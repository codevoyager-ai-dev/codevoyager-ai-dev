#!/usr/bin/env bash
# Common helpers shared by all lib modules.
# Sourced by run.sh — keeps set -euo pipefail from the caller.

REPO_DIR="${REPO_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

log()  { echo "[codevoyager] $(date '+%H:%M:%S') $*" >&2; }
die()  { log "FATAL: $*"; exit 1; }

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"
}

# Run a command, capturing combined output into a variable name passed by ref.
# Usage: capture_out <outvar> <cmd...>
capture_out() {
  local _outvar="$1"; shift
  local _rc
  "$@" >/tmp/cv-cap-$$.out 2>&1 || _rc=$?
  _rc="${_rc:-0}"
  printf -v "$_outvar" '%s' "$(cat /tmp/cv-cap-$$.out)"
  rm -f /tmp/cv-cap-$$.out
  return "$_rc"
}
