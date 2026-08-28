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

# Most cases exercise the local field reader with intentionally valid YAML;
# only the r14 block below exercises real parser rejection. On a supported
# self-test host without mikefarah/yq, give those non-parser-specific cases a
# success-only validator shim so ordinary `never` / `enabled: false` assertions
# do not turn into dozens of false failures. The r14 parser cases remain
# explicitly skipped without real yq, while the r16 cases override this seam to
# verify the production no-parser fail-toward-invoking behavior.
unset MERGEPATH_YQ_BIN
REAL_YQ_AVAILABLE=false
if command -v yq >/dev/null 2>&1 && yq --version 2>/dev/null | grep -q mikefarah; then
  REAL_YQ_AVAILABLE=true
else
  TEST_YQ="$WORKDIR/yq-valid-fixture-shim"
  printf '#!/usr/bin/env bash\nprintf "1\\n"\nexit 0\n' >"$TEST_YQ"
  chmod +x "$TEST_YQ"
  export MERGEPATH_YQ_BIN="$TEST_YQ"
fi

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

# A case block placed above the helper it calls does not fail -- it does not
# RUN, contributing neither a pass nor a fail, so the suite still reports
# "N passed, 0 failed" while a whole block silently vanishes. Caught exactly
# that way while adding the r13 cases. Turning an unknown command into a
# recorded FAIL makes the omission visible instead of invisible.
#
# bash 4.0+; on bash 3.2 the hook does not exist and behaviour is simply
# todays, so this is safe to carry to consumers.
command_not_found_handle() {
  # bash runs this hook in a SUBSHELL, so incrementing FAIL here does nothing
  # in the parent -- the first version of this guard printed a failure line
  # and still let the suite exit 0, which is precisely the toothless-check
  # shape this suite exists to catch. Record to a file instead and fold it
  # into the count at the end, where the exit code is decided.
  echo "FAIL: test helper '$1' was called before it was defined (block did not run)" >&2
  echo "$1" >>"$WORKDIR/.unrun"
  return 127
}


# Build a scratch repo whose .github/review-policy.yml carries <body>, and
# whose scripts/ dir holds a stub classifier exiting <cls_rc> (or no
# classifier at all when cls_rc is "absent").
scratch() {  # <coderabbit_block_body> <cls_rc|absent|nonexec>
  local body=$1 cls=$2 dir cls_status cls_match cls_raw
  dir=$(mktemp -d "$WORKDIR/s.XXXXXX")
  mkdir -p "$dir/.github" "$dir/scripts"
  printf 'coderabbit:\n%s\n' "$body" >"$dir/.github/review-policy.yml"
  cp "$SCRIPT" "$dir/scripts/coderabbit-should-invoke.sh"
  chmod +x "$dir/scripts/coderabbit-should-invoke.sh"
  if [ "$cls" != "absent" ]; then
    cls_status=${cls#nonexec:}
    cls_match=false
    [ "$cls_status" = "1" ] && cls_match=true
    if [ -n "${CLS_RAW_FIXTURE+x}" ]; then
      cls_raw=$CLS_RAW_FIXTURE
    else
      cls_raw="{\"match\": $cls_match, \"phase_4b_default\": \"${CLS_POLICY_FIXTURE:-complex-changes}\", \"files_inspected\": ${CLS_FILES_FIXTURE:-4}}"
    fi
    {
      echo "#!/usr/bin/env bash"
      echo "cat <<'MERGEPATH_CLASSIFIER_JSON'"
      printf '%s\n' "$cls_raw"
      echo "MERGEPATH_CLASSIFIER_JSON"
      echo "exit $cls_status"
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
case_is "unrecognized enabled value invokes"   "  enabled: bogus"$'\n'"  invoke: never" 0 0
case_is "empty enabled value invokes"          "  enabled:"$'\n'"  invoke: never"      0 0
case_is "quoted empty enabled value invokes"   '  enabled: ""'$'\n'"  invoke: never" 0 0
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

classifier_reason_is() {  # <name> <raw-output> <classifier-rc> <reason-substring>
  local name=$1 raw=$2 cls_rc=$3 reason=$4 dir out rc got
  CLS_RAW_FIXTURE=$raw
  dir=$(scratch "$CX" "$cls_rc")
  unset CLS_RAW_FIXTURE
  out=$(cd "$dir" && ./scripts/coderabbit-should-invoke.sh 99 --json 2>/dev/null); rc=$?
  got=$(printf '%s' "$out" | jq -r '.reason // ""' 2>/dev/null)
  if [ "$rc" = "0" ] && case "$got" in *"$reason"*) true ;; *) false ;; esac; then
    pass "$name"
  else
    fail "$name (expected invoke reason~'$reason', got rc=$rc reason='$got')"
  fi
}

echo "--- malformed or inconsistent classifier output must NOT skip ---"
classifier_reason_is "truncated classifier prose invokes" \
  'garbage {"files_inspected": 4' 0 'no single valid decision object'
classifier_reason_is "missing classifier match invokes" \
  '{"files_inspected": 4}' 0 'no single valid decision object'
classifier_reason_is "fractional files_inspected invokes" \
  '{"match": false, "files_inspected": 4.5}' 0 'no single valid decision object'
classifier_reason_is "multiple classifier documents invoke" \
  $'{"match": false, "files_inspected": 4}\n{"match": false, "files_inspected": 4}' 0 'no single valid decision object'
classifier_reason_is "exit 0 cannot carry match true" \
  '{"match": true, "files_inspected": 4}' 0 'match disagrees with exit status'
classifier_reason_is "exit 1 cannot carry match false" \
  '{"match": false, "files_inspected": 4}' 1 'match disagrees with exit status'
classifier_reason_is "3,000-file API cap invokes" \
  '{"match": false, "files_inspected": 3000}' 0 'may have capped'
CLS_FILES_FIXTURE=2999 case_is "2,999 inspected files may still skip" "$CX" 0 1

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

# The same checkout anchoring must carry through to the classifier. A decider
# reached by absolute path while the caller stands in another repo must not let
# the classifier's implicit `gh repo view` inherit that foreign cwd.
_d=$(scratch "$CX" 0)
_expected_cwd=$(cd "$_d" && pwd -P)
{
  echo '#!/usr/bin/env bash'
  echo "[ \"\$(pwd -P)\" = \"$_expected_cwd\" ] || exit 2"
  echo 'echo '\''{"match": false, "phase_4b_default": "complex-changes", "files_inspected": 4}'\'''
  echo 'exit 0'
} >"$_d/scripts/phase-4b-classifier.sh"
chmod +x "$_d/scripts/phase-4b-classifier.sh"
( cd / && "$_d/scripts/coderabbit-should-invoke.sh" 99 >/dev/null 2>&1 )
[ $? = 1 ] && pass "classifier runs from the script checkout, not the caller cwd" \
             || fail "classifier inherited the caller cwd and could resolve the wrong repo"

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
printf 'coderabbit:\n  enabled: true\n!!str coderabbit:\n  invoke: never\n' >"$_d/.github/review-policy.yml"
( cd "$_d" && ./scripts/coderabbit-should-invoke.sh 99 >/dev/null 2>&1 )
[ $? = 0 ] && pass "a tagged duplicate block header is ambiguous" || fail "tagged duplicate block header bypassed ambiguity detection"
printf 'key: &cr_key coderabbit\ncoderabbit:\n  enabled: true\n*cr_key:\n  invoke: never\n' >"$_d/.github/review-policy.yml"
( cd "$_d" && ./scripts/coderabbit-should-invoke.sh 99 >/dev/null 2>&1 )
[ $? = 0 ] && pass "an aliased duplicate block header is ambiguous" || fail "aliased duplicate block header bypassed ambiguity detection"

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
# An explicit YAML type tag is another semantic spelling of the same string
# key. The local reader cannot safely normalize the complete tag grammar, so a
# tagged key must be ambiguous rather than bypassing duplicate detection.
case_is 'tagged duplicate key is ambiguous'    "$ON"$'\n'"  invoke: never"$'\n''  !!str invoke: always' 0 0
case_is 'aliased duplicate key is ambiguous'   "$ON"$'\n'"  key: &invoke_key invoke"$'\n'"  invoke: never"$'\n'"  *invoke_key: always" 0 0
case_is 'explicit duplicate key is ambiguous'  "$ON"$'\n'"  invoke: never"$'\n'"  ? invoke"$'\n'"  : always" 0 0
case_is 'anchored duplicate key is ambiguous'  "$ON"$'\n'"  invoke: never"$'\n'"  &invoke_key invoke: always" 0 0
# YAML needs whitespace before a `#` for it to open a comment.
case_is 'no space before # is malformed'       "$ON"$'\n''  invoke: "never"#junk'                    0 0
case_is 'space before # is a real comment'     "$ON"$'\n''  invoke: "never" # ok'                    0 1

echo "--- #1084 r13: a direct child must be a mapping entry ---"
# Split by what go-yaml actually does, measured per case: the first four
# REJECT at parse time, the last two PARSE but leave `coderabbit` as a string
# or a list rather than a policy mapping. Both groups must invoke; only the
# reported REASON differs, so each case asserts the reason too.
_mkr() {  # <policy-text-with-escapes> <expect_rc> <expect_reason_substr> <name>
  local dir; dir=$(mktemp -d "$WORKDIR/s.XXXXXX"); mkdir -p "$dir/.github" "$dir/scripts"
  cp "$SCRIPT" "$dir/scripts/coderabbit-should-invoke.sh"; chmod +x "$dir/scripts/coderabbit-should-invoke.sh"
  printf '#!/usr/bin/env bash\nexit 0\n' >"$dir/scripts/phase-4b-classifier.sh"; chmod +x "$dir/scripts/phase-4b-classifier.sh"
  printf '%b' "$1" >"$dir/.github/review-policy.yml"
  local out rc
  out=$( cd "$dir" && ./scripts/coderabbit-should-invoke.sh 99 --json 2>/dev/null ); rc=$?
  local got; got=$(printf '%s' "$out" | jq -r '.reason' 2>/dev/null)
  if [ "$rc" = "$2" ] && case "$got" in *"$3"*) true ;; *) false ;; esac; then
    pass "$4"
  else
    fail "$4 (expected rc=$2 reason~'$3', got rc=$rc reason='$got')"
  fi
}
# go-yaml PARSE-REJECT: a colonless line among mapping entries.
_mkr 'coderabbit:\n  enabled true\n  invoke: never\n'        0 'child is not a mapping entry' 'a colonless child BEFORE never does not let never win'
_mkr 'coderabbit:\n  invoke: never\n  enabled true\n'        0 'child is not a mapping entry' 'a colonless child AFTER never does not let never win'
_mkr 'coderabbit:\n  enabled true # a: b\n  invoke: never\n' 0 'child is not a mapping entry' 'a colonless child cannot borrow the colon from its own comment'
_mkr 'coderabbit:\n  - item\n  invoke: never\n'              0 'child is not a mapping entry' 'a sequence entry mixed into the mapping is malformed'
# go-yaml PARSES, but coderabbit is not a policy mapping.
_mkr 'coderabbit:\n  justaword\n'                            0 'not a block mapping'         'colonless children ALONE are a plain scalar, not a parse error'
_mkr 'coderabbit:\n  - invoke: never\n'                      0 'invoke=always'               'a list of mappings has no invoke scalar to honour'
# go-yaml PARSES with a readable never: the knob must still work.
_mkr 'coderabbit:\n  "a: b": 1\n  invoke: never\n'          1 'never'                       'a quoted key containing a colon is still a mapping entry'
_mkr 'coderabbit:\n  url: http://x.example\n  invoke: never\n' 1 'never'                     'a colon inside a value does not make the child colonless'
# The ambiguity reason must name the diagnosis the parser reached, not a
# fixed list of causes (#1084 r13).
_mkr 'coderabbit:\n\tinvoke: never\n'                        0 'tab in indentation'          'the reported reason names the tab, not duplicate keys'
_mkr 'coderabbit:\n  invoke: never\n  invoke: always\n'      0 'duplicate invoke keys'       'the reported reason still names duplicate keys when that is the cause'

echo "--- #1084 r14: document validity comes from a real parser ---"
# yq is OPTIONAL for the production script, so it must be optional for the
# suite too. Without this gate a host lacking yq fails four cases for a reason
# that is not a defect -- and this file is canonical to all nine consumers,
# so that would red every consumer that has not bootstrapped yq (#1084 r15).
if [ "$REAL_YQ_AVAILABLE" = true ]; then
# <policy> <expect_rc> <expect_reason_substr> <name> — runs with yq available.
# A document that go-yaml REJECTS must invoke even though the `coderabbit`
# block itself is intact: enumeration of malformed shapes does not terminate,
# so validity is delegated rather than hand-detected.
_mkr 'other:\n  [bad\ncoderabbit:\n  invoke: never\n'        0 'not valid YAML' 'an unclosed flow sequence elsewhere invokes'
_mkr 'other: {bad\ncoderabbit:\n  invoke: never\n'           0 'not valid YAML' 'an unclosed flow mapping elsewhere invokes'
_mkr 'other: *nosuchanchor\ncoderabbit:\n  invoke: never\n'  0 'not valid YAML' 'an undefined anchor elsewhere invokes'
_mkr 'other: 1\n---\ncoderabbit:\n  invoke: never\n'       0 'exactly one YAML document' 'a later-document suppressing block invokes'
# A consistently indented root mapping is VALID YAML that the column-zero
# matcher does not open, so it defaults to `always` and INVOKES. That is a
# known limitation, not the desired end state (#1090) -- but it fails SAFE,
# and the alternative was worse: re-reading fields through yq to honour it
# handed duplicate-key policies to yq's silent last-wins, which SKIPPED review
# (#1084 r15). These three pin the fail-safe answer for all of it.
_mkr '  coderabbit:\n    invoke: never\n'                    0 'invoke=always' 'an indented root is not read, defaulting to invoke (known limit, fail-safe)'
_mkr '  coderabbit:\n    enabled: false\n'                   0 'invoke=always' 'an indented root enabled:false also defaults to invoke, never to skip'
_mkr '  coderabbit:\n    invoke: always\n    invoke: never\n' 0 'invoke=always' 'an indented root with duplicate keys must never resolve to skip'
# yq resolves duplicates last-wins and SILENTLY, so delegating wholesale would
# regress exactly the shape this script defends. The duplicate detector runs
# first and stays authoritative.
_mkr 'coderabbit:\n  invoke: always\n  invoke: never\n'      0 'duplicate invoke keys'  'duplicate keys stay ambiguous even though yq would answer never'
_mkr 'coderabbit:\n  invoke: always\ncoderabbit:\n  invoke: never\n' 0 'coderabbit blocks' 'duplicate blocks stay ambiguous even though yq would answer never'

else
  echo "SKIP: parser-validity cases (mikefarah yq not on PATH; production fails toward invoking here)"
fi

echo "--- #1084 r16: a suppressing policy requires the real parser ---"
# Unreachable on any machine that has yq, so exercise it through the seam. The
# local reader cannot prove whole-document validity; without the parser even a
# clean-looking suppressing value must fail toward invoking.
_mkn() {  # <policy-text> <expect_rc> <name>
  local dir; dir=$(mktemp -d "$WORKDIR/s.XXXXXX"); mkdir -p "$dir/.github" "$dir/scripts"
  cp "$SCRIPT" "$dir/scripts/coderabbit-should-invoke.sh"; chmod +x "$dir/scripts/coderabbit-should-invoke.sh"
  printf '#!/usr/bin/env bash\nexit 0\n' >"$dir/scripts/phase-4b-classifier.sh"; chmod +x "$dir/scripts/phase-4b-classifier.sh"
  printf '%b' "$1" >"$dir/.github/review-policy.yml"
  ( cd "$dir" && MERGEPATH_YQ_BIN=__absent_yq__ ./scripts/coderabbit-should-invoke.sh 99 >/dev/null 2>&1 )
  [ $? = "$2" ] && pass "$3" || fail "$3 (expected rc=$2)"
}
_mkn 'coderabbit:\n  invoke: never\n'          0 'without yq: a plain never invokes rather than suppressing'
_mkn 'coderabbit:\n  enabled: false\n'         0 'without yq: enabled false invokes rather than suppressing'
_mkn 'coderabbit:\n  invoke: complex-changes\n' 0 'without yq: a routine classifier result cannot suppress'
_mkn 'coderabbit:\n  invoke: always\n'         0 'without yq: a plain always still invokes'
_mkn 'coderabbit:\n\tinvoke: never\n'          0 'without yq: the awk tab detection still invokes'
_mkn 'coderabbit:\n  enabled true\n  invoke: never\n' 0 'without yq: the awk colonless detection still invokes'
_mkn 'coderabbit:\n  invoke: never\n  invoke: always\n' 0 'without yq: duplicate keys still invoke'
# Without a parser these two are not inspected further; both still fail safe.
_mkn 'other:\n  [bad\ncoderabbit:\n  invoke: always\n' 0 'without yq: an invalid document is undetected but still invokes'
_mkn '  coderabbit:\n    invoke: never\n'      0 'without yq: an indented root is unread, defaulting to invoke'

echo "--- #1084 r13: trailing content after a closing quote ---"
# Measured against go-yaml, recorded here because the behaviour is not what
# the YAML whitespace-before-hash rule suggests and the r8 comment got it
# wrong: `"never"#junk` PARSES to a clean `never` (a comment opens straight
# after a closing quote), while `"never" junk` and `"never"junk` both REJECT.
#
# The first case is therefore a DELIBERATE divergence, not agreement with the
# parser -- pinned so it cannot be quietly "corrected" into a skip.
_mkr 'coderabbit:\n  invoke: "never" junk\n'  0 'malformed quoting' 'trailing bare word after a closing quote invokes (go-yaml rejects it)'
_mkr 'coderabbit:\n  invoke: "never"junk\n'   0 'malformed quoting' 'unspaced trailing word after a closing quote invokes (go-yaml rejects it)'
_mkr 'coderabbit:\n  invoke: "never"#junk\n'  0 'malformed quoting' 'DELIBERATE divergence: go-yaml reads this as never, we invoke anyway'
_mkr 'coderabbit:\n  invoke: "never" # ok\n'  1 'never'             'a properly spaced trailing comment still honours never'

echo "--- #1084 r12: tabs are not YAML indentation ---"
# `%b` so the tabs are visible as \t in this source rather than as invisible
# literal whitespace an editor or a lint pass could silently convert.
_mkb() {  # <policy-text-with-escapes> <expect_rc> <name>
  local dir; dir=$(mktemp -d "$WORKDIR/s.XXXXXX"); mkdir -p "$dir/.github" "$dir/scripts"
  cp "$SCRIPT" "$dir/scripts/coderabbit-should-invoke.sh"; chmod +x "$dir/scripts/coderabbit-should-invoke.sh"
  printf '#!/usr/bin/env bash\nexit 0\n' >"$dir/scripts/phase-4b-classifier.sh"; chmod +x "$dir/scripts/phase-4b-classifier.sh"
  printf '%b' "$1" >"$dir/.github/review-policy.yml"
  ( cd "$dir" && ./scripts/coderabbit-should-invoke.sh 99 >/dev/null 2>&1 )
  [ $? = "$2" ] && pass "$3" || fail "$3 (expected rc=$2)"
}
# Every REJECT case below was measured against yq/go-yaml, the parser this
# fleet actually uses -- not inferred from the YAML spec. The comment and
# blank-line cases are why: both look like they should be exempt from
# indentation rules, and both are rejected.
_mkb 'coderabbit:\n\tinvoke: never\n'            0 'a tab-indented child is ambiguous, not a suppressing never'
_mkb 'coderabbit:\n  \tinvoke: never\n'           0 'a tab after leading spaces is ambiguous'
_mkb 'coderabbit:\n\t# c\n  invoke: never\n'      0 'a tab-indented comment line is ambiguous'
_mkb 'coderabbit:\n\t\n  invoke: never\n'         0 'a tab-only blank line is ambiguous'
_mkb 'coderabbit:\n\tenabled: false\n'            0 'a tab-indented enabled: false does not skip either'
# Document-scoped, not block-scoped: a tab under any other top-level key
# rejects the whole file, so a readable `invoke: never` next to it must not win.
_mkb 'other:\n\tx: 1\ncoderabbit:\n  invoke: never\n' 0 'a tab under an earlier top-level key is ambiguous'
_mkb 'coderabbit:\n  invoke: never\nother:\n\tx: 1\n' 0 'a tab under a later top-level key is ambiguous'
# The converse: a tab that is NOT indentation parses fine, so flagging it
# would make every such policy invoke and quietly undo the knob.
_mkb 'coderabbit:\n  invoke: never\t\n'           1 'a trailing tab after a value is not an indentation tab'
_mkb 'coderabbit:\n  invoke: never\n'              1 'baseline: space-indented never still skips'

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
_mk 'coderabbit:
  "invo\u006be": always
  invoke: never' 0 'an escaped quoted direct key cannot bypass duplicate detection'
_mk 'coderabbit:
  invoke: never
"coder\u0061bbit":
  invoke: always' 0 'an escaped quoted header cannot hide a duplicate coderabbit block'
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
exit 0' 'no single valid decision object' 'an unparseable document reports as unparseable'
_diag '#!/usr/bin/env bash
echo "{\"match\": false, \"files_inspected\": 0}"
exit 0' 'inspected no files' 'a genuine empty inspection reports as such'

# Fold in anything the command-not-found hook recorded from its subshell.
if [ -s "$WORKDIR/.unrun" ]; then
  FAIL=$((FAIL + $(wc -l <"$WORKDIR/.unrun" | tr -d ' ')))
fi

echo
echo "test_coderabbit_should_invoke: $PASS passed, $FAIL failed"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
