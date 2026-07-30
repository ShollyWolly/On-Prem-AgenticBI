#!/usr/bin/env bash
# Provision the demo agents in LibreChat.
#
# Wrapper around scripts/provision_agent.py, which runs on the HOST using only the
# standard library, so it needs no pip install and no container to borrow.
#
# This script is the only supported route: agents cannot be declared in
# librechat.yaml (issue #7741), and the UI cannot set
# tool_options.allowed_callers.
#
# Usage: scripts/provision-agent.sh [--allow-direct]
#   Cube tools default to code_execution-only, which forces the model to write
#   Python to reach them. --allow-direct permits both call paths.

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

[ "${1:-}" = "--allow-direct" ] && export ALLOW_DIRECT=1

container_running abi-librechat || die "librechat is not running. Start it with: docker compose --profile chat up -d"

command -v python >/dev/null 2>&1 && PY=python || PY=python3
command -v "$PY" >/dev/null 2>&1 || die "python is required on the host to run scripts/provision_agent.py"

export LIBRECHAT_URL="${LIBRECHAT_URL:-http://localhost:$(env_get LIBRECHAT_HOST_PORT || echo 3080)}"
export DEMO_ANALYST_EMAIL="$(env_require DEMO_ANALYST_EMAIL)"
export DEMO_ANALYST_PASSWORD="$(env_require DEMO_ANALYST_PASSWORD)"
export DEMO_ADMIN_EMAIL="$(env_require DEMO_ADMIN_EMAIL)"
export DEMO_ADMIN_PASSWORD="$(env_require DEMO_ADMIN_PASSWORD)"
export AZURE_FOUNDRY_MODEL="$(env_require AZURE_FOUNDRY_MODEL)"

"$PY" "${REPO_ROOT}/scripts/provision_agent.py"

if [ -z "${ALLOW_DIRECT:-}" ]; then
  dim "Cube tools are code_execution-only, so the model MUST write Python to reach them."
fi
