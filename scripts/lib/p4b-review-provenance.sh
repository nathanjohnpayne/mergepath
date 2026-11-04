#!/usr/bin/env bash
# scripts/lib/p4b-review-provenance.sh: automated Phase 4b review provenance
# (#2968). Sourced, never executed; Bash 3.2 portable; it sets no shell
# options on the caller.
#
# The Phase 4b round ledger (#2663, specs/phase_4b_round_cap.md) caps the
# automated rounds that reserve through it, but a review carrying the
# automated header can be posted by hand outside it (mergepath#2887). This
# library holds the shared, pure classification both ends use:
#
#   - scripts/phase-4b-review.sh validates and consumes an owner
#     authorization for one round beyond a spent cap (--owner-authorization);
#   - scripts/codex-review-check.sh classifies every review that claims
#     automated provenance before gate (b) or gate (c) may count it.
#
# The owner authorization is one line in a PR comment the owner types:
#
#   P4B_EXTRA_ROUND_AUTHORIZED=<canonical-https-PR-URL>@<full-head-sha> reason: <why>
#
# Its comment id is the single-use binding. The ledger entry of the run it
# authorizes records that id, which is how it is consumed exactly once. A
# comment posted by the owner's account does not prove the owner typed it
# (agents hold the same credential; #928/#2129): the record preserves who
# posted what and when, and nothing here authenticates a person.

# The run id a review carries: the marker the orchestrator writes directly
# before its footer. Byte-identical to scripts/phase-4b/lib.sh
# P4B_RUN_MARKER_JQ (tests/test_phase_4b_round_cap.sh asserts the parity), so
# the ledger counter and the merge gate read one run id.
P4B_PROV_RUN_MARKER_JQ='def p4b_run_marker:
  [(. // "") | capture("<!-- mergepath-p4b-run: (?<r>[A-Za-z0-9._-]+) -->\\s+_Posted by scripts/phase-4b-review\\.sh"; "g") | .r]
  | last;'

# Shared jq definitions.
#   p4b_claims: the body claims automated Phase 4b provenance. It opens with
#     a bold "Automated" or "Direct" Phase 4b review heading (any case or
#     spacing), or carries the run marker, the owner-authorization record or
#     the orchestrator footer anywhere. A manual handoff review carries none
#     of these and is never classified.
#   p4b_claiming: a review, by an account that is not a GitHub App bot,
#     whose body claims it. Bots (Codex, CodeRabbit) never post a Phase 4b
#     verdict, and their reviews quote this repository's own diffs, which
#     carry these markers whenever the Phase 4b code changes.
#   p4b_owner_authorization: the authorization record the orchestrator
#     writes directly before its run marker and footer, read from the same
#     final trailer p4b_run_marker selects. A quoted copy elsewhere in the
#     body, even a complete authorization/run/footer example, is not it.
#   p4b_seconds: an ISO-8601 instant as whole seconds, or null when it is not
#     one (malformed evidence never orders).
P4B_PROV_JQ_DEFS="$P4B_PROV_RUN_MARKER_JQ"'
def p4b_claims:
  (. // "") as $b
  | ($b | test("\\A[\\s]*\\*\\*[\\s]*(automated|direct)[\\s]+phase[\\s]*4b[\\s]+review[\\s]*\\*\\*"; "i"))
    or ($b | test("<!--[\\s]*mergepath-p4b-(run[\\s]*:[\\s]*[A-Za-z0-9._-]+|owner-authorization[\\s]*:[\\s]*[0-9]+)[\\s]*-->"; "i"))
    or ($b | test("_Posted by scripts/phase-4b-review\\.sh"; "i"));
def p4b_claiming:
  type == "object" and ((.user.login // "") | endswith("[bot]") | not) and (.body | p4b_claims);
def p4b_owner_authorization:
  [(. // "") | capture("(<!-- mergepath-p4b-owner-authorization: (?<c>[1-9][0-9]*) -->\\s+)?<!-- mergepath-p4b-run: (?<r>[A-Za-z0-9._-]+) -->\\s+_Posted by scripts/phase-4b-review\\.sh"; "g")]
  | last | if . == null then null else .c end;
def p4b_seconds:
  if type == "string" and test("\\A[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\\.[0-9]+)?Z\\z")
  then try (sub("\\.[0-9]+"; "") | fromdateiso8601) catch null
  else null end;
# p4b_authorization($cid; $author; $url; $head; $floor): validate one owner
# authorization comment from the input array of PR issue comments. $floor is
# an instant the comment must be strictly newer than, or "" for none.
def p4b_authorization($cid; $author; $url; $head; $floor):
  [ .[] | select(type == "object" and ((.id // null) | tostring) == ($cid | tostring)) ] as $m
  | if ($m | length) != 1 then {ok:false, why:"comment \($cid) is not a comment on this pull request"}
    else $m[0] as $c
    | (($c.body // "") | if type == "string" then . else "" end) as $body
    | [ $body | split("\n")[] | rtrimstr("\r") | select(test("P4B_EXTRA_ROUND_AUTHORIZED"; "i")) ] as $lines
    | ($lines[0] // "" | capture("\\A[ \\t]*P4B_EXTRA_ROUND_AUTHORIZED=(?<url>[^@\\s]+)@(?<head>[0-9a-f]{40})[ \\t]+reason:[ \\t]*(?<reason>[^\\r\\n]*[^\\s])[ \\t]*\\z") // null) as $mk
    | if ($c.user.login // "") != $author then {ok:false, why:"comment \($cid) is not by the configured author_identity \($author)"}
      elif ($c.created_at | type) != "string" or $c.updated_at != $c.created_at then {ok:false, why:"comment \($cid) was edited after it was posted"}
      elif ($lines | length) != 1 then {ok:false, why:"comment \($cid) must carry exactly one P4B_EXTRA_ROUND_AUTHORIZED line (found \($lines | length))"}
      elif $mk == null then {ok:false, why:"comment \($cid) has a malformed P4B_EXTRA_ROUND_AUTHORIZED line (expected <canonical-https-PR-URL>@<full-head-sha> reason: <why>)"}
      elif ($mk.url | ascii_downcase) != ($url | ascii_downcase) then {ok:false, why:"comment \($cid) authorizes another pull request (\($mk.url))"}
      elif $mk.head != $head then {ok:false, why:"comment \($cid) authorizes head \($mk.head), not \($head); a new head needs a fresh authorization"}
      elif ($mk.reason | length) > 500 then {ok:false, why:"comment \($cid) gives a reason longer than 500 characters"}
      elif $floor != "" and ((($c.created_at | p4b_seconds) as $a | ($floor | p4b_seconds) as $f
             | ($a | type) == "number" and ($f | type) == "number" and $a > $f) | not)
        then {ok:false, why:"comment \($cid) is not newer than the latest automated Phase 4b review (\($floor)); an authorization cannot be recorded before the round that spent the cap"}
      else {ok:true, comment_id:($c.id), head:$mk.head, reason:$mk.reason, created_at:$c.created_at,
            html_url:($c.html_url // null)} end
    end;'

# p4b_prov_pr_url <repo> <pr> -> the canonical https URL an authorization names.
p4b_prov_pr_url() { printf 'https://github.com/%s/pull/%s' "$1" "$2"; }

# p4b_prov_authorization <comments-json> <comment-id> <author> <pr-url> <head> [floor]
# Pure. Prints {ok:true, comment_id, head, reason, created_at, html_url} or
# {ok:false, why}; returns 1 when the comments are not one JSON array.
p4b_prov_authorization() {
  printf '%s' "${1:-}" | jq -ce --arg cid "${2:-}" --arg author "${3:-}" --arg url "${4:-}" \
    --arg head "${5:-}" --arg floor "${6:-}" "$P4B_PROV_JQ_DEFS"'
    if type != "array" then error("comments are not an array") else . end
    | p4b_authorization($cid; $author; $url; $head; $floor)' 2>/dev/null
}

# p4b_prov_latest_claim_at <reviews-json> -> the latest submitted_at among
# reviews that claim automated provenance, or "" when there are none. An owner
# authorization must be newer than it. Returns 1 on a non-array.
p4b_prov_latest_claim_at() {
  printf '%s' "${1:-}" | jq -er "$P4B_PROV_JQ_DEFS"'
    if type != "array" then error("reviews are not an array") else . end
    | [ .[] | select(p4b_claiming) | .submitted_at | strings ]
    | max // ""' 2>/dev/null
}

# p4b_prov_ledger_parse <commit-message> -> entries JSON array, or rc 1.
# The same acceptance as scripts/phase-4b/lib.sh p4b_round_ledger_parse (the
# round-cap suite asserts parity), plus: an `authorization`, when present, is
# a positive integer comment id.
p4b_prov_ledger_parse() {
  jq -cen --arg msg "${1:-}" '
    [$msg | split("\n")[] | select(startswith("{\"schema\":\"p4b-round-ledger/v1\""))]
    | if length != 1 then error("ledger line missing or repeated") else .[0] | fromjson end
    | if .schema == "p4b-round-ledger/v1" and (.entries | type) == "array"
         and all(.entries[]; (.run | type) == "string" and (.run | test("^[A-Za-z0-9._-]+$"))
                            and (.state == "reserved" or .state == "released")
                            and ((has("authorization") | not)
                                 or ((.authorization | type) == "number" and .authorization >= 1
                                     and (.authorization | floor) == .authorization)))
      then .entries else error("malformed ledger") end' 2>/dev/null
}

# p4b_prov_read_ledger <repo> <pr> -> the ledger entries, "null" when the
# ledger ref does not exist, rc 1 when it is unreadable or malformed. Uses
# `gh api` with the caller's token (contents: read suffices).
p4b_prov_read_ledger() {
  local repo="$1" pr="$2" err ref_json tip commit_json rc=0
  err=$(mktemp "${TMPDIR:-/tmp}/p4b-prov-ledger.XXXXXX") || return 1
  ref_json=$(gh api "repos/$repo/git/ref/mergepath/p4b-rounds/pr-$pr" 2>"$err") || rc=$?
  if [ "$rc" -ne 0 ]; then
    if grep -Eq 'HTTP 404|Not Found' "$err" 2>/dev/null; then rm -f "$err"; printf 'null\n'; return 0; fi
    rm -f "$err"; return 1
  fi
  rm -f "$err"
  tip=$(printf '%s' "$ref_json" | jq -er '.object.sha | select(test("^[0-9a-f]{40}$"))' 2>/dev/null) || return 1
  commit_json=$(gh api "repos/$repo/git/commits/$tip" 2>/dev/null) || return 1
  p4b_prov_ledger_parse "$(printf '%s' "$commit_json" | jq -r '.message // ""' 2>/dev/null)"
}

# p4b_prov_claim_count <reviews-json> -> how many reviews claim automated
# provenance; rc 1 on a non-array. A zero lets the gate skip the ledger read.
p4b_prov_claim_count() {
  printf '%s' "${1:-}" | jq -er "$P4B_PROV_JQ_DEFS"'
    if type != "array" then error("reviews are not an array") else . end
    | [ .[] | select(p4b_claiming) ] | length' 2>/dev/null
}

# p4b_prov_cites_authorization <reviews-json> -> 0 when some review carries an
# anchored owner-authorization record (the gate then reads the PR comments).
p4b_prov_cites_authorization() {
  printf '%s' "${1:-}" | jq -e "$P4B_PROV_JQ_DEFS"'
    any(.[]?; p4b_claiming and ((.body | p4b_owner_authorization) != null))' >/dev/null 2>&1
}

# p4b_prov_classify <reviews-json> <ledger-entries-json|null> <comments-json|null> <author> <pr-url> [trusted-logins-json]
# Pure. Classifies every review that claims automated provenance:
#   ledger            header, run marker before the footer, exactly one
#                     reserved ledger entry for that run on the review's
#                     commit, the only publisher-shaped review carrying that
#                     run id, and no authorization on either side;
#   owner-authorized  the same, and the review's anchored authorization
#                     record equals its ledger entry's authorization, no other
#                     entry consumed it, and the cited comment is a valid
#                     authorization for this PR and the review's commit,
#                     posted before the review;
#   unverified        anything else, with the reason. It is never clearance.
# A review that claims nothing (a manual handoff review), or one by a bot, is
# not listed.
# Run-id uniqueness counts only publisher-shaped carriers: reviews that open
# with the orchestrator header and, when trusted-logins-json (a JSON array of
# the reviewer identities) is given, are by one of those logins. A run marker
# and footer are public text, so a review that merely quotes them (a
# COMMENTED discussion, an unregistered account) must not turn a legitimate
# approval into a duplicate and get it neutralized. A surplus publication by
# the orchestrator itself is still header-bearing and by a reviewer identity,
# so it still counts.
# Prints [{id, login, state, commit_id, class, reason, run, authorization}];
# returns 1 on malformed input.
# The reviews arrive on stdin and the comments through a file: either can
# pass the 131072-byte single-argument limit on Linux (MAX_ARG_STRLEN), and an
# oversized --argjson would keep jq from starting at all. Only the small
# ledger rides on argv.
p4b_prov_classify() {
  local ledger="${2:-null}" comments="${3:-null}" trusted="${6:-null}" cf rc=0
  [ -n "$ledger" ] || ledger=null
  [ -n "$comments" ] || comments=null
  [ -n "$trusted" ] || trusted=null
  cf=$(mktemp "${TMPDIR:-/tmp}/p4b-prov-comments.XXXXXX") || return 1
  printf '%s' "$comments" >"$cf" || { rm -f "$cf"; return 1; }
  printf '%s' "${1:-}" | jq -ce --argjson ledger "$ledger" --argjson trusted "$trusted" --slurpfile cs "$cf" \
    --arg author "${4:-}" --arg url "${5:-}" "$P4B_PROV_JQ_DEFS"'
    (if ($cs | length) == 1 then $cs[0] else error("comments") end) as $comments
    | if type != "array" then error("reviews are not an array") else . end
    | if $ledger != null and ($ledger | type) != "array" then error("ledger") else . end
    | if $comments != null and ($comments | type) != "array" then error("comments") else . end
    | if $trusted != null and (($trusted | type) != "array" or any($trusted[]; type != "string"))
        then error("trusted") else . end
    | . as $all
    | [ $all[] | select(p4b_claiming)
        | select((.body // "") | startswith("**Automated Phase 4b review**"))
        | select($trusted == null or ((.user.login // "") as $l | any($trusted[]; . == $l)))
        | .body | p4b_run_marker | strings ] as $runs
    | [ $all[] | select(p4b_claiming)
        | . as $r
        | ($r.body | p4b_run_marker) as $run
        | ($r.body | p4b_owner_authorization) as $auth
        | ( if $ledger == null then [] else [ $ledger[] | select(.run == $run) ] end ) as $mine
        | ( if $ledger == null then "the PR has no Phase 4b round ledger, so no automated round reserved this review"
            elif (($r.body // "") | startswith("**Automated Phase 4b review**")) | not
              then "it claims automated Phase 4b provenance without opening with the orchestrator header"
            elif $run == null then "it carries no run marker directly before the orchestrator footer"
            elif ($mine | length) != 1 then "run \($run) has \($mine | length) ledger entries, not exactly one"
            elif $mine[0].state != "reserved" then "the ledger entry for run \($run) is \($mine[0].state), not reserved"
            elif $mine[0].head != $r.commit_id then "the ledger reserved run \($run) for head \($mine[0].head // "unknown"), but the review is on \($r.commit_id // "unknown")"
            elif ([ $runs[] | select(. == $run) ] | length) != 1 then "\([ $runs[] | select(. == $run) ] | length) reviews carry run id \($run)"
            elif (($mine[0].authorization // null) | tostring) != ($auth // "null") then "its owner-authorization record does not match the ledger entry for run \($run)"
            elif $auth == null then null
            elif ([ $ledger[] | select(((.authorization // null) | tostring) == $auth) ] | length) != 1
              then "owner authorization \($auth) was consumed by more than one ledger entry"
            elif $comments == null then "the PR comments needed to check owner authorization \($auth) were not read"
            else ($comments | p4b_authorization($auth; $author; $url; ($r.commit_id // ""); "")) as $v
              | if ($v.ok | not) then "owner authorization: \($v.why)"
                elif (($v.created_at | p4b_seconds) as $a | ($r.submitted_at | p4b_seconds) as $s
                      | ($a | type) == "number" and ($s | type) == "number" and $a < $s) | not
                  then "owner authorization \($auth) was not posted before the review"
                else null end
            end ) as $why
        | {id:$r.id, login:($r.user.login // null), state:$r.state, commit_id:($r.commit_id // null),
           class:(if $why != null then "unverified" elif $auth != null then "owner-authorized" else "ledger" end),
           reason:$why, run:$run, authorization:$auth} ]' 2>/dev/null || rc=$?
  rm -f "$cf"
  return "$rc"
}

# p4b_prov_neutralize <reviews-json> <classified-json>
# Pure. Every unverified APPROVED review becomes an opinionated non-approval
# (state DISMISSED, mergepath_p4b_unverified set): it neither clears a gate
# nor lets an earlier approval by the same reviewer stand in its place, the
# fail-closed reading of "this reviewer's latest position cannot be trusted".
p4b_prov_neutralize() {
  # The reviews arrive on stdin (see p4b_prov_classify); the classification
  # lists only claim-bearing reviews and stays small.
  printf '%s' "${1:-}" | jq -ce --argjson c "${2:-[]}" '
    if type != "array" then error("reviews are not an array") else . end
    | ([ $c[] | select(.class == "unverified") | {key:(.id | tostring), value:.reason} ] | from_entries) as $bad
    | map(if type == "object" and (((.id // null) | tostring) as $i | $bad | has($i)) and .state == "APPROVED"
                     then .state = "DISMISSED" | .mergepath_p4b_unverified = $bad[(.id | tostring)] else . end)' 2>/dev/null
}

# p4b_prov_round_cap_enforced <policy-json> -> "true" when the governing
# policy sets phase_4b_automation.max_review_rounds (the ledger is then the
# authority for automated rounds), "false" when it is absent, rc 1 when the
# value or block is malformed. The same acceptance as scripts/phase-4b/lib.sh
# p4b_governing_round_cap (parity asserted in the round-cap suite).
p4b_prov_round_cap_enforced() {
  printf '%s' "${1:-}" | jq -er '
    if .phase_4b_automation == null then "false"
    elif (.phase_4b_automation | type) != "object" then error("invalid")
    elif (.phase_4b_automation | has("max_review_rounds") | not) then "false"
    elif (.phase_4b_automation.max_review_rounds | type) == "number"
         and .phase_4b_automation.max_review_rounds >= 1
         and (.phase_4b_automation.max_review_rounds | floor) == .phase_4b_automation.max_review_rounds
      then "true"
    else error("invalid") end' 2>/dev/null || return 1
}
