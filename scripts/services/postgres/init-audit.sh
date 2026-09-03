#!/usr/bin/env bash

# This initializer creates the verifier audit database and its least-privilege reader and writer roles.
source "$(dirname "${BASH_SOURCE[0]}")/../../general/lib.sh"

AUDIT_DB="$(env_get AUDIT_DB_NAME || echo agentic_bi_audit)"
AUDIT_WRITER="$(env_get AUDIT_WRITER_USER || echo audit_writer)"
AUDIT_WRITER_PASSWORD="$(env_require AUDIT_WRITER_PASSWORD)"
AUDIT_READER="$(env_get AUDIT_READER_USER || echo audit_reader)"
AUDIT_READER_PASSWORD="$(env_require AUDIT_READER_PASSWORD)"
POSTGRES_ADMIN="$(env_get POSTGRES_USER || echo postgres)"
POSTGRES_DATABASE="$(env_get POSTGRES_DB || echo pagila)"

container_running abi-postgres || die "abi-postgres is not running"

psql_admin() {
  compose_x exec -T postgres psql -v ON_ERROR_STOP=1 -U "$POSTGRES_ADMIN" -d "$1" \
    --set=audit_db="$AUDIT_DB" --set=writer="$AUDIT_WRITER" --set=writer_password="$AUDIT_WRITER_PASSWORD" \
    --set=reader="$AUDIT_READER" --set=reader_password="$AUDIT_READER_PASSWORD"
}

step "Verified SQL audit database"

psql_admin "$POSTGRES_DATABASE" <<'SQL'
SELECT format('CREATE ROLE %I LOGIN PASSWORD %L', :'writer', :'writer_password')
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = :'writer')
\gexec
SELECT format('ALTER ROLE %I LOGIN PASSWORD %L', :'writer', :'writer_password')
\gexec
SELECT format('CREATE ROLE %I LOGIN PASSWORD %L', :'reader', :'reader_password')
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = :'reader')
\gexec
SELECT format('ALTER ROLE %I LOGIN PASSWORD %L', :'reader', :'reader_password')
\gexec
SELECT format('CREATE DATABASE %I OWNER %I', :'audit_db', current_user)
WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = :'audit_db')
\gexec
SELECT format('ALTER DATABASE %I OWNER TO %I', :'audit_db', current_user)
\gexec
SQL

psql_admin "$AUDIT_DB" <<'SQL'
CREATE TABLE IF NOT EXISTS audit_events (
  event_id uuid PRIMARY KEY,
  audit_id uuid NOT NULL,
  occurred_at timestamptz NOT NULL DEFAULT now(),
  conversation_id text NOT NULL,
  message_id text NOT NULL,
  run_id text NOT NULL,
  agent_id text NOT NULL,
  librechat_user_id text NOT NULL,
  librechat_user_email text NOT NULL,
  oauth_subject text NOT NULL,
  oauth_email text NOT NULL,
  cube_role text NOT NULL CHECK (cube_role IN ('analyst', 'admin')),
  outcome text NOT NULL CHECK (outcome IN ('pass', 'fail', 'unavailable')),
  row_count integer,
  duration_ms integer NOT NULL CHECK (duration_ms >= 0),
  judge_confidence double precision,
  judge_rationale text,
  judge_issues jsonb,
  payload_sha256 text NOT NULL,
  event_hash text NOT NULL,
  encrypted_payload bytea NOT NULL
);
ALTER TABLE audit_events ADD COLUMN IF NOT EXISTS judge_confidence double precision;
ALTER TABLE audit_events ADD COLUMN IF NOT EXISTS judge_rationale text;
ALTER TABLE audit_events ADD COLUMN IF NOT EXISTS judge_issues jsonb;
CREATE INDEX IF NOT EXISTS audit_events_occurred_at_idx ON audit_events (occurred_at DESC);
CREATE INDEX IF NOT EXISTS audit_events_conversation_idx ON audit_events (conversation_id, occurred_at);
CREATE INDEX IF NOT EXISTS audit_events_user_idx ON audit_events (oauth_email, occurred_at DESC);
CREATE INDEX IF NOT EXISTS audit_events_outcome_idx ON audit_events (outcome, occurred_at DESC);

REVOKE ALL ON DATABASE :"audit_db" FROM PUBLIC;
GRANT CONNECT ON DATABASE :"audit_db" TO :"writer", :"reader";
REVOKE ALL ON SCHEMA public FROM PUBLIC;
GRANT USAGE ON SCHEMA public TO :"writer", :"reader";
REVOKE ALL ON TABLE audit_events FROM PUBLIC;
GRANT INSERT ON TABLE audit_events TO :"writer";
GRANT SELECT ON TABLE audit_events TO :"reader";
SQL

ok "Verified SQL audit schema and least-privilege roles are ready"
