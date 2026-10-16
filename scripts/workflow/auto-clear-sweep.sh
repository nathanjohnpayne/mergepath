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
source scripts/lib/gh-retry-helpers.sh
had_infra_error=0
failing_prs=""
# #2193: heal candidates — see the evaluate-and-clear job above.
heal_prs=""
while IFS= read -r PR; do
  [ -z "$PR" ] && continue
  echo "::group::Sweep PR #$PR"

  # #827: re-verify the label against the AUTHORITATIVE labels
  # endpoint before doing any work. The PR list above comes from
  # `gh pr list --label`, which resolves through the GraphQL
  # `search()` API — GitHub's eventually-consistent search index,
  # NOT live label state. A PR whose label was cleared keeps
  # appearing in that index long after the fact (observed on #797:
  # ~3.5h, across 9 consecutive sweeps). Without this precheck the
  # sweep ran a full codex-review-check.sh evaluation, issued a
  # no-op removal, read "absent", and posted an attribution comment
  # for a label it never removed — 8 spurious comments on #797.
  # Mirrors the evaluate-and-clear job's HAS_LABEL check.
  if ! HAS_LABEL=$(with_gh_retry gh pr view "$PR" --repo "$REPO" --json labels \
    --jq '[.labels[].name] | contains(["needs-external-review"])'); then
    echo "::error::Failed to query labels for PR #$PR — cannot evaluate."
    had_infra_error=1
    failing_prs="$failing_prs $PR"
    echo "::endgroup::"
    continue
  fi
  if [ "$HAS_LABEL" != "true" ]; then
    echo "Label needs-external-review not present (stale search-index hit); nothing to clear."
    # #2193: the index lags a removal for hours (#827), which is
    # exactly the window in which a stale failed check-run from the
    # pre-removal outage needs superseding (for example after a
    # human removal, whose `unlabeled` event the event-driven job
    # skips). The heal step reads two endpoints and posts only when
    # the newest run on the head is a failure.
    heal_prs="$heal_prs $PR"
    echo "::endgroup::"
    continue
  fi

  # Dependabot action-pin bump lane (mergepath#2164) — the sweep is
  # the backstop for this lane: the labeler applies the label with
  # GITHUB_TOKEN, which fires no `labeled` run here, so a pin-only
  # Dependabot PR labeled by an older or fail-closed labeler is
  # cleared by this sweep within one interval. Same proof, same
  # verdict mapping as the event-driven job above.
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
      # Match the event-driven clear path: remove any unsafe durable
      # request while the label still blocks GitHub from consuming
      # it. The helper preserves Dependabot's dedicated lane.
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
      # Single (non-retried) REST DELETE + retried verify (#465/#827)
      # — see the evaluate-and-clear job above for the full rationale
      # on why the DELETE's HTTP status, not the end-state read, is
      # what attributes the removal to this run.
      del_out=$(gh api "repos/$REPO/issues/$PR/labels/needs-external-review" -X DELETE -i --silent 2>/dev/null || true) # NO_BARE_GH_WRITE_EXEMPT: trusted Actions review-automation App; protected tuple, current gate, label owner and arm revalidated above
      del_status=$(printf '%s\n' "$del_out" | awk 'NR==1{print $2; exit}')
      still_present=$(with_gh_retry gh pr view "$PR" --repo "$REPO" --json labels --jq 'any(.labels[]?; .name == "needs-external-review")' || echo "unknown")
      if [ "$still_present" = "false" ]; then
        # #2193: confirmed absent after a clean pass — heal candidate.
        heal_prs="$heal_prs $PR"
        # Comment ONLY if THIS sweep performed the removal (#827).
        case "$del_status" in
          200|204)
            if [ "$gate_source" = dependabot-pin-bump ]; then
              comment_body=$(printf '%s\n%s\n\n%s\n\n%s\n%s\n%s\n\n%s' \
                "<!-- mergepath-dependabot-pin-bump:v1 verified-head=$(jq -r '.head' <<<"$PIN_JSON") verified-base=$(jq -r '.base' <<<"$PIN_JSON") -->" \
                "**Automated label removal (scheduled sweep) — Dependabot action-pin bump lane** ✅ (head \`$(jq -r '.head' <<<"$PIN_JSON")\`, base \`$(jq -r '.base' <<<"$PIN_JSON")\`)" \
                "This Dependabot PR touches \`.github/workflows/\` only through action pins, so it is exempt from the \`.github/**\` protected-path external-review rule (REVIEW_POLICY.md § Dependabot action-pin bump lane). Removed \`needs-external-review\` so Label Gate passes. Proven on the live head/base pair by the trusted \`scripts/workflow/dependabot_pin_bump_exemption.sh\`:" \
                "- Commit provenance: $(jq -r '.provenance' <<<"$PIN_JSON")" \
                "- Diff shape: $(jq -r '.pins' <<<"$PIN_JSON") action pin line(s) across $(jq -r '.files | length' <<<"$PIN_JSON") workflow file(s); every changed line is a \`uses:\` ref or its pin comment, and nothing else changed" \
                "$(jq -r '.files[] | "  - `\(.filename)`: \(.pins) pin line(s)"' <<<"$PIN_JSON")" \
                "The PR still needs CI green and the Dependabot reviewer-identity \`APPROVED\` on this head (Merge clearance gate). See [.github/workflows/auto-clear-blocking-labels.yml](.github/workflows/auto-clear-blocking-labels.yml) for the sweep doctrine.")
            else
              comment_body='**Automated label removal (scheduled sweep).** `scripts/codex-review-check.sh` cleared the merge gate on this HEAD between event triggers (for example, an anchored Codex verdict or review arriving between event-driven evaluations). Removed `needs-external-review`. See [.github/workflows/auto-clear-blocking-labels.yml](.github/workflows/auto-clear-blocking-labels.yml) (#191/#197) for the sweep doctrine.'
            fi
            # #530: non-idempotent comment POST — deliberately
            # unretried (a single attempt cannot duplicate); see the
            # event-driven job above for the full rationale. Failure
            # is warn-only.
            gh pr comment "$PR" --repo "$REPO" --body "$comment_body" || echo "::warning::Failed to post attribution comment for PR #$PR" # NO_BARE_GH_WRITE_EXEMPT: trusted Actions review-automation App; diagnostic after confirmed removal, no reviewer standing
            ;;
          404)
            echo "needs-external-review was already absent (DELETE HTTP 404) — another run or sweep cleared it; skipping the attribution comment (#827)."
            ;;
          *)
            echo "::warning::Unexpected DELETE HTTP '${del_status:-none}' for needs-external-review on PR #$PR; label is confirmed absent, so skipping the attribution comment rather than risking a duplicate (#827)."
            ;;
        esac
      else
        # Removal did not take (label still present or verify read
        # failed) — infra error, not warning-only. The sweep must
        # not report success when the label is still stuck
        # (CodeRabbit Major, #271; verify-end-state per #465).
        echo "::error::Failed to remove needs-external-review on PR #$PR — label still stuck (state: $still_present, DELETE HTTP ${del_status:-none})."
        had_infra_error=1
        failing_prs="$failing_prs $PR"
      fi
      ;;
    1) echo "Gate not yet met — leaving label in place." ;;
    3) echo "::error::codex-review-check.sh rc=3 on PR #$PR"; had_infra_error=1; failing_prs="$failing_prs $PR" ;;
    *) echo "::error::unexpected rc=$rc on PR #$PR"; had_infra_error=1; failing_prs="$failing_prs $PR" ;;
  esac
  echo "::endgroup::"
done <<<"$PRS"
# Surface the infra-error sentinel + per-PR list to the next
# step (#324 round 2 codex P2). See evaluate-and-clear job
# for the rationale (correct head SHA per failing PR).
echo "HAD_INFRA_ERROR=$had_infra_error" >> "$GITHUB_ENV"
# shellcheck disable=SC2086  # intentional word-splitting to trim
echo "HAD_INFRA_ERROR_PRS=$(echo $failing_prs)" >> "$GITHUB_ENV"
# #2193: deduplicated heal candidates minus this pass's infra failures.
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
