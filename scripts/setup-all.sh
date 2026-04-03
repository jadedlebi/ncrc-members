#!/usr/bin/env bash
# Run service account + GitHub OIDC setup in order.
# Same flags as setup-service-account.sh are forwarded (e.g. --with-ci-deploy --create-key).
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
"${DIR}/setup-service-account.sh" "$@"
"${DIR}/setup-github-oidc.sh"
