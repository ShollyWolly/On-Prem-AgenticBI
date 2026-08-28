"""Smoke test Superset MCP access."""
from __future__ import annotations

import json
import sys

import httpx

BASE = "http://localhost:5008/mcp"


class HttpMcp:
    """Minimal MCP streamable-HTTP client."""

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
        """Return the response frame matching the request ID."""
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
        """Return tool text or an error marker."""
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
    """Return the first numeric ID in a tool response."""
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

    who = m.call("get_instance_info")
    check("acts as the mcp_reader service account", "mcp_reader" in who,
          who.replace("\n", " ")[:120])

    dash = m.call("list_dashboards")
    check("sees the provisioned dashboard", "Agentic BI" in dash,
          dash.replace("\n", " ")[:120])

    dash_id = first_id(dash)
    check("dashboard id resolved", dash_id is not None, str(dash_id))

    if dash_id is not None:
        info = m.call("get_dashboard_info", {"identifier": dash_id})
        check("get_dashboard_info returns charts", '"charts"' in info or "slice" in info.lower(),
              f"{len(info)} bytes")

    charts = m.call("list_charts")
    check("sees the provisioned charts", len(charts) > 200, f"{len(charts)} bytes")

    chart_id = first_id(charts)
    check("chart id resolved", chart_id is not None, str(chart_id))

    if chart_id is not None:
        info = m.call("get_chart_info", {"identifier": chart_id})
        check("get_chart_info works", not info.startswith("ERROR"),
              info.replace("\n", " ")[:100])

        data = m.call("get_chart_data", {"identifier": chart_id})
        check("get_chart_data returns ROWS, not just metadata",
              not data.startswith("ERROR") and '"data":[{' in data,
              data.replace("\n", " ")[:160])

        check("dashboard figure equals the semantic layer's figure",
              "67416.51" in data, "matches MEASURE(total_revenue) in test_pgmcp.py")

    series = m.call("get_chart_data", {"identifier": 5})
    months = series.count('T00:00:00","total_revenue"')
    check("time-series chart returns monthly buckets, not raw rows",
          months == 7, f"{months} rows (expect 7 months)")

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
