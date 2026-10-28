#!/usr/bin/env bash
# scripts/workflow/external_review_label_reconcile.sh — caller C6 of ADR 0004
# (#2727 slice 3c): retract a `needs-external-review` label that the policy
# workflow applied itself after an earlier read failed closed (#1321), once a
# trusted classification says no review is needed (`under-threshold` or
# `carried-forward`).
#
# The body below is pr-review-policy.yml's step "Reconcile a policy-owned
# fail-closed label", copied verbatim so the trusted consumer
# (trusted-policy-mutations.yml, job `mutate`) makes the same decision with
# the same ownership proof. Until cutover (#2730) the producer keeps its
# inline copy, and tests/test_policy_mutations.sh fails if the two differ.
# The one permitted difference: the label DELETE is joined onto one line to
# carry its NO_BARE_GH_WRITE_EXEMPT reason; the test normalizes exactly that.
# Cutover deletes the inline step and leaves this file as the only copy.
#
# Contract:
#   env   GH_TOKEN             reads (the PR, its timeline and comments)
#         LABEL_REMOVAL_TOKEN  the one write, DELETE the label: the producer's
#                              PAT, or the consumer's policy-mutations app token
#         PR_NUMBER, EXPECTED_HEAD_SHA, EXPECTED_BASE_SHA, REPO
#   exit  0 whether or not the label was removed; every unproven or unread
#         fact preserves the label. Non-zero only on an unexpected error.
set -euo pipefail
# #1321: a successful no-review classification may retract only a
# label this workflow previously applied because an earlier read
# failed closed. This includes an ordinary under-threshold result and
# a same-fingerprint carry-forward. An old comment is not ownership:
# a human could have removed and re-applied the label since then. Bind
# the decision to the latest label event and adjacent automation comment.
fetch_array() { # <endpoint> <output-file>
  local endpoint=$1 output=$2 raw err rc=0
  raw=$(mktemp)
  err=$(mktemp)
  gh api --paginate "$endpoint" >"$raw" 2>"$err" || rc=$?
  if [ "$rc" -ne 0 ] || ! jq -s 'add // []' "$raw" >"$output"; then
    echo "::warning::Could not read complete $endpoint data; preserving needs-external-review." >&2
    cat "$err" >&2 || true
    rm -f "$raw" "$err"
    return 1
  fi
  rm -f "$raw" "$err"
}

read_live_pr() { # <output-file>
  local output=$1 raw err rc=0
  raw=$(mktemp)
  err=$(mktemp)
  gh api "repos/$REPO/pulls/$PR_NUMBER" >"$raw" 2>"$err" || rc=$?
  if [ "$rc" -ne 0 ] \
     || ! jq -e '
          select((.head.sha | type) == "string" and (.head.sha | test("^[0-9a-fA-F]{40}$")))
          | select((.base.sha | type) == "string" and (.base.sha | test("^[0-9a-fA-F]{40}$")))
          | select((.labels | type) == "array")
          | {head_sha:.head.sha, base_sha:.base.sha,
             labels:[.labels[] | select((.name | type) == "string") | .name]}
        ' "$raw" >"$output"; then
    echo "::warning::Could not read current PR head, base, and labels; preserving needs-external-review." >&2
    cat "$err" >&2 || true
    rm -f "$raw" "$err"
    return 1
  fi
  rm -f "$raw" "$err"
}

LIVE=$(mktemp)
TIMELINE=$(mktemp)
COMMENTS=$(mktemp)
cleanup_reconcile() { rm -f "$LIVE" "$TIMELINE" "$COMMENTS"; }
trap cleanup_reconcile EXIT

if ! read_live_pr "$LIVE"; then
  exit 0
fi
LIVE_HEAD=$(jq -r '.head_sha' "$LIVE")
LIVE_BASE=$(jq -r '.base_sha' "$LIVE")
if [ "$LIVE_HEAD" != "$EXPECTED_HEAD_SHA" ] || [ "$LIVE_BASE" != "$EXPECTED_BASE_SHA" ]; then
  echo "::warning::PR head/base moved from $EXPECTED_HEAD_SHA/$EXPECTED_BASE_SHA to $LIVE_HEAD/$LIVE_BASE during classification; preserving needs-external-review." >&2
  exit 0
fi
if ! jq -e '.labels | index("needs-external-review") != null' "$LIVE" >/dev/null; then
  echo "needs-external-review is already absent; nothing to reconcile."
  exit 0
fi

if ! fetch_array "repos/$REPO/issues/$PR_NUMBER/timeline" "$TIMELINE" \
   || ! fetch_array "repos/$REPO/issues/$PR_NUMBER/comments" "$COMMENTS"; then
  exit 0
fi
LATEST=$(jq -c '
  [ .[]
    | select((.event == "labeled" or .event == "unlabeled")
             and .label.name == "needs-external-review") ]
  | sort_by(.created_at, .id) | last // null
' "$TIMELINE")
if ! jq -e '.event == "labeled" and .actor.login == "github-actions[bot]"' \
     <<<"$LATEST" >/dev/null; then
  echo "Latest needs-external-review timeline event is not a github-actions label application; preserving it."
  exit 0
fi
LABEL_EVENT_ID=$(jq -r '.id' <<<"$LATEST")
LABEL_EVENT_TIME=$(jq -r '.created_at' <<<"$LATEST")

# New applications carry an exact-head marker as the first line of
# the application envelope. Legacy applications are admitted only
# when the complete body matches one of the historical fail-closed
# templates. A title or reason substring can be supplied by an
# ordinary protected-path filename, so neither proves ownership.
OWNER_COMMENT=$(jq -c --arg applied "$LABEL_EVENT_TIME" --arg head "$EXPECTED_HEAD_SHA" '
  def application_prefix:
    "**External Review Required**\n\n"
    + "This PR has been labeled `needs-external-review` based on .github/review-policy.yml:\n\n";
  def application_suffix:
    "\n\nPer REVIEW_POLICY.md, the authoring agent must post a handoff message and alert the human. "
    + "The human will coordinate external review by a different agent.\n\n"
    + "> Automated check per .github/review-policy.yml";
  def application_body($reason):
    application_prefix + $reason + application_suffix;
  def legacy_body:
    . == application_body("- Could not fetch PR files for external-review fingerprint; requiring review fail-closed")
    or . == application_body("- Could not materialize the PR base tree for the external-review calculation; requiring review fail-closed")
    or . == application_body("- No trusted review-policy.yml on the PR base or the default branch; requiring review fail-closed")
    or . == application_body("- Trusted external-review fingerprint helper is unavailable on the PR base and the default branch; requiring review fail-closed")
    or . == application_body("- External-review fingerprint helper failed; requiring review fail-closed");
  def marked_body($expected_head):
    ("<!-- mergepath-external-review-label:v1 head=" + $expected_head
     + " cause=fail-closed -->\n" + application_prefix) as $prefix
    | . as $body
    | ($body | startswith($prefix))
      and ($body | endswith(application_suffix))
      and (($body | ltrimstr($prefix) | rtrimstr(application_suffix))
           | test("^- [^\\n]+; requiring review fail-closed$"));
  ($applied | fromdateiso8601) as $at
  | [ .[]
      | select(.user.login == "github-actions[bot]")
      | select((.created_at | fromdateiso8601) >= $at
               and (.created_at | fromdateiso8601) <= ($at + 300))
      | select(.body | legacy_body or marked_body($head)) ]
  | sort_by(.created_at, .id) | first // null
' "$COMMENTS")
if [ "$OWNER_COMMENT" = null ]; then
  echo "No adjacent github-actions fail-closed application comment proves ownership; preserving needs-external-review."
  exit 0
fi
# Close the read/delete race as far as the API permits: repeat both
# mutable facts immediately before deletion. A human re-application,
# an unlinking event, a head/base move, or any read failure holds the label.
if ! fetch_array "repos/$REPO/issues/$PR_NUMBER/timeline" "$TIMELINE"; then
  exit 0
fi
LATEST_AGAIN=$(jq -c '
  [ .[]
    | select((.event == "labeled" or .event == "unlabeled")
             and .label.name == "needs-external-review") ]
  | sort_by(.created_at, .id) | last // null
' "$TIMELINE")
if ! read_live_pr "$LIVE"; then
  exit 0
fi
if [ "$(jq -r '.id // ""' <<<"$LATEST_AGAIN")" != "$LABEL_EVENT_ID" ] \
   || [ "$(jq -r '.event // ""' <<<"$LATEST_AGAIN")" != labeled ] \
   || [ "$(jq -r '.actor.login // ""' <<<"$LATEST_AGAIN")" != 'github-actions[bot]' ] \
   || [ "$(jq -r '.head_sha' "$LIVE")" != "$EXPECTED_HEAD_SHA" ] \
   || [ "$(jq -r '.base_sha' "$LIVE")" != "$EXPECTED_BASE_SHA" ] \
   || ! jq -e '.labels | index("needs-external-review") != null' "$LIVE" >/dev/null; then
  echo "::warning::PR head, base, label, or ownership changed during reconciliation; preserving needs-external-review." >&2
  exit 0
fi
if [ -z "$LABEL_REMOVAL_TOKEN" ]; then
  echo "::warning::Label-removal token is unavailable; preserving needs-external-review." >&2
  exit 0
fi
if ! GH_TOKEN="$LABEL_REMOVAL_TOKEN" gh api -X DELETE "repos/$REPO/issues/$PR_NUMBER/labels/needs-external-review"; then  # NO_BARE_GH_WRITE_EXEMPT: CI workflow write under the producer PAT or the exchanged policy-mutations app token; no agent identity to verify (#2727 3c)
  echo "::warning::Could not remove needs-external-review; preserving the label for Label Gate." >&2
  exit 0
fi
echo "Removed workflow-owned fail-closed needs-external-review after a trusted no-review classification."
