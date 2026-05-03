#!/usr/bin/env bash
# phase-4b-classifier.sh — classify a PR against the Phase 4b proactive-
# trigger taxonomy from REVIEW_POLICY.md § Phase 4b Triggers (#158).
#
# Reads the PR's changed-files list + body, runs five trigger detectors,
# emits a JSON recommendation. Consumed by CLAUDE.md step 8.5 (#187) to
# decide whether to invoke Phase 4b proactively in addition to its
# fallback role.
#
# Usage:
#   scripts/phase-4b-classifier.sh <PR#>
#   scripts/phase-4b-classifier.sh <PR#> --repo owner/name
#   scripts/phase-4b-classifier.sh <PR#> --fixture path/to/files.json
#
# The --fixture flag is for testability: instead of calling
# `gh api repos/.../pulls/{pr}/files`, read the changed-files JSON from
# the fixture file. Same shape as gh's response (array of {filename,
# patch} objects). Used by scripts/ci/check_phase_4b_classifier.
#
# Exit codes (per #158):
#   0 — no 4b needed (no trigger matched OR phase_4b_default == "fallback-only")
#   1 — 4b recommended (one or more triggers matched AND policy is
#       "complex-changes" or "always")
#   2 — gh API failure / malformed config
#   3 — bad arguments
#
# Output (stdout, JSON):
#   {
#     "match": true|false,
#     "triggers": ["state-machine-change", "concurrency", ...],
#     "recommendation": "invoke-4b" | "fallback-only",
#     "rationale": "<human-readable>",
#     "phase_4b_default": "<policy value>",
#     "files_inspected": <count>
#   }

set -euo pipefail

# ── Argument parsing ─────────────────────────────────────────────────────────

PR_NUM=""
REPO=""
FIXTURE=""

usage() {
  cat <<'EOF' >&2
Usage: scripts/phase-4b-classifier.sh <PR#> [--repo owner/name] [--fixture path]

Classifies a PR against the Phase 4b proactive-trigger taxonomy
(REVIEW_POLICY.md § Phase 4b Triggers). Outputs JSON recommendation.

Exit codes:
  0 = no 4b needed
  1 = 4b recommended
  2 = API / config error
  3 = bad arguments

EOF
  exit 3
}

while [ $# -gt 0 ]; do
  case "$1" in
    --repo)
      if [ $# -lt 2 ] || [ -z "$2" ]; then
        echo "Error: --repo requires a non-empty value (owner/name)" >&2; usage
      fi
      REPO="$2"; shift 2 ;;
    --fixture)
      if [ $# -lt 2 ] || [ -z "$2" ]; then
        echo "Error: --fixture requires a non-empty value (path)" >&2; usage
      fi
      FIXTURE="$2"; shift 2 ;;
    -h|--help) usage ;;
    -*) echo "Unknown flag: $1" >&2; usage ;;
    *)
      if [ -z "$PR_NUM" ]; then PR_NUM="$1"
      else echo "Unexpected positional: $1" >&2; usage
      fi
      shift
      ;;
  esac
done

[ -z "$PR_NUM" ] && usage
if ! [[ "$PR_NUM" =~ ^[1-9][0-9]*$ ]]; then
  echo "Error: PR# must be a positive integer; got '$PR_NUM'" >&2; exit 3
fi

if [ -n "$REPO" ] && ! [[ "$REPO" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*\/[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
  echo "Error: invalid --repo value: '$REPO' (expected owner/name)" >&2; exit 3
fi

if [ -n "$FIXTURE" ] && [ ! -r "$FIXTURE" ]; then
  echo "Error: --fixture file not readable: $FIXTURE" >&2; exit 3
fi

# ── Policy: phase_4b_default ─────────────────────────────────────────────────

CONFIG=".github/review-policy.yml"
PHASE_4B_DEFAULT=""
if [ -f "$CONFIG" ]; then
  PHASE_4B_DEFAULT=$(awk '
    $1 == "phase_4b_default:" {
      sub(/^[[:space:]]*[^:]+:[[:space:]]*/, "", $0)
      gsub(/^"/, "", $0); gsub(/"[[:space:]]*(#.*)?$/, "", $0)
      gsub(/[[:space:]]*#.*$/, "", $0); sub(/[[:space:]]+$/, "", $0)
      print; exit
    }
  ' "$CONFIG")
fi
PHASE_4B_DEFAULT=${PHASE_4B_DEFAULT:-fallback-only}
case "$PHASE_4B_DEFAULT" in
  fallback-only|complex-changes|always) ;;
  *)
    echo "Error: phase_4b_default must be one of fallback-only / complex-changes / always; got '$PHASE_4B_DEFAULT'" >&2
    echo "       See REVIEW_POLICY.md § Phase 4b Triggers." >&2
    exit 2
    ;;
esac

# ── Fast-path: policy short-circuits ─────────────────────────────────────────

emit_json() {
  local match=$1 triggers=$2 recommendation=$3 rationale=$4 files_inspected=$5
  jq -n \
    --argjson match "$match" \
    --argjson triggers "$triggers" \
    --arg rec "$recommendation" \
    --arg rationale "$rationale" \
    --arg policy "$PHASE_4B_DEFAULT" \
    --argjson files_inspected "$files_inspected" \
    '{match: $match, triggers: $triggers, recommendation: $rec,
      rationale: $rationale, phase_4b_default: $policy,
      files_inspected: $files_inspected}'
}

if [ "$PHASE_4B_DEFAULT" = "fallback-only" ]; then
  emit_json false '[]' "fallback-only" "policy is fallback-only; classifier short-circuits without inspecting diff" 0
  exit 0
fi

if [ "$PHASE_4B_DEFAULT" = "always" ]; then
  emit_json true '[]' "invoke-4b" "policy is always; 4b handoff is required for every threshold-PR regardless of trigger match" 0
  exit 1
fi

# Past this point: PHASE_4B_DEFAULT == "complex-changes". Run the
# trigger detectors.

# ── Resolve repo + fetch PR data ────────────────────────────────────────────

# --fixture bypasses live API calls, so REPO resolution is unnecessary.
# Only resolve when actually going to call gh.
if [ -z "$REPO" ] && [ -z "$FIXTURE" ]; then
  REPO=$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null) || {
    echo "Error: could not resolve repo. Pass --repo owner/name (or --fixture)." >&2; exit 2
  }
fi

if [ -n "$FIXTURE" ]; then
  FILES_JSON=$(cat "$FIXTURE")
  # Validate JSON shape up-front — jq's native exit codes (e.g., 4 on
  # parse error, 5 on schema mismatch) would otherwise propagate
  # through `set -e` and break the script's documented 0/1/2/3 exit
  # contract. CodeRabbit Major on PR #190.
  if ! echo "$FILES_JSON" | jq -e . >/dev/null 2>&1; then
    echo "Error: fixture is not valid JSON: $FIXTURE" >&2
    exit 2
  fi
  PR_BODY=""
  # Fixtures may include an optional body field via .body — extract it
  # if present, otherwise empty. The fixture file's top-level shape is
  # either a bare files array (legacy/simple) or a {body, files} object
  # (when body-text triggers need to be exercised).
  if echo "$FILES_JSON" | jq -e 'type == "object" and has("files")' >/dev/null 2>&1; then
    PR_BODY=$(echo "$FILES_JSON" | jq -r '.body // ""' 2>/dev/null) || {
      echo "Error: failed to read .body from fixture object" >&2; exit 2
    }
    FILES_JSON=$(echo "$FILES_JSON" | jq '.files' 2>/dev/null) || {
      echo "Error: failed to read .files from fixture object" >&2; exit 2
    }
  fi
  if ! echo "$FILES_JSON" | jq -e 'type == "array"' >/dev/null 2>&1; then
    echo "Error: fixture changed-files payload must be an array (got non-array after .files extraction)" >&2
    exit 2
  fi
else
  if [ -z "${GH_TOKEN:-}" ]; then
    echo "Error: GH_TOKEN required for live API call (or use --fixture)." >&2
    exit 2
  fi
  FILES_JSON=$(gh api --paginate "repos/$REPO/pulls/$PR_NUM/files" 2>&1) || {
    echo "Error: failed to fetch PR files: $FILES_JSON" >&2; exit 2
  }
  # gh --paginate emits a stream of arrays; flatten into one. Normalize
  # any jq failure here to exit 2 per the contract.
  FILES_JSON=$(echo "$FILES_JSON" | jq -s 'add // []' 2>/dev/null) || {
    echo "Error: failed to flatten gh pulls/files paginated response" >&2; exit 2
  }
  # Mirror the fixture-path shape guard: after flatten, the live API
  # response must be a JSON array. Anything else (a string error blob
  # gh somehow snuck through, an object, null) is a contract violation
  # — exit 2 instead of letting jq's downstream `.[]` produce confusing
  # failures. CR Major on PR #190 r1.
  if ! echo "$FILES_JSON" | jq -e 'type == "array"' >/dev/null 2>&1; then
    echo "Error: live API changed-files payload must be an array (got non-array after flatten)" >&2
    exit 2
  fi
  # PR body fetch failure must NOT silently mask body-only triggers
  # (state-machine via "state machine" body mention, invariant via
  # "invariant" body mention). Hard-fail with exit 2 instead of
  # falling through with PR_BODY="" — codex r1 Phase 4b on PR #190
  # caught the prior `|| echo ""` swallow + reproduced with stubbed gh.
  PR_BODY=$(gh api "repos/$REPO/pulls/$PR_NUM" --jq '.body // ""' 2>&1) || {
    echo "Error: failed to fetch PR body for $REPO#$PR_NUM: $PR_BODY" >&2
    echo "       Body-only triggers (state-machine / invariant body mention) require this fetch to succeed." >&2
    exit 2
  }
fi

FILES_COUNT=$(echo "$FILES_JSON" | jq 'length' 2>/dev/null) || {
  echo "Error: failed to compute files count (malformed FILES_JSON)" >&2; exit 2
}
if [ "$FILES_COUNT" -eq 0 ]; then
  emit_json false '[]' "fallback-only" "no files in PR diff" 0
  exit 0
fi

# Pre-extract for the detectors:
#   FILE_PATHS — newline-separated filenames
#   PATCH_TEXT — concatenated patch hunks for keyword scanning
FILE_PATHS=$(echo "$FILES_JSON" | jq -r '.[].filename // empty')
PATCH_TEXT=$(echo "$FILES_JSON" | jq -r '.[].patch // empty')

# ── Trigger detectors ───────────────────────────────────────────────────────
# Each function: prints rationale fragment to stdout on match; returns 0
# on match, 1 on no-match. The caller composes hits into the triggers
# array and the rationale into the JSON output.

detect_state_machine_changes() {
  # Tagged-union pattern: `type X = | { kind: "..."` or similar.
  # Plus PR body explicit "state machine" mention.
  local matched_files matched_body=""
  matched_files=$(echo "$PATCH_TEXT" | grep -E '\| \{ kind: "|\| \{ status: "|type [A-Z][A-Za-z0-9_]+ = .* \| .* \|' || true)
  if echo "$PR_BODY" | grep -qiE '\bstate[ -]machine\b'; then
    matched_body="PR body mentions state machine"
  fi
  if [ -n "$matched_files" ] || [ -n "$matched_body" ]; then
    local frag="state-machine pattern detected"
    [ -n "$matched_body" ] && frag="$frag ($matched_body)"
    [ -n "$matched_files" ] && frag="$frag (tagged-union pattern in diff)"
    printf '%s' "$frag"
    return 0
  fi
  return 1
}

detect_concurrency() {
  local matched_keywords matched_paths
  # `|| true` on each grep — under `set -euo pipefail` an empty-match
  # grep exits 1, which propagates through pipefail and aborts the
  # script before the no-match branch is taken. CR Major on PR #190 r1.
  matched_keywords=$({ echo "$PATCH_TEXT" | grep -Eo 'runTransaction|setSnapshot|applyOptimistic|compare-and-set|Promise\.all|writeBatch' || true; } | sort -u | head -3)
  matched_paths=$({ echo "$FILE_PATHS" | grep -E '(^|/)(transactions?|concurrency)/' || true; } | head -3)
  if [ -n "$matched_keywords" ] || [ -n "$matched_paths" ]; then
    local frag="concurrency/transactional pattern detected"
    [ -n "$matched_keywords" ] && frag="$frag (keywords: $(echo "$matched_keywords" | tr '\n' ',' | sed 's/,$//'))"
    [ -n "$matched_paths" ] && frag="$frag (paths: $(echo "$matched_paths" | tr '\n' ',' | sed 's/,$//'))"
    printf '%s' "$frag"
    return 0
  fi
  return 1
}

detect_prompt_design() {
  local matched
  matched=$({ echo "$FILE_PATHS" | grep -E '(^|/)prompts/|\.v[0-9]+\.md$|prompts/.*\.json$' || true; } | head -3)
  if [ -n "$matched" ]; then
    printf 'prompt design / LLM contract change in: %s' "$(echo "$matched" | tr '\n' ',' | sed 's/,$//')"
    return 0
  fi
  return 1
}

detect_cross_cutting_refactor() {
  # Heuristic: count distinct top-level dirs in the changed-files list.
  # If ≥3 distinct dirs OR diff includes BOTH src/types/ AND src/services/
  # (or analogous layer pair), match.
  local distinct_top_dirs has_types has_services
  # Count distinct top-level DIRECTORIES, not filenames. A path with no
  # `/` is a root-level file; collapse all such files to a single
  # sentinel ("<root>") so a docs-only PR touching N root files counts
  # as 1 distinct entry, not N. Codex P2 + CR Minor on PR #190 caught
  # the prior `awk -F/ '{print $1}'` over-counting root files as dirs,
  # which spuriously triggered cross-cutting on docs-only PRs.
  distinct_top_dirs=$(echo "$FILE_PATHS" | awk -F/ 'NF>1 {print $1; next} {print "<root>"}' | sort -u | wc -l | tr -d ' ')
  has_types=$(echo "$FILE_PATHS" | grep -cE '(^|/)types/' || true)
  has_services=$(echo "$FILE_PATHS" | grep -cE '(^|/)services/' || true)
  if [ "$distinct_top_dirs" -ge 3 ]; then
    printf 'cross-cutting refactor (changes span %s distinct top-level dirs)' "$distinct_top_dirs"
    return 0
  fi
  if [ "$has_types" -gt 0 ] && [ "$has_services" -gt 0 ]; then
    printf 'cross-cutting refactor (changes span both types/ and services/ layers)'
    return 0
  fi
  return 1
}

detect_invariant_enforcement() {
  local matched_paths matched_body
  matched_paths=$({ echo "$FILE_PATHS" | grep -E '(^|/)(validation|security|policies)/' || true; } | head -3)
  matched_body=""
  if echo "$PR_BODY" | grep -qiE '\binvariant\b'; then
    matched_body="PR body mentions invariant"
  fi
  if [ -n "$matched_paths" ] || [ -n "$matched_body" ]; then
    local frag="invariant/validation change"
    [ -n "$matched_body" ] && frag="$frag ($matched_body)"
    [ -n "$matched_paths" ] && frag="$frag (paths: $(echo "$matched_paths" | tr '\n' ',' | sed 's/,$//'))"
    printf '%s' "$frag"
    return 0
  fi
  return 1
}

# ── Run detectors + compose output ──────────────────────────────────────────

TRIGGERS=()
RATIONALE_PARTS=()

run_detector() {
  local name=$1 fn=$2
  local frag
  if frag=$($fn); then
    TRIGGERS+=("$name")
    RATIONALE_PARTS+=("$name: $frag")
  fi
}

run_detector "state-machine-change"      detect_state_machine_changes
run_detector "concurrency"               detect_concurrency
run_detector "prompt-design"             detect_prompt_design
run_detector "cross-cutting-refactor"    detect_cross_cutting_refactor
run_detector "invariant-enforcement"     detect_invariant_enforcement

if [ "${#TRIGGERS[@]}" -eq 0 ]; then
  emit_json false '[]' "fallback-only" "no trigger classes matched on $FILES_COUNT changed file(s)" "$FILES_COUNT"
  exit 0
fi

TRIGGERS_JSON=$(printf '%s\n' "${TRIGGERS[@]}" | jq -R . | jq -s .)
RATIONALE=$(printf '%s; ' "${RATIONALE_PARTS[@]}" | sed 's/; $//')
emit_json true "$TRIGGERS_JSON" "invoke-4b" "$RATIONALE" "$FILES_COUNT"
exit 1
