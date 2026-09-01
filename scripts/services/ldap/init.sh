#!/usr/bin/env bash

source "$(dirname "${BASH_SOURCE[0]}")/../../general/lib.sh"

BASE_DN="$(env_get LDAP_BASE_DN || echo 'dc=demo,dc=local')"
ADMIN_DN="$(env_get LDAP_ADMIN_DN || echo "cn=admin,${BASE_DN}")"
ADMIN_PW="$(env_require LDAP_ADMIN_PASSWORD)"

ANALYST_EMAIL="$(env_require DEMO_ANALYST_EMAIL)"
ANALYST_PW="$(env_require DEMO_ANALYST_PASSWORD)"
ADMIN_EMAIL="$(env_require DEMO_ADMIN_EMAIL)"
ADMIN_USER_PW="$(env_require DEMO_ADMIN_PASSWORD)"

container_running abi-openldap || die "abi-openldap is not running (docker compose up -d openldap)"

step "LDAP tree"

ldap_apply() {
  local label="$1" mode="${2:-add}" out rc
  if out="$(dexec -i -e LDAP_PW="$ADMIN_PW" abi-openldap \
              sh -c "ldap${mode} -x -H ldap://localhost -D '${ADMIN_DN}' -w \"\$LDAP_PW\" -c" 2>&1)"; then
    rc=0
  else
    rc=$?
  fi
  if [ "$rc" -eq 0 ]; then
    ok "  ${label}"
  elif printf '%s' "$out" | grep -qE 'Already exists|(^|[^0-9])20\b.*Type or value exists|Type or value exists'; then
    dim "  ${label} (already present)"
  else
    err "$out"
    die "  ${label} FAILED (rc=$rc)"
  fi
}

ldap_apply "ou=people / ou=groups" add <<LDIF
dn: ou=people,${BASE_DN}
objectClass: organizationalUnit
ou: people

dn: ou=groups,${BASE_DN}
objectClass: organizationalUnit
ou: groups
LDIF

add_user() {
  local uid="$1" cn="$2" sn="$3" mail="$4" pw="$5"
  ldap_apply "uid=${uid} (${mail})" add <<LDIF
dn: uid=${uid},ou=people,${BASE_DN}
objectClass: inetOrgPerson
objectClass: organizationalPerson
objectClass: person
objectClass: top
uid: ${uid}
cn: ${cn}
sn: ${sn}
givenName: ${cn% *}
displayName: ${cn}
mail: ${mail}
userPassword: ${pw}
LDIF

  ldap_apply "uid=${uid} password + givenName re-applied" modify <<LDIF
dn: uid=${uid},ou=people,${BASE_DN}
changetype: modify
replace: userPassword
userPassword: ${pw}
-
replace: givenName
givenName: ${cn% *}
LDIF
}

add_user "${ANALYST_EMAIL%%@*}" "Demo Analyst" "Analyst" "$ANALYST_EMAIL" "$ANALYST_PW"
add_user "${ADMIN_EMAIL%%@*}"   "Demo Admin"   "Admin"   "$ADMIN_EMAIL"   "$ADMIN_USER_PW"

# Recreate managed groups so the memberOf values always match the demo identities.
for g in analysts admins; do
  dexec -e LDAP_PW="$ADMIN_PW" abi-openldap sh -c \
    "ldapdelete -x -H ldap://localhost -D '${ADMIN_DN}' -w \"\$LDAP_PW\" 'cn=${g},ou=groups,${BASE_DN}'" \
    >/dev/null 2>&1 || true
done

ldap_apply "cn=analysts / cn=admins (groupOfUniqueNames)" add <<LDIF
dn: cn=analysts,ou=groups,${BASE_DN}
objectClass: groupOfUniqueNames
cn: analysts
uniqueMember: uid=${ANALYST_EMAIL%%@*},ou=people,${BASE_DN}

dn: cn=admins,ou=groups,${BASE_DN}
objectClass: groupOfUniqueNames
cn: admins
uniqueMember: uid=${ADMIN_EMAIL%%@*},ou=people,${BASE_DN}
LDIF

step "Verifying binds"
for pair in "${ANALYST_EMAIL}:${ANALYST_PW}" "${ADMIN_EMAIL}:${ADMIN_USER_PW}"; do
  email="${pair%%:*}"; pw="${pair#*:}"
  uid="${email%%@*}"
  if dexec -e BPW="$pw" abi-openldap sh -c \
       "ldapwhoami -x -H ldap://localhost -D 'uid=${uid},ou=people,${BASE_DN}' -w \"\$BPW\"" \
       >/dev/null 2>&1; then
    ok "  bind OK as uid=${uid} (${email})"
  else
    die "  bind FAILED as uid=${uid} -- password in LDAP does not match .env"
  fi
done

for pair in "${ANALYST_EMAIL%%@*}:analysts" "${ADMIN_EMAIL%%@*}:admins"; do
  uid="${pair%%:*}"; want="${pair#*:}"
  got="$(dexec -e LDAP_PW="$ADMIN_PW" abi-openldap sh -c \
    "ldapsearch -x -H ldap://localhost -D '${ADMIN_DN}' -w \"\$LDAP_PW\" \
     -b 'uid=${uid},ou=people,${BASE_DN}' -s base memberOf" 2>/dev/null \
    | grep '^memberOf:' | tr -d '\r')"
  case "$got" in
    *"cn=${want},ou=groups,${BASE_DN}"*)
      ok "  memberOf OK: uid=${uid} -> cn=${want}" ;;
    *)
      err "${got:-<memberOf empty>}"
      die "  memberOf NOT populated for uid=${uid} -- the memberof overlay expects
  groupOfUniqueNames/uniqueMember; a groupOfNames group is ignored silently." ;;
  esac
done

count="$(dexec -e LPW="$ADMIN_PW" abi-openldap sh -c \
  "ldapsearch -x -H ldap://localhost -D '${ADMIN_DN}' -w \"\$LPW\" \
   -b 'ou=people,${BASE_DN}' '(objectClass=inetOrgPerson)' dn" 2>/dev/null \
  | tr -d '\r' | grep -c '^dn:' || true)"

[ "${count:-0}" -ge 2 ] || die "expected at least 2 users under ou=people,${BASE_DN}, found ${count:-0}"
ok "LDAP ready: ${count} user(s) under ou=people,${BASE_DN}"
