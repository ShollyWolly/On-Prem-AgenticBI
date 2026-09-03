#!/usr/bin/env bash

# This lifecycle command starts an existing bootstrapped stack and reruns safe initializers.
source "$(dirname "${BASH_SOURCE[0]}")/../general/lib.sh"

usage() {
  cat <<'EOF'
Usage: bash ./scripts/deployment/up.sh [--profile chat|sandbox|cubestore]...

Starts the default data and BI services, then starts each requested optional
profile. The command reconciles LDAP on every run, prepares the vector database
before the chat profile, and initializes Garage before the sandbox services.

Bootstrap remains responsible for secrets, vendored sources, images, and the
sandbox package build: bash ./bootstrap.sh
EOF
}

profiles=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --profile)
      [ "$#" -ge 2 ] || die "--profile requires chat, sandbox, or cubestore"
      case "$2" in
        chat|sandbox|cubestore) profiles+=("$2") ;;
        *) die "unknown profile: $2" ;;
      esac
      shift 2
      ;;
    --help|-h) usage; exit 0 ;;
    *) die "unknown argument: $1 (use --help)" ;;
  esac
done

has_profile() {
  local wanted="$1" profile
  for profile in "${profiles[@]}"; do
    [ "$profile" = "$wanted" ] && return 0
  done
  return 1
}

require_vendor() {
  local path="$1"
  [ -d "${REPO_ROOT}/${path}" ] || die "${path} is missing; run bash ./bootstrap.sh first"
}

for required_env in \
  "$ENV_FILE" \
  "${REPO_ROOT}/config/ldap/.env" \
  "${REPO_ROOT}/config/postgres/.env" \
  "${REPO_ROOT}/config/cube/env/.env" \
  "${REPO_ROOT}/config/superset/.env" \
  "${REPO_ROOT}/config/audit/core/.env" \
  "${REPO_ROOT}/config/audit/writer/.env" \
  "${REPO_ROOT}/config/audit/console/.env"; do
  [ -f "$required_env" ] || die "${required_env} is missing; run bash ./scripts/general/gen-secrets.sh --apply first"
done

if has_profile chat; then
  for required_env in \
    "${REPO_ROOT}/config/authentik/.env" \
    "${REPO_ROOT}/config/foundry/.env" \
    "${REPO_ROOT}/config/librechat/.env" \
    "${REPO_ROOT}/config/librechat/extensions/meilisearch/.env" \
    "${REPO_ROOT}/config/librechat/extensions/rag-api/.env" \
    "${REPO_ROOT}/config/mcp/verified-sql/.env"; do
    [ -f "$required_env" ] || die "${required_env} is missing; run bash ./scripts/general/gen-secrets.sh --apply first"
  done
fi

if has_profile sandbox; then
  [ -f "${REPO_ROOT}/config/librechat/extensions/sandbox/.env" ] || \
    die "config/librechat/extensions/sandbox/.env is missing; run bash ./scripts/general/gen-secrets.sh --apply first"
fi

if has_profile chat; then
  require_vendor vendor/LibreChat
  require_vendor vendor/rag_api
fi
if has_profile sandbox; then
  require_vendor vendor/code-interpreter
fi

step "Starting default data and BI services"
compose up -d
wait_healthy abi-openldap 180 || die "openldap did not become healthy in 180s"
wait_healthy abi-postgres 360 || die "postgres did not become healthy in 360s"
bash "${REPO_ROOT}/scripts/services/ldap/init.sh"
bash "${REPO_ROOT}/scripts/services/postgres/remove-warehouse-mcp-role.sh"
bash "${REPO_ROOT}/scripts/services/postgres/init-audit.sh"

if has_profile chat; then
  step "Preparing the chat profile"
  bash "${REPO_ROOT}/scripts/services/postgres/init-vectordb.sh"
  compose --profile chat up -d
  wait_healthy abi-mongodb 120 || die "mongodb did not become healthy in 120s"
  wait_healthy abi-authentik-server 300 || die "authentik did not become healthy in 300s"
  authentik_port="$(env_get AUTHENTIK_HOST_PORT || echo 9000)"
  wait_http_status "http://localhost:$authentik_port/application/o/librechat/.well-known/openid-configuration" 200 300 || \
    die "Authentik did not publish LibreChat OIDC discovery in 300s"
  compose --profile chat up -d --no-deps --force-recreate librechat
  wait_healthy abi-librechat 300 || die "librechat did not become healthy in 300s"
  bash "${REPO_ROOT}/scripts/services/authentik/remove-warehouse-mcp.sh"
  bash "${REPO_ROOT}/scripts/services/librechat/migrate-oidc.sh"
fi

if has_profile sandbox; then
  step "Preparing the sandbox profile"
  compose --profile sandbox up -d garage
  wait_healthy abi-garage 180 || die "garage did not become healthy in 180s"
  bash "${REPO_ROOT}/scripts/services/sandbox/init-garage.sh"
  compose --profile sandbox up -d
fi

if has_profile cubestore; then
  step "Starting the CubeStore profile"
  compose --profile cubestore up -d
fi

ok "Requested services are running"
