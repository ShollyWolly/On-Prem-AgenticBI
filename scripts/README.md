# scripts/

Host-side, idempotent operational commands arranged by responsibility.

## Layout

| Directory | Purpose | Primary commands |
|---|---|---|
| `general/` | Shared shell support and setup prerequisites | `gen-secrets.sh`, `fetch-pagila.sh` |
| `deployment/` | Full setup and Compose lifecycle | `bootstrap.sh`, `up.sh`, `down.sh`, `status.sh` |
| `services/` | Service-owned initialization and recovery | LDAP, PostgreSQL, LibreChat, and sandbox scripts |

## Common commands

```bash
# Full first-time setup; the repository-root wrapper stays the easiest entry point.
bash ./bootstrap.sh

# Rebuild all enabled-profile images and sandbox packages without Docker build cache.
bash ./bootstrap.sh --no-cache

# Run all end-to-end checks, or only Cube authorization and MCP parity checks.
bash ./scripts/verify.sh
bash ./scripts/verify.sh V1

# Start the base stack, or add any optional profiles.
bash ./scripts/deployment/up.sh
bash ./scripts/deployment/up.sh --profile chat --profile sandbox

# Inspect or stop the Compose project.
bash ./scripts/deployment/status.sh --profile chat
bash ./scripts/deployment/down.sh

# Explicitly destructive: deletes local Compose volumes and their data.
bash ./scripts/deployment/down.sh --volumes

```

`up.sh` expects the checkout to have been bootstrapped already: it starts
services and runs safe initializers, but does not fetch sources, build images,
or compile sandbox packages.

Bootstrap builds images one at a time to keep the local Docker daemon stable
during the heavyweight LibreChat, RAG, and sandbox builds.

LibreChat's frontend build uses a 2 GB Node heap by default through
`LIBRECHAT_BUILD_NODE_MAX_OLD_SPACE_SIZE`; raise it only when Docker Desktop has
enough memory available.

It rechecks out the pinned LibreChat, RAG API, and Code Interpreter revisions on
every run before applying the local LibreChat patch.

`.env` holds only Compose-wide ports and `CUBE_MODE`; ignored service-local
environment files are created from `config/**/.env.example` by `gen-secrets.sh`.

## Tests

```bash
bash ./scripts/tests/verify-cube-mcp-parity.sh
bash ./scripts/tests/verify-audit.sh
```

The Cube check exercises REST and Semantic SQL authorization paths. The audit
check verifies verifier-only audit records, their verdict summary fields, and the
least-privilege database roles.

## Service recovery

| Service | Canonical command | Use |
|---|---|---|
| LDAP | `services/ldap/init.sh` | Reconcile demo users and groups. |
| PostgreSQL | `services/postgres/init-vectordb.sh` | Add or repair the RAG vector database on existing state. |
| PostgreSQL | `services/postgres/init-audit.sh` | Add or repair the verified SQL audit database and least-privilege roles. |
| Sandbox | `services/sandbox/init-garage.sh` | Initialize Garage object storage. |
| Sandbox | `services/sandbox/build-packages.sh` | Prebuild sandbox Python packages. |
| Sandbox | `services/sandbox/patch-code-interpreter.sh` | Apply the pinned upstream Bun dependency retry patch. |
| LibreChat | `services/librechat/patch-oidc.sh` | Apply the pinned upstream OIDC patch. |
| LibreChat | `services/librechat/migrate-oidc.sh` | Preserve legacy agent records during OIDC migration. |
| LibreChat | `services/librechat/provision-managed-agents.sh` | Add or refresh managed agents for existing OIDC users. |

`general/lib.sh` is sourced by implementation scripts and provides logging,
`.env` lookup, and Docker wrappers.
