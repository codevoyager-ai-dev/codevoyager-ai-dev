#!/usr/bin/env bash
# handle codevoyager's registered PRs: no-op so the daily cycle does not
# reprocess their own feedback accidentally.
# Depends on: lib/common.sh

pr_cdevoyager_check() {
  local repo="$1"
  local url="$2"
  log "(skip) this is a codevoyager PR in $repo — will respond via standard PR cycle."
}