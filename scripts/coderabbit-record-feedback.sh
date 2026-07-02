#!/usr/bin/env bash
# scripts/coderabbit-record-feedback.sh — CodeRabbit disposition-verdict
# ledger (#584). The CodeRabbit counterpart of scripts/codex-record-feedback.sh.
#
# ─────────────────────────────────────────────────────────────────────────────
# BY-NATURE ASYMMETRY (#574 / #584): DISPOSITION LOGGING ONLY — NO REACTIONS.
# Codex ends each finding with "Useful? React with 👍 / 👎.", so its recorder
# (scripts/codex-record-feedback.sh) both POSTs the solicited reaction and
# writes a ledger row. CodeRabbit does NOT solicit per-finding reactions, so
# this helper NEVER posts a reaction (or any other write) to GitHub. Its only
# output is the durable JSONL disposition ledger — one row per adjudicated
# finding — plus the JSON summary on stdout. Every GitHub call in this script
# is a GET (REST reads + the read-only GraphQL reviewThreads query).
# ─────────────────────────────────────────────────────────────────────────────
#
# After the authoring agent adjudicates each CodeRabbit inline finding
# (fixed by a code change, or rebutted as a false positive), this helper
# records the per-finding verdict so CodeRabbit review precision is
# trackable over time, symmetric with the Codex ledger from #487.
#
# Usage:
#   scripts/coderabbit-record-feedback.sh <PR_NUMBER> [--repo <owner/repo>] \
#     --verdict <comment_id>=<verdict>[:<reason>] [--verdict ...] \
#     [--findings-json <FILE|->] [--scan] \
#     [--ledger <FILE>] [--dry-run]
#
# Arguments:
#   PR_NUMBER  Required. The pull request number (integer).
#
# Options:
#   --repo R            Optional. "owner/repo". Defaults to the current repo
#                       (via `gh repo view`). A bare positional REPO after
#                       PR_NUMBER is also accepted, mirroring the codex twin.
#   --verdict C=V[:R]   Repeatable. Maps a finding's comment_id (C) to the
#                       agent's verdict (V) with an optional free-text
#                       reason (R). Verdict aliases (same vocabulary as
#                       scripts/codex-record-feedback.sh):
#                         fixed | real | useful | +1      → disposition `fixed`
#                         rebutted | false-positive |
#                           false_positive | not-useful |
#                           not_useful | -1                → disposition `rebutted`
#                       A comment_id with no matching collected finding is
#                       skipped with a `not-found` note, not an error.
#   --findings-json F   Read a findings array from F (a file, or "-" for
#                       stdin). Accepts either an object with a `findings`
#                       array or a bare array of
#                       { path, line, comment_id|id, body[, tier] } objects.
#                       Each finding is (re)classified from its body via
#                       coderabbit_tier_of; a supplied `tier` is only a
#                       fallback when the body carries no marker.
#   --scan              Fetch the current-HEAD CodeRabbit inline findings
#                       directly (read-only): comments authored by
#                       coderabbit.bot_login (default `coderabbitai[bot]`)
#                       whose commit_id or original_commit_id equals the PR
#                       HEAD — the same current-finding scope
#                       scripts/coderabbit-severity-gate.sh gates on.
#   --ledger F          Append per-finding disposition records (JSONL) to F.
#                       Defaults to $CODERABBIT_FEEDBACK_LEDGER, else
#                       .mergepath/coderabbit-feedback-ledger.jsonl under the
#                       repo root (a gitignored directory). The directory is
#                       created if missing.
#   --dry-run           Resolve verdicts and report what WOULD be recorded,
#                       but write nothing. Exit 0.
#
# Environment:
#   GH_TOKEN                    Required for the read/scan calls. Auto-sourced
#                               from the op-preflight cache when unset (#282).
#   CODERABBIT_FEEDBACK_LEDGER  Default ledger path override.
#
# HEAD-pinning / "latest round" adaptation: the codex twin scopes --scan to
# the latest Codex review round on HEAD because Codex re-posts a full review
# per round. CodeRabbit instead posts findings INCREMENTALLY across many
# review submissions, so "current" is defined by SHA, not round: a finding
# counts iff its commit_id or original_commit_id equals the PR's current
# HEAD — exactly the stage-1 filter in scripts/coderabbit-severity-gate.sh.
# Findings supplied via --findings-json inherit the producer's scoping.
#
# Ledger row schema (JSONL, one compact object per line, append-only):
#   {
#     comment_id: N,            # CodeRabbit inline comment databaseId
#     pr: N, repo: "owner/repo",
#     head_sha: "<sha>",        # PR HEAD at record time
#     path: "p"|null, line: N|null,
#     tier: "p1"|"p2"|"p3"|"nitpick"|null,   # coderabbit_tier_of (#576)
#     verdict: "<alias as supplied>",
#     disposition: "fixed"|"rebutted",
#     reason: "..."|null,
#     resolved: true|false,     # thread isResolved at record time
#     superseded_prior: true|false,
#     recorded_at: "<ISO-8601 UTC>"
#   }
#
# Idempotency / superseding contract (append-only, no rewrites):
#   - Re-recording a comment_id whose LAST ledger row (same repo) carries the
#     SAME disposition is a no-op: skipped with a log line and reported under
#     `skipped` as `already-recorded`. Aliases normalize first, so re-running
#     with `real` after `fixed` is still a no-op.
#   - A verdict that maps to a DIFFERENT disposition appends a superseding
#     row flagged `superseded_prior: true`. Prior rows are never rewritten;
#     consumers take the last row per comment_id as current.
#
# Output JSON shape (stdout):
#   {
#     "pr_number": 123, "repo": "owner/repo", "head_sha": "<sha>",
#     "dry_run": false,
#     "recorded": [ { <ledger row fields>, "action":
#                     "recorded|superseded_prior|dry_run" } ],
#     "skipped":  [ { "comment_id": N,
#                     "why": "no-verdict|not-found|already-recorded" } ]
#   }
#
# Exit codes:
#   0   Completed. Every resolvable verdict was recorded (or was already
#       recorded, or dry-run). Summary JSON on stdout.
#   2   A --verdict value was unrecognized, or argument misuse. Validated
#       BEFORE any GitHub call and before any ledger write.
#   3   API / infrastructure error. Error message on stderr.
#   (1 is unused — it is the reaction-POST-failure code in the codex twin,
#   and this recorder never posts.)
#
# Design notes:
#   - jq for all JSON parsing/emission. No ad-hoc string concatenation.
#   - Strictly read-only against GitHub: REST GETs plus the read-only
#     GraphQL reviewThreads query for the `resolved` bit. No gh-as-*.sh
#     wrapper is involved because there is nothing to write.
#   - Tier classification is the shared coderabbit_tier_of from
#     scripts/lib/feedback-policy-helpers.sh — the single classifier both
#     severity gates key on, so the ledger vocabulary cannot drift.
#
# References:
#   - #584 — this script (CodeRabbit disposition logging)
#   - #574 — the symmetric feedback policy + the documented asymmetry
#   - #487 — the Codex twin (scripts/codex-record-feedback.sh)
#   - #576/#577 — coderabbit_tier_of + the severity gate whose HEAD scope
#     this mirrors
#   - REVIEW_POLICY.md § Feedback Disposition Policy

set -euo pipefail

__CRRF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
__CRRF_ROOT="$(cd "$__CRRF_DIR/.." && pwd)"

# --- preflight auto-source (#282) ------------------------------------------
# Auto-source the op-preflight cache when GH_TOKEN is unset. Reviewer scope is
# the conventional PAT for review-loop reads; this helper performs GETs only.
if [ -r "$__CRRF_DIR/lib/preflight-helpers.sh" ]; then
  # shellcheck source=lib/preflight-helpers.sh
  . "$__CRRF_DIR/lib/preflight-helpers.sh"
  preflight_require_token reviewer || true
fi

# Shared tier classifier (#576) — the same coderabbit_tier_of both severity
# gates use. Hard requirement: the ledger is KEYED on this classifier, so a
# missing lib is an infrastructure error, not a degraded mode.
if [ -r "$__CRRF_DIR/lib/feedback-policy-helpers.sh" ]; then
  # shellcheck source=lib/feedback-policy-helpers.sh
  . "$__CRRF_DIR/lib/feedback-policy-helpers.sh"
else
  echo "[coderabbit-record-feedback] ERROR: scripts/lib/feedback-policy-helpers.sh is missing (coderabbit_tier_of classifier). See #576/#584." >&2
  exit 3
fi

# --- logging helpers --------------------------------------------------------

log() {
  echo "[coderabbit-record-feedback] $*" >&2
}

die() {
  local code=$1
  shift
  echo "[coderabbit-record-feedback] ERROR: $*" >&2
  exit "$code"
}

# --- argument parsing -------------------------------------------------------

PR_NUMBER=""
REPO=""
FINDINGS_SOURCE=""
DO_SCAN=0
DRY_RUN=0
LEDGER=""
# Parallel arrays (Bash 3.2 — no associative arrays): VERDICT_IDS[i] maps to
# VERDICT_VALS[i] / VERDICT_REASONS[i].
VERDICT_IDS=()
VERDICT_VALS=()
VERDICT_REASONS=()

usage() {
  echo "Usage: $0 <PR_NUMBER> [--repo <owner/repo>] --verdict <comment_id>=<verdict>[:<reason>] [...] [--findings-json <FILE|->] [--scan] [--ledger <FILE>] [--dry-run]" >&2
}

add_verdict() {
  # Accepts comment_id=verdict[:reason]. The reason may contain '='; only the
  # FIRST '=' splits id from the rest, and the FIRST ':' splits verdict from
  # reason. Mirrors the codex twin byte-for-byte.
  local spec=$1
  local id rest verdict reason
  case "$spec" in
    *=*) : ;;
    *) die 2 "--verdict expects <comment_id>=<verdict>[:<reason>]; got '$spec'" ;;
  esac
  id=${spec%%=*}
  rest=${spec#*=}
  if ! [[ "$id" =~ ^[0-9]+$ ]]; then
    die 2 "--verdict comment_id must be an integer; got '$id' (from '$spec')"
  fi
  case "$rest" in
    *:*)
      verdict=${rest%%:*}
      reason=${rest#*:}
      ;;
    *)
      verdict=$rest
      reason=""
      ;;
  esac
  VERDICT_IDS+=("$id")
  VERDICT_VALS+=("$verdict")
  VERDICT_REASONS+=("$reason")
}

while [ $# -gt 0 ]; do
  case "$1" in
    --verdict)
      [ $# -ge 2 ] || die 2 "--verdict requires an argument"
      add_verdict "$2"
      shift 2
      ;;
    --verdict=*)
      add_verdict "${1#*=}"
      shift
      ;;
    --repo)
      [ $# -ge 2 ] || die 2 "--repo requires an owner/repo argument"
      REPO="$2"
      shift 2
      ;;
    --repo=*)
      REPO="${1#*=}"
      shift
      ;;
    --findings-json)
      [ $# -ge 2 ] || die 2 "--findings-json requires a FILE or -"
      FINDINGS_SOURCE="$2"
      shift 2
      ;;
    --findings-json=*)
      FINDINGS_SOURCE="${1#*=}"
      shift
      ;;
    --scan)
      DO_SCAN=1
      shift
      ;;
    --ledger)
      [ $# -ge 2 ] || die 2 "--ledger requires a FILE"
      LEDGER="$2"
      shift 2
      ;;
    --ledger=*)
      LEDGER="${1#*=}"
      shift
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      ;;
    -*)
      usage
      die 2 "unknown option: $1"
      ;;
    *)
      if [ -z "$PR_NUMBER" ]; then
        PR_NUMBER="$1"
      elif [ -z "$REPO" ]; then
        REPO="$1"
      else
        usage
        die 2 "unexpected positional argument: $1"
      fi
      shift
      ;;
  esac
done

if [ -z "$PR_NUMBER" ]; then
  usage
  die 2 "PR_NUMBER is required"
fi
if ! [[ "$PR_NUMBER" =~ ^[0-9]+$ ]]; then
  die 2 "PR_NUMBER must be an integer; got '$PR_NUMBER'"
fi

if [ -z "$FINDINGS_SOURCE" ] && [ "$DO_SCAN" -ne 1 ]; then
  usage
  die 2 "no findings source: pass --findings-json <FILE|-> and/or --scan"
fi

# --- verdict vocabulary -----------------------------------------------------

# Map a verdict alias to its disposition. Echoes `fixed` or `rebutted` on
# success, returns non-zero on an unrecognized alias. Same alias set as the
# codex twin's resolve_reaction (the +1/-1/thumbs* aliases are kept for
# muscle-memory parity even though NO reaction is ever posted here).
resolve_disposition() {
  local v
  v=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  case "$v" in
    fixed|real|useful|"+1"|thumbsup|thumbs-up|up)
      printf 'fixed\n' ;;
    rebutted|false-positive|false_positive|falsepositive|not-useful|not_useful|notuseful|"-1"|thumbsdown|thumbs-down|down)
      printf 'rebutted\n' ;;
    *)
      return 1 ;;
  esac
}

# Validate all supplied verdict values UP FRONT — before any GitHub call and
# before any ledger write — so a typo fails closed with exit 2 and zero side
# effects (stricter placement than the codex twin, per the #584 contract).
for ((vi = 0; vi < ${#VERDICT_VALS[@]}; vi++)); do
  if ! resolve_disposition "${VERDICT_VALS[$vi]}" >/dev/null; then
    die 2 "unrecognized verdict '${VERDICT_VALS[$vi]}' for comment ${VERDICT_IDS[$vi]} (use fixed|real|useful|+1 or rebutted|false-positive|not-useful|-1)"
  fi
done

# --- environment / context --------------------------------------------------

if [ -z "${GH_TOKEN:-}" ]; then
  echo "ERROR: GH_TOKEN is required. Either:" >&2
  echo "  - Run: eval \"\$(scripts/op-preflight.sh --agent <agent> --mode review)\"" >&2
  echo "    so this helper auto-sources OP_PREFLIGHT_REVIEWER_PAT, OR" >&2
  echo "  - Set GH_TOKEN inline per REVIEW_POLICY.md § PAT lookup table." >&2
  exit 3
fi

if [ -z "$REPO" ]; then
  REPO=$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null || true)
  if [ -z "$REPO" ]; then
    die 3 "could not detect current repo via 'gh repo view'. Pass --repo explicitly."
  fi
fi

# Ledger default: repo-root .mergepath/coderabbit-feedback-ledger.jsonl unless
# overridden by --ledger or $CODERABBIT_FEEDBACK_LEDGER. The .mergepath/
# directory is gitignored (local durable state, not tracked content).
if [ -z "$LEDGER" ]; then
  LEDGER=${CODERABBIT_FEEDBACK_LEDGER:-"$__CRRF_ROOT/.mergepath/coderabbit-feedback-ledger.jsonl"}
fi

# --- config readers ---------------------------------------------------------

CONFIG=".github/review-policy.yml"

# Read a scalar field from the coderabbit: block. Mirrors
# scripts/coderabbit-severity-gate.sh's coderabbit_field.
coderabbit_field() {
  local field=$1
  [ -f "$CONFIG" ] || return 0
  awk -v field="$field" '
    /^coderabbit:/ {in_block=1; next}
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

BOT_LOGIN=$(coderabbit_field bot_login)
BOT_LOGIN=${BOT_LOGIN:-"coderabbitai[bot]"}

# Paginated REST fetch helper — same shape as the severity gates.
fetch_api_array() {
  local endpoint=$1
  local label=$2
  local raw
  raw=$(gh api --paginate "$endpoint" 2>&1) || die 3 "failed to fetch $label: $raw"
  echo "$raw" | jq -s 'add // []' 2>/dev/null \
    || die 3 "failed to flatten $label pagination output"
}

# --- PR metadata (HEAD sha pins every ledger row) ----------------------------

PR_JSON=$(gh api "repos/$REPO/pulls/$PR_NUMBER" 2>&1) \
  || die 3 "failed to fetch PR metadata: $PR_JSON"
HEAD_SHA=$(echo "$PR_JSON" | jq -r '.head.sha')
[ -n "$HEAD_SHA" ] && [ "$HEAD_SHA" != "null" ] \
  || die 3 "could not determine HEAD sha for PR #$PR_NUMBER"

# --- collect findings -------------------------------------------------------

# Normalize an arbitrary findings input into the canonical findings array:
#   [ { path, line, comment_id, body, tier } ]
# Accepts either an object carrying a findings array or a bare array. `tier`
# here is only the producer's FALLBACK — classification below re-derives it
# from the body via coderabbit_tier_of whenever a marker is present.
#
# comment_id is COERCED to a number (#617): a GitHub inline-comment databaseId
# is always an integer, but a --findings-json producer may emit it as a string
# ("5001"). The three id-matching sites downstream are inconsistent — the main
# loop's lookup_verdict string-compares, while the NEED_RESOLUTION_MAP scan and
# the final not-found pass compare against numeric --argjson values — so a
# string id would be BOTH recorded (matched by lookup_verdict) AND reported
# skipped:not-found (missed by index($c)). Coercing here makes comment_id
# numeric everywhere, matching the --scan path (which reads a JSON number) and
# the integer-validated --verdict ids, so all three sites agree. A value that
# is neither a number nor a numeric string is left untouched (it simply will
# not match — the conservative default) rather than aborting normalization.
normalize_findings() {
  jq '
    def coerce_id:
      if type == "string" and test("^[0-9]+$") then tonumber else . end;
    (if type == "object" and has("findings") then .findings else . end)
    | (if type == "array" then . else [] end)
    | [ .[]
        | {
            path: (.path // null),
            line: (.line // null),
            comment_id: ((.comment_id // .id) | coerce_id),
            body: (.body // ""),
            tier: (.tier // null)
          }
        | select(.comment_id != null)
      ]
  '
}

COLLECTED='[]'

if [ -n "$FINDINGS_SOURCE" ]; then
  if [ "$FINDINGS_SOURCE" = "-" ]; then
    RAW_JSON=$(cat)
  else
    [ -r "$FINDINGS_SOURCE" ] || die 3 "findings JSON file not readable: $FINDINGS_SOURCE"
    RAW_JSON=$(cat "$FINDINGS_SOURCE")
  fi
  [ -n "$RAW_JSON" ] || die 3 "findings JSON source is empty"
  FROM_JSON=$(printf '%s' "$RAW_JSON" | normalize_findings) \
    || die 3 "could not parse findings JSON from $FINDINGS_SOURCE"
  COLLECTED=$(jq -n --argjson a "$COLLECTED" --argjson b "$FROM_JSON" '$a + $b')
fi

if [ "$DO_SCAN" -eq 1 ]; then
  log "scanning current-HEAD CodeRabbit inline findings (read-only; bot_login = $BOT_LOGIN)"
  COMMENTS_JSON=$(fetch_api_array "repos/$REPO/pulls/$PR_NUMBER/comments" "inline comments")
  # Current-HEAD scope: identical to coderabbit-severity-gate.sh stage 1 —
  # bot-authored AND (commit_id == HEAD OR original_commit_id == HEAD).
  # CodeRabbit posts incrementally across review rounds, so SHA (not
  # latest-round) defines "current"; see the header note.
  SCANNED=$(echo "$COMMENTS_JSON" | jq \
    --arg bot "$BOT_LOGIN" --arg sha "$HEAD_SHA" '
    [ .[]
      | select(.user.login == $bot)
      | select((.commit_id == $sha) or (.original_commit_id == $sha))
      | {
          path: (.path // null),
          line: (.line // .original_line // null),
          comment_id: .id,
          body: (.body // ""),
          tier: null
        }
    ]
  ')
  COLLECTED=$(jq -n --argjson a "$COLLECTED" --argjson b "$SCANNED" '$a + $b')
fi

# Deduplicate by comment_id (a finding present in both the JSON and the scan
# collapses to one entry; the first occurrence wins). Same as the codex twin.
FINDINGS=$(echo "$COLLECTED" | jq '
  reduce .[] as $f ({seen: {}, out: []};
    if (.seen[($f.comment_id|tostring)] // false) then .
    else .seen[($f.comment_id|tostring)] = true | .out += [$f]
    end)
  | .out
')

# Classify each finding with the SHARED coderabbit_tier_of (never re-implement
# the classifier in jq — same no-drift posture as the severity gate). A body
# with no marker falls back to the producer-supplied tier, else stays null.
CLASSIFIED='[]'
FINDINGS_COUNT=$(echo "$FINDINGS" | jq 'length')
fi_idx=0
while [ "$fi_idx" -lt "$FINDINGS_COUNT" ]; do
  f=$(echo "$FINDINGS" | jq -c ".[$fi_idx]")
  body=$(echo "$f" | jq -r '.body // ""')
  tier=$(coderabbit_tier_of "$body")
  if [ -z "$tier" ]; then
    tier=$(echo "$f" | jq -r '.tier // empty')
  fi
  CLASSIFIED=$(jq -cn --argjson acc "$CLASSIFIED" --argjson f "$f" --arg tier "$tier" '
    $acc + [ $f + { tier: (if $tier == "" then null else $tier end) } ]
  ')
  fi_idx=$((fi_idx + 1))
done
FINDINGS=$CLASSIFIED

log "collected $FINDINGS_COUNT candidate finding(s) on HEAD $HEAD_SHA"

# --- verdict lookup ----------------------------------------------------------

# Look up the verdict spec for a comment_id. Sets VERDICT_FOUND/VERDICT_VALUE/
# VERDICT_REASON. Last --verdict for a given id wins. Mirrors the codex twin.
lookup_verdict() {
  local want=$1
  local i
  VERDICT_FOUND=0
  VERDICT_VALUE=""
  VERDICT_REASON=""
  for ((i = 0; i < ${#VERDICT_IDS[@]}; i++)); do
    if [ "${VERDICT_IDS[$i]}" = "$want" ]; then
      VERDICT_FOUND=1
      VERDICT_VALUE="${VERDICT_VALS[$i]}"
      VERDICT_REASON="${VERDICT_REASONS[$i]}"
    fi
  done
}

COLLECTED_IDS=$(echo "$FINDINGS" | jq '[.[].comment_id]')

# Does any supplied verdict match a collected finding? Only then is the
# thread-resolution map (a GraphQL read) needed at all.
NEED_RESOLUTION_MAP=0
for ((vi2 = 0; vi2 < ${#VERDICT_IDS[@]}; vi2++)); do
  if [ "$(echo "$COLLECTED_IDS" | jq --argjson c "${VERDICT_IDS[$vi2]}" 'index($c) != null')" = "true" ]; then
    NEED_RESOLUTION_MAP=1
    break
  fi
done

# --- thread resolution map (read-only GraphQL) -------------------------------

# Build { "<comment_id>": isResolved, ... } for the `resolved` ledger field.
# This mirrors the #592 paginated reviewThreads walk in
# scripts/coderabbit-severity-gate.sh (both the top-level connection and each
# thread's nested comments connection page at 100), with die 3 as this
# script's API-error code. A comment id absent from the fully-paginated map
# records resolved=false — the conservative default.
RESOLUTION_MAP='{}'
if [ "$NEED_RESOLUTION_MAP" -eq 1 ]; then
  OWNER=${REPO%/*}
  NAME=${REPO#*/}
  MAX_PAGES=100

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

  ALL_THREADS='[]'
  CURSOR=""
  PAGE=0
  while :; do
    PAGE=$((PAGE + 1))
    if [ "$PAGE" -gt "$MAX_PAGES" ]; then
      die 3 "reviewThreads pagination exceeded $MAX_PAGES pages (#592 safety cap) — failing closed."
    fi
    if [ -z "$CURSOR" ]; then
      THREADS_JSON=$(gh api graphql -F owner="$OWNER" -F name="$NAME" \
        -F pr="$PR_NUMBER" -F cursor=null -f query="$THREADS_QUERY" 2>&1) \
        || die 3 "failed to query reviewThreads (page $PAGE): $THREADS_JSON"
    else
      THREADS_JSON=$(gh api graphql -F owner="$OWNER" -F name="$NAME" \
        -F pr="$PR_NUMBER" -f cursor="$CURSOR" -f query="$THREADS_QUERY" 2>&1) \
        || die 3 "failed to query reviewThreads (page $PAGE): $THREADS_JSON"
    fi
    if ! echo "$THREADS_JSON" | jq -e '.data.repository.pullRequest.reviewThreads.nodes' >/dev/null 2>&1; then
      die 3 "malformed reviewThreads response (page $PAGE) — failing closed."
    fi

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
          die 3 "thread comments pagination exceeded $MAX_PAGES pages (#592 safety cap) — failing closed."
        fi
        CJSON=$(gh api graphql -F id="$NODE_ID" -f cursor="$C_CURSOR" \
          -f query="$THREAD_COMMENTS_QUERY" 2>&1) \
          || die 3 "failed to query thread comments (thread $NODE_ID, page $C_PAGE): $CJSON"
        if ! echo "$CJSON" | jq -e '.data.node.comments.nodes' >/dev/null 2>&1; then
          die 3 "malformed thread comments response (thread $NODE_ID, page $C_PAGE) — failing closed."
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
      die 3 "reviewThreads reported hasNextPage but no endCursor — failing closed."
    fi
  done

  RESOLUTION_MAP=$(echo "$ALL_THREADS" | jq '
    map(
        (.isResolved) as $resolved
        | .comment_ids
        | map({ key: (. | tostring), value: $resolved })
      )
    | flatten
    | from_entries
  ')
fi

# --- ledger helpers -----------------------------------------------------------

# Echo the disposition of the LAST ledger row for this comment_id in this
# repo, or nothing when no prior row exists (or the ledger is absent /
# unparseable — treated as no-prior so a corrupt line cannot block recording;
# the ledger is append-only either way).
prior_disposition_of() {
  local cid=$1
  [ -f "$LEDGER" ] || return 0
  jq -rs --argjson cid "$cid" --arg repo "$REPO" '
    [ .[] | select(.comment_id == $cid and .repo == $repo) ]
    | last
    | if . == null then "" else (.disposition // "") end
  ' "$LEDGER" 2>/dev/null || true
}

# Append one JSONL disposition record to the ledger.
append_ledger() {
  local record=$1
  local dir
  dir=$(dirname "$LEDGER")
  mkdir -p "$dir" || die 3 "could not create ledger directory: $dir"
  printf '%s\n' "$record" >>"$LEDGER" || die 3 "could not append to ledger: $LEDGER"
}

# --- main loop ----------------------------------------------------------------

RECORDED='[]'
SKIPPED='[]'
NOW_ISO=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || printf '')

record_skip() {
  local cid=$1
  local why=$2
  SKIPPED=$(jq -n --argjson arr "$SKIPPED" --argjson cid "$cid" --arg why "$why" '
    $arr + [ { comment_id: $cid, why: $why } ]
  ')
}

while IFS= read -r finding; do
  [ -n "$finding" ] || continue
  CID=$(echo "$finding" | jq -r '.comment_id')
  TIER=$(echo "$finding" | jq -r '.tier // ""')

  lookup_verdict "$CID"
  if [ "$VERDICT_FOUND" -ne 1 ]; then
    log "comment $CID has no --verdict — skipping (no blanket rows)"
    record_skip "$CID" "no-verdict"
    continue
  fi

  DISPOSITION=$(resolve_disposition "$VERDICT_VALUE") \
    || die 2 "unrecognized verdict '$VERDICT_VALUE' for comment $CID"

  # Idempotency: the LAST prior row for this comment_id decides. Same
  # disposition → no-op; different disposition → superseding append.
  PRIOR=$(prior_disposition_of "$CID")
  SUPERSEDED=false
  if [ -n "$PRIOR" ]; then
    if [ "$PRIOR" = "$DISPOSITION" ]; then
      log "comment $CID already recorded with disposition '$DISPOSITION' — no-op (idempotent)"
      record_skip "$CID" "already-recorded"
      continue
    fi
    SUPERSEDED=true
    log "comment $CID re-adjudicated: '$PRIOR' -> '$DISPOSITION' — appending superseding row"
  fi

  RESOLVED=$(echo "$RESOLUTION_MAP" | jq --argjson cid "$CID" '.[($cid|tostring)] // false')

  if [ "$DRY_RUN" -eq 1 ]; then
    log "[dry-run] would record comment $CID: tier=${TIER:-none} verdict=$VERDICT_VALUE disposition=$DISPOSITION resolved=$RESOLVED superseded_prior=$SUPERSEDED"
    ACTION="dry_run"
  elif [ "$SUPERSEDED" = "true" ]; then
    ACTION="superseded_prior"
  else
    ACTION="recorded"
  fi

  # Compact (-c): the ledger is JSONL — one record PER LINE — so downstream
  # consumers (rollups / audits) can stream it line by line.
  RECORD=$(echo "$finding" | jq -c \
    --argjson pr "$PR_NUMBER" \
    --arg repo "$REPO" \
    --arg head "$HEAD_SHA" \
    --arg verdict "$VERDICT_VALUE" \
    --arg dispo "$DISPOSITION" \
    --arg reason "$VERDICT_REASON" \
    --argjson resolved "$RESOLVED" \
    --argjson superseded "$SUPERSEDED" \
    --arg ts "$NOW_ISO" '
    {
      comment_id: .comment_id,
      pr: $pr,
      repo: $repo,
      head_sha: $head,
      path: (.path // null),
      line: (.line // null),
      tier: (.tier // null),
      verdict: $verdict,
      disposition: $dispo,
      reason: (if $reason == "" then null else $reason end),
      resolved: $resolved,
      superseded_prior: $superseded,
      recorded_at: $ts
    }
  ')

  if [ "$DRY_RUN" -ne 1 ]; then
    append_ledger "$RECORD"
    log "recorded comment $CID: tier=${TIER:-none} disposition=$DISPOSITION resolved=$RESOLVED (action=$ACTION)"
  fi

  RECORDED=$(jq -n --argjson arr "$RECORDED" --argjson rec "$RECORD" --arg action "$ACTION" '
    $arr + [ ($rec + { action: $action }) ]
  ')
done < <(echo "$FINDINGS" | jq -c '.[]')

# Verdicts that named a comment_id which is not among the collected findings
# (e.g. a stale non-HEAD finding under --scan, or a typo) are reported as
# not-found skips — mirrors the codex twin.
for ((vi3 = 0; vi3 < ${#VERDICT_IDS[@]}; vi3++)); do
  vid=${VERDICT_IDS[$vi3]}
  if [ "$(echo "$COLLECTED_IDS" | jq --argjson c "$vid" 'index($c) != null')" != "true" ]; then
    log "verdict supplied for comment $vid but no matching collected finding on HEAD — skipping"
    record_skip "$vid" "not-found"
  fi
done

# --- emit summary -------------------------------------------------------------

jq -n \
  --argjson pr "$PR_NUMBER" \
  --arg repo "$REPO" \
  --arg head "$HEAD_SHA" \
  --argjson dry "$([ "$DRY_RUN" -eq 1 ] && echo true || echo false)" \
  --argjson recorded "$RECORDED" \
  --argjson skipped "$SKIPPED" '
  {
    pr_number: $pr,
    repo: $repo,
    head_sha: $head,
    dry_run: $dry,
    recorded: $recorded,
    skipped: $skipped
  }
'

exit 0
