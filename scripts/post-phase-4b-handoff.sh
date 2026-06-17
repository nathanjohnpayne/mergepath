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
#   - branch matches `mergepath-sync/<sha>` or `mergepath-sync/sync-all-<sha>`
#     → "verbatim mirror of mergepath@<sha>"
#     (if the PR has commits beyond the sync source — detected by a
#      commit count >1 — annotate as "sync + N convergence commits"
#      instead).
#   - otherwise → "novel work".
#
# `GH_TOKEN` (e.g. `$OP_PREFLIGHT_REVIEWER_PAT`) is honored on the
# read paths per the Active-account convention; not required for
# public-repo reads.
#
# Exit codes:
#   0  rendered to stdout successfully.
#   2  usage / argument error.
#   3  `gh` not available or a required field could not be fetched.

set -euo pipefail

usage() {
  cat >&2 <<EOF
usage: post-phase-4b-handoff.sh <pr-ref> [<pr-ref> ...]

  <pr-ref>           <num> | <owner>/<repo>#<num>

Emits the chat-side Phase 4b handoff block to stdout.
EOF
  exit 2
}

[[ $# -ge 1 ]] || usage

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

# Classify a head ref string into a content note.
# Inputs: head_ref (branch name), commits_count (int)
# Stdout: one-line content classification.
classify_content() {
  local head_ref="$1"
  local commits_count="$2"
  local sha=""
  if [[ "$head_ref" =~ ^mergepath-sync/(sync-all-)?([0-9a-f]+)$ ]]; then
    sha="${BASH_REMATCH[2]}"
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
#   unresolved_threads  url
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

  # Unresolved review threads — best-effort via GraphQL. On failure
  # (auth scope, network), emit "?" rather than hard-failing the
  # handoff render. Paginate beyond 100 — the prior `first: 100` form
  # silently undercounted on PRs with >100 review threads (rare but
  # observable on long-running canonical PRs after multi-round Phase 4b
  # iterations + heavy CodeRabbit traffic). (nathanpayne-codex Phase 4b
  # r1 on PR #291.)
  local unresolved="?"
  local owner repo_name
  owner="${owner_name%%/*}"
  repo_name="${owner_name#*/}"
  local cursor="null"  # GraphQL `after: null` = start of stream
  local running_total=0
  local pages=0
  local saw_error=0
  while :; do
    local gql
    gql=$(gh api graphql -f query="
      query(\$owner: String!, \$name: String!, \$num: Int!, \$cursor: String) {
        repository(owner: \$owner, name: \$name) {
          pullRequest(number: \$num) {
            reviewThreads(first: 100, after: \$cursor) {
              pageInfo { hasNextPage endCursor }
              nodes { isResolved }
            }
          }
        }
      }" -F owner="$owner" -F name="$repo_name" -F num="$num" \
         -F cursor="$cursor" 2>/dev/null || true)
    if [[ -z "$gql" ]]; then
      saw_error=1
      break
    fi
    local page_count
    page_count=$(printf '%s' "$gql" \
      | jq -r '[.data.repository.pullRequest.reviewThreads.nodes[]?
                | select(.isResolved == false)] | length' 2>/dev/null || echo "")
    if [[ ! "$page_count" =~ ^[0-9]+$ ]]; then
      saw_error=1
      break
    fi
    running_total=$((running_total + page_count))
    local has_next
    has_next=$(printf '%s' "$gql" \
      | jq -r '.data.repository.pullRequest.reviewThreads.pageInfo.hasNextPage // false' 2>/dev/null)
    if [[ "$has_next" != "true" ]]; then
      break
    fi
    cursor=$(printf '%s' "$gql" \
      | jq -r '.data.repository.pullRequest.reviewThreads.pageInfo.endCursor // empty' 2>/dev/null)
    if [[ -z "$cursor" || "$cursor" == "null" ]]; then
      # Defensive: hasNextPage=true but no cursor returned — bail
      # rather than infinite-loop.
      saw_error=1
      break
    fi
    pages=$((pages + 1))
    if [[ "$pages" -gt 100 ]]; then
      # Cap at 10,000 threads (100 pages × 100 per page) to prevent
      # runaway loops on pathological inputs. Vanishingly unlikely to
      # hit in practice — Phase 4b handoff renders don't fire on PRs
      # this large — but the cap is cheap insurance.
      saw_error=1
      break
    fi
  done
  if [[ "$saw_error" -eq 0 ]]; then
    unresolved="$running_total"
  fi

  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$head_sha" "${head_sha:0:7}" \
    "$base_sha" "${base_sha:0:7}" \
    "$head_ref" "$commits" \
    "$unresolved" "$url"
}

# Render the single-PR variant.
#   Inputs: $1 url, $2 head_short, $3 base_short, $4 content_note, $5 unresolved
render_single() {
  local url="$1" head_short="$2" base_short="$3" content="$4" unresolved="$5"
  cat <<EOF
PR ready for external review (Phase 4b):

  ${url}  head ${head_short}  (base ${base_short})

Context: ${content}
Gate: post APPROVED as nathanpayne-codex on the listed HEAD, OR a
      Codex bot review / 👍 reaction newer than the HEAD committer date.
Threads: ${unresolved} unresolved (resolve addressed bot or agent-reviewer
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
  IFS=$'\t' read -r head_sha head_short base_sha base_short head_ref commits unresolved url <<<"$meta"
  content=$(classify_content "$head_ref" "$commits")
  ROWS_TSV+="$(printf '%s\t%s\t%s\t%s\t%s\t%s\t%s' \
    "$repo" "$num" "$url" "$head_short" "$base_short" "$content" "$unresolved")"$'\n'
done <<<"$REFS_TSV"

# Count populated rows for variant selection.
ROW_COUNT=$(printf '%s' "$ROWS_TSV" | grep -c $'\t' || true)

if [[ "$ROW_COUNT" -eq 1 ]]; then
  # Single-PR variant.
  IFS=$'\t' read -r _repo _num url head_short base_short content unresolved <<<"$(printf '%s' "$ROWS_TSV" | head -n 1)"
  render_single "$url" "$head_short" "$base_short" "$content" "$unresolved"
  exit 0
fi

# -----------------------------------------------------------------------
# Batch variant: table + paste prompt.
# -----------------------------------------------------------------------
echo "| Repo | PR # | HEAD short SHA | Unresolved threads | Content note |"
echo "|------|------|---------------|-------------------|--------------|"
while IFS=$'\t' read -r repo num url head_short base_short content unresolved; do
  [[ -n "$repo" ]] || continue
  printf '| `%s` | [#%s](%s) | `%s` | %s | %s |\n' \
    "$repo" "$num" "$url" "$head_short" "$unresolved" "$content"
done <<<"$ROWS_TSV"
echo

# Compute shared context line: if all rows have the same content
# classification, surface it; otherwise "mixed — see table above".
SHARED_CONTEXT=""
ALL_SAME=1
FIRST_CONTENT=""
while IFS=$'\t' read -r _repo _num _url _head_short _base_short content _unresolved; do
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
while IFS=$'\t' read -r _repo _num url _head_short_unused base_short _content _unresolved; do
  [[ -n "$_repo" ]] || continue
  # Re-read to get head_short in the right column.
  :
done <<<"$ROWS_TSV"
# Print one URL line per row, with head + base shorts.
while IFS=$'\t' read -r _repo _num url head_short base_short _content _unresolved; do
  [[ -n "$_repo" ]] || continue
  printf '  %s  head %s  (base %s)\n' "$url" "$head_short" "$base_short"
done <<<"$ROWS_TSV"
echo
echo "Context: ${SHARED_CONTEXT}"
echo 'Gate: for each PR, post APPROVED as nathanpayne-codex on the listed'
echo '      HEAD, OR a Codex bot review / 👍 reaction newer than the HEAD'
echo '      committer date.'
echo 'Threads: see "Unresolved threads" column (resolve addressed bot or'
echo '         agent-reviewer threads per the pre-merge gate; never resolve'
echo '         real-human threads automatically).'
echo '```'
