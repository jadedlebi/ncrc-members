#!/usr/bin/env bash
#
# Create the member-map service account and grant roles for:
#   - Cloud Run Job runtime (BigQuery export → Mapbox)
#   - Invoking Cloud Run Jobs (GitHub Actions via WIF uses this SA)
#   - Reading secrets from Secret Manager (Mapbox token, etc.)
#
# Usage:
#   ./scripts/setup-service-account.sh
#   ./scripts/setup-service-account.sh --create-key   # writes ./member-map-sa-key.json (gitignored)
#   ./scripts/setup-service-account.sh --with-ci-deploy  # adds run.developer + artifactregistry.writer for CI deploys
#
# Requires: gcloud auth login (account with iam.serviceAccounts.create, resourcemanager.projects.setIamPolicy)
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

load_env_file "${REPO_ROOT}/.env"

CREATE_KEY=0
WITH_CI_DEPLOY=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --create-key) CREATE_KEY=1 ;;
    --with-ci-deploy) WITH_CI_DEPLOY=1 ;;
    -h|--help)
      grep '^#' "$0" | grep -v '^#!/' | sed 's/^# //' | sed 's/^#//' | head -20
      exit 0
      ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
  shift || true
done

require_gcloud

if [[ -z "${GCP_PROJECT_ID:-}" ]]; then
  echo "Set GCP_PROJECT_ID in .env or: gcloud config set project YOUR_PROJECT_ID" >&2
  exit 1
fi

echo "Project:        ${GCP_PROJECT_ID}"
echo "Service account: ${MEMBER_MAP_SA_EMAIL}"
echo

echo "Enabling APIs..."
gcloud services enable \
  bigquery.googleapis.com \
  run.googleapis.com \
  secretmanager.googleapis.com \
  iam.googleapis.com \
  iamcredentials.googleapis.com \
  cloudresourcemanager.googleapis.com \
  sts.googleapis.com \
  --project="${GCP_PROJECT_ID}"

if [[ "${WITH_CI_DEPLOY}" -eq 1 ]]; then
  gcloud services enable artifactregistry.googleapis.com --project="${GCP_PROJECT_ID}"
fi

if ! gcloud iam service-accounts describe "${MEMBER_MAP_SA_EMAIL}" --project="${GCP_PROJECT_ID}" &>/dev/null; then
  echo "Creating service account ${MEMBER_MAP_SA_ID}..."
  gcloud iam service-accounts create "${MEMBER_MAP_SA_ID}" \
    --project="${GCP_PROJECT_ID}" \
    --display-name="NCRC member map (export job + automation)" \
    --description="BigQuery export, Cloud Run Job runtime, GitHub Actions (WIF), Secret Manager"
else
  echo "Service account already exists: ${MEMBER_MAP_SA_EMAIL}"
fi

# Core roles (runtime + automation)
ROLES=(
  roles/bigquery.jobUser
  roles/bigquery.dataViewer
  roles/secretmanager.secretAccessor
  roles/logging.logWriter
  roles/run.invoker
)

if [[ "${WITH_CI_DEPLOY}" -eq 1 ]]; then
  ROLES+=(
    roles/run.developer
    roles/artifactregistry.writer
  )
fi

echo "Binding IAM roles..."
for role in "${ROLES[@]}"; do
  gcloud projects add-iam-policy-binding "${GCP_PROJECT_ID}" \
    --member="serviceAccount:${MEMBER_MAP_SA_EMAIL}" \
    --role="${role}" \
    --quiet
done

echo
echo "Done. Service account: ${MEMBER_MAP_SA_EMAIL}"
echo
echo "Next steps:"
echo "  1) Point your Cloud Run Job at this runtime service account:"
echo "     gcloud run jobs update YOUR_JOB --service-account=${MEMBER_MAP_SA_EMAIL} --region=${GCP_REGION:-us-east1}"
echo "  2) Run ./scripts/setup-github-oidc.sh to let GitHub Actions impersonate this account (no JSON key)."
echo "  3) Grant dataset-level access if you use VPC-SC or deny project-level BigQuery (optional):"
echo "     bq show --format=prettyjson justdata-ncrc:hubspot   # then use console or bq to add SA as dataViewer"
echo

if [[ "${CREATE_KEY}" -eq 1 ]]; then
  KEY_PATH="${REPO_ROOT}/member-map-sa-key.json"
  echo "Creating JSON key at ${KEY_PATH} (keep private; rotate if leaked)..."
  gcloud iam service-accounts keys create "${KEY_PATH}" \
    --project="${GCP_PROJECT_ID}" \
    --iam-account="${MEMBER_MAP_SA_EMAIL}"
  echo "Wrote ${KEY_PATH}"
fi
