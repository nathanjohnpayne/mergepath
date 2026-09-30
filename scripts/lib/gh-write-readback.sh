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
#     pr-merge | pr-edit | none. Returns non-zero (and prints why) only
#     when a verb that NEEDS a readback cannot be prepared; the caller must
#     then refuse the write rather than make one it cannot verify.
#
#   gh_readback_verify <stdout-file>
#     After the write exited 0: re-reads the produced object with the same
#     token and returns 0 when its author is <expected-login>, 5 otherwise
#     (mismatch or could not verify), printing the #241 recovery text.
#
# Verbs and what is read back:
#   pr comment / issue comment  the comment gh printed the URL of
#                               (repos/R/issues/comments/ID .user.login)
#   pr review                   a review newer than the pre-write snapshot
#                               authored by the expected login
#   pr merge                    merged_by, or auto_merge.enabled_by for
#                               --auto; --disable-auto needs no readback
#   pr edit                     issue events newer than the snapshot; an
#                               edit that produced none (body-only) is
#                               reported and accepted on the pre-write check
#   `comment --delete-last`     nothing to read back
#
# Every read uses `gh api --paginate` for lists. Token material is never
# printed. Bash 3.2 portable; no top-level side effects.

GH_READBACK_KIND="none"

# gh value-taking flags per verb (the next argv token is the value, not the
# selector). `-m` is --merge (boolean) on `pr merge` but --milestone (value)
# on `pr edit`, so the table is per verb.
gh_readback_value_flags() { # <verb-key>
  case "$1" in
    pr-comment|issue-comment) echo "-b --body -F --body-file -R --repo" ;;
    pr-review) echo "-b --body -F --body-file -R --repo" ;;
    pr-merge) echo "-b --body -F --body-file -R --repo -t --subject -A --author-email --match-head-commit" ;;
    pr-edit) echo "-b --body -F --body-file -R --repo -t --title -B --base --add-label --remove-label --add-reviewer --remove-reviewer --add-assignee --remove-assignee --add-project --remove-project -m --milestone" ;;
  esac
}

_gh_readback_api() { # gh args... (reads with the verified token)
  ( unset GITHUB_TOKEN; GH_TOKEN="$GH_READBACK_TOKEN" gh "$@" )
}

_gh_readback_fail() { # <message...>
  local line
  for line in "$@"; do echo "$GH_READBACK_LABEL: $line" >&2; done
}

gh_readback_prepare() {
  GH_READBACK_EXPECTED="${1:-}"
  GH_READBACK_TOKEN="${2:-}"
  GH_READBACK_LABEL="${3:-gh-write-readback}"
  shift 3
  [ "${1:-}" = "--" ] && shift
  GH_READBACK_KIND="none"
  GH_READBACK_REPO=""
  GH_READBACK_NUMBER=""
  GH_READBACK_SNAPSHOT=""
  GH_READBACK_DISABLE_AUTO=0

  # Locate `gh`, then the first `pr|issue <verb>` pair after it.
  local seen_gh=0 group="" verb="" key="" idx=0 arg
  local -a rest
  rest=()
  for arg in "$@"; do
    if [ "$seen_gh" -eq 0 ]; then
      [ "${arg##*/}" = "gh" ] && seen_gh=1
      continue
    fi
    if [ -z "$group" ]; then
      case "$arg" in
        pr|issue) group="$arg" ;;
        -*) ;;
        *) return 0 ;;   # some other gh command: no readback
      esac
      continue
    fi
    if [ -z "$verb" ]; then
      verb="$arg"
      continue
    fi
    rest+=("$arg")
  done
  [ -n "$group" ] && [ -n "$verb" ] || return 0
  case "$group $verb" in
    "pr comment") key=pr-comment ;;
    "issue comment") key=issue-comment ;;
    "pr review") key=pr-review ;;
    "pr merge") key=pr-merge ;;
    "pr edit") key=pr-edit ;;
    *) return 0 ;;
  esac

  # Split the verb's own argv into selector / --repo / the flags we act on.
  local value_flags selector="" repo_flag="" skip="" f is_value
  value_flags=" $(gh_readback_value_flags "$key") "
  for arg in ${rest[@]+"${rest[@]}"}; do
    if [ -n "$skip" ]; then
      if [ "$skip" = "-R" ] || [ "$skip" = "--repo" ]; then repo_flag="$arg"; fi
      skip=""
      continue
    fi
    case "$arg" in
      --repo=*) repo_flag="${arg#--repo=}"; continue ;;
      -R?*) repo_flag="${arg#-R}"; repo_flag="${repo_flag#=}"; continue ;;
      --delete-last) GH_READBACK_KIND="none"; return 0 ;;
      --disable-auto) GH_READBACK_DISABLE_AUTO=1 ;;
    esac
    is_value=0
    case "$value_flags" in *" $arg "*) is_value=1 ;; esac
    if [ "$is_value" -eq 1 ]; then
      skip="$arg"
      continue
    fi
    case "$arg" in
      -*) ;;
      *) [ -z "$selector" ] && selector="$arg" ;;
    esac
  done

  if ! command -v jq >/dev/null 2>&1; then
    _gh_readback_fail "jq is required to verify the byline of a '$group $verb' write; refusing to write unverified."
    return 1
  fi

  # Resolve the target number and repository through gh itself, so every
  # selector form gh accepts (number, URL, branch, none) resolves the same way
  # the write will.
  local -a view
  view=("$group" view)
  [ -n "$selector" ] && view+=("$selector")
  [ -n "$repo_flag" ] && view+=(--repo "$repo_flag")
  local target
  if ! target="$(_gh_readback_api "${view[@]}" --json number,url --jq '"\(.number) \(.url)"' 2>/dev/null)" || [ -z "$target" ]; then
    _gh_readback_fail "could not resolve the target of '$group $verb' (gh $group view failed); refusing to write without a byline readback (#1057)."
    return 1
  fi
  GH_READBACK_NUMBER="${target%% *}"
  GH_READBACK_REPO="$(printf '%s\n' "${target#* }" | sed -nE 's#^https://[^/]+/([^/]+/[^/]+)/(pull|issues)/[0-9]+.*#\1#p')"
  if ! printf '%s' "$GH_READBACK_NUMBER" | grep -Eq '^[0-9]+$' || [ -z "$GH_READBACK_REPO" ]; then
    _gh_readback_fail "could not parse the target of '$group $verb' ($target); refusing to write without a byline readback."
    return 1
  fi

  local ids
  case "$key" in
    pr-review)
      if ! ids="$(_gh_readback_api api --paginate "repos/$GH_READBACK_REPO/pulls/$GH_READBACK_NUMBER/reviews" --jq '.[].id' 2>/dev/null)"; then
        _gh_readback_fail "could not snapshot existing reviews on $GH_READBACK_REPO#$GH_READBACK_NUMBER; refusing to write without a byline readback."
        return 1
      fi
      GH_READBACK_SNAPSHOT="$(printf '%s\n' "$ids" | grep -E '^[0-9]+$' | sort -n | tail -1)"
      GH_READBACK_SNAPSHOT="${GH_READBACK_SNAPSHOT:-0}"
      ;;
    pr-edit)
      if ! ids="$(_gh_readback_api api --paginate "repos/$GH_READBACK_REPO/issues/$GH_READBACK_NUMBER/events" --jq '.[].id' 2>/dev/null)"; then
        _gh_readback_fail "could not snapshot existing events on $GH_READBACK_REPO#$GH_READBACK_NUMBER; refusing to write without a byline readback."
        return 1
      fi
      GH_READBACK_SNAPSHOT="$(printf '%s\n' "$ids" | grep -E '^[0-9]+$' | sort -n | tail -1)"
      GH_READBACK_SNAPSHOT="${GH_READBACK_SNAPSHOT:-0}"
      ;;
  esac
  GH_READBACK_KIND="$key"
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

gh_readback_verify() {
  local out="${1:-}" id login
  case "$GH_READBACK_KIND" in
    none) return 0 ;;
    pr-comment|issue-comment)
      id="$(grep -oE '#issuecomment-[0-9]+' "$out" 2>/dev/null | tail -1 | sed 's/#issuecomment-//' || true)"
      [ -n "$id" ] || { _gh_readback_unverified "the comment (gh printed no comment URL)"; return $?; }
      login="$(_gh_readback_api api "repos/$GH_READBACK_REPO/issues/comments/$id" --jq '.user.login' 2>/dev/null || true)"
      [ -n "$login" ] || { _gh_readback_unverified "comment $id"; return $?; }
      [ "$login" = "$GH_READBACK_EXPECTED" ] || { _gh_readback_mismatch "comment $id" "$login"; return $?; }
      echo "$GH_READBACK_LABEL: verified comment $id author=$login" >&2
      ;;
    pr-review)
      login="$(_gh_readback_api api --paginate "repos/$GH_READBACK_REPO/pulls/$GH_READBACK_NUMBER/reviews" \
        --jq ".[] | select(.id > $GH_READBACK_SNAPSHOT) | .user.login" 2>/dev/null)" \
        || { _gh_readback_unverified "the review"; return $?; }
      if printf '%s\n' "$login" | grep -qxF -- "$GH_READBACK_EXPECTED"; then
        echo "$GH_READBACK_LABEL: verified review author=$GH_READBACK_EXPECTED" >&2
      elif [ -n "$login" ]; then
        _gh_readback_mismatch "the review" "$(printf '%s\n' "$login" | head -1)"; return $?
      else
        _gh_readback_unverified "the review (no review newer than the pre-write snapshot)"; return $?
      fi
      ;;
    pr-merge)
      [ "$GH_READBACK_DISABLE_AUTO" -eq 1 ] && return 0
      local state
      state="$(_gh_readback_api api "repos/$GH_READBACK_REPO/pulls/$GH_READBACK_NUMBER" \
        --jq 'if .merged then "merged \(.merged_by.login // "")" elif .auto_merge then "auto \(.auto_merge.enabled_by.login // "")" else "open " end' 2>/dev/null || true)"
      login="${state#* }"
      case "$state" in
        merged\ ?*|auto\ ?*)
          [ "$login" = "$GH_READBACK_EXPECTED" ] || { _gh_readback_mismatch "the ${state%% *} action" "$login"; return $?; }
          echo "$GH_READBACK_LABEL: verified ${state%% *} by $login" >&2
          ;;
        *) _gh_readback_unverified "the merge (the PR is neither merged nor armed for auto-merge)"; return $? ;;
      esac
      ;;
    pr-edit)
      login="$(_gh_readback_api api --paginate "repos/$GH_READBACK_REPO/issues/$GH_READBACK_NUMBER/events" \
        --jq ".[] | select(.id > $GH_READBACK_SNAPSHOT) | .actor.login" 2>/dev/null)" \
        || { _gh_readback_unverified "the edit"; return $?; }
      if printf '%s\n' "$login" | grep -qxF -- "$GH_READBACK_EXPECTED"; then
        echo "$GH_READBACK_LABEL: verified edit events by $GH_READBACK_EXPECTED" >&2
      elif [ -n "$login" ]; then
        _gh_readback_mismatch "the edit" "$(printf '%s\n' "$login" | head -1)"; return $?
      else
        echo "$GH_READBACK_LABEL: the edit produced no issue event to read back (a body-only edit leaves none); accepted on the pre-write credential check." >&2
      fi
      ;;
  esac
  return 0
}
