#!/usr/bin/env bash
# tests/test_repo_lint_prepush_defer.sh — the repo-lint pre-push hook's
# full-suite deferral and wall-clock budget (#2841).
#
# Against a small fixture hub (the real classifier, a fixture workflow and a
# graph with a full trigger, probe checks that record what ran), it proves:
#   deferral       - under full_suite=defer a change that selects the
#                    complete surface runs the live assertions and the
#                    wrappers its paths select (a full trigger selects the
#                    wrappers that declare it), names every other wrapper as
#                    deferred to CI, and exits 0 with the deferral on its
#                    last line; an undeclared path selects nothing, a
#                    propagation-lane head defers too, and a change that
#                    does not select everything defers nothing;
#   budget         - under max_minutes a step whose previous duration would
#                    pass the budget, and every step once it is spent, is
#                    not started; the run lists them and exits 0, and says so
#                    on its last line;
#   failure        - a failed step still blocks the push when the budget
#                    deferred others;
#   run unchanged  - full_suite=run (the default) runs the complete surface
#                    exactly as before.
# A hook push of a committed `full_suite: defer` policy shows the same in
# the path git takes. Each property is then re-run against a mutated copy of
# the runner that breaks it, and must fail there.
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

# Marker-first (#2844): consumers now receive the runner, but not this
# suite's hub-shaped fixtures and expectations, so the runner's presence no
# longer tells a consumer from the hub.
if [ ! -f "$REPO_ROOT/scripts/sync-to-downstream.sh" ]; then
  echo "test_repo_lint_prepush_defer: SKIP (consumer checkout: scripts/sync-to-downstream.sh absent; the pre-push suites are hub-only)"
  exit 0
fi
for tool in jq python3 git shellcheck; do
  command -v "$tool" >/dev/null 2>&1 || { echo "test_repo_lint_prepush_defer: FAIL ($tool is required)" >&2; exit 1; }
done
if ! command -v yq >/dev/null 2>&1 || ! yq --version 2>&1 | grep -q 'mikefarah/yq'; then
  echo "test_repo_lint_prepush_defer: FAIL (mikefarah/yq is required)" >&2
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

TMP=$(mktemp -d "${TMPDIR:-/tmp}/test_repo_lint_prepush_defer.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  FAIL $1"; }

# Run normally the property checks pass or fail the suite; run against a
# mutant (SUITE_MODE=mutant) the first miss ends it (mutant_killed below).
SUITE_MODE=real
# #2990: in mutant mode the first failed assertion ends the property at
# once. It records which assertion failed and exits the property's subshell
# with MUTANT_KILLED, the only status mutation_check counts as a kill, so the
# property's remaining runs are skipped and nothing else (a harness error,
# set -e, the watchdog) can pass for a kill.
MUTANT_KILLED=86
MUTANT_TIMEOUT_S=300
mutant_killed() { printf '%s\n' "$1" > "$TMP/mutant-killer"; exit "$MUTANT_KILLED"; }
expect() {   # $1 description, $2 actual, $3 expected
  if [ "$2" = "$3" ]; then
    [ "$SUITE_MODE" != real ] || ok "$1"
  elif [ "$SUITE_MODE" = real ]; then
    bad "$1 (expected '$3', got '$2')"
  else
    mutant_killed "$1"
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
# The graph's full trigger is the graph itself, as in mergepath. check_owner
# declares it; check_graphed owns other/*; check_unrelated owns unrelated/*,
# which no case below changes, so only the complete surface selects it.
FIX="$TMP/fix"
FIXREMOTE="$TMP/fix-remote.git"
mkdir -p "$FIX/scripts/ci" "$FIX/scripts/git-hooks" "$FIX/.github/workflows" "$FIX/other" "$FIX/unrelated"
cp "$REPO_ROOT/scripts/ci/repo-lint-scope.sh" "$FIX/scripts/ci/"
cp "$RUNNER" "$INSTALLER" "$FIX/scripts/"
cp "$HOOK" "$FIX/scripts/git-hooks/"
chmod +x "$FIX/scripts/git-hooks/pre-push"
printf '#!/usr/bin/env bash\n# hub marker\n' > "$FIX/scripts/sync-to-downstream.sh"
cat > "$FIX/scripts/ci/repo-lint-dependencies.json" <<'JSON'
{"version": 1, "full_triggers": ["scripts/ci/repo-lint-dependencies.json"],
 "consumer_replay_triggers": [], "deep_triggers": [], "self_tests": [],
 "wrappers": {"check_graphed": ["other/*"],
              "check_owner": ["scripts/ci/repo-lint-dependencies.json"],
              "check_unrelated": ["unrelated/*"]}}
JSON
# Each check records that it ran, and that it finished; PROBE_FAIL names
# checks that fail, and PROBE_SLOW one that first spends PROBE_SLOW_SECS: on
# the fixture clock when one is running (below), otherwise in a real sleep.
cat > "$FIX/scripts/ci/probe.sh" <<'SH'
#!/usr/bin/env bash
set -eu
touch "$PROBE_DIR/ran.$1"
if [ "$1" = "${PROBE_SLOW:-}" ]; then
  if [ -n "${FAKE_CLOCK_FILE:-}" ]; then
    now=$(cat "$FAKE_CLOCK_FILE")
    printf '%s\n' "$((now + ${PROBE_SLOW_SECS:-0}))" > "$FAKE_CLOCK_FILE.tmp"
    mv "$FAKE_CLOCK_FILE.tmp" "$FAKE_CLOCK_FILE"
  else
    sleep "${PROBE_SLOW_SECS:-0}"
  fi
fi
case " ${PROBE_FAIL:-} " in *" $1 "*) echo "probe: $1 fails" >&2; exit 1 ;; esac
touch "$PROBE_DIR/done.$1"
SH
for c in check_live check_live2 check_graphed check_owner check_unrelated check_harness; do
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
      - name: check_owner
        if: matrix.shard == 1
        run: ./scripts/ci/check_owner
      - name: check_unrelated
        if: matrix.shard == 1
        run: ./scripts/ci/check_unrelated
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
printf 'input\n' > "$FIX/unrelated/input.txt"
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
# interpreter with CI's pins. The hook lock stays inside the fixture, and a
# fake sysctl (4 CPUs, load 0.50) keeps the default concurrency at 2.
printf '#!/bin/sh\nexit 0\n' > "$TMP/python-ok"
chmod +x "$TMP/python-ok"
export MERGEPATH_PREPUSH_PYTHON="$TMP/python-ok"
export XDG_CACHE_HOME="$TMP/xdg"
export PROBE_DIR="$TMP/probe"
FAKEBIN="$TMP/fakebin"
mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/sysctl" <<'SH'
#!/bin/sh
case "$2" in
  hw.ncpu) echo 4 ;;
  vm.loadavg) echo "{ 0.50 0.00 0.00 }" ;;
  *) exit 1 ;;
esac
SH
chmod +x "$FAKEBIN/sysctl"
export PATH="$FAKEBIN:$PATH"
# The fixture clock (#2990). The runner reads the time only through
# `date +%s`; on CLOCKBIN's PATH that answers the epoch second in
# FAKE_CLOCK_FILE, which stands still until a check advances it, and every
# other `date` call goes to the real one. So the budget's expiry is exact:
# the elapsed time the feeder sees is whatever the slow check added, not a
# real minute plus scheduling noise. No production code knows about it.
CLOCKBIN="$TMP/clockbin"
mkdir -p "$CLOCKBIN"
cat > "$CLOCKBIN/date" <<'SH'
#!/bin/sh
if [ "$#" -eq 1 ] && [ "$1" = +%s ] && [ -n "${FAKE_CLOCK_FILE:-}" ]; then
  exec cat "$FAKE_CLOCK_FILE"
fi
exec /bin/date "$@"
SH
chmod +x "$CLOCKBIN/date"

POLICY="$FIX/.github/prepush.yml"
TIMINGS="$FIX/.mergepath/prepush-timings.tsv"
GRAPH_PATH=scripts/ci/repo-lint-dependencies.json
reset_probe() { rm -rf "$PROBE_DIR"; mkdir -p "$PROBE_DIR"; }
ran() { [ -f "$PROBE_DIR/ran.$1" ] && echo ran || echo 'not run'; }
last_line() { printf '%s\n' "$1" | sed '/^$/d' | tail -n 1; }
# Previous durations, name<TAB>seconds, as a past run would have left them.
seed_timings() { mkdir -p "$(dirname "$TIMINGS")"; printf '%s\n' "$@" > "$TIMINGS"; }
clear_state() { rm -f "$POLICY" "$TIMINGS"; }

run_paths() {   # $1 runner, $2 newline-separated changed paths, rest: runner arguments
  local r="$1" p="$2"; shift 2
  reset_probe
  RC=0; OUT=$(cd "$FIX" && printf '%s\n' "$p" | bash "$r" --paths-from - "$@" 2>&1) || RC=$?
}
plan_paths() {   # same, with --plan
  local r="$1" p="$2"; shift 2
  RC=0; OUT=$(cd "$FIX" && printf '%s\n' "$p" | bash "$r" --paths-from - --plan "$@" 2>&1) || RC=$?
}
lane_of() { printf '%s\n' "$OUT" | awk -F'\t' -v n="$1" '$3 == n && $2 == "lint_fast" { print $1; exit }'; }

# ── property 1: full_suite=defer runs what the changed paths select ──────
assert_defer_selects_changed_paths() {   # $1 runner
  local r="$1" both
  both=$(printf '%s\nother/input.txt' "$GRAPH_PATH")
  clear_state
  plan_paths "$r" "$both" --set full_suite=defer
  expect "defer --plan: exits 0" "$RC" "0"
  expect "defer --plan: CI's scope still selects everything" "$(printf '%s\n' "$OUT" | sed -n 's/^scope\t.*full=\([a-z]*\).*/\1/p')" "true"
  expect_has "defer --plan: names the reason" "$OUT" "$(printf 'defer\ta full trigger (%s)' "$GRAPH_PATH")"
  expect "defer --plan: the wrapper declaring the full trigger is selected" "$(lane_of check_owner)" "selected"
  expect "defer --plan: the wrapper owning the other path is selected" "$(lane_of check_graphed)" "selected"
  expect "defer --plan: the unrelated wrapper is deferred" "$(lane_of check_unrelated)" "fallback"
  expect "defer --plan: the live assertions stay live" "$(lane_of check_live)" "live"

  run_paths "$r" "$both" --set full_suite=defer
  expect "defer: the run passes" "$RC" "0"
  expect "defer: live assertion check_live runs" "$(ran check_live)" "ran"
  expect "defer: live assertion check_live2 runs" "$(ran check_live2)" "ran"
  expect "defer: the full trigger's own wrapper runs" "$(ran check_owner)" "ran"
  expect "defer: the changed path's wrapper runs" "$(ran check_graphed)" "ran"
  expect "defer: the unrelated wrapper does not run" "$(ran check_unrelated)" "not run"
  expect_has "defer: the deferred wrapper is named" "$OUT" "$(printf 'deferring 1 wrappers to CI (CI'"'"'s lint runs them):\n    check_unrelated')"
  expect_has "defer: the last line says the run deferred" "$(last_line "$OUT")" "PASS with checks DEFERRED TO CI"
  expect_has "defer: the last line counts the deferral" "$(last_line "$OUT")" "deferred: 1 by full_suite=defer"

  # An undeclared path selects nothing under deferral; the rest still defers.
  run_paths "$r" "$(printf '%s\nscripts/undeclared.sh' "$GRAPH_PATH")" --set full_suite=defer
  expect "defer+undeclared: the run passes" "$RC" "0"
  expect "defer+undeclared: the owner runs" "$(ran check_owner)" "ran"
  expect "defer+undeclared: the unrelated wrapper does not run" "$(ran check_unrelated)" "not run"
  expect_has "defer+undeclared: the undeclared path is named" "$OUT" "scripts/undeclared.sh is in no wrapper's declared inputs"

  # A propagation-lane head selects everything for CI; the hook defers it.
  run_paths "$r" other/input.txt --set full_suite=defer --head-ref mergepath-sync/fixture
  expect "defer+propagation head: the run passes" "$RC" "0"
  expect "defer+propagation head: the changed path's wrapper runs" "$(ran check_graphed)" "ran"
  expect "defer+propagation head: the unrelated wrapper does not run" "$(ran check_unrelated)" "not run"
  expect_has "defer+propagation head: the reason is named" "$OUT" "selected by a propagation-lane head"

  # A change that does not select the complete surface defers nothing.
  run_paths "$r" other/input.txt --set full_suite=defer
  expect "defer, partial selection: the run passes" "$RC" "0"
  expect_lacks "defer, partial selection: nothing is deferred" "$OUT" "DEFERRED"
  expect_lacks "defer, partial selection: no deferral notice" "$OUT" "full_suite=defer:"
}

# ── property 2: max_minutes stops starting steps that cannot fit ─────────
assert_budget_defers_unstarted() {   # $1 runner
  local r="$1"
  clear_state
  # check_unrelated took 9999 s last time: it cannot fit a 1-minute budget.
  seed_timings "$(printf 'check_unrelated\t9999')"
  run_paths "$r" "$GRAPH_PATH" --set max_minutes=1
  expect "budget: the run passes" "$RC" "0"
  expect "budget: the step that would pass the budget is not started" "$(ran check_unrelated)" "not run"
  expect "budget: the others run" "$(ran check_owner)$(ran check_graphed)$(ran check_live)" "ranranran"
  expect_has "budget: the run line shows the budget" "$OUT" "budget 1m)"
  expect_has "budget: the unstarted step is listed" "$OUT" "$(printf 'not started within the budget and are deferred to CI (CI'"'"'s lint runs them):\n    check_unrelated')"
  expect_has "budget: the last line says the run deferred" "$(last_line "$OUT")" "PASS with checks DEFERRED TO CI"
  expect_has "budget: the last line counts the budget deferral" "$(last_line "$OUT")" "1 by the 1-minute budget"
  # A budget that defers every step hands the workers nothing: the run still
  # passes and lists them all (GNU xargs runs its command once on empty
  # input, so the worker must accept no step id).
  seed_timings "$(printf 'check_live\t9999')" "$(printf 'check_live2\t9999')" "$(printf 'check_graphed\t9999')"
  run_paths "$r" other/input.txt --set max_minutes=1
  expect "budget, all deferred: the run passes" "$RC" "0"
  expect "budget, all deferred: nothing ran" "$(ran check_live)$(ran check_live2)$(ran check_graphed)" "not runnot runnot run"
  expect_has "budget, all deferred: the last line counts all three" "$(last_line "$OUT")" "3 by the 1-minute budget"
  mkdir -p "$TMP/emptyrun/results"
  RC=0; bash "$r" --exec-step "$TMP/emptyrun" >/dev/null 2>&1 || RC=$?
  expect "worker with no step id (GNU xargs on empty input): exits 0" "$RC" "0"
  expect "worker with no step id: writes no result" "$(find "$TMP/emptyrun/results" -type f | wc -l | tr -d ' ')" "0"
  rm -rf "$TMP/emptyrun"
  # A garbled timing cache predicts nothing and never changes the outcome.
  seed_timings "$(printf 'check_unrelated\tabc')" "$(printf 'check_owner\t1e9')"
  run_paths "$r" "$GRAPH_PATH" --set max_minutes=1
  expect "budget, garbled timings: the run passes" "$RC" "0"
  expect "budget, garbled timings: every check runs" "$(ran check_unrelated)$(ran check_owner)" "ranran"
  expect_lacks "budget, garbled timings: nothing is deferred" "$OUT" "DEFERRED"
}

# ── property 3: a failed step still blocks the push ──────────────────────
assert_failure_blocks_after_budget() {   # $1 runner
  local r="$1"
  clear_state
  seed_timings "$(printf 'check_unrelated\t9999')"
  PROBE_FAIL=check_graphed run_paths "$r" "$GRAPH_PATH" --set max_minutes=1
  expect "failure+budget: the run fails" "$RC" "1"
  expect "failure+budget: the budget still deferred a step" "$(ran check_unrelated)" "not run"
  expect_has "failure+budget: the verdict names the failure" "$OUT" "FAIL (1 of"
  expect_has "failure+budget: the last line still names the deferral" "$(last_line "$OUT")" "DEFERRED checks TO CI"
  PROBE_FAIL=check_graphed run_paths "$r" "$(printf '%s\nother/input.txt' "$GRAPH_PATH")" --set full_suite=defer
  expect "failure+defer: the run fails" "$RC" "1"
  expect_has "failure+defer: the last line still names the deferral" "$(last_line "$OUT")" "1 by full_suite=defer"
}

# ── property 4: full_suite=run is unchanged ──────────────────────────────
assert_run_unchanged() {   # $1 runner
  local r="$1" default_plan
  clear_state
  plan_paths "$r" "$GRAPH_PATH"
  default_plan=$(printf '%s\n' "$OUT" | grep -v '^policy' || true)
  expect "default --plan: the unrelated wrapper is selected" "$(lane_of check_unrelated)" "selected"
  plan_paths "$r" "$GRAPH_PATH" --set full_suite=run
  expect "run --plan: identical to the default" "$(printf '%s\n' "$OUT" | grep -v '^policy' || true)" "$default_plan"
  run_paths "$r" "$GRAPH_PATH"
  expect "default run: passes" "$RC" "0"
  expect "default run: every wrapper runs" "$(ran check_owner)$(ran check_graphed)$(ran check_unrelated)" "ranranran"
  expect_has "default run: a plain PASS" "$(last_line "$OUT")" "PASS ("
  expect_lacks "default run: nothing deferred" "$OUT" "DEFERRED"
}

echo "Part 1: full_suite=defer runs the changed paths' wrappers and names the rest"
assert_defer_selects_changed_paths "$RUNNER"

echo "Part 2: max_minutes does not start a step that would pass the budget"
assert_budget_defers_unstarted "$RUNNER"
# Once the budget is spent nothing more starts: one check outlasts a
# 1-minute budget (one at a time), and every later one is deferred. The
# long check spends its time on the fixture clock, so these cases also pin
# the expiry's boundaries exactly (#2990): a step starts while elapsed time
# is under the budget and elapsed plus its previous duration does not pass
# it, and is deferred from the second the budget is spent.
clock_run() {   # $1 runner, $2 seconds the long check spends, $3 later checks' previous duration
  clear_state
  seed_timings "$(printf 'check_graphed\t30')" "$(printf 'check_live\t%s' "$3")" "$(printf 'check_live2\t%s' "$3")" "$(printf 'check_owner\t1')"
  printf '%s\n' 1700000000 > "$TMP/clock"
  PATH="$CLOCKBIN:$PATH" FAKE_CLOCK_FILE="$TMP/clock" PROBE_SLOW=check_graphed PROBE_SLOW_SECS="$2" \
    run_paths "$1" other/input.txt --set max_minutes=1 --jobs 1
}
done_set() { for c in check_graphed check_live check_live2; do [ ! -f "$PROBE_DIR/done.$c" ] || printf '%s ' "$c"; done; }
assert_budget_expiry() {   # $1 runner
  clock_run "$1" 61 1
  expect "spent budget: the run passes" "$RC" "0"
  expect "spent budget: the long check ran to the end" "$(ran check_graphed) $(done_set)" "ran check_graphed "
  expect "spent budget: the later checks were not started" "$(ran check_live)$(ran check_live2)" "not runnot run"
  expect_has "spent budget: the last line counts them" "$(last_line "$OUT")" "2 by the 1-minute budget"
  clock_run "$1" 60 0
  expect "budget spent to the second: the run passes" "$RC" "0"
  expect "budget spent to the second: only the check started in time ran, and it finished" "$(done_set)" "check_graphed "
  expect_has "budget spent to the second: both later checks are deferred" "$(last_line "$OUT")" "2 by the 1-minute budget"
  clock_run "$1" 59 1
  expect "a second left, elapsed plus previous at the budget: the run passes" "$RC" "0"
  expect "a second left, elapsed plus previous at the budget: every check starts and finishes" "$(done_set)" "check_graphed check_live check_live2 "
  expect_lacks "a second left, elapsed plus previous at the budget: nothing is deferred" "$OUT" "DEFERRED"
  clock_run "$1" 59 2
  expect "a second left, elapsed plus previous past the budget: the run passes" "$RC" "0"
  expect "a second left, elapsed plus previous past the budget: only the started check ran" "$(done_set)" "check_graphed "
  expect_has "a second left, elapsed plus previous past the budget: both are deferred" "$(last_line "$OUT")" "2 by the 1-minute budget"
}
assert_budget_expiry "$RUNNER"

# A zero concurrency, however it is spelled, is refused rather than left to
# a feeder that would wait for a free slot forever.
for j in 0 00 000 1x; do
  plan_paths "$RUNNER" other/input.txt --jobs "$j"
  expect "--jobs $j is refused" "$RC" "2"
done
RC=0; OUT=$(cd "$FIX" && printf 'other/input.txt\n' | MERGEPATH_PREPUSH_JOBS=000 bash "$RUNNER" --paths-from - --plan 2>&1) || RC=$?
expect "MERGEPATH_PREPUSH_JOBS=000 is refused" "$RC" "2"
expect_has "the refusal names the value" "$OUT" "must be a positive integer (got '000')"
plan_paths "$RUNNER" other/input.txt --jobs 02
expect "--jobs 02 is accepted" "$RC" "0"

echo "Part 3: a failed step still blocks the push"
assert_failure_blocks_after_budget "$RUNNER"

echo "Part 4: full_suite=run is unchanged"
assert_run_unchanged "$RUNNER"

echo "Part 5: a hook push of a committed full_suite=defer policy"
clear_state
git -C "$FIX" config --local core.hooksPath scripts/git-hooks
git -C "$FIX" checkout -q -B feat/defer main
printf 'full_suite: defer\nmax_minutes: 15\n' > "$POLICY"
jq '.wrappers.check_unrelated += ["unrelated2/*"]' "$FIX/$GRAPH_PATH" > "$TMP/graph.json" && mv "$TMP/graph.json" "$FIX/$GRAPH_PATH"
git -C "$FIX" add -A
git -C "$FIX" commit -q -m 'graph edit under a deferring policy'
reset_probe
RC=0; OUT=$(cd "$FIX" && git push origin feat/defer 2>&1) || RC=$?
expect "hook: the push passes" "$RC" "0"
expect "hook: the remote received the branch" "$(git -C "$FIXREMOTE" rev-parse -q --verify refs/heads/feat/defer >/dev/null && echo yes || echo no)" "yes"
expect "hook: the graph's own wrapper ran" "$(ran check_owner)" "ran"
expect "hook: the unrelated wrapper was deferred" "$(ran check_unrelated)" "not run"
expect_has "hook: the deferral is named" "$OUT" "full_suite=defer: the complete surface is selected by a full trigger ($GRAPH_PATH)"
expect_has "hook: the policy line shows the committed values" "$OUT" "full_suite=defer (.github/prepush.yml), max_minutes=15 (.github/prepush.yml)"
git -C "$FIX" checkout -q main

help_out=$(bash "$RUNNER" --help)
for want in 'full_suite' 'max_minutes' 'deferred to CI'; do
  case "$help_out" in *"$want"*) ok "--help documents $want" ;; *) bad "--help omits $want" ;; esac
done

echo "Part 6: each property fails against a runner mutated to break it"
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
# Runs property $1 against runner $2 in mutant mode and prints its verdict:
# `killed<TAB>assertion`, `survived`, or `error<TAB>status`. The property runs
# in a subshell, so mutant_killed can end it early, under a watchdog: a
# mutant that hangs is stopped and reported, never counted. Its output goes
# to $3, kept for the diagnostics below.
mutant_verdict() {   # $1 property function, $2 runner, $3 log file
  local pid rc waited=0
  rm -f "$TMP/mutant-killer"
  # errexit is set again inside: a command substitution (the caller's
  # verdict=$(...)) drops it, and a property must stop at a failed command
  # as it does in a real run, not go on to a miss that reads as a kill.
  ( set -euo pipefail; SUITE_MODE=mutant; "$1" "$2" ) > "$3" 2>&1 &
  pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$waited" -ge $((MUTANT_TIMEOUT_S * 5)) ]; then
      pkill -TERM -P "$pid" 2>/dev/null || true
      kill -TERM "$pid" 2>/dev/null || true
      break
    fi
    sleep 0.2; waited=$((waited + 1))
  done
  rc=0; wait "$pid" || rc=$?
  if [ "$rc" -eq "$MUTANT_KILLED" ] && [ -s "$TMP/mutant-killer" ]; then
    printf 'killed\t%s\n' "$(cat "$TMP/mutant-killer")"
  elif [ "$rc" -eq 0 ]; then
    echo survived
  else
    printf 'error\t%s\n' "$rc"
  fi
}
mutation_check() {   # $1 property function, $2 name, $3 old, $4 new
  local m verdict
  if ! m=$(mutant "$2" "$3" "$4"); then
    bad "mutation $2: its anchor is gone from the runner; update the mutation"
    return
  fi
  verdict=$(mutant_verdict "$1" "$m" "$TMP/mutant-$2.log")
  case "$verdict" in
    killed*) ok "mutation $2 breaks $1 (killed by: ${verdict#killed?})" ;;
    survived) bad "mutation $2 leaves $1 passing: the property is not tested" ;;
    *)
      bad "mutation $2: $1 ended with status ${verdict#error?} before any assertion failed (a harness error or the ${MUTANT_TIMEOUT_S}s watchdog), which is not a kill"
      tail -n 5 "$TMP/mutant-$2.log" | sed 's/^/        /'
      ;;
  esac
  clear_state
}
# #2990: the harness itself. Only a failed assertion of the property kills a
# mutant: a property that completes, crashes, or outlives the watchdog is
# not a kill, whatever it printed.
harness_ok() { expect "harness self-test: a passing assertion" yes yes; }
harness_miss() { expect "harness self-test: a missed assertion" 1 2; }
harness_crash() { false; expect "harness self-test: unreachable" 1 2; }
harness_exit() { exit 3; }
harness_hang() { sleep 30; expect "harness self-test: unreachable" 1 2; }
v=$(mutant_verdict harness_miss "$RUNNER" "$TMP/harness.log")
[ "$v" = "$(printf 'killed\tharness self-test: a missed assertion')" ] && ok "harness: a failed assertion kills the mutant and is named" || bad "harness: a failed assertion read as '$v'"
v=$(mutant_verdict harness_ok "$RUNNER" "$TMP/harness.log")
[ "$v" = survived ] && ok "harness: a property that passes is a survivor" || bad "harness: a passing property read as '$v'"
v=$(mutant_verdict harness_crash "$RUNNER" "$TMP/harness.log")
[ "$v" = "$(printf 'error\t1')" ] && ok "harness: a command failure is an error, not a kill" || bad "harness: a command failure read as '$v'"
v=$(mutant_verdict harness_exit "$RUNNER" "$TMP/harness.log")
[ "$v" = "$(printf 'error\t3')" ] && ok "harness: an early exit is an error, not a kill" || bad "harness: an early exit read as '$v'"
v=$(MUTANT_TIMEOUT_S=1; mutant_verdict harness_hang "$RUNNER" "$TMP/harness.log")
case "$v" in error*) ok "harness: the watchdog stops a hang and it is not a kill" ;; *) bad "harness: a hang read as '$v'" ;; esac

# full_suite=defer is ignored: the complete surface runs.
mutation_check assert_defer_selects_changed_paths defer-ignored \
  'if [ "$P_FULL" = true ] && [ "$(policy_value full_suite)" = defer ]; then' \
  'if false; then'
# A full trigger no longer selects the wrappers that declare it.
mutation_check assert_defer_selects_changed_paths owners-dropped \
  'd_owned="${d_owned}${w}' \
  'd_owned="${d_owned}'
# A deferring run ends on a bare PASS.
mutation_check assert_defer_selects_changed_paths silent-pass \
  $'  if [ -n "$DEFERRED_SUMMARY" ]; then\n    echo "$PREFIX: PASS with' \
  $'  if false; then\n    echo "$PREFIX: PASS with'
# The budget is ignored.
mutation_check assert_budget_defers_unstarted budget-ignored \
  $'    if [ "$BUDGET_S" -gt 0 ]; then\n      el=' \
  $'    if false; then\n      el='
# A garbled timing cache aborts the budget arithmetic.
mutation_check assert_budget_defers_unstarted garbled-timing-trusted \
  "    case \"\$prev\" in ''|*[!0-9]*) prev=0 ;; esac" \
  '    :'
# The worker trips over GNU xargs's empty invocation.
mutation_check assert_budget_defers_unstarted empty-invocation-fails \
  '  [ -n "${3:-}" ] || exit 0' \
  '  :'
# A budget deferral masks a failure.
mutation_check assert_failure_blocks_after_budget failure-masked \
  $'if [ "$failed" -eq 0 ]; then\n  if [ "${MERGEPATH_PREPUSH_KEEP_LOGS' \
  $'if [ "$failed" -eq 0 ] || [ "$BUDGET_N" -gt 0 ]; then\n  if [ "${MERGEPATH_PREPUSH_KEEP_LOGS'
# #2990: the budget's two boundaries, pinned by the fixture clock. A spent
# budget that still starts steps until it is passed by a second:
mutation_check assert_budget_expiry spent-at-the-second-starts \
  'if [ "$el" -ge "$BUDGET_S" ] || [ $((el + prev)) -gt "$BUDGET_S" ]; then' \
  'if [ "$el" -gt "$BUDGET_S" ] || [ $((el + prev)) -gt "$BUDGET_S" ]; then'
# A prediction that defers a step which would end exactly at the budget:
mutation_check assert_budget_expiry prediction-at-the-budget-defers \
  'if [ "$el" -ge "$BUDGET_S" ] || [ $((el + prev)) -gt "$BUDGET_S" ]; then' \
  'if [ "$el" -ge "$BUDGET_S" ] || [ $((el + prev)) -ge "$BUDGET_S" ]; then'
# The default turns into defer.
mutation_check assert_run_unchanged default-defers \
  'full_suite|MERGEPATH_PREPUSH_FULL_SUITE|run' \
  'full_suite|MERGEPATH_PREPUSH_FULL_SUITE|defer'

echo ""
echo "test_repo_lint_prepush_defer: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
