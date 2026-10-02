#!/usr/bin/env bash
# scripts/lib/codex-review-ledger.sh
#
# Codex review ledger (#1560, slice 2). Reconstructs, from records GitHub
# already holds, which Codex responses a PR's Codex requests drew, and
# reports every case whose attribution the record cannot prove as ambiguous
# instead of guessing. Its one decision input is the per-PR count of
# solicited blocking responses, which the requester's blocking-review budget
# reads (slice 3) and which does not depend on attribution; the Phase 4b human
# stops (crl_human_stops) do depend on it, to decide a tested rebuttal. The contract, including every
# rule below, is specs/codex_review_ledger.md.
#
# What the record does not prove, and how the ledger treats it:
#   - A request comment names no commit, so a request never gets a head from
#     timestamps. A response's head comes only from its own anchor (a review's
#     commit_id, a verdict's "Reviewed commit"); reactions and block notices
#     carry none.
#   - Anyone can request a review. Requests from other accounts, or author
#     comments that are not the exact command, are FOREIGN: they open windows
#     and are attribution candidates, but are not counted as the configured
#     author's requests (the set the request cap counts).
#   - Codex reacts with eyes while a review runs and usually removes the
#     reaction when it finishes, so eyes are current state. The ledger only
#     says eyes came before a re-post when the reaction's own timestamp proves
#     it; otherwise it says unknown.
#   - The thumbs-up on the pull request is one reaction per user: only its
#     latest creation survives, so earlier reaction-only clean passes leave no
#     record. The Review Summary is edited in place. Both are listed in
#     `limits` on every ledger.
#
# Every comment body is parsed by an existing shared helper the caller runs
# first (crqe_trigger_generation, crqe_ack_present's selection, codex_tiers_of,
# codex_tier_of, codex_failure_marker_of, crqe_verdicts,
# crqe_select_codex_review_summary). This file only orders and attributes the
# results, so it adds no second grammar.

# crl_ledger <inputs-json>
#
# <inputs-json>:
#   {
#     pr, repo, head_sha, author, bot, required_tiers: ["p1", ...],
#     requests:  [{id, created_at, counted: true|false, source, author,
#                  eyes_at: iso|null}],
#     reviews:   [{id, submitted_at, commit_id|null, body_tiers: [...],
#                  root_findings: [{comment_id, tier, path}], reply_comments: N,
#                  reply_markers: [...]}],
#     rebuttals: [{finding, path, at, sources: [...]}],  # optional (slice 3)
#     verdicts:  [{comment_id, created_at, reviewed_shas: [...], affirmative}],
#     reactions: [{id, created_at}],             # bot +1 on the PR issue
#     blocks:    [{comment_id, created_at, reason}],
#     summary:   null | {status, commit, observed_at, ...}
#   }
# Prints the ledger JSON. Pure jq; returns jq's status.
crl_ledger() {
  printf '%s\n' "$1" | jq -c '
    def epoch: sub("\\.[0-9]+"; "") | fromdateiso8601;
    def same_head($a; $b):
      ($a | ascii_downcase) as $x | ($b | ascii_downcase) as $y
      | ($x | startswith($y)) or ($y | startswith($x));
    # One anchor for a list of shas, or null when they disagree or are absent.
    def consistent_anchor:
      if length == 0 then null
      elif (. as $s | all(.[]; . as $a | $s | all(.[]; same_head($a; .)))) then max_by(length)
      else null end;

    . as $in
    | ($in.required_tiers // []) as $required
    | def blocking_tier($t): $t == "p0" or ($required | index($t)) != null;

    # ---- requests and windows ----------------------------------------------
    ( [ $in.requests | sort_by(.created_at, (.id | tostring)) | to_entries[] | .value + {k: (.key + 1)} ] ) as $reqs
    | ($reqs | length) as $n
    | def window_of($t): ([ $reqs[] | select(.created_at <= $t) | .k ] | max) // 0;
      def tie_of($t): ([ $reqs[] | select(.created_at == $t) ] | length) > 0;

    # ---- signals -------------------------------------------------------------
      ( [ $in.reviews[]
          | select((.root_findings | length) > 0 or (.body_tiers | length) > 0 or .reply_comments == 0)
          | ([.root_findings[].tier] + .body_tiers) as $tiers
          | { sid: ("review:" + (.id | tostring)), kind: "review", t: .submitted_at,
              anchor: .commit_id,
              grade: (if ($tiers | any(. as $x | blocking_tier($x))) then "blocking"
                      elif ($tiers | length) > 0 then "discretionary"
                      else "no_findings" end),
              # Where the blocking findings sit, for the disagreement check:
              # inline findings carry a path; body findings and inline findings
              # without one cannot be located.
              blocking_paths: ([ .root_findings[] | select(blocking_tier(.tier)) | .path | select(type == "string") ] | unique),
              blocking_unlocated: ((.body_tiers | any(. as $x | blocking_tier($x)))
                                   or any(.root_findings[]; blocking_tier(.tier) and ((.path | type) != "string"))) } ]
        + [ $in.verdicts[]
            | (.reviewed_shas | consistent_anchor) as $anchor
            | { sid: ("verdict:" + (.comment_id | tostring)), kind: "verdict", t: .created_at,
                anchor: $anchor,
                anchor_conflict: ($anchor == null and (.reviewed_shas | length) > 0),
                affirmative } ]
        + [ $in.reactions[] | { sid: ("reaction:" + (.id | tostring)), kind: "reaction", t: .created_at, anchor: null } ]
        + [ $in.blocks[] | { sid: ("block:" + (.comment_id | tostring)), kind: "block", t: .created_at,
                             anchor: null, reason } ]
        | map(. + {w: window_of(.t), tie: tie_of(.t)})
        | sort_by(.t, .sid) ) as $signals

    # ---- responses: one review per response ----------------------------------
    # Each review is its own response. A verdict joins the latest review on
    # the same head at or before it (else the earliest later one) in its
    # window; otherwise it stands alone. Anchorless signals join the window''s
    # single response, or form their own when the window has none or several.
    | def responses_of($w):
        ( [ $signals[] | select(.w == $w) ] ) as $ws
        | ( [ $ws[] | select(.kind == "review") | {anchor, sigs: [.]} ] ) as $g0
        | ( reduce ($ws[] | select(.kind == "verdict" and .anchor != null)) as $v ($g0;
              ( [ to_entries[] | select(.value.sigs[0].kind == "review" and .value.anchor != null
                                        and same_head(.value.anchor; $v.anchor)) ] ) as $m
              | ( [ $m[] | select(.value.sigs[0].t <= $v.t) ] | last
                  // ($m | first) ) as $hit
              | if $hit == null then . + [{anchor: $v.anchor, sigs: [$v]}]
                else .[$hit.key].sigs += [$v] end ) ) as $g1
        # Anchorless reviews are already their own responses in $g0.
        | ( [ $ws[] | select(.anchor == null and .kind != "review") ] ) as $free
        | if ($g1 | length) == 0 then
            (if ($free | length) == 0 then [] else [{anchor: null, sigs: $free}] end)
          elif ($g1 | length) == 1 then [ $g1[0] | .sigs += $free ]
          else $g1 + (if ($free | length) == 0 then [] else [{anchor: null, sigs: $free}] end)
          end;
      def classify:
        . as $g
        | ([ $g.sigs[] | select(.kind == "review") ] | first) as $rev
        | ([ $g.sigs[] | select(.kind == "verdict") ]) as $ver
        | ([ $g.sigs[] | select(.kind == "reaction") ]) as $rea
        | ([ $g.sigs[] | select(.kind == "block") ]) as $blk
        | (($ver | any(.affirmative)) or ($rea | length) > 0) as $clean_signal
        | (($ver | any(.affirmative)) and ($ver | any(.affirmative | not))) as $verdicts_disagree
        | if $rev != null then
            { class: $rev.grade,
              conflicting: (($rev.grade == "blocking" and $clean_signal) or $verdicts_disagree) }
          elif ($ver | length) > 0 then
            { class: (if ($ver | all(.affirmative)) then "clean" else "unknown_tier" end),
              conflicting: (($ver | any(.affirmative)) and ($ver | any(.affirmative | not))) }
          elif ($rea | length) > 0 then { class: "clean", conflicting: false }
          elif ($blk | length) > 0 then { class: "provider_blocked", conflicting: false }
          else { class: "no_findings", conflicting: false } end;
      ( [ range(0; $n + 1) as $w
          | responses_of($w) as $g
          # Distinct heads: the anchors that are not a proper prefix of another
          # anchor. A short sha and its full sha are one head, but a short sha
          # matching two different full shas does not merge them.
          | ( [ $g[] | .anchor | select(. != null) | ascii_downcase ] | unique ) as $anch
          | ( [ $anch[] as $a | select(all($anch[]; . == $a or (startswith($a) | not))) ] | length ) as $heads
          | $g | to_entries[]
          | .value as $grp
          | ($grp | classify) as $c
          | { rid: ("w" + ($w | tostring) + "." + (.key | tostring)),
              window: $w, unsolicited: ($w == 0),
              anchor: $grp.anchor,
              first_at: ([$grp.sigs[].t] | min),
              blocking_paths: ([ $grp.sigs[] | select(.kind == "review") | .blocking_paths[] ] | unique),
              blocking_unlocated: ($c.class == "unknown_tier" or $c.conflicting
                                   or any($grp.sigs[]; .kind == "review" and .blocking_unlocated)),
              signals: [$grp.sigs[].sid],
              class: $c.class, conflicting: $c.conflicting,
              mixed_heads: ($heads > 1),
              multiple_in_window: (($g | length) > 1),
              tie: ($grp.sigs | any(.tie)),
              tie_times: ([ $grp.sigs[] | select(.tie) | .t ] | unique),
              anchor_conflict: ($grp.sigs | any(.anchor_conflict // false)),
              provider_blocked: ([$grp.sigs[] | select(.kind == "block") | .reason] | unique) } ] ) as $responses

    # ---- attribution sweep -----------------------------------------------------
    # unresolved: requests that may still be owed a response. A response is
    # attributed only when it is the window''s only response, its own request
    # is the only unresolved one, it is not a same-second tie, and nothing makes
    # it a plausible second answer to an earlier request (an earlier request
    # holding a response on the same head, or an anchorless response after the
    # first window). Responses never name the request they answer, so an
    # ambiguous window settles its requests only when that coverage is proven:
    # its own request is the only candidate (#1572). Otherwise every candidate
    # stays unresolved, because several responses can all answer one request.
    # anchors: every head a request may have been answered on, recorded for
    # each candidate of an ambiguous window too (#1573).
    | ( reduce range(1; $n + 1) as $k
          ( {unresolved: [], att: {}, amb: {}, second: {}, anchors: {}};
            .unresolved += [$k]
            | [ $responses[] | select(.window == $k) ] as $rs
            | if ($rs | length) == 0 then .
              else
                . as $st
                | ( [ $rs[] | .anchor | select(. != null) ] ) as $ranchors
                | ( [ $rs[] | .anchor as $a
                      | if $a == null then (if $k > 1 then [$k - 1] else [] end)
                        else [ $st.anchors | to_entries[] | select(any(.value[]; same_head(.; $a)))
                               | .key | tonumber ] end ]
                    | add | unique | map(select(. < $k)) ) as $extra
                # A response in the same second as a request may precede every
                # request of that second, so it could answer any of them or the
                # last request strictly before that second.
                | ( [ $rs[].tie_times[] as $tt
                      | ( [ $reqs[] | select(.created_at == $tt and .k != $k) | .k ]
                          + ([ $reqs[] | select(.created_at < $tt) | .k ] | if length > 0 then [max] else [] end) ) ]
                    | add // [] | unique ) as $tieprev
                | ( $st.unresolved == [$k] and ($tieprev | length) == 0
                    and (any($rs[]; .tie) | not) and ($extra | length) == 0 ) as $covered
                | if $covered and ($rs | length) == 1 then
                    .att[($k | tostring)] = [$rs[0].rid]
                    | .anchors[($k | tostring)] = $ranchors
                    | .unresolved = []
                  else
                    ( [ $tieprev, $st.unresolved, $extra ] | add | unique ) as $cand
                    | ( [ (if ($rs | length) > 1 then "several responses in one window" else empty end),
                          (if ([ $st.unresolved[] | select(. != $k and ($st.amb[(. | tostring)] | not)) ] | length) > 0
                           then "more than one request unresolved" else empty end),
                          (if ([ $st.unresolved[] | select(. != $k and ($st.amb[(. | tostring)] != null)) ] | length) > 0
                           then "an earlier ambiguous window may still owe a response" else empty end),
                          (if any($rs[]; .tie) then "a response in the same second as a request" else empty end),
                          (if ($extra | length) > 0 then "could be a second or late answer to an earlier request" else empty end) ]
                        | join("; ") ) as $why
                    | reduce $st.unresolved[] as $u (.;
                        .amb[($u | tostring)] = { responses: ((.amb[($u | tostring)].responses // []) + [$rs[].rid]),
                                                  candidates: ((.amb[($u | tostring)].candidates // []) + $cand | unique),
                                                  reasons: ((.amb[($u | tostring)].reasons // []) + [$why] | unique) })
                    # Earlier requests outside the unresolved set that may also
                    # have received this response (second/late answer or tie).
                    | reduce ([ $extra[], $tieprev[] ] | unique | map(select(. as $x | $st.unresolved | index($x) | not)))[] as $x
                        (.; .second[($x | tostring)] = ((.second[($x | tostring)] // []) + [$rs[].rid] | unique))
                    # Any candidate may have been answered on these heads.
                    | reduce $cand[] as $c (.;
                        .anchors[($c | tostring)] = ((.anchors[($c | tostring)] // []) + $ranchors | unique))
                    | if $covered then .unresolved = [] else . end
                  end
              end ) ) as $sweep

    | ( [ $reqs[]
          | .k as $k | ($k | tostring) as $ks
          | (if $k < $n then $reqs[$k] else null end) as $next
          | ( [ $responses[] | select(.window == $k) ] | length ) as $own
          | { id, created_at, counted, source, author, eyes_at,
              outcome: ( if $sweep.att[$ks] then "attributed"
                         elif $sweep.amb[$ks] then "ambiguous"
                         elif $k == $n then "no_response_yet"
                         else "unanswered" end ),
              responses: ($sweep.att[$ks] // $sweep.amb[$ks].responses // []),
              candidates: ( ($sweep.amb[$ks].candidates // []) | map($reqs[. - 1].id) ),
              reasons: ($sweep.amb[$ks].reasons // []),
              possible_second_response: ($sweep.second[$ks] // []),
              reposted_without_response: ($next != null and $own == 0),
              repost_gap_seconds: (if $next != null and $own == 0
                                   then (($next.created_at | epoch) - (.created_at | epoch)) else null end),
              eyes_before_repost: (if $next == null or $own > 0 then null
                                   elif .eyes_at == null then "unknown"
                                   elif .eyes_at < $next.created_at then true
                                   else false end) } ] ) as $requests

    | ( [ $in.reviews[] | select((.root_findings | length) == 0 and (.body_tiers | length) == 0
                                 and .reply_comments > 0) ] ) as $wrappers
    | def outcomes($rs): reduce $rs[] as $r ({attributed: 0, ambiguous: 0, unanswered: 0, no_response_yet: 0};
                                             .[$r.outcome] += 1);
    {
      pr: $in.pr, repo: $in.repo, head_sha: $in.head_sha,
      author: $in.author, bot: $in.bot, required_tiers: $required,
      requests: $requests,
      responses: $responses,
      thread_reply_reviews: [ $wrappers[] | {id, submitted_at, commit_id, reply_markers} ],
      rebuttals: ($in.rebuttals // [] | sort_by(.at, (.finding | tostring))),
      current_summary: $in.summary,
      limits: [
        "a request comment names no commit; request heads are never inferred",
        "eyes are current state: Codex removes them when a review finishes",
        "the pull-request thumbs-up keeps only its latest creation; earlier reaction-only clean passes leave no record",
        "the Review Summary is edited in place; only its current state is visible",
        "request comments are read as they stand now; an edited or deleted request changes the reconstructed windows"
      ],
      summary: {
        requests: ([ $requests[] | select(.counted) ] | length),
        foreign_requests: ([ $requests[] | select(.counted | not) ] | length),
        outcomes: outcomes([ $requests[] | select(.counted) ]),
        foreign_outcomes: outcomes([ $requests[] | select(.counted | not) ]),
        open_debt: ([ $sweep.unresolved[] | select($sweep.amb[(. | tostring)] != null) ] | length),
        eyes_now: ([ $requests[] | select(.eyes_at != null) ] | length),
        reposted_without_response: ([ $requests[] | select(.counted and .reposted_without_response) ] | length),
        reposted_after_eyes: ([ $requests[] | select(.counted and .eyes_before_repost == true) ] | length),
        reposted_eyes_unknown: ([ $requests[] | select(.counted and .eyes_before_repost == "unknown") ] | length),
        responses: ($responses | length),
        unsolicited_responses: ([ $responses[] | select(.unsolicited) ] | length),
        responses_by_class: ( reduce $responses[] as $r ({}; .[$r.class] += 1) ),
        blocking_responses: ([ $responses[] | select(.class == "blocking") ] | length),
        blocking_responses_solicited: ([ $responses[] | select(.class == "blocking" and (.unsolicited | not)) ] | length),
        mixed_head_windows: ([ $responses[] | select(.mixed_heads) | .window ] | unique | length),
        multiple_response_windows: ([ $responses[] | select(.multiple_in_window) | .window ] | unique | length),
        tie_responses: ([ $responses[] | select(.tie) ] | length),
        conflicting_responses: ([ $responses[] | select(.conflicting) ] | length),
        anchor_conflicts: ([ $responses[] | select(.anchor_conflict) ] | length),
        thread_reply_reviews: ($wrappers | length)
      }
    }
  '
}

# The blocking-review budget's counting rule (#1560 slice 3), shared by the
# requester and the Phase 4b barrier. A response counts when it came after at
# least one request and is classed blocking or unknown_tier, or is
# conflicting: unknown and conflicting evidence counts against the budget,
# never for it.
__CRL_COUNTS='(.unsolicited | not) and (.class == "blocking" or .class == "unknown_tier" or .conflicting)'
# A ledger is usable for a decision only when every response carries the
# fields the rule reads, and every rebuttal the fields the stop check reads.
# A class outside the known set (version skew, malformed output) is refused,
# never read as non-blocking.
__CRL_VALID='type == "object" and (.responses | type) == "array"
  and all(.responses[]; (.unsolicited | type) == "boolean" and (.conflicting | type) == "boolean"
                        and (.first_at | type) == "string" and (.first_at | length) > 0
                        and (.class as $c | ["blocking", "discretionary", "no_findings", "clean",
                                             "unknown_tier", "provider_blocked"] | index($c)) != null)'

# crl_blocking_count <ledger-json> <head> <author>
# Prints the count. Returns nonzero when the ledger is malformed or names
# another head or author.
crl_blocking_count() {
  printf '%s\n' "$1" | jq -ser --arg head "$2" --arg author "$3" "
    if length != 1 then error(\"documents\") else .[0] end
    | if ($__CRL_VALID) and .head_sha == \$head and .author == \$author
    then [ .responses[] | select($__CRL_COUNTS) ] | length
    else error(\"ledger\") end" 2>/dev/null
}

# crl_human_stops <ledger-json> <head> <author> <max-blocking-reviews> [request-ceiling]
#
# The human-stop conditions the Phase 4b barrier re-evaluates before it lets a
# spent request ceiling dispatch the automated adapter (#1560 slice 3, S3-4):
#   blocking-budget    the counted responses reach the budget;
#   runaway            the request windows with a counted response reach the
#                      request ceiling before the budget: every request the
#                      ceiling allowed drew a
#                      blocking review, so a ceiling below the budget (for
#                      example max_review_rounds 2 against the default budget
#                      of 10) never reads as cost exhaustion (#1560 canary);
#   untested-rebuttal  a rebutted Codex finding has no Codex response after
#                      its rebuttal, so Codex never re-read the dispute;
#   disagreement       a counted (blocking, unknown-tier or conflicting)
#                      response to a request posted after a rebuttal. Any
#                      path counts: a re-raise can move with a rename, so the
#                      path cannot rule a repeat out (#1560 canary).
# Prints {blocking_reviews, max_blocking_reviews, stops: [...],
# untested_rebuttals: [...], disagreements: [...]}. Returns nonzero unless the
# input is exactly one well-formed ledger for this head and author, read under
# a policy snapshot with the same max_blocking_reviews.
crl_human_stops() {
  printf '%s\n' "$1" | jq -sec --arg head "$2" --arg author "$3" --argjson max "$4" \
    --argjson ceiling "${5:-null}" "
    if length != 1 then error(\"documents\") else .[0] end
    | if (($__CRL_VALID) and .head_sha == \$head and .author == \$author
        and .max_blocking_reviews == \$max
        and (.rebuttals | type) == \"array\"
        and (.requests | type) == \"array\"
        and all(.requests[]; (.created_at | type) == \"string\" and (.outcome | type) == \"string\"
                             and (.responses | type) == \"array\"
                             # counted decides which windows a runaway counts;
                             # absent or malformed must fail, not read as foreign.
                             and (.counted | type) == \"boolean\")
        and all(.responses[]; (.first_at | type) == \"string\" and (.window | type) == \"number\"
                              and (.blocking_paths | type) == \"array\"
                              and (.blocking_unlocated | type) == \"boolean\")
        and all(.rebuttals[]; (.at | type) == \"string\" and (.finding | type) == \"number\"
                              and ((.path | type) == \"string\" or .path == null))) | not
    then error(\"ledger\") else . end
    | .responses as \$rs
    | .requests as \$reqs
    | ([ \$rs[] | select($__CRL_COUNTS) ] | length) as \$n
    # Runaway compares the ceiling with REQUEST WINDOWS that drew a counted
    # response, not with responses: a window can hold several (#1584).
    # Only windows opened by COUNTED (configured-author) requests, which is
    # what the ceiling counts; a foreign mention opens a window too (#1584).
    | ([ \$rs[] | select($__CRL_COUNTS) | .window
         | select(. > 0 and (\$reqs[. - 1].counted == true)) ] | unique | length) as \$nw
    # A runaway needs EVERY counted request to have drawn a blocking review,
    # not just as many windows as the current ceiling: a lowered ceiling or
    # concurrent near-cap callers can leave more requests than it (#1584).
    | ([ \$reqs[] | select(.counted == true) ] | length) as \$nr
    | [ .rebuttals[] | . as \$r
        # Only a response to a request posted AFTER the rebuttal can have read
        # it: a request already in flight may be answered later without
        # seeing it (#1579). Windows are numbered by request in time order, so
        # those are the windows from the first later request on. A
        # provider-block notice is not Codex re-reading the dispute.
        | ([ \$reqs | to_entries[] | select(.value.created_at > \$r.at) | .key + 1 ] | min) as \$k0
        | [ \$rs[] | select(\$k0 != null and .window >= \$k0 and .first_at > \$r.at
                            and .class != \"provider_blocked\") ] as \$after
        # Tested needs PROOF: a response the ledger attributes to a request
        # posted after the rebuttal. A later-window response whose attribution
        # is ambiguous may be a late answer to an earlier request, so it does
        # not clear the stop (fail closed on ambiguity). Disagreement keeps the
        # broader window set, where counting more responses is the safe side.
        | ([ \$reqs[] | select(.created_at > \$r.at and .outcome == \"attributed\") | .responses[] ]) as \$proven
        | [ \$after[] | select(.rid as \$id | \$proven | index(\$id)) ] as \$tested
        | ( [ \$after[] | select($__CRL_COUNTS) ] ) as \$again
        | if (\$tested | length) == 0 and (\$again | length) == 0
          then {kind: \"untested\", finding: \$r.finding, path: \$r.path, at: \$r.at}
          else .
               | if (\$again | length) > 0
                 then {kind: \"disagreement\", finding: \$r.finding, path: \$r.path, at: \$r.at,
                       responses: [ \$again[].rid ]}
                 else empty end
          end ] as \$disputes
    | { blocking_reviews: \$n, max_blocking_reviews: \$max,
        untested_rebuttals: [ \$disputes[] | select(.kind == \"untested\") | del(.kind) ],
        disagreements: [ \$disputes[] | select(.kind == \"disagreement\") | del(.kind) ] }
    | .request_ceiling = \$ceiling
    | .blocking_windows = \$nw
    | .counted_requests = \$nr
    | .stops = ( [ (if \$n >= \$max then \"blocking-budget\" else empty end),
                   (if \$n < \$max and \$ceiling != null and \$ceiling > 0 and \$nr >= \$ceiling and \$nw >= \$nr then \"runaway\" else empty end),
                   (if (.disagreements | length) > 0 then \"disagreement\" else empty end),
                   (if (.untested_rebuttals | length) > 0 then \"untested-rebuttal\" else empty end) ] )" 2>/dev/null
}
