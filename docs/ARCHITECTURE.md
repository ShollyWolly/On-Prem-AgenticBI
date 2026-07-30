# On-Prem Agentic BI — Technical Report

How the system works, end to end, and why it is built this way.

Audience: someone who has to operate, extend, or security-review this stack.
`README.md` is the operator quick-start; this document is the design rationale
and the request-path detail.

**Status:** all 92 automated checks in `scripts/verify.sh` pass, plus three smoke
suites (`test_pgmcp.py` 15/15, `test_superset_mcp.py` 18/18, and live agent turns
through `agent_turn.py`). Everything described below was executed and observed,
not designed on paper. Where something does **not** work, or works less well than
the architecture diagram implies, it is said so explicitly — see §3.4 and §11.

---

## 1. What problem this solves

Two consumers want the same warehouse:

- a **dashboard** for repeatable, curated questions;
- an **agent** for open-ended questions nobody built a chart for.

The naive version gives each of them its own database credential and its own copy
of the business logic. Then "revenue" means two different things, and PII
governance is enforced twice — which in practice means enforced once and forgotten
once.

This stack puts a **semantic layer** in the middle and makes it the only path to
the data. Metric definitions live there once. Access control lives there once. A
chat agent and a BI tool get the same numbers and the same redactions, because
neither of them is trusted to redact anything.

The demonstrable claim, stated precisely: **two identically-configured agents,
asked the same question, return masked or unmasked PII — and the only difference
between them is the SQL username their MCP server binds to the semantic layer
with.** Same image, same flags, same instructions, same model, same prompt. Any
difference in output is therefore the semantic layer's doing and nothing else.

An earlier version of this document claimed the distinction followed "who is logged
in". That was true when a custom MCP server forwarded the caller's e-mail on every
request; it is **not** true of the current build, where identity is bound to the
MCP container. The claim above is the one this stack actually supports, and §3.4
is explicit about the gap.

---

## 2. System overview — every container

16 long-running containers across four compose profiles, plus one that exists only
during setup. Nothing here is hidden: this section lists all of them, what each one
is for, and exactly how to look inside it.

### 2.1 What talks to what

```
                          ┌──────────────────────────────┐
                          │  Azure AI Foundry (INTERNET) │  the ONLY egress
                          └──────────────▲───────────────┘
                                         │ https, gpt-5-mini
 ═══════════════════════════════════════ │ ══════════════════════════════ host ══
                                         │
   ┌─────────────────────────────────────┴──────────────────┐
   │  librechat            :3080   chat UI + agent runtime  │
   │  (abi/librechat)              MCP client, LDAP login   │
   └─┬─────────┬──────────┬───────────┬──────────┬──────────┘
     │         │          │           │          │
     │ mongo   │ MCP/SSE  │ MCP/http  │ /v1/exec │ RAG /query, /embed
     ▼         ▼          ▼           ▼          ▼
 ┌────────┐ ┌──────────────────┐ ┌──────────┐ ┌──────────┐ ┌─────────┐
 │mongodb │ │ postgres-mcp x2  │ │superset  │ │ codeapi  │ │ rag-api │
 │ agents │ │ analyst :8001    │ │-mcp :5008│ │  :3112   │ │ embeds  │
 │ convos │ │ admin   :8002    │ │(read-only│ │ orchestr.│ │ locally │
 │ users  │ │ SAME image,      │ │ service  │ └──┬────┬──┘ └────┬────┘
 └────────┘ │ different SQL    │ │ account) │    │    │         │
            │ user = the demo  │ └────┬─────┘    │    │         │
            └────────┬─────────┘      │          │    │         │
                     │ pg-wire        │ reads    │    │         │
                     │ :15432         │ charts   │    │         │
                     ▼                │          │    │         │
   ┌──────────────────────────────────┼───┐      │    │         │
   │  cube                :4000 REST  │   │      │    │         │
   │  SEMANTIC LAYER — masking lives  │   │      │    │         │
   │  here. 5 views over 15 cubes.    │   │      │    │         │
   └──────────────┬───────────────────┼───┘      │    │         │
                  │ as cube_ro        │          │    │         │
                  │        ┌──────────┘          │    │         │
                  │        │ psycopg2            │    │         │
                  ▼        ▼  (one fixed user)   │    │         │
   ┌──────────────────────────────┐              │    │         │
   │ postgres  :55432  pgvector   │◄─────────────┼────┼─────────┘
   │  pagila | superset | vectordb│              │    │   embeddings
   └──────────────────────────────┘              │    │
                  ▲                              │    │
   ┌──────────────┴───────────┐    ┌─────────────▼──┐ │ ┌──────────────┐
   │ superset          :8088  │    │ codeapi-sandbox│ │ │codeapi-redis │
   │ dashboard, 9 charts      │    │ NsJail, /pkgs  │ │ │ BullMQ queue │
   └──────────────┬───────────┘    │ NO NETWORK     │ │ └──────────────┘
                  │                └────────────────┘ │
                  │ AUTH_LDAP            ▲            │
                  │                      │ tool calls │
                  ▼                ┌─────┴──────────┐ │ ┌──────────────┐
   ┌──────────────────────────┐    │codeapi-toolcall│ │ │codeapi-files │
   │ openldap                 │    │ only port the  │ │ │  plots out   │
   │ ONE userstore, no port   │    │ sandbox may    │ │ └──────┬───────┘
   │ ou=people / ou=groups    │    │ reach          │ │        │ S3
   └──────────────────────────┘    └────────────────┘ │        ▼
                  ▲                                   │ ┌──────────────┐
                  └───────────────────────────────────┘ │ garage       │
                        both front doors bind here      │ S3, no port  │
                                                        └──────────────┘
   cubestore (optional profile, off): Cube pre-aggregations. Not used.
```

Read the diagram as three claims:

1. **Every path to data goes through `cube`.** Neither `superset` nor the agents
   hold a warehouse credential; only Cube does (`cube_ro`, SELECT-only).
2. **`codeapi-sandbox` has no network.** The only address it can reach is
   `codeapi-toolcall`. That is why every Python library must be pre-baked into the
   `/pkgs` volume.
3. **Only `librechat` reaches the internet**, and only to Foundry for inference.

### 2.2 The containers, and how to inspect each

Profile column: `d` = default, `c` = chat, `s` = sandbox. Ports are `host->container`.

| Container | Image | P | Port | What it does | How to inspect |
|---|---|---|---|---|---|
| **abi-openldap** | `osixia/openldap:1.5.0` | d | — | The single userstore. `ou=people` (2 users), `ou=groups` (`analysts`, `admins`). Both front doors bind here | **No UI, no published port.** `./scripts/init-ldap.sh` re-verifies and prints the tree state. Manual: `docker exec -it abi-openldap ldapsearch -x -H ldap://localhost -D "cn=admin,dc=demo,dc=local" -w "$LDAP_ADMIN_PASSWORD" -b "dc=demo,dc=local" dn` |
| **abi-postgres** | `pgvector/pgvector:0.8.1-pg17-bookworm` | d | 55432->5432 | The warehouse. **Three databases**: `pagila` (demo data), `superset` (BI metadata), `vectordb` (RAG embeddings) | `docker exec -it abi-postgres psql -U postgres -d pagila`. `\l` lists all three. Port is 55432 to avoid clashing with a local Postgres |
| **abi-cube** | `cubejs/cube:v1.6.70` | d | 4000, 15432 | **The semantic layer and the governance boundary.** 5 views over 15 cubes; masking decided here | `:4000` serves only a "running in production mode" page — **the Playground is dev-mode only**. `/readyz` and `/livez` return 200. `/cubejs-api/v1/meta` returns 403 without a JWT. The real interface is the SQL API: `psql -h localhost -p 15432 -U analyst@demo.local -d cube` (password `CUBEJS_SQL_PASSWORD`) |
| **abi-superset** | `abi/superset:6.1.0-psycopg2` | d | 8088 | The dashboard: 9 charts, dark theme | **UI: http://localhost:8088** — log in with `admin@demo.local` and `DEMO_ADMIN_PASSWORD` (LDAP). Dashboard at `/superset/dashboard/agentic-bi/` |
| **abi-mongodb** | `mongo:8.0.20` | c | — | LibreChat's state: users, agents, conversations, file records | **No published port** (and `--noauth`). `docker exec -it abi-mongodb mongosh LibreChat` then e.g. `db.users.find({},{email:1,provider:1,ldapId:1})` |
| **abi-meilisearch** | `getmeili/meilisearch:v1.35.1` | c | — | Private full-text index for LibreChat conversations | **No published port.** Persists in `meilisearch_data`; `verify.sh V24` confirms the `messages` and `convos` indexes. |
| **abi-postgres-mcp-analyst** | `crystaldba/postgres-mcp:0.3.0` | c | 8001->8000 | MCP tool server bound to the **analyst** Cube role → PII masked | MCP over SSE, not a browser UI. `GET /sse` returns 200 and then holds the stream open. Real test: `python scripts/smoke/test_pgmcp.py` |
| **abi-postgres-mcp-admin** | `crystaldba/postgres-mcp:0.3.0` | c | 8002->8000 | Same image, same flags, **admin** SQL user → PII visible. The difference between these two containers *is* the demo | as above; the same smoke test exercises both and compares them |
| **abi-superset-mcp** | `abi/superset:6.1.0-psycopg2` | c | 5008 | `superset mcp run` — lets the reviewer agent read charts. Acts as the read-only `mcp_reader` account | `GET /mcp` correctly returns **405** (the route is POST-only); that 405 is what the healthcheck accepts. Real test: `python scripts/smoke/test_superset_mcp.py` |
| **abi-rag-api** | `abi/rag-api:0.8.0` | c | 127.0.0.1:8000->8000 | `file_search`: chunks and embeds user-attached documents **locally** (CPU), storing vectors in `vectordb` | FastAPI's developer reference is local-only at http://localhost:8000/docs; it is an API reference, not a user dashboard. `docker exec abi-rag-api python -c "import torch;print(torch.__version__)"` → `2.6.0+cpu`. Inspect the vectors: `docker exec -it abi-postgres psql -U postgres -d vectordb -c "select count(*) from langchain_pg_embedding"` |
| **abi-librechat** | `abi/librechat:v0.8.7` | c | 3080 | Chat UI, agent runtime, MCP client. The only container that reaches the internet | **UI: http://localhost:3080** — `analyst@demo.local` or `admin@demo.local` with the matching `DEMO_*_PASSWORD` (LDAP). Two agents each. Headless: `python scripts/smoke/agent_turn.py analyst "Pagila BI Analyst" "..."` |
| **abi-codeapi** | `abi/codeapi:latest` | s | 3112 | Code-execution orchestrator; LibreChat's `execute_code` target | `POST /v1/exec` only — a GET returns 404, which is not a fault. Exercised by `verify.sh V14` (direct) and `V18` (from inside librechat) |
| **abi-codeapi-sandbox** | `abi/codeapi-sandbox:latest` | s | — | Where agent Python actually runs, under **NsJail**. **No network**; `/pkgs` mounted read-only | `docker exec -it abi-codeapi-sandbox ls /pkgs` → `bash bun node python`. The wheels are under `/pkgs/python/<ver>/lib/python*/site-packages/` |
| **abi-codeapi-toolcall** | `abi/codeapi-toolcall:latest` | s | — | The **only** address the sandbox may reach. Proxies MCP tool calls back out | `docker logs abi-codeapi-toolcall` shows each tool call the sandbox made |
| **abi-codeapi-files** | `abi/codeapi-files:latest` | s | — | File server for generated plots; writes to Garage over S3 | `docker logs abi-codeapi-files`. This is where the Garage multipart bug appeared as `BUG: failed to parse server response` on Garage v1.0.1 — fixed by the v2.3.0 upgrade, not by a patch any more |
| **abi-codeapi-redis** | `redis:7-alpine` | s | — | BullMQ job queue for execution requests | `docker exec -it abi-codeapi-redis redis-cli -a "$CODEAPI_REDIS_PASSWORD" info keyspace` |
| **abi-garage** | `dxflrs/garage:v2.3.0` | s | — | S3 object storage behind the file server | **Distroless — there is no shell.** `docker exec abi-garage /garage -c /etc/garage.toml status`, or just run `./scripts/init-garage.sh`, which is idempotent and prints the layout/key/bucket state |
| *abi-cubestore* | `cubejs/cubestore:v1.6.70` | — | — | Cube pre-aggregation store. **Off** — the `cubestore` profile is not enabled | n/a |
| *(transient)* `codeapi-package-init` | built locally | — | — | Runs **once** to populate the `/pkgs` volume: compiles CPython with PGO, installs ~120 wheels. 20–45 min | `./scripts/build-sandbox-packages.sh`; idempotent on `/pkgs/.initialized`. Deletes itself when done |

### 2.3 One command to see the whole picture

```bash
docker compose --profile chat --profile sandbox ps
./scripts/verify.sh              # full verification suite across every container
```

A container being `healthy` proves less than it looks. Several healthchecks here
deliberately test something weaker than the thing you care about — Garage's daemon
answers RPC before its S3 layout exists, and slapd answers the root DSE before the
tree is populated. `verify.sh` is what checks the *contents*.

### 2.4 Credentials, in one place

Everything is generated by `scripts/gen-secrets.sh --apply` into `.env`, which is
gitignored.

| Surface | Who | Password from |
|---|---|---|
| Superset UI (8088) | `admin@demo.local` | `DEMO_ADMIN_PASSWORD` (LDAP) |
| LibreChat UI (3080) | `analyst@demo.local` / `admin@demo.local` | `DEMO_*_PASSWORD` (LDAP) |
| Cube SQL API (15432) | `analyst@demo.local` / `admin@demo.local` | `CUBEJS_SQL_PASSWORD` |
| Postgres (55432) | `POSTGRES_USER` | `POSTGRES_PASSWORD` |
| LDAP admin | `LDAP_ADMIN_DN` | `LDAP_ADMIN_PASSWORD` |

There is deliberately **no separate `SUPERSET_ADMIN_PASSWORD`**. It is wired to
`${DEMO_ADMIN_PASSWORD}` in compose: `SUPERSET_ADMIN_EMAIL` and `DEMO_ADMIN_EMAIL`
are both `admin@demo.local`, which is one person and one row in `ab_user` (the
e-mail column is unique). Two passwords for one identity meant the documented
`SUPERSET_AUTH=db` recovery path needed a credential that appeared in no document —
a break-glass path that does not work is worse than none. The local hash is
re-synced on every start by `align_ldap_usernames.py` and asserted by `verify.sh
V20`. The `SUPERSET_AUTH=db` fallback exists because with `AUTH_LDAP` an unreachable
directory locks every human out of the dashboard.

### 2.5 Volumes

| Volume | Holds | Lost on `down -v`? |
|---|---|---|
| `pgdata` | all three databases | yes — Pagila reseeds automatically |
| `ldap_data`, `ldap_config` | the directory | yes — `init-ldap.sh` recreates it |
| `mongo_data` | users, **agents**, conversations | yes — re-run `provision-agent.sh` |
| `superset_home` | Superset runtime state | yes — it re-provisions itself on start |
| `ragmodels` | the embedding model (~90 MB) | yes — re-downloaded on first start |
| `garage_meta`, `garage_data` | S3 objects | yes — `init-garage.sh` re-bootstraps |
| `librechat_images/uploads/logs` | uploaded files, logs | yes |
| `meilisearch_data` | private LibreChat conversation-search index | yes — rebuilt from MongoDB conversations and messages |
| **`codeapi_pkgs`** | CPython + ~120 wheels, 2.7 GB | **NO — `external: true`** |

That last row is deliberate. The volume is declared external precisely so
`docker compose down -v` cannot destroy 20–45 minutes of compilation. Recreating it
requires deleting it by hand.

### 2.6 Component inventory, versions

| Layer | Component | Version | Provenance |
|---|---|---|---|
| Userstore | OpenLDAP (`osixia`) | 1.5.0 (OpenLDAP 2.4.57) | pulled |
| Warehouse | PostgreSQL + pgvector | 17.8 / 0.8.1 | pulled |
| Semantic layer | Cube Core | v1.6.70 | pulled |
| Dashboard | Apache Superset | 6.1.0 | **derived image** (psycopg2, curl, fastmcp, python-ldap) |
| Chart tools | Superset MCP (SIP-187) | 6.1.0 | same image, different command |
| Warehouse tools | `crystaldba/postgres-mcp` ×2 | 0.3.0 | pulled, **stock and unmodified** |
| Agent host | LibreChat | v0.8.7 | **built from source** |
| Retrieval | `rag_api` | v0.8.0 | **built from source** |
| Code execution | ClickHouse `code-interpreter` | Apache-2.0 | **built from source**, no local patches |
| Object storage | Garage | v2.3.0 | pulled |
| Queue | Redis | 7-alpine | pulled |
| Agent state | MongoDB | 8.0.20 | pulled |
| Inference | Azure AI Foundry | gpt-5-mini | external |

Three deliberate reductions in component count, each of which upstream would have
made a separate container:

- **No `vectordb` container.** LibreChat's compose ships one; the vector store is a
  third *database* in the shared Postgres instead, which is why the image is
  `pgvector/pgvector`.
- **No custom tool server.** An earlier build had one (`cube-mcp`, ~700 lines of
  FastMCP with its own identity resolution and a SQL guard). It was deleted after
  testing showed two of its three guards were redundant — see §5.1.
- **No init containers anywhere.** Superset provisions itself in its own start
  command; everything else is an idempotent script under `scripts/`.

Three components are **built from source** rather than pulled. Two of the three needed
a replacement Dockerfile to build at all (§7, §5.5), which is the practical argument
for the choice. A third fix — the Garage multipart workaround — was carried as a patch
against the vendored source until the Garage v2.3.0 upgrade made it unnecessary; there
are no local patches now.

---

## 3. The identity spine

This is the heart of the system. One environment variable is the source of truth:

```
CUBE_USER_ROLE_MAP={"analyst@demo.local":{"role":"analyst"},
                    "admin@demo.local":{"role":"admin"}}
```

It is read by `config/cube/cube.js`. Nothing else in the stack decides who sees what.

There are now **two** distinct identity questions, and keeping them apart is the
single most important thing to understand about this build:

| Question | Answered by | Granularity |
|---|---|---|
| Who are you? | **OpenLDAP** — one directory, both front doors | per person |
| What data may you see? | **Cube**, from `CUBE_USER_ROLE_MAP` keyed on the e-mail | per *connection*, i.e. per MCP container |

LDAP unified the first. It did not touch the second. §3.4 says what that costs.

### 3.1 The chat path, request by request

```
1. Browser          user signs in to LibreChat as analyst@demo.local
                    ldapStrategy binds to OpenLDAP with mail={{username}};
                    on success the Mongo user is created/updated with
                    provider=ldap, ldapId=<uid>

2. LibreChat        agent turn begins. The agent's tools are named
                        execute_sql_mcp_cube_analyst
                    i.e. the MCP SERVER is chosen by the agent definition, not
                    by the signed-in user. There is no per-request identity
                    header any more.

3. postgres-mcp     the analyst container holds a static DATABASE_URI:
                        user = analyst@demo.local
                    It is the stock image with stock flags. The admin container
                    is byte-identical except for that username.

4. Cube             checkSqlAuth(req, "analyst@demo.local", pw)
                      -> securityContext {user, role:"analyst",
                                          groups:["analyst"]}
                    contextToAppId  -> "cube_analyst"   (compiler cache key)
                    contextToGroups -> ["analyst"]

5. Cube             compiles the query against the data model for that group.
                    access_policy on the VIEW decides, per member:
                      in member_level                     -> real value
                      in member_masking, not member_level -> MASKED value
                      in neither                          -> DENIED
                    The mask expression itself comes from `mask:` on the CUBE.

6. Postgres         Cube emits SQL as the read-only role cube_ro and gets rows.

7. back up          masked rows -> postgres-mcp -> LibreChat -> the model.
```

The model never sees the real value. Masking happens in the SQL Cube generates,
before the data leaves Postgres' result set — not as a post-filter in the agent,
and not as a prompt instruction.

Two things follow from step 2 that are easy to miss:

- The Cube tools are provisioned `allowed_callers: ["code_execution"]`, so the
  model cannot call them directly — it must write Python that calls them. That is
  what makes "query, compute in pandas, plot" the actual path rather than a hope.
- Because the server carries the identity, **the agent is the credential**. Handing
  someone the admin agent hands them admin data.

### 3.2 Why fail-closed is structural, not a rule

Three properties, none of which depend on anyone remembering a convention:

1. **`denied` is the default branch**, not a final `else if`. Adding a role later
   cannot accidentally reorder into something permissive.
2. **`denied` appears in no `access_policy`.** Cube denies access to every group
   that has no policy, so there is no deny rule to write and therefore none to
   forget.
3. **A startup assertion** in `cube.js` refuses to boot if the role map ever
   assigns `denied` to a real user, which would otherwise mint a silent super-user
   through a typo.

Observed behaviour for an unmapped identity: the connection *succeeds* (so the
error is clean and diagnosable) but the views are not even visible —
`Table or CTE with name 'revenue_analytics' not found`.

### 3.3 What we deliberately did NOT enable

`CUBEJS_SQL_SUPER_USER` is unset and `canSwitchSqlUser` is pinned to `false`.

That mechanism exists so one service account can re-scope per query with
`WHERE __user = 'someone'`. Our design is the inverse — the connection *carries*
the identity — so there is nothing to re-scope. And if it were enabled, the
agent's `execute_sql` tool would be precisely the client that could escalate
through it.

An earlier build also rejected the `__user` identifier in our own MCP server, on
the reasoning that a table allowlist cannot catch a virtual *filter*. That guard
turned out to be **redundant**: with `canSwitchSqlUser: () => false`, Cube itself
answers `Not allowed: Cannot change security context...`. It was tested rather than
assumed, and `test_pgmcp.py` now asserts the refusal against Cube instead of
against code we maintain. The same applied to the `SELECT *` guard — Cube's
"no masks on ungrouped queries" caveat concerns *measure* masks; dimension masks
survive `SELECT *`, which the same suite verifies. Deleting a control because it is
genuinely redundant is worth doing; deleting one because it is inconvenient is not,
and the distinction here is a test.

### 3.4 What LDAP does and does not buy — the honest limitation

OpenLDAP is a real single userstore. Both applications bind to it, neither keeps a
password of its own any more, and LDAP group membership maps to Superset roles
(`cn=admins` → Admin, `cn=analysts` → Alpha, re-synced at every login).

It does **not** make data authorization per-person. Three separate reasons, none of
which LDAP can fix:

1. **Superset holds one Cube credential** for the whole instance
   (`SUPERSET_CUBE_SQL_USER`). Signing in as a different LDAP user does not change
   which SQL user Superset queries Cube as.
2. **An agent's Cube role comes from its MCP container**, chosen by the agent
   definition, not by the session.
3. **Superset's MCP service has no per-user identity at all** in 6.1.0 — every call
   runs as the `mcp_reader` service account.

So the correct sentence for a stakeholder is: *one directory now authenticates
everyone, and the semantic layer still enforces masking — but the mapping from
"this person" to "this Cube role" is made by deployment topology, not by the
login.* Closing that gap does not require new Cube capability: `securityContext`
already supports it. It requires the client to pass the authenticated identity per
request — a JWT from an OIDC provider in front of Cube's REST API, or one Cube SQL
user per role with the app selecting between them. Both are client-side work.

Two migrations were needed to get even the login unified, and both are documented
because they fail in a way that looks like a wrong password:

- **Superset**: with `AUTH_LDAP_UID_FIELD = "mail"`, FAB matches the local record by
  `username == <the e-mail>`. `fab create-admin` had set `username=admin`, so FAB
  found nothing, tried to *register*, and hit the unique e-mail index.
  `config/superset/align_ldap_usernames.py` renames usernames to e-mails at every start.
- **LibreChat**: `ldapStrategy` looks up `findUser({ldapId})`, misses a pre-existing
  local user, and falls through to `createUser` with the same e-mail — same
  collision. `scripts/migrate-librechat-ldap.sh` sets `provider=ldap` and `ldapId`
  in place. Setting `ldapId` alone is not enough: a user whose provider is not
  `ldap` is refused with a bare `AUTH_FAILED`.

Both rename **in place** rather than deleting and letting LDAP recreate, because
the Superset admin owns the dashboard and all nine charts, and the LibreChat users
own both provisioned agents and every uploaded file. Recreating them would
have presented as "the agent disappeared".

### 3.5 The dashboard path

Superset holds **one** Cube credential (`SUPERSET_CUBE_SQL_USER`, default
`analyst@demo.local`). Every Superset user therefore shares one security context
and the dashboard shows masked PII to everyone.

This is a deliberate choice, not an oversight:

- A shared dashboard showing masked PII is the correct default.
- `DASHBOARD_RBAC` is switched **off** rather than on, because turning it on would
  imply per-user masking that this path cannot deliver — Superset would gate
  *which dashboard* you see, not *which values* you see.

Flipping `SUPERSET_CUBE_SQL_USER` to `admin@demo.local` gives an unmasked
dashboard, which is useful for a side-by-side demo. Real per-user masking in
Superset would need either one Cube SQL user per Superset role or database
impersonation.

---

## 4. The semantic layer

### 4.1 Model shape

15 cubes, all `public: false`, plus **5 views** which are the only queryable
surface:

- `revenue_analytics` — grain: payment. `total_revenue`, `count`, `avg_payment`,
  `paying_customers`, `paid_at`, plus customer / geography / store / staff / film
  attributes.
- `rental_analytics` — grain: rental. `count`, `distinct_customers`,
  `avg_rental_duration_days`, `open_rentals`, `rented_at`, `returned_at`.
- `customer_analytics`, `film_performance`, `store_performance` — agent-only.
  They give the chat agents genuinely different questions to answer than the two
  the dashboard is built on. No Superset dataset points at them, and `verify.sh`
  asserts exactly two datasets, so adding one would fail that check.

Separate views rather than one is a data-driven decision, not tidiness. See §6.

### 4.2 Where masking rules live — and why the split is not arbitrary

| Concern | Lives on | Reason |
|---|---|---|
| `mask:` expression | the **cube** | one definition; it travels into every view that includes the member |
| `access_policy.member_level` | the **view** | Cube member-level policies are **not inherited** by views. A `member_level` on a cube is dead code the moment a query targets a view — and every query does |
| `access_policy.member_masking` | the **view** | it requires `member_level` in the same policy |

Masked members and their masks:

| Member | Mask | Result |
|---|---|---|
| `customers_email` | `'***@' \|\| split_part(email,'@',2)` | `***@sakilacustomer.org` |
| `customers_full_name` | initials | `M. S.` |
| `addresses_phone` | last 3 digits | `***-***-123` |
| `staff_name`, `staff_email` | initials / domain | as above |
| `addresses_street` | constant literal | `*** redacted ***` |

The masks keep *some* signal (domain, initials, last digits) so an analyst can
still reason about "is this the same customer" without seeing the identity. That
is a governance design choice: blanking to `NULL` is indistinguishable from
missing data and generates support tickets.

`staff.password` and `staff.username` are **not modelled at all**. For a
credential hash, excluding beats masking — there is no legitimate analytical
query, so the safest representation is absence. Masking would still put the
column name in the model and invite the agent to select it.

### 4.3 Dev mode is a loaded gun

`CUBEJS_DEV_MODE=true` **disables member-level access control**. The masking demo
silently shows real PII, and nothing warns you.

Mitigation is two env profiles (`config/env/cube.dev.env`, `config/env/cube.demo.env`), the demo
running on `demo`, and `verify.sh V1` asserting the flag. Dev mode exists
only to iterate on the model with the Cube Playground.

---

## 5. The tool servers

Three MCP servers, none of them written by us. That is the interesting part: an
earlier build had a custom FastMCP server (`cube-mcp`, ~700 lines) and it was
deleted.

### 5.1 Why the custom server went away

It existed for three reasons. Each was tested, and two turned out not to hold:

| Reason it existed | What testing showed |
|---|---|
| Per-request identity via an `X-Cube-User` header | Real, and it is the one thing genuinely lost — see §3.4. Though note the header was trusted input from the client anyway |
| A guard rejecting `SELECT *`, because Cube does not mask ungrouped queries | Cube's caveat is about **measure** masks. Dimension masks *do* survive `SELECT *`. Verified: the analyst still sees `***@sakilacustomer.org` |
| A guard rejecting `__user`, invisible to a table allowlist | Cube itself refuses it — `Cannot change security context...` — because `canSwitchSqlUser` is pinned `false` |

Two of the three were redundant. The controls now live in the semantic layer, which
is where the thesis says they belong, and `test_pgmcp.py` asserts them **against
Cube** rather than against code we maintain. Deleting ~700 lines of
security-adjacent code that duplicated an upstream control is a real reduction in
what can rot.

Deleting a control because it is genuinely redundant is worth doing; deleting one
because it is inconvenient is not. The difference here is that both were tested
first, and the tests are still in the suite.

### 5.2 `postgres-mcp` ×2 — the masking contrast

Two containers of `crystaldba/postgres-mcp:0.3.0`, **same image, same flags**,
differing only in the SQL username inside `DATABASE_URI`. That symmetry is the
experiment: with everything else held constant, any difference in output is
attributable to the semantic layer alone.

Operational details that cost time to find:

- **`--access-mode=unrestricted` is required.** Restricted mode rejects `MEASURE()`,
  which is the one function every Cube query needs. Safe here because Cube refuses
  INSERT/DROP regardless and `cube_ro` is SELECT-only — verified, not assumed.
- **Only four of its nine tools work** against Cube (`execute_sql`, `list_schemas`,
  `list_objects`, `get_object_details`). The rest need `pg_stat_statements`,
  `hypopg` or `pg_indexes`, none of which a semantic layer implements. 0.3.0 has no
  server-side flag to disable them, so `provision_agent.py` simply does not attach
  them and the model never sees them.
- **Transport is SSE**, not streamable-http: 0.3.0 is the newest released image, and
  streamable-http was merged upstream but never shipped in a release.
- **After `docker compose restart cube`, restart these two as well.** They pool
  connections and do not validate them on checkout, so the first query to reuse a
  dead socket fails with `server closed the connection unexpectedly` — which, on the
  admin server, reads exactly like the admin role having lost its access.

### 5.3 Superset MCP — the reviewer agent's tools

Superset 6.1.0 ships its own MCP service (SIP-187). It runs as a second container,
`superset mcp run`, and gives the Dashboard Reviewer agent read access to the charts
that already exist.

- **Every tool takes ONE argument, an object called `request`**, with the real
  arguments nested inside: `{"request": {"identifier": 10}}`. Charts are addressed
  by `identifier` (id, uuid or slug), never `chart_id`. Flat arguments fail pydantic
  validation and the middleware reports `Internal error ... contact support`, which
  points nowhere near the cause.
- **A single POST answers with several SSE frames.** The tools log through the MCP
  logging capability, so N `notifications/message` frames precede the result. Taking
  the first `data:` line yields a log line that parses fine as JSON and has no
  `result` key — i.e. it reads as "the tool returned nothing". Match on the request
  `id`.
- **`get_chart_data`'s `limit` REPLACES the chart's row limit** rather than capping
  it: chart 10 returns 15 rows with no limit and 100 with `limit=100`. An agent that
  passes a limit and then reports "the title says Top 15 but it returns 108 rows" is
  describing its own argument. Observed; now forbidden in both instruction files.
- **`mcp_reader` is the entire security boundary.** 6.1.0 resolves the acting user
  from `MCP_DEV_USERNAME` or Preset's proprietary `g.user`; `default_user_resolver`
  is dead code. Individual tools cannot be disabled on the CLI path either
  (`MCP_FACTORY_CONFIG.exclude_tags` is only read when `use_factory_config=True`).
  So the account is read-only and deliberately lacks `can_execute_sql_query`;
  `test_superset_mcp.py` asserts the refusal from outside the container.

### 5.4 What the reviewer agent actually found

Worth reporting, because it is evidence the architecture does something rather than
merely being drawn correctly.

Asked to reconcile the dashboard against its KPI tiles, the agent reported that
"Revenue by Category" summed to **$159,539.15** against a total revenue of
**$67,416.51** — a 2.37× over-count.

It was right, and the cause was in our own semantic layer: `public.film_category` is
many-to-many in this dataset (2367 rows for 1000 films). Joining it fans every film
row out, so any additive measure sliced by category over-reports. Cube and
hand-written SQL produce the inflated number *identically*, because it is what the
join says. Sixteen plausible bars, no error, no warning — the failure mode this
whole project treats as the dangerous one.

The fix (`film_primary_categories`, joined `one_to_one`) and its own second-order
trap — `MIN(category_id)` is stable but correlates with the id, draining revenue
down the id order and fabricating a trend — are in §4. `verify.sh V1b` now
reconciles the breakdown against the total on every run.

The same session also produced one confident **fabrication**: the agent claimed a
"Top 15" chart really returned 108 rows. It did not; the agent had passed its own
`limit` and then reported the consequence as a defect. Both outputs came from the
same tool in the same conversation, which is the honest summary of what an LLM
reviewer is worth here: it surfaced a real bug that had survived review, and it
invented one that would have wasted a fix. The instruction files now require row
counts to be quoted from `row_count`, and — more importantly — the *verification*
layer stayed deterministic. `verify.sh` is what gates correctness; the agent is what
suggests where to look.

### 5.5 `rag_api` — retrieval, and why it is built from source

`file_search` is reserved for documents users attach in chat. Shared business rules
are a compact appendix in the agent system prompt, so their availability does not
depend on retrieval.

Embeddings are computed **locally** (`all-MiniLM-L6-v2`, 384-dim, CPU). Not
incidental: Foundry has no embeddings deployment at all (`text-embedding-3-small`,
`-large` and `ada-002` all answer `unknown_model`), and sending document text to a
hosted embedder would contradict the on-prem premise. It is also why the `-lite`
image is unusable — it ships no `sentence-transformers`.

Building from source surfaced three upstream defects that the prebuilt image hides:

1. **Unbounded pip backtracking.** `requirements.txt` pins
   `opencv-python-headless==4.9.0.80` while `rapidocr-onnxruntime` requires an
   unpinned `opencv-python`. Pip walks backwards through opencv releases — ~75 MB
   per probe — with no error message, so the build appears to hang mid-`pip
   install`. Even when it converges, the version chosen depends on the state of PyPI
   that day, so it is not a pin at all. Fixed with a constraints file.
2. **CUDA torch for a CPU workload.** `sentence_transformers` depends on torch
   unpinned, and the default wheel is the CUDA build: over **1.5 GB of `nvidia_*`
   packages** measured mid-build, plus a 526 MB torch, for a container that then logs
   `Use pytorch device_name: cpu`. Now `torch==2.6.0+cpu` (178 MB) from PyTorch's CPU
   index, constrained so nothing pulls the CUDA build back, with a build-time
   `assert not torch.version.cuda`. Final image **3.73 GB vs 7.79 GB** pulled.
3. **nltk 3.10's download path allowlist.** `-d /app/nltk_data` is refused as an
   "Unauthorized path"; the CLI then prints `Retry? [n/y/e]` and calls `input()`, so
   the visible failure is `EOFError` with the real cause buried six lines above.
   Fixed by setting `NLTK_DATA` *before* downloading and using the programmatic API.
   This one matters beyond tidiness: without the corpora baked in, `unstructured`
   fetches them at **runtime**, which would quietly falsify "Foundry is the only
   egress".

`verify.sh V22` asserts pgvector is enabled in the right database and that the
local embedding runtime and its model weights are available. A clean installation
has no vectors until a user attaches a document.


## 6. The data, and what it forced

Pagila, vendored at commit `5ba5a57`. Everything below was **measured**, and each
finding changed the design.

`30-date-shift.sql` relocates the all-2022 data into the trailing months, because
otherwise every relative-date filter renders empty and the whole stack looks
broken.

### 6.1 Two independent date families

| Column | Rows | Shift applied |
|---|---|---|
| `rental.rental_date` / `return_date` | 16 044 | **1425 days** |
| `payment.payment_date` | 16 049 | **1462 days** |

The shifts differ by 37 days because the two families are generated
independently in this fork: 51 % of rentals postdate the last payment, and
**rentals have no rows at all in two consecutive months**.

Consequences, both load-bearing:

- **All revenue trends are built on `payments.paid_at`.** A line chart on
  `rented_at` renders a two-month gap that reads as a data-pipeline fault.
- **The two Cube views are separate.** One view forcing revenue onto `rental_date`
  would misdate all revenue; joining payments into a rental-grained view would
  fan out `SUM(amount)`.

`rental_date`, `return_date` and `last_update` receive the **identical** interval,
which is the only reason `avg_rental_duration_days` is trustworthy (0.75–9.25
days, mean 5.03, zero negatives — verified after the shift).

### 6.2 The partitioned-`payment` problem

`payment` is `PARTITION BY RANGE (payment_date)` with seven monthly partitions
covering 2022. Postgres 11+ *can* move rows across partitions during `UPDATE`, but
only into a partition that **already exists**. Shifting by ~4 years puts every row
outside all seven ranges, so a plain `UPDATE` dies:

```
ERROR: no partition of relation "payment" found for row
```

Strategy: stage into an `UNLOGGED` table → drop all seven partitions → create
monthly partitions across the new range (+1 month headroom) → re-insert and let
the router place rows → re-add the three FKs **on the parent** → `setval` both
sequences.

Chosen over "pre-create future partitions then UPDATE" because it does not depend
on row-movement semantics and leaves no empty 2022 partitions behind. Safe because
**nothing references `payment`** — verified: zero `REFERENCES public.payment` in
the schema. Note the FKs are declared per-partition upstream; re-adding them on
the parent is strictly better, since PG12+ propagates parent FKs to future
partitions.

The script also sets `session_replication_role = 'replica'` for its duration. A
`last_updated` BEFORE-UPDATE trigger exists on **15 tables**; without suppressing
it, every UPDATE stamps `last_update = now()` and destroys that column.

### 6.3 What the data cannot support

Stated explicitly so nobody builds them:

- **No signup/cohort chart.** `customer.create_date` is a single constant value
  for all 599 rows.
- **No map.** There is no lat/long anywhere in Pagila, only place names.
- **No 24-month x-axis.** The span is ~7.3 months and a shift relocates a window
  without widening it. A "stretch" transform would fill 24 months but multiplies
  every rental duration by ~3.2×, taking mean duration from 5.0 to 16.1 days and
  making the duration KPI a lie. Rejected; documented as opt-in only.

### 6.4 Seeding integrity

`initdb.d` runs alphabetically under `ON_ERROR_STOP=1`. The shift ends with
assertions that `RAISE EXCEPTION` on: zero rentals or payments in the last 30
days, any `return_date < rental_date`, any payment in the future. **A failed seed
aborts the container** rather than producing an empty dashboard, because a broken
seed that starts anyway is far more expensive to debug later.

`99-seed-complete.sql` writes a sentinel row, which the healthcheck requires. The
healthcheck has two gates and both are necessary:

```
pg_isready -h 127.0.0.1 -U $POSTGRES_USER   &&   select 1 from seed_complete
```

`-h 127.0.0.1` forces **TCP**: during `initdb.d` the temporary server listens on
the unix socket only (`listen_addresses=''`), so a socket-based probe reports
"ready" mid-seed and Cube would start against half-loaded Pagila and cache a
broken model. `-U` is not cosmetic either — without it `pg_isready` sends the OS
user and logs `FATAL: role "root" does not exist` every five seconds forever,
which reads as a broken stack during a demo.

Verified totals: 16 044 rentals, 16 049 payments, revenue **67 416.51** — and the
same 67 416.51 comes back through Cube's `MEASURE(total_revenue)`, which is the
cheapest proof that the semantic layer is not quietly changing the numbers.

---

## 7. Code execution

### 7.1 Topology and why it is six containers

`codeapi` (gateway + workers in one process, `local-api.ts`), `codeapi-sandbox`
(NsJail executor), `codeapi-files`, `codeapi-toolcall`, `codeapi-redis`,
`garage`.

This is the verified **floor**, not a preference:

- `service/src/file-server.ts` hardcodes an S3 client — there is no
  local-filesystem backend, so object storage is mandatory.
- Redis/BullMQ carries the job queue and is not optional.
- We do already use the combined `local-api` build, which folds the API and the
  workers into one process instead of two.

**Garage, not MinIO.** MinIO relicensed and gutted its community edition. Garage
is AGPL-3.0 and a single self-contained binary.

Garage needs a one-time cluster bootstrap, and it is worth understanding why:
until a **layout** is assigned and applied, the S3 port answers but every write
fails — so "the port is open" proves nothing, which is exactly the kind of
half-ready state that produces confusing downstream errors. `V15` in the
verification suite checks the layout, key and bucket rather than the port.

`scripts/init-garage.sh` performs that bootstrap idempotently: layout assign +
apply, `key import`, `bucket create`, `bucket allow`. It **imports** the S3
credentials from `.env` rather than letting Garage generate them, which is what
keeps them deterministic so `codeapi-files` can read them straight from the
environment — generated keys would have to be captured and injected, forcing a
restart. Creating the bucket here also means the key never needs
create-bucket privilege.

Garage's own secrets (`GARAGE_RPC_SECRET`, `GARAGE_ADMIN_TOKEN`) are passed via
the environment rather than written into `garage.toml`, because Garage refuses to
start when a config file containing secrets is group/world-readable — and a
bind-mounted file on Docker Desktop always is.

### 7.2 Isolation — state this plainly to stakeholders

`/dev/kvm` **does not exist in Docker Desktop** (verified on this host), so the
libkrun microVM path is unavailable. The sandbox runs **NsJail-only**, which
**shares the host kernel**. Upstream's own assessment: appropriate for local
development, *not* for executing untrusted code.

For an on-prem PoC with two named internal users this is acceptable. It should be
revisited before wider exposure. The mitigations that *are* in place: no network
from executed code (`SANDBOX_DISABLE_NETWORKING=true`, the only reachable port
being the tool-call server), per-job UIDs, a workspace reaper, CPU-time and
wall-clock caps, and an output size cap.

Three configuration details are each individually fatal if missed, and mirror
upstream's `docker-compose.mac.yml` (which exists because macOS also lacks
`/dev/kvm`): build target `sandbox-build`, the overridden entrypoint
`/sandbox_api/entrypoint.sh`, and packages mounted at **`/pkgs`** (the KVM path
uses `/host-packages`).

### 7.3 Packages must be baked in

Executed code has no network, so there is no runtime `pip install` — and an agent
that tries will simply fail. `scripts/build-sandbox-packages.sh` populates a
named volume once: CPython 3.14.4 compiled from source with PGO, plus pandas,
numpy, matplotlib, seaborn, plotly, scipy, scikit-learn, pyarrow and ~110 more.
**2.7 GB, 20–45 minutes, once.** `/pkgs/.initialized` is the idempotence marker.

Verified working in the sandbox: pandas 3.0.5, numpy 2.4.6, matplotlib 3.11.1,
with a PNG written to `/mnt/data` and returned as a file.

### 7.4 Programmatic tool calling — the actual mechanism

This is widely misunderstood, so precisely: **the sandbox does not call the MCP
server.** It is a host-side round trip.

```
1. model            asks for run_tools_with_code with Python that calls query()
2. codeapi          runs the code; the query() call hits a stub
3. codeapi          returns {status:"tool_call_required", continuation_token, …}
4. LibreChat        executes the REAL MCP tool in its own Node process
                    -> so the {{LIBRECHAT_USER_EMAIL}} header resolution is
                       IDENTICAL to the direct path
5. LibreChat        POSTs tool_results back with the continuation token
6. codeapi          resumes the Python where it left off, now with real rows
7. sandbox          pandas-processes, matplotlib-plots, saves to /mnt/data
8. LibreChat        renders the returned PNG inline
```

Two important consequences:

- **The per-user identity story holds through PTC.** The tool call originates from
  LibreChat, carrying the same resolved header.
- **The sandbox needs no network access to reach Cube**, which is why
  `SANDBOX_DISABLE_NETWORKING=true` is compatible with a data-querying agent.

The agent is provisioned with `tool_options[...].allowed_callers =
['code_execution']`, which makes the Cube tools **invisible to direct
tool-calling**. The model therefore *must* route through `run_tools_with_code`.
That converts "hopefully the model writes Python and plots" into a structural
guarantee.

### 7.5 Plot delivery

Plots go through **Code Interpreter file outputs**, not MCP-returned images.

Deliberate: LibreChat's MCP image rendering is provider-dependent, and the
Azure/OpenAI-compatible path — which is exactly our Foundry path — flattens
structured tool content to a string, so images arrive as raw base64 text. The
`artifacts` capability is enabled as a second, independent plot path (HTML/
Recharts), which sidesteps image plumbing altogether.

---

## 8. Dashboard

### 8.1 Provisioning is code, not clicks, and needs no init container

The usual advice is to build charts in the UI and export them, because chart
`params` and dashboard `position_json` are large, version-sensitive blobs. True —
but it also means the dashboard is only reproducible by a human repeating a
click-path.

Instead: `config/superset/assets/` holds hand-authored `metadata.yaml`,
`databases/cube.yaml` and the two dataset YAMLs (small, stable, genuinely worth
diffing), and `config/superset/build_dashboard.py` constructs the nine charts and the
layout tree programmatically. Superset runs both during its own startup, so
`down -v && up -d` reproduces the entire demo unattended.

Datasets declare their columns **explicitly**, including `is_dttm: true` and
`main_dttm_col`. This is deliberate: never rely on type introspection through
Cube's pg-wire protocol. Metrics use `MEASURE(x)` for the reason in §5.1.

### 8.2 The time-grain trap

Superset's generated time-series SQL needs the x-axis expressed as an adhoc
**`BASE_AXIS`** column carrying `timeGrain`:

```json
{"timeGrain":"P1M","columnType":"BASE_AXIS","sqlExpression":"paid_at",
 "label":"paid_at","expressionType":"SQL"}
```

Setting `extras.time_grain_sqla` alone is **silently wrong**: the query succeeds
and returns ungrouped raw rows — one per payment — which renders as a dense
scribble that looks like real data. Caught here by checking row counts (1000 raw
rows vs 7 monthly rows), not by eyeballing the chart.

### 8.3 Charts, and the form choices

Nine charts: a four-tile KPI row, a revenue time-series, three bar charts, and a
top-10 table.

Every bar chart is **single-series**: the x-axis is the category and `groupby` is
empty, so all bars are slot-1 blue. Colouring each bar differently would encode
rank as hue, which carries no information — the classic colour-by-rank
anti-pattern. No dual-axis charts: two scales means two charts. No map (§6.3). No
sparkline on average rental duration, which has no meaningful trend.

The palette is a validated dark categorical set (worst adjacent CVD ΔE 8.4 protan,
all eight ≥ 3:1 contrast on the `#131922` card surface) applied through
`EXTRA_CATEGORICAL_COLOR_SCHEMES` — a mechanism entirely separate from the AntD
theme tokens. Slot **order** is the CVD-safety mechanism, so it must not be
re-sorted.

### 8.4 Theme API churn

For the record, because most guides on the internet are now wrong for 6.1:

- `THEME_OVERRIDES` was **removed in 6.0**.
- `THEME_DEFAULT_MODE` **does not exist** in 6.1 — setting it is a silent no-op.
- The working mechanism is `algorithm: "dark"` inside `THEME_DEFAULT` plus
  `THEME_DARK = None`.
- Assigning `THEME_DEFAULT` **replaces** the upstream dict, so `brand*` tokens
  must be re-declared or they vanish.

Also: `superset import-assets` does not exist in OSS Superset (that is
`preset-cli`), and `superset import-directory` takes **no** `-u/--username`.

### 8.5 Dropped services

Redis, Celery worker and beat are all absent. This is only safe because
`run-server.sh` defaults to `--workers 1` (gthread ×20), which makes in-process
`SimpleCache` coherent. Lost: async SQL Lab (fine at 16 k rows), Alerts & Reports,
thumbnails.

**Hard rule:** if `SERVER_WORKER_AMOUNT` is ever raised, the four cache configs
must move to `RedisCache` **first**, or dashboard filter state breaks
non-deterministically across processes.

---

## 9. LibreChat

Built from source so the code is editable, but **not** with upstream's Dockerfile.
Two defects combine into a silently broken image on Windows:

1. Docker's `COPY` from a Windows build context strips the owner write bit, so
   `/app/packages/*` land as `dr-xr-xr-x`. rolldown then cannot create `dist/`
   and the workspace build fails with `Permission denied (os error 13)`.
2. Upstream's build step is `npm run frontend;` — a **semicolon**, not `&&`. The
   failure is swallowed, `docker build` reports success, and the image ships with
   empty `packages/*/dist`. The container then crash-loops on
   `Cannot find module '@librechat/data-schemas/dist/index.cjs'` with nothing in
   the build log to explain it.

`docker/librechat/Dockerfile` adds `chmod -R u+w /app` before the build, uses
`&&`, and asserts the artefacts exist — so a broken build fails at build time.

Bind mounts are **subdirectory by subdirectory** (`api/server`, `api/models`, …).
Mounting `./vendor/LibreChat/api` over `/app/api` shadows the image's
`/app/api/node_modules` and the container dies on `Cannot find module
'compression'`. `client/` is not mounted at all, because the Vite bundle lives at
`/app/client/dist` inside the image and a mount hides it, serving a blank page.

Meilisearch provides private full-text search over LibreChat conversations. It has
no published port and stores its index in a named volume. `rag_api` separately backs
`file_search`; its vector store is a third database in the shared Postgres rather
than a separate container.

### 9.1 Two configuration traps

**MCP SSRF protection is on by default** whenever `mcpSettings.allowedAddresses`
is empty, and it blocks Docker-internal private IPs. The only symptom is "MCP
server failed to initialize" with no stated cause. Entries must be bare
`host:port` — no scheme, no path, no CIDR, port mandatory — and a malformed entry
is dropped silently.

**All six agent capabilities must be enumerated**, because specifying
`capabilities` **replaces** the default array and `programmatic_tools` is not in
the defaults: `execute_code`, `tools`, `artifacts`, `programmatic_tools`,
`actions`.

### 9.2 "0 tools" at startup is correct

LibreChat logs `Initialized with 1 configured server and 0 tools` for `cube`.
This is **not** a fault.

Because our MCP config carries `{{LIBRECHAT_USER_EMAIL}}` in its headers,
`hasRuntimeContextPlaceholders()` is true, and `MCPServerInspector.inspectServer()`
deliberately **skips startup inspection** — a per-user MCP server can only be
resolved per request, so its tools are discovered lazily inside a user session.

Practical consequence: `GET /api/agents/tools` returns no cube tools before any
user session exists, so `provision_agent.py` constructs the ids deterministically
as `<tool>_mcp_cube` (`Constants.mcp_delimiter = '_mcp_'`) instead of discovering
them.

### 9.3 Agent provisioning

Agents cannot be declared in `librechat.yaml` — issue #7741 is open, and
`interface.agents` only seeds role permissions. `POST /api/agents` is scriptable
and accepts `tool_options`, so provisioning is IaC.

Three API quirks worth knowing:

- **A browser-like `User-Agent` is mandatory.** LibreChat's `uaParser` middleware
  answers `{"message":"Illegal request"}` on an SSE channel otherwise, which looks
  nothing like the header problem it is.
- **Updates are `PATCH /api/agents/:id`**, not `PUT`. `PUT` returns a bare 404
  that reads like a wrong agent id.
- **Sharing is not possible.** An agent created via `POST /api/agents` gets **no
  ACL entry even for its author**, so `PUT /api/permissions/agent/:id` answers
  `Forbidden` to the creator, and `isCollaborative` is accepted (HTTP 200) but not
  persisted. A single admin-owned agent is therefore invisible to the analyst.
  Hence one identical agent **per user** — which also happens to be how the
  masked/unmasked contrast is expressed, since the Cube role rides on the agent.

The provisioner runs on the **host, using only the standard library**, so it needs
no pip install and no container to borrow. It is Python rather than PowerShell
because Windows PowerShell 5.1's `Invoke-RestMethod` hangs indefinitely against this
API even though the server answers 201 in under half a second — and shelling out to
`curl.exe` from PowerShell hit the same wall.

Note the **resumable** controller: `POST /api/agents/chat/agents` returns
`{"streamId": ...}` and nothing else; the events come from a separate
`GET /api/agents/chat/stream/<id>`. Reading the POST as SSE yields one line and
looks exactly like an agent that produced nothing.

---

## 10. Inference

Azure AI Foundry is the only egress: `endpoints.custom` →
`https://alh-ai-foundry.cognitiveservices.azure.com/openai/v1`, model
`gpt-5-mini`.

Two details:

- The host is `*.cognitiveservices.azure.com`, **not** the
  `*.services.ai.azure.com` form in some Microsoft docs. Both front the same
  `/openai/v1` route. Verified working with `Authorization: Bearer`.
- **No trailing slash.** LibreChat appends `/chat/completions` itself, so a
  trailing slash produces `/v1//chat/completions` and a 404.

`models.fetch` is `false` because Foundry's model-list response shape differs from
the OpenAI format and yields an empty dropdown.

Everything else — data, semantic layer, dashboards, agent state, code execution —
stays on the host. Swapping to a fully local vLLM or Ollama is a change to one
`endpoints.custom` block.

---

## 11. Security posture, stated honestly

| Area | Current state | Recommendation before wider use |
|---|---|---|
| PII masking | Enforced in Cube, per Cube role, verified three ways | Keep `verify.sh V1` and `V1b` in CI |
| **Authentication** | **OpenLDAP is the single userstore**; both front doors bind to it, group→role mapping works | Fine as a PoC; put TLS on it (§below) |
| **Data authorization** | **NOT per person.** An agent's Cube role comes from its MCP container; Superset holds one Cube credential | Pass the authenticated identity per request — OIDC/JWT to Cube's REST API, or one Cube SQL user per role |
| LDAP transport | **Plain LDAP, no TLS.** Simple bind sends the password in clear; no port published | Enable TLS and mount the CA into both clients |
| LDAP version | `osixia/openldap:1.5.0` = OpenLDAP **2.4.57, an EOL series** (newest stable tag is 2021; only newer tag is `2.6.10-alpha`) | Pin a maintained 2.6 build; do not carry this image to production |
| Superset MCP | No per-user identity in 6.1.0 — every call runs as `mcp_reader`, which is read-only and lacks `can_execute_sql_query` | That account's role IS the boundary; keep `V21` asserting the refusal |
| Sandbox isolation | **NsJail, shares host kernel** (no `/dev/kvm` in Docker Desktop) | Run on a KVM-capable Linux host for the microVM path |
| codeapi auth | `LOCAL_MODE=true` and LibreChat sends **no** Authorization header (`CODEAPI_AUTH_PROVIDER=none`). codeapi's `localAuth` never reads it, so all code sessions bucket under one principal | Real JWT auth needs the **split api+worker build** — our `local-api` image mounts `localAuth` unconditionally, so `setup-local-auth-env.js` alone is not enough |
| MongoDB | `--noauth`, port never published | Enable auth |
| Warehouse access | Cube connects as `cube_ro`, SELECT-only, `CREATE` revoked | Fine as-is |
| Superset → Cube | One shared credential; `DASHBOARD_RBAC` off | Per-role Cube users if per-user dashboards are needed |
| Retrieval | Embeddings computed **locally** (CPU); document text never leaves the host; NLTK corpora baked in so nothing is fetched at runtime | Fine as-is |
| Transport | Plain HTTP on localhost, `TALISMAN_ENABLED=False` | TLS + re-enable Talisman |
| Agent SQL | Stock `postgres-mcp` in `--access-mode=unrestricted`; the *semantic layer* is the control, and only 4 tools are attached | Keep the tool allowlist in `provision_agent.py` |
| Secrets | Generated locally, `.env` gitignored | Move to a secret manager |

The masking claim is worth being precise about: it is enforced by Cube in generated
SQL, and it is verified independently at three layers — raw psql over the SQL API,
the MCP tool surface, and the Superset connection. It does **not** depend on the
agent's prompt, on any MCP server behaving well, or on the model choosing to comply.

The claim that is **not** supported: that a person's login determines what they see.
It does not. See §3.4 — and say so out loud when demoing, because the architecture
diagram invites the opposite assumption.

---

## 12. Verification

`scripts/verify.sh` — the full verification suite, plus three smoke suites. Confirmed
after a full `down -v` teardown and rebuild from scratch.

| Check | Guards against |
|---|---|
| **V1** | masking silently no-op (fails *open-looking* — the one that matters most) |
| **V1b** | a breakdown that does not reconcile to its total — the join fan-out that produced 16 plausible bars and a 2.37× over-count |
| V2 | Cube healthy but every query throws (cache/queue driver default) |
| V3 | date-shift row loss or empty relative-date windows |
| V4 | masking through the two stock MCP servers, over real MCP protocol, incl. `SELECT *` and `__user` refusals |
| V5 | healthcheck binaries absent from base images |
| V6 | any MCP server silently blocked by the SSRF guard |
| V7 | Cube rejecting Superset's time-grain alias shadowing |
| V8 | OneDrive dehydrating a bind-mounted file |
| V9 | CRLF in anything a Linux container executes |
| V10 | sandbox missing baked-in packages |
| V11 | Foundry base URL / auth shape |
| V12 | `SUPERSET_SECRET_KEY` drift breaking the stored credential |
| V13 | Superset provisioning / dashboard build failure |
| **V14** | sandbox actually running Python and returning a plot |
| V15 | Garage cluster not bootstrapped (its S3 port answers before it is usable) |
| V16 | an agent invisible to a demo user (LibreChat grants no ACL entry to an agent's author) |
| **V17** | LibreChat codeapi auth incoherent — signing enabled with no key, which kills execute_code AND all data access |
| **V18** | the real LibreChat→codeapi path (V14 tests codeapi in isolation and cannot catch this) |
| **V20** | LDAP: binds, `memberOf` populated, both front doors accepting the e-mail, wrong password rejected, roles mapped from groups, both Mongo users migrated |
| **V21** | Superset MCP serving chart data *and* refusing `execute_sql` to its service account |
| **V22** | one Postgres, pgvector present, torch is CPU-only, NLTK baked in, and local RAG ready for user uploads |
| V23 | capabilities listed but not wired — `artifacts` empty on the agent record, or `file_search` missing |

V1, V1b and V14 are the three that prove the product claim: governance is real,
the numbers reconcile, and the agent can actually compute and plot.

Smoke suites, all runnable from the host:

```bash
python scripts/smoke/test_pgmcp.py         # 15 checks, incl. the masking contrast
python scripts/smoke/test_superset_mcp.py  # 18 checks, incl. the read-only refusal
python scripts/smoke/agent_turn.py analyst "Dashboard Reviewer" "your prompt"
```

`agent_turn.py` is the only test that goes **through LibreChat**, so it is the only
one that can catch a broken agent record, a bad tool id, or an MCP server the SSRF
guard has blocked.

### 12.1 A note on the tests themselves

Four checks in this suite were, at some point, **wrong in a way that reported a
working system as broken** — and one reported a partial result as a complete one,
which is worse. They are recorded because the class of error recurs:

- Reading `artifacts`/`tools` off `GET /api/agents`, which returns a **list
  projection** without them.
- Host Python emits CRLF; Git Bash strips only the *trailing* one, so of two agent
  ids the first carried a `\r`, curl rejected it, and the check reported `1/1` when
  the truth was `2/2`.
- Two build-log greps that matched their own search string in the command BuildKit
  echoes (`opencv_python_headless` when looking for `opencv_python`; the literal text
  of an assertion message).
- `rc=${PIPESTATUS[0]}` after a command substitution, which reads the assignment's
  status rather than the subshell pipeline's — so a rate-limit became a FAIL instead
  of a SKIP.

The lesson applied throughout: a check must fail for the reason it claims, and
"passed" must not be reachable by measuring the wrong thing. Where a check now
depends on an exit code, it reads a real exit code rather than inferring one from
log text.

---

## 13. Windows / OneDrive

The project sits in a OneDrive-synced path, which caused three distinct failures
during the build. All are now guarded, but they are worth knowing.

**CRLF is a functional bug here, not a style preference.** It bit three times, in
three different file types:

1. `*.sh` — `#!/bin/sh\r` makes the kernel report "not found"; the sandbox image
   build dies with a bare `exit code: 127` pointing nowhere.
2. `*.py` — codeapi injects user code into `matplotlib.py` by regex-matching
   `# BEGIN USER CODE\n`. With CRLF the match fails **silently**, leaving
   `def main():` with a comment-only body, so **every plot request** fails with an
   `IndentationError` in generated code the user never wrote.
3. Project files generally — `initdb.d` scripts and mounted entrypoints.

Guards, layered: `.gitattributes` and `.editorconfig` for this repo;
`bootstrap.sh` clones the vendored repos with `-c core.autocrlf=false` **and**
normalises every text type afterwards (the project `.gitattributes` cannot help —
they are separate repositories); and structurally, `initdb.d` holds only `.sql`
plus one deliberate `.sh`, while Superset provisions itself with an **inline compose command**
rather than a mounted script. `verify.sh V9` checks both trees.

**Volumes:** no heavy path is bind-mounted. `pgdata`, `codeapi_pkgs` (2.7 GB),
`garage_meta`/`garage_data` and friends are named volumes inside the WSL2 VM. Only small
read-only text is bind-mounted, so the 9p crossing cost is a one-time startup
expense.

**Files On-Demand** can dehydrate a file into a stub that reads as zero bytes
inside a container — which would produce a baffling empty seed. Mark the folder
"Always keep on this device"; `verify.sh V8` checks the `Offline`
attribute.

---

## 14. Extending it

**Add a metric:** define it once in `config/cube/model/cubes/*.yml`. Superset picks it up
via a dataset metric using `MEASURE(...)`; the agent sees it immediately through
`describe_view`. No agent-side change.

**Add a masked field:** `mask:` on the cube, then add the member to the analyst
policy's `member_level.excludes` on **every** view that exposes it. Mention it in
`config/librechat/agent-instructions.md` so the agent knows not to ask (advisory only —
enforcement is Cube's). Re-run `verify.sh V1`.

**Add a role:** one entry in `CUBE_USER_ROLE_MAP`, one `access_policy` group per
view. Both resolvers pick it up; `contextToAppId` gains one compiler-cache entry.

**Add row-level security:** `access_policy.row_level.filters` on the views, with
values from `{ securityContext.x }` — never `{ userAttributes.x }`, which is Cube
Cloud-only and silently yields `undefined`, i.e. fails *open-looking*. Row-level
policies *are* combined across view and cubes, unlike member-level ones.

**Swap to local inference:** replace the `endpoints.custom` block with a vLLM or
Ollama base URL. Nothing else changes; there is no other egress.

---

## 15. Summary of judgement calls

| Decision | Alternative | Why this way |
|---|---|---|
| **Delete `cube-mcp`**, use two stock `postgres-mcp` containers | keep the custom server | two of its three reasons to exist were tested and found redundant — Cube masks dimensions on `SELECT *`, and Cube refuses `__user` itself. ~700 lines of security-adjacent code removed; the cost is that identity moved from the request to the container (§3.4) |
| **OpenLDAP as one userstore** | per-app local users | one place a person's credential lives, and group→role mapping for Superset. Does NOT make data authorization per-person — said so explicitly rather than implying it |
| **One Postgres, three databases** | separate `vectordb` container | fewer services, volumes and healthchecks; the cost is one image swap to `pgvector/pgvector` |
| **Build `rag_api` from source** | pull the prebuilt image | the image is `:latest`-only (unpinnable) and hides three real defects — pip backtracking, CUDA torch on a CPU box, and nltk 3.10's path allowlist. 3.73 GB vs 7.79 GB |
| **Local embeddings** | a hosted embeddings API | Foundry has no embeddings model, and document text should not leave an on-prem box. Cost: torch in the image |
| **One primary category per film** | keep the many-to-many bridge | additive measures must reconcile to their total; the bridge over-counted revenue by 2.37×. Cost: "which categories does this film have" is no longer answerable |
| Two Cube views | one wide view | the two date families are independent; one view would misdate revenue and fan out `SUM` |
| Charts in Python | click-then-export | reproducible from a clean `up -d` rather than from a human click-path |
| `allowed_callers: code_execution` | direct tool calls | structurally guarantees the agent writes Python and plots |
| Superset as one Cube user | per-user Superset masking | honest about what one shared credential can deliver; per-user story lives on the agent path |
| Garage | MinIO / SeaweedFS | MinIO relicensed and gutted its community edition; Garage bootstrap is one idempotent script |
| NsJail | libkrun microVM | `/dev/kvm` unavailable in Docker Desktop; documented as a real limitation |
| `LOCAL_MODE=true` + `CODEAPI_AUTH_PROVIDER=none` | Ed25519 JWT signing | governance is enforced in Cube, not codeapi. Signing is also unreachable with the `local-api` image, which mounts `localAuth` unconditionally — enabling it without keys silently kills `execute_code` and all data access |
| Date shift, not stretch | fill 24 months | stretching multiplies rental durations 3.2× and makes a KPI lie |
| Exclude `staff.password` | mask it | no legitimate query exists; absence beats redaction |
```
