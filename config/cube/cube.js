/**
 * Cube Core configuration - the identity half of the governance boundary.
 *
 *   SQL username -> checkSqlAuth -> securityContext -> contextToGroups
 *                -> access_policy on the views -> masked / real / denied
 *
 * See docs/TRAPS.md before changing anything here.
 */

const DENIED = 'denied';

const ROLE_MAP = JSON.parse(process.env.CUBE_USER_ROLE_MAP || '{}');

// A typo like {"someone":{"role":"denied"}} would put a real user in the group that
// means "no access", minting a silent super-user. Fail at boot instead.
for (const [email, entry] of Object.entries(ROLE_MAP)) {
  if (!entry || typeof entry.role !== 'string' || !entry.role) {
    throw new Error(`CUBE_USER_ROLE_MAP: entry for "${email}" has no role`);
  }
  if (entry.role === DENIED) {
    throw new Error(`CUBE_USER_ROLE_MAP: "${DENIED}" is reserved and cannot be assigned (offender: ${email})`);
  }
}

// Fail closed by construction: `denied` is the DEFAULT branch, not an else-if, and it
// appears in no access_policy - Cube denies every group without one, so there is no
// deny rule to forget. The connection still succeeds, so an unknown user gets a clean
// "not authorized" error rather than an opaque connection failure.
function identityFor(username) {
  const email = String(username || '').trim().toLowerCase();
  const entry = ROLE_MAP[email];

  if (!email || !entry) {
    return { user: email, role: DENIED, groups: [DENIED] };
  }
  return { user: email, role: entry.role, groups: [entry.role] };
}

module.exports = {
  // `password` must be returned UNCONDITIONALLY: on re-auth (every
  // CUBESQL_AUTH_EXPIRE_SECS, default 300) the incoming argument is undefined, and
  // returning it only when supplied breaks every pooled connection after 5 minutes.
  checkSqlAuth: (req, username, password) => ({
    password: process.env.CUBEJS_SQL_PASSWORD,
    securityContext: identityFor(username),
  }),

  // Keyed on ROLE, never e-mail: this runs on every request and each distinct value
  // compiles and retains its own copy of the data model (cap ~250, then LRU evict).
  contextToAppId: ({ securityContext }) =>
    `cube_${(securityContext && securityContext.role) || DENIED}`,

  // The REST /meta path takes securityContext straight from the JWT payload rather
  // than from checkSqlAuth, so a malformed token must still land in `denied`.
  extendContext: ({ securityContext }) => {
    const sc = Object.assign({}, securityContext);
    if (!sc.role) sc.role = DENIED;
    if (!Array.isArray(sc.groups) || sc.groups.length === 0) sc.groups = [sc.role];
    return { securityContext: sc };
  },

  // contextToGroups, NOT contextToRoles. This is the bridge from securityContext to
  // the `group:` names used by access_policy.
  contextToGroups: ({ securityContext }) =>
    (securityContext && securityContext.groups) || [DENIED],

  // Nobody may switch identity. CUBEJS_SQL_SUPER_USER is unset for the same reason:
  // the connection carries the identity, so there is nothing to re-scope.
  canSwitchSqlUser: () => false,
};
