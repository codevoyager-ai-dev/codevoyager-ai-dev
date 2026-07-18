#!/usr/bin/env bash
# OpenCode agent execution — builds prompt + runs opencode.
# Depends on: lib/common.sh, lib/fork.sh

OPENCODE_MODEL="opencode/deepseek-v4-flash-free"

opencode_build_prompt() {
  local repo_full="$1"
  local task="$2"
  local extra_context="$3"
  local branch_name="$4"
  local rules_plan="$5"
  local base_branch="$6"

  cat <<PROMPT
You are CodeVoyager, an autonomous AI contributing to $repo_full.

## Rules
$rules_plan

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
9. Create a PR using \`gh pr create --repo "$repo_full" \
   --title "[codevoyager] <title>" --body "<summary>" \
   --head "codevoyager-ai-dev:$branch_name" --base "$base_branch"\`.
10. Verify the PR was created successfully. If any step fails, diagnose and fix it.
11. The gh CLI is authenticated. Do not leave anything for me — handle commit, push, and PR creation.
12. At the end output the PR number in a line starting with PR_NUMBER:
PROMPT
}

opencode_run() {
  local target_dir="$1"
  local prompt_file="$2"
  local title
  title="$(head -3 "$prompt_file" | tr '\n' ' ' | cut -c1-100)"

  log "Running OpenCode agent in $target_dir ..."

  opencode run \
    -m "$OPencode_MODEL" \
    --dangerously-skip-permissions \
    --dir "$target_dir" \
    --title "CodeVoyager: $title" \
    -f "$prompt_file" -- \
    "Read the prompt file and follow the instructions. Implement real, working code." \
    2>/tmp/opencode-$$.err | tee /tmp/opencode-$$.out || true

  local exit_code="${PIPESTATUS[0]}"
  rm -f /tmp/opencode-$$.err

  if [[ "$exit_code" -ne 0 ]]; then
    log "OpenCode exited with code $exit_code"
  else
    log "OpenCode completed"
  fi

  rm -f /tmp/opencode-$$.out
  return "$exit_code"
}

opencode_extract_pr_number() {
  local output_file="$1"
  grep -oE 'PR_NUMBER:[[:space:]]*[0-9]+' "$output_file" 2>/dev/null \
    | grep -oE '[0-9]+' | head -1 || true
}