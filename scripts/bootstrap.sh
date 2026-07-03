#!/usr/bin/env bash
# scripts/bootstrap.sh — one-time, idempotent provisioning for cloudy-handoff.
#
# Bring-your-own-GCP: everything below is created in YOUR project. Run once:
#
#   gcloud auth login
#   ./scripts/bootstrap.sh                          # confirm the active project, then provision
#   ./scripts/bootstrap.sh --project my-proj -y     # target a specific project, no prompt
#   ./scripts/bootstrap.sh --create-project my-new  # create a new project (+link billing) first
#   ./scripts/bootstrap.sh --build                  # force a fresh image build from source
#
# Flags: --project <id> | --create-project <id> | --billing-account <id>
#        --region <r> | --build | -y/--yes (skip confirmation) | -h/--help
#
# Safe to re-run; each step checks for existing resources first.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${HERE}/.." && pwd)"
# shellcheck source=scripts/lib/gcp.sh
. "${HERE}/lib/gcp.sh"

FORCE_BUILD=0; ASSUME_YES=0; CLI_PROJECT=""; CREATE_PROJECT=""; CLI_BILLING=""
while [ $# -gt 0 ]; do
  case "$1" in
    --build) FORCE_BUILD=1; shift ;;
    --project) CLI_PROJECT="$2"; shift 2 ;;
    --project=*) CLI_PROJECT="${1#*=}"; shift ;;
    --create-project) CREATE_PROJECT="$2"; shift 2 ;;
    --create-project=*) CREATE_PROJECT="${1#*=}"; shift ;;
    --billing-account) CLI_BILLING="$2"; shift 2 ;;
    --billing-account=*) CLI_BILLING="${1#*=}"; shift ;;
    --region) REGION="$2"; shift 2 ;;
    --region=*) REGION="${1#*=}"; shift ;;
    -y|--yes) ASSUME_YES=1; shift ;;
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//' | sed '/^!/d'; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

require_cmd gcloud curl jq

# Choose a billing account: explicit flag, else the sole open account, else none.
pick_billing() {
  if [ -n "$CLI_BILLING" ]; then printf '%s' "$CLI_BILLING"; return; fi
  local accts
  accts="$(gcloud beta billing accounts list --filter='open=true' \
            --format='value(name)' 2>/dev/null | sed 's#billingAccounts/##')"
  [ "$(printf '%s\n' "$accts" | grep -c .)" = "1" ] && printf '%s' "$accts"
}

# Resolve PROJECT_ID from flags / active gcloud config, creating or confirming
# as needed, before load_config's hard requirement kicks in.
resolve_project() {
  if [ -n "$CREATE_PROJECT" ]; then
    create_project "$CREATE_PROJECT" "$(pick_billing)"
    PROJECT_ID="$CREATE_PROJECT"; export PROJECT_ID; return
  fi
  PROJECT_ID="${CLI_PROJECT:-$(gcloud config get-value project 2>/dev/null)}"
  [ "$PROJECT_ID" = "(unset)" ] && PROJECT_ID=""

  if [ -z "$PROJECT_ID" ]; then
    { [ "$ASSUME_YES" -eq 1 ] || [ ! -t 0 ]; } && die "no project set — pass --project <id> or --create-project <id>"
    warn "no active project. Recent projects:"
    gcloud projects list --format='value(projectId,name)' 2>/dev/null | head -15 >&2
    read -r -p "Enter a project id (or 'new' to create one): " PROJECT_ID </dev/tty
    if [ "$PROJECT_ID" = "new" ]; then
      read -r -p "New project id: " PROJECT_ID </dev/tty
      create_project "$PROJECT_ID" "$(pick_billing)"
    fi
  fi

  if [ "$ASSUME_YES" -ne 1 ] && [ -t 0 ]; then
    printf '→ provision cloudy-handoff in project "%s"? [y/N/(c)reate new] ' "$PROJECT_ID" >&2
    local ans; read -r ans </dev/tty
    case "$ans" in
      y|Y) ;;
      c|C) read -r -p "New project id: " PROJECT_ID </dev/tty; create_project "$PROJECT_ID" "$(pick_billing)" ;;
      *) die "aborted by user" ;;
    esac
  fi
  export PROJECT_ID
}

resolve_project
load_config

# Ensure the target project has billing (best-effort warning).
if ! gcloud beta billing projects describe "$PROJECT_ID" --format='value(billingEnabled)' 2>/dev/null | grep -qi true; then
  warn "billing does not appear to be enabled on ${PROJECT_ID} — Cloud Build / Run will fail without it"
fi

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
# File-mounted secrets (Codex auth.json, Claude credentials.json) get a valid
# empty-JSON placeholder so the mount is stable before the first handoff.
for s in codex-auth claude-creds; do
  if ! secret_exists "$s"; then ensure_secret "$s" '{}'; else ensure_secret "$s"; fi
done

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
JOB_SECRETS+=",/secrets/claude/.credentials.json=claude-creds:latest"

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

# Persist a global config so `cloudy-handoff` targets this project from any repo.
CH_CONFIG="${HOME}/.config/cloudy-handoff/config.env"
if [ ! -f "$CH_CONFIG" ]; then
  mkdir -p "$(dirname "$CH_CONFIG")"
  cat > "$CH_CONFIG" <<CFG
# Written by cloudy-handoff bootstrap. Edit PROJECT_ID to target a different project.
export PROJECT_ID="${PROJECT_ID}"
export REGION="${REGION}"
export CLAUDE_AUTH_MODE="${CLAUDE_AUTH_MODE}"
export CODEX_AUTH_MODE="${CODEX_AUTH_MODE}"
CFG
  ok "wrote config → ${CH_CONFIG}"
else
  log "config already exists at ${CH_CONFIG} (left unchanged)"
fi

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
