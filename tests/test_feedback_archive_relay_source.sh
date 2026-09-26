#!/usr/bin/env bash
# Runtime tests for the trusted source-run to PR binding used by the feedback
# archive relay. Every network response is supplied by the gh shim; the log
# makes a write against a title-selected PR observable if one is introduced.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/scripts/workflow/feedback-archive-relay-source.sh"
[ -x "$SCRIPT" ] || { echo "missing executable $SCRIPT" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq is required" >&2; exit 0; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/feedback-archive-relay-source.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
BIN="$TMP/bin"
mkdir -p "$BIN"
PASS=0
FAIL=0
pass() { printf 'PASS: %s\n' "$*"; PASS=$((PASS + 1)); }
fail() { printf 'FAIL: %s\n' "$*" >&2; FAIL=$((FAIL + 1)); }
assert_eq() { [ "$1" = "$2" ] && pass "$3" || fail "$3 (got=$1 want=$2)"; }
assert_empty_writes() {
  if ! grep -E $'\t(POST|PATCH|DELETE)\t|--method\t(POST|PATCH|DELETE)' "$GH_LOG" >/dev/null 2>&1; then
    pass "$1"
  else
    fail "$1 (unexpected mutation: $(cat "$GH_LOG"))"
  fi
}

cat >"$BIN/gh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf 'gh' >>"$GH_LOG"
for a in "$@"; do printf '\t%s' "$a" >>"$GH_LOG"; done
printf '\n' >>"$GH_LOG"
for a in "$@"; do
  if [ "$a" = --input ]; then
    body=$(cat)
    printf 'input\t%s\n' "$body" >>"$GH_LOG"
    break
  fi
done
[ "${1:-}" = api ] || exit 64
shift
paginate=false
if [ "${1:-}" = --paginate ]; then paginate=true; shift; fi
method=GET
if [ "${1:-}" = --method ]; then method=$2; shift 2; fi
endpoint=${1:-}
shift || true
jq_filter=""
prev=""
for arg in "$@"; do
  if [ "$prev" = --jq ]; then jq_filter=$arg; fi
  prev=$arg
done
case "$endpoint" in
  repos/acme/widget/pulls/[0-9]*)
    pr=${endpoint##*/}
    file_var="PR_$pr"
    file=${!file_var:-}
    [ -n "$file" ] || { printf 'HTTP 404\n' >&2; exit 1; }
    if [ "${FAIL_PR_HEAD_READ:-false}" = true ] && [ "$jq_filter" = .head.sha ]; then
      printf 'temporary PR head read failure\n' >&2
      exit 1
    fi
    if [ "$jq_filter" = .head.sha ] && [ -n "${HEAD_SEQUENCE_FILE:-}" ]; then
      count_file="${HEAD_SEQUENCE_FILE}.count"
      count=0; [ -f "$count_file" ] && count=$(cat "$count_file")
      count=$((count + 1)); printf '%s' "$count" >"$count_file"
      sed -n "${count}p" "$HEAD_SEQUENCE_FILE"
    elif [ -n "$jq_filter" ]; then
      jq -r "$jq_filter" "$file"
    else
      cat "$file"
    fi
    ;;
  repos/acme/widget/pulls\?state=all\&head=*)
    cat "$CANDIDATES"
    ;;
  repos/acme/widget/check-runs)
    [ "$method" = POST ] || exit 65
    if [ "$jq_filter" = .id ]; then printf '900\n'; else printf '{"id":900}\n'; fi
    ;;
  repos/acme/widget/issues/[0-9]*/comments)
    if [ "$method" = POST ]; then printf '{"id": 901}\n'; else printf '[]\n'; fi
    ;;
  repos/acme/widget/check-runs/[0-9]*)
    [ "$method" = PATCH ] || exit 65
    ;;
  repos/acme/widget/commits/*/check-runs*)
    printf '{"check_runs":[]}\n'
    ;;
  repos/acme/widget/actions/artifacts/[0-9]*)
    [ "$method" = DELETE ] || exit 65
    ;;
  *)
    printf 'unhandled endpoint: %s\n' "$endpoint" >&2
    exit 65
    ;;
esac
SH
chmod +x "$BIN/gh"
cat >"$BIN/sleep" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod +x "$BIN/sleep"

sha() { printf '%040d' "$1"; }
BASE_ID=100
BASE_REPO=acme/widget
RUN_AT=2026-09-26T10:00:00Z

write_pr() {
  # number, head sha, head repo id, head repo name, branch, actor, created, fork flag
  local fork=${8:-}
  if [ -z "$fork" ]; then
    [ "$4" = "$BASE_REPO" ] && fork=false || fork=true
  fi
  jq -n --argjson n "$1" --arg head "$2" --argjson hrid "$3" --arg hrepo "$4" \
    --arg branch "$5" --arg actor "$6" --arg created "$7" --argjson base "$BASE_ID" \
    --arg repo "$BASE_REPO" --argjson fork "$fork" '{number:$n,created_at:$created,user:{login:$actor},base:{repo:{id:$base,full_name:$repo,default_branch:"main"}},head:{sha:$head,ref:$branch,repo:{id:$hrid,full_name:$hrepo,fork:$fork}}}' >"$TMP/pr-$1.json"
  eval "PR_$1=\"$TMP/pr-$1.json\""
  export "PR_$1"
}

write_run() {
  # event, source sha, source repo id, source repo, branch, associations json, path
  jq -n --arg event "$1" --arg head "$2" --argjson hri "$3" --arg hr "$4" --arg branch "$5" \
    --argjson associations "$6" --arg path "$7" --arg created "$RUN_AT" --argjson base "$BASE_ID" \
    --arg repo "$BASE_REPO" --argjson pr "${RUN_PR:-41}" '{id:501,display_title:("Codex P1 Gate relay-v1 PR #" + ($pr|tostring)),event:$event,path:$path,head_sha:$head,head_branch:$branch,head_repository:{id:$hri,full_name:$hr},repository:{id:$base,full_name:$repo},created_at:$created,pull_requests:$associations}' >"$TMP/run.json"
}

run_case() {
  : >"$GH_LOG"
  set +e
  OUTPUT=$(PATH="$BIN:$PATH" GH_LOG="$GH_LOG" CANDIDATES="$CANDIDATES" "$SCRIPT" "$BASE_REPO" "$1" <"$TMP/run.json" 2>"$TMP/stderr")
  RC=$?
  set -e
  if [ "$RC" -ne 0 ]; then
    printf 'helper rc=%s: %s [calls: %s]\n' "$RC" "$(cat "$TMP/stderr")" "$(cat "$GH_LOG")" >&2
  fi
}

CANDIDATES="$TMP/candidates.json"
GH_LOG="$TMP/gh.log"
export CANDIDATES GH_LOG

# GitHub's observed review-event shape has no PR association. A unique source
# origin/branch binds it, but publication uses the current PR API head after a
# later push, rather than the historical source head.
SRC=$(sha 11)
PUBLISH=$(sha 12)
write_pr 41 "$PUBLISH" 201 fork/alice relay-branch alice 2026-09-25T09:00:00Z
jq -n --argjson base "$BASE_ID" --argjson head 201 --arg source fork/alice --arg branch relay-branch '[{number:41,created_at:"2026-09-25T09:00:00Z",base:{repo:{id:$base}},head:{repo:{id:$head,full_name:$source},ref:$branch}}]' >"$CANDIDATES"
write_run pull_request_review "$SRC" 201 fork/alice relay-branch '[]' '.github/workflows/codex-p1-gate.yml@refs/heads/main'
run_case 41
assert_eq "$RC" 0 "empty-association pull_request_review binds a unique fork branch"
assert_eq "$(printf '%s' "$OUTPUT" | jq -r .publish_head_sha)" "$PUBLISH" "review relay publishes on current PR API head"
assert_eq "$(printf '%s' "$OUTPUT" | jq -r .source_head_sha)" "$SRC" "review relay retains historical source head separately"
assert_empty_writes "binding helper never mutates while resolving a review source"

# The same empty-association shape is documented for review-comment events.
write_run pull_request_review_comment "$SRC" 201 fork/alice relay-branch '[]' '.github/workflows/codex-p1-gate.yml'
run_case 41
assert_eq "$RC" 0 "empty-association pull_request_review_comment binds a unique fork branch"
assert_eq "$(printf '%s' "$OUTPUT" | jq -r .source_event)" pull_request_review_comment "review-comment event is preserved in the binding"

# issue_comment runs execute from the trusted default branch. Its run head is
# deliberately not compared to the PR head, and a same-repository Dependabot
# PR still requires the relay.
ISSUE_HEAD=$(sha 31)
DEP_HEAD=$(sha 32)
write_pr 42 "$DEP_HEAD" "$BASE_ID" "$BASE_REPO" dependabot/npm/foo dependabot[bot] 2026-09-25T09:00:00Z
jq -n '[]' >"$CANDIDATES"
RUN_PR=42 write_run issue_comment "$ISSUE_HEAD" "$BASE_ID" "$BASE_REPO" main '[]' '.github/workflows/codex-p1-gate.yml@refs/heads/main'
run_case 42
assert_eq "$RC" 0 "default-branch issue_comment binds its PR despite a different run head"
assert_eq "$(printf '%s' "$OUTPUT" | jq -r .publish_head_sha)" "$DEP_HEAD" "issue-comment publication head comes from the PR API"
assert_eq "$(printf '%s' "$OUTPUT" | jq -r .requires_relay)" true "same-repository Dependabot PR still requires relay"

# Match the producer's classification field directly. A repository that is
# itself a fork can host a same-name PR head with `fork: true`; origin binding
# still uses ids/branch, while relay classification must remain true.
write_pr 43 "$(sha 43)" "$BASE_ID" "$BASE_REPO" fork-base-branch alice 2026-09-25T09:00:00Z true
jq -n --argjson base "$BASE_ID" --arg source "$BASE_REPO" --arg branch fork-base-branch '[{number:43,created_at:"2026-09-25T09:00:00Z",base:{repo:{id:$base}},head:{repo:{id:$base,full_name:$source},ref:$branch}}]' >"$CANDIDATES"
RUN_PR=43 write_run pull_request "$(sha 43)" "$BASE_ID" "$BASE_REPO" fork-base-branch '[]' '.github/workflows/codex-p1-gate.yml'
run_case 43
assert_eq "$RC" 0 "same-name head with GitHub fork flag binds normally"
assert_eq "$(printf '%s' "$OUTPUT" | jq -r .requires_relay)" true "relay classification follows head.repo.fork rather than name equality"

# An artifact or title that names PR 77 cannot override the source origin: the
# unique branch candidate is PR 41, so helper stays inert for PR 77.
write_pr 77 "$(sha 77)" 202 fork/bob victim-branch bob 2026-09-25T09:00:00Z
jq -n --argjson base "$BASE_ID" --argjson head 201 --arg source fork/alice --arg branch relay-branch '[{number:41,created_at:"2026-09-25T09:00:00Z",base:{repo:{id:$base}},head:{repo:{id:$head,full_name:$source},ref:$branch}}]' >"$CANDIDATES"
RUN_PR=77 write_run pull_request "$SRC" 201 fork/alice relay-branch '[]' '.github/workflows/codex-p1-gate.yml'
run_case 77
assert_eq "$RC" 4 "wrong-title cross-PR candidate is rejected before any writer can arm"
assert_empty_writes "wrong-title cross-PR binding makes no mutation"

# A contradictory nonempty association is rejection, never permission to fall
# back to the title or the origin query.
jq -n --argjson base "$BASE_ID" '{number:77,base:{repo:{id:$base}},head:{repo:{id:202},ref:"victim-branch"}} | [.]' >"$TMP/associations.json"
RUN_PR=41 write_run pull_request "$SRC" 201 fork/alice relay-branch "$(cat "$TMP/associations.json")" '.github/workflows/codex-p1-gate.yml'
run_case 41
assert_eq "$RC" 4 "contradictory source association is rejected without title fallback"
assert_empty_writes "contradictory association creates no mutation"

# Two historical PRs for one source branch are intentionally unavailable: do
# not choose the first target or let a reused branch acquire a later PR.
jq -n --argjson base "$BASE_ID" --argjson head 201 --arg source fork/alice --arg branch relay-branch '[41,43] | map({number:.,created_at:"2026-09-25T09:00:00Z",base:{repo:{id:$base}},head:{repo:{id:$head,full_name:$source},ref:$branch}})' >"$CANDIDATES"
write_run pull_request "$SRC" 201 fork/alice relay-branch '[]' '.github/workflows/codex-p1-gate.yml'
run_case 41
assert_eq "$RC" 4 "ambiguous reused source branch is rejected"
assert_empty_writes "ambiguous source branch creates no mutation"

# A title pointing at another branch in the same fork cannot rely on repository
# identity alone; exact source branch equality is load-bearing.
write_pr 78 "$(sha 78)" 201 fork/alice different-branch alice 2026-09-25T09:00:00Z
RUN_PR=78 write_run pull_request "$SRC" 201 fork/alice relay-branch '[]' '.github/workflows/codex-p1-gate.yml'
run_case 78
assert_eq "$RC" 4 "same-fork wrong-branch candidate is rejected"
assert_empty_writes "same-fork wrong-branch candidate creates no mutation"

# A reused branch must not let an old source run acquire a PR created later.
write_pr 79 "$(sha 79)" 201 fork/alice relay-branch alice 2026-09-27T09:00:00Z
RUN_PR=79 write_run pull_request "$SRC" 201 fork/alice relay-branch '[]' '.github/workflows/codex-p1-gate.yml'
run_case 79
assert_eq "$RC" 4 "source run cannot bind a PR created after the run"
assert_empty_writes "later-created branch reuse creates no mutation"

# A malformed candidate response is an infrastructure result, distinct from a
# title/source mismatch, so callers can retry but may not publish meanwhile.
printf '{}\n' >"$TMP/pr-80.json"
PR_80="$TMP/pr-80.json"; export PR_80
RUN_PR=80 write_run pull_request "$SRC" 201 fork/alice relay-branch '[]' '.github/workflows/codex-p1-gate.yml'
run_case 80
assert_eq "$RC" 3 "malformed candidate PR response fails as infrastructure"
assert_empty_writes "malformed candidate response creates no mutation"

# The recovery writer is a privileged sink. Execute the run block extracted
# from the actual workflow, rather than duplicating it: a forged title/source
# mismatch must reach its inert exit before a check POST, while a valid delayed
# run must POST against publish_head_sha (the current PR API head), never the
# historical source/artifact head.
RECOVERY="$TMP/recovery.sh"
awk '
  /name: Publish a PR-head failure when source resolution errors/ { active=1 }
  active && /^      - name: Locate the read-only handoff artifact/ { exit }
  active && /^        run: \|$/ { body=1; next }
  body { sub(/^          /, ""); print }
' "$ROOT/.github/workflows/codex-feedback-archive-relay.yml" >"$RECOVERY"
[ -s "$RECOVERY" ] || { echo "could not extract relay recovery writer" >&2; exit 1; }
chmod +x "$RECOVERY"
run_recovery() {
  : >"$GH_LOG"
  jq -n --argjson pr "$1" --arg event "$2" --arg head "$3" --argjson repo_id "$4" \
    --arg repo "$5" --arg branch "$6" --argjson associations "$7" --arg path "$8" \
    --arg created "$RUN_AT" '{workflow_run:{id:501,display_title:("Codex P1 Gate relay-v1 PR #" + ($pr|tostring)),event:$event,path:$path,head_sha:$head,head_branch:$branch,head_repository:{id:$repo_id,full_name:$repo},repository:{id:100,full_name:"acme/widget"},created_at:$created,pull_requests:$associations}}' >"$TMP/event.json"
  set +e
  PATH="$BIN:$PATH" GH_LOG="$GH_LOG" CANDIDATES="$CANDIDATES" \
    GITHUB_EVENT_PATH="$TMP/event.json" RUNNER_TEMP="$TMP" REPO="$BASE_REPO" \
    SOURCE_RUN_ID=501 CHECK_NAME='Codex P1 unresolved threads' "$RECOVERY" >"$TMP/recovery.out" 2>"$TMP/recovery.err"
  RECOVERY_RC=$?
  set -e
}

# The recovery must rebind; a source from Alice cannot publish a failure onto
# title-selected Bob PR 77, even though that PR is a fork and has a real head.
run_recovery 77 pull_request "$SRC" 201 fork/alice relay-branch '[]' '.github/workflows/codex-p1-gate.yml'
assert_eq "$RECOVERY_RC" 1 "actual recovery writer exits without publication for an unbound title target"
assert_empty_writes "actual recovery writer makes no target-PR mutation after failed binding"

# A delayed valid source binds PR 41 and the writer publishes the API head 12,
# not source head 11. This is the recovery path's real POST command.
jq -n --argjson base "$BASE_ID" --argjson head 201 --arg source fork/alice --arg branch relay-branch '[{number:41,created_at:"2026-09-25T09:00:00Z",base:{repo:{id:$base}},head:{repo:{id:$head,full_name:$source},ref:$branch}}]' >"$CANDIDATES"
run_recovery 41 pull_request "$SRC" 201 fork/alice relay-branch '[]' '.github/workflows/codex-p1-gate.yml@refs/heads/main'
assert_eq "$RECOVERY_RC" 1 "actual recovery writer reports its source-step failure after publishing bound failure"
if grep -F -- $'--method\tPOST\trepos/acme/widget/check-runs' "$GH_LOG" >/dev/null \
  && grep -F -- $'head_sha=0000000000000000000000000000000000000012' "$GH_LOG" >/dev/null \
  && ! grep -F -- $'head_sha=0000000000000000000000000000000000000011' "$GH_LOG" >/dev/null; then
  pass "actual recovery writer publishes only the bound PR API head"
else
  fail "actual recovery writer did not target the bound PR API head: $(cat "$GH_LOG")"
fi

# Execute the actual persist writer from the workflow in a scratch trusted
# checkout. The two locally supplied commands are only its gate/fingerprint
# dependencies; all relay source, lease, archive, marker, PATCH, and artifact
# operations remain the extracted production block and the same gh shim.
PERSIST="$TMP/persist.sh"
awk '
  /name: Persist archive and publish the exact-head gate/ { active=1 }
  active && /^      - name: Close an abandoned read-only relay lease/ { exit }
  active && /^        run: \|$/ { body=1; next }
  body { sub(/^          /, ""); print }
' "$ROOT/.github/workflows/codex-feedback-archive-relay.yml" >"$PERSIST"
[ -s "$PERSIST" ] || { echo "could not extract relay persist writer" >&2; exit 1; }
chmod +x "$PERSIST"
TRUSTED="$TMP/trusted"
mkdir -p "$TRUSTED/scripts"
cat >"$TRUSTED/scripts/review-feedback-surface-fingerprint.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "${TEST_FINGERPRINT:-fingerprint}"
SH
cat >"$TRUSTED/scripts/codex-p1-gate.sh" <<'SH'
#!/usr/bin/env bash
printf 'fake Codex P1 gate on expected head %s\n' "${CODEX_P1_EXPECTED_HEAD_SHA:-}"
exit "${TEST_GATE_RC:-0}"
SH
chmod +x "$TRUSTED/scripts/review-feedback-surface-fingerprint.sh" "$TRUSTED/scripts/codex-p1-gate.sh"
HANDOFF="$TMP/handoff.json"
ARCHIVE='<!-- mergepath-feedback-archive-relay:v1 run=777 status=complete -->'
write_handoff() {
  # event, artifact/source head; persist supplies the rest from trusted binding.
  jq -n --arg repo "$BASE_REPO" --argjson pr 41 --argjson run 501 --arg event "$1" --arg head "$2" \
    --arg actor alice --arg archive "$ARCHIVE" '{version:1,repo:$repo,pr:$pr,source_run_id:$run,requires_relay:true,is_fork:true,pr_actor:$actor,event_name:$event,head_sha:$head,archive_records:[$archive]}' >"$HANDOFF"
}
run_persist() {
  : >"$GH_LOG"
  rm -f "${HEAD_SEQUENCE_FILE:-}.count" 2>/dev/null || true
  set +e
  (cd "$TRUSTED" && PATH="$BIN:$PATH" GH_LOG="$GH_LOG" CANDIDATES="$CANDIDATES" \
    HEAD_SEQUENCE_FILE="$HEAD_SEQUENCE_FILE" RUNNER_TEMP="$TMP" REPO="$BASE_REPO" \
    PR_NUMBER=41 SOURCE_RUN_ID=501 ARTIFACT_ID=700 EXPECTED_IS_FORK=true \
    EXPECTED_PR_ACTOR=alice EXPECTED_SOURCE_EVENT="$1" EXPECTED_SOURCE_HEAD="$2" \
    HANDOFF_FILE="$HANDOFF" CHECK_NAME='Codex P1 unresolved threads' \
    GITHUB_OUTPUT="$TMP/persist-output" "$PERSIST") \
    >"$TMP/persist.out" 2>"$TMP/persist.err"
  PERSIST_RC=$?
  set -e
}

# A forged artifact event/head is rejected before the lease or archive writer.
write_handoff pull_request "$(sha 88)"
HEAD_SEQUENCE_FILE="$TMP/persist-heads"
printf '%s\n' "$PUBLISH" "$PUBLISH" "$PUBLISH" >"$HEAD_SEQUENCE_FILE"
run_persist pull_request "$SRC"
assert_eq "$PERSIST_RC" 1 "actual persist writer rejects an artifact with a wrong source head"
assert_empty_writes "wrong artifact source head reaches no lease or archive writer"
write_handoff pull_request_review "$SRC"
run_persist pull_request "$SRC"
assert_eq "$PERSIST_RC" 1 "actual persist writer rejects an artifact with a wrong event"
assert_empty_writes "wrong artifact event reaches no lease or archive writer"

# A valid delayed archive preserves its historical record but opens and
# evaluates the lease at the current bound API head, not the handoff source.
write_handoff pull_request "$SRC"
printf '%s\n' "$PUBLISH" "$PUBLISH" "$PUBLISH" >"$HEAD_SEQUENCE_FILE"
run_persist pull_request "$SRC"
assert_eq "$PERSIST_RC" 0 "actual persist writer accepts a valid delayed source archive"
if grep -F -- $'--method\tPOST\trepos/acme/widget/check-runs' "$GH_LOG" >/dev/null \
  && grep -F -- $'head_sha=0000000000000000000000000000000000000012' "$GH_LOG" >/dev/null \
  && ! grep -F -- $'head_sha=0000000000000000000000000000000000000011' "$GH_LOG" >/dev/null \
  && grep -F -- "$ARCHIVE" "$GH_LOG" >/dev/null \
  && grep -F -- 'conclusion=success' "$GH_LOG" >/dev/null \
  && grep -F -- "fake Codex P1 gate on expected head $PUBLISH" "$GH_LOG" >/dev/null; then
  pass "actual persist writer archives, gates, and publishes only the current PR API head"
else
  fail "actual persist writer did not preserve delayed archive/current-head separation: $(cat "$GH_LOG")"
fi

# If the head moves only at the final read, the existing lease is closed as a
# failure; no second lease is opened on the newly observed head.
NEW_HEAD=$(sha 13)
printf '%s\n' "$PUBLISH" "$PUBLISH" "$NEW_HEAD" >"$HEAD_SEQUENCE_FILE"
run_persist pull_request "$SRC"
assert_eq "$PERSIST_RC" 0 "head drift closes the existing persist invocation"
if [ "$(grep -Fc -- $'--method\tPOST\trepos/acme/widget/check-runs' "$GH_LOG")" -eq 1 ] \
  && grep -F -- $'--method\tPATCH\trepos/acme/widget/check-runs/900' "$GH_LOG" >/dev/null \
  && grep -F -- 'conclusion=failure' "$GH_LOG" >/dev/null \
  && ! grep -F -- "head_sha=$NEW_HEAD" "$GH_LOG" >/dev/null; then
  pass "final head movement fails only its old lease without retargeting the new head"
else
  fail "head movement retargeted or cleared a new head: $(cat "$GH_LOG")"
fi

# Failure publishers have a positively bound API-head snapshot available from
# the source step. Execute both actual blocks with a failed *fresh* head read:
# they must still retract a prior success on that known bound head rather than
# leaving it untouched or selecting an artifact/source head.
MISSING="$TMP/missing-handoff.sh"
awk '
  /name: Fail permanently when a read-only handoff is missing/ { active=1 }
  active && /^      - name: Download the inert read-only handoff/ { exit }
  active && /^        run: \|$/ { body=1; next }
  body { sub(/^          /, ""); print }
' "$ROOT/.github/workflows/codex-feedback-archive-relay.yml" >"$MISSING"
[ -s "$MISSING" ] || { echo "could not extract missing-handoff writer" >&2; exit 1; }
chmod +x "$MISSING"
run_missing_handoff() {
  : >"$GH_LOG"
  set +e
  PATH="$BIN:$PATH" GH_LOG="$GH_LOG" CANDIDATES="$CANDIDATES" FAIL_PR_HEAD_READ=true \
    RUNNER_TEMP="$TMP" REPO="$BASE_REPO" PR_NUMBER=41 SOURCE_RUN_ID=501 \
    BOUND_HEAD_SHA="$PUBLISH" CHECK_NAME='Codex P1 unresolved threads' "$MISSING" \
    >"$TMP/missing.out" 2>"$TMP/missing.err"
  MISSING_RC=$?
  set -e
}
run_missing_handoff
assert_eq "$MISSING_RC" 1 "actual missing-handoff writer retains its failure result after fresh read failure"
if grep -F -- $'--method\tPOST\trepos/acme/widget/check-runs' "$GH_LOG" >/dev/null \
  && grep -F -- "head_sha=$PUBLISH" "$GH_LOG" >/dev/null \
  && ! grep -F -- "head_sha=$SRC" "$GH_LOG" >/dev/null; then
  pass "missing-handoff writer falls back to the known bound API head"
else
  fail "missing-handoff writer lost its bound-head failure fallback: $(cat "$GH_LOG")"
fi

CLEANUP="$TMP/cleanup.sh"
awk '
  /name: Close an abandoned read-only relay lease/ { active=1 }
  active && /^      - name: / && !/Close an abandoned read-only relay lease/ { exit }
  active && /^        run: \|$/ { body=1; next }
  body { sub(/^          /, ""); print }
' "$ROOT/.github/workflows/codex-feedback-archive-relay.yml" >"$CLEANUP"
[ -s "$CLEANUP" ] || { echo "could not extract relay cleanup writer" >&2; exit 1; }
chmod +x "$CLEANUP"
: >"$GH_LOG"
set +e
PATH="$BIN:$PATH" GH_LOG="$GH_LOG" CANDIDATES="$CANDIDATES" FAIL_PR_HEAD_READ=true \
  RUNNER_TEMP="$TMP" REPO="$BASE_REPO" PR_NUMBER=41 SOURCE_RUN_ID=501 CHECK_ID='' \
  BOUND_HEAD_SHA="$PUBLISH" CHECK_NAME='Codex P1 unresolved threads' "$CLEANUP" \
  >"$TMP/cleanup.out" 2>"$TMP/cleanup.err"
CLEANUP_RC=$?
set -e
assert_eq "$CLEANUP_RC" 0 "actual no-lease cleanup completes its bound-head failure publication"
if grep -F -- $'--method\tPOST\trepos/acme/widget/check-runs' "$GH_LOG" >/dev/null \
  && grep -F -- "head_sha=$PUBLISH" "$GH_LOG" >/dev/null \
  && ! grep -F -- "head_sha=$SRC" "$GH_LOG" >/dev/null; then
  pass "no-lease cleanup falls back to the known bound API head"
else
  fail "no-lease cleanup lost its bound-head failure fallback: $(cat "$GH_LOG")"
fi

if [ "$FAIL" -ne 0 ]; then
  printf 'feedback-archive-relay-source: FAIL (%s failed, %s passed)\n' "$FAIL" "$PASS" >&2
  exit 1
fi
printf 'feedback-archive-relay-source: PASS (%s assertions)\n' "$PASS"
