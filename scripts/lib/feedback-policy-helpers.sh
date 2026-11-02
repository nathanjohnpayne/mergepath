# scripts/lib/feedback-policy-helpers.sh
#
# Shared reader + classifiers for the `feedback_policy` block in
# .github/review-policy.yml (nathanjohnpayne/mergepath#574, sub-issue #576).
#
# `feedback_policy` controls WHICH bot-review findings must be dispositioned
# (fixed OR rebutted + thread resolved) before merge, by normalized severity
# tier. This file is the single source of truth that both severity gates
# (scripts/codex-p1-gate.sh and the #577 scripts/coderabbit-severity-gate.sh)
# and the wait/request helpers consult, so the tier vocabulary and the
# blocking-set resolution cannot drift between them.
#
# NOTE: this is the FOUNDATION (#576). It ships the readers + classifiers and
# unit tests; nothing consumes them to BLOCK a merge yet — the gates that act
# on `resolve_required_tiers` land in #577. So sourcing this file is inert.
#
# Sourcing contract: NO top-level side effects, only function defs.
# Bash 3.2 portable (no mapfile, no associative arrays). Pure awk/sed/grep —
# no yq, no gh, no network. Fail closed.
#
#   source scripts/lib/feedback-policy-helpers.sh
#   feedback_policy_field <key> [cfg]      # scalar under feedback_policy:
#   resolve_required_tiers [cfg]           # one blocking tier per line
#   resolve_tiers_by_disposition <required|discretionary|ignore> [cfg]
#                                         # one disposition tier per line
#   codex_tier_of "<comment-body>"         # p0..p3 or empty
#   codex_tiers_of "<comment-body>"        # every p0..p3 marker, in order
#   coderabbit_tier_of "<comment-body>"    # p0..p3|nitpick or empty
#   coderabbit_tiers_of "<comment-body>"   # every graded marker, in order
#     Both CodeRabbit tier readers return 2, with no output, on extraction error.
#   coderabbit_finding_scan "<body>"       # strip fenced/pre-merge regions
#   ghas_severity_tier "<security_severity_level>"  # p0..p3 or empty (#1101)
#   ghas_alert_number_from_body "<comment-body>"     # alert number or empty (#1113)
#   read_policy_block_field <block> <field> [cfg]    # scalar under an arbitrary top-level block
#
# cfg defaults to $CONFIG (the global the gate scripts set) and then to
# .github/review-policy.yml, matching scripts/lib/reviewers-helpers.sh.
#
# The normalized ladder (see REVIEW_POLICY.md § Feedback Disposition Policy):
#   p0  critical   p1  high   p2  minor   p3  trivial   nitpick  style
# Codex maps EXACTLY (badge markers); CodeRabbit maps HEURISTICALLY (category
# + Critical/Major/Minor qualifier — it has no numeric scale).

# Read a scalar field directly under the feedback_policy: block. Mirrors the
# block-scoped awk reader used by codex_field (scripts/codex-p1-gate.sh) and
# the sed normalization used by read_available_reviewers
# (scripts/lib/reviewers-helpers.sh): strip the `key:` prefix in awk, then
# strip a trailing inline comment, surrounding quotes (single OR double), and
# trailing whitespace in sed. Every key under feedback_policy: is unique
# (mode, priorities, p0..p3, nitpick), so an exact-name match is unambiguous.
feedback_policy_field() (
  local field=$1 cfg="${2:-${CONFIG:-.github/review-policy.yml}}"
  [ -f "$cfg" ] || return 0
  set -o pipefail
  awk -v field="$field" '
    /^feedback_policy:/ {in_block=1; next}
    in_block && /^[^[:space:]#]/ {in_block=0}
    in_block && $1 == field":" {
      sub(/^[[:space:]]*[^:]+:[[:space:]]*/, "", $0)
      print
      exit
    }
  ' "$cfg" | sed -E "s/[[:space:]]+#.*$//; s/^[\"']//; s/[\"'][[:space:]]*$//; s/[[:space:]]+$//"
)


# policy_yaml_to_json <path> -- parse a review-policy YAML file to JSON on
# stdout; non-zero and empty on any failure. This is THE one parser
# review-feedback-accounting.sh's validate_governing_policy uses (it adds its
# own schema validation on top), extracted here (Codex P2, PR #1124) so a
# second caller cannot drift from it. The earlier line-oriented awk reader
# below could not see flow-style YAML at all -- `code_scanning: {bot_login:
# "custom-ghas[bot]"}` returned empty -- so accounting recognized a consumer's
# custom GHAS bot while the fingerprint and the archive workflow silently fell
# back to the default login. Two readers of the same file is the bug; this is
# the shared one.
policy_yaml_to_json() {
  local cfg="${1:-}" docs json
  [ -r "$cfg" ] || return 1
  if command -v yq >/dev/null 2>&1 \
     && yq --version 2>/dev/null | grep -qi 'mikefarah'; then
    # shellcheck disable=SC2016 # $d belongs to yq, not the shell.
    docs=$(yq eval-all -o=json '[.] as $d ireduce ([]; . + $d) | length' "$cfg" 2>/dev/null) || return 1
    [ "$docs" = 1 ] || return 1
    json=$(yq eval -o=json '.' "$cfg" 2>/dev/null) || return 1
    printf '%s\n' "$json"
  elif command -v python3 >/dev/null 2>&1 \
       && python3 -c 'import yaml' >/dev/null 2>&1; then
    python3 -c '
import json, sys, yaml
with open(sys.argv[1], encoding="utf-8") as source:
    print(json.dumps(yaml.safe_load(source)))
' "$cfg" 2>/dev/null || return 1
  elif command -v ruby >/dev/null 2>&1; then
    ruby -ryaml -rjson -e '
source = File.read(ARGV[0])
raise "multiple YAML documents" if YAML.parse_stream(source).children.length > 1
value = YAML.safe_load(source, permitted_classes: [], permitted_symbols: [], aliases: false)
puts JSON.generate(value)
' "$cfg" 2>/dev/null || return 1
  else
    return 1
  fi
}

# policy_json_field <policy-json> <dotted.path> <kind> -- read one field of a
# policy already parsed by policy_yaml_to_json (#2901, #2913). It replaces the
# line-oriented awk readers, which matched only an unquoted, block-style
# `field:` key: a quoted key or a flow mapping (`codex: {enabled: false}`) read
# as unset there and took the default. Prints the value, or nothing when the
# key or an enclosing block is absent (`block:` with no value counts as
# absent); the caller applies its default only then. Returns 1 with a reason
# on stderr when the policy is not a mapping, an enclosing block is not a
# mapping, or the value is not of <kind>:
#   bool    true/false, or the quoted strings "true"/"false"
#   int     a non-negative integer, or a quoted string of digits
#   string  a non-empty one-line string
#   scalar  any one-line string, number or boolean (the caller validates)
# Only the named path matches, so a nested p1_gate.enabled can never stand in
# for codex.enabled. A null value is present but of no kind, so it refuses.
policy_json_field() {
  local json="${1:-}" path="$2" kind="$3" result
  if [ -z "$json" ]; then
    echo "ERROR: governing policy was not parsed; cannot read $path" >&2
    return 1
  fi
  # One line out: "ok <value>" or "err <reason>". A jq failure leaves it empty.
  result=$(printf '%s' "$json" | jq -r --arg p "$path" --arg k "$kind" '
    def want: {bool: "true|false", int: "a non-negative integer",
               scalar: "a one-line scalar"}[$k] // "a non-empty string";
    def bad: "err \($p) must be \(want); got \(tojson)";
    def one_line: test("[\n\r]") | not;
    def check:
      if $k == "bool" then
        if type == "boolean" then "ok \(.)" elif . == "true" or . == "false" then "ok \(.)" else bad end
      elif $k == "int" then
        if type == "number" and . >= 0 and floor == . then "ok \(.)"
        elif type == "string" and test("^[0-9]+$") then "ok \(.)" else bad end
      elif $k == "scalar" then
        if type == "boolean" or type == "number" then "ok \(.)"
        elif type == "string" and one_line then "ok \(.)" else bad end
      elif type == "string" and length > 0 and one_line then "ok \(.)"
      else bad end;
    # Walk the path; $seen is the dotted prefix already entered.
    def walk_to($keys; $seen):
      if ($keys | length) == 0 then check
      elif type != "object" then
        if $seen == "" then "err the governing policy is not a mapping"
        else "err \($seen) must be a mapping; got \(tojson)" end
      elif has($keys[0]) | not then "ok "
      elif ($keys | length) > 1 and .[$keys[0]] == null then "ok "
      else .[$keys[0]] | walk_to($keys[1:];
             (if $seen == "" then $keys[0] else "\($seen).\($keys[0])" end)) end;
    walk_to($p | split("."); "")' 2>/dev/null) || result=""
  case "$result" in
    "ok "*) printf '%s\n' "${result#ok }" ;;
    "err "*) echo "ERROR: ${result#err }" >&2; return 1 ;;
    *) echo "ERROR: $path could not be read from the governing policy" >&2; return 1 ;;
  esac
}

# policy_block_field_parsed <block> <field> [config] -- read one block field
# through policy_yaml_to_json, so block AND flow style both resolve. Empty
# (rc 1) when the file is unreadable or no YAML parser exists, which callers
# must treat as "unknown", NOT as "unset" -- see the fingerprint's use.
policy_block_field_parsed() {
  local block="$1" field="$2" cfg="${3:-${CONFIG:-.github/review-policy.yml}}" json=""
  json="$(policy_yaml_to_json "$cfg")" || return 1
  [ -n "$json" ] || return 1
  printf '%s' "$json" | jq -r --arg b "$block" --arg f "$field" '.[$b][$f] // empty'
}

# Same reader, parameterized on an ARBITRARY top-level block (not only
# feedback_policy:) -- e.g. `read_policy_block_field code_scanning
# bot_login` (#1124). Deliberately untrusted / not base-materialized: a
# caller that needs the same trust guarantees review-feedback-accounting.sh
# gives its OWN policy reads (governing the PR's exact base SHA, for a
# merge-safety decision) must resolve $CONFIG itself before sourcing this,
# same as that script already does. A caller that only needs a best-effort
# hint (e.g. an additional login to widen a scan, never to narrow one) can
# use this directly against whatever checkout it has.
read_policy_block_field() {
  local block=$1 field=$2 cfg="${3:-${CONFIG:-.github/review-policy.yml}}"
  [ -f "$cfg" ] || return 0
  awk -v block="$block" -v field="$field" '
    $0 ~ "^"block":[[:space:]]*(#.*)?$" {in_block=1; next}
    in_block && /^[^[:space:]#]/ {in_block=0}
    in_block && $1 == field":" {
      sub(/^[[:space:]]*[^:]+:[[:space:]]*/, "", $0)
      print
      exit
    }
  ' "$cfg" | sed -E "s/[[:space:]]+#.*$//; s/^[\"']//; s/[\"'][[:space:]]*$//; s/[[:space:]]+$//"
}

# Emit the gate's BLOCKING tier set, one tier per line.
#
#   feedback_policy block ABSENT  -> "p1" only. This preserves today's
#       gate behavior byte-for-byte: before #574 the only enforced tier was
#       Codex P1 (scripts/codex-p1-gate.sh). Disposition DEFAULTS (p0/p1
#       required for the agent) are a separate, prose-level concept; this
#       function is specifically the merge-gate blocking set.
#   mode: address-all             -> every tier (p0 p1 p2 p3 nitpick).
#   mode: by-priority (default)   -> the tiers whose value is `required`.
#
# A present block with `by-priority` and a tier left unset treats that tier as
# discretionary (not required) — an explicit block is an explicit opt-in.
# Fails closed (return 2) on a malformed mode or tier value.
resolve_required_tiers() {
  local cfg="${1:-${CONFIG:-.github/review-policy.yml}}"
  if [ ! -f "$cfg" ] || ! grep -qE '^feedback_policy:' "$cfg"; then
    echo p1
    return 0
  fi

  local mode tier val
  mode=$(feedback_policy_field mode "$cfg")
  mode=${mode:-by-priority}

  case "$mode" in
    address-all)
      printf '%s\n' p0 p1 p2 p3 nitpick
      ;;
    by-priority)
      for tier in p0 p1 p2 p3 nitpick; do
        val=$(feedback_policy_field "$tier" "$cfg")
        case "$val" in
          ""|required|discretionary|ignore) ;;
          *)
            echo "ERROR: feedback_policy.priorities.$tier must be required|discretionary|ignore; got '$val'" >&2
            return 2
            ;;
        esac
        [ "$val" = required ] && echo "$tier"
      done
      ;;
    *)
      echo "ERROR: feedback_policy.mode must be by-priority|address-all; got '$mode'" >&2
      return 2
      ;;
  esac
}

# Emit the DISPOSITION tier set, one tier per line (#1672).
# Unlike resolve_required_tiers (the legacy gate blocking set), an absent
# block uses agent defaults: p0/p1 required, p2/p3/nitpick discretionary.
# Present blocks share its modes and scalar validation: address-all ignores
# priorities; by-priority treats an unset tier as discretionary. Validate the
# entire applicable policy before printing, so errors return 2 with no output.
resolve_tiers_by_disposition() {
  local disposition="${1:-}" cfg="${2:-${CONFIG:-.github/review-policy.yml}}" block_rc=0
  case "$disposition" in
    required|discretionary|ignore) ;;
    *)
      echo "ERROR: disposition must be required|discretionary|ignore; got '$disposition'" >&2
      return 2
      ;;
  esac
  if [ ! -f "$cfg" ]; then
    block_rc=1
  elif grep -qE '^feedback_policy:' "$cfg"; then
    block_rc=0
  else
    block_rc=$?
  fi
  if [ "$block_rc" -gt 1 ]; then
    echo "ERROR: could not read feedback policy: $cfg" >&2
    return 2
  fi
  if [ "$block_rc" -eq 1 ]; then
    case "$disposition" in
      required) printf '%s\n' p0 p1 ;;
      discretionary) printf '%s\n' p2 p3 nitpick ;;
    esac
    return 0
  fi

  local mode tier val selected=""
  mode=$(feedback_policy_field mode "$cfg") || return 2
  mode=${mode:-by-priority}
  case "$mode" in
    address-all)
      if [ "$disposition" = required ]; then
        printf '%s\n' p0 p1 p2 p3 nitpick
      fi
      ;;
    by-priority)
      for tier in p0 p1 p2 p3 nitpick; do
        val=$(feedback_policy_field "$tier" "$cfg") || return 2
        val=${val:-discretionary}
        case "$val" in
          required|discretionary|ignore) ;;
          *)
            echo "ERROR: feedback_policy.priorities.$tier must be required|discretionary|ignore; got '$val'" >&2
            return 2
            ;;
        esac
        if [ "$val" = "$disposition" ]; then
          selected="${selected}${tier}"$'\n'
        fi
      done
      printf '%s' "$selected"
      ;;
    *)
      echo "ERROR: feedback_policy.mode must be by-priority|address-all; got '$mode'" >&2
      return 2
      ;;
  esac
  return 0
}

# Map a Codex finding body to a tier, or empty if it carries no Codex priority
# marker. Matches the badge image `![P0 Badge]`..`![P3 Badge]` (the form
# scripts/codex-p1-gate.sh and scripts/codex-record-feedback.sh already parse)
# and the text fallback `**P0`..`**P3` Codex emits when the badge image is
# absent. The FIRST marker in document order wins across BOTH forms — a
# blocking P1 must not be downgraded by a later P2/P3 in quoted/example text
# (nathanpayne-codex Phase 4b on #581). `codex_tiers_of` exposes the same
# canonical markers in document order for callers that intentionally model a
# compound top-level body.
codex_tiers_of() {
  local body=${1:-} markers marker n
  markers=$(printf '%s' "$body" | grep -oE '!\[P[0-3] Badge\]|\*\*P[0-3]' || true)
  while IFS= read -r marker; do
    [ -n "$marker" ] || continue
    n=$(printf '%s' "$marker" | sed -E 's/.*P([0-3]).*/\1/')
    echo "p$n"
  done <<EOF
$markers
EOF
}

codex_tier_of() {
  local tiers
  # Keep the single-finding contract: the first marker wins. The all-marker
  # primitive above exists for compound top-level review surfaces.
  tiers=$(codex_tiers_of "${1:-}")
  [ -n "$tiers" ] || return 0
  printf '%s\n' "$tiers" | sed -n '1p'
}

# Map a CodeRabbit finding body to a tier, or empty if it is not a gradeable
# finding (a plain Note / prose comment). CodeRabbit has no numeric scale, so
# we read its category/severity MARKERS.
#
# Derived from classify_severity in scripts/lib/daily-feedback-rollup-helpers.sh
# (the repo's canonical CodeRabbit badge parser) but STRICTER: it matches ONLY
# the actual markers — the emoji badges and the distinctive "Potential issue" /
# "Outside diff range" category phrases — and DROPS classify_severity's
# bare-titlecase fallbacks. A bare `Minor`/`Trivial`/`Nitpick` word in plain
# prose must NOT be classified, per this helper's contract that unknown/
# plain-note shapes stay unclassified (nathanpayne-codex Phase 4b P1 on #581: a
# bare-word match would let the #577 gate block/clear the wrong tier, and a
# Minor badge whose prose says "Trivial" must stay p2). Anchored on the first
# 600 chars (the marker sits near the top), ordered highest-confidence first.
#
# CodeRabbit markers → tier (p0 is Codex-only; CodeRabbit never maps to p0):
#   🟠 Major / Potential issue / ⚠️  → p1
#   🧹 Nitpick                                     → nitpick
#   🔵 Trivial / Outside diff range                → p3
#   🟡 Minor                                       → p2
# Anything else (Refactor suggestion, plain Note, bare titlecase prose) → empty.
#
# CodeRabbit's other machine-readable signal — the `cr-indicator-types` tag it
# appends to a finding body — is deliberately NOT graded here. Grading it needs
# a definition of where one finding's stanza ends, because CodeRabbit renders a
# finding's badge and its tag on different lines and both merge-relevant
# callers grade a PR-level summary line by line; four successive framings of
# that boundary produced four defects on #936. It is [#945](https://github.com/nathanjohnpayne/mergepath/issues/945),
# with a spec-derived matrix, and #888 stays open for it.
coderabbit_finding_scan() {
  local body=${1:-} out
  out=$(printf '%s\n' "$body" | awk \
    -v block_start='<!-- pre_merge_checks_walkthrough_start -->' \
    -v block_end='<!-- pre_merge_checks_walkthrough_end -->' '
      function fence_info(s, out,   c, n) {
        sub(/^ ? ? ?/, "", s)
        c = substr(s, 1, 1)
        if (c != "`" && c != "~") return 0
        n = 0
        while (substr(s, n + 1, 1) == c) n++
        if (n < 3) return 0
        out["rest"] = substr(s, n + 1)
        if (c == "`" && index(out["rest"], "`") > 0) return 0
        out["char"] = c
        out["len"] = n
        return 1
      }
      function fence_update(line,   info) {
        if (!fence_info(line, info)) return 0
        if (!in_fence) {
          in_fence = 1
          fence_char = info["char"]
          fence_len = info["len"]
          return 1
        }
        if (info["char"] == fence_char && info["len"] >= fence_len \
            && info["rest"] ~ /^[ \t]*$/) {
          in_fence = 0
          fence_char = ""
          fence_len = 0
        }
        return 1
      }
      {
        line = $0
        sub(/\r$/, "", line)
        lines[NR] = line
        delimiter = fence_update(line)
        visible[NR] = (!delimiter && !in_fence)
        structural = line
        sub(/[ \t]+$/, "", structural)
        # Pair the block on the NEWEST start seen before the end, not the
        # oldest. Anchoring on the first start (the old "&& !start_line")
        # let an unmatched start earlier in the body swallow everything up to
        # a LATER, properly paired block: a real Major badge sitting between
        # the two was suppressed, and the inventory then reported clear with
        # nothing to disposition (#1000 Codex P1). An unpaired start is not a
        # block, so it must not extend one; re-anchoring keeps the intervening
        # text classified. Still at most one suppressed region per body -- only
        # the first properly closed pair is dropped -- so this can never
        # suppress more than the previous rule did.
        if (visible[NR] && structural == block_start && !end_line) {
          pending_start = NR
        } else if (visible[NR] && structural == block_end \
                   && pending_start && !end_line) {
          start_line = pending_start
          end_line = NR
          pending_start = 0
        }
      }
      END {
        # A commanded CodeRabbit review can answer with provider state rather
        # than reviewer feedback. Its exact "Action not completed" summary
        # carries the same warning glyph the tier ladder grades p1, so omit
        # only that one line when it follows a visible, nonempty command-
        # invocation marker (#1050). Find the pair only after resolving the
        # pre-merge exclusion above: a marker inside any excluded region must
        # not authorize suppressing a visible line elsewhere. Do not remove
        # the surrounding details block; a mixed body can still carry a real
        # severity badge there and must fail toward classification.
        for (i = 1; i <= NR; i++) {
          if (!visible[i]) continue
          if (end_line && i >= start_line && i <= end_line) continue
          structural = lines[i]
          sub(/[ \t]+$/, "", structural)
          if (!invocation_line \
              && structural ~ /^<!-- CodeRabbit review command invocation: [^[:space:]<>][^<>]* -->$/) {
            invocation_line = i
          } else if (invocation_line && !status_summary_line \
                     && structural == "<summary>⚠️ Action not completed</summary>") {
            status_summary_line = i
          }
        }
        for (i = 1; i <= NR; i++) {
          if (!visible[i]) continue
          if (end_line && i >= start_line && i <= end_line) continue
          if (status_summary_line && i == status_summary_line) continue
          print lines[i]
        }
      }
    ') || {
      echo "ERROR: could not sanitize a CodeRabbit finding surface" >&2
      return 2
    }
  if [ -n "$out" ]; then
    printf '%s\n' "$out"
  fi
}

coderabbit_tiers_of() {
  local body=${1:-} markers marker rc=0
  # Outside-diff section headings carry both a warning glyph and a category
  # phrase, but the nested comment supplies the actual severity (#1407).
  # Exclude only complete known heading lines, including their blockquote
  # presentation. Keep this at the shared extraction boundary: callers grade
  # either whole bodies or numbered lines, and retain their original text for
  # fingerprints and reporting. Extra finding text on a heading line must not
  # disappear along with its structural markers.
  #
  # The `⚠️ **Unverified finding**` status banner (#2560) is excluded on the
  # same terms: CodeRabbit prefixes a finding it could not verify with it, and
  # the banner states a verification status, not a severity, while its bare
  # glyph matched the p1 marker and promoted a 🟡 Minor finding to a required
  # p1. Only the complete banner line is dropped, so a `⚠️ Potential issue`
  # under it still grades p1 and a banner sharing its line with other text
  # stays classified.
  body=$(printf '%s\n' "$body" | awk '
    {
      heading = $0
      sub(/\r$/, "", heading)
      sub(/^[ \t]*(>[ \t]*)*/, "", heading)
      sub(/[ \t]+$/, "", heading)
      if (heading ~ /^\*\*(⚠️ )?Outside diff range comments \([0-9]+\)\*\*$/ \
          || heading ~ /^<summary>(⚠️ )?Outside diff range comments \([0-9]+\)<\/summary>(<blockquote>)?$/ \
          || heading ~ /^(\*\*)?⚠️ (\*\*)?Unverified finding(\*\*)?$/) next
      print
    }
  ') || {
    echo "ERROR: could not read CodeRabbit section headings" >&2
    return 2
  }
  markers=$(grep -oE '🟠 Major|Potential issue|⚠️|🧹 Nitpick|🔵 Trivial|Outside diff range|🟡 Minor' <<<"$body") || rc=$?
  case "$rc" in
    0) ;;
    1) return 0 ;;
    *) echo "ERROR: could not classify CodeRabbit tier evidence" >&2; return 2 ;;
  esac
  while IFS= read -r marker; do
    case "$marker" in
      "🟠 Major"|"Potential issue"|"⚠️") echo p1 ;;
      "🟡 Minor") echo p2 ;;
      "🔵 Trivial"|"Outside diff range") echo p3 ;;
      "🧹 Nitpick") echo nitpick ;;
    esac
  done <<EOF
$markers
EOF
}

coderabbit_tier_of() {
  local head tiers wanted
  # Truncate via parameter expansion (not `printf | head -c`): under
  # `set -euo pipefail` a large body makes head close the pipe early and
  # printf exits 141 (SIGPIPE), which aborts every caller. The badge markers
  # matched below are near the start, so a 600-char cut is more than enough.
  head="${1:-}"; head="${head:0:600}"
  tiers=$(coderabbit_tiers_of "$head") || return 2
  for wanted in p1 nitpick p3 p2; do
    case $'\n'"$tiers"$'\n' in
      *$'\n'"$wanted"$'\n'*) echo "$wanted"; return 0 ;;
    esac
  done
  return 0
}

# Map a GitHub code-scanning alert's `rule.security_severity_level` value
# (nathanjohnpayne/mergepath#1101) to the shared p0-p3 ladder, or empty for
# an unrecognized/absent value. A code-scanning inline PR comment carries no
# severity of its own — only a link to the alert — so unlike codex_tier_of /
# coderabbit_tier_of (which parse a comment BODY), the caller resolves the
# severity STRING itself via the `code-scanning/alerts` API and hands it
# here. This keeps the network fetch in the caller (review-feedback-
# accounting.sh already talks to the GitHub API) and this file's "no gh, no
# network" sourcing contract intact — this function only maps a value it is
# given.
#
#   critical -> p0   high -> p1   medium -> p2   low -> p3
#
# GHAS never maps to `nitpick` (that tier is CodeRabbit-only) and an
# unrecognized level (including `none`, which GitHub uses for rules with no
# CVSS-derived severity) returns empty; the caller decides the fail-open-vs-
# closed default for that case, matching every other classifier in this file.
ghas_severity_tier() {
  case "${1:-}" in
    critical) echo p0 ;;
    high) echo p1 ;;
    medium) echo p2 ;;
    low) echo p3 ;;
    *) return 0 ;;
  esac
}

# Pure regex extraction of the code-scanning alert number a
# github-advanced-security[bot] comment body links to (the
# "[Show more details](.../security/code-scanning/<number>)" line every such
# comment carries), or empty if none is found. No I/O — the caller resolves
# the number to a severity via scripts/lib/ghas-alert-severity.sh
# (nathanjohnpayne/mergepath#1113), which needs the network access this file's
# sourcing contract excludes.
ghas_alert_number_from_body() {
  printf '%s' "${1:-}" \
    | grep -oE '/security/code-scanning/[0-9]+' | head -n1 | grep -oE '[0-9]+$' || true
}
