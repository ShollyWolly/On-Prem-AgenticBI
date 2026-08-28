#!/usr/bin/env bash

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
