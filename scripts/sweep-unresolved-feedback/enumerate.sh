#!/usr/bin/env bash
# scripts/sweep-unresolved-feedback/enumerate.sh
#
# Enumerate unresolved review threads on recently-closed PRs across a
# configured list of target repos. Emits one JSON object per finding to
# stdout (newline-delimited JSON), suitable for piping into
# render.sh.
#
# Design (#236):
#
#   This is the v1 of the post-merge feedback sweep — a defense-in-
#   depth catch-net for review feedback that slipped past the merge
#   gate. The companion script render.sh consumes this stream and
#   manages the per-repo rollup issue (idempotent: posts a delta
#   comment to an existing issue rather than creating a new one each
#   week).
#
# Output schema (one JSON object per line, NDJSON):
#   {
#     "repo":          "owner/repo",
#     "pr_number":     123,
#     "pr_title":      "...",
#     "pr_url":        "https://github.com/owner/repo/pull/123",
#     "thread_id":     "PRT_kw...",
#     "author_login":  "coderabbitai[bot]",
#     "body_excerpt":  "first 200 chars of the comment body, single line",
#     "severity":      "P0|P1|P2|P3|Critical|Major|Minor|Nitpick|Unknown",
#     "thread_url":    "https://github.com/owner/repo/pull/123#discussion_r..."
#   }
#
# Filter: isResolved == false AND isOutdated == false.
#
# Inputs:
#   $1 (optional) path to target-repos file (default: target-repos.txt
#                 alongside this script).
#
# Environment:
#   GH_TOKEN                  required. Read-path call; PAT must have
#                             pull-request read on every target repo.
#                             In CI: secrets.REVIEWER_ASSIGNMENT_TOKEN
#                             via the workflow's env: block.
#   SWEEP_LOOKBACK_DAYS       window for closed PRs (default 90).
#   SWEEP_OUTPUT              optional output path (default stdout).
#   SWEEP_MAX_PRS_PER_REPO    safety cap (default 200). Prevents a
#                             pathologically active repo from blowing
#                             up the cron runner. Hits stderr if
#                             exceeded; CI green still.
#
# Exit codes:
#   0   success (zero or more findings emitted)
#   1   setup error (config file missing, GH_TOKEN unset, dependency
#       missing)
#   2   API error (gh exited non-zero, GraphQL errors)
#
# Bash 3.2 compatible (macOS default + ubuntu-latest).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGETS_FILE="${1:-$SCRIPT_DIR/target-repos.txt}"

if [ ! -f "$TARGETS_FILE" ]; then
  echo "enumerate: target repos file not found: $TARGETS_FILE" >&2
  exit 1
fi

if [ -z "${GH_TOKEN:-}" ]; then
  echo "enumerate: GH_TOKEN not set. Set GH_TOKEN to a PAT with pull-request read on every target repo." >&2
  exit 1
fi

for dep in gh jq; do
  if ! command -v "$dep" >/dev/null 2>&1; then
    echo "enumerate: required dependency missing: $dep" >&2
    exit 1
  fi
done

LOOKBACK_DAYS="${SWEEP_LOOKBACK_DAYS:-90}"
MAX_PRS_PER_REPO="${SWEEP_MAX_PRS_PER_REPO:-200}"
OUTPUT="${SWEEP_OUTPUT:-/dev/stdout}"

# Cut-off date in ISO-8601 (UTC). BSD date (macOS) and GNU date have
# divergent flag syntax — try GNU first, fall back to BSD.
if date -u -d "@0" '+%Y-%m-%d' >/dev/null 2>&1; then
  SINCE=$(date -u -d "${LOOKBACK_DAYS} days ago" '+%Y-%m-%dT%H:%M:%SZ')
else
  SINCE=$(date -u -v-"${LOOKBACK_DAYS}"d '+%Y-%m-%dT%H:%M:%SZ')
fi

echo "enumerate: scanning closed PRs since $SINCE (lookback=${LOOKBACK_DAYS}d)" >&2

# Severity heuristic. Anchored, case-insensitive. Order matters — pick
# the highest severity that matches. Look only at the first ~400 chars
# of the body to avoid matching the severity word in a quoted prior
# review.
classify_severity() {
  # arg 1: body text (already trimmed)
  local body_head
  body_head=${1:0:400}
  case "$body_head" in
    *[Pp]0*|*Critical*|*CRITICAL*) echo "P0"; return ;;
    *[Pp]1*|*Major*|*MAJOR*|*"Potential issue"*|*"⚠️"*) echo "P1"; return ;;
    *[Pp]2*|*Minor*|*MINOR*) echo "P2"; return ;;
    *[Pp]3*|*Nitpick*|*"🧹"*|*Trivial*|*"🔵"*) echo "P3"; return ;;
  esac
  echo "Unknown"
}

emit_findings_for_repo() {
  local repo="$1"
  local owner name
  owner="${repo%%/*}"
  name="${repo##*/}"

  echo "enumerate: scanning $repo" >&2

  # List closed PRs in the lookback window via the search API. Use
  # --search instead of --state because the latter ignores `closed:>=`
  # filtering. Cap at MAX_PRS_PER_REPO to bound the runtime.
  local prs_json
  if ! prs_json=$(gh pr list \
      --repo "$repo" \
      --state closed \
      --search "closed:>=$SINCE" \
      --limit "$MAX_PRS_PER_REPO" \
      --json number,title,url 2>/dev/null); then
    echo "enumerate: WARN gh pr list failed for $repo (skipping)" >&2
    return 0
  fi

  local pr_count
  pr_count=$(printf '%s' "$prs_json" | jq 'length')
  echo "enumerate:   $pr_count closed PRs in window" >&2

  # Iterate PRs. For each, query reviewThreads. Filter unresolved AND
  # not-outdated. Emit one NDJSON line per surviving comment.
  local i=0
  while [ "$i" -lt "$pr_count" ]; do
    local pr_number pr_title pr_url
    pr_number=$(printf '%s' "$prs_json" | jq -r ".[$i].number")
    pr_title=$(printf '%s' "$prs_json" | jq -r ".[$i].title")
    pr_url=$(printf '%s' "$prs_json" | jq -r ".[$i].url")
    i=$((i + 1))

    local threads_json
    if ! threads_json=$(gh api graphql -f query='
      query($owner:String!,$name:String!,$pr:Int!) {
        repository(owner:$owner, name:$name) {
          pullRequest(number:$pr) {
            reviewThreads(first: 100) {
              totalCount
              pageInfo { hasNextPage endCursor }
              nodes {
                id
                isResolved
                isOutdated
                comments(first: 1) {
                  nodes {
                    author { login }
                    body
                    url
                  }
                }
              }
            }
          }
        }
      }' \
      -F owner="$owner" -F name="$name" -F pr="$pr_number" 2>/dev/null); then
      echo "enumerate: WARN GraphQL threads query failed for $repo#$pr_number (skipping)" >&2
      continue
    fi

    local has_next
    has_next=$(printf '%s' "$threads_json" | jq -r '.data.repository.pullRequest.reviewThreads.pageInfo.hasNextPage // false')
    if [ "$has_next" = "true" ]; then
      # >100 threads on a single PR — log and proceed with the page we
      # have. v1 doesn't paginate; in practice this is rare and the 100
      # most-recent threads are what matters anyway.
      echo "enumerate: WARN $repo#$pr_number has >100 review threads; sweep examined first page only" >&2
    fi

    # Emit one NDJSON line per unresolved & not-outdated thread.
    # Build via jq so quoting/escaping is correct, then post-process
    # body_excerpt and severity in shell (jq can't easily do the
    # severity heuristic without verbose case logic).
    local thread_blob
    thread_blob=$(printf '%s' "$threads_json" | jq -c '
      .data.repository.pullRequest.reviewThreads.nodes[]
      | select(.isResolved == false and .isOutdated == false)
      | select(.comments.nodes | length > 0)
      | {
          thread_id: .id,
          author_login: (.comments.nodes[0].author.login // "unknown"),
          body: (.comments.nodes[0].body // ""),
          thread_url: (.comments.nodes[0].url // "")
        }
    ')

    if [ -z "$thread_blob" ]; then
      continue
    fi

    # Iterate per-line so we can compute severity in shell. jq's -c
    # mode already emits one object per line.
    printf '%s\n' "$thread_blob" | while IFS= read -r line; do
      [ -z "$line" ] && continue
      local thread_id author_login body thread_url
      thread_id=$(printf '%s' "$line" | jq -r '.thread_id')
      author_login=$(printf '%s' "$line" | jq -r '.author_login')
      body=$(printf '%s' "$line" | jq -r '.body')
      thread_url=$(printf '%s' "$line" | jq -r '.thread_url')

      # body_excerpt: first 200 chars, single-line, trimmed.
      local body_excerpt single_line_body
      single_line_body=${body//$'\n'/ }
      single_line_body=${single_line_body//$'\r'/ }
      single_line_body=${single_line_body//$'\t'/ }
      body_excerpt=${single_line_body:0:200}

      local severity
      severity=$(classify_severity "$body")

      # Emit final JSON via jq -nc so the string escaping is correct.
      jq -nc \
        --arg repo "$repo" \
        --argjson pr_number "$pr_number" \
        --arg pr_title "$pr_title" \
        --arg pr_url "$pr_url" \
        --arg thread_id "$thread_id" \
        --arg author_login "$author_login" \
        --arg body_excerpt "$body_excerpt" \
        --arg severity "$severity" \
        --arg thread_url "$thread_url" \
        '{
          repo:         $repo,
          pr_number:    $pr_number,
          pr_title:     $pr_title,
          pr_url:       $pr_url,
          thread_id:    $thread_id,
          author_login: $author_login,
          body_excerpt: $body_excerpt,
          severity:     $severity,
          thread_url:   $thread_url
        }' >> "$OUTPUT"
    done
  done
}

# Truncate output file if it's a regular path (not /dev/stdout). This
# makes the script safe to re-run.
case "$OUTPUT" in
  /dev/stdout|-) : ;;
  *) : > "$OUTPUT" ;;
esac

# Read targets, skipping blanks and comments.
while IFS= read -r line; do
  line=$(printf '%s' "$line" | sed -E 's/[[:space:]]+$//')
  case "$line" in
    ''|\#*) continue ;;
  esac
  emit_findings_for_repo "$line"
done < "$TARGETS_FILE"

echo "enumerate: done" >&2
exit 0
