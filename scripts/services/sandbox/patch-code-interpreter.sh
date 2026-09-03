#!/usr/bin/env bash

# This script applies the maintained Bun dependency retry patch to the pinned Code Interpreter source.
source "$(dirname "${BASH_SOURCE[0]}")/../../general/lib.sh"

SOURCE_DIR="${REPO_ROOT}/vendor/code-interpreter"
PATCH_FILE="${REPO_ROOT}/docker/codeapi/bun-install.patch"

[ -d "$SOURCE_DIR/.git" ] || die "missing $SOURCE_DIR; run ./bootstrap.sh to vendor Code Interpreter"
[ -f "$PATCH_FILE" ] || die "missing $PATCH_FILE"

if git -C "$SOURCE_DIR" apply --reverse --check "$PATCH_FILE" 2>/dev/null; then
  dim "Code Interpreter Bun retry patch already applied"
else
  git -C "$SOURCE_DIR" apply --check "$PATCH_FILE" || \
    die "Code Interpreter Bun retry patch does not apply; the pinned upstream source may have changed"
  git -C "$SOURCE_DIR" apply "$PATCH_FILE"
  ok "Applied Code Interpreter Bun retry patch"
fi
