
\echo '>>> 40-grants: granting SELECT-only to the Cube role'

GRANT CONNECT ON DATABASE pagila TO cube_ro;
GRANT USAGE   ON SCHEMA public   TO cube_ro;
GRANT SELECT  ON ALL TABLES    IN SCHEMA public TO cube_ro;
GRANT SELECT  ON ALL SEQUENCES IN SCHEMA public TO cube_ro;

ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO cube_ro;

REVOKE CREATE ON SCHEMA public FROM cube_ro;

REVOKE ALL ON DATABASE pagila FROM PUBLIC;

\echo '>>> 40-grants: done'
