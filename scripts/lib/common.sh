#!/usr/bin/env bash
# Shared defaults and env loading for GCP setup scripts.
# shellcheck disable=SC1091

set -euo pipefail

# This file lives in scripts/lib/
_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${_LIB_DIR}/../.." && pwd)"

# Defaults: prefer .env / env; else active gcloud project (no project id committed in repo).
if [[ -z "${GCP_PROJECT_ID:-}" ]]; then
  GCP_PROJECT_ID="$(gcloud config get-value project 2>/dev/null || true)"
fi
export GCP_PROJECT_ID
export GCP_REGION="${GCP_REGION:-us-east1}"
export MEMBER_MAP_SA_ID="${MEMBER_MAP_SA_ID:-member-map}"
if [[ -n "${GCP_PROJECT_ID:-}" ]]; then
  export MEMBER_MAP_SA_EMAIL="${MEMBER_MAP_SA_EMAIL:-${MEMBER_MAP_SA_ID}@${GCP_PROJECT_ID}.iam.gserviceaccount.com}"
else
  export MEMBER_MAP_SA_EMAIL="${MEMBER_MAP_SA_EMAIL:-}"
fi

load_env_file() {
  local f="${1:-${REPO_ROOT}/.env}"
  if [[ -f "$f" ]]; then
    # shellcheck disable=SC1090
    set -a
    # shellcheck source=/dev/null
    source "$f"
    set +a
  fi
}

require_gcloud() {
  command -v gcloud >/dev/null 2>&1 || {
    echo "gcloud CLI not found. Install: https://cloud.google.com/sdk/docs/install" >&2
    exit 1
  }
}

project_number() {
  gcloud projects describe "$GCP_PROJECT_ID" --format='value(projectNumber)'
}
