#!/usr/bin/env bash
set -euo pipefail

# Detect whether a prior Codex affirmative verdict reviewed the same
# external-review-triggering content as the current PR head. This is the
# base-only sync carry-forward used by the labelers and merge gate: a new HEAD
# SHA alone is not enough reason to re-request external review when the
# protected/threshold-triggering content is byte-identical.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG=".github/review-policy.yml"
REPO=""
PR_NUMBER=""
HEAD_SHA=""
BOT_LOGIN="chatgpt-codex-connector[bot]"
CURRENT_FINGERPRINT=""
FILES_JSON_PATH=""

usage() {
  cat >&2 <<'EOF'
usage: external_review_carryforward.sh --repo owner/repo --pr N --head SHA [--current-fingerprint FP] [--files-json path] [--config path] [--bot-login login]
EOF
  exit 2
}

while [ $# -gt 0 ]; do
  case "$1" in
    --repo)
      [ $# -ge 2 ] || usage
      REPO="$2"; shift 2 ;;
    --pr)
      [ $# -ge 2 ] || usage
      PR_NUMBER="$2"; shift 2 ;;
    --head)
      [ $# -ge 2 ] || usage
      HEAD_SHA="$2"; shift 2 ;;
    --current-fingerprint)
      [ $# -ge 2 ] || usage
      CURRENT_FINGERPRINT="$2"; shift 2 ;;
    --files-json)
      [ $# -ge 2 ] || usage
      FILES_JSON_PATH="$2"; shift 2 ;;
    --config)
      [ $# -ge 2 ] || usage
      CONFIG="$2"; shift 2 ;;
    --bot-login)
      [ $# -ge 2 ] || usage
      BOT_LOGIN="$2"; shift 2 ;;
    -h|--help)
      usage ;;
    *)
      echo "external_review_carryforward.sh: unknown arg: $1" >&2
      usage ;;
  esac
done

[ -n "$REPO" ] || usage
[ -n "$PR_NUMBER" ] || usage
[ -n "$HEAD_SHA" ] || usage
[[ "$PR_NUMBER" =~ ^[0-9]+$ ]] || { echo "external_review_carryforward.sh: --pr must be an integer" >&2; exit 2; }
[ -f "$CONFIG" ] || { echo "external_review_carryforward.sh: config not found: $CONFIG" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "external_review_carryforward.sh: jq is required" >&2; exit 2; }

codex_enabled=$(awk '
  /^codex:/ { in_codex = 1; next }
  in_codex && /^[^[:space:]#]/ { in_codex = 0 }
  in_codex && $1 == "enabled:" {
    sub(/^[[:space:]]*enabled:[[:space:]]*/, "", $0)
    sub(/[[:space:]]*#.*$/, "", $0)
    gsub(/^["'\'']|["'\'']$/, "", $0)
    print
    exit
  }
' "$CONFIG")
codex_enabled=${codex_enabled:-true}
if [ "$codex_enabled" = "false" ]; then
  jq -n '{carried:false, reason:"codex.enabled is false; Codex verdict carry-forward is disabled"}'
  exit 0
fi

FINGERPRINT_BIN="$SCRIPT_DIR/external_review_fingerprint.sh"
[ -x "$FINGERPRINT_BIN" ] || { echo "external_review_carryforward.sh: missing executable helper: $FINGERPRINT_BIN" >&2; exit 2; }

# Run a gh invocation with stdout and stderr captured separately, so a
# stderr warning/notice on an otherwise-successful call can't leak into
# the stdout stream that callers parse as JSON with jq (#716). On
# failure, stdout+stderr are combined into the returned text (for the
# caller's error message) and the real gh exit code is preserved — a
# genuine gh failure still fails closed. Same fix applied to
# external_review_fingerprint.sh (#715); kept as a small duplicated
# helper since the two scripts run as separate processes (same pattern
# as fetch_api_array in codex-review-check.sh / codex-review-request.sh).
gh_api_capture() {
  local err_file rc=0 out
  err_file=$(mktemp "${TMPDIR:-/tmp}/external-review-gh-err.XXXXXX") || {
    "$@" 2>&1
    return $?
  }
  out=$("$@" 2>"$err_file") || rc=$?
  if [ "$rc" -ne 0 ]; then
    out="$out
$(cat "$err_file" 2>/dev/null)"
  fi
  rm -f "$err_file"
  printf '%s' "$out"
  return "$rc"
}

TMP_FILES=""
cleanup() {
  [ -z "$TMP_FILES" ] || rm -f "$TMP_FILES"
}
trap cleanup EXIT

if [ -z "$FILES_JSON_PATH" ]; then
  TMP_FILES=$(mktemp "${TMPDIR:-/tmp}/external-review-files.XXXXXX")
  RAW_FILES=$(gh_api_capture gh api --paginate "repos/$REPO/pulls/$PR_NUMBER/files") || {
    echo "external_review_carryforward.sh: failed to fetch PR files: $RAW_FILES" >&2
    exit 2
  }
  printf '%s\n' "$RAW_FILES" | jq -s 'add // []' > "$TMP_FILES" || {
    echo "external_review_carryforward.sh: failed to flatten PR files pagination" >&2
    exit 2
  }
  FILES_JSON_PATH="$TMP_FILES"
fi

if [ -z "$CURRENT_FINGERPRINT" ]; then
  CURRENT_JSON=$(bash "$FINGERPRINT_BIN" --repo "$REPO" --pr "$PR_NUMBER" --ref "$HEAD_SHA" --config "$CONFIG" --files-json "$FILES_JSON_PATH")
  CURRENT_FINGERPRINT=$(printf '%s' "$CURRENT_JSON" | jq -r '.fingerprint // ""')
fi

if [ -z "$CURRENT_FINGERPRINT" ]; then
  jq -n '{carried:false, reason:"current PR does not require external review or has no fingerprint"}'
  exit 0
fi

COMMENTS_JSON=$(gh_api_capture gh api --paginate "repos/$REPO/issues/$PR_NUMBER/comments") || {
  echo "external_review_carryforward.sh: failed to fetch issue comments: $COMMENTS_JSON" >&2
  exit 2
}
COMMENTS_JSON=$(printf '%s\n' "$COMMENTS_JSON" | jq -s 'add // []') || {
  echo "external_review_carryforward.sh: failed to flatten issue comments pagination" >&2
  exit 2
}

REVIEWS_JSON=$(gh_api_capture gh api --paginate "repos/$REPO/pulls/$PR_NUMBER/reviews") || {
  echo "external_review_carryforward.sh: failed to fetch reviews: $REVIEWS_JSON" >&2
  exit 2
}
REVIEWS_JSON=$(printf '%s\n' "$REVIEWS_JSON" | jq -s 'add // []') || {
  echo "external_review_carryforward.sh: failed to flatten reviews pagination" >&2
  exit 2
}

HEAD_LC=$(printf '%s' "$HEAD_SHA" | tr '[:upper:]' '[:lower:]')
CURRENT_SIGNAL=$(jq -n -c \
  --arg bot "$BOT_LOGIN" \
  --arg head "$HEAD_LC" \
  --argjson comments "$COMMENTS_JSON" \
  --argjson reviews "$REVIEWS_JSON" '
  def verdict_shas($body):
    [ $body
      | ascii_downcase
      | scan("reviewed commit[^0-9a-f]{0,6}([0-9a-f]{7,40})")
      | .[0]
    ];
  ([
    $comments[]
    | select(.user.login == $bot)
    | . as $c
    | verdict_shas($c.body)[] as $sha
    | select($head | startswith($sha))
    | {
        kind: "verdict",
        time: ($c.created_at // ""),
        affirmative: ($c.body | test("(?im)^\\s*codex review:\\s*didn.?t find any major issues\\b"))
      }
  ] + [
    $reviews[]
    | select(.user.login == $bot)
    | ((.commit_id // "") | ascii_downcase) as $sha
    | select($sha != "" and ($head == $sha or ($head | startswith($sha))))
    | {kind: "review", time: (.submitted_at // ""), affirmative: false}
  ])
  | map(select(.time != ""))
  | sort_by(.time)
  | last // empty
')

if [ -n "$CURRENT_SIGNAL" ]; then
  current_kind=$(printf '%s' "$CURRENT_SIGNAL" | jq -r '.kind')
  current_time=$(printf '%s' "$CURRENT_SIGNAL" | jq -r '.time')
  current_affirmative=$(printf '%s' "$CURRENT_SIGNAL" | jq -r '.affirmative | tostring')
  if [ "$current_affirmative" != "true" ]; then
    jq -n \
      --arg kind "$current_kind" \
      --arg time "$current_time" \
      '{carried:false, reason:"current-head Codex signal exists and must not be overridden by carry-forward", current_signal:{kind:$kind, time:$time}}'
    exit 0
  fi
  # (#718) The current HEAD already carries a direct affirmative Codex
  # signal — callers already prefer that over a carry-forward result
  # (see codex-review-check.sh's latest-signal-wins comment), so there is
  # nothing for the historical-candidate scan below to add. Return early
  # instead of paying for the candidate + newer-signal fingerprint scan.
  jq -n \
    --arg kind "$current_kind" \
    --arg time "$current_time" \
    '{carried:false, reason:"current-head Codex signal is already affirmative; carry-forward scan skipped", current_signal:{kind:$kind, time:$time}}'
  exit 0
fi

CANDIDATES=$(printf '%s' "$COMMENTS_JSON" | jq -r \
  --arg bot "$BOT_LOGIN" '
  [ .[]
    | select(.user.login == $bot)
    | select(.body | test("(?im)^\\s*codex review:\\s*didn.?t find any major issues\\b"))
    | . as $c
    | [ $c.body
        | ascii_downcase
        | scan("reviewed commit[^0-9a-f]{0,6}([0-9a-f]{7,40})")
        | .[0]
      ] as $shas
    | $shas[]
    | {time: $c.created_at, sha: .}
  ]
  | sort_by(.time)
  | reverse
  | .[]
  | [.time, .sha]
  | @tsv
')

if [ -z "$CANDIDATES" ]; then
  jq -n '{carried:false, reason:"no affirmative Codex verdict comments with Reviewed commit anchors"}'
  exit 0
fi

while IFS=$'\t' read -r source_time source_sha; do
  [ -n "$source_sha" ] || continue
  resolved_sha=""
  source_lc=$(printf '%s' "$source_sha" | tr '[:upper:]' '[:lower:]')
  case "$HEAD_LC" in
    "$source_lc"*) resolved_sha="$HEAD_SHA" ;;
  esac
  if [ -z "$resolved_sha" ]; then
    resolved_sha=$(gh api "repos/$REPO/commits/$source_sha" --jq .sha 2>/dev/null || true)
  fi
  [ -n "$resolved_sha" ] || continue

  resolved_lc=$(printf '%s' "$resolved_sha" | tr '[:upper:]' '[:lower:]')
  NEWER_SOURCE_SIGNAL=$(jq -n -c \
    --arg bot "$BOT_LOGIN" \
    --arg resolved "$resolved_lc" \
    --arg source_time "$source_time" \
    --argjson comments "$COMMENTS_JSON" \
    --argjson reviews "$REVIEWS_JSON" '
    def verdict_shas($body):
      [ $body
        | ascii_downcase
        | scan("reviewed commit[^0-9a-f]{0,6}([0-9a-f]{7,40})")
        | .[0]
      ];
    ([
      $comments[]
      | select(.user.login == $bot)
      | . as $c
      | verdict_shas($c.body)[] as $sha
      | select($resolved | startswith($sha))
      | {
          kind: "verdict",
          time: ($c.created_at // ""),
          affirmative: ($c.body | test("(?im)^\\s*codex review:\\s*didn.?t find any major issues\\b"))
        }
    ] + [
      $reviews[]
      | select(.user.login == $bot)
      | ((.commit_id // "") | ascii_downcase) as $sha
      | select($sha != "" and ($resolved == $sha or ($resolved | startswith($sha))))
      | {kind: "review", time: (.submitted_at // ""), affirmative: false}
    ])
    | map(select(.time != "" and .time > $source_time))
    | sort_by(.time)
    | last // empty
  ')
  if [ -n "$NEWER_SOURCE_SIGNAL" ]; then
    continue
  fi

  NEWER_SIGNALS=$(jq -n -r \
    --arg bot "$BOT_LOGIN" \
    --arg source_time "$source_time" \
    --argjson comments "$COMMENTS_JSON" \
    --argjson reviews "$REVIEWS_JSON" '
    def verdict_shas($body):
      [ $body
        | ascii_downcase
        | scan("reviewed commit[^0-9a-f]{0,6}([0-9a-f]{7,40})")
        | .[0]
      ];
    ([
      $comments[]
      | select(.user.login == $bot)
      | . as $c
      | verdict_shas($c.body)[] as $sha
      | {
          kind: "verdict",
          time: ($c.created_at // ""),
          sha: $sha,
          affirmative: ($c.body | test("(?im)^\\s*codex review:\\s*didn.?t find any major issues\\b"))
        }
    ] + [
      $reviews[]
      | select(.user.login == $bot)
      | {kind: "review", time: (.submitted_at // ""), sha: (.commit_id // ""), affirmative: false}
    ])
    | map(select(.time != "" and .sha != "" and .time > $source_time and .affirmative != true))
    | sort_by(.time)
    | reverse
    | .[]
    | [.time, .sha, .kind]
    | @tsv
  ')
  blocked_by_newer_same_fingerprint=false
  while IFS=$'\t' read -r signal_time signal_sha signal_kind; do
    [ -n "$signal_sha" ] || continue
    signal_resolved=""
    signal_lc=$(printf '%s' "$signal_sha" | tr '[:upper:]' '[:lower:]')
    case "$HEAD_LC" in
      "$signal_lc"*) signal_resolved="$HEAD_SHA" ;;
    esac
    if [ -z "$signal_resolved" ]; then
      signal_resolved=$(gh api "repos/$REPO/commits/$signal_sha" --jq .sha 2>/dev/null || true)
    fi
    if [ -z "$signal_resolved" ]; then
      echo "external_review_carryforward.sh: newer $signal_kind Codex signal at $signal_time references unresolvable commit $signal_sha; refusing carry-forward" >&2
      exit 2
    fi

    set +e
    SIGNAL_JSON=$(bash "$FINGERPRINT_BIN" --repo "$REPO" --pr "$PR_NUMBER" --ref "$signal_resolved" --config "$CONFIG" --files-json "$FILES_JSON_PATH" 2>/dev/null)
    signal_fp_rc=$?
    set -e
    if [ "$signal_fp_rc" -ne 0 ]; then
      echo "external_review_carryforward.sh: failed to fingerprint newer $signal_kind Codex signal at $signal_time on $signal_resolved; refusing carry-forward" >&2
      exit 2
    fi
    SIGNAL_FINGERPRINT=$(printf '%s' "$SIGNAL_JSON" | jq -r '.fingerprint // ""')
    if [ -z "$SIGNAL_FINGERPRINT" ]; then
      echo "external_review_carryforward.sh: newer $signal_kind Codex signal at $signal_time produced no fingerprint; refusing carry-forward" >&2
      exit 2
    fi
    if [ "$SIGNAL_FINGERPRINT" = "$CURRENT_FINGERPRINT" ]; then
      blocked_by_newer_same_fingerprint=true
      break
    fi
  done <<<"$NEWER_SIGNALS"
  if [ "$blocked_by_newer_same_fingerprint" = "true" ]; then
    continue
  fi

  set +e
  SOURCE_JSON=$(bash "$FINGERPRINT_BIN" --repo "$REPO" --pr "$PR_NUMBER" --ref "$resolved_sha" --config "$CONFIG" --files-json "$FILES_JSON_PATH" 2>/dev/null)
  fp_rc=$?
  set -e
  [ "$fp_rc" -eq 0 ] || continue
  SOURCE_FINGERPRINT=$(printf '%s' "$SOURCE_JSON" | jq -r '.fingerprint // ""')
  if [ "$SOURCE_FINGERPRINT" = "$CURRENT_FINGERPRINT" ]; then
    jq -n \
      --arg kind "codex-verdict" \
      --arg source_commit "$resolved_sha" \
      --arg source_time "$source_time" \
      --arg fingerprint "$CURRENT_FINGERPRINT" \
      '{carried:true, kind:$kind, source_commit:$source_commit, source_time:$source_time, fingerprint:$fingerprint}'
    exit 0
  fi
done <<<"$CANDIDATES"

jq -n --arg fingerprint "$CURRENT_FINGERPRINT" '{carried:false, reason:"no prior affirmative Codex verdict matched the current external-review fingerprint", fingerprint:$fingerprint}'
