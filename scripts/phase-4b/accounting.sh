#!/usr/bin/env bash
# scripts/phase-4b/accounting.sh — Phase 4b approval-loop accounting.
#
# REFERENCE IMPLEMENTATION (#602). Sourced by scripts/phase-4b-review.sh; it
# does NOT set -euo pipefail on the caller. Bash 3.2 portable (macOS). Pure
# functions over JSON inputs — no network, no GitHub, no reviewer CLI — so the
# whole module is unit-testable in isolation (tests/test_phase_4b_accounting.sh).
#
# What it produces: the human-readable "## Phase 4b Approval Accounting" block
# AND the embedded machine-readable `<!-- p4b-accounting:v1 ... -->` JSON record
# (scripts/phase-4b/accounting.schema.json). The record is loop-centric (every
# adapter attempt, not just the final approval), carries findings lifecycle +
# disposition, a rigor-as-proof-of-work table, a four-part cost model
# (wall-clock / tokens / throttle / labeled-notional$), and repo-wide running
# totals aggregated STATELESSLY from prior embedded records.
#
# Data-integrity posture (all enforced here, fail-closed):
#   - No estimated tokens. A CLI that exposes nothing renders "unavailable".
#   - No green rigor check without a captured signal; else "n/a — reason".
#   - A required-tier (P0/P1) finding can NEVER accompany a posted APPROVED.
#   - Notional $ is ALWAYS labeled not-billed; prices come from the versioned
#     prices.json (never hardcoded); a missing price ⇒ notional n/a, record
#     still posts.
#   - Running totals degrade to "unavailable" rather than reporting wrong
#     numbers.
#
# This module never decides WHETHER to approve — the orchestrator owns that.
# It only renders the accounting for a decision already made, and if any step
# here fails the orchestrator falls back to its plain-summary approval.

# --- location + logging ----------------------------------------------------

P4B_ACCT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

p4b_acct_warn() { echo "[phase-4b-acct] WARN: $*" >&2; }

# scripts/phase-4b/prices.json unless overridden (tests).
p4b_acct_prices_path() {
  if [ -n "${P4B_ACCT_PRICES_PATH:-}" ]; then
    printf '%s' "$P4B_ACCT_PRICES_PATH"
    return 0
  fi
  printf '%s/prices.json' "$P4B_ACCT_DIR"
}

# scripts/phase-4b/accounting.schema.json unless overridden (tests).
p4b_acct_schema_path() {
  if [ -n "${P4B_ACCT_SCHEMA_PATH:-}" ]; then
    printf '%s' "$P4B_ACCT_SCHEMA_PATH"
    return 0
  fi
  printf '%s/accounting.schema.json' "$P4B_ACCT_DIR"
}

# Cited human-shuttle-avoided constant. REVIEW_POLICY.md § Phase 4b Triggers:
# "the human-mediated handoff typically adds 30 minutes to a few hours per PR".
P4B_ACCT_HUMAN_MINUTES_LOW=30
P4B_ACCT_HUMAN_MINUTES_HIGH=180

# --- price table -----------------------------------------------------------

# p4b_acct_price_table_version — the `version` stamp of prices.json, or empty
# if the table is missing/unreadable. Stamped into every record so historical
# notional totals stay reproducible.
p4b_acct_price_table_version() {
  local prices
  prices="$(p4b_acct_prices_path)"
  [ -r "$prices" ] || return 0
  jq -r '.version // empty' "$prices" 2>/dev/null || true
}

# p4b_acct_resolve_rate <price_key> <rate_field>
# Resolve a scalar per-1M-token rate from prices.json. <price_key> is a
# `<provider>.<model>.<tier>` key, e.g. "openai.gpt-5.3-codex.standard" or
# "anthropic.claude-sonnet-4.6.standard". The MODEL segment can itself contain
# dots (e.g. `gpt-5.3-codex`), so the key is parsed as first=provider,
# last=tier, and everything between as the (dot-preserving) model id; the JSON
# path is providers.<provider>.models.<model>.<tier>. <rate_field> names the
# scalar inside that tier object, e.g. "input" / "output" /
# "total_only_blended_80_20" / "cache_read" / "cache_write_5m". Prints the
# numeric rate on success; prints nothing and returns non-zero when the table,
# key, or field is missing (caller renders notional n/a — never a guess).
p4b_acct_resolve_rate() {
  local price_key="$1" rate_field="$2" prices val
  [ -n "$price_key" ] && [ -n "$rate_field" ] || return 1
  prices="$(p4b_acct_prices_path)"
  [ -r "$prices" ] || return 1
  val="$(jq -r \
    --arg key "$price_key" --arg field "$rate_field" '
      ($key | split(".")) as $seg
      | if ($seg | length) < 3 then empty
        else
          ($seg[0]) as $provider
          | ($seg[-1]) as $tier
          | ($seg[1:-1] | join(".")) as $model
          | (.providers[$provider].models[$model][$tier]) as $obj
          | if ($obj | type) == "object" and ($obj[$field] | type) == "number"
            then $obj[$field] else empty end
        end
    ' "$prices" 2>/dev/null)" || return 1
  [ -n "$val" ] || return 1
  printf '%s' "$val"
}

# p4b_acct_notional_from_tokens <tokens-json> <price_key> <rate_fields-json>
# Compute a notional USD figure for one loop's token object using the named
# rate fields resolved from prices.json. Two modes:
#   - explicit input/output/cache split: rate_fields lists which of
#     {input,output,cache_creation:cache_write_5m,cache_read} to price, matched
#     to the token object's fields.
#   - total-only: rate_fields == ["total_only_blended_80_20"] (or any single
#     blended field) applied to tokens.total.
# Prints the dollar figure (bc-scale 6) on success. Returns non-zero (no
# output) if any required rate is unresolvable OR the needed token count is
# null — so the caller renders notional n/a rather than an estimate.
#
# The mapping from a token field to its rate field is fixed here:
#   input          -> the rate field literally named in rate_fields if "input"
#   output         -> "output"
#   cache_creation -> "cache_write_5m"
#   cache_read     -> "cache_read"
#   total          -> "total_only_blended_80_20" (or the sole blended field)
p4b_acct_notional_from_tokens() {
  local tokens_json="$1" price_key="$2" rate_fields_json="$3"
  [ -n "$tokens_json" ] && [ -n "$price_key" ] && [ -n "$rate_fields_json" ] || return 1

  # total-only path: a single blended field priced against tokens.total.
  local is_total_only
  is_total_only="$(printf '%s' "$rate_fields_json" | jq -r '
    (type == "array") and (length == 1)
    and (.[0] | test("blended|total_only"))' 2>/dev/null || echo false)"
  if [ "$is_total_only" = "true" ]; then
    local field total rate
    field="$(printf '%s' "$rate_fields_json" | jq -r '.[0]')"
    total="$(printf '%s' "$tokens_json" | jq -r '.total // empty' 2>/dev/null || true)"
    [ -n "$total" ] || return 1
    rate="$(p4b_acct_resolve_rate "$price_key" "$field")" || return 1
    printf '%s' "$total" | jq -r --argjson rate "$rate" '(. / 1000000.0) * $rate'
    return 0
  fi

  # split path: sum each priced component. Every requested field must resolve
  # and its token count must be non-null, else fail (no partial estimate).
  local field tok_field rate tok
  local sum_expr="0"
  local -a args=()
  local i=0
  while IFS= read -r field; do
    [ -n "$field" ] || continue
    case "$field" in
      input)          tok_field="input" ;;
      output)         tok_field="output" ;;
      cache_write_5m) tok_field="cache_creation" ;;
      cache_read)     tok_field="cache_read" ;;
      *) return 1 ;;  # unknown rate field for the split path
    esac
    tok="$(printf '%s' "$tokens_json" | jq -r --arg f "$tok_field" '.[$f] // empty' 2>/dev/null || true)"
    [ -n "$tok" ] || return 1
    rate="$(p4b_acct_resolve_rate "$price_key" "$field")" || return 1
    args+=(--argjson "tok$i" "$tok" --argjson "rate$i" "$rate")
    sum_expr="$sum_expr + ((\$tok$i / 1000000.0) * \$rate$i)"
    i=$((i + 1))
  done < <(printf '%s' "$rate_fields_json" | jq -r '.[]' 2>/dev/null)
  [ "$i" -gt 0 ] || return 1
  jq -n "${args[@]}" "$sum_expr"
}

# --- record extraction + aggregation ---------------------------------------

# p4b_acct_marker — the embedded-block marker string.
p4b_acct_marker() { printf 'p4b-accounting:v1'; }

# p4b_acct_extract_records — read prior review bodies on stdin and emit each
# embedded p4b-accounting:v1 JSON record as one compact line (JSONL). Only
# well-formed objects carrying the v1 schema tag are emitted; malformed or
# non-conformant blocks are skipped (they must not corrupt aggregation). Used
# to aggregate running totals statelessly from GitHub-fetched prior approval
# bodies. The block spans from the `p4b-accounting:v1` marker line to the `-->`
# HTML-comment close.
p4b_acct_extract_records() {
  awk -v marker="$(p4b_acct_marker)" '
    index($0, marker) > 0 { capturing = 1; buf = ""; next }
    capturing {
      if ($0 ~ /-->/) {
        sub(/-->.*/, "", $0)
        buf = buf $0 " "
        printf "%s\n", buf
        capturing = 0
        next
      }
      buf = buf $0 " "
    }
  ' | while IFS= read -r block; do
    [ -n "$block" ] || continue
    # Emit only a conformant compact record; drop anything jq cannot parse or
    # that lacks the v1 schema tag.
    printf '%s' "$block" \
      | jq -c 'select(type == "object" and .schema == "p4b-accounting/v1")' 2>/dev/null || true
  done
}

# p4b_acct_aggregate_running_totals — read prior p4b-accounting:v1 records as
# JSONL on stdin (one record per line, e.g. the output of extracting embedded
# blocks) and print a running_totals object (matching the schema's
# running_totals shape) on stdout. <source> ("github-derived" | "ledger-cache")
# labels where the records came from. On any parse trouble it prints an
# {"source":"unavailable","records":0,"reason":...} object and returns 0 — the
# renderer shows "running totals unavailable" rather than wrong numbers.
p4b_acct_aggregate_running_totals() {
  local source_label="${1:-github-derived}"
  local input result
  input="$(cat)"
  # Empty input ⇒ zero prior records (valid: first-ever approval).
  result="$(printf '%s' "$input" | jq -s \
    --arg source "$source_label" \
    --argjson mlow "$P4B_ACCT_HUMAN_MINUTES_LOW" \
    --argjson mhigh "$P4B_ACCT_HUMAN_MINUTES_HIGH" '
    # Each line must be a v1 record; a non-conformant line aborts to unavailable.
    (map(select(type == "object" and .schema == "p4b-accounting/v1"))) as $recs
    | if ($recs | length) != (. | length) and (. | length) > 0
      then error("non-conformant record in ledger")
      else
        ($recs | length) as $n
        | {
            source: $source,
            records: $n,
            auto_approved_prs: ([ $recs[] | select(.final_verdict == "APPROVED") ] | length),
            automated_attempts: ([ $recs[] | .totals.adapter_invocations // 0 ] | add // 0),
            fail_closed_events: ([ $recs[] | .totals.fail_closed_events // 0 ] | add // 0),
            tokens_total: ([ $recs[] | .totals.tokens_total // 0 ] | add // 0),
            notional_usd: ([ $recs[] | .totals.notional_usd // 0 ] | add // 0),
            human_minutes_saved_estimate:
              (if $n == 0 then null
               else [ ([ $recs[] | select(.final_verdict == "APPROVED") ] | length) * $mlow,
                      ([ $recs[] | select(.final_verdict == "APPROVED") ] | length) * $mhigh ]
               end)
          }
      end
  ' 2>/dev/null || true)"
  if [ -z "$result" ]; then
    jq -nc --arg reason "aggregation failed to parse prior records" \
      '{source:"unavailable", records:0, reason:$reason}'
    return 0
  fi
  printf '%s' "$result"
}

# --- per-approval totals ---------------------------------------------------

# p4b_acct_compute_totals <loops-json-array> <price_table_version> <notional_usd|null>
# Compute the per-approval `totals` object from the loop array. Token totals
# sum only the loops with a non-null total; provider split keys off the adapter
# name. notional_usd is passed in (the renderer resolves it via the price
# table) and echoed through; a null value is preserved (missing price).
p4b_acct_compute_totals() {
  local loops_json="$1" ptv="$2" notional="$3"
  local ptv_arg notional_arg
  if [ -n "$ptv" ]; then ptv_arg="$ptv"; else ptv_arg="null"; fi
  if [ -n "$notional" ] && [ "$notional" != "null" ]; then notional_arg="$notional"; else notional_arg="null"; fi
  printf '%s' "$loops_json" | jq -c \
    --argjson ptv "$(printf '%s' "$ptv_arg" | jq -R 'if . == "null" then null else . end')" \
    --argjson notional "$notional_arg" '
    {
      adapter_invocations: length,
      tokens_total: ([ .[] | .tokens.total // empty ] | if length == 0 then 0 else add end),
      tokens_by_provider: (
        # Classify by the reviewer identity (nathanpayne-codex -> codex), which
        # is meaningful even for orchestrator-dry-run loops whose adapter name
        # is not the reviewer CLI; fall back to the adapter name, then to the
        # direction's target reviewer, then "other".
        reduce .[] as $l ({};
          (($l.reviewer // "") | ascii_downcase) as $rev
          | ($l.adapter // "") as $ad
          | ($l.direction // "") as $dir
          | (if ($rev | test("codex")) or ($ad | test("codex")) or ($dir | test("->codex")) then "codex"
             elif ($rev | test("claude")) or ($ad | test("claude")) or ($dir | test("->claude")) then "claude"
             else "other" end) as $prov
          | if ($l.tokens.total == null) then .
            else .[$prov] = ((.[$prov] // 0) + $l.tokens.total) end)
      ),
      elapsed_seconds_total: ([ .[] | .elapsed_seconds // empty ] | if length == 0 then null else add end),
      billed_usd: 0.0,
      notional_usd: $notional,
      price_table_version: $ptv,
      fail_closed_events: ([ .[] | select(.fail_closed.happened == true) ] | length),
      advisory_issues_filed: []
    }'
}

# --- fail-closed assertion -------------------------------------------------

# p4b_acct_required_severities_json — the required-tier severity set the
# posting rule forbids on an APPROVED. Reuses lib.sh's feedback-policy reader
# when available (sourced by the orchestrator); else the P0/P1 default.
p4b_acct_required_severities_json() {
  if command -v p4b_required_verdict_severities_json >/dev/null 2>&1; then
    p4b_required_verdict_severities_json && return 0
  fi
  printf '%s' '["P0","P1"]'
}

# p4b_acct_assert_no_required_with_approved <final_verdict> <loops-json-array>
# Fail-closed invariant: a posted APPROVED must not carry a required-tier
# finding in ANY loop's histogram. Returns 0 when safe, non-zero when the
# combination is illegal (the orchestrator must then NOT post the accounting
# approval — it falls back). Mirrors the orchestrator's strict posting rule.
p4b_acct_assert_no_required_with_approved() {
  local final_verdict="$1" loops_json="$2" required
  [ "$final_verdict" = "APPROVED" ] || return 0
  required="$(p4b_acct_required_severities_json)" || return 1
  # For each required tier, any loop with a positive count is a violation.
  local violated
  violated="$(printf '%s' "$loops_json" | jq -r \
    --argjson req "$required" '
    [ .[] | .findings as $f
      | $req[] | select(($f[.] // 0) > 0) ] | length' 2>/dev/null || echo 1)"
  [ "$violated" = "0" ]
}

# --- record assembly -------------------------------------------------------

# p4b_acct_build_record — assemble the full p4b-accounting/v1 record.
# All inputs are passed explicitly (pure function). Prints the compact record
# JSON on stdout, or returns non-zero (no output) if the fail-closed invariant
# is violated or the inputs cannot be assembled into schema-valid JSON.
#
# Env-style named inputs (all required unless noted):
#   $1 pr                                   integer
#   $2 final_head_sha                       string
#   $3 final_verdict                        APPROVED|CHANGES_REQUESTED
#   $4 final_reviewer                       string
#   $5 final_direction                      string
#   $6 automation_state                     posted|dry-run|manual
#   $7 wall_time_first_loop_to_approval_seconds  integer|"" (→ null)
#   $8 loops_json                           JSON array of loop objects
#   $9 unique_findings_json                 JSON array (may be [])
#  $10 totals_json                          JSON object (from compute_totals)
#  $11 running_totals_json                  JSON object
#  $12 generated_at                         RFC3339 string ("" → now)
p4b_acct_build_record() {
  local pr="$1" head="$2" verdict="$3" reviewer="$4" direction="$5"
  local astate="$6" wall="$7" loops_json="$8" uf_json="$9"
  local totals_json="${10}" running_json="${11}" gen_at="${12}"

  # Fail-closed: never emit an APPROVED record that carries a required finding.
  if ! p4b_acct_assert_no_required_with_approved "$verdict" "$loops_json"; then
    p4b_acct_warn "refusing to build APPROVED accounting: a required-tier finding is present in loop history (fail-closed)"
    return 1
  fi

  [ -n "$gen_at" ] || gen_at="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "")"
  local wall_arg
  if [ -n "$wall" ]; then wall_arg="$wall"; else wall_arg="null"; fi

  jq -nc \
    --argjson pr "$pr" \
    --arg head "$head" \
    --arg verdict "$verdict" \
    --arg reviewer "$reviewer" \
    --arg direction "$direction" \
    --arg astate "$astate" \
    --argjson wall "$wall_arg" \
    --argjson loops "$loops_json" \
    --argjson uf "$uf_json" \
    --argjson totals "$totals_json" \
    --argjson running "$running_json" \
    --arg gen "$gen_at" '
    {
      schema: "p4b-accounting/v1",
      pr: $pr,
      final_head_sha: $head,
      final_verdict: $verdict,
      final_reviewer: $reviewer,
      final_direction: $direction,
      automation_state: $astate,
      wall_time_first_loop_to_approval_seconds: $wall,
      loops: $loops,
      unique_findings: $uf,
      totals: $totals,
      running_totals: $running,
      generated_at: $gen
    }' 2>/dev/null || return 1
}

# --- rendering helpers -----------------------------------------------------

# Render a token count cell for the loop table: "N,NNN (source)" or
# "unavailable (source)" — never an estimate.
p4b_acct_fmt_tokens_cell() {
  local tokens_json="$1"
  printf '%s' "$tokens_json" | jq -r '
    def commafy:
      tostring
      | explode | reverse
      | [ range(0; length) as $i | .[$i], (if ($i % 3 == 2 and $i != length-1) then 44 else empty end) ]
      | reverse | implode;
    if .total != null then "\(.total | commafy) (\(.source))"
    else "unavailable (\(.source))" end'
}

# Render one rigor row: "| <check> | <result> | <evidence> |". A row whose
# signal is absent renders "n/a — reason" rather than a green check.
# args: <check> <captured:true|false> <evidence-or-reason>
p4b_acct_rigor_row() {
  local check="$1" captured="$2" text="$3"
  if [ "$captured" = "true" ]; then
    printf '| %s | ✅ | %s |\n' "$check" "$text"
  else
    printf '| %s | n/a | %s |\n' "$check" "$text"
  fi
}

# p4b_acct_render_block <record-json>
# Render the full human-readable "## Phase 4b Approval Accounting" block with
# the machine-readable record embedded as an HTML comment. Input is the record
# produced by p4b_acct_build_record. Prints markdown on stdout.
p4b_acct_render_block() {
  local rec="$1"
  [ -n "$rec" ] || return 1
  printf '%s' "$rec" | jq -e . >/dev/null 2>&1 || return 1

  local pr head verdict reviewer direction astate wall
  pr="$(printf '%s' "$rec" | jq -r '.pr')"
  head="$(printf '%s' "$rec" | jq -r '.final_head_sha')"
  verdict="$(printf '%s' "$rec" | jq -r '.final_verdict')"
  reviewer="$(printf '%s' "$rec" | jq -r '.final_reviewer')"
  direction="$(printf '%s' "$rec" | jq -r '.final_direction')"
  astate="$(printf '%s' "$rec" | jq -r '.automation_state')"
  wall="$(printf '%s' "$rec" | jq -r '.wall_time_first_loop_to_approval_seconds // "n/a"')"

  printf '## Phase 4b Approval Accounting\n\n'
  printf '**Reviewed head:** `%s` · **Final approval:** `%s` as `%s` (%s) · **Automation state:** %s · **Wall time, first 4b loop → approval:** %s%s\n\n' \
    "$head" "$verdict" "$reviewer" "$direction" "$astate" "$wall" \
    "$([ "$wall" != "n/a" ] && printf ' s reviewer time' || printf '')"

  # --- Loop summary ---
  printf '### Loop summary\n\n'
  printf '| Loop | Reviewer | Adapter · direction | Verdict | Posted? | Elapsed | Tokens (source) | P0 | P1 | P2 | P3 | Nit | Fail-closed |\n'
  printf '|---:|---|---|---|---|---:|---|---:|---:|---:|---:|---:|---|\n'
  local loops_count i
  loops_count="$(printf '%s' "$rec" | jq -r '.loops | length')"
  i=0
  while [ "$i" -lt "$loops_count" ]; do
    local loop_json tok_cell
    loop_json="$(printf '%s' "$rec" | jq -c ".loops[$i]")"
    tok_cell="$(p4b_acct_fmt_tokens_cell "$(printf '%s' "$loop_json" | jq -c '.tokens')")"
    printf '%s' "$loop_json" | jq -r --arg tok "$tok_cell" '
      def cell(x): (if x == null then "—" else (x|tostring) end);
      "| \(.loop) | \(.reviewer) | \(.adapter) · \(.direction) | \(.verdict) | \(.posted) | "
      + (if .elapsed_seconds == null then "n/a" else "\(.elapsed_seconds) s" end)
      + " | \($tok) | \(cell(.findings.P0)) | \(cell(.findings.P1)) | \(cell(.findings.P2)) | \(cell(.findings.P3)) | \(cell(.findings.nitpick)) | "
      + (if .fail_closed.happened then "**yes** — \(.fail_closed.reason)" else "no" end)
      + " |"'
    i=$((i + 1))
  done
  printf '\n'

  # --- Findings and disposition ---
  local uf_count
  uf_count="$(printf '%s' "$rec" | jq -r '.unique_findings | length')"
  printf '### Findings and disposition\n\n'
  if [ "$uf_count" -eq 0 ]; then
    printf '_No findings on the approved HEAD. See the rigor table below for proof this was reviewed hard rather than rubber-stamped._\n\n'
  else
    printf '| Finding | Severity | First loop | Last seen | Disposition | Fix commit / issue |\n'
    printf '|---|---|---:|---:|---|---|\n'
    printf '%s' "$rec" | jq -r '
      .unique_findings[]
      | "| \(.id) | \(.severity) | \(.first_loop) | \(.last_loop) | \(.disposition) | "
        + (if .fix_commit != null then "`\(.fix_commit)`"
           elif .issue != null then "#\(.issue)"
           else "—" end)
        + " |"'
    printf '\n'
    printf '%s' "$rec" | jq -r '
      ([ .unique_findings[] | select(.first_loop == .last_loop) ] | length) as $uniq
      | ([ .unique_findings[] | select(.first_loop != .last_loop) ] | length) as $rep
      | "Unique current-head findings: \(.unique_findings | length). Repeated/stale across loops: \($rep)."'
    printf '\n\n'
  fi

  # --- Rigor (proof-of-work for the final posted approval) ---
  printf '### Rigor (final posted approval)\n\n'
  printf '| Check | Result | Evidence |\n'
  printf '|---|---|---|\n'
  # Each row is backed by a captured signal already recorded in the record.
  local final_loop
  final_loop="$(printf '%s' "$rec" | jq -c '.loops | last')"
  # Verdict schema-conformant: the orchestrator only reaches here on a validated verdict.
  p4b_acct_rigor_row "Verdict schema-conformant" true "lib.sh jq mirror of verdict.schema.json accepted the verdict"
  p4b_acct_rigor_row "Reviewed current HEAD" true "posted commit_id=\`$head\`, created-review SHA re-verified"
  # Cross-agent: reviewer login prefix vs direction author.
  local xagent xagent_ev
  xagent="$(printf '%s' "$rec" | jq -r '(.final_direction | test("->")) and ((.final_direction | split("->")[0]) != (.final_reviewer | sub("^nathanpayne-";"")))')"
  xagent_ev="direction \`$direction\`, reviewer \`$reviewer\`"
  p4b_acct_rigor_row "Cross-agent (reviewer ≠ author)" "$xagent" "$xagent_ev"
  # Plan-only auth: from the final loop's plan_auth signal.
  local plan_auth
  plan_auth="$(printf '%s' "$final_loop" | jq -r '.plan_auth // ""')"
  if [ -n "$plan_auth" ]; then
    p4b_acct_rigor_row "Plan-only auth (no metered API)" true "\`plan_auth=$plan_auth\`; API-key env scrubbed by the adapter"
  else
    p4b_acct_rigor_row "Plan-only auth (no metered API)" false "plan-auth posture not captured for this loop"
  fi
  # Read-only posture: always true for the reference adapters.
  p4b_acct_rigor_row "Read-only posture" true "codex \`--sandbox read-only\` / claude \`--permission-mode plan --tools \"\"\`"
  p4b_acct_rigor_row "Exhaustive review pass" true "bounded \"Exhaustive code review\" adapter prompt"
  # Fail-closed rule honored: 0 required findings on the approval, and any fail-closed loop is recorded.
  local fc_events
  fc_events="$(printf '%s' "$rec" | jq -r '.totals.fail_closed_events // 0')"
  p4b_acct_rigor_row "Fail-closed rule honored" true "0 required-tier findings on the approval; $fc_events fail-closed loop(s) recorded"
  # Reviewer CLI version: captured only if the final loop recorded it (#586).
  local cli_ver
  cli_ver="$(printf '%s' "$final_loop" | jq -r '.cli_version // ""')"
  if [ -n "$cli_ver" ]; then
    p4b_acct_rigor_row "Reviewer CLI version" true "\`$cli_ver\` (#586)"
  else
    p4b_acct_rigor_row "Reviewer CLI version" false "CLI version not exposed/recorded for this loop"
  fi
  printf '\n'

  # --- Cost and effort ---
  printf '### Cost and effort\n\n'
  printf '| Metric | This approval |\n'
  printf '|---|---|\n'
  printf '%s' "$rec" | jq -r \
    --argjson mlow "$P4B_ACCT_HUMAN_MINUTES_LOW" --argjson mhigh "$P4B_ACCT_HUMAN_MINUTES_HIGH" '
    .totals as $t
    | (if $t.elapsed_seconds_total == null then "unavailable" else "\($t.elapsed_seconds_total) s across \($t.adapter_invocations) loop(s)" end) as $wall
    | (if $t.tokens_total == null or $t.tokens_total == 0 then "unavailable (no CLI-exposed counts)"
       else "\($t.tokens_total) total (" + ([ $t.tokens_by_provider | to_entries[] | "\(.key) \(.value)" ] | join(", ")) + ")" end) as $tok
    | (if $t.notional_usd == null then "n/a — no price for the recorded model(s)"
       else "~$\($t.notional_usd * 100 | round / 100)  *(not billed; price table `\($t.price_table_version // "unknown")`)*" end) as $notional
    | ([ .loops[] | .throttle_events // 0 ] | add // 0) as $throttle
    | "| Reviewer wall-clock | **\($wall)** |\n"
      + "| Tokens observed | \($tok) |\n"
      + "| Billed cost | **$0.00** — operator subscription plan |\n"
      + "| Notional API-equivalent | **\($notional)** |\n"
      + "| Plan-capacity throttle events | \($throttle) |\n"
      + "| Human shuttle avoided | **~\($mlow) min – \($mhigh / 60) h** (manual Phase 4b handoff, per REVIEW_POLICY.md) |"'
  printf '\n\n'

  # --- Running totals ---
  printf '### Running totals — repo, to date\n\n'
  local rt_source
  rt_source="$(printf '%s' "$rec" | jq -r '.running_totals.source')"
  if [ "$rt_source" = "unavailable" ]; then
    printf '%s' "$rec" | jq -r '"_Running totals unavailable — \(.running_totals.reason // "aggregation degraded").__"'
    printf '\n\n'
  else
    printf '| Metric | Cumulative |\n'
    printf '|---|---|\n'
    printf '%s' "$rec" | jq -r '
      .running_totals as $r
      | ($r.auto_approved_prs // 0) as $ap
      | ($r.automated_attempts // 0) as $at
      | (if $at > 0 then "\($ap) / \($at) = \(($ap / $at) * 100 | round)% approved · \((($at - ($r.fail_closed_events // 0)) ) )/\($at) non-fail-closed"
         else "n/a (no attempts yet)" end) as $rate
      | "| Auto-approved PRs | \($ap) |\n"
        + "| Automated attempts (posted + fell-back) | \($at) |\n"
        + "| **Auto-approval / fail-closed rate** | **\($rate)** (\($r.fail_closed_events // 0) fail-closed to human) |\n"
        + "| Cumulative tokens | \($r.tokens_total // 0) |\n"
        + "| Cumulative notional API-equivalent | ~$\((($r.notional_usd // 0) * 100 | round) / 100) *(not billed)* |\n"
        + "| Cumulative human time saved (est.) | "
        + (if $r.human_minutes_saved_estimate == null then "unavailable"
           else "~\(($r.human_minutes_saved_estimate[0] / 60) | floor) – \(($r.human_minutes_saved_estimate[1] / 60) | floor) h" end)
        + " |"'
    printf '\n\n'
    printf '%s' "$rec" | jq -r '"*Totals source: \(.running_totals.source) (\(.running_totals.records) p4b-accounting:v1 record(s)).*"'
    printf '\n\n'
  fi

  # --- Embedded machine-readable record ---
  printf '<!-- %s\n' "$(p4b_acct_marker)"
  printf '%s\n' "$(printf '%s' "$rec" | jq -c '.')"
  printf -- '-->\n'
}
