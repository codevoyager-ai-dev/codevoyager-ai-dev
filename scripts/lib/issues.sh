#!/usr/bin/env bash
# search issues on GitHub (proactive discovery)
# Depends on: lib/common.sh

# Supported languages; each emitted as its own `language:X` term joined with OR.
CV_LANGUAGES=(python javascript typescript go rust java kotlin)

issues_search() {
  log "Searching for issues to solve..."
  local lang_query=""
  local first=1
  for l in "${CV_LANGUAGES[@]}"; do
    if [[ $first -eq 1 ]]; then
      lang_query="language:$l"
      first=0
    else
      lang_query="$lang_query OR language:$l"
    fi
  done

  gh search issues \
    --label "good first issue" \
    --state open \
    --sort updated \
    --limit 30 \
    --json repository,number,title,url,body \
    -- "$lang_query" 2>/dev/null || echo "[]"
}

# Pick first issue whose repo we have not explored yet.
# Normalizes `repository` (which can be either an object {nameWithOwner}
# or, in some gh versions, a plain string) before filtering.
issues_pick_best() {
  local issues_json="$1"
  local state="$2"

  jq -r --argjson state "$state" '
    def norm_repo(r):
      r | if   type == "object" then (.nameWithOwner // .full_name // .name // null)
           elif type == "string" then .
           else null end;
    (. // [])
      | map(.repository = norm_repo(.repository))
      | map(select(.repository != null))
      | map(select((($state.repos_explored // []) | index(.repository)) == null))
      | (first // null)
      | if . == null then empty else . end
  ' <<< "$issues_json"
}
