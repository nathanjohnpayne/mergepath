#!/usr/bin/env bash
# Regression coverage for codex-review-request.sh's --trigger-only mode (#489),
# used by coderabbit-wait.sh's rate-limit failover.
#
# Runs the real script from a temp repo with stubbed gh + gh-as-author so the
# trigger-only path is deterministic and makes no GitHub writes. Verifies:
#   - fresh HEAD: posts exactly ONE @codex trigger, exits 0 WITHOUT polling and
#     WITHOUT an ack-retry (the trigger-only exit is before run_trigger_ack_gate
#     — Codex P2 #3 on #512); JSON carries trigger_only:true, trigger_posted:true.
#   - idempotent: an existing author @codex trigger on HEAD → skips the post
#     (trigger_posted:false), exits 0.
#   - author-scoped (Codex P2 #1 on #512): a *reviewer*-authored @codex review
#     does NOT count as a valid trigger → still posts.
#
# Cases D–K cover #798: the AUTOMATIC trigger must not fire on a content-free
# `update-branch` head, while an agent's explicit trigger and any head with a
# real content change still post. See the section header above case D for how
# the three layers (gate decision, call-site wiring, workflow declaration) are
# split and why each pair is non-vacuous.
#
# Bash 3.2 portable. Mirrors tests/test_codex_review_request_ack.sh.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export MERGEPATH_REVIEW_FEEDBACK_ACCOUNTING_CMD=true

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/codex-trigger-only.XXXXXX")"
trap 'rm -rf "$WORKDIR"' EXIT

PASS=0
FAIL=0
pass() { echo "PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $*" >&2; FAIL=$((FAIL + 1)); }

make_case() {
  local name=$1
  local dir="$WORKDIR/$name"
  mkdir -p "$dir/scripts" "$dir/scripts/lib" "$dir/.github" "$dir/bin" "$dir/state"
  cp "$ROOT/scripts/codex-review-request.sh" "$dir/scripts/codex-review-request.sh"
  chmod +x "$dir/scripts/codex-review-request.sh"
  cp "$ROOT/scripts/lib/gh-api-scalar.sh" "$dir/scripts/lib/gh-api-scalar.sh"   # #799, hard-sourced
  cp "$ROOT/scripts/lib/gh-api-array.sh" "$dir/scripts/lib/gh-api-array.sh"     # #1008, hard-sourced

  cat >"$dir/.github/review-policy.yml" <<'EOF'
author_identity: nathanjohnpayne
codex:
  bot_login: "chatgpt-codex-connector[bot]"
  review_timeout_seconds: 0
  reaction_freshness_window_seconds: 999999999
  ack_wait_seconds: 0
  max_ack_retries: 2
EOF

  # gh-as-author stub: records each @codex trigger post.
  cat >"$dir/scripts/gh-as-author.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
state_dir=${CODEX_TEST_STATE_DIR:?}
if [ "${9:-}" != "@codex review" ]; then
  echo "trigger body was not exact '@codex review': $*" >&2; exit 98
fi
count=0
[ -f "$state_dir/trigger-count" ] && count=$(cat "$state_dir/trigger-count")
count=$((count + 1))
printf '%s\n' "$count" >"$state_dir/trigger-count"
printf 'https://github.com/owner/repo/pull/999#issuecomment-%s\n' "$((1000 + count))"
EOF
  chmod +x "$dir/scripts/gh-as-author.sh"

  cat >"$dir/bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
scenario=${CODEX_TEST_SCENARIO:?}
author='nathanjohnpayne'
reviewer='nathanpayne-codex'
t='2026-06-04T00:00:00Z'
[ "${1:-}" = "api" ] || { echo "unexpected gh command: $*" >&2; exit 99; }
shift
[ "${1:-}" = "--paginate" ] && shift
endpoint=${1:-}
case "$endpoint" in
  repos/owner/repo/pulls/999)            printf '{"head":{"sha":"head-sha"}}\n' ;;
  repos/owner/repo/commits/head-sha)     printf '%s\n' "$t" ;;
  repos/owner/repo/issues/999/timeline)  printf '[]\n' ;;
  repos/owner/repo/pulls/999/reviews)    printf '[]\n' ;;
  repos/owner/repo/pulls/999/comments)   printf '[]\n' ;;
  repos/owner/repo/issues/999/reactions) printf '[]\n' ;;
  repos/owner/repo/issues/999/comments)
    case "$scenario" in
      dup_author)    printf '[{"id":7001,"user":{"login":"%s"},"created_at":"%s","body":"@codex review"}]\n' "$author" "$t" ;;
      reviewer_only) printf '[{"id":7002,"user":{"login":"%s"},"created_at":"%s","body":"@codex review"}]\n' "$reviewer" "$t" ;;
      *)             printf '[]\n' ;;
    esac
    ;;
  *) echo "unexpected gh api endpoint: $endpoint" >&2; exit 99 ;;
esac
EOF
  chmod +x "$dir/bin/gh"
  printf '%s\n' "$dir"
}

run_trigger_only() {
  local dir=$1 scenario=$2 rc=0
  (
    cd "$dir"
    PATH="$dir/bin:$PATH" \
      GH_TOKEN=test-token \
      CODEX_TEST_STATE_DIR="$dir/state" \
      CODEX_TEST_SCENARIO="$scenario" \
      ./scripts/codex-review-request.sh --trigger-only 999 owner/repo \
      >"$dir/out.json" 2>"$dir/err.log"
  ) || rc=$?
  printf '%s\n' "$rc"
}

trig_count() { if [ -f "$1/state/trigger-count" ]; then cat "$1/state/trigger-count"; else printf '0\n'; fi; }
jqf() { jq -r "$2" "$1/out.json"; }

# A: fresh HEAD → posts once, exits 0, no poll, no ack-retry (#3), JSON shape
test_fresh_posts_once_no_poll() {
  local dir rc before=$FAIL
  dir=$(make_case "fresh")
  rc=$(run_trigger_only "$dir" fresh)
  [ "$rc" = "0" ] || fail "A: expected exit 0, got $rc; err=$(cat "$dir/err.log")"
  [ "$(trig_count "$dir")" = "1" ] || fail "A: expected exactly 1 @codex post (no ack-retry), got $(trig_count "$dir")"
  [ "$(jqf "$dir" '.trigger_only')" = "true" ] || fail "A: trigger_only=$(jqf "$dir" '.trigger_only'), expected true"
  [ "$(jqf "$dir" '.trigger_posted')" = "true" ] || fail "A: trigger_posted=$(jqf "$dir" '.trigger_posted'), expected true"
  [ "$(jqf "$dir" '.rounds_waited_seconds')" = "0" ] || fail "A: rounds_waited_seconds=$(jqf "$dir" '.rounds_waited_seconds'), expected 0 (no poll)"
  [ "$FAIL" -ne "$before" ] || pass "A: fresh HEAD posts one @codex trigger, exits 0 without polling/ack-retry"
}

# B: existing AUTHOR trigger on HEAD → idempotent skip
test_dup_author_skips() {
  local dir rc before=$FAIL
  dir=$(make_case "dup")
  rc=$(run_trigger_only "$dir" dup_author)
  [ "$rc" = "0" ] || fail "B: expected exit 0, got $rc; err=$(cat "$dir/err.log")"
  [ "$(trig_count "$dir")" = "0" ] || fail "B: expected 0 posts (idempotent skip), got $(trig_count "$dir")"
  [ "$(jqf "$dir" '.trigger_posted')" = "false" ] || fail "B: trigger_posted=$(jqf "$dir" '.trigger_posted'), expected false"
  [ "$FAIL" -ne "$before" ] || pass "B: existing author @codex trigger on HEAD → idempotent skip (no duplicate)"
}

# C: only a REVIEWER-authored trigger → not a valid trigger, still posts (#1)
test_reviewer_trigger_does_not_count() {
  local dir rc before=$FAIL
  dir=$(make_case "reviewer")
  rc=$(run_trigger_only "$dir" reviewer_only)
  [ "$rc" = "0" ] || fail "C: expected exit 0, got $rc; err=$(cat "$dir/err.log")"
  [ "$(trig_count "$dir")" = "1" ] || fail "C: reviewer-authored @codex must NOT count → expected 1 post, got $(trig_count "$dir")"
  [ "$(jqf "$dir" '.trigger_posted')" = "true" ] || fail "C: trigger_posted=$(jqf "$dir" '.trigger_posted'), expected true"
  [ "$FAIL" -ne "$before" ] || pass "C: reviewer-authored @codex is not a valid trigger (author-scoped dedupe) → still posts"
}

# ---------------------------------------------------------------------------
# #798 — the AUTOMATIC trigger must not fire on a content-free update-branch
# head.
#
# `gh pr update-branch` mints a new head SHA that changes no file in the PR's
# own diff. With `required_status_checks.strict: true` every merge forces one
# on every other open PR, so a batch of N PRs drew O(N²) Codex rounds that
# responded to no code change.
#
# Two layers are covered, and both directions in each:
#
#   D–G  scripts/workflow/codex_auto_trigger_gate.sh, the decision itself, run
#        for real over the real external_review_fingerprint.sh with only `gh`
#        stubbed. D and E differ ONLY in which head is passed — same PR, same
#        files, same reviewed-commit history — so a gate that ignored content
#        could not pass both.
#   H–J  the call site in codex-review-request.sh. H and I differ ONLY in
#        whether MERGEPATH_CODEX_AUTO_TRIGGER is set, against an identical
#        skip-verdict gate, so a wiring that always consulted the gate (or
#        never did) fails one of them.
#   K    agent-review.yml declares the flag on the step that reaches this
#        script, asserted by PARSING the workflow rather than grepping it.
# ---------------------------------------------------------------------------

GATE_SRC="$ROOT/scripts/workflow/codex_auto_trigger_gate.sh"
FP_SRC="$ROOT/scripts/workflow/external_review_fingerprint.sh"
# The gate delegates its whole decision to the carry-forward helper, so these
# cases run the REAL one — a stub would make them assert the stub.
CF_SRC="$ROOT/scripts/workflow/external_review_carryforward.sh"

# Distinct 40-hex commit SHAs. HEAD_UNCHANGED is the update-branch head:
# different SHA, identical tree entries for the PR's changed path at both the
# head and the (moved) merge base. HEAD_CHANGED carries a different blob.
SHA_REVIEWED="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
SHA_UNCHANGED="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
SHA_CHANGED="cccccccccccccccccccccccccccccccccccccccc"

make_gate_case() {
  local name=$1
  local dir="$WORKDIR/$name"
  mkdir -p "$dir/scripts/workflow" "$dir/scripts/lib" "$dir/.github" "$dir/bin"
  cp "$GATE_SRC" "$FP_SRC" "$CF_SRC" \
     "$ROOT/scripts/workflow/parse_policy_list.sh" \
     "$ROOT/scripts/workflow/match_protected_paths.sh" \
     "$dir/scripts/workflow/"
  chmod +x "$dir/scripts/workflow/"*.sh
  # #799: both external_review_* helpers hard-source ../lib/gh-api-scalar.sh
  # (exit 2 if absent) for their sha reads, so the fixture tree needs it.
  cp "$ROOT/scripts/lib/gh-api-scalar.sh" "$dir/scripts/lib/gh-api-scalar.sh"

  # threshold 1 with a one-line diff makes the PR require external review, so
  # the fingerprint helper runs its full tree-fetching path.
  cat >"$dir/.github/review-policy.yml" <<'EOF'
external_review_threshold: 1
external_review_paths: []
codex:
  enabled: true
EOF

  # gh stub. Trees are keyed by commit: the reviewed head and the
  # update-branch head resolve to the SAME tree (t1); the changed head
  # resolves to t2. The merge base MOVES between them (mbold → mbnew) exactly
  # as a real update-branch moves it, and both merge-base trees omit the PR's
  # changed path — so a base-only advance leaves the fingerprint identical
  # while a content edit does not.
  cat >"$dir/bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[ "${1:-}" = "api" ] || { echo "unexpected gh command: $*" >&2; exit 99; }
shift
JQEXPR=""; PATHARG=""
while [ $# -gt 0 ]; do
  case "$1" in
    --paginate) shift ;;
    --jq) JQEXPR="$2"; shift 2 ;;
    *) [ -n "$PATHARG" ] || PATHARG="$1"; shift ;;
  esac
done
PATHARG=${PATHARG%%\?*}
emit() { if [ -n "$JQEXPR" ]; then printf '%s' "$1" | jq -r "$JQEXPR"; else printf '%s\n' "$1"; fi; exit 0; }
tree_for() {
  case "$1" in
    t1) printf '{"truncated":false,"tree":[{"path":"foo.txt","type":"blob","mode":"100644","sha":"blob1"}]}' ;;
    t2) printf '{"truncated":false,"tree":[{"path":"foo.txt","type":"blob","mode":"100644","sha":"blob2"}]}' ;;
    *)  printf '{"truncated":false,"tree":[]}' ;;
  esac
}
commit_tree() {
  case "$1" in
    aaaa*) printf 't1' ;;
    bbbb*) printf 't1' ;;
    cccc*) printf 't2' ;;
    *)     printf 't0' ;;
  esac
}
merge_base_for() {
  case "$1" in
    aaaa*) printf 'dddddddddddddddddddddddddddddddddddddddd' ;;
    *)     printf 'eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee' ;;
  esac
}
case "$PATHARG" in
  repos/owner/repo/pulls/999/files)
    emit '[{"filename":"foo.txt","additions":1,"deletions":0}]' ;;
  repos/owner/repo/pulls/999/reviews)
    emit "$(cat "${GATE_TEST_REVIEWS_JSON:?}")" ;;
  repos/owner/repo/issues/999/comments)
    [ "${GATE_TEST_COMMENTS_FAIL:-0}" != "1" ] || { echo "comments-boom" >&2; exit 1; }
    emit "$(cat "${GATE_TEST_COMMENTS_JSON:?}")" ;;
  repos/owner/repo/pulls/999)
    emit '{"base":{"sha":"ffffffffffffffffffffffffffffffffffffffff"}}' ;;
  repos/owner/repo/compare/*)
    emit "$(printf '{"merge_base_commit":{"sha":"%s"}}' "$(merge_base_for "${PATHARG##*...}")")" ;;
  repos/owner/repo/commits/*)
    sha=${PATHARG##*/}
    emit "$(printf '{"sha":"%s","commit":{"tree":{"sha":"%s"}}}' "$sha" "$(commit_tree "$sha")")" ;;
  repos/owner/repo/git/trees/*)
    emit "$(tree_for "${PATHARG##*/}")" ;;
  *) echo "unexpected gh api endpoint: $PATHARG" >&2; exit 99 ;;
esac
EOF
  chmod +x "$dir/bin/gh"

  # BOTH halves are load-bearing: the `Reviewed commit:` anchor AND the
  # affirmative verdict wording. The gate asks whether a prior verdict CARRIES
  # to this head, which is strictly narrower than "Codex looked at a commit" —
  # see case L for the difference and why it matters.
  printf '[{"user":{"login":"chatgpt-codex-connector[bot]"},"created_at":"2026-07-29T10:00:00Z","body":"Codex Review: Didn'"'"'t find any major issues. :+1:\\n\\n**Reviewed commit:** %s"}]\n' \
    "$SHA_REVIEWED" >"$dir/comments.json"
  printf '[]\n' >"$dir/reviews.json"
  printf '%s\n' "$dir"
}

run_gate() {
  local dir=$1 head=$2 rc=0
  (
    cd "$dir"
    PATH="$dir/bin:$PATH" \
      GATE_TEST_COMMENTS_JSON="$dir/comments.json" \
      GATE_TEST_REVIEWS_JSON="$dir/reviews.json" \
      GATE_TEST_COMMENTS_FAIL="${GATE_TEST_COMMENTS_FAIL:-0}" \
      ./scripts/workflow/codex_auto_trigger_gate.sh \
        --repo owner/repo --pr 999 --head "$head" \
      >"$dir/gate.json" 2>"$dir/gate.err"
  ) || rc=$?
  printf '%s\n' "$rc"
}

gatef() { jq -r "$2" "$1/gate.json"; }

# D: content-free update-branch head → do NOT trigger
test_gate_skips_content_free_head() {
  local dir rc before=$FAIL
  dir=$(make_gate_case "gate-unchanged")
  rc=$(run_gate "$dir" "$SHA_UNCHANGED")
  [ "$rc" = "0" ] || fail "D: expected exit 0, got $rc; err=$(cat "$dir/gate.err")"
  [ "$(gatef "$dir" '.trigger')" = "false" ] \
    || fail "D: trigger=$(gatef "$dir" '.trigger'), expected false; reason=$(gatef "$dir" '.reason')"
  [ "$(gatef "$dir" '.reviewed_commit')" = "$SHA_REVIEWED" ] \
    || fail "D: reviewed_commit=$(gatef "$dir" '.reviewed_commit'), expected $SHA_REVIEWED"
  case "$(gatef "$dir" '.fingerprint')" in
    external-review:v2:*) ;;
    *) fail "D: expected the existing external-review:v2 fingerprint, got $(gatef "$dir" '.fingerprint')" ;;
  esac
  [ "$FAIL" -ne "$before" ] || pass "D: content-free update-branch head → no automatic @codex trigger (#798)"
}

# E: same PR, same history, head whose content DIFFERS → still trigger
test_gate_triggers_on_real_content_change() {
  local dir rc before=$FAIL
  dir=$(make_gate_case "gate-changed")
  rc=$(run_gate "$dir" "$SHA_CHANGED")
  [ "$rc" = "0" ] || fail "E: expected exit 0, got $rc; err=$(cat "$dir/gate.err")"
  [ "$(gatef "$dir" '.trigger')" = "true" ] \
    || fail "E: trigger=$(gatef "$dir" '.trigger'), expected true — a real content change must still auto-post (#631/#648)"
  [ "$(gatef "$dir" '.reviewed_commit')" = "" ] \
    || fail "E: reviewed_commit=$(gatef "$dir" '.reviewed_commit'), expected empty on a trigger verdict"
  [ "$FAIL" -ne "$before" ] || pass "E: head with changed content still triggers (explicit-invocation requirement intact)"
}

# F: nothing Codex has reviewed → nothing to compare → trigger
test_gate_triggers_without_prior_review() {
  local dir rc before=$FAIL
  dir=$(make_gate_case "gate-noprior")
  printf '[]\n' >"$dir/comments.json"
  rc=$(run_gate "$dir" "$SHA_UNCHANGED")
  [ "$rc" = "0" ] || fail "F: expected exit 0, got $rc; err=$(cat "$dir/gate.err")"
  [ "$(gatef "$dir" '.trigger')" = "true" ] \
    || fail "F: trigger=$(gatef "$dir" '.trigger'), expected true with no prior Codex signal"
  [ "$FAIL" -ne "$before" ] || pass "F: no Codex-reviewed commit to compare against → triggers"
}

# G: an unreadable API must fail OPEN (over-trigger), never suppress
test_gate_fails_open_on_api_error() {
  local dir rc before=$FAIL
  dir=$(make_gate_case "gate-apierr")
  rc=$(GATE_TEST_COMMENTS_FAIL=1 run_gate "$dir" "$SHA_UNCHANGED")
  [ "$rc" = "0" ] || fail "G: expected exit 0 (a decision), got $rc; err=$(cat "$dir/gate.err")"
  [ "$(gatef "$dir" '.trigger')" = "true" ] \
    || fail "G: trigger=$(gatef "$dir" '.trigger'), expected true — an unreadable API must not suppress a review"
  [ "$FAIL" -ne "$before" ] || pass "G: API read failure fails open (posts the trigger)"
}

# L: the ONLY prior Codex signal is a COMMENTED review object — a findings
# round, not a verdict. The head is content-free in exactly the way case D is,
# so a gate that asked "did Codex LOOK at this content" would suppress here.
# It must not: external_review_carryforward.sh scores every review object
# non-affirmative, so nothing would carry to the new head. Suppressing would
# leave the head with no head-anchored signal, no carry-forward clearance, and
# no automatic caller left to re-request the review — the merge-clearance gate
# would wait forever. (Codex P1 on the #798 PR.)
test_gate_triggers_when_only_signal_is_a_review_object() {
  local dir rc before=$FAIL
  dir=$(make_gate_case "gate-reviewobj")
  printf '[]\n' >"$dir/comments.json"
  printf '[{"user":{"login":"chatgpt-codex-connector[bot]"},"state":"COMMENTED","submitted_at":"2026-07-29T10:00:00Z","commit_id":"%s"}]\n' \
    "$SHA_REVIEWED" >"$dir/reviews.json"
  rc=$(run_gate "$dir" "$SHA_UNCHANGED")
  [ "$rc" = "0" ] || fail "L: expected exit 0, got $rc; err=$(cat "$dir/gate.err")"
  [ "$(gatef "$dir" '.trigger')" = "true" ] \
    || fail "L: trigger=$(gatef "$dir" '.trigger'), expected true — a findings round carries no clearance, so suppressing would strand the head; reason=$(gatef "$dir" '.reason')"
  [ "$(gatef "$dir" '.reviewed_commit')" = "" ] \
    || fail "L: reviewed_commit=$(gatef "$dir" '.reviewed_commit'), expected empty on a trigger verdict"
  [ "$FAIL" -ne "$before" ] || pass "L: a COMMENTED review object alone does not suppress (it carries no clearance)"
}

# M: an affirmative verdict on the reviewed commit that a LATER findings round
# on that same commit supersedes. Carry-forward revokes it; the gate must
# inherit that revocation rather than matching the stale verdict. Pins that the
# delegation is real — a gate that only copied the "affirmative verdict"
# predicate would still suppress here.
test_gate_triggers_when_verdict_is_superseded() {
  local dir rc before=$FAIL
  dir=$(make_gate_case "gate-superseded")
  printf '[{"user":{"login":"chatgpt-codex-connector[bot]"},"state":"COMMENTED","submitted_at":"2026-07-29T12:00:00Z","commit_id":"%s"}]\n' \
    "$SHA_REVIEWED" >"$dir/reviews.json"
  rc=$(run_gate "$dir" "$SHA_UNCHANGED")
  [ "$rc" = "0" ] || fail "M: expected exit 0, got $rc; err=$(cat "$dir/gate.err")"
  [ "$(gatef "$dir" '.trigger')" = "true" ] \
    || fail "M: trigger=$(gatef "$dir" '.trigger'), expected true — a superseded verdict must not suppress; reason=$(gatef "$dir" '.reason')"
  [ "$FAIL" -ne "$before" ] || pass "M: a verdict superseded by a later findings round does not suppress"
}

# N: carry-forward reports a NON-BOOLEAN `carried`. `.carried | tostring` would
# coerce the string "true" into consent, and a JSON string is what a truncated
# or doubly-encoded payload most plausibly degrades into. `carried` is the one
# field that suppresses a review, so a wrong-typed value must read as no answer,
# not as yes. (CodeRabbit Major on #880.) The carry-forward helper is stubbed
# here on purpose: this asserts the GATE's handling of a malformed contract,
# which the real helper cannot produce.
test_gate_requires_boolean_carried() {
  local dir rc before=$FAIL payload
  for payload in '{"carried":"true"}' '{"carried":1}' '{"carried":null}' '{}'; do
    dir=$(make_gate_case "gate-carriedtype-$(printf '%s' "$payload" | tr -cd '[:alnum:]')")
    cat >"$dir/scripts/workflow/external_review_carryforward.sh" <<EOF
#!/usr/bin/env bash
printf '%s\n' '$payload'
EOF
    chmod +x "$dir/scripts/workflow/external_review_carryforward.sh"
    rc=$(run_gate "$dir" "$SHA_UNCHANGED")
    [ "$rc" = "0" ] || fail "N: expected exit 0 for $payload, got $rc; err=$(cat "$dir/gate.err")"
    [ "$(gatef "$dir" '.trigger')" = "true" ] \
      || fail "N: trigger=$(gatef "$dir" '.trigger') for carried=$payload, expected true — a non-boolean carried is not consent; reason=$(gatef "$dir" '.reason')"
  done
  # Control: the same stub with a real boolean DOES suppress, so N is asserting
  # the type check and not merely that a stubbed helper is ignored.
  dir=$(make_gate_case "gate-carriedtype-control")
  cat >"$dir/scripts/workflow/external_review_carryforward.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' '{"carried":true,"source_commit":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","source_time":"2026-07-29T10:00:00Z","fingerprint":"external-review:v2:deadbeef"}'
EOF
  chmod +x "$dir/scripts/workflow/external_review_carryforward.sh"
  rc=$(run_gate "$dir" "$SHA_UNCHANGED")
  [ "$rc" = "0" ] || fail "N: control expected exit 0, got $rc; err=$(cat "$dir/gate.err")"
  [ "$(gatef "$dir" '.trigger')" = "false" ] \
    || fail "N: control trigger=$(gatef "$dir" '.trigger'), expected false — a boolean true must still suppress"
  [ "$FAIL" -ne "$before" ] || pass "N: a non-boolean 'carried' is not consent (boolean true still suppresses)"
}

# --- call-site wiring in codex-review-request.sh ----------------------------

# Writes a gate stub with a fixed verdict, so H/I isolate the env flag.
write_gate_stub() {
  local dir=$1 trigger=$2
  cat >"$dir/gate-stub.sh" <<EOF
#!/usr/bin/env bash
printf '{"trigger": $trigger, "reason": "stubbed"}\n'
EOF
  chmod +x "$dir/gate-stub.sh"
  printf '%s\n' "$dir/gate-stub.sh"
}

run_trigger_only_auto() {
  local dir=$1 scenario=$2 auto=$3 gate=$4 rc=0
  (
    cd "$dir"
    PATH="$dir/bin:$PATH" \
      GH_TOKEN=test-token \
      CODEX_TEST_STATE_DIR="$dir/state" \
      CODEX_TEST_SCENARIO="$scenario" \
      MERGEPATH_CODEX_AUTO_TRIGGER="$auto" \
      MERGEPATH_CODEX_AUTO_TRIGGER_GATE_CMD="$gate" \
      ./scripts/codex-review-request.sh --trigger-only 999 owner/repo \
      >"$dir/out.json" 2>"$dir/err.log"
  ) || rc=$?
  printf '%s\n' "$rc"
}

# H: automatic caller + gate says "content-free" → no post
test_wiring_auto_caller_honors_skip() {
  local dir gate rc before=$FAIL
  dir=$(make_case "auto-skip")
  gate=$(write_gate_stub "$dir" false)
  rc=$(run_trigger_only_auto "$dir" fresh true "$gate")
  [ "$rc" = "0" ] || fail "H: expected exit 0, got $rc; err=$(cat "$dir/err.log")"
  [ "$(trig_count "$dir")" = "0" ] || fail "H: expected 0 posts, got $(trig_count "$dir")"
  [ "$(jqf "$dir" '.trigger_posted')" = "false" ] || fail "H: trigger_posted=$(jqf "$dir" '.trigger_posted'), expected false"
  [ "$FAIL" -ne "$before" ] || pass "H: automatic caller honors the gate's content-free verdict (no post)"
}

# I: SAME gate verdict, but the caller is an agent (flag unset) → still posts
test_wiring_manual_caller_ignores_gate() {
  local dir gate rc before=$FAIL
  dir=$(make_case "manual-ignores")
  gate=$(write_gate_stub "$dir" false)
  rc=$(run_trigger_only_auto "$dir" fresh "" "$gate")
  [ "$rc" = "0" ] || fail "I: expected exit 0, got $rc; err=$(cat "$dir/err.log")"
  [ "$(trig_count "$dir")" = "1" ] \
    || fail "I: expected 1 post — a manual --trigger-only must never be suppressed (#631/#648), got $(trig_count "$dir")"
  [ "$FAIL" -ne "$before" ] || pass "I: manual invocation ignores the gate entirely (explicit invocation always posts)"
}

# J: automatic caller, gate helper absent (bootstrap / mid-sync skew) → posts
test_wiring_missing_gate_fails_open() {
  local dir rc before=$FAIL
  dir=$(make_case "auto-nogate")
  rc=$(run_trigger_only_auto "$dir" fresh true "$dir/does-not-exist.sh")
  [ "$rc" = "0" ] || fail "J: expected exit 0, got $rc; err=$(cat "$dir/err.log")"
  [ "$(trig_count "$dir")" = "1" ] || fail "J: expected 1 post when the gate helper is missing, got $(trig_count "$dir")"
  [ "$FAIL" -ne "$before" ] || pass "J: missing gate helper fails open (soft-pass, posts the trigger)"
}

# O: undispositioned feedback blocks BEFORE the author-attributed trigger.
test_feedback_accounting_blocks_trigger() {
  local dir gate rc before=$FAIL
  dir=$(make_case "feedback-unaccounted")
  gate="$dir/feedback-accounting-stub.sh"
  cat >"$gate" <<'EOF'
#!/bin/sh
printf '%s\n' '{"status":"unaccounted","posted":2,"accounted":1}'
exit 1
EOF
  chmod +x "$gate"
  (
    cd "$dir"
    PATH="$dir/bin:$PATH" \
      GH_TOKEN=test-token \
      CODEX_TEST_STATE_DIR="$dir/state" \
      CODEX_TEST_SCENARIO=fresh \
      MERGEPATH_REVIEW_FEEDBACK_ACCOUNTING_CMD="$gate" \
      ./scripts/codex-review-request.sh --trigger-only 999 owner/repo \
      >"$dir/out.json" 2>"$dir/err.log"
  ) || rc=$?
  rc=${rc:-0}
  [ "$rc" = "6" ] || fail "O: expected feedback-unaccounted exit 6, got $rc; err=$(cat "$dir/err.log")"
  [ "$(trig_count "$dir")" = "0" ] || fail "O: accounting miss must block before @codex post"
  [ "$FAIL" -ne "$before" ] || pass "O: unaccounted feedback exits 6 before a new @codex trigger"
}

# K: a registered approval routes straight to the shared continuation helper.
# Parsed as YAML, not grepped: the claim is about executable step wiring, and a
# text match cannot distinguish a step body from comments elsewhere in the file.
test_workflow_declares_auto_trigger_flag() {
  local wf="$ROOT/.github/workflows/agent-review.yml" before=$FAIL
  if [ ! -f "$wf" ]; then
    echo "NOTE: K skipped — $wf not present in this checkout"
    return 0
  fi
  command -v ruby >/dev/null 2>&1 \
    || { fail "K: ruby is required to parse the workflow (refusing to pass on an unrun assertion)"; return 0; }
  if ! ruby -ryaml -e '
    wf = YAML.unsafe_load_file(ARGV[0]) rescue YAML.load_file(ARGV[0])
    job = (wf["jobs"] || {})["auto-merge-on-approval"] or abort("job auto-merge-on-approval not found")
    steps = job["steps"] || []
    abort("approval job must not wait for CodeRabbit") \
      if steps.any? { |s| s.is_a?(Hash) && s["name"].to_s.include?("CodeRabbit") }
    step = steps.find { |s| s.is_a?(Hash) && s["name"] == "Report stable readiness" } \
      or abort("step \"Report stable readiness\" not found")
    run = step["run"].to_s
    abort("Report stable readiness must route through approval-merge-continuation.sh") \
      unless run.include?("scripts/workflow/approval-merge-continuation.sh")
  ' "$wf" 2>"$WORKDIR/k.err"; then
    fail "K: $(cat "$WORKDIR/k.err")"
  fi
  [ "$FAIL" -ne "$before" ] || pass "K: registered approval routes directly through the shared continuation helper"
}

test_fresh_posts_once_no_poll
test_dup_author_skips
test_reviewer_trigger_does_not_count
test_gate_skips_content_free_head
test_gate_triggers_on_real_content_change
test_gate_triggers_without_prior_review
test_gate_fails_open_on_api_error
test_gate_triggers_when_only_signal_is_a_review_object
test_gate_triggers_when_verdict_is_superseded
test_gate_requires_boolean_carried
test_wiring_auto_caller_honors_skip
test_wiring_manual_caller_ignores_gate
test_wiring_missing_gate_fails_open
test_feedback_accounting_blocks_trigger
test_workflow_declares_auto_trigger_flag

echo "----"
echo "test_codex_review_request_trigger_only: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
