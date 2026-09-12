#!/usr/bin/env bash
# Regression coverage for codex-review-request.sh's Phase 4a entry
# decision (#486): codex.request_by_default + codex.enabled gating of
# whether an `@codex review` trigger is posted at all. It also locks the
# #1085 handoff contract: a real, confirmed request that reaches the ordinary
# timeout path must leave a durable exact-head terminal marker for Phase 4b.
#
# Runs the real script from a temp repo with stubbed gh + gh-as-author so
# the tests exercise the production entry-gate without touching GitHub.
# The skip cases (exit 5) short-circuit BEFORE any gh call, so the stubs
# only matter on the trigger-posting cases.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export MERGEPATH_REVIEW_FEEDBACK_ACCOUNTING_CMD=true

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/codex-review-request-entry.XXXXXX")"
trap 'rm -rf "$WORKDIR"' EXIT

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

  mkdir -p "$dir/scripts" "$dir/scripts/lib" "$dir/.github" "$dir/bin" "$dir/state"
  cp "$ROOT/scripts/codex-review-request.sh" "$dir/scripts/codex-review-request.sh"
  chmod +x "$dir/scripts/codex-review-request.sh"
  cp "$ROOT/scripts/lib/codex-failure-markers.sh" "$dir/scripts/lib/codex-failure-markers.sh"
  cp "$ROOT/scripts/lib/gh-api-scalar.sh" "$dir/scripts/lib/gh-api-scalar.sh"   # #799, hard-sourced
  cp "$ROOT/scripts/lib/gh-api-array.sh" "$dir/scripts/lib/gh-api-array.sh"     # #1008, hard-sourced

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
    if [ "${2:-}" = "--jq" ]; then
      printf '%s\n' "${CODEX_TEST_LIVE_HEAD:-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa}"
    else
      printf '{"head":{"sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}}\n'
    fi ;;
  repos/owner/repo/commits/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa) printf '%s\n' "$now" ;;
  repos/owner/repo/issues/999/timeline)      printf '[]\n' ;;
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

# --- defaults: absent keys ⇒ request on every PR (backward compat) ----------
test_defaults_request_on_every_pr() {
  local dir rc count requested terminals body expected
  dir=$(make_case "defaults" "  bot_login: \"chatgpt-codex-connector[bot]\"")
  rc=$(run_case "$dir")
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
    pass "absent enabled/request_by_default ⇒ trigger posted and ordinary timeout is durably head-pinned for Phase 4b (#1085)"
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
  else
    pass "request_by_default:true ⇒ under-threshold PR gets a trigger"
  fi
}

# --- single-quoted booleans ⇒ quotes stripped before the == "true" gate -----
# Valid single-quoted YAML (`request_by_default: 'true'`, `enabled: 'true'`)
# must parse as the boolean true, not the literal string "'true'". Before the
# codex_field quote-stripping fix this triggered the wrong skip (exit 5).
test_single_quoted_booleans_trigger_under_threshold() {
  local dir rc count
  dir=$(make_case "rbd-single-quoted" \
    "  enabled: 'true'"$'\n'"  request_by_default: 'true'")
  # Not gated (under threshold): only request_by_default can drive the trigger.
  rc=$(run_case "$dir" false)
  count=$(trigger_count "$dir")
  if [ "$rc" != "4" ]; then
    fail "single-quoted: exit $rc, expected 4 (trigger posted, then timeout); stderr=$(cat "$dir/err.log")"
  elif [ "$count" != "1" ]; then
    fail "single-quoted: trigger count $count, expected 1 (quotes must be stripped before == \"true\")"
  else
    pass "single-quoted enabled/request_by_default ⇒ quotes stripped, trigger posted"
  fi
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
  else
    pass "request_by_default:false + under-threshold ⇒ skip with exit 5"
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

test_defaults_request_on_every_pr
test_request_by_default_true_triggers_under_threshold
test_single_quoted_booleans_trigger_under_threshold
test_request_by_default_false_skips_under_threshold
test_request_by_default_false_triggers_when_gated
test_enabled_false_never_triggers
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
G1100_LASTDIR="$(mktemp "${TMPDIR:-/tmp}/g1100-lastdir.XXXXXX")"
trap 'rm -f "$G1100_LASTDIR"' EXIT

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
  fake="$(mktemp -d "${TMPDIR:-/tmp}/g1100-req.XXXXXX")"
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
      printf '{"author_identity":%s,"available_reviewers":%s}' \
        "$(printf '%s' "${G1100_AUTHOR-nathanjohnpayne}" | jq -Rs 'rtrimstr("\n")')" \
        "$(printf '%s' "${G1100_REVIEWERS-nathanpayne-codex nathanpayne-claude}" \
           | jq -Rc 'rtrimstr("\n") | split(" ") | map(select(length > 0))')"
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

# Every case above assumes the policy DECLARES the providers that may be
# skipped. If it does not -- a policy without a coderabbit/code_scanning block,
# or a read that fails -- the relax set is empty and nothing is skippable, so
# the gate must refuse exactly as it did before this change. Untested shapes
# are where the first cut of this fix failed open, so this one is pinned too.
G1100_CR='' G1100_GHAS='' \
  g1100_case "empty relax set (policy declares no skippable provider)" \
    '{"missing":[{"reviewer":"coderabbitai[bot]"}]}' refuse

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
