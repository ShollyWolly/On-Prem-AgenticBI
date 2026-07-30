# docker/

Our Dockerfiles. **Build inputs only** - nothing here is read at runtime; runtime
configuration lives in [`../config/`](../config/).

Three of the eighteen images are built rather than pulled, and each one exists
because the upstream Dockerfile does not produce a working image here.

| Image | Base / source | Why not the stock image |
|---|---|---|
| `superset/` | `apache/superset:6.1.0` | The lean build ships **zero database drivers** and no curl. Without `psycopg2` Superset cannot reach its own metadata DB, so it fails at boot with an unhelpful loop. Also adds `python-ldap` and `fastmcp`. |
| `librechat/` | `vendor/LibreChat` | Upstream swallows a failed frontend build (`npm run frontend;` - note the semicolon). Our Dockerfile restores write permission before the build and fails if its artefacts are missing. |
| `rag-api/` | `vendor/rag_api` | Upstream pins `opencv-python-headless` while a dependency requires `opencv-python`, sending pip into unbounded backtracking. It looks exactly like a hang: no error, a ~75 MB wheel re-downloaded per attempt. |

`vendor/` is cloned by `bootstrap.sh` and is gitignored.

## The one thing to be careful with

**`dockerfile:` paths in compose are relative to the build context, not the repo
root.** `rag-api` and `librechat` build from `./vendor/<repo>`, so compose
references them as `../../docker/<name>/Dockerfile`. Moving either `docker/` or
`vendor/` to a different depth changes that `../../`, and it fails only at image
build time - never at `docker compose config`.

`python-ldap` is a C extension with no wheel available here. `docker/superset/`
installs its build toolchain, uses it, and purges it **in one layer**; keep that
shape rather than leaving `gcc` in the image.
