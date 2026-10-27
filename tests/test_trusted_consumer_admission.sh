#!/usr/bin/env bash
# tests/test_trusted_consumer_admission.sh — #2727 (ADR 0004)
#
# scripts/workflow/trusted-consumer-admission.sh decides whether a trusted
# workflow_run consumer may act on the PR its producer run nominates. Every
# event field is an untrusted nomination, so each admission rule gets a case
# that must decline: a fork run, a borrowed workflow name, a wrong path or
# event, an ambiguous or missing PR, and a live PR that moved, closed,
# retargeted or turned into a cross-repository PR. Read failures fail closed.

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HELPER="$ROOT/scripts/workflow/trusted-consumer-admission.sh"
[ -f "$HELPER" ] || { echo "missing $HELPER" >&2; exit 1; }

pass=0; fail=0
ok()  { pass=$((pass + 1)); echo "  PASS: $1"; }
bad() { fail=$((fail + 1)); echo "  FAIL: $1" >&2; }

SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/tca.XXXXXX")"
trap 'rm -rf "$SCRATCH"' EXIT
STATE="$SCRATCH/state"; mkdir -p "$STATE"

H=1111111111111111111111111111111111111111
H2=3333333333333333333333333333333333333333
B=2222222222222222222222222222222222222222
RID=42

# The stub answers the calls the helper makes. It returns what gh prints after
# --jq where the helper passes one, and the raw resource where it does not.
cat > "$SCRATCH/gh" <<'GH'
#!/usr/bin/env bash
[ "$1" = api ] || exit 1
fails() { [ -f "$STATE/fail_$1" ]; }
case "$2" in
  repos/o/r) fails default && exit 1; cat "$STATE/default" ;;
  repos/o/r/actions/workflows/*) fails wf && exit 1; cat "$STATE/wf_id" ;;
  # --paginate makes gh print one JSON array per page; pulls2.json is page 2.
  --paginate)
    case "$3" in
      repos/o/r/commits/*/pulls*) fails pulls && exit 1; cat "$STATE/pulls.json"
        [ -f "$STATE/pulls2.json" ] && cat "$STATE/pulls2.json"; exit 0 ;;
    esac
    exit 1 ;;
  # pr_<n>.json, when present, is PR #n's live state; pr.json otherwise.
  repos/o/r/pulls/*) fails pr && exit 1; n="${2##*/}"
    if [ -f "$STATE/pr_$n.json" ]; then cat "$STATE/pr_$n.json"; else cat "$STATE/pr.json"; fi ;;
  *) exit 1 ;;
esac
GH
chmod +x "$SCRATCH/gh"

# reset — the happy-path world: a same-repository open PR #7 at $H on main.
reset() {
  rm -f "$STATE"/*
  echo main > "$STATE/default"
  echo 111 > "$STATE/wf_id"
  jq -n --arg h "$H" --arg b "$B" --argjson rid "$RID" \
    '{number: 7, state: "open", head: {sha: $h, repo: {id: $rid}}, base: {sha: $b, ref: "main", repo: {id: $rid}}}' \
    > "$STATE/pr.json"
  echo '[]' > "$STATE/pulls.json"
}

# event <jq filter applied to the base event>
event() {
  jq -n --arg h "$H" --argjson rid "$RID" '{action: "completed", workflow_run: {
      workflow_id: 111, path: ".github/workflows/agent-review.yml", event: "pull_request",
      head_sha: $h, head_branch: "anything", conclusion: "failure",
      head_repository: {id: $rid}, repository: {id: $rid},
      pull_requests: [{number: 7, head: {sha: $h}, base: {repo: {id: $rid}}}]}}' \
    | jq "$1" > "$STATE/event.json"
}

run() { # <args...>
  out=$(cd "$ROOT" && PATH="$SCRATCH:$PATH" STATE="$STATE" GITHUB_EVENT_PATH="$STATE/event.json" \
    GITHUB_REPOSITORY=o/r GITHUB_REPOSITORY_ID="$RID" bash "$HELPER" "$@" 2>"$STATE/err")
  rc=$?
  err=$(cat "$STATE/err")
}
admit() { run admit --producer agent-review.yml --events pull_request,pull_request_review; }
expect() { # <label> <rc> [stdout-jq-predicate]
  if [ "$rc" -eq "$2" ] && { [ -z "${3:-}" ] || jq -e "$3" <<<"$out" >/dev/null 2>&1; }; then ok "$1"
  else bad "$1 (rc=$rc, want $2; out=$out; err=$err)"; fi
}

echo "admit"
reset; event .; admit
expect "a same-repository PR run of the producer is admitted" 0 \
  '.pr == 7 and .head_sha == "'"$H"'" and .base_sha == "'"$B"'" and .base_ref == "main"'
reset; event '.workflow_run.path += "@refs/heads/main"'; admit
expect "a path with one trailing @ref is accepted" 0 '.pr == 7'
reset; event '.workflow_run.event = "pull_request_review"'; admit
expect "a listed second producer event is accepted" 0 '.pr == 7'
reset; event '.workflow_run.head_repository.id = 99'; admit
expect "a fork run is declined (invariant 9)" 3
reset; event '.workflow_run.head_repository = null'; admit
expect "a null head repository is declined" 3
reset; event 'del(.workflow_run.head_repository)'; admit
expect "an absent head repository is declined" 3
reset; event '.workflow_run.repository.id = 99'; admit
expect "a run of another repository is declined" 3
reset; event '.action = "requested"'; admit
expect "a run that has not completed is declined" 3
reset; event '.workflow_run.event = "pull_request_target"'; admit
expect "an event the producer does not trigger on is declined" 3
reset; event '.workflow_run.workflow_id = 222'; admit
expect "a borrowed producer name (another workflow id) is declined" 3
reset; event '.workflow_run.path = ".github/workflows/agent-review.yml.evil"'; admit
expect "a path that only starts with the producer path is declined" 3
reset; event '.workflow_run.path = ".github/workflows/evil.yml@refs/heads/main"'; admit
expect "another workflow file is declined" 3
reset; event '.workflow_run.path = ".github/workflows/agent-review.yml@a@b"'; admit
expect "only one trailing @ref is removed" 3
reset; event '.workflow_run.head_sha = "abc"'; admit
expect "a malformed head SHA is declined" 3
grep -q "head_sha is not 40 hex" <<<"$err" && ok "a malformed head SHA is declined for that reason, before any PR lookup" \
  || bad "malformed head SHA reason (err=$err)"
reset; event 'del(.workflow_run)'; admit
expect "a non-workflow_run event is declined" 3

echo "nomination"
reset; event '.workflow_run.pull_requests = []'
jq -n --arg h "$H" --argjson rid "$RID" '[{number: 7, state: "open", head: {sha: $h, repo: {id: $rid}}, base: {repo: {id: $rid}}}]' > "$STATE/pulls.json"
admit
expect "an empty pull_requests list resolves the PR from the commit" 0 '.pr == 7'
reset; event '.workflow_run.pull_requests = []'
jq -n --arg h "$H" --argjson rid "$RID" '[{number: 9, state: "open", head: {sha: $h, repo: {id: 99}}, base: {repo: {id: $rid}}}]' > "$STATE/pulls.json"
admit
expect "a commit whose only PR is a fork PR is declined" 3
reset; event '.workflow_run.pull_requests = []'
jq -n --arg h "$H" --argjson rid "$RID" '[{number: 7, state: "open", head: {sha: $h, repo: {id: $rid}}, base: {repo: {id: $rid}}},
  {number: 8, state: "open", head: {sha: $h, repo: {id: $rid}}, base: {repo: {id: $rid}}}]' > "$STATE/pulls.json"
admit
expect "two PRs with the same head are declined, not chosen between" 3
reset; event '.workflow_run.pull_requests = []'; admit
expect "no PR for the commit is declined" 3
reset; event '.workflow_run.pull_requests = []'
jq -n --arg h "$H2" --argjson rid "$RID" '[range(0; 30) | {number: (100 + .), state: "open", head: {sha: $h, repo: {id: $rid}}, base: {repo: {id: $rid}}}]' > "$STATE/pulls.json"
jq -n --arg h "$H" --argjson rid "$RID" '[{number: 7, state: "open", head: {sha: $h, repo: {id: $rid}}, base: {repo: {id: $rid}}}]' > "$STATE/pulls2.json"
admit
expect "a qualifying PR on a later page of the commit lookup is found" 0 '.pr == 7'
reset; event '.workflow_run.pull_requests = []'
jq -n --arg h "$H" --argjson rid "$RID" '[{number: 7, state: "open", head: {sha: $h, repo: {id: $rid}}, base: {repo: {id: $rid}}}]' > "$STATE/pulls.json"
jq -n --arg h "$H" --argjson rid "$RID" '[{number: 8, state: "open", head: {sha: $h, repo: {id: $rid}}, base: {repo: {id: $rid}}}]' > "$STATE/pulls2.json"
admit
expect "a second qualifying PR on a later page makes the nomination ambiguous" 3
reset; event '.workflow_run.pull_requests = [{number: 5, head: {sha: "'"$H"'"}, base: {repo: {id: 99}}}]'
jq -n --arg h "$H" --argjson rid "$RID" '[{number: 7, state: "open", head: {sha: $h, repo: {id: $rid}}, base: {repo: {id: $rid}}}]' > "$STATE/pulls.json"
admit
expect "a pull_requests entry for another base repository is ignored" 0 '.pr == 7'
reset; event '.workflow_run.pull_requests = [{number: 5, head: {sha: "'"$H2"'"}, base: {repo: {id: '"$RID"'}}}]'; admit
expect "a pull_requests entry for another head is ignored" 3

echo "live nomination (#2823, #2822 item 1)"
# open_pr <n> [state]: a same-repository PR at $H, as the commit lookup and
# the live read both print it.
open_pr() {
  jq -n --argjson n "$1" --arg s "${2:-open}" --arg h "$H" --arg b "$B" --argjson rid "$RID" \
    '{number: $n, state: $s, head: {sha: $h, repo: {id: $rid}}, base: {sha: $b, ref: "main", repo: {id: $rid}}}'
}
two_nominated='.workflow_run.pull_requests = [{number: 7, head: {sha: "'"$H"'"}, base: {repo: {id: '"$RID"'}}},
  {number: 8, head: {sha: "'"$H"'"}, base: {repo: {id: '"$RID"'}}}]'
reset; event "$two_nominated"; open_pr 8 closed > "$STATE/pr_8.json"; open_pr 7 | jq -s . > "$STATE/pulls.json"; admit
expect "a snapshot PR that closed later does not decline the one still open" 0 '.pr == 7'
reset; event .; { open_pr 7; open_pr 8; } | jq -s . > "$STATE/pulls.json"; open_pr 8 > "$STATE/pr_8.json"; admit
expect "a second same-head PR opened after the snapshot makes the nomination ambiguous" 3
grep -q "more than one open PR" <<<"$err" && ok "the late second PR is declined as ambiguous" \
  || bad "late second PR reason (err=$err)"
reset; event .; open_pr 7 closed > "$STATE/pr_7.json"; open_pr 8 | jq -s . > "$STATE/pulls.json"; open_pr 8 > "$STATE/pr_8.json"; admit
expect "a live PR the event did not nominate is declined" 3
grep -q "which the event did not nominate" <<<"$err" && ok "an unnominated live PR is declined for that reason" \
  || bad "unnominated live PR reason (err=$err)"
reset; event .; admit
expect "a nominated open PR the commit lookup does not list yet is admitted" 0 '.pr == 7'
reset; event .; touch "$STATE/fail_pulls"; admit
expect "an unreadable commit lookup exits 4 even with a nonempty snapshot" 4

echo "live PR"
reset; event .; jq --arg h "$H2" '.head.sha = $h' "$STATE/pr.json" > "$STATE/x" && mv "$STATE/x" "$STATE/pr.json"; admit
expect "a live head that moved is declined" 3
reset; event .; jq '.base.ref = "release"' "$STATE/pr.json" > "$STATE/x" && mv "$STATE/x" "$STATE/pr.json"; admit
expect "a PR targeting another branch is declined" 3
reset; event .; jq '.state = "closed"' "$STATE/pr.json" > "$STATE/x" && mv "$STATE/x" "$STATE/pr.json"; admit
expect "a closed PR is declined" 3
reset; event .; jq '.head.repo.id = 99' "$STATE/pr.json" > "$STATE/x" && mv "$STATE/x" "$STATE/pr.json"; admit
expect "a live cross-repository PR is declined" 3
reset; event .; jq '.head.repo = null' "$STATE/pr.json" > "$STATE/x" && mv "$STATE/x" "$STATE/pr.json"; admit
expect "a live PR whose head repository is gone is declined" 3

echo "read failures fail closed"
reset; event .; touch "$STATE/fail_wf"; admit
expect "an unreadable workflow id exits 4" 4
reset; event .; touch "$STATE/fail_pr"; admit
expect "an unreadable live PR exits 4" 4
reset; event .; touch "$STATE/fail_default"; admit
expect "an unreadable default branch exits 4" 4
reset; event '.workflow_run.pull_requests = []'; touch "$STATE/fail_pulls"; admit
expect "an unreadable commit-to-PR lookup exits 4" 4
reset; event .; echo "" > "$STATE/wf_id"; admit
expect "an empty workflow id exits 4" 4

echo "recheck"
reset; run recheck --pr 7 --head "$H" --base "$B"
expect "the held pair passes" 0
reset; run recheck --pr 7 --head "$H" --base "$H2"
expect "a moved base is declined" 3
reset; run recheck --pr 7 --head "$H2" --base "$B"
expect "a moved head is declined" 3
reset; jq '.state = "closed"' "$STATE/pr.json" > "$STATE/x" && mv "$STATE/x" "$STATE/pr.json"; run recheck --pr 7 --head "$H" --base "$B"
expect "a PR closed since admission is declined" 3
reset; jq '.base.ref = "release"' "$STATE/pr.json" > "$STATE/x" && mv "$STATE/x" "$STATE/pr.json"; run recheck --pr 7 --head "$H" --base "$B"
expect "a PR retargeted since admission is declined" 3
reset; touch "$STATE/fail_pr"; run recheck --pr 7 --head "$H" --base "$B"
expect "an unreadable PR at recheck exits 4" 4

echo "usage"
reset; event .; run admit --producer agent-review.yml
expect "admit without --events is a usage error" 1
reset; run recheck --pr 7 --head abc --base "$B"
expect "recheck with a malformed SHA is a usage error" 1
reset; event .
# GitHub Actions sets GITHUB_REPOSITORY_ID for every step, so unset it here
# or this case would inherit the runner's value (Codex on #2818).
out=$(cd "$ROOT" && env -u GITHUB_REPOSITORY_ID PATH="$SCRATCH:$PATH" STATE="$STATE" GITHUB_EVENT_PATH="$STATE/event.json" \
  GITHUB_REPOSITORY=o/r bash "$HELPER" admit --producer agent-review.yml --events pull_request 2>/dev/null); rc=$?
expect "a missing GITHUB_REPOSITORY_ID is a usage error" 1

echo
echo "test_trusted_consumer_admission: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
