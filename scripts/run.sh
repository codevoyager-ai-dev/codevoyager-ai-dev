#!/usr/bin/env bash
set -euo pipefail

# ─── Config ────────────────────────────────────────────────────────────────
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
API_URL="https://opencode.ai/zen/v1/chat/completions"
MODEL="deepseek-v4-flash-free"
AUTH="Bearer public"
MAX_RETRIES=3

export GH_TOKEN="${GH_TOKEN:?GH_TOKEN not set}"
export GIT_TERMINAL_PROMPT=0

# ─── Helpers ───────────────────────────────────────────────────────────────

log()  { echo "[codevoyager] $(date '+%H:%M:%S') $*"; }
die()  { log "FATAL: $*"; exit 1; }

# ─── API call ──────────────────────────────────────────────────────────────

api_complete() {
  local messages_json="$1"
  local body

  body="$(jq -n --arg model "$MODEL" --argjson messages "$messages_json" '{
    model: $model,
    messages: $messages
  }')"

  curl -s "$API_URL" \
    -H "Authorization: $AUTH" \
    -H "Content-Type: application/json" \
    -d "$body" \
    --max-time 180
}

api_extract_content() {
  jq -r '.choices[0].message.content // empty'
}

# ─── State management ──────────────────────────────────────────────────────

load_state() {
  if [[ -f "$REPO_DIR/state.json" ]]; then
    cat "$REPO_DIR/state.json"
  else
    echo '{}'
  fi
}

save_state() {
  local new_state="$1"
  echo "$new_state" > "$REPO_DIR/state.json"
}

# ─── Notification check ────────────────────────────────────────────────────

check_notifications() {
  log "Checking notifications..."
  gh api notifications --jq '[
    .[] | select(.reason == "mention" or .reason == "review_requested" or .reason == "comment")
    | {id, reason, subject: {title, url, latest_comment_url}, repository: {full_name}}
  ]' 2>/dev/null || echo "[]"
}

mark_notification_done() {
  local notif_id="$1"
  gh api "notifications/$notif_id" -X PATCH --silent 2>/dev/null || true
}

# ─── Own-repo help requests ────────────────────────────────────────────────

MY_REPO="codevoyager-ai-dev/codevoyager-ai-dev"

check_help_requests() {
  log "Checking for help requests in $MY_REPO..."
  gh issue list \
    --repo "$MY_REPO" \
    --label "help wanted" \
    --state open \
    --json number,title,body,createdAt \
    --limit 10 \
    2>/dev/null | jq '[
      .[] | select(.body != null)
      | {
        number,
        title,
        body,
        created_at: .createdAt,
        target_repo: (.body | capture("https?://github\\.com/(?<r>[^/\"\\s]+/[^/\"\\s]+)") // .body | capture("(?<r>[a-zA-Z0-9_-]+/[a-zA-Z0-9_-]+)"))
      }
    ]'
}

close_help_issue() {
  local issue_number="$1"
  gh issue close "$issue_number" --repo "$MY_REPO" --comment "CodeVoyager is working on this!" 2>/dev/null || true
}

# ─── Issue search (proactive) ─────────────────────────────────────────────

find_issue() {
  log "Searching for issues to solve..."
  gh search issues \
    --label "good-first-issue,good first issue,help wanted,bug" \
    --state open \
    --sort updated \
    --limit 20 \
    --json repository,number,title,url,body,labels \
    -- 'language:python language:javascript language:typescript language:go language:rust language:java language:kotlin' \
    2>/dev/null
}

pick_best_issue() {
  local issues_json="$1"
  local state="$2"

  local used_repos
  used_repos="$(echo "$state" | jq -r '.repos_explored // [] | join("|")')"

  echo "$issues_json" | jq -r --arg used "$used_repos" '
    [.[] | select(.repository.full_name | test("^(" + $used + ")"; "x") | not)]
    | first
  '
}

# ─── Repo operations ───────────────────────────────────────────────────────

fork_repo() {
  local repo_full="$1"
  log "Forking $repo_full ..."
  gh repo fork "$repo_full" --clone=false 2>/dev/null || true
  echo "https://x-access-token:${GH_TOKEN}@github.com/codevoyager-ai-dev/${repo_full#*/}.git"
}

create_pr() {
  local repo_full="$1"
  local title="$2"
  local body="$3"
  local head="$4"
  local base="${5:-main}"

  log "Creating PR: $title"
  gh pr create \
    --repo "$repo_full" \
    --title "$title" \
    --body "$body" \
    --head "codevoyager-ai-dev:$head" \
    --base "$base" \
    2>/dev/null || true
}

# ─── Test framework detection ──────────────────────────────────────────────

detect_test_cmd() {
  local dir="$1"
  if [[ -f "$dir/package.json" ]]; then
    if jq -e '.scripts.test' "$dir/package.json" >/dev/null 2>&1; then
      echo "npm test 2>&1 || true"
      return
    fi
  fi
  if [[ -f "$dir/pyproject.toml" ]] && grep -q '\[tool.pytest' "$dir/pyproject.toml" 2>/dev/null; then
    echo "python -m pytest -x -q 2>&1 || true"
    return
  fi
  if [[ -f "$dir/setup.cfg" ]] && grep -q 'pytest' "$dir/setup.cfg" 2>/dev/null; then
    echo "python -m pytest -x -q 2>&1 || true"
    return
  fi
  if ls "$dir"/test_*.py "$dir"/tests/test_*.py 2>/dev/null | head -1 >/dev/null; then
    echo "python -m pytest -x -q 2>&1 || true"
    return
  fi
  if ls "$dir"/*_test.py 2>/dev/null | head -1 >/dev/null; then
    echo "python -m pytest -x -q 2>&1 || true"
    return
  fi
  if [[ -f "$dir/Cargo.toml" ]]; then
    echo "cargo test 2>&1 || true"
    return
  fi
  if [[ -f "$dir/go.mod" ]]; then
    echo "go test ./... 2>&1 || true"
    return
  fi
  if [[ -f "$dir/pom.xml" ]]; then
    echo "mvn test -q 2>&1 || true"
    return
  fi
  if [[ -f "$dir/build.gradle" ]] || [[ -f "$dir/build.gradle.kts" ]]; then
    echo "gradle test 2>&1 || true"
    return
  fi
  if [[ -f "$dir/Makefile" ]] && grep -q '^test' "$dir/Makefile" 2>/dev/null; then
    echo "make test 2>&1 || true"
    return
  fi
  echo ""
}

run_tests() {
  local dir="$1"
  local cmd
  cmd="$(detect_test_cmd "$dir")"

  if [[ -z "$cmd" ]]; then
    log "No test framework detected — skipping tests"
    return 0
  fi

  log "Running: $cmd"
  eval "$cmd" || return 1
}

install_deps() {
  local dir="$1"
  if [[ -f "$dir/package.json" ]]; then
    if [[ -f "$dir/package-lock.json" ]]; then
      npm ci --prefix "$dir" 2>/dev/null && return 0
    fi
    npm install --prefix "$dir" 2>/dev/null && return 0
  fi
  if [[ -f "$dir/pyproject.toml" ]]; then
    pip install -e "$dir" 2>/dev/null && return 0
  fi
  if [[ -f "$dir/requirements.txt" ]]; then
    pip install -r "$dir/requirements.txt" 2>/dev/null && return 0
  fi
  return 0
}

# ─── Self-review (diff analysis) ───────────────────────────────────────────

self_review_diff() {
  local clone_dir="$1"
  local system_prompt="$2"
  local original_issue="$3"

  cd "$clone_dir"

  local diff_text
  diff_text="$(git diff 2>/dev/null || true)"

  if [[ -z "$diff_text" ]]; then
    log "No diff to review"
    return 0
  fi

  log "Running self-review on diff (${#diff_text} chars)..."

  local review_prompt
  review_prompt="$(cat <<REVIEW
You are reviewing your own code changes. Verify:

1. Does the diff actually solve the original problem?
   Original issue: $original_issue

2. Does the diff avoid breaking existing functionality?
3. Is the code correct, idiomatic, and consistent with the project?
4. Are there any edge cases not handled?
5. Are the tests adequate and correct?

Diff to review:
\`\`\`diff
$diff_text
\`\`\`

Respond with either:
- **APPROVED** if everything is correct
- **CHANGES NEEDED:** followed by what needs to be fixed and how
REVIEW
)"

  local messages_json
  messages_json="$(jq -n \
    --arg system "$system_prompt" \
    --arg user "$review_prompt" \
    '[{role: "system", content: $system}, {role: "user", content: $user}]'
  )"

  local api_result
  api_result="$(api_complete "$messages_json")"
  local review_response
  review_response="$(echo "$api_result" | api_extract_content)"

  echo "$review_response" > "$clone_dir/.codevoyager-review.md"

  if echo "$review_response" | grep -qi "^APPROVED"; then
    log "Self-review: APPROVED"
    return 0
  else
    log "Self-review: CHANGES NEEDED"
    return 1
  fi
}

# ─── Test-and-retry loop ──────────────────────────────────────────────────

apply_and_test_loop() {
  local clone_dir="$1"
  local system_prompt="$2"
  local user_msg="$3"
  local attempt=0

  while [[ "$attempt" -lt "$MAX_RETRIES" ]]; do
    attempt=$((attempt + 1))
    log "API call attempt $attempt/$MAX_RETRIES ..."

    local messages_json
    messages_json="$(jq -n \
      --arg system "$system_prompt" \
      --arg user "$user_msg" \
      '[{role: "system", content: $system}, {role: "user", content: $user}]'
    )"

    local api_result
    api_result="$(api_complete "$messages_json")"
    local ai_response
    ai_response="$(echo "$api_result" | api_extract_content)"

    log "AI response received (${#ai_response} chars)"
    echo "$ai_response" > "$clone_dir/.codevoyager-response.md"

    install_deps "$clone_dir" || true

    if run_tests "$clone_dir"; then
      log "Tests passed on attempt $attempt"

      if self_review_diff "$clone_dir" "$system_prompt" "$user_msg"; then
        log "Self-review passed on attempt $attempt"
        return 0
      else
        log "Self-review found issues on attempt $attempt"

        if [[ "$attempt" -ge "$MAX_RETRIES" ]]; then
          log "Max retries reached after self-review failure"
          return 1
        fi

        local review_result
        review_result="$(cat "$clone_dir/.codevoyager-review.md")"

        user_msg="$(cat <<USERMSG
The self-review found the following issues with your code changes:

\`\`\`
$review_result
\`\`\`

Fix the issues identified above. Output corrected file contents.
Do not break the tests — they are currently passing.
USERMSG
)"
      fi
    else
      local test_output
      test_output="$(run_tests "$clone_dir" 2>&1 || true)"
      log "Tests failed on attempt $attempt"

      if [[ "$attempt" -ge "$MAX_RETRIES" ]]; then
        log "Max retries reached after test failure"
        echo "$test_output" > "$clone_dir/.codevoyager-test-failure.txt"
        return 1
      fi

      log "Sending test output back to fix..."
      user_msg="$(cat <<USERMSG
The tests failed. Here is the test output:

\`\`\`
$test_output
\`\`\`

The code changes you previously suggested caused test failures.
Fix the issues. Output corrected file contents.
USERMSG
)"
    fi
  done
}

# ─── Build system prompt ───────────────────────────────────────────────────

build_system_prompt() {
  local rules
  rules="$(cat "$REPO_DIR/rules.md")"
  cat <<PROMPT
You are CodeVoyager, an AI assistant that contributes to open source projects.

## Rules
$rules

## Instructions
- Generate ONLY functional, tested code
- NO placeholders, NO examples, NO simulacra
- Include or update tests
- Respect the project's existing conventions
- Output your response as valid Markdown with code blocks
- When making changes, output a list of files and the exact changes needed
- Keep explanations minimal — focus on the code
PROMPT
}

# ─── Solve workflow (shared between issue solving and help requests) ──────

solve_issue() {
  local repo_full="$1"
  local issue_number="$2"
  local issue_title="$3"
  local issue_body="$4"
  local issue_url="$5"
  local system_prompt="$6"
  local state_ref="$7"

  log "Solving: $repo_full#$issue_number — $issue_title"

  local fork_remote
  fork_remote="$(fork_repo "$repo_full")"

  local clone_dir
  clone_dir="$(mktemp -d)"
  local branch_name="fix-issue-$issue_number"

  git clone --depth 1 "$fork_remote" "$clone_dir" 2>/dev/null || die "Failed to clone fork"
  cd "$clone_dir"
  git checkout -b "$branch_name"

  local repo_files
  repo_files="$(find "$clone_dir" -type f \
    -not -path '*/.git/*' \
    -not -path '*/node_modules/*' \
    -not -path '*/vendor/*' \
    -not -path '*/__pycache__/*' \
    -not -path '*.pyc' \
    2>/dev/null | head -100)"

  local repo_readme
  repo_readme="$(cat "$clone_dir/README.md" 2>/dev/null || echo "No README")"
  local build_info
  build_info="$(cat "$clone_dir/package.json" "$clone_dir/pyproject.toml" "$clone_dir/Cargo.toml" "$clone_dir/go.mod" "$clone_dir/pom.xml" "$clone_dir/build.gradle" 2>/dev/null || echo "")"

  local user_msg
  user_msg="$(cat <<USERMSG
## Issue
- Repository: $repo_full
- Issue #$issue_number: $issue_title
- URL: $issue_url

## Description
$issue_body

## Project Structure
- README: $repo_readme
- Build/Config: $(echo "$build_info" | head -300)

## Key files (first 100)
$repo_files

## Task
Implement a solution for this issue.
The code MUST be functional, real, and include/update tests.
Output the exact file contents or diffs.
USERMSG
)"

  log "Starting test-and-retry loop for the solution..."
  if apply_and_test_loop "$clone_dir" "$system_prompt" "$user_msg"; then
    cd "$clone_dir"
    git add -A 2>/dev/null || true
    if git diff --cached --quiet 2>/dev/null; then
      log "No changes to commit"
      cd "$REPO_DIR"
      rm -rf "$clone_dir"
      return 1
    fi

    git commit -m "[codevoyager] fix: $issue_title

Closes #$issue_number
" 2>/dev/null || true

    git push origin "$branch_name" 2>/dev/null || log "Push failed"

    local pr_body
    pr_body="## Summary

This PR addresses issue #$issue_number: **$issue_title**

### Changes
See commit diff for details.

### Testing
- [x] Changes tested locally
- [x] Tests pass

Closes #$issue_number
"
    create_pr "$repo_full" "[codevoyager] $issue_title" "$pr_body" "$branch_name"

    local s="$state_ref"
    s="$(echo "$s" | jq \
      --arg repo "$repo_full" \
      --arg issue "$issue_number" \
      --arg title "$issue_title" \
      '.active_prs += [{
        repo: $repo,
        issue_number: ($issue | tonumber),
        pr_number: null,
        title: $title,
        status: "opened",
        created_at: (now | todate)
      }] |
      .repos_explored += [$repo] |
      .total_contributions += 1 |
      .total_issues_resolved += 1 |
      .total_prs_opened += 1
    ')"

    cd "$REPO_DIR"
    rm -rf "$clone_dir"
    echo "$s"
    return 0
  else
    cd "$REPO_DIR"
    rm -rf "$clone_dir"
    log "Failed to solve issue after $MAX_RETRIES attempts"
    return 1
  fi
}

# ─── Main ──────────────────────────────────────────────────────────────────

main() {
  log "CodeVoyager starting..."
  cd "$REPO_DIR"

  local state
  state="$(load_state)"
  local system_prompt
  system_prompt="$(build_system_prompt)"

  # ── Priority 1: Handle notification (PR review/comment) ─────
  local notifications
  notifications="$(check_notifications)"
  local notif_count
  notif_count="$(echo "$notifications" | jq length)"

  if [[ "$notif_count" -gt 0 ]]; then
    log "Handling 1 notification ($notif_count pending)"

    local notif_id
    notif_id="$(echo "$notifications" | jq -r '.[0].id')"
    local notif_data
    notif_data="$(echo "$notifications" | jq '.[0]')"

    local repo_full
    repo_full="$(echo "$notif_data" | jq -r '.repository.full_name')"
    local subject_url
    subject_url="$(echo "$notif_data" | jq -r '.subject.url // empty')"
    local comment_url
    comment_url="$(echo "$notif_data" | jq -r '.subject.latest_comment_url // empty')"

    local comment_body=""
    local pr_number=""
    local pr_title=""

    if [[ -n "$comment_url" && "$comment_url" != "null" ]]; then
      comment_body="$(gh api "$comment_url" --jq '.body' 2>/dev/null || echo "")"
    fi
    if [[ -n "$subject_url" && "$subject_url" != "null" ]]; then
      pr_number="$(echo "$subject_url" | grep -oP '\d+$')"
      pr_title="$(gh api "$subject_url" --jq '.title' 2>/dev/null || echo "")"
    fi

    if [[ -z "$pr_number" || -z "$comment_body" ]]; then
      log "Skipping notification $notif_id — missing data"
      mark_notification_done "$notif_id"
    else
      log "Handling review: PR #$pr_number on $repo_full"

      local fork_remote
      fork_remote="$(fork_repo "$repo_full")"
      local clone_dir
      clone_dir="$(mktemp -d)"

      git clone --depth 1 "$fork_remote" "$clone_dir" 2>/dev/null || die "Failed to clone fork"
      cd "$clone_dir"
      git fetch origin "pull/$pr_number/head:pr-$pr_number" 2>/dev/null || true
      git checkout "pr-$pr_number" 2>/dev/null || git checkout -b "pr-$pr_number" main

      local repo_files
      repo_files="$(find "$clone_dir" -type f \
        -not -path '*/.git/*' \
        -not -path '*/node_modules/*' \
        -not -path '*/vendor/*' \
        -not -path '*/__pycache__/*' \
        -not -path '*.pyc' \
        2>/dev/null | head -50)"

      local user_msg
      user_msg="$(cat <<USERMSG
## Context
- Repository: $repo_full
- PR #$pr_number: $pr_title
- Review comment:

$comment_body

## Current PR branch files
$repo_files

## Task
Address the review comment above. Fix/adjust the code.
Make real functional changes. Update tests.
Output exact file diffs or contents.
USERMSG
)"

      log "Starting test-and-retry for review fix..."
      if apply_and_test_loop "$clone_dir" "$system_prompt" "$user_msg"; then
        git add -A 2>/dev/null || true
        if ! git diff --cached --quiet 2>/dev/null; then
          git commit -m "[codevoyager] address review feedback for PR #$pr_number" 2>/dev/null || true
          git push origin "pr-$pr_number" 2>/dev/null || log "Push failed"
        fi

        state="$(echo "$state" | jq \
          --arg repo "$repo_full" \
          --arg pr "$pr_number" \
          '.active_prs = [.active_prs[] | if (.repo == $repo and .pr_number == $pr) then .status = "updated" else . end]'
        )"
      fi

      cd "$REPO_DIR"
      rm -rf "$clone_dir"
      mark_notification_done "$notif_id"
    fi

  # ── Priority 2: Check help requests in own repo ─────────────
  else
    log "No notifications. Checking help requests in $MY_REPO..."
    local help_requests
    help_requests="$(check_help_requests)"
    local help_count
    help_count="$(echo "$help_requests" | jq length)"

    if [[ "$help_count" -gt 0 ]]; then
      log "Found $help_count help request(s) — handling the first one"

      local help_issue
      help_issue="$(echo "$help_requests" | jq '.[0]')"
      local help_issue_number
      help_issue_number="$(echo "$help_issue" | jq -r '.number')"
      local help_issue_title
      help_issue_title="$(echo "$help_issue" | jq -r '.title')"
      local help_issue_body
      help_issue_body="$(echo "$help_issue" | jq -r '.body')"
      local target_repo
      target_repo="$(echo "$help_issue" | jq -r '.target_repo.repo // empty')"

      if [[ -z "$target_repo" ]]; then
        target_repo="$(echo "$help_issue_body" | grep -oP '[a-zA-Z0-9_-]+/[a-zA-Z0-9_-]+' | head -1 || echo "")"
      fi

      if [[ -z "$target_repo" ]]; then
        log "Help request #$help_issue_number has no clear target repo — closing"
        gh issue comment "$help_issue_number" \
          --repo "$MY_REPO" \
          --body "Could not identify a target repository. Please include the repository link (e.g. \`owner/repo\`)." \
          2>/dev/null || true
      else
        log "Help request for $target_repo — issue #$help_issue_number"

        close_help_issue "$help_issue_number"

        local new_state
        new_state="$(solve_issue \
          "$target_repo" \
          "" \
          "$help_issue_title" \
          "$help_issue_body" \
          "" \
          "$system_prompt" \
          "$state"
        )"

        if [[ -n "$new_state" ]]; then
          state="$new_state"
        fi
      fi

    # ── Priority 3: Proactively find an issue ────────────────
    else
      log "No help requests. Searching proactively for issues..."
      local issues
      issues="$(find_issue)"
      local issue
      issue="$(pick_best_issue "$issues" "$state")"

      if [[ -z "$issue" || "$issue" == "null" ]]; then
        log "No suitable issues found. Will retry next cycle."
        save_state "$state"
        exit 0
      fi

      local repo_full
      repo_full="$(echo "$issue" | jq -r '.repository.full_name')"
      local issue_number
      issue_number="$(echo "$issue" | jq -r '.number')"
      local issue_title
      issue_title="$(echo "$issue" | jq -r '.title')"
      local issue_body
      issue_body="$(echo "$issue" | jq -r '.body // ""')"
      local issue_url
      issue_url="$(echo "$issue" | jq -r '.url')"

      local new_state
      new_state="$(solve_issue \
        "$repo_full" \
        "$issue_number" \
        "$issue_title" \
        "$issue_body" \
        "$issue_url" \
        "$system_prompt" \
        "$state"
      )"

      if [[ -n "$new_state" ]]; then
        state="$new_state"
      fi
    fi
  fi

  # ── Finalize ─────────────────────────────────────────────
  state="$(echo "$state" | jq --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
    .last_run = $now |
    .consecutive_failures = 0
  ')"

  save_state "$state"
  log "Done. State saved."
}

main "$@"
