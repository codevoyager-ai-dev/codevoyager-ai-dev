#!/usr/bin/env bash
set -euo pipefail

# ─── Config ────────────────────────────────────────────────────────────────
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OPENCODE_MODEL="opencode/deepseek-v4-flash-free"

export GH_TOKEN="${GH_TOKEN:?GH_TOKEN not set}"
export GIT_TERMINAL_PROMPT=0
export PATH="$HOME/.opencode/bin:$PATH"

# ─── Helpers ───────────────────────────────────────────────────────────────

log()  { echo "[codevoyager] $(date '+%H:%M:%S') $*" >&2; }
die()  { log "FATAL: $*"; exit 1; }

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
  local result
  result="$(gh api notifications --jq '[
    .[] | select(.reason == "mention" or .reason == "review_requested" or .reason == "comment" or .reason == "author" or .reason == "state_change")
    | {id, reason, subject: {title, url, latest_comment_url}, repository: {full_name}}
  ]' 2>&1)" || {
    log "WARNING: Failed to fetch notifications: $result"
    echo "[]"
    return
  }
  if [[ -z "$result" ]]; then
    result="[]"
  fi
  echo "$result"
  local count
  count="$(echo "$result" | jq length)"
  log "Fetched $count notification(s)"
}

mark_notification_done() {
  local notif_id="$1"
  log "Marking notification $notif_id as done..."
  gh api "notifications/threads/$notif_id" -X PATCH --silent 2>/dev/null || true
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
      .[] | select(.body != null and .body != "")
      | {number, title, body, created_at: .createdAt}
    ]'
}

close_help_issue() {
  local issue_number="$1"
  gh issue close "$issue_number" --repo "$MY_REPO" --comment "CodeVoyager is working on this!" 2>/dev/null || true
}

resolve_help_target() {
  local body="$1"
  local repo
  repo="$(echo "$body" | grep -oE 'https?://github\.com/[a-zA-Z0-9_-]+/[a-zA-Z0-9_-]+' | head -1 | sed 's|https\?://github\.com/||' || echo "")"
  if [[ -z "$repo" ]]; then
    repo="$(echo "$body" | grep -oE '^[a-zA-Z0-9_-]+/[a-zA-Z0-9_-]+' | head -1 || echo "")"
  fi
  if [[ -z "$repo" ]]; then
    repo="$(echo "$body" | grep -oE '[a-zA-Z0-9_-]+/[a-zA-Z0-9_-]+' | head -1 || echo "")"
  fi
  log "Resolved help target to: $repo"
  echo "$repo"
}

# ─── Issue search (proactive) ─────────────────────────────────────────────

find_issue() {
  log "Searching for issues to solve..."
  gh search issues \
    --label "good first issue" \
    --label "help wanted" \
    --label "bug" \
    --state open \
    --sort updated \
    --limit 30 \
    --json repository,number,title,url,body \
    -- "language:python,javascript,typescript,go,rust,java,kotlin" \
    2>/dev/null
}

pick_best_issue() {
  local issues_json="$1"
  local state="$2"

  echo "$issues_json" | jq -r --argjson state "$state" '
    def is_used($repo): 
      ($state.repos_explored // []) | index($repo) != null;

    [.[] | select(.repository != null) | select(.repository.nameWithOwner != null) | select(is_used(.repository.nameWithOwner) | not)]
    | first // null
  '
}

# ─── Repo operations ───────────────────────────────────────────────────────

fork_repo() {
  local repo_full="$1"
  local fork_name="${repo_full#*/}"
  log "Forking $repo_full ..."
  gh repo fork "$repo_full" --clone=false >&2 2>/dev/null || true
  echo "https://codevoyager-ai-dev:${GH_TOKEN}@github.com/codevoyager-ai-dev/${fork_name}.git"
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

# ─── Test detection ────────────────────────────────────────────────────────

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

# ─── OpenCode autonomous agent ─────────────────────────────────────────────

build_task_prompt() {
  local repo_full="$1"
  local task="$2"
  local extra_context="$3"
  local fork_remote="$4"
  local branch_name="$5"
  local rules
  rules="$(cat "$REPO_DIR/rules.md")"

  cat <<PROMPT
You are CodeVoyager, an autonomous AI contributing to $repo_full.

## Rules
$rules

## Task
$task

## Context
$extra_context

## Instructions
1. Read the repository files to understand the codebase.
2. Implement a real, functional solution. Split large files into smaller ones.
3. Include or update tests.
4. Run the project's tests. If they fail, fix the code until they pass.
5. If no test framework is detected, verify your changes are correct by re-reading the modified files.
6. Stage all changes with \`git add -A\`.
7. Commit with \`git commit -m "[codevoyager] <description>"\`.
8. Push to the remote: \`git push origin $branch_name\`.
9. Create a PR using \`gh pr create --repo "$repo_full" --title "[codevoyager] <title>" --body "<summary>" --head "codevoyager-ai-dev:$branch_name" --base main\`.
10. Verify the PR was created successfully. If any step fails, diagnose and fix it.
11. Output a summary of everything you did.

The fork remote is: $fork_remote
The branch name is: $branch_name
All git remote commands will work. The \`gh\` CLI is authenticated.
Do NOT leave any step for me — handle everything including commit, push, and PR.
PROMPT
}

run_opencode_task() {
  local target_dir="$1"
  local prompt_file="$2"
  local title
  title="$(head -3 "$prompt_file" | tr '\n' ' ' | cut -c1-100)"

  log "Running OpenCode agent in $target_dir ..."

  opencode run \
    -m "$OPENCODE_MODEL" \
    --dangerously-skip-permissions \
    --dir "$target_dir" \
    --title "CodeVoyager: $title" \
    --print-logs \
    -f "$prompt_file" -- \
    "Read the attached prompt file and follow the instructions. Implement the solution with real, functional code." \
    2>/tmp/opencode-$$.err | tee /tmp/opencode-$$.out || true

  local exit_code="${PIPESTATUS[0]}"
  rm -f /tmp/opencode-$$.err /tmp/opencode-$$.out

  if [[ "$exit_code" -ne 0 ]]; then
    log "OpenCode exited with code $exit_code"
    return 1
  fi

  log "OpenCode completed successfully"
  return 0
}

# ─── Solve workflow ────────────────────────────────────────────────────────

solve_with_opencode() {
  local repo_full="$1"
  local task_description="$2"
  local issue_ref="$3"

  log "Solving on $repo_full: $task_description"

  local fork_remote
  fork_remote="$(fork_repo "$repo_full")"

  local clone_dir
  clone_dir="$(mktemp -d)"
  local branch_name
  branch_name="codevoyager-$(date +%s)"

  git clone --depth 1 "$fork_remote" "$clone_dir" 2>/dev/null || die "Failed to clone fork"
  cd "$clone_dir"
  git checkout -b "$branch_name"

  local prompt_file
  prompt_file="$(mktemp)"
  build_task_prompt "$repo_full" "$task_description" "Ref: $issue_ref" "$fork_remote" "$branch_name" > "$prompt_file"

  if run_opencode_task "$clone_dir" "$prompt_file"; then
    rm -f "$prompt_file"
    cd "$REPO_DIR"
    rm -rf "$clone_dir"
    log "Task completed by OpenCode (commit, push, PR handled by agent)"
    return 0
  else
    rm -f "$prompt_file"
    cd "$REPO_DIR"
    rm -rf "$clone_dir"
    return 1
  fi
}

# ─── Main ──────────────────────────────────────────────────────────────────

main() {
  log "CodeVoyager starting..."
  cd "$REPO_DIR"

  local state
  state="$(load_state)"

  # ── Priority 1: Handle notification (PR review/comment) ─────
  local notifications
  notifications="$(check_notifications)"
  local notif_count
  notif_count="$(echo "$notifications" | jq length)"

  local handled_something=false

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

    log "Notification data: repo=$repo_full subject_url=$subject_url comment_url=$comment_url"

    local comment_body=""
    local pr_number=""
    local pr_title=""

    if [[ -n "$comment_url" && "$comment_url" != "null" ]]; then
      comment_body="$(gh api "$comment_url" --jq '.body' 2>&1)" || {
        log "WARNING: Failed to fetch comment body: $comment_body"
        comment_body=""
      }
    fi
    if [[ -n "$subject_url" && "$subject_url" != "null" ]]; then
      pr_number="$(echo "$subject_url" | grep -oE '[0-9]+$')"
      pr_title="$(gh api "$subject_url" --jq '.title' 2>&1)" || {
        log "WARNING: Failed to fetch PR title: $pr_title"
        pr_title=""
      }
    fi

    log "Extracted: pr_number=$pr_number comment_body_len=${#comment_body}"

    if [[ -n "$pr_number" && -n "$comment_body" ]]; then
      log "Handling review: PR #$pr_number on $repo_full"

      local task="Address this review comment on PR #$pr_number ($pr_title):

$comment_body

Make the requested changes and ensure all tests pass."

      if solve_with_opencode "$repo_full" "$task" "PR #$pr_number in $repo_full"; then
        log "PR #$pr_number updated"
      fi

      mark_notification_done "$notif_id"
      handled_something=true
    else
      log "Skipping notification — missing data (will retry next cycle)"
    fi
  fi

  # ── Priority 2: Check help requests in own repo ─────────────
  if [[ "$notif_count" -le 0 ]] || ! $handled_something; then
    log "Checking help requests in $MY_REPO..."
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
      target_repo="$(resolve_help_target "$help_issue_body")"

      if [[ -z "$target_repo" ]]; then
        log "Help request #$help_issue_number has no clear target repo"
        gh issue comment "$help_issue_number" \
          --repo "$MY_REPO" \
          --body "Could not identify a target repository. Please include a GitHub link (e.g. \`owner/repo\`)." \
          2>/dev/null || true
      else
        log "Help request for $target_repo"

        local task="Help with: $help_issue_title

This request was made by a user in my help repository. Details:
$help_issue_body

Implement the requested changes or solve the problem described."

        close_help_issue "$help_issue_number"

        if solve_with_opencode "$target_repo" "$task" "Help request #$help_issue_number"; then
          log "Help request #$help_issue_number completed"
          handled_something=true
        fi
      fi
    fi
  fi

  # ── Priority 3: Proactively find an issue ────────────────
  if ! $handled_something; then
    log "Searching proactively for issues..."
    local issues
    issues="$(find_issue)"
    local issue
    issue="$(pick_best_issue "$issues" "$state")"

    if [[ -z "$issue" || "$issue" == "null" ]]; then
      log "No suitable issues found. Will retry next cycle."
    else
      local repo_full
      repo_full="$(echo "$issue" | jq -r '.repository.nameWithOwner')"
      local issue_number
      issue_number="$(echo "$issue" | jq -r '.number')"
      local issue_title
      issue_title="$(echo "$issue" | jq -r '.title')"
      local issue_body
      issue_body="$(echo "$issue" | jq -r '.body // ""')"
      local issue_url
      issue_url="$(echo "$issue" | jq -r '.url')"

      log "Found issue: $repo_full#$issue_number — $issue_title"

      local task="Solve this issue: $issue_title

Issue description:
$issue_body

Implement a real, functional solution. Include tests.
Ensure all existing tests still pass."

      if solve_with_opencode "$repo_full" "$task" "$issue_url"; then
        state="$(echo "$state" | jq \
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
        log "Issue #$issue_number solved"
      else
        log "Failed to solve issue #$issue_number"
        state="$(echo "$state" | jq \
          --arg issue "$issue_number" \
          '.consecutive_failures += 1 |
           .last_error = "Failed to solve issue #\($issue)"'
        )"
      fi
    fi
  fi

  # ── Finalize ─────────────────────────────────────────────
  state="$(echo "$state" | jq --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
    .last_run = $now
  ')"

  save_state "$state"
  log "Done. State saved."
}

main "$@"
