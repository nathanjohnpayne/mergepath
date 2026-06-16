#!/usr/bin/env bash
# scripts/codex-p1-gate.sh — Codex P1 unresolved-thread merge gate
#
# Reports "Codex P1 unresolved: N" for a pull request and fails (exit 1)
# when N > 0. Read-only. Never merges, labels, or comments.
#
# Context: per nathanjohnpayne/mergepath#235, the 2026-05-13 sweep of
# unresolved reviewer feedback (#234) found 62 Codex P1 items sitting
# on merged PRs across 9 repos. P1 is Codex's "blocking" severity tag;
# 62 P1s riding through to closed state is evidence that the label was
# advisory, not enforced. This script is the v1 enforcement.
#
# Usage:
#   scripts/codex-p1-gate.sh <PR_NUMBER> [REPO]
#   scripts/codex-p1-gate.sh                       # env-only mode
#
# Arguments:
#   PR_NUMBER  Required (positional or via $PR_NUMBER env). Integer.
#   REPO       Optional. "owner/repo". Falls back to $REPO env, then
#              to the current repo via `gh repo view`.
#
# Environment:
#   GH_TOKEN   Required. Needs pull_requests:read.
#   PR_NUMBER  Optional fallback for the positional arg. The
#              scheduled-sweep job in .github/workflows/codex-p1-
#              gate.yml passes PR_NUMBER positionally per iteration,
#              but other callers (workflow_dispatch, ad-hoc CLI use,
#              CI matrix jobs) may find it easier to set it as env.
#   REPO       Optional fallback for the positional REPO arg. Same
#              motivation as PR_NUMBER above.
#
# Algorithm:
#   1. Read .github/review-policy.yml `codex.p1_gate.enabled`. If false
#      (the default everywhere except mergepath), exit 0 — clean pass,
#      gate disabled.
#   2. Fetch all inline review comments on the PR via
#      `repos/{repo}/pulls/{pr}/comments`.
#   3. Filter to comments authored by `chatgpt-codex-connector[bot]`
#      (or whatever `codex.bot_login` is configured to) that contain a
#      P1 marker — the badge image pattern `![P1 Badge]` or the text
#      pattern `**P1` (covers Codex's text-only fallback when image
#      rendering is suppressed).
#   4. For each candidate, fetch its review thread state via GraphQL
#      `reviewThreads` and check `isResolved`. The author or any
#      collaborator can resolve a thread via the GitHub UI or
#      `resolveReviewThread` mutation; this script does NOT fight
#      against a human-or-agent-marked-resolved state.
#   5. SHA scope: a P1 finding only gates if its comment was attached
#      to the PR's current HEAD. A P1 from an earlier SHA that is now
#      either resolved OR no longer on HEAD does not count.
#   6. Print one line per unresolved P1 to stdout for CI visibility,
#      then the summary "Codex P1 unresolved: N".
#
# Exit codes:
#   0   No unresolved P1s on current HEAD (or gate disabled).
#   1   One or more unresolved P1s on current HEAD — gate blocks.
#   2   Usage / config error. Error message on stderr.
#
# Design notes:
#   - Read-only. Only GETs against the GitHub API.
#   - bash 3.2 portable (`#!/usr/bin/env bash`, no associative arrays
#     or [[ ]] regex features beyond what 3.2 supports).
#   - PATH-shimmable: tests substitute a `gh` stub on PATH that returns
#     canned payloads. See tests/test_codex_p1_gate.sh.
#   - The override pattern from #235 (`p1-already-fixed`,
#     `p1-rejected`, `p1-moot`, `p1-deferred`) is NOT implemented in
#     v1 — instead, the override path is "mark the thread resolved
#     via the GitHub UI or GraphQL". The structured taxonomy lands in
#     a follow-up once we see how the basic gate behaves in practice.
#
# References:
#   - nathanjohnpayne/mergepath#235 — this script
#   - nathanjohnpayne/mergepath#234 — the sweep that motivated it
#   - REVIEW_POLICY.md § Phase 4a merge gate — the companion script
#     `codex-review-check.sh` covers Codex clearance more broadly;
#     this script is a narrower per-thread enforcement that exists
#     specifically to catch the "Codex flagged P1 but author shipped
#     anyway" failure mode.

set -euo pipefail

# --- argument parsing -------------------------------------------------------

if [ $# -gt 2 ]; then
  echo "Usage: $0 [PR_NUMBER] [REPO]" >&2
  echo "       PR_NUMBER and REPO may also be set via env." >&2
  exit 2
fi

# --- config readers ---------------------------------------------------------

CONFIG=".github/review-policy.yml"

# Read a scalar field nested inside `codex:` `<sub_block>:` `<field>:`.
# Same state-machine awk pattern as codex-review-check.sh, but tracks
# nesting one level deeper for the `p1_gate` sub-block.
codex_p1_gate_field() {
  local field=$1
  [ -f "$CONFIG" ] || return 0
  awk -v field="$field" '
    /^codex:/ { in_codex=1; in_p1_gate=0; next }
    in_codex && /^[^[:space:]#]/ { in_codex=0; in_p1_gate=0 }
    in_codex && /^[[:space:]]+p1_gate:/ { in_p1_gate=1; next }
    in_p1_gate && /^[[:space:]]{0,3}[^[:space:]#]/ { in_p1_gate=0 }
    in_p1_gate && $1 == field":" {
      sub(/^[[:space:]]*[^:]+:[[:space:]]*/, "", $0)
      gsub(/^"/, "", $0)
      gsub(/"[[:space:]]*(#.*)?$/, "", $0)
      gsub(/[[:space:]]*#.*$/, "", $0)
      sub(/[[:space:]]+$/, "", $0)
      print
      exit
    }
  ' "$CONFIG"
}

# Read a scalar field from the codex: block. Mirrors codex-review-check.sh.
codex_field() {
  local field=$1
  [ -f "$CONFIG" ] || return 0
  awk -v field="$field" '
    /^codex:/ {in_block=1; next}
    in_block && /^[^[:space:]#]/ {in_block=0}
    in_block && $1 == field":" {
      sub(/^[[:space:]]*[^:]+:[[:space:]]*/, "", $0)
      gsub(/^"/, "", $0)
      gsub(/"[[:space:]]*(#.*)?$/, "", $0)
      gsub(/[[:space:]]*#.*$/, "", $0)
      sub(/[[:space:]]+$/, "", $0)
      print
      exit
    }
  ' "$CONFIG"
}

# Gate knob: codex.p1_gate.enabled. Default false everywhere except
# mergepath itself (which sets it true in .github/review-policy.yml).
# Off-state is a clean pass — no API calls, no work.
#
# This off-state short-circuit runs BEFORE the PR_NUMBER/REPO/GH_TOKEN
# requirements below (#447): the header documents step 1 as
# "p1_gate.enabled=false → clean pass," so a consumer with the gate
# disabled must no-op on a bare/ad-hoc invocation instead of erroring on
# missing PR context. The readers above touch only the local
# review-policy.yml — no args, no API, no gh.
P1_GATE_ENABLED=$(codex_p1_gate_field enabled)
P1_GATE_ENABLED=${P1_GATE_ENABLED:-false}
case "$P1_GATE_ENABLED" in
  true|false) ;;
  *)
    echo "ERROR: codex.p1_gate.enabled must be true|false; got '$P1_GATE_ENABLED'" >&2
    exit 2
    ;;
esac

if [ "$P1_GATE_ENABLED" != "true" ]; then
  echo "[codex-p1-gate] codex.p1_gate.enabled=false — skipping (clean pass)"
  echo "Codex P1 unresolved: 0"
  exit 0
fi

# --- PR context (required only once the gate is enabled) --------------------

# Positional args take precedence; env fallbacks support the
# workflow_dispatch / scheduled-sweep paths where it's more
# ergonomic to set env than to build a positional arg list.
PR_NUMBER=${1:-${PR_NUMBER:-}}
if [ -z "$PR_NUMBER" ]; then
  echo "ERROR: PR_NUMBER required (positional arg or \$PR_NUMBER env)" >&2
  exit 2
fi
if ! echo "$PR_NUMBER" | grep -qE '^[0-9]+$'; then
  echo "ERROR: PR_NUMBER must be an integer; got '$PR_NUMBER'" >&2
  exit 2
fi

# Verify GH_TOKEN BEFORE auto-detecting REPO via `gh repo view` — a
# missing/invalid token otherwise surfaces as a misleading "could not
# detect current repo" instead of the real auth error (CodeRabbit on #463).
if [ -z "${GH_TOKEN:-}" ]; then
  echo "ERROR: GH_TOKEN is required. See REVIEW_POLICY.md § PAT lookup table." >&2
  exit 2
fi

REPO=${2:-${REPO:-}}
if [ -z "$REPO" ]; then
  REPO=$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null || true)
  if [ -z "$REPO" ]; then
    echo "ERROR: could not detect current repo via 'gh repo view'. Pass REPO explicitly." >&2
    exit 2
  fi
fi

BOT_LOGIN=$(codex_field bot_login)
BOT_LOGIN=${BOT_LOGIN:-"chatgpt-codex-connector[bot]"}

# --- logging helpers --------------------------------------------------------

log() {
  echo "[codex-p1-gate] $*" >&2
}

die() {
  local code=$1
  shift
  echo "[codex-p1-gate] ERROR: $*" >&2
  exit "$code"
}

# Paginated fetch helper — same shape as codex-review-check.sh.
fetch_api_array() {
  local endpoint=$1
  local label=$2
  local raw
  raw=$(gh api --paginate "$endpoint" 2>&1) || die 2 "failed to fetch $label: $raw"
  echo "$raw" | jq -s 'add // []' 2>/dev/null \
    || die 2 "failed to flatten $label pagination output"
}

# --- fetch PR metadata ------------------------------------------------------

log "PR $REPO#$PR_NUMBER — fetching metadata"

PR_JSON=$(gh api "repos/$REPO/pulls/$PR_NUMBER" 2>&1) \
  || die 2 "failed to fetch PR metadata: $PR_JSON"

HEAD_SHA=$(echo "$PR_JSON" | jq -r '.head.sha')
if [ -z "$HEAD_SHA" ] || [ "$HEAD_SHA" = "null" ]; then
  die 2 "could not determine HEAD sha for PR #$PR_NUMBER"
fi
log "HEAD = $HEAD_SHA    bot_login = $BOT_LOGIN"

# --- fetch Codex P1 inline comments ----------------------------------------

COMMENTS_JSON=$(fetch_api_array "repos/$REPO/pulls/$PR_NUMBER/comments" "inline comments")

# Filter:
#   - author == bot_login
#   - body contains a P1 marker: the badge image (`![P1 Badge]`) OR the
#     text fallback (`**P1` at any position; covers titles like
#     `**P1**: Stop retrying endlessly`).
#   - on the current HEAD: original_commit_id == HEAD or commit_id == HEAD.
#     A P1 from an earlier SHA that was addressed in a later commit will
#     have commit_id != HEAD; we treat it as out-of-scope for this gate
#     regardless of thread state (it's already resolved by virtue of
#     not being on HEAD).
#
# Output: array of {id, path, line, body_snippet}. body_snippet is a
# trimmed first line for log readability.
P1_COMMENTS=$(echo "$COMMENTS_JSON" | jq \
  --arg bot "$BOT_LOGIN" --arg sha "$HEAD_SHA" '
  [ .[]
    | select(.user.login == $bot)
    | select(.body | test("!\\[P1 Badge\\]") or test("\\*\\*P1"))
    | select((.commit_id == $sha) or (.original_commit_id == $sha))
    | {
        id: .id,
        path: .path,
        line: (.line // .original_line // 0),
        body_snippet: ((.body // "") | split("\n")[0] | .[0:120])
      }
  ]
')

P1_COUNT=$(echo "$P1_COMMENTS" | jq 'length')
log "found $P1_COUNT P1 comment(s) on HEAD"

if [ "$P1_COUNT" -eq 0 ]; then
  echo "Codex P1 unresolved: 0"
  exit 0
fi

# --- fetch review-thread resolution state via GraphQL ----------------------

# GraphQL `reviewThreads(first: N)` returns each thread with `isResolved`
# and a `comments` connection. We extract a mapping (comment_id →
# isResolved) keyed on the first comment's databaseId, then look each
# P1-bearing comment up.
#
# A single page of 100 review threads is enough for the typical PR; a
# PR with >100 review threads is unusual and warrants a hard error
# rather than a silent truncation (same pattern as the manual GraphQL
# fallback in CLAUDE.md § Before merging step 7.6 escape hatch).

OWNER=${REPO%/*}
NAME=${REPO#*/}

GRAPHQL_QUERY=$(cat <<'EOF'
query($owner: String!, $name: String!, $pr: Int!) {
  repository(owner: $owner, name: $name) {
    pullRequest(number: $pr) {
      reviewThreads(first: 100) {
        totalCount
        pageInfo { hasNextPage }
        nodes {
          isResolved
          comments(first: 100) {
            nodes { databaseId }
          }
        }
      }
    }
  }
}
EOF
)

THREADS_JSON=$(gh api graphql \
  -F owner="$OWNER" \
  -F name="$NAME" \
  -F pr="$PR_NUMBER" \
  -f query="$GRAPHQL_QUERY" 2>&1) \
  || die 2 "failed to query reviewThreads: $THREADS_JSON"

HAS_NEXT=$(echo "$THREADS_JSON" | jq -r '.data.repository.pullRequest.reviewThreads.pageInfo.hasNextPage')
if [ "$HAS_NEXT" = "true" ]; then
  die 2 "PR has >100 review threads; pagination not yet supported. File a follow-up issue."
fi

# Build a JSON object: { "<comment_id>": isResolved, ... }
RESOLUTION_MAP=$(echo "$THREADS_JSON" | jq '
  .data.repository.pullRequest.reviewThreads.nodes
  | map(
      (.isResolved) as $resolved
      | .comments.nodes
      | map({ key: (.databaseId | tostring), value: $resolved })
    )
  | flatten
  | from_entries
')

# --- classify P1 comments by resolution ------------------------------------

UNRESOLVED_P1=$(echo "$P1_COMMENTS" | jq \
  --argjson map "$RESOLUTION_MAP" '
  [ .[]
    | . as $c
    | ($map[($c.id | tostring)] // false) as $resolved
    | select($resolved != true)
  ]
')

UNRESOLVED_COUNT=$(echo "$UNRESOLVED_P1" | jq 'length')

# --- report ----------------------------------------------------------------

if [ "$UNRESOLVED_COUNT" -gt 0 ]; then
  echo ""
  echo "Unresolved Codex P1 findings on current HEAD ($HEAD_SHA):"
  echo "$UNRESOLVED_P1" | jq -r '
    .[] | "  - \(.path):\(.line) (comment id \(.id))\n      \(.body_snippet)"
  '
  echo ""
  echo "Resolve each thread via the GitHub UI (or GraphQL"
  echo "resolveReviewThread mutation) once the finding is addressed."
  echo ""
fi

echo "Codex P1 unresolved: $UNRESOLVED_COUNT"

if [ "$UNRESOLVED_COUNT" -gt 0 ]; then
  exit 1
fi
exit 0
