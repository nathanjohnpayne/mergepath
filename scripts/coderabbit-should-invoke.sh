#!/usr/bin/env bash
# coderabbit-should-invoke.sh — decide whether Phase 2.5 (CodeRabbit) runs
# for a given PR.
#
# CodeRabbit is advisory: it never carries the merge gate, and its severity
# gate is a clean no-op wherever `coderabbit.severity_gate.enabled` is false
# (the default on every consumer). What it does cost is wall-clock — the
# Phase 2.5 wait is bounded by `coderabbit.max_wait_seconds` (1245s here) and
# the provider rate-limits under sustained use. Spending that on every
# one-line docs PR is the waste this script exists to remove.
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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG=".github/review-policy.yml"

PR_NUM=""
REPO=""
JSON=false
while [ "$#" -gt 0 ]; do
  case "$1" in
    --repo) REPO="${2:-}"; shift 2 ;;
    --json) JSON=true; shift ;;
    --help|-h) sed -n '2,40p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) echo "Error: unknown flag '$1'" >&2; exit 3 ;;
    *) if [ -z "$PR_NUM" ]; then PR_NUM="$1"; else echo "Error: unexpected argument '$1'" >&2; exit 3; fi; shift ;;
  esac
done

if ! [[ "$PR_NUM" =~ ^[0-9]+$ ]]; then
  echo "Error: PR# must be a positive integer; got '${PR_NUM:-}'" >&2
  exit 3
fi
if [ -n "$REPO" ] && ! [[ "$REPO" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]]; then
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
    index($0, "coderabbit:") == 1 { in_block=1; next }
    in_block && /^[^[:space:]#]/ { in_block=0 }
    in_block && $1 == fld":" {
      sub(/^[[:space:]]*[^:]+:[[:space:]]*/, "", $0)
      gsub(/^["\047]/, "", $0)
      gsub(/["\047][[:space:]]*(#.*)?$/, "", $0)
      gsub(/[[:space:]]*#.*$/, "", $0)
      sub(/[[:space:]]+$/, "", $0)
      print
      exit
    }
  ' "$CONFIG"
}

emit() {  # <decision> <reason>
  local decision=$1 reason=$2 code
  [ "$decision" = "invoke" ] && code=0 || code=1
  if [ "$JSON" = true ]; then
    printf '{\n  "pr_number": %s,\n  "decision": "%s",\n  "reason": "%s",\n  "invoke_mode": "%s",\n  "coderabbit_enabled": "%s"\n}\n' \
      "$PR_NUM" "$decision" "$reason" "${INVOKE_MODE:-}" "${CR_ENABLED:-}"
  else
    echo "[coderabbit-should-invoke] $decision — $reason"
  fi
  exit "$code"
}

CR_ENABLED=$(coderabbit_field enabled)
CR_ENABLED=${CR_ENABLED:-true}
if [ "$CR_ENABLED" = "false" ]; then
  emit skip "coderabbit.enabled=false"
fi

INVOKE_MODE=$(coderabbit_field invoke)
INVOKE_MODE=${INVOKE_MODE:-always}

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

set +e
if [ -n "$REPO" ]; then
  CLS_OUT=$("$CLASSIFIER" "$PR_NUM" --repo "$REPO" 2>&1)
else
  CLS_OUT=$("$CLASSIFIER" "$PR_NUM" 2>&1)
fi
CLS_RC=$?
set -e

case "$CLS_RC" in
  1) emit invoke "classifier matched a Phase 4b trigger (complex change)" ;;
  0) emit skip   "classifier matched no Phase 4b trigger (routine change)" ;;
  *)
    echo "$CLS_OUT" | tail -3 >&2
    emit invoke "classifier exited $CLS_RC (API failure, bad config, or bad args) — defaulting to invoke"
    ;;
esac
