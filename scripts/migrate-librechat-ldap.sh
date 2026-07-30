#!/usr/bin/env bash
# Convert LibreChat's existing LOCAL users into LDAP users, in place.
#
# RUN THIS BEFORE THE FIRST LDAP LOGIN -- a hard ordering requirement, not advice.
# ldapStrategy looks users up by `ldapId`, which a local user does not have, so it
# falls through to createUser with the same e-mail and Mongo rejects it on the
# unique index: the login 500s. Setting ldapId alone is not enough either, because
# a user whose provider is not 'ldap' is refused with a bare AUTH_FAILED. Both
# fields must change together.
#
# In place rather than delete-and-recreate: agents, files and conversations all
# reference the user's `_id`, so deleting would orphan both provisioned agents and
# every uploaded file -- surfacing as "the agent disappeared".
#
# Idempotent once both users are provider=ldap.

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ANALYST_EMAIL="$(env_require DEMO_ANALYST_EMAIL)"
ADMIN_EMAIL="$(env_require DEMO_ADMIN_EMAIL)"

container_running abi-mongodb || die "abi-mongodb is not running"

step "Migrating LibreChat users to provider=ldap"

# ldapId must equal what the strategy will compute: LDAP_ID=uid, and our uid is
# the local part of the e-mail (see scripts/init-ldap.sh). If those two ever
# disagree the login creates a SECOND user instead of matching the existing one.
read -r -d '' JS <<'JSEOF' || true
const targets = JSON.parse(process.env.TARGETS);
const users = db.getSiblingDB('LibreChat').users;
let changed = 0;
for (const [email, uid] of Object.entries(targets)) {
  const u = users.findOne({ email: email });
  if (!u) { print(`MISSING  ${email} -- not in Mongo, LDAP will create it on first login`); continue; }
  if (u.provider === 'ldap' && u.ldapId === uid) { print(`OK       ${email} already provider=ldap ldapId=${uid}`); continue; }
  const res = users.updateOne(
    { _id: u._id },
    { $set: { provider: 'ldap', ldapId: uid } },
    // NOTE: no $unset of `password`. LibreChat keeps the hash on the document and
    // simply stops consulting it for an ldap-provider user; removing it would make
    // a rollback to local auth impossible without a password reset.
  );
  print(`MIGRATED ${email} provider=${u.provider}->ldap ldapId=${uid} (matched=${res.matchedCount})`);
  changed++;
}
print(`RESULT changed=${changed}`);
JSEOF

TARGETS="$(printf '{"%s":"%s","%s":"%s"}' \
  "$ANALYST_EMAIL" "${ANALYST_EMAIL%%@*}" \
  "$ADMIN_EMAIL"   "${ADMIN_EMAIL%%@*}")"

out="$(dexec -i -e TARGETS="$TARGETS" abi-mongodb mongosh --quiet <<< "$JS" 2>&1)" || {
  err "$out"; die "mongosh failed"
}
printf '%s\n' "$out" | sed 's/^/  /'

printf '%s' "$out" | grep -q 'RESULT changed=' || die "migration did not report a result"

# Show the end state, because "changed=0" is ambiguous on its own -- it means both
# "already migrated" and "nothing matched".
step "Post-migration state"
dexec abi-mongodb mongosh --quiet --eval \
  'db.getSiblingDB("LibreChat").users.find({}, {email:1, username:1, provider:1, ldapId:1, _id:0}).forEach(u => printjson(u))' \
  2>&1 | sed 's/^/  /'
