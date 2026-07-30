# Traps

Upstream behaviours that cost real time when violated. Each one is here because
it **failed in a way that looked like something else** -- a healthy container, a
plausible number, a wrong-password error -- rather than because it was merely
surprising.

Grouped by component. Inline comments in the code point here.

> Paths below are repo-relative. Service configuration lives under `config/`,
> our Dockerfiles under `docker/`, helper scripts under `scripts/`.

## Cube

- **Never demo on `CUBE_MODE=dev`.** `CUBEJS_DEV_MODE=true` disables
  member-level access control, so masking silently shows real PII. Use `dev` only
  to iterate on the model with the Playground, then switch back.
- **`CUBEJS_CACHE_AND_QUEUE_DRIVER=memory` in `config/env/cube.demo.env` is
  load-bearing.** The driver default keys on `NODE_ENV` (hardcoded `production`
  in the image), not on `CUBEJS_DEV_MODE`. Remove it and the container stays
  *healthy* while the first query throws.
- **`mask:` goes on cubes. `access_policy` goes on views.** Cube member-level
  policies are not inherited by views, so a `member_level` on a cube is dead code
  the moment a query targets a view — and every query does.
- **Constant masks need an explicit SQL literal**: `mask: { sql: "'redacted'" }`.
  A bare `mask: "redacted"` is parsed as an expression, `redacted` becomes an
  undefined identifier, the cube fails to compile, and every view join path that
  touches it cascades into confusing errors.
- **Write `{ securityContext.x }`, never `{ userAttributes.x }`.** The latter is
  Cube Cloud-only and silently yields `undefined` — it fails *open-looking*.
- Base-cube members in a view are **unprefixed** (`total_revenue`, `paid_at`).
  Only `prefix: true` join paths get prefixed. Use prefixes sparingly: applying
  them everywhere yields names like `staff_staff_name`.
- **`checkSqlAuth` must return `password` unconditionally.** Cube re-authenticates
  every `CUBESQL_AUTH_EXPIRE_SECS` (default 300) and on change-user flows, and the
  incoming `password` argument is `undefined` on those calls. Returning it only when
  one was supplied breaks every long-lived pooled connection after five minutes — an
  intermittent failure that looks like a network fault.
- **`contextToAppId` is keyed on ROLE, never on e-mail.** It runs on every request and
  each distinct value compiles and retains its own copy of the data model (cap ~250,
  then LRU evict). Keying on e-mail in a 5k-user tenant means 5k compiled models.
  Role gives three.
- The hook is **`contextToGroups`**, not `contextToRoles`. It is the bridge from
  `securityContext` to the `group:` names in `access_policy`, and the piece most
  people miss.

## Talking to Cube's SQL API

- **Use psycopg, never asyncpg.** asyncpg only speaks the Postgres *extended*
  query protocol, which Cube does not implement; every query fails with a bare
  `FeatureNotSupportedError: Unsupported Error:`. `postgres-mcp` uses psycopg3 with
  client-side parameter binding, which sends a simple query and therefore works.
  Placeholders are `%s`, not `$1`.
- **Always emit `MEASURE(x)`** rather than `SUM`/`AVG`. It is valid for every Cube
  measure type, so aggregation-mismatch errors become unreachable.
- **Query views, never join cubes.** Joins inflate the e-graph and trigger
  `Can't find rewrite due to N AST node limit reached`.
- `GROUP BY` by **ordinal**, so `DATE_TRUNC` appears once in the AST.

## Semantic-layer correctness (read before adding a dimension)

- **`public.film_category` is many-to-many here**: 2367 rows for 1000 films, 1–3
  categories each. Joining it raw fans every film row out, so any additive measure
  sliced by category over-reports by ~2.37× — revenue by category came to
  `159539.15` against a true `67416.51`. Cube and hand-written SQL produce the
  inflated number *identically*, because it is what the join says.
  `film_primary_categories` in `config/cube/model/cubes/catalog.yml` collapses it to one
  row per film, and `films` joins it **`one_to_one`**. Do not restore
  `one_to_many`, and do not model the full bridge as a second cube — that gives
  `categories` two join paths from `films` and makes category queries ambiguous.
- The primary-category tiebreak is a **hash** of `(film_id, category_id)`, not
  `MIN(category_id)`. MIN is stable but correlates with the id, which drains
  revenue down the id order and fabricates a trend (Action 10289 → Travel 82).
- **This class of bug fails open-looking**: 16 plausible bars, no error, no
  warning. The only detector is reconciling a breakdown against its total, which
  is what `verify.sh V1b` does. Add a V1b-style assertion whenever you expose a
  new dimension over an additive measure.

## postgres-mcp (the two Cube-facing MCP servers)

- Two containers of the **same image with the same flags**, differing only in the
  SQL username in `DATABASE_URI`. That is the demo: any difference in output is
  the semantic layer's doing. It also means **identity is bound to the server, so
  to the agent** — whoever gets the admin agent gets unmasked data. Say so out
  loud; it is a prop, not governance.
- `--access-mode=unrestricted` is required: restricted mode rejects `MEASURE()`.
  Safe because Cube itself refuses INSERT/DROP and `__user` switching, and
  `cube_ro` is SELECT-only. Verified, not assumed.
- Only **four** of its nine tools work against Cube (`execute_sql`,
  `list_schemas`, `list_objects`, `get_object_details`). The rest need
  `pg_stat_statements` / `hypopg` / `pg_indexes`. There is no server-side flag to
  disable them in 0.3.0, so `provision_agent.py` simply does not attach them.
- Transport is **SSE**, not streamable-http: 0.3.0 is the newest released image and
  streamable-http was merged upstream but never shipped.
- **After `docker compose restart cube`, restart the two MCP servers too.** They
  pool connections to Cube and do not validate them on checkout, so the first
  query to reuse a dead socket fails with `server closed the connection
  unexpectedly` — which, on the admin server, reads exactly like the admin role
  having lost its access. `test_pgmcp.py` retries once for this reason.

## Superset MCP (`superset mcp run`)

- **Every tool takes one argument, an object called `request`**, with the real
  arguments nested inside — `{"request": {"identifier": 10}}`. Charts and
  dashboards are addressed by `identifier` (id, uuid or slug), never `chart_id`.
  Flat arguments fail pydantic validation and the middleware reports them as
  `Internal error ... contact support`, which points nowhere near the cause.
- **`get_chart_data`'s `limit` REPLACES the chart's row limit, it does not cap
  it.** Chart 10 returns 15 rows with no limit and 100 with `limit=100`. An agent
  that passes a limit and then reports "the title says Top 15 but it returns 108
  rows" is describing its own argument. Both agent instruction files warn about it.
- A single POST answers with **several SSE frames**: the tools log through the MCP
  logging capability, so N `notifications/message` frames precede the result.
  Taking the first `data:` line yields a log line that parses fine as JSON and has
  no `result` key — i.e. it reads as "the tool returned nothing". Match on the
  request `id`.
- The transport is **stateless** (`Terminating session: None`, no `mcp-session-id`),
  so every request must be self-contained.
- `GET /mcp` correctly returns **405** — the route is POST-only. The healthcheck
  accepts `200|400|405|406`; `curl -fsS` there leaves the container `starting`
  forever.
- **The `mcp_reader` role is the entire security boundary.** 6.1.0 has no per-user
  MCP identity: `get_user_from_request` resolves `MCP_DEV_USERNAME` or Preset's
  proprietary `g.user`, and `default_user_resolver` is dead code. Individual tools
  cannot be disabled via the CLI either (`MCP_FACTORY_CONFIG.exclude_tags` is only
  read on the `use_factory_config=True` path). So the account is read-only and
  deliberately lacks `can_execute_sql_query` — `test_superset_mcp.py` asserts the
  refusal from outside.
- Use `db.session`, not `sm.get_session`, in `create_mcp_reader.py` — the latter
  does not exist on `SupersetSecurityManager` in FAB 5.0.2.
- Install `fastmcp` via `uv pip install "fastmcp>=3.1.0,<4.0"`, **not**
  `apache-superset[fastmcp]`: `apache-superset` is an editable install pointing at
  `/app` and pip will try to rebuild it.

## Superset

- `apache/superset:6.1.0` is the **lean** build with no DB drivers and no curl.
  Always build via `docker/superset/Dockerfile`.
- **`THEME_OVERRIDES` was removed in 6.0** and `THEME_DEFAULT_MODE` does not
  exist in 6.1. Use `algorithm: "dark"` in `THEME_DEFAULT` plus
  `THEME_DARK = None`. Assigning `THEME_DEFAULT` replaces the upstream dict, so
  the `brand*` tokens must be re-declared.
- **`superset import-assets` does not exist** (that is `preset-cli`), and
  `import-directory` takes **no `-u/--username`**.
- Charts live in `config/superset/build_dashboard.py`, not in hand-written YAML. When
  adding a time-series chart, the x-axis must be an adhoc **`BASE_AXIS`** column
  carrying `timeGrain`; `extras.time_grain_sqla` alone silently returns ungrouped
  raw rows that look like real data.
- Charts are keyed on a **uuid5 of the spec `slug`**, so renaming one is a rename.
  It used to key on `slice_name`, where a rename created a second chart and
  orphaned the first — invisible on the dashboard but still returned by
  `list_charts`, so the Dashboard Reviewer agent read the stale copy. The script
  now deletes any slice it does not manage; keep that.
- If a chart's row limit is a **top-N**, put the N in the title
  ("Top 15 Countries by Revenue"). Otherwise the only way to notice the truncation
  is to sum the bars and find they fall short of the KPI tile.
- Redis/Celery are deliberately absent, which is only safe because
  `run-server.sh` defaults to `--workers 1`. **If you raise
  `SERVER_WORKER_AMOUNT`, switch the four cache configs to `RedisCache` first.**

## LibreChat

- **`allowed_callers: ["code_execution"]` on the Cube tools is deliberate.** It hides
  them from direct tool-calling, so the model must reach them by writing Python. That
  is what makes "query, compute in pandas, plot" the actual path rather than a hope.
  Set `ALLOW_DIRECT=1` to permit both while debugging. The Dashboard Reviewer opts out
  (`allow_direct`), because the Superset tools return structured JSON already.
- `mcpSettings.allowedAddresses` must list EVERY MCP server as a bare
  `host:port` -- `postgres-mcp-analyst:8000`, `postgres-mcp-admin:8000`,
  `superset-mcp:5008`. The SSRF guard is on by default and silently blocks
  Docker private IPs.
- All SIX agent capabilities must be enumerated in `config/librechat/librechat.yaml`; specifying
  `capabilities` **replaces** the default array, and `programmatic_tools` is not
  in the defaults.
- **Do not bind-mount `vendor/LibreChat/client`.** The Vite bundle is built into
  `/app/client/dist` inside the image; mounting over it serves a blank page.
  Front-end edits need `docker compose build librechat`.
- `LIBRECHAT_CODE_API_KEY` is obsolete — do not reintroduce it.
- **Never set `CODEAPI_AUTH_PROVIDER` to `librechat-jwt` or `both`** (nor
  `CODEAPI_JWT_ENABLED=true`) unless you also supply
  `CODEAPI_JWT_PRIVATE_KEY` / `..._BASE64` / `..._PRIVATE_JWK_JSON`. Signing then
  throws `Code API JWT signing key is not configured` on **every** codeapi call, at
  tool-execute time rather than startup — so the stack looks healthy while the agent
  loses `execute_code` and, because the Cube tools are `code_execution`-only, **all
  data access**. `none` is correct here: our codeapi image
  (`service/Dockerfile.local` → `local-api.ts`) mounts `localAuth`, which never reads
  the Authorization header, so real JWT verification is not even reachable without
  switching to the split api+worker build (more containers).
  The value is pinned in the compose `librechat` service so an `.env` edit cannot
  silently break it. `verify.sh V17` guards it.
- Agents cannot be declared in YAML (issue #7741). Use
  `scripts/provision-agent.sh`.
- **`GET /api/agents` returns a LIST PROJECTION**: only `_id`, `id`, `name`,
  `description`, `author`, `category`, `is_promoted`, `updatedAt`. `artifacts`,
  `tools`, `tool_options` and `instructions` are absent. A check that reads them
  off the listing sees empty values and reports a correctly-configured agent as
  broken. V23 therefore reads provisioned agent records directly from MongoDB,
  avoiding both the incomplete projection and unnecessary user logins.
- **`/api/auth/login` is rate-limited to `LOGIN_MAX=7` per `LOGIN_WINDOW=5`
  minutes** (upstream defaults; we do not override them). A verify run plus
  provisioning plus a couple of `agent_turn.py` calls can exceed that. Do not
  raise the limit to make tests pass — bootstrap verification does not log in to
  LibreChat; `agent_turn.py` backs off when a manual smoke test is rate-limited.
- The **resumable** chat controller means `POST /api/agents/chat/agents` returns
  `{"streamId": ...}` and nothing else; events come from
  `GET /api/agents/chat/stream/<id>`. See `scripts/smoke/agent_turn.py`.

## OpenLDAP (the single userstore)

- **`osixia/openldap:1.5.0`** — the de-facto standard (112M pulls) but OpenLDAP
  2.4.57, an EOL series; its only newer tag is `2.6.10-alpha`. `bitnami/openldap`
  is no longer an option: that repo's tag list is empty after Bitnami's Aug 2025
  catalogue change. **No port is published**, which is what makes 2.4.57 tolerable.
- **The login identifier is the FULL E-MAIL, in both apps.** Superset
  `AUTH_LDAP_UID_FIELD = "mail"`, LibreChat `LDAP_SEARCH_FILTER=mail={{username}}`
  with `LDAP_LOGIN_USES_USERNAME=false`. The e-mail is already the canonical key
  (`CUBE_USER_ROLE_MAP`, agent provisioning, every script), and FAB supports only
  one UID field — so choosing `uid` would give one identity two spellings.
- **Changing the login identifier orphans existing user records. Both stores.**
  - Superset: FAB matches on `username == <login string>`; `fab create-admin` set
    `username=admin`, so it tries to REGISTER and dies on the unique e-mail index.
    Fixed by `config/superset/align_ldap_usernames.py`, which runs at every start.
  - LibreChat: `ldapStrategy` does `findUser({ldapId})`, misses a local user, and
    falls through to `createUser` with the same e-mail. Fixed by
    `scripts/migrate-librechat-ldap.sh`, which **must run before the first LDAP
    login**. Setting `ldapId` alone is not enough — a user whose `provider` is not
    `ldap` is refused with a bare `AUTH_FAILED`.
  - Both **rename in place**. Deleting and letting LDAP recreate would orphan the
    dashboard's owner, both provisioned agents, and every uploaded file.
  - Both failures look like a wrong password. They are not; the password is never
    checked.
- **Groups must be `groupOfUniqueNames` with `uniqueMember`.** osixia enables the
  memberof overlay but configures it for that flavour
  (`olcMemberOfGroupOC: groupOfUniqueNames`, `olcMemberOfMemberAD: uniqueMember`).
  A `groupOfNames` group is accepted, stores its members, and is invisible to the
  overlay — `memberOf` never appears, `AUTH_ROLES_MAPPING` matches nobody, and
  everyone lands on `AUTH_USER_REGISTRATION_ROLE`. `init-ldap.sh` asserts
  `memberOf` rather than assuming it.
- **Anonymous `-b <suffix> -s base` returns err=32 "No such object" even when the
  entry exists** — the ACLs hide it and OpenLDAP reports hidden as absent. Probe
  the **root DSE** (`-b ""`) for liveness; bind properly to assert contents.
- **`python-ldap` is a C extension** with no wheel here: it needs `gcc`,
  `libldap2-dev`, `libsasl2-dev`, `libssl-dev`. Installed, used and **purged in one
  layer** in `docker/superset/Dockerfile` — do not leave gcc in the image.
- **`SUPERSET_AUTH=db` is the escape hatch.** With `AUTH_LDAP`, FAB authenticates
  *only* against the directory, so an unreachable slapd locks every human out of
  the dashboard — including the local `admin`.
- **`SUPERSET_ADMIN_PASSWORD` is not a separate secret.** It is wired to
  `${DEMO_ADMIN_PASSWORD}` in compose, because `SUPERSET_ADMIN_EMAIL` and
  `DEMO_ADMIN_EMAIL` are the same identity and the same `ab_user` row — one person
  must not have two passwords, or the `SUPERSET_AUTH=db` break-glass path wants a
  password that appears in no document. Keep the account itself: it owns the
  dashboard and all nine charts.
- **`fab create-admin` never updates an existing account's password**, so
  `align_ldap_usernames.py` re-syncs it on every start — and does so AFTER the
  username rename, resolving the user by **e-mail**. A `fab reset-password` step
  keyed on `--username` works on exactly one of {fresh, existing} stack and
  silently no-ops on the other.
- **Superset 6.1.0 reads `RECAPTCHA_PUBLIC_KEY`, a key it never defines**, whenever
  `AUTH_USER_REGISTRATION` is true and the auth type is not OAuth. `GET /login/`
  then raises KeyError and returns **500 — the login page will not render at all**,
  while `/health` stays 200, the container stays `healthy`, and
  `POST /api/v1/security/login` keeps working because the JSON API renders no SPA
  payload. Set `RECAPTCHA_PUBLIC_KEY = ""`. Do NOT instead disable
  `AUTH_USER_REGISTRATION`: a fresh stack needs it so the analyst's first LDAP login
  can create their local record.
- **Quote `.env` values containing spaces.** `LDAP_ORGANISATION=Demo Corp` is fine
  for compose but makes `. ./.env` execute `Corp`. `lib.sh`'s `env_get` reads via
  `sed` precisely to avoid sourcing.

## Postgres seed

- **The healthcheck has TWO gates and needs both.** `pg_isready -h 127.0.0.1` forces
  TCP, because while `initdb.d` runs the temp server listens on the unix socket only —
  a socket probe reports ready mid-seed and Cube starts against half-loaded Pagila.
  The second gate is the `seed_complete` sentinel from `99-*.sql`, which proves the
  date shift finished.
- `-U "$POSTGRES_USER"` on `pg_isready` is not cosmetic: without it the probe sends the
  OS user (`root`) and logs `FATAL: role "root" does not exist` every 5 seconds
  forever. The check still passes, so it is pure log noise — but it reads as a broken
  stack during a demo.
- **`30-date-shift.sql` sets `session_replication_role='replica'`** to suppress the
  `last_updated` triggers on 15 tables. Without it the shift rewrites those columns and
  the trigger fires on every row.
- `initdb.d` runs **only on an empty PGDATA**. Anything added there later needs a
  matching idempotent script (see `scripts/init-vectordb.sh`) or an existing volume
  never gets it.

## RAG API / pgvector (file_search)

- **One Postgres instance, three databases** (`pagila`, `superset`, `vectordb`).
  Upstream LibreChat's compose runs a separate `vectordb` container; we do not.
  That is why the postgres image is `pgvector/pgvector:0.8.1-pg17-bookworm`.
- **`CREATE EXTENSION vector` is per-database.** Creating it in `pagila` does
  nothing for `vectordb`. Miss it and the RAG API is *healthy* and dies on first
  upload with `type "vector" does not exist`.
- **`initdb.d` only runs on an empty PGDATA**, so on any stack that has already
  seeded, the vector database does not exist. `scripts/init-vectordb.sh` is the
  idempotent path for that; run it freely.
- **Use the FULL `librechat-rag-api-dev` image, never `-lite`.** Lite ships no
  sentence-transformers and can only call a remote embedder — and this Foundry
  deployment has no embeddings model (`text-embedding-3-small`/`-large`/`ada-002`
  all answer `unknown_model`). Local embedding also keeps document text on the
  host, which is the whole point.
- **`RAG_API_URL` is pinned in the compose `librechat` service.** Unset, LibreChat
  does not error — it just omits the `file_search` tool, so the capability looks
  broken.
- Uploads must carry **`tool_resource: file_search`**. Without it the same POST
  succeeds as a plain message attachment, and file search finds nothing.
  `embedded: true` in the response is the only proof it was vectorised.
- **psql interpolates `:"var"` from stdin and files, NOT from `-c`.**
  `psql --set=u=x -c 'CREATE ROLE :"u"'` sends the literal `:"u"` and fails with
  `syntax error at or near ":"`. Related but distinct: variables are also not
  substituted inside a dollar-quoted `DO $$ ... $$` block, so the usual
  "CREATE ROLE IF NOT EXISTS" workaround cannot be combined with them — check from
  the shell first, then run a plain statement.

## Garage (object storage for the sandbox)

- **`s3_region` must be `us-east-1`.** The code-interpreter file server builds its
  S3 client with `region: MINIO_REGION ?? AWS_REGION ?? 'us-east-1'`, and a region
  mismatch invalidates every SigV4 signature. It surfaces only as
  `MinIO not ready, retrying...` with an **empty error string**, so it reads as a
  connectivity fault rather than an auth one.
- **Do not pin Garage below v2.x.** On **v1.0.1**, Garage's
  `CompleteMultipartUpload` response could not be parsed by the MinIO JS client
  (`BUG: failed to parse server response`). The file server uploads with
  `size=undefined`, which selects multipart, so the bytes landed in the bucket but
  the client threw, the sandbox logged `Pruned files from response`, and **every
  generated plot silently never reached the user** — no error anywhere the user
  could see. We carried `patches/garage-single-put.patch` to buffer the stream and
  send an explicit Content-Length.
  **Retested on v2.3.0 with minio 8.0.6: the unpatched multipart path works, so the
  patch is deleted.** Verified by uploading a real agent-generated plot and
  confirming the object in the bucket, not by absence of an error. `verify.sh V15`
  now asserts a round-trip, so a regression here fails loudly instead of silently.
- The client is not a lever if this recurs: `service/package.json` says
  `minio: ^8.0.5`, `service/bun.lock` pins **8.0.6**, and the image builds with
  `bun install --frozen-lockfile` — already current.
- The Garage image is **distroless** — no `/bin/sh`. Healthchecks must use
  exec-form `CMD`, never `CMD-SHELL`.
- `garage status` returning 0 only means the daemon answers RPC. Until a layout is
  applied the S3 port accepts connections but every write fails, so "the port is
  open" proves nothing — `verify.sh V15` checks layout, key and bucket instead.
- `scripts/init-garage.sh` is idempotent; run it freely. It **imports** the keys
  from `.env` rather than generating them, which is what keeps them deterministic.

## Shell scripts

Everything is bash, not PowerShell. That is deliberate: Windows PowerShell 5.1's
`Invoke-RestMethod` hangs indefinitely against LibreChat's API even though the
server answers in under a second, and cmdlet behaviour differs enough between 5.1
and 7 to be a liability in a demo.

- **Use the `lib.sh` docker wrappers**: `dexec`, `dcp_to`, `compose_x`, `docker_x`.
  They scope `MSYS_NO_PATHCONV=1` to the call. Do **not** export that variable
  globally — with it set, the native `curl.exe` stops understanding
  `-o /dev/null`, and `docker cp` receives an unconverted `/c/Users/...` host path
  and fails with `CreateFile C:\c:`. Both were observed.
- **`verify.sh` disables `pipefail` on purpose.** `printf ... | grep -q` returns
  **141 (SIGPIPE)** under `pipefail`, because `grep -q` closes the pipe on first
  match. The result is a check that fails precisely when its pattern matches
  early — which reads like a real regression. Keep `set +o pipefail` there.
- **`PIPESTATUS` after a command substitution describes the assignment, not the
  pipeline inside it.** `x="$(cmd | filter)"; rc=${PIPESTATUS[0]}` always gives 0,
  because the pipeline ran in a subshell. Capture the function's status directly
  (`x="$(fn)"; rc=$?`) and transform afterwards. This silently turned a rate-limit
  SKIP into a FAIL in V16.
- **An assignment whose command substitution fails aborts the script under `set -e`,
  before the next line runs.** `out="$(cmd)"; rc=$?` never reaches `rc=$?` when `cmd`
  exits non-zero — which is the normal path for an idempotent `ldapadd` returning 68.
  Put the assignment in an `if` (`if out="$(cmd)"; then rc=0; else rc=$?; fi`).
- **Do not let a pipeline hide an exit code you care about.** `cmd | tail -3` reports
  `tail`'s status, so a failing build or script reads as success. This has bitten
  repeatedly; when the status matters, capture it before piping.
- Agent provisioning lives in `scripts/provision_agent.py` and runs on the HOST
  using only the standard library, so it needs no pip install and no container to
  borrow.

## Windows specifics

- **CRLF is a functional bug here, not a style issue.** `.gitattributes` covers
  this repo, but the `vendor/` clones are separate repositories: clone them with
  `-c core.autocrlf=false`, or a `#!/bin/sh\r` shebang makes the sandbox build
  die with a bare `exit code: 127`.
- **Host Python emits CRLF, and it only bites MULTI-LINE captures.** Python on
  Windows opens stdout in text mode, so `print()` writes `\r\n` even under Git
  Bash. Git Bash's command substitution strips the *trailing* CRLF, so
  `x="$(... | python -c 'print(v)')"` is clean — but interior CRs survive, so a
  two-line capture yields `id1\r` and `id2`. Every token except the last carries a
  CR, curl rejects those URLs with `Malformed input to a URL function`, and a loop
  silently processes only the last item — reporting `1/1` where the truth is
  `2/2`. Pipe through `tr -d '\r'` whenever a host-side Python prints more than
  one line. (Python run *inside* a container is fine: Linux, `\n` only.)
- `initdb.d` holds only `.sql` plus one deliberate `.sh`, and Superset provisions itself via
  an **inline compose command** rather than a mounted script. That is structural
  CRLF defence — keep it that way.
- Bash tool: prefix `docker compose exec` with `MSYS_NO_PATHCONV=1` or container
  paths get rewritten to Windows paths.
- Never bind-mount PGDATA or `/pkgs`. Named volumes only — the working tree is
  OneDrive-synced.
