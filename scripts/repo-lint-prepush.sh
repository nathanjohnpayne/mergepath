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
#                when it selects the complete surface). Always run.
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
#   deep       - the deep-lane steps the scope bits select: the enrolled
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
#   --jobs N       concurrency cap (default MERGEPATH_PREPUSH_JOBS or 2)
#   --event NAME    classifier event (default pull_request; a push to the
#                   remote default branch is classified as `push`, like CI)
#   --head-ref REF  branch name handed to the classifier (mergepath-sync/*
#                   selects the complete surface, as in CI)
# Environment:
#   MERGEPATH_PREPUSH_SKIP=1    bypass entirely (as does git push --no-verify)
#   MERGEPATH_PREPUSH_DEEP=1    run the selected deep-lane steps too
#   MERGEPATH_PREPUSH_LIVE=all  run the unselected graph wrappers too
#   MERGEPATH_PREPUSH_JOBS=N    concurrency cap, default 2
#   MERGEPATH_PREPUSH_NICE=N    nice level for every check, default 10
#   MERGEPATH_PREPUSH_PYTHON=P  interpreter to expose as python3 (needs PyYAML,
#                               and markdown-it-py for the deep lane)
#   MERGEPATH_PREPUSH_KEEP_LOGS=1  keep the per-check logs of a passing run
# Hook checks run in tool-owned detached worktrees of each pushed tip, so
# working-tree modifications and untracked files cannot affect their result.
# Python package metadata must equal the committed workflow pins.
# Exit: 0 pass or skipped, 1 a selected check failed, 2 usage or environment
# (including missing or mismatched CI packages).

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

ORIGINAL_ARGS=("$@")
SNAPSHOT=0
TIMINGS_ROOT=''
MODE=range
HOOK_REMOTE=''
BASE_REF=''
PATHS_FROM=''
PLAN=0
DEEP="${MERGEPATH_PREPUSH_DEEP:-0}"
ALL_LIVE=0
[ "${MERGEPATH_PREPUSH_LIVE:-selected}" = "all" ] && ALL_LIVE=1
JOBS="${MERGEPATH_PREPUSH_JOBS:-2}"
NICE="${MERGEPATH_PREPUSH_NICE:-10}"
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
    --base) [ "$#" -ge 2 ] || die "--base needs a ref"; BASE_REF="$2"; shift 2 ;;
    --paths-from) [ "$#" -ge 2 ] || die "--paths-from needs a file or -"; MODE=paths; PATHS_FROM="$2"; shift 2 ;;
    --plan) PLAN=1; shift ;;
    --deep) DEEP=1; shift ;;
    --all-live) ALL_LIVE=1; shift ;;
    --jobs) [ "$#" -ge 2 ] || die "--jobs needs a number"; JOBS="$2"; shift 2 ;;
    --event) [ "$#" -ge 2 ] || die "--event needs a name"; EVENT="$2"; shift 2 ;;
    --head-ref) [ "$#" -ge 2 ] || die "--head-ref needs a ref"; HEAD_REF="$2"; shift 2 ;;
    -h|--help) awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$SELF"; exit 0 ;;
    *) die "unknown argument: $1 (see --help)" ;;
  esac
done
case "$JOBS" in ''|*[!0-9]*|0) die "--jobs / MERGEPATH_PREPUSH_JOBS must be a positive integer (got '$JOBS')" ;; esac
case "$NICE" in ''|*[!0-9]*) die "MERGEPATH_PREPUSH_NICE must be a non-negative integer (got '$NICE')" ;; esac
case "$DEEP" in 1|true) DEEP=1 ;; *) DEEP=0 ;; esac

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
    exit "$rc"
  }
  trap cleanup_snapshot EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
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
    (
      # Git's hook-local repository/index variables must not redirect the
      # detached tree or any test-created fixture back into the push checkout.
      # shellcheck disable=SC2046
      unset $(git rev-parse --local-env-vars) 2>/dev/null || true
      cd "$snapshot"
      bash "$SELF" --committed-snapshot --timings-root "$ROOT" "${ORIGINAL_ARGS[@]}" \
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
if [ "$FAIL_CLOSED" -eq 1 ]; then
  # The CI scope job's "PR diff unavailable" branch.
  SCOPE=$'deep=true\nfull=true\nchecks=[]\nconsumer_replay=true\nself_tests=true'
  echo "$PREFIX: the pushed range has no merge base with the remote default branch; failing closed to the complete selection, as CI does"
else
  if [ "$EVENT" = "pull_request" ]; then
    SCOPE=$(printf '%s' "$CHANGED" | sed '/^$/d' | LC_ALL=C sort -u \
      | bash "$CLASSIFIER" --event "$EVENT" --head-ref "$HEAD_REF") || die "$CLASSIFIER failed"
  else
    SCOPE=$(printf '' | bash "$CLASSIFIER" --event "$EVENT") || die "$CLASSIFIER failed"
  fi
fi
scope_get() { printf '%s\n' "$SCOPE" | sed -n "s/^$1=//p" | head -n 1; }
S_DEEP=$(scope_get deep); S_FULL=$(scope_get full); S_CHECKS=$(scope_get checks)
S_REPLAY=$(scope_get consumer_replay); S_SELF=$(scope_get self_tests)
for v in "$S_DEEP" "$S_FULL" "$S_REPLAY" "$S_SELF"; do
  case "$v" in true|false) ;; *) die "unexpected classifier output: $SCOPE" ;; esac
done
jq -e 'type == "array"' >/dev/null 2>&1 <<<"$S_CHECKS" || die "unexpected classifier checks: $S_CHECKS"

# ── plan: derive the step list from the workflow ──
JOBS_JSON=$(yq -o=json '.jobs' "$WORKFLOW") || die "cannot parse $WORKFLOW"
# Graph-declared wrappers. An unreadable graph leaves this empty, which puts
# every wrapper in the always-run lane (the classifier fails closed too).
GRAPH_WRAPPERS=$(jq -c '.wrappers | keys' scripts/ci/repo-lint-dependencies.json 2>/dev/null) || GRAPH_WRAPPERS='[]'
jq -e 'type == "array"' >/dev/null 2>&1 <<<"$GRAPH_WRAPPERS" || GRAPH_WRAPPERS='[]'
PLAN_JSON=$(jq -c \
  --argjson deep "$S_DEEP" --argjson full "$S_FULL" --argjson checks "$S_CHECKS" \
  --argjson graph "$GRAPH_WRAPPERS" \
  --argjson replay "$S_REPLAY" --argjson self "$S_SELF" \
  --arg fullstr "$S_FULL" --arg checksstr "$S_CHECKS" '
  def need($j): (.[$j] // error("workflow job \($j) is missing; the pre-push mirror needs updating"));
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
                      elif $full or ($checks | index($w)) != null then "selected"
                      else "unselected" end),
               job: "lint_fast", name, run, env: []}
          elif (.if | test("^matrix\\.shard != [0-9]+$")) then empty
          else error("lint_fast step \(.name) has an unrecognized if: \(.if)") end),
      ($st | check_steps[] as $s
        | select($deep and $self and ($full or (($checks | index($s | wrapper)) != null)))
        | {lane: "deep", job: "deep_self_tests", name: $s.name, run: $s.run, env: envlist($st; $s)}),
      ($safety | check_steps[] as $s | select($deep)
        | {lane: "deep", job: "deep_safety", name: $s.name, run: $s.run, env: envlist($safety; $s)}),
      ($rep | check_steps[] as $s | select($deep and $replay)
        | {lane: "deep", job: "deep_consumer_replay", name: $s.name, run: $s.run, env: envlist($rep; $s)})
    ] | .[]' <<<"$JOBS_JSON") || die "cannot derive the step list from $WORKFLOW"

lane_count() { printf '%s\n' "$PLAN_JSON" | jq -s --arg l "$1" '[.[] | select(.lane == $l)] | length'; }
LIVE_N=$(lane_count live); SEL_N=$(lane_count selected); UNSEL_N=$(lane_count unselected); DEEP_N=$(lane_count deep)
[ "$LIVE_N" -gt 0 ] || die "no live checks found in $WORKFLOW (extraction broken?)"

if [ "$PLAN" -eq 1 ]; then
  printf 'scope\tdeep=%s full=%s checks=%s consumer_replay=%s self_tests=%s\n' \
    "$S_DEEP" "$S_FULL" "$S_CHECKS" "$S_REPLAY" "$S_SELF"
  printf '%s\n' "$PLAN_JSON" | jq -r '[.lane, .job, .name] | @tsv'
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
  PY_CANDIDATES="$MERGEPATH_PREPUSH_PYTHON"
else
  PY_CANDIDATES='python3 python3.14 python3.13 python3.12 python3.11 /usr/bin/python3'
fi
for cand in $PY_CANDIDATES; do
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
  ln -s "$PY_SHIM" "$RUN_DIR/bin/python3"
  PATH="$RUN_DIR/bin:$PATH"; export PATH
fi

# Longest-first ordering from the previous run's timings, so the slowest
# check starts first and the concurrency cap is used evenly.
TIMINGS="${TIMINGS_ROOT:-$ROOT}/.mergepath/prepush-timings.tsv"
lanes='"live","selected"'
[ "$ALL_LIVE" -eq 1 ] && lanes="$lanes,\"unselected\""
[ "$DEEP" -eq 1 ] && lanes="$lanes,\"deep\""
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

echo "$PREFIX: running $(wc -l < "$RUN_DIR/order" | tr -d ' ') checks (jobs=$JOBS, nice=$NICE): $LIVE_N live assertions, $SEL_N selected wrappers$([ "$ALL_LIVE" -eq 1 ] && echo ", $UNSEL_N unselected wrappers")$([ "$DEEP" -eq 1 ] && echo ", $DEEP_N deep-lane steps")"
if [ "$ALL_LIVE" -ne 1 ] && [ "$UNSEL_N" -gt 0 ]; then
  echo "$PREFIX: $UNSEL_N graph-declared wrappers are unselected for this change and not run (MERGEPATH_PREPUSH_LIVE=all runs CI's whole fast lane)"
fi
if [ "$DEEP" -ne 1 ] && [ "$DEEP_N" -gt 0 ]; then
  echo "$PREFIX: the deep lane selects $DEEP_N steps; not run here (MERGEPATH_PREPUSH_DEEP=1 runs them; CI runs them regardless):"
  printf '%s\n' "$PLAN_JSON" | jq -r 'select(.lane == "deep") | "    \(.job): \(.name)"'
fi

T0=$(date +%s)
sort -t "$(printf '\t')" -k1,1nr -k2,2 "$RUN_DIR/order" | cut -f2 \
  | xargs -P "$JOBS" -n 1 bash "$SELF" --exec-step "$RUN_DIR"
ELAPSED=$(( $(date +%s) - T0 ))

failed=0
total=0
for f in "$RUN_DIR"/results/*; do
  [ -f "$f" ] || continue
  total=$((total + 1))
  rc=$(cut -f1 "$f")
  [ "$rc" = "0" ] || failed=$((failed + 1))
done
expected=$(wc -l < "$RUN_DIR/order" | tr -d ' ')
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
if [ "$failed" -eq 0 ]; then
  echo "$PREFIX: PASS ($total checks in ${mins}m${secs}s). CI lint still runs and remains authoritative."
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
echo "$PREFIX: FAIL ($failed of $expected checks failed in ${mins}m${secs}s); the push is blocked. Logs: $RUN_DIR" >&2
echo "$PREFIX: fix and push again. Bypass only in an emergency: git push --no-verify, or MERGEPATH_PREPUSH_SKIP=1 git push (CI lint still gates the merge)." >&2
exit 1
