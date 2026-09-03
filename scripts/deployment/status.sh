#!/usr/bin/env bash

# This lifecycle command reports the state of the selected Compose profiles.
source "$(dirname "${BASH_SOURCE[0]}")/../general/lib.sh"

usage() {
  cat <<'EOF'
Usage: bash ./scripts/deployment/status.sh [--profile chat|sandbox|cubestore]...

Shows Compose service state for the default services and requested profiles.
EOF
}

compose_args=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --profile)
      [ "$#" -ge 2 ] || die "--profile requires chat, sandbox, or cubestore"
      case "$2" in
        chat|sandbox|cubestore) compose_args+=(--profile "$2") ;;
        *) die "unknown profile: $2" ;;
      esac
      shift 2
      ;;
    --help|-h) usage; exit 0 ;;
    *) die "unknown argument: $1 (use --help)" ;;
  esac
done

compose "${compose_args[@]}" ps
