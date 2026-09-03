#!/usr/bin/env bash

# This initializer creates or repairs the PostgreSQL and pgvector storage used by the RAG API.
source "$(dirname "${BASH_SOURCE[0]}")/../../general/lib.sh"

VDB="$(env_get VECTOR_DB_NAME || echo vectordb)"
VUSER="$(env_get VECTOR_DB_USER || echo vectoruser)"
VPW="$(env_require VECTOR_DB_PASSWORD)"
PGUSER_="$(env_get POSTGRES_USER || echo postgres)"
PGDB_="$(env_get POSTGRES_DB || echo pagila)"

container_running abi-postgres || die "abi-postgres is not running"

q() { compose_x exec -T postgres psql -U "$PGUSER_" -d "$1" -tAc "$2" 2>&1 | tr -d '\r'; }

vsql() {
  local db="$1"
  compose_x exec -T postgres psql -v ON_ERROR_STOP=1 -U "$PGUSER_" -d "$db" \
    --set=d="$VDB" --set=u="$VUSER" --set=p="$VPW" -q
}

step "Vector database for the RAG API"

if [ "$(q "$PGDB_" "SELECT 1 FROM pg_roles WHERE rolname='${VUSER}'")" = "1" ]; then
  vsql "$PGDB_" <<'SQL' || die "ALTER ROLE failed"
ALTER ROLE :"u" WITH LOGIN PASSWORD :'p';
SQL
  ok "role ${VUSER} exists (password re-applied)"
else
  vsql "$PGDB_" <<'SQL' || die "CREATE ROLE failed"
CREATE ROLE :"u" LOGIN PASSWORD :'p';
SQL
  ok "created role ${VUSER}"
fi

if [ "$(q "$PGDB_" "SELECT 1 FROM pg_database WHERE datname='${VDB}'")" = "1" ]; then
  ok "database ${VDB} exists"
else
  vsql "$PGDB_" <<'SQL' || die "CREATE DATABASE failed"
CREATE DATABASE :"d" OWNER :"u";
SQL
  ok "created database ${VDB}"
fi

vsql "$VDB" <<'SQL' \
  || die "CREATE EXTENSION vector failed -- is the image pgvector/pgvector?"
CREATE EXTENSION IF NOT EXISTS vector;
SQL

ver="$(q "$VDB" "SELECT extversion FROM pg_extension WHERE extname='vector'")"
[ -n "$ver" ] || die "vector extension is not present in ${VDB}"
ok "pgvector ${ver} enabled in ${VDB}"

probe="$(q "$VDB" "SELECT '[1,2,3]'::vector <-> '[1,2,4]'::vector")"
case "$probe" in
  1|1.*|0.*) ok "vector distance operator works (<-> = ${probe})" ;;
  *) die "vector type present but unusable: ${probe}" ;;
esac
