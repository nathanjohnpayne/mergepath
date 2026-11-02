#!/usr/bin/env bash
# Review-input fingerprints for the event-driven required checks (#2920).
# Sourced by trusted gate workflows and the required-check publisher. Does
# not load credentials or select accounts.
#
# A review event used to re-run every review-dependent context on the PR
# head even when nothing that context reads had changed: each approval
# opened holds, re-evaluated and re-published, and the PR sat BLOCKED while
# it did. A producer that evaluates a context now records, beside a green
# verdict, a fingerprint of exactly the inputs that verdict was computed
# from. A later review event whose live fingerprint matches the newest
# published run of the same context on the same head may leave that run
# standing instead of re-evaluating it.
#
# Fail toward re-evaluating. Every function here returns non-zero on any
# failed read, malformed answer, unsupported context or mismatch, and the
# callers then run the full gate exactly as before. Only these may skip:
#   * a live fingerprint computed from complete reads (no truncated page);
#   * the NEWEST Checks-API run of the context on the head (by id: holds,
#     publisher generations and event-job runs all count, so any newer
#     hold or verdict defeats the skip) is completed with conclusion
#     success;
#   * its output.text is exactly the marker for that fingerprint. Only
#     trusted workflow code writes output.text on these contexts; gate
#     output, which carries attacker-influenceable text, goes to
#     output.summary and never reaches it;
#   * it completed less than GIF_MAX_AGE_SECONDS ago, so a skip never stands
#     in for an evaluation older than the sweep interval.
# Producers write the marker only when the fingerprint read before the
# evaluation equals the one read after it, so a state change during the
# evaluation never lets a verdict for one state stand under another's
# fingerprint. Only a success is ever recorded or reused: a red verdict
# always re-evaluates, so a skip cannot hold a PR blocked either.

GIF_MARKER_PREFIX='mergepath-input-fingerprint:v1'
GIF_MAX_AGE_SECONDS="${GIF_MAX_AGE_SECONDS:-1800}"
# GIF_HEX and GIF_REASON are this library's results, read by its callers.
# shellcheck disable=SC2034
GIF_REASON=""
# shellcheck disable=SC2034
GIF_HEX=""

# Contexts with a projection below. Anything else never skips.
gif_supported() { # context
  case "$1" in
    'Merge clearance gate') return 0 ;;
    *) return 1 ;;
  esac
}

gif_marker() { # context hex
  [[ "$2" =~ ^[0-9a-f]{64}$ ]] || return 1
  gif_supported "$1" || return 1
  printf '<!-- %s %s -->' "$GIF_MARKER_PREFIX" "$2"
}

gif_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | cut -d' ' -f1
  else
    shasum -a 256 | cut -d' ' -f1
  fi
}

# Request accounting (Phase 4b on #2924). Every API request this library
# makes goes through gif_request, which counts it in GIF_REQUESTS_FILE (a
# file, so the count survives the command substitutions callers use) and
# refuses once GIF_REQUEST_LIMIT requests have been made. A caller sets the
# limit from the live installation budget with gif_budget, so the optional
# comparison stops, page by page, before it reaches the reserve the budget
# guards keep back, and the caller then evaluates in full. An unset limit
# (an unknown budget) counts without refusing, the guards' own direction.
gif_budget() { # <limit or empty>: start counting afresh under this limit
  if [ -z "${GIF_REQUESTS_FILE:-}" ] || [ ! -w "$GIF_REQUESTS_FILE" ]; then
    GIF_REQUESTS_FILE=$(mktemp "${TMPDIR:-/tmp}/gif-requests.XXXXXX") || return 1
    export GIF_REQUESTS_FILE
  fi
  : >"$GIF_REQUESTS_FILE"
  GIF_REQUEST_LIMIT="${1:-}"
  export GIF_REQUEST_LIMIT
}
gif_requests_used() {
  if [ -n "${GIF_REQUESTS_FILE:-}" ] && [ -r "$GIF_REQUESTS_FILE" ]; then
    wc -l <"$GIF_REQUESTS_FILE" | tr -d ' '
  else
    echo 0
  fi
}
gif_request() { # gh api arguments: one counted request, refused over the limit
  local used
  [ -n "${GIF_REQUESTS_FILE:-}" ] || gif_budget "${GIF_REQUEST_LIMIT:-}" || return 1
  used=$(gif_requests_used)
  if [ -n "${GIF_REQUEST_LIMIT:-}" ]; then
    [[ "$GIF_REQUEST_LIMIT" =~ ^[0-9]+$ ]] || return 1
    [ "$used" -lt "$GIF_REQUEST_LIMIT" ] || return 1
  fi
  echo . >>"$GIF_REQUESTS_FILE"
  gh api "$@"
}

# gif_list <endpoint>: every element of a paginated REST list, as one JSON
# array, fetched one counted page at a time (so the request limit can stop
# it between pages). Fails when any page is not an array of objects, and
# past 50 pages.
gif_list() {
  local page=1 reply all='[]' n
  while [ "$page" -le 50 ]; do
    reply=$(gif_request -X GET "$1" -f per_page=100 -f page="$page") || return 1
    n=$(printf '%s\n' "$reply" | jq -e 'if type == "array" and all(.[]; type == "object") then length else error("not a list page") end' 2>/dev/null) || return 1
    all=$(printf '%s\n%s\n' "$all" "$reply" | jq -cs '.[0] + .[1]') || return 1
    [ "$n" -ge 100 ] || { printf '%s\n' "$all"; return 0; }
    page=$((page + 1))
  done
  return 1
}

# gif_threads <repo> <pr>: every review thread's resolution state. A PR
# with more than one page of threads has no fingerprint (no skip).
gif_threads() {
  local repo="$1" pr="$2" reply
  # shellcheck disable=SC2016  # GraphQL variables, bound by the -F/-f flags
  reply=$(gif_request graphql -F owner="${repo%%/*}" -F name="${repo#*/}" -F number="$pr" \
    -f query='query($owner:String!,$name:String!,$number:Int!){repository(owner:$owner,name:$name){pullRequest(number:$number){reviewThreads(first:100){pageInfo{hasNextPage} nodes{id isResolved isOutdated}}}}}') || return 1
  printf '%s\n' "$reply" | jq -ce '
    if (.errors // null) != null then error("graphql errors") else . end
    | .data.repository.pullRequest.reviewThreads
    | if .pageInfo.hasNextPage != false then error("more than one page of threads")
      elif (.nodes | type) != "array" then error("no thread list")
      else [.nodes[] | {id, isResolved, isOutdated}] end'
}

# The merge clearance projection: everything scripts/merge-clearance-gate.sh
# and the codex-review-check.sh it delegates to read that a review-side
# event can change. Repository configuration (branch protection, rulesets,
# the trusted policy) is covered by the trusted revision or, for the rule
# surfaces, by GIF_MAX_AGE_SECONDS and the sweep, like every other
# transition that fires no event.
#
# Reviews are the one surface not hashed raw, because a repeated identical
# approval is a NEW review object: each review is reduced to who left it,
# its state, commit and body. A review identical to its predecessor is
# dropped only when that predecessor is the event immediately before it on
# one timeline of reviews (by submitted_at, the order the gate selects them
# in) and PR-level and inline comments (by creation and by every edit). On a
# timestamp tie a comment sorts before a review, so a same-second comment
# always counts as between them, and a repeat whose timestamp, or whose
# predecessor's, is shared with any other event is kept: the gate breaks
# submitted_at ties by input order, so a tie can move which review governs
# (Phase 4b on #2924). Anything in between keeps the repeat: the
# gate selects governing reviews by submission order across reviewers (the
# newest Phase 4b approver, for one) and checks an approval against the
# requests and Codex outcomes posted before it, so a repeat with another
# review or a comment in between can move the verdict (Codex P1 and Phase 4b
# on #2924). The kept entries carry no timestamps, so an adjacent repeat
# leaves the fingerprint unchanged. A dismissal (state DISMISSED), an edit
# (body), a CHANGES_REQUESTED or an approval of another commit is never
# identical, so each one changes the fingerprint. Reactions are hashed as
# per-object counts without times; no gate check makes a later identical
# approval weaker against a reaction (an approval only has to follow the
# Codex signal). Inline comments, PR-level comments and review threads are
# hashed with their ids, bodies, edit times and reaction counts, so any
# finding, reply, edit, deletion or resolution changes it.
GIF_MCG_PROJECTION=$(cat <<'JQ'
def rx: if type == "object" then del(.url) else null end;
{
  v: 1,
  context: $context,
  repo: $repo,
  trusted_revision: $revision,
  pr: ($pr | {
    number, state, draft, merged, title, body,
    user: .user.login, author_association,
    head: .head.sha, head_ref: .head.ref, head_repo: .head.repo.full_name,
    base: .base.ref, base_sha: .base.sha,
    labels: ([.labels[]?.name] | sort),
    requested_reviewers: ([.requested_reviewers[]?.login] | sort),
    requested_teams: ([.requested_teams[]?.slug] | sort),
    auto_merge: (if has("auto_merge") then (.auto_merge != null) else "unknown" end)
  }),
  pr_reactions: ($issue.reactions | rx),
  reviews: (
    ( [ $reviews[] | {t: (.submitted_at // ""), o: 1, id, r: true,
                      v: {user: .user.login, state, commit: .commit_id, body,
                          association: .author_association}} ]
      + [ ($comments + $inline)[]
          | {t: (.created_at // ""), o: 0, id, r: false},
            (select((.updated_at // "") != (.created_at // ""))
             | {t: (.updated_at // ""), o: 0, id, r: false}) ] )
    | sort_by([.t, .o, .id])
    | (group_by(.t) | map({key: .[0].t, value: length}) | from_entries) as $at
    | reduce .[] as $e ({prev: null, out: []};
        if $e.r and .prev != null and .prev.r and .prev.v == $e.v
           and $at[$e.t] == 1 and $at[.prev.t] == 1 then .prev = $e
        elif $e.r then .out += [$e.v] | .prev = $e
        else .prev = $e end)
    | .out),
  inline: ($inline | sort_by(.id) | map({
    id, user: .user.login, body, created_at, updated_at,
    review: .pull_request_review_id, reply_to: .in_reply_to_id,
    commit: .commit_id, original_commit: .original_commit_id,
    path, line, original_line, side, subject_type,
    reactions: (.reactions | rx)
  })),
  comments: ($comments | sort_by(.id) | map({
    id, user: .user.login, body, created_at, updated_at,
    reactions: (.reactions | rx)
  })),
  threads: ($threads | sort_by(.id))
}
JQ
)

# gif_compute <repo> <pr> <head> <context> [trusted-revision]: print the
# 64-hex fingerprint of the context's inputs on the PR's live state. Fails
# when any read fails, when the PR's live head is not <head>, or when the
# context has no projection. The trusted revision defaults to the current
# checkout's HEAD; it is part of the fingerprint, so a verdict computed by
# other gate code never matches.
gif_compute() {
  local repo="$1" pr="$2" head="$3" context="$4" revision="${5:-}"
  local pr_json issue_json reviews inline comments threads projection doc
  gif_supported "$context" || return 1
  [[ "$pr" =~ ^[1-9][0-9]*$ && "$head" =~ ^[0-9a-f]{40}$ ]] || return 1
  case "$repo" in */*) ;; *) return 1 ;; esac
  if [ -z "$revision" ]; then
    revision=$(git rev-parse HEAD 2>/dev/null) || return 1
  fi
  [[ "$revision" =~ ^[0-9a-f]{40}$ ]] || return 1
  pr_json=$(gif_request "repos/$repo/pulls/$pr") || return 1
  jq -e --arg head "$head" '.head.sha == $head' >/dev/null <<<"$pr_json" 2>/dev/null || return 1
  issue_json=$(gif_request "repos/$repo/issues/$pr") || return 1
  reviews=$(gif_list "repos/$repo/pulls/$pr/reviews") || return 1
  inline=$(gif_list "repos/$repo/pulls/$pr/comments") || return 1
  comments=$(gif_list "repos/$repo/issues/$pr/comments") || return 1
  threads=$(gif_threads "$repo" "$pr") || return 1
  case "$context" in
    'Merge clearance gate') projection="$GIF_MCG_PROJECTION" ;;
    *) return 1 ;;
  esac
  # The six documents travel on stdin, not as --argjson arguments: Linux caps
  # one argument at 128 KiB (MAX_ARG_STRLEN), which a busy PR's comment list
  # passes, and the skip would then never work on exactly the PRs with the
  # most review events (CodeRabbit on #2924). printf is a builtin, so it has
  # no such limit. Exactly six documents must arrive, each the right type.
  doc=$(printf '%s\n' "$pr_json" "$issue_json" "$reviews" "$inline" "$comments" "$threads" \
    | jq -ncS --arg context "$context" --arg repo "$repo" --arg revision "$revision" \
      '[inputs] as $docs
       | if ($docs | length) != 6 or ($docs[0] | type) != "object" or ($docs[1] | type) != "object"
            or any($docs[2:][]; type != "array") then error("malformed inputs") else . end
       | $docs as [$pr, $issue, $reviews, $inline, $comments, $threads]
       | '"$projection" 2>/dev/null) || return 1
  [ -n "$doc" ] || return 1
  printf '%s' "$doc" | gif_sha256
}

# gif_published_matches <repo> <head> <context> <hex>: exit 0 only when the
# newest Checks-API run of <context> on <head> is a completed success that
# carries exactly this fingerprint's marker and is younger than
# GIF_MAX_AGE_SECONDS. GIF_REASON says why not.
gif_published_matches() {
  local repo="$1" head="$2" context="$3" hex="$4" marker runs verdict
  GIF_REASON=""
  marker=$(gif_marker "$context" "$hex") || { GIF_REASON="no well-formed fingerprint"; return 1; }
  [[ "$head" =~ ^[0-9a-f]{40}$ ]] || { GIF_REASON="malformed head"; return 1; }
  [[ "$GIF_MAX_AGE_SECONDS" =~ ^[1-9][0-9]*$ ]] || { GIF_REASON="malformed GIF_MAX_AGE_SECONDS"; return 1; }
  # Job-native runs carry an /actions/runs/ details URL and an Actions
  # external_id; Checks-API runs carry neither (the discriminators due()
  # and scripts/gate-api-lineage-blocking.sh use).
  local page=1 reply n
  runs=""
  while :; do
    if [ "$page" -gt 50 ] || ! reply=$(gif_request -X GET "repos/$repo/commits/$head/check-runs" \
        -f check_name="$context" -f filter=all -f per_page=100 -f page="$page") \
        || ! n=$(printf '%s\n' "$reply" | jq -e '.check_runs | if type == "array" then length else error("no list") end' 2>/dev/null); then
      GIF_REASON="could not read the published runs"
      return 1
    fi
    runs="$runs$(printf '%s\n' "$reply" | jq -c '.check_runs[] | {id, name, status, conclusion, completed_at,
              ext: (.external_id // ""), app: (.app.slug // ""),
              url: (.details_url // ""), text: (.output.text // "")}')"$'\n'
    [ "$n" -ge 100 ] || break
    page=$((page + 1))
  done
  verdict=$(printf '%s\n' "$runs" | jq -rs --arg context "$context" --arg marker "$marker" \
    --argjson age "$GIF_MAX_AGE_SECONDS" '
    [ .[] | select(.name == $context and .app == "github-actions" and .ext == ""
             and (.url | contains("/actions/runs/") | not)) ] as $api
    | if ($api | length) == 0 then "no published run"
      else ($api | max_by(.id)) as $n
      | if $n.status != "completed" then "newest run \($n.id) is \($n.status)"
        elif $n.conclusion != "success" then "newest run \($n.id) concluded \($n.conclusion)"
        elif $n.text != $marker then "newest run \($n.id) carries no matching fingerprint"
        else ((now - ($n.completed_at | fromdateiso8601)) as $a
          | if $a < -60 or $a > $age then "newest run \($n.id) is \($a | floor) s old"
            else "match \($n.id)" end)
        end
      end' 2>/dev/null) || { GIF_REASON="could not parse the published runs"; return 1; }
  case "$verdict" in
    "match "*) GIF_REASON="$verdict"; return 0 ;;
    '') GIF_REASON="could not parse the published runs"; return 1 ;;
    *) GIF_REASON="$verdict"; return 1 ;;
  esac
}

# gif_decide <repo> <pr> <head> <context> [trusted-revision]: compute the
# live fingerprint into GIF_HEX (empty when it could not be computed) and
# exit 0 only when the published run may stand. Call it directly, not in a
# command substitution, so GIF_HEX and GIF_REASON reach the caller.
gif_decide() {
  # shellcheck disable=SC2034  # read by the caller
  GIF_HEX=""
  GIF_REASON=""
  if ! GIF_HEX=$(gif_compute "$@"); then
    GIF_HEX=""
    # shellcheck disable=SC2034  # read by the caller
    GIF_REASON="no live fingerprint"
    return 1
  fi
  gif_published_matches "$1" "$3" "$4" "$GIF_HEX"
}
