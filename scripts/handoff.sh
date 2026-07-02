#!/usr/bin/env bash
# scripts/handoff.sh — local trigger. Captures repo state, forwards credentials
# to your Secret Manager, records the session in Firestore, and launches the
# Cloud Run Job.
#
#   scripts/handoff.sh "add retry logic to the uploader and write tests"
#   scripts/handoff.sh --agent codex "port the parser to rust"
#   scripts/handoff.sh --resume 20260702-… "now also update the changelog"
#   scripts/handoff.sh --dry-run "…"        # print the plan, spend nothing
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/gcp.sh
. "${HERE}/lib/gcp.sh"
# shellcheck source=scripts/lib/repo_state.sh
. "${HERE}/lib/repo_state.sh"
# shellcheck source=scripts/lib/creds.sh
. "${HERE}/lib/creds.sh"

AGENT="claude"
RESUME_ID=""
OPEN_PR="1"
DRY_RUN=0
TASK=""

while [ $# -gt 0 ]; do
  case "$1" in
    --agent) AGENT="$2"; shift 2 ;;
    --agent=*) AGENT="${1#*=}"; shift ;;
    --resume) RESUME_ID="$2"; shift 2 ;;
    --resume=*) RESUME_ID="${1#*=}"; shift ;;
    --no-pr) OPEN_PR="0"; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//' | sed '/^!/d'; exit 0 ;;
    --) shift; TASK="$*"; break ;;
    -*) die "unknown flag: $1" ;;
    *) TASK="${TASK:+$TASK }$1"; shift ;;
  esac
done

case "$AGENT" in claude|codex) ;; *) die "unknown --agent '$AGENT' (want claude|codex)";; esac
[ -n "$TASK" ] || die "no task given. Usage: handoff.sh [--agent claude|codex] [--resume <id>] \"<task>\""

require_cmd gcloud curl jq git base64
load_config

# --- preflight --------------------------------------------------------------
gcloud auth print-access-token >/dev/null 2>&1 || die "gcloud is not authenticated — run 'gcloud auth login'"
gcloud run jobs describe "$JOB_NAME" --region "$REGION" --project "$PROJECT_ID" >/dev/null 2>&1 \
  || die "Cloud Run Job '$JOB_NAME' not found — run scripts/bootstrap.sh first"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
CREATED_BY="$(gcloud config get-value account 2>/dev/null || echo unknown)"
NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

if [ -n "$RESUME_ID" ]; then
  # ---- follow-up run: reuse the existing session/branch -------------------
  SESSION_ID="$RESUME_ID"
  RESUME="1"
  local_agent="$(fs_get "sessions/${SESSION_ID}" agent)"
  [ -n "$local_agent" ] && AGENT="$local_agent"
  REPO_URL="$(fs_get "sessions/${SESSION_ID}" repoUrl)"
  BASE_BRANCH="$(fs_get "sessions/${SESSION_ID}" baseBranch)"
  [ -n "$REPO_URL" ] || die "no Firestore record for session '$SESSION_ID' — cannot resume"
  log "resuming session ${SESSION_ID} (agent=${AGENT}, repo=${REPO_URL})"
  fs_set "sessions/${SESSION_ID}" status=queued lastTask="$TASK" updatedAt="$NOW"
else
  # ---- fresh handoff ------------------------------------------------------
  RESUME="0"
  detect_repo
  SESSION_ID="$(gen_session_id)"
  log "session ${SESSION_ID} — repo=${REPO_URL} base=${BASE_BRANCH}@${BASE_SHA:0:8}"

  had_changes="$(capture_uncommitted "$TMP")"
  if [ "$had_changes" = "1" ]; then
    [ -f "${TMP}/uncommitted.patch" ] && gcs_up "${TMP}/uncommitted.patch" "sessions/${SESSION_ID}/uncommitted.patch"
    [ -f "${TMP}/untracked.tar.gz" ] && gcs_up "${TMP}/untracked.tar.gz" "sessions/${SESSION_ID}/untracked.tar.gz"
    log "uploaded uncommitted work"
  fi

  fs_set "sessions/${SESSION_ID}" \
    status=queued agent="$AGENT" repoUrl="$REPO_URL" \
    baseBranch="$BASE_BRANCH" baseSha="$BASE_SHA" \
    branch="handoff/${SESSION_ID}" task="$TASK" \
    createdBy="$CREATED_BY" createdAt="$NOW" hadUncommitted="$had_changes"
fi

# --- credentials ------------------------------------------------------------
if [ "$AGENT" = "claude" ]; then forward_claude_creds; else forward_codex_creds; fi
forward_git_creds

# --- launch -----------------------------------------------------------------
TASK_B64="$(printf '%s' "$TASK" | base64 | tr -d '\n')"
ENV_PAIRS="SESSION_ID=${SESSION_ID},AGENT=${AGENT},RESUME=${RESUME},OPEN_PR=${OPEN_PR},TASK_B64=${TASK_B64}"
ENV_PAIRS+=",REPO_URL=${REPO_URL},BASE_BRANCH=${BASE_BRANCH},CLAUDE_AUTH_MODE=${CLAUDE_AUTH_MODE}"

if [ "$DRY_RUN" -eq 1 ]; then
  warn "dry-run — would execute:"
  printf '  gcloud run jobs execute %s --region %s --project %s \\\n' "$JOB_NAME" "$REGION" "$PROJECT_ID" >&2
  printf '    --update-env-vars %s --async\n' "$ENV_PAIRS" >&2
  exit 0
fi

log "launching Cloud Run Job…"
gcloud run jobs execute "$JOB_NAME" \
  --region "$REGION" --project "$PROJECT_ID" \
  --update-env-vars "^@@^${ENV_PAIRS//,/@@}" \
  --async

fs_set "sessions/${SESSION_ID}" status=launched

cat >&2 <<EOF

────────────────────────────────────────────────────────────
✓ handed off — session ${SESSION_ID}

  agent   : ${AGENT}
  branch  : handoff/${SESSION_ID}   (PR opens when it finishes)

  watch executions:
    gcloud run jobs executions list --job ${JOB_NAME} --region ${REGION}
  tail logs:
    gcloud beta run jobs logs tail ${JOB_NAME} --region ${REGION}
  follow up later:
    /handoff-followup ${SESSION_ID} "more instructions"
────────────────────────────────────────────────────────────
EOF
