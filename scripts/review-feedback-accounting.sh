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
  LOCAL_REPO=""
  ORIGIN_URL=$(git -C "$REPO_ROOT" config --get remote.origin.url 2>/dev/null || true)
  case "$ORIGIN_URL" in
    *github.com:*) LOCAL_REPO=${ORIGIN_URL##*github.com:} ;;
    *github.com/*) LOCAL_REPO=${ORIGIN_URL##*github.com/} ;;
  esac
  LOCAL_REPO=${LOCAL_REPO%.git}
  LOCAL_BRANCH=$(git -C "$REPO_ROOT" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
  ORIGIN_DEFAULT=$(git -C "$REPO_ROOT" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
  ORIGIN_DEFAULT=${ORIGIN_DEFAULT#origin/}
  RESOLVER_ARGS=(--repo "$REPO" --pr "$PR_NUMBER" --default-config "$DEFAULT_CONFIG")
  if [ "$LOCAL_REPO" != "$REPO" ] || [ -z "$ORIGIN_DEFAULT" ] || [ "$LOCAL_BRANCH" != "$ORIGIN_DEFAULT" ]; then
    RESOLVER_ARGS+=(--materialize-default)
  fi
  CONFIG=$(
    "$POLICY_RESOLVER" "${RESOLVER_ARGS[@]}"
  ) || die 2 "could not resolve the review policy governing $REPO#$PR_NUMBER"
  if [ "$CONFIG" != "$DEFAULT_CONFIG" ]; then
    RESOLVED_CONFIG="$CONFIG"
  fi
fi

trap 'if [ -n "$RESOLVED_CONFIG" ]; then rm -f "$RESOLVED_CONFIG"; fi' EXIT

validate_governing_policy() {
  local parsed=""
  [ -r "$CONFIG" ] || die 2 "governing review policy is unreadable: $CONFIG"
  if command -v yq >/dev/null 2>&1; then
    parsed=$(yq eval -o=json '.' "$CONFIG" 2>/dev/null) \
      || die 2 "governing review policy did not parse as YAML: $CONFIG"
  elif command -v python3 >/dev/null 2>&1 \
       && python3 -c 'import yaml' >/dev/null 2>&1; then
    parsed=$(python3 -c '
import json, sys, yaml
with open(sys.argv[1], encoding="utf-8") as source:
    print(json.dumps(yaml.safe_load(source)))
' "$CONFIG" 2>/dev/null) \
      || die 2 "governing review policy did not parse as YAML: $CONFIG"
  elif command -v ruby >/dev/null 2>&1; then
    parsed=$(ruby -ryaml -rjson -e '
value = YAML.safe_load(File.read(ARGV[0]), permitted_classes: [], permitted_symbols: [], aliases: false)
puts JSON.generate(value)
' "$CONFIG" 2>/dev/null) \
      || die 2 "governing review policy did not parse as YAML: $CONFIG"
  else
    die 2 "no YAML parser is available to validate governing review policy: $CONFIG"
  fi
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
    and ((.codex // {}) | optional_string("bot_login"))
    and ((.coderabbit // {}) | optional_string("bot_login"))
    and optional_object("feedback_policy")
    and ((.feedback_policy // {}) | optional_string("mode"))
    and (((.feedback_policy // {}) | has("priorities") | not)
      or (((.feedback_policy // {}).priorities | type == "object")
        and all((.feedback_policy // {}).priorities[]; type == "string")))
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
CR_PRE_MERGE_BLOCK_START='<!-- pre_merge_checks_walkthrough_start -->'
CR_PRE_MERGE_BLOCK_END='<!-- pre_merge_checks_walkthrough_end -->'

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

coderabbit_finding_scan() {
  local out
  out=$(printf '%s\n' "$1" | awk \
    -v block_start="$CR_PRE_MERGE_BLOCK_START" \
    -v block_end="$CR_PRE_MERGE_BLOCK_END" '
      function fence_info(s, out,   c, n) {
        sub(/^ ? ? ?/, "", s)
        c = substr(s, 1, 1)
        if (c != "`" && c != "~") return 0
        n = 0
        while (substr(s, n + 1, 1) == c) n++
        if (n < 3) return 0
        out["rest"] = substr(s, n + 1)
        if (c == "`" && index(out["rest"], "`") > 0) return 0
        out["char"] = c
        out["len"] = n
        return 1
      }
      function fence_update(line,   info) {
        if (!fence_info(line, info)) return 0
        if (!in_fence) {
          in_fence = 1
          fence_char = info["char"]
          fence_len = info["len"]
          return 1
        }
        if (info["char"] == fence_char && info["len"] >= fence_len \
            && info["rest"] ~ /^[ \t]*$/) {
          in_fence = 0
          fence_char = ""
          fence_len = 0
        }
        return 1
      }
      {
        line = $0
        sub(/\r$/, "", line)
        lines[NR] = line
        delimiter = fence_update(line)
        visible[NR] = (!delimiter && !in_fence)
        structural = line
        sub(/[ \t]+$/, "", structural)
        if (visible[NR] && structural == block_start && !start_line) {
          start_line = NR
        } else if (visible[NR] && structural == block_end \
                   && start_line && !end_line) {
          end_line = NR
        }
      }
      END {
        for (i = 1; i <= NR; i++) {
          if (!visible[i]) continue
          if (end_line && i >= start_line && i <= end_line) continue
          print lines[i]
        }
      }
    ') || {
      echo "[review-feedback-accounting] ERROR: could not sanitize a CodeRabbit finding surface" >&2
      return 2
    }
  if [ -n "$out" ]; then
    printf '%s\n' "$out"
  fi
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
  fi
}

INLINE_CANDIDATES='[]'
while IFS= read -r comment; do
  [ -n "$comment" ] || continue
  login=$(printf '%s' "$comment" | jq -r '.user.login // ""')
  case "$login" in
    "$CODEX_BOT"|"$CODERABBIT_BOT") ;;
    *) registered_reviewer_login "$login" || continue ;;
  esac
  body=$(printf '%s' "$comment" | jq -r '.body // ""')
  tier=$(finding_tier "$login" "$body")
  [ -n "$tier" ] || continue
  tier_is_ignored "$tier" && continue
  INLINE_CANDIDATES=$(printf '%s' "$INLINE_CANDIDATES" | jq -c \
    --argjson c "$comment" --arg tier "$tier" '
      . + [{
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
      }]
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
  local root_id="$1" floor="$2"
  printf '%s' "$INLINE_COMMENTS" | jq -e \
    --argjson root "$root_id" --arg floor "$floor" --argjson agents "$AGENT_LOGINS_JSON" '
      any(.[];
        (.in_reply_to_id != null)
        and (.in_reply_to_id == $root)
        and ((.created_at // "") >= $floor)
        and ((.user.login // "") as $login | ($agents | index($login)) != null)
        and (((.body // "") | gsub("\\[mergepath-resolve:[^]]*\\]"; "")
          | gsub("^[[:space:]]+|[[:space:]]+$"; "")
          | gsub("[[:space:]]+"; " ")) as $body
          | (($body | length) >= 12)
          and (([$body | scan("[[:alnum:]][[:alnum:]_-]*")] | length) >= 2)))
    ' >/dev/null 2>&1
}

FINDINGS='[]'
while IFS= read -r finding; do
  [ -n "$finding" ] || continue
  root_id=$(printf '%s' "$finding" | jq -r '.root_id')
  floor=$(printf '%s' "$finding" | jq -r '.updated_at // .created_at')
  accounted=false
  evidence=""
  if agent_reply_after_finding "$root_id" "$floor"; then
    accounted=true
    evidence="thread-reply"
  fi
  FINDINGS=$(printf '%s' "$FINDINGS" | jq -c \
    --argjson f "$finding" --argjson accounted "$accounted" --arg evidence "$evidence" '
      . + [($f + {
        accounted: $accounted,
        evidence: (if $evidence == "" then null else $evidence end)
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
        and ((.created_at // "") >= $raised)
        and (((.body // "") | gsub("\r"; "") | split("\n")) as $lines
          | (($lines[0] // "") | sub("[ \t]+$"; "")) == $token
          and (($lines[1:] | map(gsub("^[ \t]+|[ \t]+$"; ""))
            | map(select(. != "")) | length) > 0)))
    ' >/dev/null 2>&1
}

while IFS= read -r issue_comment; do
  [ -n "$issue_comment" ] || continue
  login=$(printf '%s' "$issue_comment" | jq -r '.user.login // ""')
  case "$login" in
    "$CODEX_BOT"|"$CODERABBIT_BOT") ;;
    *) continue ;;
  esac
  body_json=$(printf '%s' "$issue_comment" | jq -c '.body // ""')
  body=$(printf '%s' "$body_json" | jq -r '.')
  tier=$(finding_tier "$login" "$body")
  [ -n "$tier" ] || continue
  tier_is_ignored "$tier" && continue
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
  FINDINGS=$(printf '%s' "$FINDINGS" | jq -c --argjson f "$finding" '. + [$f]')
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
  tier=$(finding_tier "$login" "$body")
  [ -n "$tier" ] || continue
  tier_is_ignored "$tier" && continue
  review_id=$(printf '%s' "$review" | jq -r '.id')
  submitted_at=$(printf '%s' "$review" | jq -r '.submitted_at // ""')
  body_fingerprint=$(fingerprint "$body_json")
  ack_token="[mergepath-review-ack: $review_id $body_fingerprint]"
  accounted=false
  evidence=""
  if ack_present "$ack_token" "$submitted_at"; then
    accounted=true
    evidence="review-ack"
  fi
  finding=$(printf '%s' "$review" | jq -c \
    --arg tier "$tier" --arg fingerprint "$body_fingerprint" \
    --arg token "$ack_token" --argjson accounted "$accounted" --arg evidence "$evidence" '
      {
        kind: "review-body",
        review_id: .id,
        reviewer: (.user.login // ""),
        tier: $tier,
        created_at: (.submitted_at // ""),
        commit_id: (.commit_id // null),
        body_fingerprint: $fingerprint,
        ack_token: $token,
        body: (.body // ""),
        accounted: $accounted,
        evidence: (if $evidence == "" then null else $evidence end)
      }
    ')
  FINDINGS=$(printf '%s' "$FINDINGS" | jq -c --argjson f "$finding" '. + [$f]')
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
