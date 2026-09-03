#!/usr/bin/env bash

# This cleanup removes legacy direct warehouse MCP database access from the demo.
source "$(dirname "${BASH_SOURCE[0]}")/../../general/lib.sh"

container_running abi-postgres || die "abi-postgres is not running"

pg_user="$(env_get POSTGRES_USER || echo postgres)"
pg_db="$(env_get POSTGRES_DB || echo pagila)"
compose_x exec -T postgres psql -v ON_ERROR_STOP=1 -U "$pg_user" -d "$pg_db" \
  -c 'DO $block$ BEGIN IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = $role$warehouse_mcp_ro$role$) THEN DROP OWNED BY warehouse_mcp_ro; DROP ROLE warehouse_mcp_ro; END IF; END $block$;' >/dev/null

ok "Removed the retired warehouse MCP database role"
