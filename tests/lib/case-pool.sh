# shellcheck shell=bash
# tests/lib/case-pool.sh — run a suite's independent cases concurrently (#2990).
#
# Sourced by a bash test suite that keeps the usual `PASS` / `FAIL` counters
# and `pass` / `fail` helpers. Instead of calling each case function at top
# level, the suite queues it:
#
#   case_pool_add test_something
#   case_pool_add test_with_args one two
#   case_pool_add --first test_long_poll_wait
#   ...
#   case_pool_wait          # before reading PASS / FAIL
#
# `case_pool_wait` runs the queued cases with up to MERGEPATH_TEST_JOBS of them
# at once, each in its own background subshell, then replays every case's
# stdout and stderr in queue order and adds its PASS / FAIL counts to the
# suite's. The log therefore reads exactly as a serial run would, case by case.
# `--first` only changes when a case STARTS: it is launched ahead of the
# unmarked ones, so a long case does not begin last and set the suite's wall
# time on its own. Its output is still replayed in queue order.
#
# Why a subshell per case is safe here: every case already builds its own
# fixture directory and runs the requester against it, so cases share nothing
# but read-only setup. A case that needs state from an earlier case is not a
# pool case; leave it as a plain call. Queued cases run at the wait, after any
# top-level code between the add and the wait, so a pool case must not read a
# top-level variable that is reassigned after its add.
#
# Fail-closed rules:
#   - A case that exits early (errexit, `exit`, a signal) writes no counts and
#     is reported as one FAIL with its exit status. It never reads as a pass.
#   - The counts file is written only after the case function returns, so a
#     case that dies halfway cannot report the passes it made before dying.
#   - errexit stays on inside each case: a background subshell is not part of
#     an `||` / `&&` list, so `set -e` is not suspended the way it would be
#     for `( case ) || rc=$?`.
#   - In the serial shape (below) a case runs in the suite's own shell, so an
#     early exit ends the suite and the cases after it do not run. An EXIT
#     trap held while the cases run reports that case as a FAIL, runs the
#     suite's own EXIT trap, and exits 1, so even `exit 0` cannot read as a
#     pass.
#
# Concurrency: MERGEPATH_TEST_JOBS (a positive integer) pins it; otherwise the
# online CPU count. MERGEPATH_TEST_JOBS=1 runs every case in this shell, in
# order, exactly as the plain calls did (no subshell), which is the shape to
# use when bisecting a case that only fails alongside others. Bash older than
# 4.3 has no `wait -n` and also runs serially.
#
# MERGEPATH_TEST_TIMINGS=1 prints the slowest pooled cases (wall seconds) to
# stderr after the replay, which is how to find the case that sets a suite's
# wall time before rebalancing it.

CASE_POOL_QUEUE=()
CASE_POOL_FIRST=()
CASE_POOL_SEQ=0
CASE_POOL_CURRENT=
CASE_POOL_SUITE_EXIT=

# EXIT trap for the serial shape: the running case left the suite shell.
case_pool_serial_exit() {
  local rc=$?
  echo "FAIL: case '$CASE_POOL_CURRENT' exited with status $rc before reporting its counts (case-pool, #2990)" >&2
  eval "$CASE_POOL_SUITE_EXIT"
  exit 1
}

case_pool_jobs() {
  local n="${MERGEPATH_TEST_JOBS:-}"
  if [ -n "$n" ]; then
    case "$n" in
      *[!0-9]*|0*) echo "case-pool: MERGEPATH_TEST_JOBS must be a positive integer (got '$n')" >&2; return 1 ;;
    esac
    printf '%s\n' "$n"
    return 0
  fi
  n=$(getconf _NPROCESSORS_ONLN 2>/dev/null) || n=$(nproc 2>/dev/null) || n=$(sysctl -n hw.ncpu 2>/dev/null) || n=1
  case "$n" in ''|*[!0-9]*|0) n=1 ;; esac
  printf '%s\n' "$n"
}

# case_pool_add [--first] <function> [args...]: queue one case. The arguments
# are kept word for word (each one is shell-quoted into the queue entry).
case_pool_add() {
  local first=0
  if [ "${1:-}" = --first ]; then first=1; shift; fi
  [ "$#" -ge 1 ] || { echo "case-pool: case_pool_add needs a function name" >&2; return 1; }
  declare -F "$1" >/dev/null || { echo "case-pool: '$1' is not a defined function" >&2; return 1; }
  local entry
  printf -v entry '%q ' "$@"
  CASE_POOL_QUEUE+=("${entry% }")
  CASE_POOL_FIRST+=("$first")
}

case_pool_wait() {
  local jobs count=${#CASE_POOL_QUEUE[@]}
  [ "$count" -gt 0 ] || return 0
  jobs=$(case_pool_jobs) || return 1

  if [ "$jobs" -le 1 ] || [ "${BASH_VERSINFO[0]}" -lt 4 ] \
     || { [ "${BASH_VERSINFO[0]}" -eq 4 ] && [ "${BASH_VERSINFO[1]}" -lt 3 ]; }; then
    local entry saved
    # A second `trap ... EXIT` replaces the suite's own, so keep its command
    # (`trap -p` prints it shell-quoted) to run from ours and to restore.
    saved=$(trap -p EXIT)
    CASE_POOL_SUITE_EXIT=
    if [ -n "$saved" ]; then
      eval "set -- ${saved#trap -- }"
      CASE_POOL_SUITE_EXIT=$1
    fi
    trap case_pool_serial_exit EXIT
    for entry in "${CASE_POOL_QUEUE[@]}"; do
      CASE_POOL_CURRENT=$entry
      eval "$entry"
    done
    if [ -n "$saved" ]; then eval "$saved"; else trap - EXIT; fi
    CASE_POOL_QUEUE=()
    CASE_POOL_FIRST=()
    return 0
  fi

  CASE_POOL_SEQ=$((CASE_POOL_SEQ + 1))
  local pool_dir
  pool_dir=$(mktemp -d "${TMPDIR:-/tmp}/case-pool.XXXXXX") || { echo "case-pool: cannot create a scratch directory" >&2; return 1; }
  local -a pids=() order=()
  local i running=0
  for ((i = 0; i < count; i++)); do
    if [ "${CASE_POOL_FIRST[i]}" = 1 ]; then order+=("$i"); fi
  done
  for ((i = 0; i < count; i++)); do
    if [ "${CASE_POOL_FIRST[i]}" != 1 ]; then order+=("$i"); fi
  done
  for i in "${order[@]}"; do
    if [ "$running" -ge "$jobs" ]; then
      # Any one finished case frees a slot; its status is read again below.
      wait -n 2>/dev/null || :
      running=$((running - 1))
    fi
    # shellcheck disable=SC2030,SC2031 # each case counts in its own subshell;
    # the totals come back through its counts file, read below.
    (
      PASS=0
      FAIL=0
      # A suite that keeps fixtures under $WORKDIR/<name> gets one WORKDIR per
      # case, so two cases that compute the same fixture name never share it.
      if [ -n "${WORKDIR:-}" ]; then
        WORKDIR="$WORKDIR/case-pool-$CASE_POOL_SEQ-$i"
        mkdir -p "$WORKDIR"
      fi
      SECONDS=0
      eval "${CASE_POOL_QUEUE[$i]}"
      printf '%s %s\n' "$PASS" "$FAIL" >"$pool_dir/$i.counts"
      printf '%s\n' "$SECONDS" >"$pool_dir/$i.secs"
    ) >"$pool_dir/$i.out" 2>"$pool_dir/$i.err" </dev/null &
    pids[i]=$!
    running=$((running + 1))
  done

  local rc p f
  for ((i = 0; i < count; i++)); do
    rc=0
    wait "${pids[i]}" || rc=$?
    cat "$pool_dir/$i.out"
    cat "$pool_dir/$i.err" >&2
    # shellcheck disable=SC2031 # these are the suite's own counters
    if [ "$rc" -eq 0 ] && read -r p f <"$pool_dir/$i.counts" 2>/dev/null \
       && [[ "$p" =~ ^[0-9]+$ ]] && [[ "$f" =~ ^[0-9]+$ ]]; then
      PASS=$((PASS + p))
      FAIL=$((FAIL + f))
    else
      echo "FAIL: case '${CASE_POOL_QUEUE[$i]}' exited with status $rc before reporting its counts (case-pool, #2990)" >&2
      FAIL=$((FAIL + 1))
    fi
  done
  if [ -n "${MERGEPATH_TEST_TIMINGS:-}" ]; then
    for ((i = 0; i < count; i++)); do
      [ -s "$pool_dir/$i.secs" ] && printf '%6ss  %s\n' "$(cat "$pool_dir/$i.secs")" "${CASE_POOL_QUEUE[$i]}"
    done | sort -rn | head -15 | sed 's/^/case-pool timing: /' >&2
  fi
  rm -rf "$pool_dir"
  CASE_POOL_QUEUE=()
  CASE_POOL_FIRST=()
}
