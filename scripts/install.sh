#!/usr/bin/env bash
# scripts/install.sh — put the `cloudy-handoff` command on your PATH and install
# the /handoff slash commands for Claude Code and Codex.
#
#   ./scripts/install.sh                 # installs to ~/.local/bin + ~/.claude, ~/.codex
#   BIN_DIR=/usr/local/bin ./scripts/install.sh
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${HERE}/.." && pwd)"
BIN_DIR="${BIN_DIR:-${HOME}/.local/bin}"

mkdir -p "$BIN_DIR"
cat > "${BIN_DIR}/cloudy-handoff" <<EOF
#!/usr/bin/env bash
exec "${REPO_ROOT}/scripts/handoff.sh" "\$@"
EOF
chmod +x "${BIN_DIR}/cloudy-handoff"
echo "✓ installed ${BIN_DIR}/cloudy-handoff"

# Claude Code slash commands (personal scope).
if [ -d "${HOME}/.claude" ] || command -v claude >/dev/null 2>&1; then
  mkdir -p "${HOME}/.claude/commands"
  cp "${REPO_ROOT}/.claude/commands/"*.md "${HOME}/.claude/commands/" 2>/dev/null || true
  echo "✓ installed Claude slash commands → ~/.claude/commands/"
fi

# Codex prompts (invoked the same way, /handoff).
if [ -d "${HOME}/.codex" ] || command -v codex >/dev/null 2>&1; then
  mkdir -p "${HOME}/.codex/prompts"
  cp "${REPO_ROOT}/.claude/commands/handoff.md"          "${HOME}/.codex/prompts/handoff.md" 2>/dev/null || true
  cp "${REPO_ROOT}/.claude/commands/handoff-followup.md" "${HOME}/.codex/prompts/handoff-followup.md" 2>/dev/null || true
  echo "✓ installed Codex prompts → ~/.codex/prompts/"
fi

case ":${PATH}:" in
  *":${BIN_DIR}:"*) ;;
  *) echo "⚠  add ${BIN_DIR} to your PATH:  export PATH=\"${BIN_DIR}:\$PATH\"" ;;
esac
echo "Done. Try:  /handoff \"your task\"   (or: cloudy-handoff \"your task\")"
