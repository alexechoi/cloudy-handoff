#!/usr/bin/env bash
# scripts/lib/repo_state.sh — capture the local repo state for a handoff.
# Sourced by scripts/handoff.sh (local only). Relies on helpers from gcp.sh.

# Ensure we're inside a git work tree; sets REPO_URL / BASE_BRANCH / BASE_SHA.
detect_repo() {
  git rev-parse --is-inside-work-tree >/dev/null 2>&1 \
    || die "not inside a git repository — run /handoff from your project"

  local remote
  remote="$(git remote get-url origin 2>/dev/null)" \
    || die "no 'origin' remote — the cloud job needs a remote to clone and push to"
  REPO_URL="$(normalize_git_url "$remote")"

  BASE_BRANCH="$(git rev-parse --abbrev-ref HEAD)"
  [ "$BASE_BRANCH" != "HEAD" ] || die "detached HEAD — check out a branch before handoff"
  BASE_SHA="$(git rev-parse HEAD)"
  export REPO_URL BASE_BRANCH BASE_SHA
}

# Convert git@github.com:owner/repo(.git) → https://github.com/owner/repo.git
# Leaves https:// URLs unchanged (minus a normalized .git suffix).
normalize_git_url() {
  local u="$1"
  case "$u" in
    git@*:*)
      u="https://${u#git@}"
      u="${u/:/\/}"
      ;;
    ssh://git@*)
      u="https://${u#ssh://git@}"
      ;;
  esac
  [[ "$u" == *.git ]] || u="${u}.git"
  printf '%s' "$u"
}

# Generate a session id: <timestamp>-<shortsha>-<rand>
gen_session_id() {
  local ts sha rnd
  ts="$(date -u +%Y%m%d-%H%M%S)"
  sha="$(git rev-parse --short HEAD 2>/dev/null || echo nogit)"
  rnd="$( (openssl rand -hex 2 2>/dev/null) || printf '%04x' "$RANDOM")"
  printf '%s-%s-%s' "$ts" "$sha" "$rnd"
}

# Bundle uncommitted work (tracked diff vs HEAD + untracked files) into <dir>.
# Non-destructive: never touches the working tree or index.
# Prints "1" if there was anything to bundle, "0" otherwise.
capture_uncommitted() {
  local dir="$1" had=0
  git diff HEAD > "${dir}/uncommitted.patch" 2>/dev/null || true
  [ -s "${dir}/uncommitted.patch" ] && had=1

  git ls-files --others --exclude-standard -z > "${dir}/untracked.nul" 2>/dev/null || true
  if [ -s "${dir}/untracked.nul" ]; then
    tar czf "${dir}/untracked.tar.gz" --null -T "${dir}/untracked.nul" 2>/dev/null && had=1
  fi
  rm -f "${dir}/untracked.nul"
  printf '%s' "$had"
}
