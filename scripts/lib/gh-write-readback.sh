#!/usr/bin/env bash
# scripts/lib/gh-write-readback.sh — read back the byline of a guarded write
# after it lands (#1057 item A2, layer 3).
#
# Why this exists:
#
#   The wrappers verify a token BEFORE the write (identity-check.sh
#   --expect-write-identity). That check reasons about the credential. This
#   one reads the object the write produced and checks who GitHub says wrote
#   it, which holds whatever brokering scheme the environment uses — and on
#   Codex, where no PreToolUse guard runs, it is the only check that does.
#   gh-as-author.sh has done this for `gh pr create` since #241; this extends
#   it to every other guarded verb.
#
# Source this file, then:
#
#   gh_readback_prepare <expected-login> <token> <label> -- <gh argv...>
#     Classifies argv. For a verb with a readback, resolves the target and
#     snapshots what the write will be compared against. Sets
#     GH_READBACK_KIND to one of pr-comment | issue-comment | pr-review |
#     pr-merge | pr-edit | none. Returns non-zero (and prints why) when a
#     verb that NEEDS a readback cannot be prepared; the caller must then
#     refuse the write rather than make one it cannot verify.
#
#   gh_readback_verify <stdout-file>
#     After the write exited 0: re-reads what THIS write produced with the
#     same token and returns 0 when its author is <expected-login>, 5
#     otherwise (mismatch, ambiguous, or could not verify), printing the
#     #241 recovery text.
#
#   gh_readback_interactive
#     Exit 0 when the wrapped command can prompt (stdin and stdout are both
#     terminals). The wrappers then run it attached to the terminal instead
#     of capturing stdout, since capturing makes gh refuse to prompt.
#
# Parsing. Every argument after `gh` is read, whichever side of the group or
# verb it sits on: `gh --repo o/r pr review`, `gh pr --repo o/r review`,
# `gh pr review --repo=o/r` and `-Ro/r` all select the same repository. A
# guarded verb whose argv does not start with `gh` (an `env -C`, `sudo`, or
# `GH_REPO=` prefix) is refused: its execution context is not the one the
# readback would resolve the target in.
#
# Correlation (a newer object by the right login is not enough; it must be
# THIS write's object, and ambiguity fails closed):
#   pr comment / issue comment  the comment gh printed the URL of
#   pr review                   the reviews newer than a pre-write snapshot
#                               whose state and body match this write; every
#                               match must be the expected login
#   pr merge                    merged_by; auto_merge.enabled_by for --auto;
#                               the merge-queue entry's enqueuer when the PR
#                               was queued; --disable-auto needs no readback
#   pr edit                     for each change that produces an issue event
#                               (label, title, assignee, reviewer,
#                               milestone), a newer event of that kind and
#                               name by the expected login, and none by
#                               anyone else
#
# What cannot be attributed through REST is reported, never claimed
# verified: a body/base/project-only edit leaves no issue event, and a
# comment `--edit-last` keeps the ORIGINAL author on the comment. Those are
# accepted on the pre-write credential check with a stderr notice.
#
# Every read is REST (`gh api`), pinned to the host the target resolved to,
# except the merge-queue enqueuer, which exists only in GraphQL. Lists use
# --paginate. Token material is never printed. Bash 3.2 portable; no
# top-level side effects.

GH_READBACK_KIND="none"

_gh_readback_api() { # gh api args... (reads with the verified token, on the target host)
  local -a host_args
  host_args=()
  [ -n "${GH_READBACK_HOST:-}" ] && [ "$GH_READBACK_HOST" != "github.com" ] && host_args=(--hostname "$GH_READBACK_HOST")
  ( unset GITHUB_TOKEN; GH_TOKEN="$GH_READBACK_TOKEN" gh api ${host_args[@]+"${host_args[@]}"} "$@" )
}

_gh_readback_fail() { # <message...>
  local line
  for line in "$@"; do echo "$GH_READBACK_LABEL: $line" >&2; done
}

gh_readback_interactive() {
  [ -t 0 ] && [ -t 1 ]
}

# Value-taking flags of the guarded verbs, shared by every verb because a
# flag the verb does not accept makes gh itself fail before any write. `-m`
# and `-r` are booleans on `pr merge` (--merge, --rebase) and on `pr review`
# (--request-changes), but -m is --milestone on `pr edit`, hence the key.
_gh_readback_takes_value() { # <verb-key> <flag>
  case "$2" in
    -R|--repo|-b|--body|-F|--body-file|--attach) return 0 ;;
  esac
  case "$1:$2" in
    pr-merge:-A|pr-merge:--author-email|pr-merge:-t|pr-merge:--subject|pr-merge:--match-head-commit) return 0 ;;
    pr-edit:-t|pr-edit:--title|pr-edit:-B|pr-edit:--base|pr-edit:-m|pr-edit:--milestone) return 0 ;;
    pr-edit:--add-label|pr-edit:--remove-label|pr-edit:--add-assignee|pr-edit:--remove-assignee) return 0 ;;
    pr-edit:--add-reviewer|pr-edit:--remove-reviewer|pr-edit:--add-project|pr-edit:--remove-project) return 0 ;;
  esac
  return 1
}

_gh_readback_note_body() { # <flag> <value>: record the body this write sends
  case "$1" in
    -b|--body) GH_READBACK_BODY="$2"; GH_READBACK_BODY_KNOWN=1 ;;
    -F|--body-file)
      if [ "$2" != "-" ] && [ "$2" != "/dev/stdin" ] && [ -r "$2" ]; then
        GH_READBACK_BODY="$(cat "$2")"; GH_READBACK_BODY_KNOWN=1
      else
        GH_READBACK_BODY_KNOWN=0
      fi ;;
  esac
}

_gh_readback_note_edit() { # <flag> <value>: record the events this edit must produce
  local item IFS=,
  case "$1" in
    --add-label) for item in $2; do GH_READBACK_EDIT_EXPECT+=("labeled:$item"); done ;;
    --remove-label) for item in $2; do GH_READBACK_EDIT_EXPECT+=("unlabeled:$item"); done ;;
    --add-assignee) for item in $2; do GH_READBACK_EDIT_EXPECT+=("assigned:$item"); done ;;
    --remove-assignee) for item in $2; do GH_READBACK_EDIT_EXPECT+=("unassigned:$item"); done ;;
    --add-reviewer) for item in $2; do GH_READBACK_EDIT_EXPECT+=("review_requested:$item"); done ;;
    --remove-reviewer) for item in $2; do GH_READBACK_EDIT_EXPECT+=("review_request_removed:$item"); done ;;
    -t|--title) GH_READBACK_EDIT_EXPECT+=("renamed:") ;;
    -m|--milestone) GH_READBACK_EDIT_EXPECT+=("milestoned:$2") ;;
    --remove-milestone) GH_READBACK_EDIT_EXPECT+=("demilestoned:") ;;
  esac
}

gh_readback_prepare() {
  GH_READBACK_EXPECTED="${1:-}"
  GH_READBACK_TOKEN="${2:-}"
  GH_READBACK_LABEL="${3:-gh-write-readback}"
  shift 3
  [ "${1:-}" = "--" ] && shift
  GH_READBACK_KIND="none"
  GH_READBACK_REPO=""
  GH_READBACK_HOST=""
  GH_READBACK_NUMBER=""
  GH_READBACK_SNAPSHOT=""
  GH_READBACK_BODY=""
  GH_READBACK_BODY_KNOWN=0
  GH_READBACK_REVIEW_STATE=""
  GH_READBACK_EDIT_EXPECT=()
  GH_READBACK_NOTE=""
  GH_READBACK_DISABLE_AUTO=0

  # Classify the whole argv first: the group and verb are the first two
  # non-option words after `gh`, skipping the value of any option that takes
  # one; options on either side of them are collected in one pass.
  local prefixed=0 seen_gh=0 group="" verb="" key="" pending="" arg repo_flag="" selector=""
  local -a opts
  opts=()
  if [ "$#" -gt 0 ] && [ "${1##*/}" != "gh" ]; then
    prefixed=1
  fi
  for arg in "$@"; do
    if [ "$seen_gh" -eq 0 ]; then
      [ "${arg##*/}" = "gh" ] && seen_gh=1
      continue
    fi
    if [ -n "$pending" ]; then
      opts+=("$pending" "$arg")
      pending=""
      continue
    fi
    case "$arg" in
      --repo=*|--body=*|--body-file=*|--title=*|--add-label=*|--remove-label=*|--add-assignee=*|--remove-assignee=*|--add-reviewer=*|--remove-reviewer=*|--milestone=*|--subject=*|--base=*)
        opts+=("${arg%%=*}" "${arg#*=}"); continue ;;
      -R?*) opts+=(-R "${arg#-R}"); continue ;;
      -*)
        if [ -z "$verb" ] && [ "$arg" != "--help" ]; then
          # Before the verb only -R/--repo take a value.
          case "$arg" in -R|--repo) pending="$arg"; continue ;; esac
        elif [ -n "$verb" ] && _gh_readback_takes_value "$key" "$arg"; then
          pending="$arg"; continue
        fi
        opts+=("$arg" "")
        continue
        ;;
    esac
    if [ -z "$group" ]; then
      group="$arg"
      case "$group" in
        pr|issue) ;;
        api) _gh_readback_prepare_api "$@"; return $? ;;
        *) return 0 ;;
      esac
      continue
    fi
    if [ -z "$verb" ]; then
      verb="$arg"
      case "$group $verb" in
        "pr comment") key=pr-comment ;;
        "issue comment") key=issue-comment ;;
        "pr review") key=pr-review ;;
        "pr merge") key=pr-merge ;;
        "pr edit") key=pr-edit ;;
        *) return 0 ;;
      esac
      continue
    fi
    [ -z "$selector" ] && selector="$arg"
  done
  [ -n "$key" ] || return 0

  if [ "$prefixed" -eq 1 ]; then
    _gh_readback_fail "a '$group $verb' behind a command prefix runs in a context the byline readback cannot resolve (#1057); call gh directly and pass --repo instead."
    return 1
  fi
  if ! command -v jq >/dev/null 2>&1; then
    _gh_readback_fail "jq is required to verify the byline of a '$group $verb' write; refusing to write unverified."
    return 1
  fi

  local i=0 flag value
  while [ "$i" -lt "${#opts[@]}" ]; do
    flag="${opts[$i]}"; value="${opts[$((i + 1))]}"
    i=$((i + 2))
    case "$flag" in
      -R|--repo) repo_flag="$value" ;;
      -b|--body|-F|--body-file) _gh_readback_note_body "$flag" "$value" ;;
      --delete-last) GH_READBACK_KIND="none"; return 0 ;;
      --edit-last) GH_READBACK_NOTE="edit-last" ;;
      --disable-auto) GH_READBACK_DISABLE_AUTO=1 ;;
      -a|--approve) [ "$key" = "pr-review" ] && GH_READBACK_REVIEW_STATE="APPROVED" ;;
      -r|--request-changes) [ "$key" = "pr-review" ] && GH_READBACK_REVIEW_STATE="CHANGES_REQUESTED" ;;
      -c|--comment) [ "$key" = "pr-review" ] && GH_READBACK_REVIEW_STATE="COMMENTED" ;;
    esac
    [ "$key" = "pr-edit" ] && _gh_readback_note_edit "$flag" "$value"
  done

  # Resolve the target through gh itself, so every selector form gh accepts
  # (number, URL, branch, none) resolves the same way the write will, and
  # keep the host it resolved on for every later read.
  local -a view
  view=("$group" view)
  [ -n "$selector" ] && view+=("$selector")
  [ -n "$repo_flag" ] && view+=(--repo "$repo_flag")
  local target url
  if ! target="$( ( unset GITHUB_TOKEN; GH_TOKEN="$GH_READBACK_TOKEN" gh "${view[@]}" --json number,url --jq '"\(.number) \(.url)"' ) 2>/dev/null)" || [ -z "$target" ]; then
    _gh_readback_fail "could not resolve the target of '$group $verb' (gh $group view failed); refusing to write without a byline readback (#1057)."
    return 1
  fi
  GH_READBACK_NUMBER="${target%% *}"
  url="${target#* }"
  GH_READBACK_HOST="$(printf '%s\n' "$url" | sed -nE 's#^https://([^/]+)/[^/]+/[^/]+/(pull|issues)/[0-9]+.*#\1#p')"
  GH_READBACK_REPO="$(printf '%s\n' "$url" | sed -nE 's#^https://[^/]+/([^/]+/[^/]+)/(pull|issues)/[0-9]+.*#\1#p')"
  if ! printf '%s' "$GH_READBACK_NUMBER" | grep -Eq '^[0-9]+$' || [ -z "$GH_READBACK_REPO" ] || [ -z "$GH_READBACK_HOST" ]; then
    _gh_readback_fail "could not parse the target of '$group $verb' ($target); refusing to write without a byline readback."
    return 1
  fi

  local ids path=""
  case "$key" in
    pr-review) path="repos/$GH_READBACK_REPO/pulls/$GH_READBACK_NUMBER/reviews" ;;
    pr-edit) path="repos/$GH_READBACK_REPO/issues/$GH_READBACK_NUMBER/events" ;;
  esac
  if [ -n "$path" ]; then
    if ! ids="$(_gh_readback_api --paginate "$path" --jq '.[].id' 2>/dev/null)"; then
      _gh_readback_fail "could not snapshot $path before the write; refusing to write without a byline readback."
      return 1
    fi
    GH_READBACK_SNAPSHOT="$(printf '%s\n' "$ids" | grep -E '^[0-9]+$' | sort -n | tail -1)"
    GH_READBACK_SNAPSHOT="${GH_READBACK_SNAPSHOT:-0}"
  fi
  GH_READBACK_KIND="$key"
  return 0
}

# `gh api` writes (#1057, Codex on #1541). A REST write whose response names
# its author (a review, a comment, a reaction) is checked against the expected
# login from the response itself; the wrappers capture stdout for this. A GET,
# a response with no author object, or one filtered by --jq/--template carries
# nothing to check, and is left alone rather than claimed verified.
_gh_readback_prepare_api() {
  local arg method="" fields=0 filtered=0 prev=""
  for arg in "$@"; do
    case "$prev" in
      -X|--method) method="$arg" ;;
    esac
    case "$arg" in
      -X?*) method="${arg#-X}" ;;
      --method=*) method="${arg#--method=}" ;;
      -f|-F|--field|--raw-field|--input|-f?*|-F?*|--field=*|--raw-field=*|--input=*) fields=1 ;;
      -q|--jq|-t|--template|--jq=*|--template=*|-q?*|-t?*) filtered=1 ;;
    esac
    prev="$arg"
  done
  [ -z "$method" ] && [ "$fields" -eq 1 ] && method=POST
  method="$(printf '%s' "$method" | tr 'a-z' 'A-Z')"
  case "$method" in
    POST|PATCH|PUT) ;;
    *) return 0 ;;
  esac
  [ "$filtered" -eq 1 ] && return 0
  command -v jq >/dev/null 2>&1 || return 0
  GH_READBACK_KIND="api-write"
  return 0
}

_gh_readback_mismatch() { # <what> <actual>
  _gh_readback_fail \
    "ERROR $1 on $GH_READBACK_REPO#$GH_READBACK_NUMBER landed under '$2', expected '$GH_READBACK_EXPECTED'." \
    "This is the #241 mis-attribution class: the effective credential did not write as the verified identity (#1057)." \
    "Recovery: delete or retract the object written under '$2', then repeat the write through the wrapper with a user-held token for '$GH_READBACK_EXPECTED'." \
    "See REVIEW_POLICY.md § Recovery: PR created under the wrong identity."
  return 5
}

_gh_readback_unverified() { # <what>
  _gh_readback_fail \
    "ERROR could not read back the author of $1 on $GH_READBACK_REPO#$GH_READBACK_NUMBER; refusing to treat the write as verified." \
    "The write may still have landed; check its author manually before repeating it."
  return 5
}

_gh_readback_unattributable() { # <what>: accepted on the pre-write check, and said so
  _gh_readback_fail "$1 leaves no author record that REST exposes; accepted on the pre-write credential check, not read back."
  return 0
}

_gh_readback_verify_review() {
  local reviews matches others
  reviews="$(_gh_readback_api --paginate "repos/$GH_READBACK_REPO/pulls/$GH_READBACK_NUMBER/reviews" 2>/dev/null | jq -s 'add // []' 2>/dev/null)" \
    || { _gh_readback_unverified "the review"; return $?; }
  # Correlate: newer than the snapshot, the state this write asked for (when
  # it named one), and the body it sent (when known; GitHub stores a review's
  # body as sent, and an empty one for --approve without --body).
  matches="$(printf '%s' "$reviews" | jq -c \
      --argjson snap "$GH_READBACK_SNAPSHOT" \
      --arg state "$GH_READBACK_REVIEW_STATE" \
      --arg body "$GH_READBACK_BODY" \
      --argjson body_known "$GH_READBACK_BODY_KNOWN" \
      '[.[] | select(.id > $snap)
            | select($state == "" or .state == $state)
            | select($body_known == 0 or ((.body // "") | gsub("\\s+$"; "")) == ($body | gsub("\\s+$"; "")))]' 2>/dev/null)" \
    || { _gh_readback_unverified "the review"; return $?; }
  if [ "$(printf '%s' "$matches" | jq 'length')" -eq 0 ]; then
    _gh_readback_unverified "the review (no review newer than the pre-write snapshot matches this write's state and body)"; return $?
  fi
  others="$(printf '%s' "$matches" | jq -r --arg me "$GH_READBACK_EXPECTED" '[.[] | select(.user.login != $me) | .user.login] | first // empty')"
  if [ -n "$others" ]; then
    _gh_readback_mismatch "the review" "$others"; return $?
  fi
  echo "$GH_READBACK_LABEL: verified review author=$GH_READBACK_EXPECTED" >&2
}

_gh_readback_verify_edit() {
  if [ "${#GH_READBACK_EDIT_EXPECT[@]}" -eq 0 ]; then
    _gh_readback_unattributable "This edit (body, base or project only)"; return $?
  fi
  local events want kind name found others
  events="$(_gh_readback_api --paginate "repos/$GH_READBACK_REPO/issues/$GH_READBACK_NUMBER/events" 2>/dev/null | jq -s 'add // []' 2>/dev/null)" \
    || { _gh_readback_unverified "the edit"; return $?; }
  for want in "${GH_READBACK_EDIT_EXPECT[@]}"; do
    kind="${want%%:*}"; name="${want#*:}"
    # `@me`/`@copilot` style shorthands name no literal login to match on.
    case "$name" in @*) name="" ;; esac
    found="$(printf '%s' "$events" | jq -c --argjson snap "$GH_READBACK_SNAPSHOT" --arg kind "$kind" --arg name "$name" '
        [.[] | select(.id > $snap and .event == $kind)
             | select($name == ""
                      or (.label.name // .assignee.login // .requested_reviewer.login // .milestone.title // "") == $name)]')"
    if [ "$(printf '%s' "$found" | jq 'length')" -eq 0 ]; then
      _gh_readback_unverified "the edit (no '$kind${name:+ $name}' event newer than the pre-write snapshot)"; return $?
    fi
    others="$(printf '%s' "$found" | jq -r --arg me "$GH_READBACK_EXPECTED" '[.[] | select(.actor.login != $me) | .actor.login] | first // empty')"
    if [ -n "$others" ]; then
      _gh_readback_mismatch "the edit ('$kind' event)" "$others"; return $?
    fi
  done
  echo "$GH_READBACK_LABEL: verified edit events by $GH_READBACK_EXPECTED" >&2
}

_gh_readback_verify_merge() {
  [ "$GH_READBACK_DISABLE_AUTO" -eq 1 ] && return 0
  local state login owner name
  state="$(_gh_readback_api "repos/$GH_READBACK_REPO/pulls/$GH_READBACK_NUMBER" \
    --jq 'if .merged then "merged \(.merged_by.login // "")" elif .auto_merge then "auto \(.auto_merge.enabled_by.login // "")" else "open " end' 2>/dev/null || true)"
  if [ "$state" = "open " ]; then
    # Admission to a merge queue leaves the PR open with no auto_merge; the
    # queue entry's enqueuer is the actor, and exists only in GraphQL.
    owner="${GH_READBACK_REPO%%/*}"; name="${GH_READBACK_REPO#*/}"
    login="$(_gh_readback_api graphql -f query='query($o:String!,$n:String!,$p:Int!){repository(owner:$o,name:$n){pullRequest(number:$p){mergeQueueEntry{enqueuer{login}}}}}' \
      -f o="$owner" -f n="$name" -F p="$GH_READBACK_NUMBER" \
      --jq '.data.repository.pullRequest.mergeQueueEntry.enqueuer.login // empty' 2>/dev/null || true)"
    [ -n "$login" ] && state="queued $login"
  fi
  login="${state#* }"
  case "$state" in
    merged\ ?*|auto\ ?*|queued\ ?*)
      [ "$login" = "$GH_READBACK_EXPECTED" ] || { _gh_readback_mismatch "the ${state%% *} action" "$login"; return $?; }
      echo "$GH_READBACK_LABEL: verified ${state%% *} by $login" >&2
      ;;
    *) _gh_readback_unverified "the merge (the PR is neither merged, armed for auto-merge, nor queued)"; return $? ;;
  esac
}

gh_readback_verify() {
  local out="${1:-}" id login
  case "$GH_READBACK_KIND" in
    none) return 0 ;;
    pr-comment|issue-comment)
      if [ "$GH_READBACK_NOTE" = "edit-last" ]; then
        # The REST comment keeps its ORIGINAL author when someone else edits
        # it, so the editor of --edit-last is not observable here.
        _gh_readback_unattributable "Editing the last comment (--edit-last)"; return $?
      fi
      id="$(grep -oE '#issuecomment-[0-9]+' "$out" 2>/dev/null | tail -1 | sed 's/#issuecomment-//' || true)"
      if [ -z "$id" ] && gh_readback_interactive; then
        _gh_readback_unattributable "An interactive comment (gh prints its URL to the terminal, not to the wrapper)"; return $?
      fi
      [ -n "$id" ] || { _gh_readback_unverified "the comment (gh printed no comment URL)"; return $?; }
      login="$(_gh_readback_api "repos/$GH_READBACK_REPO/issues/comments/$id" --jq '.user.login' 2>/dev/null || true)"
      [ -n "$login" ] || { _gh_readback_unverified "comment $id"; return $?; }
      [ "$login" = "$GH_READBACK_EXPECTED" ] || { _gh_readback_mismatch "comment $id" "$login"; return $?; }
      echo "$GH_READBACK_LABEL: verified comment $id author=$login" >&2
      ;;
    api-write)
      login="$(jq -r 'if type == "object" and (.user.login | type) == "string" then .user.login else empty end' "$out" 2>/dev/null || true)"
      [ -n "$login" ] || return 0
      if [ "$login" != "$GH_READBACK_EXPECTED" ]; then
        GH_READBACK_REPO="${GH_READBACK_REPO:-the API}"; GH_READBACK_NUMBER="${GH_READBACK_NUMBER:-write}"
        _gh_readback_mismatch "the object this API write created" "$login"; return $?
      fi
      echo "$GH_READBACK_LABEL: verified API write author=$login" >&2
      ;;
    pr-review) _gh_readback_verify_review; return $? ;;
    pr-merge) _gh_readback_verify_merge; return $? ;;
    pr-edit) _gh_readback_verify_edit; return $? ;;
  esac
  return 0
}
