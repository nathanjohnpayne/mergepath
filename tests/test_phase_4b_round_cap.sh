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
    response=$(jq --arg login nathanpayne-codex '. + {id:99,user:{login:$login},state:"CHANGES_REQUESTED"}' "$input")
    jq --argjson r "$response" '. + [$r]' "$S/reviews.json" >"$S/reviews.next"
    mv "$S/reviews.next" "$S/reviews.json"
    [ "$(knob review_lost_response)" = 0 ] || { echo 'fixture lost review response' >&2; exit 42; }
    printf '%s\n' "$response" ;;
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
export P4B_ROUND_TEST_GUARD="$ROOT/scripts/workflow/gh-comment-trigger-guard.py"
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
        H_ADMIN_OVERRIDDEN="${H_ADMIN_OVERRIDDEN:-[]}" \
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

echo
echo "test_phase_4b_round_cap: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
