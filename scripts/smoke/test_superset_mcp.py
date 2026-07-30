"""
Smoke test Superset's built-in MCP service (SIP-187, shipped in 6.1.0).

Runs on the HOST (needs `pip install httpx`):

    python scripts/smoke/test_superset_mcp.py

What this proves, and why each check exists:

  * The service speaks MCP over STREAMABLE-HTTP, not SSE. Note GET /mcp returns
    405 Method Not Allowed -- that is correct, the route is POST-only, and the 405
    is what the compose healthcheck keys on.

  * `get_chart_data` returns the ACTUAL ROWS behind a saved chart. Without this,
    an "analyse the dashboard" agent is just paraphrasing chart titles.

  * THE SERVICE ACCOUNT IS THE SECURITY BOUNDARY. Superset 6.1.0 has no per-user
    MCP identity (see config/superset/create_mcp_reader.py for the code trail), so every
    call acts as MCP_DEV_USERNAME = mcp_reader. We therefore assert the read-only
    posture from the outside: execute_sql must be refused. If that ever starts
    passing, the agent has gained a path to the warehouse that bypasses Cube's
    masking entirely.

  * The rows arriving here came through Cube, so masked columns stay masked. The
    dashboard and the chat agent read the same governed numbers.
"""
from __future__ import annotations

import json
import sys

import httpx

BASE = "http://localhost:5008/mcp"


class HttpMcp:
    """Minimal MCP streamable-http client.

    The transport answers a POST with either a JSON body or an SSE-framed body
    depending on Accept negotiation, so both are handled.

    This server runs STATELESS: it issues no `mcp-session-id` and logs
    "Terminating session: None" after every request. So each POST must be
    self-contained -- there is nothing to echo back, and equally nothing to keep
    alive. The session id is still captured if present, to stay correct if a later
    Superset flips to the stateful transport.
    """

    def __init__(self, url: str):
        self.url = url
        self.client = httpx.Client(timeout=180)
        self.session: str | None = None
        self._id = 0

    def open(self) -> "HttpMcp":
        res, headers = self._rpc_raw("initialize", {
            "protocolVersion": "2025-06-18",
            "capabilities": {},
            "clientInfo": {"name": "superset-mcp-smoke", "version": "0"},
        })
        self.session = headers.get("mcp-session-id")
        self.protocol = res.get("result", {}).get("protocolVersion", "?")
        self._post_notify("notifications/initialized")
        return self

    def _headers(self) -> dict:
        h = {"Content-Type": "application/json",
             "Accept": "application/json, text/event-stream"}
        if self.session:
            h["mcp-session-id"] = self.session
        return h

    @staticmethod
    def _parse(body: str, want_id: int) -> dict:
        """Pick the RESPONSE frame out of an SSE body, by matching the request id.

        The body is not one frame. Superset's tools log through the MCP logging
        capability, so a single POST answers with N `notifications/message` frames
        followed by the actual result. Taking the first `data:` line therefore
        returns a log line -- which decodes cleanly as JSON, has no "result" key,
        and so silently reads as "the tool returned nothing". That cost a round of
        false failures here; match on id instead.
        """
        body = body.strip()
        if not body:
            return {}
        if body.startswith("{"):
            return json.loads(body)

        fallback: dict = {}
        for line in body.splitlines():
            if not line.startswith("data:"):
                continue
            chunk = line[5:].strip()
            if not chunk.startswith("{"):
                continue
            try:
                msg = json.loads(chunk)
            except json.JSONDecodeError:
                continue
            if msg.get("id") == want_id:
                return msg
            fallback = fallback or msg
        if fallback:
            return fallback
        raise RuntimeError(f"unparseable body: {body[:200]}")

    def _rpc_raw(self, method: str, params: dict | None = None):
        self._id += 1
        payload = {"jsonrpc": "2.0", "id": self._id, "method": method}
        if params is not None:
            payload["params"] = params
        r = self.client.post(self.url, json=payload, headers=self._headers())
        if r.status_code >= 400:
            raise RuntimeError(f"{method} -> {r.status_code}: {r.text[:300]}")
        return self._parse(r.text, self._id), r.headers

    def _post_notify(self, method: str) -> None:
        self.client.post(self.url, json={"jsonrpc": "2.0", "method": method},
                         headers=self._headers())

    def rpc(self, method: str, params: dict | None = None) -> dict:
        return self._rpc_raw(method, params)[0]

    def tools(self) -> list[str]:
        return [t["name"] for t in self.rpc("tools/list").get("result", {}).get("tools", [])]

    def call(self, name: str, args: dict | None = None, wrap: bool = True) -> str:
        """Returns the tool's text output, or an 'ERROR: ...' marker.

        WRAPPING: nearly every Superset MCP tool declares exactly one parameter,
        an object called `request`, and the real arguments live inside it. Passing
        them flat yields a pydantic ValidationError that the middleware then
        reports as "Internal error ... contact support", which reads like a bug in
        Superset rather than a bad call. (`health_check` and `get_chart_type_schema`
        are the exceptions -- pass wrap=False for those.)

        Both failure shapes are flattened deliberately: a JSON-RPC `error`, and a
        result carrying isError=true (which is how FastMCP reports a tool that
        raised). A caller asserting "this is refused" must catch both.
        """
        payload = {"request": args or {}} if wrap else (args or {})
        res = self.rpc("tools/call", {"name": name, "arguments": payload})
        if "error" in res:
            return "ERROR: " + json.dumps(res["error"])[:600]
        result = res.get("result", {})
        text = "\n".join(b.get("text", "") for b in result.get("content", [])
                         if b.get("type") == "text")
        if result.get("isError"):
            return "ERROR: " + text[:600]
        if not text and "structuredContent" in result:
            text = json.dumps(result["structuredContent"])
        return text

    def close(self) -> None:
        self.client.close()


PASS = FAIL = 0


def check(label: str, ok: bool, detail: str = "") -> None:
    global PASS, FAIL
    mark = "PASS" if ok else "FAIL"
    if ok:
        PASS += 1
    else:
        FAIL += 1
    print(f"  [{mark}] {label}" + (f" -- {detail}" if detail else ""))


def first_id(blob: str) -> int | None:
    """Pull the first numeric "id" out of a tool response of unknown shape.

    The MCP tools return pydantic models serialised to JSON, and the envelope
    shape differs per tool and per version, so key-path walking is brittle. A
    scan for the first plausible id is stable across both.
    """
    try:
        data = json.loads(blob)
    except json.JSONDecodeError:
        return None

    stack = [data]
    while stack:
        node = stack.pop(0)
        if isinstance(node, dict):
            if isinstance(node.get("id"), int):
                return node["id"]
            stack.extend(node.values())
        elif isinstance(node, list):
            stack.extend(node)
    return None


def main() -> int:
    m = HttpMcp(BASE).open()
    print(f"== superset mcp (protocol {m.protocol}, session {m.session or 'stateless'}) ==")
    check("initialize negotiates a protocol version", m.protocol.startswith("20"),
          m.protocol)

    names = m.tools()
    check("tools/list works", len(names) > 10, f"{len(names)} tools")
    for t in ("list_dashboards", "get_dashboard_info", "list_charts",
              "get_chart_info", "get_chart_data"):
        check(f"tool {t} present", t in names)

    # --- who are we, and is RBAC on? -------------------------------------
    who = m.call("get_instance_info")
    check("acts as the mcp_reader service account", "mcp_reader" in who,
          who.replace("\n", " ")[:120])

    # --- navigation ------------------------------------------------------
    dash = m.call("list_dashboards")
    check("sees the provisioned dashboard", "Agentic BI" in dash,
          dash.replace("\n", " ")[:120])

    dash_id = first_id(dash)
    check("dashboard id resolved", dash_id is not None, str(dash_id))

    if dash_id is not None:
        # `identifier`, not `dashboard_id` -- the tools take ID, UUID or slug
        # through one polymorphic field.
        info = m.call("get_dashboard_info", {"identifier": dash_id})
        check("get_dashboard_info returns charts", '"charts"' in info or "slice" in info.lower(),
              f"{len(info)} bytes")

    charts = m.call("list_charts")
    check("sees the provisioned charts", len(charts) > 200, f"{len(charts)} bytes")

    chart_id = first_id(charts)
    check("chart id resolved", chart_id is not None, str(chart_id))

    # --- the point of the whole exercise: real rows -----------------------
    if chart_id is not None:
        info = m.call("get_chart_info", {"identifier": chart_id})
        check("get_chart_info works", not info.startswith("ERROR"),
              info.replace("\n", " ")[:100])

        data = m.call("get_chart_data", {"identifier": chart_id})
        check("get_chart_data returns ROWS, not just metadata",
              not data.startswith("ERROR") and '"data":[{' in data,
              data.replace("\n", " ")[:160])

        # THE POINT OF THE WHOLE ARCHITECTURE: the dashboard and the chat agent
        # are reading the same governed numbers. 67416.51 is exactly what
        # test_pgmcp.py gets from MEASURE(total_revenue) over the SQL API. One
        # semantic layer, two consumers, no second definition of "revenue".
        check("dashboard figure equals the semantic layer's figure",
              "67416.51" in data, "matches MEASURE(total_revenue) in test_pgmcp.py")

    # A time-series chart, to prove the monthly grain survives the MCP path too
    # (an ungrouped chart silently returns raw rows -- see build_dashboard.py).
    series = m.call("get_chart_data", {"identifier": 5})
    months = series.count('T00:00:00","total_revenue"')
    check("time-series chart returns monthly buckets, not raw rows",
          months == 7, f"{months} rows (expect 7 months)")

    # --- the security assertion ------------------------------------------
    # mcp_reader deliberately lacks can_execute_sql_query. If this ever starts
    # succeeding, the agent has a warehouse path that skips Cube's masking.
    if "execute_sql" in names:
        sql = m.call("execute_sql", {"database_id": 1, "sql": "SELECT 1"})
        low = sql.lower()
        check("execute_sql REFUSED for the service account",
              sql.startswith("ERROR") or "permission" in low
              or "forbidden" in low or "not authorized" in low
              or "unauthorized" in low or "access" in low and "denied" in low,
              sql.replace("\n", " ")[:160])
    else:
        check("execute_sql not even exposed", True, "tool absent from this build")

    m.close()

    print(f"\n{PASS} passed, {FAIL} failed")
    return 1 if FAIL else 0


if __name__ == "__main__":
    sys.exit(main())
