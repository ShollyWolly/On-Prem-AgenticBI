#!/usr/bin/env bash

bash "$(dirname "$0")/migrate-librechat-oidc.sh" "$@"
bash "$(dirname "$0")/provision-librechat-oidc-agents.sh" "$@"
