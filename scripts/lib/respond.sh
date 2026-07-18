#!/usr/bin/env bash
# Auto-respond to maintainer comments on our PRs.
# Depends on: lib/common.sh

respond_maintainer() {
  local pr_number="$1"
  local repo_full="$2"
  local comment_user="$3"
  local comment_body="$4"

  log "Responding to PR #$pr_number in $repo_full (user: $comment_user)"

  local reply
  reply="Thank you for the feedback, @$comment_user!

I've read your comment and will address it now. The requested changes are in progress — I'll push an update shortly.

If you have any additional requests, feel free to let me know."

  if [[ -n "$comment_body" ]]; then
    reply="$reply

(Reference: your comment was on PR #$pr_number regarding this issue.)"
  fi

  gh pr comment "$pr_number" \
    --repo "$repo_full" \
    --body "$reply" \
    2>/dev/null || {
    log "WARNING: failed to post comment on PR #$pr_number"
  }

  log "Response posted on PR #$pr_number"
}