
const fs = require('fs');
const path = require('path');
const { randomBytes } = require('crypto');
const db = require('~/models');
const { logger } = require('@librechat/data-schemas');
const { grantPermission } = require('~/server/services/PermissionService');
const { ResourceType, AccessRoleIds, PrincipalType } = require('librechat-data-provider');

const configDir = process.env.AGENTIC_BI_CONFIG_DIR || '/app/agentic-bi-config';

const readInstructions = (filename) => {
  const file = path.join(configDir, filename);
  return fs.readFileSync(file, 'utf8');
};

const agentSpecs = () => [
  {
    name: 'Agentic BI Analyst',
    description: 'Governed DVD-rental BI analysis through the Cube semantic layer.',
    instructions: readInstructions('agent-instructions.md'),
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
    conversation_starters: [
      'Which film category earned the most revenue?',
      'Plot monthly revenue by store for the last 12 months.',
      'Compare each film\'s list price against what it actually earned.',
      'Who are the top 10 customers by lifetime value?',
    ],
  },
  {
    name: 'Dashboard Reviewer',
    description: 'Reads and critiques existing Superset dashboards through its read-only service account.',
    instructions: readInstructions('agent-dashboard-instructions.md'),
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
    conversation_starters: [
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

async function provisionOidcAgents(user) {
  if (!user?._id || user.provider !== 'openid') {
    return;
  }

  for (const spec of agentSpecs()) {
    const filter = { author: user._id, name: spec.name };
    if (user.tenantId) {
      filter.tenantId = user.tenantId;
    }

    let agent = await db.getAgent(filter);
    if (!agent) {
      agent = await db.createAgent({
        id: `agent_${randomBytes(16).toString('hex')}`,
        ...spec,
        provider: 'Azure Foundry',
        model: process.env.AZURE_FOUNDRY_MODEL,
        model_parameters: { temperature: 0.1 },
        artifacts: 'default',
        author: user._id,
        authorName: user.name || user.email,
        tenantId: user.tenantId,
      });
      logger.info(`[oidcAgentProvisioning] Created '${spec.name}' for ${user.email}`);
    } else if (agent.instructions !== spec.instructions) {
      agent = await db.updateAgent(
        { _id: agent._id },
        { instructions: spec.instructions },
        { updatingUserId: user._id },
      );
      logger.info(`[oidcAgentProvisioning] Updated '${spec.name}' prompt for ${user.email}`);
    }

    await grantOwnerPermissions(user._id, agent._id);
  }
}

module.exports = { provisionOidcAgents };
