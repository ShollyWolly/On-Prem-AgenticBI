"""Smoke test Postgres MCP servers over MCP SSE."""
from __future__ import annotations

import json
import sys
import uuid

import httpx

ANALYST = "http://localhost:8001"
ADMIN = "http://localhost:8002"


class SseMcp:
    """Minimal MCP-over-SSE client."""

    def __init__(self, base: str):
        self.base = base
        self.client = httpx.Client(timeout=120)
        self.endpoint: str | None = None
        self._id = 0
        self._stream = None
        self._lines = None

    def open(self) -> "SseMcp":
        self._stream = self.client.stream("GET", f"{self.base}/sse",
                                          headers={"Accept": "text/event-stream"})
        resp = self._stream.__enter__()
        resp.raise_for_status()
        self._lines = resp.iter_lines()
        for line in self._lines:
            if line.startswith("data:"):
                path = line[5:].strip()
                self.endpoint = self.base + path if path.startswith("/") else path
                break
        if not self.endpoint:
            raise RuntimeError("no session endpoint announced on /sse")

        self._rpc("initialize", {
            "protocolVersion": "2024-11-05",
            "capabilities": {},
            "clientInfo": {"name": "pgmcp-smoke", "version": "0"},
        })
        self._notify("notifications/initialized")
        return self

    def _post(self, payload: dict) -> None:
        r = self.client.post(self.endpoint, json=payload,
                             headers={"Content-Type": "application/json"})
        if r.status_code >= 400:
            raise RuntimeError(f"POST {payload.get('method')} -> {r.status_code}: {r.text[:300]}")

    def _notify(self, method: str) -> None:
        self._post({"jsonrpc": "2.0", "method": method})

    def _rpc(self, method: str, params: dict | None = None) -> dict:
        self._id += 1
        want = self._id
        self._post({"jsonrpc": "2.0", "id": want, "method": method,
                    **({"params": params} if params is not None else {})})
        for line in self._lines:
            if not line.startswith("data:"):
                continue
            try:
                msg = json.loads(line[5:].strip())
            except json.JSONDecodeError:
                continue
            if msg.get("id") == want:
                return msg
        raise RuntimeError(f"no response for {method}")

    def tools(self) -> list[str]:
        res = self._rpc("tools/list")
        return [t["name"] for t in res.get("result", {}).get("tools", [])]

    def sql(self, statement: str, _retry: bool = True) -> str:
        res = self._rpc("tools/call", {"name": "execute_sql",
                                       "arguments": {"sql": statement}})
        if "error" in res:
            return "RPC_ERROR: " + json.dumps(res["error"])[:400]
        out = []
        for block in res.get("result", {}).get("content", []):
            if block.get("type") == "text":
                out.append(block["text"])
        text = "\n".join(out)

        if _retry and "server closed the connection unexpectedly" in text:
            return self.sql(statement, _retry=False)
        return text

    def close(self) -> None:
        try:
            if self._stream:
                self._stream.__exit__(None, None, None)
        except Exception:
            pass
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


def main() -> int:
    print("== analyst server ==")
    a = SseMcp(ANALYST).open()
    names = a.tools()
    check("tools/list works", "execute_sql" in names, f"{len(names)} tools")

    rev = a.sql("SELECT MEASURE(total_revenue) AS revenue FROM revenue_analytics")
    check("can query the semantic layer", "67416.51" in rev, rev.replace("\n", " ")[:90])

    views = a.sql(
        "SELECT table_name FROM information_schema.tables "
        "WHERE table_schema='public' ORDER BY 1"
    )
    for v in ("revenue_analytics", "customer_analytics", "film_performance",
              "store_performance", "rental_analytics"):
        check(f"view {v} visible", v in views)

    masked = a.sql("SELECT customers_email FROM revenue_analytics GROUP BY 1 LIMIT 1")
    check("analyst sees MASKED e-mail", "***@" in masked, masked.replace("\n", " ")[:70])

    star = a.sql("SELECT * FROM revenue_analytics LIMIT 1")
    check("SELECT * is masked too (Cube's job, not ours)",
          "***@" in star and "@sakilacustomer.org" in star,
          "dimension masks survive ungrouped queries")

    esc = a.sql("SELECT customers_email FROM revenue_analytics "
                "WHERE __user = 'admin@demo.local' GROUP BY 1 LIMIT 1")
    check("__user escalation REFUSED BY CUBE",
          "cannot change security context" in esc.lower(),
          esc.replace("\n", " ")[:110])

    ins = a.sql("INSERT INTO revenue_analytics VALUES (1)")
    check("INSERT refused by Cube", "unsupported query type" in ins.lower(),
          ins.replace("\n", " ")[:90])
    drp = a.sql("DROP TABLE revenue_analytics")
    check("DROP refused by Cube", "error" in drp.lower(),
          drp.replace("\n", " ")[:90])

    meas = a.sql("SELECT MEASURE(paying_customers) AS c FROM revenue_analytics")
    check("MEASURE() works on a count_distinct measure", "599" in meas,
          meas.replace("\n", " ")[:70])
    mism = a.sql("SELECT SUM(paying_customers) AS c FROM revenue_analytics")
    check("...and a matched aggregate on it fails (why MEASURE matters)",
          "aggregation type doesn't match" in mism.lower(),
          mism.replace("\n", " ")[:80])
    a.close()

    print("\n== admin server (same image, same flags, different SQL user) ==")
    b = SseMcp(ADMIN).open()
    real = b.sql("SELECT customers_email FROM revenue_analytics GROUP BY 1 LIMIT 1")
    check("admin sees REAL e-mail",
          "@sakilacustomer.org" in real and "***@" not in real,
          real.replace("\n", " ")[:70])
    b.close()

    print(f"\n{'ALL CHECKS PASSED' if FAIL == 0 else f'{FAIL} CHECK(S) FAILED'}"
          f"  (pass={PASS} fail={FAIL})")
    return 1 if FAIL else 0


if __name__ == "__main__":
    sys.exit(main())
