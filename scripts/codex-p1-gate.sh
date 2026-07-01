#!/usr/bin/env bash
# scripts/codex-p1-gate.sh — Codex blocking-tier unresolved-thread merge gate
#
# Reports "Codex blocking-tier unresolved: N" for a pull request and fails
# (exit 1) when N > 0. Read-only. Never merges, labels, or comments.
#
# Context: per nathanjohnpayne/mergepath#235, the 2026-05-13 sweep of
# unresolved reviewer feedback (#234) found 62 Codex P1 items sitting
# on merged PRs across 9 repos. P1 is Codex's "blocking" severity tag;
# 62 P1s riding through to closed state is evidence that the label was
# advisory, not enforced. This script is the v1 enforcement.
#
# Generalization (nathanjohnpayne/mergepath#574, sub-issue #577): the gate
# no longer hard-codes P1. It enforces the BLOCKING TIER SET resolved by
# scripts/lib/feedback-policy-helpers.sh's resolve_required_tiers from the
# `feedback_policy` block in .github/review-policy.yml, and classifies each
# Codex inline comment with codex_tier_of. When the feedback_policy block is
# ABSENT, resolve_required_tiers returns "p1" only, so the gate stays
# byte-identical to its original P1-only behavior. The required-check NAME
# (`Codex P1 Gate / Codex P1 unresolved threads`) is UNCHANGED — branch
# protection depends on it — even though the gate now spans the resolved
# tier set.
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
#      (or whatever `codex.bot_login` is configured to) whose Codex
#      tier (codex_tier_of: the badge image `![Pn Badge]` or the text
#      fallback `**Pn`) is in the resolved BLOCKING tier set. With the
#      feedback_policy block absent the set is {p1}, so this matches the
#      original `![P1 Badge]` / `**P1` filter exactly.
#   4. For each candidate, fetch its review thread state via GraphQL
#      `reviewThreads` and check `isResolved`. The author or any
#      collaborator can resolve a thread via the GitHub UI or
#      `resolveReviewThread` mutation; this script does NOT fight
#      against a human-or-agent-marked-resolved state.
#   5. SHA scope: a P1 finding only gates if its comment was attached
#      to the PR's current HEAD. A P1 from an earlier SHA that is now
#      either resolved OR no longer on HEAD does not count.
#   6. Print one line per unresolved blocking-tier finding to stdout for
#      CI visibility, then the summary "Codex blocking-tier unresolved: N".
#
# Exit codes:
#   0   No unresolved blocking-tier findings on current HEAD (or gate
#       disabled).
#   1   One or more unresolved blocking-tier findings on current HEAD —
#       gate blocks.
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

# Shared blocking-tier resolver + Codex tier classifier (#576 foundation).
# resolve_required_tiers reads CONFIG (the global set above) and prints the
# blocking tier set one per line — "p1" when the feedback_policy block is
# absent, preserving this gate's original behavior. codex_tier_of maps a
# Codex finding body to p0..p3. Sourced by absolute-ish path relative to
# this script so it resolves regardless of cwd (the script runs from the
# trusted default-branch checkout root, but lib lives under scripts/).
__P1_GATE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/feedback-policy-helpers.sh
. "$__P1_GATE_DIR/lib/feedback-policy-helpers.sh"

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
  echo "Codex blocking-tier unresolved: 0"
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

# Resolve the BLOCKING tier set from the feedback_policy block (#577). Absent
# block -> "p1" (byte-identical to the original P1-only gate). Only rc 2 is
# the documented "malformed mode/tier" signal — fail closed as a config error
# (exit 2), the same posture as the p1_gate.enabled validation above. A
# non-2 non-zero rc is NOT a failure: resolve_required_tiers' by-priority
# branch inherits the exit status of its final loop iteration (e.g. rc 1 when
# the last tier, nitpick, is not `required`), which is benign. Capture the
# output regardless and branch on the rc explicitly so that benign tail
# status does not get misread as malformed.
set +e
REQUIRED_TIERS=$(resolve_required_tiers "$CONFIG")
RT_RC=$?
set -e
if [ "$RT_RC" -eq 2 ]; then
  echo "ERROR: malformed feedback_policy block in $CONFIG (resolve_required_tiers exit 2)" >&2
  exit 2
fi

# Return 0 iff $1 (a tier like p0..p3) is in the resolved REQUIRED_TIERS set.
# Newline-delimited exact match — mirrors login_is_available_reviewer.
tier_is_required() {
  local needle=$1 t
  [ -n "$needle" ] || return 1
  while IFS= read -r t; do
    [ "$t" = "$needle" ] && return 0
  done <<< "$REQUIRED_TIERS"
  return 1
}

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

# --- fetch Codex blocking-tier inline comments ------------------------------

COMMENTS_JSON=$(fetch_api_array "repos/$REPO/pulls/$PR_NUMBER/comments" "inline comments")

log "blocking tier set: $(echo "$REQUIRED_TIERS" | tr '\n' ' ')"

# Stage 1 (jq): narrow to bot-authored comments on the current HEAD —
#   - author == bot_login
#   - on the current HEAD: original_commit_id == HEAD or commit_id == HEAD.
#     A finding from an earlier SHA that was addressed in a later commit
#     has commit_id != HEAD; we treat it as out-of-scope for this gate
#     regardless of thread state (already resolved by not being on HEAD).
# We keep the FULL body here so stage 2 can classify each candidate with
# the shared codex_tier_of — no tier filter in jq, to avoid re-implementing
# (and drifting from) the classifier in scripts/lib/feedback-policy-helpers.sh.
CANDIDATES=$(echo "$COMMENTS_JSON" | jq -c \
  --arg bot "$BOT_LOGIN" --arg sha "$HEAD_SHA" '
  [ .[]
    | select(.user.login == $bot)
    | select((.commit_id == $sha) or (.original_commit_id == $sha))
    | {
        id: .id,
        path: .path,
        line: (.line // .original_line // 0),
        body: (.body // "")
      }
  ]
')

# Stage 2 (bash): classify each candidate via codex_tier_of and keep only
# those whose tier is in the resolved blocking set. With the feedback_policy
# block absent the set is {p1}, so this reproduces the original
# `![P1 Badge]` / `**P1` filter exactly (codex_tier_of matches those two
# markers). Re-assemble the kept comments into a JSON array of
# {id, path, line, body_snippet} (trimmed first line for log readability).
BLOCKING_COMMENTS="[]"
CAND_COUNT=$(echo "$CANDIDATES" | jq 'length')
i=0
while [ "$i" -lt "$CAND_COUNT" ]; do
  c=$(echo "$CANDIDATES" | jq -c ".[$i]")
  body=$(echo "$c" | jq -r '.body')
  tier=$(codex_tier_of "$body")
  if tier_is_required "$tier"; then
    BLOCKING_COMMENTS=$(echo "$BLOCKING_COMMENTS" | jq -c \
      --argjson c "$c" --arg tier "$tier" '
      . + [ {
        id: $c.id,
        path: $c.path,
        line: $c.line,
        tier: $tier,
        body_snippet: ($c.body | split("\n")[0] | .[0:120])
      } ]
    ')
  fi
  i=$((i + 1))
done

BLOCKING_COUNT=$(echo "$BLOCKING_COMMENTS" | jq 'length')
log "found $BLOCKING_COUNT blocking-tier comment(s) on HEAD"

if [ "$BLOCKING_COUNT" -eq 0 ]; then
  echo "Codex blocking-tier unresolved: 0"
  exit 0
fi

# --- fetch review-thread resolution state via GraphQL ----------------------

# Build a mapping (comment_id → isResolved) across ALL review threads and ALL
# comments in each thread, then look each blocking-tier comment up.
#
# PAGINATION (#592). The GraphQL `reviewThreads` connection and each thread's
# nested `comments` connection each cap at 100 items per page. A PR with >100
# review threads, or a thread with >100 comments, would truncate the map — a
# blocking comment id beyond the cap would be absent, fall to `// false` in the
# classification below, and be counted as unresolved. That is already fail-SAFE
# (over-block, never false-clear), but it turns an extreme-but-legitimate PR
# into a hard exit 2. So instead of erroring, we PAGINATE both connections with
# a cursor loop and classify precisely.
#
# FAIL-CLOSED POSTURE IS PRESERVED (#592). The loop fails closed (die 2, the
# same exit code as the pre-pagination hard error) on ANY of: a GraphQL error,
# a null/malformed page (missing reviewThreads), or exceeding the max-page
# safety cap. It never treats a partial or failed scan as complete, so a
# truncated map can NEVER silently under-count blocking findings. This block is
# mirrored verbatim (bar the log prefix) in scripts/coderabbit-severity-gate.sh
# — keep the two in lockstep; a shared paginator was considered but the shared
# lib (scripts/lib/feedback-policy-helpers.sh) is contractually gh/network-free.

OWNER=${REPO%/*}
NAME=${REPO#*/}

# Safety cap: 100 threads/page × 100 pages = 10k threads; 100 comments/page ×
# 100 pages = 10k comments/thread. Far beyond any real PR; a loop that reaches
# it indicates a cursor-stall / non-terminating pagination bug, so we fail
# closed rather than spin.
MAX_PAGES=100

# Top-level reviewThreads query (paged via $cursor). Each thread carries its
# first page of comments plus that connection's pageInfo so we can detect a
# >100-comment thread and page it separately below.
THREADS_QUERY=$(cat <<'EOF'
query($owner: String!, $name: String!, $pr: Int!, $cursor: String) {
  repository(owner: $owner, name: $name) {
    pullRequest(number: $pr) {
      reviewThreads(first: 100, after: $cursor) {
        pageInfo { hasNextPage endCursor }
        nodes {
          id
          isResolved
          comments(first: 100) {
            pageInfo { hasNextPage endCursor }
            nodes { databaseId }
          }
        }
      }
    }
  }
}
EOF
)

# Per-thread comments query (paged via $cursor) for a thread whose comments
# connection overflowed 100. Keyed by the thread node id.
THREAD_COMMENTS_QUERY=$(cat <<'EOF'
query($id: ID!, $cursor: String) {
  node(id: $id) {
    ... on PullRequestReviewThread {
      comments(first: 100, after: $cursor) {
        pageInfo { hasNextPage endCursor }
        nodes { databaseId }
      }
    }
  }
}
EOF
)

# Accumulate every thread node (with a fully-paginated comment id list) into
# ALL_THREADS as a JSON array of { isResolved, comment_ids: [databaseId,...] }.
ALL_THREADS='[]'
CURSOR=""
PAGE=0
while :; do
  PAGE=$((PAGE + 1))
  if [ "$PAGE" -gt "$MAX_PAGES" ]; then
    die 2 "reviewThreads pagination exceeded $MAX_PAGES pages (#592 safety cap) — failing closed."
  fi
  if [ -z "$CURSOR" ]; then
    THREADS_JSON=$(gh api graphql -F owner="$OWNER" -F name="$NAME" \
      -F pr="$PR_NUMBER" -F cursor=null -f query="$THREADS_QUERY" 2>&1) \
      || die 2 "failed to query reviewThreads (page $PAGE): $THREADS_JSON"
  else
    THREADS_JSON=$(gh api graphql -F owner="$OWNER" -F name="$NAME" \
      -F pr="$PR_NUMBER" -f cursor="$CURSOR" -f query="$THREADS_QUERY" 2>&1) \
      || die 2 "failed to query reviewThreads (page $PAGE): $THREADS_JSON"
  fi
  # Fail closed on a malformed / null page: a missing reviewThreads object
  # means the scan cannot be trusted complete.
  if ! echo "$THREADS_JSON" | jq -e '.data.repository.pullRequest.reviewThreads.nodes' >/dev/null 2>&1; then
    die 2 "malformed reviewThreads response (page $PAGE) — failing closed."
  fi

  # For each thread on this page, resolve its comment id list — paginating the
  # nested comments connection if it overflowed 100.
  PAGE_NODE_COUNT=$(echo "$THREADS_JSON" | jq '.data.repository.pullRequest.reviewThreads.nodes | length')
  n=0
  while [ "$n" -lt "$PAGE_NODE_COUNT" ]; do
    NODE=$(echo "$THREADS_JSON" | jq -c ".data.repository.pullRequest.reviewThreads.nodes[$n]")
    NODE_RESOLVED=$(echo "$NODE" | jq '.isResolved')
    NODE_ID=$(echo "$NODE" | jq -r '.id')
    COMMENT_IDS=$(echo "$NODE" | jq -c '[.comments.nodes[].databaseId]')
    C_HAS_NEXT=$(echo "$NODE" | jq -r '.comments.pageInfo.hasNextPage')
    C_CURSOR=$(echo "$NODE" | jq -r '.comments.pageInfo.endCursor')
    C_PAGE=1
    while [ "$C_HAS_NEXT" = "true" ]; do
      C_PAGE=$((C_PAGE + 1))
      if [ "$C_PAGE" -gt "$MAX_PAGES" ]; then
        die 2 "thread comments pagination exceeded $MAX_PAGES pages (#592 safety cap) — failing closed."
      fi
      CJSON=$(gh api graphql -F id="$NODE_ID" -f cursor="$C_CURSOR" \
        -f query="$THREAD_COMMENTS_QUERY" 2>&1) \
        || die 2 "failed to query thread comments (thread $NODE_ID, page $C_PAGE): $CJSON"
      if ! echo "$CJSON" | jq -e '.data.node.comments.nodes' >/dev/null 2>&1; then
        die 2 "malformed thread comments response (thread $NODE_ID, page $C_PAGE) — failing closed."
      fi
      COMMENT_IDS=$(jq -c -n --argjson acc "$COMMENT_IDS" --argjson pg \
        "$(echo "$CJSON" | jq -c '[.data.node.comments.nodes[].databaseId]')" '$acc + $pg')
      C_HAS_NEXT=$(echo "$CJSON" | jq -r '.data.node.comments.pageInfo.hasNextPage')
      C_CURSOR=$(echo "$CJSON" | jq -r '.data.node.comments.pageInfo.endCursor')
    done
    ALL_THREADS=$(jq -c -n --argjson acc "$ALL_THREADS" \
      --argjson resolved "$NODE_RESOLVED" --argjson ids "$COMMENT_IDS" \
      '$acc + [{ isResolved: $resolved, comment_ids: $ids }]')
    n=$((n + 1))
  done

  HAS_NEXT=$(echo "$THREADS_JSON" | jq -r '.data.repository.pullRequest.reviewThreads.pageInfo.hasNextPage')
  [ "$HAS_NEXT" = "true" ] || break
  CURSOR=$(echo "$THREADS_JSON" | jq -r '.data.repository.pullRequest.reviewThreads.pageInfo.endCursor')
  if [ -z "$CURSOR" ] || [ "$CURSOR" = "null" ]; then
    die 2 "reviewThreads reported hasNextPage but no endCursor — failing closed."
  fi
done

# Build a JSON object: { "<comment_id>": isResolved, ... } from the fully
# paginated thread set.
RESOLUTION_MAP=$(echo "$ALL_THREADS" | jq '
  map(
      (.isResolved) as $resolved
      | .comment_ids
      | map({ key: (. | tostring), value: $resolved })
    )
  | flatten
  | from_entries
')

# --- classify blocking-tier comments by resolution -------------------------

UNRESOLVED_BLOCKING=$(echo "$BLOCKING_COMMENTS" | jq \
  --argjson map "$RESOLUTION_MAP" '
  [ .[]
    | . as $c
    | ($map[($c.id | tostring)] // false) as $resolved
    | select($resolved != true)
  ]
')

UNRESOLVED_COUNT=$(echo "$UNRESOLVED_BLOCKING" | jq 'length')

# --- report ----------------------------------------------------------------

if [ "$UNRESOLVED_COUNT" -gt 0 ]; then
  echo ""
  echo "Unresolved Codex blocking-tier findings on current HEAD ($HEAD_SHA):"
  echo "$UNRESOLVED_BLOCKING" | jq -r '
    .[] | "  - [\(.tier | ascii_upcase)] \(.path):\(.line) (comment id \(.id))\n      \(.body_snippet)"
  '
  echo ""
  echo "Resolve each thread via the GitHub UI (or GraphQL"
  echo "resolveReviewThread mutation) once the finding is addressed."
  echo ""
fi

echo "Codex blocking-tier unresolved: $UNRESOLVED_COUNT"

if [ "$UNRESOLVED_COUNT" -gt 0 ]; then
  exit 1
fi
exit 0
