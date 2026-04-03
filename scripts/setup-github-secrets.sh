#!/usr/bin/env bash
#
# Set GitHub Actions secrets from .env / environment (requires: gh auth login).
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

load_env_file "${REPO_ROOT}/.env"

command -v gh >/dev/null 2>&1 || { echo "Install GitHub CLI: https://cli.github.com/" >&2; exit 1; }

REGION="${GCP_REGION:-us-east1}"
PROJECT="${GCP_PROJECT_ID:-}"
JOB_NAME="${GCP_RUN_JOB_NAME:-ncrc-members-export}"

if [[ -z "${PROJECT}" ]]; then
  echo "Set GCP_PROJECT_ID in .env or: export GCP_PROJECT_ID=your-project-id" >&2
  exit 1
fi
if [[ -z "${GITHUB_REPO_OWNER:-}" || -z "${GITHUB_REPO_NAME:-}" ]]; then
  echo "Set GITHUB_REPO_OWNER and GITHUB_REPO_NAME in .env" >&2
  exit 1
fi
REPO="${GITHUB_REPO_OWNER}/${GITHUB_REPO_NAME}"

if [[ -z "${WIF_PROVIDER:-}" ]]; then
  echo "Set WIF_PROVIDER in .env (output of setup-github-oidc.sh)" >&2
  exit 1
fi
WIF_PROV="${WIF_PROVIDER}"
WIF_SA="${WIF_SERVICE_ACCOUNT:-member-map@${PROJECT}.iam.gserviceaccount.com}"

echo "Setting secrets on ${REPO}..."

gh secret set GCP_PROJECT_ID --body="${PROJECT}" --repo="${REPO}"
gh secret set GCP_REGION --body="${REGION}" --repo="${REPO}"
gh secret set GCP_RUN_JOB_NAME --body="${JOB_NAME}" --repo="${REPO}"
gh secret set WIF_PROVIDER --body="${WIF_PROV}" --repo="${REPO}"
gh secret set WIF_SERVICE_ACCOUNT --body="${WIF_SA}" --repo="${REPO}"

echo "Set: GCP_PROJECT_ID, GCP_REGION, GCP_RUN_JOB_NAME, WIF_PROVIDER, WIF_SERVICE_ACCOUNT"
