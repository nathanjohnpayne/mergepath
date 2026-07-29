#!/usr/bin/env bash
# tests/test_load_review_config.sh
#
# Hermetic coverage for scripts/workflow/load_review_config.sh — the extracted
# body of `.github/workflows/agent-review.yml`'s `load-config` step (#788).
#
# The contract under test is that `load-config` exports its four outputs from
# the policy that GOVERNS the PR (the base branch's), the same policy
# scripts/merge-clearance-gate.sh, scripts/codex-review-check.sh and the
# `triage` job already read. Before #788 the step parsed whatever
# `actions/checkout` had materialized, so on a PR targeting a non-default
# branch the pipeline could assign a reviewer the base policy does not list, or
# arm auto-merge from an identity it does not permit.
#
# Both halves of the asymmetry are pinned, because regressing either one is
# easy and only one of them is visible in the fleet today:
#
#   non-default base -> identities come from the BASE policy
#   default base     -> identical outputs AND ZERO gh calls. The no-API-call
#                       short circuit is what shaped the #769 resolver: this
#                       job runs on every push to every open PR across the
#                       fleet, so an unconditional contents fetch would put a
#                       new API dependency on the busiest path in the pipeline.
#                       Passing the `--pr` form instead of the base fields
#                       reintroduces exactly that, which is why the call log is
#                       asserted rather than assumed.
#   resolver failure -> fail-CLOSED outputs, exit 0. Exiting nonzero would skip
#                       `triage` (it declares `needs: [load-config]` without
#                       `always()`), and a skipped labeling job is fail-OPEN.
#
# Fully offline via a PATH-prepended `gh` stub. Bash 3.2 portable.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOADER="$ROOT/scripts/workflow/load_review_config.sh"
[ -x "$LOADER" ] || { echo "missing $LOADER" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not available" >&2; exit 0; }

PASS=0
FAIL=0
pass() { echo "PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $*" >&2; FAIL=$((FAIL + 1)); }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/load-review-config-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# Give the run its own TMPDIR so the temp-file-cleanup assertion below observes
# only files this suite caused, not another process's leftovers.
mkdir -p "$WORK/tmp"
export TMPDIR="$WORK/tmp"

REPO="owner/repo"

# The DEFAULT-branch policy: what the checkout carries.
DEFAULT_CONFIG="$WORK/default-policy.yml"
cat > "$DEFAULT_CONFIG" <<'YAML'
external_review_threshold: 300

external_review_paths:
  - "src/auth/**"
  - ".github/**"

available_reviewers:
  - nathanpayne-claude
  - nathanpayne-cursor

author_identity: nathanjohnpayne
YAML

# The NON-DEFAULT BASE branch's policy: deliberately names different
# identities, a different threshold, and different protected paths, so an
# implementation that reads the wrong file cannot accidentally agree.
BASE_POLICY="$WORK/base-policy.yml"
cat > "$BASE_POLICY" <<'YAML'
external_review_threshold: 25

external_review_paths:
  - "release/**"

available_reviewers:
  - nathanpayne-codex

author_identity: release-bot
YAML

# A base policy that repeats a scalar key. Only reachable now that the policy
# can be FETCHED from another branch rather than always being the checked-out
# file, and a second bare line in GITHUB_OUTPUT is parsed by Actions as its own
# output entry.
DUP_POLICY="$WORK/dup-policy.yml"
cat > "$DUP_POLICY" <<'YAML'
external_review_threshold: 25
external_review_threshold: 999999

available_reviewers:
  - nathanpayne-codex

author_identity: release-bot
author_identity: someone-else
YAML

CALLS_LOG="$WORK/gh-calls.log"

GH_STUB="$WORK/gh"
cat > "$GH_STUB" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "${GH_CALLS_LOG:-/dev/null}"
[ "${1:-}" = "api" ] || { echo "{}"; exit 0; }
shift
PATHARG=""
while [ $# -gt 0 ]; do
  case "$1" in
    -H) shift 2 ;;
    --jq|--paginate) if [ "$1" = "--jq" ]; then shift 2; else shift; fi ;;
    *) [ -n "$PATHARG" ] || PATHARG="$1"; shift ;;
  esac
done
case "$PATHARG" in
  repos/*/pulls/*)
    cat "${STUB_PR_JSON:-/dev/null}"
    exit 0 ;;
  repos/*/commits/*)
    echo '{"sha":"basesha1"}'
    exit 0 ;;
  repos/*/contents/*)
    case "${STUB_CONTENTS_MODE:-ok}" in
      ok)    cat "${STUB_BASE_POLICY:?}"; exit 0 ;;
      dup)   cat "${STUB_DUP_POLICY:?}"; exit 0 ;;
      error) echo "gh: API rate limit exceeded (HTTP 403)" >&2; exit 1 ;;
    esac ;;
esac
echo "{}"
STUB
chmod +x "$GH_STUB"
export PATH="$WORK:$PATH" GH_CALLS_LOG="$CALLS_LOG" STUB_BASE_POLICY="$BASE_POLICY" STUB_DUP_POLICY="$DUP_POLICY"
hash -r 2>/dev/null || true

OUT_FILE="$WORK/github-output.txt"

run_loader() {  # <base_ref> <default_branch>
  : > "$OUT_FILE"
  : > "$CALLS_LOG"
  LOG=$(bash "$LOADER" --repo "$REPO" --base-ref "$1" --base-sha "basesha1" \
        --default-branch "$2" --default-config "$DEFAULT_CONFIG" \
        --output "$OUT_FILE" 2>"$WORK/err.txt") && RC=0 || RC=$?
}

out_value() {  # <key>
  # Last wins, mirroring how Actions folds duplicate GITHUB_OUTPUT keys.
  grep "^$1=" "$OUT_FILE" | tail -n 1 | sed "s/^$1=//"
}

# ---------------------------------------------------------------------------
# 1. Non-default base: every identity comes from the BASE policy, not the
#    checked-out default-branch one. This is the #788 defect.
# ---------------------------------------------------------------------------
export STUB_CONTENTS_MODE=ok
run_loader release/1.x main
if [ "$RC" -eq 0 ] \
   && [ "$(out_value reviewers)" = '["nathanpayne-codex"]' ] \
   && [ "$(out_value author_identity)" = "release-bot" ]; then
  pass "non-default base exports identities from the BASE policy (#788)"
else
  fail "non-default base identities (rc=$RC reviewers=$(out_value reviewers) author=$(out_value author_identity))"
fi

if [ "$(out_value threshold)" = "25" ] && [ "$(out_value paths)" = '["release/**"]' ]; then
  pass "non-default base exports threshold/paths from the BASE policy (#788)"
else
  fail "non-default base threshold/paths (threshold=$(out_value threshold) paths=$(out_value paths))"
fi

# The resolver hands back a TEMP file on this path and the caller owns cleanup;
# the checkout's own config must survive untouched either way.
if [ -f "$DEFAULT_CONFIG" ] && [ "$(find "$TMPDIR" -maxdepth 1 -name 'base-review-policy.*' 2>/dev/null | wc -l | tr -d ' ')" = "0" ]; then
  pass "the resolver's temp policy file is cleaned up and the checkout config is left in place"
else
  fail "temp policy file leaked, or the default config was deleted"
fi

# ---------------------------------------------------------------------------
# 2. Default base: identical outputs AND no API call. The short circuit is the
#    constraint that shaped the #769 resolver — see the header.
# ---------------------------------------------------------------------------
run_loader main main
if [ "$RC" -eq 0 ] \
   && [ "$(out_value threshold)" = "300" ] \
   && [ "$(out_value paths)" = '["src/auth/**",".github/**"]' ] \
   && [ "$(out_value reviewers)" = '["nathanpayne-claude","nathanpayne-cursor"]' ] \
   && [ "$(out_value author_identity)" = "nathanjohnpayne" ]; then
  pass "default base exports the checked-out policy unchanged (#788 no-regression)"
else
  fail "default base outputs (rc=$RC threshold=$(out_value threshold) paths=$(out_value paths) reviewers=$(out_value reviewers) author=$(out_value author_identity))"
fi

if ! grep -q . "$CALLS_LOG"; then
  pass "default base makes ZERO gh API calls (#769 short circuit preserved)"
else
  fail "default base made API calls: $(cat "$CALLS_LOG")"
fi

# ---------------------------------------------------------------------------
# 3. Every output is a single GITHUB_OUTPUT line. Multi-line JSON cannot be
#    written through the `key=value` format and silently truncates (#30/#58).
# ---------------------------------------------------------------------------
if [ "$(grep -c '' "$OUT_FILE" | tr -d ' ')" = "4" ] \
   && [ "$(grep -c '^threshold=\|^paths=\|^reviewers=\|^author_identity=' "$OUT_FILE" | tr -d ' ')" = "4" ]; then
  pass "emits exactly the four load-config outputs, one line each"
else
  fail "unexpected GITHUB_OUTPUT shape: $(cat "$OUT_FILE")"
fi

# ---------------------------------------------------------------------------
# 3b. A base policy that repeats a scalar key must still emit exactly four
#     GITHUB_OUTPUT lines. A stray second line is not inert — Actions parses it
#     as another `key=value` entry.
# ---------------------------------------------------------------------------
export STUB_CONTENTS_MODE=dup
run_loader release/1.x main
if [ "$RC" -eq 0 ] \
   && [ "$(grep -c '' "$OUT_FILE" | tr -d ' ')" = "4" ] \
   && [ "$(out_value threshold)" = "25" ] \
   && [ "$(out_value author_identity)" = "release-bot" ]; then
  pass "a duplicated policy key still emits one line per output"
else
  fail "duplicated policy key broke the output shape (rc=$RC): $(cat "$OUT_FILE")"
fi

# ---------------------------------------------------------------------------
# 4. Resolver failure on a non-default base: FAIL CLOSED but exit 0.
#    reviewers=[] is the operative guard — `assign` assigns nobody and the
#    auto-merge arming gate rejects every approver. threshold=0 makes triage's
#    preliminary calculation require external review. Exit 0 keeps `triage`
#    from being SKIPPED, which would be fail-open (#59's class).
# ---------------------------------------------------------------------------
export STUB_CONTENTS_MODE=error
run_loader release/1.x main
if [ "$RC" -eq 0 ] \
   && [ "$(out_value reviewers)" = "[]" ] \
   && [ "$(out_value paths)" = "[]" ] \
   && [ "$(out_value threshold)" = "0" ] \
   && [ "$(out_value author_identity)" = "" ]; then
  pass "unreadable base policy emits fail-closed outputs and stays green (#788)"
else
  fail "fail-closed path (rc=$RC threshold=$(out_value threshold) reviewers=$(out_value reviewers) author=$(out_value author_identity))"
fi

if printf '%s' "$LOG" | grep -q '::warning::'; then
  pass "the fail-closed path annotates the run rather than failing silently"
else
  fail "fail-closed path emitted no ::warning:: annotation: $LOG"
fi

# The fail-closed values must never come from the default-branch policy: that
# substitution is precisely the bypass #768/#769 closed.
if [ "$(out_value reviewers)" != '["nathanpayne-claude","nathanpayne-cursor"]' ]; then
  pass "an unreadable base policy never silently falls back to the default-branch identities (#768 P1)"
else
  fail "unreadable base policy fell back to the default-branch reviewer list"
fi

echo
echo "== load_review_config (#788) tests: $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ]
