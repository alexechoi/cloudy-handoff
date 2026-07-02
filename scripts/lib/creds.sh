#!/usr/bin/env bash
# scripts/lib/creds.sh — read local credentials and forward them to the user's
# OWN Secret Manager. Sourced by scripts/handoff.sh (local only).
#
# Design: forward only what the chosen agent needs, plus a git token so the job
# can clone/push/open PRs. Values are pushed as new secret versions; the Job
# already mounts them (bootstrap wired the mounts).

# ---- Claude -----------------------------------------------------------------
# Reads ~/.claude/.credentials.json or the macOS keychain and prints the
# access token, or nothing if unavailable.
_claude_token_from_store() {
  local json=""
  if [ -f "${HOME}/.claude/.credentials.json" ]; then
    json="$(cat "${HOME}/.claude/.credentials.json")"
  elif command -v security >/dev/null 2>&1; then
    json="$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null || true)"
  fi
  [ -n "$json" ] || return 0
  printf '%s' "$json" | jq -r '.claudeAiOauth.accessToken // .accessToken // empty' 2>/dev/null || true
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
      local token="${CLAUDE_CODE_OAUTH_TOKEN:-}"
      if [ -z "$token" ]; then
        token="$(_claude_token_from_store)"
        [ -n "$token" ] && warn "using short-lived token from local Claude creds; for a durable 1-year token run 'claude setup-token' and export CLAUDE_CODE_OAUTH_TOKEN"
      fi
      if [ -z "$token" ] && [ -t 0 ]; then
        warn "no Claude token found. Run 'claude setup-token' in another terminal, then:"
        read -r -s -p "Paste CLAUDE_CODE_OAUTH_TOKEN: " token </dev/tty; printf '\n' >&2
      fi
      [ -n "$token" ] || die "no Claude credentials found (set CLAUDE_CODE_OAUTH_TOKEN or run 'claude setup-token')"
      printf '%s' "$token" | add_secret_version claude-oauth-token -
      log "claude auth: forwarded subscription OAuth token" ;;
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
