#!/usr/bin/env python3
"""pipeline_token_checkouts -- the regression gate for #2775.

Invoked through `scripts/ci/check_pipeline_token_checkouts`, the shell
launcher repo_lint wires; the launcher passes its arguments straight through.

THE RULE

    On an event whose default checkout is the pull request's merge ref
    (`pull_request`, `pull_request_review`, `pull_request_review_comment`), a
    job that holds one of the three pipeline tokens -- AUTHOR_MERGE_TOKEN,
    REVIEWER_ASSIGNMENT_TOKEN, CI_ACTOR_TOKEN -- must not check out a
    candidate-controlled tree. On `pull_request_target` the default checkout is
    the base, so only an explicit candidate `ref:` counts there.

Why: #2775 found agent-review.yml's `detect-disagreement` job checking out
`refs/pull/N/merge` (no `ref:`), then `require()`ing
scripts/disagreement-detector.cjs and a run-time-installed js-yaml inside the
github-script process that held the CI-actor PAT. Any same-repository branch
could rewrite the detector and run it with the token. Every other PAT-bearing
job pins its checkout to the default branch or the base SHA; this gate keeps
it that way across `.github/workflows/`.

THE SHAPE IS THE VIOLATION

A token-holding job with a candidate checkout fails whatever its later steps
look like. "Does this step execute something from the checkout?" has no
complete static answer: a variable path, a command wrapper (`timeout`, `env`,
`eval`, `sh -c '...'`, `xargs`), an env-file write, or a config file a tool
reads on its own all escape a pattern scan. Each new spelling would be a new
hole, so the gate does not try to recognise execution at all.

REVIEWED DATA-ONLY JOBS

A job that needs the candidate tree as DATA and runs no code from it is
recorded in REVIEWED_CANDIDATE_CHECKOUTS with its reason and the SHA-256 of
its exact source block in the workflow file (the job's key line through the
line before the next line at or above its indentation). The review covers that
text and nothing else: any edit to the job -- one added step, one changed
argument, one comment -- fails the gate until someone re-reviews the job and
records the new hash, which the failure prints. An entry whose job no longer
has the shape fails as stale, so the list cannot outlive the code it vouches
for.

A checkout is PINNED when its `ref:` is exactly one of the trusted
expressions in TRUSTED_REF_EXPRESSIONS and that expression is populated on
every pull-request event the workflow listens to. `github.base_ref` exists only
on `pull_request` and `pull_request_target`; on a review event it is empty, and
checkout then falls back to the merge ref. Anything else -- a literal branch,
tag or SHA (a same-repository branch is exactly the threat), `github.head_ref`,
`github.sha`, `github.event.pull_request.head.*`, a mixed expression -- is
unpinned. This is an allow-list on purpose: a deny-list of candidate
expressions is the fail-open shape.

DOES NOT CATCH

    * A reviewed job's code that is unchanged but reaches candidate files
      through something outside its block (a trusted helper it calls). The
      review has to cover what those helpers do with the candidate tree.
    * Composite actions under `.github/actions/` and reusable workflows
      called with `secrets: inherit`; only `.github/workflows/*.y(a)ml` jobs
      with steps are read.
    * Events other than the four pull-request events above (`workflow_run`
      with a head checkout, `issue_comment` that checks out a PR head).

Usage:
    pipeline_token_checkouts.py              # self-test, then scan this repo
    pipeline_token_checkouts.py --self-test  # embedded cases only
    pipeline_token_checkouts.py --check [ROOT]

Exit: 0 clean, 1 violations or a failed self-test, 2 environment/usage error.
"""

import glob
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys

NAME = "check_pipeline_token_checkouts"

PIPELINE_TOKENS = ("AUTHOR_MERGE_TOKEN", "REVIEWER_ASSIGNMENT_TOKEN", "CI_ACTOR_TOKEN")
TOKEN_RE = re.compile(
    r"\bsecrets\s*\.\s*(?:%s)\b|\bsecrets\s*\[\s*['\"](?:%s)['\"]\s*\]|\btoJSON\(\s*secrets\s*\)"
    % ("|".join(PIPELINE_TOKENS), "|".join(PIPELINE_TOKENS)),
    # Secret names and expression contexts are case-insensitive in Actions:
    # `${{ Secrets.ci_actor_token }}` still hands the job the PAT.
    re.IGNORECASE,
)

MERGE_REF_EVENTS = {"pull_request", "pull_request_review", "pull_request_review_comment"}
BASE_REF_EVENTS = {"pull_request_target"}

PR_EVENTS = MERGE_REF_EVENTS | BASE_REF_EVENTS

# Trusted expression -> the pull-request events on which it is populated.
TRUSTED_REF_EXPRESSIONS = {
    "github.event.repository.default_branch": PR_EVENTS,
    "github.event.pull_request.base.sha": PR_EVENTS,
    "github.event.pull_request.base.ref": PR_EVENTS,
    "github.base_ref": {"pull_request", "pull_request_target"},
}
EXPRESSION_RE = re.compile(r"^\$\{\{\s*([A-Za-z0-9_.]+)\s*\}\}$")

# Jobs that check out the candidate as data and run no code from it, keyed by
# (workflow basename, job id). `sha256` pins the job's exact source block; an
# edit to the job fails the gate until the job is re-reviewed and this hash is
# updated to the one the failure prints.
REVIEWED_CANDIDATE_CHECKOUTS = {
    ("pr-review-policy.yml", "external-review-labeling"): {
        "sha256": "f8adb94f4bc23ca7ac5e8786bfa219276ba2e562f656def342d36689f4c021eb",
        "reason": (
            "#2725 C6/C7: the candidate tree is diffed and byte-verified as data; "
            "every helper runs from a base-SHA or default-branch git worktree, and "
            "the CI-actor PAT is used only for the label removal and the "
            "recheck dispatch."
        ),
    },
}


# --- workflow model ----------------------------------------------------------

def workflow_events(doc):
    on = doc.get("on", doc.get(True))
    if isinstance(on, str):
        return {on}
    if isinstance(on, list):
        return {e for e in on if isinstance(e, str)}
    if isinstance(on, dict):
        return {e for e in on if isinstance(e, str)}
    return set()


def ref_is_pinned(ref, events):
    if not isinstance(ref, str) or not ref.strip():
        return False
    m = EXPRESSION_RE.match(ref.strip())
    if not m or m.group(1) not in TRUSTED_REF_EXPRESSIONS:
        return False
    return (events & PR_EVENTS) <= TRUSTED_REF_EXPRESSIONS[m.group(1)]


def action_name(step):
    """The `uses:` action without its version, lower-cased: GitHub resolves
    owner and repository names case-insensitively."""
    uses = step.get("uses")
    return uses.split("@", 1)[0].strip().lower() if isinstance(uses, str) else ""


def is_checkout(step):
    return action_name(step) == "actions/checkout"


def unpinned_checkout_index(steps, events):
    """Index of the first candidate checkout in `steps`, or None."""
    merge_ref = bool(events & MERGE_REF_EVENTS)
    for idx, step in enumerate(steps):
        if not isinstance(step, dict) or not is_checkout(step):
            continue
        ref = (step.get("with") or {}).get("ref")
        if ref is None or (isinstance(ref, str) and not ref.strip()):
            if merge_ref:
                return idx
            continue
        if not ref_is_pinned(ref, events):
            return idx
    return None



_JOBS_KEY_RE = re.compile(r"^jobs:\s*(?:#.*)?$")


def _indent(line):
    return len(line) - len(line.lstrip(" "))


def job_source(text, job_id):
    """The job's source block, or None when it cannot be located.

    The block runs from the job's key line, at the indentation of the first
    entry under the top-level `jobs:`, to the line before the next non-blank
    line at or above that indentation. Trailing blank lines are dropped.
    """
    lines = text.replace("\r\n", "\n").split("\n")
    try:
        top = next(i for i, ln in enumerate(lines) if _JOBS_KEY_RE.match(ln))
    except StopIteration:
        return None
    indent = None
    for ln in lines[top + 1:]:
        if ln.strip() and not ln.lstrip().startswith("#"):
            indent = _indent(ln)
            break
    if not indent:
        return None
    key_re = re.compile(r"^ {%d}(['\"]?)%s\1:\s*(?:#.*)?$" % (indent, re.escape(job_id)))
    start = None
    for i in range(top + 1, len(lines)):
        ln = lines[i]
        if ln.strip() and _indent(ln) == 0:
            break
        if key_re.match(ln):
            start = i
            break
    if start is None:
        return None
    end = len(lines)
    for i in range(start + 1, len(lines)):
        if lines[i].strip() and _indent(lines[i]) <= indent:
            end = i
            break
    block = lines[start:end]
    while block and not block[-1].strip():
        block.pop()
    return "\n".join(block) + "\n"


def job_source_sha256(text, job_id):
    block = job_source(text, job_id)
    return None if block is None else hashlib.sha256(block.encode("utf-8")).hexdigest()


def scan_workflow(doc, basename, reviewed, text):
    """Return (violations, reviewed keys that matched)."""
    violations, matched = [], set()
    if not isinstance(doc, dict):
        return ["%s: not a mapping" % basename], matched
    events = workflow_events(doc)
    if not events & PR_EVENTS:
        return violations, matched
    workflow_level = json.dumps({k: doc.get(k) for k in ("env", "defaults")}, default=str)
    workflow_token = bool(TOKEN_RE.search(workflow_level))
    for job_id, job in (doc.get("jobs") or {}).items():
        if not isinstance(job, dict):
            continue
        steps = job.get("steps")
        if not isinstance(steps, list):
            continue
        if not (workflow_token or TOKEN_RE.search(json.dumps(job, default=str))):
            continue
        idx = unpinned_checkout_index(steps, events)
        if idx is None:
            continue
        key = (basename, str(job_id))
        where = "%s job %s" % (basename, job_id)
        if key in reviewed:
            matched.add(key)
            current = job_source_sha256(text, str(job_id))
            if current is None:
                violations.append(
                    "%s is a reviewed data-only job, but its source block cannot be "
                    "located to verify the review; treat it as unreviewed" % where)
            elif current != reviewed[key].get("sha256"):
                violations.append(
                    "%s is a reviewed data-only job whose source changed since its "
                    "review (recorded sha256 %s, now %s). Re-review that it still runs "
                    "no code from the candidate checkout while a pipeline token is in "
                    "scope, then record the new hash in REVIEWED_CANDIDATE_CHECKOUTS"
                    % (where, reviewed[key].get("sha256"), current))
            continue
        violations.append(
            "%s holds a pipeline token and checks out a candidate-controlled tree "
            "(step %d has no trusted ref:). Pin it to "
            "${{ github.event.repository.default_branch }} or the base SHA, or, for a "
            "job that runs no candidate code, record it in REVIEWED_CANDIDATE_CHECKOUTS"
            % (where, idx))
    return violations, matched


# --- YAML loading ------------------------------------------------------------

def make_loader():
    try:
        import yaml  # type: ignore

        def load(text):
            return yaml.safe_load(text)
        return load, None
    except ImportError:
        pass
    yq = shutil.which("yq")
    if yq:
        version = subprocess.run([yq, "--version"], capture_output=True, text=True).stdout
        if "mikefarah" in version:
            def load(text):
                out = subprocess.run([yq, "-p=yaml", "-o=json", "."], input=text,
                                     capture_output=True, text=True)
                if out.returncode != 0:
                    raise ValueError(out.stderr.strip())
                return json.loads(out.stdout or "null")
            return load, None
    return None, "neither PyYAML nor mikefarah/yq is available"



def scan_tree(root, load, reviewed):
    violations, matched, seen = [], set(), set()
    files = sorted(glob.glob(os.path.join(root, ".github", "workflows", "*.yml"))
                   + glob.glob(os.path.join(root, ".github", "workflows", "*.yaml")))
    for path in files:
        base = os.path.basename(path)
        seen.add(base)
        with open(path, encoding="utf-8") as fh:
            text = fh.read()
        try:
            doc = load(text)
        except Exception as exc:  # noqa: BLE001 - any parse failure fails closed
            violations.append("%s: cannot parse (%s)" % (base, exc))
            continue
        v, m = scan_workflow(doc, base, reviewed, text)
        violations += v
        matched |= m
    for key in sorted(reviewed):
        if key[0] in seen and key not in matched:
            violations.append(
                "stale REVIEWED_CANDIDATE_CHECKOUTS entry %s job %s: the job no longer "
                "holds a pipeline token with a candidate checkout; remove the entry" % key)
    return violations


# --- self-test ---------------------------------------------------------------

C4_BEFORE = """
on:
  pull_request_review:
    types: [submitted]
jobs:
  detect-disagreement:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@0000000000000000000000000000000000000000
        with:
          persist-credentials: false
      - name: Install js-yaml
        run: npm install --no-save --ignore-scripts --legacy-peer-deps js-yaml
      - uses: actions/github-script@0000000000000000000000000000000000000000
        with:
          github-token: ${{ secrets.CI_ACTOR_TOKEN || secrets.REVIEWER_ASSIGNMENT_TOKEN }}
          script: |
            const yaml = require('js-yaml');
            const { decide } = require(
              path.resolve(process.env.GITHUB_WORKSPACE, 'scripts/disagreement-detector.cjs'));
"""

C4_AFTER = C4_BEFORE.replace(
    "        with:\n          persist-credentials: false\n",
    "        with:\n          ref: ${{ github.event.repository.default_branch }}\n"
    "          persist-credentials: false\n", 1)


def _job(steps, on="pull_request", env=""):
    return "on: %s\n%sjobs:\n  j:\n    runs-on: ubuntu-latest\n    steps:\n%s" % (on, env, steps)



CHECKOUT = "      - uses: actions/checkout@v7\n"
TOKEN_STEP = "      - run: gh pr view\n        env:\n          GH_TOKEN: ${{ secrets.CI_ACTOR_TOKEN }}\n"


def _pinned(ref):
    return "      - uses: actions/checkout@v7\n        with:\n          ref: %s\n" % ref


def _run(cmd):
    return "      - run: %s\n" % cmd


# A data-only job of the C6/C7 shape: candidate checkout, helpers from a
# trusted worktree, the token used for one write. Its hash is computed by the
# self-test, which then edits it the ways Codex and CodeRabbit found the old
# execution scan could be bypassed.
REVIEWED_JOB = _job(
    CHECKOUT
    + _run('git worktree add --detach "$RUNNER_TEMP/base" "$BASE_SHA"')
    + _run('bash "$RUNNER_TEMP/base/scripts/verify.sh" "$PWD"')
    + TOKEN_STEP
) + "  other:\n    runs-on: ubuntu-latest\n    steps:\n" + _run("true")

# (name, yaml, expected violation count)
SELF_TEST_CASES = [
    ("C4 before #2775 fails", C4_BEFORE, 1),
    ("C4 after #2775 passes", C4_AFTER, 0),
    ("no-ref checkout + token fails", _job(CHECKOUT + TOKEN_STEP), 1),
    ("pull_request_review list form", _job(CHECKOUT + TOKEN_STEP, on="[push, pull_request_review]"), 1),
    ("pull_request_review_comment counts", _job(CHECKOUT + TOKEN_STEP, on="pull_request_review_comment"), 1),
    ("workflow-level env token counts",
     _job(CHECKOUT + _run("true"), env="env:\n  T: ${{ secrets.AUTHOR_MERGE_TOKEN }}\n"), 1),
    ("toJSON(secrets) counts", _job(CHECKOUT + _run("echo '${{ toJSON(secrets) }}' | jq .")), 1),
    ("lower-case secret name counts", _job(CHECKOUT + _run("echo ${{ secrets.ci_actor_token }}")), 1),
    ("mixed-case secrets context counts", _job(CHECKOUT + _run("echo ${{ Secrets.REVIEWER_ASSIGNMENT_TOKEN }}")), 1),
    ("mixed-case checkout action counts", _job("      - uses: Actions/Checkout@v7\n" + TOKEN_STEP), 1),
    ("bracket secret access counts", _job(CHECKOUT + _run("echo ${{ secrets['CI_ACTOR_TOKEN'] }}")), 1),
    ("GITHUB_TOKEN only passes", _job(CHECKOUT + _run("GH_TOKEN=${{ secrets.GITHUB_TOKEN }} ./x.sh")), 0),
    ("push-only workflow passes", _job(CHECKOUT + TOKEN_STEP, on="push"), 0),
    ("default-branch pin passes", _job(_pinned("${{ github.event.repository.default_branch }}") + TOKEN_STEP), 0),
    ("base.sha pin passes", _job(_pinned("${{ github.event.pull_request.base.sha }}") + TOKEN_STEP), 0),
    ("literal branch fails", _job(_pinned("main") + TOKEN_STEP), 1),
    ("literal feature branch fails", _job(_pinned("attacker-feature") + TOKEN_STEP), 1),
    ("literal SHA fails", _job(_pinned("0123456789abcdef0123456789abcdef01234567") + TOKEN_STEP), 1),
    ("base_ref on pull_request passes", _job(_pinned("${{ github.base_ref }}") + TOKEN_STEP), 0),
    ("base_ref on pull_request_review fails",
     _job(_pinned("${{ github.base_ref }}") + TOKEN_STEP, on="pull_request_review"), 1),
    ("base_ref with a review event beside pull_request fails",
     _job(_pinned("${{ github.base_ref }}") + TOKEN_STEP, on="[pull_request, pull_request_review_comment]"), 1),
    ("base.sha on pull_request_review passes",
     _job(_pinned("${{ github.event.pull_request.base.sha }}") + TOKEN_STEP, on="pull_request_review"), 0),
    ("head.sha ref fails", _job(_pinned("${{ github.event.pull_request.head.sha }}") + TOKEN_STEP), 1),
    ("head_ref fails", _job(_pinned("${{ github.head_ref }}") + TOKEN_STEP), 1),
    ("refs/pull literal fails", _job(_pinned("refs/pull/1/merge") + TOKEN_STEP), 1),
    ("mixed expression fails", _job(_pinned("${{ github.event.repository.default_branch || github.head_ref }}") + TOKEN_STEP), 1),
    ("empty ref fails", _job(_pinned("''") + TOKEN_STEP), 1),
    ("second checkout unpinned fails", _job(_pinned("${{ github.base_ref }}") + CHECKOUT + TOKEN_STEP), 1),
    ("prt with no ref passes", _job(CHECKOUT + TOKEN_STEP + _run("./x.sh"), on="pull_request_target"), 0),
    ("prt with head ref fails",
     _job(_pinned("${{ github.event.pull_request.head.sha }}") + TOKEN_STEP, on="pull_request_target"), 1),
    ("tokenless job with candidate checkout passes", _job(CHECKOUT + _run("./x.sh")), 0),
    ("unreviewed data-only job fails", REVIEWED_JOB, 1),
]

# Edits to REVIEWED_JOB that must each invalidate its review.
REVIEWED_EDITS = [
    ("an added wrapper-spelled execution", lambda t: t.replace(
        TOKEN_STEP, _run("timeout 30 ./evil.sh") + TOKEN_STEP, 1)),
    ("an eval of a quoted command", lambda t: t.replace(
        TOKEN_STEP, _run("eval './evil.sh'") + TOKEN_STEP, 1)),
    ("a changed argument", lambda t: t.replace('"$PWD"', '"$PWD" --exec', 1)),
    ("an added comment", lambda t: t.replace(TOKEN_STEP, "      # reviewed?\n" + TOKEN_STEP, 1)),
]


def self_test(load):
    failures, total = 0, 0

    def check(name, ok, detail=""):
        nonlocal failures, total
        total += 1
        if not ok:
            failures += 1
            print("  FAIL: %s%s" % (name, ": " + detail if detail else ""))

    for name, text, want in SELF_TEST_CASES:
        violations, _ = scan_workflow(load(text), "wf.yml", {}, text)
        check(name, len(violations) == want, "want %d violation(s), got %r" % (want, violations))

    def reviewed_for(text):
        return {("wf.yml", "j"): {"sha256": job_source_sha256(text, "j"), "reason": "fixture"}}

    review = reviewed_for(REVIEWED_JOB)
    v, _ = scan_workflow(load(REVIEWED_JOB), "wf.yml", review, REVIEWED_JOB)
    check("reviewed job at its recorded hash passes", v == [], repr(v))
    for name, edit in REVIEWED_EDITS:
        text = edit(REVIEWED_JOB)
        check("edit applies: " + name, text != REVIEWED_JOB)
        v, _ = scan_workflow(load(text), "wf.yml", review, text)
        check("reviewed job with %s fails" % name, len(v) == 1 and "source changed" in v[0], repr(v))
    # The block ends at the next job: editing a sibling keeps the review.
    sibling = REVIEWED_JOB.replace(_run("true"), _run("false"))
    check("sibling edit applies", sibling.endswith(_run("false")))
    v, _ = scan_workflow(load(sibling), "wf.yml", review, sibling)
    check("editing another job keeps the review", v == [], repr(v))
    # Block extraction: quoted key, four-space indentation, flow style.
    quoted = REVIEWED_JOB.replace("\n  j:\n", "\n  'j':\n", 1)
    check("quoted job key is located", job_source(quoted, "j") is not None)
    wide = "on: pull_request\njobs:\n    j:\n        steps: []\n    k:\n        steps: []\n"
    check("four-space job block", job_source(wide, "j") == "    j:\n        steps: []\n", repr(job_source(wide, "j")))
    flow = "on: pull_request\njobs: {j: {runs-on: x, steps: [{uses: actions/checkout@v7}, " \
           "{run: 'echo ${{ secrets.CI_ACTOR_TOKEN }}'}]}}\n"
    v, _ = scan_workflow(load(flow), "wf.yml", {("wf.yml", "j"): {"sha256": "x"}}, flow)
    check("an unlocatable reviewed job fails closed", len(v) == 1 and "cannot be located" in v[0], repr(v))

    import tempfile
    with tempfile.TemporaryDirectory() as tmp:
        wf_dir = os.path.join(tmp, ".github", "workflows")
        os.makedirs(wf_dir)
        with open(os.path.join(wf_dir, "wf.yml"), "w") as fh:
            fh.write(REVIEWED_JOB)
        v = scan_tree(tmp, load, review)
        check("scan_tree honours a matching review", v == [], repr(v))
        pinned = _job(_pinned("${{ github.event.repository.default_branch }}") + TOKEN_STEP)
        with open(os.path.join(wf_dir, "wf.yml"), "w") as fh:
            fh.write(pinned)
        v = scan_tree(tmp, load, review)
        check("stale reviewed entry fails", len(v) == 1 and "stale" in v[0], repr(v))
        os.remove(os.path.join(wf_dir, "wf.yml"))
        check("a reviewed entry for an absent workflow does not fail", scan_tree(tmp, load, review) == [])
        with open(os.path.join(wf_dir, "bad.yml"), "w") as fh:
            fh.write("on: [pull_request\n")
        v = scan_tree(tmp, load, {})
        check("an unparseable workflow fails closed", len(v) == 1 and "cannot parse" in v[0], repr(v))
    print("%s: self-test %d/%d passed" % (NAME, total - failures, total))
    return failures == 0


def main(argv):
    mode, root = "all", None
    args = list(argv)
    if args and args[0] in ("--self-test", "--check"):
        mode = args.pop(0)[2:]
    if args:
        if mode != "check" or len(args) > 1:
            print("usage: %s [--self-test | --check [ROOT]]" % NAME, file=sys.stderr)
            return 2
        root = args[0]
    load, err = make_loader()
    if load is None:
        print("%s: ERROR (%s). Install one rather than letting a credential gate skip." % (NAME, err),
              file=sys.stderr)
        return 2
    ok = True
    if mode in ("all", "self-test"):
        ok = self_test(load) and ok
    if mode in ("all", "check"):
        if root is None:
            root = subprocess.run(["git", "rev-parse", "--show-toplevel"], capture_output=True,
                                  text=True).stdout.strip() or os.getcwd()
        violations = scan_tree(root, load, REVIEWED_CANDIDATE_CHECKOUTS)
        for v in violations:
            print("%s: FAIL %s" % (NAME, v))
        if violations:
            ok = False
        else:
            print("%s: scan PASS (%s)" % (NAME, os.path.join(root, ".github", "workflows")))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
