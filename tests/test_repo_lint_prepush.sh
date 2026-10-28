#!/usr/bin/env bash
# tests/test_repo_lint_prepush.sh — the repo-lint pre-push mirror (#2221).
#
# Part 1, selection parity. For each changed-path list, a fixture hub commits
# the change on a branch, then:
#   CI   - the `classify repo-lint scope` step body extracted from
#          .github/workflows/repo_lint.yml runs with the BASE/HEAD SHAs, as
#          the scope job does; an independent evaluator of GitHub's
#          expression subset then evaluates every job-level and step-level
#          `if:` of the workflow, for every matrix leg, against those scope
#          outputs, giving the set of check steps CI executes;
#   hook - scripts/repo-lint-prepush.sh receives the same push as git's
#          pre-push stdin and prints its plan.
# The scope bits must be identical and the step sets equal, minus the
# documented per-runner bookends the hook does not run locally. The
# evaluator shares no code with the runner: the runner selects by structure
# (step pins, wrapper names, scope bits), the evaluator by the `if:` text.
# One documented difference (#2580): CI's classifier fails closed to the
# complete surface for a changed path nothing declares, and the hook does
# not run that expansion. Each case names its undeclared paths; the hook's
# runnable lanes (`selected`, `deep`) must equal what CI executes for the
# same push WITHOUT those paths (CI's classify step run on a second commit
# that touches only the rest), and the expansion must sit in the
# `fallback` / `deep_fallback` lanes, so the plan still covers every step
# CI executes.
#
# Part 2, behaviour, through real `git push` into a bare remote with the hook
# installed by scripts/install-git-hooks.sh: a failing selected check blocks
# the push, a passing run lets it through, both bypasses work, the deep lane
# runs only on opt-in, the concurrency cap and nice level hold, no GIT_*
# variable leaks into a check, and the hub-only soft-passes.
#
# Part 3, one hook run per machine (#2581): a second push waits for the
# running one and names it, the wait is bounded, a killed holder's stale
# record is reported, a killed run's snapshot is retired under the lock, and
# the default concurrency follows the load average.
#
# Hermetic: fixtures under one mktemp dir, GIT_CONFIG_GLOBAL=/dev/null.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNNER="$REPO_ROOT/scripts/repo-lint-prepush.sh"
INSTALLER="$REPO_ROOT/scripts/install-git-hooks.sh"
HOOK="$REPO_ROOT/scripts/git-hooks/pre-push"

if [ ! -f "$RUNNER" ] && [ ! -f "$REPO_ROOT/scripts/sync-to-downstream.sh" ]; then
  echo "test_repo_lint_prepush: SKIP (consumer checkout: the pre-push mirror is hub-only)"
  exit 0
fi
for tool in jq python3 git; do
  command -v "$tool" >/dev/null 2>&1 || { echo "test_repo_lint_prepush: FAIL ($tool is required)" >&2; exit 1; }
done
if ! command -v yq >/dev/null 2>&1 || ! yq --version 2>&1 | grep -q 'mikefarah/yq'; then
  echo "test_repo_lint_prepush: FAIL (mikefarah/yq is required)" >&2
  exit 1
fi

# shellcheck disable=SC2046
unset $(git rev-parse --local-env-vars) 2>/dev/null || true
# Every runner control, so a suite run from inside the hook (check_repo_lint_prepush
# under MERGEPATH_PREPUSH_LIVE=all, say) does not leak its opt-ins into the fixtures.
unset MERGEPATH_PREPUSH_SKIP MERGEPATH_PREPUSH_DEEP MERGEPATH_PREPUSH_LIVE MERGEPATH_PREPUSH_JOBS \
  MERGEPATH_PREPUSH_NICE MERGEPATH_PREPUSH_PYTHON MERGEPATH_PREPUSH_KEEP_LOGS MERGEPATH_PREPUSH_LOCK_WAIT \
  MERGEPATH_PREPUSH_LOCK_TOOL GITHUB_OUTPUT 2>/dev/null || true
unset MERGEPATH_PREPUSH_RETRY_FAILED 2>/dev/null || true
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=fixture GIT_AUTHOR_EMAIL=fixture@example.invalid
export GIT_COMMITTER_NAME=fixture GIT_COMMITTER_EMAIL=fixture@example.invalid

TMP=$(mktemp -d "${TMPDIR:-/tmp}/test_repo_lint_prepush.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
ZERO=0000000000000000000000000000000000000000

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  FAIL $1"; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected '$3', got '$2')"; fi; }

# ── the independent CI evaluator ─────────────────────────────────────────
cat > "$TMP/ci_eval.py" <<'PY'
"""Steps GitHub Actions would execute for one scope, from the workflow's if: text.

argv: workflow-jobs.json scope-file. The scope file holds the scope job's
key=value outputs. Prints "<job>\t<step name>" for every step whose job-level
and step-level `if:` are both true for at least one matrix leg. Evaluates the
expression subset the workflow uses (== != && || ! parentheses, string and
number literals, contains, fromJSON, always, success) and fails on anything
else, so a new construct cannot be silently misread.
"""
import itertools, json, re, sys

jobs = json.load(open(sys.argv[1]))
scope = dict(l.split("=", 1) for l in open(sys.argv[2]).read().split("\n") if "=" in l)

TOKEN = re.compile(r"\s*(?:(\|\||&&|==|!=|[!(),])|'((?:[^']|'')*)'|(\d+(?:\.\d+)?)|([A-Za-z_][A-Za-z0-9_.\-]*))")

def tokenize(src):
    pos, out = 0, []
    src = src.strip()
    while pos < len(src):
        m = TOKEN.match(src, pos)
        if not m or m.end() == pos:
            raise SystemExit("ci_eval: cannot tokenize %r at %d" % (src, pos))
        op, s, num, ident = m.groups()
        out.append(("op", op) if op else ("str", s.replace("''", "'")) if s is not None
                   else ("num", float(num)) if num else ("id", ident))
        pos = m.end()
    return out

def lookup(name, matrix):
    if name == "true": return True
    if name == "false": return False
    parts = name.split(".")
    if parts[:3] == ["needs", "scope", "outputs"] and len(parts) == 4:
        if parts[3] not in scope: raise SystemExit("ci_eval: unknown scope output " + name)
        return scope[parts[3]]
    if parts[0] == "matrix" and len(parts) == 2:
        return matrix[parts[1]]
    raise SystemExit("ci_eval: unsupported context " + name)

def coerce_eq(a, b):
    if isinstance(a, (int, float)) and not isinstance(a, bool) or isinstance(b, (int, float)) and not isinstance(b, bool):
        try: return float(a) == float(b)
        except (TypeError, ValueError): return False
    if isinstance(a, str) and isinstance(b, str): return a.lower() == b.lower()
    return a == b

def evaluate(src, matrix):
    toks, i = tokenize(src), [0]
    def peek(): return toks[i[0]] if i[0] < len(toks) else (None, None)
    def take(kind=None, val=None):
        t = peek()
        if (kind and t[0] != kind) or (val and t[1] != val):
            raise SystemExit("ci_eval: unexpected %r in %r" % (t, src))
        i[0] += 1
        return t
    def truthy(v): return v not in (False, None, 0, 0.0, "")
    def expr_or():
        v = expr_and()
        while peek() == ("op", "||"): take(); r = expr_and(); v = v if truthy(v) else r
        return v
    def expr_and():
        v = unary()
        while peek() == ("op", "&&"): take(); r = unary(); v = r if truthy(v) else v
        return v
    def unary():
        if peek() == ("op", "!"): take(); return not truthy(unary())
        return compare()
    def compare():
        v = primary()
        if peek() in (("op", "=="), ("op", "!=")):
            op = take()[1]; r = primary()
            return coerce_eq(v, r) if op == "==" else not coerce_eq(v, r)
        return v
    def primary():
        t = peek()
        if t == ("op", "("):
            take(); v = expr_or(); take("op", ")"); return v
        if t[0] in ("str", "num"): take(); return t[1]
        if t[0] == "id":
            take()
            if peek() == ("op", "("):
                take(); args = []
                while peek() != ("op", ")"):
                    args.append(expr_or())
                    if peek() == ("op", ","): take()
                take("op", ")")
                fn = t[1].lower()
                if fn == "contains":
                    hay, needle = args
                    if isinstance(hay, list): return any(coerce_eq(x, needle) for x in hay)
                    return str(needle).lower() in str(hay).lower()
                if fn == "fromjson": return json.loads(args[0])
                if fn in ("always", "success"): return True
                raise SystemExit("ci_eval: unsupported function " + t[1])
            return lookup(t[1], matrix)
        raise SystemExit("ci_eval: unexpected token %r in %r" % (t, src))
    v = expr_or()
    if i[0] != len(toks): raise SystemExit("ci_eval: trailing tokens in %r" % src)
    return truthy(v)

def strip(cond):
    cond = cond.strip()
    m = re.fullmatch(r"\$\{\{(.*)\}\}", cond, re.S)
    return m.group(1) if m else cond

for job_id, job in jobs.items():
    matrix = (job.get("strategy") or {}).get("matrix") or {}
    if any(k in matrix for k in ("include", "exclude")) or any(not isinstance(v, list) for v in matrix.values()):
        raise SystemExit("ci_eval: unsupported matrix shape in " + job_id)
    keys = sorted(matrix)
    legs = [dict(zip(keys, combo)) for combo in itertools.product(*(matrix[k] for k in keys))] or [{}]
    job_if = strip(str(job.get("if", "true")))
    for step in job.get("steps", []):
        name = step.get("name") or step.get("uses") or ""
        step_if = strip(str(step.get("if", "true")))
        if any(evaluate(job_if, leg) and evaluate(step_if, leg) for leg in legs):
            print("%s\t%s" % (job_id, name))
PY

# What the hook deliberately leaves to CI: the setup prelude (not check
# steps: no check_ name), the per-runner `--snapshot`/`--verify` bookends of
# check_git_identity_hygiene, and the deep jobs' closing plain call (the plain
# call runs once in the live lane). Nothing else may differ.
expected_hook_steps() {
  awk -F'\t' '
    $2 !~ /^check_/ { next }
    $2 == "check_git_identity_hygiene --snapshot" { next }
    $2 == "check_git_identity_hygiene --verify" { next }
    $1 != "lint_fast" && $2 == "check_git_identity_hygiene" { next }
    { print }' | LC_ALL=C sort -u
}

echo "Part 1: selection parity with the CI scope job and the workflow if: expressions"

HUB="$TMP/hub"
REMOTE="$TMP/hub-remote.git"
mkdir -p "$HUB/scripts/ci" "$HUB/.github/workflows"
cp "$REPO_ROOT/scripts/ci/repo-lint-scope.sh" "$REPO_ROOT/scripts/ci/repo-lint-dependencies.json" "$HUB/scripts/ci/"
cp "$REPO_ROOT/.github/workflows/repo_lint.yml" "$HUB/.github/workflows/"
cp "$RUNNER" "$HUB/scripts/"
printf '#!/usr/bin/env bash\n# hub marker\n' > "$HUB/scripts/sync-to-downstream.sh"
git -C "$HUB" init -q -b main
git -C "$HUB" add -A
git -C "$HUB" commit -q -m base
git init -q --bare "$REMOTE"
git -C "$HUB" remote add origin "$REMOTE"
git -C "$HUB" push -q origin main
git -C "$HUB" fetch -q origin
git -C "$HUB" remote set-head origin main >/dev/null

yq -o=json '.jobs' "$HUB/.github/workflows/repo_lint.yml" > "$TMP/jobs.json"
yq '.jobs.scope.steps[] | select(.name == "classify repo-lint scope") | .run' \
  "$HUB/.github/workflows/repo_lint.yml" > "$TMP/ci_classify.sh"
if ! grep -q 'repo-lint-scope.sh' "$TMP/ci_classify.sh"; then
  echo "test_repo_lint_prepush: FAIL (could not extract the CI classify step)" >&2
  exit 1
fi

# id | branch | ;-separated changed paths | ;-separated undeclared paths
CASES='docs|feat/docs|README.md;docs/guide.md|
script|feat/script|scripts/coderabbit-wait.sh|
wrapper|feat/wrapper|scripts/ci/check_cockpit|
fastonly|feat/fastonly|scripts/ci/check_bootstrap_sh|
governance|feat/governance|docs/agents/testing-requirements.md|
replay|feat/replay|.mergepath-sync.yml|
full|feat/full|scripts/ci/repo-lint-scope.sh|
unknown|feat/unknown|scripts/brand-new-tool.sh|scripts/brand-new-tool.sh
unknownmixed|feat/unknown-mixed|scripts/brand-new-tool.sh;scripts/coderabbit-wait.sh;tests/test_brand_new_tool.sh|scripts/brand-new-tool.sh;tests/test_brand_new_tool.sh
unknowntrigger|feat/unknown-trigger|scripts/brand-new-tool.sh;scripts/ci/repo-lint-scope.sh|
prose|feat/prose|scripts/ci/README.md;tests/README.md|
sync|mergepath-sync/wave-1|README.md;scripts/brand-new-tool.sh|
mixed|feat/mixed|scripts/ci/check_doc_ownership;scripts/merge-clearance-gate.sh;BRAND.md|
self|feat/self|scripts/repo-lint-prepush.sh;scripts/git-hooks/pre-push;tests/test_repo_lint_prepush.sh|'

lanes_only() { awk -F'\t' '$1 ~ /^(live|selected|fallback|unselected|deep|deep_fallback)$/'; }
graph_keys=$(jq -c '.wrappers | keys' "$HUB/scripts/ci/repo-lint-dependencies.json")
ci_wrappers() {  # $1 = scope file: the graph wrappers CI selects for it
  jq -r --argjson checks "$(sed -n 's/^checks=//p' "$1")" --argjson full "$(sed -n 's/^full=//p' "$1")" \
     --argjson graph "$graph_keys" '
    [.lint_fast.steps[] | select((.if // "") | test("^matrix\\.shard == "))
      | [(.run // "") | capture("^\\./scripts/ci/(?<w>check_[A-Za-z0-9_]+)") | .w] | first
      | . as $w
      | select($w != null and ($graph | index($w)) != null)
      | select($full or ($checks | index($w)) != null)] | unique | .[]' "$TMP/jobs.json"
}
hook_wrappers() {  # $1 = plan file, $2 = lane: the wrappers of that lane's steps
  awk -F'\t' -v l="$2" '$1 == l { print $3 }' "$1" > "$TMP/lane_names"
  jq -r --rawfile names "$TMP/lane_names" '
    ($names | split("\n") | map(select(length > 0))) as $n
    | [.lint_fast.steps[] | select(.name as $x | $n | index($x) != null)
      | [(.run // "") | capture("^\\./scripts/ci/(?<w>check_[A-Za-z0-9_]+)") | .w] | first] | unique | .[]' \
    "$TMP/jobs.json"
}

while IFS='|' read -r id branch paths undeclared; do
  [ -n "$id" ] || continue
  git -C "$HUB" checkout -q -B "$branch" main
  printf '%s\n' "$paths" | tr ';' '\n' | while IFS= read -r p; do
    mkdir -p "$HUB/$(dirname "$p")"
    printf '\n# prepush parity touch\n' >> "$HUB/$p"
  done
  git -C "$HUB" add -A
  git -C "$HUB" commit -q -m "case $id"
  base=$(git -C "$HUB" rev-parse main)
  head=$(git -C "$HUB" rev-parse HEAD)

  : > "$TMP/ci_scope.$id"
  (cd "$HUB" && EVENT_NAME=pull_request BASE_SHA="$base" HEAD_SHA="$head" HEAD_REF="$branch" \
     GITHUB_OUTPUT="$TMP/ci_scope.$id" bash -e "$TMP/ci_classify.sh") > /dev/null
  printf 'refs/heads/%s %s refs/heads/%s %s\n' "$branch" "$head" "$branch" "$ZERO" \
    | (cd "$HUB" && bash scripts/repo-lint-prepush.sh --hook origin "$REMOTE" --plan 2>"$TMP/plan_err.$id") > "$TMP/plan.$id"

  # CI's selection minus the undeclared-path expansion: CI's own classify
  # step on a sibling commit that touches every path except the undeclared.
  if [ -n "$undeclared" ]; then
    git -C "$HUB" checkout -q -B "$branch-declared" main
    printf '%s\n' "$paths" | tr ';' '\n' | LC_ALL=C sort -u \
      | LC_ALL=C comm -23 - <(printf '%s\n' "$undeclared" | tr ';' '\n' | LC_ALL=C sort -u) \
      | while IFS= read -r p; do
          [ -n "$p" ] || continue
          mkdir -p "$HUB/$(dirname "$p")"
          printf '\n# prepush parity touch\n' >> "$HUB/$p"
        done
    git -C "$HUB" add -A
    git -C "$HUB" commit -q --allow-empty -m "case $id, declared paths only"
    : > "$TMP/ci_local_scope.$id"
    (cd "$HUB" && EVENT_NAME=pull_request BASE_SHA="$base" HEAD_SHA="$(git -C "$HUB" rev-parse HEAD)" HEAD_REF="$branch" \
       GITHUB_OUTPUT="$TMP/ci_local_scope.$id" bash -e "$TMP/ci_classify.sh") > /dev/null
  else
    cp "$TMP/ci_scope.$id" "$TMP/ci_local_scope.$id"
  fi

  ci_scope=$(sort "$TMP/ci_scope.$id" | tr '\n' ' ')
  hook_scope=$(sed -n 's/^scope\t//p' "$TMP/plan.$id" | tr ' ' '\n' | sed '/^$/d' | sort | tr '\n' ' ')
  check "[$id] scope bits equal the CI scope job" "$hook_scope" "$ci_scope"

  # The undeclared paths the hook names are the case's, and its local scope
  # is CI's scope for the declared paths alone.
  check "[$id] the hook names exactly the undeclared paths" \
    "$(sed -n 's/^undeclared\t//p' "$TMP/plan.$id" | LC_ALL=C sort | tr '\n' ';')" \
    "$(printf '%s' "$undeclared" | tr ';' '\n' | sed '/^$/d' | LC_ALL=C sort | tr '\n' ';')"
  if [ -n "$undeclared" ]; then
    check "[$id] the local scope equals CI's scope without the undeclared paths" \
      "$(sed -n 's/^local_scope\t//p' "$TMP/plan.$id" | tr ' ' '\n' | sed '/^$/d' | sort | tr '\n' ' ')" \
      "$(sort "$TMP/ci_local_scope.$id" | tr '\n' ' ')"
    case "$(cat "$TMP/plan_err.$id")" in
      *"UNDECLARED PATH: "*"CI's lint runs the complete surface"*) ok "[$id] the undeclared path is announced" ;;
      *) bad "[$id] no undeclared-path notice: $(cat "$TMP/plan_err.$id")" ;;
    esac
    notice=$(sed -n '/UNDECLARED PATH:/p' "$TMP/plan_err.$id")
    while IFS= read -r upath; do
      [ -n "$upath" ] || continue
      case "$notice" in
        *"$upath"*) ok "[$id] the notice names $upath" ;;
        *) bad "[$id] the undeclared-path notice omits $upath: $notice" ;;
      esac
    done < <(printf '%s\n' "$undeclared" | tr ';' '\n')
  else
    check "[$id] no local scope without an undeclared path" "$(grep -c '^local_scope' "$TMP/plan.$id" || true)" "0"
  fi

  # (a) Coverage: every check step CI executes is in exactly the hook's plan
  # (any lane, the undeclared-path fallback lanes included), nothing more.
  python3 -I "$TMP/ci_eval.py" "$TMP/jobs.json" "$TMP/ci_scope.$id" | expected_hook_steps > "$TMP/ci_steps.$id"
  lanes_only < "$TMP/plan.$id" | awk -F'\t' '{ print $2 "\t" $3 }' | LC_ALL=C sort -u > "$TMP/hook_steps.$id"
  if diff -u "$TMP/ci_steps.$id" "$TMP/hook_steps.$id" > "$TMP/diff.$id"; then
    ok "[$id] the plan covers exactly the check steps CI executes ($(wc -l < "$TMP/hook_steps.$id" | tr -d ' '))"
  else
    bad "[$id] the plan differs from the check steps CI executes (- CI, + hook):"
    sed 's/^/        /' "$TMP/diff.$id"
  fi

  # (b) Deep lane: the deep steps the hook runs on opt-in are the deep-job
  # steps whose if: expressions CI evaluates true for the push minus the
  # undeclared-path fallback; the rest of CI's deep steps are deep_fallback.
  python3 -I "$TMP/ci_eval.py" "$TMP/jobs.json" "$TMP/ci_local_scope.$id" | expected_hook_steps \
    | awk -F'\t' '$1 != "lint_fast"' > "$TMP/ci_deep.$id"
  awk -F'\t' '$1 == "deep" { print $2 "\t" $3 }' "$TMP/plan.$id" | LC_ALL=C sort -u > "$TMP/hook_deep.$id"
  if diff -u "$TMP/ci_deep.$id" "$TMP/hook_deep.$id" > "$TMP/diff.$id"; then
    ok "[$id] deep-lane selection equals CI's minus the undeclared-path fallback ($(wc -l < "$TMP/hook_deep.$id" | tr -d ' ') steps)"
  else
    bad "[$id] deep-lane selection differs from CI's minus the undeclared-path fallback (- CI, + hook):"
    sed 's/^/        /' "$TMP/diff.$id"
  fi
  awk -F'\t' '$1 != "lint_fast"' "$TMP/ci_steps.$id" | LC_ALL=C comm -23 - "$TMP/ci_deep.$id" > "$TMP/ci_deepfb.$id"
  awk -F'\t' '$1 == "deep_fallback" { print $2 "\t" $3 }' "$TMP/plan.$id" | LC_ALL=C sort -u > "$TMP/hook_deepfb.$id"
  check "[$id] deep_fallback holds exactly CI's undeclared-path deep expansion" \
    "$(tr '\n' ' ' < "$TMP/hook_deepfb.$id")" "$(tr '\n' ' ' < "$TMP/ci_deepfb.$id")"

  # (c) Wrappers: the fast-lane wrappers the hook runs as `selected` are the
  # CI scope job's `checks` for the push minus the undeclared-path fallback
  # (every graph wrapper when CI selects the complete surface for another
  # reason); the `fallback` lane holds the rest of CI's selection; the
  # always-run `live` lane holds no graph wrapper.
  ci_wrappers "$TMP/ci_local_scope.$id" > "$TMP/ci_wrappers.$id"
  hook_wrappers "$TMP/plan.$id" selected > "$TMP/hook_wrappers.$id"
  check "[$id] selected fast-lane wrappers equal the CI scope job's checks minus the undeclared-path fallback" \
    "$(tr '\n' ' ' < "$TMP/hook_wrappers.$id")" "$(tr '\n' ' ' < "$TMP/ci_wrappers.$id")"
  ci_wrappers "$TMP/ci_scope.$id" | LC_ALL=C comm -23 - <(LC_ALL=C sort "$TMP/ci_wrappers.$id") > "$TMP/ci_fb_wrappers.$id"
  hook_wrappers "$TMP/plan.$id" fallback > "$TMP/hook_fb_wrappers.$id"
  check "[$id] fallback wrappers are exactly CI's undeclared-path expansion" \
    "$(tr '\n' ' ' < "$TMP/hook_fb_wrappers.$id")" "$(tr '\n' ' ' < "$TMP/ci_fb_wrappers.$id")"
  live_graph=$(awk -F'\t' '$1 == "live" { print $3 }' "$TMP/plan.$id" \
    | jq -R -r --argjson graph "$(jq -c '.wrappers | keys' "$HUB/scripts/ci/repo-lint-dependencies.json")" \
        'split(" ")[0] as $w | select(($graph | index($w)) != null) | $w')
  check "[$id] the always-run lane holds no graph-declared wrapper" "$live_graph" ""
done <<<"$CASES"

# Sanity: the cases exercise both deep and fast selections, so the parity
# above is not vacuous (a hook that always selected everything, or nothing,
# fails here even if CI drifted the same way).
check "docs case is fast-lane only" "$(grep -c '^deep' "$TMP/plan.docs" || true)" "0"
check "docs case selects no graph wrapper" "$(grep -c '^selected' "$TMP/plan.docs" || true)" "0"
check "self case selects the mirror's own wrapper" "$(awk -F'\t' '$1 == "selected" { print $3 }' "$TMP/plan.self")" "check_repo_lint_prepush"
# coderabbit-wait.sh is declared under both enrolled wrappers whose suites
# name it (#2580), so exactly those two self-tests run.
check "script case selects exactly its self-tests" \
  "$(awk -F'\t' '$2 == "deep_self_tests" { print $3 }' "$TMP/plan.script" | LC_ALL=C sort | tr '\n' ' ')" "check_coderabbit_wait --self-test check_phase_4b_automation --self-test "
check "full case selects the consumer replay" "$(grep -c 'deep_consumer_replay' "$TMP/plan.full" || true)" "1"
# #2580: an undeclared path runs no graph wrapper and no deep step here, a
# full trigger or a propagation head beside one still selects everything.
# tests/test_repo_lint_optimization.sh asserts the hot review scripts
# select by path; naming them here would make this suite one of their
# readers and its wrapper a dependent (#2580's drift rule).
check "unknown case runs no graph wrapper locally" "$(grep -c '^selected' "$TMP/plan.unknown" || true)" "0"
check "unknown case runs no deep step locally" "$(grep -c '^deep	' "$TMP/plan.unknown" || true)" "0"
if [ "$(grep -c '^fallback' "$TMP/plan.unknown" || true)" -gt 0 ]; then ok "unknown case keeps CI's expansion in the fallback lane"; else bad "unknown case lost CI's expansion"; fi
check "unknown case states the reason" "$(sed -n 's/^selection\t//p' "$TMP/plan.unknown")" \
  "0 wrappers selected by path, $(grep -c '^fallback' "$TMP/plan.unknown") by undeclared-path fallback"
check "unknownmixed case still runs the declared path's wrapper" \
  "$(hook_wrappers "$TMP/plan.unknownmixed" selected | tr '\n' ' ')" "$(ci_wrappers "$TMP/ci_local_scope.unknownmixed" | tr '\n' ' ')"
check "a full trigger beside an undeclared path keeps the complete surface" "$(grep -c '^fallback' "$TMP/plan.unknowntrigger" || true)" "0"
case "$(sed -n 's/^selection\t//p' "$TMP/plan.unknowntrigger")" in *"complete-surface rule (a full trigger"*) ok "the full-trigger reason is printed" ;; *) bad "full-trigger reason: $(sed -n 's/^selection\t//p' "$TMP/plan.unknowntrigger")" ;; esac
check "a propagation head beside an undeclared path keeps the complete surface" "$(grep -c '^fallback' "$TMP/plan.sync" || true)" "0"

# A push to the default branch is a `push` event in CI: the complete surface.
git -C "$HUB" checkout -q main
printf 'refs/heads/main %s refs/heads/main %s\n' "$(git -C "$HUB" rev-parse HEAD)" "$(git -C "$HUB" rev-parse HEAD)" \
  | (cd "$HUB" && bash scripts/repo-lint-prepush.sh --hook origin "$REMOTE" --plan) > "$TMP/plan.main"
printf '' > "$TMP/ci_scope.main"
(cd "$HUB" && EVENT_NAME=push GITHUB_OUTPUT="$TMP/ci_scope.main" bash -e "$TMP/ci_classify.sh") > /dev/null
check "[main push] scope bits equal the CI push run" \
  "$(sed -n 's/^scope\t//p' "$TMP/plan.main" | tr ' ' '\n' | sed '/^$/d' | sort | tr '\n' ' ')" \
  "$(sort "$TMP/ci_scope.main" | tr '\n' ' ')"

# No merge base with the remote default branch: fail closed, as CI does when
# the PR diff is unavailable.
git -C "$HUB" checkout -q --orphan feat/orphan
git -C "$HUB" commit -q -m orphan
printf 'refs/heads/feat/orphan %s refs/heads/feat/orphan %s\n' "$(git -C "$HUB" rev-parse HEAD)" "$ZERO" \
  | (cd "$HUB" && bash scripts/repo-lint-prepush.sh --hook origin "$REMOTE" --plan 2>/dev/null) > "$TMP/plan.orphan"
check "[no merge base] fails closed to the complete selection" \
  "$(sed -n 's/^scope\t//p' "$TMP/plan.orphan")" \
  'deep=true full=true checks=[] consumer_replay=true self_tests=true'

# --help prints the whole header: the bypass, opt-in and exit-code lines.
help_out=$(bash "$RUNNER" --help)
for want in MERGEPATH_PREPUSH_SKIP MERGEPATH_PREPUSH_LIVE MERGEPATH_PREPUSH_PYTHON MERGEPATH_PREPUSH_KEEP_LOGS 'Exit: 0'; do
  case "$help_out" in *"$want"*) ok "--help documents $want" ;; *) bad "--help omits $want" ;; esac
done
case "$help_out" in *'set -euo'*) bad "--help printed code past the header" ;; *) ok "--help stops at the end of the header" ;; esac
case "$(bash "$INSTALLER" --help)" in *"--uninstall"*"no longer runs"*|*"--uninstall"*) ok "installer --help documents its flags" ;; *) bad "installer --help incomplete" ;; esac

echo "Part 2: behaviour through git push with the installed hook"

FIX="$TMP/fix"
FIXREMOTE="$TMP/fix-remote.git"
mkdir -p "$FIX/scripts/ci" "$FIX/scripts/git-hooks" "$FIX/.github/workflows" "$FIX/lib"
cp "$REPO_ROOT/scripts/ci/repo-lint-scope.sh" "$FIX/scripts/ci/"
cp "$RUNNER" "$INSTALLER" "$FIX/scripts/"
cp "$HOOK" "$FIX/scripts/git-hooks/"
chmod +x "$FIX/scripts/git-hooks/pre-push"
printf '#!/usr/bin/env bash\n# hub marker\n' > "$FIX/scripts/sync-to-downstream.sh"
cat > "$FIX/scripts/ci/repo-lint-dependencies.json" <<'JSON'
{"version": 1, "full_triggers": [], "consumer_replay_triggers": [], "deep_triggers": [],
 "self_tests": ["check_selftested"], "wrappers": {"check_selftested": ["lib/*"], "check_graphed": ["other/*"]}}
JSON
# Each check records that it ran, its nice level, and the peak number of
# checks running at once; check_flag fails while the FLAG file exists, and
# check_env fails if any GIT_* variable of the push leaked into it.
cat > "$FIX/scripts/ci/probe.sh" <<'SH'
#!/usr/bin/env bash
set -eu
out="$PROBE_DIR"
mkdir -p "$out/running"
touch "$out/running/$1"
n=$(ls "$out/running" | wc -l | tr -d ' ')
echo "$n" >> "$out/concurrency"
ps -o nice= -p $$ | tr -d ' ' > "$out/nice.$1"
echo "${REPO_LINT_FULL:-unset} ${REPO_LINT_CHECKS_JSON:-unset} ${REPO_LINT_SHARD:-unset}" > "$out/env.$1"
printf '%s\n' "$1" >> "$out/start-order"
touch "$out/ran.$1"
if [ -f "$out/slow.$1" ]; then sleep 3; fi
if [ -f "$out/hang.$1" ]; then touch "$out/hanging.$1"; sleep 120; touch "$out/unhung.$1"; fi
sleep 1
rm -f "$out/running/$1"
SH
for c in check_ok check_flag check_env check_graphed check_harness check_replay check_selftested; do
  printf '#!/usr/bin/env bash\nset -eu\nbash "$(dirname "$0")/probe.sh" %s\n' "$c" > "$FIX/scripts/ci/$c"
done
cat >> "$FIX/scripts/ci/check_flag" <<'SH'
[ ! -f "$PROBE_DIR/FLAG" ]
SH
cat >> "$FIX/scripts/ci/check_env" <<'SH'
[ -z "${GIT_DIR:-}${GIT_INDEX_FILE:-}${GIT_WORK_TREE:-}" ]
[ -f required-input.txt ]
d=$(mktemp -d "${TMPDIR:-/tmp}/probe-git.XXXXXX")
git init -q "$d"
[ "$(cd "$d" && pwd -P)" = "$(git -C "$d" rev-parse --show-toplevel)" ]
rm -rf "$d"
SH
chmod +x "$FIX/scripts/ci/"*
cat > "$FIX/.github/workflows/repo_lint.yml" <<'YAML'
name: repo-lint
on: [pull_request]
jobs:
  scope:
    runs-on: ubuntu-latest
    steps:
      - run: echo scope
  lint_fast:
    runs-on: ubuntu-latest
    strategy:
      matrix:
        shard: [1, 2]
    steps:
      - name: install_python_ci_dependencies
        run: python3 -m pip install "PyYAML==6.0.3" "markdown-it-py==4.2.0"
      - name: setup prelude
        run: touch "$PROBE_DIR/ran.setup"
      - name: check_ok
        if: matrix.shard == 1
        run: ./scripts/ci/check_ok
      - name: check_flag
        if: matrix.shard == 2
        run: ./scripts/ci/check_flag
      - name: check_env
        if: matrix.shard == 1
        run: ./scripts/ci/check_env
      - name: check_graphed
        if: matrix.shard == 2
        run: ./scripts/ci/check_graphed
      - name: check_git_identity_hygiene --verify
        if: matrix.shard != 1
        run: touch "$PROBE_DIR/ran.verify"
  deep_safety:
    needs: scope
    if: needs.scope.outputs.deep == 'true'
    env:
      REPO_LINT_FULL: ${{ needs.scope.outputs.full }}
      REPO_LINT_CHECKS_JSON: ${{ needs.scope.outputs.checks }}
    strategy:
      matrix:
        safety: [consumer]
    steps:
      - name: check_harness
        if: matrix.safety == 'consumer'
        env:
          REPO_LINT_FULL: "false"
        run: ./scripts/ci/check_harness
  deep_consumer_replay:
    needs: scope
    if: needs.scope.outputs.deep == 'true' && needs.scope.outputs.consumer_replay == 'true'
    env:
      REPO_LINT_FULL: "true"
      REPO_LINT_SHARD: ${{ matrix.shard }}/3
    strategy:
      matrix:
        shard: [1, 2, 3]
    steps:
      - name: check_replay
        run: ./scripts/ci/check_replay
  deep_self_tests:
    needs: scope
    if: needs.scope.outputs.deep == 'true' && needs.scope.outputs.self_tests == 'true'
    strategy:
      matrix:
        suite: [only]
    steps:
      - name: check_selftested --self-test
        if: matrix.suite == 'only' && (needs.scope.outputs.full == 'true' || contains(fromJSON(needs.scope.outputs.checks), 'check_selftested'))
        run: ./scripts/ci/check_selftested --self-test
YAML
printf 'lib\n' > "$FIX/lib/selftested.sh"
printf 'committed requirement\n' > "$FIX/required-input.txt"
printf '.mergepath/\n' > "$FIX/.gitignore"
git -C "$FIX" init -q -b main
git -C "$FIX" add -A
git -C "$FIX" commit -q -m base
git init -q --bare "$FIXREMOTE"
git -C "$FIX" remote add origin "$FIXREMOTE"
git -C "$FIX" push -q --no-verify origin main
git -C "$FIX" fetch -q origin
git -C "$FIX" remote set-head origin main >/dev/null

# Installer: idempotent, local-only, refuses to clobber, reversible.
out=$(cd "$FIX" && bash scripts/install-git-hooks.sh)
check "installer sets core.hooksPath" "$(git -C "$FIX" config --local --get core.hooksPath)" "scripts/git-hooks"
out=$(cd "$FIX" && bash scripts/install-git-hooks.sh)
case "$out" in *"already installed"*) ok "installer is idempotent" ;; *) bad "installer rerun: $out" ;; esac
check "installer leaves exactly one core.hooksPath" "$(git -C "$FIX" config --local --get-all core.hooksPath | wc -l | tr -d ' ')" "1"
rc=0; (cd "$FIX" && bash scripts/install-git-hooks.sh --check >/dev/null) || rc=$?
check "installer --check passes when installed" "$rc" "0"
git -C "$FIX" config --local core.hooksPath other-hooks
rc=0; (cd "$FIX" && bash scripts/install-git-hooks.sh >/dev/null 2>&1) || rc=$?
check "installer refuses a different core.hooksPath" "$rc" "1"
check "installer left the other value alone" "$(git -C "$FIX" config --local --get core.hooksPath)" "other-hooks"
(cd "$FIX" && bash scripts/install-git-hooks.sh --force >/dev/null)
check "installer --force replaces it" "$(git -C "$FIX" config --local --get core.hooksPath)" "scripts/git-hooks"
(cd "$FIX" && bash scripts/install-git-hooks.sh --uninstall >/dev/null)
rc=0; (cd "$FIX" && bash scripts/install-git-hooks.sh --check >/dev/null) || rc=$?
check "installer --uninstall removes it" "$rc" "1"
(cd "$FIX" && bash scripts/install-git-hooks.sh >/dev/null)
# A hook git would skip (no executable bit) is not reported as installed.
chmod -x "$FIX/scripts/git-hooks/pre-push"
rc=0; (cd "$FIX" && bash scripts/install-git-hooks.sh --check >/dev/null) || rc=$?
check "installer --check fails when the hook is not executable" "$rc" "1"
rc=0; (cd "$FIX" && bash scripts/install-git-hooks.sh >/dev/null 2>&1) || rc=$?
check "installer rerun fails when the hook is not executable" "$rc" "1"
chmod +x "$FIX/scripts/git-hooks/pre-push"
# A duplicated key: --force normalizes it to one value, --uninstall clears
# every copy of ours.
git -C "$FIX" config --local --add core.hooksPath other-hooks
rc=0; (cd "$FIX" && bash scripts/install-git-hooks.sh >/dev/null 2>&1) || rc=$?
check "installer refuses a duplicated core.hooksPath without --force" "$rc" "1"
(cd "$FIX" && bash scripts/install-git-hooks.sh --force >/dev/null)
check "installer --force leaves exactly one value" "$(git -C "$FIX" config --local --get-all core.hooksPath)" "scripts/git-hooks"
git -C "$FIX" config --local --add core.hooksPath scripts/git-hooks
(cd "$FIX" && bash scripts/install-git-hooks.sh --uninstall >/dev/null)
check "installer --uninstall removes every copy of its value" "$(git -C "$FIX" config --local --get-all core.hooksPath | wc -l | tr -d ' ')" "0"
(cd "$FIX" && bash scripts/install-git-hooks.sh >/dev/null)

# The fixture checks need no Python; a stub stands in for an interpreter
# with CI's packages, and a failing one for an interpreter without them.
printf '#!/bin/sh\nexit 0\n' > "$TMP/python-ok"
printf '#!/bin/sh\nexit 1\n' > "$TMP/python-bad"
chmod +x "$TMP/python-ok" "$TMP/python-bad"
export MERGEPATH_PREPUSH_PYTHON="$TMP/python-ok"
# The machine-wide hook lock lives under the cache directory (#2581): the
# fixture pushes take their own, never the machine's.
export XDG_CACHE_HOME="$TMP/xdg"

export PROBE_DIR="$TMP/probe"
reset_probe() { rm -rf "$PROBE_DIR"; mkdir -p "$PROBE_DIR"; }
remote_tip() { git -C "$FIXREMOTE" rev-parse -q --verify "refs/heads/$1" 2>/dev/null || echo none; }
commit_change() {  # $1 = branch, $2 = path
  git -C "$FIX" checkout -q -B "$1" main
  mkdir -p "$FIX/$(dirname "$2")"
  printf 'change\n' >> "$FIX/$2"
  git -C "$FIX" add -A
  git -C "$FIX" commit -q -m "change $2"
}

# A passing run lets the push through; setup and --verify are not run.
reset_probe
touch "$PROBE_DIR/slow.check_env"
commit_change feat/pass README.md
rc=0; out=$(cd "$FIX" && MERGEPATH_PREPUSH_JOBS=1 git push origin feat/pass 2>&1) || rc=$?
check "passing checks: push succeeds" "$rc" "0"
check "the hook's first line is the unconditional invocation banner (#2578)" "$(printf '%s\n' "$out" | sed -n 1p)" "repo-lint pre-push: hook invoked for remote origin"
check "passing checks: remote updated" "$(remote_tip feat/pass)" "$(git -C "$FIX" rev-parse HEAD)"
case "$out" in *"PASS  check_ok"*"PASS"*) ok "per-check result lines are printed" ;; *) bad "missing per-check output: $out" ;; esac
for c in check_ok check_flag check_env; do
  [ -f "$PROBE_DIR/ran.$c" ] && ok "live check $c ran" || bad "live check $c did not run"
done
[ ! -f "$PROBE_DIR/ran.setup" ] && ok "setup prelude not run" || bad "setup prelude ran"
[ ! -f "$PROBE_DIR/ran.verify" ] && ok "--verify bookend not run" || bad "--verify bookend ran"
[ ! -f "$PROBE_DIR/ran.check_selftested" ] && ok "unselected self-test not run" || bad "unselected self-test ran"
[ ! -f "$PROBE_DIR/ran.check_graphed" ] && ok "unselected graph wrapper not run by default" || bad "unselected graph wrapper ran"
check "concurrency cap 1 holds" "$(sort -n "$PROBE_DIR/concurrency" | tail -n 1)" "1"
# #2575: the host load is printed beside the cap and in the verdict, so an
# hour-long run on a saturated machine reads as the machine.
if grep -Eq '^repo-lint pre-push: running [0-9]+ checks \(jobs=1, nice=10, host load ([0-9.]+|unknown) on ([0-9]+|\?) CPUs\)' <<<"$out"; then
  ok "the jobs= line reports the host load and CPU count"
else
  bad "no host load beside jobs=: $out"
fi
if grep -Eq '^repo-lint pre-push: PASS \([0-9]+ checks in [0-9]+m[0-9]+s; host load ([0-9.]+|unknown) at start, ([0-9.]+|unknown) at end\)' <<<"$out"; then
  ok "the verdict line reports the host load at start and end"
else
  bad "no host load in the verdict: $out"
fi
base_nice=$(ps -o nice= -p $$ | tr -d ' ')
# Discover the kernel's ceiling independently of the runner. Only this
# disposable Python child changes priority: Linux clamps 20 to 19, while
# macOS permits 20. The suite may itself inherit nice 10 from the hook.
nice_ceiling=$(python3 -I -S - <<'PY'
import os
os.setpriority(os.PRIO_PROCESS, 0, 20)
print(os.getpriority(os.PRIO_PROCESS, 0))
PY
)
want_nice=$((base_nice + 10)); [ "$want_nice" -le "$nice_ceiling" ] || want_nice=$nice_ceiling
check "checks run 10 nice levels below the push" "$(cat "$PROBE_DIR/nice.check_ok")" "$want_nice"

# A cold run must bootstrap timing persistence at the original checkout,
# even though the checks execute in a disposable committed snapshot.
timings="$FIX/.mergepath/prepush-timings.tsv"
if [ -f "$timings" ]; then
  ok "cold timing cache initializes after the first real push"
  cold_rows=$(wc -l < "$timings" | tr -d ' ')
  cold_env=$(awk -F'\t' '$1 == "check_env" { print $2 }' "$timings")
  cold_max=$(awk -F'\t' 'BEGIN{m=0} $2 > m {m=$2} END{print m}' "$timings")
  check "cold timing cache contains each completed check" "$cold_rows" "3"
  check "slow fixture supplies the longest measured duration" "$cold_env" "$cold_max"
else
  bad "cold timing cache did not initialize"
fi

# Retain unselected historical rows, discard duplicate old measurements,
# and use the first run's timings to start its slowest check first.
if [ -f "$timings" ]; then
  printf 'old_unselected\t999999\ncheck_env\t999999\n' >> "$timings"
fi
reset_probe
git -C "$FIX" commit -q --allow-empty -m timing-order
rc=0; out=$(cd "$FIX" && MERGEPATH_PREPUSH_JOBS=1 git push origin feat/pass 2>&1) || rc=$?
check "warm timing cache: next push succeeds" "$rc" "0"
check "next push starts the previously longest check first" "$(sed -n '1p' "$PROBE_DIR/start-order")" "check_env"
if [ -f "$timings" ]; then
  check "warm cache retains unselected historical measurements" "$(awk -F'\t' '$1 == "old_unselected" {print $2}' "$timings")" "999999"
  check "warm cache has one newest check_env measurement" "$(awk -F'\t' '$1 == "check_env" {n++} END{print n+0}' "$timings")" "1"
  measured_env=$(awk '$1 == "PASS" && $2 == "check_env" {sub(/s$/, "", $3);print $3}' <<<"$out")
  check "warm cache uses this run's measured duration" "$(awk -F'\t' '$1 == "check_env" {print $2}' "$timings")" "$measured_env"
else
  bad "warm timing cache is missing"
fi

# Failed persistence stays advisory to the actual selected checks. A file
# at the cache directory path makes mkdir fail on every supported host.
if [ -d "$FIX/.mergepath" ]; then mv "$FIX/.mergepath" "$TMP/saved-timing-cache"; fi
printf 'block cache directory\n' > "$FIX/.mergepath"
reset_probe
git -C "$FIX" commit -q --allow-empty -m cache-unavailable
rc=0; out=$(cd "$FIX" && git push origin HEAD:refs/heads/feat/cache-unavailable-pass 2>&1) || rc=$?
check "unwritable timing cache does not block passing checks" "$rc" "0"
touch "$PROBE_DIR/FLAG"
rc=0; out=$(cd "$FIX" && git push origin HEAD:refs/heads/feat/cache-unavailable-fail 2>&1) || rc=$?
if [ "$rc" -ne 0 ]; then ok "unwritable timing cache cannot clear a failed check"; else bad "unwritable timing cache hid a failed check"; fi
check "failed check with unavailable cache leaves remote unchanged" "$(remote_tip feat/cache-unavailable-fail)" "none"
rm "$FIX/.mergepath"
if [ -d "$TMP/saved-timing-cache" ]; then mv "$TMP/saved-timing-cache" "$FIX/.mergepath"; fi

# MERGEPATH_PREPUSH_LIVE=all runs CI's whole fast lane.
reset_probe
git -C "$FIX" commit -q --allow-empty -m all-live
rc=0; out=$(cd "$FIX" && MERGEPATH_PREPUSH_LIVE=all git push origin feat/pass 2>&1) || rc=$?
check "MERGEPATH_PREPUSH_LIVE=all: push succeeds" "$rc" "0"
[ -f "$PROBE_DIR/ran.check_graphed" ] && ok "MERGEPATH_PREPUSH_LIVE=all runs the unselected wrapper" || bad "unselected wrapper not run under LIVE=all"
# A change to the wrapper's declared input selects it without the opt-in.
reset_probe
commit_change feat/graphed other/input.txt
rc=0; out=$(cd "$FIX" && git push origin feat/graphed 2>&1) || rc=$?
check "graph-selected wrapper: push succeeds" "$rc" "0"
[ -f "$PROBE_DIR/ran.check_graphed" ] && ok "a selected graph wrapper runs" || bad "selected graph wrapper did not run"

# #2580: a path nothing declares (the hub catch-all, scripts/*) makes CI
# select the complete surface. The hook runs the live assertions only,
# names the path in one loud line and says why each wrapper was selected;
# MERGEPATH_PREPUSH_LIVE=all still runs CI's complete fast lane.
reset_probe
commit_change feat/undeclared scripts/new-tool.sh
rc=0; out=$(cd "$FIX" && git push origin feat/undeclared 2>&1) || rc=$?
check "undeclared path: push succeeds" "$rc" "0"
for c in check_ok check_flag check_env; do
  if [ -f "$PROBE_DIR/ran.$c" ]; then ok "undeclared path: live check $c ran"; else bad "undeclared path: live check $c did not run"; fi
done
if [ ! -f "$PROBE_DIR/ran.check_graphed" ]; then ok "undeclared path: the fallback wrapper is not run"; else bad "undeclared path expanded to the complete surface locally"; fi
case "$out" in
  *"UNDECLARED PATH: scripts/new-tool.sh is in no wrapper's declared inputs"*"CI's lint runs the complete surface for it"*) ok "undeclared path: one loud line names the path" ;;
  *) bad "undeclared path notice missing: $out" ;;
esac
case "$out" in *"selection: 0 wrappers selected by path, 1 by undeclared-path fallback"*) ok "undeclared path: the selection reason is printed" ;; *) bad "selection reason missing: $out" ;; esac
# The recovery hint names both opt-ins: the deep_fallback lane runs only
# with MERGEPATH_PREPUSH_LIVE=all and MERGEPATH_PREPUSH_DEEP=1 together.
case "$out" in *"MERGEPATH_PREPUSH_LIVE=all runs the wrappers, and with MERGEPATH_PREPUSH_DEEP=1 as well the deep steps"*) ok "undeclared path: the hint names both opt-ins for the deep fallback" ;; *) bad "undeclared path hint omits the deep opt-in: $out" ;; esac
reset_probe
git -C "$FIX" commit -q --allow-empty -m undeclared-all-live
rc=0; out=$(cd "$FIX" && MERGEPATH_PREPUSH_LIVE=all git push origin feat/undeclared 2>&1) || rc=$?
check "undeclared path, MERGEPATH_PREPUSH_LIVE=all: push succeeds" "$rc" "0"
if [ -f "$PROBE_DIR/ran.check_graphed" ]; then ok "MERGEPATH_PREPUSH_LIVE=all runs the fallback wrapper"; else bad "fallback wrapper not run under LIVE=all"; fi
case "$out" in *"1 fallback wrappers"*) ok "MERGEPATH_PREPUSH_LIVE=all counts the fallback wrappers it runs" ;; *) bad "LIVE=all running line: $out" ;; esac
# The notice describes this run, not the default one.
case "$out" in
  *"this hook runs only the live assertions"*) bad "LIVE=all notice still claims only the live assertions ran: $out" ;;
  *"MERGEPATH_PREPUSH_LIVE=all runs its 1 fallback wrappers here; its 3 deep steps also need MERGEPATH_PREPUSH_DEEP=1"*) ok "MERGEPATH_PREPUSH_LIVE=all: the notice says the fallback wrappers ran and the deep steps need DEEP=1" ;;
  *) bad "LIVE=all notice: $out" ;;
esac

# A failing selected check blocks the push and names the check.
reset_probe
touch "$PROBE_DIR/FLAG"
commit_change feat/fail README.md
rc=0; out=$(cd "$FIX" && git push origin feat/fail 2>&1) || rc=$?
[ "$rc" -ne 0 ] && ok "failing check: push blocked (exit $rc)" || bad "failing check: push was not blocked"
check "failing check: remote not updated" "$(remote_tip feat/fail)" "none"
case "$out" in *"FAIL  check_flag"*) ok "failing check is named" ;; *) bad "failing check not named: $out" ;; esac
case "$out" in *"--no-verify"*"MERGEPATH_PREPUSH_SKIP=1"*) ok "bypass is documented in the failure" ;; *) bad "bypass hint missing" ;; esac

# Hook checks use the pushed tip even when the original checkout differs.
reset_probe
rm -f "$PROBE_DIR/FLAG"
git -C "$FIX" checkout -q feat/pass
printf 'dirty\n' >> "$FIX/README.md"
printf 'untracked\n' > "$FIX/untracked-local.txt"
rc=0; out=$(cd "$FIX" && git push origin feat/pass:refs/heads/feat/dirty 2>&1) || rc=$?
check "dirty tracked file: committed tip passes" "$rc" "0"
check "dirty tracked file: remote receives exact commit" "$(remote_tip feat/dirty)" "$(git -C "$FIX" rev-parse feat/pass)"
check "dirty checkout bytes retained" "$(tail -n 1 "$FIX/README.md")" "dirty"
check "untracked checkout bytes retained" "$(cat "$FIX/untracked-local.txt")" "untracked"
git -C "$FIX" checkout -q -- README.md
rm "$FIX/untracked-local.txt"
git -C "$FIX" checkout -q main
rc=0; out=$(cd "$FIX" && git push origin feat/pass:refs/heads/feat/other 2>&1) || rc=$?
check "push of a non-HEAD tip: checks exact committed tree" "$rc" "0"
check "non-HEAD remote receives pushed tip" "$(remote_tip feat/other)" "$(git -C "$FIX" rev-parse feat/pass)"
check "original checkout HEAD retained" "$(git -C "$FIX" symbolic-ref --short HEAD)" "main"
index_before=$(git hash-object "$FIX/.git/index")
rc=0; out=$(cd "$FIX" && GIT_DIR="$FIX/.git" GIT_WORK_TREE="$FIX" GIT_INDEX_FILE="$FIX/.git/index" git push origin feat/pass:refs/heads/feat/hook-env 2>&1) || rc=$?
check "explicit hook-local git environment: exact non-HEAD tip passes" "$rc" "0"
check "hook-local index remains unchanged" "$(git hash-object "$FIX/.git/index")" "$index_before"
check "hook-local environment remote receives exact tip" "$(remote_tip feat/hook-env)" "$(git -C "$FIX" rev-parse feat/pass)"

# #2575: the --exec-step worker itself clears git's hook-local variables, so
# a check never resolves a fixture against the pushing repository even when
# the worker is reached without the runner's own scrub. Under a leaked
# GIT_DIR, `git init "$d"` reinitializes that repository instead (it sets the
# shared core.bare = true, the #2578 footprint) and creates nothing in $d.
WORKER="$TMP/worker-run"
mkdir -p "$WORKER/steps" "$WORKER/logs" "$WORKER/results"
printf '%s\n' "$FIX" > "$WORKER/root"
printf '0\n' > "$WORKER/nice"
printf 'check_worker_env\n' > "$WORKER/steps/001.name"
: > "$WORKER/steps/001.env"
cat > "$WORKER/steps/001.sh" <<'SH'
env | grep -E '^GIT_(DIR|WORK_TREE|INDEX_FILE|PREFIX|COMMON_DIR|OBJECT_DIRECTORY)=' > "$WORKER_ENV_OUT" || true
d=$(mktemp -d "${TMPDIR:-/tmp}/worker-fixture.XXXXXX")
git init -q "$d"
[ -d "$d/.git" ]
rm -rf "$d"
SH
bare_before=$(git -C "$FIX" config --local --get core.bare)
rc=0; GIT_DIR="$FIX/.git" GIT_WORK_TREE="$FIX" GIT_INDEX_FILE="$FIX/.git/index" GIT_PREFIX='' \
  GIT_COMMON_DIR="$FIX/.git" WORKER_ENV_OUT="$TMP/worker-env.out" \
  bash "$RUNNER" --exec-step "$WORKER" 001 > "$TMP/worker.out" 2>&1 || rc=$?
check "worker invoked with git's hook-local variables exits 0" "$rc" "0"
check "worker passes a fixture git init under leaked GIT_* variables" "$(cut -f1 "$WORKER/results/001" 2>/dev/null)" "0"
check "no hook-local GIT_* variable reaches the check" "$(cat "$TMP/worker-env.out" 2>/dev/null)" ""
check "a fixture git init under the worker leaves the pushing repository's core.bare alone" "$(git -C "$FIX" config --local --get core.bare)" "$bare_before"
git -C "$FIX" config --local core.bare "$bare_before"

# A deleted tracked requirement, recreated only as an untracked local file,
# must fail exactly as CI does. The old checkout-based runner passes this.
reset_probe
commit_change feat/deleted README.md
git -C "$FIX" rm -q required-input.txt
git -C "$FIX" commit -q -m 'delete required input'
printf 'local recreation\n' > "$FIX/required-input.txt"
rc=0; out=$(cd "$FIX" && git push origin feat/deleted 2>&1) || rc=$?
if [ "$rc" -ne 0 ]; then ok "untracked recreation cannot mask committed deletion"; else bad "untracked recreation masked committed deletion"; fi
case "$out" in *"FAIL  check_env"*) ok "committed deletion fails its actual check" ;; *) bad "committed deletion diagnostic: $out" ;; esac
check "committed deletion remote not updated" "$(remote_tip feat/deleted)" "none"
check "untracked recreation is untouched" "$(cat "$FIX/required-input.txt")" 'local recreation'
rc=0; out=$(cd "$FIX" && git push origin feat/pass:refs/heads/feat/multi-good feat/deleted:refs/heads/feat/multi-bad 2>&1) || rc=$?
if [ "$rc" -ne 0 ]; then ok "one failing committed tip blocks a multi-branch push"; else bad "multi-branch push ignored failing tip"; fi
check "multi-branch good ref not updated on failure" "$(remote_tip feat/multi-good)" "none"
check "multi-branch bad ref not updated on failure" "$(remote_tip feat/multi-bad)" "none"
rc=0; out=$(cd "$FIX" && git push origin feat/pass:refs/heads/feat/multi-first feat/graphed:refs/heads/feat/multi-second 2>&1) || rc=$?
check "two passing committed tips allow multi-branch push" "$rc" "0"
check "first multi-branch tip exact" "$(remote_tip feat/multi-first)" "$(git -C "$FIX" rev-parse feat/pass)"
check "second multi-branch tip exact" "$(remote_tip feat/multi-second)" "$(git -C "$FIX" rev-parse feat/graphed)"
rm "$FIX/required-input.txt"
check "owned snapshots retired" "$(git -C "$FIX" worktree list --porcelain | grep -c '^worktree ')" "1"
git -C "$FIX" checkout -q feat/fail
touch "$PROBE_DIR/FLAG"

# Missing CI Python packages are an environment error, not a pass.
rc=0; out=$(cd "$FIX" && MERGEPATH_PREPUSH_PYTHON="$TMP/python-bad" git push origin feat/fail:refs/heads/feat/nopy 2>&1) || rc=$?
check "missing CI Python packages: push refused" "$rc" "1"
case "$out" in *"no python3 with the CI packages"*) ok "missing packages are named" ;; *) bad "missing packages output: $out" ;; esac

# Real interpreter metadata must match the committed workflow pins. These
# local fake distributions need no pip/network; the production probe reads
# their installed metadata under -I, exactly as it does a normal venv.
# Literal spaces, apostrophe and shell metacharacters must survive launcher
# generation without being evaluated as shell syntax.
PIN_VENV="$TMP/pin venv's \$(literal) \`literal\`"
python3 -I -m venv --without-pip "$PIN_VENV"
pin_site=$("$PIN_VENV/bin/python3" -I -c 'import site; print(site.getsitepackages()[0])')
mkdir -p "$pin_site/PyYAML-6.0.3.dist-info" "$pin_site/markdown_it_py-4.2.0.dist-info"
printf '' > "$pin_site/yaml.py"
printf '' > "$pin_site/markdown_it.py"
printf 'Name: PyYAML\nVersion: 6.0.3\n' > "$pin_site/PyYAML-6.0.3.dist-info/METADATA"
printf 'Name: markdown-it-py\nVersion: 0.0.0\n' > "$pin_site/markdown_it_py-4.2.0.dist-info/METADATA"
rm -f "$PROBE_DIR/FLAG"
rc=0; out=$(cd "$FIX" && MERGEPATH_PREPUSH_PYTHON="$PIN_VENV/bin/python3" MERGEPATH_PREPUSH_DEEP=1 git push origin feat/fail:refs/heads/feat/wrong-md 2>&1) || rc=$?
if [ "$rc" -ne 0 ]; then ok "wrong markdown-it-py version refuses deep run"; else bad "wrong markdown-it-py version passed"; fi
case "$out" in *"workflow pins"*) ok "version mismatch names pinned environment" ;; *) bad "version mismatch diagnostic: $out" ;; esac
check "wrong markdown version remote not updated" "$(remote_tip feat/wrong-md)" "none"
printf 'Name: markdown-it-py\nVersion: 4.2.0\n' > "$pin_site/markdown_it_py-4.2.0.dist-info/METADATA"
rc=0; out=$(cd "$FIX" && MERGEPATH_PREPUSH_PYTHON="$PIN_VENV/bin/python3" MERGEPATH_PREPUSH_DEEP=1 git push origin feat/fail:refs/heads/feat/right-pins 2>&1) || rc=$?
check "exact pinned metadata allows deep run" "$rc" "0"
# The environment probe alone is insufficient: checks call python3 again
# through the installed PATH shim. An external symlink to a venv interpreter
# can lose its pyvenv.cfg and execute the base Python without these packages.
# Exercise the actual nested check with a module present only in this venv.
printf 'MARKER = "venv-runtime-module"\n' > "$pin_site/prepush_venv_only.py"
git -C "$FIX" checkout -q -B feat/venv-runtime feat/fail
cat >> "$FIX/scripts/ci/check_env" <<'SH'
nested_python=$(command -v python3)
mkdir -p "$PROBE_DIR/bash-free-bin"
if PATH="$PROBE_DIR/bash-free-bin" command -v bash >/dev/null 2>&1; then exit 1; fi
PATH="$PROBE_DIR/bash-free-bin" "$nested_python" -I - "$EXPECTED_PYTHON_PREFIX" \
  '' 'two words' $'quote\' " dollar$() `backtick`' $'line1\nline2' <<'PY' >> "$PROBE_DIR/python-runtime"
import os, sys, yaml, prepush_venv_only
assert os.path.samefile(sys.prefix, sys.argv[1])
assert sys.argv[2:] == ["", "two words", "quote' \" dollar$() `backtick`", "line1\nline2"]
print(prepush_venv_only.MARKER)
PY
SH
git -C "$FIX" add scripts/ci/check_env
git -C "$FIX" commit -q -m 'exercise the selected Python in a nested check'
rc=0; out=$(cd "$FIX" && EXPECTED_PYTHON_PREFIX="$PIN_VENV" \
  MERGEPATH_PREPUSH_PYTHON="$PIN_VENV/bin/python3" \
  git push origin feat/venv-runtime 2>&1) || rc=$?
check "selected venv survives nested check PATH shim" "$rc" "0"
check "nested Python imports its venv-only module" "$(cat "$PROBE_DIR/python-runtime" 2>/dev/null || true)" "venv-runtime-module"
if [ "$rc" -ne 0 ]; then printf '%s\n' "$out"; fi
# Correct package metadata cannot stand in for the actual required import.
# A real missing PyYAML module must still refuse before any selected check.
rm "$pin_site/yaml.py"
rc=0; out=$(cd "$FIX" && EXPECTED_PYTHON_PREFIX="$PIN_VENV" \
  MERGEPATH_PREPUSH_PYTHON="$PIN_VENV/bin/python3" \
  git push origin feat/venv-runtime:refs/heads/feat/missing-yaml 2>&1) || rc=$?
if [ "$rc" -ne 0 ]; then ok "missing PyYAML import refuses despite matching metadata"; else bad "matching metadata hid missing PyYAML"; fi
case "$out" in *"no python3 with the CI packages"*) ok "missing PyYAML import retains environment error" ;; *) bad "missing PyYAML diagnostic: $out" ;; esac
check "missing PyYAML import leaves remote unchanged" "$(remote_tip feat/missing-yaml)" "none"
printf '' > "$pin_site/yaml.py"
git -C "$FIX" checkout -q feat/fail
printf 'Name: PyYAML\nVersion: 0.0.0\n' > "$pin_site/PyYAML-6.0.3.dist-info/METADATA"
rc=0; out=$(cd "$FIX" && MERGEPATH_PREPUSH_PYTHON="$PIN_VENV/bin/python3" git push origin feat/fail:refs/heads/feat/wrong-yaml 2>&1) || rc=$?
if [ "$rc" -ne 0 ]; then ok "wrong PyYAML version refuses fast run"; else bad "wrong PyYAML version passed"; fi
touch "$PROBE_DIR/FLAG"

# Both bypasses.
rc=0; out=$(cd "$FIX" && MERGEPATH_PREPUSH_SKIP=1 git push origin feat/fail 2>&1) || rc=$?
check "MERGEPATH_PREPUSH_SKIP=1 bypasses" "$rc" "0"
case "$out" in *"hook invoked for remote origin"*"skipped (MERGEPATH_PREPUSH_SKIP=1)"*) ok "the skip bypass still prints the invocation banner first" ;; *) bad "skip bypass output: $out" ;; esac
git -C "$FIX" push -q origin --delete feat/fail --no-verify
rc=0; (cd "$FIX" && git push -q --no-verify origin feat/fail >/dev/null 2>&1) || rc=$?
check "--no-verify bypasses" "$rc" "0"
rm -f "$PROBE_DIR/FLAG"

# The deep lane is selected by the classifier but runs only on opt-in.
reset_probe
commit_change feat/deep lib/selftested.sh
rc=0; out=$(cd "$FIX" && git push origin feat/deep 2>&1) || rc=$?
check "deep selection without opt-in: push succeeds" "$rc" "0"
[ ! -f "$PROBE_DIR/ran.check_selftested" ] && ok "self-test not run without opt-in" || bad "self-test ran without opt-in"
case "$out" in *"deep_self_tests: check_selftested --self-test"*) ok "skipped deep steps are listed" ;; *) bad "deep steps not listed: $out" ;; esac
reset_probe
git -C "$FIX" commit -q --allow-empty -m again
rc=0; out=$(cd "$FIX" && MERGEPATH_PREPUSH_DEEP=1 git push origin feat/deep 2>&1) || rc=$?
check "deep opt-in: push succeeds" "$rc" "0"
[ -f "$PROBE_DIR/ran.check_selftested" ] && ok "self-test runs on opt-in" || bad "self-test did not run on opt-in"
check "deep harness gets the step env over the job env" "$(cat "$PROBE_DIR/env.check_harness" 2>/dev/null)" 'false ["check_selftested"] unset'
[ ! -f "$PROBE_DIR/ran.check_replay" ] && ok "unselected replay not run" || bad "replay ran without consumer_replay"

# Tag pushes and deletions have nothing to lint.
reset_probe
git -C "$FIX" tag v1
rc=0; out=$(cd "$FIX" && git push origin v1 2>&1) || rc=$?
check "tag push passes" "$rc" "0"
[ ! -f "$PROBE_DIR/ran.check_ok" ] && ok "tag push runs no checks" || bad "tag push ran checks"

# #2578: a hook that cannot check must fail the push, never pass it silently.
# The observed shape: the primary's shared config gains `core.bare = true`
# (what a fixture `git init` under an inherited GIT_DIR writes) while
# extensions.worktreeConfig is on, so every linked worktree reads as bare and
# `git rev-parse --show-toplevel` fails inside the hook.
LINKED="$TMP/fix-linked"
git -C "$FIX" worktree add -q -b feat/linked "$LINKED" feat/pass
git -C "$LINKED" commit -q --allow-empty -m linked
# Git reports physical paths (/private/var on macOS, where TMPDIR is /var).
LINKED_P=$(cd "$LINKED" && pwd -P)
FIX_P=$(cd "$FIX" && pwd -P)
git -C "$FIX" config --local extensions.worktreeConfig true
reset_probe
rc=0; out=$(cd "$LINKED" && bash scripts/install-git-hooks.sh --check 2>&1) || rc=$?
check "installer --check passes from a linked worktree" "$rc" "0"
case "$out" in *"inherits the relative core.hooksPath=scripts/git-hooks"*) ok "installer --check warns about the inherited relative core.hooksPath" ;; *) bad "inherited relative core.hooksPath not warned: $out" ;; esac
case "$out" in *"this worktree runs $LINKED_P/scripts/git-hooks/pre-push"*) ok "installer --check names the hook git resolves from this worktree" ;; *) bad "resolved hook not named: $out" ;; esac
rc=0; out=$(cd "$FIX" && bash scripts/install-git-hooks.sh --check 2>&1) || rc=$?
case "$out" in *"inherits the relative"*) bad "primary checkout warned as a linked worktree: $out" ;; *) ok "the primary checkout gets no linked-worktree warning" ;; esac
# A relative --git-common-dir resolves against the worktree root, not the
# directory --check runs from.
rc=0; out=$(cd "$FIX/scripts" && bash install-git-hooks.sh --check 2>&1) || rc=$?
check "installer --check passes from a subdirectory of the primary checkout" "$rc" "0"
rc=0; out=$(cd "$LINKED/scripts" && bash install-git-hooks.sh --check 2>&1) || rc=$?
check "installer --check passes from a subdirectory of a linked worktree" "$rc" "0"
git -C "$LINKED" config --worktree core.hooksPath "$TMP/no-such-hooks"
rc=0; out=$(cd "$LINKED" && bash scripts/install-git-hooks.sh --check 2>&1) || rc=$?
check "installer --check fails when this worktree's effective hooks path has no pre-push" "$rc" "1"
case "$out" in *"$TMP/no-such-hooks"*"no executable pre-push"*) ok "the unreachable hooks path is named" ;; *) bad "unreachable hooks path output: $out" ;; esac
git -C "$LINKED" config --worktree --unset core.hooksPath
git -C "$FIX" config --local core.bare true
rc=0; out=$(cd "$LINKED" && bash scripts/install-git-hooks.sh --check 2>&1) || rc=$?
check "installer --check fails while the shared config says core.bare = true" "$rc" "1"
case "$out" in *"core.bare = true in $FIX_P/.git/config"*) ok "installer names the file that sets core.bare" ;; *) bad "installer bare output: $out" ;; esac
rc=0; out=$(cd "$LINKED" && git push origin feat/linked 2>&1) || rc=$?
check "shared core.bare = true: push from a linked worktree is blocked, not silently passed" "$rc" "1"
check "shared core.bare = true: remote not updated" "$(remote_tip feat/linked)" "none"
case "$out" in "repo-lint pre-push: hook invoked for remote origin"*"bare repository"*"core.bare false"*) ok "the bare-config failure prints the banner, names the state and the repair" ;; *) bad "bare-config output: $out" ;; esac
rc=0; out=$(cd "$FIX" && git push origin feat/pass:refs/heads/feat/bare-primary 2>&1) || rc=$?
check "core.bare = true: push from the primary checkout is blocked too" "$rc" "1"
check "core.bare = true: primary push leaves the remote unchanged" "$(remote_tip feat/bare-primary)" "none"
git -C "$FIX" config --local core.bare false
git -C "$FIX" config --local --unset extensions.worktreeConfig

# A runner that is present but unusable fails closed; only an absent runner
# soft-passes (the consumer case below).
mv "$LINKED/scripts/repo-lint-prepush.sh" "$TMP/saved-runner"
mkdir "$LINKED/scripts/repo-lint-prepush.sh"
rc=0; out=$(cd "$LINKED" && git push origin feat/linked 2>&1) || rc=$?
check "unreadable runner: push blocked" "$rc" "1"
case "$out" in *"is not a readable file"*) ok "unreadable runner is named" ;; *) bad "unreadable runner output: $out" ;; esac
rmdir "$LINKED/scripts/repo-lint-prepush.sh"
ln -s "$TMP/no-such-runner.sh" "$LINKED/scripts/repo-lint-prepush.sh"
rc=0; out=$(cd "$LINKED" && git push origin feat/linked 2>&1) || rc=$?
check "dangling runner symlink: push blocked, not soft-passed" "$rc" "1"
case "$out" in *"SKIP (scripts/repo-lint-prepush.sh"*) bad "dangling runner symlink reported as an absent runner: $out" ;; *"is not a readable file"*) ok "dangling runner symlink is named as unusable" ;; *) bad "dangling runner symlink output: $out" ;; esac
rm "$LINKED/scripts/repo-lint-prepush.sh"
mv "$TMP/saved-runner" "$LINKED/scripts/repo-lint-prepush.sh"
# exec failing: a `bash` on PATH whose interpreter does not exist. The wrapper
# itself runs under the real bash, so only its exec of the runner fails.
mkdir -p "$TMP/badbash"
printf '#!/nonexistent/interpreter\n' > "$TMP/badbash/bash"
chmod +x "$TMP/badbash/bash"
rc=0; out=$(cd "$LINKED" && PATH="$TMP/badbash:$PATH" "$BASH" scripts/git-hooks/pre-push origin "$FIXREMOTE" </dev/null 2>&1) || rc=$?
check "runner exec failure: hook exits 1" "$rc" "1"
case "$out" in *"could not exec bash"*) ok "runner exec failure is named" ;; *) bad "exec failure output: $out" ;; esac

# The #2578 sequence: a long hook run killed by SIGTERM to its process group
# (as GNU timeout does), then an immediate re-push from the same worktree.
# The kill must leave nothing that makes the next hook skip.
reset_probe
touch "$PROBE_DIR/hang.check_ok"
rc=0; python3 -I - "$LINKED" "$PROBE_DIR/hanging.check_ok" <<'PY' > "$TMP/killed-push.log" 2>&1 || rc=$?
import os, signal, subprocess, sys, time
wt, marker = sys.argv[1], sys.argv[2]
p = subprocess.Popen(["git", "push", "origin", "feat/linked"], cwd=wt, start_new_session=True,
                     stdin=subprocess.DEVNULL)
deadline = time.time() + 60
while not os.path.exists(marker) and time.time() < deadline and p.poll() is None:
    time.sleep(0.1)
if not os.path.exists(marker):
    sys.exit("hang marker never appeared")
os.killpg(p.pid, signal.SIGTERM)
sys.exit(0 if p.wait(timeout=60) != 0 else 3)
PY
check "killed push: the run was interrupted mid-check and failed" "$rc" "0"
check "killed push: remote not updated" "$(remote_tip feat/linked)" "none"
check "killed push: no snapshot worktree left behind" "$(git -C "$FIX" worktree list --porcelain | grep -c '^worktree ')" "2"
leftover=$(find "$TMP/.fix-worktrees" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l | tr -d ' ')
check "killed push: no snapshot directory left behind" "$leftover" "0"
check "killed push: no lock file left in the repository" "$(find "$FIX/.git" -name '*.lock' | wc -l | tr -d ' ')" "0"
check "killed push: core.bare untouched" "$(git -C "$FIX" config --local --get core.bare)" "false"
rm -f "$PROBE_DIR/hang.check_ok"
reset_probe
rc=0; out=$(cd "$LINKED" && git push origin feat/linked 2>&1) || rc=$?
check "re-push after a killed run: push succeeds" "$rc" "0"
case "$out" in "repo-lint pre-push: hook invoked for remote origin"*"checking committed tree"*"PASS"*) ok "re-push after a killed run runs the hook in full" ;; *) bad "re-push after a killed run: $out" ;; esac
if [ -f "$PROBE_DIR/ran.check_ok" ]; then ok "re-push after a killed run executed its checks"; else bad "re-push after a killed run executed no check"; fi
check "re-push after a killed run: remote receives the tip" "$(remote_tip feat/linked)" "$(git -C "$LINKED" rev-parse HEAD)"
git -C "$FIX" worktree remove --force "$LINKED"

# Hub-only: a checkout without the runner, and a consumer without the kit.
CONS="$TMP/consumer"
mkdir -p "$CONS/scripts/git-hooks"
cp "$HOOK" "$CONS/scripts/git-hooks/"
chmod +x "$CONS/scripts/git-hooks/pre-push"
git -C "$CONS" init -q -b main
git -C "$CONS" add -A
git -C "$CONS" commit -q -m base
git init -q --bare "$TMP/cons-remote.git"
git -C "$CONS" remote add origin "$TMP/cons-remote.git"
git -C "$CONS" config --local core.hooksPath scripts/git-hooks
rc=0; out=$(cd "$CONS" && git push origin main 2>&1) || rc=$?
check "checkout without the runner: push passes" "$rc" "0"
case "$out" in *"SKIP"*) ok "missing runner reports SKIP" ;; *) bad "missing runner output: $out" ;; esac
case "$out" in "repo-lint pre-push: hook invoked for remote origin"*) ok "missing runner still prints the invocation banner first" ;; *) bad "missing runner banner: $out" ;; esac
cp "$RUNNER" "$CONS/scripts/"
rc=0; out=$(cd "$CONS" && printf '' | bash scripts/repo-lint-prepush.sh --paths-from - 2>&1) || rc=$?
check "consumer without the scripts/ci kit: runner soft-passes" "$rc" "0"

echo "Part 3: one hook run per machine, load-sized jobs, stale snapshots (#2581)"

LOCK_DIR="$XDG_CACHE_HOME/mergepath"
LOCK_FILE="$LOCK_DIR/prepush.lock"
lock_field() { { sed -n "s/^$1=//p" "$LOCK_FILE" 2>/dev/null || true; } | head -n 1; }
peak_concurrency() { sort -n "$PROBE_DIR/concurrency" | tail -n 1; }
# A helper process that is not a job of this shell, so killing it later
# prints no termination notice. Prints its pid.
detach() { ( "$@" >/dev/null 2>&1 & printf '%s\n' "$!" ); }
slow_all() { for c in check_ok check_flag check_env; do touch "$PROBE_DIR/slow.$c"; done; }
wait_for_lock_field() {  # $1 = field, $2 = glob it must match; up to 60 s
  local i=0
  while [ "$i" -lt 600 ]; do
    # shellcheck disable=SC2254 # the caller passes a glob on purpose
    case "$(lock_field "$1")" in $2) return 0 ;; esac
    sleep 0.1; i=$((i + 1))
  done
  return 1
}

# Every Part 2 push took and released the lock: a clean release leaves an
# empty record, and the lock file itself stays (the flock lives on its inode).
check "a finished run leaves an empty lock record" "$(cat "$LOCK_FILE" 2>/dev/null)" ""
if [ -f "$LOCK_FILE" ]; then ok "the lock file itself survives a release"; else bad "the lock file was removed on release"; fi
help_out=$(bash "$RUNNER" --help)
for want in MERGEPATH_PREPUSH_LOCK_WAIT MERGEPATH_PREPUSH_LOCK_TOOL 'load average' 'take turns' 'fcntl'; do
  case "$help_out" in *"$want"*) ok "--help documents $want" ;; *) bad "--help omits $want" ;; esac
done

# Contention. Three slow live checks at jobs=1 hold the lock for about twelve
# seconds; a second push arriving meanwhile waits, names the holder, runs
# only after it, and both pushes land.
reset_probe; slow_all
commit_change feat/lock-a README.md
commit_change feat/lock-b README.md
(cd "$FIX" && MERGEPATH_PREPUSH_JOBS=1 git push origin feat/lock-a) > "$TMP/lock-a.out" 2>&1 &
A_PID=$!
if wait_for_lock_field branch feat/lock-a; then ok "the running hook records its branch in the lock file"; else bad "the lock record never named feat/lock-a: $(cat "$LOCK_FILE" 2>/dev/null)"; fi
holder_pid=$(lock_field pid)
case "$holder_pid" in ''|*[!0-9]*) bad "lock record pid: '$holder_pid'" ;; *) ok "the lock record carries the holder's pid" ;; esac
case "$(lock_field started)" in [0-9][0-9]:[0-9][0-9]' UTC') ok "the lock record carries the start time" ;; *) bad "lock record start time: '$(lock_field started)'" ;; esac
(cd "$FIX" && MERGEPATH_PREPUSH_JOBS=1 git push origin feat/lock-b) > "$TMP/lock-b.out" 2>&1 &
B_PID=$!
if wait_for_lock_field progress '[1-3] of 3'; then ok "the holder refreshes its progress per completed check"; else bad "the progress never advanced: $(cat "$LOCK_FILE" 2>/dev/null)"; fi
rc_a=0; wait "$A_PID" || rc_a=$?
rc_b=0; wait "$B_PID" || rc_b=$?
out=$(cat "$TMP/lock-b.out")
check "the first push passes" "$rc_a" "0"
check "a second push waits for the running hook, then succeeds" "$rc_b" "0"
case "$out" in *"waiting for the run of feat/lock-a (pid $holder_pid, started "[0-9][0-9]:[0-9][0-9]" UTC, "*) ok "the waiter names the holder's branch, pid and start time" ;; *) bad "waiter output: $out" ;; esac
case "$out" in *" UTC, "[0-9]*" of 3 checks)"*|*" UTC, preparing)"*) ok "the waiter reports the holder's progress" ;; *) bad "waiter progress: $out" ;; esac
check "both tips reached the remote" "$(remote_tip feat/lock-a) $(remote_tip feat/lock-b)" "$(git -C "$FIX" rev-parse feat/lock-a) $(git -C "$FIX" rev-parse feat/lock-b)"
check "the two runs' checks never overlapped" "$(peak_concurrency)" "1"
check "the waiter's checks all ran after the holder's" "$(sed -n '1,3p' "$PROBE_DIR/start-order" | sort | tr '\n' ' ')" "check_env check_flag check_ok "

# The python3 fcntl path is the one every macOS machine takes; a Linux runner
# has flock(1) and would otherwise never exercise it, so contention is
# repeated with that path forced.
reset_probe; slow_all
git -C "$FIX" checkout -q feat/lock-a && git -C "$FIX" commit -q --allow-empty -m py-hold
git -C "$FIX" checkout -q feat/lock-b && git -C "$FIX" commit -q --allow-empty -m py-wait
(cd "$FIX" && MERGEPATH_PREPUSH_LOCK_TOOL='python3' MERGEPATH_PREPUSH_JOBS=1 git push origin feat/lock-a) > "$TMP/lock-a-py.out" 2>&1 &
A_PID=$!
if wait_for_lock_field branch feat/lock-a; then ok "python3 fcntl lock: the holder records its branch"; else bad "python3 fcntl lock: no holder record: $(cat "$LOCK_FILE" 2>/dev/null)"; fi
holder_pid=$(lock_field pid)
rc=0; out=$(cd "$FIX" && MERGEPATH_PREPUSH_LOCK_TOOL='python3' MERGEPATH_PREPUSH_JOBS=1 git push origin feat/lock-b 2>&1) || rc=$?
check "python3 fcntl lock: a second push waits, then succeeds" "$rc" "0"
case "$out" in *"waiting for the run of feat/lock-a (pid $holder_pid, started "*) ok "python3 fcntl lock: the waiter names the holder" ;; *) bad "python3 fcntl lock waiter output: $out" ;; esac
rc_a=0; wait "$A_PID" || rc_a=$?
check "python3 fcntl lock: the holder passes" "$rc_a" "0"
check "python3 fcntl lock: the two runs' checks never overlapped" "$(peak_concurrency)" "1"
rc=0; out=$(cd "$FIX" && MERGEPATH_PREPUSH_LOCK_TOOL='mkdir' git push origin feat/lock-b:refs/heads/feat/lock-tool-bad 2>&1) || rc=$?
check "an unknown MERGEPATH_PREPUSH_LOCK_TOOL refuses the push" "$rc" "1"
case "$out" in *"MERGEPATH_PREPUSH_LOCK_TOOL must be flock or python3"*) ok "the unknown lock tool is named" ;; *) bad "unknown lock tool output: $out" ;; esac

# A flock-less host whose only usable interpreter is a versioned python3.13
# (python3 itself unusable) still takes the lock.
VPY="$TMP/versioned-py"
mkdir -p "$VPY"
printf '#!/bin/sh\nexit 1\n' > "$VPY/python3"
ln -s "$(command -v python3)" "$VPY/python3.13"
chmod +x "$VPY/python3"
reset_probe
git -C "$FIX" checkout -q feat/lock-a && git -C "$FIX" commit -q --allow-empty -m versioned-py
rc=0; out=$(cd "$FIX" && PATH="$VPY:$PATH" MERGEPATH_PREPUSH_LOCK_TOOL='python3' git push origin feat/lock-a 2>&1) || rc=$?
check "a versioned python3.13 alone is enough for the lock" "$rc" "0"
case "$out" in *"needs flock(1) or a python3 with fcntl"*) bad "the versioned interpreter was not found: $out" ;; *) ok "the lock found the versioned interpreter" ;; esac

# A supervisor killed mid-run leaves its started checks running, and they
# keep the lock: a waiting push starts only after they end.
# The first check hangs (the probe's hang.<check>, about two minutes), so the
# surviving worker plainly outlives its supervisor.
reset_probe
for c in check_ok check_flag check_env; do touch "$PROBE_DIR/hang.$c"; done
git -C "$FIX" checkout -q feat/lock-a && git -C "$FIX" commit -q --allow-empty -m killed-holder
git -C "$FIX" checkout -q feat/lock-b && git -C "$FIX" commit -q --allow-empty -m after-kill
(cd "$FIX" && MERGEPATH_PREPUSH_JOBS=1 git push origin feat/lock-a) > "$TMP/killed-a.out" 2>&1 &
A_PID=$!
i=0
hung_marker() { for f in "$PROBE_DIR"/hanging.*; do [ -e "$f" ] && { printf '%s\n' "${f##*/hanging.}"; return 0; }; done; return 1; }
until hung_marker >/dev/null || [ "$i" -ge 600 ]; do sleep 0.1; i=$((i + 1)); done
rm -f "$PROBE_DIR"/hang.*
fix_phys=$(cd "$FIX" && pwd -P)
sup=$(pgrep -o -f -- "--committed-snapshot --timings-root $fix_phys " || true)
if [ -n "$sup" ]; then ok "the holder's supervisor is running a check"; else bad "no supervisor found to kill"; fi
[ -z "$sup" ] || kill "$sup" 2>/dev/null || true
rc=0; out=$(cd "$FIX" && MERGEPATH_PREPUSH_JOBS=1 git push origin feat/lock-b 2>&1) || rc=$?
wait "$A_PID" 2>/dev/null || true
check "a push after a killed supervisor still succeeds" "$rc" "0"
hung=$(hung_marker || true)
if [ -n "$hung" ] && [ -f "$PROBE_DIR/unhung.$hung" ]; then ok "the killed supervisor's surviving check finished before the next push did"; else bad "the next push finished while the killed supervisor's $hung check was still running"; fi

# The wait is bounded: a waiter past MERGEPATH_PREPUSH_LOCK_WAIT gives up
# nonzero, says so, pushes nothing, and leaves the holder undisturbed.
reset_probe; slow_all
git -C "$FIX" checkout -q feat/lock-a && git -C "$FIX" commit -q --allow-empty -m hold
git -C "$FIX" checkout -q feat/lock-b && git -C "$FIX" commit -q --allow-empty -m late
(cd "$FIX" && MERGEPATH_PREPUSH_JOBS=1 git push origin feat/lock-a) > "$TMP/lock-a2.out" 2>&1 &
A_PID=$!
wait_for_lock_field branch feat/lock-a || bad "the second holder never recorded itself"
before_b=$(remote_tip feat/lock-b)
rc=0; out=$(cd "$FIX" && MERGEPATH_PREPUSH_LOCK_WAIT=2 git push origin feat/lock-b 2>&1) || rc=$?
if [ "$rc" -ne 0 ]; then ok "a waiter past MERGEPATH_PREPUSH_LOCK_WAIT gives up nonzero (exit $rc)"; else bad "the waiter did not give up"; fi
case "$out" in *"gave up after "*" s waiting for the run of feat/lock-a (pid "*"MERGEPATH_PREPUSH_LOCK_WAIT"*) ok "the give-up message names the holder and the bound" ;; *) bad "give-up output: $out" ;; esac
check "the push that gave up did not reach the remote" "$(remote_tip feat/lock-b)" "$before_b"
rc_a=0; wait "$A_PID" || rc_a=$?
check "the holder is undisturbed by a waiter that gave up" "$rc_a" "0"
check "the undisturbed holder's tip reached the remote" "$(remote_tip feat/lock-a)" "$(git -C "$FIX" rev-parse feat/lock-a)"
check "a waiter that gave up ran no check" "$(peak_concurrency)" "1"

# A killed run leaves its record behind; the kernel has already dropped its
# flock. The next run says whose record it found and proceeds.
dead_pid=$(bash -c 'echo $$')
printf 'branch=feat/ghost\npid=%s\nstarted=00:00 UTC\nprogress=1 of 9\n' "$dead_pid" > "$LOCK_FILE"
reset_probe
commit_change feat/reap README.md
rc=0; out=$(cd "$FIX" && git push origin feat/reap 2>&1) || rc=$?
check "a dead holder's lock is reaped and the push proceeds" "$rc" "0"
case "$out" in *"reaping the lock record of pid $dead_pid (feat/ghost), which is no longer running"*) ok "the reaped holder is named" ;; *) bad "reap output: $out" ;; esac
check "the reaped record is replaced, then released" "$(cat "$LOCK_FILE")" ""
# A live process that is not a hook run (the kernel reused the pid) holds nothing either.
SLEEPER=$(detach sleep 300)
printf 'branch=feat/reused\npid=%s\nstarted=00:00 UTC\nprogress=preparing\n' "$SLEEPER" > "$LOCK_FILE"
reset_probe
git -C "$FIX" commit -q --allow-empty -m reused
rc=0; out=$(cd "$FIX" && git push origin feat/reap 2>&1) || rc=$?
kill "$SLEEPER" 2>/dev/null || true
check "a reused pid that is not a hook run does not hold the lock" "$rc" "0"
case "$out" in *"reaping the lock record of pid $SLEEPER (feat/reused), which is no longer running"*) ok "the reused pid is reaped by name" ;; *) bad "reused-pid output: $out" ;; esac


# Snapshot hygiene under the lock. The hook keeps its snapshots beside the
# primary checkout, in a hidden folder named after it, as detached
# prepush-<12 hex of the tip>.XXXXXX checkouts at that tip. One nobody is
# working in is retired; one a (pre-lock) `--committed-snapshot` run is
# working in is left alone; a worktree that is not positively a tool snapshot
# (a branch checkout named prepush-debug with uncommitted work, a detached
# checkout whose name does not match its commit) is never touched.
SNAPS=$(cd "$TMP/.fix-worktrees" && pwd -P)
MAIN12=$(git -C "$FIX" rev-parse main | cut -c1-12)
git -C "$FIX" worktree add -q --detach "$SNAPS/prepush-$MAIN12.stale0" main
git -C "$FIX" worktree add -q --detach "$SNAPS/prepush-$MAIN12.busy00" main
git -C "$FIX" worktree add -q --detach "$SNAPS/prepush-000000000000.wrong0" main
git -C "$FIX" worktree add -q -b prepush-debug "$SNAPS/prepush-debug" main
printf 'uncommitted work\n' >> "$SNAPS/prepush-debug/README.md"
printf 'scratch\n' > "$SNAPS/prepush-debug/notes.txt"
git -C "$FIX" worktree add -q -b other/session "$SNAPS/other-session" main
# An unrelated worktree that is temporarily unavailable, and a tool snapshot
# whose directory is gone: neither registration may be pruned.
git -C "$FIX" worktree add -q -b other/away "$TMP/away-checkout" main
mv "$TMP/away-checkout" "$TMP/away-checkout.moved"
git -C "$FIX" worktree add -q --detach "$SNAPS/prepush-$MAIN12.gone00" main
rm -rf "$SNAPS/prepush-$MAIN12.gone00"
# shellcheck disable=SC2016 # the $1 is the inner bash's, not ours
BUSY_PID=$(detach bash -c 'cd "$1" && sleep 300; :' --committed-snapshot "$SNAPS/prepush-$MAIN12.busy00")
# Wait until that process has actually changed into the snapshot (bounded).
busy_cwd() {
  if [ -d /proc/self ]; then readlink "/proc/$BUSY_PID/cwd" 2>/dev/null || true
  else { lsof -a -p "$BUSY_PID" -d cwd -Fn 2>/dev/null || true; } | sed -n 's/^n//p'; fi
}
i=0
until [ "$(busy_cwd)" = "$SNAPS/prepush-$MAIN12.busy00" ] || [ "$i" -ge 100 ]; do sleep 0.1; i=$((i + 1)); done
check "the busy process is working in its snapshot before the push" "$(busy_cwd)" "$SNAPS/prepush-$MAIN12.busy00"
reset_probe
commit_change feat/snapshots README.md
rc=0; out=$(cd "$FIX" && git push origin feat/snapshots 2>&1) || rc=$?
pkill -P "$BUSY_PID" 2>/dev/null || true; kill "$BUSY_PID" 2>/dev/null || true
check "a push with leftover snapshots around succeeds" "$rc" "0"
case "$out" in *"retired stale snapshot "*"/prepush-$MAIN12.stale0 (left by an interrupted run)"*) ok "the stale snapshot is retired, with a message" ;; *) bad "retirement output: $out" ;; esac
if [ ! -d "$SNAPS/prepush-$MAIN12.stale0" ]; then ok "the stale snapshot directory is gone"; else bad "the stale snapshot directory remains"; fi
case "$out" in *"leaving snapshot "*"/prepush-$MAIN12.busy00: a hook run is still working in it"*) ok "a snapshot a run is working in is left alone, with a message" ;; *) bad "busy snapshot output: $out" ;; esac
if [ -d "$SNAPS/prepush-$MAIN12.busy00" ]; then ok "the busy snapshot directory survives"; else bad "the busy snapshot was removed"; fi
case "$out" in *"leaving "*"/prepush-debug: not a snapshot this tool made"*) ok "a branch checkout under the snapshots folder is named as not the tool's" ;; *) bad "prepush-debug output: $out" ;; esac
if [ -d "$SNAPS/prepush-debug" ] && [ "$(tail -n 1 "$SNAPS/prepush-debug/README.md")" = "uncommitted work" ] && [ -f "$SNAPS/prepush-debug/notes.txt" ]; then ok "a dirty branch checkout named prepush-debug survives with its work intact"; else bad "the prepush-debug checkout or its uncommitted work was removed"; fi
if [ -d "$SNAPS/prepush-000000000000.wrong0" ]; then ok "a detached checkout whose name does not match its commit survives"; else bad "the mismatched-name checkout was removed"; fi
if [ -d "$SNAPS/other-session" ]; then ok "another checkout beside the snapshots is untouched"; else bad "the other checkout was removed"; fi
registered=$(git -C "$FIX" worktree list --porcelain | sed -n 's/^worktree //p')
case "$registered" in *"prepush-$MAIN12.stale0"*) bad "the stale snapshot is still registered" ;; *) ok "the stale snapshot is unregistered" ;; esac
case "$registered" in *"prepush-$MAIN12.busy00"*) ok "the busy snapshot stays registered" ;; *) bad "the busy snapshot was unregistered" ;; esac
case "$registered" in *prepush-debug*) ok "the branch checkout stays registered" ;; *) bad "the branch checkout was unregistered" ;; esac
case "$registered" in *other-session*) ok "the other checkout stays registered" ;; *) bad "the other checkout was unregistered" ;; esac
case "$registered" in *away-checkout*) ok "an unavailable unrelated worktree keeps its registration" ;; *) bad "an unavailable unrelated worktree was pruned" ;; esac
case "$out" in *"leaving the registration of missing snapshot "*"/prepush-$MAIN12.gone00"*) ok "a missing snapshot's registration is left, with a message" ;; *) bad "missing snapshot output: $out" ;; esac
mv "$TMP/away-checkout.moved" "$TMP/away-checkout"
# A process inspection that fails is not evidence of an unused snapshot: with
# pgrep failing, a free owned snapshot is left alone and says why.
FAKEPS="$TMP/fakeps"
mkdir -p "$FAKEPS"
printf '#!/bin/sh\necho "pgrep: cannot enumerate processes" >&2\nexit 2\n' > "$FAKEPS/pgrep"
chmod +x "$FAKEPS/pgrep"
git -C "$FIX" worktree add -q --detach "$SNAPS/prepush-$MAIN12.stale1" main
reset_probe
git -C "$FIX" commit -q --allow-empty -m inspection-fails
rc=0; out=$(cd "$FIX" && PATH="$FAKEPS:$PATH" git push origin feat/snapshots 2>&1) || rc=$?
check "a failing process inspection does not block the push" "$rc" "0"
case "$out" in *"leaving snapshot "*"/prepush-$MAIN12.stale1: a hook run is still working in it, or that cannot be established"*) ok "a free snapshot is left alone when liveness cannot be established" ;; *) bad "inspection-failure output: $out" ;; esac
if [ -d "$SNAPS/prepush-$MAIN12.stale1" ]; then ok "the snapshot survives a failed inspection"; else bad "the snapshot was removed on a failed inspection"; fi
# With inspection working again the same snapshot is retired.
reset_probe
git -C "$FIX" commit -q --allow-empty -m inspection-works
rc=0; out=$(cd "$FIX" && git push origin feat/snapshots 2>&1) || rc=$?
check "the next push with working inspection succeeds" "$rc" "0"
case "$out" in *"retired stale snapshot "*"/prepush-$MAIN12.stale1 (left by an interrupted run)"*) ok "the same snapshot is retired once liveness can be established" ;; *) bad "post-inspection output: $out" ;; esac
git -C "$FIX" worktree remove --force "$SNAPS/prepush-$MAIN12.busy00" 2>/dev/null || true
git -C "$FIX" worktree remove --force "$SNAPS/prepush-000000000000.wrong0" 2>/dev/null || true

# The default parallelism follows the machine. A fake sysctl/nproc first on
# PATH reports 4 CPUs and the load each push chooses; the running line
# prints both.
FAKEBIN="$TMP/fakebin"
mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/sysctl" <<'SH'
#!/bin/sh
case "$2" in
  hw.ncpu) echo 4 ;;
  vm.loadavg) echo "{ ${FAKE_LOAD:-0.50} 0.00 0.00 }" ;;
  *) exit 1 ;;
esac
SH
printf '#!/bin/sh\necho 4\n' > "$FAKEBIN/nproc"
chmod +x "$FAKEBIN/sysctl" "$FAKEBIN/nproc"
reset_probe; slow_all
commit_change feat/load README.md
rc=0; out=$(cd "$FIX" && PATH="$FAKEBIN:$PATH" FAKE_LOAD=0.50 git push origin feat/load 2>&1) || rc=$?
check "quiet machine: push succeeds" "$rc" "0"
case "$out" in *"(jobs=2, nice=10, host load 0.50 on 4 CPUs)"*) ok "load below the CPU count defaults to jobs=2, and both are printed" ;; *) bad "quiet-machine running line: $out" ;; esac
check "quiet machine: two checks run at once" "$(peak_concurrency)" "2"
reset_probe; slow_all
git -C "$FIX" commit -q --allow-empty -m loaded
rc=0; out=$(cd "$FIX" && PATH="$FAKEBIN:$PATH" FAKE_LOAD=4.00 git push origin feat/load 2>&1) || rc=$?
check "loaded machine: push succeeds" "$rc" "0"
case "$out" in *"(jobs=1, nice=10, host load 4.00 on 4 CPUs)"*) ok "load at the CPU count defaults to jobs=1, and both are printed" ;; *) bad "loaded-machine running line: $out" ;; esac
check "loaded machine: checks run one at a time" "$(peak_concurrency)" "1"
reset_probe; slow_all
git -C "$FIX" commit -q --allow-empty -m override
rc=0; out=$(cd "$FIX" && PATH="$FAKEBIN:$PATH" FAKE_LOAD=512.25 MERGEPATH_PREPUSH_JOBS=2 git push origin feat/load 2>&1) || rc=$?
check "MERGEPATH_PREPUSH_JOBS overrides the load-derived default" "$rc" "0"
case "$out" in *"(jobs=2, nice=10, host load 512.25 on 4 CPUs)"*) ok "the override is printed beside the load" ;; *) bad "override running line: $out" ;; esac
check "override: two checks run at once" "$(peak_concurrency)" "2"

echo "Part 4: --retry-failed re-runs only what failed for the same commit and selection (#2843)"

RESULTS_DIR="$XDG_CACHE_HOME/mergepath/prepush-results"
REC="$RESULTS_DIR/feat_retry.tsv"
help_out=$(bash "$RUNNER" --help)
for want in --retry-failed MERGEPATH_PREPUSH_RETRY_FAILED prepush-results; do
  case "$help_out" in *"$want"*) ok "--help documents $want" ;; *) bad "--help omits $want" ;; esac
done
ran_set() { for c in check_env check_flag check_graphed check_ok; do [ ! -f "$PROBE_DIR/ran.$c" ] || printf '%s ' "$c"; done; }
rec_rc() { awk -F'\t' -v n="$1" '$1 == "step" && $4 == n { print $3 }' "$REC" 2>/dev/null; }
retry_push() { (cd "$FIX" && MERGEPATH_PREPUSH_RETRY_FAILED=1 "$@" git push origin feat/retry 2>&1); }

# A failing push records every selected check's result for its branch,
# with the commit it checked, and says how to retry.
reset_probe; touch "$PROBE_DIR/FLAG"
commit_change feat/retry README.md
rc=0; out=$(cd "$FIX" && git push origin feat/retry 2>&1) || rc=$?
check "retry: the recorded push fails on check_flag" "$rc" "1"
if [ -f "$REC" ]; then ok "a hook run records its results under the cache directory"; else bad "no record at $REC"; fi
check "the record names the pushed commit" "$(awk -F'\t' '$1 == "commit" { print $2 }' "$REC" 2>/dev/null)" "$(git -C "$FIX" rev-parse HEAD)"
check "the record holds each check's result" "$(rec_rc check_ok) $(rec_rc check_flag) $(rec_rc check_env)" "0 1 0"
case "$out" in *"MERGEPATH_PREPUSH_RETRY_FAILED=1 git push"*) ok "a failed push names the retry" ;; *) bad "no retry hint: $out" ;; esac

# Same commit and selection: only the failed check runs, and the push passes
# once it does.
rm -f "$PROBE_DIR/FLAG"; reset_probe
rc=0; out=$(retry_push) || rc=$?
check "retry: the push passes once the failed check passes" "$rc" "0"
check "retry: only the failed check ran" "$(ran_set)" "check_flag "
check "retry: the remote has the commit" "$(remote_tip feat/retry)" "$(git -C "$FIX" rev-parse HEAD)"
case "$out" in *"--retry-failed: re-running the 1 of 3 checks that did not pass in the recorded run of $(git -C "$FIX" rev-parse HEAD)"*) ok "the retry names what it re-runs and what it builds on" ;; *) bad "retry output: $out" ;; esac
check "the retry rewrites the record with the new result" "$(rec_rc check_ok) $(rec_rc check_flag) $(rec_rc check_env)" "0 0 0"

# Every check passed in the record: nothing is re-run, and the run passes.
# (git skips the hook when the remote already has the commit, so the hook
# is invoked directly with git's pre-push line.)
reset_probe
sha=$(git -C "$FIX" rev-parse HEAD)
rc=0; out=$(cd "$FIX" && MERGEPATH_PREPUSH_RETRY_FAILED=1 bash scripts/repo-lint-prepush.sh --hook origin <<<"refs/heads/feat/retry $sha refs/heads/feat/retry $ZERO" 2>&1) || rc=$?
check "retry of an all-pass record passes" "$rc" "0"
check "retry of an all-pass record runs nothing" "$(ran_set)" ""

# A recorded failure that still fails still blocks the push.
reset_probe; touch "$PROBE_DIR/FLAG"
git -C "$FIX" commit -q --allow-empty -m retry-still-failing
rc=0; out=$(cd "$FIX" && git push origin feat/retry 2>&1) || rc=$?
check "retry: a second recorded push fails" "$rc" "1"
reset_probe; touch "$PROBE_DIR/FLAG"
rc=0; out=$(retry_push) || rc=$?
check "retry: a still-failing check blocks the push" "$rc" "1"
check "retry: only the failed check ran again" "$(ran_set)" "check_flag "
check "retry: a blocked retry leaves the remote unchanged" "$(remote_tip feat/retry)" "$(git -C "$FIX" rev-parse HEAD~1)"

# The commit changed since the recorded run: the retry is refused and the
# full selection runs.
recorded=$(git -C "$FIX" rev-parse HEAD)
git -C "$FIX" commit -q --allow-empty -m retry-new-commit
rm -f "$PROBE_DIR/FLAG"; reset_probe
rc=0; out=$(retry_push) || rc=$?
check "changed commit: the full selection passes the push" "$rc" "0"
check "changed commit: every live check ran" "$(ran_set)" "check_env check_flag check_ok "
case "$out" in *"--retry-failed: the commit changed since the recorded run (recorded $recorded, pushing $(git -C "$FIX" rev-parse HEAD)); running the full selection"*) ok "changed commit: the refusal names both commits" ;; *) bad "changed-commit output: $out" ;; esac

# The selection changed (MERGEPATH_PREPUSH_LIVE=all adds the unselected
# wrapper): the retry is refused and the full, new selection runs.
reset_probe; touch "$PROBE_DIR/FLAG"
git -C "$FIX" commit -q --allow-empty -m retry-selection
rc=0; out=$(cd "$FIX" && git push origin feat/retry 2>&1) || rc=$?
check "changed selection: the recorded push fails" "$rc" "1"
rm -f "$PROBE_DIR/FLAG"; reset_probe
rc=0; out=$(retry_push env MERGEPATH_PREPUSH_LIVE=all) || rc=$?
check "changed selection: the full selection passes the push" "$rc" "0"
check "changed selection: every check of the new selection ran" "$(ran_set)" "check_env check_flag check_graphed check_ok "
case "$out" in *"--retry-failed: the selection changed since the recorded run of "*"; running the full selection"*) ok "changed selection: the refusal says so" ;; *) bad "changed-selection output: $out" ;; esac

# An incomplete record (a run cut short mid-write) is not a pass.
reset_probe; touch "$PROBE_DIR/FLAG"
git -C "$FIX" commit -q --allow-empty -m retry-malformed
rc=0; out=$(cd "$FIX" && git push origin feat/retry 2>&1) || rc=$?
sed -i.bak '/^end$/d' "$REC" && rm -f "$REC.bak"
reset_probe; touch "$PROBE_DIR/FLAG"
rc=0; out=$(retry_push) || rc=$?
check "malformed record: the push is still blocked" "$rc" "1"
check "malformed record: the full selection ran" "$(ran_set)" "check_env check_flag check_ok "
case "$out" in *"is incomplete or malformed; running the full selection"*) ok "malformed record: the refusal says so" ;; *) bad "malformed-record output: $out" ;; esac

# A manual run checks the working tree, so it has nothing to retry.
rm -f "$PROBE_DIR/FLAG"; reset_probe
rc=0; out=$(cd "$FIX" && bash scripts/repo-lint-prepush.sh --retry-failed 2>&1) || rc=$?
check "manual --retry-failed: the full selection passes" "$rc" "0"
check "manual --retry-failed: every live check ran" "$(ran_set)" "check_env check_flag check_ok "
case "$out" in *"--retry-failed: a manual run checks the working tree"*) ok "manual --retry-failed: the refusal says why" ;; *) bad "manual retry output: $out" ;; esac

# A missing record runs the full selection, and a still-failing check still
# blocks. The scenario runs once with the runner and once with a mutant that
# reads a missing record as "nothing failed"; the mutant must pass the push,
# so the assertions on the real runner discriminate that defect.
missing_record_retry() {  # $1 = runner, $2 = label; prints the exit status
  local sha rc=0
  git -C "$FIX" commit -q --allow-empty -m "retry-missing-$2"
  sha=$(git -C "$FIX" rev-parse HEAD)
  rm -f "$REC"
  reset_probe; touch "$PROBE_DIR/FLAG"
  (cd "$FIX" && MERGEPATH_PREPUSH_RETRY_FAILED=1 bash "$1" --hook origin <<<"refs/heads/feat/retry $sha refs/heads/feat/retry $ZERO") \
    > "$TMP/missing-$2.out" 2>&1 || rc=$?
  printf '%s\n' "$rc"
}
rc=$(missing_record_retry "$FIX/scripts/repo-lint-prepush.sh" real)
check "missing record: a failing check still blocks the push" "$rc" "1"
check "missing record: the full selection ran" "$(ran_set)" "check_env check_flag check_ok "
case "$(cat "$TMP/missing-real.out")" in *"--retry-failed: no recorded run of this branch to retry; running the full selection"*) ok "missing record: the refusal says so" ;; *) bad "missing-record output: $(cat "$TMP/missing-real.out")" ;; esac
MUTANT="$TMP/mutant/repo-lint-prepush.sh"
mkdir -p "$TMP/mutant"
python3 - "$RUNNER" "$MUTANT" <<'PY'
import sys
src = open(sys.argv[1]).read()
old = '    RETRY_NOTE="no recorded run of this branch to retry"\n    return 1\n'
new = ('    awk -v n="$SEL_TOTAL" \'BEGIN { for (i = 1; i <= n; i++) printf "%03d\\t0\\n", i }\' > "$RUN_DIR/retry.prior"\n'
       '    return 0\n')
open(sys.argv[2], 'w').write(src.replace(old, new, 1))
PY
rc=$(missing_record_retry "$MUTANT" mutant)
if ! cmp -s "$MUTANT" "$RUNNER" && [ "$rc" = 0 ] && [ -z "$(ran_set)" ]; then
  ok "mutation: reading a missing record as a pass lets the failing push through, so the assertions above discriminate"
else
  bad "mutation: expected the mutant to pass the push without running anything (rc=$rc, ran: $(ran_set))"
fi
git -C "$FIX" checkout -q main

echo ""
echo "test_repo_lint_prepush: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
