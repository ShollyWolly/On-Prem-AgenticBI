# scripts/

Everything that runs on the **host**, in bash. There are no init containers: each
step is an idempotent script `bootstrap.sh` calls in order, so any one of them can
be re-run on its own without tearing the stack down.

## Run during bootstrap

| Script | When | Idempotent |
|---|---|---|
| `fetch-pagila.sh` | before first `up` | yes - skips if the SQL is already vendored |
| `gen-secrets.sh --apply` | before first `up` | yes - only fills keys still set to `CHANGE_ME` |
| `init-ldap.sh` | after `openldap` is healthy | yes - re-applies passwords and asserts every bind |
| `build-sandbox-packages.sh` | once, sandbox profile | yes - `/pkgs/.initialized` is the marker |
| `init-garage.sh` | after `garage` is healthy | yes |
| `migrate-librechat-ldap.sh` | **before the first LDAP login** | yes - no-op once users are `provider=ldap` |
| `provision-agent.sh` | after `librechat` is healthy | yes - updates the agents in place |

## Run on demand

- `verify.sh` - the check suite. `./scripts/verify.sh` for all of it,
  `./scripts/verify.sh V1 V7` for named checks.
- `init-vectordb.sh` - creates the RAG vector database on a stack whose `PGDATA`
  already exists. `initdb.d` only fires on an empty volume, so this is the upgrade
  path for anything already seeded.
- `smoke/` - three end-to-end tests, standard library or `httpx`, all runnable
  from the host. `agent_turn.py` is the only one that goes *through* LibreChat, so
  it is the only one that can catch a broken agent record or a blocked MCP server.

`lib.sh` is sourced, never executed: logging, `.env` reading, and the docker
wrappers.

## The one thing to be careful with

**`verify.sh` deliberately disables `pipefail`, and `lib.sh` deliberately does
not.** The suite tests with `printf ... | grep -q PATTERN`. `grep -q` closes the
pipe on its first match, killing `printf` with SIGPIPE (141), and under `pipefail`
the pipeline reports 141 instead of grep's 0 - so a check fails *precisely when
its pattern matches early*, which reads like a real regression. Keep
`set +o pipefail` there.

Use the `lib.sh` Docker wrappers (`dexec`, `dcp_to`, `compose_x`, `docker_x`)
rather than calling `docker` directly when a command passes a container path.
