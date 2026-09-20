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
#   exit 7  feedback unaccounted; no tag is written. Never fan out.
#           If the orchestrator JSON says review_posted:true, repair that
#           review's acknowledgment without repeating the review. Otherwise
#           disposition the earlier findings and rerun the same audit.
#   exit 8  curated diff exceeds the configured byte budget. No reviewer
#           is dispatched and no tag is written. Never fan out on this:
#           the range needs bounded review, not another unavailable retry.
#   exit 9  one historical chunk was validated and optionally retained as a
#           non-clearance prefix receipt. Never fan out: only an explicit
#           --finalize-historical run can produce ordinary exit 0 clearance.
#
# Usage:
#   scripts/wave-audit.sh <canary-pr> --repo <owner/repo>
#       [--base <sha>] [--head-sha <sha>] [--dry-run]
#       [--historical-end <sha> | --finalize-historical]
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
PREFIX_TAG_PREFIX="wave-audit-prefix"

log() { printf '[wave-audit] %s\n' "$*" >&2; }
die() { local rc="$1"; shift; printf '[wave-audit] ERROR: %s\n' "$*" >&2; exit "$rc"; }

usage() {
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "${BASH_SOURCE[0]}"
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
HISTORICAL_END=""; FINALIZE_HISTORICAL=false
while [ $# -gt 0 ]; do
  case "$1" in
    --repo)      REPO="${2:-}"; shift 2 ;;
    --base)      BASE="${2:-}"; shift 2 ;;
    --head-sha)  HEAD_SHA="${2:-}"; shift 2 ;;
    --dry-run)   DRY_RUN=true; shift ;;
    --historical-end) HISTORICAL_END="${2:-}"; shift 2 ;;
    --finalize-historical) FINALIZE_HISTORICAL=true; shift ;;
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
[ -z "$HISTORICAL_END" ] || [ "$FINALIZE_HISTORICAL" = false ] \
  || die 3 "--historical-end and --finalize-historical are mutually exclusive"
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
BASE_WATERMARK_TAG=""
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
    if [ "$n" -gt "$best_n" ]; then best="$sha"; best_n="$n"; BASE_WATERMARK_TAG="$t"; fi
  done
  BASE="$best"
fi
[ -n "$BASE" ] || die 3 "no ${TAG_PREFIX}/* watermark is an ancestor of $HEAD_SHA and no --base was given — pass --base <sha> for the first audited wave"
BASE_FULL="$(git -C "$REPO_DIR" rev-parse --verify --quiet "${BASE}^{commit}")" \
  || die 3 "audit base $BASE not found in $REPO_DIR"
git -C "$REPO_DIR" merge-base --is-ancestor "$BASE_FULL" "$HEAD_FULL" 2>/dev/null \
  || die 3 "audit base $BASE is not an ancestor of wave head $HEAD_SHA"

# Informational annotation time only: never substitute the commit date or
# treat this unsigned metadata as a review receipt. Explicit --base selects
# no tag. Missing/unreadable/invalid metadata leaves age unknown, without
# changing selection or the audit outcome; future timestamps have no age.
tagger_timestamp=""
if [ -n "$BASE_WATERMARK_TAG" ]; then
  tagger_timestamp="$(git -C "$REPO_DIR" for-each-ref --format='%(taggerdate:unix)' "refs/tags/$BASE_WATERMARK_TAG" 2>/dev/null)" \
    || tagger_timestamp=""
fi
observed_timestamp="$(date +%s 2>/dev/null)" || observed_timestamp=""
BASE_WATERMARK_JSON="$(jq -n --arg tag "$BASE_WATERMARK_TAG" \
  --arg tagged "$tagger_timestamp" --arg now "$observed_timestamp" '
    def epoch: if test("^[0-9]+$") then (try tonumber catch null) else null end;
    ($tagged | epoch) as $timestamp | ($now | epoch) as $observed |
    {tag: (if $tag == "" then null else $tag end), tagger_timestamp: $timestamp,
     age_seconds: (if $timestamp != null and $observed != null and $timestamp <= $observed
                   then $observed - $timestamp else null end)}')"
log "$(printf '%s' "$BASE_WATERMARK_JSON" | jq -r '
  "base watermark: tag=\(.tag // "unknown") tagger_timestamp=\(.tagger_timestamp // "unknown") age_seconds=\(.age_seconds // "unknown") (tag metadata only; not verified review freshness)"')"

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

[ -n "$head_scope" ] \
  || die 3 "no manifest paths remain in audit scope at ${HEAD_SHA} (check ${MANIFEST_RELPATH} at that commit and scope_exclude_prefixes)"

# Historical-prefix receipts are deliberately outside the clearance
# watermark namespace. They retain only clean, dry-run-validated coverage
# for one immutable intended head. Every binding below is recomputed from
# committed objects before a receipt can be reused.
MANIFEST_BLOB="$(git -C "$REPO_DIR" rev-parse --verify "${HEAD_FULL}:${MANIFEST_RELPATH}" 2>/dev/null)" \
  || die 3 "could not resolve ${MANIFEST_RELPATH} blob at intended head $HEAD_FULL"
SCOPE_FINGERPRINT="$(printf 'version=1\nbase=%s\nhead=%s\nmanifest=%s\nexcludes<<EOF\n%s\nEOF\nscope<<EOF\n%s\nEOF\n' \
  "$BASE_FULL" "$HEAD_FULL" "$MANIFEST_BLOB" "$EXCLUDES" "$head_scope" \
  | git -C "$REPO_DIR" hash-object --stdin)"

TMP_FILES=()
cleanup() {
  local cleanup_file
  for cleanup_file in "${TMP_FILES[@]}"; do rm -f "$cleanup_file"; done
}
trap cleanup EXIT
DIFF_FILE="$(mktemp "${TMPDIR:-/tmp}/wave-audit-diff.XXXXXX")"
TMP_FILES[${#TMP_FILES[@]}]="$DIFF_FILE"
RECEIPT_RECORDS="$(mktemp "${TMPDIR:-/tmp}/wave-audit-receipts.XXXXXX")"
RECEIPT_CHAIN="$(mktemp "${TMPDIR:-/tmp}/wave-audit-chain.XXXXXX")"
TMP_FILES[${#TMP_FILES[@]}]="$RECEIPT_RECORDS"
TMP_FILES[${#TMP_FILES[@]}]="$RECEIPT_CHAIN"
: > "$RECEIPT_RECORDS"; : > "$RECEIPT_CHAIN"

HISTORICAL=false
[ -n "$HISTORICAL_END" ] && HISTORICAL=true
[ "$FINALIZE_HISTORICAL" = true ] && HISTORICAL=true
PREFIX_BASE="$BASE_FULL"

if [ "$HISTORICAL" = true ]; then
  # Fetch remote receipts one exact ref at a time. A wildcard refspec with no
  # remote match can erase a local receipt left by a failed push, destroying
  # the idempotent publish-only retry path.
  remote_prefix_refs="$(git -C "$REPO_DIR" ls-remote --refs --tags origin \
    "refs/tags/${PREFIX_TAG_PREFIX}/*" 2>/dev/null)" \
    || die 3 "could not list ${PREFIX_TAG_PREFIX}/* receipts from origin"
  while IFS=$'\t' read -r _remote_oid remote_ref; do
    [ -n "$remote_ref" ] || continue
    git -C "$REPO_DIR" fetch -q origin "+${remote_ref}:${remote_ref}" 2>/dev/null \
      || die 3 "could not fetch prefix receipt $remote_ref from origin"
  done <<EOF
$remote_prefix_refs
EOF
  for receipt_tag in $(git -C "$REPO_DIR" tag -l "${PREFIX_TAG_PREFIX}/${HEAD_FULL}/*"); do
    receipt_json="$(git -C "$REPO_DIR" for-each-ref --format='%(contents)' "refs/tags/$receipt_tag")"
    printf '%s' "$receipt_json" | jq -e \
      --arg base "$BASE_FULL" --arg head "$HEAD_FULL" \
      --arg manifest "$MANIFEST_BLOB" --arg scope "$SCOPE_FINGERPRINT" '
        .version == 1 and .kind == "wave-audit-prefix" and .clearance == false and
        .initial_base == $base and .full_head == $head and
        .manifest_blob == $manifest and .scope_fingerprint == $scope and
        (.chunk_base | type == "string") and (.prefix_end | type == "string") and
        (.review_provenance.direction | type == "string" and length > 0) and
        (.review_provenance.reviewer_identity | type == "string" and length > 0) and
        (.review_provenance.canary_head | type == "string") and
        .validated_verdict.verdict == "APPROVED" and
        (.validated_verdict.findings | type == "array" and length == 0)' >/dev/null \
      || die 3 "prefix receipt $receipt_tag is incompatible with the pinned historical scope"
    receipt_base="$(printf '%s' "$receipt_json" | jq -r .chunk_base)"
    receipt_end="$(printf '%s' "$receipt_json" | jq -r .prefix_end)"
    [ "$receipt_tag" = "${PREFIX_TAG_PREFIX}/${HEAD_FULL}/${receipt_end}" ] \
      || die 3 "prefix receipt $receipt_tag does not use its recorded exact-head name"
    receipt_target="$(git -C "$REPO_DIR" rev-parse --verify "${receipt_tag}^{}" 2>/dev/null)" \
      || die 3 "could not peel prefix receipt $receipt_tag"
    [ "$receipt_target" = "$receipt_end" ] \
      || die 3 "prefix receipt $receipt_tag targets $receipt_target, not recorded end $receipt_end"
    [ "$receipt_base" != "$receipt_end" ] \
      || die 3 "prefix receipt $receipt_tag is not a strict forward range"
    git -C "$REPO_DIR" merge-base --is-ancestor "$receipt_base" "$receipt_end" 2>/dev/null \
      || die 3 "prefix receipt $receipt_tag is not a forward range"
    git -C "$REPO_DIR" merge-base --is-ancestor "$receipt_end" "$HEAD_FULL" 2>/dev/null \
      || die 3 "prefix receipt $receipt_tag ends outside intended head $HEAD_FULL"
    printf '%s\t%s\t%s\n' "$receipt_base" "$receipt_end" "$receipt_tag" >> "$RECEIPT_RECORDS"
  done

  # Build exactly one contiguous chain. Alternative or disconnected receipts
  # are ambiguity, never authority to skip a range.
  cursor="$BASE_FULL"; used=0
  while :; do
    matches="$(awk -F '\t' -v base="$cursor" '$1 == base { print }' "$RECEIPT_RECORDS")"
    match_count="$(printf '%s\n' "$matches" | awk 'NF { n++ } END { print n+0 }')"
    [ "$match_count" -le 1 ] || die 3 "multiple prefix receipts continue from $cursor"
    [ "$match_count" -eq 1 ] || break
    next_end="$(printf '%s\n' "$matches" | cut -f2)"
    next_tag="$(printf '%s\n' "$matches" | cut -f3)"
    git -C "$REPO_DIR" for-each-ref --format='%(contents)' "refs/tags/$next_tag" >> "$RECEIPT_CHAIN"
    printf '\n' >> "$RECEIPT_CHAIN"
    cursor="$next_end"; used=$((used + 1))
  done
  total="$(awk 'NF { n++ } END { print n+0 }' "$RECEIPT_RECORDS")"
  [ "$used" -eq "$total" ] || die 3 "prefix receipt set is disconnected from initial base $BASE_FULL"
  PREFIX_BASE="$cursor"
fi

if [ -n "$HISTORICAL_END" ]; then
  RANGE_HEAD="$(git -C "$REPO_DIR" rev-parse --verify --quiet "${HISTORICAL_END}^{commit}")" \
    || die 3 "historical end $HISTORICAL_END not found in $REPO_DIR"
  if [ "$RANGE_HEAD" = "$PREFIX_BASE" ]; then
    retained_tag="${PREFIX_TAG_PREFIX}/${HEAD_FULL}/${RANGE_HEAD}"
    retained_json="$(git -C "$REPO_DIR" for-each-ref --format='%(contents)' "refs/tags/$retained_tag")"
    [ -n "$retained_json" ] || die 3 "historical end equals retained prefix but exact receipt $retained_tag is missing"
    if [ "$DRY_RUN" = false ]; then
      git -C "$REPO_DIR" push -q origin "refs/tags/$retained_tag" \
        || die 3 "prefix receipt $retained_tag remains local because retry push failed"
    fi
    jq -n --arg base "$(printf '%s' "$retained_json" | jq -r .chunk_base)" \
      --arg end "$RANGE_HEAD" --arg head "$HEAD_FULL" --arg tag "$retained_tag" \
      --argjson dry "$([ "$DRY_RUN" = true ] && echo true || echo false)" \
      --argjson verdict "$(printf '%s' "$retained_json" | jq -c .validated_verdict)" '
        {historical_chunk:{base:$base,end:$end,full_head:$head},clearance:false,
         prefix_receipt:$tag,receipt_written:($dry|not),receipt_reused:true,
         watermark_advanced:false,fanout_authorized:false,dry_run:$dry,
         validated_verdict:$verdict}'
    if [ "$DRY_RUN" = true ]; then
      log "historical chunk receipt already validated — dry-run made no receipt write or push; no full-wave clearance"
    else
      log "historical chunk receipt already validated — exact receipt ensured on origin without another review; no full-wave clearance"
    fi
    exit 9
  fi
  git -C "$REPO_DIR" merge-base --is-ancestor "$PREFIX_BASE" "$RANGE_HEAD" 2>/dev/null \
    || die 3 "historical end $RANGE_HEAD does not continue retained prefix $PREFIX_BASE"
  git -C "$REPO_DIR" merge-base --is-ancestor "$RANGE_HEAD" "$HEAD_FULL" 2>/dev/null \
    || die 3 "historical end $RANGE_HEAD is not within intended head $HEAD_FULL"
  RANGE_BASE="$PREFIX_BASE"
else
  RANGE_BASE="$BASE_FULL"
  RANGE_HEAD="$HEAD_FULL"
fi

# Build one range using the intended head's fixed scope. A path newly
# admitted to that scope during this chunk is diffed from the empty tree at
# the chunk end, retaining pre-existing bytes; subsequent chunks carry its
# ordinary deltas. Cumulative contiguous chunks therefore equal the existing
# full-range coverage contract.
build_curated_diff() { # build_curated_diff <range-base> <range-end> <output>
  local range_base="$1" range_end="$2" output="$3"
  local initial_base_scope range_base_scope range_end_scope p
  local common=() added=()
  initial_base_scope="$(manifest_scope_at "$BASE_FULL")"
  range_base_scope="$(manifest_scope_at "$range_base")"
  range_end_scope="$(manifest_scope_at "$range_end")"
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    # Paths already shipped at the initial base remain ordinary range deltas
    # for every chunk, even if an intermediate manifest temporarily removes
    # them. The fixed full-head scope must retain deletions of their old bytes.
    if printf '%s\n' "$initial_base_scope" | grep -Fxq "$p"; then
      common[${#common[@]}]="$p"
    elif printf '%s\n' "$range_end_scope" | grep -Fxq "$p"; then
      if printf '%s\n' "$range_base_scope" | grep -Fxq "$p"; then
        common[${#common[@]}]="$p"
      else
        added[${#added[@]}]="$p"
      fi
    else
      # A newly admitted path that is absent at this chunk end delivers
      # nothing yet. Its next admission is covered from the empty tree.
      continue
    fi
  done <<EOF
$head_scope
EOF
  : > "$output"
  if [ "${#common[@]}" -gt 0 ]; then
    git -C "$REPO_DIR" diff "${range_base}..${range_end}" -- "${common[@]}" >> "$output"
  fi
  if [ "${#added[@]}" -gt 0 ]; then
    EMPTY_TREE="$(git -C "$REPO_DIR" hash-object -t tree /dev/null)"
    log "newly-manifested path(s) audited in full for this range: ${added[*]}"
    git -C "$REPO_DIR" diff "$EMPTY_TREE" "$range_end" -- "${added[@]}" >> "$output"
  fi
}

manifest_scope_at() { # manifest_scope_at <commit>; absence is empty, read failure is fatal
  local commit="$1" raw tree_paths
  if git -C "$REPO_DIR" cat-file -e "${commit}:${MANIFEST_RELPATH}" 2>/dev/null; then
    raw="$(manifest_paths_at "$commit")" \
      || die 3 "could not read ${MANIFEST_RELPATH} at historical boundary $commit"
    printf '%s\n' "$raw" | in_scope
    return 0
  fi
  # A missing path is legitimate before the manifest was introduced. If the
  # tree still names it, cat-file failed for another reason and cannot be
  # interpreted as empty scope.
  tree_paths="$(git -C "$REPO_DIR" ls-tree --name-only "$commit" -- "$MANIFEST_RELPATH" 2>/dev/null)" \
    || die 3 "could not inspect ${MANIFEST_RELPATH} at historical boundary $commit"
  if printf '%s\n' "$tree_paths" | grep -Fxq "$MANIFEST_RELPATH"; then
    die 3 "could not read ${MANIFEST_RELPATH} at historical boundary $commit"
  fi
  git -C "$REPO_DIR" rev-parse --verify "${commit}^{tree}" >/dev/null 2>&1 \
    || die 3 "could not read historical boundary tree $commit"
  return 0
}

if [ "$FINALIZE_HISTORICAL" = false ]; then
  build_curated_diff "$RANGE_BASE" "$RANGE_HEAD" "$DIFF_FILE"
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

advance_prefix_receipt() { # advance_prefix_receipt <orchestrator-summary-json>
  local summary="$1" tag="${PREFIX_TAG_PREFIX}/${HEAD_FULL}/${RANGE_HEAD}"
  local receipt_file diff_oid verdict provenance
  receipt_file="$(mktemp "${TMPDIR:-/tmp}/wave-audit-prefix.XXXXXX")"
  TMP_FILES[${#TMP_FILES[@]}]="$receipt_file"
  diff_oid="$(git -C "$REPO_DIR" hash-object "$DIFF_FILE")"
  verdict="$(printf '%s' "$summary" | jq -c .validated_verdict)"
  provenance="$(printf '%s' "$summary" | jq -c '
    {direction, reviewer_identity, adapter, canary_head:.head_sha,
     repo, pr_number, reviewer_effort, adapter_timeout_seconds,
     usage_source, token_count}')"
  jq -n --arg base "$BASE_FULL" --arg head "$HEAD_FULL" \
    --arg manifest "$MANIFEST_BLOB" --arg scope "$SCOPE_FINGERPRINT" \
    --arg chunk_base "$RANGE_BASE" --arg prefix_end "$RANGE_HEAD" \
    --arg diff_oid "$diff_oid" --argjson files "$FILES" --argjson bytes "$BYTES" \
    --arg repo "$REPO" --argjson pr "$PR" --argjson verdict "$verdict" \
    --argjson provenance "$provenance" \
    '{version:1, kind:"wave-audit-prefix", clearance:false,
      initial_base:$base, full_head:$head, manifest_blob:$manifest,
      scope_fingerprint:$scope, chunk_base:$chunk_base, prefix_end:$prefix_end,
      diff_oid:$diff_oid, scope_files:$files, scope_bytes:$bytes,
      canary:{repo:$repo,pr:$pr}, review_provenance:$provenance,
      validated_verdict:$verdict}' > "$receipt_file"
  if git -C "$REPO_DIR" rev-parse --verify --quiet "refs/tags/$tag" >/dev/null; then
    log "prefix receipt $tag already present locally — ensuring it is on origin"
  else
    GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=tag.gpgsign GIT_CONFIG_VALUE_0=false \
      git -C "$REPO_DIR" tag -a "$tag" -F "$receipt_file" "$RANGE_HEAD"
  fi
  git -C "$REPO_DIR" push -q origin "refs/tags/$tag" \
    || die 3 "prefix receipt $tag exists locally but the push failed — rerun to retain this exact chunk"
  PREFIX_TAG_RESULT="$tag"
}

emit_json() { # emit_json <orch_exit_or_null> <tagged> <skipped_reason_or_null>
  jq -n \
    --arg base "$BASE_FULL" --arg head "$HEAD_FULL" --arg repo "$REPO" \
    --argjson pr "$PR" --argjson files "$FILES" --argjson bytes "$BYTES" \
    --argjson limit "$DIFF_MAX" \
    --argjson watermark "$BASE_WATERMARK_JSON" \
    --arg effort "$EFFORT" --argjson timeout "$TIMEOUT" \
    --argjson orch "$1" --argjson tagged "$2" --argjson skipped "$3" \
    --argjson dry "$([ "$DRY_RUN" = true ] && echo true || echo false)" \
    '{base:$base, base_watermark:$watermark, head:$head, repo:$repo, pr:$pr, scope_files:$files,
      scope_bytes:$bytes, diff_max_bytes:$limit, effort:$effort, timeout_seconds:$timeout,
      orchestrator_exit:$orch, watermark_advanced:$tagged, skipped:$skipped,
      dry_run:$dry}'
}

log "audit range ${RANGE_BASE} .. ${RANGE_HEAD} (intended head ${HEAD_FULL}) — ${FILES} file(s), ${BYTES} bytes in scope (effort=${EFFORT}, timeout=${TIMEOUT}s)"

if [ "$FINALIZE_HISTORICAL" = true ]; then
  [ "$PREFIX_BASE" = "$HEAD_FULL" ] \
    || die 3 "historical coverage is incomplete: retained through $PREFIX_BASE, intended head is $HEAD_FULL"
  RECEIPT_PACKAGE="$(mktemp "${TMPDIR:-/tmp}/wave-audit-cumulative.XXXXXX")"
  TMP_FILES[${#TMP_FILES[@]}]="$RECEIPT_PACKAGE"
  # Rebuild every retained chunk from the pinned Git objects. The tag
  # annotation is a locator and record; it cannot substitute different bytes
  # into final cumulative coverage.
  while IFS= read -r receipt_json; do
    verify_diff="$(mktemp "${TMPDIR:-/tmp}/wave-audit-verify.XXXXXX")"
    TMP_FILES[${#TMP_FILES[@]}]="$verify_diff"
    verify_base="$(printf '%s' "$receipt_json" | jq -r .chunk_base)"
    verify_end="$(printf '%s' "$receipt_json" | jq -r .prefix_end)"
    build_curated_diff "$verify_base" "$verify_end" "$verify_diff"
    verify_oid="$(git -C "$REPO_DIR" hash-object "$verify_diff")"
    verify_bytes="$(wc -c < "$verify_diff" | tr -d ' ')"
    verify_files="$(grep -c '^diff --git ' "$verify_diff" || true)"
    printf '%s' "$receipt_json" | jq -e --arg oid "$verify_oid" \
      --argjson bytes "$verify_bytes" --argjson files "$verify_files" \
      '.diff_oid == $oid and .scope_bytes == $bytes and .scope_files == $files' >/dev/null \
      || die 3 "prefix receipt through $verify_end does not match reconstructed curated bytes"
  done < <(jq -sc '.[]' "$RECEIPT_CHAIN")
  jq -s --arg base "$BASE_FULL" --arg head "$HEAD_FULL" \
    --arg manifest "$MANIFEST_BLOB" --arg scope "$SCOPE_FINGERPRINT" '
      {artifact_kind:"wave-audit-cumulative-coverage-receipts", version:1,
       clearance:false, claims_prior_posted_approval:false,
       review_instruction:"Review cumulative coverage receipts for the pinned historical range. This is not a code diff and not a prior posted approval. Verify the complete contiguous coverage and receipt bindings before issuing the final verdict.",
       initial_base:$base, full_head:$head, manifest_blob:$manifest,
       scope_fingerprint:$scope, receipts:.}' "$RECEIPT_CHAIN" > "$RECEIPT_PACKAGE"
  {
    receipt_lines="$(wc -l < "$RECEIPT_PACKAGE" | tr -d ' ')"
    printf 'diff --git a/wave-audit-cumulative-coverage-receipts.json b/wave-audit-cumulative-coverage-receipts.json\n'
    printf 'new file mode 100644\n--- /dev/null\n+++ b/wave-audit-cumulative-coverage-receipts.json\n'
    printf '@@ -0,0 +1,%s @@\n' "$receipt_lines"
    sed 's/^/+/' "$RECEIPT_PACKAGE"
  } > "$DIFF_FILE"
  BYTES="$(wc -c < "$DIFF_FILE" | tr -d ' ')"
  FILES=1
  RANGE_BASE="$BASE_FULL"; RANGE_HEAD="$HEAD_FULL"
  log "finalizing explicit cumulative historical coverage from $BASE_FULL through $HEAD_FULL"
fi

if [ -n "$HISTORICAL_END" ] && [ "$BYTES" -eq 0 ]; then
  jq -n --arg base "$RANGE_BASE" --arg end "$RANGE_HEAD" --arg head "$HEAD_FULL" \
    --argjson dry "$([ "$DRY_RUN" = true ] && echo true || echo false)" '
      {historical_chunk:{base:$base,end:$end,full_head:$head},clearance:false,
       prefix_receipt:null,receipt_written:false,watermark_advanced:false,
       fanout_authorized:false,dry_run:$dry,skipped:"empty-historical-chunk"}'
  log "ERROR: historical chunk has no in-scope bytes, so no reviewer evidence can be retained — no receipt or clearance; choose a later endpoint that coalesces this empty interval with a non-empty chunk"
  exit 3
fi

# The complete curated payload is already known. Refuse deterministic
# overage before the orchestrator waits on providers or accounts feedback;
# its transient-unavailability exit would only chain a larger range (#1186).
if [ "$BYTES" -gt "$DIFF_MAX" ]; then
  emit_json null false '"over-budget"'
  log "audit scope exceeds the ${DIFF_MAX}-byte budget (${BYTES} bytes) — no reviewer dispatched and no watermark; do NOT fan out, this range needs bounded review before retrying"
  exit 8
fi

if [ "$BYTES" -eq 0 ] && [ "$HISTORICAL" = false ]; then
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
if [ "$DRY_RUN" = true ] || [ -n "$HISTORICAL_END" ]; then
  orch_args[${#orch_args[@]}]="--dry-run"
fi
if [ "$EFFORT" != "minimal" ]; then
  export P4B_CLAUDE_EFFORT="$EFFORT"
fi
if [ -n "$HISTORICAL_END" ]; then
  ORCH_OUTPUT="$(mktemp "${TMPDIR:-/tmp}/wave-audit-orchestrator.XXXXXX")"
  TMP_FILES[${#TMP_FILES[@]}]="$ORCH_OUTPUT"
  set +e
  P4B_CODEX_EFFORT="$EFFORT" P4B_ADAPTER_TIMEOUT_SECONDS="$TIMEOUT" \
  P4B_DIFF_MAX_BYTES="$DIFF_MAX" "$ORCH" "${orch_args[@]}" > "$ORCH_OUTPUT"
  orc=$?
  set -e
  if [ "$orc" -ne 0 ]; then
    cat "$ORCH_OUTPUT"
    log "historical chunk validation failed (orchestrator exit $orc) — no prefix receipt, watermark, or fan-out"
    exit "$orc"
  fi
  orch_summary="$(jq -ce '
    select(.dry_run == true and .review_posted == false) |
    select((.direction | type == "string" and length > 0) and
           (.reviewer_identity | type == "string" and length > 0) and
           (.head_sha | type == "string")) |
    select((.validated_verdict | type == "object") and
           (.validated_verdict.verdict | type == "string") and
           (.validated_verdict.findings | type == "array"))' "$ORCH_OUTPUT" 2>/dev/null)" \
    || { cat "$ORCH_OUTPUT"; die 3 "historical dry-run returned no complete validated_verdict"; }
  verdict="$(printf '%s' "$orch_summary" | jq -c .validated_verdict)"
  if [ -n "$pr_head" ]; then
    [ "$(printf '%s' "$orch_summary" | jq -r '.head_sha // empty')" = "$pr_head" ] \
      || { cat "$ORCH_OUTPUT"; die 3 "historical dry-run verdict is not pinned to lane-verified canary head $pr_head"; }
  fi
  clean=false
  printf '%s' "$verdict" | jq -e '.verdict == "APPROVED" and (.findings | length == 0)' >/dev/null && clean=true
  if [ "$clean" != true ]; then
    jq -n --arg base "$RANGE_BASE" --arg end "$RANGE_HEAD" --arg head "$HEAD_FULL" \
      --argjson verdict "$verdict" \
      '{historical_chunk:{base:$base,end:$end,full_head:$head},clearance:false,
        prefix_receipt:null,watermark_advanced:false,fanout_authorized:false,
        validated_verdict:$verdict}'
    log "historical chunk produced findings (including APPROVED advisories) — complete verdict retained for disposition; no receipt or clearance state written"
    exit 1
  fi
  prefix_tag=null
  if [ "$DRY_RUN" = false ]; then
    PREFIX_TAG_RESULT=""
    advance_prefix_receipt "$orch_summary"
    prefix_tag="$PREFIX_TAG_RESULT"
  fi
  jq -n --arg base "$RANGE_BASE" --arg end "$RANGE_HEAD" --arg head "$HEAD_FULL" \
    --arg tag "$prefix_tag" --argjson dry "$([ "$DRY_RUN" = true ] && echo true || echo false)" \
    --argjson verdict "$verdict" '
      {historical_chunk:{base:$base,end:$end,full_head:$head},clearance:false,
       prefix_receipt:(if $tag == "null" then null else $tag end),
       receipt_written:($dry|not),watermark_advanced:false,fanout_authorized:false,
       dry_run:$dry,validated_verdict:$verdict}'
  log "historical chunk validated clean — retained as non-clearance prefix only; explicit --finalize-historical is still required"
  exit 9
else
  set +e
  P4B_CODEX_EFFORT="$EFFORT" \
  P4B_ADAPTER_TIMEOUT_SECONDS="$TIMEOUT" \
  P4B_DIFF_MAX_BYTES="$DIFF_MAX" \
    "$ORCH" "${orch_args[@]}"
  orc=$?
  set -e
fi

if [ "$FINALIZE_HISTORICAL" = true ] && [ "$orc" -ne 0 ]; then
  emit_json "$orc" false null
  log "historical finalization did not approve (orchestrator exit $orc) — full watermark unchanged; do NOT fan out or treat retained prefixes as clearance"
  exit "$orc"
fi

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
  7)
    # #1000 feedback-accounting hold: a canary finding has no
    # disposition evidence. Treat it like the fail-closed/no-fan-out states,
    # never like reviewer unavailability; spending or bypassing another review
    # round is exactly what this status prevents.
    emit_json 7 false null
    log "review feedback is unaccounted on ${REPO}#${PR} (orchestrator exit 7) — no watermark; do NOT fan out. If the orchestrator JSON reports review_posted:true, repair its acknowledgment without repeating the review; otherwise disposition earlier findings and rerun the audit"
    ;;
  *)
    emit_json "$orc" false null
    log "reviewer unavailable (orchestrator exit $orc) — no watermark; the wave may proceed on CI + lane and this range chains into the next audit"
    ;;
esac
exit "$orc"
