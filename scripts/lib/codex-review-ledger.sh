#!/usr/bin/env bash
# scripts/lib/codex-review-ledger.sh
#
# Report-only Codex review ledger (#1560, slice 2). Reconstructs, from records
# GitHub already holds, which Codex responses a PR's configured-author requests
# drew, and reports every case whose attribution cannot be proven as
# ambiguous instead of guessing. It decides nothing: no requester, barrier or
# merge-gate path reads it. Its job is to produce the evidence the counting
# and routing decision on #1560 is made from.
#
# Two outputs are kept apart on purpose (#1560 decision, correction 4):
#   - a response CLASS (blocking / discretionary / no_findings / clean / ...),
#     which says what Codex answered;
#   - nothing about merge clearance, which stays with codex-review-check.sh.
#
# What GitHub does and does not prove, and how the ledger treats it:
#   - A request comment names no commit (scripts/lib/codex-request-evidence.sh
#     header), so a request's head is never inferred from timestamps. A
#     response's head comes only from its own anchor (review commit_id, verdict
#     "Reviewed commit"); reactions and block notices carry none.
#   - A response is attributed to a request only when exactly one request is
#     outstanding when it lands. Two or more outstanding requests make it
#     ambiguous, with every candidate listed. A response before the first
#     request is unsolicited (for example an automatic review on open).
#   - Acknowledgement is only partly recoverable. Codex reacts with eyes while
#     a review runs and removes the reaction when it finishes, so a request
#     shows `eyes_now: true` only while Codex is still working on it; `false`
#     does NOT prove the request was never acknowledged.
#   - Acknowledgement retries are FLAGGED (`possible_ack_retry_of`), never
#     folded: a request is flagged when the previous one shows no eyes now,
#     nothing answered it, and it was posted within `retry_window_seconds`.
#     Folding is a counting rule for #1560 to choose.
#   - Review objects that only wrap thread replies (every inline comment is a
#     reply) are not responses; they are reported separately, because a
#     connector reply in a thread lands as one (#1543).
#
# All parsing of comment bodies happens in the shared helpers the caller runs
# first (crqe_trigger_generation, crqe_ack_present, codex_tiers_of,
# codex_tier_of, codex_failure_marker_of, crqe_verdict_of,
# crqe_select_codex_review_summary). This file only orders and attributes the
# results, so it adds no second grammar.
#
# Window rule: a signal at time t belongs to the window of the latest request
# posted at or before t. A signal in the same second as a later request belongs
# to that later request's window.

# crl_ledger <inputs-json>
#
# <inputs-json>:
#   {
#     pr, repo, head_sha, author, bot, required_tiers: ["p1", ...],
#     retry_window_seconds: N,
#     requests:  [{id, created_at, eyes_now: true|false}],
#     reviews:   [{id, submitted_at, commit_id, body_tiers: ["p2", ...],
#                  root_findings: [{comment_id, tier}], reply_comments: N,
#                  reply_markers: ["not_connected", ...]}],
#     verdicts:  [{comment_id, created_at, reviewed_sha|null, affirmative}],
#     reactions: [{id, created_at}],             # bot +1 on the PR issue
#     blocks:    [{comment_id, created_at, reason}],
#     summary:   null | {status, commit, observed_at}
#   }
# Prints the ledger JSON. Pure jq; returns jq's status.
crl_ledger() {
  printf '%s\n' "$1" | jq -c '
    def epoch: sub("\\.[0-9]+"; "") | fromdateiso8601;
    def same_head($a; $b):
      ($a | ascii_downcase) as $x | ($b | ascii_downcase) as $y
      | ($x | startswith($y)) or ($y | startswith($x));
    def severity:
      if . == "blocking" then 6
      elif . == "unknown_tier" then 5
      elif . == "discretionary" then 4
      elif . == "no_findings" then 3
      elif . == "clean" then 2
      elif . == "provider_blocked" then 1
      else 0 end;

    . as $in
    | ($in.required_tiers // []) as $required
    | def blocking_tier($t): $t == "p0" or ($required | index($t)) != null;

    # ---- signals ---------------------------------------------------------
    ( [ $in.reviews[]
        | select((.root_findings | length) > 0 or (.body_tiers | length) > 0
                 or (.reply_comments == 0))
        | ([.root_findings[].tier] + .body_tiers) as $tiers
        | { sid: ("review:" + (.id | tostring)), kind: "review", t: .submitted_at,
            anchor: .commit_id,
            class: (if ($tiers | any(. as $t | blocking_tier($t))) then "blocking"
                    elif ($tiers | length) > 0 then "discretionary"
                    else "no_findings" end),
            tiers: $tiers } ]
      + [ $in.verdicts[]
          | { sid: ("verdict:" + (.comment_id | tostring)), kind: "verdict",
              t: .created_at, anchor: .reviewed_sha,
              class: (if .affirmative then "clean" else "unknown_tier" end),
              tiers: [] } ]
      + [ $in.reactions[]
          | { sid: ("reaction:" + (.id | tostring)), kind: "reaction",
              t: .created_at, anchor: null, class: "clean", tiers: [] } ]
      + [ $in.blocks[]
          | { sid: ("block:" + (.comment_id | tostring)), kind: "block",
              t: .created_at, anchor: null, class: "provider_blocked",
              reason: .reason, tiers: [] } ]
      | sort_by(.t, .sid)
    ) as $signals

    | ( $in.requests | sort_by(.created_at, .id) ) as $reqs
    | ( [ $reqs | to_entries[] | .value + {k: (.key + 1)} ] ) as $reqs

    # Window k (1..n) = signals at or after request k and before request k+1;
    # window 0 = signals before the first request.
    | def window_of($t):
        ([ $reqs[] | select(.created_at <= $t) | .k ] | max) // 0;
      ( [ $signals[] | . + {w: window_of(.t)} ] ) as $signals

    # ---- responses: group a window by head anchor -------------------------
    | def group_window($sigs):
        ( [ $sigs[] | select(.anchor != null) ] ) as $anch
        | ( [ $sigs[] | select(.anchor == null) ] ) as $free
        | ( reduce $anch[] as $s ([];
              (map(.anchor) | map(. as $a | same_head($a; $s.anchor)) | index(true)) as $i
              | if $i == null then . + [{anchor: $s.anchor, sigs: [$s]}]
                else .[$i].sigs += [$s]
                     | .[$i].anchor = ([.[$i].anchor, $s.anchor] | max_by(length))
                end) ) as $groups
        | if ($groups | length) == 0 then
            (if ($free | length) == 0 then [] else [{anchor: null, sigs: $free}] end)
          elif ($groups | length) == 1 then
            [ $groups[0] | .sigs += $free ]
          else
            $groups + (if ($free | length) == 0 then [] else [{anchor: null, sigs: $free}] end)
          end;
      ( [ range(0; ($reqs | length) + 1) as $w
          | [ $signals[] | select(.w == $w) ] as $ws
          | group_window($ws) as $g
          | $g | to_entries[]
          | .value as $grp
          | { rid: ("w" + ($w | tostring) + "." + (.key | tostring)),
              window: $w,
              mixed_heads: (($g | length) > 1),
              anchor: $grp.anchor,
              first_at: ([$grp.sigs[].t] | min),
              signals: [$grp.sigs[].sid],
              class: ([$grp.sigs[].class] | max_by(severity)),
              conflicting: (([$grp.sigs[].class] | (index("blocking") != null) and (index("clean") != null))),
              provider_blocked: ([$grp.sigs[] | select(.kind == "block") | .reason] | unique) } ] ) as $responses

    # ---- attribution sweep ------------------------------------------------
    | ( reduce range(1; ($reqs | length) + 1) as $k
          ( {outstanding: [], att: {}, notes: {}};
            .outstanding += [$k]
            | [ $responses[] | select(.window == $k) ] as $rs
            | if ($rs | length) == 0 then .
              elif ($rs | length) == 1 and (.outstanding | length) == 1 then
                .att[($k | tostring)] = {outcome: "attributed", responses: [$rs[0].rid], candidates: [$k]}
                | .outstanding = []
              else
                .outstanding as $cand
                | ( if ($rs | length) > 1 then "multiple responses with different head anchors in one window"
                    else "more than one request outstanding when the response landed" end ) as $why
                | reduce $cand[] as $c (.;
                    .att[($c | tostring)] = {outcome: "ambiguous", responses: [$rs[].rid],
                                            candidates: $cand, reason: $why})
                | .outstanding = []
              end ) ) as $sweep

    | ( $reqs | length ) as $n
    | ( [ $reqs[]
          | .k as $k
          | ($sweep.att[($k | tostring)]) as $a
          | (if $k > 1 then $reqs[$k - 2] else null end) as $prev
          | ( [ $responses[] | select(.window == ($k - 1)) ] | length ) as $prev_window_responses
          | { id, created_at, eyes_now,
              outcome: ( if $a != null then $a.outcome
                         elif $k == $n then "no_response_yet"
                         else "unanswered" end ),
              responses: ($a.responses // []),
              candidates: ( ($a.candidates // []) | map($reqs[. - 1].id) ),
              reason: ($a.reason // null),
              possible_ack_retry_of: (
                if $prev != null and $prev.eyes_now == false and $prev_window_responses == 0
                   and ((.created_at | epoch) - ($prev.created_at | epoch)) <= ($in.retry_window_seconds // 300)
                then $prev.id else null end),
              reposted_while_eyes_present: (
                $k < $n and .eyes_now == true
                and ([ $responses[] | select(.window == $k) ] | length) == 0) } ] ) as $requests

    | ( [ $in.reviews[] | select((.root_findings | length) == 0 and (.body_tiers | length) == 0
                                 and .reply_comments > 0) ] ) as $wrappers
    | {
        pr: $in.pr, repo: $in.repo, head_sha: $in.head_sha,
        author: $in.author, bot: $in.bot, required_tiers: $required,
        requests: $requests,
        responses: [ $responses[] | . + {unsolicited: (.window == 0)} ],
        thread_reply_reviews: [ $wrappers[] | {id, submitted_at, commit_id, reply_markers} ],
        current_summary: $in.summary,
        summary: {
          requests: $n,
          eyes_now: ([ $requests[] | select(.eyes_now == true) ] | length),
          possible_ack_retries: ([ $requests[] | select(.possible_ack_retry_of != null) ] | length),
          reposted_while_eyes_present: ([ $requests[] | select(.reposted_while_eyes_present) ] | length),
          outcomes: ( reduce $requests[] as $r ({attributed: 0, ambiguous: 0, unanswered: 0, no_response_yet: 0};
                        .[$r.outcome] += 1) ),
          responses: ($responses | length),
          unsolicited_responses: ([ $responses[] | select(.window == 0) ] | length),
          responses_by_class: ( reduce $responses[] as $r ({}; .[$r.class] += 1) ),
          blocking_responses: ([ $responses[] | select(.class == "blocking") ] | length),
          blocking_responses_solicited: ([ $responses[] | select(.class == "blocking" and .window > 0) ] | length),
          mixed_head_windows: ([ $responses[] | select(.mixed_heads) | .window ] | unique | length),
          conflicting_responses: ([ $responses[] | select(.conflicting) ] | length),
          thread_reply_reviews: ($wrappers | length)
        }
      }
  '
}
