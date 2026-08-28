#!/usr/bin/env bash

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

container_running abi-librechat || die "abi-librechat is not running"
command -v base64 >/dev/null || die "base64 is required"

BI_INSTRUCTIONS_FILE="${REPO_ROOT}/config/librechat/agent-instructions.md"
REVIEW_INSTRUCTIONS_FILE="${REPO_ROOT}/config/librechat/agent-dashboard-instructions.md"
[ -s "$BI_INSTRUCTIONS_FILE" ] || die "missing $BI_INSTRUCTIONS_FILE"
[ -s "$REVIEW_INSTRUCTIONS_FILE" ] || die "missing $REVIEW_INSTRUCTIONS_FILE"
MODEL="$(env_require AZURE_FOUNDRY_MODEL)"
BI_INSTRUCTIONS_B64="$(base64 -w 0 "$BI_INSTRUCTIONS_FILE")"
REVIEW_INSTRUCTIONS_B64="$(base64 -w 0 "$REVIEW_INSTRUCTIONS_FILE")"

step "Provisioning governed Cube agents for OIDC users"
read -r -d '' JS <<'JSEOF' || true
require('module-alias').addAlias('~', '/app/api');

const { randomBytes } = require('crypto');
const { connectDb } = require('./api/db');
const db = require('./api/models');
const { grantPermission } = require('./api/server/services/PermissionService');
const { ResourceType, AccessRoleIds, PrincipalType } = require('librechat-data-provider');

const model = process.env.AZURE_FOUNDRY_MODEL;
const agents = [
  {
    name: 'Agentic BI Analyst',
    description: 'Governed DVD-rental BI analysis through the Cube semantic layer.',
    instructions: Buffer.from(process.env.BI_INSTRUCTIONS_B64, 'base64').toString('utf8'),
    tools: [
      'get_schema_mcp_cube',
      'query_mcp_cube',
      'whoami_mcp_cube',
      'execute_code',
      'file_search',
    ],
    tool_options: {
      get_schema_mcp_cube: { allowed_callers: ['direct', 'code_execution'] },
      query_mcp_cube: { allowed_callers: ['direct', 'code_execution'] },
      whoami_mcp_cube: { allowed_callers: ['direct', 'code_execution'] },
    },
    starters: [
      'Which film category earned the most revenue?',
      'Plot monthly revenue by store for the last 12 months.',
      'Compare each film\'s list price against what it actually earned.',
      'Who are the top 10 customers by lifetime value?',
    ],
  },
  {
    name: 'Dashboard Reviewer',
    description: 'Reads and critiques existing Superset dashboards through its read-only service account.',
    instructions: Buffer.from(process.env.REVIEW_INSTRUCTIONS_B64, 'base64').toString('utf8'),
    tools: [
      'get_instance_info_mcp_superset',
      'list_dashboards_mcp_superset',
      'get_dashboard_info_mcp_superset',
      'list_charts_mcp_superset',
      'get_chart_info_mcp_superset',
      'get_chart_data_mcp_superset',
      'list_datasets_mcp_superset',
      'get_dataset_info_mcp_superset',
      'generate_explore_link_mcp_superset',
      'get_schema_mcp_superset',
      'execute_code',
      'file_search',
    ],
    tool_options: {},
    starters: [
      'What dashboards exist, and what does each one claim?',
      'Read the revenue dashboard and tell me the three things that matter.',
      'Do the KPI tiles reconcile with the detail charts?',
      'Which charts on this dashboard are misleading, and why?',
    ],
  },
];

async function grantOwnerPermissions(userId, agentId) {
  await Promise.all([
    grantPermission({
      principalType: PrincipalType.USER,
      principalId: userId,
      resourceType: ResourceType.AGENT,
      resourceId: agentId,
      accessRoleId: AccessRoleIds.AGENT_OWNER,
      grantedBy: userId,
    }),
    grantPermission({
      principalType: PrincipalType.USER,
      principalId: userId,
      resourceType: ResourceType.REMOTE_AGENT,
      resourceId: agentId,
      accessRoleId: AccessRoleIds.REMOTE_AGENT_OWNER,
      grantedBy: userId,
    }),
  ]);
}

(async () => {
  await connectDb();
  const users = await db.findUsers({ provider: 'openid' }, '_id email name tenantId');
  let created = 0;
  let existing = 0;

  for (const user of users) {
    for (const spec of agents) {
      const filter = { author: user._id, name: spec.name };
      if (user.tenantId) filter.tenantId = user.tenantId;
      let agent = await db.getAgent(filter);

      if (agent) {
        if (agent.instructions !== spec.instructions) {
          agent = await db.updateAgent(
            { _id: agent._id },
            { instructions: spec.instructions },
            { updatingUserId: user._id },
          );
          console.log(`UPDATED ${user.email} ${spec.name} ${agent.id}`);
        }
        await grantOwnerPermissions(user._id, agent._id);
        console.log(`EXISTING ${user.email} ${spec.name} ${agent.id}`);
        existing += 1;
        continue;
      }

      agent = await db.createAgent({
        id: `agent_${randomBytes(16).toString('hex')}`,
        name: spec.name,
        description: spec.description,
        instructions: spec.instructions,
        provider: 'Azure Foundry',
        model,
        model_parameters: { temperature: 0.1 },
        artifacts: 'default',
        tools: spec.tools,
        tool_options: spec.tool_options,
        conversation_starters: spec.starters,
        author: user._id,
        authorName: user.name || user.email,
        tenantId: user.tenantId,
      });
      await grantOwnerPermissions(user._id, agent._id);
      console.log(`CREATED ${user.email} ${spec.name} ${agent.id}`);
      created += 1;
    }
  }

  console.log(`RESULT users=${users.length} created=${created} existing=${existing}`);
  process.exit(0);
})().catch((error) => {
  console.error(error.stack || error.message || String(error));
  process.exit(1);
});
JSEOF

out="$(dexec -i \
  -e BI_INSTRUCTIONS_B64="$BI_INSTRUCTIONS_B64" \
  -e REVIEW_INSTRUCTIONS_B64="$REVIEW_INSTRUCTIONS_B64" \
  -e AZURE_FOUNDRY_MODEL="$MODEL" \
  abi-librechat node - <<< "$JS" 2>&1)" || {
  err "$out"
  die "LibreChat OIDC agent provisioning failed"
}
printf '%s\n' "$out" | sed 's/^/  /'
printf '%s' "$out" | grep -q 'RESULT users=' || die "agent provisioning did not report a result"

if printf '%s' "$out" | grep -q 'RESULT users=0'; then
  info "No OIDC user exists yet. Sign in to LibreChat, then rerun ./scripts/provision-agent.sh."
fi
