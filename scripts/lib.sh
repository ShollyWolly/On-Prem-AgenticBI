#!/usr/bin/env bash
# Shared helpers. Source this, do not execute it.
#
# Bash rather than PowerShell throughout: PowerShell 5.1's Invoke-RestMethod hangs
# indefinitely against LibreChat's API even though the server answers in under a
# second, and cmdlet behaviour differs enough between 5.1 and 7 to be a liability
# in a demo.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${REPO_ROOT}/.env"

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

# Reads .env without sourcing it: values contain characters a shell would
# interpret, e.g. the JSON in CUBE_USER_ROLE_MAP and spaces in LDAP_ORGANISATION.
env_get() {
  local key="$1" file="${2:-$ENV_FILE}"
  [ -f "$file" ] || return 1
  sed -n "s/^${key}=//p" "$file" | head -n1
}

env_require() {
  local key="$1" val
  val="$(env_get "$key" || true)"
  [ -n "$val" ] || die "$key is missing from .env (run scripts/gen-secrets.sh --apply)"
  printf '%s' "$val"
}

rand_hex()   { openssl rand -hex "$1"; }
rand_b64()   { openssl rand -base64 "$1"; }

# Alphanumeric only: used where a value is interpolated without url-encoding,
# notably CUBEJS_SQL_PASSWORD, which Superset's provisioning seds into a URI.
#
# Do NOT rewrite as `tr -dc ... < /dev/urandom | head -c N`. /dev/urandom never
# ends, so head closes the pipe and tr dies with SIGPIPE (141); under the pipefail
# set above, a caller doing `if value="$(rand_alnum 24)"` then takes the FALSE
# branch while holding a perfectly good value. Racy too, so it looks intermittent.
# A finite source (openssl) lets tr reach EOF normally.
rand_alnum() {
  local want="$1" out=""
  while [ "${#out}" -lt "$want" ]; do
    out="${out}$(openssl rand -base64 $(( want * 2 )) | LC_ALL=C tr -dc 'A-Za-z0-9')"
  done
  printf '%.*s' "$want" "$out"
}

# Garage access keys must be "GK" plus exactly 24 hex characters.
rand_garage_key() { printf 'GK%s' "$(openssl rand -hex 12)"; }

# -----------------------------------------------------------------------------
#  Docker wrappers. Git Bash rewrites Unix-looking absolute paths into Windows
#  paths before calling a native .exe, so
#      docker exec abi-garage /garage -c /etc/garage.toml status
#  becomes  docker exec abi-garage "C:/Program Files/Git/garage" ...  and fails as
#  if the container were broken.
#
#  MSYS_NO_PATHCONV=1 stops that, but it must be scoped PER CALL: exported
#  globally, curl.exe stops understanding `-o /dev/null` and `docker cp` gets an
#  unconverted host path and reports `CreateFile C:\c: ...`. Both observed.
#  Inert on Linux and macOS.
# -----------------------------------------------------------------------------
host_path() {
  if command -v cygpath >/dev/null 2>&1; then cygpath -w "$1"; else printf '%s' "$1"; fi
}

dexec() { MSYS_NO_PATHCONV=1 docker exec "$@"; }

dcp_to() { MSYS_NO_PATHCONV=1 docker cp "$(host_path "$1")" "$2"; }

compose() { ( cd "$REPO_ROOT" && docker compose "$@" ); }

# For compose subcommands whose arguments include container paths.
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

# An SSE endpoint intentionally keeps its response open. curl may time out after
# receiving the status, so use that status as the readiness signal.
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
