#!/usr/bin/env bash
# scripts/lib/gcp.sh — shared helpers for cloudy-handoff.
#
# Sourced by scripts/bootstrap.sh, scripts/handoff.sh (locally) and by
# docker/entrypoint.sh (inside the Cloud Run Job). Everything here must work in
# BOTH places, so credential/token acquisition auto-detects the environment.
#
# Requires: bash, curl, jq, and (locally) the gcloud CLI.

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
# shellcheck disable=SC2015  # C is just `true`; no if-then-else trap here
_ch_color() { [ -t 2 ] && printf '\033[%sm' "$1" >&2 || true; }
log()  { _ch_color '0;36'; printf '›  %s\n' "$*" >&2; _ch_color '0'; }
ok()   { _ch_color '0;32'; printf '✓  %s\n' "$*" >&2; _ch_color '0'; }
warn() { _ch_color '0;33'; printf '⚠  %s\n' "$*" >&2; _ch_color '0'; }
die()  { _ch_color '0;31'; printf '✗  %s\n' "$*" >&2; _ch_color '0'; exit 1; }

require_cmd() {
  local missing=0 c
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || { warn "missing required command: $c"; missing=1; }
  done
  [ "$missing" -eq 0 ] || die "install the missing commands above and retry"
}

# ---------------------------------------------------------------------------
# Config loading
# ---------------------------------------------------------------------------
# Load config from (first that exists): $CLOUDY_HANDOFF_CONFIG,
# ./.cloudy-handoff.env, ~/.config/cloudy-handoff/config.env. Then apply
# defaults for anything still unset.
load_config() {
  local f
  for f in "${CLOUDY_HANDOFF_CONFIG:-}" \
           "$(pwd)/.cloudy-handoff.env" \
           "${HOME}/.config/cloudy-handoff/config.env"; do
    if [ -n "$f" ] && [ -f "$f" ]; then
      # shellcheck disable=SC1090
      . "$f"
      log "loaded config: $f"
      break
    fi
  done

  # PROJECT_ID falls back to the active gcloud project (local only).
  if [ -z "${PROJECT_ID:-}" ] && command -v gcloud >/dev/null 2>&1; then
    PROJECT_ID="$(gcloud config get-value project 2>/dev/null)"
    [ "$PROJECT_ID" = "(unset)" ] && PROJECT_ID=""
  fi
  # In-container, PROJECT_ID comes from the metadata server if unset.
  if [ -z "${PROJECT_ID:-}" ] && _on_cloud_run; then
    PROJECT_ID="$(_metadata "project/project-id" || true)"
  fi

  : "${REGION:=us-central1}"
  : "${JOB_NAME:=cloudy-handoff}"
  : "${AR_REPO:=cloudy-handoff}"
  : "${SA_NAME:=cloudy-handoff}"
  : "${BUCKET:=${PROJECT_ID}-cloudy-handoff}"
  : "${FIRESTORE_DATABASE:=(default)}"
  : "${CPU:=2}"
  : "${MEMORY:=4Gi}"
  : "${TASK_TIMEOUT:=14400s}"
  : "${MAX_HOURS:=3.5}"
  : "${CLAUDE_AUTH_MODE:=subscription}"
  : "${CODEX_AUTH_MODE:=subscription}"

  SA_EMAIL="${SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"
  if [ -z "${IMAGE:-}" ]; then
    IMAGE="${REGION}-docker.pkg.dev/${PROJECT_ID}/${AR_REPO}/${JOB_NAME}:latest"
  fi
  export PROJECT_ID REGION JOB_NAME AR_REPO SA_NAME SA_EMAIL BUCKET \
         FIRESTORE_DATABASE CPU MEMORY TASK_TIMEOUT MAX_HOURS IMAGE \
         CLAUDE_AUTH_MODE CODEX_AUTH_MODE

  [ -n "$PROJECT_ID" ] || die "PROJECT_ID is not set (run 'gcloud config set project <id>' or edit .cloudy-handoff.env)"
}

# ---------------------------------------------------------------------------
# Environment detection + tokens
# ---------------------------------------------------------------------------
_on_cloud_run() { [ -n "${CLOUD_RUN_JOB:-}" ] || [ -n "${K_SERVICE:-}" ]; }

_metadata() {
  curl -sf -H "Metadata-Flavor: Google" \
    "http://metadata.google.internal/computeMetadata/v1/${1}"
}

# An OAuth2 access token for the current identity. Uses the metadata server
# inside Cloud Run, gcloud locally.
gcp_access_token() {
  if _on_cloud_run; then
    _metadata "instance/service-accounts/default/token" | jq -r '.access_token'
  else
    gcloud auth print-access-token 2>/dev/null
  fi
}

# ---------------------------------------------------------------------------
# Provisioning helpers (idempotent). Local-only; use the gcloud CLI.
# ---------------------------------------------------------------------------
# create_project <project-id> [billing-account-id]
create_project() {
  local pid="$1" billing="${2:-}"
  if gcloud projects describe "$pid" >/dev/null 2>&1; then
    ok "project ${pid} already exists"
  else
    log "creating project ${pid}"
    gcloud projects create "$pid" --name "$pid" \
      || die "could not create project ${pid} (id may be taken globally, or you lack createProject on the org/folder)"
    ok "project created"
  fi
  if [ -n "$billing" ]; then
    if gcloud beta billing projects link "$pid" --billing-account "$billing" >/dev/null 2>&1; then
      ok "linked billing account ${billing}"
    else
      warn "could not link billing ${billing} — enable billing on ${pid} manually before continuing"
    fi
  else
    warn "no billing account chosen — pass --billing-account <id> or link billing manually"
  fi
}

ensure_apis() {
  log "enabling APIs (idempotent): $*"
  gcloud services enable "$@" --project "$PROJECT_ID" -q
}

ensure_bucket() {
  if gcloud storage buckets describe "gs://${BUCKET}" --project "$PROJECT_ID" >/dev/null 2>&1; then
    ok "bucket gs://${BUCKET} exists"
  else
    log "creating bucket gs://${BUCKET}"
    gcloud storage buckets create "gs://${BUCKET}" \
      --project "$PROJECT_ID" --location "$REGION" --uniform-bucket-level-access
    ok "bucket created"
  fi
}

ensure_firestore() {
  if gcloud firestore databases describe --database="$FIRESTORE_DATABASE" \
       --project "$PROJECT_ID" >/dev/null 2>&1; then
    ok "firestore database ${FIRESTORE_DATABASE} exists"
  else
    log "creating firestore database (native mode) in ${REGION}"
    gcloud firestore databases create \
      --database="$FIRESTORE_DATABASE" \
      --location="$REGION" --type=firestore-native \
      --project "$PROJECT_ID"
    ok "firestore database created"
  fi
}

ensure_ar_repo() {
  if gcloud artifacts repositories describe "$AR_REPO" \
       --location "$REGION" --project "$PROJECT_ID" >/dev/null 2>&1; then
    ok "artifact registry repo ${AR_REPO} exists"
  else
    log "creating artifact registry repo ${AR_REPO}"
    gcloud artifacts repositories create "$AR_REPO" \
      --repository-format=docker --location "$REGION" --project "$PROJECT_ID"
    ok "artifact registry repo created"
  fi
}

ensure_service_account() {
  if gcloud iam service-accounts describe "$SA_EMAIL" --project "$PROJECT_ID" >/dev/null 2>&1; then
    ok "service account ${SA_EMAIL} exists"
  else
    log "creating service account ${SA_NAME}"
    gcloud iam service-accounts create "$SA_NAME" \
      --display-name "cloudy-handoff job runner" --project "$PROJECT_ID"
    ok "service account created"
  fi
}

# Grant a project-level role to the runtime SA (idempotent).
grant_sa_role() {
  local role="$1"
  gcloud projects add-iam-policy-binding "$PROJECT_ID" \
    --member "serviceAccount:${SA_EMAIL}" --role "$role" \
    --condition=None -q >/dev/null
  ok "granted ${role} to runtime SA"
}

# ---------------------------------------------------------------------------
# Secret Manager (idempotent). Secrets live in the user's OWN project.
# ---------------------------------------------------------------------------
secret_exists() {
  gcloud secrets describe "$1" --project "$PROJECT_ID" >/dev/null 2>&1
}

# ensure_secret <name> [placeholder-value]
# Creates the secret (if missing) with least-privilege accessor for the runtime
# SA, and seeds a first version so the Job can mount :latest before the real
# value is pushed at handoff time.
ensure_secret() {
  local name="$1" placeholder="${2:-PLACEHOLDER}"
  if ! secret_exists "$name"; then
    log "creating secret ${name}"
    gcloud secrets create "$name" --replication-policy=automatic --project "$PROJECT_ID" -q
    printf '%s' "$placeholder" | gcloud secrets versions add "$name" \
      --data-file=- --project "$PROJECT_ID" -q >/dev/null
  fi
  # Grant the runtime SA read access to THIS secret only (least privilege).
  gcloud secrets add-iam-policy-binding "$name" \
    --member "serviceAccount:${SA_EMAIL}" \
    --role roles/secretmanager.secretAccessor \
    --project "$PROJECT_ID" -q >/dev/null
}

# add_secret_version <name> <file|->  (reads stdin when given "-")
add_secret_version() {
  local name="$1" src="$2"
  ensure_secret "$name" >/dev/null 2>&1 || true
  gcloud secrets versions add "$name" --data-file="$src" --project "$PROJECT_ID" -q >/dev/null
  ok "updated secret ${name}"
}

# ---------------------------------------------------------------------------
# GCS object helpers (work locally via gcloud; in-container via gcloud too)
# ---------------------------------------------------------------------------
gcs_up()   { gcloud storage cp "$1" "gs://${BUCKET}/$2" -q >/dev/null; }
gcs_down() { gcloud storage cp "gs://${BUCKET}/$1" "$2" -q >/dev/null; }
gcs_exists() { gcloud storage objects describe "gs://${BUCKET}/$1" >/dev/null 2>&1; }

# ---------------------------------------------------------------------------
# Firestore REST helpers. Document path is relative, e.g. "sessions/<id>".
# All fields are stored/read as stringValue (sufficient for v1 metadata).
# ---------------------------------------------------------------------------
_fs_doc_url() {
  printf 'https://firestore.googleapis.com/v1/projects/%s/databases/%s/documents/%s' \
    "$PROJECT_ID" "$FIRESTORE_DATABASE" "$1"
}

# fs_set <path> key=value [key=value ...]   (merge/patch, string fields)
fs_set() {
  local path="$1"; shift
  local token fields="" mask="" kv k v esc
  token="$(gcp_access_token)"
  [ -n "$token" ] || { warn "no access token; skipping firestore write"; return 0; }
  for kv in "$@"; do
    k="${kv%%=*}"; v="${kv#*=}"
    esc="$(printf '%s' "$v" | jq -Rs .)"
    fields="${fields:+$fields,}\"${k}\":{\"stringValue\":${esc}}"
    mask="${mask:+$mask&}updateMask.fieldPaths=${k}"
  done
  curl -sf -X PATCH \
    -H "Authorization: Bearer ${token}" \
    -H "Content-Type: application/json" \
    "$(_fs_doc_url "$path")?${mask}" \
    -d "{\"fields\":{${fields}}}" >/dev/null \
    || warn "firestore write to ${path} failed (non-fatal)"
}

# fs_get <path> <field>  -> prints the stringValue (empty if absent)
fs_get() {
  local path="$1" field="$2" token
  token="$(gcp_access_token)"
  [ -n "$token" ] || return 0
  curl -sf -H "Authorization: Bearer ${token}" "$(_fs_doc_url "$path")" 2>/dev/null \
    | jq -r ".fields[\"${field}\"].stringValue // empty" 2>/dev/null || true
}
