# shellcheck shell=bash
# Shared runtime comment guard for the token-verifying wrappers (#2158).
# Sourcing defines functions only; every payload file is private and ephemeral.
gh_comment_guard_prepare() {
  local argument
  GH_COMMENT_GUARD_ARGS=("$@")
  GH_COMMENT_GUARD_STATE=$(mktemp -d "${TMPDIR:-/tmp}/gh-comment-guard.XXXXXX") || return 1
  chmod 700 "$GH_COMMENT_GUARD_STATE" || return 1
  python3 "$ROOT/scripts/workflow/gh-comment-trigger-guard.py" \
    --role "$GH_COMMENT_GUARD_ROLE" --state-dir "$GH_COMMENT_GUARD_STATE" -- "$@" || return 1
  GH_COMMENT_GUARD_ARGS=()
  while IFS= read -r -d '' argument; do
    GH_COMMENT_GUARD_ARGS+=("$argument")
  done < "$GH_COMMENT_GUARD_STATE/argv"
}

# Preserve the REST transport's existing materialized-file-only CLI grammar.
# Raw API stdin remains a separate documented transport form.
gh_comment_guard_check_transport() {
  local cli_stdin
  if [ "$1" != rest ]; then return 0; fi
  cli_stdin=$(jq -er '(.cli_stdin // false) | if type == "boolean" then tostring else error("invalid stdin metadata") end' \
    "$GH_COMMENT_GUARD_STATE/metadata.json") || return 1
  if [ "$cli_stdin" = true ]; then
    echo "comment-trigger-guard: the REST transport accepts exactly a materialized body file; write stdin to a file first." >&2
    return 1
  fi
}

gh_comment_guard_authorize() {
  local metadata="$GH_COMMENT_GUARD_STATE/metadata.json" repo pr head result trigger
  trigger=$(jq -er '.trigger | if type == "boolean" then tostring else error("invalid trigger metadata") end' \
    "$metadata") || return 1
  if [ "$trigger" = false ]; then return 0; fi
  repo=$(jq -er .repo "$metadata") && pr=$(jq -er .pr "$metadata") && head=$(jq -er .head "$metadata") || return 1
  result=$(MERGEPATH_PHASE_4A_GATED=true MERGEPATH_CODEX_TRIGGER_EXPECTED_HEAD="$head" \
    GH_TOKEN="${OP_PREFLIGHT_REVIEWER_PAT:-$TOKEN}" \
    "$ROOT/scripts/codex-review-request.sh" --authorize-trigger-write --allow-moving-head "$pr" "$repo") || return 1
  printf '%s' "$result" | jq -e --arg repo "$repo" --argjson pr "$pr" --arg head "$head" --arg author "$AUTHOR" \
    '.authorized == true and .repo == $repo and .pr_number == $pr and .head_sha == $head and .author_identity == $author' >/dev/null
}

gh_comment_guard_cleanup() {
  [ -z "${GH_COMMENT_GUARD_STATE:-}" ] || python3 - "$GH_COMMENT_GUARD_STATE" <<'PY'
import shutil, sys
shutil.rmtree(sys.argv[1])
PY
}
