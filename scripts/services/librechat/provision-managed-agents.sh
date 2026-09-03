#!/usr/bin/env bash

# This command provisions or refreshes governed managed agents for existing OIDC users.
source "$(dirname "${BASH_SOURCE[0]}")/../../general/lib.sh"

container_running abi-librechat || die "abi-librechat is not running"

step "Provisioning managed agents for existing OIDC users"
dexec abi-librechat node /app/api/server/services/provision-existing-oidc-agents.js
