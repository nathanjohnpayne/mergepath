#!/usr/bin/env bash
# coderabbit-should-invoke.sh — decide whether Phase 2.5 (CodeRabbit) runs
# for a given PR.
#
# SCOPE -- read this before assuming what the knob buys you (#1084 r1).
#
# This governs PHASE 2.5, the AGENT's wait-and-disposition phase. It does NOT
# stop the CodeRabbit App from reviewing: the shipped `.coderabbit.yml` sets
# `auto_review.enabled: true`, so the App starts on PR open, before this script
# ever runs. Skipping therefore:
#
#   * DOES save the agent the Phase 2.5 wait (bounded by
#     `coderabbit.max_wait_seconds`, 1245s here).
#   * Does NOT reduce provider invocations, and so does NOT reduce rate-limit
#     pressure. Reading this as a rate-limit remedy is reading it wrong.
#   * Leaves findings the App posts later UNWATCHED. Those are still
#     unresolved review conversations, and the pre-merge conversation gate
#     still blocks on them, so a skipped PR can still need thread triage.
#
# Actually reducing invocations needs an App-side opt-out (auto_review off, or
# path filters in `.coderabbit.yml`) and is deliberately not attempted here.
#
# CodeRabbit is advisory: it never carries the merge gate, and its severity
# gate is a clean no-op wherever `coderabbit.severity_gate.enabled` is false
# (the default on every consumer).
#
# The decision is deliberately a SCRIPT rather than agent judgement: "is this
# PR complex enough for CodeRabbit" must be reproducible across sessions and
# agents, and must be answerable the same way in CI as at the keyboard.
#
# Usage:
#   scripts/coderabbit-should-invoke.sh <PR#>
#   scripts/coderabbit-should-invoke.sh <PR#> --repo owner/name
#   scripts/coderabbit-should-invoke.sh <PR#> --json
#
# Exit codes:
#   0 — INVOKE CodeRabbit for this PR
#   1 — SKIP CodeRabbit for this PR
#   3 — bad arguments
#
# There is deliberately no config-error exit. An unreadable config, an
# unparseable knob, or a classifier that fails all resolve to INVOKE, because
# the two directions are not symmetric: skipping wrongly silently drops a
# review round, while invoking wrongly costs time on a PR that did not need
# it. Only an explicit, well-formed instruction may suppress a reviewer.
#
# Config (`.github/review-policy.yml`):
#   coderabbit.enabled: false        -> SKIP  (CodeRabbit not set up here)
#   coderabbit.invoke: always        -> INVOKE on every PR
#   coderabbit.invoke: complex-changes -> INVOKE only when
#                                       phase-4b-classifier.sh matches
#   coderabbit.invoke: never         -> SKIP on every PR
#   coderabbit.invoke absent         -> `always`, preserving the pre-#1084
#                                       behaviour for a repo that has not
#                                       adopted the knob.
#
# Bash 3.2 portable.

set -uo pipefail

# Follow symlinks before deriving anything from the script location. Invoked
# through a PATH symlink, `dirname "${BASH_SOURCE[0]}"` names the symlink's
# directory, so both the policy and the classifier would be looked up beside
# the link and an explicit `enabled: false` / `invoke: never` would be silently
# ignored (#1084 r2). Same bash-3.2 portable loop phase-4b-classifier.sh uses;
# BSD readlink has no portable `-f`.
_src="${BASH_SOURCE[0]}"
while [ -L "$_src" ]; do
  _target="$(readlink "$_src")"
  case "$_target" in
    /*) _src="$_target" ;;
    *)  _src="$(cd -P "$(dirname "$_src")" && pwd)/$_target" ;;
  esac
done
SCRIPT_DIR="$(cd -P "$(dirname "$_src")" && pwd)"
# Resolve the policy relative to the SCRIPT's checkout, not $PWD (#1084 r1).
# Launched from a subdirectory, or by absolute path from another working
# directory, a relative CONFIG reads the wrong checkout or no file at all --
# and an explicit `enabled: false` / `invoke: never` would then be silently
# ignored. Mirrors how phase-4b-classifier.sh locates the repo.
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG="$REPO_ROOT/.github/review-policy.yml"

PR_NUM=""
REPO=""
JSON=false
while [ "$#" -gt 0 ]; do
  case "$1" in
    --repo)
      # `shift 2` with only one argument left FAILS and shifts NOTHING; with
      # errexit off the loop then re-reads `--repo` forever (#1084 r1).
      if [ "$#" -lt 2 ] || [ -z "${2:-}" ]; then
        echo "Error: --repo requires a value" >&2; exit 3
      fi
      REPO="$2"; shift 2 ;;
    --json) JSON=true; shift ;;
    --help|-h) sed -n '2,40p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) echo "Error: unknown flag '$1'" >&2; exit 3 ;;
    *) if [ -z "$PR_NUM" ]; then PR_NUM="$1"; else echo "Error: unexpected argument '$1'" >&2; exit 3; fi; shift ;;
  esac
done

# Leading digit 1-9: `0` is not a PR number, and accepting it sent callers to
# the wait/API path for a PR that cannot exist (#1084 r3). Matches the
# constraint phase-4b-classifier.sh already applies.
# --json is assembled with jq. Without it, `emit` would fail while the script
# carries on and exits with the DECISION code -- for `always` that is exit 0
# with empty stdout, so a machine caller reads success and gets no document
# (#1084 r4). Check the dependency before any decision path can be taken.
if [ "$JSON" = true ] && ! command -v jq >/dev/null 2>&1; then
  echo "Error: --json requires jq, which is not on PATH" >&2
  exit 3
fi

if ! [[ "$PR_NUM" =~ ^[1-9][0-9]*$ ]]; then
  echo "Error: PR# must be a positive integer; got '${PR_NUM:-}'" >&2
  exit 3
fi
# Owner must start alphanumeric (GitHub forbids a leading dot or dash on a
# user/org); a REPO NAME may start with a dot -- `owner/.github` is a real and
# common repository. Neither existing validator in scripts/ encodes both: this
# one was permissive on the owner, the classifier strict on the repo name, so
# `owner/.github` passed here and was rejected there, making every routine PR
# invoke (#1084 r11). Aligning to either existing pattern would keep a
# divergence; this is the intersection of the two correct halves.
if [ -n "$REPO" ] && ! [[ "$REPO" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*/[A-Za-z0-9._-]+$ ]]; then
  echo "Error: invalid --repo value: '$REPO' (expected owner/name)" >&2
  exit 3
fi

# Read a scalar under the top-level `coderabbit:` block. Same state-machine
# shape as coderabbit_field in coderabbit-wait.sh, kept local so this script
# has no sourcing dependency and can be run standalone from any checkout.
coderabbit_field() {  # <field>
  local fld=$1
  [ -f "$CONFIG" ] || return 0
  awk -v fld="$fld" '
    function keyname(line,   k) {
      # Leading token up to the colon, with surrounding quotes stripped.
      # `"invoke": always` is the same key as `invoke: always` to any YAML
      # reader, and counting only the bare spelling let a quoted duplicate
      # slip past the ambiguity guard (#1084 r8).
      k = line
      sub(/^[[:space:]]+/, "", k)
      sub(/:.*$/, "", k)
      sub(/[[:space:]]+$/, "", k)
      # Strip quotes only as a MATCHED pair. Removing boundary quotes
      # unconditionally turned the mistyped key `invoke": never` -- whose real
      # key is `invoke"` -- into `invoke`, so a key that is absent produced a
      # suppressing value (#1084 r9).
      if (length(k) >= 2) {
        f = substr(k, 1, 1); l = substr(k, length(k), 1)
        if ((f == "\"" || f == "\047") && f == l) k = substr(k, 2, length(k) - 2)
      }
      return k
    }
    function indentof(line,   m) { match(line, /^[[:space:]]*/); return RLENGTH }

    # YAML forbids TAB characters in indentation, and go-yaml (the parser this
    # fleet uses, via scripts/lib/ensure-yq.sh) rejects the whole DOCUMENT when it
    # finds one -- measured, not inferred: a tab-indented child, a tab after
    # leading spaces, a tab-indented comment, and a tab-only blank line all
    # fail to load, while a tab AFTER a value parses fine. `[[:space:]]`
    # matched the tab as ordinary indentation, so `coderabbit:<TAB>invoke:
    # never` read as a valid `never` and suppressed Phase 2.5 on a file no
    # parser would accept (#1084 r12).
    #
    # Scoped to the document, not to the block: a tab under ANY top-level key
    # -- before or after `coderabbit:` -- rejects the file just the same, which
    # would otherwise leave a readable `invoke: never` next to an unreadable
    # document.
    { lead = $0; sub(/[^[:space:]].*$/, "", lead); if (lead ~ /\t/) tabindent++ }

    # A top-level key at column 0 ends any block and, when it names coderabbit,
    # opens one. The header is normalized the same way child keys are, so
    # `"coderabbit":` counts as a duplicate of `coderabbit:` (#1084 r9).
    /^[^[:space:]#]/ {
      hdr = keyname($0)
      in_block = 0
      if (hdr == "coderabbit") {
        # Only a block MAPPING is a policy. `coderabbit: |` is a string, and
        # its indented text is scalar content, not direct children -- parsing
        # it as a mapping read `invoke: never` out of a string (#1084 r9).
        rest = $0
        sub(/^[^:]*:/, "", rest)
        sub(/[[:space:]]+#.*$/, "", rest)
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", rest)
        blocks++
        if (rest != "") { nonmap++; next }
        in_block = 1; child_indent = -1
      }
      next
    }
    in_block && /^[[:space:]]*$/ { next }
    in_block && /^[[:space:]]*#/ { next }
    in_block {
      ind = indentof($0)
      # Derive the block child indentation from its first child rather than
      # assuming two spaces. A policy indented with four spaces had every
      # direct child ignored, so an explicit `invoke: never` silently became
      # the `always` default and forced the wait it was set to avoid
      # (#1084 r8).
      if (child_indent < 0) child_indent = ind
      # A line indented LESS than the established child depth cannot be
      # a nested value and cannot be a sibling -- the file is malformed and a
      # real YAML parser rejects it. Skipping it let an over-indented
      # suppressing field win while the later, shallower line was silently
      # dropped (#1084 r10).
      if (ind < child_indent) { badindent++; next }
      if (ind > child_indent) {
        # Deeper lines are nested content ONLY under a mapping key. A key with
        # a scalar value cannot have children, and YAML rejects the file --
        # ignoring them let `enabled: false` win while an indented
        # `invoke: never` was silently dropped (#1084 r11).
        if (prev_scalar) { badindent++ }
        next
      }
      # Remember whether THIS direct child is a mapping key (empty value) or a
      # scalar, so the next deeper line can be judged.
      val = $0
      sub(/^[^:]*:/, "", val)
      sub(/[[:space:]]+#.*$/, "", val)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", val)
      prev_scalar = (val != "")
      if (keyname($0) != fld) next
      n++; last = $0
    }
    END {
      if (tabindent > 0) { print "<<ambiguous:tab in indentation>>"; exit }
      if (badindent > 0) { print "<<ambiguous:inconsistent child indentation>>"; exit }
      if (nonmap > 0) { print "<<ambiguous:coderabbit is not a block mapping>>"; exit }
      if (blocks > 1) { print "<<ambiguous:" blocks " coderabbit blocks>>"; exit }
      if (n != 1) { if (n > 1) print "<<ambiguous:" n " duplicate " fld " keys>>"; exit }
      $0 = last
      sub(/^[[:space:]]*[^:]*:[[:space:]]*/, "", $0)
      if ($0 ~ /^["\047]/) {
        q = substr($0, 1, 1)
        rest = substr($0, 2)
        idx = index(rest, q)
        if (idx > 0) {
          after = substr(rest, idx + 1)
          # YAML needs WHITESPACE before a `#` for it to open a comment, so
          # `"never"#junk` is malformed rather than a commented value; the
          # zero-whitespace alternative accepted it and produced a clean
          # `never` (#1084 r8).
          if (after ~ /^[[:space:]]*$/ || after ~ /^[[:space:]]+#/) {
            print substr(rest, 1, idx - 1); exit
          }
          print "<<ambiguous:malformed quoting on " fld ">>"; exit
        }
        print "<<ambiguous:unterminated quoted scalar for " fld ">>"; exit
      }
      sub(/[[:space:]]+#.*$/, "", $0)
      sub(/[[:space:]]+$/, "", $0)
      print
    }
  ' "$CONFIG"
}

emit() {  # <decision> <reason>
  local decision=$1 reason=$2 code
  [ "$decision" = "invoke" ] && code=0 || code=1
  if [ "$JSON" = true ]; then
    # Built by jq, not printf. A policy value is arbitrary YAML text and can
    # contain JSON-special characters -- `invoke: '"'"'bogus"mode'"'"'` produced
    # malformed output that jq itself then rejected, on the fail-safe path
    # where a machine reader most needs a parseable answer (#1084 r2).
    jq -n --arg pr "$PR_NUM" --arg d "$decision" --arg r "$reason" \
          --arg m "${INVOKE_MODE:-}" --arg e "${CR_ENABLED:-}" \
      '{pr_number: ($pr|tonumber), decision: $d, reason: $r,
        invoke_mode: $m, coderabbit_enabled: $e}'
  else
    echo "[coderabbit-should-invoke] $decision — $reason"
  fi
  exit "$code"
}

# Read BOTH fields before acting on either. Honouring `enabled: false` first
# let one well-formed field mask the other field's ambiguity: a policy with
# `enabled: false` and two `invoke:` keys exited skip without the duplicate
# ever being examined (#1084 r7). Ambiguity is a property of the FILE, not of
# whichever key happened to be read first, and a malformed file must not
# produce a confident suppressing answer through any path.
CR_ENABLED=$(coderabbit_field enabled)
INVOKE_MODE=$(coderabbit_field invoke)

case "${CR_ENABLED}${INVOKE_MODE}" in
  *"<<ambiguous:"*)
    echo "[coderabbit-should-invoke] WARN: ambiguous coderabbit policy — enabled='${CR_ENABLED}' invoke='${INVOKE_MODE}'" >&2
    emit invoke "ambiguous coderabbit policy block (duplicate blocks or duplicate direct keys)"
    ;;
esac

CR_ENABLED=${CR_ENABLED:-true}
if [ "$CR_ENABLED" = "false" ]; then
  emit skip "coderabbit.enabled=false"
fi

INVOKE_MODE=${INVOKE_MODE:-always}

# Exact-match only. Anything that is not one of the three literals invokes.
case "$INVOKE_MODE" in
  never)   emit skip   "coderabbit.invoke=never" ;;
  always)  emit invoke "coderabbit.invoke=always" ;;
  complex-changes) ;;
  *)
    # Unrecognized value: invoke, and say so loudly. Silently treating an
    # unknown mode as `never` would suppress a reviewer on a typo.
    echo "[coderabbit-should-invoke] WARN: unrecognized coderabbit.invoke='$INVOKE_MODE'; treating as 'always'" >&2
    emit invoke "unrecognized coderabbit.invoke='$INVOKE_MODE' (defaulted to always)"
    ;;
esac

# --- complex-changes: defer to the Phase 4b trigger classifier -------------
#
# Reusing that classifier rather than inventing a second notion of "complex"
# is the point. The taxonomy in REVIEW_POLICY.md § Phase 4b Triggers is
# already the repo's definition of a change that warrants more eyes, it is
# already tested, and a second threshold would drift from it.
CLASSIFIER="$SCRIPT_DIR/phase-4b-classifier.sh"
if [ ! -x "$CLASSIFIER" ]; then
  emit invoke "phase-4b-classifier.sh missing or not executable — cannot assess complexity, defaulting to invoke"
fi

# --detect-only makes the classifier run its trigger detectors regardless of
# phase_4b_default (#1084 r4). Without it, a repo on `fallback-only` or
# `always` got a policy answer instead of a complexity answer, and the safe
# reading of that -- invoke -- meant `complex-changes` could never actually
# skip on those repos. Selectivity now works independently of the 4b mode,
# which is what the knob advertises.
set +e
if [ -n "$REPO" ]; then
  CLS_OUT=$("$CLASSIFIER" "$PR_NUM" --detect-only --repo "$REPO" 2>&1)
else
  CLS_OUT=$("$CLASSIFIER" "$PR_NUM" --detect-only 2>&1)
fi
CLS_RC=$?
# An older classifier on a not-yet-synced consumer does not know the flag and
# exits 3 (bad arguments). Retry without it rather than turning a propagation
# lag into a permanent invoke-everything; the files_inspected guard below still
# catches the short-circuits in that degraded mode.
if [ "$CLS_RC" = 3 ]; then
  if [ -n "$REPO" ]; then
    CLS_OUT=$("$CLASSIFIER" "$PR_NUM" --repo "$REPO" 2>&1)
  else
    CLS_OUT=$("$CLASSIFIER" "$PR_NUM" 2>&1)
  fi
  CLS_RC=$?
fi
set -e

# The classifier is a DISPOSITION function, not purely a complexity detector,
# and the difference matters here (#1084 r1). With `phase_4b_default:
# fallback-only` -- the documented default for existing repos -- it
# short-circuits and exits 0 WITHOUT inspecting the diff at all. Read as
# "routine", that would skip CodeRabbit on every PR in such a repo, including
# state-machine and concurrency changes, and would do it silently. Exit 0 is
# therefore only trustworthy as "no trigger matched" when the classifier
# actually looked.
# `files_inspected == 0` is the single, policy-agnostic signal that the
# classifier did not look at this diff. Both short-circuits emit it: the
# `fallback-only` arm (exit 0, which would read as "routine") AND the
# symmetric `always` arm (exit 1, which would read as "a trigger matched").
# The first version of this fix keyed on the policy NAME and so caught only
# the `fallback-only` half, leaving `always` reporting a phantom trigger match
# on every routine PR (#1084 r2). Keying on whether it inspected anything
# covers both, plus the empty-diff case, without string-matching a rationale.
# Three diagnoses, deliberately, and in this order. Every branch invokes, so
# the DECISION was always fail-safe; what was wrong is the reason a machine
# reader is handed (#1084 r11). Coercing an empty CLS_FILES to zero reported an
# infrastructure failure as "the classifier looked and found nothing", discarded
# the classifier stderr, and made the dedicated failure branch below unreachable
# for the ordinary error shape.
#
#   1. non-0/1 exit  -> the classifier failed (API, config, arguments)
#   2. no parseable files_inspected -> it produced no usable document
#   3. files_inspected == 0 -> it genuinely inspected nothing (short-circuit
#                              or empty diff)
case "$CLS_RC" in
  0|1) ;;
  *)
    printf '%s\n' "$CLS_OUT" | tail -3 >&2
    emit invoke "classifier failed (exit $CLS_RC) — complexity unassessed, defaulting to invoke"
    ;;
esac

CLS_FILES=$(printf '%s' "$CLS_OUT" | sed -n 's/.*"files_inspected"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' | head -1)
if [ -z "$CLS_FILES" ]; then
  printf '%s\n' "$CLS_OUT" | tail -3 >&2
  emit invoke "classifier emitted no parseable files_inspected — complexity unassessed, defaulting to invoke"
fi
if [ "$CLS_FILES" = "0" ]; then
  emit invoke "classifier inspected no files (phase_4b_default short-circuit or empty diff) — complexity unassessed, defaulting to invoke"
fi

case "$CLS_RC" in
  1) emit invoke "classifier matched a Phase 4b trigger (complex change)" ;;
  0) emit skip   "classifier matched no Phase 4b trigger (routine change)" ;;
  *)
    echo "$CLS_OUT" | tail -3 >&2
    emit invoke "classifier exited $CLS_RC (API failure, bad config, or bad args) — defaulting to invoke"
    ;;
esac
