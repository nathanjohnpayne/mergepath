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
#     Protection 1q–1s2 cover #781 item 1 (the bypass-actor lookup follows the
#     ruleset's OWNING scope, so an inherited org ruleset is readable) and
#     1t–1z2 cover #781 item 11 (bypass actors are evaluated against the
#     merging identity rather than counted, allowlist-style, with every
#     unresolvable actor still disqualifying the ruleset).
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
      # #772 r2 P1: bypass-actor lookup for a candidate REPOSITORY ruleset.
      if [ "${FIXTURE_RULESET_OBJ_FAIL:-0}" = "1" ]; then
        echo "STUB gh: simulated ruleset object read failure" >&2
        exit 1
      fi
      cat "${FIXTURE_RULESET_OBJ:-/dev/null}"
      exit 0
      ;;
    orgs/*/rulesets/*)
      # #781 item 1: an ORG-level ruleset inherited by the repo lives only
      # here. Absent fixture == the real 404 an org ruleset produces when a
      # caller looks for it under the repository path.
      if [ -z "${FIXTURE_ORG_RULESET_OBJ:-}" ]; then
        echo "gh: Not Found (HTTP 404)" >&2
        exit 1
      fi
      cat "$FIXTURE_ORG_RULESET_OBJ"
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
  # <dependabot_enabled> <external_enabled> [author_identity]
  # Pass "" as the third argument to OMIT author_identity entirely — the
  # "merging identity unknown" case, in which the #781 probe must rule no
  # bypass actor out.
  local dependabot_enabled=$1 external_enabled=$2
  local author_identity=${3-nathanjohnpayne}
  local dir
  dir=$(mktemp -d "$WORKDIR/scratch.XXXXXX")
  mkdir -p "$dir/.github"
  [ -z "$author_identity" ] \
    || printf 'author_identity: %s\n' "$author_identity" >"$dir/.github/review-policy.yml"
  cat >>"$dir/.github/review-policy.yml" <<EOF
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

make_rulesets_fixture() {  # <contexts_json_array> [ruleset_id] [source_type] [source]
  # rules/branches/<branch> shape. The real endpoint always reports the OWNING
  # scope of each rule via ruleset_source_type / ruleset_source, and the #781
  # probe selects the repository vs organization ruleset endpoint from it, so
  # the fixture carries them. Defaults to a repository-owned ruleset.
  local contexts=$1 rs_id=${2:-101} src_type=${3:-Repository} src=${4:-owner/repo}
  local file="$WORKDIR/rulesets.$$.$RANDOM.json"
  jq -n --argjson contexts "$contexts" --argjson rs_id "$rs_id" \
        --arg src_type "$src_type" --arg src "$src" \
        --argjson app "${FIXTURE_RULESET_APP_ID:-15368}" '
    [ { type: "required_status_checks",
        ruleset_id: $rs_id,
        ruleset_source_type: $src_type,
        ruleset_source: $src,
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
# Test 5a–5d (#817): the reviewer allow-list is parsed by the shared
# scripts/lib/reviewers-helpers.sh reader, so every YAML spelling of a
# reviewer entry resolves to the same login. The reader this script used to
# carry was a single sed with a double-quote-only capture; on this same
# 4-entry fixture it returned two clean logins, one with its single quotes
# intact, and one whole raw line with its inline comment unparsed. Each
# mangled entry drops a real reviewer out of the fail-closed allow-list, so
# the APPROVED review below stops matching and the Dependabot gate BLOCKS a
# correctly-approved PR.
# ---------------------------------------------------------------------------
make_scratch_reviewers() {  # <reviewers_block_body>
  local reviewers=$1 dir
  dir=$(mktemp -d "$WORKDIR/scratch.XXXXXX")
  mkdir -p "$dir/.github"
  cat >"$dir/.github/review-policy.yml" <<EOF
author_identity: nathanjohnpayne
external_review_threshold: 300

available_reviewers:
$reviewers

codex:
  bot_login: "chatgpt-codex-connector[bot]"
  external_review_gate:
    enabled: false

dependabot:
  reviewer_gate:
    enabled: true
EOF
  echo "$dir"
}

# The four shapes from the #817 reproduction: unquoted, single-quoted,
# trailing inline comment, double-quoted and padded.
QUOTED_REVIEWERS='  - nathanpayne-claude
  - '"'"'nathanpayne-cursor'"'"'
  - nathanpayne-codex   # the codex identity
  - "nathanpayne-fixture"   '

for _rv in nathanpayne-claude nathanpayne-cursor nathanpayne-codex nathanpayne-fixture; do
  echo; echo "--- Test 5* (#817): allow-list entry '$_rv' survives its YAML spelling"
  SCRATCH=$(make_scratch_reviewers "$QUOTED_REVIEWERS")
  FIXTURE_PR=$(make_pr_fixture "$HEAD_SHA" "$DEPENDABOT")
  FIXTURE_REVIEWS=$(make_reviews_fixture "$(jq -n --arg sha "$HEAD_SHA" --arg who "$_rv" '
    [{ user:{login:$who}, state:"APPROVED", commit_id:$sha, submitted_at:"2026-06-01T10:00:00Z" }]
  ')")
  set +e
  OUT=$(FIXTURE_PR="$FIXTURE_PR" FIXTURE_REVIEWS="$FIXTURE_REVIEWS" run_gate "$SCRATCH" 99 owner/repo 2>&1)
  RC=$?
  set -e
  if [ "$RC" = 0 ] && echo "$OUT" | grep -q "PASS" && echo "$OUT" | grep -q "$_rv"; then
    pass "#817: quoted/commented/padded allow-list entry '$_rv' still matches its approval"
  else
    fail "#817: expected rc=0 PASS naming '$_rv'; got rc=$RC"; echo "$OUT" | sed 's/^/      /' >&2
  fi
done

# ---------------------------------------------------------------------------
# Test 5e (#817): the helper is a HARD dependency, not a soft one. An
# unreadable scripts/lib/reviewers-helpers.sh must abort with the config
# exit code rather than leaving read_available_reviewers undefined — an
# undefined reader would produce an empty allow-list, which on this path is
# the difference between "block" and "crash", but on the codex-review-check
# path is the fail-OPEN direction #453 exists to prevent.
# ---------------------------------------------------------------------------
echo; echo "--- Test 5e (#817): missing reviewers-helpers.sh → exit 2"
SANDBOX_SCRIPTS="$WORKDIR/no-lib/scripts"
mkdir -p "$SANDBOX_SCRIPTS/lib"
cp "$SCRIPT" "$SANDBOX_SCRIPTS/merge-clearance-gate.sh"
chmod +x "$SANDBOX_SCRIPTS/merge-clearance-gate.sh"
SCRATCH=$(make_scratch true false)
FIXTURE_PR=$(make_pr_fixture "$HEAD_SHA" "$DEPENDABOT")
set +e
OUT=$(cd "$SCRATCH" && PATH="$STUB_DIR:$PATH" GH_TOKEN="dummy-token" \
  GH_CALLS_LOG="$WORKDIR/gh-calls.log" FIXTURE_PR="$FIXTURE_PR" \
  "$SANDBOX_SCRIPTS/merge-clearance-gate.sh" 99 owner/repo 2>&1)
RC=$?
set -e
if [ "$RC" = 2 ] && echo "$OUT" | grep -q "reviewers-helpers missing"; then
  pass "#817: absent reviewers-helpers.sh → exit 2 with a naming error"
else
  fail "#817: expected rc=2 'reviewers-helpers missing'; got rc=$RC"; echo "$OUT" | sed 's/^/      /' >&2
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
WF
  # The auxiliary producers come from the REAL workflow, not from a
  # hand-written stand-in (#849). Hand-maintained positive controls drifted
  # behind the check on five consecutive review rounds — each new assertion
  # left them non-compliant — and a control weaker than its subject accepts
  # workflows the real check rejects, which is a false pass in the direction
  # that hides regressions. Extracting them means the control cannot lag.
  mcg_real_job scheduled-sweep
  mcg_real_job dispatch-recheck
}

# Print one job block verbatim from the canonical workflow.
mcg_real_job() {  # <job-key>
  awk -v key="$1" '
    $0 ~ "^  " key ":[[:space:]]*$" { inblk = 1; print; next }
    inblk && /^  [A-Za-z0-9_-]+:[[:space:]]*$/ { exit }
    inblk { print }
  ' "$ROOT/.github/workflows/merge-clearance-gate.yml"
}

# The compliant event job, likewise taken from the canonical workflow.
write_wf_gate_job() {
  mcg_real_job merge-clearance-gate
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
  write_wf_gate_job
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

# ---------------------------------------------------------------------------
# Test 23 (#841): the two-phase Checks-API publish in the event-driven job.
#
# BEHAVIOURAL, not structural. The real `run:` bodies are extracted from the
# live workflow and executed against a stub `gh`, so these cases fail if the
# published shape stops matching what the workflow actually does — a grep for
# the POST would keep passing while the mapping underneath it rotted.
#
# Why the job publishes at all: a job-native completion cannot retire a
# Checks-API entry, so before #841 a stale synthetic FAILURE outlived ten
# job-native successes on an unchanged head and blocked the PR indefinitely.
# The event job now writes the same slot the sweep writes.
# ---------------------------------------------------------------------------
WF_841="$ROOT/.github/workflows/merge-clearance-gate.yml"
if [ -f "$WF_841" ]; then
  echo; echo "--- Test 23 (#841): two-phase Checks-API publish"
  # Every case below deliberately runs commands that are EXPECTED to fail
  # (a stub gh returning 1, a grep that must not match), and several are
  # written as `cmd && bad=...`, whose status is non-zero when cmd fails.
  # Under the suite's errexit that exits the whole run, so drop it for the
  # duration and restore it at the end of the block — the same idiom the
  # older cases in this file use around run_gate.
  set +e

  # Extract one step's run: body and dedent it. Body lines sit at 10 spaces;
  # the first non-blank line shallower than that ends the block.
  mcg_step_body() {  # <workflow> <step name>
    awk -v want="$2" '
      index($0, "- name: " want) { instep = 1; next }
      instep && !inrun && /^        run: \|/ { inrun = 1; next }
      inrun {
        if ($0 ~ /^[[:space:]]*$/) { print ""; next }
        if ($0 !~ /^          /) exit
        sub(/^          /, "")
        print
      }
    ' "$1"
  }

  P1_BODY="$(mcg_step_body "$WF_841" 'Open the required check_run (#841 phase 1)')"
  P2_BODY="$(mcg_step_body "$WF_841" 'Close the required check_run (#841 phase 2)')"
  RV_BODY="$(mcg_step_body "$WF_841" 'Report gate verdict')"

  T23="$(mktemp -d "${TMPDIR:-/tmp}/mcg841.XXXXXX")"
  mkdir -p "$T23/bin"
  # Stub gh: logs argv, behaviour driven by env.
  cat > "$T23/bin/gh" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >> "$GH_LOG"
if [ "$1" = api ]; then
  case "$*" in
    *"-X POST"*)
      [ "${GH_POST_FAIL:-0}" = 1 ] && exit 1
      printf '%s\n' "${GH_POST_ID:-42}"; exit 0 ;;
    *"-X PATCH"*)
      [ "${GH_PATCH_FAIL:-0}" = 1 ] && exit 1
      exit 0 ;;
  esac
  exit 0
fi
if [ "$1" = pr ] && [ "$2" = view ]; then
  [ "${GH_PRVIEW_FAIL:-0}" = 1 ] && exit 1
  printf '%s\n' "${GH_PRVIEW_SHA:-deadbeefdeadbeefdeadbeefdeadbeefdeadbeef}"; exit 0
fi
exit 0
STUB
  # No-op sleep: the retry loops would otherwise burn ~2 minutes of real time.
  printf '#!/bin/sh\nexit 0\n' > "$T23/bin/sleep"
  chmod +x "$T23/bin/gh" "$T23/bin/sleep"

  SHA1=deadbeefdeadbeefdeadbeefdeadbeefdeadbeef
  run23() {  # <body> ; env supplied by caller
    GH_LOG="$T23/gh.log" PATH="$T23/bin:$PATH" \
    GITHUB_OUTPUT="$T23/out.txt" RUNNER_TEMP="$T23" \
      bash -c "$1" 2>&1
  }
  reset23() { : > "$T23/gh.log"; : > "$T23/out.txt"; }

  bad=""
  # -- phase 1 -------------------------------------------------------------
  reset23
  OUT=$(REPO=o/r HEAD_SHA="$SHA1" IS_FORK=false CHECK_NAME="Merge clearance gate" \
        run23 "$P1_BODY"); RC=$?
  posts=$(grep -c -- "-X POST" "$T23/gh.log" || true)
  [ "$RC" = 0 ] || bad="$bad p1-ok-rc"
  [ "$posts" = 1 ] || bad="$bad p1-ok-postcount"
  grep -q "id=42" "$T23/out.txt" || bad="$bad p1-ok-id"
  grep -q "status=in_progress" "$T23/gh.log" || bad="$bad p1-ok-inprogress"
  grep -q "head_sha=$SHA1" "$T23/gh.log" || bad="$bad p1-ok-headsha"
  grep -q "name=Merge clearance gate" "$T23/gh.log" || bad="$bad p1-ok-name"

  reset23
  OUT=$(REPO=o/r HEAD_SHA="$SHA1" IS_FORK=true CHECK_NAME=X GH_POST_FAIL=1 \
        run23 "$P1_BODY"); RC=$?
  [ "$RC" = 0 ] || bad="$bad p1-fork-rc"
  printf '%s' "$OUT" | grep -q "::warning::" || bad="$bad p1-fork-warn"
  grep -q "^id=" "$T23/out.txt" && bad="$bad p1-fork-idleak"

  reset23
  OUT=$(REPO=o/r HEAD_SHA="$SHA1" IS_FORK=false PR_ACTOR=someone CHECK_NAME=X \
        GH_POST_FAIL=1 run23 "$P1_BODY"); RC=$?
  [ "$RC" = 1 ] || bad="$bad p1-samerepo-rc"
  printf '%s' "$OUT" | grep -q "::error::" || bad="$bad p1-samerepo-err"

  # Dependabot PRs are SAME-REPO (IS_FORK=false) but carry a read-only token.
  # Without this branch the publish fails every retry and fails the required
  # check on every Dependabot PR, which run weekly here (Codex P1 on #843).
  reset23
  OUT=$(REPO=o/r HEAD_SHA="$SHA1" IS_FORK=false PR_ACTOR="dependabot[bot]" \
        CHECK_NAME=X GH_POST_FAIL=1 run23 "$P1_BODY"); RC=$?
  [ "$RC" = 0 ] || bad="$bad p1-dependabot-rc"
  printf '%s' "$OUT" | grep -q "::warning::" || bad="$bad p1-dependabot-warn"

  # "dependabot[bot]" is a glob character class in a case arm, so a case-based
  # match would also accept "dependabott" and let a spoofable actor name take
  # the degrade path. Pin that it does not.
  reset23
  OUT=$(REPO=o/r HEAD_SHA="$SHA1" IS_FORK=false PR_ACTOR="dependabott" \
        CHECK_NAME=X GH_POST_FAIL=1 run23 "$P1_BODY"); RC=$?
  [ "$RC" = 1 ] || bad="$bad p1-dependabot-globtrap"

  reset23
  OUT=$(REPO=o/r HEAD_SHA="" IS_FORK=false CHECK_NAME=X run23 "$P1_BODY"); RC=$?
  [ "$RC" = 1 ] || bad="$bad p1-nohead-rc"
  [ -s "$T23/gh.log" ] && bad="$bad p1-nohead-posted"

  if [ -z "$bad" ]; then
    pass "#841 phase 1: opens an in_progress run on the PR head, tolerates a fork, and refuses to proceed when it cannot publish"
  else
    fail "#841 phase 1 wrong:$bad"
  fi

  # -- phase 2 -------------------------------------------------------------
  bad=""
  p2() {  # <rc> <verdict> ; extra env via caller prefix
    reset23
    printf 'gate said things\n' > "$T23/mcg-summary.txt"
    REPO=o/r PR_NUMBER=7 CHECK_ID=42 HEAD_SHA="$SHA1" RC="$1" VERDICT="$2" \
      run23 "$P2_BODY"
  }
  OUT=$(p2 0 pass); RC=$?
  grep -q -- "-X PATCH" "$T23/gh.log" || bad="$bad p2-pass-nopatch"
  grep -q "check-runs/42" "$T23/gh.log" || bad="$bad p2-pass-target"
  grep -q "conclusion=success" "$T23/gh.log" || bad="$bad p2-pass-conclusion"

  OUT=$(p2 1 blocked)
  grep -q "conclusion=failure" "$T23/gh.log" || bad="$bad p2-blocked"
  grep -q "infra/config" "$T23/gh.log" && bad="$bad p2-blocked-mislabelled"

  OUT=$(p2 0 absent)
  grep -q "conclusion=failure" "$T23/gh.log" || bad="$bad p2-absent"
  grep -q "rc=0 with no PASS verdict" "$T23/gh.log" || bad="$bad p2-absent-title"

  OUT=$(p2 7 absent)
  grep -q "infra/config error (rc=7)" "$T23/gh.log" || bad="$bad p2-rc7"

  # Head moved, and head unreadable: both must publish a red pinned to the
  # head we bound to, never a silent skip that leaves a stale green standing.
  reset23; printf 'x\n' > "$T23/mcg-summary.txt"
  OUT=$(REPO=o/r PR_NUMBER=7 CHECK_ID=42 HEAD_SHA="$SHA1" RC=0 VERDICT=pass \
        GH_PRVIEW_SHA=cafebabecafebabecafebabecafebabecafebabe run23 "$P2_BODY")
  grep -q "conclusion=failure" "$T23/gh.log" || bad="$bad p2-drift-conclusion"
  grep -q "head moved" "$T23/gh.log" || bad="$bad p2-drift-title"
  grep -q "check-runs/42" "$T23/gh.log" || bad="$bad p2-drift-target"

  reset23; printf 'x\n' > "$T23/mcg-summary.txt"
  OUT=$(REPO=o/r PR_NUMBER=7 CHECK_ID=42 HEAD_SHA="$SHA1" RC=0 VERDICT=pass \
        GH_PRVIEW_FAIL=1 run23 "$P2_BODY")
  grep -q "conclusion=failure" "$T23/gh.log" || bad="$bad p2-unreadable"

  reset23; printf 'x\n' > "$T23/mcg-summary.txt"
  OUT=$(REPO=o/r PR_NUMBER=7 CHECK_ID=42 HEAD_SHA="$SHA1" RC=0 VERDICT=pass \
        GH_PATCH_FAIL=1 run23 "$P2_BODY"); RC=$?
  patches=$(grep -c -- "-X PATCH" "$T23/gh.log" || true)
  [ "$RC" = 0 ] || bad="$bad p2-patchfail-rc"
  [ "$patches" = 3 ] || bad="$bad p2-patchfail-attempts($patches)"
  printf '%s' "$OUT" | grep -q "::warning::" || bad="$bad p2-patchfail-warn"

  if [ -z "$bad" ]; then
    pass "#841 phase 2: maps rc/verdict to a conclusion, publishes a red on head drift rather than skipping, and never fails the job"
  else
    fail "#841 phase 2 wrong:$bad"
  fi

  # -- native conclusion mapping is unchanged ------------------------------
  bad=""
  rv() { RC="$1" VERDICT="$2" run23 "$RV_BODY" >/dev/null 2>&1; }
  rv 0 pass   || bad="$bad rv-pass"
  rv 0 absent && bad="$bad rv-absent-should-fail"
  rv 1 blocked && bad="$bad rv-blocked-should-fail"
  rv 2 absent && bad="$bad rv-rc2-should-fail"
  if [ -z "$bad" ]; then
    pass "#841: the job's NATIVE conclusion mapping is unchanged apart from the rc-0-without-PASS sentinel"
  else
    fail "#841 native mapping changed:$bad"
  fi

  rm -rf "$T23"
  set -e
else
  echo "SKIP: Test 23 (#841) — merge-clearance-gate.yml absent"
fi


# ---------------------------------------------------------------------------
# Test 22 (#845): the two-phase Checks-API publish assertions must actually
# reject a workflow that lost the property they name.
#
# Each case appends a deliberately-broken variant of write_wf_gate_job to a
# shape-valid header and asserts the check FAILS. Case I is the positive
# control. Two of these are worth more than the rest:
#
#   B proves COMMENT STRIPPING. #843 documents this design in prose right next
#     to the code, so an unstripped grep matches the explanation after the
#     implementation is gone.
#   D proves BLOCK SCOPING. The header's sweep job POSTs under the same
#     CHECK_NAME, so a whole-file grep passes even with the event job's
#     publish deleted — which is exactly the pre-#843 workflow.
#
# Without B and D the other assertions are decorative: they would pass on the
# very shape they exist to reject.
# ---------------------------------------------------------------------------
echo; echo "--- Test 22 (#845): two-phase publish assertions reject each broken shape"

mcg22_run() {  # <fixture-path> -> echoes rc
  local out rc
  set +e
  out=$(MCG_SKIP_FIX3_SELFTEST=1 MERGE_CLEARANCE_WORKFLOW="$1" "$CHECK_BIN" 2>&1)
  rc=$?
  set -e
  printf '%s' "$out" > "$1.out"
  echo "$rc"
}

# The expected-message argument is what makes these cases mean anything. A
# broken fixture can fail the check for an unrelated reason — a mangled
# substitution, a tripped older assertion — and a bare rc!=0 assertion would
# call that a pass while proving nothing about the property under test.
mcg22_case() {  # <name> <perl-program-or-empty> <expect: fail|pass> [expected-FAIL-substring]
  local name="$1" prog="$2" expect="$3" want="${4:-}" f rc
  f="$WORKDIR/wf-22-$name.yml"
  { write_wf_header; write_wf_gate_job; } > "$f.raw"
  if [ -n "$prog" ]; then perl -0777 -pe "$prog" "$f.raw" > "$f"; else cp "$f.raw" "$f"; fi
  # A no-op substitution means the case is testing nothing.
  if [ -n "$prog" ] && cmp -s "$f.raw" "$f"; then
    fail "${MCG_TAG:-#845} case $name: the mutation changed nothing — anchor drifted"
    return
  fi
  rc=$(mcg22_run "$f")
  if [ "$expect" = pass ]; then
    if [ "$rc" -eq 0 ]; then
      pass "${MCG_TAG:-#845} case $name: positive control — a compliant job is accepted"
    else
      fail "${MCG_TAG:-#845} case $name: expected pass, got rc=$rc"
      sed 's/^/      /' "$f.out" | head -4 >&2
    fi
    return
  fi
  if [ "$rc" -eq 0 ]; then
    fail "${MCG_TAG:-#845} case $name: expected the check to reject this shape, got rc=0"
  elif [ -n "$want" ] && ! grep -qF -- "$want" "$f.out"; then
    fail "${MCG_TAG:-#845} case $name: rejected, but not for its own reason (wanted: $want)"
    grep '^FAIL' "$f.out" | sed 's/^/      /' | head -3 >&2
  else
    pass "${MCG_TAG:-#845} case $name: the check rejects it, naming the right cause"
  fi
}

# A — no POST at all.
mcg22_case A 's{(  merge-clearance-gate:.*?)gh api -X POST "repos/\$REPO/check-runs" \\}{$1true \\}s' fail "must open the required check_run"
# B — the POST survives only as a full-line comment.
mcg22_case B 's{^(\s*)id=\$\(gh api -X POST}{$1# id=\$(gh api -X POST}m' fail "must open the required check_run"
# C — no job-scoped checks: write.
mcg22_case C 's{^\s*checks: write\n}{}m' fail "checks: write"
# D — the event job loses its publish; the header sweep still POSTs.
mcg22_case D 's{  merge-clearance-gate:}{  merge-clearance-renamed:}' fail 'the #845'
# E — bound to the merge commit instead of the PR head.
mcg22_case E 's{HEAD_SHA: \$\{\{ github.event.pull_request.head.sha \}\}}{HEAD_SHA: head_sha="\$\{\{ github.sha \}\}"}' fail "must NOT bind to github.sha"
# F — opens the run but never closes it.
mcg22_case F 's{gh api -X PATCH "repos/\$REPO/check-runs/\$CHECK_ID"}{true}' fail "must close the check_run it opened"
# G — no verdict sentinel, so a query-mode rc 0 could publish green.
mcg22_case G 's{\*"Merge clearance: PASS"\*\)}{*"nope"*)}' fail "verdict sentinel"
# H — always() instead of !cancelled(): publishes on a cancelled run.
mcg22_case H 's{if: \$\{\{ !cancelled\(\) && steps.open.outputs.id != .. \}\}}{if: always()}' fail "guarded by !cancelled()"
# J — valid YAML that DISABLES the permission while an inline comment still
#     carries the string. Stripping only full-line comments accepts this
#     (Codex P2 on #849), which would have made every assertion bypassable by
#     leaving the old code behind a `#`.
mcg22_case J 's{^(\s*)checks: write}{$1checks: read # checks: write}m' fail 'checks: write'
# K — rebind phase 1 to the merge commit WITHOUT the one literal spelling the
#     first version of this assertion forbade. Phase 2's unchanged line kept
#     satisfying the positive grep, so the mutation slipped through (Codex P2).
mcg22_case K 's{HEAD_SHA: \$\{\{ github.event.pull_request.head.sha \}\}}{HEAD_SHA: \$\{\{ github.sha \}\}}' fail 'must NOT bind to github.sha'
# L and M are the two halves of the same assertion, and they fail in OPPOSITE
# directions — which is why the producer check has to be a conjunction, per
# scope, rather than a count of either half.
# L — delete a producer's POST but keep its CHECK_NAME env. A name-count
#     assertion still sees three and passes (Codex P2 on #849).
mcg22_case L 's{(  scheduled-sweep:.*?)gh api -X POST "repos/\$REPO/check-runs"}{$1true #}s' fail 'must POST a check_run under CHECK_NAME'
# M — keep a POST but publish a DIFFERENT check name. A POST-count assertion
#     still sees three and passes, while that trigger path has stopped
#     refreshing this required context (CodeRabbit Major on #849).
mcg22_case M 's{(.*)-f name="\$CHECK_NAME"}{$1-f name="Some Other Check"}s' fail 'must POST a check_run under CHECK_NAME'
# I — positive control.
mcg22_case I '' pass

# ---------------------------------------------------------------------------
# Test 24 (#850): the STRUCTURAL layer — assertions over the PARSED document.
#
# Position and eligibility have no text reformulation available: they are
# statements about which step comes FIRST and whether a job's if: can ever be
# true. Every case below breaks exactly ONE of them in a fixture derived from
# the canonical workflow (never hand-written — a hand-maintained control drifted
# behind the check on five consecutive rounds in #849, and a control weaker than
# its subject is a false pass in the direction that hides regressions) and
# asserts the check names THAT property rather than merely going red.
#
# Reuses the Test 22 harness verbatim, retagged: its no-op guard (a mutation
# that changed nothing means the anchor drifted) matters more here, because
# these anchors are step names and indents in a file that keeps being edited.
#
# Gated on PyYAML: the check soft-skips the structural layer without it (the
# scripts/ci/check_workflow_parsers posture), so there is nothing to test.
# ---------------------------------------------------------------------------
if python3 -c "import yaml" >/dev/null 2>&1; then
echo; echo "--- Test 24 (#850): structural assertions over the parsed workflow"
MCG_TAG='#850'

# a — phase 1 demoted below the checkout. Every string assertion still passes:
#     the POST and status=in_progress are present, just no longer first, so a
#     checkout failure now happens before anything retires the stale verdict.
mcg22_case a 's{(      - name: Open the required check_run.*?)(      - name: Checkout repo.*?)(      - name: Resolve PR number)}{$2$1$3}s' \
  fail '[#850 phase-1 position]'
# b — phase 1 made conditional. success() is TRUTHY on purpose: the property is
#     that phase 1 carries no step-level if: AT ALL, not that its if is falsy.
mcg22_case b 's{(      - name: Open the required check_run[^\n]*\n)}{$1        if: success()\n}' \
  fail '[#850 phase-1 unconditional]'
# c — the sweep can never run. Trigger, CHECK_NAME, POST, permissions all
#     intact; only the parse sees that the job is unreachable.
mcg22_case c 's{(  scheduled-sweep:.*?)^    if: [^\n]*$}{$1    if: false}sm' \
  fail "[#850 producer eligibility] job 'scheduled-sweep'"
# d — #849 hole 1: phase 2 loses its own HEAD_SHA. A job-scoped grep for the
#     binding is satisfied by phase 1's.
mcg22_case d 's{(      - name: Close the required check_run.*?)^          HEAD_SHA: [^\n]*\n}{$1}sm' \
  fail '[#850 phase-2 head binding]'
# e — #849 hole 2: a gh-invoking step loses its token, so gh falls back to
#     unauthenticated and the sweep cannot list PRs at all.
mcg22_case e 's{(      - name: Find open PRs.*?)^          GH_TOKEN: [^\n]*\n}{$1}sm' \
  fail "[#850 gh token binding] step 'Find open PRs' in job 'scheduled-sweep'"
# f — truncated mid-document, leaving an unterminated quoted scalar. Must fail
#     LOUDLY naming the parse error; a parser that silently matches nothing
#     turns every assertion above into a no-op.
mcg22_case f 's{(    - cron: "\*/15).*}{$1}s' fail 'does not parse as YAML'
# h — a DUPLICATE job key. yaml.safe_load would keep the last while the text
#     layer reads the first, so the two layers would inspect different
#     definitions; the strict loader makes it a parse error, exactly as
#     Actions' own workflow parser treats it.
mcg22_case h 's{\z}{  merge-clearance-gate: ["not-a-mapping"]\n}' \
  fail 'duplicate mapping key'
# h2 — the event job parses to a NON-mapping (its body re-homed under another
#      key, no duplicate). Must fail with the named not-a-mapping cause, never
#      an unhandled traceback (which prints no FAIL line at all because
#      failures are buffered until the end).
mcg22_case h2 's{^  merge-clearance-gate:\n}{  merge-clearance-gate: ["not-a-mapping"]\n  relocated-original:\n}m' \
  fail "[#850 producer eligibility] job 'merge-clearance-gate'"
# a2 — a preliminary first step whose run body merely MENTIONS the phase-1
#      strings. Substrings alone accept it (the real publisher still satisfies
#      the text layer later in the job); only the step-identity conjunct sees
#      that the first step is not the publisher.
mcg22_case a2 's{(    steps:\n)(      - name: Open the required check_run)}{$1      - name: Preliminary\n        run: echo check-runs in_progress\n$2}' \
  fail '[#850 phase-1 position]'
# c2 — the same unreachable sweep spelled as an expression-wrapped literal,
#      which GitHub evaluates exactly like the bare one.
mcg22_case c2 's{(  scheduled-sweep:.*?)^    if: [^\n]*$}{$1    if: \$\{\{ 0 \}\}}sm' \
  fail "[#850 producer eligibility] job 'scheduled-sweep'"
# c3 — a bare null condition. PyYAML yields None, whose str() is outside the
#      literal tuple; the explicit None arm must fail it closed rather than
#      pass a condition nobody can prove eligible.
mcg22_case c3 's{(  scheduled-sweep:.*?)^    if: [^\n]*$}{$1    if: null}sm' \
  fail "[#850 producer eligibility] job 'scheduled-sweep'"
# c4 — numeric-zero spellings inside the expression wrapper. GitHub evaluates
#      -0 falsy; numeric normalisation must catch every zero spelling, not an
#      enumerated literal list.
mcg22_case c4 's{(  scheduled-sweep:.*?)^    if: [^\n]*$}{$1    if: \$\{\{ -0 \}\}}sm' \
  fail "[#850 producer eligibility] job 'scheduled-sweep'"
# i — a complex (sequence) mapping key. Unhashable in Python; must surface as
#     a NAMED parse error, not an incidental TypeError, and Actions rejects
#     complex keys in workflows anyway.
mcg22_case i 's{^  scheduled-sweep:$}{  ? [scheduled-sweep]\n  :}m' \
  fail 'does not parse as YAML'
# c5 — a BARE numeric-zero condition, no expression wrapper. YAML hands the
#      float over directly; the normalisation must not live only inside the
#      wrapped branch.
mcg22_case c5 's{(  scheduled-sweep:.*?)^    if: [^\n]*$}{$1    if: 0.0}sm' \
  fail "[#850 producer eligibility] job 'scheduled-sweep'"
# j — a steps entry that parses to a bare string. .get on it would raise; the
#     first-step property must fail with its own named cause instead.
mcg22_case j 's{(    steps:\n)(      - name: Open the required check_run)}{$1      - just-a-string\n$2}' \
  fail '[#850 phase-1 position]'
# c6 — a QUOTED non-empty expression literal is TRUTHY to GitHub ('0'
#      included). Job-level conditions are exact-pinned now, so the truthy
#      semantics are exercised where the falsy test still rules: a producer
#      STEP. Stripping the quotes into the numeric arm would falsely red an
#      eligible step.
mcg22_case c6 's{(      - name: Re-evaluate gate per PR and post check_run\n)(        if: )steps.find.outputs.prs[^\n]*}{$1$2\$\{\{ \x270\x27 \}\}}sm' pass
# c7 — the EMPTY quoted literal is the one falsy quoted form.
mcg22_case c7 's{(  scheduled-sweep:.*?)^    if: [^\n]*$}{$1    if: \$\{\{ \x27\x27 \}\}}sm' \
  fail "[#850 producer eligibility] job 'scheduled-sweep'"
# c8 — hexadecimal zero: GitHub's expression numerics accept 0x0 and it
#      evaluates falsy; float() alone never sees it.
mcg22_case c8 's{(  scheduled-sweep:.*?)^    if: [^\n]*$}{$1    if: \$\{\{ 0x0 \}\}}sm' \
  fail "[#850 producer eligibility] job 'scheduled-sweep'"
# k — a falsy if: on a producer STEP: the job-level condition stays truthy and
#     every string survives, but the publishing path is dead.
mcg22_case k 's{(      - name: Re-evaluate gate per PR and post check_run\n)(        if: )steps.find.outputs.prs[^\n]*}{$1$2\x27\x27}sm' \
  fail "[#850 producer eligibility] step"
# m — an always-false NON-literal condition: never true on the sweep's only
#     trigger, invisible to any falsy test, caught only by the exact
#     per-producer condition allowlist.
mcg22_case m 's{(  scheduled-sweep:.*?)^    if: [^\n]*$}{$1    if: github.event_name == \x27push\x27}sm' \
  fail "[#850 producer eligibility] job 'scheduled-sweep'"
# l — a path-qualified gh invocation must still demand its token binding.
mcg22_case l 's{(      - name: Open the required check_run.*?\n        run: \|\n)}{$1          /usr/bin/gh api /rate_limit >/dev/null\n}s && s{^          GH_TOKEN: [^\n]*\n(          REPO: \$\{\{ github.repository \}\}\n          # Bind to the PR HEAD)}{$1}m' \
  fail "[#850 gh token binding]"
unset MCG_TAG

# g — positive control on the REAL file. Case I uses a synthesized header; this
#     asserts the canonical workflow passes the whole check unmodified.
set +e
OUT=$(MCG_SKIP_FIX3_SELFTEST=1 \
  MERGE_CLEARANCE_WORKFLOW="$ROOT/.github/workflows/merge-clearance-gate.yml" \
  "$CHECK_BIN" 2>&1)
RC=$?
set -e
if [ "$RC" -eq 0 ]; then
  pass "#850 case g: the unmodified canonical workflow passes the whole check"
else
  fail "#850 case g: the canonical workflow must pass the check; got rc=$RC"
  grep '^FAIL' <<<"$OUT" | sed 's/^/      /' | head -4 >&2
fi
else
  echo; echo "SKIP: Test 24 (#850) — PyYAML unavailable (the check soft-skips it too)"
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
# Carries the owning-scope metadata (#781 item 1) so the ONLY thing keeping
# this ruleset from counting is the missing integration pin.
jq -n --arg n "$GATE_CHECK_NAME" '[{type:"required_status_checks",ruleset_id:101,ruleset_source_type:"Repository",ruleset_source:"owner/repo",parameters:{required_status_checks:[{context:$n}]}}]' >"$NOPIN_RULES"
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

# ---------------------------------------------------------------------------
# #781 item 1 — the ruleset's OWNING SCOPE selects the endpoint the bypass-actor
# lookup reads. A repo-only lookup makes every inherited org ruleset unreadable,
# hence unproven, hence arm 1 false forever on a centrally governed repo.
# ---------------------------------------------------------------------------

echo; echo "--- Protection 1q (#781 item 1): an INHERITED ORG ruleset is read from the org endpoint → true"
# The repository endpoint 404s for an org-owned ruleset (FIXTURE_RULESET_OBJ_FAIL
# models that), so this passes only if the probe follows ruleset_source_type.
SCRATCH=$(make_scratch false true)
FIXTURE_PR=$(make_pr_fixture "$HEAD_SHA" "someone")
FIXTURE_FILES=$(make_files_fixture '[{"filename":"src/auth/token.js","additions":2,"deletions":0}]')
FIXTURE_COMMENTS=$(make_comments_fixture '[]')
FIXTURE_PROTECTION=$(make_protection_fixture '["lint"]')
FIXTURE_RULESETS=$(make_rulesets_fixture "$(jq -n --arg n "$GATE_CHECK_NAME" '[$n]')" 101 Organization acme-org)
ORG_OBJ=$(make_ruleset_object_fixture "[]")
set +e
OUT=$(FIXTURE_PR="$FIXTURE_PR" FIXTURE_FILES="$FIXTURE_FILES" FIXTURE_COMMENTS="$FIXTURE_COMMENTS" \
      FIXTURE_PROTECTION="$FIXTURE_PROTECTION" FIXTURE_RULESETS="$FIXTURE_RULESETS" \
      FIXTURE_RULESET_OBJ_FAIL=1 FIXTURE_ORG_RULESET_OBJ="$ORG_OBJ" \
      MERGE_CLEARANCE_CODEX_CHECK_BIN="$STUB_DIR/codex-check-stub" CODEX_STUB_REQUIRE_HEAD_PIN=1 CODEX_STUB_RC=1 \
      run_gate "$SCRATCH" --derive-rate-limit-protection 99 owner/repo 2>/dev/null)
RC=$?
set -e
if [ "$RC" = 0 ] && [ "$OUT" = "true" ]; then
  pass "protection: inherited org ruleset resolved from orgs/{org}/rulesets → counted → true (#781 item 1)"
else
  fail "protection: inherited org ruleset expected true/0; got rc=$RC out='$OUT'"
fi

echo; echo "--- Protection 1q2 (#781 item 1): the org lookup actually hits orgs/{org}/rulesets/{id}"
if grep -qF "orgs/acme-org/rulesets/101" "$WORKDIR/gh-calls.log"; then
  pass "protection: org-scoped ruleset read used the organization endpoint"
else
  fail "protection: expected an orgs/acme-org/rulesets/101 call in the gh log"
fi

echo; echo "--- Protection 1r (#781 item 1): an ENTERPRISE-owned ruleset is not readable here → false"
# Enterprise rulesets live behind an enterprise-admin endpoint this token does
# not have. Unverifiable bypass actors are not proof — drop, do not guess.
SCRATCH=$(make_scratch false true)
FIXTURE_PR=$(make_pr_fixture "$HEAD_SHA" "someone")
FIXTURE_FILES=$(make_files_fixture '[{"filename":"src/auth/token.js","additions":2,"deletions":0}]')
FIXTURE_COMMENTS=$(make_comments_fixture '[]')
FIXTURE_PROTECTION=$(make_protection_fixture '["lint"]')
FIXTURE_RULESETS=$(make_rulesets_fixture "$(jq -n --arg n "$GATE_CHECK_NAME" '[$n]')" 101 Enterprise acme-ent)
set +e
OUT=$(FIXTURE_PR="$FIXTURE_PR" FIXTURE_FILES="$FIXTURE_FILES" FIXTURE_COMMENTS="$FIXTURE_COMMENTS" \
      FIXTURE_PROTECTION="$FIXTURE_PROTECTION" FIXTURE_RULESETS="$FIXTURE_RULESETS" \
      MERGE_CLEARANCE_CODEX_CHECK_BIN="$STUB_DIR/codex-check-stub" CODEX_STUB_REQUIRE_HEAD_PIN=1 CODEX_STUB_RC=1 \
      run_gate "$SCRATCH" --derive-rate-limit-protection 99 owner/repo 2>/dev/null)
RC=$?
set -e
if [ "$RC" = 0 ] && [ "$OUT" = "false" ]; then
  pass "protection: enterprise-owned ruleset → not counted → false (#781 item 1)"
else
  fail "protection: enterprise-owned ruleset expected false/0; got rc=$RC out='$OUT'"
fi

echo; echo "--- Protection 1s (#781 item 1): a rule with NO ruleset_source_type is not counted"
# An unrecognized payload shape cannot be verified, so it is dropped rather
# than assumed to be a repository ruleset.
SCRATCH=$(make_scratch false true)
FIXTURE_PR=$(make_pr_fixture "$HEAD_SHA" "someone")
FIXTURE_FILES=$(make_files_fixture '[{"filename":"src/auth/token.js","additions":2,"deletions":0}]')
FIXTURE_COMMENTS=$(make_comments_fixture '[]')
FIXTURE_PROTECTION=$(make_protection_fixture '["lint"]')
NOSRC_RULES="$WORKDIR/rulesets-nosrc.$$.json"
jq -n --arg n "$GATE_CHECK_NAME" '[{type:"required_status_checks",ruleset_id:101,parameters:{required_status_checks:[{context:$n,integration_id:15368}]}}]' >"$NOSRC_RULES"
set +e
OUT=$(FIXTURE_PR="$FIXTURE_PR" FIXTURE_FILES="$FIXTURE_FILES" FIXTURE_COMMENTS="$FIXTURE_COMMENTS" \
      FIXTURE_PROTECTION="$FIXTURE_PROTECTION" FIXTURE_RULESETS="$NOSRC_RULES" \
      MERGE_CLEARANCE_CODEX_CHECK_BIN="$STUB_DIR/codex-check-stub" CODEX_STUB_REQUIRE_HEAD_PIN=1 CODEX_STUB_RC=1 \
      run_gate "$SCRATCH" --derive-rate-limit-protection 99 owner/repo 2>/dev/null)
RC=$?
set -e
if [ "$RC" = 0 ] && [ "$OUT" = "false" ]; then
  pass "protection: rule with no ruleset_source_type → not counted → false (#781 item 1)"
else
  fail "protection: sourceless ruleset rule expected false/0; got rc=$RC out='$OUT'"
fi

echo; echo "--- Protection 1s2 (#781 item 1): an org ruleset_source that is not a bare login is rejected"
# $ruleset_source is interpolated into a URL path; a value carrying a slash
# would address a different resource entirely.
SCRATCH=$(make_scratch false true)
FIXTURE_PR=$(make_pr_fixture "$HEAD_SHA" "someone")
FIXTURE_FILES=$(make_files_fixture '[{"filename":"src/auth/token.js","additions":2,"deletions":0}]')
FIXTURE_COMMENTS=$(make_comments_fixture '[]')
FIXTURE_PROTECTION=$(make_protection_fixture '["lint"]')
FIXTURE_RULESETS=$(make_rulesets_fixture "$(jq -n --arg n "$GATE_CHECK_NAME" '[$n]')" 101 Organization "acme/../other")
ORG_OBJ=$(make_ruleset_object_fixture "[]")
set +e
OUT=$(FIXTURE_PR="$FIXTURE_PR" FIXTURE_FILES="$FIXTURE_FILES" FIXTURE_COMMENTS="$FIXTURE_COMMENTS" \
      FIXTURE_PROTECTION="$FIXTURE_PROTECTION" FIXTURE_RULESETS="$FIXTURE_RULESETS" \
      FIXTURE_ORG_RULESET_OBJ="$ORG_OBJ" \
      MERGE_CLEARANCE_CODEX_CHECK_BIN="$STUB_DIR/codex-check-stub" CODEX_STUB_REQUIRE_HEAD_PIN=1 CODEX_STUB_RC=1 \
      run_gate "$SCRATCH" --derive-rate-limit-protection 99 owner/repo 2>/dev/null)
RC=$?
set -e
if [ "$RC" = 0 ] && [ "$OUT" = "false" ]; then
  pass "protection: org ruleset_source that is not a bare login → not counted → false (#781 item 1)"
else
  fail "protection: malformed org ruleset_source expected false/0; got rc=$RC out='$OUT'"
fi

# ---------------------------------------------------------------------------
# #781 item 11 — bypass actors are evaluated against the MERGING identity
# instead of counted. The allowlist of provably-inapplicable actors is
# {DeployKey, Integration != the trusted Actions app}; every other actor type,
# and every unknown, still disqualifies the ruleset (the #772 r2 rule).
# Protection 1i above is the OrganizationAdmin half of the safety direction.
# ---------------------------------------------------------------------------

echo; echo "--- Protection 1t (#781 item 11): a bypass Integration that is NOT the merger → still enforcement → true"
# A deployment App is a different principal from the user account that runs
# `gh pr merge`, so it cannot make that merge unconstrained.
SCRATCH=$(make_scratch false true)
FIXTURE_PR=$(make_pr_fixture "$HEAD_SHA" "someone")
FIXTURE_FILES=$(make_files_fixture '[{"filename":"src/auth/token.js","additions":2,"deletions":0}]')
FIXTURE_COMMENTS=$(make_comments_fixture '[]')
FIXTURE_PROTECTION=$(make_protection_fixture '["lint"]')
FIXTURE_RULESETS=$(make_rulesets_fixture "$(jq -n --arg n "$GATE_CHECK_NAME" '[$n]')")
DEPLOY_APP_OBJ=$(make_ruleset_object_fixture '[{"actor_id":40001,"actor_type":"Integration","bypass_mode":"always"}]')
set +e
OUT=$(FIXTURE_PR="$FIXTURE_PR" FIXTURE_FILES="$FIXTURE_FILES" FIXTURE_COMMENTS="$FIXTURE_COMMENTS" \
      FIXTURE_PROTECTION="$FIXTURE_PROTECTION" FIXTURE_RULESETS="$FIXTURE_RULESETS" \
      FIXTURE_RULESET_OBJ="$DEPLOY_APP_OBJ" \
      MERGE_CLEARANCE_CODEX_CHECK_BIN="$STUB_DIR/codex-check-stub" CODEX_STUB_REQUIRE_HEAD_PIN=1 CODEX_STUB_RC=1 \
      run_gate "$SCRATCH" --derive-rate-limit-protection 99 owner/repo 2>/dev/null)
RC=$?
set -e
if [ "$RC" = 0 ] && [ "$OUT" = "true" ]; then
  pass "protection: non-merging bypass Integration ruled out → ruleset still counts → true (#781 item 11)"
else
  fail "protection: non-merging bypass Integration expected true/0; got rc=$RC out='$OUT'"
fi

echo; echo "--- Protection 1u (#781 item 11): a bypass DeployKey cannot merge a PR → still enforcement → true"
SCRATCH=$(make_scratch false true)
FIXTURE_PR=$(make_pr_fixture "$HEAD_SHA" "someone")
FIXTURE_FILES=$(make_files_fixture '[{"filename":"src/auth/token.js","additions":2,"deletions":0}]')
FIXTURE_COMMENTS=$(make_comments_fixture '[]')
FIXTURE_PROTECTION=$(make_protection_fixture '["lint"]')
FIXTURE_RULESETS=$(make_rulesets_fixture "$(jq -n --arg n "$GATE_CHECK_NAME" '[$n]')")
DEPLOYKEY_OBJ=$(make_ruleset_object_fixture '[{"actor_id":null,"actor_type":"DeployKey","bypass_mode":"always"}]')
set +e
OUT=$(FIXTURE_PR="$FIXTURE_PR" FIXTURE_FILES="$FIXTURE_FILES" FIXTURE_COMMENTS="$FIXTURE_COMMENTS" \
      FIXTURE_PROTECTION="$FIXTURE_PROTECTION" FIXTURE_RULESETS="$FIXTURE_RULESETS" \
      FIXTURE_RULESET_OBJ="$DEPLOYKEY_OBJ" \
      MERGE_CLEARANCE_CODEX_CHECK_BIN="$STUB_DIR/codex-check-stub" CODEX_STUB_REQUIRE_HEAD_PIN=1 CODEX_STUB_RC=1 \
      run_gate "$SCRATCH" --derive-rate-limit-protection 99 owner/repo 2>/dev/null)
RC=$?
set -e
if [ "$RC" = 0 ] && [ "$OUT" = "true" ]; then
  pass "protection: bypass DeployKey ruled out (no API merge path) → ruleset still counts → true (#781 item 11)"
else
  fail "protection: bypass DeployKey expected true/0; got rc=$RC out='$OUT'"
fi

echo; echo "--- Protection 1v (#781 item 11): a bypass Team can contain the merger → NOT enforcement → false"
# The #772 r2 defect must stay fixed: a Team is a set of accounts that can
# include author_identity, and membership is not decidable from this token.
SCRATCH=$(make_scratch false true)
FIXTURE_PR=$(make_pr_fixture "$HEAD_SHA" "someone")
FIXTURE_FILES=$(make_files_fixture '[{"filename":"src/auth/token.js","additions":2,"deletions":0}]')
FIXTURE_COMMENTS=$(make_comments_fixture '[]')
FIXTURE_PROTECTION=$(make_protection_fixture '["lint"]')
FIXTURE_RULESETS=$(make_rulesets_fixture "$(jq -n --arg n "$GATE_CHECK_NAME" '[$n]')")
TEAM_OBJ=$(make_ruleset_object_fixture '[{"actor_id":77,"actor_type":"Team","bypass_mode":"always"}]')
set +e
OUT=$(FIXTURE_PR="$FIXTURE_PR" FIXTURE_FILES="$FIXTURE_FILES" FIXTURE_COMMENTS="$FIXTURE_COMMENTS" \
      FIXTURE_PROTECTION="$FIXTURE_PROTECTION" FIXTURE_RULESETS="$FIXTURE_RULESETS" \
      FIXTURE_RULESET_OBJ="$TEAM_OBJ" \
      MERGE_CLEARANCE_CODEX_CHECK_BIN="$STUB_DIR/codex-check-stub" CODEX_STUB_REQUIRE_HEAD_PIN=1 CODEX_STUB_RC=1 \
      run_gate "$SCRATCH" --derive-rate-limit-protection 99 owner/repo 2>/dev/null)
RC=$?
set -e
if [ "$RC" = 0 ] && [ "$OUT" = "false" ]; then
  pass "protection: bypass Team not ruled out → ruleset not counted → false (#772 r2 preserved)"
else
  fail "protection: bypass Team expected false/0; got rc=$RC out='$OUT'"
fi

echo; echo "--- Protection 1v2 (#781 item 11): a bypass RepositoryRole is NOT ruled out → false"
SCRATCH=$(make_scratch false true)
FIXTURE_PR=$(make_pr_fixture "$HEAD_SHA" "someone")
FIXTURE_FILES=$(make_files_fixture '[{"filename":"src/auth/token.js","additions":2,"deletions":0}]')
FIXTURE_COMMENTS=$(make_comments_fixture '[]')
FIXTURE_PROTECTION=$(make_protection_fixture '["lint"]')
FIXTURE_RULESETS=$(make_rulesets_fixture "$(jq -n --arg n "$GATE_CHECK_NAME" '[$n]')")
ROLE_OBJ=$(make_ruleset_object_fixture '[{"actor_id":5,"actor_type":"RepositoryRole","bypass_mode":"always"}]')
set +e
OUT=$(FIXTURE_PR="$FIXTURE_PR" FIXTURE_FILES="$FIXTURE_FILES" FIXTURE_COMMENTS="$FIXTURE_COMMENTS" \
      FIXTURE_PROTECTION="$FIXTURE_PROTECTION" FIXTURE_RULESETS="$FIXTURE_RULESETS" \
      FIXTURE_RULESET_OBJ="$ROLE_OBJ" \
      MERGE_CLEARANCE_CODEX_CHECK_BIN="$STUB_DIR/codex-check-stub" CODEX_STUB_REQUIRE_HEAD_PIN=1 CODEX_STUB_RC=1 \
      run_gate "$SCRATCH" --derive-rate-limit-protection 99 owner/repo 2>/dev/null)
RC=$?
set -e
if [ "$RC" = 0 ] && [ "$OUT" = "false" ]; then
  pass "protection: bypass RepositoryRole not ruled out → false (#772 r2 preserved)"
else
  fail "protection: bypass RepositoryRole expected false/0; got rc=$RC out='$OUT'"
fi

echo; echo "--- Protection 1w (#781 item 11): an UNKNOWN future actor_type fails closed → false"
SCRATCH=$(make_scratch false true)
FIXTURE_PR=$(make_pr_fixture "$HEAD_SHA" "someone")
FIXTURE_FILES=$(make_files_fixture '[{"filename":"src/auth/token.js","additions":2,"deletions":0}]')
FIXTURE_COMMENTS=$(make_comments_fixture '[]')
FIXTURE_PROTECTION=$(make_protection_fixture '["lint"]')
FIXTURE_RULESETS=$(make_rulesets_fixture "$(jq -n --arg n "$GATE_CHECK_NAME" '[$n]')")
FUTURE_OBJ=$(make_ruleset_object_fixture '[{"actor_id":9,"actor_type":"SomeFutureActorType","bypass_mode":"always"}]')
set +e
OUT=$(FIXTURE_PR="$FIXTURE_PR" FIXTURE_FILES="$FIXTURE_FILES" FIXTURE_COMMENTS="$FIXTURE_COMMENTS" \
      FIXTURE_PROTECTION="$FIXTURE_PROTECTION" FIXTURE_RULESETS="$FIXTURE_RULESETS" \
      FIXTURE_RULESET_OBJ="$FUTURE_OBJ" \
      MERGE_CLEARANCE_CODEX_CHECK_BIN="$STUB_DIR/codex-check-stub" CODEX_STUB_REQUIRE_HEAD_PIN=1 CODEX_STUB_RC=1 \
      run_gate "$SCRATCH" --derive-rate-limit-protection 99 owner/repo 2>/dev/null)
RC=$?
set -e
if [ "$RC" = 0 ] && [ "$OUT" = "false" ]; then
  pass "protection: unknown bypass actor_type fails closed → false (allowlist, not blocklist)"
else
  fail "protection: unknown bypass actor_type expected false/0; got rc=$RC out='$OUT'"
fi

echo; echo "--- Protection 1x (#781 item 11): a bypass Integration for the TRUSTED Actions app is not ruled out → false"
# Workflow steps in this repo authenticate as github-actions, so granting that
# app bypass is not provably outside the merge path.
SCRATCH=$(make_scratch false true)
FIXTURE_PR=$(make_pr_fixture "$HEAD_SHA" "someone")
FIXTURE_FILES=$(make_files_fixture '[{"filename":"src/auth/token.js","additions":2,"deletions":0}]')
FIXTURE_COMMENTS=$(make_comments_fixture '[]')
FIXTURE_PROTECTION=$(make_protection_fixture '["lint"]')
FIXTURE_RULESETS=$(make_rulesets_fixture "$(jq -n --arg n "$GATE_CHECK_NAME" '[$n]')")
ACTIONS_APP_OBJ=$(make_ruleset_object_fixture '[{"actor_id":15368,"actor_type":"Integration","bypass_mode":"always"}]')
set +e
OUT=$(FIXTURE_PR="$FIXTURE_PR" FIXTURE_FILES="$FIXTURE_FILES" FIXTURE_COMMENTS="$FIXTURE_COMMENTS" \
      FIXTURE_PROTECTION="$FIXTURE_PROTECTION" FIXTURE_RULESETS="$FIXTURE_RULESETS" \
      FIXTURE_RULESET_OBJ="$ACTIONS_APP_OBJ" \
      MERGE_CLEARANCE_CODEX_CHECK_BIN="$STUB_DIR/codex-check-stub" CODEX_STUB_REQUIRE_HEAD_PIN=1 CODEX_STUB_RC=1 \
      run_gate "$SCRATCH" --derive-rate-limit-protection 99 owner/repo 2>/dev/null)
RC=$?
set -e
if [ "$RC" = 0 ] && [ "$OUT" = "false" ]; then
  pass "protection: bypass Integration for the trusted Actions app → not ruled out → false"
else
  fail "protection: trusted-app bypass Integration expected false/0; got rc=$RC out='$OUT'"
fi

echo; echo "--- Protection 1y (#781 item 11): one rule-out-able + one not → the ruleset still fails closed"
SCRATCH=$(make_scratch false true)
FIXTURE_PR=$(make_pr_fixture "$HEAD_SHA" "someone")
FIXTURE_FILES=$(make_files_fixture '[{"filename":"src/auth/token.js","additions":2,"deletions":0}]')
FIXTURE_COMMENTS=$(make_comments_fixture '[]')
FIXTURE_PROTECTION=$(make_protection_fixture '["lint"]')
FIXTURE_RULESETS=$(make_rulesets_fixture "$(jq -n --arg n "$GATE_CHECK_NAME" '[$n]')")
MIXED_OBJ=$(make_ruleset_object_fixture '[{"actor_id":40001,"actor_type":"Integration","bypass_mode":"always"},{"actor_id":1,"actor_type":"OrganizationAdmin","bypass_mode":"always"}]')
set +e
OUT=$(FIXTURE_PR="$FIXTURE_PR" FIXTURE_FILES="$FIXTURE_FILES" FIXTURE_COMMENTS="$FIXTURE_COMMENTS" \
      FIXTURE_PROTECTION="$FIXTURE_PROTECTION" FIXTURE_RULESETS="$FIXTURE_RULESETS" \
      FIXTURE_RULESET_OBJ="$MIXED_OBJ" \
      MERGE_CLEARANCE_CODEX_CHECK_BIN="$STUB_DIR/codex-check-stub" CODEX_STUB_REQUIRE_HEAD_PIN=1 CODEX_STUB_RC=1 \
      run_gate "$SCRATCH" --derive-rate-limit-protection 99 owner/repo 2>/dev/null)
RC=$?
set -e
if [ "$RC" = 0 ] && [ "$OUT" = "false" ]; then
  pass "protection: a single un-ruled-out bypass actor disqualifies the whole ruleset → false"
else
  fail "protection: mixed bypass actors expected false/0; got rc=$RC out='$OUT'"
fi

echo; echo "--- Protection 1z (#781 item 11): merging identity UNKNOWN → nothing is ruled out → false"
# With author_identity absent from the governing policy the "an App is not the
# merger" premise does not hold, so the probe keeps the strict #772 r2 rule.
SCRATCH=$(make_scratch false true "")
FIXTURE_PR=$(make_pr_fixture "$HEAD_SHA" "someone")
FIXTURE_FILES=$(make_files_fixture '[{"filename":"src/auth/token.js","additions":2,"deletions":0}]')
FIXTURE_COMMENTS=$(make_comments_fixture '[]')
FIXTURE_PROTECTION=$(make_protection_fixture '["lint"]')
FIXTURE_RULESETS=$(make_rulesets_fixture "$(jq -n --arg n "$GATE_CHECK_NAME" '[$n]')")
DEPLOYKEY_OBJ=$(make_ruleset_object_fixture '[{"actor_id":null,"actor_type":"DeployKey","bypass_mode":"always"}]')
set +e
OUT=$(FIXTURE_PR="$FIXTURE_PR" FIXTURE_FILES="$FIXTURE_FILES" FIXTURE_COMMENTS="$FIXTURE_COMMENTS" \
      FIXTURE_PROTECTION="$FIXTURE_PROTECTION" FIXTURE_RULESETS="$FIXTURE_RULESETS" \
      FIXTURE_RULESET_OBJ="$DEPLOYKEY_OBJ" \
      MERGE_CLEARANCE_CODEX_CHECK_BIN="$STUB_DIR/codex-check-stub" CODEX_STUB_REQUIRE_HEAD_PIN=1 CODEX_STUB_RC=1 \
      run_gate "$SCRATCH" --derive-rate-limit-protection 99 owner/repo 2>/dev/null)
RC=$?
set -e
if [ "$RC" = 0 ] && [ "$OUT" = "false" ]; then
  pass "protection: author_identity absent → no bypass actor ruled out → false (#772 r2 behaviour retained)"
else
  fail "protection: unknown merging identity expected false/0; got rc=$RC out='$OUT'"
fi

echo; echo "--- Protection 1z2 (#781 item 11): a [bot] merging identity disables the Integration rule-out → false"
SCRATCH=$(make_scratch false true "some-app[bot]")
FIXTURE_PR=$(make_pr_fixture "$HEAD_SHA" "someone")
FIXTURE_FILES=$(make_files_fixture '[{"filename":"src/auth/token.js","additions":2,"deletions":0}]')
FIXTURE_COMMENTS=$(make_comments_fixture '[]')
FIXTURE_PROTECTION=$(make_protection_fixture '["lint"]')
FIXTURE_RULESETS=$(make_rulesets_fixture "$(jq -n --arg n "$GATE_CHECK_NAME" '[$n]')")
DEPLOY_APP_OBJ=$(make_ruleset_object_fixture '[{"actor_id":40001,"actor_type":"Integration","bypass_mode":"always"}]')
set +e
OUT=$(FIXTURE_PR="$FIXTURE_PR" FIXTURE_FILES="$FIXTURE_FILES" FIXTURE_COMMENTS="$FIXTURE_COMMENTS" \
      FIXTURE_PROTECTION="$FIXTURE_PROTECTION" FIXTURE_RULESETS="$FIXTURE_RULESETS" \
      FIXTURE_RULESET_OBJ="$DEPLOY_APP_OBJ" \
      MERGE_CLEARANCE_CODEX_CHECK_BIN="$STUB_DIR/codex-check-stub" CODEX_STUB_REQUIRE_HEAD_PIN=1 CODEX_STUB_RC=1 \
      run_gate "$SCRATCH" --derive-rate-limit-protection 99 owner/repo 2>/dev/null)
RC=$?
set -e
if [ "$RC" = 0 ] && [ "$OUT" = "false" ]; then
  pass "protection: app-shaped author_identity → Integration rule-out disabled → false"
else
  fail "protection: [bot] merging identity expected false/0; got rc=$RC out='$OUT'"
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
