#!/usr/bin/env bash
# Existing trusted label evaluation, separated from its queue credential phase.
# Only inert PR/head/base tuples cross jobs; every mutation re-evaluates live state.
set -euo pipefail
case "${CLEAR_PHASE:-}" in protect|mutate) ;; *) echo "Invalid auto-clear phase" >&2; exit 3 ;; esac
AUTHOR_TOKEN=${AUTHOR_TOKEN:-}
QUEUE_POLICY_TOKEN=${QUEUE_POLICY_TOKEN:-}
QUEUE_SOURCE_TOKEN=${QUEUE_SOURCE_TOKEN:-}
protected_pairs='[]'
if [ "$CLEAR_PHASE" = mutate ]; then
  jq -e 'type == "array" and all(.[]; (.pr | test("^[1-9][0-9]*$")) and (.head | test("^[0-9a-f]{40}$")) and (.base | test("^[0-9a-f]{40}$")))' <<<"${PROTECTED_PAIRS:-}" >/dev/null || exit 3
fi
set -euo pipefail
# Source the gh-retry helper (#324). with_gh_retry wraps gh
# calls in 3×30s retry on transient failures (HTTP 5xx,
# rate-limit, "Resource not accessible by integration") so a
# flaky read or write doesn't silently leave the label stuck.
source scripts/lib/gh-retry-helpers.sh
# codex-review-check.sh exits:
#   0 = gate passes
#   1 = gate fails (one or more of CI/reviewer/codex not met)
#   3 = config/arg error (real infrastructure failure)
# CR Major on PR #202 r1: every gh call gets explicit error
# handling so a transient failure (rate limit, 5xx) on one
# PR doesn't abort the sweep, AND no early gh failure is
# silently swallowed by an asymmetric set -e/+e dance.
# CR Major on PR #202 r2: rc=3 (infrastructure error) sets a
# sentinel; after the sweep finishes we exit non-zero if any
# PR hit it, so the workflow doesn't go green when gate
# evaluation was actually impossible.
had_infra_error=0
failing_prs=""
cleared_prs=""
# #2193: PRs this pass evaluated without an infrastructure error and
# left with needs-external-review absent. The "Heal stale auto-clear
# infra-failure check-runs" step supersedes a stale failed
# auto-clear-blocking-labels check-run on each one's head.
heal_prs=""
while IFS= read -r PR; do
  [ -z "$PR" ] && continue
  echo "::group::Evaluating PR #$PR"

  # Skip if label not present (no-op, common case on
  # synchronize/workflow_run for under-threshold PRs).
  if ! HAS_LABEL=$(with_gh_retry gh pr view "$PR" --repo "$REPO" --json labels \
    --jq '[.labels[].name] | contains(["needs-external-review"])'); then
    # Infra error — NOT a warning-only skip. This workflow
    # exists to clear a merge-blocking label; if it can't even
    # read the label state, it must NOT report success. A
    # rate-limit / network / API error here previously let
    # the job go green while a PR stayed stuck. (CodeRabbit
    # Major, #271.)
    echo "::error::Failed to query labels for PR #$PR — cannot evaluate."
    had_infra_error=1
    failing_prs="$failing_prs $PR"
    echo "::endgroup::"
    continue
  fi
  if [ "$HAS_LABEL" != "true" ]; then
    echo "Label needs-external-review not present; nothing to clear."
    # #2193: a PR whose label is already gone can still carry a
    # stale failed auto-clear-blocking-labels check-run, and the
    # scheduled sweep visits only PRs the search index still lists
    # as labeled, so this event is often its only heal path (a
    # body-edit `edited` nudge being the deliberate one). Limited to
    # pull_request_target actions other than `synchronize`: a fresh
    # push carries a head no infra failure was posted on, and
    # workflow_run fires several times per push, so either would
    # spend installation-token reads for nothing. The heal step
    # itself posts only when the newest run on the head is a failure.
    # A repository_dispatch nomination of a label-absent PR is the
    # routine retry (#2205): the publisher sends one only after it
    # read a failed newest auto-clear-blocking-labels run on the
    # head, so this candidate is the case the heal exists for.
    if { [ "${EVENT_NAME:-}" = "pull_request_target" ] \
         && [ "${EVENT_ACTION:-}" != "synchronize" ]; } \
       || [ "${EVENT_NAME:-}" = "repository_dispatch" ]; then
      heal_prs="$heal_prs $PR"
    fi
    echo "::endgroup::"
    continue
  fi

  # --- Dependabot action-pin bump lane (mergepath#2164) --------
  # A Dependabot PR that only bumps action pins under
  # .github/workflows/ carries needs-external-review solely because
  # `.github/**` is a protected path, and codex-review-check.sh can
  # never clear it (Codex does not review Dependabot PRs). This is
  # the TRUSTED removal authority for that label: default-branch
  # code, a trusted trigger, and the proof re-derived here against
  # the LIVE head/base pair by scripts/workflow/
  # dependabot_pin_bump_exemption.sh — Dependabot-only, GitHub-
  # committed, signature-verified commits, and a diff confined to
  # `uses:` pin lines. The labeler's own non-application and its
  # diagnostic marker grant nothing here. rc 1 (not a pin-only
  # Dependabot PR, including every non-Dependabot PR) falls through
  # to the ordinary merge-gate evaluation; rc 3 (no verdict
  # reachable) is an infrastructure error like a gate rc 3, so the
  # job fails loudly and the next event or sweep retries. The
  # helper reads under the workflow token: three GET reads, no PAT
  # quota. See REVIEW_POLICY.md § Dependabot action-pin bump lane.
  # Latest needs-external-review label event as "<event>:<actor>"
  # ("none" when there is none); nonzero on a failed read.
  # Paginated: a long-lived PR's timeline exceeds one page. Used
  # before the proof and again immediately before the DELETE.
  lane_latest_label_event() {
    GH_TOKEN="$WORKFLOW_TOKEN" gh api --paginate "repos/$REPO/issues/$PR/timeline" \
      | jq -rs '[ (add // []) | .[]
                  | select((.event == "labeled" or .event == "unlabeled")
                           and (.label.name // "") == "needs-external-review") ]
                | sort_by(.created_at, .id) | last
                | if . == null then "none" else "\(.event):\(.actor.login // "<unknown>")" end'
  }
  gate_source=codex
  PIN_JSON=""
  pin_rc=1
  LANE_HEAD=""
  LANE_BASE=""
  LANE_BASE_REF=""
  LANE_AUTHOR=""
  if [ -x scripts/workflow/dependabot_pin_bump_exemption.sh ] \
     && [ -x scripts/workflow/resolve_base_policy.sh ]; then
    # ONE captured live head/base/ref/author read feeds everything
    # below: the policy resolution, the ownership check, the
    # helper's pinned pair and the pre-delete fence. Resolving the
    # policy from an unpinned base and then proving a different
    # live pair would let a retarget between the two reads judge a
    # release-branch PR by the old base's policy.
    set +e
    LANE_TRIPLE=$(GH_TOKEN="$WORKFLOW_TOKEN" gh api "repos/$REPO/pulls/$PR" \
      --jq '[.head.sha, .base.sha, .base.ref, .user.login] | @tsv')
    triple_rc=$?
    set -e
    LANE_HEAD=$(cut -f1 <<<"$LANE_TRIPLE")
    LANE_BASE=$(cut -f2 <<<"$LANE_TRIPLE")
    LANE_BASE_REF=$(cut -f3 <<<"$LANE_TRIPLE")
    LANE_AUTHOR=$(cut -f4 <<<"$LANE_TRIPLE")
    if [ "$triple_rc" -ne 0 ] || ! [[ "$LANE_HEAD" =~ ^[0-9a-f]{40}$ ]] \
       || ! [[ "$LANE_BASE" =~ ^[0-9a-f]{40}$ ]] || [ -z "$LANE_BASE_REF" ] \
       || [ -z "$LANE_AUTHOR" ]; then
      pin_rc=3
      PIN_JSON='{"reason":"the live PR head, base, base ref and author could not be read"}'
    elif [ "$LANE_AUTHOR" != 'dependabot[bot]' ]; then
      # Not a Dependabot PR: the lane cannot apply (the helper would
      # return the same not-exempt verdict), so skip the policy
      # materialization, the timeline read and the proof instead of
      # spending installation-token reads on every labeled PR in
      # every sweep. Falls through to the ordinary merge gate.
      pin_rc=1
      PIN_JSON=$(jq -nc --arg a "$LANE_AUTHOR" \
        '{reason:("PR author is " + $a + ", not dependabot[bot]; the lane does not apply")}')
    else
      # The policy that governs a PR is its BASE branch's (#769): a
      # release branch that opts the lane out must be honored here
      # exactly as the classifier honors it. MATERIALIZED at the
      # captured base SHA even for a default-branch base: without
      # --materialize-default the resolver returns this checkout's
      # own copy for a default base and ignores --base-sha, so a
      # default branch that advanced after this checkout (opting the
      # lane out, adding a narrower protected path, lowering the
      # threshold) would be judged by the older policy. The result
      # is always a temp file; an unknown base policy is exit 2 and
      # fails closed below.
      LANE_POLICY=""
      set +e
      LANE_POLICY=$(GH_TOKEN="$WORKFLOW_TOKEN" bash scripts/workflow/resolve_base_policy.sh \
        --repo "$REPO" --base-ref "$LANE_BASE_REF" --base-sha "$LANE_BASE" \
        --default-branch "$DEFAULT_BRANCH" --default-config .github/review-policy.yml \
        --materialize-default)
      policy_rc=$?
      set -e
      if [ "$policy_rc" -ne 0 ] || [ -z "$LANE_POLICY" ] || [ ! -f "$LANE_POLICY" ]; then
        pin_rc=3
        PIN_JSON='{"reason":"the governing base policy could not be resolved"}'
      else
        # Only a POLICY-APPLIED label is the lane's to clear: the
        # latest needs-external-review label event must be a
        # github-actions[bot] application. A human force-on, or a
        # human re-application after an automated removal, is
        # Phase 4 by decision and stays until the merge gate clears
        # it or the human removes it. Re-checked at the DELETE.
        set +e
        LANE_OWNER=$(lane_latest_label_event)
        owner_rc=$?
        set -e
        if [ "$owner_rc" -ne 0 ] || [ -z "$LANE_OWNER" ]; then
          pin_rc=3
          PIN_JSON='{"reason":"the needs-external-review label timeline could not be read"}'
        elif [ "$LANE_OWNER" != 'labeled:github-actions[bot]' ]; then
          pin_rc=1
          PIN_JSON=$(jq -nc --arg o "$LANE_OWNER" \
            '{reason:("the latest needs-external-review label event is " + $o + ", not a policy-workflow application; the lane clears only a policy-applied label")}')
        else
          set +e
          PIN_JSON=$(GH_TOKEN="$WORKFLOW_TOKEN" bash scripts/workflow/dependabot_pin_bump_exemption.sh \
            --repo "$REPO" --pr "$PR" --head "$LANE_HEAD" --base "$LANE_BASE" --config "$LANE_POLICY")
          pin_rc=$?
          set -e
        fi
      fi
      # The resolver hands back a temp file only for a non-default
      # base; the default path is the checkout's own file.
      if [ -n "$LANE_POLICY" ] && [ "$LANE_POLICY" != .github/review-policy.yml ]; then
        rm -f "$LANE_POLICY"
      fi
    fi
  else
    echo "Dependabot pin-bump lane: trusted helper or base-policy resolver absent on the default branch (pre-mergepath#2164 checkout); evaluating the merge gate only."
  fi
  PIN_REASON=$(jq -r '.reason // "no reason reported"' <<<"$PIN_JSON" 2>/dev/null || echo "no reason reported")
  case "$pin_rc" in
    0)
      rc=0
      gate_source=dependabot-pin-bump
      echo "Dependabot pin-bump lane: VERIFIED on the live head/base pair — $PIN_REASON"
      ;;
    1)
      echo "Dependabot pin-bump lane: not applicable — $PIN_REASON"
      # #2239: capture the live head/base the merge gate is about to
      # judge, so the DELETE below can be fenced against it. The
      # lane's own read above is reused when it ran; otherwise one
      # read under the workflow token, here.
      if ! [[ "$LANE_HEAD" =~ ^[0-9a-f]{40}$ ]] || ! [[ "$LANE_BASE" =~ ^[0-9a-f]{40}$ ]]; then
        set +e
        LANE_PAIR=$(GH_TOKEN="$WORKFLOW_TOKEN" gh api "repos/$REPO/pulls/$PR" \
          --jq '[.head.sha, .base.sha] | @tsv')
        set -e
        LANE_HEAD=$(cut -f1 <<<"$LANE_PAIR")
        LANE_BASE=$(cut -f2 <<<"$LANE_PAIR")
      fi
      if ! [[ "$LANE_HEAD" =~ ^[0-9a-f]{40}$ ]] || ! [[ "$LANE_BASE" =~ ^[0-9a-f]{40}$ ]]; then
        echo "::error::Could not read the live head/base of PR #$PR before evaluating the merge gate."
        rc=3
      else
        set +e
        GH_TOKEN="$WORKFLOW_TOKEN" scripts/codex-review-check.sh "$PR"
        rc=$?
        set -e
      fi
      ;;
    *)
      echo "::error::Dependabot pin-bump lane could not reach a verdict on PR #$PR (rc=$pin_rc): $PIN_REASON"
      rc=3
      ;;
  esac

  case "$rc" in
    0)
      # Retract any durable request while needs-external-review is
      # still a blocker. Deleting the last blocking label first can
      # let GitHub consume an older arm before the continuation step
      # gets a chance to clean it up. Dependabot is preserved inside
      # the helper because its dedicated workflow owns that lane.
      if [ ! -f scripts/workflow/approval-merge-continuation.sh ] \
         || ! grep -Fq 'APPROVAL_PROTECTIVE_RETRACTION_V2' scripts/workflow/approval-merge-continuation.sh; then
        echo "::error::Protective retraction helper is unavailable; refusing to remove needs-external-review from PR #$PR."
        had_infra_error=1
        failing_prs="$failing_prs $PR"
        echo "::endgroup::"
        continue
      fi
    if [ "$CLEAR_PHASE" = protect ]; then
        set +e
        GH_TOKEN="$WORKFLOW_TOKEN" MERGEPATH_AUTHOR_TOKEN="$AUTHOR_TOKEN" \
          MERGEPATH_QUEUE_POLICY_TOKEN="$QUEUE_POLICY_TOKEN" \
          MERGEPATH_QUEUE_SOURCE_TOKEN="$QUEUE_SOURCE_TOKEN" \
          bash scripts/workflow/approval-merge-continuation.sh \
          --retract-unsafe-only "$PR" "$REPO"
        protective_rc=$?
        set -e
    else
      # The prior trusted queue phase transports a tuple, never a clearance
      # flag or credential. Re-evaluate the gate above, then require its pair.
      if ! jq -e --arg pr "$PR" --arg head "$LANE_HEAD" --arg base "$LANE_BASE" \
          'any(.[]; .pr == $pr and .head == $head and .base == $base)' <<<"$PROTECTED_PAIRS" >/dev/null; then
        echo "No matching protected head/base for PR #$PR; preserving the label."
        echo "::endgroup::"
        continue
      fi
      # A new ordinary auto-merge arm after the queue phase must never lose
      # its last blocking label. Only the existing native Dependabot lane
      # preserves its own durable request, as in the original retraction helper.
      if ! arm=$(GH_TOKEN="$WORKFLOW_TOKEN" gh pr view "$PR" --repo "$REPO" --json author,autoMergeRequest); then
        protective_rc=3
      elif ! jq -e 'has("autoMergeRequest") and (.autoMergeRequest == null or (.autoMergeRequest | type == "object")) and (.author.login | type == "string" and length > 0)' <<<"$arm" >/dev/null; then
        protective_rc=3
      elif jq -e '.autoMergeRequest == null or .author.login == "dependabot[bot]" or .author.login == "app/dependabot"' <<<"$arm" >/dev/null; then
        protective_rc=0
      else
        protective_rc=4
      fi
    fi
      if [ "$protective_rc" -eq 4 ]; then
        # Exit 4 is the helper's benign not-ready verdict (#1159): the
        # standing auto-merge request is either outside the #1058 queue
        # boundary or a queue-governed arm retained within it. Nothing
        # was mutated and no dependency is broken, so this must not set
        # the infrastructure sentinel or emit a per-PR failure diagnostic.
        # The label still stays:
        # removing the last blocker while an arm stands would let
        # GitHub consume it, which is the hazard this retraction
        # exists to prevent. Every other nonzero keeps failing below.
        echo "::notice::PR #$PR has a standing auto-merge request outside the #1058 queue boundary or a queue-governed arm retained within it; leaving needs-external-review in place until it is dispositioned."
        echo "::endgroup::"
        continue
      fi
      if [ "$protective_rc" -ne 0 ]; then
        echo "::error::Protective retraction failed rc=$protective_rc; refusing to remove needs-external-review from PR #$PR."
        had_infra_error=1
        failing_prs="$failing_prs $PR"
        echo "::endgroup::"
        continue
      fi
      # Pin-bump lane: the helper fenced the live pair at the end of
      # its proof, but the protective retraction above made several
      # API calls since. A non-pin push onto the Dependabot branch in
      # that window would otherwise have the label removed for a
      # head the proof never covered, and the resulting `unlabeled`
      # event does not re-add it (#969). Re-read the pair under the
      # workflow token immediately before the DELETE and require it
      # to equal the PROVEN pair; a move leaves the label for the
      # next evaluation, an unreadable pair is an infrastructure
      # error. Bounds the write without claiming atomicity.
      if [ "$gate_source" = dependabot-pin-bump ]; then
        if ! live_pair=$(GH_TOKEN="$WORKFLOW_TOKEN" gh api "repos/$REPO/pulls/$PR" \
             --jq '[.head.sha, .base.sha] | @tsv'); then
          echo "::error::Could not re-read the live head/base of PR #$PR before removing needs-external-review for the pin-bump lane."
          had_infra_error=1
          failing_prs="$failing_prs $PR"
          echo "::endgroup::"
          continue
        fi
        proven_pair=$(jq -r '[.head, .base] | @tsv' <<<"$PIN_JSON")
        captured_pair=$(printf '%s\t%s' "$LANE_HEAD" "$LANE_BASE")
        if [ -z "$live_pair" ] || [ "$live_pair" != "$proven_pair" ] \
           || [ "$live_pair" != "$captured_pair" ]; then
          echo "PR #$PR head/base moved after the pin-bump proof (proven: $proven_pair; live: ${live_pair:-unreadable}); leaving needs-external-review for the next evaluation."
          echo "::endgroup::"
          continue
        fi
        # Ownership too: a human who removed and re-applied the
        # label while the proof and retraction ran leaves the pair
        # unchanged, and that re-application is a force-on this
        # lane must not clear.
        set +e
        live_owner=$(lane_latest_label_event)
        live_owner_rc=$?
        set -e
        if [ "$live_owner_rc" -ne 0 ] || [ -z "$live_owner" ]; then
          echo "::error::Could not re-read the needs-external-review label timeline of PR #$PR before removal for the pin-bump lane."
          had_infra_error=1
          failing_prs="$failing_prs $PR"
          echo "::endgroup::"
          continue
        fi
        if [ "$live_owner" != 'labeled:github-actions[bot]' ]; then
          echo "PR #$PR needs-external-review was re-applied by $live_owner after the pin-bump proof; leaving it for the next evaluation."
          echo "::endgroup::"
          continue
        fi
      else
        # #2239: the same fence for the merge-gate path.
        # codex-review-check.sh judged whatever head was live while
        # it ran, and a push during it or during the protective
        # retraction would otherwise have the label removed from a
        # head nobody evaluated (the publisher's repository_dispatch
        # nomination makes this path run while a PR is still being
        # pushed to). The pair captured before the gate must still
        # be live; a move leaves the label for the new head's own
        # events, an unreadable pair is an infrastructure error.
        if ! live_pair=$(GH_TOKEN="$WORKFLOW_TOKEN" gh api "repos/$REPO/pulls/$PR" \
             --jq '[.head.sha, .base.sha] | @tsv'); then
          echo "::error::Could not re-read the live head/base of PR #$PR before removing needs-external-review."
          had_infra_error=1
          failing_prs="$failing_prs $PR"
          echo "::endgroup::"
          continue
        fi
        captured_pair=$(printf '%s\t%s' "$LANE_HEAD" "$LANE_BASE")
        if [ -z "$live_pair" ] || [ "$live_pair" != "$captured_pair" ]; then
          echo "PR #$PR head/base moved while the merge gate was evaluated (evaluated: $captured_pair; live: ${live_pair:-unreadable}); leaving needs-external-review for the next evaluation."
          echo "::endgroup::"
          continue
        fi
      fi
          if [ "$CLEAR_PHASE" = protect ]; then
      protected_pairs=$(jq -c --arg pr "$PR" --arg head "$LANE_HEAD" --arg base "$LANE_BASE" \
        '. + [{pr:$pr,head:$head,base:$base}]' <<<"$protected_pairs")
      echo "Protected PR #$PR at $LANE_HEAD/$LANE_BASE; mutation re-evaluates it separately."
      echo "::endgroup::"
      continue
    fi
echo "Gate passes — removing needs-external-review label."
      # Single (non-retried) removal, then verify end state with a
      # retried READ (#465): retrying the removal can double-fire
      # downstream label-event workflows. Authoritative success = the
      # label is gone, not the write's exit code (fail-closed #271).
      #
      # #827: the removal is a REST DELETE, NOT
      # `gh pr edit --remove-label`, because only the DELETE's HTTP
      # status distinguishes "THIS run removed the label" from "the
      # label was already gone". `gh pr edit --remove-label` is backed
      # by the idempotent GraphQL removeLabelsFromLabelable mutation
      # and exits 0 even when the label was never present, so neither
      # its exit code nor the `still_present` read below can attribute
      # the removal. Gating the attribution comment on mere ABSENCE is
      # what produced duplicate comments: this workflow has no
      # concurrency group (a per-PR one is not expressible for
      # workflow_run, whose PR is resolved in a step), so several runs
      # clear the HAS_LABEL check above, one write wins, and every one
      # of them then reads "absent" and comments. On #797 that made 15
      # comments for 5 real removals. DELETE
      # /issues/{n}/labels/{name} returns 404 when the label is not on
      # the issue, so exactly one racing run sees 2xx.
      del_out=$(gh api "repos/$REPO/issues/$PR/labels/needs-external-review" -X DELETE -i --silent 2>/dev/null || true) # NO_BARE_GH_WRITE_EXEMPT: trusted Actions review-automation App; protected tuple, current gate, label owner and arm revalidated above
      del_status=$(printf '%s\n' "$del_out" | awk 'NR==1{print $2; exit}')
      still_present=$(with_gh_retry gh pr view "$PR" --repo "$REPO" --json labels --jq 'any(.labels[]?; .name == "needs-external-review")' || echo "unknown")
      if [ "$still_present" != "false" ]; then
        echo "::error::Failed to remove needs-external-review on PR #$PR — label still stuck (state: $still_present, DELETE HTTP ${del_status:-none})."
        had_infra_error=1
        failing_prs="$failing_prs $PR"
        echo "::endgroup::"
        continue
      fi
      # #2193: the label is confirmed absent after a clean pass, so
      # this head is a heal candidate whoever performed the removal.
      heal_prs="$heal_prs $PR"
      # End state is correct. Comment ONLY if THIS run performed the
      # removal (#827) — a 404 means another run or an earlier sweep
      # already cleared it, and the desired end state holds either way.
      case "$del_status" in
        200|204)
          cleared_prs="$cleared_prs $PR"
          # Direct string body (NOT a heredoc — heredoc closing
          # delimiter must be column-0 unless using `<<-` with
          # tabs; YAML run blocks make that brittle).
          if [ "$gate_source" = dependabot-pin-bump ]; then
            # The evidence the lane acted on: the verified pair, the
            # provenance verdict and the pinned files. Diagnostic
            # marker; no reader treats it as authority.
            comment_body=$(printf '%s\n%s\n\n%s\n\n%s\n%s\n%s\n\n%s' \
              "<!-- mergepath-dependabot-pin-bump:v1 verified-head=$(jq -r '.head' <<<"$PIN_JSON") verified-base=$(jq -r '.base' <<<"$PIN_JSON") -->" \
              "**Automated label removal — Dependabot action-pin bump lane** ✅ (head \`$(jq -r '.head' <<<"$PIN_JSON")\`, base \`$(jq -r '.base' <<<"$PIN_JSON")\`)" \
              "This Dependabot PR touches \`.github/workflows/\` only through action pins, so it is exempt from the \`.github/**\` protected-path external-review rule (REVIEW_POLICY.md § Dependabot action-pin bump lane). Removed \`needs-external-review\` so Label Gate passes. Proven on the live head/base pair by the trusted \`scripts/workflow/dependabot_pin_bump_exemption.sh\`:" \
              "- Commit provenance: $(jq -r '.provenance' <<<"$PIN_JSON")" \
              "- Diff shape: $(jq -r '.pins' <<<"$PIN_JSON") action pin line(s) across $(jq -r '.files | length' <<<"$PIN_JSON") workflow file(s); every changed line is a \`uses:\` ref or its pin comment, and nothing else changed" \
              "$(jq -r '.files[] | "  - `\(.filename)`: \(.pins) pin line(s)"' <<<"$PIN_JSON")" \
              "The PR still needs CI green and the Dependabot reviewer-identity \`APPROVED\` on this head (Merge clearance gate). See [.github/workflows/auto-clear-blocking-labels.yml](.github/workflows/auto-clear-blocking-labels.yml) for the trigger doctrine.")
          else
            comment_body='**Automated label removal.** `scripts/codex-review-check.sh` cleared the merge gate on this HEAD (CI green + reviewer-identity APPROVED + Codex cleared). Removed `needs-external-review` so Label Gate passes and the PR can merge. See [.github/workflows/auto-clear-blocking-labels.yml](.github/workflows/auto-clear-blocking-labels.yml) (#191/#195) for the trigger doctrine.'
          fi
          # #530 (IMPLEMENTED — was DEFER+DOCUMENT, human-ratified
          # 2026-06-28): this attribution-comment POST is
          # NON-idempotent, so it is deliberately NOT wrapped in
          # with_gh_retry. A retry after a timeout-after-accept would
          # post a DUPLICATE comment; a single unretried attempt
          # cannot. Failure stays warn-only (non-fatal) and is purely
          # cosmetic — the label is already cleared and the workflow
          # log records the action. The other retried writes here are
          # check-runs keyed on (name, head_sha), which GitHub UPSERTS
          # (idempotent), so those stay wrapped.
          gh pr comment "$PR" --repo "$REPO" --body "$comment_body" || echo "::warning::Failed to post attribution comment for PR #$PR" # NO_BARE_GH_WRITE_EXEMPT: trusted Actions review-automation App; diagnostic after confirmed removal, no reviewer standing
          ;;
        404)
          echo "needs-external-review was already absent (DELETE HTTP 404) — another run or sweep cleared it; skipping the attribution comment (#827)."
          ;;
        *)
          echo "::warning::Unexpected DELETE HTTP '${del_status:-none}' for needs-external-review on PR #$PR; label is confirmed absent, so skipping the attribution comment rather than risking a duplicate (#827)."
          ;;
      esac
      ;;
    1)
      echo "Gate not yet met — leaving label in place."
      ;;
    3)
      echo "::error::codex-review-check.sh config/arg error (rc=3) on PR #$PR"
      # Don't exit non-zero mid-loop — keep sweeping other
      # PRs on a multi-PR workflow_run trigger. But set
      # the sentinel so the job exits non-zero at the end.
      had_infra_error=1
      failing_prs="$failing_prs $PR"
      ;;
    *)
      echo "::error::codex-review-check.sh unexpected rc=$rc on PR #$PR (contract drift — failing job)"
      # Fail-closed: any rc outside 0/1/3 is contract drift.
      # Better to fail loudly than leave the label stuck
      # behind a silently-broken gate. CR Major on PR #202 r3.
      had_infra_error=1
      failing_prs="$failing_prs $PR"
      ;;
  esac
  echo "::endgroup::"
done <<<"$PR_NUMBERS"
# Surface the infra-error sentinel + per-PR list to the next
# step (#324 round 2 codex P2) so the check-run can be posted
# with the correct head SHA per PR. failing_prs is space-
# separated, may have a leading space — `echo` collapses it.
echo "HAD_INFRA_ERROR=$had_infra_error" >> "$GITHUB_ENV"
# shellcheck disable=SC2086  # intentional word-splitting to trim
echo "HAD_INFRA_ERROR_PRS=$(echo $failing_prs)" >> "$GITHUB_ENV"
# A PR whose external-review label was removed in THIS pass must
# wait for the label-policy workflow to publish its new verdict.
# The continuation step skips it until that later workflow_run.
# shellcheck disable=SC2086  # intentional word-splitting to trim
echo "cleared_prs=$(echo $cleared_prs)" >> "$GITHUB_OUTPUT"
# #2193: deduplicated heal candidates, minus any PR that also hit an
# infrastructure error in this pass (a repeated PR number), which
# the surfacing step owns.
heal_out=""
for heal_pr in $heal_prs; do
  case " $failing_prs $heal_out " in
    *" $heal_pr "*) ;;
    *) heal_out="$heal_out $heal_pr" ;;
  esac
done
# shellcheck disable=SC2086  # intentional word-splitting to trim
echo "heal_prs=$(echo $heal_out)" >> "$GITHUB_OUTPUT"
echo "protected_pairs=$protected_pairs" >> "$GITHUB_OUTPUT"
exit "$had_infra_error"
