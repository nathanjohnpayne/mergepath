#!/usr/bin/env bash
# tests/test_phase_4b_accounting.sh
#
# Unit tests for the Phase 4b approval-loop accounting package (#602):
#   scripts/phase-4b/accounting.sh           (ledger builder + block renderer)
#   scripts/phase-4b/accounting.schema.json  (p4b-accounting/v1 record contract)
#   scripts/phase-4b/verdict.schema.json     (additive nullable usage fields)
#   scripts/phase-4b-review.sh               (orchestrator hook, fail-open)
#
# Strategy: no network, no real models — mirrors tests/test_phase_4b_automation.sh.
# Adapter CLIs are injected via CODEX_BIN fakes, PR metadata via orchestrator
# override flags, policy via MERGEPATH_REVIEW_POLICY_PATH, accounting state via
# P4B_ACCT_STATE_DIR, and prices via P4B_ACCT_PRICES_PATH. Bash 3.2 portable.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ACCT="$ROOT/scripts/phase-4b/accounting.sh"
LIB="$ROOT/scripts/phase-4b/lib.sh"
ORCH="$ROOT/scripts/phase-4b-review.sh"
AD_CLAUDE="$ROOT/scripts/phase-4b/adapters/review-via-claude.sh"
ACCT_SCHEMA="$ROOT/scripts/phase-4b/accounting.schema.json"
VERDICT_SCHEMA="$ROOT/scripts/phase-4b/verdict.schema.json"
PRICES="$ROOT/scripts/phase-4b/prices.json"

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not available" >&2; exit 0; }
for f in "$ACCT" "$LIB" "$ORCH" "$AD_CLAUDE" "$ACCT_SCHEMA" "$VERDICT_SCHEMA" "$PRICES"; do
  [ -e "$f" ] || { echo "missing required path: $f" >&2; exit 1; }
done

WORK="$(mktemp -d "${TMPDIR:-/tmp}/p4b-acct-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

PASS=0; FAIL=0
pass() { echo "  PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*" >&2; FAIL=$((FAIL + 1)); }

# --- fixtures ----------------------------------------------------------------
DIFF="$WORK/diff.patch"
printf 'diff --git a/x.js b/x.js\n+const x = 1;\n' > "$DIFF"

# Enabled automation, accounting block ABSENT (sub-toggle defaults to true).
POLICY_ON="$WORK/policy-on.yml"
cat > "$POLICY_ON" <<'YAML'
available_reviewers:
  - nathanpayne-claude
  - nathanpayne-codex
default_external_reviewer: nathanpayne-codex
author_identity: nathanjohnpayne
phase_4b_automation:
  enabled: true
  mode: local
YAML

# Enabled automation, accounting explicitly DISABLED.
POLICY_ACCT_OFF="$WORK/policy-acct-off.yml"
cat > "$POLICY_ACCT_OFF" <<'YAML'
available_reviewers:
  - nathanpayne-claude
  - nathanpayne-codex
default_external_reviewer: nathanpayne-codex
phase_4b_automation:
  enabled: true
  mode: local
  accounting:
    enabled: false
YAML

# Enabled automation + accounting with notional price keys configured.
POLICY_ACCT_PRICES="$WORK/policy-acct-prices.yml"
cat > "$POLICY_ACCT_PRICES" <<'YAML'
available_reviewers:
  - nathanpayne-claude
  - nathanpayne-codex
default_external_reviewer: nathanpayne-codex
phase_4b_automation:
  enabled: true
  mode: local
  accounting:
    enabled: true            # explicit, with a trailing comment
    codex_price_key: testprov.model-x.standard   # fixture key
    claude_price_key: testprov.model-y.standard
YAML

# Parent automation disabled entirely.
POLICY_OFF="$WORK/policy-off.yml"
cat > "$POLICY_OFF" <<'YAML'
available_reviewers:
  - nathanpayne-claude
  - nathanpayne-codex
default_external_reviewer: nathanpayne-codex
phase_4b_automation:
  enabled: false
YAML

# Deterministic test price table (never depend on live prices for math).
TEST_PRICES="$WORK/prices-test.json"
cat > "$TEST_PRICES" <<'JSON'
{
  "version": "test-1",
  "providers": {
    "testprov": {
      "models": {
        "model-x": {
          "standard": { "input": 2.0, "output": 10.0, "total_only_blended_80_20": 4.0 }
        },
        "model-y": {
          "standard": { "input": 10.0, "output": 20.0, "cache_write_5m": 5.0, "cache_read": 1.0, "total_only_blended_80_20": 12.0 }
        },
        "model-nototal": {
          "standard": { "input": 1.0, "output": 2.0 }
        }
      }
    }
  }
}
JSON

# Adapter/auth fixtures for orchestrator runs (mirrors the automation suite).
CODEX_AUTH_CHATGPT="$WORK/codex-auth-chatgpt.json"
printf '%s\n' '{"auth_mode":"chatgpt"}' > "$CODEX_AUTH_CHATGPT"
CLAUDE_AUTH_PLAN="$WORK/claude-auth-plan.json"
printf '%s\n' '{"loggedIn":true,"authMethod":"claude.ai","apiProvider":"firstParty","subscriptionType":"max"}' > "$CLAUDE_AUTH_PLAN"
export P4B_CODEX_AUTH_FILE="$CODEX_AUTH_CHATGPT"
export P4B_CLAUDE_AUTH_STATUS_FILE="$CLAUDE_AUTH_PLAN"

BIN="$WORK/bin"; mkdir -p "$BIN"
mk_fake() { # mk_fake <name> <body-after-stdin-drain>
  local name="$1"; shift
  { echo '#!/usr/bin/env bash'; echo 'cat >/dev/null 2>&1 || true'; printf '%s\n' "$*"; } > "$BIN/$name"
  chmod +x "$BIN/$name"
}
mk_fake fake-codex-approve \
  "printf '%s' '{\"verdict\":\"APPROVED\",\"summary\":\"looks good\",\"findings\":[]}'"
mk_fake fake-codex-approve-p2 \
  "printf '%s' '{\"verdict\":\"APPROVED\",\"summary\":\"advisory only\",\"findings\":[{\"severity\":\"P2\",\"path\":\"x.js\",\"line\":2,\"body\":\"tighten this\"}]}'"
mk_fake fake-codex-changes \
  "printf '%s' '{\"verdict\":\"CHANGES_REQUESTED\",\"summary\":\"needs work\",\"findings\":[{\"severity\":\"P1\",\"path\":\"x.js\",\"line\":2,\"body\":\"bug here\"}]}'"
mk_fake fake-codex-usage \
  "printf '%s\n' 'tokens used' >&2
printf '%s\n' '1,234' >&2
printf '%s' '{\"verdict\":\"APPROVED\",\"summary\":\"looks good\",\"findings\":[]}'"
# Claude envelope exposing the additive #602 usage fields.
mk_fake fake-claude-cache-usage \
  "jq -n --arg r '{\"verdict\":\"APPROVED\",\"summary\":\"ok\",\"findings\":[]}' '{type:\"result\",subtype:\"success\",result:\$r,session_id:\"t\",total_cost_usd:0.42,usage:{input_tokens:100,output_tokens:50,total_tokens:150,cache_creation_input_tokens:30,cache_read_input_tokens:20}}'"

cat > "$BIN/gh" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = "api" ]; then
  case "${2:-}" in
    repos/o/r/pulls/*)
      printf '%s\n' "${P4B_FAKE_LIVE_HEAD:-abc123}"
      exit 0
      ;;
  esac
fi
echo "unexpected fake gh invocation: $*" >&2
exit 127
SH
chmod +x "$BIN/gh"

cat > "$BIN/fake-gh-as-reviewer" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = "--" ] || { echo "expected wrapper separator" >&2; exit 64; }
while [ "$#" -gt 0 ]; do
  if [ "$1" = "--input" ]; then
    if [ -n "${P4B_WRAPPER_BODY:-}" ]; then
      jq -r '.body' "${2:?}" > "$P4B_WRAPPER_BODY"
    fi
    printf '{"id":1,"commit_id":"%s"}\n' "${P4B_FAKE_CREATED_REVIEW_HEAD:-abc123}"
    exit 0
  fi
  shift
done
printf '{"id":1,"commit_id":"%s"}\n' "${P4B_FAKE_CREATED_REVIEW_HEAD:-abc123}"
SH
chmod +x "$BIN/fake-gh-as-reviewer"

# --- golden p4b-accounting/v1 sample (SPEC § Output shape, the #580 case) ----
GOLDEN_RAW="$WORK/golden-raw.json"
cat > "$GOLDEN_RAW" <<'JSON'
{"schema":"p4b-accounting/v1","pr":580,"final_head_sha":"d05ff4d0…","final_verdict":"APPROVED","final_reviewer":"nathanpayne-codex","final_direction":"claude->codex","automation_state":"dry-run","wall_time_first_loop_to_approval_seconds":225,
 "loops":[
  {"loop":1,"reviewer":"nathanpayne-codex","adapter":"review-via-codex.sh","direction":"claude->codex","head_sha":"d05ff4d0…","verdict":"APPROVED","posted":"direct-probe","fell_back":false,"elapsed_seconds":18,"tokens":{"total":55926,"input":null,"output":null,"cache_creation":null,"cache_read":null,"reasoning":null,"source":"codex-stderr"},"findings":{"P0":0,"P1":0,"P2":0,"P3":0,"nitpick":0,"unknown":0},"cli_version":"codex/0.137","timeout_seconds":900,"effort":null,"throttle_events":1,"plan_auth":"chatgpt","fail_closed":{"happened":false,"reason":null,"duration_seconds":null}},
  {"loop":2,"reviewer":"nathanpayne-codex","adapter":"orchestrator-dry-run","direction":"claude->codex","head_sha":"d05ff4d0…","verdict":"APPROVED","posted":"dry-run","fell_back":false,"elapsed_seconds":65,"tokens":{"total":113918,"input":null,"output":null,"cache_creation":null,"cache_read":null,"reasoning":null,"source":"codex-stderr"},"findings":{"P0":0,"P1":0,"P2":0,"P3":0,"nitpick":0,"unknown":0},"cli_version":"codex/0.137","timeout_seconds":900,"effort":null,"throttle_events":0,"plan_auth":"chatgpt","fail_closed":{"happened":false,"reason":null,"duration_seconds":null}},
  {"loop":3,"reviewer":"nathanpayne-claude","adapter":"review-via-claude.sh","direction":"codex->claude","head_sha":"d05ff4d0…","verdict":"APPROVED_WITH_ADVISORIES","posted":"direct-probe","fell_back":false,"elapsed_seconds":66,"tokens":{"total":7360,"input":1589,"output":5771,"cache_creation":null,"cache_read":null,"reasoning":null,"source":"claude-json"},"findings":{"P0":0,"P1":0,"P2":2,"P3":2,"nitpick":0,"unknown":0},"cli_version":null,"timeout_seconds":900,"effort":"medium","throttle_events":0,"plan_auth":"firstParty","fail_closed":{"happened":false,"reason":null,"duration_seconds":null}},
  {"loop":4,"reviewer":"nathanpayne-claude","adapter":"orchestrator-dry-run","direction":"codex->claude","head_sha":"d05ff4d0…","verdict":"CHANGES_REQUESTED","posted":"not-posted","fell_back":true,"elapsed_seconds":76,"tokens":{"total":null,"input":null,"output":null,"cache_creation":null,"cache_read":null,"reasoning":null,"source":"unavailable"},"findings":{"P0":0,"P1":0,"P2":null,"P3":null,"nitpick":null,"unknown":null},"cli_version":null,"timeout_seconds":900,"effort":"medium","throttle_events":0,"plan_auth":"firstParty","fail_closed":{"happened":true,"reason":"approval-carried-findings","duration_seconds":76}}
 ],
 "unique_findings":[
  {"id":"F1","severity":"P2","first_loop":3,"last_loop":3,"disposition":"deferred-to-follow-up","fix_commit":null,"issue":585},
  {"id":"F2","severity":"P2","first_loop":3,"last_loop":3,"disposition":"deferred-to-follow-up","fix_commit":null,"issue":586},
  {"id":"F3","severity":"P3","first_loop":3,"last_loop":3,"disposition":"deferred-to-follow-up","fix_commit":null,"issue":587},
  {"id":"F4","severity":"P3","first_loop":3,"last_loop":3,"disposition":"deferred-to-follow-up","fix_commit":null,"issue":588}
 ],
 "totals":{"adapter_invocations":4,"tokens_total":177204,"tokens_by_provider":{"codex":169844,"claude":7360},"elapsed_seconds_total":225,"billed_usd":0.0,"notional_usd":0.66,"price_table_version":"2026-07-01","fail_closed_events":1,"advisory_issues_filed":[585,586,587,588]},
 "running_totals":{"source":"github-derived","records":24,"auto_approved_prs":24,"automated_attempts":27,"fail_closed_events":3,"tokens_total":2360000,"notional_usd":9.40,"human_minutes_saved_estimate":[720,4320]},
 "generated_at":"2026-07-01T16:24:01Z"}
JSON
GOLDEN="$(jq -c . "$GOLDEN_RAW")"
GOLDEN_FILE="$WORK/golden.json"
printf '%s\n' "$GOLDEN" > "$GOLDEN_FILE"

# --- source the module (pure functions; no lib.sh dependency required) -------
export MERGEPATH_REVIEW_POLICY_PATH="$POLICY_ON"
# shellcheck source=../scripts/phase-4b/accounting.sh
. "$ACCT"

# ===========================================================================
echo "accounting.sh — config toggle + nested reader"
# ===========================================================================
p4b_acct_config_enabled && pass "accounting defaults to enabled when the block is absent" \
  || fail "absent accounting block should default enabled"
MERGEPATH_REVIEW_POLICY_PATH="$POLICY_ACCT_OFF" p4b_acct_config_enabled \
  && fail "accounting.enabled: false not honored" \
  || pass "accounting.enabled: false disables the sub-toggle"
MERGEPATH_REVIEW_POLICY_PATH="$POLICY_ACCT_PRICES" p4b_acct_config_enabled \
  && pass "accounting.enabled: true honored" || fail "explicit enabled true rejected"
v="$(MERGEPATH_REVIEW_POLICY_PATH="$POLICY_ACCT_PRICES" p4b_acct_config_field codex_price_key)"
[ "$v" = "testprov.model-x.standard" ] && pass "nested reader resolves codex_price_key (strips trailing comment)" \
  || fail "codex_price_key -> '$v'"
v="$(MERGEPATH_REVIEW_POLICY_PATH="$POLICY_ACCT_PRICES" p4b_acct_config_field claude_price_key)"
[ "$v" = "testprov.model-y.standard" ] && pass "nested reader resolves claude_price_key" \
  || fail "claude_price_key -> '$v'"
v="$(p4b_acct_config_field codex_price_key)"
[ -z "$v" ] && pass "unset price key reads empty (notional stays n/a)" || fail "unset price key -> '$v'"

# ===========================================================================
echo "accounting.sh — verdict → accounting mappers"
# ===========================================================================
t="$(p4b_acct_tokens_from_verdict '{"verdict":"APPROVED","summary":"x","findings":[],"usage":null}')"
[ "$(printf '%s' "$t" | jq -r '.source')" = "unavailable" ] \
  && [ "$(printf '%s' "$t" | jq -r '.total')" = "null" ] \
  && pass "null usage → all-null tokens with explicit source=unavailable (never estimated)" \
  || fail "null-usage tokens mapping: $t"
t="$(p4b_acct_tokens_from_verdict '{"verdict":"APPROVED","summary":"x","findings":[],"usage":{"token_count":150,"input_tokens":100,"output_tokens":50,"cache_creation_input_tokens":30,"cache_read_input_tokens":20,"reasoning_tokens":7,"total_cost_usd":0.42,"source":"claude-json-envelope"}}')"
if printf '%s' "$t" | jq -e '.total == 150 and .input == 100 and .output == 50 and .cache_creation == 30 and .cache_read == 20 and .reasoning == 7 and .source == "claude-json-envelope"' >/dev/null; then
  pass "full usage (incl. additive #602 fields) maps onto the accounting token names"
else fail "full-usage tokens mapping: $t"; fi

h="$(p4b_acct_findings_hist_from_verdict '{"findings":[{"severity":"P1","path":"a","line":1,"body":"x"},{"severity":"P2","path":"a","line":2,"body":"y"},{"severity":"P2","path":null,"line":null,"body":"z"},{"severity":"weird","body":"w"}]}')"
if printf '%s' "$h" | jq -e '.P0 == 0 and .P1 == 1 and .P2 == 2 and .P3 == 0 and .nitpick == 0 and .unknown == 1' >/dev/null; then
  pass "severity histogram counts exactly, unmapped severities land in unknown"
else fail "histogram: $h"; fi

d="$(p4b_acct_finding_details_from_verdict '{"findings":[{"severity":"P2","path":"a.js","line":3,"body":"dup"}]}' 2)"
[ "$(printf '%s' "$d" | jq -r '.loop')" = "2" ] && pass "finding details carry the loop number" \
  || fail "details: $d"

uf="$(printf '%s\n%s\n%s\n' \
  '{"loop":1,"severity":"P2","path":"a.js","line":3,"body":"dup"}' \
  '{"loop":2,"severity":"P2","path":"a.js","line":3,"body":"dup"}' \
  '{"loop":2,"severity":"P3","path":null,"line":null,"body":"solo"}' \
  | p4b_acct_unique_findings)"
if printf '%s' "$uf" | jq -e 'length == 2
    and .[0].id == "F1" and .[0].first_loop == 1 and .[0].last_loop == 2
    and .[1].id == "F2" and .[1].first_loop == 2 and .[1].last_loop == 2
    and (all(.[]; .disposition == "unresolved" and .fix_commit == null and .issue == null))' >/dev/null; then
  pass "repeated finding across loops dedupes to one entry with first/last lifecycle; default disposition never guessed"
else fail "unique findings: $uf"; fi
uf="$(printf '%s\n' '{"loop":1,"severity":"P2","path":"a.js","line":3,"body":"dup"}' \
  | p4b_acct_unique_findings '{"F1":{"disposition":"deferred-to-follow-up","issue":585}}')"
if printf '%s' "$uf" | jq -e '.[0].disposition == "deferred-to-follow-up" and .[0].issue == 585' >/dev/null; then
  pass "explicit dispositions map applies (issue link recorded)"
else fail "dispositions map: $uf"; fi
uf="$(printf '' | p4b_acct_unique_findings)"
[ "$uf" = "[]" ] && pass "zero findings → empty unique_findings array" || fail "empty details -> $uf"

# ===========================================================================
echo "accounting.sh — notional-cost math (versioned price table)"
# ===========================================================================
export P4B_ACCT_PRICES_PATH="$TEST_PRICES"
v="$(p4b_acct_price_table_version)"
[ "$v" = "test-1" ] && pass "price_table_version read from the table" || fail "version -> '$v'"

r="$(p4b_acct_resolve_rate "testprov.model-x.standard" "input")"
[ "$r" = "2.0" ] || [ "$r" = "2" ] && pass "resolve_rate finds a scalar rate" || fail "rate -> '$r'"
p4b_acct_resolve_rate "testprov.model-x.standard" "no_such_field" >/dev/null \
  && fail "missing rate field accepted" || pass "missing rate field → non-zero (notional n/a, never a guess)"
p4b_acct_resolve_rate "testprov.nope.standard" "input" >/dev/null \
  && fail "missing model accepted" || pass "missing model → non-zero"

TOK_SPLIT='{"total":150,"input":100,"output":50,"cache_creation":null,"cache_read":null,"reasoning":null,"source":"x"}'
n="$(p4b_acct_notional_from_tokens "$TOK_SPLIT" "testprov.model-x.standard" '["input","output"]')"
if printf '%s' "$n" | jq -e '. > 0.0006999 and . < 0.0007001' >/dev/null; then
  pass "split notional math exact (100·2 + 50·10 per-1M = 0.0007)"
else fail "split notional -> '$n'"; fi
TOK_TOTAL='{"total":1000000,"input":null,"output":null,"cache_creation":null,"cache_read":null,"reasoning":null,"source":"x"}'
n="$(p4b_acct_notional_from_tokens "$TOK_TOTAL" "testprov.model-x.standard" '["total_only_blended_80_20"]')"
if printf '%s' "$n" | jq -e '. == 4.0' >/dev/null; then
  pass "total-only blended math exact (1M · 4.0)"
else fail "blended notional -> '$n'"; fi
TOK_CACHE='{"total":200,"input":100,"output":50,"cache_creation":40,"cache_read":10,"reasoning":null,"source":"x"}'
n="$(p4b_acct_notional_auto "$TOK_CACHE" "testprov.model-y.standard")"
if printf '%s' "$n" | jq -e '(. * 1000000 | round) == 2210' >/dev/null; then
  pass "auto pricing includes counted cache components (in+out+cache_write+cache_read)"
else fail "auto cache notional -> '$n'"; fi
p4b_acct_notional_from_tokens '{"total":null,"input":null,"output":null,"cache_creation":null,"cache_read":null,"reasoning":null,"source":"unavailable"}' "testprov.model-x.standard" '["input","output"]' >/dev/null \
  && fail "null token counts priced" || pass "null token counts → non-zero (no partial estimate)"
n="$(p4b_acct_notional_auto "$TOK_SPLIT" "testprov.model-x.standard")"
if printf '%s' "$n" | jq -e '. > 0.0006999 and . < 0.0007001' >/dev/null; then
  pass "notional_auto prefers the exact split over the blended rate"
else fail "auto split preference -> '$n'"; fi
n="$(p4b_acct_notional_auto "$TOK_TOTAL" "testprov.model-x.standard")"
if printf '%s' "$n" | jq -e '. == 4.0' >/dev/null; then
  pass "notional_auto falls back to blended when only a total is exposed"
else fail "auto blended fallback -> '$n'"; fi
p4b_acct_notional_auto "$TOK_TOTAL" "testprov.model-nototal.standard" >/dev/null \
  && fail "missing blended rate priced a total-only loop" \
  || pass "missing blended rate → non-zero (missing price ⇒ n/a)"

LOOPS_MIXED='[
 {"loop":1,"reviewer":"nathanpayne-codex","adapter":"review-via-codex.sh","direction":"claude->codex","tokens":{"total":1000000,"input":null,"output":null,"cache_creation":null,"cache_read":null,"reasoning":null,"source":"codex-stderr"}},
 {"loop":2,"reviewer":"nathanpayne-claude","adapter":"review-via-claude.sh","direction":"codex->claude","tokens":{"total":150,"input":100,"output":50,"cache_creation":null,"cache_read":null,"reasoning":null,"source":"claude-json"}},
 {"loop":3,"reviewer":"nathanpayne-claude","adapter":"orchestrator-dry-run","direction":"codex->claude","tokens":{"total":null,"input":null,"output":null,"cache_creation":null,"cache_read":null,"reasoning":null,"source":"unavailable"}}
]'
n="$(MERGEPATH_REVIEW_POLICY_PATH="$POLICY_ACCT_PRICES" p4b_acct_notional_for_loops "$LOOPS_MIXED")"
# codex loop: 1M · blended 4.0 = 4.0 ; claude loop: 100·10 + 50·20 per-1M = 0.002 ; rounded → 4.0
if printf '%s' "$n" | jq -e '. == 4.0' >/dev/null; then
  pass "per-loop notional sums priced loops and skips token-less loops (rounded to cents)"
else fail "notional_for_loops -> '$n'"; fi
MERGEPATH_REVIEW_POLICY_PATH="$POLICY_ON" p4b_acct_notional_for_loops "$LOOPS_MIXED" >/dev/null \
  && fail "unpriced loops summed without configured keys" \
  || pass "no configured price key → non-zero (fail-closed to n/a, no partial figure)"
LOOPS_NOTOK='[{"loop":1,"reviewer":"nathanpayne-codex","adapter":"a","direction":"claude->codex","tokens":{"total":null,"input":null,"output":null,"cache_creation":null,"cache_read":null,"reasoning":null,"source":"unavailable"}}]'
MERGEPATH_REVIEW_POLICY_PATH="$POLICY_ACCT_PRICES" p4b_acct_notional_for_loops "$LOOPS_NOTOK" >/dev/null \
  && fail "notional computed with zero measured loops" \
  || pass "all-unavailable tokens → notional n/a (cannot price what was not measured)"
unset P4B_ACCT_PRICES_PATH

# ===========================================================================
echo "accounting.sh — per-approval totals"
# ===========================================================================
GOLDEN_LOOPS="$(printf '%s' "$GOLDEN" | jq -c '.loops')"
GOLDEN_UF="$(printf '%s' "$GOLDEN" | jq -c '.unique_findings')"
tt="$(p4b_acct_compute_totals "$GOLDEN_LOOPS" "2026-07-01" "0.66" "$GOLDEN_UF")"
if printf '%s' "$tt" | jq -e '
    .adapter_invocations == 4
    and .tokens_total == 177204
    and .tokens_by_provider.codex == 169844
    and .tokens_by_provider.claude == 7360
    and .elapsed_seconds_total == 225
    and .billed_usd == 0
    and .notional_usd == 0.66
    and .price_table_version == "2026-07-01"
    and .fail_closed_events == 1
    and .advisory_issues_filed == [585,586,587,588]' >/dev/null; then
  pass "compute_totals reproduces the golden totals from the golden loops (incl. provider split + advisory links)"
else fail "compute_totals: $tt"; fi
tt="$(p4b_acct_compute_totals '[{"loop":1,"reviewer":"nathanpayne-codex","adapter":"a","direction":"claude->codex","elapsed_seconds":null,"tokens":{"total":null,"input":null,"output":null,"cache_creation":null,"cache_read":null,"reasoning":null,"source":"unavailable"},"fail_closed":{"happened":false,"reason":null,"duration_seconds":null}}]' "" "null" '[]')"
if printf '%s' "$tt" | jq -e '.tokens_total == null and .elapsed_seconds_total == null and .notional_usd == null and .price_table_version == null' >/dev/null; then
  pass "totals degrade to explicit null when nothing was measured (never a fabricated 0)"
else fail "degraded totals: $tt"; fi

# ===========================================================================
echo "accounting.sh — fail-closed posting-rule assertion + record builder"
# ===========================================================================
mkloop() { # mkloop <n> <verdict> <P0> <P1> <fail_closed_bool>
  jq -nc --argjson n "$1" --arg v "$2" --argjson p0 "$3" --argjson p1 "$4" --argjson fc "$5" '
    {loop:$n, reviewer:"nathanpayne-codex", adapter:"review-via-codex.sh",
     direction:"claude->codex", head_sha:"abc123", verdict:$v,
     posted:(if $fc then "not-posted" else "posted" end), fell_back:$fc,
     elapsed_seconds:10,
     tokens:{total:null,input:null,output:null,cache_creation:null,cache_read:null,reasoning:null,source:"unavailable"},
     findings:{P0:$p0,P1:$p1,P2:0,P3:0,nitpick:0,unknown:0},
     cli_version:null, timeout_seconds:900, effort:null, throttle_events:null,
     plan_auth:"chatgpt",
     fail_closed:{happened:$fc, reason:(if $fc then "test" else null end),
                  duration_seconds:(if $fc then 10 else null end)}}'
}
CLEAN_LOOP="$(mkloop 1 APPROVED 0 0 false)"
CR_LOOP="$(mkloop 1 CHANGES_REQUESTED 0 1 false)"
FIXED_LOOP="$(mkloop 2 APPROVED 0 0 false)"
BAD_APPROVED_LOOP="$(mkloop 1 APPROVED 0 1 false)"
GUARDED_BAD_LOOP="$(mkloop 2 APPROVED_WITH_ADVISORIES 0 1 true)"

p4b_acct_assert_no_required_with_approved "APPROVED" "[$CLEAN_LOOP]" \
  && pass "zero-finding APPROVED passes the posting-rule assertion" \
  || fail "clean APPROVED rejected"
p4b_acct_assert_no_required_with_approved "APPROVED" "[$CR_LOOP,$FIXED_LOOP]" \
  && pass "changes-requested-then-fixed history passes (P1 on a CR loop is legitimate history)" \
  || fail "changes-requested-then-fixed wrongly refused"
p4b_acct_assert_no_required_with_approved "APPROVED" "[$BAD_APPROVED_LOOP]" \
  && fail "APPROVED loop carrying a required-tier finding accepted" \
  || pass "APPROVED loop carrying P1 → assertion refuses (fail-closed)"
p4b_acct_assert_no_required_with_approved "APPROVED" "[$CR_LOOP]" \
  && fail "final APPROVED with no clean approved loop accepted" \
  || pass "final APPROVED requires at least one clean APPROVED loop"
NULLREQ_LOOP="$(printf '%s' "$CLEAN_LOOP" | jq -c '.findings.P1 = null')"
p4b_acct_assert_no_required_with_approved "APPROVED" "[$NULLREQ_LOOP]" \
  && fail "null required-tier counts on the only approved loop accepted" \
  || pass "null required-tier counts cannot back a posted APPROVED (fail-closed)"
p4b_acct_assert_no_required_with_approved "APPROVED" "[$CR_LOOP,$FIXED_LOOP,$GUARDED_BAD_LOOP]" \
  && pass "a fail-closed-guarded findings-bearing approval is recorded history, not a violation" \
  || fail "guarded fail-closed loop wrongly poisons the record"
p4b_acct_assert_no_required_with_approved "APPROVED" "$GOLDEN_LOOPS" \
  && pass "golden loop history passes the assertion" || fail "golden loops refused"

RT_ZERO='{"source":"unavailable","records":0,"reason":"test"}'
rec="$(p4b_acct_build_record 42 abc123 APPROVED nathanpayne-codex "claude->codex" posted "" \
  "[$CR_LOOP,$FIXED_LOOP]" "[]" \
  "$(p4b_acct_compute_totals "[$CR_LOOP,$FIXED_LOOP]" "" null '[]')" "$RT_ZERO" "2026-07-01T00:00:00Z")"
if [ -n "$rec" ] && printf '%s' "$rec" | jq -e '.schema == "p4b-accounting/v1" and (.loops | length) == 2 and .wall_time_first_loop_to_approval_seconds == null' >/dev/null; then
  pass "build_record assembles a changes-requested-then-fixed record"
else fail "build_record: $rec"; fi
p4b_acct_build_record 42 abc123 APPROVED r d posted "" "[$BAD_APPROVED_LOOP]" "[]" "{}" "$RT_ZERO" "" >/dev/null \
  && fail "build_record emitted an illegal APPROVED record" \
  || pass "build_record refuses a findings-bearing APPROVED (fail-closed, no output)"
p4b_acct_build_record "abc" x APPROVED r d posted "" "[$CLEAN_LOOP]" "[]" "{}" "$RT_ZERO" "" >/dev/null \
  && fail "non-integer pr accepted" || pass "non-integer pr refused"

# ===========================================================================
echo "accounting.schema.json — golden sample validates + round-trips"
# ===========================================================================
jq -e . "$ACCT_SCHEMA" >/dev/null 2>&1 && pass "accounting.schema.json parses" || fail "schema unparseable"
if jq -e --slurpfile s "$ACCT_SCHEMA" '
    ($s[0]) as $sch
    | (keys | sort) == ($sch.required | sort)
    and (.schema == "p4b-accounting/v1")
    and ((.final_verdict) as $v | $sch.properties.final_verdict.enum | index($v) != null)
    and ((.automation_state) as $a | $sch.properties.automation_state.enum | index($a) != null)
    and (all(.loops[]; (keys | sort) == ($sch."$defs".loop.required | sort)))
    and (all(.loops[]; (.verdict) as $lv | $sch."$defs".loop.properties.verdict.enum | index($lv) != null))
    and (all(.loops[]; (.posted) as $lp | $sch."$defs".loop.properties.posted.enum | index($lp) != null))
    and (all(.loops[]; (.tokens | keys | sort) == ($sch."$defs".tokens.required | sort)))
    and (all(.loops[]; (.findings | keys | sort) == ($sch."$defs".findings_counts.required | sort)))
    and ((.totals | keys | sort) == ($sch."$defs".totals.required | sort))
    and (all(.unique_findings[]; (keys | sort) == ($sch."$defs".unique_finding.required | sort)))
    and (all(.unique_findings[]; (.disposition) as $dd | $sch."$defs".unique_finding.properties.disposition.enum | index($dd) != null))
    and ((.running_totals | keys) - ($sch."$defs".running_totals.properties | keys) == [])
    and ((.running_totals | keys) | index("source") != null)
  ' "$GOLDEN_FILE" >/dev/null; then
  pass "golden record matches the schema structurally (key sets + enums derived FROM the schema)"
else fail "golden record does not match accounting.schema.json structure"; fi
if command -v check-jsonschema >/dev/null 2>&1; then
  if check-jsonschema --schemafile "$ACCT_SCHEMA" "$GOLDEN_FILE" >/dev/null 2>&1; then
    pass "external JSON Schema validator accepts the golden record"
  else fail "check-jsonschema rejects the golden record"; fi
elif command -v ajv >/dev/null 2>&1; then
  if ajv validate -s "$ACCT_SCHEMA" -d "$GOLDEN_FILE" >/dev/null 2>&1; then
    pass "external JSON Schema validator accepts the golden record"
  else fail "ajv rejects the golden record"; fi
else
  echo "  SKIP: no JSON Schema validator (check-jsonschema/ajv) — structural jq checks above still ran"
fi

BLOCK="$(p4b_acct_render_block "$GOLDEN")" || BLOCK=""
[ -n "$BLOCK" ] || fail "render_block produced nothing for the golden record"
printf '%s' "$BLOCK" | grep -q '^## Phase 4b Approval Accounting' \
  && pass "golden render carries the block heading" || fail "missing block heading"
printf '%s' "$BLOCK" | grep -q -- '55,926 (codex-stderr)' \
  && pass "golden render formats total-only tokens with source" || fail "token cell (total-only) wrong"
printf '%s' "$BLOCK" | grep -q -- '7,360 (claude-json: in 1,589 / out 5,771)' \
  && pass "golden render formats split tokens with in/out" || fail "token cell (split) wrong"
printf '%s' "$BLOCK" | grep -q -- 'unavailable (unavailable)' \
  && pass "loop with no CLI counts renders explicit unavailable" || fail "missing unavailable cell"
printf '%s' "$BLOCK" | grep -q -- '\*\*yes\*\* — approval-carried-findings' \
  && pass "fail-closed loop rendered as positive safety evidence" || fail "fail-closed loop row missing"
printf '%s' "$BLOCK" | grep -q '| F1 | P2 | 3 | 3 | deferred-to-follow-up | #585 |' \
  && pass "findings table links the follow-up issue" || fail "findings row missing"
printf '%s' "$BLOCK" | grep -q -- '~\$0.66 \*(not billed; price table `2026-07-01`)\*' \
  && pass "notional cost labeled not-billed with the price-table version stamp" || fail "notional row wrong"
printf '%s' "$BLOCK" | grep -q -- '\*\*\$0.00\*\* — operator subscription plan' \
  && pass "billed cost row states \$0.00 plainly" || fail "billed row missing"
printf '%s' "$BLOCK" | grep -q '| Reviewer CLI version | ✅ | `codex/0.137` (#586) |' \
  && pass "captured CLI version renders green with evidence" || fail "cli version rigor row wrong"
printf '%s' "$BLOCK" | grep -q '| Local gates green | n/a | local gate results not captured for this run |' \
  && pass "uncaptured gate signal renders n/a with the reason (never a green check)" || fail "gates rigor row wrong"
printf '%s' "$BLOCK" | grep -q '\*Totals source: github-derived (24 prior record(s)).\*' \
  && pass "running-totals footer names the totals source" || fail "totals-source footer missing"
GATES_BLOCK="$(P4B_ACCT_GATES_EVIDENCE="check_phase_4b_automation 67/67 green" p4b_acct_render_block "$GOLDEN")"
printf '%s' "$GATES_BLOCK" | grep -q '| Local gates green | ✅ | check_phase_4b_automation 67/67 green |' \
  && pass "captured gate evidence renders the gates row green" || fail "gates evidence row wrong"

RT="$(printf '%s\n' "$BLOCK" | p4b_acct_extract_records)"
if [ "$(printf '%s' "$RT" | jq -S .)" = "$(printf '%s' "$GOLDEN" | jq -S .)" ]; then
  pass "embedded record round-trips: render → extract == original"
else fail "round-trip mismatch"; fi
RT_N="$(printf 'prose mentions p4b-accounting:v1 in passing\n%s\n' "$BLOCK" | p4b_acct_extract_records | wc -l | tr -d '[:space:]')"
[ "$RT_N" = "1" ] && pass "extractor keys on the comment-open, not bare marker prose" \
  || fail "extractor captured $RT_N records with marker prose present"
BADREC="$(printf '%s' "$GOLDEN" | jq -c '.loops[0].findings.P1 = 3')"
p4b_acct_render_block "$BADREC" >/dev/null \
  && fail "render_block rendered an illegal APPROVED record" \
  || pass "render_block refuses an APPROVED record carrying required findings (defense in depth)"
p4b_acct_render_block "not json" >/dev/null 2>&1 \
  && fail "render_block accepted junk" || pass "render_block refuses non-JSON input"

# ===========================================================================
echo "accounting.sh — running-totals aggregation"
# ===========================================================================
REC2="$(printf '%s' "$GOLDEN" | jq -c '.pr = 581 | .final_verdict = "CHANGES_REQUESTED"
  | .totals.tokens_total = 1000 | .totals.elapsed_seconds_total = 60
  | .totals.notional_usd = 0.10 | .totals.adapter_invocations = 2 | .totals.fail_closed_events = 0')"
agg="$(printf '%s\n%s\n%s\n' "$GOLDEN" "$REC2" "$GOLDEN" | p4b_acct_aggregate_running_totals github-derived)"
if printf '%s' "$agg" | jq -e '
    .source == "github-derived" and .records == 3
    and .auto_approved_prs == 2 and .automated_attempts == 10
    and .fail_closed_events == 2 and .tokens_total == 355408
    and .elapsed_seconds_total == 510 and .notional_usd == 1.42
    and .human_minutes_saved_estimate == [60, 360]' >/dev/null; then
  pass "aggregation over N records sums every metric and derives the human-minutes range"
else fail "aggregation: $agg"; fi
agg="$(printf '%s\ngarbage-line\n' "$GOLDEN" | p4b_acct_aggregate_running_totals ledger-cache)"
[ "$(printf '%s' "$agg" | jq -r '.source')" = "unavailable" ] \
  && pass "a malformed ledger line degrades the whole aggregation to unavailable (never wrong numbers)" \
  || fail "malformed line aggregation: $agg"
agg="$(printf '' | p4b_acct_aggregate_running_totals ledger-cache)"
if printf '%s' "$agg" | jq -e '.source == "ledger-cache" and .records == 0 and .human_minutes_saved_estimate == null' >/dev/null; then
  pass "empty prior input is a valid zero-record aggregation (first-ever approval)"
else fail "empty aggregation: $agg"; fi

PRIOR="$WORK/prior.jsonl"; printf '%s\n' "$GOLDEN" > "$PRIOR"
LEDGER="$WORK/ledger.jsonl"; printf '%s\n%s\n' "$GOLDEN" "$REC2" > "$LEDGER"
rt="$(P4B_ACCT_PRIOR_RECORDS_JSONL="$PRIOR" p4b_acct_running_totals_for_post "$LEDGER")"
[ "$(printf '%s' "$rt" | jq -r '.source + "/" + (.records | tostring)')" = "github-derived/1" ] \
  && pass "injected prior-records file wins (github-derived path)" || fail "source priority: $rt"
rt="$(p4b_acct_running_totals_for_post "$LEDGER")"
[ "$(printf '%s' "$rt" | jq -r '.source + "/" + (.records | tostring)')" = "ledger-cache/2" ] \
  && pass "ledger cache is the fallback source" || fail "ledger fallback: $rt"
rt="$(p4b_acct_running_totals_for_post "$WORK/no-such-ledger.jsonl")"
[ "$(printf '%s' "$rt" | jq -r '.source')" = "unavailable" ] \
  && pass "no source at all → explicit unavailable (never a guessed zero baseline)" \
  || fail "no-source: $rt"

# ===========================================================================
echo "accounting.sh — zero-finding + degraded rendering"
# ===========================================================================
ZLOOP="$(printf '%s' "$CLEAN_LOOP" | jq -c '.cli_version = null | .plan_auth = null')"
ZREC="$(p4b_acct_build_record 7 headzz APPROVED nathanpayne-codex "claude->codex" posted 12 \
  "[$ZLOOP]" "[]" \
  "$(p4b_acct_compute_totals "[$ZLOOP]" "" null '[]')" \
  '{"source":"unavailable","records":0,"reason":"no prior-record source"}' "2026-07-01T00:00:00Z")"
ZBLOCK="$(p4b_acct_render_block "$ZREC")"
printf '%s' "$ZBLOCK" | grep -q '_No findings recorded on the approved HEAD' \
  && pass "zero-finding approval names the rigor table as its proof-of-work" || fail "zero-finding text missing"
printf '%s' "$ZBLOCK" | grep -q '| Plan-only auth (no metered API) | n/a | plan-auth posture not captured' \
  && pass "missing plan-auth signal renders n/a, not a green check" || fail "plan-auth n/a row missing"
printf '%s' "$ZBLOCK" | grep -q '| Reviewer CLI version | n/a |' \
  && pass "missing CLI version renders n/a" || fail "cli-version n/a row missing"
printf '%s' "$ZBLOCK" | grep -q 'unavailable (no CLI-exposed counts)' \
  && pass "missing token totals render explicit unavailable with reason" || fail "token unavailable row missing"
printf '%s' "$ZBLOCK" | grep -q -- 'n/a — no price resolvable' \
  && pass "missing price renders notional n/a while the record still posts" || fail "notional n/a row missing"
printf '%s' "$ZBLOCK" | grep -q '_Running totals unavailable — no prior-record source._' \
  && pass "unavailable running totals render the degradation reason" || fail "running-totals degradation missing"
printf '%s' "$ZBLOCK" | grep -q '| Plan-capacity throttle events | not captured |' \
  && pass "uncaptured throttle events render as not captured (no fabricated 0)" || fail "throttle row wrong"

# ===========================================================================
echo "verdict.schema.json + lib.sh — additive nullable usage fields (#602)"
# ===========================================================================
# shellcheck source=../scripts/phase-4b/lib.sh
. "$LIB"
if p4b_validate_verdict '{"verdict":"APPROVED","summary":"ok","findings":[],"usage":{"token_count":150,"input_tokens":100,"output_tokens":50,"source":"claude-json-envelope"}}'; then
  pass "pre-#602 4-key usage still validates (additive change is backward compatible)"
else fail "legacy usage shape rejected"; fi
if p4b_validate_verdict '{"verdict":"APPROVED","summary":"ok","findings":[],"usage":{"token_count":150,"input_tokens":100,"output_tokens":50,"cache_creation_input_tokens":30,"cache_read_input_tokens":20,"reasoning_tokens":7,"total_cost_usd":0.42,"source":"claude-json-envelope"}}'; then
  pass "usage with all additive #602 fields validates"
else fail "extended usage shape rejected"; fi
if p4b_validate_verdict '{"verdict":"APPROVED","summary":"ok","findings":[],"usage":{"token_count":150,"input_tokens":100,"output_tokens":50,"cache_creation_input_tokens":null,"cache_read_input_tokens":null,"reasoning_tokens":null,"total_cost_usd":null,"source":"x"}}'; then
  pass "additive fields accept explicit null (nullable, never required)"
else fail "null additive fields rejected"; fi
if p4b_validate_verdict '{"verdict":"APPROVED","summary":"ok","findings":[],"usage":{"token_count":150,"input_tokens":100,"output_tokens":50,"bogus_key":1,"source":"x"}}'; then
  fail "unknown usage key accepted"
else pass "unknown usage key still rejected (additionalProperties stays closed)"; fi
if p4b_validate_verdict '{"verdict":"APPROVED","summary":"ok","findings":[],"usage":{"token_count":150,"input_tokens":100,"output_tokens":50,"cache_read_input_tokens":"lots","source":"x"}}'; then
  fail "non-integer cache count accepted"
else pass "mistyped additive field rejected"; fi
if p4b_validate_verdict '{"verdict":"APPROVED","summary":"ok","findings":[],"usage":{"token_count":150,"source":"x"}}'; then
  fail "usage missing required keys accepted"
else pass "usage missing schema-required keys still rejected"; fi

set +e
out="$(CLAUDE_BIN="$BIN/fake-claude-cache-usage" bash "$AD_CLAUDE" --pr 1 --repo o/r --diff-file "$DIFF")"; rc=$?
set -e
if [ "$rc" = 0 ] && printf '%s' "$out" | jq -e '
    .usage.cache_creation_input_tokens == 30
    and .usage.cache_read_input_tokens == 20
    and .usage.total_cost_usd == 0.42
    and .usage.token_count == 150' >/dev/null; then
  pass "claude adapter populates the additive usage fields from the CLI envelope (CLI-sourced only)"
else fail "claude adapter additive usage (rc=$rc, out=$out)"; fi

# ===========================================================================
echo "orchestrator — accounting hook (fail-open, exit codes preserved)"
# ===========================================================================
run_orch() { # run_orch <state-dir> <policy> <codex-fake> <pr> [extra env as VAR=VAL...] -- [extra args...]
  local state="$1" policy="$2" fake="$3" pr="$4"; shift 4
  local -a envs=()
  while [ $# -gt 0 ] && [ "$1" != "--" ]; do envs+=("$1"); shift; done
  [ "${1:-}" = "--" ] && shift
  env "${envs[@]:-_P4B_NOOP=1}" \
    PATH="$BIN:$PATH" \
    MERGEPATH_REVIEW_POLICY_PATH="$policy" \
    P4B_ACCT_STATE_DIR="$state" \
    CODEX_BIN="$BIN/$fake" \
    P4B_GH_AS_REVIEWER="$BIN/fake-gh-as-reviewer" \
    P4B_FAKE_LIVE_HEAD=abc123 \
    bash "$ORCH" "$pr" --repo o/r --author claude --head abc123 --diff-file "$DIFF" "$@"
}

# (a) APPROVED posted with accounting on → block embedded, record parses,
#     plain summary intact, ledger appended, exit 0.
STATE_A="$WORK/state-a"; BODY_A="$WORK/body-a.md"
set +e
out="$(run_orch "$STATE_A" "$POLICY_ON" fake-codex-approve 201 P4B_WRAPPER_BODY="$BODY_A" -- 2>/dev/null)"; rc=$?
set -e
REC_A="$(p4b_acct_extract_records < "$BODY_A" 2>/dev/null || true)"
if [ "$rc" = 0 ] \
   && grep -q '^## Phase 4b Approval Accounting' "$BODY_A" \
   && grep -q '^\*\*Automated Phase 4b review\*\*' "$BODY_A" \
   && [ -n "$REC_A" ] \
   && printf '%s' "$REC_A" | jq -e '.schema == "p4b-accounting/v1" and .pr == 201
        and .automation_state == "posted" and .final_verdict == "APPROVED"
        and (.loops | length) == 1 and .loops[0].verdict == "APPROVED"
        and .loops[0].posted == "posted" and .loops[0].plan_auth == "chatgpt"
        and .wall_time_first_loop_to_approval_seconds != null' >/dev/null \
   && [ "$(wc -l < "$STATE_A/phase-4b-ledger.jsonl" | tr -d '[:space:]')" = "1" ]; then
  pass "posted APPROVED embeds the accounting block + record, keeps the plain summary, appends the ledger, exit 0"
else fail "hook happy path (rc=$rc, body=$(cat "$BODY_A" 2>/dev/null | head -5), rec=$REC_A)"; fi
if printf '%s' "$REC_A" | jq -e '.running_totals.source == "unavailable"' >/dev/null 2>&1; then
  pass "first-ever post reports running totals unavailable (no prior source) rather than a guessed baseline"
else fail "first-post running totals: $REC_A"; fi

# (b) accounting sub-toggle off → plain summary only, exit 0, no state writes.
STATE_B="$WORK/state-b"; BODY_B="$WORK/body-b.md"
set +e
out="$(run_orch "$STATE_B" "$POLICY_ACCT_OFF" fake-codex-approve 202 P4B_WRAPPER_BODY="$BODY_B" -- 2>/dev/null)"; rc=$?
set -e
if [ "$rc" = 0 ] && ! grep -q 'Phase 4b Approval Accounting' "$BODY_B" && [ ! -d "$STATE_B" ]; then
  pass "accounting.enabled: false → plain summary, no state writes, exit 0"
else fail "sub-toggle off (rc=$rc)"; fi

# (c) forced report-generation error → plain summary posts, exit 0 (never
#     blocks or fabricates the approval).
STATE_C="$WORK/state-c"; BODY_C="$WORK/body-c.md"
set +e
out="$(run_orch "$STATE_C" "$POLICY_ON" fake-codex-approve 203 P4B_WRAPPER_BODY="$BODY_C" P4B_ACCT_SELFTEST_FAIL=1 -- 2>/dev/null)"; rc=$?
set -e
if [ "$rc" = 0 ] \
   && ! grep -q 'Phase 4b Approval Accounting' "$BODY_C" \
   && grep -q '^\*\*Automated Phase 4b review\*\*' "$BODY_C" \
   && grep -q 'Reviewed head: `abc123`' "$BODY_C"; then
  pass "report-generation error → plain-summary approval still posts with exit 0 (fail-open for reporting only)"
else fail "generation-error fallback (rc=$rc, body=$(cat "$BODY_C" 2>/dev/null | head -3))"; fi

# (d) changes-requested-then-fixed across two invocations: loop history
#     accumulates and the final approval renders both loops + the lifecycle.
STATE_D="$WORK/state-d"; BODY_D1="$WORK/body-d1.md"; BODY_D2="$WORK/body-d2.md"
set +e
run_orch "$STATE_D" "$POLICY_ON" fake-codex-changes 204 P4B_WRAPPER_BODY="$BODY_D1" -- >/dev/null 2>&1; rc1=$?
run_orch "$STATE_D" "$POLICY_ON" fake-codex-approve 204 P4B_WRAPPER_BODY="$BODY_D2" -- >/dev/null 2>&1; rc2=$?
set -e
REC_D="$(p4b_acct_extract_records < "$BODY_D2" 2>/dev/null || true)"
if [ "$rc1" = 1 ] && [ "$rc2" = 0 ] \
   && ! grep -q 'Phase 4b Approval Accounting' "$BODY_D1" \
   && [ -n "$REC_D" ] \
   && printf '%s' "$REC_D" | jq -e '
        (.loops | length) == 2
        and .loops[0].loop == 1 and .loops[0].verdict == "CHANGES_REQUESTED" and .loops[0].findings.P1 == 1
        and .loops[1].loop == 2 and .loops[1].verdict == "APPROVED" and .loops[1].findings.P1 == 0
        and (.unique_findings | length) == 1
        and .unique_findings[0].severity == "P1"
        and .unique_findings[0].first_loop == 1 and .unique_findings[0].last_loop == 1
        and .totals.adapter_invocations == 2' >/dev/null; then
  pass "changes-requested-then-fixed: exit codes 1 then 0 preserved; final record carries both loops + finding lifecycle"
else fail "CR-then-fixed (rc1=$rc1 rc2=$rc2, rec=$REC_D)"; fi

# (e) findings-bearing APPROVED verdict → existing fail-closed fallback (exit
#     4) preserved; the fail-closed loop is recorded as safety evidence.
STATE_E="$WORK/state-e"
set +e
run_orch "$STATE_E" "$POLICY_ON" fake-codex-approve-p2 205 -- --dry-run >/dev/null 2>&1; rc=$?
set -e
LOG_E="$(find "$STATE_E/phase-4b-loops" -name '*.jsonl' 2>/dev/null | head -n1)"
if [ "$rc" = 4 ] && [ -n "$LOG_E" ] \
   && jq -e -s '
        length == 1
        and .[0].loop.verdict == "APPROVED_WITH_ADVISORIES"
        and .[0].loop.fell_back == true
        and .[0].loop.fail_closed.happened == true
        and .[0].loop.findings.P2 == 1
        and (.[0].details | length) == 1' "$LOG_E" >/dev/null; then
  pass "findings-bearing approval still falls back (exit 4) and is recorded as a fail-closed loop with its histogram"
else fail "fail-closed recording (rc=$rc, log=$(cat "$LOG_E" 2>/dev/null))"; fi

# (f) dry-run APPROVED → exit 0, dry-run never contaminates the ledger cache.
STATE_F="$WORK/state-f"
set +e
run_orch "$STATE_F" "$POLICY_ON" fake-codex-approve 206 -- --dry-run >/dev/null 2>&1; rc=$?
set -e
if [ "$rc" = 0 ] && [ ! -e "$STATE_F/phase-4b-ledger.jsonl" ]; then
  pass "dry-run renders without appending the running-totals ledger"
else fail "dry-run ledger hygiene (rc=$rc)"; fi

# (g) parent automation disabled → exit 5 unchanged, zero accounting writes.
STATE_G="$WORK/state-g"
set +e
env PATH="$BIN:$PATH" MERGEPATH_REVIEW_POLICY_PATH="$POLICY_OFF" P4B_ACCT_STATE_DIR="$STATE_G" \
  bash "$ORCH" 207 --repo o/r >/dev/null 2>&1; rc=$?
set -e
if [ "$rc" = 5 ] && [ ! -d "$STATE_G" ]; then
  pass "disabled parent still exits 5 with no accounting side effects"
else fail "disabled parent (rc=$rc)"; fi

# (h) notional pricing end-to-end: configured price keys + CLI-exposed tokens
#     → labeled notional in the posted body and record.
STATE_H="$WORK/state-h"; BODY_H="$WORK/body-h.md"
set +e
out="$(run_orch "$STATE_H" "$POLICY_ACCT_PRICES" fake-codex-usage 208 \
  P4B_WRAPPER_BODY="$BODY_H" P4B_ACCT_PRICES_PATH="$TEST_PRICES" -- 2>/dev/null)"; rc=$?
set -e
REC_H="$(p4b_acct_extract_records < "$BODY_H" 2>/dev/null || true)"
# 1234 tokens · blended 4.0 per 1M = 0.004936 → 0.00 at cent rounding
if [ "$rc" = 0 ] && [ -n "$REC_H" ] \
   && printf '%s' "$REC_H" | jq -e '
        .totals.tokens_total == 1234
        and .totals.notional_usd == 0
        and .totals.price_table_version == "test-1"
        and .totals.billed_usd == 0' >/dev/null \
   && grep -q 'not billed; price table `test-1`' "$BODY_H"; then
  pass "configured price keys yield a stamped, labeled notional figure end-to-end"
else fail "notional end-to-end (rc=$rc, rec=$REC_H)"; fi

echo
echo "Summary: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
