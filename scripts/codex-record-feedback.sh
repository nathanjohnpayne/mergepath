#!/usr/bin/env bash
# scripts/codex-record-feedback.sh — Phase 4a Codex feedback loop (#487)
#
# After the authoring agent adjudicates each Codex finding in the Phase 4a
# loop, this helper records the 👍 / 👎 reaction that Codex solicits at the
# end of every finding ("Useful? React with 👍 / 👎.") and writes a durable
# per-finding verdict so Codex review precision is trackable over time.
#
# This is the FIRST place Mergepath POSTS a reaction. It is a WRITE path, so
# every reaction is posted through scripts/gh-as-reviewer.sh under the
# verified REVIEWER identity (e.g. nathanpayne-claude) — never the author
# token. The 👍/👎 byline is the reviewer, mirroring the rest of the review
# write surface.
#
# Usage:
#   scripts/codex-record-feedback.sh <PR_NUMBER> [REPO] \
#     --verdict <comment_id>=<verdict>[:<reason>] [--verdict ...] \
#     [--findings-json <FILE|->] [--scan] \
#     [--ledger <FILE>] [--dry-run]
#
# Arguments:
#   PR_NUMBER  Required. The pull request number (integer).
#   REPO       Optional. "owner/repo". Defaults to the current repo.
#
# Options:
#   --verdict C=V[:R]   Repeatable. Maps a finding's comment_id (C) to the
#                       agent's verdict (V) with an optional free-text
#                       reason (R). Verdict aliases:
#                         fixed | real | useful | +1   → reacts +1 (👍)
#                         rebutted | false-positive |
#                           false_positive | not-useful |
#                           not_useful | -1               → reacts -1 (👎)
#                       A comment_id with no matching finding (or a finding
#                       that does not solicit feedback) is skipped with a
#                       logged note, not an error.
#   --findings-json F   Read the findings array from F (a file, or "-" for
#                       stdin) using the codex-review-request.sh JSON
#                       contract. The whole request-script object OR a bare
#                       findings array is accepted. This is the primary
#                       hook: pass the JSON the agent already captured from
#                       `scripts/codex-review-request.sh`.
#   --scan              Instead of (or in addition to) --findings-json,
#                       fetch the current-HEAD latest-round Codex inline
#                       findings directly (read-only), mirroring
#                       codex-review-request.sh's HEAD-pinned, latest-review
#                       scoping. Use when no findings JSON is on hand.
#   --ledger F          Append per-finding verdict records (JSONL) to F.
#                       Defaults to $CODEX_FEEDBACK_LEDGER, else
#                       .mergepath/codex-feedback-ledger.jsonl under the repo
#                       root. The directory is created if missing.
#   --dry-run           Resolve verdicts and report what WOULD be posted, but
#                       do not POST any reaction and do not append to the
#                       ledger. Exit 0.
#
# Environment:
#   GH_TOKEN                   Required for the read/scan calls. Auto-sourced
#                              from the op-preflight cache when unset (#282).
#   GH_AS_REVIEWER_IDENTITY    Reviewer login used for the reaction write and
#                              the idempotency check. Falls back to
#                              MERGEPATH_AGENT / OP_PREFLIGHT_AGENT, else
#                              nathanpayne-claude (see gh-token-resolver.sh).
#
# Behavior:
#   1. Collects the candidate findings (from --findings-json and/or --scan),
#      deduplicated by comment_id.
#   2. Filters to findings whose body contains the exact solicitation
#      "Useful? React with 👍 / 👎." — findings that do not solicit feedback
#      are never reacted to.
#   3. For each soliciting finding that has a --verdict, resolves the verdict
#      to +1 / -1.
#   4. Idempotent: GETs the comment's reactions and, if a reaction by the
#      reviewer identity already exists, leaves it in place (records the
#      verdict against the pre-existing reaction; never double-reacts or
#      flips a reaction the reviewer already left).
#   5. Otherwise POSTs content=+1 / content=-1 to the reactions endpoint that
#      matches where the finding lives (pull-request review comment →
#      repos/{owner}/{repo}/pulls/comments/{id}/reactions; PR/issue comment →
#      repos/{owner}/{repo}/issues/comments/{id}/reactions) through
#      gh-as-reviewer.sh.
#   6. Appends a durable JSONL record per finding to the ledger and emits a
#      JSON summary to stdout.
#
# HEAD-pinned: findings from --scan are scoped to the LATEST Codex review
# round on the CURRENT HEAD (same filter shape as codex-review-request.sh).
# Findings supplied via --findings-json inherit whatever scoping the producer
# applied — pass the JSON from a request-script run on the current HEAD.
#
# Output JSON shape (stdout):
#   {
#     "pr_number": 123,
#     "repo": "owner/repo",
#     "reviewer_identity": "nathanpayne-claude",
#     "dry_run": false,
#     "recorded": [
#       { "comment_id": N, "priority": "P0|P1|P2|P3", "verdict": "fixed",
#         "reaction": "+1", "location": "pull_request_review_comment",
#         "action": "posted|already_present|dry_run", "reason": "..." }
#     ],
#     "skipped": [
#       { "comment_id": N, "why": "no-solicitation|no-verdict|not-found" }
#     ]
#   }
#
# Exit codes:
#   0   Completed. Every resolvable verdict was recorded (or already
#       present, or dry-run). Summary JSON on stdout.
#   1   At least one reaction POST failed. Summary JSON still on stdout;
#       per-finding error on stderr.
#   2   A --verdict value was unrecognized, or argument misuse.
#   3   API / infrastructure error. Error message on stderr.
#
# Design notes:
#   - jq for all JSON parsing/emission. No ad-hoc string concatenation.
#   - Read-only except the reaction POSTs, which all go through
#     gh-as-reviewer.sh (token-verified reviewer attribution).
#   - Idempotent and safe to re-run on the same PR/HEAD.
#
# References:
#   - #487 — this script (record validated 👍/👎 on Codex findings)
#   - #486 — companion (request @codex review by default)
#   - #419 — inverse direction (reading Codex's 👀 ack)
#   - REVIEW_POLICY.md § Phase 4a (canonical policy)

set -euo pipefail

__CRF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
__CRF_ROOT="$(cd "$__CRF_DIR/.." && pwd)"

# --- preflight auto-source (#282) ------------------------------------------
# Auto-source the op-preflight cache when GH_TOKEN is unset. Reviewer scope
# is the right PAT — the only write this helper performs (the reaction POST)
# goes through gh-as-reviewer.sh, which re-verifies the reviewer token.
if [ -r "$__CRF_DIR/lib/preflight-helpers.sh" ]; then
  # shellcheck source=lib/preflight-helpers.sh
  . "$__CRF_DIR/lib/preflight-helpers.sh"
  preflight_require_token reviewer || true
fi

# Shared reviewer-identity resolver (same logic gh-as-reviewer.sh uses) so the
# idempotency check looks for a reaction by the SAME login the write will use.
if [ -r "$__CRF_DIR/lib/gh-token-resolver.sh" ]; then
  # shellcheck source=lib/gh-token-resolver.sh
  . "$__CRF_DIR/lib/gh-token-resolver.sh"
fi

# --- logging helpers --------------------------------------------------------

log() {
  echo "[codex-record-feedback] $*" >&2
}

die() {
  local code=$1
  shift
  echo "[codex-record-feedback] ERROR: $*" >&2
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
  echo "Usage: $0 <PR_NUMBER> [REPO] --verdict <comment_id>=<verdict>[:<reason>] [...] [--findings-json <FILE|->] [--scan] [--ledger <FILE>] [--dry-run]" >&2
}

add_verdict() {
  # Accepts comment_id=verdict[:reason]. The reason may contain '='; only the
  # FIRST '=' splits id from the rest, and the FIRST ':' splits verdict from
  # reason.
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

if [ -z "$REPO" ]; then
  REPO=$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null || true)
  if [ -z "$REPO" ]; then
    die 3 "could not detect current repo via 'gh repo view'. Pass REPO explicitly."
  fi
fi

if [ -z "${GH_TOKEN:-}" ]; then
  echo "ERROR: GH_TOKEN is required. Either:" >&2
  echo "  - Run: eval \"\$(scripts/op-preflight.sh --agent <agent> --mode review)\"" >&2
  echo "    so this helper auto-sources OP_PREFLIGHT_REVIEWER_PAT, OR" >&2
  echo "  - Set GH_TOKEN inline per REVIEW_POLICY.md § PAT lookup table." >&2
  exit 3
fi

if [ -z "$FINDINGS_SOURCE" ] && [ "$DO_SCAN" -ne 1 ]; then
  usage
  die 2 "no findings source: pass --findings-json <FILE|-> and/or --scan"
fi

# Reviewer identity — used for BOTH the idempotency reaction-owner check and
# (implicitly) the write, which gh-as-reviewer.sh re-derives the same way.
if command -v gh_default_reviewer_identity >/dev/null 2>&1; then
  REVIEWER_IDENTITY=$(gh_default_reviewer_identity)
else
  REVIEWER_IDENTITY=${GH_AS_REVIEWER_IDENTITY:-nathanpayne-claude}
fi

# Ledger default: repo-root .mergepath/codex-feedback-ledger.jsonl unless
# overridden by --ledger or $CODEX_FEEDBACK_LEDGER.
if [ -z "$LEDGER" ]; then
  LEDGER=${CODEX_FEEDBACK_LEDGER:-"$__CRF_ROOT/.mergepath/codex-feedback-ledger.jsonl"}
fi

AS_REVIEWER="$__CRF_DIR/gh-as-reviewer.sh"

# Bridge an inline reviewer token to the write path (documented GH_TOKEN=<PAT>
# invocation). gh-as-reviewer.sh re-resolves the reviewer credential via
# gh-token-resolver.sh, whose source precedence is (1) $OP_PREFLIGHT_REVIEWER_PAT
# then (2) `gh auth token --user <reviewer>` — it never reads ambient $GH_TOKEN.
# So a caller that followed this helper's "GH_TOKEN=<reviewer PAT> ..." doc on a
# fresh shell (no op-preflight cache, no stored gh auth token for the reviewer)
# has its read/scan calls succeed on ambient $GH_TOKEN but its reaction POST fail
# because the wrapper finds no reviewer-token source. When NO other source is
# present, forward ambient $GH_TOKEN as $OP_PREFLIGHT_REVIEWER_PAT so the wrapper
# can use it. Attribution is NOT weakened: gh-token-resolver.sh still verifies the
# token with identity-check.sh --expect-token-identity "$REVIEWER_IDENTITY", so a
# non-reviewer token fails closed and the byline stays the reviewer identity.
if [ -z "${OP_PREFLIGHT_REVIEWER_PAT:-}" ] && [ -n "${GH_TOKEN:-}" ]; then
  if ! env -u GH_TOKEN -u GITHUB_TOKEN gh auth token --user "$REVIEWER_IDENTITY" >/dev/null 2>&1; then
    export OP_PREFLIGHT_REVIEWER_PAT="$GH_TOKEN"
    log "no cached/stored reviewer-token source; bridging ambient GH_TOKEN to the reviewer write path (verified as $REVIEWER_IDENTITY by gh-as-reviewer.sh)"
  fi
fi

# Exact feedback solicitation Codex appends to every finding it wants graded.
# Detection is substring-based so surrounding markdown/whitespace does not
# defeat the match, but the phrase itself must appear verbatim.
SOLICITATION='Useful? React with 👍 / 👎.'

# --- collect findings -------------------------------------------------------

fetch_api_array() {
  local endpoint=$1
  local label=$2
  local raw
  raw=$(gh api --paginate "$endpoint" 2>&1) || die 3 "failed to fetch $label: $raw"
  echo "$raw" | jq -s 'add // []' 2>/dev/null \
    || die 3 "failed to flatten $label pagination output"
}

# Normalize an arbitrary findings input into the canonical findings array:
#   [ { path, line, priority, comment_id, body, location } ]
# Accepts either the full codex-review-request.sh object ({ findings: [...] })
# or a bare array. `location` defaults to pull_request_review_comment (where
# request-script findings live) when the producer did not set it.
normalize_findings() {
  jq '
    (if type == "object" and has("findings") then .findings else . end)
    | (if type == "array" then . else [] end)
    | [ .[]
        | {
            path: (.path // null),
            line: (.line // null),
            priority: (.priority // "P?"),
            comment_id: (.comment_id // .id),
            body: (.body // ""),
            location: (.location // "pull_request_review_comment")
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
  log "scanning current-HEAD latest-round Codex findings (read-only)"
  CONFIG=".github/review-policy.yml"
  codex_field() {
    local field=$1
    [ -f "$CONFIG" ] || return 0
    awk -v field="$field" '
      /^codex:/ {in_block=1; next}
      in_block && /^[^[:space:]#]/ {in_block=0}
      in_block && $1 == field":" {
        sub(/^[[:space:]]*[^:]+:[[:space:]]*/, "", $0)
        gsub(/^["\047]/, "", $0)
        gsub(/["\047][[:space:]]*(#.*)?$/, "", $0)
        gsub(/[[:space:]]*#.*$/, "", $0)
        sub(/[[:space:]]+$/, "", $0)
        print
        exit
      }
    ' "$CONFIG"
  }
  BOT_LOGIN=$(codex_field bot_login)
  BOT_LOGIN=${BOT_LOGIN:-"chatgpt-codex-connector[bot]"}

  PR_JSON=$(gh api "repos/$REPO/pulls/$PR_NUMBER" 2>&1) || die 3 "failed to fetch PR metadata: $PR_JSON"
  HEAD_SHA=$(echo "$PR_JSON" | jq -r '.head.sha')
  [ -n "$HEAD_SHA" ] && [ "$HEAD_SHA" != "null" ] || die 3 "could not determine HEAD sha for PR #$PR_NUMBER"

  REVIEWS_JSON=$(fetch_api_array "repos/$REPO/pulls/$PR_NUMBER/reviews" "reviews")
  COMMENTS_JSON=$(fetch_api_array "repos/$REPO/pulls/$PR_NUMBER/comments" "inline comments")

  # Latest Codex review on the current HEAD, then scope findings to that
  # review id only (mirrors codex-review-request.sh's scan_codex_state).
  LATEST_REVIEW_ID=$(echo "$REVIEWS_JSON" | jq -r --arg bot "$BOT_LOGIN" --arg sha "$HEAD_SHA" '
    [.[] | select(.user.login == $bot) | select(.commit_id == $sha)]
    | sort_by(.submitted_at) | last
    | if . == null then "" else .id end
  ')

  if [ -n "$LATEST_REVIEW_ID" ] && [ "$LATEST_REVIEW_ID" != "null" ]; then
    SCANNED=$(echo "$COMMENTS_JSON" | jq \
      --arg bot "$BOT_LOGIN" \
      --argjson review_id "$LATEST_REVIEW_ID" '
      [ .[]
        | select(.user.login == $bot)
        | select(.pull_request_review_id == $review_id)
        | { path, line, comment_id: .id, body,
            location: "pull_request_review_comment",
            priority: (
              (.body | capture("!\\[P(?<n>[0-3]) Badge\\]")? // {n: null}) | .n
              | if . == null then "P?" else "P" + . end
            )
          }
      ]
    ')
  else
    SCANNED='[]'
    log "no Codex review on the current HEAD ($HEAD_SHA) — nothing to scan"
  fi
  COLLECTED=$(jq -n --argjson a "$COLLECTED" --argjson b "$SCANNED" '$a + $b')
fi

# Deduplicate by comment_id (a finding present in both the JSON and the scan
# collapses to one entry; the first occurrence wins).
FINDINGS=$(echo "$COLLECTED" | jq '
  reduce .[] as $f ({seen: {}, out: []};
    if (.seen[($f.comment_id|tostring)] // false) then .
    else .seen[($f.comment_id|tostring)] = true | .out += [$f]
    end)
  | .out
')

FINDINGS_COUNT=$(echo "$FINDINGS" | jq 'length')
log "collected $FINDINGS_COUNT candidate finding(s); reviewer identity = $REVIEWER_IDENTITY"

# --- verdict resolution -----------------------------------------------------

# Map a verdict alias to +1 / -1. Echoes the reaction content on success,
# returns non-zero on an unrecognized alias.
resolve_reaction() {
  local v
  v=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  case "$v" in
    fixed|real|useful|"+1"|thumbsup|thumbs-up|up)
      printf '+1\n' ;;
    rebutted|false-positive|false_positive|falsepositive|not-useful|not_useful|notuseful|"-1"|thumbsdown|thumbs-down|down)
      printf '\055\061\n' ;;  # "-1"
    *)
      return 1 ;;
  esac
}

# Look up the verdict spec for a comment_id. Sets VERDICT_FOUND/VERDICT_VALUE/
# VERDICT_REASON. Last --verdict for a given id wins.
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

# Validate all supplied verdict values UP FRONT so a typo fails before any
# reaction is posted (no partial writes from a bad spec at the end).
for ((vi = 0; vi < ${#VERDICT_VALS[@]}; vi++)); do
  if ! resolve_reaction "${VERDICT_VALS[$vi]}" >/dev/null; then
    die 2 "unrecognized verdict '${VERDICT_VALS[$vi]}' for comment ${VERDICT_IDS[$vi]} (use fixed|real|useful|+1 or rebutted|false-positive|not-useful|-1)"
  fi
done

# --- reaction write helpers -------------------------------------------------

# Echo the reactions endpoint for a finding's location + comment_id.
reactions_endpoint() {
  local location=$1
  local cid=$2
  case "$location" in
    issue_comment|pr_comment|issue)
      printf 'repos/%s/issues/comments/%s/reactions\n' "$REPO" "$cid" ;;
    *)
      # pull_request_review_comment (default) — inline diff findings.
      printf 'repos/%s/pulls/comments/%s/reactions\n' "$REPO" "$cid" ;;
  esac
}

# Returns 0 (and is a no-op POST) if the reviewer identity ALREADY reacted on
# this comment with ANY reaction content — idempotency: leave what's there.
reviewer_reaction_present() {
  local endpoint=$1
  local existing
  existing=$(gh api --paginate "$endpoint" 2>/dev/null | jq -s 'add // []' 2>/dev/null || printf '[]')
  [ "$(echo "$existing" | jq -r --arg who "$REVIEWER_IDENTITY" '
    any(.[]; .user.login == $who)
  ')" = "true" ]
}

# POST a reaction through gh-as-reviewer.sh. Echoes nothing; returns the
# wrapper's exit code.
post_reaction() {
  local endpoint=$1
  local content=$2
  [ -x "$AS_REVIEWER" ] || die 3 "gh-as-reviewer.sh helper missing or non-executable: $AS_REVIEWER"
  GH_AS_REVIEWER_IDENTITY="$REVIEWER_IDENTITY" "$AS_REVIEWER" -- gh api -X POST "$endpoint" -f "content=$content" >/dev/null 2>&1
}

# Append one JSONL verdict record to the ledger.
append_ledger() {
  local record=$1
  local dir
  dir=$(dirname "$LEDGER")
  mkdir -p "$dir" || die 3 "could not create ledger directory: $dir"
  printf '%s\n' "$record" >>"$LEDGER" || die 3 "could not append to ledger: $LEDGER"
}

# --- main loop --------------------------------------------------------------

RECORDED='[]'
SKIPPED='[]'
POST_FAILURES=0
NOW_ISO=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || printf '')

record_skip() {
  local cid=$1
  local why=$2
  SKIPPED=$(jq -n --argjson arr "$SKIPPED" --argjson cid "$cid" --arg why "$why" '
    $arr + [ { comment_id: $cid, why: $why } ]
  ')
}

# Iterate over each soliciting finding; jq emits a compact line per finding.
while IFS= read -r finding; do
  [ -n "$finding" ] || continue
  CID=$(echo "$finding" | jq -r '.comment_id')
  PRIORITY=$(echo "$finding" | jq -r '.priority // "P?"')
  LOCATION=$(echo "$finding" | jq -r '.location // "pull_request_review_comment"')
  BODY=$(echo "$finding" | jq -r '.body // ""')

  # Solicitation gate — never react on a finding that does not ask for it.
  case "$BODY" in
    *"$SOLICITATION"*) : ;;
    *)
      log "comment $CID does not solicit feedback — skipping"
      record_skip "$CID" "no-solicitation"
      continue
      ;;
  esac

  lookup_verdict "$CID"
  if [ "$VERDICT_FOUND" -ne 1 ]; then
    log "comment $CID solicits feedback but no --verdict was supplied — skipping"
    record_skip "$CID" "no-verdict"
    continue
  fi

  REACTION=$(resolve_reaction "$VERDICT_VALUE") \
    || die 2 "unrecognized verdict '$VERDICT_VALUE' for comment $CID"

  ENDPOINT=$(reactions_endpoint "$LOCATION" "$CID")

  if [ "$DRY_RUN" -eq 1 ]; then
    log "[dry-run] would react $REACTION on $ENDPOINT (verdict=$VERDICT_VALUE)"
    ACTION="dry_run"
  elif reviewer_reaction_present "$ENDPOINT"; then
    log "reviewer $REVIEWER_IDENTITY already reacted on comment $CID — leaving it (idempotent)"
    ACTION="already_present"
  else
    if post_reaction "$ENDPOINT" "$REACTION"; then
      log "reacted $REACTION on comment $CID (verdict=$VERDICT_VALUE) as $REVIEWER_IDENTITY"
      ACTION="posted"
    else
      echo "[codex-record-feedback] ERROR: failed to POST $REACTION reaction on comment $CID ($ENDPOINT)" >&2
      POST_FAILURES=$((POST_FAILURES + 1))
      ACTION="post_failed"
    fi
  fi

  # Compact (-c): the ledger is JSONL — one record PER LINE — so downstream
  # consumers (daily-feedback-rollup / pr-audit) can stream it line by line.
  RECORD=$(jq -nc \
    --argjson pr "$PR_NUMBER" \
    --arg repo "$REPO" \
    --argjson cid "$CID" \
    --arg priority "$PRIORITY" \
    --arg verdict "$VERDICT_VALUE" \
    --arg reaction "$REACTION" \
    --arg location "$LOCATION" \
    --arg action "$ACTION" \
    --arg reviewer "$REVIEWER_IDENTITY" \
    --arg reason "$VERDICT_REASON" \
    --arg ts "$NOW_ISO" '
    {
      pr_number: $pr, repo: $repo, comment_id: $cid, priority: $priority,
      verdict: $verdict, reaction: $reaction, location: $location,
      action: $action, reviewer_identity: $reviewer,
      reason: (if $reason == "" then null else $reason end),
      recorded_at: $ts
    }
  ')

  # Persist to the durable ledger (skip on dry-run and on a failed POST — a
  # failed write should not leave a "recorded" ledger row).
  if [ "$DRY_RUN" -ne 1 ] && [ "$ACTION" != "post_failed" ]; then
    append_ledger "$RECORD"
  fi

  RECORDED=$(jq -n --argjson arr "$RECORDED" --argjson rec "$RECORD" '$arr + [ $rec ]')
done < <(echo "$FINDINGS" | jq -c '.[]')

# Verdicts that named a comment_id which is not among the collected findings
# are reported as not-found skips (helps catch a stale/typo'd comment_id).
COLLECTED_IDS=$(echo "$FINDINGS" | jq '[.[].comment_id]')
for ((vi2 = 0; vi2 < ${#VERDICT_IDS[@]}; vi2++)); do
  vid=${VERDICT_IDS[$vi2]}
  if [ "$(echo "$COLLECTED_IDS" | jq --argjson c "$vid" 'index($c) != null')" != "true" ]; then
    log "verdict supplied for comment $vid but no matching collected finding — skipping"
    record_skip "$vid" "not-found"
  fi
done

# --- emit summary -----------------------------------------------------------

jq -n \
  --argjson pr "$PR_NUMBER" \
  --arg repo "$REPO" \
  --arg reviewer "$REVIEWER_IDENTITY" \
  --argjson dry "$([ "$DRY_RUN" -eq 1 ] && echo true || echo false)" \
  --argjson recorded "$RECORDED" \
  --argjson skipped "$SKIPPED" '
  {
    pr_number: $pr,
    repo: $repo,
    reviewer_identity: $reviewer,
    dry_run: $dry,
    recorded: $recorded,
    skipped: $skipped
  }
'

if [ "$POST_FAILURES" -gt 0 ]; then
  exit 1
fi
exit 0
