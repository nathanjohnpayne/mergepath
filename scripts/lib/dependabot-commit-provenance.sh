#!/usr/bin/env bash
# scripts/lib/dependabot-commit-provenance.sh
#
# `dependabot_commit_provenance` — the ONE predicate that decides whether a
# PR opened by `dependabot[bot]` still contains ONLY Dependabot's own commits.
#
# Why this exists
# ---------------
# Two trusted paths special-case a Dependabot PR by its OPENER alone:
#
#   - .github/workflows/dependabot-auto-merge.yml approves under the reviewer
#     token and merges under the author token when
#     `pull_request.user.login == 'dependabot[bot]'`; its
#     `dependabot/fetch-metadata` step classifies the update from the FIRST
#     commit's message only.
#   - scripts/merge-clearance-gate.sh's Dependabot arm needs only a
#     reviewer-identity approval on HEAD and skips the external-review
#     (Phase 4) derivation entirely.
#
# The opener of a PR never changes, but its branch can: anyone with push
# access can add commits to a Dependabot branch, and the PR is still
# "authored by dependabot[bot]". Both paths must therefore judge the PR by the
# commits it would MERGE, not by who opened it. A PR that fails this predicate
# is not a Dependabot PR for governance purposes: the workflow does not
# approve or merge it, and the gate judges it like any other PR.
#
# The predicate
# -------------
# Every commit on the PR (`pulls/{n}/commits`, all pages) must satisfy ALL of:
#
#   1. `author.login == "dependabot[bot]"`
#   2. `committer.login` is `web-flow` or `dependabot[bot]`. Dependabot's
#      commits are created server-side and committed/signed by GitHub
#      (`GitHub <noreply@github.com>`, login `web-flow`) — verified live on
#      mergepath#749, overridebroadway#178 and matchline#499 — so requiring
#      `committer.login == "dependabot[bot]"` would reject every real
#      Dependabot PR. `dependabot[bot]` is accepted as the committer too, so a
#      future GitHub change toward self-committed bot commits does not
#      silently disable the lane.
#   3. `commit.verification.verified == true` (GitHub's signature check).
#
# and the PR's current head SHA (the caller's pinned HEAD) must be one of the
# listed commits, so the verdict is about the exact head the caller will act
# on. The endpoint lists at most 250 commits; a PR at that ceiling cannot be
# fully enumerated and is judged untrusted, never "trusted as far as we can
# see".
#
# Contract
# --------
#   rc 0  every commit passes; the head is among them.
#   rc 1  at least one commit fails, or the list is empty / at the 250 cap.
#         DEPENDABOT_PROVENANCE_REASON names why (one line).
#   rc 3  the verdict could not be reached: the commits read failed, the
#         response was malformed, the head is not among the listed commits
#         (the branch moved under the caller), or gh_api_array is not
#         defined. Same rc-3 "unreadable" status as gh-api-array.sh /
#         gh-api-scalar.sh; each caller maps it to its own failure action.
#         DEPENDABOT_PROVENANCE_REASON carries the diagnostic.
#
# rc 1 and rc 3 are deliberately distinct: rc 1 is a positive verdict ("this
# PR is not Dependabot-only") that a caller can act on safely by withholding
# the Dependabot lane; rc 3 establishes nothing, and a caller must fail closed
# rather than fall through to either lane.
#
# Sourcing contract: function definitions only, no top-level side effects,
# no shell options changed. The caller must source scripts/lib/gh-api-array.sh
# first. Bash 3.2 portable.
#
#   . scripts/lib/gh-api-array.sh
#   . scripts/lib/dependabot-commit-provenance.sh
#   dependabot_commit_provenance <owner/repo> <pr_number> <head_sha>

# shellcheck disable=SC2034  # DEPENDABOT_PROVENANCE_REASON is the caller-facing report channel
dependabot_commit_provenance() {
  DEPENDABOT_PROVENANCE_REASON=""
  local repo=${1:-} pr=${2:-} head=${3:-}
  local commits verdict

  if [ -z "$repo" ] || [ -z "$pr" ] || [ -z "$head" ]; then
    DEPENDABOT_PROVENANCE_REASON="usage: dependabot_commit_provenance <owner/repo> <pr_number> <head_sha>"
    return 3
  fi
  if ! [[ "$head" =~ ^[0-9a-fA-F]{40}$ ]]; then
    DEPENDABOT_PROVENANCE_REASON="head sha '$head' is not a full 40-hex commit id"
    return 3
  fi
  if ! command -v gh_api_array >/dev/null 2>&1; then
    DEPENDABOT_PROVENANCE_REASON="gh_api_array is not defined; source scripts/lib/gh-api-array.sh first"
    return 3
  fi

  if ! commits=$(gh_api_array "repos/$repo/pulls/$pr/commits?per_page=100" "PR commits"); then
    DEPENDABOT_PROVENANCE_REASON="${GH_API_ARRAY_ERROR:-failed to read PR commits}"
    return 3
  fi

  # One jq pass produces `<status>\t<reason>`. Every per-commit field is read
  # defensively (`// ""`, `== true`) so a missing key is a FAILED check, never
  # a pass. Element shape is validated first: a list whose items are not
  # commit objects is a malformed read (status 3), not an untrusted PR.
  verdict=$(printf '%s' "$commits" | jq -r --arg head "$head" '
    def short: (.sha // "?" | tostring | .[0:12]);
    length as $n
    | if any(.[]; type != "object") then "3\tPR commits list contains non-object entries"
    elif length == 0 then "1\tPR lists no commits"
    elif length >= 250 then "1\tPR lists \(length) commits; the pulls commits endpoint stops at 250, so every commit cannot be verified"
    elif (any(.[]; (.sha // "" | ascii_downcase) == ($head | ascii_downcase)) | not)
      then "3\tPR head \($head) is not among the listed commits (the branch moved during the read)"
    else
      [ .[]
        | . as $c
        | [ (if (($c.author.login // "") == "dependabot[bot]") then empty
             else "author=\($c.author.login // "<unmapped>")" end),
            (if ((($c.committer.login // "") == "web-flow") or (($c.committer.login // "") == "dependabot[bot]")) then empty
             else "committer=\($c.committer.login // "<unmapped>")" end),
            (if ($c.commit.verification.verified == true) then empty
             else "signature=\($c.commit.verification.reason // "unverified")" end) ]
        | select(length > 0)
        | "\($c | short) (\(join(", ")))" ]
      | if length == 0 then "0\tall \($n) commit(s) authored by dependabot[bot], committed by GitHub, signature verified"
        else "1\tcommit(s) not produced by Dependabot: \(join("; "))" end
    end
  ' 2>/dev/null) || {
    DEPENDABOT_PROVENANCE_REASON="could not evaluate the PR commits list"
    return 3
  }

  DEPENDABOT_PROVENANCE_REASON=${verdict#*$'\t'}
  case "${verdict%%$'\t'*}" in
    0) return 0 ;;
    1) return 1 ;;
    *) return 3 ;;
  esac
}
