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
its WHOLE parsed workflow document (canonical JSON). The review covers
everything that decides what the job runs, not just its own lines: triggers,
workflow-level `env` and `defaults` (a `BASH_ENV` there is sourced by every
`run:` step), YAML anchors and merge keys, and sibling jobs whose outputs it
reads. Any semantic edit to that workflow fails the gate until someone
re-reviews the job and records the new hash, which the failure prints.
Comments and formatting do not change the parsed document, so they do not
invalidate a review. An entry whose job no longer has the shape fails as
stale, so the list cannot outlive the code it vouches for.

A checkout is PINNED when every input it sets is in TRUSTED_CHECKOUT_INPUTS,
its `repository:` is absent or exactly `${{ github.repository }}`, and its
`ref:` is exactly one of the trusted expressions in TRUSTED_REF_EXPRESSIONS,
populated on every pull-request event the workflow listens to. `github.base_ref` exists only
on `pull_request` and `pull_request_target`; on a review event it is empty, and
checkout then falls back to the merge ref. Anything else -- a literal branch,
tag or SHA (a same-repository branch is exactly the threat), `github.head_ref`,
`github.sha`, `github.event.pull_request.head.*`, a mixed expression -- is
unpinned. A trusted ref in another repository (`repository: attacker/x`) or
from another server (`github-server-url:`) is unpinned too. These are
allow-lists on purpose: a deny-list of candidate expressions is the
fail-open shape.

A job HOLDS a pipeline token when any `${{ }}` expression in it, or in the
workflow-level `env`/`defaults`, reads `secrets` other than as
`secrets.<NAME>` with NAME outside the three tokens. So
`secrets.CI_ACTOR_TOKEN` (any case), `secrets['X']`,
`secrets[format(...)]` and `toJSON(secrets)` all count; only a named,
non-pipeline secret such as `secrets.GITHUB_TOKEN` does not.

DOES NOT CATCH

    * What a reviewed job's trusted helpers (outside the workflow file) do
      with the candidate tree. The fingerprint pins the workflow, so the
      review has to cover those helpers too.
    * Composite actions under `.github/actions/` and reusable workflows
      called with `secrets: inherit`; only `.github/workflows/*.y(a)ml` jobs
      with steps are read.
    * A secret reached without an expression in the job or the workflow-level
      `env`/`defaults` (for example an action that reads secrets itself).
    * Events other than the four pull-request events above (`workflow_run`
      with a head checkout, `issue_comment` that checks out a PR head).

Usage:
    pipeline_token_checkouts.py              # self-test, then scan this repo
    pipeline_token_checkouts.py --self-test  # embedded cases only
    pipeline_token_checkouts.py --check [ROOT]

Exit: 0 clean, 1 violations or a failed self-test, 2 environment/usage error.
"""

import hashlib
import json
import os
import re
import shutil
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
# The canonical owner/repo[/path]@ref check (#2823). One definition, shared
# with the CI app trust gate, so the two gates agree on what a step runs.
from ci_app_trust import action_ref  # noqa: E402

NAME = "check_pipeline_token_checkouts"

PIPELINE_TOKENS = ("AUTHOR_MERGE_TOKEN", "REVIEWER_ASSIGNMENT_TOKEN", "CI_ACTOR_TOKEN")
PIPELINE_TOKEN_NAMES = {t.lower() for t in PIPELINE_TOKENS}
# Expression contexts and secret names are case-insensitive in Actions.
_SECRETS_RE = re.compile(r"\bsecrets\b(?:\s*\.\s*([A-Za-z_][A-Za-z0-9_-]*))?", re.IGNORECASE)


def expression_bodies(text):
    """Yield the body of every `${{ ... }}` expression in `text`.

    `}}` inside a single-quoted string literal (`format('}}{0}', ...)`) does
    not close the expression. The escaped quote `''` needs no special case:
    it closes and reopens the literal. An expression
    with no closing `}}` yields the rest of the text, so a malformed one is
    read in full rather than skipped.
    """
    pos = 0
    while True:
        start = text.find("${{", pos)
        if start < 0:
            return
        i, n, quoted = start + 3, len(text), False
        while i < n:
            if quoted:
                if text[i] == "'":
                    quoted = False
            elif text[i] == "'":
                quoted = True
            elif text.startswith("}}", i):
                break
            i += 1
        yield text[start + 3:i]
        pos = i + 2


def holds_pipeline_token(text):
    """True when an expression in `text` may read a pipeline token.

    Conservative: any `secrets` access that is not a named, non-pipeline
    secret counts, because computed access (`secrets[format(...)]`,
    `toJSON(secrets)`) can reach any of them.
    """
    for body in expression_bodies(text):
        for m in _SECRETS_RE.finditer(body):
            if m.group(1) is None or m.group(1).lower() in PIPELINE_TOKEN_NAMES:
                return True
    return False


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

# actions/checkout inputs that cannot point it at other content. `ref` and
# `repository` are further constrained below; anything else, such as
# `github-server-url`, makes the checkout unpinned.
TRUSTED_CHECKOUT_INPUTS = {
    "ref", "repository", "persist-credentials", "fetch-depth", "fetch-tags",
    "path", "clean", "filter", "sparse-checkout", "sparse-checkout-cone-mode",
    "lfs", "submodules", "set-safe-directory", "show-progress", "token",
    "ssh-key", "ssh-known-hosts", "ssh-strict", "ssh-user",
}

# Jobs that check out the candidate as data and run no code from it, keyed by
# (workflow basename, job id). `sha256` pins the whole parsed workflow
# (workflow_fingerprint); a semantic edit anywhere in it fails the gate until
# the job is re-reviewed and this hash is updated to the one the failure
# prints.
REVIEWED_CANDIDATE_CHECKOUTS = {
    ("pr-review-policy.yml", "external-review-labeling"): {
        "sha256": "5f374a06d88e3b8585c2f3efdc86c9e74acac8718ca0b5f71842711a6af32c09",
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
    expr = m.group(1).lower() if m else None
    if expr not in TRUSTED_REF_EXPRESSIONS:
        return False
    return (events & PR_EVENTS) <= TRUSTED_REF_EXPRESSIONS[expr]


def checkout_is_pinned(step, events):
    inputs = step.get("with")
    if inputs is None:
        inputs = {}
    if not isinstance(inputs, dict):
        return False
    # Action inputs are case-insensitive.
    inputs = {str(k).lower(): v for k, v in inputs.items()}
    if any(k not in TRUSTED_CHECKOUT_INPUTS for k in inputs):
        return False
    repository = inputs.get("repository")
    if repository is not None:
        m = EXPRESSION_RE.match(str(repository).strip())
        if not m or m.group(1).lower() != "github.repository":
            return False
    ref = inputs.get("ref")
    if ref is None or (isinstance(ref, str) and not ref.strip()):
        # No ref: the event's default checkout, which is the merge ref on
        # the merge-ref events and the base on pull_request_target.
        return not (events & MERGE_REF_EVENTS)
    return ref_is_pinned(ref, events)


def action_name(step):
    """The canonical `uses:` action without its version, lower-cased (GitHub
    resolves owner and repository names case-insensitively); "" for a step
    with no remote action or a non-canonical one."""
    uses = step.get("uses")
    ref = action_ref(uses.strip()) if isinstance(uses, str) else None
    return ref[0] if ref else ""


def is_noncanonical(step):
    """A remote `uses:` that is not canonical owner/repo[/path]@ref. The
    runner drops empty path components, so `actions/checkout/@sha` and
    `actions//checkout@sha` run checkout; the gate cannot name what such a
    step runs, so it is refused rather than normalised (#2823)."""
    uses = step.get("uses")
    if not isinstance(uses, str):
        return False
    low = uses.strip().lower()
    if low.startswith("./") or low.startswith("docker://"):
        return False
    return action_ref(uses.strip()) is None


def is_checkout(step):
    return action_name(step) == "actions/checkout"


def noncanonical_action_index(steps):
    """Index of the first non-canonical remote action in `steps`, or None."""
    for idx, step in enumerate(steps):
        if isinstance(step, dict) and is_noncanonical(step):
            return idx
    return None


def unpinned_checkout_index(steps, events):
    """Index of the first candidate checkout in `steps`, or None."""
    for idx, step in enumerate(steps):
        if isinstance(step, dict) and is_checkout(step) and not checkout_is_pinned(step, events):
            return idx
    return None


def _canonical(node, top=False):
    if isinstance(node, dict):
        out = {}
        for k, v in node.items():
            # PyYAML (YAML 1.1) reads the top-level `on:` key as True; yq
            # (YAML 1.2) reads it as "on". Both must give one fingerprint.
            key = "on" if (top and k is True) else str(k)
            out[key] = _canonical(v)
        return out
    if isinstance(node, list):
        return [_canonical(v) for v in node]
    return node


def workflow_fingerprint(doc):
    canon = json.dumps(_canonical(doc, top=True), sort_keys=True, separators=(",", ":"),
                       ensure_ascii=False, default=str)
    return hashlib.sha256(canon.encode("utf-8")).hexdigest()


def scan_workflow(doc, basename, reviewed):
    """Return (violations, reviewed keys that matched)."""
    violations, matched = [], set()
    if not isinstance(doc, dict):
        return ["%s: not a mapping" % basename], matched
    events = workflow_events(doc)
    if not events & PR_EVENTS:
        return violations, matched
    workflow_level = json.dumps({k: doc.get(k) for k in ("env", "defaults")}, default=str)
    workflow_token = holds_pipeline_token(workflow_level)
    for job_id, job in (doc.get("jobs") or {}).items():
        if not isinstance(job, dict):
            continue
        steps = job.get("steps")
        if not isinstance(steps, list):
            continue
        if not (workflow_token or holds_pipeline_token(json.dumps(job, default=str))):
            continue
        where = "%s job %s" % (basename, job_id)
        bad = noncanonical_action_index(steps)
        if bad is not None:
            # Not reviewable: a reviewed entry cannot vouch for a step whose
            # action the gate cannot name.
            violations.append(
                "%s holds a pipeline token and step %d names its action %r, which is "
                "not a canonical owner/repo[/path]@ref reference; the runner may still "
                "run it as actions/checkout. Spell it canonically"
                % (where, bad, steps[bad].get("uses")))
            continue
        idx = unpinned_checkout_index(steps, events)
        if idx is None:
            continue
        key = (basename, str(job_id))
        if key in reviewed:
            matched.add(key)
            current = workflow_fingerprint(doc)
            if current != reviewed[key].get("sha256"):
                violations.append(
                    "%s is a reviewed data-only job whose workflow changed since its "
                    "review (recorded sha256 %s, now %s). Re-review that the job still "
                    "runs no code from the candidate checkout while a pipeline token is "
                    "in scope, then record the new hash in REVIEWED_CANDIDATE_CHECKOUTS"
                    % (where, reviewed[key].get("sha256"), current))
            continue
        violations.append(
            "%s holds a pipeline token and checks out a candidate-controlled tree "
            "(step %d is not pinned to trusted content). Pin it to "
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
    # os.listdir, not glob: glob's `*` skips dot-prefixed names, and GitHub
    # runs `.github/workflows/.x.yml` like any other workflow (#2802).
    wf_dir = os.path.join(root, ".github", "workflows")
    files = sorted(os.path.join(wf_dir, n) for n in (os.listdir(wf_dir) if os.path.isdir(wf_dir) else [])
                   if n.endswith((".yml", ".yaml")) and os.path.isfile(os.path.join(wf_dir, n)))
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
        v, m = scan_workflow(doc, base, reviewed)
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
# trusted worktree, the token used for one write. Its fingerprint is computed
# by the self-test, which then edits the workflow the ways the reviews of #2786
# found the earlier execution scan and job-text hash could be bypassed.
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
    ("toJSON ( secrets ) with spaces counts", _job(CHECKOUT + _run("echo '${{ toJSON ( secrets ) }}'")), 1),
    ("computed bracket access counts",
     _job(CHECKOUT + _run("echo ${{ secrets[format('CI_{0}_TOKEN', 'ACTOR')] }}")), 1),
    ("a quoted }} inside the expression does not hide the read",
     _job(CHECKOUT + _run("echo \"${{ format('}}{0}', secrets.CI_ACTOR_TOKEN) }}\"")), 1),
    ("an escaped quote inside a string literal does not end it",
     _job(CHECKOUT + _run("echo \"${{ format('it''s }}{0}', secrets.CI_ACTOR_TOKEN) }}\"")), 1),
    ("an unterminated expression is read to the end",
     _job(CHECKOUT + _run("echo \"${{ format('{0}', secrets.CI_ACTOR_TOKEN)\"")), 1),
    ("spaced dot access counts", _job(CHECKOUT + _run("echo ${{ secrets . CI_ACTOR_TOKEN }}")), 1),
    ("lower-case secret name counts", _job(CHECKOUT + _run("echo ${{ secrets.ci_actor_token }}")), 1),
    ("mixed-case secrets context counts", _job(CHECKOUT + _run("echo ${{ Secrets.REVIEWER_ASSIGNMENT_TOKEN }}")), 1),
    ("mixed-case checkout action counts", _job("      - uses: Actions/Checkout@v7\n" + TOKEN_STEP), 1),
    # #2823: the runner drops empty path components, so these run checkout.
    ("a trailing-slash checkout counts",
     _job("      - uses: actions/checkout/@0000000000000000000000000000000000000000\n" + TOKEN_STEP), 1),
    ("a double-slash checkout counts",
     _job("      - uses: actions//checkout@0000000000000000000000000000000000000000\n" + TOKEN_STEP), 1),
    ("a pinned non-canonical checkout still fails",
     _job("      - uses: actions//checkout@v7\n        with:\n          ref: ${{ github.event.pull_request.base.sha }}\n"
          + TOKEN_STEP), 1),
    ("a dot-segment action fails", _job("      - uses: actions/./checkout@v7\n" + TOKEN_STEP), 1),
    ("a non-canonical action in a tokenless job passes",
     _job("      - uses: actions//checkout@v7\n" + _run("./x.sh")), 0),
    ("a local action is not a non-canonical remote one",
     _job(_pinned("${{ github.event.pull_request.base.sha }}") + "      - uses: ./.github/actions/x\n" + TOKEN_STEP), 0),
    ("bracket secret access counts", _job(CHECKOUT + _run("echo ${{ secrets['CI_ACTOR_TOKEN'] }}")), 1),
    ("GITHUB_TOKEN only passes", _job(CHECKOUT + _run("GH_TOKEN=${{ secrets.GITHUB_TOKEN }} ./x.sh")), 0),
    ("the word secrets outside an expression passes", _job(CHECKOUT + _run("echo no secrets here")), 0),
    ("push-only workflow passes", _job(CHECKOUT + TOKEN_STEP, on="push"), 0),
    ("default-branch pin passes", _job(_pinned("${{ github.event.repository.default_branch }}") + TOKEN_STEP), 0),
    ("mixed-case trusted expression passes", _job(_pinned("${{ GitHub.Event.Repository.Default_Branch }}") + TOKEN_STEP), 0),
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
    ("trusted ref in another repository fails",
     _job(_pinned("${{ github.event.repository.default_branch }}") + "          repository: attacker/evil\n" + TOKEN_STEP), 1),
    ("trusted ref with repository github.repository passes",
     _job(_pinned("${{ github.event.repository.default_branch }}") + "          repository: ${{ github.repository }}\n" + TOKEN_STEP), 0),
    ("another server fails",
     _job(_pinned("${{ github.event.repository.default_branch }}") + "          github-server-url: https://evil.example\n" + TOKEN_STEP), 1),
    ("an unknown checkout input fails",
     _job(_pinned("${{ github.event.repository.default_branch }}") + "          new-input: x\n" + TOKEN_STEP), 1),
    ("a mixed-case Ref input is still the ref",
     _job("      - uses: actions/checkout@v7\n        with:\n          Ref: ${{ github.event.pull_request.head.sha }}\n" + TOKEN_STEP), 1),
    ("a mixed-case Ref input with a trusted value passes",
     _job("      - uses: actions/checkout@v7\n        with:\n          Ref: ${{ github.event.pull_request.base.sha }}\n" + TOKEN_STEP), 0),
    ("prt with no ref passes", _job(CHECKOUT + TOKEN_STEP + _run("./x.sh"), on="pull_request_target"), 0),
    ("prt with no ref in another repository fails",
     _job("      - uses: actions/checkout@v7\n        with:\n          repository: attacker/evil\n" + TOKEN_STEP,
          on="pull_request_target"), 1),
    ("prt with head ref fails",
     _job(_pinned("${{ github.event.pull_request.head.sha }}") + TOKEN_STEP, on="pull_request_target"), 1),
    ("tokenless job with candidate checkout passes", _job(CHECKOUT + _run("./x.sh")), 0),
    ("unreviewed data-only job fails", REVIEWED_JOB, 1),
]

# Edits to REVIEWED_JOB's workflow that must each invalidate its review.
REVIEWED_EDITS = [
    ("an added wrapper-spelled execution", lambda t: t.replace(
        TOKEN_STEP, _run("timeout 30 ./evil.sh") + TOKEN_STEP, 1)),
    ("an eval of a quoted command", lambda t: t.replace(
        TOKEN_STEP, _run("eval './evil.sh'") + TOKEN_STEP, 1)),
    ("a changed argument", lambda t: t.replace('"$PWD"', '"$PWD" --exec', 1)),
    ("a step after a comment at the job's indentation", lambda t: t.replace(
        "  other:\n", "  # extra\n" + _run("./evil.sh") + "  other:\n", 1)),
    ("a workflow-level BASH_ENV", lambda t: t.replace(
        "jobs:\n", "env:\n  BASH_ENV: ${{ github.workspace }}/evil.sh\njobs:\n", 1)),
    ("job-level defaults", lambda t: t.replace(
        "  j:\n    runs-on: ubuntu-latest\n",
        "  j:\n    runs-on: ubuntu-latest\n    defaults:\n      run:\n        shell: bash --rcfile evil {0}\n", 1)),
    ("an edited sibling job", lambda t: t.replace(_run("true"), _run("./evil.sh"))),
    ("an added trigger", lambda t: t.replace("on: pull_request\n", "on: [pull_request, pull_request_target]\n", 1)),
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
        violations, _ = scan_workflow(load(text), "wf.yml", {})
        check(name, len(violations) == want, "want %d violation(s), got %r" % (want, violations))

    review = {("wf.yml", "j"): {"sha256": workflow_fingerprint(load(REVIEWED_JOB)), "reason": "fixture"}}
    v, _ = scan_workflow(load(REVIEWED_JOB), "wf.yml", review)
    check("reviewed job at its recorded fingerprint passes", v == [], repr(v))
    for name, edit in REVIEWED_EDITS:
        text = edit(REVIEWED_JOB)
        check("edit applies: " + name, text != REVIEWED_JOB)
        v, _ = scan_workflow(load(text), "wf.yml", review)
        check("reviewed job with %s fails" % name, len(v) == 1 and "workflow changed" in v[0], repr(v))
    # Comments and formatting do not change the parsed document.
    cosmetic = "# header\n" + REVIEWED_JOB.replace("\n  other:\n", "\n  # note\n\n  other:\n", 1)
    check("cosmetic edit applies", cosmetic != REVIEWED_JOB)
    v, _ = scan_workflow(load(cosmetic), "wf.yml", review)
    check("a comment-only edit keeps the review", v == [], repr(v))
    # PyYAML reads top-level `on:` as True, yq as "on": one fingerprint.
    doc = load(REVIEWED_JOB)
    swapped = dict(doc)
    if "on" in swapped:
        swapped[True] = swapped.pop("on")
    elif True in swapped:
        swapped["on"] = swapped.pop(True)
    check("the `on` key spelling does not change the fingerprint",
          workflow_fingerprint(doc) == workflow_fingerprint(swapped))

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
        os.remove(os.path.join(wf_dir, "bad.yml"))
        with open(os.path.join(wf_dir, ".hidden.yml"), "w") as fh:
            fh.write(_job(CHECKOUT + TOKEN_STEP))
        v = scan_tree(tmp, load, {})
        check("a dot-prefixed workflow is scanned", len(v) == 1 and ".hidden.yml" in v[0], repr(v))
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
