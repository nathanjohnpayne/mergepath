#!/usr/bin/env bash
# Owned generations for the three Mergepath Checks-API contexts (#906).
# Sourced by trusted publishers. Does not load credentials or select accounts.

rcg_binding() { # repo pr head context trusted-revision
  jq -nc --arg repo "$1" --argjson pr "$2" --arg head "$3" \
    --arg context "$4" --arg revision "$5" \
    '{repo:$repo,pr:$pr,head:$head,context:$context,trusted_revision:$revision}'
}

rcg_open() { # repo pr full-head context; prints owned check id
  local repo="$1" pr="$2" head="$3" context="$4" revision binding reply
  [[ "$pr" =~ ^[1-9][0-9]*$ && "$head" =~ ^[0-9a-f]{40}$ ]] || return 1
  case "$context" in
    'Merge clearance gate'|'Codex P1 unresolved threads'|'CodeRabbit unresolved blocking findings') ;;
    *) return 1 ;;
  esac
  revision=$(git rev-parse HEAD) || return 1
  [[ "$revision" =~ ^[0-9a-f]{40}$ ]] || return 1
  binding=$(rcg_binding "$repo" "$pr" "$head" "$context" "$revision") || return 1
  # Never retry an ambiguous POST: its response may have been lost after the
  # server opened a generation. An incomplete opening remains non-green.
  reply=$(gh api -X POST "repos/$repo/check-runs" -f name="$context" -f head_sha="$head" -f status=in_progress -f "output[title]=$context (evaluation in progress)" -f "output[summary]=<!-- mergepath-generation:v1 $binding -->") || return 1 # NO_BARE_GH_WRITE_EXEMPT: Actions-only owned Checks API generation under workflow GITHUB_TOKEN (checks:write), never interactive author/reviewer PATs.
  printf '%s\n' "$reply" | jq -er --arg head "$head" --arg context "$context" \
    --arg marker "<!-- mergepath-generation:v1 $binding -->" '
    select(.head_sha == $head and .name == $context and .status == "in_progress"
      and ((.external_id // "") == "") and .output.summary == $marker)
    | .id | select(type == "number" and . > 0 and floor == .)'
}

rcg_close() { # repo pr head context id conclusion title summary
  local repo="$1" pr="$2" head="$3" context="$4" id="$5" conclusion="$6" title="$7" summary="$8"
  local revision binding owned live tip heads failed=0
  [[ "$id" =~ ^[1-9][0-9]*$ && "$head" =~ ^[0-9a-f]{40}$ ]] || return 1
  revision=$(git rev-parse HEAD) || return 1
  binding=$(rcg_binding "$repo" "$pr" "$head" "$context" "$revision") || return 1
  # An id is not authority on its own. Bind the immutable head/name and the
  # opening's exact trusted-code tuple before PATCHing that id, never another.
  owned=$(gh api "repos/$repo/check-runs/$id") || return 1
  if ! jq -e --argjson id "$id" --arg head "$head" --arg context "$context" \
      --arg marker "<!-- mergepath-generation:v1 $binding -->" '
      .id == $id and .head_sha == $head and .name == $context
      and ((.external_id // "") == "")
      and ((.output.summary // "") | startswith($marker))' <<<"$owned" >/dev/null; then
    echo "::error::Owned check generation $id has an invalid binding; leaving it non-green." >&2
    return 1
  fi
  # Cover every verdict input's trusted revision as well as the PR tuple.
  # A stale checkout can publish a failure, never a success for newer policy.
  tip=$(gh api "repos/$repo/commits/HEAD" --jq .sha) || failed=1
  live=$(gh api "repos/$repo/pulls/$pr" --jq .head.sha) || failed=1
  heads=$(gh api --paginate -X GET "repos/$repo/pulls" -f state=open -f per_page=100 \
    --jq ".[] | select(.head.sha == \"$head\") | .number") || failed=1
  if [ "$failed" -ne 0 ] || [ "$tip" != "$revision" ] || [ "$live" != "$head" ] || [ "$heads" != "$pr" ]; then
    failed=1
    conclusion=failure
    title="$context — generation input changed or unreadable"
    summary="Cannot certify PR #$pr at $head: current head, unique PR ownership or trusted default revision changed or could not be read. Re-evaluate from the current trusted revision."
  fi
  # A failed final fence must still close this owned generation red. Its
  # evaluator may have observed the new head; do not attach or validate that
  # other tuple's report while publishing the already-determined failure.
  if [ "$failed" -eq 0 ] && [ -n "${CR_EVIDENCE_REPORT:-}" ] && [ -s "$CR_EVIDENCE_REPORT" ]; then
    local evidence
    evidence=$(jq -ce --arg repo "$repo" --argjson pr "$pr" --arg head "$head" \
      'select(.repo == $repo and .pr == $pr and .head == $head)' "$CR_EVIDENCE_REPORT") || return 1
    if [ "$(jq -r .state <<<"$evidence")" = recovery ] && [ "$conclusion" = success ]; then
      title="$context — RECOVERY (not a clean provider review)"
    fi
    # A readable evaluator result ends an episode only after the final
    # publication binding fence succeeds. Infrastructure failures cannot.
    summary="<!-- mergepath-coderabbit-evidence:v1 $evidence -->
$summary"
  fi
  # Updating an older owned id cannot change its opening order. In particular,
  # a newer pending/failing generation wins even if it opens after these reads.
  summary="<!-- mergepath-generation:v1 $binding -->
${summary:0:59000}"
  gh api -X PATCH "repos/$repo/check-runs/$id" -f status=completed -f conclusion="$conclusion" -f "output[title]=$title" -f "output[summary]=$summary" >/dev/null || return 1 # NO_BARE_GH_WRITE_EXEMPT: Actions-only owned Checks API generation under workflow GITHUB_TOKEN (checks:write), never interactive author/reviewer PATs.
  [ "$failed" -eq 0 ]
}
