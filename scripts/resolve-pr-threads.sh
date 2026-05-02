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
BOT_LOGINS_RE='^(coderabbitai\[bot\]|chatgpt-codex-connector\[bot\]|dependabot\[bot\])$'

while [ $# -gt 0 ]; do
  case "$1" in
    --repo) REPO="$2"; shift 2 ;;
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

if [ -z "$REPO" ]; then
  REPO=$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null) || {
    echo "Could not resolve repo. Pass --repo owner/name." >&2
    exit 2
  }
fi

OWNER="${REPO%/*}"
NAME="${REPO#*/}"

# Fetch all review threads with their isResolved state, author, and
# first comment. Use GraphQL because reviewThreads aren't exposed via
# the REST endpoint.
THREADS=$(gh api graphql -f query='
  query($owner: String!, $repo: String!, $pr: Int!) {
    repository(owner: $owner, name: $repo) {
      pullRequest(number: $pr) {
        reviewThreads(first: 100) {
          nodes {
            id
            isResolved
            isOutdated
            comments(first: 1) {
              nodes {
                author { login }
                path
                body
                createdAt
              }
            }
          }
        }
      }
    }
  }
' -F owner="$OWNER" -F repo="$NAME" -F pr="$PR_NUM" 2>&1) || {
  echo "GraphQL query failed: $THREADS" >&2
  exit 2
}

UNRESOLVED=$(echo "$THREADS" | jq -c '
  .data.repository.pullRequest.reviewThreads.nodes[]
  | select(.isResolved == false)
  | {
      id: .id,
      outdated: .isOutdated,
      author: (.comments.nodes[0].author.login // "unknown"),
      path: (.comments.nodes[0].path // "(no path)"),
      created: (.comments.nodes[0].createdAt // ""),
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
RESOLVED_COUNT=0
SKIPPED_HUMAN=0
echo "$UNRESOLVED" | while IFS= read -r thread; do
  AUTHOR=$(echo "$thread" | jq -r .author)
  THREAD_ID=$(echo "$thread" | jq -r .id)
  PATH_=$(echo "$thread" | jq -r .path)
  EXCERPT=$(echo "$thread" | jq -r .excerpt)

  if ! [[ "$AUTHOR" =~ $BOT_LOGINS_RE ]]; then
    echo "  SKIP (human author $AUTHOR): $PATH_"
    echo "    $EXCERPT"
    SKIPPED_HUMAN=$((SKIPPED_HUMAN + 1))
    continue
  fi

  if $DRY_RUN; then
    echo "  WOULD RESOLVE [$AUTHOR] $PATH_"
    echo "    $EXCERPT"
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
  fi
done

if $DRY_RUN; then
  echo ""
  echo "(dry-run; no threads modified)"
  exit 0
fi
exit 0
