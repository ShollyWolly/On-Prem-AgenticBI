#!/usr/bin/env bash

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ENV_FILE="${REPO_ROOT}/.env"
SERVICE_ENV_FILES=(
  "${REPO_ROOT}/config/ldap/.env"
  "${REPO_ROOT}/config/postgres/.env"
  "${REPO_ROOT}/config/cube/env/.env"
  "${REPO_ROOT}/config/cube-mcp/.env"
  "${REPO_ROOT}/config/cube-sql-mcp/.env"
  "${REPO_ROOT}/config/superset/.env"
  "${REPO_ROOT}/config/authentik/.env"
  "${REPO_ROOT}/config/meilisearch/.env"
  "${REPO_ROOT}/config/rag-api/.env"
  "${REPO_ROOT}/config/librechat/.env"
  "${REPO_ROOT}/config/sandbox/.env"
)

if [ -t 1 ]; then
  C_RESET=$'\033[0m'; C_RED=$'\033[31m'; C_GREEN=$'\033[32m'
  C_YELLOW=$'\033[33m'; C_CYAN=$'\033[36m'; C_DIM=$'\033[2m'
else
  C_RESET=''; C_RED=''; C_GREEN=''; C_YELLOW=''; C_CYAN=''; C_DIM=''
fi

info()  { printf '%s%s%s\n' "$C_CYAN"   "$*" "$C_RESET"; }
ok()    { printf '%s%s%s\n' "$C_GREEN"  "$*" "$C_RESET"; }
warn()  { printf '%s%s%s\n' "$C_YELLOW" "$*" "$C_RESET"; }
err()   { printf '%s%s%s\n' "$C_RED"    "$*" "$C_RESET" >&2; }
dim()   { printf '%s%s%s\n' "$C_DIM"    "$*" "$C_RESET"; }
step()  { printf '\n%s=== %s ===%s\n' "$C_CYAN" "$*" "$C_RESET"; }

die() { err "$*"; exit 1; }

env_get() {
  local key="$1" file value
  if [ "$#" -gt 1 ]; then
    file="$2"
    [ -f "$file" ] || return 1
    sed -n "s/^${key}=//p" "$file" | head -n1
    return 0
  fi
  for file in "$ENV_FILE" "${SERVICE_ENV_FILES[@]}"; do
    [ -f "$file" ] || continue
    value="$(sed -n "s/^${key}=//p" "$file" | head -n1)"
    [ -n "$value" ] && printf '%s' "$value" && return 0
  done
  return 1
}

env_require() {
  local key="$1" val
  val="$(env_get "$key" || true)"
  [ -n "$val" ] || die "$key is missing from its local environment file (run scripts/general/gen-secrets.sh --apply)"
  printf '%s' "$val"
}

rand_hex()   { openssl rand -hex "$1"; }
rand_b64()   { openssl rand -base64 "$1"; }

rand_alnum() {
  local want="$1" out=""
  while [ "${#out}" -lt "$want" ]; do
    out="${out}$(openssl rand -base64 $(( want * 2 )) | LC_ALL=C tr -dc 'A-Za-z0-9')"
  done
  printf '%.*s' "$want" "$out"
}

rand_garage_key() { printf 'GK%s' "$(openssl rand -hex 12)"; }

host_path() {
  if command -v cygpath >/dev/null 2>&1; then cygpath -w "$1"; else printf '%s' "$1"; fi
}

dexec() { MSYS_NO_PATHCONV=1 docker exec "$@"; }

dcp_to() { MSYS_NO_PATHCONV=1 docker cp "$(host_path "$1")" "$2"; }

compose() { ( cd "$REPO_ROOT" && docker compose "$@" ); }

compose_x() { ( cd "$REPO_ROOT" && MSYS_NO_PATHCONV=1 docker compose "$@" ); }
docker_x()  { MSYS_NO_PATHCONV=1 docker "$@"; }

container_running() {
  [ -n "$(docker ps --filter "name=$1" --format '{{.Names}}' 2>/dev/null)" ]
}

wait_healthy() {
  local name="$1" timeout="${2:-300}" waited=0 state
  while [ "$waited" -lt "$timeout" ]; do
    state="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$name" 2>/dev/null || echo missing)"
    case "$state" in
      healthy|running) return 0 ;;
      unhealthy)       return 1 ;;
    esac
    sleep 5; waited=$((waited + 5))
  done
  return 1
}

wait_http_status() {
  local url="$1" expected="$2" timeout="${3:-120}" waited=0 status
  while [ "$waited" -lt "$timeout" ]; do
    status="$(curl -sS --connect-timeout 2 --max-time 4 -o /dev/null \
      -w '%{http_code}' "$url" 2>/dev/null || true)"
    [ "$status" = "$expected" ] && return 0
    sleep 3; waited=$((waited + 3))
  done
  return 1
}
