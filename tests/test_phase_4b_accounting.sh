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
SKIP=0
pass() { echo "  PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*" >&2; FAIL=$((FAIL + 1)); }
skip() { echo "  SKIP: $*" >&2; SKIP=$((SKIP + 1)); }

# make_file_unappendable / restore_file — a ROOT-ROBUST unwritable seam
# (#615 Codex round 6). `chmod 0444` does NOT stop root from appending (the CI
# check_phase_4b_accounting job runs as root), so a permissions-only injection
# silently exercises the SUCCESS path there. As a non-root user chmod 0444 is
# enough; as root we fall back to the filesystem immutable flag (`chattr +i` on
# Linux, `chflags uchg`/`schg` on macOS/BSD), which blocks even root's own
# writes while keeping the file READABLE — exactly the read-only-log shape the
# render path needs. make_file_unappendable prints the token naming HOW it was
# locked (chmod|chattr|chflags) on success, or "unsupported" when running as
# root with no immutable-flag tool available (the caller then skips the
# injection-dependent assertion with a clear reason rather than passing on an
# unexercised failure path). restore_file undoes whichever lock was applied.
make_file_unappendable() {
  local f="$1"
  if [ "$(id -u)" -ne 0 ]; then
    chmod 0444 "$f" 2>/dev/null && { printf 'chmod'; return 0; }
  fi
  if command -v chattr >/dev/null 2>&1 && chattr +i "$f" 2>/dev/null; then
    printf 'chattr'; return 0
  fi
  if command -v chflags >/dev/null 2>&1 && chflags uchg "$f" 2>/dev/null; then
    printf 'chflags'; return 0
  fi
  # As root on Linux, chmod alone is not enough; only reachable if the
  # immutable-flag tools are missing or failed.
  printf 'unsupported'; return 1
}
restore_file() {
  local f="$1" how="$2"
  case "$how" in
    chattr)  chattr -i "$f" 2>/dev/null || true ;;
    chflags) chflags nouchg "$f" 2>/dev/null || true ;;
    *)       : ;;
  esac
  chmod 0644 "$f" 2>/dev/null || true
}

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

# #615 round 3 collision fixtures: the parent `enabled` is ABSENT (or comes
# AFTER the sub-block) while the nested accounting sub-toggle says true. The
# flat parent-block scanner used to read the nested key as the master switch.
POLICY_NESTED_ONLY="$WORK/policy-nested-only.yml"
cat > "$POLICY_NESTED_ONLY" <<'YAML'
available_reviewers:
  - nathanpayne-claude
  - nathanpayne-codex
default_external_reviewer: nathanpayne-codex
author_identity: nathanjohnpayne
phase_4b_automation:
  accounting:
    enabled: true
YAML
POLICY_NESTED_REORDER="$WORK/policy-nested-reorder.yml"
cat > "$POLICY_NESTED_REORDER" <<'YAML'
available_reviewers:
  - nathanpayne-claude
  - nathanpayne-codex
default_external_reviewer: nathanpayne-codex
phase_4b_automation:
  accounting:
    enabled: true
  enabled: false
  mode: local
YAML

# #615 round 3 trust fixture: automation on but NO registered reviewers —
# prior records cannot be attributed, so the fetch must fail closed.
POLICY_NO_REVIEWERS="$WORK/policy-no-reviewers.yml"
cat > "$POLICY_NO_REVIEWERS" <<'YAML'
default_external_reviewer: nathanpayne-codex
phase_4b_automation:
  enabled: true
  mode: local
YAML

# #615 round 4 indent fixtures: the SAME policies formatted with four-space
# children. The sub-block reader hardcoded the two-space style, so the
# nested accounting block was never entered — accounting.enabled: false read
# as ABSENT (default true) and an opted-out repo still got accounting.
POLICY_ACCT_OFF4="$WORK/policy-acct-off-4space.yml"
cat > "$POLICY_ACCT_OFF4" <<'YAML'
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
POLICY_ACCT_PRICES4="$WORK/policy-acct-prices-4space.yml"
cat > "$POLICY_ACCT_PRICES4" <<'YAML'
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
YAML
# Guard: an `accounting:` header nested INSIDE another sub-block is not the
# accounting sub-block — its keys must never resolve (direct children only,
# mirroring the round-3 p4b_automation_field semantics).
POLICY_ACCT_DEEP="$WORK/policy-acct-deep.yml"
cat > "$POLICY_ACCT_DEEP" <<'YAML'
available_reviewers:
  - nathanpayne-claude
default_external_reviewer: nathanpayne-codex
phase_4b_automation:
  enabled: true
  some_future_block:
    accounting:
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
# Claude envelope exposing ONLY a cost — no token counts at all (#615 round
# 11, Codex P2): the adapter must still emit a usage object carrying the cost.
mk_fake fake-claude-cost-only \
  "jq -n --arg r '{\"verdict\":\"APPROVED\",\"summary\":\"ok\",\"findings\":[]}' '{type:\"result\",subtype:\"success\",result:\$r,session_id:\"t\",total_cost_usd:0.37}'"

cat > "$BIN/gh" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = "api" ]; then
  case "${2:-}" in
    repos/o/r/pulls/*)
      printf '%s\n' "${P4B_FAKE_LIVE_HEAD:-abc123}"
      exit 0
      ;;
    graphql)
      # Prior-record fetch shim (#615 rounds 2+3): serves the raw GraphQL
      # response JSON the real read-only call returns (the fetch now parses
      # author logins + pageInfo locally). Default is a successful EMPTY
      # fetch (a repo with no prior records).
      if [ -n "${P4B_FAKE_GRAPHQL_FAIL:-}" ]; then
        echo "simulated graphql failure" >&2
        exit 1
      fi
      # Stalled-read simulation (#615 round 8, finding 2): sleep so the
      # bounded fetch's timeout fires. The sleep must OUTLAST the timeout for
      # the wrapper to interrupt it; a real hung network read is unbounded.
      if [ -n "${P4B_FAKE_GRAPHQL_SLEEP:-}" ]; then
        sleep "${P4B_FAKE_GRAPHQL_SLEEP}"
      fi
      # Multi-page fixtures (#615 round 3): the endCursor of page N names
      # the NEXT page's fixture file; no `after` arg serves page1.json.
      if [ -n "${P4B_FAKE_GRAPHQL_PAGE_DIR:-}" ]; then
        after=""
        for a in "$@"; do
          case "$a" in after=*) after="${a#after=}" ;; esac
        done
        pagefile="${P4B_FAKE_GRAPHQL_PAGE_DIR}/${after:-page1}.json"
        if [ -f "$pagefile" ]; then cat "$pagefile"; exit 0; fi
        echo "no fixture page: $pagefile" >&2
        exit 1
      fi
      # Single-page single-review body fixture; author defaults to a
      # registered reviewer identity so pre-round-3 tests stay valid.
      if [ -n "${P4B_FAKE_PRIOR_BODIES:-}" ] && [ -f "${P4B_FAKE_PRIOR_BODIES}" ]; then
        jq -Rs --arg login "${P4B_FAKE_PRIOR_AUTHOR:-nathanpayne-codex}" '
          {data:{repository:{pullRequests:{
            pageInfo:{hasNextPage:false, endCursor:null},
            nodes:[{reviews:{nodes:[{author:{login:$login}, body:.}]}}]}}}}' \
          "${P4B_FAKE_PRIOR_BODIES}"
        exit 0
      fi
      printf '%s\n' '{"data":{"repository":{"pullRequests":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[]}}}}'
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
if [ -n "${P4B_FAKE_WRAPPER_FAIL:-}" ]; then
  echo "simulated review POST failure" >&2
  exit 1
fi
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
  {"loop":1,"reviewer":"nathanpayne-codex","adapter":"review-via-codex.sh","direction":"claude->codex","head_sha":"d05ff4d0…","verdict":"APPROVED","posted":"direct-probe","fell_back":false,"elapsed_seconds":18,"tokens":{"total":55926,"input":null,"output":null,"cache_creation":null,"cache_read":null,"reasoning":null,"cost_usd":null,"source":"codex-stderr"},"findings":{"P0":0,"P1":0,"P2":0,"P3":0,"nitpick":0,"unknown":0},"cli_version":"codex/0.137","timeout_seconds":900,"effort":null,"throttle_events":1,"plan_auth":"chatgpt","fail_closed":{"happened":false,"reason":null,"duration_seconds":null}},
  {"loop":2,"reviewer":"nathanpayne-codex","adapter":"orchestrator-dry-run","direction":"claude->codex","head_sha":"d05ff4d0…","verdict":"APPROVED","posted":"dry-run","fell_back":false,"elapsed_seconds":65,"tokens":{"total":113918,"input":null,"output":null,"cache_creation":null,"cache_read":null,"reasoning":null,"cost_usd":null,"source":"codex-stderr"},"findings":{"P0":0,"P1":0,"P2":0,"P3":0,"nitpick":0,"unknown":0},"cli_version":"codex/0.137","timeout_seconds":900,"effort":null,"throttle_events":0,"plan_auth":"chatgpt","fail_closed":{"happened":false,"reason":null,"duration_seconds":null}},
  {"loop":3,"reviewer":"nathanpayne-claude","adapter":"review-via-claude.sh","direction":"codex->claude","head_sha":"d05ff4d0…","verdict":"APPROVED_WITH_ADVISORIES","posted":"direct-probe","fell_back":false,"elapsed_seconds":66,"tokens":{"total":7360,"input":1589,"output":5771,"cache_creation":null,"cache_read":null,"reasoning":null,"cost_usd":null,"source":"claude-json"},"findings":{"P0":0,"P1":0,"P2":2,"P3":2,"nitpick":0,"unknown":0},"cli_version":null,"timeout_seconds":900,"effort":"medium","throttle_events":0,"plan_auth":"firstParty","fail_closed":{"happened":false,"reason":null,"duration_seconds":null}},
  {"loop":4,"reviewer":"nathanpayne-claude","adapter":"orchestrator-dry-run","direction":"codex->claude","head_sha":"d05ff4d0…","verdict":"CHANGES_REQUESTED","posted":"not-posted","fell_back":true,"elapsed_seconds":76,"tokens":{"total":null,"input":null,"output":null,"cache_creation":null,"cache_read":null,"reasoning":null,"cost_usd":null,"source":"unavailable"},"findings":{"P0":0,"P1":0,"P2":null,"P3":null,"nitpick":null,"unknown":null},"cli_version":null,"timeout_seconds":900,"effort":"medium","throttle_events":0,"plan_auth":"firstParty","fail_closed":{"happened":true,"reason":"approval-carried-findings","duration_seconds":76}}
 ],
 "unique_findings":[
  {"id":"F1","severity":"P2","path":null,"line":null,"title":"Codex `--output-schema` vs jq validator drift (`line` min)","first_loop":3,"last_loop":3,"disposition":"deferred-to-follow-up","fix_commit":null,"issue":585},
  {"id":"F2","severity":"P2","path":null,"line":null,"title":"Record reviewer CLI version before enablement","first_loop":3,"last_loop":3,"disposition":"deferred-to-follow-up","fix_commit":null,"issue":586},
  {"id":"F3","severity":"P3","path":null,"line":null,"title":"Harden Claude JSON extraction beyond first/last brace","first_loop":3,"last_loop":3,"disposition":"deferred-to-follow-up","fix_commit":null,"issue":587},
  {"id":"F4","severity":"P3","path":null,"line":null,"title":"Make local shellcheck absence more visible","first_loop":3,"last_loop":3,"disposition":"deferred-to-follow-up","fix_commit":null,"issue":588}
 ],
 "totals":{"adapter_invocations":4,"tokens_total":177204,"tokens_by_provider":{"codex":169844,"claude":7360},"elapsed_seconds_total":225,"billed_usd":0.0,"notional_usd":0.66,"reported_cost_usd":null,"price_table_version":"2026-07-01","fail_closed_events":1,"advisory_issues_filed":[585,586,587,588]},
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
# #615 round 4 (fails pre-fix): a four-space-indented policy never entered
# the nested accounting block, so an explicit opt-out was silently ignored.
MERGEPATH_REVIEW_POLICY_PATH="$POLICY_ACCT_OFF4" p4b_acct_config_enabled \
  && fail "four-space accounting.enabled: false ignored (opt-out must work at any consistent indent)" \
  || pass "four-space-indented accounting.enabled: false disables the sub-toggle (#615 round 4)"
# (fails pre-fix) …and price keys under four-space children were ignored too.
v="$(MERGEPATH_REVIEW_POLICY_PATH="$POLICY_ACCT_PRICES4" p4b_acct_config_field codex_price_key)"
[ "$v" = "testprov.model-x.standard" ] \
  && pass "four-space nested reader resolves price keys (strips trailing comment)" \
  || fail "four-space codex_price_key -> '$v'"
MERGEPATH_REVIEW_POLICY_PATH="$POLICY_ACCT_PRICES4" p4b_acct_config_enabled \
  && pass "four-space accounting.enabled: true honored" \
  || fail "four-space explicit enabled true rejected"
# Guard (passes pre- and post-fix): an accounting: header nested inside some
# OTHER sub-block is not phase_4b_automation.accounting — direct children only.
MERGEPATH_REVIEW_POLICY_PATH="$POLICY_ACCT_DEEP" p4b_acct_config_enabled \
  && pass "a deeper-nested accounting: block never shadows the real sub-block (direct children only)" \
  || fail "deep-nested accounting.enabled: false wrongly resolved as the sub-toggle"

# ===========================================================================
echo "accounting.sh — verdict → accounting mappers"
# ===========================================================================
t="$(p4b_acct_tokens_from_verdict '{"verdict":"APPROVED","summary":"x","findings":[],"usage":null}')"
[ "$(printf '%s' "$t" | jq -r '.source')" = "unavailable" ] \
  && [ "$(printf '%s' "$t" | jq -r '.total')" = "null" ] \
  && [ "$(printf '%s' "$t" | jq -r '.cost_usd')" = "null" ] \
  && pass "null usage → all-null tokens (incl. cost_usd) with explicit source=unavailable (never estimated)" \
  || fail "null-usage tokens mapping: $t"
t="$(p4b_acct_tokens_from_verdict '{"verdict":"APPROVED","summary":"x","findings":[],"usage":{"token_count":150,"input_tokens":100,"output_tokens":50,"cache_creation_input_tokens":30,"cache_read_input_tokens":20,"reasoning_tokens":7,"total_cost_usd":0.42,"source":"claude-json-envelope"}}')"
if printf '%s' "$t" | jq -e '.total == 150 and .input == 100 and .output == 50 and .cache_creation == 30 and .cache_read == 20 and .reasoning == 7 and .source == "claude-json-envelope"' >/dev/null; then
  pass "full usage (incl. additive #602 fields) maps onto the accounting token names"
else fail "full-usage tokens mapping: $t"; fi
# #615 round 2 (fails pre-fix): the mapper used to DROP total_cost_usd, so
# records could only ever show notional or n/a even when the CLI reported a
# real cost.
if printf '%s' "$t" | jq -e '.cost_usd == 0.42' >/dev/null; then
  pass "CLI-reported total_cost_usd is preserved as tokens.cost_usd (#615 round 2)"
else fail "cost_usd dropped by the mapper: $t"; fi

# #615 round 6 (fails pre-fix): a schema-valid split-only envelope exposes
# input_tokens + output_tokens but token_count: null. Pre-fix `total` stayed
# null, so downstream totals/loop-table reported usage unavailable despite an
# EXACT split. total is now derived as input+output (never a guess).
t_split="$(p4b_acct_tokens_from_verdict '{"verdict":"APPROVED","summary":"x","findings":[],"usage":{"token_count":null,"input_tokens":100,"output_tokens":50,"source":"split-only-cli"}}')"
if printf '%s' "$t_split" | jq -e '.total == 150 and .input == 100 and .output == 50 and .source == "split-only-cli"' >/dev/null; then
  pass "split-only envelope (token_count null, both splits present) derives total = input+output (#615 round 6)"
else fail "split-total derivation: $t_split"; fi
# never-guess: token_count null and either split absent/null → total stays null.
t_partial="$(p4b_acct_tokens_from_verdict '{"verdict":"APPROVED","summary":"x","findings":[],"usage":{"token_count":null,"input_tokens":100,"output_tokens":null,"source":"x"}}')"
if printf '%s' "$t_partial" | jq -e '.total == null and .input == 100 and .output == null' >/dev/null; then
  pass "split derivation stays null when either split is absent (never-guess preserved) (#615 round 6)"
else fail "partial-split must stay null-total: $t_partial"; fi
# an explicit reported token_count always wins over the split (even if it
# differs) — a reported total is never overwritten by a derivation.
t_both="$(p4b_acct_tokens_from_verdict '{"verdict":"APPROVED","summary":"x","findings":[],"usage":{"token_count":200,"input_tokens":100,"output_tokens":50,"source":"x"}}')"
if printf '%s' "$t_both" | jq -e '.total == 200' >/dev/null; then
  pass "an explicit token_count is preferred over the input+output split (#615 round 6)"
else fail "token_count must win over split: $t_both"; fi
# The derived total must reach the downstream consumers Codex named: the
# per-approval totals and the loop-table cell (#615 round 6). Build a loop
# whose tokens came from a split-only envelope and check both surfaces report
# 150, not "unavailable".
loop_split="$(jq -nc --argjson tok "$t_split" '
  {loop:1,reviewer:"nathanpayne-codex",adapter:"review-via-codex.sh",
   direction:"claude->codex",head_sha:"h",verdict:"APPROVED",posted:"posted",
   fell_back:false,elapsed_seconds:5,tokens:$tok,
   findings:{P0:0,P1:0,P2:0,P3:0,nitpick:0,unknown:0},cli_version:null,
   timeout_seconds:900,effort:null,throttle_events:null,plan_auth:"chatgpt",
   fail_closed:{happened:false,reason:null,duration_seconds:null}}')"
tot_split="$(p4b_acct_compute_totals "[$loop_split]" "" "null")"
cell_split="$(p4b_acct_fmt_tokens_cell "$t_split")"
if printf '%s' "$tot_split" | jq -e '.tokens_total == 150 and .tokens_by_provider.codex == 150' >/dev/null \
   && grep -q '^150 (split-only-cli: in 100 / out 50)$' <<<"$cell_split"; then
  pass "the derived total flows into per-approval totals and the loop-table cell, not 'unavailable' (#615 round 6)"
else fail "derived-total downstream (totals=$tot_split cell=$cell_split)"; fi

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
# #615 Codex: unique findings carry content (path/line/title) so the posted
# record is reconstructable without local files — never the full body.
if printf '%s' "$uf" | jq -e '
    .[0].path == "a.js" and .[0].line == 3 and .[0].title == "dup"
    and .[1].path == null and .[1].line == null and .[1].title == "solo"' >/dev/null; then
  pass "unique findings carry path/line/title content (#615)"
else fail "unique-finding content: $uf"; fi
LONGBODY="$(printf 'A%.0s' $(seq 1 100))"
uf="$(printf '{"loop":1,"severity":"P2","path":"b.js","line":1,"body":"%s"}\n' "$LONGBODY" \
  | p4b_acct_unique_findings)"
if printf '%s' "$uf" | jq -e '.[0].title | (length == 80) and endswith("…") and startswith("AAAA")' >/dev/null; then
  pass "title truncates a long body to 80 chars with an ellipsis (never the full body)"
else fail "title truncation: $uf"; fi
uf="$(printf '{"loop":1,"severity":"P2","path":"b.js","line":1,"body":"first line\\nsecond line"}\n' \
  | p4b_acct_unique_findings)"
if printf '%s' "$uf" | jq -e '.[0].title == "first line"' >/dev/null; then
  pass "title keeps only the first body line"
else fail "multi-line title: $uf"; fi
uf="$(printf '%s\n' '{"loop":1,"severity":"P2","path":"a.js","line":3,"body":"dup"}' \
  | p4b_acct_unique_findings '{"F1":{"disposition":"deferred-to-follow-up","issue":585}}')"
if printf '%s' "$uf" | jq -e '.[0].disposition == "deferred-to-follow-up" and .[0].issue == 585' >/dev/null; then
  pass "explicit dispositions map applies (issue link recorded)"
else fail "dispositions map: $uf"; fi
uf="$(printf '' | p4b_acct_unique_findings)"
[ "$uf" = "[]" ] && pass "zero findings → empty unique_findings array" || fail "empty details -> $uf"

# Collision-proof de-dupe key (#615 Codex round 9, finding 3). FAILS pre-fix:
# the old key joined (severity, path, line, body) with a raw "|", so two
# DISTINCT findings whose content contains "|" produced the same string key and
# collapsed into ONE lifecycle entry (undercount + one disposition smeared over
# two issues). Here:
#   A = (P2, path="a",     line=1, body="b|2|c")  → old key "P2|a|1|b|2|c"
#   B = (P2, path="a|1|b", line=2, body="c")      → old key "P2|a|1|b|2|c"  (SAME!)
# Post-fix the key is the JSON-encoded tuple array, which cannot be forged by
# content: the two findings stay distinct (F1, F2), each with its own lifecycle.
uf="$(printf '%s\n%s\n' \
  '{"loop":1,"severity":"P2","path":"a","line":1,"body":"b|2|c"}' \
  '{"loop":2,"severity":"P2","path":"a|1|b","line":2,"body":"c"}' \
  | p4b_acct_unique_findings)"
if printf '%s' "$uf" | jq -e 'length == 2
    and .[0].id == "F1" and .[0].path == "a" and .[0].line == 1
    and .[0].first_loop == 1 and .[0].last_loop == 1
    and .[1].id == "F2" and .[1].path == "a|1|b" and .[1].line == 2
    and .[1].first_loop == 2 and .[1].last_loop == 2' >/dev/null; then
  pass "two distinct findings whose content contains the old '|' separator stay distinct (collision-proof key, finding 3)"
else fail "pipe-in-content dedup collision: $uf"; fi
# A genuine repeat still dedupes: identical tuples (incl. a body containing "|")
# collapse to one entry with a first/last lifecycle spanning both loops.
uf="$(printf '%s\n%s\n' \
  '{"loop":1,"severity":"P1","path":"p|q","line":5,"body":"x|y|z"}' \
  '{"loop":3,"severity":"P1","path":"p|q","line":5,"body":"x|y|z"}' \
  | p4b_acct_unique_findings)"
if printf '%s' "$uf" | jq -e 'length == 1
    and .[0].first_loop == 1 and .[0].last_loop == 3' >/dev/null; then
  pass "an identical finding (pipe-bearing content) across loops still dedupes to one lifecycle entry (finding 3)"
else fail "pipe-bearing repeat dedup: $uf"; fi

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

TOK_SPLIT='{"total":150,"input":100,"output":50,"cache_creation":null,"cache_read":null,"reasoning":null,"cost_usd":null,"source":"x"}'
n="$(p4b_acct_notional_from_tokens "$TOK_SPLIT" "testprov.model-x.standard" '["input","output"]')"
if printf '%s' "$n" | jq -e '. > 0.0006999 and . < 0.0007001' >/dev/null; then
  pass "split notional math exact (100·2 + 50·10 per-1M = 0.0007)"
else fail "split notional -> '$n'"; fi
TOK_TOTAL='{"total":1000000,"input":null,"output":null,"cache_creation":null,"cache_read":null,"reasoning":null,"cost_usd":null,"source":"x"}'
n="$(p4b_acct_notional_from_tokens "$TOK_TOTAL" "testprov.model-x.standard" '["total_only_blended_80_20"]')"
if printf '%s' "$n" | jq -e '. == 4.0' >/dev/null; then
  pass "total-only blended math exact (1M · 4.0)"
else fail "blended notional -> '$n'"; fi
TOK_CACHE='{"total":200,"input":100,"output":50,"cache_creation":40,"cache_read":10,"reasoning":null,"cost_usd":null,"source":"x"}'
n="$(p4b_acct_notional_auto "$TOK_CACHE" "testprov.model-y.standard")"
if printf '%s' "$n" | jq -e '(. * 1000000 | round) == 2210' >/dev/null; then
  pass "auto pricing includes counted cache components (in+out+cache_write+cache_read)"
else fail "auto cache notional -> '$n'"; fi
p4b_acct_notional_from_tokens '{"total":null,"input":null,"output":null,"cache_creation":null,"cache_read":null,"reasoning":null,"cost_usd":null,"source":"unavailable"}' "testprov.model-x.standard" '["input","output"]' >/dev/null \
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
 {"loop":1,"reviewer":"nathanpayne-codex","adapter":"review-via-codex.sh","direction":"claude->codex","tokens":{"total":1000000,"input":null,"output":null,"cache_creation":null,"cache_read":null,"reasoning":null,"cost_usd":null,"source":"codex-stderr"}},
 {"loop":2,"reviewer":"nathanpayne-claude","adapter":"review-via-claude.sh","direction":"codex->claude","tokens":{"total":150,"input":100,"output":50,"cache_creation":null,"cache_read":null,"reasoning":null,"cost_usd":null,"source":"claude-json"}},
 {"loop":3,"reviewer":"nathanpayne-claude","adapter":"orchestrator-dry-run","direction":"codex->claude","tokens":{"total":null,"input":null,"output":null,"cache_creation":null,"cache_read":null,"reasoning":null,"cost_usd":null,"source":"unavailable"}}
]'
n="$(MERGEPATH_REVIEW_POLICY_PATH="$POLICY_ACCT_PRICES" p4b_acct_notional_for_loops "$LOOPS_MIXED")"
# codex loop: 1M · blended 4.0 = 4.0 ; claude loop: 100·10 + 50·20 per-1M = 0.002 ; rounded → 4.0
if printf '%s' "$n" | jq -e '. == 4.0' >/dev/null; then
  pass "per-loop notional sums priced loops and skips token-less loops (rounded to cents)"
else fail "notional_for_loops -> '$n'"; fi
MERGEPATH_REVIEW_POLICY_PATH="$POLICY_ON" p4b_acct_notional_for_loops "$LOOPS_MIXED" >/dev/null \
  && fail "unpriced loops summed without configured keys" \
  || pass "no configured price key → non-zero (fail-closed to n/a, no partial figure)"
LOOPS_NOTOK='[{"loop":1,"reviewer":"nathanpayne-codex","adapter":"a","direction":"claude->codex","tokens":{"total":null,"input":null,"output":null,"cache_creation":null,"cache_read":null,"reasoning":null,"cost_usd":null,"source":"unavailable"}}]'
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
tt="$(p4b_acct_compute_totals '[{"loop":1,"reviewer":"nathanpayne-codex","adapter":"a","direction":"claude->codex","elapsed_seconds":null,"tokens":{"total":null,"input":null,"output":null,"cache_creation":null,"cache_read":null,"reasoning":null,"cost_usd":null,"source":"unavailable"},"fail_closed":{"happened":false,"reason":null,"duration_seconds":null}}]' "" "null" '[]')"
if printf '%s' "$tt" | jq -e '.tokens_total == null and .elapsed_seconds_total == null and .notional_usd == null and .price_table_version == null' >/dev/null; then
  pass "totals degrade to explicit null when nothing was measured (never a fabricated 0)"
else fail "degraded totals: $tt"; fi
# #615 round 2 (fails pre-fix): CLI-reported per-loop costs must reach the
# totals, fail-closed — a token-bearing loop WITHOUT a reported cost nulls
# the sum (a partial sum would silently underreport), while loops with
# nothing measured contribute nothing and never block.
mkcostloop() { # mkcostloop <n> <tokens-json>
  jq -nc --argjson n "$1" --argjson tokens "$2" '
    {loop:$n, reviewer:"nathanpayne-claude", adapter:"review-via-claude.sh",
     direction:"codex->claude", elapsed_seconds:9, tokens:$tokens,
     fail_closed:{happened:false, reason:null, duration_seconds:null}}'
}
COST_TOK='{"total":150,"input":100,"output":50,"cache_creation":null,"cache_read":null,"reasoning":null,"cost_usd":0.42,"source":"claude-json"}'
NOCOST_TOK='{"total":1000,"input":null,"output":null,"cache_creation":null,"cache_read":null,"reasoning":null,"cost_usd":null,"source":"codex-stderr"}'
NOTOK_TOK='{"total":null,"input":null,"output":null,"cache_creation":null,"cache_read":null,"reasoning":null,"cost_usd":null,"source":"unavailable"}'
CL_COST="$(mkcostloop 1 "$COST_TOK")"
CL_NOCOST="$(mkcostloop 2 "$NOCOST_TOK")"
CL_NOTOK="$(mkcostloop 3 "$NOTOK_TOK")"
CL_COST2="$(mkcostloop 4 "$(printf '%s' "$COST_TOK" | jq -c '.cost_usd = 0.081')")"
tt="$(p4b_acct_compute_totals "[$CL_COST]" "" null '[]')"
printf '%s' "$tt" | jq -e '.reported_cost_usd == 0.42' >/dev/null \
  && pass "a CLI-reported loop cost is carried into totals.reported_cost_usd (#615 round 2)" \
  || fail "reported cost dropped: $tt"
tt="$(p4b_acct_compute_totals "[$CL_COST,$CL_NOTOK]" "" null '[]')"
printf '%s' "$tt" | jq -e '.reported_cost_usd == 0.42' >/dev/null \
  && pass "an unmeasured loop does not block the reported sum" \
  || fail "unmeasured loop blocked reported cost: $tt"
tt="$(p4b_acct_compute_totals "[$CL_COST,$CL_NOCOST]" "" null '[]')"
printf '%s' "$tt" | jq -e '.reported_cost_usd == null' >/dev/null \
  && pass "a token-bearing loop without a reported cost fail-closes the sum to null (never a partial underreport)" \
  || fail "partial reported sum emitted: $tt"
tt="$(p4b_acct_compute_totals "[$CL_COST,$CL_COST2]" "" null '[]')"
printf '%s' "$tt" | jq -e '.reported_cost_usd == 0.5' >/dev/null \
  && pass "reported costs sum across loops and round to cents (0.42 + 0.081 → 0.5)" \
  || fail "reported sum/rounding: $tt"

# ===========================================================================
echo "accounting.sh — fail-closed posting-rule assertion + record builder"
# ===========================================================================
mkloop() { # mkloop <n> <verdict> <P0> <P1> <fail_closed_bool> [head]
  jq -nc --argjson n "$1" --arg v "$2" --argjson p0 "$3" --argjson p1 "$4" --argjson fc "$5" \
    --arg head "${6:-abc123}" '
    {loop:$n, reviewer:"nathanpayne-codex", adapter:"review-via-codex.sh",
     direction:"claude->codex", head_sha:$head, verdict:$v,
     posted:(if $fc then "not-posted" else "posted" end), fell_back:$fc,
     elapsed_seconds:10,
     tokens:{total:null,input:null,output:null,cache_creation:null,cache_read:null,reasoning:null,cost_usd:null,source:"unavailable"},
     findings:{P0:$p0,P1:$p1,P2:0,P3:0,nitpick:0,unknown:0},
     cli_version:null, timeout_seconds:900, effort:null, throttle_events:null,
     plan_auth:"chatgpt",
     fail_closed:{happened:$fc, reason:(if $fc then "test" else null end),
                  duration_seconds:(if $fc then 10 else null end)}}'
}
CLEAN_LOOP="$(mkloop 1 APPROVED 0 0 false)"
CR_LOOP="$(mkloop 1 CHANGES_REQUESTED 0 1 false)"
# A REAL fix advances the head: the CR loop's P1 is on abc123, and the approval
# lands on def456 (a new commit). Same-head reruns are covered separately below.
FIXED_LOOP="$(mkloop 2 APPROVED 0 0 false def456)"
BAD_APPROVED_LOOP="$(mkloop 1 APPROVED 0 1 false)"
GUARDED_BAD_LOOP="$(mkloop 2 APPROVED_WITH_ADVISORIES 0 1 true def456)"

p4b_acct_assert_no_required_with_approved "APPROVED" "[$CLEAN_LOOP]" \
  && pass "zero-finding APPROVED passes the posting-rule assertion" \
  || fail "clean APPROVED rejected"
p4b_acct_assert_no_required_with_approved "APPROVED" "[$CR_LOOP,$FIXED_LOOP]" def456 \
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
p4b_acct_assert_no_required_with_approved "APPROVED" "[$CR_LOOP,$FIXED_LOOP,$GUARDED_BAD_LOOP]" def456 \
  && pass "a fail-closed-guarded findings-bearing approval is recorded history, not a violation" \
  || fail "guarded fail-closed loop wrongly poisons the record"
p4b_acct_assert_no_required_with_approved "APPROVED" "$GOLDEN_LOOPS" \
  && pass "golden loop history passes the assertion" || fail "golden loops refused"

RT_ZERO='{"source":"unavailable","records":0,"reason":"test"}'
# --- Same-head unresolved required finding (#615 round 8, finding 3) ---------
# FAILS pre-fix (the two-argument checks accept a CR-P1-then-clean-APPROVED on
# the SAME head): the loop log only rotates after an approval posts, so a CR
# loop with a P1 on abc123 survives a rerun-without-commit that returns a clean
# APPROVED for the SAME abc123. Approving that would record a clean approval for
# a head whose required finding was never fixed.
CR_SAMEHEAD="$(mkloop 1 CHANGES_REQUESTED 0 1 false abc123)"
RERUN_APPROVED_SAMEHEAD="$(mkloop 2 APPROVED 0 0 false abc123)"
p4b_acct_assert_no_required_with_approved "APPROVED" "[$CR_SAMEHEAD,$RERUN_APPROVED_SAMEHEAD]" abc123 \
  && fail "same-head rerun laundered an unresolved P1 into a clean approval" \
  || pass "a clean APPROVED on the SAME head as an earlier unresolved required finding fails closed (finding 3)"
# The fix path — the approval lands on a NEW head (def456) — still passes: the
# required finding on abc123 was addressed by a real commit.
p4b_acct_assert_no_required_with_approved "APPROVED" "[$CR_SAMEHEAD,$FIXED_LOOP]" def456 \
  && pass "an approval on a NEW head clears the earlier required finding (real fix commit)" \
  || fail "new-head fix wrongly rejected by the same-head guard"
# A P0 case on the same head is likewise rejected.
CR_SAMEHEAD_P0="$(jq -c '.findings.P0 = 1 | .findings.P1 = 0' <<<"$CR_SAMEHEAD")"
p4b_acct_assert_no_required_with_approved "APPROVED" "[$CR_SAMEHEAD_P0,$RERUN_APPROVED_SAMEHEAD]" abc123 \
  && fail "same-head rerun laundered an unresolved P0" \
  || pass "a same-head unresolved P0 fails closed too (finding 3)"
# A fail-closed-marked same-head required finding is legitimate recorded history
# (it was already refused as an approval) and does NOT re-block.
CR_SAMEHEAD_GUARDED="$(mkloop 1 APPROVED_WITH_ADVISORIES 0 1 true abc123)"
p4b_acct_assert_no_required_with_approved "APPROVED" "[$CR_SAMEHEAD_GUARDED,$RERUN_APPROVED_SAMEHEAD]" abc123 \
  && pass "a fail-closed-marked same-head required finding is history, not a re-block (finding 3)" \
  || fail "guarded same-head loop wrongly re-blocked"
# Omitting the final head (or passing 'unknown') skips the same-head guard —
# backward-compatible with the original two-argument contract.
p4b_acct_assert_no_required_with_approved "APPROVED" "[$CR_SAMEHEAD,$RERUN_APPROVED_SAMEHEAD]" \
  && pass "no final head supplied ⇒ same-head guard skipped (backward-compatible contract)" \
  || fail "two-argument call wrongly enforced the same-head guard"
# --- same_head_only mode (#615 round 9, CodeRabbit; fails pre-fix) -----------
# The approval-time hook runs this assertion against the LIVE loop log, where
# the current loop can be legitimately absent (its record append failed). Full
# mode would then demand a clean APPROVED loop that is not in the log and
# refuse a VALID head-advanced approval; same_head_only applies exactly the
# laundering clause and nothing record-scoped.
p4b_acct_assert_no_required_with_approved "APPROVED" "[$CR_SAMEHEAD]" def456 same_head_only \
  && pass "same_head_only: head-advanced approval passes with only a prior CR-P1 loop in the log (current loop unrecorded) (round 9 CodeRabbit)" \
  || fail "same_head_only wrongly refused a head-advanced approval whose current loop is unrecorded"
p4b_acct_assert_no_required_with_approved "APPROVED" "[$CR_SAMEHEAD]" def456 \
  && fail "full mode accepted a final APPROVED with no clean approved loop (record-context regression)" \
  || pass "full mode still requires the clean APPROVED loop (record context unchanged)"
p4b_acct_assert_no_required_with_approved "APPROVED" "[$CR_SAMEHEAD]" abc123 same_head_only \
  && fail "same_head_only laundered a same-head unresolved P1" \
  || pass "same_head_only still fails closed on a same-head unresolved required finding"
p4b_acct_assert_no_required_with_approved "APPROVED" "[$CR_SAMEHEAD]" def456 bogus-mode \
  && fail "an unrecognized mode weakened the assertion (must behave as full)" \
  || pass "an unrecognized mode falls back to full (stricter is the safe direction)"
# build_record threads its final-head argument into the guard: a same-head
# rerun record is REFUSED (fails pre-fix).
p4b_acct_build_record 55 abc123 APPROVED nathanpayne-codex "claude->codex" posted "" \
  "[$CR_SAMEHEAD,$RERUN_APPROVED_SAMEHEAD]" "[]" \
  "$(p4b_acct_compute_totals "[$CR_SAMEHEAD,$RERUN_APPROVED_SAMEHEAD]" "" null '[]')" "$RT_ZERO" "" >/dev/null 2>&1 \
  && fail "build_record emitted a same-head laundered approval" \
  || pass "build_record refuses a same-head laundered approval (finding 3, head threaded)"

rec="$(p4b_acct_build_record 42 def456 APPROVED nathanpayne-codex "claude->codex" posted "" \
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
grep -q  '^## Phase 4b Approval Accounting' <<<"$BLOCK" \
  && pass "golden render carries the block heading" || fail "missing block heading"
grep -q  -- '55,926 (codex-stderr)' <<<"$BLOCK" \
  && pass "golden render formats total-only tokens with source" || fail "token cell (total-only) wrong"
grep -q  -- '7,360 (claude-json: in 1,589 / out 5,771)' <<<"$BLOCK" \
  && pass "golden render formats split tokens with in/out" || fail "token cell (split) wrong"
grep -q  -- 'unavailable (unavailable)' <<<"$BLOCK" \
  && pass "loop with no CLI counts renders explicit unavailable" || fail "missing unavailable cell"
grep -q  -- '\*\*yes\*\* — approval-carried-findings' <<<"$BLOCK" \
  && pass "fail-closed loop rendered as positive safety evidence" || fail "fail-closed loop row missing"
grep -qF '| F1 | P2 | — | Codex `--output-schema` vs jq validator drift (`line` min) | current-head | 3 | 3 | deferred-to-follow-up | #585 |' <<<"$BLOCK" \
  && pass "findings table carries content (path/summary), scope, and the follow-up issue link (#615)" \
  || fail "findings row missing"
grep -qF  'Unique findings across loops: 4 — 4 on the approved head, 0 historical (earlier loops only). Repeated across loops: 0.' <<<"$BLOCK" \
  && pass "findings summary counts approved-head vs historical findings truthfully" \
  || fail "findings summary sentence wrong"
# #615 Codex: findings last seen on a PRIOR commit must be labeled historical,
# never current-head. Rewrite loop 3 (the advisory-bearing loop) to an older
# head; F1–F4 were last seen there, so all four become historical.
HISTREC="$(printf '%s' "$GOLDEN" | jq -c '.loops[2].head_sha = "older111"')"
HISTBLOCK="$(p4b_acct_render_block "$HISTREC")"
grep -qF '| F1 | P2 | — | Codex `--output-schema` vs jq validator drift (`line` min) | historical | 3 | 3 |' <<<"$HISTBLOCK" \
  && pass "findings from a prior commit are labeled historical, not current-head (#615)" \
  || fail "historical scope label missing"
grep -qF  'Unique findings across loops: 4 — 0 on the approved head, 4 historical (earlier loops only).' <<<"$HISTBLOCK" \
  && pass "summary sentence separates historical findings from approved-head ones" \
  || fail "historical summary sentence wrong"
grep -q  -- '~\$0.66 \*(not billed; price table `2026-07-01`)\*' <<<"$BLOCK" \
  && pass "notional cost labeled not-billed with the price-table version stamp" || fail "notional row wrong"
grep -q  -- '\*\*\$0.00\*\* — operator subscription plan' <<<"$BLOCK" \
  && pass "billed cost row states \$0.00 plainly" || fail "billed row missing"
grep -q '| Reviewer CLI version | ✅ | `codex/0.137` (#586) |' <<<"$BLOCK" \
  && pass "captured CLI version renders green with evidence" || fail "cli version rigor row wrong"
grep -q '| Local gates green | n/a | local gate results not captured for this run |' <<<"$BLOCK" \
  && pass "uncaptured gate signal renders n/a with the reason (never a green check)" || fail "gates rigor row wrong"
grep -q  '\*Totals source: github-derived (24 prior record(s)).\*' <<<"$BLOCK" \
  && pass "running-totals footer names the totals source" || fail "totals-source footer missing"
# #615 Codex: the trust-signal rate divides by automated ATTEMPTS (27), not by
# emitted records (24) — records only exist for approvals, so records as the
# denominator rendered 100% even across fail-closed history.
grep -qF  '24 approved / 27 automated attempts = 89%' <<<"$BLOCK" \
  && pass "auto-approval rate uses the attempts denominator (24/27 = 89%, the spec golden)" \
  || fail "approval-rate denominator wrong"
RATEREC="$(printf '%s' "$GOLDEN" | jq -c '.running_totals.auto_approved_prs = 1
  | .running_totals.records = 1 | .running_totals.automated_attempts = 4
  | .running_totals.fail_closed_events = 3')"
RATEBLOCK="$(p4b_acct_render_block "$RATEREC")"
grep -qF  '1 approved / 4 automated attempts = 25%' <<<"$RATEBLOCK" \
  && pass "fail-closed-heavy history can no longer render as 100% approved (#615)" \
  || fail "fail-closed rate render wrong"
# #615 Codex: a null (unavailable) cumulative measurement renders unavailable,
# never a fabricated 0 / ~$0.
NULLRTREC="$(printf '%s' "$GOLDEN" | jq -c '.running_totals.tokens_total = null
  | .running_totals.notional_usd = null')"
NULLRTBLOCK="$(p4b_acct_render_block "$NULLRTREC")"
grep -qF '| Cumulative tokens | unavailable (not measured in every prior record) |' <<<"$NULLRTBLOCK" \
  && pass "null cumulative tokens render unavailable, not 0 (#615)" \
  || fail "null cumulative tokens rendered wrong"
grep -qF '| Cumulative notional API-equivalent | unavailable (not priced in every prior record) *(not billed either way)* |' <<<"$NULLRTBLOCK" \
  && pass "null cumulative notional renders unavailable, not ~\$0 (#615)" \
  || fail "null cumulative notional rendered wrong"
# #615 Codex round 7, finding 3 (fails pre-fix): a sub-hour cumulative
# human-time-saved lower bound must render in minutes, never floored to ~0 h.
# Pre-fix [30,180] rendered "~0 – 3 h", understating the documented 30-minute
# floor; post-fix it renders "~30 min – 3 h" (per-bound units once the low bound
# drops below an hour).
SUBHOURREC="$(printf '%s' "$GOLDEN" | jq -c '.running_totals.human_minutes_saved_estimate = [30, 180]')"
SUBHOURBLOCK="$(p4b_acct_render_block "$SUBHOURREC")"
if grep -qF '| Cumulative human time saved (est.) | ~30 min – 3 h |' <<<"$SUBHOURBLOCK" \
   && ! grep -qF '~0 – 3 h' <<<"$SUBHOURBLOCK"; then
  pass "sub-hour cumulative human-time-saved renders in minutes (~30 min – 3 h), not floored to ~0 h (#615 round 7, finding 3)"
else fail "sub-hour human-time render: $(printf '%s' "$SUBHOURBLOCK" | grep -F 'Cumulative human time saved')"; fi
# Both bounds below an hour render as a minutes-only range.
SUBHOUR2REC="$(printf '%s' "$GOLDEN" | jq -c '.running_totals.human_minutes_saved_estimate = [30, 50]')"
grep -qF '| Cumulative human time saved (est.) | ~30 – 50 min |' <<<"$(p4b_acct_render_block "$SUBHOUR2REC")" \
  && pass "a fully sub-hour range renders minutes on both bounds (~30 – 50 min) (#615 round 7, finding 3)" \
  || fail "fully-sub-hour human-time render"
# The whole-hour shared-unit form is unchanged for bounds >= 60 min (spec golden).
grep -qF '| Cumulative human time saved (est.) | ~12 – 72 h |' <<<"$BLOCK" \
  && pass "both-bounds >= 1h keep the shared-unit ~A – B h form (spec golden unchanged)" \
  || fail "whole-hour human-time render drifted from the spec golden"
GATES_BLOCK="$(P4B_ACCT_GATES_EVIDENCE="check_phase_4b_automation 67/67 green" p4b_acct_render_block "$GOLDEN")"
grep -q '| Local gates green | ✅ | check_phase_4b_automation 67/67 green |' <<<"$GATES_BLOCK" \
  && pass "captured gate evidence renders the gates row green" || fail "gates evidence row wrong"

RT="$(printf '%s\n' "$BLOCK" | p4b_acct_extract_records)"
if [ "$(printf '%s' "$RT" | jq -S .)" = "$(printf '%s' "$GOLDEN" | jq -S .)" ]; then
  pass "embedded record round-trips: render → extract == original"
else fail "round-trip mismatch"; fi
RT_N="$(printf 'prose mentions p4b-accounting:v1 in passing\n%s\n' "$BLOCK" | p4b_acct_extract_records | wc -l | tr -d '[:space:]')"
[ "$RT_N" = "1" ] && pass "extractor keys on the comment-open, not bare marker prose" \
  || fail "extractor captured $RT_N records with marker prose present"
# #615 round 2 (fails pre-fix): a `-->` inside any record string — e.g. a
# hostile finding title — used to close the embedded HTML comment early
# (GitHub renders the tail visibly) AND truncate extraction, silently
# dropping the record from future running totals. The writer now encodes
# the comment-delimiter angle brackets as JSON unicode escapes.
enc="$(printf '%s' '{"a":"x --> y","b":"<!-- open","c":"z --!> w"}' | p4b_acct_encode_comment_payload)"
if [ "$(printf '%s' "$enc" | jq -r '.a + "|" + .b + "|" + .c')" = 'x --> y|<!-- open|z --!> w' ] \
   && ! grep -q  -- '-->' <<<"$enc" \
   && ! grep -qF  '<!--' <<<"$enc" \
   && ! grep -qF -- '--!>' <<<"$enc"; then
  pass "payload encoder strips every literal comment delimiter while the parsed value round-trips"
else fail "payload encoder: $enc"; fi
HOSTILE="$(printf '%s' "$GOLDEN" | jq -c '.unique_findings[0].title = "hostile --> terminator <!-- reopen --!> tail"')"
HBLOCK="$(p4b_acct_render_block "$HOSTILE")" || HBLOCK=""
HTERMS="$(printf '%s\n' "$HBLOCK" | sed -n '/<!-- p4b-accounting:v1/,$p' | grep -c -- '-->' || true)"
[ "$HTERMS" = "1" ] \
  && pass "a hostile title cannot terminate the embedded comment early (exactly one --> after the comment-open)" \
  || fail "embedded comment carries $HTERMS terminator line(s)"
HRT="$(printf '%s\n' "$HBLOCK" | p4b_acct_extract_records)"
if [ -n "$HRT" ] && [ "$(printf '%s' "$HRT" | jq -S .)" = "$(printf '%s' "$HOSTILE" | jq -S .)" ]; then
  pass "hostile-title record round-trips: render → extract == original (#615 round 2)"
else fail "hostile round-trip mismatch: $HRT"; fi
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
# Three DISTINCT PRs (580 approved, 581 changes-requested, 582 approved) so the
# sum-every-metric intent is unambiguous and auto_approved_prs counts distinct
# approved PR numbers, not APPROVED records (#615 Codex round 5 — a same-PR
# duplicate is exercised as its own regression below).
REC3="$(printf '%s' "$GOLDEN" | jq -c '.pr = 582')"
agg="$(printf '%s\n%s\n%s\n' "$GOLDEN" "$REC2" "$REC3" | p4b_acct_aggregate_running_totals github-derived)"
if printf '%s' "$agg" | jq -e '
    .source == "github-derived" and .records == 3
    and .auto_approved_prs == 2 and .automated_attempts == 10
    and .fail_closed_events == 2 and .tokens_total == 355408
    and .elapsed_seconds_total == 510 and .notional_usd == 1.42
    and .human_minutes_saved_estimate == [60, 360]' >/dev/null; then
  pass "aggregation over N records sums every metric and derives the human-minutes range"
else fail "aggregation: $agg"; fi
# #615 Codex round 5 (fails pre-fix): a PR approved twice (two commits, two
# automated approvals) leaves two APPROVED bodies with the SAME .pr. The PR
# metric must dedupe by .pr (distinct approved PRs = 1) and the derived
# human-time-saved must follow it — while automated_attempts / tokens / elapsed
# / notional still SUM across both approvals (actual spend, two real reviews).
DUP_A="$(printf '%s' "$GOLDEN" | jq -c '.pr = 900 | .final_head_sha = "aaa111"')"
DUP_B="$(printf '%s' "$GOLDEN" | jq -c '.pr = 900 | .final_head_sha = "bbb222"')"
agg="$(printf '%s\n%s\n' "$DUP_A" "$DUP_B" | p4b_acct_aggregate_running_totals github-derived)"
if printf '%s' "$agg" | jq -e '
    .records == 2
    and .auto_approved_prs == 1
    and .human_minutes_saved_estimate == [30, 180]
    and .automated_attempts == 8 and .fail_closed_events == 2
    and .tokens_total == 354408 and .elapsed_seconds_total == 450
    and .notional_usd == 1.32' >/dev/null; then
  pass "two approvals of the SAME PR count as one distinct auto-approved PR; spend metrics still sum (#615 round 5)"
else fail "duplicate-PR dedupe: $agg"; fi
# #615 Codex: a prior record with an unavailable (null) measurement makes the
# CUMULATIVE figure unavailable too — per metric, independently — instead of
# being coerced to 0 (which underreports repo-wide totals in the common
# no-price-key case). Counts (records/attempts/fail-closed) still sum.
REC_NULLTOK="$(printf '%s' "$GOLDEN" | jq -c '.totals.tokens_total = null')"
agg="$(printf '%s\n%s\n' "$GOLDEN" "$REC_NULLTOK" | p4b_acct_aggregate_running_totals github-derived)"
if printf '%s' "$agg" | jq -e '
    .tokens_total == null
    and .elapsed_seconds_total == 450 and .notional_usd == 1.32
    and .records == 2 and .automated_attempts == 8 and .fail_closed_events == 2' >/dev/null; then
  pass "one unmeasured tokens_total degrades cumulative tokens to null while other metrics still sum (#615)"
else fail "null-token aggregation: $agg"; fi
REC_NULLNOTIONAL="$(printf '%s' "$GOLDEN" | jq -c '.totals.notional_usd = null')"
agg="$(printf '%s\n%s\n' "$GOLDEN" "$REC_NULLNOTIONAL" | p4b_acct_aggregate_running_totals github-derived)"
if printf '%s' "$agg" | jq -e '
    .notional_usd == null and .tokens_total == 354408 and .elapsed_seconds_total == 450' >/dev/null; then
  pass "an unpriced record degrades cumulative notional to null, never ~\$0 (#615, the no-price-key case)"
else fail "null-notional aggregation: $agg"; fi
REC_NULLELAPSED="$(printf '%s' "$GOLDEN" | jq -c '.totals.elapsed_seconds_total = null')"
agg="$(printf '%s\n%s\n' "$GOLDEN" "$REC_NULLELAPSED" | p4b_acct_aggregate_running_totals github-derived)"
if printf '%s' "$agg" | jq -e '.elapsed_seconds_total == null and .tokens_total == 354408' >/dev/null; then
  pass "an unmeasured elapsed total degrades cumulative wall-clock to null (#615)"
else fail "null-elapsed aggregation: $agg"; fi
# #615 Codex round 5 (fails pre-fix): a syntactically valid object carrying the
# schema tag but MISSING required fields (partial write / manual edit / buggy
# emitter) used to pass the tag-only filter — counted as records:1 with zero
# attempts/fail-closed events, silently understating repo-wide totals. It must
# now be DROPPED from aggregation (schema-mirror required-key check) and counted
# in a diagnostics line, while the conformant records aggregate unaffected.
INCOMPLETE='{"schema":"p4b-accounting/v1","pr":999,"final_verdict":"APPROVED"}'
agg="$(printf '%s\n%s\n' "$GOLDEN" "$INCOMPLETE" | p4b_acct_aggregate_running_totals github-derived)"
if printf '%s' "$agg" | jq -e '
    .source == "github-derived"
    and .records == 1
    and .records_dropped_nonconformant == 1
    and .auto_approved_prs == 1
    and .automated_attempts == 4 and .fail_closed_events == 1
    and .tokens_total == 177204' >/dev/null; then
  pass "an incomplete schema-tagged record is dropped (not counted as conformant) and reported in diagnostics (#615 round 5)"
else fail "incomplete-record rejection: $agg"; fi
# A record missing only the required totals sub-keys is likewise non-conformant
# (the aggregation reads .totals.* and must not treat a totals-less record as
# zero-attempt conformant history).
INCOMPLETE_TOTALS="$(printf '%s' "$GOLDEN" | jq -c 'del(.totals.adapter_invocations)')"
agg="$(printf '%s\n%s\n' "$GOLDEN" "$INCOMPLETE_TOTALS" | p4b_acct_aggregate_running_totals github-derived)"
if printf '%s' "$agg" | jq -e '
    .records == 1 and .records_dropped_nonconformant == 1
    and .automated_attempts == 4' >/dev/null; then
  pass "a record missing a required totals sub-key is dropped from aggregation (#615 round 5)"
else fail "incomplete-totals rejection: $agg"; fi
# #615 Codex round 10 (fails pre-fix): key-present but wrong-TYPED values
# passed the required-key mirror — totals.tokens_total: "oops" flowed through
# addall into running_totals.tokens_total under a github-derived label,
# publishing corrupt cumulative data. A record whose aggregation-read fields
# do not match the schema types is dropped and counted like a missing key.
BADTYPE="$(printf '%s' "$GOLDEN" | jq -c '.totals.tokens_total = "oops"')"
agg="$(printf '%s\n%s\n' "$GOLDEN" "$BADTYPE" | p4b_acct_aggregate_running_totals github-derived)"
if printf '%s' "$agg" | jq -e '
    .records == 1 and .records_dropped_nonconformant == 1
    and .tokens_total == 177204' >/dev/null; then
  pass "a wrong-typed totals field (tokens_total: string) drops the record instead of publishing corrupt running totals (#615 round 10)"
else fail "type-invalid record accepted: $agg"; fi
# Fractional counts are schema-invalid integers and likewise dropped.
BADFRAC="$(printf '%s' "$GOLDEN" | jq -c '.totals.adapter_invocations = 2.5')"
agg="$(printf '%s\n%s\n' "$GOLDEN" "$BADFRAC" | p4b_acct_aggregate_running_totals github-derived)"
printf '%s' "$agg" | jq -e '.records == 1 and .records_dropped_nonconformant == 1' >/dev/null \
  && pass "a fractional adapter_invocations count is dropped (schema integer mirror) (#615 round 10)" \
  || fail "fractional-count record accepted: $agg"
# A fully conformant aggregation reports zero drops (diagnostics honesty).
agg="$(printf '%s\n' "$GOLDEN" | p4b_acct_aggregate_running_totals github-derived)"
printf '%s' "$agg" | jq -e '.records_dropped_nonconformant == 0' >/dev/null \
  && pass "a clean aggregation reports zero dropped records" \
  || fail "clean-aggregation drop count: $agg"
agg="$(printf '%s\ngarbage-line\n' "$GOLDEN" | p4b_acct_aggregate_running_totals ledger-cache)"
[ "$(printf '%s' "$agg" | jq -r '.source')" = "unavailable" ] \
  && pass "a malformed (non-object) ledger line degrades the whole aggregation to unavailable (never wrong numbers)" \
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
echo "accounting.sh — GitHub-derived prior-record fetch (#615 round 2)"
# ===========================================================================
# fails pre-fix: p4b_acct_fetch_prior_records / p4b_acct_hook_running_totals
# did not exist — the real orchestrator path never populated
# P4B_ACCT_PRIOR_RECORDS_JSONL, so totals always fell through to the
# gitignored per-checkout ledger.
PRIOR_BODY="$WORK/prior-review-body.txt"
{ printf 'Automated Phase 4b review prose above the accounting block.\n\n'
  p4b_acct_render_block "$GOLDEN"; } > "$PRIOR_BODY"
set +e
out="$(PATH="$BIN:$PATH" P4B_FAKE_PRIOR_BODIES="$PRIOR_BODY" p4b_acct_fetch_prior_records o/r)"; rc=$?
set -e
if [ "$rc" = 0 ] && [ "$(printf '%s' "$out" | jq -S .)" = "$(printf '%s' "$GOLDEN" | jq -S .)" ]; then
  pass "fetch pulls prior review bodies via the PATH-shimmed gh and re-emits the embedded record"
else fail "fetch happy path (rc=$rc, out=$out)"; fi
set +e
out="$(PATH="$BIN:$PATH" p4b_acct_fetch_prior_records o/r)"; rc=$?
set -e
if [ "$rc" = 0 ] && [ -z "$out" ]; then
  pass "a repo with no prior records is a VALID empty fetch (first-ever approval)"
else fail "empty fetch (rc=$rc, out='$out')"; fi
set +e
PATH="$BIN:$PATH" P4B_FAKE_GRAPHQL_FAIL=1 p4b_acct_fetch_prior_records o/r >/dev/null 2>&1; rc=$?
set -e
[ "$rc" != 0 ] && pass "an API failure returns non-zero (the caller falls back explicitly)" \
  || fail "graphql failure not surfaced"
set +e
p4b_acct_fetch_prior_records "" >/dev/null 2>&1; rc=$?
set -e
[ "$rc" != 0 ] && pass "an unusable repo slug refuses to fetch" || fail "empty slug accepted"

# --- Bounded fetch: a stalled read times out (#615 round 8, finding 2) --------
# FAILS pre-fix: the gh api graphql call had no timeout, so a hung read blocked
# the valid APPROVED post indefinitely. With P4B_ACCT_FETCH_TIMEOUT the bounded
# wrapper interrupts a slow read and returns non-zero (a fetch failure), and the
# hook degrades to the ledger-cache path — never blocking the approval.
HOOK_STATE_TIMEOUT="$WORK/hook-rt-timeout"
if command -v timeout >/dev/null 2>&1 || command -v gtimeout >/dev/null 2>&1 \
   || command -v perl >/dev/null 2>&1; then
  set +e
  _t0=$(date +%s)
  PATH="$BIN:$PATH" P4B_FAKE_GRAPHQL_SLEEP=30 P4B_ACCT_FETCH_TIMEOUT=1 \
    P4B_FAKE_PRIOR_BODIES="$PRIOR_BODY" \
    p4b_acct_fetch_prior_records o/r >/dev/null 2>&1; rc=$?
  _t1=$(date +%s)
  set -e
  if [ "$rc" != 0 ] && [ "$(( _t1 - _t0 ))" -lt 15 ]; then
    pass "a stalled graphql read is time-boxed and returns non-zero well under the sleep (finding 2)"
  else fail "bounded fetch (rc=$rc, elapsed=$(( _t1 - _t0 ))s)"; fi
  # The hook degrades to explicit unavailable when the bounded fetch times out
  # and no ledger cache exists — the approval path never stalls on accounting.
  rt="$(PATH="$BIN:$PATH" REPO=o/r P4B_ACCT_STATE_DIR="$HOOK_STATE_TIMEOUT" \
        P4B_FAKE_GRAPHQL_SLEEP=30 P4B_ACCT_FETCH_TIMEOUT=1 \
        p4b_acct_hook_running_totals 2>/dev/null)"
  [ "$(printf '%s' "$rt" | jq -r '.source')" = "unavailable" ] \
    && pass "a timed-out fetch with no ledger degrades to explicit unavailable, never a stall (finding 2)" \
    || fail "timed-out hook degradation: $rt"
  # 0 opts out of the bound (unbounded) — a fast fixture still succeeds.
  set +e
  out="$(PATH="$BIN:$PATH" P4B_ACCT_FETCH_TIMEOUT=0 \
    P4B_FAKE_PRIOR_BODIES="$PRIOR_BODY" p4b_acct_fetch_prior_records o/r)"; rc=$?
  set -e
  [ "$rc" = 0 ] && [ -n "$out" ] \
    && pass "P4B_ACCT_FETCH_TIMEOUT=0 opts out of the bound (unbounded fetch still works)" \
    || fail "unbounded opt-out (rc=$rc)"
else
  skip "no timeout/gtimeout/perl available — cannot exercise the bounded-fetch path"
fi

# Hook resolution order: injected file > GitHub fetch > ledger cache
# (explicitly labeled) > unavailable with the fetch-failed reason.
HOOK_STATE="$WORK/hook-rt-state"
mkdir -p "$HOOK_STATE"
printf '%s\n%s\n' "$GOLDEN" "$REC2" > "$HOOK_STATE/phase-4b-ledger.jsonl"
rt="$(PATH="$BIN:$PATH" REPO=o/r P4B_ACCT_STATE_DIR="$HOOK_STATE" \
      P4B_FAKE_PRIOR_BODIES="$PRIOR_BODY" p4b_acct_hook_running_totals)"
[ "$(printf '%s' "$rt" | jq -r '.source + "/" + (.records | tostring)')" = "github-derived/1" ] \
  && pass "the GitHub fetch outranks a populated local ledger (repo-wide, not per-checkout)" \
  || fail "fetch-over-ledger priority: $rt"
rt="$(PATH="$BIN:$PATH" REPO=o/r P4B_ACCT_STATE_DIR="$HOOK_STATE" \
      P4B_FAKE_GRAPHQL_FAIL=1 p4b_acct_hook_running_totals 2>/dev/null)"
[ "$(printf '%s' "$rt" | jq -r '.source + "/" + (.records | tostring)')" = "ledger-cache/2" ] \
  && pass "fetch failure falls back to the ledger cache, labeled explicitly (never presented as repo-wide)" \
  || fail "fetch-failure ledger fallback: $rt"
rt="$(PATH="$BIN:$PATH" REPO=o/r P4B_ACCT_STATE_DIR="$WORK/hook-rt-empty" \
      P4B_FAKE_GRAPHQL_FAIL=1 p4b_acct_hook_running_totals 2>/dev/null)"
printf '%s' "$rt" | jq -e '.source == "unavailable" and (.reason | test("fetch failed"))' >/dev/null \
  && pass "fetch failure with no ledger renders explicit unavailable with the fetch-failed reason" \
  || fail "fetch-failure unavailable: $rt"
rt="$(PATH="$BIN:$PATH" REPO=o/r P4B_ACCT_STATE_DIR="$HOOK_STATE" \
      P4B_FAKE_GRAPHQL_FAIL=1 P4B_ACCT_PRIOR_RECORDS_JSONL="$PRIOR" p4b_acct_hook_running_totals)"
[ "$(printf '%s' "$rt" | jq -r '.source + "/" + (.records | tostring)')" = "github-derived/1" ] \
  && pass "an injected prior-record file still wins (no fetch attempted)" \
  || fail "injection priority: $rt"

# ===========================================================================
echo "accounting.sh — pagination, trusted authors, honest window (#615 round 3)"
# ===========================================================================
# Two-page fixture: page 1 carries a trusted record (nathanpayne-codex)
# AND a fabricated record embedded by the unregistered account "mallory";
# page 2 carries a second trusted record (nathanpayne-claude).
mkbody() { printf 'Automated Phase 4b review prose.\n\n<!-- p4b-accounting:v1\n%s\n-->\n' "$1"; }
FAKE_REC="$(printf '%s' "$GOLDEN" | jq -c '.pr = 999 | .totals.tokens_total = 999999999')"
PAGES_DIR="$WORK/gh-pages"; mkdir -p "$PAGES_DIR"
jq -n --arg b1 "$(mkbody "$GOLDEN")" --arg b2 "$(mkbody "$FAKE_REC")" '
  {data:{repository:{pullRequests:{
    pageInfo:{hasNextPage:true, endCursor:"page2"},
    nodes:[
      {reviews:{nodes:[{author:{login:"nathanpayne-codex"}, body:$b1}]}},
      {reviews:{nodes:[{author:{login:"mallory"}, body:$b2}]}}
    ]}}}}' > "$PAGES_DIR/page1.json"
jq -n --arg b "$(mkbody "$REC2")" '
  {data:{repository:{pullRequests:{
    pageInfo:{hasNextPage:false, endCursor:null},
    nodes:[{reviews:{nodes:[{author:{login:"nathanpayne-claude"}, body:$b}]}}]}}}}' \
  > "$PAGES_DIR/page2.json"

# (fails pre-fix: the fetch read one page and never followed endCursor)
set +e
PATH="$BIN:$PATH" P4B_FAKE_GRAPHQL_PAGE_DIR="$PAGES_DIR" \
  p4b_acct_fetch_prior_records o/r > "$WORK/fetch-pages.jsonl" 2>"$WORK/fetch-pages.err"; rc=$?
set -e
if [ "$rc" = 0 ] \
   && [ "$(grep -c . "$WORK/fetch-pages.jsonl")" = "2" ] \
   && [ "$(jq -s -S '.[0]' "$WORK/fetch-pages.jsonl")" = "$(printf '%s' "$GOLDEN" | jq -S .)" ] \
   && [ "$(jq -s -S '.[1]' "$WORK/fetch-pages.jsonl")" = "$(printf '%s' "$REC2" | jq -S .)" ]; then
  pass "fetch follows pageInfo.endCursor: trusted records from BOTH pages, in scan order (#615 round 3)"
else fail "pagination (rc=$rc, out=$(cat "$WORK/fetch-pages.jsonl" 2>/dev/null))"; fi
[ "${P4B_ACCT_PRIOR_FETCH_TRUNCATED:-}" = "false" ] && [ "${P4B_ACCT_PRIOR_FETCH_SCANNED_PRS:-}" = "3" ] \
  && pass "a fully-drained scan reports its window: 3 PRs scanned, not truncated" \
  || fail "window globals: trunc=${P4B_ACCT_PRIOR_FETCH_TRUNCATED:-}, scanned=${P4B_ACCT_PRIOR_FETCH_SCANNED_PRS:-}"
# (fails pre-fix: author.login was never fetched, so mallory's fabricated
# record poisoned the totals)
if ! grep -qF '"pr":999' "$WORK/fetch-pages.jsonl"; then
  pass "a record embedded by an unregistered author never reaches the output (#615 round 3)"
else fail "poisoned record extracted into the aggregate stream"; fi
[ "${P4B_ACCT_PRIOR_FETCH_SKIPPED_RECORDS:-}" = "1" ] \
  && grep -q 'unregistered review author' "$WORK/fetch-pages.err" \
  && pass "the skipped untrusted record is counted and surfaced as a diagnostics line, not aggregated" \
  || fail "skip diagnostics: skipped=${P4B_ACCT_PRIOR_FETCH_SKIPPED_RECORDS:-}, err=$(cat "$WORK/fetch-pages.err" 2>/dev/null)"

# (fails pre-fix: no window was tracked at all) page-cap truncation is
# detected and reported so the renderer can label a bounded window.
set +e
PATH="$BIN:$PATH" P4B_FAKE_GRAPHQL_PAGE_DIR="$PAGES_DIR" P4B_ACCT_PRIOR_SCAN_PAGES=1 \
  p4b_acct_fetch_prior_records o/r > "$WORK/fetch-trunc.jsonl" 2>/dev/null; rc=$?
set -e
if [ "$rc" = 0 ] \
   && [ "$(grep -c . "$WORK/fetch-trunc.jsonl")" = "1" ] \
   && [ "${P4B_ACCT_PRIOR_FETCH_TRUNCATED:-}" = "true" ] \
   && [ "${P4B_ACCT_PRIOR_FETCH_SCANNED_PRS:-}" = "2" ]; then
  pass "a page-cap hit with history remaining reports a truncated 2-PR window"
else fail "truncated fetch (rc=$rc, trunc=${P4B_ACCT_PRIOR_FETCH_TRUNCATED:-}, scanned=${P4B_ACCT_PRIOR_FETCH_SCANNED_PRS:-})"; fi

# An untrusted-author-only history is a clean 0-record fetch, skip counted.
set +e
PATH="$BIN:$PATH" P4B_FAKE_PRIOR_BODIES="$PRIOR_BODY" P4B_FAKE_PRIOR_AUTHOR=mallory \
  p4b_acct_fetch_prior_records o/r > "$WORK/fetch-untrusted.jsonl" 2>/dev/null; rc=$?
set -e
if [ "$rc" = 0 ] && [ ! -s "$WORK/fetch-untrusted.jsonl" ] \
   && [ "${P4B_ACCT_PRIOR_FETCH_SKIPPED_RECORDS:-}" = "1" ]; then
  pass "the same body under an unregistered author yields 0 records (fabrication cannot inflate totals)"
else fail "untrusted-only fetch (rc=$rc, skipped=${P4B_ACCT_PRIOR_FETCH_SKIPPED_RECORDS:-})"; fi
# No registered reviewers ⇒ records unattributable ⇒ fail-closed.
set +e
MERGEPATH_REVIEW_POLICY_PATH="$POLICY_NO_REVIEWERS" PATH="$BIN:$PATH" \
  P4B_FAKE_PRIOR_BODIES="$PRIOR_BODY" p4b_acct_fetch_prior_records o/r >/dev/null 2>&1; rc=$?
set -e
[ "$rc" != 0 ] && pass "no registered available_reviewers → the fetch fails closed (ledger/unavailable fallback)" \
  || fail "reviewer-less policy fetch accepted"

# Hook threads the scan window into the running-totals object.
rt="$(PATH="$BIN:$PATH" REPO=o/r P4B_ACCT_STATE_DIR="$WORK/hook-rt-window" \
      P4B_FAKE_GRAPHQL_PAGE_DIR="$PAGES_DIR" P4B_ACCT_PRIOR_SCAN_PAGES=1 \
      p4b_acct_hook_running_totals 2>/dev/null)"
printf '%s' "$rt" | jq -e '.source == "github-derived" and .records == 1
    and .window.truncated == true and .window.scanned_prs == 2' >/dev/null \
  && pass "hook totals carry the truncated scan window for the renderer (#615 round 3)" \
  || fail "hook truncated window: $rt"
rt="$(PATH="$BIN:$PATH" REPO=o/r P4B_ACCT_STATE_DIR="$WORK/hook-rt-window" \
      P4B_FAKE_PRIOR_BODIES="$PRIOR_BODY" p4b_acct_hook_running_totals 2>/dev/null)"
printf '%s' "$rt" | jq -e '.source == "github-derived" and .window.truncated == false' >/dev/null \
  && pass "an untruncated fetch attaches truncated=false (the repo-wide claim stays earned)" \
  || fail "hook untruncated window: $rt"

# (fails pre-fix: the heading claimed repo, to date unconditionally)
WINREC="$(printf '%s' "$GOLDEN" | jq -c '.running_totals.window = {scanned_prs: 200, truncated: true}')"
WINBLOCK="$(p4b_acct_render_block "$WINREC")"
if grep -q  '^### Running totals — window: last 200 merged PRs$' <<<"$WINBLOCK" \
   && ! grep -q 'repo, to date' <<<"$WINBLOCK"; then
  pass "a truncated window renders the bounded-window heading, never a repo-wide claim"
else fail "window heading: $(printf '%s' "$WINBLOCK" | grep '### Running totals')"; fi
grep -qF  '*Totals source: github-derived (24 prior record(s)); window: last 200 merged PRs — older history beyond the scan cap is not included.*' <<<"$WINBLOCK" \
  && pass "the totals-source footer states the truncated window explicitly" \
  || fail "window footer: $(printf '%s' "$WINBLOCK" | grep 'Totals source')"
LCREC="$(printf '%s' "$GOLDEN" | jq -c '.running_totals.source = "ledger-cache"')"
LCBLOCK="$(p4b_acct_render_block "$LCREC")"
if grep -q  '^### Running totals — local ledger cache (this checkout only)$' <<<"$LCBLOCK" \
   && ! grep -q 'repo, to date' <<<"$LCBLOCK"; then
  pass "ledger-cache totals no longer claim repo, to date (#615 round 3)"
else fail "ledger-cache heading: $(printf '%s' "$LCBLOCK" | grep '### Running totals')"; fi

# --- nested review truncation (#615 round 4) --------------------------------
# A PR with more reviews than the nested last:50 window can silently omit an
# older embedded approval while PR-level pagination looks complete. The fetch
# now reads the nested reviews pageInfo.hasPreviousPage and any truncated
# review list makes the WHOLE scan window truncated (honest labeling; nested
# pagination deliberately not attempted — see the fetch contract).
RTRUNC_DIR="$WORK/gh-review-trunc"; mkdir -p "$RTRUNC_DIR"
jq -n --arg b "$(mkbody "$GOLDEN")" '
  {data:{repository:{pullRequests:{
    pageInfo:{hasNextPage:false, endCursor:null},
    nodes:[
      {reviews:{pageInfo:{hasPreviousPage:true},
                nodes:[{author:{login:"nathanpayne-codex"}, body:$b}]}},
      {reviews:{pageInfo:{hasPreviousPage:false}, nodes:[]}}
    ]}}}}' > "$RTRUNC_DIR/page1.json"
# (fails pre-fix: the query had no nested pageInfo, so the scan reported
# truncated=false and the totals claimed repo, to date)
set +e
PATH="$BIN:$PATH" P4B_FAKE_GRAPHQL_PAGE_DIR="$RTRUNC_DIR" \
  p4b_acct_fetch_prior_records o/r > "$WORK/fetch-rtrunc.jsonl" 2>"$WORK/fetch-rtrunc.err"; rc=$?
set -e
if [ "$rc" = 0 ] \
   && [ "$(grep -c . "$WORK/fetch-rtrunc.jsonl")" = "1" ] \
   && [ "${P4B_ACCT_PRIOR_FETCH_TRUNCATED:-}" = "true" ] \
   && [ "${P4B_ACCT_PRIOR_FETCH_SCANNED_PRS:-}" = "2" ] \
   && [ "${P4B_ACCT_PRIOR_FETCH_REVIEW_TRUNCATED_PRS:-}" = "1" ]; then
  pass "a PR with a truncated review list makes the whole scan window truncated (#615 round 4)"
else fail "review-truncated fetch (rc=$rc, trunc=${P4B_ACCT_PRIOR_FETCH_TRUNCATED:-}, scanned=${P4B_ACCT_PRIOR_FETCH_SCANNED_PRS:-}, rtrunc=${P4B_ACCT_PRIOR_FETCH_REVIEW_TRUNCATED_PRS:-})"; fi
grep -q 'more reviews than the nested' "$WORK/fetch-rtrunc.err" \
  && pass "the unscanned deeper review history is surfaced as a diagnostics line" \
  || fail "review-truncation diagnostics missing: $(cat "$WORK/fetch-rtrunc.err" 2>/dev/null)"
# The hook threads the review-truncated window into the running totals…
rt="$(PATH="$BIN:$PATH" REPO=o/r P4B_ACCT_STATE_DIR="$WORK/hook-rt-rtrunc" \
      P4B_FAKE_GRAPHQL_PAGE_DIR="$RTRUNC_DIR" p4b_acct_hook_running_totals 2>/dev/null)"
printf '%s' "$rt" | jq -e '.source == "github-derived" and .records == 1
    and .window.truncated == true and .window.scanned_prs == 2
    and .window.review_truncated_prs == 1' >/dev/null \
  && pass "hook totals carry the review-truncated window (#615 round 4)" \
  || fail "hook review-truncated window: $rt"
# …and the renderer labels a bounded window plus the deeper-history footer,
# never a repo-wide claim. (fails pre-fix: no footer clause existed)
RTWINREC="$(printf '%s' "$GOLDEN" | jq -c '.running_totals.window
  = {scanned_prs: 3, truncated: true, review_truncated_prs: 1}')"
RTWINBLOCK="$(p4b_acct_render_block "$RTWINREC")"
if grep -q  '^### Running totals — window: last 3 merged PRs$' <<<"$RTWINBLOCK" \
   && ! grep -q  'repo, to date' <<<"$RTWINBLOCK" \
   && grep -qF '1 scanned PR(s) hold more reviews than the nested review window — their older reviews are not included' <<<"$RTWINBLOCK"; then
  pass "review truncation renders the bounded-window heading + deeper-history footer (#615 round 4)"
else fail "review-truncation render: $(printf '%s' "$RTWINBLOCK" | grep -E '### Running totals|Totals source')"; fi
# Old fixtures without nested pageInfo stay valid (absent ⇒ not truncated;
# already exercised by every pre-round-4 fetch test above).

# ===========================================================================
echo "accounting.sh — zero-finding + degraded rendering"
# ===========================================================================
ZLOOP="$(printf '%s' "$CLEAN_LOOP" | jq -c '.cli_version = null | .plan_auth = null')"
ZREC="$(p4b_acct_build_record 7 headzz APPROVED nathanpayne-codex "claude->codex" posted 12 \
  "[$ZLOOP]" "[]" \
  "$(p4b_acct_compute_totals "[$ZLOOP]" "" null '[]')" \
  '{"source":"unavailable","records":0,"reason":"no prior-record source"}' "2026-07-01T00:00:00Z")"
ZBLOCK="$(p4b_acct_render_block "$ZREC")"
grep -q  '_No findings recorded on the approved HEAD' <<<"$ZBLOCK" \
  && pass "zero-finding approval names the rigor table as its proof-of-work" || fail "zero-finding text missing"
grep -q '| Plan-only auth (no metered API) | n/a | plan-auth posture not captured' <<<"$ZBLOCK" \
  && pass "missing plan-auth signal renders n/a, not a green check" || fail "plan-auth n/a row missing"
grep -q '| Reviewer CLI version | n/a |' <<<"$ZBLOCK" \
  && pass "missing CLI version renders n/a" || fail "cli-version n/a row missing"
grep -q  'unavailable (no CLI-exposed counts)' <<<"$ZBLOCK" \
  && pass "missing token totals render explicit unavailable with reason" || fail "token unavailable row missing"
grep -q  -- 'n/a — no price resolvable' <<<"$ZBLOCK" \
  && pass "missing price renders notional n/a while the record still posts" || fail "notional n/a row missing"
grep -q  '_Running totals unavailable — no prior-record source._' <<<"$ZBLOCK" \
  && pass "unavailable running totals render the degradation reason" || fail "running-totals degradation missing"
grep -q '| Plan-capacity throttle events | not captured |' <<<"$ZBLOCK" \
  && pass "uncaptured throttle events render as not captured (no fabricated 0)" || fail "throttle row wrong"
# #615 round 2 (fails pre-fix): when the CLI reported a real cost the cost
# row prefers it over the price-table notional, labeled with its source;
# the notional and n/a renderings are byte-unchanged otherwise (asserted by
# the golden render tests above).
CFULL_LOOP="$(printf '%s' "$CLEAN_LOOP" | jq -c '.tokens = {total:150, input:100, output:50, cache_creation:null, cache_read:null, reasoning:null, cost_usd:0.42, source:"claude-json"}')"
CTOT="$(p4b_acct_compute_totals "[$CFULL_LOOP]" "test-1" "0.66" '[]')"
CREC="$(p4b_acct_build_record 9 abc123 APPROVED nathanpayne-claude "codex->claude" posted 9 \
  "[$CFULL_LOOP]" "[]" "$CTOT" "$RT_ZERO" "2026-07-01T00:00:00Z")"
CBLOCK="$(p4b_acct_render_block "$CREC")"
grep -qF  -- '~$0.42 *(not billed; CLI-reported)*' <<<"$CBLOCK" \
  && pass "render prefers the CLI-reported cost with a source label (#615 round 2)" \
  || fail "CLI-reported preference missing: $(printf '%s' "$CBLOCK" | grep 'Notional API-equivalent')"
grep -q  'price table `test-1`' <<<"$CBLOCK" \
  && fail "price-table notional shown despite a CLI-reported cost" \
  || pass "the price-table notional stays out of the row when a reported cost wins"

# ===========================================================================
echo "verdict.schema.json + lib.sh — additive nullable usage fields (#602)"
# ===========================================================================
# shellcheck source=../scripts/phase-4b/lib.sh
. "$LIB"
# #632 retired the pre-#602 4-key backward-compat shape: OpenAI strict mode
# requires the schema to be required-complete, so the additive fields are
# required-but-nullable and a 4-key emitter is now schema-invalid.
if p4b_validate_verdict '{"verdict":"APPROVED","summary":"ok","findings":[],"usage":{"token_count":150,"input_tokens":100,"output_tokens":50,"source":"claude-json-envelope"}}'; then
  fail "pre-#602 4-key usage accepted despite #632 required-completeness"
else pass "pre-#602 4-key usage rejected (#632 required-complete schema)"; fi
if p4b_validate_verdict '{"verdict":"APPROVED","summary":"ok","findings":[],"usage":{"token_count":150,"input_tokens":100,"output_tokens":50,"cache_creation_input_tokens":30,"cache_read_input_tokens":20,"reasoning_tokens":7,"total_cost_usd":0.42,"source":"claude-json-envelope"},"cli_version":null}'; then
  pass "usage with all additive #602 fields validates"
else fail "extended usage shape rejected"; fi
if p4b_validate_verdict '{"verdict":"APPROVED","summary":"ok","findings":[],"usage":{"token_count":150,"input_tokens":100,"output_tokens":50,"cache_creation_input_tokens":null,"cache_read_input_tokens":null,"reasoning_tokens":null,"total_cost_usd":null,"source":"x"},"cli_version":null}'; then
  pass "additive fields accept explicit null (nullable, never required)"
else fail "null additive fields rejected"; fi
if p4b_validate_verdict '{"verdict":"APPROVED","summary":"ok","findings":[],"usage":{"token_count":150,"input_tokens":100,"output_tokens":50,"bogus_key":1,"source":"x"}}'; then
  fail "unknown usage key accepted"
else pass "unknown usage key still rejected (additionalProperties stays closed)"; fi
if p4b_validate_verdict '{"verdict":"APPROVED","summary":"ok","findings":[],"usage":{"token_count":150,"input_tokens":100,"output_tokens":50,"cache_read_input_tokens":"lots","source":"x"}}'; then
  fail "non-integer cache count accepted"
else pass "mistyped additive field rejected"; fi
# #615 Codex: jq `//` treats false as absent, so `X // null` let BOOLEAN
# additive fields sneak past the type check. The schema allows only
# integer/number/null — booleans must fail closed.
if p4b_validate_verdict '{"verdict":"APPROVED","summary":"ok","findings":[],"usage":{"token_count":150,"input_tokens":100,"output_tokens":50,"cache_read_input_tokens":false,"source":"x"}}'; then
  fail "boolean cache_read_input_tokens accepted"
else pass "boolean cache_read_input_tokens rejected (#615: the //-vs-false footgun)"; fi
if p4b_validate_verdict '{"verdict":"APPROVED","summary":"ok","findings":[],"usage":{"token_count":150,"input_tokens":100,"output_tokens":50,"cache_creation_input_tokens":true,"source":"x"}}'; then
  fail "boolean cache_creation_input_tokens accepted"
else pass "boolean cache_creation_input_tokens rejected"; fi
if p4b_validate_verdict '{"verdict":"APPROVED","summary":"ok","findings":[],"usage":{"token_count":150,"input_tokens":100,"output_tokens":50,"reasoning_tokens":false,"source":"x"}}'; then
  fail "boolean reasoning_tokens accepted"
else pass "boolean reasoning_tokens rejected"; fi
if p4b_validate_verdict '{"verdict":"APPROVED","summary":"ok","findings":[],"usage":{"token_count":150,"input_tokens":100,"output_tokens":50,"total_cost_usd":false,"source":"x"}}'; then
  fail "boolean total_cost_usd accepted"
else pass "boolean total_cost_usd rejected"; fi
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

# #615 round 11, Codex P2 (fails pre-fix): a COST-ONLY envelope (no token
# counts anywhere) used to hit the all-null-tokens bail and return usage:
# null, dropping the only CLI-sourced cost signal. The additive fields now
# participate in the emit decision; token fields stay honestly null.
set +e
out="$(CLAUDE_BIN="$BIN/fake-claude-cost-only" bash "$AD_CLAUDE" --pr 1 --repo o/r --diff-file "$DIFF")"; rc=$?
set -e
if [ "$rc" = 0 ] && printf '%s' "$out" | jq -e '
    .usage != null
    and .usage.total_cost_usd == 0.37
    and .usage.token_count == null
    and .usage.input_tokens == null
    and .usage.output_tokens == null
    and .usage.source == "claude-json-envelope"' >/dev/null; then
  pass "a cost-only claude envelope still yields a usage object carrying the reported cost (no fabricated tokens) (#615 round 11)"
else fail "cost-only claude envelope dropped (rc=$rc, out=$out)"; fi

# ===========================================================================
echo "lib.sh — parent-block reader is nesting-aware (#615 round 3)"
# ===========================================================================
# (fails pre-fix) The flat whole-block scanner matched the NESTED
# accounting.enabled as the parent phase_4b_automation.enabled whenever the
# parent key was absent — the accounting sub-toggle wrongly became the
# orchestrator master switch.
v="$(MERGEPATH_REVIEW_POLICY_PATH="$POLICY_NESTED_ONLY" p4b_automation_field enabled)"
[ -z "$v" ] && pass "parent enabled ABSENT + accounting.enabled true → parent reads empty (default-disabled)" \
  || fail "nested-toggle collision: parent enabled -> '$v'"
# (fails pre-fix) …and first-match-wins let a REORDERED sub-block shadow a
# later parent enabled: false.
v="$(MERGEPATH_REVIEW_POLICY_PATH="$POLICY_NESTED_REORDER" p4b_automation_field enabled)"
[ "$v" = "false" ] && pass "a sub-block listed first cannot shadow the later parent enabled: false" \
  || fail "reordered collision: parent enabled -> '$v'"
v="$(MERGEPATH_REVIEW_POLICY_PATH="$POLICY_NESTED_REORDER" p4b_automation_field mode)"
[ "$v" = "local" ] && pass "direct-child keys AFTER a nested sub-block still resolve (no over-skip)" \
  || fail "post-sub-block key lost: mode -> '$v'"
v="$(MERGEPATH_REVIEW_POLICY_PATH="$POLICY_ACCT_PRICES" p4b_automation_field enabled)"
[ "$v" = "true" ] && pass "a normally-shaped block still reads the parent enabled: true" \
  || fail "normal parent read: '$v'"
v="$(MERGEPATH_REVIEW_POLICY_PATH="$POLICY_NESTED_ONLY" p4b_acct_config_field enabled)"
[ "$v" = "true" ] && pass "the accounting sub-block reader still resolves its own nested enabled" \
  || fail "sub-block reader: '$v'"
# #615 round 4 parity: both readers share the first-key-line indent-capture
# mechanism, so the four-space policy resolves at BOTH nesting levels.
v="$(MERGEPATH_REVIEW_POLICY_PATH="$POLICY_ACCT_OFF4" p4b_automation_field enabled)"
[ "$v" = "true" ] && pass "the parent-block reader handles the four-space style (round-3 mechanism)" \
  || fail "four-space parent enabled -> '$v'"
v="$(MERGEPATH_REVIEW_POLICY_PATH="$POLICY_ACCT_OFF4" p4b_automation_field mode)"
[ "$v" = "local" ] && pass "four-space direct-child keys after the sub-block still resolve" \
  || fail "four-space mode -> '$v'"

# ===========================================================================
echo "accounting.sh — loop-log JSONL integrity + object-count numbering (#615 round 4)"
# ===========================================================================
# (passes pre-fix — documents the standing guarantee) The unposted-loop
# correction rewrites through `jq -cs`, so a corrected log must stay one
# compact object per line and keep the corrected loop reachable by later
# retries.
# shellcheck disable=SC2034  # orchestrator globals read by the sourced hook functions
if (
  P4B_ACCT_STATE_DIR="$WORK/state-jsonl"; export P4B_ACCT_STATE_DIR
  REPO="o/r"; PR=301; REVIEWER=nathanpayne-codex; ADAPTER=codex
  DIRECTION="claude->codex"; HEAD=abc123
  VERDICT_JSON='{"verdict":"APPROVED","summary":"ok","findings":[]}'
  p4b_acct_hook_record_loop APPROVED posted false "" || exit 1
  p4b_acct_hook_record_loop APPROVED posted false "" || exit 1
  p4b_acct_hook_mark_last_loop_unposted "review POST failed" || exit 1
  log="$(p4b_acct_hook_loop_log)"
  [ "$(wc -l < "$log" | tr -d '[:space:]')" = "2" ] || exit 1
  while IFS= read -r l; do
    printf '%s' "$l" | jq -e 'type == "object" and .schema == "p4b-loop-log/v1"' >/dev/null || exit 1
  done < "$log"
  jq -e -s 'length == 2
      and .[0].loop.loop == 1 and .[0].loop.posted == "posted"
      and .[1].loop.loop == 2 and .[1].loop.posted == "not-posted"
      and .[1].loop.fail_closed.happened == true' "$log" >/dev/null || exit 1
); then
  pass "a corrected loop log stays compact JSONL: 2 loops → 2 one-object lines, correction in place"
else fail "corrected loop log lost its JSONL shape or its correction"; fi
# (fails pre-fix) The retry after a correction derives the next loop number
# by counting JSON OBJECTS, not lines — a record spanning multiple lines
# (any non-compact writer/corruption) used to inflate loop IDs via `wc -l`,
# breaking the finding-lifecycle links keyed on them.
# shellcheck disable=SC2034  # orchestrator globals read by the sourced hook functions
if (
  P4B_ACCT_STATE_DIR="$WORK/state-prettylog"; export P4B_ACCT_STATE_DIR
  REPO="o/r"; PR=302; REVIEWER=nathanpayne-codex; ADAPTER=codex
  DIRECTION="claude->codex"; HEAD=abc123
  log="$(p4b_acct_hook_loop_log)"
  mkdir -p "$(dirname "$log")"
  # one record, PRETTY-PRINTED across many lines (simulated non-compact write)
  jq -n '{schema:"p4b-loop-log/v1", started_at_epoch:null,
          loop:{loop:1, reviewer:"nathanpayne-codex", posted:"posted"},
          details:[]}' > "$log"
  [ "$(wc -l < "$log" | tr -d '[:space:]')" -gt 1 ] || exit 1
  VERDICT_JSON='{"verdict":"APPROVED","summary":"ok","findings":[]}'
  p4b_acct_hook_record_loop APPROVED posted false "" || exit 1
  jq -e -s 'length == 2 and .[1].loop.loop == 2' "$log" >/dev/null || exit 1
); then
  pass "loop numbering counts JSON objects: a multi-line record cannot inflate the next loop ID (#615 round 4)"
else fail "object-count loop numbering (log=$(cat "$WORK/state-prettylog/phase-4b-loops/"*.jsonl 2>/dev/null | tail -3))"; fi

# ===========================================================================
echo "accounting.sh — cli_version threading (#622)"
# ===========================================================================
# p4b_acct_hook_record_loop maps VERDICT_JSON.cli_version through to the
# built record instead of hard-coding null. Three cases: populated,
# explicit null, and absent (an older adapter that predates #622) — all
# must round-trip honestly, never fabricating a value.
# shellcheck disable=SC2034  # orchestrator globals read by the sourced hook functions
if (
  P4B_ACCT_STATE_DIR="$WORK/state-cliversion-present"; export P4B_ACCT_STATE_DIR
  REPO="o/r"; PR=310; REVIEWER=nathanpayne-codex; ADAPTER=codex
  DIRECTION="claude->codex"; HEAD=cliver1
  VERDICT_JSON='{"verdict":"APPROVED","summary":"ok","findings":[],"usage":null,"cli_version":"codex-cli 0.137.0"}'
  p4b_acct_hook_record_loop APPROVED posted false "" || exit 1
  log="$(p4b_acct_hook_loop_log)"
  jq -e '.loop.cli_version == "codex-cli 0.137.0"' "$log" >/dev/null || exit 1
); then
  pass "populated VERDICT_JSON.cli_version threads through to the built record"
else fail "populated cli_version did not thread through"; fi
# shellcheck disable=SC2034  # orchestrator globals read by the sourced hook functions
if (
  P4B_ACCT_STATE_DIR="$WORK/state-cliversion-null"; export P4B_ACCT_STATE_DIR
  REPO="o/r"; PR=311; REVIEWER=nathanpayne-codex; ADAPTER=codex
  DIRECTION="claude->codex"; HEAD=cliver2
  VERDICT_JSON='{"verdict":"APPROVED","summary":"ok","findings":[],"usage":null,"cli_version":null}'
  p4b_acct_hook_record_loop APPROVED posted false "" || exit 1
  log="$(p4b_acct_hook_loop_log)"
  jq -e '.loop.cli_version == null' "$log" >/dev/null || exit 1
); then
  pass "explicit null VERDICT_JSON.cli_version records as null (never fabricated)"
else fail "explicit null cli_version did not record as null"; fi
# shellcheck disable=SC2034  # orchestrator globals read by the sourced hook functions
if (
  P4B_ACCT_STATE_DIR="$WORK/state-cliversion-absent"; export P4B_ACCT_STATE_DIR
  REPO="o/r"; PR=312; REVIEWER=nathanpayne-codex; ADAPTER=codex
  DIRECTION="claude->codex"; HEAD=cliver3
  # Pre-#622 adapter envelope shape: no cli_version key at all.
  VERDICT_JSON='{"verdict":"APPROVED","summary":"ok","findings":[],"usage":null}'
  p4b_acct_hook_record_loop APPROVED posted false "" || exit 1
  log="$(p4b_acct_hook_loop_log)"
  jq -e '.loop.cli_version == null' "$log" >/dev/null || exit 1
); then
  pass "an envelope predating #622 (no cli_version key) records as null, not an error"
else fail "absent cli_version key was not handled as null"; fi

# Approval-time same-head gate at the HOOK level (#615 round 9, CodeRabbit;
# fails pre-fix): a live log holding ONLY a prior CR-P1 loop, current loop
# unrecorded. A head-advanced approval (def456) must be SAFE (pre-fix the
# full-mode record clauses refused it: no clean APPROVED loop in the log); a
# same-head rerun (abc123) must still BLOCK (the laundering clause survives
# the mode split).
# shellcheck disable=SC2034  # orchestrator globals read by the sourced hook
if (
  P4B_ACCT_STATE_DIR="$WORK/state-samehead-hook"; export P4B_ACCT_STATE_DIR
  REPO="o/r"; PR=303; HEAD=def456
  log="$(p4b_acct_hook_loop_log)"
  mkdir -p "$(dirname "$log")"
  jq -cn --argjson loop "$(mkloop 1 CHANGES_REQUESTED 0 1 false abc123)" \
    '{schema:"p4b-loop-log/v1", started_at_epoch:null, loop:$loop, details:[]}' > "$log"
  p4b_acct_hook_same_head_required_block || exit 1
  HEAD=abc123
  p4b_acct_hook_same_head_required_block && exit 1
  exit 0
); then
  pass "approval-time hook: head-advanced approval is safe with the current loop unrecorded; a same-head rerun still blocks (#615 round 9 CodeRabbit)"
else fail "approval-time hook safe/block split wrong on an unrecorded current loop"; fi

# #615 Codex round 7, finding 2 (fails pre-fix): an APPROVED verdict carrying a
# REQUIRED-tier finding is rejected by p4b_validate_verdict BEFORE the
# discretionary gate, so note_fallback is reached with the GENERIC reason
# "adapter returned a non-conformant verdict". Pre-fix that reason keyed to
# UNAVAILABLE — the parsed P1 severity count/details of the unsafe approval the
# gate PREVENTED were dropped, underreporting the fail-closed loop. Post-fix the
# label is derived from the parsed verdict, so the histogram/details survive as
# an APPROVED_WITH_ADVISORIES fail-closed loop. It is still fell_back=true with a
# fail_closed marker (not a real approval), so it does NOT violate the posting
# rule (assert_no_required_with_approved excludes fail-closed-marked loops).
# shellcheck disable=SC2034  # orchestrator globals read by the sourced hook functions
if (
  P4B_ACCT_STATE_DIR="$WORK/state-reqtier-fallback"; export P4B_ACCT_STATE_DIR
  REPO="o/r"; PR=340; REVIEWER=nathanpayne-codex; ADAPTER=codex
  DIRECTION="claude->codex"; HEAD=abc123
  # An APPROVED verdict carrying a required-tier (P1) finding: what the adapter
  # returned and validate_verdict rejected. VERDICT_JSON is still set (it parsed).
  VERDICT_JSON='{"verdict":"APPROVED","summary":"ok despite issue","findings":[{"severity":"P1","path":"a.js","line":3,"body":"unsafe"}]}'
  p4b_acct_hook_note_fallback "adapter returned a non-conformant verdict" || exit 1
  log="$(p4b_acct_hook_loop_log)"
  jq -e -s '
      length == 1
      and .[0].loop.verdict == "APPROVED_WITH_ADVISORIES"
      and .[0].loop.posted == "not-posted"
      and .[0].loop.fell_back == true
      and .[0].loop.fail_closed.happened == true
      and .[0].loop.findings.P1 == 1
      and (.[0].details | length) == 1
      and .[0].details[0].severity == "P1"' "$log" >/dev/null || exit 1
  # The recorded loop must NOT trip the required-tier posting-rule assertion
  # (fail-closed-marked loops are legitimate fail-closed history, not approvals).
  loops="$(jq -cs '[ .[] | .loop ]' "$log")"
  p4b_acct_assert_no_required_with_approved CHANGES_REQUESTED "$loops" || exit 1
); then
  pass "a required-tier APPROVED-with-findings rejection records a fail-closed loop that PRESERVES the P1 histogram/details, not UNAVAILABLE (#615 round 7, finding 2)"
else fail "required-tier fail-closed accounting ($(cat "$WORK/state-reqtier-fallback/phase-4b-loops/"*.jsonl 2>/dev/null))"; fi
# A truly malformed verdict (not parseable as clean APPROVED-with-findings)
# still falls through to UNAVAILABLE — preservation is verdict-driven, not
# reason-string-driven, so it does not fabricate a histogram from garbage.
# shellcheck disable=SC2034
if (
  P4B_ACCT_STATE_DIR="$WORK/state-malformed-fallback"; export P4B_ACCT_STATE_DIR
  REPO="o/r"; PR=341; REVIEWER=nathanpayne-codex; ADAPTER=codex
  DIRECTION="claude->codex"; HEAD=abc123
  VERDICT_JSON='not even json'
  p4b_acct_hook_note_fallback "adapter returned a non-conformant verdict" || exit 1
  log="$(p4b_acct_hook_loop_log)"
  jq -e -s 'length == 1 and .[0].loop.verdict == "UNAVAILABLE" and .[0].loop.findings.P1 == null' "$log" >/dev/null || exit 1
); then
  pass "a genuinely malformed verdict still records UNAVAILABLE (preservation is verdict-driven, not reason-string-driven) (#615 round 7, finding 2)"
else fail "malformed-verdict fallback stayed UNAVAILABLE"; fi

# --- two-phase commit: stale-pending discard + per-approval log reset --------
# (#615 round 6, both fail pre-fix)

# Stale pending record (finding 2): a PRIOR run crashed after staging a pending
# record but before posting, leaving `<pending>` (with a DIFFERENT run id). A
# later APPROVED run whose accounting render failed/skipped never re-stages;
# pre-fix commit_posted_record appended that stale record after the new review
# posted, corrupting the ledger. The commit now proves ownership by the run-id
# sidecar and DISCARDS a record it did not stage.
# shellcheck disable=SC2034  # orchestrator globals read by the sourced hook functions
if (
  P4B_ACCT_STATE_DIR="$WORK/state-stalepending"; export P4B_ACCT_STATE_DIR
  REPO="o/r"; PR=330
  pending="$(p4b_acct_hook_pending_record_path)"
  runid="$(p4b_acct_hook_pending_runid_path)"
  ledger="$(p4b_acct_hook_ledger)"
  mkdir -p "$(dirname "$pending")"
  printf '%s\n' '{"schema":"p4b-accounting/v1","pr":330,"phantom":true}' > "$pending"
  printf '%s' 'crashed-run-9999' > "$runid"          # a DIFFERENT run's id
  # This invocation's run id differs from the staged one.
  P4B_ACCT_RUN_ID="current-run-1234"; export P4B_ACCT_RUN_ID
  p4b_acct_hook_commit_posted_record
  # ledger must NOT have gained the phantom; pending + sidecar cleared.
  [ ! -e "$ledger" ] || { grep -q phantom "$ledger" && exit 1; }
  [ ! -e "$pending" ] || exit 1
  [ ! -e "$runid" ] || exit 1
); then
  pass "commit discards a stale pending record from a crashed prior run (run-id mismatch), never appending it to the ledger (#615 round 6, finding 2)"
else fail "stale-pending discard (ledger=$(cat "$WORK/state-stalepending/phase-4b-ledger.jsonl" 2>/dev/null))"; fi

# Positive control: a pending record staged BY THIS run (matching sidecar) IS
# committed — the ownership guard does not break the happy path.
# shellcheck disable=SC2034
if (
  P4B_ACCT_STATE_DIR="$WORK/state-ownpending"; export P4B_ACCT_STATE_DIR
  REPO="o/r"; PR=331
  pending="$(p4b_acct_hook_pending_record_path)"
  runid="$(p4b_acct_hook_pending_runid_path)"
  ledger="$(p4b_acct_hook_ledger)"
  mkdir -p "$(dirname "$pending")"
  P4B_ACCT_RUN_ID="mine-42"; export P4B_ACCT_RUN_ID
  printf '%s\n' '{"schema":"p4b-accounting/v1","pr":331,"mine":true}' > "$pending"
  printf '%s' "$(p4b_acct_run_id)" > "$runid"          # matching sidecar
  p4b_acct_hook_commit_posted_record
  grep -q '"mine":true' "$ledger" || exit 1
  [ ! -e "$pending" ] || exit 1
  [ ! -e "$runid" ] || exit 1
); then
  pass "commit appends a pending record staged by THIS run (matching run-id sidecar) and clears the staging files (#615 round 6)"
else fail "own-pending commit (ledger=$(cat "$WORK/state-ownpending/phase-4b-ledger.jsonl" 2>/dev/null))"; fi

# Per-approval loop-log reset (finding 4): after a committed approval, the
# consumed loop-log lines are rotated to the archive and the live log is
# emptied so a LATER rerun aggregates only loops SINCE the approval — the next
# posted record cannot repeat the earlier loops (which would double-count
# attempts/tokens/wall-time in cumulative running totals). Pre-fix the live log
# kept every historical line, so the second record re-embedded the first
# approval's loops.
# shellcheck disable=SC2034
if (
  P4B_ACCT_STATE_DIR="$WORK/state-logreset"; export P4B_ACCT_STATE_DIR
  REPO="o/r"; PR=332; REVIEWER=nathanpayne-codex; ADAPTER=codex
  DIRECTION="claude->codex"; HEAD=abc123
  VERDICT_JSON='{"verdict":"APPROVED","summary":"ok","findings":[]}'
  P4B_ACCT_RUN_ID="reset-run"; export P4B_ACCT_RUN_ID
  log="$(p4b_acct_hook_loop_log)"
  archive="${log}.archive"
  # Record two loops (simulating a CR→approve or probe history) then stage +
  # commit an approval so the reset fires.
  p4b_acct_hook_record_loop APPROVED posted false "" || exit 1
  p4b_acct_hook_record_loop APPROVED posted false "" || exit 1
  [ "$(jq -s length "$log")" = 2 ] || exit 1
  pending="$(p4b_acct_hook_pending_record_path)"
  mkdir -p "$(dirname "$pending")"
  printf '%s\n' '{"schema":"p4b-accounting/v1","pr":332}' > "$pending"
  printf '%s' "$(p4b_acct_run_id)" > "$(p4b_acct_hook_pending_runid_path)"
  p4b_acct_hook_commit_posted_record
  # After the commit: live log emptied, archive holds the two consumed loops.
  [ "$(jq -s length "$log" 2>/dev/null || echo -1)" = 0 ] || exit 1
  [ "$(jq -s length "$archive")" = 2 ] || exit 1
  # A subsequent loop starts a fresh segment: numbering restarts at 1 and the
  # live log holds ONLY the new loop (no re-embedding of the consumed loops).
  p4b_acct_hook_record_loop APPROVED posted false "" || exit 1
  jq -e -s 'length == 1 and .[0].loop.loop == 1' "$log" >/dev/null || exit 1
); then
  pass "post-approval loop-log reset: consumed loops rotate to the archive and the next rerun starts a fresh segment (no double-count) (#615 round 6, finding 4)"
else fail "loop-log reset (live=$(jq -s length "$WORK/state-logreset/phase-4b-loops/"*.jsonl 2>/dev/null), archive=$(cat "$WORK/state-logreset/phase-4b-loops/"*.archive 2>/dev/null | jq -s length 2>/dev/null))"; fi

# #615 Codex round 7, finding 1 (fails pre-fix): the approval POSTED but the
# accounting render FAILED/skipped, so NO pending record was staged. commit is
# still called (post-success branch), and this run's APPROVED loop is already in
# the live log. Pre-fix commit returned early on the empty-pending guard WITHOUT
# rotating, leaving that consumed loop in the live log to be re-counted by the
# next rerun's record. Rotation now keys off "the approval posted", so the loop
# is archived and the live log emptied even with no record committed. Composes
# with round-6: no ledger record is committed here (nothing was staged), only
# the LOOP log rotates.
# shellcheck disable=SC2034  # orchestrator globals read by the sourced hook functions
if (
  P4B_ACCT_STATE_DIR="$WORK/state-norecord-rotate"; export P4B_ACCT_STATE_DIR
  REPO="o/r"; PR=350; REVIEWER=nathanpayne-codex; ADAPTER=codex
  DIRECTION="claude->codex"; HEAD=abc123
  VERDICT_JSON='{"verdict":"APPROVED","summary":"ok","findings":[]}'
  P4B_ACCT_RUN_ID="norecord-run"; export P4B_ACCT_RUN_ID
  log="$(p4b_acct_hook_loop_log)"; archive="${log}.archive"
  # This run appends its APPROVED loop, then the render FAILS so nothing is
  # staged (no pending record). The approval still posts → commit is called.
  p4b_acct_hook_record_loop APPROVED posted false "" || exit 1
  [ "$(jq -s length "$log")" = 1 ] || exit 1
  [ ! -e "$(p4b_acct_hook_pending_record_path)" ] || exit 1   # render staged nothing
  p4b_acct_hook_commit_posted_record
  # The consumed loop must be rotated out even though no record was committed.
  [ "$(jq -s length "$log" 2>/dev/null || echo -1)" = 0 ] || exit 1
  [ "$(jq -s length "$archive")" = 1 ] || exit 1
  # A rerun therefore starts fresh (loop 1), never re-counting the posted loop.
  p4b_acct_hook_record_loop APPROVED posted false "" || exit 1
  jq -e -s 'length == 1 and .[0].loop.loop == 1' "$log" >/dev/null || exit 1
); then
  pass "commit rotates this run's posted loop even when the render staged NO record (approval-keyed rotation, no re-count) (#615 round 7, finding 1)"
else fail "no-record rotation (live=$(jq -s length "$WORK/state-norecord-rotate/phase-4b-loops/"*.jsonl 2>/dev/null), archive=$(cat "$WORK/state-norecord-rotate/phase-4b-loops/"*.jsonl.archive 2>/dev/null | jq -s length 2>/dev/null))"; fi

# Ownership-mismatch path (#615 round 7, finding 1 + round 6 compose): a stale
# pending record from a DIFFERENT run is discarded (round-6 ownership check),
# and this run's own posted loop is ALSO rotated out (round-7). Pre-fix the
# mismatch path returned WITHOUT rotating, re-counting the loop next rerun.
# shellcheck disable=SC2034
if (
  P4B_ACCT_STATE_DIR="$WORK/state-mismatch-rotate"; export P4B_ACCT_STATE_DIR
  REPO="o/r"; PR=351; REVIEWER=nathanpayne-codex; ADAPTER=codex
  DIRECTION="claude->codex"; HEAD=abc123
  VERDICT_JSON='{"verdict":"APPROVED","summary":"ok","findings":[]}'
  P4B_ACCT_RUN_ID="mine-mismatch"; export P4B_ACCT_RUN_ID
  log="$(p4b_acct_hook_loop_log)"; archive="${log}.archive"
  ledger="$(p4b_acct_hook_ledger)"
  p4b_acct_hook_record_loop APPROVED posted false "" || exit 1
  # A stale pending record from a crashed OTHER run (different sidecar).
  pending="$(p4b_acct_hook_pending_record_path)"
  mkdir -p "$(dirname "$pending")"
  printf '%s\n' '{"schema":"p4b-accounting/v1","pr":351,"phantom":true}' > "$pending"
  printf '%s' 'other-run-777' > "$(p4b_acct_hook_pending_runid_path)"
  p4b_acct_hook_commit_posted_record
  # Ledger never gains the phantom; the pending files are cleared; AND this
  # run's own posted loop is rotated out (approval-keyed rotation).
  [ ! -e "$ledger" ] || { grep -q phantom "$ledger" && exit 1; }
  [ ! -e "$pending" ] || exit 1
  [ "$(jq -s length "$log" 2>/dev/null || echo -1)" = 0 ] || exit 1
  [ "$(jq -s length "$archive")" = 1 ] || exit 1
); then
  pass "commit discards a foreign pending record AND rotates this run's own posted loop (round-6 ownership + round-7 approval-keyed rotation) (#615 round 7, finding 1)"
else fail "mismatch rotation (ledger=$(cat "$WORK/state-mismatch-rotate/phase-4b-ledger.jsonl" 2>/dev/null), live=$(jq -s length "$WORK/state-mismatch-rotate/phase-4b-loops/"*.jsonl 2>/dev/null))"; fi

# ===========================================================================
echo "accounting.sh — p4b_acct_safe_truncate (marker-safe body cut)"
# ===========================================================================
# #615 round 10, Codex P3 (fails pre-fix as a raw byte slice): a cut landing
# between the `<!-- p4b-accounting:v1` comment-open and its closing `-->`
# leaves an unterminated HTML comment that hides the appended truncation
# notice. The helper backs such a cut off to just before the marker; cuts
# before the marker or past the terminated comment stay plain byte slices.
PRE_T='0123456789ABCDEF'                          # 16 bytes, all ASCII
CMT_T='<!-- p4b-accounting:v1 {"x":1} -->'
TAIL_T='-tail-tail-tail'
BLK_T="${PRE_T}${CMT_T}${TAIL_T}"
CMT_END_T=$(( ${#PRE_T} + ${#CMT_T} ))
out_t="$(p4b_acct_safe_truncate "$BLK_T" 10)"
[ "$out_t" = "0123456789" ] \
  && pass "a cut before the marker is a plain byte slice" \
  || fail "pre-marker cut wrong: '$out_t'"
out_t="$(p4b_acct_safe_truncate "$BLK_T" $(( ${#PRE_T} + 5 )))"
[ "$out_t" = "$PRE_T" ] \
  && pass "a cut inside the embedded record comment backs off to just before the marker (notice stays visible) (#615 round 10)" \
  || fail "inside-comment cut did not back off: '$out_t'"
out_t="$(p4b_acct_safe_truncate "$BLK_T" $(( CMT_END_T + 3 )))"
if [ "$out_t" = "${BLK_T:0:$(( CMT_END_T + 3 ))}" ] && case "$out_t" in *'-->'*) true ;; *) false ;; esac; then
  pass "a cut past the terminated comment keeps the whole record (plain slice, comment intact)"
else fail "post-comment cut wrong: '$out_t'"; fi
out_t="$(p4b_acct_safe_truncate "$BLK_T" $(( ${#BLK_T} + 50 )))"
[ "$out_t" = "$BLK_T" ] \
  && pass "a budget past the block end returns the whole block unchanged" \
  || fail "over-length cut wrong"
out_t="$(p4b_acct_safe_truncate "no marker here at all" 7)"
[ "$out_t" = "no mark" ] \
  && pass "a block with no embedded record truncates as a plain byte slice" \
  || fail "no-marker cut wrong: '$out_t'"
BLK_U="${PRE_T}<!-- p4b-accounting:v1 unterminated"
out_t="$(p4b_acct_safe_truncate "$BLK_U" $(( ${#BLK_U} - 2 )))"
[ "$out_t" = "$PRE_T" ] \
  && pass "a defensive cut into an unterminated comment backs off to before the marker" \
  || fail "unterminated-comment cut wrong: '$out_t'"

# ===========================================================================
echo "orchestrator — accounting hook (fail-open, exit codes preserved)"
# ===========================================================================
run_orch() { # run_orch <state-dir> <policy> <codex-fake> <pr> [extra env as VAR=VAL...] -- [extra args...]
  # Extra env vars come LAST so a test can override the defaults below (env
  # takes the last assignment); extra args land after the defaults, and the
  # orchestrator flag parser is last-wins, so e.g. `-- --head def456` works.
  local state="$1" policy="$2" fake="$3" pr="$4"; shift 4
  local -a envs=()
  while [ $# -gt 0 ] && [ "$1" != "--" ]; do envs+=("$1"); shift; done
  [ "${1:-}" = "--" ] && shift
  env PATH="$BIN:$PATH" \
    MERGEPATH_REVIEW_POLICY_PATH="$policy" \
    P4B_ACCT_STATE_DIR="$state" \
    CODEX_BIN="$BIN/$fake" \
    P4B_GH_AS_REVIEWER="$BIN/fake-gh-as-reviewer" \
    P4B_FAKE_LIVE_HEAD=abc123 \
    "${envs[@]:-_P4B_NOOP=1}" \
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
if [ -z "$(find "$STATE_A/phase-4b-pending" -type f 2>/dev/null)" ]; then
  pass "two-phase ledger commit leaves no staged record behind after a successful post (#615)"
else fail "staged pending record left behind: $(find "$STATE_A/phase-4b-pending" -type f)"; fi
# #615 round 2: the hook now fetches prior records from GitHub itself, so a
# first-ever post on a repo with no prior records is a VALID github-derived
# 0-record baseline (previously: unavailable, because nothing populated
# P4B_ACCT_PRIOR_RECORDS_JSONL on the real path).
if printf '%s' "$REC_A" | jq -e '.running_totals.source == "github-derived" and .running_totals.records == 0' >/dev/null 2>&1; then
  pass "first-ever post derives totals from GitHub: a clean empty fetch is a 0-record baseline, never a guess (#615 round 2)"
else fail "first-post running totals: $REC_A"; fi

# (a3) Oversized accounting block never blocks the approval (#615 round 8,
#      finding 1). FAILS pre-fix: the block was appended to the ONLY POSTed
#      body with no size guard, so a block that pushes the body past GitHub's
#      ~65536-char review-body cap would fail the POST and block a valid
#      clearance. With a small P4B_ACCT_MAX_BODY_BYTES the append is TRUNCATED
#      (an explicit notice) yet the plain-summary APPROVED still posts (exit 0,
#      review posted). The capped body is strictly smaller than the full block.
STATE_A3F="$WORK/state-a3f"; BODY_A3F="$WORK/body-a3f.md"
set +e
run_orch "$STATE_A3F" "$POLICY_ON" fake-codex-approve 233 \
  P4B_WRAPPER_BODY="$BODY_A3F" -- >/dev/null 2>&1
set -e
FULL_BYTES="$(wc -c < "$BODY_A3F" 2>/dev/null | tr -d '[:space:]')"
BASE_BYTES="$(awk '/^## Phase 4b Approval Accounting/{exit} {print}' "$BODY_A3F" | wc -c | tr -d '[:space:]')"
STATE_A3="$WORK/state-a3"; BODY_A3="$WORK/body-a3.md"
# Cap ABOVE the plain summary but BELOW the full block so the TRUNCATION path
# (keep a prefix + notice) runs, not the drop-entirely path.
CAP_A3=$(( BASE_BYTES + 1000 ))
set +e
out="$(run_orch "$STATE_A3" "$POLICY_ON" fake-codex-approve 231 \
  P4B_WRAPPER_BODY="$BODY_A3" P4B_ACCT_MAX_BODY_BYTES="$CAP_A3" -- 2>/dev/null)"; rc=$?
set -e
CAP_BYTES="$(wc -c < "$BODY_A3" 2>/dev/null | tr -d '[:space:]')"
if [ "$rc" = 0 ] \
   && grep -q '^\*\*Automated Phase 4b review\*\*' "$BODY_A3" \
   && grep -qF 'accounting truncated' "$BODY_A3" \
   && [ "${CAP_BYTES:-0}" -lt "${FULL_BYTES:-0}" ] \
   && [ "${CAP_BYTES:-0}" -le "$CAP_A3" ] \
   && printf '%s' "$out" | jq -e '.verdict == "APPROVED" and .review_posted == true' >/dev/null; then
  pass "an oversized accounting block is truncated with a notice; body stays within the cap and the valid APPROVED still posts (finding 1)"
else fail "oversized-block truncation (rc=$rc, cap_bytes=$CAP_BYTES budget=$CAP_A3 full=$FULL_BYTES base=$BASE_BYTES, tail=$(tail -2 "$BODY_A3" 2>/dev/null))"; fi
# An even tighter budget (no room for the notice) drops the block entirely and
# posts the plain summary — the approval is still not blocked.
STATE_A3B="$WORK/state-a3b"; BODY_A3B="$WORK/body-a3b.md"
set +e
out="$(run_orch "$STATE_A3B" "$POLICY_ON" fake-codex-approve 232 \
  P4B_WRAPPER_BODY="$BODY_A3B" P4B_ACCT_MAX_BODY_BYTES=1 -- 2>/dev/null)"; rc=$?
set -e
if [ "$rc" = 0 ] \
   && grep -q '^\*\*Automated Phase 4b review\*\*' "$BODY_A3B" \
   && ! grep -q '## Phase 4b Approval Accounting' "$BODY_A3B" \
   && printf '%s' "$out" | jq -e '.verdict == "APPROVED" and .review_posted == true' >/dev/null; then
  pass "a budget too small even for the notice drops the block and posts the plain-summary approval (finding 1)"
else fail "block-dropped approval (rc=$rc, body=$(head -3 "$BODY_A3B" 2>/dev/null))"; fi

# (a3c) SIGPIPE-safe truncation of a LARGE (>64KB pipe-buffer) accounting block
#       (#615 Codex round 9, finding 1). Robustness guard (the pre-fix abort is
#       RACY — see the deterministic construct-level test right below, which
#       DOES fail pre-fix). The pre-fix truncation used
#       `printf '%s' "$ACCT_BLOCK" | head -c N`; for a block bigger than the
#       ~64KB pipe buffer, head -c can close the pipe after reading its prefix
#       while printf is still writing, so printf gets SIGPIPE (exit 141). Under
#       `set -euo pipefail` that fails the assignment and can abort the whole
#       orchestrator BEFORE post_review — advisory accounting BLOCKING a valid
#       approval, the inverse of the guard's intent. Whether the race fires
#       depends on scheduler timing and pipe-buffer draining, so this e2e path
#       is not a reliable pre-fix failure; it asserts the post-fix property (a
#       large block truncates and the approval still posts). Pre-seed a 150-loop
#       log so the rendered block is ~110KB, then cap into the truncation-keep
#       path.
STATE_A3C="$WORK/state-a3c"; BODY_A3C="$WORK/body-a3c.md"
mkdir -p "$STATE_A3C/phase-4b-loops"
: > "$STATE_A3C/phase-4b-loops/o-r-pr236.jsonl"
_a3c_i=1
while [ "$_a3c_i" -le 150 ]; do
  jq -nc --argjson n "$_a3c_i" '{schema:"p4b-loop-log/v1", started_at_epoch:1700000000,
    loop:{loop:$n, reviewer:"nathanpayne-codex", adapter:"review-via-codex.sh",
      direction:"claude->codex", head_sha:"abc123", verdict:"APPROVED",
      posted:"posted", fell_back:false, elapsed_seconds:10,
      tokens:{total:100,input:null,output:null,cache_creation:null,cache_read:null,reasoning:null,cost_usd:null,source:"codex-stderr"},
      findings:{P0:0,P1:0,P2:0,P3:0,nitpick:0,unknown:0},
      cli_version:null, timeout_seconds:900, effort:null, throttle_events:null,
      plan_auth:"chatgpt", fail_closed:{happened:false,reason:null,duration_seconds:null}},
    details:[]}' >> "$STATE_A3C/phase-4b-loops/o-r-pr236.jsonl"
  _a3c_i=$((_a3c_i + 1))
done
set +e
out="$(run_orch "$STATE_A3C" "$POLICY_ON" fake-codex-approve 236 \
  P4B_WRAPPER_BODY="$BODY_A3C" P4B_ACCT_MAX_BODY_BYTES=3000 -- 2>/dev/null)"; rc=$?
set -e
A3C_BYTES="$(wc -c < "$BODY_A3C" 2>/dev/null | tr -d '[:space:]')"
if [ "$rc" = 0 ] \
   && printf '%s' "$out" | jq -e '.verdict == "APPROVED" and .review_posted == true' >/dev/null \
   && grep -q '^\*\*Automated Phase 4b review\*\*' "$BODY_A3C" \
   && grep -qF 'accounting truncated' "$BODY_A3C" \
   && { ! grep -qF '<!-- p4b-accounting:v1' "$BODY_A3C" || grep -qF -- '-->' "$BODY_A3C"; } \
   && [ "${A3C_BYTES:-0}" -le 3000 ]; then
  pass "a large (>64KB) accounting block truncates via a pure-bash byte slice (no SIGPIPE abort) and the valid APPROVED still posts (finding 1)"
else fail "large-block SIGPIPE-safe truncation (rc=$rc, body_bytes=${A3C_BYTES:-?} cap=3000, posted=$(printf '%s' "$out" | jq -r '.review_posted // "?"' 2>/dev/null), notice=$(grep -qF 'accounting truncated' "$BODY_A3C" 2>/dev/null && echo yes || echo no))"; fi

# (a3d) Deterministic construct-level proof that the truncation is SIGPIPE-safe
#       (#615 Codex round 9, finding 1). The e2e a3c path is racy; this isolates
#       the two candidate constructs under the SAME `set -euo pipefail` the
#       orchestrator runs with, feeding a block far larger than one pipe buffer
#       and keeping only a tiny prefix (so head -c closes the read end while the
#       producer is still writing). The OLD `printf … | head -c N` form
#       (exercised in a loop to defeat the race) DOES surface exit 141 and would
#       abort the script; the NEW pure-bash `${var:0:N}` byte slice (LC_ALL=C, as
#       in the fix) NEVER aborts and yields exactly N bytes. FAILS pre-fix in the
#       sense that the vulnerable form is demonstrably abortable here while the
#       fixed form is not.
BIGBLK="$(head -c 400000 /dev/zero | tr '\0' 'a')"
# The fixed construct: must complete cleanly every time, byte-exact to N. Each
# probe runs in its own strict subshell (mirroring the orchestrator's mode);
# `|| FIX_RC=$?` keeps a subshell abort from tripping THIS script's set -e so
# the assertion below can report it.
# Capture-mechanism self-check first (#615 round 9, CodeRabbit): the earlier
# `if ! ( ... ); then FIX_RC=$?` form read $? AFTER the ! negation — always 0
# on the taken branch — so FIX_RC could never record a failure and the a3d
# assertion was unfalsifiable. Prove the corrected `|| { RC=$?; }` pattern
# actually captures a real strict-subshell failure code before trusting it.
CAP_RC=0
( set -euo pipefail; exit 7 ) || { CAP_RC=$?; }
if [ "$CAP_RC" -eq 7 ]; then
  pass "rc-capture pattern records a failing strict-subshell status — the a3d tripwire is falsifiable (round 9 CodeRabbit)"
else fail "rc-capture pattern lost the subshell status (CAP_RC=$CAP_RC, want 7); the a3d assertion below cannot be trusted"; fi
FIX_RC=0
for _t in 1 2 3 4 5; do
  ( set -euo pipefail
    v="$(LC_ALL=C; printf '%s' "${BIGBLK:0:64}")"
    [ "${#v}" -eq 64 ] || exit 91 ) || { FIX_RC=$?; break; }
done
# The vulnerable construct: run in a loop; record whether the pipe form ever
# aborts a strict subshell (exit 141/SIGPIPE). Racy, so we do not REQUIRE an
# abort — but if it aborts even once, that is the exact pre-fix failure the fix
# removes. `set +e` locally so the probe's own 141 never kills this test; we
# assert the FIX never aborts and record the vulnerable observation for signal.
VULN_SAW_141=no
set +e
for _t in 1 2 3 4 5 6 7 8; do
  ( set -euo pipefail
    v="$(printf '%s' "$BIGBLK" | head -c 64)"
    : "${v}" ) 2>/dev/null
  if [ "$?" -eq 141 ]; then VULN_SAW_141=yes; break; fi
done
set -e
if [ "$FIX_RC" -eq 0 ]; then
  pass "the pure-bash byte-slice truncation completes under set -euo pipefail on a >1-pipe-buffer block, byte-exact, never SIGPIPE-aborting (finding 1; vulnerable pipe form saw-141=$VULN_SAW_141)"
else fail "SIGPIPE-safe construct aborted (rc=$FIX_RC) — the fix must never abort on a large block"; fi

# (a2) #615 round 6 (fails pre-fix): TWO automated approvals of the SAME PR
#      (a second commit reran Phase 4b). Pre-fix the per-PR loop log kept the
#      first approval's loop, so the SECOND posted record re-embedded it — two
#      loops — and the ledger then held record1 (1 loop) + record2 (2 loops),
#      double-counting the first loop's attempt/tokens/wall-time in cumulative
#      running totals. Post-fix the first approval rotates its loop out, so the
#      second record embeds ONLY its own loop and each loop lives in exactly
#      one ledger record.
STATE_A2="$WORK/state-a2"; BODY_A2A="$WORK/body-a2a.md"; BODY_A2B="$WORK/body-a2b.md"
set +e
run_orch "$STATE_A2" "$POLICY_ON" fake-codex-approve 230 P4B_WRAPPER_BODY="$BODY_A2A" -- >/dev/null 2>&1; rc1=$?
run_orch "$STATE_A2" "$POLICY_ON" fake-codex-approve 230 P4B_WRAPPER_BODY="$BODY_A2B" -- >/dev/null 2>&1; rc2=$?
set -e
REC_A2A="$(p4b_acct_extract_records < "$BODY_A2A" 2>/dev/null || true)"
REC_A2B="$(p4b_acct_extract_records < "$BODY_A2B" 2>/dev/null || true)"
LEDGER_A2="$STATE_A2/phase-4b-ledger.jsonl"
if [ "$rc1" = 0 ] && [ "$rc2" = 0 ] \
   && printf '%s' "$REC_A2A" | jq -e '(.loops | length) == 1 and .loops[0].loop == 1' >/dev/null \
   && printf '%s' "$REC_A2B" | jq -e '(.loops | length) == 1 and .loops[0].loop == 1 and .totals.adapter_invocations == 1' >/dev/null \
   && [ "$(wc -l < "$LEDGER_A2" | tr -d '[:space:]')" = "2" ] \
   && [ "$(jq -s '[ .[].loops | length ] | add' "$LEDGER_A2")" = "2" ]; then
  pass "two approvals of the same PR: the second record embeds only its own loop; each loop lives in exactly one ledger record (no double-count) (#615 round 6, finding 4)"
else fail "no-double-count e2e (rc1=$rc1 rc2=$rc2, recA loops=$(printf '%s' "$REC_A2A" | jq '.loops|length' 2>/dev/null), recB loops=$(printf '%s' "$REC_A2B" | jq '.loops|length' 2>/dev/null), ledger-loops=$(jq -s '[ .[].loops | length ] | add' "$LEDGER_A2" 2>/dev/null))"; fi

# (b) accounting sub-toggle off → plain summary only, exit 0, no state writes.
STATE_B="$WORK/state-b"; BODY_B="$WORK/body-b.md"
set +e
out="$(run_orch "$STATE_B" "$POLICY_ACCT_OFF" fake-codex-approve 202 P4B_WRAPPER_BODY="$BODY_B" -- 2>/dev/null)"; rc=$?
set -e
if [ "$rc" = 0 ] && ! grep -q 'Phase 4b Approval Accounting' "$BODY_B" && [ ! -d "$STATE_B" ]; then
  pass "accounting.enabled: false → plain summary, no state writes, exit 0"
else fail "sub-toggle off (rc=$rc)"; fi

# (b2) #615 round 4 (fails pre-fix): the SAME opt-out formatted with
#      four-space children — the two-space-hardcoded reader read
#      accounting.enabled: false as absent, so the opted-out repo still got
#      the accounting block appended to its posted approval.
STATE_B2="$WORK/state-b2"; BODY_B2="$WORK/body-b2.md"
set +e
out="$(run_orch "$STATE_B2" "$POLICY_ACCT_OFF4" fake-codex-approve 216 P4B_WRAPPER_BODY="$BODY_B2" -- 2>/dev/null)"; rc=$?
set -e
if [ "$rc" = 0 ] && ! grep -q 'Phase 4b Approval Accounting' "$BODY_B2" && [ ! -d "$STATE_B2" ]; then
  pass "a four-space-indented opt-out is honored end-to-end: plain summary, no state writes (#615 round 4)"
else fail "four-space sub-toggle off (rc=$rc, body=$(grep -c 'Phase 4b Approval Accounting' "$BODY_B2" 2>/dev/null) accounting block(s))"; fi

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

# (c2) #615 Codex round 7, finding 1 (fails pre-fix), end-to-end: a first
#      APPROVED whose accounting RENDER FAILS (P4B_ACCT_SELFTEST_FAIL) still
#      posts (plain summary), staging NO ledger record — but its loop was
#      appended to the live log. Pre-fix that loop lingered (commit returned
#      early with no record to rotate), so the SECOND, clean APPROVED of the
#      same PR re-embedded it (two loops) and the running totals double-counted
#      the first approval's attempt/tokens/wall-time. Post-fix the first
#      approval's loop is rotated out on the confirmed post, so the second
#      record embeds ONLY its own loop.
STATE_C2="$WORK/state-c2"; BODY_C2A="$WORK/body-c2a.md"; BODY_C2B="$WORK/body-c2b.md"
set +e
run_orch "$STATE_C2" "$POLICY_ON" fake-codex-approve 240 P4B_WRAPPER_BODY="$BODY_C2A" P4B_ACCT_SELFTEST_FAIL=1 -- >/dev/null 2>&1; rc1=$?
run_orch "$STATE_C2" "$POLICY_ON" fake-codex-approve 240 P4B_WRAPPER_BODY="$BODY_C2B" -- >/dev/null 2>&1; rc2=$?
set -e
REC_C2A="$(p4b_acct_extract_records < "$BODY_C2A" 2>/dev/null || true)"
REC_C2B="$(p4b_acct_extract_records < "$BODY_C2B" 2>/dev/null || true)"
LEDGER_C2="$STATE_C2/phase-4b-ledger.jsonl"
if [ "$rc1" = 0 ] && [ "$rc2" = 0 ] \
   && ! grep -q 'Phase 4b Approval Accounting' "$BODY_C2A" \
   && [ -z "$REC_C2A" ] \
   && printf '%s' "$REC_C2B" | jq -e '(.loops | length) == 1 and .loops[0].loop == 1 and .totals.adapter_invocations == 1' >/dev/null \
   && [ "$(wc -l < "$LEDGER_C2" | tr -d '[:space:]')" = "1" ]; then
  pass "render-fail approval then clean approval of the same PR: the second record embeds only its own loop; the render-failed loop was rotated out (no double-count) (#615 round 7, finding 1)"
else fail "render-fail no-double-count e2e (rc1=$rc1 rc2=$rc2, recA='$REC_C2A', recB loops=$(printf '%s' "$REC_C2B" | jq '.loops|length' 2>/dev/null), ledger-lines=$(wc -l < "$LEDGER_C2" 2>/dev/null))"; fi

# (c3) #615 round 9, CodeRabbit (fails pre-fix): the accounting MODULE is
#      ABSENT entirely. The module-missing contract says accounting is simply
#      off (plain summary posts) — but the round-9 same-head safety gate
#      called its hook unguarded, so the undefined function (exit 127) drove
#      every valid APPROVED into fall_back_to_manual (exit 4).
STATE_C3="$WORK/state-noacct"; BODY_C3="$WORK/body-noacct.md"
# Repo-SHAPED copy (root/scripts/...): lib.sh resolves the repo root two dirs
# above itself, and reviewer selection requires an executable adapter under
# <root>/scripts/phase-4b/adapters — a bare copy of scripts/ would resolve
# the root into $WORK and find no adapters (die 3 before the gate under test).
NOACCT="$WORK/noacct-root"
mkdir -p "$NOACCT"
cp -Rp "$ROOT/scripts" "$NOACCT/scripts"
rm -f "$NOACCT/scripts/phase-4b/accounting.sh"
ORCH_SAVED="$ORCH"; ORCH="$NOACCT/scripts/phase-4b-review.sh"
set +e
out="$(run_orch "$STATE_C3" "$POLICY_ON" fake-codex-approve 306 P4B_WRAPPER_BODY="$BODY_C3" -- 2>"$WORK/noacct.err")"; rc=$?
set -e
ORCH="$ORCH_SAVED"
if [ "$rc" = 0 ] \
   && printf '%s' "$out" | jq -e '.verdict == "APPROVED" and .review_posted == true' >/dev/null \
   && grep -q '^\*\*Automated Phase 4b review\*\*' "$BODY_C3" \
   && ! grep -q 'Phase 4b Approval Accounting' "$BODY_C3" \
   && [ ! -d "$STATE_C3" ]; then
  pass "missing accounting module: a valid APPROVED still posts plain (no undefined-hook manual fallback, no state writes) (#615 round 9 CodeRabbit)"
else fail "module-absent approval regressed (rc=$rc, out=$(printf '%s' "$out" | head -c 200), err=$(tail -c 300 "$WORK/noacct.err" 2>/dev/null))"; fi

# (c4) #615 round 9, CodeRabbit (fails pre-fix), end-to-end: the current
#      loop's record append FAILS (read-only log) while the log holds a prior
#      CR-P1 loop on a DIFFERENT head. The head-advanced APPROVED is valid and
#      must post (pre-fix the gate ran the record-scoped full assertion
#      against the live log, found no clean APPROVED loop — the current one
#      never recorded — and refused to manual fallback).
STATE_C4="$WORK/state-c4"; BODY_C4="$WORK/body-c4.md"
LOG_C4="$(P4B_ACCT_STATE_DIR="$STATE_C4" REPO="o/r" PR=307 p4b_acct_hook_loop_log)"
mkdir -p "$(dirname "$LOG_C4")"
jq -cn --argjson loop "$(mkloop 1 CHANGES_REQUESTED 0 1 false zzz999)" \
  '{schema:"p4b-loop-log/v1", started_at_epoch:null, loop:$loop, details:[]}' > "$LOG_C4"
# Root-robust lock (#615 round 10 Codex): chmod 0444 does not stop root from
# appending (the CI gate runs as root), which would record the current loop,
# rotate the log on approval, and fail the length assertion below. Use the
# same make_file_unappendable/skip seam as the D2 test.
# Capture the helper status OUTSIDE set -e (#615 round 11, Codex P1): a bare
# VAR="$(helper)"; rc=$? dies under the global set -e when the helper returns
# unsupported (root without an immutable-flag tool), so the documented skip
# branch was unreachable in exactly the environment it exists for.
lock_rc=0
LOCK_C4="$(make_file_unappendable "$LOG_C4")" || lock_rc=$?
if [ "$lock_rc" -ne 0 ]; then
  skip "record-append-fail head-advanced gate: no root-robust unwritable seam available ($LOCK_C4) (#615 round 10)"
else
  set +e
  out="$(run_orch "$STATE_C4" "$POLICY_ON" fake-codex-approve 307 P4B_WRAPPER_BODY="$BODY_C4" -- 2>/dev/null)"; rc=$?
  set -e
  restore_file "$LOG_C4" "$LOCK_C4"
  if [ "$rc" = 0 ] \
     && printf '%s' "$out" | jq -e '.verdict == "APPROVED" and .review_posted == true' >/dev/null \
     && grep -q '^\*\*Automated Phase 4b review\*\*' "$BODY_C4" \
     && [ "$(jq -s length "$LOG_C4")" = 1 ]; then
    pass "record-append failure (root-robust lock via $LOCK_C4) + prior-head CR history: the head-advanced APPROVED still posts (live-log gate is same-head-only) (#615 round 9 CodeRabbit)"
  else fail "not-recorded head-advanced approval regressed (lock=$LOCK_C4 rc=$rc, out=$(printf '%s' "$out" | head -c 200))"; fi
fi

# (c5) the safety direction of the same split: identical setup but the prior
#      unresolved CR-P1 sits on the RUN head itself (abc123) — the rerun
#      without a fix commit must STILL be refused to the manual handoff even
#      though its own record append failed (the gate must not need the
#      current loop to enforce the laundering block).
STATE_C5="$WORK/state-c5"; BODY_C5="$WORK/body-c5.md"
LOG_C5="$(P4B_ACCT_STATE_DIR="$STATE_C5" REPO="o/r" PR=308 p4b_acct_hook_loop_log)"
mkdir -p "$(dirname "$LOG_C5")"
jq -cn --argjson loop "$(mkloop 1 CHANGES_REQUESTED 0 1 false abc123)" \
  '{schema:"p4b-loop-log/v1", started_at_epoch:null, loop:$loop, details:[]}' > "$LOG_C5"
lock_rc=0
LOCK_C5="$(make_file_unappendable "$LOG_C5")" || lock_rc=$?
if [ "$lock_rc" -ne 0 ]; then
  skip "record-append-fail same-head block: no root-robust unwritable seam available ($LOCK_C5) (#615 round 10)"
else
  set +e
  out="$(run_orch "$STATE_C5" "$POLICY_ON" fake-codex-approve 308 P4B_WRAPPER_BODY="$BODY_C5" -- 2>/dev/null)"; rc=$?
  set -e
  restore_file "$LOG_C5" "$LOCK_C5"
  if [ "$rc" = 4 ] \
     && printf '%s' "$out" | jq -e '.review_posted == false and .fell_back_to_manual == true' >/dev/null \
     && [ ! -e "$BODY_C5" ]; then
    pass "record-append failure (root-robust lock via $LOCK_C5) does NOT disarm the same-head laundering block: the no-fix rerun is refused to manual (exit 4, nothing posted)"
  else fail "same-head laundering block lost under a failed record append (lock=$LOCK_C5 rc=$rc, out=$(printf '%s' "$out" | head -c 200))"; fi
fi

# (c6) #615 round 10, Codex P2 (fails pre-fix): accounting DISABLED by config
#      (sub-toggle off) with a prior unresolved CR-P1 on the RUN head already
#      in the loop log (recorded while accounting was still enabled). Pre-fix
#      the same-head gate lived INSIDE the p4b_acct_on block, so the opt-out
#      skipped it and the rerun posted a clean APPROVED on the laundered head.
#      The gate now sits OUTSIDE the sub-toggle: history on disk still blocks.
STATE_C6="$WORK/state-c6"; BODY_C6="$WORK/body-c6.md"
LOG_C6="$(P4B_ACCT_STATE_DIR="$STATE_C6" REPO="o/r" PR=309 p4b_acct_hook_loop_log)"
mkdir -p "$(dirname "$LOG_C6")"
jq -cn --argjson loop "$(mkloop 1 CHANGES_REQUESTED 0 1 false abc123)" \
  '{schema:"p4b-loop-log/v1", started_at_epoch:null, loop:$loop, details:[]}' > "$LOG_C6"
set +e
out="$(run_orch "$STATE_C6" "$POLICY_ACCT_OFF" fake-codex-approve 309 P4B_WRAPPER_BODY="$BODY_C6" -- 2>/dev/null)"; rc=$?
set -e
if [ "$rc" = 4 ] \
   && printf '%s' "$out" | jq -e '.review_posted == false and .fell_back_to_manual == true' >/dev/null \
   && [ ! -e "$BODY_C6" ]; then
  pass "accounting opt-out cannot launder a same-head required finding: the gate runs outside the sub-toggle and refuses to manual (#615 round 10 Codex)"
else fail "ACCT-OFF same-head laundering not blocked (rc=$rc, out=$(printf '%s' "$out" | head -c 200))"; fi
# The no-over-block control: same opt-out, prior finding on a DIFFERENT head —
# the valid head-advanced approval still posts plain (no accounting block).
STATE_C6B="$WORK/state-c6b"; BODY_C6B="$WORK/body-c6b.md"
LOG_C6B="$(P4B_ACCT_STATE_DIR="$STATE_C6B" REPO="o/r" PR=310 p4b_acct_hook_loop_log)"
mkdir -p "$(dirname "$LOG_C6B")"
jq -cn --argjson loop "$(mkloop 1 CHANGES_REQUESTED 0 1 false zzz999)" \
  '{schema:"p4b-loop-log/v1", started_at_epoch:null, loop:$loop, details:[]}' > "$LOG_C6B"
set +e
out="$(run_orch "$STATE_C6B" "$POLICY_ACCT_OFF" fake-codex-approve 310 P4B_WRAPPER_BODY="$BODY_C6B" -- 2>/dev/null)"; rc=$?
set -e
if [ "$rc" = 0 ] \
   && printf '%s' "$out" | jq -e '.verdict == "APPROVED" and .review_posted == true' >/dev/null \
   && ! grep -q 'Phase 4b Approval Accounting' "$BODY_C6B"; then
  pass "accounting opt-out with prior-head-only history still posts the plain approval (gate does not over-block) (#615 round 10)"
else fail "ACCT-OFF head-advanced approval over-blocked (rc=$rc, out=$(printf '%s' "$out" | head -c 200))"; fi

# (d) changes-requested-then-fixed across two invocations: loop history
#     accumulates and the final approval renders both loops + the lifecycle.
#     The fix lands as a NEW head (def456), so the loop-1 finding must be
#     labeled historical, never current-head (#615 Codex).
STATE_D="$WORK/state-d"; BODY_D1="$WORK/body-d1.md"; BODY_D2="$WORK/body-d2.md"
set +e
run_orch "$STATE_D" "$POLICY_ON" fake-codex-changes 204 P4B_WRAPPER_BODY="$BODY_D1" -- >/dev/null 2>&1; rc1=$?
run_orch "$STATE_D" "$POLICY_ON" fake-codex-approve 204 \
  P4B_WRAPPER_BODY="$BODY_D2" P4B_FAKE_LIVE_HEAD=def456 P4B_FAKE_CREATED_REVIEW_HEAD=def456 \
  -- --head def456 >/dev/null 2>&1; rc2=$?
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
if printf '%s' "$REC_D" | jq -e '
     .final_head_sha == "def456"
     and .unique_findings[0].path == "x.js" and .unique_findings[0].line == 2
     and .unique_findings[0].title == "bug here"' >/dev/null 2>&1 \
   && grep -qF '| F1 | P1 | `x.js:2` | bug here | historical | 1 | 1 | unresolved | — |' "$BODY_D2" \
   && grep -qF 'Unique findings across loops: 1 — 0 on the approved head, 1 historical (earlier loops only).' "$BODY_D2"; then
  pass "fixed-then-approved: the prior-commit finding renders with content and a historical label (#615)"
else fail "historical labeling end-to-end (rec=$REC_D, body=$(grep -F '| F1 ' "$BODY_D2" 2>/dev/null))"; fi

# (d2) #615 Codex round 5 (fails pre-fix): when recording THIS invocation's
#      loop fails (an unwritable loop-log) but the log ALREADY holds a clean
#      APPROVED loop, the orchestrator must SKIP the accounting block rather
#      than render it from the stale log. Pre-fix the render ran off the stale
#      log and appended a block stamped with the CURRENT head claiming that
#      head was reviewed while silently OMITTING the current loop (a HEAD-
#      stamped block that misses this invocation entirely). The plain-summary
#      approval still posts (exit 0); accounting is advisory.
#
# Root-safe injection (#615 round 6, fails pre-fix under root): the earlier
# `chmod 0444` seam did NOT make the append fail as root (CI runs the gate as
# root), so under root the second run recorded another loop and DID render —
# the exact `record-failure skips render ... blockB=1` failure Codex flagged.
# make_file_unappendable now uses chmod as a non-root user and the filesystem
# immutable flag as root (blocks even root, keeps the file readable). Post
# round-6 the first APPROVED run rotates its consumed loop out of the live log,
# so we re-seed the live log from the archive to recreate the exact
# "log holds a prior approved loop the stale render could build from" premise.
STATE_D2="$WORK/state-d2"; BODY_D2A="$WORK/body-d2a.md"; BODY_D2B="$WORK/body-d2b.md"
set +e
# First invocation (APPROVED) records + posts loop 1 normally (block present).
run_orch "$STATE_D2" "$POLICY_ON" fake-codex-approve 220 P4B_WRAPPER_BODY="$BODY_D2A" -- >/dev/null 2>&1; rc1=$?
# The live loop log is `*.jsonl`; the round-6 rotation archive is `*.jsonl.archive`
# (never matched by `-name '*.jsonl'`). Re-seed the (now empty) live log with the
# archived approved loop so the render read finds a clean approved loop while the
# CURRENT record-loop append fails.
LOG_D2="$(find "$STATE_D2/phase-4b-loops" -name '*.jsonl' 2>/dev/null | head -n1)"
ARCHIVE_D2="${LOG_D2}.archive"
[ -s "$ARCHIVE_D2" ] && cat "$ARCHIVE_D2" > "$LOG_D2"
LOCK_D2="$(make_file_unappendable "$LOG_D2")"; lock_rc=$?
if [ "$lock_rc" -ne 0 ]; then
  skip "record-failure skip-render root-safety: no root-robust unwritable seam available ($LOCK_D2); cannot exercise the record-loop failure path here (#615 round 6)"
else
  run_orch "$STATE_D2" "$POLICY_ON" fake-codex-approve 220 P4B_WRAPPER_BODY="$BODY_D2B" -- >/dev/null 2>&1; rc2=$?
  restore_file "$LOG_D2" "$LOCK_D2"
  if [ "$rc1" = 0 ] && [ "$rc2" = 0 ] \
     && grep -q 'Phase 4b Approval Accounting' "$BODY_D2A" \
     && grep -q '^\*\*Automated Phase 4b review\*\*' "$BODY_D2B" \
     && ! grep -q 'Phase 4b Approval Accounting' "$BODY_D2B"; then
    pass "record-loop failure (root-robust unwritable log via $LOCK_D2) skips the accounting block even when the stale log holds an approved loop; plain summary posts, exit 0 (#615 rounds 5+6)"
  else fail "record-failure skips render (lock=$LOCK_D2 rc1=$rc1 rc2=$rc2, blockA=$(grep -c 'Phase 4b Approval Accounting' "$BODY_D2A" 2>/dev/null) blockB=$(grep -c 'Phase 4b Approval Accounting' "$BODY_D2B" 2>/dev/null))"; fi
fi
set -e

# (e) findings-bearing APPROVED verdict → existing fail-closed fallback (exit
#     4) preserved; the fail-closed loop is recorded as safety evidence. Runs
#     WITHOUT --dry-run since #615 round 11 (dry-runs no longer persist state);
#     the fallback fires before any posting, so the recorded shape is the same.
STATE_E="$WORK/state-e"
set +e
run_orch "$STATE_E" "$POLICY_ON" fake-codex-approve-p2 205 -- >/dev/null 2>&1; rc=$?
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

# (f) dry-run APPROVED → exit 0, dry-run never contaminates ANY persistent
#     accounting state (#615 round 11, Codex P2, fails pre-fix for the loop
#     log): the ledger stays absent AND no per-PR loop log is written — the
#     simulated loop lands only in the throwaway sandbox.
STATE_F="$WORK/state-f"
set +e
run_orch "$STATE_F" "$POLICY_ON" fake-codex-approve 206 -- --dry-run >/dev/null 2>&1; rc=$?
set -e
if [ "$rc" = 0 ] && [ ! -e "$STATE_F/phase-4b-ledger.jsonl" ] \
   && [ -z "$(find "$STATE_F/phase-4b-loops" -name '*.jsonl' 2>/dev/null)" ]; then
  pass "dry-run renders without persisting the ledger OR the per-PR loop log (#615 round 11)"
else fail "dry-run state hygiene (rc=$rc, loops=$(find "$STATE_F/phase-4b-loops" -type f 2>/dev/null | head -3))"; fi

# (f2) #615 round 11, Codex P2 (fails pre-fix): rehearsal history must not
#      leak into real accounting. Pre-fix, a dry-run loop stayed in the live
#      per-PR log (never rotated — nothing posted), so the NEXT real approval
#      of the same PR embedded the rehearsal loop in its record and counted
#      its attempt in the totals. Post-fix the real run records only itself.
STATE_F2="$WORK/state-f2"; BODY_F2="$WORK/body-f2.md"
set +e
run_orch "$STATE_F2" "$POLICY_ON" fake-codex-approve 207 -- --dry-run >/dev/null 2>&1; rc1=$?
run_orch "$STATE_F2" "$POLICY_ON" fake-codex-approve 207 P4B_WRAPPER_BODY="$BODY_F2" -- >/dev/null 2>&1; rc2=$?
set -e
REC_F2="$(p4b_acct_extract_records < "$BODY_F2" 2>/dev/null || true)"
if [ "$rc1" = 0 ] && [ "$rc2" = 0 ] \
   && printf '%s' "$REC_F2" | jq -e '
        (.loops | length) == 1 and .loops[0].loop == 1
        and .totals.adapter_invocations == 1' >/dev/null \
   && [ "$(wc -l < "$STATE_F2/phase-4b-ledger.jsonl" | tr -d '[:space:]')" = "1" ]; then
  pass "a dry-run rehearsal leaves no trace in the next real approval: one loop, one attempt, one ledger record (#615 round 11)"
else fail "dry-run rehearsal leaked into real accounting (rc1=$rc1 rc2=$rc2, loops=$(printf '%s' "$REC_F2" | jq '.loops|length' 2>/dev/null), invocations=$(printf '%s' "$REC_F2" | jq '.totals.adapter_invocations' 2>/dev/null))"; fi

# (f3) dry-run gate fidelity: with REAL history holding an unresolved CR-P1 on
#      the run head, a dry-run APPROVED rehearsal must predict the refusal
#      (exit 4) — the sandbox COPIES real state — while the real log stays
#      byte-identical (still exactly the seeded loop).
STATE_F3="$WORK/state-f3"
LOG_F3="$(P4B_ACCT_STATE_DIR="$STATE_F3" REPO="o/r" PR=208 p4b_acct_hook_loop_log)"
mkdir -p "$(dirname "$LOG_F3")"
jq -cn --argjson loop "$(mkloop 1 CHANGES_REQUESTED 0 1 false abc123)" \
  '{schema:"p4b-loop-log/v1", started_at_epoch:null, loop:$loop, details:[]}' > "$LOG_F3"
F3_BEFORE="$(cat "$LOG_F3")"
set +e
run_orch "$STATE_F3" "$POLICY_ON" fake-codex-approve 208 -- --dry-run >/dev/null 2>&1; rc=$?
set -e
if [ "$rc" = 4 ] && [ "$(cat "$LOG_F3")" = "$F3_BEFORE" ]; then
  pass "a dry-run rehearsal predicts the same-head refusal from copied real history without touching the real log (#615 round 11)"
else fail "dry-run gate fidelity (rc=$rc, log-changed=$([ "$(cat "$LOG_F3")" = "$F3_BEFORE" ] && echo no || echo yes))"; fi

# (g) parent automation disabled → exit 5 unchanged, zero accounting writes.
STATE_G="$WORK/state-g"
set +e
env PATH="$BIN:$PATH" MERGEPATH_REVIEW_POLICY_PATH="$POLICY_OFF" P4B_ACCT_STATE_DIR="$STATE_G" \
  bash "$ORCH" 207 --repo o/r >/dev/null 2>&1; rc=$?
set -e
if [ "$rc" = 5 ] && [ ! -d "$STATE_G" ]; then
  pass "disabled parent still exits 5 with no accounting side effects"
else fail "disabled parent (rc=$rc)"; fi

# (g2) #615 round 3 (fails pre-fix): a downstream policy that OMITS the
#      parent enabled while the nested accounting sub-toggle says true must
#      take the documented default-disabled path (exit 5) — the flat
#      scanner used to read the sub-toggle as the master switch and RUN the
#      orchestrator (it posted a full review here pre-fix).
STATE_G2="$WORK/state-g2"
set +e
out="$(run_orch "$STATE_G2" "$POLICY_NESTED_ONLY" fake-codex-approve 214 -- 2>/dev/null)"; rc=$?
set -e
if [ "$rc" = 5 ] && [ ! -d "$STATE_G2" ] \
   && printf '%s' "$out" | jq -e '.skipped == true and .reason == "automation-disabled"' >/dev/null; then
  pass "the accounting sub-toggle alone cannot enable the orchestrator (exit 5, no writes) (#615 round 3)"
else fail "nested-toggle orchestrator gate (rc=$rc, out=$out)"; fi

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

# (i) head drift during the APPROVED post (#615 Codex): the provisionally
#     recorded loop must be corrected to not-posted/fail-closed (one line, no
#     duplicate fallback loop) and the staged ledger record discarded — local
#     state never claims a phantom posted approval.
STATE_I="$WORK/state-i"
set +e
run_orch "$STATE_I" "$POLICY_ON" fake-codex-approve 209 P4B_FAKE_LIVE_HEAD=zzz999 -- >/dev/null 2>&1; rc=$?
set -e
LOG_I="$(find "$STATE_I/phase-4b-loops" -name '*.jsonl' 2>/dev/null | head -n1)"
if [ "$rc" = 4 ] \
   && [ ! -e "$STATE_I/phase-4b-ledger.jsonl" ] \
   && [ -z "$(find "$STATE_I/phase-4b-pending" -type f 2>/dev/null)" ] \
   && [ -n "$LOG_I" ] \
   && jq -e -s '
        length == 1
        and .[0].loop.verdict == "APPROVED"
        and .[0].loop.posted == "not-posted"
        and .[0].loop.fell_back == true
        and .[0].loop.fail_closed.happened == true
        and (.[0].loop.fail_closed.reason | test("head changed"))' "$LOG_I" >/dev/null; then
  pass "head drift after the provisional record: loop corrected in place, no phantom ledger approval, exit 4 (#615)"
else fail "head-drift correction (rc=$rc, ledger=$(cat "$STATE_I/phase-4b-ledger.jsonl" 2>/dev/null), log=$(cat "$LOG_I" 2>/dev/null))"; fi

# (j) review POST failure (#615 Codex): same correction on the gh-write
#     failure path — exit 3 preserved, no ledger record, loop marked
#     not-posted with the failure disposition.
STATE_J="$WORK/state-j"
set +e
run_orch "$STATE_J" "$POLICY_ON" fake-codex-approve 210 P4B_FAKE_WRAPPER_FAIL=1 -- >/dev/null 2>&1; rc=$?
set -e
LOG_J="$(find "$STATE_J/phase-4b-loops" -name '*.jsonl' 2>/dev/null | head -n1)"
if [ "$rc" = 3 ] \
   && [ ! -e "$STATE_J/phase-4b-ledger.jsonl" ] \
   && [ -z "$(find "$STATE_J/phase-4b-pending" -type f 2>/dev/null)" ] \
   && [ -n "$LOG_J" ] \
   && jq -e -s '
        length == 1
        and .[0].loop.verdict == "APPROVED"
        and .[0].loop.posted == "not-posted"
        and .[0].loop.fell_back == true
        and .[0].loop.fail_closed.happened == true
        and (.[0].loop.fail_closed.reason | test("POST failed"))' "$LOG_J" >/dev/null; then
  pass "review POST failure: loop corrected to not-posted, ledger untouched, exit 3 preserved (#615)"
else fail "POST-failure correction (rc=$rc, ledger=$(cat "$STATE_J/phase-4b-ledger.jsonl" 2>/dev/null), log=$(cat "$LOG_J" 2>/dev/null))"; fi

# (j2) Same-head required-finding SAFETY gate via the REAL orchestrator path
#      (#615 Codex round 9, finding 2). FAILS pre-fix: the fail-closed invariant
#      (an APPROVED verdict may never carry an unresolved required-tier finding
#      on the CURRENT head) lived only inside p4b_acct_build_record — a same-head
#      laundered approval made the record builder return non-zero, the render
#      hook propagated that as an ordinary ADVISORY report-generation failure,
#      and the orchestrator posted the plain-summary APPROVED anyway. Pre-seed
#      the live loop log with a prior CHANGES_REQUESTED + P1 on head abc123 (the
#      log has NOT rotated because no approval posted), then run the orchestrator
#      on the SAME head abc123 with a clean APPROVED (no fix commit). The
#      approval MUST now be REFUSED via the manual handoff (exit 4), the review
#      MUST NOT post, and no ledger record is written.
STATE_J2="$WORK/state-j2"; BODY_J2="$WORK/body-j2.md"
mkdir -p "$STATE_J2/phase-4b-loops"
# Loop-log line shape matches p4b_acct_hook_record_loop output (top-level
# {schema, started_at_epoch, loop:{…}, details:[…]}); the render/guard read .loop.
jq -nc '{schema:"p4b-loop-log/v1", started_at_epoch:1700000000,
  loop:{loop:1, reviewer:"nathanpayne-codex", adapter:"review-via-codex.sh",
    direction:"claude->codex", head_sha:"abc123", verdict:"CHANGES_REQUESTED",
    posted:"posted", fell_back:false, elapsed_seconds:10,
    tokens:{total:null,input:null,output:null,cache_creation:null,cache_read:null,reasoning:null,cost_usd:null,source:"unavailable"},
    findings:{P0:0,P1:1,P2:0,P3:0,nitpick:0,unknown:0},
    cli_version:null, timeout_seconds:900, effort:null, throttle_events:null,
    plan_auth:"chatgpt", fail_closed:{happened:false,reason:null,duration_seconds:null}},
  details:[{loop:1,severity:"P1",path:"x.js",line:2,body:"bug here"}]}' \
  > "$STATE_J2/phase-4b-loops/o-r-pr234.jsonl"
set +e
out="$(run_orch "$STATE_J2" "$POLICY_ON" fake-codex-approve 234 P4B_WRAPPER_BODY="$BODY_J2" -- 2>/dev/null)"; rc=$?
set -e
if [ "$rc" = 4 ] \
   && printf '%s' "$out" | jq -e '.review_posted == false and .fell_back_to_manual == true
        and (.reason | test("required-tier finding was recorded on the current head"))' >/dev/null \
   && [ ! -s "$BODY_J2" ] \
   && [ ! -e "$STATE_J2/phase-4b-ledger.jsonl" ]; then
  pass "a clean APPROVED rerun on the SAME head as a prior unresolved required finding is REFUSED (exit 4, no post) via the orchestrator (finding 2)"
else fail "same-head required block via review path (rc=$rc, out=$out, body_bytes=$(wc -c < "$BODY_J2" 2>/dev/null), ledger=$( [ -e "$STATE_J2/phase-4b-ledger.jsonl" ] && echo present || echo absent))"; fi
# Control: the SAME prior CR+P1 on abc123, but the approval lands on a NEW head
# (def456 = a real fix commit) still POSTS — the guard permits the legitimate
# changes-requested-then-fixed path and does not over-block.
STATE_J2B="$WORK/state-j2b"; BODY_J2B="$WORK/body-j2b.md"
mkdir -p "$STATE_J2B/phase-4b-loops"
jq -nc '{schema:"p4b-loop-log/v1", started_at_epoch:1700000000,
  loop:{loop:1, reviewer:"nathanpayne-codex", adapter:"review-via-codex.sh",
    direction:"claude->codex", head_sha:"abc123", verdict:"CHANGES_REQUESTED",
    posted:"posted", fell_back:false, elapsed_seconds:10,
    tokens:{total:null,input:null,output:null,cache_creation:null,cache_read:null,reasoning:null,cost_usd:null,source:"unavailable"},
    findings:{P0:0,P1:1,P2:0,P3:0,nitpick:0,unknown:0},
    cli_version:null, timeout_seconds:900, effort:null, throttle_events:null,
    plan_auth:"chatgpt", fail_closed:{happened:false,reason:null,duration_seconds:null}},
  details:[{loop:1,severity:"P1",path:"x.js",line:2,body:"bug here"}]}' \
  > "$STATE_J2B/phase-4b-loops/o-r-pr235.jsonl"
set +e
out="$(env PATH="$BIN:$PATH" MERGEPATH_REVIEW_POLICY_PATH="$POLICY_ON" \
  P4B_ACCT_STATE_DIR="$STATE_J2B" CODEX_BIN="$BIN/fake-codex-approve" \
  P4B_GH_AS_REVIEWER="$BIN/fake-gh-as-reviewer" P4B_FAKE_LIVE_HEAD=def456 \
  P4B_FAKE_CREATED_REVIEW_HEAD=def456 P4B_WRAPPER_BODY="$BODY_J2B" \
  bash "$ORCH" 235 --repo o/r --author claude --head def456 --diff-file "$DIFF" 2>/dev/null)"; rc=$?
set -e
if [ "$rc" = 0 ] \
   && printf '%s' "$out" | jq -e '.verdict == "APPROVED" and .review_posted == true' >/dev/null; then
  pass "a clean approval on a NEW head (real fix commit) still posts despite a prior same-PR required finding on the old head (finding 2, no over-block)"
else fail "new-head fix still posts (rc=$rc, out=$out)"; fi

# (k) totals-from-GitHub fetch path (#615 round 2, fails pre-fix): the real
#     orchestrator path never set P4B_ACCT_PRIOR_RECORDS_JSONL, so running
#     totals always fell through to the gitignored local ledger — a fresh
#     checkout reported unavailable/local-only even when prior PRs embedded
#     records. The hook now fetches prior review bodies itself (shimmed gh).
STATE_K="$WORK/state-k"; BODY_K="$WORK/body-k.md"
set +e
out="$(run_orch "$STATE_K" "$POLICY_ON" fake-codex-approve 211 \
  P4B_WRAPPER_BODY="$BODY_K" P4B_FAKE_PRIOR_BODIES="$PRIOR_BODY" -- 2>/dev/null)"; rc=$?
set -e
REC_K="$(p4b_acct_extract_records < "$BODY_K" 2>/dev/null || true)"
if [ "$rc" = 0 ] && [ -n "$REC_K" ] \
   && printf '%s' "$REC_K" | jq -e '
        .running_totals.source == "github-derived"
        and .running_totals.records == 1
        and .running_totals.auto_approved_prs == 1
        and .running_totals.automated_attempts == 4' >/dev/null \
   && grep -qF '*Totals source: github-derived (1 prior record(s)).*' "$BODY_K"; then
  pass "posted approval aggregates GitHub-fetched prior records into repo-wide running totals (#615 round 2)"
else fail "github-derived totals e2e (rc=$rc, rec=$REC_K)"; fi

# (k2) truncated-scan e2e (#615 round 3, fails pre-fix): when the page cap
#      leaves history unscanned, the POSTED body labels the totals as a
#      bounded window (heading + footer) and the embedded record carries
#      the window object — never an unearned repo-wide claim.
STATE_K2="$WORK/state-k2"; BODY_K2="$WORK/body-k2.md"
set +e
out="$(run_orch "$STATE_K2" "$POLICY_ON" fake-codex-approve 215 \
  P4B_WRAPPER_BODY="$BODY_K2" P4B_FAKE_GRAPHQL_PAGE_DIR="$PAGES_DIR" \
  P4B_ACCT_PRIOR_SCAN_PAGES=1 -- 2>/dev/null)"; rc=$?
set -e
REC_K2="$(p4b_acct_extract_records < "$BODY_K2" 2>/dev/null || true)"
if [ "$rc" = 0 ] && [ -n "$REC_K2" ] \
   && printf '%s' "$REC_K2" | jq -e '
        .running_totals.source == "github-derived"
        and .running_totals.records == 1
        and .running_totals.window.truncated == true
        and .running_totals.window.scanned_prs == 2' >/dev/null \
   && grep -q '^### Running totals — window: last 2 merged PRs$' "$BODY_K2" \
   && ! grep -q 'repo, to date' "$BODY_K2" \
   && grep -qF 'window: last 2 merged PRs — older history beyond the scan cap is not included' "$BODY_K2"; then
  pass "a cap-truncated scan posts window-labeled totals end-to-end, never a repo-wide claim (#615 round 3)"
else fail "truncated-window e2e (rc=$rc, rec=$REC_K2, heading=$(grep '### Running totals' "$BODY_K2" 2>/dev/null))"; fi

# (l) fetch failure → the ledger fallback stays EXPLICITLY labeled
#     ledger-cache in the posted body — local-only totals are never silently
#     presented as repo-wide (post-fix guard; pre-fix the ledger was the only
#     real source, so this asserts the new failure path keeps the label).
STATE_L="$WORK/state-l"; BODY_L="$WORK/body-l.md"
mkdir -p "$STATE_L"
printf '%s\n' "$GOLDEN" > "$STATE_L/phase-4b-ledger.jsonl"
set +e
out="$(run_orch "$STATE_L" "$POLICY_ON" fake-codex-approve 212 \
  P4B_WRAPPER_BODY="$BODY_L" P4B_FAKE_GRAPHQL_FAIL=1 -- 2>/dev/null)"; rc=$?
set -e
REC_L="$(p4b_acct_extract_records < "$BODY_L" 2>/dev/null || true)"
if [ "$rc" = 0 ] && [ -n "$REC_L" ] \
   && printf '%s' "$REC_L" | jq -e '
        .running_totals.source == "ledger-cache" and .running_totals.records == 1' >/dev/null \
   && grep -qF '*Totals source: ledger-cache (1 prior record(s)).*' "$BODY_L"; then
  pass "fetch failure posts ledger-cache totals under the explicit local-only label (#615 round 2)"
else fail "ledger-fallback e2e (rc=$rc, rec=$REC_L)"; fi

# (m) CLI-reported cost end-to-end (#615 round 2, fails pre-fix): a claude
#     reviewer loop whose envelope reports total_cost_usd must surface it in
#     the posted record (tokens.cost_usd, fail-closed reported total) and the
#     cost row must prefer it over notional, labeled CLI-reported.
STATE_M="$WORK/state-m"; BODY_M="$WORK/body-m.md"
set +e
out="$(env PATH="$BIN:$PATH" \
  MERGEPATH_REVIEW_POLICY_PATH="$POLICY_ON" \
  P4B_ACCT_STATE_DIR="$STATE_M" \
  CLAUDE_BIN="$BIN/fake-claude-cache-usage" \
  P4B_GH_AS_REVIEWER="$BIN/fake-gh-as-reviewer" \
  P4B_FAKE_LIVE_HEAD=abc123 \
  P4B_WRAPPER_BODY="$BODY_M" \
  bash "$ORCH" 213 --repo o/r --author codex --reviewer nathanpayne-claude \
    --head abc123 --diff-file "$DIFF" 2>/dev/null)"; rc=$?
set -e
REC_M="$(p4b_acct_extract_records < "$BODY_M" 2>/dev/null || true)"
if [ "$rc" = 0 ] && [ -n "$REC_M" ] \
   && printf '%s' "$REC_M" | jq -e '
        .loops[0].tokens.cost_usd == 0.42
        and .totals.reported_cost_usd == 0.42' >/dev/null \
   && grep -qF -- '~$0.42 *(not billed; CLI-reported)*' "$BODY_M"; then
  pass "claude envelope total_cost_usd flows into the posted record and the cost row prefers it (#615 round 2)"
else fail "reported-cost e2e (rc=$rc, rec=$REC_M)"; fi

echo
echo "Summary: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -eq 0 ]
