#!/usr/bin/env bash
# scripts/sweep-unresolved-feedback/render.sh
#
# Consume the NDJSON enumeration emitted by enumerate.sh, render a
# per-repo "Unresolved reviewer feedback backlog" rollup, and post it
# to a SINGLE issue in this repo (mergepath) as the cross-repo
# clearinghouse. Idempotent on its own output:
#
#   - First run: opens a new issue titled
#       "Unresolved reviewer feedback backlog — <YYYY-MM-DD>"
#     with label `post-review`.
#   - Subsequent runs (existing open issue with exact title prefix
#       "Unresolved reviewer feedback backlog" and label `post-review`):
#     compute a content hash of the rollup body. If unchanged since
#     the prior run (matched via the hidden HTML comment marker the
#     script writes), do nothing — no duplicate comment. If the
#     rollup changed materially, post a delta comment listing NEW
#     items only and update the issue body.
#
# Design notes (#236):
#
#   - Single rollup issue per sweep target (mergepath itself), NOT one
#     per scanned target repo. The issue body has a per-target-repo
#     section so the human can navigate. This keeps cross-repo
#     remediation visible in one place — the 2026-05-13 manual sweep
#     proved this is the right ergonomic (#234).
#   - Idempotency is anchored by a hidden HTML comment in the issue
#     body containing the prior enumeration's content hash AND the
#     sorted list of thread_ids. Delta detection diffs the current
#     thread_id set against the prior — items in current-only get
#     posted as the delta comment; items in prior-only are recorded
#     as "resolved between sweeps" (informational, no separate
#     comment).
#   - Counts the rollup as "still requiring fix" only after the
#     validation pass classifies items. v1 of this script just
#     enumerates — the validation pass is a follow-up issue. The
#     rollup body is honest about this: it labels the counts as
#     "raw, pre-validation".
#
# Inputs:
#   $1   path to NDJSON enumeration file (default: /dev/stdin)
#
# Environment:
#   GH_TOKEN              required. Write-path? NO — issue create /
#                         comment on THIS repo only. In CI the
#                         default GITHUB_TOKEN suffices because the
#                         workflow runs in this repo.
#   SWEEP_TARGET_REPO     repo to post the rollup to. Default:
#                         nathanjohnpayne/mergepath. Override in
#                         tests or for a dry-run staging issue.
#   SWEEP_ROLLUP_TITLE    title for the rollup issue. Default
#                         "Unresolved reviewer feedback backlog".
#                         The first creation appends " — <date>"
#                         for human readability; subsequent runs
#                         match on the prefix.
#   SWEEP_DRY_RUN         "1" to print the would-be issue body /
#                         delta comment to stderr and exit without
#                         calling the API. Used by the unit tests.
#   SWEEP_TODAY           override the date stamp (YYYY-MM-DD). Used
#                         by the unit tests for deterministic output.
#
# Exit codes:
#   0   success (no-op, new issue, or delta comment posted)
#   1   setup error (no input, GH_TOKEN unset, malformed JSON)
#   2   API error (gh exited non-zero on issue create/comment)
#
# Bash 3.2 compatible.

set -euo pipefail

INPUT="${1:-/dev/stdin}"

if [ -z "${GH_TOKEN:-}" ] && [ -z "${SWEEP_DRY_RUN:-}" ]; then
  echo "render: GH_TOKEN not set (and SWEEP_DRY_RUN not set)" >&2
  exit 1
fi

for dep in gh jq sha256sum_or_shasum; do
  case "$dep" in
    sha256sum_or_shasum)
      if ! command -v sha256sum >/dev/null 2>&1 && ! command -v shasum >/dev/null 2>&1; then
        echo "render: required dependency missing: sha256sum or shasum" >&2
        exit 1
      fi
      ;;
    *)
      if ! command -v "$dep" >/dev/null 2>&1; then
        echo "render: required dependency missing: $dep" >&2
        exit 1
      fi
      ;;
  esac
done

# Portable hash helper. sha256sum is GNU; shasum is BSD.
_hash() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | awk '{print $1}'
  else
    shasum -a 256 | awk '{print $1}'
  fi
}

TARGET_REPO="${SWEEP_TARGET_REPO:-nathanjohnpayne/mergepath}"
TITLE_PREFIX="${SWEEP_ROLLUP_TITLE:-Unresolved reviewer feedback backlog}"

# Body-size bounding knobs (#397). GitHub caps issue/comment bodies at
# 65536 bytes; a large unresolved-feedback backlog (693 findings on the
# 2026-06-01 run) blew past it because the old render emitted every
# finding inline. We now bound the VISIBLE findings to a hard global
# budget and keep the full set in the workflow's NDJSON artifact + the
# hidden thread-id marker block (which is itself compacted, below).
#   MAX_VISIBLE      hard cap on visible finding lines across the whole
#                    Findings section (and across the delta comment).
#   EXCERPT_LEN      max chars of body_excerpt per visible line.
#   PER_REPO_VISIBLE soft per-(severity,repo) cap so one noisy bucket
#                    cannot consume the whole global budget.
MAX_VISIBLE="${SWEEP_MAX_VISIBLE:-60}"
EXCERPT_LEN="${SWEEP_EXCERPT_LEN:-120}"
PER_REPO_VISIBLE="${SWEEP_PER_REPO_VISIBLE:-8}"

if [ -n "${SWEEP_TODAY:-}" ]; then
  TODAY="$SWEEP_TODAY"
else
  TODAY=$(date -u '+%Y-%m-%d')
fi

# ---------------------------------------------------------------------------
# Read NDJSON into a working file. We need to make two passes (counts
# + body render + delta-detect), so a tmp file is simpler than
# re-reading stdin.
# ---------------------------------------------------------------------------
WORKDIR=$(mktemp -d "${TMPDIR:-/tmp}/sweep-render.XXXXXX")
trap 'rm -rf "$WORKDIR"' EXIT

NDJSON="$WORKDIR/findings.ndjson"
if [ "$INPUT" = "/dev/stdin" ] || [ "$INPUT" = "-" ]; then
  cat > "$NDJSON"
else
  cp "$INPUT" "$NDJSON"
fi

# Validate each line is JSON before going further.
LINE_COUNT=0
while IFS= read -r line; do
  [ -z "$line" ] && continue
  if ! printf '%s' "$line" | jq -e . >/dev/null 2>&1; then
    echo "render: malformed JSON line in input (line $((LINE_COUNT + 1)))" >&2
    exit 1
  fi
  LINE_COUNT=$((LINE_COUNT + 1))
done < "$NDJSON"

echo "render: $LINE_COUNT findings ingested" >&2

# ---------------------------------------------------------------------------
# Sorted thread-id list (used for the idempotency marker AND for delta
# detection against the prior body).
# ---------------------------------------------------------------------------
SORTED_IDS="$WORKDIR/sorted-ids.txt"
if [ "$LINE_COUNT" -gt 0 ]; then
  jq -r '.thread_id' "$NDJSON" | sort -u > "$SORTED_IDS"
else
  : > "$SORTED_IDS"
fi

CONTENT_HASH=$(_hash < "$SORTED_IDS")
echo "render: content hash = $CONTENT_HASH" >&2

# ---------------------------------------------------------------------------
# Build the bounded "## Findings" section into a file (#397). Ordered
# severity-major (P0,P1,P2,P3,Unknown) so the most important findings are
# emitted first and are never the ones truncated; within a severity,
# repos by descending count. A global visible-line budget (MAX_VISIBLE)
# bounds the rendered bytes regardless of total finding count N — the
# complete set always lives in the NDJSON workflow artifact and the
# hidden thread-id marker block. Built in a file (not a pipe) so the
# REMAINING/SHOWN_TOTAL counters survive (a piped `while` subshells them
# away under bash 3.2).
# ---------------------------------------------------------------------------
FINDINGS_MD="$WORKDIR/findings.md"
: > "$FINDINGS_MD"
if [ "$LINE_COUNT" -gt 0 ]; then
  # Ordered bucket list: "<sev>\t<count>\t<repo>".
  BUCKETS="$WORKDIR/buckets.txt"
  : > "$BUCKETS"
  for sev in P0 P1 P2 P3 Unknown; do
    jq -r --arg s "$sev" 'select(.severity == $s) | .repo' "$NDJSON" \
      | sort | uniq -c | sort -k1,1nr -k2,2 \
      | while read -r c r; do
          [ -n "$r" ] && printf '%s\t%s\t%s\n' "$sev" "$c" "$r"
        done >> "$BUCKETS"
  done

  {
    echo "## Findings"
    echo ""
    # Headline per-severity totals so the reader sees the full shape even
    # when individual buckets are truncated.
    printf 'Severity totals — '
    sev_first=1
    for sev in P0 P1 P2 P3 Unknown; do
      sc=$(jq -r --arg s "$sev" 'select(.severity == $s) | .thread_id' "$NDJSON" | wc -l | tr -d ' ')
      [ "$sev_first" -eq 1 ] || printf ' · '
      printf '%s: %s' "$sev" "$sc"
      sev_first=0
    done
    printf '  (showing at most %s items inline; full list in the workflow artifact)\n' "$MAX_VISIBLE"
    echo ""

    REMAINING="$MAX_VISIBLE"
    SHOWN_TOTAL=0
    while IFS="$(printf '\t')" read -r sev bucket_count repo; do
      [ -z "$repo" ] && continue
      [ "$REMAINING" -le 0 ] && break
      show="$bucket_count"
      [ "$show" -gt "$PER_REPO_VISIBLE" ] && show="$PER_REPO_VISIBLE"
      [ "$show" -gt "$REMAINING" ] && show="$REMAINING"
      echo "<details>"
      echo "<summary>$sev — $repo ($bucket_count, showing $show)</summary>"
      echo ""
      # Write to a file then `head` the file — piping `jq | head` would
      # SIGPIPE jq when head closes early, and `set -o pipefail` + `set -e`
      # would abort the whole render (the #397-adjacent footgun).
      jq -r --arg r "$repo" --arg s "$sev" --argjson len "$EXCERPT_LEN" '
        select(.repo == $r and .severity == $s)
        | "- [#\(.pr_number) · \((.pr_title // "(no title)")[0:80])](\(.thread_url)) — `\(.author_login)`: \((.body_excerpt // "")[0:$len])"
      ' "$NDJSON" > "$WORKDIR/bucket-lines.txt"
      head -n "$show" "$WORKDIR/bucket-lines.txt"
      if [ "$bucket_count" -gt "$show" ]; then
        printf -- '- _+%s more in this group — full list in the workflow artifact._\n' "$((bucket_count - show))"
      fi
      echo ""
      echo "</details>"
      echo ""
      REMAINING=$((REMAINING - show))
      SHOWN_TOTAL=$((SHOWN_TOTAL + show))
    done < "$BUCKETS"

    if [ "$SHOWN_TOTAL" -lt "$LINE_COUNT" ]; then
      printf '> **+%s more findings not shown above.** Full enumeration (all %s threads, every severity) is in the workflow artifact **sweep-findings-%s** (NDJSON, see #236).\n' \
        "$((LINE_COUNT - SHOWN_TOTAL))" "$LINE_COUNT" "${GITHUB_RUN_ID:-<run>}"
      echo ""
    fi
  } > "$FINDINGS_MD"
fi

# Render the body. Per-repo aggregate counts, then the bounded Findings
# section assembled above.
BODY="$WORKDIR/body.md"
{
  echo "<!-- sweep-unresolved-feedback v2 -->"
  echo "<!-- content-hash: $CONTENT_HASH -->"
  echo "<!-- last-run: $TODAY -->"
  echo ""
  echo "# Unresolved reviewer feedback backlog"
  echo ""
  echo "Automated weekly sweep — see #236. Last run **$TODAY** found **$LINE_COUNT** unresolved review threads on closed PRs across configured target repos."
  echo ""
  echo "**Counts below are raw (pre-validation).** A separate validation pass (see issue rubric in #236) is required to classify each item as VALID / ALREADY-FIXED / REJECTED / MOOT / AMBIGUOUS before treating the count as actionable backlog."
  echo ""
  echo "Lookback window: closed PRs in the last \`SWEEP_LOOKBACK_DAYS\` days (default 90)."
  echo ""

  if [ "$LINE_COUNT" -eq 0 ]; then
    echo "## No unresolved threads found"
    echo ""
    echo "All scanned repos came back clean. Either the merge gate is doing its job, the lookback window expired everything, or all target repos are quiet."
  else
    echo "## By repo"
    echo ""
    # Per-repo aggregate counts.
    jq -r '.repo' "$NDJSON" | sort -u | while IFS= read -r repo; do
      [ -z "$repo" ] && continue
      n=$(jq -r --arg r "$repo" 'select(.repo == $r) | .thread_id' "$NDJSON" | wc -l | tr -d ' ')
      printf -- '- **%s** — %s items\n' "$repo" "$n"
    done
    echo ""

    cat "$FINDINGS_MD"
  fi
} > "$BODY"

# ---------------------------------------------------------------------------
# Append the hidden thread-id marker block. Both the create path AND
# the edit path emit it so delta detection on the next run can diff
# against a complete prior id set. Without this on create, the first
# subsequent run with content changes would treat every existing
# thread as "new" because PRIOR_IDS would parse as empty (see #254
# Codex P2 finding).
# ---------------------------------------------------------------------------
# Marker budget (#397, Codex P2 on #399). The marker is the load-bearing
# delta state and MUST carry the COMPLETE id set (dropping any reintroduces
# the #254 regression). It is also the only body term that grows with N
# once Findings are capped. Rather than merely WARN and still post an
# over-limit body (which would deterministically fail at gh create/edit —
# the exact bug this PR fixes), we HARD-bound the marker to the bytes left
# under the cap after the rendered body, and on the (only at >~4500-id)
# overflow drop the tail with a `thread-ids-truncated` sentinel. That is a
# self-healing soft degradation (next run re-reports the dropped ids as
# "new") instead of a hard crash. SWEEP_MARKER_MAX_BYTES overrides the
# computed budget (used by tests to exercise the truncation path).
PRE_MARKER_BYTES=$(wc -c < "$BODY" | tr -d ' ')
MARKER_MAX_BYTES="${SWEEP_MARKER_MAX_BYTES:-$(( 65000 - PRE_MARKER_BYTES - 200 ))}"
[ "$MARKER_MAX_BYTES" -lt 0 ] && MARKER_MAX_BYTES=0

{
  cat "$BODY"
  echo ""
  echo "<!-- thread-ids-begin -->"
  # Compact, chunked encoding: ids are space-joined, ~40 per comment line,
  # instead of one comment per id (~13 B/id vs ~38, ~3x headroom). Emission
  # stops once MARKER_MAX_BYTES is reached, appending a truncated sentinel.
  # The reader below accepts this chunk form, the truncated sentinel, AND
  # the legacy v1 per-line form, so an old body stays delta-diffable.
  if [ -s "$SORTED_IDS" ]; then
    awk -v budget="$MARKER_MAX_BYTES" '
      BEGIN { used = 0; c = 0; buf = ""; trunc = 0 }
      NF {
        if (trunc) next
        cost = length($0) + 1
        # +45 amortizes the "<!-- thread-ids-chunk:  -->\n" framing per line.
        if (used + cost + 45 > budget) { trunc = 1; next }
        buf = (buf == "" ? $0 : buf " " $0); c++; used += cost
        if (c == 40) { print "<!-- thread-ids-chunk: " buf " -->"; used += 45; buf = ""; c = 0 }
      }
      END {
        if (buf != "") print "<!-- thread-ids-chunk: " buf " -->"
        if (trunc) print "<!-- thread-ids-truncated -->"
      }
    ' "$SORTED_IDS"
  fi
  echo "<!-- thread-ids-end -->"
} > "$BODY.with-marker"
mv "$BODY.with-marker" "$BODY"

# Belt-and-suspenders: the budget guard above keeps the body under the cap
# for any N, so this should never fire — if it does, it is a real alarm.
BODY_BYTES=$(wc -c < "$BODY" | tr -d ' ')
if [ "$BODY_BYTES" -gt 65536 ]; then
  echo "render: WARNING body is ${BODY_BYTES} bytes, still over GitHub's 65536-byte cap (findings=$LINE_COUNT) despite bounding — investigate before relying on this run." >&2
fi
if grep -q '<!-- thread-ids-truncated -->' "$BODY" 2>/dev/null; then
  echo "render: NOTE thread-id marker truncated to fit the 65536-byte cap (findings=$LINE_COUNT); delta state is partial this run and self-heals next run." >&2
fi

# ---------------------------------------------------------------------------
# Dry-run short-circuit. Print the body and exit. Tests use this.
# ---------------------------------------------------------------------------
if [ -n "${SWEEP_DRY_RUN:-}" ]; then
  echo "render: SWEEP_DRY_RUN=1 — printing body to stdout and exiting 0" >&2
  cat "$BODY"
  exit 0
fi

# ---------------------------------------------------------------------------
# Find existing rollup issue. Match on label `post-review` AND title
# prefix. Take the most recent open match.
# ---------------------------------------------------------------------------
EXISTING_JSON=$(gh issue list \
  --repo "$TARGET_REPO" \
  --state open \
  --label post-review \
  --search "$TITLE_PREFIX in:title" \
  --json number,title,body \
  --limit 20 2>/dev/null || echo "[]")

EXISTING_NUMBER=$(printf '%s' "$EXISTING_JSON" | jq -r --arg p "$TITLE_PREFIX" '
  [ .[] | select(.title | startswith($p)) ] | (.[0].number // empty)
')

if [ -z "$EXISTING_NUMBER" ]; then
  echo "render: no existing rollup issue found — creating new one" >&2
  NEW_TITLE="$TITLE_PREFIX — $TODAY"
  if ! gh issue create \
    --repo "$TARGET_REPO" \
    --title "$NEW_TITLE" \
    --label post-review \
    --body-file "$BODY" >&2; then
    echo "render: gh issue create failed" >&2
    exit 2
  fi
  echo "render: created new rollup issue" >&2
  exit 0
fi

echo "render: found existing rollup issue #$EXISTING_NUMBER" >&2

# Extract the prior content-hash marker. If unchanged, no-op.
PRIOR_BODY=$(printf '%s' "$EXISTING_JSON" | jq -r --arg n "$EXISTING_NUMBER" '
  [ .[] | select((.number|tostring) == $n) ] | .[0].body // ""
')
PRIOR_HASH=$(printf '%s' "$PRIOR_BODY" | sed -nE 's|.*<!-- content-hash: ([a-f0-9]+) -->.*|\1|p' | head -1)

if [ -n "$PRIOR_HASH" ] && [ "$PRIOR_HASH" = "$CONTENT_HASH" ]; then
  echo "render: content unchanged since prior run (hash $CONTENT_HASH) — no-op" >&2
  exit 0
fi

# Delta detection: extract the prior sorted thread-id list from the
# hidden marker block. Accepts BOTH the v2 compact chunk form
# (`<!-- thread-ids-chunk: id1 id2 ... -->`) and the legacy v1 per-line
# form (`<!-- <id> -->`), so a body written by the old script is still
# delta-diffable on the first v2 run (#397).
PRIOR_IDS="$WORKDIR/prior-ids.txt"
printf '%s' "$PRIOR_BODY" | awk '
  /<!-- thread-ids-begin -->/ { capture=1; next }
  /<!-- thread-ids-end -->/   { capture=0 }
  capture==1 {
    line = $0
    if (line ~ /thread-ids-truncated/) { next }
    if (line ~ /thread-ids-chunk:/) {
      sub(/.*thread-ids-chunk:[[:space:]]*/, "", line)
      sub(/[[:space:]]*-->.*/, "", line)
      n = split(line, ids, /[[:space:]]+/)
      for (i = 1; i <= n; i++) if (ids[i] != "") print ids[i]
    } else {
      sub(/^<!--[[:space:]]*/, "", line)
      sub(/[[:space:]]*-->.*/, "", line)
      if (line != "") print line
    }
  }
' | sort -u > "$PRIOR_IDS" || true

NEW_IDS="$WORKDIR/new-ids.txt"
comm -23 "$SORTED_IDS" "$PRIOR_IDS" > "$NEW_IDS" 2>/dev/null || true

RESOLVED_IDS="$WORKDIR/resolved-ids.txt"
comm -13 "$SORTED_IDS" "$PRIOR_IDS" > "$RESOLVED_IDS" 2>/dev/null || true

NEW_COUNT=$(wc -l < "$NEW_IDS" | tr -d ' ')
RESOLVED_COUNT=$(wc -l < "$RESOLVED_IDS" | tr -d ' ')

# The thread-id marker block was already appended to $BODY above,
# before the dry-run short-circuit, so both the create and edit
# paths post bodies that the next run can delta against.

# Update the body in place.
echo "render: updating issue #$EXISTING_NUMBER body (new=$NEW_COUNT, resolved=$RESOLVED_COUNT)" >&2
if ! gh issue edit "$EXISTING_NUMBER" \
  --repo "$TARGET_REPO" \
  --body-file "$BODY" >&2; then
  echo "render: gh issue edit failed" >&2
  exit 2
fi

# Post the delta comment if there are new items. Resolved-only changes
# update the body but don't get a comment — that's informational.
if [ "$NEW_COUNT" -gt 0 ]; then
  COMMENT="$WORKDIR/comment.md"
  {
    echo "## Sweep delta — $TODAY"
    echo ""
    echo "**$NEW_COUNT new** unresolved thread(s) since the last sweep. **$RESOLVED_COUNT** prior thread(s) cleared (resolved, marked outdated, or PR deleted)."
    echo ""
    echo "### New items"
    echo ""
    # Bound the comment to MAX_VISIBLE lines with truncated excerpts so a
    # large new-item batch can't exceed GitHub's 65536-byte comment cap
    # (#397). The full set is always in the workflow artifact.
    shown=0
    while IFS= read -r tid; do
      [ -z "$tid" ] && continue
      [ "$shown" -ge "$MAX_VISIBLE" ] && break
      jq -r --arg t "$tid" --argjson len "$EXCERPT_LEN" '
        select(.thread_id == $t)
        | "- **\(.repo) #\(.pr_number)** · `\(.severity)` · [\((.pr_title // "(no title)")[0:80])](\(.thread_url)) — `\(.author_login)`: \((.body_excerpt // "")[0:$len])"
      ' "$NDJSON"
      shown=$((shown + 1))
    done < "$NEW_IDS"
    if [ "$NEW_COUNT" -gt "$MAX_VISIBLE" ]; then
      printf '\n> **+%s more new items not shown above.** Full enumeration is in the workflow artifact **sweep-findings-%s** (NDJSON, see #236).\n' \
        "$((NEW_COUNT - MAX_VISIBLE))" "${GITHUB_RUN_ID:-<run>}"
    fi
  } > "$COMMENT"

  if ! gh issue comment "$EXISTING_NUMBER" \
    --repo "$TARGET_REPO" \
    --body-file "$COMMENT" >&2; then
    echo "render: gh issue comment failed" >&2
    exit 2
  fi
  echo "render: posted delta comment ($NEW_COUNT new items)" >&2
fi

exit 0
