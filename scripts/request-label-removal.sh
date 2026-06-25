#!/usr/bin/env bash
# request-label-removal.sh — post a structured label-removal ask on a PR.
#
# Background: REVIEW_POLICY.md prohibits agents from removing the
# `needs-external-review`, `needs-human-review`, `policy-violation`, and
# `human-hold` labels — even when authorized in chat. Label removal is a
# human action.
# This helper turns the prohibition into a one-command ask: the agent
# posts a templated PR comment and (optionally) pings the human via
# iMessage so they can clear the label without opening a chat window.
#
# Note for `needs-external-review`: the `auto-clear-blocking-labels.yml`
# workflow (#191/#195) usually removes that label automatically once
# `scripts/codex-review-check.sh` clears the merge gate. The workflow
# fires on pull_request_target / pull_request_review / workflow_run
# events (event-driven path) and on a 15-minute `schedule` cron
# (#197 — catches the 👍-after-last-push case). Use this script for
# `needs-external-review` only when neither the event-driven path
# nor the sweep has fired in a reasonable window — typically rare.
# For `needs-human-review`, `policy-violation`, and `human-hold`, this
# script is the only path; all three remain manual-only by design.
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
#   scripts/request-label-removal.sh 182 human-hold \
#     --reason "Morning 4b review approved the current HEAD"
#   MERGEPATH_NOTIFY_IMESSAGE_TO="+15551234567" \
#     scripts/request-label-removal.sh 182 needs-external-review
#
# Exit codes:
#   0 = comment posted (and iMessage sent if configured)
#   1 = bad arguments / unsupported label
#   2 = gh failure (auth, missing PR, network)

set -euo pipefail
# `-u` added (#536): every optional is already guarded with `${VAR:-}`,
# so unset-variable strictness surfaces genuine typos without breaking the
# documented optional-arg paths.

# --- preflight auto-source (#282) ------------------------------------------
# If OP_PREFLIGHT_REVIEWER_PAT is unset and a fresh op-preflight cache
# exists for this agent, source it. The token resolver below prefers
# OP_PREFLIGHT_REVIEWER_PAT and falls back to `gh auth token --user`
# for the expected reviewer identity. Silent on no-op paths.
__REQUEST_LABEL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -z "${OP_PREFLIGHT_REVIEWER_PAT:-}" ] && [ -r "$__REQUEST_LABEL_DIR/lib/preflight-helpers.sh" ]; then
  # shellcheck source=lib/preflight-helpers.sh
  . "$__REQUEST_LABEL_DIR/lib/preflight-helpers.sh"
  auto_source_preflight
fi
if [ ! -r "$__REQUEST_LABEL_DIR/lib/gh-token-resolver.sh" ]; then
  echo "ERROR: gh-token-resolver helper missing: $__REQUEST_LABEL_DIR/lib/gh-token-resolver.sh" >&2
  echo "       Refusing to post label-removal ask without reviewer-token verification." >&2
  exit 2
fi
# shellcheck source=lib/gh-token-resolver.sh
. "$__REQUEST_LABEL_DIR/lib/gh-token-resolver.sh"

ALLOWED_LABELS=(needs-external-review needs-human-review policy-violation human-hold)

# Escape a string for embedding inside an AppleScript double-quoted
# literal. See the inline call site below for the full rationale on
# escape ordering; the function is hoisted up here so unit tests can
# `source` this script (with MERGEPATH_REQUEST_LABEL_REMOVAL_LIB=1) and
# call it directly without firing the main flow.
applescript_escape() {
  local s="$1"
  s=${s//\\/\\\\}        # \  -> \\          (must be FIRST)
  s=${s//\"/\\\"}        # "  -> \"
  s=${s//$'\n'/\\n}      # LF -> \n
  s=${s//$'\r'/\\r}      # CR -> \r
  s=${s//$'\t'/\\t}      # TAB -> \t
  printf '%s' "$s"
}

# Library mode: when sourced by a test harness with this env var set,
# expose helper functions only and skip the main flow (which would
# error on the missing positional PR#).
if [ "${MERGEPATH_REQUEST_LABEL_REMOVAL_LIB:-0}" = "1" ]; then
  return 0 2>/dev/null || true
fi

usage() {
  cat <<'EOF' >&2
Usage: scripts/request-label-removal.sh <PR#> <label> [--reason <text>] [--repo owner/name]

Allowed labels: needs-external-review | needs-human-review | policy-violation | human-hold

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
    # Validate the value is present BEFORE shift 2 (#536): under
    # `set -eo pipefail` a trailing `--reason` / `--repo` with no value
    # made `shift 2` abort the script (shifting past the end) instead of
    # routing to the usage handler. `[ -n "${2:-}" ] || usage` makes the
    # missing-value case a clean usage exit.
    --reason) [ -n "${2:-}" ] || usage; REASON="$2"; shift 2 ;;
    --repo)   [ -n "${2:-}" ] || usage; REPO="$2"; shift 2 ;;
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
  echo "Refusing: '$LABEL' is not a protected human-action label." >&2
  echo "Allowed: ${ALLOWED_LABELS[*]}" >&2
  echo "If this label is genuinely a no-op blocker, just remove it directly." >&2
  exit 1
fi

REPO_FLAG=()
REPO_HINT_FOR_BODY=""
if [ -n "$REPO" ]; then
  REPO_FLAG=(--repo "$REPO")
  REPO_HINT_FOR_BODY=" --repo $REPO"
fi
# NOTE: the two `"${REPO_FLAG[@]}"` expansions below use the
# `${REPO_FLAG[@]+...}` guard form. macOS's default /bin/bash 3.2 raises
# "unbound variable" on a bare `"${REPO_FLAG[@]}"` when the array is empty
# (the no-`--repo` common case) under the `-u` added above; the guard
# expands to nothing when unset and to the elements otherwise.
# Plain string (set -e safe). The previous form embedded
# `$([ -n "$REPO" ] && echo "--repo $REPO")` directly inside the BODY
# heredoc. In the default no-`--repo` case the inline `[` returns 1,
# the `&&` short-circuits with rc=1, the command substitution's
# rc=1 propagates as the assignment's exit status, and `set -e`
# aborts the whole script BEFORE `gh pr comment` ever runs — so
# every `request-label-removal.sh <PR#> <label>` call without
# `--repo` silently failed (no PR comment, no iMessage, no error
# message to chat past the bash trace). Compute the hint string
# once in a normal `if` block so the assignment can never inherit
# a non-zero exit from a tested-empty command substitution.
# (nathanpayne-codex Phase 4b finding on the 263caf3 sync wave.)

# Token policy (#412):
#  - The structured ask is posted by the reviewer identity because the
#    agent is asking the human to clear a human-action label.
#  - Both the read and the comment write use a token that has been
#    verified as that reviewer identity. The write itself routes through
#    gh-as-reviewer.sh; no machine-global gh account is read or changed.
REVIEWER_IDENTITY="$(gh_default_reviewer_identity)"
if ! gh_resolve_token_for_identity "$REVIEWER_IDENTITY" "OP_PREFLIGHT_REVIEWER_PAT" "request-label-removal"; then
  echo "request-label-removal: refusing to continue without a verified reviewer token for $REVIEWER_IDENTITY." >&2
  exit 2
fi
REVIEWER_TOKEN="$GH_RESOLVED_TOKEN"

PR_URL=$(GH_TOKEN="$REVIEWER_TOKEN" gh pr view "$PR_NUM" ${REPO_FLAG[@]+"${REPO_FLAG[@]}"} --json url --jq .url 2>/dev/null) || {
  echo "Could not resolve PR #$PR_NUM. Check --repo and gh auth." >&2
  exit 2
}

REASON_BLOCK=""
if [ -n "$REASON" ]; then
  REASON_BLOCK=$'\n\n**Context:** '"$REASON"
fi

# For needs-external-review specifically, the auto-clear workflow
# (#191/#195) usually handles removal. Surface that fact in the
# message so the human knows the manual ask is a fallback path.
AUTOCLEAR_NOTE=""
if [ "$LABEL" = "needs-external-review" ]; then
  AUTOCLEAR_NOTE=$'\n\n_Note: `auto-clear-blocking-labels.yml` normally removes this label automatically once `codex-review-check.sh` clears the merge gate (event-driven on `pull_request_target` / `pull_request_review` / `workflow_run`, plus a 15-min `schedule` sweep — the sweep can be intentionally disabled via `auto_clear_labels.scheduled_sweep_enabled: false`). If you\'re seeing this ask, none of those triggers fired AND the sweep hasn\'t caught it yet (or is disabled, or the gate is genuinely not yet met). Manual removal is the fallback._'
fi

BODY="@nathanjohnpayne — this PR is blocked only on the \`$LABEL\` label.

Per [REVIEW_POLICY.md § Agent prohibitions](https://github.com/nathanjohnpayne/mergepath/blob/main/REVIEW_POLICY.md), agents do not remove this label. When you're ready, clear it from any device:

- GitHub UI: Labels sidebar → click \`x\` on \`$LABEL\`
- CLI: \`gh pr edit $PR_NUM --remove-label $LABEL${REPO_HINT_FOR_BODY}\`

The PR can proceed as soon as the label is gone and the normal merge gates are green.${REASON_BLOCK}${AUTOCLEAR_NOTE}

— posted by \`scripts/request-label-removal.sh\`"

AS_REVIEWER="$__REQUEST_LABEL_DIR/gh-as-reviewer.sh"
if [ ! -x "$AS_REVIEWER" ]; then
  echo "ERROR: gh-as-reviewer.sh helper missing or non-executable: $AS_REVIEWER" >&2
  echo "       Refusing to post label-removal ask without reviewer-token verification." >&2
  exit 2
fi

if ! GH_AS_REVIEWER_IDENTITY="$REVIEWER_IDENTITY" OP_PREFLIGHT_REVIEWER_PAT="$REVIEWER_TOKEN" \
  "$AS_REVIEWER" -- gh pr comment "$PR_NUM" ${REPO_FLAG[@]+"${REPO_FLAG[@]}"} --body "$BODY" >/dev/null; then
  echo "Failed to post comment on PR #$PR_NUM" >&2
  exit 2
fi
echo "Posted label-removal request on $PR_URL"

if [ -n "${MERGEPATH_NOTIFY_IMESSAGE_TO:-}" ]; then
  # `applescript_escape` is defined at the top of this file. The
  # string transits both shell and AppleScript, so the escape order
  # is load-bearing — see the helper definition for full rationale.
  IMSG_BODY="Mergepath: PR #$PR_NUM blocked on '$LABEL' label. Clear when ready: $PR_URL"
  IMSG_BODY_ESC=$(applescript_escape "$IMSG_BODY")
  TARGET_ESC=$(applescript_escape "$MERGEPATH_NOTIFY_IMESSAGE_TO")
  if osascript -e "tell application \"Messages\" to send \"$IMSG_BODY_ESC\" to buddy \"$TARGET_ESC\" of (service 1 whose service type is iMessage)" >/dev/null 2>&1; then
    echo "Notified $MERGEPATH_NOTIFY_IMESSAGE_TO via iMessage"
  else
    echo "iMessage notify failed (non-fatal); comment is the source of truth" >&2
  fi
fi
