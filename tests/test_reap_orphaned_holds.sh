#!/usr/bin/env bash
# Behavior suite for scripts/workflow/reap-orphaned-holds.sh (#2907) and its
# call site in the publisher's scheduled pass. Hermetic: a stub `gh` serves
# fixture check runs shaped like friends-and-family-billing#583 on
# 2026-10-30, where six phase-1 holds outlived every later green verdict.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REAPER="$ROOT/scripts/workflow/reap-orphaned-holds.sh"
WORKFLOW="${REQUIRED_CHECK_PUBLISHER_WORKFLOW:-$ROOT/.github/workflows/required-check-publisher.yml}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0
pass() { echo "ok - $1"; PASS=$((PASS + 1)); }
fail() { echo "not ok - $1" >&2; [ -z "${2:-}" ] || echo "  $2" >&2; FAIL=$((FAIL + 1)); }

HEAD_A=1fa4ea8ded7cd0bc7108bb526a37233a1ec6b609
HEAD_B=2222222222222222222222222222222222222222
NOW=$(jq -n '"2026-10-30T21:00:00Z" | fromdateiso8601')
RECENT=$(jq -nr --argjson now "$NOW" '$now - 600 | todateiso8601')
PHASE1='Publisher phase 1: evaluation queued for x. <!-- required-check-publisher:pending:41:1 -->'

run_json() { # id name status started [conclusion] [details_url] [app]
  jq -cn --argjson id "$1" --arg name "$2" --arg status "$3" --arg started "$4" \
    --arg conclusion "${5:-}" --arg details "${6:-}" --arg app "${7:-github-actions}" --arg summary "$PHASE1" \
    '{id: $id, name: $name, status: $status, started_at: $started,
      conclusion: (if $conclusion == "" then null else $conclusion end),
      details_url: $details, app: {slug: $app}, output: {summary: $summary}}'
}

make_fixture() {
  local dir="$1"
  mkdir -p "$dir/bin"
  jq -cn --arg a "$HEAD_A" --arg b "$HEAD_B" '[{number: 583, head: {sha: $a}}, {number: 584, head: {sha: $b}}]' >"$dir/pulls.json"
  {
    # Reaped: the #583 shape, a newer same-name green exists.
    run_json 100 'Merge clearance gate' in_progress 2026-10-30T18:09:41Z
    run_json 200 'Merge clearance gate' completed 2026-10-30T21:34:35Z success
    # Kept: only an OLDER completed run of that name.
    run_json 50 'Codex P1 unresolved threads' completed 2026-10-30T17:00:00Z failure
    run_json 101 'Codex P1 unresolved threads' in_progress 2026-10-30T18:09:41Z
    # Kept: too young, even with a newer completion.
    run_json 102 'CodeRabbit unresolved blocking findings' in_progress "$RECENT"
    run_json 210 'CodeRabbit unresolved blocking findings' completed "$RECENT" success
    # Kept: a native Actions job run, not a Checks-API hold.
    run_json 103 'Merge clearance gate' in_progress 2026-10-30T18:00:00Z '' 'https://github.com/o/r/actions/runs/9/job/1'
    # Kept: not one of the three contexts.
    run_json 104 lint in_progress 2026-10-30T18:00:00Z
    run_json 230 lint completed 2026-10-30T19:00:00Z success
    # Kept: written by another app.
    run_json 105 'Codex P1 unresolved threads' in_progress 2026-10-30T18:00:00Z '' '' other-app
    run_json 240 'Codex P1 unresolved threads' completed 2026-10-30T19:00:00Z failure '' other-app
  } | jq -cs '{check_runs: .}' >"$dir/runs-$HEAD_A.json"
  {
    # Reaped even though the newer verdict is red: the hold is cancelled,
    # and the red stays the newest decision.
    run_json 300 'CodeRabbit unresolved blocking findings' in_progress 2026-10-30T18:09:42Z
    run_json 310 'CodeRabbit unresolved blocking findings' completed 2026-10-30T19:00:00Z failure
    # Raced: closed by its writer between listing and re-read.
    run_json 301 'Codex P1 unresolved threads' in_progress 2026-10-30T18:09:42Z
    run_json 311 'Codex P1 unresolved threads' completed 2026-10-30T19:00:00Z success
  } | jq -cs '{check_runs: .}' >"$dir/runs-$HEAD_B.json"
  cat >"$dir/bin/gh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$FIXTURE/gh.log"
[ "${1:-}" = api ] || exit 90
shift
args=" $* "
jq_filter=""
prev=""
for arg in "$@"; do
  [ "$prev" != --jq ] || jq_filter="$arg"
  prev="$arg"
done
case "$args" in
  *" -X PATCH "*)
    [ "${PATCH_MODE:-ok}" != fail ] || exit 1
    id=""; conclusion=""; title=""; summary=""; prev=""
    for arg in "$@"; do
      case "$arg" in repos/*/check-runs/*) id="${arg##*/}" ;; esac
      if [ "$prev" = -f ]; then
        case "$arg" in
          conclusion=*) conclusion="${arg#conclusion=}" ;;
          'output[title]='*) title="${arg#*=}" ;;
          'output[summary]='*) summary="${arg#*=}" ;;
        esac
      fi
      prev="$arg"
    done
    printf 'close %s %s\n' "$id" "$conclusion" >>"$FIXTURE/mutations.log"
    printf '%s\n' "$summary" >"$FIXTURE/summary-$id.log"
    printf '%s\n' "$title" >"$FIXTURE/title-$id.log"
    exit 0 ;;
  *" repos/owner/repo/pulls "*)
    [ "${PULLS_MODE:-ok}" != fail ] || exit 1
    jq -r "$jq_filter" "$FIXTURE/pulls.json"; exit 0 ;;
  *"/check-runs -f filter=all"*)
    sha="${args#*/commits/}"; sha="${sha%%/*}"
    [ "${READ_FAIL_HEAD:-}" != "$sha" ] || exit 1
    jq -c '[.]' "$FIXTURE/runs-$sha.json"; exit 0 ;;
  *" repos/owner/repo/check-runs/"*)
    id="${args#* repos/owner/repo/check-runs/}"; id="${id%% *}"
    if [ "$id" = 301 ]; then echo completed; else echo in_progress; fi
    exit 0 ;;
esac
echo "unexpected gh call: $*" >&2
exit 91
SH
  chmod +x "$dir/bin/gh"
  : >"$dir/mutations.log"
}

run_reaper() {
  local dir="$1"; shift
  set +e
  env PATH="$dir/bin:$PATH" FIXTURE="$dir" REAP_NOW_EPOCH="$NOW" "$@" \
    bash "$REAPER" owner/repo >"$dir/out" 2>&1
  local rc=$?
  set -e
  printf '%s' "$rc"
}

dir="$TMP/basic"
make_fixture "$dir"
rc=$(run_reaper "$dir")
expected=$'close 100 cancelled\nclose 300 cancelled'
if [ "$rc" -ne 0 ]; then
  fail "reaper exits 0 on a clean pass" "rc=$rc: $(cat "$dir/out")"
elif [ "$(cat "$dir/mutations.log")" != "$expected" ]; then
  fail "reaper closes exactly the superseded, aged Checks-API holds" "mutations: $(tr '\n' ' ' <"$dir/mutations.log")"
else
  pass "reaper closes exactly the superseded, aged Checks-API holds"
fi
if grep -Eq ' (success|neutral|skipped)$' "$dir/mutations.log"; then
  fail "a reaped hold is never closed with a passing conclusion"
else
  pass "a reaped hold is never closed with a passing conclusion"
fi
if [ -f "$dir/summary-100.log" ] && [ "$(head -n1 "$dir/summary-100.log")" = "$PHASE1" ] \
    && grep -Fq 'newer completed run 200' "$dir/summary-100.log" \
    && grep -Fq 'run 200' "$dir/title-100.log"; then
  pass "the reaped summary keeps the opening as its prefix and names the deciding run"
else
  fail "the reaped summary keeps the opening as its prefix and names the deciding run"
fi
if grep -q '^close 301 ' "$dir/mutations.log"; then
  fail "a hold its writer closed after the listing is left alone"
else
  pass "a hold its writer closed after the listing is left alone"
fi

dir="$TMP/read-fail"
make_fixture "$dir"
rc=$(run_reaper "$dir" READ_FAIL_HEAD="$HEAD_A")
if [ "$rc" -eq 0 ]; then
  fail "an unreadable head is reported" "rc=0"
elif [ "$(cat "$dir/mutations.log")" != 'close 300 cancelled' ]; then
  fail "an unreadable head does not stop later heads" "mutations: $(tr '\n' ' ' <"$dir/mutations.log")"
else
  pass "an unreadable head is reported and later heads are still reaped"
fi

dir="$TMP/patch-fail"
make_fixture "$dir"
rc=$(run_reaper "$dir" PATCH_MODE=fail)
if [ "$rc" -eq 0 ] || ! grep -Fq 'stays in progress' "$dir/out"; then
  fail "a failed close is reported and the hold stays" "rc=$rc"
else
  pass "a failed close is reported and the hold stays"
fi

dir="$TMP/pulls-fail"
make_fixture "$dir"
rc=$(run_reaper "$dir" PULLS_MODE=fail)
if [ "$rc" -eq 0 ] || [ -s "$dir/mutations.log" ]; then
  fail "an unreadable open-PR list reaps nothing and fails" "rc=$rc"
else
  pass "an unreadable open-PR list reaps nothing and fails"
fi

dir="$TMP/bounded"
make_fixture "$dir"
rc=$(run_reaper "$dir" REAP_MAX_CLOSES=1)
if [ "$rc" -ne 0 ] || [ "$(cat "$dir/mutations.log")" != 'close 100 cancelled' ]; then
  fail "the per-pass close bound is honoured" "rc=$rc mutations: $(tr '\n' ' ' <"$dir/mutations.log")"
else
  pass "the per-pass close bound is honoured"
fi

dir="$TMP/young"
make_fixture "$dir"
rc=$(run_reaper "$dir" REAP_MIN_AGE_SECONDS=999999)
if [ "$rc" -ne 0 ] || [ -s "$dir/mutations.log" ]; then
  fail "holds younger than the bound are never reaped" "rc=$rc"
else
  pass "holds younger than the bound are never reaped"
fi

# The call site: the shipped publish job runs the reaper on the scheduled
# full-coverage pass only, after a failed publish step too, with the job token.
if ruby - "$WORKFLOW" <<'RUBY'
require "yaml"
steps = YAML.load_file(ARGV[0]).fetch("jobs").fetch("publish").fetch("steps")
step = steps.find { |s| s["name"] == "Reap orphaned holds on open PR heads" }
abort("missing reaper step") unless step
abort("reaper must be the last publish step") unless steps.last.equal?(step)
cond = step["if"].to_s.split.join(" ")
abort("reaper condition: #{cond}") unless cond.include?("!cancelled()") &&
  cond.include?("github.event.workflow_run.event == 'schedule'") && !cond.include?("success()")
abort("reaper token") unless step.dig("env", "GH_TOKEN") == "${{ secrets.GITHUB_TOKEN }}"
abort("reaper command") unless step["run"].strip == 'scripts/workflow/reap-orphaned-holds.sh "$REPO"'
RUBY
then
  pass "the publisher's scheduled pass invokes the reaper with the job token"
else
  fail "the publisher's scheduled pass invokes the reaper with the job token"
fi

echo "reap-orphaned-holds: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
