#!/usr/bin/env bash
# test_coderabbit_should_invoke.sh — scripts/coderabbit-should-invoke.sh
#
# The asymmetry under test: SKIP silently drops a review round, INVOKE only
# costs wall-clock. So every ambiguous input must resolve to INVOKE, and only
# an explicit well-formed instruction may suppress CodeRabbit. Most cases here
# exist to prove a wrong/absent/broken input does NOT skip.
#
# Classifier-backed cases use a STUB classifier on PATH-adjacent lookup rather
# than the live API, so the suite is hermetic and runs on a consumer that has
# no network.

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/scripts/coderabbit-should-invoke.sh"
PASS=0; FAIL=0
WORKDIR=$(mktemp -d "${TMPDIR:-/tmp}/cri-test.XXXXXX")
trap 'rm -rf "$WORKDIR"' EXIT

pass() { PASS=$((PASS+1)); echo "PASS: $*"; }
fail() { FAIL=$((FAIL+1)); echo "FAIL: $*" >&2; }

# Build a scratch repo whose .github/review-policy.yml carries <body>, and
# whose scripts/ dir holds a stub classifier exiting <cls_rc> (or no
# classifier at all when cls_rc is "absent").
scratch() {  # <coderabbit_block_body> <cls_rc|absent|nonexec>
  local body=$1 cls=$2 dir
  dir=$(mktemp -d "$WORKDIR/s.XXXXXX")
  mkdir -p "$dir/.github" "$dir/scripts"
  printf 'coderabbit:\n%s\n' "$body" >"$dir/.github/review-policy.yml"
  cp "$SCRIPT" "$dir/scripts/coderabbit-should-invoke.sh"
  chmod +x "$dir/scripts/coderabbit-should-invoke.sh"
  if [ "$cls" != "absent" ]; then
    {
      echo "#!/usr/bin/env bash"
      echo "echo '{\"match\": false, \"phase_4b_default\": \"${CLS_POLICY_FIXTURE:-complex-changes}\", \"files_inspected\": ${CLS_FILES_FIXTURE:-4}}'"
      echo "exit ${cls#nonexec:}"
    } >"$dir/scripts/phase-4b-classifier.sh"
    if [ "${cls%%:*}" = "nonexec" ]; then chmod -x "$dir/scripts/phase-4b-classifier.sh"; else chmod +x "$dir/scripts/phase-4b-classifier.sh"; fi
  fi
  echo "$dir"
}

case_is() {  # <name> <body> <cls_rc> <expect_rc>
  local name=$1 body=$2 cls=$3 want=$4 dir out rc
  dir=$(scratch "$body" "$cls")
  out=$( cd "$dir" && ./scripts/coderabbit-should-invoke.sh 99 2>&1 ); rc=$?
  if [ "$rc" = "$want" ]; then
    pass "$name (rc=$rc)"
  else
    fail "$name: expected rc=$want, got rc=$rc"; printf '%s\n' "$out" | sed 's/^/      /' >&2
  fi
}

ON="  enabled: true"

echo "--- explicit modes ---"
case_is "invoke=always invokes"                "$ON"$'\n'"  invoke: always"           0 0
case_is "invoke=never skips"                   "$ON"$'\n'"  invoke: never"            0 1
case_is "enabled=false skips regardless"       "  enabled: false"$'\n'"  invoke: always" 0 1

echo "--- defaults and malformed input must NOT skip ---"
case_is "invoke absent defaults to always"     "$ON"                                  0 0
case_is "unrecognized mode defaults to invoke" "$ON"$'\n'"  invoke: bogus"            0 0
case_is "empty mode value defaults to invoke"  "$ON"$'\n'"  invoke:"                  0 0
case_is "quoted mode parses"                   "$ON"$'\n''  invoke: "never"'          0 1
case_is "mode with inline comment parses"      "$ON"$'\n'"  invoke: never   # why"    0 1

echo "--- complex-changes defers to the classifier ---"
CX="$ON"$'\n'"  invoke: complex-changes"
case_is "classifier match (rc=1) invokes"      "$CX" 1 0
case_is "classifier no-match (rc=0) skips"     "$CX" 0 1
case_is "classifier API failure (rc=2) invokes" "$CX" 2 0
case_is "classifier bad args (rc=3) invokes"   "$CX" 3 0
case_is "classifier absent invokes"            "$CX" absent 0
case_is "classifier non-executable invokes"    "$CX" nonexec:1 0

echo "--- argument validation ---"
d=$(scratch "$ON" 0)
( cd "$d" && ./scripts/coderabbit-should-invoke.sh notanum >/dev/null 2>&1 ); [ $? = 3 ] && pass "non-numeric PR is rc=3" || fail "non-numeric PR should be rc=3"
( cd "$d" && ./scripts/coderabbit-should-invoke.sh 99 --repo bad_repo >/dev/null 2>&1 ); [ $? = 3 ] && pass "malformed --repo is rc=3" || fail "malformed --repo should be rc=3"
( cd "$d" && ./scripts/coderabbit-should-invoke.sh 99 --nope >/dev/null 2>&1 ); [ $? = 3 ] && pass "unknown flag is rc=3" || fail "unknown flag should be rc=3"

echo "--- json shape ---"
d=$(scratch "$ON"$'\n'"  invoke: never" 0)
out=$( cd "$d" && ./scripts/coderabbit-should-invoke.sh 99 --json 2>/dev/null )
if printf '%s' "$out" | jq -e '.decision == "skip" and .invoke_mode == "never" and .pr_number == 99' >/dev/null 2>&1; then
  pass "--json emits parseable decision/invoke_mode/pr_number"
else
  fail "--json shape wrong: $out"
fi

echo "--- #1084 r1: the classifier is a DISPOSITION function, not a detector ---"
# With phase_4b_default: fallback-only the classifier short-circuits and exits 0
# WITHOUT inspecting the diff. Reading that as "routine" would skip CodeRabbit on
# every PR in such a repo, silently, including state-machine changes.
CLS_FILES_FIXTURE=0 CLS_POLICY_FIXTURE=fallback-only case_is "fallback-only short-circuit invokes (not skip)" "$CX" 0 0
CLS_POLICY_FIXTURE=complex-changes case_is "an inspecting policy still skips on no-match" "$CX" 0 1

echo "--- #1084 r1: a flag with a missing value must not loop forever ---"
d=$(scratch "$ON" 0)
( cd "$d" && timeout 5 ./scripts/coderabbit-should-invoke.sh 99 --repo >/dev/null 2>&1 )
rc=$?
if [ "$rc" = 3 ]; then pass "--repo with no value is rc=3 (no infinite loop)"
elif [ "$rc" = 124 ]; then fail "--repo with no value HUNG (shift 2 failed and the loop re-read it)"
else fail "--repo with no value: expected rc=3, got rc=$rc"; fi

echo "--- #1084 r1: a hash inside a quoted scalar is content, not a comment ---"
# Stripping it unconditionally turned a malformed value into a bare `never`,
# so bad input suppressed CodeRabbit -- inverting the fail-toward-invoke contract.
case_is 'quoted hash does not become a valid mode' "$ON"$'\n''  invoke: "never # temporary"' 0 0
case_is 'unquoted hash without space stays one token' "$ON"$'\n'"  invoke: never#temporary"    0 0
case_is 'genuine trailing comment still parses'      "$ON"$'\n'"  invoke: never   # why"       0 1

echo "--- #1084 r1: the policy is resolved from the SCRIPT checkout, not \$PWD ---"
d=$(scratch "$ON"$'\n'"  invoke: never" 0)
( cd / && "$d/scripts/coderabbit-should-invoke.sh" 99 >/dev/null 2>&1 )
[ $? = 1 ] && pass "explicit never is honoured when run from a foreign cwd" \
             || fail "running from a foreign cwd lost the config and did not skip"

echo "--- #1084 r2: BOTH phase_4b short-circuits are unassessed, not verdicts ---"
# fallback-only exits 0 (reads as "routine"); always exits 1 (reads as "trigger
# matched"). Keying on the policy NAME caught only the first half. files_inspected
# == 0 is the policy-agnostic "did not look" signal and covers both.
CLS_FILES_FIXTURE=0 case_is "always short-circuit (exit 1, 0 files) invokes as unassessed" "$CX" 1 0
CLS_FILES_FIXTURE=8 case_is "genuine trigger match (files inspected) invokes"              "$CX" 1 0
CLS_FILES_FIXTURE=3 case_is "genuine no-match (files inspected) skips"                     "$CX" 0 1

echo "--- #1084 r2: --json must stay parseable on the fail-safe path ---"
_d=$(scratch "$ON"$'\n'"  invoke: 'bogus\"mode'" 0)
_out=$( cd "$_d" && ./scripts/coderabbit-should-invoke.sh 99 --json 2>/dev/null )
if printf '%s' "$_out" | jq -e '.decision == "invoke"' >/dev/null 2>&1; then
  pass "a JSON-special char in the policy value still yields parseable --json"
else
  fail "--json malformed when the policy value contains a quote: $_out"
fi

echo "--- #1084 r2: resolve through a symlink ---"
_d=$(scratch "$ON"$'\n'"  invoke: never" 0)
ln -sf "$_d/scripts/coderabbit-should-invoke.sh" "$WORKDIR/via-link.sh"
( cd / && "$WORKDIR/via-link.sh" 99 >/dev/null 2>&1 )
[ $? = 1 ] && pass "explicit never honoured when invoked through a symlink" \
             || fail "symlink invocation lost the config and did not skip"

echo
echo "test_coderabbit_should_invoke: $PASS passed, $FAIL failed"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
