#!/usr/bin/env bash
# resolve-pr-threads.sh — Enumerate and resolve open review threads on a PR.
#
# Branch protection on `main` typically requires
# `required_conversation_resolution: true`, which means **every review
# thread on the PR must be resolved** before `mergeStateStatus` flips
# from `BLOCKED` to `CLEAN`. This includes CodeRabbit's `🧹 Nitpick` /
# `🔵 Trivial` comments that don't block merge in CodeRabbit's own
# model but DO block the conversation-resolution gate.
#
# The blocker is invisible in `gh pr checks` output — only the GitHub
# UI surfaces it. This script fills the discoverability gap.
#
# Usage:
#   scripts/resolve-pr-threads.sh <PR#> [--repo owner/name] [--list]
#                                 [--auto-resolve-bots] [--dry-run]
#
# Modes:
#   --list                  List unresolved threads with author + path +
#                           first-comment excerpt. No mutations.
#   --auto-resolve-bots     Resolve threads whose author is a bot
#                           (CodeRabbit, Codex Connector, Dependabot)
#                           AND whose latest comment is on the current
#                           HEAD. Use ONLY when:
#                           - The agent has already addressed each
#                             finding in a fix commit on this HEAD, OR
#                             posted a rebuttal reply, AND
#                           - The bot author has not auto-resolved in
#                             a reasonable window.
#                           Per REVIEW_POLICY.md § Implementation notes
#                           for branch protection gates: this is a
#                           CLEAN-UP mechanism, not a policy override.
#                           Human-authored threads are NEVER auto-
#                           resolved regardless of mode.
#   --dry-run               With --auto-resolve-bots, print what would
#                           be resolved without mutating.
#
# Default mode (no flags): equivalent to --list.
#
# Exit codes:
#   0 — no unresolved threads
#   1 — bad arguments
#   2 — gh failure (auth, missing PR, network)
#   3 — unresolved threads exist (in --list mode); call again with
#       --auto-resolve-bots after addressing findings, or resolve
#       human-authored threads via the GitHub UI.
#
# References:
#   nathanjohnpayne/mergepath#166 — the issue this closes
#   matchline #181, #190, #192 — observed cases of conversation-
#                                resolution blocker

set -eo pipefail

usage() {
  cat <<'EOF' >&2
Usage: scripts/resolve-pr-threads.sh <PR#> [--repo owner/name] [--list]
                                            [--auto-resolve-bots] [--dry-run]

  --list                List unresolved threads (default).
  --auto-resolve-bots   Resolve bot-authored threads on current HEAD.
  --dry-run             With --auto-resolve-bots, print without mutating.
EOF
  exit 1
}

PR_NUM=""
REPO=""
MODE="list"
DRY_RUN=false
# Match both REST and GraphQL bot-login formats. The REST API returns
# `coderabbitai[bot]`; GraphQL `author{login}` returns `coderabbitai`
# (un-suffixed user-facing handle). The trailing `(\[bot\])?` accepts
# either form so the auto-resolve mode works with the GraphQL data
# this script reads. Caught on PR #180 review when every CR thread
# was skipped as "human author" — see #182.
BOT_LOGINS_RE='^(coderabbitai|chatgpt-codex-connector|dependabot)(\[bot\])?$'

while [ $# -gt 0 ]; do
  case "$1" in
    --repo)
      # Codex r2 on PR #172: bare `shift 2` silently consumed nothing
      # when --repo was the last arg, leaving REPO empty and falling
      # through to gh-repo-view auto-detect. Validate the value is
      # present and non-empty so the user gets a clear error instead.
      if [ $# -lt 2 ] || [ -z "$2" ]; then
        echo "Error: --repo requires a non-empty value (owner/name)" >&2
        usage
      fi
      REPO="$2"; shift 2 ;;
    --list) MODE="list"; shift ;;
    --auto-resolve-bots) MODE="auto-resolve-bots"; shift ;;
    --dry-run) DRY_RUN=true; shift ;;
    -h|--help) usage ;;
    -*) echo "Unknown flag: $1" >&2; usage ;;
    *)
      if [ -z "$PR_NUM" ]; then PR_NUM="$1"
      else echo "Unexpected positional: $1" >&2; usage
      fi
      shift
      ;;
  esac
done

[ -z "$PR_NUM" ] && usage

# PR_NUM must be a positive integer (no leading zeros, no other chars).
if ! [[ "$PR_NUM" =~ ^[1-9][0-9]*$ ]]; then
  echo "Invalid PR number: '$PR_NUM' (must be a positive integer)" >&2
  exit 1
fi

if [ -z "$REPO" ]; then
  REPO=$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null) || {
    echo "Could not resolve repo. Pass --repo owner/name." >&2
    exit 2
  }
fi

# --repo value validation. Codex r1 on PR #172 caught the missing
# check. Must be `owner/name` where each side is GitHub-legal:
# alphanumerics, hyphens, dots, underscores; no leading dash; ≤39
# chars per GitHub's username rules but we only enforce the syntactic
# shape — gh will reject genuinely-invalid combinations downstream.
if ! [[ "$REPO" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*\/[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
  echo "Invalid --repo value: '$REPO' (expected owner/name)" >&2
  exit 1
fi

OWNER="${REPO%/*}"
NAME="${REPO#*/}"

# Fetch the PR's current HEAD commit oid — used by --auto-resolve-bots
# to verify each thread's latest comment is on the current HEAD before
# resolving. Codex P2 on PR #172 caught that the docstring promised
# this check but the code didn't enforce it.
HEAD_OID=$(gh api "repos/$OWNER/$NAME/pulls/$PR_NUM" --jq .head.sha 2>/dev/null) || {
  echo "Could not resolve PR HEAD oid for $REPO#$PR_NUM" >&2
  exit 2
}

# Fetch all review threads with isResolved state. Three design
# choices, all load-bearing:
#
# 1. `-F cursor=null` (typed) on the first call, NOT `-f cursor=null`
#    (string). The prior code used `-f cursor=null` which sent the
#    literal STRING "null" as the cursor; GitHub's GraphQL endpoint
#    interpreted that as a real cursor and silently returned the
#    wrong thread set. This was the actual root cause of the
#    PR #189 undercount (May 2026 — initially misdiagnosed as
#    eventual consistency; #192 has the post-mortem). The cursor-
#    state branching below sends GraphQL null on the first call,
#    then a real cursor string on subsequent pages.
#
# 2. `comments(first: 50)` — fetch up to 50 comments per thread
#    instead of `comments(last: 1)`. PR review threads almost never
#    exceed 50 comments; fetching them all lets us pick first
#    (original author/body/path) AND last (HEAD anchor commit_oid)
#    deterministically from one response.
#
# 3. `totalCount` cross-validation — after assembling THREADS_JSON,
#    compare the returned node count against the API's reported
#    totalCount. If they disagree the script reports on stderr +
#    exits 2 rather than the silent "no unresolved threads" output
#    that bit PR #189. Belt-and-suspenders: even with the cursor fix
#    above, a future API quirk could re-introduce undercount; the
#    cross-check catches it.
#
# Codex P2 on PR #172 caught that the prior `first: 100` (no pager)
# could undercount on PRs with many threads — paginating with
# `first: 50` + cursor preserves that fix.
THREADS_JSON='[]'
TOTAL_COUNT=0
# CURSOR sentinel "" means "first call — send GraphQL null". A string
# value "null" is NOT the same: passing it via `-f cursor=null` sends
# the literal string "null" which GitHub interprets as a real cursor
# and silently returns the wrong thread set. Always use `-F` (typed)
# for null on first call; switch to `-f` (string) once we have a real
# cursor. This was the actual root cause of the PR #189 undercount —
# not eventual consistency.
CURSOR=""
QUERY='
  query($owner: String!, $repo: String!, $pr: Int!, $cursor: String) {
    repository(owner: $owner, name: $repo) {
      pullRequest(number: $pr) {
        reviewThreads(first: 50, after: $cursor) {
          totalCount
          pageInfo { hasNextPage endCursor }
          nodes {
            id
            isResolved
            isOutdated
            comments(first: 50) {
              nodes {
                author { login }
                path
                body
                createdAt
                commit { oid }
              }
            }
          }
        }
      }
    }
  }
'
while :; do
  if [ -z "$CURSOR" ]; then
    PAGE=$(gh api graphql -f query="$QUERY" \
      -F owner="$OWNER" -F repo="$NAME" -F pr="$PR_NUM" -F cursor=null 2>&1) || {
      echo "GraphQL query failed: $PAGE" >&2
      exit 2
    }
  else
    PAGE=$(gh api graphql -f query="$QUERY" \
      -F owner="$OWNER" -F repo="$NAME" -F pr="$PR_NUM" -f cursor="$CURSOR" 2>&1) || {
      echo "GraphQL query failed: $PAGE" >&2
      exit 2
    }
  fi
  THREADS_JSON=$(jq -c --argjson acc "$THREADS_JSON" \
    '$acc + .data.repository.pullRequest.reviewThreads.nodes' <<<"$PAGE")
  TOTAL_COUNT=$(jq -r '.data.repository.pullRequest.reviewThreads.totalCount' <<<"$PAGE")
  HAS_NEXT=$(jq -r '.data.repository.pullRequest.reviewThreads.pageInfo.hasNextPage' <<<"$PAGE")
  [ "$HAS_NEXT" = "true" ] || break
  CURSOR=$(jq -r '.data.repository.pullRequest.reviewThreads.pageInfo.endCursor' <<<"$PAGE")
done

# totalCount cross-validation — undercount detection.
RETURNED_COUNT=$(jq -r 'length' <<<"$THREADS_JSON")
if [ "$RETURNED_COUNT" -lt "$TOTAL_COUNT" ]; then
  cat >&2 <<EOF
ERROR: GraphQL undercount detected on $REPO#$PR_NUM.
       reviewThreads.totalCount = $TOTAL_COUNT, but the paginated query
       returned $RETURNED_COUNT nodes. This is the eventual-consistency /
       cache-shape failure mode that masked unresolved threads on
       PR #189 (May 2026 — see scripts/resolve-pr-threads.sh header).
       Do NOT trust the "no unresolved threads" output below; fall back
       to the manual GraphQL escape hatch in CLAUDE.md § 7.6.
EOF
  exit 2
fi

UNRESOLVED=$(echo "$THREADS_JSON" | jq -c '
  .[]
  # `!= true` instead of `== false` so a null/missing isResolved
  # field is treated as unresolved (defensive — prefer to surface
  # noise over silently skip).
  | select(.isResolved != true)
  | {
      id: .id,
      outdated: .isOutdated,
      # First comment = original review (what the human/agent needs
      # to recognize the thread). Last comment = HEAD-anchor target
      # (where the bot is now expected to re-review).
      author: (.comments.nodes[0].author.login // "unknown"),
      path: (.comments.nodes[0].path // "(no path)"),
      created: (.comments.nodes[0].createdAt // ""),
      commit_oid: (.comments.nodes[-1].commit.oid // ""),
      excerpt: ((.comments.nodes[0].body // "") | .[0:160])
    }
')

if [ -z "$UNRESOLVED" ]; then
  echo "No unresolved threads on PR #$PR_NUM."
  exit 0
fi

UNRESOLVED_COUNT=$(echo "$UNRESOLVED" | wc -l | tr -d ' ')
echo "Unresolved threads on $REPO#$PR_NUM: $UNRESOLVED_COUNT"
echo ""

# List mode: print and exit 3.
if [ "$MODE" = "list" ]; then
  echo "$UNRESOLVED" | jq -r '
    "  [\(.author)] \(.path)" + (if .outdated then " (outdated)" else "" end) +
    "\n    " + .excerpt + "\n"
  '
  echo "To resolve bot-authored threads where you have already addressed"
  echo "the finding: re-run with --auto-resolve-bots."
  echo "Human-authored threads must be resolved via the GitHub UI or by"
  echo "asking the human. Per REVIEW_POLICY.md § Agent prohibitions."
  exit 3
fi

# auto-resolve-bots mode: resolve bot threads, leave human threads alone.
# Use process substitution (`< <(...)`) instead of `echo $UNRESOLVED | while`
# so the loop runs in the parent shell — counter increments survive past the
# loop and the trailing summary is accurate.
RESOLVED_COUNT=0
SKIPPED_HUMAN=0
SKIPPED_STALE=0
WOULD_RESOLVE_COUNT=0
FAILED_COUNT=0
while IFS= read -r thread; do
  AUTHOR=$(echo "$thread" | jq -r .author)
  THREAD_ID=$(echo "$thread" | jq -r .id)
  PATH_=$(echo "$thread" | jq -r .path)
  EXCERPT=$(echo "$thread" | jq -r .excerpt)
  COMMIT_OID=$(echo "$thread" | jq -r .commit_oid)

  if ! [[ "$AUTHOR" =~ $BOT_LOGINS_RE ]]; then
    echo "  SKIP (human author $AUTHOR): $PATH_"
    echo "    $EXCERPT"
    SKIPPED_HUMAN=$((SKIPPED_HUMAN + 1))
    continue
  fi

  # Current-HEAD check. The advertised contract is "resolve only when
  # the latest comment is on the current HEAD" — a thread anchored to
  # an older commit (or with no commit linkage at all) means the
  # agent's most recent push hasn't been re-reviewed by the bot, so
  # resolving it would force-clear an unaddressed finding.
  #
  # Codex r1 on PR #172 caught that the previous check
  # `if [ -n "$COMMIT_OID" ] && [ "$COMMIT_OID" != "$HEAD_OID" ]`
  # treated EMPTY commit_oid as "matches HEAD" → bot threads with no
  # commit linkage in the GraphQL response would be force-resolved
  # silently. The safe default is the opposite: missing oid is
  # treated as stale.
  if [ -z "$COMMIT_OID" ] || [ "$COMMIT_OID" = "null" ] || [ "$COMMIT_OID" != "$HEAD_OID" ]; then
    if [ -z "$COMMIT_OID" ] || [ "$COMMIT_OID" = "null" ]; then
      reason="no commit linkage"
    else
      reason="latest comment on ${COMMIT_OID:0:7}, HEAD is ${HEAD_OID:0:7}"
    fi
    echo "  SKIP (stale: $reason): [$AUTHOR] $PATH_"
    echo "    Push a fix commit (or rebuttal reply) to re-trigger the bot, then retry."
    SKIPPED_STALE=$((SKIPPED_STALE + 1))
    continue
  fi

  if $DRY_RUN; then
    echo "  WOULD RESOLVE [$AUTHOR] $PATH_"
    echo "    $EXCERPT"
    WOULD_RESOLVE_COUNT=$((WOULD_RESOLVE_COUNT + 1))
    continue
  fi

  if gh api graphql -f query='
    mutation($id: ID!) {
      resolveReviewThread(input: {threadId: $id}) {
        thread { isResolved }
      }
    }
  ' -F id="$THREAD_ID" >/dev/null 2>&1; then
    echo "  RESOLVED [$AUTHOR] $PATH_"
    RESOLVED_COUNT=$((RESOLVED_COUNT + 1))
  else
    echo "  FAILED [$AUTHOR] $PATH_ — mutation rejected" >&2
    FAILED_COUNT=$((FAILED_COUNT + 1))
  fi
done < <(printf '%s\n' "$UNRESOLVED")

echo ""
if $DRY_RUN; then
  echo "(dry-run; no threads modified) — would-resolve: $WOULD_RESOLVE_COUNT, skipped (human): $SKIPPED_HUMAN, skipped (stale-HEAD): $SKIPPED_STALE"
  # Codex r2 on PR #172: dry-run previously exited 0 when only
  # current-HEAD bot threads remained (because dry-run does not mutate
  # them and they didn't increment SKIPPED_*). Callers would treat
  # the PR as "all clear" and proceed to merge into a still-BLOCKED PR.
  # Fix: dry-run exits 3 if ANY actionable items remain (would-resolve,
  # human-skipped, or stale-skipped). The only exit-0 path through
  # auto-resolve-bots --dry-run is "no unresolved threads at all"
  # which is already short-circuited above (UNRESOLVED is empty).
  if [ "$WOULD_RESOLVE_COUNT" -gt 0 ] || [ "$SKIPPED_HUMAN" -gt 0 ] || [ "$SKIPPED_STALE" -gt 0 ]; then
    exit 3
  fi
  exit 0
fi
echo "Resolved: $RESOLVED_COUNT  Skipped (human): $SKIPPED_HUMAN  Skipped (stale-HEAD): $SKIPPED_STALE  Failed: $FAILED_COUNT"
# Codex r1 on PR #172: previously this exited 0 even with stale or
# human-authored threads remaining — callers would treat it as "all
# clear" and proceed to merge into a still-BLOCKED PR. Exit codes:
#   2 = mutation failure (transient: gh/network)
#   3 = unresolved threads remain (human or stale-bot) — PR still
#       conversation-resolution-blocked; address and retry
#   0 = no unresolved threads on current HEAD
[ "$FAILED_COUNT" -gt 0 ] && exit 2
[ "$SKIPPED_HUMAN" -gt 0 ] || [ "$SKIPPED_STALE" -gt 0 ] && exit 3
exit 0
