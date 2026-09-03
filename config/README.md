# config/

Runtime configuration mounted into containers or loaded through Compose. Build
instructions belong in [`../docker/`](../docker/).

| Directory | Consumers | Purpose |
|---|---|---|
| `authentik/` | Authentik server and worker | LDAP source plus LibreChat OIDC and Cube MCP OAuth providers. |
| `audit/` | LibreChat, verifier, audit console | Nested shared, writer, and console audit settings. |
| `cube/` | Cube | Semantic cubes, views, request security-context handling, and mode-specific environment settings. |
| `garage/` | Garage | Object-storage daemon configuration. |
| `librechat/` | LibreChat extensions | Chat settings, MCP definitions, RAG, search, sandbox, and managed-agent instructions. |
| `mcp/` | MCP services | Service-local environment settings for Cube REST, Cube SQL, and verified SQL gateways. |
| `postgres/` | PostgreSQL | Pagila seed, grants, and date-shift initialization. |
| `superset/` | Superset and Superset MCP | LDAP auth, dashboard assets, and the read-only MCP service account. |

## Authorization boundary

`config/cube/` and `docker/mcp/cube/` are the data-authorization boundary.
`cube-mcp` verifies Authentik OAuth tokens, maps exactly one LDAP group to a Cube
security context, and sends only a short-lived signed context to Cube. Cube views
apply access policies and masks.

Keep these invariants:

- `analysts` maps to `analyst`, `admins` maps to `admin`, and all other or
  ambiguous memberships map to `denied`.
- `mask` belongs on cubes and `access_policy` belongs on views.
- Use `{ securityContext.x }` in model expressions.
- Keep `CUBE_MODE=demo` outside local model development.
- Do not expose Cube REST or move `CUBEJS_API_SECRET` into LibreChat.

`CUBE_USER_ROLE_MAP` is retained for the Cube SQL path used by Superset and
operator checks. LibreChat's Cube MCP access is derived from verified Authentik
group claims instead.

After changing Cube models, role mapping, masks, views, Authentik, or Cube MCP
OAuth settings, validate both masked analyst results and unmasked admin results.

## Identity settings

OpenLDAP remains the directory of record. Authentik synchronizes LDAP users and
groups for LibreChat login and Cube MCP authorization. Superset intentionally
uses direct LDAP authentication and a fixed Cube SQL identity, so it is not a
per-user Cube pass-through path.

The local `.env` contains stable secrets and is not committed. Generate initial
values with `bash ./scripts/general/gen-secrets.sh --apply --force`; then set the Azure
Foundry endpoint, API key, and model before running the chat profile.
