#!/usr/bin/env bash

# This repository-root wrapper forwards every option to the supported bootstrap implementation.
exec "$(dirname "${BASH_SOURCE[0]}")/scripts/deployment/bootstrap.sh" "$@"
