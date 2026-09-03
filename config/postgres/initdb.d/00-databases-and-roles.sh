#!/bin/bash
# This initialization step creates separate PostgreSQL databases and identities for each local service.
set -euo pipefail

echo ">>> 00-databases-and-roles: creating service databases and read-only roles"

: "${SUPERSET_DB_NAME:?SUPERSET_DB_NAME must be set}"
: "${SUPERSET_DB_USER:?SUPERSET_DB_USER must be set}"
: "${SUPERSET_DB_PASSWORD:?SUPERSET_DB_PASSWORD must be set}"
: "${CUBE_DB_USER:?CUBE_DB_USER must be set}"
: "${CUBE_DB_PASSWORD:?CUBE_DB_PASSWORD must be set}"
: "${VECTOR_DB_NAME:?VECTOR_DB_NAME must be set}"
: "${VECTOR_DB_USER:?VECTOR_DB_USER must be set}"
: "${VECTOR_DB_PASSWORD:?VECTOR_DB_PASSWORD must be set}"

# Separate database roles limit each service to the data it needs.
psql -v ON_ERROR_STOP=1 \
     -v superset_user="$SUPERSET_DB_USER" -v superset_pw="$SUPERSET_DB_PASSWORD" \
     -v superset_db="$SUPERSET_DB_NAME" -v cube_user="$CUBE_DB_USER" -v cube_pw="$CUBE_DB_PASSWORD" \
     -v vector_user="$VECTOR_DB_USER" -v vector_pw="$VECTOR_DB_PASSWORD" -v vector_db="$VECTOR_DB_NAME" \
     --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<'EOSQL'
CREATE ROLE :"superset_user" LOGIN PASSWORD :'superset_pw';
CREATE DATABASE :"superset_db" OWNER :"superset_user";

CREATE ROLE :"cube_user" LOGIN PASSWORD :'cube_pw';
CREATE ROLE :"vector_user" LOGIN PASSWORD :'vector_pw';
CREATE DATABASE :"vector_db" OWNER :"vector_user";
EOSQL

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$VECTOR_DB_NAME" \
     -c 'CREATE EXTENSION IF NOT EXISTS vector'

echo ">>> 00-databases-and-roles: done"
