"""
Drive one real agent turn through LibreChat's own API and print what came back.

    python scripts/smoke/agent_turn.py analyst "Dashboard Reviewer" "your prompt"
    python scripts/smoke/agent_turn.py admin "Pagila BI Analyst" "total revenue?"

This is the only test that exercises the WHOLE path: LibreChat -> agent record ->
MCP client -> MCP server -> Cube or Superset -> model -> tool result -> answer.
Every component smoke test bypasses LibreChat, so none of them can catch a broken
agent record, a tool-id typo, or an MCP server that LibreChat's SSRF guard has
silently blocked.

Stdlib only (urllib), so the smoke test has no additional host dependency and can
read LibreChat's SSE response stream directly.
"""
from __future__ import annotations

import json
import os
import sys
import time
import urllib.error
import urllib.request
import uuid

BASE = os.environ.get("LIBRECHAT_URL", "http://localhost:3080")

# A model answer can contain characters a restrictive host console cannot encode.
# Force UTF-8 so a successful turn is not reported as a printing failure.
for _stream in (sys.stdout, sys.stderr):
    try:
        _stream.reconfigure(encoding="utf-8", errors="replace")
    except (AttributeError, ValueError):
        pass

# Mandatory. LibreChat's uaParser middleware answers {"message":"Illegal request"}
# without a browser-like User-Agent, and it does so on the SSE channel, where it
# reads as a model failure rather than a rejected request.
UA = ("Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36")

USERS = {
    "analyst": ("DEMO_ANALYST_EMAIL", "DEMO_ANALYST_PASSWORD"),
    "admin": ("DEMO_ADMIN_EMAIL", "DEMO_ADMIN_PASSWORD"),
}


def _req(path: str, method: str = "GET", body: dict | None = None,
         token: str | None = None, accept: str = "application/json"):
    data = json.dumps(body).encode() if body is not None else None
    r = urllib.request.Request(BASE + path, data=data, method=method)
    r.add_header("User-Agent", UA)
    r.add_header("Accept", accept)
    if data is not None:
        r.add_header("Content-Type", "application/json")
    if token:
        r.add_header("Authorization", f"Bearer {token}")
    return r


def login(email: str, password: str, attempts: int = 6) -> str:
    """Log in, backing off on 429.

    LibreChat rate-limits /api/auth/login per IP, and running this script a few
    times in a row is enough to trip it. The failure is an unhandled HTTPError
    several frames deep, which looks like a broken script rather than "wait a
    minute", so absorb it here.
    """
    delay = 15
    for i in range(attempts):
        try:
            with urllib.request.urlopen(
                _req("/api/auth/login", "POST", {"email": email, "password": password}),
                timeout=60,
            ) as resp:
                return json.load(resp)["token"]
        except urllib.error.HTTPError as e:
            if e.code != 429 or i == attempts - 1:
                raise SystemExit(
                    f"login failed for {email}: HTTP {e.code} "
                    f"{e.read().decode('utf-8', 'replace')[:200]}"
                )
            print(f"  login rate-limited, retrying in {delay}s ...", file=sys.stderr)
            time.sleep(delay)
            delay = min(delay * 2, 120)
    raise SystemExit("unreachable")


def find_agent(token: str, name: str) -> str:
    with urllib.request.urlopen(_req("/api/agents", token=token), timeout=60) as resp:
        agents = json.load(resp).get("data") or []
    for a in agents:
        if a.get("name") == name:
            return a["id"]
    have = ", ".join(sorted(a.get("name", "?") for a in agents)) or "(none)"
    raise SystemExit(f"no agent named {name!r} for this user. Have: {have}\n"
                     f"Run scripts/provision-agent.sh")


def turn(token: str, agent_id: str, model: str, text: str, timeout: int = 600) -> int:
    """Run one turn and narrate the tool calls.

    TWO PHASES, not one. LibreChat 0.8.7 uses the RESUMABLE controller: the POST
    does NOT stream: it registers a generation job and answers a single JSON body
    `{"streamId": ..., "status": "started"}`. The events come from a separate
    GET /api/agents/chat/stream/<streamId>. Reading the POST response as SSE yields
    exactly one line and looks like an agent that produced nothing -- which is
    precisely the false negative this comment exists to prevent.

    parentMessageId must be the NO_PARENT sentinel (all-zero uuid) to start a new
    conversation; omitting it makes the controller look for a message that does not
    exist. conversationId must be null, not absent.
    """
    body = {
        "text": text,
        "endpoint": "agents",
        "agent_id": agent_id,
        "model": model,
        "conversationId": None,
        "parentMessageId": "00000000-0000-0000-0000-000000000000",
        "messageId": str(uuid.uuid4()),
        "sender": "User",
        "isCreatedByUser": True,
        "isContinued": False,
        "isTemporary": True,
        "error": False,
        "generation": "",
    }

    try:
        with urllib.request.urlopen(
            _req("/api/agents/chat/agents", "POST", body, token=token), timeout=120
        ) as r:
            started = json.load(r)
    except urllib.error.HTTPError as e:
        print(f"POST HTTP {e.code}: {e.read().decode('utf-8', 'replace')[:600]}",
              file=sys.stderr)
        return 1

    stream_id = started.get("streamId")
    if not stream_id:
        print(f"no streamId in response: {json.dumps(started)[:400]}", file=sys.stderr)
        return 1
    print(f"stream {stream_id} ({started.get('status')})\n")

    try:
        resp = urllib.request.urlopen(
            _req(f"/api/agents/chat/stream/{stream_id}", token=token,
                 accept="text/event-stream"),
            timeout=timeout,
        )
    except urllib.error.HTTPError as e:
        print(f"GET stream HTTP {e.code}: {e.read().decode('utf-8', 'replace')[:600]}",
              file=sys.stderr)
        return 1

    final = ""
    tool_calls: list[str] = []
    seen_error = None

    for raw in resp:
        line = raw.decode("utf-8", "replace").rstrip("\n")
        if not line.startswith("data:"):
            continue
        chunk = line[5:].strip()
        if not chunk or chunk == "[DONE]":
            continue
        try:
            msg = json.loads(chunk)
        except json.JSONDecodeError:
            continue

        # Tool activity arrives as content parts of type tool_call. Printing the
        # tool NAME and ARGS is the point of this script -- it proves the model
        # actually reached the MCP server rather than answering from memory.
        for part in _content_parts(msg):
            if part.get("type") == "tool_call":
                tc = part.get("tool_call") or {}
                name = tc.get("name", "?")
                args = tc.get("args")
                if isinstance(args, dict):
                    args = json.dumps(args)
                sig = f"{name}({str(args)[:400]})"
                if sig not in tool_calls:
                    tool_calls.append(sig)
                    print(f"  TOOL {sig}")

        if msg.get("final") or msg.get("responseMessage"):
            rm = msg.get("responseMessage") or {}
            final = _text_of(rm) or final
        if msg.get("error"):
            seen_error = msg

    resp.close()

    print("\n---- tool calls ----")
    for t in tool_calls:
        print(f"  {t}")
    if not tool_calls:
        print("  (none -- the model answered without touching a tool)")

    print("\n---- final answer ----")
    print(final or "(empty)")

    if seen_error:
        print(f"\nSTREAM ERROR: {json.dumps(seen_error)[:600]}", file=sys.stderr)
        return 1
    return 0 if final else 1


def _content_parts(msg: dict) -> list[dict]:
    for key in ("responseMessage", "message"):
        node = msg.get(key)
        if isinstance(node, dict) and isinstance(node.get("content"), list):
            return [p for p in node["content"] if isinstance(p, dict)]
    if isinstance(msg.get("content"), list):
        return [p for p in msg["content"] if isinstance(p, dict)]
    # Incremental deltas carry a single part under a different envelope.
    for key in ("data", "delta"):
        node = msg.get(key)
        if isinstance(node, dict):
            if isinstance(node.get("content"), list):
                return [p for p in node["content"] if isinstance(p, dict)]
            if node.get("type"):
                return [node]
    return []


def _text_of(rm: dict) -> str:
    if isinstance(rm.get("text"), str) and rm["text"]:
        return rm["text"]
    out = []
    for part in rm.get("content") or []:
        if isinstance(part, dict) and part.get("type") == "text":
            t = part.get("text")
            out.append(t if isinstance(t, str) else (t or {}).get("value", ""))
    return "".join(out)


def env_or_dotenv(key: str) -> str:
    """Environment first, then .env -- read, never sourced.

    Values contain characters a shell would interpret (JSON, spaces), and this
    script is documented as runnable straight from the host, so requiring the
    caller to export four variables first would make the documented command a
    KeyError.
    """
    if os.environ.get(key):
        return os.environ[key]
    root = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    path = os.path.join(root, ".env")
    try:
        with open(path, encoding="utf-8") as fh:
            for line in fh:
                name, sep, value = line.partition("=")
                if sep and name.strip() == key:
                    return value.strip().strip('"').strip("'")
    except FileNotFoundError:
        pass
    raise SystemExit(f"{key} is not set and not found in {path}")


def main() -> int:
    if len(sys.argv) < 4:
        print(__doc__)
        return 2
    who, agent_name, prompt = sys.argv[1], sys.argv[2], " ".join(sys.argv[3:])
    if who not in USERS:
        print(f"user must be one of {list(USERS)}", file=sys.stderr)
        return 2

    email_var, pw_var = USERS[who]
    email, password = env_or_dotenv(email_var), env_or_dotenv(pw_var)
    model = env_or_dotenv("AZURE_FOUNDRY_MODEL")

    token = login(email, password)
    agent_id = find_agent(token, agent_name)
    print(f"== {who} ({email}) -> {agent_name} [{agent_id}] ==")
    print(f"prompt: {prompt}\n")
    return turn(token, agent_id, model, prompt)


if __name__ == "__main__":
    sys.exit(main())
