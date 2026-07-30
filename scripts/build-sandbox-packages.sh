#!/usr/bin/env bash
# Populate the sandbox runtime volume (Python + Node + Bun + libraries). Run ONCE;
# it compiles CPython from source with PGO, so budget 20-45 minutes.
#
# Everything must be baked in ahead of time because executed code has NO NETWORK:
# there is no runtime pip install path. The default manifest already covers the
# demo (pandas, numpy, matplotlib, seaborn, plotly, scikit-learn, ...).
#
# The container route rather than upstream's ./build-packages.sh, because it
# writes to a named volume instead of the source tree and supports
# PYTHON_PACKAGE_INSTALLER=uv.
#
# /pkgs/.initialized is the idempotence marker.
#
# Usage: scripts/build-sandbox-packages.sh [--force]

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

FORCE=0
[ "${1:-}" = "--force" ] && FORCE=1

VOLUME=agentic-bi_codeapi_pkgs
CI_DIR="${REPO_ROOT}/vendor/code-interpreter"
[ -d "$CI_DIR" ] || die "vendor/code-interpreter not found. Run ./bootstrap.sh first."

if [ "$FORCE" -eq 0 ] && docker_x run --rm -v "${VOLUME}:/pkgs" alpine test -f /pkgs/.initialized 2>/dev/null; then
  ok "Sandbox packages already built (/pkgs/.initialized present). Use --force to rebuild."
  exit 0
fi

docker volume create "$VOLUME" >/dev/null

step "Building package-init image"
docker build -f "${CI_DIR}/docker/Dockerfile.package-init" -t codeapi-package-init "$CI_DIR"

step "Populating ${VOLUME} (compiles CPython from source; 20-45 min)"
env_args=(-e PYTHON_PACKAGE_INSTALLER=uv)
[ "$FORCE" -eq 1 ] && env_args+=(-e FORCE_REBUILD=true)
docker_x run --rm -v "${VOLUME}:/pkgs" "${env_args[@]}" codeapi-package-init

step "Verifying"
docker_x run --rm -v "${VOLUME}:/pkgs" alpine sh -c '
  set -e
  test -f /pkgs/.initialized || { echo "MISSING /pkgs/.initialized"; exit 1; }
  for p in pandas matplotlib numpy seaborn plotly; do
    if ls -d /pkgs/python/*/lib/python*/site-packages/$p >/dev/null 2>&1; then
      echo "  ok  $p"
    else
      echo "  MISSING $p"; exit 1
    fi
  done
  echo "  runtimes: $(ls /pkgs | tr "\n" " ")"
  echo "  size: $(du -sh /pkgs | cut -f1)"
'

ok ""
ok "Sandbox packages ready."
