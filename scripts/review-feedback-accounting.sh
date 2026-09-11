#!/usr/bin/env bash
# Read-only gate that reconciles every bot finding on a pull request with
# finding-bound, GitHub-visible disposition evidence.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DEFAULT_CONFIG="$REPO_ROOT/.github/review-policy.yml"
CONFIG="${REVIEW_FEEDBACK_ACCOUNTING_CONFIG:-}"
RESOLVED_CONFIG=""
POLICY_JSON=""

# Read-only helper: use the cached reviewer PAT when the caller followed the
# normal op-preflight contract but did not export GH_TOKEN explicitly (#282).
if [ -r "$SCRIPT_DIR/lib/preflight-helpers.sh" ]; then
  # shellcheck source=lib/preflight-helpers.sh
  . "$SCRIPT_DIR/lib/preflight-helpers.sh"
  preflight_require_token reviewer || true
fi

if [ ! -r "$SCRIPT_DIR/lib/feedback-policy-helpers.sh" ]; then
  echo "[review-feedback-accounting] ERROR: missing feedback-policy-helpers.sh" >&2
  exit 2
fi
# shellcheck source=lib/feedback-policy-helpers.sh
. "$SCRIPT_DIR/lib/feedback-policy-helpers.sh"

if [ ! -r "$SCRIPT_DIR/lib/gh-api-array.sh" ]; then
  echo "[review-feedback-accounting] ERROR: missing gh-api-array.sh" >&2
  exit 2
fi
# shellcheck source=lib/gh-api-array.sh
. "$SCRIPT_DIR/lib/gh-api-array.sh"

if [ ! -r "$SCRIPT_DIR/lib/gh-api-scalar.sh" ]; then
  echo "[review-feedback-accounting] ERROR: missing gh-api-scalar.sh" >&2
  exit 2
fi
# shellcheck source=lib/gh-api-scalar.sh
. "$SCRIPT_DIR/lib/gh-api-scalar.sh"

if [ ! -r "$SCRIPT_DIR/lib/ghas-alert-severity.sh" ]; then
  echo "[review-feedback-accounting] ERROR: missing ghas-alert-severity.sh" >&2
  exit 2
fi
# shellcheck source=lib/ghas-alert-severity.sh
. "$SCRIPT_DIR/lib/ghas-alert-severity.sh"
ghas_severity_cache_init || exit 2
# Registered immediately (not after later setup) so a validation failure
# between here and the fuller trap below still cleans up the cache file;
# $RESOLVED_CONFIG is read at EXIT time, not now, so it is safe to
# reference before that variable is ever assigned a real path.
trap 'ghas_severity_cache_cleanup; if [ -n "$RESOLVED_CONFIG" ]; then rm -f "$RESOLVED_CONFIG"; fi' EXIT

die() {
  local code="$1"
  shift
  echo "[review-feedback-accounting] ERROR: $*" >&2
  exit "$code"
}

usage() {
  echo "Usage: $0 <PR_NUMBER> [REPO]" >&2
  exit 2
}

[ $# -ge 1 ] && [ $# -le 2 ] || usage
PR_NUMBER="$1"
case "$PR_NUMBER" in
  ''|*[!0-9]*) die 2 "PR_NUMBER must be an integer; got '$PR_NUMBER'" ;;
esac
[ -n "${GH_TOKEN:-}" ] || die 2 "GH_TOKEN is required"

REPO="${2:-}"
if [ -z "$REPO" ]; then
  REPO=$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null || true)
  [ -n "$REPO" ] || die 2 "could not detect repository; pass owner/repo"
fi
case "$REPO" in
  */*) ;;
  *) die 2 "REPO must be owner/repo; got '$REPO'" ;;
esac

if [ -z "$CONFIG" ]; then
  POLICY_RESOLVER="$SCRIPT_DIR/workflow/resolve_base_policy.sh"
  [ -x "$POLICY_RESOLVER" ] || die 2 "missing executable base-policy resolver: $POLICY_RESOLVER"
  # Accounting is a merge-safety decision, so a checkout merely NAMED like
  # the default branch is not proof that its policy matches the PR base. It
  # may be behind, ahead, or dirty. Materialize the policy at the exact base
  # SHA for every invocation; the resolver retains its no-fetch trusted mode
  # for callers that independently prove content equality.
  RESOLVER_ARGS=(--repo "$REPO" --pr "$PR_NUMBER" \
    --default-config "$DEFAULT_CONFIG" --materialize-default)
  CONFIG=$(
    "$POLICY_RESOLVER" "${RESOLVER_ARGS[@]}"
  ) || die 2 "could not resolve the review policy governing $REPO#$PR_NUMBER"
  if [ "$CONFIG" != "$DEFAULT_CONFIG" ]; then
    RESOLVED_CONFIG="$CONFIG"
  fi
fi

validate_governing_policy() {
  local parsed=""
  [ -r "$CONFIG" ] || die 2 "governing review policy is unreadable: $CONFIG"
  # Parsed through the shared policy_yaml_to_json in
  # scripts/lib/feedback-policy-helpers.sh (Codex P2, PR #1124). It began as
  # this block; a second, weaker reader drifting from it is precisely the bug
  # that review found, so there is now one parser and this is a caller of it.
  parsed=$(policy_yaml_to_json "$CONFIG") \
    || die 2 "governing review policy did not parse as YAML (or no YAML parser is available): $CONFIG"
  [ -n "$parsed" ] \
    || die 2 "governing review policy did not parse as YAML: $CONFIG"
  printf '%s' "$parsed" | jq -e '
    def optional_string($key):
      (has($key) | not) or (.[$key] | type == "string");
    def optional_object($key):
      (has($key) | not) or (.[$key] | type == "object");
    type == "object"
    and optional_string("author_identity")
    and ((has("available_reviewers") | not)
      or ((.available_reviewers | type == "array")
        and all(.available_reviewers[]; type == "string" and length > 0)))
    and optional_object("codex")
    and optional_object("coderabbit")
    and optional_object("code_scanning")
    and ((.codex // {}) | optional_string("bot_login"))
    and ((.coderabbit // {}) | optional_string("bot_login"))
    and ((.code_scanning // {}) | optional_string("bot_login"))
    and optional_object("feedback_policy")
    and ((.feedback_policy // {}) | optional_string("mode"))
    and (((.feedback_policy // {}).mode // "by-priority") as $mode
      | ($mode == "by-priority" or $mode == "address-all"))
    and (((.feedback_policy // {}) | has("priorities") | not)
      or (((.feedback_policy // {}).priorities | type == "object")
        and all((.feedback_policy // {}).priorities[];
          . == "required" or . == "discretionary" or . == "ignore")))
  ' >/dev/null 2>&1 \
    || die 2 "governing review policy has an invalid accounting schema: $CONFIG"
  POLICY_JSON="$parsed"
}

validate_governing_policy

policy_top_field() {
  local field="$1"
  printf '%s' "$POLICY_JSON" | jq -r --arg field "$field" '.[$field] // empty'
}

policy_block_field() {
  local block="$1" field="$2"
  printf '%s' "$POLICY_JSON" | jq -r --arg block "$block" --arg field "$field" \
    '.[$block][$field] // empty'
}

policy_reviewers() {
  printf '%s' "$POLICY_JSON" | jq -r '.available_reviewers[]?'
}

AUTHOR_IDENTITY=$(policy_top_field author_identity)
AUTHOR_IDENTITY=${AUTHOR_IDENTITY:-nathanjohnpayne}
CODEX_BOT=$(policy_block_field codex bot_login)
CODEX_BOT=${CODEX_BOT:-chatgpt-codex-connector[bot]}
CODERABBIT_BOT=$(policy_block_field coderabbit bot_login)
CODERABBIT_BOT=${CODERABBIT_BOT:-coderabbitai[bot]}
GHAS_BOT=$(policy_block_field code_scanning bot_login)
GHAS_BOT=${GHAS_BOT:-github-advanced-security[bot]}

REVIEWER_LOGINS_JSON=$(
  policy_reviewers | awk 'NF && !seen[$0]++' | jq -Rsc 'split("\n") | map(select(. != ""))'
) || die 2 "could not parse available_reviewers from $CONFIG"
AGENT_LOGINS_JSON=$(
  {
    printf '%s\n' "$AUTHOR_IDENTITY"
    policy_reviewers
  } | awk 'NF && !seen[$0]++' | jq -Rsc 'split("\n") | map(select(. != ""))'
) || die 2 "could not parse available_reviewers from $CONFIG"

registered_reviewer_login() {
  printf '%s' "$REVIEWER_LOGINS_JSON" | jq -e --arg login "$1" 'index($login) != null' >/dev/null 2>&1
}

tier_is_ignored() {
  local tier="$1" mode disposition
  mode=$(printf '%s' "$POLICY_JSON" | jq -r '.feedback_policy.mode // empty')
  mode=${mode:-by-priority}
  case "$mode" in
    address-all) return 1 ;;
    by-priority) ;;
    *) die 2 "feedback_policy.mode must be by-priority|address-all; got '$mode'" ;;
  esac
  disposition=$(printf '%s' "$POLICY_JSON" | jq -r --arg tier "$tier" \
    '.feedback_policy.priorities[$tier] // empty')
  case "$disposition" in
    ""|required|discretionary) return 1 ;;
    ignore) return 0 ;;
    *) die 2 "feedback_policy.priorities.$tier must be required|discretionary|ignore; got '$disposition'" ;;
  esac
}

fetch_api_array() {
  gh_api_array "$1" "$2" || die 2 "$GH_API_ARRAY_ERROR"
}

INLINE_COMMENTS=$(fetch_api_array "repos/$REPO/pulls/$PR_NUMBER/comments" "inline review comments")
REVIEWS=$(fetch_api_array "repos/$REPO/pulls/$PR_NUMBER/reviews" "review objects")
ISSUE_COMMENTS=$(fetch_api_array "repos/$REPO/issues/$PR_NUMBER/comments" "PR-level comments")

# #1210: on a pull request from a fork the relay's archive records are
# rendered by the fork-side run and accepted by the relay on marker shape
# alone, so their bodies are the fork's to write. Such a record may add a
# demand (an inventoried revision and its token) but never stands as
# evidence that lowers a floor. The head is a fork when it is not the base
# repository itself, compared by repository identity rather than by the
# fork flag of the head, which is also true for every branch of a
# repository that is itself a fork. A head repository that is gone can only
# have been a fork, and reads the same way. The fetch fails closed.
PR_OBJECT=$(gh api "repos/$REPO/pulls/$PR_NUMBER" 2>/dev/null) \
  || die 2 "could not fetch pull request $REPO#$PR_NUMBER"
PR_HEAD_IS_FORK=$(printf '%s' "$PR_OBJECT" | jq -r '
  if (.head.repo // null) == null then "true"
  elif (.head.repo.id // null) != null and (.base.repo.id // null) != null
  then (if .head.repo.id != .base.repo.id then "true" else "false" end)
  elif (.head.repo.full_name // "") != "" and (.base.repo.full_name // "") != ""
  then (if (.head.repo.full_name | ascii_downcase) != (.base.repo.full_name | ascii_downcase)
        then "true" else "false" end)
  else "true" end')
# A source run blocks only when EVERY terminal marker it carries says failed.
# Recency cannot decide this: restoring an edited or deleted marker reposts the
# exact prior body under a new comment id and created_at, so the restored copy
# always sorts last and a stale completion could mask a later failure (or a
# stale failure could invent a permanent block). Presence of a completion is the
# durable fact — the archive it records cannot be un-persisted by a later rerun
# that no longer finds its artifact — and presence is immune to reordering.
RELAY_FAILURE_RUN=$(printf '%s' "$ISSUE_COMMENTS" | jq -r '
  [
    .[]
    | select(.user.login == "github-actions[bot]")
    | . as $comment
    | ((.body // "")
      | try capture("^<!-- mergepath-feedback-archive-relay:v1 run=(?<run>[0-9]+) status=(?<status>complete|failed) -->$")
        catch null) as $marker
    | select($marker != null)
    | {
        run: ($marker.run | tonumber),
        status: $marker.status,
        created_at: ($comment.created_at // ""),
        id: $comment.id
      }
  ]
  | sort_by(.run, .created_at, .id)
  | group_by(.run)
  | map(select(all(.[]; .status == "failed")) | .[0].run)
  | first // empty
') || die 2 "could not validate read-only feedback archive relay state"
if [ -n "$RELAY_FAILURE_RUN" ]; then
  die 2 "read-only feedback archive relay failed for source run $RELAY_FAILURE_RUN; prior feedback may be unrecoverable"
fi

tier_rank() {
  case "$1" in
    p0) echo 0 ;;
    p1) echo 1 ;;
    p2) echo 2 ;;
    p3) echo 3 ;;
    nitpick) echo 4 ;;
    *) echo 99 ;;
  esac
}

# ghas_finding_tier <body> — resolve a github-advanced-security[bot] inline
# comment to a tier (#1101, redesigned #1113). The body's only structured
# signal is a link to the alert (".../security/code-scanning/<number>");
# ghas_alert_severity resolves that number's CURRENT severity by a direct
# per-alert GET, not a ref-scoped list, so this works identically for a
# finding raised on any past head, not only the current one (#1113 item 3).
#
# Falls back to p2 — accountable, but not required under the default
# feedback_policy — when no alert-number link can be parsed from the body,
# or the alert was read successfully but its rule carries no
# security_severity_level (e.g. a non-security CodeQL quality query). p2
# keeps the finding tracked rather than silently dropped, which is the
# defect this whole change exists to close, without unilaterally making an
# unclassifiable finding merge-blocking.
#
# A FAILED read (network/auth/rate-limit — ghas_alert_severity rc=3) is
# NOT folded into that same p2 fallback: it propagates as a hard failure
# (return 2), matching every other fetch in this script. A systemic
# security-events permission gap must surface loudly, not disappear as a
# confident-looking p2 — exactly the class of bug Codex found in #1101's
# first version (PR #1106).
ghas_finding_tier() {
  local body="$1" alert_number severity tier rc
  alert_number=$(ghas_alert_number_from_body "$body")
  if [ -z "$alert_number" ]; then
    printf '%s' p2
    return 0
  fi
  rc=0
  severity=$(ghas_alert_severity "$REPO" "$alert_number") || rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "[review-feedback-accounting] ERROR: could not read code-scanning alert #$alert_number for $REPO" >&2
    return 2
  fi
  tier=$(ghas_severity_tier "$severity")
  printf '%s' "${tier:-p2}"
}

finding_tier() {
  local login="$1" body="$2" tier="" line sanitized
  if [ "$login" = "$CODEX_BOT" ] || registered_reviewer_login "$login"; then
    codex_tier_of "$body"
    return
  fi
  if [ "$login" = "$CODERABBIT_BOT" ]; then
    sanitized=$(coderabbit_finding_scan "$body") || return 2
    while IFS= read -r line; do
      tier=$(coderabbit_tier_of "$line")
      if [ -n "$tier" ]; then
        printf '%s' "$tier"
        return
      fi
    done <<EOF
$sanitized
EOF
    return
  fi
  if [ "$login" = "$GHAS_BOT" ]; then
    ghas_finding_tier "$body"
  fi
}

strongest_nonignored_finding_tier() {
  local login="$1" body="$2" tier="" tiers="" sanitized
  local best="" best_rank=99 rank
  sanitized="$body"
  if [ "$login" = "$CODEX_BOT" ] || registered_reviewer_login "$login"; then
    tiers=$(codex_tiers_of "$sanitized")
  elif [ "$login" = "$CODERABBIT_BOT" ]; then
    sanitized=$(coderabbit_finding_scan "$body") || return 2
    tiers=$(coderabbit_tiers_of "$sanitized")
  fi
  while IFS= read -r tier; do
    [ -n "$tier" ] || continue
    tier_is_ignored "$tier" && continue
    rank=$(tier_rank "$tier")
    if [ "$rank" -lt "$best_rank" ]; then
      best="$tier"
      best_rank="$rank"
    fi
  done <<EOF
$tiers
EOF
  printf '%s' "$best"
}

INLINE_CANDIDATES='[]'
while IFS= read -r comment; do
  [ -n "$comment" ] || continue
  login=$(printf '%s' "$comment" | jq -r '.user.login // ""')
  case "$login" in
    "$CODEX_BOT"|"$CODERABBIT_BOT"|"$GHAS_BOT") ;;
    *) registered_reviewer_login "$login" || continue ;;
  esac
  body=$(printf '%s' "$comment" | jq -r '.body // ""')
  tier=$(finding_tier "$login" "$body")
  [ -n "$tier" ] || continue
  tier_is_ignored "$tier" && continue
  INLINE_CANDIDATES=$(printf '%s\n%s\n' "$INLINE_CANDIDATES" "$comment" | jq -cs \
    --arg tier "$tier" '
      .[0] + [(.[1] as $c | {
        kind: "inline",
        root_id: ($c.in_reply_to_id // $c.id),
        finding_id: $c.id,
        reviewer: ($c.user.login // ""),
        tier: $tier,
        created_at: ($c.created_at // ""),
        updated_at: ($c.updated_at // $c.created_at // ""),
        path: ($c.path // "(unknown)"),
        line: ($c.line // $c.original_line // null),
        body: ($c.body // "")
      })]
    ')
done <<EOF
$(printf '%s' "$INLINE_COMMENTS" | jq -c '.[]')
EOF

INLINE_CANDIDATES=$(printf '%s' "$INLINE_CANDIDATES" | jq -c '
  sort_by(.root_id, (.updated_at // .created_at), .created_at, .finding_id)
  | group_by(.root_id)
  | map(last)
')

agent_reply_after_finding() {
  local root_id="$1" floor="$2" finding_id="$3" confirmed_login="$4"
  printf '%s' "$INLINE_COMMENTS" | jq -e \
    --argjson root "$root_id" --arg floor "$floor" --argjson finding "$finding_id" \
    --arg confirmed "$confirmed_login" --argjson agents "$AGENT_LOGINS_JSON" '
      any(.[];
        (.in_reply_to_id != null)
        and (.in_reply_to_id == $root)
        and (.id != $finding)
        and (((.created_at // "") > $floor)
          or ($confirmed != ""
            and (.user.login // "") == $confirmed
            and (.created_at // "") == $floor))
        and ((.user.login // "") as $login | ($agents | index($login)) != null)
        and (((.body // "") | gsub("\\[mergepath-resolve:[^]]*\\]"; "")
          | gsub("^[[:space:]]+|[[:space:]]+$"; "")
          | gsub("[[:space:]]+"; " ")) as $body
          | (($body | length) >= 12)
          and (([$body | scan("[[:alnum:]][[:alnum:]_-]*")] | length) >= 2)))
    ' >/dev/null 2>&1
}

# CodeRabbit acknowledges a disposition by EDITING its finding comment rather
# than replying, so every acknowledgement advances the finding's updated_at.
# Observed shapes of that edit, all ending the body:
#   1. the finding's `auto-generated comment` footer is rewritten to the
#      `auto-generated reply` marker and a confirmation line is appended;
#   2. reply marker, confirmation line, reply marker;
#   3. reply marker, confirmation line, `auto-generated comment` footer;
#   4. confirmation line, then either footer (the original #1000 form);
#   5. the footer rewritten to the reply marker with NO confirmation line,
#      after a reply CodeRabbit does not confirm (handled below the FINDINGS
#      loop from the relay's record, since it carries no marker of its own);
# and any of them stacked when CodeRabbit acknowledges again. The wording of
# the confirmation line varies (`✅ Confirmed as addressed by @<login>`,
# `✅ Addressed in commit <sha>`, plurals), so recognition is anchored on the
# vendor's generated footer markers, either kind (#1167).
#
# The model is a trailing RUN: the lines at the end of the body that are a
# footer marker or a confirmation line, blank lines allowed between them. A
# ✅ line is a confirmation when it carries a known confirmation wording or
# when the non-blank line directly above it is the reply marker, which is
# where every observed shape puts it; a content line that happens to start
# with ✅ before the finding's own footer stays content, and ✅ lines with no
# marker at all are content, not a run. The run acknowledges when it holds
# at least one marker and at least one confirmation line.
# Anything after the run, visible content or a code fence, is an ordinary
# edit, and a run inside a fence is not a run.
#
# mode=run prints the run (trimmed, non-blank; may be empty); mode=suffix
# prints it and exits 1 unless it acknowledges; mode=strip prints the body
# without the run; mode=trim prints the body with only trailing blank lines
# removed. strip and trim print lines with only the carriage return removed,
# so two revisions compare on content, trailing spaces included.
CODERABBIT_ACK_PAIR_AWK='
  function trimmed(s) { sub(/\r$/, "", s); sub(/[ \t]+$/, "", s); return s }
  function crless(s) { sub(/\r$/, "", s); return s }
  function is_reply(s) {
    return s ~ /^<!-- This is an auto-generated reply by CodeRabbit -->$/
  }
  function is_marker(s) {
    return s ~ /^<!-- This is an auto-generated (comment|reply) by CodeRabbit -->$/
  }
  function is_check(s) { return s ~ /^✅[^ \t]*[ \t]+[^ \t]/ }
  function is_known(s) {
    return s ~ /^✅[^ \t]*[ \t]+(Confirmed as addressed by @[A-Za-z0-9-]+$|Addressed in commits? )/
  }
  { raw[NR] = crless($0); t[NR] = trimmed($0) }
  END {
    n = NR
    while (n > 0 && t[n] == "") n--
    m = 0
    for (k = 1; k <= n; k++) if (t[k] != "") nb[++m] = k
    p = m
    markers = 0
    confirmations = 0
    while (p > 0) {
      k = nb[p]
      if (is_marker(t[k])) { markers++; p--; continue }
      if (is_check(t[k])) {
        above = (p > 1) ? nb[p - 1] : 0
        if (is_known(t[k]) || (above && is_reply(t[above]))) {
          confirmations++
          p--
          continue
        }
      }
      break
    }
    if (markers == 0) { p = m; confirmations = 0 }
    i = (p > 0) ? nb[p] : 0
    if (mode == "run" || mode == "suffix") {
      for (k = i + 1; k <= n; k++) if (t[k] != "") print t[k]
      if (mode == "suffix" && (markers == 0 || confirmations == 0)) exit 1
      exit 0
    }
    end = n
    if (mode == "strip") end = i
    for (k = 1; k <= end; k++) print raw[k]
  }
'

# coderabbit_ack_run <body> — the trailing footer/confirmation run of a
# CodeRabbit body, when the raw body and its fence-aware visible text agree
# on it: the raw run must be the tail of the visible run (the visible run may
# reach further up through a region the scan suppresses). Exit 1 when they
# disagree: a run inside an unclosed fence, or a fence after the run. Empty
# output with exit 0 means "no run".
coderabbit_ack_run() {
  local body="$1" visible raw_run visible_run vl rl
  visible=$(coderabbit_finding_scan "$body") || return 1
  raw_run=$(printf '%s\n' "$body" | awk -v mode=run "$CODERABBIT_ACK_PAIR_AWK")
  visible_run=$(printf '%s\n' "$visible" | awk -v mode=run "$CODERABBIT_ACK_PAIR_AWK")
  if [ -z "$raw_run" ]; then
    [ -z "$visible_run" ] || return 1
    return 0
  fi
  vl=${#visible_run}
  rl=${#raw_run}
  if [ "$vl" -eq "$rl" ]; then
    [ "$visible_run" = "$raw_run" ] || return 1
  else
    [ "$vl" -gt "$rl" ] || return 1
    [ "${visible_run:$((vl - rl))}" = "$raw_run" ] || return 1
    [ "${visible_run:$((vl - rl - 1)):1}" = $'\n' ] || return 1
  fi
  printf '%s' "$raw_run"
}

# coderabbit_ack_suffix <body> — the trusted acknowledgement suffix, or exit
# 1 when the body does not end in an acknowledging run.
coderabbit_ack_suffix() {
  local body="$1" run
  run=$(coderabbit_ack_run "$body") || return 1
  [ -n "$run" ] || return 1
  printf '%s\n' "$run" | awk -v mode=suffix "$CODERABBIT_ACK_PAIR_AWK" >/dev/null || return 1
  printf '%s' "$run"
}

# coderabbit_ack_login <suffix> — the first configured identity a
# login-naming confirmation names, or exit 1. Only that wording carries one;
# the commit-naming form and any other marker-anchored wording reset the
# floor without naming anyone.
coderabbit_ack_login() {
  local suffix="$1" login
  while IFS= read -r login; do
    [ -n "$login" ] || continue
    if printf '%s' "$AGENT_LOGINS_JSON" \
      | jq -e --arg login "$login" 'index($login) != null' >/dev/null 2>&1; then
      printf '%s' "$login"
      return 0
    fi
  done <<EOF
$(printf '%s\n' "$suffix" | awk '
  /^✅[^ \t]*[ \t]+Confirmed as addressed by @[A-Za-z0-9-]+$/ {
    sub(/^✅[^ \t]*[ \t]+Confirmed as addressed by @/, "")
    print
  }')
EOF
  return 1
}

# coderabbit_strip_ack_suffix <body> — the body without its trailing
# footer/confirmation run, carriage returns and trailing blank lines removed,
# for comparing two revisions of one finding on content. The run is removed
# only when the raw body and its visible text agree on it; otherwise only the
# carriage returns and trailing blank lines go.
coderabbit_strip_ack_suffix() {
  local body="$1" mode=strip
  coderabbit_ack_run "$body" >/dev/null 2>&1 || mode=trim
  printf '%s\n' "$body" | awk -v mode="$mode" "$CODERABBIT_ACK_PAIR_AWK"
}

FINDINGS='[]'
while IFS= read -r finding; do
  [ -n "$finding" ] || continue
  root_id=$(printf '%s' "$finding" | jq -r '.root_id')
  finding_id=$(printf '%s' "$finding" | jq -r '.finding_id')
  reviewer=$(printf '%s' "$finding" | jq -r '.reviewer')
  body=$(printf '%s' "$finding" | jq -r '.body // ""')
  floor=$(printf '%s' "$finding" | jq -r '.updated_at // .created_at')
  confirmed_login=""
  if [ "$reviewer" = "$CODERABBIT_BOT" ]; then
    if ack_suffix=$(coderabbit_ack_suffix "$body"); then
      # CodeRabbit's own acknowledgement of a disposition is not a re-raise.
      # Keep the finding's creation as its evidence floor so the reply the
      # acknowledgement answers stays valid, whichever shape or wording the
      # acknowledgement takes and however often it is appended (#1167).
      floor=$(printf '%s' "$finding" | jq -r '.created_at')
      confirmed_login=$(coderabbit_ack_login "$ack_suffix" || true)
    fi
  fi
  accounted=false
  evidence=""
  if agent_reply_after_finding "$root_id" "$floor" "$finding_id" "$confirmed_login"; then
    accounted=true
    evidence="thread-reply"
  fi
  FINDINGS=$(printf '%s\n%s\n' "$FINDINGS" "$finding" | jq -cs \
    --argjson accounted "$accounted" --arg evidence "$evidence" \
    --arg confirmed_login "$confirmed_login" '
      .[0] + [(.[1] + {
        accounted: $accounted,
        evidence: (if $evidence == "" then null else $evidence end),
        confirmed_login: (if $confirmed_login == "" then null else $confirmed_login end)
      })]
    ')
done <<EOF
$(printf '%s' "$INLINE_CANDIDATES" | jq -c '.[]')
EOF

fingerprint() {
  local out
  if command -v sha256sum >/dev/null 2>&1; then
    out=$(printf '%s' "$1" | sha256sum)
  elif command -v shasum >/dev/null 2>&1; then
    out=$(printf '%s' "$1" | shasum -a 256)
  else
    die 2 "neither sha256sum nor shasum is available for acknowledgement fingerprints"
  fi
  printf '%s' "$out" | awk '{print substr($1, 1, 12)}'
}

ack_present() {
  local token="$1" raised_at="$2"
  printf '%s' "$ISSUE_COMMENTS" | jq -e \
    --arg token "$token" --arg raised "$raised_at" --argjson agents "$AGENT_LOGINS_JSON" '
      any(.[];
        ((.user.login // "") as $login | ($agents | index($login)) != null)
        and ((.created_at // "") > $raised)
        and (((.body // "") | gsub("\r"; "") | split("\n")) as $lines
          | (($lines[0] // "") | sub("[ \t]+$"; "")) == $token
          and (($lines[1:] | join(" ")
            | gsub("\\[mergepath-resolve:[^]]*\\]"; "")
            | gsub("^[[:space:]]+|[[:space:]]+$"; "")
            | gsub("[[:space:]]+"; " ")) as $rationale
            | (($rationale | length) >= 12)
            and (([$rationale | scan("[[:alnum:]][[:alnum:]_-]*")] | length) >= 2))))
    ' >/dev/null 2>&1
}

validate_archive_payload() {
  jq -e '
    type == "object"
    and ((.archive_version // 1) == 1 or (.archive_version // 1) == 2)
    and ((.source_kind // "issue-comment") as $kind
      | $kind == "issue-comment" or $kind == "inline" or $kind == "review-body")
    and (.source_comment_id | type == "number" and . > 0 and floor == .)
    and (.source_login | type == "string" and length > 0)
    and (.archived_at | type == "string" and length > 0)
    and (.body_fingerprint | type == "string" and test("^[0-9a-f]{12}$"))
    and (if (.archive_version // 1) == 2 then (.body | type == "string")
      else ((has("body") | not) or (.body | type == "string")) end)
    and (.codex_tiers | type == "array"
      and all(.[]; . == "p0" or . == "p1" or . == "p2" or . == "p3"))
    and (.coderabbit_tiers | type == "array"
      and all(.[]; . == "p0" or . == "p1" or . == "p2" or . == "p3" or . == "nitpick"))
    and ((.ghas_tiers // []) | type == "array"
      and all(.[]; . == "p0" or . == "p1" or . == "p2" or . == "p3"))
  ' >/dev/null 2>&1
}

archive_payload() {
  local body="$1" encoded payload
  encoded=$(printf '%s\n' "$body" | sed -nE \
    '1s/^<!-- mergepath-feedback-archive:v1 ([A-Za-z0-9+\/=]+) -->$/\1/p')
  [ -n "$encoded" ] || return 1
  payload=$(printf '%s' "$encoded" | jq -Rer '@base64d | fromjson') || return 1
  printf '%s' "$payload" | validate_archive_payload || return 1
  printf '%s' "$payload" | jq -c '.source_kind = (.source_kind // "issue-comment")'
}

strongest_nonignored_archive_tier() {
  local tiers_json="$1" tier best="" best_rank=99 rank
  while IFS= read -r tier; do
    [ -n "$tier" ] || continue
    tier_is_ignored "$tier" && continue
    rank=$(tier_rank "$tier")
    if [ "$rank" -lt "$best_rank" ]; then
      best="$tier"
      best_rank="$rank"
    fi
  done <<EOF
$(printf '%s' "$tiers_json" | jq -r '.[]')
EOF
  printf '%s' "$best"
}

# GitHub exposes only the current body of edited PR-level comments, inline
# comments, and top-level review bodies, and removes a deleted comment from its
# original endpoint. The trusted workflow snapshots the prior marker set in an
# append-only issue comment before it can disappear. Trust only records authored
# by github-actions[bot], bind them back to a configured source identity, and
# use every distinct archived finding version even when the live source was
# rewritten into another finding. Identical live/archive deliveries collapse
# by source kind + id + fingerprint; a distinct body remains independently
# dispositionable.
ARCHIVE_ENTRIES='[]'
while IFS= read -r archive_comment; do
  [ -n "$archive_comment" ] || continue
  archive_login=$(printf '%s' "$archive_comment" | jq -r '.user.login // ""')
  [ "$archive_login" = 'github-actions[bot]' ] || continue
  archive_body=$(printf '%s' "$archive_comment" | jq -r '.body // ""')
  payload=$(archive_payload "$archive_body" || true)
  [ -n "$payload" ] || continue
  archive_comment_id=$(printf '%s' "$archive_comment" | jq -r '.id')
  # A repaired archive comment is a byte-for-byte restoration of the same
  # history record. Keep its evidence floor tied to the immutable payload,
  # rather than advancing it to the replacement GitHub comment's created_at.
  archived_at=$(printf '%s' "$payload" | jq -r '.archived_at')
  archive_entry=$(printf '%s' "$payload" | jq -c \
    --argjson archive_comment_id "$archive_comment_id" --arg archived_at "$archived_at" '
      {archive_comment_id:$archive_comment_id,archived_at:$archived_at,payload:.}
    ')
  ARCHIVE_ENTRIES=$(printf '%s\n%s\n' "$ARCHIVE_ENTRIES" "$archive_entry" \
    | jq -cs '.[0] + [.[1]]')
done <<EOF
$(printf '%s' "$ISSUE_COMMENTS" | jq -c '.[]')
EOF

V2_ARCHIVE_ENTRIES=$(printf '%s' "$ISSUE_COMMENTS" | jq -c '
  [
    .[]
    | select((.user.login // "") == "github-actions[bot]")
    | . as $comment
    | ((.body // "")
      | try capture("^<!-- mergepath-feedback-archive:v2 id=(?<archive_id>[0-9a-f]{64}) part=(?<part>[0-9]+)/(?<total>[0-9]+) data=(?<data>[A-Za-z0-9+/=]+) -->$")
        catch null) as $marker
    | select($marker != null)
    | {
        archive_id: $marker.archive_id,
        part: ($marker.part | tonumber),
        total: ($marker.total | tonumber),
        data: $marker.data,
        archive_comment_id: $comment.id,
        archived_at: ($comment.created_at // $comment.updated_at // "")
      }
  ]
  | sort_by(.archive_id, .part, .archive_comment_id)
  | group_by(.archive_id)
  | map(
      . as $raw_parts
      | ($raw_parts | group_by(.part)) as $part_groups
      | (if any($part_groups[]; (map([.total, .data]) | unique | length) != 1) then
          error("conflicting duplicate v2 archive parts")
        else ($part_groups | map(last))
        end) as $parts
      | ($parts[0].total) as $total
      | if ($total < 1 or $total > 32)
          or ($parts | map(.total) | unique) != [$total]
          or ($parts | map(.part) | sort) != [range(1; $total + 1)]
          or any($parts[]; (.data | length) < 1 or (.data | length) > 60000)
        then error("incomplete or invalid v2 archive")
        else
          ($parts | sort_by(.part) | map(.data) | join("") | @base64d | fromjson) as $payload
          | {
              archive_comment_id: ($parts | map(.archive_comment_id) | max),
              archived_at: $payload.archived_at,
              payload: $payload
            }
        end
    )
') || die 2 "could not reconstruct chunked feedback archives"
printf '%s' "$V2_ARCHIVE_ENTRIES" | jq -e 'all(.[]; .payload | type == "object")' \
  >/dev/null 2>&1 || die 2 "chunked feedback archive payload is malformed"
ARCHIVE_ENTRIES=$(printf '%s\n%s\n' "$ARCHIVE_ENTRIES" "$V2_ARCHIVE_ENTRIES" \
  | jq -cs '.[0] + .[1]')

# #1167, with the relay's record available: the record decides what the
# latest edit did. An edit that changed no visible content never raises a
# CodeRabbit inline finding's evidence floor, whether or not it carried a
# confirmation line (CodeRabbit also rewrites its footer to the reply marker
# after a reply it does not confirm, with no line at all); the floor is then
# the newest archived revision whose content differs from the live body, or
# the finding's creation. An edit that changed content raises the floor to
# that edit even when an acknowledgement came with it, so a reply to the old
# text cannot stand for the new. Every CodeRabbit inline finding with a
# record is revisited; without a record the marker-based decision stands.
# On a fork pull request the record is fork-supplied (#1210), so no finding
# is revisited: the marker-based decision stands and every archived
# revision stays inventoried.
REFINED_FINDINGS='[]'
while IFS= read -r finding; do
  [ -n "$finding" ] || continue
  if [ "$PR_HEAD_IS_FORK" = true ] \
    || [ "$(printf '%s' "$finding" | jq -r '.reviewer')" != "$CODERABBIT_BOT" ]; then
    REFINED_FINDINGS=$(printf '%s\n%s\n' "$REFINED_FINDINGS" "$finding" | jq -cs '.[0] + [.[1]]')
    continue
  fi
  finding_id=$(printf '%s' "$finding" | jq -r '.finding_id')
  root_id=$(printf '%s' "$finding" | jq -r '.root_id')
  confirmed_login=$(printf '%s' "$finding" | jq -r '.confirmed_login // ""')
  live_stripped=$(coderabbit_strip_ack_suffix "$(printf '%s' "$finding" | jq -r '.body // ""')")
  content_floor=""
  content_matched=false
  archives_seen=false
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    archives_seen=true
    archived_at=$(printf '%s' "$entry" | jq -r '.archived_at')
    if [ "$(coderabbit_strip_ack_suffix "$(printf '%s' "$entry" | jq -r '.payload.body')")" = "$live_stripped" ]; then
      content_matched=true
    elif [ -z "$content_floor" ] || [ "$archived_at" \> "$content_floor" ]; then
      content_floor="$archived_at"
    fi
  done <<EOF
$(printf '%s' "$ARCHIVE_ENTRIES" | jq -c --argjson id "$finding_id" --arg login "$CODERABBIT_BOT" '
  .[] | select((.payload.source_kind // "issue-comment") == "inline"
    and .payload.source_comment_id == $id
    and .payload.source_login == $login
    and (.payload.body | type) == "string")' \
  | while IFS= read -r entry; do
      [ -n "$entry" ] || continue
      [ "$(fingerprint "$(printf '%s' "$entry" | jq -c '.payload.body')")" = \
        "$(printf '%s' "$entry" | jq -r '.payload.body_fingerprint')" ] || continue
      printf '%s\n' "$entry"
    done)
EOF
  # With a record, the record decides: the latest edit was content-free only
  # when some archived revision has the live content, and then the floor is
  # the newest content change; otherwise the latest edit changed content and
  # the floor is that edit, whatever acknowledgement it was delivered with.
  # Without a record the marker-based decision above stands.
  if [ "$archives_seen" = true ]; then
    finding_created_at=$(printf '%s' "$finding" | jq -r '.created_at')
    if [ "$content_matched" = true ]; then
      [ -n "$content_floor" ] || content_floor="$finding_created_at"
    else
      content_floor=$(printf '%s' "$finding" | jq -r '.updated_at // .created_at')
    fi
    # The same-second allowance for the reply a confirmation names holds only
    # at the finding's creation; at a content edit the reply must be strictly
    # later, since a reply in the edit's second may precede the rewrite.
    floor_login="$confirmed_login"
    [ "$content_floor" = "$finding_created_at" ] || floor_login=""
    if agent_reply_after_finding "$root_id" "$content_floor" "$finding_id" "$floor_login"; then
      finding=$(printf '%s' "$finding" | jq -c '.accounted = true | .evidence = "thread-reply"')
    else
      finding=$(printf '%s' "$finding" | jq -c '.accounted = false | .evidence = null')
    fi
  fi
  REFINED_FINDINGS=$(printf '%s\n%s\n' "$REFINED_FINDINGS" "$finding" | jq -cs '.[0] + [.[1]]')
done <<EOF
$(printf '%s' "$FINDINGS" | jq -c '.[]')
EOF
FINDINGS="$REFINED_FINDINGS"

ARCHIVED_CANDIDATES='[]'
append_archive_candidate() {
  local payload="$1" archive_comment_id="$2" archived_at="$3"
  local source_kind source_id source_login source_comments source_comment
  local live_source_login live_source_body_json live_source_fingerprint archive_tiers tier
  local body_fingerprint payload_body_json finding_kind ack_token accounted evidence
  local live_body archived_body

  printf '%s' "$payload" | validate_archive_payload \
    || die 2 "feedback archive payload failed schema validation"
  payload_body_json=""
  if [ "$(printf '%s' "$payload" | jq -r '.archive_version // 1')" -eq 2 ]; then
    payload_body_json=$(printf '%s' "$payload" | jq -c '.body')
    [ "$(fingerprint "$payload_body_json")" = \
      "$(printf '%s' "$payload" | jq -r '.body_fingerprint')" ] \
      || die 2 "feedback archive body fingerprint mismatch"
  elif [ "$(printf '%s' "$payload" | jq -r 'if (.body | type) == "string" then "yes" else "no" end')" = yes ]; then
    # A v1 record may carry its body. Use it only when it is the body the
    # record's fingerprint was taken from, as for v2; a body that does not
    # match (a handoff can be fork-supplied) is ignored and the archived
    # revision is inventoried as if the record carried no body.
    payload_body_json=$(printf '%s' "$payload" | jq -c '.body')
    [ "$(fingerprint "$payload_body_json")" = \
      "$(printf '%s' "$payload" | jq -r '.body_fingerprint')" ] \
      || payload_body_json=""
  fi
  source_kind=$(printf '%s' "$payload" | jq -r '.source_kind')
  source_id=$(printf '%s' "$payload" | jq -r '.source_comment_id')
  source_login=$(printf '%s' "$payload" | jq -r '.source_login')
  body_fingerprint=$(printf '%s' "$payload" | jq -r '.body_fingerprint')
  case "$source_kind" in
    issue-comment)
      case "$source_login" in
        "$CODEX_BOT"|"$CODERABBIT_BOT") ;;
        *) return 0 ;;
      esac
      source_comments="$ISSUE_COMMENTS"
      ;;
    inline)
      case "$source_login" in
        "$CODEX_BOT"|"$CODERABBIT_BOT"|"$GHAS_BOT") ;;
        *) registered_reviewer_login "$source_login" || return 0 ;;
      esac
      source_comments="$INLINE_COMMENTS"
      ;;
    review-body)
      case "$source_login" in
        "$CODEX_BOT"|"$CODERABBIT_BOT") ;;
        *) registered_reviewer_login "$source_login" || return 0 ;;
      esac
      source_comments="$REVIEWS"
      ;;
    *) return 0 ;;
  esac

  source_comment=$(printf '%s' "$source_comments" | jq -c \
    --argjson id "$source_id" 'first(.[] | select(.id == $id)) // null')
  if [ "$source_comment" != null ]; then
    live_source_login=$(printf '%s' "$source_comment" | jq -r '.user.login // ""')
    [ "$live_source_login" = "$source_login" ] || return 0
    live_source_body_json=$(printf '%s' "$source_comment" | jq -c '.body // ""')
    live_source_fingerprint=$(fingerprint "$live_source_body_json")
    [ "$live_source_fingerprint" != "$body_fingerprint" ] || return 0
    # A CodeRabbit acknowledgement is an edit of the finding, so the relay
    # archives the revision being acknowledged. That revision is the same
    # finding, already dispositioned by the reply the acknowledgement
    # answers; demanding a second acknowledgement for it is the archive half
    # of #1167. Compare the two revisions with their trailing footer and
    # confirmation runs removed: equal means the archive adds nothing to
    # disposition, and a changed visible content line still archives.
    if [ "$source_kind" = inline ] && [ "$source_login" = "$CODERABBIT_BOT" ] \
      && [ -n "$payload_body_json" ]; then
      live_body=$(printf '%s' "$source_comment" | jq -r '.body // ""')
      archived_body=$(printf '%s' "$payload_body_json" | jq -r '.')
      [ "$(coderabbit_strip_ack_suffix "$live_body")" != \
        "$(coderabbit_strip_ack_suffix "$archived_body")" ] || return 0
    fi
  fi

  if [ "$source_login" = "$CODERABBIT_BOT" ]; then
    archive_tiers=$(printf '%s' "$payload" | jq -c '.coderabbit_tiers')
  elif [ "$source_login" = "$GHAS_BOT" ]; then
    # Absent on any record archived before #1113 added this field —
    # optional in validate_archive_payload for exactly that reason.
    archive_tiers=$(printf '%s' "$payload" | jq -c '.ghas_tiers // []')
  else
    archive_tiers=$(printf '%s' "$payload" | jq -c '.codex_tiers')
  fi
  tier=$(strongest_nonignored_archive_tier "$archive_tiers")
  [ -n "$tier" ] || return 0

  case "$source_kind" in
    issue-comment)
      finding_kind="issue-comment-archive"
      ack_token="[mergepath-comment-ack: $source_id $body_fingerprint]"
      ;;
    inline)
      finding_kind="inline-archive"
      ack_token="[mergepath-inline-ack: $source_id $body_fingerprint]"
      ;;
    review-body)
      finding_kind="review-body-archive"
      ack_token="[mergepath-review-ack: $source_id $body_fingerprint]"
      ;;
  esac
  accounted=false
  evidence=""
  if ack_present "$ack_token" "$archived_at"; then
    accounted=true
    evidence="comment-ack"
  fi
  ARCHIVED_CANDIDATES=$(printf '%s\n%s\n' "$ARCHIVED_CANDIDATES" "$payload" | jq -cs \
    --arg source_kind "$source_kind" --arg finding_kind "$finding_kind" \
    --argjson source_id "$source_id" \
    --argjson archive_comment_id "$archive_comment_id" \
    --arg source_login "$source_login" \
    --arg tier "$tier" --arg archived_at "$archived_at" \
    --arg fingerprint "$body_fingerprint" --arg token "$ack_token" \
    --arg validated_body_json "$payload_body_json" \
    --argjson accounted "$accounted" --arg evidence "$evidence" '
      .[0] + [(.[1] as $payload | {
        kind: $finding_kind,
        source_kind: $source_kind,
        source_id: $source_id,
        comment_id: (if $source_kind == "review-body" then null else $source_id end),
        review_id: (if $source_kind == "review-body" then $source_id else null end),
        archive_comment_id: $archive_comment_id,
        reviewer: $source_login,
        tier: $tier,
        created_at: $archived_at,
        updated_at: $archived_at,
        body_fingerprint: $fingerprint,
        ack_token: $token,
        body: (if $validated_body_json == "" then ("(archived reviewer " + $source_kind + " version)")
               else ($validated_body_json | fromjson) end),
        accounted: $accounted,
        evidence: (if $evidence == "" then null else $evidence end)
      })]
    ')
}

while IFS= read -r archive_entry; do
  [ -n "$archive_entry" ] || continue
  payload=$(printf '%s' "$archive_entry" | jq -c '.payload')
  archive_comment_id=$(printf '%s' "$archive_entry" | jq -r '.archive_comment_id')
  archived_at=$(printf '%s' "$archive_entry" | jq -r '.archived_at')
  append_archive_candidate "$payload" "$archive_comment_id" "$archived_at"
done <<EOF
$(printf '%s' "$ARCHIVE_ENTRIES" | jq -c '.[]')
EOF

ARCHIVED_CANDIDATES=$(printf '%s' "$ARCHIVED_CANDIDATES" | jq -c '
  sort_by(.source_kind, .source_id, .body_fingerprint, .updated_at, .archive_comment_id)
  | group_by([.source_kind, .source_id, .body_fingerprint])
  | map(last)
')
FINDINGS=$(printf '%s\n%s\n' "$FINDINGS" "$ARCHIVED_CANDIDATES" \
  | jq -cs '.[0] + .[1]')

while IFS= read -r issue_comment; do
  [ -n "$issue_comment" ] || continue
  login=$(printf '%s' "$issue_comment" | jq -r '.user.login // ""')
  case "$login" in
    "$CODEX_BOT"|"$CODERABBIT_BOT") ;;
    *) continue ;;
  esac
  body_json=$(printf '%s' "$issue_comment" | jq -c '.body // ""')
  body=$(printf '%s' "$body_json" | jq -r '.')
  tier=$(strongest_nonignored_finding_tier "$login" "$body")
  [ -n "$tier" ] || continue
  comment_id=$(printf '%s' "$issue_comment" | jq -r '.id')
  raised_at=$(printf '%s' "$issue_comment" | jq -r '.updated_at // .created_at // ""')
  body_fingerprint=$(fingerprint "$body_json")
  ack_token="[mergepath-comment-ack: $comment_id $body_fingerprint]"
  accounted=false
  evidence=""
  if ack_present "$ack_token" "$raised_at"; then
    accounted=true
    evidence="comment-ack"
  fi
  finding=$(printf '%s' "$issue_comment" | jq -c \
    --arg tier "$tier" --arg fingerprint "$body_fingerprint" \
    --arg token "$ack_token" --argjson accounted "$accounted" --arg evidence "$evidence" '
      {
        kind: "issue-comment",
        comment_id: .id,
        reviewer: (.user.login // ""),
        tier: $tier,
        created_at: (.created_at // ""),
        updated_at: (.updated_at // .created_at // ""),
        body_fingerprint: $fingerprint,
        ack_token: $token,
        body: (.body // ""),
        accounted: $accounted,
        evidence: (if $evidence == "" then null else $evidence end)
      }
    ')
  FINDINGS=$(printf '%s\n%s\n' "$FINDINGS" "$finding" | jq -cs '.[0] + [.[1]]')
done <<EOF
$(printf '%s' "$ISSUE_COMMENTS" | jq -c '.[]')
EOF

while IFS= read -r review; do
  [ -n "$review" ] || continue
  login=$(printf '%s' "$review" | jq -r '.user.login // ""')
  case "$login" in
    "$CODEX_BOT"|"$CODERABBIT_BOT") ;;
    *) registered_reviewer_login "$login" || continue ;;
  esac
  # Hash the JSON string encoding rather than a shell command-substitution
  # rendering. Command substitution strips trailing newlines; the JSON form
  # preserves every body byte represented by GitHub, so a same-review edit at
  # the end of the body invalidates the acknowledgement too.
  body_json=$(printf '%s' "$review" | jq -c '.body // ""')
  body=$(printf '%s' "$body_json" | jq -r '.')
  tier=$(strongest_nonignored_finding_tier "$login" "$body")
  [ -n "$tier" ] || continue
  review_id=$(printf '%s' "$review" | jq -r '.id')
  submitted_at=$(printf '%s' "$review" | jq -r '.submitted_at // ""')
  body_fingerprint=$(fingerprint "$body_json")
  # Review submitted_at is immutable across edits. Every trusted archive for
  # this review source proves a later edit, including an intermediate body with
  # a different fingerprint in an A -> B -> A re-raise. Matching the source
  # identity and id prevents an unrelated archive from advancing the floor.
  raised_at=$(printf '%s' "$ARCHIVE_ENTRIES" | jq -r \
    --argjson id "$review_id" --arg login "$login" \
    --arg submitted "$submitted_at" '
      [
        $submitted,
        (
          .[]
          | select((.payload.source_kind // "issue-comment") == "review-body")
          | select(.payload.source_comment_id == $id)
          | select(.payload.source_login == $login)
          | .payload.archived_at
        )
      ]
      | map(select(type == "string" and length > 0))
      | max // $submitted
    ')
  ack_token="[mergepath-review-ack: $review_id $body_fingerprint]"
  accounted=false
  evidence=""
  if ack_present "$ack_token" "$raised_at"; then
    accounted=true
    evidence="review-ack"
  fi
  finding=$(printf '%s' "$review" | jq -c \
    --arg tier "$tier" --arg fingerprint "$body_fingerprint" \
    --arg raised_at "$raised_at" --arg token "$ack_token" \
    --argjson accounted "$accounted" --arg evidence "$evidence" '
      {
        kind: "review-body",
        review_id: .id,
        reviewer: (.user.login // ""),
        tier: $tier,
        created_at: (.submitted_at // ""),
        updated_at: $raised_at,
        commit_id: (.commit_id // null),
        body_fingerprint: $fingerprint,
        ack_token: $token,
        body: (.body // ""),
        accounted: $accounted,
        evidence: (if $evidence == "" then null else $evidence end)
      }
    ')
  FINDINGS=$(printf '%s\n%s\n' "$FINDINGS" "$finding" | jq -cs '.[0] + [.[1]]')
done <<EOF
$(printf '%s' "$REVIEWS" | jq -c '.[]')
EOF

POSTED=$(printf '%s' "$FINDINGS" | jq 'length')
ACCOUNTED=$(printf '%s' "$FINDINGS" | jq '[.[] | select(.accounted == true)] | length')
MISSING_COUNT=$((POSTED - ACCOUNTED))
MISSING=$(printf '%s' "$FINDINGS" | jq -c '[.[] | select(.accounted != true)]')
STATUS=clear
[ "$MISSING_COUNT" -eq 0 ] || STATUS=unaccounted

RESULT=$(printf '%s\n%s\n' "$FINDINGS" "$MISSING" | jq -c -s \
  --arg status "$STATUS" --arg repo "$REPO" --argjson pr "$PR_NUMBER" \
  --argjson posted "$POSTED" --argjson accounted "$ACCOUNTED" \
  --argjson missing_count "$MISSING_COUNT" '
    .[0] as $findings | .[1] as $missing |
    {
      status: $status,
      repo: $repo,
      pr_number: $pr,
      posted: $posted,
      accounted: $accounted,
      missing_count: $missing_count,
      findings: $findings,
      missing: $missing
    }
  ') || die 2 "could not render accounting result"

if [ "$MISSING_COUNT" -gt 0 ]; then
  echo "[review-feedback-accounting] $ACCOUNTED/$POSTED findings accounted; $MISSING_COUNT still undispositioned." >&2
  printf '%s' "$MISSING" | jq -r '
    .[] |
    if .kind == "inline" then
      "  - inline \(.reviewer) \(.tier) finding \(.finding_id) at \(.path):\(.line // "?"): post a substantive disposition reply on the thread"
    elif .kind == "inline-archive" then
      "  - archived inline \(.reviewer) \(.tier) finding from comment \(.comment_id): post a PR comment whose first line is\n      \(.ack_token)\n    with the fix/rebuttal/deferral rationale below it"
    elif .kind == "review-body-archive" then
      "  - archived review-body \(.reviewer) \(.tier) finding from review \(.review_id): post a PR comment whose first line is\n      \(.ack_token)\n    with the fix/rebuttal/deferral rationale below it"
    elif .kind == "review-body" then
      "  - review-body \(.reviewer) \(.tier) finding in review \(.review_id): post a PR comment whose first line is\n      \(.ack_token)\n    with the fix/rebuttal/deferral rationale below it"
    else
      "  - PR-level \(.reviewer) \(.tier) finding in comment \(.comment_id): post a PR comment whose first line is\n      \(.ack_token)\n    with the fix/rebuttal/deferral rationale below it"
    end
  ' >&2
fi

printf '%s\n' "$RESULT"
[ "$MISSING_COUNT" -eq 0 ] || exit 1
exit 0
