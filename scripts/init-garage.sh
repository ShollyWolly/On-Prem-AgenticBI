#!/usr/bin/env bash

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ACCESS_KEY="$(env_require MINIO_ACCESS_KEY)"
SECRET_KEY="$(env_require MINIO_SECRET_KEY)"
BUCKET="$(env_get MINIO_BUCKET || echo codeapi-files)"
[ -n "$BUCKET" ] || BUCKET=codeapi-files

case "$ACCESS_KEY" in
  GK*) : ;;
esac

container_running abi-garage || die "garage is not running. Start it with: docker compose --profile sandbox up -d garage"

g() { dexec abi-garage /garage -c /etc/garage.toml "$@"; }

step "Garage: waiting for the daemon"
for _ in $(seq 1 30); do
  if g status >/dev/null 2>&1; then break; fi
  sleep 2
done
g status >/dev/null 2>&1 || die "garage did not become responsive (see: docker compose logs garage)"

NODE_ID="$(g status 2>/dev/null | awk '/^==== HEALTHY NODES ====/{f=1;next} f && NF && $1 !~ /^ID$/ {print $1; exit}')"
[ -n "$NODE_ID" ] || NODE_ID="$(g node id -q 2>/dev/null | cut -d@ -f1)"
[ -n "$NODE_ID" ] || die "could not determine the garage node id"

if g status 2>/dev/null | grep -qi 'NO ROLE ASSIGNED'; then
  step "Garage: assigning layout to node ${NODE_ID:0:16}"
  g layout assign -z dc1 -c 10G "$NODE_ID"
  g layout apply --version 1
  ok "  layout applied"
else
  dim "layout already assigned"
fi

if g key info "$ACCESS_KEY" >/dev/null 2>&1; then
  dim "S3 key already imported"
else
  step "Garage: importing S3 key"
  g key import --yes -n codeapi "$ACCESS_KEY" "$SECRET_KEY"
  ok "  key imported"
fi

if g bucket info "$BUCKET" >/dev/null 2>&1; then
  dim "bucket '$BUCKET' already exists"
else
  step "Garage: creating bucket '$BUCKET'"
  g bucket create "$BUCKET"
  ok "  bucket created"
fi

g bucket allow --read --write "$BUCKET" --key "$ACCESS_KEY" >/dev/null
ok "Garage ready: bucket '$BUCKET' readable/writable by ${ACCESS_KEY:0:8}..."
