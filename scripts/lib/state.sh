#!/usr/bin/env bash
# State persistence: load/save state.json and memory/*.json
# Depends on: lib/common.sh (log, REPO_DIR)

STATE_FILE="$REPO_DIR/state.json"
MEMORY_DIR="$REPO_DIR/memory"
INTERACTIONS_FILE="$MEMORY_DIR/interactions.json"
PROJECTS_FILE="$MEMORY_DIR/projects.json"

MAX_REPOS_EXPLORED=200

state_init_files() {
  mkdir -p "$MEMORY_DIR"
  [[ -f "$STATE_FILE" ]] || echo '{}' > "$STATE_FILE"
  [[ -f "$INTERACTIONS_FILE" ]] || echo '[]' > "$INTERACTIONS_FILE"
  [[ -f "$PROJECTS_FILE" ]] || echo '[]' > "$PROJECTS_FILE"
}

state_load() {
  state_init_files
  jq '.' "$STATE_FILE"
}

state_save() {
  local new_state="$1"
  printf '%s\n' "$new_state" | jq '.' > "$STATE_FILE"
}

# Write an interaction record to memory/interactions.json
state_record_interaction() {
  local repo="$1"
  local kind="$2"
  local title="$3"
  local status="$4"
  state_init_files
  local entry
  entry="$(jq -n \
    --arg repo "$repo" \
    --arg kind "$kind" \
    --arg title "$title" \
    --arg status "$status" \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{repo:$repo, kind:$kind, title:$title, status:$status, ts:$ts}')"
  local merged
  merged="$(jq --argjson e "$entry" '. + [$e]' "$INTERACTIONS_FILE")"
  printf '%s\n' "$merged" | jq '.' > "$INTERACTIONS_FILE"
}

# Record (or update) a project in memory/projects.json
state_record_project() {
  local repo="$1"
  local lang="${2:-unknown}"
  state_init_files
  local merged
  merged="$(jq --arg repo "$repo" --arg lang "$lang" \
    'map(select(.repo != $repo)) + [{repo:$repo, language:$lang, last_seen:(now|todate)}]' \
    "$PROJECTS_FILE")"
  printf '%s\n' "$merged" | jq '.' > "$PROJECTS_FILE"
}

# Bump a language counter in state.languages_experience
state_bump_language() {
  local state="$1"
  local lang="$2"
  jq --arg lang "$lang" \
    '.languages_experience[$lang] = ((.languages_experience[$lang] // 0) + 1)' \
    <<< "$state"
}

# Push repo into repos_explored with LRU cap (MAX_REPOS_EXPLORED).
state_mark_repo_explored() {
  local state="$1"
  local repo="$2"
  jq --arg repo "$repo" --argjson cap "$MAX_REPOS_EXPLORED" '
    (.repos_explored // []) as $r
    | ($r | index($repo)) as $idx
    | (if $idx != null then $r else $r + [$repo] end) as $r2
    | ($r2 | length) as $len
    | (if $len > $cap then $r2[$len - $cap:] else $r2 end) as $r3
    | .repos_explored = $r3
  ' <<< "$state"
}

state_has_repo_been_explored() {
  local state="$1"
  local repo="$2"
  jq -e --arg repo "$repo" '(.repos_explored // []) | index($repo) != null' <<< "$state" >/dev/null
}
