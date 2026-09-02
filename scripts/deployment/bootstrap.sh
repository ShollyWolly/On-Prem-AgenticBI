#!/usr/bin/env bash

source "$(dirname "${BASH_SOURCE[0]}")/../general/lib.sh"

SKIP_SANDBOX=0
SKIP_CHAT=0
for arg in "$@"; do
  case "$arg" in
    --skip-sandbox) SKIP_SANDBOX=1 ;;
    --skip-chat)    SKIP_CHAT=1 ;;
    *) die "unknown argument: $arg" ;;
  esac
done

cd "$REPO_ROOT"

step "1/8  Vendoring upstream sources"
clone_pinned() {
  local url="$1" path="$2" ref="${3:-}"
  if [ -d "$path" ]; then
    dim "  exists: $path"
  else
    if [ -n "$ref" ]; then
      git -c core.autocrlf=false clone --depth 1 --branch "$ref" "$url" "$path"
    else
      git -c core.autocrlf=false clone --depth 1 "$url" "$path"
    fi
  fi
  local fixed=0 f
  while IFS= read -r f; do
    if grep -qU $'\r' "$f" 2>/dev/null; then
      tr -d '\r' < "$f" > "${f}.lf" && mv "${f}.lf" "$f"
      fixed=$((fixed + 1))
    fi
  done < <(find "$path" -type f \( -name '*.sh' -o -name '*.py' -o -name '*.ts' \
           -o -name '*.js' -o -name '*.cjs' -o -name '*.mjs' -o -name '*.json' \
           -o -name '*.yml' -o -name '*.yaml' -o -name '*.txt' \) 2>/dev/null)
  [ "$fixed" -gt 0 ] && warn "  normalised CR -> LF in $fixed file(s)"
  return 0
}

clone_pinned https://github.com/danny-avila/LibreChat.git       vendor/LibreChat       v0.8.7
clone_pinned https://github.com/ClickHouse/code-interpreter.git vendor/code-interpreter
clone_pinned https://github.com/danny-avila/rag_api.git         vendor/rag_api         v0.8.0

bash ./scripts/services/librechat/patch-oidc.sh

step "2/8  Vendoring Pagila SQL"
./scripts/general/fetch-pagila.sh

step "3/8  Generating secrets"
./scripts/general/gen-secrets.sh --apply

foundry_key="$(env_get AZURE_FOUNDRY_API_KEY || true)"
if [ -z "$foundry_key" ] || [[ "$foundry_key" == *CHANGE_ME* ]]; then
  warn ""
  warn "  ACTION REQUIRED: set AZURE_FOUNDRY_API_KEY in config/librechat/.env, then re-run."
  warn "  Verify the Azure Foundry endpoint before enabling the chat profile."
  if [ "$SKIP_CHAT" -eq 0 ]; then
    warn "  (continuing with the data + BI tier only)"
    SKIP_CHAT=1
  fi
fi

step "4/8  Building images"
docker compose build

step "5/8  Userstore + data + BI tier (openldap -> postgres -> cube -> superset)"
docker compose up -d

./scripts/services/ldap/init.sh
./scripts/services/postgres/remove-warehouse-mcp-role.sh

if [ "$SKIP_SANDBOX" -eq 0 ]; then
  step "6/8  Sandbox runtime packages (compiles CPython; 20-45 min, ONCE)"
  ./scripts/services/sandbox/build-packages.sh

  step "6b/8  Sandbox services + Garage bootstrap"
  docker compose --profile sandbox up -d garage
  ./scripts/services/sandbox/init-garage.sh
  docker compose --profile sandbox up -d
else
  step "6/8  Sandbox SKIPPED (--skip-sandbox)"
fi

if [ "$SKIP_CHAT" -eq 0 ]; then
  step "7/8  Agent tier (MCP servers + rag-api + LibreChat)"
  docker compose --profile chat up -d

  wait_healthy abi-authentik-server 300 || die "authentik did not become healthy in 300s"
  wait_healthy abi-meilisearch 120 || die "meilisearch did not become healthy in 120s"
  wait_healthy abi-librechat 300 || die "librechat did not become healthy in 300s"
  wait_http_status "http://localhost:$(env_get CUBE_MCP_HOST_PORT || echo 8003)/mcp" 401 120 || \
    die "Cube MCP did not expose its OAuth-protected endpoint in 120s"
  cube_sql_mcp_port="$(env_get CUBE_SQL_MCP_HOST_PORT || true)"
  wait_http_status "http://localhost:${cube_sql_mcp_port:-8004}/mcp" 401 120 || \
    die "Cube SQL MCP did not expose its OAuth-protected endpoint in 120s"
  wait_healthy abi-superset-mcp 300 || die "superset MCP did not become healthy in 300s"

  bash ./scripts/services/authentik/remove-warehouse-mcp.sh
  bash ./scripts/services/librechat/migrate-oidc.sh
else
  step "7/8  Agent tier SKIPPED"
fi

step "8/8  Runtime startup complete"

cat <<EOF

  Authentik SSO opens LibreChat with the same LDAP credentials used by Superset.
  LibreChat redirects to http://authentik.localhost:9000; log in with the full
  e-mail and matching DEMO_*_PASSWORD from config/ldap/.env.

  Superset dashboard : http://localhost:8088/superset/dashboard/agentic-bi/
                       admin@demo.local / DEMO_ADMIN_PASSWORD
  LibreChat          : http://localhost:3080
                       analyst@demo.local / DEMO_ANALYST_PASSWORD
                       admin@demo.local   / DEMO_ADMIN_PASSWORD

  Each user's first LibreChat sign-in automatically creates their managed agents.
  Cube OAuth consent ties every analyst query to the signed LDAP identity, so the
  role follows the login, not the agent.

  Cube SQL API       : psql -h localhost -p 15432 -U analyst@demo.local -d cube
EOF
