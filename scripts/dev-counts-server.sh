#!/usr/bin/env bash
# Local BigQuery → JSON state counts (same logic as Cloud Run counts service).
# Usage: ./scripts/dev-counts-server.sh
# Then set MEMBERS_STATE_COUNTS_URL=http://127.0.0.1:8789/ in .env and run ./scripts/dev-local.sh
#
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

load_env_file "${REPO_ROOT}/.env"
export GCP_PROJECT="${GCP_PROJECT_ID}"
export GOOGLE_CLOUD_PROJECT="${GCP_PROJECT_ID}"
if [[ -z "${BQ_TABLE:-}" ]]; then
  echo "Set BQ_TABLE in .env" >&2
  exit 1
fi
export PORT="${PORT:-8789}"
echo "State counts: http://127.0.0.1:${PORT}/  (gcloud auth application-default login if needed)" >&2
exec python3 "${REPO_ROOT}/job/counts_server.py"
