#!/usr/bin/env bash
#
# Build images (Cloud Build), push to Artifact Registry, deploy Cloud Run Job + Service.
# Prerequisites: ./scripts/setup-service-account.sh, APIs enabled, Mapbox secrets in Secret Manager (or created as placeholders).
#
# Usage: ./scripts/deploy-cloud-run.sh
# Optional env: IMAGE_TAG=20250403 (default: latest)
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

load_env_file "${REPO_ROOT}/.env"

require_gcloud

REGION="${GCP_REGION:-us-east1}"
PROJECT="${GCP_PROJECT_ID:-}"
if [[ -z "${PROJECT}" ]]; then
  echo "Set GCP_PROJECT_ID in .env or gcloud config set project ..." >&2
  exit 1
fi
AR_REPO="${AR_REPOSITORY_ID:-ncrc-members}"
SA_EMAIL="${MEMBER_MAP_SA_EMAIL}"
IMAGE_TAG="${IMAGE_TAG:-latest}"
JOB_NAME="${GCP_RUN_JOB_NAME:-ncrc-members-export}"
SERVICE_NAME="${CLOUD_RUN_SERVICE_NAME:-ncrc-members-web}"
SERVICE_NAME_COUNTS="${CLOUD_RUN_COUNTS_SERVICE_NAME:-ncrc-members-counts}"

REGISTRY_HOST="${REGION}-docker.pkg.dev"
IMAGE_BASE="${REGISTRY_HOST}/${PROJECT}/${AR_REPO}"
IMAGE_WEB="${IMAGE_BASE}/web:${IMAGE_TAG}"
IMAGE_JOB="${IMAGE_BASE}/job:${IMAGE_TAG}"
IMAGE_COUNTS="${IMAGE_BASE}/counts:${IMAGE_TAG}"

BQ_TABLE="${BQ_TABLE:-}"
MAPBOX_TILESET="${MAPBOX_TILESET:-}"
STATE_BOUNDARIES_TILESET_URL="${STATE_BOUNDARIES_TILESET_URL:-}"
if [[ -z "${BQ_TABLE}" || -z "${MAPBOX_TILESET}" || -z "${STATE_BOUNDARIES_TILESET_URL}" || -z "${MAPBOX_STYLE_URL}" ]]; then
  echo "Set BQ_TABLE, MAPBOX_TILESET, STATE_BOUNDARIES_TILESET_URL, and MAPBOX_STYLE_URL in .env" >&2
  exit 1
fi
MAPBOX_STYLE_URL="${MAPBOX_STYLE_URL:-}"
MAPBOX_UPLOAD_NAME="${MAPBOX_UPLOAD_NAME:-ncrc-members-weekly}"
MAPBOX_TILESET_URL="${MAPBOX_TILESET_URL:-mapbox://${MAPBOX_TILESET}}"
MEMBERS_SOURCE_LAYER="${MEMBERS_SOURCE_LAYER:-ncrc-members-weekly}"
MEMBERS_STATE_COUNTS_URL="${MEMBERS_STATE_COUNTS_URL:-}"
MEMBERS_STATE_COUNTS_REFRESH_SEC="${MEMBERS_STATE_COUNTS_REFRESH_SEC:-0}"
STATE_COUNTS_CACHE_TTL_SEC="${STATE_COUNTS_CACHE_TTL_SEC:-300}"
STATE_BOUNDARIES_SOURCE_LAYER="${STATE_BOUNDARIES_SOURCE_LAYER:-State_Shoreline-al2frv}"

SECRET_UPLOAD="${MAPBOX_UPLOAD_SECRET_NAME:-mapbox-members-upload-token}"
SECRET_PUBLIC="${MAPBOX_PUBLIC_SECRET_NAME:-mapbox-members-public-token}"

echo "Project:  ${PROJECT}"
echo "Region:   ${REGION}"
echo "Images:   ${IMAGE_WEB} , ${IMAGE_JOB} , ${IMAGE_COUNTS}"
echo

gcloud config set project "${PROJECT}" >/dev/null

echo "Ensuring Artifact Registry repository ${AR_REPO}..."
if ! gcloud artifacts repositories describe "${AR_REPO}" --location="${REGION}" --project="${PROJECT}" &>/dev/null; then
  gcloud artifacts repositories create "${AR_REPO}" \
    --repository-format=docker \
    --location="${REGION}" \
    --description="NCRC member map containers"
fi

echo "Granting ${SA_EMAIL} read access to ${AR_REPO}..."
gcloud artifacts repositories add-iam-policy-binding "${AR_REPO}" \
  --location="${REGION}" \
  --project="${PROJECT}" \
  --member="serviceAccount:${SA_EMAIL}" \
  --role=roles/artifactregistry.reader \
  --quiet 2>/dev/null || true

ensure_secret_placeholder() {
  local name="$1"
  local label="$2"
  if gcloud secrets describe "${name}" --project="${PROJECT}" &>/dev/null; then
    echo "Secret exists: ${name}"
    return
  fi
  echo "Creating placeholder secret ${name} — update value in Secret Manager (${label})."
  echo -n "PLACEHOLDER_UPDATE_ME" | gcloud secrets create "${name}" \
    --project="${PROJECT}" \
    --replication-policy=automatic \
    --data-file=-
}

ensure_secret_placeholder "${SECRET_UPLOAD}" "Mapbox uploads token (sk. or token with uploads:read, uploads:write)"
ensure_secret_placeholder "${SECRET_PUBLIC}" "Mapbox public token (pk.) for the web map"

echo "Building and pushing images via Cloud Build..."
(
  cd "${REPO_ROOT}"
  gcloud builds submit --project="${PROJECT}" --tag "${IMAGE_WEB}" .
  gcloud builds submit --project="${PROJECT}" \
    --config="${REPO_ROOT}/cloudbuild.job.yaml" \
    --substitutions="_IMAGE=${IMAGE_JOB}" \
    .
  gcloud builds submit --project="${PROJECT}" \
    --config="${REPO_ROOT}/cloudbuild.counts.yaml" \
    --substitutions="_IMAGE=${IMAGE_COUNTS}" \
    .
)

echo "Deploying Cloud Run Job ${JOB_NAME}..."
if gcloud run jobs describe "${JOB_NAME}" --region="${REGION}" --project="${PROJECT}" &>/dev/null; then
  gcloud run jobs update "${JOB_NAME}" \
    --region="${REGION}" \
    --project="${PROJECT}" \
    --image="${IMAGE_JOB}" \
    --service-account="${SA_EMAIL}" \
    --set-env-vars="GCP_PROJECT=${PROJECT},GOOGLE_CLOUD_PROJECT=${PROJECT},BQ_TABLE=${BQ_TABLE},MAPBOX_TILESET=${MAPBOX_TILESET},MAPBOX_UPLOAD_NAME=${MAPBOX_UPLOAD_NAME}" \
    --set-secrets="MAPBOX_ACCESS_TOKEN=${SECRET_UPLOAD}:latest" \
    --max-retries=1 \
    --task-timeout=1h
else
  gcloud run jobs create "${JOB_NAME}" \
    --region="${REGION}" \
    --project="${PROJECT}" \
    --image="${IMAGE_JOB}" \
    --service-account="${SA_EMAIL}" \
    --set-env-vars="GCP_PROJECT=${PROJECT},GOOGLE_CLOUD_PROJECT=${PROJECT},BQ_TABLE=${BQ_TABLE},MAPBOX_TILESET=${MAPBOX_TILESET},MAPBOX_UPLOAD_NAME=${MAPBOX_UPLOAD_NAME}" \
    --set-secrets="MAPBOX_ACCESS_TOKEN=${SECRET_UPLOAD}:latest" \
    --max-retries=1 \
    --task-timeout=1h
fi

echo "Deploying Cloud Run service ${SERVICE_NAME_COUNTS} (BigQuery → JSON state counts)..."
if gcloud run services describe "${SERVICE_NAME_COUNTS}" --region="${REGION}" --project="${PROJECT}" &>/dev/null; then
  gcloud run services update "${SERVICE_NAME_COUNTS}" \
    --region="${REGION}" \
    --project="${PROJECT}" \
    --image="${IMAGE_COUNTS}" \
    --service-account="${SA_EMAIL}" \
    --set-env-vars="GCP_PROJECT=${PROJECT},GOOGLE_CLOUD_PROJECT=${PROJECT},BQ_TABLE=${BQ_TABLE},STATE_COUNTS_CACHE_TTL_SEC=${STATE_COUNTS_CACHE_TTL_SEC}" \
    --allow-unauthenticated
else
  gcloud run deploy "${SERVICE_NAME_COUNTS}" \
    --region="${REGION}" \
    --project="${PROJECT}" \
    --image="${IMAGE_COUNTS}" \
    --service-account="${SA_EMAIL}" \
    --set-env-vars="GCP_PROJECT=${PROJECT},GOOGLE_CLOUD_PROJECT=${PROJECT},BQ_TABLE=${BQ_TABLE},STATE_COUNTS_CACHE_TTL_SEC=${STATE_COUNTS_CACHE_TTL_SEC}" \
    --allow-unauthenticated
fi

COUNTS_URL="$(gcloud run services describe "${SERVICE_NAME_COUNTS}" --region="${REGION}" --project="${PROJECT}" --format='value(status.url)')"
echo "  State counts API: ${COUNTS_URL}/"
echo "  Set MEMBERS_STATE_COUNTS_URL in .env to this URL (plus trailing path / or /state-counts) and redeploy the web service."

echo "Deploying Cloud Run service ${SERVICE_NAME}..."
if gcloud run services describe "${SERVICE_NAME}" --region="${REGION}" --project="${PROJECT}" &>/dev/null; then
  gcloud run services update "${SERVICE_NAME}" \
    --region="${REGION}" \
    --project="${PROJECT}" \
    --image="${IMAGE_WEB}" \
    --service-account="${SA_EMAIL}" \
    --set-env-vars="MAPBOX_STYLE_URL=${MAPBOX_STYLE_URL},MAPBOX_TILESET_URL=${MAPBOX_TILESET_URL},MEMBERS_SOURCE_LAYER=${MEMBERS_SOURCE_LAYER},MEMBERS_STATE_COUNTS_URL=${MEMBERS_STATE_COUNTS_URL},MEMBERS_STATE_COUNTS_REFRESH_SEC=${MEMBERS_STATE_COUNTS_REFRESH_SEC},STATE_BOUNDARIES_TILESET_URL=${STATE_BOUNDARIES_TILESET_URL},STATE_BOUNDARIES_SOURCE_LAYER=${STATE_BOUNDARIES_SOURCE_LAYER}" \
    --set-secrets="MAPBOX_PUBLIC_ACCESS_TOKEN=${SECRET_PUBLIC}:latest" \
    --allow-unauthenticated
else
  gcloud run deploy "${SERVICE_NAME}" \
    --region="${REGION}" \
    --project="${PROJECT}" \
    --image="${IMAGE_WEB}" \
    --service-account="${SA_EMAIL}" \
    --set-env-vars="MAPBOX_STYLE_URL=${MAPBOX_STYLE_URL},MAPBOX_TILESET_URL=${MAPBOX_TILESET_URL},MEMBERS_SOURCE_LAYER=${MEMBERS_SOURCE_LAYER},MEMBERS_STATE_COUNTS_URL=${MEMBERS_STATE_COUNTS_URL},MEMBERS_STATE_COUNTS_REFRESH_SEC=${MEMBERS_STATE_COUNTS_REFRESH_SEC},STATE_BOUNDARIES_TILESET_URL=${STATE_BOUNDARIES_TILESET_URL},STATE_BOUNDARIES_SOURCE_LAYER=${STATE_BOUNDARIES_SOURCE_LAYER}" \
    --set-secrets="MAPBOX_PUBLIC_ACCESS_TOKEN=${SECRET_PUBLIC}:latest" \
    --allow-unauthenticated
fi

echo
echo "Done."
echo "  Job:     gcloud run jobs execute ${JOB_NAME} --region=${REGION} --wait"
echo "  Web map:  gcloud run services describe ${SERVICE_NAME} --region=${REGION} --format='value(status.url)'"
echo "  Counts:   ${COUNTS_URL}/"
echo "Update Secret Manager values for ${SECRET_UPLOAD} and ${SECRET_PUBLIC}, then redeploy or wait for next revision."
