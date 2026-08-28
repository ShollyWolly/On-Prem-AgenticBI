# docker/

Docker build inputs owned by this repository. Runtime settings live in
[`../config/`](../config/) and `.env`.

| Build | Source | Purpose |
|---|---|---|
| `cube-mcp/` | Local FastMCP application | Verifies Authentik OAuth tokens and proxies governed Cube semantic requests. |
| `superset/` | `apache/superset:6.1.0` | Adds PostgreSQL, LDAP, FastMCP, and healthcheck dependencies. |
| `librechat/` | `vendor/LibreChat` | Builds the pinned LibreChat source with the OIDC provisioning patch. |
| `rag-api/` | `vendor/rag_api` | Resolves the upstream OpenCV dependency conflict for local embeddings. |

`bootstrap.sh` clones the pinned `vendor/` sources and applies the LibreChat OIDC
patch before Compose builds `librechat`. Do not edit generated vendor state as a
configuration mechanism; keep repository changes in `docker/`, `config/`, or the
patch file.

## Cube MCP

`cube-mcp/app.py` is a security boundary. It verifies the Authentik issuer, JWKS,
and `cube.read` scope; derives the identity from verified claims; and creates a
short-lived Cube JWT. It is the only chat-side service with `CUBEJS_API_SECRET`.

Do not expose Cube REST, disable token verification, or add a user-selected role
parameter. Test this boundary with `bash ./scripts/verify.sh V4`.

## Build notes

Compose Dockerfile paths are relative to each build context. LibreChat and RAG
API build from `vendor/`, so their Compose Dockerfile paths point back into this
directory. `docker compose config -q` validates rendering but does not prove a
Dockerfile path exists at build time.

The Superset image installs `python-ldap` with a temporary C build toolchain and
removes that toolchain in the same image layer. Preserve that pattern when
updating dependencies.
