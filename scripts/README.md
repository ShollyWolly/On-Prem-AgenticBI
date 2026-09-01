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
services and runs safe initializers, but does not generate secrets, vendor
sources, build images, or compile sandbox packages.

## Service recovery

| Service | Canonical command | Use |
|---|---|---|
| LDAP | `services/ldap/init.sh` | Reconcile demo users and groups. |
| PostgreSQL | `services/postgres/init-vectordb.sh` | Add or repair the RAG vector database on existing state. |
| Sandbox | `services/sandbox/init-garage.sh` | Initialize Garage object storage. |
| Sandbox | `services/sandbox/build-packages.sh` | Prebuild sandbox Python packages. |
| LibreChat | `services/librechat/patch-oidc.sh` | Apply the pinned upstream OIDC patch. |
| LibreChat | `services/librechat/migrate-oidc.sh` | Preserve legacy agent records during OIDC migration. |

`general/lib.sh` is sourced by implementation scripts and provides logging,
`.env` lookup, and Docker wrappers.
