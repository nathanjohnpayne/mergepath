#!/usr/bin/env bash
# Trusted Dependabot approval/author phases (#1547). Each invocation receives
# only its own protected-environment PAT. Cross-job outputs are inert tuples.
set -euo pipefail

latest_check_run() {
  gh api --paginate -X GET "repos/${GITHUB_REPOSITORY}/commits/$2/check-runs" \
    -f check_name="$1" -F per_page=100 \
    | jq -sc --arg check "$1" '[.[] | .check_runs[] | select(.name == $check)] | sort_by(.started_at // .created_at) | last // empty'
}

require_current_head_check_success() {
  local sha runs conclusion status wait_seconds poll_seconds deadline required_check_name ever_seen
  # Optional explicit name so the plural wrapper below can loop
  # this unchanged; with no argument the previous env behaviour is
  # exactly preserved.
  required_check_name=${1:-${REQUIRED_HEAD_CHECK_NAME:-lint}}
  wait_seconds=${TEST_CHECK_WAIT_SECONDS:-1200}
  poll_seconds=${TEST_CHECK_POLL_SECONDS:-15}
  deadline=$((SECONDS + wait_seconds))
  ever_seen=0
  sha=$(gh pr view "$PR_URL" --json headRefOid --jq .headRefOid)
  while :; do
    runs=$(latest_check_run "$required_check_name" "$sha")
    if [ -n "$runs" ]; then
      ever_seen=1
      status=$(printf '%s' "$runs" | jq -r '.status')
      conclusion=$(printf '%s' "$runs" | jq -r '.conclusion // ""')
      if [ "$status" = "completed" ]; then
        if [ "$conclusion" = "success" ]; then
          CURRENT_HEAD_SHA="$sha"
          echo "::notice::Required check run '$required_check_name' is successful on current HEAD $CURRENT_HEAD_SHA."
          return 0
        fi
        echo "::error::Required check run '$required_check_name' failed on current HEAD $sha (conclusion=${conclusion:-none}); refusing auto-merge."
        exit 1
      fi
      echo "::notice::Required check run '$required_check_name' is $status on current HEAD $sha; waiting for completion."
    else
      echo "::notice::Required check run '$required_check_name' is absent on current HEAD $sha; waiting for it to start."
    fi
    if [ "$SECONDS" -ge "$deadline" ]; then
      # Deliberately still the full deadline, and still a hard
      # refusal: a check that genuinely never ran is a real
      # reason not to auto-merge, and shortening the wait would
      # break repos whose CI is slow to schedule. Only the
      # diagnostics split. The old message claimed the check
      # "did not complete successfully" even when it had never
      # appeared at all, which is what made the #524 truncation
      # bug read as a CI failure and cost an hour of digging.
      if [ "$ever_seen" -eq 0 ]; then
        echo "::error::Required check run '$required_check_name' never appeared on current HEAD $sha within ${wait_seconds}s; refusing auto-merge."
        echo "::error::The check never started, or REQUIRED_HEAD_CHECK_NAME does not match any check name in this repo. Compare against: gh api -X GET repos/${GITHUB_REPOSITORY}/commits/$sha/check-runs --paginate --jq '.check_runs[].name' | sort -u"
      else
        echo "::error::Required check run '$required_check_name' did not complete successfully within ${wait_seconds}s on current HEAD $sha; refusing auto-merge."
      fi
      exit 1
    fi
    sleep "$poll_seconds"
  done
  echo "::error::Required check run '$required_check_name' wait loop ended unexpectedly; refusing auto-merge."
  exit 1
}

require_current_head_checks_success() {
  local wait_seconds poll_seconds deadline pinned attempts max_attempts
  wait_seconds=${TEST_CHECK_WAIT_SECONDS:-1200}
  poll_seconds=${TEST_CHECK_POLL_SECONDS:-15}
  max_attempts=${HEAD_DRIFT_MAX_RESTARTS:-3}
  attempts=0
  while :; do
    attempts=$((attempts + 1))
    pinned=$(gh pr view "$PR_URL" --json headRefOid --jq .headRefOid)
    if [ -z "$pinned" ]; then
      echo "::error::Could not resolve the PR head SHA; refusing auto-merge."
      exit 1
    fi
    deadline=$((SECONDS + wait_seconds))
    while :; do
      # Capture the verifier's OWN status. `rc=$?` after a failed
      # `if` reads the compound statement's status (0), not the
      # command's -- which would take the fail-closed branch on the
      # first not-ready poll and never wait at all.
      rc=0
      if [ ! -f scripts/required-head-checks.sh ]; then
        # First-rollout guard (#1070); see agent-review.yml for why
        # this falls back rather than failing closed.
        echo "::notice::scripts/required-head-checks.sh absent (pre-#1070 checkout); falling back to the singular waiter."
        require_current_head_check_success
        CURRENT_HEAD_SHA="$pinned"
        return 0
      fi
      bash scripts/required-head-checks.sh --repo "$GITHUB_REPOSITORY" --verify --sha "$pinned" || rc=$?
      if [ "$rc" -eq 0 ]; then
        break
      fi
      if [ "$rc" -ne 1 ]; then
        echo "::error::required-head-checks failed closed (rc=$rc); refusing auto-merge."
        exit 1
      fi
      if [ "$SECONDS" -ge "$deadline" ]; then
        echo "::error::Timed out waiting for the configured required head checks on $pinned."
        exit 1
      fi
      sleep "$poll_seconds"
    done
    # Every configured check is green on $pinned. Accept only if the
    # head has not moved underneath the verdict.
    if [ "$(gh pr view "$PR_URL" --json headRefOid --jq .headRefOid)" = "$pinned" ]; then
      CURRENT_HEAD_SHA="$pinned"
      echo "::notice::All configured required head checks are successful on $CURRENT_HEAD_SHA."
      return 0
    fi
    if [ "$attempts" -ge "$max_attempts" ]; then
      echo "::error::PR head kept moving during check verification; refusing auto-merge."
      exit 1
    fi
    echo "::notice::PR head moved during verification; re-pinning and re-verifying."
  done
}

require_dependabot_provenance() {
  local sha=$1 rc=0
  dependabot_commit_provenance "$GITHUB_REPOSITORY" "$PR_NUMBER" "$sha" || rc=$?
  if [ "$rc" -eq 0 ]; then
    return 0
  fi
  if [ "$rc" -eq 1 ]; then
    echo "::warning::PR head $sha is not Dependabot-only ($DEPENDABOT_PROVENANCE_REASON); not approving or merging. It needs ordinary review."
    # An earlier run of this job may have armed native auto-merge
    # on a then-clean head, and GitHub keeps that request across
    # pushes by write collaborators. Withdraw it before stopping.
    armed=$(gh pr view "$PR_URL" --json autoMergeRequest --jq 'if .autoMergeRequest == null then "false" else "true" end')
    if [ "$armed" = "true" ]; then
      GH_TOKEN="${WORKFLOW_GH_TOKEN:?workflow token required for protective cleanup}" gh pr merge --disable-auto "$PR_URL" # NO_BARE_GH_WRITE_EXEMPT: trusted Actions protective cleanup under GITHUB_TOKEN; no reviewer/author PAT carries this write
      echo "::warning::Withdrew the auto-merge request after provenance became untrusted."
    fi
    exit 0
  fi
  echo "::error::Could not verify Dependabot commit provenance on $sha: $DEPENDABOT_PROVENANCE_REASON. Refusing auto-merge."
  exit 1
}

has_human_hold() {
  local labels
  if ! labels=$(gh pr view "$PR_URL" --json labels --jq '.labels[].name'); then
    echo "::error::Failed to read labels for $PR_URL while checking human-hold."
    exit 1
  fi
  printf '%s\n' "$labels" | grep -Fxq human-hold
}

# Re-read the stop label immediately before each actual writer, including
# after approval/accounting reads. This is a bounded fence, not an atomic lock.
human_hold_fence() {
  if has_human_hold; then
    echo '::notice::human-hold is present immediately before the writer; leaving the PR untouched.'
    exit 0
  fi
}

refuse() { echo "::error::$*" >&2; exit 1; }

read_live_binding() {
  LIVE_PR=$(gh api "repos/$GITHUB_REPOSITORY/pulls/$PR_NUMBER") || refuse 'Cannot read the live PR binding.'
  jq -e --arg repo "$GITHUB_REPOSITORY" --argjson pr "$PR_NUMBER" --arg head "$BOUND_HEAD" --arg base "$BOUND_BASE" --arg ref "$DEFAULT_BRANCH" '
    .number == $pr and .state == "open" and .draft == false
    and .user.login == "dependabot[bot]" and .head.sha == $head
    and .base.sha == $base and .base.ref == $ref and .base.repo.full_name == $repo
  ' <<<"$LIVE_PR" >/dev/null || refuse 'Live opener, state, head or governing base changed; refusing this invocation.'
}

load_governing_identities() {
  POLICY=$(bash scripts/workflow/resolve_base_policy.sh --repo "$GITHUB_REPOSITORY" --base-ref "$DEFAULT_BRANCH" --base-sha "$BOUND_BASE" --default-branch "$DEFAULT_BRANCH" --default-config .github/review-policy.yml --materialize-default) || refuse 'Cannot resolve governing base policy.'
  ALLOWED=$(read_available_reviewers "$POLICY")
  [ -n "$ALLOWED" ] || refuse 'Governing available_reviewers is empty.'
  ALLOWED_JSON=$(printf '%s\n' "$ALLOWED" | jq -R . | jq -s .)
  EXPECTED_AUTHOR=$(awk '
    /^[^[:space:]]/ && $1 == "author_identity:" {
      sub(/^[[:space:]]*[^:]+:[[:space:]]*/, "", $0)
      gsub(/^"/, "", $0); gsub(/^\047/, "", $0)
      gsub(/"[[:space:]]*(#.*)?$/, "", $0); gsub(/\047[[:space:]]*(#.*)?$/, "", $0)
      gsub(/[[:space:]]*#.*$/, "", $0); sub(/[[:space:]]+$/, "", $0)
      print; exit
    }' "$POLICY")
  # Preserve this Dependabot lane's pre-existing #426 default when the
  # optional policy scalar is absent/empty. A configured author still wins.
  EXPECTED_AUTHOR=${EXPECTED_AUTHOR:-nathanjohnpayne}
  [ -n "$EXPECTED_AUTHOR" ] || refuse 'Resolved author identity is empty.'
  if policy_list_has_unconsumed_inline_value non_reviewer_identities "$POLICY"; then
    refuse 'Governing non_reviewer_identities is unreadable.'
  fi
  if login_is_available_reviewer "$EXPECTED_AUTHOR" "$POLICY"; then
    refuse 'Governing author_identity must be distinct from available_reviewers.'
  fi
}

verify_phase_identity() {
  local identity
  [ -n "${GH_TOKEN:-}" ] || refuse 'The protected environment PAT is empty.'
  identity=$(gh api user) || refuse 'Cannot positively verify the protected environment PAT.'
  ACTING_AS=$(jq -er 'select(.type == "User") | .login | select(type == "string" and length > 0)' <<<"$identity") || refuse 'A nonempty User identity is required; an automation App has no reviewer standing.'
  if [ "$PHASE" = approve ]; then
    [ "$ACTING_AS" != 'dependabot[bot]' ] || refuse 'Reviewer cannot be the PR author.'
    login_is_available_reviewer "$ACTING_AS" "$POLICY" || refuse 'Reviewer is not in governing available_reviewers.'
    if login_is_non_reviewer_identity "$ACTING_AS" "$POLICY"; then refuse 'Reviewer is a declared non-reviewer identity.'; fi
  else
    [ "$ACTING_AS" = "$EXPECTED_AUTHOR" ] || refuse 'AUTHOR_MERGE_TOKEN does not resolve to governing author_identity.'
    login_is_available_reviewer "$ACTING_AS" "$POLICY" && refuse 'Author cannot have reviewer standing.'
  fi
  # The verified User identities are disjoint under the same governing policy.
  # One credential cannot satisfy both roles; no secret or secret digest crosses jobs.
  return 0
}

require_current_approval() {
  local reviewer=${1:-} reviews
  reviews=$(gh_api_array "repos/$GITHUB_REPOSITORY/pulls/$PR_NUMBER/reviews?per_page=100" 'current-head approvals') || refuse 'Approval history is unreadable.'
  jq -e --arg head "$BOUND_HEAD" --arg reviewer "$reviewer" --arg author "$EXPECTED_AUTHOR" --argjson allowed "$ALLOWED_JSON" '
    [.[] | select(.commit_id == $head)
     | select(.state == "APPROVED" or .state == "CHANGES_REQUESTED" or .state == "DISMISSED")
     | select(.user.type == "User" and (.user.login | type == "string") and .user.login != "" and .user.login != "dependabot[bot]" and .user.login != $author)
     | select(.user.login as $u | $allowed | index($u))]
    | group_by(.user.login) | map(max_by([.submitted_at // "", .id // 0]))
    | any(.[]; .state == "APPROVED" and ($reviewer == "" or .user.login == $reviewer))
  ' <<<"$reviews" >/dev/null || refuse 'No positive latest-state registered User approval on the exact live head.'
}

writer_fence() {
  read_live_binding
  require_dependabot_provenance "$BOUND_HEAD"
  verify_phase_identity
  human_hold_fence
  read_live_binding
}

require_merge_clearance() {
  [ -x scripts/merge-clearance-gate.sh ] || refuse 'Trusted merge-clearance gate is missing.'
  bash scripts/merge-clearance-gate.sh "$PR_NUMBER" "$GITHUB_REPOSITORY" || refuse 'Current-head merge clearance is not satisfied.'
}

approve_dependabot() {
  local response review_id readback
  APPROVE_SHA=$(gh pr view "$PR_URL" --json headRefOid --jq .headRefOid)
  [ "$APPROVE_SHA" = "$BOUND_HEAD" ] || refuse 'Head moved before approval.'
  require_dependabot_provenance "$APPROVE_SHA"
  writer_fence
  human_hold_fence
  response=$(gh api -X POST "repos/$GITHUB_REPOSITORY/pulls/$PR_NUMBER/reviews" -f commit_id="$APPROVE_SHA" -f event=APPROVE) || refuse 'Approval write failed; not retrying an ambiguous result.' # NO_BARE_GH_WRITE_EXEMPT: trusted Actions Dependabot reviewer phase, isolated reviewer-maintenance PAT after exact identity/provenance/hold fences; never an interactive agent write
  review_id=$(jq -er --arg head "$BOUND_HEAD" --arg user "$ACTING_AS" 'select(.state == "APPROVED" and .commit_id == $head and .user.login == $user and .user.type == "User") | .id | select(type == "number" and . > 0 and floor == .)' <<<"$response") || refuse 'Approval response did not positively bind the reviewer and full head.'
  readback=$(gh api "repos/$GITHUB_REPOSITORY/pulls/$PR_NUMBER/reviews/$review_id") || refuse 'Approval readback failed.'
  jq -e --argjson id "$review_id" --arg head "$BOUND_HEAD" --arg user "$ACTING_AS" '.id == $id and .state == "APPROVED" and .commit_id == $head and .user.login == $user and .user.type == "User"' <<<"$readback" >/dev/null || refuse 'Approval readback does not match the written object.'
  require_current_approval "$ACTING_AS"
  read_live_binding
  # Inert routing metadata, never an authorization or credential carrier.
  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    printf 'repo=%s\npr=%s\nhead=%s\nbase=%s\nbase_ref=%s\n' "$GITHUB_REPOSITORY" "$PR_NUMBER" "$BOUND_HEAD" "$BOUND_BASE" "$DEFAULT_BRANCH" >>"$GITHUB_OUTPUT"
  fi
}

merge_dependabot() {
  local AUTO_STDERR AUTO_RC ACCOUNTING_JSON ACCOUNTING_RC
  # Major development groups retain approval only. Neither merge path runs.
  if [ "$UPDATE_TYPE" != 'version-update:semver-patch' ] && [ "$UPDATE_TYPE" != 'version-update:semver-minor' ]; then
    echo '::notice::Major development group remains approved-but-unmerged.'
    return 0
  fi
  require_current_head_checks_success
  require_dependabot_provenance "$CURRENT_HEAD_SHA"
  [ "$CURRENT_HEAD_SHA" = "$BOUND_HEAD" ] || refuse 'CI verification moved beyond the cross-job head binding.'
  require_current_approval
  require_merge_clearance
  writer_fence
  require_current_approval
  human_hold_fence
  set +e
  AUTO_STDERR=$(gh pr merge --squash --auto --match-head-commit "$CURRENT_HEAD_SHA" "$PR_URL" 2>&1 1>/dev/null) # NO_BARE_GH_WRITE_EXEMPT: trusted Actions author phase under isolated merge-queue-policy author PAT after current-head approval/gate/hold/provenance checks; never an interactive agent write
  AUTO_RC=$?
  set -e
  if [ "$AUTO_RC" -eq 0 ]; then return 0; fi
  printf '%s\n' "$AUTO_STDERR" >&2
  if ! grep -qiE 'auto[- ]?merge is not available|not in the correct state to enable auto[- ]?merge|auto[- ]?merge.*disabled|protected branch rules not configured' <<<"$AUTO_STDERR"; then
    refuse 'Auto-merge failed for a reason other than its known unavailability; no immediate retry.'
  fi
  require_current_head_checks_success
  require_dependabot_provenance "$CURRENT_HEAD_SHA"
  [ "$CURRENT_HEAD_SHA" = "$BOUND_HEAD" ] || refuse 'Head changed during fallback CI verification.'
  require_current_approval
  local FEEDBACK_ACCOUNTING_GATE="${MERGEPATH_REVIEW_FEEDBACK_ACCOUNTING_CMD:-scripts/review-feedback-accounting.sh}"
  [ -x "$FEEDBACK_ACCOUNTING_GATE" ] || refuse 'Trusted feedback accounting gate is missing.'
  ACCOUNTING_RC=0
  ACCOUNTING_JSON=$(GH_TOKEN="$WORKFLOW_GH_TOKEN" "$FEEDBACK_ACCOUNTING_GATE" "$PR_NUMBER" "$GITHUB_REPOSITORY") || ACCOUNTING_RC=$?
  if [ "$ACCOUNTING_RC" -ne 0 ]; then
    printf '%s\n' "$ACCOUNTING_JSON" >&2
    refuse 'Feedback accounting failed; no immediate squash.'
  fi
  [ -x scripts/codex-review-check.sh ] || refuse 'Trusted native/API readiness gate is missing.'
  GH_TOKEN="$WORKFLOW_GH_TOKEN" SKIP_CI=0 REQUIRE_APPROVAL_ON_HEAD=1 bash scripts/codex-review-check.sh --approval-readiness-only "$PR_NUMBER" "$GITHUB_REPOSITORY" || refuse 'Native/API required checks or current-head approval are not ready.'
  require_merge_clearance
  writer_fence
  require_current_approval
  read_live_binding
  human_hold_fence
  gh pr merge --squash --match-head-commit "$CURRENT_HEAD_SHA" "$PR_URL" # NO_BARE_GH_WRITE_EXEMPT: trusted Actions immediate author squash after repeated exact-head approval, CI/native/API, accounting, provenance and hold checks in merge-queue-policy; never an interactive agent write
}

dependabot_main() {
  PHASE=${1:-}
  case "$PHASE" in approve|merge) ;; *) refuse 'Usage: dependabot-approved-merge.sh approve|merge' ;; esac
  [[ "${PR_NUMBER:-}" =~ ^[1-9][0-9]*$ ]] || refuse 'Invalid PR number.'
  [[ "${PR_HEAD_SHA:-}" =~ ^[0-9a-f]{40}$ ]] || refuse 'A full bound head is required.'
  [[ "${GITHUB_REPOSITORY:-}" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || refuse 'Invalid repository.'
  [ "${DEFAULT_BRANCH:-}" = main ] || refuse 'Only the protected literal-main environment path is supported.'
  [ -n "${WORKFLOW_GH_TOKEN:-}" ] || refuse 'Workflow token is required for read-only accounting and protective cleanup.'
  BOUND_HEAD=$PR_HEAD_SHA
  PR_URL="https://github.com/$GITHUB_REPOSITORY/pull/$PR_NUMBER"
  . scripts/lib/gh-api-array.sh
  . scripts/lib/dependabot-commit-provenance.sh
  . scripts/lib/reviewers-helpers.sh
  local initial
  initial=$(gh api "repos/$GITHUB_REPOSITORY/pulls/$PR_NUMBER") || refuse 'Cannot read initial live PR.'
  if [ "$PHASE" = approve ]; then
    BOUND_BASE=$(jq -er '.base.sha | select(type == "string" and test("^[0-9a-f]{40}$"))' <<<"$initial") || refuse 'Live governing base is unreadable.'
  else
    BOUND_BASE=${PR_BASE_SHA:-}
    [[ "$BOUND_BASE" =~ ^[0-9a-f]{40}$ ]] || refuse 'A full cross-job governing base binding is required.'
  fi
  read_live_binding
  load_governing_identities
  verify_phase_identity
  # Update classification is re-read by the pinned metadata action in EACH
  # trusted job; no classification or cleared boolean crosses the job boundary.
  if [ "${UPDATE_TYPE:-}" != 'version-update:semver-patch' ] && [ "${UPDATE_TYPE:-}" != 'version-update:semver-minor' ] && [ "${DEPENDENCY_GROUP:-}" != dev-dependencies ]; then
    refuse 'This update is outside the existing automatic approval lane.'
  fi
  if has_human_hold; then echo '::notice::human-hold keeps the Dependabot lane frozen.'; return 0; fi
  if [ "$PHASE" = approve ]; then approve_dependabot; else merge_dependabot; fi
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then dependabot_main "$@"; fi
