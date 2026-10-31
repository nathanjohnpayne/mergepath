#!/usr/bin/env bash
# Regression coverage for codex-review-request.sh's Phase 4a entry
# decision (#486): codex.request_by_default + codex.enabled gating of
# whether an `@codex review` trigger is posted at all, including the #2240
# default (unset means false; an unreadable policy requests with a warning;
# a Phase-4a-gated PR is always requested). It also locks the
# #1085 handoff contract: a real, confirmed request that reaches the ordinary
# timeout path must leave a durable exact-head terminal marker for Phase 4b.
#
# Runs the real script from a temp repo with stubbed gh + gh-as-author so
# the tests exercise the production entry-gate without touching GitHub.
# Skip cases (exit 5) still read the governing entry policy, then stop before
# review polling or comment writes. Every API call remains fixture-only.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export MERGEPATH_REVIEW_FEEDBACK_ACCOUNTING_CMD=true

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/codex-review-request-entry.XXXXXX")"
trap 'rm -rf "$WORKDIR"' EXIT
# The requester counts solicited blocking reviews from the Codex review ledger
# before every new request (#1560 slice 3). This stub reports a ledger with no
# responses for whatever head the requester expects, so the blocking-review
# budget never stops these cases; test_codex_review_request_trigger_only.sh
# covers the budget itself.
LEDGER_STUB="$WORKDIR/codex-ledger-stub.sh"
cat >"$LEDGER_STUB" <<'LEDGER_EOF'
#!/usr/bin/env bash
head=""
while [ $# -gt 0 ]; do
  case "$1" in --expect-head) head=$2; shift 2 ;; --expect-policy) fp=$2; shift 2 ;; *) shift ;; esac
done
jq -nc --arg h "$head" --arg fp "${fp:-}" --arg a "${CODEX_LEDGER_STUB_AUTHOR:-nathanjohnpayne}" \
  '{head_sha: $h, author: $a, max_blocking_reviews: 10, policy_fingerprint: $fp, responses: []}'
LEDGER_EOF
chmod +x "$LEDGER_STUB"
export MERGEPATH_CODEX_LEDGER_CMD="$LEDGER_STUB"

PASS=0
FAIL=0
TEST_HEAD=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
pass() { echo "PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $*" >&2; FAIL=$((FAIL + 1)); }

# Build a case directory with a review-policy.yml whose codex: block is
# exactly the lines passed as $2 (a newline-joined string of "  key: val"
# entries), and stubbed gh / gh-as-author. The gh stub always reports a
# HEAD with no Codex signal so a posted trigger times out (exit 4) and a
# skip is unambiguously exit 5.
make_case() {
  local name=$1
  local codex_block=$2
  local dir="$WORKDIR/$name"

  mkdir -p "$dir/scripts" "$dir/scripts/lib" "$dir/scripts/workflow" "$dir/.github" "$dir/bin" "$dir/state"
  cp "$ROOT/scripts/codex-review-request.sh" "$dir/scripts/codex-review-request.sh"
  chmod +x "$dir/scripts/codex-review-request.sh"
  cp "$ROOT/scripts/lib/codex-failure-markers.sh" "$dir/scripts/lib/codex-failure-markers.sh"
  cp "$ROOT/scripts/lib/gh-api-scalar.sh" "$dir/scripts/lib/gh-api-scalar.sh"   # #799, hard-sourced
  cp "$ROOT/scripts/lib/gh-api-array.sh" "$dir/scripts/lib/gh-api-array.sh"     # #1008, hard-sourced
  cp "$ROOT/scripts/lib/codex-request-evidence.sh" "$dir/scripts/lib/codex-request-evidence.sh"
  mkdir -p "$dir/scripts/workflow"
  cp "$ROOT/scripts/workflow/resolve-codex-verdict-anchors.py" "$dir/scripts/workflow/resolve-codex-verdict-anchors.py"
  cp "$ROOT/scripts/lib/feedback-policy-helpers.sh" "$dir/scripts/lib/feedback-policy-helpers.sh"
  cp "$ROOT/scripts/workflow/resolve_base_policy.sh" "$dir/scripts/workflow/resolve_base_policy.sh"
  # #2257: the Phase 4 gate derivation reads the parser, the matcher and the
  # fingerprint helper's EXCLUDE_RE AT THE BASE, which the gh stub serves from
  # state/.
  cp "$ROOT/scripts/workflow/match_protected_paths.sh" "$dir/state/base-matcher.sh"
  cp "$ROOT/scripts/workflow/parse_policy_list.sh" "$dir/state/base-parser.sh"
  cp "$ROOT/scripts/workflow/external_review_fingerprint.sh" "$dir/state/base-fingerprint.sh"
  # #2272: the parser and matcher that RUN are the requester's own copies,
  # and only when byte-identical to the base copies the stub serves.
  cp "$ROOT/scripts/workflow/match_protected_paths.sh" "$dir/scripts/workflow/match_protected_paths.sh"
  cp "$ROOT/scripts/workflow/parse_policy_list.sh" "$dir/scripts/workflow/parse_policy_list.sh"
  chmod +x "$dir/scripts/workflow/resolve_base_policy.sh"

  {
    printf 'codex:\n'
    printf '%s\n' "$codex_block"
    # Zero review timeout so a posted trigger reaches the deadline
    # immediately and the case finishes fast (still exits 4, not 0).
    printf '  review_timeout_seconds: 0\n'
    printf '  reaction_freshness_window_seconds: 999999999\n'
    printf '  ack_wait_seconds: 0\n'
    printf '  max_ack_retries: 0\n'
  } >"$dir/.github/review-policy.yml"
  {
    printf 'author_identity: nathanjohnpayne\ncodex:\n'
    printf '%s\n' "$codex_block"
    printf '  bot_login: "chatgpt-codex-connector[bot]"\n  max_review_rounds: 10\n'
  } >"$dir/state/base-review-policy.yml"

  # gh-as-author records triggers and Phase 4a terminal markers separately.
  # The real wrapper receives either --body or --body-file after `--`.
  cat >"$dir/scripts/gh-as-author.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
state_dir=${CODEX_TEST_STATE_DIR:?}
body=''
while [ $# -gt 0 ]; do
  case "$1" in
    --body) body=${2-}; shift 2 ;;
    --body-file)
      body=$(cat "${2-}"; printf x)
      body=${body%x}
      shift 2
      ;;
    *) shift ;;
  esac
done
case "$body" in
  '@codex review') kind=trigger ;;
  '<!-- mergepath-phase-4a-terminal:'*) kind=terminal ;;
  *) echo "unexpected author comment body: $body" >&2; exit 98 ;;
esac
count=0
[ -f "$state_dir/$kind-count" ] && count=$(cat "$state_dir/$kind-count")
count=$((count + 1))
printf '%s\n' "$count" >"$state_dir/$kind-count"
printf '%s\n' "$body" >"$state_dir/$kind-body"
post_count=0
[ -f "$state_dir/post-count" ] && post_count=$(cat "$state_dir/post-count")
post_count=$((post_count + 1))
printf '%s\n' "$post_count" >"$state_dir/post-count"
comment_id=$((1000 + post_count))
jq -cn --argjson id "$comment_id" --arg body "$body" --arg created "2026-06-17T00:00:0${post_count}Z" \
  '{id:$id,user:{login:"nathanjohnpayne"},body:$body,created_at:$created}' >>"$state_dir/comments.jsonl"
printf 'https://github.com/owner/repo/pull/999#issuecomment-%s\n' "$comment_id"
EOF
  chmod +x "$dir/scripts/gh-as-author.sh"

  cat >"$dir/bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
now='2026-06-17T00:00:00Z'
[ "${1:-}" = "api" ] || { echo "unexpected gh command: $*" >&2; exit 99; }
shift
[ "${1:-}" = "--paginate" ] && shift
endpoint=${1:-}
case "$endpoint" in
  repos/owner/repo/pulls/999)
    # #2240: a case with no policy file runs on the script's default
    # timings (an 1800s poll), so it ends the run at the first read past
    # the entry decision instead. Reaching this read at all proves the
    # decision was to request. CODEX_TEST_FAIL_PR_FETCH=N refuses the Nth
    # metadata read: 1 for a decision that reads nothing, 3 when the #2257
    # derivation reads the metadata and re-reads the head inside it.
    # Read zero materializes the governing entry policy (#2273). Existing
    # derivation/failure controls count the reads after that authority lookup.
    n=-1
    [ -f "$CODEX_TEST_STATE_DIR/pr-fetch-count" ] && n=$(cat "$CODEX_TEST_STATE_DIR/pr-fetch-count")
    n=$((n + 1))
    printf '%s\n' "$n" >"$CODEX_TEST_STATE_DIR/pr-fetch-count"
    if [ -n "${CODEX_TEST_FAIL_PR_FETCH:-}" ] && [ "$n" -ge "$CODEX_TEST_FAIL_PR_FETCH" ]; then
      echo "stub: PR fetch refused after the entry decision" >&2
      exit 1
    fi
    if [ "${CODEX_TEST_PR_META:-ok}" = fail ]; then
      echo "stub: PR metadata read refused" >&2
      exit 1
    fi
    if [ "${2:-}" = "--jq" ]; then
      printf '%s\n' "${CODEX_TEST_LIVE_HEAD:-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa}"
    elif [ "$n" -ge 2 ] && [ "${CODEX_TEST_FENCE_MODE:-}" = garbage ]; then
      # #2257: the snapshot-fence re-read (the 2nd metadata read) is unreadable.
      printf 'not json\n'
    else
      # #2257: labels and changed_files feed the Phase 4 gate derivation.
      # CODEX_TEST_FENCE_MODE changes the PR from the 2nd metadata read on,
      # i.e. between the derivation's snapshot and its fence re-read.
      fence=""
      [ "$n" -ge 2 ] && fence="${CODEX_TEST_FENCE_MODE:-}"
      jq -cn --argjson labels "${CODEX_TEST_PR_LABELS:-[]}" \
        --argjson changed "${CODEX_TEST_PR_CHANGED_FILES:-1}" \
        --arg mode "${CODEX_TEST_PR_META:-ok}" --arg fence "$fence" '
        {head:{sha:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},base:{ref:"main",sha:"base-sha",repo:{default_branch:"main"}},
         labels:$labels, changed_files:$changed}
        | if $mode == "no-labels" then del(.labels)
          elif $mode == "no-changed-files" then del(.changed_files)
          elif $mode == "no-base" then del(.base)
          else . end
        | if $fence == "head-moved" then .head.sha = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
          elif $fence == "base-moved" then .base.sha = "base-sha-2"
          elif $fence == "label-added" then .labels += [{name: "needs-external-review"}]
          elif $fence == "default-moved" then .base.repo.default_branch = "trunk"
          else . end'
    fi ;;
  repos/owner/repo/pulls/999/files)
    # #2257: the paginated file list for the Phase 4 gate derivation.
    printf 'files\n' >>"$CODEX_TEST_STATE_DIR/files-reads"
    if [ "${CODEX_TEST_FILES:-ok}" = fail ]; then
      echo "stub: PR files read refused" >&2
      exit 1
    fi
    default_files='[{"filename":"src/app.ts","additions":10,"deletions":2}]'
    # A list too large for one environment variable (Linux caps a single
    # env string at 128 KiB) comes from a file instead.
    if [ -n "${CODEX_TEST_FILES_JSON_FILE:-}" ]; then cat "$CODEX_TEST_FILES_JSON_FILE"
    else printf '%s\n' "${CODEX_TEST_FILES_JSON:-$default_files}"; fi ;;
  'repos/owner/repo/contents/scripts/workflow/match_protected_paths.sh?ref=base-sha')
    # #2257: the protected-path matcher at the base.
    case "${CODEX_TEST_BASE_MATCHER:-ok}" in
      fail) echo "stub: base matcher read refused" >&2; exit 1 ;;
      broken) content=$(printf '#!/usr/bin/env bash\nexit 2\n' | base64 | tr -d '\n') ;;
      *) content=$(base64 <"$CODEX_TEST_STATE_DIR/base-matcher.sh" | tr -d '\n') ;;
    esac
    jq -cn --arg c "$content" '{encoding: "base64", content: $c}' ;;
  'repos/owner/repo/contents/scripts/workflow/parse_policy_list.sh?ref=base-sha')
    # #2257: the labeler's policy list parser at the base.
    case "${CODEX_TEST_BASE_PARSER:-ok}" in
      fail) echo "stub: base parser read refused" >&2; exit 1 ;;
      broken) content=$(printf '#!/usr/bin/env bash\nexit 3\n' | base64 | tr -d '\n') ;;
      *) content=$(base64 <"$CODEX_TEST_STATE_DIR/base-parser.sh" | tr -d '\n') ;;
    esac
    jq -cn --arg c "$content" '{encoding: "base64", content: $c}' ;;
  repos/owner/repo/branches/main)
    # #2257: the default branch's head, pinned before the policy read and
    # re-read by the fence. CODEX_TEST_DEFAULT_MODE=advanced moves it on the
    # second read; =fail refuses every read.
    d=0
    [ -f "$CODEX_TEST_STATE_DIR/default-reads" ] && d=$(cat "$CODEX_TEST_STATE_DIR/default-reads")
    d=$((d + 1))
    printf '%s\n' "$d" >"$CODEX_TEST_STATE_DIR/default-reads"
    case "${CODEX_TEST_DEFAULT_MODE:-ok}" in
      fail) echo "stub: branch read refused" >&2; exit 1 ;;
      advanced) [ "$d" -ge 2 ] && sha=main-sha-2 || sha=main-sha-1 ;;
      *) sha=main-sha-1 ;;
    esac
    jq -cn --arg s "$sha" '{name: "main", commit: {sha: $s}}' ;;
  'repos/owner/repo/contents/scripts/workflow/external_review_fingerprint.sh?ref=base-sha')
    # #2257: the fingerprint helper at the base, for its EXCLUDE_RE constant.
    case "${CODEX_TEST_BASE_HELPER:-ok}" in
      fail) echo "stub: base helper read refused" >&2; exit 1 ;;
      noexclude) content=$(grep -v '^EXCLUDE_RE=' "$CODEX_TEST_STATE_DIR/base-fingerprint.sh" | base64 | tr -d '\n') ;;
      *) content=$(base64 <"$CODEX_TEST_STATE_DIR/base-fingerprint.sh" | tr -d '\n') ;;
    esac
    jq -cn --arg c "$content" '{encoding: "base64", content: $c}' ;;
  'repos/owner/repo/contents/.github/review-policy.yml?ref=base-sha')
    if [ "${CODEX_TEST_BASE_POLICY:-ok}" = fail ]; then
      echo "stub: base policy read refused" >&2
      exit 1
    fi
    cat "$CODEX_TEST_STATE_DIR/base-review-policy.yml" ;;
  repos/owner/repo/commits/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa) printf '%s\n' "$now" ;;
  repos/owner/repo/issues/999/timeline)      printf '[]\n' ;;
  # #2664: the same-head hold's force-push read; no force-push here.
  graphql) printf '%s\n' '{"data":{"repository":{"pullRequest":{"timelineItems":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[]}}}}}' ;;
  repos/owner/repo/pulls/999/reviews)        printf '[]\n' ;;
  repos/owner/repo/pulls/999/comments)       printf '[]\n' ;;
  repos/owner/repo/issues/999/reactions)     printf '[]\n' ;;
  repos/owner/repo/issues/999/comments)
    if [ -f "${CODEX_TEST_STATE_DIR:?}/comments.jsonl" ]; then
      jq -sc '.' "${CODEX_TEST_STATE_DIR:?}/comments.jsonl"
    else
      printf '[]\n'
    fi ;;
  repos/owner/repo/issues/comments/*/reactions) printf '[]\n' ;;
  repos/owner/repo/issues/comments/*)        printf '%s\n' "$now" ;;
  *) echo "unexpected gh api endpoint: $endpoint" >&2; exit 99 ;;
esac
EOF
  chmod +x "$dir/bin/gh"

  printf '%s\n' "$dir"
}

# Run a case; echoes the exit code. $3 = MERGEPATH_PHASE_4A_GATED value.
run_case() {
  local dir=$1
  local gated=${2:-}
  local live_head=${3:-$TEST_HEAD}
  local rc=0
  (
    cd "$dir"
    PATH="$dir/bin:$PATH" \
      GH_TOKEN="test-token" \
      CODEX_TEST_STATE_DIR="$dir/state" \
      CODEX_TEST_LIVE_HEAD="$live_head" \
      MERGEPATH_PHASE_4A_GATED="$gated" \
      ./scripts/codex-review-request.sh 999 owner/repo \
      >"$dir/out.json" 2>"$dir/err.log"
  ) || rc=$?
  printf '%s\n' "$rc"
}

trigger_count() {
  local dir=$1
  [ -f "$dir/state/trigger-count" ] && cat "$dir/state/trigger-count" || printf '0\n'
}

terminal_count() {
  local dir=$1
  [ -f "$dir/state/terminal-count" ] && cat "$dir/state/terminal-count" || printf '0\n'
}

terminal_body() {
  local dir=$1
  [ -f "$dir/state/terminal-body" ] && cat "$dir/state/terminal-body" || true
}

# #2273: a real checkout for another repository must not decide the target's
# entry switches. All API and comment writes remain fake fixture operations.
test_target_entry_policy() {
  local name=$1 local_enabled=$2 local_default=$3 target_enabled=$4 target_default=$5 gated=$6 expected=$7 posts=$8
  local dir rc
  dir=$(make_case "target-entry-$name" "  enabled: $local_enabled"$'\n'"  request_by_default: $local_default")
  git -C "$dir" init -q
  git -C "$dir" remote add origin https://github.com/other/checkout.git
  printf 'author_identity: nathanjohnpayne\ncodex:\n  enabled: %s\n  request_by_default: %s\n  max_review_rounds: 10\n' \
    "$target_enabled" "$target_default" > "$dir/state/base-review-policy.yml"
  rc=$(run_case "$dir" "$gated")
  if [ "$rc" = "$expected" ] && [ "$(trigger_count "$dir")" = "$posts" ]; then
    pass "#2273 $name: target policy governs a foreign checkout"
  else
    fail "#2273 $name: expected rc=$expected/posts=$posts, got rc=$rc/posts=$(trigger_count "$dir"): $(cat "$dir/err.log")"
  fi
}
test_target_entry_policy enabled-target-on false true true true true 4 1
test_target_entry_policy enabled-target-off true true false true true 5 0
test_target_entry_policy default-target-on true false true true '' 4 1
test_target_entry_policy default-target-off true true true false '' 5 0

# --- defaults: absent keys on a gated PR ⇒ trigger + durable timeout ------
# Absent enabled/request_by_default on a Phase-4a-gated PR: the request is
# made (the gate does not depend on request_by_default, #2240) and its
# ordinary timeout is durably head-pinned for Phase 4b (#1085).
test_defaults_request_on_gated_pr() {
  local dir rc count requested terminals body expected
  dir=$(make_case "defaults" "  bot_login: \"chatgpt-codex-connector[bot]\"")
  rc=$(run_case "$dir" true)
  count=$(trigger_count "$dir")
  terminals=$(terminal_count "$dir")
  body=$(terminal_body "$dir")
  expected="<!-- mergepath-phase-4a-terminal:v1 provider=codex outcome=timeout head=$TEST_HEAD trigger_comment_id=1001 -->"
  requested=$(jq -r '.trigger_requested' "$dir/out.json")
  if [ "$rc" != "4" ]; then
    fail "defaults: exit $rc, expected 4 (trigger posted, then timeout); stderr=$(cat "$dir/err.log")"
  elif [ "$count" != "1" ]; then
    fail "defaults: trigger count $count, expected 1"
  elif [ "$requested" != "true" ]; then
    fail "defaults: trigger_requested=$requested, expected true"
  elif [ "$terminals" != "1" ]; then
    fail "defaults: terminal marker count $terminals, expected 1 after a confirmed ordinary timeout (#1085)"
  elif [ "$body" != "$expected" ]; then
    fail "defaults: terminal marker body '$body', expected '$expected'"
  else
    pass "absent enabled/request_by_default on a gated PR ⇒ trigger posted and ordinary timeout is durably head-pinned for Phase 4b (#1085)"
  fi
}

# --- request_by_default unset + not gated ⇒ skip (the #2240 default) --------
test_request_by_default_unset_skips_under_threshold() {
  local dir rc count requested
  dir=$(make_case "rbd-unset" "  enabled: true")
  rc=$(run_case "$dir" false)
  count=$(trigger_count "$dir")
  requested=$(jq -r '.trigger_requested' "$dir/out.json" 2>/dev/null || echo unreadable)
  if [ "$rc" != "5" ]; then
    fail "rbd unset ungated: exit $rc, expected 5 (NO_TRIGGER_REQUESTED, the #2240 default); stderr=$(cat "$dir/err.log")"
  elif [ "$count" != "0" ]; then
    fail "rbd unset ungated: trigger count $count, expected 0"
  elif [ "$requested" != "false" ]; then
    fail "rbd unset ungated: trigger_requested=$requested, expected false"
  elif ! grep -q 'codex.request_by_default is not set (the default is false since #2240)' "$dir/err.log"; then
    fail "rbd unset ungated: the skip must say the key is unset and defaults to false; stderr=$(cat "$dir/err.log")"
  elif grep -q 'WARN: cannot read codex.request_by_default' "$dir/err.log"; then
    fail "rbd unset ungated: a readable policy with the key absent must not warn; stderr=$(cat "$dir/err.log")"
  else
    pass "request_by_default unset + under-threshold ⇒ skip with exit 5 (#2240 default false)"
  fi
}

# --- request_by_default: true ⇒ under-threshold PR still triggers -----------
test_request_by_default_true_triggers_under_threshold() {
  local dir rc count
  dir=$(make_case "rbd-true" "  enabled: true"$'\n'"  request_by_default: true")
  # Not gated (under threshold).
  rc=$(run_case "$dir" false)
  count=$(trigger_count "$dir")
  if [ "$rc" != "4" ]; then
    fail "rbd true: exit $rc, expected 4 (trigger posted, then timeout); stderr=$(cat "$dir/err.log")"
  elif [ "$count" != "1" ]; then
    fail "rbd true: trigger count $count, expected 1"
  elif grep -q 'WARN: cannot read codex.request_by_default' "$dir/err.log"; then
    fail "rbd true: an explicit boolean must be read cleanly, not through the fail-safe; stderr=$(cat "$dir/err.log")"
  else
    pass "request_by_default:true ⇒ under-threshold PR gets a trigger"
  fi
}

# --- unreadable request_by_default ⇒ request, with a warning naming why -----
# #2240: an unreadable policy never opts out. Each shape must choose a request
# on an UNGATED PR and warn with its cause. Stop before the write-budget fence
# independently refuses an invalid governing policy. Args: <case> <cause> <block>
# [extra top-level YAML appended after the codex: block] [both|base: where the
# extra goes; default both].
assert_unreadable_requests() {
  local name=$1 cause=$2 block=$3 extra=${4:-} where=${5:-both} dir rc count
  dir=$(make_case "rbd-$name" "$block")
  if [ -n "$extra" ]; then
    [ "$where" = base ] || printf '%s\n' "$extra" >>"$dir/.github/review-policy.yml"
    printf '%s\n' "$extra" >>"$dir/state/base-review-policy.yml"
  fi
  # Stop after the conservative entry decision, before an invalid governing
  # policy would independently fail the later write-budget fence.
  rc=$(CODEX_TEST_FAIL_PR_FETCH=1 run_case "$dir" false)
  count=$(trigger_count "$dir")
  if [ "$rc" != "3" ] || ! grep -q 'fetching HEAD commit metadata' "$dir/err.log"; then
    fail "rbd $name: exit $rc, expected 3 after a conservative request decision; stderr=$(cat "$dir/err.log")"
  elif [ "$count" != "0" ]; then
    fail "rbd $name: trigger count $count, expected 0 before the write-budget fence"
  elif ! grep -F 'WARN: cannot read codex.request_by_default' "$dir/err.log" | grep -Fq "$cause"; then
    fail "rbd $name: missing a warning naming '$cause'; stderr=$(cat "$dir/err.log")"
  else
    pass "request_by_default $name ⇒ requested with a warning naming the cause (#2240)"
  fi
}

test_request_by_default_unreadable_requests() {
  # A non-boolean value.
  assert_unreadable_requests "non-boolean" "value 'maybe' (YAML tag !!str) is not a boolean" \
    "  enabled: true"$'\n'"  request_by_default: maybe"
  # A quoted 'false' is a YAML string, not the boolean false: it must not
  # opt out. (codex_field strips quotes for the other keys; this one is read
  # by a parser so the distinction survives.)
  assert_unreadable_requests "quoted-false" "value 'false' (YAML tag !!str) is not a boolean" \
    "  enabled: true"$'\n'"  request_by_default: 'false'"
  # A single-quoted 'true' still requests (enabled: 'true' keeps the
  # codex_field quote stripping), now through the fail-safe.
  assert_unreadable_requests "quoted-true" "value 'true' (YAML tag !!str) is not a boolean" \
    "  enabled: 'true'"$'\n'"  request_by_default: 'true'"
  # Unparseable YAML elsewhere in the governing base policy: a line reader
  # would still find a clean `request_by_default: false`, which is exactly why
  # a skip needs the parser's answer. Only the base is broken here; an
  # unparseable checkout policy refuses before the entry decision (#2913, see
  # test_unparseable_checkout_policy_refuses).
  assert_unreadable_requests "unparseable" "is not valid YAML" \
    "  enabled: true"$'\n'"  request_by_default: false" "broken: [1, 2" base
  # Duplicated key: go-yaml resolves last-wins without complaint.
  assert_unreadable_requests "duplicate" "has 2 codex.request_by_default keys" \
    "  enabled: true"$'\n'"  request_by_default: true"$'\n'"  request_by_default: false"
  # A duplicated key spelled with quotes inside a block mapping (#2245).
  assert_unreadable_requests "quoted-duplicate-key" "has 2 codex.request_by_default keys" \
    "  enabled: true"$'\n'"  request_by_default: true"$'\n'"  \"request_by_default\": false"
  # A duplicate codex: block spelled with a quoted key: the parser treats
  # "codex": as the same key and keeps the last block's false, so the count
  # must see both spellings (Codex task on #2243).
  assert_unreadable_requests "quoted-duplicate-block" "has 2 codex: blocks" \
    "  enabled: true"$'\n'"  request_by_default: true" '"codex":'$'\n''  request_by_default: false'
  # No YAML parser to verify the file with.
  local dir rc count
  dir=$(make_case "rbd-no-parser" "  enabled: true"$'\n'"  request_by_default: false")
  rc=$(MERGEPATH_YQ_BIN="$dir/bin/no-such-yq" run_case "$dir" false)
  count=$(trigger_count "$dir")
  if [ "$rc" != "4" ] || [ "$count" != "1" ]; then
    fail "rbd no-parser: exit $rc / trigger count $count, expected 4 / 1 (no parser ⇒ request); stderr=$(cat "$dir/err.log")"
  elif ! grep -q 'WARN: cannot read codex.request_by_default: no YAML parser (yq)' "$dir/err.log"; then
    fail "rbd no-parser: missing the parser-unavailable warning; stderr=$(cat "$dir/err.log")"
  else
    pass "request_by_default with no YAML parser ⇒ requested with a warning naming the cause (#2240)"
  fi
}

# --- whole-policy shapes the codex:-block fixture cannot express (#2245) ----
# Each writes the ENTIRE policy, so codex_field's line reader finds none of
# the fast timing keys and the run would use the default 1800s poll. As in
# the missing-policy case below, the gh stub refuses the first read past the
# entry decision: exit 3 after "fetching HEAD commit metadata" proves a
# request, where a skip exits 5 before any read. Args: <case> <cause> <policy>
assert_policy_requests_at_fetch() {
  local name=$1 cause=$2 policy=$3 dir rc
  dir=$(make_case "rbd-$name" "  enabled: true")
  printf '%s\n' "$policy" >"$dir/.github/review-policy.yml"
  printf '%s\n' "$policy" >"$dir/state/base-review-policy.yml"
  rc=$(CODEX_TEST_FAIL_PR_FETCH=1 run_case "$dir" false)
  if [ "$rc" != "3" ] || ! grep -q 'fetching HEAD commit metadata' "$dir/err.log"; then
    fail "rbd $name: exit $rc, expected 3 at the PR fetch past a request decision; stderr=$(cat "$dir/err.log")"
  elif ! grep -F 'WARN: cannot read codex.request_by_default' "$dir/err.log" | grep -Fq "$cause"; then
    fail "rbd $name: missing a warning naming '$cause'; stderr=$(cat "$dir/err.log")"
  else
    pass "request_by_default $name ⇒ requested with a warning naming the cause (#2245)"
  fi
}

# Args: <case> <policy>. The policy parses and states no request_by_default,
# so the run must skip with exit 5 and no warning.
assert_policy_skips_unset() {
  local name=$1 policy=$2 dir rc
  dir=$(make_case "rbd-$name" "  enabled: true")
  printf '%s\n' "$policy" >"$dir/.github/review-policy.yml"
  printf '%s\n' "$policy" >"$dir/state/base-review-policy.yml"
  # Reads 1 and 2 are the #2257 derivation (metadata, head re-read).
  rc=$(CODEX_TEST_FAIL_PR_FETCH=3 run_case "$dir" false)
  if [ "$rc" != "5" ]; then
    fail "rbd $name: exit $rc, expected 5 (unset ⇒ false); stderr=$(cat "$dir/err.log")"
  elif grep -q 'WARN: cannot read codex.request_by_default' "$dir/err.log"; then
    fail "rbd $name: a parseable policy with the key absent must not warn; stderr=$(cat "$dir/err.log")"
  elif ! grep -q 'codex.request_by_default is not set' "$dir/err.log"; then
    fail "rbd $name: the skip must report the key as not set; stderr=$(cat "$dir/err.log")"
  else
    pass "request_by_default $name ⇒ unset, skip with exit 5"
  fi
}

test_request_by_default_policy_shapes() {
  # Duplicated key inside a flow mapping: go-yaml keeps the last value.
  assert_policy_requests_at_fetch "flow-duplicate-key" "has 2 codex.request_by_default keys" \
    'codex: {enabled: true, request_by_default: true, request_by_default: false}'
  # Duplicated codex key in a flow-style root mapping.
  assert_policy_requests_at_fetch "flow-duplicate-block" "has 2 codex: blocks" \
    '{codex: {request_by_default: true}, codex: {request_by_default: false}}'
  # A present but empty codex: block, an explicit null and a tilde null.
  assert_policy_requests_at_fetch "empty-codex" "is present but empty or null" \
    "author_identity: nathanjohnpayne"$'\n'"codex:"
  assert_policy_requests_at_fetch "null-codex" "is present but empty or null" \
    "author_identity: nathanjohnpayne"$'\n'"codex: null"
  assert_policy_requests_at_fetch "tilde-codex" "is present but empty or null" \
    "author_identity: nathanjohnpayne"$'\n'"codex: ~"
  # Controls: an absent codex: key still means unset, and so does a
  # well-formed empty mapping, which states no value rather than a broken one.
  assert_policy_skips_unset "absent-codex" "author_identity: nathanjohnpayne"
  assert_policy_skips_unset "empty-mapping-codex" "author_identity: nathanjohnpayne"$'\n'"codex: {}"
}

# --- missing policy file ⇒ request, with a warning --------------------------
# With no policy the script runs on its default timings (an 1800s poll), so
# the gh stub refuses the first read past the entry decision: exit 3 after
# "fetching HEAD commit metadata" proves the decision was to request, where a
# skip would have exited 5 before any read.
test_request_by_default_missing_policy_requests() {
  local dir rc gated
  for gated in false true; do
    dir=$(make_case "rbd-missing-$gated" "  enabled: true")
    rm -f "$dir/.github/review-policy.yml"
    rm -f "$dir/state/base-review-policy.yml"
    rc=$(CODEX_TEST_FAIL_PR_FETCH=1 run_case "$dir" "$gated")
    if [ "$rc" != "3" ] || ! grep -q 'fetching HEAD commit metadata' "$dir/err.log"; then
      fail "rbd missing (gated=$gated): exit $rc, expected 3 at the PR fetch past a request decision; stderr=$(cat "$dir/err.log")"
    elif ! grep -q 'could not resolve the governing policy for owner/repo#999' "$dir/err.log"; then
      fail "rbd missing (gated=$gated): missing the governing-policy warning; stderr=$(cat "$dir/err.log")"
    else
      pass "missing policy file (gated=$gated) ⇒ Codex requested (#2240)"
    fi
  done
}

# --- a Phase-4a-gated PR is requested whatever the policy says --------------
# #2240: mandatory review does not depend on request_by_default. Every shape,
# explicit false included, must post the trigger on a gated PR.
test_gated_requests_in_every_case() {
  local name block dir rc count
  while IFS='|' read -r name block; do
    dir=$(make_case "gated-$name" "  enabled: true"$'\n'"$block")
    rc=$(run_case "$dir" true)
    count=$(trigger_count "$dir")
    if [ "$rc" != "4" ] || [ "$count" != "1" ]; then
      fail "gated $name: exit $rc / trigger count $count, expected 4 / 1 (a gated PR is always requested); stderr=$(cat "$dir/err.log")"
    else
      pass "Phase-4a-gated PR with request_by_default $name ⇒ trigger posted"
    fi
  done <<'CASES'
false|  request_by_default: false
true|  request_by_default: true
unset|  bot_login: "chatgpt-codex-connector[bot]"
non-boolean|  request_by_default: maybe
CASES
}

# --- request_by_default: false + not gated ⇒ skip (exit 5, no trigger) ------
test_request_by_default_false_skips_under_threshold() {
  local dir rc count requested head terminal_shape
  dir=$(make_case "rbd-false" "  enabled: true"$'\n'"  request_by_default: false")
  rc=$(run_case "$dir" false)
  count=$(trigger_count "$dir")
  requested=$(jq -r '.trigger_requested' "$dir/out.json")
  head=$(jq -r '.head_sha' "$dir/out.json")
  terminal_shape=$(jq -r 'has("terminal_determination") and (.terminal_determination == null)' "$dir/out.json")
  if [ "$rc" != "5" ]; then
    fail "rbd false ungated: exit $rc, expected 5 (NO_TRIGGER_REQUESTED); stderr=$(cat "$dir/err.log")"
  elif [ "$count" != "0" ]; then
    fail "rbd false ungated: trigger count $count, expected 0 (no trigger)"
  elif [ "$requested" != "false" ]; then
    fail "rbd false ungated: trigger_requested=$requested, expected false"
  elif [ "$head" != "null" ]; then
    fail "rbd false ungated: head_sha=$head, expected null (skipped before PR fetch)"
  elif [ "$terminal_shape" != "true" ]; then
    fail "rbd false ungated: terminal_determination must be present and null"
  elif ! grep -q 'Codex is mandatory: rerun with MERGEPATH_PHASE_4A_GATED=true' "$dir/err.log"; then
    # Codex P1 on #2175: a Phase 4 caller that forgot the gate flag must be
    # told, not left to read the skip as "Codex not needed".
    fail "rbd false ungated: the skip must name MERGEPATH_PHASE_4A_GATED=true for a Phase 4 PR; stderr=$(cat "$dir/err.log")"
  elif grep -q 'WARN: cannot read codex.request_by_default' "$dir/err.log"; then
    fail "rbd false ungated: an explicit false must be read cleanly, not through the fail-safe; stderr=$(cat "$dir/err.log")"
  elif ! grep -q 'codex.request_by_default is false and this PR' "$dir/err.log"; then
    # #2240: an explicit false must be seen as set. A `//` read loses it
    # (yq's alternative operator treats false like null) and reports "not set".
    fail "rbd false ungated: an explicit false must be reported as set to false, not as unset; stderr=$(cat "$dir/err.log")"
  else
    pass "request_by_default:false + under-threshold ⇒ skip with exit 5, naming the Phase 4 gate flag"
  fi
}

# --- request_by_default: false + gated ⇒ trigger (pre-#486 behavior) --------
test_request_by_default_false_triggers_when_gated() {
  local dir rc count
  dir=$(make_case "rbd-false-gated" "  enabled: true"$'\n'"  request_by_default: false")
  rc=$(run_case "$dir" true)
  count=$(trigger_count "$dir")
  if [ "$rc" != "4" ]; then
    fail "rbd false gated: exit $rc, expected 4 (trigger posted, then timeout); stderr=$(cat "$dir/err.log")"
  elif [ "$count" != "1" ]; then
    fail "rbd false gated: trigger count $count, expected 1"
  else
    pass "request_by_default:false + Phase-4a-gated ⇒ trigger posted"
  fi
}

# --- enabled: false ⇒ never trigger, even with request_by_default: true -----
test_enabled_false_never_triggers() {
  local dir rc count
  dir=$(make_case "enabled-false" "  enabled: false"$'\n'"  request_by_default: true")
  # Gated AND request_by_default true — must STILL skip because Codex is off.
  rc=$(run_case "$dir" true)
  count=$(trigger_count "$dir")
  if [ "$rc" != "5" ]; then
    fail "enabled false: exit $rc, expected 5 (NO_TRIGGER_REQUESTED); stderr=$(cat "$dir/err.log")"
  elif [ "$count" != "0" ]; then
    fail "enabled false: trigger count $count, expected 0"
  elif ! grep -q "codex.enabled is false" "$dir/err.log"; then
    fail "enabled false: missing 'codex.enabled is false' log; stderr=$(cat "$dir/err.log")"
  else
    pass "enabled:false ⇒ no trigger regardless of request_by_default (orthogonality)"
  fi
}

# --- a malformed moving-head age floor fails only the write path (#2253) ----
# codex.request_min_head_age_seconds is read by the moving-head guard (#2166),
# which runs only before a new trigger write. A malformed value must not turn
# the disabled or skip paths, which post nothing, from exit 5 into exit 3; on
# the write path it is still a configuration error, refused before any post.
test_malformed_head_age_fails_only_the_write_path() {
  local dir rc count before=$FAIL
  dir=$(make_case "bad-age-skip" "  enabled: true"$'\n'"  request_min_head_age_seconds: soon")
  rc=$(run_case "$dir" false)
  [ "$rc" = "5" ] && [ "$(trigger_count "$dir")" = "0" ] \
    || fail "bad age floor, skip path: exit $rc, expected 5 with no trigger; stderr=$(cat "$dir/err.log")"
  dir=$(make_case "bad-age-disabled" "  enabled: false"$'\n'"  request_min_head_age_seconds: soon")
  rc=$(run_case "$dir" true)
  [ "$rc" = "5" ] && [ "$(trigger_count "$dir")" = "0" ] \
    || fail "bad age floor, disabled path: exit $rc, expected 5 with no trigger; stderr=$(cat "$dir/err.log")"
  dir=$(make_case "bad-age-gated" "  enabled: true"$'\n'"  request_min_head_age_seconds: soon")
  rc=$(run_case "$dir" true)
  count=$(trigger_count "$dir")
  if [ "$rc" != "3" ] || [ "$count" != "0" ]; then
    fail "bad age floor, gated write path: exit $rc with $count trigger(s), expected 3 and none; stderr=$(cat "$dir/err.log")"
  elif ! grep -q "codex.request_min_head_age_seconds must be a non-negative integer; got 'soon'" "$dir/err.log"; then
    fail "bad age floor, gated write path: the refusal must name the knob; stderr=$(cat "$dir/err.log")"
  fi
  [ "$FAIL" -ne "$before" ] || pass "a malformed request_min_head_age_seconds keeps the skip and disabled paths at exit 5 and refuses only the write path with exit 3 (#2253)"
}

# --- #2257: the Phase 4 gate is derived from the PR when the caller does not
# flag it. Every case below runs ungated with request_by_default unset unless
# it says otherwise. A request shows as exit 4 (trigger posted, then the zero
# timeout) with one trigger; a skip as exit 5 with none.
files_reads() {
  if [ -f "$1/state/files-reads" ]; then wc -l <"$1/state/files-reads" | tr -d ' '; else printf '0\n'; fi
}
derive_case() {  # <name> [top-level lines for the GOVERNING base policy]
  local dir
  dir=$(make_case "derive-$1" "  enabled: true")
  [ -z "${2:-}" ] || printf '%s\n' "$2" >>"$dir/state/base-review-policy.yml"
  printf '%s\n' "$dir"
}
# Args: <label> <dir> <rc> <reason substring>
assert_derived_request() {
  local label=$1 dir=$2 rc=$3 reason=$4 count
  count=$(trigger_count "$dir")
  if [ "$rc" != "4" ] || [ "$count" != "1" ]; then
    fail "derive $label: exit $rc / trigger count $count, expected 4 / 1 (a derived Phase 4 PR is requested); stderr=$(cat "$dir/err.log")"
  elif ! grep -F 'Phase 4 gate derived from the PR:' "$dir/err.log" | grep -Fq "$reason"; then
    fail "derive $label: the log must name the gating signal '$reason'; stderr=$(cat "$dir/err.log")"
  elif grep -q 'WARN: cannot derive the Phase 4 gate' "$dir/err.log"; then
    fail "derive $label: a readable PR must not take the fail-safe; stderr=$(cat "$dir/err.log")"
  else
    pass "#2257 derive: $label ⇒ requested, logging the signal"
  fi
}
# Args: <label> <dir> <rc> <cause substring>
assert_failsafe_request() {
  local label=$1 dir=$2 rc=$3 cause=$4 count
  count=$(trigger_count "$dir")
  if [ "$rc" != "4" ] || [ "$count" != "1" ]; then
    fail "derive fail-safe $label: exit $rc / trigger count $count, expected 4 / 1 (an unreadable input requests); stderr=$(cat "$dir/err.log")"
  elif ! grep -F 'WARN: cannot derive the Phase 4 gate:' "$dir/err.log" | grep -Fq "$cause"; then
    fail "derive fail-safe $label: missing a warning naming '$cause'; stderr=$(cat "$dir/err.log")"
  else
    pass "#2257 derive fail-safe: $label ⇒ requested with a warning naming the cause"
  fi
}
# A fail-safe whose cause also breaks the reads after the decision ends at
# exit 3 past "fetching HEAD commit metadata", which still proves the
# decision was to request. Args: <label> <dir> <rc> <cause substring>
assert_failsafe_request_at_fetch() {
  local label=$1 dir=$2 rc=$3 cause=$4 prefix=${5:-'WARN: cannot derive the Phase 4 gate:'}
  if [ "$rc" = "3" ] && grep -q 'fetching HEAD commit metadata' "$dir/err.log" \
     && grep -F "$prefix" "$dir/err.log" | grep -Fq "$cause"; then
    pass "#2257 derive fail-safe: $label ⇒ requested with a warning naming the cause"
  else
    fail "derive fail-safe $label: exit $rc, expected 3 past a request decision with a warning naming '$cause'; stderr=$(cat "$dir/err.log")"
  fi
}
# Args: <label> <dir> <rc>
assert_derived_skip() {
  local label=$1 dir=$2 rc=$3 count
  count=$(trigger_count "$dir")
  if [ "$rc" != "5" ] || [ "$count" != "0" ]; then
    fail "derive $label: exit $rc / trigger count $count, expected 5 / 0 (an under-threshold PR is skipped); stderr=$(cat "$dir/err.log")"
  elif ! grep -q 'codex.request_by_default is not set (the default is false since #2240)' "$dir/err.log"; then
    fail "derive $label: the genuine skip must keep the exit-5 message; stderr=$(cat "$dir/err.log")"
  elif ! grep -q 'Phase 4 gate derived from the PR: not gated' "$dir/err.log"; then
    fail "derive $label: the skip must report the derivation; stderr=$(cat "$dir/err.log")"
  elif grep -q 'WARN: cannot derive the Phase 4 gate' "$dir/err.log"; then
    fail "derive $label: a readable PR must not warn; stderr=$(cat "$dir/err.log")"
  else
    pass "#2257 derive: $label ⇒ skipped with exit 5"
  fi
}

test_derive_signals() {
  local dir rc
  # Label.
  dir=$(derive_case label)
  rc=$(CODEX_TEST_PR_LABELS='[{"name":"bug"},{"name":"needs-external-review"}]' run_case "$dir" false)
  assert_derived_request "needs-external-review label" "$dir" "$rc" "the PR carries the needs-external-review label"
  # The label is read from the first snapshot and short-circuits: no file list
  # is fetched and the late-label fence branch is not what gated it.
  if [ "$(files_reads "$dir")" = "0" ] && ! grep -q 'added during the derivation' "$dir/err.log"; then
    pass "#2257 derive: the label gates from the first snapshot, before any file-list read"
  else
    fail "derive label short-circuit: files reads $(files_reads "$dir"); stderr=$(cat "$dir/err.log")"
  fi
  # Size, at the default threshold: 300 is gated, 299 is not.
  dir=$(derive_case size-at)
  rc=$(CODEX_TEST_FILES_JSON='[{"filename":"src/a.ts","additions":200,"deletions":100}]' run_case "$dir" false)
  assert_derived_request "300 lines at the default threshold" "$dir" "$rc" "300 lines changed >= external_review_threshold 300"
  dir=$(derive_case size-under)
  rc=$(CODEX_TEST_FILES_JSON='[{"filename":"src/a.ts","additions":200,"deletions":99}]' run_case "$dir" false)
  assert_derived_skip "299 lines under the default threshold" "$dir" "$rc"
  # Size, at a configured threshold.
  dir=$(derive_case size-configured "external_review_threshold: 50")
  rc=$(CODEX_TEST_FILES_JSON='[{"filename":"src/a.ts","additions":30,"deletions":20}]' run_case "$dir" false)
  assert_derived_request "a configured threshold" "$dir" "$rc" "50 lines changed >= external_review_threshold 50"
  # Generated files do not count toward the size, as for the labeler.
  dir=$(derive_case size-generated)
  rc=$(CODEX_TEST_PR_CHANGED_FILES=2 CODEX_TEST_FILES_JSON='[{"filename":"package-lock.json","additions":5000,"deletions":0},{"filename":"src/a.ts","additions":3,"deletions":1}]' run_case "$dir" false)
  assert_derived_skip "a large lockfile change excluded from the size" "$dir" "$rc"
  # Protected path, and a rename out of one.
  dir=$(derive_case paths-direct 'external_review_paths:'$'\n''  - ".github/**"'$'\n''  - "src/auth/**"')
  rc=$(CODEX_TEST_FILES_JSON='[{"filename":".github/workflows/ci.yml","additions":1,"deletions":1}]' run_case "$dir" false)
  assert_derived_request "a changed protected path" "$dir" "$rc" "protected paths changed: .github/workflows/ci.yml"
  dir=$(derive_case paths-rename 'external_review_paths:'$'\n''  - "src/auth/**"')
  rc=$(CODEX_TEST_FILES_JSON='[{"filename":"src/open/login.ts","previous_filename":"src/auth/login.ts","additions":0,"deletions":0}]' run_case "$dir" false)
  assert_derived_request "a rename out of a protected path" "$dir" "$rc" "protected paths changed: src/auth/login.ts"
  dir=$(derive_case paths-miss 'external_review_paths:'$'\n''  - "src/auth/**"')
  rc=$(run_case "$dir" false)
  assert_derived_skip "no protected path touched" "$dir" "$rc"
  # Empty forms that are legitimately "no protected paths".
  dir=$(derive_case paths-empty-list 'external_review_paths: []')
  rc=$(run_case "$dir" false)
  assert_derived_skip "an empty external_review_paths list" "$dir" "$rc"
  dir=$(derive_case paths-null 'external_review_paths:')
  rc=$(run_case "$dir" false)
  assert_derived_skip "a null external_review_paths" "$dir" "$rc"
  # GitHub's 3000-file cap is gated outright.
  dir=$(derive_case files-cap)
  jq -cn '[range(3000) | {filename: "f\(.).txt", additions: 0, deletions: 0}]' >"$dir/state/files-3000.json"
  rc=$(CODEX_TEST_PR_CHANGED_FILES=3000 CODEX_TEST_FILES_JSON_FILE="$dir/state/files-3000.json" run_case "$dir" false)
  assert_derived_request "a file list at the 3000-file cap" "$dir" "$rc" "at GitHub's 3000-file cap"
  # An explicit request_by_default: false derives the same way.
  dir=$(make_case "derive-explicit-false" "  enabled: true"$'\n'"  request_by_default: false")
  rc=$(CODEX_TEST_PR_LABELS='[{"name":"needs-external-review"}]' run_case "$dir" false)
  assert_derived_request "explicit request_by_default: false with the label" "$dir" "$rc" "the PR carries the needs-external-review label"
}

test_derive_failsafe() {
  local dir rc
  dir=$(derive_case meta-unread)
  rc=$(CODEX_TEST_PR_META=fail run_case "$dir" false)
  # The metadata read after the decision fails too, so the run ends with exit 3
  # at "fetching HEAD commit metadata": proof the decision was to request.
  if [ "$rc" = "3" ] && grep -q 'fetching HEAD commit metadata' "$dir/err.log" \
     && grep -q 'could not resolve the governing policy for owner/repo#999' "$dir/err.log"; then
    pass "#2257 derive fail-safe: unreadable PR metadata ⇒ requested with a warning naming the cause"
  else
    fail "derive fail-safe metadata: exit $rc, expected 3 past a request decision with the warning; stderr=$(cat "$dir/err.log")"
  fi
  dir=$(derive_case meta-no-labels)
  rc=$(CODEX_TEST_PR_META=no-labels run_case "$dir" false)
  assert_failsafe_request "PR metadata without labels" "$dir" "$rc" "has no readable labels or changed_files count"
  dir=$(derive_case meta-bad-labels)
  rc=$(CODEX_TEST_PR_LABELS='"needs-external-review"' run_case "$dir" false)
  assert_failsafe_request "labels that are not a list" "$dir" "$rc" "has no readable labels or changed_files count"
  dir=$(derive_case meta-no-count)
  rc=$(CODEX_TEST_PR_META=no-changed-files run_case "$dir" false)
  assert_failsafe_request "PR metadata without changed_files" "$dir" "$rc" "has no readable labels or changed_files count"
  dir=$(derive_case files-unread)
  rc=$(CODEX_TEST_FILES=fail run_case "$dir" false)
  assert_failsafe_request "a failed file-list read" "$dir" "$rc" "failed to fetch PR files"
  dir=$(derive_case files-garbage)
  rc=$(CODEX_TEST_FILES_JSON='not json' run_case "$dir" false)
  assert_failsafe_request "a file list that is not JSON" "$dir" "$rc" "PR files"
  dir=$(derive_case files-empty)
  rc=$(CODEX_TEST_PR_CHANGED_FILES=0 CODEX_TEST_FILES_JSON='[]' run_case "$dir" false)
  assert_failsafe_request "an empty file list" "$dir" "$rc" "the PR file list is empty"
  dir=$(derive_case files-short)
  rc=$(CODEX_TEST_PR_CHANGED_FILES=2 run_case "$dir" false)
  assert_failsafe_request "a file list shorter than changed_files" "$dir" "$rc" "has 1 entries but the PR reports 2 changed files"
  # A newline inside a name would reach the line-based matcher as two paths.
  dir=$(derive_case files-newline 'external_review_paths:'$'\n''  - "src/auth/*.ts"')
  rc=$(CODEX_TEST_FILES_JSON='[{"filename":"src/auth/secret\n.ts","additions":1,"deletions":0}]' run_case "$dir" false)
  assert_failsafe_request "a file name containing a newline" "$dir" "$rc" "contains a newline"
  dir=$(derive_case files-shape)
  rc=$(CODEX_TEST_FILES_JSON='[{"filename":"src/a.ts"}]' run_case "$dir" false)
  assert_failsafe_request "a file entry without line counts" "$dir" "$rc" "is not an array of file entries"
  dir=$(derive_case threshold-string "external_review_threshold: \"300\"")
  rc=$(run_case "$dir" false)
  assert_failsafe_request "a quoted threshold" "$dir" "$rc" "external_review_threshold in"
  dir=$(derive_case threshold-word "external_review_threshold: lots")
  rc=$(run_case "$dir" false)
  assert_failsafe_request "a non-numeric threshold" "$dir" "$rc" "external_review_threshold in"
  # The labeler's policy list parser, loaded from the base.
  dir=$(derive_case parser-unread 'external_review_paths:'$'\n''  - ".github/**"')
  rc=$(CODEX_TEST_BASE_PARSER=fail run_case "$dir" false)
  assert_failsafe_request "an unreadable base policy list parser" "$dir" "$rc" "the policy list parser: cannot read scripts/workflow/parse_policy_list.sh at base-sha"
  # A parser that exits nonzero: identical at the base and in the requester
  # (#2272: only an identical own copy runs), so it runs and fails.
  dir=$(derive_case parser-fails 'external_review_paths:'$'\n''  - ".github/**"')
  printf '#!/usr/bin/env bash\nexit 3\n' | tee "$dir/state/base-parser.sh" >"$dir/scripts/workflow/parse_policy_list.sh"
  rc=$(run_case "$dir" false)
  assert_failsafe_request "a base policy list parser that exits nonzero" "$dir" "$rc" "the policy list parser failed on external_review_paths (rc=3)"
  dir=$(derive_case matcher-unread 'external_review_paths:'$'\n''  - ".github/**"')
  rc=$(CODEX_TEST_BASE_MATCHER=fail run_case "$dir" false)
  assert_failsafe_request "an unreadable base protected-path matcher" "$dir" "$rc" "the protected-path matcher: cannot read scripts/workflow/match_protected_paths.sh at base-sha"
  dir=$(derive_case matcher-fails 'external_review_paths:'$'\n''  - ".github/**"')
  printf '#!/usr/bin/env bash\nexit 2\n' | tee "$dir/state/base-matcher.sh" >"$dir/scripts/workflow/match_protected_paths.sh"
  rc=$(run_case "$dir" false)
  assert_failsafe_request "a failing base protected-path matcher" "$dir" "$rc" "the protected-path matcher failed (rc=2)"
  # A narrower matcher in this checkout never decides a skip: it differs from
  # the base copy, so the PR is requested without running either (#2272).
  dir=$(derive_case matcher-local-narrow 'external_review_paths:'$'\n''  - "src/**"')
  printf '#!/usr/bin/env bash\ncat >/dev/null\nexit 0\n' >"$dir/scripts/workflow/match_protected_paths.sh"
  rc=$(run_case "$dir" false)
  assert_failsafe_request "a narrower checkout matcher" "$dir" "$rc" "the protected-path matcher: scripts/workflow/match_protected_paths.sh at base-sha is not byte-identical to this requester's own copy"
  # The requester's own copy is missing: nothing runs, the PR is requested.
  dir=$(derive_case parser-own-missing 'external_review_paths:'$'\n''  - "src/**"')
  rm -f "$dir/scripts/workflow/parse_policy_list.sh"
  rc=$(run_case "$dir" false)
  assert_failsafe_request "no own copy of the parser" "$dir" "$rc" "the policy list parser: this requester has no copy of scripts/workflow/parse_policy_list.sh"
  # The default branch: its head is pinned before the policy read.
  dir=$(derive_case default-unread)
  rc=$(CODEX_TEST_DEFAULT_MODE=fail run_case "$dir" false)
  assert_failsafe_request "an unreadable default-branch head" "$dir" "$rc" "could not read the head commit of the default branch main"
  dir=$(derive_case default-advanced)
  rc=$(CODEX_TEST_DEFAULT_MODE=advanced run_case "$dir" false)
  assert_failsafe_request "a default branch that advances during the derivation" "$dir" "$rc" "the default branch main moved during the derivation"
  dir=$(derive_case exclusion-missing)
  rc=$(CODEX_TEST_BASE_HELPER=noexclude run_case "$dir" false)
  assert_failsafe_request "a base fingerprint helper without EXCLUDE_RE" "$dir" "$rc" "cannot read the generated-file exclusion"
  dir=$(derive_case exclusion-unread)
  rc=$(CODEX_TEST_BASE_HELPER=fail run_case "$dir" false)
  assert_failsafe_request "an unreadable base fingerprint helper" "$dir" "$rc" "cannot read the generated-file exclusion"
  # A local copy is never consulted: with no checkout copy at all, the base
  # copy still drives the count (a lockfile-only size stays excluded).
  dir=$(derive_case exclusion-from-base)
  rm -f "$dir/scripts/workflow/external_review_fingerprint.sh"
  rc=$(CODEX_TEST_PR_CHANGED_FILES=2 CODEX_TEST_FILES_JSON='[{"filename":"package-lock.json","additions":5000,"deletions":0},{"filename":"src/a.ts","additions":3,"deletions":1}]' run_case "$dir" false)
  assert_derived_skip "the exclusion read from the base, with no checkout copy" "$dir" "$rc"
  # A threshold on two lines: the labeler's reader yields two tokens and
  # falls back to 300, so no single value is read as written.
  dir=$(derive_case dup-threshold 'external_review_threshold: 300'$'\n''external_review_threshold: 999999')
  rc=$(run_case "$dir" false)
  assert_failsafe_request "a duplicated external_review_threshold" "$dir" "$rc" "appears on 2 top-level lines"
  dir=$(derive_case base-policy-unread)
  rc=$(CODEX_TEST_BASE_POLICY=fail run_case "$dir" false)
  assert_failsafe_request_at_fetch "an unreadable governing base policy" "$dir" "$rc" "could not resolve the governing policy for owner/repo#999" 'WARN: cannot read codex.request_by_default:'
  dir=$(derive_case meta-no-base)
  rc=$(CODEX_TEST_PR_META=no-base run_case "$dir" false)
  assert_failsafe_request_at_fetch "PR metadata without a base" "$dir" "$rc" "could not resolve the governing policy for owner/repo#999" 'WARN: cannot read codex.request_by_default:'
  # Snapshot fence: the re-read before a skip sees another PR, so the
  # under-threshold verdict no longer describes it.
  local mode
  # The moved PR also fails the stub's later reads, so these end at exit 3
  # past "fetching HEAD commit metadata": the decision was to request.
  for mode in head-moved base-moved; do
    dir=$(derive_case "fence-$mode")
    rc=$(CODEX_TEST_FENCE_MODE=$mode run_case "$dir" false)
    assert_failsafe_request_at_fetch "a PR whose $mode during the derivation" "$dir" "$rc" "the PR moved during the derivation"
  done
  # A default-branch switch changes which fallback policy governs; the later
  # reads still succeed, so this one posts and times out normally.
  dir=$(derive_case fence-default-moved)
  rc=$(CODEX_TEST_FENCE_MODE=default-moved run_case "$dir" false)
  assert_failsafe_request "a repository default branch that changed during the derivation" "$dir" "$rc" "the PR moved during the derivation"
  dir=$(derive_case fence-garbage)
  rc=$(CODEX_TEST_FENCE_MODE=garbage CODEX_TEST_FAIL_PR_FETCH=3 run_case "$dir" false)
  assert_failsafe_request_at_fetch "an unreadable fence re-read" "$dir" "$rc" "could not re-read the PR before skipping"
  dir=$(derive_case fence-label-added)
  rc=$(CODEX_TEST_FENCE_MODE=label-added run_case "$dir" false)
  assert_derived_request "a needs-external-review label added during the derivation" "$dir" "$rc" "added during the derivation"
}

# Threshold parity with the labeler (Codex P1 on #2258). The labeler and the
# merge clearance gate read `grep -E '^external_review_threshold:' | awk
# '{print $2}'` and fall back to 300 unless the token is all digits. For each
# spelling, run that same reader: a digit token must be used as written (a
# 299-line PR is under 300 and 0300, over 50); any other token must be
# unreadable here and request, never a silent 300.
# shellcheck disable=SC2015  # `check && check || fail` is the assertion idiom here
test_derive_threshold_parity() {
  local spelling token dir rc expected before=$FAIL
  while IFS= read -r spelling; do
    token=$(printf 'external_review_threshold: %s\n' "$spelling" | grep -E '^external_review_threshold:' | awk '{print $2}')
    dir=$(derive_case "parity-$(printf '%s' "$spelling" | tr -c 'A-Za-z0-9' '_')" "external_review_threshold: $spelling")
    rc=$(CODEX_TEST_FILES_JSON='[{"filename":"src/a.ts","additions":200,"deletions":99}]' run_case "$dir" false)
    if [[ "$token" =~ ^[0-9]+$ ]]; then
      if [ 299 -ge "$token" ]; then expected=request; else expected=skip; fi
      if [ "$expected" = skip ]; then
        [ "$rc" = "5" ] && ! grep -q 'cannot derive the Phase 4 gate' "$dir/err.log" \
          || fail "parity '$spelling': the labeler reads $token, so a 299-line PR must skip (rc=$rc); stderr=$(cat "$dir/err.log")"
      else
        [ "$rc" = "4" ] && grep -q "299 lines changed >= external_review_threshold $token" "$dir/err.log" \
          || fail "parity '$spelling': the labeler reads $token, so a 299-line PR must be gated by size (rc=$rc); stderr=$(cat "$dir/err.log")"
      fi
    else
      [ "$rc" = "4" ] && grep -q 'is not a plain digit scalar' "$dir/err.log" \
        || fail "parity '$spelling': the labeler rejects token '$token' (falls back to 300), so it must be unreadable and request (rc=$rc); stderr=$(cat "$dir/err.log")"
    fi
  done <<'SPELLINGS'
300
300 # tuned for this repo
0300
50
300_000
"300"
3e2
+300
0x12C
SPELLINGS
  # A flow-style policy: the labeler's line reader finds no line and uses
  # 300 (a YAML parser would read 50). The requester agrees with the labeler:
  # a 60-line PR is under 300, so it skips.
  dir=$(derive_case parity-flow)
  printf '%s\n' '{author_identity: nathanjohnpayne, external_review_threshold: 50, codex: {bot_login: "chatgpt-codex-connector[bot]", max_review_rounds: 10}}' >"$dir/state/base-review-policy.yml"
  rc=$(CODEX_TEST_FILES_JSON='[{"filename":"src/a.ts","additions":40,"deletions":20}]' run_case "$dir" false)
  [ "$rc" = "5" ] && ! grep -q 'cannot derive the Phase 4 gate' "$dir/err.log" \
    || fail "parity flow-style: the labeler reads no threshold line (300), so a 60-line PR must skip (rc=$rc); stderr=$(cat "$dir/err.log")"
  [ "$FAIL" -ne "$before" ] || pass "#2257 derive: the threshold is read exactly as the labeler reads it; spellings it would not read as written request"
}

# Path parity with the labeler (Codex P1 on #2258, round 5). For each
# spelling of external_review_paths, run the labeler's own parser and matcher
# (scripts/workflow/parse_policy_list.sh | match_protected_paths.sh) on the
# same changed file, and require the requester to gate exactly when the
# labeler matches: request on a match, skip otherwise.
# shellcheck disable=SC2015  # `check && check || fail` is the assertion idiom here
test_derive_paths_parity() {
  local name body file labeler_patterns labeler_match dir rc before=$FAIL
  local -a pats
  while IFS='|' read -r name body file; do
    dir=$(derive_case "pparity-$name" "$(printf '%b' "$body")")
    labeler_patterns=$(bash "$ROOT/scripts/workflow/parse_policy_list.sh" "$dir/state/base-review-policy.yml" external_review_paths)
    pats=()
    while IFS= read -r line; do [ -n "$line" ] && pats+=("$line"); done <<<"$labeler_patterns"
    labeler_match=""
    if [ "${#pats[@]}" -gt 0 ]; then
      labeler_match=$(printf '%s\n' "$file" | bash "$ROOT/scripts/workflow/match_protected_paths.sh" "${pats[@]}")
    fi
    rc=$(CODEX_TEST_FILES_JSON="$(jq -cn --arg f "$file" '[{filename: $f, additions: 1, deletions: 0}]')" run_case "$dir" false)
    if [ -n "$labeler_match" ]; then
      [ "$rc" = "4" ] && grep -Fq "protected paths changed: $file" "$dir/err.log" \
        || fail "paths parity $name: the labeler matches '$file' (patterns: $(printf '%s' "$labeler_patterns" | tr '\n' ' ')), so the requester must request (rc=$rc); stderr=$(cat "$dir/err.log")"
    else
      [ "$rc" = "5" ] && ! grep -q 'cannot derive the Phase 4 gate' "$dir/err.log" \
        || fail "paths parity $name: the labeler does not match '$file' (patterns: $(printf '%s' "$labeler_patterns" | tr '\n' ' ')), so the requester must skip (rc=$rc); stderr=$(cat "$dir/err.log")"
    fi
  done <<'CASES'
block|external_review_paths:\n  - ".github/**"\n  - src/auth/**|src/auth/login.ts
block-miss|external_review_paths:\n  - ".github/**"|src/app.ts
quoted-single|external_review_paths:\n  - 'src/**'|src/app.ts
commented|external_review_paths:\n  # - "docs/**"\n  - "src/**" # tail comment|src/app.ts
commented-out|external_review_paths:\n  # - "docs/**"\n  - "src/**"|docs/x.md
flow-list|external_review_paths: [".github/**", "src/**"]|src/app.ts
scalar|external_review_paths: "src/**"|src/app.ts
empty-entry|external_review_paths:\n  - ""|src/app.ts
anchor-alias|common_path: &common "*p"\nexternal_review_paths:\n  - *common|common
anchor-alias-p|common_path: &common "*p"\nexternal_review_paths:\n  - *common|top
duplicate-key|external_review_paths:\n  - "a/**"\nexternal_review_paths:\n  - "b/**"|b/x.ts
CASES
  [ "$FAIL" -ne "$before" ] || pass "#2257 derive: external_review_paths is read exactly as the labeler reads it, on every spelling"
}

# #2272: the parser and matcher are code, and the PR base can be any branch
# the PR targets. Two properties, each with planted helpers that dump their
# whole environment to a file and then do their normal work:
#  1. a base copy that differs from the requester's own is NEVER executed,
#     and the PR is requested through the fail-safe;
#  2. an identical copy runs (it is the requester's own) with no inherited
#     credentials: the dump holds no credential value and no variable beyond
#     PATH and LC_ALL plus those bash sets itself.
# Every credential variable this script can hold is set for the runs.
plant_env_dump() {  # <dir> <where: base|both>
  local dir=$1 where=$2 helper own planted
  for helper in parser matcher; do
    case "$helper" in
      parser) own="$dir/scripts/workflow/parse_policy_list.sh" ;;
      matcher) own="$dir/scripts/workflow/match_protected_paths.sh" ;;
    esac
    planted="$dir/state/base-$helper.sh.planted"
    { sed -n 1p "$dir/state/base-$helper.sh"
      printf 'env >"%s"\n' "$dir/state/$helper-env.txt"
      sed 1d "$dir/state/base-$helper.sh"
    } >"$planted"
    [ "$where" = base ] || cp "$planted" "$own"
    mv "$planted" "$dir/state/base-$helper.sh"
  done
}
assert_helper_env_clean() {  # <label> <dir> <helper>
  local label=$1 dir=$2 helper=$3 dump="$2/state/$3-env.txt" leaked helper_locale
  if [ ! -s "$dump" ]; then
    fail "helper env $label: the identical $helper never ran (no $dump); stderr=$(cat "$dir/err.log")"
    return
  fi
  if grep -Eq 'test-token|planted-secret' "$dump"; then
    fail "helper env $label: a credential VALUE reached the $helper: $(grep -E 'test-token|planted-secret' "$dump" | cut -d= -f1 | tr '\n' ' ')"
    return
  fi
  # grep -v exits 1 when nothing leaked; that is the passing case.
  leaked=$(cut -d= -f1 "$dump" | { grep -vxE 'PATH|LC_ALL|PWD|OLDPWD|SHLVL|_' || true; } | tr '\n' ' ')
  # The child Bash evaluates the literal probe under the recorded locale.
  # shellcheck disable=SC2016
  if [ -n "$leaked" ]; then
    fail "helper env $label: the $helper inherited variables beyond PATH/LC_ALL: $leaked"
  elif ! helper_locale=$(sed -n 's/^LC_ALL=//p' "$dump") \
    || ! env -i PATH="$PATH" LC_ALL="$helper_locale" bash -c \
      'sample=$'"'"'\303\251'"'"'; [ "${#sample}" -eq 1 ] && [[ $sample =~ ^[^/]$ ]]'; then
    fail "helper env $label: the $helper did not retain verified UTF-8 semantics"
  else
    pass "#2272: $label: the $helper ran with no inherited credentials"
  fi
}

plant_locale_bash() {  # <dir> <all-bad|first-bad>
  local dir=$1 mode=$2 real_bash
  real_bash=$(command -v bash)
  {
    printf '#!%s\n' "$real_bash"
    # This string is generated child-shell code, not a parent expansion.
    # shellcheck disable=SC2016
    printf 'case "${LC_ALL-}" in\n  C.UTF-8) export LC_ALL=C ;;\n'
    [ "$mode" != all-bad ] || printf '  en_US.UTF-8) export LC_ALL=C ;;\n'
    printf 'esac\nexec %q "$@"\n' "$real_bash"
  } > "$dir/bin/bash"
  chmod +x "$dir/bin/bash"
}

test_policy_helpers_verify_locale_semantics() {
  local dir rc protected='external_review_paths:'$'\n''  - "docs/a?b.md"'
  dir=$(derive_case helper-locale-unavailable "$protected")
  plant_locale_bash "$dir" all-bad
  rc=$(CODEX_TEST_FILES_JSON='[{"filename":"src/app.ts","additions":1,"deletions":0}]' run_case "$dir" false)
  assert_failsafe_request "no effective UTF-8 locale" "$dir" "$rc" "the policy list parser failed on external_review_paths (rc=2)"

  dir=$(derive_case helper-locale-fallback "$protected")
  plant_locale_bash "$dir" first-bad
  rc=$(CODEX_TEST_FILES_JSON="$(jq -cn --arg f "docs/a$(printf '\303\251')b.md" '[{filename:$f,additions:1,deletions:0}]')" run_case "$dir" false)
  # The child Bash evaluates the literal probe under its own locale.
  # shellcheck disable=SC2016
  if env -i PATH="$PATH" LC_ALL=en_US.UTF-8 bash -c \
    'sample=$'"'"'\303\251'"'"'; [ "${#sample}" -eq 1 ] && [[ $sample =~ ^[^/]$ ]]' 2>/dev/null; then
    assert_derived_request "verified fallback preserves a multibyte protected path" "$dir" "$rc" "protected paths changed: docs/a"
  else
    assert_failsafe_request "unavailable fallback also requests safely" "$dir" "$rc" "the policy list parser failed on external_review_paths (rc=2)"
  fi
}
run_case_with_credentials() {  # <dir> <files json>: run_case with every credential variable set
  GITHUB_TOKEN=planted-secret-github OP_PREFLIGHT_AUTHOR_PAT=planted-secret-author \
    OP_PREFLIGHT_REVIEWER_PAT=planted-secret-reviewer OP_SERVICE_ACCOUNT_TOKEN=planted-secret-op \
    GH_ENTERPRISE_TOKEN=planted-secret-ghe CODEX_TEST_FILES_JSON="$2" run_case "$1" false
}
test_derive_helpers_get_no_credentials() {
  local dir rc protected='external_review_paths:'$'\n''  - "src/auth/**"'$'\n''  - "docs/a?b.md"'
  # 1. A planted base copy (differs from the requester's own) never runs.
  dir=$(derive_case helper-planted-base "$protected")
  plant_env_dump "$dir" base
  rc=$(run_case_with_credentials "$dir" '[{"filename":"src/app.ts","additions":1,"deletions":0}]')
  assert_failsafe_request "a planted base parser" "$dir" "$rc" "the policy list parser: scripts/workflow/parse_policy_list.sh at base-sha is not byte-identical"
  if [ -e "$dir/state/parser-env.txt" ] || [ -e "$dir/state/matcher-env.txt" ]; then
    fail "#2272: a planted base helper was EXECUTED (an environment dump exists under $dir/state)"
  else
    pass "#2272: a base helper that differs from the requester's own is never executed"
  fi
  # 2. Identical copies run, with no credentials, and still read correctly.
  dir=$(derive_case helper-env-gated "$protected")
  plant_env_dump "$dir" both
  rc=$(run_case_with_credentials "$dir" '[{"filename":"src/auth/login.ts","additions":1,"deletions":0}]')
  assert_derived_request "identical helpers, protected path" "$dir" "$rc" "protected paths changed: src/auth/login.ts"
  assert_helper_env_clean "gated run" "$dir" parser
  assert_helper_env_clean "gated run" "$dir" matcher
  dir=$(derive_case helper-env-skip "$protected")
  plant_env_dump "$dir" both
  rc=$(run_case_with_credentials "$dir" '[{"filename":"src/app.ts","additions":1,"deletions":0}]')
  assert_derived_skip "identical helpers, unprotected path" "$dir" "$rc"
  assert_helper_env_clean "skip run" "$dir" parser
  assert_helper_env_clean "skip run" "$dir" matcher
  # The isolated locale keeps the labeler's match: `?` is one character, so a
  # multibyte file name still matches `docs/a?b.md` (under C it would not).
  dir=$(derive_case helper-env-utf8 "$protected")
  rc=$(run_case_with_credentials "$dir" "$(jq -cn --arg f "docs/a$(printf '\303\251')b.md" '[{filename: $f, additions: 1, deletions: 0}]')")
  assert_derived_request "a multibyte name under a ? pattern" "$dir" "$rc" "protected paths changed: docs/a"
}

# The threshold and paths come from the GOVERNING base policy, not the
# script checkout's copy (Codex P1 on #2258).
test_derive_reads_governing_policy() {
  local dir rc
  # The checkout lowers the threshold to 50; the base keeps the default 300.
  dir=$(derive_case governing-threshold)
  printf '%s\n' "external_review_threshold: 50" >>"$dir/.github/review-policy.yml"
  rc=$(CODEX_TEST_FILES_JSON='[{"filename":"src/a.ts","additions":40,"deletions":20}]' run_case "$dir" false)
  assert_derived_skip "a lower threshold in the checkout only" "$dir" "$rc"
  # The base protects a path the checkout does not list.
  dir=$(derive_case governing-paths 'external_review_paths:'$'\n''  - "src/**"')
  rc=$(run_case "$dir" false)
  assert_derived_request "a protected path in the base policy only" "$dir" "$rc" "protected paths changed: src/app.ts"
}

# The derivation never runs where the decision is already made: a caller
# flag (the CodeRabbit failover passes it, with the CI auto-trigger env when
# it runs from the auto-merge job), request_by_default: true, or Codex off.
# Each case refuses the file list, so a derivation would show as a fail-safe
# warning and a files read.
test_derive_not_run_when_decided() {
  local name gated block extra flags dir rc before=$FAIL
  while IFS='|' read -r name gated block extra flags; do
    dir=$(make_case "derive-skip-$name" "$(printf '%b' "$block")")
    # shellcheck disable=SC2086,SC2016  # $extra and $flags are word lists; the bash -c body expands in the child
    rc=$(env $extra CODEX_TEST_FILES=fail CODEX_TEST_PR_META=no-labels bash -c '
      dir=$1 gated=$2; shift 2
      cd "$dir" && PATH="$dir/bin:$PATH" GH_TOKEN=test-token CODEX_TEST_STATE_DIR="$dir/state" \
        MERGEPATH_PHASE_4A_GATED="$gated" ./scripts/codex-review-request.sh "$@" 999 owner/repo >"$dir/out.json" 2>"$dir/err.log"
      echo $?' _ "$dir" "$gated" $flags)
    if [ "$(files_reads "$dir")" != "0" ] || grep -q 'Phase 4 gate derived\|cannot derive the Phase 4 gate' "$dir/err.log"; then
      fail "derive not run ($name): the derivation ran (files reads $(files_reads "$dir")); stderr=$(cat "$dir/err.log")"
    fi
    case "$name" in
      codex-off) [ "$rc" = "5" ] || fail "derive not run ($name): exit $rc, expected 5" ;;
      failover) [ "$rc" = "0" ] && [ "$(trigger_count "$dir")" = "1" ] || fail "derive not run ($name): exit $rc / trigger count $(trigger_count "$dir"), expected 0 / 1; stderr=$(cat "$dir/err.log")" ;;
      *) [ "$rc" = "4" ] && [ "$(trigger_count "$dir")" = "1" ] || fail "derive not run ($name): exit $rc / trigger count $(trigger_count "$dir"), expected 4 / 1; stderr=$(cat "$dir/err.log")" ;;
    esac
  done <<'CASES'
caller-flag|true|  enabled: true|CODEX_TEST_X=1|
failover|true|  enabled: true|MERGEPATH_CODEX_AUTO_TRIGGER=true|--trigger-only --allow-moving-head
rbd-true|false|  enabled: true\n  request_by_default: true|CODEX_TEST_X=1|
codex-off|false|  enabled: false|CODEX_TEST_X=1|
CASES
  [ "$FAIL" -ne "$before" ] || pass "#2257: a caller flag (as the CodeRabbit failover passes it, with the CI auto-trigger env and --trigger-only), request_by_default: true and codex.enabled: false never run the derivation"
}

# --- timeout record is fenced against a push landing before the write -------
test_timeout_head_drift_fails_closed_without_marker() {
  local dir rc count terminals moved
  dir=$(make_case "timeout-head-drift" "  enabled: true"$'\n'"  request_by_default: true")
  moved=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
  rc=$(run_case "$dir" false "$moved")
  count=$(trigger_count "$dir")
  terminals=$(terminal_count "$dir")
  if [ "$rc" != "3" ]; then
    fail "timeout head drift: exit $rc, expected 3 (infrastructure/drift, not a timeout waiver); stderr=$(cat "$dir/err.log")"
  elif [ "$count" != "1" ]; then
    fail "timeout head drift: trigger count $count, expected 1"
  elif [ "$terminals" != "0" ]; then
    fail "timeout head drift: terminal marker count $terminals, expected 0"
  elif ! grep -q "head moved from $TEST_HEAD to $moved" "$dir/err.log"; then
    fail "timeout head drift: missing distinct drift diagnostic; stderr=$(cat "$dir/err.log")"
  else
    pass "ordinary timeout refuses to record after head drift; no stale-head waiver is written (#1085)"
  fi
}

# --- a newer request on the same head supersedes an older timeout -----------
test_new_trigger_replaces_superseded_timeout_marker() {
  local dir rc count terminals body expected marker final_state
  dir=$(make_case "superseded-timeout" "  enabled: true"$'\n'"  request_by_default: true")
  marker="<!-- mergepath-phase-4a-terminal:v1 provider=codex outcome=timeout head=$TEST_HEAD trigger_comment_id=900 -->"
  jq -cn '{id:900,user:{login:"nathanjohnpayne"},body:"@codex review",created_at:"2026-06-16T23:45:00Z"}' \
    >"$dir/state/comments.jsonl"
  jq -cn --arg body "$marker" \
    '{id:901,user:{login:"nathanjohnpayne"},body:$body,created_at:"2026-06-16T23:59:00Z"}' \
    >>"$dir/state/comments.jsonl"

  rc=$(run_case "$dir")
  count=$(trigger_count "$dir")
  terminals=$(terminal_count "$dir")
  body=$(terminal_body "$dir")
  expected="<!-- mergepath-phase-4a-terminal:v1 provider=codex outcome=timeout head=$TEST_HEAD trigger_comment_id=1001 -->"
  final_state=$(jq -sc '.' "$dir/state/comments.jsonl" | \
    bash -c 'source "$1/scripts/lib/codex-failure-markers.sh"; comments=$(cat); codex_phase4a_timeout_marker_state "$2" nathanjohnpayne "$comments"' \
      _ "$dir" "$TEST_HEAD" | jq -r '.state + ":" + (.trigger_comment_id | tostring)')

  if [ "$rc" != "4" ]; then
    fail "superseded timeout: exit $rc, expected 4; stderr=$(cat "$dir/err.log")"
  elif [ "$count" != "1" ]; then
    fail "superseded timeout: new trigger count $count, expected 1"
  elif [ "$terminals" != "1" ]; then
    fail "superseded timeout: new terminal count $terminals, expected 1"
  elif [ "$body" != "$expected" ]; then
    fail "superseded timeout: terminal body '$body', expected '$expected'"
  elif [ "$final_state" != "current:1001" ]; then
    fail "superseded timeout: final parser state '$final_state', expected current:1001"
  else
    pass "a newer same-head request supersedes the old timeout; only its own timeout may reopen Phase 4b"
  fi
}


# --- #2913: codex_field reads the parsed policy -----------------------------
# The earlier line-oriented awk reader matched only an unquoted, block-style
# `field:` key, so a quoted key or a flow mapping read as unset and took the
# default. LEGACY_REQUEST_CODEX_FIELD_AWK is that reader, kept here as the
# mutation baseline: every spelling below must be misread by it.
LEGACY_REQUEST_CODEX_FIELD_AWK='
  /^codex:/ {in_block=1; next}
  in_block && /^[^[:space:]#]/ {in_block=0}
  in_block {
    if ($1 == field":") {
      sub(/^[[:space:]]*[^:]+:[[:space:]]*/, "", $0)
      gsub(/^["\047]/, "", $0)
      gsub(/["\047][[:space:]]*(#.*)?$/, "", $0)
      gsub(/[[:space:]]*#.*$/, "", $0)
      sub(/[[:space:]]+$/, "", $0)
      print
      exit
    }
  }
'
# write_base_policy <dir> <base-policy> -- replace the governing base policy
# the entry decision reads. The checkout policy keeps make_case's fast knobs.
write_base_policy() {
  printf '%s\n' "author_identity: nathanjohnpayne" "$2" >"$1/state/base-review-policy.yml"
}

test_codex_enabled_spellings() {
  local spec label policy dir rc count legacy n=0
  for spec in \
    "quoted key|codex:"$'\n'"  \"enabled\": false"$'\n'"  request_by_default: true" \
    "single-quoted key|codex:"$'\n'"  'enabled': false" \
    "flow mapping|codex: {enabled: false, request_by_default: true}" \
    "flow mapping, quoted key|codex: {\"enabled\": false}"; do
    n=$((n + 1))
    label=${spec%%|*} policy=${spec#*|}
    dir=$(make_case "enabled-spelling-$n" "  enabled: true")
    write_base_policy "$dir" "$policy"
    rc=$(run_case "$dir" true)
    count=$(trigger_count "$dir")
    if [ "$rc" = "5" ] && [ "$count" = "0" ] && grep -q "codex.enabled is false" "$dir/err.log"; then
      pass "#2913 $label: codex.enabled: false is read, so a gated PR gets no trigger"
    else
      fail "#2913 $label: exit $rc with $count trigger(s), expected 5 and none; stderr=$(cat "$dir/err.log")"
    fi
    legacy=$(awk -v field=enabled "$LEGACY_REQUEST_CODEX_FIELD_AWK" "$dir/state/base-review-policy.yml")
    if [ "$legacy" != "false" ]; then
      pass "#2913 mutation $label: the legacy awk reader misreads codex.enabled ('$legacy'), so the case detects a regression"
    else
      fail "#2913 mutation $label: the legacy awk reader already reads codex.enabled; the case proves nothing"
    fi
  done

  # A codex.enabled of the wrong kind never opts out: the trigger is requested
  # with a warning, the #2240 failsafe. (The legacy reader handed `[false]` to
  # the caller, which read it as "not true" and skipped.)
  dir=$(make_case "enabled-wrong-kind" "  enabled: true")
  write_base_policy "$dir" "codex: {enabled: [false]}"
  rc=$(CODEX_TEST_FAIL_PR_FETCH=1 run_case "$dir" false)
  count=$(trigger_count "$dir")
  if [ "$rc" = "3" ] && [ "$count" = "0" ] && grep -q 'fetching HEAD commit metadata' "$dir/err.log" \
     && grep -q 'WARN: cannot read codex.request_by_default: codex.enabled could not be read' "$dir/err.log" \
     && grep -q 'codex.enabled must be true|false' "$dir/err.log"; then
    pass "#2913: a codex.enabled of the wrong kind is requested through the failsafe, naming the cause"
  else
    fail "#2913: wrong-kind codex.enabled did not take the failsafe (rc=$rc count=$count); stderr=$(cat "$dir/err.log")"
  fi
}

# An unparseable checkout policy refuses before the entry decision instead of
# running the requester under default timing and bot settings.
test_unparseable_checkout_policy_refuses() {
  local dir rc count
  dir=$(make_case "checkout-unparseable" "  enabled: true"$'\n'"  request_by_default: true")
  printf '%s\n' "broken: [1, 2" >>"$dir/.github/review-policy.yml"
  rc=$(run_case "$dir" true)
  count=$(trigger_count "$dir")
  if [ "$rc" = "3" ] && [ "$count" = "0" ] \
     && grep -q 'could not be parsed; cannot read codex.review_timeout_seconds' "$dir/err.log"; then
    pass "#2913: an unparseable checkout policy exits 3 before any trigger, naming the field"
  else
    fail "#2913: unparseable checkout policy (rc=$rc count=$count); stderr=$(cat "$dir/err.log")"
  fi
  # A flow-mapping checkout policy reads the same fast knobs as block style:
  # under the legacy reader this case would wait out the 1800s default.
  dir=$(make_case "checkout-flow" "  enabled: true")
  printf '%s\n' 'codex: {"review_timeout_seconds": 0, reaction_freshness_window_seconds: 999999999, "ack_wait_seconds": 0, max_ack_retries: 0}' \
    >"$dir/.github/review-policy.yml"
  rc=$(run_case "$dir" true)
  count=$(trigger_count "$dir")
  if [ "$rc" = "4" ] && [ "$count" = "1" ]; then
    pass "#2913: a flow-mapping, quoted-key checkout policy supplies its timing knobs"
  else
    fail "#2913: flow-mapping checkout policy (rc=$rc count=$count); stderr=$(cat "$dir/err.log")"
  fi
  if [ -z "$(awk -v field=review_timeout_seconds "$LEGACY_REQUEST_CODEX_FIELD_AWK" "$dir/.github/review-policy.yml")" ]; then
    pass "#2913 mutation: the legacy awk reader finds no review_timeout_seconds in the flow mapping"
  else
    fail "#2913 mutation: the legacy awk reader already reads the flow mapping; the case proves nothing"
  fi
}

test_defaults_request_on_gated_pr
test_request_by_default_unset_skips_under_threshold
test_request_by_default_true_triggers_under_threshold
test_request_by_default_unreadable_requests
test_request_by_default_policy_shapes
test_request_by_default_missing_policy_requests
test_gated_requests_in_every_case
test_request_by_default_false_skips_under_threshold
test_request_by_default_false_triggers_when_gated
test_enabled_false_never_triggers
test_codex_enabled_spellings
test_unparseable_checkout_policy_refuses
test_malformed_head_age_fails_only_the_write_path
test_derive_signals
test_derive_failsafe
test_derive_reads_governing_policy
test_derive_threshold_parity
test_derive_paths_parity
test_derive_helpers_get_no_credentials
test_policy_helpers_verify_locale_semantics
test_derive_not_run_when_decided
test_timeout_head_drift_fails_closed_without_marker
test_new_trigger_replaces_superseded_timeout_marker

# ── #1100: the accounting precondition is scoped to the provider REQUESTED ──
#
# The Phase 4b barrier's Codex arm is read-only, so making Codex terminal is
# the agent's job and codex-review-request.sh is its only tool. That tool
# refused whenever accounting was unaccounted for ANY provider -- so
# CodeRabbit's findings on the head refused the Codex request, and clearing
# them needs fix commits, each producing a new head for CodeRabbit to find more
# on. Codex could never reach terminal on the head the barrier was evaluating.
# Observed live on nathanpaynedotcom#798.
#
# The relax set is ENUMERATED rather than the block set, and that direction is
# the point: naming who may be skipped is fail-closed, because an unmodelled,
# renamed or absent reviewer keeps refusing. Naming who must block would be the
# fail-open shape.
#
# Run against the decision EXTRACTED from the script, so a revert is executed
# rather than text-matched.
# g1100_decide is invoked inside a command substitution, so a shell variable
# set there cannot reach the caller. The scratch dir travels back in a sidecar
# file so the post-call assertions below can inspect what the run left behind.
# Inside WORKDIR, so the EXIT trap registered with it at the top of this file
# is the only one. A second `trap ... EXIT` REPLACES the first rather than
# extending it, which leaked the whole WORKDIR tree on every run -- and this
# suite runs in required CI via scripts/ci/check_codex_scripts.
G1100_LASTDIR="$(mktemp "$WORKDIR/g1100-lastdir.XXXXXX")"

g1100_extract() {  # <fn-name> -- the REAL function body, so a revert is executed
  # Prefix match, not an awk -v regex: -v processes escape sequences, so the
  # backslashes needed to escape `(` and `{` do not survive into the pattern.
  awk -v fn="$1() {" 'index($0, fn) == 1 { grab = 1 } grab { print } grab && /^\}$/ { exit }' \
    "$ROOT/scripts/codex-review-request.sh"
}
# Round 3 moved the base-policy resolution OUT of the `1)` arm and into the top
# of run_feedback_accounting_gate, so one snapshot serves both accounting and
# the relax set (Codex P2: a second resolution can see a newer base than the
# one `.missing` was classified under). Extracting the whole function rather
# than the arm keeps the test on the real boundary and lets the single-snapshot
# property be asserted directly.
g1100_decide() {  # <accounting-json> -> "refuse" | "proceed"
  local body retire out fake
  body="$(g1100_extract run_feedback_accounting_gate)"
  retire="$(g1100_extract __cra_retire_base_cfg)"
  [ -n "$body" ] && [ -n "$retire" ] || { printf 'extract-failed'; return 0; }
  # Mutation proofs exercise the extracted production decision with either
  # normalization removed. Each paired control below must then fail closed.
  case "${G1100_MUTATION:-}" in
    configured-normalization)
      body="$(printf '%s\n' "$body" | sed "s/LC_ALL=C tr '\\[:upper:\\]' '\\[:lower:\\]'/cat/")"
      ;;
    gating-normalization)
      body="$(printf '%s\n' "$body" | sed "/^        __cra_gating=/,/^        if / s/LC_ALL=C tr '\\[:upper:\\]' '\\[:lower:\\]'/cat/")"
      ;;
    observed-normalization)
      body="$(printf '%s\n' "$body" | sed 's/ascii_downcase/./')"
      ;;
  esac
  fake="$(mktemp -d "$WORKDIR/g1100-req.XXXXXX")"
  printf '%s' "$fake" > "$G1100_LASTDIR"
  mkdir -p "$fake/workflow"
  printf 'codex:\n  bot_login: "chatgpt-codex-connector[bot]"\n' > "$fake/default-policy.yml"
  printf '%s' "$1" > "$fake/accounting.json"
  printf '%s' "${G1100_RC:-1}" > "$fake/accounting.rc"
  # A stub resolver standing in for scripts/workflow/resolve_base_policy.sh.
  # It materializes a NEW file per call, exactly as --materialize-default does,
  # and appends the path to materialized.log so the retry-leak property is
  # observable. G1100_NOBASE makes it fail, which must refuse: an unresolvable
  # governing base policy means we cannot say who is skippable.
  if [ -n "${G1100_NOBASE:-}" ]; then
    printf '#!/bin/sh\nexit 1\n' > "$fake/workflow/resolve_base_policy.sh"
  else
    cat > "$fake/workflow/resolve_base_policy.sh" <<RESOLVER
#!/bin/sh
f=\$(mktemp "$fake/base-policy.XXXXXX")
printf 'codex:\\n  bot_login: "chatgpt-codex-connector[bot]"\\n' > "\$f"
printf '%s\\n' "\$f" >> "$fake/materialized.log"
printf %s "\$f"
RESOLVER
  fi
  chmod +x "$fake/workflow/resolve_base_policy.sh"
  # The accounting stub records the CONFIG it was handed, so the single-snapshot
  # property is asserted on the value that actually crossed the boundary.
  cat > "$fake/accounting-stub.sh" <<STUB
#!/bin/sh
printf '%s\\n' "\${REVIEW_FEEDBACK_ACCOUNTING_CONFIG-<unset>}" >> "$fake/accounting-config.log"
cat "$fake/accounting.json"
exit "\$(cat "$fake/accounting.rc")"
STUB
  chmod +x "$fake/accounting-stub.sh"
  out="$(
    __CODEX_REQUEST_DIR="$fake"
    CONFIG="$fake/default-policy.yml"
    MERGEPATH_REVIEW_FEEDBACK_ACCOUNTING_CMD="$fake/accounting-stub.sh"
    REPO=owner/repo
    PR_NUMBER=1
    __CRA_BASE_CFG_TMP=""
    # Stub the SHARED parsed readers the decision uses; the real ones are
    # exercised by the feedback-policy-helpers suite. Keeping them stubbed also
    # keeps this suite hermetic on a runner with no YAML parser, where the real
    # reader returns rc 1 for every shape alike.
    # Every reader records the policy path it was handed. Without that, a
    # regression that reads $CONFIG -- the CANDIDATE checkout, the round-1 P1
    # privilege escalation -- passes unnoticed: the stubs return the same
    # values whatever path they are given, and $CONFIG exists and is readable
    # here. The assertions below require every reader path to equal the one
    # materialized base policy.
    policy_block_field_parsed() { printf '%s\n' "${3:-<none>}" >> "$fake/reader-paths.log"
      case "$1" in
      coderabbit) printf '%s' "${G1100_CR-coderabbitai[bot]}" ;;
      code_scanning) printf '%s' "${G1100_GHAS-github-advanced-security[bot]}" ;;
      codex) printf '%s' "${G1100_CODEX-chatgpt-codex-connector[bot]}" ;;
      *) printf '' ;; esac; }
    policy_yaml_to_json() {
      printf '%s\n' "${1:-<none>}" >> "$fake/reader-paths.log"
      [ -z "${G1100_PARSE_FAIL:-}" ] || return 1
      if [ -n "${G1100_POLICY_JSON:-}" ]; then
        printf '%s' "$G1100_POLICY_JSON"
        return 0
      fi
      jq -nc --arg cr "${G1100_CR-coderabbitai[bot]}" \
        --arg ghas "${G1100_GHAS-github-advanced-security[bot]}" \
        --arg codex "${G1100_CODEX-chatgpt-codex-connector[bot]}" \
        --arg author "${G1100_AUTHOR-nathanjohnpayne}" \
        --arg reviewers "${G1100_REVIEWERS-nathanpayne-codex nathanpayne-claude}" '
        {author_identity: $author,
         available_reviewers: ($reviewers | split(" ") | map(select(length > 0))),
         codex: {bot_login: $codex}, coderabbit: {bot_login: $cr},
         code_scanning: {bot_login: $ghas}}'
    }
    log() { :; }
    die() { printf 'refuse'; exit 0; }
    eval "$retire"
    eval "$body"
    run_feedback_accounting_gate
    [ -z "${G1100_RUNS:-}" ] || run_feedback_accounting_gate
    printf 'proceed'
  )" 2>/dev/null || out='refuse'
  printf '%s' "$out"
}
g1100_case() {  # <label> <json> <expected>
  local got; got="$(g1100_decide "$2")"
  if [ "$got" = "$3" ]; then
    pass "#1100: $1 -> $3"
  else
    fail "#1100: $1 -> expected $3, got $got"
  fi
  G1100_FAKE="$(cat "$G1100_LASTDIR")"
  [ -z "${G1100_KEEP:-}" ] && [ -n "$G1100_FAKE" ] && rm -rf "$G1100_FAKE"
  return 0
}
g1100_case "only CodeRabbit undispositioned"  '{"missing":[{"reviewer":"coderabbitai[bot]"}]}' proceed
g1100_case "only GHAS undispositioned"        '{"missing":[{"reviewer":"github-advanced-security[bot]"}]}' proceed
g1100_case "Codex App undispositioned"        '{"missing":[{"reviewer":"chatgpt-codex-connector[bot]"}]}' refuse
g1100_case "Phase-4b reviewer undispositioned" '{"missing":[{"reviewer":"nathanpayne-codex"}]}' refuse
g1100_case "CodeRabbit plus Codex"            '{"missing":[{"reviewer":"coderabbitai[bot]"},{"reviewer":"chatgpt-codex-connector[bot]"}]}' refuse
g1100_case "renamed/unmodelled reviewer"      '{"missing":[{"reviewer":"some-new-bot[bot]"}]}' refuse
g1100_case "reviewer field absent"            '{"missing":[{"kind":"inline"}]}' refuse
g1100_case "unparseable accounting output"    'not json at all' refuse
# The shapes that made the first cut fail OPEN. `.missing // []` treated an
# ABSENT missing set as "nothing blocking", so an accounting run that reported
# unaccounted without naming who was outstanding sailed through. Caught by the
# pre-existing tests/test_codex_review_request_trigger_only.sh case O, whose
# stub emits exactly that shape -- which is why that test is left untouched:
# it asserts the same fail-closed property from the other side.
g1100_case "unaccounted, missing set ABSENT"  '{"status":"unaccounted","posted":2,"accounted":1}' refuse
g1100_case "unaccounted, missing set empty"   '{"status":"unaccounted","missing":[]}' refuse
g1100_case "missing is not an array"          '{"status":"unaccounted","missing":"three"}' refuse

# #1359: successful absence uses the same provider defaults as accounting.
# It is different from an unreadable/unparseable policy, which must still
# leave nothing skippable. The parsed-reader stubs return empty for absence
# exactly as the shared readers do; the JSON fixture covers omitted blocks.
G1100_CR='' G1100_GHAS='' \
  g1100_case "absent provider logins default CodeRabbit" \
    '{"missing":[{"reviewer":"coderabbitai[bot]"}]}' proceed
G1100_CR='' G1100_GHAS='' \
  g1100_case "absent provider logins default code scanning" \
    '{"missing":[{"reviewer":"github-advanced-security[bot]"}]}' proceed
G1100_CR='' G1100_GHAS='' \
G1100_POLICY_JSON='{"coderabbit":{"enabled":true},"available_reviewers":["nathanpayne-codex"]}' \
  g1100_case "enabled CodeRabbit without login and absent code-scanning block" \
    '{"missing":[{"reviewer":"CodeRabbitAI[Bot]"},{"reviewer":"github-advanced-security[bot]"}]}' proceed
G1100_CR='custom-cr[bot]' G1100_GHAS='custom-ghas[bot]' \
  g1100_case "explicit provider logins retain their configured names" \
    '{"missing":[{"reviewer":"custom-cr[bot]"},{"reviewer":"custom-ghas[bot]"}]}' proceed
G1100_CR='custom-cr[bot]' G1100_GHAS='custom-ghas[bot]' \
  g1100_case "explicit names do not additionally relax the defaults" \
    '{"missing":[{"reviewer":"coderabbitai[bot]"}]}' refuse
G1100_PARSE_FAIL=1 \
  g1100_case "policy parse failure leaves the relax set empty" \
    '{"missing":[{"reviewer":"coderabbitai[bot]"}]}' refuse
G1100_POLICY_JSON='not json' \
  g1100_case "invalid parsed-policy JSON leaves the relax set empty" \
    '{"missing":[{"reviewer":"github-advanced-security[bot]"}]}' refuse
G1100_POLICY_JSON='{"coderabbit":{"bot_login":"coderabbitai[bot]"},"code_scanning":[]}' \
  g1100_case "failed second provider extraction discards the first login" \
    '{"missing":[{"reviewer":"coderabbitai[bot]"}]}' refuse
G1100_CR='' G1100_GHAS='' G1100_REVIEWERS='CodeRabbitAI[Bot]' \
  g1100_case "default provider colliding with a reviewer voids the whole relax set" \
    '{"missing":[{"reviewer":"github-advanced-security[bot]"}]}' refuse

# The relax set NARROWS what gates this request, so it must be resolved from
# the governing BASE policy -- the same one accounting classifies `.missing`
# with -- never from the candidate checkout. Otherwise a PR that edits
# .github/review-policy.yml could point coderabbit.bot_login at the Codex bot
# and mark Codex's own findings skippable (Codex P1, round 1). An unresolvable
# base policy is therefore "we cannot say who is skippable" -> refuse, not a
# fallback to whatever config the checkout happens to carry.
G1100_NOBASE=1 \
  g1100_case "base policy unresolvable (must not fall back to the PR checkout)" \
    '{"missing":[{"reviewer":"coderabbitai[bot]"}]}' refuse

# Resolving the relax set from the BASE policy stops a PR NOMINATING its own
# skippable providers. It does not stop a COLLISION, because
# validate_governing_policy (review-feedback-accounting.sh:127-129) validates
# codex/coderabbit/code_scanning bot_login only as `optional_string` and
# available_reviewers only as non-empty strings -- nothing requires the
# identities to be DISTINCT. A base policy that gives a skippable provider a
# gating identity's login therefore passes validation, and a login-only
# allowlist would relax that identity's findings (Codex P1, round 2).
#
# The contract is: ANY collision voids the WHOLE relax set. A policy that gives
# two providers one login has not named either of them.
G1100_CR='chatgpt-codex-connector[bot]' \
  g1100_case "coderabbit.bot_login collides with the Codex bot" \
    '{"missing":[{"reviewer":"chatgpt-codex-connector[bot]"}]}' refuse
G1100_GHAS='chatgpt-codex-connector[bot]' \
  g1100_case "code_scanning.bot_login collides with the Codex bot" \
    '{"missing":[{"reviewer":"chatgpt-codex-connector[bot]"}]}' refuse
G1100_CR='nathanpayne-codex' \
  g1100_case "coderabbit.bot_login collides with a registered reviewer" \
    '{"missing":[{"reviewer":"nathanpayne-codex"}]}' refuse
G1100_CR='nathanjohnpayne' \
  g1100_case "coderabbit.bot_login collides with the author identity" \
    '{"missing":[{"reviewer":"nathanjohnpayne"}]}' refuse
# A collision voids the relax set ENTIRELY, so even a finding from the
# uncollided provider now gates. Subtracting only the colliding entry would
# leave a policy we have already caught conflating identities still deciding
# which findings may be skipped.
G1100_CR='chatgpt-codex-connector[bot]' \
  g1100_case "collision voids the whole relax set, not just the colliding entry" \
    '{"missing":[{"reviewer":"github-advanced-security[bot]"}]}' refuse
# GitHub logins are case-insensitive but policy fields are hand-written. A
# casing-only collision must void the whole relax set just like its lower-case
# equivalent, including when the outstanding finding belongs to the other
# provider. Removing configured-set normalization mutates this back to proceed.
G1100_CR='Chatgpt-Codex-Connector[Bot]' \
  g1100_case "case-only provider collision voids the whole relax set" \
    '{"missing":[{"reviewer":"github-advanced-security[bot]"}]}' refuse
G1100_MUTATION=configured-normalization G1100_CR='Chatgpt-Codex-Connector[Bot]' \
  g1100_case "mutation: removing configured-set normalization reopens the collision" \
    '{"missing":[{"reviewer":"github-advanced-security[bot]"}]}' proceed
G1100_MUTATION=''
# The inverse spelling proves the gating set is independently normalized.
# Leaving only this side case-sensitive would let the same collision relax the
# uncollided provider's finding.
G1100_CR='chatgpt-codex-connector[bot]' G1100_CODEX='Chatgpt-Codex-Connector[Bot]' \
  g1100_case "case-only gating login collision voids the whole relax set" \
    '{"missing":[{"reviewer":"github-advanced-security[bot]"}]}' refuse
G1100_MUTATION=gating-normalization G1100_CR='chatgpt-codex-connector[bot]' G1100_CODEX='Chatgpt-Codex-Connector[Bot]' \
  g1100_case "mutation: removing gating-set normalization reopens the collision" \
    '{"missing":[{"reviewer":"github-advanced-security[bot]"}]}' proceed
G1100_MUTATION=''

# The gating set must be populated from DEFAULTS when the base policy omits a
# field. policy_block_field_parsed exits 0 and prints nothing for an absent
# field, so a `|| default` fallback never fires and would leave the Codex bot
# (or the author) out of the gating set entirely -- the collision check would
# then pass over exactly the shape it exists to catch.
G1100_CODEX='' G1100_CR='chatgpt-codex-connector[bot]' \
  g1100_case "codex.bot_login ABSENT still defaults into the gating set" \
    '{"missing":[{"reviewer":"chatgpt-codex-connector[bot]"}]}' refuse
G1100_AUTHOR='' G1100_CR='nathanjohnpayne' \
  g1100_case "author_identity ABSENT still defaults into the gating set" \
    '{"missing":[{"reviewer":"nathanjohnpayne"}]}' refuse

# Control: a policy with DISTINCT identities is not a collision, and the
# scoped exception still applies. Without this the collision check could be
# refusing everything and every case above would still pass.
G1100_CR='coderabbitai[bot]' G1100_GHAS='github-advanced-security[bot]' \
  g1100_case "distinct identities are not a collision" \
    '{"missing":[{"reviewer":"coderabbitai[bot]"},{"reviewer":"github-advanced-security[bot]"}]}' proceed
# The observed login comes from GitHub, whose canonical casing need not match
# the policy spelling. The provider exception remains legitimate across that
# difference; removing observed-login normalization makes it refuse.
G1100_CR='CodeRabbitAI[Bot]' \
  g1100_case "case-insensitive observed provider login matches the relax set" \
    '{"missing":[{"reviewer":"cOdErAbBiTaI[BoT]"}]}' proceed
G1100_MUTATION=observed-normalization G1100_CR='CodeRabbitAI[Bot]' \
  g1100_case "mutation: removing observed-login normalization refuses the provider exception" \
    '{"missing":[{"reviewer":"cOdErAbBiTaI[BoT]"}]}' refuse
G1100_MUTATION=''

# ONE snapshot, both consumers. The relax set narrows what gates this request,
# so it must come from the policy revision accounting classified `.missing`
# with. Resolving separately on each side left a window: if the PR base
# advanced between the two calls, a newer revision that moved a gating login
# onto coderabbit/code_scanning would relax a finding the older revision
# classified as gating, and the collision check could not catch it because the
# newer revision is internally consistent (Codex P2, round 3). Asserted on the
# value that actually crossed the boundary -- the CONFIG the accounting command
# was invoked with -- against the file the resolver materialized.
G1100_KEEP=1 \
  g1100_case "single snapshot: relax set and accounting share one policy file" \
    '{"missing":[{"reviewer":"coderabbitai[bot]"}]}' proceed
if [ -n "${G1100_FAKE:-}" ] && [ -s "$G1100_FAKE/materialized.log" ] \
   && [ "$(cat "$G1100_FAKE/materialized.log")" = "$(cat "$G1100_FAKE/accounting-config.log")" ] \
   && [ "$(wc -l < "$G1100_FAKE/materialized.log")" -eq 1 ]; then
  pass "#1100: accounting is handed the one materialized policy, not a second resolution"
else
  fail "#1100: accounting CONFIG ($(cat "${G1100_FAKE:-}/accounting-config.log" 2>/dev/null)) is not the one materialized policy ($(cat "${G1100_FAKE:-}/materialized.log" 2>/dev/null))"
fi
# The relax and collision readers must be handed that SAME path. Asserting only
# the accounting CONFIG leaves the original privilege escalation untested: a
# reader that took $CONFIG -- the candidate checkout a PR can edit -- would keep
# every case above green, because the stubs answer identically whatever path
# they are given (CodeRabbit, round 4).
g1100_reader_paths_ok() {
  local materialized reader
  [ -n "${G1100_FAKE:-}" ] && [ -s "$G1100_FAKE/reader-paths.log" ] || return 1
  materialized="$(cat "$G1100_FAKE/materialized.log")"
  while IFS= read -r reader; do
    [ "$reader" = "$materialized" ] || return 1
  done < "$G1100_FAKE/reader-paths.log"
  return 0
}
if g1100_reader_paths_ok; then
  pass "#1100: the relax and collision readers are handed the base policy, never \$CONFIG"
else
  fail "#1100: a policy reader was handed $(sort -u "${G1100_FAKE:-}/reader-paths.log" 2>/dev/null | tr '\n' ' ') rather than the base policy $(cat "${G1100_FAKE:-}/materialized.log" 2>/dev/null)"
fi
rm -rf "${G1100_FAKE:-/nonexistent}"

# run_trigger_ack_gate re-posts the trigger up to MAX_ACK_RETRIES times, and
# each re-post re-enters this gate and materializes ANOTHER policy file. The
# first cut of the cleanup used one variable and one EXIT trap, so only the
# last file was ever removed and every prior retry leaked (Codex P2, round 3).
# Two invocations must leave exactly one file live.
G1100_KEEP=1 G1100_RUNS=2 \
  g1100_case "retry re-entry still proceeds" \
    '{"missing":[{"reviewer":"coderabbitai[bot]"}]}' proceed
if [ -n "${G1100_FAKE:-}" ] \
   && [ "$(wc -l < "$G1100_FAKE/materialized.log")" -eq 2 ] \
   && [ "$(find "$G1100_FAKE" -maxdepth 1 -name 'base-policy.*' | wc -l)" -eq 1 ]; then
  pass "#1100: a second gate invocation retires the first materialized policy"
else
  fail "#1100: $(find "${G1100_FAKE:-}" -maxdepth 1 -name 'base-policy.*' 2>/dev/null | wc -l) materialized policies survive two invocations (expected 1 of 2)"
fi
rm -rf "${G1100_FAKE:-/nonexistent}"

echo
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
