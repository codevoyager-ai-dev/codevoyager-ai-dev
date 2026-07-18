#!/usr/bin/env bash
# Help requests opened in our own repo.
# Depends on: lib/common.sh

MY_REPO="${MY_REPO:-codevoyager-ai-dev/codevoyager-ai-dev}"

help_fetch_open() {
  log "Checking for help requests in $MY_REPO..."
  gh issue list \
    --repo "$MY_REPO" \
    --label "help wanted" \
    --state open \
    --json number,title,body,createdAt \
    --limit 10 \
    2>/dev/null | jq '[
      .[] | select(.body != null and .body != "")
      | {number, title, body, created_at: .createdAt}
    ]' || echo "[]"
}

# Resolve the target repository from an issue body. Accepts:
#   * https://github.com/owner/repo URLs
#   * owner/repo shorthand at start of line
help_resolve_target() {
  local body="$1"
  local repo
  repo="$(grep -oE 'https?://github\.com/[a-zA-Z0-9._-]+/[a-zA-Z0-9._-]+' <<< "$body" \
        | head -1 \
        | sed -E 's|https?://github\.com/||' || true)"
  if [[ -z "$repo" ]]; then
    repo="$(grep -oE '^[[:space:]]*[a-zA-Z0-9._-]+/[a-zA-Z0-9._-]+' <<< "$body" \
          | head -1 | xargs || true)"
  fi
  if [[ -z "$repo" ]]; then
    repo="$(grep -oE '[a-zA-Z0-9._-]+/[a-zA-Z0-9._-]+' <<< "$body" \
          | head -1 || true)"
  fi
  log "Resolved help target to: ${repo:-<none>}"
  printf '%s' "$repo"
}

help_close() {
  local number="$1"
  gh issue close "$number" --repo "$MY_REPO" \
    --comment "CodeVoyager is working on this!" 2>/dev/null || true
}

help_comment_cannot_resolve() {
  local number="$1"
  gh issue comment "$number" --repo "$MY_REPO" \
    --body "Could not identify a target repository. Please include a GitHub link (e.g. \`owner/repo\`)." \
    2>/dev/null || true
}
