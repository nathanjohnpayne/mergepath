#!/usr/bin/env bash
# scripts/post-phase-4b-handoff.sh
#
# Render the chat-side Phase 4b handoff block to stdout (single-PR or
# batch variant) per REVIEW_POLICY.md § Handoff Message Format
# § Chat-side handoff block. See nathanjohnpayne/mergepath#281.
#
# STDOUT-ONLY: this helper NEVER posts comments, NEVER edits labels,
# NEVER mutates remote state. Read-only `gh api` GETs are the only
# side effect. The originating agent emits the rendered block into
# chat itself; the human pastes it into the external reviewer's CLI
# session.
#
# Usage:
#   scripts/post-phase-4b-handoff.sh <pr-ref> [<pr-ref> ...]
#
#   <pr-ref> takes one of two forms:
#     <num>              — PR in the current repo (resolved via
#                          `gh repo view --json owner,name`).
#     <owner>/<repo>#<num> — cross-repo PR.
#
# Examples:
#   scripts/post-phase-4b-handoff.sh 281
#   scripts/post-phase-4b-handoff.sh 281 nathanjohnpayne/matchline#42
#
# With one PR ref, emits the single-PR variant. With two or more,
# emits the batch variant (markdown table + paste-prompt).
#
# Content classification:
#   - branch matches `mergepath-sync/<sha>`, legacy
#     `mergepath-sync/sync-all-<sha>`, or scoped
#     `mergepath-sync/sync-all-<sha>-<scope-digest>`
#     → "verbatim mirror of mergepath@<sha>"
#     (if the PR has commits beyond the sync source — detected by a
#      commit count >1 — annotate as "sync + N convergence commits"
#      instead).
#   - otherwise → "novel work".
#
# `GH_TOKEN` (or the cached `$OP_PREFLIGHT_REVIEWER_PAT`) is required for the
# complete-history accounting read. The helper auto-sources a fresh preflight
# cache using the standard read-only reviewer scope.
#
# Exit codes:
#   0  rendered to stdout successfully.
#   2  usage / argument error.
#   3  `gh` not available or a required field could not be fetched.
#   4  prior reviewer feedback is unaccounted; no handoff was rendered.
#   5  Codex review is in flight on HEAD; rerun after it reports.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -r "$SCRIPT_DIR/lib/preflight-helpers.sh" ]; then
  # shellcheck source=lib/preflight-helpers.sh
  . "$SCRIPT_DIR/lib/preflight-helpers.sh"
  preflight_require_token reviewer || true
fi

usage() {
  cat >&2 <<EOF
usage: post-phase-4b-handoff.sh <pr-ref> [<pr-ref> ...]

  <pr-ref>           <num> | <owner>/<repo>#<num>

Emits the chat-side Phase 4b handoff block to stdout.
EOF
  exit 2
}

[[ $# -ge 1 ]] || usage
# shellcheck source=lib/pr-body-contract.sh
. "$SCRIPT_DIR/lib/pr-body-contract.sh"
# shellcheck source=lib/codex-request-evidence.sh
. "$SCRIPT_DIR/lib/codex-request-evidence.sh"
# shellcheck source=lib/codex-failure-markers.sh
. "$SCRIPT_DIR/lib/codex-failure-markers.sh"
# shellcheck source=lib/feedback-policy-helpers.sh
. "$SCRIPT_DIR/lib/feedback-policy-helpers.sh"

command -v gh >/dev/null 2>&1 || {
  echo "post-phase-4b-handoff.sh: gh not on PATH" >&2
  exit 3
}
command -v jq >/dev/null 2>&1 || {
  echo "post-phase-4b-handoff.sh: jq not on PATH (every metadata parse below pipes through jq)" >&2
  exit 3
}

# ---------------------------------------------------------------------------
# Resolve current-repo owner/name once for bare <num> refs. Lazy: if no
# bare ref is passed, the resolution is skipped (so the helper works
# outside a git checkout when every ref is owner/repo#num).
# ---------------------------------------------------------------------------
CURRENT_REPO=""
resolve_current_repo() {
  if [[ -n "$CURRENT_REPO" ]]; then
    return 0
  fi
  if ! CURRENT_REPO=$(gh repo view --json owner,name --jq '.owner.login + "/" + .name' 2>/dev/null); then
    echo "post-phase-4b-handoff.sh: a bare <num> ref was passed but the current dir is not a gh-resolvable repo" >&2
    exit 3
  fi
}

# Parse one ref into "<owner>/<repo>\t<num>" lines (tab-separated).
parse_ref() {
  local ref="$1"
  if [[ "$ref" =~ ^([^/]+)/([^#]+)#([0-9]+)$ ]]; then
    printf '%s/%s\t%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}"
  elif [[ "$ref" =~ ^[0-9]+$ ]]; then
    resolve_current_repo
    printf '%s\t%s\n' "$CURRENT_REPO" "$ref"
  else
    echo "post-phase-4b-handoff.sh: invalid pr-ref: $ref" >&2
    exit 2
  fi
}

# Build a tab-separated table of (repo, num) pairs.
REFS_TSV=""
for raw in "$@"; do
  REFS_TSV+="$(parse_ref "$raw")"$'\n'
done

# A manual handoff is a real reviewer dispatch. Reconcile every prior finding
# before rendering the artifact that starts that round, just as the automated
# Phase 4b path gates before its adapter call (#1000).
FEEDBACK_ACCOUNTING_GATE="${MERGEPATH_REVIEW_FEEDBACK_ACCOUNTING_CMD:-$SCRIPT_DIR/review-feedback-accounting.sh}"
command -v "$FEEDBACK_ACCOUNTING_GATE" >/dev/null 2>&1 || {
  echo "post-phase-4b-handoff.sh: review feedback accounting gate unavailable: $FEEDBACK_ACCOUNTING_GATE" >&2
  exit 3
}
ACCOUNTING_TSV=""
while IFS=$'\t' read -r accounting_repo accounting_pr; do
  [[ -n "$accounting_repo" && -n "$accounting_pr" ]] || continue
  accounting_json=""
  accounting_rc=0
  accounting_json=$("$FEEDBACK_ACCOUNTING_GATE" "$accounting_pr" "$accounting_repo") \
    || accounting_rc=$?
  case "$accounting_rc" in
    0) ;;
    1)
      printf '%s\n' "$accounting_json" >&2
      echo "post-phase-4b-handoff.sh: feedback is unaccounted on ${accounting_repo}#${accounting_pr}; no handoff rendered" >&2
      exit 4
      ;;
    *)
      printf '%s\n' "$accounting_json" >&2
      echo "post-phase-4b-handoff.sh: feedback accounting failed with exit $accounting_rc on ${accounting_repo}#${accounting_pr}" >&2
      exit 3
      ;;
  esac
  if ! printf '%s' "$accounting_json" | jq -e --arg repo "$accounting_repo" --argjson pr "$accounting_pr" '
    .status == "clear" and .repo == $repo and .pr_number == $pr and
    (.posted | type == "number" and . >= 0 and floor == .) and
    .accounted == .posted and .missing_count == 0
  ' >/dev/null 2>&1; then
    echo "post-phase-4b-handoff.sh: invalid accounting result for ${accounting_repo}#${accounting_pr}" >&2
    exit 3
  fi
  ACCOUNTING_TSV+="$(printf '%s\t%s\t%s' "$accounting_repo" "$accounting_pr" "$(jq -r .missing_count <<<"$accounting_json")")"$'\n'
done <<<"$REFS_TSV"

fetch_history_array() {
  local pages
  pages=$(gh api --paginate --slurp "$1") || return 1
  printf '%s' "$pages" | jq -ce '
    if type == "array" and all(.[]; type == "array") and all(.[][]; type == "object") then add // []
    else error("incomplete history") end'
}

# Reuse the merge checker's summary/run selectors. This is sensing, never a
# request or cap reset; an unanswered expired request permits timeout fallback.
ensure_codex_idle() {
  local repo="$1" num="$2" head="$3" policy_json="$4"
  local source_repo="${5:-}" source_id="${6:-0}" head_ref="${7:-}"
  local bot author timeout comments reviews inline summary trigger response timeline transition floor since enabled failure
  local events push_transition
  bot=$(jq -er '.codex.bot_login // "chatgpt-codex-connector[bot]" | select(type == "string" and length > 0)' <<<"$policy_json") || exit 3
  author=$(crqe_policy_author "$policy_json") || exit 3
  timeout=$(jq -er '.codex.review_timeout_seconds // 1800 | select(type == "number" and . > 0 and floor == .)' <<<"$policy_json") || exit 3
  enabled=$(jq -r 'if (.codex | type) == "object" and (.codex | has("enabled")) then .codex.enabled else true end | if type == "boolean" then . else error("codex.enabled") end' <<<"$policy_json") || exit 3
  comments=$(fetch_history_array "repos/$repo/issues/$num/comments") &&
    reviews=$(fetch_history_array "repos/$repo/pulls/$num/reviews") &&
    inline=$(fetch_history_array "repos/$repo/pulls/$num/comments") || {
      echo "post-phase-4b-handoff.sh: unreadable Codex history for $repo#$num" >&2; exit 3;
    }
  summary=$(crqe_select_codex_review_summary "$comments" "$bot" "$head") || exit 3
  response=$(crqe_select_head_review "$reviews" "$inline" "$bot" "$head" | jq -r '.submitted_at // ""') || exit 3
  response=$(crqe_verdicts "$comments" "$bot" | jq -r --arg head "$head" --arg response "$response" '
    [ $response, (.[] | select(.reviewed_shas == [$head]) | .created_at) ] | max // ""') || exit 3
  trigger=null
  if [[ "$enabled" != false ]]; then
    timeline=$(fetch_history_array "repos/$repo/issues/$num/timeline") || exit 3
    transition=$(crqe_latest_head_transition "$timeline") || exit 3
    # Events may arrive late or be absent from the bounded feed. Only a
    # positive, exact source/head match can narrow the existing wait window;
    # unavailable evidence retains the force-push/timeout behavior.
    if [[ "$source_repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ \
       && "$source_id" =~ ^[1-9][0-9]*$ && -n "$head_ref" ]]; then
      if events=$(fetch_history_array "repos/$source_repo/events?per_page=100" 2>/dev/null) \
         && push_transition=$(crqe_latest_matching_head_push "$events" "$source_repo" "$source_id" \
              "$head_ref" "$head" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" 2>/dev/null); then
        [[ "$push_transition" < "$transition" ]] || transition="$push_transition"
      else
        echo "post-phase-4b-handoff.sh: ordinary-push evidence unavailable; retaining the existing request window" >&2
      fi
    fi
    floor=$(($(date +%s) - timeout))
    since=$(date -u -r "$floor" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "@$floor" +%Y-%m-%dT%H:%M:%SZ) || exit 3
    # Only GitHub's bound transition can exclude a prior-head request.
    # Commit dates may be old or future; neither proves when this head arrived.
    [[ "$since" > "$transition" ]] || since="$transition"
    trigger=$(crqe_select_trigger "$comments" "$author" "$since") || exit 3
    # A provider-owned refusal answers this request without claiming a review.
    # Older refusals and other identities cannot end a renewed request's wait.
    if [[ "$trigger" != null ]]; then
      failure=$(jq -r --arg bot "$bot" --argjson trigger "$trigger" \
        --arg usage "$CODEX_USAGE_LIMIT_MARKER_RE" --arg connection "$CODEX_NOT_CONNECTED_MARKER_RE" '
        [.[] | select(.user.login == $bot)
         | select((.body // "") | test($usage; "i") or test($connection; "i"))
         | select([.created_at, .id] > [$trigger.created_at, $trigger.id])]
        | max_by([.created_at, .id]) | .created_at // ""' <<<"$comments") || exit 3
      [[ "$failure" < "$response" ]] || response="$failure"
    fi
    response=$(jq -r --arg response "$response" '[ $response, (if .status == "completed" then .observed_at else "" end) ] | max // ""' <<<"$summary") || exit 3
  fi
  # A disabled provider has no expected response, but an observed running
  # summary still prevents briefing over actual ongoing work. A newer summary
  # likewise retains the hold after an earlier terminal failure.
  if [[ "$(jq -r '.status // ""' <<<"$summary")" =~ ^(running|unknown)$ ]] \
     && [[ "$(jq -r '.observed_at // ""' <<<"$summary")" > "$response" || "$(jq -r '.observed_at // ""' <<<"$summary")" == "$response" ]]; then
    echo "post-phase-4b-handoff.sh: Codex review in flight on HEAD $head; rerun after it reports" >&2
    exit 5
  fi
  if [[ "$enabled" != false ]]; then
    if [[ "$trigger" != null && "$(jq -r .created_at <<<"$trigger")" > "$response" ]]; then
      echo "post-phase-4b-handoff.sh: Codex request in flight on HEAD $head; rerun after it reports" >&2
      exit 5
    fi
  fi
}

# Classify a head ref string into a content note.
# Inputs: head_ref (branch name), commits_count (int)
# Stdout: one-line content classification.
classify_content() {
  local head_ref="$1"
  local commits_count="$2"
  local sha=""
  if [[ "$head_ref" =~ ^mergepath-sync/sync-all-([0-9a-f]{7,40})-[0-9a-f]{12}$ ]]; then
    sha="${BASH_REMATCH[1]}"
  elif [[ "$head_ref" =~ ^mergepath-sync/(sync-all-)?([0-9a-f]+)$ ]]; then
    sha="${BASH_REMATCH[2]}"
  fi
  if [ -n "$sha" ]; then
    # Trim to 12 chars to keep the chat line readable; full sha is on
    # the PR's HEAD anyway.
    local short="${sha:0:12}"
    if [[ "$commits_count" =~ ^[0-9]+$ ]] && [[ "$commits_count" -gt 1 ]]; then
      local n=$((commits_count - 1))
      printf 'sync + %s convergence commit%s on mergepath@%s' \
        "$n" "$( [ "$n" -eq 1 ] && echo "" || echo "s" )" "$short"
    else
      printf 'verbatim mirror of mergepath@%s' "$short"
    fi
  else
    printf 'novel work'
  fi
}

# Fetch PR metadata in a single gh api call per PR.
#   $1: owner/repo  $2: pr_number
# Outputs (tab-separated, one line):
#   head_sha  head_short  base_sha  base_short  head_ref  commits_count
#   unresolved_threads  url  reviewer
fetch_pr_metadata() {
  local repo="$1"
  local num="$2"
  local owner_name="${repo}"
  local json
  if ! json=$(gh api "repos/${owner_name}/pulls/${num}" 2>/dev/null); then
    echo "post-phase-4b-handoff.sh: failed to fetch repos/${owner_name}/pulls/${num}" >&2
    exit 3
  fi

  local head_sha base_sha head_ref commits url
  head_sha=$(printf '%s' "$json" | jq -r '.head.sha // empty')
  base_sha=$(printf '%s' "$json" | jq -r '.base.sha // empty')
  head_ref=$(printf '%s' "$json" | jq -r '.head.ref // empty')
  commits=$(printf '%s' "$json" | jq -r '.commits // 0')
  url=$(printf '%s' "$json" | jq -r '.html_url // empty')

  if [[ -z "$head_sha" || -z "$base_sha" || -z "$head_ref" || -z "$url" ]]; then
    echo "post-phase-4b-handoff.sh: PR metadata missing required fields for ${owner_name}#${num}" >&2
    exit 3
  fi

  # Resolve each target's governing policy, including cross-repository batches.
  # Candidate checkout policy must not choose its own external reviewer.
  local policy body author_count author reviewer candidate policy_json unresolved live_head
  policy=$("$SCRIPT_DIR/workflow/resolve_base_policy.sh" --repo "$repo" \
    --base-ref "$(printf '%s' "$json" | jq -r '.base.ref // empty')" \
    --base-sha "$base_sha" \
    --default-branch "$(printf '%s' "$json" | jq -r '.base.repo.default_branch // empty')" \
    --materialize-default) || {
      echo "post-phase-4b-handoff.sh: cannot resolve governing reviewer policy for ${repo}#${num}" >&2
      exit 3
    }
  # fetch_pr_metadata runs in a command substitution; own that subshell's file.
  # shellcheck disable=SC2064 # Bind the escaped path before function-local scope ends.
  trap "$(printf 'rm -f -- %q' "$policy")" EXIT
  body=$(printf '%s' "$json" | jq -r '.body // ""')
  policy_json=$(policy_yaml_to_json "$policy") || exit 3
  author_count=$(pr_body_authoring_agent_count "$body") && \
    author=$(pr_body_authoring_agent "$body") || {
      echo "post-phase-4b-handoff.sh: Authoring-Agent parser failed for ${repo}#${num}" >&2
      exit 3
    }
  if [[ "$author_count" != 1 || -z "$author" ]] \
     || ! pr_body_agent_is_allowed "$author" "$policy"; then
    echo "post-phase-4b-handoff.sh: expected exactly one configured Authoring-Agent for ${repo}#${num}" >&2
    exit 3
  fi
  reviewer=$(printf '%s' "${PHASE_4B_REVIEWER_IDENTITY:-}" | tr '[:upper:]' '[:lower:]')
  if [[ -z "$reviewer" ]]; then
    candidate=$(jq -r '.default_external_reviewer // "" | if type == "string" then ascii_downcase else error("default_external_reviewer") end' <<<"$policy_json") || exit 3
    if [[ -n "$candidate" && "$candidate" != "nathanpayne-$author" ]] \
       && login_is_available_reviewer "$candidate" "$policy"; then
      reviewer="$candidate"
    fi
  fi
  if [[ -z "$reviewer" ]]; then
    while IFS= read -r candidate; do
      candidate=$(printf '%s' "$candidate" | tr '[:upper:]' '[:lower:]')
      case "$candidate" in
        nathanpayne-*)
          if [[ "${candidate#nathanpayne-}" != "$author" ]]; then
            reviewer="$candidate"
            break
          fi
          ;;
      esac
    done <<<"$(read_available_reviewers "$policy")"
  fi
  if [[ -z "$reviewer" || "$reviewer" == "nathanpayne-$author" ]] \
     || ! login_is_available_reviewer "$reviewer" "$policy"; then
    echo "post-phase-4b-handoff.sh: reviewer must be configured and differ from Authoring-Agent '$author' for ${repo}#${num}" >&2
    exit 3
  fi

  ensure_codex_idle "$repo" "$num" "$head_sha" "$policy_json" \
    "$(jq -r '.head.repo.full_name // ""' <<<"$json")" \
    "$(jq -r '.head.repo.id // 0' <<<"$json")" "$head_ref"
  unresolved=$(awk -F '\t' -v repo="$repo" -v num="$num" '$1 == repo && $2 == num {print $3; exit}' <<<"$ACCOUNTING_TSV")
  [[ "$unresolved" =~ ^[0-9]+$ ]] || exit 3
  live_head=$(gh api "repos/$repo/pulls/$num" --jq .head.sha) || exit 3
  if [[ "$live_head" != "$head_sha" ]]; then
    echo "post-phase-4b-handoff.sh: HEAD moved during rendering for $repo#$num" >&2; exit 3
  fi

  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$head_sha" "${head_sha:0:7}" \
    "$base_sha" "${base_sha:0:7}" \
    "$head_ref" "$commits" \
    "$unresolved" "$url" "$reviewer"
}

# Render the single-PR variant.
#   Inputs: $1 url, $2 head_short, $3 base_short, $4 content_note, $5 unresolved
render_single() {
  local url="$1" head_short="$2" base_short="$3" content="$4" unresolved="$5" reviewer="$6"
  cat <<EOF
PR ready for external review (Phase 4b):

  ${url}  head ${head_short}  (base ${base_short})

Context: ${content}
Gate: (b) APPROVED as ${reviewer} on the listed HEAD, AND
      (c) a HEAD-anchored Codex clearance or that same APPROVED review
      as the Phase 4b substitute where governing policy allows it.
Threads: ${unresolved} undispositioned findings (resolve addressed bot or agent-reviewer
         threads per the pre-merge gate; never resolve real-human
         threads automatically).
EOF
}

# Collect rows once so we can render both the table AND the prompt
# from the same data. Each row: tab-separated repo, num, url,
# head_short, base_short, content_note, unresolved.
ROWS_TSV=""
while IFS=$'\t' read -r repo num; do
  [[ -n "$repo" && -n "$num" ]] || continue
  meta=$(fetch_pr_metadata "$repo" "$num")
  IFS=$'\t' read -r head_sha head_short base_sha base_short head_ref commits unresolved url reviewer <<<"$meta"
  content=$(classify_content "$head_ref" "$commits")
  ROWS_TSV+="$(printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s' \
    "$repo" "$num" "$url" "$head_short" "$base_short" "$content" "$unresolved" "$reviewer")"$'\n'
done <<<"$REFS_TSV"

# Count populated rows for variant selection.
ROW_COUNT=$(printf '%s' "$ROWS_TSV" | grep -c $'\t' || true)

if [[ "$ROW_COUNT" -eq 1 ]]; then
  # Single-PR variant.
  IFS=$'\t' read -r _repo _num url head_short base_short content unresolved reviewer <<<"$(printf '%s' "$ROWS_TSV" | head -n 1)"
  render_single "$url" "$head_short" "$base_short" "$content" "$unresolved" "$reviewer"
  exit 0
fi

# -----------------------------------------------------------------------
# Batch variant: table + paste prompt.
# -----------------------------------------------------------------------
echo "| Repo | PR # | HEAD short SHA | Undispositioned findings | Content note | Reviewer |"
echo "|------|------|---------------|-------------------|--------------|----------|"
while IFS=$'\t' read -r repo num url head_short base_short content unresolved reviewer; do
  [[ -n "$repo" ]] || continue
  printf '| `%s` | [#%s](%s) | `%s` | %s | %s | `%s` |\n' \
    "$repo" "$num" "$url" "$head_short" "$unresolved" "$content" "$reviewer"
done <<<"$ROWS_TSV"
echo

# Compute shared context line: if all rows have the same content
# classification, surface it; otherwise "mixed — see table above".
SHARED_CONTEXT=""
ALL_SAME=1
FIRST_CONTENT=""
while IFS=$'\t' read -r _repo _num _url _head_short _base_short content _unresolved _reviewer; do
  [[ -n "$_repo" ]] || continue
  if [[ -z "$FIRST_CONTENT" ]]; then
    FIRST_CONTENT="$content"
  elif [[ "$content" != "$FIRST_CONTENT" ]]; then
    ALL_SAME=0
  fi
done <<<"$ROWS_TSV"
if [[ "$ALL_SAME" -eq 1 ]]; then
  SHARED_CONTEXT="$FIRST_CONTENT"
else
  SHARED_CONTEXT="mixed — see table above"
fi

echo '```'
echo 'PRs ready for external review (Phase 4b):'
echo
# Print one URL line per row, with head + base shorts.
while IFS=$'\t' read -r _repo _num url head_short base_short _content _unresolved reviewer; do
  [[ -n "$_repo" ]] || continue
  printf '  %s  head %s  (base %s)  reviewer %s\n' "$url" "$head_short" "$base_short" "$reviewer"
done <<<"$ROWS_TSV"
echo
echo "Context: ${SHARED_CONTEXT}"
echo 'Gate: for each PR, (b) APPROVED as its listed reviewer on HEAD, AND'
echo '      (c) a HEAD-anchored Codex clearance or that same APPROVED review'
echo '      as the Phase 4b substitute where governing policy allows it.'
echo 'Threads: see "Undispositioned findings" column (resolve addressed bot or'
echo '         agent-reviewer threads per the pre-merge gate; never resolve'
echo '         real-human threads automatically).'
echo '```'
