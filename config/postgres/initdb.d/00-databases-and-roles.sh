#!/bin/bash
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

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" \
CREATE ROLE :"superset_user" LOGIN PASSWORD :'superset_pw';
CREATE DATABASE :"superset_db" OWNER :"superset_user";

CREATE ROLE :"cube_user" LOGIN PASSWORD :'cube_pw';

CREATE ROLE :"vector_user" LOGIN PASSWORD :'vector_pw';
CREATE DATABASE :"vector_db" OWNER :"vector_user";
EOSQL

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$VECTOR_DB_NAME" \
     -c 'CREATE EXTENSION IF NOT EXISTS vector'

echo ">>> 00-databases-and-roles: done"
