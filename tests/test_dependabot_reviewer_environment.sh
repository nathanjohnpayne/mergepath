#!/usr/bin/env bash
# tests/test_dependabot_reviewer_environment.sh
#
# Regression coverage for #2729: the Dependabot approval PAT lives in its own
# `dependabot-reviewer` environment and is read by one job only.
#
# Structural half (parsed YAML, not text greps): .github/workflows/
# dependabot-auto-merge.yml has exactly an `approve` job on
# `dependabot-reviewer` and a `merge` job on `merge-queue-policy`; both carry
# the base-is-default guard; DEPENDABOT_REVIEWER_TOKEN is referenced once, by
# the approve step, under a name no call uses implicitly; no reviewer secret
# reaches the merge job and no author secret reaches the approve job.
#
# Behavioral half: the live approve step and the merge step's
# require_exact_head_approval run against a PATH-shimmed gh. Cases: a missing
# secret, an unresolvable or wrong identity, self-approval, human-hold, a
# changed head (the approval reads back on another SHA, or the head moved
# before the merge), a base retargeted off the default branch, an empty head
# read, a dismissed approval (also across review pages), an exact-head
# approval held only by another allowlisted login, and the happy paths.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKFLOW="$ROOT/.github/workflows/dependabot-auto-merge.yml"

[ -r "$WORKFLOW" ] || { echo "missing workflow: $WORKFLOW" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not available" >&2; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "SKIP: python3 not available" >&2; exit 0; }

PASS=0
FAIL=0
pass() { echo "PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $*" >&2; FAIL=$((FAIL + 1)); }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/dependabot-reviewer-env.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# ---------------------------------------------------------------------------
# Structural checks, on the parsed workflow (PyYAML, else mikefarah yq; the
# suite fails rather than skipping when neither parses it). The script also
# writes the approve step's `run:` body to $WORK/approve.sh for the
# behavioral half, so both halves test the same parsed file.
# ---------------------------------------------------------------------------
set +e
structural=$(python3 - "$WORKFLOW" "$WORK/approve.sh" "$WORK" <<'PY'
import json
import re
import subprocess
import sys

text = open(sys.argv[1]).read()
try:
    import yaml
    doc = yaml.safe_load(text)
except ImportError:
    doc = json.loads(subprocess.run(['yq', '-o=json', '.', '-'], input=text, capture_output=True,
                                    text=True, check=True).stdout)
jobs = doc.get('jobs') or {}
results = []

def check(ok, name):
    results.append(('PASS' if ok else 'FAIL') + ': ' + name)

def secrets_in(node):
    return set(re.findall(r'secrets\.([A-Za-z0-9_]+)', json.dumps(node)))

check(sorted(jobs) == ['approve', 'merge'], 'the workflow has exactly the approve and merge jobs (got %s)' % sorted(jobs))
approve = jobs.get('approve') or {}
merge = jobs.get('merge') or {}

check(approve.get('environment') == 'dependabot-reviewer', 'approve names the dependabot-reviewer environment')
check(merge.get('environment') == 'merge-queue-policy', 'merge names the merge-queue-policy environment')

author_gate = "github.event.pull_request.user.login == 'dependabot[bot]'"
base_guard = 'github.event.pull_request.base.ref == github.event.repository.default_branch'
for name, job in (('approve', approve), ('merge', merge)):
    cond = ' '.join(str(job.get('if', '')).split())
    check(author_gate in cond and base_guard in cond,
          '%s carries the PR-author gate and the base-is-default guard' % name)
    refs = [((s.get('with') or {}).get('ref')) for s in job.get('steps') or []
            if str(s.get('uses', '')).startswith('actions/checkout@')]
    check(refs == ['${{ github.event.pull_request.base.sha }}'],
          '%s checks out only pull_request.base.sha (got %s)' % (name, refs))
    for s in job.get('steps') or []:
        if 'actions/checkout@' in str(s.get('uses', '')):
            check((s.get('with') or {}).get('persist-credentials') is False,
                  '%s checkout does not persist credentials' % name)

check(merge.get('needs') == 'approve', 'merge needs approve')
check("needs.approve.outputs.merge == 'true'" in str(merge.get('if', '')),
      "merge runs only when approve reports merge == 'true'")

# The reviewer PAT: one textual reference in the whole file, in the approve
# job, bound to REVIEWER_TOKEN (never GH_TOKEN, so no gh call uses it
# implicitly).
check(len(re.findall(r'secrets\.DEPENDABOT_REVIEWER_TOKEN', text)) == 1,
      'DEPENDABOT_REVIEWER_TOKEN is referenced exactly once')
holders = [(s.get('name'), k) for s in approve.get('steps') or []
           for k, v in (s.get('env') or {}).items()
           if 'secrets.DEPENDABOT_REVIEWER_TOKEN' in str(v)]
check(len(holders) == 1 and holders[0][1] == 'REVIEWER_TOKEN',
      'only the approve step holds it, as REVIEWER_TOKEN (got %s)' % holders)
check('secrets.REVIEWER_ASSIGNMENT_TOKEN' not in text,
      'the shared REVIEWER_ASSIGNMENT_TOKEN is no longer read')
check(secrets_in(approve) <= {'DEPENDABOT_REVIEWER_TOKEN', 'GITHUB_TOKEN'},
      'approve reads no secret but the reviewer PAT and GITHUB_TOKEN (got %s)' % sorted(secrets_in(approve)))
check(secrets_in(merge) <= {'AUTHOR_MERGE_TOKEN', 'GITHUB_TOKEN'},
      'merge reads no secret but the author token and GITHUB_TOKEN (got %s)' % sorted(secrets_in(merge)))
check(not (doc.get('env') or {}) and not (approve.get('env') or {}) and not (merge.get('env') or {}),
      'no workflow- or job-level env can leak a secret into other steps')
for name, job in (('approve', approve), ('merge', merge)):
    for s in job.get('steps') or []:
        gh = (s.get('env') or {}).get('GH_TOKEN')
        if gh is not None:
            check(gh == '${{ secrets.GITHUB_TOKEN }}',
                  '%s step %r defaults gh to GITHUB_TOKEN' % (name, s.get('name')))

perms = doc.get('permissions') or {}
check(perms.get('checks') == 'read', 'GITHUB_TOKEN can read check runs for the merge wait')
check('id-token' not in perms and all('id-token' not in (j.get('permissions') or {}) for j in jobs.values()),
      'no job requests id-token (ADR 0004: never on pull_request_target)')

steps = {s.get('id'): s for s in approve.get('steps') or [] if s.get('id')}
run = (steps.get('approve') or {}).get('run', '')
open(sys.argv[2], 'w').write(run)
check('REVIEWER_TOKEN' in run, 'extracted the live approve step')

merge_run = '\n'.join(s.get('run', '') for s in merge.get('steps') or [])
# Every merge call, --auto and the fallback squash alike, must be preceded,
# after the CI wait that pinned its SHA, by the provenance re-check, the
# exact-head approval re-read and a human-hold re-read.
merges = [m.start() for m in re.finditer(r'gh pr merge --squash', merge_run)]
ordered = len(merges) == 2
for at in merges:
    wait = merge_run.rfind('require_current_head_checks_success\n', 0, at)
    window = merge_run[wait:at] if wait >= 0 else ''
    ordered = ordered and all(call in window for call in (
        'require_dependabot_provenance "$CURRENT_HEAD_SHA"',
        'require_exact_head_approval "$CURRENT_HEAD_SHA"',
        'if has_human_hold; then'))
# And the approval/base re-read is the last check before each write:
# nothing but comments and the `set +e` wrapper may separate them, so
# slow work (feedback accounting) cannot slip in between.
for at in merges:
    last = merge_run.rfind('require_exact_head_approval "$CURRENT_HEAD_SHA"', 0, at)
    gap = [line.strip() for line in merge_run[last:at].splitlines()[1:]
           if line.strip() and not line.strip().startswith('#')]
    ordered = ordered and last >= 0 and all(
        line in ('set +e', 'AUTO_STDERR=$(GH_TOKEN="$AUTHOR_MERGE_TOKEN"', 'GH_TOKEN="$AUTHOR_MERGE_TOKEN"') for line in gap)
first_check = merge_run.find('require_exact_head_approval "$FIRST_HEAD"')
first_wait = merge_run.find('require_current_head_checks_success\n')
check(ordered and 0 <= first_check < first_wait,
      'merge re-reads the exact-head approval before the CI wait, and re-checks provenance, approval and human-hold before each merge path')
outs = approve.get('outputs') or {}
check(all(k in outs for k in ('approved_sha', 'approved_by', 'merge')),
      'approve exports approved_sha, approved_by and merge')

# #2823: Actions `==` ignores case, so the job `if:` admits a base named
# `Main`. Each job's first step must repeat the comparison exactly, hold no
# secret, run no action, and no later step may opt back in after a failure;
# its `run:` is written to $WORK/guard-<job>.sh for the behavioral half.
for name, job in (('approve', approve), ('merge', merge)):
    steps_list = job.get('steps') or []
    first = steps_list[0] if steps_list else {}
    env = first.get('env') or {}
    check('uses' not in first and 'if' not in first and env == {
              'BASE_REF': '${{ github.event.pull_request.base.ref }}',
              'DEFAULT_BRANCH': '${{ github.event.repository.default_branch }}'}
          and '"$BASE_REF" != "$DEFAULT_BRANCH"' in first.get('run', ''),
          '%s first step is the exact base guard, before any checkout or secret' % name)
    reopen = [s.get('name') or s.get('uses') for s in steps_list[1:]
              if re.search(r'always\(\)|failure\(\)|cancelled\(\)', str(s.get('if', '')))
              or s.get('continue-on-error')]
    check(not reopen and not job.get('continue-on-error'),
          '%s: no step after the guard runs once it fails (got %s)' % (name, reopen))
    open('%s/guard-%s.sh' % (sys.argv[3], name), 'w').write(first.get('run', ''))
print('\n'.join(results))
PY
)
rc=$?
set -e
if [ "$rc" -ne 0 ]; then
  fail "structural checks could not run (rc=$rc): $structural"
fi
while IFS= read -r line; do
  case "$line" in
    PASS:*) pass "${line#PASS: }" ;;
    FAIL:*) fail "${line#FAIL: }" ;;
  esac
done <<<"$structural"

# ---------------------------------------------------------------------------
# Behavioral: the exact base guard (#2823). Run as Actions runs `run:`
# (bash -e). A `Main` base must fail it in both jobs, so the token-holding
# steps after it never run; the exact default branch passes.
# ---------------------------------------------------------------------------
for job in approve merge; do
  guard="$WORK/guard-$job.sh"
  for base in Main MAIN main- '' refs/heads/main; do
    if BASE_REF="$base" DEFAULT_BRANCH=main bash -e "$guard" >/dev/null 2>&1; then
      fail "$job guard admits base '$base' for default branch 'main'"
    else
      pass "$job guard refuses base '$base' for default branch 'main'"
    fi
  done
  if BASE_REF=main DEFAULT_BRANCH=main bash -e "$guard" >/dev/null 2>&1; then
    pass "$job guard admits the exact default branch"
  else
    fail "$job guard refuses the exact default branch"
  fi
done

# ---------------------------------------------------------------------------
# Behavioral: the approve step. A sandbox holds the base checkout's pieces the
# step reads: scripts/lib and a review policy.
# ---------------------------------------------------------------------------
BOX="$WORK/box"
mkdir -p "$BOX/bin" "$BOX/scripts/lib" "$BOX/.github"
cp "$ROOT/scripts/lib/gh-api-array.sh" "$ROOT/scripts/lib/dependabot-commit-provenance.sh" "$BOX/scripts/lib/"
cat >"$BOX/.github/review-policy.yml" <<'YAML'
author_identity: nathanjohnpayne
available_reviewers:
  - nathanpayne-claude
  - nathanpayne-codex
YAML

HEAD_SHA=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
OTHER_SHA=cccccccccccccccccccccccccccccccccccccccc
jq -nc --arg sha "$HEAD_SHA" \
  '[{sha:$sha, author:{login:"dependabot[bot]"}, committer:{login:"web-flow"}, commit:{verification:{verified:true}}}]' \
  >"$BOX/commits.json"

# Every call is logged with the token it ran under, so the suite can prove
# the reviewer PAT reached exactly two calls.
cat >"$BOX/bin/gh" <<'SHIM'
#!/usr/bin/env bash
set -euo pipefail
printf '%s|%s\n' "${GH_TOKEN:-<unset>}" "$*" >>"$SHIM_LOG"
case "$*" in
  "api user --jq .login")
    [ "${GH_TOKEN:-}" = reviewer-pat ] || { echo "gh shim: user read under ${GH_TOKEN:-<unset>}" >&2; exit 94; }
    printf '%s\n' "$SHIM_LOGIN"
    ;;
  "api --paginate repos/owner/repo/pulls/1/commits?per_page=100"*)
    cat "$SHIM_COMMITS"
    ;;
  "pr view "*"--json labels"*)
    [ -z "${SHIM_LABELS:-}" ] || printf '%s\n' "$SHIM_LABELS"
    ;;
  "pr view "*"--json headRefOid,baseRefName"*)
    printf '%s %s\n' "$SHIM_HEAD" "${SHIM_BASE:-main}"
    ;;
  "pr view "*"--json headRefOid"*)
    printf '%s\n' "$SHIM_HEAD"
    ;;
  "pr view "*"--json autoMergeRequest"*)
    echo false
    ;;
  "api -X POST repos/owner/repo/pulls/1/reviews "*)
    [ "${GH_TOKEN:-}" = reviewer-pat ] || { echo "gh shim: approval under ${GH_TOKEN:-<unset>}" >&2; exit 95; }
    echo 77
    ;;
  "api repos/owner/repo/pulls/1/reviews/77 "*)
    printf '%s\n' "$SHIM_RECORDED"
    ;;
  *) echo "gh shim: unexpected command: $*" >&2; exit 93 ;;
esac
SHIM
chmod +x "$BOX/bin/gh"

run_approve() {  # <reviewer_token> <login> [update_type] [labels] [recorded]; SHIM_BASE/SHIM_HEAD override
  : >"$BOX/gh.log"
  : >"$BOX/output"
  ( cd "$BOX" && PATH="$BOX/bin:$PATH" SHIM_LOG="$BOX/gh.log" SHIM_COMMITS="$BOX/commits.json" \
      SHIM_LOGIN="$2" SHIM_LABELS="${4:-}" SHIM_HEAD="${SHIM_HEAD-$HEAD_SHA}" SHIM_BASE="${SHIM_BASE:-main}" \
      DEFAULT_BRANCH=main \
      SHIM_RECORDED="${5:-APPROVED $HEAD_SHA $2}" \
      GITHUB_OUTPUT="$BOX/output" GITHUB_REPOSITORY=owner/repo \
      PR_URL=https://example.test/owner/repo/pull/1 PR_NUMBER=1 PR_AUTHOR='dependabot[bot]' \
      UPDATE_TYPE="${3:-version-update:semver-patch}" DEPENDENCY_GROUP= \
      GH_TOKEN=github-token REVIEWER_TOKEN="$1" \
      bash "$WORK/approve.sh" )
}
posted() { grep -Fq '|api -X POST repos/owner/repo/pulls/1/reviews' "$BOX/gh.log"; }

set +e
out=$(run_approve "" nathanpayne-claude 2>&1); rc=$?
set -e
if [ "$rc" -eq 1 ] && ! posted && [ ! -s "$BOX/output" ] \
   && [[ "$out" == *"DEPENDABOT_REVIEWER_TOKEN is unavailable from the dependabot-reviewer environment"* ]]; then
  pass "approve: missing secret fails closed before any call, with no outputs"
else
  fail "approve: missing secret rc=$rc output=$(cat "$BOX/output"): $out"
fi

set +e
out=$(run_approve reviewer-pat "" 2>&1); rc=$?
set -e
if [ "$rc" -eq 1 ] && ! posted && [[ "$out" == *"DEPENDABOT_REVIEWER_TOKEN may be invalid"* ]]; then
  pass "approve: an unresolvable token fails closed without approving"
else
  fail "approve: unresolvable token rc=$rc: $out"
fi

set +e
out=$(run_approve reviewer-pat some-contractor 2>&1); rc=$?
set -e
if [ "$rc" -eq 1 ] && ! posted && [ ! -s "$BOX/output" ] \
   && [[ "$out" == *"resolves to 'some-contractor', which is NOT in .github/review-policy.yml available_reviewers"* ]]; then
  pass "approve: a wrong identity fails closed without approving"
else
  fail "approve: wrong identity rc=$rc: $out"
fi

set +e
out=$(run_approve reviewer-pat 'dependabot[bot]' 2>&1); rc=$?
set -e
if [ "$rc" -eq 1 ] && ! posted && [[ "$out" == *"the PR's own author"* ]]; then
  pass "approve: a token resolving to the PR author fails closed"
else
  fail "approve: self-approval rc=$rc: $out"
fi

set +e
out=$(run_approve reviewer-pat nathanpayne-claude version-update:semver-patch human-hold 2>&1); rc=$?
set -e
if [ "$rc" -eq 0 ] && ! posted && [ ! -s "$BOX/output" ] && [[ "$out" == *"human-hold"* ]]; then
  pass "approve: human-hold stops before approving, with no outputs"
else
  fail "approve: human-hold rc=$rc output=$(cat "$BOX/output"): $out"
fi

set +e
out=$(run_approve reviewer-pat nathanpayne-claude 2>&1); rc=$?
set -e
reviewer_calls=$(grep -c '^reviewer-pat|' "$BOX/gh.log" || true)
if [ "$rc" -eq 0 ] \
   && grep -Fq "reviewer-pat|api -X POST repos/owner/repo/pulls/1/reviews -f commit_id=$HEAD_SHA -f event=APPROVE" "$BOX/gh.log" \
   && [ "$reviewer_calls" -eq 2 ] \
   && grep -Fxq "approved_sha=$HEAD_SHA" "$BOX/output" \
   && grep -Fxq 'approved_by=nathanpayne-claude' "$BOX/output" \
   && grep -Fxq 'merge=true' "$BOX/output"; then
  pass "approve: patch bump approved on the exact head, read back, merge=true; the PAT ran exactly two calls"
else
  fail "approve: happy path rc=$rc reviewer_calls=$reviewer_calls output=$(cat "$BOX/output") log=$(cat "$BOX/gh.log"): $out"
fi

set +e
out=$(run_approve reviewer-pat nathanpayne-claude version-update:semver-major 2>&1); rc=$?
set -e
if [ "$rc" -eq 0 ] && posted && grep -Fxq "approved_sha=$HEAD_SHA" "$BOX/output" \
   && grep -Fxq 'merge=false' "$BOX/output" && ! grep -Fxq 'merge=true' "$BOX/output"; then
  pass "approve: a major dev-group bump is approved but the merge job is not started"
else
  fail "approve: major dev-group rc=$rc output=$(cat "$BOX/output"): $out"
fi

set +e
out=$(run_approve reviewer-pat nathanpayne-claude version-update:semver-patch "" "APPROVED $OTHER_SHA nathanpayne-claude" 2>&1); rc=$?
set -e
if [ "$rc" -eq 1 ] && [ ! -s "$BOX/output" ] && [[ "$out" == *"reads back as 'APPROVED $OTHER_SHA nathanpayne-claude'"* ]]; then
  pass "approve: an approval that reads back on another head fails closed with no outputs"
else
  fail "approve: changed-head read-back rc=$rc output=$(cat "$BOX/output"): $out"
fi

set +e
out=$(SHIM_BASE=release run_approve reviewer-pat nathanpayne-claude 2>&1); rc=$?
set -e
if [ "$rc" -eq 1 ] && ! posted && [ ! -s "$BOX/output" ] \
   && [[ "$out" == *"PR base is now 'release', not the default branch 'main'"* ]]; then
  pass "approve: a base retargeted off the default branch since the event fails closed without approving"
else
  fail "approve: retargeted base rc=$rc output=$(cat "$BOX/output"): $out"
fi

set +e
out=$(SHIM_HEAD= run_approve reviewer-pat nathanpayne-claude 2>&1); rc=$?
set -e
if [ "$rc" -eq 1 ] && ! posted && [[ "$out" == *"Could not resolve the PR head SHA"* ]]; then
  pass "approve: an empty head read fails closed without approving"
else
  fail "approve: empty head rc=$rc: $out"
fi

# ---------------------------------------------------------------------------
# Behavioral: the merge job's require_exact_head_approval.
# ---------------------------------------------------------------------------
awk '
  /^[[:space:]]*require_exact_head_approval\(\)[[:space:]]*\{/ { capture = 1; match($0, /^[[:space:]]*/); indent = RLENGTH }
  capture { print (length($0) >= indent ? substr($0, indent + 1) : "") }
  capture && /^[[:space:]]*}[[:space:]]*$/ { exit }
' "$WORKFLOW" >"$WORK/exact.sh"
if grep -Fq 'require_exact_head_approval()' "$WORK/exact.sh"; then
  pass "extracted the live require_exact_head_approval"
else
  fail "could not extract require_exact_head_approval from the workflow"
fi

cat >"$WORK/reviews-gh" <<'SHIM'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$SHIM_LOG"
case "$*" in
  "api --paginate repos/owner/repo/pulls/1/reviews?per_page=100")
    [ "${SHIM_REVIEWS_FAIL:-}" != 1 ] || { echo "HTTP 502" >&2; exit 1; }
    cat "$SHIM_REVIEWS"
    ;;
  "pr view https://example.test/owner/repo/pull/1 --json baseRefName --jq .baseRefName")
    [ "${SHIM_BASE_FAIL:-}" != 1 ] || { echo "HTTP 502" >&2; exit 1; }
    printf '%s\n' "${SHIM_BASE:-main}"
    ;;
  *) echo "gh shim: unexpected command: $*" >&2; exit 93 ;;
esac
SHIM
mkdir -p "$WORK/rbin"
mv "$WORK/reviews-gh" "$WORK/rbin/gh"
chmod +x "$WORK/rbin/gh"

review() {  # <login> <state> <sha>
  jq -nc --arg l "$1" --arg s "$2" --arg c "$3" '{user:{login:$l}, state:$s, commit_id:$c}'
}

run_exact() {  # <sha> <approved_by> <reviews_json, one page per line> [fail]; SHIM_BASE*/APPROVED_SHA override
  printf '%s\n' "$3" >"$WORK/reviews.json"
  : >"$WORK/rgh.log"
  ( PATH="$WORK/rbin:$PATH" SHIM_LOG="$WORK/rgh.log" SHIM_REVIEWS="$WORK/reviews.json" SHIM_REVIEWS_FAIL="${4:-}" \
      SHIM_BASE="${SHIM_BASE:-main}" SHIM_BASE_FAIL="${SHIM_BASE_FAIL:-}" DEFAULT_BRANCH=main \
      GITHUB_REPOSITORY=owner/repo PR_NUMBER=1 PR_URL=https://example.test/owner/repo/pull/1 \
      APPROVED_SHA="${APPROVED_SHA-$HEAD_SHA}" APPROVED_BY="$2" POLICY=.github/review-policy.yml \
      ALLOWED=$'nathanpayne-claude\nnathanpayne-codex' \
      bash -c 'set -euo pipefail
. "$1"
require_exact_head_approval "$2"
echo CONTINUED' _ "$WORK/exact.sh" "$1" )
}

set +e
out=$(run_exact "$OTHER_SHA" nathanpayne-claude '[]' 2>&1); rc=$?
set -e
if [ "$rc" -eq 0 ] && [[ "$out" != *CONTINUED* ]] && [ ! -s "$WORK/rgh.log" ] \
   && [[ "$out" == *"approve job approved $HEAD_SHA; not merging"* ]]; then
  pass "merge: a head that moved off the approved SHA stops the run without merging"
else
  fail "merge: moved head rc=$rc: $out"
fi

set +e
out=$(run_exact "$HEAD_SHA" nathanpayne-claude \
  "[$(review nathanpayne-codex COMMENTED "$HEAD_SHA"),$(review nathanpayne-claude APPROVED "$HEAD_SHA"),$(review nathanpayne-claude COMMENTED "$HEAD_SHA")]" 2>&1); rc=$?
set -e
if [ "$rc" -eq 0 ] && [[ "$out" == *CONTINUED* ]]; then
  pass "merge: a standing approval on the exact head lets the merge continue"
else
  fail "merge: standing approval rc=$rc: $out"
fi

set +e
out=$(run_exact "$HEAD_SHA" nathanpayne-claude \
  "[$(review nathanpayne-claude APPROVED "$HEAD_SHA"),$(review nathanpayne-claude DISMISSED "$HEAD_SHA")]" 2>&1); rc=$?
set -e
if [ "$rc" -eq 1 ] && [[ "$out" != *CONTINUED* ]] && [[ "$out" == *"latest review reads 'DISMISSED $HEAD_SHA'"* ]]; then
  pass "merge: a dismissed approval fails closed"
else
  fail "merge: dismissed rc=$rc: $out"
fi

set +e
out=$(run_exact "$HEAD_SHA" nathanpayne-claude "[$(review nathanpayne-claude APPROVED "$OTHER_SHA")]" 2>&1); rc=$?
set -e
if [ "$rc" -eq 1 ] && [[ "$out" != *CONTINUED* ]]; then
  pass "merge: an approval only on another commit fails closed"
else
  fail "merge: stale-commit approval rc=$rc: $out"
fi

set +e
out=$(run_exact "$HEAD_SHA" some-contractor "[$(review some-contractor APPROVED "$HEAD_SHA")]" 2>&1); rc=$?
set -e
if [ "$rc" -eq 1 ] && [[ "$out" != *CONTINUED* ]] && [ ! -s "$WORK/rgh.log" ]; then
  pass "merge: an approver outside available_reviewers fails closed"
else
  fail "merge: non-allowlisted approver rc=$rc: $out"
fi

# The approval is bound to APPROVED_BY, not to any allowlisted login (#2822
# item 4): when the approve job reported nathanpayne-claude, an exact-head
# APPROVED held only by nathanpayne-codex (also in available_reviewers) must
# not stand in for it.
set +e
out=$(run_exact "$HEAD_SHA" nathanpayne-claude \
  "[$(review nathanpayne-codex APPROVED "$HEAD_SHA"),$(review nathanpayne-claude COMMENTED "$HEAD_SHA")]" 2>&1); rc=$?
set -e
if [ "$rc" -eq 1 ] && [[ "$out" != *CONTINUED* ]] \
   && [[ "$out" == *"nathanpayne-claude's latest review reads ' ', expected 'APPROVED $HEAD_SHA'"* ]]; then
  pass "merge: another allowlisted login's exact-head approval does not satisfy APPROVED_BY"
else
  fail "merge: APPROVED_BY mismatch rc=$rc: $out"
fi

set +e
out=$(run_exact "$HEAD_SHA" nathanpayne-claude '[]' 1 2>&1); rc=$?
set -e
if [ "$rc" -eq 1 ] && [[ "$out" != *CONTINUED* ]] && [[ "$out" == *"Could not read the reviews"* ]]; then
  pass "merge: an unreadable review list fails closed"
else
  fail "merge: unreadable reviews rc=$rc: $out"
fi

# gh --paginate prints one JSON array per page; the reader must flatten
# them and take the approver's latest review across pages.
set +e
out=$(run_exact "$HEAD_SHA" nathanpayne-claude \
  "[$(review nathanpayne-claude APPROVED "$HEAD_SHA")]
[$(review nathanpayne-claude DISMISSED "$HEAD_SHA")]" 2>&1); rc=$?
set -e
if [ "$rc" -eq 1 ] && [[ "$out" == *"latest review reads 'DISMISSED $HEAD_SHA'"* ]]; then
  pass "merge: a dismissal on a later review page wins over an approval on an earlier one"
else
  fail "merge: paginated dismissal rc=$rc: $out"
fi

set +e
out=$(run_exact "$HEAD_SHA" nathanpayne-claude \
  "[$(review nathanpayne-claude APPROVED "$OTHER_SHA")]
[$(review nathanpayne-claude APPROVED "$HEAD_SHA")]" 2>&1); rc=$?
set -e
if [ "$rc" -eq 0 ] && [[ "$out" == *CONTINUED* ]]; then
  pass "merge: a re-approval of the exact head on a later page lets the merge continue"
else
  fail "merge: paginated re-approval rc=$rc: $out"
fi

set +e
out=$(SHIM_BASE=release run_exact "$HEAD_SHA" nathanpayne-claude "[$(review nathanpayne-claude APPROVED "$HEAD_SHA")]" 2>&1); rc=$?
set -e
if [ "$rc" -eq 1 ] && [[ "$out" != *CONTINUED* ]] && [[ "$out" == *"PR base reads 'release', not the default branch 'main'"* ]]; then
  pass "merge: a base retargeted off the default branch fails closed"
else
  fail "merge: retargeted base rc=$rc: $out"
fi

set +e
out=$(SHIM_BASE_FAIL=1 run_exact "$HEAD_SHA" nathanpayne-claude "[$(review nathanpayne-claude APPROVED "$HEAD_SHA")]" 2>&1); rc=$?
set -e
if [ "$rc" -eq 1 ] && [[ "$out" != *CONTINUED* ]]; then
  pass "merge: an unreadable base fails closed"
else
  fail "merge: unreadable base rc=$rc: $out"
fi

set +e
out=$(run_exact "" nathanpayne-claude '[]' 2>&1); rc=$?
set -e
if [ "$rc" -eq 1 ] && [[ "$out" != *CONTINUED* ]] && [[ "$out" == *"Missing head SHA"* ]]; then
  pass "merge: an empty head read fails closed instead of reading as a moved head"
else
  fail "merge: empty head rc=$rc: $out"
fi

set +e
out=$(APPROVED_SHA= run_exact "$HEAD_SHA" nathanpayne-claude '[]' 2>&1); rc=$?
set -e
if [ "$rc" -eq 1 ] && [[ "$out" != *CONTINUED* ]] && [[ "$out" == *"Missing head SHA"* ]]; then
  pass "merge: an empty approved SHA from the approve job fails closed"
else
  fail "merge: empty approved SHA rc=$rc: $out"
fi

echo
echo "test_dependabot_reviewer_environment: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
