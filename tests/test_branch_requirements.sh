#!/usr/bin/env bash
# tests/test_branch_requirements.sh
#
# Behavioural coverage for scripts/lib/branch-requirements.sh (#1064,
# subsuming #1063).
#
# The lib exists to kill ONE conflation. Gate (a) used to read the required
# checks from `branches/{branch}/protection/required_status_checks`, which
# needs Administration:read; GitHub HIDES that resource rather than admitting
# a permission denial, so an unprivileged token gets 404, not 403. "This
# branch requires nothing" and "this token may not look" therefore arrived as
# the same empty list, and gate (a) passed without examining a check run.
#
# So the assertions that matter here are not "does it parse JSON" but "can
# `unknown` ever be mistaken for `known`-and-empty". Every failure mode is
# driven through a stubbed `gh`, so the suite runs offline like its siblings.
#
# The surfaces themselves were verified live while writing #1064, with the
# reviewer PAT that 404s on the REST protection endpoint:
#   nathanjohnpayne/nathanpaynedotcom@main → 7 contexts (the admin-visible list)
#   nathanjohnpayne/mergepath@main         → 6 contexts
# That is what makes the whole approach work and cannot be re-checked offline.
#
# Bash 3.2 portable.

set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT/scripts/lib/branch-requirements.sh"
[ -r "$LIB" ] || { echo "missing $LIB" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not available" >&2; exit 0; }

# shellcheck source=../scripts/lib/branch-requirements.sh
. "$LIB"

PASS=0; FAIL=0
pass() { echo "PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $*" >&2; FAIL=$((FAIL + 1)); }

# `gh` stub. GH_CLASSIC / GH_RULESETS select the behaviour of each surface:
#   ok       — answer with the fixture in GH_CLASSIC_BODY / GH_RULESETS_BODY
#   fail     — exit non-zero with a message on stderr (network / 4xx / 5xx)
#   gqlerror — HTTP 200 carrying a GraphQL `errors` array (classic only)
#   noref    — HTTP 200 whose repository.ref is null (classic only)
# Deliberately overrides the real binary for the whole suite: these tests are
# about the lib's state machine, and reaching the network would make them
# depend on live branch protection.
gh() {
  case "$*" in
    *graphql*)
      case "${GH_CLASSIC:-ok}" in
        fail)     echo "gh: Bad credentials (HTTP 401)" >&2; return 1 ;;
        gqlerror) echo '{"data":null,"errors":[{"message":"Resource not accessible by integration"}]}'; return 0 ;;
        noref)    echo '{"data":{"repository":{"ref":null}}}'; return 0 ;;
        *)        echo "${GH_CLASSIC_BODY:-{\"data\":{\"repository\":{\"ref\":{\"refUpdateRule\":{\"requiredStatusCheckContexts\":[\"lint\"]}}}}}}"; return 0 ;;
      esac
      ;;
    *rules/branches*)
      case "${GH_RULESETS:-ok}" in
        fail) echo "gh: Not Found (HTTP 404)" >&2; return 1 ;;
        *)    echo "${GH_RULESETS_BODY:-[]}"; return 0 ;;
      esac
      ;;
  esac
  echo "unexpected gh invocation: $*" >&2
  return 1
}

# Read one field out of a br_required_checks result.
field() { printf '%s' "$1" | jq -r "$2"; }

RULESET_ONE='[{"type":"required_status_checks","parameters":{"required_status_checks":[{"context":"build"}]}}]'

# ── 1. Both surfaces answer: known, complete, unioned.
out=$(GH_CLASSIC=ok GH_RULESETS=ok GH_RULESETS_BODY="$RULESET_ONE" \
  br_required_checks owner/repo main)
if [ "$(field "$out" .state)" = "known" ] \
   && [ "$(field "$out" .partial)" = "false" ] \
   && [ "$(field "$out" '.contexts | join(",")')" = "build,lint" ]; then
  pass "both surfaces answer: known, complete, and the two lists are unioned"
else
  fail "both surfaces answer: expected known/complete/[build,lint], got $out"
fi

# ── 2. THE REGRESSION. Neither surface answers → unknown, never known-empty.
# If this ever flips to known, gate (a) silently stops filtering again.
out=$(GH_CLASSIC=fail GH_RULESETS=fail br_required_checks owner/repo main)
if [ "$(field "$out" .state)" = "unknown" ] \
   && [ "$(field "$out" '.contexts | length')" = "0" ] \
   && [ "$(field "$out" '.errors | length')" = "2" ]; then
  pass "neither surface answers: unknown with an empty list and both errors recorded (#1064)"
else
  fail "neither surface answers: expected unknown + 2 errors, got $out"
fi

# ── 3. An unreadable config must never present as a readable-and-empty one.
# Same emptiness, opposite meaning — this is the whole bug in one assertion.
unknown_out=$(GH_CLASSIC=fail GH_RULESETS=fail br_required_checks owner/repo main)
empty_out=$(GH_CLASSIC=ok GH_RULESETS=ok \
  GH_CLASSIC_BODY='{"data":{"repository":{"ref":{"refUpdateRule":null}}}}' \
  br_required_checks owner/repo main)
if [ "$(field "$unknown_out" '.contexts | length')" = "$(field "$empty_out" '.contexts | length')" ] \
   && [ "$(field "$unknown_out" .state)" != "$(field "$empty_out" .state)" ]; then
  pass "an unreadable config and a genuinely empty one share a list length but NOT a state"
else
  fail "unreadable and empty are no longer distinguishable: unknown=$unknown_out empty=$empty_out"
fi

# ── 4. Protection exists but requires no status checks: a real answer.
if [ "$(field "$empty_out" .state)" = "known" ] \
   && [ "$(field "$empty_out" '.contexts | length')" = "0" ]; then
  pass "an approvals-only branch resolves to known with an empty list, not to unknown"
else
  fail "approvals-only branch: expected known + [], got $empty_out"
fi

# ── 5. One surface down: degraded but usable, and it says so.
out=$(GH_CLASSIC=ok GH_RULESETS=fail br_required_checks owner/repo main)
if [ "$(field "$out" .state)" = "known" ] \
   && [ "$(field "$out" .partial)" = "true" ] \
   && [ "$(field "$out" '.surfaces | join(",")')" = "classic" ]; then
  pass "rulesets down: still known (filtering on the classic list beats no filter) and flagged partial"
else
  fail "rulesets down: expected known/partial/classic, got $out"
fi

out=$(GH_CLASSIC=fail GH_RULESETS=ok GH_RULESETS_BODY="$RULESET_ONE" \
  br_required_checks owner/repo main)
if [ "$(field "$out" .state)" = "known" ] \
   && [ "$(field "$out" .partial)" = "true" ] \
   && [ "$(field "$out" '.contexts | join(",")')" = "build" ]; then
  pass "classic down: the ruleset-only branch still resolves its required checks (#1064 acceptance)"
else
  fail "classic down: expected known/partial/[build], got $out"
fi

# ── 6. A 200 carrying a GraphQL errors array is a FAILED read, not an empty
# one. `gh` does not reliably exit non-zero for it, so a naive reader would
# treat the null data as "no protection".
out=$(GH_CLASSIC=gqlerror GH_RULESETS=fail br_required_checks owner/repo main)
if [ "$(field "$out" .state)" = "unknown" ] \
   && printf '%s' "$out" | grep -q 'not accessible'; then
  pass "a GraphQL errors payload counts as an unreadable surface and keeps its message"
else
  fail "GraphQL errors payload: expected unknown carrying the message, got $out"
fi

# ── 7. A null ref means the ref was never observed, so the classic surface
# must contribute NOTHING rather than an empty list it did not earn.
out=$(GH_CLASSIC=noref GH_RULESETS=fail br_required_checks owner/repo main)
if [ "$(field "$out" .state)" = "unknown" ]; then
  pass "a null ref contributes nothing instead of manufacturing an empty classic list"
else
  fail "null ref: expected unknown when the other surface is also down, got $out"
fi

# ── 8. Malformed invocation lands on the conservative state, not on an empty
# string a caller might read as "nothing required".
for bad in "  " "noslash main" " main"; do
  # shellcheck disable=SC2086
  out=$(br_required_checks $bad)
  if [ "$(field "$out" .state)" = "unknown" ]; then
    pass "malformed args ('$bad') resolve to unknown"
  else
    fail "malformed args ('$bad'): expected unknown, got $out"
  fi
done

# ── 9. URI-segment encoding (#1063). `#` truncates a path as a fragment and
# `%` starts an escape, so an unencoded branch name reads a DIFFERENT branch —
# and an empty result there is indistinguishable from "nothing required".
# `/` must survive: GitHub addresses release/1.0 with a literal slash.
enc_case() {  # <label> <input> <expected>
  local got; got=$(br_urlencode_branch_path "$2")
  if [ "$got" = "$3" ]; then pass "urlencode: $1"; else fail "urlencode: $1 (want '$3', got '$got')"; fi
}
enc_case "a fragment character is escaped"      'feat#2'        'feat%232'
enc_case "a percent is escaped"                 'feat%2Fx'      'feat%252Fx'
enc_case "a query character is escaped"         'feat?x'        'feat%3Fx'
enc_case "hierarchical slashes are preserved"   'release/1.0'   'release/1.0'
enc_case "a space is escaped"                   'my branch'     'my%20branch'
enc_case "plain names are untouched"            'main'          'main'
enc_case "non-ASCII is UTF-8 percent-encoded"   'feat/ü'        'feat/%C3%BC'

echo
echo "test_branch_requirements: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
