#!/usr/bin/env bash

# This wrapper runs all checks or the Cube authorization subset requested by repository operators.
source "$(dirname "${BASH_SOURCE[0]}")/general/lib.sh"

case "${1:-}" in
  "")
    bash "${REPO_ROOT}/scripts/tests/verify-cube-mcp-parity.sh"
    bash "${REPO_ROOT}/scripts/tests/verify-audit.sh"
    ;;
  V1)
    bash "${REPO_ROOT}/scripts/tests/verify-cube-mcp-parity.sh"
    ;;
  *)
    die "usage: $0 [V1]"
    ;;
esac
