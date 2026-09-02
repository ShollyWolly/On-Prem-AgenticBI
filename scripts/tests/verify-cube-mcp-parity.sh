#!/usr/bin/env bash

source "$(dirname "${BASH_SOURCE[0]}")/../general/lib.sh"

set -euo pipefail

PASS=0
FAIL=0

assert() {
  local label="$1" condition="$2"
  if [ "$condition" = "1" ]; then
    ok "PASS  ${label}"
    PASS=$((PASS + 1))
  else
    err "FAIL  ${label}"
    FAIL=$((FAIL + 1))
  fi
}

require_container() {
  container_running "$1" || die "$1 is not running; start the chat profile first"
}

sql_password_for() {
  local user="$1" role="$2"
  docker exec -i -e TEST_SQL_USER="$user" -e TEST_SQL_ROLE="$role" abi-cube-sql-mcp python - <<'PY'
import os
from app import sql_password

print(sql_password({
    "user": os.environ["TEST_SQL_USER"],
    "subject": "parity-test",
    "role": os.environ["TEST_SQL_ROLE"],
    "groups": [os.environ["TEST_SQL_ROLE"]],
}))
PY
}

cube_sql() {
  local user="$1" password="$2" query="$3"
  compose_x exec -T -e PGPASSWORD="$password" postgres \
    psql -h cube -p 15432 -U "$user" -d cube -Atc "$query" 2>/dev/null | tr -d '\r' | head -n1
}

rest_revenue() {
  docker exec -i abi-cube-mcp python - <<'PY'
import os
import time

import httpx
import jwt

identity = {
    "user": "analyst@demo.local",
    "subject": "parity-test",
    "role": "analyst",
    "groups": ["analyst"],
}

token = jwt.encode(
    {"iat": int(time.time()), "exp": int(time.time()) + 60, "securityContext": identity},
    os.environ["CUBEJS_API_SECRET"],
    algorithm="HS256",
)
response = httpx.post(
    f"{os.environ['CUBE_API_URL']}/load",
    headers={"Authorization": f"Bearer {token}"},
    json={"query": {"measures": ["revenue_analytics.total_revenue"]}},
    timeout=45,
)
response.raise_for_status()
print(response.json()["data"][0]["revenue_analytics.total_revenue"])
PY
}

sql_gateway_revenue() {
  docker exec -i abi-cube-sql-mcp python - <<'PY'
import asyncio

from app import connect, validate_sql, visible_views

identity = {
    "user": "analyst@demo.local",
    "subject": "parity-test",
    "role": "analyst",
    "groups": ["analyst"],
}

async def main():
    connection = await connect(identity)
    try:
        views = await visible_views(connection)
        query, _ = validate_sql(
            "SELECT MEASURE(total_revenue) FROM revenue_analytics", views
        )
        value = await connection.fetchval(query)
    finally:
        await connection.close()
    print(f"{len(views)}|{value}")

asyncio.run(main())
PY
}

sql_gateway_schema() {
  docker exec -i abi-cube-sql-mcp python - <<'PY'
import asyncio

from app import described_schema

identity = {
    "user": "analyst@demo.local",
    "subject": "parity-test",
    "role": "analyst",
    "groups": ["analyst"],
}

async def main():
    schema = await described_schema(identity)
    revenue = next(view for view in schema["views"] if view["name"] == "revenue_analytics")
    email = next(column for column in revenue["columns"] if column["name"] == "customers_email")
    if not revenue.get("description") or email.get("description") != "E-mail address. PII.":
        raise SystemExit("Cube descriptions missing from SQL schema")
    print("ok")

asyncio.run(main())
PY
}

require_container abi-cube
require_container abi-cube-mcp
require_container abi-cube-sql-mcp

sql_mcp_port="$(env_get CUBE_SQL_MCP_HOST_PORT || true)"
sql_mcp_port="${sql_mcp_port:-8004}"
sql_mcp_status="$(curl -sS -o /dev/null -w '%{http_code}' "http://localhost:${sql_mcp_port}/mcp" || true)"
assert "Cube SQL MCP rejects unauthenticated requests" "$([ "$sql_mcp_status" = "401" ] && echo 1 || echo 0)"

analyst_password="$(sql_password_for analyst@demo.local analyst)"
admin_password="$(sql_password_for admin@demo.local admin)"
analyst_email="$(cube_sql analyst@demo.local "$analyst_password" 'SELECT customers_email FROM revenue_analytics GROUP BY 1 LIMIT 1')"
admin_email="$(cube_sql admin@demo.local "$admin_password" 'SELECT customers_email FROM revenue_analytics GROUP BY 1 LIMIT 1')"
assert "signed analyst SQL session masks customer e-mail" "$(case "$analyst_email" in '***@'*) echo 1 ;; *) echo 0 ;; esac)"
assert "signed admin SQL session reveals customer e-mail" "$(case "$admin_email" in '***@'*|'') echo 0 ;; *) echo 1 ;; esac)"

sql_revenue="$(cube_sql analyst@demo.local "$analyst_password" 'SELECT MEASURE(total_revenue) FROM revenue_analytics')"
api_revenue="$(rest_revenue)"
assert "SQL and REST revenue results match" "$([ "$sql_revenue" = "$api_revenue" ] && echo 1 || echo 0)"

gateway_result="$(sql_gateway_revenue)"
assert "SQL MCP connects with the signed analyst context" \
  "$([ "$gateway_result" = "5|${sql_revenue}" ] && echo 1 || echo 0)"

schema_output="$(sql_gateway_schema)"
assert "SQL MCP includes Cube view and column descriptions" \
  "$([ "$schema_output" = "ok" ] && echo 1 || echo 0)"

validator_output="$(docker exec -i abi-cube-sql-mcp python - <<'PY'
from app import validate_sql

allowed = {"revenue_analytics"}
cases = [
    ("SELECT MEASURE(total_revenue) FROM revenue_analytics", True),
    ("SELECT * FROM public.payment", False),
    ("DELETE FROM revenue_analytics", False),
    ("SELECT 1; SELECT 2", False),
    ("SELECT * FROM revenue_analytics LIMIT 1001", True),
]
for query, expected in cases:
    try:
        validate_sql(query, allowed)
        actual = True
    except ValueError:
        actual = False
    if actual != expected:
        raise SystemExit(query)
query, limit = validate_sql("SELECT * FROM revenue_analytics", allowed)
if limit is not None or query.endswith(" LIMIT 1000"):
    raise SystemExit("query unexpectedly capped")
print("ok")
PY
)"
assert "SQL validator permits unbounded read-only semantic queries" "$([ "$validator_output" = "ok" ] && echo 1 || echo 0)"

printf '\nResult: %s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
