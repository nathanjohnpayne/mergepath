#!/usr/bin/env bash
# tests/test_repo_lint_prepush_fleet.sh — fleet adoption of the repo-lint
# pre-push hook (#2844, epic #2839).
#
# The hook (scripts/git-hooks/pre-push), its runner (scripts/repo-lint-
# prepush.sh) and its installer (scripts/install-git-hooks.sh) propagate to
# every consumer, and each consumer's .github/prepush.yml is rendered from
# examples/prepush.yml by its `prepush_mode` fact. This suite proves, on the
# hub:
#   Part 1 manifest     - the three scripts are canonical entries for every
#                         consumer with the requires: closure the runner and
#                         hook actually use (derived from their source), and
#                         the policy is a templated entry for every consumer
#                         that no entry requires (a consumer may own it);
#   Part 2 allow-list   - check_propagation_closure's hub-only allow-list
#                         names the hook's suites and none of the propagated
#                         pieces;
#   Part 3 policies     - every consumer declares prepush_mode as selected or
#                         off, and its rendered policy is accepted by the
#                         runner with the intended values (selected: mode
#                         selected, full_suite defer, max_minutes 5; off:
#                         mode off), on a consumer-shaped checkout carrying
#                         the real classifier, graph and workflow;
#   Part 4 consumer     - on that checkout the runner runs (it does not soft-
#                         pass, because the classifier and workflow are
#                         delivered), an app-only change selects nothing and
#                         passes, both pre-push wrappers SKIP, a checkout
#                         without the classifier soft-passes, and the
#                         installed hook passes a real push;
#   Part 5 mutations    - a template that loses its `off` arm, and a runner
#                         that stops soft-passing a consumer without the
#                         classifier, each fail the matching part.
#
# Hermetic: fixtures under one mktemp dir, GIT_CONFIG_GLOBAL=/dev/null.
# shellcheck disable=SC2016

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MANIFEST="$REPO_ROOT/.mergepath-sync.yml"
RUNNER_REL=scripts/repo-lint-prepush.sh
HOOK_REL=scripts/git-hooks/pre-push
INSTALLER_REL=scripts/install-git-hooks.sh
TEMPLATE_REL=examples/prepush.yml
POLICY_REL=.github/prepush.yml
CLOSURE="$REPO_ROOT/scripts/ci/check_propagation_closure"

if [ ! -f "$REPO_ROOT/scripts/sync-to-downstream.sh" ]; then
  echo "test_repo_lint_prepush_fleet: SKIP (consumer checkout: scripts/sync-to-downstream.sh absent; this suite reads the hub-only manifest)"
  exit 0
fi
for tool in jq git; do
  command -v "$tool" >/dev/null 2>&1 || { echo "test_repo_lint_prepush_fleet: FAIL ($tool is required)" >&2; exit 1; }
done
if ! command -v yq >/dev/null 2>&1 || ! yq --version 2>&1 | grep -q 'mikefarah/yq'; then
  echo "test_repo_lint_prepush_fleet: FAIL (mikefarah/yq is required)" >&2
  exit 1
fi

# shellcheck disable=SC2046
unset $(git rev-parse --local-env-vars) 2>/dev/null || true
for v in $(env | sed -n 's/^\(MERGEPATH_PREPUSH_[A-Z_]*\)=.*/\1/p'); do unset "$v"; done
for v in $(env | sed -n 's/^\(MERGEPATH_FACT_[A-Z_]*\)=.*/\1/p'); do unset "$v"; done
unset GITHUB_OUTPUT 2>/dev/null || true
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=fixture GIT_AUTHOR_EMAIL=fixture@example.invalid
export GIT_COMMITTER_NAME=fixture GIT_COMMITTER_EMAIL=fixture@example.invalid

TMP=$(mktemp -d "${TMPDIR:-/tmp}/test_repo_lint_prepush_fleet.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  FAIL $1"; }

# As in the policy suite: run normally, `expect` passes or fails the suite;
# against a mutant (SUITE_MODE=mutant) it only counts misses in MISSES.
SUITE_MODE=real
MISSES=0
expect() {   # $1 description, $2 actual, $3 expected
  if [ "$2" = "$3" ]; then
    [ "$SUITE_MODE" != real ] || ok "$1"
  elif [ "$SUITE_MODE" = real ]; then
    bad "$1 (expected '$3', got '$2')"
  else
    MISSES=$((MISSES + 1))
  fi
}
expect_has() {   # $1 description, $2 text, $3 literal substring
  case "$2" in
    *"$3"*) expect "$1" yes yes ;;
    *) expect "$1" "$(printf '%s' "$2" | tail -n 5)" "... $3 ..." ;;
  esac
}

# ── Part 1: manifest entries ─────────────────────────────────────────────
echo "Part 1: manifest entries for the hook, the runner, the installer and the policy"
entry() { P="$1" yq -o=json -I=0 '[.paths[] | select(.path == env(P))]' "$MANIFEST"; }
requires_of() { P="$1" yq -r '.paths[] | select(.path == env(P)) | .requires // [] | .[]' "$MANIFEST"; }
for p in "$HOOK_REL" "$RUNNER_REL" "$INSTALLER_REL"; do
  e=$(entry "$p")
  expect "$p has exactly one manifest entry" "$(jq 'length' <<<"$e")" "1"
  expect "$p is canonical" "$(jq -r '.[0].type' <<<"$e")" "canonical"
  expect "$p goes to every consumer" "$(jq -r '.[0].consumers' <<<"$e")" "all"
  expect "$p is executable in the hub, so the mirror is too" "$(git -C "$REPO_ROOT" ls-files -s "$p" | cut -c1-6)" "100755"
done

# The hook execs the runner by this path.
hook_runner=$(sed -n 's|^runner="\$root/\(.*\)"$|\1|p' "$REPO_ROOT/$HOOK_REL")
expect "the hook runs $RUNNER_REL" "$hook_runner" "$RUNNER_REL"
expect "the hook entry requires the runner it execs" \
  "$(requires_of "$HOOK_REL" | grep -cxF "$hook_runner" || true)" "1"
# Every input the runner names as CLASSIFIER, WORKFLOW or GRAPH travels with it.
runner_inputs=$(grep -E '^ *(CLASSIFIER|WORKFLOW|GRAPH)=[^ ]+$' "$REPO_ROOT/$RUNNER_REL" | sed 's/^[^=]*=//' | sort -u)
expect "the runner names its three repository inputs" "$(printf '%s\n' "$runner_inputs" | grep -c .)" "3"
while IFS= read -r input; do
  [ -n "$input" ] || continue
  expect "the runner entry requires $input" "$(requires_of "$RUNNER_REL" | grep -cxF "$input" || true)" "1"
done <<<"$runner_inputs"
expect "the installer entry requires the hook" "$(requires_of "$INSTALLER_REL" | grep -cxF "$HOOK_REL" || true)" "1"

t=$(entry "$TEMPLATE_REL")
expect "$TEMPLATE_REL has exactly one manifest entry" "$(jq 'length' <<<"$t")" "1"
expect "$TEMPLATE_REL is templated" "$(jq -r '.[0].type' <<<"$t")" "templated"
expect "$TEMPLATE_REL renders to $POLICY_REL" "$(jq -r '.[0].dest' <<<"$t")" "$POLICY_REL"
expect "$TEMPLATE_REL renders from itself" "$(jq -r '.[0].source' <<<"$t")" "$TEMPLATE_REL"
expect "$TEMPLATE_REL goes to every consumer" "$(jq -r '.[0].consumers' <<<"$t")" "all"
expect "no manifest entry delivers $POLICY_REL verbatim" \
  "$(P="$POLICY_REL" yq '[.paths[] | select(.path == env(P))] | length' "$MANIFEST")" "0"
expect "no entry requires the policy (a consumer may own it through skip_paths)" \
  "$(T="$TEMPLATE_REL" P="$POLICY_REL" yq '[.paths[] | .requires // [] | .[] | select(. == env(T) or . == env(P))] | length' "$MANIFEST")" "0"

# ── Part 2: the closure check's hub-only allow-list ──────────────────────
echo "Part 2: check_propagation_closure's allow-list"
allow=$(awk '/^ALLOW_LIST=\(/ { on = 1; next } on && /^\)/ { exit } on' "$CLOSURE" \
  | sed -n 's/^ *"\([^"]*\)".*/\1/p')
allow_listed() {   # glob match, as is_allow_listed does
  local ref="$1" pat
  while IFS= read -r pat; do
    [ -n "$pat" ] || continue
    # shellcheck disable=SC2254
    case "$ref" in $pat) return 0 ;; esac
  done <<<"$allow"
  return 1
}
expect "the allow-list parses" "$([ -n "$allow" ] && echo yes || echo no)" "yes"
for p in "$HOOK_REL" "$RUNNER_REL" "$INSTALLER_REL" "$TEMPLATE_REL"; do
  expect "$p propagates, so it is not allow-listed as hub-only" "$(allow_listed "$p" && echo listed || echo absent)" "absent"
done
for s in tests/test_repo_lint_prepush.sh tests/test_repo_lint_prepush_policy.sh \
  tests/test_repo_lint_prepush_defer.sh tests/test_repo_lint_prepush_load.sh tests/test_repo_lint_prepush_fleet.sh; do
  expect "$s stays hub-only (allow-listed)" "$(allow_listed "$s" && echo listed || echo absent)" "listed"
  expect "$s is not a manifest path" "$(P="$s" yq '[.paths[] | select(.path == env(P))] | length' "$MANIFEST")" "0"
done

# ── consumer-shaped fixture ──────────────────────────────────────────────
# What a consumer holds after a sync: the kit's classifier and graph, the
# canonical workflow, the hook, runner and installer, both pre-push wrappers,
# app code, and neither hub marker.
FIX="$TMP/consumer"
FIXREMOTE="$TMP/consumer-remote.git"
mkdir -p "$FIX/scripts/ci" "$FIX/scripts/git-hooks" "$FIX/.github/workflows" "$FIX/src"
for f in scripts/ci/repo-lint-scope.sh scripts/ci/repo-lint-dependencies.json .github/workflows/repo_lint.yml \
  "$RUNNER_REL" "$HOOK_REL" "$INSTALLER_REL" scripts/ci/check_repo_lint_prepush scripts/ci/check_repo_lint_prepush_fleet; do
  cp -p "$REPO_ROOT/$f" "$FIX/$f"
done
printf 'export const app = 1;\n' > "$FIX/src/app.ts"
printf '.mergepath/\n' > "$FIX/.gitignore"
git -C "$FIX" init -q -b main
git -C "$FIX" add -A
git -C "$FIX" commit -q -m base
git init -q --bare "$FIXREMOTE"
git -C "$FIX" remote add origin "$FIXREMOTE"
git -C "$FIX" push -q --no-verify origin main
git -C "$FIX" fetch -q origin
git -C "$FIX" remote set-head origin main >/dev/null

# The checks this suite runs need no Python packages; a stub stands in for an
# interpreter with CI's pins, and the hook lock and retry records stay here.
printf '#!/bin/sh\nexit 0\n' > "$TMP/python-ok"
chmod +x "$TMP/python-ok"
export MERGEPATH_PREPUSH_PYTHON="$TMP/python-ok"
export XDG_CACHE_HOME="$TMP/xdg"
# The runner refuses to run without shellcheck; a stub is enough, as nothing
# this suite selects calls it.
FAKEBIN="$TMP/fakebin"
mkdir -p "$FAKEBIN"
if ! command -v shellcheck >/dev/null 2>&1; then
  printf '#!/bin/sh\nexit 0\n' > "$FAKEBIN/shellcheck"
  chmod +x "$FAKEBIN/shellcheck"
fi
export PATH="$FAKEBIN:$PATH"

policy_line() { printf '%s\n' "$1" | sed -n 's/^repo-lint pre-push: policy //p; s/^policy\t//p' | head -n 1; }
policy_entry() { printf '%s\n' "$1" | tr ';' '\n' | head -n 1 | tr ',' '\n' | sed 's/^ *//' | grep "^$2=" || true; }

render_for() {   # $1 consumer, $2 template; prints the rendered policy
  (
    # shellcheck source=/dev/null
    source "$REPO_ROOT/scripts/lib/manifest-fact-helpers.sh"
    # shellcheck source=/dev/null
    source "$REPO_ROOT/scripts/lib/template-substitution.sh"
    export_consumer_facts "$1" "$MANIFEST"
    template_substitution::render "$2"
  )
}

# ── Part 3: every consumer's rendered policy ─────────────────────────────
assert_consumer_policies() {   # $1 template, $2 runner
  local tpl="$1" r="$2" c mode out rc line
  for c in $(yq -r '.consumers[].name' "$MANIFEST"); do
    mode=$(C="$c" yq -r '.consumers[] | select(.name == env(C)) | .facts.prepush_mode // ""' "$MANIFEST")
    case "$mode" in
      selected|off) expect "$c declares prepush_mode ($mode)" ok ok ;;
      *) expect "$c declares prepush_mode as selected or off" "'$mode'" "selected|off"; continue ;;
    esac
    rc=0
    render_for "$c" "$tpl" > "$FIX/$POLICY_REL.rendered" || rc=$?
    expect "$c: the template renders" "$rc" "0"
    expect "$c: no template marker survives the render" "$(grep -cE '(>>>|<<<)' "$FIX/$POLICY_REL.rendered" || true)" "0"
    mv "$FIX/$POLICY_REL.rendered" "$FIX/$POLICY_REL"
    rc=0
    out=$(cd "$FIX" && printf 'src/app.ts\n' | bash "$r" --paths-from - --plan 2>&1) || rc=$?
    line=$(policy_line "$out")
    expect "$c: the runner accepts the rendered policy" "$rc" "0"
    expect "$c: mode=$mode comes from the rendered file" "$(policy_entry "$line" mode)" "mode=$mode ($POLICY_REL)"
    if [ "$mode" = selected ]; then
      expect "$c: full_suite=defer from the rendered file" "$(policy_entry "$line" full_suite)" "full_suite=defer ($POLICY_REL)"
      expect "$c: a 5-minute budget from the rendered file" "$(policy_entry "$line" max_minutes)" "max_minutes=5 ($POLICY_REL)"
      expect "$c: deep stays off" "$(policy_entry "$line" deep)" "deep=false ($POLICY_REL)"
    fi
    rc=0
    out=$(cd "$FIX" && printf 'src/app.ts\n' | bash "$r" --paths-from - 2>&1) || rc=$?
    expect "$c: an app-only change passes" "$rc" "0"
    if [ "$mode" = off ]; then
      expect_has "$c: mode off runs nothing and says so" "$out" "skipped (mode=off from $POLICY_REL)"
    else
      expect_has "$c: mode selected, nothing selected for app code" "$out" "the classifier selected no wrapper for this change"
    fi
  done
  rm -f "$FIX/$POLICY_REL"
}
echo "Part 3: every consumer's rendered .github/prepush.yml"
assert_consumer_policies "$REPO_ROOT/$TEMPLATE_REL" "$FIX/$RUNNER_REL"

# ── Part 4: the runner and hook on a consumer checkout ───────────────────
assert_consumer_softpass() {   # $1 runner
  local r="$1" out rc
  mv "$FIX/scripts/ci/repo-lint-scope.sh" "$TMP/scope.hidden"
  rc=0
  out=$(cd "$FIX" && printf 'src/app.ts\n' | bash "$r" --paths-from - 2>&1) || rc=$?
  mv "$TMP/scope.hidden" "$FIX/scripts/ci/repo-lint-scope.sh"
  expect "a consumer without the classifier soft-passes" "$rc" "0"
  expect_has "the soft-pass says why" "$out" "SKIP (no scripts/ci/repo-lint-scope.sh or .github/workflows/repo_lint.yml in this checkout; consumer or pre-kit tree)"
}
echo "Part 4: the runner and hook on a consumer-shaped checkout"
render_for swipewatch "$REPO_ROOT/$TEMPLATE_REL" > "$FIX/$POLICY_REL"
git -C "$FIX" add -A
git -C "$FIX" commit -q -m 'policy: rendered for a selected consumer'
rc=0
out=$(cd "$FIX" && printf 'src/app.ts\n' | bash "$FIX/$RUNNER_REL" --paths-from - --plan 2>&1) || rc=$?
expect "the runner plans on a consumer (no soft-pass: classifier and workflow are delivered)" "$rc" "0"
expect_has "the classifier ran in consumer mode: app code selects nothing" "$out" $'scope\tdeep=false full=false checks=[] consumer_replay=false self_tests=false'
for w in check_repo_lint_prepush check_repo_lint_prepush_fleet; do
  rc=0
  out=$(cd "$FIX" && bash "scripts/ci/$w" 2>&1) || rc=$?
  expect "$w passes on a consumer" "$rc" "0"
  expect_has "$w SKIPs on a consumer" "$out" "$w: SKIP (consumer checkout"
done
assert_consumer_softpass "$FIX/$RUNNER_REL"

# The installed hook, end to end.
rc=0
out=$(cd "$FIX" && bash "$INSTALLER_REL" 2>&1) || rc=$?
expect "the installer installs on a consumer" "$rc" "0"
rc=0
out=$(cd "$FIX" && bash "$INSTALLER_REL" --check 2>&1) || rc=$?
expect "--check reports the hook installed" "$rc" "0"
expect_has "--check names core.hooksPath" "$out" "installed (core.hooksPath=scripts/git-hooks"
git -C "$FIX" checkout -q -b feat/app
printf 'export const app = 2;\n' > "$FIX/src/app.ts"
git -C "$FIX" commit -q -am 'app change'
rc=0
out=$(cd "$FIX" && git push origin feat/app 2>&1) || rc=$?
expect "a consumer push of an app change passes the hook" "$rc" "0"
expect_has "the hook ran" "$out" "repo-lint pre-push: hook invoked for remote origin"
expect_has "the push ran under the rendered policy" "$out" "policy mode=selected ($POLICY_REL)"
expect_has "the push checked the committed tree" "$out" "checking committed tree"
expect "the remote received the branch" "$(git -C "$FIXREMOTE" rev-parse -q --verify refs/heads/feat/app >/dev/null && echo yes || echo no)" "yes"
# A clone that already points core.hooksPath elsewhere (a repository with its
# own hooks directory) is not taken over without --force.
git -C "$FIX" config --local core.hooksPath .githooks
rc=0
out=$(cd "$FIX" && bash "$INSTALLER_REL" 2>&1) || rc=$?
expect "the installer refuses to replace another core.hooksPath" "$rc" "1"
expect_has "the refusal names the existing value" "$out" "core.hooksPath is already set to '.githooks'"
git -C "$FIX" config --local --unset-all core.hooksPath

# ── Part 5: mutations ────────────────────────────────────────────────────
echo "Part 5: each property fails against a mutant"
mutation_check() {   # $1 assertion, $2 name, $3 file to mutate, $4 anchor, $5 replacement, rest: assertion args
  local fn="$1" name="$2" src="$3" anchor="$4" repl="$5"; shift 5
  local mut="$TMP/mutant.$name"
  ANCHOR="$anchor" REPL="$repl" python3 - "$src" "$mut" <<'PY'
import os, sys
s = open(sys.argv[1]).read()
a, r = os.environ["ANCHOR"], os.environ["REPL"]
if s.count(a) != 1:
    sys.exit("anchor found %d times" % s.count(a))
open(sys.argv[2], "w").write(s.replace(a, r))
PY
  SUITE_MODE=mutant MISSES=0
  "$fn" "$@" "$mut" >/dev/null 2>&1 || true
  SUITE_MODE=real
  if [ "$MISSES" -gt 0 ]; then ok "mutant $name is caught ($MISSES misses)"; else bad "mutant $name passes $fn"; fi
}
policies_with_template() { assert_consumer_policies "$1" "$FIX/$RUNNER_REL"; }
softpass_with_runner() { assert_consumer_softpass "$1"; }
mutation_check policies_with_template off-arm-dropped "$REPO_ROOT/$TEMPLATE_REL" \
  $'# >>> if prepush_mode == off\nmode: off\n# <<<\n' ''
mutation_check softpass_with_runner consumer-softpass-dies "$REPO_ROOT/$RUNNER_REL" \
  $'    echo "$PREFIX: SKIP (no $CLASSIFIER or $WORKFLOW in this checkout; consumer or pre-kit tree)"\n    exit 0' \
  '    die "consumer without the classifier"'

echo ""
echo "test_repo_lint_prepush_fleet: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
