# config/

Service configuration. Everything here is **read by a container at runtime**, via
a bind mount or an `env_file` in `docker-compose.yml`. Nothing here is a build
input - Dockerfiles live in [`../docker/`](../docker/).

| Directory | Read by | What it decides |
|---|---|---|
| `cube/` | `cube` | `cube.js` maps a SQL username to a role; `model/` holds 15 cubes and 5 views |
| `superset/` | `superset`, `superset-mcp` | Flask config, LDAP auth, dark theme, plus the Python that builds the dashboard and the MCP service account |
| `librechat/` | `librechat` | `librechat.yaml`, agent instructions, and compact system rules embedded during provisioning |
| `postgres/` | `postgres` | `initdb.d/` - Pagila schema, data, date shift, grants, seed sentinel |
| `garage/` | `garage` | S3 daemon config (secrets come from the environment, not this file) |
| `env/` | `cube` | `cube.common.env` plus one profile file selected by `CUBE_MODE` |

## The one thing to be careful with

**`config/cube/` is the governance boundary, not just a data model.**
`cube.js` decides identity and `model/views/*.yml` decide what each identity may
see. A change here silently changes who can read PII, and it fails *open-looking*
- masked columns simply come back real, with no error. Run `./scripts/verify.sh V1`
after touching either.

Two rules that are easy to get wrong and produce no error:

- `mask:` belongs on **cubes**; `access_policy` belongs on **views**. Member-level
  policies are not inherited by views, so a policy on a cube is dead code the
  moment a query targets a view - and every query does.
- Write `{ securityContext.x }`, never `{ userAttributes.x }`. The latter is Cube
  Cloud-only and yields `undefined` here, which fails open-looking.

`config/env/cube.dev.env` exists to enable the Cube Playground and **deliberately
disables masking**. It is for iterating on the model, never for a demo.
