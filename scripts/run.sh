#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPTS_LIB="$REPO_DIR/scripts/lib"

source "$SCRIPTS_LIB/common.sh"
source "$SCRIPTS_LIB/state.sh"
source "$SCRIPTS_LIB/notifications.sh"
source "$SCRIPTS_LIB/issues.sh"
source "$SCRIPTS_LIB/help.sh"
source "$SCRIPTS_LIB/fork.sh"
source "$SCRIPTS_LIB/opencode.sh"
source "$SCRIPTS_LIB/log.sh"
source "$SCRIPTS_LIB/respond.sh"

export GH_TOKEN="${GH_TOKEN:?GH_TOKEN not set}"
export GIT_TERMINAL_PROMPT=0
export PATH="$HOME/.opencode/bin:$PATH"
MY_USER_NAME="codevoyager-ai-dev"

main() {
  log "CodeVoyager starting..."
  cd "$REPO_DIR"

  local state
  state="$(state_load)"

  fork_init_credentials "$GH_TOKEN"

  local handled_something=false

  # 1) Handle the first notification (PR review / comment / review_requested)
  local notifications
  notifications="$(notif_fetch)"
  local notif_count
  notif_count="$(jq 'length' <<< "$notifications")"

  if [[ "$notif_count" -gt 0 ]]; then
    local notif_id
    notif_id="$(jq -r '.[0].id' <<< "$notifications")"
    local notif_data
    notif_data="$(jq '.[0]' <<< "$notifications")"

    local repo_full
    repo_full="$(jq -r '.repository.full_name' <<< "$notif_data")"

    if [[ -n "$repo_full" && "$repo_full" != "null" ]]; then
      local info
      info="$(notif_resolve "$notif_data")"
      local pr_number comment_body comment_user is_our_pr
      pr_number="$(jq -r '.pr_number' <<< "$info")"
      comment_body="$(jq -r '.comment_body' <<< "$info")"
      comment_user="$(jq -r '.comment_user' <<< "$info")"
      is_our_pr="$(jq -r '.is_our_pr' <<< "$info")"

      if [[ "$is_our_pr" == "true" && -n "$pr_number" && "$pr_number" != "null" ]]; then
        respond_maintainer "$pr_number" "$repo_full" "$comment_user" "$comment_body"
        handled_something=true
      elif [[ -n "$pr_number" && "$pr_number" != "null" && -n "$comment_body" && "$comment_body" != "null" ]]; then
        log "Comment on non-CodeVoyager PR #$pr_number in $repo_full — dispatching as collaboration"
        local pr_title
        pr_title="$(jq -r '.pr_title' <<< "$info")"
        local task="Collaborate on PR #$pr_number ($pr_title): $comment_body"
        if solve_with_opencode "$repo_full" "$task" "$comment_user"; then
          handled_something=true
        fi
      else
        log "Skipping empty/missing-data notification"
      fi
    fi

    notif_mark_done "$notif_id"
  fi

  # 2) Help requests
  if ! $handled_something; then
    local help_reqs
    help_reqs="$(help_fetch_open)"
    local help_count
    help_count="$(jq 'length' <<< "$help_reqs")"

    if [[ "$help_count" -gt 0 ]]; then
      local help="$(jq '.[0]' <<< "$help_reqs" 2>/dev/null)"
      local help_num title body target
      help_num="$(jq -r '.number' <<< "$help")"
      title="$(jq -r '.title' <<< "$help")"
      body="$(jq -r '.body' <<< "$help")"
      target="$(help_resolve_target "$body")"

      if [[ -z "$target" ]]; then
        help_comment_cannot_resolve "$help_num"
      else
        local task="Problem description: [[$title]] | Details: [[$body]]. Implement the requested changes or solve the problem described."
        log "Help request for $target"

        if solve_with_opencode "$target" "$task" "Help-request #$help_num" no_pr_out; then
          help_close "$help_num"
          handled_something=true
        else
          log "Help request #$help_num failed"
        fi
      fi
    fi
  fi

  # 3) Proactive issue search
  if ! $handled_something; then
    local issues
    issues="$(issues_search)"
    local issue
    issue="$(issues_pick_best "$issues" "$state")"

    if [[ -z "$issue" || "$issue" == "null" ]]; then
      log "No suitable issues found. Will retry next cycle."
    else
      local repo_full
      repo_full="$(jq -r '.repository' <<< "$issue")"
      local issue_number
      issue_number="$(jq -r '.number' <<< "$issue")"
      local issue_title
      issue_title="$(jq -r '.title' <<< "$issue")"
      local issue_body
      issue_body="$(jq -r '.body // ""' <<< "$issue")"

      log "Found issue: $repo_full#$issue_number — $issue_title"

      local task="Resolve this from-scratch task
Issue no: $issue_number on $repo_full
Title: $issue_title
Description: $issue_body
Implement a real, functional solution with tests."

      local pr_out=""
      if solve_with_opencode "$repo_full" "$task" "#$issue_number" pr_out; then
        state="$(state_bump_language "$state" "unknown")"
        state="$(state_mark_repo_explored "$state" "$repo_full")"
        state_record_interaction "$repo_full" "issue" "$issue_title" "solved"
        state_record_project "$repo_full" "unknown"

        local pr_num=""
        if [[ -n "$pr_out" ]]; then
          pr_num="$pr_out"
          state="$(jq --arg repo "$repo_full" --arg num "$pr_num" --arg t "$issue_title" --arg nr "$issue_number" \
            '.active_prs += [{repo:$repo, issue_number:($nr|fromjson), pr_number:($num|fromjson), title:$t, status:"opened", created_at:(now|todate)}] | .total_contributions += 1 | .total_prs_opened += 1' <<< "$state")"
        else
          state="$(jq --arg repo "$repo_full" --arg title "$issue_title" --arg nr "$issue_number" \
            '.active_prs += [{repo:$repo, issue_number:($nr|fromjson), pr_number:null, title:$title, status:"opened", created_at:(now|todate)}] | .total_contributions += 1 | .total_issues_resolved += 1' <<< "$state")"
        fi

        handled_something=true
      else
        log "Failed to solve issue #$issue_number"
        state="$(jq --arg is "$issue_number" '.consecutive_failures += 1 | .last_error = "Failed to solve issue #\($is)"' <<< "$state")"
      fi
    fi
  fi

  state="$(jq --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '.last_run = $now' <<< "$state")"
  state_save "$state"
  log "Done. State saved."
}

solve_with_opencode() {
  local repo_full="$1"
  local task_description="$2"
  local issue_ref="$3"
  local _pr_varname="$4"
  local ret=0
  shift 4 || true

  log "Solving on $repo_full: $task_description"

  local base_branch
  base_branch="$(fork_detect_default_branch "$repo_full")"
  local fork_remote
  fork_remote="$(fork_prepare "$repo_full" "$base_branch")" || return 1

  local clone_dir
  clone_dir="$(fork_clone_dir "$fork_remote")" || die "Failed to clone fork"
  local branch_name
  branch_name="codevoyager-$(date +%s)"

  cd "$clone_dir"
  git checkout -b "$branch_name"

  local prompt_file
  prompt_file="$(mktemp)"
  local rules_plan
  rules_plan="$(cat "$REPO_DIR/rules.md")"

  opencode_build_prompt "$repo_full" "$task_description" "Issue: $issue_ref" "$branch_name" "$rules_plan" "$base_branch" > "$prompt_file"

  opencode_run "$clone_dir" "$prompt_file" && ret=0 || ret=1

  if [[ $ret -eq 0 && -n "$_pr_varname" ]]; then
    local pr_out
    pr_out="$(opencode_extract_pr_number "/tmp/opencode-$$.out")"
    if [[ -n "$pr_out" ]]; then
      printf -v "$_pr_varname" '%s' "$pr_out"
    fi
  fi

  rm -f "$prompt_file"
  cd "$REPO_DIR"
  rm -rf "$clone_dir"
  return $ret
}

main "$@"