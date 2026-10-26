#!/usr/bin/env bash
# tests/test_pull_request_target_policy.sh
#
# Regression suite for scripts/workflow/pull-request-target-policy.py, the
# explicit Actions event policies that keep the propagated pull_request_target
# workflows running after GitHub enforces its default policy on 2026-11-02
# (nathanjohnpayne/mergepath#2733).
#
# Part 1 lints this checkout, then mutated copies of the real workflows: an
# unregistered pull_request_target workflow, a trigger added to a registered
# one, and each way of running candidate code must fail. Every lint case runs
# under PyYAML when it imports and again under the yq fallback when yq exists.
# Part 2 pins the policy bodies. Part 3 runs verify against a PATH-shimmed
# `gh` serving canned policy and contents responses. Part 4 runs plan.
# Hermetic: no token, no network.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOL="$ROOT/scripts/workflow/pull-request-target-policy.py"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/prt-policy.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0
pass() { echo "PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $*" >&2; FAIL=$((FAIL + 1)); }

[ -x "$TOOL" ] || { echo "FAIL: missing executable $TOOL" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "FAIL: jq is required" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "FAIL: python3 is required" >&2; exit 1; }

# Parser modes: "pyyaml" when it imports, "yq" (PyYAML hidden behind a stub
# module that refuses to import) when yq exists. At least one must exist.
NOYAML="$TMP/noyaml"
mkdir -p "$NOYAML"
printf 'raise ImportError("hidden by the suite")\n' > "$NOYAML/yaml.py"
MODES=()
python3 -c 'import yaml' >/dev/null 2>&1 && MODES+=(pyyaml)
command -v yq >/dev/null 2>&1 && MODES+=(yq)
if [ "${#MODES[@]}" -eq 0 ]; then
  echo "FAIL: neither PyYAML nor yq is available; the tool cannot parse workflows" >&2
  exit 1
fi

run_tool() { # run_tool <mode> args... ; prints output, returns the tool's status
  local mode="$1"; shift
  if [ "$mode" = yq ]; then
    PYTHONPATH="$NOYAML" python3 "$TOOL" "$@"
  else
    python3 "$TOOL" "$@"
  fi
}

expect() { # expect <desc> <want-rc> <grep-pattern|""> <mode> args...
  local desc="$1" want="$2" pattern="$3" mode="$4"; shift 4
  local out rc=0
  out="$(run_tool "$mode" "$@" 2>&1)" || rc=$?
  if [ "$rc" != "$want" ]; then
    fail "$desc [$mode]: exit $rc, want $want"; printf '%s\n' "$out" >&2; return
  fi
  if [ -n "$pattern" ] && ! printf '%s\n' "$out" | grep -Eq -- "$pattern"; then
    fail "$desc [$mode]: output lacks /$pattern/"; printf '%s\n' "$out" >&2; return
  fi
  pass "$desc [$mode]"
}

# --- Part 1: lint -------------------------------------------------------------

REAL_WF="$ROOT/.github/workflows"
AC=auto-clear-blocking-labels.yml
DA=dependabot-auto-merge.yml
MQ=merge-queue-authorization.yml

fresh_tree() { # fresh_tree <name>: a root holding copies of the three real workflows
  local dir="$TMP/lint/$1"
  mkdir -p "$dir/.github/workflows"
  cp "$REAL_WF/$AC" "$REAL_WF/$DA" "$REAL_WF/$MQ" "$dir/.github/workflows/"
  printf '%s\n' "$dir"
}

# edit <file> <python-expression over s>: rewrite the file's text, failing loudly
# when the edit changed nothing (a stale anchor would make a case vacuous).
edit() {
  python3 - "$1" "$2" <<'PY'
import sys
path, expr = sys.argv[1], sys.argv[2]
s = open(path).read()
new = eval(expr, {'s': s})
if new == s:
    sys.exit('edit changed nothing in %s' % path)
open(path, 'w').write(new)
PY
}

T="$(fresh_tree unregistered)"
cat > "$T/.github/workflows/label-forks.yml" <<'YAML'
name: Label forks
on: pull_request_target
jobs:
  label:
    runs-on: ubuntu-latest
    steps:
      - run: echo hi
YAML
T_UNREG="$T"

T="$(fresh_tree list-form)"
cat > "$T/.github/workflows/triage.yaml" <<'YAML'
name: Triage
on: [issues, pull_request_target]
jobs: {}
YAML
T_LIST="$T"

T="$(fresh_tree added-trigger)"
edit "$T/.github/workflows/$AC" "s.replace('  schedule:\n', '  workflow_dispatch:\n  schedule:\n', 1)"
T_ADDED="$T"

T="$(fresh_tree dropped-trigger)"
edit "$T/.github/workflows/$MQ" "s.replace('on:\n  pull_request_target:\n', 'on:\n  pull_request_target:\n  push:\n', 1)"
T_MQPUSH="$T"

T="$(fresh_tree head-checkout)"
edit "$T/.github/workflows/$DA" "s.replace('github.event.pull_request.base.sha }}', 'github.event.pull_request.head.sha }}', 1)"
T_HEAD="$T"

T="$(fresh_tree mixed-case-checkout)"
edit "$T/.github/workflows/$DA" "s.replace('uses: actions/checkout@', 'uses: actIONS/Checkout@', 1).replace('github.event.pull_request.base.sha }}', 'github.event.pull_request.head.sha }}', 1)"
T_MIXED="$T"

T="$(fresh_tree upper-case-inputs)"
edit "$T/.github/workflows/$MQ" "s.replace('          ref: \${{ github.event.pull_request.base.sha }}\n', '          REF: \${{ github.event.pull_request.head.sha }}\n          ALLOW-UNSAFE-PR-CHECKOUT: true\n', 1)"
T_UPPER="$T"

T="$(fresh_tree merge-ref-checkout)"
edit "$T/.github/workflows/$MQ" "s.replace('ref: \${{ github.event.pull_request.base.sha }}', 'ref: refs/pull/\${{ github.event.pull_request.number }}/merge', 1)"
T_MERGEREF="$T"

T="$(fresh_tree fork-repository)"
edit "$T/.github/workflows/$AC" "s.replace('ref: \${{ github.event.repository.default_branch }}', 'ref: \${{ github.event.repository.default_branch }}\n          repository: \${{ github.event.pull_request.head.repo.full_name }}', 1)"
T_FORKREPO="$T"

T="$(fresh_tree unsafe-flag)"
edit "$T/.github/workflows/$DA" "s.replace('persist-credentials: false', 'persist-credentials: false\n          allow-unsafe-pr-checkout: true', 1)"
T_UNSAFE="$T"

T="$(fresh_tree gh-pr-checkout)"
edit "$T/.github/workflows/$MQ" "s.replace('    steps:\n', '    steps:\n      - run: gh pr checkout \"\$PR_NUMBER\" && make test\n', 1)"
T_GHCO="$T"

T="$(fresh_tree git-fetch)"
edit "$T/.github/workflows/$DA" "s.replace('    steps:\n', '    steps:\n      - run: |\n          # git fetch is fine in a comment\n          git fetch origin \"\$HEAD_SHA\"\n', 1)"
T_FETCH="$T"

T="$(fresh_tree git-clone)"
edit "$T/.github/workflows/$DA" "s.replace('    steps:\n', '    steps:\n      - run: |\n          git clone \"\$FORK_URL\" candidate\n          ./candidate/test.sh\n', 1)"
T_CLONE="$T"

T="$(fresh_tree head-repo-expression)"
edit "$T/.github/workflows/$DA" "s.replace('    steps:\n', '    steps:\n      - run: ./fetch.sh \"\${{ github.event.pull_request.head.repo.clone_url }}\"\n', 1)"
T_HEADREPO="$T"

T="$(fresh_tree gh-repo-clone)"
edit "$T/.github/workflows/$MQ" "s.replace('    steps:\n', '    steps:\n      - run: gh repo clone \"\$FORK\" candidate\n', 1)"
T_GHCLONE="$T"

T="$(fresh_tree tarball)"
edit "$T/.github/workflows/$AC" "s.replace('    steps:\n', '    steps:\n      - run: curl -sL \"\$API/repos/\$FORK/tarball/\$HEAD_SHA\" | tar xz\n', 1)"
T_TARBALL="$T"

T="$(fresh_tree git-global-options)"
edit "$T/.github/workflows/$DA" "s.replace('    steps:\n', '    steps:\n      - run: |\n          git -C candidate fetch origin \"\$SHA\"\n          git -c protocol.version=2 clone \"\$URL\" c2\n', 1)"
T_GITOPTS="$T"

T="$(fresh_tree registry-file-deleted)"
rm "$T/.github/workflows/$MQ"
T_DELETED="$T"

T="$(fresh_tree trigger-replaced)"
edit "$T/.github/workflows/$MQ" "s.replace('on:\n  pull_request_target:\n', 'on:\n  pull_request:\n', 1)"
T_REPLACED="$T"

T="$(fresh_tree comment-only)"
edit "$T/.github/workflows/$DA" "s.replace('    steps:\n', '    steps:\n      - run: |\n          # never: gh pr checkout, git fetch, refs/pull/1/merge\n          echo ok\n', 1)"
T_COMMENT="$T"

T="$(fresh_tree download-artifact)"
edit "$T/.github/workflows/$MQ" "s.replace('    steps:\n', '    steps:\n      - uses: actions/download-artifact@0000000000000000000000000000000000000000\n', 1)"
T_ARTIFACT="$T"

T="$(fresh_tree reusable)"
edit "$T/.github/workflows/$MQ" "s.replace('jobs:\n', 'jobs:\n  remote:\n    uses: octo/shared/.github/workflows/build.yml@main\n  local:\n    uses: ./.github/workflows/local.yml\n', 1)"
T_REUSABLE="$T"

T="$(fresh_tree spacing)"
edit "$T/.github/workflows/$DA" "s.replace('\${{ github.event.pull_request.base.sha }}', '\${{github.event.pull_request.base.sha}}', 1)"
T_SPACING="$T"

T="$(fresh_tree non-target-head)"
cat > "$T/.github/workflows/ci.yml" <<'YAML'
name: CI
on: pull_request
jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@0000000000000000000000000000000000000000
        with:
          ref: ${{ github.event.pull_request.head.sha }}
YAML
T_NONTARGET="$T"

for mode in "${MODES[@]}"; do
  expect "lint passes on this checkout" 0 '^PASS: 3 pull_request_target workflow' "$mode" lint --root "$ROOT"
  expect "lint flags an unregistered pull_request_target workflow" 1 'label-forks.yml triggers on pull_request_target but is not in REGISTRY' "$mode" lint --root "$T_UNREG"
  expect "lint reads list-form triggers" 1 'triage.yaml triggers on pull_request_target but is not in REGISTRY' "$mode" lint --root "$T_LIST"
  expect "lint flags a trigger added to a registered workflow" 1 "auto-clear-blocking-labels.yml triggers on .*workflow_dispatch.* but REGISTRY pins" "$mode" lint --root "$T_ADDED"
  expect "lint flags a push trigger added to the queue recorder" 1 "merge-queue-authorization.yml triggers on .*push.* but REGISTRY pins" "$mode" lint --root "$T_MQPUSH"
  expect "lint flags a head-SHA checkout" 1 'dependabot-auto-merge.yml: job .* checks out ref .*head.sha' "$mode" lint --root "$T_HEAD"
  expect "lint matches action names case-insensitively" 1 'dependabot-auto-merge.yml: job .* checks out ref .*head.sha' "$mode" lint --root "$T_MIXED"
  expect "lint reads checkout inputs in any case (ref)" 1 'merge-queue-authorization.yml: job .* checks out ref .*head.sha' "$mode" lint --root "$T_UPPER"
  expect "lint reads checkout inputs in any case (unsafe flag)" 1 'merge-queue-authorization.yml: job .* sets allow-unsafe-pr-checkout' "$mode" lint --root "$T_UPPER"
  expect "lint flags a merge-ref checkout" 1 'merge-queue-authorization.yml: job .* checks out ref refs/pull/' "$mode" lint --root "$T_MERGEREF"
  expect "lint flags a fork-repository checkout" 1 'auto-clear-blocking-labels.yml: job .* checks out repository .*head.repo.full_name' "$mode" lint --root "$T_FORKREPO"
  expect "lint flags allow-unsafe-pr-checkout" 1 'sets allow-unsafe-pr-checkout' "$mode" lint --root "$T_UNSAFE"
  expect "lint flags gh pr checkout" 1 'runs: gh pr checkout' "$mode" lint --root "$T_GHCO"
  expect "lint flags git clone of the fork" 1 'runs: git clone ' "$mode" lint --root "$T_CLONE"
  expect "lint flags the fork's coordinates in shell" 1 'runs: ./fetch.sh .*head.repo.clone_url' "$mode" lint --root "$T_HEADREPO"
  expect "lint flags git behind -C" 1 'runs: git -C candidate fetch' "$mode" lint --root "$T_GITOPTS"
  expect "lint flags git behind -c" 1 'runs: git -c protocol.version=2 clone' "$mode" lint --root "$T_GITOPTS"
  expect "lint flags a deleted registry workflow" 1 'merge-queue-authorization.yml is in REGISTRY but missing' "$mode" lint --root "$T_DELETED"
  expect "lint flags gh repo clone" 1 'runs: gh repo clone' "$mode" lint --root "$T_GHCLONE"
  expect "lint flags an archive download" 1 'runs: curl .*tarball' "$mode" lint --root "$T_TARBALL"
  expect "lint flags a registered workflow that lost pull_request_target" 1 'merge-queue-authorization.yml no longer triggers on pull_request_target' "$mode" lint --root "$T_REPLACED"
  expect "lint flags git fetch but not its comment" 1 'runs: git fetch origin' "$mode" lint --root "$T_FETCH"
  out="$(run_tool "$mode" lint --root "$T_FETCH" 2>&1 || true)"
  if printf '%s\n' "$out" | grep -q 'git fetch is fine'; then
    fail "lint flagged a shell comment [$mode]"
  else
    pass "lint ignores shell comments [$mode]"
  fi
  expect "lint ignores candidate-code words inside comments" 0 '^PASS' "$mode" lint --root "$T_COMMENT"
  expect "lint flags download-artifact" 1 'downloads an artifact' "$mode" lint --root "$T_ARTIFACT"
  expect "lint flags a remote reusable workflow" 1 'job remote calls reusable workflow octo/shared' "$mode" lint --root "$T_REUSABLE"
  expect "lint flags a local reusable workflow" 1 'job local calls reusable workflow ./.github/workflows/local.yml' "$mode" lint --root "$T_REUSABLE"
  expect "lint normalizes expression spacing" 0 '^PASS' "$mode" lint --root "$T_SPACING"
  expect "lint leaves non-pull_request_target workflows alone" 0 '^PASS: 3 ' "$mode" lint --root "$T_NONTARGET"
done

# --- Part 2: payloads -----------------------------------------------------------

want_payloads='[
 {"name":"Mergepath dependabot-auto-merge events","enforcement":"active",
  "conditions":{"workflow_path":{"include":[".github/workflows/dependabot-auto-merge.yml"],"exclude":[]}},
  "rules":[{"type":"restrict_action_events","parameters":{"allowed_events":["pull_request_target"]}}]},
 {"name":"Mergepath auto-clear-blocking-labels events","enforcement":"active",
  "conditions":{"workflow_path":{"include":[".github/workflows/auto-clear-blocking-labels.yml"],"exclude":[]}},
  "rules":[{"type":"restrict_action_events","parameters":{"allowed_events":["pull_request_target","workflow_run","repository_dispatch","schedule"]}}]},
 {"name":"Mergepath merge-queue-authorization events","enforcement":"active",
  "conditions":{"workflow_path":{"include":[".github/workflows/merge-queue-authorization.yml"],"exclude":[]}},
  "rules":[{"type":"restrict_action_events","parameters":{"allowed_events":["pull_request_target"]}}]}
]'
got="$(python3 "$TOOL" payloads)"
if [ "$(jq -cS . <<<"$got")" = "$(jq -cS . <<<"$want_payloads")" ]; then
  pass "payloads are the three pinned policy bodies"
else
  fail "payloads drifted"; printf '%s\n' "$got" >&2
fi

# --- Part 3: verify against a shimmed gh ----------------------------------------

SHIM="$TMP/bin"
mkdir -p "$SHIM"
cat > "$SHIM/gh" <<'SH'
#!/usr/bin/env bash
# Canned GitHub API: $GH_FIXTURE/policies.json is the slurped policy list,
# policy-<id>.json each detail, contents/<path> each workflow file.
printf '%s\n' "$*" >> "$GH_FIXTURE/calls.log"
path=""
for a in "$@"; do
  case "$a" in repos/*|orgs/*|enterprises/*) path="$a" ;; esac
done
case "$path" in
  */actions/policies\?*)
    [ -f "$GH_FIXTURE/policies.json" ] || { echo "gh: Not Found (HTTP 404)" >&2; exit 1; }
    cat "$GH_FIXTURE/policies.json" ;;
  */actions/policies/*)
    id="${path##*/}"
    [ -f "$GH_FIXTURE/policy-$id.json" ] || { echo "gh: Not Found (HTTP 404)" >&2; exit 1; }
    cat "$GH_FIXTURE/policy-$id.json" ;;
  repos/*/commits/*)
    [ ! -f "$GH_FIXTURE/no-ref" ] || { echo "gh: No commit found for SHA: main (HTTP 422)" >&2; exit 1; }
    printf '{"sha":"%040d"}\n' 1 ;;
  repos/*/contents/*)
    rel="${path#repos/*/*/contents/}"; rel="${rel%%\?*}"
    [ -f "$GH_FIXTURE/contents/$rel" ] || { echo "gh: Not Found (HTTP 404)" >&2; exit 1; }
    # --rawfile, not --arg: a large workflow's base64 exceeds Linux's
    # per-argument limit (MAX_ARG_STRLEN), which macOS does not have.
    base64 < "$GH_FIXTURE/contents/$rel" | tr -d '\n' > "$GH_FIXTURE/b64.tmp"
    jq -n --rawfile c "$GH_FIXTURE/b64.tmp" '{content: $c, encoding: "base64"}' ;;
  *) echo "unexpected gh call: $*" >&2; exit 99 ;;
esac
SH
chmod +x "$SHIM/gh"

REPO=octo/demo
fixture() { # fixture <name>: repo with the three real workflows and no policies
  local dir="$TMP/api/$1"
  mkdir -p "$dir/contents/.github/workflows"
  cp "$REAL_WF/$AC" "$REAL_WF/$DA" "$REAL_WF/$MQ" "$dir/contents/.github/workflows/"
  printf '[{"total_count":0,"policies":[]}]\n' > "$dir/policies.json"
  printf '%s\n' "$dir"
}
add_policy() { # add_policy <fixture> <id> <detail-json> [summary-extra-json]
  local dir="$1" id="$2" detail="$3" extra="${4:-}"
  [ -n "$extra" ] || extra='{}'
  jq -c --argjson id "$id" '. + {id: $id}' <<<"$detail" > "$dir/policy-$id.json"
  jq --argjson s "$(jq -c --argjson id "$id" --argjson x "$extra" '{id: $id, name: .name, enforcement: .enforcement} + $x' "$dir/policy-$id.json")" \
    '.[0].policies += [$s] | .[0].total_count = (.[0].policies | length)' "$dir/policies.json" > "$dir/p.tmp"
  mv "$dir/p.tmp" "$dir/policies.json"
}
owner_policies() { # owner_policies <fixture>: the three payloads as repository policies
  local i=1 body
  while IFS= read -r body; do
    add_policy "$1" "$((100 + i))" "$body"; i=$((i + 1))
  done < <(python3 "$TOOL" payloads | jq -c '.[]')
}
verify_expect() { # verify_expect <desc> <fixture> <want-rc> <pattern>...
  local desc="$1" dir="$2" want="$3"; shift 3
  local out rc=0 pat
  out="$(GH_FIXTURE="$dir" PATH="$SHIM:$PATH" python3 "$TOOL" verify --repo "$REPO" 2>&1)" || rc=$?
  if [ "$rc" != "$want" ]; then
    fail "$desc: exit $rc, want $want"; printf '%s\n' "$out" >&2; return
  fi
  for pat in "$@"; do
    if ! printf '%s\n' "$out" | grep -Eq -- "$pat"; then
      fail "$desc: output lacks /$pat/"; printf '%s\n' "$out" >&2; return
    fi
  done
  pass "$desc"
}
ALLOW_ALL_EVENTS='["pull_request_target","workflow_run","repository_dispatch","schedule"]'

F="$(fixture none)"
verify_expect "no policy leaves all three uncovered" "$F" 1 \
  '^UNCOVERED .github/workflows/dependabot-auto-merge.yml on pull_request_target$' \
  '^UNCOVERED .github/workflows/auto-clear-blocking-labels.yml on pull_request_target, workflow_run, repository_dispatch, schedule$' \
  '^UNCOVERED .github/workflows/merge-queue-authorization.yml' \
  'blocks it in affected public repositories from 2026-11-02'

F="$(fixture owner)"; owner_policies "$F"
verify_expect "the three owner policies allow every workflow" "$F" 0 \
  '^octo/demo: 3 applicable Actions policies$' \
  '^OK +.github/workflows/dependabot-auto-merge.yml' \
  '^OK +.github/workflows/auto-clear-blocking-labels.yml' \
  '^OK +.github/workflows/merge-queue-authorization.yml' \
  'allowed by "Mergepath auto-clear-blocking-labels events" \(id 102, repository\)'
if grep -q 'has_parents=true' "$F/calls.log" && grep -q 'X-GitHub-Api-Version: 2026-03-10' "$F/calls.log" \
   && grep -q 'contents/.github/workflows/dependabot-auto-merge.yml?ref=main' "$F/calls.log"; then
  pass "verify reads inherited policies, pins the API version and reads the repo's own workflow at main"
else
  fail "verify call shape"; cat "$F/calls.log" >&2
fi

F="$(fixture missing-schedule)"; owner_policies "$F"
jq '.rules[0].parameters.allowed_events -= ["schedule"]' "$F/policy-102.json" > "$F/t" && mv "$F/t" "$F/policy-102.json"
verify_expect "a policy missing one of the workflow's events blocks it" "$F" 1 \
  '^BLOCKED .github/workflows/auto-clear-blocking-labels.yml' 'does not allow schedule' \
  '^OK +.github/workflows/dependabot-auto-merge.yml'

F="$(fixture repo-wide-push-only)"; owner_policies "$F"
add_policy "$F" 7 '{"name":"Push only","enforcement":"active","conditions":{},"rules":[{"type":"restrict_action_events","parameters":{"allowed_events":["push"]}}]}'
verify_expect "a layered repo-wide allowlist blocks what it omits" "$F" 1 \
  '^BLOCKED .github/workflows/dependabot-auto-merge.yml' '"Push only" \(id 7, repository\) does not allow pull_request_target'

F="$(fixture evaluate-only)"; owner_policies "$F"
add_policy "$F" 8 '{"name":"Trial","enforcement":"evaluate","conditions":{},"rules":[{"type":"restrict_action_events","parameters":{"allowed_events":["push"]}}]}'
add_policy "$F" 9 '{"name":"Off","enforcement":"disabled","conditions":{},"rules":[{"type":"restrict_action_events","parameters":{"allowed_events":["push"]}}]}'
verify_expect "evaluate and disabled policies never block" "$F" 0 '^OK +.github/workflows/merge-queue-authorization.yml'

F="$(fixture evaluate-allow)"
add_policy "$F" 10 "{\"name\":\"Trial allow\",\"enforcement\":\"evaluate\",\"conditions\":{},\"rules\":[{\"type\":\"restrict_action_events\",\"parameters\":{\"allowed_events\":$ALLOW_ALL_EVENTS}}]}"
verify_expect "an evaluate-mode allow does not count as coverage" "$F" 1 '^UNCOVERED .github/workflows/dependabot-auto-merge.yml'

F="$(fixture actors)"; owner_policies "$F"
add_policy "$F" 11 '{"name":"Maintainers only","enforcement":"active","conditions":{},"rules":[{"type":"restrict_actions_actors","parameters":{"allowed_actors":[{"id":5,"type":"RepositoryRole"}]}}]}'
verify_expect "an actor rule is reported, not assumed harmless" "$F" 1 \
  '^UNVERIFIED .github/workflows/dependabot-auto-merge.yml' 'has a restrict_actions_actors rule this tool does not evaluate'

F="$(fixture glob)"
add_policy "$F" 12 "{\"name\":\"All workflows\",\"enforcement\":\"active\",\"conditions\":{\"workflow_path\":{\"include\":[\".github/workflows/*.yml\"],\"exclude\":[]}},\"rules\":[{\"type\":\"restrict_action_events\",\"parameters\":{\"allowed_events\":$ALLOW_ALL_EVENTS}}]}"
verify_expect "a matching glob include covers the workflow" "$F" 0 '^OK +.github/workflows/auto-clear-blocking-labels.yml'

F="$(fixture glob-deep)"
add_policy "$F" 13 "{\"name\":\"Nested\",\"enforcement\":\"active\",\"conditions\":{\"workflow_path\":{\"include\":[\".github/*.yml\"],\"exclude\":[]}},\"rules\":[{\"type\":\"restrict_action_events\",\"parameters\":{\"allowed_events\":$ALLOW_ALL_EVENTS}}]}"
verify_expect "a single star does not cross a slash" "$F" 1 '^UNCOVERED .github/workflows/dependabot-auto-merge.yml'

F="$(fixture glob-unknown)"
add_policy "$F" 14 "{\"name\":\"Classes\",\"enforcement\":\"active\",\"conditions\":{\"workflow_path\":{\"include\":[\".github/workflows/[a-z]*.yml\"],\"exclude\":[]}},\"rules\":[{\"type\":\"restrict_action_events\",\"parameters\":{\"allowed_events\":$ALLOW_ALL_EVENTS}}]}"
verify_expect "an unmodelled glob never counts as coverage" "$F" 1 '^UNCOVERED .github/workflows/dependabot-auto-merge.yml'

F="$(fixture glob-unknown-deny)"; owner_policies "$F"
add_policy "$F" 15 '{"name":"Maybe","enforcement":"active","conditions":{"workflow_path":{"include":[".github/workflows/[a-z]*.yml"],"exclude":[]}},"rules":[{"type":"restrict_action_events","parameters":{"allowed_events":["push"]}}]}'
verify_expect "an unmodelled glob that could deny is unverified" "$F" 1 \
  '^UNVERIFIED .github/workflows/dependabot-auto-merge.yml' 'may target this path and does not allow pull_request_target'

F="$(fixture excluded)"
add_policy "$F" 16 "{\"name\":\"All but Dependabot\",\"enforcement\":\"active\",\"conditions\":{\"workflow_path\":{\"include\":[\"~ALL\"],\"exclude\":[\".github/workflows/dependabot-auto-merge.yml\"]}},\"rules\":[{\"type\":\"restrict_action_events\",\"parameters\":{\"allowed_events\":$ALLOW_ALL_EVENTS}}]}"
verify_expect "an excluded path is not covered" "$F" 1 \
  '^UNCOVERED .github/workflows/dependabot-auto-merge.yml' '^OK +.github/workflows/merge-queue-authorization.yml'

F="$(fixture other-path)"; owner_policies "$F"
add_policy "$F" 17 '{"name":"Deploy","enforcement":"active","conditions":{"workflow_path":{"include":[".github/workflows/deploy.yml"],"exclude":[]}},"rules":[{"type":"restrict_action_events","parameters":{"allowed_events":["push"]}}]}'
verify_expect "a policy on another path is ignored" "$F" 0 '^OK +.github/workflows/dependabot-auto-merge.yml'

F="$(fixture inherited)"; owner_policies "$F"
add_policy "$F" 18 '{"name":"Org push only","enforcement":"active","source_type":"Organization","rules":[{"type":"restrict_action_events","parameters":{"allowed_events":["push"]}}]}' \
  '{"source_type":"Organization","_links":{"self":{"href":"https://api.github.com/orgs/octo/actions/policies/18"}}}'
verify_expect "an inherited policy is read from its own link and layered" "$F" 1 \
  '"Org push only" \(id 18, Organization\) does not allow pull_request_target'
if grep -q '^api .*orgs/octo/actions/policies/18$' "$F/calls.log"; then
  pass "verify follows the inherited policy's self link"
else
  fail "inherited policy link not followed"; cat "$F/calls.log" >&2
fi

F="$(fixture absent)"; owner_policies "$F"
rm "$F/contents/.github/workflows/$MQ"
verify_expect "a workflow the repo lacks is reported absent, not failed" "$F" 0 \
  '^ABSENT  .github/workflows/merge-queue-authorization.yml'

F="$(fixture drifted)"; owner_policies "$F"
edit "$F/contents/.github/workflows/$DA" "s.replace('on:\n  pull_request_target:\n', 'on:\n  pull_request_target:\n  workflow_dispatch:\n', 1)"
verify_expect "verify checks the repo's own trigger list, not only REGISTRY" "$F" 1 \
  '^BLOCKED .github/workflows/dependabot-auto-merge.yml on pull_request_target, workflow_dispatch \[events differ from REGISTRY' \
  'does not allow workflow_dispatch'

F="$(fixture bad-ref)"; owner_policies "$F"; touch "$F/no-ref"
verify_expect "an unresolvable ref is an API error, not three absences" "$F" 3 'repos/octo/demo/commits/main failed'

F="$(fixture odd-ref)"; owner_policies "$F"
out="$(GH_FIXTURE="$F" PATH="$SHIM:$PATH" python3 "$TOOL" verify --repo "$REPO" --ref 'release&candidate#1' 2>&1)" || true
if grep -q 'contents/.github/workflows/dependabot-auto-merge.yml?ref=release%26candidate%231$' "$F/calls.log" \
   && grep -q 'commits/release%26candidate%231$' "$F/calls.log"; then
  pass "verify percent-encodes the ref in the commit lookup and every contents read"
else
  fail "ref encoding"; cat "$F/calls.log" >&2
fi

F="$(fixture trigger-dropped)"; owner_policies "$F"
edit "$F/contents/.github/workflows/$MQ" "s.replace('on:\n  pull_request_target:\n', 'on:\n  pull_request:\n', 1)"
verify_expect "a registered workflow without pull_request_target fails verify" "$F" 1 \
  '^DRIFT   .github/workflows/merge-queue-authorization.yml no longer triggers on pull_request_target at main \(triggers: pull_request\)' \
  '^OK +.github/workflows/dependabot-auto-merge.yml'

F="$(fixture no-access)"; rm "$F/policies.json"
verify_expect "a 404 on the policy list is an API error naming the owner token" "$F" 3 'use the owner token'

# --- Part 4: plan ---------------------------------------------------------------

F="$(fixture plan)"
add_policy "$F" 21 "$(python3 "$TOOL" payloads | jq -c '.[1]')"
OUT="$TMP/plan-out"
out="$(GH_FIXTURE="$F" PATH="$SHIM:$PATH" python3 "$TOOL" plan --repo "$REPO" --out "$OUT" 2>&1)" || { fail "plan exited non-zero"; printf '%s\n' "$out" >&2; }
if printf '%s\n' "$out" | grep -q "scripts/gh-as-author.sh -- gh api --method PUT -H 'X-GitHub-Api-Version: 2026-03-10' repos/octo/demo/actions/policies/21 --input $OUT/octo__demo.auto-clear-blocking-labels.json" \
   && printf '%s\n' "$out" | grep -q "scripts/gh-as-author.sh -- gh api --method POST -H 'X-GitHub-Api-Version: 2026-03-10' repos/octo/demo/actions/policies --input $OUT/octo__demo.dependabot-auto-merge.json" \
   && [ "$(printf '%s\n' "$out" | grep -c 'gh-as-author.sh')" = 3 ]; then
  pass "plan updates the existing policy and creates the others through the author wrapper"
else
  fail "plan commands"; printf '%s\n' "$out" >&2
fi
if grep -q 'has_parents=false' "$F/calls.log"; then
  pass "plan matches names against repository-level policies only"
else
  fail "plan read inherited policies"; cat "$F/calls.log" >&2
fi
if [ "$(jq -cS . "$OUT/octo__demo.merge-queue-authorization.json")" = "$(python3 "$TOOL" payloads | jq -cS '.[2]')" ]; then
  pass "plan writes each payload file verbatim"
else
  fail "plan payload file"
fi
add_policy "$F" 22 "$(python3 "$TOOL" payloads | jq -c '.[1]')"
rc=0
out="$(GH_FIXTURE="$F" PATH="$SHIM:$PATH" python3 "$TOOL" plan --repo "$REPO" --out "$OUT" 2>&1)" || rc=$?
if [ "$rc" = 1 ] && printf '%s\n' "$out" | grep -q '^# ERROR: 2 policies named "Mergepath auto-clear-blocking-labels events"' \
   && ! printf '%s\n' "$out" | grep -q 'policies/2[12] --input'; then
  pass "plan refuses to pick between duplicate names and exits 1"
else
  fail "plan duplicate names (exit $rc)"; printf '%s\n' "$out" >&2
fi

# --- Part 5: usage --------------------------------------------------------------

for mode in "${MODES[@]}"; do
  expect "a malformed --repo is a usage error" 2 'OWNER/NAME' "$mode" verify --repo 'octo demo'
  expect "an unknown subcommand is a usage error" 2 'invalid choice' "$mode" apply
  expect "--help exits 0" 0 'never writes a setting' "$mode" --help
done

echo
echo "pull-request-target-policy: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
