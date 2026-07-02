#!/usr/bin/env bash
# scripts/bootstrap.sh — one-time, idempotent provisioning for cloudy-handoff.
#
# Bring-your-own-GCP: everything below is created in YOUR project. Run once:
#
#   gcloud auth login
#   gcloud config set project <your-project>
#   ./scripts/bootstrap.sh            # uses/builds the container image
#   ./scripts/bootstrap.sh --build    # force a fresh image build from source
#
# Safe to re-run; each step checks for existing resources first.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${HERE}/.." && pwd)"
# shellcheck source=scripts/lib/gcp.sh
. "${HERE}/lib/gcp.sh"

FORCE_BUILD=0
for arg in "$@"; do
  case "$arg" in
    --build) FORCE_BUILD=1 ;;
    -h|--help)
      grep '^#' "$0" | sed 's/^# \{0,1\}//' | sed '/^!/d'; exit 0 ;;
    *) die "unknown argument: $arg" ;;
  esac
done

require_cmd gcloud curl jq
load_config

log "project=${PROJECT_ID} region=${REGION} job=${JOB_NAME}"

# 1. APIs -------------------------------------------------------------------
ensure_apis run.googleapis.com secretmanager.googleapis.com \
  artifactregistry.googleapis.com storage.googleapis.com \
  firestore.googleapis.com cloudbuild.googleapis.com

# 2. Core resources ---------------------------------------------------------
ensure_service_account
ensure_bucket
ensure_firestore
ensure_ar_repo

# 3. IAM for the runtime SA (least privilege) -------------------------------
# Firestore read/write. (Firestore has no per-database IAM, so this is project
# scoped — the tightest available role for Datastore/Firestore data access.)
grant_sa_role roles/datastore.user
# Bucket-scoped object read/write (NOT project-wide storage admin).
gcloud storage buckets add-iam-policy-binding "gs://${BUCKET}" \
  --member "serviceAccount:${SA_EMAIL}" \
  --role roles/storage.objectAdmin -q >/dev/null
ok "granted bucket-scoped objectAdmin to runtime SA"

# 4. Secrets (placeholder versions; real values pushed at handoff time) -----
# Each ensure_secret also grants the runtime SA accessor on that secret only.
for s in claude-oauth-token anthropic-api-key openai-api-key git-token; do
  ensure_secret "$s"
done
# Codex auth.json is mounted as a file; seed a valid empty-ish JSON placeholder.
if ! secret_exists codex-auth; then
  ensure_secret codex-auth '{}'
else
  ensure_secret codex-auth   # (re)grant accessor
fi

# 5. Container image --------------------------------------------------------
image_exists() { gcloud artifacts docker images describe "$IMAGE" >/dev/null 2>&1; }
if [ "$FORCE_BUILD" -eq 1 ] || ! image_exists; then
  log "building image via Cloud Build → ${IMAGE}"
  gcloud builds submit "$REPO_ROOT" \
    --config "${REPO_ROOT}/deploy/cloudbuild.yaml" \
    --substitutions "_IMAGE=${IMAGE}" \
    --project "$PROJECT_ID"
  ok "image built: ${IMAGE}"
else
  ok "image already present: ${IMAGE} (use --build to rebuild)"
fi

# 6. Cloud Run Job ----------------------------------------------------------
# All credential secrets are mounted; empty/placeholder values are unset by
# the entrypoint, so mounting them all keeps the Job definition stable.
JOB_SECRETS="CLAUDE_CODE_OAUTH_TOKEN=claude-oauth-token:latest"
JOB_SECRETS+=",ANTHROPIC_API_KEY=anthropic-api-key:latest"
JOB_SECRETS+=",OPENAI_API_KEY=openai-api-key:latest"
JOB_SECRETS+=",GIT_TOKEN=git-token:latest"
JOB_SECRETS+=",/secrets/codex/auth.json=codex-auth:latest"

JOB_ENV="BUCKET=${BUCKET},FIRESTORE_DATABASE=${FIRESTORE_DATABASE}"
JOB_ENV+=",MAX_HOURS=${MAX_HOURS},CLAUDE_AUTH_MODE=${CLAUDE_AUTH_MODE}"

job_common_args=(
  --image "$IMAGE"
  --region "$REGION"
  --service-account "$SA_EMAIL"
  --cpu "$CPU" --memory "$MEMORY"
  --task-timeout "$TASK_TIMEOUT"
  --max-retries 0
  --set-env-vars "$JOB_ENV"
  --set-secrets "$JOB_SECRETS"
  --project "$PROJECT_ID"
)

if gcloud run jobs describe "$JOB_NAME" --region "$REGION" --project "$PROJECT_ID" >/dev/null 2>&1; then
  log "updating existing Cloud Run Job ${JOB_NAME}"
  gcloud run jobs update "$JOB_NAME" "${job_common_args[@]}"
else
  log "creating Cloud Run Job ${JOB_NAME}"
  gcloud run jobs create "$JOB_NAME" "${job_common_args[@]}"
fi
ok "Cloud Run Job ready: ${JOB_NAME}"

cat >&2 <<EOF

────────────────────────────────────────────────────────────
✓ bootstrap complete.

  project : ${PROJECT_ID}
  region  : ${REGION}
  job     : ${JOB_NAME}
  image   : ${IMAGE}
  bucket  : gs://${BUCKET}
  runner  : ${SA_EMAIL}

Next: from any local repo, run

  /handoff "describe the task to run in the cloud"

(or scripts/handoff.sh "…"). Credentials are forwarded on first handoff.
────────────────────────────────────────────────────────────
EOF
