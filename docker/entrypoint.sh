#!/usr/bin/env bash
# docker/entrypoint.sh — Cloud Run Job entrypoint (M1 stub).
#
# The full lifecycle (restore state → run agent → commit/push/PR → persist)
# lands in M2. This stub keeps the image buildable and lets bootstrap create a
# working Job; a stray execution simply reports its context and exits cleanly.
set -euo pipefail

CLOUDY_HANDOFF_HOME="${CLOUDY_HANDOFF_HOME:-/opt/cloudy-handoff}"
# shellcheck source=scripts/lib/gcp.sh
. "${CLOUDY_HANDOFF_HOME}/scripts/lib/gcp.sh"

load_config
log "cloudy-handoff entrypoint (stub)"
log "session=${SESSION_ID:-<none>} agent=${AGENT:-<none>} repo=${REPO_URL:-<none>}"
warn "entrypoint lifecycle not implemented yet (M2) — exiting 0"
exit 0
