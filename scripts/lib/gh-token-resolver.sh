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
# A gh identity check does not prove which credential git authenticates with,
# so that path is a closed contract, not a pass-through. The payload is
# exactly
#
#   git -C <dir> push -u origin HEAD
#
# and the repository it names must match a fixed, value-checked allowlist
# (gh_author_git_push). Prints "gh" or "git-push"; refuses anything else.
gh_author_payload_kind() { # <payload...>
  case "${1:-}" in
    gh|*/gh) printf 'gh\n'; return 0 ;;
    git|*/git) ;;
    *)
      gh_require_direct_gh_payload "gh-as-author" "$@"
      return 1
      ;;
  esac
  if [ "$#" -eq 7 ] && [ "$2" = "-C" ] && [ -n "$3" ] && [ "$4" = "push" ] \
     && [ "$5" = "-u" ] && [ "$6" = "origin" ] && [ "$7" = "HEAD" ]; then
    printf 'git-push\n'
    return 0
  fi
  echo "gh-as-author: the only git command accepted is: git -C <dir> push -u origin HEAD (bootstrap's initial push)." >&2
  return 1
}

# Run git so that the ONLY credential it can present to github.com is
# <token>. Global and system config, ~/.netrc and XDG config are out of reach
# (throwaway HOME, GIT_CONFIG_GLOBAL=/dev/null, GIT_CONFIG_NOSYSTEM), config
# and repository redirection injected through the environment are dropped,
# the credential helper list is reset to gh's (which reads GH_TOKEN), extra
# headers are reset, hooks are disabled, and SSH github.com spellings are
# rewritten to HTTPS so the helper, not an SSH key, decides.
gh_author_git_exec() { # <token> <git args...>
  local token="$1" home rc gh_bin
  shift
  # The credential helper names gh by ABSOLUTE path, resolved here, before
  # git enters the repository: a bare `!gh` is looked up after `git -C`
  # changes directory, so a relative PATH entry (".") would run a gh file the
  # repository ships, with the token in its environment (Codex on #1541).
  gh_bin="$(command -v gh 2>/dev/null || true)"
  case "$gh_bin" in
    /*) ;;
    *) echo "gh-as-author: refusing git: gh does not resolve to an absolute path ('${gh_bin:-not found}')." >&2; return 5 ;;
  esac
  case "$gh_bin" in
    *"'"*|*'\'*) echo "gh-as-author: refusing git: the gh path contains a quote or backslash." >&2; return 5 ;;
  esac
  # Every inherited GIT_* variable is dropped, not a list of known ones:
  # GIT_EXEC_PATH can substitute git-remote-https itself, GIT_TRACE_CURL with
  # GIT_TRACE_REDACT=0 logs the Authorization header, and GIT_CONFIG_*,
  # GIT_DIR and friends redirect config or repository (Codex on #1541). The
  # runner then sets only its own.
  local -a drop_git_env=()
  local v
  for v in $(compgen -e); do
    case "$v" in GIT_*) drop_git_env+=(-u "$v") ;; esac
  done
  home="$(mktemp -d "${TMPDIR:-/tmp}/gh-as-author-git-home.XXXXXX")" || return 1
  env -u GITHUB_TOKEN ${drop_git_env[@]+"${drop_git_env[@]}"} \
    HOME="$home" XDG_CONFIG_HOME="$home/.config" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
    GIT_TERMINAL_PROMPT=0 GIT_ASKPASS= SSH_ASKPASS= \
    GH_TOKEN="$token" GH_ENTERPRISE_TOKEN="$GH_WRAPPER_NO_ENTERPRISE_CREDENTIAL" \
    GITHUB_ENTERPRISE_TOKEN="$GH_WRAPPER_NO_ENTERPRISE_CREDENTIAL" \
    git -c credential.helper= -c "credential.helper=!'$gh_bin' auth git-credential" \
        -c http.extraHeader= \
        -c core.hooksPath=/dev/null \
        -c url.https://github.com/.insteadOf=git@github.com: \
        "$@"
  rc=$?
  rm -rf "$home"
  return "$rc"
}

# Push under <token> after proving the repository is a plain, freshly created
# bootstrap repository for <owner/repo> and nothing in it can redirect the
# push or run a program with the token (owner's allowlist on #1541):
#   - a primary, non-bare work tree: <dir>/.git is a directory and is both the
#     git dir and the common dir; no config.worktree;
#   - its .git/config, parsed by git itself with includes off (-z, status
#     checked), holds EXACTLY:
#       core.repositoryformatversion=0, core.bare=false,
#       remote.origin.url = https://github.com/<owner/repo>.git
#                           (or the exact git@github.com: spelling, which the
#                           exec rewrites to that HTTPS URL),
#       remote.origin.fetch = +refs/heads/*:refs/remotes/origin/*;
#     optionally core.{filemode,logallrefupdates,ignorecase,precomposeunicode,
#     symlinks} as true/false, and branch.main.remote=origin +
#     branch.main.merge=refs/heads/main (a retry after push -u);
#     every key at most once; anything else refuses the push.
# <owner/repo> comes from the caller's trusted input, never from the URL.
gh_author_git_push() { # <token> <owner/repo> -C <dir> push -u origin HEAD
  local token="$1" expected="$2" dir="$4"
  shift 2
  case "$expected" in
    ''|*[!A-Za-z0-9._/-]*|*/*/*|/*|*/) expected="" ;;
    */*) ;;
    *) expected="" ;;
  esac
  if [ -z "$expected" ]; then
    echo "gh-as-author: refusing git push: GH_AS_AUTHOR_PUSH_REPO must name the expected owner/repo." >&2
    return 5
  fi
  local top gitdir common
  top="$(cd "$dir" 2>/dev/null && pwd -P)" || { echo "gh-as-author: refusing git push: $dir is not a directory." >&2; return 5; }
  if [ ! -d "$top/.git" ] || [ -L "$top/.git" ]; then
    echo "gh-as-author: refusing git push: $dir/.git is not a plain directory (linked worktree, submodule or gitdir file)." >&2
    return 5
  fi
  gitdir="$(env -u GIT_DIR -u GIT_WORK_TREE -u GIT_COMMON_DIR git -C "$top" rev-parse --absolute-git-dir 2>/dev/null)" || gitdir=""
  common="$(env -u GIT_DIR -u GIT_WORK_TREE -u GIT_COMMON_DIR git -C "$top" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || common=""
  if [ "$gitdir" != "$top/.git" ] || [ "$common" != "$top/.git" ] || [ -e "$top/.git/config.worktree" ]; then
    echo "gh-as-author: refusing git push: $dir is not a primary repository whose git dir is $dir/.git." >&2
    return 5
  fi

  local cfg entry key value seen=" " bad="" rc=0
  local want_https="https://github.com/$expected.git" want_ssh="git@github.com:$expected.git"
  cfg="$(mktemp "${TMPDIR:-/tmp}/gh-as-author-cfg.XXXXXX")" || return 5
  env -u GIT_CONFIG_PARAMETERS -u GIT_CONFIG_COUNT git config --file "$top/.git/config" --no-includes --list -z >"$cfg" 2>/dev/null || rc=$?
  if [ "$rc" -ne 0 ]; then
    rm -f "$cfg"
    echo "gh-as-author: refusing git push: could not parse $dir/.git/config." >&2
    return 5
  fi
  while IFS= read -r -d '' entry; do
    case "$entry" in
      *$'\n'*) key="${entry%%$'\n'*}"; value="${entry#*$'\n'}" ;;
      *) key="$entry"; value=$'\001no-value' ;;
    esac
    case "$seen" in *" $key "*) bad="$bad$key (duplicate)"$'\n'; continue ;; esac
    seen="$seen$key "
    case "$key=$value" in
      "core.repositoryformatversion=0"|"core.bare=false"|"remote.origin.fetch=+refs/heads/*:refs/remotes/origin/*") ;;
      "remote.origin.url=$want_https"|"remote.origin.url=$want_ssh") ;;
      core.filemode=true|core.filemode=false|core.logallrefupdates=true|core.logallrefupdates=false) ;;
      core.ignorecase=true|core.ignorecase=false|core.precomposeunicode=true|core.precomposeunicode=false) ;;
      core.symlinks=true|core.symlinks=false) ;;
      "branch.main.remote=origin"|"branch.main.merge=refs/heads/main") ;;
      *) bad="$bad$key"$'\n' ;;
    esac
  done <"$cfg"
  rm -f "$cfg"
  for key in core.repositoryformatversion core.bare remote.origin.url remote.origin.fetch; do
    case "$seen" in *" $key "*) ;; *) bad="$bad$key (missing)"$'\n' ;; esac
  done
  if [ -n "$bad" ]; then
    # Key names only; values can hold credentials, and so can a URL
    # subsection in a name (http.https://user:secret@host/.extraheader).
    echo "gh-as-author: refusing git push: $dir/.git/config is not a plain bootstrap repository for $expected; unexpected or invalid:" >&2
    printf '%s' "$bad" | sed -E 's#//[^/@]*@#//<redacted>@#g; s/^/  /' >&2
    return 5
  fi
  gh_author_git_exec "$token" "$@"
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
