#!/bin/bash
# Runs FIRST (alphabetical). Creates the Superset metadata DB and Cube's
# least-privilege login. The one .sh in initdb.d, because plain .sql cannot
# expand env vars and these passwords must not be committed; pinned `eol=lf`
# in .gitattributes, checked by verify.sh V9. Roles are created but not yet
# granted anything -- Pagila's tables do not exist until 20-*.sql runs.
set -euo pipefail

echo ">>> 00-databases-and-roles: creating superset DB and cube_ro role"

: "${SUPERSET_DB_NAME:?SUPERSET_DB_NAME must be set}"
: "${SUPERSET_DB_USER:?SUPERSET_DB_USER must be set}"
: "${SUPERSET_DB_PASSWORD:?SUPERSET_DB_PASSWORD must be set}"
: "${CUBE_DB_USER:?CUBE_DB_USER must be set}"
: "${CUBE_DB_PASSWORD:?CUBE_DB_PASSWORD must be set}"
: "${VECTOR_DB_NAME:?VECTOR_DB_NAME must be set}"
: "${VECTOR_DB_USER:?VECTOR_DB_USER must be set}"
: "${VECTOR_DB_PASSWORD:?VECTOR_DB_PASSWORD must be set}"

# psql --set gives us :'var' interpolation with proper quoting/escaping, which
# is safer than string-concatenating passwords into SQL.
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" \
     --set=superset_db="$SUPERSET_DB_NAME" \
     --set=superset_user="$SUPERSET_DB_USER" \
     --set=superset_pw="$SUPERSET_DB_PASSWORD" \
     --set=cube_user="$CUBE_DB_USER" \
     --set=cube_pw="$CUBE_DB_PASSWORD" \
     --set=vector_db="$VECTOR_DB_NAME" \
     --set=vector_user="$VECTOR_DB_USER" \
     --set=vector_pw="$VECTOR_DB_PASSWORD" <<'EOSQL'
-- Superset's metadata store -- a separate DATABASE here, not a second
-- container. Assets re-import declaratively every start, so losing this on
-- `down -v` costs nothing.
CREATE ROLE :"superset_user" LOGIN PASSWORD :'superset_pw';
CREATE DATABASE :"superset_db" OWNER :"superset_user";

-- Cube reads through this role: SELECT-only (granted in 40-grants.sql), so
-- even a tricked semantic layer cannot execute DML.
CREATE ROLE :"cube_user" LOGIN PASSWORD :'cube_pw';

-- RAG API's document chunks and embeddings: a third database in this instance
-- rather than the upstream vectordb container. Owns it outright since the RAG
-- API migrates its own tables at startup.
CREATE ROLE :"vector_user" LOGIN PASSWORD :'vector_pw';
CREATE DATABASE :"vector_db" OWNER :"vector_user";
EOSQL

# Extensions are per-database, so this must run INSIDE the vector database, as
# superuser (CREATE EXTENSION requires it). Without it the RAG API starts
# healthy and fails at insert time with `type "vector" does not exist`.
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$VECTOR_DB_NAME" \
     -c 'CREATE EXTENSION IF NOT EXISTS vector'

echo ">>> 00-databases-and-roles: done"
