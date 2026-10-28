#!/usr/bin/env bash
# tests/test_repo_lint_prepush_policy.sh — the per-repository policy of the
# repo-lint pre-push hook, .github/prepush.yml (#2840).
#
# Against a small fixture hub (the real classifier, a fixture workflow and
# graph, probe checks that record what ran), it proves:
#   missing file   - with no .github/prepush.yml every key takes its built-in
#                    default, named as such, and the run is today's: the
#                    live assertions and the selected wrappers, nice 10, the
#                    load-sized default concurrency, no deep lane;
#   precedence     - for every key, --set beats the environment, which beats
#                    the file, which beats the default; the `policy` line
#                    names each source, and the effective values drive the
#                    run (nice, mode, jobs);
#   invalid file   - each malformed policy fails the run closed (exit 2,
#                    named, no check run, never a skip), even when the
#                    environment overrides the offending key;
#   which copy     - a hook run reads the pushed commit's copy, not an
#                    uncommitted edit, and a committed invalid file blocks
#                    the push;
#   shipped file   - mergepath's own .github/prepush.yml resolves to exactly
#                    the built-in defaults, so the hub's behaviour is unchanged.
# Each of the first three is then re-run against a mutated copy of the runner
# that breaks the property, and must fail there: a test that passes against
# the mutant proves nothing.
#
# Hermetic: fixtures under one mktemp dir, GIT_CONFIG_GLOBAL=/dev/null.
# Single-quoted runner source (mutation anchors, generated checks) is
# literal on purpose.
# shellcheck disable=SC2016

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNNER="$REPO_ROOT/scripts/repo-lint-prepush.sh"
INSTALLER="$REPO_ROOT/scripts/install-git-hooks.sh"
HOOK="$REPO_ROOT/scripts/git-hooks/pre-push"
SHIPPED_POLICY="$REPO_ROOT/.github/prepush.yml"

if [ ! -f "$RUNNER" ] && [ ! -f "$REPO_ROOT/scripts/sync-to-downstream.sh" ]; then
  echo "test_repo_lint_prepush_policy: SKIP (consumer checkout: the pre-push mirror is hub-only)"
  exit 0
fi
for tool in jq python3 git shellcheck; do
  command -v "$tool" >/dev/null 2>&1 || { echo "test_repo_lint_prepush_policy: FAIL ($tool is required)" >&2; exit 1; }
done
if ! command -v yq >/dev/null 2>&1 || ! yq --version 2>&1 | grep -q 'mikefarah/yq'; then
  echo "test_repo_lint_prepush_policy: FAIL (mikefarah/yq is required)" >&2
  exit 1
fi

# shellcheck disable=SC2046
unset $(git rev-parse --local-env-vars) 2>/dev/null || true
# Every runner control, so a suite run from inside the hook does not leak the
# pusher's settings into the fixtures.
for v in $(env | sed -n 's/^\(MERGEPATH_PREPUSH_[A-Z_]*\)=.*/\1/p'); do unset "$v"; done
unset GITHUB_OUTPUT 2>/dev/null || true
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=fixture GIT_AUTHOR_EMAIL=fixture@example.invalid
export GIT_COMMITTER_NAME=fixture GIT_COMMITTER_EMAIL=fixture@example.invalid

TMP=$(mktemp -d "${TMPDIR:-/tmp}/test_repo_lint_prepush_policy.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  FAIL $1"; }

# The property checks below report through `expect`. Run normally they pass
# or fail the suite; run against a mutant (SUITE_MODE=mutant) they only count
# their misses in MISSES, and the mutation check requires at least one.
SUITE_MODE=real
MISSES=0
expect() {   # $1 description, $2 actual, $3 expected
  if [ "$2" = "$3" ]; then
    [ "$SUITE_MODE" != real ] || ok "$1"
  elif [ "$SUITE_MODE" = real ]; then
    bad "$1 (expected '$3', got '$2')"
  else
    MISSES=$((MISSES + 1))
  fi
}
expect_has() {   # $1 description, $2 text, $3 literal substring it must contain
  case "$2" in
    *"$3"*) expect "$1" yes yes ;;
    *) expect "$1" "$(printf '%s' "$2" | tail -n 5)" "... $3 ..." ;;
  esac
}
expect_lacks() {   # $1 description, $2 text, $3 literal substring it must not contain
  case "$2" in
    *"$3"*) expect "$1" "contains '$3'" "no '$3'" ;;
    *) expect "$1" yes yes ;;
  esac
}

# ── fixture hub ──────────────────────────────────────────────────────────
FIX="$TMP/fix"
FIXREMOTE="$TMP/fix-remote.git"
mkdir -p "$FIX/scripts/ci" "$FIX/scripts/git-hooks" "$FIX/.github/workflows" "$FIX/other"
cp "$REPO_ROOT/scripts/ci/repo-lint-scope.sh" "$FIX/scripts/ci/"
cp "$RUNNER" "$INSTALLER" "$FIX/scripts/"
cp "$HOOK" "$FIX/scripts/git-hooks/"
chmod +x "$FIX/scripts/git-hooks/pre-push"
printf '#!/usr/bin/env bash\n# hub marker\n' > "$FIX/scripts/sync-to-downstream.sh"
cat > "$FIX/scripts/ci/repo-lint-dependencies.json" <<'JSON'
{"version": 1, "full_triggers": [], "consumer_replay_triggers": [], "deep_triggers": [],
 "self_tests": [], "wrappers": {"check_graphed": ["other/*"]}}
JSON
# Each check records that it ran.
cat > "$FIX/scripts/ci/probe.sh" <<'SH'
#!/usr/bin/env bash
set -eu
touch "$PROBE_DIR/ran.$1"
SH
for c in check_live check_live2 check_graphed check_harness; do
  printf '#!/usr/bin/env bash\nset -eu\nbash "$(dirname "$0")/probe.sh" %s\n' "$c" > "$FIX/scripts/ci/$c"
done
chmod +x "$FIX/scripts/ci/"*
cat > "$FIX/.github/workflows/repo_lint.yml" <<'YAML'
name: repo-lint
on: [pull_request]
jobs:
  scope:
    runs-on: ubuntu-latest
    steps:
      - run: echo scope
  lint_fast:
    runs-on: ubuntu-latest
    strategy:
      matrix:
        shard: [1]
    steps:
      - name: install_python_ci_dependencies
        run: python3 -m pip install "PyYAML==6.0.3" "markdown-it-py==4.2.0"
      - name: check_live
        if: matrix.shard == 1
        run: ./scripts/ci/check_live
      - name: check_live2
        if: matrix.shard == 1
        run: ./scripts/ci/check_live2
      - name: check_graphed
        if: matrix.shard == 1
        run: ./scripts/ci/check_graphed
  deep_safety:
    needs: scope
    if: needs.scope.outputs.deep == 'true'
    steps:
      - name: check_harness
        run: ./scripts/ci/check_harness
  deep_consumer_replay:
    needs: scope
    if: needs.scope.outputs.deep == 'true' && needs.scope.outputs.consumer_replay == 'true'
    steps:
      - name: check_replay_unused
        run: echo unused
  deep_self_tests:
    needs: scope
    if: needs.scope.outputs.deep == 'true' && needs.scope.outputs.self_tests == 'true'
    steps:
      - name: check_selftest_unused
        run: echo unused
YAML
printf 'input\n' > "$FIX/other/input.txt"
printf '.mergepath/\n' > "$FIX/.gitignore"
git -C "$FIX" init -q -b main
git -C "$FIX" add -A
git -C "$FIX" commit -q -m base
git init -q --bare "$FIXREMOTE"
git -C "$FIX" remote add origin "$FIXREMOTE"
git -C "$FIX" push -q --no-verify origin main
git -C "$FIX" fetch -q origin
git -C "$FIX" remote set-head origin main >/dev/null

# The fixture checks need no Python packages: a stub stands in for an
# interpreter with CI's pins. The hook lock stays inside the fixture.
printf '#!/bin/sh\nexit 0\n' > "$TMP/python-ok"
chmod +x "$TMP/python-ok"
export MERGEPATH_PREPUSH_PYTHON="$TMP/python-ok"
export XDG_CACHE_HOME="$TMP/xdg"
export PROBE_DIR="$TMP/probe"
# A fake sysctl reports 4 CPUs and the load FAKE_LOAD, so the load-sized
# default concurrency is deterministic.
FAKEBIN="$TMP/fakebin"
mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/sysctl" <<'SH'
#!/bin/sh
case "$2" in
  hw.ncpu) echo 4 ;;
  vm.loadavg) echo "{ ${FAKE_LOAD:-0.50} 0.00 0.00 }" ;;
  *) exit 1 ;;
esac
SH
chmod +x "$FAKEBIN/sysctl"
export PATH="$FAKEBIN:$PATH"

POLICY="$FIX/.github/prepush.yml"
KEYS='mode full_suite max_minutes deep nice jobs_max load_per_cpu_threshold'
DEFAULTS='mode=full full_suite=run max_minutes=0 deep=false nice=10 jobs_max=2 load_per_cpu_threshold=1'
reset_probe() { rm -rf "$PROBE_DIR"; mkdir -p "$PROBE_DIR"; }
ran() { [ -f "$PROBE_DIR/ran.$1" ] && echo ran || echo 'not run'; }
ran_count() { local f n=0; for f in "$PROBE_DIR"/ran.*; do [ -e "$f" ] && n=$((n + 1)); done; echo "$n"; }
policy_line() { printf '%s\n' "$1" | sed -n 's/^repo-lint pre-push: policy //p; s/^policy\t//p' | head -n 1; }
# The "key=value (source)" entry of one key on a policy line.
policy_entry() { printf '%s\n' "$1" | tr ';' '\n' | head -n 1 | tr ',' '\n' | sed 's/^ *//' | grep "^$2=" || true; }
# The policy line's values alone, in key order.
policy_values() {
  local k out=''
  for k in $KEYS; do out="${out:+$out }$(policy_entry "$1" "$k" | sed 's/ (.*//')"; done
  printf '%s' "$out"
}

# Manual runs against the fixture working tree; each sets OUT and RC.
# README.md selects no graph wrapper, other/input.txt selects check_graphed.
run_plan() {   # $1 runner, rest: extra runner arguments; env comes from the caller
  local r="$1"; shift
  RC=0; OUT=$(cd "$FIX" && printf 'README.md\n' | bash "$r" --paths-from - --plan "$@" 2>&1) || RC=$?
}
run_real() {   # $1 runner, $2 changed path, rest: extra runner arguments
  local r="$1" p="$2"; shift 2
  reset_probe
  RC=0; OUT=$(cd "$FIX" && printf '%s\n' "$p" | bash "$r" --paths-from - "$@" 2>&1) || RC=$?
}

# ── property 1: a missing file is today's behaviour ─────────────────────
assert_missing_file_default() {   # $1 runner
  local r="$1" k line
  rm -f "$POLICY"
  run_plan "$r"
  line=$(policy_line "$OUT")
  expect "missing file: --plan exits 0" "$RC" "0"
  expect "missing file: every key takes its built-in default" "$(policy_values "$line")" "$DEFAULTS"
  for k in $KEYS; do
    expect_has "missing file: $k is attributed to the default" "$(policy_entry "$line" "$k")" "(default)"
  done
  expect_has "missing file: the policy line says the file is absent" "$line" ".github/prepush.yml absent, built-in defaults"
  FAKE_LOAD=0.50 run_real "$r" other/input.txt
  expect "missing file: the run passes" "$RC" "0"
  expect "missing file: live assertion check_live runs" "$(ran check_live)" "ran"
  expect "missing file: live assertion check_live2 runs" "$(ran check_live2)" "ran"
  expect "missing file: the selected wrapper runs" "$(ran check_graphed)" "ran"
  expect "missing file: the deep lane is not run" "$(ran check_harness)" "not run"
  expect_has "missing file: today's nice level and load-sized jobs" "$OUT" "(jobs=2, nice=10, host load 0.50 on 4 CPUs)"
  expect_lacks "missing file: never a skip" "$OUT" "skipped"
  FAKE_LOAD=4.00 run_real "$r" README.md
  expect_has "missing file: load at the CPU count still drops to jobs=1" "$OUT" "(jobs=1, nice=10, host load 4.00 on 4 CPUs)"
}

# ── property 2: --set > environment > file > default ─────────────────────
# One value per key and tier, all distinct from each other and the default.
file_value() { case "$1" in mode) echo selected ;; full_suite) echo defer ;; max_minutes) echo 15 ;; deep) echo true ;; nice) echo 5 ;; jobs_max) echo 3 ;; load_per_cpu_threshold) echo 1.5 ;; esac; }
env_value() { case "$1" in mode) echo off ;; full_suite) echo run ;; max_minutes) echo 20 ;; deep) echo false ;; nice) echo 7 ;; jobs_max) echo 4 ;; load_per_cpu_threshold) echo 2 ;; esac; }
flag_value() { case "$1" in mode) echo full ;; full_suite) echo defer ;; max_minutes) echo 25 ;; deep) echo true ;; nice) echo 3 ;; jobs_max) echo 5 ;; load_per_cpu_threshold) echo 0.5 ;; esac; }
env_name() { printf 'MERGEPATH_PREPUSH_%s' "$(printf '%s' "$1" | tr '[:lower:]' '[:upper:]')"; }
write_policy() { printf '%s\n' "$@" > "$POLICY"; }

assert_precedence() {   # $1 runner
  local r="$1" k e line body=()
  for k in $KEYS; do body+=("$k: $(file_value "$k")"); done
  write_policy "${body[@]}"
  run_plan "$r"; line=$(policy_line "$OUT")
  expect "precedence: a valid file is accepted" "$RC" "0"
  for k in $KEYS; do
    expect "precedence: the file beats the default for $k" "$(policy_entry "$line" "$k")" "$k=$(file_value "$k") (.github/prepush.yml)"
    e=$(env_name "$k")
    run_plan_env "$r" "$e=$(env_value "$k")"; line=$(policy_line "$OUT")
    expect "precedence: $e beats the file" "$(policy_entry "$line" "$k")" "$k=$(env_value "$k") (env $e)"
    run_plan_env "$r" "$e=$(env_value "$k")" --set "$k=$(flag_value "$k")"; line=$(policy_line "$OUT")
    expect "precedence: --set $k beats $e" "$(policy_entry "$line" "$k")" "$k=$(flag_value "$k") (flag --set $k)"
  done
  # retry_failed (#2843) is reported with its source but has no file key.
  run_plan "$r"; line=$(policy_line "$OUT")
  expect "precedence: retry_failed is reported, default false" "$(policy_entry "$line" retry_failed)" "retry_failed=false (default)"
  run_plan_env "$r" MERGEPATH_PREPUSH_RETRY_FAILED=1; line=$(policy_line "$OUT")
  expect "precedence: retry_failed names its environment source" "$(policy_entry "$line" retry_failed)" "retry_failed=true (env MERGEPATH_PREPUSH_RETRY_FAILED)"
  run_plan_env "$r" MERGEPATH_PREPUSH_RETRY_FAILED=0 --retry-failed; line=$(policy_line "$OUT")
  expect "precedence: --retry-failed beats the environment" "$(policy_entry "$line" retry_failed)" "retry_failed=true (flag --retry-failed)"
  # --deep is the deep key's own flag.
  run_plan_env "$r" MERGEPATH_PREPUSH_DEEP=0 --deep; line=$(policy_line "$OUT")
  expect "precedence: --deep beats MERGEPATH_PREPUSH_DEEP" "$(policy_entry "$line" deep)" "deep=true (flag --deep)"
  # The effective values drive the run. File: mode=selected (no live
  # assertions), nice=5, jobs_max=3 under a quiet load.
  write_policy "mode: selected" "nice: 5" "jobs_max: 3"
  FAKE_LOAD=0.50 run_real "$r" other/input.txt
  expect "precedence: the file's mode=selected run passes" "$RC" "0"
  expect "precedence: mode=selected skips the live assertions" "$(ran check_live)" "not run"
  expect "precedence: mode=selected still runs the selected wrapper" "$(ran check_graphed)" "ran"
  expect_has "precedence: the file's nice and jobs_max reach the run" "$OUT" "(jobs=3, nice=5, host load 0.50 on 4 CPUs)"
  # Environment over the file: mode back to full, nice 7.
  FAKE_LOAD=0.50 MERGEPATH_PREPUSH_MODE=full MERGEPATH_PREPUSH_NICE=7 run_real "$r" other/input.txt
  expect "precedence: MERGEPATH_PREPUSH_MODE=full restores the live assertions" "$(ran check_live)" "ran"
  expect_has "precedence: MERGEPATH_PREPUSH_NICE reaches the run" "$OUT" "(jobs=3, nice=7, host load 0.50 on 4 CPUs)"
  # --set over the environment: off wins over MERGEPATH_PREPUSH_MODE=full.
  FAKE_LOAD=0.50 MERGEPATH_PREPUSH_MODE=full run_real "$r" other/input.txt --set mode=off
  expect "precedence: --set mode=off passes" "$RC" "0"
  expect "precedence: --set mode=off runs nothing" "$(ran check_live)$(ran check_graphed)" "not runnot run"
  expect_has "precedence: the skip names its source" "$OUT" "skipped (mode=off from flag --set mode)"
  # mode=selected with nothing selected passes without running anything.
  write_policy "mode: selected"
  run_real "$r" README.md
  expect "precedence: mode=selected with no wrapper selected passes" "$RC" "0"
  expect "precedence: ...and runs nothing" "$(ran check_live)" "not run"
  # load_per_cpu_threshold sets where the default drops to one job.
  write_policy "load_per_cpu_threshold: 0.5"
  FAKE_LOAD=3.00 run_real "$r" README.md
  expect_has "precedence: a lower threshold drops to jobs=1 sooner" "$OUT" "(jobs=1, nice=10, host load 3.00 on 4 CPUs)"
  FAKE_LOAD=3.00 MERGEPATH_PREPUSH_LOAD_PER_CPU_THRESHOLD=1 run_real "$r" README.md
  expect_has "precedence: the default threshold keeps jobs_max at the same load" "$OUT" "(jobs=2, nice=10, host load 3.00 on 4 CPUs)"
  rm -f "$POLICY"
}
run_plan_env() {   # $1 runner, $2 NAME=value, rest: runner arguments
  local r="$1" kv="$2"; shift 2
  RC=0; OUT=$(cd "$FIX" && printf 'README.md\n' | env "$kv" bash "$r" --paths-from - --plan "$@" 2>&1) || RC=$?
}

# ── property 3: an invalid file fails closed ─────────────────────────────
INVALID_BODIES=(
  'mode: of'
  'mode: [full]'
  'mode:'
  'bogus_key: 1'
  'max_minute: 15'
  $'nice: 1\nnice: 2'
  '- mode'
  'just a string'
  $'mode: full\n---\nmode: off'
  'mode: [full'
  'deep: yes'
  'nice: -1'
  'max_minutes: 0x10'
  'jobs_max: 0'
  'load_per_cpu_threshold: 0'
  'full_suite: skip'
  ''
  '# comments only'
)
assert_invalid_file_refused() {   # $1 runner
  local r="$1" body
  for body in "${INVALID_BODIES[@]}"; do
    printf '%s\n' "$body" > "$POLICY"
    run_real "$r" other/input.txt
    expect "invalid file [$(printf '%s' "$body" | tr '\n' '|')]: the run is refused with exit 2" "$RC" "2"
    expect_has "invalid file [$(printf '%s' "$body" | tr '\n' '|')]: the refusal names the file" "$OUT" "invalid .github/prepush.yml:"
    expect "invalid file [$(printf '%s' "$body" | tr '\n' '|')]: no check ran" "$(ran_count)" "0"
    expect_lacks "invalid file [$(printf '%s' "$body" | tr '\n' '|')]: never a skip" "$OUT" "skipped"
  done
  # An environment override of the offending key does not hide the file.
  printf 'mode: of\n' > "$POLICY"
  reset_probe
  RC=0; OUT=$(cd "$FIX" && printf 'other/input.txt\n' | MERGEPATH_PREPUSH_MODE=full bash "$r" --paths-from - 2>&1) || RC=$?
  expect "invalid file under an env override: still refused" "$RC" "2"
  # A path that exists but is not a readable file is not "absent".
  rm -f "$POLICY"; mkdir "$POLICY"
  run_real "$r" other/input.txt
  expect "invalid file: a directory at the path is refused" "$RC" "2"
  rmdir "$POLICY"
  ln -s "$TMP/no-such-policy.yml" "$POLICY"
  run_real "$r" other/input.txt
  expect "invalid file: a dangling symlink is refused, not read as absent" "$RC" "2"
  rm -f "$POLICY"
}

# A mutated copy of the runner: $2 must occur exactly once in it, so a
# mutation that no longer applies fails loudly instead of testing nothing.
mutant() {   # $1 name, $2 old text, $3 new text; prints the mutant's path
  local dst="$TMP/mutant-$1.sh"
  python3 -I - "$RUNNER" "$dst" "$2" "$3" <<'PY'
import sys
src, dst, old, new = sys.argv[1:5]
s = open(src).read()
if s.count(old) != 1:
    sys.exit(f"mutation anchor occurs {s.count(old)} times")
open(dst, "w").write(s.replace(old, new))
PY
  printf '%s' "$dst"
}
mutation_check() {   # $1 property function, $2 name, $3 old, $4 new
  local m
  if ! m=$(mutant "$2" "$3" "$4"); then
    bad "mutation $2: its anchor is gone from the runner; update the mutation"
    return
  fi
  SUITE_MODE=mutant; MISSES=0
  "$1" "$m"
  SUITE_MODE=real
  if [ "$MISSES" -gt 0 ]; then
    ok "mutation $2 breaks $1 ($MISSES assertions fail)"
  else
    bad "mutation $2 leaves $1 passing: the property is not tested"
  fi
  rm -f "$POLICY"; [ ! -d "$POLICY" ] || rmdir "$POLICY"
}

echo "Part 1: a missing .github/prepush.yml is today's behaviour"
assert_missing_file_default "$RUNNER"

echo "Part 2: --set > environment > file > built-in default"
assert_precedence "$RUNNER"

echo "Part 3: an invalid .github/prepush.yml fails closed"
assert_invalid_file_refused "$RUNNER"
# --set and the environment are validated as strictly as the file.
run_plan "$RUNNER" --set mode=sometimes
expect "an invalid --set value is refused" "$RC" "2"
run_plan "$RUNNER" --set no_such_key=1
expect "an unknown --set key is refused" "$RC" "2"
run_plan_env "$RUNNER" MERGEPATH_PREPUSH_JOBS_MAX=two
expect "an invalid environment value is refused" "$RC" "2"
expect_has "the environment refusal names the variable" "$OUT" "MERGEPATH_PREPUSH_JOBS_MAX must be a positive integer (got 'two')"

echo "Part 4: a hook run reads the pushed commit's copy"
git -C "$FIX" config --local core.hooksPath scripts/git-hooks
git -C "$FIX" checkout -q -B feat/policy main
printf 'nice: 5\n' > "$POLICY"
git -C "$FIX" add -A
git -C "$FIX" commit -q -m 'policy: nice 5'
# An uncommitted edit of the policy cannot change the run.
printf 'nice: 7\nmode: off\n' > "$POLICY"
reset_probe
RC=0; OUT=$(cd "$FIX" && git push origin feat/policy 2>&1) || RC=$?
expect "hook: the push passes" "$RC" "0"
expect "hook: the policy line comes from the pushed commit" "$(policy_entry "$(policy_line "$OUT")" nice)" "nice=5 (.github/prepush.yml)"
expect "hook: the uncommitted mode=off is ignored" "$(ran check_live)" "ran"
git -C "$FIX" checkout -q -- .github/prepush.yml
# A committed invalid policy blocks the push; fixing it only in the working
# tree does not help, because the pushed commit still carries it.
printf 'mode: sometimes\n' > "$POLICY"
git -C "$FIX" add -A
git -C "$FIX" commit -q -m 'policy: invalid'
printf 'mode: full\n' > "$POLICY"
reset_probe
RC=0; OUT=$(cd "$FIX" && git push origin feat/policy:refs/heads/feat/policy-invalid 2>&1) || RC=$?
if [ "$RC" -ne 0 ]; then ok "hook: a committed invalid policy blocks the push"; else bad "hook: a committed invalid policy was pushed: $OUT"; fi
expect_has "hook: the refusal names the file and the bad value" "$OUT" "invalid .github/prepush.yml: mode must be one of off, selected, full (got 'sometimes')"
expect "hook: the remote did not receive the invalid policy" "$(git -C "$FIXREMOTE" rev-parse -q --verify refs/heads/feat/policy-invalid || echo none)" "none"
git -C "$FIX" checkout -q -- .github/prepush.yml
git -C "$FIX" checkout -q main

echo "Part 5: mergepath's own .github/prepush.yml keeps today's behaviour"
if [ -f "$SHIPPED_POLICY" ]; then
  cp "$SHIPPED_POLICY" "$POLICY"
  run_plan "$RUNNER"
  expect "the shipped policy is valid" "$RC" "0"
  expect "the shipped policy equals the built-in defaults" "$(policy_values "$(policy_line "$OUT")")" "$DEFAULTS"
  for k in $KEYS; do
    expect_has "the shipped policy sets $k explicitly" "$(policy_entry "$(policy_line "$OUT")" "$k")" "(.github/prepush.yml)"
  done
  rm -f "$POLICY"
else
  bad "the hub ships no .github/prepush.yml"
fi
help_out=$(bash "$RUNNER" --help)
for want in .github/prepush.yml MERGEPATH_PREPUSH_MODE MERGEPATH_PREPUSH_FULL_SUITE MERGEPATH_PREPUSH_MAX_MINUTES \
  MERGEPATH_PREPUSH_JOBS_MAX MERGEPATH_PREPUSH_LOAD_PER_CPU_THRESHOLD '--set KEY=VALUE'; do
  case "$help_out" in *"$want"*) ok "--help documents $want" ;; *) bad "--help omits $want" ;; esac
done

echo "Part 6: each property fails against a runner mutated to break it"
# The file beats the environment: the env tier applies only where the file is silent.
mutation_check assert_precedence file-beats-env \
  'if [ -n "${!env-}" ]; then' \
  'if [ -n "${!env-}" ] && [ -z "${!n-}" ]; then'
# --set is ignored after validation.
mutation_check assert_precedence flag-ignored \
  'policy_set "$k" "$(policy_normalize "$k" "${line#*=}")" "flag --set $k"' \
  ':'
# A missing file silently turns the hook off.
mutation_check assert_missing_file_default missing-means-off \
  'mode|MERGEPATH_PREPUSH_MODE|full' \
  'mode|MERGEPATH_PREPUSH_MODE|off'
# A missing file is treated as an invalid one.
mutation_check assert_missing_file_default missing-means-invalid \
  $'  if [ ! -e "$f" ] && [ ! -L "$f" ]; then\n    return 0' \
  $'  if [ ! -e "$f" ] && [ ! -L "$f" ]; then\n    policy_refuse "absent"'
# An invalid file falls back to the defaults with a warning.
mutation_check assert_invalid_file_refused invalid-falls-back \
  '  die "invalid $PREPUSH_POLICY_FILE: $*.' \
  '  echo "ignoring $PREPUSH_POLICY_FILE: $*" >&2; POLICY_FILE_STATE=absent; return 0; die "invalid $PREPUSH_POLICY_FILE: $*.'

echo ""
echo "test_repo_lint_prepush_policy: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
