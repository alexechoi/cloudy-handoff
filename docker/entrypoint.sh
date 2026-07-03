#!/usr/bin/env bash
# docker/entrypoint.sh — Cloud Run Job entrypoint.
#
# Lifecycle: restore state → run the agent to completion → commit/push the
# handoff branch → open a PR → persist the transcript + logs → record status.
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
: "${RESUME:=0}"
: "${OPEN_PR:=1}"
BRANCH="handoff/${SESSION_ID}"
WORK=/workspace/repo
RUN_LOG="$(mktemp)"
TASK="$(printf '%s' "${TASK_B64:-}" | base64 -d 2>/dev/null || true)"
CLAUDE_ARGS="${CLAUDE_ARGS:---dangerously-skip-permissions --verbose}"
CODEX_ARGS="${CODEX_ARGS:---dangerously-bypass-approvals-and-sandbox --skip-git-repo-check}"

fail() { set_status "$SESSION_ID" failed error="$1" finishedAt="$(date -u +%Y-%m-%dT%H:%M:%SZ)"; exit 1; }

# Open (or find the existing) PR for BRANCH → BASE_BRANCH. Prints the URL.
open_pr() {
  local owner_repo owner title body payload resp url
  owner_repo="${REPO_URL#https://github.com/}"; owner_repo="${owner_repo%.git}"
  case "$owner_repo" in */*) ;; *) return 0 ;; esac
  owner="${owner_repo%%/*}"
  title="cloudy-handoff: $(printf '%s' "$TASK" | head -1 | cut -c1-60)"
  body="$(printf 'Automated cloudy-handoff run.\n\n- session: %s\n- agent: %s\n- base: %s\n\n### Task\n\n%s\n' \
    "$SESSION_ID" "$AGENT" "$BASE_BRANCH" "$TASK")"
  payload="$(jq -n --arg t "$title" --arg h "$BRANCH" --arg b "$BASE_BRANCH" --arg body "$body" \
    '{title:$t, head:$h, base:$b, body:$body}')"
  resp="$(curl -sf -X POST \
    -H "Authorization: Bearer ${GIT_TOKEN}" -H "Accept: application/vnd.github+json" \
    "https://api.github.com/repos/${owner_repo}/pulls" -d "$payload" 2>/dev/null)"
  url="$(printf '%s' "$resp" | jq -r '.html_url // empty' 2>/dev/null)"
  if [ -z "$url" ]; then   # likely already open — look it up
    url="$(curl -sf -H "Authorization: Bearer ${GIT_TOKEN}" \
      "https://api.github.com/repos/${owner_repo}/pulls?head=${owner}:${BRANCH}&state=open" 2>/dev/null \
      | jq -r '.[0].html_url // empty' 2>/dev/null)"
  fi
  printf '%s' "$url"
}

# --- sanitize credential env: treat placeholders/empties as unset -----------
for v in ANTHROPIC_API_KEY OPENAI_API_KEY CLAUDE_CODE_OAUTH_TOKEN GIT_TOKEN; do
  val="${!v:-}"
  if [ -z "$val" ] || [ "$val" = "PLACEHOLDER" ]; then unset "$v"; fi
done

# --- git identity + GitHub credential helper --------------------------------
git config --global user.name  "cloudy-handoff"
git config --global user.email "cloudy-handoff@users.noreply.github.com"
git config --global advice.detachedHead false
if [ -n "${GIT_TOKEN:-}" ]; then
  git config --global credential.helper store
  printf 'https://x-access-token:%s@github.com\n' "$GIT_TOKEN" > "${HOME}/.git-credentials"
  chmod 600 "${HOME}/.git-credentials"
fi

# --- codex auth.json file mount → ~/.codex/auth.json ------------------------
if [ -s /secrets/codex/auth.json ] && [ "$(cat /secrets/codex/auth.json)" != "{}" ]; then
  mkdir -p "${HOME}/.codex"
  cp /secrets/codex/auth.json "${HOME}/.codex/auth.json"
  chmod 600 "${HOME}/.codex/auth.json"
fi

# --- claude credentials file mount → ~/.claude/.credentials.json ------------
# (Full local creds incl. refresh token, so Claude Code refreshes itself.)
if [ -s /secrets/claude/.credentials.json ] && [ "$(cat /secrets/claude/.credentials.json)" != "{}" ]; then
  mkdir -p "${HOME}/.claude"
  cp /secrets/claude/.credentials.json "${HOME}/.claude/.credentials.json"
  chmod 600 "${HOME}/.claude/.credentials.json"
  log "restored Claude credentials from mount"
fi

# --- claude vertex mode -----------------------------------------------------
if [ "${CLAUDE_AUTH_MODE:-}" = "vertex" ] && [ "$AGENT" = "claude" ]; then
  export CLAUDE_CODE_USE_VERTEX=1
  export CLOUD_ML_REGION="${CLOUD_ML_REGION:-$REGION}"
  export ANTHROPIC_VERTEX_PROJECT_ID="${ANTHROPIC_VERTEX_PROJECT_ID:-$PROJECT_ID}"
  log "claude: using Vertex AI backend (service-account auth, no stored token)"
fi

set_status "$SESSION_ID" running startedAt="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# --- restore state ----------------------------------------------------------
: "${REPO_URL:?REPO_URL missing}"
: "${BASE_BRANCH:=main}"
log "cloning ${REPO_URL}"
git clone "$REPO_URL" "$WORK" 2>>"$RUN_LOG" || fail "git clone failed"
cd "$WORK"

if [ "$RESUME" = "1" ]; then
  git fetch origin "$BRANCH" 2>>"$RUN_LOG" && git checkout "$BRANCH" 2>>"$RUN_LOG" \
    || fail "could not check out existing branch ${BRANCH} for resume"
  # Restore the agent transcript so --resume has full context.
  if gcs_exists "sessions/${SESSION_ID}/transcript.tgz"; then
    gcs_down "sessions/${SESSION_ID}/transcript.tgz" /tmp/transcript.tgz
    tar xzf /tmp/transcript.tgz -C "${HOME}" 2>>"$RUN_LOG" || warn "transcript restore failed"
    log "restored session transcript"
  fi
else
  git checkout -b "$BRANCH" "origin/${BASE_BRANCH}" 2>>"$RUN_LOG" \
    || git checkout -b "$BRANCH" 2>>"$RUN_LOG" || fail "could not create branch ${BRANCH}"
  # Re-apply uncommitted work captured at handoff time.
  if gcs_exists "sessions/${SESSION_ID}/uncommitted.patch"; then
    gcs_down "sessions/${SESSION_ID}/uncommitted.patch" /tmp/uncommitted.patch
    [ -s /tmp/uncommitted.patch ] && git apply --whitespace=nowarn /tmp/uncommitted.patch 2>>"$RUN_LOG" \
      && log "applied uncommitted patch" || true
  fi
  if gcs_exists "sessions/${SESSION_ID}/untracked.tar.gz"; then
    gcs_down "sessions/${SESSION_ID}/untracked.tar.gz" /tmp/untracked.tar.gz
    tar xzf /tmp/untracked.tar.gz 2>>"$RUN_LOG" && log "restored untracked files" || true
  fi
fi

# --- run the agent to completion (with a wall-clock guard) ------------------
SECS="$(awk "BEGIN{printf \"%d\", ${MAX_HOURS:-3.5}*3600}")"
log "running ${AGENT} (timeout ${SECS}s): ${TASK:0:80}"
set +e
if [ "$AGENT" = "claude" ]; then
  CLAUDE_SID="$(fs_get "sessions/${SESSION_ID}" claudeSessionId)"
  if [ "$RESUME" = "1" ] && [ -n "$CLAUDE_SID" ]; then
    # shellcheck disable=SC2086
    timeout "${SECS}" claude --resume "$CLAUDE_SID" -p "$TASK" $CLAUDE_ARGS 2>&1 | tee -a "$RUN_LOG"
  else
    # shellcheck disable=SC2086
    timeout "${SECS}" claude -p "$TASK" $CLAUDE_ARGS 2>&1 | tee -a "$RUN_LOG"
  fi
  AGENT_RC="${PIPESTATUS[0]}"
else
  # shellcheck disable=SC2086
  timeout "${SECS}" codex exec $CODEX_ARGS "$TASK" 2>&1 | tee -a "$RUN_LOG"
  AGENT_RC="${PIPESTATUS[0]}"
fi
set -e
log "agent exited rc=${AGENT_RC}"

# --- capture the claude session id + project hash for future resumes --------
CLAUDE_META=""
if [ "$AGENT" = "claude" ] && [ -d "${HOME}/.claude/projects" ]; then
  latest="$(ls -t "${HOME}"/.claude/projects/*/*.jsonl 2>/dev/null | head -1 || true)"
  if [ -n "$latest" ]; then
    sid="$(basename "$latest" .jsonl)"
    phash="$(basename "$(dirname "$latest")")"
    CLAUDE_META="claudeSessionId=${sid} projectHash=${phash}"
  fi
fi

# --- commit + push + PR -----------------------------------------------------
PR_URL=""
git add -A
if git diff --cached --quiet; then
  log "no file changes to commit"
else
  summary="$(printf '%s' "$TASK" | head -1 | cut -c1-60)"
  git commit -q -m "cloudy-handoff: ${summary} (session ${SESSION_ID})" 2>>"$RUN_LOG" || true
fi
if [ -n "${GIT_TOKEN:-}" ]; then
  if git push -u origin "$BRANCH" 2>>"$RUN_LOG"; then
    log "pushed ${BRANCH}"
    [ "$OPEN_PR" = "1" ] && PR_URL="$(open_pr || true)"
  else
    warn "git push failed (see log)"
  fi
else
  warn "no GIT_TOKEN — skipping push/PR"
fi

# --- persist transcript + run log -------------------------------------------
TS="$(date -u +%Y%m%d-%H%M%S)"
gcs_up "$RUN_LOG" "sessions/${SESSION_ID}/run-${TS}.log" || true
TAR_PATHS=()
[ -d "${HOME}/.claude/projects" ] && TAR_PATHS+=(".claude/projects")
[ -d "${HOME}/.codex/sessions" ]  && TAR_PATHS+=(".codex/sessions")
if [ "${#TAR_PATHS[@]}" -gt 0 ]; then
  tar czf /tmp/transcript.tgz -C "${HOME}" "${TAR_PATHS[@]}" 2>/dev/null \
    && gcs_up /tmp/transcript.tgz "sessions/${SESSION_ID}/transcript.tgz" || true
fi

# --- final status -----------------------------------------------------------
FIN="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
if [ "$AGENT_RC" -eq 0 ]; then
  # shellcheck disable=SC2086
  set_status "$SESSION_ID" "done" branch="$BRANCH" prUrl="$PR_URL" finishedAt="$FIN" ${CLAUDE_META}
  ok "handoff complete — ${PR_URL:-$BRANCH}"
  exit 0
else
  # shellcheck disable=SC2086
  set_status "$SESSION_ID" failed branch="$BRANCH" prUrl="$PR_URL" agentRc="$AGENT_RC" finishedAt="$FIN" ${CLAUDE_META}
  fail "agent exited non-zero (rc=${AGENT_RC})"
fi
