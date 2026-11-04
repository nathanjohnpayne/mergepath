#!/usr/bin/env bash
# tests/test_phase_4b_round_cap.sh — the Phase 4b round cap (#2663).
#
# Two layers. Pure: the production counting, ledger and reconciliation
# helpers in scripts/phase-4b/lib.sh. Protocol: the production round-cap block
# extracted from scripts/phase-4b-review.sh (between `# BEGIN p4b_round_cap`
# and `# END p4b_round_cap`), run against a stateful fake GitHub whose ref
# compare-and-swap is atomic under a mkdir lock and which can be adversarial:
# stale ref reads, a ref update that commits after the client times out, a
# dropped update, a competitor that wins between this run's read and write,
# reviews that only become visible after N reads, and read failures. Real
# concurrent callers share one fake to show the cap holds under contention.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/p4b-round-cap.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
PASS=0; FAIL=0
pass() { echo "PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $*" >&2; FAIL=$((FAIL + 1)); }
HEAD_A=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
HEAD_B=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb

# shellcheck source=../scripts/phase-4b/lib.sh
. "$ROOT/scripts/phase-4b/lib.sh"
# shellcheck source=../scripts/lib/p4b-review-provenance.sh
. "$ROOT/scripts/lib/p4b-review-provenance.sh"

# --- review fixtures -----------------------------------------------------------
review() { # <id> <login> <state> <head> [run] [heading:yes|no] [footer:yes|no]
  local body="" run="${5:-}"
  [ "${6:-yes}" = no ] || body="**Automated Phase 4b review** (claude->codex, reviewer $2)"$'\n'
  body+="### Review Metadata"$'\n'
  [ -z "$run" ] || body+=$'\n'"<!-- mergepath-p4b-run: $run -->"$'\n'
  [ "${7:-yes}" = no ] || body+=$'\n\n'"_Posted by scripts/phase-4b-review.sh under the reviewer identity._"
  jq -nc --argjson id "$1" --arg login "$2" --arg state "$3" --arg head "$4" --arg body "$body" \
    '{id:$id,user:{login:$login},state:$state,commit_id:$head,body:$body}'
}
arr() { jq -sc . ; }

# ===========================================================================
# Pure: completed rounds
# ===========================================================================
reviews=$( { review 1 nathanpayne-codex APPROVED "$HEAD_A" r1
             review 2 nathanpayne-retired CHANGES_REQUESTED "$HEAD_A"      # rotated-out reviewer, legacy (no run)
             review 3 nathanpayne-codex DISMISSED "$HEAD_A" r3
             review 4 nathanjohnpayne APPROVED "$HEAD_A" r4                 # PR author: never a round
             review 5 nathanpayne-codex COMMENTED "$HEAD_A" r5              # no verdict
             review 6 nathanpayne-codex APPROVED "$HEAD_A" r6 no            # no heading
             review 7 nathanpayne-codex APPROVED "$HEAD_A" r7 yes no        # no footer
             review 1 nathanpayne-codex APPROVED "$HEAD_A" r1               # duplicate id
           } | arr)
out=$(p4b_completed_rounds_from_reviews "$reviews" nathanjohnpayne)
if [ "$(jq -c '[.completed, [.rounds[].id], [.rounds[].run]]' <<<"$out")" = '[3,[1,2,3],["r1",null,"r3"]]' ]; then
  pass "rounds: verdict-bearing automated reviews count across logins (rotation-safe), dismissed included; author, comment-only, unheaded and unfootered do not; duplicates once"
else fail "rounds: $out"; fi
p4b_completed_rounds_from_reviews '{"not":"array"}' x >/dev/null && fail "rounds: a non-array was accepted" || pass "rounds: a non-array review list fails closed"
bad=$(jq -nc --arg b "**Automated Phase 4b review** x"$'\n'"_Posted by scripts/phase-4b-review.sh" '[{user:{login:"nathanpayne-codex"},state:"APPROVED",body:$b}]')
p4b_completed_rounds_from_reviews "$bad" x >/dev/null && fail "rounds: a qualifying review without an id was accepted" || pass "rounds: a qualifying review without an id fails closed"
for junk in '[null]' '[42]' '[{"message":"bad"}]' '[{"id":1,"state":7,"body":""}]' '[{"id":1,"state":"APPROVED","body":{}}]'; do
  p4b_completed_rounds_from_reviews "$junk" x >/dev/null && fail "rounds: malformed record accepted: $junk" \
    || pass "rounds: a malformed review record fails closed instead of reading as empty history ($junk)"
done
ghost=$(jq -nc --arg b "**Automated Phase 4b review** x"$'\n'"_Posted by scripts/phase-4b-review.sh" '[{id:9,user:null,state:"APPROVED",commit_id:"c",body:$b}]')
[ "$(p4b_completed_rounds_from_reviews "$ghost" nathanjohnpayne | jq -r .completed)" = 1 ] \
  && pass "rounds: a review by a deleted (ghost) user is a well-formed record and still counts" || fail "rounds: ghost user"

# The run id is the marker before the footer; a marker-shaped example quoted in
# the review text (as a finding about this ledger would) is not it.
quoted=$(jq -nc --arg b "**Automated Phase 4b review** x"$'\n'"Finding: a body quoting <!-- mergepath-p4b-run: sample-run --> is ambiguous."$'\n\n'"<!-- mergepath-p4b-run: real-run -->"$'\n\n\n'"_Posted by scripts/phase-4b-review.sh under the reviewer identity._" \
  '[{id:11,user:{login:"nathanpayne-codex"},state:"APPROVED",commit_id:"'"$HEAD_A"'",body:$b}]')
[ "$(p4b_completed_rounds_from_reviews "$quoted" nathanjohnpayne | jq -c '[.rounds[].run]')" = '["real-run"]' ] \
  && pass "rounds: a quoted marker-shaped example never displaces the run marker before the footer" || fail "rounds: quoted marker $(p4b_completed_rounds_from_reviews "$quoted" nathanjohnpayne)"
[ "$(p4b_reconcile_posted_review "$quoted" nathanpayne-codex "$HEAD_A" real-run | jq -r '.id // empty')" = 11 ] \
  && [ -z "$(p4b_reconcile_posted_review "$quoted" nathanpayne-codex "$HEAD_A" sample-run)" ] \
  && pass "reconcile: only the marker before the footer identifies the run; a quoted id is never adopted" || fail "reconcile: quoted marker"

# ===========================================================================
# Pure: governing cap
# ===========================================================================
for c in '{}:none' '{"phase_4b_automation":{}}:none' '{"phase_4b_automation":{"max_review_rounds":3}}:3'; do
  got=$(p4b_governing_round_cap "${c%:*}") && [ "$got" = "${c##*:}" ] && pass "cap: ${c%:*} -> ${c##*:}" || fail "cap: ${c%:*} gave '${got:-}'"
done
for c in 0 -1 2.5 '"3"' null true; do
  p4b_governing_round_cap "{\"phase_4b_automation\":{\"max_review_rounds\":$c}}" >/dev/null \
    && fail "cap: $c was accepted" || pass "cap: $c is refused (exit 10 at the orchestrator)"
done
# #2746: a present block that is not a mapping is malformed policy, not "no cap".
for c in '3' '"x"' '[]' 'true'; do
  p4b_governing_round_cap "{\"phase_4b_automation\":$c}" >/dev/null \
    && fail "cap: a non-object phase_4b_automation ($c) read as no cap" || pass "cap: a non-object phase_4b_automation ($c) is refused"
done
got=$(p4b_governing_round_cap '{"phase_4b_automation":null}') && [ "$got" = none ] \
  && pass "cap: a null phase_4b_automation block is absent -> none" || fail "cap: null block gave '${got:-}'"

# ===========================================================================
# Pure: ledger parse/message and occupancy
# ===========================================================================
m=$(p4b_round_ledger_message 7 '[{"run":"r1","head":"'"$HEAD_A"'","state":"reserved"}]')
[ "$(p4b_round_ledger_parse "$m")" = '[{"run":"r1","head":"'"$HEAD_A"'","state":"reserved"}]' ] \
  && pass "ledger: message and parse round-trip" || fail "ledger: round-trip"
for badm in "no ledger here" $'x\n{"schema":"p4b-round-ledger/v1","pr":7,"entries":[{"run":"r","state":"maybe"}]}' \
            $'{"schema":"p4b-round-ledger/v1","pr":7,"entries":[]}\n{"schema":"p4b-round-ledger/v1","pr":7,"entries":[]}' \
            $'{"schema":"p4b-round-ledger/v1","pr":7,"entries":[{"run":"bad id","state":"reserved"}]}'; do
  p4b_round_ledger_parse "$badm" >/dev/null && fail "ledger: malformed accepted: ${badm:0:40}" || pass "ledger: malformed ledger refused (${badm:0:24}…)"
done
occ() { p4b_round_occupancy "$1" "$2" 3 | jq -c '[.occupied,.in_flight,.legacy]'; }
E='[{"run":"a","state":"reserved"},{"run":"b","state":"released"},{"run":"c","state":"reserved"}]'
R='{"rounds":[{"id":1,"run":null},{"id":2,"run":"a"}]}'
[ "$(occ "$E" "$R")" = '[3,1,1]' ] && pass "occupancy: reserved (consumed or in flight) + legacy rounds; a writer release frees its slot" || fail "occupancy: $(occ "$E" "$R")"
# Completion between reads: the review for c is not visible yet -> c still occupies as in flight.
[ "$(occ '[{"run":"c","state":"reserved"}]' '{"rounds":[]}')" = '[1,1,0]' ] \
  && [ "$(occ '[{"run":"c","state":"reserved"}]' '{"rounds":[{"id":9,"run":"c"}]}')" = '[1,0,0]' ] \
  && pass "occupancy: a slot moves from in-flight to completed without ever leaving the count" || fail "occupancy: completion between reads"
# A released writer that published anyway is still counted (legacy), never lost.
[ "$(occ '[{"run":"b","state":"released"}]' '{"rounds":[{"id":5,"run":"b"}]}')" = '[0,0,0]' ] \
  && fail "occupancy: a released run's review dropped from the count" || pass "occupancy: a review by a run whose entry reads released is still counted"
# Duplicate run entries each occupy.
[ "$(occ '[{"run":"d","state":"reserved"},{"run":"d","state":"reserved"}]' '{"rounds":[]}')" = '[2,2,0]' ] \
  && pass "occupancy: duplicate run entries each keep a slot occupied" || fail "occupancy: duplicates"
# Several reviews carrying one reserved run id each count; one reservation never absorbs them.
[ "$(occ '[{"run":"a","state":"reserved"}]' '{"rounds":[{"id":1,"run":"a"},{"id":2,"run":"a"}]}')" = '[2,0,0]' ] \
  && [ "$(occ '[{"run":"a","state":"reserved"}]' '{"rounds":[{"id":1,"run":"a"},{"id":2,"run":"a"},{"id":3,"run":null}]}')" = '[3,0,1]' ] \
  && pass "occupancy: surplus reviews carrying one reserved run id each occupy a slot" || fail "occupancy: surplus $(occ '[{"run":"a","state":"reserved"}]' '{"rounds":[{"id":1,"run":"a"},{"id":2,"run":"a"}]}')"

# ===========================================================================
# Pure: reconciliation of an uncertain POST
# ===========================================================================
mine=$(review 41 nathanpayne-codex APPROVED "$HEAD_A" run-me)
twin=$(review 42 nathanpayne-codex APPROVED "$HEAD_A" run-other)     # identical body apart from the nonce
foreign=$(review 43 nathanpayne-claude APPROVED "$HEAD_A" run-me)
stale=$(review 44 nathanpayne-codex APPROVED "$HEAD_B" run-me)
recon() { p4b_reconcile_posted_review "$1" nathanpayne-codex "$HEAD_A" run-me | jq -r '.id // empty'; }
[ "$(recon "[$mine,$twin]")" = 41 ] && pass "reconcile: adopts exactly this run's review by its nonce, never an identical twin" || fail "reconcile: unique"
[ -z "$(recon "[$twin,$foreign,$stale]")" ] && pass "reconcile: another caller's twin, another reviewer, or another head is never adopted" || fail "reconcile: foreign"
[ -z "$(recon "[$mine,$(review 45 nathanpayne-codex APPROVED "$HEAD_A" run-me)]")" ] && pass "reconcile: two reviews carrying this nonce are ambiguous; nothing is adopted" || fail "reconcile: ambiguous"
[ -z "$(recon '[]')" ] && pass "reconcile: a POST not yet visible adopts nothing (the slot stays occupied)" || fail "reconcile: invisible"

# ===========================================================================
# Protocol: the production round-cap block against a stateful fake GitHub
# ===========================================================================
BLOCK="$WORK/round-cap-block.sh"
awk '/^# BEGIN p4b_round_cap$/{f=1;next} /^# END p4b_round_cap$/{f=0} f' "$ROOT/scripts/phase-4b-review.sh" >"$BLOCK"
grep -q '^enforce_phase4b_round_cap()' "$BLOCK" || { echo "FAIL: could not extract the production round-cap block" >&2; exit 1; }
# The production exit-8 helper too, so the spent stop's real output shape is tested.
TIEBREAK="$WORK/tiebreak.sh"
awk '/^stop_for_human_tiebreaker\(\) \{$/{f=1} f{print} f && /^}$/{exit}' "$ROOT/scripts/phase-4b-review.sh" >"$TIEBREAK"
grep -q '^stop_for_human_tiebreaker()' "$TIEBREAK" || { echo "FAIL: could not extract stop_for_human_tiebreaker" >&2; exit 1; }
# And the production #2633 override-fields helper every terminal summary uses.
OVERRIDE_SUMMARY="$WORK/override-summary.sh"
awk '/^admin_override_summary\(\) \{$/{f=1} f{print} f && /^}$/{exit}' "$ROOT/scripts/phase-4b-review.sh" >"$OVERRIDE_SUMMARY"
grep -q '^admin_override_summary()' "$OVERRIDE_SUMMARY" || { echo "FAIL: could not extract admin_override_summary" >&2; exit 1; }

# Test the real publication boundary against the same atomic ledger fake.
POST_REVIEW="$WORK/post-review.sh"
awk '/^post_review\(\) \{$/{f=1} f{print} f && /^}$/{exit}' "${P4B_TEST_ROUND_POST_ORCH:-$ROOT/scripts/phase-4b-review.sh}" >"$POST_REVIEW"
grep -q '^post_review()' "$POST_REVIEW" || { echo 'FAIL: missing production post_review' >&2; exit 1; }

FAKE_BIN="$WORK/bin"; mkdir -p "$FAKE_BIN"
cat >"$FAKE_BIN/gh" <<'GH'
#!/usr/bin/env bash
# Stateful fake GitHub: git refs/commits/trees and PR reviews for owner/repo#7.
set -uo pipefail
S=${FAKE_GH_STATE:?}
[ "${1:-}" = api ] || { echo "unsupported: $*" >&2; exit 99; }
shift; endpoint=""; method=GET; input=""
while [ $# -gt 0 ]; do
  case "$1" in
    --method) method=$2; shift 2 ;;
    --input) input=$2; shift 2 ;;
    --paginate) shift ;;
    -*) shift ;;
    *) endpoint=$1; shift ;;
  esac
done
lock() { until mkdir "$S/.lock" 2>/dev/null; do sleep 0.01; done; }
unlock() { rmdir "$S/.lock"; }
bump() { local n; n=$(cat "$S/$1" 2>/dev/null || echo 0); echo $((n + 1)) >"$S/$1"; echo $((n + 1)); }
knob() { cat "$S/knob.$1" 2>/dev/null || echo 0; }
take() { local n; n=$(knob "$1"); [ "$n" -gt 0 ] || return 1; echo $((n - 1)) >"$S/knob.$1"; }
compete() { # a competitor reserves (or appends) an entry on the true tip
  local tip msg entries new sha
  tip=$(cat "$S/tip" 2>/dev/null || true)
  if [ -n "$tip" ]; then msg=$(cat "$S/commits/$tip"); entries=$(printf '%s\n' "$msg" | grep -F '{"schema"' | jq -c .entries); else entries='[]'; fi
  new=$(jq -nc --argjson e "$entries" --arg run "competitor-$(bump competitors)" '$e + [{run:$run,head:"cccccccccccccccccccccccccccccccccccccccc",state:"reserved"}]')
  msg=$(printf 'competitor\n\n%s\n' "$(jq -nc --argjson e "$new" '{schema:"p4b-round-ledger/v1",pr:7,entries:$e}')")
  sha=$(printf '%s|%s' "$tip" "$msg" | shasum | cut -c1-40)
  mkdir -p "$S/commits"; printf '%s' "$msg" >"$S/commits/$sha"; printf '%s' "$tip" >"$S/parents.$sha"
  printf '%s' "$sha" >"$S/tip"
}
case "$method:$endpoint" in
  GET:repos/owner/repo/git/ref/mergepath/p4b-rounds/pr-7)
    [ "$(knob ref_fail)" = 0 ] || { echo "HTTP 500" >&2; exit 1; }
    lock
    n=$(bump ref_reads)
    [ "$(knob compete_on_ref_read)" != "$n" ] || compete
    tip=$(cat "$S/tip" 2>/dev/null || true)
    if take stale_ref_reads; then tip=$(cat "$S/prev_tip" 2>/dev/null || true); fi
    unlock
    [ -n "$tip" ] || { echo "gh: Not Found (HTTP 404)" >&2; exit 1; }
    printf '{"ref":"refs/mergepath/p4b-rounds/pr-7","object":{"sha":"%s","type":"commit"}}\n' "$tip" ;;
  GET:repos/owner/repo/git/commits/*)
    sha=${endpoint##*/}; [ -f "$S/commits/$sha" ] || { echo "HTTP 404" >&2; exit 1; }
    jq -nc --rawfile m "$S/commits/$sha" --arg sha "$sha" '{sha:$sha,message:$m}' ;;
  POST:repos/owner/repo/git/trees)
    # Like GitHub: an empty tree is HTTP 422 "Invalid tree info".
    jq -e '(.tree | type) == "array" and (.tree | length) > 0
           and all(.tree[]; (.path | type) == "string" and .mode == "100644" and .type == "blob"
                            and (.content | type) == "string")' "$input" >/dev/null 2>&1 \
      || { echo "gh: Invalid tree info (HTTP 422)" >&2; exit 1; }
    sha=$(jq -cS . "$input" | shasum | cut -c1-40); mkdir -p "$S/trees"; : >"$S/trees/$sha"
    printf '{"sha":"%s"}\n' "$sha" ;;
  POST:repos/owner/repo/git/commits)
    tree=$(jq -r '.tree // ""' "$input")
    [ -n "$tree" ] && [ -f "$S/trees/$tree" ] || { echo "gh: Tree SHA does not exist (HTTP 422)" >&2; exit 1; }
    msg=$(jq -r .message "$input"); parent=$(jq -r '.parents[0] // ""' "$input")
    sha=$(printf '%s|%s' "$parent" "$msg" | shasum | cut -c1-40)
    mkdir -p "$S/commits"; printf '%s' "$msg" >"$S/commits/$sha"; printf '%s' "$parent" >"$S/parents.$sha"
    printf '{"sha":"%s"}\n' "$sha" ;;
  POST:repos/owner/repo/git/refs|PATCH:repos/owner/repo/git/refs/mergepath/p4b-rounds/pr-7)
    sha=$(jq -r .sha "$input")
    if take drop_ref_writes; then echo "timeout: no response" >&2; exit 1; fi
    lock
    cur=$(cat "$S/tip" 2>/dev/null || true)
    if [ "$method" = POST ] && [ -n "$cur" ]; then unlock; echo "gh: Reference already exists (HTTP 422)" >&2; exit 1; fi
    # Like GitHub: force:true overwrites regardless of ancestry; otherwise the
    # update must be a fast-forward from the current tip.
    force=$(jq -r '.force // false' "$input")
    if [ "$method" = PATCH ] && [ "$force" != true ] && [ "$(cat "$S/parents.$sha" 2>/dev/null)" != "$cur" ]; then unlock; echo "gh: Update is not a fast forward (HTTP 422)" >&2; exit 1; fi
    printf '%s' "$cur" >"$S/prev_tip"; printf '%s' "$sha" >"$S/tip"; bump ref_writes >/dev/null
    unlock
    # The write committed; the client may still see a timeout.
    if take lost_ref_writes; then echo "timeout: response lost" >&2; exit 1; fi
    printf '{"ref":"refs/mergepath/p4b-rounds/pr-7","object":{"sha":"%s"}}\n' "$sha" ;;
  POST:repos/owner/repo/pulls/7/reviews)
    bump review_posts >/dev/null
    [ "$(knob review_unknown)" = 0 ] || { echo 'fixture unknown review outcome' >&2; exit 42; }
    response=$(jq --arg login nathanpayne-codex --arg at "${FAKE_SUBMITTED_AT:-2026-11-03T23:00:00Z}" \
      '. + {id:99,user:{login:$login},state:"CHANGES_REQUESTED",submitted_at:$at}' "$input")
    jq --argjson r "$response" '. + [$r]' "$S/reviews.json" >"$S/reviews.next"
    mv "$S/reviews.next" "$S/reviews.json"
    [ "$(knob review_lost_response)" = 0 ] || { echo 'fixture lost review response' >&2; exit 42; }
    printf '%s\n' "$response" ;;
  GET:repos/owner/repo/issues/7/comments)
    [ "$(knob comments_fail)" = 0 ] || { echo "HTTP 500" >&2; exit 1; }
    cat "$S/comments.json" 2>/dev/null || echo '[]' ;;
  GET:repos/owner/repo/pulls/7/reviews)
    n=$(bump review_reads)
    if [ -f "$S/reviews_late.json" ] && [ "$n" -gt "$(knob reviews_late_after)" ]; then
      jq -sc 'add' "$S/reviews.json" "$S/reviews_late.json"
    else cat "$S/reviews.json"; fi ;;
  *) echo "unexpected fake gh: $method $endpoint" >&2; exit 99 ;;
esac
GH
chmod +x "$FAKE_BIN/gh"
cat >"$FAKE_BIN/as-reviewer" <<'W'
#!/usr/bin/env bash
while [ $# -gt 0 ] && [ "$1" != -- ]; do shift; done; shift
# Preserve the production wrapper's strict local refusal on the review write;
# ledger writes remain the same atomic fake transport used by this suite.
if [[ "$*" == *repos/owner/repo/pulls/7/reviews* ]] && [[ "$*" == *POST* ]]; then
  python3 "$P4B_ROUND_TEST_GUARD" --role reviewer -- "$@" >/dev/null || exit 1
fi
exec "$@"
W
chmod +x "$FAKE_BIN/as-reviewer"

cat >"$WORK/harness.sh" <<'H'
#!/usr/bin/env bash
# Runs the production block. Args: <run-id> <steps...>; steps: reserve, prepost, attempt, release.
set -euo pipefail
. "$ROOT/scripts/phase-4b/lib.sh"
. "$ROOT/scripts/lib/p4b-review-provenance.sh"
export P4B_ROUND_TEST_GUARD="$ROOT/scripts/workflow/gh-comment-trigger-guard.py"
P4B_OWNER_AUTH_ID=${H_AUTH:-}
PR=7 REPO=owner/repo HEAD=${H_HEAD:-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa} DIRECTION=claude-\>codex
REVIEWER=nathanpayne-codex ADAPTER=codex ENABLED_VIA=config GH_AS_REVIEWER="$FAKE_BIN/as-reviewer"
P4B_ACCT_RUN_ID=$1; shift
p4b_warn() { echo "[warn] $*" >&2; }
p4b_governing_policy_json() { cat "$FAKE_GH_STATE/policy.json"; }
gh_api_array() { gh api --paginate "$1"; }
cleanup_pre_post_refusal_side_effects() { echo "[cleanup] $1" >&2; }
p4b_unposted_verdict_summary() { printf '{}\n'; }
ADMIN_OVERRIDE_SET=${H_ADMIN_SET:-false} ADMIN_OVERRIDE_QUOTE=${H_ADMIN_QUOTE:-} ADMIN_OVERRIDDEN=${H_ADMIN_OVERRIDDEN:-[]}
. "$H_OVERRIDE_SUMMARY"
. "$H_TIEBREAK"
. "$H_BLOCK"
. "$H_POST"
revalidate_codex_request_budget_authority() { :; }
revalidate_phase4a_timeout_generation() { :; }
gh_api_scalar() { printf '%s\n' "$HEAD"; }
revalidate_pr_body_author() { :; }
revalidate_expected_base() { :; }
revalidate_immutable_input() { :; }
p4b_acct_mark_unposted() { :; }
for step in "$@"; do
  case "$step" in
    reserve) enforce_phase4b_round_cap pre-dispatch ;;
    prepost) enforce_phase4b_round_cap pre-post ;;
    publish)
      # #2968: the production header line, owner-authorization metadata line
      # and provenance trailer, through the production post_review.
      BODY_FILE="$FAKE_GH_STATE/body.$P4B_ACCT_RUN_ID"
      { printf '**Automated Phase 4b review** (%s, reviewer %s)\n\nok\n\n### Review Metadata\n\n' "$DIRECTION" "$REVIEWER"
        round_owner_authorization_line; round_provenance_trailer; } >"$BODY_FILE"
      ROOT="$ROOT/scripts"
      publish_rc=0
      post_review --request-changes || publish_rc=$?
      exit "$publish_rc" ;;
    publish-refused|publish-unknown|publish-lost-response)
      BODY_FILE="$FAKE_GH_STATE/body.$P4B_ACCT_RUN_ID"
      if [ "$step" = publish-refused ]; then
        printf 'TIEBREAK_RUNAWAY_ACCEPTED=https://github.com/owner/repo/pull/7@%s' "$HEAD" >"$BODY_FILE"
      else
        printf '**Automated Phase 4b review**\n\n<!-- mergepath-p4b-run: %s -->\n\n_Posted by scripts/phase-4b-review.sh under the reviewer identity._\n' "$P4B_ACCT_RUN_ID" >"$BODY_FILE"
        if [ "$step" = publish-unknown ]; then echo 1 >"$FAKE_GH_STATE/knob.review_unknown"
        else echo 1 >"$FAKE_GH_STATE/knob.review_lost_response"; fi
      fi
      # post_review's ROOT is the scripts directory; the harness uses the
      # repo root elsewhere. Preserve its attempted flag in this same shell.
      ROOT="$ROOT/scripts"
      publish_rc=0
      post_review --request-changes || publish_rc=$?
      release_round_reservation publication-exit
      exit "$publish_rc" ;;
    attempt) P4B_ROUND_POST_ATTEMPTED=true ;;
    release) release_round_reservation test ;;
    hook) bash "$H_HOOK" ;;
  esac
done
jq -nc --argjson rc "$P4B_ROUND_CAP_JSON" --arg reserved "$P4B_ROUND_RESERVED" '{exit:0,reserved:$reserved,round_cap:$rc}'
H
chmod +x "$WORK/harness.sh"

fresh() { # <name> <cap-or-none> -> sets S
  S="$WORK/state-$1"; rm -rf "$S"; mkdir -p "$S/commits"
  printf '[]' >"$S/reviews.json"
  if [ "$2" = none ]; then printf '{"author_identity":"nathanjohnpayne"}' >"$S/policy.json"
  else printf '{"author_identity":"nathanjohnpayne","phase_4b_automation":{"max_review_rounds":%s}}' "$2" >"$S/policy.json"; fi
}
run() { # <run-id> <steps...> -> the last JSON document in OUT; RC set
  RC=0
  OUT=$(PATH="$FAKE_BIN:$PATH" FAKE_GH_STATE="$S" FAKE_BIN="$FAKE_BIN" ROOT="$ROOT" H_BLOCK="$BLOCK" H_TIEBREAK="$TIEBREAK" \
        H_POST="$POST_REVIEW" H_OVERRIDE_SUMMARY="$OVERRIDE_SUMMARY" H_ADMIN_SET="${H_ADMIN_SET:-false}" H_ADMIN_QUOTE="${H_ADMIN_QUOTE:-}" \
        H_ADMIN_OVERRIDDEN="${H_ADMIN_OVERRIDDEN:-[]}" H_AUTH="${H_AUTH:-}" \
        H_HOOK="${H_HOOK:-/dev/null}" TAMPER="${TAMPER:-}" \
        bash "$WORK/harness.sh" "$@" 2>"$S/err.$1") || RC=$?
  OUT=$(printf '%s\n' "$OUT" | jq -sc 'last // {}' 2>/dev/null || printf '{}')
}
ledger() { local t; t=$(cat "$S/tip" 2>/dev/null || true); [ -n "$t" ] || { echo '[]'; return; }
           p4b_round_ledger_parse "$(cat "$S/commits/$t")"; }
reserved_runs() { ledger | jq -c '[.[] | select(.state == "reserved") | .run]'; }

# P1: below the cap, the run reserves on a fresh ref (create-if-absent).
fresh p1 3; { review 1 nathanpayne-codex APPROVED "$HEAD_A"; review 2 nathanpayne-codex CHANGES_REQUESTED "$HEAD_A"; } | arr >"$S/reviews.json"
run me reserve
[ "$RC" = 0 ] && [ "$(reserved_runs)" = '["me"]' ] && [ "$(jq -r .round_cap.occupied <<<"$OUT")" = 2 ] \
  && pass "P1: 2/3 legacy rounds -> this run reserves the third slot on a newly created ledger ref" || fail "P1 rc=$RC $OUT $(cat "$S/err.me")"

# P2: at the cap with nothing in flight -> exit 8, no ledger write.
fresh p2 3; { review 1 x APPROVED "$HEAD_A"; review 2 x APPROVED "$HEAD_A"; review 3 x DISMISSED "$HEAD_A"; } | arr >"$S/reviews.json"
run me reserve
[ "$RC" = 8 ] && [ "$(jq -c '[.round_cap.state, .human_tiebreaker_required, .barrier.round_cap.state]' <<<"$OUT")" = '["spent",true,"spent"]' ] && [ ! -f "$S/tip" ] \
  && pass "P2: 3/3 completed -> the fourth round is refused (exit 8 from the production tiebreaker stop, top-level round_cap spent) and nothing is written" || fail "P2 rc=$RC $OUT"

# P3: at the cap with a round in flight -> hold (exit 6), the slot is not reused.
fresh p3 3; { review 1 x APPROVED "$HEAD_A"; review 2 x APPROVED "$HEAD_A"; } | arr >"$S/reviews.json"
run other reserve; run me reserve
[ "$RC" = 6 ] && [ "$(jq -r .round_cap.state <<<"$OUT")" = held ] && [ "$(reserved_runs)" = '["other"]' ] \
  && pass "P3: 2 completed + 1 in flight -> a competing run holds (exit 6) and takes no slot" || fail "P3 rc=$RC $OUT"

# P4: a competitor wins between this run's read and its write -> CAS fails, fresh read, re-evaluate.
fresh p4 3; { review 1 x APPROVED "$HEAD_A"; review 2 x APPROVED "$HEAD_A"; } | arr >"$S/reviews.json"
echo 1 >"$S/knob.compete_on_ref_read"
run me reserve
[ "$RC" = 6 ] && [ "$(reserved_runs)" = '["competitor-1"]' ] \
  && pass "P4: a competitor that reserves the last slot mid-run makes this run's CAS fail; the fresh re-read holds instead of over-reserving" || fail "P4 rc=$RC $OUT $(reserved_runs)"

# P5: a stale ref read (delayed visibility) -> the stale-parent CAS is rejected and re-evaluated.
fresh p5 3; { review 1 x APPROVED "$HEAD_A"; } | arr >"$S/reviews.json"
run a reserve; run b reserve                       # 1 completed + a + b = 3
echo 1 >"$S/knob.stale_ref_reads"                  # the next ref read returns the pre-b tip
run c reserve
[ "$RC" = 6 ] && [ "$(reserved_runs)" = '["a","b"]' ] \
  && pass "P5: a stale ref read builds on an old tip; the non-fast-forward CAS fails and the fresh read refuses the slot" || fail "P5 rc=$RC $OUT $(reserved_runs)"

# P6: a ref write that commits but loses its response is recognised from the tip, once.
fresh p6 3; echo 1 >"$S/knob.lost_ref_writes"
run me reserve
[ "$RC" = 0 ] && [ "$(reserved_runs)" = '["me"]' ] && [ "$(cat "$S/ref_writes")" = 1 ] \
  && pass "P6: a reservation that committed after the client timed out is adopted from the tip; no duplicate entry" || fail "P6 rc=$RC $OUT $(ledger)"

# P7: a dropped write (never applied) is retried after a fresh read.
fresh p7 3; echo 1 >"$S/knob.drop_ref_writes"
run me reserve
[ "$RC" = 0 ] && [ "$(reserved_runs)" = '["me"]' ] \
  && pass "P7: a ref write that never applied is re-read and retried once, not assumed" || fail "P7 rc=$RC $OUT $(ledger)"

# P8: real concurrency — five callers race for one remaining slot; exactly one wins.
fresh p8 3; { review 1 x APPROVED "$HEAD_A"; review 2 x APPROVED "$HEAD_A"; } | arr >"$S/reviews.json"
for i in 1 2 3 4 5; do
  ( PATH="$FAKE_BIN:$PATH" FAKE_GH_STATE="$S" FAKE_BIN="$FAKE_BIN" ROOT="$ROOT" H_BLOCK="$BLOCK" H_TIEBREAK="$TIEBREAK" \
    H_POST="$POST_REVIEW" H_OVERRIDE_SUMMARY="$OVERRIDE_SUMMARY" \
      bash "$WORK/harness.sh" "racer$i" reserve >"$S/out.racer$i" 2>"$S/err.racer$i"; echo $? >"$S/rc.racer$i" ) &
done
wait
won=$(reserved_runs | jq length); zeros=0; sixes=0
for i in 1 2 3 4 5; do case "$(cat "$S/rc.racer$i")" in 0) zeros=$((zeros+1)) ;; 6) sixes=$((sixes+1)) ;; esac; done
[ "$won" = 1 ] && [ "$zeros" = 1 ] && [ "$sixes" = 4 ] \
  && pass "P8: five concurrent callers for the last slot -> exactly one reserves, four hold" || fail "P8 won=$won zeros=$zeros sixes=$sixes"

# P9: ten concurrent callers on an empty PR with cap 3 -> exactly three reserve.
fresh p9 3
for i in $(seq 1 10); do
  ( PATH="$FAKE_BIN:$PATH" FAKE_GH_STATE="$S" FAKE_BIN="$FAKE_BIN" ROOT="$ROOT" H_BLOCK="$BLOCK" H_TIEBREAK="$TIEBREAK" \
    H_POST="$POST_REVIEW" H_OVERRIDE_SUMMARY="$OVERRIDE_SUMMARY" \
      bash "$WORK/harness.sh" "racer$i" reserve >/dev/null 2>"$S/err.racer$i"; echo $? >"$S/rc.racer$i" ) &
done
wait
[ "$(reserved_runs | jq length)" = 3 ] && pass "P9: ten concurrent callers, cap 3 -> exactly three slots reserved" || fail "P9 reserved=$(reserved_runs)"

# P10: the binding pre-POST check refuses a slot that was edited, duplicated or removed.
cat >"$WORK/tamper.sh" <<'T'
#!/usr/bin/env bash
set -euo pipefail
. "$ROOT/scripts/phase-4b/lib.sh"
t=$(cat "$FAKE_GH_STATE/tip"); e=$(p4b_round_ledger_parse "$(cat "$FAKE_GH_STATE/commits/$t")")
case "$TAMPER" in
  released) e=$(jq -c 'map(.state = "released")' <<<"$e") ;;
  duplicated) e=$(jq -c '. + .' <<<"$e") ;;
  removed) e='[]' ;;
esac
msg=$(p4b_round_ledger_message 7 "$e"); sha=$(printf 'tamper|%s' "$msg" | shasum | cut -c1-40)
printf '%s' "$msg" >"$FAKE_GH_STATE/commits/$sha"; printf '%s' "$t" >"$FAKE_GH_STATE/parents.$sha"; printf '%s' "$sha" >"$FAKE_GH_STATE/tip"
T
for variant in released duplicated removed; do
  fresh "p10-$variant" 3
  TAMPER=$variant H_HOOK="$WORK/tamper.sh" run me reserve hook prepost
  [ "$RC" = 10 ] && grep -q '^\[cleanup\] Phase 4b round cap' "$S/err.me" \
    && pass "P10: pre-POST refuses a slot that was $variant by someone else mid-run (exit 10, nothing published, pre-POST side effects undone)" || fail "P10 $variant rc=$RC $OUT"
done
# An unreadable ledger at the writer boundary also undoes the pre-POST side effects.
printf '#!/usr/bin/env bash\necho 1 >"$FAKE_GH_STATE/knob.ref_fail"\n' >"$WORK/ref-fail.sh"
fresh p10-unreadable 3
H_HOOK="$WORK/ref-fail.sh" run me reserve hook prepost
[ "$RC" = 10 ] && grep -q '^\[cleanup\] Phase 4b round cap: the round ledger ref is unreadable' "$S/err.me" \
  && pass "P10: an unreadable ledger at the pre-POST check exits 10 and undoes the pre-POST side effects" || fail "P10 unreadable rc=$RC $(cat "$S/err.me")"

# P11: the writer's own release before any POST frees its slot for the next caller.
fresh p11 1
run a reserve release; run b reserve
[ "$RC" = 0 ] && [ "$(reserved_runs)" = '["b"]' ] \
  && pass "P11: a writer release before any POST frees the slot; the next run reserves it" || fail "P11 rc=$RC $(ledger)"

# P12: after a POST attempt (outcome uncertain) the writer never releases; the slot stays occupied.
fresh p12 1
run a reserve attempt release; run b reserve
[ "$RC" = 6 ] && [ "$(reserved_runs)" = '["a"]' ] \
  && pass "P12: no release after a POST attempt — an uncertain publication keeps its slot and the next run holds" || fail "P12 rc=$RC $(ledger)"

# #2790: cross the actual strict guard/transport boundary, not a simulated
# attempt flag. Only definitive pre-transport refusal frees the writer slot.
fresh publication-local-refusal 1
run a reserve publish-refused; refusal_rc=$RC
run b reserve
[ "$refusal_rc" = 1 ] && [ "$RC" = 0 ] && [ "$(reserved_runs)" = '["b"]' ] \
  && [ ! -f "$S/review_posts" ] && grep -q 'owner' "$S/err.a" \
  && pass '#2790: real guard local refusal frees the owning writer slot; next dispatch reserves without a POST' \
  || fail "#2790 local refusal rc=$refusal_rc next=$RC $(ledger)"
fresh publication-unknown 1
run a reserve publish-unknown; post_rc=$RC
run b reserve
[ "$post_rc" = 42 ] && [ "$RC" = 6 ] && [ "$(reserved_runs)" = '["a"]' ] \
  && [ "$(cat "$S/review_posts")" = 1 ] \
  && pass '#2790: actual unknown transport keeps its slot after an empty reconciliation read; next dispatch holds without repost' \
  || fail "#2790 unknown rc=$post_rc next=$RC $(ledger)"
fresh publication-lost-response 1
run a reserve publish-lost-response; post_rc=$RC
run b reserve
[ "$post_rc" = 0 ] && [ "$RC" = 8 ] && [ "$(reserved_runs)" = '["a"]' ] \
  && [ "$(cat "$S/review_posts")" = 1 ] && [ "$(jq length "$S/reviews.json")" = 1 ] \
  && pass '#2790: actual lost-response POST reconciles exact run/head/reviewer once, remains consumed and never reposts' \
  || fail "#2790 lost-response rc=$post_rc next=$RC $(ledger)"

# P13: a review that commits after the client timed out and becomes visible late is never double-counted or lost.
fresh p13 2
run a reserve attempt                                  # a's POST "timed out"
review 50 nathanpayne-codex APPROVED "$HEAD_A" a | arr >"$S/reviews_late.json"
echo $(( $(cat "$S/review_reads" 2>/dev/null || echo 0) + 2 )) >"$S/knob.reviews_late_after"  # invisible to b's consistency-checked read
run b reserve; first_rc=$RC; first=$(jq -c '[.round_cap.occupied, .round_cap.in_flight]' <<<"$OUT")
run c reserve; second=$(jq -c '[.round_cap.occupied, .round_cap.in_flight]' <<<"$OUT")
[ "$first_rc" = 0 ] && [ "$first" = '[1,1]' ] && [ "$RC" = 6 ] && [ "$second" = '[2,1]' ] \
  && pass "P13: a's review lands after its client timed out and only later becomes visible; its slot is counted in flight, then completed, never dropped; b takes the last slot and c holds" \
  || fail "P13 first_rc=$first_rc first=$first second=$second rc=$RC"

# P14: an ambiguous ledger (this run id already present) is refused, never double-reserved.
fresh p14 3; run me reserve; run me reserve
[ "$RC" = 10 ] && [ "$(reserved_runs)" = '["me"]' ] && pass "P14: a duplicate run id is refused (exit 10) and leaves one entry" || fail "P14 rc=$RC"

# P15: unreadable or malformed evidence fails closed.
fresh p15a 3; echo 1 >"$S/knob.ref_fail"; run me reserve
[ "$RC" = 10 ] && pass "P15: an unreadable ledger ref fails closed (exit 10)" || fail "P15a rc=$RC"
fresh p15b 3; printf 'not json' >"$S/reviews.json"; run me reserve
[ "$RC" = 10 ] && pass "P15: malformed review history fails closed (exit 10)" || fail "P15b rc=$RC"
fresh p15c 3; printf 'junk' >"$S/commits/dead"; printf 'dead' >"$S/tip"; run me reserve
[ "$RC" = 10 ] && pass "P15: a malformed ledger commit fails closed (exit 10)" || fail "P15c rc=$RC"
fresh p15d 3; printf '{"author_identity":"nathanjohnpayne","phase_4b_automation":{"max_review_rounds":0}}' >"$S/policy.json"; run me reserve
[ "$RC" = 10 ] && pass "P15: an invalid governing cap fails closed (exit 10)" || fail "P15d rc=$RC"

# #2633: a run that absorbed a tripwire under the admin override keeps the
# override fields in every round-cap stop: spent (8), held (6), unreadable (10).
OVR='[{"decision":"human-tiebreaker","reason":"tripwire","tripwires":["reviewer-address"]}]'
ovr_ok() { jq -e '.admin_override_quote == "Owner: run it" and .admin_overridden[0].tripwires == ["reviewer-address"]' <<<"$OUT" >/dev/null; }
fresh o8 3; { review 1 x APPROVED "$HEAD_A"; review 2 x APPROVED "$HEAD_A"; review 3 x APPROVED "$HEAD_A"; } | arr >"$S/reviews.json"
H_ADMIN_SET=true H_ADMIN_QUOTE='Owner: run it' H_ADMIN_OVERRIDDEN="$OVR" run me reserve
[ "$RC" = 8 ] && ovr_ok && pass "#2633: the spent round-cap stop keeps the admin override fields" || fail "#2633 spent rc=$RC $OUT"
fresh o6 3; { review 1 x APPROVED "$HEAD_A"; review 2 x APPROVED "$HEAD_A"; } | arr >"$S/reviews.json"
run other reserve; H_ADMIN_SET=true H_ADMIN_QUOTE='Owner: run it' H_ADMIN_OVERRIDDEN="$OVR" run me reserve
[ "$RC" = 6 ] && ovr_ok && pass "#2633: the held round-cap stop keeps the admin override fields" || fail "#2633 held rc=$RC $OUT"
fresh o10 3; echo 1 >"$S/knob.ref_fail"
H_ADMIN_SET=true H_ADMIN_QUOTE='Owner: run it' H_ADMIN_OVERRIDDEN="$OVR" run me reserve
[ "$RC" = 10 ] && ovr_ok && pass "#2633: the unreadable round-cap stop keeps the admin override fields" || fail "#2633 unreadable rc=$RC $OUT"

# P16: no governing cap -> nothing is read or written (backward compatible).
fresh p16 none; { for i in 1 2 3 4 5; do review "$i" x APPROVED "$HEAD_A"; done; } | arr >"$S/reviews.json"
run me reserve
[ "$RC" = 0 ] && [ ! -f "$S/tip" ] && [ ! -f "$S/ref_reads" ] && pass "P16: with no governing cap the ledger is never touched" || fail "P16 rc=$RC"

# P17: a head change between rounds does not reset the count.
fresh p17 2; review 1 x APPROVED "$HEAD_A" | arr >"$S/reviews.json"
run a reserve; H_HEAD=$HEAD_B run b reserve
[ "$RC" = 6 ] || [ "$RC" = 8 ] && pass "P17: rounds on an earlier head still count after the head changes (no reset)" || fail "P17 rc=$RC $OUT"

# P18: a release whose ledger read fails (it runs from the EXIT trap after the
# result is out) only warns: no second result, no exit 10, and the slot stays.
fresh p18 3
H_HOOK="$WORK/ref-fail.sh" run me reserve hook release
rm -f "$S/knob.ref_fail"
[ "$RC" = 0 ] && [ "$(jq -r .exit <<<"$OUT")" = 0 ] && ! grep -q 'stopping without review publication' "$S/err.me" \
  && grep -q 'stays occupied' "$S/err.me" && [ "$(reserved_runs)" = '["me"]' ] \
  && pass "P18: a release that cannot read the ledger warns and returns; it never emits a second result or replaces the exit status" \
  || fail "P18 rc=$RC $OUT $(cat "$S/err.me")"

# P19: two reviews carrying one reserved run id (a surplus publication) occupy
# two slots: with one legacy round the cap of 3 is spent, never a fourth round.
fresh p19 3
run a reserve
{ review 1 x APPROVED "$HEAD_A" a; review 2 x APPROVED "$HEAD_A" a; review 3 x APPROVED "$HEAD_A"; } | arr >"$S/reviews.json"
run b reserve
[ "$RC" = 8 ] && [ "$(jq -c '[.round_cap.occupied, .round_cap.in_flight]' <<<"$OUT")" = '[3,0]' ] && [ "$(reserved_runs)" = '["a"]' ] \
  && pass "P19: a surplus review under one reserved run id counts; the cap is spent and b is refused (exit 8)" \
  || fail "P19 rc=$RC $OUT $(reserved_runs)"

# ===========================================================================
# #2968: automated Phase 4b review provenance and the owner-authorized round
# ===========================================================================
# Pure helpers in scripts/lib/p4b-review-provenance.sh, then the production
# round-cap block's --owner-authorization path against the same fake GitHub.
PRURL=https://github.com/owner/repo/pull/7
FOOT="_Posted by scripts/phase-4b-review.sh under the reviewer identity._"
areview() { # <id> <state> <head> <run|""> <submitted_at> [auth-id] [body-prefix]
  local body="${7:-**Automated Phase 4b review** (claude->codex, reviewer nathanpayne-codex)}"$'\n\nok\n'
  [ -z "${6:-}" ] || body+=$'\n'"<!-- mergepath-p4b-owner-authorization: $6 -->"$'\n'
  [ -z "$4" ] || body+=$'\n'"<!-- mergepath-p4b-run: $4 -->"$'\n'
  body+=$'\n\n'"$FOOT"$'\n'
  jq -nc --argjson id "$1" --arg state "$2" --arg head "$3" --arg body "$body" --arg at "$5" \
    '{id:$id,user:{login:"nathanpayne-codex"},state:$state,commit_id:$head,submitted_at:$at,body:$body}'
}
acomment() { # <id> <head> <created_at> [updated_at] [login] [body]
  local body="${6:-P4B_EXTRA_ROUND_AUTHORIZED=$PRURL@$2 reason: the last round findings were fixed; one more review}"
  jq -nc --argjson id "$1" --arg c "$3" --arg u "${4:-$3}" --arg login "${5:-nathanjohnpayne}" --arg body "$body" \
    '{id:$id,user:{login:$login},created_at:$c,updated_at:$u,body:$body,html_url:("https://github.com/owner/repo/pull/7#issuecomment-" + ($id|tostring))}'
}

# Parity with the ledger counter: one run-marker definition, one ledger and
# cap acceptance.
[ "$P4B_PROV_RUN_MARKER_JQ" = "$P4B_RUN_MARKER_JQ" ] \
  && pass "#2968: the gate's run-marker parse is byte-identical to the round counter's" || fail "#2968: run-marker parse diverged"
parity_bad=""
for m in "$(p4b_round_ledger_message 7 '[{"run":"r1","head":"'"$HEAD_A"'","state":"reserved"}]')" "no ledger here" \
         $'x\n{"schema":"p4b-round-ledger/v1","pr":7,"entries":[{"run":"r","state":"maybe"}]}' \
         $'{"schema":"p4b-round-ledger/v1","pr":7,"entries":[]}\n{"schema":"p4b-round-ledger/v1","pr":7,"entries":[]}' \
         $'{"schema":"p4b-round-ledger/v1","pr":7,"entries":[{"run":"bad id","state":"reserved"}]}' \
         "$(p4b_round_ledger_message 7 '[{"run":"r1","head":"'"$HEAD_A"'","state":"reserved","authorization":12}]')"; do
  a=$(p4b_round_ledger_parse "$m" || echo REFUSED); b=$(p4b_prov_ledger_parse "$m" || echo REFUSED)
  [ "$a" = "$b" ] || parity_bad="$parity_bad [${m:0:30}]"
done
for c in '{}' '{"phase_4b_automation":{"max_review_rounds":3}}' '{"phase_4b_automation":{"max_review_rounds":0}}' \
         '{"phase_4b_automation":3}' '{"phase_4b_automation":null}' '{"phase_4b_automation":{"max_review_rounds":2.5}}'; do
  a=$(p4b_governing_round_cap "$c" || echo REFUSED); b=$(p4b_prov_round_cap_enforced "$c" || echo REFUSED)
  case "$a:$b" in none:false|REFUSED:REFUSED|[1-9]*:true) ;; *) parity_bad="$parity_bad [cap $c: $a/$b]" ;; esac
done
[ -z "$parity_bad" ] && pass "#2968: the gate's ledger and cap readers accept exactly what the round counter accepts" || fail "#2968: parity$parity_bad"
for bad in '"12"' 0 -1 1.5 null; do
  p4b_prov_ledger_parse "$(printf '{"schema":"p4b-round-ledger/v1","pr":7,"entries":[{"run":"r","head":"h","state":"reserved","authorization":%s}]}' "$bad")" >/dev/null \
    && fail "#2968: ledger authorization $bad accepted" || pass "#2968: a ledger authorization that is not a positive comment id ($bad) is malformed"
done

# The authorization line: exact PR, full head, reason, the owner's unedited
# comment, newer than the latest automated review, exactly one line.
T0=2026-11-03T10:00:00Z; T1=2026-11-03T11:00:00Z; T2=2026-11-03T12:00:00Z
authv() { p4b_prov_authorization "$1" "${2:-501}" nathanjohnpayne "$PRURL" "${3:-$HEAD_A}" "${4:-$T0}"; }
ok=$(authv "[$(acomment 501 "$HEAD_A" "$T1")]")
jq -e --arg h "$HEAD_A" '.ok == true and .comment_id == 501 and .head == $h and (.reason | startswith("the last round"))' <<<"$ok" >/dev/null \
  && pass "#2968: a well-formed owner authorization for this PR and head validates" || fail "#2968: valid authorization $ok"
[ "$(authv "[$(acomment 501 "$HEAD_A" "$T1" "" "" "P4B_EXTRA_ROUND_AUTHORIZED=https://GitHub.com/Owner/Repo/pull/7@$HEAD_A reason: go")]" | jq -r .ok)" = true ] \
  && pass "#2968: the PR URL compares case-insensitively, as the tiebreak markers do" || fail "#2968: case-insensitive URL"
while IFS='|' read -r label comments cid head floor want; do
  got=$(authv "$comments" "$cid" "$head" "$floor")
  if [ "$(jq -r .ok <<<"$got")" = false ] && jq -e --arg w "$want" '.why | contains($w)' <<<"$got" >/dev/null; then
    pass "#2968: authorization refused: $label"
  else fail "#2968: authorization $label gave $got"; fi
done <<CASES
missing comment|[$(acomment 502 "$HEAD_A" "$T1")]|501|$HEAD_A|$T0|is not a comment on this pull request
another account|[$(acomment 501 "$HEAD_A" "$T1" "" nathanpayne-claude)]|501|$HEAD_A|$T0|configured author_identity
edited comment|[$(acomment 501 "$HEAD_A" "$T1" "$T2")]|501|$HEAD_A|$T0|was edited
no reason|[$(acomment 501 "$HEAD_A" "$T1" "" "" "P4B_EXTRA_ROUND_AUTHORIZED=$PRURL@$HEAD_A")]|501|$HEAD_A|$T0|malformed
abbreviated head|[$(acomment 501 "$HEAD_A" "$T1" "" "" "P4B_EXTRA_ROUND_AUTHORIZED=$PRURL@aaaaaaa reason: go")]|501|$HEAD_A|$T0|malformed
quoted in prose|[$(acomment 501 "$HEAD_A" "$T1" "" "" "As agreed: P4B_EXTRA_ROUND_AUTHORIZED=$PRURL@$HEAD_A reason: go")]|501|$HEAD_A|$T0|malformed
another PR|[$(acomment 501 "$HEAD_A" "$T1" "" "" "P4B_EXTRA_ROUND_AUTHORIZED=https://github.com/owner/repo/pull/8@$HEAD_A reason: go")]|501|$HEAD_A|$T0|another pull request
another head|[$(acomment 501 "$HEAD_A" "$T1")]|501|$HEAD_B|$T0|a new head needs a fresh authorization
older than the latest automated review|[$(acomment 501 "$HEAD_A" "$T0")]|501|$HEAD_A|$T1|not newer than the latest automated
same second as the latest automated review|[$(acomment 501 "$HEAD_A" "$T1")]|501|$HEAD_A|$T1|not newer than the latest automated
CASES
two=$(authv "[$(acomment 501 "$HEAD_A" "$T1" "" "" "P4B_EXTRA_ROUND_AUTHORIZED=$PRURL@$HEAD_A reason: a
P4B_EXTRA_ROUND_AUTHORIZED=$PRURL@$HEAD_A reason: b")]")
jq -e '.ok == false and (.why | contains("exactly one"))' <<<"$two" >/dev/null \
  && pass "#2968: authorization refused: two authorization lines in one comment are ambiguous" || fail "#2968: two lines gave $two"
p4b_prov_authorization '{"not":"array"}' 501 nathanjohnpayne "$PRURL" "$HEAD_A" "" >/dev/null \
  && fail "#2968: non-array comments accepted" || pass "#2968: unreadable comments fail closed rather than reading as no authorization"

# Classification: the gate's four cases.
LEDGER_R='[{"run":"r1","head":"'"$HEAD_A"'","state":"reserved"},{"run":"r2","head":"'"$HEAD_A"'","state":"reserved","authorization":501},{"run":"r3","head":"'"$HEAD_A"'","state":"released"}]'
COMMENTS_R="[$(acomment 501 "$HEAD_A" "$T1")]"
cls() { p4b_prov_classify "$1" "${2:-$LEDGER_R}" "${3:-$COMMENTS_R}" nathanjohnpayne "$PRURL" | jq -r --argjson id "${4:-1}" '.[] | select(.id == $id) | "\(.class)|\(.reason // "")"'; }
want_cls() { # <label> <expected-class> <reason-substring> <reviews> [ledger] [comments] [id]
  local got; got=$(cls "$4" "${5:-}" "${6:-}" "${7:-1}")
  if [ "${got%%|*}" = "$2" ] && [[ "${got#*|}" == *"$3"* ]]; then pass "#2968: classify: $1"; else fail "#2968: classify $1 gave '$got'"; fi
}
want_cls "a ledger-reserved automated review is ledger" ledger "" "[$(areview 1 APPROVED "$HEAD_A" r1 "$T2")]"
want_cls "a review reserved under a valid owner authorization it cites is owner-authorized" owner-authorized "" "[$(areview 1 APPROVED "$HEAD_A" r2 "$T2" 501)]"
want_cls "the #2887 direct header with a quoted owner instruction is unverified" unverified "without opening with the orchestrator header" \
  "[$(jq -c '.body = "**Direct Phase 4b review** (claude -> codex)\n\nOne direct run at the owner'"'"'s direction.\n\n- Owner authorization: \"use an automated 4b\""' <<<"$(areview 1 APPROVED "$HEAD_A" "" "$T2")")]"
want_cls "the #2887 automated header with no run marker or footer is unverified" unverified "no run marker" \
  "[$(jq -c '.body = "**Automated Phase 4b review** (claude->codex, reviewer nathanpayne-codex), direct adapter run\n\n- Owner authorization: \"use an automated 4b\"; scope reduced per owner \"go\""' <<<"$(areview 1 APPROVED "$HEAD_A" "" "$T2")")]"
want_cls "a forged header, run marker and footer with no ledger entry is unverified" unverified "has 0 ledger entries" "[$(areview 1 APPROVED "$HEAD_A" forged "$T2")]"
want_cls "any claim on a PR with no ledger is unverified" unverified "no Phase 4b round ledger" "[$(areview 1 APPROVED "$HEAD_A" r1 "$T2")]" null
want_cls "a released entry does not reserve its review" unverified "is released" "[$(areview 1 APPROVED "$HEAD_A" r3 "$T2")]"
want_cls "a review on another head than its reservation is unverified" unverified "for head $HEAD_A" "[$(areview 1 APPROVED "$HEAD_B" r1 "$T2")]"
want_cls "two reviews carrying one run id are unverified" unverified "2 reviews carry run id r1" "[$(areview 1 APPROVED "$HEAD_A" r1 "$T2"),$(areview 2 APPROVED "$HEAD_A" r1 "$T2")]"
# Run-id uniqueness counts only publisher-shaped carriers (wave audit P1 on
# swipewatch#230): a quoted trailer must not neutralize a legitimate approval.
TRUSTED_R='["nathanpayne-claude","nathanpayne-codex"]'
cls_t() { p4b_prov_classify "$1" "$LEDGER_R" "$COMMENTS_R" nathanjohnpayne "$PRURL" "${2:-$TRUSTED_R}" | jq -r --argjson id "${3:-1}" '.[] | select(.id == $id) | "\(.class)|\(.reason // "")"'; }
quoter=$(jq -c '.id = 2 | .state = "COMMENTED" | .user.login = "drive-by-user"' <<<"$(areview 2 COMMENTED "$HEAD_A" r1 "$T2")")
[ "$(cls_t "[$(areview 1 APPROVED "$HEAD_A" r1 "$T2"),$quoter]")" = "ledger|" ] \
  && pass "#2968: classify: an unregistered account copying the header, run marker and footer does not neutralize the approval" \
  || fail "#2968: classify: unregistered quoter gave '$(cls_t "[$(areview 1 APPROVED "$HEAD_A" r1 "$T2"),$quoter]")'"
noheader=$(areview 2 COMMENTED "$HEAD_A" r1 "$T2" "" "Discussing the trailer of review 1:")
[ "$(cls "[$(areview 1 APPROVED "$HEAD_A" r1 "$T2"),$noheader]")" = "ledger|" ] \
  && pass "#2968: classify: a reviewer's comment quoting the run marker and footer without the header is not a carrier" \
  || fail "#2968: classify: header-less quoter gave '$(cls "[$(areview 1 APPROVED "$HEAD_A" r1 "$T2"),$noheader]")'"
[ "$(cls_t "[$(areview 1 APPROVED "$HEAD_A" r1 "$T2"),$(areview 2 APPROVED "$HEAD_A" r1 "$T2")]")" = "unverified|2 reviews carry run id r1" ] \
  && pass "#2968: classify: a surplus publication by a reviewer identity still makes the run ambiguous" \
  || fail "#2968: classify: surplus with trusted list gave '$(cls_t "[$(areview 1 APPROVED "$HEAD_A" r1 "$T2"),$(areview 2 APPROVED "$HEAD_A" r1 "$T2")]")'"
p4b_prov_classify "[$(areview 1 APPROVED "$HEAD_A" r1 "$T2")]" "$LEDGER_R" null nathanjohnpayne "$PRURL" '{"not":"array"}' >/dev/null \
  && fail "#2968: classify accepted a malformed trusted-login list" || pass "#2968: classify fails closed on a malformed trusted-login list"
want_cls "an authorized reservation cited without its record is unverified" unverified "does not match the ledger" "[$(areview 1 APPROVED "$HEAD_A" r2 "$T2")]"
want_cls "a record on an unauthorized reservation is unverified" unverified "does not match the ledger" "[$(areview 1 APPROVED "$HEAD_A" r1 "$T2" 501)]"
want_cls "a review that only quotes an authorization line is unverified" unverified "0 ledger entries" \
  "[$(areview 1 APPROVED "$HEAD_A" quoted "$T2" "" "**Automated Phase 4b review** (x)
Owner said: P4B_EXTRA_ROUND_AUTHORIZED=$PRURL@$HEAD_A reason: go")]"
want_cls "a quoted, unanchored authorization record is not a citation" ledger "" \
  "[$(areview 1 APPROVED "$HEAD_A" r1 "$T2" "" "**Automated Phase 4b review** (x)
Finding text quoting <!-- mergepath-p4b-owner-authorization: 501 --> mid-review.")]"
want_cls "a complete authorization/run/footer example quoted before the real trailer is not the citation (Codex P2 on #2980)" ledger "" \
  "[$(areview 1 APPROVED "$HEAD_A" r1 "$T2" "" "**Automated Phase 4b review** (x)
Example trailer:
<!-- mergepath-p4b-owner-authorization: 501 -->
<!-- mergepath-p4b-run: example -->
$FOOT
End of example.")]"
want_cls "an authorization consumed by two entries is unverified" unverified "more than one ledger entry" "[$(areview 1 APPROVED "$HEAD_A" r2 "$T2" 501)]" \
  "$(jq -c '. + [{"run":"r4","head":"'"$HEAD_A"'","state":"reserved","authorization":501}]' <<<"$LEDGER_R")"
want_cls "an edited authorization comment is unverified" unverified "was edited" "[$(areview 1 APPROVED "$HEAD_A" r2 "$T2" 501)]" "" "[$(acomment 501 "$HEAD_A" "$T1" "$T2")]"
want_cls "an authorization for another head is unverified" unverified "a new head needs a fresh authorization" "[$(areview 1 APPROVED "$HEAD_A" r2 "$T2" 501)]" "" "[$(acomment 501 "$HEAD_B" "$T1")]"
want_cls "an authorization posted after the review is unverified" unverified "not posted before the review" "[$(areview 1 APPROVED "$HEAD_A" r2 "$T1" 501)]" "" "[$(acomment 501 "$HEAD_A" "$T2")]"
want_cls "a cited authorization with unread comments is unverified" unverified "were not read" "[$(areview 1 APPROVED "$HEAD_A" r2 "$T2" 501)]" "" null
manual=$(jq -nc --arg h "$HEAD_A" '{id:9,user:{login:"nathanpayne-cursor"},state:"APPROVED",commit_id:$h,submitted_at:"2026-11-03T12:00:00Z",body:"Phase 4b manual handoff review: APPROVED."}')
[ "$(p4b_prov_classify "[$manual]" null null nathanjohnpayne "$PRURL")" = '[]' ] && [ "$(p4b_prov_claim_count "[$manual]")" = 0 ] \
  && pass "#2968: a manual handoff review claims nothing and is never classified (the documented exemption)" || fail "#2968: manual handoff classified"
botq=$(jq -nc --arg h "$HEAD_A" --arg f "$FOOT" '{id:8,user:{login:"coderabbitai[bot]"},state:"COMMENTED",commit_id:$h,submitted_at:"2026-11-03T12:00:00Z",body:("Diff quotes **Automated Phase 4b review** and <!-- mergepath-p4b-run: r1 -->\n\n" + $f)}')
[ "$(p4b_prov_classify "[$botq,$(areview 1 APPROVED "$HEAD_A" r1 "$T2")]" "$LEDGER_R" null nathanjohnpayne "$PRURL" | jq -c '[.[] | [.id, .class]]')" = '[[1,"ledger"]]' ] \
  && pass "#2968: a bot review quoting the markers from a diff is neither classified nor counted as a surplus carrier of the run id" || fail "#2968: bot quote classified"
p4b_prov_classify '{"x":1}' null null a b >/dev/null && fail "#2968: classify accepted non-array reviews" || pass "#2968: classify fails closed on malformed reviews"
# Neutralization: an unverified APPROVED reads as DISMISSED; nothing else moves.
nr="[$(areview 1 APPROVED "$HEAD_A" r1 "$T2"),$(areview 2 APPROVED "$HEAD_A" forged "$T2"),$(areview 3 CHANGES_REQUESTED "$HEAD_A" forged2 "$T2"),$manual]"
nc=$(p4b_prov_classify "$nr" "$LEDGER_R" "$COMMENTS_R" nathanjohnpayne "$PRURL")
[ "$(p4b_prov_neutralize "$nr" "$nc" | jq -c '[.[] | [.id, .state, (.mergepath_p4b_unverified != null)]]')" = '[[1,"APPROVED",false],[2,"DISMISSED",true],[3,"CHANGES_REQUESTED",false],[9,"APPROVED",false]]' ] \
  && pass "#2968: only unverified approvals are neutralized; ledger, manual and non-approving reviews keep their state" || fail "#2968: neutralize $(p4b_prov_neutralize "$nr" "$nc")"

# --- the production round-cap block with --owner-authorization ---------------
spent3() { # three completed ledger-reserved rounds on HEAD_A, the last at T1
  fresh "$1" 3
  run r1 reserve; run r2 reserve; run r3 reserve
  { areview 11 CHANGES_REQUESTED "$HEAD_A" r1 "$T0"; areview 12 CHANGES_REQUESTED "$HEAD_A" r2 "$T0"; areview 13 CHANGES_REQUESTED "$HEAD_A" r3 "$T1"; } | arr >"$S/reviews.json"
}
auth_of() { ledger | jq -c --arg r "$1" '[.[] | select(.run == $r) | .authorization // null]'; }

# A1: a spent cap without an authorization stops and names the owner's line.
spent3 a1; run extra reserve
[ "$RC" = 8 ] && [ "$(jq -r .round_cap.state <<<"$OUT")" = spent ] && grep -q 'P4B_EXTRA_ROUND_AUTHORIZED=<canonical-https-PR-URL>@<full-head-sha> reason: <why>' "$S/err.extra" \
  && pass "#2968 A1: a direct round after a spent cap with no authorization is refused (exit 8) and the stop names the owner's placeholder line" || fail "#2968 A1 rc=$RC $OUT"
# A2: a valid authorization reserves exactly one slot beyond the cap, bound to
# it, and the pre-POST binding check accepts it while the authorization holds.
printf '[%s]' "$(acomment 501 "$HEAD_A" "$T2")" >"$S/comments.json"
H_AUTH=501 run extra reserve prepost
[ "$RC" = 0 ] && [ "$(auth_of extra)" = '[501]' ] && [ "$(jq -c '[.round_cap.occupied, .round_cap.owner_authorization.state, .round_cap.owner_authorization.comment_id]' <<<"$OUT")" = '[3,"consumed",501]' ] \
  && pass "#2968 A2: a valid owner authorization reserves one round beyond the spent cap, the ledger entry records its comment id, and the binding check accepts it" || fail "#2968 A2 rc=$RC $OUT $(cat "$S/err.extra")"
# A4: a second run on the same authorization is refused; the cap stays spent.
{ cat "$S/reviews.json" | jq -c '.[]'; areview 14 APPROVED "$HEAD_A" extra 2026-11-03T13:00:00Z 501; } | arr >"$S/reviews.next" && mv "$S/reviews.next" "$S/reviews.json"
H_AUTH=501 run again reserve
[ "$RC" = 8 ] && [ "$(auth_of again)" = '[]' ] && grep -q 'already consumed by run extra' "$S/err.again" \
  && [ "$(jq -r .round_cap.owner_authorization.state <<<"$OUT")" = refused ] \
  && pass "#2968 A4: a second run on the same authorization is refused (exit 8): it authorizes exactly one run" || fail "#2968 A4 rc=$RC $OUT"
run plain reserve
[ "$RC" = 8 ] && pass "#2968 A4: after the authorized round, an unauthorized run still meets the spent cap" || fail "#2968 A4b rc=$RC"
# A5: a head change invalidates the authorization.
spent3 a5; printf '[%s]' "$(acomment 501 "$HEAD_A" "$T2")" >"$S/comments.json"
H_HEAD=$HEAD_B H_AUTH=501 run extra reserve
[ "$RC" = 8 ] && grep -q 'a new head needs a fresh authorization' "$S/err.extra" && [ "$(auth_of extra)" = '[]' ] \
  && pass "#2968 A5: an authorization for an earlier head is stale on a new head (exit 8, nothing reserved)" || fail "#2968 A5 rc=$RC $OUT"
# A6: an authorization older than the latest automated review, or edited, or
# by another account, keeps the stop.
for variant in older edited other; do
  spent3 "a6-$variant"
  case "$variant" in
    older) printf '[%s]' "$(acomment 501 "$HEAD_A" "$T0")" >"$S/comments.json" ;;
    edited) printf '[%s]' "$(acomment 501 "$HEAD_A" "$T2" 2026-11-03T13:00:00Z)" >"$S/comments.json" ;;
    other) printf '[%s]' "$(acomment 501 "$HEAD_A" "$T2" "" nathanpayne-claude)" >"$S/comments.json" ;;
  esac
  H_AUTH=501 run extra reserve
  [ "$RC" = 8 ] && [ "$(auth_of extra)" = '[]' ] && pass "#2968 A6: an $variant authorization keeps the spent stop" || fail "#2968 A6 $variant rc=$RC $OUT"
done
# A6b (#2666 matrix row 19): a valid exact-head owner runaway tiebreak clears
# only the Codex runaway stop. It is not an extra-round authorization, so at a
# spent round cap it grants no fourth round, whether merely present on the PR
# or cited as the authorization comment.
for variant in present cited; do
  spent3 "a6b-$variant"
  printf '[%s]' "$(acomment 502 "$HEAD_A" "$T2" "" nathanjohnpayne "TIEBREAK_RUNAWAY_ACCEPTED=$PRURL@$HEAD_A")" >"$S/comments.json"
  if [ "$variant" = cited ]; then H_AUTH=502 run extra reserve; else run extra reserve; fi
  [ "$RC" = 8 ] && [ "$(jq -r .round_cap.state <<<"$OUT")" = spent ] && [ "$(auth_of extra)" = '[]' ] \
    && pass "#2666: a valid owner runaway tiebreak ($variant) grants no round beyond the spent cap (exit 8, nothing reserved)" \
    || fail "#2666 A6b $variant rc=$RC $OUT $(cat "$S/err.extra")"
done
# A7: a cap that is not spent, or no cap, refuses the flag and consumes nothing.
fresh a7 3; printf '[%s]' "$(acomment 501 "$HEAD_A" "$T2")" >"$S/comments.json"
H_AUTH=501 run extra reserve
[ "$RC" = 3 ] && [ ! -f "$S/tip" ] && grep -q 'applies only to a spent round cap' "$S/err.extra" \
  && pass "#2968 A7: below the cap the flag is refused (exit 3) and the authorization stays unconsumed" || fail "#2968 A7 rc=$RC"
fresh a7n none; H_AUTH=501 run extra reserve
[ "$RC" = 3 ] && [ ! -f "$S/tip" ] && pass "#2968 A7: with no governing cap the flag is refused (exit 3)" || fail "#2968 A7n rc=$RC"
# A8: unreadable comments are unreadable evidence (exit 10), never "no authorization".
spent3 a8; echo 1 >"$S/knob.comments_fail"
H_AUTH=501 run extra reserve
[ "$RC" = 10 ] && [ "$(auth_of extra)" = '[]' ] && pass "#2968 A8: unreadable authorization evidence exits 10 and reserves nothing" || fail "#2968 A8 rc=$RC"
# A9: an authorization edited after dispatch refuses the POST at the binding check.
spent3 a9; printf '[%s]' "$(acomment 501 "$HEAD_A" "$T2")" >"$S/comments.json"
cat >"$WORK/edit-auth.sh" <<'E'
#!/usr/bin/env bash
jq -c '.[0].updated_at = "2026-11-03T14:00:00Z"' "$FAKE_GH_STATE/comments.json" >"$FAKE_GH_STATE/comments.next" && mv "$FAKE_GH_STATE/comments.next" "$FAKE_GH_STATE/comments.json"
E
H_AUTH=501 H_HOOK="$WORK/edit-auth.sh" run extra reserve hook prepost
[ "$RC" = 10 ] && grep -q 'no longer holds' "$S/err.extra" && grep -q '\[cleanup\]' "$S/err.extra" \
  && pass "#2968 A9: an authorization edited after dispatch refuses publication at the binding check (exit 10, pre-POST cleanup)" || fail "#2968 A9 rc=$RC $(cat "$S/err.extra")"
# A10: a reservation stripped of its authorization fails the binding check.
spent3 a10; printf '[%s]' "$(acomment 501 "$HEAD_A" "$T2")" >"$S/comments.json"
cat >"$WORK/strip-auth.sh" <<'T'
#!/usr/bin/env bash
set -euo pipefail
. "$ROOT/scripts/phase-4b/lib.sh"
t=$(cat "$FAKE_GH_STATE/tip"); e=$(p4b_round_ledger_parse "$(cat "$FAKE_GH_STATE/commits/$t")")
e=$(jq -c 'map(del(.authorization))' <<<"$e")
msg=$(p4b_round_ledger_message 7 "$e"); sha=$(printf 'strip|%s' "$msg" | shasum | cut -c1-40)
printf '%s' "$msg" >"$FAKE_GH_STATE/commits/$sha"; printf '%s' "$t" >"$FAKE_GH_STATE/parents.$sha"; printf '%s' "$sha" >"$FAKE_GH_STATE/tip"
T
H_AUTH=501 H_HOOK="$WORK/strip-auth.sh" run extra reserve hook prepost
[ "$RC" = 10 ] && grep -q 'no longer bound to its owner authorization' "$S/err.extra" \
  && pass "#2968 A10: a reservation stripped of its authorization is refused before the POST" || fail "#2968 A10 rc=$RC $(cat "$S/err.extra")"
# A11: a released authorized run still spent its authorization.
spent3 a11; printf '[%s]' "$(acomment 501 "$HEAD_A" "$T2")" >"$S/comments.json"
H_AUTH=501 run extra reserve release
H_AUTH=501 run retry reserve
[ "$RC" = 8 ] && grep -q 'already consumed by run extra' "$S/err.retry" \
  && pass "#2968 A11: an authorized run that released its slot before posting still consumed the authorization" || fail "#2968 A11 rc=$RC $OUT"
# A12: five concurrent runs on one authorization -> exactly one consumes it.
spent3 a12; printf '[%s]' "$(acomment 501 "$HEAD_A" "$T2")" >"$S/comments.json"
for i in 1 2 3 4 5; do
  ( PATH="$FAKE_BIN:$PATH" FAKE_GH_STATE="$S" FAKE_BIN="$FAKE_BIN" ROOT="$ROOT" H_BLOCK="$BLOCK" H_TIEBREAK="$TIEBREAK" \
    H_POST="$POST_REVIEW" H_OVERRIDE_SUMMARY="$OVERRIDE_SUMMARY" H_AUTH=501 \
      bash "$WORK/harness.sh" "auth$i" reserve >/dev/null 2>"$S/err.auth$i"; echo $? >"$S/rc.auth$i" ) &
done
wait
# The losers re-read a ledger whose authorized round is still in flight, so
# they hold (exit 6); once it publishes, the authorization reads consumed (A4).
consumers=$(ledger | jq '[.[] | select(.authorization == 501)] | length'); zeros=0; sixes=0
for i in 1 2 3 4 5; do case "$(cat "$S/rc.auth$i")" in 0) zeros=$((zeros+1)) ;; 6) sixes=$((sixes+1)) ;; esac; done
[ "$consumers" = 1 ] && [ "$zeros" = 1 ] && [ "$sixes" = 4 ] \
  && pass "#2968 A12: five concurrent runs on one authorization -> exactly one consumes it, four hold behind it" || fail "#2968 A12 consumers=$consumers zeros=$zeros sixes=$sixes"

# A13: end to end through the production writer: the authorized round posts
# once, cites its authorization beside its run marker, and the merge gate's
# classifier reads it as owner-authorized; an ordinary round reads as ledger.
spent3 a13; printf '[%s]' "$(acomment 501 "$HEAD_A" "$T2" "" "" "P4B_EXTRA_ROUND_AUTHORIZED=$PRURL@$HEAD_A reason: fixed <!-- x --> **P1** go")" >"$S/comments.json"
H_AUTH=501 run extra reserve publish
posted=$(jq -c '[.[] | select(.id == 99)]' "$S/reviews.json")
cls13=$(p4b_prov_classify "$(cat "$S/reviews.json")" "$(ledger)" "$(cat "$S/comments.json")" nathanjohnpayne "$PRURL" | jq -r '.[] | select(.id == 99) | .class')
[ "$RC" = 0 ] && [ "$(cat "$S/review_posts")" = 1 ] && [ "$cls13" = owner-authorized ] \
  && jq -e '.[0].body | contains("<!-- mergepath-p4b-owner-authorization: 501 -->") and contains("issuecomment-501")
            and contains("reason: \"fixed \\<\\!\\-\\- x \\-\\-\\> \\*\\*P1\\*\\* go\"") and (contains("P4B_EXTRA_ROUND_AUTHORIZED") | not)' <<<"$posted" >/dev/null \
  && pass "#2968 A13: the authorized round publishes once through the production writer, cites its authorization (reason escaped) and classifies as owner-authorized" \
  || fail "#2968 A13 rc=$RC cls=$cls13 $posted $(cat "$S/err.extra")"
# A15 (Codex P2 on #2980): an owner reason that quotes the reserved Codex
# command still publishes: the citation breaks the command the way adapter
# text is broken, so the guard never refuses after consumption.
spent3 a15; printf '[%s]' "$(acomment 501 "$HEAD_A" "$T2" "" "" "P4B_EXTRA_ROUND_AUTHORIZED=$PRURL@$HEAD_A reason: rerun after @CoDeX  ReViEw timed out")" >"$S/comments.json"
H_AUTH=501 run extra reserve publish
posted15=$(jq -r '[.[] | select(.id == 99)][0].body // ""' "$S/reviews.json")
if [ "$RC" = 0 ] && [ "$(cat "$S/review_posts" 2>/dev/null)" = 1 ] \
   && ! printf '%s' "$posted15" | python3 -c 'import re,sys; sys.exit(0 if re.search(r"@codex\s+review", sys.stdin.read(), re.I) else 1)' \
   && printf '%s' "$posted15" | grep -q 'rerun after'; then
  pass "#2968 A15: an authorization reason quoting the reserved Codex command publishes with the command broken"
else fail "#2968 A15 rc=$RC $(cat "$S/err.extra")"; fi
spent_less() { fresh "$1" 3; run r1 reserve; areview 11 CHANGES_REQUESTED "$HEAD_A" r1 "$T0" | arr >"$S/reviews.json"; }
spent_less a14; run plain reserve publish
cls14=$(p4b_prov_classify "$(cat "$S/reviews.json")" "$(ledger)" null nathanjohnpayne "$PRURL" | jq -r '.[] | select(.id == 99) | .class')
[ "$RC" = 0 ] && [ "$cls14" = ledger ] \
  && pass "#2968 A14: an ordinary ledger-reserved round published by the production writer classifies as ledger" || fail "#2968 A14 rc=$RC cls=$cls14 $(cat "$S/err.plain")"

# ===========================================================================
# #2746 item 2: the REST transport passes the ledger's git-data writes through
# ===========================================================================
# round_api runs `gh api <endpoint> --method <M> --input <file>` through
# gh-as-reviewer.sh, which hands it to gh_rest_run under REST transport. The
# canary review claimed that dispatcher refuses a wrapped `gh api`; it passes
# each of the ledger's four shapes through under the verified token.
mkdir -p "$WORK/rest-bin"
cat >"$WORK/rest-bin/gh" <<'SH'
#!/usr/bin/env bash
printf '%s|%s\n' "${GH_TOKEN:-}" "$*" >>"$REST_PROBE_LOG"
printf '{"sha":"deadbeef"}\n'
SH
chmod +x "$WORK/rest-bin/gh"
printf '{"sha":"x","force":false}' >"$WORK/rest-payload.json"
rest_bad=""
for spec in "POST repos/o/r/git/trees" "POST repos/o/r/git/commits" "POST repos/o/r/git/refs" "PATCH repos/o/r/git/refs/heads/x"; do
  set -- $spec
  : >"$WORK/rest.log"
  out=$(REST_PROBE_LOG="$WORK/rest.log" bash -c '. "$1"; shift; gh_rest_run gh-as-reviewer nathanpayne-claude verified-token "$@"' _ \
    "$ROOT/scripts/lib/gh-rest-transport.sh" "$WORK/rest-bin/gh" api "$2" --method "$1" --input "$WORK/rest-payload.json" 2>&1) \
    || rest_bad="$rest_bad $1:$2(rc)"
  [ "$out" = '{"sha":"deadbeef"}' ] || rest_bad="$rest_bad $1:$2(out)"
  grep -qxF "verified-token|api $2 --method $1 --input $WORK/rest-payload.json" "$WORK/rest.log" || rest_bad="$rest_bad $1:$2(call)"
done
[ -z "$rest_bad" ] && pass "#2746: the REST transport runs every round-ledger git-data write under the verified token" \
  || fail "#2746: REST transport refused or altered a round-ledger write:$rest_bad"

echo
echo "test_phase_4b_round_cap: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
