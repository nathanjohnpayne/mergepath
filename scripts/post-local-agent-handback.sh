#!/usr/bin/env bash
# scripts/post-local-agent-handback.sh — park a PR step a session cannot
# complete, with the state it established, for a session that can (#1057 D).
#
# A cloud session that reaches one of its ceilings (no GraphQL for thread
# resolution, one-branch pushes, no cross-repo access) used to stop with a
# prose handoff in its own chat transcript that a human copied by hand, and
# the next session re-derived everything. This posts that handoff to the PR
# itself as a structured comment and marks the PR `needs-local-agent`:
#
#   - the capability that blocked, and the session's measured tier
#   - the head SHA the state was established at
#   - the review-feedback accounting at that head (posted / accounted)
#   - the session's transcript URL, so the next session reads the run
#     rather than a paraphrase of it (--session-url, MERGEPATH_SESSION_URL,
#     or derived from CLAUDE_CODE_REMOTE_SESSION_ID)
#   - the exact next command
#
# `needs-local-agent` is the fourth member of the handoff family (see
# REVIEW_POLICY.md § Handoff Message Format § Local-agent handback). It is
# INFORMATIONAL: it is not a blocking label (scripts/lib/blocking-labels.sh),
# no gate reads its presence or absence, and it is agent-removable — the
# resuming session removes it once the next command has run. Removing it
# clears nothing else; `human-hold` / `needs-human-review` /
# `policy-violation` are untouched by this script.
#
# Every call is REST, not GraphQL, because the session most likely to need
# this is one whose proxy refuses GraphQL. The comment is posted through
# scripts/gh-as-reviewer.sh under the session's reviewer identity, so the
# handback works even when the missing capability is the AUTHOR token, and
# its author is read back from the POST response.
#
# Usage:
#   scripts/post-local-agent-handback.sh <PR#> --blocked <capability> \
#     --next "<command>" [--repo OWNER/REPO] [--note-file FILE]
#     [--session-url URL] [--print]
#
#   <capability>  one of: author-writes reviewer-writes graphql cross-repo
#                 push-multi-branch (the agent-capability-probe vocabulary)
#   --session-url the run's transcript URL. A Claude cloud session derives it
#                 from CLAUDE_CODE_REMOTE_SESSION_ID; a Codex task has no such
#                 variable, so pass its task URL (or set MERGEPATH_SESSION_URL)
#   --print       render the comment to stdout and post nothing
#
# Exit codes:
#   0  handback posted and labelled (or rendered, with --print)
#   1  bad invocation
#   3  a read the handback needs failed (head SHA)
#   4  the comment could not be posted, or the label it needs could not be
#      created first: nothing was posted, and the rendered body is on stdout
#      so the session can relay it another way
#   5  the comment posted but its author did not read back as the reviewer,
#      or the label could not be applied
#
# Bash 3.2 portable.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LABEL="needs-local-agent"
LABEL_COLOR="fbca04"
LABEL_DESC="A cloud/limited session parked this step; a session with the named capability resumes it"
CAPABILITIES="author-writes reviewer-writes graphql cross-repo push-multi-branch"

PR=""
REPO=""
BLOCKED=""
NEXT=""
NOTE_FILE=""
SESSION_URL="${MERGEPATH_SESSION_URL:-}"
PRINT=false

usage() { sed -n '2,/^# Bash 3.2 portable/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2; }
die() { echo "post-local-agent-handback: $2" >&2; exit "$1"; }

while [ "$#" -gt 0 ]; do
  case "$1" in
    --blocked|--next|--repo|--note-file|--session-url)
      [ "$#" -ge 2 ] || die 1 "$1 requires a value"
      case "$1" in
        --blocked) BLOCKED="$2" ;;
        --next) NEXT="$2" ;;
        --repo) REPO="$2" ;;
        --note-file) NOTE_FILE="$2" ;;
        --session-url) SESSION_URL="$2" ;;
      esac
      shift 2
      ;;
    --print) PRINT=true; shift ;;
    -h|--help) usage; exit 0 ;;
    -*) die 1 "unknown option: $1" ;;
    *)
      [ -z "$PR" ] || die 1 "unexpected argument: $1"
      PR="$1"; shift
      ;;
  esac
done

printf '%s' "$PR" | grep -Eq '^[0-9]+$' || die 1 "PR number required (got '${PR}')"
[ -n "$BLOCKED" ] || die 1 "--blocked <capability> is required"
case " $CAPABILITIES " in *" $BLOCKED "*) ;; *) die 1 "--blocked must be one of: $CAPABILITIES (got '$BLOCKED')" ;; esac
[ -n "$NEXT" ] || die 1 "--next \"<command>\" is required: the resuming session runs it"
if [ -n "$NOTE_FILE" ] && [ ! -r "$NOTE_FILE" ]; then die 1 "note file not readable: $NOTE_FILE"; fi
case "$SESSION_URL" in ''|https://*) ;; *) die 1 "--session-url must be an https:// URL (got '$SESSION_URL')" ;; esac
case "$SESSION_URL" in *[[:space:]]*) die 1 "--session-url must not contain whitespace" ;; esac
command -v jq >/dev/null 2>&1 || die 1 "jq is required"
command -v gh >/dev/null 2>&1 || die 1 "gh is required"

if [ -z "$REPO" ]; then
  REPO="$(git -C "$ROOT" remote get-url origin 2>/dev/null \
    | sed -nE 's#^(https://[^/]*github\.com/|git@github(-[A-Za-z0-9]+)?(\.com)?:|ssh://git@github(-[A-Za-z0-9]+)?(\.com)?/)([^/]+/[^/]+)$#\6#p' \
    | sed -E 's/\.git$//')"
  [ -n "$REPO" ] || die 1 "could not derive OWNER/REPO from origin; pass --repo"
fi

# --- state the handback records --------------------------------------------

# Reads use a provisioned PAT when there is one: a Codex cloud task has no gh
# keyring and no ambient token, only the OP_PREFLIGHT_*_PAT variables (Codex
# on #1555). A read needs no identity proof, so no verification here; every
# write below goes through the reviewer wrapper, which verifies its token.
READ_TOKEN="${OP_PREFLIGHT_REVIEWER_PAT:-${OP_PREFLIGHT_AUTHOR_PAT:-${GH_TOKEN:-}}}"
read_gh() {
  if [ -n "$READ_TOKEN" ]; then GH_TOKEN="$READ_TOKEN" gh "$@"; else gh "$@"; fi
}

read_head() {
  local sha
  sha="$(read_gh api "repos/$REPO/pulls/$PR" --jq '.head.sha' 2>/dev/null || true)"
  printf '%s' "$sha" | grep -Eq '^[0-9a-f]{40}$' || return 1
  printf '%s\n' "$sha"
}
HEAD_SHA="$(read_head)" || die 3 "could not read the head SHA of $REPO#$PR; a handback without it cannot be resumed safely"

TIER="unmeasured"
SURFACE="unknown"
if [ -x "$ROOT/scripts/agent-capability-probe.sh" ]; then
  exports="$("$ROOT/scripts/agent-capability-probe.sh" --repo "$REPO" --check --print-exports 2>/dev/null || true)"
  if [ -n "$exports" ]; then
    measured="$(bash -c "$exports"'
printf "%s|%s" "${MERGEPATH_AGENT_TIER:-}" "${MERGEPATH_AGENT_SURFACE_MEASURED:-}"' 2>/dev/null || true)"
    [ -n "${measured%%|*}" ] && TIER="${measured%%|*}"
    [ -n "${measured#*|}" ] && SURFACE="${measured#*|}"
  fi
fi

collect_accounting() {
  local acct
  ACCOUNTING="not measured"
  [ -x "$ROOT/scripts/review-feedback-accounting.sh" ] || return 0
  if [ -n "$READ_TOKEN" ]; then
    acct="$(GH_TOKEN="$READ_TOKEN" "$ROOT/scripts/review-feedback-accounting.sh" "$PR" "$REPO" 2>/dev/null || true)"
  else
    acct="$("$ROOT/scripts/review-feedback-accounting.sh" "$PR" "$REPO" 2>/dev/null || true)"
  fi
  if printf '%s' "$acct" | jq -e '.posted | numbers' >/dev/null 2>&1; then
    ACCOUNTING="$(printf '%s' "$acct" | jq -r '"\(.posted) posted, \(.accounted) accounted"')"
  fi
}

# The accounting must describe the head the comment names: a push while it
# runs would record new state against the old SHA (CodeRabbit on #1555). So
# the head is read again afterwards, and the collection repeats on the new
# head until the two agree.
settled=false
for _ in 1 2 3; do
  collect_accounting
  after="$(read_head)" || die 3 "could not re-read the head SHA of $REPO#$PR after collecting its state"
  if [ "$after" = "$HEAD_SHA" ]; then settled=true; break; fi
  echo "post-local-agent-handback: head moved $HEAD_SHA -> $after while collecting state; collecting again" >&2
  HEAD_SHA="$after"
done
$settled || die 3 "the head of $REPO#$PR kept moving while its state was collected; wait for the pushes to settle and run again"

# A Codex task has no session variable, so an explicit URL wins; without one
# the measured surface is still recorded rather than calling a cloud task
# local (Codex on #1555).
if [ -n "$SESSION_URL" ]; then
  SESSION="$SESSION_URL"
elif [ -n "${CLAUDE_CODE_REMOTE_SESSION_ID:-}" ]; then
  SESSION="https://claude.ai/code/${CLAUDE_CODE_REMOTE_SESSION_ID/#cse_/session_}"
else
  case "$SURFACE" in
    local) SESSION="local session (no transcript URL)" ;;
    *) SESSION="\`$SURFACE\` session; no transcript URL was supplied (pass --session-url)" ;;
  esac
fi

BODY_FILE="$(mktemp "${TMPDIR:-/tmp}/local-agent-handback.XXXXXX")"
trap 'rm -f "$BODY_FILE"' EXIT
{
  printf '<!-- mergepath-handback: v1 head=%s blocked=%s -->\n' "$HEAD_SHA" "$BLOCKED"
  printf '## Needs a local agent\n\n'
  printf 'This session cannot complete the next step on this PR. It lacks the `%s` capability. The state below was established at head `%s`.\n\n' "$BLOCKED" "$HEAD_SHA"
  printf -- '- **Blocked capability:** `%s`\n' "$BLOCKED"
  printf -- '- **Session tier:** `%s` (surface: `%s`)\n' "$TIER" "$SURFACE"
  printf -- '- **Head:** `%s`\n' "$HEAD_SHA"
  printf -- '- **Review feedback at this head:** %s\n' "$ACCOUNTING"
  printf -- '- **Session:** %s\n\n' "$SESSION"
  printf '### Next command\n\n```bash\n%s\n```\n\n' "$NEXT"
  if [ -n "$NOTE_FILE" ]; then
    printf '### Notes\n\n'
    cat "$NOTE_FILE"
    printf '\n\n'
  fi
  printf '### Resuming\n\n'
  printf 'First confirm the PR head is still `%s`. If it moved, re-derive the state instead of trusting this note. Then run the next command from a session that has `%s`. Remove the `%s` label only once the step it stands for has completed: a dispatch that returned is not completion. For thread resolution, `scripts/dispatch-thread-resolution-lane.sh %s` dispatches the lane and waits for its own run, exiting 0 only when that run succeeded. The label is informational: no gate reads it, and removing it clears no other label.\n' "$HEAD_SHA" "$BLOCKED" "$LABEL" "$PR"
} >"$BODY_FILE"

if $PRINT; then
  cat "$BODY_FILE"
  exit 0
fi

# --- post and label ----------------------------------------------------------

AS_REVIEWER="$ROOT/scripts/gh-as-reviewer.sh"
[ -x "$AS_REVIEWER" ] || { cat "$BODY_FILE"; die 4 "reviewer wrapper missing ($AS_REVIEWER); the handback body is on stdout"; }
# shellcheck source=lib/gh-token-resolver.sh
. "$ROOT/scripts/lib/gh-token-resolver.sh"
EXPECTED="$(gh_default_reviewer_identity)"

# The label is created before anything is posted. A repository that got this
# script by propagation has no needs-local-agent label (only bootstrap seeds
# it), and failing on the label after the comment would leave a comment that
# every retry duplicates (Codex on #1555). Adding a label by name does not
# reliably create it, so it is created explicitly; "already exists" is fine.
if ! "$AS_REVIEWER" -- gh api "repos/$REPO/labels/$LABEL" >/dev/null 2>&1 \
   && ! "$AS_REVIEWER" -- gh api -X POST "repos/$REPO/labels" -f "name=$LABEL" -f "color=$LABEL_COLOR" -f "description=$LABEL_DESC" >/dev/null 2>&1; then
  cat "$BODY_FILE"
  die 4 "the $LABEL label does not exist on $REPO and could not be created; nothing was posted, and the rendered body is on stdout: relay it another way"
fi

posted=""
if ! posted="$("$AS_REVIEWER" -- gh api -X POST "repos/$REPO/issues/$PR/comments" -F "body=@$BODY_FILE" 2>/dev/null)"; then
  cat "$BODY_FILE"
  die 4 "could not post the handback comment on $REPO#$PR as $EXPECTED; the rendered body is on stdout: relay it another way"
fi
author="$(printf '%s' "$posted" | jq -r '.user.login // empty' 2>/dev/null || true)"
url="$(printf '%s' "$posted" | jq -r '.html_url // empty' 2>/dev/null || true)"
if [ "$author" != "$EXPECTED" ]; then
  die 5 "handback comment ${url:-?} landed under '${author:-unknown}', expected '$EXPECTED' (#241 class); delete it and retry with a user-held reviewer token"
fi
echo "post-local-agent-handback: posted $url as $author" >&2

if ! "$AS_REVIEWER" -- gh api -X POST "repos/$REPO/issues/$PR/labels" -f "labels[]=$LABEL" >/dev/null 2>&1; then
  die 5 "handback posted ($url) but the $LABEL label could not be applied; add it by hand"
fi
echo "post-local-agent-handback: labelled $REPO#$PR $LABEL" >&2
exit 0
