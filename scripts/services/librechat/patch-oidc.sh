#!/usr/bin/env bash

# This script applies the maintained OIDC integration patch to the pinned LibreChat source.
source "$(dirname "${BASH_SOURCE[0]}")/../../general/lib.sh"

SOURCE="${REPO_ROOT}/vendor/LibreChat/api/strategies/openidStrategy.js"
PATCH_FILE="${REPO_ROOT}/docker/librechat/openid-strategy.patch"
HOOK_SOURCE="${REPO_ROOT}/docker/librechat/oidc-agent-provisioning.js"
HOOK_TARGET="${REPO_ROOT}/vendor/LibreChat/api/server/services/oidc-agent-provisioning.js"
PROVISION_SOURCE="${REPO_ROOT}/docker/librechat/provision-existing-oidc-agents.js"
PROVISION_TARGET="${REPO_ROOT}/vendor/LibreChat/api/server/services/provision-existing-oidc-agents.js"
[ -f "$SOURCE" ] || die "missing $SOURCE; run ./bootstrap.sh to vendor LibreChat"
[ -f "$PATCH_FILE" ] || die "missing $PATCH_FILE"
[ -f "$HOOK_SOURCE" ] || die "missing $HOOK_SOURCE"
[ -f "$PROVISION_SOURCE" ] || die "missing $PROVISION_SOURCE"

if git -C "${REPO_ROOT}/vendor/LibreChat" apply --reverse --check "$PATCH_FILE" 2>/dev/null; then
  dim "LibreChat OIDC patch already applied"
else
  git -C "${REPO_ROOT}/vendor/LibreChat" apply --check "$PATCH_FILE" || \
    die "LibreChat OIDC patch does not apply; the pinned upstream source may have changed"
  git -C "${REPO_ROOT}/vendor/LibreChat" apply "$PATCH_FILE"
  ok "Applied LibreChat OIDC integration patch"
fi

install -m 0644 "$HOOK_SOURCE" "$HOOK_TARGET"
install -m 0644 "$PROVISION_SOURCE" "$PROVISION_TARGET"
