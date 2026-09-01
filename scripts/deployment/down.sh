#!/usr/bin/env bash

source "$(dirname "${BASH_SOURCE[0]}")/../general/lib.sh"

usage() {
  cat <<'EOF'
Usage: bash ./scripts/deployment/down.sh [--profile chat|sandbox|cubestore]... [--volumes]

Stops and removes this Compose project. Profile flags are accepted to mirror the
other lifecycle commands, but Docker Compose teardown applies to the whole
project. --volumes also removes named local data volumes and is irreversible.
EOF
}

profiles=()
remove_volumes=0
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
    --volumes) remove_volumes=1; shift ;;
    --help|-h) usage; exit 0 ;;
    *) die "unknown argument: $1 (use --help)" ;;
  esac
done

compose_args=()
for profile in "${profiles[@]}"; do
  compose_args+=(--profile "$profile")
done

if [ "$remove_volumes" -eq 1 ]; then
  warn "Removing all Compose volumes for this project; local data cannot be recovered."
  compose "${compose_args[@]}" down --volumes
else
  compose "${compose_args[@]}" down
fi
