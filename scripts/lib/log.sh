#!/usr/bin/env bash
# Logging + did-it-actually-work checks.
# Depends on: lib/common.sh

notif_log_success() {
  local url="$1"
  local kind="$2"
  log "Handled interlocutor notice: $kind at $url"
}

notif_log_skip() {
  local why="$1"
  log "Skipping notification ($why). Will retry next cycle."
}

notif_resolve_interlocutor() {
  local data="$1"
  local url="${2:-unknown}"
  local body="${3:-}"

  log "Detected interlocutor comment on: $url"

  if [[ -n "$body" ]]; then
    log "Comment body (first 200 chars): ${body:0:200}"
  else
    log "No comment body available — courtesy notice."
  fi
}