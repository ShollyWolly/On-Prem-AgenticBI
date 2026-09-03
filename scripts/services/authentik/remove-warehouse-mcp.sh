#!/usr/bin/env bash

# This cleanup removes the retired direct warehouse MCP application from Authentik.
source "$(dirname "${BASH_SOURCE[0]}")/../../general/lib.sh"

container_running abi-authentik-server || die "abi-authentik-server is not running"

cleanup="from authentik.core.models import Application; from authentik.providers.oauth2.models import OAuth2Provider, ScopeMapping; Application.objects.filter(slug='warehouse-mcp').delete(); OAuth2Provider.objects.filter(client_id='warehouse-mcp').delete(); ScopeMapping.objects.filter(scope_name='warehouse.read').delete(); print('warehouse MCP OAuth configuration removed')"
if ! dexec abi-authentik-server ak shell -c "$cleanup" -v 0 >/dev/null 2>&1; then
  die "could not remove the retired warehouse MCP OAuth configuration"
fi

ok "Removed the retired warehouse MCP OAuth configuration"
