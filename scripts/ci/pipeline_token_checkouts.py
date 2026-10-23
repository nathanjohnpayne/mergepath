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

TWO TIERS

1. Fail-closed. A token-holding job with an unpinned checkout fails, whatever
   its later steps look like. "Does this step execute something from the
   checkout?" has no complete static answer (a variable path, an env file, a
   config file a tool reads implicitly), so the shape itself is the
   violation.

2. Reviewed jobs. A job that needs the candidate tree as DATA and runs no code
   from it can be recorded in REVIEWED_CANDIDATE_CHECKOUTS with the reason.
   Tier 1 then passes it, but the steps after its unpinned checkout are still
   scanned for the execution shapes below, and any hit fails. An entry whose
   job no longer has the shape fails as stale, so the list cannot outlive the
   code it vouches for.

A checkout is PINNED when its `ref:` is exactly one of the trusted
expressions in TRUSTED_REF_EXPRESSIONS and that expression is populated on
every pull-request event the workflow listens to. `github.base_ref` exists only
on `pull_request` and `pull_request_target`; on a review event it is empty, and
checkout then falls back to the merge ref. Anything else -- a literal branch,
tag or SHA (a same-repository branch is exactly the threat), `github.head_ref`,
`github.sha`, `github.event.pull_request.head.*`, a mixed expression -- is
unpinned. This is an allow-list on purpose: a deny-list of candidate
expressions is the fail-open shape.

EXECUTION SHAPES (tier 2)

    * `uses: ./...`: a local action.
    * `run:` -- at a command position, a relative path (`./x`, `scripts/x`),
      an interpreter (bash, sh, source, `.`, node, python, ...) given a
      relative path or a `$GITHUB_WORKSPACE`/`$PWD`-rooted one, or a package
      manager or build tool (npm, npx, yarn, pnpm, make, ...), which reads
      config from the tree or resolves packages at run time.
    * `actions/github-script` -- any `require()`/`import()` that is not a
      string literal naming a Node built-in, and any child-process or
      `exec.*` call given a relative or workspace path.

DOES NOT CATCH

    * Execution through a variable path (`bash "$HELPER"`) in a reviewed job.
      The variable's value is not static. Tier 1 still catches every
      unreviewed job regardless.
    * A step that copies candidate bytes into $GITHUB_ENV / $GITHUB_PATH
      (NODE_OPTIONS, PATH, LD_PRELOAD) without executing anything itself.
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

# Jobs that check out the candidate as data and run no code from it. Keyed by
# (workflow basename, job id). Each still gets the tier-2 execution scan.
REVIEWED_CANDIDATE_CHECKOUTS = {
    ("pr-review-policy.yml", "external-review-labeling"): (
        "#2725 C6/C7: the candidate tree is diffed and byte-verified as data; "
        "every helper runs from a base-SHA or default-branch git worktree, and "
        "the CI-actor PAT is used only for the label removal and the "
        "recheck dispatch."
    ),
}

NODE_BUILTINS = {
    "assert", "buffer", "child_process", "crypto", "dns", "events", "fs",
    "fs/promises", "http", "https", "net", "os", "path", "perf_hooks",
    "process", "querystring", "readline", "stream", "string_decoder",
    "timers", "tls", "url", "util", "v8", "vm", "worker_threads", "zlib",
}

# --- run: scanning -----------------------------------------------------------

_CMD_START = (
    r"(?:^|[;&|(`]|\$\(|\b(?:then|do|else|elif|if|while|until|exec|time|sudo|xargs)\b|!)"
    r"\s*(?:[A-Za-z_][A-Za-z0-9_]*=\S*\s+)*"
)
_WORKSPACE_ROOT = r"(?:\$\{?GITHUB_WORKSPACE\}?|\$\{\{\s*github\.workspace\s*\}\}|\$\{?PWD\}?|\$\(pwd\))/"
_SCRIPT_EXT = r"\.(?:sh|bash|js|cjs|mjs|ts|py|rb|pl)\b"
# A relative path operand: no leading `/`, `$`, `~` or `-`; contains a slash
# or ends in a script extension.
_REL_OPERAND = (
    r"[\"']?(?:" + _WORKSPACE_ROOT + r"|(?![$/~\"'-])(?:[\w.-]+/[^\s\"';|&)]*|[\w.-]+" + _SCRIPT_EXT + r"))"
)
_INTERPRETERS = r"(?:bash|sh|zsh|dash|ksh|source|\.|node|nodejs|python3?|perl|ruby|deno|bun|tsx|ts-node|pwsh)"
RUN_PATTERNS = (
    ("runs a relative path", re.compile(_CMD_START + r"[\"']?(?:\.{1,2}/|" + _WORKSPACE_ROOT + r"|(?![$/~\"'-])[\w.-]+/)[\w./-]+")),
    ("passes a checkout file to an interpreter",
     re.compile(_CMD_START + _INTERPRETERS + r"\s+(?:-{1,2}[\w-]+(?:=\S+)?\s+)*" + _REL_OPERAND)),
    ("runs a package manager or build tool",
     re.compile(_CMD_START + r"(?:npm|npx|yarn|pnpm|corepack|make|gradle|mvn|cargo|poetry|bundle|rake|pip3?\s+install|go\s+(?:run|generate|build|test))\b")),
)


_TEXT_BLANKED = set(";&|()`<>!")
_HEREDOC_RE = re.compile(r"<<(-?)\s*(['\"]?)([A-Za-z_][A-Za-z0-9_]*)\2")
_WORKSPACE_EXPR_RE = re.compile(r"\$\{\{\s*github\.workspace\s*\}\}")
_EXPR_RE = re.compile(r"\$\{\{.*?\}\}", re.S)


def _text(c):
    return "_" if c.isspace() or c in _TEXT_BLANKED else c


def neutralize_shell(src, start="N"):
    """Return `src` with quoted text unable to look like a command position.

    Inside quotes and heredoc bodies, whitespace and shell operators become
    `_`, so prose such as "run scripts/x" never starts a command; `$(...)` and
    backtick substitutions inside double quotes or an unquoted heredoc stay
    code. Comments are dropped. Positions are not preserved.
    """
    out = []
    stack = [[start, 0]]
    pending = []
    i, n = 0, len(src)
    while i < n:
        mode, c = stack[-1][0], src[i]
        if mode == "S":
            if c == "'":
                stack.pop()
                out.append(c)
            else:
                out.append(_text(c))
            i += 1
            continue
        if mode in ("D", "H"):
            if c == "\\" and i + 1 < n:
                out.append("__")
                i += 2
                continue
            if c == '"' and mode == "D":
                stack.pop()
                out.append(c)
                i += 1
                continue
            if src.startswith("$(", i):
                stack.append(["N", 0])
                out.append(";")
                i += 2
                continue
            if c == "`":
                stack.append(["BT", 0])
                out.append(";")
                i += 1
                continue
            out.append(_text(c))
            i += 1
            continue
        # Code: "N" (top level or `$(`) or "BT" (backtick substitution).
        if c == "\\" and i + 1 < n:
            out.append(" " if src[i + 1] == "\n" else "__")
            i += 2
            continue
        if mode == "BT" and c == "`":
            stack.pop()
            out.append(";")
            i += 1
            continue
        if c in "'\"`":
            stack.append([{"'": "S", '"': "D", "`": "BT"}[c], 0])
            out.append(c if c != "`" else ";")
            i += 1
            continue
        if c == "#" and (i == 0 or src[i - 1] in " \t\n;&|("):
            j = src.find("\n", i)
            i = n if j < 0 else j
            continue
        if c == "(":
            stack[-1][1] += 1
        elif c == ")":
            if stack[-1][1] == 0 and len(stack) > 1:
                stack.pop()
                out.append(";")
                i += 1
                continue
            stack[-1][1] -= 1
        if src.startswith("<<<", i):
            # A here-string: consume all three characters so the trailing
            # `<< word` is not read as a heredoc that swallows later lines.
            out.append("<<<")
            i += 3
            continue
        if c == "<":
            m = _HEREDOC_RE.match(src, i)
            if m:
                pending.append((m.group(3), bool(m.group(2)), bool(m.group(1))))
                out.append(" ")
                i = m.end()
                continue
        if c == "\n" and pending:
            out.append("\n")
            i += 1
            for delim, quoted, strip_tabs in pending:
                body = []
                while i < n:
                    j = src.find("\n", i)
                    line = src[i:] if j < 0 else src[i:j]
                    i = n if j < 0 else j + 1
                    if (line.lstrip("\t") if strip_tabs else line) == delim:
                        break
                    body.append(line)
                # One `%`-prefixed word: a body line must not sit at a
                # line start, where it would read as a command.
                text = "\n".join(body)
                out.append("%" + ("".join(_text(ch) for ch in text) if quoted
                                  else neutralize_shell(text, start="H")))
                out.append("\n")
            pending = []
            continue
        out.append(c)
        i += 1
    return "".join(out)


def _run_lines(script):
    script = _WORKSPACE_EXPR_RE.sub("$GITHUB_WORKSPACE", script)
    script = _EXPR_RE.sub("EXPR", script)
    for raw in neutralize_shell(script).splitlines():
        line = raw.strip()
        if line:
            yield line


def scan_run(script):
    hits = []
    for line in _run_lines(script):
        for label, pattern in RUN_PATTERNS:
            if pattern.search(line):
                hits.append("%s: %s" % (label, line[:160]))
                break
    return hits


# --- github-script scanning --------------------------------------------------

def strip_js_comments(source):
    """Drop // and /* */ comments, keeping string and template literals."""
    out = []
    i, n = 0, len(source)
    quote = None
    while i < n:
        c = source[i]
        if quote:
            out.append(c)
            if c == "\\" and i + 1 < n:
                out.append(source[i + 1])
                i += 2
                continue
            if c == quote:
                quote = None
            i += 1
            continue
        if c in "'\"`":
            quote = c
            out.append(c)
            i += 1
            continue
        if source.startswith("//", i):
            j = source.find("\n", i)
            i = n if j < 0 else j
            continue
        if source.startswith("/*", i):
            j = source.find("*/", i + 2)
            i = n if j < 0 else j + 2
            continue
        out.append(c)
        i += 1
    return "".join(out)


LOAD_RE = re.compile(r"\b(require|import)\s*\(\s*")
LITERAL_RE = re.compile(r"""(['"`])([^'"`\\$]*)\1\s*\)""")
EXEC_CALL_RE = re.compile(
    r"\b(?:execSync|execFileSync|spawnSync|spawn|execFile|exec\.exec|exec\.getExecOutput|exec)\s*\("
)
EXEC_PATH_RE = re.compile(
    r"""['"`](?:\.{1,2}/|[\w.-]+/[^'"`]*|[\w.-]+""" + _SCRIPT_EXT + r""")"""
    r"""|GITHUB_WORKSPACE|github\.workspace"""
)


def scan_github_script(script):
    code = strip_js_comments(script)
    hits = []
    for m in LOAD_RE.finditer(code):
        lit = LITERAL_RE.match(code, m.end())
        spec = lit.group(2) if lit else None
        name = spec[5:] if spec and spec.startswith("node:") else spec
        if name is None or name not in NODE_BUILTINS:
            shown = code[m.start():m.start() + 120].splitlines()[0]
            hits.append("%s() loads a non-built-in module: %s" % (m.group(1), shown))
    for m in EXEC_CALL_RE.finditer(code):
        window = code[m.end():m.end() + 300]
        depth, end = 1, len(window)
        for idx, ch in enumerate(window):
            if ch == "(":
                depth += 1
            elif ch == ")":
                depth -= 1
                if depth == 0:
                    end = idx
                    break
        if EXEC_PATH_RE.search(window[:end]):
            shown = code[m.start():m.start() + 120].splitlines()[0]
            hits.append("spawns a checkout path: %s" % shown)
    return hits


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


def scan_steps(steps):
    hits = []
    for idx, step in enumerate(steps):
        if not isinstance(step, dict):
            continue
        label = step.get("name") or step.get("uses") or "step %d" % idx
        uses = step.get("uses")
        if isinstance(uses, str) and uses.startswith("./"):
            hits.append("step %r runs a local action: %s" % (label, uses))
        run = step.get("run")
        if isinstance(run, str):
            hits += ["step %r %s" % (label, h) for h in scan_run(run)]
        if action_name(step) == "actions/github-script":
            script = (step.get("with") or {}).get("script")
            if isinstance(script, str):
                hits += ["step %r %s" % (label, h) for h in scan_github_script(script)]
    return hits


def scan_workflow(doc, basename, reviewed):
    """Return (violations, reviewed keys that matched)."""
    violations, matched = [], set()
    if not isinstance(doc, dict):
        return ["%s: not a mapping" % basename], matched
    events = workflow_events(doc)
    if not events & (MERGE_REF_EVENTS | BASE_REF_EVENTS):
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
        hits = scan_steps(steps[idx + 1:])
        where = "%s job %s" % (basename, job_id)
        if key in reviewed:
            matched.add(key)
            for h in hits:
                violations.append("%s (reviewed as data-only, but) %s" % (where, h))
            continue
        detail = "; ".join(hits[:3]) if hits else "no execution shape matched, but the checkout itself is the violation"
        violations.append(
            "%s holds a pipeline token and checks out a candidate-controlled tree "
            "(step %d has no trusted ref:). Pin it to "
            "${{ github.event.repository.default_branch }} or the base SHA, or "
            "record a data-only job in REVIEWED_CANDIDATE_CHECKOUTS. Evidence: %s"
            % (where, idx, detail)
        )
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
        v, m = scan_workflow(doc, base, reviewed)
        violations += v
        matched |= m
    for key, reason in sorted(reviewed.items()):
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


def _script(body):
    return ("      - uses: actions/github-script@v9\n        with:\n"
            "          github-token: ${{ secrets.REVIEWER_ASSIGNMENT_TOKEN }}\n"
            "          script: |\n" + "".join("            %s\n" % ln for ln in body.splitlines()))


REVIEWED_FIXTURE = {("wf.yml", "j"): "fixture"}

# (name, yaml, reviewed, expected violation count, substring each violation must carry)
SELF_TEST_CASES = [
    ("C4 before #2775 fails", C4_BEFORE, {}, 1, "js-yaml"),
    ("C4 after #2775 passes", C4_AFTER, {}, 0, None),
    ("no-ref checkout + token fails even without an execution shape",
     _job(CHECKOUT + TOKEN_STEP), {}, 1, "checkout itself is the violation"),
    ("pull_request_review list form", _job(CHECKOUT + TOKEN_STEP, on="[push, pull_request_review]"), {}, 1, None),
    ("pull_request_review_comment counts", _job(CHECKOUT + TOKEN_STEP, on="pull_request_review_comment"), {}, 1, None),
    ("workflow-level env token counts",
     _job(CHECKOUT + _run("./scripts/x.sh"), env="env:\n  T: ${{ secrets.AUTHOR_MERGE_TOKEN }}\n"), {}, 1, "relative path"),
    ("toJSON(secrets) counts", _job(CHECKOUT + _run("echo '${{ toJSON(secrets) }}' | jq .")), {}, 1, None),
    ("lower-case secret name counts", _job(CHECKOUT + _run("echo ${{ secrets.ci_actor_token }}")), {}, 1, None),
    ("mixed-case secrets context counts", _job(CHECKOUT + _run("echo ${{ Secrets.REVIEWER_ASSIGNMENT_TOKEN }}")), {}, 1, None),
    ("mixed-case checkout action counts",
     _job("      - uses: Actions/Checkout@v7\n" + TOKEN_STEP), {}, 1, None),
    ("bracket secret access counts", _job(CHECKOUT + _run("echo ${{ secrets['CI_ACTOR_TOKEN'] }}")), {}, 1, None),
    ("GITHUB_TOKEN only passes", _job(CHECKOUT + _run("GH_TOKEN=${{ secrets.GITHUB_TOKEN }} ./x.sh")), {}, 0, None),
    ("push-only workflow passes", _job(CHECKOUT + TOKEN_STEP + _run("./x.sh"), on="push"), {}, 0, None),
    ("default-branch pin passes", _job(_pinned("${{ github.event.repository.default_branch }}") + TOKEN_STEP + _run("./x.sh")), {}, 0, None),
    ("base.sha pin passes", _job(_pinned("${{ github.event.pull_request.base.sha }}") + TOKEN_STEP), {}, 0, None),
    ("literal branch fails", _job(_pinned("main") + TOKEN_STEP), {}, 1, None),
    ("literal feature branch fails", _job(_pinned("attacker-feature") + TOKEN_STEP), {}, 1, None),
    ("literal SHA fails", _job(_pinned("0123456789abcdef0123456789abcdef01234567") + TOKEN_STEP), {}, 1, None),
    ("base_ref on pull_request passes", _job(_pinned("${{ github.base_ref }}") + TOKEN_STEP), {}, 0, None),
    ("base_ref on pull_request_review fails",
     _job(_pinned("${{ github.base_ref }}") + TOKEN_STEP, on="pull_request_review"), {}, 1, None),
    ("base_ref with a review event beside pull_request fails",
     _job(_pinned("${{ github.base_ref }}") + TOKEN_STEP, on="[pull_request, pull_request_review_comment]"), {}, 1, None),
    ("base.sha on pull_request_review passes",
     _job(_pinned("${{ github.event.pull_request.base.sha }}") + TOKEN_STEP, on="pull_request_review"), {}, 0, None),
    ("head.sha ref fails", _job(_pinned("${{ github.event.pull_request.head.sha }}") + TOKEN_STEP), {}, 1, None),
    ("head_ref fails", _job(_pinned("${{ github.head_ref }}") + TOKEN_STEP), {}, 1, None),
    ("refs/pull literal fails", _job(_pinned("refs/pull/1/merge") + TOKEN_STEP), {}, 1, None),
    ("mixed expression fails", _job(_pinned("${{ github.event.repository.default_branch || github.head_ref }}") + TOKEN_STEP), {}, 1, None),
    ("empty ref fails", _job(_pinned("''") + TOKEN_STEP), {}, 1, None),
    ("second checkout unpinned fails",
     _job(_pinned("${{ github.base_ref }}") + CHECKOUT + TOKEN_STEP), {}, 1, None),
    ("prt with no ref passes", _job(CHECKOUT + TOKEN_STEP + _run("./x.sh"), on="pull_request_target"), {}, 0, None),
    ("prt with head ref fails",
     _job(_pinned("${{ github.event.pull_request.head.sha }}") + TOKEN_STEP, on="pull_request_target"), {}, 1, None),
    ("tokenless job with candidate checkout passes", _job(CHECKOUT + _run("./x.sh")), {}, 0, None),
    # Reviewed (data-only) jobs: tier 2.
    ("reviewed data-only job passes",
     _job(CHECKOUT + TOKEN_STEP + _run('bash "$TRUSTED/helper.sh" "$PWD"') + _run("git diff --name-only HEAD~1")
          + _run('bash -c "echo hi"') + _script("const fs = require('fs');\nconst p = require('node:path');\n// require('evil')")),
     REVIEWED_FIXTURE, 0, None),
    ("reviewed: ./ path", _job(CHECKOUT + TOKEN_STEP + _run("./scripts/do.sh")), REVIEWED_FIXTURE, 1, "relative path"),
    ("reviewed: bare relative path", _job(CHECKOUT + TOKEN_STEP + _run("scripts/do.sh --flag")), REVIEWED_FIXTURE, 1, "relative path"),
    ("reviewed: env-prefixed path", _job(CHECKOUT + TOKEN_STEP + _run("FOO=1 ./do.sh")), REVIEWED_FIXTURE, 1, "relative path"),
    ("reviewed: after &&", _job(CHECKOUT + TOKEN_STEP + _run("cd x && ./do")), REVIEWED_FIXTURE, 1, "relative path"),
    ("reviewed: bash file", _job(CHECKOUT + TOKEN_STEP + _run("bash scripts/do.sh")), REVIEWED_FIXTURE, 1, None),
    ("reviewed: bash -e file", _job(CHECKOUT + TOKEN_STEP + _run("bash -e do.sh")), REVIEWED_FIXTURE, 1, "interpreter"),
    ("reviewed: source", _job(CHECKOUT + TOKEN_STEP + _run("source lib/x.sh")), REVIEWED_FIXTURE, 1, None),
    ("reviewed: dot", _job(CHECKOUT + TOKEN_STEP + _run(". lib/x.sh")), REVIEWED_FIXTURE, 1, None),
    ("reviewed: node", _job(CHECKOUT + TOKEN_STEP + _run("node tool.mjs")), REVIEWED_FIXTURE, 1, "interpreter"),
    ("reviewed: python", _job(CHECKOUT + TOKEN_STEP + _run("python3 -u tool.py")), REVIEWED_FIXTURE, 1, "interpreter"),
    ("reviewed: workspace path", _job(CHECKOUT + TOKEN_STEP + _run('bash "$GITHUB_WORKSPACE/x"')), REVIEWED_FIXTURE, 1, None),
    ("reviewed: github.workspace path", _job(CHECKOUT + TOKEN_STEP + _run("${{ github.workspace }}/x")), REVIEWED_FIXTURE, 1, None),
    ("reviewed: npm", _job(CHECKOUT + TOKEN_STEP + _run("npm ci")), REVIEWED_FIXTURE, 1, "package manager"),
    ("reviewed: make in if", _job(CHECKOUT + TOKEN_STEP + _run("if make lint; then :; fi")), REVIEWED_FIXTURE, 1, "package manager"),
    ("reviewed: local action",
     _job(CHECKOUT + TOKEN_STEP + "      - uses: ./.github/actions/x\n"), REVIEWED_FIXTURE, 1, "local action"),
    ("reviewed: require package", _job(CHECKOUT + _script("const y = require('js-yaml');")), REVIEWED_FIXTURE, 1, "non-built-in"),
    ("reviewed: require computed path",
     _job(CHECKOUT + _script("const d = require(path.resolve(process.env.GITHUB_WORKSPACE, 'x.cjs'));")), REVIEWED_FIXTURE, 1, None),
    ("reviewed: require relative", _job(CHECKOUT + _script("require('./x.cjs')")), REVIEWED_FIXTURE, 1, None),
    ("reviewed: dynamic import", _job(CHECKOUT + _script("await import('./x.mjs')")), REVIEWED_FIXTURE, 1, None),
    ("reviewed: execFileSync relative",
     _job(CHECKOUT + _script("const cp = require('child_process');\ncp.execFileSync('bash', ['scripts/x.sh']);")), REVIEWED_FIXTURE, 1, "spawns"),
    ("reviewed: exec.exec relative", _job(CHECKOUT + _script("await exec.exec('./x');")), REVIEWED_FIXTURE, 1, "spawns"),
    ("reviewed: comment URL does not hide code",
     _job(CHECKOUT + _script("const u = 'https://x'; require('js-yaml');")), REVIEWED_FIXTURE, 1, "non-built-in"),
    # Quoted text is data; substitutions inside it are code.
    ("reviewed: prose in quotes and heredocs passes",
     _job(CHECKOUT + TOKEN_STEP + "      - run: |\n"
          "          echo \"see \\`scripts/x.sh\\` and; ./y\"\n"
          "          printf 'Touches `.github/workflows/` only; then scripts/z.sh\\n'\n"
          "          cat <<'EOF'\n          ./not-run.sh\n          EOF\n"
          "          cat <<EOF\n          scripts/also-text.sh\n          EOF\n"
          "          echo \"${{ github.event.pull_request.title || 'x' }}\"\n"),
     REVIEWED_FIXTURE, 0, None),
    ("reviewed: $( ) inside double quotes", _job(CHECKOUT + TOKEN_STEP + _run('echo "v=$(./x.sh)"')), REVIEWED_FIXTURE, 1, "relative path"),
    ("reviewed: backtick inside unquoted heredoc",
     _job(CHECKOUT + TOKEN_STEP + "      - run: |\n          cat <<EOF\n          v=`scripts/x.sh`\n          EOF\n"),
     REVIEWED_FIXTURE, 1, "relative path"),
    ("reviewed: after a quoted string", _job(CHECKOUT + TOKEN_STEP + _run('echo "a; b" && ./x')), REVIEWED_FIXTURE, 1, None),
    ("reviewed: line after a heredoc is code",
     _job(CHECKOUT + TOKEN_STEP + "      - run: |\n          cat <<'EOF'\n          text\n          EOF\n          ./x.sh\n"),
     REVIEWED_FIXTURE, 1, None),
    ("reviewed: a here-string does not open a heredoc",
     _job(CHECKOUT + TOKEN_STEP + "      - run: |\n          grep -q x <<< done\n          ./scripts/x.sh\n          done\n"),
     REVIEWED_FIXTURE, 1, "relative path"),
    ("reviewed: mixed-case github-script is scanned",
     _job(CHECKOUT + _script("require('js-yaml')").replace("actions/github-script@v9", "Actions/GitHub-Script@v9")),
     REVIEWED_FIXTURE, 1, "non-built-in"),
    ("reviewed: steps before the checkout are not scanned",
     _job(_run("./bootstrap.sh") + CHECKOUT + TOKEN_STEP), REVIEWED_FIXTURE, 0, None),
]


def self_test(load):
    failures = 0
    for name, text, reviewed, want, needle in SELF_TEST_CASES:
        violations, _ = scan_workflow(load(text), "wf.yml", reviewed)
        ok = len(violations) == want and (needle is None or all(needle in v for v in violations))
        if not ok:
            failures += 1
            print("  FAIL: %s: want %d violation(s)%s, got %r"
                  % (name, want, " carrying %r" % needle if needle else "", violations))
    # Stale reviewed entry: the job exists but no longer has the shape.
    import tempfile
    with tempfile.TemporaryDirectory() as tmp:
        os.makedirs(os.path.join(tmp, ".github", "workflows"))
        with open(os.path.join(tmp, ".github", "workflows", "wf.yml"), "w") as fh:
            fh.write(_job(_pinned("${{ github.event.repository.default_branch }}") + TOKEN_STEP))
        v = scan_tree(tmp, load, REVIEWED_FIXTURE)
        if not (len(v) == 1 and "stale" in v[0]):
            failures += 1
            print("  FAIL: stale reviewed entry: got %r" % v)
        os.remove(os.path.join(tmp, ".github", "workflows", "wf.yml"))
        if scan_tree(tmp, load, REVIEWED_FIXTURE):
            failures += 1
            print("  FAIL: a reviewed entry for an absent workflow must not fail")
        with open(os.path.join(tmp, ".github", "workflows", "bad.yml"), "w") as fh:
            fh.write("on: [pull_request\n")
        v = scan_tree(tmp, load, {})
        if not (len(v) == 1 and "cannot parse" in v[0]):
            failures += 1
            print("  FAIL: an unparseable workflow must fail closed: got %r" % v)
    total = len(SELF_TEST_CASES) + 3
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
