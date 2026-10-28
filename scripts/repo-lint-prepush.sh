#!/usr/bin/env bash
# repo-lint-prepush.sh — run, before a push, the repo-lint checks CI would
# select for it (#2221). Hub-only local tooling: it is not in
# .mergepath-sync.yml, so no consumer receives it.
#
# The required `lint` context stays authoritative. This only moves a failure
# that CI would report about ten minutes after the push to before the push,
# so the fix does not cost a CI cycle and a fresh review round.
#
# Selection is not re-implemented here. Two sources decide it:
#   - scripts/ci/repo-lint-scope.sh, the classifier the CI `scope` job runs,
#     receives the changed paths and emits the same deep/full/checks/
#     consumer_replay/self_tests bits CI computes;
#   - .github/workflows/repo_lint.yml is read (via yq) for the step list and
#     the exact `run:` bodies, so a step added, moved or re-pinned in the
#     workflow is picked up without editing this file.
# tests/test_repo_lint_prepush.sh proves the result equals what CI runs for
# the same change, by evaluating every job and step `if:` expression in the
# workflow independently and comparing step sets.
#
# What runs. Every `lint_fast` check step (all four shards' pins) falls in
# one of the first three lanes below, by its wrapper; `deep` is the rest:
#   live       - steps whose wrapper is NOT in the dependency graph's
#                `wrappers` map, and inline steps: the cheap repository
#                assertions (about 30 s of CI time in total). Always run.
#   selected   - graph-declared wrappers the classifier selected (all of them
#                when it selects the complete surface for a reason other than
#                an undeclared path). Always run.
#   fallback   - graph-declared wrappers CI runs only because a changed path
#                is undeclared (#2580). CI's classifier fails closed to the
#                complete surface for a path no wrapper, trigger or full
#                trigger declares; the hook re-classifies without those paths,
#                names them in one loud line, and leaves the expansion to
#                CI's `lint`. Run with MERGEPATH_PREPUSH_LIVE=all.
#   unselected - graph-declared wrappers the classifier did not select. The
#                graph is CI's own record of which paths each of these
#                expensive wrappers depends on, and the hub classifier fails
#                closed to the complete surface on any undeclared CI path, so
#                their suites cannot change result. CI's fast lane still runs
#                them; run them here too with MERGEPATH_PREPUSH_LIVE=all.
#                Residual: a wrapper whose live assertion scans the whole tree
#                (check_git_identity_hygiene's identity-write scan,
#                check_mktemp_portability) can still fail in CI on a path
#                outside its declared inputs.
#   deep       - the deep-lane steps the scope bits select (without the
#                undeclared-path expansion, which is the `deep_fallback` lane
#                and runs only with MERGEPATH_PREPUSH_LIVE=all plus DEEP): the enrolled
#                `--self-test` suites of `deep_self_tests`, the consumer-smoke
#                and residue legs of `deep_safety`, and the complete consumer
#                replay. Only with MERGEPATH_PREPUSH_DEEP=1 (or --deep);
#                otherwise the selection is printed and CI runs them.
# Deliberately not run locally: non-check setup steps, including the
# workflow's ref-fetch setup and its prelude (checkout,
# chmod, pip and yq provisioning; this script finds python3/yq itself), the
# `check_git_identity_hygiene --snapshot` / `--verify` per-runner bookends,
# and the deep jobs' closing `check_git_identity_hygiene` (the plain call
# already runs once in the live lane).
#
# Usage:
#   repo-lint-prepush.sh --hook <remote> [<url>]   (stdin: git pre-push lines)
#   repo-lint-prepush.sh [--base <ref>]            (HEAD vs merge-base)
#   repo-lint-prepush.sh --paths-from <file|->     (explicit changed paths)
# Options:
#   --plan          print the scope and the selected steps; run nothing
#   --deep          also run the selected deep-lane steps
#   --all-live      run CI's whole fast lane, unselected wrappers included
#   --jobs N        concurrency cap (default MERGEPATH_PREPUSH_JOBS, else 2
#                   while the one-minute load average is below the CPU
#                   count and 1 once it is not)
#   --event NAME    classifier event (default pull_request; a push to the
#                   remote default branch is classified as `push`, like CI)
#   --head-ref REF  branch name handed to the classifier (mergepath-sync/*
#                   selects the complete surface, as in CI)
# Environment:
#   MERGEPATH_PREPUSH_SKIP=1    bypass entirely (as does git push --no-verify)
#   MERGEPATH_PREPUSH_DEEP=1    run the selected deep-lane steps too
#   MERGEPATH_PREPUSH_LIVE=all  run the unselected and undeclared-path fallback
#                               graph wrappers too (CI's whole fast lane, and
#                               with DEEP=1 CI's exact deep selection)
#   MERGEPATH_PREPUSH_JOBS=N    concurrency cap; default 2 below one CPU's
#                               worth of load per core, 1 at or above it
#   MERGEPATH_PREPUSH_NICE=N    nice level for every check, default 10
#   MERGEPATH_PREPUSH_PYTHON=P  interpreter to expose as python3 (needs PyYAML,
#                               and markdown-it-py for the deep lane)
#   MERGEPATH_PREPUSH_KEEP_LOGS=1  keep the per-check logs of a passing run
#   MERGEPATH_PREPUSH_LOCK_WAIT=S  wait up to S seconds for another hook run
#                               on this machine to finish (default 3600)
#   MERGEPATH_PREPUSH_LOCK_TOOL=T  take the lock with flock(1) or python3's
#                               fcntl (default: flock(1) if present, else python3)
# Hook checks run in tool-owned detached worktrees of each pushed tip, so
# working-tree modifications and untracked files cannot affect their result.
# Python package metadata must equal the committed workflow pins.
# Hook runs on one machine take turns (#2581): a run holds an exclusive
# flock(2) on ${XDG_CACHE_HOME:-$HOME/.cache}/mergepath/prepush.lock (through
# flock(1), or python3's fcntl where that is absent) from before its first
# snapshot until its last check, a second push waits for it, naming the
# holder's branch, pid, start time and progress every 30 s, and gives up
# after the bound above; a snapshot left by a killed run is retired under
# that lock. A host with neither tool fails closed (exit 2).
# Exit: 0 pass or skipped, 1 a selected check failed, 2 usage or environment
# (including missing or mismatched CI packages).
#
# Per-repository policy (#2840): .github/prepush.yml, read from the tree the
# run checks (the pushed commit's snapshot in a hook run, the checkout in a
# manual run; never uncommitted edits during a push). Each key resolves as
# --set KEY=VALUE (repeatable) > environment > the file > built-in default,
# and the `policy` line names every effective value and its source.
#   key                     environment                               default
#   mode                    MERGEPATH_PREPUSH_MODE                    full
#                           (off: run nothing; selected: only the selected
#                           wrappers, no live assertions; full: as above)
#   full_suite              MERGEPATH_PREPUSH_FULL_SUITE              run
#                           (run | defer; validated, consumed by #2841)
#   max_minutes             MERGEPATH_PREPUSH_MAX_MINUTES             0
#                           (0 = no budget; validated, consumed by #2841)
#   deep                    MERGEPATH_PREPUSH_DEEP (or --deep)        false
#   nice                    MERGEPATH_PREPUSH_NICE                    10
#   jobs_max                MERGEPATH_PREPUSH_JOBS_MAX                2
#   load_per_cpu_threshold  MERGEPATH_PREPUSH_LOAD_PER_CPU_THRESHOLD  1
#                           (the default concurrency is jobs_max while the
#                           load per CPU is below the threshold, else 1;
#                           MERGEPATH_PREPUSH_JOBS / --jobs still pin it)
# A missing file is the defaults. A file that is not one YAML mapping of
# known keys with valid values fails the run closed (exit 2), whatever the
# environment overrides.

set -euo pipefail

PREFIX='repo-lint pre-push'
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"

die() { echo "$PREFIX: $*" >&2; exit 2; }

# ── internal worker: run one prepared step (invoked through xargs -P) ──
if [ "${1:-}" = "--exec-step" ]; then
  run_dir="$2"; id="$3"
  name=$(cat "$run_dir/steps/$id.name")
  start=$(date +%s)
  rc=0
  (
    # Each check starts from the environment a CI job gives it (#2575),
    # whatever path invoked this worker. Git exports its hook-local
    # repository variables to a pre-push hook (GIT_DIR=<primary>/.git/
    # worktrees/<name> from a linked worktree); a fixture `git init` or
    # `git config` under them writes into the real repository instead, the
    # #777 identity leak and a shared `core.bare = true` (#2578). The literal
    # names cover a git that cannot list them.
    # shellcheck disable=SC2046
    unset $(git rev-parse --local-env-vars 2>/dev/null) 2>/dev/null || true
    unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_PREFIX GIT_COMMON_DIR \
      GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_IMPLICIT_WORK_TREE \
      GIT_CONFIG GIT_CONFIG_PARAMETERS GIT_CONFIG_COUNT 2>/dev/null || true
    cd "$(cat "$run_dir/root")"
    if [ -s "$run_dir/steps/$id.env" ]; then
      while IFS= read -r kv; do
        [ -n "$kv" ] && export "${kv?}"
      done < "$run_dir/steps/$id.env"
    fi
    exec nice -n "$(cat "$run_dir/nice")" bash --noprofile --norc -e "$run_dir/steps/$id.sh"
  ) < /dev/null > "$run_dir/logs/$id.log" 2>&1 || rc=$?
  secs=$(( $(date +%s) - start ))
  printf '%s\t%s\t%s\n' "$rc" "$secs" "$name" > "$run_dir/results/$id"
  if [ "$rc" -eq 0 ]; then
    printf '  PASS  %-46s %4ss\n' "$name" "$secs"
  else
    printf '  FAIL  %-46s %4ss  exit %s, log %s\n' "$name" "$secs" "$rc" "$run_dir/logs/$id.log"
  fi
  exit 0
fi

if [ "${MERGEPATH_PREPUSH_SKIP:-0}" = "1" ]; then
  echo "$PREFIX: skipped (MERGEPATH_PREPUSH_SKIP=1); CI lint remains authoritative"
  exit 0
fi

# ── one hook run per machine, parallelism sized to the load (#2581) ──
# Six pre-push hooks running at once drove the host load average past 500
# and stretched a 21-check run from 27 minutes to over an hour, so hook runs
# on one machine take turns. The lock is an exclusive flock(2) on
# ${XDG_CACHE_HOME:-$HOME/.cache}/mergepath/prepush.lock, held on fd 9 for
# the run's lifetime and dropped by the kernel with the holder, so nothing is
# ever reaped by deleting a file (a lock reaped by deletion has a window in
# which two waiters read the same dead pid; a kernel lock has none). It is
# taken with flock(1) where that exists and otherwise with python3's fcntl on
# the same inherited fd (macOS ships no flock(1); every host that can run the
# checks has a python3, since the run requires one). Where neither exists the
# hook fails closed as an environment error, like a missing ShellCheck. The
# lock file carries the holder's branch, pid, start time and progress,
# refreshed per completed check, so a waiter's message is specific; the file
# is rewritten in place and never replaced or removed, because the lock lives
# on its inode. A waiter polls every second, speaks every 30 s and gives up
# after MERGEPATH_PREPUSH_LOCK_WAIT seconds (default 3600) rather than run
# concurrently. Manual runs (--paths-from, HEAD vs merge-base, --plan) do not
# lock: only the hook runs checks on a shared machine unattended.
LOCK_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/mergepath"
LOCK_FILE="$LOCK_DIR/prepush.lock"
LOCK_HELD=0       # 1 while this process holds the lock
LOCK_FLOCK=''     # flock(1) path, when present
LOCK_PY=''        # python3 with fcntl, when flock(1) is absent
LOCK_RECORD=''    # the record this run refreshes: the holder's, or via --lock-record
LOCK_START=''

lock_field() {   # $1 field; empty when the record is absent (first run on a machine)
  [ -f "$LOCK_FILE" ] || return 0
  sed -n "/^$1=/{s/^$1=//p;q;}" "$LOCK_FILE" 2>/dev/null || true
}

# One write, in place: the lock lives on this inode, so the file is never
# replaced, only rewritten.
lock_write_record() {   # $1 branch, $2 pid, $3 started, $4 progress
  printf 'branch=%s\npid=%s\nstarted=%s\nprogress=%s\n' "$1" "$2" "$3" "$4" > "$LOCK_FILE" 2>/dev/null || true
}

# A recorded holder is alive when its pid exists and still runs this tool;
# a pid the kernel reused for something else is as gone as a dead one.
holder_alive() {   # $1 pid
  local cmd
  case "$1" in ''|*[!0-9]*) return 1 ;; esac
  kill -0 "$1" 2>/dev/null || return 1
  cmd=$(ps -o command= -p "$1" 2>/dev/null) || return 0
  case "$cmd" in *repo-lint-prepush*) return 0 ;; *) return 1 ;; esac
}

holder_description() {   # "the run of <branch> (pid N, started HH:MM UTC, k of n checks)"
  local branch pid started progress
  branch=$(lock_field branch); pid=$(lock_field pid)
  started=$(lock_field started); progress=$(lock_field progress)
  case "$progress" in ''|preparing) progress=preparing ;; *) progress="$progress checks" ;; esac
  printf 'the run of %s (pid %s, started %s, %s)' "${branch:-?}" "${pid:-?}" "${started:-?}" "$progress"
}

# Sets LOCK_FLOCK or LOCK_PY, or dies: flock(1) first, then a python3 whose
# fcntl answers the probe (a stub that merely exits 0 does not).
# MERGEPATH_PREPUSH_LOCK_TOOL=python3 skips flock(1) so the path every macOS
# machine takes can be exercised on a Linux runner; =flock insists on it.
lock_tooling() {
  local cand d tool="${MERGEPATH_PREPUSH_LOCK_TOOL:-}"
  # A git client may run hooks with a minimal PATH: look where the run's own
  # tool discovery looks (Homebrew), before deciding nothing is available.
  for d in /opt/homebrew/bin /usr/local/bin; do
    case ":$PATH:" in *":$d:"*) ;; *) [ -d "$d" ] && PATH="$PATH:$d" ;; esac
  done
  export PATH
  case "$tool" in ''|flock|python3) ;; *) die "MERGEPATH_PREPUSH_LOCK_TOOL must be flock or python3 (got '$tool')" ;; esac
  if [ "$tool" != python3 ] && LOCK_FLOCK=$(command -v flock 2>/dev/null) && [ -n "$LOCK_FLOCK" ]; then
    return 0
  fi
  LOCK_FLOCK=''
  [ "$tool" != flock ] || die "MERGEPATH_PREPUSH_LOCK_TOOL=flock, but flock(1) is not on PATH"
  # Any interpreter with fcntl will do for the lock: the explicit one first,
  # then the candidates the run itself accepts, in its order.
  for cand in "${MERGEPATH_PREPUSH_PYTHON:-}" python3 python3.14 python3.13 python3.12 python3.11 /usr/bin/python3; do
    [ -n "$cand" ] || continue
    if command -v "$cand" >/dev/null 2>&1 \
       && [ "$("$cand" -I -c 'import fcntl; print("fcntl-ok")' 2>/dev/null)" = fcntl-ok ]; then
      LOCK_PY=$(command -v "$cand")
      return 0
    fi
  done
  die "the machine-wide hook lock needs flock(1) or a python3 with fcntl; neither is available"
}

lock_try() {   # non-blocking exclusive flock(2) on fd 9; the lock stays with the fd
  if [ -n "$LOCK_FLOCK" ]; then
    "$LOCK_FLOCK" -n 9
  else
    "$LOCK_PY" -I -c 'import fcntl, sys
try:
    fcntl.flock(9, fcntl.LOCK_EX | fcntl.LOCK_NB)
except OSError:
    sys.exit(1)'
  fi
}

prepush_lock_acquire() {   # $1 = the pushed branch this run checks
  local bound="${MERGEPATH_PREPUSH_LOCK_WAIT:-3600}" t0 now last pid
  case "$bound" in ''|*[!0-9]*) die "MERGEPATH_PREPUSH_LOCK_WAIT must be a whole number of seconds (got '$bound')" ;; esac
  mkdir -p "$LOCK_DIR" 2>/dev/null || die "cannot create $LOCK_DIR for the machine-wide hook lock"
  lock_tooling
  exec 9>>"$LOCK_FILE" || die "cannot open $LOCK_FILE"
  t0=$(date +%s); last=$((t0 - 30))
  until lock_try; do
    now=$(date +%s)
    if [ $((now - t0)) -ge "$bound" ]; then
      echo "$PREFIX: gave up after $((now - t0)) s waiting for $(holder_description); MERGEPATH_PREPUSH_LOCK_WAIT=<seconds> waits longer, MERGEPATH_PREPUSH_SKIP=1 or --no-verify bypasses" >&2
      exit 2
    fi
    if [ $((now - last)) -ge 30 ]; then
      echo "$PREFIX: waiting for $(holder_description)"
      last=$now
    fi
    sleep 1
  done
  # Held. A clean release leaves an empty record, so a record naming a dead
  # holder here means that run was killed and the kernel freed its lock.
  LOCK_HELD=1
  pid=$(lock_field pid)
  if [ -n "$pid" ] && [ "$pid" != "$$" ] && ! holder_alive "$pid"; then
    echo "$PREFIX: reaping the lock record of pid $pid ($(lock_field branch)), which is no longer running"
  fi
  LOCK_START="$(date -u +%H:%M) UTC"
  LOCK_RECORD="$LOCK_FILE"
  lock_write_record "$1" "$$" "$LOCK_START" preparing
}

# Invoked indirectly by the hook's EXIT trap.
# shellcheck disable=SC2329
prepush_lock_release() {
  [ "$LOCK_HELD" -eq 1 ] || return 0
  : > "$LOCK_FILE" 2>/dev/null || true
  exec 9>&-
  LOCK_HELD=0
}

prepush_lock_progress() {   # $1 completed, $2 total: refresh the record's progress line in place
  local rec
  [ -n "$LOCK_RECORD" ] && [ -f "$LOCK_RECORD" ] || return 0
  rec=$(grep -v '^progress=' "$LOCK_RECORD" 2>/dev/null || true)
  printf '%s\nprogress=%s of %s\n' "$rec" "$1" "$2" > "$LOCK_RECORD" 2>/dev/null || true
}

# Host load and CPU count, best effort (#2575): the one-minute load average
# and the online CPUs, or `unknown` / `?`. sysctl is asked first, so a test
# can stand in for the host; /proc, getconf and nproc answer where it is not.
host_load() {
  local l=''
  l=$({ sysctl -n vm.loadavg 2>/dev/null || true; } | awk '{ print $2 }')
  [ -n "$l" ] || l=$(cut -d' ' -f1 /proc/loadavg 2>/dev/null || true)
  case "$l" in ''|*[!0-9.]*|*.*.*|.) l=unknown ;; esac
  printf '%s' "$l"
}
host_cpus() {
  local n=''
  n=$(sysctl -n hw.ncpu 2>/dev/null) || n=$(getconf _NPROCESSORS_ONLN 2>/dev/null) || n=$(nproc 2>/dev/null) || n=''
  case "$n" in ''|*[!0-9]*) n='?' ;; esac
  printf '%s' "$n"
}

# The default concurrency follows the machine: two checks at once while the
# one-minute load average is below the CPU count, one once it is not. Either
# reading unavailable keeps the historical default of 2. Sets DEFAULT_JOBS,
# LOAD_1 and CPU_N (printed on the `running` line).
LOAD_1=''
CPU_N=''
DEFAULT_JOBS=2
prepush_default_jobs() {   # $1 jobs_max, $2 load_per_cpu_threshold (policy; 2 and 1 by default)
  local jmax="${1:-2}" thr="${2:-1}"
  LOAD_1=$(host_load)
  CPU_N=$(host_cpus)
  if [ "$LOAD_1" != unknown ] && [ "$CPU_N" != '?' ] \
     && awk -v l="$LOAD_1" -v c="$CPU_N" -v t="$thr" 'BEGIN { exit !(l + 0 >= (c + 0) * (t + 0)) }'; then
    DEFAULT_JOBS=1
  else
    DEFAULT_JOBS=$jmax
  fi
}

# Snapshot hygiene. A snapshot is positively identified before anything is
# removed: this tool creates it as `mktemp -d prepush-<12 hex of the tip>.XXXXXX`
# and checks it out detached at a commit that prefix names, so a worktree
# under the snapshots directory that is a branch checkout, carries another
# name (prepush-debug), or sits at some other commit is never touched. Under
# the lock no run of this version is live, so an owned snapshot is left only
# by a killed run; a run of an older version, which took no lock, could
# still be working in one, so a `--committed-snapshot` process whose working
# directory is the snapshot protects it, and an inspection that fails, or a
# live process whose working directory cannot be read, counts as in use.
owned_snapshot() {   # $1 worktree path, $2 its HEAD sha, $3 detached (1/0)
  local name sha12
  name=$(basename "$1")
  case "$name" in prepush-????????????.??????) ;; *) return 1 ;; esac
  sha12=${name#prepush-}; sha12=${sha12%.*}
  case "$sha12" in *[!0-9a-f]*) return 1 ;; esac
  [ "$3" = 1 ] || return 1
  case "$2" in "$sha12"*) return 0 ;; *) return 1 ;; esac
}

# Prints the pids of `--committed-snapshot` runs. Status 1: none. Status 2:
# that cannot be established (no pgrep, or pgrep failing).
snapshot_runs() {
  local out rc=0
  command -v pgrep >/dev/null 2>&1 || return 2
  out=$(pgrep -f -- '[-]-committed-snapshot' 2>/dev/null) || rc=$?
  case "$rc" in
    0) printf '%s\n' "$out"; return 0 ;;
    1) return 1 ;;
    *) return 2 ;;
  esac
}

process_cwd() {   # $1 pid; prints its working directory, status 1 when it cannot be read
  local d=''
  if [ -d /proc/self ]; then
    d=$(readlink "/proc/$1/cwd" 2>/dev/null) || d=''
  elif command -v lsof >/dev/null 2>&1; then
    d=$({ lsof -a -p "$1" -d cwd -Fn 2>/dev/null || true; } | sed -n 's/^n//p;' | head -n 1)
  fi
  [ -n "$d" ] || return 1
  printf '%s\n' "$d"
}

snapshot_in_use() {   # $1 snapshot path: 0 = in use, or that cannot be established; 1 = positively free
  local real pids rc=0 pid cwd
  real=$(cd "$1" 2>/dev/null && pwd -P) || return 1
  pids=$(snapshot_runs) || rc=$?
  [ "$rc" -ne 2 ] || return 0
  [ "$rc" -eq 0 ] || return 1
  for pid in $pids; do
    [ "$pid" != "$$" ] || continue
    if ! cwd=$(process_cwd "$pid"); then
      kill -0 "$pid" 2>/dev/null || continue
      return 0
    fi
    case "$cwd" in "$real"|"$real"/*) return 0 ;; esac
  done
  return 1
}

retire_stale_snapshots() {   # $1 = the snapshots directory; called under the lock
  local wt head detached prunable
  while IFS=$'\t' read -r wt head detached prunable; do
    case "$wt" in "$1"/prepush-*) ;; *) continue ;; esac
    if ! owned_snapshot "$wt" "$head" "$detached"; then
      echo "$PREFIX: leaving $wt: not a snapshot this tool made (a detached prepush-<sha>.XXXXXX checkout at that commit)"
      continue
    fi
    if [ "$prunable" = 1 ]; then
      # Its directory is gone. `git worktree prune` would act on every
      # registration in the repository, not this one, so it is left alone.
      echo "$PREFIX: leaving the registration of missing snapshot $wt (its directory is gone; git worktree prune clears it)"
      continue
    fi
    if snapshot_in_use "$wt"; then
      echo "$PREFIX: leaving snapshot $wt: a hook run is still working in it, or that cannot be established"
      continue
    fi
    if git worktree remove --force "$wt" 2>/dev/null; then
      echo "$PREFIX: retired stale snapshot $wt (left by an interrupted run)"
    else
      echo "$PREFIX: could not retire stale snapshot $wt" >&2
    fi
  done < <(git worktree list --porcelain | awk '
    /^worktree / { if (p != "") print p "\t" h "\t" d "\t" x; p = substr($0, 10); h = ""; d = 0; x = 0; next }
    /^HEAD / { h = $2; next }
    /^detached$/ { d = 1; next }
    /^prunable/ { x = 1; next }
    END { if (p != "") print p "\t" h "\t" d "\t" x }')
}

# ── per-repository policy (#2840) ──
# One table drives the file reader, the environment and flag tiers, the
# validation and the `policy` line, so a key added for a later slice (#2841's
# full-suite deferral and budget, #2842's live load policy) is one row here
# plus the code that consumes it. Rows: key|environment variable|default.
#
# Location: .github/prepush.yml, a file of its own, beside the other per-repo
# policy (review-policy.yml) but not inside it: review-policy.yml is merged
# into every consumer by the propagation engine and read by the review
# tooling, while this hook is hub-only local tooling; and a file of its own
# lets a consumer adopt the hook (the epic's fleet slice) without touching
# review configuration.
#
# Which copy: the one in the tree this run checks, which in a hook run is the
# pushed commit's own snapshot (the cwd here), the same tree the workflow,
# classifier and graph are read from. Never the working tree during a push:
# an uncommitted edit cannot change the result, as for every other input.
# Not the remote default branch's copy either: the hook never fetches, so
# that copy is whatever stale ref the clone holds, there is none when the
# merge base is missing, and a change to the policy would only take effect
# a merge later, so the PR that changes it could not exercise it. The
# policy can only lower local cost; it never touches CI's `lint`, and the
# environment already overrides any of it, so reading the pushed copy gives
# a branch no bypass it lacks.
PREPUSH_POLICY_FILE=.github/prepush.yml
PREPUSH_POLICY_TABLE='mode|MERGEPATH_PREPUSH_MODE|full
full_suite|MERGEPATH_PREPUSH_FULL_SUITE|run
max_minutes|MERGEPATH_PREPUSH_MAX_MINUTES|0
deep|MERGEPATH_PREPUSH_DEEP|false
nice|MERGEPATH_PREPUSH_NICE|10
jobs_max|MERGEPATH_PREPUSH_JOBS_MAX|2
load_per_cpu_threshold|MERGEPATH_PREPUSH_LOAD_PER_CPU_THRESHOLD|1'
POLICY_CLI=''   # --set KEY=VALUE pairs, one per line

policy_keys() { printf '%s\n' "$PREPUSH_POLICY_TABLE" | cut -d'|' -f1; }
policy_env_name() { printf '%s\n' "$PREPUSH_POLICY_TABLE" | awk -F'|' -v k="$1" '$1 == k { print $2 }'; }
policy_default() { printf '%s\n' "$PREPUSH_POLICY_TABLE" | awk -F'|' -v k="$1" '$1 == k { print $3 }'; }

# What a valid value of each key looks like, for the refusal message.
policy_expect() {
  case "$1" in
    mode) echo 'one of off, selected, full' ;;
    full_suite) echo 'one of run, defer' ;;
    deep) echo 'true or false (1 or 0)' ;;
    max_minutes) echo 'a whole number of minutes, 0 for no budget' ;;
    nice) echo 'a non-negative integer' ;;
    jobs_max) echo 'a positive integer' ;;
    load_per_cpu_threshold) echo 'a positive decimal number, such as 1 or 1.5' ;;
  esac
}

# Prints the canonical form of $2 for key $1; status 1 when it is invalid.
# Every tier (flag, environment, file) goes through this one check.
policy_normalize() {
  local v="$2"
  case "$1" in
    mode) case "$v" in off|selected|full) printf '%s' "$v" ;; *) return 1 ;; esac ;;
    full_suite) case "$v" in run|defer) printf '%s' "$v" ;; *) return 1 ;; esac ;;
    deep) case "$v" in true|1) printf true ;; false|0) printf false ;; *) return 1 ;; esac ;;
    max_minutes|nice|jobs_max)
      case "$v" in ''|*[!0-9]*) return 1 ;; esac
      [ "${#v}" -le 9 ] || return 1
      v=$((10#$v))
      [ "$1" != jobs_max ] || [ "$v" -gt 0 ] || return 1
      printf '%s' "$v" ;;
    load_per_cpu_threshold)
      [[ "$v" =~ ^[0-9]{1,6}(\.[0-9]{1,6})?$ ]] || return 1
      awk -v t="$v" 'BEGIN { exit !(t + 0 > 0) }' || return 1
      printf '%s' "$v" ;;
    *) return 1 ;;
  esac
}

policy_set() {   # $1 key, $2 value, $3 source
  printf -v "POLICY_$1" '%s' "$2"
  printf -v "POLICY_SRC_$1" '%s' "$3"
}
# The effective value and its source, for the rest of the runner.
policy_value() { local n="POLICY_$1"; printf '%s' "${!n-}"; }
policy_source() { local n="POLICY_SRC_$1"; printf '%s' "${!n-}"; }

policy_refuse() {   # the file is invalid: fail closed, never fall back to defaults or to off
  die "invalid $PREPUSH_POLICY_FILE: $*. Fix the file (see docs/agents/testing-requirements.md § Pre-push hook); a broken policy blocks the push rather than run less than it says. Bypass only in an emergency: MERGEPATH_PREPUSH_SKIP=1 or git push --no-verify"
}

# Reads $PREPUSH_POLICY_FILE (relative to the cwd) into POLICY_FILE_<key>;
# POLICY_FILE_STATE is absent or present. Only absence means the defaults.
policy_read_file() {
  local f="$PREPUSH_POLICY_FILE" json err tag keys k t raw norm
  POLICY_FILE_STATE=absent
  if [ ! -e "$f" ] && [ ! -L "$f" ]; then
    return 0
  fi
  { [ -f "$f" ] && [ -r "$f" ]; } || policy_refuse "not a readable regular file"
  if ! json=$(yq -o=json -I=0 '.' "$f" 2>&1); then
    err=$(printf '%s\n' "$json" | head -n 1)
    policy_refuse "not parseable YAML ($err)"
  fi
  [ "$(printf '%s\n' "$json" | wc -l | tr -d ' ')" = 1 ] || policy_refuse "more than one YAML document"
  tag=$(yq 'tag' "$f") || policy_refuse "unreadable YAML"
  case "$tag" in
    '!!null') POLICY_FILE_STATE=present; return 0 ;;   # empty, or comments only: no keys set
    '!!map') ;;
    *) policy_refuse "the top level must be a mapping of policy keys (found $tag)" ;;
  esac
  keys=$(yq -o=json -I=0 'keys' "$f") || policy_refuse "unreadable keys"
  jq -e 'length == (unique | length)' >/dev/null <<<"$keys" || policy_refuse "a key is set more than once"
  k=$(jq -r --arg known "$(policy_keys | paste -sd ' ' -)" \
        '.[] | tostring | select(. as $k | ($known | split(" ") | index($k)) == null)' <<<"$keys" | head -n 1)
  [ -z "$k" ] || policy_refuse "unknown key '$k' (known: $(policy_keys | paste -sd ',' - | sed 's/,/, /g'))"
  for k in $(jq -r '.[]' <<<"$keys"); do
    # Known keys are plain identifiers, so they are safe in a yq path.
    t=$(yq ".$k | tag" "$f") || policy_refuse "unreadable value of $k"
    case "$t" in
      '!!str'|'!!int'|'!!float'|'!!bool') ;;
      *) policy_refuse "$k must be a single value, $(policy_expect "$k") (found ${t:-an alias})" ;;
    esac
    raw=$(yq ".$k" "$f") || policy_refuse "unreadable value of $k"
    norm=$(policy_normalize "$k" "$raw") || policy_refuse "$k must be $(policy_expect "$k") (got '$raw')"
    printf -v "POLICY_FILE_$k" '%s' "$norm"
  done
  POLICY_FILE_STATE=present
}

# Resolves every key: --set, then the environment, then the file, then the
# built-in default. $1 is the --deep flag (1 when given). An invalid value
# from any tier is refused; an invalid file is refused even where a higher
# tier would override the key, so a broken file never goes unnoticed.
policy_resolve() {
  local deep_flag="${1:-}" k env v n line ck cv
  policy_read_file
  # Flags first, so an unknown or invalid --set fails before anything runs.
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    case "$line" in *=*) ;; *) die "--set needs KEY=VALUE (got '$line')" ;; esac
    ck=${line%%=*}; cv=${line#*=}
    [ -n "$(policy_default "$ck")" ] || die "--set: unknown policy key '$ck' (known: $(policy_keys | paste -sd ',' - | sed 's/,/, /g'))"
    policy_normalize "$ck" "$cv" >/dev/null || die "--set $ck must be $(policy_expect "$ck") (got '$cv')"
  done <<<"$POLICY_CLI"
  for k in $(policy_keys); do
    policy_set "$k" "$(policy_default "$k")" default
    n="POLICY_FILE_$k"
    if [ -n "${!n-}" ]; then
      policy_set "$k" "${!n}" "$PREPUSH_POLICY_FILE"
    fi
    env=$(policy_env_name "$k")
    if [ -n "${!env-}" ]; then
      v=$(policy_normalize "$k" "${!env}") || die "$env must be $(policy_expect "$k") (got '${!env}')"
      policy_set "$k" "$v" "env $env"
    fi
    if [ "$k" = deep ] && [ "$deep_flag" = 1 ]; then
      policy_set deep true "flag --deep"
    fi
    while IFS= read -r line; do
      [ "${line%%=*}" = "$k" ] || continue
      policy_set "$k" "$(policy_normalize "$k" "${line#*=}")" "flag --set $k"
    done <<<"$POLICY_CLI"
  done
}

# The effective policy in one line: each key's value and where it came from.
policy_summary() {
  local k out=''
  for k in $(policy_keys); do
    out="${out:+$out, }$k=$(policy_value "$k") ($(policy_source "$k"))"
  done
  printf '%s; %s %s' "$out" "$PREPUSH_POLICY_FILE" "$([ "$POLICY_FILE_STATE" = present ] && echo read || echo 'absent, built-in defaults')"
}

ORIGINAL_ARGS=("$@")
SNAPSHOT=0
TIMINGS_ROOT=''
MODE=range
HOOK_REMOTE=''
BASE_REF=''
PATHS_FROM=''
PLAN=0
DEEP=''   # the --deep flag; policy_resolve adds the env, file and default tiers (#2840)
ALL_LIVE=0
[ "${MERGEPATH_PREPUSH_LIVE:-selected}" = "all" ] && ALL_LIVE=1
JOBS="${MERGEPATH_PREPUSH_JOBS:-}"
NICE=''   # from the policy (#2840)
EVENT=''
HEAD_REF=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    --hook)
      MODE=hook
      [ "$#" -ge 2 ] || die "--hook needs the remote name"
      HOOK_REMOTE="$2"; shift 2
      # git passes the URL as a second argument; it is not needed.
      if [ "$#" -gt 0 ] && [ "${1#--}" = "$1" ]; then shift; fi
      ;;
    --committed-snapshot) SNAPSHOT=1; shift ;;
    --timings-root) [ "$#" -ge 2 ] || die "--timings-root needs a path"; TIMINGS_ROOT="$2"; shift 2 ;;
    --lock-record) [ "$#" -ge 2 ] || die "--lock-record needs a path"; LOCK_RECORD="$2"; shift 2 ;;
    --base) [ "$#" -ge 2 ] || die "--base needs a ref"; BASE_REF="$2"; shift 2 ;;
    --paths-from) [ "$#" -ge 2 ] || die "--paths-from needs a file or -"; MODE=paths; PATHS_FROM="$2"; shift 2 ;;
    --plan) PLAN=1; shift ;;
    --deep) DEEP=1; shift ;;
    --set) [ "$#" -ge 2 ] || die "--set needs KEY=VALUE"; POLICY_CLI="${POLICY_CLI}$2"$'\n'; shift 2 ;;
    --all-live) ALL_LIVE=1; shift ;;
    --jobs) [ "$#" -ge 2 ] || die "--jobs needs a number"; JOBS="$2"; shift 2 ;;
    --event) [ "$#" -ge 2 ] || die "--event needs a name"; EVENT="$2"; shift 2 ;;
    --head-ref) [ "$#" -ge 2 ] || die "--head-ref needs a ref"; HEAD_REF="$2"; shift 2 ;;
    -h|--help) awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$SELF"; exit 0 ;;
    *) die "unknown argument: $1 (see --help)" ;;
  esac
done
# An explicit cap is checked now; the default, NICE and DEEP come from the
# policy once the checked tree is known (#2840).
if [ -n "$JOBS" ]; then
  case "$JOBS" in *[!0-9]*|0) die "--jobs / MERGEPATH_PREPUSH_JOBS must be a positive integer (got '$JOBS')" ;; esac
fi

ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || die "not inside a git work tree"
cd "$ROOT"

# Hook checks get a detached tree per pushed branch. In particular, an
# untracked copy of a committed deletion cannot satisfy a check that CI will
# run without that file. These unique worktrees belong to this tool's
# lifecycle; never reuse or clean another session's checkout.
if [ "$MODE" = hook ] && [ "$PLAN" -eq 0 ] && [ "$SNAPSHOT" -eq 0 ]; then
  records=$(cat)
  common_dir=$(cd "$(git rev-parse --git-common-dir)" && pwd -P)
  # Capture the owning repository first, then detach hook-local index/worktree
  # overrides before creating or inspecting any snapshot.
  # shellcheck disable=SC2046
  unset $(git rev-parse --local-env-vars) 2>/dev/null || true
  primary_root=$(dirname "$common_dir")
  snapshots="$(dirname "$primary_root")/.$(basename "$primary_root")-worktrees"
  mkdir -p "$snapshots"
  snapshot=''
  # Invoked indirectly by the EXIT trap.
  # shellcheck disable=SC2329
  cleanup_snapshot() {
    local rc=$?
    trap - EXIT
    if [ -n "$snapshot" ]; then
      if ! git -C "$ROOT" worktree remove --force "$snapshot"; then
        echo "$PREFIX: could not retire owned snapshot $snapshot" >&2
        [ "$rc" -ne 0 ] || rc=2
      fi
    fi
    prepush_lock_release
    exit "$rc"
  }
  trap cleanup_snapshot EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  # One hook run per machine (#2581): the lock covers everything from the
  # first snapshot to the last check. A push with no branch update needs none.
  lock_branch=$(printf '%s\n' "$records" \
    | awk '$2 != "0000000000000000000000000000000000000000" && $3 ~ /^refs\/heads\// { sub("refs/heads/", "", $3); print $3; exit }')
  if [ -n "$lock_branch" ]; then
    prepush_lock_acquire "$lock_branch"
    retire_stale_snapshots "$snapshots"
  fi
  saw=0
  while read -r local_ref local_sha remote_ref remote_sha; do
    [ -n "${local_ref:-}" ] || continue
    [ "$local_sha" != 0000000000000000000000000000000000000000 ] || continue
    case "$remote_ref" in refs/heads/*) ;; *) continue ;; esac
    git cat-file -e "$local_sha^{commit}" || die "pushed tip is not an available commit"
    snapshot=$(mktemp -d "$snapshots/prepush-${local_sha:0:12}.XXXXXX")
    git -c core.hooksPath=/dev/null worktree add --quiet --detach "$snapshot" "$local_sha"
    [ "$(git -C "$snapshot" rev-parse HEAD)" = "$local_sha" ] || die "snapshot tip mismatch"
    echo "$PREFIX: checking committed tree $local_sha (${remote_ref#refs/heads/})"
    lock_write_record "${remote_ref#refs/heads/}" "$$" "$LOCK_START" preparing
    (
      # Git's hook-local repository/index variables must not redirect the
      # detached tree or any test-created fixture back into the push checkout.
      # shellcheck disable=SC2046
      unset $(git rev-parse --local-env-vars) 2>/dev/null || true
      cd "$snapshot"
      # The inner run and every check it starts inherit fd 9, and a flock(2)
      # lives as long as any descriptor of it is open: if this supervisor is
      # killed mid-run, the checks it already started keep the machine-wide
      # lock until they end, so a waiting push cannot overlap them.
      bash "$SELF" --committed-snapshot --timings-root "$ROOT" --lock-record "$LOCK_FILE" "${ORIGINAL_ARGS[@]}" \
        <<<"$local_ref $local_sha $remote_ref $remote_sha"
    )
    git worktree remove --force "$snapshot"
    snapshot=''
    saw=1
  done <<<"$records"
  [ "$saw" -ne 0 ] || echo "$PREFIX: no branch updates in this push; nothing to lint"
  exit 0
fi
CLASSIFIER=scripts/ci/repo-lint-scope.sh
WORKFLOW=.github/workflows/repo_lint.yml

# Hub-only first (#2221): a checkout without the scripts/ci kit or the
# workflow has nothing to mirror. A consumer (neither hub marker present)
# soft-passes; the hub missing either input is broken and says so.
if [ ! -f "$CLASSIFIER" ] || [ ! -f "$WORKFLOW" ]; then
  if [ ! -f scripts/sync-to-downstream.sh ] && [ ! -f .mergepath-sync.yml ]; then
    echo "$PREFIX: SKIP (no $CLASSIFIER or $WORKFLOW in this checkout; consumer or pre-kit tree)"
    exit 0
  fi
  die "the hub checkout is missing $CLASSIFIER or $WORKFLOW"
fi

# Tools. A git client may run hooks with a minimal PATH; Homebrew's yq is the
# one the workflow's install step expects (mikefarah/yq).
for d in /opt/homebrew/bin /usr/local/bin; do
  case ":$PATH:" in *":$d:"*) ;; *) [ -d "$d" ] && PATH="$PATH:$d" ;; esac
done
export PATH
command -v jq >/dev/null 2>&1 || die "jq is required"
if ! command -v yq >/dev/null 2>&1 || ! yq --version 2>&1 | grep -q 'mikefarah/yq'; then
  die "mikefarah/yq is required (brew install yq); the lint checks need it too"
fi

# ── the effective policy (#2840): read here, in the checked tree ──
policy_resolve "$DEEP"
if [ "$PLAN" -eq 1 ]; then
  printf 'policy\t%s\n' "$(policy_summary)"
else
  echo "$PREFIX: policy $(policy_summary)"
  if [ "$(policy_value mode)" = off ]; then
    echo "$PREFIX: skipped (mode=off from $(policy_source mode)); CI lint remains authoritative"
    exit 0
  fi
fi
DEEP=0
[ "$(policy_value deep)" = true ] && DEEP=1
NICE=$(policy_value nice)
prepush_default_jobs "$(policy_value jobs_max)" "$(policy_value load_per_cpu_threshold)"
[ -n "$JOBS" ] || JOBS="$DEFAULT_JOBS"

ZERO=0000000000000000000000000000000000000000

remote_default_ref() {
  # $1 = remote name. Prints <remote>/<branch> for the remote's default
  # branch from local refs only; the hook never fetches.
  local remote="$1" ref
  if ref=$(git symbolic-ref -q --short "refs/remotes/$remote/HEAD" 2>/dev/null) && [ -n "$ref" ]; then
    printf '%s\n' "$ref"; return 0
  fi
  for ref in "$remote/main" "$remote/master"; do
    if git rev-parse -q --verify "refs/remotes/$ref^{commit}" >/dev/null 2>&1; then
      printf '%s\n' "$ref"; return 0
    fi
  done
  return 1
}

CHANGED=''
FAIL_CLOSED=0
add_range() {
  # $1 = base ref/sha, $2 = tip sha. Appends the merge-base diff.
  local mb names
  if mb=$(git merge-base "$1" "$2" 2>/dev/null) \
     && names=$(git diff --name-only "$mb" "$2"); then
    [ -n "$names" ] && CHANGED="${CHANGED}${names}
"
    return 0
  fi
  FAIL_CLOSED=1
}

case "$MODE" in
  hook)
    remote="$HOOK_REMOTE"
    git remote get-url "$remote" >/dev/null 2>&1 || remote=origin
    default_ref=$(remote_default_ref "$remote") || default_ref=''
    default_branch="${default_ref#*/}"
    saw=0
    PUSHED=''
    while read -r local_ref local_sha remote_ref _remote_sha; do
      [ -n "${local_ref:-}" ] || continue
      [ "$local_sha" != "$ZERO" ] || continue      # deletion: nothing to lint
      case "$remote_ref" in refs/heads/*) ;; *) continue ;; esac   # tags, notes
      saw=1
      PUSHED="${PUSHED}${local_sha} ${remote_ref}
"
      branch="${remote_ref#refs/heads/}"
      if [ -n "$default_branch" ] && [ "$branch" = "$default_branch" ]; then
        [ -n "$EVENT" ] || EVENT=push            # CI's main-push run
      fi
      case "$branch" in
        mergepath-sync/*) HEAD_REF="$branch" ;;
        *) [ -n "$HEAD_REF" ] || HEAD_REF="$branch" ;;
      esac
      if [ -n "$default_ref" ]; then
        add_range "$default_ref" "$local_sha"
      else
        FAIL_CLOSED=1
      fi
    done
    if [ "$saw" -eq 0 ]; then
      echo "$PREFIX: no branch updates in this push; nothing to lint"
      exit 0
    fi
    if [ "$PLAN" -eq 0 ]; then
      [ "$SNAPSHOT" -eq 1 ] || die "hook checks require a committed snapshot"
      while read -r sha ref; do
        [ -n "$sha" ] || continue
        [ "$sha" = "$(git rev-parse HEAD)" ] || die "snapshot does not contain the pushed tip for $ref"
      done <<<"$PUSHED"
    fi
    ;;
  range)
    if [ -z "$BASE_REF" ]; then
      BASE_REF=$(remote_default_ref origin) || die "no origin default branch ref; pass --base <ref>"
    fi
    [ -n "$HEAD_REF" ] || HEAD_REF=$(git symbolic-ref -q --short HEAD 2>/dev/null || true)
    add_range "$BASE_REF" HEAD
    ;;
  paths)
    if [ "$PATHS_FROM" = "-" ]; then
      CHANGED=$(cat)
    else
      CHANGED=$(cat "$PATHS_FROM") || die "cannot read $PATHS_FROM"
    fi
    ;;
esac
[ -n "$EVENT" ] || EVENT=pull_request

# Children inherit nothing of the push: a test suite that runs `git init` in
# a fixture must not see this repository's GIT_DIR or GIT_INDEX_FILE.
# shellcheck disable=SC2046
unset $(git rev-parse --local-env-vars) 2>/dev/null || true
unset GITHUB_OUTPUT GITHUB_ENV GITHUB_PATH 2>/dev/null || true

# ── scope: the CI classifier, fed the same changed-path list ──
PATHS=$(printf '%s' "$CHANGED" | sed '/^$/d' | LC_ALL=C sort -u)
classify_paths() {  # stdin: changed paths, one per line
  bash "$CLASSIFIER" --event "$EVENT" --head-ref "$HEAD_REF"
}
if [ "$FAIL_CLOSED" -eq 1 ]; then
  # The CI scope job's "PR diff unavailable" branch.
  SCOPE=$'deep=true\nfull=true\nchecks=[]\nconsumer_replay=true\nself_tests=true'
  echo "$PREFIX: the pushed range has no merge base with the remote default branch; failing closed to the complete selection, as CI does"
else
  if [ "$EVENT" = "pull_request" ]; then
    SCOPE=$(printf '%s\n' "$PATHS" | classify_paths) || die "$CLASSIFIER failed"
  else
    SCOPE=$(printf '' | bash "$CLASSIFIER" --event "$EVENT") || die "$CLASSIFIER failed"
  fi
fi
scope_get() { printf '%s\n' "$2" | sed -n "s/^$1=//p" | head -n 1; }
scope_parse() {  # $1 = classifier output; sets P_DEEP P_FULL P_CHECKS P_REPLAY P_SELF
  P_DEEP=$(scope_get deep "$1"); P_FULL=$(scope_get full "$1"); P_CHECKS=$(scope_get checks "$1")
  P_REPLAY=$(scope_get consumer_replay "$1"); P_SELF=$(scope_get self_tests "$1")
  for v in "$P_DEEP" "$P_FULL" "$P_REPLAY" "$P_SELF"; do
    case "$v" in true|false) ;; *) die "unexpected classifier output: $1" ;; esac
  done
  jq -e 'type == "array"' >/dev/null 2>&1 <<<"$P_CHECKS" || die "unexpected classifier checks: $P_CHECKS"
}
scope_parse "$SCOPE"
S_DEEP=$P_DEEP; S_FULL=$P_FULL; S_CHECKS=$P_CHECKS; S_REPLAY=$P_REPLAY; S_SELF=$P_SELF

# ── undeclared-path fallback (#2580) ──
# CI's classifier fails closed: a changed path that no wrapper, trigger or
# full trigger declares selects the complete surface, and CI keeps doing so.
# Locally that turned a one-file change into every graph wrapper and every
# deep step. The hook re-classifies without those paths instead: each
# undeclared path keeps only the always-run live assertions here, is named
# in one loud line, and CI's `lint` runs the complete surface for it. A
# complete selection for any other reason (a full trigger, a push event, a
# propagation-lane head, no merge base, an unreadable graph) is unchanged.
# An undeclared path is one that selects the complete surface alone and is
# not a full trigger; the classifier decides the first half, so the hook
# re-implements only the full-trigger glob match.
UNDECLARED=''
FULL_REASON=''
L_SCOPE="$SCOPE"
if [ "$S_FULL" = true ]; then
  GRAPH=scripts/ci/repo-lint-dependencies.json
  if [ "$FAIL_CLOSED" -eq 1 ]; then
    FULL_REASON='no merge base with the remote default branch'
  elif [ "$EVENT" != pull_request ]; then
    FULL_REASON="a $EVENT event"
  else
    case "$HEAD_REF" in mergepath-sync/*) FULL_REASON='a propagation-lane head' ;; esac
  fi
  if [ -z "$FULL_REASON" ]; then
    # An empty list is valid; only a missing or malformed one is unreadable.
    if ! full_trigger_globs=$(jq -r 'if (.full_triggers | type) == "array" then .full_triggers[] | select(type == "string") else error("no full_triggers") end' "$GRAPH" 2>/dev/null); then
      FULL_REASON='the dependency graph is unreadable'
    fi
  fi
  if [ -z "$FULL_REASON" ]; then
    while IFS= read -r p; do
      [ -n "$p" ] || continue
      trigger=0
      while IFS= read -r glob; do
        [ -n "$glob" ] || continue
        # shellcheck disable=SC2254 # graph entries are case globs by design
        case "$p" in $glob) trigger=1; break ;; esac
      done <<<"$full_trigger_globs"
      if [ "$trigger" -eq 1 ]; then
        FULL_REASON="a full trigger ($p)"
        UNDECLARED=''
        break
      fi
      one=$(printf '%s\n' "$p" | classify_paths) || die "$CLASSIFIER failed"
      if [ "$(scope_get full "$one")" = true ]; then
        UNDECLARED="${UNDECLARED}${p}
"
      fi
    done <<<"$PATHS"
  fi
  if [ -z "$FULL_REASON" ] && [ -n "$UNDECLARED" ]; then
    L_SCOPE=$(LC_ALL=C comm -23 <(printf '%s\n' "$PATHS") <(printf '%s' "$UNDECLARED" | LC_ALL=C sort -u) \
      | sed '/^$/d' | classify_paths) || die "$CLASSIFIER failed"
    if [ "$(scope_get full "$L_SCOPE")" = true ]; then
      # Something besides the undeclared paths selects everything.
      FULL_REASON='the complete-surface rule'
      UNDECLARED=''
      L_SCOPE="$SCOPE"
    fi
  elif [ -z "$FULL_REASON" ]; then
    FULL_REASON='the complete-surface rule'
  fi
fi
scope_parse "$L_SCOPE"
L_DEEP=$P_DEEP; L_FULL=$P_FULL; L_CHECKS=$P_CHECKS; L_REPLAY=$P_REPLAY; L_SELF=$P_SELF

# ── plan: derive the step list from the workflow ──
JOBS_JSON=$(yq -o=json '.jobs' "$WORKFLOW") || die "cannot parse $WORKFLOW"
# Graph-declared wrappers. An unreadable graph leaves this empty, which puts
# every wrapper in the always-run lane (the classifier fails closed too).
GRAPH_WRAPPERS=$(jq -c '.wrappers | keys' scripts/ci/repo-lint-dependencies.json 2>/dev/null) || GRAPH_WRAPPERS='[]'
jq -e 'type == "array"' >/dev/null 2>&1 <<<"$GRAPH_WRAPPERS" || GRAPH_WRAPPERS='[]'
# Two selections: CI's (S_*) decides which steps are in the plan at all, the
# local one (L_*, CI's minus the undeclared-path expansion) which of them run
# by default. They are equal unless UNDECLARED is set. Deep steps take the
# local scope values in their env, so a locally run harness sees the local
# selection; under MERGEPATH_PREPUSH_LIVE=all they take CI's, as CI runs them.
if [ "$ALL_LIVE" -eq 1 ]; then ENV_FULL=$S_FULL; ENV_CHECKS=$S_CHECKS; else ENV_FULL=$L_FULL; ENV_CHECKS=$L_CHECKS; fi
PLAN_JSON=$(jq -c \
  --argjson deep "$S_DEEP" --argjson full "$S_FULL" --argjson checks "$S_CHECKS" \
  --argjson ldeep "$L_DEEP" --argjson lfull "$L_FULL" --argjson lchecks "$L_CHECKS" \
  --argjson graph "$GRAPH_WRAPPERS" \
  --argjson replay "$S_REPLAY" --argjson self "$S_SELF" \
  --argjson lreplay "$L_REPLAY" --argjson lself "$L_SELF" \
  --arg fullstr "$ENV_FULL" --arg checksstr "$ENV_CHECKS" '
  def need($j): (.[$j] // error("workflow job \($j) is missing; the pre-push mirror needs updating"));
  def st_on($d; $s; $f; $c; $w): $d and $s and ($f or (($c | index($w)) != null));
  def wrapper: [(.run // "") | capture("^\\./scripts/ci/(?<w>check_[A-Za-z0-9_]+)") | .w] | first;
  def check_steps: [.steps[] | select(wrapper != null and wrapper != "check_git_identity_hygiene")];
  # ${{ needs.scope.outputs.* }} becomes the classifier value; a matrix
  # reference (the replay shard) is dropped so one local run covers all
  # shards; anything else is a workflow shape this script does not know.
  def subst: with_entries(
      if (.value | type) != "string" or ((.value | test("\\$\\{\\{")) | not) then .
      elif (.value | test("^\\$\\{\\{ *needs\\.scope\\.outputs\\.full *\\}\\}$")) then .value = $fullstr
      elif (.value | test("^\\$\\{\\{ *needs\\.scope\\.outputs\\.checks *\\}\\}$")) then .value = $checksstr
      elif (.value | test("\\$\\{\\{ *matrix\\.")) then empty
      else error("unrecognized expression in env \(.key): \(.value)") end);
  def envlist($job; $step): (($job.env // {}) + ($step.env // {})) | subst | to_entries | map("\(.key)=\(.value)");
  need("lint_fast") as $fast
  | need("deep_safety") as $safety
  | need("deep_consumer_replay") as $rep
  | need("deep_self_tests") as $st
  | [ ($fast.steps[] | select(.if != null and (.name | startswith("check_")))
        | if (.if | test("^matrix\\.shard == [0-9]+$")) then
            wrapper as $w
            | {lane: (if $w == null or ($graph | index($w)) == null then "live"
                      elif $lfull or ($lchecks | index($w)) != null then "selected"
                      elif $full or ($checks | index($w)) != null then "fallback"
                      else "unselected" end),
               job: "lint_fast", name, run, env: []}
          elif (.if | test("^matrix\\.shard != [0-9]+$")) then empty
          else error("lint_fast step \(.name) has an unrecognized if: \(.if)") end),
      ($st | check_steps[] as $s
        | select(st_on($deep; $self; $full; $checks; $s | wrapper))
        | {lane: (if st_on($ldeep; $lself; $lfull; $lchecks; $s | wrapper) then "deep" else "deep_fallback" end),
           job: "deep_self_tests", name: $s.name, run: $s.run, env: envlist($st; $s)}),
      ($safety | check_steps[] as $s | select($deep)
        | {lane: (if $ldeep then "deep" else "deep_fallback" end),
           job: "deep_safety", name: $s.name, run: $s.run, env: envlist($safety; $s)}),
      ($rep | check_steps[] as $s | select($deep and $replay)
        | {lane: (if $ldeep and $lreplay then "deep" else "deep_fallback" end),
           job: "deep_consumer_replay", name: $s.name, run: $s.run, env: envlist($rep; $s)})
    ] | .[]' <<<"$JOBS_JSON") || die "cannot derive the step list from $WORKFLOW"

lane_count() { printf '%s\n' "$PLAN_JSON" | jq -s --arg l "$1" '[.[] | select(.lane == $l)] | length'; }
LIVE_N=$(lane_count live); SEL_N=$(lane_count selected); UNSEL_N=$(lane_count unselected); DEEP_N=$(lane_count deep)
FB_N=$(lane_count fallback); DEEPFB_N=$(lane_count deep_fallback)
[ "$LIVE_N" -gt 0 ] || die "no live checks found in $WORKFLOW (extraction broken?)"

# Why the graph wrappers are selected, printed beside the run line.
if [ -n "$FULL_REASON" ]; then
  SELECTION_REASON="$SEL_N wrappers selected by the complete-surface rule ($FULL_REASON)"
else
  SELECTION_REASON="$SEL_N wrappers selected by path, $FB_N by undeclared-path fallback"
fi
undeclared_notice() {
  [ -n "$UNDECLARED" ] || return 0
  local list ran
  list=$(printf '%s' "$UNDECLARED" | sed '/^$/d' | paste -sd ',' - | sed 's/,/, /g')
  # Say what this invocation does with the expansion: --plan runs nothing,
  # LIVE=all runs the fallback wrappers (and with DEEP=1 the deep steps).
  if [ "$PLAN" -eq 1 ]; then
    ran="a hook run executes only the live assertions for it ($FB_N fallback wrappers and $DEEPFB_N deep steps are not run by default)"
  elif [ "$ALL_LIVE" -eq 1 ] && [ "$DEEP" -eq 1 ]; then
    ran="MERGEPATH_PREPUSH_LIVE=all and MERGEPATH_PREPUSH_DEEP=1 run it here too ($FB_N fallback wrappers and $DEEPFB_N deep steps)"
  elif [ "$ALL_LIVE" -eq 1 ]; then
    ran="MERGEPATH_PREPUSH_LIVE=all runs its $FB_N fallback wrappers here; its $DEEPFB_N deep steps also need MERGEPATH_PREPUSH_DEEP=1"
  else
    ran="this hook runs only the live assertions for it ($FB_N fallback wrappers and $DEEPFB_N deep steps not run here; MERGEPATH_PREPUSH_LIVE=all runs the wrappers, and with MERGEPATH_PREPUSH_DEEP=1 as well the deep steps)"
  fi
  echo "$PREFIX: UNDECLARED PATH: $list is in no wrapper's declared inputs in scripts/ci/repo-lint-dependencies.json. CI's lint runs the complete surface for it; $ran."
}

if [ "$PLAN" -eq 1 ]; then
  printf 'scope\tdeep=%s full=%s checks=%s consumer_replay=%s self_tests=%s\n' \
    "$S_DEEP" "$S_FULL" "$S_CHECKS" "$S_REPLAY" "$S_SELF"
  if [ -n "$UNDECLARED" ]; then
    printf 'local_scope\tdeep=%s full=%s checks=%s consumer_replay=%s self_tests=%s\n' \
      "$L_DEEP" "$L_FULL" "$L_CHECKS" "$L_REPLAY" "$L_SELF"
    printf '%s' "$UNDECLARED" | sed '/^$/d' | sed 's/^/undeclared\t/'
  fi
  printf 'selection\t%s\n' "$SELECTION_REASON"
  printf '%s\n' "$PLAN_JSON" | jq -r '[.lane, .job, .name] | @tsv'
  undeclared_notice >&2
  exit 0
fi

echo "$PREFIX: scope deep=$S_DEEP full=$S_FULL consumer_replay=$S_REPLAY self_tests=$S_SELF checks=$S_CHECKS"

# Read literal CI pins from the committed workflow instead of maintaining a
# second version list. Missing/conflicting pins are an environment error.
CI_PY_PINS=$(jq -er '
  [ .[] | .steps[]? | select(.name == "install_python_ci_dependencies")
    | (.run // "") | scan("(?i)(PyYAML|markdown-it-py)==([0-9][A-Za-z0-9.+_-]*)")
    | {name: (.[0] | ascii_downcase), version: .[1]} ]
  | group_by(.name) | map({key: .[0].name, value: (map(.version) | unique)}) | from_entries
  | if ((.pyyaml | length) == 1 and (.["markdown-it-py"] | length) == 1)
    then {PyYAML: .pyyaml[0], "markdown-it-py": .["markdown-it-py"][0]}
    else error("missing or conflicting CI Python package pins") end
' <<<"$JOBS_JSON") || die "cannot resolve pinned CI Python packages from $WORKFLOW"
PY_PROBE='import importlib.metadata as m, json, sys
pins=json.loads(sys.argv[1])
import yaml
assert m.version("PyYAML") == pins["PyYAML"]
if sys.argv[2] == "1":
 import markdown_it
 assert m.version("markdown-it-py") == pins["markdown-it-py"]'
PY_SHIM=''
PY_OK=0
# An explicit MERGEPATH_PREPUSH_PYTHON is the only candidate when set.
if [ -n "${MERGEPATH_PREPUSH_PYTHON:-}" ]; then
  PY_CANDIDATES=("$MERGEPATH_PREPUSH_PYTHON")
else
  PY_CANDIDATES=(python3 python3.14 python3.13 python3.12 python3.11 /usr/bin/python3)
fi
for cand in "${PY_CANDIDATES[@]}"; do
  if command -v "$cand" >/dev/null 2>&1 && "$cand" -I -c "$PY_PROBE" "$CI_PY_PINS" "$DEEP" >/dev/null 2>&1; then
    PY_SHIM=$(command -v "$cand")
    PY_OK=1
    break
  fi
done
if [ "$PY_OK" -ne 1 ]; then
  echo "$PREFIX: no python3 with the CI packages at workflow pins ($CI_PY_PINS) was found; without them several checks skip assertions and pass, so the run would not mean what CI means." >&2
  echo "$PREFIX: install the displayed workflow pins for some python3 and point MERGEPATH_PREPUSH_PYTHON at it, or bypass with --no-verify / MERGEPATH_PREPUSH_SKIP=1." >&2
  exit 2
fi

# ShellCheck is on every runner; locally its absence makes several wrappers
# warn, skip their lint step and pass (they hard-fail only under CI). Missing
# it is an environment error here for the same reason as the Python packages.
if ! command -v shellcheck >/dev/null 2>&1; then
  echo "$PREFIX: shellcheck is not installed; several checks skip their ShellCheck step locally and would pass where CI fails (brew install shellcheck), or bypass with --no-verify / MERGEPATH_PREPUSH_SKIP=1." >&2
  exit 2
fi

RUN_DIR=$(mktemp -d "${TMPDIR:-/tmp}/repo-lint-prepush.XXXXXX")
mkdir -p "$RUN_DIR/steps" "$RUN_DIR/logs" "$RUN_DIR/results"
printf '%s\n' "$ROOT" > "$RUN_DIR/root"
printf '%s\n' "$NICE" > "$RUN_DIR/nice"
if [ -n "$PY_SHIM" ]; then
  mkdir -p "$RUN_DIR/bin"
  # Preserve the selected executable path: invoking a venv Python through an
  # external symlink can lose pyvenv.cfg and its verified site-packages.
  # Nested fixtures may deliberately omit bash from PATH. Keep this launcher
  # self-contained and quote the interpreter for POSIX sh, including apostrophes.
  PY_SHIM_QUOTED="'${PY_SHIM//\'/\'\\\'\'}'"
  printf '#!/bin/sh\nexec %s "$@"\n' "$PY_SHIM_QUOTED" > "$RUN_DIR/bin/python3"
  chmod +x "$RUN_DIR/bin/python3"
  PATH="$RUN_DIR/bin:$PATH"; export PATH
fi

# Longest-first ordering from the previous run's timings, so the slowest
# check starts first and the concurrency cap is used evenly.
TIMINGS="${TIMINGS_ROOT:-$ROOT}/.mergepath/prepush-timings.tsv"
lanes='"live","selected"'
# mode=selected (#2840): only the classifier's selected wrappers; CI runs the
# live assertions.
LIVE_RUN_N=$LIVE_N
[ "$(policy_value mode)" != selected ] || { lanes='"selected"'; LIVE_RUN_N=0; }
[ "$ALL_LIVE" -eq 1 ] && lanes="$lanes,\"fallback\",\"unselected\""
[ "$DEEP" -eq 1 ] && lanes="$lanes,\"deep\""
[ "$DEEP" -eq 1 ] && [ "$ALL_LIVE" -eq 1 ] && lanes="$lanes,\"deep_fallback\""
id=0
while IFS= read -r step; do
  id=$((id + 1))
  sid=$(printf '%03d' "$id")
  jq -r '.name' <<<"$step" > "$RUN_DIR/steps/$sid.name"
  jq -r '.run' <<<"$step" > "$RUN_DIR/steps/$sid.sh"
  jq -r '.env[]' <<<"$step" > "$RUN_DIR/steps/$sid.env"
  name=$(cat "$RUN_DIR/steps/$sid.name")
  prev=0
  if [ -f "$TIMINGS" ]; then
    prev=$(awk -F'\t' -v n="$name" '$1 == n { print $2; exit }' "$TIMINGS")
    [ -n "$prev" ] || prev=0
  fi
  printf '%s\t%s\n' "$prev" "$sid" >> "$RUN_DIR/order"
done < <(printf '%s\n' "$PLAN_JSON" | jq -c "select(.lane == ($lanes))")
if [ ! -s "$RUN_DIR/order" ]; then
  # Only mode=selected can select nothing: the live lane is never empty.
  echo "$PREFIX: PASS (mode=selected from $(policy_source mode), and the classifier selected no wrapper for this change: nothing to run here; CI lint still runs the $LIVE_N live assertions and remains authoritative)"
  rm -rf "$RUN_DIR"
  exit 0
fi

# One host reading per run (#2575, #2581): the load that sized the jobs
# default is the one printed here; the verdict line reads it again at the end.
LOAD_START="$LOAD_1"
echo "$PREFIX: running $(wc -l < "$RUN_DIR/order" | tr -d ' ') checks (jobs=$JOBS, nice=$NICE, host load $LOAD_START on $CPU_N CPUs): $LIVE_RUN_N live assertions, $SEL_N selected wrappers$([ "$ALL_LIVE" -eq 1 ] && echo ", $FB_N fallback wrappers, $UNSEL_N unselected wrappers")$([ "$DEEP" -eq 1 ] && echo ", $DEEP_N deep-lane steps")$([ "$DEEP" -eq 1 ] && [ "$ALL_LIVE" -eq 1 ] && echo ", $DEEPFB_N fallback deep-lane steps")"
echo "$PREFIX: selection: $SELECTION_REASON"
[ "$(policy_value mode)" != selected ] || echo "$PREFIX: mode=selected (from $(policy_source mode)): the $LIVE_N live assertions are not run here; CI runs them"
undeclared_notice
if [ "$ALL_LIVE" -ne 1 ] && [ "$UNSEL_N" -gt 0 ]; then
  echo "$PREFIX: $UNSEL_N graph-declared wrappers are unselected for this change and not run (MERGEPATH_PREPUSH_LIVE=all runs CI's whole fast lane)"
fi
if [ "$DEEP" -ne 1 ] && [ "$DEEP_N" -gt 0 ]; then
  echo "$PREFIX: the deep lane selects $DEEP_N steps; not run here (MERGEPATH_PREPUSH_DEEP=1 runs them; CI runs them regardless):"
  printf '%s\n' "$PLAN_JSON" | jq -r 'select(.lane == "deep") | "    \(.job): \(.name)"'
fi

expected=$(wc -l < "$RUN_DIR/order" | tr -d ' ')
prepush_lock_progress 0 "$expected"
T0=$(date +%s)
sort -t "$(printf '\t')" -k1,1nr -k2,2 "$RUN_DIR/order" | cut -f2 \
  | xargs -P "$JOBS" -n 1 bash "$SELF" --exec-step "$RUN_DIR" \
  | while IFS= read -r line; do
      # Each worker prints one result line; the lock record follows them so a
      # push waiting on this run can report its progress.
      printf '%s\n' "$line"
      prepush_lock_progress "$(find "$RUN_DIR/results" -type f | wc -l | tr -d ' ')" "$expected"
    done
ELAPSED=$(( $(date +%s) - T0 ))

failed=0
total=0
for f in "$RUN_DIR"/results/*; do
  [ -f "$f" ] || continue
  total=$((total + 1))
  rc=$(cut -f1 "$f")
  [ "$rc" = "0" ] || failed=$((failed + 1))
done
if [ "$total" -ne "$expected" ]; then
  echo "$PREFIX: only $total of $expected checks reported a result; treating the run as failed" >&2
  failed=$((failed + 1))
fi

# Remember durations for the next run's ordering (best effort).
if mkdir -p "$(dirname "$TIMINGS")" 2>/dev/null; then
  {
    cat "$RUN_DIR"/results/* 2>/dev/null | awk -F'\t' '{ print $3 "\t" $2 }'
    if [ -f "$TIMINGS" ]; then cat "$TIMINGS"; fi
  } | awk -F'\t' '!seen[$1]++' > "$RUN_DIR/timings.new" && mv "$RUN_DIR/timings.new" "$TIMINGS" || true
fi

mins=$((ELAPSED / 60)); secs=$((ELAPSED % 60))
LOAD_NOTE="host load $LOAD_START at start, $(host_load) at end"
if [ "$failed" -eq 0 ]; then
  echo "$PREFIX: PASS ($total checks in ${mins}m${secs}s; $LOAD_NOTE). CI lint still runs and remains authoritative."
  if [ "${MERGEPATH_PREPUSH_KEEP_LOGS:-0}" = "1" ]; then
    echo "$PREFIX: logs kept in $RUN_DIR"
  else
    rm -rf "$RUN_DIR"
  fi
  exit 0
fi

echo "" >&2
for f in "$RUN_DIR"/results/*; do
  [ -f "$f" ] || continue
  rc=$(cut -f1 "$f")
  [ "$rc" = "0" ] && continue
  sid=$(basename "$f")
  echo "── $(cut -f3 "$f") (exit $rc), last 30 lines of $RUN_DIR/logs/$sid.log ──" >&2
  tail -n 30 "$RUN_DIR/logs/$sid.log" >&2
  echo "" >&2
done
echo "$PREFIX: FAIL ($failed of $expected checks failed in ${mins}m${secs}s; $LOAD_NOTE); the push is blocked. Logs: $RUN_DIR" >&2
echo "$PREFIX: fix and push again. Bypass only in an emergency: git push --no-verify, or MERGEPATH_PREPUSH_SKIP=1 git push (CI lint still gates the merge)." >&2
exit 1
