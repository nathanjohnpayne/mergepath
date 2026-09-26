#!/usr/bin/env bash
# Bind one Codex P1 Gate workflow run to one pull request before a privileged
# workflow_run consumer treats either the run title or its artifact as authority.
#
# Usage: feedback-archive-relay-source.sh <owner/repo> <candidate-pr>
# Input: one GitHub workflow-run JSON object on stdin.
# Output on rc 0: one compact JSON binding whose publish_head_sha came from the
# current pull-request API object.
#
# rc 3: an API read or response shape was indeterminate (the caller may retry).
# rc 4: the run is not positively bound to the candidate (the caller must stay
#       inert with respect to that candidate).

set -euo pipefail

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(CDPATH='' cd -- "$SCRIPT_DIR/../.." && pwd)
ARRAY_HELPER="$ROOT/scripts/lib/gh-api-array.sh"
[ -r "$ARRAY_HELPER" ] || {
  echo "feedback-archive-relay-source: missing $ARRAY_HELPER" >&2
  exit 3
}
# shellcheck source=scripts/lib/gh-api-array.sh
. "$ARRAY_HELPER"

die_infra() {
  echo "feedback-archive-relay-source: $*" >&2
  exit 3
}

reject() {
  echo "feedback-archive-relay-source: source run is not bound: $*" >&2
  exit 4
}

fetch_source_candidates() {  # <endpoint>
  local candidates_file=""
  candidates_file=$(mktemp "${TMPDIR:-/tmp}/relay-source-candidates.XXXXXX" 2>/dev/null) \
    || { echo "feedback-archive-relay-source: could not allocate candidate response file" >&2; return 3; }
  if ! gh_api_array "$1" "pull requests for source branch" >"$candidates_file"; then
    echo "${GH_API_ARRAY_ERROR:-could not read source candidates}" >&2
    rm -f "$candidates_file"
    return 3
  fi
  cat "$candidates_file"
  local rc=$?
  rm -f "$candidates_file"
  return "$rc"
}

[ $# -eq 2 ] || die_infra "usage: feedback-archive-relay-source.sh <owner/repo> <candidate-pr>"
REPO=$1
PR_NUMBER=$2
case "$REPO" in
  */*) ;;
  *) die_infra "repository must be owner/repo" ;;
esac
case "$PR_NUMBER" in
  ''|*[!0-9]*) die_infra "candidate PR must be a positive integer" ;;
esac
[ "$PR_NUMBER" -gt 0 ] || die_infra "candidate PR must be a positive integer"

RUN_JSON=$(cat) || die_infra "could not read source run JSON"
printf '%s' "$RUN_JSON" | jq -e 'type == "object"' >/dev/null 2>&1 \
  || die_infra "source run payload is not a JSON object"

RUN_ID=$(printf '%s' "$RUN_JSON" | jq -r '.id // empty')
DISPLAY_TITLE=$(printf '%s' "$RUN_JSON" | jq -r '.display_title // empty')
SOURCE_EVENT=$(printf '%s' "$RUN_JSON" | jq -r '.event // empty')
SOURCE_PATH=$(printf '%s' "$RUN_JSON" | jq -r '.path // empty')
SOURCE_HEAD=$(printf '%s' "$RUN_JSON" | jq -r '.head_sha // empty')
SOURCE_BRANCH=$(printf '%s' "$RUN_JSON" | jq -r '.head_branch // empty')
SOURCE_REPO_ID=$(printf '%s' "$RUN_JSON" | jq -r '.head_repository.id // empty')
SOURCE_REPO=$(printf '%s' "$RUN_JSON" | jq -r '.head_repository.full_name // empty')
RUN_REPO_ID=$(printf '%s' "$RUN_JSON" | jq -r '.repository.id // empty')
RUN_REPO=$(printf '%s' "$RUN_JSON" | jq -r '.repository.full_name // empty')
RUN_CREATED=$(printf '%s' "$RUN_JSON" | jq -r '.created_at // empty')

case "$RUN_ID" in ''|*[!0-9]*) reject "missing source run id" ;; esac
[ "$RUN_ID" -gt 0 ] || reject "invalid source run id"
[ "$DISPLAY_TITLE" = "Codex P1 Gate relay-v1 PR #$PR_NUMBER" ] \
  || reject "source title does not name the candidate PR"
case "$SOURCE_EVENT" in
  pull_request|pull_request_review|pull_request_review_comment|issue_comment) ;;
  *) reject "unsupported source event" ;;
esac
SOURCE_PATH=${SOURCE_PATH%%@*}
[ "$SOURCE_PATH" = '.github/workflows/codex-p1-gate.yml' ] \
  || reject "unexpected workflow path"
case "$RUN_REPO_ID" in ''|*[!0-9]*) reject "missing source repository id" ;; esac
[ -n "$RUN_REPO" ] || reject "missing source repository name"
[ "$(printf '%s' "$RUN_REPO" | tr '[:upper:]' '[:lower:]')" = \
  "$(printf '%s' "$REPO" | tr '[:upper:]' '[:lower:]')" ] \
  || reject "source run belongs to another repository"
case "$RUN_CREATED" in
  [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z) ;;
  *) reject "missing source creation time" ;;
esac

CACHE_DIR=${MERGEPATH_RELAY_SOURCE_CACHE_DIR:-}
if [ -n "$CACHE_DIR" ] && [ ! -d "$CACHE_DIR" ]; then
  die_infra "relay source cache directory does not exist"
fi
err_file=$(mktemp "${TMPDIR:-/tmp}/relay-source-pr.XXXXXX" 2>/dev/null) \
  || die_infra "could not allocate PR read diagnostic"
trap 'rm -f "$err_file"' EXIT
PR_JSON=""
pr_cache=""
if [ -n "$CACHE_DIR" ]; then
  pr_cache="$CACHE_DIR/pr-$PR_NUMBER.json"
fi
if [ -n "$pr_cache" ] && [ -r "$pr_cache" ]; then
  PR_JSON=$(cat "$pr_cache") || die_infra "could not read cached candidate PR"
else
  pr_rc=0
  PR_JSON=$(gh api "repos/$REPO/pulls/$PR_NUMBER" 2>"$err_file") || pr_rc=$?
  if [ "$pr_rc" -ne 0 ]; then
    if grep -q 'HTTP 404' "$err_file"; then
      reject "candidate is not a pull request"
    fi
    cat "$err_file" >&2
    die_infra "could not read candidate PR"
  fi
fi
printf '%s' "$PR_JSON" | jq -e 'type == "object"' >/dev/null 2>&1 \
  || die_infra "candidate PR response is not an object"
printf '%s' "$PR_JSON" | jq -e '
  (.number | type == "number" and floor == . and . > 0) and
  (.created_at | type == "string" and
    test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")) and
  (.base.repo.id | type == "number" and floor == . and . > 0) and
  (.base.repo.full_name | type == "string" and length > 0) and
  (.base.repo.default_branch | type == "string" and length > 0) and
  (.head.sha | type == "string" and test("^[0-9a-f]{40}$")) and
  (.head.ref | type == "string" and length > 0) and
  ((.head.repo == null) or
    ((.head.repo.id | type == "number" and floor == . and . > 0) and
     (.head.repo.full_name | type == "string" and length > 0) and
     (.head.repo.fork | type == "boolean"))) and
  (.user.login | type == "string" and length > 0)
' >/dev/null 2>&1 || die_infra "candidate PR response is missing authority fields"
if [ -n "$pr_cache" ] && [ ! -e "$pr_cache" ]; then
  if ! printf '%s' "$PR_JSON" >"$pr_cache.next" \
    || ! mv "$pr_cache.next" "$pr_cache"; then
    die_infra "could not cache candidate PR"
  fi
fi

BOUND_NUMBER=$(printf '%s' "$PR_JSON" | jq -r '.number // empty')
BASE_REPO_ID=$(printf '%s' "$PR_JSON" | jq -r '.base.repo.id // empty')
BASE_REPO=$(printf '%s' "$PR_JSON" | jq -r '.base.repo.full_name // empty')
DEFAULT_BRANCH=$(printf '%s' "$PR_JSON" | jq -r '.base.repo.default_branch // empty')
PR_CREATED=$(printf '%s' "$PR_JSON" | jq -r '.created_at // empty')
PR_HEAD=$(printf '%s' "$PR_JSON" | jq -r '.head.sha // empty')
PR_HEAD_REPO_ID=$(printf '%s' "$PR_JSON" | jq -r '.head.repo.id // empty')
PR_HEAD_REPO=$(printf '%s' "$PR_JSON" | jq -r '.head.repo.full_name // empty')
PR_HEAD_BRANCH=$(printf '%s' "$PR_JSON" | jq -r '.head.ref // empty')
PR_ACTOR=$(printf '%s' "$PR_JSON" | jq -r '.user.login // empty')
IS_FORK=$(printf '%s' "$PR_JSON" | jq -r '.head.repo.fork // false')

[ "$BOUND_NUMBER" = "$PR_NUMBER" ] || reject "candidate response number mismatch"
case "$BASE_REPO_ID" in ''|*[!0-9]*) reject "candidate base repository id is missing" ;; esac
[ "$BASE_REPO_ID" = "$RUN_REPO_ID" ] || reject "source and candidate base repository ids differ"
[ "$(printf '%s' "$BASE_REPO" | tr '[:upper:]' '[:lower:]')" = \
  "$(printf '%s' "$REPO" | tr '[:upper:]' '[:lower:]')" ] \
  || reject "candidate base repository differs"
case "$PR_HEAD" in ''|*[!0-9a-f]*) reject "candidate publication head is missing" ;; esac
[ "${#PR_HEAD}" -eq 40 ] || reject "candidate publication head is not a full SHA"
[ -n "$PR_ACTOR" ] || die_infra "candidate actor is missing"

if [ "$SOURCE_EVENT" = issue_comment ]; then
  [ "$SOURCE_REPO_ID" = "$BASE_REPO_ID" ] \
    || reject "issue-comment source repository id differs from the base"
  [ "$(printf '%s' "$SOURCE_REPO" | tr '[:upper:]' '[:lower:]')" = \
    "$(printf '%s' "$REPO" | tr '[:upper:]' '[:lower:]')" ] \
    || reject "issue-comment source repository differs from the base"
  [ -n "$DEFAULT_BRANCH" ] && [ "$SOURCE_BRANCH" = "$DEFAULT_BRANCH" ] \
    || reject "issue-comment source is not on the trusted default branch"
else
  case "$SOURCE_REPO_ID" in ''|*[!0-9]*) reject "missing source head repository id" ;; esac
  [ -n "$SOURCE_REPO" ] || reject "missing source head repository name"
  [ -n "$SOURCE_BRANCH" ] || reject "missing source branch"
  case "$SOURCE_HEAD" in ''|*[!0-9a-f]*) reject "missing source head SHA" ;; esac
  [ "${#SOURCE_HEAD}" -eq 40 ] || reject "source head is not a full SHA"

  [ "$PR_HEAD_REPO_ID" = "$SOURCE_REPO_ID" ] \
    || reject "candidate head repository id differs from the source run"
  [ "$(printf '%s' "$PR_HEAD_REPO" | tr '[:upper:]' '[:lower:]')" = \
    "$(printf '%s' "$SOURCE_REPO" | tr '[:upper:]' '[:lower:]')" ] \
    || reject "candidate head repository differs from the source run"
  [ "$PR_HEAD_BRANCH" = "$SOURCE_BRANCH" ] \
    || reject "candidate branch differs from the source run"
  if [ -z "$PR_CREATED" ] \
    || { [ "$PR_CREATED" != "$RUN_CREATED" ] && [ ! "$PR_CREATED" \< "$RUN_CREATED" ]; }; then
    reject "candidate was created after the source run"
  fi

  ASSOCIATIONS=$(printf '%s' "$RUN_JSON" | jq -c '.pull_requests // []')
  printf '%s' "$ASSOCIATIONS" | jq -e 'type == "array"' >/dev/null 2>&1 \
    || reject "source PR associations are not an array"
  if [ "$(printf '%s' "$ASSOCIATIONS" | jq 'length')" -gt 0 ]; then
    printf '%s' "$ASSOCIATIONS" | jq -e \
      --argjson pr "$PR_NUMBER" --argjson base "$BASE_REPO_ID" \
      --argjson head "$SOURCE_REPO_ID" --arg branch "$SOURCE_BRANCH" '
        any(.[];
          .number == $pr and .base.repo.id == $base and
          .head.repo.id == $head and .head.ref == $branch)
      ' >/dev/null || reject "source PR association contradicts the candidate"
  else
    SOURCE_OWNER=${SOURCE_REPO%%/*}
    [ -n "$SOURCE_OWNER" ] && [ "$SOURCE_OWNER" != "$SOURCE_REPO" ] \
      || reject "source repository owner is missing"
    encoded_head=$(jq -nr --arg value "$SOURCE_OWNER:$SOURCE_BRANCH" '$value | @uri') \
      || die_infra "could not encode source branch query"
    candidates_cache=""
    if [ -n "$CACHE_DIR" ]; then
      if command -v sha256sum >/dev/null 2>&1; then
        candidates_key=$(printf '%s\n%s\n%s\n' "$REPO" "$SOURCE_REPO_ID" "$SOURCE_BRANCH" | sha256sum | awk '{print $1}')
      elif command -v shasum >/dev/null 2>&1; then
        candidates_key=$(printf '%s\n%s\n%s\n' "$REPO" "$SOURCE_REPO_ID" "$SOURCE_BRANCH" | shasum -a 256 | awk '{print $1}')
      else
        die_infra "cannot key the per-invocation source candidate cache"
      fi
      candidates_cache="$CACHE_DIR/origin-$candidates_key.json"
    fi
    if [ -n "$candidates_cache" ] && [ -r "$candidates_cache" ]; then
      CANDIDATES=$(cat "$candidates_cache") \
        || die_infra "could not read cached source candidates"
      printf '%s' "$CANDIDATES" | jq -e 'type == "array"' >/dev/null 2>&1 \
        || die_infra "cached source candidates are not an array"
    else
      CANDIDATES=$(fetch_source_candidates \
        "repos/$REPO/pulls?state=all&head=$encoded_head&per_page=100") \
        || exit 3
      if [ -n "$candidates_cache" ]; then
        if ! printf '%s' "$CANDIDATES" >"$candidates_cache.next" \
          || ! mv "$candidates_cache.next" "$candidates_cache"; then
          die_infra "could not cache source candidates"
        fi
      fi
    fi
    printf '%s' "$CANDIDATES" | jq -e '
      type == "array" and all(.[];
        (.number | type == "number" and floor == . and . > 0) and
        (.created_at | type == "string" and
          test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")) and
        (.base.repo.id | type == "number" and floor == . and . > 0) and
        (.head.ref | type == "string" and length > 0) and
        ((.head.repo == null) or
          (.head.repo.id | type == "number" and floor == . and . > 0)))
    ' >/dev/null 2>&1 || die_infra "source candidate list is missing authority fields"
    MATCHES=$(printf '%s' "$CANDIDATES" | jq -c \
      --argjson base "$BASE_REPO_ID" --argjson head "$SOURCE_REPO_ID" \
      --arg branch "$SOURCE_BRANCH" --arg created "$RUN_CREATED" '
        [ .[]
          | select(.base.repo.id == $base and .head.repo.id == $head and
              .head.ref == $branch and
              ((.created_at // "") != "") and .created_at <= $created) ]
      ') || die_infra "could not filter source branch candidates"
    [ "$(printf '%s' "$MATCHES" | jq 'length')" -eq 1 ] \
      || reject "source branch does not identify exactly one historical PR"
    [ "$(printf '%s' "$MATCHES" | jq -r '.[0].number')" = "$PR_NUMBER" ] \
      || reject "unique source branch candidate differs from the title candidate"
  fi
fi

REQUIRES_RELAY=$IS_FORK
if [ "$PR_ACTOR" = 'dependabot[bot]' ]; then
  REQUIRES_RELAY=true
fi

jq -nc \
  --argjson pr "$PR_NUMBER" --argjson run "$RUN_ID" \
  --arg event "$SOURCE_EVENT" --arg source_head "$SOURCE_HEAD" \
  --argjson source_repo_id "${SOURCE_REPO_ID:-null}" \
  --arg source_repo "$SOURCE_REPO" --arg source_branch "$SOURCE_BRANCH" \
  --arg publish_head "$PR_HEAD" --argjson base_repo_id "$BASE_REPO_ID" \
  --arg actor "$PR_ACTOR" --argjson is_fork "$IS_FORK" \
  --argjson requires_relay "$REQUIRES_RELAY" '
    {
      pr:$pr, source_run_id:$run, source_event:$event,
      source_head_sha:$source_head, source_repository_id:$source_repo_id,
      source_repository:$source_repo, source_branch:$source_branch,
      publish_head_sha:$publish_head, base_repository_id:$base_repo_id,
      pr_actor:$actor, is_fork:$is_fork, requires_relay:$requires_relay
    }
  '
