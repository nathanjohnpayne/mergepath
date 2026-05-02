#!/usr/bin/env bash
# request-label-removal.sh — post a structured label-removal ask on a PR.
#
# Background: REVIEW_POLICY.md prohibits agents from removing the
# `needs-external-review`, `needs-human-review`, and `policy-violation`
# labels — even when authorized in chat. Label removal is a human action.
# This helper turns the prohibition into a one-command ask: the agent
# posts a templated PR comment and (optionally) pings the human via
# iMessage so they can clear the label without opening a chat window.
#
# Usage:
#   scripts/request-label-removal.sh <PR#> <label>
#   scripts/request-label-removal.sh <PR#> <label> --reason "<short reason>"
#   scripts/request-label-removal.sh <PR#> <label> --repo owner/name
#
# Notification: if MERGEPATH_NOTIFY_IMESSAGE_TO is set to a phone number
# or contact name resolvable by Messages.app, this script also fires an
# iMessage with the PR URL. Otherwise it skips silently.
#
# Examples:
#   scripts/request-label-removal.sh 182 needs-external-review
#   scripts/request-label-removal.sh 182 needs-human-review \
#     --reason "Codex cleared r3; CI green; only blocker is this label"
#   MERGEPATH_NOTIFY_IMESSAGE_TO="+15551234567" \
#     scripts/request-label-removal.sh 182 needs-external-review
#
# Exit codes:
#   0 = comment posted (and iMessage sent if configured)
#   1 = bad arguments / unsupported label
#   2 = gh failure (auth, missing PR, network)

set -eo pipefail

ALLOWED_LABELS=(needs-external-review needs-human-review policy-violation)

usage() {
  cat <<'EOF' >&2
Usage: scripts/request-label-removal.sh <PR#> <label> [--reason <text>] [--repo owner/name]

Allowed labels: needs-external-review | needs-human-review | policy-violation

Posts a templated PR comment asking the human to remove the label.
Sends an iMessage to MERGEPATH_NOTIFY_IMESSAGE_TO if set.
EOF
  exit 1
}

PR_NUM=""
LABEL=""
REASON=""
REPO=""

while [ $# -gt 0 ]; do
  case "$1" in
    --reason) REASON="$2"; shift 2 ;;
    --repo)   REPO="$2"; shift 2 ;;
    -h|--help) usage ;;
    -*) echo "Unknown flag: $1" >&2; usage ;;
    *)
      if [ -z "$PR_NUM" ]; then PR_NUM="$1"
      elif [ -z "$LABEL" ]; then LABEL="$1"
      else echo "Unexpected positional: $1" >&2; usage
      fi
      shift
      ;;
  esac
done

[ -z "$PR_NUM" ] && usage
[ -z "$LABEL" ] && usage

allowed=0
for ok in "${ALLOWED_LABELS[@]}"; do
  if [ "$LABEL" = "$ok" ]; then allowed=1; break; fi
done
if [ "$allowed" -ne 1 ]; then
  echo "Refusing: '$LABEL' is not a human-action label." >&2
  echo "Allowed: ${ALLOWED_LABELS[*]}" >&2
  echo "If this label is genuinely a no-op blocker, just remove it directly." >&2
  exit 1
fi

REPO_FLAG=()
if [ -n "$REPO" ]; then REPO_FLAG=(--repo "$REPO"); fi

PR_URL=$(gh pr view "$PR_NUM" "${REPO_FLAG[@]}" --json url --jq .url 2>/dev/null) || {
  echo "Could not resolve PR #$PR_NUM. Check --repo and gh auth." >&2
  exit 2
}

REASON_BLOCK=""
if [ -n "$REASON" ]; then
  REASON_BLOCK=$'\n\n**Context:** '"$REASON"
fi

BODY="@nathanjohnpayne — this PR is blocked only on the \`$LABEL\` label.

Per [REVIEW_POLICY.md § Agent prohibitions](https://github.com/nathanjohnpayne/mergepath/blob/main/REVIEW_POLICY.md), agents do not remove this label. When you're ready, clear it from any device:

- GitHub UI: Labels sidebar → click \`x\` on \`$LABEL\`
- CLI: \`gh pr edit $PR_NUM --remove-label $LABEL\` $([ -n "$REPO" ] && echo "--repo $REPO")

Auto-merge will fire as soon as the label is gone.${REASON_BLOCK}

— posted by \`scripts/request-label-removal.sh\`"

if ! gh pr comment "$PR_NUM" "${REPO_FLAG[@]}" --body "$BODY" >/dev/null; then
  echo "Failed to post comment on PR #$PR_NUM" >&2
  exit 2
fi
echo "Posted label-removal request on $PR_URL"

if [ -n "${MERGEPATH_NOTIFY_IMESSAGE_TO:-}" ]; then
  IMSG_BODY="Mergepath: PR #$PR_NUM blocked on '$LABEL' label. Clear when ready: $PR_URL"
  IMSG_BODY_ESC=${IMSG_BODY//\"/\\\"}
  TARGET_ESC=${MERGEPATH_NOTIFY_IMESSAGE_TO//\"/\\\"}
  if osascript -e "tell application \"Messages\" to send \"$IMSG_BODY_ESC\" to buddy \"$TARGET_ESC\" of (service 1 whose service type is iMessage)" >/dev/null 2>&1; then
    echo "Notified $MERGEPATH_NOTIFY_IMESSAGE_TO via iMessage"
  else
    echo "iMessage notify failed (non-fatal); comment is the source of truth" >&2
  fi
fi
