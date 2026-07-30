#!/usr/bin/env bash
# Vendor the Pagila schema + data SQL into config/postgres/initdb.d. Run ONCE, then commit.
#
# Vendoring rather than downloading at container start, because:
#   - the PoC is explicitly on-premise / air-gappable
#   - upstream master moves, so a rebuild months from now could seed different
#     data and silently change every number in the demo
#   - initdb.d then has no network dependency that can fail at boot
#
# Only ONE of the two upstream data files may be loaded. We take pagila-data.sql
# (COPY form, ~3.3 MB) over pagila-insert-data.sql because COPY is far faster.
#
# Usage: scripts/fetch-pagila.sh [--force] [--ref master]

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

FORCE=0
REF=master
while [ $# -gt 0 ]; do
  case "$1" in
    --force) FORCE=1; shift ;;
    --ref)   REF="$2"; shift 2 ;;
    *) die "unknown argument: $1" ;;
  esac
done

DEST="${REPO_ROOT}/config/postgres/initdb.d"
BASE="https://raw.githubusercontent.com/devrimgunduz/pagila/${REF}"
mkdir -p "$DEST"

fetch() {
  local url="$1" out="$2"
  if [ -f "$out" ] && [ "$FORCE" -eq 0 ]; then
    dim "exists, skipping: $(basename "$out")  (use --force to re-download)"
    return
  fi
  info "downloading $url"
  # -f so an HTML error page never lands in a .sql file; binary-safe by default,
  # so no line-ending translation can corrupt the COPY blocks.
  curl -fsSL "$url" -o "$out"
}

fetch "${BASE}/pagila-schema.sql" "${DEST}/10-pagila-schema.sql"
fetch "${BASE}/pagila-data.sql"   "${DEST}/20-pagila-data.sql"

# Record the exact commit so the seed is reproducible.
if sha="$(curl -fsSL -H 'User-Agent: agentic-bi-poc' \
          "https://api.github.com/repos/devrimgunduz/pagila/commits/${REF}" 2>/dev/null \
          | sed -n 's/^  "sha": "\([a-f0-9]*\)".*/\1/p' | head -n1)"; then
  [ -n "$sha" ] && warn "Pagila upstream commit: $sha  (record this in README.md)"
fi

# ---- Phase 0 green light ----------------------------------------------------
# 20-pagila-data.sql must be 3 310 905 bytes with ZERO CR bytes. Any CR means
# something rewrote the file and the COPY blocks are corrupt.
echo
fail=0
for f in 10-pagila-schema.sql 20-pagila-data.sql; do
  path="${DEST}/${f}"
  bytes="$(wc -c < "$path" | tr -d ' ')"
  crs="$(tr -dc '\r' < "$path" | wc -c | tr -d ' ')"
  if [ "$crs" -eq 0 ]; then
    printf '%-24s %10s bytes  %s CR bytes (must be 0)\n' "$f" "$bytes" "$crs"
  else
    err "$(printf '%-24s %10s bytes  %s CR bytes (MUST BE 0)' "$f" "$bytes" "$crs")"
    fail=1
  fi
done

data_len="$(wc -c < "${DEST}/20-pagila-data.sql" | tr -d ' ')"
if [ "$data_len" != "3310905" ]; then
  warn "NOTE: 20-pagila-data.sql is ${data_len} bytes; the design was measured against 3310905."
  warn "      Upstream may have changed - re-check the row counts in scripts/verify.sh (V3)."
fi

[ "$fail" -eq 0 ] || die 'CR bytes detected in a vendored .sql file.'
ok "Phase 0 green."
