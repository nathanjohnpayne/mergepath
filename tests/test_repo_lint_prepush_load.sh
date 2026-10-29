#!/usr/bin/env bash
# tests/test_repo_lint_prepush_load.sh — the repo-lint pre-push hook re-reads
# the host load during the run (#2842).
#
# Against a small fixture hub (the real classifier, a fixture workflow, probe
# checks that record how many checks run at once), with a fake `sysctl` on
# PATH that reads the load from a file the probes rewrite while the run is in
# progress, it proves:
#   falling and rising - a run that starts at jobs=2 drops to 1 when the load
#                        rises mid-run and returns to 2 when it falls, each
#                        change is logged, and the checks really overlap or
#                        do not accordingly;
#   starting loaded    - a run that starts at jobs=1 on a busy host rises to
#                        jobs_max once the load falls (xargs -P is only the
#                        upper bound);
#   pinned             - MERGEPATH_PREPUSH_JOBS and --jobs hold the
#                        concurrency whatever the load does, and the output
#                        says so;
#   throttled          - a long wait does not read the load every second.
# Each property is then re-run against a mutated copy of the runner that
# breaks it (one that pins the first reading among them), and must fail there.
#
# Hermetic: fixtures under one mktemp dir, GIT_CONFIG_GLOBAL=/dev/null.
# Single-quoted runner source (mutation anchors, generated checks) is
# literal on purpose.
# shellcheck disable=SC2016

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNNER="$REPO_ROOT/scripts/repo-lint-prepush.sh"

if [ ! -f "$RUNNER" ] && [ ! -f "$REPO_ROOT/scripts/sync-to-downstream.sh" ]; then
  echo "test_repo_lint_prepush_load: SKIP (consumer checkout: the pre-push mirror is hub-only)"
  exit 0
fi
for tool in jq python3 git shellcheck; do
  command -v "$tool" >/dev/null 2>&1 || { echo "test_repo_lint_prepush_load: FAIL ($tool is required)" >&2; exit 1; }
done
if ! command -v yq >/dev/null 2>&1 || ! yq --version 2>&1 | grep -q 'mikefarah/yq'; then
  echo "test_repo_lint_prepush_load: FAIL (mikefarah/yq is required)" >&2
  exit 1
fi

# shellcheck disable=SC2046
unset $(git rev-parse --local-env-vars) 2>/dev/null || true
for v in $(env | sed -n 's/^\(MERGEPATH_PREPUSH_[A-Z_]*\)=.*/\1/p'); do unset "$v"; done
unset GITHUB_OUTPUT 2>/dev/null || true
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=fixture GIT_AUTHOR_EMAIL=fixture@example.invalid
export GIT_COMMITTER_NAME=fixture GIT_COMMITTER_EMAIL=fixture@example.invalid

TMP=$(mktemp -d "${TMPDIR:-/tmp}/test_repo_lint_prepush_load.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  FAIL $1"; }

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
# Six live probe steps s1..s6 (s6 is a graph wrapper owning other/*, selected
# by the changed path) so every step runs and the order is set by timings.
FIX="$TMP/fix"
mkdir -p "$FIX/scripts/ci" "$FIX/.github/workflows" "$FIX/other"
cp "$REPO_ROOT/scripts/ci/repo-lint-scope.sh" "$FIX/scripts/ci/"
cp "$RUNNER" "$FIX/scripts/"
printf '#!/usr/bin/env bash\n# hub marker\n' > "$FIX/scripts/sync-to-downstream.sh"
cat > "$FIX/scripts/ci/repo-lint-dependencies.json" <<'JSON'
{"version": 1, "full_triggers": ["scripts/ci/repo-lint-dependencies.json"],
 "consumer_replay_triggers": [], "deep_triggers": [], "self_tests": [],
 "wrappers": {"check_s6": ["other/*"]}}
JSON
# A probe records how many probes are running when it starts, may rewrite the
# fake load at its start (LOAD_AT_START_<name>) or its end (LOAD_AT_END_<name>),
# and runs for SECS_<name> seconds (default 1). PEER_<name> names probes this
# one is meant to overlap: after creating its marker it waits (at most 5 s)
# until each peer's marker exists, so a sample never races a peer's start.
cat > "$FIX/scripts/ci/probe.sh" <<'SH'
#!/usr/bin/env bash
set -eu
n=$1
touch "$PROBE_DIR/active.$n"
v="PEER_$n"
for peer in ${!v:-}; do
  for _ in $(seq 1 50); do [ -e "$PROBE_DIR/active.$peer" ] && break; sleep 0.1; done
done
echo "$n $(find "$PROBE_DIR" -name 'active.*' | wc -l | tr -d ' ')" >> "$PROBE_DIR/samples"
v="LOAD_AT_START_$n"; [ -z "${!v:-}" ] || echo "${!v}" > "$FAKE_LOADFILE"
v="SECS_$n"; sleep "${!v:-1}"
v="LOAD_AT_END_$n"; [ -z "${!v:-}" ] || echo "${!v}" > "$FAKE_LOADFILE"
rm -f "$PROBE_DIR/active.$n"
SH
for c in s1 s2 s3 s4 s5 s6; do
  printf '#!/usr/bin/env bash\nset -eu\nbash "$(dirname "$0")/probe.sh" %s\n' "$c" > "$FIX/scripts/ci/check_$c"
done
chmod +x "$FIX/scripts/ci/"*
{
  cat <<'YAML'
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
YAML
  for c in s1 s2 s3 s4 s5 s6; do
    printf '      - name: check_%s\n        if: matrix.shard == 1\n        run: ./scripts/ci/check_%s\n' "$c" "$c"
  done
  cat <<'YAML'
  deep_safety:
    needs: scope
    if: needs.scope.outputs.deep == 'true'
    steps:
      - name: check_deep_unused
        run: echo unused
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
} > "$FIX/.github/workflows/repo_lint.yml"
printf 'input\n' > "$FIX/other/input.txt"
printf '.mergepath/\n' > "$FIX/.gitignore"
git -C "$FIX" init -q -b main
git -C "$FIX" add -A
git -C "$FIX" commit -q -m base
FIXREMOTE="$TMP/fix-remote.git"
git init -q --bare "$FIXREMOTE"
git -C "$FIX" remote add origin "$FIXREMOTE"
git -C "$FIX" push -q --no-verify origin main
git -C "$FIX" fetch -q origin
git -C "$FIX" remote set-head origin main >/dev/null

printf '#!/bin/sh\nexit 0\n' > "$TMP/python-ok"
chmod +x "$TMP/python-ok"
export MERGEPATH_PREPUSH_PYTHON="$TMP/python-ok"
export XDG_CACHE_HOME="$TMP/xdg"
export PROBE_DIR="$TMP/probe"
export FAKE_LOADFILE="$TMP/loadfile"
export FAKE_SYSCTL_COUNT="$TMP/sysctl-count"
# The fake host: 4 CPUs and a load read from FAKE_LOADFILE on every call, so
# a probe can change it while the run is in progress. Below 4.00 the load is
# under one per CPU (jobs_max); at or above it the runner drops to one.
FAKEBIN="$TMP/fakebin"
mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/sysctl" <<'SH'
#!/bin/sh
case "$2" in
  hw.ncpu) echo 4 ;;
  vm.loadavg) echo x >> "$FAKE_SYSCTL_COUNT"; echo "{ $(cat "$FAKE_LOADFILE") 0.00 0.00 }" ;;
  *) exit 1 ;;
esac
SH
chmod +x "$FAKEBIN/sysctl"
export PATH="$FAKEBIN:$PATH"

TIMINGS="$FIX/.mergepath/prepush-timings.tsv"
# Longest-first: s1 .. s6 in this order.
seed_order() {
  mkdir -p "$(dirname "$TIMINGS")"
  printf 'check_s%s\t%s\n' 1 60 2 50 3 40 4 30 5 20 6 10 > "$TIMINGS"
}
LOW=0.50; HIGH=9.00
# run_load RUNNER START_LOAD [VAR=value ...] -- [runner args]
run_load() {
  local r="$1" start="$2"; shift 2
  local envs=()
  while [ "$#" -gt 0 ] && [ "$1" != -- ]; do envs+=("$1"); shift; done
  [ "$#" -eq 0 ] || shift
  rm -rf "$PROBE_DIR" "$FAKE_SYSCTL_COUNT"; mkdir -p "$PROBE_DIR"; : > "$FAKE_SYSCTL_COUNT"
  echo "$start" > "$FAKE_LOADFILE"
  seed_order
  RC=0
  OUT=$(cd "$FIX" && printf 'other/input.txt\n' | env ${envs[@]+"${envs[@]}"} bash "$r" --paths-from - "$@" 2>&1) || RC=$?
}
seen() { awk -v n="$1" '$1 == n { print $2 }' "$PROBE_DIR/samples"; }   # probes running when $1 started
reads() { wc -l < "$FAKE_SYSCTL_COUNT" | tr -d ' '; }

# ── property 1: the concurrency falls and rises with the load ────────────
# Starts quiet (jobs=2): s1 (1 s) and s2 (3 s) overlap. s1 raises the load
# as it ends, so s3 starts alone (jobs=1). s3 (5 s) lowers the load as it
# starts, so s4 and s5 start beside it (jobs=2).
assert_falls_and_rises() {   # $1 runner
  local r="$1"
  run_load "$r" "$LOW" LOAD_AT_END_s1="$HIGH" SECS_s1=1 SECS_s2=3 PEER_s2=s1 LOAD_AT_START_s3="$LOW" SECS_s3=12 PEER_s4=s3 --
  expect "falls and rises: the run passes" "$RC" "0"
  expect_has "falls and rises: starts at jobs=2" "$OUT" "(jobs=2, nice=10, host load 0.50 on 4 CPUs)"
  expect_has "falls and rises: the run says the concurrency follows the load" "$OUT" "follows the host load between 1 and 2"
  expect "falls and rises: the first two checks overlap" "$(seen s2)" "2"
  expect_has "falls and rises: the fall is logged" "$OUT" "repo-lint pre-push: concurrency 2 -> 1 (host load 9.00 on 4 CPUs)"
  expect "falls and rises: a check started under load runs alone" "$(seen s3)" "1"
  expect_has "falls and rises: the rise is logged" "$OUT" "repo-lint pre-push: concurrency 1 -> 2 (host load 0.50 on 4 CPUs)"
  expect "falls and rises: the next check overlaps the long one again" "$(seen s4)" "2"
  expect "falls and rises: the concurrency never passes jobs_max" "$(awk '$2 > 2' "$PROBE_DIR/samples" | wc -l | tr -d ' ')" "0"
  expect "falls and rises: every check ran" "$(wc -l < "$PROBE_DIR/samples" | tr -d ' ')" "6"
  expect "falls and rises: exactly the two changes are logged" "$(printf '%s\n' "$OUT" | grep -c 'pre-push: concurrency [0-9]* -> ')" "2"
}

# ── property 2: a run that starts loaded speeds up when the load falls ───
assert_loaded_start_rises() {   # $1 runner
  local r="$1"
  run_load "$r" "$HIGH" LOAD_AT_START_s1="$LOW" SECS_s1=8 PEER_s2=s1 --
  expect "loaded start: the run passes" "$RC" "0"
  expect_has "loaded start: starts at jobs=1" "$OUT" "(jobs=1, nice=10, host load 9.00 on 4 CPUs)"
  expect_has "loaded start: the rise is logged" "$OUT" "repo-lint pre-push: concurrency 1 -> 2 (host load 0.50 on 4 CPUs)"
  expect "loaded start: a later check runs beside the first" "$(seen s2)" "2"
}

# ── property 3: a pinned concurrency is not re-sized ─────────────────────
assert_pinned_holds() {   # $1 runner
  local r="$1"
  # One job pinned by the environment on a quiet host, where a re-size would go to two.
  run_load "$r" "$LOW" MERGEPATH_PREPUSH_JOBS=1 SECS_s1=1 --
  expect "pinned by env: the run passes" "$RC" "0"
  expect "pinned by env: never more than one at a time" "$(awk '$2 > 1' "$PROBE_DIR/samples" | wc -l | tr -d ' ')" "0"
  expect_has "pinned by env: the output says so" "$OUT" "concurrency pinned to 1 by env MERGEPATH_PREPUSH_JOBS; it is not re-sized from the host load"
  expect_lacks "pinned by env: no concurrency change is logged" "$OUT" "pre-push: concurrency 1 ->"
  # Two jobs pinned by the flag while the load is high and never recovers.
  run_load "$r" "$HIGH" PEER_s2=s1 -- --jobs 2
  expect "pinned by flag: the run passes" "$RC" "0"
  expect "pinned by flag: stays at two under load" "$(seen s2)" "2"
  expect_has "pinned by flag: the output says so" "$OUT" "concurrency pinned to 2 by flag --jobs; it is not re-sized from the host load"
  expect_lacks "pinned by flag: no concurrency change is logged" "$OUT" "pre-push: concurrency 2 ->"
  expect_lacks "pinned by flag: no 'follows the host load' line" "$OUT" "follows the host load"
}

# ── property 4: a long wait does not read the load every second ──────────
# Loaded throughout: s1 runs for 12 s while the feeder waits for its slot.
# The fixed 5 s interval allows two extra reads there; reading every second
# would add twelve to the eight or so a run makes (the start, one per check,
# the end).
assert_reads_throttled() {   # $1 runner
  local r="$1" n
  run_load "$r" "$HIGH" SECS_s1=12 --
  expect "throttled: the run passes" "$RC" "0"
  n=$(reads)
  expect "throttled: a 12-second wait adds no per-second reads (got $n)" "$([ "$n" -le 12 ] && echo ok || echo "too many: $n")" "ok"
}

echo "Part 1: the concurrency falls and rises with the load"
assert_falls_and_rises "$RUNNER"

echo "Part 2: a run that starts loaded speeds up when the load falls"
assert_loaded_start_rises "$RUNNER"

echo "Part 3: a pinned concurrency is not re-sized"
assert_pinned_holds "$RUNNER"

echo "Part 4: the load is not read every second while waiting"
assert_reads_throttled "$RUNNER"

help_out=$(bash "$RUNNER" --help)
for want in 'at most every 5 seconds' 'Live load (#2842)' 'pin the concurrency'; do
  case "$help_out" in *"$want"*) ok "--help documents $want" ;; *) bad "--help omits $want" ;; esac
done

echo "Part 5: each property fails against a runner mutated to break it"
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
}
# The first reading is kept for the whole run (the pre-#2842 behaviour).
mutation_check assert_falls_and_rises pin-first-reading \
  '  [ -z "$JOBS_SRC" ] || return 0
  now=$(date +%s)' \
  '  return 0
  now=$(date +%s)'
mutation_check assert_loaded_start_rises pin-first-reading \
  '  [ -z "$JOBS_SRC" ] || return 0
  now=$(date +%s)' \
  '  return 0
  now=$(date +%s)'
# xargs may start no more than the concurrency the run started with.
mutation_check assert_loaded_start_rises xargs-capped-at-start \
  'xargs -P "$JOBS_CAP"' \
  'xargs -P "$JOBS"'
# A pinned concurrency is re-sized anyway.
mutation_check assert_pinned_holds pinned-resized \
  '  [ -z "$JOBS_SRC" ] || return 0
  now=$(date +%s)' \
  '  now=$(date +%s)'
# The load is read on every pass of the wait loop.
mutation_check assert_reads_throttled unthrottled \
  '$((now - SCHED_READ_AT)) -lt "$SCHED_REREAD_S"' \
  '1 -lt 0'
# A change of concurrency is not logged.
mutation_check assert_falls_and_rises silent-change \
  'echo "$PREFIX: concurrency $SCHED_CUR -> $n (host load $load on $CPU_N CPUs)" >&2' \
  ':'

echo ""
echo "test_repo_lint_prepush_load: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
