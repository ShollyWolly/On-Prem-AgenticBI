#!/usr/bin/env bash

# This check verifies verifier audit contracts, audit service health, and database role separation.
source "$(dirname "${BASH_SOURCE[0]}")/../general/lib.sh"

set -euo pipefail

container_running abi-postgres || die "abi-postgres is not running"
container_running abi-sql-verifier-mcp || die "abi-sql-verifier-mcp is not running"
container_running abi-audit-console || die "abi-audit-console is not running"

step "Verified SQL audit checks"

docker exec abi-sql-verifier-mcp python -m unittest -v test_app.py

audit_port="$(env_get AUDIT_CONSOLE_HOST_PORT || echo 8090)"
wait_http_status "http://localhost:${audit_port}/health" 200 60 || die "audit console health endpoint did not return 200"

audit_db="$(env_get AUDIT_DB_NAME || echo agentic_bi_audit)"
writer="$(env_get AUDIT_WRITER_USER || echo audit_writer)"
reader="$(env_get AUDIT_READER_USER || echo audit_reader)"
admin="$(env_get POSTGRES_USER || echo postgres)"

roles="$(compose_x exec -T postgres psql -U "$admin" -d "$audit_db" -Atc \
  "SELECT rolname FROM pg_roles WHERE rolname IN ('${writer}', '${reader}') ORDER BY rolname")"
printf '%s\n' "$roles" | rg -qx "$writer" || die "audit writer role is missing"
printf '%s\n' "$roles" | rg -qx "$reader" || die "audit reader role is missing"

privileges="$(compose_x exec -T postgres psql -U "$admin" -d "$audit_db" -Atc \
  "SELECT has_table_privilege('${writer}', 'audit_events', 'INSERT'), has_table_privilege('${writer}', 'audit_events', 'SELECT'), has_table_privilege('${reader}', 'audit_events', 'INSERT'), has_table_privilege('${reader}', 'audit_events', 'SELECT')")"
[[ "$privileges" == "t|f|f|t" ]] || die "audit database roles are not least-privilege"

verdict_columns="$(compose_x exec -T postgres psql -U "$admin" -d "$audit_db" -Atc \
  "SELECT string_agg(column_name, ',' ORDER BY column_name) FROM information_schema.columns WHERE table_name = 'audit_events' AND column_name IN ('judge_confidence', 'judge_issues', 'judge_rationale')")"
[[ "$verdict_columns" == "judge_confidence,judge_issues,judge_rationale" ]] || die "audit verdict summary columns are missing"

ok "Verified SQL audit service, verdict fields, unit contract, and least-privilege database roles are ready"
