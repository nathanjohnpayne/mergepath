#!/usr/bin/env bash
# tests/test_dependabot_auto_merge_check_wait.sh
#
# Behavioral regression coverage for the Dependabot current-HEAD check wait
# in .github/workflows/dependabot-auto-merge.yml. The PATH-shimmed gh stub
# requires a paginated, GET, form-encoded check-name lookup and models the
# three decisions the embedded shell makes: success, never-seen timeout, and
# seen-but-pending timeout. This complements the structural checks in
# scripts/ci/check_workflow_parsers, which cannot prove the request shape or
# timeout classification.
#
# It also covers the Dependabot commit-provenance wiring: the workflow's
# "Verify Dependabot commit provenance" step and its in-step
# require_dependabot_provenance re-check, both run against a PATH-shimmed gh
# serving the PR commits list (trusted, foreign-commit, unreadable).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKFLOW="$ROOT/.github/workflows/dependabot-auto-merge.yml"

[ -r "$WORKFLOW" ] || { echo "missing workflow: $WORKFLOW" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not available" >&2; exit 0; }

PASS=0
FAIL=0
pass() { echo "PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $*" >&2; FAIL=$((FAIL + 1)); }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/dependabot-current-head-check.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
SHIM_DIR="$WORK/bin"
FUNCTIONS="$WORK/functions.sh"
SHIM_LOG="$WORK/gh.log"
mkdir -p "$SHIM_DIR"

extract_function() {
  local name="$1"
  local file="${2:-$WORKFLOW}"
  # The strip width is derived from the MATCHED header line's own
  # indentation, not hardcoded (#904): a hardcoded `sub(/^          /,
  # "")` (10 spaces) is silently wrong the moment the workflow's `run:
  # |` block indentation changes for any unrelated reason, mis-dedenting
  # every extracted line rather than failing loudly.
  awk -v name="$name" '
    $0 ~ "^[[:space:]]*" name "\\(\\)[[:space:]]*\\{" {
      capture = 1
      match($0, /^[[:space:]]*/)
      indent = RLENGTH
    }
    capture {
      line = $0
      if (length(line) >= indent) line = substr(line, indent + 1)
      print line
    }
    capture && /^[[:space:]]*}[[:space:]]*$/ {
      exit
    }
  ' "$file"
}

{
  extract_function latest_check_run
  printf '\n'
  extract_function require_current_head_check_success
} >"$FUNCTIONS"

if grep -Fq 'latest_check_run()' "$FUNCTIONS" && \
   grep -Fq 'require_current_head_check_success()' "$FUNCTIONS"; then
  pass "extracted the live workflow functions"
else
  fail "could not extract current-head check functions from workflow"
fi

# extract_function's dedent must be DERIVED from the matched header
# line's own indentation, not a value hardcoded to this workflow's
# current `run: |` nesting (#904). Prove it against a fixture indented
# at a DIFFERENT level (4 spaces) than the real workflow (10 spaces): a
# hardcoded strip width would either mis-dedent (leaving stray leading
# spaces) or, if the fixture line is shorter than the hardcoded width,
# eat into the content itself.
INDENT_FIXTURE="$WORK/indent-fixture.yml"
cat >"$INDENT_FIXTURE" <<'FIXTURE'
some:
  unrelated: yaml
    other_function() {
      echo "line one"
      echo "line two"
    }
FIXTURE
indent_extracted="$(extract_function other_function "$INDENT_FIXTURE")"
indent_expected='other_function() {
  echo "line one"
  echo "line two"
}'
if [ "$indent_extracted" = "$indent_expected" ]; then
  pass "extract_function derives the dedent width from the header's own indentation"
else
  fail "extract_function dedent is not indentation-derived; got: $indent_extracted"
fi

cat >"$SHIM_DIR/gh" <<'SHIM'
#!/usr/bin/env bash
set -euo pipefail

printf '%s\n' "$*" >>"$SHIM_LOG"
# Argument-boundary-preserving companion log (#905): $* collapses a
# single argument containing spaces with two adjacent tokens separated
# by a space, so the $*-joined line above cannot by itself prove the
# form-encoded check_name is ONE argv element. This uses a unit
# separator (0x1f) that cannot occur inside a shell argv element to
# record each argument distinctly, one record per invocation.
{ printf '%s\x1f' "$@"; printf '\n'; } >>"${SHIM_LOG}.argv"

require_arg() {
  local expected="$1"
  shift
  local arg
  for arg in "$@"; do
    [ "$arg" = "$expected" ] && return 0
  done
  echo "gh shim: missing expected argument: $expected" >&2
  exit 91
}

case "${1:-}" in
  pr)
    [ "${2:-}" = view ] || { echo "gh shim: unexpected pr command" >&2; exit 92; }
    printf '%s\n' "${FAKE_HEAD:-test-head}"
    ;;
  api)
    shift
    require_arg --paginate "$@"
    require_arg -X "$@"
    require_arg GET "$@"
    require_arg "repos/${GITHUB_REPOSITORY}/commits/${FAKE_HEAD:-test-head}/check-runs" "$@"
    require_arg "check_name=${FAKE_CHECK_NAME:-Label Gate}" "$@"
    require_arg per_page=100 "$@"
    case "${FAKE_MODE:-success}" in
      success)
        cat <<'JSON'
{"check_runs":[{"name":"Label Gate","status":"completed","conclusion":"success","started_at":"2026-08-04T00:01:00Z"},{"name":"Other","status":"completed","conclusion":"failure","started_at":"2026-08-04T00:02:00Z"}]}
{"check_runs":[{"name":"Label Gate","status":"completed","conclusion":"failure","started_at":"2026-08-04T00:00:00Z"}]}
JSON
        ;;
      absent)
        printf '%s\n' '{"check_runs":[]}'
        ;;
      pending)
        printf '%s\n' '{"check_runs":[{"name":"Label Gate","status":"in_progress","conclusion":null,"started_at":"2026-08-04T00:00:00Z"}]}'
        ;;
      *)
        echo "gh shim: unknown FAKE_MODE=${FAKE_MODE:-}" >&2
        exit 93
        ;;
    esac
    ;;
  *)
    echo "gh shim: unexpected command: ${1:-}" >&2
    exit 94
    ;;
esac
SHIM
chmod +x "$SHIM_DIR/gh"

run_functions() {
  local mode="$1"
  local action="$2"
  PATH="$SHIM_DIR:$PATH" \
    SHIM_LOG="$SHIM_LOG" \
    FAKE_MODE="$mode" \
    FAKE_HEAD=test-head \
    FAKE_CHECK_NAME='Label Gate' \
    GITHUB_REPOSITORY=owner/repo \
    PR_URL=https://example.test/owner/repo/pull/1 \
    REQUIRED_HEAD_CHECK_NAME='Label Gate' \
    TEST_CHECK_WAIT_SECONDS=0 \
    TEST_CHECK_POLL_SECONDS=0 \
    bash -c '
      set -euo pipefail
      source "$1"
      case "$2" in
        latest) latest_check_run "Label Gate" test-head ;;
        gate) require_current_head_check_success ;;
      esac
    ' bash "$FUNCTIONS" "$action"
}

: >"$SHIM_LOG"
: >"${SHIM_LOG}.argv"
if latest_output="$(run_functions success latest)"; then
  if [ "$(printf '%s' "$latest_output" | jq -c '{name,status,conclusion}')" = '{"name":"Label Gate","status":"completed","conclusion":"success"}' ]; then
    pass "paginated filtered lookup selects the latest exact-name run"
  else
    fail "latest lookup returned the wrong run: $latest_output"
  fi
else
  fail "paginated filtered lookup failed"
fi

# This checks the OVERALL invocation shape and ordering via the $*-joined
# log line. $* alone would collapse a single argument containing spaces
# (e.g. `check_name=Label Gate` as one token) with two adjacent tokens
# that happen to be separated by a space, so it cannot by itself prove
# which one occurred — it is redundant/weaker coverage of flag order,
# not of the argument boundary (#905).
if grep -Fq -- '--paginate -X GET repos/owner/repo/commits/test-head/check-runs -f check_name=Label Gate -F per_page=100' "$SHIM_LOG"; then
  pass "lookup's overall invocation shape matches the expected flag order"
else
  fail "lookup did not use the required paginated, form-encoded request shape"
fi

# The actual argument-boundary proof (#905): read the 0x1f-delimited argv
# record and confirm `check_name=Label Gate` arrived as exactly ONE argv
# element, not two adjacent elements ("check_name=Label" and "Gate")
# that a $*-join would render identically. require_arg's "$@" walk above
# already enforces this at runtime; this reads back the same evidence
# independently of $*.
argv_record="$(tail -n1 "${SHIM_LOG}.argv")"
argv_field_count=0
argv_has_exact_token=0
IFS=$'\x1f' read -r -a argv_fields <<<"$argv_record"
for argv_field in "${argv_fields[@]}"; do
  [ -n "$argv_field" ] || continue
  argv_field_count=$((argv_field_count + 1))
  [ "$argv_field" = "check_name=Label Gate" ] && argv_has_exact_token=1
done
if [ "$argv_has_exact_token" -eq 1 ]; then
  pass "check_name=Label Gate arrived as a single argv element, not two adjacent tokens"
else
  fail "check_name=Label Gate did not arrive as a single argv element (argv: $argv_record)"
fi

if success_output="$(run_functions success gate 2>&1)"; then
  if [[ "$success_output" == *"Required check run 'Label Gate' is successful on current HEAD test-head."* ]]; then
    pass "successful latest run clears the current-head wait"
  else
    fail "success path emitted an unexpected result: $success_output"
  fi
else
  fail "successful latest run did not clear the current-head wait"
fi

set +e
absent_output="$(run_functions absent gate 2>&1)"
absent_rc=$?
set -e
if [ "$absent_rc" -ne 0 ] && \
   [[ "$absent_output" == *"never appeared on current HEAD test-head"* ]] && \
   [[ "$absent_output" == *"Compare against: gh api -X GET repos/owner/repo/commits/test-head/check-runs --paginate"* ]]; then
  pass "absent check takes the never-seen timeout path"
else
  fail "absent timeout was misclassified (rc=$absent_rc): $absent_output"
fi

set +e
pending_output="$(run_functions pending gate 2>&1)"
pending_rc=$?
set -e
if [ "$pending_rc" -ne 0 ] && \
   [[ "$pending_output" == *"did not complete successfully within 0s on current HEAD test-head"* ]] && \
   [[ "$pending_output" != *"never appeared"* ]]; then
  pass "seen pending check takes the completion timeout path"
else
  fail "pending timeout was misclassified (rc=$pending_rc): $pending_output"
fi

# ---------------------------------------------------------------------------
# Dependabot commit provenance. The job-level `if:` trusts the PR opener and
# fetch-metadata reads only the first commit, so the workflow must refuse to
# approve or merge unless EVERY commit on the PR is Dependabot-produced.
# ---------------------------------------------------------------------------
PROV_DIR="$WORK/prov"
mkdir -p "$PROV_DIR/bin"
PROV_HEAD=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
PROV_OLD=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
cat >"$PROV_DIR/bin/gh" <<'SHIM'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$PROV_LOG"
case "$1 ${2:-}" in
  "api --paginate")
    case "$3" in
      repos/owner/repo/pulls/1/commits\?per_page=100)
        [ "${PROV_MODE:-}" != unreadable ] || { echo "HTTP 502" >&2; exit 1; }
        cat "$PROV_COMMITS"
        ;;
      *) echo "gh shim: unexpected api endpoint: $3" >&2; exit 91 ;;
    esac
    ;;
  "pr view")
    printf '%s\n' "${PROV_ARMED:-false}"
    ;;
  "pr merge")
    [ "${3:-}" = "--disable-auto" ] || { echo "gh shim: unexpected merge: $*" >&2; exit 92; }
    ;;
  *) echo "gh shim: unexpected command: $*" >&2; exit 93 ;;
esac
SHIM
chmod +x "$PROV_DIR/bin/gh"

prov_commit() {  # <sha> <author> <committer> <verified>
  jq -nc --arg sha "$1" --arg a "$2" --arg c "$3" --argjson v "$4" \
    '{sha:$sha, author:{login:$a}, committer:{login:$c}, commit:{verification:{verified:$v}}}'
}
printf '[%s]\n' "$(prov_commit "$PROV_HEAD" 'dependabot[bot]' web-flow true)" >"$PROV_DIR/trusted.json"
printf '[%s,%s]\n' "$(prov_commit "$PROV_OLD" 'dependabot[bot]' web-flow true)" \
  "$(prov_commit "$PROV_HEAD" someone-with-push someone-with-push false)" >"$PROV_DIR/foreign.json"

# Extract the provenance step's `run: |` body, dedented by its own indent.
awk '
  /- name: Verify Dependabot commit provenance/ { in_step = 1; next }
  in_step && /^[[:space:]]*run: \|[[:space:]]*$/ { in_run = 1; indent = -1; next }
  in_run && /^[[:space:]]*env:[[:space:]]*$/ { exit }
  in_run {
    if (indent < 0 && $0 ~ /[^[:space:]]/) { match($0, /^[[:space:]]*/); indent = RLENGTH }
    print (length($0) >= indent ? substr($0, indent + 1) : "")
  }
' "$WORKFLOW" >"$PROV_DIR/step.sh"

run_prov_step() {  # <commits_file> <mode> <armed>
  : >"$PROV_DIR/gh.log"
  : >"$PROV_DIR/output"
  ( cd "$ROOT" && PATH="$PROV_DIR/bin:$PATH" PROV_LOG="$PROV_DIR/gh.log" \
      PROV_COMMITS="$1" PROV_MODE="$2" PROV_ARMED="$3" \
      GITHUB_OUTPUT="$PROV_DIR/output" GITHUB_REPOSITORY=owner/repo \
      PR_URL=https://example.test/owner/repo/pull/1 PR_NUMBER=1 PR_HEAD_SHA="$PROV_HEAD" \
      bash "$PROV_DIR/step.sh" )
}

if grep -Fq 'dependabot_commit_provenance "$GITHUB_REPOSITORY" "$PR_NUMBER" "$PR_HEAD_SHA"' "$PROV_DIR/step.sh"; then
  pass "extracted the live provenance step"
else
  fail "could not extract the provenance step from the workflow"
fi

set +e
out=$(run_prov_step "$PROV_DIR/trusted.json" ok false 2>&1); rc=$?
set -e
if [ "$rc" -eq 0 ] && grep -Fxq 'trusted=true' "$PROV_DIR/output"; then
  pass "provenance step: Dependabot-only commits → trusted=true"
else
  fail "provenance step: trusted case rc=$rc output=$(cat "$PROV_DIR/output"): $out"
fi

set +e
out=$(run_prov_step "$PROV_DIR/foreign.json" ok true 2>&1); rc=$?
set -e
if [ "$rc" -eq 0 ] && grep -Fxq 'trusted=false' "$PROV_DIR/output" \
   && grep -Fq 'pr merge --disable-auto' "$PROV_DIR/gh.log" \
   && [[ "$out" == *"not Dependabot-only"* ]]; then
  pass "provenance step: foreign commit → trusted=false and an armed auto-merge is withdrawn"
else
  fail "provenance step: foreign case rc=$rc output=$(cat "$PROV_DIR/output") log=$(cat "$PROV_DIR/gh.log"): $out"
fi

set +e
out=$(run_prov_step "$PROV_DIR/foreign.json" ok false 2>&1); rc=$?
set -e
if [ "$rc" -eq 0 ] && grep -Fxq 'trusted=false' "$PROV_DIR/output" \
   && ! grep -Fq 'pr merge' "$PROV_DIR/gh.log"; then
  pass "provenance step: foreign commit, nothing armed → trusted=false, no merge call"
else
  fail "provenance step: foreign/unarmed case rc=$rc log=$(cat "$PROV_DIR/gh.log"): $out"
fi

set +e
out=$(run_prov_step "$PROV_DIR/trusted.json" unreadable false 2>&1); rc=$?
set -e
if [ "$rc" -ne 0 ] && grep -Fxq 'trusted=false' "$PROV_DIR/output"; then
  pass "provenance step: unreadable commits → job fails, trusted=false"
else
  fail "provenance step: unreadable case rc=$rc output=$(cat "$PROV_DIR/output"): $out"
fi

# The in-step re-check that guards the approve and both merge paths.
extract_function require_dependabot_provenance >"$PROV_DIR/recheck.sh"
run_recheck() {  # <commits_file> <mode> [armed]
  ( cd "$ROOT" && PATH="$PROV_DIR/bin:$PATH" PROV_LOG="$PROV_DIR/gh.log" \
      PROV_COMMITS="$1" PROV_MODE="$2" PROV_ARMED="${3:-false}" GITHUB_REPOSITORY=owner/repo PR_NUMBER=1 \
      PR_URL=https://example.test/owner/repo/pull/1 \
      bash -c 'set -euo pipefail
        . scripts/lib/gh-api-array.sh
        . scripts/lib/dependabot-commit-provenance.sh
        . "$1"
        require_dependabot_provenance "$2"
        echo REACHED_ACTION' bash "$PROV_DIR/recheck.sh" "$PROV_HEAD" )
}
set +e
out_t=$(run_recheck "$PROV_DIR/trusted.json" ok 2>&1); rc_t=$?
: >"$PROV_DIR/gh.log"
out_f=$(run_recheck "$PROV_DIR/foreign.json" ok true 2>&1); rc_f=$?
withdrew_f=$(grep -c 'pr merge --disable-auto' "$PROV_DIR/gh.log" || true)
out_u=$(run_recheck "$PROV_DIR/trusted.json" unreadable 2>&1); rc_u=$?
set -e
if [ "$rc_t" -eq 0 ] && [[ "$out_t" == *REACHED_ACTION* ]] \
   && [ "$rc_f" -eq 0 ] && [[ "$out_f" != *REACHED_ACTION* ]] && [ "$withdrew_f" -eq 1 ] \
   && [ "$rc_u" -ne 0 ] && [[ "$out_u" != *REACHED_ACTION* ]]; then
  pass "require_dependabot_provenance: trusted proceeds; foreign withdraws an armed auto-merge and stops cleanly; unreadable fails"
else
  fail "require_dependabot_provenance: t=$rc_t/$out_t f=$rc_f/$out_f u=$rc_u/$out_u"
fi

# Ordering: the approve is bound to a verified SHA, and each merge path
# re-verifies the SHA it is pinned to.
approve_block=$(awk '/APPROVE_SHA=\$\(gh pr view/{p=1} p{print} /event=APPROVE/{exit}' "$WORKFLOW")
if [[ "$approve_block" == *'require_dependabot_provenance "$APPROVE_SHA"'* ]] \
   && [[ "$approve_block" == *'-f commit_id="$APPROVE_SHA"'* ]] \
   && ! grep -Fq 'gh pr review --approve' "$WORKFLOW"; then
  pass "approve is pinned to a provenance-verified commit_id"
else
  fail "approve must verify provenance and bind commit_id to the verified SHA"
fi
recheck_before_merge=$(awk '
  /^[[:space:]]*require_current_head_checks_success[[:space:]]*$/ { getline nxt; if (nxt ~ /require_dependabot_provenance "\$CURRENT_HEAD_SHA"/) n++ }
  END { print n + 0 }' "$WORKFLOW")
if [ "$recheck_before_merge" -ge 2 ] \
   && grep -Fq "steps.provenance.outputs.trusted == 'true'" "$WORKFLOW"; then
  pass "both merge paths re-verify provenance on the pinned head; approve step gated on trusted"
else
  fail "expected provenance re-check after each head pin (got $recheck_before_merge) and a trusted-gated approve step"
fi

echo "test_dependabot_auto_merge_check_wait: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
