#!/usr/bin/env bash
# tests/test_gh_rest_transport.sh
#
# Regression suite for scripts/lib/gh-rest-transport.sh (#1057 item A,
# #1542): the REST transport the write wrappers use on a cloud surface, where
# every `gh pr` / `gh issue` subcommand is GraphQL and the proxy refuses it.
#
# The gh stub below serves REST fixtures by method and endpoint, synthesizes
# the issue events a real write produces (so the event-based readback is
# exercised against what GitHub would return), and records every call with
# the token it carried. STUB_WRITE_LOGIN, STUB_PR_AUTHOR, STUB_EVENT_ACTOR and
# STUB_DUPLICATE_ACTOR make a write land under another login, which is the
# mutation each readback must catch.
#
# Bash 3.2 portable.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT/scripts/lib/gh-rest-transport.sh"
AUTHOR="$ROOT/scripts/gh-as-author.sh"
REVIEWER="$ROOT/scripts/gh-as-reviewer.sh"

[ -r "$LIB" ] || { echo "missing $LIB" >&2; exit 1; }
[ -x "$AUTHOR" ] || { echo "missing or non-executable $AUTHOR" >&2; exit 1; }
[ -x "$REVIEWER" ] || { echo "missing or non-executable $REVIEWER" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "jq is required" >&2; exit 1; }
command -v node >/dev/null 2>&1 || { echo "SKIP: node not available (the PR-body contract needs it)" >&2; exit 0; }

# The stub records the token each call carried, and failing cases print that
# log, so the ambient credential environment is scrubbed here (#996). Every
# case pins its own fixture token.
unset OP_PREFLIGHT_AUTHOR_PAT OP_PREFLIGHT_REVIEWER_PAT GH_TOKEN GITHUB_TOKEN GH_HOST GH_ENTERPRISE_TOKEN GITHUB_ENTERPRISE_TOKEN
unset CLAUDE_CODE_REMOTE MERGEPATH_AGENT_SURFACE MERGEPATH_GH_TRANSPORT MERGEPATH_AGENT OP_PREFLIGHT_AGENT GH_REPO GH_AS_AUTHOR_TRACE_MARKER

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/gh-rest-transport-test.XXXXXX")"
trap 'rm -rf "$WORKDIR"' EXIT

PASS=0
FAIL=0
pass() { echo "PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $*" >&2; FAIL=$((FAIL + 1)); }

# ---------------------------------------------------------------------------
# gh stub
# ---------------------------------------------------------------------------
STUB_DIR="$WORKDIR/stub-bin"
mkdir -p "$STUB_DIR"
cat >"$STUB_DIR/gh" <<'STUB'
#!/usr/bin/env bash
LOG="${GH_CALLS_LOG:-/dev/null}"
STATE="${STUB_STATE:-/tmp}"
line="GH_TOKEN=${GH_TOKEN:-} GITHUB_TOKEN=${GITHUB_TOKEN:-} ENT=${GH_ENTERPRISE_TOKEN:-}|${GITHUB_ENTERPRISE_TOKEN:-} gh"  # TOKEN_OUTPUT_EXEMPT: records the fixture token the wrapper selected; every case pins it inline and the ambient credential env is scrubbed above (#996)
input=""
prev=""
for a in "$@"; do
  if [ "$prev" = "--input" ]; then
    # The JSON the wrapper sent, in place of its private temp path.
    input="$(jq -c . "$a")"
    line="$line"$'\t'"$input"
  else
    line="$line"$'\t'"$a"
  fi
  prev="$a"
done
printf '%s\n' "$line" >>"$LOG"
[ -z "${STUB_HOST_LOG:-}" ] || printf '%s\t%s\n' "${GH_HOST:-<unset>}" "$*" >>"$STUB_HOST_LOG"

case "${GH_TOKEN:-}" in
  ghp_author-token|gho_fallback-author-token) login=nathanjohnpayne ;;
  ghp_reviewer-token|gho_fallback-claude-token) login=nathanpayne-claude ;;
  ghp_codex-token|gho_fallback-codex-token) login=nathanpayne-codex ;;
  proxy-injected) login=nathanjohnpayne ;;
  *) login="" ;;
esac
write_login="${STUB_WRITE_LOGIN:-$login}"
actor="${STUB_EVENT_ACTOR:-$login}"

if [ "${1:-}" = auth ] && [ "${2:-}" = switch ]; then
  echo "gh auth switch must not be called" >&2
  exit 90
fi
if [ "${1:-}" = auth ] && [ "${2:-}" = token ]; then
  [ -n "${STUB_NO_KEYRING:-}" ] && exit 1
  user=""
  shift 2
  while [ "$#" -gt 0 ]; do
    [ "$1" = "--user" ] && { user="${2:-}"; break; }
    shift
  done
  case "$user" in
    nathanjohnpayne) echo gho_fallback-author-token ;;
    nathanpayne-claude) echo gho_fallback-claude-token ;;
    nathanpayne-codex) echo gho_fallback-codex-token ;;
    *) exit 3 ;;
  esac
  exit 0
fi
# `gh api --help`: STUB_NO_SLURP models a gh older than 2.48.
if [ "${1:-}" = api ] && [ "${2:-}" = --help ]; then
  echo "  --paginate   Make additional HTTP requests to fetch all pages of results"
  [ -n "${STUB_NO_SLURP:-}" ] || echo "  --slurp      Use with \"--paginate\" to return an array of all pages"
  exit 0
fi
if [ "${1:-}" = api ] && [ "${2:-}" = user ]; then
  [ -n "$login" ] || exit 4
  echo "$login"
  exit 0
fi

# Not `gh api`: the gh transport ran the wrapped command. Record and succeed.
if [ "${1:-}" != api ]; then
  case "${1:-} ${2:-}" in
    "pr create"|"pr new") echo "${GH_CREATE_PR_URL:-https://github.com/o/r/pull/42}" ;;
    "pr view") echo "${GH_VIEW_AUTHOR:-nathanjohnpayne}" ;;
  esac
  exit "${GH_GENERIC_RC:-0}"
fi

shift
method=GET
endpoint=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --method|-X) method="$2"; shift 2 ;;
    --input|--jq|--hostname|-f|-F|-H|--header) shift 2 ;;
    -*) shift ;;
    *) endpoint="$1"; shift ;;
  esac
done
REPO="${STUB_REPO:-o/r}"
events_file="$STATE/events.json"
[ -f "$events_file" ] || echo '[]' >"$events_file"

add_event() { # <event> <extra json object>
  local n who
  for who in "$actor" "${STUB_DUPLICATE_ACTOR:-}"; do
    [ -n "$who" ] || continue
    n="$(jq 'length' "$events_file")"
    jq --arg ev "$1" --argjson extra "$2" --arg who "$who" --argjson id "$((1000 + n))" \
      '. + [($extra + {event: $ev, id: $id, actor: {login: $who}})]' "$events_file" >"$events_file.tmp" \
      && mv "$events_file.tmp" "$events_file"
  done
}
number_of() { printf '%s' "$1" | sed -E 's#^repos/[^/]+/[^/]+/(pulls|issues)/([0-9]+).*#\2#'; }
url_of() { printf 'https://github.com/%s/pull/%s' "$REPO" "$1"; }

case "$method $endpoint" in
  "GET repos/$REPO")
    jq -n --arg r "$REPO" '{full_name: $r, default_branch: "main"}' ;;
  "GET repos/$REPO/pulls/"*)
    [ -z "${STUB_PR_MISSING:-}" ] || { echo "gh: Not Found (HTTP 404)" >&2; exit 1; }
    num="$(number_of "$endpoint")"
    jq -n --arg num "$num" --arg url "$(url_of "$num")" --arg title "${STUB_PR_TITLE:-Old title}" \
      --arg body "${STUB_PR_BODY:-old body}" --arg base "${STUB_PR_BASE:-main}" \
      --arg labels "${STUB_PR_LABELS:-}" --arg reviewers "${STUB_PR_REVIEWERS:-}" --arg assignees "${STUB_PR_ASSIGNEES:-}" \
      --arg state "${STUB_PR_STATE:-open}" --arg href "${STUB_PR_HEAD_REF:-feature}" --arg hrepo "${STUB_PR_HEAD_REPO:-$REPO}" \
      --arg author "${STUB_PR_AUTHOR:-$write_login}" --arg merged "${STUB_PR_MERGED:-false}" '
      {number: ($num | tonumber), html_url: $url, state: $state, merged: ($merged == "true"), title: $title, body: $body,
       user: {login: $author}, base: {ref: $base}, head: {ref: $href, repo: {full_name: $hrepo}},
       labels: ($labels | split(",") | map(select(length > 0)) | map({name: .})),
       requested_reviewers: ($reviewers | split(",") | map(select(length > 0)) | map({login: .})),
       assignees: ($assignees | split(",") | map(select(length > 0)) | map({login: .}))}' ;;
  "GET repos/$REPO/issues/"*"/events?per_page=100")
    [ -z "${STUB_EVENTS_FAIL:-}" ] || { echo "gh: HTTP 502" >&2; exit 1; }
    reads=$(( $(cat "$STATE/event-reads" 2>/dev/null || echo 0) + 1 ))
    echo "$reads" >"$STATE/event-reads"
    # STUB_EVENTS_HIDE_READS=N: the first N reads do not yet show the events
    # the writes produced, as GitHub may record an event after the write.
    if [ "$reads" -le "${STUB_EVENTS_HIDE_READS:-0}" ]; then
      jq -n --argjson before "${STUB_EVENTS_BEFORE:-[]}" '[$before]'
    else
      jq -n --argjson before "${STUB_EVENTS_BEFORE:-[]}" --slurpfile ev "$events_file" '[$before + $ev[0]]'
    fi ;;
  "POST repos/$REPO/pulls")
    [ -z "${STUB_CREATE_FAIL:-}" ] || { echo "gh: Validation Failed (HTTP 422)" >&2; exit 1; }
    jq -n --arg url "$(url_of 42)" --arg login "$write_login" '{number: 42, html_url: $url, user: {login: $login}}' ;;
  "POST repos/$REPO/issues")
    [ -z "${STUB_CREATE_FAIL:-}" ] || { echo 'gh: Validation Failed (HTTP 422)' >&2; exit 1; }
    jq -n --argjson payload "$input" --arg login "$write_login" --arg repo "$REPO" '
      $payload + {number:42,html_url:("https://github.com/"+$repo+"/issues/42"),user:{login:$login},
        labels:($payload.labels|map({name:.})),assignees:($payload.assignees|map({login:.}))}' >"$STATE/created-issue.json"
    if [ -n "${STUB_ISSUE_BAD_RESPONSE:-}" ]; then printf '{}\n'; else cat "$STATE/created-issue.json"; fi ;;
  "GET repos/$REPO/issues/42")
    [ -z "${STUB_ISSUE_READBACK_FAIL:-}" ] || { echo 'gh: HTTP 502' >&2; exit 1; }
    jq --arg who "${STUB_ISSUE_READBACK_LOGIN:-$write_login}" --arg drop "${STUB_ISSUE_DROP_LABELS:-}" \
      --arg upper "${STUB_ISSUE_METADATA_UPCASE:-}" --arg assignee "${STUB_ISSUE_READBACK_ASSIGNEE:-}" '
      .user.login=$who
      | (if $drop == "" then . else .labels=[] end)
      | (if $upper == "" then . else .labels |= map(.name |= ascii_upcase)
         | .assignees |= map(.login |= ascii_upcase) end)
      | if $assignee == "" then . else .assignees=[{login:$assignee}] end' "$STATE/created-issue.json" ;;
  "POST repos/$REPO/issues/"*"/comments")
    [ -z "${STUB_COMMENT_FAIL:-}" ] || { echo "gh: Forbidden (HTTP 403)" >&2; exit 1; }
    num="$(number_of "$endpoint")"
    jq -n --arg url "$(url_of "$num")#issuecomment-900" --arg login "$write_login" '{id: 900, html_url: $url, user: {login: $login}}' ;;
  "POST repos/$REPO/pulls/"*"/reviews")
    num="$(number_of "$endpoint")"
    jq -n --arg url "$(url_of "$num")#pullrequestreview-77" --arg login "$write_login" --arg ev "$(printf '%s' "$input" | jq -r '.event')" \
      '{id: 77, html_url: $url, user: {login: $login}, state: (if $ev == "APPROVE" then "APPROVED" elif $ev == "REQUEST_CHANGES" then "CHANGES_REQUESTED" else "COMMENTED" end)}' ;;
  "PATCH repos/$REPO/pulls/"*)
    [ -z "${STUB_PATCH_FAIL:-}" ] || { echo "gh: Validation Failed (HTTP 422)" >&2; exit 1; }
    t="$(printf '%s' "$input" | jq -r '.title // empty')"
    [ -z "$t" ] || add_event renamed "$(jq -n --arg t "$t" '{rename: {from: "Old title", to: $t}}')"
    b="$(printf '%s' "$input" | jq -r '.base // empty')"
    [ -z "$b" ] || add_event base_ref_changed '{}'
    s="$(printf '%s' "$input" | jq -r '.state // empty')"
    [ "$s" != "closed" ] || add_event closed '{}'
    echo '{"ok": true}' ;;
  "POST repos/$REPO/issues/"*"/labels")
    printf '%s' "$input" | jq -r '.labels[]' | while IFS= read -r l; do
      # STUB_LABEL_UPCASE: the repository's label is spelled in upper case,
      # and GitHub records the event under its own spelling.
      [ -z "${STUB_LABEL_UPCASE:-}" ] || l="$(printf '%s' "$l" | tr '[:lower:]' '[:upper:]')"
      add_event labeled "$(jq -n --arg l "$l" '{label: {name: $l}}')"
    done
    echo '[]' ;;
  "DELETE repos/$REPO/issues/"*"/labels/"*)
    name="${endpoint##*/labels/}"
    # shellcheck disable=SC2059  # %XX escapes become \xXX for printf %b
    decoded="$(printf '%b' "$(printf '%s' "$name" | sed 's/%/\\x/g')")"
    add_event unlabeled "$(jq -n --arg l "$decoded" '{label: {name: $l}}')"
    echo '[]' ;;
  "POST repos/$REPO/pulls/"*"/requested_reviewers")
    [ -z "${STUB_REVIEWERS_FAIL:-}" ] || { echo "gh: Reviews may only be requested from collaborators (HTTP 422)" >&2; exit 1; }
    printf '%s' "$input" | jq -r '.reviewers[]' | while IFS= read -r u; do
      add_event review_requested "$(jq -n --arg u "$u" '{requested_reviewer: {login: $u}}')"
    done
    echo '{}' ;;
  "DELETE repos/$REPO/pulls/"*"/requested_reviewers")
    printf '%s' "$input" | jq -r '.reviewers[]' | while IFS= read -r u; do
      add_event review_request_removed "$(jq -n --arg u "$u" '{requested_reviewer: {login: $u}}')"
    done
    echo '{}' ;;
  "POST repos/$REPO/issues/"*"/assignees")
    printf '%s' "$input" | jq -r '.assignees[]' | while IFS= read -r u; do
      add_event assigned "$(jq -n --arg u "$u" '{assignee: {login: $u}}')"
    done
    echo '{}' ;;
  "DELETE repos/$REPO/issues/"*"/assignees")
    printf '%s' "$input" | jq -r '.assignees[]' | while IFS= read -r u; do
      add_event unassigned "$(jq -n --arg u "$u" '{assignee: {login: $u}}')"
    done
    echo '{}' ;;
  "DELETE repos/$REPO/git/refs/heads/"*)
    [ -z "${STUB_DELETE_REF_FAIL:-}" ] || { echo "gh: Unprocessable (HTTP 422)" >&2; exit 1; }
    # GitHub records head_ref_deleted on the pull request; STUB_REF_EVENT_ACTOR
    # attributes it to another login, STUB_NO_REF_EVENT records none.
    if [ -z "${STUB_NO_REF_EVENT:-}" ]; then
      actor="${STUB_REF_EVENT_ACTOR:-$actor}"
      add_event head_ref_deleted '{}'
    fi
    exit 0 ;;
  *)
    echo "stub gh: unhandled $method $endpoint" >&2
    exit "${GH_GENERIC_RC:-1}" ;;
esac
exit 0
STUB
chmod +x "$STUB_DIR/gh"

ALT_DIR="$WORKDIR/alt-bin"
mkdir -p "$ALT_DIR"
# shellcheck disable=SC2016  # the $-expressions belong to the generated stub
printf '#!/usr/bin/env bash\necho ALT-GH-USED >>"${GH_CALLS_LOG:-/dev/null}"\nexec %q "$@"\n' "$STUB_DIR/gh" >"$ALT_DIR/gh"
chmod +x "$ALT_DIR/gh"
LOGF="$WORKDIR/calls.log"
STATE="$WORKDIR/state"
new_case() { : >"$LOGF"; rm -rf "$STATE"; mkdir -p "$STATE"; }
# A zero readback delay keeps the retry cases fast; the attempt count is the
# production default unless a case sets it. Every call runs from a directory
# that is not a git repository unless a case names its fixture repository in
# RUN_CWD, so the transport's local git steps (head resolution, local branch
# deletion) can never act on the checkout running this suite.
NOGIT="$WORKDIR/nogit"
mkdir -p "$NOGIT"
as_author() {
  ( cd "${RUN_CWD:-$NOGIT}" && PATH="$STUB_DIR:$PATH" GH_CALLS_LOG="$LOGF" STUB_STATE="$STATE" MERGEPATH_GH_READBACK_DELAY="${MERGEPATH_GH_READBACK_DELAY:-0}" \
    OP_PREFLIGHT_AUTHOR_PAT="${OP_PREFLIGHT_AUTHOR_PAT:-ghp_author-token}" bash "$AUTHOR" "$@" )
}
as_reviewer() {
  ( cd "${RUN_CWD:-$NOGIT}" && PATH="$STUB_DIR:$PATH" GH_CALLS_LOG="$LOGF" STUB_STATE="$STATE" MERGEPATH_GH_READBACK_DELAY="${MERGEPATH_GH_READBACK_DELAY:-0}" \
    OP_PREFLIGHT_REVIEWER_PAT="${OP_PREFLIGHT_REVIEWER_PAT:-ghp_reviewer-token}" bash "$REVIEWER" "$@" )
}
event_reads() { cat "$STATE/event-reads" 2>/dev/null || echo 0; }
log_has() { grep -qF -- "$1" "$LOGF"; }
log_lacks() { ! grep -qF -- "$1" "$LOGF"; }
# Every api call under the REST transport carries the verified token alone.
log_token_clean() { # <token>; the identity check's `api user` runs before the transport, outside its environment
  ! grep -F $'gh\tapi' "$LOGF" | grep -v -F $'gh\tapi\tuser' | grep -v -F "GH_TOKEN=$1 GITHUB_TOKEN= ENT=mergepath-guarded-write-github-com-only|mergepath-guarded-write-github-com-only gh" | grep -q .
}

VALID_BODY="$WORKDIR/valid-body.md"
printf '%s\n' 'Authoring-Agent: codex' '' '## Self-Review' '' '- Correctness: verified.' >"$VALID_BODY"
INVALID_BODY="$WORKDIR/invalid-body.md"
printf '%s\n' 'no agent line here' >"$INVALID_BODY"
COMMENT_FILE="$WORKDIR/comment.md"
printf '%s\n' 'line one' 'line two' >"$COMMENT_FILE"

# ---------------------------------------------------------------------------
# gh_transport_select
# ---------------------------------------------------------------------------
select_is() { # <expected> <env assignments...>
  local expected="$1" got rc=0
  shift
  # shellcheck disable=SC2016  # $1 is expanded by the inner bash
  got="$(env -u CLAUDE_CODE_REMOTE -u MERGEPATH_AGENT_SURFACE -u MERGEPATH_GH_TRANSPORT "$@" bash -c '. "$1"; gh_transport_select' _ "$LIB" 2>/dev/null)" || rc=$?
  if [ "$expected" = "refused" ]; then
    if [ "$rc" -ne 0 ] && [ -z "$got" ]; then
      pass "transport select: $* -> refused"
    else
      fail "transport select: $* -> rc=$rc got=$got, expected refusal"
    fi
  elif [ "$rc" -eq 0 ] && [ "$got" = "$expected" ]; then
    pass "transport select: ${*:-(no env)} -> $expected"
  else
    fail "transport select: ${*:-(no env)} -> rc=$rc got=$got, expected $expected"
  fi
}
select_is gh
select_is rest CLAUDE_CODE_REMOTE=true
select_is rest MERGEPATH_AGENT_SURFACE=claude-cloud
select_is rest MERGEPATH_AGENT_SURFACE=codex-cloud
select_is gh MERGEPATH_AGENT_SURFACE=local CLAUDE_CODE_REMOTE=true
select_is gh MERGEPATH_AGENT_SURFACE=ci
select_is gh MERGEPATH_GH_TRANSPORT=gh CLAUDE_CODE_REMOTE=true
select_is rest MERGEPATH_GH_TRANSPORT=rest
select_is refused MERGEPATH_GH_TRANSPORT=graphql
select_is refused MERGEPATH_AGENT_SURFACE=somewhere

# ---------------------------------------------------------------------------
# Transport through the wrappers
# ---------------------------------------------------------------------------
new_case
set +e
out="$(as_reviewer -- gh pr comment 123 --repo o/r --body hi 2>/dev/null)"; rc=$?
set -e
if [ "$rc" -eq 0 ] && log_has $'gh\tpr\tcomment\t123' && log_lacks $'api\t--method'; then
  pass "local session: the wrapped gh command runs, no REST call"
else
  fail "local session: rc=$rc"; cat "$LOGF" >&2
fi

new_case
set +e
out="$(CLAUDE_CODE_REMOTE=true as_reviewer -- gh pr comment 123 --repo o/r --body hi 2>"$WORKDIR/err")"; rc=$?
set -e
if [ "$rc" -eq 0 ] && [ "$out" = "https://github.com/o/r/pull/123#issuecomment-900" ] \
   && log_has $'gh\tapi\trepos/o/r/pulls/123' \
   && log_has $'gh\tapi\t--method\tPOST\trepos/o/r/issues/123/comments\t--input\t'"$(printf '%s' '{"body":"hi"}')" \
   && log_lacks $'gh\tpr\tcomment' && log_token_clean ghp_reviewer-token \
   && grep -q 'verified comment https://github.com/o/r/pull/123#issuecomment-900 author=nathanpayne-claude' "$WORKDIR/err"; then
  pass "Claude cloud: pr comment runs as a REST POST under the verified token, reads the byline back, prints gh's URL"
else
  fail "Claude cloud pr comment: rc=$rc out=$out"; cat "$LOGF" "$WORKDIR/err" >&2
fi

new_case
set +e
out="$(MERGEPATH_AGENT_SURFACE=codex-cloud MERGEPATH_AGENT=codex OP_PREFLIGHT_REVIEWER_PAT=ghp_codex-token as_reviewer -- gh issue comment 7 --repo o/r --body-file "$COMMENT_FILE" 2>/dev/null)"; rc=$?
set -e
if [ "$rc" -eq 0 ] && [ "$out" = "https://github.com/o/r/pull/7#issuecomment-900" ] \
   && log_has $'POST\trepos/o/r/issues/7/comments\t--input\t'"$(printf '%s' '{"body":"line one\nline two\n"}')" \
   && log_lacks 'repos/o/r/pulls/7' && log_token_clean ghp_codex-token; then
  pass "Codex cloud: issue comment runs as REST from --body-file (byte-exact, trailing newline kept), as nathanpayne-codex, with no PR read"
else
  fail "Codex cloud issue comment: rc=$rc out=$out"; cat "$LOGF" >&2
fi

new_case
set +e
MERGEPATH_GH_TRANSPORT=rest as_author -- gh pr comment 5 --repo=o/r --body 'review status' >/dev/null 2>&1; rc=$?
set -e
if [ "$rc" -eq 0 ] && log_has $'POST\trepos/o/r/issues/5/comments\t--input\t'"$(printf '%s' '{"body":"review status"}')" && log_token_clean ghp_author-token; then
  pass "forced REST locally: the author's status comment posts with --repo=OWNER/REPO attached"
else
  fail "forced REST author comment: rc=$rc"; cat "$LOGF" >&2
fi

new_case
set +e
err="$(MERGEPATH_GH_TRANSPORT=graphql as_reviewer -- gh pr comment 5 --repo o/r --body x 2>&1 >/dev/null)"; rc=$?
set -e
if [ "$rc" -eq 1 ] && grep -q 'MERGEPATH_GH_TRANSPORT must be auto, gh or rest' <<<"$err" && log_lacks $'pr\tcomment' && log_lacks 'POST'; then
  pass "unknown transport value: refused, nothing written"
else
  fail "unknown transport: rc=$rc err=$err"
fi

# ---------------------------------------------------------------------------
# Closed grammar: comment
# ---------------------------------------------------------------------------
refused_rest() { # <label> <wrapper fn> <args...>; expects rc 1, the form in the message, and no write
  local label="$1" fn="$2" rc=0 err
  shift 2
  new_case
  set +e
  err="$(MERGEPATH_GH_TRANSPORT=rest "$fn" -- "$@" 2>&1 >/dev/null)"; rc=$?
  set -e
  if [ "$rc" -eq 1 ] && grep -qE 'the REST transport accepts exactly|comment-trigger-guard:' <<<"$err" && log_lacks $'--method\tPOST' && log_lacks $'--method\tPATCH' && log_lacks $'--method\tDELETE'; then
    pass "refused before any write: $label"
  else
    fail "$label: rc=$rc err=$err"; cat "$LOGF" >&2
  fi
}
refused_rest "comment without a body" as_reviewer gh pr comment 1 --repo o/r
refused_rest "comment without --repo" as_reviewer gh pr comment 1 --body x
refused_rest "comment by URL" as_reviewer gh pr comment https://github.com/o/r/pull/1 --repo o/r --body x
refused_rest "comment by branch" as_reviewer gh pr comment feature --repo o/r --body x
refused_rest "comment with a short option" as_reviewer gh pr comment 1 -R o/r --body x
refused_rest "comment --edit-last" as_reviewer gh pr comment 1 --repo o/r --body x --edit-last
refused_rest "comment --body-file -" as_reviewer gh pr comment 1 --repo o/r --body-file -
refused_rest "comment with two bodies" as_reviewer gh pr comment 1 --repo o/r --body x --body-file "$COMMENT_FILE"
refused_rest "comment with a missing body file" as_reviewer gh pr comment 1 --repo o/r --body-file "$WORKDIR/absent.md"
refused_rest "options before the verb" as_reviewer gh pr --repo o/r comment 1 --body x
refused_rest "a pr verb the transport does not run (view)" as_reviewer gh pr view 1 --repo o/r
refused_rest "a pr verb the transport does not run (ready)" as_author gh pr ready 1 --repo o/r
refused_rest "an issue verb the transport does not run (close)" as_author gh issue close 1 --repo o/r

new_case
set +e
err="$(MERGEPATH_GH_TRANSPORT=rest STUB_WRITE_LOGIN='claude[bot]' as_reviewer -- gh pr comment 123 --repo o/r --body hi 2>&1 >/dev/null)"; rc=$?
set -e
if [ "$rc" -eq 5 ] && grep -q "landed under 'claude\[bot\]', expected 'nathanpayne-claude'" <<<"$err" && grep -q '#241' <<<"$err"; then
  pass "comment readback: a bot byline exits 5 with the #241 recovery"
else
  fail "comment readback mutation: rc=$rc err=$err"
fi

new_case
set +e
err="$(MERGEPATH_GH_TRANSPORT=rest STUB_PR_MISSING=1 as_reviewer -- gh pr comment 404 --repo o/r --body hi 2>&1 >/dev/null)"; rc=$?
set -e
if [ "$rc" -eq 1 ] && grep -q 'could not read pull request o/r#404' <<<"$err" && log_lacks 'POST'; then
  pass "pr comment on a missing PR: refused before the write"
else
  fail "pr comment missing PR: rc=$rc err=$err"
fi

new_case
set +e
err="$(MERGEPATH_GH_TRANSPORT=rest STUB_COMMENT_FAIL=1 as_reviewer -- gh pr comment 1 --repo o/r --body hi 2>&1 >/dev/null)"; rc=$?
set -e
if [ "$rc" -eq 1 ] && grep -q 'HTTP 403' <<<"$err"; then
  pass "comment POST failure: gh's error and exit status propagate"
else
  fail "comment POST failure: rc=$rc err=$err"
fi

# ---------------------------------------------------------------------------
# review
# ---------------------------------------------------------------------------
new_case
set +e
out="$(MERGEPATH_GH_TRANSPORT=rest as_reviewer -- gh pr review 9 --repo o/r --approve 2>"$WORKDIR/err")"; rc=$?
set -e
if [ "$rc" -eq 0 ] && [ -z "$out" ] && log_has $'POST\trepos/o/r/pulls/9/reviews\t--input\t'"$(printf '%s' '{"event":"APPROVE"}')" \
   && grep -q 'verified review https://github.com/o/r/pull/9#pullrequestreview-77 (APPROVED) author=nathanpayne-claude' "$WORKDIR/err"; then
  pass "review --approve: POST with the APPROVE event, no body, nothing on stdout (gh parity), byline verified"
else
  fail "review approve: rc=$rc out=$out"; cat "$LOGF" "$WORKDIR/err" >&2
fi

new_case
set +e
MERGEPATH_GH_TRANSPORT=rest as_reviewer -- gh pr review 9 --repo o/r --request-changes --body-file "$COMMENT_FILE" >/dev/null 2>&1; rc=$?
set -e
if [ "$rc" -eq 0 ] && log_has $'POST\trepos/o/r/pulls/9/reviews\t--input\t'"$(printf '%s' '{"event":"REQUEST_CHANGES","body":"line one\nline two\n"}')"; then
  pass "review --request-changes: POST with the event and the body file"
else
  fail "review request-changes: rc=$rc"; cat "$LOGF" >&2
fi

refused_rest "review --comment without a body" as_reviewer gh pr review 9 --repo o/r --comment
refused_rest "review with two events" as_reviewer gh pr review 9 --repo o/r --approve --comment --body x
refused_rest "review with no event" as_reviewer gh pr review 9 --repo o/r --body x
refused_rest "review --approve=yes" as_reviewer gh pr review 9 --repo o/r --approve=yes

new_case
set +e
err="$(MERGEPATH_GH_TRANSPORT=rest STUB_WRITE_LOGIN='claude[bot]' as_reviewer -- gh pr review 9 --repo o/r --approve 2>&1 >/dev/null)"; rc=$?
set -e
if [ "$rc" -eq 5 ] && grep -q "review https://github.com/o/r/pull/9#pullrequestreview-77 landed under 'claude\[bot\]'" <<<"$err"; then
  pass "review readback: a bot byline exits 5"
else
  fail "review readback mutation: rc=$rc err=$err"
fi

# ---------------------------------------------------------------------------
# create
# ---------------------------------------------------------------------------
new_case
set +e
out="$(MERGEPATH_GH_TRANSPORT=rest as_author -- gh pr create --repo o/r --title 'T' --body-file "$VALID_BODY" --head feature/x --base main --draft --label a --label 'b c,d' --reviewer nathanpayne-codex --assignee nathanjohnpayne 2>"$WORKDIR/err")"; rc=$?
set -e
# Byte-exact, trailing newline included, as gh --body-file sends it.
expected_body="$(cat "$VALID_BODY"; printf x)"
expected_body="${expected_body%x}"
create_input="$(jq -nc --arg body "$expected_body" '{title: "T", body: $body, head: "feature/x", base: "main", draft: true}')"
if [ "$rc" -eq 0 ] && [ "$out" = "https://github.com/o/r/pull/42" ] \
   && log_has $'POST\trepos/o/r/pulls\t--input\t'"$create_input" \
   && log_has $'gh\tapi\trepos/o/r/pulls/42' \
   && log_has $'POST\trepos/o/r/issues/42/labels\t--input\t'"$(printf '%s' '{"labels":["a","b c","d"]}')" \
   && log_has $'POST\trepos/o/r/pulls/42/requested_reviewers\t--input\t'"$(printf '%s' '{"reviewers":["nathanpayne-codex"]}')" \
   && log_has $'POST\trepos/o/r/issues/42/assignees\t--input\t'"$(printf '%s' '{"assignees":["nathanjohnpayne"]}')" \
   && log_has 'repos/o/r/issues/42/events?per_page=100' \
   && log_lacks $'gh\tpr\tcreate' && log_lacks 'repos/o/r'$'\t' && log_token_clean ghp_author-token \
   && grep -q 'verified PR #42 author=nathanjohnpayne (matches expected nathanjohnpayne)' "$WORKDIR/err" \
   && grep -q "verified on PR #42 by nathanjohnpayne: labeled:a, labeled:b c, labeled:d, review_requested:nathanpayne-codex, assigned:nathanjohnpayne" "$WORKDIR/err"; then
  pass "pr create: REST POST with the validated body, the #241 re-read, labels/reviewers/assignees as follow-ups attributed through events, gh's URL on stdout"
else
  fail "pr create: rc=$rc out=$out"; cat "$LOGF" "$WORKDIR/err" >&2
fi

# --base defaults to the repository's default branch; --head to the checked-out branch.
GITREPO="$WORKDIR/gitrepo"
mkdir -p "$GITREPO"
( cd "$GITREPO" && git init -q && git checkout -q -b topic/z 2>/dev/null \
  && git -c user.name=t -c user.email=t@example.invalid -c commit.gpgsign=false commit -q --allow-empty --no-gpg-sign -m init \
  && git remote add origin https://github.com/o/r.git && git config branch.topic/z.remote origin \
  && git config branch.topic/z.merge refs/heads/topic/z && git config push.default current \
  && git update-ref refs/remotes/origin/topic/z HEAD )
new_case
set +e
out="$(RUN_CWD="$GITREPO" MERGEPATH_GH_TRANSPORT=rest as_author -- gh pr create --repo o/r --title T --body-file "$VALID_BODY" 2>/dev/null)"; rc=$?
set -e
create_input="$(jq -nc --arg body "$expected_body" '{title: "T", body: $body, head: "topic/z", base: "main", draft: false}')"
if [ "$rc" -eq 0 ] && grep -q $'\tapi\trepos/o/r$' "$LOGF" && log_has $'POST\trepos/o/r/pulls\t--input\t'"$create_input" && log_lacks 'events?per_page'; then
  pass "pr create defaults: --head from the checked-out branch pushed to --repo, --base from GET repos, no event read without follow-ups"
else
  fail "pr create defaults: rc=$rc"; cat "$LOGF" >&2
fi

# gh's order for an omitted --base: the branch's gh-merge-base, then the
# repository default.
git -C "$GITREPO" config branch.topic/z.gh-merge-base release/2
new_case
set +e
RUN_CWD="$GITREPO" MERGEPATH_GH_TRANSPORT=rest as_author -- gh pr create --repo o/r --title T --body-file "$VALID_BODY" >/dev/null 2>&1; rc=$?
set -e
create_input="$(jq -nc --arg body "$expected_body" '{title: "T", body: $body, head: "topic/z", base: "release/2", draft: false}')"
if [ "$rc" -eq 0 ] && log_has $'POST\trepos/o/r/pulls\t--input\t'"$create_input" && ! grep -q $'\tapi\trepos/o/r$' "$LOGF"; then
  pass "pr create: an omitted --base takes the branch's gh-merge-base before the repository default"
else
  fail "pr create gh-merge-base: rc=$rc"; cat "$LOGF" >&2
fi
git -C "$GITREPO" config --unset branch.topic/z.gh-merge-base

# An omitted --head is qualified owner:branch when the branch is pushed to a
# fork, kept bare for the session proxy's remote of --repo itself, and
# refused when the branch has no push remote.
git -C "$GITREPO" remote add fork git@github.com:forker/r.git
git -C "$GITREPO" config branch.topic/z.pushRemote fork
git -C "$GITREPO" update-ref refs/remotes/fork/topic/z HEAD
new_case
set +e
RUN_CWD="$GITREPO" MERGEPATH_GH_TRANSPORT=rest as_author -- gh pr create --repo o/r --base main --title T --body-file "$VALID_BODY" >/dev/null 2>&1; rc=$?
set -e
create_input="$(jq -nc --arg body "$expected_body" '{title: "T", body: $body, head: "forker:topic/z", base: "main", draft: false}')"
if [ "$rc" -eq 0 ] && log_has $'POST\trepos/o/r/pulls\t--input\t'"$create_input"; then
  pass "pr create: a branch pushed to a fork gets the owner-qualified head"
else
  fail "pr create fork head: rc=$rc"; cat "$LOGF" >&2
fi
# A fork with the same owner as --repo makes owner:branch ambiguous, so
# GitHub requires head_repo naming the fork.
git -C "$GITREPO" remote add samefork https://github.com/o/r-fork.git
git -C "$GITREPO" config branch.topic/z.pushRemote samefork
git -C "$GITREPO" update-ref refs/remotes/samefork/topic/z HEAD
new_case
set +e
RUN_CWD="$GITREPO" MERGEPATH_GH_TRANSPORT=rest as_author -- gh pr create --repo o/r --base main --title T --body-file "$VALID_BODY" >/dev/null 2>&1; rc=$?
set -e
create_input="$(jq -nc --arg body "$expected_body" '{title: "T", body: $body, head: "o:topic/z", base: "main", draft: false, head_repo: "r-fork"}')"
if [ "$rc" -eq 0 ] && log_has $'POST\trepos/o/r/pulls\t--input\t'"$create_input"; then
  pass "pr create: a branch pushed to a same-owner fork sends head_repo with the qualified head"
else
  fail "pr create same-owner fork: rc=$rc"; cat "$LOGF" >&2
fi
git -C "$GITREPO" config --unset branch.topic/z.pushRemote
git -C "$GITREPO" remote set-url origin http://local_proxy@127.0.0.1:9/git/O/R
new_case
set +e
RUN_CWD="$GITREPO" CLAUDE_CODE_REMOTE=true as_author -- gh pr create --repo o/r --base main --title T --body-file "$VALID_BODY" >/dev/null 2>&1; rc=$?
set -e
create_input="$(jq -nc --arg body "$expected_body" '{title: "T", body: $body, head: "topic/z", base: "main", draft: false}')"
if [ "$rc" -eq 0 ] && log_has $'POST\trepos/o/r/pulls\t--input\t'"$create_input"; then
  pass "pr create in a Claude cloud session: the git proxy's loopback remote ending in --repo (any case) keeps the bare head"
else
  fail "pr create proxy remote head: rc=$rc"; cat "$LOGF" >&2
fi
# Outside a Claude cloud session a loopback remote is just a local git
# server: it says nothing about GitHub, so the head is not inferred from it.
new_case
set +e
err="$(RUN_CWD="$GITREPO" MERGEPATH_GH_TRANSPORT=rest as_author -- gh pr create --repo o/r --base main --title T --body-file "$VALID_BODY" 2>&1 >/dev/null)"; rc=$?
set -e
if [ "$rc" -eq 1 ] && grep -q 'has no push remote on GitHub' <<<"$err" && log_lacks 'POST'; then
  pass "pr create outside Claude cloud: a loopback remote is refused, not taken for GitHub"
else
  fail "pr create local loopback: rc=$rc err=$err"; cat "$LOGF" >&2
fi
new_case
set +e
err="$(RUN_CWD="$GITREPO" CLAUDE_CODE_REMOTE=true MERGEPATH_AGENT_SURFACE=codex-cloud as_author -- gh pr create --repo o/r --base main --title T --body-file "$VALID_BODY" 2>&1 >/dev/null)"; rc=$?
set -e
if [ "$rc" -eq 1 ] && grep -q 'has no push remote on GitHub' <<<"$err"; then
  pass "pr create: the surface variable wins, so a Codex cloud surface does not accept a loopback remote"
else
  fail "pr create surface wins: rc=$rc err=$err"; cat "$LOGF" >&2
fi
git -C "$GITREPO" remote set-url origin https://gitlab.com/o/r.git
new_case
set +e
err="$(RUN_CWD="$GITREPO" MERGEPATH_GH_TRANSPORT=rest as_author -- gh pr create --repo o/r --base main --title T --body-file "$VALID_BODY" 2>&1 >/dev/null)"; rc=$?
set -e
if [ "$rc" -eq 1 ] && grep -q 'has no push remote on GitHub' <<<"$err" && log_lacks 'POST'; then
  pass "pr create: a push remote that is not on GitHub is refused, even when its path matches --repo"
else
  fail "pr create gitlab remote: rc=$rc err=$err"; cat "$LOGF" >&2
fi
git -C "$GITREPO" remote set-url origin https://github.com/o/r.git
git -C "$GITREPO" config --unset branch.topic/z.remote
new_case
set +e
err="$(RUN_CWD="$GITREPO" MERGEPATH_GH_TRANSPORT=rest as_author -- gh pr create --repo o/r --base main --title T --body-file "$VALID_BODY" 2>&1 >/dev/null)"; rc=$?
set -e
if [ "$rc" -eq 1 ] && grep -q 'branch topic/z has no push remote' <<<"$err" && log_lacks 'POST'; then
  pass "pr create: a branch with no push remote is refused, as gh refuses an unpushed branch"
else
  fail "pr create no push remote: rc=$rc err=$err"
fi
git -C "$GITREPO" config branch.topic/z.remote origin

# An inferred head must be fully pushed: a PR from a ref behind HEAD would
# leave out the latest commits, and gh asks to push first.
git -C "$GITREPO" -c user.name=t -c user.email=t@example.invalid -c commit.gpgsign=false commit -q --allow-empty --no-gpg-sign -m ahead
new_case
set +e
err="$(RUN_CWD="$GITREPO" MERGEPATH_GH_TRANSPORT=rest as_author -- gh pr create --repo o/r --base main --title T --body-file "$VALID_BODY" 2>&1 >/dev/null)"; rc=$?
set -e
if [ "$rc" -eq 1 ] && grep -q 'branch topic/z is not fully pushed: origin/topic/z differs from HEAD' <<<"$err" && log_lacks 'POST'; then
  pass "pr create: an inferred head behind the local HEAD is refused"
else
  fail "pr create not fully pushed: rc=$rc err=$err"; cat "$LOGF" >&2
fi
git -C "$GITREPO" update-ref -d refs/remotes/origin/topic/z
new_case
set +e
err="$(RUN_CWD="$GITREPO" MERGEPATH_GH_TRANSPORT=rest as_author -- gh pr create --repo o/r --base main --title T --body-file "$VALID_BODY" 2>&1 >/dev/null)"; rc=$?
set -e
if [ "$rc" -eq 1 ] && grep -q 'has no pushed ref on origin' <<<"$err" && log_lacks 'POST'; then
  pass "pr create: a branch never pushed to its push remote is refused"
else
  fail "pr create never pushed: rc=$rc err=$err"; cat "$LOGF" >&2
fi
git -C "$GITREPO" update-ref refs/remotes/origin/topic/z HEAD

# A body far larger than one argument may be reaches jq through a file.
BIG_BODY="$WORKDIR/big-body.md"
{ printf 'Authoring-Agent: codex\n\n## Self-Review\n\n- Correctness: verified.\n\n'; head -c 1200000 /dev/zero | tr '\0' 'x'; printf '\n'; } >"$BIG_BODY"
new_case
set +e
MERGEPATH_GH_TRANSPORT=rest as_reviewer -- gh pr comment 1 --repo o/r --body-file "$BIG_BODY" >/dev/null 2>"$WORKDIR/err"; rc=$?
set -e
if [ "$rc" -eq 0 ] && grep -F $'POST\trepos/o/r/issues/1/comments' "$LOGF" | grep -q 'xxxxxxxxxx'; then
  pass "a 1.2 MB comment body is posted (it never travels as a single argument)"
else
  fail "big comment body: rc=$rc"; head -c 600 "$WORKDIR/err" >&2
fi

new_case
set +e
err="$(MERGEPATH_GH_TRANSPORT=rest as_author -- gh pr create --repo o/r --title T --body-file "$INVALID_BODY" --head h 2>&1 >/dev/null)"; rc=$?
set -e
if [ "$rc" -eq 1 ] && grep -q 'Authoring-Agent' <<<"$err" && log_lacks 'POST'; then
  pass "pr create: the PR-body contract still refuses an invalid body before any REST call"
else
  fail "pr create invalid body: rc=$rc err=$err"
fi

refused_rest "create without --title" as_author gh pr create --repo o/r --body-file "$VALID_BODY" --head h
refused_rest "create without --repo" as_author gh pr create --title T --body-file "$VALID_BODY" --head h
refused_rest "create with a team reviewer" as_author gh pr create --repo o/r --title T --body-file "$VALID_BODY" --head h --reviewer org/team
refused_rest "create with an @me assignee" as_author gh pr create --repo o/r --title T --body-file "$VALID_BODY" --head h --assignee @me
refused_rest "create with --fill" as_author gh pr create --repo o/r --title T --body-file "$VALID_BODY" --head h --fill
refused_rest "create with a positional" as_author gh pr create 5 --repo o/r --title T --body-file "$VALID_BODY" --head h

new_case
set +e
out="$(MERGEPATH_GH_TRANSPORT=rest STUB_PR_AUTHOR='claude[bot]' as_author -- gh pr create --repo o/r --title T --body-file "$VALID_BODY" --head h 2>"$WORKDIR/err")"; rc=$?
set -e
if [ "$rc" -eq 5 ] && [ "$out" = "https://github.com/o/r/pull/42" ] && grep -q "PR #42 on o/r landed under 'claude\[bot\]', expected 'nathanjohnpayne'" "$WORKDIR/err" && grep -q '#241' "$WORKDIR/err"; then
  pass "pr create readback: the #241 re-read catches a bot author, exit 5, URL still printed for recovery"
else
  fail "pr create readback mutation: rc=$rc out=$out"; cat "$WORKDIR/err" >&2
fi

new_case
set +e
err="$(MERGEPATH_GH_TRANSPORT=rest STUB_EVENT_ACTOR='claude[bot]' as_author -- gh pr create --repo o/r --title T --body-file "$VALID_BODY" --head h --label a 2>&1 >/dev/null)"; rc=$?
set -e
if [ "$rc" -eq 5 ] && grep -q "the label 'a' landed under 'claude\[bot\]'" <<<"$err"; then
  pass "pr create follow-ups: a label applied by another login exits 5"
else
  fail "pr create label actor mutation: rc=$rc err=$err"
fi

new_case
set +e
err="$(MERGEPATH_GH_TRANSPORT=rest STUB_CREATE_FAIL=1 as_author -- gh pr create --repo o/r --title T --body-file "$VALID_BODY" --head h 2>&1 >/dev/null)"; rc=$?
set -e
if [ "$rc" -eq 1 ] && grep -q 'HTTP 422' <<<"$err" && log_lacks 'repos/o/r/pulls/42'; then
  pass "pr create POST failure: propagates, no readback attempted"
else
  fail "pr create POST failure: rc=$rc err=$err"
fi

# ---------------------------------------------------------------------------
# edit
# ---------------------------------------------------------------------------
new_case
set +e
out="$(MERGEPATH_GH_TRANSPORT=rest STUB_PR_LABELS='y,z' as_author -- gh pr edit 42 --repo o/r --add-label x --add-label z --remove-label y --remove-label absent 2>"$WORKDIR/err")"; rc=$?
set -e
if [ "$rc" -eq 0 ] && [ "$out" = "https://github.com/o/r/pull/42" ] \
   && log_has $'POST\trepos/o/r/issues/42/labels\t--input\t'"$(printf '%s' '{"labels":["x"]}')" \
   && log_has $'DELETE\trepos/o/r/issues/42/labels/y' && log_lacks 'labels/absent' \
   && [ "$(grep -c 'events?per_page=100' "$LOGF")" -eq 2 ] \
   && grep -q 'verified edit of PR #42 by nathanjohnpayne: labeled:x, unlabeled:y' "$WORKDIR/err"; then
  pass "pr edit labels: no-ops dropped (z present, absent not present), add and remove attributed through new events"
else
  fail "pr edit labels: rc=$rc out=$out"; cat "$LOGF" "$WORKDIR/err" >&2
fi

new_case
set +e
out="$(MERGEPATH_GH_TRANSPORT=rest STUB_PR_LABELS='z' as_author -- gh pr edit 42 --repo o/r --add-label z --title 'Old title' 2>"$WORKDIR/err")"; rc=$?
set -e
if [ "$rc" -eq 0 ] && [ "$out" = "https://github.com/o/r/pull/42" ] && log_lacks 'POST' && log_lacks 'PATCH' && grep -q 'no change' "$WORKDIR/err"; then
  pass "pr edit no-op: nothing written, URL printed"
else
  fail "pr edit no-op: rc=$rc"; cat "$LOGF" "$WORKDIR/err" >&2
fi

new_case
set +e
out="$(MERGEPATH_GH_TRANSPORT=rest as_author -- gh pr edit 42 --repo o/r --title 'New title' --base dev --body-file "$COMMENT_FILE" 2>"$WORKDIR/err")"; rc=$?
set -e
if [ "$rc" -eq 0 ] && log_has $'PATCH\trepos/o/r/pulls/42\t--input\t'"$(printf '%s' '{"title":"New title","body":"line one\nline two\n","base":"dev"}')" \
   && grep -q 'verified edit of PR #42 by nathanjohnpayne: title, base' "$WORKDIR/err" \
   && grep -q 'body edit of PR #42 is not attributable over REST' "$WORKDIR/err"; then
  pass "pr edit title/body/base: one PATCH; title and base attributed through events, the body edit reported as not attributable"
else
  fail "pr edit patch: rc=$rc"; cat "$LOGF" "$WORKDIR/err" >&2
fi

new_case
set +e
out="$(MERGEPATH_GH_TRANSPORT=rest STUB_PR_REVIEWERS='nathanpayne-codex' STUB_PR_ASSIGNEES='nathanjohnpayne' as_author -- gh pr edit 42 --repo o/r --add-reviewer nathanpayne-claude --remove-reviewer nathanpayne-codex --add-assignee nathanpayne-codex --remove-assignee nathanjohnpayne 2>"$WORKDIR/err")"; rc=$?
set -e
if [ "$rc" -eq 0 ] \
   && log_has $'POST\trepos/o/r/pulls/42/requested_reviewers\t--input\t'"$(printf '%s' '{"reviewers":["nathanpayne-claude"]}')" \
   && log_has $'DELETE\trepos/o/r/pulls/42/requested_reviewers\t--input\t'"$(printf '%s' '{"reviewers":["nathanpayne-codex"]}')" \
   && log_has $'POST\trepos/o/r/issues/42/assignees\t--input\t'"$(printf '%s' '{"assignees":["nathanpayne-codex"]}')" \
   && log_has $'DELETE\trepos/o/r/issues/42/assignees\t--input\t'"$(printf '%s' '{"assignees":["nathanjohnpayne"]}')" \
   && grep -q 'review_requested:nathanpayne-claude, review_request_removed:nathanpayne-codex, assigned:nathanpayne-codex, unassigned:nathanjohnpayne' "$WORKDIR/err"; then
  pass "pr edit reviewers and assignees: each change its own REST call, each attributed"
else
  fail "pr edit reviewers/assignees: rc=$rc"; cat "$LOGF" "$WORKDIR/err" >&2
fi

new_case
set +e
MERGEPATH_GH_TRANSPORT=rest STUB_PR_LABELS='b c' as_author -- gh pr edit 42 --repo o/r --remove-label 'b c' >/dev/null 2>"$WORKDIR/err"; rc=$?
set -e
if [ "$rc" -eq 0 ] && log_has $'DELETE\trepos/o/r/issues/42/labels/b%20c' && grep -q 'unlabeled:b c' "$WORKDIR/err"; then
  pass "pr edit: a label with a space is percent-encoded in the DELETE and attributed by its name"
else
  fail "pr edit label encoding: rc=$rc"; cat "$LOGF" "$WORKDIR/err" >&2
fi

new_case
set +e
err="$(MERGEPATH_GH_TRANSPORT=rest STUB_EVENT_ACTOR='claude[bot]' as_author -- gh pr edit 42 --repo o/r --add-label x 2>&1 >/dev/null)"; rc=$?
set -e
if [ "$rc" -eq 5 ] && grep -q "the label 'x' landed under 'claude\[bot\]', expected 'nathanjohnpayne'" <<<"$err"; then
  pass "pr edit readback: a label event by another login exits 5"
else
  fail "pr edit actor mutation: rc=$rc err=$err"
fi

new_case
set +e
err="$(MERGEPATH_GH_TRANSPORT=rest STUB_DUPLICATE_ACTOR='claude[bot]' as_author -- gh pr edit 42 --repo o/r --add-label x 2>&1 >/dev/null)"; rc=$?
set -e
if [ "$rc" -eq 5 ] && grep -q "the label 'x' landed under 'claude\[bot\],nathanjohnpayne'" <<<"$err"; then
  pass "pr edit readback: a concurrent bot event beside the expected one is not told apart; exits 5"
else
  fail "pr edit concurrent mutation: rc=$rc err=$err"
fi

new_case
set +e
err="$(MERGEPATH_GH_TRANSPORT=rest STUB_EVENTS_FAIL=1 as_author -- gh pr edit 42 --repo o/r --add-label x 2>&1 >/dev/null)"; rc=$?
set -e
if [ "$rc" -eq 5 ] && grep -q 'refusing a write that could not be attributed' <<<"$err" && log_lacks 'POST'; then
  pass "pr edit: an unreadable event log before the write refuses the write"
else
  fail "pr edit events pre-read failure: rc=$rc err=$err"; cat "$LOGF" >&2
fi

new_case
set +e
err="$(MERGEPATH_GH_TRANSPORT=rest STUB_PATCH_FAIL=1 as_author -- gh pr edit 42 --repo o/r --title New --add-label x 2>&1 >/dev/null)"; rc=$?
set -e
if [ "$rc" -eq 1 ] && grep -q 'later edits were not attempted' <<<"$err" && log_lacks $'POST\trepos/o/r/issues/42/labels'; then
  pass "pr edit: a failed PATCH stops before the later label write and says so"
else
  fail "pr edit PATCH failure: rc=$rc err=$err"; cat "$LOGF" >&2
fi

# GitHub may record an event a moment after the write: a missing event is
# re-read, an event by another login is not.
new_case
set +e
MERGEPATH_GH_TRANSPORT=rest STUB_EVENTS_HIDE_READS=2 as_author -- gh pr edit 42 --repo o/r --add-label x >/dev/null 2>"$WORKDIR/err"; rc=$?
set -e
if [ "$rc" -eq 0 ] && [ "$(event_reads)" -eq 3 ] && grep -q 'labeled:x' "$WORKDIR/err" && ! grep -q 'ERROR' "$WORKDIR/err"; then
  pass "edit readback: a lagging event is re-read and attributed, with no error printed for the early miss"
else
  fail "edit readback lag: rc=$rc reads=$(event_reads)"; cat "$WORKDIR/err" >&2
fi
new_case
set +e
err="$(MERGEPATH_GH_TRANSPORT=rest STUB_EVENTS_HIDE_READS=99 MERGEPATH_GH_READBACK_ATTEMPTS=3 as_author -- gh pr edit 42 --repo o/r --add-label x 2>&1 >/dev/null)"; rc=$?
set -e
if [ "$rc" -eq 5 ] && [ "$(event_reads)" -eq 4 ] && [ "$(printf '%s\n' "$err" | grep -c "no labeled event appeared")" -eq 1 ]; then
  pass "edit readback: an event that never appears is reported once, after the configured attempts, and exits 5"
else
  fail "edit readback never appears: rc=$rc reads=$(event_reads) err=$err"
fi
new_case
set +e
err="$(MERGEPATH_GH_TRANSPORT=rest STUB_EVENT_ACTOR='claude[bot]' as_author -- gh pr edit 42 --repo o/r --add-label x 2>&1 >/dev/null)"; rc=$?
set -e
if [ "$rc" -eq 5 ] && [ "$(event_reads)" -eq 2 ]; then
  pass "edit readback: an event by another login fails on the first read, with no retry"
else
  fail "edit readback wrong actor retry: rc=$rc reads=$(event_reads) err=$err"
fi
new_case
set +e
MERGEPATH_GH_TRANSPORT=rest STUB_EVENTS_HIDE_READS=1 as_author -- gh pr create --repo o/r --title T --body-file "$VALID_BODY" --head h --label a >/dev/null 2>"$WORKDIR/err"; rc=$?
set -e
if [ "$rc" -eq 0 ] && [ "$(event_reads)" -eq 2 ] && grep -q 'labeled:a' "$WORKDIR/err"; then
  pass "create readback: a lagging label event is re-read and attributed"
else
  fail "create readback lag: rc=$rc reads=$(event_reads)"; cat "$WORKDIR/err" >&2
fi
new_case
set +e
MERGEPATH_GH_TRANSPORT=rest STUB_EVENTS_HIDE_READS=2 as_author -- gh pr close 42 --repo o/r >/dev/null 2>"$WORKDIR/err"; rc=$?
set -e
if [ "$rc" -eq 0 ] && [ "$(event_reads)" -eq 3 ] && grep -q 'verified close of PR #42' "$WORKDIR/err"; then
  pass "close readback: a lagging closed event is re-read and attributed"
else
  fail "close readback lag: rc=$rc reads=$(event_reads)"; cat "$WORKDIR/err" >&2
fi
for bad in x 0 21; do
  new_case
  set +e
  MERGEPATH_GH_TRANSPORT=rest STUB_EVENTS_HIDE_READS=99 MERGEPATH_GH_READBACK_ATTEMPTS=$bad as_author -- gh pr edit 42 --repo o/r --add-label x >/dev/null 2>&1; rc=$?
  set -e
  if [ "$rc" -eq 5 ] && [ "$(event_reads)" -eq 6 ]; then
    pass "readback attempts '$bad' is out of range: the default of 5 applies"
  else
    fail "readback attempts '$bad': rc=$rc reads=$(event_reads)"
  fi
done

refused_rest "edit with nothing to edit" as_author gh pr edit 42 --repo o/r
refused_rest "edit --milestone" as_author gh pr edit 42 --repo o/r --milestone m
refused_rest "edit with an empty title" as_author gh pr edit 42 --repo o/r --title ''

# ---------------------------------------------------------------------------
# close
# ---------------------------------------------------------------------------
new_case
set +e
out="$(MERGEPATH_GH_TRANSPORT=rest as_author -- gh pr close 42 --repo o/r --comment bye --delete-branch 2>"$WORKDIR/err")"; rc=$?
set -e
if [ "$rc" -eq 0 ] && [ -z "$out" ] \
   && log_has $'POST\trepos/o/r/issues/42/comments\t--input\t'"$(printf '%s' '{"body":"bye"}')" \
   && log_has $'PATCH\trepos/o/r/pulls/42\t--input\t'"$(printf '%s' '{"state":"closed"}')" \
   && log_has $'DELETE\trepos/o/r/git/refs/heads/feature' \
   && grep -q 'verified close of PR #42 by nathanjohnpayne' "$WORKDIR/err" \
   && grep -q 'verified delete of branch feature on o/r by nathanjohnpayne' "$WORKDIR/err"; then
  pass "pr close: comment, PATCH closed attributed through the closed event, head ref delete attributed through head_ref_deleted"
else
  fail "pr close: rc=$rc out=$out"; cat "$LOGF" "$WORKDIR/err" >&2
fi

# The head-ref delete is attributed from its head_ref_deleted event: one by
# another login, or none at all, is unattributed (5) with the recovery text
# (Phase 4b on #2178).
new_case
set +e
err="$(MERGEPATH_GH_TRANSPORT=rest STUB_REF_EVENT_ACTOR='claude[bot]' as_author -- gh pr close 42 --repo o/r --delete-branch 2>&1 >/dev/null)"; rc=$?
set -e
if [ "$rc" -eq 5 ] && grep -q 'verified close of PR #42' <<<"$err" && grep -q 'restore branch feature' <<<"$err" && ! grep -q 'verified delete of branch' <<<"$err"; then
  pass "pr close --delete-branch: a head_ref_deleted event by another login exits 5"
else
  fail "pr close foreign ref delete: rc=$rc err=$err"; cat "$LOGF" >&2
fi
new_case
set +e
err="$(MERGEPATH_GH_TRANSPORT=rest STUB_NO_REF_EVENT=1 MERGEPATH_GH_READBACK_ATTEMPTS=2 as_author -- gh pr close 42 --repo o/r --delete-branch 2>&1 >/dev/null)"; rc=$?
set -e
if [ "$rc" -eq 5 ] && grep -q 'head_ref_deleted' <<<"$err" && grep -q 'restore branch feature' <<<"$err"; then
  pass "pr close --delete-branch: no head_ref_deleted event leaves the delete unattributed (5)"
else
  fail "pr close missing ref event: rc=$rc err=$err"; cat "$LOGF" >&2
fi
new_case
set +e
err="$(MERGEPATH_GH_TRANSPORT=rest STUB_EVENTS_FAIL=1 as_author -- gh pr close 42 --repo o/r --comment bye 2>&1 >/dev/null)"; rc=$?
set -e
if [ "$rc" -eq 5 ] && grep -q 'Nothing was written' <<<"$err" && log_lacks 'POST' && log_lacks 'PATCH'; then
  pass "pr close: an unreadable event log refuses before the closing comment is posted"
else
  fail "pr close events-first: rc=$rc err=$err"; cat "$LOGF" >&2
fi
new_case
set +e
err="$(MERGEPATH_GH_TRANSPORT=rest STUB_PATCH_FAIL=1 as_author -- gh pr close 42 --repo o/r --comment bye 2>&1 >/dev/null)"; rc=$?
set -e
if [ "$rc" -eq 1 ] && grep -q 'the closing comment was posted (https://github.com/o/r/pull/42#issuecomment-900), but closing PR #42 failed' <<<"$err"; then
  pass "pr close: a close that fails after the comment says the comment was posted"
else
  fail "pr close partial: rc=$rc err=$err"
fi
new_case
set +e
MERGEPATH_GH_TRANSPORT=rest STUB_PR_HEAD_REPO=O/R as_author -- gh pr close 42 --repo o/r --delete-branch >/dev/null 2>&1; rc=$?
set -e
if [ "$rc" -eq 0 ] && log_has $'DELETE\trepos/o/r/git/refs/heads/feature'; then
  pass "pr close --delete-branch: the head repository matches --repo case-insensitively"
else
  fail "pr close case-insensitive repo: rc=$rc"; cat "$LOGF" >&2
fi
new_case
set +e
err="$(MERGEPATH_GH_TRANSPORT=rest STUB_PR_STATE=closed as_author -- gh pr close 42 --repo o/r --comment bye --delete-branch 2>&1 >/dev/null)"; rc=$?
set -e
if [ "$rc" -eq 0 ] && grep -q 'already closed; nothing was written (no comment was posted and no branch was deleted' <<<"$err" \
   && log_lacks 'PATCH' && log_lacks 'issues/42/comments' && log_lacks 'git/refs' && log_lacks 'events?per_page'; then
  pass "pr close on an already-closed PR: succeeds as gh does, writing nothing (no comment, no branch delete) (#2207)"
else
  fail "pr close already closed: rc=$rc err=$err"; cat "$LOGF" >&2
fi
new_case
set +e
err="$(MERGEPATH_GH_TRANSPORT=rest STUB_PR_STATE=closed STUB_PR_MERGED=true as_author -- gh pr close 42 --repo o/r 2>&1 >/dev/null)"; rc=$?
set -e
if [ "$rc" -eq 1 ] && grep -q 'already merged; nothing was written' <<<"$err" && log_lacks 'PATCH'; then
  pass "pr close on a merged PR: still refused (1), nothing written (#2207)"
else
  fail "pr close merged: rc=$rc err=$err"; cat "$LOGF" >&2
fi

new_case
set +e
MERGEPATH_GH_TRANSPORT=rest STUB_PR_HEAD_REPO=fork/r as_author -- gh pr close 42 --repo o/r --delete-branch >/dev/null 2>"$WORKDIR/err"; rc=$?
set -e
if [ "$rc" -eq 0 ] && log_lacks 'git/refs' && grep -q 'head branch is on another repository (fork/r) and was not deleted' "$WORKDIR/err"; then
  pass "pr close --delete-branch on a fork head: the ref on the other repository is left alone"
else
  fail "pr close fork head: rc=$rc"; cat "$LOGF" "$WORKDIR/err" >&2
fi

# --delete-branch never deletes a local branch: gh skips that whenever --repo
# is given, and the checkout may hold another repository's same-named branch.
git -C "$GITREPO" branch feature
new_case
set +e
RUN_CWD="$GITREPO" MERGEPATH_GH_TRANSPORT=rest as_author -- gh pr close 42 --repo o/r --delete-branch >/dev/null 2>"$WORKDIR/err"; rc=$?
set -e
if [ "$rc" -eq 0 ] && git -C "$GITREPO" show-ref --verify --quiet refs/heads/feature \
   && log_has $'DELETE\trepos/o/r/git/refs/heads/feature' && grep -q 'no local branch was deleted' "$WORKDIR/err"; then
  pass "pr close --delete-branch: the remote ref is deleted and a same-named local branch is left, as gh does with --repo"
else
  fail "pr close local branch kept: rc=$rc"; cat "$WORKDIR/err" >&2
fi
git -C "$GITREPO" branch -D feature >/dev/null
new_case
set +e
err="$(MERGEPATH_GH_TRANSPORT=rest STUB_EVENT_ACTOR='claude[bot]' as_author -- gh pr close 42 --repo o/r 2>&1 >/dev/null)"; rc=$?
set -e
if [ "$rc" -eq 5 ] && grep -q "closing PR #42 landed under 'claude\[bot\]'" <<<"$err"; then
  pass "pr close readback: a closed event by another login exits 5"
else
  fail "pr close actor mutation: rc=$rc err=$err"
fi

# --- gh without `gh api --slurp` (#2233) -----------------------------------
# The event reads need gh 2.48 or later. A write whose attribution reads
# events is refused before anything is written, naming the requirement; a
# write that reads no events still runs.
slurp_refused() { # <label> <args...>
  local label="$1" rc=0 err
  shift
  new_case
  set +e
  err="$(MERGEPATH_GH_TRANSPORT=rest STUB_NO_SLURP=1 as_author -- "$@" 2>&1 >/dev/null)"; rc=$?
  set -e
  if [ "$rc" -eq 1 ] && grep -q 'install gh 2.48 or later. Nothing was written.' <<<"$err" \
     && log_lacks $'POST\t' && log_lacks $'PATCH\t' && log_lacks $'DELETE\t' && log_lacks 'events?per_page'; then
    pass "no --slurp: $label is refused before any write"
  else
    fail "no --slurp, $label: rc=$rc err=$err"; cat "$LOGF" >&2
  fi
}
slurp_refused "an edit" gh pr edit 42 --repo o/r --add-label x
slurp_refused "a close" gh pr close 42 --repo o/r --comment bye
slurp_refused "a create with a label" gh pr create --repo o/r --title T --body-file "$VALID_BODY" --head h --label a
new_case
set +e
MERGEPATH_GH_TRANSPORT=rest STUB_NO_SLURP=1 as_author -- gh pr create --repo o/r --title T --body-file "$VALID_BODY" --head h >/dev/null 2>&1; rc=$?
set -e
if [ "$rc" -eq 0 ] && log_has $'POST\trepos/o/r/pulls' && log_lacks $'api\t--help'; then
  pass "no --slurp: a create with no follow-ups reads no events, so it runs without the probe"
else
  fail "no --slurp, plain create: rc=$rc"; cat "$LOGF" >&2
fi
new_case
set +e
MERGEPATH_GH_TRANSPORT=rest STUB_NO_SLURP=1 as_reviewer -- gh pr comment 1 --repo o/r --body x >/dev/null 2>&1; rc=$?
set -e
if [ "$rc" -eq 0 ] && log_has $'POST\trepos/o/r/issues/1/comments'; then
  pass "no --slurp: a comment, attributed from its POST response, still runs"
else
  fail "no --slurp, comment: rc=$rc"; cat "$LOGF" >&2
fi
new_case
set +e
MERGEPATH_GH_TRANSPORT=rest as_author -- gh pr edit 42 --repo o/r --add-label x >/dev/null 2>&1; rc=$?
set -e
if [ "$rc" -eq 0 ] && [ "$(grep -c $'api\t--help' "$LOGF")" -eq 1 ]; then
  pass "with --slurp: the probe runs once per command, however many event reads follow"
else
  fail "probe count: rc=$rc count=$(grep -c $'api\t--help' "$LOGF")"; cat "$LOGF" >&2
fi

# --- partial failures and case ---------------------------------------------
# A write sequence that stops partway still checks the writes that landed:
# a label applied under another login before the reviewer request failed is
# caught (5); applied under the expected login, the failure is reported (1).
new_case
set +e
err="$(MERGEPATH_GH_TRANSPORT=rest STUB_REVIEWERS_FAIL=1 STUB_EVENT_ACTOR='claude[bot]' as_author -- gh pr create --repo o/r --title T --body-file "$VALID_BODY" --head h --label a --reviewer nathanpayne-codex 2>&1 >/dev/null)"; rc=$?
set -e
if [ "$rc" -eq 5 ] && grep -q 'its reviewers could not be requested' <<<"$err" && grep -q "the label 'a' landed under 'claude\\[bot\\]'" <<<"$err" && grep -q 'not attributed to' <<<"$err"; then
  pass "create: a label that landed under another login before a failed reviewer request is caught (5)"
else
  fail "create partial foreign: rc=$rc err=$err"
fi
new_case
set +e
err="$(MERGEPATH_GH_TRANSPORT=rest STUB_REVIEWERS_FAIL=1 as_author -- gh pr create --repo o/r --title T --body-file "$VALID_BODY" --head h --label a --reviewer nathanpayne-codex 2>&1 >/dev/null)"; rc=$?
set -e
if [ "$rc" -eq 1 ] && grep -q 'are attributed to nathanjohnpayne, and no event by another login appeared' <<<"$err"; then
  pass "create: a failed reviewer request after a correctly attributed label is reported as a failure (1)"
else
  fail "create partial clean: rc=$rc err=$err"
fi
new_case
set +e
err="$(MERGEPATH_GH_TRANSPORT=rest STUB_REVIEWERS_FAIL=1 STUB_EVENT_ACTOR='claude[bot]' as_author -- gh pr edit 42 --repo o/r --add-label x --add-reviewer nathanpayne-codex 2>&1 >/dev/null)"; rc=$?
set -e
if [ "$rc" -eq 5 ] && grep -q 'requesting reviewers on PR #42 failed' <<<"$err" && grep -q 'not attributed to' <<<"$err"; then
  pass "edit: a label that landed under another login before a failed reviewer request is caught (5)"
else
  fail "edit partial foreign: rc=$rc err=$err"
fi
# A body edit that landed before a later write failed has no event to be
# attributed by, so it is named as unattributed, and the closing line claims
# attribution only for the evented writes (Codex on #2178).
new_case
set +e
err="$(MERGEPATH_GH_TRANSPORT=rest STUB_REVIEWERS_FAIL=1 MERGEPATH_GH_READBACK_ATTEMPTS=1 as_author -- gh pr edit 42 --repo o/r --body-file "$COMMENT_FILE" --add-reviewer nathanpayne-codex 2>&1 >/dev/null)"; rc=$?
set -e
if [ "$rc" -eq 1 ] && grep -q 'note: the body edit of PR #42 landed before the failure and is not attributable over REST' <<<"$err" \
   && grep -q 'no write that GitHub records as an event landed before the failure' <<<"$err" \
   && ! grep -q 'are attributed to nathanjohnpayne' <<<"$err"; then
  pass "edit: a body-only PATCH before a failed reviewer request is reported as unattributed, not verified"
else
  fail "edit partial body-only: rc=$rc err=$err"
fi
new_case
set +e
err="$(MERGEPATH_GH_TRANSPORT=rest STUB_REVIEWERS_FAIL=1 MERGEPATH_GH_READBACK_ATTEMPTS=1 as_author -- gh pr edit 42 --repo o/r --body-file "$COMMENT_FILE" --add-label x --add-reviewer nathanpayne-codex 2>&1 >/dev/null)"; rc=$?
set -e
if [ "$rc" -eq 1 ] && grep -q 'note: the body edit of PR #42 landed before the failure' <<<"$err" \
   && grep -q 'the other writes that succeeded before the failure are attributed to nathanjohnpayne' <<<"$err"; then
  pass "edit: a body PATCH and a label before a failed reviewer request report the body unattributed and the label attributed"
else
  fail "edit partial body and label: rc=$rc err=$err"
fi
new_case
set +e
err="$(MERGEPATH_GH_TRANSPORT=rest STUB_REVIEWERS_FAIL=1 STUB_EVENT_ACTOR='claude[bot]' as_author -- gh pr edit 42 --repo o/r --body-file "$COMMENT_FILE" --add-label x --add-reviewer nathanpayne-codex 2>&1 >/dev/null)"; rc=$?
set -e
if [ "$rc" -eq 5 ] && grep -q 'note: the body edit of PR #42 landed before the failure' <<<"$err" && grep -q 'not attributed to' <<<"$err"; then
  pass "edit: the unattributed body is still named when a foreign label event fails the partial readback (5)"
else
  fail "edit partial body foreign: rc=$rc err=$err"
fi
# A write that succeeded must show its own expected-login event: when the
# label's event never appears before the reviewer request fails, the label is
# unattributed (5), not merely "no foreign actor seen" (Codex on #2178).
new_case
set +e
err="$(MERGEPATH_GH_TRANSPORT=rest STUB_REVIEWERS_FAIL=1 STUB_EVENTS_HIDE_READS=99 MERGEPATH_GH_READBACK_ATTEMPTS=2 as_author -- gh pr create --repo o/r --title T --body-file "$VALID_BODY" --head h --label a --reviewer nathanpayne-codex 2>&1 >/dev/null)"; rc=$?
set -e
if [ "$rc" -eq 5 ] && grep -q "no labeled event appeared" <<<"$err" && grep -q 'not attributed to' <<<"$err"; then
  pass "create: a label that succeeded but never shows its event before a failed reviewer request is unattributed (5)"
else
  fail "create partial missing event: rc=$rc err=$err"
fi
# Only the writes that succeeded are attributed: a reviewer request that
# failed is not demanded, so a clean label still reports the failure (1).
new_case
set +e
err="$(MERGEPATH_GH_TRANSPORT=rest STUB_REVIEWERS_FAIL=1 MERGEPATH_GH_READBACK_ATTEMPTS=2 as_author -- gh pr create --repo o/r --title T --body-file "$VALID_BODY" --head h --label a --reviewer nathanpayne-codex 2>&1 >/dev/null)"; rc=$?
set -e
if [ "$rc" -eq 1 ] && ! grep -q 'no review_requested event appeared' <<<"$err"; then
  pass "create: the failed reviewer request itself is not demanded as an event"
else
  fail "create partial only-done: rc=$rc err=$err"
fi
# gh reads repeatable values as CSV, so a quoted value can hold a comma;
# the transport refuses one rather than split it into the wrong names.
refused_rest "a quoted CSV label on edit" as_author gh pr edit 42 --repo o/r --add-label '"area,backend"'
refused_rest "a quoted CSV label on create" as_author gh pr create --repo o/r --title T --body-file "$VALID_BODY" --head h --label '"area,backend"'
# Logins and label names compare without case, as GitHub compares them.
new_case
set +e
MERGEPATH_GH_TRANSPORT=rest STUB_PR_REVIEWERS=MixedCase as_author -- gh pr edit 42 --repo o/r --remove-reviewer mixedcase >/dev/null 2>"$WORKDIR/err"; rc=$?
set -e
if [ "$rc" -eq 0 ] && log_has $'DELETE\trepos/o/r/pulls/42/requested_reviewers\t--input\t'"$(printf '%s' '{"reviewers":["MixedCase"]}')"; then
  pass "edit: removing a reviewer in another case removes the current one, spelled as GitHub spells it"
else
  fail "edit case-insensitive removal: rc=$rc"; cat "$LOGF" "$WORKDIR/err" >&2
fi
new_case
set +e
MERGEPATH_GH_TRANSPORT=rest STUB_PR_LABELS=Bug as_author -- gh pr edit 42 --repo o/r --add-label bug >/dev/null 2>"$WORKDIR/err"; rc=$?
set -e
if [ "$rc" -eq 0 ] && log_lacks 'issues/42/labels' && grep -q 'no change' "$WORKDIR/err"; then
  pass "edit: adding a label already present in another case is a no-op"
else
  fail "edit case-insensitive label no-op: rc=$rc"; cat "$LOGF" "$WORKDIR/err" >&2
fi
new_case
set +e
MERGEPATH_GH_TRANSPORT=rest STUB_LABEL_UPCASE=1 as_author -- gh pr edit 42 --repo o/r --add-label bug >/dev/null 2>"$WORKDIR/err"; rc=$?
set -e
if [ "$rc" -eq 0 ] && grep -q "labeled:bug" "$WORKDIR/err"; then
  pass "edit: a label event GitHub spells in another case is still attributed"
else
  fail "edit case-insensitive attribution: rc=$rc"; cat "$LOGF" "$WORKDIR/err" >&2
fi

# --- Phase 4b round two ------------------------------------------------------
# Every call the wrappers make with the verified token is pinned to
# github.com, on both transports: with GH_HOST unset, gh targets the only host
# in its hosts file, and sends GH_TOKEN to github.localhost and *.ghe.com too.
HOST_LOG="$WORKDIR/hosts.log"
for t in rest gh; do
  new_case
  : >"$HOST_LOG"
  set +e
  (unset GH_HOST; MERGEPATH_GH_TRANSPORT=$t STUB_HOST_LOG="$HOST_LOG" as_reviewer -- gh pr comment 1 --repo o/r --body x >/dev/null 2>&1); rc=$?
  set -e
  writes=$(grep -v $'\tapi user' "$HOST_LOG" | grep -c . || true)
  pinned=$(grep -v $'\tapi user' "$HOST_LOG" | grep -c $'^github.com\t' || true)
  if [ "$rc" -eq 0 ] && [ "$writes" -ge 1 ] && [ "$writes" -eq "$pinned" ]; then
    pass "$t transport: every call under the verified token runs with GH_HOST=github.com"
  else
    fail "$t transport GH_HOST pin: rc=$rc writes=$writes pinned=$pinned"; cat "$HOST_LOG" >&2
  fi
done
new_case
: >"$HOST_LOG"
set +e
(unset GH_HOST; MERGEPATH_GH_TRANSPORT=gh STUB_HOST_LOG="$HOST_LOG" as_author -- gh pr comment 5 --repo o/r --body 'review status' >/dev/null 2>&1); rc=$?
set -e
if [ "$rc" -eq 0 ] && grep -q $'^github.com\tpr comment 5' "$HOST_LOG"; then
  pass "gh transport, author wrapper: the wrapped write runs with GH_HOST=github.com"
else
  fail "author gh transport GH_HOST pin: rc=$rc"; cat "$HOST_LOG" >&2
fi
# Create follow-ups are taken against the created pull request's state, and
# attributed only from events after a snapshot: automation that labeled the
# new PR first makes that label a no-op, and its own event is not read as
# this wrapper's write.
new_case
set +e
MERGEPATH_GH_TRANSPORT=rest STUB_PR_LABELS=a STUB_EVENTS_BEFORE='[{"id":1,"event":"labeled","label":{"name":"a"},"actor":{"login":"automation[bot]"}}]' \
  as_author -- gh pr create --repo o/r --title T --body-file "$VALID_BODY" --head h --label a --label b >/dev/null 2>"$WORKDIR/err"; rc=$?
set -e
if [ "$rc" -eq 0 ] && log_has $'POST\trepos/o/r/issues/42/labels\t--input\t'"$(printf '%s' '{"labels":["b"]}')" && grep -q 'labeled:b' "$WORKDIR/err"; then
  pass "create follow-ups: a label automation already applied is dropped, and its earlier event is not attributed to this write"
else
  fail "create follow-up no-op filter: rc=$rc"; cat "$LOGF" "$WORKDIR/err" >&2
fi
# History before the snapshot is not this write: a label another account
# applied and removed earlier, then requested again here, is attributed only
# from the event this write produced.
new_case
set +e
MERGEPATH_GH_TRANSPORT=rest STUB_EVENTS_BEFORE='[{"id":1,"event":"labeled","label":{"name":"b"},"actor":{"login":"automation[bot]"}},{"id":2,"event":"unlabeled","label":{"name":"b"},"actor":{"login":"automation[bot]"}}]' \
  as_author -- gh pr create --repo o/r --title T --body-file "$VALID_BODY" --head h --label b >/dev/null 2>"$WORKDIR/err"; rc=$?
set -e
if [ "$rc" -eq 0 ] && grep -q 'labeled:b' "$WORKDIR/err"; then
  pass "create follow-ups: an earlier event for the same label by another account is outside the snapshot"
else
  fail "create follow-up snapshot: rc=$rc"; cat "$WORKDIR/err" >&2
fi
new_case
set +e
MERGEPATH_GH_TRANSPORT=rest STUB_PR_LABELS=a as_author -- gh pr create --repo o/r --title T --body-file "$VALID_BODY" --head h --label a >/dev/null 2>"$WORKDIR/err"; rc=$?
set -e
if [ "$rc" -eq 0 ] && log_lacks 'issues/42/labels' && log_lacks 'events?per_page'; then
  pass "create follow-ups: when every requested label is already present, nothing is written and no events are read"
else
  fail "create follow-up all present: rc=$rc"; cat "$LOGF" "$WORKDIR/err" >&2
fi
new_case
set +e
err="$(MERGEPATH_GH_TRANSPORT=rest STUB_EVENTS_FAIL=1 as_author -- gh pr create --repo o/r --title T --body-file "$VALID_BODY" --head h --label b 2>&1 >/dev/null)"; rc=$?
set -e
if [ "$rc" -eq 5 ] && grep -q 'were not attempted' <<<"$err" && log_lacks 'issues/42/labels'; then
  pass "create follow-ups: an unreadable event snapshot stops before the follow-up writes"
else
  fail "create follow-up snapshot failure: rc=$rc err=$err"; cat "$LOGF" >&2
fi

# --- round-five parity cases ------------------------------------------------
# Removal wins when one login or label is both added and removed, as gh
# computes (current + added) - removed.
new_case
set +e
MERGEPATH_GH_TRANSPORT=rest as_author -- gh pr edit 42 --repo o/r --add-reviewer nathanpayne-codex --remove-reviewer nathanpayne-codex --add-label x --remove-label x >/dev/null 2>"$WORKDIR/err"; rc=$?
set -e
if [ "$rc" -eq 0 ] && log_lacks 'requested_reviewers' && log_lacks 'issues/42/labels' && grep -q 'no change' "$WORKDIR/err"; then
  pass "pr edit: a reviewer and a label both added and removed end up absent, so nothing is written"
else
  fail "pr edit add+remove absent: rc=$rc"; cat "$LOGF" "$WORKDIR/err" >&2
fi
new_case
set +e
MERGEPATH_GH_TRANSPORT=rest STUB_PR_REVIEWERS=nathanpayne-codex as_author -- gh pr edit 42 --repo o/r --add-reviewer nathanpayne-codex --remove-reviewer nathanpayne-codex >/dev/null 2>"$WORKDIR/err"; rc=$?
set -e
if [ "$rc" -eq 0 ] && log_has $'DELETE\trepos/o/r/pulls/42/requested_reviewers\t--input\t'"$(printf '%s' '{"reviewers":["nathanpayne-codex"]}')" && log_lacks $'POST\trepos/o/r/pulls/42/requested_reviewers'; then
  pass "pr edit: a requested reviewer both added and removed is removed, as gh does"
else
  fail "pr edit add+remove present: rc=$rc"; cat "$LOGF" "$WORKDIR/err" >&2
fi
# A body-file edit compares bytes: the same body with its trailing newline is
# a no-op, and a trailing newline is not stripped from the PATCH.
new_case
set +e
MERGEPATH_GH_TRANSPORT=rest STUB_PR_BODY=$'line one\nline two\n' as_author -- gh pr edit 42 --repo o/r --body-file "$COMMENT_FILE" >/dev/null 2>"$WORKDIR/err"; rc=$?
set -e
if [ "$rc" -eq 0 ] && log_lacks 'PATCH' && grep -q 'no change' "$WORKDIR/err"; then
  pass "pr edit: a body file identical to the current body, trailing newline included, is a no-op"
else
  fail "pr edit byte-exact no-op: rc=$rc"; cat "$LOGF" "$WORKDIR/err" >&2
fi
# The gh the caller names runs the REST calls.
new_case
set +e
MERGEPATH_GH_TRANSPORT=rest as_reviewer -- "$ALT_DIR/gh" pr comment 1 --repo o/r --body x >/dev/null 2>&1; rc=$?
set -e
if [ "$rc" -eq 0 ] && [ "$(grep -c '^ALT-GH-USED$' "$LOGF")" -ge 2 ] && log_has $'POST\trepos/o/r/issues/1/comments'; then
  pass "an absolute gh path in the payload runs every REST call"
else
  fail "explicit gh path: rc=$rc"; cat "$LOGF" >&2
fi
new_case
set +e
err="$(RUN_CWD="$ALT_DIR/.." MERGEPATH_GH_TRANSPORT=rest as_reviewer -- alt-bin/gh pr comment 1 --repo o/r --body x 2>&1 >/dev/null)"; rc=$?
set -e
if [ "$rc" -ne 0 ] && log_lacks 'POST'; then
  pass "a relative gh path in the payload is refused before any write"
else
  fail "relative gh path: rc=$rc err=$err"; cat "$LOGF" >&2
fi

# ---------------------------------------------------------------------------
# merge is a ceiling on this transport
# ---------------------------------------------------------------------------
new_case
set +e
err="$(CLAUDE_CODE_REMOTE=true as_author -- gh pr merge 42 --repo o/r --squash --delete-branch --match-head-commit 0123456789012345678901234567890123456789 2>&1 >/dev/null)"; rc=$?
set -e
if [ "$rc" -eq 6 ] && grep -q 'CEILING: gh pr merge does not run on the REST transport' <<<"$err" \
   && grep -q 'post-local-agent-handback.sh <PR#> --blocked graphql' <<<"$err" \
   && log_lacks $'pr\tmerge' && log_lacks 'POST' && log_lacks 'PUT'; then
  pass "pr merge on a cloud surface: refused with the ceiling code (6) and the handback command; nothing written"
else
  fail "pr merge ceiling: rc=$rc err=$err"; cat "$LOGF" >&2
fi

for spelling in "gh --repo o/r pr merge 42 --squash" "gh -R o/r pr merge 42" "gh pr --repo o/r merge 42"; do
  new_case
  set +e
  # shellcheck disable=SC2086  # the spelling is split into argv on purpose
  err="$(CLAUDE_CODE_REMOTE=true as_author -- $spelling 2>&1 >/dev/null)"; rc=$?
  set -e
  if [ "$rc" -eq 6 ] && grep -q 'CEILING: gh pr merge' <<<"$err" && log_lacks $'merge\t'; then
    pass "pr merge spelled '$spelling' on a cloud surface: the same ceiling refusal"
  else
    fail "merge spelling '$spelling': rc=$rc err=$err"; cat "$LOGF" >&2
  fi
done
for api_merge in "gh api -X PUT repos/o/r/pulls/42/merge" "gh api --method=PUT repos/o/r/pulls/42/merge -f merge_method=squash"; do
  new_case
  set +e
  # shellcheck disable=SC2086  # the spelling is split into argv on purpose
  err="$(CLAUDE_CODE_REMOTE=true as_author -- $api_merge 2>&1 >/dev/null)"; rc=$?
  set -e
  if [ "$rc" -eq 2 ] && grep -q 'merge API mutations are forbidden' <<<"$err" && log_lacks 'PUT'; then
    pass "REST merge endpoint through gh api ('$api_merge') on a cloud surface: refused, never passed through"
  else
    fail "api merge '$api_merge': rc=$rc err=$err"; cat "$LOGF" >&2
  fi
done
new_case
set +e
err="$(CLAUDE_CODE_REMOTE=true as_reviewer -- gh api graphql -f 'query=mutation { mergePullRequest(input: {pullRequestId: "x"}) { clientMutationId } }' 2>&1 >/dev/null)"; rc=$?
set -e
if [ "$rc" -eq 2 ] && grep -q 'merge API mutations are forbidden' <<<"$err" && log_lacks 'graphql'; then
  pass "GraphQL merge mutation through gh api on a cloud surface: refused for the reviewer wrapper too"
else
  fail "graphql merge: rc=$rc err=$err"; cat "$LOGF" >&2
fi
# Arming auto-merge or entering the merge queue merges later without the
# gates, so those GraphQL mutations are refused like the merge itself, on
# both transports of the author wrapper.
for mutation in enablePullRequestAutoMerge disablePullRequestAutoMerge addPullRequestToMergeQueue enqueuePullRequest dequeuePullRequest; do
  for t in rest gh; do
    new_case
    set +e
    err="$(MERGEPATH_GH_TRANSPORT=$t as_author -- gh api graphql -f "query=mutation { $mutation(input: {pullRequestId: \"x\"}) { clientMutationId } }" 2>&1 >/dev/null)"; rc=$?
    set -e
    if [ "$rc" -eq 2 ] && grep -q 'merge API mutations are forbidden' <<<"$err" && log_lacks 'graphql'; then
      pass "$mutation through gh api ($t transport): refused before the call"
    else
      fail "$mutation ($t transport): rc=$rc err=$err"; cat "$LOGF" >&2
    fi
  done
done
new_case
set +e
err="$(CLAUDE_CODE_REMOTE=true as_reviewer -- gh --repo o/r pr comment 1 --body x 2>&1 >/dev/null)"; rc=$?
set -e
if [ "$rc" -eq 1 ] && grep -q "option '--repo' before the command group" <<<"$err" && log_lacks $'pr\tcomment' && log_lacks 'POST'; then
  pass "an option before the command group on the REST transport: refused, not passed to native gh"
else
  fail "leading option: rc=$rc err=$err"; cat "$LOGF" >&2
fi

new_case
set +e
MERGEPATH_GH_TRANSPORT=gh CLAUDE_CODE_REMOTE=true as_author -- gh pr merge 42 --repo o/r --disable-auto >/dev/null 2>&1; rc=$?
set -e
if [ "$rc" -eq 0 ] && log_has $'gh\tpr\tmerge\t42\t--repo\to/r\t--disable-auto'; then
  pass "MERGEPATH_GH_TRANSPORT=gh on a cloud surface: the gh path runs the wrapped merge as before"
else
  fail "forced gh transport merge: rc=$rc"; cat "$LOGF" >&2
fi

# ---------------------------------------------------------------------------
# pass-through: gh api is REST already; other commands run unchanged
# ---------------------------------------------------------------------------
new_case
set +e
out="$(MERGEPATH_GH_TRANSPORT=rest as_reviewer -- gh api -X POST repos/o/r/issues/1/comments -f body=x 2>/dev/null)"; rc=$?
set -e
if [ "$rc" -eq 0 ] && log_has $'GH_TOKEN=ghp_reviewer-token GITHUB_TOKEN= ENT=mergepath-guarded-write-github-com-only|mergepath-guarded-write-github-com-only gh\tapi\t-X\tPOST\trepos/o/r/issues/1/comments\t-f\tbody=x'; then
  pass "gh api payload on the REST transport: passed through under the verified token"
else
  fail "gh api passthrough: rc=$rc"; cat "$LOGF" >&2
fi

new_case
set +e
MERGEPATH_GH_TRANSPORT=rest as_reviewer -- gh repo view o/r >/dev/null 2>&1; rc=$?
set -e
if [ "$rc" -eq 0 ] && log_has $'GH_TOKEN=ghp_reviewer-token GITHUB_TOKEN= ENT=mergepath-guarded-write-github-com-only|mergepath-guarded-write-github-com-only gh\trepo\tview\to/r'; then
  pass "a non-pr, non-issue gh command on the REST transport: passed through unchanged"
else
  fail "gh repo view passthrough: rc=$rc"; cat "$LOGF" >&2
fi

# ---------------------------------------------------------------------------
# caller-supplied credential re-routing is refused on both transports (#1542)
# ---------------------------------------------------------------------------
override_refused() { # <label> <wrapper fn> <args...>
  local label="$1" fn="$2" rc=0 err t
  shift 2
  for t in gh rest; do
    new_case
    set +e
    err="$(MERGEPATH_GH_TRANSPORT=$t "$fn" -- "$@" 2>&1 >/dev/null)"; rc=$?
    set -e
    if [ "$rc" -eq 1 ] && grep -q '#1542' <<<"$err" && [ ! -s "$LOGF" ]; then
      pass "$label ($t transport): refused before any gh call"
    else
      fail "$label ($t transport): rc=$rc err=$err"; cat "$LOGF" >&2
    fi
  done
}
override_refused "--hostname" as_reviewer gh pr comment 1 --repo o/r --body x --hostname ghe.example.com
override_refused "--hostname= on gh api" as_reviewer gh api --hostname=ghe.example.com repos/o/r
override_refused "host-qualified --repo" as_reviewer gh pr comment 1 --repo ghe.example.com/o/r --body x
override_refused "host-qualified --repo= on the author wrapper" as_author gh pr edit 1 --repo=ghe.example.com/o/r --add-label x
override_refused "host-qualified -R" as_reviewer gh pr review 1 -R ghe.example.com/o/r --approve
override_refused "Authorization header on gh api" as_reviewer gh api -H 'Authorization: token ghp_other' repos/o/r/issues/1/comments -f body=x
override_refused "Authorization header, long attached form" as_reviewer gh api --header='authorization: Bearer x' repos/o/r
override_refused "Authorization header, short attached form" as_reviewer gh api -HAuthorization:x repos/o/r
override_refused "gh api endpoint on another host" as_reviewer gh api https://evil.example/repos/o/r/issues/1/comments -f body=x
# Option values cannot hide a re-routing argument: each argument is checked on
# its own, so a value-taking option in front cannot shift the real one.
override_refused "a PR URL selector on github.localhost" as_reviewer gh pr comment https://github.localhost/o/r/pull/123 --body x
override_refused "an issue URL selector on a ghe.com tenant" as_reviewer gh issue comment https://tenant.ghe.com/o/r/issues/7 --body x
# Any URL gh can read as a selector is checked, for every command the
# wrappers pass through, not only pull request and issue URLs (Phase 4b on
# #2178): gh repo view takes its host from a repository URL.
override_refused "a repository URL on a ghe.com tenant (gh repo view)" as_reviewer gh repo view https://tenant.ghe.com/o/r --json name
override_refused "an scp-like git@ repository URL" as_author gh repo clone git@tenant.ghe.com:o/r
override_refused "an ssh:// repository URL with userinfo" as_reviewer gh repo view ssh://git@tenant.ghe.com/o/r
override_refused "a git+https:// repository URL on github.localhost" as_reviewer gh repo view git+https://github.localhost/o/r
override_refused "an ssh: URL without slashes" as_reviewer gh repo view ssh:tenant.ghe.com/o/r
override_refused "a mixed-case scheme and host" as_reviewer gh repo view HTTPS://Tenant.GHE.com/o/r
override_refused "userinfo that names github.com" as_reviewer gh repo view https://github.com@tenant.ghe.com/o/r
override_refused "a port on the foreign host" as_reviewer gh repo view https://tenant.ghe.com:443/o/r
override_refused "a repository URL behind a --jq value" as_reviewer gh repo view --jq https://tenant.ghe.com/o/r
override_refused "an argument that begins with a foreign URL" as_reviewer gh repo view 'https://tenant.ghe.com/o/r extra'
# A repository value is held to a plain OWNER/REPO in every form gh reads
# one, and so is an inherited GH_REPO: gh run list --repo=git@HOST:O/R
# targets that host (Phase 4b on #2178).
override_refused "a --repo that is not OWNER/REPO" as_reviewer gh pr comment 1 --repo r --body x
override_refused "an scp-like repository in --repo=" as_reviewer gh run list --repo=git@tenant.ghe.com:o/r
override_refused "an scp-like repository in -RVALUE" as_reviewer gh run list -Rgit@tenant.ghe.com:o/r
override_refused "an scp-like repository in -R=VALUE" as_reviewer gh run list -R=git@tenant.ghe.com:o/r
override_refused "a repository URL in --repo=" as_author gh run list --repo=https://tenant.ghe.com/o/r
override_refused "a repository in a short-option cluster ending in R" as_reviewer gh pr view 1 -wRgit@tenant.ghe.com:o/r
override_refused "a repository after a short-option cluster ending in R" as_reviewer gh pr view 1 -wR tenant.ghe.com:o/r
for gr in git@tenant.ghe.com:o/r https://tenant.ghe.com/o/r; do
  for t in gh rest; do
    new_case
    set +e
    err="$(GH_REPO=$gr MERGEPATH_GH_TRANSPORT=$t as_reviewer -- gh run list 2>&1 >/dev/null)"; rc=$?
    set -e
    if [ "$rc" -eq 1 ] && grep -q 'not a plain OWNER/REPO' <<<"$err" && [ ! -s "$LOGF" ]; then
      pass "inherited GH_REPO $gr ($t transport): refused before any gh call"
    else
      fail "inherited GH_REPO $gr ($t transport): rc=$rc err=$err"; cat "$LOGF" >&2
    fi
  done
done
# The positional HOST/OWNER/REPO form with a port or userinfo targets that
# host too: gh strips both before it picks a credential (Phase 4b on #2178).
override_refused "a positional HOST:PORT/OWNER/REPO" as_reviewer gh repo view github.localhost:443/o/r --json name
override_refused "a positional USER@HOST/OWNER/REPO" as_reviewer gh repo view x@tenant.ghe.com/o/r
override_refused "a positional host-qualified repo whose repo segment holds a space" as_reviewer gh repo view 'tenant.ghe.com/o/r x'
# Only gh's own command groups run as the first argument: an alias or an
# extension expands where the checks cannot see it, and a leading option
# shifts which argument gh takes as the command (Phase 4b on #2178).
override_refused "an alias or extension name as the command" as_reviewer gh rv
override_refused "a gh alias management command" as_reviewer gh alias set rv 'repo view github.localhost:443/o/r'
override_refused "a gh extension command" as_author gh extension exec myext
override_refused "a leading option before an extension name" as_reviewer gh --x pr myext
override_refused "an extension name behind a leading --repo" as_reviewer gh --repo o/r myext
override_refused "a leading -R with a value that is not OWNER/REPO" as_reviewer gh -R git@tenant.ghe.com:o/r pr view 1
override_refused "gh auth under the verified token" as_reviewer gh auth token
override_refused "no command at all" as_reviewer gh
override_refused "short header flag with an equals sign" as_reviewer gh api repos/o/r/issues/1/comments -H='Authorization: Bearer x' -f body=x
override_refused "header flag clustered after another short flag" as_reviewer gh api repos/o/r/issues/1/comments -iHAuthorization:x -f body=x
override_refused "Authorization header behind a --preview value" as_reviewer gh api repos/o/r/issues/1/comments --preview --header --header 'Authorization: Bearer x' -f body=x
override_refused "host-qualified repo behind a --body value" as_reviewer gh pr comment 1 --body --repo --repo tenant.ghe.com/o/r
override_refused "host-qualified repo behind a -H value on pr create" as_author gh pr create -H --repo --repo github.localhost/o/r --title t --body-file /dev/null
override_refused "Authorization header behind a --jq value" as_reviewer gh api repos/o/r --jq --header --header 'authorization:x'
for t in gh rest; do
  new_case
  set +e
  err="$(GH_REPO=tenant.ghe.com/o/r MERGEPATH_GH_TRANSPORT=$t as_reviewer -- gh pr comment 1 --repo o/r --body x 2>&1 >/dev/null)"; rc=$?
  set -e
  if [ "$rc" -eq 1 ] && grep -q 'inherited GH_REPO (.tenant.ghe.com/o/r.) that is not a plain OWNER/REPO' <<<"$err" && [ ! -s "$LOGF" ]; then
    pass "inherited host-qualified GH_REPO ($t transport): refused before any gh call"
  else
    fail "inherited GH_REPO ($t transport): rc=$rc err=$err"; cat "$LOGF" >&2
  fi
done
new_case
set +e
GH_REPO=o/r MERGEPATH_GH_TRANSPORT=rest as_reviewer -- gh pr comment 1 --repo o/r --body x >/dev/null 2>&1; rc=$?
set -e
if [ "$rc" -eq 0 ] && log_has $'POST\trepos/o/r/issues/1/comments'; then
  pass "an inherited OWNER/REPO GH_REPO with no host is not refused"
else
  fail "plain GH_REPO: rc=$rc"; cat "$LOGF" >&2
fi

# Text with a dotted word before two slashes is not a host-qualified repo
# when the would-be host holds whitespace, and ./a/b has no host at all.
for body in 'Update foo.sh: handles a/b/c' ./a/b; do
  new_case
  set +e
  MERGEPATH_GH_TRANSPORT=rest as_reviewer -- gh pr comment 1 --repo o/r --body "$body" >/dev/null 2>&1; rc=$?
  set -e
  if [ "$rc" -eq 0 ] && log_has $'POST\trepos/o/r/issues/1/comments'; then
    pass "a body of '$body' is not read as a host-qualified repository"
  else
    fail "body '$body': rc=$rc"; cat "$LOGF" >&2
  fi
done
# A plain OWNER/REPO passes in every repository form.
for form in --repo=Org-1/repo.name_x -RO/r -R=o/r; do
  new_case
  set +e
  MERGEPATH_GH_TRANSPORT=gh as_reviewer -- gh run list "$form" >/dev/null 2>&1; rc=$?
  set -e
  if [ "$rc" -eq 0 ] && log_has $'gh\trun\tlist\t'"$form"; then
    pass "a plain OWNER/REPO passes as $form"
  else
    fail "plain repo $form: rc=$rc"; cat "$LOGF" >&2
  fi
done
# GitHub's own hosts, and text that merely contains a URL, are not refused.
for t in gh rest; do
  new_case
  set +e
  MERGEPATH_GH_TRANSPORT=$t as_reviewer -- gh repo view HTTPS://GitHub.com/o/r --json name >/dev/null 2>&1; rc=$?
  set -e
  if [ "$rc" -eq 0 ] && log_has $'gh\trepo\tview\tHTTPS://GitHub.com/o/r'; then
    pass "a github.com repository URL in any case passes through ($t transport)"
  else
    fail "github.com repo URL ($t transport): rc=$rc"; cat "$LOGF" >&2
  fi
  new_case
  set +e
  MERGEPATH_GH_TRANSPORT=$t as_reviewer -- gh repo clone git@github.com:o/r >/dev/null 2>&1; rc=$?
  set -e
  if [ "$rc" -eq 0 ] && log_has $'gh\trepo\tclone\tgit@github.com:o/r'; then
    pass "an scp-like github.com URL passes through ($t transport)"
  else
    fail "github.com scp URL ($t transport): rc=$rc"; cat "$LOGF" >&2
  fi
done
new_case
set +e
MERGEPATH_GH_TRANSPORT=rest as_reviewer -- gh pr comment 1 --repo o/r --body 'see https://tenant.ghe.com/o/r for context' >/dev/null 2>&1; rc=$?
set -e
if [ "$rc" -eq 0 ] && log_has $'POST\trepos/o/r/issues/1/comments'; then
  pass "a body that contains a foreign URL after other text is not refused"
else
  fail "body containing a URL: rc=$rc"; cat "$LOGF" >&2
fi
new_case
set +e
MERGEPATH_GH_TRANSPORT=rest as_author -- gh pr edit 42 --repo o/r --title fix:typo >/dev/null 2>&1; rc=$?
set -e
if [ "$rc" -eq 0 ] && log_has $'PATCH\trepos/o/r/pulls/42'; then
  pass "a title shaped like word:word is not read as a URL"
else
  fail "word:word title: rc=$rc"; cat "$LOGF" >&2
fi
new_case
set +e
MERGEPATH_GH_TRANSPORT=gh as_reviewer -- gh pr comment https://github.com/o/r/pull/9 --body x >/dev/null 2>&1; rc=$?
set -e
if [ "$rc" -eq 0 ] && log_has $'gh\tpr\tcomment\thttps://github.com/o/r/pull/9'; then
  pass "a github.com PR URL selector still passes on the gh transport"
else
  fail "github.com URL selector: rc=$rc"; cat "$LOGF" >&2
fi
# An argument that is a foreign URL is refused whatever option precedes it:
# `--title --body https://tenant.ghe.com/o/r` makes gh read the URL as the
# selector, so a position-based exemption for body values could be bypassed
# (Phase 4b on #2178). A body that is only a URL goes through --body-file,
# and a github.com URL body is not refused.
new_case
set +e
err="$(MERGEPATH_GH_TRANSPORT=rest as_reviewer -- gh pr comment 1 --repo o/r --body https://example.com/a/b 2>&1 >/dev/null)"; rc=$?
set -e
if [ "$rc" -eq 1 ] && grep -q -- '--body-file' <<<"$err" && log_lacks 'issues/1/comments'; then
  pass "a body that is only a foreign URL is refused with the --body-file route"
else
  fail "foreign URL body: rc=$rc err=$err"; cat "$LOGF" >&2
fi
override_refused "a foreign URL behind a --title that swallows --body" as_reviewer gh pr create --title --body https://tenant.ghe.com/o/r
printf 'https://example.com/a/b' >"$WORKDIR/url-body.md"
new_case
set +e
MERGEPATH_GH_TRANSPORT=rest as_reviewer -- gh pr comment 1 --repo o/r --body-file "$WORKDIR/url-body.md" >/dev/null 2>&1; rc=$?
set -e
if [ "$rc" -eq 0 ] && log_has $'POST\trepos/o/r/issues/1/comments'; then
  pass "the same URL-only body through --body-file is posted"
else
  fail "URL body through --body-file: rc=$rc"; cat "$LOGF" >&2
fi
new_case
set +e
MERGEPATH_GH_TRANSPORT=rest as_reviewer -- gh pr comment 1 --repo o/r --body https://github.com/o/r/pull/1 >/dev/null 2>&1; rc=$?
set -e
if [ "$rc" -eq 0 ] && log_has $'POST\trepos/o/r/issues/1/comments'; then
  pass "a body that is only a github.com URL is not refused"
else
  fail "github.com URL body: rc=$rc"; cat "$LOGF" >&2
fi
new_case
set +e
MERGEPATH_GH_TRANSPORT=gh as_author -- gh pr create -H feature --title t --body-file "$VALID_BODY" >/dev/null 2>&1; rc=$?
set -e
if [ "$rc" -eq 0 ] && log_has $'gh\tpr\tcreate\t-H\tfeature'; then
  pass "-H on gh pr create is --head, not a header: accepted on the gh transport"
else
  fail "-H head on gh transport: rc=$rc"; cat "$LOGF" >&2
fi

new_case
set +e
MERGEPATH_GH_TRANSPORT=gh GH_GENERIC_RC=0 as_reviewer -- gh api -H 'Accept: application/vnd.github+json' https://api.github.com/repos/o/r >/dev/null 2>&1; rc=$?
set -e
if [ "$rc" -eq 0 ] && log_has $'gh\tapi\t-H\tAccept: application/vnd.github+json\thttps://api.github.com/repos/o/r'; then
  pass "a non-Authorization header and an api.github.com URL pass"
else
  fail "benign header: rc=$rc"; cat "$LOGF" >&2
fi

# ---------------------------------------------------------------------------
# trace marker (bootstrap's "did the write run" signal) on the REST transport
# ---------------------------------------------------------------------------
new_case
MARKER="$WORKDIR/marker"
rm -f "$MARKER"
set +e
MERGEPATH_GH_TRANSPORT=rest GH_AS_AUTHOR_TRACE_MARKER="$MARKER" as_author -- gh pr comment 5 --repo o/r --body 'review status' >/dev/null 2>&1; rc=$?
set -e
if [ "$rc" -eq 0 ] && [ -e "$MARKER" ] && log_lacks 'GH_AS_AUTHOR_TRACE_MARKER'; then
  pass "trace marker: created before the REST write"
else
  fail "trace marker REST: rc=$rc marker=$([ -e "$MARKER" ] && echo present || echo absent)"
fi
rm -f "$MARKER"
set +e
MERGEPATH_GH_TRANSPORT=rest GH_AS_AUTHOR_TRACE_MARKER="$MARKER" as_author -- gh pr comment 5 --repo o/r >/dev/null 2>&1; rc=$?
set -e
if [ "$rc" -eq 1 ] && [ ! -e "$MARKER" ]; then
  pass "trace marker: absent when the form is refused before the write"
else
  fail "trace marker refusal: rc=$rc marker=$([ -e "$MARKER" ] && echo present || echo absent)"
fi
new_case
set +e
MERGEPATH_GH_TRANSPORT=rest GH_AS_AUTHOR_TRACE_MARKER="$WORKDIR/no-such-dir/marker" as_author -- gh pr comment 5 --repo o/r --body x >/dev/null 2>&1; rc=$?
set -e
if [ "$rc" -eq 70 ] && log_lacks 'POST'; then
  pass "trace marker: unwritable, so exit 70 and the REST write never runs"
else
  fail "trace marker unwritable: rc=$rc"; cat "$LOGF" >&2
fi

# #2158: both transports refuse accidental provider commands before a write.
TRIGGER_BODY="$WORKDIR/accidental-command.md"
printf '%s\n' 'Do not quote `@CoDeX review` in a status comment.' > "$TRIGGER_BODY"
for transport in gh rest; do
  for role in author reviewer; do
    new_case
    rc=0
    MERGEPATH_GH_TRANSPORT="$transport" "as_$role" -- gh pr comment 5 --repo o/r --body-file "$TRIGGER_BODY" > /dev/null 2>"$WORKDIR/err" || rc=$?
    if [ "$rc" -ne 0 ] && grep -q 'Reword the comment' "$WORKDIR/err" && log_lacks 'POST' && log_lacks $'pr\tcomment'; then
      pass "$transport $role: accidental trigger body file refused before writing"
    else
      fail "$transport $role trigger guard: rc=$rc"; cat "$LOGF" >&2
    fi
  done
  new_case
  rc=0
  MERGEPATH_GH_TRANSPORT="$transport" as_author -- gh pr comment 5 --repo o/r --body '@codex review' > /dev/null 2>"$WORKDIR/err" || rc=$?
  if [ "$rc" -ne 0 ] && grep -q 'canonical\|reserved review command' "$WORKDIR/err" && log_lacks 'POST' && log_lacks $'pr\tcomment'; then
    pass "$transport: genuine command without canonical authorization is refused"
  else
    fail "$transport unauthorized command: rc=$rc"; cat "$LOGF" >&2
  fi
done

# ---------------------------------------------------------------------------
# the brokered placeholder is still refused before the transport is chosen
# ---------------------------------------------------------------------------
new_case
set +e
err="$(CLAUDE_CODE_REMOTE=true GITHUB_TOKEN='' GH_TOKEN=proxy-injected STUB_NO_KEYRING=1 PATH="$STUB_DIR:$PATH" GH_CALLS_LOG="$LOGF" STUB_STATE="$STATE" bash "$AUTHOR" -- gh pr comment 5 --repo o/r --body x 2>&1 >/dev/null)"; rc=$?
set -e
if [ "$rc" -eq 3 ] && log_lacks 'POST' && log_lacks $'pr\tcomment'; then
  pass "cloud session with only the proxy placeholder: refused before any write, on either transport"
else
  fail "placeholder on cloud: rc=$rc err=$err"; cat "$LOGF" >&2
fi

# #2335: the exact observation-filer command runs as one REST issue create,
# then verifies the author and requested state through an independent GET.
ISSUE_BODY="$WORKDIR/observation-body.md"
printf '%s\n\n' 'Advisory observation: "quoted" text and café.' >"$ISSUE_BODY"
new_case
set +e
out="$(MERGEPATH_GH_TRANSPORT=rest as_author -- gh issue create --repo o/r \
  --title '[Post-Review] observation' --body-file "$ISSUE_BODY" \
  --label post-review --label observation --assignee nathanjohnpayne 2>"$WORKDIR/err")"; rc=$?
set -e
if [ "$rc" = 0 ] && [ "$out" = https://github.com/o/r/issues/42 ] \
   && log_has $'POST\trepos/o/r/issues\t--input\t' && log_has $'gh\tapi\trepos/o/r/issues/42' \
   && log_token_clean ghp_author-token \
   && jq -e --rawfile body "$ISSUE_BODY" '.body==$body and .title=="[Post-Review] observation"
      and ([.labels[].name]|sort)==["observation","post-review"]
      and [.assignees[].login]==["nathanjohnpayne"]' "$STATE/created-issue.json" >/dev/null; then
  pass "#2335: exact observation-filer issue create uses REST, preserves body bytes and verifies readback"
else fail "#2335: observation issue create rc=$rc out=$out"; cat "$WORKDIR/err" >&2; fi

# GitHub preserves existing label/login display case. Only metadata names
# normalize; the author, number, title and exact body still have their fences.
for metadata_mode in mixed-case wrong-assignee; do
  new_case
  set +e
  out="$(STUB_ISSUE_METADATA_UPCASE=1 \
    STUB_ISSUE_READBACK_ASSIGNEE="$( [ "$metadata_mode" != wrong-assignee ] || printf 'OtherUser' )" \
    MERGEPATH_GH_TRANSPORT=rest as_author -- gh issue create --repo o/r \
      --title '[Post-Review] observation' --body-file "$ISSUE_BODY" \
      --label post-review --label observation --assignee nathanjohnpayne 2>"$WORKDIR/err")"; rc=$?
  set -e
  if [ "$(grep -c $'POST\trepos/o/r/issues\t' "$LOGF")" = 1 ] \
     && log_has $'gh\tapi\trepos/o/r/issues/42' \
     && { { [ "$metadata_mode" = mixed-case ] && [ "$rc" = 0 ] && [ "$out" = https://github.com/o/r/issues/42 ]; } \
          || { [ "$metadata_mode" = wrong-assignee ] && [ "$rc" = 5 ]; }; }; then
    pass "#2335: $metadata_mode metadata readback honors case but retains requested identity"
  else fail "#2335: $metadata_mode metadata readback rc=$rc out=$out"; cat "$WORKDIR/err" >&2; fi
done

for mode in wrong-author unreadable changed-metadata bad-response api-failure; do
  new_case
  set +e
  out="$(STUB_ISSUE_READBACK_LOGIN="$( [ "$mode" != wrong-author ] || printf 'claude[bot]' )" \
    STUB_ISSUE_READBACK_FAIL="$( [ "$mode" != unreadable ] || printf 1 )" \
    STUB_ISSUE_DROP_LABELS="$( [ "$mode" != changed-metadata ] || printf 1 )" \
    STUB_ISSUE_BAD_RESPONSE="$( [ "$mode" != bad-response ] || printf 1 )" \
    STUB_CREATE_FAIL="$( [ "$mode" != api-failure ] || printf 1 )" \
    MERGEPATH_GH_TRANSPORT=rest as_author -- gh issue create --repo o/r \
      --title observation --body-file "$ISSUE_BODY" --label post-review 2>"$WORKDIR/err")"; rc=$?
  set -e
  if [ "$rc" != 0 ] && [ "$(grep -c $'POST\trepos/o/r/issues\t' "$LOGF")" = 1 ]; then
    case "$mode" in
      api-failure) [ "$rc" = 1 ] && log_lacks $'gh\tapi\trepos/o/r/issues/42' ;;
      *) [ "$rc" = 5 ] ;;
    esac && pass "#2335: $mode refuses without a duplicate create" || fail "#2335: $mode unexpected rc=$rc"
  else fail "#2335: $mode must refuse after one attempted create (rc=$rc)"; fi
 done

for variant in no-repo no-title no-body stdin-body extra-flag bad-assignee; do
  new_case
  args=(--repo o/r --title observation --body-file "$ISSUE_BODY")
  case "$variant" in
    no-repo) args=(--title observation --body-file "$ISSUE_BODY") ;;
    no-title) args=(--repo o/r --body-file "$ISSUE_BODY") ;;
    no-body) args=(--repo o/r --title observation) ;;
    stdin-body) args=(--repo o/r --title observation --body-file -) ;;
    extra-flag) args+=(--web) ;;
    bad-assignee) args+=(--assignee @me) ;;
  esac
  set +e
  MERGEPATH_GH_TRANSPORT=rest as_author -- gh issue create "${args[@]}" >"$WORKDIR/out" 2>"$WORKDIR/err"; rc=$?
  set -e
  if [ "$rc" != 0 ] && log_lacks $'POST\trepos/o/r/issues\t'; then
    pass "#2335: $variant grammar refuses before create"
  else fail "#2335: $variant must refuse before write (rc=$rc)"; fi
 done

echo ""
echo "test_gh_rest_transport: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
