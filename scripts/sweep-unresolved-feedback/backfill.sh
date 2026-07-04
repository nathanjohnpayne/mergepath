#!/usr/bin/env bash
# scripts/sweep-unresolved-feedback/backfill.sh
#
# One-time backfill (#566) that drains the standing unresolved-feedback
# backlog (#562). It enumerates closed PRs that still carry unresolved bot
# review threads — via enumerate.sh, the same enumerator the weekly sweep
# uses — and runs resolve-pr-threads.sh on each distinct PR in one of two
# demonstrability modes (--mode, default resolve-actioned).
#
# --mode resolve-actioned (default) resolves ONLY demonstrably-actioned
# bot-authored threads: a fix commit that touches the anchored file after the
# latest bot/reviewer comment (addressed-elsewhere), or a substantive agent
# rebuttal after the bot's last word (rebuttal-recorded). Routing-only
# (canonical/templated), surface (nitpick/deferred), and human-authored
# threads are LEFT UNRESOLVED.
#
# --mode resolve-verified-propagation drains the OTHER half: the routing
# classes (canonical-coverage / templated-render) that the actioned gate
# leaves behind — but ONLY where the consumer file at the compared ref
# byte-matches the mergepath canonical/rendered source AND the upstream
# carries a fix commit newer than the finding (#572/#616). It is the
# Track-C drain, valid once the sync wave has landed so consumers match
# canonical. It EXCLUDES the canonical repo itself (see CANONICAL_REPO):
# verified-propagation is a consumer→canonical compare and would self-match
# there.
#
# Both modes readback-confirm every resolve (isResolved:true) and fail closed
# otherwise. The forward fix (#564/#565) prevents the backlog from growing;
# this drains the parts already demonstrably handled or verifiably propagated.
#
# SAFETY: dry-run by DEFAULT. It mutates only with --execute. The dry-run
# previews per-PR would-resolve / skipped counts so the operator can review
# the scope before any write.
#
# Usage:
#   scripts/sweep-unresolved-feedback/backfill.sh [--execute]
#       [--mode resolve-actioned|resolve-verified-propagation]
#       [--repo owner/name] [targets-file]
#
#   --execute        Actually resolve (default: dry-run, no mutations).
#   --mode M         Resolve mode delegated to resolve-pr-threads.sh:
#                    resolve-actioned (default) or resolve-verified-propagation.
#   --repo o/n       Restrict to a single repo (default: every repo in the
#                    targets file).
#   targets-file     Path to the target-repos list (default:
#                    target-repos.txt alongside this script).
#
# Environment:
#   GH_TOKEN                 required. PR read + (when --execute) the
#                            identity-checked resolve mutation, per
#                            resolve-pr-threads.sh.
#   SWEEP_LOOKBACK_DAYS      forwarded to enumerate.sh (default 90).
#   BACKFILL_MAX_PRS         optional safety cap on the number of distinct
#                            PRs processed in one run (default 0 = no cap).
#                            This is a ONE-RUN safety limit, NOT a resumable
#                            batch cursor: each run re-enumerates from the
#                            start, so capping then re-running re-processes the
#                            same earliest PRs. For a complete drain, run
#                            uncapped (Codex Phase-4b r2 on #571, P3).
#
# Exit codes:
#   0  completed (dry-run, or every actioned thread resolved + confirmed)
#   1  setup error (missing dep/script/targets, GH_TOKEN unset)
#   2  fail closed: an unresolvable target repo, ANY enumerate warning (repo-list
#      skip, per-PR thread-fetch skip, or >100-review-threads page truncation),
#      or a resolve/readback failure on some PR
#
# Bash 3.2 compatible.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
ENUMERATE="$SCRIPT_DIR/enumerate.sh"
RESOLVE="$ROOT/scripts/resolve-pr-threads.sh"

DRY_RUN=true
ONLY_REPO=""
TARGETS_FILE=""
# Which resolve-pr-threads.sh mode each PR is run through. The shipped #566
# backfill only drained the actioned classes (addressed-elsewhere /
# rebuttal-recorded); resolve-verified-propagation (#572/#616) drains the
# routing classes (canonical-coverage / templated-render) that the actioned
# gate deliberately leaves behind — but ONLY when the consumer file at the
# compared ref byte-matches canonical AND the upstream carries a newer fix
# commit. That mode is the Track-C drain enabled once the sync wave lands.
MODE="resolve-actioned"
# The canonical (hub) repo. verified-propagation is a CONSUMER→canonical
# byte-compare; run against the canonical repo itself it would compare a file
# to itself, self-match, and resolve with a semantically-false "propagation
# verified" tag. So --mode resolve-verified-propagation SKIPS this repo (the
# per-PR loop below); --resolve-actioned still drains its actioned threads
# normally. Env-overridable for tests, mirroring
# scripts/ci/check_op_firebase_deploy_integration.
CANONICAL_REPO="${MERGEPATH_CANONICAL_REPO:-nathanjohnpayne/mergepath}"
# GitHub repo slugs are case-insensitive, so match case-insensitively — a
# case-variant override (or an enumerated slug in different case) must not
# bypass the skip. Bash 3.2 has no ${var,,}; normalize with tr, once.
CANONICAL_REPO_LC="$(printf '%s' "$CANONICAL_REPO" | tr '[:upper:]' '[:lower:]')"

usage() { sed -n '2,46p' "$0" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --execute) DRY_RUN=false; shift ;;
    --dry-run) DRY_RUN=true; shift ;;
    --mode)
      if [ $# -lt 2 ] || [ -z "$2" ]; then echo "backfill: --mode needs a value" >&2; exit 1; fi
      MODE="$2"; shift 2 ;;
    --repo)
      if [ $# -lt 2 ] || [ -z "$2" ]; then echo "backfill: --repo needs a value" >&2; exit 1; fi
      ONLY_REPO="$2"; shift 2 ;;
    -h|--help) usage ;;
    -*) echo "backfill: unknown flag: $1" >&2; usage ;;
    *)
      if [ -z "$TARGETS_FILE" ]; then TARGETS_FILE="$1"; else echo "backfill: unexpected arg: $1" >&2; usage; fi
      shift ;;
  esac
done

TARGETS_FILE="${TARGETS_FILE:-$SCRIPT_DIR/target-repos.txt}"

case "$MODE" in
  resolve-actioned|resolve-verified-propagation) : ;;
  *) echo "backfill: --mode must be resolve-actioned or resolve-verified-propagation (got: '$MODE')" >&2; exit 1 ;;
esac

for f in "$ENUMERATE" "$RESOLVE"; do
  [ -x "$f" ] || { echo "backfill: missing or non-executable: $f" >&2; exit 1; }
done
for dep in gh jq; do
  command -v "$dep" >/dev/null 2>&1 || { echo "backfill: required dependency missing: $dep" >&2; exit 1; }
done
if [ -z "${GH_TOKEN:-}" ]; then
  echo "backfill: GH_TOKEN not set." >&2; exit 1
fi

# verified-propagation verifies against the mergepath canonical source + manifest
# read from the LOCAL committed HEAD (resolve-pr-threads.sh). A bulk drain from a
# stale or feature-branch checkout would byte-compare consumers against a non-main
# snapshot and tag verified-propagation against untrusted state (Codex P2 on
# #666). Require the checkout to sit at the canonical repo's current
# default-branch tip for THIS mode (actioned resolution does not read canonical,
# so it is exempt). MERGEPATH_BACKFILL_TRUSTED_REF_OK=1 overrides — for the
# hermetic tests, or an intentional pinned-SHA run the operator has vetted.
if [ "$MODE" = "resolve-verified-propagation" ] && [ "${MERGEPATH_BACKFILL_TRUSTED_REF_OK:-0}" != "1" ]; then
  trusted_branch=$(gh repo view "$CANONICAL_REPO" --json defaultBranchRef --jq '.defaultBranchRef.name' 2>/dev/null)
  [ -n "$trusted_branch" ] || trusted_branch=main
  # Compare local HEAD against the canonical repo's AUTHORITATIVE default-branch
  # OID from GitHub, NOT a local origin/ tracking ref (Codex P2 on #666): this
  # checkout's origin may point at a fork/mirror, and a failed fetch can leave a
  # stale origin/<branch> that still equals HEAD — either would pass a local
  # comparison while the verifier byte-compares consumers against non-canonical
  # source. gh api reads the true tip regardless of local remote config.
  trusted_head=$(gh api "repos/$CANONICAL_REPO/commits/$trusted_branch" --jq '.sha' 2>/dev/null || true)
  local_head=$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || true)
  if [ -z "$local_head" ] || [ -z "$trusted_head" ] || [ "$local_head" != "$trusted_head" ]; then
    echo "backfill: --mode resolve-verified-propagation verifies against the LOCAL checkout's canonical source." >&2
    echo "         Refusing to run from a non-trusted ref (HEAD=${local_head:-none} vs $CANONICAL_REPO@$trusted_branch=${trusted_head:-none})." >&2
    echo "         Run from a fresh $CANONICAL_REPO $trusted_branch checkout, or set MERGEPATH_BACKFILL_TRUSTED_REF_OK=1 after vetting the pinned SHA." >&2
    exit 1
  fi
fi

# Build the targets file enumerate.sh reads. With --repo we hand it a
# one-line temp file so a single repo can be drained without editing the
# shipped list.
WORK="$(mktemp -d "${TMPDIR:-/tmp}/backfill.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
if [ -n "$ONLY_REPO" ]; then
  printf '%s\n' "$ONLY_REPO" > "$WORK/targets.txt"
  ENUM_TARGETS="$WORK/targets.txt"
else
  [ -f "$TARGETS_FILE" ] || { echo "backfill: targets file not found: $TARGETS_FILE" >&2; exit 1; }
  # Normalize into a temp copy with a guaranteed trailing newline. A targets
  # file whose FINAL entry lacks a newline would otherwise be silently dropped
  # by the `while read` loops here AND in enumerate.sh (read returns non-zero on
  # an EOF-terminated last line), turning an invalid/unscanned final target into
  # a false empty drain (CodeRabbit + Codex Phase-4b r4 on #571). An already
  # newline-terminated file just gains a harmless trailing blank line (skipped).
  ENUM_TARGETS="$WORK/targets.txt"
  { cat "$TARGETS_FILE"; printf '\n'; } > "$ENUM_TARGETS"
fi

# verified-propagation is N/A on the canonical repo (self-match). Drop it from
# the target set BEFORE validation + enumeration, so a transient canonical-only
# enumerate WARN (e.g. a >100-thread hub PR, or a flaky thread fetch) cannot
# fail-close the whole consumer drain before any consumer PR is processed
# (Codex P2 on #666). The per-PR loop skip below stays as a backstop for a
# direct --repo <canonical>. Comments/blank lines are preserved; the match is
# case-insensitive (GitHub slugs are).
if [ "$MODE" = "resolve-verified-propagation" ]; then
  _cf="$WORK/targets.no-canonical.txt"; : > "$_cf"
  _cf_dropped=0
  while IFS= read -r _cf_line || [ -n "$_cf_line" ]; do
    _cf_slug=$(printf '%s' "$_cf_line" | sed -E 's/[[:space:]]+$//')
    case "$_cf_slug" in ''|\#*) printf '%s\n' "$_cf_line" >> "$_cf"; continue ;; esac
    if [ "$(printf '%s' "$_cf_slug" | tr '[:upper:]' '[:lower:]')" = "$CANONICAL_REPO_LC" ]; then
      _cf_dropped=1; continue
    fi
    printf '%s\n' "$_cf_line" >> "$_cf"
  done < "$ENUM_TARGETS"
  mv "$_cf" "$ENUM_TARGETS"
  [ "$_cf_dropped" -eq 1 ] && \
    echo "backfill: excluded canonical repo $CANONICAL_REPO from verified-propagation targets (N/A for this mode)" >&2
fi

# Verify every target repo RESOLVES with the current token before draining.
# gh pr list returns an empty SUCCESSFUL list (exit 0, no error) for a
# nonexistent / renamed / unauthorized repo, so a typo'd or inaccessible
# --repo would otherwise look like a clean empty drain. Validate existence
# explicitly with `gh repo view` and fail closed; this distinguishes a real
# repo with zero findings from an unresolvable target (Codex Phase-4b r2 on
# #571 — the enumerate WARN path does NOT fire on this empty-success case).
# `|| [ -n "$_trepo" ]` keeps the final line even if the normalize above is ever
# bypassed (defense-in-depth for the no-trailing-newline drop, #571 r4).
while IFS= read -r _trepo || [ -n "$_trepo" ]; do
  _trepo=$(printf '%s' "$_trepo" | sed -E 's/[[:space:]]+$//')
  case "$_trepo" in ''|\#*) continue ;; esac
  if ! gh repo view "$_trepo" --json nameWithOwner >/dev/null 2>&1; then
    echo "backfill: target repo not resolvable with the current token (nonexistent, renamed, or no access): $_trepo — failing closed" >&2
    exit 2
  fi
done < "$ENUM_TARGETS"

echo "backfill: mode=$MODE — $($DRY_RUN && echo 'DRY-RUN (no mutations)' || echo 'EXECUTE (will resolve)') — enumerating unresolved threads" >&2

FINDINGS="$WORK/findings.ndjson"
ENUM_STDERR="$WORK/enumerate.stderr"
SWEEP_OUTPUT="$FINDINGS" "$ENUMERATE" "$ENUM_TARGETS" >/dev/null 2>"$ENUM_STDERR" || {
  cat "$ENUM_STDERR" >&2; echo "backfill: enumerate.sh failed" >&2; exit 1
}
cat "$ENUM_STDERR" >&2
# Fail closed if enumerate emitted ANY warning. enumerate.sh is tolerant by
# design — it WARNs and continues on an unlistable repo, an unfetchable PR's
# threads, OR a PR with >100 review threads (it examines only the first page) —
# so the weekly sweep still covers the rest. But a one-time fail-closed drain
# must not report a PARTIAL drain as complete: any such WARN means some threads
# were never visited. The gh-repo-view pre-validation above catches an invalid
# --repo target up front; matching every `enumerate: WARN` here catches the rest
# without a fragile per-warning whitelist — a repo-list skip, a per-PR
# thread-fetch skip, AND the >100-threads page truncation (Codex Phase-4b on
# #571: r2 the per-PR skip, r3 the >100-threads page cap).
if grep -q 'enumerate: WARN' "$ENUM_STDERR"; then
  echo "backfill: enumerate reported incomplete coverage (see WARN above: a repo-list skip, a per-PR thread-fetch skip, or a >100-review-threads page truncation); refusing to report a partial drain — failing closed" >&2
  exit 2
fi

# Distinct (repo, pr) pairs that have at least one unresolved thread. These
# are the PRs worth visiting; --resolve-actioned decides per-thread whether
# each is actually actioned.
PAIRS=$(jq -r '[.repo, (.pr_number|tostring)] | @tsv' "$FINDINGS" 2>/dev/null | sort -u)
PAIR_COUNT=$(printf '%s' "$PAIRS" | grep -c . || true)
echo "backfill: $PAIR_COUNT distinct closed PR(s) with unresolved threads" >&2

MAX="${BACKFILL_MAX_PRS:-0}"
case "$MAX" in
  ''|*[!0-9]*)
    echo "backfill: BACKFILL_MAX_PRS must be a non-negative integer (got: '$MAX')" >&2; exit 1 ;;
esac
TOTAL_RESOLVED=0
TOTAL_WOULD=0
TOTAL_SKIPPED=0
TOTAL_FAILED=0
PRS_DONE=0
ANY_FAILURE=0

# Process each PR through the actioned resolver. resolve-pr-threads.sh exit
# codes: 0 clean, 2 a resolve/readback failure (fail closed), 3 work remains
# (threads left unresolved) — for a backfill, 3 is expected and NOT a failure.
while IFS=$'\t' read -r repo pr; do
  [ -z "$repo" ] && continue
  # verified-propagation self-matches on the canonical repo (compares its own
  # source to itself → false "propagation verified"). Skip it in that mode;
  # --resolve-actioned still drains the canonical repo's actioned threads. Match
  # case-insensitively (GitHub slugs are case-insensitive); the tr only runs in
  # verified mode via the short-circuit.
  if [ "$MODE" = "resolve-verified-propagation" ] \
     && [ "$(printf '%s' "$repo" | tr '[:upper:]' '[:lower:]')" = "$CANONICAL_REPO_LC" ]; then
    echo "  $repo#$pr: SKIP (verified-propagation N/A on the canonical repo $CANONICAL_REPO)" >&2
    continue
  fi
  if [ "$MAX" -gt 0 ] && [ "$PRS_DONE" -ge "$MAX" ]; then
    echo "backfill: BACKFILL_MAX_PRS=$MAX reached; stopping (remaining PRs not processed)" >&2
    break
  fi
  PRS_DONE=$((PRS_DONE + 1))
  # The DEFAULT mode (--resolve-actioned) legitimately drains EVERY target,
  # INCLUDING the canonical repo (nathanjohnpayne/mergepath, present in
  # target-repos.txt): an actioned resolution — a fix commit touching the
  # anchored file, or a rebuttal — is valid on the canonical source itself.
  # --mode resolve-verified-propagation is the exception (#664): it
  # byte-compares a CONSUMER's content against the canonical source, so on the
  # canonical repo the two sides are ONE file and every thread self-matches.
  # That mode SKIPS the canonical repo above (CANONICAL_REPO), and
  # resolve-pr-threads.sh ALSO self-guards it (#664, skipped as
  # not-propagation-routed) — fail-safe on both layers.
  args=("$pr" --repo "$repo" "--$MODE")
  $DRY_RUN && args+=(--dry-run)
  set +e
  out=$("$RESOLVE" "${args[@]}" 2>&1)
  resolve_rc=$?
  set -e
  rc_line=$(printf '%s\n' "$out" | tail -40)
  # Pull the summary counters from resolve-pr-threads.sh output.
  resolved=$(printf '%s\n' "$out" | sed -n 's/.*Resolved: \([0-9]*\) .*/\1/p' | tail -1)
  would=$(printf '%s\n' "$out" | sed -n 's/.*would-resolve: \([0-9]*\).*/\1/p' | tail -1)
  # Sum EVERY skipped(*) category the resolver reports, not just not-actioned:
  # verified-propagation also emits skipped (not-propagation|drift|verify-error|
  # no-upstream-evidence), and counting only not-actioned would let a dry-run
  # read "skipped=0" while drifted/unverified threads remain, hiding them from
  # the operator's scope review (Codex P2 on #666). Only the resolver's summary
  # line uses the "skipped (label): N" shape (per-thread lines say "SKIP (...)").
  # Single awk (no grep) so a no-match output exits 0 — a grep here would exit 1
  # under `set -o pipefail` and abort the fail-closed exit path on a crashed
  # resolver (the summary-less "die" case).
  skipped=$(printf '%s\n' "$out" | awk '
    { line=$0
      while (match(line, /[Ss]kipped \([A-Za-z-]+\): [0-9]+/)) {
        seg=substr(line, RSTART, RLENGTH); sub(/.*: /, "", seg); s+=seg
        line=substr(line, RSTART+RLENGTH)
      } }
    END { print s+0 }')
  failed=$(printf '%s\n' "$out" | sed -n 's/.*Failed: \([0-9]*\) .*/\1/p' | tail -1)
  readback_failed=$(printf '%s\n' "$out" | sed -n 's/.*Readback-failed: \([0-9]*\).*/\1/p' | tail -1)
  resolved=${resolved:-0}; would=${would:-0}; skipped=${skipped:-0}
  failed=${failed:-0}; readback_failed=${readback_failed:-0}
  TOTAL_RESOLVED=$((TOTAL_RESOLVED + resolved))
  TOTAL_WOULD=$((TOTAL_WOULD + would))
  TOTAL_SKIPPED=$((TOTAL_SKIPPED + skipped))
  # Fail closed on EITHER parsed Failed:/Readback-failed: counters OR an
  # unexpected resolver exit. resolve-pr-threads.sh exits: 0 clean, 3
  # work-remains (expected for a backfill), 2 fail-closed, 1 setup. A crash
  # before the summary prints leaves the counters at 0, so the exit code is
  # the backstop that keeps a summary-less death from reading as success.
  pr_failed=0
  if [ "$failed" -gt 0 ] || [ "$readback_failed" -gt 0 ]; then pr_failed=1; fi
  case "$resolve_rc" in
    0|3) : ;;
    *) pr_failed=1 ;;
  esac
  if [ "$pr_failed" -eq 1 ]; then
    n=$((failed + readback_failed)); [ "$n" -eq 0 ] && n=1
    TOTAL_FAILED=$((TOTAL_FAILED + n))
    ANY_FAILURE=1
    echo "  $repo#$pr: FAILED (exit=$resolve_rc failed=$failed readback-failed=$readback_failed)" >&2
    printf '%s\n' "$rc_line" | sed 's/^/    /' >&2
  fi
  # Print any PR with resolves OR leftover skips, so a skipped-only PR (nothing
  # verified, but drifted / unverified threads remain) is visible per-PR, not
  # just folded into the summary total (Codex P3 on #666).
  if $DRY_RUN; then
    if [ "$would" -gt 0 ] || [ "$skipped" -gt 0 ]; then echo "  $repo#$pr: would-resolve=$would skipped=$skipped"; fi
  else
    if [ "$resolved" -gt 0 ] || [ "$skipped" -gt 0 ]; then echo "  $repo#$pr: resolved=$resolved skipped=$skipped"; fi
  fi
done <<< "$PAIRS"

echo "" >&2
if $DRY_RUN; then
  echo "backfill DRY-RUN summary: $PRS_DONE PR(s) scanned — would-resolve=$TOTAL_WOULD, skipped=$TOTAL_SKIPPED. Re-run with --execute to resolve." >&2
else
  echo "backfill EXECUTE summary: $PRS_DONE PR(s) — resolved=$TOTAL_RESOLVED, skipped=$TOTAL_SKIPPED, failed=$TOTAL_FAILED." >&2
fi

[ "$ANY_FAILURE" -eq 1 ] && exit 2
exit 0
