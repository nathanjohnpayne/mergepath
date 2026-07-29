#!/usr/bin/env bash
# tests/test_audit_branch_protection_workflow.sh
#
# Coverage for .github/workflows/branch-protection-audit.yml (#774) — the
# scheduled caller that finally makes scripts/audit-branch-protection.sh
# run. Before it existed, nothing invoked the audit at all, and the fleet
# reached 0-of-5 canonical gates on eight of ten repos with no red check
# anywhere.
#
# Two layers, following the pattern in scripts/ci/check_auto_clear_workflow:
#
#   1. Structural — the workflow parses as YAML and carries the trigger,
#      ref guard, permission set, checkout pin and secret wiring it needs.
#
#   2. Behavioural — the workflow's OWN bash is extracted with yq and
#      executed against stubs, rather than re-implemented here. That
#      matters most for two properties:
#        - the exit-code classification, because the rollup issue is
#          opened only on drift and closed only on clean, so a
#          misclassified auth failure would either present as a fleet-wide
#          all-clear or close a genuine drift issue;
#        - the issue-body assembly, because GitHub caps a body at 65536
#          characters and a rollup that lets the cap eat findings is a
#          rollup that lies.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKFLOW="$ROOT/.github/workflows/branch-protection-audit.yml"

[[ -f "$WORKFLOW" ]] || { echo "missing $WORKFLOW" >&2; exit 1; }

if ! command -v yq >/dev/null 2>&1 || ! yq --version 2>&1 | grep -q "mikefarah/yq"; then
  # Fail closed: every assertion below reads the workflow through yq, so a
  # skip would turn this whole suite into a no-op.
  echo "FAIL: mikefarah/yq v4+ is required (brew install yq)" >&2
  exit 1
fi

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/bp-audit-wf-test.XXXXXX")"
trap 'rm -rf "$WORKDIR"' EXIT

PASS=0
FAIL=0
pass() { echo "PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $*" >&2; FAIL=$((FAIL + 1)); }

step_run() {  # <step name> — print that step's `run:` body
  MP_STEP_NAME="$1" yq -r \
    '.jobs.audit.steps[] | select(.name == strenv(MP_STEP_NAME)) | .run' "$WORKFLOW"
}

# ===========================================================================
# Layer 1 — structural
# ===========================================================================

if yq eval '.' "$WORKFLOW" >/dev/null 2>&1; then
  pass "workflow YAML parses"
else
  fail "workflow YAML does not parse"
fi

# Scheduled + manually triggerable. The whole point of #774 is that the
# audit runs without anyone remembering to run it.
if [ "$(yq -r '.on.schedule[0].cron' "$WORKFLOW")" != "null" ]; then
  pass "schedule trigger with a cron entry"
else
  fail "no schedule cron — the audit would still be manual-only (#774)"
fi

# The manual trigger must NOT be ref-selectable. workflow_dispatch runs the
# workflow DEFINITION from the dispatcher's chosen ref, so every in-file
# guard against a non-default ref is written in the file the dispatcher can
# rewrite — a feature branch that deletes the guard gets
# BRANCH_PROTECTION_AUDIT_TOKEN (Administration:read across all ten fleet
# repos) before the pinned checkout runs. repository_dispatch has no ref
# parameter and always runs the default-branch definition, so the surface
# is removed rather than guarded from inside.
if [ "$(yq -r '.on | has("workflow_dispatch")' "$WORKFLOW")" = "false" ]; then
  pass "no workflow_dispatch trigger (no ref-selectable run of an admin-PAT workflow)"
else
  fail "workflow_dispatch must NOT be a trigger: it runs the definition from the dispatcher's ref, so the job's own ref guard is rewritable by the attacker and an admin-scoped PAT leaks to a feature branch"
fi
dispatch_types="$(yq -r '.on.repository_dispatch.types[]' "$WORKFLOW" 2>/dev/null || true)"
if printf '%s\n' "$dispatch_types" | grep -qx "branch-protection-audit"; then
  pass "repository_dispatch trigger typed 'branch-protection-audit' (manual runs stay on the default branch)"
else
  fail "expected a repository_dispatch trigger with type branch-protection-audit — got: [$dispatch_types]"
fi

# Backstop only, now that no trigger can select a ref — but it must stay,
# so that re-adding a ref-selectable trigger fails closed (#550).
if [ "$(yq -r '.jobs.audit.if' "$WORKFLOW")" = "github.ref_name == github.event.repository.default_branch" ]; then
  pass "job still gated to the default ref (fail-closed backstop if a ref-selectable trigger is ever re-added)"
else
  fail "job must be gated to the default ref — got: $(yq -r '.jobs.audit.if' "$WORKFLOW")"
fi

# Overlapping runs would each read "no open rollup issue" before either
# created one and open two, and a slow drift run could re-open the issue a
# newer clean run just closed. A workflow-level concurrency group is what
# makes the read-then-write rollup pair safe.
conc_group="$(yq -r '.concurrency.group // "none"' "$WORKFLOW")"
# `| tostring` rather than `// "unset"`: yq's alternative operator treats a
# literal `false` as empty, so the well-configured value would read as
# missing and this assertion could never pass.
conc_cancel="$(yq -r '.concurrency."cancel-in-progress" | tostring' "$WORKFLOW")"
if [ "$conc_group" = "none" ]; then
  fail "workflow-level concurrency group missing — two overlapping runs can both create a rollup issue"
elif [ "$conc_cancel" != "false" ]; then
  fail "concurrency must set cancel-in-progress: false so a queued scheduled audit is never dropped — got: $conc_cancel"
else
  pass "runs are serialized by a concurrency group ('$conc_group', cancel-in-progress: false)"
fi

expected_perms=$'contents: read\nissues: write'
actual_perms="$(yq -r '.permissions | to_entries | .[] | .key + ": " + (.value | tostring)' "$WORKFLOW" | sort)"
if [ "$actual_perms" = "$expected_perms" ]; then
  pass "permissions exactly match the least-privilege set"
else
  fail "permissions drifted; expected [$expected_perms], got [$actual_perms]"
fi

checkout_ref="$(yq -r '.jobs.audit.steps[0].with.ref' "$WORKFLOW")"
checkout_creds="$(yq -r '.jobs.audit.steps[0].with."persist-credentials"' "$WORKFLOW")"
if [ "$checkout_ref" = '${{ github.event.repository.default_branch }}' ] && [ "$checkout_creds" = "false" ]; then
  pass "checkout pinned to default_branch with persist-credentials: false"
else
  fail "checkout must pin ref to default_branch and set persist-credentials: false (got ref=$checkout_ref creds=$checkout_creds)"
fi

# The audit MUST use its own admin-scoped secret. REVIEWER_ASSIGNMENT_TOKEN
# is the reviewer PAT; it lacks Administration:read and 403s on every repo
# (#177, #285), which the fleet loop would then report as an infrastructure
# failure on all ten repos.
audit_token="$(yq -r '.jobs.audit.steps[] | select(.name == "Run the fleet audit") | .env.GH_TOKEN' "$WORKFLOW")"
if [ "$audit_token" = '${{ secrets.BRANCH_PROTECTION_AUDIT_TOKEN }}' ]; then
  pass "audit step reads through the admin-scoped BRANCH_PROTECTION_AUDIT_TOKEN"
else
  fail "audit step must use secrets.BRANCH_PROTECTION_AUDIT_TOKEN — got: $audit_token"
fi
if echo "$audit_token" | grep -q "REVIEWER_ASSIGNMENT_TOKEN"; then
  fail "audit step must NOT use the reviewer PAT (no Administration:read; 403s on every repo)"
else
  pass "audit step does not use the reviewer PAT"
fi

# ---------------------------------------------------------------------------
# GitHub API field limits.
#
# Every value below is written verbatim into an API field with a documented
# cap, and each cap is a hard 422 on the whole call rather than a silent
# truncation — so an over-long literal does not degrade the object, it stops
# the object being created. That is exactly how the tracking-label
# description (104 characters against a 100-character cap) would have made
# the FIRST drift run fail before it could report anything.
#
# Read as YAML scalars rather than scraped out of the `run:` bodies with a
# regex: a regex that stops matching after an unrelated edit would silently
# stop measuring anything, and the assertion would pass forever. Keeping the
# values in `env:` is what makes them measurable.
WF_LABEL_NAME="$(yq -r '.jobs.audit.env.TRACKING_LABEL' "$WORKFLOW")"
WF_LABEL_COLOR="$(yq -r '.jobs.audit.env.TRACKING_LABEL_COLOR' "$WORKFLOW")"
WF_LABEL_DESC="$(yq -r '.jobs.audit.env.TRACKING_LABEL_DESCRIPTION' "$WORKFLOW")"
WF_ISSUE_TITLE="$(yq -r '.jobs.audit.env.ISSUE_TITLE' "$WORKFLOW")"

for pair in "TRACKING_LABEL:$WF_LABEL_NAME" "TRACKING_LABEL_COLOR:$WF_LABEL_COLOR" \
            "TRACKING_LABEL_DESCRIPTION:$WF_LABEL_DESC" "ISSUE_TITLE:$WF_ISSUE_TITLE"; do
  key="${pair%%:*}"; val="${pair#*:}"
  if [ -n "$val" ] && [ "$val" != "null" ]; then
    continue
  fi
  fail "job env.$key is unset — the GitHub field-limit assertions below cannot measure a value that is not there (do not inline it in the step)"
done

# Label description: <= 100 characters.
if [ "${#WF_LABEL_DESC}" -le 100 ] && [ "${#WF_LABEL_DESC}" -gt 0 ]; then
  pass "tracking-label description is ${#WF_LABEL_DESC} chars (GitHub caps label descriptions at 100)"
else
  fail "tracking-label description is ${#WF_LABEL_DESC} chars — GitHub 422s a label description over 100, so the label is never created and the drift run reports nothing"
fi

# Label name: <= 50 characters.
if [ "${#WF_LABEL_NAME}" -le 50 ]; then
  pass "tracking-label name is ${#WF_LABEL_NAME} chars (GitHub caps label names at 50)"
else
  fail "tracking-label name is ${#WF_LABEL_NAME} chars — over GitHub's 50-character label-name cap"
fi

# Label color: exactly six hex digits, no leading '#'.
if printf '%s' "$WF_LABEL_COLOR" | grep -qE '^[0-9a-fA-F]{6}$'; then
  pass "tracking-label color '$WF_LABEL_COLOR' is a bare 6-digit hex value"
else
  fail "tracking-label color must be exactly 6 hex digits with no leading '#' — got '$WF_LABEL_COLOR'"
fi

# Issue title: <= 256 characters.
if [ "${#WF_ISSUE_TITLE}" -le 256 ] && [ "${#WF_ISSUE_TITLE}" -gt 0 ]; then
  pass "rollup issue title is ${#WF_ISSUE_TITLE} chars (GitHub caps issue titles at 256)"
else
  fail "rollup issue title is ${#WF_ISSUE_TITLE} chars — over GitHub's 256-character issue-title cap"
fi

# ---------------------------------------------------------------------------
# Issue steps fire on the right verdicts and nothing else.
drift_if="$(yq -r '.jobs.audit.steps[] | select(.name == "Open or update the rollup issue") | .if' "$WORKFLOW")"
clean_if="$(yq -r '.jobs.audit.steps[] | select(.name == "Close stale rollup issue on a clean audit") | .if' "$WORKFLOW")"
if [ "$drift_if" = "steps.audit.outputs.result == 'drift'" ]; then
  pass "rollup issue is opened/updated only on the drift verdict"
else
  fail "rollup-issue step gate wrong: $drift_if"
fi
if [ "$clean_if" = "steps.audit.outputs.result == 'clean'" ]; then
  pass "rollup issue is closed only on the clean verdict"
else
  fail "rollup-close step gate wrong: $clean_if"
fi

# ===========================================================================
# Layer 2a — behavioural: exit-code classification
# ===========================================================================
#
# Run the workflow's own "Run the fleet audit" body against a stub auditor
# whose exit code we choose.

WS="$WORKDIR/ws"
mkdir -p "$WS/scripts"
step_run "Run the fleet audit" > "$WORKDIR/audit-step.sh"

cat >"$WS/scripts/audit-branch-protection.sh" <<'STUB'
#!/usr/bin/env bash
# Stub fleet auditor. Records that it ran, honours --summary-file, and
# exits with STUB_FLEET_RC.
summary=""
while [ $# -gt 0 ]; do
  case "$1" in
    --summary-file) summary="$2"; shift 2 ;;
    *) shift ;;
  esac
done
echo "stub fleet audit ran"
[ -n "$summary" ] && printf 'PASS   rc=0  owner/example\nAudited 1 repo(s): 1 pass, 0 drift, 0 error.\n' > "$summary"
exit "${STUB_FLEET_RC:-0}"
STUB
chmod +x "$WS/scripts/audit-branch-protection.sh"

run_audit_step() {  # <stub rc> <gh token>  → prints step stdout+stderr; sets STEP_RC / STEP_OUTPUTS
  local stub_rc="$1" token="$2"
  local outfile="$WORKDIR/gh-output.$$"
  : > "$outfile"
  rm -f "$WS/audit-output.txt" "$WS/fleet-summary.txt"
  STEP_RC=0
  STEP_TEXT="$(
    cd "$WS" && \
    STUB_FLEET_RC="$stub_rc" \
    GH_TOKEN="$token" \
    HUB_REPO="owner/hub" \
    GITHUB_OUTPUT="$outfile" \
      bash "$WORKDIR/audit-step.sh" 2>&1
  )" || STEP_RC=$?
  STEP_OUTPUTS="$(cat "$outfile")"
  rm -f "$outfile"
}

# rc 0 → clean, step succeeds.
run_audit_step 0 "admin-pat"
if [ "$STEP_RC" -eq 0 ] && echo "$STEP_OUTPUTS" | grep -qx "result=clean" && echo "$STEP_OUTPUTS" | grep -qx "exit_code=0"; then
  pass "audit rc=0 → result=clean, step succeeds"
else
  fail "audit rc=0 mishandled (rc=$STEP_RC outputs=[$STEP_OUTPUTS])"
fi

# rc 3 → drift, step succeeds so the rollup steps can run.
run_audit_step 3 "admin-pat"
if [ "$STEP_RC" -eq 0 ] && echo "$STEP_OUTPUTS" | grep -qx "result=drift" && echo "$STEP_OUTPUTS" | grep -qx "exit_code=3"; then
  pass "audit rc=3 → result=drift, step succeeds so the rollup runs"
else
  fail "audit rc=3 mishandled (rc=$STEP_RC outputs=[$STEP_OUTPUTS])"
fi

# rc 2 (auth/API) → job FAILS and emits NO result, so neither the
# open-rollup nor the close-rollup step can fire. This is the guard that
# stops an under-scoped token presenting as a fleet-wide all-clear.
run_audit_step 2 "admin-pat"
if [ "$STEP_RC" -ne 2 ]; then
  fail "audit rc=2 must fail the step with 2, got $STEP_RC"
elif echo "$STEP_OUTPUTS" | grep -q "^result="; then
  fail "audit rc=2 must NOT set a result (would let the rollup steps fire): [$STEP_OUTPUTS]"
elif ! echo "$STEP_TEXT" | grep -q "::error::"; then
  fail "audit rc=2 must emit an ::error:: annotation; got: $STEP_TEXT"
elif ! echo "$STEP_TEXT" | grep -q "NOT drift"; then
  fail "audit rc=2 diagnostic must distinguish infrastructure failure from drift; got: $STEP_TEXT"
else
  pass "audit rc=2 → job fails loudly, no result set, rollup issue untouched"
fi

# rc 1 (usage/prereq) → same posture as rc 2.
run_audit_step 1 "admin-pat"
if [ "$STEP_RC" -eq 1 ] && ! echo "$STEP_OUTPUTS" | grep -q "^result=" && echo "$STEP_TEXT" | grep -q "::error::"; then
  pass "audit rc=1 → job fails loudly, no result set"
else
  fail "audit rc=1 mishandled (rc=$STEP_RC outputs=[$STEP_OUTPUTS])"
fi

# An unexpected code is contract drift, not a pass.
run_audit_step 7 "admin-pat"
if [ "$STEP_RC" -eq 7 ] && echo "$STEP_TEXT" | grep -q "unexpected code 7"; then
  pass "audit rc=7 → job fails with a contract-drift diagnostic"
else
  fail "unexpected audit rc mishandled (rc=$STEP_RC text=$STEP_TEXT)"
fi

# Missing secret → fail BEFORE running the audit, naming the secret and the
# scope. A silent green here would recreate exactly the blind spot #774
# closes.
run_audit_step 0 ""
if [ "$STEP_RC" -eq 0 ]; then
  fail "empty BRANCH_PROTECTION_AUDIT_TOKEN must fail the job, got rc=0"
elif ! echo "$STEP_TEXT" | grep -q "BRANCH_PROTECTION_AUDIT_TOKEN"; then
  fail "empty-token diagnostic must name the secret; got: $STEP_TEXT"
elif ! echo "$STEP_TEXT" | grep -q "Administration:read"; then
  fail "empty-token diagnostic must name the required scope; got: $STEP_TEXT"
elif echo "$STEP_TEXT" | grep -q "stub fleet audit ran"; then
  fail "empty-token guard must run BEFORE the audit"
elif echo "$STEP_OUTPUTS" | grep -q "^result="; then
  fail "empty-token path must NOT set a result: [$STEP_OUTPUTS]"
else
  pass "empty BRANCH_PROTECTION_AUDIT_TOKEN → fails before auditing, names secret + scope"
fi

# ===========================================================================
# Layer 2b — behavioural: rollup issue body
# ===========================================================================
#
# Run the workflow's own "Open or update the rollup issue" body with `gh`
# stubbed, and inspect the issue-body.txt it assembles.

step_run "Open or update the rollup issue" > "$WORKDIR/issue-step.sh"

GH_STUB_DIR="$WORKDIR/stub-bin"
mkdir -p "$GH_STUB_DIR"
cat >"$GH_STUB_DIR/gh" <<'STUB'
#!/usr/bin/env bash
# Records every invocation and models the slice of `gh` this workflow
# uses — INCLUDING the server-side validation GitHub applies, so a value
# GitHub would reject is rejected here too rather than sailing through a
# permissive stub.
#
#   gh issue list   returns GH_STUB_EXISTING (empty = "no open rollup
#                   issue"); fails outright under GH_STUB_LIST_FAIL — the
#                   "GitHub unreachable / issues:read denied" case, which
#                   must never be mistaken for "nothing is open".
#   gh label list   prints GH_STUB_LABELS one name per line, matching what
#                   `--json name --jq '.[].name'` emits; fails under
#                   GH_STUB_LABEL_LIST_FAIL.
#   gh label create enforces GitHub's documented label limits and, like the
#                   real command, refuses to overwrite an existing label
#                   without --force. Errors go to stderr and exit 1, as
#                   `gh label create` does (this is a high-level command,
#                   not `gh api --jq`, which prints error BODIES to stdout).
printf '%s\n' "gh $*" >> "$GH_CALL_LOG"

if [ "${1:-}" = "issue" ] && [ "${2:-}" = "list" ]; then
  if [ -n "${GH_STUB_LIST_FAIL:-}" ]; then
    echo "gh: HTTP 503 Service Unavailable (stubbed)" >&2
    exit 1
  fi
  printf '%s' "${GH_STUB_EXISTING:-}"
  exit 0
fi

if [ "${1:-}" = "label" ] && [ "${2:-}" = "list" ]; then
  if [ -n "${GH_STUB_LABEL_LIST_FAIL:-}" ]; then
    echo "gh: HTTP 503 Service Unavailable (stubbed)" >&2
    exit 1
  fi
  [ -n "${GH_STUB_LABELS:-}" ] && printf '%s\n' "$GH_STUB_LABELS"
  exit 0
fi

if [ "${1:-}" = "label" ] && [ "${2:-}" = "create" ]; then
  name="${3:-}"
  color=""
  description=""
  shift 3
  while [ $# -gt 0 ]; do
    case "$1" in
      --color) color="$2"; shift 2 ;;
      --description) description="$2"; shift 2 ;;
      --repo) shift 2 ;;
      *) shift ;;
    esac
  done

  # Refuses to clobber an existing label without --force, exactly as the
  # real command does ("Create a new label on GitHub, or update an
  # existing one with --force").
  if printf '%s\n' "${GH_STUB_LABELS:-}" | grep -qx "$name"; then
    echo "label with name \"$name\" already exists; use \`--force\` to update its color and description" >&2
    exit 1
  fi
  # GitHub's documented caps on POST /repos/{owner}/{repo}/labels. Each is
  # a hard 422 on the whole call — the label is not created at all.
  if [ "${#name}" -gt 50 ]; then
    echo "HTTP 422: Validation Failed (name is too long (maximum is 50 characters))" >&2
    exit 1
  fi
  if [ "${#description}" -gt 100 ]; then
    echo "HTTP 422: Validation Failed (description is too long (maximum is 100 characters))" >&2
    exit 1
  fi
  if ! printf '%s' "$color" | grep -qE '^[0-9a-fA-F]{6}$'; then
    echo "HTTP 422: Validation Failed (color is invalid: must be 6 hex digits without a leading '#')" >&2
    exit 1
  fi
  exit 0
fi

exit 0
STUB
chmod +x "$GH_STUB_DIR/gh"

run_issue_step() {  # <audit-output file> [label-ready: true|false|""]
  local output_src="$1"
  local label_ready="${2-true}"
  ISSUE_WS="$WORKDIR/issue-ws"
  rm -rf "$ISSUE_WS"; mkdir -p "$ISSUE_WS"
  cp "$output_src" "$ISSUE_WS/audit-output.txt"
  cat >"$ISSUE_WS/fleet-summary.txt" <<'SUM'
=== Fleet summary (branch 'main') ===
DRIFT  rc=3  owner/hub
PASS   rc=0  owner/alpha
DRIFT  rc=3  owner/omega-last-row
Audited 3 repo(s): 1 pass, 2 drift, 0 error.
SUM
  GH_CALL_LOG="$ISSUE_WS/gh-calls.log"
  : > "$GH_CALL_LOG"
  ISSUE_RC=0
  # The runner always defines GITHUB_STEP_SUMMARY; the step writes to it on
  # the edit path, and under `set -u` an unset one would fail the step for a
  # harness reason and mask the behaviour under test.
  ISSUE_TEXT="$(
    cd "$ISSUE_WS" && \
    PATH="$GH_STUB_DIR:$PATH" \
    GH_CALL_LOG="$GH_CALL_LOG" \
    GITHUB_STEP_SUMMARY="$ISSUE_WS/step-summary.md" \
    GH_TOKEN="ghtoken" \
    REPO="owner/hub" \
    RUN_URL="https://example.invalid/run/1" \
    TRACKING_LABEL="branch-protection-drift" \
    LABEL_READY="$label_ready" \
    ISSUE_TITLE="Fleet branch protection has drifted" \
      bash "$WORKDIR/issue-step.sh" 2>&1
  )" || ISSUE_RC=$?
  ISSUE_BODY="$ISSUE_WS/issue-body.txt"
}

# Small output → body carries it whole, no truncation notice.
printf 'short audit output line\n' > "$WORKDIR/small-output.txt"
run_issue_step "$WORKDIR/small-output.txt"
if [ "$ISSUE_RC" -ne 0 ]; then
  fail "issue step failed on a small output: $ISSUE_TEXT"
elif ! grep -q "short audit output line" "$ISSUE_BODY"; then
  fail "small output missing from the issue body"
elif grep -q "truncated at" "$ISSUE_BODY"; then
  fail "small output must not be marked truncated"
else
  pass "issue body embeds a small audit output verbatim"
fi

# Dedupe is by LABEL, not by body content. A body-content key would stop
# matching exactly when the body is truncated — i.e. when the fleet is at
# its most broken.
if grep -q -- "issue list .*--label branch-protection-drift" "$ISSUE_WS/gh-calls.log" \
   && grep -q -- "issue list .*--limit 500" "$ISSUE_WS/gh-calls.log"; then
  pass "rollup dedupe queries by label with --limit 500"
else
  fail "dedupe must be a labelled gh issue list with --limit 500; calls: $(cat "$ISSUE_WS/gh-calls.log")"
fi
if grep -q "issue create" "$ISSUE_WS/gh-calls.log" && ! grep -q "issue edit" "$ISSUE_WS/gh-calls.log"; then
  pass "no existing rollup issue → creates exactly one"
else
  fail "expected a single create and no edit; calls: $(cat "$ISSUE_WS/gh-calls.log")"
fi

# An existing open rollup issue is UPDATED in place, never duplicated.
GH_STUB_EXISTING="4242"
export GH_STUB_EXISTING
run_issue_step "$WORKDIR/small-output.txt"
unset GH_STUB_EXISTING
if grep -q "issue edit 4242" "$ISSUE_WS/gh-calls.log" && ! grep -q "issue create" "$ISSUE_WS/gh-calls.log"; then
  pass "existing rollup issue is updated in place, not duplicated"
else
  fail "expected an edit of #4242 and no create; calls: $(cat "$ISSUE_WS/gh-calls.log")"
fi

# Oversized output → the verbose block is truncated, the per-repo verdict
# table survives WHOLE, and the body stays under GitHub's 65536 cap.
: > "$WORKDIR/big-output.txt"
i=0
while [ "$i" -lt 3000 ]; do
  printf 'verbose audit line %05d aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n' "$i" >> "$WORKDIR/big-output.txt"
  i=$((i + 1))
done
run_issue_step "$WORKDIR/big-output.txt"
body_bytes="$(wc -c < "$ISSUE_BODY" | tr -d ' ')"
if [ "$ISSUE_RC" -ne 0 ]; then
  fail "issue step failed on an oversized output: $ISSUE_TEXT"
elif [ "$body_bytes" -ge 65536 ]; then
  fail "issue body is $body_bytes bytes — GitHub rejects a body at/over 65536"
elif ! grep -q "truncated at" "$ISSUE_BODY"; then
  fail "oversized output must carry an explicit truncation notice"
elif ! grep -q "omega-last-row" "$ISSUE_BODY"; then
  fail "the LAST per-repo verdict row was lost to the body cap — the rollup would under-report"
elif ! grep -q "Audited 3 repo(s): 1 pass, 2 drift, 0 error." "$ISSUE_BODY"; then
  fail "the verdict tally was lost to the body cap"
elif ! grep -q "https://example.invalid/run/1" "$ISSUE_BODY"; then
  fail "a truncated body must link the run log holding the full output"
else
  pass "oversized output: body stays under the cap, verdict table survives whole, truncation is explicit ($body_bytes bytes)"
fi

# The remediation ordering trap is stated in the issue itself: a repo with
# no protection cannot have a check required until that check has run once.
if grep -q "run at" "$ISSUE_BODY" && grep -q "least once" "$ISSUE_BODY"; then
  pass "issue body states the run-once-before-required ordering trap"
else
  fail "issue body must state the ordering trap (a check must have run once before it can be required)"
fi

# The label is the dedupe key, and on the happy path the created issue must
# carry it — otherwise next week's lookup opens a duplicate.
run_issue_step "$WORKDIR/small-output.txt" "true"
if [ "$ISSUE_RC" -ne 0 ]; then
  fail "issue step failed with the label ready: $ISSUE_TEXT"
elif grep -q -- "issue create .*--label branch-protection-drift" "$ISSUE_WS/gh-calls.log"; then
  pass "label ready → the new rollup issue is created WITH the dedupe label"
else
  fail "a created rollup issue must carry the dedupe label; calls: $(cat "$ISSUE_WS/gh-calls.log")"
fi

# The load-bearing degradation: the label could NOT be ensured. The rollup
# issue is this workflow's deliverable and the label is only how the next
# run finds it, so the report must still be written — unlabelled — and the
# job must then go red. Creating it WITH a label that does not exist would
# be rejected by gh and lose the report entirely.
run_issue_step "$WORKDIR/small-output.txt" "false"
if [ "$ISSUE_RC" -eq 0 ]; then
  fail "an unensured label must still fail the job after reporting, got rc=0"
elif ! grep -q "issue create" "$ISSUE_WS/gh-calls.log"; then
  fail "drift must be reported even when the label is missing — no issue was created; calls: $(cat "$ISSUE_WS/gh-calls.log")"
elif grep -q -- "issue create .*--label" "$ISSUE_WS/gh-calls.log"; then
  fail "with the label unensured the create must NOT pass --label (gh rejects an unknown label and the whole report is lost); calls: $(cat "$ISSUE_WS/gh-calls.log")"
elif ! grep -q "short audit output line" "$ISSUE_BODY"; then
  fail "the degraded path must still assemble a full issue body"
elif ! echo "$ISSUE_TEXT" | grep -q "::error::"; then
  fail "the degraded path must emit an ::error:: annotation, not degrade silently; got: $ISSUE_TEXT"
else
  pass "label unensured → drift is still reported (unlabelled), annotated, and the job then fails"
fi

# An UNSET LABEL_READY (e.g. the label step never ran) is treated as
# "not ready", not as ready.
run_issue_step "$WORKDIR/small-output.txt" ""
if [ "$ISSUE_RC" -ne 0 ] && grep -q "issue create" "$ISSUE_WS/gh-calls.log" \
   && ! grep -q -- "issue create .*--label" "$ISSUE_WS/gh-calls.log"; then
  pass "empty LABEL_READY is treated as not-ready (reports, then fails)"
else
  fail "empty LABEL_READY must not be read as ready (rc=$ISSUE_RC calls: $(cat "$ISSUE_WS/gh-calls.log"))"
fi

# Finding an existing issue BY LABEL proves the label exists, so the edit
# path must not inherit a stale not-ready verdict and fail a healthy run.
GH_STUB_EXISTING="4242"
export GH_STUB_EXISTING
run_issue_step "$WORKDIR/small-output.txt" "false"
unset GH_STUB_EXISTING
if [ "$ISSUE_RC" -eq 0 ] && grep -q "issue edit 4242" "$ISSUE_WS/gh-calls.log"; then
  pass "the edit path (issue found by label) succeeds regardless of LABEL_READY"
else
  fail "an existing labelled rollup issue proves the label exists; the edit path must not fail (rc=$ISSUE_RC calls: $(cat "$ISSUE_WS/gh-calls.log"))"
fi

# ===========================================================================
# Layer 2c — behavioural: closing the rollup issue on a clean audit
# ===========================================================================
#
# The close step is the only place the workflow REMOVES a finding from
# view, so its failure modes matter more than its happy path: "the lookup
# failed" must never be read as "there is nothing open to close".

step_run "Close stale rollup issue on a clean audit" > "$WORKDIR/close-step.sh"

run_close_step() {  # env: GH_STUB_EXISTING / GH_STUB_LIST_FAIL
  CLOSE_WS="$WORKDIR/close-ws"
  rm -rf "$CLOSE_WS"; mkdir -p "$CLOSE_WS"
  GH_CALL_LOG="$CLOSE_WS/gh-calls.log"
  : > "$GH_CALL_LOG"
  CLOSE_RC=0
  CLOSE_TEXT="$(
    cd "$CLOSE_WS" && \
    PATH="$GH_STUB_DIR:$PATH" \
    GH_CALL_LOG="$GH_CALL_LOG" \
    GH_TOKEN="ghtoken" \
    REPO="owner/hub" \
    RUN_URL="https://example.invalid/run/1" \
    TRACKING_LABEL="branch-protection-drift" \
      bash "$WORKDIR/close-step.sh" 2>&1
  )" || CLOSE_RC=$?
  CLOSE_CALLS="$(cat "$GH_CALL_LOG")"
}

# No open rollup issue → the steady state. Succeed, close nothing.
run_close_step
if [ "$CLOSE_RC" -ne 0 ]; then
  fail "clean audit with no open rollup issue must succeed, got rc=$CLOSE_RC: $CLOSE_TEXT"
elif echo "$CLOSE_CALLS" | grep -q "issue close"; then
  fail "nothing was open, yet the step tried to close something: $CLOSE_CALLS"
else
  pass "clean audit, no open rollup issue → no-op success"
fi

# Open rollup issues → every one is closed.
GH_STUB_EXISTING=$'77\n88'
export GH_STUB_EXISTING
run_close_step
unset GH_STUB_EXISTING
if [ "$CLOSE_RC" -ne 0 ]; then
  fail "clean audit with open rollup issues must succeed, got rc=$CLOSE_RC: $CLOSE_TEXT"
elif ! echo "$CLOSE_CALLS" | grep -q "issue close 77" || ! echo "$CLOSE_CALLS" | grep -q "issue close 88"; then
  fail "clean audit must close every open rollup issue; calls: $CLOSE_CALLS"
else
  pass "clean audit closes every open rollup issue"
fi

# The load-bearing one: the lookup FAILS. `mapfile -t arr < <(gh ...)`
# would swallow this — a process substitution's exit status is not
# mapfile's, so mapfile succeeds with an empty array even under
# `set -euo pipefail`, the step reports "nothing to do", and a genuine
# drift issue stays open behind a green clean-audit run. The step must
# fail loudly instead.
GH_STUB_LIST_FAIL=1
export GH_STUB_LIST_FAIL
run_close_step
unset GH_STUB_LIST_FAIL
if [ "$CLOSE_RC" -eq 0 ]; then
  fail "a failing 'gh issue list' must fail the step, not report an empty result (rc=0, text: $CLOSE_TEXT)"
elif echo "$CLOSE_TEXT" | grep -q "nothing to do"; then
  fail "a failing lookup must not be reported as 'no open rollup issue': $CLOSE_TEXT"
elif ! echo "$CLOSE_TEXT" | grep -q "::error::"; then
  fail "a failing lookup must emit an ::error:: annotation; got: $CLOSE_TEXT"
elif echo "$CLOSE_CALLS" | grep -q "issue close"; then
  fail "a failing lookup must not close anything; calls: $CLOSE_CALLS"
else
  pass "a failing rollup lookup fails the step instead of masquerading as an empty result"
fi

# ===========================================================================
# Layer 2d — behavioural: ensuring the tracking label
# ===========================================================================
#
# This step runs BEFORE the rollup issue is written, so anything it treats
# as fatal is fatal to the whole report. The `gh` stub enforces GitHub's
# real label validation, which means the workflow's OWN description literal
# is measured against the 100-character cap by actually being submitted —
# not just by counting it in Layer 1.

step_run "Ensure tracking label exists" > "$WORKDIR/label-step.sh"

run_label_step() {  # <description>  → LABEL_RC / LABEL_TEXT / LABEL_OUTPUTS / LABEL_CALLS
  local desc="$1"
  LABEL_WS="$WORKDIR/label-ws"
  rm -rf "$LABEL_WS"; mkdir -p "$LABEL_WS"
  GH_CALL_LOG="$LABEL_WS/gh-calls.log"
  : > "$GH_CALL_LOG"
  local outfile="$LABEL_WS/gh-output"
  : > "$outfile"
  LABEL_RC=0
  LABEL_TEXT="$(
    cd "$LABEL_WS" && \
    PATH="$GH_STUB_DIR:$PATH" \
    GH_CALL_LOG="$GH_CALL_LOG" \
    GH_TOKEN="ghtoken" \
    REPO="owner/hub" \
    TRACKING_LABEL="$WF_LABEL_NAME" \
    TRACKING_LABEL_COLOR="$WF_LABEL_COLOR" \
    TRACKING_LABEL_DESCRIPTION="$desc" \
    GITHUB_OUTPUT="$outfile" \
      bash "$WORKDIR/label-step.sh" 2>&1
  )" || LABEL_RC=$?
  LABEL_OUTPUTS="$(cat "$outfile")"
  LABEL_CALLS="$(cat "$GH_CALL_LOG")"
}

# The regression test for the 104-character description: submit the
# workflow's own values to a stub that applies GitHub's validation. A
# description over the cap is a 422 on the whole create call, so the label
# is never created — and under the old `set -e` step that aborted the job
# before the rollup issue could be written.
run_label_step "$WF_LABEL_DESC"
if [ "$LABEL_RC" -ne 0 ]; then
  fail "creating the tracking label with the workflow's own values failed: $LABEL_TEXT"
elif ! echo "$LABEL_OUTPUTS" | grep -qx "ready=true"; then
  fail "the workflow's own label values were REJECTED by GitHub's validation — the label is never created. Output: $LABEL_TEXT"
elif ! echo "$LABEL_CALLS" | grep -q "label create"; then
  fail "expected a label create call; calls: $LABEL_CALLS"
else
  pass "the workflow's own label name/color/description pass GitHub's validation and yield ready=true"
fi

# Already present → no create attempt, still ready.
GH_STUB_LABELS="$WF_LABEL_NAME"
export GH_STUB_LABELS
run_label_step "$WF_LABEL_DESC"
unset GH_STUB_LABELS
if [ "$LABEL_RC" -eq 0 ] && echo "$LABEL_OUTPUTS" | grep -qx "ready=true" \
   && ! echo "$LABEL_CALLS" | grep -q "label create"; then
  pass "existing label → ready=true with no create attempt"
else
  fail "an existing label must short-circuit the create (rc=$LABEL_RC outputs=[$LABEL_OUTPUTS] calls: $LABEL_CALLS)"
fi

# The listing fails while the label DOES exist. A failed `gh label list`
# pipeline is indistinguishable from an empty one at the `grep -qx`, so the
# step falls into the create branch and gets the real command's
# "already exists" refusal — which is proof of presence, not a failure.
GH_STUB_LABELS="$WF_LABEL_NAME"
GH_STUB_LABEL_LIST_FAIL=1
export GH_STUB_LABELS GH_STUB_LABEL_LIST_FAIL
run_label_step "$WF_LABEL_DESC"
unset GH_STUB_LABELS GH_STUB_LABEL_LIST_FAIL
if [ "$LABEL_RC" -eq 0 ] && echo "$LABEL_OUTPUTS" | grep -qx "ready=true"; then
  pass "a failed label listing + an 'already exists' create is still ready=true"
else
  fail "'already exists' means the label is present, not that ensuring it failed (rc=$LABEL_RC outputs=[$LABEL_OUTPUTS] text: $LABEL_TEXT)"
fi

# An unrecoverable create failure must NOT abort the job — the rollup issue
# has not been written yet. Drive it with a description one character over
# GitHub's cap, i.e. the exact defect this fix closes.
overlong=""
while [ "${#overlong}" -lt 101 ]; do overlong="${overlong}x"; done
run_label_step "$overlong"
if [ "$LABEL_RC" -ne 0 ]; then
  fail "a label failure must not fail the step — the rollup issue has not been written yet (rc=$LABEL_RC, text: $LABEL_TEXT)"
elif ! echo "$LABEL_OUTPUTS" | grep -qx "ready=false"; then
  fail "an unrecoverable label failure must report ready=false so the rollup step degrades; outputs=[$LABEL_OUTPUTS]"
elif ! echo "$LABEL_TEXT" | grep -q "::warning::"; then
  fail "a label failure must be annotated, not swallowed; got: $LABEL_TEXT"
elif ! echo "$LABEL_TEXT" | grep -qi "maximum is 100"; then
  fail "the underlying gh/GitHub error must be surfaced in the log; got: $LABEL_TEXT"
else
  pass "an over-long description degrades to ready=false with a ::warning:: instead of killing the report"
fi

echo ""
echo "test_audit_branch_protection_workflow: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
