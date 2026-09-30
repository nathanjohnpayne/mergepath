#!/usr/bin/env bash
# Shared GitHub token resolver for agent write wrappers.
#
# Source this file from a wrapper, then call:
#
#   gh_resolve_token_for_identity <expected-login> <preferred-env-var> <label>
#
# On success it sets GH_RESOLVED_TOKEN in the caller's shell. It never
# prints token material. The selected token is verified with
# scripts/identity-check.sh --expect-write-identity before the caller
# can use it for a write: the login must match AND the token must be a
# user-held credential, because a brokered token can read as the right
# login and still write under a bot's (#1057).
#
# Bash 3.2 portable.

gh_resolver_repo_root() {
  local this_dir
  this_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
  printf '%s\n' "$this_dir"
}

# gh sends GH_TOKEN only to github.com; any other host reads
# GH_ENTERPRISE_TOKEN / GITHUB_ENTERPRISE_TOKEN, then a stored login. The
# wrappers set both to this fixed non-credential value for the wrapped command:
# no ambient Enterprise token or stored login can carry a guarded write, and a
# non-GitHub destination (--hostname, --repo host/o/r, GH_REPO) receives this
# string instead of the verified PAT, so its request fails authentication
# rather than exposing the credential (#1057; Codex and CodeRabbit on #1541).
# shellcheck disable=SC2034
GH_WRAPPER_NO_ENTERPRISE_CREDENTIAL="mergepath-guarded-write-github-com-only"

# The wrappers verify one token and run the payload under it. Anything in
# front of `gh` (env, sudo, command, nice, ...) can replace or drop that
# token after verification: `env GH_TOKEN=proxy-injected gh pr comment` writes
# as the broker (Codex P1 on #1541). Rather than enumerate the forms that can,
# accept only a payload whose first word is gh itself.
gh_require_direct_gh_payload() { # <label> <payload...>
  local label="$1"
  shift
  case "${1:-}" in
    gh|*/gh) return 0 ;;
  esac
  echo "$label: the wrapped command must start with gh (got '${1:-}')." >&2
  echo "$label:   A prefix such as env, sudo or command can replace the verified token after it is checked; run gh directly." >&2
  return 1
}

# The author wrapper also runs bootstrap's initial `git push` (Codex on #1541).
# A gh identity check does not prove which credential git authenticates
# with, so that path is a closed contract, not a pass-through:
#
#   git [-C <dir>] push [-u|--set-upstream] <remote-name> [<refspec>...]
#
# No -c, no --config-env, no URL argument, no other subcommand. Prints
# "gh" or "git-push" for an accepted author payload; refuses anything else.
gh_author_payload_kind() { # <payload...>
  case "${1:-}" in
    gh|*/gh) printf 'gh\n'; return 0 ;;
    git|*/git) ;;
    *)
      gh_require_direct_gh_payload "gh-as-author" "$@"
      return 1
      ;;
  esac
  shift
  if [ "${1:-}" = "-C" ] && [ -n "${2:-}" ]; then shift 2; fi
  if [ "${1:-}" != "push" ]; then
    echo "gh-as-author: the only git command accepted is: git [-C <dir>] push [-u] <remote> [<refspec>...] (got 'git ${1:-}')." >&2
    return 1
  fi
  shift
  case "${1:-}" in -u|--set-upstream) shift ;; esac
  case "${1:-}" in
    ''|-*|*/*|*:*|*@*)
      echo "gh-as-author: git push needs a plain remote name, not '${1:-}' (no URL, no option)." >&2
      return 1
      ;;
  esac
  shift
  local ref
  for ref in "$@"; do
    case "$ref" in
      ''|-*|*://*|*@\{*) ;;
      *[!A-Za-z0-9._/:+^~-]*) ;;
      *) continue ;;
    esac
    echo "gh-as-author: git push refspec '$ref' is not accepted (options, URLs and shell-special forms are refused)." >&2
    return 1
  done
  printf 'git-push\n'
}

# Run git so that the ONLY credential it can present to github.com is
# <token>. Global and system config, ~/.netrc and XDG config are out of reach
# (throwaway HOME, GIT_CONFIG_GLOBAL=/dev/null, GIT_CONFIG_NOSYSTEM), config
# injected through the environment is dropped, the credential helper list is
# reset to gh's (which reads GH_TOKEN), extra headers are reset, and SSH forms
# of github.com are rewritten to HTTPS so the helper, not an SSH key, decides.
gh_author_git_exec() { # <token> <git args...>
  local token="$1" home rc
  shift
  home="$(mktemp -d "${TMPDIR:-/tmp}/gh-as-author-git-home.XXXXXX")" || return 1
  env -u GITHUB_TOKEN -u GIT_CONFIG_PARAMETERS -u GIT_CONFIG_COUNT -u GIT_CONFIG \
    HOME="$home" XDG_CONFIG_HOME="$home/.config" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
    GIT_TERMINAL_PROMPT=0 GIT_ASKPASS= SSH_ASKPASS= \
    GH_TOKEN="$token" GH_ENTERPRISE_TOKEN="$GH_WRAPPER_NO_ENTERPRISE_CREDENTIAL" \
    GITHUB_ENTERPRISE_TOKEN="$GH_WRAPPER_NO_ENTERPRISE_CREDENTIAL" \
    git -c credential.helper= -c 'credential.helper=!gh auth git-credential' \
        -c http.extraHeader= \
        -c url.https://github.com/.insteadOf=git@github.com: \
        -c url.https://github.com/.insteadOf=ssh://git@github.com/ \
        "$@"
  rc=$?
  rm -rf "$home"
  return "$rc"
}

# Push under <token> after proving the push can only authenticate with it:
# the repository's own config may not carry http.*, credential.* or url.*
# keys (a repo-local extra header, helper or rewrite would outrank nothing we
# pin, or redirect the push), and the resolved push URL must be plain
# https://github.com/ with no embedded credentials.
gh_author_git_push() { # <token> <git args as accepted by gh_author_payload_kind, minus "git">
  local token="$1"
  shift
  local -a dir_args=()
  if [ "${1:-}" = "-C" ]; then dir_args=(-C "$2"); fi
  local -a rest=("$@")
  local i=0
  [ "${#dir_args[@]}" -gt 0 ] && i=2
  i=$((i + 1))                                   # past "push"
  case "${rest[$i]:-}" in -u|--set-upstream) i=$((i + 1)) ;; esac
  local remote="${rest[$i]}" local_keys url
  local_keys="$(git ${dir_args[@]+"${dir_args[@]}"} config --local --includes --name-only --get-regexp '^(http|credential|url)\.' 2>/dev/null || true)"
  if [ -n "$local_keys" ]; then
    echo "gh-as-author: refusing git push: this repository's config sets keys that can change the credential or destination:" >&2
    printf '  %s\n' $local_keys >&2
    return 5
  fi
  if ! url="$(gh_author_git_exec "$token" ${dir_args[@]+"${dir_args[@]}"} remote get-url --push "$remote" 2>/dev/null)"; then
    echo "gh-as-author: refusing git push: remote '$remote' has no push URL." >&2
    return 5
  fi
  case "$url" in
    https://github.com/*@*|https://*@*) ;;
    https://github.com/*) gh_author_git_exec "$token" "$@"; return $? ;;
  esac
  # Never echo the URL: it may carry a credential in its userinfo.
  echo "gh-as-author: refusing git push: remote '$remote' does not resolve to https://github.com/ without embedded credentials." >&2
  return 5
}

gh_default_reviewer_identity() {
  if [ -n "${GH_AS_REVIEWER_IDENTITY:-}" ]; then
    printf '%s\n' "$GH_AS_REVIEWER_IDENTITY"
  elif [ -n "${MERGEPATH_AGENT:-}" ]; then
    printf 'nathanpayne-%s\n' "$MERGEPATH_AGENT"
  elif [ -n "${OP_PREFLIGHT_AGENT:-}" ]; then
    printf 'nathanpayne-%s\n' "$OP_PREFLIGHT_AGENT"
  else
    printf '%s\n' "nathanpayne-claude"
  fi
}

gh_resolve_token_for_identity() {
  local expected_login="${1:-}"
  local preferred_var="${2:-}"
  local label="${3:-gh-token-resolver}"

  if [ -z "$expected_login" ]; then
    echo "$label: expected login is required" >&2
    return 1
  fi

  local root checker token source
  root="$(gh_resolver_repo_root)"
  checker="$root/scripts/identity-check.sh"
  if [ ! -x "$checker" ]; then
    echo "$label: identity-check helper missing or non-executable: $checker" >&2
    echo "$label: refusing to select a GitHub write token without verification." >&2
    return 2
  fi

  # Resolution order (every candidate is verified via identity-check.sh
  # --expect-write-identity before it can win — no candidate is ever blindly
  # trusted, and no token material is printed):
  #
  #   1. The preferred OP_PREFLIGHT_*_PAT env var (if set). A WRONG identity
  #      here is a hard error — the caller asked for this specific cached PAT,
  #      so a mismatch is a misconfiguration to surface, not something to
  #      paper over by silently using a different token.
  #   2. An ambient GH_TOKEN (#533). On a token-only runner
  #      (`GH_TOKEN=... scripts/gh-as-reviewer.sh ...`) with no keyring and no
  #      OP_PREFLIGHT cache, this is the only token material available. It is
  #      tried only when (1) supplied no token. A WRONG-identity ambient token
  #      is REJECTED and falls through to the keyring — never blindly trusted.
  #      So is one whose write identity cannot be established: the Claude
  #      cloud placeholder `proxy-injected` reads as the human through
  #      `GET /user` and writes as `claude[bot]`, and before #1057 it won
  #      here silently.
  #   3. The `gh auth token --user <login>` keyring fallback. A WRONG identity
  #      here is a hard error (the keyring returned a token for the wrong
  #      account).

  token=""
  source=""

  # --- Candidate 1: preferred OP_PREFLIGHT_*_PAT (hard-fail on mismatch) ---
  if [ -n "$preferred_var" ]; then
    # Indirect expansion is supported by the repo's Bash 3.2 baseline.
    token="${!preferred_var:-}"
    if [ -n "$token" ]; then
      source="\$$preferred_var"
      if ! GH_TOKEN="$token" "$checker" --expect-write-identity "$expected_login"; then
        echo "$label: selected token source ($source) did not verify as $expected_login." >&2
        return 2
      fi
      GH_RESOLVED_TOKEN="$token"
      return 0
    fi
  fi

  # --- Candidate 2: ambient GH_TOKEN (verify; fall through on mismatch) ---
  # Tried only when the preferred var supplied nothing. A mismatch does NOT
  # hard-fail here — it falls through to the keyring — because an ambient
  # GH_TOKEN may belong to a different identity than the one this write needs
  # (e.g. a CI-default token), and the keyring may still hold the right one.
  if [ -n "${GH_TOKEN:-}" ]; then
    if GH_TOKEN="$GH_TOKEN" "$checker" --expect-write-identity "$expected_login" 2>/dev/null; then
      GH_RESOLVED_TOKEN="$GH_TOKEN"
      return 0
    fi
    echo "$label: ambient GH_TOKEN did not verify as a user-held credential for $expected_login; trying gh auth token --user." >&2
  fi

  # --- Candidate 3: gh auth token --user keyring fallback (hard-fail) ------
  if ! command -v gh >/dev/null 2>&1; then
    echo "$label: gh CLI not on PATH; cannot fall back to gh auth token." >&2
    return 3
  fi
  if ! token="$(env -u GH_TOKEN -u GITHUB_TOKEN gh auth token --user "$expected_login" 2>/dev/null)"; then
    echo "$label: could not read a token for $expected_login via gh auth token --user." >&2
    echo "$label: run gh auth login once for that identity, or warm op-preflight." >&2
    return 3
  fi
  source="gh auth token --user $expected_login"

  if [ -z "$token" ]; then
    echo "$label: selected token for $expected_login is empty." >&2
    return 3
  fi

  if ! GH_TOKEN="$token" "$checker" --expect-write-identity "$expected_login"; then
    echo "$label: selected token source ($source) did not verify as $expected_login." >&2
    return 2
  fi

  GH_RESOLVED_TOKEN="$token"
  return 0
}
