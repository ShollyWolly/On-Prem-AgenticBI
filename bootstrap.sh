#!/usr/bin/env bash
# First-run driver: brings an empty checkout to a working demo. The ordering is
# load-bearing. Run once; afterwards plain `docker compose up -d` is enough.
#
# Usage:
#   ./bootstrap.sh                  # everything
#   ./bootstrap.sh --skip-sandbox   # data + BI + agent, no python execution
#   ./bootstrap.sh --skip-chat      # data + BI only

source "$(dirname "${BASH_SOURCE[0]}")/scripts/lib.sh"

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

# -----------------------------------------------------------------------------
step "1/8  Vendoring upstream sources"
# Vendored repositories do not inherit this checkout's .gitattributes. Preserve
# LF line endings while cloning and normalize any text files that do not comply:
#   *.sh -> `#!/bin/sh\r` makes the kernel report "not found", so the sandbox
#           build dies with a bare `exit code: 127` that points nowhere.
#   *.py -> codeapi injects user code by regex-matching `# BEGIN USER CODE\n`.
#           With non-LF endings the match fails SILENTLY, leaving a comment-only function
#           body, so every plot fails with an IndentationError in code the user
#           never wrote.
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
  # Belt and braces, and not only shell scripts (see above).
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
# From source like the other two: the prebuilt image is opaque and publishes only
# :latest. Built with the FULL Dockerfile, never Dockerfile.lite -- lite drops
# sentence-transformers and can then only call a remote embedder.
clone_pinned https://github.com/danny-avila/rag_api.git         vendor/rag_api         v0.8.0

# -----------------------------------------------------------------------------
step "2/8  Vendoring Pagila SQL"
./scripts/fetch-pagila.sh

# -----------------------------------------------------------------------------
step "3/8  Generating secrets"
./scripts/gen-secrets.sh --apply

foundry_key="$(env_get AZURE_FOUNDRY_API_KEY || true)"
if [ -z "$foundry_key" ] || [[ "$foundry_key" == *CHANGE_ME* ]]; then
  warn ""
  warn "  ACTION REQUIRED: set AZURE_FOUNDRY_API_KEY in .env, then re-run."
  warn "  Verify it first with:  ./scripts/verify.sh V11"
  if [ "$SKIP_CHAT" -eq 0 ]; then
    warn "  (continuing with the data + BI tier only)"
    SKIP_CHAT=1
  fi
fi

# -----------------------------------------------------------------------------
step "4/8  Building images"
docker compose build

# -----------------------------------------------------------------------------
step "5/8  Userstore + data + BI tier (openldap -> postgres -> cube -> superset)"
# The date shift asserts on failure, so a bad seed stops the container rather
# than producing an empty dashboard. Superset provisions itself at startup.
docker compose up -d

# The tree must exist before anything authenticates: AUTH_LDAP binds on every
# login, and provision-agent.sh below logs in. Idempotent; asserts its own binds.
./scripts/init-ldap.sh

# -----------------------------------------------------------------------------
if [ "$SKIP_SANDBOX" -eq 0 ]; then
  step "6/8  Sandbox runtime packages (compiles CPython; 20-45 min, ONCE)"
  ./scripts/build-sandbox-packages.sh

  step "6b/8  Sandbox services + Garage bootstrap"
  docker compose --profile sandbox up -d garage
  ./scripts/init-garage.sh
  docker compose --profile sandbox up -d
else
  step "6/8  Sandbox SKIPPED (--skip-sandbox)"
fi

# -----------------------------------------------------------------------------
if [ "$SKIP_CHAT" -eq 0 ]; then
  step "7/8  Agent tier (MCP servers + rag-api + LibreChat)"
  docker compose --profile chat up -d

  # HEALTHY, not merely started: `up -d` returns once the container is running,
  # and provisioning immediately POSTs to /api/auth/login. Against a still-booting
  # Express app that fails with `RemoteDisconnected: Remote end closed connection
  # without response`, which reads like a crash rather than "too early".
  wait_healthy abi-meilisearch 120 || die "meilisearch did not become healthy in 120s"
  wait_healthy abi-librechat 300 || die "librechat did not become healthy in 300s"
  wait_http_status 'http://localhost:8001/sse' 200 120 || \
    die "analyst Postgres MCP did not become ready in 120s"
  wait_http_status 'http://localhost:8002/sse' 200 120 || \
    die "admin Postgres MCP did not become ready in 120s"
  wait_healthy abi-superset-mcp 300 || die "superset MCP did not become healthy in 300s"

  # There is no user-seeding step, and there must not be one: ldapStrategy creates
  # the Mongo user on first login already as provider=ldap, so provision-agent.sh's
  # login seeds them. Seeding locally first would create exactly the provider
  # mismatch the migration below exists to repair.
  #
  # The migration is a no-op once users are provider=ldap, so it is safe here and
  # covers the stack that predates LDAP.
  ./scripts/migrate-librechat-ldap.sh
  ./scripts/provision-agent.sh
else
  step "7/8  Agent tier SKIPPED"
fi

# -----------------------------------------------------------------------------
step "8/8  Verification"
./scripts/verify.sh || warn "some checks failed - see above"

cat <<EOF

-------------------------------------------------------------------
  ONE LDAP credential opens both front doors. Log in with the full e-mail and
  the matching DEMO_*_PASSWORD from .env. There is no separate Superset password:
  admin@demo.local is one identity with one credential.

  Superset dashboard : http://localhost:8088/superset/dashboard/agentic-bi/
                       admin@demo.local / DEMO_ADMIN_PASSWORD
  LibreChat          : http://localhost:3080
                       analyst@demo.local / DEMO_ANALYST_PASSWORD
                       admin@demo.local   / DEMO_ADMIN_PASSWORD

  Two agents per user:
    Pagila BI Analyst  -> the semantic layer. PII masked for analyst,
                          visible for admin. The ROLE FOLLOWS THE AGENT,
                          not the login.
    Dashboard Reviewer -> reads and critiques the Superset charts.
  Both also support file_search for documents attached in chat.

  Cube SQL API       : psql -h localhost -p 15432 -U analyst@demo.local -d cube
-------------------------------------------------------------------
EOF
