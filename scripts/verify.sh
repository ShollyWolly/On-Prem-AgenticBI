#!/usr/bin/env bash

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

set +e

set +o pipefail

ONLY=("$@")
PASS=0; FAIL=0; SKIP=0

should_run() {
  [ ${#ONLY[@]} -eq 0 ] && return 0
  local want
  for want in "${ONLY[@]}"; do [ "$want" = "$1" ] && return 0; done
  return 1
}

check_id=""
check() {
  check_id="$1"
  should_run "$1" || return 1
  printf '\n%s[%s] %s%s\n' "$C_CYAN" "$1" "$2" "$C_RESET"
  return 0
}

assert() {
  local label="$1" cond="$2" detail="${3:-}"
  if [ "$cond" = "1" ]; then
    printf '  %sPASS%s  %s%s\n' "$C_GREEN" "$C_RESET" "$label" "${detail:+ -- $detail}"
    PASS=$((PASS + 1))
  else
    printf '  %sFAIL%s  %s%s\n' "$C_RED" "$C_RESET" "$label" "${detail:+ -- $detail}"
    FAIL=$((FAIL + 1))
  fi
}
skipped() { printf '  %sSKIP%s  %s\n' "$C_YELLOW" "$C_RESET" "$1"; SKIP=$((SKIP + 1)); }
b() { if [ "$1" = "0" ]; then echo 1; else echo 0; fi; }

SQLPW="$(env_get CUBEJS_SQL_PASSWORD || true)"
PGUSER_="$(env_get POSTGRES_USER || echo postgres)"
PGDB_="$(env_get POSTGRES_DB || echo pagila)"
PYTHON_BIN=""
for py in python python3; do
  if command -v "$py" >/dev/null 2>&1 && "$py" -c 'import httpx' >/dev/null 2>&1; then
    PYTHON_BIN="$py"
    break
  fi
done

agent_records_dump() {
  dexec abi-mongodb mongosh --quiet --eval '
const d = db.getSiblingDB("LibreChat");
const emailById = new Map(d.users.find({}, {_id: 1, email: 1}).toArray()
  .map(u => [String(u._id), u.email || ""]));
d.agents.find({}, {name:1, author:1, artifacts:1, tools:1, tool_resources:1, instructions:1})
  .forEach(a => print([
    emailById.get(String(a.author)) || "",
    a.name || "",
    a.artifacts || "",
    (a.tools || []).join(","),
    (((a.tool_resources || {}).file_search || {}).file_ids || []).length,
    Number((a.instructions || "").includes("## Shared BI rules")),
  ].join("\t")));
'
}

psql_cube() {
  compose_x exec -T -e PGPASSWORD="$SQLPW" postgres \
    psql -h cube -p 15432 -U "$1" -d cube -tAc "$2" 2>&1
}

if check V1 'Masking is enforced per identity (the money test)'; then
  Q="SELECT customers_email FROM revenue_analytics GROUP BY 1 LIMIT 1"
  analyst="$(psql_cube 'analyst@demo.local' "$Q" | tr -d '\r' | head -n1)"
  admin="$(psql_cube 'admin@demo.local'     "$Q" | tr -d '\r' | head -n1)"
  nobody="$(psql_cube 'nobody@nowhere.test' "$Q" | tr -d '\r' | head -n1)"

  case "$analyst" in '***@'*) a=1 ;; *) a=0 ;; esac
  assert 'analyst sees a MASKED e-mail' "$a" "$analyst"

  case "$admin" in
    '***@'*) b1=0 ;;
  esac
  assert 'admin sees a REAL e-mail' "$b1" "$admin"

  case "$nobody" in *"not found"*|*ERROR*|*denied*) n=1 ;; *) n=0 ;; esac
  assert 'unmapped identity is DENIED' "$n" "$(printf '%.60s' "$nobody")"

  grep -q 'CUBEJS_DEV_MODE=false' "${REPO_ROOT}/config/env/cube.demo.env"
  assert 'demo profile pins CUBEJS_DEV_MODE=false' "$(b $?)" \
    'dev mode disables member-level access control'
fi

if check V1b 'Revenue by category is ADDITIVE (no join fan-out)'; then
  total="$(psql_cube 'analyst@demo.local' \
    'SELECT MEASURE(total_revenue) FROM revenue_analytics' | tr -d '\r' | head -n1)"
  bycat="$(psql_cube 'analyst@demo.local' \
    'SELECT category_name, MEASURE(total_revenue) FROM revenue_analytics GROUP BY 1' \
    | tr -d '\r' | awk -F'|' 'NF>1 {s+=$2} END {printf "%.2f", s}')"
  ncat="$(psql_cube 'analyst@demo.local' \
    'SELECT category_name, MEASURE(total_revenue) FROM revenue_analytics GROUP BY 1' \
    | tr -d '\r' | grep -c '|')"

  assert 'total revenue = 67416.51' \
    "$([ "$total" = "67416.51" ] && echo 1 || echo 0)" "$total"
  assert 'category breakdown sums to the total' \
    "$([ "$bycat" = "$total" ] && echo 1 || echo 0)" \
    "categories=$bycat total=$total"
  assert 'all 16 categories present' \
    "$([ "$ncat" = "16" ] && echo 1 || echo 0)" "$ncat"

  grep -q 'md5(film_id::text' "${REPO_ROOT}/config/cube/model/cubes/catalog.yml"
  assert 'primary category tiebreak is hash-based, not MIN(category_id)' "$(b $?)" \
    'MIN() biases the distribution toward low category ids'
fi

if check V2 'Cube is not silently missing its cache/queue driver'; then
  logs="$(compose logs --tail 400 cube 2>&1)"
  printf '%s' "$logs" | grep -q 'Please set CUBEJS_CUBESTORE_HOST'
  assert 'no "Please set CUBEJS_CUBESTORE_HOST" error' "$(b $((1 - $?)) )" ''
  rev="$(psql_cube 'analyst@demo.local' 'SELECT MEASURE(total_revenue) FROM revenue_analytics' | tr -d '\r' | head -n1)"
  printf '%s' "$rev" | grep -Eq '^[0-9]+(\.[0-9]+)?$'
  assert 'a real MEASURE() query returns a number' "$(b $?)" "$rev"
fi

if check V3 'Pagila seed and date shift are intact'; then
  row="$(compose_x exec -T postgres psql -U "$PGUSER_" -d "$PGDB_" -tAF'|' -c \
    "SELECT (SELECT count(*) FROM rental),
            (SELECT count(*) FROM payment),
            (SELECT round(sum(amount),2) FROM payment),
            (SELECT count(*) FROM payment WHERE payment_date >= now()-interval '30 days'),
            (SELECT count(*) FROM rental  WHERE rental_date  >= now()-interval '30 days'),
            (SELECT count(*) FROM rental  WHERE return_date < rental_date)" 2>&1 | tr -d '\r' | head -n1)"
  IFS='|' read -r r p revsum p30 r30 bad <<< "$row"
  assert 'rental rows = 16044'      "$([ "$r" = "16044" ] && echo 1 || echo 0)" "$r"
  assert 'payment rows = 16049'     "$([ "$p" = "16049" ] && echo 1 || echo 0)" "$p"
  assert 'revenue = 67416.51'       "$([ "$revsum" = "67416.51" ] && echo 1 || echo 0)" "$revsum"
  assert 'payments in last 30 days' "$([ "${p30:-0}" -gt 0 ] && echo 1 || echo 0)" "$p30"
  assert 'rentals in last 30 days'  "$([ "${r30:-0}" -gt 0 ] && echo 1 || echo 0)" "$r30"
  assert 'no corrupted durations'   "$([ "$bad" = "0" ] && echo 1 || echo 0)" "$bad"
fi

if check V4 'Cube MCP requires an authenticated OAuth token'; then
  if ! container_running abi-cube-mcp; then
    skipped 'cube-mcp not running (docker compose --profile chat up -d)'
  elif ! wait_http_status "http://localhost:$(env_get CUBE_MCP_HOST_PORT || echo 8003)/mcp" 401 120; then
    assert 'Cube MCP endpoint becomes ready and requires auth' 0 'endpoint did not return HTTP 401'
  elif [ -z "$PYTHON_BIN" ]; then
    skipped 'Python with httpx is not on PATH'
  else
    out="$(CUBE_MCP_URL="http://localhost:$(env_get CUBE_MCP_HOST_PORT || echo 8003)/mcp" "$PYTHON_BIN" "${REPO_ROOT}/scripts/smoke/test_cube_mcp.py" 2>&1)"
    rc=$?
    assert 'test_cube_mcp.py passes' "$(b $rc)" \
      "$(printf '%s' "$out" | grep -E 'passed, [0-9]+ failed' | tail -n1)"
    if [ "$rc" != "0" ]; then
      printf '%s\n' "$out" | sed 's/^/    /'
    fi
    jwks_key_type="$(compose_x exec -T cube-mcp python -c '
import httpx, os
keys = httpx.get(os.environ["AUTHENTIK_CUBE_JWKS_URL"], timeout=10).json().get("keys", [])
print("RSA" if any(k.get("kty") == "RSA" and k.get("use") == "sig" for k in keys) else "MISSING")
' 2>/dev/null | tr -d '\r' | tail -n1)"
    assert 'Cube OAuth JWKS exposes an RSA signing key' \
      "$([ "$jwks_key_type" = "RSA" ] && echo 1 || echo 0)" "$jwks_key_type"
  fi
fi

if check V5 'Images have the binaries their healthchecks need'; then
  cube_has="$(docker run --rm --entrypoint sh cubejs/cube:v1.6.70 -c 'command -v curl wget || echo ABSENT' 2>&1)"
  printf '%s' "$cube_has" | grep -q ABSENT
  assert 'cube image genuinely has no curl/wget (so we use node -e)' "$(b $?)" \
    'this is why the healthcheck uses node'
  ss="$(docker run --rm --entrypoint sh abi/superset:6.1.0-psycopg2 -c \
        "command -v curl && /app/.venv/bin/python -c 'import psycopg2;print(psycopg2.__version__)'" 2>&1)"
  printf '%s' "$ss" | grep -q '/usr/bin/curl'; assert 'derived superset image has curl' "$(b $?)" ''
  printf '%s' "$ss" | grep -q '2\.9\.9';       assert 'derived superset image has psycopg2' "$(b $?)" ''
fi

if check V6 'LibreChat is not silently blocking the MCP servers (SSRF guard)'; then
  for addr in 'cube-mcp:8000' 'superset-mcp:5008'; do
    grep -q "$addr" "${REPO_ROOT}/config/librechat/librechat.yaml"
    assert "allowedAddresses lists ${addr}" "$(b $?)" ''
  done
  if ! container_running abi-librechat; then
    skipped 'librechat not running'
  else
    logs="$(compose logs --tail 400 librechat 2>&1)"
    printf '%s' "$logs" | grep -Eq 'SSRF|Blocked host|blocked address'
    assert 'no SSRF/blocked messages in logs' "$(b $((1 - $?)) )" ''
  fi
fi

if check V7 "Cube tolerates DATE_TRUNC(x) AS x (Superset's grain pattern)"; then
  out="$(psql_cube 'analyst@demo.local' \
    "SELECT DATE_TRUNC('month', paid_at) AS paid_at, MEASURE(total_revenue) AS revenue
     FROM revenue_analytics GROUP BY 1 ORDER BY 1 DESC LIMIT 3" | tr -d '\r')"
  printf '%s' "$out" | grep -Eq '[0-9]{4}-[0-9]{2}'
  assert 'alias-shadowed time grain returns rows' "$(b $?)" "$(printf '%s' "$out" | head -n1)"
fi

if check V8 'Required source files are present and non-empty'; then
  scan_roots=(); missing_roots=""
  for d in config scripts docker; do
    if [ -d "${REPO_ROOT}/${d}" ]; then scan_roots+=("${REPO_ROOT}/${d}")
    else missing_roots="${missing_roots}${d} "; fi
  done
  assert 'scan roots exist (else this check is vacuous)' \
    "$([ -z "$missing_roots" ] && echo 1 || echo 0)" "${missing_roots:-config scripts docker}"

  empties="$(find "${scan_roots[@]}" -type f -size 0 2>/dev/null | head -5)"
  assert 'no unexpected zero-byte files' "$([ -z "$empties" ] && echo 1 || echo 0)" \
    "${empties:-all files present}"
fi

if check V9 'Container-executed source files use LF line endings'; then
  bad=""
  for d in config docker scripts; do
    [ -d "${REPO_ROOT}/${d}" ] || die "V9 scan root ${d} missing -- check would be vacuous"
    while IFS= read -r f; do
      [ -n "$f" ] && grep -qU $'\r' "$f" 2>/dev/null && bad="${bad}$(basename "$f") "
    done < <(find "${REPO_ROOT}/${d}" -type f \( -name '*.sql' -o -name '*.sh' -o -name '*.yml' \
             -o -name '*.yaml' -o -name '*.py' -o -name '*.js' -o -name 'Dockerfile' \) 2>/dev/null)
  done
  grep -qU $'\r' "${REPO_ROOT}/docker-compose.yml" 2>/dev/null && bad="${bad}docker-compose.yml "
  assert 'no CR bytes in mounted/executed files' "$([ -z "$bad" ] && echo 1 || echo 0)" "${bad:-clean}"

  apt="${REPO_ROOT}/vendor/code-interpreter/docker/apt-install.sh"
  mpl="${REPO_ROOT}/vendor/code-interpreter/service/src/matplotlib.py"
  if [ -f "$apt" ]; then
    grep -qU $'\r' "$apt"
    assert 'vendored shell scripts are LF' "$(b $((1 - $?)) )" 'CR here breaks the sandbox build with exit 127'
    grep -qU $'\r' "$mpl"
    assert 'vendored matplotlib.py is LF' "$(b $((1 - $?)) )" 'CR here silently breaks EVERY plot request'
  else
    skipped 'vendor/code-interpreter not cloned'
  fi
fi

if check V10 'Sandbox packages are baked in (no network at runtime)'; then
  if ! docker volume ls --format '{{.Name}}' | grep -q '^agentic-bi_codeapi_pkgs$'; then
    skipped 'packages volume not created yet (scripts/build-sandbox-packages.sh)'
  else
    out="$(docker_x run --rm -v agentic-bi_codeapi_pkgs:/pkgs alpine sh -c \
      'test -f /pkgs/.initialized && echo MARKER_OK; for p in pandas matplotlib numpy; do ls -d /pkgs/python/*/lib/python*/site-packages/$p >/dev/null 2>&1 && echo HAVE_$p; done' 2>&1)"
    printf '%s' "$out" | grep -q MARKER_OK
    assert '/pkgs/.initialized present' "$(b $?)" 'absent => package-init did not finish'
    for p in pandas matplotlib numpy; do
      printf '%s' "$out" | grep -q "HAVE_$p"
      assert "$p installed in the sandbox" "$(b $?)" ''
    done
  fi
fi

if check V17 'LibreChat codeapi auth is coherent (signing off, or keys present)'; then
  if ! container_running abi-librechat; then
    skipped 'librechat not running'
  else
    provider="$(dexec abi-librechat printenv CODEAPI_AUTH_PROVIDER 2>/dev/null | tr -d '\r')"
    jwt_on="$(dexec abi-librechat printenv CODEAPI_JWT_ENABLED 2>/dev/null | tr -d '\r')"
    keylen="$(dexec abi-librechat sh -c 'printf %s "${#CODEAPI_JWT_PRIVATE_KEY}:${#CODEAPI_JWT_PRIVATE_KEY_BASE64}:${#CODEAPI_JWT_PRIVATE_JWK_JSON}"' 2>/dev/null | tr -d '\r')"

    signing_on=0
    case "$provider" in librechat-jwt|both) signing_on=1 ;; esac
    case "$jwt_on" in true|TRUE|True) signing_on=1 ;; esac

    have_key=0
    case "$keylen" in *:*:*) for n in ${keylen//:/ }; do [ "${n:-0}" -gt 0 ] && have_key=1; done ;; esac

    if [ "$signing_on" -eq 1 ]; then
      assert 'signing is enabled AND key material is present' "$have_key" \
        "provider=$provider jwt_enabled=$jwt_on key_lengths=$keylen -- with no key this throws 'Code API JWT signing key is not configured' on every call"
    else
      assert 'signing is off, so no key is needed' 1 "provider=${provider:-<unset>}"
    fi

    logs="$(compose logs --tail 600 librechat 2>&1)"
    printf '%s' "$logs" | grep -q 'signing key is not configured'
    assert 'no "signing key is not configured" in logs' "$(b $((1 - $?)) )" ''
    printf '%s' "$logs" | grep -q 'Error loading tool execute_code'
    assert 'execute_code tool loads' "$(b $((1 - $?)) )" ''
  fi
fi

if check V18 "LibreChat's container can reach and execute on codeapi"; then
  if ! container_running abi-librechat; then
    skipped 'librechat not running'
  elif ! container_running abi-codeapi; then
    skipped 'codeapi not running (docker compose --profile sandbox up -d)'
  else
    resp="$(dexec abi-librechat sh -c 'printf "%s" "{\"lang\":\"py\",\"code\":\"import pandas as pd\\nprint(pd.__version__)\\nprint(\\\"OK\\\")\\n\"}" > /tmp/v18.json; curl -sS --max-time 180 -X POST http://codeapi:3112/v1/exec -H "Content-Type: application/json" --data-binary @/tmp/v18.json' 2>&1)"
    ec="$(printf '%s' "$resp" | python -c 'import sys,json;print(json.load(sys.stdin).get("code"))' 2>/dev/null)"
    so="$(printf '%s' "$resp" | python -c 'import sys,json;print(json.load(sys.stdin).get("stdout",""))' 2>/dev/null)"
    assert 'codeapi accepts LibreChat-originated exec' "$([ "$ec" = "0" ] && echo 1 || echo 0)" \
      "code=${ec:-<no json>}"
    printf '%s' "$so" | grep -q OK
    assert 'code ran inside the sandbox' "$(b $?)" "$(printf '%s' "$so" | tr '\n' ' ')"
  fi
fi

if check V14 'Sandbox actually runs Python and returns a plot file (codeapi in isolation)'; then
  if ! container_running abi-codeapi; then
    skipped 'codeapi not running (docker compose --profile sandbox up -d)'
  else
    port="$(env_get CODEAPI_HOST_PORT || echo 3112)"
    python - > /tmp/v14.json <<'PY'
import json
code = '''import pandas as pd, numpy as np
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
df = pd.DataFrame({"m": ["Feb","Mar","Apr"], "rev": [10095.14, 11437.89, 10802.30]})
print("pandas", pd.__version__, "matplotlib", matplotlib.__version__)
fig, ax = plt.subplots(figsize=(5,3))
ax.bar(df["m"], df["rev"], color="#3987e5")
fig.savefig("/mnt/data/verify.png", dpi=90, bbox_inches="tight")
print("PLOT_OK")
'''
print(json.dumps({"lang": "py", "code": code}))
PY
    resp="$(curl -sS --max-time 180 -X POST "http://localhost:${port}/v1/exec" \
            -H 'Content-Type: application/json' --data-binary @/tmp/v14.json 2>&1)"
    ec="$(printf '%s' "$resp" | python -c 'import sys,json;print(json.load(sys.stdin).get("code"))' 2>/dev/null)"
    so="$(printf '%s' "$resp" | python -c 'import sys,json;print(json.load(sys.stdin).get("stdout",""))' 2>/dev/null)"
    nf="$(printf '%s' "$resp" | python -c 'import sys,json;print(len(json.load(sys.stdin).get("files") or []))' 2>/dev/null)"
    assert 'exec exited 0' "$([ "$ec" = "0" ] && echo 1 || echo 0)" "code=$ec"
    printf '%s' "$so" | grep -Eq 'pandas [0-9]'
    assert 'python + matplotlib importable in sandbox' "$(b $?)" "$(printf '%s' "$so" | head -n1)"
    printf '%s' "$so" | grep -q PLOT_OK
    assert 'plot saved and returned as a file' "$([ "$?" = "0" ] && [ "${nf:-0}" -ge 1 ] && echo 1 || echo 0)" "files=$nf"
  fi
fi

if check V15 'Garage cluster is bootstrapped and usable'; then
  if ! container_running abi-garage; then
    skipped 'garage not running (docker compose --profile sandbox up -d garage)'
  else
    key="$(env_get MINIO_ACCESS_KEY || true)"
    bucket="$(env_get MINIO_BUCKET || echo codeapi-files)"
    g() { dexec abi-garage /garage -c /etc/garage.toml "$@" 2>&1; }
    g status | grep -qi 'NO ROLE ASSIGNED'
    assert 'layout is applied (node has a role)' "$(b $((1 - $?)) )" ''
    g key info "$key" >/dev/null 2>&1
    assert 'S3 key imported' "$(b $?)" "${key:0:8}..."
    g bucket info "$bucket" >/dev/null 2>&1
    assert "bucket '$bucket' exists" "$(b $?)" ''

    if ! container_running abi-codeapi-files; then
      skipped 'codeapi-files not running: cannot check the S3 round trip'
    else
      objs="$(g bucket info "$bucket" 2>/dev/null | tr -d '\r' \
              | grep -iE '^Objects:' | grep -oE '[0-9]+' | head -n1)"
      objdetail="objects=${objs:-0}"
      [ "${objs:-0}" -eq 0 ] 2>/dev/null && \
        objdetail="${objdetail} -- run 'verify.sh V14' first, it generates a plot"
      assert "bucket has objects (an upload actually round-tripped)" \
        "$([ "${objs:-0}" -gt 0 ] 2>/dev/null && echo 1 || echo 0)" "$objdetail"

      parsefail="$(docker logs abi-codeapi-files 2>&1 \
                   | grep -ciE 'failed to parse server response|Pruned files from response' || true)"
      assert 'file server reports no S3 parse failures / pruned uploads' \
        "$([ "${parsefail:-0}" -eq 0 ] 2>/dev/null && echo 1 || echo 0)" \
        "matches=${parsefail:-0} (non-zero => the Garage/minio-js multipart bug is back)"
    fi
  fi
fi

if false && check V16 'Legacy static-role agent ownership checks (retired)'; then
  if ! container_running abi-mongodb; then
    skipped 'mongodb not running'
  else
    dump="$(agent_records_dump)"
    for who in ANALYST ADMIN; do
      em="$(env_get "DEMO_${who}_EMAIL")"
      for agent in 'Pagila BI Analyst' 'Dashboard Reviewer'; do
        n="$(printf '%s\n' "$dump" | awk -F'\t' -v email="$em" -v name="$agent" \
          '$1 == email && $2 == name {c++} END {print c+0}')"
        assert "$em owns '$agent'" \
          "$([ "$n" = 1 ] && echo 1 || echo 0)" "count=${n}"
      done
    done
  fi
fi

if check V20 'OpenLDAP is the primary userstore for Superset and Authentik SSO'; then
  if ! container_running abi-openldap; then
    skipped 'openldap not running'
  else
    base="$(env_get LDAP_BASE_DN || echo 'dc=demo,dc=local')"
    admin_dn="$(env_get LDAP_ADMIN_DN || echo "cn=admin,${base}")"
    ldap_pw="$(env_get LDAP_ADMIN_PASSWORD || true)"

    an_em="$(env_get DEMO_ANALYST_EMAIL)"; an_pw="$(env_get DEMO_ANALYST_PASSWORD)"
    ad_em="$(env_get DEMO_ADMIN_EMAIL)";   ad_pw="$(env_get DEMO_ADMIN_PASSWORD)"

    for pair in "${an_em}:${an_pw}:analysts" "${ad_em}:${ad_pw}:admins"; do
      em="${pair%%:*}"; rest="${pair#*:}"; pw="${rest%%:*}"; grp="${rest#*:}"
      uid="${em%%@*}"

      dexec -e BPW="$pw" abi-openldap sh -c \
        "ldapwhoami -x -H ldap://localhost -D 'uid=${uid},ou=people,${base}' -w \"\$BPW\"" \
        >/dev/null 2>&1
      assert "LDAP bind works as uid=${uid}" "$(b $?)" "password matches .env"

      mo="$(dexec -e LPW="$ldap_pw" abi-openldap sh -c \
        "ldapsearch -x -H ldap://localhost -D '${admin_dn}' -w \"\$LPW\" \
         -b 'uid=${uid},ou=people,${base}' -s base memberOf" 2>/dev/null \
        | grep '^memberOf:' | tr -d '\r')"
      case "$mo" in
      esac
      assert "memberOf populated for uid=${uid} -> cn=${grp}" "$m" \
        "${mo:-empty: overlay needs groupOfUniqueNames/uniqueMember}"
    done

    if ! container_running abi-superset; then
      skipped 'superset not running'
    else
      grep -q 'AUTH_LDAP_UID_FIELD = "mail"' "${REPO_ROOT}/config/superset/superset_config.py"
      assert 'Superset logs in with the e-mail, not the uid' "$(b $?)" \
        'one identity, one spelling -- the e-mail is what CUBE_USER_ROLE_MAP keys on'

      code="$(curl -sS -o /dev/null -w '%{http_code}' 'http://localhost:8088/login/' 2>/dev/null)"
      assert 'GET /login/ renders (the page a human loads)' \
        "$([ "$code" = "200" ] && echo 1 || echo 0)" "http=${code}"

      pwmatch="$(compose_x exec -T \
        -e PW="$(env_get DEMO_ADMIN_PASSWORD)" -e EM="$(env_get SUPERSET_ADMIN_EMAIL)" \
        superset python -c '
from superset.app import create_app
from werkzeug.security import check_password_hash
import os
app = create_app()
with app.app_context():
    from superset.extensions import security_manager as sm
    u = sm.find_user(email=os.environ["EM"])
    print("YES" if u and check_password_hash(u.password, os.environ["PW"]) else "NO")
' 2>/dev/null | tr -d '\r' | grep -E '^(YES|NO)$' | tail -n1)"
      assert 'break-glass local password == DEMO_ADMIN_PASSWORD (one identity, one password)' \
        "$([ "$pwmatch" = "YES" ] && echo 1 || echo 0)" "${pwmatch:-unknown}"

      for pair in "${an_em}:${an_pw}" "${ad_em}:${ad_pw}"; do
        em="${pair%%:*}"; pw="${pair#*:}"
        code="$(curl -sS -o /dev/null -w '%{http_code}' \
          -X POST 'http://localhost:8088/api/v1/security/login' \
          -H 'Content-Type: application/json' \
          -d "{\"username\":\"${em}\",\"password\":\"${pw}\",\"provider\":\"ldap\",\"refresh\":false}" \
          2>/dev/null)"
        assert "Superset LDAP login as ${em}" \
          "$([ "$code" = "200" ] && echo 1 || echo 0)" "http=${code}"
      done

      code="$(curl -sS -o /dev/null -w '%{http_code}' \
        -X POST 'http://localhost:8088/api/v1/security/login' \
        -H 'Content-Type: application/json' \
        -d "{\"username\":\"${an_em}\",\"password\":\"definitely-not-the-password\",\"provider\":\"ldap\"}" \
        2>/dev/null)"
      assert 'Superset REJECTS a wrong password' \
        "$([ "$code" = "401" ] && echo 1 || echo 0)" "http=${code}"

      roles="$(compose_x exec -T superset python -c '
from superset.app import create_app
app = create_app()
with app.app_context():
    from superset.extensions import security_manager as sm
    for u in sm.get_all_users():
        print(u.username, ",".join(sorted(r.name for r in u.roles)))
' 2>/dev/null | tr -d '\r')"
      printf '%s' "$roles" | grep -q "^${ad_em} .*Admin"
      assert "${ad_em} mapped to Superset Admin via cn=admins" "$(b $?)" ''
      printf '%s' "$roles" | grep -q "^${an_em} .*Alpha"
      assert "${an_em} mapped to Superset Alpha via cn=analysts" "$(b $?)" ''
    fi

    if ! container_running abi-librechat; then
      skipped 'librechat not running'
    else
      issuer="$(dexec abi-librechat printenv OPENID_ISSUER 2>/dev/null | tr -d '\r')"
      client="$(dexec abi-librechat printenv OPENID_CLIENT_ID 2>/dev/null | tr -d '\r')"
      assert 'LibreChat is configured for the Authentik OIDC issuer' \
        "$(printf '%s' "$issuer" | grep -q '/application/o/librechat/' && echo 1 || echo 0)" "${issuer:-unset}"
      assert 'LibreChat has the configured OIDC client id' \
        "$([ "$client" = "librechat" ] && echo 1 || echo 0)" "${client:-unset}"

      code="$(curl -sS -o /dev/null -w '%{http_code}' \
        'http://authentik.localhost:9000/application/o/librechat/.well-known/openid-configuration' 2>/dev/null)"
      assert 'Authentik publishes LibreChat OIDC discovery' \
        "$([ "$code" = 200 ] && echo 1 || echo 0)" "http=${code}"
    fi
  fi
fi

if check V21 'Superset MCP serves chart data and refuses SQL'; then
  if ! container_running abi-superset-mcp; then
    skipped 'superset-mcp not running'
  elif ! wait_healthy abi-superset-mcp 300; then
    assert 'Superset MCP becomes healthy' 0 'healthcheck did not become healthy'
  elif [ -z "$PYTHON_BIN" ]; then
    skipped 'Python with httpx is not on PATH'
  else
    out="$("$PYTHON_BIN" "${REPO_ROOT}/scripts/smoke/test_superset_mcp.py" 2>&1)"
    rc=$?
    assert 'test_superset_mcp.py passes' "$(b $rc)" \
      "$(printf '%s' "$out" | grep -E '^[0-9]+ passed' | tail -n1)"
    if [ "$rc" != "0" ]; then
      printf '%s\n' "$out" | sed 's/^/    /'
    fi
  fi
fi

if check V22 'RAG API embeds locally into pgvector (one Postgres, third database)'; then
  vdb="$(env_get VECTOR_DB_NAME || echo vectordb)"

  n_pg="$(docker ps --format '{{.Names}}\t{{.Image}}' | grep -c 'pgvector/pgvector')"
  assert 'exactly ONE postgres instance (no separate vectordb container)' \
    "$([ "$n_pg" = "1" ] && echo 1 || echo 0)" "count=$n_pg"

  ver="$(compose_x exec -T postgres psql -U "$PGUSER_" -d "$vdb" -tAc \
        "SELECT extversion FROM pg_extension WHERE extname='vector'" 2>&1 | tr -d '\r' | head -n1)"
  printf '%s' "$ver" | grep -Eq '^[0-9]+\.[0-9]+'
  assert "pgvector enabled inside ${vdb}" "$(b $?)" "${ver:-absent}"

  grep -q 'context: ./vendor/rag_api' "${REPO_ROOT}/docker-compose.yml"
  assert 'rag-api is built from vendor/rag_api, not pulled' "$(b $?)" ''

  grep -q 'Dockerfile.lite' "${REPO_ROOT}/docker/rag-api/Dockerfile"
  assert 'the build does NOT use Dockerfile.lite' "$(b $((1 - $?)) )" \
    'lite ships no sentence-transformers, so it cannot embed locally'

  if ! container_running abi-rag-api; then
    skipped 'rag-api not running (docker compose --profile chat up -d rag-api)'
  else
    health="$(docker inspect --format '{{.State.Health.Status}}' abi-rag-api 2>/dev/null)"
    assert 'rag-api is healthy' "$([ "$health" = "healthy" ] && echo 1 || echo 0)" "$health"

    tv="$(dexec abi-rag-api python -c \
      'import torch, sentence_transformers as st; print(torch.__version__, st.__version__, torch.version.cuda)' \
      2>/dev/null | tr -d '\r')"
    case "$tv" in
    esac
    assert 'torch is the CPU wheel and sentence-transformers imports' "$tok" \
      "${tv:-import failed} (torch, st, cuda)"

    nl="$(dexec abi-rag-api python -c \
      'import nltk; nltk.data.find("tokenizers/punkt_tab"); print("ok")' \
      2>/dev/null | tr -d '\r')"
    assert 'NLTK corpora are baked in (no runtime egress)' \
      "$([ "$nl" = "ok" ] && echo 1 || echo 0)" "${nl:-missing}"

    cached="$(dexec abi-rag-api sh -c \
      'find /app/hf -name "*.safetensors" -o -name "pytorch_model.bin" 2>/dev/null | head -n1' \
      2>/dev/null | tr -d '\r')"
    assert 'embedding model weights are cached in the volume' \
      "$([ -n "$cached" ] && echo 1 || echo 0)" "${cached:-nothing cached}"

    store="$(compose_x exec -T postgres psql -U "$PGUSER_" -d "$vdb" -tAc \
      "SELECT to_regclass('public.langchain_pg_embedding') IS NOT NULL" \
      2>&1 | tr -d '\r' | head -n1)"
    assert 'RAG vector store is initialised for user uploads' \
      "$([ "$store" = "t" ] && echo 1 || echo 0)" "table=${store:-absent}"
  fi
fi

if check V23 'Agent capabilities are wired end to end (artifacts, file_search)'; then
  for cap in execute_code tools artifacts programmatic_tools file_search actions; do
    grep -q "\"${cap}\"" "${REPO_ROOT}/config/librechat/librechat.yaml"
    assert "librechat.yaml enumerates ${cap}" "$(b $?)" \
      'specifying capabilities REPLACES the defaults'
  done

  if ! container_running abi-mongodb; then
    skipped 'mongodb not running'
  else
    dump="$(agent_records_dump | cut -f2-)"
    if [ -z "$dump" ]; then
      assert 'provisioned agent records exist' 0 'no agent records found'
    else
      n_agents="$(printf '%s\n' "$dump" | grep -c .)"
      n_art="$(printf '%s\n' "$dump" | awk -F'\t' '$2 != "" {c++} END {print c+0}')"
      assert 'every agent record has a non-empty artifacts field' \
        "$([ "$n_art" = "$n_agents" ] && [ "$n_agents" -gt 0 ] && echo 1 || echo 0)" \
        "${n_art}/${n_agents}"

      n_fs="$(printf '%s\n' "$dump" | awk -F'\t' '$3 ~ /file_search/ {c++} END {print c+0}')"
      assert 'every agent has the file_search tool attached' \
        "$([ "$n_fs" = "$n_agents" ] && [ "$n_agents" -gt 0 ] && echo 1 || echo 0)" \
        "${n_fs}/${n_agents}"

      n_bundled_files="$(printf '%s\n' "$dump" | awk -F'\t' '$4 != "0" {c++} END {print c+0}')"
      assert 'agents have no bundled file-search attachments' \
        "$([ "$n_bundled_files" = 0 ] && echo 1 || echo 0)" "${n_bundled_files}/${n_agents}"

      n_embedded_rules="$(printf '%s\n' "$dump" | awk -F'\t' '$5 == "1" {c++} END {print c+0}')"
      assert 'every agent embeds the compact shared BI rules' \
        "$([ "$n_embedded_rules" = "$n_agents" ] && [ "$n_agents" -gt 0 ] && echo 1 || echo 0)" \
        "${n_embedded_rules}/${n_agents}"

      url="$(dexec abi-librechat printenv RAG_API_URL 2>/dev/null | tr -d '\r')"
      assert 'librechat has RAG_API_URL set' \
        "$([ -n "$url" ] && echo 1 || echo 0)" "${url:-unset}"

      ! grep -q 'titleModel:' "${REPO_ROOT}/config/librechat/librechat.yaml"
      assert 'conversation titles use the selected agent model (no title-model override)' \
        "$(b $?)" 'LibreChat falls back to agent.model when titleModel is unset'
    fi
  fi
fi

if check V24 'Meilisearch backs private LibreChat conversation search'; then
  if ! container_running abi-meilisearch; then
    skipped 'meilisearch not running (docker compose --profile chat up -d)'
  else
    search="$(env_get SEARCH || true)"
    assert 'LibreChat conversation search is enabled' \
      "$([ "$search" = true ] && echo 1 || echo 0)" "SEARCH=${search:-unset}"

    state="$(docker inspect --format '{{.State.Health.Status}}' abi-meilisearch 2>/dev/null)"
    assert 'Meilisearch is healthy' \
      "$([ "$state" = healthy ] && echo 1 || echo 0)" "${state:-unknown}"

    key="$(env_get MEILI_MASTER_KEY || true)"
    indexes="$(dexec abi-meilisearch wget --header="Authorization: Bearer ${key}" \
      -qO- http://127.0.0.1:7700/indexes 2>/dev/null)"
    printf '%s' "$indexes" | grep -q '"uid":"messages"'
    assert 'messages index is initialized' "$(b $?)" ''
    printf '%s' "$indexes" | grep -q '"uid":"convos"'
    assert 'conversations index is initialized' "$(b $?)" ''
  fi
fi

if check V11 'Azure Foundry endpoint answers (the only egress)'; then
  base="$(env_get AZURE_FOUNDRY_BASE_URL || true)"
  key="$(env_get AZURE_FOUNDRY_API_KEY || true)"
  model="$(env_get AZURE_FOUNDRY_MODEL || true)"

  case "$base" in
    */) t=0 ;;
    ?*) t=1 ;;
    *)  t=0 ;;
  esac
  assert 'base URL has no trailing slash' "$t" \
    'LibreChat appends /chat/completions; a trailing slash gives //chat/completions and a 404'

  if [ -z "$key" ] || [[ "$key" == *CHANGE_ME* ]]; then
    skipped 'AZURE_FOUNDRY_API_KEY not set in .env'
  elif [ -n "${SKIP_SLOW:-}" ]; then
    skipped 'skipped (SKIP_SLOW=1)'
  else
    body="$(printf '{"model":"%s","messages":[{"role":"user","content":"reply with the single word: ok"}]}' "$model")"
    code="$(curl -sS -o /tmp/foundry.json -w '%{http_code}' --max-time 60 \
            -X POST "${base}/chat/completions" \
            -H "Authorization: Bearer ${key}" -H 'Content-Type: application/json' \
            --data-binary "$body" 2>&1)"
    if [ "$code" = "200" ]; then
      assert 'chat/completions responded' 1 "$(python -c 'import json;print(json.load(open("/tmp/foundry.json"))["choices"][0]["message"]["content"][:40])' 2>/dev/null)"
    elif [ "$code" = "401" ]; then
      dim '  Bearer rejected; retrying with the api-key header'
      code2="$(curl -sS -o /tmp/foundry.json -w '%{http_code}' --max-time 60 \
               -X POST "${base}/chat/completions" \
               -H "api-key: ${key}" -H 'Content-Type: application/json' \
               --data-binary "$body" 2>&1)"
      assert 'chat/completions responded via api-key header' "$([ "$code2" = "200" ] && echo 1 || echo 0)" \
        'if only api-key works, add headers: { api-key: "${AZURE_FOUNDRY_API_KEY}" } to endpoints.custom'
    elif [ "$code" = "404" ]; then
      assert 'chat/completions responded' 0 '404 -- check the base URL ends /openai/v1 and model is the DEPLOYMENT name'
    else
      assert 'chat/completions responded' 0 "HTTP $code: $(head -c 160 /tmp/foundry.json)"
    fi
  fi
fi

if check V12 'Superset can still decrypt the stored Cube credential'; then
  if ! container_running abi-superset; then
    skipped 'superset not running'
  else
    out="$(compose_x exec -T superset python -c '
from superset.app import create_app
app = create_app()
with app.app_context():
    from superset import db
    from superset.models.core import Database
    from superset.connectors.sqla.models import SqlaTable
    d = db.session.query(Database).filter_by(database_name="Cube Semantic Layer").one()
    print("URI_OK", d.sqlalchemy_uri_decrypted.split("@")[-1])
    with d.get_sqla_engine() as eng:
        print("PII", eng.execute("SELECT customers_email FROM revenue_analytics GROUP BY 1 LIMIT 1").fetchall()[0][0])
    print("DATASETS", ",".join(sorted(t.table_name for t in db.session.query(SqlaTable).all())))
' 2>&1)"
    printf '%s' "$out" | grep -q 'URI_OK cube:15432/cube';                  assert 'credential decrypts' "$(b $?)" ''
    printf '%s' "$out" | grep -q 'DATASETS rental_analytics,revenue_analytics'; assert 'both datasets present' "$(b $?)" ''
    printf '%s' "$out" | grep -q 'PII \*\*\*@';                             assert 'dashboard path sees MASKED PII' "$(b $?)" ''
  fi
fi

if check V13 'Superset provisioning and dashboard build succeeded'; then
  if ! container_running abi-superset; then
    skipped 'superset not running'
  else
    logs="$(compose logs superset 2>&1)"
    printf '%s' "$logs" | grep -q 'provisioning complete'
    assert 'in-container provisioning completed' "$(b $?)" ''
    printf '%s' "$logs" | grep -Eq 'Schema validation failed|Unknown field'
    assert 'no asset schema validation failures' "$(b $((1 - $?)) )" ''
    n="$(compose_x exec -T superset python -c '
from superset.app import create_app
app = create_app()
with app.app_context():
    from superset import db
    from superset.models.slice import Slice
    from superset.models.dashboard import Dashboard
    print(db.session.query(Slice).count(), db.session.query(Dashboard).count())
' 2>&1 | tr -d '\r' | tail -n1)"
    charts="$(echo "$n" | awk '{print $1}')"; dashes="$(echo "$n" | awk '{print $2}')"
    assert '9 charts built'    "$([ "$charts" = "9" ] && echo 1 || echo 0)" "$charts"
    assert '1 dashboard built' "$([ "${dashes:-0}" -ge 1 ] && echo 1 || echo 0)" "$dashes"
  fi
fi

printf '\n%s=======================================================%s\n' "$C_CYAN" "$C_RESET"
if [ "$FAIL" -gt 0 ]; then
  printf '%s PASS %s   FAIL %s   SKIP %s%s\n' "$C_RED" "$PASS" "$FAIL" "$SKIP" "$C_RESET"
else
  printf '%s PASS %s   FAIL %s   SKIP %s%s\n' "$C_GREEN" "$PASS" "$FAIL" "$SKIP" "$C_RESET"
fi
printf '%s=======================================================%s\n' "$C_CYAN" "$C_RESET"
[ "$FAIL" -eq 0 ]
