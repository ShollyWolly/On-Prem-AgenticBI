#!/usr/bin/env bash

# This script creates ignored service environment files while preserving existing local secrets.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

APPLY=0
FORCE=0
for arg in "$@"; do
  case "$arg" in
    --apply) APPLY=1 ;;
    --force) FORCE=1 ;;
    --help|-h)
      cat <<'EOF'
Usage: bash ./scripts/general/gen-secrets.sh [--apply] [--force]

Creates ignored service-local environment files from their tracked examples.
It generates secure local values for CHANGE_ME placeholders and keeps values
shared by multiple services identical. When migrating an existing root .env,
it preserves each current value and reduces the root file to Compose-wide ports
and CUBE_MODE. Azure Foundry values are copied only to the ignored shared
Foundry environment file and are never included in a tracked example.
EOF
      exit 0
      ;;
    *) die "unknown argument: $arg" ;;
  esac
done

examples=(
  "config/ldap/.env.example"
  "config/postgres/.env.example"
  "config/cube/env/.env.example"
  "config/mcp/cube/.env.example"
  "config/mcp/cube-sql/.env.example"
  "config/superset/.env.example"
  "config/authentik/postgres.env.example"
  "config/authentik/.env.example"
  "config/librechat/extensions/meilisearch/.env.example"
  "config/librechat/extensions/rag-api/.env.example"
  "config/foundry/.env.example"
  "config/librechat/.env.example"
  "config/mcp/verified-sql/.env.example"
  "config/audit/core/.env.example"
  "config/audit/writer/.env.example"
  "config/audit/console/.env.example"
  "config/librechat/extensions/sandbox/.env.example"
)

command -v openssl >/dev/null || die "openssl is required"

declare -A GENERATED_VALUES=()

is_placeholder() {
  [[ "$1" == CHANGE_ME_* ]]
}

secret_key_for() {
  local example="$1" key="$2"
  case "${example}:${key}" in
    config/cube/env/.env.example:CUBEJS_DB_PASS) printf '%s' CUBE_DB_PASSWORD ;;
    config/superset/.env.example:SUPERSET_ADMIN_PASSWORD) printf '%s' DEMO_ADMIN_PASSWORD ;;
    config/superset/.env.example:CUBE_SQL_PASSWORD) printf '%s' CUBEJS_SQL_PASSWORD ;;
    config/authentik/postgres.env.example:POSTGRES_PASSWORD) printf '%s' AUTHENTIK_POSTGRES_PASSWORD ;;
    config/authentik/.env.example:AUTHENTIK_POSTGRESQL__PASSWORD) printf '%s' AUTHENTIK_POSTGRES_PASSWORD ;;
    config/librechat/extensions/rag-api/.env.example:POSTGRES_PASSWORD) printf '%s' VECTOR_DB_PASSWORD ;;
    config/librechat/.env.example:OPENID_CLIENT_SECRET) printf '%s' AUTHENTIK_LIBRECHAT_CLIENT_SECRET ;;
    config/ldap/.env.example:LDAP_CONFIG_PASSWORD) printf '%s' LDAP_ADMIN_PASSWORD ;;
    config/librechat/extensions/sandbox/.env.example:REDIS_PASSWORD) printf '%s' CODEAPI_REDIS_PASSWORD ;;
    *) printf '%s' "$key" ;;
  esac
}

generate_for() {
  case "$1" in
    AUTHENTIK_SECRET_KEY|AUTHENTIK_BOOTSTRAP_TOKEN|CUBEJS_API_SECRET|CREDS_KEY|JWT_SECRET|JWT_REFRESH_SECRET|OPENID_SESSION_SECRET|GARAGE_RPC_SECRET|GARAGE_ADMIN_TOKEN|MINIO_SECRET_KEY|AUDIT_CONTEXT_HMAC_KEY|AUDIT_CONSOLE_SESSION_SECRET)
      rand_hex 32 ;;
    AUDIT_PAYLOAD_ENCRYPTION_KEY)
      openssl rand -base64 32 | tr '+/' '-_' ;;
    CREDS_IV)
      rand_hex 16 ;;
    MINIO_ACCESS_KEY)
      rand_garage_key ;;
    CODEAPI_INTERNAL_SERVICE_TOKEN|CODEAPI_EGRESS_GRANT_SECRET)
      rand_b64 32 ;;
    POSTGRES_PASSWORD|SUPERSET_DB_PASSWORD|CUBE_DB_PASSWORD|VECTOR_DB_PASSWORD|LDAP_ADMIN_PASSWORD|DEMO_ANALYST_PASSWORD|DEMO_ADMIN_PASSWORD|AUTHENTIK_POSTGRES_PASSWORD|AUTHENTIK_BOOTSTRAP_PASSWORD|AUTHENTIK_LIBRECHAT_CLIENT_SECRET|AUTHENTIK_AUDIT_CONSOLE_CLIENT_SECRET|CUBEJS_SQL_PASSWORD|SUPERSET_SECRET_KEY|SUPERSET_MCP_READER_PASSWORD|MEILI_MASTER_KEY|CODEAPI_REDIS_PASSWORD|AUDIT_WRITER_PASSWORD|AUDIT_READER_PASSWORD)
      rand_alnum 32 ;;
    *) return 1 ;;
  esac
}

generated_value() {
  local key="$1" value
  value="${GENERATED_VALUES[$key]:-}"
  if [ -z "$value" ]; then
    value="$(generate_for "$key")" || die "no generator is configured for ${key}"
    GENERATED_VALUES["$key"]="$value"
  fi
  GENERATED_VALUE="$value"
}

legacy_value() {
  local key="$1"
  [ -f "$ENV_FILE" ] || return 1
  sed -n "s/^${key}=//p" "$ENV_FILE" | head -n1
}

file_value() {
  local file="$1" key="$2"
  [ -f "$file" ] || return 1
  sed -n "s/^${key}=//p" "$file" | head -n1
}

legacy_key_for() {
  local example="$1" key="$2"
  case "${example}:${key}" in
    config/cube/env/.env.example:CUBEJS_DB_NAME) printf '%s' POSTGRES_DB ;;
    config/cube/env/.env.example:CUBEJS_DB_USER) printf '%s' CUBE_DB_USER ;;
    config/cube/env/.env.example:CUBEJS_DB_PASS) printf '%s' CUBE_DB_PASSWORD ;;
    config/superset/.env.example:SUPERSET_ADMIN_PASSWORD) printf '%s' DEMO_ADMIN_PASSWORD ;;
    config/superset/.env.example:CUBE_SQL_USER) printf '%s' SUPERSET_CUBE_SQL_USER ;;
    config/superset/.env.example:CUBE_SQL_PASSWORD) printf '%s' CUBEJS_SQL_PASSWORD ;;
    config/authentik/postgres.env.example:POSTGRES_PASSWORD) printf '%s' AUTHENTIK_POSTGRES_PASSWORD ;;
    config/authentik/.env.example:AUTHENTIK_POSTGRESQL__PASSWORD) printf '%s' AUTHENTIK_POSTGRES_PASSWORD ;;
    config/librechat/extensions/rag-api/.env.example:POSTGRES_DB) printf '%s' VECTOR_DB_NAME ;;
    config/librechat/extensions/rag-api/.env.example:POSTGRES_USER) printf '%s' VECTOR_DB_USER ;;
    config/librechat/extensions/rag-api/.env.example:POSTGRES_PASSWORD) printf '%s' VECTOR_DB_PASSWORD ;;
    config/librechat/.env.example:OPENID_CLIENT_ID) printf '%s' AUTHENTIK_LIBRECHAT_CLIENT_ID ;;
    config/librechat/.env.example:OPENID_CLIENT_SECRET) printf '%s' AUTHENTIK_LIBRECHAT_CLIENT_SECRET ;;
    config/ldap/.env.example:LDAP_CONFIG_PASSWORD) printf '%s' LDAP_ADMIN_PASSWORD ;;
    config/librechat/extensions/sandbox/.env.example:REDIS_PASSWORD) printf '%s' CODEAPI_REDIS_PASSWORD ;;
    *) printf '%s' "$key" ;;
  esac
}

write_target() {
  local example="$1" target="${example%.example}" tmp key value legacy_key secret_key
  tmp="$(mktemp)"
  while IFS= read -r line || [ -n "$line" ]; do
    if [[ "$line" =~ ^([A-Z0-9_]+)=(.*)$ ]]; then
      key="${BASH_REMATCH[1]}"
      value=""
      case "${example}:${key}" in
        config/authentik/postgres.env.example:POSTGRES_DB|config/authentik/postgres.env.example:POSTGRES_USER)
          value="${BASH_REMATCH[2]}"
          ;;
        *)
          legacy_key="$(legacy_key_for "$example" "$key")"
          if [ "$FORCE" -eq 0 ]; then
            value="$(legacy_value "$legacy_key" || true)"
          fi
          ;;
      esac
      if [ "$example" = "config/superset/.env.example" ] && [ "$key" = "SUPERSET_METADATA_URI" ]; then
        password="$(legacy_value SUPERSET_DB_PASSWORD || true)"
        user="$(legacy_value SUPERSET_DB_USER || true)"
        database="$(legacy_value SUPERSET_DB_NAME || true)"
        if [ -n "$password" ]; then
          value="postgresql+psycopg2://${user:-superset}:${password}@postgres:5432/${database:-superset}"
        fi
      fi
      if [ -z "$value" ]; then
        case "${example}:${key}" in
          config/ldap/.env.example:LDAP_CONFIG_PASSWORD)
            value="$(file_value "$target" LDAP_ADMIN_PASSWORD || true)"
            ;;
          config/authentik/.env.example:AUTHENTIK_POSTGRESQL__PASSWORD)
            value="$(file_value "$target" AUTHENTIK_POSTGRES_PASSWORD || true)"
            ;;
          config/librechat/extensions/sandbox/.env.example:REDIS_PASSWORD)
            value="$(file_value "$target" CODEAPI_REDIS_PASSWORD || true)"
            ;;
          config/superset/.env.example:SUPERSET_METADATA_URI)
            password="$(file_value config/postgres/.env SUPERSET_DB_PASSWORD || true)"
            user="$(file_value config/postgres/.env SUPERSET_DB_USER || true)"
            database="$(file_value config/postgres/.env SUPERSET_DB_NAME || true)"
            if [ -n "$password" ]; then
              value="postgresql+psycopg2://${user:-superset}:${password}@postgres:5432/${database:-superset}"
            fi
            ;;
        esac
      fi
      if [ -z "$value" ] && [ "$FORCE" -eq 0 ]; then
        value="$(file_value "$target" "$key" || true)"
      fi
      [ -n "$value" ] || value="${BASH_REMATCH[2]}"
      if is_placeholder "$value"; then
        secret_key="$(secret_key_for "$example" "$key")"
        generated_value "$secret_key"
        value="$GENERATED_VALUE"
      fi
      printf '%s=%s\n' "$key" "$value" >> "$tmp"
    else
      printf '%s\n' "$line" >> "$tmp"
    fi
  done < "$example"

  if [ "$example" = "config/foundry/.env.example" ]; then
    for key in AZURE_FOUNDRY_BASE_URL AZURE_FOUNDRY_API_KEY AZURE_FOUNDRY_MODEL AZURE_FOUNDRY_TITLE_MODEL; do
      value="$(legacy_value "$key" || true)"
      [ -n "$value" ] || value="$(file_value "$target" "$key" || true)"
      [ -n "$value" ] || value="$(file_value config/librechat/.env "$key" || true)"
      [ -n "$value" ] && printf '%s=%s\n' "$key" "$value" >> "$tmp"
    done
  fi

  if [ "$APPLY" -eq 1 ]; then
    mkdir -p "$(dirname "$target")"
    cp "$tmp" "$target"
    ok "Wrote ${target}"
  else
    dim "Would write ${target}"
  fi
  rm -f "$tmp"
}

for example in "${examples[@]}"; do
  [ -f "${REPO_ROOT}/${example}" ] || die "${example} is missing"
  (cd "$REPO_ROOT" && write_target "$example")
done

root_example="${REPO_ROOT}/.env.example"
[ -f "$root_example" ] || die ".env.example is missing"
root_tmp="$(mktemp)"
while IFS= read -r line || [ -n "$line" ]; do
  if [[ "$line" =~ ^([A-Z0-9_]+)=(.*)$ ]]; then
    key="${BASH_REMATCH[1]}"
    value="$(legacy_value "$key" || true)"
    [ -n "$value" ] || value="${BASH_REMATCH[2]}"
    printf '%s=%s\n' "$key" "$value" >> "$root_tmp"
  else
    printf '%s\n' "$line" >> "$root_tmp"
  fi
done < "$root_example"

if [ "$APPLY" -eq 1 ]; then
  cp "$root_tmp" "$ENV_FILE"
  ok "Reduced .env to Compose-wide settings"
else
  dim "Would reduce .env to Compose-wide settings"
fi
rm -f "$root_tmp"

if [ "$APPLY" -eq 0 ]; then
  info "Dry run complete. Re-run with --apply to migrate the local environment."
fi
