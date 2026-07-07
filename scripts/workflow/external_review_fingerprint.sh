#!/usr/bin/env bash
set -euo pipefail

# Compute a stable fingerprint for the content that makes a PR require
# external review. The fingerprint is intentionally based on tree object IDs at
# a chosen ref, not on the head SHA, so a pure base-merge/update-branch that
# leaves the reviewed diff byte-identical keeps the same fingerprint.
#
# Inputs:
#   --repo owner/repo
#   --pr <number>
#   --ref <sha-or-ref>
#   --config <path>          default: .github/review-policy.yml
#   --files-json <path>      optional current PR files JSON fixture/cache
#
# Output: JSON:
#   {
#     "requires_review": true|false,
#     "fingerprint": "external-review:v2:<sha256>" | "",
#     "fingerprint_paths": ["..."],
#     "lines_changed": 123,
#     "threshold": 300,
#     "protected_paths": ["..."],
#     "reasons": ["..."]
#   }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG=".github/review-policy.yml"
REPO=""
PR_NUMBER=""
REF=""
FILES_JSON_PATH=""

usage() {
  cat >&2 <<'EOF'
usage: external_review_fingerprint.sh --repo owner/repo --pr N --ref SHA [--config path] [--files-json path]
EOF
  exit 2
}

while [ $# -gt 0 ]; do
  case "$1" in
    --repo)
      [ $# -ge 2 ] || usage
      REPO="$2"; shift 2 ;;
    --pr)
      [ $# -ge 2 ] || usage
      PR_NUMBER="$2"; shift 2 ;;
    --ref)
      [ $# -ge 2 ] || usage
      REF="$2"; shift 2 ;;
    --config)
      [ $# -ge 2 ] || usage
      CONFIG="$2"; shift 2 ;;
    --files-json)
      [ $# -ge 2 ] || usage
      FILES_JSON_PATH="$2"; shift 2 ;;
    -h|--help)
      usage ;;
    *)
      echo "external_review_fingerprint.sh: unknown arg: $1" >&2
      usage ;;
  esac
done

[ -n "$REPO" ] || usage
[ -n "$PR_NUMBER" ] || usage
[ -n "$REF" ] || usage
[[ "$PR_NUMBER" =~ ^[0-9]+$ ]] || { echo "external_review_fingerprint.sh: --pr must be an integer" >&2; exit 2; }
[ -f "$CONFIG" ] || { echo "external_review_fingerprint.sh: config not found: $CONFIG" >&2; exit 2; }

PARSE="$SCRIPT_DIR/parse_policy_list.sh"
MATCH="$SCRIPT_DIR/match_protected_paths.sh"
[ -f "$PARSE" ] || { echo "external_review_fingerprint.sh: missing parser: $PARSE" >&2; exit 2; }
[ -f "$MATCH" ] || { echo "external_review_fingerprint.sh: missing matcher: $MATCH" >&2; exit 2; }

if ! command -v jq >/dev/null 2>&1; then
  echo "external_review_fingerprint.sh: jq is required" >&2
  exit 2
fi

sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | awk '{print $1}'
  else
    echo "external_review_fingerprint.sh: sha256sum or shasum is required" >&2
    exit 2
  fi
}

# Run a gh invocation with stdout and stderr captured separately, so a
# stderr warning/notice on an otherwise-successful call can't leak into
# the stdout stream that callers parse as JSON with jq (#715). On
# failure, stdout+stderr are combined into the returned text (for the
# caller's error message) and the real gh exit code is preserved — a
# genuine gh failure still fails closed. Same fix applied to
# external_review_carryforward.sh (#716); kept as a small duplicated
# helper since the two scripts run as separate processes (same pattern
# as fetch_api_array in codex-review-check.sh / codex-review-request.sh).
gh_api_capture() {
  local err_file rc=0 out
  err_file=$(mktemp "${TMPDIR:-/tmp}/external-review-gh-err.XXXXXX") || {
    "$@" 2>&1
    return $?
  }
  out=$("$@" 2>"$err_file") || rc=$?
  if [ "$rc" -ne 0 ]; then
    out="$out
$(cat "$err_file" 2>/dev/null)"
  fi
  rm -f "$err_file"
  printf '%s' "$out"
  return "$rc"
}

tree_for_ref() {
  local ref="$1"
  local tree_ref="$ref"
  local commit_json commit_rc commit_tree tree_json

  set +e
  commit_json=$(gh api "repos/$REPO/commits/$ref" 2>/dev/null)
  commit_rc=$?
  set -e
  if [ "$commit_rc" -eq 0 ]; then
    commit_tree=$(printf '%s' "$commit_json" | jq -r '.commit.tree.sha // ""')
    [ -z "$commit_tree" ] || tree_ref="$commit_tree"
  fi

  tree_json=$(gh_api_capture gh api "repos/$REPO/git/trees/$tree_ref?recursive=1") || {
    echo "external_review_fingerprint.sh: failed to fetch tree for $ref (tree $tree_ref): $tree_json" >&2
    return 2
  }

  if [ "$(printf '%s' "$tree_json" | jq -r '.truncated // false')" = "true" ]; then
    echo "external_review_fingerprint.sh: tree for $ref (tree $tree_ref) is truncated; refusing to fingerprint incompletely" >&2
    return 2
  fi

  printf '%s' "$tree_json"
}

entries_for_tree() {
  local tree_json="$1"
  printf '%s' "$tree_json" | jq -c --argjson paths "$FINGERPRINT_PATHS_JSON" '
    (.tree
      | map(select(.path as $p | $paths | index($p)))
      | map({key: .path, value: {type: .type, mode: .mode, oid: .sha}})
      | from_entries) as $tree
    | [ $paths[] as $p
        | if $tree[$p] then
            {path: $p, state: "present", type: $tree[$p].type, mode: $tree[$p].mode, oid: $tree[$p].oid}
          else
            {path: $p, state: "absent", type: null, mode: null, oid: null}
          end
      ]
  '
}

if [ -n "$FILES_JSON_PATH" ]; then
  [ -f "$FILES_JSON_PATH" ] || { echo "external_review_fingerprint.sh: files JSON not found: $FILES_JSON_PATH" >&2; exit 2; }
  FILES_JSON=$(jq -c '.' "$FILES_JSON_PATH") || {
    echo "external_review_fingerprint.sh: files JSON does not parse: $FILES_JSON_PATH" >&2
    exit 2
  }
else
  RAW_FILES=$(gh_api_capture gh api --paginate "repos/$REPO/pulls/$PR_NUMBER/files") || {
    echo "external_review_fingerprint.sh: failed to fetch PR files: $RAW_FILES" >&2
    exit 2
  }
  FILES_JSON=$(printf '%s\n' "$RAW_FILES" | jq -c -s 'add // []') || {
    echo "external_review_fingerprint.sh: failed to flatten PR files pagination" >&2
    exit 2
  }
fi

THRESHOLD=$(grep -E '^external_review_threshold:' "$CONFIG" 2>/dev/null | awk '{print $2}' || true)
THRESHOLD=${THRESHOLD:-300}
if ! [[ "$THRESHOLD" =~ ^[0-9]+$ ]]; then
  THRESHOLD=300
fi

EXCLUDE_RE='(\.lock$)|(lock\.json$)|(\.min\.js$)|(\.min\.css$)|(\.generated\.)|(\.g\.dart$)|(\.freezed\.dart$)'
FILES_COUNT=$(printf '%s' "$FILES_JSON" | jq 'length')
FILES_COUNT=${FILES_COUNT:-0}

LINES_CHANGED=$(printf '%s' "$FILES_JSON" | jq --arg re "$EXCLUDE_RE" '
  [ .[]
    | select((.filename | test($re)) | not)
    | ((.additions // 0) + (.deletions // 0)) ]
  | add // 0
')
LINES_CHANGED=${LINES_CHANGED:-0}

ALL_CHANGED_FILES=$(printf '%s' "$FILES_JSON" | jq -r '
  .[] | .filename
')

PATHS=$(bash "$PARSE" "$CONFIG" external_review_paths)
MATCHED_FILES=""
if [ -n "$PATHS" ]; then
  PATTERNS=()
  while IFS= read -r line; do
    [ -n "$line" ] && PATTERNS+=("$line")
  done <<<"$PATHS"
  if [ "${#PATTERNS[@]}" -gt 0 ]; then
    ALL_FILES=$(printf '%s' "$FILES_JSON" | jq -r '.[].filename')
    MATCHED_FILES=$(printf '%s\n' "$ALL_FILES" | bash "$MATCH" "${PATTERNS[@]}")
  fi
fi

REQUIRES_REVIEW=false
REASONS=()
FINGERPRINT_INPUT=""

if [ "$FILES_COUNT" -ge 3000 ]; then
  REQUIRES_REVIEW=true
  REASONS+=("PR files API returned ${FILES_COUNT} files; treating as external review required because GitHub may have capped the diff")
fi

if [ "$LINES_CHANGED" -ge "$THRESHOLD" ]; then
  REQUIRES_REVIEW=true
  REASONS+=("${LINES_CHANGED} lines changed >= threshold ${THRESHOLD}")
fi

if [ -n "$MATCHED_FILES" ]; then
  REQUIRES_REVIEW=true
  PROTECTED_SUMMARY=$(printf '%s\n' "$MATCHED_FILES" | LC_ALL=C sort -u | tr '\n' ' ' | sed 's/[[:space:]]*$//')
  REASONS+=("protected paths modified: ${PROTECTED_SUMMARY}")
fi

PROTECTED_JSON=$(printf '%s\n' "$MATCHED_FILES" | LC_ALL=C sort -u | jq -R -s -c 'split("\n") | map(select(length > 0))')
REASONS_JSON=$(printf '%s\n' "${REASONS[@]:-}" | jq -R -s -c 'split("\n") | map(select(length > 0))')

if [ "$FILES_COUNT" -ge 3000 ]; then
  jq -n \
    --argjson requires true \
    --arg fingerprint "" \
    --argjson paths '[]' \
    --argjson protected "$PROTECTED_JSON" \
    --argjson reasons "$REASONS_JSON" \
    --argjson lines "$LINES_CHANGED" \
    --argjson threshold "$THRESHOLD" \
    '{requires_review:$requires, fingerprint:$fingerprint, fingerprint_paths:$paths, lines_changed:$lines, threshold:$threshold, protected_paths:$protected, reasons:$reasons}'
  exit 0
fi

if [ "$REQUIRES_REVIEW" != "true" ]; then
  jq -n \
    --argjson requires false \
    --arg fingerprint "" \
    --argjson paths '[]' \
    --argjson protected "$PROTECTED_JSON" \
    --argjson reasons "$REASONS_JSON" \
    --argjson lines "$LINES_CHANGED" \
    --argjson threshold "$THRESHOLD" \
    '{requires_review:$requires, fingerprint:$fingerprint, fingerprint_paths:$paths, lines_changed:$lines, threshold:$threshold, protected_paths:$protected, reasons:$reasons}'
  exit 0
fi

FINGERPRINT_INPUT="$ALL_CHANGED_FILES"$'\n'
FINGERPRINT_PATHS_JSON=$(printf '%s\n' "$FINGERPRINT_INPUT" | LC_ALL=C sort -u | jq -R -s -c 'split("\n") | map(select(length > 0))')

HEAD_TREE_JSON=$(tree_for_ref "$REF") || exit 2
HEAD_ENTRIES_JSON=$(entries_for_tree "$HEAD_TREE_JSON")

PR_BASE_SHA=$(gh api "repos/$REPO/pulls/$PR_NUMBER" --jq .base.sha 2>/dev/null || true)
if [ -z "$PR_BASE_SHA" ]; then
  echo "external_review_fingerprint.sh: failed to resolve PR base sha for $REPO#$PR_NUMBER" >&2
  exit 2
fi

MERGE_BASE_SHA=$(gh api "repos/$REPO/compare/$PR_BASE_SHA...$REF" --jq '.merge_base_commit.sha // ""' 2>/dev/null || true)
if [ -z "$MERGE_BASE_SHA" ]; then
  echo "external_review_fingerprint.sh: failed to resolve merge base for $REF against PR base $PR_BASE_SHA" >&2
  exit 2
fi
BASE_TREE_JSON=$(tree_for_ref "$MERGE_BASE_SHA") || exit 2
BASE_ENTRIES_JSON=$(entries_for_tree "$BASE_TREE_JSON")

CANONICAL=$(jq -S -c -n \
  --arg version "external-review-fingerprint:v2" \
  --argjson head_entries "$HEAD_ENTRIES_JSON" \
  --argjson base_entries "$BASE_ENTRIES_JSON" \
  '{version:$version, head_entries:$head_entries, base_entries:$base_entries}')
HASH=$(printf '%s' "$CANONICAL" | sha256)
FINGERPRINT="external-review:v2:$HASH"

jq -n \
  --argjson requires true \
  --arg fingerprint "$FINGERPRINT" \
  --argjson paths "$FINGERPRINT_PATHS_JSON" \
  --argjson protected "$PROTECTED_JSON" \
  --argjson reasons "$REASONS_JSON" \
  --argjson lines "$LINES_CHANGED" \
  --argjson threshold "$THRESHOLD" \
  '{requires_review:$requires, fingerprint:$fingerprint, fingerprint_paths:$paths, lines_changed:$lines, threshold:$threshold, protected_paths:$protected, reasons:$reasons}'
