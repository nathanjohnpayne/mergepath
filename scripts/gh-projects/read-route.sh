#!/usr/bin/env bash
# Read an issue's model/effort route from its `mergepath-route` marker.
#
# Usage:
#   scripts/gh-projects/read-route.sh <issue_number> [--repo OWNER/REPO]
#   scripts/gh-projects/read-route.sh <issue_number> [--repo OWNER/REPO] --body-file PATH
#   scripts/gh-projects/read-route.sh --vocabulary
#
# --body-file parses the body held in PATH instead of reading the issue, with
# the same verdicts and exit codes and no gh call. It exists so a caller that
# already holds the body (the route-marker backfill, #2850) reuses this parser
# instead of keeping a second one.
#
# Prints the route on one line in a stable, parseable form:
#
#   anthropic=opus-5.5/high openai=gpt-6.1-sol/high
#
# and nothing else on stdout. Every failure prints one line on stderr that
# names its case, prints nothing on stdout (never a partial route), and exits
# with that case's own code:
#
#   0  found        a valid marker; the route is on stdout
#   1  read-failed  the issue could not be read (gh missing or gh failed, or
#                   the --body-file PATH is unreadable)
#   2  usage        bad arguments, or no resolvable OWNER/REPO
#   3  no-marker    the body carries no marker; keep the session's model/effort,
#                   unless the issue carries decision-needed (not ready to start)
#   4  malformed    a marker line breaks the format, or
#   4  out-of-vocabulary  a model or effort value is not in the vocabulary
#   5  duplicated   more than one marker line
#
# The contract is docs/agents/shared-operating-rules.md § The route marker:
#
#   <!-- mergepath-route: anthropic=<model>/<effort> openai=<model>/<effort> -->
#
# One marker per issue, on its own line, both halves, anthropic first.
# Where the contract is silent this reads strictly:
#   - a marker candidate is a line that, after one optional trailing CR and
#     any leading or trailing whitespace, begins with `<!--` and contains the
#     token `mergepath-route`. A prose mention ("reads the `mergepath-route`
#     marker"), an inline-code span, or a `mergepath-route: ...` line without
#     the `<!--` opener is not a candidate, so it cannot make a one-marker
#     issue `duplicated`. A half-typed comment (`<!--mergepath-route ...`,
#     a missing `-->`) is still a candidate and fails closed as `malformed`;
#   - lines inside a fenced code block are not candidates, so a documentation
#     example does not count. Fences follow CommonMark: an opening run of 3+
#     backticks or tildes (up to 3 spaces of indent; a backtick info string
#     may not contain a backtick), closed by a run of the same character at
#     least as long, with only whitespace after it; an unclosed fence runs to
#     the end of the body. Fences nested in blockquotes or list items are not
#     recognized, so a marker line there is still a candidate;
#   - a candidate must be exactly the canonical marker, with no text before or
#     after it and single spaces exactly where the format shows them. The
#     contract says "its own line", so leading or trailing whitespace on an
#     otherwise exact marker is NOT accepted: it is a candidate that fails as
#     `malformed` (one trailing CR is tolerated, because web-edited bodies are
#     CRLF);
#   - two or more candidates are `duplicated` whatever they say.
#
# REST only: one `GET repos/OWNER/REPO/issues/N` (none with --body-file). A Claude cloud session's
# GitHub proxy serves only `repos/<owner>/<repo>/...` and no GraphQL, and the
# boards (projectsV2) are outside it, so this script never calls either. It is
# read-only and so does not source lib.sh, which demands a write-identity PAT;
# it uses whatever read auth `gh` already has.
#
# Repository: --repo, else $REPO, else the owner/name of the `origin` remote.
# (`gh repo view` is GraphQL and is deliberately not used.)

set -euo pipefail

# The vocabulary lives here and only here. Keep it equal to the table in
# docs/agents/shared-operating-rules.md § The route marker; check_gh_projects_
# read_route compares the two, so a change to either one alone fails.
ANTHROPIC_MODELS="haiku-4.5 sonnet-5.5 opus-5.5 fable-5.1"
ANTHROPIC_EFFORTS="low medium high"
OPENAI_MODELS="gpt-6-luna gpt-6.1-sol gpt-6-astra"
OPENAI_EFFORTS="low medium high xhigh"

NAME="read-route.sh"

usage() {
  echo "usage: $NAME <issue_number> [--repo OWNER/REPO] [--body-file PATH]" >&2
  echo "       $NAME --vocabulary" >&2
}

in_list() { # in_list <value> <space-separated list>
  case " $2 " in *" $1 "*) return 0 ;; *) return 1 ;; esac
}

REPO_ARG=""
ISSUE_NUM=""
BODY_FILE=""
BODY_FILE_SET=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --vocabulary)
      echo "anthropic.models=$ANTHROPIC_MODELS"
      echo "anthropic.efforts=$ANTHROPIC_EFFORTS"
      echo "openai.models=$OPENAI_MODELS"
      echo "openai.efforts=$OPENAI_EFFORTS"
      exit 0
      ;;
    --repo)
      if [ "$#" -lt 2 ] || [ -z "$2" ]; then echo "$NAME: usage: --repo needs OWNER/REPO" >&2; usage; exit 2; fi
      REPO_ARG="$2"; shift 2
      ;;
    --repo=*) REPO_ARG="${1#--repo=}"; shift ;;
    --body-file)
      if [ "$#" -lt 2 ] || [ -z "$2" ]; then echo "$NAME: usage: --body-file needs PATH" >&2; usage; exit 2; fi
      BODY_FILE="$2"; BODY_FILE_SET=1; shift 2
      ;;
    --body-file=*)
      BODY_FILE="${1#--body-file=}"; BODY_FILE_SET=1; shift
      if [ -z "$BODY_FILE" ]; then echo "$NAME: usage: --body-file needs PATH" >&2; usage; exit 2; fi
      ;;
    -?*) echo "$NAME: usage: unknown option: $1" >&2; usage; exit 2 ;;
    *)
      if [ -n "$ISSUE_NUM" ]; then echo "$NAME: usage: unexpected extra argument: $1" >&2; usage; exit 2; fi
      ISSUE_NUM="$1"; shift
      ;;
  esac
done

case "$ISSUE_NUM" in ''|*[!0-9]*|0*) echo "$NAME: usage: issue number must be a positive integer, got '$ISSUE_NUM'" >&2; usage; exit 2 ;; esac

REPO_SLUG="${REPO_ARG:-${REPO:-}}"
if [ -z "$REPO_SLUG" ]; then
  REMOTE_URL="$(git remote get-url origin 2>/dev/null || true)"
  REMOTE_URL="${REMOTE_URL%/}"
  REMOTE_URL="${REMOTE_URL%.git}"
  REPO_SLUG="${REMOTE_URL##*/}"
  if [ -n "$REPO_SLUG" ]; then
    REMOTE_OWNER="${REMOTE_URL%/*}"
    REMOTE_OWNER="${REMOTE_OWNER##*[/:]}"
    REPO_SLUG="$REMOTE_OWNER/$REPO_SLUG"
  fi
fi
case "$REPO_SLUG" in
  */*/*|/*|*/|*[!A-Za-z0-9._/-]*|'') echo "$NAME: usage: repository must be OWNER/REPO (pass --repo or set REPO), got '$REPO_SLUG'" >&2; usage; exit 2 ;;
  */*) ;;
  *) echo "$NAME: usage: repository must be OWNER/REPO (pass --repo or set REPO), got '$REPO_SLUG'" >&2; usage; exit 2 ;;
esac

if [ "$BODY_FILE_SET" = "1" ]; then
  # The caller holds the body: parse it and make no gh call.
  if [ ! -f "$BODY_FILE" ] || [ ! -r "$BODY_FILE" ] || ! BODY="$(cat -- "$BODY_FILE")"; then
    echo "$NAME: read-failed: could not read the body of issue #$ISSUE_NUM in $REPO_SLUG from --body-file '$BODY_FILE'" >&2
    exit 1
  fi
else
  command -v gh >/dev/null 2>&1 || { echo "$NAME: read-failed: gh CLI not on PATH" >&2; exit 1; }

  # The only network call: the issue over REST. `// ""` turns a null body into
  # an empty one, which is the no-marker case rather than a read failure.
  if ! BODY="$(gh api "repos/$REPO_SLUG/issues/$ISSUE_NUM" --jq '.body // ""')"; then
    echo "$NAME: read-failed: could not read issue #$ISSUE_NUM in $REPO_SLUG over REST (see the gh error above)" >&2
    exit 1
  fi
fi

# The strict format, as one pattern: both halves, anthropic first, single
# spaces, the whole line. The captures are checked against the vocabulary.
MARKER_RE='^<!-- mergepath-route: anthropic=([a-z0-9.-]+)/([a-z]+) openai=([a-z0-9.-]+)/([a-z]+) -->$'

CANDIDATES=0
MARKER_LINE=""
FENCE_CHAR=""
FENCE_LEN=0
# shellcheck disable=SC2016  # a literal backtick run in a regex, not an expansion
FENCE_OPEN_BT='^ {0,3}(`{3,})[^`]*$'
FENCE_OPEN_TL='^ {0,3}(~{3,}).*$'
FENCE_CLOSE='^ {0,3}(`{3,}|~{3,})[[:space:]]*$'
while IFS= read -r LINE || [ -n "$LINE" ]; do
  LINE="${LINE%$'\r'}"
  if [ -n "$FENCE_CHAR" ]; then
    # Inside a fence only a closing fence matters: same character, at least
    # as long as the opener, up to 3 spaces of indent, nothing after it.
    if [[ "$LINE" =~ $FENCE_CLOSE ]]; then
      CLOSE="${BASH_REMATCH[1]}"
      if [ "${CLOSE:0:1}" = "$FENCE_CHAR" ] && [ "${#CLOSE}" -ge "$FENCE_LEN" ]; then
        FENCE_CHAR=""; FENCE_LEN=0
      fi
    fi
    continue
  fi
  if [[ "$LINE" =~ $FENCE_OPEN_BT ]] || [[ "$LINE" =~ $FENCE_OPEN_TL ]]; then
    FENCE_CHAR="${BASH_REMATCH[1]:0:1}"
    FENCE_LEN="${#BASH_REMATCH[1]}"
    continue
  fi
  TRIMMED="${LINE#"${LINE%%[![:space:]]*}"}"
  case "$TRIMMED" in '<!--'*mergepath-route*) ;; *) continue ;; esac
  CANDIDATES=$((CANDIDATES + 1))
  MARKER_LINE="$LINE"
done <<<"$BODY"

if [ "$CANDIDATES" -eq 0 ]; then
  echo "$NAME: no-marker: issue #$ISSUE_NUM in $REPO_SLUG has no mergepath-route marker; keep the session's model and effort unless the issue carries decision-needed" >&2
  exit 3
fi
if [ "$CANDIDATES" -gt 1 ]; then
  echo "$NAME: duplicated: issue #$ISSUE_NUM in $REPO_SLUG has $CANDIDATES mergepath-route marker lines; exactly one is allowed" >&2
  exit 5
fi

if ! [[ "$MARKER_LINE" =~ $MARKER_RE ]]; then
  echo "$NAME: malformed: the mergepath-route line on issue #$ISSUE_NUM in $REPO_SLUG does not match '<!-- mergepath-route: anthropic=<model>/<effort> openai=<model>/<effort> -->' exactly" >&2
  exit 4
fi
A_MODEL="${BASH_REMATCH[1]}"
A_EFFORT="${BASH_REMATCH[2]}"
O_MODEL="${BASH_REMATCH[3]}"
O_EFFORT="${BASH_REMATCH[4]}"

BAD=""
in_list "$A_MODEL" "$ANTHROPIC_MODELS" || BAD="$BAD anthropic model '$A_MODEL'"
in_list "$A_EFFORT" "$ANTHROPIC_EFFORTS" || BAD="$BAD anthropic effort '$A_EFFORT'"
in_list "$O_MODEL" "$OPENAI_MODELS" || BAD="$BAD openai model '$O_MODEL'"
in_list "$O_EFFORT" "$OPENAI_EFFORTS" || BAD="$BAD openai effort '$O_EFFORT'"
if [ -n "$BAD" ]; then
  echo "$NAME: out-of-vocabulary: issue #$ISSUE_NUM in $REPO_SLUG names a value outside the vocabulary:$BAD" >&2
  exit 4
fi

echo "anthropic=$A_MODEL/$A_EFFORT openai=$O_MODEL/$O_EFFORT"
