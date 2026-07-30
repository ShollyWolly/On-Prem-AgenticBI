-- Least-privilege read access for Cube. Runs AFTER 20-pagila-data.sql: GRANT ON
-- ALL TABLES only affects tables that already exist -- ordering is load-bearing.
-- SELECT-only so even a compromised or mis-prompted query cannot mutate data.

\echo '>>> 40-grants: granting SELECT-only to the Cube role'

-- :cube_user is not available here (psql cannot read env vars), so the role
-- name is the .env default. If you change CUBE_DB_USER, change it here too.
-- scripts/verify.sh (check V3) asserts the seed and the read-only role.
GRANT CONNECT ON DATABASE pagila TO cube_ro;
GRANT USAGE   ON SCHEMA public   TO cube_ro;
GRANT SELECT  ON ALL TABLES    IN SCHEMA public TO cube_ro;
GRANT SELECT  ON ALL SEQUENCES IN SCHEMA public TO cube_ro;

-- Covers the payment partitions recreated by 30-date-shift.sql and anything
-- added later.
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO cube_ro;

-- Explicitly remove the ability to create objects. In PG15+ the PUBLIC role no
-- longer has CREATE on public by default, but being explicit costs nothing and
-- documents the intent.
REVOKE CREATE ON SCHEMA public FROM cube_ro;
REVOKE ALL ON DATABASE pagila FROM PUBLIC;

\echo '>>> 40-grants: done'
