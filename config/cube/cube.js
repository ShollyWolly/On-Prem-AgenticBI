
const DENIED = 'denied';

// SQL clients have fixed identities from configuration, while unknown users are denied.
const ROLE_MAP = JSON.parse(process.env.CUBE_USER_ROLE_MAP || '{}');
const REST_ROLES = new Set(['analyst', 'admin']);

for (const [email, entry] of Object.entries(ROLE_MAP)) {
  if (!entry || typeof entry.role !== 'string' || !entry.role) {
    throw new Error(`CUBE_USER_ROLE_MAP: entry for "${email}" has no role`);
  }
  if (entry.role === DENIED) {
    throw new Error(`CUBE_USER_ROLE_MAP: "${DENIED}" is reserved and cannot be assigned (offender: ${email})`);
  }
}

function identityFor(username) {
  const email = String(username || '').trim().toLowerCase();
  const entry = ROLE_MAP[email];

  if (!email || !entry) {
    return { user: email, role: DENIED, groups: [DENIED] };
  }
  return { user: email, role: entry.role, groups: [entry.role] };
}

module.exports = {
  checkSqlAuth: (req, username, password) => ({
    password: process.env.CUBEJS_SQL_PASSWORD,
    securityContext: identityFor(username),
  }),

  // Separate Cube cache namespaces by role so cached data never crosses roles.
  contextToAppId: ({ securityContext }) =>
    `cube_${(securityContext && securityContext.role) || DENIED}`,

  extendContext: ({ securityContext }) => {
    const supplied = securityContext && securityContext.securityContext
      ? securityContext.securityContext
      : securityContext;
    const sc = Object.assign({}, supplied);
    // The gateway must supply exactly one supported role or Cube fails closed.
    const permitted = REST_ROLES.has(sc.role) && Array.isArray(sc.groups) &&
      sc.groups.length === 1 && sc.groups[0] === sc.role;
    if (!permitted) return { securityContext: { role: DENIED, groups: [DENIED] } };
    return { securityContext: sc };
  },

  contextToGroups: ({ securityContext }) =>
    (securityContext && securityContext.groups) || [DENIED],

  canSwitchSqlUser: () => false,
};
