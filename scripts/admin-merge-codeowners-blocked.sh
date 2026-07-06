#!/usr/bin/env bash
# scripts/admin-merge-codeowners-blocked.sh
#
# Batch-merge helper for the specific situation where:
#   - All required CI checks pass
#   - Codex 👍 cleared on the current HEAD
#   - An APPROVED review is present (possibly from a same-agent
#     reviewer identity)
#   - Branch protection's CODEOWNERS rule (`* @nathanjohnpayne` in
#     .github/CODEOWNERS) still blocks merge because the only
#     declared CODEOWNER is also the PR author, and GitHub's
#     no-self-approval rule prevents nathanjohnpayne from approving
#     their own PR.
#
# This is a HUMAN-AUTHORIZED escape hatch. The CODEOWNERS-author
# deadlock can't be cleared by automation; the human is the
# tiebreaker. Per REVIEW_POLICY.md § Phase 4 § "Never use --admin
# unless the human explicitly authorizes it in chat as a break-
# glass exception" — this script's invocation IS that
# authorization. The PreToolUse hook on `gh pr merge --admin`
# treats running this wrapper as the auth signal.
#
# Usage:
#   scripts/admin-merge-codeowners-blocked.sh <pr-ref> [<pr-ref> ...]
#
#   <pr-ref> takes one of two forms:
#     <num>                  PR in nathanjohnpayne/mergepath (this repo)
#     <owner>/<repo>#<num>   cross-repo PR
#
# Per PR, the script:
#   1. Resolves owner/repo + PR number
#   2. Asserts the PR is OPEN and MERGEABLE
#   3. Confirms the block is the CODEOWNERS deadlock and nothing else:
#      mergeStateStatus must be BLOCKED or CLEAN (not UNSTABLE/BEHIND/
#      DIRTY/DRAFT/UNKNOWN), every status check must be green, AND a
#      QUALIFYING approving review must exist: latest-per-author state
#      APPROVED, from a collaborator with write/admin permission who is
#      NOT the PR author, with no outstanding CHANGES_REQUESTED. The
#      approval requirement is what distinguishes the CODEOWNERS self-
#      author deadlock (a real, independent approval exists, it just
#      can't satisfy the CODEOWNERS rule) from a genuinely unreviewed PR
#      or a self-approval — without it, --admin would merge unreviewed
#      code. This keeps the escape hatch scoped to the review/conversation
#      deadlock it exists for; it will NOT force-merge failing/pending CI
#      or inadequately-reviewed code. (Note: in the real deadlock
#      reviewDecision is REVIEW_REQUIRED, so this evaluates the reviews
#      directly rather than trusting reviewDecision.)
#   4. Resolves bot-authored review threads on the current HEAD via
#      scripts/resolve-pr-threads.sh (HEAD-freshness guarded; human
#      threads are never touched). FAILS CLOSED: if resolution errors,
#      or if ANY review thread remains unresolved afterward, it refuses
#      the merge — because --admin would otherwise bypass
#      required_conversation_resolution and merge past an unaddressed
#      (e.g. human-authored) thread.
#   5. Runs `scripts/gh-as-author.sh -- gh pr merge <n> --repo
#      <owner/repo> --squash --delete-branch [--admin] --match-head-commit
#      <validated-sha>`. --admin is added ONLY when mergeStateStatus is
#      BLOCKED (the deadlock); a CLEAN PR is merged WITHOUT --admin so
#      merge-queue / branch-protection paths still apply (--admin would be
#      gratuitous and bypass them). The --match-head-commit pin guarantees
#      the commit that passed steps 2-4 is the one merged (closes the
#      gate-then-merge race if a new commit lands in between).
#   6. Verifies the merge landed by re-reading the PR's state
#
# Exit codes:
#   0  every PR merged successfully
#   1  at least one PR failed to merge or was refused (others may have
#      succeeded)
#   2  usage / argument error
#   3  preflight error (op-preflight cache missing, gh not on PATH, etc.)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

usage() {
  cat >&2 <<EOF
usage: scripts/admin-merge-codeowners-blocked.sh <pr-ref> [<pr-ref> ...]

  <pr-ref>   <num> for this repo, or <owner>/<repo>#<num> cross-repo

Each PR is merged via \`gh pr merge --squash --delete-branch --admin\`
under the AUTHOR identity (nathanjohnpayne). Running this script is
the explicit human authorization for the --admin escape hatch per
REVIEW_POLICY.md § Phase 4.
EOF
  exit 2
}

[[ $# -ge 1 ]] || usage

command -v gh >/dev/null 2>&1 || {
  echo "admin-merge: gh not on PATH" >&2
  exit 3
}

# Auto-source preflight cache so write-path auth works without
# inline op-read biometric prompts.
PREFLIGHT="$SCRIPT_DIR/op-preflight.sh"
if [ -x "$PREFLIGHT" ]; then
  # shellcheck disable=SC1090
  eval "$("$PREFLIGHT" --agent claude --check 2>/dev/null)" || true
fi

# Read-path gh wrapper. Prefer the preflight reviewer PAT when present,
# otherwise fall back to the ambient GH_TOKEN / keyring. Never export an
# empty GH_TOKEN — an empty value still takes precedence over stored
# credentials and breaks auth when the preflight cache is absent.
gh_ro() {
  if [ -n "${OP_PREFLIGHT_REVIEWER_PAT:-}" ]; then
    GH_TOKEN="$OP_PREFLIGHT_REVIEWER_PAT" gh "$@"
  else
    gh "$@"
  fi
}

# Resolve current-repo for bare <num> refs.
CURRENT_REPO=""
resolve_current_repo() {
  if [ -n "$CURRENT_REPO" ]; then return 0; fi
  # Resolve from $REPO_ROOT, not the caller's CWD, so a bare <num> ref
  # always targets this repo even when the script is invoked elsewhere.
  if ! CURRENT_REPO=$( (cd "$REPO_ROOT" && gh_ro repo view --json owner,name --jq '.owner.login + "/" + .name') 2>/dev/null); then
    echo "admin-merge: bare <num> ref passed but current dir is not a gh-resolvable repo" >&2
    exit 3
  fi
}

parse_ref() {
  local ref="$1"
  if [[ "$ref" =~ ^([^/]+)/([^#]+)#([0-9]+)$ ]]; then
    printf '%s/%s\t%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}"
  elif [[ "$ref" =~ ^[0-9]+$ ]]; then
    resolve_current_repo
    printf '%s\t%s\n' "$CURRENT_REPO" "$ref"
  else
    echo "admin-merge: invalid pr-ref: $ref" >&2
    exit 2
  fi
}

GH_AS_AUTHOR="$SCRIPT_DIR/gh-as-author.sh"
if [ ! -x "$GH_AS_AUTHOR" ]; then
  echo "admin-merge: missing $GH_AS_AUTHOR" >&2
  exit 3
fi

# Canonical thread-resolution helper (HEAD-freshness guarded, bot-only).
RESOLVE_THREADS="$SCRIPT_DIR/resolve-pr-threads.sh"

OVERALL_RC=0

for ref in "$@"; do
  parsed=$(parse_ref "$ref")
  repo=$(printf '%s\n' "$parsed" | cut -f1)
  num=$(printf '%s\n' "$parsed" | cut -f2)

  printf '\n========================================\n'
  printf 'PR: %s#%s\n' "$repo" "$num"
  printf '========================================\n'

  state=$(gh_ro pr view "$num" --repo "$repo" \
    --json state,mergeable,mergeStateStatus,headRefOid,title \
    --jq '.state + "|" + (.mergeable // "") + "|" + (.mergeStateStatus // "") + "|" + (.headRefOid // "") + "|" + .title' 2>&1) || {
    printf '  ✗ could not read PR state: %s\n' "$state"
    OVERALL_RC=1
    continue
  }
  pr_state=$(printf '%s\n' "$state" | cut -d'|' -f1)
  pr_mergeable=$(printf '%s\n' "$state" | cut -d'|' -f2)
  pr_msstatus=$(printf '%s\n' "$state" | cut -d'|' -f3)
  pr_head=$(printf '%s\n' "$state" | cut -d'|' -f4)
  pr_title=$(printf '%s\n' "$state" | cut -d'|' -f5-)
  printf '  title:           %s\n' "$pr_title"
  printf '  state:           %s\n' "$pr_state"
  printf '  mergeable:       %s\n' "$pr_mergeable"
  printf '  mergeStateStatus: %s\n' "$pr_msstatus"

  if [ "$pr_state" != "OPEN" ]; then
    printf '  · already %s; skipping\n' "$pr_state"
    continue
  fi
  if [ "$pr_mergeable" != "MERGEABLE" ]; then
    printf '  ✗ not MERGEABLE (got %s) — refusing --admin merge\n' "$pr_mergeable"
    OVERALL_RC=1
    continue
  fi

  # Gate 1 — scope to the CODEOWNERS deadlock. `mergeable` only reports
  # merge-conflict status; it does NOT mean checks/reviews are satisfied.
  # The only states this helper operates on are BLOCKED (the expected
  # deadlock: required approving review missing because the sole CODEOWNER
  # is the author → merged with --admin at the merge step) and CLEAN
  # (already mergeable → merged WITHOUT --admin so merge-queue/branch
  # protections still apply; see the merge step). Anything else (UNSTABLE,
  # BEHIND, DIRTY, DRAFT, UNKNOWN) means a different blocker is in play —
  # refuse rather than force past it.
  case "$pr_msstatus" in
    BLOCKED|CLEAN) : ;;
    *)
      printf '  ✗ mergeStateStatus=%s is not a CODEOWNERS-deadlock state — refusing --admin merge\n' "$pr_msstatus"
      OVERALL_RC=1
      continue
      ;;
  esac

  # Gate 2 — BLOCKED also covers failing/pending REQUIRED checks, which
  # mergeStateStatus alone can't distinguish from a review-only block.
  # This helper's precondition is "all CI checks pass", so refuse if any
  # status check is failing or still running.
  #
  # Page the statusCheckRollup with a Relay cursor loop instead of
  # `gh pr view --json statusCheckRollup`. The --json shape requests only
  # the first 100 contexts and strips pageInfo, so on a long-lived PR whose
  # head commit has accumulated more than 100 check-runs — repeated
  # scheduled-sweep re-evaluations routinely push this well past 100 (194
  # observed on #687) — a failing check beyond the first page is silently
  # invisible, and this green-checks gate would wave an --admin merge
  # straight past it. Same silent-truncation gap and same cursor-loop fix as
  # codex-review-check.sh's rollup fetch (#655 round 13) and #691. Full
  # pagination (not the fail-closed >100 refusal the reviews gate below
  # uses) because >100 contexts is the NORMAL state for the long-lived
  # CODEOWNERS-deadlocked PRs this helper targets — failing closed on it
  # would make the tool unusable on exactly its intended inputs. Any page
  # fetch/parse error, or a hasNextPage with no advancing cursor, fails
  # closed (refuse the merge) rather than risk an undercount that masks a
  # red check.
  r_owner="${repo%%/*}"; r_name="${repo##*/}"
  rollup_query='query($owner: String!, $name: String!, $number: Int!, $cursor: String) {
    repository(owner: $owner, name: $name) {
      pullRequest(number: $number) {
        commits(last: 1) { nodes { commit { statusCheckRollup {
          contexts(first: 100, after: $cursor) {
            pageInfo { hasNextPage endCursor }
            nodes {
              __typename
              ... on CheckRun { name status conclusion }
              ... on StatusContext { context state }
            }
          }
        } } } }
      }
    }
  }'
  rollup_base='.data.repository.pullRequest.commits.nodes[0].commit.statusCheckRollup.contexts'
  rollup_contexts="[]"; rollup_cursor=""; rollup_ok=1
  while :; do
    if [ -n "$rollup_cursor" ]; then
      rollup_page=$(gh_ro api graphql -f owner="$r_owner" -f name="$r_name" \
        -F number="$num" -f cursor="$rollup_cursor" -f query="$rollup_query" 2>/dev/null) \
        || { rollup_ok=0; break; }
    else
      rollup_page=$(gh_ro api graphql -f owner="$r_owner" -f name="$r_name" \
        -F number="$num" -F cursor=null -f query="$rollup_query" 2>/dev/null) \
        || { rollup_ok=0; break; }
    fi
    page_nodes=$(printf '%s' "$rollup_page" | jq -c "(${rollup_base}.nodes // [])" 2>/dev/null) \
      || { rollup_ok=0; break; }
    rollup_contexts=$(jq -c -n --argjson a "$rollup_contexts" --argjson b "$page_nodes" '$a + $b' 2>/dev/null) \
      || { rollup_ok=0; break; }
    has_next=$(printf '%s' "$rollup_page" | jq -r "(${rollup_base}.pageInfo.hasNextPage // false)" 2>/dev/null) || has_next=false
    next_cursor=$(printf '%s' "$rollup_page" | jq -r "(${rollup_base}.pageInfo.endCursor // \"\")" 2>/dev/null) || next_cursor=""
    [ "$has_next" = "true" ] || break
    # hasNextPage=true with no advancing cursor can't prove the walk
    # terminates or that later pages were read — fail closed rather than
    # loop forever or silently undercount.
    if [ -z "$next_cursor" ] || [ "$next_cursor" = "$rollup_cursor" ]; then
      rollup_ok=0; break
    fi
    rollup_cursor="$next_cursor"
  done
  if [ "$rollup_ok" -ne 1 ]; then
    printf '  ✗ could not read check status (statusCheckRollup pagination failed) — refusing --admin merge\n'
    OVERALL_RC=1
    continue
  fi
  not_green=$(printf '%s' "$rollup_contexts" | jq -r '
    [ .[]?
      | select(
          (.__typename == "CheckRun" and (
             (.status != "COMPLETED")
             or ((.conclusion // "" | ascii_downcase) as $c
                 | (($c == "success") or ($c == "skipped") or ($c == "neutral")) | not)
          ))
          or
          (.__typename == "StatusContext" and ((.state // "" | ascii_downcase) != "success"))
        )
      | (.name // .context // "check") ]
    | join(", ")' 2>&1) || not_green="__error__"
  if [ "$not_green" = "__error__" ]; then
    printf '  ✗ could not read check status — refusing --admin merge\n'
    OVERALL_RC=1
    continue
  fi
  if [ -n "$not_green" ]; then
    printf '  ✗ checks not green (%s) — refusing --admin merge\n' "$not_green"
    OVERALL_RC=1
    continue
  fi

  # Gate 3 — require a QUALIFYING approving review ON THE VALIDATED HEAD.
  # mergeStateStatus=BLOCKED also matches a genuinely-unreviewed PR, and
  # --admin bypasses branch protection, so a bare "APPROVED" state is not
  # enough: a self-review, an approval from a non-collaborator (in repos
  # that allow public reviews), or a STALE approval on an older commit
  # would otherwise let unreviewed code merge. Require, from the
  # latest-per-author reviews: no outstanding CHANGES_REQUESTED, and at
  # least one APPROVED review from a collaborator with write/admin
  # permission who is NOT the PR author AND whose approval is on the
  # validated HEAD (pr_head). On repos that do not dismiss stale reviews
  # on push, an old APPROVED can remain the author's latest while newer
  # commits go unreviewed; pinning to pr_head closes that bypass.
  # `gh pr view --json reviews` omits the per-review commit, so query
  # GraphQL for `commit.oid`. reviewDecision is REVIEW_REQUIRED in the
  # real deadlock (the approval isn't from a CODEOWNER), so we evaluate
  # the reviews directly. (PR #340: codex P1 ×2)
  reviews_json=$(gh_ro api graphql \
    -f query='query($owner:String!,$name:String!,$num:Int!){
      repository(owner:$owner,name:$name){
        pullRequest(number:$num){
          author{login}
          reviews(first:100){
            pageInfo{ hasNextPage }
            nodes { author{login} state submittedAt commit{oid} }
          }
        }
      }
    }' -f owner="${repo%%/*}" -f name="${repo##*/}" -F num="$num" 2>&1) \
    || reviews_json="__error__"
  if [ "$reviews_json" = "__error__" ]; then
    printf '  ✗ could not read review state — refusing --admin merge\n'
    OVERALL_RC=1
    continue
  fi
  # Pinning the qualifying approval to pr_head needs the per-review commit,
  # so pipe to jq with --arg (gh's --jq does not expose jq variables).
  # Refuse on >100 reviews (page cap) rather than risk an undercount that
  # masks a CHANGES_REQUESTED or counts a stale approval. (mirrors Gate 4)
  pr_meta=$(printf '%s' "$reviews_json" | jq -r --arg head "$pr_head" '
    .data.repository.pullRequest as $pr
    | if $pr.reviews.pageInfo.hasNextPage then "PAGINATE"
      else
        [ $pr.reviews.nodes | group_by(.author.login)[] | max_by(.submittedAt) ] as $latest
        | ($pr.author.login)
          + "\t" + ([ $latest[] | select(.state=="CHANGES_REQUESTED") ] | length | tostring)
          + "\t" + ([ $latest[] | select(.state=="APPROVED" and .commit.oid==$head) | .author.login ] | unique | join(","))
      end' 2>&1) \
    || pr_meta="__error__"
  if [ "$pr_meta" = "__error__" ] || [ "$pr_meta" = "PAGINATE" ]; then
    printf '  ✗ could not confirm review state (%s) — refusing --admin merge\n' "$pr_meta"
    OVERALL_RC=1
    continue
  fi
  pr_author=$(printf '%s\n' "$pr_meta" | cut -f1)
  changes_count=$(printf '%s\n' "$pr_meta" | cut -f2)
  approvers_csv=$(printf '%s\n' "$pr_meta" | cut -f3)
  if [ "${changes_count:-0}" -gt 0 ] 2>/dev/null; then
    printf '  ✗ a reviewer has CHANGES_REQUESTED outstanding — refusing --admin merge\n'
    OVERALL_RC=1
    continue
  fi
  qualified_approver=""
  if [ -n "$approvers_csv" ]; then
    IFS=',' read -ra _approvers <<< "$approvers_csv" || true
    for appr in "${_approvers[@]}"; do
      [ -z "$appr" ] && continue
      [ "$appr" = "$pr_author" ] && continue   # never count a self-approval
      perm=$(gh_ro api "repos/$repo/collaborators/$appr/permission" --jq '.permission' 2>/dev/null || echo "")
      case "$perm" in
        admin|write|maintain) qualified_approver="$appr"; break ;;
      esac
    done
  fi
  if [ -z "$qualified_approver" ]; then
    printf '  ✗ no qualifying approval on HEAD %s — refusing --admin merge (need an APPROVED review on the validated HEAD from a write/admin collaborator other than the author)\n' "${pr_head:0:7}"
    OVERALL_RC=1
    continue
  fi
  printf '  · qualifying approval from %s\n' "$qualified_approver"

  # Resolve bot-authored review threads on the current HEAD via the
  # canonical helper (current-HEAD freshness guarded; bot threads only).
  # FAIL CLOSED on any failure: --admin bypasses
  # required_conversation_resolution, so we must not fall through to the
  # merge if resolution didn't complete cleanly.
  if [ ! -x "$RESOLVE_THREADS" ]; then
    printf '  ✗ %s missing — refusing --admin merge (cannot verify thread resolution)\n' "$RESOLVE_THREADS"
    OVERALL_RC=1
    continue
  fi
  rt_rc=0
  "$RESOLVE_THREADS" "$num" --repo "$repo" --auto-resolve-bots || rt_rc=$?
  if [ "$rt_rc" -ne 0 ]; then
    printf '  ✗ thread resolution exited %d — refusing --admin merge (fail closed)\n' "$rt_rc"
    OVERALL_RC=1
    continue
  fi

  # Gate 4 — verify NO unresolved threads remain. --admin would merge past
  # the conversation-resolution gate, so any thread the bot-resolver did
  # not (or must not) clear — human-authored threads above all — has to
  # block the merge instead. Refuse on >100 threads (page cap) or read
  # error rather than risk an undercount. (PR #340: codex P1)
  unresolved_remaining=$(gh_ro api graphql -f query="
    query { repository(owner: \"${repo%%/*}\", name: \"${repo##*/}\") {
      pullRequest(number: $num) { reviewThreads(first: 100) {
        pageInfo { hasNextPage }
        nodes { isResolved }
      }}}}" --jq '
        if .data.repository.pullRequest.reviewThreads.pageInfo.hasNextPage
        then "PAGINATE"
        else ([ .data.repository.pullRequest.reviewThreads.nodes[]
                | select(.isResolved != true) ] | length | tostring)
        end' 2>&1) || unresolved_remaining="__error__"
  if [ "$unresolved_remaining" = "__error__" ] || [ "$unresolved_remaining" = "PAGINATE" ]; then
    printf '  ✗ could not confirm all threads resolved (%s) — refusing --admin merge\n' "$unresolved_remaining"
    OVERALL_RC=1
    continue
  fi
  if [ "$unresolved_remaining" -gt 0 ] 2>/dev/null; then
    printf '  ✗ %s unresolved review thread(s) remain — refusing --admin merge (a human must resolve them)\n' "$unresolved_remaining"
    OVERALL_RC=1
    continue
  fi

  # Pin the merge to the exact HEAD the gates above validated. Without
  # --match-head-commit, a push/force-push landing between gate evaluation
  # and the merge could merge an unvalidated commit. (PR #340: codex P1)
  if [ -z "$pr_head" ]; then
    printf '  ✗ could not determine validated HEAD SHA — refusing --admin merge\n'
    OVERALL_RC=1
    continue
  fi
  # Use --admin ONLY for the BLOCKED deadlock. A CLEAN PR is already
  # normally mergeable, so --admin would be gratuitous and would bypass
  # merge-queue / branch-protection paths on repos that have them. Merge
  # CLEAN PRs normally so those protections still apply; reserve the
  # break-glass --admin for the deadlock it exists for. (PR #340: codex P1)
  admin_flag=()
  if [ "$pr_msstatus" = "BLOCKED" ]; then
    admin_flag=(--admin)
    printf '  ⤷ merging with --admin (CODEOWNERS-author deadlock), pinned to %s\n' "${pr_head:0:7}"
  else
    printf '  ⤷ merging without --admin (mergeStateStatus=CLEAN — not a deadlock; merge-queue/branch protections still apply), pinned to %s\n' "${pr_head:0:7}"
  fi
  if "$GH_AS_AUTHOR" -- gh pr merge "$num" --repo "$repo" --squash --delete-branch ${admin_flag[@]+"${admin_flag[@]}"} --match-head-commit "$pr_head"; then
    new_state=$(gh_ro pr view "$num" --repo "$repo" \
      --json state,mergeCommit --jq '.state + " " + (.mergeCommit.oid // "")[0:7]' 2>&1)
    printf '  ✓ merged: %s\n' "$new_state"
  else
    printf '  ✗ merge failed for #%s on %s\n' "$num" "$repo"
    OVERALL_RC=1
  fi
done

echo
if [ "$OVERALL_RC" -eq 0 ]; then
  echo "admin-merge: all PRs merged successfully"
else
  echo "admin-merge: one or more PRs failed; see output above"
fi
exit "$OVERALL_RC"
