#!/usr/bin/env bash
# scripts/wave-audit.sh — one scoped, automated external review per
# propagation wave (#662).
#
# A --sync-all wave opens verbatim-mirror PRs on every consumer. Their
# content is already source-reviewed (every line landed via a reviewed
# mergepath PR) and byte-verified by the propagation lane, so per-consumer
# bot review of the same bytes N times adds cost, quota risk, and
# choreography without adding signal (#662 has the measurements). This
# helper replaces it with ONE review, run against the wave CANARY PR,
# scoped to the canonical range that has not been audited before:
#
#   base = newest wave-audit-pass/<sha> tag that is an ancestor of the wave
#          head (--base <sha> on the first audited wave)
#   head = the mergepath sha in the canary PR BRANCH name
#          (mergepath-sync/[sync-all-]<sha> — what the lane verifies; a
#          parseable title must agree or the run fails closed), or --head-sha
#   diff = git diff base..head -- <manifest paths minus excluded prefixes>
#
# dispatched through scripts/phase-4b-review.sh with --diff-file. A curated
# diff is also the only workable input: `gh pr diff` refuses wave-sized sync
# PRs outright (HTTP 406 above 20k lines), so the orchestrator's own fetch
# path cannot ingest them.
#
# Verdict contract — fix at the SOURCE, never in the mirror:
#   exit 0  APPROVED posted on the canary. The wave-audit-pass/<head>
#           watermark tag is created and pushed; fan out. Fan-out mirrors
#           merge on consumer CI + lane byte-verification only (open them
#           with sync-to-downstream.sh --coderabbit-ignore and post no
#           @codex trigger on them).
#   exit 1  CHANGES_REQUESTED posted. Fix at the mergepath source, re-cut
#           the wave (--recreate-existing), re-run the audit on the fresh
#           canary. The superseded canary PR takes the blocking review with
#           it, so no review-dismissal choreography is needed.
#   exit 4/5  reviewer unavailable (adapter error, timeout, quota, or
#           automation disabled). NO tag is written. The wave may proceed
#           fail-open on CI + lane; the un-audited range chains into the
#           NEXT wave audit automatically, because the watermark only
#           advances on a posted APPROVED (or a scope-empty range).
#   exit 3  fail-closed, never fan out on this: usage/config error, a canary
#           whose head is not lane-verified (#663 P1 — the range-scoped
#           APPROVED is only sound over a byte-verified mirror), or an
#           orchestrator infrastructure failure (its exit 3, which includes
#           a failed review POST — no reliable verdict exists).
#
# Usage:
#   scripts/wave-audit.sh <canary-pr> --repo <owner/repo>
#       [--base <sha>] [--head-sha <sha>] [--dry-run]
#   scripts/wave-audit.sh --parse-title-only "<pr title>"   # test/debug hook
#
# Config: top-level `propagation_audit:` block in .github/review-policy.yml
# (hub-side only — this script and its block are deliberately NOT in
# .mergepath-sync.yml). Fields, with defaults when absent:
#   effort: high                 # codex set: minimal|low|medium|high|xhigh
#   timeout_seconds: 900         # [1, 3600]
#   diff_max_bytes: 800000       # [4096, 10485760]
#   scope_exclude_prefixes:      # manifest path prefixes skipped in the diff
#     - tests/
#     - docs/
# Invalid values fail closed (exit 3). Measured basis for the defaults
# (#662): xhigh DNFs the 900s adapter cap on a catch-up-sized wave diff,
# while high cleared the same 745 KB diff in 231s; steady-state wave ranges
# are ~70 KB and fit trivially.
#
# Env (tests / manual runs):
#   WAVE_AUDIT_REPO_DIR       canonical repo to diff/tag (default: this repo)
#   WAVE_AUDIT_MANIFEST_RELPATH  manifest path relative to the repo root,
#                             read from committed trees (audited head +
#                             audit base), never the working tree
#                             (default: .mergepath-sync.yml)
#   WAVE_AUDIT_ORCHESTRATOR   orchestrator (default: scripts/phase-4b-review.sh)
#   WAVE_AUDIT_LANE_VERIFIED_OK=1  skip the canary lane precondition —
#                             hermetic tests only, never operational runs
#   MERGEPATH_REVIEW_POLICY_PATH  policy file override (p4b convention)

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_DIR="${WAVE_AUDIT_REPO_DIR:-$ROOT}"
MANIFEST_RELPATH="${WAVE_AUDIT_MANIFEST_RELPATH:-.mergepath-sync.yml}"
POLICY="${MERGEPATH_REVIEW_POLICY_PATH:-$REPO_DIR/.github/review-policy.yml}"
ORCH="${WAVE_AUDIT_ORCHESTRATOR:-$ROOT/scripts/phase-4b-review.sh}"
TAG_PREFIX="wave-audit-pass"

log() { printf '[wave-audit] %s\n' "$*" >&2; }
die() { local rc="$1"; shift; printf '[wave-audit] ERROR: %s\n' "$*" >&2; exit "$rc"; }

usage() {
  sed -n '2,45p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

# parse_title <title> — print the mergepath sha a sync PR title names.
# Tolerates suffixes ("... (ready)") and any prefix wording; first match wins.
parse_title() {
  local sha
  sha="$(printf '%s\n' "$1" | sed -n 's/.*mergepath@\([0-9a-f]\{7,40\}\).*/\1/p' | head -n 1)"
  [ -n "$sha" ] || return 1
  printf '%s\n' "$sha"
}

# audit_field <field> — scalar under the top-level `propagation_audit:`
# block. Same nesting-aware walk as p4b_automation_field (only direct
# children match; deeper keys are skipped), same quote/comment stripping.
audit_field() {
  [ -f "$POLICY" ] || return 0
  awk -v field="$1" '
    /^propagation_audit:/ { inblk=1; child_indent=-1; next }
    inblk && /^[^[:space:]#]/ { inblk=0 }
    inblk {
      if ($0 ~ /^[[:space:]]*(#|$)/) next
      indent = match($0, /[^[:space:]]/) - 1
      if (child_indent < 0) child_indent = indent
      if (indent > child_indent) next
      if ($1 == field":") {
        sub(/^[[:space:]]*[^:]+:[[:space:]]*/, "", $0)
        gsub(/^["\047]/, "", $0)
        gsub(/["\047][[:space:]]*(#.*)?$/, "", $0)
        gsub(/[[:space:]]*#.*$/, "", $0)
        sub(/[[:space:]]+$/, "", $0)
        print; exit
      }
    }
  ' "$POLICY"
}

# audit_list <field> — newline-separated items of a list field under the
# `propagation_audit:` block (the p4b_diff_omit_globs parsing pattern).
audit_list() {
  [ -f "$POLICY" ] || return 0
  awk -v field="$1" '
    /^propagation_audit:/ { inblk=1; inlist=0; next }
    inblk && /^[^[:space:]#]/ { inblk=0; inlist=0 }
    inblk {
      if ($0 ~ /^[[:space:]]*(#|$)/) next
      if ($0 ~ ("^[[:space:]]*" field ":[[:space:]]*$")) { inlist=1; next }
      if (inlist) {
        if ($0 ~ /^[[:space:]]*-[[:space:]]*/) {
          line = $0
          sub(/^[[:space:]]*-[[:space:]]*/, "", line)
          gsub(/[[:space:]]*#.*$/, "", line)
          gsub(/^["\047]/, "", line); gsub(/["\047][[:space:]]*$/, "", line)
          sub(/[[:space:]]+$/, "", line)
          if (line != "") print line
          next
        }
        inlist = 0
      }
    }
  ' "$POLICY"
}

# --- args -------------------------------------------------------------------
PR=""; REPO=""; BASE=""; HEAD_SHA=""; DRY_RUN=false
while [ $# -gt 0 ]; do
  case "$1" in
    --repo)      REPO="${2:-}"; shift 2 ;;
    --base)      BASE="${2:-}"; shift 2 ;;
    --head-sha)  HEAD_SHA="${2:-}"; shift 2 ;;
    --dry-run)   DRY_RUN=true; shift ;;
    --parse-title-only)
      parse_title "${2:-}" || die 3 "no mergepath@<sha> in title: ${2:-}"
      exit 0 ;;
    -h|--help)   usage; exit 0 ;;
    -*)          die 3 "unknown flag: $1" ;;
    *)
      [ -z "$PR" ] || die 3 "unexpected argument: $1"
      PR="$1"; shift ;;
  esac
done
[ -n "$PR" ] || { usage >&2; die 3 "canary PR number is required"; }
case "$PR" in ''|*[!0-9]*) die 3 "canary PR must be a number: $PR" ;; esac
[ -n "$REPO" ] || die 3 "--repo <owner/repo> is required"
[ -x "$ORCH" ] || [ -f "$ORCH" ] || die 3 "orchestrator not found: $ORCH"

# --- config (fail-closed validation) ----------------------------------------
EFFORT="$(audit_field effort)"; EFFORT="${EFFORT:-high}"
case "$EFFORT" in
  minimal|low|medium|high|xhigh) : ;;
  *) die 3 "invalid propagation_audit.effort '$EFFORT' (expected minimal|low|medium|high|xhigh)" ;;
esac
TIMEOUT="$(audit_field timeout_seconds)"; TIMEOUT="${TIMEOUT:-900}"
case "$TIMEOUT" in ''|*[!0-9]*) die 3 "invalid propagation_audit.timeout_seconds '$TIMEOUT'" ;; esac
{ [ "$TIMEOUT" -ge 1 ] && [ "$TIMEOUT" -le 3600 ]; } || die 3 "propagation_audit.timeout_seconds out of range [1,3600]: $TIMEOUT"
DIFF_MAX="$(audit_field diff_max_bytes)"; DIFF_MAX="${DIFF_MAX:-800000}"
case "$DIFF_MAX" in ''|*[!0-9]*) die 3 "invalid propagation_audit.diff_max_bytes '$DIFF_MAX'" ;; esac
{ [ "$DIFF_MAX" -ge 4096 ] && [ "$DIFF_MAX" -le 10485760 ]; } || die 3 "propagation_audit.diff_max_bytes out of range [4096,10485760]: $DIFF_MAX"
EXCLUDES="$(audit_list scope_exclude_prefixes)"
[ -n "$EXCLUDES" ] || EXCLUDES="$(printf 'tests/\ndocs/')"

# --- resolve the wave head ----------------------------------------------------
# The propagation lane derives and byte-verifies against the sha in the
# BRANCH NAME (mergepath-sync/[sync-all-]<sha>), not the title — an edited
# or stale title could point the audit (and the watermark) at canonical
# commits the lane never verified (#663 round-3 P1). The branch is the
# source of truth; a parseable title must agree with it.
PR_HEAD_OID=""
# Branch metadata is resolved whenever the run is OPERATIONAL (lane check
# active) — even under --head-sha (#663 round-4 P2): a typo or stale manual
# sha would otherwise dispatch and watermark a review for a different
# canonical range while the APPROVED lands on the lane-verified canary.
# Only the hermetic-test escape skips it (alongside the lane check).
need_meta=false
[ -z "$HEAD_SHA" ] && need_meta=true
[ "${WAVE_AUDIT_LANE_VERIFIED_OK:-0}" != "1" ] && need_meta=true
if [ "$need_meta" = true ]; then
  command -v gh >/dev/null 2>&1 || die 3 "gh is required to resolve the canary metadata (or pass --head-sha with WAVE_AUDIT_LANE_VERIFIED_OK=1 in hermetic tests)"
  meta="$(gh pr view "$PR" --repo "$REPO" --json title,headRefName,headRefOid --jq '[.title, .headRefName, .headRefOid] | @tsv' 2>/dev/null)" \
    || die 3 "could not read PR $REPO#$PR metadata"
  title="$(printf '%s' "$meta" | cut -f1)"
  branch="$(printf '%s' "$meta" | cut -f2)"
  PR_HEAD_OID="$(printf '%s' "$meta" | cut -f3)"
  branch_sha="$(printf '%s\n' "$branch" | sed -n 's|.*/\(sync-all-\)\{0,1\}\([0-9a-f]\{7,40\}\)$|\2|p')"
  [ -n "$branch_sha" ] || die 3 "canary branch '$branch' does not carry the mergepath-sync/<sha> shape — not a lane-verifiable sync canary"
  if [ -z "$HEAD_SHA" ]; then
    HEAD_SHA="$branch_sha"
    # The lane derives + verifies against the BRANCH sha; a parseable
    # title must agree with it (#663 round-3 P1).
    title_sha="$(parse_title "$title" || true)"
    if [ -n "$title_sha" ]; then
      t_full="$(git -C "$REPO_DIR" rev-parse --verify --quiet "${title_sha}^{commit}" || true)"
      b_full="$(git -C "$REPO_DIR" rev-parse --verify --quiet "${branch_sha}^{commit}" || true)"
      if [ -n "$t_full" ] && [ -n "$b_full" ] && [ "$t_full" != "$b_full" ]; then
        die 3 "canary title names mergepath@$title_sha but the lane-verified branch names $branch_sha — refusing to audit a mismatched wave"
      fi
    fi
  else
    h_full="$(git -C "$REPO_DIR" rev-parse --verify --quiet "${HEAD_SHA}^{commit}" || true)"
    b_full="$(git -C "$REPO_DIR" rev-parse --verify --quiet "${branch_sha}^{commit}" || true)"
    if [ -z "$h_full" ] || [ -z "$b_full" ] || [ "$h_full" != "$b_full" ]; then
      die 3 "--head-sha $HEAD_SHA does not match the canary branch sha $branch_sha — refusing to audit a range the lane did not verify"
    fi
  fi
fi
HEAD_FULL="$(git -C "$REPO_DIR" rev-parse --verify --quiet "${HEAD_SHA}^{commit}")" \
  || die 3 "wave head $HEAD_SHA not found in $REPO_DIR — git fetch first"

# --- canary lane precondition (#663 Codex P1) ----------------------------------
# The audit reviews the curated CANONICAL range, and the APPROVED it posts
# clears the canary via the Phase 4b substitute path (codex-review-check
# gate). That is sound ONLY because the propagation lane has byte-verified
# the canary PR content == mergepath@head — dispatching against a canary
# whose current head is NOT lane-verified would let a non-faithful sync PR
# clear external review without its actual PR diff ever being reviewed.
# Fail closed unless the canary head carries the head-pinned trusted lane
# marker (the same github-actions[bot] marker merge-clearance-gate.sh keys
# on). WAVE_AUDIT_LANE_VERIFIED_OK=1 overrides — hermetic tests only.
pr_head=""
if [ "${WAVE_AUDIT_LANE_VERIFIED_OK:-0}" != "1" ]; then
  command -v gh >/dev/null 2>&1 || die 3 "gh is required for the lane-verification precondition"
  if [ -n "$PR_HEAD_OID" ]; then
    pr_head="$PR_HEAD_OID"
  else
    pr_head="$(gh pr view "$PR" --repo "$REPO" --json headRefOid --jq .headRefOid 2>/dev/null)" \
      || die 3 "could not read PR $REPO#$PR head for lane verification"
  fi
  [ -n "$pr_head" ] || die 3 "empty PR head reading $REPO#$PR for lane verification"
  lane_comments="$(gh api --paginate "repos/$REPO/issues/$PR/comments" 2>/dev/null | jq -s 'add // []' 2>/dev/null)" \
    || die 3 "could not read canary PR comments for lane verification"
  printf '%s' "$lane_comments" | jq -e --arg head "$pr_head" '
    any(.[]; (.user.login == "github-actions[bot]")
         and ((.body // "") | contains("mergepath-propagation-lane verified-head=" + $head)))' >/dev/null 2>&1 \
    || die 3 "canary $REPO#$PR head $pr_head is not lane-verified (no head-pinned mergepath-propagation-lane marker) — wait for the External Review Check lane run or investigate a diverged canary; refusing to dispatch"
  log "canary lane verified for PR head $pr_head"
fi

# --- resolve the audit base (chaining watermark) ------------------------------
if [ -z "$BASE" ]; then
  # The pushed tag is what lets EVERY checkout resolve the same base, so
  # refresh the namespace from origin before selecting (#663 round-4 P2):
  # a fresh clone or another machine otherwise picks an older base
  # (re-reviewing cleared ranges), finds none, or mints a conflicting
  # local tag object on rerun. Remote wins (forced refspec).
  git -C "$REPO_DIR" fetch -q origin "+refs/tags/${TAG_PREFIX}/*:refs/tags/${TAG_PREFIX}/*" 2>/dev/null \
    || die 3 "could not fetch ${TAG_PREFIX}/* tags from origin — the audit base must resolve against the shared watermark namespace (pass --base to pin explicitly)"
  # Newest = maximal in ancestry order, not newest by commit time: on a
  # candidate set where A is an ancestor of B, rev-list --count(B) is
  # strictly greater, and commit timestamps can tie (or even invert under
  # rebases), which would silently widen the range back over audited
  # content.
  best=""; best_n=0
  for t in $(git -C "$REPO_DIR" tag -l "${TAG_PREFIX}/*"); do
    sha="${t#"${TAG_PREFIX}"/}"
    git -C "$REPO_DIR" rev-parse --verify --quiet "${sha}^{commit}" >/dev/null || continue
    git -C "$REPO_DIR" merge-base --is-ancestor "$sha" "$HEAD_FULL" 2>/dev/null || continue
    n="$(git -C "$REPO_DIR" rev-list --count "$sha")"
    if [ "$n" -gt "$best_n" ]; then best="$sha"; best_n="$n"; fi
  done
  BASE="$best"
fi
[ -n "$BASE" ] || die 3 "no ${TAG_PREFIX}/* watermark is an ancestor of $HEAD_SHA and no --base was given — pass --base <sha> for the first audited wave"
BASE_FULL="$(git -C "$REPO_DIR" rev-parse --verify --quiet "${BASE}^{commit}")" \
  || die 3 "audit base $BASE not found in $REPO_DIR"
git -C "$REPO_DIR" merge-base --is-ancestor "$BASE_FULL" "$HEAD_FULL" 2>/dev/null \
  || die 3 "audit base $BASE is not an ancestor of wave head $HEAD_SHA"

# --- build the curated diff ---------------------------------------------------
# Manifest source paths (two-space `- path:` entries), minus excluded
# prefixes. The manifest is read from COMMITTED TREES — the audited head for
# the authoritative scope, the audit base for the scope-delta — never the
# working tree, so the scope matches what the canary actually propagated
# even when the local checkout has moved past (or has uncommitted edits to)
# the manifest (Codex P2 on #663). Excluded content is still delivered and
# still CI-validated on every consumer; it is only out of AUDIT scope.
manifest_paths_at() { # manifest_paths_at <commit> — raw manifest source paths
  git -C "$REPO_DIR" show "${1}:${MANIFEST_RELPATH}" 2>/dev/null \
    | awk '/^  - path: /{print $3}' | sort -u
}
in_scope() { # filter stdin paths through scope_exclude_prefixes
  local p ex skip
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    skip=false
    while IFS= read -r ex; do
      [ -n "$ex" ] || continue
      case "$p" in "$ex"*) skip=true; break ;; esac
    done <<EOF
$EXCLUDES
EOF
    [ "$skip" = true ] || printf '%s\n' "$p"
  done
}
head_scope="$(manifest_paths_at "$HEAD_FULL" | in_scope)"
base_scope="$(manifest_paths_at "$BASE_FULL" | in_scope || true)"

# Split head scope into paths already manifested at base (range-diffed) and
# NEWLY-MANIFESTED paths (Codex P2 on #663): a wave that adds a pre-existing
# file/dir to the manifest newly delivers those bytes to consumers, but
# `git diff base..head` is empty for content that predates the range — so
# newly in-scope paths are diffed against the EMPTY TREE for full-content
# review. Paths REMOVED from the manifest deliver nothing new and are not
# audited. A manifest absent at base makes every head path newly in scope.
common=(); added=()
while IFS= read -r p; do
  [ -n "$p" ] || continue
  if printf '%s\n' "$base_scope" | grep -Fxq "$p"; then
    common[${#common[@]}]="$p"
  else
    added[${#added[@]}]="$p"
  fi
done <<EOF
$head_scope
EOF
[ $(( ${#common[@]} + ${#added[@]} )) -gt 0 ] \
  || die 3 "no manifest paths remain in audit scope at ${HEAD_SHA} (check ${MANIFEST_RELPATH} at that commit and scope_exclude_prefixes)"

DIFF_FILE="$(mktemp "${TMPDIR:-/tmp}/wave-audit-diff.XXXXXX")"
trap 'rm -f "$DIFF_FILE"' EXIT
: > "$DIFF_FILE"
if [ "${#common[@]}" -gt 0 ]; then
  git -C "$REPO_DIR" diff "${BASE_FULL}..${HEAD_FULL}" -- "${common[@]}" >> "$DIFF_FILE"
fi
if [ "${#added[@]}" -gt 0 ]; then
  EMPTY_TREE="$(git -C "$REPO_DIR" hash-object -t tree /dev/null)"
  log "newly-manifested path(s) audited in full: ${added[*]}"
  git -C "$REPO_DIR" diff "$EMPTY_TREE" "$HEAD_FULL" -- "${added[@]}" >> "$DIFF_FILE"
fi
BYTES="$(wc -c < "$DIFF_FILE" | tr -d ' ')"
FILES="$(grep -c '^diff --git ' "$DIFF_FILE" || true)"

# advance_watermark — annotated (unsigned) tag on the audited head, pushed to
# origin so every checkout resolves the same base next wave. Only called on a
# posted APPROVED or a scope-empty range, never on --dry-run. A tag that
# already exists locally (e.g. a prior run whose PUSH failed) is not treated
# as success — the push runs unconditionally, so the documented rerun
# recovery actually recovers (Codex P2 on #663); pushing an already-present
# remote tag with the same object is a no-op success.
advance_watermark() {
  local tag="${TAG_PREFIX}/${HEAD_FULL}"
  if git -C "$REPO_DIR" rev-parse --verify --quiet "refs/tags/$tag" >/dev/null; then
    log "watermark $tag already present locally — ensuring it is on origin"
  else
    GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=tag.gpgsign GIT_CONFIG_VALUE_0=false \
      git -C "$REPO_DIR" tag -a "$tag" \
        -m "wave-audit: base=${BASE_FULL} canary=${REPO}#${PR} effort=${EFFORT} files=${FILES} bytes=${BYTES}" \
        "$HEAD_FULL"
  fi
  git -C "$REPO_DIR" push -q origin "refs/tags/$tag" \
    || die 3 "watermark tag $tag exists locally but the push failed — push it manually or rerun, or the next audit re-covers this range"
  log "watermark advanced: $tag"
}

emit_json() { # emit_json <orch_exit_or_null> <tagged> <skipped_reason_or_null>
  jq -n \
    --arg base "$BASE_FULL" --arg head "$HEAD_FULL" --arg repo "$REPO" \
    --argjson pr "$PR" --argjson files "$FILES" --argjson bytes "$BYTES" \
    --arg effort "$EFFORT" --argjson timeout "$TIMEOUT" \
    --argjson orch "$1" --argjson tagged "$2" --argjson skipped "$3" \
    --argjson dry "$([ "$DRY_RUN" = true ] && echo true || echo false)" \
    '{base:$base, head:$head, repo:$repo, pr:$pr, scope_files:$files,
      scope_bytes:$bytes, effort:$effort, timeout_seconds:$timeout,
      orchestrator_exit:$orch, watermark_advanced:$tagged, skipped:$skipped,
      dry_run:$dry}'
}

log "audit range ${BASE_FULL} .. ${HEAD_FULL} — ${FILES} file(s), ${BYTES} bytes in scope (effort=${EFFORT}, timeout=${TIMEOUT}s)"

if [ "$BYTES" -eq 0 ]; then
  # Only excluded-prefix (or no) content changed in the range: vacuously
  # clean. Advance the watermark so the next audit does not re-walk it.
  log "no in-scope changes — audit passes vacuously"
  if [ "$DRY_RUN" = true ]; then
    emit_json null false '"empty-scope"'
  else
    advance_watermark
    emit_json null true '"empty-scope"'
  fi
  exit 0
fi

# --- dispatch the scoped review ----------------------------------------------
# External P4B_* env wins over policy in the orchestrator (`:=` fill), so the
# audit profile applies without touching the phase_4b_automation gating lane.
# Both adapter directions get the audit effort (Codex P2 on #663: a
# codex-authored wave selects the Claude adapter, which reads
# P4B_CLAUDE_EFFORT) — except `minimal`, which only the codex CLI accepts;
# there the claude direction falls back to its configured gating-lane effort
# rather than failing closed on an invalid value.
orch_args=("$PR" --repo "$REPO" --diff-file "$DIFF_FILE")
# Pin the review to the lane-verified head (#663 round-3 P1): without
# --head, the orchestrator resolves the LIVE PR head at dispatch time, so a
# canary push racing the lane check above could get an APPROVED on a head
# the lane never verified. With the pin, the orchestrator's own live-head
# recheck fails closed on any drift.
if [ -n "$pr_head" ]; then
  orch_args[${#orch_args[@]}]="--head"
  orch_args[${#orch_args[@]}]="$pr_head"
fi
[ "$DRY_RUN" = true ] && orch_args[${#orch_args[@]}]="--dry-run"
if [ "$EFFORT" != "minimal" ]; then
  export P4B_CLAUDE_EFFORT="$EFFORT"
fi
set +e
P4B_CODEX_EFFORT="$EFFORT" \
P4B_ADAPTER_TIMEOUT_SECONDS="$TIMEOUT" \
P4B_DIFF_MAX_BYTES="$DIFF_MAX" \
  "$ORCH" "${orch_args[@]}"
orc=$?
set -e

case "$orc" in
  0)
    if [ "$DRY_RUN" = true ]; then
      log "dry-run APPROVED — watermark NOT advanced"
      emit_json 0 false null
    else
      advance_watermark
      emit_json 0 true null
      log "APPROVED posted — fan out (mirrors merge on CI + lane; open them with --coderabbit-ignore, no @codex trigger)"
    fi
    ;;
  1)
    emit_json 1 false null
    log "CHANGES_REQUESTED posted on ${REPO}#${PR} — fix at the mergepath source, re-cut the wave, re-run the audit on the fresh canary"
    ;;
  3)
    # Config/usage/infrastructure error — including a failed review POST
    # (Codex P2 on #663). No reliable verdict exists and the local setup or
    # the GitHub write path is broken: this is NOT a proceedable audit
    # miss, so do not suggest fanning out on it.
    emit_json 3 false null
    log "ERROR: orchestrator infrastructure/config failure (exit 3) — no verdict exists; fix the configuration or write path and rerun the audit before fanning out"
    ;;
  6)
    # #814 barrier hold: external review has not reached the canary head YET.
    # This is a transient wait that clears on its own, NOT an unavailable
    # reviewer, so it must not take the fail-open arm below — a canary is
    # audited moments after it opens, before either provider has read it, so
    # that arm would fire on the ordinary path and fan the wave out unaudited.
    emit_json 6 false null
    log "external review has not reached ${REPO}#${PR} yet (orchestrator exit 6) — no watermark; do NOT fan out, retry the audit after the retry_after in the orchestrator JSON above"
    ;;
  *)
    emit_json "$orc" false null
    log "reviewer unavailable (orchestrator exit $orc) — no watermark; the wave may proceed on CI + lane and this range chains into the next audit"
    ;;
esac
exit "$orc"
