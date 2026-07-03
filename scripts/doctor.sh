#!/usr/bin/env bash
# scripts/doctor.sh — check that everything cloudy-handoff needs is in place.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/gcp.sh
. "${HERE}/lib/gcp.sh"

problems=0
check() { # check "<label>" <cmd...>
  local label="$1"; shift
  if "$@" >/dev/null 2>&1; then ok "$label"; else warn "$label — MISSING"; problems=$((problems+1)); fi
}

log "checking prerequisites…"
for c in gcloud git jq curl base64; do check "$c installed" command -v "$c"; done

if command -v gcloud >/dev/null 2>&1; then
  if gcloud auth print-access-token >/dev/null 2>&1; then ok "gcloud authenticated ($(gcloud config get-value account 2>/dev/null))"
  else warn "gcloud not authenticated — run 'gcloud auth login'"; problems=$((problems+1)); fi
fi

# Load config (won't die here; report instead).
if load_config 2>/dev/null; then
  ok "project resolved: ${PROJECT_ID} (region ${REGION})"
  if gcloud run jobs describe "$JOB_NAME" --region "$REGION" --project "$PROJECT_ID" >/dev/null 2>&1; then
    ok "Cloud Run Job '${JOB_NAME}' exists — ready to /handoff"
  else
    warn "Job '${JOB_NAME}' not found in ${PROJECT_ID} — run 'cloudy-handoff init'"
  fi
else
  warn "no project configured — run 'cloudy-handoff init' (or set PROJECT_ID)"
  problems=$((problems+1))
fi

# Agent CLIs / creds (informational; only one is needed).
command -v claude >/dev/null 2>&1 && ok "claude CLI present" || warn "claude CLI not found (needed only for local Claude handoffs)"
command -v codex  >/dev/null 2>&1 && ok "codex CLI present"  || warn "codex CLI not found (needed only for local Codex handoffs)"
command -v gh >/dev/null 2>&1 && gh auth token >/dev/null 2>&1 && ok "GitHub token available (gh)" || warn "no gh token — set GITHUB_TOKEN or run 'gh auth login' so the job can push/PR"

if [ "$problems" -eq 0 ]; then ok "all good."; else warn "${problems} issue(s) above."; fi
exit "$problems"
