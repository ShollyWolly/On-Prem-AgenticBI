# Operational traps

These are failure modes that can look healthy or plausible while the requested
behavior is broken. Check the named outcome rather than relying on container
health alone.

## Cube and semantic governance

- Never demonstrate with `CUBE_MODE=dev`. Cube development mode disables
  member-level access control, so masked data can return as real PII. Use
  `CUBE_MODE=demo` and validate masking with both an analyst and an admin identity.
- `mask` belongs on cubes and `access_policy` belongs on views. Policies on a
  base cube do not govern queries against a view.
- A mask expression used through a view must reference its owning source cube,
  such as `{customers}`, rather than `{CUBE}`. In a view, `{CUBE}` can resolve
  to the view alias and produce a PostgreSQL missing-FROM error.
- Use `{ securityContext.x }`, not Cube Cloud user attributes. The gateway puts
  the verified request identity in Cube's `securityContext` claim.
- `extendContext` receives the full REST JWT payload. It must unwrap the nested
  `securityContext` for REST requests while continuing to accept SQL contexts.
  An empty `get_schema` result can mean this unwrap failed, not that LibreChat is
  disconnected.
- The role mapping must stay fail-closed. A missing group, no mapped group, or
  both `analysts` and `admins` must resolve to `denied`.
- `CUBEJS_CACHE_AND_QUEUE_DRIVER=memory` in the demo environment is required.
  Without it, Cube can be healthy while its first query fails because CubeStore is
  not configured.
- The Pagila category bridge is many-to-many. The model's primary-category join
  prevents revenue fan-out; do not replace it with the raw bridge. Reconcile new
  additive breakdowns against totals.

## Authentik, OIDC, and Cube MCP

- LibreChat performs OIDC discovery at startup. Authentik's healthcheck must wait
  for the LibreChat discovery endpoint, not merely `ak healthcheck`, or LibreChat
  may start without an OIDC strategy. The managed bootstrap and `up.sh` wait for
  that endpoint and recreate LibreChat; a manual Compose start does not add this
  recovery step.
- The Cube OAuth provider must use Authentik's internal JWT certificate as its
  signing key. If the JWKS is empty, access tokens are not suitable for the
  gateway and MCP requests fail with `invalid_token` or time out. Run `V4` to
  check for an RSA key.
- The external issuer hostname is `authentik.localhost`, including from the
  Compose network through `host-gateway`. Changing it to an internal service
  hostname changes the issuer and invalidates token verification.
- `cube-mcp` owns `CUBEJS_API_SECRET`; do not expose Cube REST or copy that secret
  into LibreChat. LibreChat authenticates to the MCP server with OAuth instead.
- `cube-sql-mcp` uses the same secret only to create short-lived SQL passwords;
  never give its SQL password or Cube API secret to LibreChat or an end user.
- Raw `raw_*` Cube views must retain an admin-only `access_policy`; analysts must
  not receive those views through metadata or Semantic SQL.
- LibreChat's MCP SSRF allowlist requires bare `host:port` entries. Keep
  `cube-mcp:8000`, `cube-sql-mcp:8000`, `verified-sql-mcp:8000`, `superset-mcp:5008`, and `authentik.localhost:9000` in
  `config/librechat/librechat.yaml`.
- The verified SQL MCP must judge only after Cube SQL succeeds and must never send query rows to the judge.
- Verified SQL rows must not be released if the HMAC-signed audit context is invalid or the encrypted audit record cannot be inserted.
- The audit console is read-only and must deny analysts, missing group claims, and users in both mapped groups.
- The PostgreSQL verifier audit is a demo review trail, not enterprise-grade
  monitoring. It has no OpenTelemetry export, centralized telemetry backend, or
  production alerting and retention controls.
- The LibreChat OIDC patch provisions agents after a persisted user record exists.
  Do not create agent records by hand.
- After changing the Authentik provider, reconnect the Cube connection in
  LibreChat so it obtains a fresh access token.

## Superset and Superset MCP

- Superset uses one Cube SQL identity. Its users authenticate with LDAP but do
  not receive their own Cube security contexts.
- Superset MCP always uses the `mcp_reader` service account. Its read-only role
  is the security boundary and must not gain `can_execute_sql_query`.
- Superset MCP tools take one `request` object. For example, pass
  `{"request": {"identifier": 10}}`, not a flat argument object.
- `get_chart_data` replaces a chart's row limit when a `limit` is supplied. Omit
  it when checking the chart's own top-N behavior.
- `GET /mcp` may correctly return 405 because the endpoint is POST-only. The
  healthcheck accepts the relevant response codes.
- `/health` and the human login page can fail independently. Check both after
  changing Superset configuration or assets.
- Do not rotate `SUPERSET_SECRET_KEY` after metadata exists. It encrypts stored
  database credentials and rotation is not self-healing.

## LibreChat and optional code execution

- Do not bind-mount LibreChat's built client directory. It hides the built Vite
  assets and produces a blank UI.
- Keep `CODEAPI_AUTH_PROVIDER=none` unless the full matching key integration is
  configured. A bad setting fails only when the agent executes code.
- The sandbox shares the host kernel.
- Garage version 2 or newer is required for reliable multipart file completion.
  Older versions can store bytes while the client still reports failure.

## State and diagnosis

- `initdb.d` only runs for a new PostgreSQL volume. Use
  `scripts/services/postgres/init-vectordb.sh` when adding the vector database to an existing
  installation.
- A fresh Authentik state needs the LDAP source and providers from the mounted
  blueprint. Inspect Authentik provider configuration before weakening token
  verification.
- `initdb.d` cannot add audit objects to an existing PostgreSQL volume; use
  `scripts/services/postgres/init-audit.sh`, which is run by the managed startup script.
- Start with `docker compose ps`, focused logs, and the narrowest verification
  check. A healthy container does not prove login, browser rendering, MCP access,
  or authorization.
