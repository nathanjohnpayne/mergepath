#!/usr/bin/env bash
# scripts/lib/credential-class.sh — classify a GitHub credential by what it
# can prove about the identity its WRITES will carry (#1057).
#
# Why this exists:
#
#   `GET /user` answers "who does this token READ as". In a brokered
#   environment that is not the question that matters. A Claude Code cloud
#   session hands out the placeholder `proxy-injected` as GH_TOKEN; the proxy
#   substitutes a real credential on the way out. Measured on #1057: `GET
#   /user` through that placeholder returned `nathanjohnpayne` (type User),
#   while the issue written through it was authored by `claude[bot]`. A login
#   check passes and the byline is still wrong.
#
#   The class of a credential is therefore decided from evidence the broker
#   cannot fake by answering `GET /user` truthfully: the token's own form
#   (GitHub's documented prefixes) and, for an unprefixed legacy token, the
#   `X-OAuth-Scopes` response header that only user-held OAuth/classic tokens
#   carry. Anything else is `unidentifiable`, which callers must treat as
#   "cannot establish", never as a match.
#
# Source this file, then call:
#
#   credential_class <token> [<headers-file>]
#     Prints exactly one class on stdout, never token material:
#       user-held      a personal/OAuth/user-to-server token; writes carry
#                      the login `GET /user` reports
#       app-installed  a GitHub App installation token (writes land as the
#                      app's bot)
#       brokered       the documented proxy placeholder; the real credential
#                      is chosen outside this process
#       empty          no token
#       unidentifiable none of the above can be established
#     <headers-file> is the raw response headers of a `GET /user` made with
#     the same token (e.g. `gh api -i user`). It is consulted only for a token
#     with no recognised prefix.
#
#   credential_is_user_held <token> [<headers-file>]
#     Exit 0 iff credential_class prints `user-held`.
#
# Token prefixes: https://github.blog/2021-04-05-behind-githubs-new-authentication-token-formats/
#   ghp_  classic personal access token        -> user-held
#   github_pat_  fine-grained personal access token -> user-held
#   gho_  OAuth app token (e.g. `gh auth login`) -> user-held
#   ghu_  GitHub App user-to-server token       -> user-held
#   ghs_  GitHub App installation token         -> app-installed
#   ghr_  refresh token (never a request credential) -> unidentifiable
#
# Bash 3.2 portable. Pure: no network, no gh, no output besides the class.

CREDENTIAL_BROKERED_PLACEHOLDER="proxy-injected"

credential_class() {
  local token="${1:-}"
  local headers="${2:-}"

  if [ -z "$token" ]; then
    printf '%s\n' "empty"
    return 0
  fi
  if [ "$token" = "$CREDENTIAL_BROKERED_PLACEHOLDER" ]; then
    printf '%s\n' "brokered"
    return 0
  fi
  case "$token" in
    ghp_?*|github_pat_?*|gho_?*|ghu_?*)
      printf '%s\n' "user-held"
      return 0
      ;;
    ghs_?*)
      printf '%s\n' "app-installed"
      return 0
      ;;
    ghr_?*)
      printf '%s\n' "unidentifiable"
      return 0
      ;;
  esac

  # Unprefixed: a legacy 40-hex classic/OAuth token is the only user-held
  # form without a prefix, and GitHub still returns X-OAuth-Scopes for it.
  # Require BOTH the legacy shape and the header, so an arbitrary opaque
  # string (a broker's own placeholder under another name) cannot qualify by
  # passing through a response that happens to carry the header.
  if printf '%s' "$token" | grep -Eq '^[0-9a-f]{40}$' \
    && [ -n "$headers" ] && [ -r "$headers" ] \
    && grep -Eiq '^x-oauth-scopes:' "$headers"; then
    printf '%s\n' "user-held"
    return 0
  fi

  printf '%s\n' "unidentifiable"
  return 0
}

credential_is_user_held() {
  [ "$(credential_class "${1:-}" "${2:-}")" = "user-held" ]
}
