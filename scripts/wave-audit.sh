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
#          (mergepath-sync/<sha> or sync-all-<sha>[-<scope-digest>] — what
#           the lane verifies; a
#          parseable title must agree or the run fails closed), or --head-sha
#   diff = git diff base..head -- <manifest paths minus excluded prefixes>
#
# dispatched through scripts/phase-4b-review.sh with a structured
# --wave-scope-file naming the canonical range; trusted wave code regenerates
# curated bytes after live canary byte verification. --diff-file is only an
# equality assertion against object-derived bytes, never trusted review input.
# Hosted `gh pr diff` refuses wave-sized sync PRs outright (HTTP 406 above
# 20k lines); the structured canonical range enables trusted regeneration
# of the curated bytes.
#
# Codex on the canary (#2771): the orchestrator's same-head barrier waits for
# Codex to speak on the canary head, and before this a canary was never asked,
# so audits held until the barrier budget expired (exit 4) unless the Codex
# App happened to auto-review. A publishing run now asks the barrier's own
# question first (codex-review-check.sh --diagnostic-signal-only). If Codex
# already spoke on the head (rc 0) or cannot report (rc 2), nothing is sent and
# the barrier behaves as it always has. Otherwise the run binds the barrier to
# ONE request: the configured author's latest existing request, or the single
# one it sends (codex-review-request.sh --trigger-only). It passes that comment
# id as --wave-codex-request, and the barrier's Codex arm then clears only on
# the answer to that request, never on an unsolicited App review
# (p4b_wave_codex_binding_state). An unanswered request still ends in the
# fail-open exit 4. Fan-out mirrors still get no Codex request.
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
#           automation disabled). NO tag is written. Under the default
#           propagation_audit.unavailable_policy: fail-open the wave may
#           proceed fail-open on CI + lane; the un-audited range chains into
#           the NEXT wave audit automatically, because the watermark only
#           advances on a posted APPROVED (or a scope-empty range). Under
#           `hold` these exits never reach the caller: see 11 and 12 (#2879).
#   exit 11 held (unavailable_policy: hold). No independent audit happened:
#           the reviewer was unavailable (exit 4, 5 or an unmapped exit).
#           A wave-audit-hold/<head>/<base>/<n> tag records attempt n. No
#           watermark; do NOT fan out. Rerun the same command later.
#   exit 12 needs-owner (unavailable_policy: hold). Attempt n reached
#           hold_max_attempts. Terminal: later runs exit 12 without asking
#           Codex or dispatching a review. Do NOT fan out. Recovery is
#           manual for now: the owner fans the wave out by hand under
#           break-glass. A scripted owner release is #2900; until it lands
#           and the owner's demonstration passes, the switch stays off.
#   exit 3  fail-closed, never fan out on this: usage/config error, a canary
#           whose head is not lane-verified (#663 P1 — the range-scoped
#           APPROVED is only sound over a byte-verified mirror), or an
#           orchestrator infrastructure failure (its exit 3, which includes
#           a failed review POST — no reliable verdict exists).
#   exit 7  feedback unaccounted; no tag is written. Never fan out.
#           If the orchestrator JSON says review_posted:true, repair that
#           review's acknowledgment without repeating the review. Otherwise
#           disposition the earlier findings and rerun the same audit.
#   exit 8  curated diff exceeds the configured byte budget, OR the Phase 4b
#           orchestrator requires human review (deterministic tripwire or
#           Codex-cap human stop). No reviewer authority
#           or tag follows. Never fan out on either shape. An ordinary wave
#           whose byte-verified canary is audited from a first-parent base
#           does not trip the deterministic tripwires (#2633).
#           --admin-override runs the adapter past a tripwire. The budget
#           refusal is never overridden (use the historical-prefix path), and
#           a Codex-cap human stop keeps its owner tiebreak (#2544).
#   exit 9  one historical chunk was validated and optionally retained as a
#           non-clearance prefix receipt. Never fan out: only an explicit
#           --finalize-historical run can produce ordinary exit 0 clearance.
#   exit 10 orchestrator request-budget evidence error. No adapter/handoff or
#           tag is written. Never fan out; repair the read/head drift and retry.
#
# Usage:
#   scripts/wave-audit.sh <canary-pr> --repo <owner/repo>
#       [--base <sha>] [--head-sha <sha>] [--dry-run]
#       [--historical-end <sha> | --finalize-historical]
#       [--admin-override "<owner authorization quote>"]
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
#   unavailable_policy: fail-open  # fail-open | hold (#2879)
#   hold_max_attempts: 3         # [1, 10]; holds per range before needs-owner
# Invalid values fail closed (exit 3). Measured basis for the defaults
# (#662): xhigh DNFs the 900s adapter cap on a catch-up-sized wave diff,
# while high cleared the same 745 KB diff in 231s; steady-state wave ranges
# are ~70 KB and fit trivially.
#
# --admin-override (#2633): the owner's authorization, quoted, for this run to
# dispatch the real Phase 4b adapter past the orchestrator's deterministic
# tripwires, and to post its verdict. It is passed through to
# phase-4b-review.sh, recorded in the posted review body, and marked
# `admin-override=true` on the watermark annotation. It never skips the byte
# budget, the canary byte verification, drift checks or feedback accounting.
#
# Env (tests / manual runs):
#   WAVE_AUDIT_REPO_DIR       canonical repo to diff/tag (default: this repo)
#   WAVE_AUDIT_MANIFEST_RELPATH  manifest path relative to the repo root,
#                             read from committed trees (audited head +
#                             audit base), never the working tree
#                             (default: .mergepath-sync.yml)
#   WAVE_AUDIT_ORCHESTRATOR   orchestrator (default: scripts/phase-4b-review.sh)
#   WAVE_AUDIT_CODEX_REQUEST  Codex requester (default:
#                             scripts/codex-review-request.sh)
#   WAVE_AUDIT_CODEX_CHECK    Codex signal check (default:
#                             scripts/codex-review-check.sh)
#   WAVE_AUDIT_COMMENT_CMD    wrapper that posts hold records on the canary
#                             (default: scripts/gh-as-reviewer.sh)
#   WAVE_AUDIT_GH             gh used for the canary comment and commit reads
#                             (default: gh)
#   WAVE_AUDIT_TEST_CANARY_HEAD  canary head when WAVE_AUDIT_LANE_VERIFIED_OK=1
#                             leaves no verified head — hermetic tests only
#   WAVE_AUDIT_LANE_VERIFIED_OK=1  skip the canary lane precondition —
#                             hermetic tests only, never operational runs
#   MERGEPATH_REVIEW_POLICY_PATH  policy file override (p4b convention)

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_DIR="${WAVE_AUDIT_REPO_DIR:-$ROOT}"
MANIFEST_RELPATH="${WAVE_AUDIT_MANIFEST_RELPATH:-.mergepath-sync.yml}"
POLICY="${MERGEPATH_REVIEW_POLICY_PATH:-$REPO_DIR/.github/review-policy.yml}"
ORCH="${WAVE_AUDIT_ORCHESTRATOR:-$ROOT/scripts/phase-4b-review.sh}"
CODEX_REQUEST="${WAVE_AUDIT_CODEX_REQUEST:-$ROOT/scripts/codex-review-request.sh}"
CODEX_CHECK="${WAVE_AUDIT_CODEX_CHECK:-$ROOT/scripts/codex-review-check.sh}"
WA_GH="${WAVE_AUDIT_GH:-gh}"
COMMENT_CMD="${WAVE_AUDIT_COMMENT_CMD:-$ROOT/scripts/gh-as-reviewer.sh}"
TAG_PREFIX="wave-audit-pass"
PREFIX_TAG_PREFIX="wave-audit-prefix"
HOLD_TAG_PREFIX="wave-audit-hold"

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

# top_field <field> — a top-level policy scalar (author_identity); only
# column-0 keys match. Same quote/comment stripping as audit_field.
top_field() {
  [ -f "$POLICY" ] || return 0
  awk -v field="$1" '
    /^[^[:space:]#]/ && $1 == field":" {
      sub(/^[^:]+:[[:space:]]*/, "", $0)
      gsub(/^["\047]/, "", $0)
      gsub(/["\047][[:space:]]*(#.*)?$/, "", $0)
      gsub(/[[:space:]]*#.*$/, "", $0)
      sub(/[[:space:]]+$/, "", $0)
      print; exit
    }
  ' "$POLICY"
}

# canary_author_requests — the configured author's exact request comments on
# the canary as [{id, created_at}], oldest first. The ids are cross-checked
# against crqe_trigger_generation, the grammar the request budget counts, so
# this copy can never disagree with it. Any read, parse or consistency failure
# fails closed: binding or posting blind could tie the barrier to the wrong
# request.
canary_author_requests() {
  local comments requests generation
  comments="$("$WA_GH" api --paginate --slurp "repos/$REPO/issues/$PR/comments" 2>/dev/null \
    | jq -ce 'if type == "array" then (add // []) else error("shape") end' 2>/dev/null)" \
    || die 3 "cannot read ${REPO}#${PR} comments to bind the Codex request (#2771)"
  generation="$(crqe_trigger_generation "$comments" "$CANARY_AUTHOR" 2>/dev/null)" \
    || die 3 "cannot read the Codex request generation on ${REPO}#${PR} (#2771)"
  requests="$(printf '%s' "$comments" | jq -ce --arg author "$CANARY_AUTHOR" '
    [ .[] | select((.user.login // "") == $author)
      | select((.body // "") | test("\\A@codex review\\z"; "i"))
      | {id, created_at} ] | unique_by(.id) | sort_by(.created_at, .id)' 2>/dev/null)" \
    || die 3 "cannot read the Codex request times on ${REPO}#${PR} (#2771)"
  [ "$(printf '%s' "$requests" | jq -c '[.[].id] | sort')" = "$generation" ] \
    || die 3 "Codex request evidence on ${REPO}#${PR} disagrees with the request generation (#2771)"
  printf '%s\n' "$requests"
}

# canary_head_transition — the time of the canary head's last transition by
# GitHub's clock: the later of the PR's creation and its latest
# head_ref_force_pushed event. Unreadable or malformed evidence fails closed.
canary_head_transition() {
  local created timeline
  created="$("$WA_GH" api "repos/$REPO/pulls/$PR" --jq '.created_at' 2>/dev/null)" \
    || die 3 "cannot read when ${REPO}#${PR} was opened (#2771)"
  timeline="$("$WA_GH" api --paginate --slurp "repos/$REPO/issues/$PR/timeline" 2>/dev/null \
    | jq -ce 'if type == "array" then (add // []) else error("shape") end' 2>/dev/null)" \
    || die 3 "cannot read the ${REPO}#${PR} timeline for head transitions (#2771)"
  jq -nr --arg created "$created" --argjson t "$timeline" '
    def stamp: test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$");
    if ($created | stamp | not) then error("created")
    else ([$created] + [ $t[] | select(.event == "head_ref_force_pushed") | .created_at ]) as $all
      | if all($all[]; type == "string" and stamp) then ($all | max) else error("event") end
    end' 2>/dev/null \
    || die 3 "unreadable head-transition evidence on ${REPO}#${PR} (#2771)"
}

# bind_canary_codex_review — #2771. Sets WAVE_CODEX_BOUND to the request
# comment the barrier must see answered, or leaves it empty when the barrier
# keeps its unbound behaviour. See the header.
#
# Order matters (Codex on #2875). An outstanding author request for this head
# is bound FIRST, before the rc-0 shortcut: a rerun after an unsolicited App
# review completed must still wait for the audit's own request, not open on
# that review. "For this head" means created at or after the head's last
# transition, read from GitHub's own clock: the PR's creation and any
# head_ref_force_pushed event. The pusher-set committer date is never used: a
# future-dated head discarded the audit's real request and dispatched unbound
# (Phase 4b on #2875). A request before the last transition belongs to an
# earlier canary head, so a fresh one is sent. A fast-forward push leaves no
# server-timed event; it can only make an older request look fresh, which the
# barrier will not see answered on this head, so it holds into the fail-open
# exit 4 rather than clearing.
WAVE_CODEX_BOUND=""
bind_canary_codex_review() {
  local check_rc=0 rc=0 head transition before after new out posted fresh
  # shellcheck source=lib/codex-request-evidence.sh
  . "$ROOT/scripts/lib/codex-request-evidence.sh" \
    || die 3 "cannot load the Codex request-evidence library"
  CANARY_AUTHOR="$(top_field author_identity)"
  CANARY_AUTHOR="${CANARY_AUTHOR:-nathanjohnpayne}"
  head="$pr_head"
  if [ -z "$head" ] && [ "${WAVE_AUDIT_LANE_VERIFIED_OK:-0}" = 1 ]; then
    head="${WAVE_AUDIT_TEST_CANARY_HEAD:-}"   # hermetic tests only
  fi
  [[ "$head" =~ ^[0-9a-fA-F]{40}$ ]] \
    || die 3 "no verified canary head for ${REPO}#${PR} to bind a Codex request to (#2771)"
  transition="$(canary_head_transition)" || exit "$?"
  # die inside a command substitution exits only the subshell; carry it out.
  before="$(canary_author_requests)" || exit "$?"
  fresh="$(printf '%s' "$before" | jq -r --arg c "$transition" '[.[] | select(.created_at >= $c) | .id] | max // empty')"
  if [ -n "$fresh" ]; then
    WAVE_CODEX_BOUND="$fresh"
    log "binding the barrier to the existing Codex request $WAVE_CODEX_BOUND for the ${REPO}#${PR} head (#2771)"
    return 0
  fi
  CODEX_REVIEW_CHECK_SKIP_CI=1 \
  CODEX_REVIEW_CHECK_REQUIRE_APPROVAL_ON_HEAD=1 \
  CODEX_REVIEW_CHECK_ALLOW_PHASE_4B_SUBSTITUTE=false \
    "$CODEX_CHECK" --diagnostic-signal-only "$PR" "$REPO" >/dev/null 2>&1 || check_rc=$?
  case "$check_rc" in
    0) log "Codex already spoke on the ${REPO}#${PR} head and no request of this audit is outstanding; barrier unbound (#2771)"; return 0 ;;
    1) ;;
    2) log "Codex cannot report on ${REPO}#${PR} (account or connection block); no request, barrier unbound (#2771)"; return 0 ;;
    *) die 3 "cannot read the Codex signal on ${REPO}#${PR} (codex-review-check.sh exit $check_rc) (#2771)" ;;
  esac
  out="$(MERGEPATH_PHASE_4A_GATED=true "$CODEX_REQUEST" --trigger-only --allow-moving-head "$PR" "$REPO")" || rc=$?
  case "$rc" in
    0) ;;
    5) log "Codex review is not enabled for ${REPO}#${PR}; no request, barrier unbound (#2771)"; return 0 ;;
    6) die 7 "Codex request refused on ${REPO}#${PR}: earlier review feedback is unaccounted — disposition it and rerun the audit (#2771)" ;;
    7)
      # The requester's exit 7 has two kinds (Phase 4b on #2875). A spent
      # blocking-review budget is a human stop: dispatching unbound could let
      # the barrier run out into exit 4, which fans out. Only a spent request
      # ceiling defers to the barrier's own cap path. Anything else is unknown.
      case "$(printf '%s' "$out" | jq -r '.cap_exhausted.kind // empty' 2>/dev/null || true)" in
        request-ceiling) log "Codex request ceiling is spent on ${REPO}#${PR}; barrier unbound, its cap path decides (#2771)"; return 0 ;;
        blocking-reviews) die 8 "Codex blocking-review budget is spent on ${REPO}#${PR}: a human stop, so no review runs and nothing fans out (#2771)" ;;
        *) die 3 "codex-review-request.sh exit 7 on ${REPO}#${PR} names no known cap kind (#2771)" ;;
      esac ;;
    *) die 3 "Codex request on canary ${REPO}#${PR} failed (codex-review-request.sh exit $rc) (#2771)" ;;
  esac
  # Not `// empty`: jq's alternative operator treats false like null.
  posted="$(printf '%s' "$out" | jq -r '.trigger_posted | if type == "boolean" then tostring else empty end' 2>/dev/null || true)"
  case "$posted" in true|false) ;; *) die 3 "codex-review-request.sh output on ${REPO}#${PR} names no trigger_posted (#2771)" ;; esac
  after="$(canary_author_requests)" || exit "$?"
  new="$(jq -nc --argjson a "$after" --argjson b "$before" '[$a[].id] - [$b[].id]')"
  if [ "$new" != "[]" ]; then
    WAVE_CODEX_BOUND="$(printf '%s' "$new" | jq -r 'max')"
    log "requested Codex review on ${REPO}#${PR} (request $WAVE_CODEX_BOUND); the barrier waits on that request (#2771)"
  elif [ "$posted" = true ]; then
    die 3 "codex-review-request.sh reports a posted request on ${REPO}#${PR}, but no new author request appeared (#2771)"
  else
    log "codex-review-request.sh posted no request on ${REPO}#${PR} (a Codex signal appeared first); barrier unbound (#2771)"
  fi
}

# --- args -------------------------------------------------------------------
PR=""; REPO=""; BASE=""; HEAD_SHA=""; DRY_RUN=false; CAPTURE_INPUT_DIR=""
HISTORICAL_END=""; FINALIZE_HISTORICAL=false
ADMIN_OVERRIDE_SET=false; ADMIN_OVERRIDE_QUOTE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --repo)      REPO="${2:-}"; shift 2 ;;
    --base)      BASE="${2:-}"; shift 2 ;;
    --head-sha)  HEAD_SHA="${2:-}"; shift 2 ;;
    --dry-run)   DRY_RUN=true; shift ;;
    --capture-input-dir) CAPTURE_INPUT_DIR="${2:-}"; DRY_RUN=true; shift 2 ;;
    --historical-end) HISTORICAL_END="${2:-}"; shift 2 ;;
    --finalize-historical) FINALIZE_HISTORICAL=true; shift ;;
    --admin-override)
      # A quote that starts with "-" is a mistyped option (`--admin-override
      # --dry-run`), never authorization text: refuse rather than consume it.
      case "${2:-}" in ''|-*) die 3 "--admin-override requires the owner's quoted authorization" ;; esac
      ADMIN_OVERRIDE_SET=true; ADMIN_OVERRIDE_QUOTE="$2"; shift 2 ;;
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
[ -z "$CAPTURE_INPUT_DIR" ] || { [ -d "$CAPTURE_INPUT_DIR" ] && [ ! -L "$CAPTURE_INPUT_DIR" ]; } \
  || die 3 "capture directory must already exist and be a real directory"
[ -x "$ORCH" ] || [ -f "$ORCH" ] || die 3 "orchestrator not found: $ORCH"
# The orchestrator's quote checks, applied here before any capture, budget or
# empty-scope exit can act on (or tag the watermark for) an unusable quote.
if [ "$ADMIN_OVERRIDE_SET" = true ]; then
  case "$ADMIN_OVERRIDE_QUOTE" in
    *[![:space:]]*) ;;
    *) die 3 "--admin-override requires a non-empty owner authorization quote" ;;
  esac
  case "$ADMIN_OVERRIDE_QUOTE" in
    *$'\n'*|*$'\r'*) die 3 "--admin-override quote must be a single line" ;;
  esac
  [ "${#ADMIN_OVERRIDE_QUOTE}" -le 500 ] || die 3 "--admin-override quote must be at most 500 characters"
fi

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
# #2879: only `hold` turns the switch on, and only then are its keys
# validated, so a switch-off run never fails on them (default-off is inert).
# Any other value reads as fail-open.
UNAVAILABLE_POLICY="$(audit_field unavailable_policy)"
case "${UNAVAILABLE_POLICY:-fail-open}" in
  hold|fail-open) ;;
  *) log "WARNING: propagation_audit.unavailable_policy '$UNAVAILABLE_POLICY' is not hold; treating it as fail-open" ;;
esac
[ "$UNAVAILABLE_POLICY" = hold ] || UNAVAILABLE_POLICY=fail-open
HOLD_MAX=3
if [ "$UNAVAILABLE_POLICY" = hold ]; then
  HOLD_MAX="$(audit_field hold_max_attempts)"; HOLD_MAX="${HOLD_MAX:-3}"
  case "$HOLD_MAX" in ''|*[!0-9]*) die 3 "invalid propagation_audit.hold_max_attempts '$HOLD_MAX'" ;; esac
  { [ "$HOLD_MAX" -ge 1 ] && [ "$HOLD_MAX" -le 10 ]; } || die 3 "propagation_audit.hold_max_attempts out of range [1,10]: $HOLD_MAX"
fi
EXCLUDES="$(audit_list scope_exclude_prefixes)"
[ -n "$EXCLUDES" ] || EXCLUDES="$(printf 'tests/\ndocs/')"

# --- resolve the wave head ----------------------------------------------------
# The propagation lane derives and byte-verifies against the sha in the
# BRANCH NAME (mergepath-sync/<sha> or
# mergepath-sync/sync-all-<sha>[-<scope-digest>]), not the title — an edited
# or stale title could point the audit (and the watermark) at canonical
# commits the lane never verified (#663 round-3 P1). The branch is the
# source of truth; a parseable title must agree with it.
PR_HEAD_OID=""
PR_BASE_OID=""
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
  meta="$(gh pr view "$PR" --repo "$REPO" --json title,headRefName,headRefOid,baseRefOid --jq '[.title, .headRefName, .headRefOid, .baseRefOid] | @tsv' 2>/dev/null)" \
    || die 3 "could not read PR $REPO#$PR metadata"
  title="$(printf '%s' "$meta" | cut -f1)"
  branch="$(printf '%s' "$meta" | cut -f2)"
  PR_HEAD_OID="$(printf '%s' "$meta" | cut -f3)"
  PR_BASE_OID="$(printf '%s' "$meta" | cut -f4)"
  branch_sha="$(printf '%s\n' "$branch" | sed -n \
    -e 's|.*/sync-all-\([0-9a-f]\{7,40\}\)-[0-9a-f]\{12\}$|\1|p' \
    -e 's|.*/sync-all-\([0-9a-f]\{7,40\}\)$|\1|p' \
    -e 's|.*/\([0-9a-f]\{7,40\}\)$|\1|p')"
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
# Fail closed unless trusted code freshly verifies the live canary pair.
# A bot-authored marker cannot prove which workflow or bytes produced it.
# WAVE_AUDIT_LANE_VERIFIED_OK=1 overrides — hermetic tests only.
pr_head=""
pr_base=""
if [ "${WAVE_AUDIT_LANE_VERIFIED_OK:-0}" != "1" ]; then
  command -v gh >/dev/null 2>&1 || die 3 "gh is required for the lane-verification precondition"
  if [ -n "$PR_HEAD_OID" ] && [ -n "$PR_BASE_OID" ]; then
    pr_head="$PR_HEAD_OID"
    pr_base="$PR_BASE_OID"
  else
    live_pair="$(gh pr view "$PR" --repo "$REPO" --json headRefOid,baseRefOid --jq '[.headRefOid, .baseRefOid] | @tsv' 2>/dev/null)" \
      || die 3 "could not read PR $REPO#$PR head/base for lane verification"
    pr_head="$(printf '%s' "$live_pair" | cut -f1)"
    pr_base="$(printf '%s' "$live_pair" | cut -f2)"
  fi
  [[ "$pr_head" =~ ^[0-9a-fA-F]{40}$ ]] && [[ "$pr_base" =~ ^[0-9a-fA-F]{40}$ ]] \
    || die 3 "invalid PR head/base reading $REPO#$PR for lane verification"
  lane_pr=$(gh api "repos/$REPO/pulls/$PR") \
    || die 3 "could not read the canary for live byte verification"
  lane_base_ref=$(printf '%s' "$lane_pr" | jq -er '.base.ref | select(type == "string" and length > 0)') \
    || die 3 "could not read the canary base ref"
  lane_base_sha=$(printf '%s' "$lane_pr" | jq -er '.base.sha')
  lane_default=$(printf '%s' "$lane_pr" | jq -er '.base.repo.default_branch | select(type == "string" and length > 0)') \
    || die 3 "could not read the canary default branch"
  [ "$lane_base_sha" = "$pr_base" ] || die 3 "canary base changed before policy resolution"
  lane_policy=$(bash "$ROOT/scripts/workflow/resolve_base_policy.sh" --repo "$REPO" \
    --base-ref "$lane_base_ref" --base-sha "$pr_base" --default-branch "$lane_default" --materialize-default) \
    || die 3 "could not read the canary governing policy"
  lane_rc=0
  printf '%s' "$lane_pr" | bash "$ROOT/scripts/workflow/verify-live-propagation.sh" \
    "$REPO" "$PR" "$pr_head" "$pr_base" "$lane_policy" >/dev/null || lane_rc=$?
  rm -f "$lane_policy"
  [ "$lane_rc" -eq 0 ] || die 3 "canary $REPO#$PR is not a byte-verified live mirror; refusing to dispatch"
  log "canary lane verified for PR head/base $pr_head/$pr_base"
fi

# Re-read the live pair at each authority boundary. The initial byte proof
# binds the originally observed pair; a later pair is never adopted implicitly. This closes the intervals in
# which a same-head base move could otherwise let a stale review dispatch or
# receipt advance the wave. It is still a read-before-write fence, not an
# atomic GitHub transaction. The override remains limited to hermetic tests.
revalidate_canary_pair() { # revalidate_canary_pair <operation>
  local operation="$1" live_pair live_head live_base
  [ "${WAVE_AUDIT_LANE_VERIFIED_OK:-0}" != "1" ] || return 0
  live_pair="$(gh pr view "$PR" --repo "$REPO" --json headRefOid,baseRefOid --jq '[.headRefOid, .baseRefOid] | @tsv' 2>/dev/null)" \
    || die 3 "could not re-read PR $REPO#$PR head/base before $operation"
  live_head="$(printf '%s' "$live_pair" | cut -f1)"
  live_base="$(printf '%s' "$live_pair" | cut -f2)"
  [[ "$live_head" =~ ^[0-9a-fA-F]{40}$ ]] && [[ "$live_base" =~ ^[0-9a-fA-F]{40}$ ]] \
    || die 3 "invalid PR head/base reading $REPO#$PR before $operation"
  [ "$live_head" = "$pr_head" ] && [ "$live_base" = "$pr_base" ] \
    || die 3 "canary $REPO#$PR moved from verified pair $pr_head/$pr_base to $live_head/$live_base before $operation — refusing stale authority"
}

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
  for cleanup_file in "${TMP_FILES[@]}"; do rm -rf "$cleanup_file"; done
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
      revalidate_canary_pair "publishing retained prefix receipt"
      git -C "$REPO_DIR" push -q origin "refs/tags/$retained_tag" \
        || die 3 "prefix receipt $retained_tag remains local because retry push failed"
    fi
    jq -n --arg base "$(printf '%s' "$retained_json" | jq -r .chunk_base)" \
      --arg end "$RANGE_HEAD" --arg head "$HEAD_FULL" --arg tag "$retained_tag" \
      --argjson dry "$([ "$DRY_RUN" = true ] && echo true || echo false)" \
      --argjson verdict "$(printf '%s' "$retained_json" | jq -c .validated_verdict)" \
      --argjson ao "$(printf '%s' "$retained_json" | jq -c '.review_provenance |
        {admin_overridden:(.admin_overridden // []),admin_override_quote:(.admin_override_quote // null)}')" '
        {historical_chunk:{base:$base,end:$end,full_head:$head},clearance:false,
         prefix_receipt:$tag,receipt_written:($dry|not),receipt_reused:true,
         watermark_advanced:false,fanout_authorized:false,dry_run:$dry,
         validated_verdict:$verdict} + $ao'
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
REPORT_BYTES="$BYTES"
REPORT_FILES="$FILES"

# advance_watermark — annotated (unsigned) tag on the audited head, pushed to
# origin so every checkout resolves the same base next wave. Only called on a
# posted APPROVED or a scope-empty range, never on --dry-run. A tag that
# already exists locally (e.g. a prior run whose PUSH failed) is not treated
# as success — the push runs unconditionally, so the documented rerun
# recovery actually recovers (Codex P2 on #663); pushing an already-present
# remote tag with the same object is a no-op success.
# #2633: a watermark is marked when this run carried the owner's override, or
# when it finalizes historical coverage whose retained receipts record one: a
# finalization needs no override of its own, yet its clearance rests on them.
admin_override_marked() {
  if [ "$ADMIN_OVERRIDE_SET" = true ]; then echo true; return; fi
  if [ "$FINALIZE_HISTORICAL" = true ] && jq -se \
    'any(.[]; (.review_provenance.admin_overridden // []) | length > 0)' "$RECEIPT_CHAIN" >/dev/null; then
    echo true; return
  fi
  echo false
}

advance_watermark() {
  local tag="${TAG_PREFIX}/${HEAD_FULL}"
  if git -C "$REPO_DIR" rev-parse --verify --quiet "refs/tags/$tag" >/dev/null; then
    log "watermark $tag already present locally — ensuring it is on origin"
  else
    revalidate_canary_pair "writing wave watermark"
    GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=tag.gpgsign GIT_CONFIG_VALUE_0=false \
      git -C "$REPO_DIR" tag -a "$tag" \
        -m "wave-audit: base=${BASE_FULL} canary=${REPO}#${PR} effort=${EFFORT} files=${REPORT_FILES} bytes=${REPORT_BYTES}$([ "$(admin_override_marked)" = true ] && printf ' admin-override=true')" \
        "$HEAD_FULL"
  fi
  revalidate_canary_pair "publishing wave watermark"
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
     usage_source, token_count,
     admin_overridden:(.admin_overridden // []),
     admin_override_quote:(.admin_override_quote // null)}')"
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
    revalidate_canary_pair "writing historical prefix receipt"
    GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=tag.gpgsign GIT_CONFIG_VALUE_0=false \
      git -C "$REPO_DIR" tag -a "$tag" -F "$receipt_file" "$RANGE_HEAD"
  fi
  revalidate_canary_pair "publishing historical prefix receipt"
  git -C "$REPO_DIR" push -q origin "refs/tags/$tag" \
    || die 3 "prefix receipt $tag exists locally but the push failed — rerun to retain this exact chunk"
  PREFIX_TAG_RESULT="$tag"
}

# #2633: the override fields every wave summary carries. They start from this
# run's flag and take the orchestrator's own record once it has run, so a
# wave whose review absorbed a tripwire reports the quote and reason codes.
WAVE_ADMIN_OVERRIDE="$(jq -nc --arg q "$ADMIN_OVERRIDE_QUOTE" --argjson set "$ADMIN_OVERRIDE_SET" \
  '{admin_overridden:[],admin_override_quote:(if $set then $q else null end)}')"

emit_json() { # emit_json <orch_exit_or_null> <tagged> <skipped_reason_or_null>
  jq -n --argjson ao "$WAVE_ADMIN_OVERRIDE" \
    --arg base "$BASE_FULL" --arg head "$HEAD_FULL" --arg repo "$REPO" \
    --argjson pr "$PR" --argjson files "$REPORT_FILES" --argjson bytes "$REPORT_BYTES" \
    --argjson limit "$DIFF_MAX" \
    --argjson watermark "$BASE_WATERMARK_JSON" \
    --arg effort "$EFFORT" --argjson timeout "$TIMEOUT" \
    --argjson orch "$1" --argjson tagged "$2" --argjson skipped "$3" \
    --argjson dry "$([ "$DRY_RUN" = true ] && echo true || echo false)" \
    '{base:$base, base_watermark:$watermark, head:$head, repo:$repo, pr:$pr, scope_files:$files,
      scope_bytes:$bytes, diff_max_bytes:$limit, effort:$effort, timeout_seconds:$timeout,
      orchestrator_exit:$orch, watermark_advanced:$tagged, skipped:$skipped,
      dry_run:$dry} + $ao'
}

# --- held waves (#2879) --------------------------------------------------------
# Under unavailable_policy: hold, "no independent audit happened" holds the
# fan-out instead of failing open. Each hold is an annotated tag
#   wave-audit-hold/<head>/<base>/<n>
# on origin: only hub writers can create one, every checkout counts the same
# set, and counting records never compares clocks. The count decides only when
# retrying stops; it grants nothing. A canary comment makes each hold visible
# on the PR; the tag is the state.
HOLD_REF_PREFIX="refs/tags/${HOLD_TAG_PREFIX}/${HEAD_FULL}/${BASE_FULL}"

# hold_count — holds recorded on origin for this exact range. A failed read
# exits 3: a fresh counter would restart the bound.
hold_count() {
  local refs
  refs="$(git -C "$REPO_DIR" ls-remote --refs --tags origin "${HOLD_REF_PREFIX}/*" 2>/dev/null)" \
    || die 3 "could not list ${HOLD_TAG_PREFIX}/* holds from origin (#2879)"
  printf '%s\n' "$refs" | awk -v p="${HOLD_REF_PREFIX}/" '
    { ref = $2; if (index(ref, p) == 1) { n = substr(ref, length(p) + 1); if (n ~ /^[1-9][0-9]*$/) c++ } }
    END { print c + 0 }'
}

# needs-owner recovery is manual until #2900 lands: no release command exists,
# so none is printed.
MANUAL_RECOVERY="No scripted recovery exists yet: the owner fans this wave out by hand under break-glass, recording it in the wave tracker. A scripted owner release is tracked in %s"
recovery_text() { printf "$MANUAL_RECOVERY" "https://github.com/nathanjohnpayne/mergepath/issues/2900"; }

# post_canary_record <body-file> — posts through the reviewer wrapper and
# prints the comment URL. Returns non-zero on failure; callers decide.
post_canary_record() {
  "$COMMENT_CMD" -- gh pr comment "$PR" --repo "$REPO" --body-file "$1" | tail -n 1 # NO_BARE_GH_WRITE_EXEMPT: COMMENT_CMD defaults to scripts/gh-as-reviewer.sh, which verifies the reviewer token; tests inject a fake.
  return "${PIPESTATUS[0]}"
}

# hold_json <state> <attempt> <reason-json> <comment-url> — the hold object.
hold_json() {
  jq -nc --arg state "$1" --argjson attempt "$2" --argjson max "$HOLD_MAX" \
    --argjson why "$3" --arg url "$4" --arg recovery "$(recovery_text)" \
    '$why + {policy:"hold", attempt:$attempt, max_attempts:$max,
      hold_comment_url:(if $url == "" then null else $url end),
      recovery:(if $state == "needs-owner" then {mode:"manual", detail:$recovery} else null end)}'
}

# emit_held_json <orch-exit> <state> <hold-json>
emit_held_json() {
  emit_json "$1" false null | jq --arg state "$2" --argjson hold "$3" \
    '. + {audit_state:$state, audited:false, fanout_authorized:false, hold:$hold}'
}

# orchestrator_hold_reason <orch-exit> — the reason the orchestrator gave, as
# evidence only: its last summary record and the barrier escalation it carried
# (#2771 binding: wave_binding names the bound request, the requests and runs
# it paired). Missing evidence reads as null, never as a guess.
orchestrator_hold_reason() {
  jq -sc --argjson orc "$1" --arg bound "${WAVE_CODEX_BOUND:-}" '
    (map(select(type == "object")) | last // {}) as $s
    | {orchestrator_exit:$orc,
       reason:($s.reason // "unknown"),
       codex_evidence:($s.barrier_escalation.codex_evidence // $s.codex_evidence // null),
       codex_binding:(if $bound == "" then null
         else {request:$bound} + ($s.barrier_escalation.wave_binding // {}) end),
       barrier_escalation:($s.barrier_escalation // null),
       retry_after:($s.retry_after // null)}' "$ORCH_OUTPUT" 2>/dev/null \
    || jq -nc --argjson orc "$1" '{orchestrator_exit:$orc, reason:"unknown", codex_evidence:null,
         codex_binding:null, barrier_escalation:null, retry_after:null}'
}

# record_hold <orch-exit> — the held arm. Records attempt n, posts the canary
# record and exits 11 (held) or 12 (needs-owner). Never writes a watermark.
record_hold() {
  local orc="$1" n tag why state rc note url="" body
  why="$(orchestrator_hold_reason "$orc")"
  n="$(hold_count)" || exit "$?"
  n=$((n + 1))
  state=held; rc=11
  [ "$n" -lt "$HOLD_MAX" ] || { state=needs-owner; rc=12; }
  tag="${HOLD_TAG_PREFIX}/${HEAD_FULL}/${BASE_FULL}/${n}"
  note="$(mktemp "${TMPDIR:-/tmp}/wave-audit-hold.XXXXXX")"
  TMP_FILES[${#TMP_FILES[@]}]="$note"
  printf '%s' "$why" | jq --arg repo "$REPO" --argjson pr "$PR" --arg canary "${pr_head:-}" \
    --argjson n "$n" --argjson max "$HOLD_MAX" --arg state "$state" \
    '{version:1, kind:"wave-audit-hold", audited:false, state:$state, attempt:$n,
      max_attempts:$max, canary:{repo:$repo, pr:$pr, head:$canary}} + .' > "$note"
  revalidate_canary_pair "recording a held wave"
  GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=tag.gpgsign GIT_CONFIG_VALUE_0=false \
    git -C "$REPO_DIR" tag -a -f "$tag" -F "$note" "$HEAD_FULL" >/dev/null \
    || die 3 "could not write hold record $tag — no audit happened; do NOT fan out"
  git -C "$REPO_DIR" push -q origin "refs/tags/$tag" \
    || die 3 "could not push hold record $tag — no audit happened; do NOT fan out, rerun to record the hold"
  body="$(mktemp "${TMPDIR:-/tmp}/wave-audit-hold-body.XXXXXX")"
  TMP_FILES[${#TMP_FILES[@]}]="$body"
  {
    printf '## Wave audit held: no independent audit was performed\n\n'
    printf 'The Phase 4b reviewer was unavailable (orchestrator exit %s), so this wave is **held**. Do not fan out.\n\n' "$orc"
    printf -- '- Range: `%s..%s`\n' "$BASE_FULL" "$HEAD_FULL"
    printf -- '- Attempt %s of %s (state: `%s`)\n' "$n" "$HOLD_MAX" "$state"
    printf -- '- Reason: %s\n' "$(printf '%s' "$why" | jq -r '.reason' | tr -d '<>')"
    printf -- '- Codex evidence: `%s`\n' "$(printf '%s' "$why" | jq -r '.codex_evidence // "none"' | tr -d '<>`')"
    if [ "$state" = needs-owner ]; then
      printf '\nRetries are exhausted. %s\n' "$(recovery_text)"
    else
      printf '\nRerun the same `scripts/wave-audit.sh` command later.\n'
    fi
    printf '\n<!-- mergepath-wave-audit-hold:v1 %s -->\n' "$(jq -c . "$note" | sed 's/-/\\u002d/g')"
  } > "$body"
  url="$(post_canary_record "$body")" \
    || { url=""; log "WARNING: hold $tag is recorded, but the canary comment failed to post"; }
  emit_held_json "$orc" "$state" "$(hold_json "$state" "$n" "$why" "$url")"
  if [ "$state" = needs-owner ]; then
    log "reviewer unavailable (orchestrator exit $orc) — wave HELD, attempt $n of $HOLD_MAX: needs owner. No independent audit was performed; no watermark; do NOT fan out."
    log "$(recovery_text)"
  else
    log "reviewer unavailable (orchestrator exit $orc) — wave HELD, attempt $n of $HOLD_MAX. No independent audit was performed; no watermark; do NOT fan out. Rerun the same command later."
  fi
  exit "$rc"
}

if [ "$FINALIZE_HISTORICAL" = true ]; then
  [ "$PREFIX_BASE" = "$HEAD_FULL" ] \
    || die 3 "historical coverage is incomplete: retained through $PREFIX_BASE, intended head is $HEAD_FULL"
  RECEIPT_PACKAGE="$(mktemp "${TMPDIR:-/tmp}/wave-audit-cumulative.XXXXXX")"
  TMP_FILES[${#TMP_FILES[@]}]="$RECEIPT_PACKAGE"
  REPORT_BYTES=0
  REPORT_FILES=0
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
    REPORT_BYTES=$((REPORT_BYTES + verify_bytes))
    REPORT_FILES=$((REPORT_FILES + verify_files))
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
  log "finalizing explicit cumulative historical coverage from $BASE_FULL through $HEAD_FULL — ${REPORT_FILES} file(s), ${REPORT_BYTES} bytes across retained chunks (review package: ${BYTES} bytes)"
fi

log "audit range ${RANGE_BASE} .. ${RANGE_HEAD} (intended head ${HEAD_FULL}) — ${REPORT_FILES} file(s), ${REPORT_BYTES} bytes in scope (effort=${EFFORT}, timeout=${TIMEOUT}s)"

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

# Regeneration mode never dispatches a reviewer, writes a receipt, or advances
# a watermark. The trusted orchestrator independently invokes this mode.
if [ -n "$CAPTURE_INPUT_DIR" ]; then
  cp "$DIFF_FILE" "$CAPTURE_INPUT_DIR/review.diff"
  # #2633: a base on the audited head's first-parent history is a merged hub
  # state, so the curated diff carries no never-merged intermediate bytes.
  # Only then may escalation treat the verified canary as reviewed content.
  # grep must drain rev-list: with pipefail, an early `grep -q` exit SIGPIPEs
  # the producer and reads a long, valid history as "not found".
  base_on_first_parent=false
  if git -C "$REPO_DIR" rev-list --first-parent "$HEAD_FULL" | grep -Fx -- "$BASE_FULL" >/dev/null; then
    base_on_first_parent=true
  fi
  # The audited head itself must be a merged hub state. The propagation
  # verifier byte-checks the canary against the source SHA but does not prove
  # that SHA merged, so without this an unmerged commit sitting on the
  # watermark would pass the base test above.
  #
  # The trust anchor is GitHub's own default branch of the hub, read live: a
  # commit-only clone (no trees or blobs, about 1 s) of the public hub, whose
  # HEAD is the default branch GitHub serves. No local state is consulted
  # (#2694): a stale `refs/remotes/origin/HEAD` could name an old,
  # since-unprotected branch, and the trusted checkout's own HEAD could carry
  # a local, unpushed commit (#628 is an operational rule, not a check). The
  # hub is public, so the clone needs no credentials in the capture child's
  # isolated environment. First-parent, because the hub allows merge commits:
  # a commit reachable only through a merged branch never was a merged head.
  # Any failure withholds the exemption (a human is asked), never grants it.
  head_on_hub_default=false
  if hub_history=$(mktemp -d "${TMPDIR:-/tmp}/wave-audit-hub.XXXXXX"); then
    TMP_FILES[${#TMP_FILES[@]}]="$hub_history"
    if GIT_TERMINAL_PROMPT=0 git clone --quiet --bare --single-branch --no-tags --filter=tree:0 \
         https://github.com/nathanjohnpayne/mergepath.git "$hub_history/hub.git" >/dev/null 2>&1 \
       && git -C "$hub_history/hub.git" rev-list --first-parent HEAD | grep -Fx -- "$HEAD_FULL" >/dev/null; then
      head_on_hub_default=true
    fi
  fi
  jq -n --arg base "$BASE_FULL" --arg head "$HEAD_FULL" \
    --argjson first_parent "$base_on_first_parent" --argjson on_default "$head_on_hub_default" \
    --arg end "${HISTORICAL_END:+$RANGE_HEAD}" --argjson final "$FINALIZE_HISTORICAL" \
    --arg manifest "$MANIFEST_BLOB" --arg fingerprint "$SCOPE_FINGERPRINT" \
    '{version:1,canonical_base_sha:$base,canonical_head_sha:$head,
      historical_end_sha:$end,finalize_historical:$final,
      manifest_blob:$manifest,scope_fingerprint:$fingerprint,
      base_on_first_parent:$first_parent,head_on_hub_default:$on_default}' > "$CAPTURE_INPUT_DIR/scope.json"
  chmod 400 "$CAPTURE_INPUT_DIR/review.diff" "$CAPTURE_INPUT_DIR/scope.json"
  exit 0
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

# --- held waves: terminal state (#2879) ---------------------------------------
# Only a run that could publish consults the hold. A needs-owner range never
# asks Codex or dispatches a review again: that is the bound.
if [ "$UNAVAILABLE_POLICY" = hold ] && [ "$DRY_RUN" = false ] && [ -z "$HISTORICAL_END" ]; then
  HOLDS="$(hold_count)" || exit "$?"
  if [ "$HOLDS" -ge "$HOLD_MAX" ]; then
    emit_held_json null needs-owner "$(hold_json needs-owner "$HOLDS" \
      '{"orchestrator_exit":null,"reason":"hold attempts exhausted","codex_evidence":null,"codex_binding":null,"barrier_escalation":null,"retry_after":null}' "")"
    log "wave HELD: ${HOLDS} of ${HOLD_MAX} attempts recorded for ${BASE_FULL}..${HEAD_FULL} — needs owner. No review was dispatched; no watermark; do NOT fan out."
    log "$(recovery_text)"
    exit 12
  fi
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
SCOPE_REQUEST="$(mktemp "${TMPDIR:-/tmp}/wave-audit-scope.XXXXXX")"
TMP_FILES[${#TMP_FILES[@]}]="$SCOPE_REQUEST"
jq -n --arg base "$BASE_FULL" --arg head "$HEAD_FULL" \
  --arg end "${HISTORICAL_END:+$RANGE_HEAD}" --argjson final "$FINALIZE_HISTORICAL" \
  '{version:1,canonical_base_sha:$base,canonical_head_sha:$head,
    historical_end_sha:$end,finalize_historical:$final}' > "$SCOPE_REQUEST"
orch_args+=(--wave-scope-file "$SCOPE_REQUEST")
# Pin review publication to the lane-verified pair: without --head, the
# orchestrator could approve a pushed canary head the lane never verified;
# without --expected-base-sha, a same-head retarget during the long review
# interval could publish approval for the wrong base. The orchestrator's own
# final pair check closes that provider interval.
if [ -n "$pr_head" ]; then
  orch_args[${#orch_args[@]}]="--head"
  orch_args[${#orch_args[@]}]="$pr_head"
  orch_args[${#orch_args[@]}]="--expected-base-sha"
  orch_args[${#orch_args[@]}]="$pr_base"
fi
if [ "$DRY_RUN" = true ] || [ -n "$HISTORICAL_END" ]; then
  orch_args[${#orch_args[@]}]="--dry-run"
fi
# A retained prefix is reusable evidence, not a non-persisting preview. Keep
# the orchestrator's deterministic tripwires before its historical model run.
if [ -n "$HISTORICAL_END" ] && [ "$DRY_RUN" = false ]; then
  orch_args[${#orch_args[@]}]="--retain-evidence"
fi
if [ "$ADMIN_OVERRIDE_SET" = true ]; then
  orch_args[${#orch_args[@]}]="--admin-override"
  orch_args[${#orch_args[@]}]="$ADMIN_OVERRIDE_QUOTE"
fi
if [ "$EFFORT" != "minimal" ]; then
  export P4B_CLAUDE_EFFORT="$EFFORT"
fi
# #2771: only a run that can publish asks Codex. Dry runs, capture runs and
# historical chunks force --dry-run, post nothing, and skip the barrier.
if [ "$DRY_RUN" = false ] && [ -z "$HISTORICAL_END" ]; then
  # The requester resolves the live head itself, so the verified pair is
  # rechecked first; the recheck before dispatch below still stands.
  revalidate_canary_pair "requesting the canary Codex review"
  bind_canary_codex_review
  if [ -n "$WAVE_CODEX_BOUND" ]; then
    orch_args[${#orch_args[@]}]="--wave-codex-request"
    orch_args[${#orch_args[@]}]="$WAVE_CODEX_BOUND"
  fi
fi
revalidate_canary_pair "dispatching external review"
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
  # #2633: a chunk validated past an overridden tripwire says so in every
  # summary and in its retained receipt.
  admin_override="$(printf '%s' "$orch_summary" | jq -c \
    '{admin_overridden:(.admin_overridden // []),admin_override_quote:(.admin_override_quote // null)}')"
  if [ -n "$pr_head" ]; then
    [ "$(printf '%s' "$orch_summary" | jq -r '.head_sha // empty')" = "$pr_head" ] \
      || { cat "$ORCH_OUTPUT"; die 3 "historical dry-run verdict is not pinned to lane-verified canary head $pr_head"; }
  fi
  clean=false
  printf '%s' "$verdict" | jq -e '.verdict == "APPROVED" and (.findings | length == 0)' >/dev/null && clean=true
  if [ "$clean" != true ]; then
    jq -n --arg base "$RANGE_BASE" --arg end "$RANGE_HEAD" --arg head "$HEAD_FULL" \
      --argjson verdict "$verdict" --argjson ao "$admin_override" \
      '{historical_chunk:{base:$base,end:$end,full_head:$head},clearance:false,
        prefix_receipt:null,watermark_advanced:false,fanout_authorized:false,
        validated_verdict:$verdict} + $ao'
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
    --argjson verdict "$verdict" --argjson ao "$admin_override" '
      {historical_chunk:{base:$base,end:$end,full_head:$head},clearance:false,
       prefix_receipt:(if $tag == "null" then null else $tag end),
       receipt_written:($dry|not),watermark_advanced:false,fanout_authorized:false,
       dry_run:$dry,validated_verdict:$verdict} + $ao'
  log "historical chunk validated clean — retained as non-clearance prefix only; explicit --finalize-historical is still required"
  exit 9
else
  set +e
  ORCH_OUTPUT="$(mktemp "${TMPDIR:-/tmp}/wave-audit-orchestrator.XXXXXX")"
  TMP_FILES[${#TMP_FILES[@]}]="$ORCH_OUTPUT"
  P4B_CODEX_EFFORT="$EFFORT" \
  P4B_ADAPTER_TIMEOUT_SECONDS="$TIMEOUT" \
  P4B_DIFF_MAX_BYTES="$DIFF_MAX" \
    "$ORCH" "${orch_args[@]}" > "$ORCH_OUTPUT"
  orc=$?
  set -e
  cat "$ORCH_OUTPUT"
  # The orchestrator's last record that carries override fields wins.
  orch_override="$(jq -sc 'map(select(type == "object" and has("admin_overridden"))) | last
    | if . == null then empty else {admin_overridden, admin_override_quote} end' "$ORCH_OUTPUT" 2>/dev/null || true)"
  [ -z "$orch_override" ] || WAVE_ADMIN_OVERRIDE="$orch_override"
fi

if [ "$FINALIZE_HISTORICAL" = true ] && [ "$orc" -ne 0 ]; then
  # #2879: finalization publishes, so under hold an unavailable reviewer
  # holds it like an ordinary wave.
  if [ "$UNAVAILABLE_POLICY" = hold ] && [ "$DRY_RUN" = false ]; then
    case "$orc" in
      1|3|6|7|8|10) ;;
      *) record_hold "$orc" ;;
    esac
  fi
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
      if [ "$UNAVAILABLE_POLICY" = hold ]; then
        emit_json 0 true null | jq '. + {audit_state:"approved", audited:true, fanout_authorized:true}'
      else
        emit_json 0 true null
      fi
      log "APPROVED posted — fan out (mirrors merge on CI + lane; open them with --coderabbit-ignore, no @codex trigger)"
    fi
    ;;
  1)
    emit_json 1 false null
    log "CHANGES_REQUESTED posted on ${REPO}#${PR} — fix at the mergepath source, re-cut the wave, re-run the audit on the fresh canary"
    ;;
  3)
    # Input integrity/config/usage/infrastructure error — including a failed review POST
    # (Codex P2 on #663). No reliable verdict exists and the local setup or
    # the GitHub write path is broken: this is NOT a proceedable audit
    # miss, so do not suggest fanning out on it.
    emit_json 3 false null
    log "ERROR: orchestrator input integrity/infrastructure/config failure (exit 3) — no verdict exists; fix the configuration or write path and rerun the audit before fanning out"
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
  8)
    emit_json 8 false null
    log "Phase 4b stopped without review authority on ${REPO}#${PR} (orchestrator exit 8: curated diff over budget, deterministic tripwire, or Codex-cap human tiebreaker) — no watermark; do NOT fan out or substitute Phase 4b authority"
    ;;
  10)
    emit_json 10 false null
    log "request-budget evidence failed on ${REPO}#${PR} (orchestrator exit 10) — no watermark; do NOT fan out or render a Phase 4b handoff; repair the read/head drift and retry"
    ;;
  *)
    # #2879: under hold, a dry run still previews only; a publishing run holds.
    if [ "$UNAVAILABLE_POLICY" = hold ] && [ "$DRY_RUN" = false ]; then
      record_hold "$orc"
    fi
    emit_json "$orc" false null
    if [ "$UNAVAILABLE_POLICY" = hold ]; then
      log "dry run: reviewer unavailable (orchestrator exit $orc) — a publishing run would HOLD this wave (#2879); no hold recorded"
      exit "$orc"
    fi
    log "reviewer unavailable (orchestrator exit $orc) — no watermark; the wave may proceed on CI + lane and this range chains into the next audit"
    ;;
esac
exit "$orc"
