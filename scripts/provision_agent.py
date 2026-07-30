"""
Provision the demo agents in LibreChat.

Runs on the HOST against the published LibreChat port. Uses only the standard
library (urllib), so it needs no pip install and no container to borrow -- the
previous version ran inside cube-mcp, which no longer exists.

Implemented in standard-library Python so provisioning has no additional host
dependency.

Agents cannot be declared in librechat.yaml (issue #7741 is open;
`interface.agents` only seeds role permissions), so scripted creation is the
closest thing to infrastructure-as-code.

-------------------------------------------------------------------------------
 WHY ONE AGENT PER USER, AND WHY THE ROLE IS ON THE AGENT
-------------------------------------------------------------------------------
Two separate constraints happen to point the same way:

1. LibreChat access-controls agents through an ACL, and an agent created via
   POST /api/agents gets no ACL entry for its author -- even the creator then gets
   "Forbidden: Insufficient permissions" from PUT /api/permissions/agent/:id, and
   `isCollaborative` is accepted (HTTP 200) but not persisted. So a single
   admin-owned agent is simply invisible to the analyst.

2. Cube identity now lives in the MCP *server* (two containers, two static SQL
   users) rather than in a per-request header. So the masked/unmasked distinction
   has to be expressed by WHICH MCP SERVER an agent is wired to.

Result: each demo user owns an identically-configured agent that differs only in
the MCP server it talks to. That is an honest demo of the semantic layer -- same
prompt, same instructions, same model, different masking -- but it is NOT
governance: nothing stops a user from being handed the admin agent.

-------------------------------------------------------------------------------
 TWO AGENTS, TWO JOBS
-------------------------------------------------------------------------------
  * "Pagila BI Analyst"  -> Cube's SQL API. Writes SQL against the semantic
    layer, computes in Python, plots. Masking differs per owner.
  * "Dashboard Reviewer" -> Superset's own MCP service. Reads the charts that
    already exist and critiques them. IDENTICAL for both owners, because Superset
    6.1.0's MCP has no per-user identity: every call runs as the mcp_reader
    service account (see config/superset/create_mcp_reader.py). Don't read a difference
    into it that isn't there.
"""
from __future__ import annotations

import http.client
import json
import os
import sys
import time
import urllib.error
import urllib.request

BASE = os.environ.get("LIBRECHAT_URL", "http://localhost:3080")

# LibreChat's uaParser middleware rejects requests without a browser-like
# User-Agent, answering {"message":"Illegal request"} on an SSE channel -- which
# looks nothing like a header problem.
UA = (
    "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"
)

# Tool ids are deterministic: <toolName>_mcp_<serverName>, where
# Constants.mcp_delimiter = '_mcp_'.
#
# Deliberately only the FOUR tools that work against Cube. postgres-mcp also
# exposes explain_query, get_top_queries, analyze_workload_indexes,
# analyze_query_indexes and analyze_db_health, which need
# pg_stat_statements / hypopg / pg_indexes -- none of which a semantic layer
# implements. There is no server-side flag to disable them in 0.3.0, so we simply
# do not attach them to the agent and the model never sees them.
WORKING_TOOLS = ("execute_sql", "list_schemas", "list_objects", "get_object_details")

# Superset ships 24 MCP tools and none of them can be disabled server-side when
# launched via `superset mcp run` (MCP_FACTORY_CONFIG's exclude_tags is only read
# on the use_factory_config=True path, which the CLI does not take). So the
# allowlist is here: read-only navigation plus the one tool that returns rows.
#
# Everything omitted is omitted for a reason:
#   * generate_chart / generate_dashboard / update_chart / save_sql_query /
#     create_virtual_dataset / add_chart_to_existing_dashboard / execute_sql --
#     mcp_reader is read-only and would be denied anyway. Not attaching them
#     means the model never wastes a turn discovering that.
#   * get_chart_preview / update_chart_preview -- need Selenium and a browser,
#     neither of which is deployed.
SUPERSET_TOOLS = (
    "get_instance_info",
    "list_dashboards",
    "get_dashboard_info",
    "list_charts",
    "get_chart_info",
    "get_chart_data",
    "list_datasets",
    "get_dataset_info",
    "generate_explore_link",
    "get_schema",
)


def call(method: str, path: str, body: dict | None = None,
         token: str | None = None, attempts: int = 5) -> tuple[int, dict | list]:
    """Minimal JSON request. A browser-like User-Agent is mandatory or
    LibreChat's uaParser answers {"message":"Illegal request"}.

    Retries on CONNECTION-level failures, not on HTTP status codes. A booting
    LibreChat accepts the TCP connection and then closes it without replying, so
    the first request after `docker compose up -d` can raise
        http.client.RemoteDisconnected: Remote end closed connection without response
    which is indistinguishable from a crashed container unless you retry. An HTTP
    error is a real answer and is returned to the caller as-is.
    """
    data = json.dumps(body).encode() if body is not None else None
    delay = 3.0
    for attempt in range(1, attempts + 1):
        req = urllib.request.Request(BASE + path, data=data, method=method)
        req.add_header("User-Agent", UA)
        req.add_header("Accept", "application/json")
        if data is not None:
            req.add_header("Content-Type", "application/json")
        if token:
            req.add_header("Authorization", f"Bearer {token}")
        try:
            with urllib.request.urlopen(req, timeout=90) as resp:
                raw = resp.read().decode("utf-8", "replace")
                try:
                    return resp.status, json.loads(raw)
                except json.JSONDecodeError:
                    return resp.status, {"_raw": raw[:500]}
        except urllib.error.HTTPError as e:
            raw = e.read().decode("utf-8", "replace")
            try:
                return e.code, json.loads(raw)
            except json.JSONDecodeError:
                return e.code, {"_raw": raw[:500]}
        except (http.client.RemoteDisconnected, ConnectionError,
                urllib.error.URLError, TimeoutError) as e:
            if attempt == attempts:
                raise
            print(f"  {method} {path}: {type(e).__name__} - retrying in {delay:.0f}s "
                  f"({attempt}/{attempts})", file=sys.stderr)
            time.sleep(delay)
            delay = min(delay * 2, 20.0)
    raise RuntimeError("unreachable")


def mcp_tools_for(names, server: str) -> list[str]:
    return [f"{t}_mcp_{server}" for t in names]


# The shared business rules deliberately live in the system prompt: every answer
# needs them, and attaching them through file_search made their availability depend
# on RAG retrieval. file_search remains enabled for documents a user attaches.
SYSTEM_RULES_FILE = "system-rules.md"


def system_rules() -> str:
    """Read the compact shared appendix before making any network mutation."""
    path = os.path.join(LIBRECHAT_CONFIG, SYSTEM_RULES_FILE)
    try:
        with open(path, encoding="utf-8") as fh:
            return fh.read().strip()
    except OSError as e:
        raise RuntimeError(f"required system rules unavailable: {path}: {e}") from e


def append_system_rules(instructions: str, rules: str) -> str:
    return instructions.rstrip() + "\n\n---\n\n" + rules + "\n"


BI_STARTERS = [
    "Which film category earned the most revenue?",
    "Plot monthly revenue by store for the last 12 months.",
    "Compare each film's list price against what it actually earned.",
    "Who are the top 10 customers by lifetime value?",
    "How many rentals are overdue, and at which store?",
]

REVIEW_STARTERS = [
    "What dashboards exist, and what does each one claim?",
    "Read the revenue dashboard and tell me the three things that matter.",
    "Do the KPI tiles reconcile with the detail charts?",
    "Is the revenue trend real, or an artefact of an incomplete period?",
    "Which charts on this dashboard are misleading, and why?",
]


REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LIBRECHAT_CONFIG = os.path.join(REPO_ROOT, "config", "librechat")


def read_text(*parts: str) -> str:
    return open(os.path.join(REPO_ROOT, *parts), encoding="utf-8").read()


def main() -> int:
    # Checked BEFORE any network call: these paths are resolved at runtime, so a
    # moved directory would otherwise surface only after logging in and part-way
    # through creating agents.
    if not os.path.isdir(LIBRECHAT_CONFIG):
        print(f"config directory not found: {LIBRECHAT_CONFIG}", file=sys.stderr)
        return 1

    model = os.environ["AZURE_FOUNDRY_MODEL"]
    analyst_email = os.environ["DEMO_ANALYST_EMAIL"]
    analyst_pw = os.environ["DEMO_ANALYST_PASSWORD"]
    admin_email = os.environ["DEMO_ADMIN_EMAIL"]
    admin_pw = os.environ["DEMO_ADMIN_PASSWORD"]

    bi_instructions = read_text("config", "librechat", "agent-instructions.md")
    review_instructions = read_text("config", "librechat",
                                    "agent-dashboard-instructions.md")
    try:
        rules = system_rules()
    except RuntimeError as e:
        print(e, file=sys.stderr)
        return 1
    bi_instructions = append_system_rules(bi_instructions, rules)
    review_instructions = append_system_rules(review_instructions, rules)

    def reviewer() -> dict:
        # Byte-identical for both owners on purpose -- see the module docstring.
        return {
            "name": "Dashboard Reviewer",
            "description": "Reads and critiques the Superset dashboards (read-only service account).",
            "instructions": review_instructions,
            "tools": mcp_tools_for(SUPERSET_TOOLS, "superset") + ["execute_code", "file_search"],
            "mcp": "superset",
            "starters": REVIEW_STARTERS,
            # Direct tool-calling allowed here, unlike the BI agent. The Superset
            # tools take a single nested `request` object and return already
            # structured JSON, so forcing every call through generated Python buys
            # nothing and adds a place to get the nesting wrong. Python stays
            # available for when the agent wants to actually compute over the rows.
            "allow_direct": True,
        }

    # (owner_email, owner_password, agent spec)
    plan = [
        (analyst_email, analyst_pw, {
            "name": "Pagila BI Analyst",
            "description": "Governed analytics over the Pagila semantic layer (PII masked).",
            "instructions": bi_instructions,
            "tools": mcp_tools_for(WORKING_TOOLS, "cube_analyst") + ["execute_code", "file_search"],
            "mcp": "cube_analyst",
            "starters": BI_STARTERS,
        }),
        (analyst_email, analyst_pw, reviewer()),
        (admin_email, admin_pw, {
            "name": "Pagila BI Analyst",
            "description": "Governed analytics over the Pagila semantic layer (PII visible).",
            "instructions": bi_instructions,
            "tools": mcp_tools_for(WORKING_TOOLS, "cube_admin") + ["execute_code", "file_search"],
            "mcp": "cube_admin",
            "starters": BI_STARTERS,
        }),
        (admin_email, admin_pw, reviewer()),
    ]

    failures = 0
    for email, password, spec in plan:
        if provision(email, password, spec, model, rules) != 0:
            failures += 1

    if failures:
        return 1
    print("\nAgents ready. Open http://localhost:3080 and pick an agent.")
    return 0


def provision(email: str, password: str, spec: dict, model: str, rules: str) -> int:
    # allowed_callers=['code_execution'] hides an MCP tool from direct
    # tool-calling, so the model MUST reach it through run_tools_with_code --
    # i.e. by writing Python. For the BI agent that is what guarantees the
    # "query, pandas-process, visualise" narrative rather than hoping the model
    # picks that path. The reviewer agent opts out (spec['allow_direct']).
    # Set ALLOW_DIRECT=1 to permit both everywhere.
    if spec.get("allow_direct") or os.environ.get("ALLOW_DIRECT"):
        callers = ["direct", "code_execution"]
    else:
        callers = ["code_execution"]
    mcp_tools = [t for t in spec["tools"] if "_mcp_" in t]

    print(f"\n-- {email} --")
    status, login = call("POST", "/api/auth/login",
                         body={"email": email, "password": password})
    if status != 200 or not login.get("token"):
        print(f"  login failed (HTTP {status}): {str(login)[:200]}", file=sys.stderr)
        return 1
    token = login["token"]

    # Idempotence: there is no upsert, so remove any earlier copy.
    status, listing = call("GET", "/api/agents", token=token)
    if status == 200 and isinstance(listing, dict):
        for agent in (listing.get("data") or []):
            if agent.get("name") == spec["name"]:
                call("DELETE", f"/api/agents/{agent['id']}", token=token)
                print(f"  removed previous agent {agent['id']}")

    body = {
        "name": spec["name"],
        "description": spec["description"],
        "provider": "Azure Foundry",   # must match endpoints.custom[].name
        "model": model,
        "instructions": spec["instructions"],
        "tools": spec["tools"],
        "tool_options": {t: {"allowed_callers": callers} for t in mcp_tools},
        # REQUIRED for artifacts to work at all. The `artifacts` capability in
        # librechat.yaml only gates the UI toggle -- the prompt that teaches the
        # model the :::artifact syntax is injected only when the AGENT record has
        # a non-empty `artifacts` string (packages/api/src/agents/initialize.ts).
        # Without this, the capability is on and nothing happens.
        "artifacts": "default",
        "model_parameters": {"temperature": 0.1},
        "conversation_starters": spec["starters"],
    }

    print("  creating agent ...")
    status, agent = call("POST", "/api/agents", body=body, token=token)
    if status not in (200, 201):
        print(f"  POST /api/agents -> HTTP {status}: {str(agent)[:500]}", file=sys.stderr)
        print("  There is no UI fallback: the agent form cannot set "
              "tool_options.allowed_callers. Fix the error above and re-run.",
              file=sys.stderr)
        return 1
    agent_id = agent.get("id") or agent.get("_id")
    print(f"  agent id : {agent_id}")
    print(f"  mcp      : {spec['mcp']}")
    print(f"  tools    : {', '.join(spec['tools'])}")
    print(f"  artifacts: {body['artifacts']}  |  allowed_callers: {callers}")

    print("  rules    : compact system prompt appendix; file_search is for user uploads")
    return 0


if __name__ == "__main__":
    sys.exit(main())
