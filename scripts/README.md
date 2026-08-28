# scripts/

Host-side, idempotent operational scripts. `bootstrap.sh` calls the appropriate
ones during first setup; each can also be re-run for the documented recovery use.

## Setup and recovery

| Script | Use | Notes |
|---|---|---|
| `gen-secrets.sh` | Create local secrets | Use `--apply --force` only for initial setup or a deliberate reset. |
| `fetch-pagila.sh` | Fetch the pinned Pagila SQL | Skips existing seed files unless forced. |
| `init-ldap.sh` | Reconcile demo LDAP users and groups | Re-applies passwords and validates binds. |
| `patch-librechat-oidc.sh` | Apply the pinned LibreChat OIDC patch | Bootstrap runs it after cloning the vendor source. |
| `migrate-librechat-oidc.sh` | Preserve legacy LibreChat records during OIDC migration | Safe to re-run; compatibility wrapper `migrate-librechat-ldap.sh` calls it. |
| `provision-agent.sh` | Repair managed agents for existing OIDC users | Normal first OIDC login provisions agents automatically. |
| `init-vectordb.sh` | Create the RAG vector database on existing PostgreSQL state | `initdb.d` only runs for a new volume. |
| `init-garage.sh` | Initialize sandbox object storage | Requires the sandbox Garage service. |
| `build-sandbox-packages.sh` | Prebuild sandbox Python packages | Uses the package-volume marker for idempotence. |

## Validation

`verify.sh` is the operator verification suite.

```bash
bash ./scripts/verify.sh V1
bash ./scripts/verify.sh V4
bash ./scripts/verify.sh
```

- `V1` verifies Cube masks, deny behavior, and data reconciliation.
- `V4` verifies the OAuth-protected Cube MCP endpoint and Authentik JWKS signing
  key.
- `V20` verifies LDAP and Authentik configuration.
- `V21` verifies the Superset MCP read-only boundary.

`smoke/test_cube_mcp.py` validates the Cube MCP protocol. `smoke/test_superset_mcp.py`
validates Superset MCP behavior. `smoke/agent_turn.py` is the end-to-end LibreChat
agent test and is the only smoke test that exercises a real managed-agent record.

`lib.sh` is sourced by shell scripts and provides logging, `.env` lookup, and
Docker wrappers. Use its wrappers for commands that reference container paths.

## Shell behavior

`verify.sh` intentionally disables `pipefail`; `lib.sh` does not. Some assertions
use `printf | grep -q`, where an early matching `grep` can close the pipe and make
`printf` return SIGPIPE. Enabling `pipefail` in the suite turns a successful match
into an apparent failure.
