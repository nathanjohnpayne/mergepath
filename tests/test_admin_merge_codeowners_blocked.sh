#!/usr/bin/env bash
# tests/test_admin_merge_codeowners_blocked.sh
#
# Regression tests for the #691 statusCheckRollup pagination fix in
# scripts/admin-merge-codeowners-blocked.sh (Gate 2, the green-checks gate).
#
# The bug: Gate 2 read the head commit's checks with
# `gh pr view --json statusCheckRollup`, whose GraphQL --json shape requests
# only the first 100 contexts and strips pageInfo. On a long-lived PR whose
# head commit has accumulated >100 check-runs (repeated scheduled-sweep
# re-evaluations routinely push this past 100 — 194 observed on #687), a
# FAILING check beyond the first page was silently invisible, so this gate —
# whose whole job is to refuse an --admin merge unless every check is green —
# would wave the merge straight past an off-page red check.
#
# The fix: a Relay cursor loop (mirroring scripts/codex-review-check.sh's
# #655 rollup fetch) assembles ALL contexts before the green filter runs, so
# a failure on any page is seen. Full pagination — not a fail-closed >100
# refusal — because >100 contexts is the NORMAL state for the long-lived
# CODEOWNERS-deadlocked PRs this helper targets.
#
# Strategy mirrors tests/test_resolve_pr_threads_staleness_pagination.sh:
# stub `gh` via PATH-prepend, capture argv to a side log (a thin wrapper
# records each call's argv to <log>.lastcall before exec'ing the real stub),
# shape multi-page statusCheckRollup GraphQL fixtures keyed on the cursor in
# argv, and assert on the refusal (or its absence) plus the paginating argv.
# Fully offline; bash 3.2 portable.
#
# Cases:
#   1. Off-page red check: page 1 is all-green, page 2 carries a FAILING
#      "lint" check. Gate 2 must refuse ("checks not green (lint)"), exit
#      non-zero, never reach the merge — and the argv must show the page-2
#      cursor (proof it actually paginated rather than reading page 1 only).
#   2. Green across two pages: every check on both pages is green. Gate 2
#      must PASS (no "checks not green") and the script must proceed to the
#      review gate (Gate 3) — proving pagination neither false-positives nor
#      spuriously fails closed on a >100-context PR, the exact input this
#      helper exists to serve.
#   3. Structural: the real script pages the rollup via a cursor loop and no
#      longer uses the truncating `gh pr view --json statusCheckRollup`.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/scripts/admin-merge-codeowners-blocked.sh"
[ -f "$SCRIPT" ] || { echo "missing $SCRIPT" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not available" >&2; exit 0; }

pass=0
fail=0

SCRATCH=$(mktemp -d)
trap 'rm -rf "$SCRATCH"' EXIT

# Fixture repo tree: copy the script so its $(dirname BASH_SOURCE)/.. paths
# resolve inside the fixture, and ship the executable gh-as-author.sh the
# script hard-requires at startup (a no-op — the merge is never reached on
# the refuse paths under test).
FIXTURE_ROOT="$SCRATCH/repo"
mkdir -p "$FIXTURE_ROOT/scripts"
cp "$SCRIPT" "$FIXTURE_ROOT/scripts/admin-merge-codeowners-blocked.sh"
cat > "$FIXTURE_ROOT/scripts/gh-as-author.sh" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
chmod +x "$FIXTURE_ROOT/scripts/gh-as-author.sh"

# make_gh_stub <stub-path>
# Routes:
#   pr view              → Gate 1 mergeStateStatus scalar (post-jq): the
#                          CODEOWNERS-deadlock BLOCKED state this helper runs on
#   pr merge             → record MERGE-ATTEMPTED (must NOT happen on refuse)
#   api graphql (rollup) → statusCheckRollup pages: page 2 when the endCursor
#                          ROLLCURSOR2 is in argv, else page 1; served from
#                          $ROLLUP_PAGE1_FILE / $ROLLUP_PAGE2_FILE
#   api graphql (other)  → reviews query etc. → '{}' (Gate 3 finds no
#                          qualifying approval and refuses; keeps case 2
#                          from driving a live merge)
make_gh_stub() {
  local stub_path="$1"
  cat > "$stub_path" <<'GH_STUB'
#!/usr/bin/env bash
echo "ARGV: $*" >> "$GH_ARGV_LOG"
case "$1" in
  pr)
    case "$2" in
      view)
        # Gate 1 reads state|mergeable|mergeStateStatus|headRefOid|title via
        # gh's own --jq; the stub returns the already-projected scalar.
        echo "OPEN|MERGEABLE|BLOCKED|deadbeefHEAD|Test PR (off-page check)"
        ;;
      merge)
        echo "MERGE-ATTEMPTED" >> "$GH_ARGV_LOG"
        ;;
      *) echo "" ;;
    esac
    ;;
  api)
    case "$2" in
      graphql)
        if grep -q "statusCheckRollup" "$GH_ARGV_LOG.lastcall"; then
          if grep -q "cursor=ROLLCURSOR2" "$GH_ARGV_LOG.lastcall"; then
            cat "$ROLLUP_PAGE2_FILE"
          else
            cat "$ROLLUP_PAGE1_FILE"
          fi
        else
          # Gate 3 reviews query (or anything else): no qualifying approval.
          echo '{}'
        fi
        ;;
      *) echo '{}' ;;
    esac
    ;;
  *) exit 0 ;;
esac
exit 0
GH_STUB
  chmod +x "$stub_path"
}

# make_gh_wrapper <wrapper-path> <real-stub>
# Records each call's argv to <log>.lastcall (single '>' — the current call
# only) so the stub can route on THIS call's cursor, then execs the stub.
make_gh_wrapper() {
  local wrapper_path="$1"
  local real_stub="$2"
  cat > "$wrapper_path" <<WRAP_STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" > "\$GH_ARGV_LOG.lastcall"
exec "$real_stub" "\$@"
WRAP_STUB
  chmod +x "$wrapper_path"
}

# rollup_page <hasNextPage> <endCursor-or-empty> <nodes-json> → GraphQL page
rollup_page() {
  jq -nc --argjson hn "$1" --arg ec "$2" --argjson nodes "$3" '
    {data:{repository:{pullRequest:{commits:{nodes:[{commit:{statusCheckRollup:{
      contexts:{
        pageInfo:{hasNextPage:$hn, endCursor:(if $ec=="" then null else $ec end)},
        nodes:$nodes
      }
    }}}]}}}}}'
}

run_admin_merge() {
  # run_admin_merge <page1-file> <page2-file> → captures output + rc
  local page1="$1" page2="$2"
  make_gh_stub "$SCRATCH/gh-real"
  make_gh_wrapper "$SCRATCH/gh" "$SCRATCH/gh-real"
  set +e
  RUN_OUT=$(
    GH_ARGV_LOG="$GH_ARGV_LOG" \
    ROLLUP_PAGE1_FILE="$page1" \
    ROLLUP_PAGE2_FILE="$page2" \
    PATH="$SCRATCH:$PATH" \
    env -u OP_PREFLIGHT_REVIEWER_PAT -u GH_TOKEN \
    bash "$FIXTURE_ROOT/scripts/admin-merge-codeowners-blocked.sh" test/repo#99999 2>&1
  )
  RUN_RC=$?
  set -e
}

# ─────────────────────────────────────────────────────────────────────
# Test 1: off-page red check → Gate 2 refuses, no merge, paginated.
#   page 1: build + test, both green, hasNextPage=true, endCursor=ROLLCURSOR2
#   page 2: lint, CheckRun COMPLETED/FAILURE (the off-page failure)
# ─────────────────────────────────────────────────────────────────────
echo "Test 1: off-page failing check → refuse + paginate (#691)"
rollup_page true  ROLLCURSOR2 '[
  {"__typename":"CheckRun","name":"build","status":"COMPLETED","conclusion":"SUCCESS"},
  {"__typename":"CheckRun","name":"test","status":"COMPLETED","conclusion":"SUCCESS"}
]' > "$SCRATCH/p1_fail.json"
rollup_page false "" '[
  {"__typename":"CheckRun","name":"lint","status":"COMPLETED","conclusion":"FAILURE"}
]' > "$SCRATCH/p2_fail.json"

GH_ARGV_LOG="$SCRATCH/t1.log"; : > "$GH_ARGV_LOG"
run_admin_merge "$SCRATCH/p1_fail.json" "$SCRATCH/p2_fail.json"

if [ "$RUN_RC" -ne 0 ] \
   && grep -q 'checks not green (lint)' <<<"$RUN_OUT" \
   && grep -q 'cursor=ROLLCURSOR2' "$GH_ARGV_LOG" \
   && ! grep -q 'MERGE-ATTEMPTED' "$GH_ARGV_LOG"; then
  pass=$((pass + 1))
  echo "  PASS: page-2 red check surfaced via pagination — merge refused, cursor walked, no merge attempted"
else
  fail=$((fail + 1))
  echo "  FAIL: off-page red check not caught (rc=$RUN_RC)" >&2
  echo "    script output:" >&2; echo "$RUN_OUT" | sed 's/^/      /' >&2
  echo "    captured argv:" >&2; sed 's/^/      /' "$GH_ARGV_LOG" >&2
fi

# ─────────────────────────────────────────────────────────────────────
# Test 2: all-green across two pages → Gate 2 passes, reaches Gate 3.
# Proves pagination doesn't false-positive and — crucially — doesn't
# spuriously fail closed on a >100-context PR (the tool's intended input).
# ─────────────────────────────────────────────────────────────────────
echo
echo "Test 2: green across two pages → past Gate 2 to the review gate (#691)"
rollup_page true  ROLLCURSOR2 '[
  {"__typename":"CheckRun","name":"build","status":"COMPLETED","conclusion":"SUCCESS"},
  {"__typename":"StatusContext","context":"ci/legacy","state":"SUCCESS"}
]' > "$SCRATCH/p1_ok.json"
rollup_page false "" '[
  {"__typename":"CheckRun","name":"deploy","status":"COMPLETED","conclusion":"SKIPPED"}
]' > "$SCRATCH/p2_ok.json"

GH_ARGV_LOG="$SCRATCH/t2.log"; : > "$GH_ARGV_LOG"
run_admin_merge "$SCRATCH/p1_ok.json" "$SCRATCH/p2_ok.json"

# Past Gate 2 iff no "checks not green" AND the script went on to issue the
# Gate 3 reviews GraphQL query (reviews(first:100)) — which then finds no
# qualifying approval and refuses. Either way, Gate 2 let it through.
if ! grep -q 'checks not green' <<<"$RUN_OUT" \
   && ! grep -q 'could not read check status' <<<"$RUN_OUT" \
   && grep -q 'cursor=ROLLCURSOR2' "$GH_ARGV_LOG" \
   && grep -q 'reviews(first' "$GH_ARGV_LOG"; then
  pass=$((pass + 1))
  echo "  PASS: fully-green two-page rollup cleared Gate 2 and advanced to the review gate"
else
  fail=$((fail + 1))
  echo "  FAIL: green two-page rollup did not cleanly pass Gate 2 (rc=$RUN_RC)" >&2
  echo "    script output:" >&2; echo "$RUN_OUT" | sed 's/^/      /' >&2
  echo "    captured argv:" >&2; sed 's/^/      /' "$GH_ARGV_LOG" >&2
fi

# ─────────────────────────────────────────────────────────────────────
# Test 3: structural — the real script pages the rollup and no longer
# uses the truncating gh pr view --json statusCheckRollup.
# ─────────────────────────────────────────────────────────────────────
echo
echo "Test 3: structural — rollup is cursor-paginated, no gh pr view --json statusCheckRollup (#691)"
# Strip full-line comments before the negative check: the fix's own
# explanatory comment names the old `gh pr view --json statusCheckRollup`
# form, and that mention must not read as the code still using it.
SCRIPT_CODE=$(grep -vE '^[[:space:]]*#' "$SCRIPT")
if grep -Fq 'contexts(first: 100, after: $cursor)' "$SCRIPT" \
   && grep -Fq 'pageInfo { hasNextPage endCursor }' "$SCRIPT" \
   && ! grep -Eq 'pr view.*--json statusCheckRollup' <<<"$SCRIPT_CODE"; then
  pass=$((pass + 1))
  echo "  PASS: Gate 2 fetches statusCheckRollup via a Relay cursor loop, not the first-100 --json shape"
else
  fail=$((fail + 1))
  echo "  FAIL: Gate 2 still uses (or no longer pages away from) the truncating rollup read" >&2
fi

echo
if [ "$fail" -eq 0 ]; then
  echo "test_admin_merge_codeowners_blocked: PASS ($pass tests)"
  exit 0
else
  echo "test_admin_merge_codeowners_blocked: FAIL ($fail of $((pass + fail)) tests)" >&2
  exit 1
fi
