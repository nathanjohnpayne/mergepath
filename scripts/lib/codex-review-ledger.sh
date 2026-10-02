#!/usr/bin/env bash
# scripts/lib/codex-review-ledger.sh
#
# Report-only Codex review ledger (#1560, slice 2). Reconstructs, from records
# GitHub already holds, which Codex responses a PR's Codex requests drew, and
# reports every case whose attribution the record cannot prove as ambiguous
# instead of guessing. It decides nothing: no requester, barrier or
# merge-gate path reads it. Its job is to produce the evidence the counting
# and routing decision on #1560 is made from. The contract, including every
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
#                  root_findings: [{comment_id, tier}], reply_comments: N,
#                  reply_markers: [...]}],
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
                      else "no_findings" end) } ]
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
        | if $rev != null then
            { class: $rev.grade, conflicting: ($rev.grade == "blocking" and $clean_signal) }
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
              signals: [$grp.sigs[].sid],
              class: $c.class, conflicting: $c.conflicting,
              mixed_heads: ($heads > 1),
              multiple_in_window: (($g | length) > 1),
              tie: ($grp.sigs | any(.tie)),
              tie_times: ([ $grp.sigs[] | select(.tie) | .t ] | unique),
              anchor_conflict: ($grp.sigs | any(.anchor_conflict // false)),
              provider_blocked: ([$grp.sigs[] | select(.kind == "block") | .reason] | unique) } ] ) as $responses

    # ---- attribution sweep -----------------------------------------------------
    # unresolved: requests not yet attributed; debt: how many of them may still
    # be owed a response. A response is attributed only when it is the window''s
    # only response, its own request is the only unresolved one, nothing earlier
    # is still owed, it is not a same-second tie, and nothing makes it a
    # plausible second answer to an earlier request (same head anchor as an
    # earlier attributed response, or no anchor at all after the first window).
    | ( reduce range(1; $n + 1) as $k
          ( {unresolved: [], debt: 0, att: {}, amb: {}, second: {}, anchors: {}};
            .unresolved += [$k] | .debt += 1
            | [ $responses[] | select(.window == $k) ] as $rs
            | if ($rs | length) == 0 then .
              else
                . as $st
                | ( [ $rs[] | .anchor as $a
                      | if $a == null then (if $k > 1 then [$k - 1] else [] end)
                        else [ $st.anchors | to_entries[] | select(.value != null and same_head(.value; $a))
                               | .key | tonumber ] end ]
                    | add | unique | map(select(. < $k)) ) as $extra
                # A response in the same second as a request may precede every
                # request of that second, so it could answer any of them or the
                # last request strictly before that second.
                | ( [ $rs[].tie_times[] as $tt
                      | ( [ $reqs[] | select(.created_at == $tt and .k != $k) | .k ]
                          + ([ $reqs[] | select(.created_at < $tt) | .k ] | if length > 0 then [max] else [] end) ) ]
                    | add // [] | unique ) as $tieprev
                | ( ($rs | length) == 1 and $st.unresolved == [$k] and $st.debt == 1
                    and ($tieprev | length) == 0 and (any($rs[]; .tie) | not)
                    and ($extra | length) == 0 ) as $clean
                | if $clean then
                    .att[($k | tostring)] = [$rs[0].rid]
                    | .anchors[($k | tostring)] = $rs[0].anchor
                    | .unresolved = [] | .debt = 0
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
                    # An earlier request may have taken the response, so it
                    # pays the debt only when no earlier request competes.
                    | .debt = (if ($extra | length) > 0 or ($tieprev | length) > 0 then $st.debt
                               else ([$st.debt - ($rs | length), 0] | max) end)
                    | if .debt == 0 then .unresolved = [] else . end
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
      current_summary: $in.summary,
      limits: [
        "a request comment names no commit; request heads are never inferred",
        "eyes are current state: Codex removes them when a review finishes",
        "the pull-request thumbs-up keeps only its latest creation; earlier reaction-only clean passes leave no record",
        "the Review Summary is edited in place; only its current state is visible"
      ],
      summary: {
        requests: ([ $requests[] | select(.counted) ] | length),
        foreign_requests: ([ $requests[] | select(.counted | not) ] | length),
        outcomes: outcomes([ $requests[] | select(.counted) ]),
        foreign_outcomes: outcomes([ $requests[] | select(.counted | not) ]),
        open_debt: $sweep.debt,
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
