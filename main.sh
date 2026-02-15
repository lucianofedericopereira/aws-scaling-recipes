#!/bin/bash
#
# AWS Scaling Recipes — entry point
# Delegates to deploy.sh for full deployment or individual launch scripts.
#
# Usage: ./main.sh [vertical|horizontal|both]

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

chmod +x "${REPO_ROOT}/deploy.sh"
exec "${REPO_ROOT}/deploy.sh" "$@"
