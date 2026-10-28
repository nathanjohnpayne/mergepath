#!/usr/bin/env bash
# The `cond && ok || bad` idiom is safe here: ok and bad always return 0.
# shellcheck disable=SC2015
# tests/test_policy_mutations.sh — #2727 slice 3c (ADR 0004 callers C6, C7)
#
# trusted-policy-mutations.yml moves the External Review Check's two PAT label
# writes to a trusted workflow_run consumer holding the policy-mutations app
# token. This suite covers:
#   - the C6 helper is the producer's inline step, byte for byte, until cutover;
#   - policy_mutations_apply.sh writes only with an installation token, only
#     after the admission recheck holds, and only for C6/C7 classifications;
#   - propagation_lane_label_remove.sh fences the pair before its one write and
#     fails closed on an unread or malformed PR;
#   - the workflow is inert without its repository variable, runs only trusted
#     scripts, and keeps the app token and contents: write in separate jobs.
# Hermetic: a gh stub, no token, no network.

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WF="$ROOT/.github/workflows/trusted-policy-mutations.yml"
PRODUCER="$ROOT/.github/workflows/pr-review-policy.yml"
APPLY="$ROOT/scripts/workflow/policy_mutations_apply.sh"
REMOVE="$ROOT/scripts/workflow/propagation_lane_label_remove.sh"
RECONCILE="$ROOT/scripts/workflow/external_review_label_reconcile.sh"
for f in "$WF" "$PRODUCER" "$APPLY" "$REMOVE" "$RECONCILE"; do
  [ -f "$f" ] || { echo "missing $f" >&2; exit 1; }
done

pass=0; fail=0
ok()  { pass=$((pass + 1)); echo "  PASS: $1"; }
bad() { fail=$((fail + 1)); echo "  FAIL: $1" >&2; }
expect() { if [ "$rc" -eq "$2" ]; then ok "$1"; else bad "$1 (exit $rc, want $2): $err"; fi; }

PY=""
for p in python3 /usr/bin/python3; do
  if command -v "$p" >/dev/null 2>&1 && "$p" -c 'import yaml' 2>/dev/null; then PY="$p"; break; fi
done
[ -n "$PY" ] || { echo "no python3 with PyYAML" >&2; exit 1; }

SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/tpm.XXXXXX")"
trap 'rm -rf "$SCRATCH"' EXIT
STATE="$SCRATCH/state"; mkdir -p "$STATE"

H=1111111111111111111111111111111111111111
H2=3333333333333333333333333333333333333333
B=2222222222222222222222222222222222222222
RID=42
APP_TOKEN=ghs_apptoken
PAT=ghp_usertoken

echo "C6 helper parity with the producer"
"$PY" - "$PRODUCER" "$RECONCILE" <<'PY' && ok "external_review_label_reconcile.sh carries the producer's step body verbatim" || bad "the C6 helper and pr-review-policy.yml's reconcile step differ"
import sys, yaml
steps = yaml.safe_load(open(sys.argv[1]))["jobs"]["external-review-labeling"]["steps"]
body = [s for s in steps if s.get("name") == "Reconcile a policy-owned fail-closed label"][0]["run"]
script = open(sys.argv[2]).read()
start = script.index("set -euo pipefail\n")
sys.exit(0 if script[start:] == body else 1)
PY

# The stub answers the calls the helpers make. pr_<k>.json is the k-th live
# read of the PR (the last one repeats); a --jq filter is applied as gh would.
cat > "$SCRATCH/gh" <<'GH'
#!/usr/bin/env bash
[ "$1" = api ] || exit 1
shift
method=GET
if [ "$1" = -X ]; then method="$2"; shift 2; fi
path="$1"; shift
filter=""
while [ $# -gt 0 ]; do
  case "$1" in --jq) filter="$2"; shift 2 ;; *) shift ;; esac
done
if [ "$method" != GET ]; then
  echo "$method $path token=$GH_TOKEN" >> "$STATE/writes"
  [ -f "$STATE/fail_write" ] && exit 1
  exit 0
fi
case "$path" in
  repos/o/r) body='{"default_branch":"main"}' ;;
  repos/o/r/pulls/7)
    [ -f "$STATE/fail_pr" ] && exit 1
    n=$(( $(cat "$STATE/reads" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$STATE/reads"
    f="$STATE/pr_$n.json"; [ -f "$f" ] || f=$(ls "$STATE"/pr_*.json | sort -V | tail -1)
    body=$(cat "$f") ;;
  *) exit 1 ;;
esac
if [ -n "$filter" ]; then jq -r "$filter" <<<"$body"; else printf '%s\n' "$body"; fi
GH
chmod +x "$SCRATCH/gh"

# pr <k> <head> <base> <labels-json> [state] [base_ref]
pr() {
  jq -n --arg h "$2" --arg b "$3" --argjson l "$4" --arg s "${5:-open}" --arg r "${6:-main}" --argjson rid "$RID" \
    '{number: 7, state: $s, head: {sha: $h, repo: {id: $rid}}, base: {sha: $b, ref: $r, repo: {id: $rid}},
      labels: [$l[] | {name: .}]}' > "$STATE/pr_$1.json"
}
reset() { rm -f "$STATE"/*; pr 1 "$H" "$B" '["needs-external-review"]'; }

run() { # <script> [VAR=value...]
  local script="$1"; shift
  out=$(cd "$ROOT" && env PATH="$SCRATCH:$PATH" STATE="$STATE" GITHUB_REPOSITORY=o/r GITHUB_REPOSITORY_ID="$RID" \
    REPO=o/r PR_NUMBER=7 EXPECTED_HEAD_SHA="$H" EXPECTED_BASE_SHA="$B" GH_TOKEN=ghs_readtoken \
    LABEL_REMOVAL_TOKEN="$APP_TOKEN" "$@" bash "$script" 2>"$STATE/err")
  rc=$?
  err=$(cat "$STATE/err")
}
writes() { cat "$STATE/writes" 2>/dev/null; }

echo "propagation_lane_label_remove.sh"
reset; run "$REMOVE"
expect "a held pair with the label removes it" 0
[ "$(writes)" = "DELETE repos/o/r/issues/7/labels/needs-external-review token=$APP_TOKEN" ] \
  && ok "the one write is the DELETE, made with LABEL_REMOVAL_TOKEN" || bad "unexpected writes: $(writes)"
reset; pr 1 "$H2" "$B" '["needs-external-review"]'; run "$REMOVE"
expect "a moved head is a stale no-op" 0
[ -z "$(writes)" ] && ok "a moved head writes nothing" || bad "a moved head wrote: $(writes)"
reset; pr 2 "$H" "$H2" '["needs-external-review"]'; run "$REMOVE"
expect "a base that moves between the two fences is a stale no-op" 0
[ -z "$(writes)" ] && ok "the second fence stops the write" || bad "the second fence did not stop: $(writes)"
reset; pr 1 "$H" "$B" '[]'; run "$REMOVE"
expect "an absent label is a no-op" 0
[ -z "$(writes)" ] && ok "an absent label writes nothing" || bad "an absent label wrote: $(writes)"
reset; touch "$STATE/fail_pr"; run "$REMOVE"
expect "an unreadable PR fails closed" 1
reset; echo '{"head":{"sha":"short"},"base":{"sha":"x"},"labels":[]}' > "$STATE/pr_1.json"; run "$REMOVE"
expect "a malformed live pair fails closed" 1
reset; run "$REMOVE" LABEL_REMOVAL_TOKEN=
expect "a missing removal token fails closed" 1
[ -z "$(writes)" ] && ok "a missing removal token writes nothing" || bad "wrote without a token: $(writes)"
reset; touch "$STATE/fail_write"; run "$REMOVE"
expect "a failed removal fails the run" 1

echo "policy_mutations_apply.sh"
reset; run "$APPLY" CLASSIFICATION=external-required PROPAGATION_LANE=false
expect "a classification that calls for no mutation is a no-op" 0
[ -z "$(writes)" ] && ok "no mutation, no write" || bad "wrote for external-required: $(writes)"
for tok in "$PAT" "" ghr_refresh; do
  reset; run "$APPLY" CLASSIFICATION=propagation PROPAGATION_LANE=true LABEL_REMOVAL_TOKEN="$tok"
  expect "a non-installation token ('${tok:-empty}') is refused" 1
  [ -z "$(writes)" ] && ok "refused token '${tok:-empty}' wrote nothing" || bad "token '${tok:-empty}' wrote: $(writes)"
done
reset; run "$APPLY" CLASSIFICATION=propagation PROPAGATION_LANE=true
expect "a verified propagation PR at the held pair removes the label" 0
[ "$(writes)" = "DELETE repos/o/r/issues/7/labels/needs-external-review token=$APP_TOKEN" ] \
  && ok "C7 removes with the app token" || bad "C7 writes: $(writes)"
reset; pr 1 "$H" "$B" '["needs-external-review"]' closed; run "$APPLY" CLASSIFICATION=propagation PROPAGATION_LANE=true
expect "a closed PR fails the recheck and is a stale no-op" 0
[ -z "$(writes)" ] && ok "a closed PR is not written" || bad "a closed PR was written: $(writes)"
reset; pr 1 "$H" "$B" '["needs-external-review"]' open release; run "$APPLY" CLASSIFICATION=propagation PROPAGATION_LANE=true
expect "a PR off the default branch fails the recheck and is a stale no-op" 0
[ -z "$(writes)" ] && ok "a non-default-base PR is not written" || bad "a non-default-base PR was written: $(writes)"
reset; touch "$STATE/fail_pr"; run "$APPLY" CLASSIFICATION=propagation PROPAGATION_LANE=true
expect "an unreadable recheck fails the run" 1
reset; run "$APPLY" CLASSIFICATION=under-threshold PROPAGATION_LANE=false PR_NUMBER=7x
expect "a malformed PR number fails before any read" 1
reset; run "$APPLY" CLASSIFICATION=under-threshold PROPAGATION_LANE=false EXPECTED_HEAD_SHA=abc
expect "a malformed head fails before any read" 1
# C6 reaches the verbatim reconcile helper; with the label already absent it
# stops before any timeline read or write.
reset; pr 1 "$H" "$B" '[]'; run "$APPLY" CLASSIFICATION=carried-forward PROPAGATION_LANE=false
expect "C6 runs the reconcile helper" 0
grep -q "already absent; nothing to reconcile" <<<"$out" && ok "C6 dispatches to external_review_label_reconcile.sh" \
  || bad "C6 did not reach the reconcile helper: $out"

echo "workflow shape"
if "$PY" - "$WF" <<'PY'
import sys, yaml
doc = yaml.load(open(sys.argv[1]), Loader=yaml.BaseLoader)
jobs = doc["jobs"]
res = []
def check(name, cond):
    res.append(("PASS" if cond else "FAIL") + ": " + name)
check("triggers only on workflow_run of PR Review Policy",
      list(doc["on"]) == ["workflow_run"] and doc["on"]["workflow_run"]["workflows"] == ["PR Review Policy"])
check("workflow-level permissions are empty", doc["permissions"] == {})
import re
GATE = "vars.CI_APP_POLICY_MUTATIONS == 'true'"
def gated(cond):
    # The gate must be a top-level conjunct: with every parenthesised group
    # removed, the condition has no `||` and lists the gate among its `&&` terms.
    flat = " ".join(cond.split())
    while re.search(r"\([^()]*\)", flat):
        flat = re.sub(r"\([^()]*\)", "X", flat)
    return "||" not in flat and GATE in [t.strip() for t in flat.split("&&")]
check("every job is gated on vars.CI_APP_POLICY_MUTATIONS",
      all(gated(j.get("if", "")) for j in jobs.values()))
idt = [k for k, j in jobs.items() if j.get("permissions", {}).get("id-token") == "write"]
check("only mutate requests id-token: write", idt == ["mutate"])
check("only recheck-dispatch holds contents: write",
      [k for k, j in jobs.items() if j.get("permissions", {}).get("contents") == "write"] == ["recheck-dispatch"])
check("recheck-dispatch holds nothing else",
      jobs["recheck-dispatch"]["permissions"] == {"contents": "write"})
check("the classify job holds no write permission",
      all(v in ("read", "none") for v in jobs["classify"]["permissions"].values()))
text = open(sys.argv[1]).read()
check("no secret but GITHUB_TOKEN is read", set(__import__("re").findall(r"secrets\.([A-Za-z_]+)", text)) == {"GITHUB_TOKEN"})
steps = jobs["classify"]["steps"]
cands = [s for s in steps if s.get("with", {}).get("path") == "candidate"]
check("the candidate checkout is data only: no credentials persisted",
      len(cands) == 1 and cands[0]["with"].get("persist-credentials") == "false")
runs = " ".join(s.get("run", "") for s in steps)
check("classify runs scripts only from the trusted checkout",
      "trusted/scripts/workflow/trusted-consumer-admission.sh" in runs
      and "$GITHUB_WORKSPACE/trusted/scripts/workflow/external_review_classify.sh" in runs
      and "candidate/scripts" not in runs)
trusted = [s for s in steps if s.get("with", {}).get("path") == "trusted"]
check("the trusted checkout is github.workflow_sha", len(trusted) == 1
      and trusted[0]["with"]["ref"] == "${{ github.workflow_sha }}")
mut = jobs["mutate"]["steps"]
check("mutate exchanges for the policy-mutations identity",
      any(s.get("with", {}).get("identity") == "policy-mutations" for s in mut))
check("mutate passes only the exchanged token as LABEL_REMOVAL_TOKEN",
      mut[-1]["env"]["LABEL_REMOVAL_TOKEN"] == "${{ steps.sts.outputs.token }}")
for r in res:
    print("  " + r)
sys.exit(1 if any(r.startswith("FAIL") for r in res) else 0)
PY
then ok "workflow shape assertions"; else bad "workflow shape assertions"; fi

echo
echo "test_policy_mutations: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
