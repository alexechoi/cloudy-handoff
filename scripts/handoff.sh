#!/usr/bin/env bash
# scripts/handoff.sh — local trigger. Captures repo state, forwards credentials
# to your Secret Manager, queues the task, and launches the Cloud Run Job.
#
#   scripts/handoff.sh "add retry logic to the uploader and write tests"
#   scripts/handoff.sh --agent codex "port the parser to rust"
#   scripts/handoff.sh --resume <id> "now also update the changelog"
#   scripts/handoff.sh --cancel <id>        # stop a running session
#   scripts/handoff.sh --dry-run "…"        # print the plan, spend nothing
#
# Follow-ups (--resume) are QUEUED per session: if a run is already active it
# picks them up after its current turn (same branch/PR); otherwise a new runner
# starts and drains the queue. So you can fire follow-ups any time.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/gcp.sh
. "${HERE}/lib/gcp.sh"
# shellcheck source=scripts/lib/repo_state.sh
. "${HERE}/lib/repo_state.sh"
# shellcheck source=scripts/lib/creds.sh
. "${HERE}/lib/creds.sh"

AGENT="claude"; RESUME_ID=""; CANCEL_ID=""; OPEN_PR="1"; DRY_RUN=0; TASK=""

while [ $# -gt 0 ]; do
  case "$1" in
    --agent) AGENT="$2"; shift 2 ;;
    --agent=*) AGENT="${1#*=}"; shift ;;
    --resume) RESUME_ID="$2"; shift 2 ;;
    --resume=*) RESUME_ID="${1#*=}"; shift ;;
    --cancel) CANCEL_ID="$2"; shift 2 ;;
    --cancel=*) CANCEL_ID="${1#*=}"; shift ;;
    --no-pr) OPEN_PR="0"; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//' | sed '/^!/d'; exit 0 ;;
    --) shift; TASK="$*"; break ;;
    -*) die "unknown flag: $1" ;;
    *) TASK="${TASK:+$TASK }$1"; shift ;;
  esac
done

case "$AGENT" in claude|codex) ;; *) die "unknown --agent '$AGENT' (want claude|codex)";; esac
require_cmd gcloud curl jq git base64
load_config
gcloud auth print-access-token >/dev/null 2>&1 || die "gcloud is not authenticated — run 'gcloud auth login'"

# --- cancel -----------------------------------------------------------------
if [ -n "$CANCEL_ID" ]; then
  exec_name="$(fs_get "sessions/${CANCEL_ID}" currentExecution)"
  [ -n "$exec_name" ] || die "no recorded execution for session ${CANCEL_ID}"
  log "cancelling execution ${exec_name}…"
  gcloud run jobs executions cancel "$exec_name" --region "$REGION" --project "$PROJECT_ID" -q >/dev/null 2>&1 \
    || die "cancel failed (it may have already finished)"
  fs_set "sessions/${CANCEL_ID}" status=cancelled
  ok "cancelled session ${CANCEL_ID}"
  exit 0
fi

# A follow-up with no extra text just continues the prior session.
if [ -z "$TASK" ]; then
  if [ -n "$RESUME_ID" ]; then TASK="Continue where you left off and finish the task."
  else die "no task given. Usage: handoff.sh [--agent claude|codex] [--resume <id>] \"<task>\""; fi
fi

gcloud run jobs describe "$JOB_NAME" --region "$REGION" --project "$PROJECT_ID" >/dev/null 2>&1 \
  || die "Cloud Run Job '$JOB_NAME' not found in ${PROJECT_ID} — run 'cloudy-handoff init' first"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
CREATED_BY="$(gcloud config get-value account 2>/dev/null || echo unknown)"
NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
IS_RESUME=0

if [ -n "$RESUME_ID" ]; then
  # ---- follow-up: reuse the existing session/branch ----------------------
  IS_RESUME=1
  SESSION_ID="$RESUME_ID"
  a="$(fs_get "sessions/${SESSION_ID}" agent)"; [ -n "$a" ] && AGENT="$a"
  REPO_URL="$(fs_get "sessions/${SESSION_ID}" repoUrl)"
  BASE_BRANCH="$(fs_get "sessions/${SESSION_ID}" baseBranch)"
  [ -n "$REPO_URL" ] || die "no Firestore record for session '$SESSION_ID' — cannot resume"
  fs_set "sessions/${SESSION_ID}" lastTask="$TASK" updatedAt="$NOW"
else
  # ---- fresh handoff -----------------------------------------------------
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

# --- queue the instruction --------------------------------------------------
queue_append "sessions/${SESSION_ID}" "$TASK"

# --- decide whether to launch a runner or ride the active one ---------------
LAUNCH=1
if [ "$IS_RESUME" -eq 1 ] && runner_alive "sessions/${SESSION_ID}"; then LAUNCH=0; fi

if [ "$DRY_RUN" -eq 1 ]; then
  warn "dry-run — session ${SESSION_ID}, agent ${AGENT}, launch=${LAUNCH} (0=queued onto active run)"
  exit 0
fi

if [ "$LAUNCH" -eq 0 ]; then
  n="$(queue_len "sessions/${SESSION_ID}")"
  cat >&2 <<EOF

────────────────────────────────────────────────────────────
✓ queued onto the running session ${SESSION_ID} (${n} pending)
  The active run will apply it after its current turn, on the same PR.
  Cancel the run:  cloudy-handoff --cancel ${SESSION_ID}
────────────────────────────────────────────────────────────
EOF
  exit 0
fi

# --- credentials (only when we actually start a runner) ---------------------
if [ "$AGENT" = "claude" ]; then forward_claude_creds; else forward_codex_creds; fi
forward_git_creds

# --- launch -----------------------------------------------------------------
ENV_PAIRS="SESSION_ID=${SESSION_ID},AGENT=${AGENT},OPEN_PR=${OPEN_PR}"
ENV_PAIRS+=",REPO_URL=${REPO_URL},BASE_BRANCH=${BASE_BRANCH},CLAUDE_AUTH_MODE=${CLAUDE_AUTH_MODE}"
log "launching Cloud Run Job…"
EXEC_NAME="$(gcloud run jobs execute "$JOB_NAME" \
  --region "$REGION" --project "$PROJECT_ID" \
  --update-env-vars "^@@^${ENV_PAIRS//,/@@}" \
  --async --format='value(metadata.name)' 2>/dev/null)"
fs_set "sessions/${SESSION_ID}" status=launched currentExecution="${EXEC_NAME}"

cat >&2 <<EOF

────────────────────────────────────────────────────────────
✓ handed off — session ${SESSION_ID}
  agent   : ${AGENT}
  branch  : handoff/${SESSION_ID}   (PR opens when it finishes)

  follow up any time (queues onto this run):
    cloudy-handoff resume ${SESSION_ID} "more instructions"
  cancel:
    cloudy-handoff --cancel ${SESSION_ID}
  logs:
    gcloud beta run jobs logs tail ${JOB_NAME} --region ${REGION}
────────────────────────────────────────────────────────────
EOF
