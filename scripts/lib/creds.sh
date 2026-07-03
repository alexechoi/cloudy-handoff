#!/usr/bin/env bash
# scripts/lib/creds.sh — read local credentials and forward them to the user's
# OWN Secret Manager. Sourced by scripts/handoff.sh (local only).
#
# Design: forward only what the chosen agent needs, plus a git token so the job
# can clone/push/open PRs. Values are pushed as new secret versions; the Job
# already mounts them (bootstrap wired the mounts).

# ---- Claude -----------------------------------------------------------------
# Prints the full local Claude credentials JSON (~/.claude/.credentials.json or
# the macOS keychain), or nothing if unavailable. This JSON contains the refresh
# token, so forwarding it lets Claude Code refresh itself in the cloud.
_claude_credentials_json() {
  if [ -f "${HOME}/.claude/.credentials.json" ]; then
    cat "${HOME}/.claude/.credentials.json"
  elif command -v security >/dev/null 2>&1; then
    security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null || true
  fi
}

forward_claude_creds() {
  case "$CLAUDE_AUTH_MODE" in
    vertex)
      log "claude auth: vertex mode — no secret forwarded (job uses its service account)"
      return 0 ;;
    apikey)
      local key="${ANTHROPIC_API_KEY:-}"
      if [ -z "$key" ] && [ -t 0 ]; then
        read -r -s -p "Paste ANTHROPIC_API_KEY: " key </dev/tty; printf '\n' >&2
      fi
      [ -n "$key" ] || die "CLAUDE_AUTH_MODE=apikey but no ANTHROPIC_API_KEY found"
      printf '%s' "$key" | add_secret_version anthropic-api-key -
      log "claude auth: forwarded ANTHROPIC_API_KEY" ;;
    subscription|*)
      # Prefer a durable setup-token if the user exported one …
      if [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then
        printf '%s' "$CLAUDE_CODE_OAUTH_TOKEN" | add_secret_version claude-oauth-token -
        log "claude auth: forwarded CLAUDE_CODE_OAUTH_TOKEN (durable)"
        return 0
      fi
      # … otherwise forward the full local credentials JSON (incl. refresh token)
      # so Claude Code can refresh itself in the container.
      local json; json="$(_claude_credentials_json)"
      if [ -z "$json" ] || ! printf '%s' "$json" | jq -e . >/dev/null 2>&1; then
        [ -t 0 ] && { warn "no local Claude credentials found. Run 'claude setup-token', then:"; \
                      read -r -s -p "Paste CLAUDE_CODE_OAUTH_TOKEN: " tok </dev/tty; printf '\n' >&2; \
                      [ -n "$tok" ] && { printf '%s' "$tok" | add_secret_version claude-oauth-token -; \
                                         log "claude auth: forwarded pasted token"; return 0; }; }
        die "no Claude credentials found (run 'claude login' or 'claude setup-token')"
      fi
      printf '%s' "$json" | add_secret_version claude-creds -
      warn "forwarding your Claude subscription credentials (with refresh token) — see docs/SECURITY.md for the ToS note"
      log "claude auth: forwarded local Claude credentials (refreshable)" ;;
  esac
}

# ---- Codex ------------------------------------------------------------------
forward_codex_creds() {
  case "$CODEX_AUTH_MODE" in
    apikey)
      local key="${OPENAI_API_KEY:-}"
      if [ -z "$key" ] && [ -t 0 ]; then
        read -r -s -p "Paste OPENAI_API_KEY: " key </dev/tty; printf '\n' >&2
      fi
      [ -n "$key" ] || die "CODEX_AUTH_MODE=apikey but no OPENAI_API_KEY found"
      printf '%s' "$key" | add_secret_version openai-api-key -
      log "codex auth: forwarded OPENAI_API_KEY" ;;
    subscription|*)
      local f="${HOME}/.codex/auth.json"
      if [ -f "$f" ]; then
        add_secret_version codex-auth "$f"
        log "codex auth: forwarded ~/.codex/auth.json"
      elif [ -n "${OPENAI_API_KEY:-}" ]; then
        printf '%s' "$OPENAI_API_KEY" | add_secret_version openai-api-key -
        warn "no ~/.codex/auth.json; forwarded OPENAI_API_KEY instead"
      else
        die "no Codex credentials found (run 'codex login' or set OPENAI_API_KEY)"
      fi ;;
  esac
}

# ---- Git --------------------------------------------------------------------
# Reads a GitHub token from the local environment (gh CLI, git-credentials, or
# GITHUB_TOKEN) and forwards it so the job can clone/push/open PRs.
_local_git_token() {
  if [ -n "${GITHUB_TOKEN:-}" ]; then printf '%s' "$GITHUB_TOKEN"; return; fi
  if [ -n "${GH_TOKEN:-}" ]; then printf '%s' "$GH_TOKEN"; return; fi
  if command -v gh >/dev/null 2>&1; then
    gh auth token 2>/dev/null && return
  fi
  if [ -f "${HOME}/.git-credentials" ]; then
    # Extract the token from a https://<user>:<token>@github.com line.
    grep -m1 '@github.com' "${HOME}/.git-credentials" 2>/dev/null \
      | sed -E 's#https://[^:]*:([^@]+)@github.com.*#\1#' && return
  fi
}

forward_git_creds() {
  local token; token="$(_local_git_token || true)"
  if [ -z "$token" ] && [ -t 0 ]; then
    warn "no GitHub token found (gh/git-credentials/GITHUB_TOKEN)."
    read -r -s -p "Paste a GitHub token (contents+PR write), or leave blank to skip: " token </dev/tty
    printf '\n' >&2
  fi
  if [ -z "$token" ]; then
    warn "no git token forwarded — the job can't push results or open a PR"
    return 0
  fi
  printf '%s' "$token" | add_secret_version git-token -
  log "git auth: forwarded GitHub token"
}
