#!/usr/bin/env bash

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

APPLY=0
FORCE=0
for arg in "$@"; do
  case "$arg" in
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
    AUTHENTIK_SECRET_KEY)            rand_hex 32 ;;
    AUTHENTIK_POSTGRES_PASSWORD)    rand_alnum 28 ;;
    AUTHENTIK_BOOTSTRAP_PASSWORD)   rand_alnum 28 ;;
    AUTHENTIK_BOOTSTRAP_TOKEN)      rand_hex 32 ;;
    AUTHENTIK_LIBRECHAT_CLIENT_SECRET) rand_alnum 40 ;;
    CUBEJS_SQL_PASSWORD)            rand_alnum 42 ;;
    SUPERSET_MCP_READER_PASSWORD)   rand_alnum 24 ;;
    DEMO_ANALYST_PASSWORD)          rand_alnum 20 ;;
    DEMO_ADMIN_PASSWORD)            rand_alnum 20 ;;
    CREDS_KEY)                      rand_hex 32 ;;
    CREDS_IV)                       rand_hex 16 ;;
    JWT_SECRET)                     rand_hex 32 ;;
    JWT_REFRESH_SECRET)             rand_hex 32 ;;
    OPENID_SESSION_SECRET)          rand_hex 32 ;;
    CODEAPI_INTERNAL_SERVICE_TOKEN) rand_b64 32 ;;
    CODEAPI_EGRESS_GRANT_SECRET)    rand_b64 32 ;;
    CODEAPI_REDIS_PASSWORD)         rand_alnum 28 ;;
    GARAGE_RPC_SECRET)              rand_hex 32 ;;
    GARAGE_ADMIN_TOKEN)             rand_hex 32 ;;
    MINIO_ACCESS_KEY)               rand_garage_key ;;
    MINIO_SECRET_KEY)               rand_hex 32 ;;
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
