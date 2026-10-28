#!/usr/bin/env bash
# tests/test_disagreement_detector.sh
#
# Fixture-driven unit tests for scripts/disagreement-detector.cjs,
# the decision function used by `.github/workflows/agent-review.yml`'s
# `detect-disagreement` job (#259).
#
# Strategy: each fixture under
# scripts/ci/fixtures/disagreement-detector/*.json carries a synthetic
# review payload plus `expected_decision`. The runner loads the
# detector module, feeds it the fixture's input, and compares its
# return value against the expectation.
#
# Cases (mapped to the issue body's four):
#   1. stale-changes-then-fresh-approval         → noop
#      stale-changes-then-fresh-approval-with-label → remove
#   2. same-reviewer-reversal                    → noop
#   3. live-disagreement                         → apply (regression net)
#   4. dismissed-approved                        → noop
#
# Bash 3.2 portable.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DETECTOR="$ROOT/scripts/disagreement-detector.cjs"
FIXTURES_DIR="$ROOT/scripts/ci/fixtures/disagreement-detector"

[[ -f "$DETECTOR" ]] || { echo "missing $DETECTOR" >&2; exit 1; }
[[ -d "$FIXTURES_DIR" ]] || { echo "missing $FIXTURES_DIR" >&2; exit 1; }

if ! command -v node >/dev/null 2>&1; then
  echo "SKIP: node not available" >&2
  exit 0
fi

PASS=0
FAIL=0
pass() { echo "PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $*" >&2; FAIL=$((FAIL + 1)); }

run_fixture() {
  local fixture="$1"
  local name
  name="$(basename "$fixture")"

  local result
  if ! result=$(DETECTOR_PATH="$DETECTOR" FIXTURE_PATH="$fixture" node -e '
    const fs = require("fs");
    const { decide } = require(process.env.DETECTOR_PATH);
    const fx = JSON.parse(fs.readFileSync(process.env.FIXTURE_PATH, "utf8"));
    const decision = decide({
      reviews: fx.reviews,
      reviewerAccounts: fx.reviewerAccounts,
      headSha: fx.headSha,
      hasLabel: fx.hasLabel,
    });
    process.stdout.write(JSON.stringify({
      expected: fx.expected_decision,
      actual: decision,
      description: fx.description,
    }));
  ' 2>&1); then
    fail "$name — node runner failed: $result"
    return
  fi

  local expected actual desc
  expected=$(node -e '
    const d = JSON.parse(require("fs").readFileSync("/dev/stdin", "utf8"));
    process.stdout.write(d.expected);
  ' <<<"$result")
  actual=$(node -e '
    const d = JSON.parse(require("fs").readFileSync("/dev/stdin", "utf8"));
    process.stdout.write(d.actual);
  ' <<<"$result")
  desc=$(node -e '
    const d = JSON.parse(require("fs").readFileSync("/dev/stdin", "utf8"));
    process.stdout.write(d.description || "");
  ' <<<"$result")

  if [[ "$expected" == "$actual" ]]; then
    pass "$name — $desc (decision=$actual)"
  else
    fail "$name — expected=$expected actual=$actual ($desc)"
  fi
}

# --- Fixture-driven cases (the four from #259) ---
for fixture in "$FIXTURES_DIR"/*.json; do
  run_fixture "$fixture"
done

# --- Additional invariants that fixtures don't easily express ---

# Empty review list → noop (no signal of any kind).
EMPTY_RESULT=$(DETECTOR_PATH="$DETECTOR" node -e '
  const { decide } = require(process.env.DETECTOR_PATH);
  process.stdout.write(decide({
    reviews: [],
    reviewerAccounts: ["nathanpayne-claude", "nathanpayne-codex"],
    headSha: "deadbeef",
    hasLabel: false,
  }));
')
if [[ "$EMPTY_RESULT" == "noop" ]]; then
  pass "empty review list → noop"
else
  fail "empty review list expected noop, got $EMPTY_RESULT"
fi

# Empty review list WITH label → remove (auto-clear when the
# upstream signal disappeared entirely).
EMPTY_WITH_LABEL=$(DETECTOR_PATH="$DETECTOR" node -e '
  const { decide } = require(process.env.DETECTOR_PATH);
  process.stdout.write(decide({
    reviews: [],
    reviewerAccounts: ["nathanpayne-claude"],
    headSha: "deadbeef",
    hasLabel: true,
  }));
')
if [[ "$EMPTY_WITH_LABEL" == "remove" ]]; then
  pass "empty review list with label → remove"
else
  fail "empty review list with label expected remove, got $EMPTY_WITH_LABEL"
fi

# Reviewer not in allow-list → ignored (no decision change).
OUTSIDER=$(DETECTOR_PATH="$DETECTOR" node -e '
  const { decide } = require(process.env.DETECTOR_PATH);
  process.stdout.write(decide({
    reviews: [
      { user:{login:"random-human"}, state:"APPROVED",
        commit_id:"HEAD", submitted_at:"2026-05-12T10:00:00Z" },
      { user:{login:"random-other"}, state:"CHANGES_REQUESTED",
        commit_id:"HEAD", submitted_at:"2026-05-12T11:00:00Z" },
    ],
    reviewerAccounts: ["nathanpayne-claude", "nathanpayne-codex"],
    headSha: "HEAD",
    hasLabel: false,
  }));
')
if [[ "$OUTSIDER" == "noop" ]]; then
  pass "non-allowlisted reviewers are ignored"
else
  fail "non-allowlisted reviewers should not trigger; got $OUTSIDER"
fi

# COMMENTED reviews ignored — only opinionated reviews count.
COMMENTED=$(DETECTOR_PATH="$DETECTOR" node -e '
  const { decide } = require(process.env.DETECTOR_PATH);
  process.stdout.write(decide({
    reviews: [
      { user:{login:"nathanpayne-codex"}, state:"COMMENTED",
        commit_id:"HEAD", submitted_at:"2026-05-12T10:00:00Z" },
      { user:{login:"nathanpayne-cursor"}, state:"APPROVED",
        commit_id:"HEAD", submitted_at:"2026-05-12T11:00:00Z" },
    ],
    reviewerAccounts: ["nathanpayne-claude", "nathanpayne-codex", "nathanpayne-cursor"],
    headSha: "HEAD",
    hasLabel: false,
  }));
')
if [[ "$COMMENTED" == "noop" ]]; then
  pass "COMMENTED reviews do not trigger a disagreement"
else
  fail "COMMENTED + APPROVED expected noop, got $COMMENTED"
fi

# --- resolveDisagreement: the job's whole decision (#2727 3d) ---
# Cases: a proven allow-list, then every unproven form (#975), which must
# classify every reviewer on the PR and never remove the label.
RESOLVE_OUT=$(DETECTOR_PATH="$DETECTOR" node -e '
  const { resolveDisagreement } = require(process.env.DETECTOR_PATH);
  const conflict = [
    { user:{login:"random-human"}, state:"APPROVED", commit_id:"HEAD", submitted_at:"2026-05-12T10:00:00Z" },
    { user:{login:"random-other"}, state:"CHANGES_REQUESTED", commit_id:"HEAD", submitted_at:"2026-05-12T11:00:00Z" },
  ];
  const cases = [
    ["proven list ignores outsiders", { reviews: conflict, reviewersJson: "[\"nathanpayne-claude\"]", headSha: "HEAD", hasLabel: false }, "noop", true],
    ["proven list clears a resolved escalation", { reviews: [], reviewersJson: "[\"nathanpayne-claude\"]", headSha: "HEAD", hasLabel: true }, "remove", true],
    ["missing list classifies every reviewer", { reviews: conflict, headSha: "HEAD", hasLabel: false }, "apply", false],
    ["empty list classifies every reviewer", { reviews: conflict, reviewersJson: "[]", headSha: "HEAD", hasLabel: false }, "apply", false],
    ["malformed list never removes", { reviews: [], reviewersJson: "{nope", headSha: "HEAD", hasLabel: true }, "noop", false],
    ["non-array list never removes", { reviews: [], reviewersJson: "{\"a\":1}", headSha: "HEAD", hasLabel: true }, "noop", false],
    ["list without a usable name never removes", { reviews: [], reviewersJson: "[\"\", 7, null]", headSha: "HEAD", hasLabel: true }, "noop", false],
  ];
  for (const [name, input, decision, proven] of cases) {
    const got = resolveDisagreement(input);
    const ok = got.decision === decision && got.allowListProven === proven;
    process.stdout.write(`${ok ? "PASS" : "FAIL"}\t${name}\t${JSON.stringify(got)}\n`);
  }
')
while IFS=$'\t' read -r verdict name got; do
  if [[ "$verdict" == "PASS" ]]; then pass "resolveDisagreement: $name"; else fail "resolveDisagreement: $name (got $got)"; fi
done <<<"$RESOLVE_OUT"

# --- The real detect-disagreement step ---
# Runs the workflow's "Check for conflicting reviews" script with fake GitHub
# APIs, once against the current module and once against a default-branch
# module that predates resolveDisagreement (the bootstrap case), which must
# treat the allow-list as unproven: no removal, and a failed run.
STEP_OUT=$(ROOT="$ROOT" node -e '
  const fs = require("fs");
  const path = require("path");
  const source = fs.readFileSync(path.join(process.env.ROOT, ".github/workflows/agent-review.yml"), "utf8");
  const step = source.slice(source.indexOf("      - name: Check for conflicting reviews"));
  const lines = step.slice(step.indexOf("          script: |\n") + "          script: |\n".length).split("\n");
  const script = [];
  for (const line of lines) {
    if (line && !line.startsWith("            ")) break;
    script.push(line.replace(/^ {12}/, ""));
  }
  const AsyncFunction = Object.getPrototypeOf(async function() {}).constructor;
  const run = new AsyncFunction("github", "context", "core", "require", script.join("\n"));
  const real = require(path.join(process.env.ROOT, "scripts/disagreement-detector.cjs"));
  async function attempt(detector) {
    const calls = []; let failed = null;
    const github = {
      paginate: async () => [],
      rest: {
        pulls: { listReviews() {} },
        issues: {
          listLabelsOnIssue: async () => ({ data: [{ name: "needs-human-review" }] }),
          addLabels: async () => calls.push("addLabels"),
          removeLabel: async () => calls.push("removeLabel"),
          createComment: async () => calls.push("createComment"),
        },
      },
    };
    const context = { repo: { owner: "o", repo: "r" }, payload: { pull_request: { number: 7, head: { sha: "HEAD" } } } };
    const core = { setFailed: message => { failed = message; } };
    const fakeRequire = name => name.endsWith("disagreement-detector.cjs") ? detector : require(name);
    process.env.GITHUB_WORKSPACE = process.env.ROOT;
    process.env.REVIEWERS_JSON = "[\"nathanpayne-claude\"]";
    await run(github, context, core, fakeRequire);
    return { calls: calls.join(","), failed: Boolean(failed) };
  }
  (async () => {
    const current = await attempt(real);
    const ok1 = current.calls === "removeLabel,createComment" && current.failed === false;
    process.stdout.write(`${ok1 ? "PASS" : "FAIL"}\tcurrent module clears a resolved escalation\t${JSON.stringify(current)}\n`);
    const legacy = await attempt({ decide: real.decide });
    const ok2 = legacy.calls === "" && legacy.failed === true;
    process.stdout.write(`${ok2 ? "PASS" : "FAIL"}\ta module without resolveDisagreement fails closed\t${JSON.stringify(legacy)}\n`);
  })().catch(error => { process.stdout.write(`FAIL\tstep runner threw\t${error.message}\n`); });
')
while IFS=$'\t' read -r verdict name got; do
  if [[ "$verdict" == "PASS" ]]; then pass "workflow step: $name"; else fail "workflow step: $name (got $got)"; fi
done <<<"$STEP_OUT"

echo
echo "test_disagreement_detector: $PASS PASS / $FAIL FAIL"
[[ "$FAIL" -eq 0 ]] || exit 1
