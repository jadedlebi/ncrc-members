#!/usr/bin/env bash
#
# Create a Workload Identity Pool + OIDC provider for GitHub Actions and allow
# workflows in one repository to impersonate member-map@PROJECT.
#
# Usage (set env or add to .env): GITHUB_REPO_OWNER, GITHUB_REPO_NAME, GCP_PROJECT_ID
#   ./scripts/setup-github-oidc.sh
#
# After success, add these GitHub repository secrets:
#   WIF_PROVIDER = projects/PROJECT_NUMBER/locations/global/workloadIdentityPools/POOL/providers/PROVIDER
#   WIF_SERVICE_ACCOUNT = member-map@PROJECT.iam.gserviceaccount.com
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

load_env_file "${REPO_ROOT}/.env"

export WIF_POOL_ID="${WIF_POOL_ID:-github-actions-pool}"
export WIF_PROVIDER_ID="${WIF_PROVIDER_ID:-github-oidc}"
export GITHUB_REPO_OWNER="${GITHUB_REPO_OWNER:-}"
export GITHUB_REPO_NAME="${GITHUB_REPO_NAME:-}"

require_gcloud

if [[ -z "${GCP_PROJECT_ID:-}" ]]; then
  echo "Set GCP_PROJECT_ID in .env or: gcloud config set project YOUR_PROJECT_ID" >&2
  exit 1
fi

if [[ -z "${GITHUB_REPO_OWNER}" || -z "${GITHUB_REPO_NAME}" ]]; then
  echo "Set GITHUB_REPO_OWNER and GITHUB_REPO_NAME (e.g. in .env from .env.example)." >&2
  exit 1
fi

PN="$(project_number)"
REPO_ATTR="${GITHUB_REPO_OWNER}/${GITHUB_REPO_NAME}"
PRINCIPAL_MEMBER="principalSet://iam.googleapis.com/projects/${PN}/locations/global/workloadIdentityPools/${WIF_POOL_ID}/attribute.repository/${REPO_ATTR}"

echo "Project:          ${GCP_PROJECT_ID} (number ${PN})"
echo "Service account:  ${MEMBER_MAP_SA_EMAIL}"
echo "GitHub repository: ${REPO_ATTR}"
echo "Pool / provider:  ${WIF_POOL_ID} / ${WIF_PROVIDER_ID}"
echo

gcloud services enable iamcredentials.googleapis.com sts.googleapis.com --project="${GCP_PROJECT_ID}"

if ! gcloud iam workload-identity-pools describe "${WIF_POOL_ID}" --location=global --project="${GCP_PROJECT_ID}" &>/dev/null; then
  echo "Creating workload identity pool..."
  gcloud iam workload-identity-pools create "${WIF_POOL_ID}" \
    --project="${GCP_PROJECT_ID}" \
    --location="global" \
    --display-name="GitHub Actions"
else
  echo "Workload identity pool exists: ${WIF_POOL_ID}"
fi

if ! gcloud iam workload-identity-pools providers describe "${WIF_PROVIDER_ID}" --location=global --workload-identity-pool="${WIF_POOL_ID}" --project="${GCP_PROJECT_ID}" &>/dev/null; then
  echo "Creating OIDC provider (GitHub)..."
  gcloud iam workload-identity-pools providers create-oidc "${WIF_PROVIDER_ID}" \
    --project="${GCP_PROJECT_ID}" \
    --location="global" \
    --workload-identity-pool="${WIF_POOL_ID}" \
    --display-name="GitHub" \
    --issuer-uri="https://token.actions.githubusercontent.com" \
    --attribute-mapping="google.subject=assertion.sub,attribute.actor=assertion.actor,attribute.repository=assertion.repository,attribute.repository_owner=assertion.repository_owner" \
    --attribute-condition="assertion.repository_owner == '${GITHUB_REPO_OWNER}'"
else
  echo "OIDC provider exists: ${WIF_PROVIDER_ID}"
fi

echo "Allowing GitHub repo ${REPO_ATTR} to impersonate ${MEMBER_MAP_SA_EMAIL}..."
gcloud iam service-accounts add-iam-policy-binding "${MEMBER_MAP_SA_EMAIL}" \
  --project="${GCP_PROJECT_ID}" \
  --role="roles/iam.workloadIdentityUser" \
  --member="${PRINCIPAL_MEMBER}" \
  --quiet

WIF_PROVIDER_RESOURCE="projects/${PN}/locations/global/workloadIdentityPools/${WIF_POOL_ID}/providers/${WIF_PROVIDER_ID}"

echo
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Add these GitHub Actions repository secrets:"
echo
echo "  GCP_PROJECT_ID=${GCP_PROJECT_ID}"
echo "  WIF_PROVIDER=${WIF_PROVIDER_RESOURCE}"
echo "  WIF_SERVICE_ACCOUNT=${MEMBER_MAP_SA_EMAIL}"
echo
echo "Use in workflow (google-github-actions/auth@v2):"
echo "  workload_identity_provider: \${{ secrets.WIF_PROVIDER }}"
echo "  service_account: \${{ secrets.WIF_SERVICE_ACCOUNT }}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo
echo "GitHub Actions job must request the token:"
echo '  permissions:'
echo '    id-token: write'
echo '    contents: read'
