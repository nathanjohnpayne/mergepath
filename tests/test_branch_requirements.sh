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

# Every failure case below is provoked deliberately, so do not pay the
# inter-attempt pause the lib uses to absorb real transients.
export BR_RETRY_SLEEP=0

# `gh` stub. GH_CLASSIC / GH_RULESETS select the behaviour of each surface:
#   ok       — answer with the fixture in GH_CLASSIC_BODY / GH_RULESETS_BODY
#   fail     — exit non-zero with a message on stderr (network / 4xx / 5xx)
#   gqlerror — HTTP 200 carrying a GraphQL `errors` array (classic only)
#   noref    — HTTP 200 whose repository.ref is null (classic only)
# Deliberately overrides the real binary for the whole suite: these tests are
# about the lib's state machine, and reaching the network would make them
# depend on live branch protection.
# Defaults live in their own variables. A brace-heavy JSON literal written
# inline as `${VAR:-{"a":{"b":1}}}` does NOT work: the first `}` closes the
# parameter expansion and the remainder is appended as literal text, so the
# stub emits malformed JSON and every assertion downstream reads a parse
# failure instead of the fixture it asked for.
GH_CLASSIC_DEFAULT='{"data":{"repository":{"ref":{"refUpdateRule":{"requiredStatusCheckContexts":["lint"]}}}}}'
GH_RULESETS_DEFAULT='[]'

gh() {
  case "$*" in
    *graphql*)
      case "${GH_CLASSIC:-ok}" in
        # Real `gh api` writes the JSON HTTP-error body to STDOUT and only the
        # one-line summary to stderr. The stub must do the same or it cannot
        # catch a retry that concatenates a failed attempt output with a
        # successful one — which is exactly what it missed on PR #1176.
        fail)     echo '{"message":"Bad credentials","status":"401"}'
                  echo "gh: Bad credentials (HTTP 401)" >&2; return 1 ;;
        gqlerror) echo '{"data":null,"errors":[{"message":"Resource not accessible by integration"}]}'; return 0 ;;
        noref)    echo '{"data":{"repository":{"ref":null}}}'; return 0 ;;
        *)        echo "${GH_CLASSIC_BODY:-$GH_CLASSIC_DEFAULT}"; return 0 ;;
      esac
      ;;
    # Ruleset DETAIL read, used by the completeness probe to prove that no rule
    # could have been hidden from this viewer.
    */rulesets/*)
      case "${GH_RULESET_DETAIL:-clean}" in
        fail)   echo '{"message":"Not Found","status":"404"}'
                echo "gh: Not Found (HTTP 404)" >&2; return 1 ;;
        bypass) echo '{"bypass_actors":[{"actor_id":5,"actor_type":"Team"}]}'; return 0 ;;
        # GitHub OMITS bypass_actors when the token lacks write access to the
        # ruleset, rather than returning it empty.
        omitted) echo '{"id":42,"name":"x"}'; return 0 ;;
        *)      echo '{"bypass_actors":[]}'; return 0 ;;
      esac
      ;;
    # Ruleset LISTING — a configuration read, not an actor-scoped evaluation.
    */rulesets)
      case "${GH_RULESETS_LIST:-none}" in
        fail)     echo '{"message":"Server Error","status":"500"}'
                  echo "gh: Server Error (HTTP 500)" >&2; return 1 ;;
        # Exit 0 with no document at all, and a 2xx carrying an object.
        silent)   return 0 ;;
        object)   echo '{"message":"unexpected"}'; return 0 ;;
        active)   echo '[{"id":42,"enforcement":"active","source_type":"Repository","source":"owner/repo"}]'; return 0 ;;
        org)      echo '[{"id":43,"enforcement":"active","source_type":"Organization","source":"owner"}]'; return 0 ;;
        tag)      echo '[{"id":45,"enforcement":"active","target":"tag","source_type":"Repository","source":"owner/repo"}]'; return 0 ;;
        evaluate) echo '[{"id":44,"enforcement":"evaluate","source_type":"Repository","source":"owner/repo"}]'; return 0 ;;
        *)        echo '[]'; return 0 ;;
      esac
      ;;
    *rules/branches*)
      case "${GH_RULESETS:-ok}" in
        fail) echo '{"message":"Not Found","status":"404"}'
              echo "gh: Not Found (HTTP 404)" >&2; return 1 ;;
        # Exit 0 having emitted nothing at all — an anomalous empty 2xx.
        empty) return 0 ;;
        *)    echo "${GH_RULESETS_BODY:-$GH_RULESETS_DEFAULT}"; return 0 ;;
      esac
      ;;
  esac
  echo "unexpected gh invocation: $*" >&2
  return 1
}

# Guard the harness itself: if the stub stops emitting parseable JSON, every
# assertion below silently degrades into "the read failed" and the suite goes
# green for the wrong reason. This is not hypothetical — the inline-default
# form described above did exactly that during PR #1176.
if ! GH_CLASSIC=ok gh api graphql | jq -e '.data.repository.ref.refUpdateRule.requiredStatusCheckContexts | length == 1' >/dev/null 2>&1 \
   || ! GH_RULESETS=ok gh api "repos/o/r/rules/branches/main" | jq -e 'type == "array"' >/dev/null 2>&1; then
  echo "FAIL: the gh stub does not emit parseable fixtures; every assertion below would be meaningless" >&2
  exit 1
fi

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

# ── 5. THE SECOND REGRESSION (PR #1176 review). One surface down is UNKNOWN,
# not a usable list. The requirement is the UNION, so a surface answering says
# nothing about what the other would have said.
#
# The concrete failure both reviewers found: the GraphQL read fails while
# `rules/branches` returns `[]`. An earlier revision called that known-and-
# empty, so gate (a) wiped the rollup and a red classic required check cleared
# — the original fail-open, reintroduced one level up.
out=$(GH_CLASSIC=fail GH_RULESETS=ok GH_RULESETS_BODY='[]' \
  br_required_checks owner/repo main)
if [ "$(field "$out" .state)" = "unknown" ]; then
  pass "classic down + empty rulesets: unknown, so the fail-closed arm handles it (#1176 review)"
else
  fail "classic down + empty rulesets: expected unknown — this is the fail-open both reviewers caught — got $out"
fi

# Same rule when the surviving surface DOES carry names: a partial union is
# still not the union, and acting on it would silently drop the other surface
# requirements.
out=$(GH_CLASSIC=ok GH_RULESETS=fail br_required_checks owner/repo main)
if [ "$(field "$out" .state)" = "unknown" ] \
   && [ "$(field "$out" .partial)" = "true" ] \
   && [ "$(field "$out" '.surfaces | join(",")')" = "classic" ]; then
  pass "rulesets down: unknown, with partial + surfaces recorded as diagnostics"
else
  fail "rulesets down: expected unknown/partial/classic, got $out"
fi

out=$(GH_CLASSIC=fail GH_RULESETS=ok GH_RULESETS_BODY="$RULESET_ONE" \
  br_required_checks owner/repo main)
if [ "$(field "$out" .state)" = "unknown" ] \
   && [ "$(field "$out" .partial)" = "true" ]; then
  pass "classic down: unknown even though the rulesets surface carried names"
else
  fail "classic down: expected unknown/partial, got $out"
fi

# A ruleset-governed branch still resolves — #1064 acceptance — as long as
# BOTH surfaces answer, which is the normal case (classic answers with an
# empty rule set on a ruleset-only repo).
out=$(GH_CLASSIC=ok GH_RULESETS=ok GH_RULESETS_BODY="$RULESET_ONE" \
  GH_CLASSIC_BODY='{"data":{"repository":{"ref":{"refUpdateRule":null}}}}' \
  br_required_checks owner/repo main)
if [ "$(field "$out" .state)" = "known" ] \
   && [ "$(field "$out" '.contexts | join(",")')" = "build" ]; then
  pass "a ruleset-only branch resolves its required checks (#1064 acceptance)"
else
  fail "ruleset-only branch: expected known/[build], got $out"
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

# ── 9b. A 2xx carrying a JSON OBJECT instead of the documented array is an
# unread surface, not an empty one. Without a shape check the filter returns
# `[]` with exit 0 — `add` yields the object, `.[]?` iterates its values, and
# `objects` discards the scalars — so an error envelope would be recorded as
# "this branch has no ruleset requirements" on the strength of an error body.
out=$(GH_CLASSIC=ok GH_RULESETS=ok \
  GH_RULESETS_BODY='{"message":"Server Error","status":"500"}' \
  GH_CLASSIC_BODY='{"data":{"repository":{"ref":{"refUpdateRule":null}}}}' \
  br_required_checks owner/repo main)
if [ "$(field "$out" .state)" = "unknown" ] \
   && printf '%s' "$out" | grep -q 'non-array'; then
  pass "a 2xx object body is classified as an unread rulesets surface, not an empty one"
else
  fail "non-array rulesets page: expected unknown naming the shape, got $out"
fi

# ── 9c. A rule that declares itself a required-status-checks rule but omits
# the documented payload is an unread surface too. The page-type check alone
# does not catch it: `.parameters.required_status_checks[]?` simply yields
# nothing, so the surface would be recorded as readable with an INCOMPLETE
# list and a genuinely required context would stop being scrutinised.
for malformed in \
  '[{"type":"required_status_checks","parameters":{}}]' \
  '[{"type":"required_status_checks","parameters":{"required_status_checks":"nope"}}]' \
  '[{"type":"required_status_checks","parameters":{"required_status_checks":[{"context":123}]}}]'
do
  out=$(GH_CLASSIC=ok GH_RULESETS=ok GH_RULESETS_BODY="$malformed" \
    GH_CLASSIC_BODY='{"data":{"repository":{"ref":{"refUpdateRule":null}}}}' \
    br_required_checks owner/repo main)
  if [ "$(field "$out" .state)" = "unknown" ] \
     && printf '%s' "$out" | grep -q 'malformed'; then
    pass "a malformed required_status_checks rule is an unread surface, not an empty one"
  else
    fail "malformed rule ($malformed): expected unknown, got $out"
  fi
done

# A rule of a DIFFERENT type is not the resolver business and must not trip
# the payload check.
out=$(GH_CLASSIC=ok GH_RULESETS=ok \
  GH_RULESETS_BODY='[{"type":"pull_request","parameters":{"required_approving_review_count":1}}]' \
  GH_CLASSIC_BODY='{"data":{"repository":{"ref":{"refUpdateRule":null}}}}' \
  br_required_checks owner/repo main)
if [ "$(field "$out" .state)" = "known" ] \
   && [ "$(field "$out" '.contexts | length')" = "0" ]; then
  pass "an unrelated rule type passes through without tripping the payload check"
else
  fail "unrelated rule type: expected known/[], got $out"
fi

# ── 9d. An exit-0-with-no-output read is an unread surface. `jq -s` slurps
# `[]`, which every downstream shape check accepts vacuously, so the surface
# would be recorded readable-and-empty without a byte having been read.
out=$(GH_CLASSIC=ok GH_RULESETS=empty \
  GH_CLASSIC_BODY='{"data":{"repository":{"ref":{"refUpdateRule":null}}}}' \
  br_required_checks owner/repo main)
if [ "$(field "$out" .state)" = "unknown" ] \
   && printf '%s' "$out" | grep -q 'no pages at all'; then
  pass "an empty rulesets response is an unread surface, not an empty rule set"
else
  fail "empty rulesets stream: expected unknown, got $out"
fi

# The documented array shape still resolves normally.
out=$(GH_CLASSIC=ok GH_RULESETS=ok GH_RULESETS_BODY="$RULESET_ONE" \
  GH_CLASSIC_BODY='{"data":{"repository":{"ref":{"refUpdateRule":null}}}}' \
  br_required_checks owner/repo main)
if [ "$(field "$out" .state)" = "known" ] \
   && [ "$(field "$out" '.contexts | join(",")')" = "build" ]; then
  pass "the shape check does not disturb a well-formed rulesets response"
else
  fail "well-formed rulesets after the shape check: expected known/[build], got $out"
fi

# ── 9e. Viewer-scoping. `rules/branches` returns the rules enforced on the
# REQUESTING identity, and this fleet reviews under one identity and merges
# under another, so a ruleset that bypasses the reviewer while still binding
# the merging author is simply absent from that response. A requirement hidden
# that way is one gate (a) would never scrutinise — the same fail-open, arriving
# through the reader instead of the endpoint. The response is therefore used
# only when it can be PROVEN complete: a ruleset with no bypass actors cannot
# have been hidden from anybody.
out=$(GH_CLASSIC=ok GH_RULESETS=ok GH_RULESETS_LIST=active GH_RULESET_DETAIL=bypass \
  GH_CLASSIC_BODY='{"data":{"repository":{"ref":{"refUpdateRule":{"requiredStatusCheckContexts":["lint"]}}}}}' \
  br_required_checks owner/repo main)
if [ "$(field "$out" .state)" = "unknown" ] \
   && printf '%s' "$out" | grep -q 'bypass actors'; then
  pass "a ruleset with bypass actors leaves the viewer-scoped response unproven, so the union is unknown"
else
  fail "bypassable ruleset: expected unknown naming the bypass actors, got $out"
fi

out=$(GH_CLASSIC=ok GH_RULESETS=ok GH_RULESETS_LIST=active GH_RULESET_DETAIL=clean \
  GH_CLASSIC_BODY='{"data":{"repository":{"ref":{"refUpdateRule":{"requiredStatusCheckContexts":["lint"]}}}}}' \
  br_required_checks owner/repo main)
if [ "$(field "$out" .state)" = "known" ] \
   && [ "$(field "$out" '.contexts | join(",")')" = "lint" ]; then
  pass "an active ruleset with no bypass actors cannot hide a rule, so the union stands"
else
  fail "non-bypassable ruleset: expected known/[lint], got $out"
fi

out=$(GH_CLASSIC=ok GH_RULESETS=ok GH_RULESETS_LIST=active GH_RULESET_DETAIL=fail \
  GH_CLASSIC_BODY='{"data":{"repository":{"ref":{"refUpdateRule":{"requiredStatusCheckContexts":["lint"]}}}}}' \
  br_required_checks owner/repo main)
if [ "$(field "$out" .state)" = "unknown" ]; then
  pass "a ruleset whose detail cannot be read leaves completeness unproven"
else
  fail "unreadable ruleset detail: expected unknown, got $out"
fi

out=$(GH_CLASSIC=ok GH_RULESETS=ok GH_RULESETS_LIST=fail \
  GH_CLASSIC_BODY='{"data":{"repository":{"ref":{"refUpdateRule":{"requiredStatusCheckContexts":["lint"]}}}}}' \
  br_required_checks owner/repo main)
if [ "$(field "$out" .state)" = "unknown" ]; then
  pass "an unreadable ruleset listing leaves completeness unproven"
else
  fail "unreadable ruleset listing: expected unknown, got $out"
fi

# An `evaluate`-mode ruleset does not gate merges, so it cannot hide an
# enforced requirement and must not degrade the result.
out=$(GH_CLASSIC=ok GH_RULESETS=ok GH_RULESETS_LIST=evaluate GH_RULESET_DETAIL=bypass \
  GH_CLASSIC_BODY='{"data":{"repository":{"ref":{"refUpdateRule":{"requiredStatusCheckContexts":["lint"]}}}}}' \
  br_required_checks owner/repo main)
if [ "$(field "$out" .state)" = "known" ]; then
  pass "a non-active ruleset does not gate merges and does not degrade the union"
else
  fail "evaluate-mode ruleset: expected known, got $out"
fi

# The fleet's actual shape: no rulesets at all, so nothing can be hidden.
out=$(GH_CLASSIC=ok GH_RULESETS=ok GH_RULESETS_LIST=none \
  GH_CLASSIC_BODY='{"data":{"repository":{"ref":{"refUpdateRule":{"requiredStatusCheckContexts":["lint"]}}}}}' \
  br_required_checks owner/repo main)
if [ "$(field "$out" .state)" = "known" ] \
   && [ "$(field "$out" '.contexts | join(",")')" = "lint" ]; then
  pass "a repo with no rulesets resolves normally — the probe costs nothing where nothing can hide"
else
  fail "no rulesets: expected known/[lint], got $out"
fi

# An OMITTED bypass_actors is not an empty one. GitHub drops the field when the
# token lacks write access to the ruleset, so `// []` would convert "I was not
# shown the bypass list" into "there is no bypass list" — the same
# absence-versus-inability-to-look conflation, inside the probe written to
# catch it.
out=$(GH_CLASSIC=ok GH_RULESETS=ok GH_RULESETS_LIST=active GH_RULESET_DETAIL=omitted \
  GH_CLASSIC_BODY='{"data":{"repository":{"ref":{"refUpdateRule":{"requiredStatusCheckContexts":["lint"]}}}}}' \
  br_required_checks owner/repo main)
if [ "$(field "$out" .state)" = "unknown" ] \
   && printf '%s' "$out" | grep -q 'bypass_actors array'; then
  pass "an omitted bypass_actors leaves completeness unproven rather than reading as empty"
else
  fail "omitted bypass_actors: expected unknown, got $out"
fi

# A TAG ruleset cannot contribute to rules/branches or hide a branch
# status-check requirement, so a bypassable one must not degrade the result —
# otherwise a repo whose only bypassable ruleset governs tags could never clear
# gate (a) on any PR.
out=$(GH_CLASSIC=ok GH_RULESETS=ok GH_RULESETS_LIST=tag GH_RULESET_DETAIL=bypass \
  GH_CLASSIC_BODY='{"data":{"repository":{"ref":{"refUpdateRule":{"requiredStatusCheckContexts":["lint"]}}}}}' \
  br_required_checks owner/repo main)
if [ "$(field "$out" .state)" = "known" ] \
   && [ "$(field "$out" '.contexts | join(",")')" = "lint" ]; then
  pass "a bypassable TAG ruleset does not degrade the branch requirement union"
else
  fail "tag-targeted ruleset: expected known/[lint], got $out"
fi

# The completeness proof must not rest on an unparsed inventory. An inventory
# that exits 0 emitting nothing, or one carrying an object instead of the
# documented page array, both traverse to "no active rulesets" — which would
# certify the viewer-scoped response complete on the strength of a response
# nobody read.
for inventory_shape in silent object; do
  out=$(GH_CLASSIC=ok GH_RULESETS=ok GH_RULESETS_LIST="$inventory_shape" \
    GH_CLASSIC_BODY='{"data":{"repository":{"ref":{"refUpdateRule":{"requiredStatusCheckContexts":["lint"]}}}}}' \
    br_required_checks owner/repo main)
  if [ "$(field "$out" .state)" = "unknown" ]; then
    pass "an unparseable ruleset inventory ($inventory_shape) leaves completeness unproven"
  else
    fail "ruleset inventory $inventory_shape: expected unknown, got $out"
  fi
done

# ── 10. Each surface is retried once before being given up on, so a single
# transient blip does not degrade the whole resolution to unknown (both
# surfaces are needed for `known`, which makes one blip otherwise expensive).
ATTEMPTS_FILE="$(mktemp)"
gh_flaky_once() {
  # Fail the FIRST graphql attempt only; succeed thereafter. The failing
  # attempt writes its JSON error body to STDOUT, as real `gh api` does — the
  # whole point of this case is that the retry must not concatenate it with
  # the successful attempt output.
  case "$*" in
    *graphql*)
      if [ ! -s "$ATTEMPTS_FILE" ]; then
        echo "seen" >"$ATTEMPTS_FILE"
        echo '{"message":"Internal Server Error","status":"500"}'
        echo "gh: Internal Server Error (HTTP 500)" >&2
        return 1
      fi
      echo '{"data":{"repository":{"ref":{"refUpdateRule":{"requiredStatusCheckContexts":["lint"]}}}}}'
      return 0
      ;;
    */rulesets/*)     echo '{"bypass_actors":[]}'; return 0 ;;
    */rulesets)       echo '[]'; return 0 ;;
    *rules/branches*) echo '[]'; return 0 ;;
  esac
  return 1
}
out=$(gh() { gh_flaky_once "$@"; }; br_required_checks owner/repo main)
rm -f "$ATTEMPTS_FILE"
if [ "$(field "$out" .state)" = "known" ] \
   && [ "$(field "$out" '.contexts | join(",")')" = "lint" ]; then
  pass "a surface that fails once and then succeeds is retried, not written off as unknown"
else
  fail "transient-blip retry: expected known/[lint], got $out"
fi

# ── 11. Structural: GraphQL String variables must be passed with -f, not -F.
#
# `gh api -F` applies magic type conversion, so a repository or owner whose
# name is numeric — or a ref segment that is literally true/false/null — is
# sent as a JSON number/boolean/null against a `String!` variable and the query
# hard-fails on EVERY invocation for that repo. Measured against live gh while
# fixing PR #1176: `-F name=12345` returns "Could not coerce value 12345 to
# String"; `-f name=12345` resolves normally.
if grep -qE '^[[:space:]]*-F (owner|name|qualifiedName)=' "$LIB"; then
  fail "a String! GraphQL variable is passed with -F, which coerces numeric and boolean-looking values and breaks those repos outright"
else
  pass "GraphQL String variables are passed with -f, so numeric/boolean-looking names are not coerced"
fi

echo
echo "test_branch_requirements: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
