#!/usr/bin/env bash
# Generate every secret the stack needs and write them into .env.
#
# Creates .env from .env.example if missing, then replaces each CHANGE_ME
# placeholder with a random value of the right SHAPE for that key. The shapes are
# not interchangeable:
#
#   CREDS_KEY            exactly 64 hex chars  (32 bytes) -- LibreChat won't boot otherwise
#   CREDS_IV             exactly 32 hex chars  (16 bytes) -- ditto
#   CUBEJS_SQL_PASSWORD  [A-Za-z0-9] only -- Superset's provisioning step injects it
#                        into a SQLAlchemy URI with sed and does NOT url-encode it,
#                        so @ : / # ? % would corrupt the connection string
#   MINIO_ACCESS_KEY     "GK" + 24 hex -- Garage's required access-key format
#   GARAGE_RPC_SECRET    exactly 64 hex chars
#
# Idempotent: only CHANGE_ME values are touched. That matters because
# SUPERSET_SECRET_KEY encrypts Superset's stored DB credentials (rotating it is
# NOT self-healing) and CUBEJS_API_SECRET signs Cube's REST API JWTs.
#
# Usage:
#   scripts/gen-secrets.sh            # dry run
#   scripts/gen-secrets.sh --apply    # write .env
#   scripts/gen-secrets.sh --apply --force   # regenerate everything (destructive)

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

APPLY=0
FORCE=0
for arg in "$@"; do
  case "$arg" in
    --apply) APPLY=1 ;;
    --force) FORCE=1 ;;
    *) die "unknown argument: $arg" ;;
  esac
done

command -v openssl >/dev/null || die "openssl is required"

generate_for() {
  case "$1" in
    SUPERSET_SECRET_KEY)            rand_alnum 48 ;;
    CUBEJS_API_SECRET)              rand_hex 32 ;;
    POSTGRES_PASSWORD)              rand_alnum 28 ;;
    SUPERSET_DB_PASSWORD)           rand_alnum 28 ;;
    CUBE_DB_PASSWORD)               rand_alnum 28 ;;
    VECTOR_DB_PASSWORD)             rand_alnum 28 ;;
    LDAP_ADMIN_PASSWORD)            rand_alnum 28 ;;
    CUBEJS_SQL_PASSWORD)            rand_alnum 42 ;;
    SUPERSET_MCP_READER_PASSWORD)   rand_alnum 24 ;;
    DEMO_ANALYST_PASSWORD)          rand_alnum 20 ;;
    DEMO_ADMIN_PASSWORD)            rand_alnum 20 ;;
    CREDS_KEY)                      rand_hex 32 ;;
    CREDS_IV)                       rand_hex 16 ;;
    JWT_SECRET)                     rand_hex 32 ;;
    JWT_REFRESH_SECRET)             rand_hex 32 ;;
    CODEAPI_INTERNAL_SERVICE_TOKEN) rand_b64 32 ;;
    CODEAPI_EGRESS_GRANT_SECRET)    rand_b64 32 ;;
    CODEAPI_REDIS_PASSWORD)         rand_alnum 28 ;;
    GARAGE_RPC_SECRET)              rand_hex 32 ;;
    GARAGE_ADMIN_TOKEN)             rand_hex 32 ;;
    MINIO_ACCESS_KEY)               rand_garage_key ;;
    MINIO_SECRET_KEY)               rand_hex 32 ;;
    *) return 1 ;;
  esac
}

if [ ! -f "$ENV_FILE" ]; then
  [ -f "${REPO_ROOT}/.env.example" ] || die ".env.example not found"
  warn ".env not found - creating from .env.example"
  if [ "$APPLY" -eq 1 ]; then
    cp "${REPO_ROOT}/.env.example" "$ENV_FILE"
  else
    dim "  (dry run: would copy .env.example -> .env)"
  fi
fi

SRC="$ENV_FILE"
[ -f "$SRC" ] || SRC="${REPO_ROOT}/.env.example"

TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT
changed=0

while IFS= read -r line || [ -n "$line" ]; do
  if [[ "$line" =~ ^([A-Z0-9_]+)=(.*)$ ]]; then
    key="${BASH_REMATCH[1]}"
    val="${BASH_REMATCH[2]}"
    if newval="$(generate_for "$key" 2>/dev/null)"; then
      # CHANGE_?ME so a placeholder like CHANGEMEalnum42 (deliberately without an
      # underscore, used where the value must stay alphanumeric) still matches.
      if [ "$FORCE" -eq 1 ] || [ -z "$val" ] || [[ "$val" == *CHANGE_ME* ]] || [[ "$val" == *CHANGEME* ]]; then
        printf '%s=%s\n' "$key" "$newval" >> "$TMP"
        printf '  %-32s <- %s chars\n' "$key" "${#newval}"
        changed=$((changed + 1))
        continue
      fi
    fi
  fi
  printf '%s\n' "$line" >> "$TMP"
done < "$SRC"

if [ "$changed" -eq 0 ]; then
  info "Nothing to do - all secrets already set. Use --force to regenerate (destructive)."
  exit 0
fi

if [ "$APPLY" -eq 1 ]; then
  cp "$TMP" "$ENV_FILE"
  ok ""
  ok "Wrote $changed secret(s) to .env"
  warn "Still to fill in BY HAND: AZURE_FOUNDRY_BASE_URL, AZURE_FOUNDRY_API_KEY, AZURE_FOUNDRY_MODEL"
else
  info ""
  info "Dry run: $changed secret(s) would change. Re-run with --apply."
fi
