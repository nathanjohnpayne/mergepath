#!/usr/bin/env bash
# scripts/phase-4b/accounting.sh — Phase 4b approval-loop accounting (#602).
#
# REFERENCE IMPLEMENTATION. Sourced by scripts/phase-4b-review.sh; it does NOT
# set -euo pipefail on the caller. Bash 3.2 portable (macOS). Pure functions
# over JSON inputs — no network, no GitHub, no reviewer CLI — so the whole
# module is unit-testable in isolation (tests/test_phase_4b_accounting.sh).
# Single exception: the hook-layer prior-record fetch shells out to `gh`
# (read-only, PATH-shimmable in tests) to gather aggregation input; every
# fetch failure degrades to the local ledger / explicit unavailable.
#
# What it produces: the human-readable "## Phase 4b Approval Accounting" block
# AND the embedded machine-readable `<!-- p4b-accounting:v1 ... -->` JSON record
# (scripts/phase-4b/accounting.schema.json). The record is loop-centric (every
# adapter attempt, not just the final approval), carries findings lifecycle +
# disposition, a rigor-as-proof-of-work table, a four-part cost model
# (wall-clock / tokens / throttle / labeled-notional$), and repo-wide running
# totals aggregated from prior embedded records.
#
# Data-integrity posture (all enforced here, fail-closed):
#   - No estimated tokens. A CLI that exposes nothing renders "unavailable".
#   - No green rigor check without a captured signal; else "n/a — reason".
#   - A required-tier (P0/P1 by default) finding can NEVER accompany a posted
#     APPROVED. Required findings on CHANGES_REQUESTED loops are legitimate
#     history (the changes-requested-then-fixed lifecycle) and never poison a
#     later clean approval's record.
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

# p4b_acct_run_bounded <seconds> <command> [args...]
# Portable, GRACEFULLY-DEGRADING bounded execution for the OPTIONAL prior-record
# fetch (#615 Codex round 8, finding 2). Unlike lib.sh's p4b_run_with_timeout
# (which p4b_die's when no timeout tool exists — correct for the REQUIRED
# reviewer-CLI path), accounting is advisory: a missing timeout tool must never
# abort the run, and accounting.sh is sourced WITHOUT lib.sh in tests, so this
# stays self-contained. Prefers GNU/coreutils `timeout` (or macOS `gtimeout`),
# then `perl`'s alarm; if NEITHER is present it runs the command unbounded
# (advisory can't hard-fail on a missing tool). On timeout the underlying tool
# returns 124 (perl exits non-zero via the alarm), which the fetch treats as a
# fetch failure and degrades to the ledger-cache/unavailable path. seconds<=0 or
# non-numeric ⇒ unbounded (an explicit opt-out / defensive default).
p4b_acct_run_bounded() {
  local seconds="$1"; shift
  case "$seconds" in
    ''|0|*[!0-9]*) "$@"; return $? ;;
  esac
  if command -v timeout >/dev/null 2>&1; then
    timeout "$seconds" "$@"; return $?
  fi
  if command -v gtimeout >/dev/null 2>&1; then
    gtimeout "$seconds" "$@"; return $?
  fi
  if command -v perl >/dev/null 2>&1; then
    perl -e 'alarm shift @ARGV; exec @ARGV or die "exec failed: $!\n"' \
      "$seconds" "$@"; return $?
  fi
  p4b_acct_warn "no timeout/gtimeout/perl available — the prior-record fetch runs unbounded (advisory; a stalled read cannot be time-boxed on this host)"
  "$@"; return $?
}

# Repo root: accounting.sh lives at <root>/scripts/phase-4b/accounting.sh.
p4b_acct_repo_root() { ( cd -P "$P4B_ACCT_DIR/../.." && pwd ); }

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
# "The human-mediated handoff typically adds 30 minutes to a few hours per PR."
P4B_ACCT_HUMAN_MINUTES_LOW=30
P4B_ACCT_HUMAN_MINUTES_HIGH=180

# --- config (phase_4b_automation.accounting) --------------------------------

# The policy file. Overridable via MERGEPATH_REVIEW_POLICY_PATH (tests) —
# the same override lib.sh honors.
p4b_acct_config() {
  if [ -n "${MERGEPATH_REVIEW_POLICY_PATH:-}" ]; then
    printf '%s' "$MERGEPATH_REVIEW_POLICY_PATH"
    return 0
  fi
  printf '%s/.github/review-policy.yml' "$(p4b_acct_repo_root)"
}

# p4b_acct_config_field <field> — scalar under
# phase_4b_automation.accounting.<field>. Empty string if absent.
# Indent-agnostic (#615 Codex round 4): the previous reader hardcoded the
# two-space style (an `accounting:` header at exactly column 2, children at
# indent > 2), so a downstream policy formatted with four-space children
# never entered the sub-block — `accounting.enabled: false` read as ABSENT,
# defaulted to true, and an opted-out repo still got accounting appended.
# Now mirrors the lib.sh p4b_automation_field mechanism: the automation
# block's direct-child indent is captured from its first key line, the
# `accounting:` header must sit exactly at that indent (a deeper `accounting:`
# inside some other sub-block never matches), and the accounting block's own
# child indent is captured from ITS first key line — any consistent style
# works, and only direct children of `accounting:` resolve.
p4b_acct_config_field() {
  local field="$1" cfg
  cfg="$(p4b_acct_config)"
  [ -f "$cfg" ] || return 0
  awk -v field="$field" '
    /^phase_4b_automation:/ { inauto=1; inacct=0; auto_ci=-1; acct_indent=-1; acct_ci=-1; next }
    inauto && /^[^[:space:]#]/ { inauto=0; inacct=0 }
    inauto {
      line=$0
      gsub(/[[:space:]]*#.*$/, "", line)
      if (line ~ /^[[:space:]]*$/) next
      indent = match(line, /[^[:space:]]/) - 1
      if (inacct && indent <= acct_indent) inacct=0
      if (inacct) {
        if (acct_ci < 0) acct_ci = indent
        if (indent > acct_ci) next
        key=line
        sub(/^[[:space:]]*/, "", key)
        sub(/:.*/, "", key)
        if (key == field) {
          sub(/^[[:space:]]*[^:]+:[[:space:]]*/, "", line)
          gsub(/^["\047]/, "", line)
          gsub(/["\047][[:space:]]*$/, "", line)
          sub(/[[:space:]]+$/, "", line)
          print line; exit
        }
        next
      }
      if (auto_ci < 0) auto_ci = indent
      if (indent == auto_ci && line ~ /^[[:space:]]*accounting:[[:space:]]*$/) {
        inacct=1; acct_indent=indent; acct_ci=-1
      }
    }
  ' "$cfg"
}

# Sub-toggle: phase_4b_automation.accounting.enabled. Defaults to TRUE under
# the (disabled-by-default) parent — accounting renders whenever the parent
# automation actually posts, unless a repo opts out explicitly.
p4b_acct_config_enabled() {
  local v
  v="$(p4b_acct_config_field enabled)"
  [ "${v:-true}" != "false" ]
}

# p4b_acct_available_reviewers_json — the registered reviewer identities
# (top-level `available_reviewers:` list in review-policy.yml) as a compact
# JSON array, e.g. ["nathanpayne-claude","nathanpayne-codex"]. Mirrors
# lib.sh's p4b_available_reviewers awk (accounting.sh stays sourceable in
# isolation). Prints "[]" when the list is absent/empty. Used to filter
# GitHub-fetched prior records to trusted review authors (#615 Codex
# round 3): the spec aggregates reviews BY available_reviewers identities,
# so a record embedded by any other account must never reach the totals.
p4b_acct_available_reviewers_json() {
  local cfg
  cfg="$(p4b_acct_config)"
  [ -f "$cfg" ] || { printf '[]'; return 0; }
  awk '
    /^available_reviewers:/ { inlist=1; next }
    inlist && /^[[:space:]]*-[[:space:]]*/ {
      line=$0
      sub(/^[[:space:]]*-[[:space:]]*/, "", line)
      gsub(/[[:space:]]*#.*$/, "", line)
      gsub(/^["\047]/, "", line); gsub(/["\047][[:space:]]*$/, "", line)
      sub(/[[:space:]]+$/, "", line)
      if (line != "") print line
      next
    }
    inlist && /^[^[:space:]#-]/ { inlist=0 }
  ' "$cfg" | jq -Rnc '[inputs | select(length > 0)]' 2>/dev/null || printf '[]'
}

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
#   - explicit split: rate_fields lists which of
#     {input, output, cache_write_5m, cache_read} to price, matched to the
#     token object's {input, output, cache_creation, cache_read} fields.
#   - total-only: rate_fields == ["total_only_blended_80_20"] (or any single
#     field matching /blended|total_only/) applied to tokens.total.
# Prints the dollar figure on success. Returns non-zero (no output) if any
# required rate is unresolvable OR the needed token count is null — the
# caller renders notional n/a rather than an estimate.
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
    printf '%s' "$total" | jq --argjson rate "$rate" '(. / 1000000.0) * $rate'
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

# p4b_acct_notional_auto <tokens-json> <price_key>
# Price one loop's tokens: prefer the exact split (input+output, plus the
# cache components actually counted), else fall back to the total-only
# blended rate (marked approximate by construction — see prices.json
# estimation_policy). Non-zero when nothing can be priced.
p4b_acct_notional_auto() {
  local tokens_json="$1" price_key="$2" fields nfields
  [ -n "$tokens_json" ] && [ -n "$price_key" ] || return 1
  fields="$(printf '%s' "$tokens_json" | jq -c '
    [ (if .input != null and .output != null then "input", "output" else empty end),
      (if .cache_creation != null then "cache_write_5m" else empty end),
      (if .cache_read != null then "cache_read" else empty end) ]' 2>/dev/null)" || return 1
  nfields="$(printf '%s' "$fields" | jq -r 'length' 2>/dev/null || echo 0)"
  if [ "${nfields:-0}" -ge 2 ]; then
    if p4b_acct_notional_from_tokens "$tokens_json" "$price_key" "$fields"; then
      return 0
    fi
  fi
  p4b_acct_notional_from_tokens "$tokens_json" "$price_key" '["total_only_blended_80_20"]'
}

# p4b_acct_loop_provider <loop-json>
# Classify a loop's token provider. Keys off the reviewer identity
# (nathanpayne-codex -> codex), which is meaningful even for
# orchestrator-dry-run loops whose adapter name is not the reviewer CLI;
# falls back to the adapter name, then the direction target, then "other".
p4b_acct_loop_provider() {
  printf '%s' "$1" | jq -r '
    ((.reviewer // "") | ascii_downcase) as $rev
    | (.adapter // "") as $ad
    | (.direction // "") as $dir
    | if ($rev | test("codex")) or ($ad | test("codex")) or ($dir | test("->codex")) then "codex"
      elif ($rev | test("claude")) or ($ad | test("claude")) or ($dir | test("->claude")) then "claude"
      else "other" end' 2>/dev/null
}

# p4b_acct_price_key_for_provider <codex|claude|other>
# The configured price key for a provider, from
# phase_4b_automation.accounting.{codex,claude}_price_key. Empty when not
# configured — the adapters do not capture exact model IDs yet (#602), so
# pricing is an explicit opt-in mapping, never a guess.
p4b_acct_price_key_for_provider() {
  case "$1" in
    codex)  p4b_acct_config_field codex_price_key ;;
    claude) p4b_acct_config_field claude_price_key ;;
    *)      : ;;
  esac
}

# p4b_acct_notional_for_loops <loops-json-array>
# Total notional USD (rounded to cents) across all loops with CLI-exposed
# token counts. Loops with no exposed tokens contribute nothing (you cannot
# price what was not measured). Fail-closed: if ANY token-bearing loop cannot
# be priced (no configured key, missing price/field), or NO loop has tokens,
# return non-zero so the caller renders `n/a` instead of a partial figure.
p4b_acct_notional_for_loops() {
  local loops_json="$1" n i loop tokens has_tokens prov key val
  local vals="" priced=0
  n="$(printf '%s' "$loops_json" | jq -r 'length' 2>/dev/null)" || return 1
  [ -n "$n" ] || return 1
  i=0
  while [ "$i" -lt "$n" ]; do
    loop="$(printf '%s' "$loops_json" | jq -c ".[$i]" 2>/dev/null)" || return 1
    tokens="$(printf '%s' "$loop" | jq -c '.tokens' 2>/dev/null)" || return 1
    has_tokens="$(printf '%s' "$tokens" | jq -r '
      (.total != null) or (.input != null and .output != null)' 2>/dev/null)" || return 1
    if [ "$has_tokens" = "true" ]; then
      prov="$(p4b_acct_loop_provider "$loop")"
      key="$(p4b_acct_price_key_for_provider "$prov")"
      [ -n "$key" ] || return 1
      val="$(p4b_acct_notional_auto "$tokens" "$key")" || return 1
      vals="${vals}${val}
"
      priced=$((priced + 1))
    fi
    i=$((i + 1))
  done
  [ "$priced" -gt 0 ] || return 1
  printf '%s' "$vals" | jq -s 'add * 100 | round / 100'
}

# --- record extraction + aggregation ---------------------------------------

# p4b_acct_marker — the embedded-block marker string.
p4b_acct_marker() { printf 'p4b-accounting:v1'; }

# p4b_acct_safe_truncate <block> <keep-bytes>
# Print a byte-prefix of <block> of at most <keep-bytes> that never ends
# INSIDE the embedded `<!-- p4b-accounting:v1 ... -->` record comment (#615
# Codex round 10, P3). A raw ${var:0:N} cut landing between the comment-open
# marker and its closing `-->` leaves an unterminated HTML comment, and the
# truncation notice the caller appends after the prefix is then swallowed
# (hidden) by the unterminated comment — a silently chopped block instead of
# a visibly truncated one. When the requested cut would land inside the
# comment, the cut backs off to just before the comment-open marker (dropping
# the whole machine-readable record cleanly). A cut before the marker or past
# the terminated comment is a plain byte slice. A render block carries at
# most ONE embedded record comment (the renderer emits exactly one, and
# earlier hardening guarantees loop content cannot terminate or restart it),
# so guarding the first marker suffices. LC_ALL=C makes ${var:0:N} and ${#var}
# count BYTES; pure bash — no pipe, no SIGPIPE (the round-9 requirement).
p4b_acct_safe_truncate() {
  local block="$1" keep="$2"
  (
    LC_ALL=C
    _marker='<!-- p4b-accounting:v1'
    _pre="${block%%"$_marker"*}"
    if [ "${#_pre}" -lt "${#block}" ] && [ "$keep" -gt "${#_pre}" ]; then
      _rest="${block:${#_pre}}"
      _inner="${_rest%%-->*}"
      if [ "$_inner" != "$_rest" ]; then
        _mend=$(( ${#_pre} + ${#_inner} + 3 ))
      else
        # Defensive: an unterminated comment in the input — everything from
        # the marker on is comment; any cut past the marker stays inside it.
        _mend=${#block}
      fi
      if [ "$keep" -lt "$_mend" ]; then keep=${#_pre}; fi
    fi
    printf '%s' "${block:0:$keep}"
  )
}

# p4b_acct_encode_comment_payload — stdin filter: encode the HTML-comment
# delimiter sequences inside a compact-JSON payload so an embedded record can
# never terminate (or restart) its enclosing `<!-- p4b-accounting:v1 ... -->`
# comment (#615 Codex round 2). A `-->` inside any record string (e.g. a
# hostile finding title) would otherwise close the hidden comment early —
# GitHub renders the remainder visibly AND p4b_acct_extract_records truncates
# at the first terminator, dropping the record from future running totals.
# In valid JSON text `<` / `>` occur only inside string literals, so the
# filter rewrites the angle bracket of each delimiter to its JSON unicode
# escape (backslash-u003e for `>`, backslash-u003c for `<`): the parsed
# record is identical, but the serialized payload carries no literal
# delimiter. Covered sequences: `-->` (the comment terminator), `--!>`
# (the HTML parser closes a comment on it too), and `<!--` (would restart
# a capture in the extractor).
p4b_acct_encode_comment_payload() {
  local payload
  payload="$(cat)"
  payload="${payload//-->/--\\u003e}"
  payload="${payload//--!>/--!\\u003e}"
  payload="${payload//<!--/\\u003c!--}"
  printf '%s' "$payload"
}

# p4b_acct_extract_records — read prior review bodies on stdin and emit each
# embedded p4b-accounting:v1 JSON record as one compact line (JSONL). Only
# well-formed objects carrying the v1 schema tag are emitted; malformed or
# non-conformant blocks are skipped (they must not corrupt aggregation). Used
# to aggregate running totals statelessly from GitHub-fetched prior approval
# bodies. The block spans from the `<!-- p4b-accounting:v1` comment-open line
# to the `-->` close; matching the full comment-open (not the bare marker)
# keeps prose mentions of the marker (e.g. the totals-source footer) from
# starting a bogus capture.
p4b_acct_extract_records() {
  awk -v marker="$(p4b_acct_marker)" '
    BEGIN { open_tag = "<!-- " marker }
    index($0, open_tag) > 0 { capturing = 1; buf = ""; next }
    capturing {
      if ($0 ~ /-->/) {
        line = $0
        sub(/-->.*/, "", line)
        buf = buf line " "
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

# p4b_acct_aggregate_running_totals [source-label]
# Read prior p4b-accounting:v1 records as JSONL on stdin (one record per
# line) and print a running_totals object (matching the schema shape) on
# stdout. <source> ("github-derived" | "ledger-cache") labels where the
# records came from. On any parse trouble it prints
# {"source":"unavailable","records":0,"reason":...} and returns 0 — the
# renderer then shows "running totals unavailable" rather than wrong numbers.
# Empty input is VALID (records: 0 — the first-ever approval).
p4b_acct_aggregate_running_totals() {
  local source_label="${1:-github-derived}"
  local input result
  input="$(cat)"
  result="$(printf '%s' "$input" | jq -cs \
    --arg source "$source_label" \
    --argjson mlow "$P4B_ACCT_HUMAN_MINUTES_LOW" \
    --argjson mhigh "$P4B_ACCT_HUMAN_MINUTES_HIGH" '
    # Schema-mirror conformance (#615 Codex round 5): a syntactically valid but
    # INCOMPLETE record (partial local write, manual edit, buggy earlier
    # emitter) can carry the schema tag while missing the fields the aggregation
    # reads — the tag-only filter would then count it as records:1 with zero
    # attempts/fail-closed events, silently understating repo-wide totals
    # instead of degrading. This def mirrors accounting.schema.json required
    # keys (the same required-set the record must satisfy) so a tagged record
    # missing any of them is dropped from aggregation (and counted in a
    # diagnostics line), never treated as conformant. Nullable fields must be
    # PRESENT (has()) but may be null — matching the schema, which requires the
    # key and permits an explicit-null value.
    #
    # Type mirror (#615 Codex round 10): key presence alone still accepted
    # wrong-TYPED values (totals.tokens_total: "oops" from a manually edited,
    # partially written, or buggy-older-emitter record), and addall would then
    # publish the corrupt value straight into running_totals under a
    # github-derived label. Every field this aggregation READS must also match
    # its accounting.schema.json type (integers where the schema says integer,
    # number-or-null where it says nullable) or the record is dropped and
    # counted, exactly like a missing key.
    def conformant:
      (["pr","final_head_sha","final_verdict","final_reviewer",
        "final_direction","automation_state",
        "wall_time_first_loop_to_approval_seconds","loops","unique_findings",
        "totals","running_totals","generated_at"]) as $req
      | (["adapter_invocations","tokens_total","tokens_by_provider",
          "elapsed_seconds_total","billed_usd","notional_usd",
          "reported_cost_usd","price_table_version","fail_closed_events",
          "advisory_issues_filed"]) as $treq
      | def intok($v): ($v | type) == "number" and $v >= 0 and $v == ($v | floor);
        def intornull($v): $v == null or intok($v);
        def numornull($v): $v == null or (($v | type) == "number" and $v >= 0);
      (type == "object")
        and (.schema == "p4b-accounting/v1")
        and (($req - keys_unsorted) | length) == 0
        and (.totals | type == "object")
        and (($treq - (.totals | keys_unsorted)) | length) == 0
        and intok(.pr) and .pr >= 1
        and ((.final_verdict | type) == "string")
        and intok(.totals.adapter_invocations)
        and intok(.totals.fail_closed_events)
        and intornull(.totals.tokens_total)
        and intornull(.totals.elapsed_seconds_total)
        and numornull(.totals.notional_usd);
    (map(select(type == "object" and .schema == "p4b-accounting/v1"))) as $tagged
    | ([ $tagged[] | select(conformant) ]) as $recs
    | (($tagged | length) - ($recs | length)) as $dropped
    | if ($tagged | length) != (. | length) and (. | length) > 0
      then error("non-conformant record in ledger")
      else
        ($recs | length) as $n
        # Auto-approved PRs is a DISTINCT-PR count (#615 Codex round 5): a PR
        # approved twice (two commits → two automated approvals) leaves two
        # APPROVED bodies with the same .pr, and counting both inflated the PR
        # metric and the human-time-saved derived from it. Dedupe by .pr among
        # APPROVED records. Loop/attempt SPEND metrics below (attempts,
        # fail-closed, tokens, elapsed, notional) deliberately stay summed over
        # ALL records — a re-approval really did spend a second review, so the
        # cost/effort totals must reflect actual spend, not the deduped PR set
        # (Codex: "count distinct approved PR numbers for the PR metric while
        # still summing all recorded loop attempts separately").
        | ([ $recs[] | select(.final_verdict == "APPROVED") | .pr ]
           | unique | length) as $approved
        # Measured metrics propagate unavailability (#615 Codex): a prior
        # record whose tokens/elapsed/notional is null (unavailable) makes the
        # CUMULATIVE figure null too — summing only the measured records would
        # silently underreport, and coercing null to 0 fabricates a measurement
        # the contract forbids. Counts (attempts, fail-closed) are always
        # emitted by the builder, so their defensive `// 0` stays.
        | def addall(f): if any($recs[]; f == null) then null
                         else ([ $recs[] | f ] | add // 0) end;
        {
            source: $source,
            records: $n,
            records_dropped_nonconformant: $dropped,
            auto_approved_prs: $approved,
            automated_attempts: ([ $recs[] | .totals.adapter_invocations // 0 ] | add // 0),
            fail_closed_events: ([ $recs[] | .totals.fail_closed_events // 0 ] | add // 0),
            tokens_total: addall(.totals.tokens_total),
            elapsed_seconds_total: addall(.totals.elapsed_seconds_total),
            notional_usd: (addall(.totals.notional_usd)
                           | if . == null then null else (. * 100 | round / 100) end),
            human_minutes_saved_estimate:
              (if $approved == 0 then null
               else [ $approved * $mlow, $approved * $mhigh ]
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

# p4b_acct_running_totals_for_post [ledger-file]
# Resolve the running-totals source at post time. Priority:
#   1. P4B_ACCT_PRIOR_RECORDS_JSONL — an injected prior-record file (e.g. the
#      output of piping GitHub-fetched prior review bodies through
#      p4b_acct_extract_records), labeled via P4B_ACCT_PRIOR_RECORDS_SOURCE
#      (default "github-derived"). This is the stateless GitHub path.
#   2. The append-only ledger cache (labeled "ledger-cache").
#   3. Neither ⇒ explicit "unavailable" (never a guessed zero baseline).
p4b_acct_running_totals_for_post() {
  local ledger="${1:-}"
  if [ -n "${P4B_ACCT_PRIOR_RECORDS_JSONL:-}" ]; then
    if [ -r "$P4B_ACCT_PRIOR_RECORDS_JSONL" ]; then
      p4b_acct_aggregate_running_totals "${P4B_ACCT_PRIOR_RECORDS_SOURCE:-github-derived}" \
        < "$P4B_ACCT_PRIOR_RECORDS_JSONL"
      return 0
    fi
    jq -nc --arg reason "prior-records file not readable: $P4B_ACCT_PRIOR_RECORDS_JSONL" \
      '{source:"unavailable", records:0, reason:$reason}'
    return 0
  fi
  if [ -n "$ledger" ] && [ -r "$ledger" ]; then
    p4b_acct_aggregate_running_totals "ledger-cache" < "$ledger"
    return 0
  fi
  jq -nc '{source:"unavailable", records:0,
           reason:"no prior-record source (GitHub aggregation not attempted; ledger cache absent)"}'
}

# --- per-approval totals ---------------------------------------------------

# p4b_acct_compute_totals <loops-json-array> <price_table_version> <notional_usd|null> [unique-findings-json] [filed-issues-json]
# Compute the per-approval `totals` object from the loop array. Token/elapsed
# totals sum only the loops that exposed a value; when NO loop exposed one the
# total is null (explicitly unavailable, never a fabricated 0). notional_usd
# is passed in (the caller resolves it via the price table) and echoed
# through; null is preserved (missing price). reported_cost_usd sums the
# CLI-reported per-loop costs (#615 Codex round 2) fail-closed: null unless
# every loop with measured usage also reported a cost — a token-bearing loop
# without one would make the sum a silent underreport (never a partial
# figure); loops with nothing measured contribute nothing and do not block.
# advisory_issues_filed is the union of the unique-finding issue links AND the
# optional raw filed-issues list ([filed-issues-json], P4B_ACCT_FILED_ISSUES_JSON)
# — so EVERY issue actually filed is recorded even when duplicate (identical
# severity/path/line/body) findings collapse to one unique_findings entry whose
# single per-finding issue holds only one of the refs (#675 Codex round 2).
p4b_acct_compute_totals() {
  local loops_json="$1" ptv="$2" notional="$3" uf_json="${4:-[]}" filed_json="${5:-[]}"
  [ -n "$filed_json" ] || filed_json='[]'
  local ptv_json notional_json
  if [ -n "$ptv" ]; then
    ptv_json="$(jq -nc --arg v "$ptv" '$v' 2>/dev/null)" || return 1
  else
    ptv_json="null"
  fi
  if [ -n "$notional" ] && [ "$notional" != "null" ]; then
    notional_json="$notional"
  else
    notional_json="null"
  fi
  printf '%s' "$loops_json" | jq -c \
    --argjson ptv "$ptv_json" \
    --argjson notional "$notional_json" \
    --argjson uf "$uf_json" \
    --argjson filed "$filed_json" '
    {
      adapter_invocations: length,
      tokens_total: ([ .[] | .tokens.total // empty ]
                     | if length == 0 then null else add end),
      tokens_by_provider: (
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
      elapsed_seconds_total: ([ .[] | .elapsed_seconds // empty ]
                              | if length == 0 then null else add end),
      billed_usd: 0.0,
      notional_usd: $notional,
      reported_cost_usd: (
        ([ .[] | .tokens.cost_usd | select(. != null) ]) as $rep
        | ([ .[] | select(.tokens.cost_usd == null
                          and ((.tokens.total != null)
                               or (.tokens.input != null and .tokens.output != null))) ]
           | length) as $measured_costless
        | if ($rep | length) == 0 or $measured_costless > 0 then null
          else ($rep | add * 100 | round / 100) end
      ),
      price_table_version: $ptv,
      fail_closed_events: ([ .[] | select(.fail_closed.happened == true) ] | length),
      advisory_issues_filed: (([ $uf[] | .issue ] + [ $filed[] | .issue ])
                              | map(select(. != null)) | unique)
    }' 2>/dev/null
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

# p4b_acct_assert_no_required_with_approved <final_verdict> <loops-json-array> [final_head] [mode]
# Fail-closed invariant on the strict posting rule: an APPROVED verdict may
# never carry a required-tier finding.
#   - Any loop recorded as APPROVED / APPROVED_WITH_ADVISORIES with a positive
#     required-tier count and NO fail-closed marker is a violation (that
#     approval should have been refused, never recorded as clean history).
#   - When the record's final verdict is APPROVED, at least one loop must be a
#     clean APPROVED: verdict APPROVED with required-tier counts present
#     (non-null) and zero. A record cannot claim an approval no loop produced.
# Required-tier findings on CHANGES_REQUESTED loops are legitimate history
# (changes-requested-then-fixed) and do NOT violate the rule — PROVIDED a new
# commit followed (the head changed).
#
# Same-head required-finding rejection (#615 Codex round 8, finding 3): the
# loop log is per-segment and only rotates AFTER an approval posts (round 6/7),
# so a CHANGES_REQUESTED loop with a P0/P1 on head `abc` survives in the live
# segment until an approval posts. If the operator reruns Phase 4b WITHOUT a
# new commit and the adapter returns a clean APPROVED for the SAME head, the
# earlier required finding on that head was NEVER addressed by a new commit —
# yet the two-argument checks above accept it (the P0/P1 sits on a CR loop, and
# a clean APPROVED loop exists). This mirrors the merge-gate semantic (a
# required finding on the CURRENT head blocks): when <final_head> is supplied
# and the final verdict is APPROVED, ANY loop (CR or otherwise, excluding
# fail-closed-marked loops) that recorded a required-tier finding on THAT SAME
# head is treated as an unresolved required finding and fails closed. A head
# change (a real fix commit) moves the clean approval onto a different head and
# clears it — the legitimate changes-requested-then-fixed path. A finding
# explicitly rebutted/fixed in-place is out of the loop-histogram's scope and,
# per the fail-closed contract, is left to a fresh head or an explicit
# fail-closed marker to clear. <final_head> is OPTIONAL and defaults to the
# empty string; when absent (or empty/"unknown") the same-head guard is skipped
# and behavior matches the original two-argument contract.
#
# <mode> is OPTIONAL (#615 round 9, CodeRabbit). "full" (the default, and any
# unrecognized value — stricter is the safe direction) applies every clause:
# the RECORD context, where the loop set must also contain the clean APPROVED
# loop that produced the final verdict and no recorded approval may carry a
# required finding. "same_head_only" applies ONLY the same-head
# unresolved-required clause: the LIVE-LOG context of the approval-time safety
# hook, where the current loop can be legitimately absent (its record append
# failed) — demanding the record-scoped clean-APPROVED loop there refuses a
# VALID head-advanced approval, and prior-head history defects are the record
# builder's advisory concern, not grounds to block the approval itself.
# Returns 0 when safe, non-zero when the combination is illegal.
p4b_acct_assert_no_required_with_approved() {
  local final_verdict="$1" loops_json="$2" final_head="${3:-}" mode="${4:-full}" required ok
  required="$(p4b_acct_required_severities_json)" || return 1
  case "$final_head" in unknown) final_head="" ;; esac
  ok="$(printf '%s' "$loops_json" | jq -r \
    --arg final "$final_verdict" \
    --arg head "$final_head" \
    --arg mode "$mode" \
    --argjson req "$required" '
    def reqcount($f): [ $req[] | ($f[.] // 0) ] | add // 0;
    def reqnull($f):  ([ $req[] | select($f[.] == null) ] | length) > 0;
    ( [ .[]
        | select((.verdict == "APPROVED") or (.verdict == "APPROVED_WITH_ADVISORIES"))
        | select((.fail_closed.happened // false) | not)
        | select(reqcount(.findings) > 0)
      ] | length == 0 ) as $history_ok
    | (if $final == "APPROVED"
       then ([ .[]
               | select(.verdict == "APPROVED")
               | select(reqnull(.findings) | not)
               | select(reqcount(.findings) == 0)
             ] | length) > 0
       else true end) as $final_ok
    # Same-head unresolved required-tier finding (finding 3). Only enforced when
    # a non-empty final head is supplied and the final verdict is APPROVED. Any
    # non-fail-closed loop on that same head that recorded a required-tier
    # finding blocks — a rerun-without-commit cannot launder it into a clean
    # approval, because the head never advanced past the required finding.
    | (if $final == "APPROVED" and ($head | length) > 0
       then ([ .[]
               | select((.fail_closed.happened // false) | not)
               | select(.head_sha == $head)
               | select(reqcount(.findings) > 0)
             ] | length == 0)
       else true end) as $same_head_ok
    # same_head_only (#615 round 9, CodeRabbit): the approval-time hook checks
    # the LIVE loop log, where the current loop can be legitimately absent —
    # the record-scoped history/final clauses must not apply there.
    | (if $mode == "same_head_only" then $same_head_ok
       else ($history_ok and $final_ok and $same_head_ok) end)
  ' 2>/dev/null)" || return 1
  [ "$ok" = "true" ]
}

# --- verdict -> accounting mappers ------------------------------------------

# p4b_acct_tokens_from_verdict <verdict-json>
# Map a verdict.schema.json object's usage into the accounting tokens shape.
# usage null/absent ⇒ all-null counts with source "unavailable" — never an
# estimate. The additive #602 usage fields (cache_creation_input_tokens,
# cache_read_input_tokens, reasoning_tokens, total_cost_usd) map onto the
# accounting names — total_cost_usd is the CLI-REPORTED cost (e.g. the
# Claude print-mode envelope), carried through as cost_usd so the record
# and cost table can prefer a real reported figure over the price-table
# notional (#615 Codex round 2); absent stays null, never estimated.
#
# Split-total derivation (#615 Codex round 6): a schema-valid envelope may
# expose exact input_tokens + output_tokens while leaving token_count null
# (split-only CLIs). tokens.total then stayed null and every downstream
# consumer (per-approval totals, the loop-table cell, notional pricing,
# running totals) reported usage "unavailable" even though the split WAS
# captured. total is now derived from input+output when token_count is null
# but BOTH splits are present integers — an EXACT sum of measured counts,
# not a guess. never-guess semantics hold: if token_count is absent AND
# either split is null/absent, total stays null. token_count wins when
# present (even 0) so an explicit reported total is never overwritten.
p4b_acct_tokens_from_verdict() {
  printf '%s' "${1:-null}" | jq -c '
    (.usage // null) as $u
    | if $u == null then
        {total: null, input: null, output: null, cache_creation: null,
         cache_read: null, reasoning: null, cost_usd: null,
         source: "unavailable"}
      else
        { total: (if $u.token_count != null then $u.token_count
                  elif ($u.input_tokens != null and $u.output_tokens != null)
                  then ($u.input_tokens + $u.output_tokens)
                  else null end),
          input: ($u.input_tokens // null),
          output: ($u.output_tokens // null),
          cache_creation: ($u.cache_creation_input_tokens // null),
          cache_read: ($u.cache_read_input_tokens // null),
          reasoning: ($u.reasoning_tokens // null),
          cost_usd: ($u.total_cost_usd // null),
          source: ($u.source // "unavailable") }
      end' 2>/dev/null
}

# p4b_acct_findings_hist_from_verdict <verdict-json>
# Severity histogram over the accounting severity superset. The verdict
# contract is P0-P3; nitpick/unknown absorb other sources and anything
# unmapped. A null/absent findings array counts as zero findings.
p4b_acct_findings_hist_from_verdict() {
  printf '%s' "${1:-null}" | jq -c '
    (.findings // []) as $f
    | { P0: ([ $f[] | select(.severity == "P0") ] | length),
        P1: ([ $f[] | select(.severity == "P1") ] | length),
        P2: ([ $f[] | select(.severity == "P2") ] | length),
        P3: ([ $f[] | select(.severity == "P3") ] | length),
        nitpick: ([ $f[] | select(.severity == "nitpick") ] | length),
        unknown: ([ $f[]
                    | (.severity // "unknown") as $s
                    | select((["P0","P1","P2","P3","nitpick"] | index($s)) == null)
                  ] | length) }' 2>/dev/null
}

# The all-null histogram: a loop whose finding counts were not retained
# (e.g. a fail-closed loop whose verdict was discarded before parsing).
p4b_acct_findings_hist_null() {
  printf '%s' '{"P0":null,"P1":null,"P2":null,"P3":null,"nitpick":null,"unknown":null}'
}

# p4b_acct_finding_details_from_verdict <verdict-json> <loop#>
# Emit one JSONL line per finding: {loop, severity, path, line, body}. Feeds
# p4b_acct_unique_findings for the cross-loop lifecycle.
p4b_acct_finding_details_from_verdict() {
  local vj="${1:-null}" loop="$2"
  case "$loop" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s' "$vj" | jq -c --argjson loop "$loop" '
    (.findings // [])[]
    | { loop: $loop,
        severity: (.severity // "unknown"),
        path: (.path // null),
        line: (.line // null),
        body: (.body // "") }' 2>/dev/null
}

# p4b_acct_unique_findings [dispositions-json] [filed-issues-json]
# Read finding-detail JSONL on stdin (the concatenated output of
# p4b_acct_finding_details_from_verdict across loops) and emit the
# unique_findings array: de-duplicated by (severity, path, line, body),
# ordered by first appearance, ids F1..Fn, with first_loop / last_loop
# lifecycle. Each entry carries the finding CONTENT too — path, line, and a
# single-line title (first body line, truncated to 80 chars) — so a GitHub
# reader can tell what was fixed/deferred from the posted record alone
# (#615 Codex); full bodies stay in the local loop log, never in the posted
# block.
#
# Dispositions arrive on two optional channels; both default to "unresolved"
# with null links, because the accounting never GUESSES a disposition:
#   1. [dispositions-json] — the F-id-keyed map
#      ({"F1":{"disposition":"fixed","fix_commit":"abc","issue":null}, ...}).
#      Requires the caller to know each finding's first-appearance F-id.
#   2. [filed-issues-json] — a TUPLE-keyed list the orchestrator can populate
#      WITHOUT replaying the F-id reduce (#675):
#      [{severity, path, line, body, issue}, ...]. Each entry is joined on the
#      SAME collision-proof [severity, path, line, body] | tojson key computed
#      below and sets disposition "deferred-to-follow-up" + the issue link on
#      the matching finding.
# On a per-finding conflict the explicit F-id map (channel 1) wins field by
# field — its disposition/fix_commit override the filed channel's, and an
# explicit F-id `issue` KEY (even an explicit null) wins over the filed
# channel's issue (#675 Codex round 1: key-presence, not null-coalescing — a
# `{"disposition":"fixed","issue":null}` override keeps issue null instead of
# reattaching the filed follow-up). Only an ABSENT F-id issue key falls back.
p4b_acct_unique_findings() {
  local disp="${1:-}" filed="${2:-}"
  [ -n "$disp" ] || disp='{}'
  [ -n "$filed" ] || filed='[]'
  jq -cs --argjson disp "$disp" --argjson filed "$filed" '
    def title_of: (. // "") | split("\n")[0]
      | (if length > 80 then .[0:79] + "…" else . end)
      | (if . == "" then null else . end);
    # Filed-issue tuple map (#675): key each filed post-review issue by the
    # same collision-proof [severity, path, line, body] | tojson tuple the
    # dedupe below computes, normalized with the finding-detail defaults
    # (severity→"unknown", path/line→null, body→"") so a caller need not
    # reshape its list. Value: the deferred-to-follow-up disposition + issue;
    # the explicit F-id map overrides it per field in the final build.
    (reduce ($filed[]?) as $fi ({};
       ( [ ($fi.severity // "unknown"), ($fi.path // null),
           ($fi.line // null), ($fi.body // "") ] | tojson ) as $fk
       | .[$fk] = {disposition: "deferred-to-follow-up",
                   issue: ($fi.issue // null)} )) as $filedmap
    | reduce .[] as $d ( {order: [], map: {}} ;
      # Collision-proof de-dupe key (#615 Codex round 9, finding 3): JSON-encode
      # the (severity, path, line, body) tuple as an ARRAY so structural
      # boundaries can never be forged by content. The prior `severity | path |
      # line | body` string join let a finding whose text/path contained the
      # `|` separator collapse two distinct findings into one lifecycle entry
      # (e.g. (path=a, line=1, body="b|2|c") vs (path="a|1|b", line=2, body="c")
      # produced the same key), undercounting findings and attaching one
      # disposition to several issues. `tojson` on a heterogenous array
      # (strings + a number/null for line) is unambiguous and injective.
      ( [ $d.severity, ($d.path // null), ($d.line // null), $d.body ] | tojson ) as $k
      | if .map[$k] != null then
          .map[$k].last_loop = ([ .map[$k].last_loop, $d.loop ] | max)
          | .map[$k].first_loop = ([ .map[$k].first_loop, $d.loop ] | min)
        else
          .order += [$k]
          | .map[$k] = {severity: $d.severity,
                        path: ($d.path // null),
                        line: ($d.line // null),
                        title: ($d.body | title_of),
                        first_loop: $d.loop, last_loop: $d.loop}
        end )
    | . as $st
    | [ range(0; ($st.order | length)) as $i
        | $st.order[$i] as $k
        | ("F" + (($i + 1) | tostring)) as $id
        | ($disp[$id] // {}) as $o
        | ($filedmap[$k] // {}) as $fo
        | { id: $id,
            severity: $st.map[$k].severity,
            path: $st.map[$k].path,
            line: $st.map[$k].line,
            title: $st.map[$k].title,
            first_loop: $st.map[$k].first_loop,
            last_loop: $st.map[$k].last_loop,
            disposition: ($o.disposition // $fo.disposition // "unresolved"),
            fix_commit: ($o.fix_commit // null),
            # Key-presence, not null-coalescing (#675 Codex round 1): an
            # explicit F-id `issue` (even null) wins over the filed channel;
            # only an ABSENT F-id issue key falls back to the filed issue, so a
            # `{"disposition":"fixed","issue":null}` override is not silently
            # re-linked to the filed follow-up.
            issue: (if ($o | has("issue")) then $o.issue
                    else ($fo.issue // null) end) } ]' 2>/dev/null
}

# p4b_acct_filed_issues_from_refs <refs-csv> <file-json>
# Build the tuple-keyed filed-issues payload (P4B_ACCT_FILED_ISSUES_JSON) the
# render hook consumes, by zipping a comma-separated "#N" ref list — line 1 of
# scripts/phase-4b-review.sh's p4b_file_post_review_issues, aligned 1:1 with
# <file-json>.findings in filing order (reused + created alike) — onto those
# findings. Emits a JSON array of {severity, path, line, body, issue} with a
# NUMERIC issue (schema: unique_finding.issue is integer|null).
#
# Position-preserving (#675 Codex round 1): a ref token that is not a bare
# "#<digits>" maps to a NULL placeholder rather than being dropped, so an
# unparseable middle ref never shifts a later issue number onto the wrong
# finding — e.g. "#101, #bad, #103" keeps 103 on finding index 2, not index 1.
# A finding whose ref is null/absent is then dropped (left unlinked), so the
# enrichment never fabricates a finding→issue association. Prints "[]" on a
# malformed <file-json> (the enrichment is advisory — never a hard failure).
p4b_acct_filed_issues_from_refs() {
  local refs="$1" file_json="$2" refs_json out
  refs_json="$(printf '%s' "$refs" | jq -Rc '
    [ splits(", *")
      | ltrimstr("#")
      | (if test("^[0-9]+$") then tonumber else null end) ]' 2>/dev/null)" || refs_json='[]'
  [ -n "$refs_json" ] || refs_json='[]'
  out="$(printf '%s' "$file_json" | jq -c --argjson refs "$refs_json" '
    [ .findings | to_entries[]
      | {severity: .value.severity,
         path: (.value.path // null),
         line: (.value.line // null),
         body: (.value.body // ""),
         issue: ($refs[.key] // null)}
      | select(.issue != null) ]' 2>/dev/null)" || out=''
  [ -n "$out" ] || out='[]'
  printf '%s' "$out"
}

# --- record assembly -------------------------------------------------------

# p4b_acct_build_record — assemble the full p4b-accounting/v1 record.
# All inputs are passed explicitly (pure function). Prints the compact record
# JSON on stdout, or returns non-zero (no output) if the fail-closed invariant
# is violated or the inputs cannot be assembled into valid JSON.
#
# Positional inputs (all required unless noted):
#   $1 pr                                   positive integer
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

  case "$pr" in ''|*[!0-9]*) return 1 ;; esac

  # Fail-closed: never emit an APPROVED record whose loop history violates
  # the strict posting rule (see the assertion's contract above). The final
  # head is passed so a same-head unresolved required finding (a rerun without
  # a new commit, #615 round 8 finding 3) is rejected, not laundered.
  if ! p4b_acct_assert_no_required_with_approved "$verdict" "$loops_json" "$head"; then
    p4b_acct_warn "refusing to build APPROVED accounting: loop history violates the required-tier posting rule (fail-closed)"
    return 1
  fi

  [ -n "$gen_at" ] || gen_at="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "")"
  local wall_arg
  case "$wall" in
    '') wall_arg="null" ;;
    *[!0-9]*) return 1 ;;
    *) wall_arg="$wall" ;;
  esac

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

# Render a token count cell for the loop table: "N,NNN (source)", with the
# in/out split when the CLI exposed one, or "unavailable (source)" — never
# an estimate.
p4b_acct_fmt_tokens_cell() {
  local tokens_json="$1"
  printf '%s' "$tokens_json" | jq -r '
    def commafy:
      tostring
      | explode | reverse
      | [ range(0; length) as $i | .[$i], (if ($i % 3 == 2 and $i != length-1) then 44 else empty end) ]
      | reverse | implode;
    if .total != null and .input != null and .output != null then
      "\(.total | commafy) (\(.source): in \(.input | commafy) / out \(.output | commafy))"
    elif .total != null then "\(.total | commafy) (\(.source))"
    else "unavailable (\(.source))" end' 2>/dev/null
}

# Render one rigor row: "| <check> | <result> | <evidence> |". A row whose
# signal is absent renders "n/a" + the reason rather than a green check.
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
# produced by p4b_acct_build_record. Prints markdown on stdout; returns
# non-zero (no output committed to the caller) on malformed input or when the
# record violates the required-tier posting rule (defense in depth — the
# builder already refuses, but render can be called on arbitrary records).
p4b_acct_render_block() {
  local rec="$1"
  [ -n "$rec" ] || return 1
  printf '%s' "$rec" | jq -e . >/dev/null 2>&1 || return 1

  local pr head verdict reviewer direction astate wall loops_json
  pr="$(printf '%s' "$rec" | jq -r '.pr')"
  head="$(printf '%s' "$rec" | jq -r '.final_head_sha')"
  verdict="$(printf '%s' "$rec" | jq -r '.final_verdict')"
  reviewer="$(printf '%s' "$rec" | jq -r '.final_reviewer')"
  direction="$(printf '%s' "$rec" | jq -r '.final_direction')"
  astate="$(printf '%s' "$rec" | jq -r '.automation_state')"
  wall="$(printf '%s' "$rec" | jq -r '.wall_time_first_loop_to_approval_seconds // "unavailable"')"
  loops_json="$(printf '%s' "$rec" | jq -c '.loops')"

  # Defense in depth: refuse to render an illegal record (incl. a same-head
  # unresolved required finding, #615 round 8 finding 3 — head threaded).
  p4b_acct_assert_no_required_with_approved "$verdict" "$loops_json" "$head" || return 1

  local wall_disp
  if [ "$wall" = "unavailable" ]; then wall_disp="unavailable"; else wall_disp="${wall} s"; fi

  printf '## Phase 4b Approval Accounting\n\n'
  printf '**Reviewed head:** `%s` · **Final verdict:** `%s` as `%s` (%s) · **Automation state:** %s · **Wall time, first 4b loop → approval:** %s\n\n' \
    "$head" "$verdict" "$reviewer" "$direction" "$astate" "$wall_disp"

  # --- Loop summary ---
  printf '### Loop summary\n\n'
  printf '| Loop | Reviewer | Adapter · direction | Verdict | Posted? | Elapsed | Tokens (source) | P0 | P1 | P2 | P3 | Nit | Fail-closed |\n'
  printf '|---:|---|---|---|---|---:|---|---:|---:|---:|---:|---:|---|\n'
  local loops_count i loop_json tok_cell
  loops_count="$(printf '%s' "$rec" | jq -r '.loops | length')"
  i=0
  while [ "$i" -lt "$loops_count" ]; do
    loop_json="$(printf '%s' "$rec" | jq -c ".loops[$i]")"
    tok_cell="$(p4b_acct_fmt_tokens_cell "$(printf '%s' "$loop_json" | jq -c '.tokens')")"
    printf '%s' "$loop_json" | jq -r --arg tok "$tok_cell" '
      def cell(x): (if x == null then "—" else (x | tostring) end);
      "| \(.loop) | \(.reviewer) | \(.adapter) · \(.direction) | \(.verdict) | \(.posted) | "
      + (if .elapsed_seconds == null then "n/a" else "\(.elapsed_seconds) s" end)
      + " | \($tok) | \(cell(.findings.P0)) | \(cell(.findings.P1)) | \(cell(.findings.P2)) | \(cell(.findings.P3)) | \(cell(.findings.nitpick)) | "
      + (if .fail_closed.happened then "**yes** — \(.fail_closed.reason // "unrecorded reason")" else "no" end)
      + " |"'
    i=$((i + 1))
  done
  printf '\n'

  # --- Findings and disposition ---
  local uf_count
  uf_count="$(printf '%s' "$rec" | jq -r '.unique_findings | length')"
  printf '### Findings and disposition\n\n'
  if [ "$uf_count" -eq 0 ]; then
    printf '_No findings recorded on the approved HEAD. See the rigor table below for evidence this was reviewed hard rather than rubber-stamped._\n\n'
  else
    # Scope labels findings truthfully (#615 Codex): a finding is
    # "current-head" only when it was last seen on a loop that reviewed the
    # record's final head sha; findings last seen on a prior commit are
    # "historical" (the changes-requested-then-fixed lifecycle), never
    # relabeled as residual current-head risk. An unmappable last_loop
    # degrades to current-head — risk is overstated, never understated.
    # Location/Summary come from the embedded record so a GitHub reader can
    # reconstruct what was fixed/deferred without local files (#615 Codex);
    # summaries are single-line 80-char truncations, never full bodies.
    printf '| Finding | Severity | Location | Summary | Scope | First loop | Last seen | Disposition | Fix commit / issue |\n'
    printf '|---|---|---|---|---|---:|---:|---|---|\n'
    printf '%s' "$rec" | jq -r '
      (.final_head_sha) as $head
      | ([ .loops[] | select(.head_sha == $head) | .loop ]) as $hl
      | def scope($ll): if ($hl | length) == 0 then "current-head"
                        elif ($hl | index($ll)) != null then "current-head"
                        else "historical" end;
      ( .unique_findings[]
        | "| \(.id) | \(.severity) | "
          + (if (.path // null) == null then "—"
             else "`\(.path)\(if .line != null then ":\(.line)" else "" end)`" end)
          + " | "
          + ((.title // "—") | gsub("\\|"; "\\\\|"))
          + " | \(scope(.last_loop)) | \(.first_loop) | \(.last_loop) | \(.disposition) | "
          + (if .fix_commit != null then "`\(.fix_commit)`"
             elif .issue != null then "#\(.issue)"
             else "—" end)
          + " |" ),
      "",
      ( ([ .unique_findings[] | select(.first_loop != .last_loop) ] | length) as $rep
        | ([ .unique_findings[] | select(scope(.last_loop) == "current-head") ] | length) as $cur
        | "Unique findings across loops: \(.unique_findings | length) — \($cur) on the approved head, \((.unique_findings | length) - $cur) historical (earlier loops only). Repeated across loops: \($rep)." )'
    printf '\n'
  fi

  # --- Rigor (proof-of-work for the final posted approval) ---
  # Every green row is backed by a signal captured in the record or enforced
  # structurally by the orchestrator path that produced it; anything not
  # captured renders n/a with the reason (never a green check on faith).
  printf '### Rigor (final posted approval)\n\n'
  printf '| Check | Result | Evidence |\n'
  printf '|---|---|---|\n'
  local is_auto=false final_loop
  [ "$astate" != "manual" ] && is_auto=true
  # The loop backing the posted verdict: the last clean APPROVED loop for an
  # APPROVED record (probes/fail-closed loops may follow it), else the last.
  final_loop="$(printf '%s' "$rec" | jq -c '
    if .final_verdict == "APPROVED"
    then ((.loops | map(select(.verdict == "APPROVED")) | last) // (.loops | last))
    else (.loops | last) end')"

  if [ "$is_auto" = true ]; then
    p4b_acct_rigor_row "Verdict schema-conformant" true "orchestrator validated via the lib.sh jq mirror of verdict.schema.json before rendering"
    p4b_acct_rigor_row "Reviewed current HEAD" true "review POST pinned commit_id=\`$head\`; created-review SHA re-verified (head drift falls back)"
  else
    p4b_acct_rigor_row "Verdict schema-conformant" false "manual handoff; validation signal not captured"
    p4b_acct_rigor_row "Reviewed current HEAD" false "manual handoff; HEAD-pin signal not captured"
  fi

  local xagent
  xagent="$(printf '%s' "$rec" | jq -r '
    (.final_direction | test("->"))
    and ((.final_direction | split("->")[0])
         != (.final_reviewer | sub("^nathanpayne-"; "")))')"
  if [ "$xagent" = "true" ]; then
    p4b_acct_rigor_row "Cross-agent (reviewer ≠ author)" true "direction \`$direction\`, reviewer \`$reviewer\`"
  else
    p4b_acct_rigor_row "Cross-agent (reviewer ≠ author)" false "direction \`$direction\` does not evidence a distinct authoring agent"
  fi

  local plan_auth
  plan_auth="$(printf '%s' "$final_loop" | jq -r '.plan_auth // ""')"
  if [ -n "$plan_auth" ]; then
    p4b_acct_rigor_row "Plan-only auth (no metered API)" true "\`plan_auth=$plan_auth\` verified by the adapter gate; API-key env scrubbed"
  else
    p4b_acct_rigor_row "Plan-only auth (no metered API)" false "plan-auth posture not captured for this loop"
  fi

  local known_adapter
  known_adapter="$(printf '%s' "$final_loop" | jq -r '
    (.adapter // "") | test("^review-via-(codex|claude)\\.sh$|^orchestrator")')"
  if [ "$known_adapter" = "true" ]; then
    p4b_acct_rigor_row "Read-only posture" true "codex \`--sandbox read-only\` / claude \`--permission-mode plan --tools \"\"\` (pinned by the adapter)"
    p4b_acct_rigor_row "Exhaustive review pass" true "bounded \"Exhaustive code review\" adapter prompt"
  else
    p4b_acct_rigor_row "Read-only posture" false "adapter posture not captured for this loop"
    p4b_acct_rigor_row "Exhaustive review pass" false "adapter prompt not captured for this loop"
  fi

  local fc_events
  fc_events="$(printf '%s' "$rec" | jq -r '.totals.fail_closed_events // 0')"
  p4b_acct_rigor_row "Fail-closed rule honored" true "0 required-tier findings on the posted approval (asserted at build + render); $fc_events fail-closed loop(s) recorded"

  if [ -n "${P4B_ACCT_GATES_EVIDENCE:-}" ]; then
    p4b_acct_rigor_row "Local gates green" true "$P4B_ACCT_GATES_EVIDENCE"
  else
    p4b_acct_rigor_row "Local gates green" false "local gate results not captured for this run"
  fi

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
    | (if $t.elapsed_seconds_total == null then "unavailable (no loop timings captured)"
       else "\($t.elapsed_seconds_total) s across \($t.adapter_invocations) loop(s)" end) as $wallrow
    | (if $t.tokens_total == null then "unavailable (no CLI-exposed counts)"
       else "\($t.tokens_total) total ("
            + ([ $t.tokens_by_provider | to_entries[] | "\(.key) \(.value)" ] | join(", "))
            + ")" end) as $tok
    # Cost-source preference (#615 Codex round 2): a CLI-REPORTED cost beats
    # the price-table notional, each labeled with its source; when neither
    # exists the row stays an explicit n/a — never a guess.
    | (if $t.reported_cost_usd != null then "~$\($t.reported_cost_usd) *(not billed; CLI-reported)*"
       elif $t.notional_usd == null then "n/a — no price resolvable for the recorded loops *(not billed either way)*"
       else "~$\($t.notional_usd) *(not billed; price table `\($t.price_table_version // "unknown")`)*" end) as $notional
    | ([ .loops[] | .throttle_events | select(. != null) ]) as $thr
    | (if ($thr | length) == 0 then "not captured" else ($thr | add | tostring) end) as $throttle
    | ((.loops | last | .timeout_seconds) // null) as $timeout
    | "| Reviewer wall-clock | **\($wallrow)** |\n"
      + (if $timeout != null then "| Timeout budget | \($timeout) s configured (#589) |\n" else "" end)
      + "| Tokens observed | \($tok) |\n"
      + "| Billed cost | **$0.00** — operator subscription plan |\n"
      + "| Notional API-equivalent | **\($notional)** |\n"
      + "| Plan-capacity throttle events | \($throttle) |\n"
      + "| Human shuttle avoided | **~\($mlow) min – \($mhigh / 60) h** (manual Phase 4b handoff, per REVIEW_POLICY.md § Phase 4b Triggers) |"'
  printf '\n\n'

  # --- Running totals ---
  # Honest scope labeling (#615 Codex round 3): the heading names exactly
  # what was scanned. "repo, to date" is claimed ONLY for a github-derived
  # aggregation whose scan window was NOT truncated; a cap-truncated scan
  # is labeled as a bounded window of recently updated merged PRs, and the
  # ledger-cache fallback as the local cache it is — never repo-wide.
  # Nested review truncation (#615 round 4) folds into the same truncated
  # labeling, and the footer additionally names the PRs whose deeper review
  # history was left unscanned.
  local rt_source rt_trunc rt_scanned
  rt_source="$(printf '%s' "$rec" | jq -r '.running_totals.source')"
  rt_trunc="$(printf '%s' "$rec" | jq -r '.running_totals.window.truncated // false')"
  rt_scanned="$(printf '%s' "$rec" | jq -r '.running_totals.window.scanned_prs // 0')"
  if [ "$rt_source" = "github-derived" ] && [ "$rt_trunc" = "true" ]; then
    printf '### Running totals — window: last %s merged PRs\n\n' "$rt_scanned"
  elif [ "$rt_source" = "github-derived" ]; then
    printf '### Running totals — repo, to date\n\n'
  elif [ "$rt_source" = "ledger-cache" ]; then
    printf '### Running totals — local ledger cache (this checkout only)\n\n'
  else
    printf '### Running totals\n\n'
  fi
  if [ "$rt_source" = "unavailable" ]; then
    printf '%s' "$rec" | jq -r '"_Running totals unavailable — \(.running_totals.reason // "aggregation degraded")._"'
    printf '\n\n'
  else
    printf '| Metric | Cumulative |\n'
    printf '|---|---|\n'
    printf '%s' "$rec" | jq -r '
      .running_totals as $r
      | ($r.auto_approved_prs // 0) as $ap
      | ($r.automated_attempts // 0) as $at
      | ($r.fail_closed_events // 0) as $fc
      # Rate denominator is automated ATTEMPTS, not records (#615 Codex):
      # records are only emitted on approvals, so approvals/records would
      # render 100% even across fail-closed history. Attempts include every
      # recorded loop (posted + fell-back), which is the trust signal the
      # spec golden shows (24 / 27 = 89%).
      | (if $at > 0 then "\($ap) approved / \($at) automated attempts = \((($ap / $at) * 100) | round)% · \($fc) fail-closed loop(s) to human"
         else "n/a (no recorded attempts)" end) as $rate
      | "| Auto-approved PRs | \($ap) |\n"
        + "| Automated attempts (posted + fell-back) | \($at) |\n"
        + "| **Auto-approval / fail-closed rate** | **\($rate)** |\n"
        + "| Cumulative wall-clock | "
        + (if $r.elapsed_seconds_total == null then "unavailable (not measured in every prior record)"
           else "\(($r.elapsed_seconds_total / 60) | floor) min" end)
        + " |\n"
        + "| Cumulative tokens | "
        + (if $r.tokens_total == null then "unavailable (not measured in every prior record)"
           else ($r.tokens_total | tostring) end)
        + " |\n"
        + "| Cumulative notional API-equivalent | "
        + (if $r.notional_usd == null then "unavailable (not priced in every prior record) *(not billed either way)*"
           else "~$\($r.notional_usd) *(not billed)*" end)
        + " |\n"
        + "| Cumulative human time saved (est.) | "
        # Sub-hour bounds render in minutes, not floored-to-zero hours (#615
        # Codex round 7, finding 3): a low bound like 30 min divided by 60 and
        # floored reads as ~0 h, understating the documented 30-minute floor.
        # When BOTH bounds are >= 60 min the shared-unit "~A – B h" form is kept
        # (matches the spec golden ~12 – 72 h); once the low bound drops below an
        # hour each bound carries its own unit ("~30 min – 3 h", or "~30 – 50 min"
        # when both are sub-hour), consistent with the per-loop shuttle block.
        + (if $r.human_minutes_saved_estimate == null then "unavailable"
           else ($r.human_minutes_saved_estimate[0]) as $lo
                | ($r.human_minutes_saved_estimate[1]) as $hi
                # A bound < 60 min renders in minutes; >= 60 min in floored
                # hours. When both bounds share a unit the unit is stated once
                # ("~12 – 72 h", "~30 – 50 min"); a mixed range carries a unit on
                # each bound ("~30 min – 3 h").
                | def num($m): if $m < 60 then ($m | tostring) else (($m / 60) | floor | tostring) end;
                  def unit($m): if $m < 60 then "min" else "h" end;
                  if unit($lo) == unit($hi)
                  then "~\(num($lo)) – \(num($hi)) \(unit($hi))"
                  else "~\(num($lo)) \(unit($lo)) – \(num($hi)) \(unit($hi))" end end)
        + " |"'
    printf '\n\n'
    printf '%s' "$rec" | jq -r '
      "*Totals source: \(.running_totals.source) (\(.running_totals.records) prior record(s))"
      + (if ((.running_totals.records_dropped_nonconformant // 0) > 0)
         then "; \(.running_totals.records_dropped_nonconformant) tagged record(s) dropped as incomplete (missing required fields — never aggregated)"
         else "" end)
      + (if (.running_totals.window.truncated // false)
         then "; window: last \(.running_totals.window.scanned_prs) merged PRs — older history beyond the scan cap is not included"
         else "" end)
      + (if ((.running_totals.window.review_truncated_prs // 0) > 0)
         then "; \(.running_totals.window.review_truncated_prs) scanned PR(s) hold more reviews than the nested review window — their older reviews are not included"
         else "" end)
      + ".*"'
    printf '\n\n'
  fi

  # --- Embedded machine-readable record ---
  # Comment-delimiter sequences inside record strings are encoded as JSON
  # unicode escapes (#615 Codex round 2) so the payload can never close the
  # comment early (visible render + truncated extraction). The case guard is
  # the writer-side guarantee: refuse to emit rather than post a delimiter-
  # carrying payload (structurally unreachable after the encoder).
  local payload
  payload="$(printf '%s' "$rec" | jq -c '.' | p4b_acct_encode_comment_payload)"
  [ -n "$payload" ] || return 1
  case "$payload" in
    *'-->'*|*'--!>'*|*'<!--'*) return 1 ;;
  esac
  printf '<!-- %s\n' "$(p4b_acct_marker)"
  printf '%s\n' "$payload"
  printf -- '-->\n'
}

# ============================================================================
# Orchestrator hook layer (#602)
# ============================================================================
# Thin glue so the diff in scripts/phase-4b-review.sh stays minimal. These
# functions read the orchestrator's documented runtime globals:
#   PR REPO HEAD REVIEWER ADAPTER DIRECTION VERDICT_JSON ADAPTER_TIMEOUT
#   EFFECTIVE_EFFORT DRY_RUN P4B_ACCT_LOOP_STARTED_EPOCH
#   P4B_ACCT_LOOP_ELAPSED_SECONDS
# (tests set the same globals). Every function returns non-zero on failure
# and NEVER exits — the orchestrator treats any failure as "post the plain
# summary". State lives under .mergepath/ (gitignored runtime state, the same
# home as the codex-record-feedback ledger); override via P4B_ACCT_STATE_DIR.

p4b_acct_state_dir() {
  if [ -n "${P4B_ACCT_STATE_DIR:-}" ]; then
    printf '%s' "$P4B_ACCT_STATE_DIR"
    return 0
  fi
  printf '%s/.mergepath' "$(p4b_acct_repo_root)"
}

# Per-PR loop log (JSONL of {"schema":"p4b-loop-log/v1", started_at_epoch,
# loop:{...accounting loop...}, details:[{loop,severity,path,line,body}...]}).
# Accumulates one line per orchestrator invocation so a later APPROVED can
# render the full multi-loop history.
p4b_acct_hook_loop_log() {
  local repo_slug
  repo_slug="$(printf '%s' "${REPO:-unknown}" | tr '/ ' '--')"
  printf '%s/phase-4b-loops/%s-pr%s.jsonl' "$(p4b_acct_state_dir)" "$repo_slug" "${PR:-0}"
}

# Append-only running-totals ledger cache (the spec's
# .mergepath/phase-4b-ledger.jsonl fallback source).
p4b_acct_hook_ledger() {
  printf '%s/phase-4b-ledger.jsonl' "$(p4b_acct_state_dir)"
}

# Per-PR staging file for the two-phase ledger commit (#615 Codex): the
# render hook runs in a command substitution (subshell), so the pending
# record is staged on disk, and the orchestrator commits it to the ledger
# ONLY after the GitHub review POST actually succeeds. A head-drift or POST
# failure discards it — the ledger never gains a phantom posted approval.
p4b_acct_hook_pending_record_path() {
  local repo_slug
  repo_slug="$(printf '%s' "${REPO:-unknown}" | tr '/ ' '--')"
  printf '%s/phase-4b-pending/%s-pr%s.json' "$(p4b_acct_state_dir)" "$repo_slug" "${PR:-0}"
}

# Sidecar carrying the run id of the invocation that STAGED the pending record
# (#615 Codex round 6). The two-phase commit spans a subshell (render stages
# on disk) and the parent commit call, so ownership cannot ride a shell var;
# it is written next to the pending record and compared at commit time.
p4b_acct_hook_pending_runid_path() {
  printf '%s.runid' "$(p4b_acct_hook_pending_record_path)"
}

# p4b_acct_run_id — this invocation's staging token. Set once by the
# orchestrator (exported P4B_ACCT_RUN_ID so the render subshell and the parent
# commit call agree); a stable per-process fallback (PID + start time) keeps
# direct hook callers/tests correct when unset. NEVER regenerated per call.
p4b_acct_run_id() {
  if [ -n "${P4B_ACCT_RUN_ID:-}" ]; then
    printf '%s' "$P4B_ACCT_RUN_ID"
    return 0
  fi
  printf 'pid-%s' "$$"
}

# p4b_acct_hook_commit_posted_record — phase two of the ledger commit: append
# the staged record to the ledger cache and clear the staging file. Called by
# the orchestrator ONLY from the confirmed-post branch (after a successful live
# review POST), so reaching this function means "the approval posted".
#
# Ownership check (#615 Codex round 6): commit ONLY a record staged by THIS
# invocation. Without it, a previous run that crashed AFTER staging but BEFORE
# posting leaves a stale pending record; a later APPROVED run whose accounting
# render fails/skips (the fail-open path) never re-stages, yet this commit
# would append that phantom/old record after the new review posts — corrupting
# the ledger and running totals. The staged record's sidecar run id must match
# this invocation's; a mismatch (or a missing sidecar) means the pending record
# belongs to a different run and is DISCARDED, never committed (fail-closed:
# when unsure, drop). Advisory: an append failure warns (future running totals
# may lag) but never alters review flow. Always returns 0.
#
# Loop-log rotation keys off "the approval posted", NOT "a record was committed"
# (#615 Codex round 7, finding 1). This run's APPROVED loop was appended to the
# live log by p4b_acct_hook_record_loop BEFORE the render/post step, so the loop
# is in the live log regardless of whether the render staged a ledger record.
# When rendering FAILED/skipped (no pending record) or the only pending record
# belongs to a DIFFERENT run (ownership mismatch), the earlier logic returned
# early WITHOUT rotating — leaving this run's consumed APPROVED loop in the live
# log to be re-counted by the next rerun's record (double-counting attempts,
# tokens, and wall time). The rotation is now the single unconditional trailing
# step, so it fires exactly once per posted-approval commit call across ALL
# three exit paths (no-record, ownership-mismatch, committed). It never
# double-rotates (one call per commit; rotate archives+truncates the whole live
# log) and never rotates a NON-posted run (non-posted runs never reach this
# function — the orchestrator calls it only in the post-success branch).
# Composes with the round-6 run-id ownership check: ownership governs which
# LEDGER record is committed; rotation governs the LOOP log — orthogonal axes,
# and this run's own appended loop is consumed either way.
p4b_acct_hook_commit_posted_record() {
  local pending runid_file staged_runid ledger
  pending="$(p4b_acct_hook_pending_record_path)"
  if [ ! -s "$pending" ]; then
    # Rendering failed/skipped: no record to commit, but the approval posted, so
    # this run's already-appended APPROVED loop must still be consumed (#615
    # round 7, finding 1).
    p4b_acct_hook_rotate_loop_log_after_approval || true
    return 0
  fi
  runid_file="$(p4b_acct_hook_pending_runid_path)"
  staged_runid=""
  [ -r "$runid_file" ] && staged_runid="$(cat "$runid_file" 2>/dev/null || true)"
  if [ -z "$staged_runid" ] || [ "$staged_runid" != "$(p4b_acct_run_id)" ]; then
    p4b_acct_warn "discarding a pending ledger record from a different invocation (run id '${staged_runid:-none}' != '$(p4b_acct_run_id)'); the current run did not stage it, so it is not committed (#615 round 6)"
    p4b_acct_hook_discard_pending_record
    # The foreign record is dropped, but THIS run's approval still posted — its
    # appended loop must be rotated out too, or a rerun re-counts it (#615
    # round 7, finding 1).
    p4b_acct_hook_rotate_loop_log_after_approval || true
    return 0
  fi
  ledger="$(p4b_acct_hook_ledger)"
  if ! { mkdir -p "$(dirname "$ledger")" && cat "$pending" >> "$ledger"; } 2>/dev/null; then
    p4b_acct_warn "could not append the posted record to the ledger cache (future running totals may lag)"
  fi
  p4b_acct_hook_discard_pending_record
  # Per-approval loop-log rotation (#615 Codex round 6): now that THIS run's
  # approval record is committed, the loops it embedded are consumed. Rotate
  # them out of the per-PR loop log so a later rerun (another commit → another
  # Phase 4b pass) aggregates only loops SINCE this approval — otherwise the
  # NEXT posted record would repeat these attempts and cumulative running
  # totals (which sum loop spend across ALL posted records) would double-count
  # tokens, attempts, and wall time. Advisory — a rotation failure warns but
  # never alters review flow.
  p4b_acct_hook_rotate_loop_log_after_approval || true
  return 0
}

# p4b_acct_hook_rotate_loop_log_after_approval — archive the current per-PR
# loop log so the next rerun starts a fresh segment (#615 Codex round 6).
# Called ONLY from the confirmed-post commit path, so it fires exactly once
# per posted approval. The consumed lines are appended to a per-PR archive
# (never deleted — the full history stays auditable and the archive is the
# high-water mark) and the live log is truncated. Loop numbering
# (p4b_acct_hook_record_loop counts objects in the LIVE log) then restarts at
# 1 for the next segment, so each posted record's loops are self-contained and
# appear in exactly one record — the round-4 in-record lifecycle links still
# hold (they are keyed within a single segment/record).
#
# Interaction (#615 round 6): this reset governs the per-approval loops[]/
# totals embedded in EACH record. The GitHub-fetch dedup (round 5) dedups only
# the auto_approved_prs PR metric; loop SPEND is deliberately summed across all
# records. With each loop now embedded in exactly one record, that per-record
# summation counts every loop once — the two corrections are orthogonal (PR
# dedup vs. one-record-per-loop), never double-correcting the same axis.
p4b_acct_hook_rotate_loop_log_after_approval() {
  local log archive
  log="$(p4b_acct_hook_loop_log)" || return 1
  [ -s "$log" ] || return 0
  # Archive suffix deliberately does NOT end in .jsonl so a `*.jsonl` glob over
  # the loop-log dir (tests, other consumers) never picks the archive as the
  # live log (#615 round 6).
  archive="${log}.archive"
  if ! { mkdir -p "$(dirname "$archive")" && cat "$log" >> "$archive"; } 2>/dev/null; then
    p4b_acct_warn "could not archive the per-PR loop log after approval; leaving it in place (a rerun may repeat these loops)"
    return 1
  fi
  # Truncate the live log so the next segment starts empty (loop numbering
  # restarts at 1). Removing the file would work too, but truncation keeps a
  # stable path and permissions for the next append.
  : > "$log" 2>/dev/null || { p4b_acct_warn "could not truncate the per-PR loop log after archiving"; return 1; }
  return 0
}

# p4b_acct_hook_discard_pending_record — drop a staged record (and its run-id
# sidecar) that will not be committed (the review did not post, or it belongs
# to a different invocation). Always returns 0.
p4b_acct_hook_discard_pending_record() {
  rm -f "$(p4b_acct_hook_pending_record_path)" \
        "$(p4b_acct_hook_pending_runid_path)" 2>/dev/null || true
  return 0
}

# p4b_acct_hook_mark_last_loop_unposted <reason>
# Correct this invocation's provisional loop record after the GitHub POST did
# NOT complete (#615 Codex): the loop is recorded (posted state claimed)
# before post_review re-reads the live head and sends the review, so on
# head-drift/POST failure the log would otherwise keep a phantom posted
# entry. Rewrites the loop log's LAST line to posted="not-posted",
# fell_back=true, with a fail-closed marker carrying the reason (the verdict
# itself is kept — it WAS parsed; only the posting claim was false).
p4b_acct_hook_mark_last_loop_unposted() {
  local reason="$1" log tmp
  log="$(p4b_acct_hook_loop_log)" || return 1
  [ -s "$log" ] || return 1
  tmp="${log}.tmp.$$"
  if jq -cs --arg reason "$reason" '
      (.[0:length-1][]),
      (.[length-1]
       | .loop.posted = "not-posted"
       | .loop.fell_back = true
       | .loop.fail_closed = {happened: true,
                              reason: (if $reason == "" then null else $reason end),
                              duration_seconds: .loop.elapsed_seconds})
    ' "$log" > "$tmp" 2>/dev/null; then
    mv "$tmp" "$log" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; return 1; }
  else
    rm -f "$tmp" 2>/dev/null
    return 1
  fi
}

# Gate for every hook call site: the accounting sub-toggle.
p4b_acct_hook_active() { p4b_acct_config_enabled; }

# p4b_acct_hook_record_loop <verdict-label> <posted> <fell_back> <fail-reason|"">
# Build this invocation's loop record from the orchestrator globals and
# append it to the per-PR loop log. verdict-label is the accounting verdict
# enum (APPROVED | APPROVED_WITH_ADVISORIES | CHANGES_REQUESTED |
# UNAVAILABLE). UNAVAILABLE ⇒ finding counts were not retained (all-null
# histogram); otherwise they come from VERDICT_JSON.
p4b_acct_hook_record_loop() {
  local vlabel="$1" posted="$2" fell_back="$3" fail_reason="${4:-}"
  local log logdir loopno tokens hist details fc line
  local elapsed_json started_json timeout_json effort_json plan_auth_json details_json
  log="$(p4b_acct_hook_loop_log)" || return 1
  logdir="$(dirname "$log")"
  mkdir -p "$logdir" 2>/dev/null || return 1
  # The next loop number counts the JSON OBJECTS already in the log, not its
  # lines (#615 Codex round 4). Every writer here is compact-JSONL already —
  # the append below is jq -nc and the unposted-correction rewrite is jq -cs
  # (one object per line, verified by test) — but a line count would silently
  # inflate loop IDs (and break the finding-lifecycle links keyed on them) if
  # a record ever spanned multiple lines, so numbering is anchored to the
  # parse instead. A log jq cannot parse falls back to the historical line
  # count (degraded numbering, never a blocked loop).
  loopno=1
  if [ -f "$log" ]; then
    loopno="$(jq -s 'length + 1' "$log" 2>/dev/null)" || loopno=""
    case "$loopno" in
      ''|*[!0-9]*) loopno="$(($(wc -l < "$log") + 1))" 2>/dev/null || loopno=1 ;;
    esac
  fi

  if [ "$vlabel" = "UNAVAILABLE" ] || [ -z "${VERDICT_JSON:-}" ]; then
    tokens="$(p4b_acct_tokens_from_verdict 'null')" || return 1
    hist="$(p4b_acct_findings_hist_null)"
    details=""
  else
    tokens="$(p4b_acct_tokens_from_verdict "${VERDICT_JSON:-null}")" || return 1
    hist="$(p4b_acct_findings_hist_from_verdict "${VERDICT_JSON:-null}")" || return 1
    details="$(p4b_acct_finding_details_from_verdict "${VERDICT_JSON:-null}" "$loopno")" || details=""
  fi
  details_json="$(printf '%s\n' "$details" | jq -cs '.' 2>/dev/null)" || details_json='[]'

  case "${P4B_ACCT_LOOP_ELAPSED_SECONDS:-}" in
    ''|*[!0-9]*) elapsed_json="null" ;;
    *) elapsed_json="${P4B_ACCT_LOOP_ELAPSED_SECONDS}" ;;
  esac
  case "${P4B_ACCT_LOOP_STARTED_EPOCH:-}" in
    ''|*[!0-9]*) started_json="null" ;;
    *) started_json="${P4B_ACCT_LOOP_STARTED_EPOCH}" ;;
  esac
  case "${ADAPTER_TIMEOUT:-}" in
    ''|*[!0-9]*) timeout_json="null" ;;
    *) timeout_json="${ADAPTER_TIMEOUT}" ;;
  esac
  if [ -n "${EFFECTIVE_EFFORT:-}" ]; then
    effort_json="$(jq -nc --arg v "${EFFECTIVE_EFFORT}" '$v' 2>/dev/null)" || effort_json="null"
  else
    effort_json="null"
  fi
  # cli_version (#622): map the adapter envelope's own field through instead
  # of fabricating one. VERDICT_JSON is the adapter's raw stdout — an older
  # adapter that predates #622, or a capture failure inside the adapter,
  # leaves the key absent/null here too; that is the honest "unavailable"
  # value under the accounting contract, never guessed.
  cli_version_json="$(printf '%s' "${VERDICT_JSON:-null}" | jq -c '.cli_version // null' 2>/dev/null)" \
    || cli_version_json="null"
  # plan_auth: only recorded for a loop whose adapter actually ran to a
  # verdict — the adapters' own plan-auth gates (auth_mode=chatgpt /
  # apiProvider=firstParty) are what enforce it, so a completed verdict IS
  # the captured signal. A fallback loop records null (not captured).
  plan_auth_json="null"
  if [ -n "${VERDICT_JSON:-}" ] && [ "$vlabel" != "UNAVAILABLE" ]; then
    case "${ADAPTER:-}" in
      codex)  plan_auth_json='"chatgpt"' ;;
      claude) plan_auth_json='"firstParty"' ;;
    esac
  fi
  if [ "$fell_back" = "true" ] || [ "$fell_back" = true ]; then
    fc="$(jq -nc --arg reason "$fail_reason" --argjson dur "$elapsed_json" \
      '{happened: true, reason: (if $reason == "" then null else $reason end), duration_seconds: $dur}')" || return 1
  else
    fc='{"happened":false,"reason":null,"duration_seconds":null}'
  fi

  line="$(jq -nc \
    --argjson loopno "$loopno" \
    --arg reviewer "${REVIEWER:-unknown}" \
    --arg adapter "review-via-${ADAPTER:-unknown}.sh" \
    --arg direction "${DIRECTION:-unknown}" \
    --arg head "${HEAD:-unknown}" \
    --arg vlabel "$vlabel" \
    --arg posted "$posted" \
    --argjson fell_back "$( [ "$fell_back" = "true" ] || [ "$fell_back" = true ] && printf 'true' || printf 'false' )" \
    --argjson elapsed "$elapsed_json" \
    --argjson started "$started_json" \
    --argjson tokens "$tokens" \
    --argjson findings "$hist" \
    --argjson timeout "$timeout_json" \
    --argjson effort "$effort_json" \
    --argjson plan_auth "$plan_auth_json" \
    --argjson cli_version "$cli_version_json" \
    --argjson fc "$fc" \
    --argjson details "$details_json" '
    {
      schema: "p4b-loop-log/v1",
      started_at_epoch: $started,
      loop: {
        loop: $loopno,
        reviewer: $reviewer,
        adapter: $adapter,
        direction: $direction,
        head_sha: $head,
        verdict: $vlabel,
        posted: $posted,
        fell_back: $fell_back,
        elapsed_seconds: $elapsed,
        tokens: $tokens,
        findings: $findings,
        cli_version: $cli_version,
        timeout_seconds: $timeout,
        effort: $effort,
        throttle_events: null,
        plan_auth: $plan_auth,
        fail_closed: $fc
      },
      details: $details
    }')" || return 1
  printf '%s\n' "$line" >> "$log" || return 1
}

# p4b_acct_hook_note_fallback <why>
# Record a fail-closed loop from the orchestrator's manual-fallback path.
# An APPROVED-with-findings verdict keeps its parsed histogram/details (the
# verdict WAS parsed — the loop is real fail-closed evidence); every other
# fallback (a genuinely non-conformant or unavailable verdict) discards it as
# UNAVAILABLE.
#
# Required-tier preservation (#615 Codex round 7, finding 2): an APPROVED
# verdict carrying a REQUIRED-tier finding (P0/P1 by default, or P2/P3 under a
# stricter feedback_policy) is rejected by p4b_validate_verdict BEFORE the
# discretionary "approved verdict included findings" gate is reached, so the
# orchestrator reaches this hook with the generic reason "adapter returned a
# non-conformant verdict". Keying only off that reason string would drop the
# parsed severity counts/details of exactly the unsafe approval the gate
# prevented, underreporting the fail-closed loop. So the label is derived from
# the VERDICT itself, not the reason: if VERDICT_JSON cleanly parses as an
# APPROVED verdict carrying a non-empty findings array, record it as
# APPROVED_WITH_ADVISORIES so the histogram/details survive — regardless of
# which gate (required-tier or discretionary) rejected it. A truly malformed
# verdict does not parse as clean APPROVED-with-findings and falls through to
# UNAVAILABLE. The loop is still fell_back=true with a fail_closed marker, so it
# is NOT a real approval and does not violate the required-tier posting rule
# (p4b_acct_assert_no_required_with_approved excludes fail-closed-marked loops);
# the rejection behavior in the orchestrator is unchanged.
p4b_acct_hook_note_fallback() {
  local why="$1" vlabel="UNAVAILABLE"
  case "$why" in
    "approved verdict included findings"*) vlabel="APPROVED_WITH_ADVISORIES" ;;
    *)
      # Preserve an APPROVED-with-findings verdict rejected on a required-tier
      # (or any other) semantic. `jq -e` exits non-zero on a missing/malformed
      # verdict, so a non-parseable VERDICT_JSON leaves vlabel=UNAVAILABLE.
      if [ -n "${VERDICT_JSON:-}" ] \
         && printf '%s' "$VERDICT_JSON" \
              | jq -e '.verdict == "APPROVED" and ((.findings | type) == "array") and ((.findings | length) > 0)' \
              >/dev/null 2>&1; then
        vlabel="APPROVED_WITH_ADVISORIES"
      fi
      ;;
  esac
  p4b_acct_hook_record_loop "$vlabel" "not-posted" true "$why"
}

# p4b_acct_fetch_prior_records <owner/repo>
# Stateless GitHub-derived prior-record fetch (#615 Codex rounds 2+3): pull
# the review bodies of the most recently updated merged PRs via read-only
# `gh api graphql` — subscription/plan-safe, no reviewer CLI, no API key —
# and emit every embedded p4b-accounting:v1 record as JSONL via
# p4b_acct_extract_records.
#
# Pagination (#615 round 3): follows pageInfo.hasNextPage/endCursor across
# up to P4B_ACCT_PRIOR_SCAN_PAGES pages (default 4) of
# P4B_ACCT_PRIOR_SCAN_PRS PRs each (default 50, so up to 200 merged PRs by
# default). When history remains beyond the cap the scan is TRUNCATED and
# the caller must label the totals as a bounded window — never repo-wide.
#
# Nested review window (#615 round 4): each scanned PR contributes only its
# LAST 50 reviews, so a PR with a deeper review history could silently omit
# an older embedded record while the PR-level scan looked complete. The
# query now requests the nested reviews pageInfo.hasPreviousPage, and any
# PR whose review list is truncated makes the WHOLE scan window
# truncated=true (the round-3 honest-labeling path) — a deliberate choice
# over per-PR nested pagination: 50+ reviews on one PR is rare, and honest
# bounded-window labeling is acceptable where silent omission is not.
#
# The window is reported through globals (this function is invoked with an
# output redirect, not a subshell, so they persist):
#   P4B_ACCT_PRIOR_FETCH_SCANNED_PRS      merged PRs actually scanned
#   P4B_ACCT_PRIOR_FETCH_TRUNCATED        true|false (older history left)
#   P4B_ACCT_PRIOR_FETCH_SKIPPED_RECORDS  untrusted-author records skipped
#   P4B_ACCT_PRIOR_FETCH_REVIEW_TRUNCATED_PRS  scanned PRs whose review list
#                                              exceeded the nested window
#
# Trusted authors only (#615 round 3): the spec aggregates reviews by the
# registered `available_reviewers` identities. The query fetches each
# review's author.login and only bodies from those identities are
# extracted — a record fabricated by any other account is SKIPPED (counted
# in a diagnostics line, never aggregated). No registered reviewers ⇒
# fail-closed non-zero (records cannot be attributed).
#
# Bounded (#615 round 8, finding 2): each `gh api graphql` call is wrapped in
# p4b_acct_run_bounded with a per-call timeout (P4B_ACCT_FETCH_TIMEOUT, default
# 20s; 0 = unbounded) so a stalled network read cannot indefinitely delay the
# valid APPROVED post this fetch runs before. A timeout returns non-zero like
# any other API failure and degrades to the ledger-cache/unavailable path.
#
# Empty output with exit 0 is VALID (no prior records — the first-ever
# approval). Returns non-zero when the repo slug is unusable, gh is
# absent, no reviewers are registered, or any API call fails/TIMES OUT; the
# caller then falls back to the local ledger cache, which stays explicitly
# labeled ledger-cache (never presented as repo-wide). Testable via a
# PATH-shimmed gh.
p4b_acct_fetch_prior_records() {
  local repo="${1:-}" owner name per_page max_pages trusted fetch_timeout
  local page cursor resp page_records page_skipped page_rtrunc nodes has_next
  local records="" scanned=0 skipped=0 rtrunc=0
  local -a args
  P4B_ACCT_PRIOR_FETCH_SCANNED_PRS=0
  P4B_ACCT_PRIOR_FETCH_TRUNCATED=false
  # shellcheck disable=SC2034  # documented contract: read by callers/tests after the call
  P4B_ACCT_PRIOR_FETCH_SKIPPED_RECORDS=0
  # shellcheck disable=SC2034  # documented contract: read by callers/tests after the call
  P4B_ACCT_PRIOR_FETCH_REVIEW_TRUNCATED_PRS=0
  case "$repo" in
    */*) ;;
    *) return 1 ;;
  esac
  owner="${repo%%/*}"
  name="${repo#*/}"
  [ -n "$owner" ] && [ -n "$name" ] || return 1
  per_page="${P4B_ACCT_PRIOR_SCAN_PRS:-50}"
  case "$per_page" in ''|0*|*[!0-9]*) per_page=50 ;; esac
  max_pages="${P4B_ACCT_PRIOR_SCAN_PAGES:-4}"
  case "$max_pages" in ''|0*|*[!0-9]*) max_pages=4 ;; esac
  # Per-call network bound (#615 Codex round 8, finding 2): each read-only
  # `gh api graphql` call is time-boxed so a stalled/hung read degrades the
  # OPTIONAL fetch to the ledger-cache/unavailable path instead of indefinitely
  # delaying a valid APPROVED post. Default 20s; 0 opts out (unbounded).
  fetch_timeout="${P4B_ACCT_FETCH_TIMEOUT:-20}"
  case "$fetch_timeout" in ''|*[!0-9]*) fetch_timeout=20 ;; esac
  command -v gh >/dev/null 2>&1 || return 1
  trusted="$(p4b_acct_available_reviewers_json)"
  if [ -z "$trusted" ] || [ "$trusted" = "[]" ]; then
    p4b_acct_warn "no available_reviewers registered in review-policy.yml — prior records cannot be attributed to a trusted reviewer (fail-closed, #615 round 3)"
    return 1
  fi
  cursor=""
  page=0
  has_next=false
  while [ "$page" -lt "$max_pages" ]; do
    args=(-F owner="$owner" -F name="$name" -F prs="$per_page")
    [ -n "$cursor" ] && args+=(-f after="$cursor")
    resp="$(p4b_acct_run_bounded "$fetch_timeout" gh api graphql "${args[@]}" \
      -f query='query($owner: String!, $name: String!, $prs: Int!, $after: String) {
          repository(owner: $owner, name: $name) {
            pullRequests(states: MERGED, first: $prs, after: $after,
                         orderBy: {field: UPDATED_AT, direction: DESC}) {
              pageInfo { hasNextPage endCursor }
              nodes { reviews(last: 50) {
                pageInfo { hasPreviousPage }
                nodes { body author { login } } } }
            }
          }
        }' 2>/dev/null)" || return 1
    printf '%s' "$resp" | jq -e '
      .data.repository.pullRequests
      | (.nodes | type == "array") and (.pageInfo | type == "object")' \
      >/dev/null 2>&1 || return 1
    # Trusted-author bodies → records; untrusted marker-bearing bodies →
    # diagnostics counter only (skipped, never aggregated).
    page_records="$(printf '%s' "$resp" | jq -r --argjson trusted "$trusted" '
      .data.repository.pullRequests.nodes[].reviews.nodes[]
      | (.author.login // "") as $login
      | select(($trusted | index($login)) != null)
      | .body // empty' 2>/dev/null | p4b_acct_extract_records)" || return 1
    page_skipped="$(printf '%s' "$resp" | jq -r --argjson trusted "$trusted" '
      .data.repository.pullRequests.nodes[].reviews.nodes[]
      | (.author.login // "") as $login
      | select(($trusted | index($login)) == null)
      | .body // empty' 2>/dev/null | p4b_acct_extract_records | grep -c . || true)"
    case "$page_skipped" in ''|*[!0-9]*) page_skipped=0 ;; esac
    skipped=$((skipped + page_skipped))
    [ -n "$page_records" ] && records="${records}${page_records}
"
    nodes="$(printf '%s' "$resp" | jq -r \
      '.data.repository.pullRequests.nodes | length' 2>/dev/null)" || nodes=0
    case "$nodes" in ''|*[!0-9]*) nodes=0 ;; esac
    scanned=$((scanned + nodes))
    # Nested review truncation (#615 round 4): PRs whose review connection
    # holds more reviews than the nested last:50 window. Absent pageInfo
    # (older fixtures / defensive) counts as not-truncated.
    page_rtrunc="$(printf '%s' "$resp" | jq -r '
      [ .data.repository.pullRequests.nodes[]
        | select(.reviews.pageInfo.hasPreviousPage == true) ]
      | length' 2>/dev/null)" || page_rtrunc=0
    case "$page_rtrunc" in ''|*[!0-9]*) page_rtrunc=0 ;; esac
    rtrunc=$((rtrunc + page_rtrunc))
    has_next="$(printf '%s' "$resp" | jq -r \
      '.data.repository.pullRequests.pageInfo.hasNextPage // false' 2>/dev/null)" || has_next=false
    cursor="$(printf '%s' "$resp" | jq -r \
      '.data.repository.pullRequests.pageInfo.endCursor // empty' 2>/dev/null)" || cursor=""
    page=$((page + 1))
    [ "$has_next" = "true" ] || break
    # hasNextPage without a cursor cannot be followed — treated as truncated.
    [ -n "$cursor" ] || break
  done
  P4B_ACCT_PRIOR_FETCH_SCANNED_PRS="$scanned"
  # shellcheck disable=SC2034  # documented contract: read by callers/tests after the call
  P4B_ACCT_PRIOR_FETCH_SKIPPED_RECORDS="$skipped"
  P4B_ACCT_PRIOR_FETCH_REVIEW_TRUNCATED_PRS="$rtrunc"
  if [ "$has_next" = "true" ]; then
    P4B_ACCT_PRIOR_FETCH_TRUNCATED=true
    p4b_acct_warn "prior-record scan stopped at its page cap after $scanned merged PR(s) with older history remaining — totals will be labeled as a bounded window, not repo-wide (#615 round 3)"
  fi
  if [ "$rtrunc" -gt 0 ]; then
    P4B_ACCT_PRIOR_FETCH_TRUNCATED=true
    p4b_acct_warn "$rtrunc scanned PR(s) hold more reviews than the nested 50-review window — their older reviews (and any embedded records in them) were not scanned; totals will be labeled as a bounded window, not repo-wide (#615 round 4)"
  fi
  if [ "$skipped" -gt 0 ]; then
    p4b_acct_warn "skipped $skipped prior accounting record(s) embedded by unregistered review author(s) — diagnostics only, never aggregated (#615 round 3)"
  fi
  [ -n "$records" ] && printf '%s' "$records"
  return 0
}

# p4b_acct_hook_running_totals
# Resolve the running-totals object for the post (#615 Codex round 2). The
# real phase-4b-review.sh path never injected P4B_ACCT_PRIOR_RECORDS_JSONL,
# so totals always fell through to the gitignored per-checkout ledger — a
# fresh checkout reported unavailable/local-only even when prior PRs carried
# embedded records. Priority now:
#   1. An injected P4B_ACCT_PRIOR_RECORDS_JSONL (tests / callers that
#      already fetched) — unchanged.
#   2. The GitHub-derived fetch above (stateless). The fetch's scan window
#      (#615 round 3) is attached as .window {scanned_prs, truncated} so
#      the renderer claims repo-wide ONLY when the scan saw the full
#      history and labels a cap-truncated scan as a bounded window.
#   3. On fetch failure: the local ledger cache, EXPLICITLY labeled
#      ledger-cache — or unavailable with the fetch-failed reason. Never
#      silently presented as repo-wide.
p4b_acct_hook_running_totals() {
  local ledger fetched rt rt_w
  ledger="$(p4b_acct_hook_ledger)"
  if [ -n "${P4B_ACCT_PRIOR_RECORDS_JSONL:-}" ]; then
    p4b_acct_running_totals_for_post "$ledger"
    return 0
  fi
  if ! fetched="$(mktemp "${TMPDIR:-/tmp}/p4b-prior.XXXXXX")"; then
    p4b_acct_running_totals_for_post "$ledger"
    return 0
  fi
  # stdout only is redirected (no subshell), so the fetch's window/skip
  # globals persist and its diagnostics lines still reach stderr.
  if p4b_acct_fetch_prior_records "${REPO:-}" > "$fetched"; then
    rt="$(P4B_ACCT_PRIOR_RECORDS_JSONL="$fetched" \
      P4B_ACCT_PRIOR_RECORDS_SOURCE="github-derived" \
      p4b_acct_running_totals_for_post "$ledger")"
    rm -f "$fetched" 2>/dev/null || true
    rt_w="$(printf '%s' "$rt" | jq -c \
      --argjson scanned "${P4B_ACCT_PRIOR_FETCH_SCANNED_PRS:-0}" \
      --argjson trunc "${P4B_ACCT_PRIOR_FETCH_TRUNCATED:-false}" \
      --argjson rtrunc "${P4B_ACCT_PRIOR_FETCH_REVIEW_TRUNCATED_PRS:-0}" '
      if .source == "github-derived"
      then . + {window: {scanned_prs: $scanned, truncated: $trunc,
                         review_truncated_prs: $rtrunc}}
      else . end' 2>/dev/null)" || rt_w=""
    if [ -n "$rt_w" ]; then printf '%s' "$rt_w"; else printf '%s' "$rt"; fi
    return 0
  fi
  rm -f "$fetched" 2>/dev/null || true
  p4b_acct_warn "GitHub prior-record fetch failed; running totals fall back to the local ledger cache (labeled ledger-cache/unavailable, never repo-wide)"
  if [ -r "$ledger" ]; then
    p4b_acct_aggregate_running_totals "ledger-cache" < "$ledger"
    return 0
  fi
  jq -nc '{source:"unavailable", records:0,
           reason:"GitHub prior-record fetch failed and no local ledger cache exists"}'
}

# p4b_acct_hook_render_approval_block
# Assemble + render the accounting block for the current APPROVED verdict
# from the accumulated loop log. Prints the markdown block on stdout; returns
# non-zero on ANY failure (the orchestrator then posts the plain summary).
# On a live (non-dry-run) run the finished record is STAGED (two-phase
# commit, #615 Codex); the orchestrator appends it to the ledger cache via
# p4b_acct_hook_commit_posted_record only after the review actually posts.
# P4B_ACCT_SELFTEST_FAIL=1 is a test seam that forces the failure path.
p4b_acct_hook_render_approval_block() {
  if [ "${P4B_ACCT_SELFTEST_FAIL:-0}" = "1" ]; then
    p4b_acct_warn "P4B_ACCT_SELFTEST_FAIL=1 — forcing report-generation failure (test seam)"
    return 1
  fi
  local log loops details uf ptv notional totals running astate wall
  local first_started record block
  log="$(p4b_acct_hook_loop_log)"
  [ -r "$log" ] || return 1
  loops="$(jq -cs '[ .[] | .loop ]' "$log" 2>/dev/null)" || return 1
  [ -n "$loops" ] && [ "$loops" != "[]" ] || return 1
  details="$(jq -c '.details[]?' "$log" 2>/dev/null)" || return 1
  uf="$(printf '%s\n' "$details" | p4b_acct_unique_findings "${P4B_ACCT_DISPOSITIONS_JSON:-}" "${P4B_ACCT_FILED_ISSUES_JSON:-}")" || return 1
  [ -n "$uf" ] || return 1
  ptv="$(p4b_acct_price_table_version)"
  if ! notional="$(p4b_acct_notional_for_loops "$loops")"; then
    notional="null"
  fi
  totals="$(p4b_acct_compute_totals "$loops" "$ptv" "$notional" "$uf" "${P4B_ACCT_FILED_ISSUES_JSON:-[]}")" || return 1
  [ -n "$totals" ] || return 1
  # GitHub-derived prior records are fetched here (#615 Codex round 2) so
  # the rendered totals are repo-wide by default, not local-ledger-only.
  running="$(p4b_acct_hook_running_totals)" || return 1
  [ -n "$running" ] || return 1
  if [ "${DRY_RUN:-false}" = true ]; then astate="dry-run"; else astate="posted"; fi
  wall=""
  first_started="$(jq -s '[ .[] | .started_at_epoch | select(. != null) ] | min' "$log" 2>/dev/null || true)"
  if [ -n "$first_started" ] && [ "$first_started" != "null" ]; then
    wall="$(( $(date +%s) - first_started ))"
    [ "$wall" -ge 0 ] 2>/dev/null || wall=""
  fi
  record="$(p4b_acct_build_record "${PR:-0}" "${HEAD:-unknown}" "APPROVED" \
    "${REVIEWER:-unknown}" "${DIRECTION:-unknown}" "$astate" "$wall" \
    "$loops" "$uf" "$totals" "$running" "")" || return 1
  block="$(p4b_acct_render_block "$record")" || return 1
  [ -n "$block" ] || return 1
  # Two-phase ledger commit (#615 Codex): stage the record now; the
  # orchestrator commits it only after the review POST succeeds. Any prior
  # staging leftover (e.g. a crashed run) is dropped first so a later commit
  # can never append a record from a different invocation. The record is
  # tagged with THIS invocation's run id (sidecar) so commit-time can prove
  # ownership even when the fail-open path skips re-staging (#615 round 6).
  p4b_acct_hook_discard_pending_record
  if [ "$astate" = "posted" ]; then
    local pending runid_file
    pending="$(p4b_acct_hook_pending_record_path)"
    runid_file="$(p4b_acct_hook_pending_runid_path)"
    # Advisory: a staging failure must not lose the block. Stage the record
    # THEN its run-id sidecar; a sidecar without a record (or vice versa)
    # fails the commit-time ownership check and is discarded, never committed.
    if ! { mkdir -p "$(dirname "$pending")" \
             && printf '%s\n' "$record" > "$pending" \
             && printf '%s' "$(p4b_acct_run_id)" > "$runid_file"; } 2>/dev/null; then
      p4b_acct_warn "could not stage the record for the ledger cache (future running totals may lag)"
    fi
  fi
  printf '%s' "$block"
}

# p4b_acct_hook_same_head_required_block — SAFETY gate (not advisory).
#
# Fail-closed check the orchestrator runs BEFORE posting an APPROVED review
# (#615 Codex round 9, finding 2). The record builder's
# p4b_acct_assert_no_required_with_approved already refuses to BUILD an
# accounting record whose loop history laundered a same-head required finding,
# but that failure was caught as an ordinary advisory report-generation failure
# and the orchestrator still posted the plain-summary APPROVED — the fail-closed
# invariant lived only in the accounting record, never in the approval decision.
# This hook exposes the SAME assertion, keyed to the CURRENT head, so the
# orchestrator can refuse the approval itself.
#
# Reads the live per-PR loop log (the current loop is USUALLY present —
# appended by p4b_acct_hook_record_loop before this call — but can be
# legitimately ABSENT when that append failed; the orchestrator still runs
# this gate on its not-recorded path), extracts the full loop objects, and
# runs the assertion in same_head_only mode for an APPROVED verdict on the
# current HEAD. same_head_only matters (#615 round 9, CodeRabbit): the
# full-mode record clauses (at least one clean APPROVED loop; no
# findings-bearing approved loop anywhere in history) are record-scoped and
# would refuse a VALID head-advanced approval whenever the current loop is
# absent from the log; the laundering block this gate exists for is exactly
# the same-head clause. Returns:
#   0  — safe to post the approval (no same-head unresolved required finding, or
#        no readable/parseable loop log to check).
#   1  — a same-head unresolved required finding is present; the approval MUST
#        be refused (fail closed).
# A missing/empty/unparseable loop log returns 0: this gate never fabricates a
# block from the absence of history — the assertion is only meaningful with a
# loop log, and a genuinely first-ever clean approval has none. The orchestrator
# calls this ONLY on the APPROVED path; other verdicts do not post an approval.
p4b_acct_hook_same_head_required_block() {
  local log loops
  log="$(p4b_acct_hook_loop_log)" || return 0
  [ -r "$log" ] || return 0
  loops="$(jq -cs '[ .[] | .loop ]' "$log" 2>/dev/null)" || return 0
  [ -n "$loops" ] && [ "$loops" != "[]" ] || return 0
  # assert returns 0 when SAFE, non-zero when the same-head required finding
  # would be laundered. Invert: report 1 (block) exactly when the assertion
  # refuses. A jq/assertion internal error also returns non-zero from assert;
  # fail closed on it too (an unverifiable history blocks the approval).
  if p4b_acct_assert_no_required_with_approved "APPROVED" "$loops" "${HEAD:-}" same_head_only; then
    return 0
  fi
  return 1
}
