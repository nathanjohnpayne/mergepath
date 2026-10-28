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
#     commit_id, a verdict's "Reviewed commit"); block notices carry none.
#   - Anyone can request a review. Requests from other accounts, or author
#     comments that are not the exact command, are FOREIGN: they open windows
#     and are attribution candidates, but are not counted as the configured
#     author's requests (the set the request cap counts).
#   - Codex reacts with eyes while a review runs and usually removes the
#     reaction when it finishes, so eyes are current state. The ledger only
#     says eyes came before a re-post when the reaction's own timestamp proves
#     it; otherwise it says unknown.
#   - Pull-request reactions are not review evidence and never enter response
#     attribution. The Review Summary is edited in place, so only its current
#     state is listed in `limits` on every ledger.
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
#                  eyes_at: iso|null, ceiling_exempt: true|false (optional;
#                  a counted CodeRabbit failover request, #2534)}],
#     reviews:   [{id, submitted_at, commit_id|null, body_tiers: [...],
#                  root_findings: [{comment_id, tier, path}], reply_comments: N,
#                  reply_markers: [...]}],
#     rebuttals: [{finding, path, at, sources: [...]}],  # optional (slice 3)
#     verdicts:  [{comment_id, created_at, reviewed_shas: [...], affirmative}],
#     reactions: [{created_at, ...}],             # legacy; timestamps only
#     blocks:    [{comment_id, created_at, reason}],
#     summary:   null | {status, commit, observed_at, ...}
#   }
# Prints the ledger JSON. Invalid named timestamps fail before any output.
# Pure jq; returns jq's status.
crl_ledger() {
  printf '%s\n' "$1" | jq -c '
    def epoch: sub("\\.[0-9]+"; "") | fromdateiso8601;
    def valid_instant:
      type == "string"
      and test("\\A[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\\.[0-9]+)?Z\\z")
      and (try (epoch | type == "number") catch false);
    def same_head($a; $b):
      ($a | ascii_downcase) as $x | ($b | ascii_downcase) as $y
      | ($x | startswith($y)) or ($y | startswith($x));
    # One anchor for a list of shas, or null when they disagree or are absent.
    def consistent_anchor:
      if length == 0 then null
      elif (. as $s | all(.[]; . as $a | $s | all(.[]; same_head($a; .)))) then max_by(length)
      else null end;

    . as $in
    # Validate all temporal inputs before lexical windowing can turn malformed
    # evidence into an unsolicited response or a missed human stop. Reactions
    # remain non-evidence; optional collections keep their existing defaults.
    | if all(( $in.requests[].created_at,
               ($in.requests[].eyes_at | select(. != null)),
               $in.reviews[].submitted_at,
               $in.verdicts[].created_at,
               $in.blocks[].created_at,
               ($in.reactions // [])[].created_at,
               ($in.rebuttals // [])[].at,
               (if $in.summary != null then $in.summary.observed_at else empty end) );
             valid_instant)
      then . else error("invalid ledger timestamp") end
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
              # The blocking inline findings themselves, for the fixed-finding
              # rule a runaway reads (#2534).
              blocking_findings: ([ .root_findings[] | select(blocking_tier(.tier)) | {id: .comment_id, path: (.path // null)} ]),
              blocking_unlocated: ((.body_tiers | any(. as $x | blocking_tier($x)))
                                   or any(.root_findings[]; blocking_tier(.tier) and ((.path | type) != "string"))) } ]
        + [ $in.verdicts[]
            | (.reviewed_shas | consistent_anchor) as $anchor
            | { sid: ("verdict:" + (.comment_id | tostring)), kind: "verdict", t: .created_at,
                anchor: $anchor,
                anchor_conflict: ($anchor == null and (.reviewed_shas | length) > 0),
                affirmative } ]
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
        | ([ $g.sigs[] | select(.kind == "block") ]) as $blk
        | ($ver | any(.affirmative)) as $clean_signal
        | (($ver | any(.affirmative)) and ($ver | any(.affirmative | not))) as $verdicts_disagree
        | if $rev != null then
            { class: $rev.grade,
              conflicting: (($rev.grade == "blocking" and $clean_signal) or $verdicts_disagree) }
          elif ($ver | length) > 0 then
            { class: (if ($ver | all(.affirmative)) then "clean" else "unknown_tier" end),
              conflicting: (($ver | any(.affirmative)) and ($ver | any(.affirmative | not))) }
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
              last_at: ([$grp.sigs[].t] | max),
              blocking_paths: ([ $grp.sigs[] | select(.kind == "review") | .blocking_paths[] ] | unique),
              blocking_findings: ([ $grp.sigs[] | select(.kind == "review") | .blocking_findings[] ] | unique_by(.id)),
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
          | { id, created_at, counted, ceiling_exempt: (.ceiling_exempt == true), source, author, eyes_at,
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
      # Inline findings with a plain fix disposition (#2534); the CLI adds
      # head_changes once the response heads are known.
      fixes: ($in.fixes // [] | unique),
      current_summary: $in.summary,
      limits: [
        "a request comment names no commit; request heads are never inferred",
        "eyes are current state: Codex removes them when a review finishes",
        "pull-request reactions are not response or attribution evidence",
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

# A blocking response whose every blocking finding was FIXED does not count as
# a runaway window (#2534): finding a real defect in each round and fixing it
# is the review working, not a loop. A finding is fixed only when all three
# hold, so no single act by the author can claim it:
#   disposition  it is in .fixes: a non-bot thumbs-up on its root
#                (codex-record-feedback.sh's fixed verdict), no thumbs-down, no
#                [mergepath-resolve: <class>] tag in its thread other than the
#                fix class addressed-elsewhere, not rebutted;
#   a commit     a later head that descends from the reviewed one changed the
#                finding's file (.head_changes: the compare of the two heads,
#                status "ahead", lists the path);
#   a re-read    Codex reviewed that later head, in a graded response the
#                ledger attributes to a counted request posted after this one,
#                and no later Codex response has a blocking finding on the same
#                path or one it cannot locate.
# A response with an unlocated, unknown-tier or conflicting blocking finding is
# never fixed. Missing fixes or head_changes read as nothing fixed. The rule
# never touches the blocking-review budget.
__CRL_FIXED_DEF='def crl_same_head($a; $b):
    ($a | ascii_downcase) as $x | ($b | ascii_downcase) as $y
    | ($x | startswith($y)) or ($y | startswith($x));
  # Whole seconds, so a fractional timestamp cannot sort a same-second
  # request after the response it preceded; unreadable is null.
  def crl_second: try (sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601) catch null;
  def crl_fixed_rids:
    . as $l
    | ($l.fixes // []) as $fixes
    | ($l.head_changes // []) as $changes
    | [ ($l.rebuttals // [])[] | .finding ] as $rebutted
    | $l.responses as $rs
    | $l.requests as $reqs
    | [ $rs[] | . as $r
        | select($r.class == "blocking" and ($r.conflicting | not) and ($r.blocking_unlocated | not)
                 and ($r.anchor | type) == "string" and (($r.blocking_findings // []) | length) > 0)
        | (($r.last_at // $r.first_at) | crl_second) as $done
        | select($done != null)
        | ([ $reqs[] | select(.counted == true and .outcome == "attributed"
                              and ((.created_at | crl_second) as $t | $t != null and $t > $done)) | .responses[] ]) as $proven
        | ([ $rs[] | select(.window > $r.window and (.rid as $id | $proven | index($id)) != null
                            and (.anchor | type) == "string" and (crl_same_head(.anchor; $r.anchor) | not)
                            and (.conflicting | not)
                            and (.class as $c | ["blocking", "discretionary", "no_findings", "clean"] | index($c)) != null) ]) as $looks
        | ([ $rs[] | select(.window > $r.window and (.class == "blocking" or .class == "unknown_tier" or .conflicting)) ]) as $later
        | select(all($r.blocking_findings[]; . as $f
            | ($f.path | type) == "string"
              and ($fixes | index($f.id)) != null
              and ($rebutted | index($f.id)) == null
              and any($looks[]; . as $p
                    | any($changes[]; .base == $r.anchor and .head == $p.anchor and .status == "ahead"
                                     and ((.files | index($f.path)) != null)))
              and all($later[]; (.blocking_unlocated | not) and ((.blocking_paths | index($f.path)) == null))))
        | $r.rid ];'

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
#   runaway            the request windows with a counted response, other
#                      than a fully fixed one (crl_fixed_rids, #2534), reach
#                      the request ceiling before the budget: every request
#                      the ceiling allowed drew a
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
    --argjson ceiling "${5:-null}" "$__CRL_FIXED_DEF
    if length != 1 then error(\"documents\") else .[0] end
    | if (($__CRL_VALID) and .head_sha == \$head and .author == \$author
        and .max_blocking_reviews == \$max
        and (.rebuttals | type) == \"array\"
        and (.requests | type) == \"array\"
        and all(.requests[]; (.created_at | type) == \"string\" and (.outcome | type) == \"string\"
                             and (.responses | type) == \"array\"
                             # counted decides which windows a runaway counts;
                             # absent or malformed must fail, not read as foreign.
                             and (.counted | type) == \"boolean\"
                             # absent reads as counted (older ledgers); malformed fails.
                             and (.ceiling_exempt == null or (.ceiling_exempt | type) == \"boolean\"))
        and all(.responses[]; (.first_at | type) == \"string\" and (.window | type) == \"number\"
                              and (.blocking_paths | type) == \"array\"
                              and (.blocking_unlocated | type) == \"boolean\"
                              # last_at feeds the runaway marker's floor (#2561): a
                              # non-string sorts below every instant and would drop
                              # the response out of it, so it fails like first_at.
                              # Absent is the older-ledger case and falls back to
                              # first_at; present (null included) must be an instant.
                              and ((has(\"last_at\") | not) or (.last_at | type) == \"string\"))
        and all(.rebuttals[]; (.at | type) == \"string\" and (.finding | type) == \"number\"
                              and ((.path | type) == \"string\" or .path == null))
        # The fixed-finding evidence is optional (older ledgers read as
        # nothing fixed), but present and malformed fails.
        and (.fixes == null or ((.fixes | type) == \"array\" and all(.fixes[]; type == \"number\")))
        and (.head_changes == null or ((.head_changes | type) == \"array\"
             and all(.head_changes[]; (.base | type) == \"string\" and (.head | type) == \"string\"
                                      and (.status | type) == \"string\" and (.files | type) == \"array\")))
        and all(.responses[]; .blocking_findings == null or ((.blocking_findings | type) == \"array\"
             and all(.blocking_findings[]; (.id | type) == \"number\" and ((.path | type) == \"string\" or .path == null))))) | not
    then error(\"ledger\") else . end
    | crl_fixed_rids as \$fixed
    | .responses as \$rs
    | .requests as \$reqs
    | ([ \$rs[] | select($__CRL_COUNTS) ] | length) as \$n
    # Runaway compares the ceiling with REQUEST WINDOWS that drew a counted
    # response, not with responses: a window can hold several (#1584).
    # Only windows opened by COUNTED (configured-author) requests, which is
    # what the ceiling counts; a foreign mention opens a window too (#1584).
    # A failover request is the author's but spends no ceiling (#2534).
    # A fully fixed response is no runaway window (#2534).
    | ([ \$rs[] | select($__CRL_COUNTS) | select(.rid as \$id | \$fixed | index(\$id) | not) | .window
         | select(. > 0 and (\$reqs[. - 1].counted == true) and (\$reqs[. - 1].ceiling_exempt != true)) ]
       | unique | length) as \$nw
    # A runaway needs EVERY counted request to have drawn a blocking review,
    # not just as many windows as the current ceiling: a lowered ceiling or
    # concurrent near-cap callers can leave more requests than it (#1584).
    | ([ \$reqs[] | select(.counted == true and .ceiling_exempt != true) ] | length) as \$nr
    # A fully fixed window leaves the request side too, or one fixed round
    # keeps \$nw below \$nr forever and only blocking-budget can stop the
    # loop (#2746). counted_requests still reports \$nr.
    | ([ \$rs[] | select($__CRL_COUNTS) | .window ] - [ \$rs[] | select($__CRL_COUNTS)
         | select(.rid as \$id | \$fixed | index(\$id) | not) | .window ] | unique) as \$fw
    | ([ \$reqs | to_entries[] | select(.value.counted == true and .value.ceiling_exempt != true)
         | select((.key + 1) as \$w | \$fw | index(\$w) | not) ] | length) as \$nr_open
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
    | .fixed_responses = \$fixed
    | .counted_requests = \$nr
    | .stops = ( [ (if \$n >= \$max then \"blocking-budget\" else empty end),
                   (if \$n < \$max and \$ceiling != null and \$ceiling > 0 and \$nr_open >= \$ceiling and \$nw >= \$nr_open then \"runaway\" else empty end),
                   (if (.disagreements | length) > 0 then \"disagreement\" else empty end),
                   (if (.untested_rebuttals | length) > 0 then \"untested-rebuttal\" else empty end) ] )" 2>/dev/null
}

# ---- Owner tiebreak on a dispute stop (#2511) ---------------------------------
# An untested rebuttal or a disagreement stops Phase 4b at a spent request
# ceiling for the human (crl_human_stops). On an owner-authored PR the owner
# cannot record a decision through GitHub's review state, because GitHub
# rejects a self-approval, so the decision needs its own carrier: one PR
# comment, typed by the owner, with a line per finding it settles:
#
#   TIEBREAK_REBUTTAL_ACCEPTED=<canonical-https-PR-URL>@<full-head-sha>#<finding-id>
#
# <finding-id> is the `finding` of the stop entry: the inline root comment id
# of a rebutted thread, or the review id of a body finding. The marker clears
# only that entry, only on that head, and never `blocking-budget` or `runaway`.
# It approves nothing: the stop's waiver still sends the head to the Phase 4b
# adapter, and every other gate still applies. A marker counts only if its
# comment is by the configured author, was never edited, and is newer than the
# dispute it settles (for a disagreement, newer than every counted response
# too), so a decision cannot be pre-recorded or stretched over a later
# re-raise. Agents cannot write the marker: the comment guard refuses
# well-formed marker text in any agent-authored body. As with the scoped admin
# override, GitHub cannot show the owner (rather than an operator holding the
# owner credential) typed it; the record preserves who posted what and when.
#
# A runaway stop has its own line, with no finding id because it names no
# dispute (#2534):
#
#   TIEBREAK_RUNAWAY_ACCEPTED=<canonical-https-PR-URL>@<full-head-sha>
#
# It follows the same rules and clears only `runaway`, only on that head. It
# must be newer than every request and every response in the ledger, so it
# cannot be recorded before the round that completed the runaway. It never
# clears `blocking-budget`: that budget is the owner's cap on Codex spend, and
# the waiver's next step is another review.

# crl_owner_tiebreaks <issue-comments-json> <author> <pr-url> <head>
# Prints [{kind: "rebuttal", finding, comment_id, at} | {kind: "runaway",
# comment_id, at}] for every well-formed marker; fails on input that is not
# one array of comments.
crl_owner_tiebreaks() {
  printf '%s\n' "$1" | jq -sec --arg author "$2" --arg url "$3" --arg head "$4" '
    if length != 1 or (.[0] | type) != "array" then error("comments") else .[0] end
    | [ .[]
        | select(type == "object" and (.user.login // "") == $author
                 and (.created_at | type) == "string"
                 # An edited comment could have been rewritten after the fact.
                 and .updated_at == .created_at
                 and (.body | type) == "string")
        | . as $c
        | ($c.body | split("\n")[]
           | rtrimstr("\r")
           | (capture("^[ \\t]*TIEBREAK_REBUTTAL_ACCEPTED=(?<url>[^@#\\s]+)@(?<head>[0-9a-f]{40})#(?<finding>[0-9]+)[ \\t]*$")
              | select((.url | ascii_downcase) == ($url | ascii_downcase) and .head == $head)
              | {kind: "rebuttal", finding: (.finding | tonumber), comment_id: $c.id, at: $c.created_at}),
             (capture("^[ \\t]*TIEBREAK_RUNAWAY_ACCEPTED=(?<url>[^@#\\s]+)@(?<head>[0-9a-f]{40})[ \\t]*$")
              | select((.url | ascii_downcase) == ($url | ascii_downcase) and .head == $head)
              | {kind: "runaway", comment_id: $c.id, at: $c.created_at})) ]' 2>/dev/null
}

# crl_apply_owner_tiebreaks <stops-json> <ledger-json> <tiebreaks-json>
# Drops each untested-rebuttal / disagreement entry that a newer owner marker
# settles, and the runaway stop when a newer runaway marker settles it,
# recomputes `stops`, and records what it applied in `owner_tiebreaks`. The
# input is crl_human_stops' output for the same ledger.
crl_apply_owner_tiebreaks() {
  jq -nec --argjson stops "$1" --argjson ledger "$2" --argjson tb "$3" '
    def settled($e; $floor):
      any($tb[]; .kind == "rebuttal" and (.finding | tostring) == ($e.finding | tostring) and .at > $floor);
    def latest_response($e):
      ([ $ledger.responses[] | select(.rid as $id | ($e.responses // []) | index($id)) | (.last_at // .first_at) ] | max) // "";
    # Instants compare as whole seconds, never as text (#2561): ISO strings
    # collate "...00Z" after "...00.5Z", and any non-instant string sorts
    # above every real one, so a lexicographic test let a same-second,
    # fractional or malformed timestamp release the stop. GitHub comment
    # timestamps carry no fraction, so "strictly later second" is the finest
    # order the evidence supports; a malformed instant on either side holds.
    # Absolute anchors, as crl_ledger validates: in this regex dialect `$`
    # also matches before one trailing newline, and fromdateiso8601 then
    # converts "…Z\n" as if it were an instant (Codex on #2567).
    def seconds:
      if type == "string" and test("\\A[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\\.[0-9]+)?Z\\z")
      then try (sub("\\.[0-9]+"; "") | fromdateiso8601) catch null
      else null end;
    # The runaway formed with the latest request or response, so the marker
    # must postdate every one of them. Every candidate is converted before
    # the maximum is taken: a textual max would discard a malformed candidate
    # that sorts below a valid one, so one bad instant anywhere makes the
    # floor null, and a null floor holds.
    ([ ($ledger.responses[] | (.last_at // .first_at)), ($ledger.requests[] | .created_at) ]
     | map(seconds)
     | if length == 0 or any(.[]; type != "number") then null else max end) as $runaway_floor
    | (($stops.stops | index("runaway")) != null
       and ($runaway_floor | type) == "number"
       and any($tb[]; .kind == "runaway" and ((.at | seconds) as $a | ($a | type) == "number" and $a > $runaway_floor))) as $runaway
    | ($stops.untested_rebuttals | map(. as $e | select(settled($e; $e.at) | not))) as $untested
    | ($stops.disagreements | map(. as $e
        | select(settled($e; ([$e.at, latest_response($e)] | max)) | not))) as $disagreements
    | ($stops.untested_rebuttals | map(. as $e | select(settled($e; $e.at))
         | {kind: "untested", finding: $e.finding})) as $a
    | ($stops.disagreements | map(. as $e | select(settled($e; ([$e.at, latest_response($e)] | max)))
         | {kind: "disagreement", finding: $e.finding})) as $b
    | $stops
    | .untested_rebuttals = $untested
    | .disagreements = $disagreements
    | .owner_tiebreaks = ($a + $b + (if $runaway then [{kind: "runaway"}] else [] end))
    | .stops = [ .stops[] | select((. == "untested-rebuttal" and ($untested | length) == 0) | not)
                          | select((. == "disagreement" and ($disagreements | length) == 0) | not)
                          | select((. == "runaway" and $runaway) | not) ]' 2>/dev/null
}

# crl_resolved_human_stops <ledger-json> <head> <author> <max-blocking-reviews>
#                          <request-ceiling> <pr-url> [comments-reader [args...]]
#
# The one consumer-facing stop calculation (#2558): crl_human_stops with the
# owner's tiebreak markers applied. The Phase 4b barrier (p4b_codex_human_stops)
# and Cockpit's PR read both call it, so the two cannot disagree about whether
# an owner tiebreak released a stop. Prints crl_human_stops' output for the
# ledger, head, author, budget and ceiling. When a dispute stop (an untested
# rebuttal or a disagreement, #2511) or a runaway stop (#2534) holds, it runs
# the reader to obtain the PR's issue comments as one JSON array, parses the
# markers with crl_owner_tiebreaks against <pr-url> and <head>, and applies them
# with crl_apply_owner_tiebreaks, so the output carries `owner_tiebreaks` (empty
# when no marker settled anything). A reader that fails or prints anything but
# one array, or no reader at all, leaves the stops as crl_human_stops computed
# them, without `owner_tiebreaks`: missing evidence never reads as a decision.
# With no such stop the reader never runs, so a PR with nothing to release costs
# no read; `blocking-budget` alone is not releasable. Returns nonzero, printing
# nothing, when crl_human_stops does.
crl_resolved_human_stops() {
  local ledger="$1" head="$2" author="$3" max="$4" ceiling="$5" url="$6"
  local stops comments marks applied
  shift 6
  stops=$(crl_human_stops "$ledger" "$head" "$author" "$max" "$ceiling") || return 1
  if [ $# -gt 0 ] && printf '%s' "$stops" | jq -e '(.untested_rebuttals | length) + (.disagreements | length) > 0
       or (.stops | index("runaway")) != null' >/dev/null 2>&1; then
    if comments=$("$@" 2>/dev/null) \
       && marks=$(crl_owner_tiebreaks "$comments" "$author" "$url" "$head") \
       && applied=$(crl_apply_owner_tiebreaks "$stops" "$(printf '%s' "$ledger" | jq -sc '.[0]')" "$marks"); then
      stops="$applied"
    fi
  fi
  printf '%s\n' "$stops"
}
