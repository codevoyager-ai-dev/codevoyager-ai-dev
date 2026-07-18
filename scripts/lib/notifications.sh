#!/usr/bin/env bash
# notifications via gh: fetch + resolve + mark done.
# Depends on: lib/common.sh

notif_fetch() {
  log "Checking notifications..."
  local result
  if ! result="$(gh api notifications --jq '[
      .[] | select(.reason == "mention" or .reason == "review_requested"
                 or .reason == "comment" or .reason == "author"
                 or .reason == "state_change")
      | {id, reason, subject: {title, url, latest_comment_url},
          repository: {full_name}}
    ]' 2>/dev/null)"; then
    log "WARNING: failed to fetch notifications"
    echo "[]"
    return
  fi
  [[ -z "$result" ]] && result="[]"
  local count
  count="$(jq 'length' <<< "$result")"
  log "Fetched $count notification(s)"
  printf '%s' "$result"
}

notif_mark_done() {
  local id="$1"
  log "Marking notification $id as done..."
  gh api "notifications/threads/$id" -X PATCH --silent 2>/dev/null || true
}

# Resolve PR context for a notification; prints JSON
#   {pr_number, pr_title, comment_body, comment_user, is_our_pr}
notif_resolve() {
  local notif_data="$1"

  local subject_url comment_url reason full_name
  subject_url="$(jq -r '.subject.url // empty' <<< "$notif_data")"
  comment_url="$(jq -r '.subject.latest_comment_url // empty' <<< "$notif_data")"
  reason="$(jq -r '.reason' <<< "$notif_data")"
  full_name="$(jq -r '.repository.full_name // ""' <<< "$notif_data")"

  local comment_body="" pr_number="" pr_title="" comment_user=""

  if [[ -n "$comment_url" && "$comment_url" != "null" ]]; then
    comment_body="$(gh api "$comment_url" --jq '.body' 2>/dev/null)" || comment_body=""
    comment_user="$(gh api "$comment_url" --jq '.user.login' 2>/dev/null)" || comment_user=""
  fi
  if [[ -n "$subject_url" && "$subject_url" != "null" ]]; then
    pr_number="$(grep -oE '[0-9]+$' <<< "$subject_url" || true)"
    pr_title="$(gh api "$subject_url" --jq '.title' 2>/dev/null)" || pr_title=""
    local pr_author
    pr_author="$(gh api "$subject_url" --jq '.user.login' 2>/dev/null)" || pr_author=""
    # is_our_pr: true if author is our bot
    local is_our_pr="false"
    if [[ "$pr_author" == "${MY_USER_NAME:-codevoyager-ai-dev}" ]]; then
      is_our_pr="true"
    fi
    if [[ "$reason" == "review_requested" && "$is_our_pr" == "true" ]]; then
      log "Review requested on our PR #$pr_number in $full_name"
    fi
  fi

  jq -n \
    --arg pr "$pr_number" \
    --arg title "$pr_title" \
    --arg body "$comment_body" \
    --arg user "$comment_user" \
    --argjson ours "$is_our_pr" \
    '{pr_number:$pr, pr_title:$title, comment_body:$body, comment_user:$user, is_our_pr:$ours}'
}