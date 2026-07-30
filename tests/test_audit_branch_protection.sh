#!/usr/bin/env bash
# tests/test_audit_branch_protection.sh
#
# Fixture tests for scripts/audit-branch-protection.sh — covers the
# #285 fixes:
#   - 403/401 auth-scope failures distinguished from 404 "no classic
#     protection" (no false-unprotected verdict under reviewer PAT)
#   - ruleset fallback scoped to rulesets that ACTUALLY target the
#     audited branch (not just any target=="branch" ruleset)
#   - new include forms supported: ~ALL and branch globs
#     (e.g. refs/heads/*) in addition to ~DEFAULT_BRANCH and
#     refs/heads/<name>
#
# Mocks `gh api` via a PATH-shimmed stub that returns fixture JSON
# (or fixture headers+body for the -i flag) plus an appropriate exit
# code. Pattern mirrors tests/test_gh_pr_guard.sh.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/scripts/audit-branch-protection.sh"

[[ -x "$SCRIPT" ]] || { echo "missing or non-executable $SCRIPT" >&2; exit 1; }

if ! command -v jq >/dev/null 2>&1; then
  echo "SKIP: jq not available (audit-branch-protection.sh requires jq)" >&2
  exit 0
fi

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/audit-bp-test.XXXXXX")"
trap 'rm -rf "$WORKDIR"' EXIT

PASS=0
FAIL=0
pass() { echo "PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $*" >&2; FAIL=$((FAIL + 1)); }

# --- gh stub ----------------------------------------------------------------
#
# The audit script makes two kinds of gh calls we care about:
#   1. `gh api -i repos/<owner>/<repo>/branches/<branch>/protection`
#      — includes HTTP headers; we emit a fixture status line + body.
#   2. `gh api repos/<owner>/<repo>/rulesets` and
#      `gh api repos/<owner>/<repo>/rulesets/<id>` — body only.
#
# Behavior is driven by STUB_SCENARIO. Each scenario controls:
#   - the HTTP status returned for branch protection (or 200 + body)
#   - the rulesets list returned (if any)
#   - the per-ruleset detail returned (if any)
STUB_DIR="$WORKDIR/stub-bin"
mkdir -p "$STUB_DIR"
cat >"$STUB_DIR/gh" <<'STUB'
#!/usr/bin/env bash
# Args: gh api [-i] <path>
# We only need to recognize three path shapes:
#   .../branches/.../protection
#   .../rulesets
#   .../rulesets/<id>
include_headers=0
paginate=0
args=()
for a in "$@"; do
  case "$a" in
    -i) include_headers=1 ;;
    --paginate) paginate=1; args+=("$a") ;;
    *)  args+=("$a") ;;
  esac
done

# Extract the REST path the way gh does: the first non-flag operand after
# the `api` subcommand, skipping any flag and any flag VALUE. A positional
# scan (`args[1]`) breaks the moment a flag precedes the path — which is
# exactly what `gh api --paginate <path> --jq <expr>` looks like.
path=""
jq_expr=""
prev=""
for a in "${args[@]}"; do
  if [ "$a" = "api" ] && [ -z "$path" ] && [ -z "$prev" ]; then
    continue
  fi
  case "$prev" in
    --jq|-q) jq_expr="$a"; prev=""; continue ;;
    -f|-F|-H|--method|-X|--input) prev=""; continue ;;
  esac
  case "$a" in
    -*) prev="$a"; continue ;;
  esac
  [ -z "$path" ] && path="$a"
  prev=""
done
# Every requested path is logged verbatim when STUB_PATH_LOG is set, so a
# test can assert what actually went on the wire — including whether a
# branch name was percent-encoded before being interpolated into it.
if [ -n "${STUB_PATH_LOG:-}" ]; then
  printf '%s\n' "$path" >>"$STUB_PATH_LOG"
fi
# Query strings are gh's business, not the fixture's: match on the route.
path="${path%%\?*}"

# Most fixtures describe checks by context because producer identity was not
# relevant to their original assertion. The real APIs also carry the Actions
# producer, so enrich only MISSING fixture metadata here. Scenarios that set a
# foreign id explicitly retain it and exercise the fail-closed path.
fixture_ruleset_json() {
  jq -c '
    .rules |= map(
      if .type == "required_status_checks" then
        .parameters.required_status_checks |= map(
          if has("integration_id") then . else . + {integration_id: 15368} end
        )
      else . end
    )
  ' <<<"$1"
}

# Per-ruleset fixtures are emitted at many call sites below. Route those JSON
# bodies through the enricher once at the transport boundary so every existing
# scenario models the real producer field without duplicating it in each long
# literal. Explicit foreign ids are preserved.
printf() {
  local fmt="$1"
  shift
  if [[ "${path:-}" == */rulesets/* ]] \
    && [ "$fmt" = '%s\n' ] \
    && [ "$#" = "1" ] \
    && jq -e '.rules | type == "array"' >/dev/null 2>&1 <<<"$1"; then
    set -- "$(fixture_ruleset_json "$1")"
  fi
  builtin printf "$fmt" "$@"
}

# Emulate `gh api --jq`: the filter is applied to the response body (and,
# under --paginate, to EACH page, with the outputs concatenated).
emit_body() {  # <json body>
  if [ -n "$jq_expr" ]; then
    printf '%s\n' "$1" | jq -r "$jq_expr"
  else
    printf '%s\n' "$1"
  fi
}

emit_status_and_body() {
  # $1 = HTTP status (e.g. 200, 403, 404)
  # $2 = body
  local status="$1"
  local body="$2"
  if [ "$status" = "200" ] \
    && jq -e '.required_status_checks.contexts | type == "array"' >/dev/null 2>&1 <<<"$body" \
    && ! jq -e '.required_status_checks.checks | type == "array"' >/dev/null 2>&1 <<<"$body"; then
    body="$(jq -c '.required_status_checks.checks = [.required_status_checks.contexts[] | {context: ., app_id: 15368}]' <<<"$body")"
  fi
  if [ "$include_headers" -eq 1 ]; then
    case "$status" in
      200) echo "HTTP/2 200 OK" ;;
      404) echo "HTTP/2 404 Not Found" ;;
      403) echo "HTTP/2 403 Forbidden" ;;
      401) echo "HTTP/2 401 Unauthorized" ;;
      *)   echo "HTTP/2 $status" ;;
    esac
    echo "content-type: application/json"
    echo ""
  fi
  printf '%s\n' "$body"
  # gh exits non-zero on >=400 — mirror that so the script's `|| true`
  # plus status-line inspection works as in production.
  case "$status" in
    2*) return 0 ;;
    *)  return 1 ;;
  esac
}

case "$path" in
  */branches/*/protection)
    case "${STUB_SCENARIO:-}" in
      auth_403)
        emit_status_and_body 403 '{"message":"Resource not accessible by personal access token","documentation_url":"https://docs.github.com/rest/branches/branch-protection"}'
        exit $?
        ;;
      auth_401)
        emit_status_and_body 401 '{"message":"Bad credentials"}'
        exit $?
        ;;
      classic_protected)
        # Classic protection present; required_status_checks includes
        # all canonical checks plus an extra one.
        emit_status_and_body 200 '{"required_status_checks":{"contexts":["Label Gate","Self-Review Required","Codex P1 unresolved threads","CodeRabbit unresolved blocking findings","Merge clearance gate","lint"]}}'
        exit $?
        ;;
      classic_untrusted_producer)
        # Same canonical strings, but only a foreign integration can satisfy
        # them. Context-name equality is not proof the shipped Actions gates
        # are enforced.
        emit_status_and_body 200 '{"required_status_checks":{"contexts":["Label Gate","Self-Review Required","Codex P1 unresolved threads","CodeRabbit unresolved blocking findings","Merge clearance gate"],"checks":[{"context":"Label Gate","app_id":999},{"context":"Self-Review Required","app_id":999},{"context":"Codex P1 unresolved threads","app_id":999},{"context":"CodeRabbit unresolved blocking findings","app_id":999},{"context":"Merge clearance gate","app_id":999}]}}'
        exit $?
        ;;
      classic_admins_bypass)
        # All canonical checks required, but enforce_admins is OFF — a
        # repo admin can still "merge without waiting for requirements".
        emit_status_and_body 200 '{"enforce_admins":{"enabled":false},"required_status_checks":{"contexts":["Label Gate","Self-Review Required","Codex P1 unresolved threads","CodeRabbit unresolved blocking findings","Merge clearance gate"]}}'
        exit $?
        ;;
      classic_admins_enforced)
        # The posture ADR 0002 requires of the hub: all five canonical
        # checks AND enforce_admins on.
        emit_status_and_body 200 '{"enforce_admins":{"enabled":true},"required_status_checks":{"contexts":["Label Gate","Self-Review Required","Codex P1 unresolved threads","CodeRabbit unresolved blocking findings","Merge clearance gate"]}}'
        exit $?
        ;;
      classic_plus_ruleset)
        # Classic protection is present but lists only FOUR canonical
        # checks; the fifth comes from a ruleset (id 1101 below). GitHub
        # enforces both surfaces at once, so the effective requirement is
        # the union and this repo is fully gated. Reading classic and
        # stopping there reports it as DRIFT.
        emit_status_and_body 200 '{"enforce_admins":{"enabled":true},"required_status_checks":{"contexts":["Label Gate","Self-Review Required","Codex P1 unresolved threads","CodeRabbit unresolved blocking findings"]}}'
        exit $?
        ;;
      classic_bypassable_plus_strict_ruleset)
        # All five canonical checks required by classic protection with
        # enforce_admins OFF — but an unbypassable ruleset (1102 below)
        # requires the same five. An admin bypasses only the CLASSIC
        # requirement; the ruleset still blocks the merge, so nothing
        # canonical is actually skippable.
        emit_status_and_body 200 '{"enforce_admins":{"enabled":false},"required_status_checks":{"contexts":["Label Gate","Self-Review Required","Codex P1 unresolved threads","CodeRabbit unresolved blocking findings","Merge clearance gate"]}}'
        exit $?
        ;;
      classic_missing_clearance_gate)
        # Classic protection present but MISSING "Merge clearance gate".
        # Regression net for #427/#428: the auditor must FAIL when the
        # HEAD-pinned merge-clearance check is not a required check.
        emit_status_and_body 200 '{"required_status_checks":{"contexts":["Label Gate","Self-Review Required","Codex P1 unresolved threads","lint"]}}'
        exit $?
        ;;
      no_protection|ruleset_*|ruleset_all_but_main_excluded)
        # No classic protection; 404 triggers ruleset fallback.
        emit_status_and_body 404 '{"message":"Branch not protected","documentation_url":"https://docs.github.com/rest/branches/branch-protection"}'
        exit $?
        ;;
      *)
        emit_status_and_body 500 '{"message":"unknown STUB_SCENARIO"}'
        exit $?
        ;;
    esac
    ;;
  */rulesets)
    # The ruleset INVENTORY. Modelled as pages, because that is what the
    # real endpoint returns: `gh api` without --paginate reads exactly one
    # page, and a repo's inventory can span several — `includes_parents`
    # defaults to true, so organization- and enterprise-level rulesets are
    # folded into this list alongside the repository's own. The fixture
    # pins the page BOUNDARY, not a page size: page 2 is served only when
    # --paginate is passed, exactly as gh behaves.
    page1="[]"
    page2=""
    case "${STUB_SCENARIO:-}" in
      no_protection)
        page1="[]"
        ;;
      ruleset_all)
        page1='[{"id":101,"target":"branch"}]'
        ;;
      ruleset_untrusted_producer)
        page1='[{"id":1301,"target":"branch"}]'
        ;;
      ruleset_glob)
        page1='[{"id":102,"target":"branch"}]'
        ;;
      ruleset_unrelated_only)
        # One ruleset that targets refs/heads/dev only — must NOT
        # contaminate the audit of main.
        page1='[{"id":201,"target":"branch"}]'
        ;;
      ruleset_unrelated_plus_default)
        # Two rulesets: one targets dev with bogus checks; one targets
        # ~DEFAULT_BRANCH with the canonical checks. Audit of main must
        # see only the canonical set.
        page1='[{"id":201,"target":"branch"},{"id":202,"target":"branch"}]'
        ;;
      ruleset_all_but_main_excluded)
        # ONE ruleset: include ~ALL, exclude refs/heads/main. Must NOT
        # protect main even though include matches. #285 r2.
        page1='[{"id":301,"target":"branch"}]'
        ;;
      ruleset_bypass)
        # ~ALL include, all canonical checks, but a bypass list.
        page1='[{"id":401,"target":"branch"}]'
        ;;
      ruleset_default_branch_twice)
        # TWO rulesets, each including ~DEFAULT_BRANCH. Resolving the
        # repo's default branch is a per-repo constant, so the audit must
        # read GET /repos/{owner}/{repo} exactly once for both.
        page1='[{"id":501,"target":"branch"},{"id":502,"target":"branch"}]'
        ;;
      ruleset_bypass_unrelated_rule)
        # Two rulesets govern main: 601 enforces every canonical check
        # with NOBODY able to bypass it; 602 enforces an unrelated
        # project check and grants a bypass actor for it.
        page1='[{"id":601,"target":"branch"},{"id":602,"target":"branch"}]'
        ;;
      ruleset_evaluate_only)
        # A single ruleset listing every canonical check but running in
        # `evaluate` mode — it reports, it does not block a merge.
        page1='[{"id":701,"target":"branch"}]'
        ;;
      ruleset_bypass_actors_absent)
        # Ruleset detail payload that answers NEITHER bypass question.
        page1='[{"id":801,"target":"branch"}]'
        ;;
      ruleset_bypass_actors_not_array)
        # Ruleset detail payload whose `bypass_actors` is an object and
        # which carries no `current_user_can_bypass` either.
        page1='[{"id":802,"target":"branch"}]'
        ;;
      ruleset_readonly_clean)
        # The shape a READ-ONLY token actually gets from GitHub.
        page1='[{"id":1001,"target":"branch"}]'
        ;;
      ruleset_readonly_bypass_always)
        page1='[{"id":1002,"target":"branch"}]'
        ;;
      ruleset_readonly_bypass_prs_only)
        page1='[{"id":1003,"target":"branch"}]'
        ;;
      ruleset_write_scope_other_actor)
        # Write-access shape: the full list names a TEAM that is not the
        # auditing identity, so `current_user_can_bypass` says "never"
        # while the gate is in fact skippable.
        page1='[{"id":1004,"target":"branch"}]'
        ;;
      ruleset_readonly_two)
        # Two rulesets, both withholding `bypass_actors`. "Is the
        # auditing identity an admin" is a per-repo constant, so the
        # admin probe must be issued ONCE for both.
        page1='[{"id":1005,"target":"branch"},{"id":1006,"target":"branch"}]'
        ;;
      classic_plus_ruleset)
        page1='[{"id":1101,"target":"branch"}]'
        ;;
      classic_bypassable_plus_strict_ruleset)
        page1='[{"id":1102,"target":"branch"}]'
        ;;
      ruleset_single_star_deep)
        page1='[{"id":1201,"target":"branch"}]'
        ;;
      ruleset_double_star_deep)
        page1='[{"id":1202,"target":"branch"}]'
        ;;
      ruleset_trailing_double_star)
        page1='[{"id":1203,"target":"branch"}]'
        ;;
      ruleset_exclude_single_star_deep)
        page1='[{"id":1204,"target":"branch"}]'
        ;;
      ruleset_paginated)
        # The applicable required-check ruleset is NOT on the first page.
        # Page 1 carries only a dev-only ruleset (which must not
        # contaminate main); page 2 carries the ~ALL ruleset with every
        # canonical check. A single-page read sees only page 1 and reports
        # a fully gated repo as unprotected.
        page1='[{"id":201,"target":"branch"}]'
        page2='[{"id":101,"target":"branch"}]'
        ;;
      ruleset_default_branch_unreadable)
        # ~DEFAULT_BRANCH ruleset on a repo whose metadata read fails.
        page1='[{"id":901,"target":"branch"}]'
        ;;
      *)
        page1="[]"
        ;;
    esac
    emit_body "$page1"
    if [ -n "$page2" ] && [ "$paginate" -eq 1 ]; then
      emit_body "$page2"
    fi
    exit 0
    ;;
  */rulesets/1101)
    # Supplies the ONE canonical check classic protection omits. Active,
    # nobody can bypass it.
    printf '%s\n' '{"id":1101,"target":"branch","enforcement":"active","conditions":{"ref_name":{"include":["~ALL"],"exclude":[]}},"bypass_actors":[],"rules":[{"type":"required_status_checks","parameters":{"required_status_checks":[{"context":"Merge clearance gate"}]}}]}'
    exit 0
    ;;
  */rulesets/1301)
    printf '%s\n' '{"id":1301,"target":"branch","enforcement":"active","conditions":{"ref_name":{"include":["~ALL"],"exclude":[]}},"bypass_actors":[],"rules":[{"type":"required_status_checks","parameters":{"required_status_checks":[{"context":"Label Gate","integration_id":999},{"context":"Self-Review Required","integration_id":999},{"context":"Codex P1 unresolved threads","integration_id":999},{"context":"CodeRabbit unresolved blocking findings","integration_id":999},{"context":"Merge clearance gate","integration_id":999}]}}]}'
    exit 0
    ;;
  */rulesets/1102)
    # Requires all five canonical checks and nobody can bypass it, so it
    # holds the gate shut even though classic protection's enforce_admins
    # is off.
    printf '%s\n' '{"id":1102,"target":"branch","enforcement":"active","conditions":{"ref_name":{"include":["~ALL"],"exclude":[]}},"bypass_actors":[],"rules":[{"type":"required_status_checks","parameters":{"required_status_checks":[{"context":"Label Gate"},{"context":"Self-Review Required"},{"context":"Codex P1 unresolved threads"},{"context":"CodeRabbit unresolved blocking findings"},{"context":"Merge clearance gate"}]}}]}'
    exit 0
    ;;
  */rulesets/1201|*/rulesets/1202|*/rulesets/1203)
    # fnmatch include patterns, all three carrying every canonical check
    # so the ONLY thing that can decide the verdict is whether the pattern
    # is held to match the audited ref:
    #   1201 refs/heads/release/*    single star, must not cross `/`
    #   1202 refs/heads/release/**/* Ruby's recursive `**/` form
    #   1203 refs/heads/release/**   trailing `**`, NOT the recursive form
    # Verified against real Ruby (File.fnmatch with File::FNM_PATHNAME,
    # which GitHub's ruleset docs name explicitly) for the refs these
    # tests audit:
    #                          release/a   release/a/b
    #   release/*                true        false
    #   release/**/*             true        true
    #   release/**               true        false
    case "$path" in
      */1201) inc='refs/heads/release/*' ;;
      */1202) inc='refs/heads/release/**/*' ;;
      *)      inc='refs/heads/release/**' ;;
    esac
    printf '%s\n' '{"id":'"${path##*/}"',"target":"branch","enforcement":"active","conditions":{"ref_name":{"include":["'"$inc"'"],"exclude":[]}},"bypass_actors":[],"rules":[{"type":"required_status_checks","parameters":{"required_status_checks":[{"context":"Label Gate"},{"context":"Self-Review Required"},{"context":"Codex P1 unresolved threads"},{"context":"CodeRabbit unresolved blocking findings"},{"context":"Merge clearance gate"}]}}]}'
    exit 0
    ;;
  */rulesets/1204)
    # The exclusion mirror: governs every branch EXCEPT one level under
    # release/. `refs/heads/release/*` does not reach `release/a/b`, so
    # this ruleset DOES govern that branch — an over-eager exclude match
    # would drop the only ruleset protecting it and report false DRIFT.
    printf '%s\n' '{"id":1204,"target":"branch","enforcement":"active","conditions":{"ref_name":{"include":["~ALL"],"exclude":["refs/heads/release/*"]}},"bypass_actors":[],"rules":[{"type":"required_status_checks","parameters":{"required_status_checks":[{"context":"Label Gate"},{"context":"Self-Review Required"},{"context":"Codex P1 unresolved threads"},{"context":"CodeRabbit unresolved blocking findings"},{"context":"Merge clearance gate"}]}}]}'
    exit 0
    ;;
  */rulesets/101)
    # ~ALL include, canonical checks. `bypass_actors` is present and
    # EMPTY, which is what GET /repos/{o}/{r}/rulesets/{id} really
    # returns for a ruleset nobody can bypass — the shape that is
    # genuine proof of "no bypass". Distinct from ruleset 801 below,
    # which omits the key entirely.
    printf '%s\n' '{"id":101,"target":"branch","enforcement":"active","conditions":{"ref_name":{"include":["~ALL"],"exclude":[]}},"bypass_actors":[],"rules":[{"type":"required_status_checks","parameters":{"required_status_checks":[{"context":"Label Gate"},{"context":"Self-Review Required"},{"context":"Codex P1 unresolved threads"},{"context":"CodeRabbit unresolved blocking findings"},{"context":"Merge clearance gate"}]}}]}'
    exit 0
    ;;
  */rulesets/102)
    # refs/heads/* glob include, canonical checks
    printf '%s\n' '{"id":102,"target":"branch","enforcement":"active","conditions":{"ref_name":{"include":["refs/heads/*"],"exclude":[]}},"rules":[{"type":"required_status_checks","parameters":{"required_status_checks":[{"context":"Label Gate"},{"context":"Self-Review Required"},{"context":"Codex P1 unresolved threads"},{"context":"CodeRabbit unresolved blocking findings"},{"context":"Merge clearance gate"}]}}]}'
    exit 0
    ;;
  */rulesets/201)
    # refs/heads/dev only — should NOT match audit of main. Has bogus
    # checks that, if leaked into the audit, would NOT include the
    # canonical set (so we can assert "FAIL: no rulesets target main"
    # rather than "FAIL: <canonical> missing").
    printf '%s\n' '{"id":201,"target":"branch","enforcement":"active","conditions":{"ref_name":{"include":["refs/heads/dev"],"exclude":[]}},"rules":[{"type":"required_status_checks","parameters":{"required_status_checks":[{"context":"dev-only-check"}]}}]}'
    exit 0
    ;;
  */rulesets/202)
    # ~DEFAULT_BRANCH with canonical checks — should match audit of main.
    printf '%s\n' '{"id":202,"target":"branch","enforcement":"active","conditions":{"ref_name":{"include":["~DEFAULT_BRANCH"],"exclude":[]}},"rules":[{"type":"required_status_checks","parameters":{"required_status_checks":[{"context":"Label Gate"},{"context":"Self-Review Required"},{"context":"Codex P1 unresolved threads"},{"context":"CodeRabbit unresolved blocking findings"},{"context":"Merge clearance gate"}]}}]}'
    exit 0
    ;;
  */rulesets/301)
    # ~ALL include, refs/heads/main excluded. Canonical checks in the
    # rule, but the ruleset must be IGNORED for the audit of main.
    # Without exclude handling, the prior implementation would PASS
    # — which is the bug #285 r2 closes.
    printf '%s\n' '{"id":301,"target":"branch","enforcement":"active","conditions":{"ref_name":{"include":["~ALL"],"exclude":["refs/heads/main"]}},"rules":[{"type":"required_status_checks","parameters":{"required_status_checks":[{"context":"Label Gate"},{"context":"Self-Review Required"}]}}]}'
    exit 0
    ;;
  */rulesets/401)
    # ~ALL include, every canonical check required — and a bypass list.
    # The checks are all there, so this ruleset PASSES the required-checks
    # half; only the admin-enforcement half can catch it.
    printf '%s\n' '{"id":401,"target":"branch","enforcement":"active","conditions":{"ref_name":{"include":["~ALL"],"exclude":[]}},"bypass_actors":[{"actor_id":5,"actor_type":"RepositoryRole","bypass_mode":"always"}],"rules":[{"type":"required_status_checks","parameters":{"required_status_checks":[{"context":"Label Gate"},{"context":"Self-Review Required"},{"context":"Codex P1 unresolved threads"},{"context":"CodeRabbit unresolved blocking findings"},{"context":"Merge clearance gate"}]}}]}'
    exit 0
    ;;
  */rulesets/501|*/rulesets/502)
    # Two ~DEFAULT_BRANCH rulesets carrying the canonical checks. The
    # `exclude` list holds a pattern that does NOT resolve the default
    # branch, so the only ~DEFAULT_BRANCH resolutions come from the two
    # includes — one per ruleset.
    printf '%s\n' '{"id":'"${path##*/}"',"target":"branch","enforcement":"active","conditions":{"ref_name":{"include":["~DEFAULT_BRANCH"],"exclude":["refs/heads/dev"]}},"rules":[{"type":"required_status_checks","parameters":{"required_status_checks":[{"context":"Label Gate"},{"context":"Self-Review Required"},{"context":"Codex P1 unresolved threads"},{"context":"CodeRabbit unresolved blocking findings"},{"context":"Merge clearance gate"}]}}]}'
    exit 0
    ;;
  */rulesets/601)
    # Active, requires every canonical check, NO bypass actors — this
    # ruleset alone makes all five mandatory for everybody.
    printf '%s\n' '{"id":601,"target":"branch","enforcement":"active","conditions":{"ref_name":{"include":["~ALL"],"exclude":[]}},"bypass_actors":[],"rules":[{"type":"required_status_checks","parameters":{"required_status_checks":[{"context":"Label Gate"},{"context":"Self-Review Required"},{"context":"Codex P1 unresolved threads"},{"context":"CodeRabbit unresolved blocking findings"},{"context":"Merge clearance gate"}]}}]}'
    exit 0
    ;;
  */rulesets/602)
    # Active, grants a bypass actor — but the only check it requires is a
    # project build check, so nobody can skip a canonical gate through it.
    printf '%s\n' '{"id":602,"target":"branch","enforcement":"active","conditions":{"ref_name":{"include":["~ALL"],"exclude":[]}},"bypass_actors":[{"actor_id":7,"actor_type":"Team","bypass_mode":"always"}],"rules":[{"type":"required_status_checks","parameters":{"required_status_checks":[{"context":"project-build"}]}}]}'
    exit 0
    ;;
  */rulesets/701)
    # Every canonical check listed, but enforcement is `evaluate` — the
    # ruleset reports rule outcomes and blocks nothing.
    printf '%s\n' '{"id":701,"target":"branch","enforcement":"evaluate","conditions":{"ref_name":{"include":["~ALL"],"exclude":[]}},"rules":[{"type":"required_status_checks","parameters":{"required_status_checks":[{"context":"Label Gate"},{"context":"Self-Review Required"},{"context":"Codex P1 unresolved threads"},{"context":"CodeRabbit unresolved blocking findings"},{"context":"Merge clearance gate"}]}}]}'
    exit 0
    ;;
  */rulesets/801)
    # Answers NEITHER bypass question: no `bypass_actors` key AND no
    # `current_user_can_bypass`. `.bypass_actors[]?` yields nothing here
    # exactly as it does for a genuinely empty list, so an audit that
    # counts rows cannot tell "nobody can bypass" apart from "the payload
    # did not say" — and would publish the latter as the former. Real
    # GitHub always sends `current_user_can_bypass` on this endpoint, so
    # this is a deliberately DEGENERATE payload: it exists to pin the
    # doctrine that an unanswerable payload exits 2 rather than passing.
    printf '%s\n' '{"id":801,"target":"branch","enforcement":"active","conditions":{"ref_name":{"include":["~ALL"],"exclude":[]}},"rules":[{"type":"required_status_checks","parameters":{"required_status_checks":[{"context":"Label Gate"},{"context":"Self-Review Required"},{"context":"Codex P1 unresolved threads"},{"context":"CodeRabbit unresolved blocking findings"},{"context":"Merge clearance gate"}]}}]}'
    exit 0
    ;;
  */rulesets/802)
    # Same, but `bypass_actors` is an OBJECT rather than an array — the
    # other shape `.bypass_actors[]?` swallows silently. Also degenerate:
    # no `current_user_can_bypass` to fall back to.
    printf '%s\n' '{"id":802,"target":"branch","enforcement":"active","conditions":{"ref_name":{"include":["~ALL"],"exclude":[]}},"bypass_actors":{"message":"unavailable"},"rules":[{"type":"required_status_checks","parameters":{"required_status_checks":[{"context":"Label Gate"},{"context":"Self-Review Required"},{"context":"Codex P1 unresolved threads"},{"context":"CodeRabbit unresolved blocking findings"},{"context":"Merge clearance gate"}]}}]}'
    exit 0
    ;;
  */rulesets/1001|*/rulesets/1005|*/rulesets/1006)
    # THE SHAPE A READ-ONLY TOKEN ACTUALLY GETS. GitHub returns
    # `bypass_actors` only to a caller with write access to the ruleset,
    # so a correctly provisioned `Administration:read` audit token never
    # sees the key — but DOES see `current_user_can_bypass`.
    #
    # Captured from live GET /repos/{o}/{r}/rulesets/{id} under a token
    # with no write access to the ruleset (cli/cli 4898070,
    # home-assistant/core 6332198, github/docs 8039397,
    # vercel/next.js 15412430): HTTP 200, full rules/conditions/
    # enforcement, `current_user_can_bypass` present, `bypass_actors`
    # absent — on Repository-, Organization- AND Enterprise-sourced
    # rulesets alike.
    printf '%s\n' '{"id":'"${path##*/}"',"target":"branch","source_type":"Repository","enforcement":"active","current_user_can_bypass":"never","conditions":{"ref_name":{"include":["~ALL"],"exclude":[]}},"rules":[{"type":"required_status_checks","parameters":{"required_status_checks":[{"context":"Label Gate"},{"context":"Self-Review Required"},{"context":"Codex P1 unresolved threads"},{"context":"CodeRabbit unresolved blocking findings"},{"context":"Merge clearance gate"}]}}]}'
    exit 0
    ;;
  */rulesets/1002)
    # Read-only shape, but the auditing admin CAN bypass outright.
    printf '%s\n' '{"id":1002,"target":"branch","source_type":"Repository","enforcement":"active","current_user_can_bypass":"always","conditions":{"ref_name":{"include":["~ALL"],"exclude":[]}},"rules":[{"type":"required_status_checks","parameters":{"required_status_checks":[{"context":"Label Gate"},{"context":"Self-Review Required"},{"context":"Codex P1 unresolved threads"},{"context":"CodeRabbit unresolved blocking findings"},{"context":"Merge clearance gate"}]}}]}'
    exit 0
    ;;
  */rulesets/1003)
    # Read-only shape, bypass limited to pull requests. #427/#428 were
    # both admin merges OF PULL REQUESTS, so this is the escape ADR 0002
    # exists to stop — it must count as bypassed, not as a lesser state.
    printf '%s\n' '{"id":1003,"target":"branch","source_type":"Repository","enforcement":"active","current_user_can_bypass":"pull_requests_only","conditions":{"ref_name":{"include":["~ALL"],"exclude":[]}},"rules":[{"type":"required_status_checks","parameters":{"required_status_checks":[{"context":"Label Gate"},{"context":"Self-Review Required"},{"context":"Codex P1 unresolved threads"},{"context":"CodeRabbit unresolved blocking findings"},{"context":"Merge clearance gate"}]}}]}'
    exit 0
    ;;
  */rulesets/1004)
    # WRITE-ACCESS shape: both fields present, and they disagree. A team
    # holds a bypass while the auditing identity does not, so
    # `current_user_can_bypass: never` is true and yet the gate is
    # skippable. The authoritative list must win over the narrower
    # signal — otherwise adding the read-only fallback would have made
    # the audit BLINDER for the tokens that can see the most.
    printf '%s\n' '{"id":1004,"target":"branch","source_type":"Repository","enforcement":"active","current_user_can_bypass":"never","bypass_actors":[{"actor_id":7,"actor_type":"Team","bypass_mode":"always"}],"conditions":{"ref_name":{"include":["~ALL"],"exclude":[]}},"rules":[{"type":"required_status_checks","parameters":{"required_status_checks":[{"context":"Label Gate"},{"context":"Self-Review Required"},{"context":"Codex P1 unresolved threads"},{"context":"CodeRabbit unresolved blocking findings"},{"context":"Merge clearance gate"}]}}]}'
    exit 0
    ;;
  */rulesets/901)
    # The ONLY ruleset governing the repo, targeting ~DEFAULT_BRANCH and
    # requiring every canonical check. Paired with a repo whose metadata
    # read fails: if `~DEFAULT_BRANCH` silently resolves to "no match",
    # this ruleset disappears and the audit reports the branch as
    # completely unprotected.
    printf '%s\n' '{"id":901,"target":"branch","enforcement":"active","conditions":{"ref_name":{"include":["~DEFAULT_BRANCH"],"exclude":[]}},"bypass_actors":[],"rules":[{"type":"required_status_checks","parameters":{"required_status_checks":[{"context":"Label Gate"},{"context":"Self-Review Required"},{"context":"Codex P1 unresolved threads"},{"context":"CodeRabbit unresolved blocking findings"},{"context":"Merge clearance gate"}]}}]}'
    exit 0
    ;;
  repos/*/*)
    # Repository metadata. The audit reads TWO different fields from this
    # one endpoint with two different `--jq` expressions, so the stub
    # dispatches on the expression the way real gh does — otherwise the
    # `.permissions.admin` probe would be answered with a branch name.
    #
    #   .default_branch    — resolves `~DEFAULT_BRANCH` ruleset conditions
    #                        and (in --fleet) each repo's audited branch
    #   .permissions.admin — is the auditing identity a repo admin? Read
    #                        only by the read-only admin-bypass fallback
    #
    # `.permissions` is the AUTHENTICATED USER's permission set, which is
    # why a read-only audit can ask it at all; a real payload returns
    # `{"admin":false,...}` for a non-admin rather than omitting it.
    # Verified against live gh on this machine:
    #   author PAT   → {"admin":true,...}
    #   reviewer PAT → {"admin":false,...}
    if [ "$jq_expr" = ".permissions.admin" ]; then
      if [ -n "${STUB_ADMIN_LOG:-}" ]; then
        printf '%s\n' "$path" >>"$STUB_ADMIN_LOG"
      fi
      # `fail` reproduces gh's real failure shape (error body on STDOUT,
      # message on STDERR, rc=1) so the resolver's status check is what
      # makes the "unreadable" tests non-vacuous, not an empty string.
      case "${STUB_ADMIN_PERMISSION:-true}" in
        fail)
          printf '%s\n' '{"message":"Not Found","status":"404"}'
          echo 'gh: Not Found (HTTP 404)' >&2
          exit 1
          ;;
        *)
          printf '%s\n' "${STUB_ADMIN_PERMISSION:-true}"
          exit 0
          ;;
      esac
    fi
    #
    # Every metadata read is logged when STUB_METADATA_LOG is set, so a
    # test can assert the single-repo audit resolves the default branch
    # ONCE however many ~DEFAULT_BRANCH patterns it evaluates.
    if [ -n "${STUB_METADATA_LOG:-}" ]; then
      printf '%s\n' "$path" >>"$STUB_METADATA_LOG"
    fi
    #
    # STUB_DEFAULT_BRANCH_MAP is a space-separated list of
    # `owner/name=branch` pairs; the sentinel branch `fail` makes the
    # metadata read fail the way a missing repo or a scopeless token
    # would. Anything unlisted falls back to STUB_DEFAULT_BRANCH (main).
    #
    # `fail` reproduces REAL `gh api ... --jq` failure semantics, which
    # are the whole point of these fixtures: gh writes the HTTP error
    # BODY to STDOUT, a human-readable line to STDERR, and exits 1.
    # Verified against live gh:
    #   $ gh api repos/<owner>/<missing> --jq .default_branch
    #   stdout: {"message":"Not Found",...,"status":"404"}
    #   stderr: gh: Not Found (HTTP 404)
    #   rc=1
    # An earlier version of this stub wrote the body to stderr only, so
    # the script's `2>/dev/null` swallowed it and the caller's variable
    # really did come back empty — every emptiness guard fired and the
    # tests passed against a failure mode gh does not produce. Keep the
    # body on STDOUT: it is what makes tests 24/25 and the fleet
    # unreadable-metadata tests non-vacuous.
    #
    # The sentinel `leak` is the same body with a ZERO exit status — the
    # residual case the shape check (looks_like_branch_name) defends,
    # where a payload reaches the caller without any status to detect it.
    stub_repo="${path#repos/}"
    for kv in ${STUB_DEFAULT_BRANCH_MAP:-}; do
      case "$kv" in
        "$stub_repo="*)
          v="${kv#*=}"
          if [ "$v" = "fail" ]; then
            printf '%s\n' '{"message":"Not Found","status":"404"}'
            echo 'gh: Not Found (HTTP 404)' >&2
            exit 1
          fi
          if [ "$v" = "leak" ]; then
            printf '%s\n' '{"message":"Server Error","status":"500"}'
            exit 0
          fi
          printf '%s\n' "$v"
          exit 0
          ;;
      esac
    done
    printf '%s\n' "${STUB_DEFAULT_BRANCH:-main}"
    exit 0
    ;;
  *)
    printf '%s\n' '{}'
    exit 0
    ;;
esac
STUB
chmod +x "$STUB_DIR/gh"

# Helper: run the script with a chosen scenario.
run_audit() {
  local scenario="$1"
  shift
  PATH="$STUB_DIR:$PATH" \
  STUB_SCENARIO="$scenario" \
    bash "$SCRIPT" --repo nathanjohnpayne/mergepath --branch main "$@"
}

# ---------------------------------------------------------------------------
# Test 1: insufficient token scope (403) → exit 2 with auth diagnostic.
#         Must NOT fall through to a false "unprotected" verdict.
# ---------------------------------------------------------------------------
set +e
out=$(run_audit auth_403 2>&1)
rc=$?
set -e
if [ "$rc" -ne 2 ]; then
  fail "auth 403: exit $rc, expected 2; output: $out"
elif ! echo "$out" | grep -qi "Administration:read"; then
  fail "auth 403: diagnostic missing 'Administration:read' hint; output: $out"
elif echo "$out" | grep -q "PR merges are completely unprotected"; then
  fail "auth 403: must NOT emit false 'unprotected' verdict; output: $out"
elif ! echo "$out" | grep -qi "author/admin"; then
  fail "auth 403: diagnostic missing 'author/admin' guidance; output: $out"
else
  pass "auth 403: exits 2 with auth diagnostic, no false-unprotected verdict"
fi

# ---------------------------------------------------------------------------
# Test 1b: 401 also routes through the auth diagnostic path.
# ---------------------------------------------------------------------------
set +e
out=$(run_audit auth_401 2>&1)
rc=$?
set -e
if [ "$rc" -ne 2 ]; then
  fail "auth 401: exit $rc, expected 2; output: $out"
elif echo "$out" | grep -q "PR merges are completely unprotected"; then
  fail "auth 401: must NOT emit false 'unprotected' verdict; output: $out"
else
  pass "auth 401: exits 2, no false-unprotected verdict"
fi

# ---------------------------------------------------------------------------
# Test 2: no protection at all (true 404, empty rulesets list) →
#         exit 3 with "unprotected" verdict.
# ---------------------------------------------------------------------------
set +e
out=$(run_audit no_protection 2>&1)
rc=$?
set -e
if [ "$rc" -ne 3 ]; then
  fail "no protection: exit $rc, expected 3; output: $out"
elif ! echo "$out" | grep -q "no rulesets target main"; then
  fail "no protection: diagnostic missing 'no rulesets target main'; output: $out"
else
  pass "no protection (true 404 + empty rulesets): exits 3 with unprotected verdict"
fi

# ---------------------------------------------------------------------------
# Test 3: classic protection present → exit 0 (PASS).
# ---------------------------------------------------------------------------
set +e
out=$(run_audit classic_protected 2>&1)
rc=$?
set -e
if [ "$rc" -ne 0 ]; then
  fail "classic protection: exit $rc, expected 0; output: $out"
elif ! echo "$out" | grep -q "PASS:"; then
  fail "classic protection: missing PASS line; output: $out"
else
  pass "classic protection present: exits 0 with PASS"
fi

# ---------------------------------------------------------------------------
# Test 3b: matching classic context names from a foreign app are not the
#          shipped Actions gates and therefore do not count as protection.
# ---------------------------------------------------------------------------
set +e
out=$(run_audit classic_untrusted_producer 2>&1)
rc=$?
set -e
if [ "$rc" -ne 3 ]; then
  fail "classic foreign producer: exit $rc, expected 3; output: $out"
elif ! echo "$out" | grep -q "no required status checks configured"; then
  fail "classic foreign producer: missing canonical-gap diagnostic; output: $out"
else
  pass "classic same-named checks from a foreign app do not count"
fi

# ---------------------------------------------------------------------------
# Test 4: ruleset with ~ALL targeting main → exit 0 (PASS).
# ---------------------------------------------------------------------------
set +e
out=$(run_audit ruleset_all 2>&1)
rc=$?
set -e
if [ "$rc" -ne 0 ]; then
  fail "ruleset ~ALL: exit $rc, expected 0; output: $out"
elif ! echo "$out" | grep -q "PASS:"; then
  fail "ruleset ~ALL: missing PASS line; output: $out"
else
  pass "ruleset ~ALL targeting main: exits 0 (canonical checks present)"
fi

# ---------------------------------------------------------------------------
# Test 4b: a ruleset whose same-named checks are unpinned to the trusted
#          Actions integration is not proof those workflows gate merges.
# ---------------------------------------------------------------------------
set +e
out=$(run_audit ruleset_untrusted_producer 2>&1)
rc=$?
set -e
if [ "$rc" -ne 3 ]; then
  fail "ruleset foreign producer: exit $rc, expected 3; output: $out"
elif ! echo "$out" | grep -q "no required status checks configured"; then
  fail "ruleset foreign producer: missing canonical-gap diagnostic; output: $out"
else
  pass "ruleset same-named checks from a foreign integration do not count"
fi

# ---------------------------------------------------------------------------
# Test 5: ruleset with refs/heads/* glob → exit 0 (matches main).
# ---------------------------------------------------------------------------
set +e
out=$(run_audit ruleset_glob 2>&1)
rc=$?
set -e
if [ "$rc" -ne 0 ]; then
  fail "ruleset refs/heads/* glob: exit $rc, expected 0; output: $out"
elif ! echo "$out" | grep -q "PASS:"; then
  fail "ruleset refs/heads/* glob: missing PASS line; output: $out"
else
  pass "ruleset refs/heads/* glob: matches main and exits 0"
fi

# ---------------------------------------------------------------------------
# Test 6: unrelated branch ruleset (target refs/heads/dev only) — its
#         checks must NOT contaminate the audit of main. Expect exit 3
#         with the "no rulesets target main" verdict, NOT a leaked
#         "dev-only-check" appearing in the audited set.
# ---------------------------------------------------------------------------
set +e
out=$(run_audit ruleset_unrelated_only 2>&1)
rc=$?
set -e
if [ "$rc" -ne 3 ]; then
  fail "ruleset dev-only: exit $rc, expected 3; output: $out"
elif echo "$out" | grep -q "dev-only-check"; then
  fail "ruleset dev-only: 'dev-only-check' leaked into main's audit; output: $out"
elif ! echo "$out" | grep -q "no rulesets target main"; then
  fail "ruleset dev-only: missing 'no rulesets target main' verdict; output: $out"
else
  pass "ruleset dev-only: does NOT contaminate audit of main"
fi

# ---------------------------------------------------------------------------
# Test 7: mixed rulesets (dev-only + ~DEFAULT_BRANCH) — audit of main
#         picks up only the ~DEFAULT_BRANCH ruleset's checks, not the
#         dev-only ones. Regression net: even when SOME ruleset matches,
#         non-matching rulesets must NOT leak their checks in.
# ---------------------------------------------------------------------------
set +e
out=$(run_audit ruleset_unrelated_plus_default 2>&1)
rc=$?
set -e
if [ "$rc" -ne 0 ]; then
  fail "mixed rulesets: exit $rc, expected 0; output: $out"
elif echo "$out" | grep -q "dev-only-check"; then
  fail "mixed rulesets: 'dev-only-check' leaked from unrelated ruleset; output: $out"
elif ! echo "$out" | grep -q "PASS:"; then
  fail "mixed rulesets: missing PASS line; output: $out"
else
  pass "mixed rulesets: only matching ruleset's checks counted; PASS"
fi

# ---------------------------------------------------------------------------
# Test 9 (#285 r2): a ruleset with include ~ALL + exclude refs/heads/main
#         must NOT count as protecting main, even though the include
#         matches. Pre-fix this was a false PASS. (nathanpayne-codex
#         Phase 4b finding.)
# ---------------------------------------------------------------------------
set +e
out=$(run_audit ruleset_all_but_main_excluded 2>&1)
rc=$?
set -e
if [ "$rc" -ne 3 ]; then
  fail "ruleset all-but-main-excluded: exit $rc, expected 3 (excluded ruleset must not protect); output: $out"
elif ! echo "$out" | grep -q "no rulesets target main"; then
  fail "ruleset all-but-main-excluded: missing 'no rulesets target main' verdict; output: $out"
else
  pass "ruleset all-but-main-excluded: exclude correctly disqualifies the ~ALL include"
fi

# ---------------------------------------------------------------------------
# Test 10 (#427/#428): classic protection present but MISSING the
#         "Merge clearance gate" required check → exit 3. Regression net
#         that the HEAD-pinned merge-clearance gate is wired into the
#         canonical required-checks list.
# ---------------------------------------------------------------------------
set +e
out=$(run_audit classic_missing_clearance_gate 2>&1)
rc=$?
set -e
if [ "$rc" -ne 3 ]; then
  fail "missing clearance gate: exit $rc, expected 3; output: $out"
elif ! echo "$out" | grep -q "Merge clearance gate"; then
  fail "missing clearance gate: diagnostic must name 'Merge clearance gate'; output: $out"
else
  pass "missing 'Merge clearance gate' required check: exits 3 (canonical gap flagged)"
fi

# ===========================================================================
# ~DEFAULT_BRANCH resolution
# ===========================================================================
#
# `~DEFAULT_BRANCH` used to be approximated as "main or master". ADR 0002
# states the posture as "all five checks on its DEFAULT branch", so a repo
# whose default is renamed was answered wrongly in both directions. These
# two cases pin the resolved behaviour.

# ---------------------------------------------------------------------------
# Test 11: a repo whose default branch is `trunk`, audited on `trunk`, with
#          a ~DEFAULT_BRANCH ruleset carrying the canonical checks → PASS.
#          Under the old main/master guess this was a false DRIFT ("no
#          rulesets target trunk") on a repo that is in fact fully gated.
# ---------------------------------------------------------------------------
set +e
out=$(STUB_DEFAULT_BRANCH=trunk run_audit ruleset_unrelated_plus_default --branch trunk 2>&1)
rc=$?
set -e
if [ "$rc" -ne 0 ]; then
  fail "~DEFAULT_BRANCH on a trunk-defaulted repo: exit $rc, expected 0; output: $out"
elif echo "$out" | grep -q "no rulesets target trunk"; then
  fail "~DEFAULT_BRANCH must resolve to the repo's real default branch, not main/master; output: $out"
elif ! echo "$out" | grep -q "PASS:"; then
  fail "~DEFAULT_BRANCH on a trunk-defaulted repo: missing PASS line; output: $out"
else
  pass "~DEFAULT_BRANCH resolves to the repo's real default branch (trunk), not a main/master guess"
fi

# ---------------------------------------------------------------------------
# Test 12: the mirror image — audit `main` on a repo whose default is
#          `trunk`. A ~DEFAULT_BRANCH ruleset does NOT govern main there,
#          so counting it would be a false PASS on an unprotected branch.
# ---------------------------------------------------------------------------
set +e
out=$(STUB_DEFAULT_BRANCH=trunk run_audit ruleset_unrelated_plus_default --branch main 2>&1)
rc=$?
set -e
if [ "$rc" -ne 3 ]; then
  fail "~DEFAULT_BRANCH must not match main on a trunk-defaulted repo: exit $rc, expected 3; output: $out"
elif ! echo "$out" | grep -q "no rulesets target main"; then
  fail "~DEFAULT_BRANCH on a trunk-defaulted repo audited at main: expected 'no rulesets target main'; output: $out"
else
  pass "~DEFAULT_BRANCH does not falsely protect main on a repo whose default is trunk"
fi

# ===========================================================================
# --require-admin-enforcement (ADR 0002, hub posture)
# ===========================================================================
#
# A required check is only as strong as the set of people who cannot skip
# it. ADR 0002 requires enforce_admins on the hub because #427/#428 were
# both admin merges, so a hub with all five checks and an open admin bypass
# must be DRIFT, not PASS.

# ---------------------------------------------------------------------------
# Test 13: all five canonical checks required, enforce_admins OFF, flag
#          passed → exit 3 naming enforce_admins.
# ---------------------------------------------------------------------------
set +e
out=$(run_audit classic_admins_bypass --require-admin-enforcement 2>&1)
rc=$?
set -e
if [ "$rc" -ne 3 ]; then
  fail "admins-bypass with --require-admin-enforcement: exit $rc, expected 3; output: $out"
elif ! echo "$out" | grep -q "enforce_admins"; then
  fail "admins-bypass: diagnostic must name enforce_admins; output: $out"
elif echo "$out" | grep -q "PASS:"; then
  fail "admins-bypass: must NOT report PASS just because all five checks are listed; output: $out"
else
  pass "all five checks required but enforce_admins off + --require-admin-enforcement: exits 3"
fi

# ---------------------------------------------------------------------------
# Test 14: the same repo WITHOUT the flag is a PASS — consumers are not
#          audited for admin enforcement (ADR 0002 requires it of the hub
#          only), so the flag must actually gate the check.
# ---------------------------------------------------------------------------
set +e
out=$(run_audit classic_admins_bypass 2>&1)
rc=$?
set -e
if [ "$rc" -ne 0 ]; then
  fail "admins-bypass without the flag: exit $rc, expected 0 (consumers are not audited for it); output: $out"
elif echo "$out" | grep -q "enforce_admins"; then
  fail "admins-bypass without the flag must not report an admin-enforcement gap; output: $out"
else
  pass "enforce_admins is only audited when --require-admin-enforcement is passed"
fi

# ---------------------------------------------------------------------------
# Test 15: enforce_admins ON + flag → PASS.
# ---------------------------------------------------------------------------
set +e
out=$(run_audit classic_admins_enforced --require-admin-enforcement 2>&1)
rc=$?
set -e
if [ "$rc" -ne 0 ]; then
  fail "admins-enforced: exit $rc, expected 0; output: $out"
elif ! echo "$out" | grep -q "Admin enforcement: OK"; then
  fail "admins-enforced: expected an explicit admin-enforcement OK line; output: $out"
else
  pass "enforce_admins enabled + all canonical checks: exits 0"
fi

# ---------------------------------------------------------------------------
# Test 16: rulesets have no enforce_admins; their equivalent is the bypass
#          list. A ruleset requiring all five checks but granting a bypass
#          actor must fail --require-admin-enforcement.
# ---------------------------------------------------------------------------
set +e
out=$(run_audit ruleset_bypass --require-admin-enforcement 2>&1)
rc=$?
set -e
if [ "$rc" -ne 3 ]; then
  fail "ruleset bypass actors: exit $rc, expected 3; output: $out"
elif ! echo "$out" | grep -q "bypass"; then
  fail "ruleset bypass actors: diagnostic must name the bypass list; output: $out"
elif ! echo "$out" | grep -q "RepositoryRole"; then
  fail "ruleset bypass actors: diagnostic should identify the actor; output: $out"
else
  pass "ruleset with bypass actors + --require-admin-enforcement: exits 3 (checks are skippable)"
fi

# ---------------------------------------------------------------------------
# Test 17: a ruleset with no bypass list satisfies the flag.
# ---------------------------------------------------------------------------
set +e
out=$(run_audit ruleset_all --require-admin-enforcement 2>&1)
rc=$?
set -e
if [ "$rc" -ne 0 ]; then
  fail "ruleset without bypass actors: exit $rc, expected 0; output: $out"
elif ! echo "$out" | grep -q "Admin enforcement: OK"; then
  fail "ruleset without bypass actors: expected an explicit admin-enforcement OK line; output: $out"
else
  pass "ruleset with an empty bypass list satisfies --require-admin-enforcement"
fi

# ---------------------------------------------------------------------------
# Test 18: a bypass entry only weakens the ruleset that grants it. Ruleset
#          601 requires all five canonical checks with nobody able to
#          bypass it; ruleset 602 grants a bypass but requires only an
#          unrelated project check. Nothing canonical is skippable, so this
#          must PASS. Treating "any matching ruleset has a bypass actor" as
#          proof of skippability filed a fully enforced hub as DRIFT and
#          refreshed the weekly rollup issue for it.
# ---------------------------------------------------------------------------
set +e
out=$(run_audit ruleset_bypass_unrelated_rule --require-admin-enforcement 2>&1)
rc=$?
set -e
if [ "$rc" -ne 0 ]; then
  fail "bypass on an unrelated rule: exit $rc, expected 0 (no canonical check is skippable); output: $out"
elif ! echo "$out" | grep -q "Admin enforcement: OK"; then
  fail "bypass on an unrelated rule: expected an explicit admin-enforcement OK line; output: $out"
elif echo "$out" | grep -q "are skippable"; then
  fail "bypass on an unrelated rule: must not report the canonical checks as skippable; output: $out"
else
  pass "bypass on a ruleset requiring no canonical check: does not read as an admin-bypass gap"
fi

# ---------------------------------------------------------------------------
# Test 19: an `evaluate`-mode ruleset reports rule outcomes without
#          blocking a merge, so its required status checks do not gate
#          anything. Counting them would report PASS on a branch nothing
#          actually protects — the exact false-clean verdict #774 exists to
#          remove.
# ---------------------------------------------------------------------------
set +e
out=$(run_audit ruleset_evaluate_only 2>&1)
rc=$?
set -e
if [ "$rc" -ne 3 ]; then
  fail "evaluate-only ruleset: exit $rc, expected 3 (a non-enforcing ruleset gates nothing); output: $out"
elif ! echo "$out" | grep -q "enforcement is 'evaluate'"; then
  fail "evaluate-only ruleset: output must say why the ruleset was not counted; output: $out"
elif echo "$out" | grep -q "PASS:"; then
  fail "evaluate-only ruleset: must NOT report PASS; output: $out"
else
  pass "evaluate-mode ruleset: its required checks are not credited as gating"
fi

# ---------------------------------------------------------------------------
# Test 20: the repo's default branch is resolved ONCE per audit, however
#          many `~DEFAULT_BRANCH` patterns are evaluated. The resolver
#          memoises, but the matcher used to be called inside a command
#          substitution, so every memo was written in a subshell and
#          discarded — two ~DEFAULT_BRANCH rulesets meant two
#          GET /repos/{owner}/{repo} calls per repo (fleet-wide), and a
#          transient failure on a later call could downgrade an already
#          resolved answer to the main/master guess.
# ---------------------------------------------------------------------------
META_LOG="$WORKDIR/metadata-calls.txt"
: >"$META_LOG"
set +e
out=$(STUB_METADATA_LOG="$META_LOG" STUB_DEFAULT_BRANCH=trunk \
        run_audit ruleset_default_branch_twice --branch trunk 2>&1)
rc=$?
set -e
meta_calls=$(grep -c . "$META_LOG" 2>/dev/null || true)
[ -n "$meta_calls" ] || meta_calls=0
if [ "$rc" -ne 0 ]; then
  fail "default-branch memo: exit $rc, expected 0; output: $out"
elif [ "$meta_calls" -ne 1 ]; then
  fail "default-branch memo: GET repos/{owner}/{repo} called $meta_calls time(s), expected exactly 1 (the memo is being discarded in a subshell)"
else
  pass "default-branch memo survives across matcher calls (one metadata read per repo)"
fi

# ---------------------------------------------------------------------------
# Test 21: a ruleset detail payload with NO `bypass_actors` key is not
#          proof of an empty bypass list. `.bypass_actors[]?` yields zero
#          rows for an absent key exactly as it does for a genuinely empty
#          array, so counting rows would let the hub PASS
#          --require-admin-enforcement — and publish a fleet-wide
#          all-clear — without ever seeing the list its verdict depends
#          on. scripts/merge-clearance-gate.sh's enforcement probe rejects
#          the same shape for the same reason.
# ---------------------------------------------------------------------------
set +e
out=$(run_audit ruleset_bypass_actors_absent --require-admin-enforcement 2>&1)
rc=$?
set -e
if [ "$rc" -ne 2 ]; then
  fail "bypass_actors absent: exit $rc, expected 2 (unreadable, not proof of no bypass); output: $out"
elif echo "$out" | grep -q "Admin enforcement: OK"; then
  fail "bypass_actors absent: must NOT report admin enforcement OK on an unread list; output: $out"
elif echo "$out" | grep -q "PASS:"; then
  fail "bypass_actors absent: must NOT report PASS; output: $out"
elif ! echo "$out" | grep -q "bypass_actors"; then
  fail "bypass_actors absent: diagnostic must name the field; output: $out"
else
  pass "ruleset payload without a bypass_actors array: exits 2 (unknown), never a PASS"
fi

# ---------------------------------------------------------------------------
# Test 22: the other shape `.bypass_actors[]?` swallows — a non-array
#          value — is classified the same way.
# ---------------------------------------------------------------------------
set +e
out=$(run_audit ruleset_bypass_actors_not_array --require-admin-enforcement 2>&1)
rc=$?
set -e
if [ "$rc" -ne 2 ]; then
  fail "bypass_actors non-array: exit $rc, expected 2; output: $out"
elif echo "$out" | grep -q "Admin enforcement: OK"; then
  fail "bypass_actors non-array: must NOT report admin enforcement OK; output: $out"
elif ! echo "$out" | grep -q "object"; then
  fail "bypass_actors non-array: diagnostic should report the type it actually saw; output: $out"
else
  pass "ruleset payload with a non-array bypass_actors: exits 2 (unknown)"
fi

# ---------------------------------------------------------------------------
# Test 23: the same unreadable payload WITHOUT --require-admin-enforcement
#          is still a clean PASS. Consumers are not audited for admin
#          enforcement (ADR 0002 requires it of the hub only), so a field
#          the run never consults must not turn eight consumer audits red
#          — the check has to be scoped to the mode that reads it.
# ---------------------------------------------------------------------------
set +e
out=$(run_audit ruleset_bypass_actors_absent 2>&1)
rc=$?
set -e
if [ "$rc" -ne 0 ]; then
  fail "bypass_actors absent without the flag: exit $rc, expected 0; output: $out"
elif echo "$out" | grep -q "bypass_actors"; then
  fail "bypass_actors absent without the flag: must not report on a field it never reads; output: $out"
else
  pass "unreadable bypass_actors is only fatal when --require-admin-enforcement asks the question"
fi

# ---------------------------------------------------------------------------
# Test 23a: THE REGRESSION. GitHub returns `bypass_actors` only to a caller
#           with write access to the ruleset, so the read-only
#           `Administration:read` token this audit is provisioned with never
#           receives it — while `current_user_can_bypass` IS returned.
#           Requiring the list therefore made the hub ruleset path exit 2
#           on every run: never clean, never drift, indistinguishable from a
#           broken audit. A confirmed repository admin who cannot bypass is
#           the ADR 0002 posture and must PASS.
# ---------------------------------------------------------------------------
set +e
out=$(STUB_ADMIN_PERMISSION=true \
        run_audit ruleset_readonly_clean --require-admin-enforcement 2>&1)
rc=$?
set -e
if [ "$rc" -ne 0 ]; then
  fail "read-only clean ruleset: exit $rc, expected 0 — a read-only token must be able to reach a verdict; output: $out"
elif ! echo "$out" | grep -q "Admin enforcement: OK"; then
  fail "read-only clean ruleset: expected an explicit admin-enforcement OK line; output: $out"
elif ! echo "$out" | grep -q "current_user_can_bypass"; then
  fail "read-only clean ruleset: the OK line must disclose which signal it rests on; output: $out"
elif ! echo "$out" | grep -q "PASS:"; then
  fail "read-only clean ruleset: expected an overall PASS; output: $out"
else
  pass "read-only token (bypass_actors withheld, current_user_can_bypass=never) reaches a clean verdict"
fi

# ---------------------------------------------------------------------------
# Test 23b: same read-only shape, but the confirmed admin CAN bypass. That
#           is drift (exit 3) — the fallback must be able to fail, not just
#           to pass, or it is a rubber stamp.
# ---------------------------------------------------------------------------
set +e
out=$(STUB_ADMIN_PERMISSION=true \
        run_audit ruleset_readonly_bypass_always --require-admin-enforcement 2>&1)
rc=$?
set -e
if [ "$rc" -ne 3 ]; then
  fail "read-only admin bypass: exit $rc, expected 3 (drift); output: $out"
elif echo "$out" | grep -q "Admin enforcement: OK"; then
  fail "read-only admin bypass: must NOT report admin enforcement OK; output: $out"
elif ! echo "$out" | grep -q "current_user_can_bypass=always"; then
  fail "read-only admin bypass: diagnostic must name the signal and value; output: $out"
else
  pass "read-only token: current_user_can_bypass=always is reported as drift"
fi

# ---------------------------------------------------------------------------
# Test 23c: `pull_requests_only` is a bypass too. The two escapes that
#           motivated the merge-clearance gate (#427/#428) were both admin
#           merges of pull requests, so treating this as anything short of
#           bypassed would miss exactly the case ADR 0002 exists for.
# ---------------------------------------------------------------------------
set +e
out=$(STUB_ADMIN_PERMISSION=true \
        run_audit ruleset_readonly_bypass_prs_only --require-admin-enforcement 2>&1)
rc=$?
set -e
if [ "$rc" -ne 3 ]; then
  fail "read-only pull_requests_only: exit $rc, expected 3 (drift); output: $out"
elif ! echo "$out" | grep -q "current_user_can_bypass=pull_requests_only"; then
  fail "read-only pull_requests_only: diagnostic must name the value; output: $out"
else
  pass "read-only token: current_user_can_bypass=pull_requests_only counts as a bypass"
fi

# ---------------------------------------------------------------------------
# Test 23d: `current_user_can_bypass` describes the AUDITING IDENTITY, not
#           the bypass list, so it is evidence about admins only when that
#           identity is an admin. A non-admin reports "never" whether or not
#           admins can bypass — accepting it would turn "we could not tell"
#           into an all-clear, which is the exact conflation this audit
#           refuses everywhere else.
# ---------------------------------------------------------------------------
set +e
out=$(STUB_ADMIN_PERMISSION=false \
        run_audit ruleset_readonly_clean --require-admin-enforcement 2>&1)
rc=$?
set -e
if [ "$rc" -ne 2 ]; then
  fail "read-only non-admin identity: exit $rc, expected 2 (cannot conclude); output: $out"
elif echo "$out" | grep -q "Admin enforcement: OK"; then
  fail "read-only non-admin identity: must NOT report admin enforcement OK; output: $out"
elif echo "$out" | grep -q "PASS:"; then
  fail "read-only non-admin identity: must NOT report PASS; output: $out"
elif ! echo "$out" | grep -q "permissions.admin"; then
  fail "read-only non-admin identity: diagnostic must say what it could not establish; output: $out"
else
  pass "current_user_can_bypass from a NON-admin identity exits 2, never a clean verdict"
fi

# ---------------------------------------------------------------------------
# Test 23e: an admin probe that fails outright is the same "unknown". gh
#           writes the HTTP error body to STDOUT on failure, so a
#           status-blind resolver would compare a JSON blob against "true",
#           land in the not-admin branch, and still exit 2 — for the wrong
#           reason. The diagnostic has to distinguish unreadable from
#           confirmed-non-admin.
# ---------------------------------------------------------------------------
set +e
out=$(STUB_ADMIN_PERMISSION=fail \
        run_audit ruleset_readonly_clean --require-admin-enforcement 2>&1)
rc=$?
set -e
if [ "$rc" -ne 2 ]; then
  fail "read-only admin probe failure: exit $rc, expected 2; output: $out"
elif echo "$out" | grep -q "PASS:"; then
  fail "read-only admin probe failure: must NOT report PASS; output: $out"
elif ! echo "$out" | grep -q "permissions.admin"; then
  fail "read-only admin probe failure: diagnostic must name the probe that failed; output: $out"
elif ! echo "$out" | grep -q "'unreadable'"; then
  fail "read-only admin probe failure: must report the permission as unreadable, not as 'false'; output: $out"
else
  pass "an unreadable .permissions.admin exits 2 and is distinguished from a confirmed non-admin"
fi

# ---------------------------------------------------------------------------
# Test 23f: where BOTH fields are returned (a write-scoped token), the
#           authoritative list wins. A team holds a bypass the auditing
#           identity does not, so `current_user_can_bypass` says "never"
#           while the gate is genuinely skippable. Preferring the narrower
#           signal would have made the audit blinder for the tokens that
#           can see the most.
# ---------------------------------------------------------------------------
set +e
out=$(STUB_ADMIN_PERMISSION=true \
        run_audit ruleset_write_scope_other_actor --require-admin-enforcement 2>&1)
rc=$?
set -e
if [ "$rc" -ne 3 ]; then
  fail "write-scope disagreeing signals: exit $rc, expected 3 — bypass_actors must win; output: $out"
elif echo "$out" | grep -q "Admin enforcement: OK"; then
  fail "write-scope disagreeing signals: must NOT report admin enforcement OK; output: $out"
elif ! echo "$out" | grep -q "actor_type=Team"; then
  fail "write-scope disagreeing signals: must report the actual bypass actor; output: $out"
elif echo "$out" | grep -q "current_user_can_bypass"; then
  fail "write-scope disagreeing signals: must not fall back when the full list was returned; output: $out"
else
  pass "bypass_actors outranks current_user_can_bypass when GitHub returns both"
fi

# ---------------------------------------------------------------------------
# Test 23g: "is the auditing identity an admin" is a per-repo constant, so
#           the probe is memoised. Without the memo the answer is recomputed
#           once per ruleset, and a transient failure on a later call would
#           downgrade an already-established admin standing into exit 2.
#           Same subshell trap as resolve_repo_default_branch.
# ---------------------------------------------------------------------------
ADMIN_LOG="$WORKDIR/admin-reads.log"
: >"$ADMIN_LOG"
set +e
out=$(STUB_ADMIN_PERMISSION=true STUB_ADMIN_LOG="$ADMIN_LOG" \
        run_audit ruleset_readonly_two --require-admin-enforcement 2>&1)
rc=$?
set -e
admin_reads=$(wc -l <"$ADMIN_LOG" | tr -d ' ')
if [ "$rc" -ne 0 ]; then
  fail "two read-only rulesets: exit $rc, expected 0; output: $out"
elif [ "$admin_reads" -ne 1 ]; then
  fail "two read-only rulesets: .permissions.admin read $admin_reads times, expected exactly 1 (memoised)"
else
  pass "the .permissions.admin probe is memoised across rulesets (1 read for 2 rulesets)"
fi

# ---------------------------------------------------------------------------
# Test 24: a `~DEFAULT_BRANCH` ruleset on a repo whose metadata cannot be
#          read, audited on a branch the main/master guess does not cover,
#          is an infrastructure ERROR (exit 2) — never DRIFT. Returning
#          "no match" drops the only ruleset protecting the repo and
#          reports "no rulesets target trunk", i.e. files a failed
#          metadata read in the weekly rollup issue as a protection gap.
#          This is the shape the fleet loop produces when a child audit
#          re-reads metadata its parent already resolved.
# ---------------------------------------------------------------------------
set +e
out=$(STUB_DEFAULT_BRANCH_MAP="nathanjohnpayne/mergepath=fail" \
        PATH="$STUB_DIR:$PATH" STUB_SCENARIO=ruleset_default_branch_unreadable \
        bash "$SCRIPT" --repo nathanjohnpayne/mergepath --branch trunk 2>&1)
rc=$?
set -e
if [ "$rc" -ne 2 ]; then
  fail "~DEFAULT_BRANCH unreadable on a non-main branch: exit $rc, expected 2 (infrastructure); output: $out"
elif echo "$out" | grep -q "completely unprotected"; then
  fail "~DEFAULT_BRANCH unreadable: must NOT report the branch unprotected on a failed metadata read; output: $out"
elif ! echo "$out" | grep -q "unknown"; then
  fail "~DEFAULT_BRANCH unreadable: diagnostic must say the answer is unknown; output: $out"
else
  pass "unresolvable ~DEFAULT_BRANCH on a non-main branch: exits 2, never a drift verdict"
fi

# ---------------------------------------------------------------------------
# Test 24b: the residual case behind the status check — an HTTP error body
#           that reaches the caller with a ZERO exit status. `gh api
#           ... --jq` prints error bodies to STDOUT, so a payload is only
#           ever one dropped status away from being read as a branch name;
#           if `{"message":"Server Error","status":"500"}` is accepted as
#           the default branch it compares unequal to every real branch,
#           silently drops the ~DEFAULT_BRANCH ruleset, and reports the
#           failed read as "completely unprotected" drift. The shape check
#           must keep this on the infrastructure path (exit 2).
# ---------------------------------------------------------------------------
set +e
out=$(STUB_DEFAULT_BRANCH_MAP="nathanjohnpayne/mergepath=leak" \
        PATH="$STUB_DIR:$PATH" STUB_SCENARIO=ruleset_default_branch_unreadable \
        bash "$SCRIPT" --repo nathanjohnpayne/mergepath --branch trunk 2>&1)
rc=$?
set -e
if [ "$rc" -ne 2 ]; then
  fail "leaked error body as default branch: exit $rc, expected 2 (infrastructure); output: $out"
elif echo "$out" | grep -q "completely unprotected"; then
  fail "leaked error body: must NOT report the branch unprotected; output: $out"
elif echo "$out" | grep -q '"message"'; then
  fail "leaked error body: an API payload must never be echoed as a branch name; output: $out"
else
  pass "an API error body reaching the caller with rc=0 is rejected by shape, not audited as a branch"
fi

# ---------------------------------------------------------------------------
# Test 25: --default-branch supplies the fact instead, so the audit
#          answers `~DEFAULT_BRANCH` correctly with the metadata read
#          still failing — AND issues no metadata request at all. This is
#          the seam --fleet uses: the parent resolved the branch once, so
#          the child must not repeat (and can no longer be broken by) the
#          lookup.
# ---------------------------------------------------------------------------
META_LOG_SEED="$WORKDIR/metadata-calls-seeded.txt"
: >"$META_LOG_SEED"
set +e
out=$(STUB_DEFAULT_BRANCH_MAP="nathanjohnpayne/mergepath=fail" \
        STUB_METADATA_LOG="$META_LOG_SEED" \
        PATH="$STUB_DIR:$PATH" STUB_SCENARIO=ruleset_default_branch_unreadable \
        bash "$SCRIPT" --repo nathanjohnpayne/mergepath --branch trunk \
          --default-branch trunk 2>&1)
rc=$?
set -e
seeded_calls=$(grep -c . "$META_LOG_SEED" 2>/dev/null || true)
[ -n "$seeded_calls" ] || seeded_calls=0
if [ "$rc" -ne 0 ]; then
  fail "--default-branch seed: exit $rc, expected 0; output: $out"
elif [ "$seeded_calls" -ne 0 ]; then
  fail "--default-branch seed: made $seeded_calls metadata call(s), expected 0 (the fact was handed in)"
elif ! echo "$out" | grep -q "PASS:"; then
  fail "--default-branch seed: expected a PASS verdict; output: $out"
else
  pass "--default-branch seeds the fact: correct verdict with zero metadata reads"
fi

# ---------------------------------------------------------------------------
# Test 26: --default-branch is a per-repo fact --fleet computes itself, so
#          passing it alongside --fleet is rejected rather than silently
#          ignored.
# ---------------------------------------------------------------------------
set +e
out=$(bash "$SCRIPT" --fleet --default-branch trunk 2>&1)
rc=$?
set -e
if [ "$rc" -ne 1 ]; then
  fail "--fleet + --default-branch: exit $rc, expected 1; output: $out"
elif ! echo "$out" | grep -q -- "--default-branch is a per-repo fact"; then
  fail "--fleet + --default-branch: diagnostic missing; output: $out"
else
  pass "--fleet + --default-branch: rejected rather than silently ignored"
fi

# ===========================================================================
# --fleet mode (#774)
# ===========================================================================
#
# The fleet loop is what .github/workflows/branch-protection-audit.yml
# runs on a schedule. Its load-bearing property is the exit-code
# CLASSIFICATION, because the workflow's rollup behaviour hangs off it:
# only 3 opens/updates the rollup issue, only 0 closes it, and 1/2 fail
# the job without touching it. A loop that mapped an auth failure to
# "clean" or to "drift" would recreate the #774 blind spot with a green
# cron on top of it.
#
# The per-repo auditor is stubbed via --audit-cmd so these tests exercise
# the loop's classification and reporting, not the protection semantics
# already covered above.

if ! command -v yq >/dev/null 2>&1 || ! yq --version 2>&1 | grep -q "mikefarah/yq"; then
  # Fail closed rather than skip: --fleet parses the manifest with
  # mikefarah/yq, and a silent skip here would let the classification
  # regression this section exists to catch ship unnoticed.
  echo "FAIL: mikefarah/yq v4+ is required to exercise --fleet (brew install yq)" >&2
  exit 1
fi

FLEET_MANIFEST="$WORKDIR/fleet-manifest.yml"
cat >"$FLEET_MANIFEST" <<'MANIFEST'
version: 1
consumers:
  - name: alpha
    repo: testowner/alpha
  - name: beta
    repo: testowner/beta
MANIFEST

FLEET_STUB="$WORKDIR/stub-audit.sh"
cat >"$FLEET_STUB" <<'STUB'
#!/usr/bin/env bash
# Stub single-repo auditor for the --fleet loop tests. Exits with a
# per-repo code chosen by FLEET_SCENARIO, mirroring the real script's
# contract: 0 pass, 2 auth/API failure, 3 canonical-check gap.
#
# It also echoes the branch and the admin-enforcement flag it was handed,
# because those are the loop's job to compute: the branch must be that
# repo's own default (not a fleet-wide `main`), and --require-admin-
# enforcement must reach the hub and only the hub.
repo=""
branch=""
admin_flag="no"
default_branch="<unset>"
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) repo="$2"; shift 2 ;;
    --branch) branch="$2"; shift 2 ;;
    --default-branch) default_branch="$2"; shift 2 ;;
    --require-admin-enforcement) admin_flag="yes"; shift ;;
    *) shift ;;
  esac
done
echo "stub-audit reached $repo"
echo "stub-audit branch=$branch repo=$repo admin_enforcement=$admin_flag default_branch=$default_branch"
case "${FLEET_SCENARIO:-all_pass}" in
  all_pass) exit 0 ;;
  hub_drift)   case "$repo" in */hub)  exit 3 ;; *) exit 0 ;; esac ;;
  one_drift)   case "$repo" in */beta) exit 3 ;; *) exit 0 ;; esac ;;
  drift_and_auth_error)
    case "$repo" in
      */beta)  exit 3 ;;
      */alpha) exit 2 ;;
      *)       exit 0 ;;
    esac ;;
esac
exit 0
STUB
chmod +x "$FLEET_STUB"

run_fleet() {
  local scenario="$1"
  shift
  PATH="$STUB_DIR:$PATH" \
  FLEET_SCENARIO="$scenario" \
    bash "$SCRIPT" --fleet \
      --hub-repo testowner/hub \
      --manifest "$FLEET_MANIFEST" \
      --audit-cmd "$FLEET_STUB" "$@"
}

# ---------------------------------------------------------------------------
# Fleet test 1: every repo passes → exit 0, and the HUB is audited even
#               though it is not in the manifest's consumer list (#774
#               measured mergepath itself at 2 of 5 canonical gates).
# ---------------------------------------------------------------------------
set +e
out=$(run_fleet all_pass 2>&1)
rc=$?
set -e
if [ "$rc" -ne 0 ]; then
  fail "fleet all-pass: exit $rc, expected 0; output: $out"
elif ! echo "$out" | grep -q "stub-audit reached testowner/hub"; then
  fail "fleet all-pass: hub repo was not audited; output: $out"
elif ! echo "$out" | grep -q "stub-audit reached testowner/alpha"; then
  fail "fleet all-pass: manifest consumer alpha was not audited; output: $out"
elif ! echo "$out" | grep -q "stub-audit reached testowner/beta"; then
  fail "fleet all-pass: manifest consumer beta was not audited; output: $out"
elif ! echo "$out" | grep -q "Audited 3 repo(s): 3 pass, 0 drift, 0 error."; then
  fail "fleet all-pass: tally line wrong; output: $out"
else
  pass "fleet all-pass: exits 0 and audits the hub plus every manifest consumer"
fi

# ---------------------------------------------------------------------------
# Fleet test 2: one consumer missing a canonical check → exit 3, with that
#               repo marked DRIFT in the verdict table.
# ---------------------------------------------------------------------------
set +e
out=$(run_fleet one_drift 2>&1)
rc=$?
set -e
if [ "$rc" -ne 3 ]; then
  fail "fleet one-drift: exit $rc, expected 3; output: $out"
elif ! echo "$out" | grep -qE "^DRIFT +rc=3 +testowner/beta@main$"; then
  fail "fleet one-drift: beta not marked DRIFT in the verdict table; output: $out"
elif ! echo "$out" | grep -q "Audited 3 repo(s): 2 pass, 1 drift, 0 error."; then
  fail "fleet one-drift: tally line wrong; output: $out"
else
  pass "fleet one-drift: exits 3 and marks the drifting repo DRIFT"
fi

# ---------------------------------------------------------------------------
# Fleet test 3: the HUB drifting is enough to fail the fleet audit.
# ---------------------------------------------------------------------------
set +e
out=$(run_fleet hub_drift 2>&1)
rc=$?
set -e
if [ "$rc" -ne 3 ]; then
  fail "fleet hub-drift: exit $rc, expected 3; output: $out"
elif ! echo "$out" | grep -qE "^DRIFT +rc=3 +testowner/hub@main$"; then
  fail "fleet hub-drift: hub not marked DRIFT; output: $out"
else
  pass "fleet hub-drift: hub drift alone exits 3"
fi

# ---------------------------------------------------------------------------
# Fleet test 4 (the load-bearing one): one repo drifts AND another returns
#               an auth/API failure → exit 2, NOT 3. An unreadable repo's
#               posture is unknown, so the run must be reported as an
#               infrastructure failure. The workflow's `case` leaves the
#               rollup issue untouched on 2, which is what stops an
#               expired or under-scoped token from either presenting as a
#               clean audit or half-filling the rollup.
# ---------------------------------------------------------------------------
set +e
out=$(run_fleet drift_and_auth_error 2>&1)
rc=$?
set -e
if [ "$rc" -ne 2 ]; then
  fail "fleet drift+auth-error: exit $rc, expected 2 (infra beats drift); output: $out"
elif ! echo "$out" | grep -qE "^ERROR +rc=2 +testowner/alpha@main$"; then
  fail "fleet drift+auth-error: alpha not marked ERROR; output: $out"
elif ! echo "$out" | grep -qE "^DRIFT +rc=3 +testowner/beta@main$"; then
  fail "fleet drift+auth-error: beta's drift verdict must still be reported; output: $out"
elif ! echo "$out" | grep -q "Administration:read"; then
  fail "fleet drift+auth-error: diagnostic must name the missing scope; output: $out"
elif ! echo "$out" | grep -q "NOT a drift verdict"; then
  fail "fleet drift+auth-error: diagnostic must say this is not drift; output: $out"
else
  pass "fleet drift+auth-error: exits 2 (infrastructure) rather than 3, and says why"
fi

# ---------------------------------------------------------------------------
# Fleet test 5: --summary-file gets the complete per-repo verdict table.
#               The workflow embeds this file verbatim in the rollup issue
#               body while truncating the verbose output, so a repo missing
#               from it is a repo silently missing from the rollup.
# ---------------------------------------------------------------------------
SUMMARY_OUT="$WORKDIR/fleet-summary.txt"
set +e
run_fleet one_drift --summary-file "$SUMMARY_OUT" >/dev/null 2>&1
rc=$?
set -e
if [ "$rc" -ne 3 ]; then
  fail "fleet --summary-file: exit $rc, expected 3"
elif [ ! -s "$SUMMARY_OUT" ]; then
  fail "fleet --summary-file: summary file missing or empty ($SUMMARY_OUT)"
else
  summary_body="$(cat "$SUMMARY_OUT")"
  missing=""
  for r in testowner/hub testowner/alpha testowner/beta; do
    echo "$summary_body" | grep -q " $r@" || missing="$missing $r"
  done
  if [ -n "$missing" ]; then
    fail "fleet --summary-file: table missing repo(s):$missing; body: $summary_body"
  elif ! echo "$summary_body" | grep -q "Audited 3 repo(s):"; then
    fail "fleet --summary-file: table missing the tally line; body: $summary_body"
  else
    pass "fleet --summary-file: writes the complete per-repo verdict table"
  fi
fi

# ---------------------------------------------------------------------------
# Fleet test 6: a missing manifest is a prerequisite failure (exit 1), not
#               a clean audit. Fail-closed: an absent manifest must never
#               read as "zero repos, nothing wrong".
# ---------------------------------------------------------------------------
set +e
out=$(PATH="$STUB_DIR:$PATH" bash "$SCRIPT" --fleet \
        --hub-repo testowner/hub \
        --manifest "$WORKDIR/definitely-not-here.yml" \
        --audit-cmd "$FLEET_STUB" 2>&1)
rc=$?
set -e
if [ "$rc" -ne 1 ]; then
  fail "fleet missing manifest: exit $rc, expected 1; output: $out"
elif ! echo "$out" | grep -q "manifest not found"; then
  fail "fleet missing manifest: diagnostic missing; output: $out"
else
  pass "fleet missing manifest: exits 1 (prerequisite), never a clean 0"
fi

# ---------------------------------------------------------------------------
# Fleet test 7: --fleet and --repo are mutually exclusive.
# ---------------------------------------------------------------------------
set +e
out=$(bash "$SCRIPT" --fleet --repo testowner/hub 2>&1)
rc=$?
set -e
if [ "$rc" -ne 1 ]; then
  fail "fleet+--repo: exit $rc, expected 1; output: $out"
elif ! echo "$out" | grep -q "mutually exclusive"; then
  fail "fleet+--repo: diagnostic missing; output: $out"
else
  pass "fleet + --repo: rejected with exit 1"
fi

# ---------------------------------------------------------------------------
# Fleet test 8: a fleet-only flag without --fleet is rejected rather than
#               silently ignored — a caller who asked for a summary file
#               and got a single-repo run with no summary would read the
#               clean exit as a fleet-wide all-clear.
# ---------------------------------------------------------------------------
set +e
out=$(bash "$SCRIPT" --summary-file "$WORKDIR/ignored.txt" --repo testowner/hub 2>&1)
rc=$?
set -e
if [ "$rc" -ne 1 ]; then
  fail "--summary-file without --fleet: exit $rc, expected 1; output: $out"
elif ! echo "$out" | grep -q -- "--summary-file requires --fleet"; then
  fail "--summary-file without --fleet: diagnostic missing; output: $out"
elif [ -e "$WORKDIR/ignored.txt" ]; then
  fail "--summary-file without --fleet: must not write the summary file"
else
  pass "fleet-only flag without --fleet: rejected with exit 1"
fi

# ---------------------------------------------------------------------------
# Fleet test 9: each repo is audited on ITS OWN default branch. ADR 0002
#               states the posture as "all five checks on its DEFAULT
#               branch"; a fleet-wide hard-coded `main` would inspect a
#               branch a renamed or master-defaulted consumer does not
#               have and report the miss as protection drift.
# ---------------------------------------------------------------------------
set +e
out=$(STUB_DEFAULT_BRANCH_MAP="testowner/beta=trunk testowner/alpha=master" \
        run_fleet all_pass 2>&1)
rc=$?
set -e
if [ "$rc" -ne 0 ]; then
  fail "fleet per-repo default branch: exit $rc, expected 0; output: $out"
elif ! echo "$out" | grep -q "stub-audit branch=trunk repo=testowner/beta"; then
  fail "fleet per-repo default branch: beta must be audited on 'trunk', not a fleet-wide 'main'; output: $out"
elif ! echo "$out" | grep -q "stub-audit branch=master repo=testowner/alpha"; then
  fail "fleet per-repo default branch: alpha must be audited on 'master'; output: $out"
elif ! echo "$out" | grep -q "stub-audit branch=main repo=testowner/hub"; then
  fail "fleet per-repo default branch: hub must be audited on its own default 'main'; output: $out"
elif ! echo "$out" | grep -qE "^PASS +rc=0 +testowner/beta@trunk$"; then
  fail "fleet per-repo default branch: verdict table must name the branch actually audited; output: $out"
else
  pass "fleet resolves and audits each repo's own default branch"
fi

# ---------------------------------------------------------------------------
# Fleet test 10: an explicit --branch still pins one branch across the
#                whole fleet — the escape hatch for "audit everything on
#                release/x" must not be broken by per-repo resolution.
# ---------------------------------------------------------------------------
set +e
out=$(STUB_DEFAULT_BRANCH_MAP="testowner/beta=trunk" \
        run_fleet all_pass --branch main 2>&1)
rc=$?
set -e
if [ "$rc" -ne 0 ]; then
  fail "fleet explicit --branch: exit $rc, expected 0; output: $out"
elif echo "$out" | grep -q "branch=trunk"; then
  fail "fleet explicit --branch must override per-repo defaults; output: $out"
elif ! echo "$out" | grep -q "stub-audit branch=main repo=testowner/beta"; then
  fail "fleet explicit --branch: beta must be audited on the pinned 'main'; output: $out"
elif ! echo "$out" | grep -q "explicit --branch"; then
  fail "fleet explicit --branch: the report should say the branch was pinned; output: $out"
else
  pass "fleet honours an explicit --branch across every repo"
fi

# ---------------------------------------------------------------------------
# Fleet test 11: a repo whose default branch cannot be resolved is an
#                ERROR (exit 2, infrastructure), never a silent fall back
#                to `main`. Guessing would audit a branch that may not
#                exist and file the resulting miss as drift — the same
#                class of false verdict the 403-vs-404 split exists to
#                prevent.
# ---------------------------------------------------------------------------
set +e
out=$(STUB_DEFAULT_BRANCH_MAP="testowner/beta=fail" run_fleet all_pass 2>&1)
rc=$?
set -e
if [ "$rc" -ne 2 ]; then
  fail "fleet unresolvable default branch: exit $rc, expected 2 (infrastructure); output: $out"
elif echo "$out" | grep -q "stub-audit reached testowner/beta"; then
  fail "fleet unresolvable default branch: must not audit beta on a guessed branch; output: $out"
elif ! echo "$out" | grep -qE "^ERROR +rc=2 +testowner/beta@<unresolved>$"; then
  fail "fleet unresolvable default branch: beta must be marked ERROR in the table; output: $out"
elif ! echo "$out" | grep -q "Audited 3 repo(s): 2 pass, 0 drift, 1 error."; then
  fail "fleet unresolvable default branch: tally wrong; output: $out"
else
  pass "fleet marks a repo with an unresolvable default branch ERROR, not drift"
fi

# ---------------------------------------------------------------------------
# Fleet test 11b: the serious shape of the same bug — a broken fleet
#                 presenting as a CLEAN one. `gh api ... --jq` writes the
#                 HTTP error body to STDOUT, so a metadata read that fails
#                 500 used to leave the JSON payload in `repo_branch`,
#                 which is non-empty and so passed the unresolvable-branch
#                 guard, was handed to the child as an authoritative
#                 `--default-branch` fact (suppressing the child's own
#                 re-read), and came back PASS. Fleet rc=0 is what
#                 branch-protection-audit.yml calls `result=clean`, and a
#                 clean audit CLOSES the open drift rollup issue — the
#                 exact outcome the workflow header promises can never
#                 happen. Assert on the whole observable surface: the
#                 status, the tally, and the fact that no API payload is
#                 ever printed as a branch label.
# ---------------------------------------------------------------------------
set +e
out=$(STUB_DEFAULT_BRANCH_MAP="testowner/beta=leak" run_fleet all_pass 2>&1)
rc=$?
set -e
if [ "$rc" -eq 0 ]; then
  fail "fleet leaked-body default branch: exit 0 — a failed metadata read presented as a CLEAN fleet audit; output: $out"
elif [ "$rc" -ne 2 ]; then
  fail "fleet leaked-body default branch: exit $rc, expected 2 (infrastructure); output: $out"
elif echo "$out" | grep -q '"message"'; then
  fail "fleet leaked-body default branch: an API payload was printed as a branch label; output: $out"
elif ! echo "$out" | grep -qE "^ERROR +rc=2 +testowner/beta@<unresolved>$"; then
  fail "fleet leaked-body default branch: beta must be marked ERROR in the table; output: $out"
elif ! echo "$out" | grep -q "Audited 3 repo(s): 2 pass, 0 drift, 1 error."; then
  fail "fleet leaked-body default branch: tally wrong; output: $out"
else
  pass "a leaked API error body never becomes a branch name — no broken fleet reports as clean"
fi

# ---------------------------------------------------------------------------
# Fleet test 12: the hub — and only the hub — is audited with
#                --require-admin-enforcement. ADR 0002 requires
#                enforce_admins on the hub (#427/#428 were both admin
#                merges) and does not require it of consumers, so the loop
#                must not apply the stricter posture fleet-wide either.
# ---------------------------------------------------------------------------
set +e
out=$(run_fleet all_pass 2>&1)
rc=$?
set -e
if [ "$rc" -ne 0 ]; then
  fail "fleet hub admin-enforcement: exit $rc, expected 0; output: $out"
elif ! echo "$out" | grep -q "repo=testowner/hub admin_enforcement=yes"; then
  fail "fleet must audit the hub with --require-admin-enforcement (ADR 0002); output: $out"
elif echo "$out" | grep -q "repo=testowner/alpha admin_enforcement=yes"; then
  fail "fleet must NOT apply --require-admin-enforcement to consumers; output: $out"
elif echo "$out" | grep -q "repo=testowner/beta admin_enforcement=yes"; then
  fail "fleet must NOT apply --require-admin-enforcement to consumers; output: $out"
else
  pass "fleet audits the hub (and only the hub) for admin enforcement"
fi

# ---------------------------------------------------------------------------
# Fleet test 13: --require-admin-enforcement is decided per repo by the
#                fleet loop, so passing it alongside --fleet is rejected
#                rather than silently ignored.
# ---------------------------------------------------------------------------
set +e
out=$(bash "$SCRIPT" --fleet --require-admin-enforcement \
        --hub-repo testowner/hub --manifest "$FLEET_MANIFEST" \
        --audit-cmd "$FLEET_STUB" 2>&1)
rc=$?
set -e
if [ "$rc" -ne 1 ]; then
  fail "--fleet + --require-admin-enforcement: exit $rc, expected 1; output: $out"
elif ! echo "$out" | grep -q -- "--require-admin-enforcement is decided per repo"; then
  fail "--fleet + --require-admin-enforcement: diagnostic missing; output: $out"
else
  pass "--fleet + --require-admin-enforcement: rejected rather than silently ignored"
fi

# ---------------------------------------------------------------------------
# Fleet test 14: the loop hands each child the default branch it already
#                resolved. Without it every child repeats its parent's
#                GET /repos/{owner}/{repo}, and a transient failure of that
#                redundant lookup leaves `~DEFAULT_BRANCH` unresolvable on a
#                repo whose default is neither main nor master — the child
#                then counts no ruleset as governing the branch and returns
#                DRIFT, filing an infrastructure failure in the rollup issue
#                as a protection gap.
# ---------------------------------------------------------------------------
set +e
out=$(STUB_DEFAULT_BRANCH_MAP="testowner/beta=trunk" run_fleet all_pass 2>&1)
rc=$?
set -e
if [ "$rc" -ne 0 ]; then
  fail "fleet default-branch handoff: exit $rc, expected 0; output: $out"
elif ! echo "$out" | grep -q "repo=testowner/beta admin_enforcement=no default_branch=trunk"; then
  fail "fleet default-branch handoff: beta's child must receive --default-branch trunk; output: $out"
elif ! echo "$out" | grep -q "repo=testowner/hub admin_enforcement=yes default_branch=main"; then
  fail "fleet default-branch handoff: the hub's child must receive it too (alongside the admin flag); output: $out"
else
  pass "fleet hands each child the default branch it resolved (no redundant metadata read)"
fi

# ---------------------------------------------------------------------------
# Fleet test 15: with an explicit fleet-wide --branch the loop resolves no
#                default branch at all, so it has no fact to hand down and
#                must not invent one. Passing the PINNED branch as though
#                it were the repo's default would make a `~DEFAULT_BRANCH`
#                ruleset appear to govern `release/x` on every repo.
# ---------------------------------------------------------------------------
set +e
out=$(STUB_DEFAULT_BRANCH_MAP="testowner/beta=trunk" \
        run_fleet all_pass --branch main 2>&1)
rc=$?
set -e
if [ "$rc" -ne 0 ]; then
  fail "fleet explicit --branch handoff: exit $rc, expected 0; output: $out"
elif echo "$out" | grep -q "default_branch=main"; then
  fail "fleet explicit --branch: must not pass the pinned branch as the repo's default; output: $out"
elif ! echo "$out" | grep -q "repo=testowner/beta admin_enforcement=no default_branch=<unset>"; then
  fail "fleet explicit --branch: child must be given no default-branch fact; output: $out"
else
  pass "fleet withholds --default-branch when --branch pinned the fleet (no invented fact)"
fi

# ---------------------------------------------------------------------------
# Fleet test 16: a manifest whose schema `version:` this reader does not
#                support is a prerequisite failure (exit 1), not a fleet
#                verdict. The manifest reserves version bumps for
#                INCOMPATIBLE changes and requires readers to refuse
#                unknown ones — an old auditor that still finds a parseable
#                `.consumers[].repo` would otherwise audit a consumer list
#                it no longer reads correctly and publish that partial run
#                as a fleet-wide result. Both sibling readers
#                (sync-to-downstream.sh, project-doc-sync.sh) already gate
#                on this.
# ---------------------------------------------------------------------------
FLEET_MANIFEST_V2="$WORKDIR/fleet-manifest-v2.yml"
cat >"$FLEET_MANIFEST_V2" <<'MANIFEST'
version: 2
consumers:
  - name: alpha
    repo: testowner/alpha
MANIFEST
set +e
out=$(PATH="$STUB_DIR:$PATH" bash "$SCRIPT" --fleet \
        --hub-repo testowner/hub \
        --manifest "$FLEET_MANIFEST_V2" \
        --audit-cmd "$FLEET_STUB" 2>&1)
rc=$?
set -e
if [ "$rc" -ne 1 ]; then
  fail "fleet unsupported manifest version: exit $rc, expected 1 (prerequisite); output: $out"
elif echo "$out" | grep -q "stub-audit reached"; then
  fail "fleet unsupported manifest version: must not audit anything from a manifest it cannot interpret; output: $out"
elif ! echo "$out" | grep -q "version '2'"; then
  fail "fleet unsupported manifest version: diagnostic must name the version it saw; output: $out"
else
  pass "fleet refuses an unsupported manifest schema version (exit 1, no verdict)"
fi

# ---------------------------------------------------------------------------
# Fleet test 17: a manifest with NO `version:` key is refused the same way.
#                yq reads the absent key as `null`, which must not be
#                waved through as "close enough to 1".
# ---------------------------------------------------------------------------
FLEET_MANIFEST_NOVER="$WORKDIR/fleet-manifest-noversion.yml"
cat >"$FLEET_MANIFEST_NOVER" <<'MANIFEST'
consumers:
  - name: alpha
    repo: testowner/alpha
MANIFEST
set +e
out=$(PATH="$STUB_DIR:$PATH" bash "$SCRIPT" --fleet \
        --hub-repo testowner/hub \
        --manifest "$FLEET_MANIFEST_NOVER" \
        --audit-cmd "$FLEET_STUB" 2>&1)
rc=$?
set -e
if [ "$rc" -ne 1 ]; then
  fail "fleet versionless manifest: exit $rc, expected 1; output: $out"
elif echo "$out" | grep -q "stub-audit reached"; then
  fail "fleet versionless manifest: must not audit anything; output: $out"
else
  pass "fleet refuses a manifest with no schema version at all"
fi

# ---------------------------------------------------------------------------
# Fleet test 18: an unwritable --summary-file fails the run (exit 1) rather
#                than returning a verdict with the summary missing. The
#                workflow embeds that file VERBATIM in the rollup issue
#                while truncating the verbose stdout, so a silent write
#                failure publishes a rollup built from nothing — or from a
#                stale file left by an earlier run. `set -e` cannot catch
#                it: fleet_audit runs on the left of `||` to capture its
#                status, which disables errexit for the whole function.
# ---------------------------------------------------------------------------
UNWRITABLE_SUMMARY="$WORKDIR/no-such-directory/fleet-summary.txt"
set +e
out=$(run_fleet one_drift --summary-file "$UNWRITABLE_SUMMARY" 2>&1)
rc=$?
set -e
if [ "$rc" -ne 1 ]; then
  fail "fleet unwritable --summary-file: exit $rc, expected 1 (prerequisite), not a verdict; output: $out"
elif [ -e "$UNWRITABLE_SUMMARY" ]; then
  fail "fleet unwritable --summary-file: the file must genuinely not exist for this test to mean anything"
elif ! echo "$out" | grep -q "could not write the fleet summary"; then
  fail "fleet unwritable --summary-file: diagnostic missing; output: $out"
else
  pass "fleet exits 1 when the summary file cannot be written (never a 0/3 with no summary)"
fi

# ---------------------------------------------------------------------------
# Fleet test 19: a STALE summary file from an earlier run is not left in
#                place behind a verdict either — the failure is reported
#                whether or not something is already at the path.
# ---------------------------------------------------------------------------
STALE_SUMMARY="$WORKDIR/stale-summary"
mkdir -p "$STALE_SUMMARY"
set +e
out=$(run_fleet one_drift --summary-file "$STALE_SUMMARY" 2>&1)
rc=$?
set -e
if [ "$rc" -ne 1 ]; then
  fail "fleet summary path is a directory: exit $rc, expected 1; output: $out"
elif ! echo "$out" | grep -q "could not write the fleet summary"; then
  fail "fleet summary path is a directory: diagnostic missing; output: $out"
else
  pass "fleet exits 1 when the summary path is unwritable for any reason"
fi

# ===========================================================================
# Classic protection ∪ rulesets (both surfaces are enforced at once)
# ===========================================================================
#
# GitHub applies classic branch protection AND every applicable ruleset
# simultaneously, so the effective requirement on a branch is the UNION of
# the two lists. scripts/merge-clearance-gate.sh's enforcement probe already
# unions them for exactly that reason, having verified live that
# mergepath@main's classic contexts do not appear on the ruleset surface at
# all. An audit that read classic protection and stopped there whenever it
# answered 200 reported a repo whose fifth check comes from a ruleset as
# DRIFT, every week, forever.

# ---------------------------------------------------------------------------
# Test 27: four canonical checks from classic protection, the fifth from a
#          ruleset → PASS. Pre-fix: exit 3 naming 'Merge clearance gate'.
# ---------------------------------------------------------------------------
set +e
out=$(run_audit classic_plus_ruleset 2>&1)
rc=$?
set -e
if [ "$rc" -ne 0 ]; then
  fail "classic ∪ ruleset: exit $rc, expected 0; output: $out"
elif ! echo "$out" | grep -q "PASS:"; then
  fail "classic ∪ ruleset: missing PASS line; output: $out"
elif ! echo "$out" | grep -q "Merge clearance gate"; then
  fail "classic ∪ ruleset: the ruleset-supplied check must appear in the enforced list; output: $out"
else
  pass "a canonical check supplied by a ruleset counts on a classically protected branch"
fi

# ---------------------------------------------------------------------------
# Test 28: the admin-bypass half unions too. Classic protection lists all
#          five with enforce_admins OFF, and an unbypassable ruleset
#          requires the same five. An admin bypasses only the CLASSIC
#          requirement — the ruleset still blocks the merge — so nothing
#          canonical is skippable. Judging the two surfaces separately
#          filed this fully gated repo as DRIFT.
# ---------------------------------------------------------------------------
set +e
out=$(run_audit classic_bypassable_plus_strict_ruleset --require-admin-enforcement 2>&1)
rc=$?
set -e
if [ "$rc" -ne 0 ]; then
  fail "union admin enforcement: exit $rc, expected 0; output: $out"
elif ! echo "$out" | grep -q "Admin enforcement: OK"; then
  fail "union admin enforcement: expected an explicit admin-enforcement OK line; output: $out"
elif echo "$out" | grep -q "skippable"; then
  fail "union admin enforcement: an unbypassable ruleset requiring the same checks keeps them mandatory; output: $out"
else
  pass "enforce_admins off is not an admin-bypass gap when an unbypassable ruleset requires the same checks"
fi

# ---------------------------------------------------------------------------
# Test 29: the union must not become a way to lose the enforce_admins
#          finding. Classic-only, all five checks, enforce_admins off →
#          still exit 3, and the diagnostic still names enforce_admins.
#          (Test 13 asserts the same from the other direction; this pins
#          that the unified analysis did not soften it.)
# ---------------------------------------------------------------------------
set +e
out=$(run_audit classic_admins_bypass --require-admin-enforcement 2>&1)
rc=$?
set -e
if [ "$rc" -ne 3 ]; then
  fail "classic-only admin bypass under the union: exit $rc, expected 3; output: $out"
elif ! echo "$out" | grep -q "skippable"; then
  fail "classic-only admin bypass: expected the checks to be reported skippable; output: $out"
elif ! echo "$out" | grep -q "enforce_admins"; then
  fail "classic-only admin bypass: the remediation must still name enforce_admins; output: $out"
else
  pass "classic-only enforce_admins gap survives the unified analysis (named, and exit 3)"
fi

# ===========================================================================
# Ruleset inventory pagination
# ===========================================================================

# ---------------------------------------------------------------------------
# Test 30: the ruleset that governs the branch is on page 2. A one-page
#          read omits it and reports a fully gated repo as unprotected.
#          Page 2 is served by the stub ONLY when --paginate is passed,
#          which is exactly how gh behaves.
# ---------------------------------------------------------------------------
set +e
out=$(run_audit ruleset_paginated 2>&1)
rc=$?
set -e
if [ "$rc" -ne 0 ]; then
  fail "paginated ruleset inventory: exit $rc, expected 0; output: $out"
elif ! echo "$out" | grep -q "PASS:"; then
  fail "paginated ruleset inventory: missing PASS line; output: $out"
elif echo "$out" | grep -q "no rulesets target main"; then
  fail "paginated ruleset inventory: page 2 was never read; output: $out"
else
  pass "ruleset inventory is paginated — a governing ruleset on page 2 is still found"
fi

# ===========================================================================
# GitHub's fnmatch semantics for conditions.ref_name (File::FNM_PATHNAME)
# ===========================================================================
#
# GitHub's ruleset docs state the rule outright: "Because GitHub uses the
# File::FNM_PATHNAME flag for the File.fnmatch syntax, the * wildcard does
# not match directory separators (/). For example, qa/* will match all
# branches beginning with qa/ and containing a single slash, but will not
# match qa/foo/bar." Bash's `[[ str == pat ]]` has no such rule, so it
# credited `refs/heads/release/*` with governing `release/a/b` (false PASS)
# and, in an exclude list, disqualified a ruleset that does govern it
# (false DRIFT). Every expectation below is the value real Ruby returns for
# File.fnmatch(pat, ref, File::FNM_PATHNAME) — see the differential test at
# the end of this section.

# ---------------------------------------------------------------------------
# Test 31: `refs/heads/release/*` governs `release/a` (one level).
# ---------------------------------------------------------------------------
set +e
out=$(run_audit ruleset_single_star_deep --branch release/a 2>&1)
rc=$?
set -e
if [ "$rc" -ne 0 ]; then
  fail "single-star include at one level: exit $rc, expected 0; output: $out"
else
  pass "refs/heads/release/* governs release/a"
fi

# ---------------------------------------------------------------------------
# Test 32: ...and does NOT govern `release/a/b`, because `*` cannot cross a
#          `/`. Pre-fix this was a false PASS on an ungoverned branch.
# ---------------------------------------------------------------------------
set +e
out=$(run_audit ruleset_single_star_deep --branch release/a/b 2>&1)
rc=$?
set -e
if [ "$rc" -ne 3 ]; then
  fail "single-star include must not cross '/': exit $rc, expected 3; output: $out"
elif ! echo "$out" | grep -q "no rulesets target release/a/b"; then
  fail "single-star include: expected 'no rulesets target release/a/b'; output: $out"
else
  pass "refs/heads/release/* does NOT govern release/a/b (* does not cross '/')"
fi

# ---------------------------------------------------------------------------
# Test 33: Ruby's recursive form `**/` does cross separators, so
#          `refs/heads/release/**/*` governs `release/a/b`.
# ---------------------------------------------------------------------------
set +e
out=$(run_audit ruleset_double_star_deep --branch release/a/b 2>&1)
rc=$?
set -e
if [ "$rc" -ne 0 ]; then
  fail "recursive '**/' include: exit $rc, expected 0; output: $out"
else
  pass "refs/heads/release/**/* governs release/a/b (the recursive '**/' form)"
fi

# ---------------------------------------------------------------------------
# Test 34: a TRAILING `**` is not the recursive form. Ruby special-cases
#          the literal three bytes `**/` only, so `refs/heads/release/**`
#          behaves like `refs/heads/release/*`: it governs release/a but
#          not release/a/b. Treating every `**` as recursive would credit
#          a ruleset that does not govern the branch.
# ---------------------------------------------------------------------------
set +e
out=$(run_audit ruleset_trailing_double_star --branch release/a 2>&1)
rc=$?
set -e
if [ "$rc" -ne 0 ]; then
  fail "trailing '**' at one level: exit $rc, expected 0; output: $out"
else
  set +e
  out=$(run_audit ruleset_trailing_double_star --branch release/a/b 2>&1)
  rc=$?
  set -e
  if [ "$rc" -ne 3 ]; then
    fail "trailing '**' must not cross '/': exit $rc, expected 3; output: $out"
  else
    pass "refs/heads/release/** governs release/a but not release/a/b (trailing ** is not '**/')"
  fi
fi

# ---------------------------------------------------------------------------
# Test 35: the exclusion mirror. `exclude: [refs/heads/release/*]` on a
#          `~ALL` ruleset disqualifies release/a but NOT release/a/b — the
#          same non-crossing rule, in the direction where getting it wrong
#          drops the only ruleset protecting a branch and files false DRIFT.
# ---------------------------------------------------------------------------
set +e
out=$(run_audit ruleset_exclude_single_star_deep --branch release/a 2>&1)
rc=$?
set -e
if [ "$rc" -ne 3 ]; then
  fail "exclude single-star at one level: exit $rc, expected 3 (excluded); output: $out"
else
  set +e
  out=$(run_audit ruleset_exclude_single_star_deep --branch release/a/b 2>&1)
  rc=$?
  set -e
  if [ "$rc" -ne 0 ]; then
    fail "exclude single-star must not cross '/': exit $rc, expected 0 (still governed); output: $out"
  else
    pass "an exclude of refs/heads/release/* disqualifies release/a but not release/a/b"
  fi
fi

# ---------------------------------------------------------------------------
# Test 36: DIFFERENTIAL. The matcher is extracted verbatim from the audit
#          script and compared against the reference implementation GitHub
#          names in its own docs — Ruby's File.fnmatch under
#          File::FNM_PATHNAME. Every pattern/ref pair must agree.
# ---------------------------------------------------------------------------
FNMATCH_SNIPPET="$WORKDIR/fnmatch.sh"
awk '/^# BEGIN fnmatch/{f=1; next} /^# END fnmatch$/{f=0} f' "$SCRIPT" > "$FNMATCH_SNIPPET"
if ! grep -q 'fnmatch_pathname()' "$FNMATCH_SNIPPET"; then
  fail "could not extract the fnmatch matcher from $SCRIPT (BEGIN/END fnmatch markers moved?)"
elif ! command -v ruby >/dev/null 2>&1; then
  # Fail rather than skip: this is the only test that pins the matcher to
  # the semantics GitHub documents, and a silent skip would let a rewrite
  # of it ship unchecked.
  fail "ruby is required to differentially test the fnmatch matcher against File::FNM_PATHNAME"
else
  # shellcheck source=/dev/null
  . "$FNMATCH_SNIPPET"
  FNM_PATTERNS=(
    'refs/heads/main'
    'refs/heads/*'
    'refs/heads/**'
    'refs/heads/**/*'
    'refs/heads/release/*'
    'refs/heads/release/**'
    'refs/heads/release/**/*'
    'refs/heads/release/*/*'
    'refs/heads/release/*/'
    'refs/heads/**/'
    'refs/heads/qa**/**/*'
    'refs/heads/rel-[0-9]'
    'refs/heads/rel-[0-9]*'
    'refs/heads/release-[[:digit:]]'
    'refs/heads/re?ease'
    'refs/heads/**/deep'
    'refs/tags/*'
  )
  FNM_REFS=(
    'refs/heads/main'
    'refs/heads/release'
    'refs/heads/release/a'
    'refs/heads/release/a/b'
    'refs/heads/release/a/b/c'
    'refs/heads/'
    'refs/heads/release/a/'
    'refs/heads/qa/foo/bar'
    'refs/heads/qafoo/x/y'
    'refs/heads/rel-7'
    'refs/heads/rel-77'
    'refs/heads/relXease'
    'refs/heads/release-5'
    'refs/heads/a/b/deep'
    'refs/heads/deep'
  )
  # Compared through files rather than a parallel array: this suite has to
  # run under the bash 3.2 that ships with macOS as /bin/bash, where an
  # array indexed under `set -u` is not portable.
  FNM_PAIRS="$WORKDIR/fnm-pairs.tsv"
  FNM_RUBY="$WORKDIR/fnm-ruby.tsv"
  FNM_BASH="$WORKDIR/fnm-bash.tsv"
  : >"$FNM_PAIRS"
  for p in "${FNM_PATTERNS[@]}"; do
    for r in "${FNM_REFS[@]}"; do
      printf '%s\t%s\n' "$p" "$r" >>"$FNM_PAIRS"
    done
  done
  # One ruby process for the whole matrix. Reference implementation:
  # File.fnmatch under File::FNM_PATHNAME, the exact combination GitHub's
  # ruleset docs name.
  ruby -e '
    STDIN.each_line do |line|
      pat, ref = line.chomp.split("\t", 2)
      puts "#{pat}\t#{ref}\t#{File.fnmatch(pat, ref, File::FNM_PATHNAME)}"
    end
  ' <"$FNM_PAIRS" >"$FNM_RUBY"
  : >"$FNM_BASH"
  while IFS=$'\t' read -r p r; do
    if fnmatch_pathname "$p" "$r"; then got=true; else got=false; fi
    printf '%s\t%s\t%s\n' "$p" "$r" "$got" >>"$FNM_BASH"
  done <"$FNM_PAIRS"
  fnm_pairs="$(wc -l < "$FNM_PAIRS" | tr -d ' ')"
  if ! fnm_diff="$(diff "$FNM_RUBY" "$FNM_BASH")"; then
    printf '%s\n' "$fnm_diff" | sed 's/^/  /' >&2
    fail "fnmatch matcher disagrees with Ruby File::FNM_PATHNAME (< ruby, > bash)"
  else
    pass "fnmatch matcher agrees with Ruby File::FNM_PATHNAME on all $fnm_pairs pattern/ref pairs"
  fi
fi

# ===========================================================================
# Default-branch shape check vs. real `git check-ref-format`
# ===========================================================================
#
# looks_like_branch_name is the second line of defence behind the status
# check on the metadata read: it must reject a leaked HTTP error body while
# accepting every name git will actually give a branch. An earlier ASCII
# allow-list (`^[A-Za-z0-9][A-Za-z0-9._/+-]*$`) rejected legitimate names
# — `feat#2`, `feat%2Ftwo`, anything non-ASCII — and turned those repos
# into permanent fleet ERRORs. So the predicate is checked against the real
# `git check-ref-format` binary, not against a re-reading of the regex.

REFCHECK_SNIPPET="$WORKDIR/refcheck.sh"
awk '/^# BEGIN looks_like_branch_name/{f=1} /^# END looks_like_branch_name$/{f=0} f' "$SCRIPT" \
  > "$REFCHECK_SNIPPET"
if ! grep -q 'looks_like_branch_name()' "$REFCHECK_SNIPPET"; then
  fail "could not extract looks_like_branch_name from $SCRIPT (BEGIN/END markers moved?)"
elif ! command -v git >/dev/null 2>&1; then
  fail "git is required to check looks_like_branch_name against git check-ref-format"
else
  # shellcheck source=/dev/null
  . "$REFCHECK_SNIPPET"
  # Names git accepts for refs/heads/<name>. Every one MUST be accepted:
  # rejecting any of them is an availability bug that reports a healthy
  # repo as an infrastructure failure.
  REF_ACCEPT=(
    'main'
    'master'
    'trunk'
    'release/1.2'
    'feature/a/b/c'
    'feat#2'
    'feat%2Ftwo'
    'fix!urgent'
    'v1.0+build'
    'a,b'
    'x&y'
    "it's"
    'name(paren)'
    'semi;colon'
    'eq=sign'
    'dollar$sign'
    'brace{x}'
    'ünïcode-brånch'
    '分支'
    'UPPER_lower-123'
    'a.b.c'
    '@'
  )
  # Values that must be REJECTED. Each is either forbidden by
  # check-ref-format or one of the two documented extras (`null`, leading
  # `{`, leading `-`); the loop below insists on that justification, so a
  # rejection can never be justified by "the regex said so".
  REF_REJECT=(
    '{"message":"Not Found","status":"404"}'
    '{"message":"Server Error","status":"500"}'
    'null'
    ''
    'has space'
    'has:colon'
    'has~tilde'
    'has^caret'
    'has?question'
    'has*star'
    'has[bracket'
    'has\backslash'
    'dot..dot'
    'at@{brace'
    '/leading'
    'trailing/'
    'double//slash'
    'trailing.'
    '.hidden'
    'nested/.hidden'
    'foo.lock'
    'nested/foo.lock'
    '-leading'
  )
  ref_bad=0
  for n in "${REF_ACCEPT[@]}"; do
    if ! git check-ref-format "refs/heads/$n" >/dev/null 2>&1; then
      echo "  fixture error: git check-ref-format REJECTS 'refs/heads/$n' — it does not belong in REF_ACCEPT" >&2
      ref_bad=$((ref_bad + 1))
      continue
    fi
    if ! looks_like_branch_name "$n"; then
      echo "  looks_like_branch_name REJECTS '$n', which git accepts" >&2
      ref_bad=$((ref_bad + 1))
    fi
  done
  for n in "${REF_REJECT[@]}"; do
    if looks_like_branch_name "$n"; then
      echo "  looks_like_branch_name ACCEPTS '$n', which it must not" >&2
      ref_bad=$((ref_bad + 1))
      continue
    fi
    # A rejection is only legitimate if git rejects the name too — as a
    # ref OR as a branch name, which is stricter — or it is one of the two
    # documented extras (`null`, a leading `{`) or the empty string.
    case "$n" in
      ''|null|'{'*) continue ;;
    esac
    if git check-ref-format "refs/heads/$n" >/dev/null 2>&1 \
       && git check-ref-format --branch "$n" >/dev/null 2>&1; then
      echo "  fixture error: git ACCEPTS '$n' as a branch name, so rejecting it is an availability bug, not a defence" >&2
      ref_bad=$((ref_bad + 1))
    fi
  done
  if [ "$ref_bad" -ne 0 ]; then
    fail "looks_like_branch_name disagrees with git check-ref-format on $ref_bad case(s)"
  else
    pass "looks_like_branch_name accepts every name git accepts (${#REF_ACCEPT[@]} cases) and rejects only what git forbids plus the 2 documented extras (${#REF_REJECT[@]} cases)"
  fi
fi

# ---------------------------------------------------------------------------
# Test 38: end-to-end — a fleet whose repos default to a branch name the
#          old ASCII allow-list rejected must be AUDITED, not written off
#          as an infrastructure ERROR.
# ---------------------------------------------------------------------------
set +e
out=$(STUB_DEFAULT_BRANCH='feat#2' run_fleet all_pass 2>&1)
rc=$?
set -e
if [ "$rc" -ne 0 ]; then
  fail "fleet with a '#' in the default branch: exit $rc, expected 0; output: $out"
elif echo "$out" | grep -q "ERROR"; then
  fail "fleet with a '#' in the default branch: must not report an infrastructure ERROR; output: $out"
elif ! echo "$out" | grep -qE "^PASS +rc=0 +testowner/hub@feat#2$"; then
  fail "fleet with a '#' in the default branch: expected the repo audited on 'feat#2'; output: $out"
else
  pass "a default branch containing '#' is audited, not turned into a fleet ERROR"
fi

# ---------------------------------------------------------------------------
# Test 39: ...and the branch is percent-encoded before it is interpolated
#          into the protection path. Unencoded, `#` starts a URL fragment
#          and everything after it — including `/protection` — is dropped.
#          `/` must NOT be encoded: GitHub's route takes a hierarchical
#          branch name with literal separators.
# ---------------------------------------------------------------------------
PATH_LOG="$WORKDIR/paths.log"
: >"$PATH_LOG"
set +e
out=$(STUB_PATH_LOG="$PATH_LOG" run_audit classic_protected --branch 'feat#2/x' 2>&1)
rc=$?
set -e
if [ "$rc" -ne 0 ]; then
  fail "percent-encoded branch path: exit $rc, expected 0; output: $out"
elif ! grep -q 'branches/feat%232/x/protection' "$PATH_LOG"; then
  fail "the branch must be percent-encoded per segment before interpolation; requested paths: $(cat "$PATH_LOG")"
elif grep -q 'feat#2' "$PATH_LOG"; then
  fail "an unencoded '#' reached the API path (everything after it is a URL fragment); requested paths: $(cat "$PATH_LOG")"
else
  pass "a branch name is percent-encoded per segment for the protection path ('/' preserved)"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "test_audit_branch_protection: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
