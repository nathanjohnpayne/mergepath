#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCOPE="$ROOT/scripts/ci/repo-lint-scope.sh"
DEPENDENCIES="$ROOT/scripts/ci/repo-lint-dependencies.json"
REPO_LINT="$ROOT/.github/workflows/repo_lint.yml"
MD_WRAP="$ROOT/.github/workflows/md-prose-wrap.yml"
OWL="$ROOT/.github/workflows/owl-rules-check.yml"
AGENT_REVIEW="$ROOT/.github/workflows/agent-review.yml"
AUTO_CLEAR="$ROOT/.github/workflows/auto-clear-blocking-labels.yml"
TOKEN_WRAPPER="$ROOT/scripts/ci/check_no_token_in_output"
DOC_WRAPPER="$ROOT/scripts/ci/check_doc_ownership"
AUTO_CLEAR_WRAPPER="$ROOT/scripts/ci/check_auto_clear_workflow"
CONSUMER_VERDICT="$ROOT/scripts/ci/repo-lint-consumer-verdict.sh"
MODE_HELPER="$ROOT/scripts/lib/ci-check-modes.sh"
SELECTION_HELPER="$ROOT/scripts/lib/repo-lint-check-selection.sh"
CONSUMER_HARNESS="$ROOT/tests/test_repo_lint_consumer_safety.sh"
RESIDUE_HARNESS="$ROOT/tests/test_consumer_residue_safety.sh"

PASS=0
FAIL=0

pass() {
  echo "PASS: $*"
  PASS=$((PASS + 1))
}

fail() {
  echo "FAIL: $*" >&2
  FAIL=$((FAIL + 1))
}

# Derive this test-only inventory from raw wrapper text. A shell comment
# stripper can erase a later source command when a quoted `#` occurs first on
# the same physical line; raw inspection is conservative and cannot miss it.
mode_helper_source_inventory_entry() {
  local wrapper="$1"
  grep -q 'ci-check-modes\.sh' "$wrapper" || return 1
  basename "$wrapper"
}

# True when $1 matches one of the newline-separated case globs in $2, the
# way the classifier matches graph entries.
matches_any_glob() {
  local candidate="$1" patterns="$2" pattern
  while IFS= read -r pattern; do
    [ -n "$pattern" ] || continue
    # shellcheck disable=SC2254 # graph entries are case globs by design
    case "$candidate" in $pattern) return 0 ;; esac
  done <<<"$patterns"
  return 1
}

# The classifier changes behaviour with the checkout it sits in (hub vs
# consumer mode), and this suite also runs on consumers, so its assertions
# run against explicit fixture roots rather than "$SCOPE" in place:
# HUB_SCOPE_ROOT carries both hub markers, CONSUMER_SCOPE_ROOT neither.
SCOPE_FIXTURES="$(mktemp -d "${TMPDIR:-/tmp}/repo-lint-scope.XXXXXX")"
trap 'rm -rf "$SCOPE_FIXTURES"' EXIT
HUB_SCOPE_ROOT="$SCOPE_FIXTURES/hub"
CONSUMER_SCOPE_ROOT="$SCOPE_FIXTURES/consumer"
for scope_root in "$HUB_SCOPE_ROOT" "$CONSUMER_SCOPE_ROOT"; do
  mkdir -p "$scope_root/scripts/ci"
  if [ -f "$SCOPE" ]; then
    cp "$SCOPE" "$scope_root/scripts/ci/repo-lint-scope.sh"
  fi
  if [ -f "$DEPENDENCIES" ]; then
    cp "$DEPENDENCIES" "$scope_root/scripts/ci/repo-lint-dependencies.json"
  fi
done
touch "$HUB_SCOPE_ROOT/scripts/sync-to-downstream.sh" "$HUB_SCOPE_ROOT/.mergepath-sync.yml"

classify() {
  local event="$1"
  shift
  printf '%s\n' "$@" | bash "$HUB_SCOPE_ROOT/scripts/ci/repo-lint-scope.sh" --event "$event"
}

consumer_scope_value() {
  local key="$1" event="$2"
  shift 2
  printf '%s\n' "$@" \
    | bash "$CONSUMER_SCOPE_ROOT/scripts/ci/repo-lint-scope.sh" --event "$event" \
    | sed -n "s/^${key}=//p"
}

scope_value() {
  local key="$1" event="$2"
  shift 2
  classify "$event" "$@" | sed -n "s/^${key}=//p"
}

if [ ! -f "$SCOPE" ]; then
  fail "repo-lint scope classifier exists"
else
  if [ "$(scope_value deep pull_request docs/README.md plans/example.md)" = "false" ]; then
    pass "ordinary documentation changes stay on the fast required lane"
  else
    fail "ordinary documentation changes should not request deep CI"
  fi

  for path in \
    .github/workflows/repo_lint.yml \
    scripts/ci/check_example \
    tests/test_example.sh \
    specs/example.md \
    rules/repo_rules.md \
    docs/agents/operating-rules.md \
    docs/architecture/0002-branch-protection-enforcement-posture.md \
    .mergepath-sync.yml \
    .repo-template.yml \
    REVIEW_POLICY.md \
    ai_agent_tooling_standard.md; do
    if [ "$(scope_value deep pull_request "$path")" = "true" ]; then
      pass "$path requests deep CI"
    else
      fail "$path must request deep CI"
    fi
  done

  # #1655: governance documents request the deep legs in SMOKE mode. Their
  # only deep-lane readers are the hub-only harnesses, so they select no
  # self-test, no complete consumer replay and no fail-closed full surface;
  # the complete replay runs for them on push to main and on the schedule.
  # Every output key is asserted so a regression to the old fail-closed
  # behaviour (full=true) or a new silent key cannot pass unnoticed.
  governance_smoke_ok=1
  for path in \
    specs/example.md \
    rules/repo_rules.md \
    docs/agents/operating-rules.md \
    docs/architecture/0002-branch-protection-enforcement-posture.md \
    .repo-template.yml \
    AGENTS.md \
    REVIEW_POLICY.md \
    ai_agent_tooling_standard.md; do
    scope_out=$(classify pull_request "$path" | LC_ALL=C sort | tr '\n' ' ')
    if [ "$scope_out" != "checks=[] consumer_replay=false deep=true full=false self_tests=false " ]; then
      governance_smoke_ok=0
      echo "INFO: $path -> $scope_out" >&2
    fi
  done
  if [ "$governance_smoke_ok" -eq 1 ]; then
    pass "governance documents request deep smoke without the full surface, the complete replay, or the self-test legs"
  else
    fail "governance documents must classify as deep=true full=false checks=[] consumer_replay=false self_tests=false"
  fi

  # The reader of rules/repo_rules.md (the self-approval policy checker) is a
  # live lint-fast step, so moving the document off the full surface removes
  # nothing from the required lane. Pinned here so the smoke assertion above
  # cannot outlive the live step it relies on.
  if command -v yq >/dev/null 2>&1 \
     && yq -e '[.jobs.lint_fast.steps[] | select(.name == "check_self_approval_detector")] | length == 1' "$REPO_LINT" >/dev/null 2>&1; then
    pass "the self-approval policy checker stays a live lint-fast step"
  else
    fail "check_self_approval_detector must remain wired in lint-fast (the rules/ reader moved off the full deep surface)"
  fi

  # Consumer-shape inputs select the complete consumer replay (the sharded
  # deep_consumer_replay job) without forcing every self-test; a change to
  # the bootstrap exclusion list also selects its own wrapper (and, since
  # #2580, every other wrapper whose suites name it). The manifest selects
  # exactly one wrapper, the pre-push fleet suite that reads its consumer
  # facts and hook entries (#2844), which is not an enrolled self-test.
  manifest_scope=$(classify pull_request .mergepath-sync.yml | LC_ALL=C sort | tr '\n' ' ')
  mirror_scope=$(classify pull_request scripts/bootstrap/template-mirror.sh | LC_ALL=C sort | tr '\n' ' ')
  mirror_checks=$(scope_value checks pull_request scripts/bootstrap/template-mirror.sh)
  if [ "$manifest_scope" = 'checks=["check_repo_lint_prepush_fleet"] consumer_replay=true deep=true full=false self_tests=false ' ] \
     && case "$mirror_scope" in *"consumer_replay=true deep=true full=false "*) true ;; *) false ;; esac \
     && jq -e 'index("check_bootstrap_template_mirror") != null' <<<"$mirror_checks" >/dev/null 2>&1; then
    pass "consumer-shape inputs select the complete consumer replay without the full surface"
  else
    fail "manifest/bootstrap-exclusion changes must select consumer_replay=true with full=false (manifest: $manifest_scope; mirror: $mirror_scope)"
  fi

  # A propagation-lane head runs the complete surface on every repo.
  sync_head=$(printf '%s\n' docs/README.md | bash "$HUB_SCOPE_ROOT/scripts/ci/repo-lint-scope.sh" --event pull_request --head-ref mergepath-sync/abc123 | LC_ALL=C sort | tr '\n' ' ')
  feature_head=$(printf '%s\n' docs/README.md | bash "$HUB_SCOPE_ROOT/scripts/ci/repo-lint-scope.sh" --event pull_request --head-ref feat/abc123 | sed -n 's/^deep=//p')
  if [ "$sync_head" = "checks=[] consumer_replay=true deep=true full=true self_tests=true " ] && [ "$feature_head" = "false" ]; then
    pass "a mergepath-sync/ head selects the complete surface; an ordinary head does not"
  else
    fail "--head-ref mergepath-sync/* must fail closed to the full surface (sync: $sync_head; feature deep=$feature_head)"
  fi

  # self_tests follows the graph's enrolment list: a lint-fast-only wrapper
  # leaves the self-test legs idle, an enrolled wrapper or a full selection
  # starts them.
  if [ "$(scope_value self_tests pull_request scripts/ci/check_codex_scripts)" = "false" ] \
     && [ "$(scope_value self_tests pull_request scripts/ci/check_cockpit)" = "true" ] \
     && [ "$(scope_value self_tests pull_request scripts/unknown-helper.sh)" = "true" ] \
     && [ "$(scope_value self_tests pull_request docs/README.md)" = "false" ]; then
    pass "self_tests is true only for a full selection or an enrolled wrapper"
  else
    fail "self_tests must track the graph's self-test enrolment (codex=$(scope_value self_tests pull_request scripts/ci/check_codex_scripts) cockpit=$(scope_value self_tests pull_request scripts/ci/check_cockpit))"
  fi

  if [ "$(scope_value deep pull_request scripts/ci/README.md tests/README.md scripts/phase-4b/README.md)" = "false" ]; then
    pass "prose beside the implementation stays on the fast lane"
  else
    fail "scripts/**/*.md and tests/*.md must not request deep CI by shape"
  fi

  # The graph's self_tests list must equal the set of suites the workflow
  # enrols: a suite enrolled in the workflow but absent from the list leaves
  # its leg unstarted for a partial selection (a silent coverage gap), and a
  # listed suite the workflow never runs starts the legs for nothing.
  if command -v yq >/dev/null 2>&1 && [ -f "$DEPENDENCIES" ]; then
    enrolled=$(yq -r '.jobs.deep_self_tests.steps[] | select(.name | test(" --self-test$")) | .name | sub(" --self-test$"; "")' "$REPO_LINT" | LC_ALL=C sort -u)
    listed=$(jq -r '.self_tests[]' "$DEPENDENCIES" | LC_ALL=C sort -u)
    if [ -n "$enrolled" ] && [ "$enrolled" = "$listed" ]; then
      pass "the graph's self_tests list equals the workflow's enrolled --self-test suites ($(printf '%s\n' "$enrolled" | wc -l | tr -d ' '))"
    else
      fail "repo-lint-dependencies.json self_tests must equal the deep_self_tests --self-test steps (workflow: $(tr '\n' ' ' <<<"$enrolled"); graph: $(tr '\n' ' ' <<<"$listed"))"
    fi
  fi

  # Every test a declared wrapper names must be a declared dependency of
  # that wrapper, so a suite a wrapper gains cannot route to the wrong
  # partial selection. References are read from the RAW wrapper text,
  # comments included (#2227): a comment stripper has to model shell syntax
  # (quotes, heredocs, `$#`, continuations, `${…}`), and every construct it
  # misreads hides a live reference silently (#2176). Scanning raw text can
  # only over-ask, and an over-ask is loud. A test a wrapper names only in a
  # comment is therefore declared under it, or the comment is reworded so it
  # no longer names a test path. There are deliberately no per-wrapper or
  # per-path exemptions: one that fits a comment today would hide an
  # executable reference added beside it later. Hub-only: the wrappers are
  # read from the tree.
  if [ -f "$ROOT/scripts/sync-to-downstream.sh" ] && [ -f "$DEPENDENCIES" ]; then
    undeclared_refs=""
    witness_refs=""
    declared_wrappers=$(jq -r '.wrappers | keys[]' "$DEPENDENCIES")
    while IFS= read -r wrapper; do
      [ -n "$wrapper" ] || continue
      [ -f "$ROOT/scripts/ci/$wrapper" ] || continue
      wrapper_patterns=$(jq -r --arg w "$wrapper" '.wrappers[$w][]' "$DEPENDENCIES")
      referenced=$(grep -o 'tests/test_[A-Za-z0-9_]*\.\(sh\|py\|cjs\)' "$ROOT/scripts/ci/$wrapper" \
        | LC_ALL=C sort -u || true)
      while IFS= read -r ref; do
        [ -n "$ref" ] || continue
        declared=0
        while IFS= read -r pattern; do
          [ -n "$pattern" ] || continue
          # shellcheck disable=SC2254 # graph entries are case globs by design
          case "$ref" in $pattern) declared=1; break ;; esac
        done <<<"$wrapper_patterns"
        [ "$declared" -eq 1 ] || undeclared_refs="$undeclared_refs $wrapper:$ref"
      done <<<"$referenced"
      [ "$wrapper" != "check_merge_clearance_gate" ] || witness_refs="$referenced"
    done <<<"$declared_wrappers"
    if [ -z "$undeclared_refs" ]; then
      pass "every test a declared wrapper names, in code or in a comment, is a declared dependency of that wrapper"
    else
      fail "wrapper test references missing from repo-lint-dependencies.json (declare each under its wrapper, or reword the comment that names it; #2227):$undeclared_refs"
    fi
    # Non-vacuity witness (#2227): check_merge_clearance_gate names this
    # suite only inside a `#` comment, so it is visible exactly when the
    # extraction above reads raw text. Any comment stripper reintroduced at
    # the call site, naive or quote-aware, drops it while the completeness
    # check still passes. Should the comment change, move the witness to
    # another test path a wrapper names only in a comment.
    if grep -Fxq 'tests/test_465_fail_closed.sh' <<<"$witness_refs"; then
      pass "the reference extraction reads comments too (check_merge_clearance_gate witness)"
    else
      fail "the reference extraction lost tests/test_465_fail_closed.sh, which check_merge_clearance_gate names only in a comment; references must be read from the raw wrapper text (#2227)"
    fi
  fi

  # #2580: every top-level scripts/*.sh that a declared wrapper names, in its
  # own text or in a suite it runs, is a declared dependency of that wrapper. An undeclared script
  # costs both lanes: CI fails closed to the complete surface for it, and
  # the pre-push hook runs only the live assertions for it, so a change to
  # the script never runs the suite that exercises it before the push. A
  # script declared under one wrapper but named by another wrapper's suite is
  # worse: CI selects the first wrapper alone and skips the second suite
  # (#1839). Suites are read from the RAW wrapper text and scripts from the
  # RAW wrapper and suite text, comments included, for the reason given
  # above (#2227); a wrapper can inspect a script itself, as
  # check_workflow_parsers does scripts/required-head-checks.sh:
  # a reference reader can only over-ask, and an over-ask is loud. A script
  # the lane's own definition covers (full_triggers) already selects
  # everything. Hub-only: the wrappers and suites are read from the tree.
  if [ -f "$ROOT/scripts/sync-to-downstream.sh" ] && [ -f "$DEPENDENCIES" ]; then
    # Real-case names: a case-insensitive filesystem would accept a
    # miscased reference as an existing file.
    top_scripts=$(find "$ROOT/scripts" -maxdepth 1 -type f -name '*.sh' -exec basename {} \; | sed 's|^|scripts/|' | LC_ALL=C sort -u)
    full_trigger_patterns=$(jq -r '.full_triggers[]' "$DEPENDENCIES")
    script_gaps=""
    script_edges=0
    gh_as_author_witness=0
    wrapper_direct_witness=0
    while IFS= read -r wrapper; do
      [ -n "$wrapper" ] || continue
      [ -f "$ROOT/scripts/ci/$wrapper" ] || continue
      wrapper_patterns=$(jq -r --arg w "$wrapper" '.wrappers[$w][]' "$DEPENDENCIES")
      suites=$(grep -o 'tests/test_[A-Za-z0-9_]*\.\(sh\|py\|cjs\)' "$ROOT/scripts/ci/$wrapper" | LC_ALL=C sort -u || true)
      named=$({
          grep -o 'scripts/[A-Za-z0-9_.-]*\.sh' "$ROOT/scripts/ci/$wrapper" || true
          while IFS= read -r suite; do
            [ -n "$suite" ] && [ -f "$ROOT/$suite" ] || continue
            grep -o 'scripts/[A-Za-z0-9_.-]*\.sh' "$ROOT/$suite" || true
          done <<<"$suites"
        } | LC_ALL=C sort -u | LC_ALL=C comm -12 - <(printf '%s\n' "$top_scripts"))
      while IFS= read -r script; do
        [ -n "$script" ] || continue
        if matches_any_glob "$script" "$full_trigger_patterns"; then
          continue
        fi
        script_edges=$((script_edges + 1))
        if [ "$wrapper" = check_gh_as_author ] && [ "$script" = scripts/gh-as-author.sh ]; then
          gh_as_author_witness=1
        fi
        # Named only by the wrapper itself, so it is visible exactly when the
        # wrapper's own text is read.
        if [ "$wrapper" = check_workflow_parsers ] && [ "$script" = scripts/required-head-checks.sh ]; then
          wrapper_direct_witness=1
        fi
        matches_any_glob "$script" "$wrapper_patterns" || script_gaps="$script_gaps $wrapper:$script"
      done <<<"$named"
    done < <(jq -r '.wrappers | keys[]' "$DEPENDENCIES")
    if [ -z "$script_gaps" ] && [ "$script_edges" -gt 0 ] && [ "$gh_as_author_witness" -eq 1 ] && [ "$wrapper_direct_witness" -eq 1 ]; then
      pass "every top-level script a declared wrapper or its suites name is declared under that wrapper ($script_edges edges)"
    else
      fail "scripts named by a wrapper or its suites but not declared under that wrapper in repo-lint-dependencies.json (declare each under that wrapper; #2580; edges=$script_edges, gh-as-author witness=$gh_as_author_witness, wrapper-direct witness=$wrapper_direct_witness):$script_gaps"
    fi

    # Libraries (scripts/lib/*.sh, scripts/bootstrap/*.sh) follow the same
    # rule once declared under ANY wrapper: a partial declaration is what
    # makes CI select that wrapper alone and skip the others whose suites
    # name the library (#1839: dependabot-commit-provenance.sh was declared
    # only under check_merge_clearance_gate). Adding a wrapper to a declared
    # library only widens CI's selection. A library no wrapper declares is
    # left alone: CI keeps the complete surface for it, and declaring it
    # safely needs the wrappers of every script that sources it, which a
    # name scan cannot see.
    all_patterns=$(jq -r '.wrappers[][]' "$DEPENDENCIES")
    declared_libs=$(find "$ROOT/scripts/lib" "$ROOT/scripts/bootstrap" -maxdepth 1 -type f -name '*.sh' 2>/dev/null \
      | sed "s|^$ROOT/||" | LC_ALL=C sort -u | while IFS= read -r lib; do
          if matches_any_glob "$lib" "$all_patterns"; then printf '%s\n' "$lib"; fi
        done)
    lib_gaps=""
    lib_edges=0
    provenance_witness=0
    while IFS= read -r wrapper; do
      [ -n "$wrapper" ] || continue
      [ -f "$ROOT/scripts/ci/$wrapper" ] || continue
      wrapper_patterns=$(jq -r --arg w "$wrapper" '.wrappers[$w][]' "$DEPENDENCIES")
      suites=$(grep -o 'tests/test_[A-Za-z0-9_]*\.\(sh\|py\|cjs\)' "$ROOT/scripts/ci/$wrapper" | LC_ALL=C sort -u || true)
      named=$({
          grep -o 'scripts/\(lib\|bootstrap\)/[A-Za-z0-9_.-]*\.sh' "$ROOT/scripts/ci/$wrapper" || true
          while IFS= read -r suite; do
            [ -n "$suite" ] && [ -f "$ROOT/$suite" ] || continue
            grep -o 'scripts/\(lib\|bootstrap\)/[A-Za-z0-9_.-]*\.sh' "$ROOT/$suite" || true
          done <<<"$suites"
        } | LC_ALL=C sort -u | LC_ALL=C comm -12 - <(printf '%s\n' "$declared_libs"))
      while IFS= read -r lib; do
        [ -n "$lib" ] || continue
        if matches_any_glob "$lib" "$full_trigger_patterns"; then
          continue
        fi
        lib_edges=$((lib_edges + 1))
        if [ "$wrapper" = check_workflow_parsers ] && [ "$lib" = scripts/lib/dependabot-commit-provenance.sh ]; then
          provenance_witness=1
        fi
        matches_any_glob "$lib" "$wrapper_patterns" || lib_gaps="$lib_gaps $wrapper:$lib"
      done <<<"$named"
    done < <(jq -r '.wrappers | keys[]' "$DEPENDENCIES")
    if [ -z "$lib_gaps" ] && [ "$lib_edges" -gt 0 ] && [ "$provenance_witness" -eq 1 ]; then
      pass "every declared library is declared under each wrapper that it or its suites name ($lib_edges edges)"
    else
      fail "declared libraries missing from a wrapper that names them, which CI then skips (declare each under that wrapper; #1839, #2580; edges=$lib_edges, provenance witness=$provenance_witness):$lib_gaps"
    fi
  fi

  if [ "$(scope_value full push docs/README.md)" = "true" ] \
     && [ "$(scope_value full schedule docs/README.md)" = "true" ] \
     && [ "$(scope_value full workflow_dispatch docs/README.md)" = "true" ]; then
    pass "main pushes, schedules, and manual runs execute the full regression surface"
  else
    fail "non-PR events must fail closed to deep CI"
  fi

  if [ "$(printf '' | bash "$SCOPE" --event pull_request | sed -n 's/^deep=//p')" = "false" ]; then
    pass "an empty PR diff does not invent deep work"
  else
    fail "an empty PR diff should stay fast"
  fi

  if [ ! -f "$DEPENDENCIES" ] || ! jq -e '.version == 1 and (.wrappers | type == "object") and (.full_triggers | type == "array")' "$DEPENDENCIES" >/dev/null 2>&1; then
    fail "repo-lint exposes a versioned machine-readable wrapper dependency graph"
  else
    pass "repo-lint exposes a versioned machine-readable wrapper dependency graph"
  fi

  selected=$(scope_value checks pull_request scripts/ci/check_no_token_in_output)
  if jq -e 'index("check_no_token_in_output") != null and length == 1' <<<"$selected" >/dev/null 2>&1 \
     && [ "$(scope_value full pull_request scripts/ci/check_no_token_in_output)" = "false" ]; then
    pass "a direct wrapper change selects only that wrapper's expensive checks"
  else
    fail "a direct wrapper change must produce a partial affected-wrapper selection (got $selected)"
  fi

  selected=$(scope_value checks pull_request scripts/ci/token_output_gate.py)
  if jq -e 'index("check_no_token_in_output") != null' <<<"$selected" >/dev/null 2>&1; then
    pass "a declared dependency change selects its owning wrapper"
  else
    fail "declared dependencies must select their owning wrappers (got $selected)"
  fi

  # #1276: independent helper/test changes must reach the real blocked-evidence suite.
  for evidence_path in scripts/lib/codex-request-evidence.sh tests/test_codex_request_evidence.sh; do
    selected=$(scope_value checks pull_request "$evidence_path")
    if jq -e 'index("check_codex_scripts") != null' <<<"$selected" >/dev/null; then
      pass "$evidence_path selects the Codex wrapper"
    else
      fail "$evidence_path omitted the Codex wrapper (selected=$selected)"
    fi
  done

  selected=$(scope_value checks pull_request scripts/lib/ci-check-modes.sh)
  # DERIVED from the tree, not hardcoded. The assertion's intent is "every
  # wrapper that sources the helper is selected", and a fixed list of six
  # names asserted a snapshot of that instead: the seventh such wrapper
  # (#931's check_pr_review_policy_nudge) failed it while satisfying it.
  # The raw wrapper text is read, comments included, for the same reason as
  # the test-reference completeness check above (#2227): a wrapper that
  # names the helper only in prose counts as sourcing it, which can only
  # demand a graph entry, never hide one.
  quoted_hash_wrapper="$SCOPE_FIXTURES/quoted-hash-before-source.sh"
  printf '%s\n' "message='# is quoted data' && . \"\$ROOT/scripts/lib/ci-check-modes.sh\"" >"$quoted_hash_wrapper"
  quoted_hash_source=$(mode_helper_source_inventory_entry "$quoted_hash_wrapper" || true)
  if [ "$quoted_hash_source" = "quoted-hash-before-source.sh" ]; then
    pass "a quoted hash before a source command remains in the sourcing-wrapper inventory"
  else
    fail "quoted-hash-before-source.sh disappeared from the sourcing-wrapper inventory"
  fi

  sourcing=$(for f in "$ROOT"/scripts/ci/check_*; do
      # No pipeline, so a quiet grep cannot SIGPIPE a reader under this
      # suite's `set -o pipefail` (the earlier `sed | grep -q` form silently
      # dropped check_doc_ownership and check_merge_clearance_gate). `|| true`
      # because a non-matching wrapper is the common case and its exit 1
      # would abort the suite under `set -e`.
      mode_helper_source_inventory_entry "$f" || true
    done | sort | jq -R -s -c 'split("\n") | map(select(length > 0))')
  # A SUBSET check, matching the assertion's own words: every sourcing wrapper
  # must be selected. Equality would be wrong — the graph also declares this
  # dependency for wrappers that reach the helper indirectly rather than
  # sourcing it textually, and those are legitimately selected too.
  if jq -e --argjson sourcing "$sourcing" \
      '. as $sel | $sourcing | all(. as $w | $sel | index($w) != null)' \
      <<<"$selected" >/dev/null 2>&1; then
    pass "the shared mode selector selects every wrapper that sources it"
  else
    fail "ci-check-modes.sh must select every sourcing wrapper (sourcing $sourcing, selected $selected)"
  fi

  # #1832: every Cockpit file check_cockpit covers is a declared dependency of
  # that wrapper. The list is DERIVED from the tree, so a new Cockpit test or
  # spec cannot drift out of the graph. Cockpit is hub-only: a consumer has no
  # sync engine and no Cockpit files, so it has nothing to assert here.
  if [ -f "$ROOT/scripts/sync-to-downstream.sh" ]; then
    cockpit_paths=""
    for path in "$ROOT"/scripts/cockpit.sh "$ROOT"/tests/test_cockpit* "$ROOT"/specs/cockpit_*.md; do
      [ -f "$path" ] && cockpit_paths="${cockpit_paths}${path#"$ROOT"/}
"
    done
    cockpit_tree=$(cd "$ROOT" && find mergepath/cockpit -type f ! -path '*/__pycache__/*' | LC_ALL=C sort)
    cockpit_paths="${cockpit_paths}${cockpit_tree}"
    cockpit_patterns=$(jq -r '.wrappers.check_cockpit[]?' "$DEPENDENCIES")
    cockpit_undeclared=""
    cockpit_count=0
    while IFS= read -r path; do
      [ -n "$path" ] || continue
      cockpit_count=$((cockpit_count + 1))
      declared=0
      while IFS= read -r pattern; do
        [ -n "$pattern" ] || continue
        # shellcheck disable=SC2254 # graph entries are case globs by design
        case "$path" in $pattern) declared=1; break ;; esac
      done <<<"$cockpit_patterns"
      [ "$declared" -eq 1 ] || cockpit_undeclared="$cockpit_undeclared $path"
    done <<<"$cockpit_paths"
    if [ "$cockpit_count" -gt 0 ] && [ -z "$cockpit_undeclared" ]; then
      pass "every Cockpit file ($cockpit_count) is a declared check_cockpit dependency"
    else
      fail "Cockpit files missing from wrappers.check_cockpit (count $cockpit_count):$cockpit_undeclared"
    fi
    # specs/* is a full trigger on its own, so only the other Cockpit paths can
    # prove the partial selection: together they select check_cockpit alone.
    cockpit_partial=$(printf '%s\n' "$cockpit_paths" | grep -v '^specs/' || true)
    cockpit_scope=$(printf '%s\n' "$cockpit_partial" | bash "$SCOPE" --event pull_request)
    if [ "$(printf '%s\n' "$cockpit_scope" | sed -n 's/^full=//p')" = "false" ] \
       && [ "$(printf '%s\n' "$cockpit_scope" | sed -n 's/^checks=//p')" = '["check_cockpit"]' ]; then
      pass "Cockpit runtime and test changes select only check_cockpit"
    else
      fail "Cockpit runtime and test changes must select only check_cockpit (got $cockpit_scope)"
    fi
  fi

  # #931: the nudge wrapper owns two paths and nothing else does, so a change
  # to either selects it alone rather than the full deep net.
  selected=$(scope_value checks pull_request scripts/pr-review-policy-nudge.sh)
  full=$(scope_value full pull_request scripts/pr-review-policy-nudge.sh)
  if [ "$full" = "false" ] && [ "$selected" = '["check_pr_review_policy_nudge"]' ]; then
    pass "a change to the nudge selects only its own wrapper"
  else
    fail "nudge subject should select only its wrapper (full=$full, selected=$selected)"
  fi

  # The other side of that: a SHARED helper must NOT be narrowed by one
  # wrapper declaring it. scripts/lib/preflight-helpers.sh is sourced by
  # coderabbit-wait.sh and phase-4b-review.sh as well, so it stays undeclared
  # and keeps the fail-closed full deep net rather than selecting one caller.
  if [ "$(scope_value full pull_request scripts/lib/preflight-helpers.sh)" = "true" ]; then
    pass "scripts/lib/preflight-helpers.sh keeps the full deep net rather than a partial selection"
  else
    fail "scripts/lib/preflight-helpers.sh was narrowed to a partial selection; its other callers' deep suites would be skipped"
  fi

  # #2580: the shared top-level review scripts are declared under EVERY
  # wrapper whose suites name them (the completeness check above), so a
  # change to one selects those wrappers instead of the complete surface.
  hot_ok=1
  for hot in \
    'scripts/gh-as-author.sh check_gh_as_author check_codex_scripts' \
    'scripts/gh-as-reviewer.sh check_gh_as_author check_codex_scripts' \
    'scripts/codex-review-check.sh check_codex_scripts check_merge_clearance_gate' \
    'scripts/validate-pr-body.sh check_gh_as_author check_pr_review_policy_nudge'; do
    read -r hot_path hot_wrappers <<<"$hot"
    hot_full=$(scope_value full pull_request "$hot_path")
    hot_checks=$(scope_value checks pull_request "$hot_path")
    for hot_wrapper in $hot_wrappers; do
      if [ "$hot_full" != "false" ] || ! jq -e --arg w "$hot_wrapper" 'index($w) != null' <<<"$hot_checks" >/dev/null 2>&1; then
        hot_ok=0
        echo "INFO: $hot_path selected full=$hot_full checks=$hot_checks; expected $hot_wrapper" >&2
      fi
    done
  done
  if [ "$hot_ok" -eq 1 ]; then
    pass "the shared review scripts select the wrappers whose suites exercise them, not the complete surface"
  else
    fail "a shared review script fell back to the complete surface or lost a wrapper that exercises it (#2580)"
  fi

  auto_clear_dependencies_ok=1
  for path in \
    .github/workflows/agent-review.yml \
    scripts/lib/blocking-labels.sh \
    scripts/lib/gh-retry-helpers.sh \
    scripts/lib/review-policy-scalar.sh; do
    selected=$(scope_value checks pull_request "$path")
    if ! jq -e 'index("check_auto_clear_workflow") != null' <<<"$selected" >/dev/null 2>&1; then
      auto_clear_dependencies_ok=0
      echo "INFO: $path selected $selected" >&2
    fi
  done
  if [ "$auto_clear_dependencies_ok" -eq 1 ]; then
    pass "every shared auto-clear self-test input selects its deep wrapper"
  else
    fail "shared auto-clear self-test inputs must select check_auto_clear_workflow"
  fi

  # At least these two source it; since #2580 every other wrapper whose
  # suites name it is selected as well.
  selected=$(scope_value checks pull_request scripts/lib/gh-command-classifier.sh)
  if jq -e '
      (index("check_auto_clear_workflow") != null)
      and (index("check_self_approval_detector") != null)
    ' <<<"$selected" >/dev/null 2>&1; then
    pass "the command classifier selects every wrapper that sources it"
  else
    fail "gh-command-classifier.sh must select auto-clear and self-approval checks (got $selected)"
  fi

  selected=$(scope_value checks pull_request scripts/phase-4b-review.sh)
  if jq -e '
      index("check_phase_4b_automation") != null
      and index("check_phase_4b_accounting") != null
    ' <<<"$selected" >/dev/null 2>&1; then
    pass "Phase 4b orchestrator changes select automation and accounting regressions"
  else
    fail "phase-4b-review.sh must select both Phase 4b wrappers (got $selected)"
  fi

  parser_routing_ok=1
  for path in scripts/lib/pr-body-contract.mjs scripts/lib/pr-body-contract.sh \
      scripts/lib/pr-body-contract.source.mjs scripts/lib/pr-body-contract.bundle/rebuild.mjs; do
    selected=$(scope_value checks pull_request "$path")
    full=$(scope_value full pull_request "$path")
    if [ "$full" != "false" ] \
       || ! jq -e 'index("check_gh_as_author") != null and index("check_phase_4b_automation") != null' \
         <<<"$selected" >/dev/null 2>&1; then
      parser_routing_ok=0
      echo "INFO: $path full=$full selected=$selected" >&2
    fi
  done
  if [ "$parser_routing_ok" -eq 1 ]; then
    pass "shared PR-body parser implementation selects parity and Phase 4b behavioral coverage"
  else
    fail "every shared PR-body parser implementation input must select parity and Phase 4b automation coverage"
  fi

  selected=$(scope_value checks pull_request tests/test_required_check_publisher_summary_hold.sh)
  full=$(scope_value full pull_request tests/test_required_check_publisher_summary_hold.sh)
  if [ "$full" = "false" ] && [ "$selected" = '["check_required_check_publisher"]' ]; then
    pass "publisher summary-hold suite selects only its publisher self-test"
  else
    fail "publisher summary-hold suite must avoid full deep fallback (full=$full, selected=$selected)"
  fi

  if [ "$(scope_value full pull_request scripts/ci/repo-lint-scope.sh)" = "true" ] \
     && [ "$(scope_value checks pull_request scripts/ci/repo-lint-scope.sh)" = '[]' ]; then
    pass "classifier and graph changes fail closed to the full deep surface"
  else
    fail "scope infrastructure changes must select the full deep surface"
  fi

  jq_stub_dir=$(mktemp -d "${TMPDIR:-/tmp}/repo-lint-jq.XXXXXX")
  jq_real=$(command -v jq)
  cat > "$jq_stub_dir/jq" <<'STUB'
#!/usr/bin/env bash
count=$(cat "$JQ_STUB_COUNT")
count=$((count + 1))
echo "$count" > "$JQ_STUB_COUNT"
if [ "$count" -eq 2 ]; then exit 7; fi
exec "$JQ_REAL" "$@"
STUB
  chmod +x "$jq_stub_dir/jq"
  echo 0 > "$jq_stub_dir/count"
  parse_failure=$(printf '%s\n' docs/README.md | PATH="$jq_stub_dir:$PATH" JQ_REAL="$jq_real" JQ_STUB_COUNT="$jq_stub_dir/count" bash "$SCOPE" --event pull_request 2>/dev/null)
  rm -rf "$jq_stub_dir"
  if grep -Fxq 'deep=true' <<<"$parse_failure" \
     && grep -Fxq 'full=true' <<<"$parse_failure" \
     && grep -Fxq 'checks=[]' <<<"$parse_failure" \
     && grep -Fxq 'consumer_replay=true' <<<"$parse_failure" \
     && grep -Fxq 'self_tests=true' <<<"$parse_failure"; then
    pass "dependency graph parse failures fail closed to the full deep surface, replay and self-test legs included"
  else
    fail "a later jq failure must not continue with incomplete wrapper patterns (got $parse_failure)"
  fi

  malformed_root=$(mktemp -d "${TMPDIR:-/tmp}/repo-lint-malformed.XXXXXX")
  mkdir -p "$malformed_root/scripts/ci"
  cp "$SCOPE" "$malformed_root/scripts/ci/repo-lint-scope.sh"
  cat > "$malformed_root/scripts/ci/repo-lint-dependencies.json" <<'JSON'
{"version":1,"full_triggers":[".github/**",null],"wrappers":{"check_example":["scripts/example.sh",7]}}
JSON
  malformed_members=$(printf '%s\n' docs/README.md | bash "$malformed_root/scripts/ci/repo-lint-scope.sh" --event pull_request 2>/dev/null)
  rm -rf "$malformed_root"
  if grep -Fxq 'deep=true' <<<"$malformed_members" \
     && grep -Fxq 'full=true' <<<"$malformed_members" \
     && grep -Fxq 'checks=[]' <<<"$malformed_members"; then
    pass "non-string dependency graph members fail closed to the full deep surface"
  else
    fail "dependency graph arrays must contain only strings (got $malformed_members)"
  fi

  invalid_name_root=$(mktemp -d "${TMPDIR:-/tmp}/repo-lint-invalid-name.XXXXXX")
  mkdir -p "$invalid_name_root/scripts/ci"
  cp "$SCOPE" "$invalid_name_root/scripts/ci/repo-lint-scope.sh"
  cat > "$invalid_name_root/scripts/ci/repo-lint-dependencies.json" <<'JSON'
{"version":1,"full_triggers":[".github/**"],"wrappers":{"lint_wrapper":["scripts/example.sh"]}}
JSON
  invalid_name=$(printf '%s\n' scripts/example.sh | bash "$invalid_name_root/scripts/ci/repo-lint-scope.sh" --event pull_request 2>/dev/null)
  rm -rf "$invalid_name_root"
  if grep -Fxq 'deep=true' <<<"$invalid_name" \
     && grep -Fxq 'full=true' <<<"$invalid_name" \
     && grep -Fxq 'checks=[]' <<<"$invalid_name"; then
    pass "invalid wrapper names fail closed before reaching the shared selector"
  else
    fail "dependency graph wrapper keys must match the selector contract (got $invalid_name)"
  fi

  # -------------------------------------------------------------------------
  # Consumer mode: neither hub marker present.
  # -------------------------------------------------------------------------

  # A consumer's own product files (specs, app tests, .mjs scripts, its
  # repository-overview doc, app source) cannot change any deep-lane result
  # there, so they stay on the fast lane. This set is the shape of the
  # fiveacross feature PRs that ran the full deep net before consumer mode.
  consumer_local_ok=1
  for path in \
    specs/admin-console-ia.md \
    docs/agents/repository-overview.md \
    rules/firestore-notes.md \
    AGENTS.md \
    tests/rules/w0-storage-rules.test.ts \
    tests/functions/proof-media.test.ts \
    tests/e2e/admin.spec.ts \
    scripts/bug-reports.mjs \
    scripts/og/render.mjs \
    src/admin/AdminConsole.tsx; do
    if [ "$(consumer_scope_value deep pull_request "$path")" != "false" ]; then
      consumer_local_ok=0
      echo "INFO: consumer $path deep=$(consumer_scope_value deep pull_request "$path")" >&2
    fi
  done
  if [ "$consumer_local_ok" -eq 1 ]; then
    pass "consumer mode keeps consumer-local specs, docs, app tests and app scripts on the fast lane"
  else
    fail "consumer-local product files must not request deep CI on a consumer"
  fi

  # Kit-shaped CI implementation still fails closed on a consumer: a delivered
  # file could be edited there, and a consumer-local shell script or workflow
  # is indistinguishable from one by shape. Declared dependencies (the hook,
  # Phase 4b, the self-approval detector) select their wrappers as on the hub.
  consumer_ci_ok=1
  for path in \
    .github/workflows/app-ci.yml \
    .github/workflows/repo_lint.yml \
    scripts/ci/repo-lint-scope.sh \
    scripts/lib/preflight-helpers.sh \
    scripts/workflow/example.sh \
    scripts/hooks/gh-pr-guard.sh \
    scripts/phase-4b/example.sh \
    scripts/gh-projects/example.sh \
    scripts/deploy.sh \
    scripts/self-approval-detector.cjs \
    tests/test_example.sh \
    tests/fixtures/example.json; do
    if [ "$(consumer_scope_value deep pull_request "$path")" != "true" ]; then
      consumer_ci_ok=0
      echo "INFO: consumer $path deep=$(consumer_scope_value deep pull_request "$path")" >&2
    fi
  done
  if [ "$consumer_ci_ok" -eq 1 ]; then
    pass "consumer mode still sends kit-shaped CI paths to deep CI (declared dependencies partially, the rest in full)"
  else
    fail "kit-shaped CI paths must fail closed to deep CI on a consumer"
  fi
  if [ "$(consumer_scope_value full pull_request scripts/emulator.sh)" = "true" ] \
     && [ "$(consumer_scope_value full pull_request .github/workflows/app-ci.yml)" = "true" ]; then
    pass "unmapped kit-shaped paths on a consumer take the full deep surface"
  else
    fail "an unmapped kit-shaped consumer path must fail closed to the full deep surface"
  fi

  selected=$(consumer_scope_value checks pull_request tests/test_coderabbit_wait_paused.sh)
  if [ "$(consumer_scope_value full pull_request tests/test_coderabbit_wait_paused.sh)" = "false" ] \
     && [ "$selected" = '["check_coderabbit_wait"]' ] \
     && [ "$(consumer_scope_value checks pull_request scripts/ci/check_no_token_in_output)" = '["check_no_token_in_output"]' ]; then
    pass "consumer mode keeps declared-dependency and direct-wrapper partial selection"
  else
    fail "consumer mode must select wrappers exactly as the hub does (got $selected)"
  fi

  if [ "$(consumer_scope_value full push docs/README.md)" = "true" ] \
     && [ "$(consumer_scope_value full schedule specs/example.md)" = "true" ]; then
    pass "consumer mode keeps non-PR events on the full regression surface"
  else
    fail "non-PR events must stay full on a consumer"
  fi

  # Either hub marker alone keeps hub rules, so losing one on the hub (or a
  # consumer carrying one as bootstrap residue) can only make CI stricter.
  for marker in scripts/sync-to-downstream.sh .mergepath-sync.yml; do
    one_marker_root="$SCOPE_FIXTURES/one-marker"
    rm -rf "$one_marker_root"
    mkdir -p "$one_marker_root/scripts/ci"
    cp "$SCOPE" "$DEPENDENCIES" "$one_marker_root/scripts/ci/"
    touch "$one_marker_root/$marker"
    one_marker=$(printf '%s\n' specs/example.md scripts/unknown-helper.sh | bash "$one_marker_root/scripts/ci/repo-lint-scope.sh" --event pull_request)
    # specs/ is a governance document (deep on the hub, fast on a consumer)
    # and the unknown helper is the hub catch-all; together they must reach
    # the full surface INCLUDING the hub-only replay, which consumer mode
    # withholds.
    if grep -Fxq 'deep=true' <<<"$one_marker" \
       && grep -Fxq 'full=true' <<<"$one_marker" \
       && grep -Fxq 'consumer_replay=true' <<<"$one_marker"; then
      pass "a checkout carrying only $marker keeps the hub rules"
    else
      fail "a checkout carrying only $marker must keep the hub rules (got $one_marker)"
    fi
  done

  # Consumer mode never selects the consumer replay: the harness is hub-only
  # (marker-first SKIP), so the replay legs would spin up for nothing. The
  # full surface there is the kit's self-tests.
  consumer_full=$(printf '%s\n' scripts/ci/repo-lint-scope.sh | bash "$CONSUMER_SCOPE_ROOT/scripts/ci/repo-lint-scope.sh" --event pull_request | LC_ALL=C sort | tr '\n' ' ')
  if [ "$consumer_full" = "checks=[] consumer_replay=false deep=true full=true self_tests=true " ]; then
    pass "consumer mode keeps the full surface but never selects the hub-only consumer replay"
  else
    fail "consumer mode must emit consumer_replay=false even for a full selection (got $consumer_full)"
  fi

  # Completeness, hub only (it needs the manifest): every path the manifest
  # delivers to consumers that the hub would send to deep CI is still deep in
  # consumer mode, unless it is one of the governance documents whose only
  # deep readers are the hub-only harnesses. A new delivered path in a shape
  # consumer_ci_surface does not cover fails here instead of silently taking
  # the consumer fast lane.
  consumer_doc_only_path() {
    case "$1" in
      specs/*|rules/*|docs/agents/*|docs/architecture/*|AGENTS.md|REVIEW_POLICY.md|ai_agent_tooling_standard.md|.repo-template.yml) return 0 ;;
    esac
    return 1
  }
  if [ -f "$ROOT/.mergepath-sync.yml" ] && command -v yq >/dev/null 2>&1; then
    delivered=$(yq -r '.paths[] | (.dest // .path)' "$ROOT/.mergepath-sync.yml")
    delivered_count=0
    weaker=""
    while IFS= read -r path; do
      [ -n "$path" ] || continue
      case "$path" in
        */) path="${path}repo-lint-scope-probe" ;;
      esac
      delivered_count=$((delivered_count + 1))
      [ "$(scope_value deep pull_request "$path")" = "true" ] || continue
      consumer_doc_only_path "$path" && continue
      if [ "$(consumer_scope_value deep pull_request "$path")" != "true" ]; then
        weaker="$weaker $path"
      fi
    done <<<"$delivered"
    if [ "$delivered_count" -gt 0 ] && [ -z "$weaker" ]; then
      pass "every manifest-delivered path ($delivered_count) the hub sends to deep CI is still deep in consumer mode"
    else
      fail "consumer mode takes the fast lane for delivered CI paths the hub runs deep (extend consumer_ci_surface):$weaker"
    fi
  fi
fi

if ! command -v yq >/dev/null 2>&1; then
  fail "mikefarah/yq is available for parsed workflow assertions"
else
  workflows=("$REPO_LINT")
  if [ -f "$MD_WRAP" ]; then
    workflows+=("$MD_WRAP")
  fi
  if [ -f "$OWL" ]; then
    workflows+=("$OWL")
  fi
  for workflow in "${workflows[@]}"; do
    label="${workflow##*/}"
    if yq -e '(.on | has("pull_request")) and (.on.push.branches | length == 1) and (.on.push.branches[0] == "main")' "$workflow" >/dev/null; then
      pass "$label runs PR heads once and limits push validation to main"
    else
      fail "$label must use pull_request plus push.branches=[main]"
    fi
    if yq -e '.concurrency.group == "${{ github.workflow }}-${{ github.event.pull_request.number || github.ref }}" and .concurrency.cancel-in-progress == "${{ github.event_name == '\''pull_request'\'' }}"' "$workflow" >/dev/null; then
      pass "$label cancels superseded PR heads without cancelling main"
    else
      fail "$label must declare PR-scoped concurrency cancellation"
    fi
  done

  if yq -e '.on.schedule[0].cron == "17 7 * * *" and .on.workflow_dispatch == null' "$REPO_LINT" >/dev/null; then
    pass "repo-lint retains a scheduled and manual full-regression backstop"
  else
    fail "repo-lint must expose the daily deep-CI schedule and manual trigger"
  fi

  if yq -e '.jobs.scope.outputs.deep == "${{ steps.classify.outputs.deep }}" and .jobs.scope.outputs.full == "${{ steps.classify.outputs.full }}" and .jobs.scope.outputs.checks == "${{ steps.classify.outputs.checks }}" and .jobs.scope.outputs.consumer_replay == "${{ steps.classify.outputs.consumer_replay }}" and .jobs.scope.outputs.self_tests == "${{ steps.classify.outputs.self_tests }}" and (.jobs.scope.steps[] | select(.id == "classify") | .run | contains("repo-lint-scope.sh")) and (.jobs.scope.steps[] | select(.id == "classify") | .run | contains("--head-ref \"$HEAD_REF\"")) and (.jobs.scope.steps[] | select(.id == "classify") | .env.HEAD_REF == "${{ github.head_ref }}")' "$REPO_LINT" >/dev/null; then
    pass "repo-lint publishes one parsed affected-wrapper scope decision with the replay and self-test bits and the head ref"
  else
    fail "repo-lint must classify and publish deep/full/checks/consumer_replay/self_tests once, passing the PR head ref"
  fi

  # The kit-less consumer branch and the diff-unavailable branch write the
  # outputs by hand; both must name every key the jobs below read, or an
  # empty string reaches a job `if` and the aggregator table.
  classify_run=$(yq -r '.jobs.scope.steps[] | select(.id == "classify") | .run' "$REPO_LINT")
  if [ "$(grep -c 'echo "consumer_replay=' <<<"$classify_run")" = "2" ] \
     && [ "$(grep -c 'echo "self_tests=' <<<"$classify_run")" = "2" ] \
     && grep -Fq 'echo "consumer_replay=false"' <<<"$classify_run" \
     && grep -Fq 'echo "consumer_replay=true"' <<<"$classify_run" \
     && grep -Fq 'echo "self_tests=false"' <<<"$classify_run" \
     && grep -Fq 'echo "self_tests=true"' <<<"$classify_run"; then
    pass "both hand-written scope fallbacks emit the replay and self-test keys (kit-less false, diff-unavailable true)"
  else
    fail "the scope step's kit-less and diff-unavailable fallbacks must emit consumer_replay and self_tests"
  fi

  if yq -e '.jobs.deep_safety.needs == "scope" and .jobs.deep_safety.if == "needs.scope.outputs.deep == '\''true'\''" and (.jobs.deep_safety.strategy.matrix.safety | contains(["consumer", "residue"]))' "$REPO_LINT" >/dev/null; then
    pass "one matrix declaration runs the two exhaustive safety nets in parallel only for deep CI"
  else
    fail "consumer and residue safety must be isolated matrix legs selected only by deep CI"
  fi

  aggregator_run=$(yq -r '.jobs.lint.steps[] | select(.name == "publish aggregate lint result") | .run' "$REPO_LINT")
  if yq -e '.jobs.lint.name == "lint" and .jobs.lint.if == "always()" and (.jobs.lint.needs | contains(["scope", "lint_fast", "deep_safety"]))' "$REPO_LINT" >/dev/null \
     && printf '%s' "$aggregator_run" | grep -F 'FAST_RESULT' >/dev/null \
     && printf '%s' "$aggregator_run" | grep -F 'DEEP_RESULT' >/dev/null \
     && printf '%s' "$aggregator_run" | grep -F 'SCOPE_RESULT' >/dev/null \
     && printf '%s' "$aggregator_run" | grep -F 'exit 1' >/dev/null; then
    pass "a stable lint aggregator preserves the required status context"
  else
    fail "repo-lint must retain one always-running lint aggregator over every lane"
  fi

  if yq -e '(.jobs.lint_fast.steps[] | select(.name == "check_no_token_in_output") | .run | contains("--scan")) and (.jobs.lint_fast.steps[] | select(.name == "check_doc_ownership") | .run | contains("--check"))' "$REPO_LINT" >/dev/null; then
    pass "the fast lane runs live token and ownership assertions without their self-tests"
  else
    fail "the fast lane must use token --scan and doc-ownership --check modes"
  fi

  if yq -e '(.jobs.deep_self_tests.steps[] | select(.name == "check_no_token_in_output --self-test") | .run | contains("--self-test")) and (.jobs.deep_self_tests.steps[] | select(.name == "check_doc_ownership --self-test") | .run | contains("--self-test"))' "$REPO_LINT" >/dev/null; then
    pass "deep CI retains the full token and ownership regression suites"
  else
    fail "deep CI must run token and doc-ownership self-tests"
  fi

  governance_modes_ok=1
  for name in check_auto_clear_workflow check_coderabbit_wait check_merge_clearance_gate check_required_check_publisher check_phase_4b_automation check_phase_4b_accounting check_gh_projects_move_item; do
    name="$name" yq -e '([.jobs.lint_fast.steps[] | select(.name == strenv(name)) | .run | contains("--check")] | any) and ([.jobs.deep_self_tests.steps[] | select(.name == (strenv(name) + " --self-test")) | select((.if | contains("needs.scope.outputs.full")) and (.if | contains("needs.scope.outputs.checks")) and (.if | contains("matrix.suite == "))) | .run | contains("--self-test")] | any)' "$REPO_LINT" >/dev/null || governance_modes_ok=0
  done
  if [ "$governance_modes_ok" -eq 1 ]; then
    pass "auto-clear and governance wrappers keep live structure fast and move regression suites to deep CI"
  else
    fail "auto-clear, CodeRabbit, merge-clearance, and Phase 4b wrappers must split live and self-test modes"
  fi

  # #1655 sharding. Every --self-test step is pinned to exactly one suite leg
  # (a step without a matrix.suite guard would run on every leg; a step
  # naming two legs would run twice), and the slowest suites sit on
  # different legs so the critical path is one suite, not their sum.
  suite_pins=$(yq -r '.jobs.deep_self_tests.steps[] | select(.name | test(" --self-test$")) | .if' "$REPO_LINT")
  suite_pin_ok=1
  while IFS= read -r cond; do
    [ -n "$cond" ] || continue
    # `|| true`: an unpinned step yields zero matches, which fails the
    # pipeline under this suite's `set -e -o pipefail` and would abort the
    # suite inside the assignment instead of reporting the finding.
    pins=$(grep -o "matrix.suite == '[a-z0-9-]*'" <<<"$cond" | wc -l | tr -d ' ' || true)
    if [ "${pins:-0}" != "1" ]; then
      suite_pin_ok=0
      echo "INFO: self-test step pinned to $pins legs: $cond" >&2
    fi
  done <<<"$suite_pins"
  automation_leg=$(yq -r '.jobs.deep_self_tests.steps[] | select(.name == "check_phase_4b_automation --self-test") | .if' "$REPO_LINT" | grep -o "matrix.suite == '[a-z0-9-]*'")
  coderabbit_leg=$(yq -r '.jobs.deep_self_tests.steps[] | select(.name == "check_coderabbit_wait --self-test") | .if' "$REPO_LINT" | grep -o "matrix.suite == '[a-z0-9-]*'")
  if [ "$suite_pin_ok" -eq 1 ] && [ -n "$automation_leg" ] && [ -n "$coderabbit_leg" ] && [ "$automation_leg" != "$coderabbit_leg" ] \
     && yq -e '.jobs.deep_self_tests.needs == "scope" and .jobs.deep_self_tests.if == "needs.scope.outputs.deep == '\''true'\'' && needs.scope.outputs.self_tests == '\''true'\''" and (.jobs.deep_self_tests.strategy.matrix.suite | length >= 2) and .jobs.deep_self_tests.strategy."fail-fast" == false and (.jobs.deep_self_tests.name | contains("deep-safety ("))' "$REPO_LINT" >/dev/null; then
    pass "self-test suites are sharded over legs that run only when a selected wrapper is enrolled, with the two slowest suites apart"
  else
    fail "deep_self_tests must pin every suite to one matrix leg, gate on scope self_tests, and keep Phase 4b automation and CodeRabbit wait on different legs"
  fi

  if yq -e '.jobs.deep_consumer_replay.needs == "scope" and .jobs.deep_consumer_replay.if == "needs.scope.outputs.deep == '\''true'\'' && needs.scope.outputs.consumer_replay == '\''true'\''" and (.jobs.deep_consumer_replay.strategy.matrix.shard | length == 3) and .jobs.deep_consumer_replay.strategy."fail-fast" == false and .jobs.deep_consumer_replay.env.REPO_LINT_FULL == "true" and .jobs.deep_consumer_replay.env.REPO_LINT_SHARD == "${{ matrix.shard }}/3" and (.jobs.deep_consumer_replay.name | contains("deep-safety (")) and ([.jobs.deep_consumer_replay.steps[] | select(.name == "check_repo_lint_consumer_safety")] | length == 1)' "$REPO_LINT" >/dev/null; then
    pass "the complete consumer replay runs as three independent shards only when the scope selects it"
  else
    fail "deep_consumer_replay must gate on scope consumer_replay, run REPO_LINT_FULL=true over a 3-way REPO_LINT_SHARD matrix, and keep the deep-safety name prefix"
  fi

  if yq -e '([.jobs.deep_safety.steps[] | select(.name == "check_repo_lint_consumer_safety") | select(.env.REPO_LINT_FULL == "false") | select(.if == "matrix.safety == '\''consumer'\''")] | length == 1) and ([.jobs.deep_safety.steps[] | select(.name | test(" --self-test$"))] | length == 0)' "$REPO_LINT" >/dev/null; then
    pass "the deep-safety consumer leg runs the harness in smoke mode and carries no self-test steps"
  else
    fail "deep_safety must pin the consumer leg to REPO_LINT_FULL=false (the complete replay is the sharded job) and host no --self-test step"
  fi

  # Aggregator semantics, executed rather than grepped: the run: body is
  # extracted and driven under the Actions default shell with every
  # (scope decision, job result) combination that must pass or fail. A
  # skipped job satisfies branch protection by itself, so this table is the
  # only thing that makes an unexpectedly skipped, cancelled or failed leg
  # red the required `lint` context.
  aggregate() {  # DEEP REPLAY SELF SCOPE FAST DEEP_RESULT REPLAY_RESULT SELF_RESULT
    DEEP="$1" CONSUMER_REPLAY="$2" SELF_TESTS="$3" SCOPE_RESULT="$4" FAST_RESULT="$5" \
      DEEP_RESULT="$6" REPLAY_RESULT="$7" SELF_TESTS_RESULT="$8" \
      bash --noprofile --norc -e -o pipefail -c "$aggregator_run" >/dev/null 2>&1
  }
  aggregator_ok=1
  aggregate false false false success success skipped skipped skipped || aggregator_ok=0
  aggregate true false false success success success skipped skipped || aggregator_ok=0
  aggregate true true true success success success success success || aggregator_ok=0
  aggregate true false true success success success skipped success || aggregator_ok=0
  for bad in \
    "false false false success failure skipped skipped skipped" \
    "false false false failure success skipped skipped skipped" \
    "false false false success success success skipped skipped" \
    "true false false success success failure skipped skipped" \
    "true false false success success cancelled skipped skipped" \
    "true false false success success skipped skipped skipped" \
    "true true true success success success skipped success" \
    "true true true success success success failure success" \
    "true true true success success success cancelled success" \
    "true true true success success success success skipped" \
    "true true true success success success success failure" \
    "true false false success success success success skipped" \
    "true false false success success success skipped success"; do
    # shellcheck disable=SC2086 # the row is a deliberate word list
    if aggregate $bad; then
      aggregator_ok=0
      echo "INFO: aggregator accepted: $bad" >&2
    fi
  done
  if [ "$aggregator_ok" -eq 1 ] \
     && yq -e '(.jobs.lint.needs | join(",")) == "scope,lint_fast,deep_safety,deep_consumer_replay,deep_self_tests" and .jobs.lint.steps[0].env.REPLAY_RESULT == "${{ needs.deep_consumer_replay.result }}" and .jobs.lint.steps[0].env.SELF_TESTS_RESULT == "${{ needs.deep_self_tests.result }}" and .jobs.lint.steps[0].env.CONSUMER_REPLAY == "${{ needs.scope.outputs.consumer_replay }}" and .jobs.lint.steps[0].env.SELF_TESTS == "${{ needs.scope.outputs.self_tests }}"' "$REPO_LINT" >/dev/null; then
    pass "the lint aggregator reads every deep job against the scope decision: selected legs must succeed, unselected legs must skip"
  else
    fail "the lint aggregator must fail on a failed, cancelled or unexpectedly skipped deep leg and pass only on the selected set"
  fi

  # -------------------------------------------------------------------------
  # #2163: the fast lane is a shard matrix. Every check step is pinned to one
  # shard; the prelude is not. Two silent failure shapes are closed here: a
  # pin naming a shard outside the matrix never runs anywhere (the check is
  # switched off while `lint` stays green), and an unpinned check runs on
  # every leg (minutes wasted, and a false reading of the balance).
  # -------------------------------------------------------------------------
  shard_members=$(yq -r '.jobs.lint_fast.strategy.matrix.shard[]?' "$REPO_LINT")
  shard_count=$(printf '%s\n' "$shard_members" | sed '/^$/d' | wc -l | tr -d ' ')
  if [ "$shard_count" -ge 2 ] && [ "$shard_count" -le 4 ] \
     && printf '%s\n' "$shard_members" | sed '/^$/d' | grep -Ex '[0-9]+' >/dev/null \
     && ! printf '%s\n' "$shard_members" | sed '/^$/d' | grep -Ev '^[0-9]+$' >/dev/null \
     && yq -e '.jobs.lint_fast.strategy."fail-fast" == false and .jobs.lint_fast.if == null and .jobs.lint_fast.name == "lint-fast" and (.jobs.lint_fast."timeout-minutes" | tag == "!!int")' "$REPO_LINT" >/dev/null; then
    pass "lint-fast is a 2-4 shard matrix that reports every leg, is never skipped, and is time-bounded"
  else
    fail "lint-fast must declare a 2-4 integer shard matrix with fail-fast: false, no job-level if:, and a timeout (got shards: $(printf '%s' "$shard_members" | tr '\n' ' '))"
  fi

  pins_ok=1
  pinned_steps=0
  unpinned_steps=""
  bad_pins=""
  hygiene_full_shard=""
  hygiene_verify_shard=""
  while IFS=$'\t' read -r step_name step_if; do
    [ -n "$step_name" ] || continue
    case "$step_name" in
      "check_git_identity_hygiene --snapshot")
        # Unpinned by design: every leg records its own baseline.
        if [ -n "$step_if" ]; then
          pins_ok=0
          bad_pins="$bad_pins ${step_name}(pinned)"
        fi
        continue
        ;;
    esac
    if [ -z "$step_if" ]; then
      pins_ok=0
      unpinned_steps="$unpinned_steps $step_name"
      continue
    fi
    if ! printf '%s' "$step_if" | grep -E '^matrix\.shard (==|!=) [0-9]+$' >/dev/null; then
      pins_ok=0
      bad_pins="$bad_pins ${step_name}(${step_if})"
      continue
    fi
    pin_value="${step_if##* }"
    if ! printf '%s\n' "$shard_members" | grep -Fx "$pin_value" >/dev/null; then
      pins_ok=0
      bad_pins="$bad_pins ${step_name}(shard $pin_value is not in the matrix)"
      continue
    fi
    case "$step_name" in
      check_git_identity_hygiene)
        case "$step_if" in *"== "*) hygiene_full_shard="$pin_value" ;; esac ;;
      "check_git_identity_hygiene --verify")
        case "$step_if" in *"!= "*) hygiene_verify_shard="$pin_value" ;; esac ;;
      *)
        # Every other check is pinned to exactly one leg: `!=` would run it
        # on all but one, which is the duplication the matrix exists to end.
        case "$step_if" in
          *"!= "*) pins_ok=0; bad_pins="$bad_pins ${step_name}(!= pins run on every other leg)" ;;
        esac ;;
    esac
    pinned_steps=$((pinned_steps + 1))
  done < <(yq -r '.jobs.lint_fast.steps[] | select(.name | test("^check_")) | [.name, (.if // "")] | @tsv' "$REPO_LINT")
  if [ "$pins_ok" -eq 1 ] && [ "$pinned_steps" -ge 60 ]; then
    pass "every lint-fast check step ($pinned_steps) is pinned to one shard that exists in the matrix"
  else
    fail "lint-fast shard pins are broken (unpinned:$unpinned_steps) (bad:$bad_pins) (pinned=$pinned_steps)"
  fi

  shard_coverage_ok=1
  for member in $shard_members; do
    member="$member" yq -e '[.jobs.lint_fast.steps[] | select(.if == ("matrix.shard == " + strenv(member)))] | length > 0' "$REPO_LINT" >/dev/null 2>&1 || shard_coverage_ok=0
  done
  if [ "$shard_coverage_ok" -eq 1 ]; then
    pass "every declared shard carries at least one pinned check"
  else
    fail "a declared shard carries no pinned check (a leg that does nothing but setup)"
  fi

  # The #777 closing pair: the plain call (Parts A-C + suite) on one shard and
  # `--verify` (Parts A and B against this leg's own snapshot) on every other,
  # pinned to the SAME number so exactly one of them closes every leg, and
  # both as the job's final two steps so no suite runs after them.
  last_two=$(yq -r '.jobs.lint_fast.steps[-2:] | map(.name) | join("|")' "$REPO_LINT")
  if [ -n "$hygiene_full_shard" ] && [ "$hygiene_full_shard" = "$hygiene_verify_shard" ] \
     && [ "$last_two" = "check_git_identity_hygiene|check_git_identity_hygiene --verify" ] \
     && yq -e '.jobs.lint_fast.steps[] | select(.name == "check_git_identity_hygiene --verify") | .run | test("check_git_identity_hygiene --verify")' "$REPO_LINT" >/dev/null \
     && yq -e '.jobs.lint_fast.steps[] | select(.name == "check_git_identity_hygiene --snapshot") | .if == null' "$REPO_LINT" >/dev/null; then
    pass "every shard snapshots .git/config first and closes with the full hygiene check or --verify (full on shard $hygiene_full_shard)"
  else
    fail "the identity-hygiene closing pair must be the last two lint-fast steps, pinned == and != to one shard (full=$hygiene_full_shard verify=$hygiene_verify_shard last=$last_two)"
  fi

  # Lint-fast shard rows for the aggregator oracle above (#2163). They reuse
  # its `aggregate` (DEEP REPLAY SELF SCOPE FAST DEEP_RESULT REPLAY_RESULT
  # SELF_RESULT) rather than defining a second one, so there is one driver
  # for the published step body. FAST_RESULT is the matrix job's ROLLED-UP
  # result: one failed or cancelled shard makes it non-success, and skipped
  # can only mean the job never ran. Each shape is paired with its passing
  # control, so a negative row cannot pass because the shape itself is bad.
  fast_shard_ok=1
  aggregate false false false success success skipped skipped skipped || fast_shard_ok=0
  aggregate true true true success success success success success || fast_shard_ok=0
  aggregate true false false success success success skipped skipped || fast_shard_ok=0
  for fast in failure cancelled skipped; do
    aggregate false false false success "$fast" skipped skipped skipped && fast_shard_ok=0
    aggregate true true true success "$fast" success success success && fast_shard_ok=0
    aggregate true false false success "$fast" success skipped skipped && fast_shard_ok=0
  done
  if [ "$fast_shard_ok" -eq 1 ] \
     && yq -e '(.jobs.lint.steps[] | select(.name == "publish aggregate lint result") | .env.FAST_RESULT) == "${{ needs.lint_fast.result }}"' "$REPO_LINT" >/dev/null; then
    pass "a failed, cancelled or skipped lint-fast shard fails the aggregator on fast and deep heads, which reads needs.lint_fast.result"
  else
    fail "the aggregator must fail on any non-success lint-fast result (failure, cancelled, skipped) on every scope shape and read needs.lint_fast.result"
  fi

  agent_review_probe=$(yq -r '.jobs."auto-merge-on-approval".steps[] | select(.name == "Probe current-head check readiness once") | .run' "$AGENT_REVIEW")
  if ! grep -Fq 'for readiness_probe in 1; do' <<<"$agent_review_probe" \
     && grep -Fq 'ready=false' <<<"$agent_review_probe" \
     && ! grep -Fq 'sleep ' <<<"$agent_review_probe"; then
    pass "agent-review probes check readiness once without reserving a runner"
  else
    fail "agent-review must record pending readiness and exit without polling"
  fi

  agent_auto_merge=$(yq -r '.jobs."auto-merge-on-approval"' "$AGENT_REVIEW")
  if ! grep -Fq 'coderabbit-wait.sh' <<<"$agent_auto_merge" \
     && ! grep -Fq 'Wait for CodeRabbit review' <<<"$agent_auto_merge"; then
    pass "registered approval does not wait for advisory CodeRabbit arrival"
  else
    fail "CodeRabbit must not be an additional runner-held requirement after approval"
  fi

  wait_step_index=$(yq -r '.jobs."auto-merge-on-approval".steps | to_entries[] | select(.value.name == "Probe current-head check readiness once") | .key' "$AGENT_REVIEW")
  readiness_step_index=$(yq -r '.jobs."auto-merge-on-approval".steps | to_entries[] | select(.value.name == "Report stable read-only readiness") | .key' "$AGENT_REVIEW")
  readiness_step=$(yq -r '.jobs."auto-merge-on-approval".steps[] | select(.name == "Report stable read-only readiness") | .run' "$AGENT_REVIEW")
  readiness_permissions=$(yq -r '.jobs."auto-merge-on-approval".permissions | to_entries | sort_by(.key) | .[] | "\(.key): \(.value)"' "$AGENT_REVIEW")
  expected_readiness_permissions=$'actions: read\nchecks: read\ncontents: read\nissues: read\npull-requests: read\nstatuses: read'
  agent_auto_merge_flat=$(tr '\n' ' ' <<<"$agent_auto_merge")
  candidate_workflow_root_env() {
    yq -r '.env // {}' "$1"
  }
  candidate_job_uses_secrets_context() {
    grep -Eiq '(^|[^[:alnum:]_])secrets([^[:alnum:]_]|$)' <<<"$1"
  }
  candidate_job_uses_privileged_credential() {
    grep -Eiq 'AUTHOR_MERGE_TOKEN|MERGE_QUEUE_POLICY_TOKEN|MERGE_QUEUE_SOURCE_TOKEN' <<<"$1"
  }
  candidate_readiness_uses_privileged_credential() {
    candidate_job_uses_privileged_credential "$1" || candidate_job_uses_privileged_credential "$2"
  }
  candidate_readiness_uses_secrets_context() {
    candidate_job_uses_secrets_context "$1" || candidate_job_uses_secrets_context "$2"
  }
  candidate_job_inherits_secrets() {
    grep -Eq '^[[:space:]]*secrets:[[:space:]]*inherit([[:space:]]|$)' <<<"$1"
  }
  workflow_root_env=$(candidate_workflow_root_env "$AGENT_REVIEW")
  inherited_env_fixture=$(
    candidate_workflow_root_env - <<'YAML'
name: inherited-secret-fixture
env:
  INHERITED: ${{ SeCrEtS ["REVIEWER_ASSIGNMENT_TOKEN"] }}
jobs: {}
YAML
  )
  privileged_credential_surface=$(sed \
    -e '/^[[:space:]]*id:[[:space:]]*author_merge_token[[:space:]]*$/d' \
    -e 's/steps\.author_merge_token/steps.read_only_readiness/g' \
    <<<"$agent_auto_merge")
  if candidate_job_uses_secrets_context '${{ toJSON(secrets) }}' \
     && candidate_job_uses_secrets_context '${{ secrets ["REVIEWER_ASSIGNMENT_TOKEN"] }}' \
     && candidate_job_uses_secrets_context '${{ Secrets.REVIEWER_ASSIGNMENT_TOKEN }}' \
     && candidate_job_uses_secrets_context '${{ toJSON(SeCrEtS) }}' \
     && candidate_readiness_uses_secrets_context '' "$inherited_env_fixture" \
     && candidate_job_inherits_secrets 'secrets: inherit' \
     && candidate_job_inherits_secrets '    secrets: inherit' \
     && candidate_job_uses_privileged_credential 'aUtHoR_mErGe_ToKeN'; then
    pass "candidate readiness rejects standalone secrets context and inherited-secret declarations regardless of extracted indentation"
  else
    fail "candidate readiness secrets matcher must reject toJSON, whitespace-indexed, inherited root-env, and column-zero inherit forms"
  fi
  candidate_rest_merge=0
  if grep -Eq 'pulls/[^[:space:]]+/merge' <<<"$agent_auto_merge_flat" \
     && grep -Eiq '(^|[[:space:]])(-X|--method)(=|[[:space:]])*(PUT|POST)([[:space:]]|$)' <<<"$agent_auto_merge_flat"; then
    candidate_rest_merge=1
  fi
  if [[ "$wait_step_index" =~ ^[0-9]+$ ]] \
     && [[ "$readiness_step_index" =~ ^[0-9]+$ ]] \
     && [ "$readiness_step_index" -gt "$wait_step_index" ] \
     && [ "$readiness_permissions" = "$expected_readiness_permissions" ] \
     && ! candidate_readiness_uses_secrets_context "$agent_auto_merge" "$workflow_root_env" \
     && ! candidate_job_inherits_secrets "$agent_auto_merge" \
     && ! candidate_readiness_uses_privileged_credential "$privileged_credential_surface" "$workflow_root_env" \
     && grep -Fq 'trusted Agent Review Pipeline workflow_run continuation' <<<"$readiness_step" \
     && ! grep -Fq 'approval-merge-continuation.sh' <<<"$agent_auto_merge" \
     && ! grep -Eq 'gh[[:space:]]+pr[[:space:]]+merge|addPullRequestToMergeQueue|enqueuePullRequest|dequeuePullRequest|enablePullRequestAutoMerge|disablePullRequestAutoMerge|mergePullRequest' <<<"$agent_auto_merge_flat" \
     && [ "$candidate_rest_merge" -eq 0 ]; then
    pass "the immediate-green candidate path remains read-only and delegates privileged continuation"
  else
    fail "the immediate-green candidate path must expose no secret, write permission, helper call, or merge mutation"
  fi

  if grep -Fq 'repo_lint_local.yml annex present' <<<"$agent_review_probe" \
     && grep -Fq 'workflowPath // "") == "repo_lint_local.yml"' <<<"$agent_review_probe"; then
    pass "the one-shot probe still observes the optional non-required annex"
  else
    fail "the one-shot probe must continue to enforce a present repo_lint_local.yml annex"
  fi

  if yq -e '(.on.workflow_run.workflows | contains(["repo-lint", "repo-lint-local", ".github/workflows/repo_lint_local.yml"])) and ([.jobs."evaluate-and-clear".steps[] | select(.name == "Continue approved PRs after completed checks") | select(.if | contains("workflow_run")) | .run | contains("approval-merge-continuation.sh")] | any)' "$AUTO_CLEAR" >/dev/null; then
    pass "completed canonical or annex CI re-enters the trusted approval continuation"
  else
    fail "auto-clear must re-enter approval continuation on completed CI workflows"
  fi

  if yq -e '([.jobs."scheduled-sweep".steps[] | select(.name == "Find open approved PRs for the continuation backstop") | .run | contains("review:approved")] | any) and ([.jobs."scheduled-sweep".steps[] | select(.name == "Continue approved PRs after custom-workflow completions") | .run | contains("approval-merge-continuation.sh")] | any)' "$AUTO_CLEAR" >/dev/null; then
    pass "the existing sweep backstops custom annex workflow names"
  else
    fail "custom annex names need a scheduled approval-continuation backstop"
  fi
fi

if [ ! -f "$SELECTION_HELPER" ]; then
  fail "shared affected-wrapper selector exists"
else
  if REPO_LINT_FULL=false REPO_LINT_CHECKS_JSON='["check_doc_ownership"]' \
       bash -c '. "$1"; repo_lint_check_is_selected check_doc_ownership && ! repo_lint_check_is_selected check_no_token_in_output' _ "$SELECTION_HELPER"; then
    pass "shared selector admits only wrappers named by a partial selection"
  else
    fail "shared selector must filter a partial wrapper selection"
  fi
  if REPO_LINT_FULL=true REPO_LINT_CHECKS_JSON='[]' \
       bash -c '. "$1"; repo_lint_check_is_selected check_anything' _ "$SELECTION_HELPER"; then
    pass "shared selector admits every wrapper for a full selection"
  else
    fail "shared selector must admit every wrapper for a full selection"
  fi
  if REPO_LINT_FULL=false REPO_LINT_CHECKS_JSON='not-json' \
       bash -c '. "$1"' _ "$SELECTION_HELPER" >/dev/null 2>&1; then
    fail "shared selector must fail closed on malformed selection JSON"
  else
    pass "shared selector rejects malformed selection JSON"
  fi

  # #1655 sharding. The default shard owns everything; a 3-way split
  # partitions ordinals exactly (each owned by one shard, none by two or
  # none); a malformed or out-of-range shard fails closed at source time.
  shard_owned() {  # $1 = shard spec, $2 = ordinal
    REPO_LINT_SHARD="$1" bash -c '. "$1"; repo_lint_shard_owns "$2"' _ "$SELECTION_HELPER" "$2" 2>/dev/null
  }
  shard_ok=1
  for ordinal in 0 1 2 67; do
    shard_owned 1/1 "$ordinal" || shard_ok=0
  done
  for ordinal in 0 1 2 3 4 5 6 7 8 9 10 11; do
    owners=0
    for shard in 1/3 2/3 3/3; do
      if shard_owned "$shard" "$ordinal"; then owners=$((owners + 1)); fi
    done
    [ "$owners" -eq 1 ] || { shard_ok=0; echo "INFO: ordinal $ordinal owned by $owners shards" >&2; }
  done
  shard_owned 2/3 1 && shard_owned 2/3 4 && ! shard_owned 2/3 0 && ! shard_owned 2/3 2 || shard_ok=0
  if [ "$shard_ok" -eq 1 ]; then
    pass "shard ownership is a round-robin partition and the default shard owns every ordinal"
  else
    fail "repo_lint_shard_owns must partition ordinals round-robin by REPO_LINT_SHARD"
  fi
  shard_reject_ok=1
  for bad in 0/3 4/3 a/b 1/0 3 1/3/1 ''; do
    if REPO_LINT_SHARD="$bad" bash -c '. "$1"' _ "$SELECTION_HELPER" >/dev/null 2>&1; then
      # An EMPTY value is the unset default (1/1) by design; every other form is rejected.
      [ -z "$bad" ] || { shard_reject_ok=0; echo "INFO: accepted REPO_LINT_SHARD='$bad'" >&2; }
    elif [ -z "$bad" ]; then
      shard_reject_ok=0
    fi
  done
  if ! shard_owned 1/3 x && ! shard_owned 1/3 -1; then
    :
  else
    shard_reject_ok=0
  fi
  if [ "$shard_reject_ok" -eq 1 ]; then
    pass "malformed, zero, out-of-range and non-integer shard inputs fail closed"
  else
    fail "the shard selector must reject malformed REPO_LINT_SHARD values and non-integer ordinals"
  fi
fi

for harness in "$CONSUMER_HARNESS" "$RESIDUE_HARNESS"; do
  if [ ! -f "$harness" ] && [ "$harness" = "$CONSUMER_HARNESS" ]; then
    # The production consumer fixture deliberately omits this hub-only replay
    # harness; the explicit assertion below verifies that omission.
    continue
  fi
  if grep -Fq 'repo-lint-check-selection.sh' "$harness" \
     && grep -Fq 'repo_lint_check_is_selected' "$harness"; then
    pass "${harness##*/} applies the shared affected-wrapper selection"
  else
    fail "${harness##*/} must filter expensive probes through the shared selector"
  fi
done

# The replay loop numbers wrappers in REPLAY_ORDER (measured-heavy wrappers
# first, then the sorted WIRED tail) and asks the shared shard selector
# before running one, so the three replay legs partition the set the way the
# selector's own tests prove and the heavy wrappers land one per shard.
if [ ! -f "$CONSUMER_HARNESS" ]; then
  : # consumer checkout: the hub-only replay harness is deliberately absent
# The loop is cut at its OWN first `done <<<` terminator (awk stops there),
# and that terminator must feed REPLAY_ORDER: a range that ended at a
# literal `done <<< "$REPLAY_ORDER"` ran to EOF when the loop was fed
# `$WIRED` instead, and still found the strings it looked for.
elif replay_loop=$(awk '/^while IFS= read -r name; do$/ {f=1} f {print} f && /^done <<< / {exit}' "$CONSUMER_HARNESS") \
     && [ "$(tail -n 1 <<<"$replay_loop")" = 'done <<< "$REPLAY_ORDER"' ] \
     && grep -Fq 'repo_lint_shard_owns "$ordinal"' <<<"$replay_loop" \
     && grep -Fq 'ordinal=$((ordinal + 1))' <<<"$replay_loop" \
     && sed -n '/^REPLAY_HEAVY=(/,/^)/p' "$CONSUMER_HARNESS" | grep -F 'check_codex_scripts' >/dev/null \
     && sed -n '/^REPLAY_HEAVY=(/,/^)/p' "$CONSUMER_HARNESS" | grep -F 'check_gh_as_author' >/dev/null; then
  pass "the consumer replay loop shards REPLAY_ORDER (heavy wrappers first) through the shared shard selector"
else
  fail "tests/test_repo_lint_consumer_safety.sh must order heavy wrappers first, number them, and consult repo_lint_shard_owns inside the replay loop"
fi

# The heavy-first order must actually separate the two heaviest wrappers
# over three shards: with REPLAY_HEAVY listed in cost order, ordinals 0 and
# 1 are owned by shards 1 and 2 respectively. Executed against the real
# selector rather than assumed from the list.
if [ -f "$CONSUMER_HARNESS" ] && [ -f "$SELECTION_HELPER" ]; then
  first_heavy=$(sed -n '/^REPLAY_HEAVY=(/,/^)/p' "$CONSUMER_HARNESS" | grep -o 'check_[a-z0-9_]*' | head -2 | tr '\n' ' ')
  if [ "$first_heavy" = "check_codex_scripts check_gh_as_author " ] \
     && REPO_LINT_SHARD=1/3 bash -c '. "$1"; repo_lint_shard_owns 0 && ! repo_lint_shard_owns 1' _ "$SELECTION_HELPER" \
     && REPO_LINT_SHARD=2/3 bash -c '. "$1"; repo_lint_shard_owns 1 && ! repo_lint_shard_owns 0' _ "$SELECTION_HELPER"; then
    pass "the two heaviest replay wrappers land on different shards"
  else
    fail "REPLAY_HEAVY must list check_codex_scripts then check_gh_as_author first so round-robin puts them on shards 1 and 2 (got '$first_heavy')"
  fi
fi

if sed -n '/Stale-ratchet sweep/,/Same ratchet/p' "$RESIDUE_HARNESS" \
     | grep -F 'repo_lint_check_is_selected "$n"' >/dev/null; then
  pass "partial residue selection audits only the selected wrappers' exception records"
else
  fail "partial residue selection must not report unselected legacy exceptions as stale"
fi

if yq -e '.jobs.deep_safety.env.REPO_LINT_FULL == "${{ needs.scope.outputs.full }}" and .jobs.deep_safety.env.REPO_LINT_CHECKS_JSON == "${{ needs.scope.outputs.checks }}" and .jobs.deep_self_tests.env.REPO_LINT_FULL == "${{ needs.scope.outputs.full }}" and .jobs.deep_self_tests.env.REPO_LINT_CHECKS_JSON == "${{ needs.scope.outputs.checks }}"' "$REPO_LINT" >/dev/null; then
  pass "deep-safety and the self-test legs receive the classifier selection"
else
  fail "deep_safety and deep_self_tests must consume the classifier full/check outputs"
fi

if [ -f "$MODE_HELPER" ]; then
  mode_result=$(bash -c '. "$1"; ci_check_select_mode --check; echo "$CI_CHECK_RUN_SELF_TEST"' _ "$MODE_HELPER")
  self_result=$(bash -c '. "$1"; ci_check_select_mode --self-test; echo "$CI_CHECK_RUN_SELF_TEST"' _ "$MODE_HELPER")
  consumer_result=$(MERGEPATH_CONSUMER_SAFETY=1 bash -c '. "$1"; ci_check_select_mode; echo "$CI_CHECK_RUN_SELF_TEST"' _ "$MODE_HELPER")
  if [ "$mode_result" = "0" ] && [ "$self_result" = "1" ] && [ "$consumer_result" = "0" ]; then
    pass "the shared wrapper mode selector distinguishes live, self-test, and consumer-smoke calls"
  else
    fail "unexpected wrapper modes: check=$mode_result self=$self_result consumer=$consumer_result"
  fi
else
  fail "shared wrapper mode selector exists"
fi

if grep -Fq 'ci_check_select_mode "$@"' "$AUTO_CLEAR_WRAPPER" \
   && ! grep -Fq 'case "${1:-}" in' "$AUTO_CLEAR_WRAPPER"; then
  pass "auto-clear delegates mode selection to the shared helper"
else
  fail "auto-clear must not duplicate the shared mode selector"
fi

if [ ! -f "$ROOT/tests/test_repo_lint_consumer_safety.sh" ]; then
  pass "consumer checkout omits the hub-only consumer replay harness"
elif grep -Fq 'MERGEPATH_CONSUMER_SAFETY=1' "$ROOT/tests/test_repo_lint_consumer_safety.sh"; then
  pass "the production consumer replay selects wrapper smoke modes"
else
  fail "the production consumer replay must set MERGEPATH_CONSUMER_SAFETY=1"
fi

if [ -f "$TOKEN_WRAPPER" ]; then
  TOKEN_FIXTURE="$(mktemp -d "${TMPDIR:-/tmp}/repo-lint-token-wrapper.XXXXXX")"
  trap 'rm -rf "$TOKEN_FIXTURE" "$SCOPE_FIXTURES"' EXIT
  mkdir -p "$TOKEN_FIXTURE/scripts/ci"
  cp "$TOKEN_WRAPPER" "$TOKEN_FIXTURE/scripts/ci/check_no_token_in_output"
  cat > "$TOKEN_FIXTURE/scripts/ci/token_output_gate.py" <<'PY'
import sys
print(" ".join(sys.argv[1:]))
PY
  token_args=$(MERGEPATH_CONSUMER_SAFETY=1 bash "$TOKEN_FIXTURE/scripts/ci/check_no_token_in_output")
  if [ "$token_args" = "--scan" ]; then
    pass "consumer-safety invokes the live token scan without replaying the execution oracle"
  else
    fail "consumer-safety token wrapper should dispatch --scan, got '$token_args'"
  fi
fi

if [ -f "$DOC_WRAPPER" ]; then
  if grep -Fq 'ci_check_select_mode "$@"' "$DOC_WRAPPER" \
     && ! grep -Fq 'case "${1:-}" in' "$DOC_WRAPPER"; then
    pass "doc ownership delegates mode selection to the shared helper"
  else
    fail "doc ownership must not duplicate the shared mode selector"
  fi

  DOC_FIXTURE="$(mktemp -d "${TMPDIR:-/tmp}/repo-lint-doc-wrapper.XXXXXX")"
  doc_result=$(MERGEPATH_CONSUMER_SAFETY=1 MERGEPATH_REPO_ROOT="$DOC_FIXTURE" bash "$DOC_WRAPPER")
  rm -rf "$DOC_FIXTURE"
  case "$doc_result" in
    "check_doc_ownership: SKIP ("*)
      pass "consumer-safety selects the live doc-ownership assertion without its regression suite"
      ;;
    *)
      fail "consumer-safety doc wrapper should run the live check, got '$doc_result'"
      ;;
  esac
else
  fail "doc ownership wrapper exists"
fi

if [ ! -f "$CONSUMER_VERDICT" ]; then
  fail "consumer-safety verdict classifier exists"
else
  nested=$(printf '%s\n' 'suite: SKIP: optional fixture' 'check_example: PASS' | bash "$CONSUMER_VERDICT" check_example)
  canonical=$(printf '%s\n' 'noise' 'check_example: SKIP (consumer checkout)' | bash "$CONSUMER_VERDICT" check_example)
  if [ "$nested" = "exit 0" ] && [ "$canonical" = "SKIP" ]; then
    pass "consumer-safety distinguishes a canonical wrapper skip from nested skip chatter"
  else
    fail "consumer-safety verdicts should be exit 0/SKIP, got '$nested'/'$canonical'"
  fi
fi

echo
echo "test_repo_lint_optimization: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
