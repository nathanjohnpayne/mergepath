#!/usr/bin/env bash
# scripts/lib/gh-rest-transport.sh — run the guarded gh write verbs as REST
# calls and read each write's byline back (#1057 item A, #1542).
#
# Why. Every `gh pr` and `gh issue` subcommand is a GraphQL call. The Claude
# cloud GitHub proxy refuses GraphQL whatever credential the request carries,
# while `gh api` REST calls pass (measured 2026-10-04 on #1601). So the write
# wrappers (scripts/gh-as-author.sh, scripts/gh-as-reviewer.sh) have two
# transports for the same payload:
#
#   gh    the wrapped command runs through gh, as it always has (local default)
#   rest  the wrapper runs the same write as REST calls under the verified
#         token, reads the written object's byline back, and prints what gh
#         prints on success (the created object's URL); the wrapped gh
#         command itself never runs (cloud default)
#
# gh_transport_select picks one. MERGEPATH_GH_TRANSPORT=gh|rest|auto (default
# auto): auto is rest on a cloud surface (MERGEPATH_AGENT_SURFACE claude-cloud
# or codex-cloud, or CLAUDE_CODE_REMOTE=true with the surface unset) and gh
# everywhere else. Codex cloud takes rest too, for the byline readback the gh
# transport does not do; its PreToolUse guards (.codex/hooks.json) still run
# before the wrapper, as Claude's do.
#
# Closed grammar. The rest transport accepts one canonical argv shape per
# verb and refuses anything else before any write, naming the form it does
# accept. Options are long options only, `--name value` or `--name=value`; N
# is a pull request or issue number; --repo is OWNER/REPO with no host and is
# required, so no git remote or GH_REPO chooses the destination of a write.
#
#   gh pr create --repo OWNER/REPO --title T (--body B | --body-file F)
#                [--head BRANCH] [--base BRANCH] [--draft]
#                [--label L]... [--reviewer USER]... [--assignee USER]...
#   gh pr comment N --repo OWNER/REPO (--body B | --body-file F)
#   gh pr review N --repo OWNER/REPO (--approve | --comment | --request-changes)
#                [--body B | --body-file F]
#   gh pr edit N --repo OWNER/REPO [--title T] [--body B | --body-file F]
#                [--base BRANCH] [--add-label L]... [--remove-label L]...
#                [--add-reviewer USER]... [--remove-reviewer USER]...
#                [--add-assignee USER]... [--remove-assignee USER]...
#   gh pr close N --repo OWNER/REPO [--comment TEXT] [--delete-branch]
#   gh issue comment N --repo OWNER/REPO (--body B | --body-file F)
#   gh issue create --repo OWNER/REPO --title T --body-file F
#                   [--label L]... [--assignee USER]...
#
# --head defaults to the checked-out branch, qualified owner:branch when its
# push remote is another repository (a fork), and is refused when the branch
# has no push remote; --base defaults to the branch's gh-merge-base, then the
# repository's default branch, as gh does. --delete-branch deletes the remote
# head ref only: gh skips the local branch whenever --repo is given, and this
# grammar always takes --repo. Repeatable options also take comma-separated
# values, as gh does. Refused: short options, --web, --editor, --edit-last,
# --create-if-none, @me, org/team reviewers, `--body-file -`, a URL or branch
# where N is expected, and any option not listed. Every other `gh pr …` or
# `gh issue …` form is refused the same way, except `gh pr merge` (below).
#
# Readback. Each write is correlated to the object it created or the event it
# produced, and the byline must be the expected login, or the wrapper exits 5
# with the #241 recovery text:
#
#   create    GET pulls/N .user.login (the #241 re-read), then the actor of
#             every labeled / review_requested / assigned event the
#             follow-up writes produced
#   comment   the POST response's .user.login (the response is this comment)
#   review    the POST response's .user.login (the response is this review)
#   edit      the issue events the edit produced, found by id against a read
#             taken before the write: renamed (title), base_ref_changed
#             (base), labeled / unlabeled, review_requested /
#             review_request_removed, assigned / unassigned. A no-op (a label
#             already present, an unchanged title) is dropped first, because
#             it produces no event. A body-only edit produces no event and
#             REST does not attribute it: the wrapper says so instead of
#             claiming it verified.
#   close     the closed event's actor; a --comment is a comment (above);
#             --delete-branch deletes the head ref, which is not attributable,
#             and the wrapper says so
#
# A new event of the expected kind by any other login fails the readback: a
# concurrent write by the expected login beside a bot-attributed one cannot
# be told apart from a wrong-byline write, and must not be (#1542). GitHub
# may record an event a moment after the write that produced it, so a missing
# event is re-read (MERGEPATH_GH_READBACK_ATTEMPTS, default 5, 1 to 20;
# MERGEPATH_GH_READBACK_DELAY seconds apart, default 2, 0 to 30) before it is
# reported as unattributed. An event by the wrong login fails at once.
#
# `gh pr merge` is refused on this transport with exit 6, the ceiling code:
# the gates that keep a merge honest (merge-writer.py, merge-clearance-gate.sh
# and gh-pr-guard.sh's merge branch) read GraphQL, and a REST merge that
# skipped them would not be the same merge. Every spelling the shared merge
# classifier (scripts/workflow/owner-admin-override.py) recognizes is refused
# the same way: options before the group, the REST merge endpoint, and a
# GraphQL merge mutation through `gh api`. Any other option before the command
# group is refused too. Park a merge with scripts/post-local-agent-handback.sh. Any other inspectable `gh api`
# payload passes through under the verified token: a REST endpoint runs as it
# is, and a GraphQL payload with exactly one literal query stays GraphQL (the
# classifier refuses an opaque or multi-query one). Any other command of gh's
# own groups passes through unchanged. On Claude cloud the proxy refuses any
# GraphQL call with its own message.
#
# gh_payload_refuse_credential_overrides is transport-independent: it refuses
# the caller-supplied arguments that could send the verified token elsewhere
# or replace it (a command outside gh's own groups, --hostname, a repository
# value that is not a plain OWNER/REPO, a host-qualified repository or URL on
# another host, an `api` endpoint on another host, an Authorization header on
# `gh api`), the #1542 inputs that only argv and environment inspection can
# bound.
#
# Needs gh 2.48 or later, for `gh api --paginate --slurp` (cli/cli#8620), and
# jq. gh_rest_require_slurp checks it before a write whose attribution reads
# the issue events (#2233). Bash 3.2 portable; no top-level side effects beyond
# defining functions and constants.
#
# shellcheck disable=SC2016  # $name inside single quotes is a jq variable, bound by --arg/--argjson

GH_REST_MERGE_CEILING_EXIT=6
GH_REST_TMPDIR=""
GH_REST_LABEL="gh-rest-transport"
GH_REST_EXPECTED=""
GH_REST_TOKEN=""
GH_REST_GH_BIN=""
GH_REST_PAYLOAD_GH=""
GH_REST_WROTE=0
GH_REST_FORM=""
GH_REST_BODY_FILE=""
GH_REST_BODY_SET=0
GH_REST_ARGS=()
GH_REST_I=0
GH_REST_OPT=""
GH_REST_VAL=""
GH_REST_HASVAL=0
GH_REST_VERIFIED=""
GH_REST_DONE=" "
GH_REST_REMOVED_LABELS=""
GH_REST_DEFAULT_HEAD=""
GH_REST_DEFAULT_HEAD_REPO=""
GH_REST_SLURP_OK=""

# --- transport selection ------------------------------------------------------

gh_transport_select() {
  local mode="${MERGEPATH_GH_TRANSPORT:-auto}"
  case "$mode" in
    gh|rest) printf '%s\n' "$mode"; return 0 ;;
    auto) ;;
    *)
      echo "gh-transport: MERGEPATH_GH_TRANSPORT must be auto, gh or rest (got '$mode'); refusing to guess a transport." >&2
      return 1
      ;;
  esac
  # The surface variable wins when set, as it does for the capability probe.
  case "${MERGEPATH_AGENT_SURFACE:-}" in
    claude-cloud|codex-cloud) printf 'rest\n'; return 0 ;;
    local|ci) printf 'gh\n'; return 0 ;;
    '') ;;
    *)
      echo "gh-transport: MERGEPATH_AGENT_SURFACE must be local, claude-cloud, codex-cloud or ci (got '$MERGEPATH_AGENT_SURFACE'); refusing to guess a transport." >&2
      return 1
      ;;
  esac
  if [ "${CLAUDE_CODE_REMOTE:-}" = "true" ]; then
    printf 'rest\n'
  else
    printf 'gh\n'
  fi
}

# --- caller-supplied credential re-routing (#1542) ----------------------------

# gh_payload_is_hosted_repo <value>: 0 iff <value> is the HOST/OWNER/REPO form
# gh reads as a repository on HOST: exactly three non-empty segments, whose
# host contains a dot once any userinfo and port are removed. gh strips the
# port before it picks a credential, and userinfo before the host reaches the
# request, so github.localhost:443/o/r and x@tenant.ghe.com/o/r target those
# hosts with GH_TOKEN (Phase 4b on #2178). Every host gh sends GH_TOKEN to
# (github.com, *.ghe.com, github.localhost) has a dot; a dotless host gets the
# Enterprise sentinel. A host with whitespace makes no request, but OWNER and
# REPO may hold any character but '/', since the request still goes to the
# host.
gh_payload_is_hosted_repo() {
  local host
  [[ "$1" =~ ^([^/[:space:]]+)/[^/]+/[^/]+$ ]] || return 1
  host="${BASH_REMATCH[1]##*@}"
  host="${host%%:*}"
  [[ "$host" =~ [A-Za-z0-9-]\.[A-Za-z0-9-] ]]
}

# gh_payload_is_canonical_repo <value>: 0 iff <value> is a plain OWNER/REPO.
# A repository value is held to this allowlist rather than screened for bad
# shapes: gh also reads git@HOST:OWNER/REPO, URLs and HOST/OWNER/REPO there,
# and a screen that misses one form sends the verified token to that host
# (Phase 4b on #2178). Anything else can only be over-refused.
gh_payload_is_canonical_repo() {
  [[ "$1" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]
}

# gh_payload_is_foreign_url <value>: 0 iff <value> begins with a URL whose
# host is not GitHub's own (github.com, www.github.com, api.github.com).
# gh reads a repository selector as a URL when it starts with git@ or with
# one of the schemes https:, http:, ssh:, git:, git+ssh: and git+https:, and
# a pull request or issue selector when it starts with http(s)://. It then
# takes the destination host from it, and sends GH_TOKEN to github.localhost
# and *.ghe.com as well as github.com. So every scheme form counts, for every
# command, not only the pull request and issue URLs of the commands this
# transport implements (Phase 4b on #2178). The host is what follows the
# last '@' of the authority, without a port, compared case-insensitively.
gh_payload_is_foreign_url() {
  local host
  if [[ "$1" =~ ^[Gg][Ii][Tt]@([^:/]*): ]]; then
    host="${BASH_REMATCH[1]}"
  elif [[ "$1" =~ ^[A-Za-z][A-Za-z0-9+.-]*://([^/?#]*) ]]; then
    host="${BASH_REMATCH[1]}"
  elif [[ "$1" =~ ^([Hh][Tt][Tt][Pp][Ss]?|[Ss][Ss][Hh]|[Gg][Ii][Tt]|[Gg][Ii][Tt]\+[Ss][Ss][Hh]|[Gg][Ii][Tt]\+[Hh][Tt][Tt][Pp][Ss]):([^/?#]*) ]]; then
    host="${BASH_REMATCH[2]}"
  else
    return 1
  fi
  host="${host##*@}"
  host="${host%%:*}"
  host="$(printf '%s' "$host" | tr '[:upper:]' '[:lower:]')"
  case "$host" in
    github.com|www.github.com|api.github.com) return 1 ;;
  esac
  return 0
}

# gh_payload_refuse_credential_overrides <label> <gh argv...>
# Exit 0 when argv carries none of the arguments that would send the verified
# token to another host or replace it; otherwise explain and exit 1.
#
# Every argument is checked on its own, whatever precedes it. Following which
# options consume the next argument would mean enumerating gh's value-taking
# options, and an argument the enumeration misses shifts every later one:
# `--preview --header --header 'Authorization: ...'` hid the real header from
# a positional check (Codex on #2178). Checking each argument by its shape
# instead can only over-refuse, never miss.
gh_payload_refuse_credential_overrides() {
  local label="$1" is_api=0 arg prev="" value
  shift
  case "${1:-}" in gh|*/gh) ;; *) return 0 ;; esac
  shift
  # The command must be one of gh's own command groups. An alias or an
  # extension runs under the verified token and expands where the checks
  # below cannot see it (a shell alias or an extension binary receives the
  # token itself); neither can shadow a built-in name, so an allowlist of
  # built-in groups closes both. gh also takes the repository flag before
  # the group (gh -R O/R pr merge N), and both alias expansion and extension
  # dispatch read only the first argument, so a leading --repo or -R and its
  # value are skipped; the value is checked below like any other. Any other
  # leading option is refused, since gh may take the argument after it as
  # its value and the one after that as the command.
  local -a cmd_args=("$@")
  local k=0
  while [ "$k" -lt "${#cmd_args[@]}" ]; do
    case "${cmd_args[$k]}" in
      --repo|-R) k=$((k + 2)) ;;
      --repo=*|-R?*) k=$((k + 1)) ;;
      *) break ;;
    esac
  done
  case "${cmd_args[$k]:-}" in
    api|cache|gist|issue|label|org|pr|project|release|repo|ruleset|run|search|secret|status|variable|workflow) ;;
    *)
      echo "$label: refusing 'gh ${cmd_args[$k]:-}': the wrappers run only gh's own command groups (api, issue, pr, repo, run, secret, variable, workflow and the like), optionally after --repo/-R. An alias, an extension or a command behind another leading option would run under the verified token where these checks cannot see it (#1542)." >&2
      return 1
      ;;
  esac
  if [ -n "${GH_REPO:-}" ] && ! gh_payload_is_canonical_repo "$GH_REPO"; then
    echo "$label: refusing an inherited GH_REPO ('$GH_REPO') that is not a plain OWNER/REPO: gh could take a host from it and send the verified token there; unset it and pass --repo OWNER/REPO (#1542)." >&2
    return 1
  fi
  for arg in "$@"; do
    [ "$arg" != "api" ] || is_api=1
  done
  for arg in "$@"; do
    case "$arg" in
      --hostname|--hostname=*)
        echo "$label: refusing --hostname: guarded writes go to github.com only, where the token was verified (#1542)." >&2
        return 1
        ;;
    esac
    # A repository value in every form gh accepts: --repo=V, -RV, -R=V, a
    # short-option cluster ending in R (-wRV), and the argument after --repo,
    # -R or such a cluster. Each must be a plain OWNER/REPO.
    value=""
    case "$arg" in
      --repo=*) value="${arg#--repo=}" ;;
      -R?*) value="${arg#-R}"; value="${value#=}" ;;
      *)
        if [[ "$arg" =~ ^-[A-Za-z]+R(.*)$ ]]; then
          value="${BASH_REMATCH[1]}"
          value="${value#=}"
        fi
        ;;
    esac
    if [ "$prev" = "--repo" ] || [[ "$prev" =~ ^-[A-Za-z]*R$ ]]; then
      value="$arg"
    fi
    if [ -n "$value" ] && ! gh_payload_is_canonical_repo "$value"; then
      echo "$label: refusing the repository '$value': guarded writes take a plain OWNER/REPO only, because gh could take a host from any other form and send the verified token there (#1542)." >&2
      return 1
    fi
    if gh_payload_is_hosted_repo "$arg"; then
      echo "$label: refusing the host-qualified repository '$arg': whatever option it belongs to, gh could send the verified token to that host; pass OWNER/REPO (#1542)." >&2
      return 1
    fi
    # A repository, pull request or issue URL is a selector for any gh
    # command these wrappers pass through: gh takes the destination host from
    # it. Checked by shape in every position, like the rest, so an argument
    # that only begins with such a URL is refused too; text goes through
    # --body-file.
    if gh_payload_is_foreign_url "$arg"; then
      echo "$label: refusing the URL '$arg' on a host other than github.com: gh can take the destination host from a repository, pull request or issue URL and would send the verified token there; select with --repo OWNER/REPO, and pass text that begins with a URL through --body-file (#1542)." >&2
      return 1
    fi
    if [ "$is_api" -eq 1 ]; then
      # The header value as gh would read it: after --header=, or after the
      # H of a short-option cluster (-H=, -HX, -iHX), with an optional '='.
      case "$arg" in
        --header=*) value="${arg#--header=}" ;;
        --*) value="$arg" ;;
        -*H*) value="${arg#*H}"; value="${value#=}" ;;
        *) value="$arg" ;;
      esac
      if [[ "$value" =~ ^[[:space:]]*[Aa][Uu][Tt][Hh][Oo][Rr][Ii][Zz][Aa][Tt][Ii][Oo][Nn][[:space:]]*: ]]; then
        echo "$label: refusing an explicit Authorization header: gh would send it in place of the verified token (#1542)." >&2
        return 1
      fi
      case "$arg" in
        [Hh][Tt][Tt][Pp]://*|[Hh][Tt][Tt][Pp][Ss]://*)
          case "$arg" in
            https://api.github.com/*|https://api.github.com) ;;
            *)
              echo "$label: refusing an api endpoint on another host ('$arg'): guarded writes go to api.github.com only (#1542)." >&2
              return 1
              ;;
          esac
          ;;
      esac
    fi
    prev="$arg"
  done
  return 0
}

# --- plumbing -------------------------------------------------------------------

gh_rest_cleanup() {
  if [ -n "${GH_REST_TMPDIR:-}" ] && [ -d "$GH_REST_TMPDIR" ]; then
    rm -rf "$GH_REST_TMPDIR"
  fi
  GH_REST_TMPDIR=""
}

gh_rest_err() {
  printf '%s: %s\n' "$GH_REST_LABEL" "$*" >&2
}

# A refusal before any write: the message, then the one form this verb takes.
gh_rest_refuse() { # <message>
  gh_rest_err "$1"
  gh_rest_err "  the REST transport accepts exactly: $GH_REST_FORM"
  gh_rest_err "  (long options only, --name value or --name=value; see scripts/lib/gh-rest-transport.sh)"
  return 1
}

gh_rest_recovery() { # <what> <url>
  gh_rest_err "This is the #241 mis-attribution class: the effective token did not write as the intended login."
  gh_rest_err "Recovery: remove $1 at $2 and retry with a user-held token for $GH_REST_EXPECTED."
  gh_rest_err "See REVIEW_POLICY.md, Recovery: PR created under the wrong identity."
}

gh_rest_trace_marker() {
  [ -n "${GH_REST_TRACE_MARKER:-}" ] || return 0
  if ! : >"$GH_REST_TRACE_MARKER"; then
    gh_rest_err "cannot write the trace marker $GH_REST_TRACE_MARKER; refusing to run the write unrecorded."
    return 70
  fi
  return 0
}

# Run gh under the verified token and nothing else: GITHUB_TOKEN is unset so
# it cannot shadow GH_TOKEN, and both Enterprise variables carry the
# resolver's non-credential sentinel (see gh-token-resolver.sh). GH_HOST is
# pinned to github.com, where the token was verified: with GH_HOST unset, gh
# targets the only host in its hosts file, and it sends GH_TOKEN to
# github.localhost and *.ghe.com hosts as well (Phase 4b on #2178).
gh_rest_exec_gh() {
  (
    unset GITHUB_TOKEN
    GH_HOST=github.com GH_TOKEN="$GH_REST_TOKEN" \
      GH_ENTERPRISE_TOKEN="${GH_WRAPPER_NO_ENTERPRISE_CREDENTIAL:-mergepath-guarded-write-github-com-only}" \
      GITHUB_ENTERPRISE_TOKEN="${GH_WRAPPER_NO_ENTERPRISE_CREDENTIAL:-mergepath-guarded-write-github-com-only}" \
      "$GH_REST_GH_BIN" "$@"
  )
}

# gh_rest_api <GET|PAGINATE|POST|PATCH|PUT|DELETE> <endpoint> [input-file]
# Response body on stdout; gh's diagnostics stay on stderr. The first
# mutating call writes the trace marker, after every check has passed.
gh_rest_api() {
  local method="$1" endpoint="$2" input="${3:-}"
  case "$method" in
    GET) gh_rest_exec_gh api "$endpoint" ;;
    PAGINATE) gh_rest_exec_gh api --paginate --slurp "$endpoint" ;;
    *)
      if [ "$GH_REST_WROTE" -eq 0 ]; then
        gh_rest_trace_marker || return $?
        GH_REST_WROTE=1
      fi
      if [ -n "$input" ]; then
        gh_rest_exec_gh api --method "$method" "$endpoint" --input "$input"
      else
        gh_rest_exec_gh api --method "$method" "$endpoint"
      fi
      ;;
  esac
}

# gh_rest_text_file <text>: a private file holding <text> exactly. Bodies reach
# jq through it (--rawfile), never as an argument: one argument is limited to
# about 128 KiB, which a multibyte body near GitHub's limit can exceed.
gh_rest_text_file() {
  local file
  file="$(umask 077; mktemp "$GH_REST_TMPDIR/text.XXXXXX")" || return 1
  printf '%s' "$1" >"$file" || return 1
  printf '%s\n' "$file"
}

# gh_rest_json_file <jq args...>: a private file holding `jq -n <args>`.
gh_rest_json_file() {
  local file
  file="$(umask 077; mktemp "$GH_REST_TMPDIR/body.XXXXXX")" || return 1
  jq -n "$@" >"$file" || return 1
  printf '%s\n' "$file"
}

gh_rest_uri() { # <text> -> percent-encoded
  jq -rn --arg s "$1" '$s | @uri'
}

# Newline-separated items -> a sorted JSON array of the non-empty ones.
gh_rest_lines_json() {
  printf '%s\n' "${1:-}" | jq -Rn '[inputs | select(length > 0)] | unique'
}

gh_rest_split_csv() { # <value> -> one item per line
  printf '%s\n' "$1" | tr ',' '\n' | sed '/^[[:space:]]*$/d'
}

# gh reads repeatable values (labels, reviewers, assignees) as CSV, so a
# quoted field can hold a comma ('"area,backend"' is one label). Splitting on
# every comma would name the wrong labels, so a quoted value is refused
# before any write.
gh_rest_check_csv() { # <option> <value>
  case "$2" in
    *'"'*)
      gh_rest_refuse "a quoted value for $1 ('$2') is not accepted: pass each name in its own $1, without quotes"
      return 1
      ;;
  esac
  return 0
}

# gh_rest_each <json array> <function> [args...]: call <function> [args...]
# <item> for every element, in the current shell, reading the list on fd 3 so
# an item holding spaces (a label) stays one item and a callee that reads
# stdin (gh) cannot swallow the rest of the list. Stops at the first non-zero
# status and returns it.
gh_rest_each() {
  local list="$1" fn="$2" item rc=0
  shift 2
  while IFS= read -r item <&3; do
    [ -n "$item" ] || continue
    "$fn" "$@" "$item" || { rc=$?; break; }
  done 3<<EOF
$(printf '%s' "$list" | jq -r '.[]')
EOF
  return "$rc"
}

gh_rest_check_login() { # <value> <what>
  case "$1" in
    @me)
      gh_rest_refuse "$2 '@me' is not accepted: name the login" ; return 1 ;;
    */*)
      gh_rest_refuse "$2 '$1' is not accepted: team reviewers are not supported on the REST transport; name a user login" ; return 1 ;;
    ''|*[!A-Za-z0-9-]*|-*|*-)
      gh_rest_refuse "$2 '$1' is not a GitHub login" ; return 1 ;;
  esac
  return 0
}

gh_rest_check_branch() { # <value> <what>
  case "$1" in
    ''|*[[:space:]]*|-*)
      gh_rest_refuse "$2 '$1' is not a branch name" ; return 1 ;;
  esac
  return 0
}

gh_rest_check_repo() { # <value> -> 0 iff OWNER/REPO
  case "$1" in
    ''|*/*/*|/*|*/|*[!A-Za-z0-9._/-]*) ;;
    */*) return 0 ;;
  esac
  gh_rest_refuse "--repo must be OWNER/REPO with no host (got '${1:-nothing}')"
}

# --- argv walking ---------------------------------------------------------------
#
# gh_rest_parse_init "$@" loads the arguments after the verb; each pass of
# gh_rest_opt classifies GH_REST_ARGS[GH_REST_I] into GH_REST_OPT (the long
# option, or empty for a positional) and GH_REST_VAL (the attached value, or
# the positional). gh_rest_value consumes a separate value when none was
# attached; gh_rest_flag refuses an attached value.

gh_rest_parse_init() {
  GH_REST_ARGS=("$@")
  GH_REST_I=0
}

gh_rest_opt() {
  local arg="${GH_REST_ARGS[$GH_REST_I]}"
  GH_REST_HASVAL=0
  case "$arg" in
    --?*=*) GH_REST_OPT="${arg%%=*}"; GH_REST_VAL="${arg#*=}"; GH_REST_HASVAL=1 ;;
    --?*) GH_REST_OPT="$arg"; GH_REST_VAL="" ;;
    -?*)
      GH_REST_OPT="$arg"; GH_REST_VAL=""
      gh_rest_refuse "short option '$arg' is not accepted: use the long form"
      return 1
      ;;
    *) GH_REST_OPT=""; GH_REST_VAL="$arg" ;;
  esac
  return 0
}

gh_rest_value() {
  [ "$GH_REST_HASVAL" -eq 0 ] || return 0
  GH_REST_I=$((GH_REST_I + 1))
  if [ "$GH_REST_I" -ge "${#GH_REST_ARGS[@]}" ]; then
    gh_rest_refuse "option $GH_REST_OPT is missing its value"
    return 1
  fi
  GH_REST_VAL="${GH_REST_ARGS[$GH_REST_I]}"
  return 0
}

gh_rest_flag() {
  if [ "$GH_REST_HASVAL" -eq 1 ]; then
    gh_rest_refuse "option $GH_REST_OPT takes no value"
    return 1
  fi
  return 0
}

gh_rest_number() { # <positional> <current number> -> prints the number
  if [ -n "$2" ]; then
    gh_rest_refuse "unexpected argument '$1'"
    return 1
  fi
  case "$1" in
    ''|*[!0-9]*|0*)
      gh_rest_refuse "'$1' is not a number: name the pull request or issue by number, not by URL or branch"
      return 1
      ;;
  esac
  printf '%s\n' "$1"
}

gh_rest_body_from() { # <--body|--body-file> <value>
  if [ "$GH_REST_BODY_SET" -eq 1 ]; then
    gh_rest_refuse "pass one of --body or --body-file, once"
    return 1
  fi
  # The body is snapshotted into a private file, byte for byte: a later edit
  # of the caller's file cannot change it between check and write, and
  # command substitution would strip its trailing newlines.
  case "$1" in
    --body) GH_REST_BODY_FILE="$(gh_rest_text_file "$2")" || return 1 ;;
    --body-file)
      if [ "$2" = "-" ]; then
        gh_rest_refuse "--body-file - is not accepted: the body is read before the write, so write it to a file first"
        return 1
      fi
      if [ ! -r "$2" ]; then
        gh_rest_refuse "body file is not readable: $2"
        return 1
      fi
      GH_REST_BODY_FILE="$(umask 077; mktemp "$GH_REST_TMPDIR/body.XXXXXX")" || return 1
      cat -- "$2" >"$GH_REST_BODY_FILE" || return 1
      ;;
  esac
  GH_REST_BODY_SET=1
  return 0
}

# --- readback helpers -------------------------------------------------------------

# gh_rest_read_pr <repo> <N> -> the pull request JSON, or exit 1 with a message.
gh_rest_read_pr() {
  local pr
  pr="$(gh_rest_api GET "repos/$1/pulls/$2")" || {
    gh_rest_err "could not read pull request $1#$2; nothing was written."
    return 1
  }
  if ! printf '%s' "$pr" | jq -e '(.number | type == "number") and (.html_url | type == "string") and (.head | type == "object")' >/dev/null 2>&1; then
    gh_rest_err "$1#$2 is not a pull request this token can read; nothing was written."
    return 1
  fi
  printf '%s\n' "$pr"
}

# gh_rest_require_slurp [suffix]: 0 iff this gh has `gh api --slurp` (gh 2.48
# or later), which the issue-event reads need. Checked once per process, and
# called before the first write of every verb whose attribution reads events,
# so an older gh is refused with its cause rather than with "could not read
# the events" after a write already landed (#2233). The help text is captured
# rather than piped to grep -q, whose early exit can fail the pipeline.
gh_rest_require_slurp() {
  local help
  if [ -z "$GH_REST_SLURP_OK" ]; then
    help="$(gh_rest_exec_gh api --help 2>/dev/null)" || help=""
    case "$help" in
      *--slurp*) GH_REST_SLURP_OK=1 ;;
      *) GH_REST_SLURP_OK=0 ;;
    esac
  fi
  [ "$GH_REST_SLURP_OK" = 1 ] && return 0
  gh_rest_err "this gh has no 'gh api --slurp', which the REST transport needs to read the issue events that attribute this write; install gh 2.48 or later.${1:+ $1}"
  return 1
}

# gh_rest_events <repo> <N> -> the issue's events as one flat JSON array.
gh_rest_events() {
  local pages
  gh_rest_require_slurp || return 1
  pages="$(gh_rest_api PAGINATE "repos/$1/issues/$2/events?per_page=100")" || return 1
  printf '%s' "$pages" | jq -ce '[.[][]] | map(select(.id | type == "number"))' 2>/dev/null
}

# gh_rest_new_events <before> <after> -> the events in <after> absent from <before>.
gh_rest_new_events() {
  # Both lists reach jq on stdin: a long event history must not become one
  # oversized argument.
  { printf '%s\n' "$1"; printf '%s\n' "$2"; } | jq -cs \
    '(.[0] | map(.id)) as $before | [.[1][] | select(.id as $i | ($before | index($i)) == null)]'
}

# gh_rest_attribute <new-events> <event> <jq match on the event> <value> <what>
# 0 when every new <event> matching the value was performed by the expected
# login; 1 when none appeared (not attributable); 2 when another login did.
gh_rest_attribute() {
  local actors
  actors="$(printf '%s' "$1" | jq -r --arg t "$2" --arg v "$4" \
    "[.[] | select(.event == \$t) | select($3) | (.actor.login // \"<unknown>\")] | unique | .[]")" || actors=""
  if [ -z "$actors" ]; then
    [ "${GH_REST_QUIET_MISSING:-0}" = 1 ] || gh_rest_err "ERROR could not attribute $5: no $2 event appeared for it."
    return 1
  fi
  if [ "$actors" != "$GH_REST_EXPECTED" ]; then
    gh_rest_err "ERROR $5 landed under '$(printf '%s\n' "$actors" | paste -sd, -)', expected '$GH_REST_EXPECTED'."
    return 2
  fi
  return 0
}

# gh_rest_each callees: the item is always the last argument.
gh_rest_check_login_what() { # <what> <item>
  gh_rest_check_login "$2" "$1"
}

gh_rest_attribute_each() { # <events> <event> <jq match> <what prefix> <item>
  gh_rest_attribute "$1" "$2" "$3" "$5" "$4 '$5'" || return $?
  GH_REST_VERIFIED="$GH_REST_VERIFIED $2:$5,"
  return 0
}

# gh_rest_worse <a> <b>: the worse of two readback statuses (2 beats 1 beats 0).
gh_rest_worse() {
  if [ "$1" -eq 2 ] || [ "$2" -eq 2 ]; then echo 2
  elif [ "$1" -eq 1 ] || [ "$2" -eq 1 ]; then echo 1
  else echo 0; fi
}

# gh_rest_readback <repo> <N> <events before the write, or "" for all> <checker>
# Reads the issue events, keeps those absent from <before>, and calls
# <checker> <events>, which returns 0 (attributed), 1 (an expected event is
# missing) or 2 (an event by another login). A missing event is re-read, since
# GitHub may record it a moment after the write; the last attempt reports it.
# Returns the checker's status, or 3 when the events cannot be read.
gh_rest_readback() {
  local repo="$1" number="$2" before="$3" checker="$4"
  local attempts="${MERGEPATH_GH_READBACK_ATTEMPTS:-5}" delay="${MERGEPATH_GH_READBACK_DELAY:-2}"
  local attempt=1 after events rc
  case "$attempts" in ''|*[!0-9]*) attempts=5 ;; esac
  { [ "$attempts" -ge 1 ] && [ "$attempts" -le 20 ]; } || attempts=5
  case "$delay" in ''|*[!0-9]*) delay=2 ;; esac
  [ "$delay" -le 30 ] || delay=2
  while :; do
    after="$(gh_rest_events "$repo" "$number")" || return 3
    if [ -n "$before" ]; then
      events="$(gh_rest_new_events "$before" "$after")" || events="[]"
    else
      events="$after"
    fi
    GH_REST_VERIFIED=""
    GH_REST_QUIET_MISSING=0
    [ "$attempt" -ge "$attempts" ] || GH_REST_QUIET_MISSING=1
    rc=0
    "$checker" "$events" || rc=$?
    GH_REST_QUIET_MISSING=0
    if [ "$rc" -ne 1 ] || [ "$attempt" -ge "$attempts" ]; then
      return "$rc"
    fi
    sleep "$delay"
    attempt=$((attempt + 1))
  done
}

# Checkers for gh_rest_readback. Each reads its caller's locals (bash scopes
# a function's locals dynamically into the functions it calls).
gh_rest_check_create_events() { # <events>
  local ev="$1" worst=0 r
  r=0; gh_rest_each "$labels_json" gh_rest_attribute_each "$ev" labeled '(.label.name | ascii_downcase) == ($v | ascii_downcase)' "the label" || r=$?; worst=$(gh_rest_worse "$worst" "$r")
  r=0; gh_rest_each "$reviewers_json" gh_rest_attribute_each "$ev" review_requested '(.requested_reviewer.login | ascii_downcase) == ($v | ascii_downcase)' "the review request to" || r=$?; worst=$(gh_rest_worse "$worst" "$r")
  r=0; gh_rest_each "$assignees_json" gh_rest_attribute_each "$ev" assigned '(.assignee.login | ascii_downcase) == ($v | ascii_downcase)' "the assignment to" || r=$?; worst=$(gh_rest_worse "$worst" "$r")
  return "$worst"
}

gh_rest_check_edit_events() { # <events>
  local ev="$1" worst=0 r
  if [ "$title_op" -eq 1 ]; then
    r=0; gh_rest_attribute "$ev" renamed '.rename.to == $v' "$title" "the title edit" || r=$?
    [ "$r" -ne 0 ] || GH_REST_VERIFIED="$GH_REST_VERIFIED title,"
    worst=$(gh_rest_worse "$worst" "$r")
  fi
  if [ "$base_op" -eq 1 ]; then
    r=0; gh_rest_attribute "$ev" base_ref_changed 'true' "" "the base edit" || r=$?
    [ "$r" -ne 0 ] || GH_REST_VERIFIED="$GH_REST_VERIFIED base,"
    worst=$(gh_rest_worse "$worst" "$r")
  fi
  r=0; gh_rest_each "$add_labels_json" gh_rest_attribute_each "$ev" labeled '(.label.name | ascii_downcase) == ($v | ascii_downcase)' "the label" || r=$?; worst=$(gh_rest_worse "$worst" "$r")
  r=0; gh_rest_each "$remove_labels_json" gh_rest_attribute_each "$ev" unlabeled '(.label.name | ascii_downcase) == ($v | ascii_downcase)' "removing the label" || r=$?; worst=$(gh_rest_worse "$worst" "$r")
  r=0; gh_rest_each "$add_reviewers_json" gh_rest_attribute_each "$ev" review_requested '(.requested_reviewer.login | ascii_downcase) == ($v | ascii_downcase)' "the review request to" || r=$?; worst=$(gh_rest_worse "$worst" "$r")
  r=0; gh_rest_each "$remove_reviewers_json" gh_rest_attribute_each "$ev" review_request_removed '(.requested_reviewer.login | ascii_downcase) == ($v | ascii_downcase)' "removing the review request to" || r=$?; worst=$(gh_rest_worse "$worst" "$r")
  r=0; gh_rest_each "$add_assignees_json" gh_rest_attribute_each "$ev" assigned '(.assignee.login | ascii_downcase) == ($v | ascii_downcase)' "the assignment to" || r=$?; worst=$(gh_rest_worse "$worst" "$r")
  r=0; gh_rest_each "$remove_assignees_json" gh_rest_attribute_each "$ev" unassigned '(.assignee.login | ascii_downcase) == ($v | ascii_downcase)' "unassigning" || r=$?; worst=$(gh_rest_worse "$worst" "$r")
  return "$worst"
}

gh_rest_check_close_events() { # <events>
  gh_rest_attribute "$1" closed 'true' "" "closing PR #$number"
}

gh_rest_check_branch_delete_events() { # <events>
  gh_rest_attribute "$1" head_ref_deleted 'true' "" "deleting branch $head_ref"
}

# gh_rest_partial_failure <repo> <N> <events before, or ""> <url> <checker>
#                         [<unattributed write> [<evented: 1|0>]]
# After a write sequence stopped partway, the writes that landed must still be
# attributed. First the writes known to have succeeded must show their
# expected-login events, through <checker> and gh_rest_readback, which the
# caller has narrowed to those writes: a missing, foreign or unreadable event
# is unattributed (Codex on #2178). Then, because the write that failed may
# have landed anyway, the new events of every kind these verbs produce are
# scanned for an actor other than the expected login. Returns 5 when either
# check fails, 1 when both pass. A write that landed but produces no event (a
# body edit) is named as unattributed on every path rather than folded into
# the attributed ones, and <evented> 0 says no evented write landed at all, so
# the closing line claims no attribution (Codex on #2178).
gh_rest_partial_failure() {
  local repo="$1" number="$2" before="$3" url="$4" checker="$5" unattributed="${6:-}" evented="${7:-1}" positive=0
  [ -z "$unattributed" ] || gh_rest_err "note: $unattributed landed before the failure and is not attributable over REST (no event records who edited a body); nothing here verified its byline."
  gh_rest_readback "$repo" "$number" "$before" "$checker" || positive=$?
  if [ "$positive" -ne 0 ]; then
    [ "$positive" -ne 3 ] || gh_rest_err "ERROR the events of PR #$number could not be read."
    gh_rest_err "ERROR the writes that succeeded before the failure are not attributed to '$GH_REST_EXPECTED'."
    gh_rest_recovery "those changes" "$url"
    return 5
  fi
  local attempts="${MERGEPATH_GH_READBACK_ATTEMPTS:-5}" delay="${MERGEPATH_GH_READBACK_DELAY:-2}"
  local attempt=1 after events wrong
  case "$attempts" in ''|*[!0-9]*) attempts=5 ;; esac
  { [ "$attempts" -ge 1 ] && [ "$attempts" -le 20 ]; } || attempts=5
  case "$delay" in ''|*[!0-9]*) delay=2 ;; esac
  [ "$delay" -le 30 ] || delay=2
  while :; do
    after="$(gh_rest_events "$repo" "$number")" || {
      gh_rest_err "ERROR the events of PR #$number could not be read, so the writes that landed before the failure are unattributed."
      gh_rest_recovery "any change those writes made" "$url"
      return 5
    }
    if [ -n "$before" ]; then
      events="$(gh_rest_new_events "$before" "$after")" || events="[]"
    else
      events="$after"
    fi
    wrong="$(printf '%s' "$events" | jq -r --arg me "$GH_REST_EXPECTED" '
      ["labeled","unlabeled","review_requested","review_request_removed","assigned","unassigned","renamed","base_ref_changed","closed"] as $kinds
      | [.[] | select(.event as $e | ($kinds | index($e)) != null)
             | select((.actor.login // "<unknown>") != $me)
             | "\(.event) by \(.actor.login // "<unknown>")"] | unique | join(", ")')" || wrong="unreadable events"
    if [ -n "$wrong" ]; then
      gh_rest_err "ERROR writes that landed before the failure are attributed to another login: $wrong (expected '$GH_REST_EXPECTED')."
      gh_rest_recovery "those changes" "$url"
      return 5
    fi
    [ "$attempt" -lt "$attempts" ] || break
    sleep "$delay"
    attempt=$((attempt + 1))
  done
  if [ "$evented" = "0" ]; then
    gh_rest_err "no write that GitHub records as an event landed before the failure, and no event by another login appeared."
  elif [ -n "$unattributed" ]; then
    gh_rest_err "the other writes that succeeded before the failure are attributed to $GH_REST_EXPECTED, and no event by another login appeared."
  else
    gh_rest_err "the writes that succeeded before the failure are attributed to $GH_REST_EXPECTED, and no event by another login appeared."
  fi
  return 1
}

gh_rest_remove_label() { # <repo> <N> <label>
  gh_rest_api DELETE "repos/$1/issues/$2/labels/$(gh_rest_uri "$3")" >/dev/null || {
    gh_rest_err "removing the label '$3' from PR #$2 failed; earlier edits were applied, later ones were not attempted."
    return 1
  }
  GH_REST_REMOVED_LABELS="$GH_REST_REMOVED_LABELS$3"$'\n'
}

# gh_rest_post_comment <repo> <N> <body file> -> prints the comment URL; 5 on
# a wrong byline.
gh_rest_post_comment() {
  local input response login url
  input="$(gh_rest_json_file --rawfile body "$3" '{body: $body}')" || return 1
  response="$(gh_rest_api POST "repos/$1/issues/$2/comments" "$input")" || return $?
  login="$(printf '%s' "$response" | jq -r '.user.login // empty' 2>/dev/null)"
  url="$(printf '%s' "$response" | jq -r '.html_url // empty' 2>/dev/null)"
  if [ -z "$login" ] || [ -z "$url" ]; then
    gh_rest_err "ERROR could not read the posted comment back from the response; refusing to treat it as verified."
    gh_rest_err "The comment may exist on $1#$2: check it by hand."
    return 5
  fi
  if [ "$login" != "$GH_REST_EXPECTED" ]; then
    gh_rest_err "ERROR comment $url landed under '$login', expected '$GH_REST_EXPECTED'."
    gh_rest_recovery "the comment" "$url"
    return 5
  fi
  gh_rest_err "verified comment $url author=$login (matches expected $GH_REST_EXPECTED)"
  printf '%s\n' "$url"
}

# --- verbs --------------------------------------------------------------------------

# gh_rest_on_claude_cloud: 0 iff this is a Claude cloud session, the surface
# whose git proxy is the one loopback remote that stands for GitHub. The
# surface variable wins when set, as it does for transport selection.
gh_rest_on_claude_cloud() {
  case "${MERGEPATH_AGENT_SURFACE:-}" in
    claude-cloud) return 0 ;;
    '') [ "${CLAUDE_CODE_REMOTE:-}" = "true" ] ;;
    *) return 1 ;;
  esac
}

# gh_rest_repo_of_url <remote URL> -> owner/repo, from the URL's last two path
# segments, when the URL points at github.com, or at a loopback host in a
# Claude cloud session (its git proxy, whose path ends in the repository
# too). Any other host fails, and so does loopback elsewhere: a local git
# server's owner/repo says nothing about a GitHub repository.
gh_rest_repo_of_url() {
  local url="$1" path host
  case "$url" in
    *://*) host="${url#*://}"; path="${host#*/}"; host="${host%%/*}" ;;
    *:*) host="${url%%:*}"; path="${url#*:}" ;;
    *) return 1 ;;
  esac
  host="${host##*@}"
  case "$host" in
    \[*\]*) host="${host%%]*}]" ;;
    *) host="${host%%:*}" ;;
  esac
  case "$(printf '%s' "$host" | tr '[:upper:]' '[:lower:]')" in
    github.com|www.github.com|ssh.github.com) ;;
    127.0.0.1|localhost|\[::1\]) gh_rest_on_claude_cloud || return 1 ;;
    *) return 1 ;;
  esac
  path="${path%/}"
  path="${path%.git}"
  case "$path" in */*) ;; *) return 1 ;; esac
  printf '%s/%s\n' "$(basename "$(dirname "$path")")" "$(basename "$path")"
}

# gh_rest_default_head <repo>: sets GH_REST_DEFAULT_HEAD to the head for an
# omitted --head, as gh resolves it: the checked-out branch, qualified
# owner:branch when it is pushed to a different repository than <repo> (a
# fork). When the fork has the same owner as <repo>, owner:branch is
# ambiguous, so GH_REST_DEFAULT_HEAD_REPO names the fork repository, which
# GitHub requires as head_repo for that case. A branch with no push remote is
# refused, as gh refuses one it has not pushed.
gh_rest_default_head() {
  local repo="$1" branch remote url pushed push_ref remote_branch
  branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
  if [ -z "$branch" ] || [ "$branch" = "HEAD" ]; then
    gh_rest_refuse "pass --head BRANCH: no branch is checked out here"
    return 1
  fi
  remote="$(git config --get "branch.$branch.pushRemote" 2>/dev/null || git config --get remote.pushDefault 2>/dev/null || git config --get "branch.$branch.remote" 2>/dev/null || true)"
  url=""
  [ -z "$remote" ] || url="$(git remote get-url --push "$remote" 2>/dev/null || true)"
  if [ -z "$url" ] || ! pushed="$(gh_rest_repo_of_url "$url")"; then
    gh_rest_refuse "pass --head: branch $branch has no push remote on GitHub to tell which repository holds it (use owner:branch for a fork)"
    return 1
  fi
  # The branch must be fully pushed: a PR from a ref behind HEAD would leave
  # out the latest commits. @{push} is where git would push this branch; gh
  # asks to push when it is not current, and this transport refuses.
  push_ref="$(git rev-parse --abbrev-ref --symbolic-full-name '@{push}' 2>/dev/null || true)"
  case "$push_ref" in
    "$remote"/?*) remote_branch="${push_ref#"$remote"/}" ;;
    *)
      gh_rest_refuse "pass --head: branch $branch has no pushed ref on $remote to open a PR from; push it first"
      return 1
      ;;
  esac
  if [ "$(git rev-parse '@{push}' 2>/dev/null || true)" != "$(git rev-parse HEAD 2>/dev/null)" ]; then
    gh_rest_refuse "branch $branch is not fully pushed: $push_ref differs from HEAD; push it first, or pass --head to open the PR from the pushed ref"
    return 1
  fi
  local lc_pushed lc_repo
  lc_pushed="$(printf '%s' "$pushed" | tr '[:upper:]' '[:lower:]')"
  lc_repo="$(printf '%s' "$repo" | tr '[:upper:]' '[:lower:]')"
  GH_REST_DEFAULT_HEAD_REPO=""
  if [ "$lc_pushed" = "$lc_repo" ]; then
    GH_REST_DEFAULT_HEAD="$remote_branch"
  else
    GH_REST_DEFAULT_HEAD="${pushed%%/*}:$remote_branch"
    [ "${lc_pushed%%/*}" != "${lc_repo%%/*}" ] || GH_REST_DEFAULT_HEAD_REPO="${pushed#*/}"
  fi
  return 0
}

# The follow-up writes of a create, in order; stops at the first failure.
# Reads its caller's locals (labels_json, reviewers_json, assignees_json,
# repo, number, url).
gh_rest_create_followups() {
  local input
  GH_REST_DONE=" "
  if [ "$labels_json" != "[]" ]; then
    input="$(gh_rest_json_file --argjson labels "$labels_json" '{labels: $labels}')" || return 1
    gh_rest_api POST "repos/$repo/issues/$number/labels" "$input" >/dev/null || { gh_rest_err "PR #$number was created ($url) but its labels could not be added."; return 1; }
    GH_REST_DONE="${GH_REST_DONE}labels "
  fi
  if [ "$reviewers_json" != "[]" ]; then
    input="$(gh_rest_json_file --argjson reviewers "$reviewers_json" '{reviewers: $reviewers}')" || return 1
    gh_rest_api POST "repos/$repo/pulls/$number/requested_reviewers" "$input" >/dev/null || { gh_rest_err "PR #$number was created ($url) but its reviewers could not be requested."; return 1; }
    GH_REST_DONE="${GH_REST_DONE}reviewers "
  fi
  if [ "$assignees_json" != "[]" ]; then
    input="$(gh_rest_json_file --argjson assignees "$assignees_json" '{assignees: $assignees}')" || return 1
    gh_rest_api POST "repos/$repo/issues/$number/assignees" "$input" >/dev/null || { gh_rest_err "PR #$number was created ($url) but its assignees could not be set."; return 1; }
    GH_REST_DONE="${GH_REST_DONE}assignees "
  fi
  return 0
}

# gh_rest_done <step>: 0 iff the write sequence recorded <step> as succeeded.
gh_rest_done() {
  case "$GH_REST_DONE" in *" $1 "*) return 0 ;; esac
  return 1
}

gh_rest_pr_create() {
  GH_REST_FORM='gh pr create --repo OWNER/REPO --title T (--body B | --body-file F) [--head BRANCH] [--base BRANCH] [--draft] [--label L]... [--reviewer USER]... [--assignee USER]...' # NO_BARE_GH_WRITE_EXEMPT: usage text printed in a refusal, never executed
  local repo="" title="" title_set=0 head="" base="" draft=false labels="" reviewers="" assignees=""
  GH_REST_BODY_FILE=""
  GH_REST_BODY_SET=0
  gh_rest_parse_init "$@"
  while [ "$GH_REST_I" -lt "${#GH_REST_ARGS[@]}" ]; do
    gh_rest_opt || return 1
    case "$GH_REST_OPT" in
      --repo) gh_rest_value || return 1; repo="$GH_REST_VAL" ;;
      --title) gh_rest_value || return 1; title="$GH_REST_VAL"; title_set=1 ;;
      --body|--body-file) gh_rest_value || return 1; gh_rest_body_from "$GH_REST_OPT" "$GH_REST_VAL" || return 1 ;;
      --head) gh_rest_value || return 1; head="$GH_REST_VAL" ;;
      --base) gh_rest_value || return 1; base="$GH_REST_VAL" ;;
      --draft) gh_rest_flag || return 1; draft=true ;;
      --label) gh_rest_value || return 1; gh_rest_check_csv --label "$GH_REST_VAL" || return 1; labels="$labels$(gh_rest_split_csv "$GH_REST_VAL")"$'\n' ;;
      --reviewer) gh_rest_value || return 1; gh_rest_check_csv --reviewer "$GH_REST_VAL" || return 1; reviewers="$reviewers$(gh_rest_split_csv "$GH_REST_VAL")"$'\n' ;;
      --assignee) gh_rest_value || return 1; gh_rest_check_csv --assignee "$GH_REST_VAL" || return 1; assignees="$assignees$(gh_rest_split_csv "$GH_REST_VAL")"$'\n' ;;
      '') gh_rest_refuse "unexpected argument '$GH_REST_VAL'"; return 1 ;;
      *) gh_rest_refuse "option $GH_REST_OPT is not accepted"; return 1 ;;
    esac
    GH_REST_I=$((GH_REST_I + 1))
  done
  gh_rest_check_repo "$repo" || return 1
  if [ "$title_set" -eq 0 ] || [ -z "$title" ]; then
    gh_rest_refuse "--title is required"
    return 1
  fi
  if [ "$GH_REST_BODY_SET" -eq 0 ]; then
    gh_rest_refuse "--body or --body-file is required"
    return 1
  fi
  local head_repo=""
  if [ -z "$head" ]; then
    gh_rest_default_head "$repo" || return 1
    head="$GH_REST_DEFAULT_HEAD"
    head_repo="$GH_REST_DEFAULT_HEAD_REPO"
  fi
  gh_rest_check_branch "$head" "--head" || return 1
  gh_rest_each "$(gh_rest_lines_json "$reviewers")" gh_rest_check_login_what "--reviewer" || return 1
  gh_rest_each "$(gh_rest_lines_json "$assignees")" gh_rest_check_login_what "--assignee" || return 1
  if [ -z "$base" ]; then
    # gh's order: the checked-out branch's gh-merge-base, then the default.
    local current
    current="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
    if [ -n "$current" ] && [ "$current" != "HEAD" ]; then
      base="$(git config --get "branch.$current.gh-merge-base" 2>/dev/null || true)"
    fi
  fi
  if [ -z "$base" ]; then
    base="$(gh_rest_api GET "repos/$repo" | jq -r '.default_branch // empty' 2>/dev/null)"
    if [ -z "$base" ]; then
      gh_rest_err "could not read the default branch of $repo; pass --base BRANCH. Nothing was written."
      return 1
    fi
  fi
  gh_rest_check_branch "$base" "--base" || return 1

  # Labels, reviewers and assignees are attributed from issue events, so an
  # older gh is refused before the pull request is created, not after.
  if [ -n "$labels$reviewers$assignees" ]; then
    gh_rest_require_slurp "Nothing was written." || return 1
  fi
  local input response number url actual rc=0
  input="$(gh_rest_json_file --arg title "$title" --rawfile body "$GH_REST_BODY_FILE" --arg head "$head" --arg base "$base" --argjson draft "$draft" \
    --arg head_repo "$head_repo" \
    '{title: $title, body: $body, head: $head, base: $base, draft: $draft} + (if $head_repo == "" then {} else {head_repo: $head_repo} end)')" || return 1
  response="$(gh_rest_api POST "repos/$repo/pulls" "$input")" || return $?
  number="$(printf '%s' "$response" | jq -r '.number // empty' 2>/dev/null)"
  url="$(printf '%s' "$response" | jq -r '.html_url // empty' 2>/dev/null)"
  if [ -z "$number" ] || [ -z "$url" ]; then
    gh_rest_err "ERROR could not read the created pull request from the response; refusing to treat the create as verified."
    gh_rest_err "The PR may still have been created: check gh pr list --author $GH_REST_EXPECTED --repo $repo and verify manually."
    return 5
  fi
  # The #241 re-read: the created object's author, under the same token.
  local created
  created="$(gh_rest_api GET "repos/$repo/pulls/$number" 2>/dev/null || true)"
  actual="$(printf '%s' "$created" | jq -r '.user.login // empty' 2>/dev/null)"
  if [ -z "$actual" ]; then
    gh_rest_err "ERROR could not read the author of $url back; refusing to treat the create as verified."
    gh_rest_err "Verify manually: GH_TOKEN=<author-token> gh api repos/$repo/pulls/$number --jq .user.login"
    printf '%s\n' "$url"
    return 5
  fi
  if [ "$actual" != "$GH_REST_EXPECTED" ]; then
    gh_rest_err "ERROR PR #$number on $repo landed under '$actual', expected '$GH_REST_EXPECTED'."
    gh_rest_recovery "the pull request (close it and recreate from the same branch)" "$url"
    printf '%s\n' "$url"
    return 5
  fi
  gh_rest_err "verified PR #$number author=$actual (matches expected $GH_REST_EXPECTED)"

  # Follow-ups are taken against the created pull request's state, as edits
  # are: automation that runs on open may already have applied a requested
  # label, and a no-op write produces no event to attribute. The events are
  # snapshotted before the follow-ups, so an event that automation produced
  # earlier is never read as this wrapper's write (Phase 4b on #2178).
  local labels_json reviewers_json assignees_json followed=0 before=""
  labels_json="$(gh_rest_set_ops add "$(printf '%s' "$created" | jq -c '[.labels[]?.name]' 2>/dev/null || echo '[]')" "$labels" "")"
  reviewers_json="$(gh_rest_set_ops add "$(printf '%s' "$created" | jq -c '[.requested_reviewers[]?.login]' 2>/dev/null || echo '[]')" "$reviewers" "")"
  assignees_json="$(gh_rest_set_ops add "$(printf '%s' "$created" | jq -c '[.assignees[]?.login]' 2>/dev/null || echo '[]')" "$assignees" "")"
  [ "$labels_json$reviewers_json$assignees_json" = "[][][]" ] || followed=1
  if [ "$followed" -eq 1 ]; then
    before="$(gh_rest_events "$repo" "$number")" || {
      gh_rest_err "ERROR PR #$number was created ($url), but its events could not be read before the label, reviewer and assignee writes, so they were not attempted: they could not be attributed."
      printf '%s\n' "$url"
      return 5
    }
  fi
  if [ "$followed" -eq 1 ] && ! gh_rest_create_followups; then
    # Labels may have landed before the reviewers failed. Only the follow-ups
    # that succeeded are attributed positively; the rest are scanned.
    gh_rest_done labels || labels_json="[]"
    gh_rest_done reviewers || reviewers_json="[]"
    gh_rest_done assignees || assignees_json="[]"
    rc=0
    gh_rest_partial_failure "$repo" "$number" "$before" "$url" gh_rest_check_create_events || rc=$?
    printf '%s\n' "$url"
    return "$rc"
  fi
  if [ "$followed" -eq 1 ]; then
    gh_rest_readback "$repo" "$number" "$before" gh_rest_check_create_events || rc=$?
    if [ "$rc" -eq 3 ]; then
      gh_rest_err "ERROR PR #$number was created ($url) but its events could not be read, so the label, reviewer and assignee writes are unattributed."
      printf '%s\n' "$url"
      return 5
    fi
    if [ "$rc" -ne 0 ]; then
      gh_rest_recovery "the mis-attributed label, reviewer or assignee changes" "$url"
      printf '%s\n' "$url"
      return 5
    fi
    gh_rest_err "verified on PR #$number by $GH_REST_EXPECTED:${GH_REST_VERIFIED%,}"
  fi
  printf '%s\n' "$url"
  return 0
}

gh_rest_issue_create() {
  GH_REST_FORM='gh issue create --repo OWNER/REPO --title T --body-file F [--label L]... [--assignee USER]...' # NO_BARE_GH_WRITE_EXEMPT: usage text printed in a refusal, never executed
  local repo="" title="" labels="" assignees=""
  GH_REST_BODY_FILE=""
  GH_REST_BODY_SET=0
  gh_rest_parse_init "$@"
  while [ "$GH_REST_I" -lt "${#GH_REST_ARGS[@]}" ]; do
    gh_rest_opt || return 1
    case "$GH_REST_OPT" in
      --repo) gh_rest_value || return 1; repo="$GH_REST_VAL" ;;
      --title) gh_rest_value || return 1; title="$GH_REST_VAL" ;;
      --body-file) gh_rest_value || return 1; gh_rest_body_from "$GH_REST_OPT" "$GH_REST_VAL" || return 1 ;;
      --label) gh_rest_value || return 1; gh_rest_check_csv --label "$GH_REST_VAL" || return 1; labels="$labels$(gh_rest_split_csv "$GH_REST_VAL")"$'\n' ;;
      --assignee) gh_rest_value || return 1; gh_rest_check_csv --assignee "$GH_REST_VAL" || return 1; assignees="$assignees$(gh_rest_split_csv "$GH_REST_VAL")"$'\n' ;;
      *) gh_rest_refuse "option or argument '${GH_REST_OPT:-$GH_REST_VAL}' is not accepted"; return 1 ;;
    esac
    GH_REST_I=$((GH_REST_I + 1))
  done
  gh_rest_check_repo "$repo" || return 1
  [ -n "$title" ] || { gh_rest_refuse "--title is required"; return 1; }
  [ "$GH_REST_BODY_SET" -eq 1 ] || { gh_rest_refuse "--body-file is required"; return 1; }
  local labels_json assignees_json input response number url created actual
  labels_json="$(gh_rest_lines_json "$labels")" || return 1
  assignees_json="$(gh_rest_lines_json "$assignees")" || return 1
  gh_rest_each "$assignees_json" gh_rest_check_login_what "--assignee" || return 1
  input="$(gh_rest_json_file --arg title "$title" --rawfile body "$GH_REST_BODY_FILE" \
    --argjson labels "$labels_json" --argjson assignees "$assignees_json" \
    '{title:$title,body:$body,labels:$labels,assignees:$assignees}')" || return 1
  response="$(gh_rest_api POST "repos/$repo/issues" "$input")" || return $?
  number="$(printf '%s' "$response" | jq -r \
    '.number | select(type == "number" and . > 0 and . == floor)' 2>/dev/null)" || number=""
  url="$(printf '%s' "$response" | jq -r '.html_url // empty' 2>/dev/null)"
  if [ -z "$number" ] || ! printf '%s' "$url" | jq -eRs --arg r "$repo" --arg n "$number" \
    'ascii_downcase == ("https://github.com/" + $r + "/issues/" + $n | ascii_downcase)' >/dev/null; then
    gh_rest_err "ERROR could not identify the created issue; it may exist, so verify manually before retrying."
    return 5
  fi
  created="$(gh_rest_api GET "repos/$repo/issues/$number" 2>/dev/null || true)"
  actual="$(printf '%s' "$created" | jq -r '.user.login // empty' 2>/dev/null)"
  if [ -z "$actual" ]; then
    gh_rest_err "ERROR could not read the author of $url back; inspect it before retrying."
    printf '%s\n' "$url"
    return 5
  fi
  if [ "$actual" != "$GH_REST_EXPECTED" ]; then
    gh_rest_err "ERROR issue $url author readback was '$actual', expected '$GH_REST_EXPECTED'."
    gh_rest_recovery "the issue" "$url"
    printf '%s\n' "$url"
    return 5
  fi
  if ! printf '%s' "$created" | jq -e --slurpfile sent "$input" --argjson n "$number" '
    .number == $n and .title == $sent[0].title and .body == $sent[0].body
    and ((($sent[0].labels | map(ascii_downcase)) - [.labels[]?.name | ascii_downcase]) | length) == 0
    and ((($sent[0].assignees | map(ascii_downcase)) - [.assignees[]?.login | ascii_downcase]) | length) == 0' >/dev/null; then
    gh_rest_err "ERROR issue $url was created, but requested content/metadata could not be verified; inspect it before retrying."
    printf '%s\n' "$url"
    return 5
  fi
  gh_rest_err "verified issue #$number author=$actual (matches expected $GH_REST_EXPECTED)"
  printf '%s\n' "$url"
}

gh_rest_comment() { # <pr|issue> <args...>
  local kind="$1" number="" repo=""
  shift
  GH_REST_FORM="gh $kind comment N --repo OWNER/REPO (--body B | --body-file F)" # NO_BARE_GH_WRITE_EXEMPT: usage text printed in a refusal, never executed
  GH_REST_BODY_FILE=""
  GH_REST_BODY_SET=0
  gh_rest_parse_init "$@"
  while [ "$GH_REST_I" -lt "${#GH_REST_ARGS[@]}" ]; do
    gh_rest_opt || return 1
    case "$GH_REST_OPT" in
      '') number="$(gh_rest_number "$GH_REST_VAL" "$number")" || return 1 ;;
      --repo) gh_rest_value || return 1; repo="$GH_REST_VAL" ;;
      --body|--body-file) gh_rest_value || return 1; gh_rest_body_from "$GH_REST_OPT" "$GH_REST_VAL" || return 1 ;;
      *) gh_rest_refuse "option $GH_REST_OPT is not accepted"; return 1 ;;
    esac
    GH_REST_I=$((GH_REST_I + 1))
  done
  if [ -z "$number" ]; then
    gh_rest_refuse "the $kind number is required"
    return 1
  fi
  gh_rest_check_repo "$repo" || return 1
  if [ "$GH_REST_BODY_SET" -eq 0 ]; then
    gh_rest_refuse "--body or --body-file is required"
    return 1
  fi
  if [ "$kind" = "pr" ]; then
    gh_rest_read_pr "$repo" "$number" >/dev/null || return 1
  fi
  gh_rest_post_comment "$repo" "$number" "$GH_REST_BODY_FILE"
}

gh_rest_pr_review() {
  GH_REST_FORM='gh pr review N --repo OWNER/REPO (--approve | --comment | --request-changes) [--body B | --body-file F]' # NO_BARE_GH_WRITE_EXEMPT: usage text printed in a refusal, never executed
  local number="" repo="" event="" events=0
  GH_REST_BODY_FILE=""
  GH_REST_BODY_SET=0
  gh_rest_parse_init "$@"
  while [ "$GH_REST_I" -lt "${#GH_REST_ARGS[@]}" ]; do
    gh_rest_opt || return 1
    case "$GH_REST_OPT" in
      '') number="$(gh_rest_number "$GH_REST_VAL" "$number")" || return 1 ;;
      --repo) gh_rest_value || return 1; repo="$GH_REST_VAL" ;;
      --approve) gh_rest_flag || return 1; event=APPROVE; events=$((events + 1)) ;;
      --comment) gh_rest_flag || return 1; event=COMMENT; events=$((events + 1)) ;;
      --request-changes) gh_rest_flag || return 1; event=REQUEST_CHANGES; events=$((events + 1)) ;;
      --body|--body-file) gh_rest_value || return 1; gh_rest_body_from "$GH_REST_OPT" "$GH_REST_VAL" || return 1 ;;
      *) gh_rest_refuse "option $GH_REST_OPT is not accepted"; return 1 ;;
    esac
    GH_REST_I=$((GH_REST_I + 1))
  done
  if [ -z "$number" ]; then
    gh_rest_refuse "the pull request number is required"
    return 1
  fi
  gh_rest_check_repo "$repo" || return 1
  if [ "$events" -ne 1 ]; then
    gh_rest_refuse "pass exactly one of --approve, --comment or --request-changes"
    return 1
  fi
  if [ "$event" != "APPROVE" ] && { [ "$GH_REST_BODY_SET" -eq 0 ] || [ ! -s "$GH_REST_BODY_FILE" ]; }; then
    gh_rest_refuse "a --comment or --request-changes review needs a non-empty --body or --body-file"
    return 1
  fi
  gh_rest_read_pr "$repo" "$number" >/dev/null || return 1

  local input response login url state
  if [ "$GH_REST_BODY_SET" -eq 1 ]; then
    input="$(gh_rest_json_file --arg event "$event" --rawfile body "$GH_REST_BODY_FILE" '{event: $event, body: $body}')" || return 1
  else
    input="$(gh_rest_json_file --arg event "$event" '{event: $event}')" || return 1
  fi
  response="$(gh_rest_api POST "repos/$repo/pulls/$number/reviews" "$input")" || return $?
  login="$(printf '%s' "$response" | jq -r '.user.login // empty' 2>/dev/null)"
  url="$(printf '%s' "$response" | jq -r '.html_url // empty' 2>/dev/null)"
  state="$(printf '%s' "$response" | jq -r '.state // empty' 2>/dev/null)"
  if [ -z "$login" ] || [ -z "$url" ]; then
    gh_rest_err "ERROR could not read the posted review back from the response; refusing to treat it as verified."
    gh_rest_err "The review may exist on $repo#$number: check it by hand."
    return 5
  fi
  if [ "$login" != "$GH_REST_EXPECTED" ]; then
    gh_rest_err "ERROR review $url landed under '$login', expected '$GH_REST_EXPECTED'."
    gh_rest_recovery "the review (dismiss it)" "$url"
    return 5
  fi
  gh_rest_err "verified review $url ($state) author=$login (matches expected $GH_REST_EXPECTED)"
  return 0
}

# gh_rest_set_ops <add|remove> <current JSON array> <added lines> <removed lines>
# The REST operations that turn <current> into gh's final set,
# (current + added) - removed. Logins and label names compare without case,
# as GitHub compares them: an addition keeps the caller's spelling, a removal
# names the current entry as GitHub spells it.
gh_rest_set_ops() {
  local add_json remove_json
  add_json="$(gh_rest_lines_json "$3")"
  remove_json="$(gh_rest_lines_json "$4")"
  { printf '%s\n' "$2"; printf '%s\n' "$add_json"; printf '%s\n' "$remove_json"; } | jq -cs --arg op "$1" '
    .[0] as $cur | .[1] as $add
    | ($cur | map(ascii_downcase)) as $curl | (.[2] | map(ascii_downcase)) as $reml
    | if $op == "add" then
        [$add[] | select(ascii_downcase as $l | ($curl | index($l)) == null and ($reml | index($l)) == null)]
        | unique_by(ascii_downcase)
      else
        [$cur[] | select(ascii_downcase as $l | ($reml | index($l)) != null)]
      end'
}

# The writes of an edit, in order; stops at the first failure. Reads its
# caller's locals (the *_op flags, the *_json operation lists, title, base,
# repo, number).
gh_rest_edit_writes() {
  local input
  GH_REST_DONE=" "
  GH_REST_REMOVED_LABELS=""
  if [ "$title_op" -eq 1 ] || [ "$body_op" -eq 1 ] || [ "$base_op" -eq 1 ]; then
    local text="$GH_REST_BODY_FILE"
    [ -n "$text" ] || text="$(gh_rest_text_file "")" || return 1
    input="$(gh_rest_json_file --arg title "$title" --rawfile body "$text" --arg base "$base" \
      --argjson t "$title_op" --argjson b "$body_op" --argjson r "$base_op" \
      '({} | if $t == 1 then .title = $title else . end | if $b == 1 then .body = $body else . end | if $r == 1 then .base = $base else . end)')" || return 1
    gh_rest_api PATCH "repos/$repo/pulls/$number" "$input" >/dev/null || { gh_rest_err "the title/body/base edit of PR #$number failed; later edits were not attempted."; return 1; }
    GH_REST_DONE="${GH_REST_DONE}patch "
  fi
  if [ "$add_labels_json" != "[]" ]; then
    input="$(gh_rest_json_file --argjson labels "$add_labels_json" '{labels: $labels}')" || return 1
    gh_rest_api POST "repos/$repo/issues/$number/labels" "$input" >/dev/null || { gh_rest_err "adding labels to PR #$number failed; earlier edits were applied, later ones were not attempted."; return 1; }
    GH_REST_DONE="${GH_REST_DONE}add-labels "
  fi
  gh_rest_each "$remove_labels_json" gh_rest_remove_label "$repo" "$number" || return 1
  if [ "$add_reviewers_json" != "[]" ]; then
    input="$(gh_rest_json_file --argjson reviewers "$add_reviewers_json" '{reviewers: $reviewers}')" || return 1
    gh_rest_api POST "repos/$repo/pulls/$number/requested_reviewers" "$input" >/dev/null || { gh_rest_err "requesting reviewers on PR #$number failed; earlier edits were applied, later ones were not attempted."; return 1; }
    GH_REST_DONE="${GH_REST_DONE}add-reviewers "
  fi
  if [ "$remove_reviewers_json" != "[]" ]; then
    input="$(gh_rest_json_file --argjson reviewers "$remove_reviewers_json" '{reviewers: $reviewers}')" || return 1
    gh_rest_api DELETE "repos/$repo/pulls/$number/requested_reviewers" "$input" >/dev/null || { gh_rest_err "removing review requests on PR #$number failed; earlier edits were applied, later ones were not attempted."; return 1; }
    GH_REST_DONE="${GH_REST_DONE}remove-reviewers "
  fi
  if [ "$add_assignees_json" != "[]" ]; then
    input="$(gh_rest_json_file --argjson assignees "$add_assignees_json" '{assignees: $assignees}')" || return 1
    gh_rest_api POST "repos/$repo/issues/$number/assignees" "$input" >/dev/null || { gh_rest_err "assigning PR #$number failed; earlier edits were applied, later ones were not attempted."; return 1; }
    GH_REST_DONE="${GH_REST_DONE}add-assignees "
  fi
  if [ "$remove_assignees_json" != "[]" ]; then
    input="$(gh_rest_json_file --argjson assignees "$remove_assignees_json" '{assignees: $assignees}')" || return 1
    gh_rest_api DELETE "repos/$repo/issues/$number/assignees" "$input" >/dev/null || { gh_rest_err "unassigning PR #$number failed; earlier edits were applied."; return 1; }
    GH_REST_DONE="${GH_REST_DONE}remove-assignees "
  fi

  return 0
}

gh_rest_pr_edit() {
  GH_REST_FORM='gh pr edit N --repo OWNER/REPO [--title T] [--body B | --body-file F] [--base BRANCH] [--add-label L]... [--remove-label L]... [--add-reviewer USER]... [--remove-reviewer USER]... [--add-assignee USER]... [--remove-assignee USER]...' # NO_BARE_GH_WRITE_EXEMPT: usage text printed in a refusal, never executed
  local number="" repo="" title="" title_set=0 base="" base_set=0
  local add_labels="" remove_labels="" add_reviewers="" remove_reviewers="" add_assignees="" remove_assignees=""
  GH_REST_BODY_FILE=""
  GH_REST_BODY_SET=0
  gh_rest_parse_init "$@"
  while [ "$GH_REST_I" -lt "${#GH_REST_ARGS[@]}" ]; do
    gh_rest_opt || return 1
    case "$GH_REST_OPT" in
      '') number="$(gh_rest_number "$GH_REST_VAL" "$number")" || return 1 ;;
      --repo) gh_rest_value || return 1; repo="$GH_REST_VAL" ;;
      --title) gh_rest_value || return 1; title="$GH_REST_VAL"; title_set=1 ;;
      --body|--body-file) gh_rest_value || return 1; gh_rest_body_from "$GH_REST_OPT" "$GH_REST_VAL" || return 1 ;;
      --base) gh_rest_value || return 1; base="$GH_REST_VAL"; base_set=1 ;;
      --add-label) gh_rest_value || return 1; gh_rest_check_csv --add-label "$GH_REST_VAL" || return 1; add_labels="$add_labels$(gh_rest_split_csv "$GH_REST_VAL")"$'\n' ;;
      --remove-label) gh_rest_value || return 1; gh_rest_check_csv --remove-label "$GH_REST_VAL" || return 1; remove_labels="$remove_labels$(gh_rest_split_csv "$GH_REST_VAL")"$'\n' ;;
      --add-reviewer) gh_rest_value || return 1; gh_rest_check_csv --add-reviewer "$GH_REST_VAL" || return 1; add_reviewers="$add_reviewers$(gh_rest_split_csv "$GH_REST_VAL")"$'\n' ;;
      --remove-reviewer) gh_rest_value || return 1; gh_rest_check_csv --remove-reviewer "$GH_REST_VAL" || return 1; remove_reviewers="$remove_reviewers$(gh_rest_split_csv "$GH_REST_VAL")"$'\n' ;;
      --add-assignee) gh_rest_value || return 1; gh_rest_check_csv --add-assignee "$GH_REST_VAL" || return 1; add_assignees="$add_assignees$(gh_rest_split_csv "$GH_REST_VAL")"$'\n' ;;
      --remove-assignee) gh_rest_value || return 1; gh_rest_check_csv --remove-assignee "$GH_REST_VAL" || return 1; remove_assignees="$remove_assignees$(gh_rest_split_csv "$GH_REST_VAL")"$'\n' ;;
      *) gh_rest_refuse "option $GH_REST_OPT is not accepted"; return 1 ;;
    esac
    GH_REST_I=$((GH_REST_I + 1))
  done
  if [ -z "$number" ]; then
    gh_rest_refuse "the pull request number is required"
    return 1
  fi
  gh_rest_check_repo "$repo" || return 1
  if [ "$title_set" -eq 1 ] && [ -z "$title" ]; then
    gh_rest_refuse "--title cannot be empty"
    return 1
  fi
  if [ "$base_set" -eq 1 ]; then gh_rest_check_branch "$base" "--base" || return 1; fi
  gh_rest_each "$(gh_rest_lines_json "$add_reviewers$remove_reviewers")" gh_rest_check_login_what "a reviewer" || return 1
  gh_rest_each "$(gh_rest_lines_json "$add_assignees$remove_assignees")" gh_rest_check_login_what "an assignee" || return 1
  if [ "$title_set" -eq 0 ] && [ "$GH_REST_BODY_SET" -eq 0 ] && [ "$base_set" -eq 0 ] \
     && [ -z "$add_labels$remove_labels$add_reviewers$remove_reviewers$add_assignees$remove_assignees" ]; then
    gh_rest_refuse "nothing to edit: pass at least one change"
    return 1
  fi

  # The current state, so a no-op is dropped before the write: a no-op
  # produces no event, and an edit with no event cannot be attributed.
  local pre url
  pre="$(gh_rest_read_pr "$repo" "$number")" || return 1
  url="$(printf '%s' "$pre" | jq -r '.html_url')"
  local title_op=0 body_op=0 base_op=0
  if [ "$title_set" -eq 1 ] && [ "$title" != "$(printf '%s' "$pre" | jq -r '.title // ""')" ]; then title_op=1; fi
  if [ "$GH_REST_BODY_SET" -eq 1 ]; then
    # Byte comparison: the current body is written out exactly, not through
    # command substitution, which would strip trailing newlines.
    local current_body
    current_body="$(umask 077; mktemp "$GH_REST_TMPDIR/current.XXXXXX")" || return 1
    printf '%s' "$pre" | jq -j '.body // ""' >"$current_body" || return 1
    cmp -s "$current_body" "$GH_REST_BODY_FILE" || body_op=1
  fi
  if [ "$base_set" -eq 1 ] && [ "$base" != "$(printf '%s' "$pre" | jq -r '.base.ref // ""')" ]; then base_op=1; fi
  local cur_labels cur_reviewers cur_assignees
  cur_labels="$(printf '%s' "$pre" | jq -c '[.labels[]?.name]')"
  cur_reviewers="$(printf '%s' "$pre" | jq -c '[.requested_reviewers[]?.login]')"
  cur_assignees="$(printf '%s' "$pre" | jq -c '[.assignees[]?.login]')"
  local add_labels_json remove_labels_json add_reviewers_json remove_reviewers_json add_assignees_json remove_assignees_json
  # gh builds each final set as (current + added) - removed, so a login or
  # label in both lists ends up removed. The REST operations are the
  # difference between that final set and the current one, which also drops
  # every no-op.
  add_labels_json="$(gh_rest_set_ops add "$cur_labels" "$add_labels" "$remove_labels")"
  remove_labels_json="$(gh_rest_set_ops remove "$cur_labels" "$add_labels" "$remove_labels")"
  add_reviewers_json="$(gh_rest_set_ops add "$cur_reviewers" "$add_reviewers" "$remove_reviewers")"
  remove_reviewers_json="$(gh_rest_set_ops remove "$cur_reviewers" "$add_reviewers" "$remove_reviewers")"
  add_assignees_json="$(gh_rest_set_ops add "$cur_assignees" "$add_assignees" "$remove_assignees")"
  remove_assignees_json="$(gh_rest_set_ops remove "$cur_assignees" "$add_assignees" "$remove_assignees")"
  if [ "$title_op" -eq 0 ] && [ "$body_op" -eq 0 ] && [ "$base_op" -eq 0 ] \
     && [ "$add_labels_json$remove_labels_json$add_reviewers_json$remove_reviewers_json$add_assignees_json$remove_assignees_json" = "[][][][][][]" ]; then
    gh_rest_err "no change: every requested edit matches the current state of PR #$number; nothing was written."
    printf '%s\n' "$url"
    return 0
  fi

  gh_rest_require_slurp "Nothing was written." || return 1
  local before
  before="$(gh_rest_events "$repo" "$number")" || {
    gh_rest_err "could not read the events of PR #$number before the edit; refusing a write that could not be attributed. Nothing was written."
    return 5
  }

  local input rc=0
  if ! gh_rest_edit_writes; then
    # Earlier writes may have landed. Only the writes that succeeded are
    # attributed positively; the rest are scanned for another login.
    # A body that landed has no event to attribute it by, so it is reported
    # as unattributed rather than counted among the verified writes.
    local body_landed="" evented=1
    if gh_rest_done patch; then
      [ "$body_op" -eq 0 ] || body_landed="the body edit of PR #$number"
    else
      title_op=0; base_op=0
    fi
    gh_rest_done add-labels || add_labels_json="[]"
    remove_labels_json="$(gh_rest_lines_json "$GH_REST_REMOVED_LABELS" | jq -c .)"
    gh_rest_done add-reviewers || add_reviewers_json="[]"
    gh_rest_done remove-reviewers || remove_reviewers_json="[]"
    gh_rest_done add-assignees || add_assignees_json="[]"
    gh_rest_done remove-assignees || remove_assignees_json="[]"
    if [ "$title_op" -eq 0 ] && [ "$base_op" -eq 0 ] \
       && [ "$add_labels_json$remove_labels_json$add_reviewers_json$remove_reviewers_json$add_assignees_json$remove_assignees_json" = "[][][][][][]" ]; then
      evented=0
    fi
    rc=0
    gh_rest_partial_failure "$repo" "$number" "$before" "$url" gh_rest_check_edit_events "$body_landed" "$evented" || rc=$?
    return "$rc"
  fi

  gh_rest_readback "$repo" "$number" "$before" gh_rest_check_edit_events || rc=$?
  if [ "$rc" -eq 3 ]; then
    gh_rest_err "ERROR the edit of PR #$number was applied but its events could not be read back, so it is unattributed."
    printf '%s\n' "$url"
    return 5
  fi
  if [ "$body_op" -eq 1 ]; then
    gh_rest_err "note: the body edit of PR #$number is not attributable over REST (no event records who edited a body); the PATCH succeeded, and nothing here verified its byline."
  fi
  if [ "$rc" -ne 0 ]; then
    gh_rest_recovery "the mis-attributed or unattributed edit (revert it)" "$url"
    printf '%s\n' "$url"
    return 5
  fi
  if [ -n "$GH_REST_VERIFIED" ]; then
    gh_rest_err "verified edit of PR #$number by $GH_REST_EXPECTED:${GH_REST_VERIFIED%,}"
  fi
  printf '%s\n' "$url"
  return 0
}

gh_rest_pr_close() {
  GH_REST_FORM='gh pr close N --repo OWNER/REPO [--comment TEXT] [--delete-branch]' # NO_BARE_GH_WRITE_EXEMPT: usage text printed in a refusal, never executed
  local number="" repo="" comment="" comment_set=0 delete_branch=0
  gh_rest_parse_init "$@"
  while [ "$GH_REST_I" -lt "${#GH_REST_ARGS[@]}" ]; do
    gh_rest_opt || return 1
    case "$GH_REST_OPT" in
      '') number="$(gh_rest_number "$GH_REST_VAL" "$number")" || return 1 ;;
      --repo) gh_rest_value || return 1; repo="$GH_REST_VAL" ;;
      --comment) gh_rest_value || return 1; comment="$GH_REST_VAL"; comment_set=1 ;;
      --delete-branch) gh_rest_flag || return 1; delete_branch=1 ;;
      *) gh_rest_refuse "option $GH_REST_OPT is not accepted"; return 1 ;;
    esac
    GH_REST_I=$((GH_REST_I + 1))
  done
  if [ -z "$number" ]; then
    gh_rest_refuse "the pull request number is required"
    return 1
  fi
  gh_rest_check_repo "$repo" || return 1
  if [ "$comment_set" -eq 1 ] && [ -z "$comment" ]; then
    gh_rest_refuse "--comment cannot be empty"
    return 1
  fi

  local pre url state head_ref head_repo
  pre="$(gh_rest_read_pr "$repo" "$number")" || return 1
  url="$(printf '%s' "$pre" | jq -r '.html_url')"
  state="$(printf '%s' "$pre" | jq -r '.state // ""')"
  head_ref="$(printf '%s' "$pre" | jq -r '.head.ref // ""')"
  head_repo="$(printf '%s' "$pre" | jq -r '.head.repo.full_name // ""')"
  # As gh does: a merged pull request cannot be closed (non-zero), and one
  # that is already closed succeeds without the comment or the branch delete
  # (#2207). Nothing is written in either case.
  if [ "$state" != "open" ]; then
    if [ "$(printf '%s' "$pre" | jq -r '(.merged == true) or (.merged_at != null)')" = "true" ]; then
      gh_rest_err "pull request #$number ($url) can't be closed because it was already merged; nothing was written."
      return 1
    fi
    if [ "$comment_set" -eq 1 ] || [ "$delete_branch" -eq 1 ]; then
      gh_rest_err "pull request #$number ($url) is already closed; nothing was written (no comment was posted and no branch was deleted, as gh does)."
    else
      gh_rest_err "pull request #$number ($url) is already closed; nothing was written."
    fi
    return 0
  fi
  gh_rest_require_slurp "Nothing was written." || return 1
  # The pre-close events are read before anything is written, so a failed
  # read leaves the PR untouched rather than commented and still open.
  local before input rc=0 comment_url=""
  before="$(gh_rest_events "$repo" "$number")" || {
    gh_rest_err "could not read the events of PR #$number before closing it; refusing a write that could not be attributed. Nothing was written."
    return 5
  }
  if [ "$comment_set" -eq 1 ]; then
    local comment_file
    comment_file="$(gh_rest_text_file "$comment")" || return 1
    comment_url="$(gh_rest_post_comment "$repo" "$number" "$comment_file")" || return $?
  fi
  input="$(gh_rest_json_file '{state: "closed"}')" || return 1
  gh_rest_api PATCH "repos/$repo/pulls/$number" "$input" >/dev/null || {
    rc=$?
    [ -z "$comment_url" ] || gh_rest_err "the closing comment was posted ($comment_url), but closing PR #$number failed; retry the close without --comment."
    return "$rc"
  }
  gh_rest_readback "$repo" "$number" "$before" gh_rest_check_close_events || rc=$?
  if [ "$rc" -eq 3 ]; then
    gh_rest_err "ERROR PR #$number was closed but its events could not be read back, so the close is unattributed."
    return 5
  fi
  if [ "$rc" -ne 0 ]; then
    gh_rest_recovery "the close (reopen the pull request)" "$url"
    return 5
  fi
  gh_rest_err "verified close of PR #$number by $GH_REST_EXPECTED"
  if [ "$delete_branch" -eq 1 ]; then
    # GitHub repository names are case-insensitive.
    if [ -n "$head_ref" ] && [ "$(printf '%s' "$head_repo" | tr '[:upper:]' '[:lower:]')" = "$(printf '%s' "$repo" | tr '[:upper:]' '[:lower:]')" ]; then
      if gh_rest_api DELETE "repos/$repo/git/refs/heads/$(gh_rest_uri "$head_ref")" >/dev/null; then
        # The delete is attributed from the head_ref_deleted event it records
        # on the pull request, against the pre-close read (Phase 4b on #2178).
        rc=0
        gh_rest_readback "$repo" "$number" "$before" gh_rest_check_branch_delete_events || rc=$?
        if [ "$rc" -eq 3 ]; then
          gh_rest_err "ERROR branch $head_ref was deleted but the events of PR #$number could not be read back, so the delete is unattributed."
        fi
        if [ "$rc" -ne 0 ]; then
          gh_rest_recovery "the branch delete (restore branch $head_ref)" "$url"
          return 5
        fi
        gh_rest_err "verified delete of branch $head_ref on $repo by $GH_REST_EXPECTED"
      else
        gh_rest_err "PR #$number is closed, but branch $head_ref could not be deleted."
        return 1
      fi
    else
      gh_rest_err "PR #$number is closed; its head branch is on another repository (${head_repo:-unknown}) and was not deleted."
    fi
    # No local branch is deleted. gh skips local deletion whenever --repo is
    # given, because the checkout may belong to another repository with a
    # same-named branch, and this grammar always takes --repo (Codex on #2178).
    gh_rest_err "no local branch was deleted: as gh does when --repo is given, only the remote head ref is."
  fi
  gh_rest_err "Closed pull request #$number ($url)"
  return 0
}

gh_rest_merge_refused() {
  gh_rest_err "CEILING: gh pr merge does not run on the REST transport. The gates that keep a merge honest (scripts/workflow/merge-writer.py, scripts/merge-clearance-gate.sh and the merge branch of scripts/hooks/gh-pr-guard.sh) read GraphQL, which this session's proxy does not serve, and a REST merge that skipped them would not be the same merge (mergepath#1057)." # NO_BARE_GH_WRITE_EXEMPT: usage text printed in a refusal, never executed
  gh_rest_err "  Hand the merge to a session that can run the gates, with the state established here:"
  gh_rest_err "    scripts/post-local-agent-handback.sh <PR#> --blocked graphql --next \"scripts/gh-as-author.sh -- gh pr merge <PR#> --repo OWNER/REPO --squash --delete-branch --match-head-commit <full-head-sha>\""
  gh_rest_err "  Where GraphQL is served, MERGEPATH_GH_TRANSPORT=gh runs the merge through gh and its gates."
}

gh_rest_passthrough() {
  gh_rest_trace_marker || return $?
  gh_rest_exec_gh "$@"
}

# gh_rest_run <label> <expected-login> <token> <gh argv...>
gh_rest_run() {
  GH_REST_LABEL="$1"
  GH_REST_EXPECTED="$2"
  GH_REST_TOKEN="$3"
  shift 3
  GH_REST_WROTE=0
  case "${1:-}" in
    gh|*/gh) GH_REST_PAYLOAD_GH="$1" ;;
    *) gh_rest_err "the wrapped command must start with gh (got '${1:-}')."; return 1 ;;
  esac
  shift
  if [ -z "$GH_REST_EXPECTED" ] || [ -z "$GH_REST_TOKEN" ]; then
    gh_rest_err "an expected login and a verified token are required; refusing."
    return 1
  fi
  # The gh the caller named runs every REST call: bare gh is resolved through
  # PATH, an absolute path is used as given, and a relative one is refused.
  case "$GH_REST_PAYLOAD_GH" in
    gh) GH_REST_GH_BIN="$(command -v gh 2>/dev/null || true)" ;;
    /*) GH_REST_GH_BIN="$GH_REST_PAYLOAD_GH" ;;
    *) gh_rest_err "the wrapped gh must be bare gh or an absolute path (got '$GH_REST_PAYLOAD_GH'); refusing."; return 1 ;;
  esac
  case "$GH_REST_GH_BIN" in
    /*) [ -x "$GH_REST_GH_BIN" ] || { gh_rest_err "gh at '$GH_REST_GH_BIN' is not executable; refusing."; return 1; } ;;
    *) gh_rest_err "gh does not resolve to an absolute path ('${GH_REST_GH_BIN:-not found}'); refusing."; return 1 ;;
  esac
  if ! command -v jq >/dev/null 2>&1; then
    gh_rest_err "jq is required for the REST transport; refusing."
    return 1
  fi
  GH_REST_TMPDIR="$(mktemp -d "${TMPDIR:-/tmp}/gh-rest-transport.XXXXXX")" || {
    gh_rest_err "cannot create a private temporary directory; refusing."
    return 1
  }
  chmod 700 "$GH_REST_TMPDIR" 2>/dev/null || true
  local rc=0
  # Every merge spelling, including the REST merge endpoint and a GraphQL merge
  # mutation through `gh api`, is classified by the same helper the gh
  # transport uses, so none of them can pass through below. A spelling it
  # refuses outright is refused here too.
  local classifier action
  classifier="$(cd "$(dirname "${BASH_SOURCE[0]}")/../workflow" 2>/dev/null && pwd -P)/owner-admin-override.py"
  if [ ! -r "$classifier" ] || ! command -v python3 >/dev/null 2>&1; then
    gh_rest_err "the merge classifier ($classifier) or python3 is missing, so a merge cannot be told apart from another write; refusing."
    gh_rest_cleanup
    return 1
  fi
  if ! action="$(python3 -I -S "$classifier" classify gh "$@")"; then
    gh_rest_cleanup
    return 2
  fi
  if [ -n "$action" ]; then
    gh_rest_merge_refused
    gh_rest_cleanup
    return "$GH_REST_MERGE_CEILING_EXIT"
  fi
  # Options ahead of the command group (`gh --repo X pr comment`) are legal gh,
  # but the dispatch below keys on the group and verb, so every option must
  # follow the verb. Refused rather than passed through, which would run the
  # native GraphQL command with no readback.
  case "${1:-}" in
    -*)
      GH_REST_FORM='gh <group> <verb> ..., with every option after the verb' # NO_BARE_GH_WRITE_EXEMPT: usage text printed in a refusal, never executed
      gh_rest_refuse "option '${1}' before the command group is not accepted"
      gh_rest_cleanup
      return 1
      ;;
  esac
  case "${1:-} ${2:-}" in
    "pr create"|"pr new") shift 2; gh_rest_pr_create "$@" || rc=$? ;;
    "pr comment") shift 2; gh_rest_comment pr "$@" || rc=$? ;;
    "issue comment") shift 2; gh_rest_comment issue "$@" || rc=$? ;;
    "issue create") shift 2; gh_rest_issue_create "$@" || rc=$? ;;
    "pr review") shift 2; gh_rest_pr_review "$@" || rc=$? ;;
    "pr edit") shift 2; gh_rest_pr_edit "$@" || rc=$? ;;
    "pr close") shift 2; gh_rest_pr_close "$@" || rc=$? ;;
    "pr merge") gh_rest_merge_refused; rc=$GH_REST_MERGE_CEILING_EXIT ;;
    "pr "*|"issue "*)
      GH_REST_FORM='gh pr create|comment|review|edit|close ... or gh issue create|comment ..., with the verb first' # NO_BARE_GH_WRITE_EXEMPT: usage text printed in a refusal, never executed
      gh_rest_refuse "'gh ${1:-} ${2:-}' is not a form the REST transport runs"
      rc=1
      ;;
    *) gh_rest_passthrough "$@" || rc=$? ;;
  esac
  gh_rest_cleanup
  return "$rc"
}
