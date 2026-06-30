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
#                                 [--rationale <text>] [--no-tag-reply]
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
#                           Non-bot threads are NEVER handled by this
#                           bot-only mode. Follow REVIEW_POLICY.md's
#                           pre-merge gate for agent-reviewer vs
#                           real-human threads.
#   --resolve-actioned      Like --auto-resolve-bots (same bot-author,
#                           current-HEAD, identity, tag-reply, and readback
#                           handling) but resolves a thread ONLY when its
#                           derived class proves ACTION on this PR:
#                           addressed-elsewhere (an agent commit touching the
#                           anchored file, after the latest re-raise) or
#                           rebuttal-recorded (a substantive agent rebuttal
#                           after the latest re-raise). Routing-only classes
#                           — canonical-coverage / templated-render — are
#                           NOT actioned here: they show WHERE a fix belongs
#                           (upstream), not that one happened, so a fresh
#                           finding on a canonical path must not be resolved
#                           by routing alone (#565). The gate evaluates
#                           action INDEPENDENTLY of routing, so a
#                           canonical/templated thread that DOES carry action
#                           evidence (a fix commit touching it, or a
#                           rebuttal) is still resolved. Routing-only threads,
#                           plus
#                           nitpick-noted / deferred-to-followup and any
#                           class that can't be positively determined, are
#                           LEFT UNRESOLVED so the weekly unresolved-
#                           feedback sweep keeps surfacing them (#564). Use
#                           this to mark genuinely-handled feedback resolved
#                           without the blunt "resolve everything" of
#                           --auto-resolve-bots. To merge past a deferral on
#                           a conversation-resolution-gated repo, fix/rebut
#                           it (making it actioned) or defer it explicitly
#                           via --auto-resolve-bots --rationale.
#   --dry-run               With either resolve mode, print what would
#                           be resolved without mutating.
#   --rationale <text>      With --auto-resolve-bots, override the
#                           auto-synthesized class with a free-form
#                           rationale. Class defaults to
#                           `deferred-to-followup` (most common manual
#                           case); the free-form text follows the tag.
#                           Useful when the auto-heuristic would
#                           misclassify (e.g. P2 deferred to a tracked
#                           follow-up issue). Implies tag-reply emission.
#   --no-tag-reply          With --auto-resolve-bots, suppress the
#                           pre-resolution `[mergepath-resolve:<class>]`
#                           reply emission. The resolve mutation still
#                           runs. Useful for dry-rehearsal of the
#                           resolve loop without polluting the thread
#                           history. The default IS to emit the tag —
#                           the v1 daily rollup classifier reads it.
#
# Default mode (no flags): equivalent to --list.
#
# Tag emission (mergepath#305):
#   When --auto-resolve-bots runs WITHOUT --no-tag-reply, the helper
#   posts a one-line reply on each bot thread BEFORE the resolve
#   mutation:
#
#     [mergepath-resolve: <class>] <one-line rationale>
#
#   where `<class>` is one of (taxonomy mirrored from the v1 daily
#   rollup classifier in scripts/lib/daily-feedback-rollup-helpers.sh):
#     addressed-elsewhere   fix-commit by an agent author after the
#                           comment's createdAt, touching the anchored
#                           file (or any file when per-file detection
#                           is unavailable)
#     canonical-coverage    path matches a canonical entry in
#                           .mergepath-sync.yml (propagated content)
#     nitpick-noted         severity is Nitpick/Trivial/P3 and no
#                           stronger signal applies
#     rebuttal-recorded     a substantive agent-authored reply (≥30
#                           chars) is on the thread
#     deferred-to-followup  default fallback / --rationale override
#
#   Tag emission failure is logged + skipped (does NOT block the
#   resolve mutation). The rollup's classifier accepts any string
#   matching the regex; unknown classes route to "surface" per spec.
#
# Exit codes:
#   0 — no unresolved threads
#   1 — bad arguments
#   2 — gh failure (auth, missing PR, network), a resolve mutation that did
#       not return isResolved:true, OR a post-resolve readback that could
#       not confirm isResolved:true (#564 — fail closed). After every
#       --auto-resolve-bots run, the helper re-reads each thread it
#       resolved via a `nodes(ids:)` readback and refuses to report success
#       unless GitHub confirms isResolved:true for all of them.
#   3 — unresolved threads exist (in --list mode); call again with
#       --auto-resolve-bots after addressing findings, or resolve
#       human-authored threads via the GitHub UI.
#
# References:
#   nathanjohnpayne/mergepath#166 — the issue this closes
#   matchline #181, #190, #192 — observed cases of conversation-
#                                resolution blocker

set -euo pipefail
# `-u` added (#536): optionals are already defaulted (MODE/DRY_RUN/
# RATIONALE_OVERRIDE/etc. at module top, env vars via `${VAR:-}` and the
# `:=` default for MERGEPATH_AGENT_AUTHORS), and the arg parser guards
# `$2` behind a `$# -lt 2` short-circuit, so strict unset-variable
# handling surfaces genuine typos without breaking documented paths.

# --- preflight auto-source (#282) ------------------------------------------
# If OP_PREFLIGHT_REVIEWER_PAT is unset and a fresh op-preflight cache
# exists for this agent, source it. The existing PAT_GH_TOKEN logic
# below already prefers OP_PREFLIGHT_REVIEWER_PAT over GH_TOKEN, so this
# block needs only to populate the env var. Silent on no-op paths.
__RESOLVE_THREADS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -z "${OP_PREFLIGHT_REVIEWER_PAT:-}" ] && [ -r "$__RESOLVE_THREADS_DIR/lib/preflight-helpers.sh" ]; then
  # shellcheck source=lib/preflight-helpers.sh
  . "$__RESOLVE_THREADS_DIR/lib/preflight-helpers.sh"
  auto_source_preflight
fi
if [ -r "$__RESOLVE_THREADS_DIR/lib/gh-token-resolver.sh" ]; then
  # shellcheck source=lib/gh-token-resolver.sh
  . "$__RESOLVE_THREADS_DIR/lib/gh-token-resolver.sh"
fi

usage() {
  cat <<'EOF' >&2
Usage: scripts/resolve-pr-threads.sh <PR#> [--repo owner/name] [--list]
                                            [--auto-resolve-bots | --resolve-actioned]
                                            [--dry-run] [--rationale <text>] [--no-tag-reply]

  --list                List unresolved threads (default).
  --auto-resolve-bots   Resolve ALL current-HEAD bot-authored threads
                        (clears the conversation-resolution gate; the
                        daily rollup re-surfaces deferrals).
  --resolve-actioned    Resolve ONLY current-HEAD bot threads whose fix or
                        rebuttal is demonstrable (derived class in the
                        actioned skip-set); leave the rest unresolved so
                        the weekly sweep keeps surfacing them.
  --dry-run             With either resolve mode, print without mutating.
  --rationale <text>    With --auto-resolve-bots, free-form rationale
                        appended after the [mergepath-resolve: deferred-to-followup]
                        tag (overrides auto-classification).
  --no-tag-reply        With either resolve mode, suppress the
                        [mergepath-resolve:<class>] reply emission
                        (the resolve mutation still runs).
EOF
  exit 1
}

PR_NUM=""
REPO=""
MODE="list"
DRY_RUN=false
RATIONALE_OVERRIDE=""
RATIONALE_FLAG_USED=false
NO_TAG_REPLY=false
# Match both REST and GraphQL bot-login formats. The REST API returns
# `coderabbitai[bot]`; GraphQL `author{login}` returns `coderabbitai`
# (un-suffixed user-facing handle). The trailing `(\[bot\])?` accepts
# either form so the auto-resolve mode works with the GraphQL data
# this script reads. Caught on PR #180 review when every CR thread
# was skipped as a non-bot author — see #182.
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
    --resolve-actioned) MODE="resolve-actioned"; shift ;;
    --dry-run) DRY_RUN=true; shift ;;
    --rationale)
      # Same defensive value check as --repo (Codex r2 on PR #172):
      # require an explicit non-empty argument so a trailing
      # `--rationale` doesn't silently produce an empty tag body.
      if [ $# -lt 2 ] || [ -z "$2" ]; then
        echo "Error: --rationale requires a non-empty value" >&2
        usage
      fi
      RATIONALE_OVERRIDE="$2"
      RATIONALE_FLAG_USED=true
      shift 2 ;;
    --no-tag-reply) NO_TAG_REPLY=true; shift ;;
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

# #565: --rationale is an --auto-resolve-bots affordance (override the class
# for a deliberate deferred resolve). It is incompatible with
# --resolve-actioned, whose whole contract is to resolve ONLY on derived
# action evidence — a free-form rationale override would resolve a thread
# while mis-tagging it deferred-to-followup, so the daily rollup would treat
# an actioned, resolved thread as deferred/unhandled. Reject the combo.
if [ "$MODE" = "resolve-actioned" ] && $RATIONALE_FLAG_USED; then
  echo "Error: --rationale is not valid with --resolve-actioned (it applies" >&2
  echo "       only to --auto-resolve-bots). --resolve-actioned resolves on" >&2
  echo "       derived action evidence; use --auto-resolve-bots --rationale" >&2
  echo "       to deliberately resolve a deferred thread with a rationale." >&2
  exit 1
fi

# Resolve the reviewer PAT once + define the wrapper before any `gh`
# call. CR Major on PR #194 r4 caught that the bare `gh repo view`
# and `gh api` invocations below this point would still hit the
# empty-GH_TOKEN keyring-fallback trap. Centralizing the wrapper
# above all gh calls fixes it.
#
# `gh_pat` (renamed from `gh_read` — CodeRabbit Major #271/#272) is
# used for BOTH the read-path calls AND the resolveReviewThread
# WRITE mutation. The mutation previously used a bare `gh api
# graphql`: in a CI context where only OP_PREFLIGHT_REVIEWER_PAT is
# populated (no ambient GH_TOKEN), that bare call would fall back to
# the keyring — wrong identity, or an outright failure — after every
# read had passed. Pinning the same PAT on the mutation keeps reads
# and the write consistent. The name is now token-centric, not
# read-centric, to reflect that.
PAT_GH_TOKEN="${OP_PREFLIGHT_REVIEWER_PAT:-${GH_TOKEN:-}}"
gh_pat() {
  if [ -n "$PAT_GH_TOKEN" ]; then
    GH_TOKEN="$PAT_GH_TOKEN" gh "$@"
  else
    gh "$@"
  fi
}

if [ -z "$REPO" ]; then
  REPO=$(gh_pat repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null) || {
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

# Per-commit file-list cache for the addressed-elsewhere check (#565). Keyed
# by commit SHA, stored on disk so the cache survives the command-substitution
# subshells that derive_tag_class / synth_rationale run in (a shell-var cache
# would be lost when those subshells exit). Removed on exit.
COMMIT_FILES_CACHE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/resolve-pr-commitfiles.XXXXXX")"
trap 'rm -rf "$COMMIT_FILES_CACHE_DIR"' EXIT

# Fetch the PR's current HEAD commit oid — used by --auto-resolve-bots
# to verify each thread's latest comment is on the current HEAD before
# resolving. Codex P2 on PR #172 caught that the docstring promised
# this check but the code didn't enforce it.
HEAD_OID=$(gh_pat api "repos/$OWNER/$NAME/pulls/$PR_NUM" --jq .head.sha 2>/dev/null) || {
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
# 2. Two GraphQL aliases — `commentsFirst: comments(first: 1)` for
#    the original review's author/path/body (what the user/agent
#    needs to recognize the thread) AND `commentsLast: comments(last:
#    1)` for the HEAD-anchor commit_oid (the truly-latest comment).
#    Earlier draft used `comments(first: 50)` and indexed `[-1]` for
#    the last comment, but Codex P2 on PR #194 caught that >50-comment
#    threads (rare but possible — bot churn over a long-lived PR)
#    would misclassify HEAD anchor. The dual-alias shape is
#    deterministic for any thread depth.
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
            # `commentsFirst` for the original review (excerpt + author).
            # `commentsLast` for the HEAD-anchor commit_oid — `last: 1`
            # guarantees the truly-latest comment regardless of thread
            # depth. Codex P2 on PR #194 caught that `first: 50` would
            # misclassify HEAD anchor on threads with >50 comments
            # (rare but possible — bot churn).
            commentsFirst: comments(first: 1) {
              nodes {
                author { login }
                path
                body
                createdAt
              }
            }
            commentsLast: comments(last: 1) {
              nodes {
                commit { oid }
              }
            }
            # `allComments` powers the rationale-tag class derivation
            # (mergepath#305): scan agent-authored replies for an
            # existing `[mergepath-resolve:...]` tag (skip re-emission)
            # and substantive rebuttal detection (≥30 chars from an
            # agent author → `rebuttal-recorded`).
            #
            # `last: 50` (not first: 50) — the staleness checks (#565) need
            # the MOST RECENT comments: latest_nonagent_created and the
            # last-word marker/rebuttal logic must see a bot re-raise even on
            # a long thread. `first: 50` truncated the newest comments, so a
            # re-raise past comment 50 was invisible and an older fix/rebuttal
            # looked like the latest word — resolving live feedback (Codex P2
            # on #565). The most-recent 50 always include the latest re-raise;
            # only very old comments (>50 back) drop off, and those never make
            # a thread look MORE actioned, so the gate stays fail-safe.
            allComments: comments(last: 50) {
              nodes {
                author { login }
                body
                databaseId
                # createdAt powers the addressed-elsewhere staleness guard
                # (#565): a fix commit must post-date the LATEST bot/reviewer
                # comment, not just the original finding, to count as actioning.
                createdAt
              }
            }
          }
        }
      }
    }
  }
'
while :; do
  # Read-path: pin to preflight reviewer PAT when available; otherwise
  # let gh use its keyring fallback (no empty-GH_TOKEN trap).
  if [ -z "$CURSOR" ]; then
    PAGE=$(gh_pat api graphql -f query="$QUERY" \
      -F owner="$OWNER" -F repo="$NAME" -F pr="$PR_NUM" -F cursor=null 2>&1) || {
      echo "GraphQL query failed: $PAGE" >&2
      exit 2
    }
  else
    PAGE=$(gh_pat api graphql -f query="$QUERY" \
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

# totalCount cross-validation — fail on ANY mismatch (under OR over).
# Equality check, not `< totalCount`: an over-count would indicate a
# duplicate-page / cursor-reset regression in the pagination loop and
# is just as bad as an undercount. CR Major on PR #194 r2.
RETURNED_COUNT=$(jq -r 'length' <<<"$THREADS_JSON")
if [ "$RETURNED_COUNT" != "$TOTAL_COUNT" ]; then
  cat >&2 <<EOF
ERROR: GraphQL count mismatch on $REPO#$PR_NUM.
       reviewThreads.totalCount = $TOTAL_COUNT, but the paginated query
       returned $RETURNED_COUNT nodes. Either undercount (cursor-typing
       bug per #192) or overcount (duplicate-page / cursor-reset
       regression). Do NOT trust the "no unresolved threads" output
       below; fall back to the manual GraphQL escape hatch in
       CLAUDE.md § 7.6.
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
      # commentsFirst = original review (excerpt + author for display).
      # commentsLast = guaranteed-latest comment (HEAD anchor commit_oid).
      # allComments = full reply chain for tag-emission heuristics
      #   (mergepath#305): existing-tag detection + rebuttal scan.
      author: (.commentsFirst.nodes[0].author.login // "unknown"),
      path: (.commentsFirst.nodes[0].path // "(no path)"),
      created: (.commentsFirst.nodes[0].createdAt // ""),
      commit_oid: (.commentsLast.nodes[0].commit.oid // ""),
      body: (.commentsFirst.nodes[0].body // ""),
      excerpt: ((.commentsFirst.nodes[0].body // "") | .[0:160]),
      all_comments: (.allComments.nodes // [])
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
  echo "Non-bot threads are not handled by --auto-resolve-bots. Follow"
  echo "REVIEW_POLICY.md's pre-merge gate for agent-reviewer vs real-human"
  echo "threads."
  exit 3
fi

# Identity check (#284 r2 / #412): the resolveReviewThread mutation is
# a GraphQL write, and its byline follows the PAT in GH_TOKEN. Verify
# that PAT resolves to the expected reviewer identity BEFORE entering
# the per-thread mutation loop.
# Opt-out via RESOLVE_PR_THREADS_SKIP_IDENTITY_CHECK=1.
#
# nathanpayne-codex Phase 4b r1 on PR #293 caught the prior shape's
# hole: the check used to fire inside the loop with an
# IDENTITY_CHECK_FIRED once-only guard. On FAILED, that guard still
# evaluated to "fired" on subsequent iterations, so the loop's
# `IDENTITY_CHECK_FIRED != 1` predicate falsely short-circuited the
# re-check and the mutation ran without identity verification on
# every thread AFTER the first failure. Lifting the check out of
# the loop entirely makes it a single up-front gate.
#
# r3 (#284): fail CLOSED if the helper is missing or non-executable.
# The previous shape bundled `[ -x "$CHECKER" ]` into the same AND
# chain as the opt-out — so if the helper got renamed, deleted, or
# lost its +x bit, the entire identity-check block was silently
# SKIPPED and the mutation ran without verification. nathanpayne-codex
# Phase 4b r2 reproduced this. The fix: the helper-presence test
# becomes a hard error inside the opt-out branch rather than a
# precondition for entering it.
if [ "${RESOLVE_PR_THREADS_SKIP_IDENTITY_CHECK:-0}" != "1" ] && ! $DRY_RUN; then
  CHECKER="$(dirname "${BASH_SOURCE[0]}")/identity-check.sh"
  if [ ! -x "$CHECKER" ]; then
    echo "ERROR: identity-check helper missing or non-executable: $CHECKER" >&2
    echo "       Refusing to mutate without identity verification." >&2
    echo "       Restore the helper, or opt out via" >&2
    echo "       RESOLVE_PR_THREADS_SKIP_IDENTITY_CHECK=1 (dev only)." >&2
    exit 2
  fi
  if command -v gh_default_reviewer_identity >/dev/null 2>&1; then
    expected_login="$(gh_default_reviewer_identity)"
  else
    expected_login="nathanpayne-${MERGEPATH_AGENT:-claude}"
  fi
  if ! GH_TOKEN="$PAT_GH_TOKEN" "$CHECKER" \
       --expect-token-identity "$expected_login"; then
    echo "ERROR: identity-check failed before any mutation. Refusing to" >&2
    echo "       resolve threads. Confirm GH_TOKEN / OP_PREFLIGHT_REVIEWER_PAT" >&2
    echo "       resolves to $expected_login, then re-run." >&2
    echo "       Opt-out (dev only): RESOLVE_PR_THREADS_SKIP_IDENTITY_CHECK=1." >&2
    exit 2
  fi
fi

# ---------------------------------------------------------------------
# mergepath#305 — agent-side `[mergepath-resolve:<class>]` tag emission
# ---------------------------------------------------------------------
#
# Before each resolveReviewThread mutation, post a one-line reply on
# the thread with `[mergepath-resolve: <class>] <rationale>`. The
# v1 daily rollup classifier in
# scripts/lib/daily-feedback-rollup-helpers.sh reads this tag and
# prioritizes it over its own heuristics. The taxonomy (the five
# valid `<class>` values) MUST match what the classifier accepts —
# unknown class strings route to "surface" per the rollup spec,
# which is acceptable but defeats the purpose.
#
# We intentionally do NOT source the rollup helpers file: it is not
# in .mergepath-sync.yml, and sourcing it would either break
# propagation OR force the helpers to travel with the canonical
# resolve script. Instead we inline the small bits we need here
# (regex shape, agent-author check, severity sniff). The
# canonical taxonomy lives in the helpers file's case-statement
# comments — this script must stay in step.

# is_agent_author_local <login> → exit 0 if agent, 1 otherwise.
# Mirrors the helpers' `is_agent_author` exactly. Bash 3.2 compatible
# (no associative arrays). Reads MERGEPATH_AGENT_AUTHORS (colon-sep)
# with the same default set as the rollup helpers.
: "${MERGEPATH_AGENT_AUTHORS:=nathanjohnpayne:nathanpayne-claude:nathanpayne-cursor:nathanpayne-codex}"
is_agent_author_local() {
  local login="$1"
  local oldIFS="$IFS"
  IFS=':'
  set -- $MERGEPATH_AGENT_AUTHORS
  IFS="$oldIFS"
  for a; do
    [ "$login" = "$a" ] && return 0
  done
  return 1
}

# latest_nonagent_created <thread_json> → ISO timestamp on stdout.
# The createdAt of the most recent NON-agent (bot / real-reviewer) comment on
# the thread, floored at the original finding's createdAt (`.created`). This is
# the "bot's last word" timestamp used by the addressed-elsewhere staleness
# guard (#565): a fix commit only counts as actioning the thread if it
# post-dates this — otherwise a stale fix that predates a later bot re-raise
# would falsely clear live feedback. ISO 8601 sorts lexicographically, so the
# `\>` string comparison is chronological. Single-sourced here so
# derive_tag_class and synth_rationale apply the identical predicate.
latest_nonagent_created() {
  local tj="$1"
  local latest cnt i login created
  latest=$(printf '%s' "$tj" | jq -r '.created // ""')
  cnt=$(printf '%s' "$tj" | jq '.all_comments | length' 2>/dev/null || echo 0)
  i=0
  while [ "$i" -lt "$cnt" ]; do
    login=$(printf '%s' "$tj" | jq -r ".all_comments[$i].author.login // \"\"")
    if ! is_agent_author_local "$login"; then
      created=$(printf '%s' "$tj" | jq -r ".all_comments[$i].createdAt // \"\"")
      if [ -n "$created" ] && { [ -z "$latest" ] || [ "$created" \> "$latest" ]; }; then
        latest="$created"
      fi
    fi
    i=$((i + 1))
  done
  printf '%s' "$latest"
}

# commit_files <sha> → JSON array of the filenames a commit touched, on
# stdout ("" if the per-commit fetch fails). Disk-cached under
# COMMIT_FILES_CACHE_DIR so each sha is fetched at most once across the
# per-thread command-substitution subshells. The PR /commits cache carries
# no file list, so addressed-elsewhere needs this per-commit lookup (#565).
commit_files() {
  local sha="$1"
  [ -z "$sha" ] && return 0
  local cf="$COMMIT_FILES_CACHE_DIR/$sha"
  if [ ! -f "$cf" ]; then
    gh_pat api "repos/$OWNER/$NAME/commits/$sha" --jq '[.files[].filename]' \
      >"$cf" 2>/dev/null || : >"$cf"
  fi
  cat "$cf"
}

# commit_touches_file <sha> <path> → exit 0 if the commit's file list
# includes <path>, 1 otherwise. FAIL CLOSED (#565): a commit whose files
# cannot be read (empty result) does NOT match, so a fetch failure can never
# make a thread look actioned, and an agent commit on an UNRELATED file no
# longer satisfies addressed-elsewhere for this thread.
commit_touches_file() {
  local sha="$1" path="$2" files
  { [ -z "$sha" ] || [ -z "$path" ] || [ "$path" = "(no path)" ]; } && return 1
  files=$(commit_files "$sha")
  [ -z "$files" ] && return 1
  printf '%s' "$files" | jq -e --arg p "$path" 'any(. == $p)' >/dev/null 2>&1
}

# classify_severity_local <body> → P0|P1|...|Nitpick|Trivial|Unknown
# Mirrors the rollup helpers' classify_severity, anchored on the
# first ~600 chars to avoid false-matching severity words deep in
# quoted context.
classify_severity_local() {
  local body_head
  body_head=$(printf '%s' "$1" | head -c 600)
  case "$body_head" in
    *"![P0 Badge]"*|*"P0 Badge"*) echo "P0"; return ;;
    *"![P1 Badge]"*|*"P1 Badge"*) echo "P1"; return ;;
    *"![P2 Badge]"*|*"P2 Badge"*) echo "P2"; return ;;
    *"![P3 Badge]"*|*"P3 Badge"*) echo "P3"; return ;;
    *"🟠 Major"*|*"Potential issue"*|*"⚠️"*) echo "Major"; return ;;
    *"🧹 Nitpick"*|*Nitpick*) echo "Nitpick"; return ;;
    *"🔵 Trivial"*|*Trivial*) echo "Trivial"; return ;;
    *"Outside diff range"*) echo "Trivial"; return ;;
    *Minor*) echo "Minor"; return ;;
  esac
  echo "Unknown"
}

# One-shot fetch of PR file paths + agent-author commits, used by
# derive_tag_class for the addressed-elsewhere heuristic. Cached so
# we make at most one REST call per resolve invocation regardless of
# thread count. Failure is non-fatal: tag derivation falls back to
# the rollup's per-PR weak heuristic if files can't be retrieved.
PR_FILES_CACHE=""
PR_COMMITS_CACHE=""
TAG_DATA_FETCHED=false
fetch_pr_tag_data() {
  $TAG_DATA_FETCHED && return 0
  TAG_DATA_FETCHED=true
  # REST /pulls/{pr}/files and /pulls/{pr}/commits both paginate at
  # 100 items per page. Without pagination, threads anchored on
  # files beyond page 1 silently misclassify on PRs with >100
  # changed files (Codex P2 on #308). We use a manual page loop
  # rather than gh's --paginate so the URL stays in argv-position
  # 2 (gh injects --paginate as $2, which breaks stubs that route
  # on $2 — including test_resolve_pr_threads_rationale_tag.sh).
  PR_FILES_CACHE=$(_fetch_paginated \
    "repos/$OWNER/$NAME/pulls/$PR_NUM/files" \
    '[.[].filename]')
  # PR_COMMITS_CACHE now includes `sha` so synth_rationale can cite
  # the matching commit. The predicate the rationale builds must
  # match derive_tag_class's predicate (CodeRabbit major on #308).
  # login fallback chain (#565 round 8): .author.login is null for commits
  # whose author email is not linked to a GitHub account — which is THIS
  # repo's normal case (commits are authored as nathanjohnpayne with a
  # placeholder .example email). So fall back to .commit.author.name (the git
  # config name, e.g. "nathanjohnpayne", which IS in MERGEPATH_AGENT_AUTHORS)
  # BEFORE the email, or agent fix commits are never recognized as
  # agent-authored and addressed-elsewhere never fires.
  PR_COMMITS_CACHE=$(_fetch_paginated \
    "repos/$OWNER/$NAME/pulls/$PR_NUM/commits" \
    '[.[] | {sha: (.sha // ""), login: (.author.login // .commit.author.name // .commit.author.email // ""), date: (.commit.author.date // .commit.committer.date // "")}]')
}

# _fetch_paginated <base-url> <jq-projection> → JSON array on stdout.
# Manually walks `?per_page=100&page=N` until a page returns fewer
# than 100 items OR a defensive 50-page cap (5,000 items) is hit.
# Falls back to `[]` on first-page failure so downstream treats as
# match-any rather than under-classifying. Test stubs that return a
# pre-transformed JSON array still work: this helper applies a
# `--jq` projection that the stubs ignore (stubs return their own
# canned output), and the per-page-merging stops naturally because
# the canned single-page output has fewer than 100 items.
_fetch_paginated() {
  local base_url="$1"
  local projection="$2"
  local page=1
  local max_pages=50
  local merged='[]'
  local raw count
  while [ "$page" -le "$max_pages" ]; do
    if ! raw=$(gh_pat api "${base_url}?per_page=100&page=${page}" \
        --jq "$projection" 2>/dev/null); then
      [ "$page" -eq 1 ] && { echo '[]'; return; }
      break
    fi
    [ -z "${raw//[[:space:]]/}" ] && break
    count=$(printf '%s' "$raw" | jq 'length' 2>/dev/null || echo 0)
    [ "$count" -eq 0 ] && break
    merged=$(printf '%s\n%s\n' "$merged" "$raw" | jq -s -c '.[0] + .[1]' 2>/dev/null || printf '%s' "$merged")
    [ "$count" -lt 100 ] && break
    page=$((page + 1))
  done
  printf '%s' "$merged"
}

# manifest_canonical_paths — extract canonical + kit paths from the
# repo's .mergepath-sync.yml once. Cached. Returns a newline-separated
# list of path strings (kit entries end with `/`, canonical entries
# do not). Used to classify a thread as `canonical-coverage` when the
# comment's anchored file matches a manifest entry.
MANIFEST_PATHS_CACHE=""
MANIFEST_FETCHED=false
fetch_manifest_paths() {
  $MANIFEST_FETCHED && return 0
  MANIFEST_FETCHED=true
  local manifest="$REPO_ROOT_FOR_MANIFEST/.mergepath-sync.yml"
  [ -f "$manifest" ] || return 0
  # Prefer yq when available — same parser the manifest validator uses.
  # Fall back to a grep-based extraction so the helper still functions
  # in environments without yq (the rollup-classifier-side reading is
  # the same shape).
  # RESOLVE_PR_THREADS_FORCE_NO_YQ=1 forces the grep/awk fallback — a test
  # hook for the #521 no-yq path (CI installs yq, so PATH curation is not
  # portable). Inert in production. Mirrors RESOLVE_PR_THREADS_SKIP_IDENTITY_CHECK.
  if [ -z "${RESOLVE_PR_THREADS_FORCE_NO_YQ:-}" ] && command -v yq >/dev/null 2>&1; then
    MANIFEST_PATHS_CACHE=$(yq -r '.paths[].path' "$manifest" 2>/dev/null || true)
  else
    # Best-effort: read `- path: VALUE` lines. Tolerates surrounding
    # whitespace and optional quotes.
    MANIFEST_PATHS_CACHE=$(grep -E '^[[:space:]]*-[[:space:]]*path:' "$manifest" \
      | sed -E 's/^[[:space:]]*-[[:space:]]*path:[[:space:]]*["'\'']?([^"'\'']+)["'\'']?[[:space:]]*$/\1/')
  fi
}

# path_matches_manifest <file-path> → exit 0 on match, 1 otherwise.
# A file matches a canonical entry if the manifest path equals the
# file path, or if the manifest path ends with `/` (kit) and the file
# starts with it.
path_matches_manifest() {
  local file_path="$1"
  [ -z "$file_path" ] && return 1
  [ "$file_path" = "(no path)" ] && return 1
  fetch_manifest_paths
  [ -z "$MANIFEST_PATHS_CACHE" ] && return 1
  while IFS= read -r mp; do
    [ -z "$mp" ] && continue
    if [ "${mp: -1}" = "/" ]; then
      case "$file_path" in
        "$mp"*) return 0 ;;
      esac
    else
      [ "$file_path" = "$mp" ] && return 0
    fi
  done <<< "$MANIFEST_PATHS_CACHE"
  return 1
}

# fetch_manifest_templated_dests — extract dest + eligible consumer
# slugs for every templated entry in the manifest (#323). Templated
# entries decouple source from dest (the whole point), so a thread
# anchored on a templated dest path doesn't match path_matches_manifest
# above (which reads only .path). Cached.
#
# Cache format: one line per entry, `dest<TAB>repo1,repo2,...` where
# each repoN is the full owner/name slug looked up from
# `.consumers[].repo` via the entry's `.consumers[] (name)` list. The
# repo-slug scoping closes the codex P2 from PR #329 round 1: without
# it, ANY repo whose local file matched the dest path got the
# `templated-render` class, even repos not opted into that entry —
# suppressing substantive unresolved feedback on unrelated files in
# the daily rollup.
MANIFEST_TEMPLATED_DESTS_CACHE=""
MANIFEST_TEMPLATED_FETCHED=false
fetch_manifest_templated_dests() {
  $MANIFEST_TEMPLATED_FETCHED && return 0
  MANIFEST_TEMPLATED_FETCHED=true
  local manifest="$REPO_ROOT_FOR_MANIFEST/.mergepath-sync.yml"
  [ -f "$manifest" ] || return 0
  # RESOLVE_PR_THREADS_FORCE_NO_YQ=1 forces the grep/awk fallback — a test
  # hook for the #521 no-yq path (CI installs yq, so PATH curation is not
  # portable). Inert in production. Mirrors RESOLVE_PR_THREADS_SKIP_IDENTITY_CHECK.
  if [ -z "${RESOLVE_PR_THREADS_FORCE_NO_YQ:-}" ] && command -v yq >/dev/null 2>&1; then
    # #467: a path entry's `consumers` is EITHER a sequence of names OR
    # the scalar literal `all`. The prior single-pass expression did
    # `.consumers // [] | map(...)`, which on the scalar `all` tried to
    # `map` over a string — a yq runtime error that, under `|| true`,
    # blanked the ENTIRE templated-dest cache. One `consumers: all`
    # templated entry thus silently disabled templated-render
    # classification for every entry. Resolve the two shapes in two
    # passes (mirrors check_sync_manifest, which splits the same way to
    # dodge mikefarah/yq's inline if/then/else limits), then merge.
    #
    # Pass 1 — scalar `consumers: all` → every consumer's repo slug.
    # Bind the full repo list inline with `as $all`; mikefarah yq has no
    # jq-style `--arg`, but it supports `... as $var` (same mechanism as
    # the `. as $root` lookup in pass 2).
    local _all_rows _seq_rows
    _all_rows=$(yq -r '
      . as $root |
      ($root.consumers | map(.repo) | join(",")) as $all |
      .paths[]
      | select(.type == "templated")
      | select(.consumers == "all")
      | (.dest // .path) + "\t" + $all
    ' "$manifest" 2>/dev/null || true)
    # Pass 2 — sequence consumers → resolve each name to its repo slug.
    # `. as $root` exposes the top-level consumers table for the inner
    # lookup. The `tag == "!!seq"` guard keeps the scalar form away from
    # the `map` that errored before. Output: `dest<TAB>repo,repo,...`.
    _seq_rows=$(yq -r '
      . as $root |
      .paths[]
      | select(.type == "templated")
      | select(.consumers | tag == "!!seq")
      | [ (.dest // .path),
          (.consumers | map(. as $name |
             $root.consumers[] | select(.name == $name) | .repo) | join(",")) ]
        | @tsv
    ' "$manifest" 2>/dev/null || true)
    MANIFEST_TEMPLATED_DESTS_CACHE=$(printf '%s\n%s\n' "$_all_rows" "$_seq_rows" | grep -v '^[[:space:]]*$' || true)
  else
    # awk fallback — mirrors the canonical-paths fallback above. Pair
    # `type:` and `dest:` (or fall back to `path:`) within a `paths:`
    # block entry. Less precise than yq in two ways, both addressed
    # below per CR Major #329 round 2:
    #
    # 1. Order-independent emission. The prior version emitted on the
    #    `type: templated` line, which broke when `dest:` appeared
    #    AFTER `type:` (legal YAML, common in manifest practice). Now
    #    we emit at entry boundaries (start of next entry / end of
    #    paths block / EOF) so `dest:` and `type:` can appear in any
    #    order within an entry.
    #
    # 2. Strict no-match instead of loose-match. The prior version
    #    emitted the dest with an empty consumers field, which
    #    path_matches_templated_dest interpreted as "match any repo"
    #    — reintroducing the exact cross-repo misclassification this
    #    fix is trying to close. Now the awk path emits a sentinel
    #    `__AWK_NO_CONSUMER_SCOPE__` token in the consumers field,
    #    which path_matches_templated_dest treats as "no match" (the
    #    cautious failure mode: under-classify rather than over-
    #    classify; templated-render is a skip-class, and a missed
    #    skip just falls back to the rollup's general heuristics).
    #
    # 3. `consumers: all` parity with the yq path (#521). The yq pass-1
    #    resolves a scalar `consumers: all` to EVERY consumer's repo slug,
    #    i.e. match-any-consumer. The awk fallback previously could not
    #    distinguish `all` from a name list (it never parsed `consumers:`),
    #    so an `all` templated entry was under-classified along with every
    #    other entry. We now detect the scalar `consumers: all` per entry
    #    and emit a dedicated `__AWK_CONSUMERS_ALL__` sentinel, which
    #    path_matches_templated_dest treats as "match any repo" — mirroring
    #    the yq semantics. A `consumers:` followed by a name SEQUENCE stays
    #    the cautious no-scope sentinel (awk can't reliably resolve
    #    name→repo cross-references), matching the prior behavior for lists.
    # Pre-extract top-level consumer repos so the awk path can resolve
    # `consumers: all` to an actual repo slug list — matching what the yq
    # pass-1 does via `$root.consumers | map(.repo) | join(",")`. Without
    # this, the `consumers: all` sentinel matched every repo unconditionally,
    # including foreign repos not in the consumers list (#554 item 1 / #556).
    local _awk_all_repos
    _awk_all_repos=$(awk '
      /^consumers:/ { in_c=1; next }
      in_c && /^[^[:space:]#]/ { in_c=0 }
      in_c && /^[[:space:]]*repo:/ {
        v=$0
        sub(/^[[:space:]]*repo:[[:space:]]*/, "", v)
        sub(/[[:space:]]*#.*$/, "", v)
        gsub(/^[[:space:]]+|[[:space:]]+$|^["\047]|["\047]$/, "", v)
        if (v != "") repos = repos (repos=="" ? "" : ",") v
      }
      END { print repos }
    ' "$manifest" 2>/dev/null || true)
    MANIFEST_TEMPLATED_DESTS_CACHE=$(awk -v all_repos="$_awk_all_repos" '
      function emit() {
        if (cur_type == "templated") {
          out = (cur_dest != "" ? cur_dest : cur_path)
          if (out != "") {
            if (cur_consumers_all) {
              # Resolve `consumers: all` to the actual consumer repo list so
              # path_matches_templated_dest can check $REPO membership, mirroring
              # the yq pass-1 behaviour. Fall back to no-scope if the list is
              # empty (cannot determine membership → conservative non-match).
              if (all_repos != "") {
                printf "%s\t%s\n", out, all_repos
              } else {
                printf "%s\t__AWK_NO_CONSUMER_SCOPE__\n", out
              }
            } else {
              printf "%s\t__AWK_NO_CONSUMER_SCOPE__\n", out
            }
          }
        }
      }
      /^paths:/ { in_p = 1; next }
      in_p && /^[^[:space:]#]/ { emit(); in_p = 0 }
      !in_p { next }
      /^[[:space:]]*-[[:space:]]*path:/ {
        emit()
        cur_path = $0
        sub(/^[[:space:]]*-[[:space:]]*path:[[:space:]]*/, "", cur_path)
        sub(/[[:space:]]*#.*$/, "", cur_path)
        gsub(/^[[:space:]]+|[[:space:]]+$|^"|"$/, "", cur_path)
        cur_dest = ""; cur_type = ""; cur_consumers_all = 0
      }
      /^[[:space:]]*dest:/ {
        cur_dest = $0
        sub(/^[[:space:]]*dest:[[:space:]]*/, "", cur_dest)
        sub(/[[:space:]]*#.*$/, "", cur_dest)
        gsub(/^[[:space:]]+|[[:space:]]+$|^"|"$/, "", cur_dest)
      }
      /^[[:space:]]*type:[[:space:]]*templated/ {
        cur_type = "templated"
      }
      # Scalar `consumers: all` (optionally quoted / trailing comment).
      # A sequence form (`consumers:` then `- name` lines) does NOT match
      # this pattern, so it correctly falls through to the no-scope sentinel.
      /^[[:space:]]*consumers:[[:space:]]*["\047]?all["\047]?[[:space:]]*(#.*)?$/ {
        cur_consumers_all = 1
      }
      END { emit() }
    ' "$manifest")
  fi
}

# path_matches_templated_dest <file-path> → exit 0 if it matches a
# templated entry's dest path AND the current repo ($REPO) is in that
# entry's consumers list, 1 otherwise. Used by derive_tag_class to
# emit the `templated-render` class (#323). The consumer-scope check
# closes codex P2 from PR #329 round 1.
path_matches_templated_dest() {
  local file_path="$1"
  [ -z "$file_path" ] && return 1
  [ "$file_path" = "(no path)" ] && return 1
  fetch_manifest_templated_dests
  [ -z "$MANIFEST_TEMPLATED_DESTS_CACHE" ] && return 1
  local line dest consumers
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    # Split on the first tab. Two-field TSV: dest<TAB>repo1,repo2,...
    dest="${line%%$'\t'*}"
    consumers="${line#*$'\t'}"
    [ "$file_path" = "$dest" ] || continue
    # Legacy sentinel — the awk fallback previously emitted this when it
    # detected `consumers: all` but could not resolve the consumer repo list.
    # The awk path now resolves `all` to the actual repo slug list (matching
    # the yq path), so this sentinel is no longer emitted in practice (#556).
    # Kept as a safety net: if somehow emitted, fall through to no-scope
    # (conservative non-match) rather than matching unconditionally.
    if [ "$consumers" = "__AWK_CONSUMERS_ALL__" ]; then
      continue
    fi
    # The awk fallback emits this sentinel when it can't resolve
    # consumer-name → repo-slug (cross-references in awk are
    # brittle). Treat sentinel as "no scope information available"
    # and DO NOT match — better to miss the templated-render skip
    # tag (falling through to other heuristics in the rollup) than
    # to over-classify and silently suppress substantive feedback
    # on unrelated files. (CR Major #329 round 2.)
    if [ "$consumers" = "__AWK_NO_CONSUMER_SCOPE__" ]; then
      continue
    fi
    # Empty consumers field — yq returned no consumer matches for
    # this entry (entry has no `consumers:` list, or none of the
    # named consumers resolve to a repo). Treat as no-scope
    # information, same as the awk sentinel: don't match.
    if [ -z "$consumers" ]; then
      continue
    fi
    # The current repo ($REPO, populated from --repo arg or origin
    # remote at module-load) MUST appear in the comma-separated
    # consumers list. Anchored grep avoids partial-name false hits
    # (e.g., `owner/matchline` vs `owner/matchline-app`).
    if printf ',%s,' "$consumers" | grep -qF ",$REPO,"; then
      return 0
    fi
  done <<< "$MANIFEST_TEMPLATED_DESTS_CACHE"
  return 1
}

# Module-load-time: pin the manifest base. We resolve REPO_ROOT_FOR_MANIFEST
# from the script's on-disk location, NOT $REPO (which is the gh repo
# slug). This intentionally reads the LOCAL working-tree manifest —
# the same file scripts/sync-to-downstream.sh authors against — so the
# helper's canonical-coverage class agrees with what would actually
# propagate.
REPO_ROOT_FOR_MANIFEST="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# derive_tag_class — given the thread JSON (one line of UNRESOLVED),
# return one of the rollup's class strings on stdout.
#
# Decision ladder (highest-confidence first; matches the
# spec § Class taxonomy from issue #305):
#   1. canonical-coverage     anchored path is in the manifest
#   1b. templated-render      anchored path is a templated dest
#                             (#323) — same "mergepath concern" class
#                             as canonical-coverage but on the
#                             templated surface; emitted only when the
#                             path is NOT also matched by 1 (the dests
#                             never appear as .path entries by
#                             construction — source ≠ dest is the
#                             point — so the two branches don't
#                             overlap in practice).
#   2. addressed-elsewhere    agent-author commit after createdAt
#                             touching the anchored file
#   3. rebuttal-recorded      ≥30-char agent-author reply on thread
#   4. nitpick-noted          severity is Nitpick/Trivial/P3
#   5. deferred-to-followup   fallback
#
# Why canonical-coverage wins over addressed-elsewhere: a finding on
# a propagated canonical path is structurally a mergepath concern;
# the rollup should route it to mergepath regardless of whether the
# local PR happened to also touch the file. (Addressed-elsewhere is
# stronger evidence for a one-off finding but doesn't say anything
# about WHERE the durable fix should live.)
derive_tag_class() {
  local thread_json="$1"
  # skip_routing (#565): when non-empty (the --resolve-actioned GATE path),
  # the routing-only classes canonical-coverage / templated-render are NOT
  # emitted — neither from a recorded marker (step 0) nor from the path
  # checks (steps 1 / 1b) — so the ladder falls through to real ACTION
  # evidence (addressed-elsewhere / rebuttal-recorded). The default (empty)
  # keeps the routing-first ladder for the --auto-resolve-bots tag / daily
  # rollup, where routing context is wanted. This decouples the actioned
  # GATE (needs proof of action) from the routing TAG (proof of where a fix
  # belongs): a fresh canonical-path finding is still NOT actioned, but a
  # canonical-path thread that WAS fixed or rebutted now is (nathanpayne-codex
  # P1 CHANGES_REQUESTED on #565 — routing was masking real action evidence).
  local skip_routing="${2:-}"
  local thread_path
  local thread_body
  thread_path=$(printf '%s' "$thread_json" | jq -r '.path // ""')
  thread_body=$(printf '%s' "$thread_json" | jq -r '.body // ""')
  # NB: the original-finding timestamp (.created) is intentionally NOT used
  # directly for the addressed-elsewhere check — that compares against the
  # LATEST bot/reviewer comment via latest_nonagent_created (#565).

  # 0. honor an existing [mergepath-resolve: <class>] marker (#564, Codex
  # P2 + CodeRabbit Major on #565). A prior resolve attempt — e.g. a
  # deferred-to-followup that was tagged but whose resolve readback-failed,
  # or a thread re-opened after tagging — leaves an agent-authored marker
  # reply on the thread. That marker records an explicit classification
  # decision and is preferred over the heuristic ladder below: without it,
  # the rebuttal-recorded step (#3) mis-reads the marker reply itself (it is
  # ≥30 chars and agent-authored) as a rebuttal. Mirrors
  # daily-feedback-rollup-helpers.sh, which also prefers the recorded tag.
  #
  # STALENESS GUARD (CodeRabbit Major on #565): a marker is authoritative
  # only as the agent's "last word". An ACTIONED marker followed by fresh
  # non-agent (bot/reviewer) feedback is stale — honoring it would resolve a
  # thread the bot just re-raised — so it is honored ONLY when it post-dates
  # the most recent non-agent comment; otherwise it falls through to the
  # ladder (which applies the same last-word rule to rebuttals). A SURFACE
  # marker (nitpick-noted / deferred-to-followup) is honored regardless,
  # because it only ever causes a skip — the fail-closed/safe outcome — even
  # if later replies exist. Most-recent valid marker wins; an unrecognized
  # class is ignored. `last_nonagent_idx` is reused by step 3.
  local recorded_class="" rc_count rc_i rc_login rc_body rc_tag
  local last_marker_idx=-1 last_nonagent_idx=-1
  rc_count=$(printf '%s' "$thread_json" | jq '.all_comments | length' 2>/dev/null || echo 0)
  rc_i=0
  while [ "$rc_i" -lt "$rc_count" ]; do
    rc_login=$(printf '%s' "$thread_json" | jq -r ".all_comments[$rc_i].author.login // \"\"")
    if is_agent_author_local "$rc_login"; then
      rc_body=$(printf '%s' "$thread_json" | jq -r ".all_comments[$rc_i].body // \"\"")
      rc_tag=$(printf '%s' "$rc_body" \
        | sed -n 's/.*\[mergepath-resolve:[[:space:]]*\([a-z][a-z-]*\)[[:space:]]*\].*/\1/p' | head -1)
      if [ -n "$rc_tag" ]; then recorded_class="$rc_tag"; last_marker_idx=$rc_i; fi
    else
      last_nonagent_idx=$rc_i
    fi
    rc_i=$((rc_i + 1))
  done
  # Honor a recorded marker ONLY in the TAG path (default). The GATE path
  # (--resolve-actioned / skip_routing) treats ANY marker as rationale only
  # and falls through to re-derive fresh evidence below — so a stale marker
  # (from an earlier deferral, a readback-failed resolve, or the older weak
  # heuristic this patch replaces) can never resolve a thread without
  # re-checking the fix commit / rebuttal against the latest comments. This
  # closes the marker-staleness cluster on #565 (re-verify actioned markers;
  # let later fixes override stale surface markers; don't let stale deferral
  # tags mask later rebuttals). `last_nonagent_idx` is reused by step 3.
  if [ -z "$skip_routing" ]; then
    case "$recorded_class" in
      addressed-elsewhere|rebuttal-recorded)
        # Genuinely-actioned marker: honor only if it is the agent's last
        # word, so a stale marker followed by fresh bot feedback cannot
        # resolve a re-raised thread.
        if [ "$last_marker_idx" -gt "$last_nonagent_idx" ]; then
          echo "$recorded_class"
          return
        fi ;;
      canonical-coverage|templated-render|nitpick-noted|deferred-to-followup)
        # Routing / surface markers: honoring even a stale one only routes or
        # skips (never a wrong resolve), so the TAG path honors it
        # unconditionally to keep the recorded class flowing to the rollup.
        echo "$recorded_class"
        return ;;
    esac
  fi

  # 1. canonical-coverage (routing — skipped in the GATE path so real action
  # evidence on a canonical path is not masked, #565).
  if [ -z "$skip_routing" ] && path_matches_manifest "$thread_path"; then
    echo "canonical-coverage"
    return
  fi

  # 1b. templated-render (#323) — path matches a templated entry's
  # dest. Same "mergepath concern" routing as canonical-coverage; the
  # rendered output came from a template in mergepath, so the fix
  # should land in mergepath too. We don't (and can't, from here)
  # re-run verify-propagation-pr.sh to confirm the bytes match — but
  # the path predicate alone is the right signal: if a thread is
  # anchored on the templated dest, the durable fix is either in
  # mergepath's template or in the consumer's facts:* block.
  if [ -z "$skip_routing" ] && path_matches_templated_dest "$thread_path"; then
    echo "templated-render"
    return
  fi

  # 2. addressed-elsewhere — an agent-authored commit that BOTH (a)
  # post-dates the latest bot/reviewer comment (the #565 staleness guard)
  # AND (b) actually TOUCHES the anchored file. Both are required.
  #
  # The earlier form gated on two independent PR-level facts — "the anchored
  # file is in the PR's overall changed-file list" AND "some agent commit
  # post-dates the re-raise" — which do not compose: an agent commit on an
  # UNRELATED file could satisfy the date check while a stale/earlier commit
  # was the only one touching the anchored file, so live feedback got
  # resolved (nathanpayne-codex CHANGES_REQUESTED on #565). The PR /commits
  # cache has no per-commit file list, so confirm per commit via
  # commit_touches_file (cached). Fail closed: a commit whose files cannot
  # be read does not qualify, and a pathless thread cannot be proven here.
  fetch_pr_tag_data
  local last_nonagent_created
  last_nonagent_created=$(latest_nonagent_created "$thread_json")
  if [ -n "$last_nonagent_created" ] && [ -n "$PR_COMMITS_CACHE" ] \
     && [ -n "$thread_path" ] && [ "$thread_path" != "(no path)" ]; then
    # Cheap PR-level pre-filter: if the PR's overall changed-file list is
    # known and does NOT include the anchored file, no commit touched it —
    # skip the per-commit fetches. When the list is empty/unavailable we
    # cannot pre-filter, so fall through to the authoritative per-commit
    # check below (which is itself fail-closed).
    local pr_touched_file=true
    if [ -n "$PR_FILES_CACHE" ] && [ "$PR_FILES_CACHE" != "[]" ]; then
      if ! printf '%s' "$PR_FILES_CACHE" \
           | jq -e --arg p "$thread_path" 'any(. == $p)' >/dev/null 2>&1; then
        pr_touched_file=false
      fi
    fi
    if $pr_touched_file; then
      local commit_count
      commit_count=$(printf '%s' "$PR_COMMITS_CACHE" | jq 'length' 2>/dev/null || echo 0)
      local i=0
      while [ "$i" -lt "$commit_count" ]; do
        local c_login
        local c_date
        local c_sha
        c_login=$(printf '%s' "$PR_COMMITS_CACHE" | jq -r ".[$i].login // \"\"")
        c_date=$(printf '%s' "$PR_COMMITS_CACHE" | jq -r ".[$i].date // \"\"")
        c_sha=$(printf '%s' "$PR_COMMITS_CACHE" | jq -r ".[$i].sha // \"\"")
        # Order matters: cheap date/identity checks short-circuit BEFORE the
        # per-commit file fetch, so we only fetch files for an agent commit
        # that post-dates the re-raise.
        if [ -n "$c_login" ] && [ -n "$c_date" ] \
           && [ "$c_date" \> "$last_nonagent_created" ] \
           && is_agent_author_local "$c_login" \
           && commit_touches_file "$c_sha" "$thread_path"; then
          echo "addressed-elsewhere"
          return
        fi
        i=$((i + 1))
      done
    fi
  fi

  # 3. rebuttal-recorded — ≥30-char reply from an agent author.
  # Skip index 0 (the original review comment).
  local reply_count
  reply_count=$(printf '%s' "$thread_json" | jq '.all_comments | length' 2>/dev/null || echo 0)
  if [ "$reply_count" -gt 1 ]; then
    # Only replies AFTER the bot's most recent comment count (CodeRabbit
    # Major on #565): a rebuttal that predates a later bot re-raise is stale
    # and must not mark the thread actioned. last_nonagent_idx was computed
    # in step 0. Start the scan just past the last non-agent comment (but at
    # least index 1, to always skip the original finding at index 0).
    local k=$((last_nonagent_idx + 1))
    [ "$k" -lt 1 ] && k=1
    while [ "$k" -lt "$reply_count" ]; do
      local r_login
      local r_body
      local r_body_len
      r_login=$(printf '%s' "$thread_json" | jq -r ".all_comments[$k].author.login // \"\"")
      r_body=$(printf '%s' "$thread_json" | jq -r ".all_comments[$k].body // \"\"")
      r_body_len=${#r_body}
      # Skip our own [mergepath-resolve: ...] marker replies — a resolution
      # marker is not a rebuttal (step 0 already honored a recognized one;
      # this also covers an unrecognized-class marker). Codex P2 on #565.
      case "$r_body" in
        *"[mergepath-resolve:"*) k=$((k + 1)); continue ;;
      esac
      if [ -n "$r_login" ] && [ "$r_body_len" -ge 30 ] && is_agent_author_local "$r_login"; then
        echo "rebuttal-recorded"
        return
      fi
      k=$((k + 1))
    done
  fi

  # 4. nitpick-noted
  local sev
  sev=$(classify_severity_local "$thread_body")
  case "$sev" in
    Nitpick|Trivial|P3) echo "nitpick-noted"; return ;;
  esac

  # 5. fallback
  echo "deferred-to-followup"
}

# class_is_actioned <class> — exit 0 if the class is a DEMONSTRABLY-ACTIONED
# class, 1 otherwise. This is the gate for --resolve-actioned (#564): only
# resolve threads whose fix or accepted rebuttal is demonstrable from the
# current PR state, leaving the rest unresolved so the weekly sweep keeps
# surfacing them.
#
# Only two classes prove ACTION on this PR:
#   addressed-elsewhere  an agent commit that touches the anchored file and
#                        post-dates the latest re-raise (verified per-commit)
#   rebuttal-recorded    a substantive agent rebuttal that post-dates the
#                        latest re-raise on the thread
#
# This is intentionally STRICTER than (a subset of) the rollup's skip-set in
# scripts/lib/daily-feedback-rollup-helpers.sh `tag_class_action`, which also
# skips canonical-coverage and templated-render. Those are ROUTING classes —
# derived from path/manifest membership alone, before any fix-commit or
# rebuttal evidence. Routing tells you WHERE a durable fix belongs (upstream
# in mergepath), NOT that one happened: a fresh, unfixed bot finding on a
# canonical path (e.g. scripts/resolve-pr-threads.sh is itself canonical)
# would classify as canonical-coverage. Treating that as actioned would
# resolve live, unactioned feedback — the exact failure #564 guards against
# (nathanpayne-codex P1 CHANGES_REQUESTED on #565). So routing classes are
# EXCLUDED from the actioned gate; --auto-resolve-bots / the daily rollup
# may still record canonical/templated context, but the actioned-only
# resolver must not equate routing with action. Unknown classes are NOT
# actioned — fail safe.
class_is_actioned() {
  case "$1" in
    addressed-elsewhere|rebuttal-recorded)
      return 0 ;;
    *)
      return 1 ;;
  esac
}

# synth_rationale <class> <thread_json> → one-line free-form rationale
# matching the class. Kept short (≤120 chars) so the reply stays
# compact in the GitHub UI. The classifier reads only the tag in
# brackets; the rationale is purely human-facing.
synth_rationale() {
  local class="$1"
  local thread_json="$2"
  local thread_path
  thread_path=$(printf '%s' "$thread_json" | jq -r '.path // ""')
  local short_sha=""
  case "$class" in
    addressed-elsewhere)
      # Surface the SHA of a commit that actually satisfies
      # derive_tag_class's predicate (agent-authored AND authoredDate >
      # the latest bot/reviewer comment). Re-run the SAME check here — using
      # the same last_nonagent_created floor (#565) — so the cited SHA
      # matches the one that triggered the classification rather than a
      # pre-thread or stale commit.
      local last_nonagent_created
      last_nonagent_created=$(latest_nonagent_created "$thread_json")
      local commit_count i
      commit_count=$(printf '%s' "$PR_COMMITS_CACHE" | jq 'length' 2>/dev/null || echo 0)
      i=0
      while [ "$i" -lt "$commit_count" ]; do
        local c_login c_date c_sha
        c_login=$(printf '%s' "$PR_COMMITS_CACHE" | jq -r ".[$i].login // \"\"")
        c_date=$(printf '%s' "$PR_COMMITS_CACHE" | jq -r ".[$i].date // \"\"")
        c_sha=$(printf '%s' "$PR_COMMITS_CACHE" | jq -r ".[$i].sha // \"\"")
        if [ -n "$c_login" ] && [ -n "$c_date" ] \
           && { [ -z "$last_nonagent_created" ] || [ "$c_date" \> "$last_nonagent_created" ]; } \
           && is_agent_author_local "$c_login" \
           && commit_touches_file "$c_sha" "$thread_path"; then
          short_sha="$c_sha"
          break
        fi
        i=$((i + 1))
      done
      if [ -n "$short_sha" ] && [ -n "$thread_path" ] && [ "$thread_path" != "(no path)" ]; then
        echo "addressed by commit ${short_sha:0:7} (touching $thread_path)."
      elif [ -n "$short_sha" ]; then
        echo "addressed by commit ${short_sha:0:7}."
      else
        echo "addressed by a follow-up commit on this PR."
      fi
      ;;
    canonical-coverage)
      if [ -n "$thread_path" ] && [ "$thread_path" != "(no path)" ]; then
        echo "path $thread_path is propagated canonical content (.mergepath-sync.yml)."
      else
        echo "thread is on propagated canonical content (.mergepath-sync.yml)."
      fi
      ;;
    templated-render)
      # #323 — the dest is rendered from a mergepath template with
      # consumer facts. verify-propagation-pr.sh re-renders and
      # byte-compares as part of the propagation-lane gate; if a
      # thread persists on a templated dest, the durable fix lives in
      # mergepath's template or the consumer's facts:* block.
      if [ -n "$thread_path" ] && [ "$thread_path" != "(no path)" ]; then
        echo "$thread_path is a templated dest rendered from mergepath; fix belongs in the template or consumer facts."
      else
        echo "thread is on a templated dest rendered from mergepath; fix belongs in the template or consumer facts."
      fi
      ;;
    nitpick-noted)
      echo "nitpick/trivial severity; noted, no code change."
      ;;
    rebuttal-recorded)
      echo "agent rebuttal posted on thread; resolving."
      ;;
    deferred-to-followup|*)
      echo "deferred to follow-up; resolving for branch-protection conversation gate."
      ;;
  esac
}

# We also want to capture the SHA in PR_COMMITS_CACHE for the
# rationale — re-pull with .sha included. (Earlier fetch_pr_tag_data
# elided it to keep the cache small. Refetch in a backwards-compatible
# way: only add the column when the original fetch already populated.)
augment_pr_commits_with_sha() {
  $TAG_DATA_FETCHED || return 0
  # If already augmented (cache has .sha), skip.
  if printf '%s' "$PR_COMMITS_CACHE" | jq -e '.[0].sha // empty' >/dev/null 2>&1; then
    return 0
  fi
  # Same login fallback chain as fetch_pr_tag_data (#565 round 8):
  # .commit.author.name before the (often-unlinked) email so agent-authored
  # commits are recognized.
  PR_COMMITS_CACHE=$(gh_pat api "repos/$OWNER/$NAME/pulls/$PR_NUM/commits?per_page=100" \
    --jq '[.[] | {sha: .sha, login: (.author.login // .commit.author.name // .commit.author.email // ""), date: (.commit.author.date // .commit.committer.date // "")}]' 2>/dev/null || echo "$PR_COMMITS_CACHE")
}

# post_tag_reply — emit a `[mergepath-resolve: <class>] <rationale>`
# reply on the thread via the GraphQL addPullRequestReviewThreadReply
# mutation. Logs and returns non-zero on failure; the caller should
# log a warning and proceed to the resolve mutation regardless.
#
# The mutation requires the `pullRequestReviewThreadId` (the same id
# resolveReviewThread takes) plus a body. The reply author follows
# the PAT used for the call — same identity verification as the
# resolve mutation, no separate gate needed.
post_tag_reply() {
  local thread_id="$1"
  local class="$2"
  local rationale="$3"
  local body
  body="[mergepath-resolve: $class] $rationale"
  # Suppress stdout (the mutation response is noise), but capture
  # stderr for failure-mode logging. The redirection order matters:
  # `2>&1 1>/dev/null` first dups stderr to stdout (so it lands in
  # the command substitution), then redirects the original stdout to
  # /dev/null. The reversed form (`>/dev/null 2>&1`) discards both
  # streams and leaves $err empty — see #shellcheck SC2327/SC2328.
  local err
  if ! err=$(gh_pat api graphql \
    -f query='mutation($id: ID!, $body: String!) {
      addPullRequestReviewThreadReply(input: {pullRequestReviewThreadId: $id, body: $body}) {
        comment { id }
      }
    }' \
    -F id="$thread_id" \
    -F body="$body" \
    2>&1 1>/dev/null); then
    printf 'tag-reply mutation failed: %s\n' "$err" >&2
    return 1
  fi
  return 0
}

# auto-resolve-bots mode: resolve bot threads, leave human threads alone.
# Use process substitution (`< <(...)`) instead of `echo $UNRESOLVED | while`
# so the loop runs in the parent shell — counter increments survive past the
# loop and the trailing summary is accurate.
RESOLVED_COUNT=0
SKIPPED_HUMAN=0
SKIPPED_STALE=0
# #564 --resolve-actioned: threads skipped because their derived class is
# NOT demonstrably actioned (surface-set: nitpick-noted / deferred-to-
# followup). Left unresolved on purpose so the weekly sweep still surfaces
# them; counted so the exit code reflects that work remains.
SKIPPED_NOT_ACTIONED=0
WOULD_RESOLVE_COUNT=0
FAILED_COUNT=0
TAG_REPLY_POSTED=0
TAG_REPLY_FAILED=0
TAG_REPLY_SKIPPED=0
# #564 — post-resolve readback. RESOLVED_IDS collects the GraphQL node IDs
# of threads whose resolve mutation reported isResolved:true, so the
# consolidated readback after the loop can re-read each and confirm the
# state actually persisted. The loop runs in the parent shell (process
# substitution below), so a plain array survives past it. READBACK_FAILED
# counts threads that did NOT read back isResolved:true — a fail-closed
# signal that forces a non-zero exit.
RESOLVED_IDS=()
READBACK_FAILED=0
while IFS= read -r thread; do
  AUTHOR=$(echo "$thread" | jq -r .author)
  THREAD_ID=$(echo "$thread" | jq -r .id)
  PATH_=$(echo "$thread" | jq -r .path)
  EXCERPT=$(echo "$thread" | jq -r .excerpt)
  COMMIT_OID=$(echo "$thread" | jq -r .commit_oid)

  if ! [[ "$AUTHOR" =~ $BOT_LOGINS_RE ]]; then
    echo "  SKIP (non-bot author $AUTHOR): $PATH_"
    echo "    $EXCERPT"
    SKIPPED_HUMAN=$((SKIPPED_HUMAN + 1))
    continue
  fi

  # Current-HEAD check — applies to --auto-resolve-bots ONLY. The contract
  # there is "resolve only when the latest comment is on the current HEAD":
  # a thread anchored to an older commit means the agent's most recent push
  # has not been re-reviewed by the bot, so resolving it would force-clear
  # an unaddressed finding.
  #
  # --resolve-actioned BYPASSES this proxy (#565): pushing a fix commit
  # advances HEAD while the bot's last comment still points at the previous
  # commit, so this gate would skip a fixed-by-commit thread as "stale"
  # before derive_tag_class could see the fix. Instead, --resolve-actioned
  # relies on its stronger, direct evidence check (a fix commit touching the
  # anchored file AFTER the latest bot/reviewer comment, or a rebuttal after
  # the bot's last word) — so a later fix commit is recognized even when the
  # bot has not re-commented on the new HEAD.
  #
  # Codex r1 on PR #172 caught that the previous check
  # `if [ -n "$COMMIT_OID" ] && [ "$COMMIT_OID" != "$HEAD_OID" ]`
  # treated EMPTY commit_oid as "matches HEAD" → bot threads with no
  # commit linkage in the GraphQL response would be force-resolved
  # silently. The safe default is the opposite: missing oid is
  # treated as stale.
  if [ "$MODE" != "resolve-actioned" ] \
     && { [ -z "$COMMIT_OID" ] || [ "$COMMIT_OID" = "null" ] || [ "$COMMIT_OID" != "$HEAD_OID" ]; }; then
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

  # #564 --resolve-actioned: gate the resolve on demonstrable action.
  # Derive the thread's class BEFORE the dry-run / tag steps, but ONLY in
  # resolve-actioned mode — auto-resolve-bots keeps its existing behavior
  # (resolve every current-HEAD bot thread to clear the conversation gate;
  # the daily rollup re-surfaces deferrals), and in particular must NOT
  # make tag-data API calls on a --dry-run. Threads whose class is not in
  # the actioned skip-set are left unresolved so the weekly sweep keeps
  # surfacing them.
  thread_class=""
  thread_class_computed=false
  if [ "$MODE" = "resolve-actioned" ]; then
    fetch_pr_tag_data
    augment_pr_commits_with_sha
    # GATE path: classify with routing skipped, so a canonical/templated
    # thread that was actually fixed/rebutted resolves on its action
    # evidence, while a fresh routing-only finding still falls through to a
    # non-actioned class and is left for the sweep (#565).
    thread_class=$(derive_tag_class "$thread" skip-routing)
    thread_class_computed=true
    if ! class_is_actioned "$thread_class"; then
      echo "  SKIP (not demonstrably actioned: $thread_class): [$AUTHOR] $PATH_"
      echo "    $EXCERPT"
      echo "    Left unresolved so the weekly sweep still surfaces it. Fix or"
      echo "    rebut the finding, or defer it via --auto-resolve-bots --rationale."
      SKIPPED_NOT_ACTIONED=$((SKIPPED_NOT_ACTIONED + 1))
      continue
    fi
  fi

  if $DRY_RUN; then
    echo "  WOULD RESOLVE [$AUTHOR] $PATH_"
    echo "    $EXCERPT"
    WOULD_RESOLVE_COUNT=$((WOULD_RESOLVE_COUNT + 1))
    continue
  fi

  # mergepath#305 — emit `[mergepath-resolve: <class>] <rationale>`
  # reply BEFORE the resolve mutation. The classifier in
  # scripts/lib/daily-feedback-rollup-helpers.sh reads this tag and
  # prioritizes it over its own heuristics; the tag therefore must
  # land on the thread BEFORE the thread is resolved (otherwise the
  # rollup that runs next is reading a closed thread with no marker).
  #
  # Failure to post the tag is logged + counted, but does NOT block
  # the resolve mutation. The rollup's heuristic fallback is the same
  # behavior the script had before #305 — losing the tag is a soft
  # regression, not a correctness bug.
  if ! $NO_TAG_REPLY; then
    if $RATIONALE_FLAG_USED; then
      tag_class="deferred-to-followup"
      tag_rationale="$RATIONALE_OVERRIDE"
    else
      # Warm the tag-data cache (PR_FILES_CACHE / PR_COMMITS_CACHE +
      # the TAG_DATA_FETCHED guard) in THIS shell BEFORE the command-
      # substitution subshells below. Without this, fetch_pr_tag_data
      # runs inside derive_tag_class's subshell, populates the caches
      # in that subshell, and the parent shell never sees them — so
      # synth_rationale (also in a subshell) finds PR_COMMITS_CACHE
      # empty, emits `[: : integer expression expected` on line ~773,
      # and falls back to the generic no-SHA rationale. nathanpayne-
      # codex Phase 4b on #308 reproduced this with a page-2 files
      # fixture. Calling here also fulfills the "one-shot cache reused
      # across threads" intention — fetch_pr_tag_data's TAG_DATA_FETCHED
      # short-circuit only works if it's set in the loop's shell.
      #
      # #564: resolve-actioned mode already derived the class (and warmed
      # the caches) above — reuse it so derive_tag_class / synth_rationale
      # run at most once per thread.
      if ! $thread_class_computed; then
        fetch_pr_tag_data
        # Need the augmented commits cache (with .sha) for the
        # addressed-elsewhere rationale; the bare cache from
        # fetch_pr_tag_data doesn't carry .sha. derive_tag_class only
        # needs login + date so it runs against either shape.
        augment_pr_commits_with_sha
        thread_class=$(derive_tag_class "$thread")
        thread_class_computed=true
      fi
      tag_class="$thread_class"
      tag_rationale=$(synth_rationale "$tag_class" "$thread")
    fi
    if post_tag_reply "$THREAD_ID" "$tag_class" "$tag_rationale"; then
      echo "  TAGGED [$AUTHOR] $PATH_ → [mergepath-resolve: $tag_class]"
      TAG_REPLY_POSTED=$((TAG_REPLY_POSTED + 1))
    else
      echo "  WARN: tag-reply post failed for [$AUTHOR] $PATH_ (resolving anyway)" >&2
      TAG_REPLY_FAILED=$((TAG_REPLY_FAILED + 1))
    fi
  else
    TAG_REPLY_SKIPPED=$((TAG_REPLY_SKIPPED + 1))
  fi

  # Identity check moved out of the loop in #293 r2 — see the
  # single-gate block above the loop.
  #
  # #564: capture the mutation's returned `thread.isResolved` rather than
  # discarding the response. A mutation that returns HTTP 200 but
  # isResolved!=true did NOT actually resolve the thread, so it must count
  # as FAILED, not RESOLVED. Threads confirmed true here are collected into
  # RESOLVED_IDS for the consolidated reviewThreads readback after the loop.
  resolve_state=""
  if mutation_out=$(gh_pat api graphql -f query='
    mutation($id: ID!) {
      resolveReviewThread(input: {threadId: $id}) {
        thread { isResolved }
      }
    }
  ' -F id="$THREAD_ID" 2>/dev/null); then
    resolve_state=$(printf '%s' "$mutation_out" \
      | jq -r '.data.resolveReviewThread.thread.isResolved' 2>/dev/null || echo "")
  fi
  if [ "$resolve_state" = "true" ]; then
    echo "  RESOLVED [$AUTHOR] $PATH_"
    RESOLVED_COUNT=$((RESOLVED_COUNT + 1))
    RESOLVED_IDS+=("$THREAD_ID")
  else
    echo "  FAILED [$AUTHOR] $PATH_ — mutation rejected (returned isResolved=${resolve_state:-none})" >&2
    FAILED_COUNT=$((FAILED_COUNT + 1))
  fi
done < <(printf '%s\n' "$UNRESOLVED")

echo ""
if $DRY_RUN; then
  echo "(dry-run; no threads modified) — would-resolve: $WOULD_RESOLVE_COUNT, skipped (human): $SKIPPED_HUMAN, skipped (stale-HEAD): $SKIPPED_STALE, skipped (not-actioned): $SKIPPED_NOT_ACTIONED"
  # Codex r2 on PR #172: dry-run previously exited 0 when only
  # current-HEAD bot threads remained (because dry-run does not mutate
  # them and they didn't increment SKIPPED_*). Callers would treat
  # the PR as "all clear" and proceed to merge into a still-BLOCKED PR.
  # Fix: dry-run exits 3 if ANY actionable items remain (would-resolve,
  # human-skipped, or stale-skipped). The only exit-0 path through
  # auto-resolve-bots --dry-run is "no unresolved threads at all"
  # which is already short-circuited above (UNRESOLVED is empty).
  if [ "$WOULD_RESOLVE_COUNT" -gt 0 ] || [ "$SKIPPED_HUMAN" -gt 0 ] || [ "$SKIPPED_STALE" -gt 0 ] || [ "$SKIPPED_NOT_ACTIONED" -gt 0 ]; then
    exit 3
  fi
  exit 0
fi

# --- post-resolve readback (#564) ------------------------------------------
# Acceptance criterion: "Actioned review feedback is resolved through an
# identity-checked resolveReviewThread path before merge, with a follow-up
# reviewThreads readback confirming isResolved: true." The per-thread
# mutation return value is checked in the loop above; this is the SEPARATE
# confirming read. We re-read each just-resolved thread via the top-level
# `nodes(ids:)` lookup — O(resolved), no pagination, and it reads back
# exactly the set we mutated (and is syntactically distinct from the
# enumeration `reviewThreads` query).
#
# Fail CLOSED: any thread that does not read back isResolved:true (state
# drift, eventual-consistency lag, an id that no longer resolves, or a
# token that could write but a later read that cannot) increments
# READBACK_FAILED and forces a non-zero exit, so a caller never treats an
# unconfirmed resolve as a clean conversation-resolution gate. A readback
# that confirms nothing is never treated as "all good".
#
# `nodes(ids:)` caps at 100 nodes per query, so batch — a single PR run
# resolving >100 threads is vanishingly rare, but the batch loop keeps the
# confirmation complete if it ever happens.
if [ "${#RESOLVED_IDS[@]}" -gt 0 ]; then
  rb_total=${#RESOLVED_IDS[@]}
  rb_start=0
  while [ "$rb_start" -lt "$rb_total" ]; do
    rb_batch=("${RESOLVED_IDS[@]:$rb_start:100}")
    rb_start=$((rb_start + 100))
    # Build the GraphQL ID-array literal by JSON-encoding the ids. GitHub
    # node IDs are documented as OPAQUE, so do not assume a charset or parse
    # them — JSON encoding (jq) escapes any content correctly, making the
    # inlined literal injection-safe for any id without a charset whitelist
    # (CodeRabbit on #565). A JSON string array is also a valid GraphQL
    # list-of-strings literal. Empty / drifted ids simply fail the per-id
    # readback below (fail closed).
    rb_ids_json=$(printf '%s\n' "${rb_batch[@]}" | jq -R . | jq -s -c .)
    rb_query="query { nodes(ids: ${rb_ids_json}) { ... on PullRequestReviewThread { id isResolved } } }"
    if ! rb_resp=$(gh_pat api graphql -f query="$rb_query" 2>&1); then
      echo "  READBACK FAILED: reviewThreads readback query errored: $rb_resp" >&2
      # Fail closed — count every id in this batch as unconfirmed.
      for rb_id in "${rb_batch[@]}"; do READBACK_FAILED=$((READBACK_FAILED + 1)); done
      continue
    fi
    for rb_id in "${rb_batch[@]}"; do
      rb_state=$(printf '%s' "$rb_resp" \
        | jq -r --arg id "$rb_id" \
            '(.data.nodes // []) | map(select(.id == $id)) | .[0].isResolved
             | if . == null then "missing" else tostring end' 2>/dev/null \
        || echo "missing")
      if [ "$rb_state" != "true" ]; then
        echo "  READBACK FAILED [$rb_id]: isResolved=$rb_state (expected true)" >&2
        READBACK_FAILED=$((READBACK_FAILED + 1))
      fi
    done
  done
  if [ "$READBACK_FAILED" -gt 0 ]; then
    echo "Readback: $READBACK_FAILED of $rb_total resolved thread(s) did NOT confirm isResolved:true — failing closed." >&2
  else
    echo "Readback: all $rb_total resolved thread(s) confirmed isResolved:true."
  fi
fi

echo "Resolved: $RESOLVED_COUNT  Skipped (human): $SKIPPED_HUMAN  Skipped (stale-HEAD): $SKIPPED_STALE  Skipped (not-actioned): $SKIPPED_NOT_ACTIONED  Failed: $FAILED_COUNT  Readback-failed: $READBACK_FAILED"
if ! $NO_TAG_REPLY; then
  echo "Tag replies: posted=$TAG_REPLY_POSTED  failed=$TAG_REPLY_FAILED"
fi
# Codex r1 on PR #172: previously this exited 0 even with stale or
# human-authored threads remaining — callers would treat it as "all
# clear" and proceed to merge into a still-BLOCKED PR. Exit codes:
#   2 = mutation failure (transient: gh/network), a resolve mutation that
#       did not return isResolved:true, OR a post-resolve readback that
#       could not confirm isResolved:true (#564 — fail closed)
#   3 = unresolved threads remain (human or stale-bot) — PR still
#       conversation-resolution-blocked; address and retry
#   0 = no unresolved threads on current HEAD
# Explicit `if` (not `[ a ] && exit`): two OR-ed conditions, and an
# `&& exit` chain would be ambiguous under set -e (see the SKIPPED block
# below). A readback failure is as fail-closed as a mutation failure.
if [ "$FAILED_COUNT" -gt 0 ] || [ "$READBACK_FAILED" -gt 0 ]; then
  exit 2
fi
# Use an explicit `if`, not `[ a ] || [ b ] && exit 3`. In that
# one-liner `&&` and `||` are equal-precedence and left-associative,
# so it parses as `([ a ] || [ b ]) && exit 3` — and under
# `set -e`, when BOTH skip counts are 0 the `[ b ]` that ends the
# `||` chain returns non-zero, making the whole list's status
# non-zero; whether that trips `set -e` depends on subtle list-tail
# rules. The `if` form is unambiguous and matches the block above.
# (CodeRabbit Major, #271/#272.)
if [ "$SKIPPED_HUMAN" -gt 0 ] || [ "$SKIPPED_STALE" -gt 0 ] || [ "$SKIPPED_NOT_ACTIONED" -gt 0 ]; then
  exit 3
fi
exit 0
