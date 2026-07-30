#!/usr/bin/env bash
# Create the LDAP tree: ou=people, ou=groups, the two demo users, and the two
# groups Superset maps to its own roles. Idempotent.
#
# A script rather than a bootstrap LDIF because passwords come from .env (a
# committed LDIF would drift from it or leak them), and because osixia applies
# its bootstrap LDIF only on first container init -- adding a user later would
# mean deleting the volume.
#
# LDAP unifies LOGIN, not authorization: masking is decided by Cube from
# CUBE_USER_ROLE_MAP, keyed on e-mail. See README's security posture.

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BASE_DN="$(env_get LDAP_BASE_DN || echo 'dc=demo,dc=local')"
ADMIN_DN="$(env_get LDAP_ADMIN_DN || echo "cn=admin,${BASE_DN}")"
ADMIN_PW="$(env_require LDAP_ADMIN_PASSWORD)"

ANALYST_EMAIL="$(env_require DEMO_ANALYST_EMAIL)"
ANALYST_PW="$(env_require DEMO_ANALYST_PASSWORD)"
ADMIN_EMAIL="$(env_require DEMO_ADMIN_EMAIL)"
ADMIN_USER_PW="$(env_require DEMO_ADMIN_PASSWORD)"

container_running abi-openldap || die "abi-openldap is not running (docker compose up -d openldap)"

step "LDAP tree"

# ldapadd/ldapmodify run INSIDE the container: the client tools are there, no
# port is published, and it keeps the admin password off the host command line
# of anything but this script.
ldap_apply() {          # stdin = LDIF, $1 = human label, $2 = "add"|"modify"
  local label="$1" mode="${2:-add}" out rc
  # Assign inside an `if`, never `out=$(...); rc=$?`: under lib.sh's -e a failing
  # command substitution exits AT THE ASSIGNMENT, so a re-run (ldapadd returns 68,
  # the normal idempotent path) would kill the script after printing its header.
  if out="$(dexec -i -e LDAP_PW="$ADMIN_PW" abi-openldap \
              sh -c "ldap${mode} -x -H ldap://localhost -D '${ADMIN_DN}' -w \"\$LDAP_PW\" -c" 2>&1)"; then
    rc=0
  else
    rc=$?
  fi
  # 68 = entry already exists, 20 = attribute/value exists. Both mean "already
  # done", which is the normal path on a re-run, so they are not failures.
  if [ "$rc" -eq 0 ]; then
    ok "  ${label}"
  elif printf '%s' "$out" | grep -qE 'Already exists|(^|[^0-9])20\b.*Type or value exists|Type or value exists'; then
    dim "  ${label} (already present)"
  else
    err "$out"
    die "  ${label} FAILED (rc=$rc)"
  fi
}

# ---- organisational units ---------------------------------------------------
ldap_apply "ou=people / ou=groups" add <<LDIF
dn: ou=people,${BASE_DN}
objectClass: organizationalUnit
ou: people

dn: ou=groups,${BASE_DN}
objectClass: organizationalUnit
ou: groups
LDIF

# ---- users ------------------------------------------------------------------
# uid is the local part; `mail` carries the full address, which is what both apps
# log in with and what CUBE_USER_ROLE_MAP is keyed on.
#
# userPassword goes in clear and slapd hashes it (SSHA); the hop is unix-domain
# inside the container.
add_user() {            # $1=uid $2=cn $3=sn $4=mail $5=password
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

  # Re-applied every run so a regenerated .env cannot drift from the directory.
  # givenName is included because Superset reads it as AUTH_LDAP_FIRSTNAME_FIELD,
  # so an entry from an older version of this script is repaired in place rather
  # than needing the volume deleted.
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

# ---- groups -----------------------------------------------------------------
# groupOfUniqueNames + uniqueMember, NOT groupOfNames + member. osixia configures
# the memberof overlay for the uniqueNames flavour (olcMemberOfGroupOC), so a
# groupOfNames group is accepted, stores its members, and is INVISIBLE to the
# overlay: memberOf never appears, AUTH_ROLES_MAPPING matches nobody, and every
# user silently lands on the default role.
#
# Deleted and recreated rather than modified: objectClass cannot be changed in
# place, so a group created with the wrong one stays wrong. No state is lost.
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

# ---- prove it ---------------------------------------------------------------
# Binding AS EACH USER is the only check that proves the stored password matches
# .env. A search as admin would not.
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

# Assert memberOf rather than assuming it: unpopulated, it surfaces much later as
# "why is admin only a Gamma user?".
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

# Bind AS ADMIN: osixia's ACLs hide these entries from an anonymous bind, and
# OpenLDAP reports hidden as absent. The `|| true` matters as much -- `grep -c`
# exits 1 on a zero count, which under -euo pipefail exits the script at its LAST
# line, after all the work has already succeeded.
count="$(dexec -e LPW="$ADMIN_PW" abi-openldap sh -c \
  "ldapsearch -x -H ldap://localhost -D '${ADMIN_DN}' -w \"\$LPW\" \
   -b 'ou=people,${BASE_DN}' '(objectClass=inetOrgPerson)' dn" 2>/dev/null \
  | tr -d '\r' | grep -c '^dn:' || true)"

[ "${count:-0}" -ge 2 ] || die "expected at least 2 users under ou=people,${BASE_DN}, found ${count:-0}"
ok "LDAP ready: ${count} user(s) under ou=people,${BASE_DN}"
