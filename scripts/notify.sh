#!/usr/bin/env bash
# scripts/notify.sh — tiny status helper, copied into the image and sourced by
# the entrypoint. Writes the session status to Firestore and echoes a log line.
# (Kept separate so a future Telegram/web control-plane can hook the same call.)

# set_status <session_id> <status> [key=value ...]
set_status() {
  local sid="$1" status="$2"; shift 2
  log "status: ${status} (session ${sid})"
  fs_set "sessions/${sid}" status="$status" "$@"
}
