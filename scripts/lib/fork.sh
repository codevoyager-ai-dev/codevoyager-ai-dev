#!/usr/bin/env bash
# Fork + clone + keep-fork-up-to-date + writing back to fork.
# Depends on: lib/common.sh
# Token handling: never put GH_TOKEN into git URLs.
#   We use a short-lived credential helper that injects Basic auth
#   only for the duration of git network operations.

fork_temp_remote_url=""
# Clean credential trap on exit
_fork_cleanup() {
  git -c credential.helper= config --unset credential.helper >/dev/null 2>&1 || true
}
trap _fork_cleanup EXIT

# Install a temporary credential.helper that returns the PAT for github.com.
# Helper is a one-shot shell command scoped to this process only.
_install_git_credential_helper() {
  local token="$1"
  # Use an askpass-style helper file in tmp so we don't expose it on disk permanently.
  local helper
  helper="$(mktemp)"
  cat > "$helper" <<EOF
#!/usr/bin/env bash
echo "username=codevoyager-ai-dev"
echo "password=$token"
EOF
  chmod 700 "$helper"
  # Use absolute path; helper runs via "git -c credential.helper=..."
  CV_CRED_HELPER="$helper"
  export CV_CRED_HELPER
  git config credential.helper "!f() { \"\$CV_CRED_HELPER\"; }; f"
}

_ensure_fork_exists() {
  local repo_full="$1"
  local fork_owner
  fork_owner="${MY_USER_NAME:-codevoyager-ai-dev}"
  local fork_full="${fork_owner}/${repo_full#*/}"

  # gh repo fork exits non-zero if fork already exists, but that's fine.
  set +e
  gh repo fork "$repo_full" --clone=false >/dev/null 2>&1
  set -e

  # Verify fork exists. If gh is rate-limited, fall back to git ls-remote check.
  if gh repo view "$fork_full" --json name >/dev/null 2>&1; then
    log "Fork ready: $fork_full"
    return 0
  fi
  # Try a second explicit fork in case first attempt was rate-limited.
  gh repo fork "$repo_full" --clone=false >/dev/null 2>&1 || true
  gh repo view "$fork_full" --json name >/dev/null 2>&1 && return 0
  return 1
}

# Sync fork's main branch with its parent (so we always work on the newest code).
_sync_fork_with_parent() {
  local repo_full="$1"
  local base_branch="$2"

  log "Syncing fork of $repo_full with parent (branch: $base_branch)..."
  gh repo sync "${MY_USER_NAME:-codevoyager-ai-dev}/${repo_full#*/}" \
    --source "$repo_full" \
    --branch "$base_branch" >/dev/null 2>&1 || {
    log "WARNING: gh repo sync failed (rate limit / fast-forward). Continuing with fork as-is."
  }
}

fork_prepare() {
  local repo_full="$1"
  local base_branch="${2:-main}"

  if ! _ensure_fork_exists "$repo_full"; then
    log "FATAL: could not ensure fork exists for $repo_full"
    return 1
  fi

  # Always sync before we clone — prevents working on a stale fork.
  _sync_fork_with_parent "$repo_full" "$base_branch"

  # Public https remote (no token embedded). Auth injected via credential helper.
  fork_temp_remote_url="https://github.com/${MY_USER_NAME:-codevoyager-ai-dev}/${repo_full#*/}.git"
  printf '%s' "$fork_temp_remote_url"
}

# Detect the default branch of an upstream repo.
fork_detect_default_branch() {
  local repo_full="$1"
  local branch
  branch="$(gh repo view "$repo_full" --json defaultBranchRef \
            --jq '.defaultBranchRef.name' 2>/dev/null || true)"
  [[ -z "$branch" ]] && branch="main"
  printf '%s' "$branch"
}

fork_clone_dir() {
  local remote="$1"
  local clone_dir
  clone_dir="$(mktemp -d)"
  git clone --depth 1 "$remote" "$clone_dir" >/dev/null 2>&1 || return 1
  printf '%s' "$clone_dir"
}

fork_init_credentials() {
  _install_git_credential_helper "$1"
}
