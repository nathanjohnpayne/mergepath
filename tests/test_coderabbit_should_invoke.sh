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

# Portable watchdog. `timeout` is GNU coreutils and is NOT on a stock macOS
# box, where it exits 127 and would fail this suite for the wrong reason
# (#1084 r3). This is a PROPAGATED self-test, so it has to run wherever a
# consumer runs it. Same selection strategy as
# tests/test_phase_4b_accounting.sh:1254-1283.
run_bounded() {  # <seconds> <cmd...>
  local secs=$1; shift
  if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"; return $?; fi
  if command -v gtimeout >/dev/null 2>&1; then gtimeout "$secs" "$@"; return $?; fi
  if command -v perl >/dev/null 2>&1; then
    perl -e 'my $s=shift; my $p=fork; if(!$p){exec @ARGV or exit 127} local $SIG{ALRM}=sub{kill 9,$p; waitpid $p,0; exit 124}; alarm $s; waitpid $p,0; my $rc=$?>>8; alarm 0; exit $rc' "$secs" "$@"
    return $?
  fi
  # 125 is the sentinel for "no watchdog available". Setting a variable would
  # be lost whenever run_bounded runs inside a subshell -- which is how the
  # caller below invokes it -- so the parent would read the fallback's success
  # as a real result and FAIL instead of skipping (#1084 r4).
  return 125
}

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
( cd "$d" && run_bounded 5 ./scripts/coderabbit-should-invoke.sh 99 --repo >/dev/null 2>&1 )
rc=$?
if [ "$rc" = 125 ]; then
  echo "SKIP: no timeout/gtimeout/perl available — cannot bound the hang check"
elif [ "$rc" = 3 ]; then pass "--repo with no value is rc=3 (no infinite loop)"
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

echo "--- #1084 r4: a quoted scalar must own the whole value ---"
# Printing only the text before the closing quote turned `invoke: "never" junk`
# into a VALID mode and suppressed review. Only whitespace or a comment may
# follow the closing quote; anything else is unparseable and must invoke.
case_is 'trailing junk after a quoted scalar invokes' "$ON"$'\n''  invoke: "never" trailing-junk' 0 0
case_is 'clean quoted scalar still parses'            "$ON"$'\n''  invoke: "never"'               0 1
case_is 'comment after a quoted scalar still parses'  "$ON"$'\n''  invoke: "never"   # ok'        0 1

echo "--- #1084 r4: --json requires jq and must say so ---"
_d=$(scratch "$ON" 0)
_shim=$(mktemp -d "$WORKDIR/shim.XXXXXX")
for _t in bash awk sed grep env readlink; do
  _r=$(command -v "$_t" 2>/dev/null) && ln -sf "$_r" "$_shim/$_t"
done
( cd "$_d" && env PATH="$_shim" bash ./scripts/coderabbit-should-invoke.sh 99 --json >/dev/null 2>&1 )
[ $? = 3 ] && pass "--json without jq exits 3 instead of returning an empty success" \
             || fail "--json without jq did not exit 3"
( cd "$_d" && env PATH="$_shim" bash ./scripts/coderabbit-should-invoke.sh 99 >/dev/null 2>&1 )
[ $? = 0 ] && pass "the non-json path still works without jq" \
             || fail "the non-json path broke without jq"

echo "--- #1084 r4: the watchdog reports unavailability by exit status ---"
# A variable set inside run_bounded is lost when the caller wraps it in a
# subshell, so the parent would read the fallback as a real result.
if run_bounded 1 true >/dev/null 2>&1; then
  pass "run_bounded returns the command status when a watchdog exists"
else
  [ $? = 125 ] && pass "run_bounded signals unavailability with 125" || fail "run_bounded returned an unexpected status"
fi

echo "--- #1084 r5: ambiguous or malformed config must never resolve to skip ---"
# Three separate ways the parser previously manufactured a suppressing value
# out of input that does not actually say "never".
case_is 'duplicate invoke keys invoke'        "$ON"$'\n'"  invoke: never"$'\n'"  invoke: always" 0 0
case_is 'duplicate enabled keys invoke'       "  enabled: false"$'\n'"  enabled: true"$'\n'"  invoke: always" 0 0
case_is 'unterminated quoted scalar invokes'  "$ON"$'\n''  invoke: "never'                        0 0
# Controls: the single well-formed forms must still be honoured, or the
# fail-open guard would have eaten the feature.
case_is 'single clean never still skips'      "$ON"$'\n'"  invoke: never"                         0 1
case_is 'nested enabled does not shadow'      "$ON"$'\n'"  severity_gate:"$'\n'"    enabled: false"$'\n'"  invoke: never" 0 1

echo "--- #1084 r6: duplicate top-level coderabbit blocks are ambiguous too ---"
# Two blocks aggregate into one logical block, so every field still occurs
# exactly once and the field-level guard never fires. The BLOCK count is the
# missing half of that check.
_d=$(mktemp -d "$WORKDIR/s.XXXXXX"); mkdir -p "$_d/.github" "$_d/scripts"
cp "$SCRIPT" "$_d/scripts/coderabbit-should-invoke.sh"; chmod +x "$_d/scripts/coderabbit-should-invoke.sh"
printf '#!/usr/bin/env bash\nexit 0\n' >"$_d/scripts/phase-4b-classifier.sh"; chmod +x "$_d/scripts/phase-4b-classifier.sh"
printf 'coderabbit:\n  enabled: false\ncodex:\n  enabled: true\ncoderabbit:\n  invoke: always\n' >"$_d/.github/review-policy.yml"
( cd "$_d" && ./scripts/coderabbit-should-invoke.sh 99 >/dev/null 2>&1 )
[ $? = 0 ] && pass "two top-level coderabbit blocks invoke" || fail "two top-level coderabbit blocks did not invoke"
printf 'coderabbit:\n  enabled: true\n  invoke: never\n' >"$_d/.github/review-policy.yml"
( cd "$_d" && ./scripts/coderabbit-should-invoke.sh 99 >/dev/null 2>&1 )
[ $? = 1 ] && pass "a single block is still honoured" || fail "single-block control broke"

echo "--- #1084 r7: ambiguity is a property of the FILE, not of the field read first ---"
# Honouring `enabled: false` before reading `invoke` let one well-formed field
# mask the other's ambiguity, producing a confident skip from a malformed file.
case_is 'enabled:false cannot mask a duplicate invoke' "  enabled: false"$'\n'"  invoke: never"$'\n'"  invoke: always" 0 0
case_is 'genuine enabled:false alone still skips'      "  enabled: false"                                                0 1
case_is 'enabled:false with a clean invoke still skips' "  enabled: false"$'\n'"  invoke: always"                       0 1

echo "--- #1084 r8: the reader accepts real YAML spellings, not one hard-coded shape ---"
# Indentation is derived from the block's first child, not assumed to be two
# spaces: a four-space policy previously had every direct child ignored, so an
# explicit `invoke: never` silently became the `always` default.
case_is 'four-space indentation is honoured'   "    enabled: true"$'\n'"    invoke: never"          0 1
# A quoted key is the same key to any YAML reader; counting only the bare
# spelling let a quoted duplicate slip past the ambiguity guard.
case_is 'quoted duplicate key is ambiguous'    "$ON"$'\n'"  invoke: never"$'\n''  "invoke": always' 0 0
# YAML needs whitespace before a `#` for it to open a comment.
case_is 'no space before # is malformed'       "$ON"$'\n''  invoke: "never"#junk'                    0 0
case_is 'space before # is a real comment'     "$ON"$'\n''  invoke: "never" # ok'                    0 1

echo "--- #1084 r9: the block header is a key and a type, not a literal prefix ---"
_mk() {  # <policy-text> <expect_rc> <name>
  local dir; dir=$(mktemp -d "$WORKDIR/s.XXXXXX"); mkdir -p "$dir/.github" "$dir/scripts"
  cp "$SCRIPT" "$dir/scripts/coderabbit-should-invoke.sh"; chmod +x "$dir/scripts/coderabbit-should-invoke.sh"
  printf '#!/usr/bin/env bash\nexit 0\n' >"$dir/scripts/phase-4b-classifier.sh"; chmod +x "$dir/scripts/phase-4b-classifier.sh"
  printf '%s\n' "$1" >"$dir/.github/review-policy.yml"
  ( cd "$dir" && ./scripts/coderabbit-should-invoke.sh 99 >/dev/null 2>&1 )
  [ $? = "$2" ] && pass "$3" || fail "$3 (expected rc=$2)"
}
_mk 'coderabbit:
  invoke: never
"coderabbit":
  invoke: always' 0 'a quoted duplicate block header is ambiguous'
_mk 'coderabbit: |
  invoke: never' 0 'a scalar coderabbit block is not a policy mapping'
_mk 'coderabbit:
  enabled: true
  invoke": never' 0 'an unmatched boundary quote does not manufacture a key'
_mk 'coderabbit:   # trailing comment
  enabled: true
  invoke: never' 1 'a commented block header is still a mapping'
_mk 'coderabbit:
  enabled: true
  invoke: never' 1 'baseline single block still skips'

echo "--- #1084 r10: inconsistent child indentation is a parse failure ---"
# An over-indented suppressing field fixed child_indent deeper, so the later,
# shallower line was silently dropped and the malformed file yielded skip.
_mk 'coderabbit:
    invoke: never
  enabled: true' 0 'inconsistent child indentation invokes'
_mk 'coderabbit:
    enabled: true
    invoke: never' 1 'consistent four-space indentation still skips'

echo "--- #1084 r11: malformed quoting is ambiguous for EVERY field ---"
# Returning the raw line only worked for `invoke`, where an unmatched literal
# fails the enum. For `enabled` a raw line simply is not "false", so the field
# defaulted to true and a valid `invoke: never` was still free to skip.
case_is 'unterminated enabled + valid never invokes' '  enabled: "false'$'\n'"  invoke: never" 0 0
case_is 'unterminated invoke still invokes'          "$ON"$'\n''  invoke: "never'            0 0

echo "--- #1084 r11: a scalar key cannot have children ---"
_mk 'coderabbit:
  enabled: false
    invoke: never' 0 'a mapping nested under a scalar is malformed'
_mk 'coderabbit:
  enabled: true
  severity_gate:
    enabled: false
  invoke: never' 1 'a real nested map under a mapping key is fine'

echo "--- #1084 r11: repo validators agree, and both halves are right ---"
_d=$(scratch "$ON" 0)
( cd "$_d" && ./scripts/coderabbit-should-invoke.sh 99 --repo "owner/.github" >/dev/null 2>&1 )
[ $? != 3 ] && pass "a dot-prefixed repo NAME is accepted (owner/.github)" || fail "owner/.github rejected"
( cd "$_d" && ./scripts/coderabbit-should-invoke.sh 99 --repo ".bad/x" >/dev/null 2>&1 )
[ $? = 3 ] && pass "a dot-prefixed OWNER is still rejected" || fail ".bad/x should be rc=3"

echo "--- #1084 r11: three diagnoses, not two ---"
# Every branch invokes, so the DECISION was always fail-safe; the defect was the
# reason handed to a machine reader. An infra failure and an empty diff must not
# land in the same bucket, and neither must an unparseable document.
_diag() {  # <classifier-body> <expected-substring> <name>
  local dir; dir=$(mktemp -d "$WORKDIR/s.XXXXXX"); mkdir -p "$dir/.github" "$dir/scripts"
  cp "$SCRIPT" "$dir/scripts/coderabbit-should-invoke.sh"; chmod +x "$dir/scripts/coderabbit-should-invoke.sh"
  printf '%s\n' "$1" >"$dir/scripts/phase-4b-classifier.sh"; chmod +x "$dir/scripts/phase-4b-classifier.sh"
  printf 'coderabbit:\n  enabled: true\n  invoke: complex-changes\n' >"$dir/.github/review-policy.yml"
  local out; out=$( cd "$dir" && ./scripts/coderabbit-should-invoke.sh 99 2>/dev/null )
  printf '%s' "$out" | grep -q "$2" && pass "$3" || fail "$3 (got: $out)"
}
_diag '#!/usr/bin/env bash
exit 2' 'classifier failed (exit 2)' 'an API failure reports as a failure'
_diag '#!/usr/bin/env bash
echo "not json"
exit 0' 'no parseable files_inspected' 'an unparseable document reports as unparseable'
_diag '#!/usr/bin/env bash
echo "{\"files_inspected\": 0}"
exit 0' 'inspected no files' 'a genuine empty inspection reports as such'

echo
echo "test_coderabbit_should_invoke: $PASS passed, $FAIL failed"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
