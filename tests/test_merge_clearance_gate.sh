#!/usr/bin/env bash
# tests/test_merge_clearance_gate.sh
#
# Unit tests for scripts/merge-clearance-gate.sh — the HEAD-pinned
# merge-clearance gate (nathanjohnpayne/mergepath#427 + #428).
#
# Strategy: PATH-shim `gh` so the script's REST calls return canned
# fixtures, and stub the codex-review-check.sh delegate via
# MERGE_CLEARANCE_CODEX_CHECK_BIN so the external-review dispatch +
# exit-code mapping can be exercised without re-deriving that script's
# behavior. Same shape as tests/test_codex_p1_gate.sh.
#
# Cases:
#   Dependabot path
#     1.  reviewer_gate disabled → exit 0, no API calls.
#     2.  enabled + latest-state APPROVED on HEAD by a reviewer → exit 0.
#     3.  enabled + APPROVED only on a STALE sha (not HEAD) → exit 1.
#         [#427 repro: matchline#245 — approval dismissed/absent on HEAD]
#     4.  enabled + APPROVED then later CHANGES_REQUESTED on HEAD → exit 1.
#     5.  enabled + APPROVED on HEAD by a non-reviewer login → exit 1.
#   External-review path
#     6.  external_review_gate disabled → exit 0.
#     7.  enabled + delegate returns 0 → exit 0.
#     8.  enabled + delegate returns 1 → exit 1.
#         [#428 repro: nathanpaynedotcom#405 — not cleared on merge HEAD]
#     9.  enabled + delegate returns 3 (infra) → exit 2.
#   Dispatch / misc
#     10. Dependabot precedence: dependabot author + needs-external-review
#         label → judged by the Dependabot rule (not the external path).
#     11. neither Dependabot nor external-review → exit 0 (not applicable).
#     12. malformed PR_NUMBER → exit 2.
#     13. missing GH_TOKEN → exit 2.
#     14. env-only PR_NUMBER + REPO → same behavior as positional.
#   Query modes (--derive-external-requiredness, --derive-rate-limit-protection)
#     Query 1–8 / Protection 1–6, at the bottom of this file. The Protection
#     block carries the #772 enforcement cases: arm 1 now demands positive
#     proof that `Merge clearance gate` is a REQUIRED status check on the PR's
#     base branch, not just `codex.external_review_gate.enabled: true`.
#
# Bash 3.2 portable.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/scripts/merge-clearance-gate.sh"

[[ -x "$SCRIPT" ]] || { echo "missing or non-executable $SCRIPT" >&2; exit 1; }

if ! command -v jq >/dev/null 2>&1; then
  echo "SKIP: jq not available (merge-clearance-gate.sh requires jq)" >&2
  exit 0
fi

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/merge-clearance-gate-test.XXXXXX")"
trap 'rm -rf "$WORKDIR"' EXIT

PASS=0
FAIL=0
pass() { echo "PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $*" >&2; FAIL=$((FAIL + 1)); }

# ---------------------------------------------------------------------------
# PATH-shim gh: log calls, route pulls/N/reviews and pulls/N to fixtures.
# ---------------------------------------------------------------------------
STUB_DIR="$WORKDIR/stub-bin"
mkdir -p "$STUB_DIR"

# Defined before the gh stub heredoc: the stub interpolates it when emitting
# per-check producer data for the #772 r5 producer verification.
GATE_CHECK_NAME="Merge clearance gate"
export GATE_CHECK_NAME  # the gh stub interpolates it at RUN time (quoted heredoc)

cat >"$STUB_DIR/gh" <<'STUB'
#!/usr/bin/env bash
LOG="${GH_CALLS_LOG:-/dev/null}"
{
  printf 'gh'
  for a in "$@"; do printf '\t%s' "$a"; done
  printf '\n'
} >> "$LOG"

if [ "$1" = "api" ]; then
  shift
  paginate=0
  if [ "${1:-}" = "--paginate" ]; then paginate=1; shift; fi
  endpoint="${1:-}"
  case "$endpoint" in
    repos/*/pulls/*/reviews)
      cat "${FIXTURE_REVIEWS:-/dev/null}"
      exit 0
      ;;
    repos/*/pulls/*/files)
      cat "${FIXTURE_FILES:-/dev/null}"
      exit 0
      ;;
    repos/*/issues/*/comments)
      # FIXTURE_COMMENTS_FAIL=1 simulates a transient comments-API failure
      # (the indeterminate marker-read case, automated-4b round-5 P1).
      if [ "${FIXTURE_COMMENTS_FAIL:-0}" = "1" ]; then
        echo "STUB gh: simulated comments API failure" >&2
        exit 1
      fi
      cat "${FIXTURE_COMMENTS:-/dev/null}"
      exit 0
      ;;
    graphql)
      # #772 enforcement probe, surface 1 (classic branch protection via
      # ref.refUpdateRule). FIXTURE_PROTECTION_FAIL=1 simulates an API failure
      # so the "enforcement undeterminable" path can be exercised. Unset
      # FIXTURE_PROTECTION means "no observable protection" — the fleet-wide
      # reality today, where `Merge clearance gate` is required nowhere.
      if [ "${FIXTURE_PROTECTION_FAIL:-0}" = "1" ]; then
        echo "STUB gh: simulated branch-protection GraphQL failure" >&2
        exit 1
      fi
      cat "${FIXTURE_PROTECTION:-/dev/null}"
      exit 0
      ;;
    repos/*/branches/*/protection)
      # #772 r3 P1: enforce_admins lookup. Absent fixture == the CI reality
      # (admin-only endpoint, 404 for the reviewer PAT), which must make the
      # classic surface contribute nothing.
      if [ -z "${FIXTURE_ADMIN_ENFORCE:-}" ]; then
        echo "gh: Not Found (HTTP 404)" >&2
        exit 1
      fi
      # #772 r5: the same response carries per-check producer data. Default to
      # the trusted Actions app id; FIXTURE_CLASSIC_APP_ID overrides it so a
      # foreign-producer case can be exercised.
      if [ "${FIXTURE_CLASSIC_DUP_FIRST:-0}" = "1" ]; then
        # Same context listed twice, foreign producer FIRST — the ordering that
        # a `.[0]`-based match would misread as not-enforced (#772 r6 P2).
        printf '{"enforce_admins":{"enabled":%s},"required_status_checks":{"checks":[{"context":"%s","app_id":99999},{"context":"%s","app_id":15368}]}}\n' \
          "$FIXTURE_ADMIN_ENFORCE" "$GATE_CHECK_NAME" "$GATE_CHECK_NAME"
      else
        printf '{"enforce_admins":{"enabled":%s},"required_status_checks":{"checks":[{"context":"%s","app_id":%s}]}}\n' \
          "$FIXTURE_ADMIN_ENFORCE" "$GATE_CHECK_NAME" "${FIXTURE_CLASSIC_APP_ID:-15368}"
      fi
      exit 0
      ;;
    repos/*/rulesets/*)
      # #772 r2 P1: bypass-actor lookup for a candidate ruleset.
      if [ "${FIXTURE_RULESET_OBJ_FAIL:-0}" = "1" ]; then
        echo "STUB gh: simulated ruleset object read failure" >&2
        exit 1
      fi
      cat "${FIXTURE_RULESET_OBJ:-/dev/null}"
      exit 0
      ;;
    repos/*/rules/branches/*)
      # #772 enforcement probe, surface 2 (repository rulesets).
      if [ "${FIXTURE_RULESETS_FAIL:-0}" = "1" ]; then
        echo "STUB gh: simulated rulesets API failure" >&2
        exit 1
      fi
      cat "${FIXTURE_RULESETS:-/dev/null}"
      # Page 2 is emitted ONLY for a caller that actually passed --paginate,
      # mirroring the real endpoint's 30-rule page cap. This is what makes
      # Protection 1g a genuine regression test for the truncation finding:
      # without --paginate the gate sees page 1 only, exactly as in production.
      if [ "$paginate" = "1" ] && [ -n "${FIXTURE_RULESETS_PAGE2:-}" ]; then
        cat "$FIXTURE_RULESETS_PAGE2"
      fi
      exit 0
      ;;
    repos/*/contents/*)
      # #763: PR-base review policy. Served only when a fixture sets it;
      # otherwise emit a 404 shape so the script takes its documented
      # "base predates the policy file" fallback.
      if [ -n "${FIXTURE_BASE_POLICY:-}" ]; then
        cat "$FIXTURE_BASE_POLICY"
        exit 0
      fi
      echo "gh: Not Found (HTTP 404)" >&2
      exit 1
      ;;
    repos/*/pulls/*)
      cat "${FIXTURE_PR:-/dev/null}"
      exit 0
      ;;
    *)
      # Fail (don't silently succeed) on an unhandled endpoint so a future
      # gate change that calls a new endpoint surfaces as a test failure
      # rather than a false green (CodeRabbit ⚠️ on PR #429).
      echo "STUB gh: unhandled api endpoint: $endpoint" >&2
      exit 1
      ;;
  esac
fi
# Any non-`gh api` invocation is unexpected for this gate.
echo "STUB gh: unhandled invocation: $*" >&2
exit 1
STUB
chmod +x "$STUB_DIR/gh"

# A stub codex-review-check.sh that exits with $CODEX_STUB_RC (inherited
# from the gate's environment). Default 0. Tests can set
# CODEX_STUB_REQUIRE_HEAD_PIN=1 to assert the caller passed the real
# delegate's HEAD-pinning override.
cat >"$STUB_DIR/codex-check-stub" <<'STUB'
#!/usr/bin/env bash
if [ "${CODEX_STUB_REQUIRE_HEAD_PIN:-0}" = "1" ] && [ "${CODEX_REVIEW_CHECK_REQUIRE_APPROVAL_ON_HEAD:-}" != "1" ]; then
  echo "codex-check-stub: expected CODEX_REVIEW_CHECK_REQUIRE_APPROVAL_ON_HEAD=1" >&2
  exit 42
fi
[ -z "${CODEX_STUB_STDOUT:-}" ] || printf '%s\n' "$CODEX_STUB_STDOUT"
exit "${CODEX_STUB_RC:-0}"
STUB
chmod +x "$STUB_DIR/codex-check-stub"

# ---------------------------------------------------------------------------
# Scratch repo dir with a review-policy.yml controlling both knobs +
# the available_reviewers list.
# ---------------------------------------------------------------------------
make_scratch() {
  local dependabot_enabled=$1 external_enabled=$2
  local dir
  dir=$(mktemp -d "$WORKDIR/scratch.XXXXXX")
  mkdir -p "$dir/.github"
  cat >"$dir/.github/review-policy.yml" <<EOF
external_review_threshold: 300
external_review_paths:
  - ".github/**"
  - "src/auth/**"

available_reviewers:
  - nathanpayne-claude
  - nathanpayne-cursor
  - nathanpayne-codex

codex:
  bot_login: "chatgpt-codex-connector[bot]"
  external_review_gate:
    enabled: $external_enabled

dependabot:
  reviewer_gate:
    enabled: $dependabot_enabled
EOF
  echo "$dir"
}

make_files_fixture() {  # <json_array_literal>   e.g. '[{"filename":"x","additions":5,"deletions":0}]'
  local content=$1
  local file="$WORKDIR/files.$$.$RANDOM.json"
  echo "$content" >"$file"
  echo "$file"
}

make_comments_fixture() {  # <json_array_literal>  issue comments
  local content=$1
  local file="$WORKDIR/comments.$$.$RANDOM.json"
  echo "$content" >"$file"
  echo "$file"
}

make_pr_fixture() {  # <sha> <author> <labels_json_array> [base_ref] [default_branch]
  local sha=$1 author=$2 labels=${3:-'[]'}
  # Default to base_ref == default_branch: the ordinary case, in which the
  # #763 base-policy fetch is deliberately skipped entirely.
  local base_ref=${4:-main} default_branch=${5:-main}
  local file="$WORKDIR/pr.$$.$RANDOM.json"
  jq -n --arg sha "$sha" --arg author "$author" --argjson labels "$labels" \
        --arg base_ref "$base_ref" --arg default_branch "$default_branch" '
    { number: 99,
      head: { sha: $sha },
      user: { login: $author },
      labels: $labels,
      base: { sha: "base000aaa", ref: $base_ref,
              repo: { default_branch: $default_branch } } }
  ' >"$file"
  echo "$file"
}

make_protection_fixture() {  # <contexts_json_array>  GraphQL refUpdateRule shape
  local contexts=$1
  local file="$WORKDIR/protection.$$.$RANDOM.json"
  jq -n --argjson contexts "$contexts" '
    { data: { repository: { ref: { refUpdateRule: {
        requiredStatusCheckContexts: $contexts } } } } }
  ' >"$file"
  echo "$file"
}

make_rulesets_fixture() {  # <contexts_json_array> [ruleset_id]  rules/branches/<branch> shape
  local contexts=$1 rs_id=${2:-101}
  local file="$WORKDIR/rulesets.$$.$RANDOM.json"
  jq -n --argjson contexts "$contexts" --argjson rs_id "$rs_id" \
        --argjson app "${FIXTURE_RULESET_APP_ID:-15368}" '
    [ { type: "required_status_checks",
        ruleset_id: $rs_id,
        parameters: { required_status_checks: [ $contexts[] | { context: ., integration_id: $app } ] } } ]
  ' >"$file"
  echo "$file"
}

# The ruleset OBJECT behind a rules/branches entry. `rules/branches` does not
# return bypass_actors, so the #772 probe fetches this to prove the ruleset
# actually constrains the merging identity.
make_ruleset_object_fixture() {  # <bypass_actors_json_array>
  local bypass=$1
  local file="$WORKDIR/ruleset-obj.$$.$RANDOM.json"
  jq -n --argjson bypass "$bypass" '{ id: 101, name: "test-ruleset", bypass_actors: $bypass }' >"$file"
  echo "$file"
}

make_reviews_fixture() {  # <json_array_literal>
  local content=$1
  local file="$WORKDIR/reviews.$$.$RANDOM.json"
  echo "$content" >"$file"
  echo "$file"
}

run_gate() {  # <scratch> [args...]   (env: FIXTURE_PR, FIXTURE_REVIEWS, CODEX_STUB_RC, MERGE_CLEARANCE_CODEX_CHECK_BIN)
  local scratch=$1; shift
  (
    cd "$scratch"
    PATH="$STUB_DIR:$PATH" \
      GH_TOKEN="dummy-token" \
      GH_CALLS_LOG="$WORKDIR/gh-calls.log" \
      "$SCRIPT" "$@"
  )
}

# Default ruleset OBJECT for the #772 bypass-actor probe: a ruleset with NO
# bypass actors, i.e. one that genuinely constrains every identity. Exported
# so every stub invocation sees it; a test that needs bypass actors overrides
# it with its own prefix assignment.
FIXTURE_RULESET_OBJ=$(make_ruleset_object_fixture "[]")
export FIXTURE_RULESET_OBJ

# Default for the #772 classic-protection arm: enforce_admins ON, so a
# required context genuinely binds every merger. Tests override to "false" or
# unset it to exercise the unprovable/CI case.
FIXTURE_ADMIN_ENFORCE=true
export FIXTURE_ADMIN_ENFORCE

HEAD_SHA="head000aaa"
OLD_SHA="old111bbb"
DEPENDABOT='dependabot[bot]'
EXT_LABEL='[{"name":"needs-external-review"}]'

# ---------------------------------------------------------------------------
# Test 1: Dependabot, reviewer_gate disabled → exit 0, no reviews API call.
# ---------------------------------------------------------------------------
echo; echo "--- Test 1: Dependabot, gate disabled"
SCRATCH=$(make_scratch false false)
FIXTURE_PR=$(make_pr_fixture "$HEAD_SHA" "$DEPENDABOT")
: > "$WORKDIR/gh-calls.log"
set +e
OUT=$(FIXTURE_PR="$FIXTURE_PR" run_gate "$SCRATCH" 99 owner/repo 2>&1)
RC=$?
set -e
if [ "$RC" = 0 ] && echo "$OUT" | grep -q "PASS" \
    && ! grep -q "reviews" "$WORKDIR/gh-calls.log"; then
  pass "Dependabot + gate disabled → exit 0, no reviews fetch"
else
  fail "expected rc=0 + no reviews fetch; got rc=$RC"; echo "$OUT" | sed 's/^/      /' >&2
fi

# ---------------------------------------------------------------------------
# Test 2: Dependabot, enabled, latest-state APPROVED on HEAD → exit 0.
# ---------------------------------------------------------------------------
echo; echo "--- Test 2: Dependabot, APPROVED on HEAD"
SCRATCH=$(make_scratch true false)
FIXTURE_PR=$(make_pr_fixture "$HEAD_SHA" "$DEPENDABOT")
FIXTURE_REVIEWS=$(make_reviews_fixture "$(jq -n --arg sha "$HEAD_SHA" '
  [{ user:{login:"nathanpayne-claude"}, state:"APPROVED", commit_id:$sha, submitted_at:"2026-06-01T10:00:00Z" }]
')")
set +e
OUT=$(FIXTURE_PR="$FIXTURE_PR" FIXTURE_REVIEWS="$FIXTURE_REVIEWS" run_gate "$SCRATCH" 99 owner/repo 2>&1)
RC=$?
set -e
if [ "$RC" = 0 ] && echo "$OUT" | grep -q "PASS" && echo "$OUT" | grep -q "nathanpayne-claude"; then
  pass "Dependabot + APPROVED on HEAD → exit 0"
else
  fail "expected rc=0 PASS with approver; got rc=$RC"; echo "$OUT" | sed 's/^/      /' >&2
fi

# ---------------------------------------------------------------------------
# Test 3 (#427 repro): APPROVED only on a STALE sha (not HEAD) → exit 1.
# ---------------------------------------------------------------------------
echo; echo "--- Test 3: Dependabot, APPROVED only on stale sha (#427)"
SCRATCH=$(make_scratch true false)
FIXTURE_PR=$(make_pr_fixture "$HEAD_SHA" "$DEPENDABOT")
FIXTURE_REVIEWS=$(make_reviews_fixture "$(jq -n --arg old "$OLD_SHA" '
  [{ user:{login:"nathanpayne-claude"}, state:"APPROVED", commit_id:$old, submitted_at:"2026-06-01T09:00:00Z" }]
')")
set +e
OUT=$(FIXTURE_PR="$FIXTURE_PR" FIXTURE_REVIEWS="$FIXTURE_REVIEWS" run_gate "$SCRATCH" 99 owner/repo 2>&1)
RC=$?
set -e
if [ "$RC" = 1 ] && echo "$OUT" | grep -q "BLOCKED"; then
  pass "Dependabot + stale-sha approval → exit 1 (HEAD-pinned)"
else
  fail "expected rc=1 BLOCKED; got rc=$RC"; echo "$OUT" | sed 's/^/      /' >&2
fi

# ---------------------------------------------------------------------------
# Test 4: APPROVED then later CHANGES_REQUESTED on HEAD → exit 1.
# ---------------------------------------------------------------------------
echo; echo "--- Test 4: Dependabot, latest-state CHANGES_REQUESTED on HEAD"
SCRATCH=$(make_scratch true false)
FIXTURE_PR=$(make_pr_fixture "$HEAD_SHA" "$DEPENDABOT")
FIXTURE_REVIEWS=$(make_reviews_fixture "$(jq -n --arg sha "$HEAD_SHA" '
  [
    { user:{login:"nathanpayne-claude"}, state:"APPROVED", commit_id:$sha, submitted_at:"2026-06-01T10:00:00Z" },
    { user:{login:"nathanpayne-claude"}, state:"CHANGES_REQUESTED", commit_id:$sha, submitted_at:"2026-06-01T11:00:00Z" }
  ]
')")
set +e
OUT=$(FIXTURE_PR="$FIXTURE_PR" FIXTURE_REVIEWS="$FIXTURE_REVIEWS" run_gate "$SCRATCH" 99 owner/repo 2>&1)
RC=$?
set -e
if [ "$RC" = 1 ] && echo "$OUT" | grep -q "BLOCKED"; then
  pass "Dependabot + stale APPROVED behind CHANGES_REQUESTED → exit 1"
else
  fail "expected rc=1 BLOCKED; got rc=$RC"; echo "$OUT" | sed 's/^/      /' >&2
fi

# ---------------------------------------------------------------------------
# Test 5: APPROVED on HEAD by a login NOT in available_reviewers → exit 1.
# ---------------------------------------------------------------------------
echo; echo "--- Test 5: Dependabot, APPROVED by non-reviewer login"
SCRATCH=$(make_scratch true false)
FIXTURE_PR=$(make_pr_fixture "$HEAD_SHA" "$DEPENDABOT")
FIXTURE_REVIEWS=$(make_reviews_fixture "$(jq -n --arg sha "$HEAD_SHA" '
  [{ user:{login:"some-random-collaborator"}, state:"APPROVED", commit_id:$sha, submitted_at:"2026-06-01T10:00:00Z" }]
')")
set +e
OUT=$(FIXTURE_PR="$FIXTURE_PR" FIXTURE_REVIEWS="$FIXTURE_REVIEWS" run_gate "$SCRATCH" 99 owner/repo 2>&1)
RC=$?
set -e
if [ "$RC" = 1 ] && echo "$OUT" | grep -q "BLOCKED"; then
  pass "Dependabot + non-reviewer approval → exit 1"
else
  fail "expected rc=1 BLOCKED; got rc=$RC"; echo "$OUT" | sed 's/^/      /' >&2
fi

# ---------------------------------------------------------------------------
# Test 6: External-review, gate disabled → exit 0.
# ---------------------------------------------------------------------------
echo; echo "--- Test 6: external-review, gate disabled"
SCRATCH=$(make_scratch false false)
FIXTURE_PR=$(make_pr_fixture "$HEAD_SHA" "nathanjohnpayne" "$EXT_LABEL")
set +e
OUT=$(FIXTURE_PR="$FIXTURE_PR" run_gate "$SCRATCH" 99 owner/repo 2>&1)
RC=$?
set -e
if [ "$RC" = 0 ] && echo "$OUT" | grep -q "PASS"; then
  pass "external-review + gate disabled → exit 0"
else
  fail "expected rc=0 PASS; got rc=$RC"; echo "$OUT" | sed 's/^/      /' >&2
fi

# ---------------------------------------------------------------------------
# Test 7: External-review, enabled, delegate returns 0 → exit 0.
# ---------------------------------------------------------------------------
echo; echo "--- Test 7: external-review, delegate clears"
SCRATCH=$(make_scratch false true)
FIXTURE_PR=$(make_pr_fixture "$HEAD_SHA" "nathanjohnpayne" "$EXT_LABEL")
set +e
OUT=$(FIXTURE_PR="$FIXTURE_PR" \
      MERGE_CLEARANCE_CODEX_CHECK_BIN="$STUB_DIR/codex-check-stub" \
      CODEX_STUB_RC=0 \
      run_gate "$SCRATCH" 99 owner/repo 2>&1)
RC=$?
set -e
if [ "$RC" = 0 ] && echo "$OUT" | grep -q "PASS"; then
  pass "external-review + delegate rc=0 → exit 0"
else
  fail "expected rc=0 PASS; got rc=$RC"; echo "$OUT" | sed 's/^/      /' >&2
fi

# ---------------------------------------------------------------------------
# Test 8 (#428 repro): delegate returns 1 (not cleared on HEAD) → exit 1.
# ---------------------------------------------------------------------------
echo; echo "--- Test 8: external-review, delegate blocks (#428)"
SCRATCH=$(make_scratch false true)
FIXTURE_PR=$(make_pr_fixture "$HEAD_SHA" "nathanjohnpayne" "$EXT_LABEL")
set +e
OUT=$(FIXTURE_PR="$FIXTURE_PR" \
      MERGE_CLEARANCE_CODEX_CHECK_BIN="$STUB_DIR/codex-check-stub" \
      CODEX_STUB_RC=1 \
      run_gate "$SCRATCH" 99 owner/repo 2>&1)
RC=$?
set -e
if [ "$RC" = 1 ] && echo "$OUT" | grep -q "BLOCKED"; then
  pass "external-review + delegate rc=1 → exit 1"
else
  fail "expected rc=1 BLOCKED; got rc=$RC"; echo "$OUT" | sed 's/^/      /' >&2
fi

# ---------------------------------------------------------------------------
# Test 9: delegate returns 3 (infra) → mapped to exit 2.
# ---------------------------------------------------------------------------
echo; echo "--- Test 9: external-review, delegate infra error"
SCRATCH=$(make_scratch false true)
FIXTURE_PR=$(make_pr_fixture "$HEAD_SHA" "nathanjohnpayne" "$EXT_LABEL")
set +e
OUT=$(FIXTURE_PR="$FIXTURE_PR" \
      MERGE_CLEARANCE_CODEX_CHECK_BIN="$STUB_DIR/codex-check-stub" \
      CODEX_STUB_RC=3 \
      run_gate "$SCRATCH" 99 owner/repo 2>&1)
RC=$?
set -e
if [ "$RC" = 2 ] && echo "$OUT" | grep -qi "rc=3"; then
  pass "external-review + delegate rc=3 → exit 2 (infra)"
else
  fail "expected rc=2; got rc=$RC"; echo "$OUT" | sed 's/^/      /' >&2
fi

# ---------------------------------------------------------------------------
# Test 10: Dependabot precedence — dependabot author + needs-external-review
#          → judged by the Dependabot rule (no APPROVED on HEAD → exit 1),
#          NOT routed to the external delegate.
# ---------------------------------------------------------------------------
echo; echo "--- Test 10: Dependabot precedence over external label"
SCRATCH=$(make_scratch true true)
FIXTURE_PR=$(make_pr_fixture "$HEAD_SHA" "$DEPENDABOT" "$EXT_LABEL")
FIXTURE_REVIEWS=$(make_reviews_fixture '[]')
set +e
# If it wrongly took the external path, the delegate stub (rc=0) would
# clear it. Point the delegate at a stub that would PASS so a precedence
# bug surfaces as a wrong exit 0.
OUT=$(FIXTURE_PR="$FIXTURE_PR" FIXTURE_REVIEWS="$FIXTURE_REVIEWS" \
      MERGE_CLEARANCE_CODEX_CHECK_BIN="$STUB_DIR/codex-check-stub" \
      CODEX_STUB_RC=0 \
      run_gate "$SCRATCH" 99 owner/repo 2>&1)
RC=$?
set -e
if [ "$RC" = 1 ] && echo "$OUT" | grep -q "BLOCKED" && echo "$OUT" | grep -qi "Dependabot"; then
  pass "Dependabot + external label → judged by Dependabot rule → exit 1"
else
  fail "expected rc=1 via Dependabot rule; got rc=$RC"; echo "$OUT" | sed 's/^/      /' >&2
fi

# ---------------------------------------------------------------------------
# Test 11: neither Dependabot nor external-review → exit 0 (not applicable).
# ---------------------------------------------------------------------------
echo; echo "--- Test 11: normal under-threshold PR → not applicable"
SCRATCH=$(make_scratch true true)
FIXTURE_PR=$(make_pr_fixture "$HEAD_SHA" "nathanjohnpayne" '[]')
FIXTURE_FILES=$(make_files_fixture '[{"filename":"README.md","additions":3,"deletions":1}]')
set +e
OUT=$(FIXTURE_PR="$FIXTURE_PR" FIXTURE_FILES="$FIXTURE_FILES" run_gate "$SCRATCH" 99 owner/repo 2>&1)
RC=$?
set -e
if [ "$RC" = 0 ] && echo "$OUT" | grep -qi "not applicable"; then
  pass "normal PR → exit 0 (not applicable)"
else
  fail "expected rc=0 not-applicable; got rc=$RC"; echo "$OUT" | sed 's/^/      /' >&2
fi

# ---------------------------------------------------------------------------
# Test 11e (#763 Codex P1): NON-DEFAULT base whose policy ENABLES the external
# gate, while the default-branch policy DISABLES it. Parsing the switch from
# the default-branch checkout made the whole external arm vacuous, so the
# required check passed a PR the base policy requires it to gate — the
# non-default-base bypass. The gate must read the switch (and the threshold)
# from the PR BASE policy and therefore delegate.
# ---------------------------------------------------------------------------
echo; echo "--- Test 11e: non-default base enables the gate the default branch disables (#763)"
SCRATCH=$(make_scratch true false)          # default-branch policy: gate OFF
BASE_POLICY="$WORKDIR/base-policy-on.yml"
cat >"$BASE_POLICY" <<'YAML'
external_review_threshold: 1
external_review_paths:
  - ".github/**"
available_reviewers:
  - nathanpayne-claude
  - nathanpayne-codex
codex:
  bot_login: "chatgpt-codex-connector[bot]"
  external_review_gate:
    enabled: true
dependabot:
  reviewer_gate:
    enabled: false
YAML
FIXTURE_PR=$(make_pr_fixture "$HEAD_SHA" "nathanjohnpayne" '[]' release/1.x main)
FIXTURE_FILES=$(make_files_fixture '[{"filename":"src/app.ts","additions":5,"deletions":1}]')
set +e
OUT=$(FIXTURE_PR="$FIXTURE_PR" FIXTURE_FILES="$FIXTURE_FILES" \
      FIXTURE_BASE_POLICY="$BASE_POLICY" \
      MERGE_CLEARANCE_CODEX_CHECK_BIN="$STUB_DIR/codex-check-stub" \
      CODEX_STUB_RC=1 \
      run_gate "$SCRATCH" 99 owner/repo 2>&1)
RC=$?
set -e
if [ "$RC" = 1 ] && echo "$OUT" | grep -qi "external review applies"; then
  pass "non-default base policy enables the gate the default branch disables (#763)"
else
  fail "expected rc=1 via base-policy gate-enable; got rc=$RC"; echo "$OUT" | sed 's/^/      /' >&2
fi

# ---------------------------------------------------------------------------
# Test 11f (#763): a PR onto the DEFAULT branch must not consult the contents
# API at all — the base policy IS the checked-out default-branch policy. This
# pins the scoping that keeps a new contents-API dependency off the path every
# consumer PR takes.
# ---------------------------------------------------------------------------
echo; echo "--- Test 11f: default-base PR does not fetch the base policy (#763)"
SCRATCH=$(make_scratch true true)
FIXTURE_PR=$(make_pr_fixture "$HEAD_SHA" "nathanjohnpayne" '[]' main main)
FIXTURE_FILES=$(make_files_fixture '[{"filename":"README.md","additions":3,"deletions":1}]')
: > "$WORKDIR/gh-calls.log"
set +e
OUT=$(FIXTURE_PR="$FIXTURE_PR" FIXTURE_FILES="$FIXTURE_FILES" run_gate "$SCRATCH" 99 owner/repo 2>&1)
RC=$?
set -e
if [ "$RC" = 0 ] && ! grep -q "contents/" "$WORKDIR/gh-calls.log"; then
  pass "default-base PR skips the base-policy contents fetch entirely (#763)"
else
  fail "expected rc=0 with no contents API call; got rc=$RC"; echo "$OUT" | sed 's/^/      /' >&2
fi

# ---------------------------------------------------------------------------
# Test 11b (#429 Codex P1): NO needs-external-review label, but the PR is
# intrinsically OVER THRESHOLD. The gate must DERIVE applicability (not
# trust the label) and delegate — so a delegate that blocks → exit 1. This
# is the stale-label race regression net: a label-only check would have
# fallen through to "not applicable" green here.
# ---------------------------------------------------------------------------
echo; echo "--- Test 11b: no label + over-threshold → derives applicability (#429)"
SCRATCH=$(make_scratch false true)
FIXTURE_PR=$(make_pr_fixture "$HEAD_SHA" "nathanjohnpayne" '[]')
FIXTURE_FILES=$(make_files_fixture '[{"filename":"src/big.ts","additions":250,"deletions":120}]')
set +e
OUT=$(FIXTURE_PR="$FIXTURE_PR" FIXTURE_FILES="$FIXTURE_FILES" \
      MERGE_CLEARANCE_CODEX_CHECK_BIN="$STUB_DIR/codex-check-stub" \
      CODEX_STUB_RC=1 \
      run_gate "$SCRATCH" 99 owner/repo 2>&1)
RC=$?
set -e
if [ "$RC" = 1 ] && echo "$OUT" | grep -q "BLOCKED" && echo "$OUT" | grep -qi "lines changed"; then
  pass "no label + over-threshold → external arm derived → delegate blocks → exit 1"
else
  fail "expected rc=1 BLOCKED via derived threshold; got rc=$RC"; echo "$OUT" | sed 's/^/      /' >&2
fi

# ---------------------------------------------------------------------------
# Test 11c: NO label, UNDER threshold, but touches a protected path
# (.github/**) → external arm applies via paths → delegate blocks → exit 1.
# ---------------------------------------------------------------------------
echo; echo "--- Test 11c: no label + protected path → derives applicability"
SCRATCH=$(make_scratch false true)
FIXTURE_PR=$(make_pr_fixture "$HEAD_SHA" "nathanjohnpayne" '[]')
FIXTURE_FILES=$(make_files_fixture '[{"filename":".github/workflows/x.yml","additions":4,"deletions":0}]')
set +e
OUT=$(FIXTURE_PR="$FIXTURE_PR" FIXTURE_FILES="$FIXTURE_FILES" \
      MERGE_CLEARANCE_CODEX_CHECK_BIN="$STUB_DIR/codex-check-stub" \
      CODEX_STUB_RC=1 \
      run_gate "$SCRATCH" 99 owner/repo 2>&1)
RC=$?
set -e
if [ "$RC" = 1 ] && echo "$OUT" | grep -q "BLOCKED" && echo "$OUT" | grep -qi "protected paths"; then
  pass "no label + protected path → external arm derived → delegate blocks → exit 1"
else
  fail "expected rc=1 BLOCKED via protected paths; got rc=$RC"; echo "$OUT" | sed 's/^/      /' >&2
fi

# ---------------------------------------------------------------------------
# Test 11d: external gate DISABLED + over-threshold no-label → exit 0
# (knob off short-circuits the whole arm; never reaches the delegate).
# ---------------------------------------------------------------------------
echo; echo "--- Test 11d: external gate disabled + over-threshold → not applicable"
SCRATCH=$(make_scratch false false)
FIXTURE_PR=$(make_pr_fixture "$HEAD_SHA" "nathanjohnpayne" '[]')
FIXTURE_FILES=$(make_files_fixture '[{"filename":"src/big.ts","additions":250,"deletions":120}]')
set +e
OUT=$(FIXTURE_PR="$FIXTURE_PR" FIXTURE_FILES="$FIXTURE_FILES" \
      MERGE_CLEARANCE_CODEX_CHECK_BIN="$STUB_DIR/codex-check-stub" \
      CODEX_STUB_RC=1 \
      run_gate "$SCRATCH" 99 owner/repo 2>&1)
RC=$?
set -e
if [ "$RC" = 0 ] && echo "$OUT" | grep -qi "not applicable"; then
  pass "external gate disabled → over-threshold no-label still exit 0"
else
  fail "expected rc=0 not-applicable; got rc=$RC"; echo "$OUT" | sed 's/^/      /' >&2
fi

# ---------------------------------------------------------------------------
# Test 12: malformed PR_NUMBER → exit 2.
# ---------------------------------------------------------------------------
echo; echo "--- Test 12: malformed PR_NUMBER"
SCRATCH=$(make_scratch true true)
set +e
OUT=$(run_gate "$SCRATCH" "not-a-number" owner/repo 2>&1)
RC=$?
set -e
if [ "$RC" = 2 ] && echo "$OUT" | grep -qi "PR_NUMBER must be an integer"; then
  pass "malformed PR_NUMBER → exit 2"
else
  fail "expected rc=2; got rc=$RC"; echo "$OUT" | sed 's/^/      /' >&2
fi

# ---------------------------------------------------------------------------
# Test 13: missing GH_TOKEN → exit 2.
# ---------------------------------------------------------------------------
echo; echo "--- Test 13: missing GH_TOKEN"
SCRATCH=$(make_scratch true true)
set +e
OUT=$(cd "$SCRATCH" && PATH="$STUB_DIR:$PATH" "$SCRIPT" 99 owner/repo 2>&1)
RC=$?
set -e
if [ "$RC" = 2 ] && echo "$OUT" | grep -q "GH_TOKEN is required"; then
  pass "missing GH_TOKEN → exit 2"
else
  fail "expected rc=2; got rc=$RC"; echo "$OUT" | sed 's/^/      /' >&2
fi

# ---------------------------------------------------------------------------
# Test 14: env-only PR_NUMBER + REPO → same behavior as positional.
# ---------------------------------------------------------------------------
echo; echo "--- Test 14: env-only PR_NUMBER + REPO"
SCRATCH=$(make_scratch true false)
FIXTURE_PR=$(make_pr_fixture "$HEAD_SHA" "$DEPENDABOT")
FIXTURE_REVIEWS=$(make_reviews_fixture "$(jq -n --arg sha "$HEAD_SHA" '
  [{ user:{login:"nathanpayne-codex"}, state:"APPROVED", commit_id:$sha, submitted_at:"2026-06-01T10:00:00Z" }]
')")
set +e
OUT=$(
  cd "$SCRATCH" && \
    PATH="$STUB_DIR:$PATH" \
    GH_TOKEN="dummy-token" \
    PR_NUMBER=99 REPO=owner/repo \
    FIXTURE_PR="$FIXTURE_PR" FIXTURE_REVIEWS="$FIXTURE_REVIEWS" \
    "$SCRIPT" 2>&1
)
RC=$?
set -e
if [ "$RC" = 0 ] && echo "$OUT" | grep -q "PASS"; then
  pass "env-only PR_NUMBER + REPO → exit 0"
else
  fail "expected rc=0 PASS; got rc=$RC"; echo "$OUT" | sed 's/^/      /' >&2
fi

# ---------------------------------------------------------------------------
# Test 15 (CodeRabbit ⚠️ #429): external_review_threshold ABSENT from config
# → defaults to 300 without crashing under set -euo pipefail. A small PR
# stays "not applicable" (exit 0); the grep|awk no-match must not abort.
# ---------------------------------------------------------------------------
echo; echo "--- Test 15: threshold key absent → default 300, no crash"
SCRATCH=$(mktemp -d "$WORKDIR/scratch.XXXXXX"); mkdir -p "$SCRATCH/.github"
cat >"$SCRATCH/.github/review-policy.yml" <<EOF
external_review_paths:
  - ".github/**"
available_reviewers:
  - nathanpayne-claude
codex:
  external_review_gate:
    enabled: true
dependabot:
  reviewer_gate:
    enabled: false
EOF
FIXTURE_PR=$(make_pr_fixture "$HEAD_SHA" "nathanjohnpayne" '[]')
FIXTURE_FILES=$(make_files_fixture '[{"filename":"README.md","additions":10,"deletions":2}]')
set +e
OUT=$(FIXTURE_PR="$FIXTURE_PR" FIXTURE_FILES="$FIXTURE_FILES" run_gate "$SCRATCH" 99 owner/repo 2>&1)
RC=$?
set -e
if [ "$RC" = 0 ] && echo "$OUT" | grep -qi "not applicable"; then
  pass "threshold absent → default 300 applied, small PR not applicable (no crash)"
else
  fail "expected rc=0 not-applicable; got rc=$RC"; echo "$OUT" | sed 's/^/      /' >&2
fi

# ---------------------------------------------------------------------------
# Test 16 (CodeRabbit ⚠️ Major #429): protected-paths matcher UNAVAILABLE →
# the gate must FAIL CLOSED (require external review), not skip to
# threshold-only. Point the helper dir at an empty location; an
# under-threshold PR must then still delegate (→ delegate blocks → exit 1).
# ---------------------------------------------------------------------------
echo; echo "--- Test 16: missing protected-paths helpers → fail closed"
SCRATCH=$(make_scratch false true)
EMPTY_WF=$(mktemp -d "$WORKDIR/emptywf.XXXXXX")
FIXTURE_PR=$(make_pr_fixture "$HEAD_SHA" "nathanjohnpayne" '[]')
FIXTURE_FILES=$(make_files_fixture '[{"filename":"README.md","additions":5,"deletions":1}]')
set +e
OUT=$(FIXTURE_PR="$FIXTURE_PR" FIXTURE_FILES="$FIXTURE_FILES" \
      MERGE_CLEARANCE_WORKFLOW_DIR="$EMPTY_WF" \
      MERGE_CLEARANCE_CODEX_CHECK_BIN="$STUB_DIR/codex-check-stub" \
      CODEX_STUB_RC=1 \
      run_gate "$SCRATCH" 99 owner/repo 2>&1)
RC=$?
set -e
if [ "$RC" = 1 ] && echo "$OUT" | grep -q "BLOCKED" && echo "$OUT" | grep -qi "failing closed"; then
  pass "missing matcher → fail closed → external arm applies → delegate blocks → exit 1"
else
  fail "expected rc=1 BLOCKED via fail-closed; got rc=$RC"; echo "$OUT" | sed 's/^/      /' >&2
fi

# ---------------------------------------------------------------------------
# Test 16b (#768 Codex P1): a MISSING policy resolver must fail CLOSED when the
# PR targets a NON-DEFAULT base. Test 16 covers the mirror case — on a default
# base the same absence is provably a no-op (the checked-out config already IS
# the governing policy) and must NOT hard-fail, or a mid-sync consumer becomes
# a red required check. The two together pin the asymmetry.
# ---------------------------------------------------------------------------
echo; echo "--- Test 16b: missing resolver + non-default base -> fail closed (#768)"
SCRATCH=$(make_scratch true true)
EMPTY_WF_16B=$(mktemp -d "$WORKDIR/emptywf16b.XXXXXX")
FIXTURE_PR=$(make_pr_fixture "$HEAD_SHA" "nathanjohnpayne" '[]' release/1.x main)
FIXTURE_FILES=$(make_files_fixture '[{"filename":"src/app.ts","additions":5,"deletions":1}]')
set +e
OUT=$(FIXTURE_PR="$FIXTURE_PR" FIXTURE_FILES="$FIXTURE_FILES" \
      MERGE_CLEARANCE_WORKFLOW_DIR="$EMPTY_WF_16B" \
      run_gate "$SCRATCH" 99 owner/repo 2>&1)
RC=$?
set -e
if [ "$RC" = 2 ] && echo "$OUT" | grep -q "refusing to evaluate it against the default-branch policy"; then
  pass "missing resolver + non-default base -> exit 2 (no silent policy downgrade)"
else
  fail "expected rc=2 fail-closed; got rc=$RC"; echo "$OUT" | sed 's/^/      /' >&2
fi


# ---------------------------------------------------------------------------
# Test 16c (#768 CodeRabbit Major): missing resolver + UNDETERMINABLE base must
# also fail closed. Test 16b covers a known non-default base; this covers the
# case where the base cannot be established at all. Degrading there is an
# assumption, not proof — the same "unknown is not proof" rule the resolver
# applies.
# ---------------------------------------------------------------------------
echo; echo "--- Test 16c: missing resolver + undeterminable base -> fail closed (#768)"
SCRATCH=$(make_scratch true true)
EMPTY_WF_16C=$(mktemp -d "$WORKDIR/emptywf16c.XXXXXX")
FIXTURE_PR_16C="$WORKDIR/pr-nobase.json"
jq -n --arg sha "$HEAD_SHA" '{number:99, head:{sha:$sha}, user:{login:"nathanjohnpayne"}, labels:[]}' >"$FIXTURE_PR_16C"
FIXTURE_FILES=$(make_files_fixture '[{"filename":"src/app.ts","additions":5,"deletions":1}]')
set +e
OUT=$(FIXTURE_PR="$FIXTURE_PR_16C" FIXTURE_FILES="$FIXTURE_FILES" \
      MERGE_CLEARANCE_WORKFLOW_DIR="$EMPTY_WF_16C" \
      run_gate "$SCRATCH" 99 owner/repo 2>&1)
RC=$?
set -e
if [ "$RC" = 2 ] && echo "$OUT" | grep -q "not provably against the default branch"; then
  pass "missing resolver + undeterminable base -> exit 2 (unknown is not proof)"
else
  fail "expected rc=2 fail-closed; got rc=$RC"; echo "$OUT" | sed 's/^/      /' >&2
fi


# ---------------------------------------------------------------------------
# Test 17 (#429): verified propagation PR — over-threshold, NO
# needs-external-review label, with a github-actions[bot] lane marker scoped
# to the CURRENT head → EXEMPT (not applicable), must NOT delegate.
# ---------------------------------------------------------------------------
echo; echo "--- Test 17: verified propagation lane (head-pinned) → exempt"
SCRATCH=$(make_scratch false true)
FIXTURE_PR=$(make_pr_fixture "$HEAD_SHA" "nathanjohnpayne" '[]')
FIXTURE_FILES=$(make_files_fixture '[{"filename":".github/workflows/x.yml","additions":400,"deletions":50}]')
FIXTURE_COMMENTS=$(make_comments_fixture "$(jq -n --arg h "$HEAD_SHA" '
  [{user:{login:"github-actions[bot]"}, body:("<!-- mergepath-propagation-lane verified-head=" + $h + " -->\nverified faithful mirror ✅")}]')")
set +e
OUT=$(FIXTURE_PR="$FIXTURE_PR" FIXTURE_FILES="$FIXTURE_FILES" FIXTURE_COMMENTS="$FIXTURE_COMMENTS" \
      MERGE_CLEARANCE_CODEX_CHECK_BIN="$STUB_DIR/codex-check-stub" \
      CODEX_STUB_RC=1 \
      run_gate "$SCRATCH" 99 owner/repo 2>&1)
RC=$?
set -e
if [ "$RC" = 0 ] && echo "$OUT" | grep -qi "not applicable"; then
  pass "verified propagation lane (current-head marker) → exempt (exit 0, no delegate)"
else
  fail "expected rc=0 not-applicable (exempt); got rc=$RC"; echo "$OUT" | sed 's/^/      /' >&2
fi

# ---------------------------------------------------------------------------
# Test 17b (#429 Codex round-3 P1 / nathanpayne-codex CHANGES_REQUESTED): a
# STALE lane marker — bot-authored but scoped to an OLD head — must NOT exempt
# a diverged current head. This is the head-pinning regression: an unscoped
# "was-ever-a-mirror" marker would have false-exempted here. Over-threshold +
# stale marker → still requires external → delegate blocks.
# ---------------------------------------------------------------------------
echo; echo "--- Test 17b: STALE bot marker (old head) + diverged head → NOT exempt"
SCRATCH=$(make_scratch false true)
FIXTURE_PR=$(make_pr_fixture "$HEAD_SHA" "nathanjohnpayne" '[]')
FIXTURE_FILES=$(make_files_fixture '[{"filename":".github/workflows/x.yml","additions":400,"deletions":50}]')
FIXTURE_COMMENTS=$(make_comments_fixture "$(jq -n --arg old "$OLD_SHA" '
  [{user:{login:"github-actions[bot]"}, body:("<!-- mergepath-propagation-lane verified-head=" + $old + " -->\nverified faithful mirror ✅")}]')")
set +e
OUT=$(FIXTURE_PR="$FIXTURE_PR" FIXTURE_FILES="$FIXTURE_FILES" FIXTURE_COMMENTS="$FIXTURE_COMMENTS" \
      MERGE_CLEARANCE_CODEX_CHECK_BIN="$STUB_DIR/codex-check-stub" \
      CODEX_STUB_RC=1 \
      run_gate "$SCRATCH" 99 owner/repo 2>&1)
RC=$?
set -e
if [ "$RC" = 1 ] && echo "$OUT" | grep -q "BLOCKED"; then
  pass "stale marker (old head) → NOT exempt → delegate blocks → exit 1 (head-pinned)"
else
  fail "expected rc=1 BLOCKED (stale marker ignored); got rc=$RC"; echo "$OUT" | sed 's/^/      /' >&2
fi

# ---------------------------------------------------------------------------
# Test 18: SPOOFED lane marker — current-head marker but authored by a NON-bot
# login → must NOT exempt (a PR author can't forge github-actions[bot]).
# Over-threshold + spoofed marker → still requires external → delegate blocks.
# ---------------------------------------------------------------------------
echo; echo "--- Test 18: spoofed (non-bot) lane marker → NOT exempt"
SCRATCH=$(make_scratch false true)
FIXTURE_PR=$(make_pr_fixture "$HEAD_SHA" "nathanjohnpayne" '[]')
FIXTURE_FILES=$(make_files_fixture '[{"filename":"src/big.ts","additions":250,"deletions":120}]')
FIXTURE_COMMENTS=$(make_comments_fixture "$(jq -n --arg h "$HEAD_SHA" '
  [{user:{login:"nathanjohnpayne"}, body:("<!-- mergepath-propagation-lane verified-head=" + $h + " --> nice try")}]')")
set +e
OUT=$(FIXTURE_PR="$FIXTURE_PR" FIXTURE_FILES="$FIXTURE_FILES" FIXTURE_COMMENTS="$FIXTURE_COMMENTS" \
      MERGE_CLEARANCE_CODEX_CHECK_BIN="$STUB_DIR/codex-check-stub" \
      CODEX_STUB_RC=1 \
      run_gate "$SCRATCH" 99 owner/repo 2>&1)
RC=$?
set -e
if [ "$RC" = 1 ] && echo "$OUT" | grep -q "BLOCKED"; then
  pass "spoofed non-bot marker → NOT exempt → delegate blocks → exit 1"
else
  fail "expected rc=1 BLOCKED (spoof ignored); got rc=$RC"; echo "$OUT" | sed 's/^/      /' >&2
fi

# ---------------------------------------------------------------------------
# Test 19 (#536): a SINGLE-QUOTED boolean — `enabled: 'true'` — must be
# parsed as the bare `true`, not the literal `'true'` that trips the
# true|false validator (exit 2). Before the nested_field quote-strip fix,
# this aborted with rc=2; now it reads `true` and the gate evaluates
# normally (APPROVED on HEAD → exit 0 PASS).
# ---------------------------------------------------------------------------
echo; echo "--- Test 19: single-quoted enabled: 'true' parses (no validator trip) (#536)"
SCRATCH=$(mktemp -d "$WORKDIR/scratch.XXXXXX"); mkdir -p "$SCRATCH/.github"
cat >"$SCRATCH/.github/review-policy.yml" <<EOF
external_review_threshold: 300
external_review_paths:
  - ".github/**"

available_reviewers:
  - nathanpayne-claude

codex:
  external_review_gate:
    enabled: 'false'

dependabot:
  reviewer_gate:
    enabled: 'true'
EOF
FIXTURE_PR=$(make_pr_fixture "$HEAD_SHA" "$DEPENDABOT")
FIXTURE_REVIEWS=$(make_reviews_fixture "$(jq -n --arg sha "$HEAD_SHA" '
  [{ user:{login:"nathanpayne-claude"}, state:"APPROVED", commit_id:$sha, submitted_at:"2026-06-01T10:00:00Z" }]
')")
set +e
OUT=$(FIXTURE_PR="$FIXTURE_PR" FIXTURE_REVIEWS="$FIXTURE_REVIEWS" run_gate "$SCRATCH" 99 owner/repo 2>&1)
RC=$?
set -e
if [ "$RC" = 0 ] && echo "$OUT" | grep -q "PASS"; then
  pass "single-quoted enabled: 'true' parsed as true → gate evaluates (exit 0)"
else
  fail "expected rc=0 PASS (single-quote stripped); got rc=$RC"; echo "$OUT" | sed 's/^/      /' >&2
fi

# ---------------------------------------------------------------------------
# Test 20 (#533): the check_merge_clearance_gate workflow-shape pre-flight
# must require the required-check name to be a JOB name, not just any
# indented name:. A step-level `name: Merge clearance gate` under a
# differently-named job MUST fail the check — otherwise a coincidentally
# named step could satisfy the branch-protection required-check contract
# while the actual job name silently drifted and de-wired the gate.
#
# These point the check's WORKFLOW at a fixture via MERGE_CLEARANCE_WORKFLOW.
# A failing workflow-shape pre-flight exits 1 BEFORE the check runs its
# fixture test suite, so this stays cheap (no recursion into this file).
# ---------------------------------------------------------------------------
# Re-entrancy guard: Case C below invokes check_merge_clearance_gate, which
# (on a clean pre-flight) runs THIS test file as its fixture suite. Skip the
# Test 20 block in that nested run to avoid infinite recursion — the nested
# run still exercises Tests 1-18.
if [ -z "${MCG_SKIP_FIX3_SELFTEST:-}" ]; then
echo; echo "--- Test 20: check_merge_clearance_gate job-name scope (#533)"
CHECK_BIN="$ROOT/scripts/ci/check_merge_clearance_gate"

# A minimal workflow that is otherwise shape-valid (all required triggers, a
# schedule cron, AND the #658 repository_dispatch trigger + dispatch-recheck
# job) so ONLY the job-name assertion is under test. Each Case appends the job
# under test after this header.
write_wf_header() {
  cat <<'WF'
name: Merge Clearance Gate
on:
  pull_request:
    types: [opened, synchronize]
  pull_request_review:
    types: [submitted]
  pull_request_review_comment:
    types: [created]
  repository_dispatch:
    types: [merge-clearance-recheck]
  schedule:
    - cron: "*/15 * * * *"
permissions:
  contents: read
jobs:
  # #658 dispatch-recheck job — present so this shape-valid header satisfies
  # the check's repository_dispatch + dispatch-wiring assertions; each Case
  # appends the job under test after it.
  dispatch-recheck:
    name: Merge clearance dispatch re-evaluation
    if: github.event_name == 'repository_dispatch'
    runs-on: ubuntu-latest
    steps:
      - env:
          PR: ${{ github.event.client_payload.pr }}
        run: echo "recheck $PR"
WF
}

# Case A (negative): the required name appears ONLY as a non-first step key
# (deeper indent, no leading dash) under a differently-named job. Must FAIL.
WF_STEP_NAME="$WORKDIR/wf-step-name.yml"
{
  write_wf_header
  cat <<'WF'
  some-other-job:
    name: A completely different job
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        name: Merge clearance gate
WF
} > "$WF_STEP_NAME"
set +e
OUT=$(MERGE_CLEARANCE_WORKFLOW="$WF_STEP_NAME" "$CHECK_BIN" 2>&1)
RC=$?
set -e
if [ "$RC" -ne 0 ] && echo "$OUT" | grep -q "must define a JOB named"; then
  pass "step-level name: Merge clearance gate under a differently-named job → check FAILS (#533)"
else
  fail "expected check FAIL on step-level name (#533); got rc=$RC"; echo "$OUT" | sed 's/^/      /' >&2
fi

# Case B (negative): job name DRIFTED, but a step is named like the required
# check. The drifted job + correctly-named step must still FAIL.
WF_DRIFT="$WORKDIR/wf-job-drift.yml"
{
  write_wf_header
  cat <<'WF'
  merge-clearance-gate:
    name: Merge clearance gate DRIFTED
    runs-on: ubuntu-latest
    steps:
      - name: Merge clearance gate
        run: echo step named like the required check
WF
} > "$WF_DRIFT"
set +e
OUT=$(MERGE_CLEARANCE_WORKFLOW="$WF_DRIFT" "$CHECK_BIN" 2>&1)
RC=$?
set -e
if [ "$RC" -ne 0 ] && echo "$OUT" | grep -q "must define a JOB named"; then
  pass "drifted job name + correctly-named step → check FAILS (#533)"
else
  fail "expected check FAIL on drifted job name (#533); got rc=$RC"; echo "$OUT" | sed 's/^/      /' >&2
fi

# Case C (positive control): a correctly-named JOB satisfies the job-name
# assertion. We only assert the job-name FAIL line was NOT emitted — we do
# not assert RC=0 here because the check also runs its own fixture suite,
# and a pre-existing unrelated failure there would couple this test to the
# state of unrelated fixtures (#556). The job-name assertion is structural;
# the RC of the nested fixture run is a separate concern.
WF_OK="$WORKDIR/wf-ok.yml"
{
  write_wf_header
  cat <<'WF'
  merge-clearance-gate:
    name: Merge clearance gate
    runs-on: ubuntu-latest
    steps:
      - name: Run gate
        run: echo ok
WF
} > "$WF_OK"
set +e
OUT=$(MCG_SKIP_FIX3_SELFTEST=1 MERGE_CLEARANCE_WORKFLOW="$WF_OK" "$CHECK_BIN" 2>&1)
RC=$?
set -e
if ! echo "$OUT" | grep -q "must define a JOB named" \
   && echo "$OUT" | grep -q "check_merge_clearance_gate:"; then
  pass "correctly-named JOB → job-name assertion passes (#533)"
else
  fail "expected job-name assertion to pass on a correct job name (#533); got rc=$RC"; echo "$OUT" | sed 's/^/      /' >&2
fi

# ---------------------------------------------------------------------------
# Test 21 (#658): the check must require the repository_dispatch marker
# re-trigger + its dispatch wiring. The propagation-lane verified-head marker
# is a GITHUB_TOKEN issue comment (creates no workflow run), so the lane sends
# a merge-clearance-recheck repository_dispatch instead; without the trigger a
# verified sync PR rides a fail-closed spurious-red gate until the */15 sweep.
# The dispatch-recheck job must accept the merge-clearance-recheck type AND
# resolve the PR from github.event.client_payload.pr.
# ---------------------------------------------------------------------------
echo; echo "--- Test 21: check requires the repository_dispatch marker re-trigger (#658)"

# Case A (negative): repository_dispatch trigger absent → check FAILS.
WF_NO_RD="$WORKDIR/wf-no-repo-dispatch.yml"
cat > "$WF_NO_RD" <<'WF'
name: Merge Clearance Gate
on:
  pull_request:
    types: [opened, synchronize]
  pull_request_review:
    types: [submitted]
  pull_request_review_comment:
    types: [created]
  schedule:
    - cron: "*/15 * * * *"
permissions:
  contents: read
jobs:
  merge-clearance-gate:
    name: Merge clearance gate
    runs-on: ubuntu-latest
    steps:
      - name: Run gate
        run: echo ok
WF
set +e
OUT=$(MERGE_CLEARANCE_WORKFLOW="$WF_NO_RD" "$CHECK_BIN" 2>&1)
RC=$?
set -e
if [ "$RC" -ne 0 ] && echo "$OUT" | grep -q "missing the repository_dispatch trigger"; then
  pass "workflow missing the repository_dispatch trigger → check FAILS (#658)"
else
  fail "expected check FAIL on missing repository_dispatch trigger (#658); got rc=$RC"; echo "$OUT" | sed 's/^/      /' >&2
fi

# Case B (negative): repository_dispatch present but the dispatch wiring absent
# (no merge-clearance-recheck type / no client_payload.pr resolution) → the
# re-trigger silently degrades to the sweep, so the check FAILS.
WF_NO_WIRING="$WORKDIR/wf-no-dispatch-wiring.yml"
cat > "$WF_NO_WIRING" <<'WF'
name: Merge Clearance Gate
on:
  pull_request:
    types: [opened, synchronize]
  pull_request_review:
    types: [submitted]
  pull_request_review_comment:
    types: [created]
  repository_dispatch:
    types: [some-other-event]
  schedule:
    - cron: "*/15 * * * *"
permissions:
  contents: read
jobs:
  merge-clearance-gate:
    name: Merge clearance gate
    runs-on: ubuntu-latest
    steps:
      - name: Run gate
        run: echo ok
WF
set +e
OUT=$(MERGE_CLEARANCE_WORKFLOW="$WF_NO_WIRING" "$CHECK_BIN" 2>&1)
RC=$?
set -e
if [ "$RC" -ne 0 ] && echo "$OUT" | grep -q "not wired for the marker re-trigger"; then
  pass "repository_dispatch without the merge-clearance-recheck wiring → check FAILS (#658)"
else
  fail "expected check FAIL on unwired repository_dispatch (#658); got rc=$RC"; echo "$OUT" | sed 's/^/      /' >&2
fi

# Case C (positive): the canonical header (repository_dispatch trigger +
# merge-clearance-recheck type + client_payload.pr wiring) plus a correctly-
# named job satisfies the #658 assertions — neither the missing-trigger nor the
# unwired FAIL line is emitted.
WF_RD_OK="$WORKDIR/wf-rd-ok.yml"
{
  write_wf_header
  cat <<'WF'
  merge-clearance-gate:
    name: Merge clearance gate
    runs-on: ubuntu-latest
    steps:
      - name: Run gate
        run: echo ok
WF
} > "$WF_RD_OK"
set +e
OUT=$(MCG_SKIP_FIX3_SELFTEST=1 MERGE_CLEARANCE_WORKFLOW="$WF_RD_OK" "$CHECK_BIN" 2>&1)
RC=$?
set -e
# Assert the check RAN to completion AND its pre-flight PASSED. A pre-flight
# failure for ANY reason (the #658 assertions or otherwise) emits
# "FAIL (pre-flight)", so this catches a checker that fails for a different
# reason (CodeRabbit) — stronger than only checking the two #658 lines are
# absent. RC is deliberately NOT asserted: the check also runs the nested
# fixture suite, whose unrelated failures must not couple this positive control
# (#556, same rationale as the job-name Case C above).
if echo "$OUT" | grep -q "check_merge_clearance_gate:" \
   && ! echo "$OUT" | grep -q "FAIL (pre-flight)"; then
  pass "repository_dispatch trigger + merge-clearance-recheck wiring present → check pre-flight (incl. #658 assertions) passes"
else
  fail "expected the check pre-flight to pass on the wired header; got rc=$RC"; echo "$OUT" | sed 's/^/      /' >&2
fi
fi  # end re-entrancy guard (MCG_SKIP_FIX3_SELFTEST)

# ---------------------------------------------------------------------------
# --derive-external-requiredness query mode (#620/#630): prints exactly
# true/false on stdout, exit 0; errors keep the die() exit codes so the
# consumer (agent-review.yml rc=5) fails closed. Semantics: true iff a
# NON-vacuous downstream review gate protects the current head.
# ---------------------------------------------------------------------------

echo; echo "--- Query 1: label present forces requiredness true"
SCRATCH=$(make_scratch false true)
FIXTURE_PR=$(make_pr_fixture "$HEAD_SHA" "someone" "$EXT_LABEL")
set +e
OUT=$(FIXTURE_PR="$FIXTURE_PR" run_gate "$SCRATCH" --derive-external-requiredness 99 owner/repo 2>/dev/null)
RC=$?
set -e
if [ "$RC" = 0 ] && [ "$OUT" = "true" ]; then
  pass "query: label present → prints exactly 'true'"
else
  fail "query: label present expected true/0; got rc=$RC out='$OUT'"
fi

echo; echo "--- Query 2: under threshold, no label, no marker → false"
SCRATCH=$(make_scratch false true)
FIXTURE_PR=$(make_pr_fixture "$HEAD_SHA" "someone")
FIXTURE_FILES=$(make_files_fixture '[{"filename":"README.md","additions":3,"deletions":1}]')
FIXTURE_COMMENTS=$(make_comments_fixture '[]')
set +e
OUT=$(FIXTURE_PR="$FIXTURE_PR" FIXTURE_FILES="$FIXTURE_FILES" FIXTURE_COMMENTS="$FIXTURE_COMMENTS" \
  run_gate "$SCRATCH" --derive-external-requiredness 99 owner/repo 2>/dev/null)
RC=$?
set -e
if [ "$RC" = 0 ] && [ "$OUT" = "false" ]; then
  pass "query: under-threshold plain PR → prints exactly 'false'"
else
  fail "query: under-threshold expected false/0; got rc=$RC out='$OUT'"
fi

echo; echo "--- Query 3: over threshold → true"
SCRATCH=$(make_scratch false true)
FIXTURE_PR=$(make_pr_fixture "$HEAD_SHA" "someone")
FIXTURE_FILES=$(make_files_fixture '[{"filename":"big.txt","additions":400,"deletions":0}]')
FIXTURE_COMMENTS=$(make_comments_fixture '[]')
set +e
OUT=$(FIXTURE_PR="$FIXTURE_PR" FIXTURE_FILES="$FIXTURE_FILES" FIXTURE_COMMENTS="$FIXTURE_COMMENTS" \
  run_gate "$SCRATCH" --derive-external-requiredness 99 owner/repo 2>/dev/null)
RC=$?
set -e
if [ "$RC" = 0 ] && [ "$OUT" = "true" ]; then
  pass "query: over-threshold → prints exactly 'true'"
else
  fail "query: over-threshold expected true/0; got rc=$RC out='$OUT'"
fi

echo; echo "--- Query 4: protected path under threshold → true"
SCRATCH=$(make_scratch false true)
FIXTURE_PR=$(make_pr_fixture "$HEAD_SHA" "someone")
FIXTURE_FILES=$(make_files_fixture '[{"filename":"src/auth/token.js","additions":2,"deletions":0}]')
FIXTURE_COMMENTS=$(make_comments_fixture '[]')
set +e
OUT=$(FIXTURE_PR="$FIXTURE_PR" FIXTURE_FILES="$FIXTURE_FILES" FIXTURE_COMMENTS="$FIXTURE_COMMENTS" \
  run_gate "$SCRATCH" --derive-external-requiredness 99 owner/repo 2>/dev/null)
RC=$?
set -e
if [ "$RC" = 0 ] && [ "$OUT" = "true" ]; then
  pass "query: protected path → prints exactly 'true'"
else
  fail "query: protected path expected true/0; got rc=$RC out='$OUT'"
fi

echo; echo "--- Query 5: verified lane marker for HEAD, label absent → false"
SCRATCH=$(make_scratch false true)
FIXTURE_PR=$(make_pr_fixture "$HEAD_SHA" "someone")
FIXTURE_FILES=$(make_files_fixture '[{"filename":".github/workflows/x.yml","additions":500,"deletions":0}]')
FIXTURE_COMMENTS=$(make_comments_fixture "$(jq -n --arg sha "$HEAD_SHA" '
  [{ user:{login:"github-actions[bot]"}, body:("<!-- mergepath-propagation-lane verified-head=" + $sha + " -->") }]
')")
set +e
OUT=$(FIXTURE_PR="$FIXTURE_PR" FIXTURE_FILES="$FIXTURE_FILES" FIXTURE_COMMENTS="$FIXTURE_COMMENTS" \
  run_gate "$SCRATCH" --derive-external-requiredness 99 owner/repo 2>/dev/null)
RC=$?
set -e
if [ "$RC" = 0 ] && [ "$OUT" = "false" ]; then
  pass "query: lane-exempt verified head → prints exactly 'false' (vacuous downstream)"
else
  fail "query: lane-exempt expected false/0; got rc=$RC out='$OUT'"
fi

echo; echo "--- Query 5b: indeterminate marker read → nonzero, NOT 'true' (automated-4b r5 P1)"
# An over-threshold PR (would derive true from threshold if it fell through)
# whose comments API fails: query mode must fail closed (nonzero) rather than
# print the unsafe 'true' that would authorize the rc=5 CodeRabbit downgrade.
SCRATCH=$(make_scratch false true)
FIXTURE_PR=$(make_pr_fixture "$HEAD_SHA" "someone")
FIXTURE_FILES=$(make_files_fixture '[{"filename":".github/workflows/x.yml","additions":500,"deletions":0}]')
set +e
OUT=$(FIXTURE_PR="$FIXTURE_PR" FIXTURE_FILES="$FIXTURE_FILES" FIXTURE_COMMENTS_FAIL=1 \
  run_gate "$SCRATCH" --derive-external-requiredness 99 owner/repo 2>/dev/null)
RC=$?
set -e
if [ "$RC" != 0 ] && [ "$OUT" != "true" ]; then
  pass "query: indeterminate marker read → nonzero exit and no 'true' (caller fails closed → rc=5 blocks)"
else
  fail "query: indeterminate marker read expected nonzero and not 'true'; got rc=$RC out='$OUT'"
fi

echo; echo "--- Query 6: external gate disabled → false"
SCRATCH=$(make_scratch false false)
FIXTURE_PR=$(make_pr_fixture "$HEAD_SHA" "someone" "$EXT_LABEL")
set +e
OUT=$(FIXTURE_PR="$FIXTURE_PR" run_gate "$SCRATCH" --derive-external-requiredness 99 owner/repo 2>/dev/null)
RC=$?
set -e
if [ "$RC" = 0 ] && [ "$OUT" = "false" ]; then
  pass "query: external gate disabled → prints exactly 'false' (even with the label present)"
else
  fail "query: gate-disabled expected false/0; got rc=$RC out='$OUT'"
fi

echo; echo "--- Query 7: Dependabot author → always false (reviewer gate is not a Codex gate; automated-4b P1)"
# The Dependabot reviewer gate blocks on a reviewer-identity APPROVED, not on
# Codex, and Codex does not review Dependabot PRs — so for the rc=5 branch's
# Codex-requiredness question the answer is false regardless of the knob.
# (The FULL gate still enforces the reviewer-APPROVED requirement; that is
# covered by the non-query Dependabot tests above.)
SCRATCH=$(make_scratch true false)
FIXTURE_PR=$(make_pr_fixture "$HEAD_SHA" "$DEPENDABOT")
set +e
OUT=$(FIXTURE_PR="$FIXTURE_PR" run_gate "$SCRATCH" --derive-external-requiredness 99 owner/repo 2>/dev/null)
RC=$?
set -e
SCRATCH2=$(make_scratch false false)
set +e
OUT2=$(FIXTURE_PR="$FIXTURE_PR" run_gate "$SCRATCH2" --derive-external-requiredness 99 owner/repo 2>/dev/null)
RC2=$?
set -e
if [ "$RC" = 0 ] && [ "$OUT" = "false" ] && [ "$RC2" = 0 ] && [ "$OUT2" = "false" ]; then
  pass "query: dependabot → false whether the reviewer gate is enabled or disabled (not a Codex gate)"
else
  fail "query: dependabot expected false/0 both ways; got rc=$RC out='$OUT' rc2=$RC2 out2='$OUT2'"
fi

echo; echo "--- Query 8: PR fetch failure → nonzero (caller fails closed)"
SCRATCH=$(make_scratch false true)
set +e
OUT=$(FIXTURE_PR="/nonexistent-fixture" run_gate "$SCRATCH" --derive-external-requiredness 99 owner/repo 2>/dev/null)
RC=$?
set -e
if [ "$RC" != 0 ]; then
  pass "query: unfetchable PR metadata → nonzero exit (fail-closed contract)"
else
  fail "query: expected nonzero on PR fetch failure; got rc=0 out='$OUT'"
fi

# ---------------------------------------------------------------------------
# --derive-rate-limit-protection query mode (#713, tightened by #772): prints
# exactly true/false. `true` means the auto-merge rc=5 path is protected either
# by an ENFORCED merge-clearance external gate — enabled in policy AND observably
# a required status check on the PR's base branch — or by already-satisfied
# current-head Codex/Phase-4b clearance. Config-enabled alone is not enforcement
# (#772): mergepath itself runs with the switch on while `Merge clearance gate`
# is absent from base-branch protection.
# ---------------------------------------------------------------------------


echo; echo "--- Protection 1 (#772): enforced required check (classic protection) + protected path → true"
SCRATCH=$(make_scratch false true)
FIXTURE_PR=$(make_pr_fixture "$HEAD_SHA" "someone")
FIXTURE_FILES=$(make_files_fixture '[{"filename":"src/auth/token.js","additions":2,"deletions":0}]')
FIXTURE_COMMENTS=$(make_comments_fixture '[]')
FIXTURE_PROTECTION=$(make_protection_fixture "$(jq -n --arg n "$GATE_CHECK_NAME" '["lint", $n]')")
set +e
OUT=$(FIXTURE_PR="$FIXTURE_PR" FIXTURE_FILES="$FIXTURE_FILES" FIXTURE_COMMENTS="$FIXTURE_COMMENTS" \
      FIXTURE_PROTECTION="$FIXTURE_PROTECTION" \
  run_gate "$SCRATCH" --derive-rate-limit-protection 99 owner/repo 2>/dev/null)
RC=$?
set -e
if [ "$RC" = 0 ] && [ "$OUT" = "true" ]; then
  pass "protection: enforced required check + protected path → true (arm 1)"
else
  fail "protection: enforced gate expected true/0; got rc=$RC out='$OUT'"
fi

echo; echo "--- Protection 1b (#772): enforced via a repository RULESET (no classic protection) → true"
# Classic protection does not surface on repos/{o}/{r}/rules/branches/{branch}
# and rulesets do not surface on ref.refUpdateRule, so the probe unions both.
SCRATCH=$(make_scratch false true)
FIXTURE_PR=$(make_pr_fixture "$HEAD_SHA" "someone")
FIXTURE_FILES=$(make_files_fixture '[{"filename":"src/auth/token.js","additions":2,"deletions":0}]')
FIXTURE_COMMENTS=$(make_comments_fixture '[]')
FIXTURE_PROTECTION=$(make_protection_fixture '["lint"]')
FIXTURE_RULESETS=$(make_rulesets_fixture "$(jq -n --arg n "$GATE_CHECK_NAME" '[$n]')")
set +e
OUT=$(FIXTURE_PR="$FIXTURE_PR" FIXTURE_FILES="$FIXTURE_FILES" FIXTURE_COMMENTS="$FIXTURE_COMMENTS" \
      FIXTURE_PROTECTION="$FIXTURE_PROTECTION" FIXTURE_RULESETS="$FIXTURE_RULESETS" \
  run_gate "$SCRATCH" --derive-rate-limit-protection 99 owner/repo 2>/dev/null)
RC=$?
set -e
if [ "$RC" = 0 ] && [ "$OUT" = "true" ]; then
  pass "protection: ruleset-enforced required check → true (both surfaces unioned)"
else
  fail "protection: ruleset-enforced gate expected true/0; got rc=$RC out='$OUT'"
fi

echo; echo "--- Protection 1c (#772 REPRO): config-enabled but NOT an enforced required check, above threshold, no clearance → false"
# The #772 bug: EXTERNAL_GATE_ENABLED=true short-circuited to `true` without
# checking whether `Merge clearance gate` can actually block the merge. Base
# protection here requires only the mergepath-real contexts, so the gate is
# vacuous and the rc=5 CodeRabbit downgrade must NOT be authorized.
SCRATCH=$(make_scratch false true)
FIXTURE_PR=$(make_pr_fixture "$HEAD_SHA" "someone")
FIXTURE_FILES=$(make_files_fixture '[{"filename":"big.txt","additions":400,"deletions":0}]')
FIXTURE_COMMENTS=$(make_comments_fixture '[]')
FIXTURE_PROTECTION=$(make_protection_fixture '["Label Gate","Self-Review Required","lint"]')
: > "$WORKDIR/protection-1c-stderr.log"
set +e
OUT=$(FIXTURE_PR="$FIXTURE_PR" FIXTURE_FILES="$FIXTURE_FILES" FIXTURE_COMMENTS="$FIXTURE_COMMENTS" \
      FIXTURE_PROTECTION="$FIXTURE_PROTECTION" \
      MERGE_CLEARANCE_CODEX_CHECK_BIN="$STUB_DIR/codex-check-stub" CODEX_STUB_REQUIRE_HEAD_PIN=1 CODEX_STUB_RC=1 \
  run_gate "$SCRATCH" --derive-rate-limit-protection 99 owner/repo 2>"$WORKDIR/protection-1c-stderr.log")
RC=$?
set -e
if [ "$RC" = 0 ] && [ "$OUT" = "false" ]; then
  pass "protection: config-enabled but unenforced gate + no current-head clearance → false (#772)"
else
  fail "protection: unenforced gate expected false/0; got rc=$RC out='$OUT'"
fi

# The not-enforced diagnostic must render each observed context QUOTED: these
# are multi-word names, and a space-joined list cannot express whether
# `Merge clearance gate` is present as one entry or as fragments of its
# neighbours — the one thing the line exists to let an operator check.
if grep -qF "observed: ['Label Gate', 'Self-Review Required', 'lint']" "$WORKDIR/protection-1c-stderr.log"; then
  pass "protection: not-enforced diagnostic quotes each observed context (multi-word names stay parseable)"
else
  fail "protection: expected a quoted, comma-separated observed-context list on stderr"
  sed 's/^/      /' "$WORKDIR/protection-1c-stderr.log" >&2
fi

echo; echo "--- Protection 1d (#772): config-enabled but unenforced + current-head clearance satisfied → true (#714 survives)"
SCRATCH=$(make_scratch false true)
FIXTURE_PR=$(make_pr_fixture "$HEAD_SHA" "someone")
FIXTURE_FILES=$(make_files_fixture '[{"filename":"big.txt","additions":400,"deletions":0}]')
FIXTURE_COMMENTS=$(make_comments_fixture '[]')
FIXTURE_PROTECTION=$(make_protection_fixture '["Label Gate","Self-Review Required","lint"]')
set +e
OUT=$(FIXTURE_PR="$FIXTURE_PR" FIXTURE_FILES="$FIXTURE_FILES" FIXTURE_COMMENTS="$FIXTURE_COMMENTS" \
      FIXTURE_PROTECTION="$FIXTURE_PROTECTION" \
      MERGE_CLEARANCE_CODEX_CHECK_BIN="$STUB_DIR/codex-check-stub" CODEX_STUB_REQUIRE_HEAD_PIN=1 CODEX_STUB_RC=0 \
      CODEX_STUB_STDOUT='delegate stdout must not pollute query output' \
  run_gate "$SCRATCH" --derive-rate-limit-protection 99 owner/repo 2>/dev/null)
RC=$?
set -e
if [ "$RC" = 0 ] && [ "$OUT" = "true" ]; then
  pass "protection: unenforced gate but satisfied current-head clearance → true (arm 2, #714 preserved)"
else
  fail "protection: unenforced-but-cleared expected true/0; got rc=$RC out='$OUT'"
fi

echo; echo "--- Protection 1e (#772): enforcement undeterminable (both API surfaces fail) + no clearance → false, error on stderr only"
SCRATCH=$(make_scratch false true)
FIXTURE_PR=$(make_pr_fixture "$HEAD_SHA" "someone")
FIXTURE_FILES=$(make_files_fixture '[{"filename":"big.txt","additions":400,"deletions":0}]')
FIXTURE_COMMENTS=$(make_comments_fixture '[]')
: > "$WORKDIR/protection-stderr.log"
set +e
OUT=$(FIXTURE_PR="$FIXTURE_PR" FIXTURE_FILES="$FIXTURE_FILES" FIXTURE_COMMENTS="$FIXTURE_COMMENTS" \
      FIXTURE_PROTECTION_FAIL=1 FIXTURE_RULESETS_FAIL=1 \
      MERGE_CLEARANCE_CODEX_CHECK_BIN="$STUB_DIR/codex-check-stub" CODEX_STUB_REQUIRE_HEAD_PIN=1 CODEX_STUB_RC=1 \
  run_gate "$SCRATCH" --derive-rate-limit-protection 99 owner/repo 2>"$WORKDIR/protection-stderr.log")
RC=$?
set -e
if [ "$RC" = 0 ] && [ "$OUT" = "false" ] \
    && grep -q "enforcement probe: classic branch-protection read failed" "$WORKDIR/protection-stderr.log" \
    && grep -q "enforcement probe: ruleset read failed" "$WORKDIR/protection-stderr.log"; then
  pass "protection: undeterminable enforcement → false, both API errors on stderr (stdout stays pure)"
else
  fail "protection: undeterminable enforcement expected false/0 with stderr diagnostics; got rc=$RC out='$OUT'"
  sed 's/^/      /' "$WORKDIR/protection-stderr.log" >&2
fi

echo; echo "--- Protection 1f (#772): propagation-lane-exempt head short-circuits to false before the enforcement probe"
SCRATCH=$(make_scratch false true)
FIXTURE_PR=$(make_pr_fixture "$HEAD_SHA" "someone")
FIXTURE_FILES=$(make_files_fixture '[{"filename":".github/workflows/x.yml","additions":500,"deletions":0}]')
FIXTURE_COMMENTS=$(make_comments_fixture "$(jq -n --arg sha "$HEAD_SHA" '
  [{ user:{login:"github-actions[bot]"}, body:("<!-- mergepath-propagation-lane verified-head=" + $sha + " -->") }]
')")
# Enforced-gate fixture on purpose: if the lane exemption did NOT short-circuit,
# arm 1 would find the context and wrongly print true.
FIXTURE_PROTECTION=$(make_protection_fixture "$(jq -n --arg n "$GATE_CHECK_NAME" '[$n]')")
: > "$WORKDIR/gh-calls.log"
set +e
OUT=$(FIXTURE_PR="$FIXTURE_PR" FIXTURE_FILES="$FIXTURE_FILES" FIXTURE_COMMENTS="$FIXTURE_COMMENTS" \
      FIXTURE_PROTECTION="$FIXTURE_PROTECTION" \
  run_gate "$SCRATCH" --derive-rate-limit-protection 99 owner/repo 2>/dev/null)
RC=$?
set -e
if [ "$RC" = 0 ] && [ "$OUT" = "false" ] && ! grep -q "graphql" "$WORKDIR/gh-calls.log"; then
  pass "protection: lane-exempt verified head → false without consulting the enforcement probe"
else
  fail "protection: lane-exempt expected false/0 and no enforcement probe; got rc=$RC out='$OUT'"
  sed 's/^/      /' "$WORKDIR/gh-calls.log" >&2
fi

echo; echo "--- Protection 1g (#772 review): a required_status_checks rule on ruleset PAGE 2 is still seen"
# repos/{o}/{r}/rules/branches/{b} pages at 30 applicable rules. Stacked
# rulesets can push the rule carrying `Merge clearance gate` past page 1, and a
# truncated page is indistinguishable from an absent rule — same empty match,
# same log line — so the probe would silently report "not enforced" forever on
# such a repo. The stub emits page 2 ONLY when --paginate was passed, so this
# case fails (false, via the arm-2 stub's rc=1) against an unpaginated read.
SCRATCH=$(make_scratch false true)
FIXTURE_PR=$(make_pr_fixture "$HEAD_SHA" "someone")
FIXTURE_FILES=$(make_files_fixture '[{"filename":"src/auth/token.js","additions":2,"deletions":0}]')
FIXTURE_COMMENTS=$(make_comments_fixture '[]')
FIXTURE_PROTECTION=$(make_protection_fixture '["lint"]')
FIXTURE_RULESETS=$(make_rulesets_fixture '["some-other-check"]')
FIXTURE_RULESETS_PAGE2=$(make_rulesets_fixture "$(jq -n --arg n "$GATE_CHECK_NAME" '[$n]')")
set +e
OUT=$(FIXTURE_PR="$FIXTURE_PR" FIXTURE_FILES="$FIXTURE_FILES" FIXTURE_COMMENTS="$FIXTURE_COMMENTS" \
      FIXTURE_PROTECTION="$FIXTURE_PROTECTION" FIXTURE_RULESETS="$FIXTURE_RULESETS" \
      FIXTURE_RULESETS_PAGE2="$FIXTURE_RULESETS_PAGE2" \
      MERGE_CLEARANCE_CODEX_CHECK_BIN="$STUB_DIR/codex-check-stub" CODEX_STUB_REQUIRE_HEAD_PIN=1 CODEX_STUB_RC=1 \
  run_gate "$SCRATCH" --derive-rate-limit-protection 99 owner/repo 2>/dev/null)
RC=$?
set -e
if [ "$RC" = 0 ] && [ "$OUT" = "true" ]; then
  pass "protection: ruleset rule on page 2 → true (surface 2 paginates; multi-page output slurped)"
else
  fail "protection: paginated ruleset expected true/0; got rc=$RC out='$OUT'"
fi

echo; echo "--- Protection 1h (#772 review): a URL-significant base ref is percent-encoded in the ruleset URL"
# A branch name permits characters a URL path segment does not. `#` truncates
# the request at a fragment, so `feat#2` would query `.../rules/branches/feat`
# — a DIFFERENT branch, whose empty result is indistinguishable from "not
# enforced". On a ruleset-only repo the classic surface cannot compensate, so
# a genuinely enforced gate reads as unproven. `/` must stay raw: GitHub
# addresses nested branch names with literal slashes in this endpoint.
SCRATCH=$(make_scratch false true)
FIXTURE_PR=$(make_pr_fixture "$HEAD_SHA" "someone" '[]' 'feat#2' 'feat#2')
FIXTURE_FILES=$(make_files_fixture '[{"filename":"src/auth/token.js","additions":2,"deletions":0}]')
FIXTURE_COMMENTS=$(make_comments_fixture '[]')
FIXTURE_PROTECTION=$(make_protection_fixture '["lint"]')
FIXTURE_RULESETS=$(make_rulesets_fixture "$(jq -n --arg n "$GATE_CHECK_NAME" '[$n]')")
# run_gate pins GH_CALLS_LOG to this path, so truncate it and read it back
# rather than trying to override the variable from out here.
ENC_LOG="$WORKDIR/gh-calls.log"
: >"$ENC_LOG"
set +e
OUT=$(FIXTURE_PR="$FIXTURE_PR" FIXTURE_FILES="$FIXTURE_FILES" FIXTURE_COMMENTS="$FIXTURE_COMMENTS" \
      FIXTURE_PROTECTION="$FIXTURE_PROTECTION" FIXTURE_RULESETS="$FIXTURE_RULESETS" \
      MERGE_CLEARANCE_CODEX_CHECK_BIN="$STUB_DIR/codex-check-stub" CODEX_STUB_REQUIRE_HEAD_PIN=1 CODEX_STUB_RC=1 \
      run_gate "$SCRATCH" --derive-rate-limit-protection 99 owner/repo 2>/dev/null)
RC=$?
set -e
if grep -q 'rules/branches/feat%232' "$ENC_LOG"; then
  pass "protection: URL-significant base ref percent-encoded in the ruleset path (feat#2 → feat%232)"
else
  fail "protection: ruleset URL not percent-encoded; log had: $(grep -o 'rules/branches/[^[:space:]]*' "$ENC_LOG" | head -1)"
fi
if grep -q 'rules/branches/feat[^%]' "$ENC_LOG"; then
  fail "protection: raw '#' reached the ruleset URL — the request would truncate at a fragment"
else
  pass "protection: no raw fragment-truncating base ref reached the ruleset URL"
fi
if [ "$RC" = 0 ] && [ "$OUT" = "true" ]; then
  pass "protection: enforced gate on a URL-significant base ref still resolves to true"
else
  fail "protection: URL-significant base ref expected true/0; got rc=$RC out='$OUT'"
fi

echo; echo "--- Protection 1k (#772 r3 P1): classic protection with enforce_admins=false is not enforcement"
# A required context does not bind the MERGING identity if admins are exempt.
# This probe runs under the reviewer/CI token; the final `gh pr merge` runs
# under the author token, so a context merely visible here would let an admin
# author merge on a downgraded rate-limit stall with no bot review.
SCRATCH=$(make_scratch false true)
FIXTURE_PR=$(make_pr_fixture "$HEAD_SHA" "someone")
FIXTURE_FILES=$(make_files_fixture '[{"filename":"src/auth/token.js","additions":2,"deletions":0}]')
FIXTURE_COMMENTS=$(make_comments_fixture '[]')
FIXTURE_PROTECTION=$(make_protection_fixture "$(jq -n --arg n "$GATE_CHECK_NAME" '[$n]')")
set +e
OUT=$(FIXTURE_PR="$FIXTURE_PR" FIXTURE_FILES="$FIXTURE_FILES" FIXTURE_COMMENTS="$FIXTURE_COMMENTS" \
      FIXTURE_PROTECTION="$FIXTURE_PROTECTION" FIXTURE_ADMIN_ENFORCE=false \
      MERGE_CLEARANCE_CODEX_CHECK_BIN="$STUB_DIR/codex-check-stub" CODEX_STUB_REQUIRE_HEAD_PIN=1 CODEX_STUB_RC=1 \
      run_gate "$SCRATCH" --derive-rate-limit-protection 99 owner/repo 2>"$WORKDIR/p1k.err")
RC=$?
set -e
if [ "$RC" = 0 ] && [ "$OUT" = "false" ]; then
  pass "protection: classic required context with enforce_admins=false → not counted → false"
else
  fail "protection: enforce_admins=false expected false/0; got rc=$RC out='$OUT'"
fi
# jq's `//` treats false as empty, so without an explicit boolean type check
# this case silently takes the "could not determine" path and 1k/1l become the
# same test. Assert the DISTINCT diagnostic so they stay separable.
if grep -q "enforce_admins=false" "$WORKDIR/p1k.err"; then
  pass "protection: enforce_admins=false emits its own diagnostic (not the undeterminable one)"
else
  fail "protection: expected an enforce_admins=false diagnostic; got: $(tr '\n' ' ' <"$WORKDIR/p1k.err" | tail -c 300)"
fi

echo; echo "--- Protection 1l (#772 r3 P1): unreadable admin-exemption state (the CI reality) is not proof"
# The admin-only protection endpoint 404s for the write-scoped reviewer PAT
# this query actually runs under, so on the normal CI path the classic surface
# must contribute nothing rather than being trusted.
SCRATCH=$(make_scratch false true)
FIXTURE_PR=$(make_pr_fixture "$HEAD_SHA" "someone")
FIXTURE_FILES=$(make_files_fixture '[{"filename":"src/auth/token.js","additions":2,"deletions":0}]')
FIXTURE_COMMENTS=$(make_comments_fixture '[]')
FIXTURE_PROTECTION=$(make_protection_fixture "$(jq -n --arg n "$GATE_CHECK_NAME" '[$n]')")
set +e
OUT=$(FIXTURE_PR="$FIXTURE_PR" FIXTURE_FILES="$FIXTURE_FILES" FIXTURE_COMMENTS="$FIXTURE_COMMENTS" \
      FIXTURE_PROTECTION="$FIXTURE_PROTECTION" FIXTURE_ADMIN_ENFORCE= \
      MERGE_CLEARANCE_CODEX_CHECK_BIN="$STUB_DIR/codex-check-stub" CODEX_STUB_REQUIRE_HEAD_PIN=1 CODEX_STUB_RC=1 \
      run_gate "$SCRATCH" --derive-rate-limit-protection 99 owner/repo 2>"$WORKDIR/p1l.err")
RC=$?
set -e
if [ "$RC" = 0 ] && [ "$OUT" = "false" ]; then
  pass "protection: unreadable enforce_admins → classic surface not counted → false"
else
  fail "protection: unreadable enforce_admins expected false/0; got rc=$RC out='$OUT'"
fi
if grep -q "unreadable with this token" "$WORKDIR/p1l.err"; then
  pass "protection: unreadable admin-exemption emits the token-scope diagnostic"
else
  fail "protection: expected an unreadable-token diagnostic; got: $(tr '\n' ' ' <"$WORKDIR/p1l.err" | tail -c 300)"
fi

echo; echo "--- Protection 1i (#772 r2 P1): a ruleset the merging identity can BYPASS is not enforcement"
# `rules/branches` filters to rules enforced on the REQUESTING identity (the CI
# reviewer token), but the account that runs the final `gh pr merge` is the
# AUTHOR identity. A ruleset listing that author in bypass_actors still appears
# here while constraining nothing — counting it would reproduce the exact
# defect this PR removes. bypass_actors is not on this endpoint, so the ruleset
# object is fetched and required to have none.
SCRATCH=$(make_scratch false true)
FIXTURE_PR=$(make_pr_fixture "$HEAD_SHA" "someone")
FIXTURE_FILES=$(make_files_fixture '[{"filename":"src/auth/token.js","additions":2,"deletions":0}]')
FIXTURE_COMMENTS=$(make_comments_fixture '[]')
FIXTURE_PROTECTION=$(make_protection_fixture '["lint"]')
FIXTURE_RULESETS=$(make_rulesets_fixture "$(jq -n --arg n "$GATE_CHECK_NAME" '[$n]')")
BYPASS_OBJ=$(make_ruleset_object_fixture '[{"actor_id":1,"actor_type":"OrganizationAdmin","bypass_mode":"always"}]')
set +e
OUT=$(FIXTURE_PR="$FIXTURE_PR" FIXTURE_FILES="$FIXTURE_FILES" FIXTURE_COMMENTS="$FIXTURE_COMMENTS" \
      FIXTURE_PROTECTION="$FIXTURE_PROTECTION" FIXTURE_RULESETS="$FIXTURE_RULESETS" \
      FIXTURE_RULESET_OBJ="$BYPASS_OBJ" \
      MERGE_CLEARANCE_CODEX_CHECK_BIN="$STUB_DIR/codex-check-stub" CODEX_STUB_REQUIRE_HEAD_PIN=1 CODEX_STUB_RC=1 \
      run_gate "$SCRATCH" --derive-rate-limit-protection 99 owner/repo 2>/dev/null)
RC=$?
set -e
if [ "$RC" = 0 ] && [ "$OUT" = "false" ]; then
  pass "protection: ruleset with bypass actors is NOT counted as enforcement → false"
else
  fail "protection: bypassable ruleset expected false/0; got rc=$RC out='$OUT'"
fi

echo; echo "--- Protection 1n (#772 r5 P1): a same-named check from ANOTHER producer is not proof (classic)"
# A context is just a string. If the branch rule requires our name from a
# different integration, some other app satisfying it must not read as the
# trusted Actions gate being enforced.
SCRATCH=$(make_scratch false true)
FIXTURE_PR=$(make_pr_fixture "$HEAD_SHA" "someone")
FIXTURE_FILES=$(make_files_fixture '[{"filename":"src/auth/token.js","additions":2,"deletions":0}]')
FIXTURE_COMMENTS=$(make_comments_fixture '[]')
FIXTURE_PROTECTION=$(make_protection_fixture "$(jq -n --arg n "$GATE_CHECK_NAME" '["lint", $n]')")
set +e
OUT=$(FIXTURE_PR="$FIXTURE_PR" FIXTURE_FILES="$FIXTURE_FILES" FIXTURE_COMMENTS="$FIXTURE_COMMENTS" \
      FIXTURE_PROTECTION="$FIXTURE_PROTECTION" FIXTURE_CLASSIC_APP_ID=99999 \
      MERGE_CLEARANCE_CODEX_CHECK_BIN="$STUB_DIR/codex-check-stub" CODEX_STUB_REQUIRE_HEAD_PIN=1 CODEX_STUB_RC=1 \
      run_gate "$SCRATCH" --derive-rate-limit-protection 99 owner/repo 2>/dev/null)
RC=$?
set -e
if [ "$RC" = 0 ] && [ "$OUT" = "false" ]; then
  pass "protection: classic required check from a foreign app_id → not counted → false"
else
  fail "protection: foreign classic producer expected false/0; got rc=$RC out='$OUT'"
fi

echo; echo "--- Protection 1p (#772 r6 P2): duplicate contexts — ANY trusted producer entry counts"
# Classic protection can list one context more than once under different
# producers. Matching only the FIRST entry reports not-enforced whenever a
# foreign entry sorts ahead of the Actions one, even though the expected
# producer is explicitly required.
SCRATCH=$(make_scratch false true)
FIXTURE_PR=$(make_pr_fixture "$HEAD_SHA" "someone")
FIXTURE_FILES=$(make_files_fixture '[{"filename":"src/auth/token.js","additions":2,"deletions":0}]')
FIXTURE_COMMENTS=$(make_comments_fixture '[]')
FIXTURE_PROTECTION=$(make_protection_fixture "$(jq -n --arg n "$GATE_CHECK_NAME" '["lint", $n]')")
set +e
OUT=$(FIXTURE_PR="$FIXTURE_PR" FIXTURE_FILES="$FIXTURE_FILES" FIXTURE_COMMENTS="$FIXTURE_COMMENTS" \
      FIXTURE_PROTECTION="$FIXTURE_PROTECTION" FIXTURE_CLASSIC_DUP_FIRST=1 \
      run_gate "$SCRATCH" --derive-rate-limit-protection 99 owner/repo 2>/dev/null)
RC=$?
set -e
if [ "$RC" = 0 ] && [ "$OUT" = "true" ]; then
  pass "protection: duplicate context with a foreign entry first still matches the trusted producer → true"
else
  fail "protection: duplicate-context ordering expected true/0; got rc=$RC out='$OUT'"
fi

echo; echo "--- Protection 1o (#772 r5 P1): a ruleset rule with no integration pin is not proof"
SCRATCH=$(make_scratch false true)
FIXTURE_PR=$(make_pr_fixture "$HEAD_SHA" "someone")
FIXTURE_FILES=$(make_files_fixture '[{"filename":"src/auth/token.js","additions":2,"deletions":0}]')
FIXTURE_COMMENTS=$(make_comments_fixture '[]')
FIXTURE_PROTECTION=$(make_protection_fixture '["lint"]')
NOPIN_RULES="$WORKDIR/rulesets-nopin.$$.json"
jq -n --arg n "$GATE_CHECK_NAME" '[{type:"required_status_checks",ruleset_id:101,parameters:{required_status_checks:[{context:$n}]}}]' >"$NOPIN_RULES"
set +e
OUT=$(FIXTURE_PR="$FIXTURE_PR" FIXTURE_FILES="$FIXTURE_FILES" FIXTURE_COMMENTS="$FIXTURE_COMMENTS" \
      FIXTURE_PROTECTION="$FIXTURE_PROTECTION" FIXTURE_RULESETS="$NOPIN_RULES" \
      MERGE_CLEARANCE_CODEX_CHECK_BIN="$STUB_DIR/codex-check-stub" CODEX_STUB_REQUIRE_HEAD_PIN=1 CODEX_STUB_RC=1 \
      run_gate "$SCRATCH" --derive-rate-limit-protection 99 owner/repo 2>/dev/null)
RC=$?
set -e
if [ "$RC" = 0 ] && [ "$OUT" = "false" ]; then
  pass "protection: ruleset rule accepting ANY producer (no integration_id) → not counted → false"
else
  fail "protection: unpinned ruleset rule expected false/0; got rc=$RC out='$OUT'"
fi

echo; echo "--- Protection 1m (#772 r4): a ruleset payload OMITTING bypass_actors is not proof"
# `[ .bypass_actors[]? ] | length` is 0 both for an empty list and for an
# ABSENT key, so an unknown payload shape would have been recorded as positive
# proof of "no bypass actors" — the one direction this probe must never move
# in. Flagged independently by CodeRabbit (Major) and Codex (P1).
SCRATCH=$(make_scratch false true)
FIXTURE_PR=$(make_pr_fixture "$HEAD_SHA" "someone")
FIXTURE_FILES=$(make_files_fixture '[{"filename":"src/auth/token.js","additions":2,"deletions":0}]')
FIXTURE_COMMENTS=$(make_comments_fixture '[]')
FIXTURE_PROTECTION=$(make_protection_fixture '["lint"]')
FIXTURE_RULESETS=$(make_rulesets_fixture "$(jq -n --arg n "$GATE_CHECK_NAME" '[$n]')")
NOKEY_OBJ="$WORKDIR/ruleset-nokey.$$.json"
jq -n '{ id: 101, name: "no-bypass-key" }' >"$NOKEY_OBJ"
set +e
OUT=$(FIXTURE_PR="$FIXTURE_PR" FIXTURE_FILES="$FIXTURE_FILES" FIXTURE_COMMENTS="$FIXTURE_COMMENTS" \
      FIXTURE_PROTECTION="$FIXTURE_PROTECTION" FIXTURE_RULESETS="$FIXTURE_RULESETS" \
      FIXTURE_RULESET_OBJ="$NOKEY_OBJ" \
      MERGE_CLEARANCE_CODEX_CHECK_BIN="$STUB_DIR/codex-check-stub" CODEX_STUB_REQUIRE_HEAD_PIN=1 CODEX_STUB_RC=1 \
      run_gate "$SCRATCH" --derive-rate-limit-protection 99 owner/repo 2>/dev/null)
RC=$?
set -e
if [ "$RC" = 0 ] && [ "$OUT" = "false" ]; then
  pass "protection: ruleset payload without a bypass_actors key → not counted → false"
else
  fail "protection: missing bypass_actors key expected false/0; got rc=$RC out='$OUT'"
fi

echo; echo "--- Protection 1j (#772 r2 P1): an unreadable ruleset object is not proof of enforcement"
SCRATCH=$(make_scratch false true)
FIXTURE_PR=$(make_pr_fixture "$HEAD_SHA" "someone")
FIXTURE_FILES=$(make_files_fixture '[{"filename":"src/auth/token.js","additions":2,"deletions":0}]')
FIXTURE_COMMENTS=$(make_comments_fixture '[]')
FIXTURE_PROTECTION=$(make_protection_fixture '["lint"]')
FIXTURE_RULESETS=$(make_rulesets_fixture "$(jq -n --arg n "$GATE_CHECK_NAME" '[$n]')")
set +e
OUT=$(FIXTURE_PR="$FIXTURE_PR" FIXTURE_FILES="$FIXTURE_FILES" FIXTURE_COMMENTS="$FIXTURE_COMMENTS" \
      FIXTURE_PROTECTION="$FIXTURE_PROTECTION" FIXTURE_RULESETS="$FIXTURE_RULESETS" \
      FIXTURE_RULESET_OBJ_FAIL=1 \
      MERGE_CLEARANCE_CODEX_CHECK_BIN="$STUB_DIR/codex-check-stub" CODEX_STUB_REQUIRE_HEAD_PIN=1 CODEX_STUB_RC=1 \
      run_gate "$SCRATCH" --derive-rate-limit-protection 99 owner/repo 2>/dev/null)
RC=$?
set -e
if [ "$RC" = 0 ] && [ "$OUT" = "false" ]; then
  pass "protection: unreadable ruleset object → not counted, falls through to arm 2 → false"
else
  fail "protection: unreadable ruleset object expected false/0; got rc=$RC out='$OUT'"
fi

echo; echo "--- Protection 2 (#713): gate disabled + protected path + Phase-4b/Codex cleared → true"
SCRATCH=$(make_scratch false false)
FIXTURE_PR=$(make_pr_fixture "$HEAD_SHA" "someone")
FIXTURE_FILES=$(make_files_fixture '[{"filename":"src/auth/token.js","additions":2,"deletions":0}]')
FIXTURE_COMMENTS=$(make_comments_fixture '[]')
set +e
OUT=$(FIXTURE_PR="$FIXTURE_PR" FIXTURE_FILES="$FIXTURE_FILES" FIXTURE_COMMENTS="$FIXTURE_COMMENTS" \
      MERGE_CLEARANCE_CODEX_CHECK_BIN="$STUB_DIR/codex-check-stub" CODEX_STUB_REQUIRE_HEAD_PIN=1 CODEX_STUB_RC=0 CODEX_STUB_STDOUT='delegate stdout must not pollute query output' \
      run_gate "$SCRATCH" --derive-rate-limit-protection 99 owner/repo 2>/dev/null)
RC=$?
set -e
if [ "$RC" = 0 ] && [ "$OUT" = "true" ]; then
  pass "protection: gate disabled + protected path + head-pinned current-head external clearance → true (#713)"
else
  fail "protection: gate-disabled cleared expected true/0; got rc=$RC out='$OUT'"
fi

echo; echo "--- Protection 3: gate disabled + protected path + no external clearance → false"
SCRATCH=$(make_scratch false false)
FIXTURE_PR=$(make_pr_fixture "$HEAD_SHA" "someone")
FIXTURE_FILES=$(make_files_fixture '[{"filename":"src/auth/token.js","additions":2,"deletions":0}]')
FIXTURE_COMMENTS=$(make_comments_fixture '[]')
set +e
OUT=$(FIXTURE_PR="$FIXTURE_PR" FIXTURE_FILES="$FIXTURE_FILES" FIXTURE_COMMENTS="$FIXTURE_COMMENTS" \
      MERGE_CLEARANCE_CODEX_CHECK_BIN="$STUB_DIR/codex-check-stub" CODEX_STUB_REQUIRE_HEAD_PIN=1 CODEX_STUB_RC=1 \
      run_gate "$SCRATCH" --derive-rate-limit-protection 99 owner/repo 2>/dev/null)
RC=$?
set -e
if [ "$RC" = 0 ] && [ "$OUT" = "false" ]; then
  pass "protection: gate disabled + protected path + no current-head external clearance → false"
else
  fail "protection: gate-disabled uncleared expected false/0; got rc=$RC out='$OUT'"
fi

echo; echo "--- Protection 4: gate disabled + under-threshold plain PR stays false even if codex-check would pass"
SCRATCH=$(make_scratch false false)
FIXTURE_PR=$(make_pr_fixture "$HEAD_SHA" "someone")
FIXTURE_FILES=$(make_files_fixture '[{"filename":"README.md","additions":2,"deletions":0}]')
FIXTURE_COMMENTS=$(make_comments_fixture '[]')
set +e
OUT=$(FIXTURE_PR="$FIXTURE_PR" FIXTURE_FILES="$FIXTURE_FILES" FIXTURE_COMMENTS="$FIXTURE_COMMENTS" \
      MERGE_CLEARANCE_CODEX_CHECK_BIN="$STUB_DIR/codex-check-stub" CODEX_STUB_RC=0 \
      run_gate "$SCRATCH" --derive-rate-limit-protection 99 owner/repo 2>/dev/null)
RC=$?
set -e
if [ "$RC" = 0 ] && [ "$OUT" = "false" ]; then
  pass "protection: under-threshold plain PR → false (keeps #512 r3 block)"
else
  fail "protection: under-threshold expected false/0; got rc=$RC out='$OUT'"
fi

echo; echo "--- Protection 5: Dependabot author → false"
SCRATCH=$(make_scratch true true)
FIXTURE_PR=$(make_pr_fixture "$HEAD_SHA" "$DEPENDABOT" "$EXT_LABEL")
set +e
OUT=$(FIXTURE_PR="$FIXTURE_PR" run_gate "$SCRATCH" --derive-rate-limit-protection 99 owner/repo 2>/dev/null)
RC=$?
set -e
if [ "$RC" = 0 ] && [ "$OUT" = "false" ]; then
  pass "protection: dependabot → false"
else
  fail "protection: dependabot expected false/0; got rc=$RC out='$OUT'"
fi

echo; echo "--- Protection 6: indeterminate marker read → nonzero, NOT 'true'"
SCRATCH=$(make_scratch false false)
FIXTURE_PR=$(make_pr_fixture "$HEAD_SHA" "someone")
FIXTURE_FILES=$(make_files_fixture '[{"filename":".github/workflows/x.yml","additions":500,"deletions":0}]')
set +e
OUT=$(FIXTURE_PR="$FIXTURE_PR" FIXTURE_FILES="$FIXTURE_FILES" FIXTURE_COMMENTS_FAIL=1 \
  run_gate "$SCRATCH" --derive-rate-limit-protection 99 owner/repo 2>/dev/null)
RC=$?
set -e
if [ "$RC" != 0 ] && [ "$OUT" != "true" ]; then
  pass "protection: indeterminate marker read → nonzero exit and no 'true' (caller fails closed)"
else
  fail "protection: indeterminate marker read expected nonzero and not 'true'; got rc=$RC out='$OUT'"
fi

# ---------------------------------------------------------------------------
echo
echo "============================================"
echo "test_merge_clearance_gate.sh: $PASS passed, $FAIL failed"
echo "============================================"
if [ "$FAIL" -gt 0 ]; then exit 1; fi
exit 0
