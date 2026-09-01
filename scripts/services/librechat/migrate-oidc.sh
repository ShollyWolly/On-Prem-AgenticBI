#!/usr/bin/env bash

source "$(dirname "${BASH_SOURCE[0]}")/../../general/lib.sh"

container_running abi-mongodb || die "abi-mongodb is not running"
command -v base64 >/dev/null || die "base64 is required"

INSTRUCTIONS_FILE="${REPO_ROOT}/config/librechat/agent-instructions.md"
[ -s "$INSTRUCTIONS_FILE" ] || die "missing $INSTRUCTIONS_FILE"
INSTRUCTIONS_B64="$(base64 -w 0 "$INSTRUCTIONS_FILE")"

# This migration replaces legacy role-specific Cube tools with the user-scoped OAuth server.
step "Migrating existing Cube agents to per-user OAuth MCP"
read -r -d '' JS <<'JSEOF' || true
const text = Buffer.from(process.env.AGENT_INSTRUCTIONS_B64, 'base64').toString('utf8');
const dbx = db.getSiblingDB('LibreChat');
const agents = dbx.agents;
const oldTools = [
  'execute_sql_mcp_cube_analyst', 'list_schemas_mcp_cube_analyst',
  'list_objects_mcp_cube_analyst', 'get_object_details_mcp_cube_analyst',
  'execute_sql_mcp_cube_admin', 'list_schemas_mcp_cube_admin',
  'list_objects_mcp_cube_admin', 'get_object_details_mcp_cube_admin',
];
const replacement = ['get_schema_mcp_cube', 'query_mcp_cube', 'whoami_mcp_cube'];
let changed = 0;
agents.find({ tools: { $in: oldTools } }).forEach((agent) => {
  const retained = (agent.tools || []).filter((tool) => !oldTools.includes(tool));
  const tools = [...new Set([...retained, ...replacement])];
  const tool_options = Object.assign({}, agent.tool_options || {});
  for (const tool of oldTools) delete tool_options[tool];
  for (const tool of replacement) tool_options[tool] = { allowed_callers: ['direct', 'code_execution'] };
  const result = agents.updateOne({ _id: agent._id }, {
    $set: {
      tools,
      tool_options,
      mcpServerNames: ['cube'],
      instructions: text,
      updatedAt: new Date(),
    },
  });
  print(`MIGRATED ${agent.id} (${agent.name}) matched=${result.matchedCount}`);
  changed += result.modifiedCount;
});
print(`RESULT changed=${changed}`);
JSEOF

out="$(dexec -i -e AGENT_INSTRUCTIONS_B64="$INSTRUCTIONS_B64" abi-mongodb mongosh --quiet <<< "$JS" 2>&1)" || {
  err "$out"; die "mongosh migration failed"
}
printf '%s\n' "$out" | sed 's/^/  /'
printf '%s' "$out" | grep -q 'RESULT changed=' || die "migration did not report a result"

info "Existing users are linked to Authentik by e-mail at their first OIDC login; their Mongo _id is preserved."
