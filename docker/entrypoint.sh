#!/usr/bin/env bash
# docker/entrypoint.sh — Cloud Run Job entrypoint (queue-draining runner).
#
# One runner per session drains the session's instruction queue: for each queued
# task it runs the agent, commits, pushes handoff/<id>, updates the PR, and
# persists the transcript — then loops until the queue is empty. Follow-ups
# appended while it runs are picked up after the current turn.
set -uo pipefail

CLOUDY_HANDOFF_HOME="${CLOUDY_HANDOFF_HOME:-/opt/cloudy-handoff}"
# shellcheck source=scripts/lib/gcp.sh
. "${CLOUDY_HANDOFF_HOME}/scripts/lib/gcp.sh"
# shellcheck source=scripts/notify.sh
. "${CLOUDY_HANDOFF_HOME}/scripts/notify.sh"

load_config
gcloud config set project "$PROJECT_ID" >/dev/null 2>&1 || true

: "${SESSION_ID:?SESSION_ID is required}"
: "${AGENT:=claude}"
: "${OPEN_PR:=1}"
BRANCH="handoff/${SESSION_ID}"
WORK=/workspace/repo
RUN_LOG="$(mktemp)"
SESS="sessions/${SESSION_ID}"
EXEC_NAME="${CLOUD_RUN_EXECUTION:-}"
CLAUDE_ARGS="${CLAUDE_ARGS:---dangerously-skip-permissions --verbose}"
CODEX_ARGS="${CODEX_ARGS:---dangerously-bypass-approvals-and-sandbox --skip-git-repo-check}"
PR_URL=""
CLAUDE_SID=""

mark_idle() { fs_set "$SESS" runState=idle currentExecution=""; }
fail() { set_status "$SESSION_ID" failed error="$1" finishedAt="$(date -u +%Y-%m-%dT%H:%M:%SZ)"; mark_idle; exit 1; }

# Open (or find) the PR for BRANCH → BASE_BRANCH. Prints the URL. Uses the
# session's original task for the title.
open_pr() {
  local owner_repo owner title body payload resp url
  owner_repo="${REPO_URL#https://github.com/}"; owner_repo="${owner_repo%.git}"
  case "$owner_repo" in */*) ;; *) return 0 ;; esac
  owner="${owner_repo%%/*}"
  title="cloudy-handoff: $(printf '%s' "$TITLE_TASK" | head -1 | cut -c1-60)"
  body="$(printf 'Automated cloudy-handoff run.\n\n- session: %s\n- agent: %s\n- base: %s\n' \
    "$SESSION_ID" "$AGENT" "$BASE_BRANCH")"
  payload="$(jq -n --arg t "$title" --arg h "$BRANCH" --arg b "$BASE_BRANCH" --arg body "$body" \
    '{title:$t, head:$h, base:$b, body:$body}')"
  resp="$(curl -sf -X POST -H "Authorization: Bearer ${GIT_TOKEN}" -H "Accept: application/vnd.github+json" \
    "https://api.github.com/repos/${owner_repo}/pulls" -d "$payload" 2>/dev/null)"
  url="$(printf '%s' "$resp" | jq -r '.html_url // empty' 2>/dev/null)"
  if [ -z "$url" ]; then
    url="$(curl -sf -H "Authorization: Bearer ${GIT_TOKEN}" \
      "https://api.github.com/repos/${owner_repo}/pulls?head=${owner}:${BRANCH}&state=open" 2>/dev/null \
      | jq -r '.[0].html_url // empty' 2>/dev/null)"
  fi
  printf '%s' "$url"
}

# --- credentials + git identity --------------------------------------------
for v in ANTHROPIC_API_KEY OPENAI_API_KEY CLAUDE_CODE_OAUTH_TOKEN GIT_TOKEN; do
  val="${!v:-}"; { [ -z "$val" ] || [ "$val" = "PLACEHOLDER" ]; } && unset "$v"
done
git config --global user.name  "cloudy-handoff"
git config --global user.email "cloudy-handoff@users.noreply.github.com"
git config --global advice.detachedHead false
if [ -n "${GIT_TOKEN:-}" ]; then
  git config --global credential.helper store
  printf 'https://x-access-token:%s@github.com\n' "$GIT_TOKEN" > "${HOME}/.git-credentials"
  chmod 600 "${HOME}/.git-credentials"
fi
if [ -s /secrets/codex/auth.json ] && [ "$(cat /secrets/codex/auth.json)" != "{}" ]; then
  mkdir -p "${HOME}/.codex"; cp /secrets/codex/auth.json "${HOME}/.codex/auth.json"; chmod 600 "${HOME}/.codex/auth.json"
fi
if [ -s /secrets/claude/.credentials.json ] && [ "$(cat /secrets/claude/.credentials.json)" != "{}" ]; then
  mkdir -p "${HOME}/.claude"; cp /secrets/claude/.credentials.json "${HOME}/.claude/.credentials.json"
  chmod 600 "${HOME}/.claude/.credentials.json"; log "restored Claude credentials from mount"
fi
if [ "${CLAUDE_AUTH_MODE:-}" = "vertex" ] && [ "$AGENT" = "claude" ]; then
  export CLAUDE_CODE_USE_VERTEX=1 CLOUD_ML_REGION="${CLOUD_ML_REGION:-$REGION}" \
         ANTHROPIC_VERTEX_PROJECT_ID="${ANTHROPIC_VERTEX_PROJECT_ID:-$PROJECT_ID}"
  log "claude: using Vertex AI backend"
fi

# --- claim the runner slot + gather session facts ---------------------------
: "${REPO_URL:?REPO_URL missing}"; : "${BASE_BRANCH:=main}"
TITLE_TASK="$(fs_get "$SESS" task)"; [ -n "$TITLE_TASK" ] || TITLE_TASK="cloudy-handoff run"
fs_set "$SESS" currentExecution="${EXEC_NAME}" runState=running startedAt="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
set_status "$SESSION_ID" running

# --- repo setup: check out (resume) or create (fresh) the branch ------------
log "cloning ${REPO_URL}"
git clone "$REPO_URL" "$WORK" 2>>"$RUN_LOG" || fail "git clone failed"
cd "$WORK"
if git ls-remote --exit-code --heads origin "$BRANCH" >/dev/null 2>&1; then
  git fetch origin "$BRANCH" 2>>"$RUN_LOG" && git checkout "$BRANCH" 2>>"$RUN_LOG" || fail "checkout ${BRANCH} failed"
  log "resuming existing branch ${BRANCH}"
else
  git checkout -b "$BRANCH" "origin/${BASE_BRANCH}" 2>>"$RUN_LOG" || git checkout -b "$BRANCH" 2>>"$RUN_LOG" \
    || fail "could not create branch ${BRANCH}"
  if gcs_exists "${SESS}/uncommitted.patch"; then
    gcs_down "${SESS}/uncommitted.patch" /tmp/uncommitted.patch
    [ -s /tmp/uncommitted.patch ] && git apply --whitespace=nowarn /tmp/uncommitted.patch 2>>"$RUN_LOG" && log "applied uncommitted patch" || true
  fi
  if gcs_exists "${SESS}/untracked.tar.gz"; then
    gcs_down "${SESS}/untracked.tar.gz" /tmp/untracked.tar.gz
    tar xzf /tmp/untracked.tar.gz 2>>"$RUN_LOG" && log "restored untracked files" || true
  fi
fi
# Restore any prior transcript so claude --resume has full context.
if gcs_exists "${SESS}/transcript.tgz"; then
  gcs_down "${SESS}/transcript.tgz" /tmp/transcript.tgz
  tar xzf /tmp/transcript.tgz -C "${HOME}" 2>>"$RUN_LOG" && log "restored transcript" || true
fi
CLAUDE_SID="$(fs_get "$SESS" claudeSessionId)"

SECS="$(awk "BEGIN{printf \"%d\", ${MAX_HOURS:-3.5}*3600}")"

run_turn() { # <task> → returns agent rc  (script baseline has no errexit)
  local task="$1" rc latest
  log "running ${AGENT} (timeout ${SECS}s): ${task:0:80}"
  if [ "$AGENT" = "claude" ]; then
    if [ -n "$CLAUDE_SID" ]; then
      # shellcheck disable=SC2086
      timeout "${SECS}" claude --resume "$CLAUDE_SID" -p "$task" $CLAUDE_ARGS 2>&1 | tee -a "$RUN_LOG"
    else
      # shellcheck disable=SC2086
      timeout "${SECS}" claude -p "$task" $CLAUDE_ARGS 2>&1 | tee -a "$RUN_LOG"
    fi
    rc="${PIPESTATUS[0]}"
    latest="$(ls -t "${HOME}"/.claude/projects/*/*.jsonl 2>/dev/null | head -1 || true)"
    [ -n "$latest" ] && CLAUDE_SID="$(basename "$latest" .jsonl)"
  else
    # shellcheck disable=SC2086
    timeout "${SECS}" codex exec $CODEX_ARGS "$task" 2>&1 | tee -a "$RUN_LOG"
    rc="${PIPESTATUS[0]}"
  fi
  return "$rc"
}

commit_push() { # <task>
  local task="$1"
  git add -A
  if git diff --cached --quiet; then
    log "no file changes this turn"
  else
    git commit -q -m "cloudy-handoff: $(printf '%s' "$task" | head -1 | cut -c1-60) (session ${SESSION_ID})" 2>>"$RUN_LOG" || true
  fi
  if [ -n "${GIT_TOKEN:-}" ]; then
    if git push -u origin "$BRANCH" 2>>"$RUN_LOG"; then
      log "pushed ${BRANCH}"
      [ "$OPEN_PR" = "1" ] && [ -z "$PR_URL" ] && PR_URL="$(open_pr || true)"
    else
      warn "git push failed (see log)"
    fi
  else
    warn "no GIT_TOKEN — skipping push/PR"
  fi
}

persist() {
  local ts; ts="$(date -u +%Y%m%d-%H%M%S)"
  gcs_up "$RUN_LOG" "${SESS}/run-${ts}.log" || true
  local paths=()
  [ -d "${HOME}/.claude/projects" ] && paths+=(".claude/projects")
  [ -d "${HOME}/.codex/sessions" ]  && paths+=(".codex/sessions")
  if [ "${#paths[@]}" -gt 0 ]; then
    tar czf /tmp/transcript.tgz -C "${HOME}" "${paths[@]}" 2>/dev/null \
      && gcs_up /tmp/transcript.tgz "${SESS}/transcript.tgz" || true
  fi
}

# --- drain loop -------------------------------------------------------------
OVERALL_RC=0; idle=0
while : ; do
  elem="$(queue_peek "$SESS")"
  if [ -z "$elem" ]; then
    idle=$((idle+1)); [ "$idle" -ge 2 ] && break   # one grace re-check for a late follow-up
    sleep 3; continue
  fi
  idle=0
  task="$(queue_decode "$elem")"
  set_status "$SESSION_ID" running currentTask="$task"
  run_turn "$task"; rc=$?
  log "turn rc=${rc}"
  commit_push "$task"
  [ -n "$CLAUDE_SID" ] && fs_set "$SESS" claudeSessionId="$CLAUDE_SID"
  persist
  queue_remove "$SESS" "$elem"
  if [ "$rc" -ne 0 ]; then OVERALL_RC="$rc"; break; fi
done

FIN="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
if [ "$OVERALL_RC" -eq 0 ]; then
  set_status "$SESSION_ID" "done" branch="$BRANCH" prUrl="$PR_URL" finishedAt="$FIN"
  mark_idle
  ok "session complete — ${PR_URL:-$BRANCH}"
  exit 0
else
  set_status "$SESSION_ID" failed branch="$BRANCH" prUrl="$PR_URL" agentRc="$OVERALL_RC" finishedAt="$FIN"
  mark_idle
  exit 1
fi
