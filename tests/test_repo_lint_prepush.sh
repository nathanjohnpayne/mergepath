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
#
# Part 2, behaviour, through real `git push` into a bare remote with the hook
# installed by scripts/install-git-hooks.sh: a failing selected check blocks
# the push, a passing run lets it through, both bypasses work, the deep lane
# runs only on opt-in, the concurrency cap and nice level hold, no GIT_*
# variable leaks into a check, and the hub-only soft-passes.
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
unset MERGEPATH_PREPUSH_SKIP MERGEPATH_PREPUSH_DEEP MERGEPATH_PREPUSH_JOBS MERGEPATH_PREPUSH_NICE GITHUB_OUTPUT 2>/dev/null || true
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

# id | branch | ;-separated changed paths
CASES='docs|feat/docs|README.md;docs/guide.md
script|feat/script|scripts/coderabbit-wait.sh
wrapper|feat/wrapper|scripts/ci/check_cockpit
fastonly|feat/fastonly|scripts/ci/check_bootstrap_sh
governance|feat/governance|docs/agents/testing-requirements.md
replay|feat/replay|.mergepath-sync.yml
full|feat/full|scripts/ci/repo-lint-scope.sh
unknown|feat/unknown|scripts/brand-new-tool.sh
prose|feat/prose|scripts/ci/README.md;tests/README.md
sync|mergepath-sync/wave-1|README.md
mixed|feat/mixed|scripts/ci/check_doc_ownership;scripts/merge-clearance-gate.sh;BRAND.md
self|feat/self|scripts/repo-lint-prepush.sh;scripts/git-hooks/pre-push;tests/test_repo_lint_prepush.sh'

while IFS='|' read -r id branch paths; do
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
    | (cd "$HUB" && bash scripts/repo-lint-prepush.sh --hook origin "$REMOTE" --plan) > "$TMP/plan.$id"

  ci_scope=$(sort "$TMP/ci_scope.$id" | tr '\n' ' ')
  hook_scope=$(sed -n 's/^scope\t//p' "$TMP/plan.$id" | tr ' ' '\n' | sed '/^$/d' | sort | tr '\n' ' ')
  check "[$id] scope bits equal the CI scope job" "$hook_scope" "$ci_scope"

  # (a) Coverage: every check step CI executes is in exactly the hook's plan
  # (live, selected, unselected or deep lane), nothing more.
  python3 -I "$TMP/ci_eval.py" "$TMP/jobs.json" "$TMP/ci_scope.$id" | expected_hook_steps > "$TMP/ci_steps.$id"
  awk -F'\t' '$1 != "scope" { print $2 "\t" $3 }' "$TMP/plan.$id" | LC_ALL=C sort -u > "$TMP/hook_steps.$id"
  if diff -u "$TMP/ci_steps.$id" "$TMP/hook_steps.$id" > "$TMP/diff.$id"; then
    ok "[$id] the plan covers exactly the check steps CI executes ($(wc -l < "$TMP/hook_steps.$id" | tr -d ' '))"
  else
    bad "[$id] the plan differs from the check steps CI executes (- CI, + hook):"
    sed 's/^/        /' "$TMP/diff.$id"
  fi

  # (b) Deep lane: the self-test and harness steps the hook selects are the
  # deep-job steps whose if: expressions CI evaluates true.
  awk -F'\t' '$1 != "lint_fast"' "$TMP/ci_steps.$id" > "$TMP/ci_deep.$id"
  awk -F'\t' '$1 == "deep" { print $2 "\t" $3 }' "$TMP/plan.$id" | LC_ALL=C sort -u > "$TMP/hook_deep.$id"
  if diff -u "$TMP/ci_deep.$id" "$TMP/hook_deep.$id" > "$TMP/diff.$id"; then
    ok "[$id] deep-lane selection equals CI's ($(wc -l < "$TMP/hook_deep.$id" | tr -d ' ') steps)"
  else
    bad "[$id] deep-lane selection differs from CI's (- CI, + hook):"
    sed 's/^/        /' "$TMP/diff.$id"
  fi

  # (c) Wrappers: the fast-lane wrappers the hook runs as `selected` are the
  # CI scope job's `checks` (every graph wrapper when CI selects the
  # complete surface), and the always-run `live` lane holds no graph wrapper.
  ci_full=$(sed -n 's/^full=//p' "$TMP/ci_scope.$id")
  ci_checks=$(sed -n 's/^checks=//p' "$TMP/ci_scope.$id")
  jq -r --argjson checks "$ci_checks" --argjson full "$ci_full" \
     --argjson graph "$(jq -c '.wrappers | keys' "$HUB/scripts/ci/repo-lint-dependencies.json")" '
    [.lint_fast.steps[] | select((.if // "") | test("^matrix\\.shard == "))
      | [(.run // "") | capture("^\\./scripts/ci/(?<w>check_[A-Za-z0-9_]+)") | .w] | first
      | . as $w
      | select($w != null and ($graph | index($w)) != null)
      | select($full or ($checks | index($w)) != null)] | unique | .[]' "$TMP/jobs.json" > "$TMP/ci_wrappers.$id"
  awk -F'\t' '$1 == "selected" { print $3 }' "$TMP/plan.$id" > "$TMP/hook_sel_names.$id"
  jq -r --rawfile names "$TMP/hook_sel_names.$id" '
    ($names | split("\n") | map(select(length > 0))) as $n
    | [.lint_fast.steps[] | select(.name as $x | $n | index($x) != null)
      | [(.run // "") | capture("^\\./scripts/ci/(?<w>check_[A-Za-z0-9_]+)") | .w] | first] | unique | .[]' \
    "$TMP/jobs.json" > "$TMP/hook_wrappers.$id"
  check "[$id] selected fast-lane wrappers equal the CI scope job's checks" \
    "$(tr '\n' ' ' < "$TMP/hook_wrappers.$id")" "$(tr '\n' ' ' < "$TMP/ci_wrappers.$id")"
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
check "script case selects exactly its self-test" \
  "$(awk -F'\t' '$2 == "deep_self_tests" { print $3 }' "$TMP/plan.script" | tr '\n' ' ')" "check_coderabbit_wait --self-test "
check "full case selects the consumer replay" "$(grep -c 'deep_consumer_replay' "$TMP/plan.full" || true)" "1"

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
touch "$out/ran.$1"
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

# The fixture checks need no Python; a stub stands in for an interpreter
# with CI's packages, and a failing one for an interpreter without them.
printf '#!/bin/sh\nexit 0\n' > "$TMP/python-ok"
printf '#!/bin/sh\nexit 1\n' > "$TMP/python-bad"
chmod +x "$TMP/python-ok" "$TMP/python-bad"
export MERGEPATH_PREPUSH_PYTHON="$TMP/python-ok"

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
commit_change feat/pass README.md
rc=0; out=$(cd "$FIX" && MERGEPATH_PREPUSH_JOBS=1 git push origin feat/pass 2>&1) || rc=$?
check "passing checks: push succeeds" "$rc" "0"
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
base_nice=$(ps -o nice= -p $$ | tr -d ' ')
want_nice=$((base_nice + 10)); [ "$want_nice" -le 20 ] || want_nice=20
check "checks run 10 nice levels below the push" "$(cat "$PROBE_DIR/nice.check_ok")" "$want_nice"

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

# A failing selected check blocks the push and names the check.
reset_probe
touch "$PROBE_DIR/FLAG"
commit_change feat/fail README.md
rc=0; out=$(cd "$FIX" && git push origin feat/fail 2>&1) || rc=$?
[ "$rc" -ne 0 ] && ok "failing check: push blocked (exit $rc)" || bad "failing check: push was not blocked"
check "failing check: remote not updated" "$(remote_tip feat/fail)" "none"
case "$out" in *"FAIL  check_flag"*) ok "failing check is named" ;; *) bad "failing check not named: $out" ;; esac
case "$out" in *"--no-verify"*"MERGEPATH_PREPUSH_SKIP=1"*) ok "bypass is documented in the failure" ;; *) bad "bypass hint missing" ;; esac

# The checkout must be the pushed commit: a dirty tracked file, or a push
# of a branch other than HEAD, is refused rather than tested.
reset_probe
rm -f "$PROBE_DIR/FLAG"
git -C "$FIX" checkout -q feat/pass
printf 'dirty\n' >> "$FIX/README.md"
rc=0; out=$(cd "$FIX" && git push origin feat/pass:refs/heads/feat/dirty 2>&1) || rc=$?
check "dirty tracked file: push refused" "$rc" "1"
case "$out" in *"uncommitted changes"*) ok "dirty refusal says why" ;; *) bad "dirty refusal output: $out" ;; esac
check "dirty tracked file: remote not updated" "$(remote_tip feat/dirty)" "none"
git -C "$FIX" checkout -q -- README.md
git -C "$FIX" checkout -q main
rc=0; out=$(cd "$FIX" && git push origin feat/pass:refs/heads/feat/other 2>&1) || rc=$?
check "push of a non-HEAD tip: refused" "$rc" "1"
case "$out" in *"the checkout is at"*) ok "non-HEAD refusal says why" ;; *) bad "non-HEAD refusal output: $out" ;; esac
[ ! -f "$PROBE_DIR/ran.check_ok" ] && ok "refused pushes run no checks" || bad "a refused push ran checks"
git -C "$FIX" checkout -q feat/fail
touch "$PROBE_DIR/FLAG"

# Missing CI Python packages are an environment error, not a pass.
rc=0; out=$(cd "$FIX" && MERGEPATH_PREPUSH_PYTHON="$TMP/python-bad" git push origin feat/fail:refs/heads/feat/nopy 2>&1) || rc=$?
check "missing CI Python packages: push refused" "$rc" "1"
case "$out" in *"no python3 with the CI packages"*) ok "missing packages are named" ;; *) bad "missing packages output: $out" ;; esac

# Both bypasses.
rc=0; out=$(cd "$FIX" && MERGEPATH_PREPUSH_SKIP=1 git push origin feat/fail 2>&1) || rc=$?
check "MERGEPATH_PREPUSH_SKIP=1 bypasses" "$rc" "0"
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
cp "$RUNNER" "$CONS/scripts/"
rc=0; out=$(cd "$CONS" && printf '' | bash scripts/repo-lint-prepush.sh --paths-from - 2>&1) || rc=$?
check "consumer without the scripts/ci kit: runner soft-passes" "$rc" "0"

echo ""
echo "test_repo_lint_prepush: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
