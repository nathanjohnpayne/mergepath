#!/usr/bin/env python3
"""ci_app_trust -- the CI app trust gate for #2727 (ADR 0004).

Invoked through `scripts/ci/check_ci_app_trust`, the shell launcher repo_lint
wires; the launcher passes its arguments straight through.

ADR 0004 (docs/architecture/0004-trusted-privileged-jobs.md) replaces the
standing CI-actor PAT with per-job Octo STS tokens: a trusted job requests
`id-token: write`, and Octo STS exchanges its OIDC token for a one-hour
installation token under a trust policy committed at
`.github/chainguard/<identity>.sts.yaml`. Both halves are credential grants,
so this gate holds each to the ADR's exact shape.

PART A: WHO MAY REQUEST `id-token: write` (ADR "Who may request")

    Only a (workflow, job) pair in ALLOWED_ID_TOKEN_JOBS, or a reviewed
    non-app job in REVIEWED_OTHER_OIDC_JOBS (below), may hold `id-token:
    write`, directly or through `permissions: write-all`. A workflow-level
    grant is always a violation. ALLOWED_ID_TOKEN_JOBS grows one job at a
    time as #2727's slices add trusted consumers; the first is the
    thread-resolution lane's `resolve-app` job (C17, the #2732 pilot
    vehicle). Every other app consumer grant fails; the reviewed non-app jobs
    pass only under their own restrictions. An allow-listed job must also
    satisfy the ADR's execution rules:

      * every workflow trigger is one of its identity's events (no candidate
        event, no `pull_request_target`, no undeclared `workflow_dispatch`);
      * it names no `environment` (that changes the OIDC `sub`), is not a
        reusable-workflow call, and declares no job-level `container` or
        `services` image (every step would share the OIDC request variables
        with that image);
      * every checkout is this repository at `${{ github.workflow_sha }}`
        with `persist-credentials: false` and only allow-listed inputs;
      * no local action (`uses: ./...`), no `docker://` action, every other
        action a canonical `owner/repo[/path]@ref` (no empty, `.` or `..`
        component: the runner drops empty ones, so `actions/checkout/@sha`
        would run checkout under another spelling) pinned to a full 40-hex
        commit SHA;
      * no artifact download and no cache restore (`actions/cache*`, or a
        `cache` / `package-manager-cache` input on any action whose value is
        not the literal `false`). A setup action that caches by default
        (CACHE_DEFAULT_ON: `actions/setup-go` `cache`, `actions/setup-node`
        `package-manager-cache`) must turn it off explicitly; an absent input,
        or no `with:` block at all, restores a cache.

    An allow-list entry whose job no longer exists, or no longer requests the
    grant, fails as stale.

    OIDC jobs that are not app consumers (build provenance, for example) are
    reviewed one by one in REVIEWED_OTHER_OIDC_JOBS, keyed by repository. Such
    a job must sit outside every identity's workflow (so no trust policy can
    name it), mention Octo STS nowhere, not be a reusable-workflow call, and
    use only canonical SHA-pinned actions. An entry applies only in its own
    repository; where the repository is unknown, none applies.

    Every `.yml`/`.yaml` file in `.github/workflows` is read, dot-prefixed
    names included. `--check` refuses a root with no `.github/workflows`
    directory instead of passing an empty scan.

PART B: TRUST POLICY FILES (ADR "Octo STS trust policies")

    Every file in `.github/chainguard/` must be `<identity>.sts.yaml` for an
    identity in IDENTITIES, and its parsed content must EQUAL the document
    `render_policy()` builds for that identity, this repository, and the
    `repository_id`, `repository_owner_id` and `app` the file carries. So:
    exact `issuer` and `subject` (name-only or immutable form), never a
    `*_pattern` subject, issuer, audience or app; exact claim set;
    `workflow_ref` pinned to the identity's one workflow file; `event_name`
    pinned; `app` pinned; `permissions` exactly the ADR table's. The IDs must
    be decimal, and every policy in the tree must carry the same `app`, equal
    to APP_PIN. APP_PIN is None until the #2732 pilot records the pin, so a
    policy file cannot land before the pilot does.

    The repository the policies live in comes from `--repository`, then
    `GITHUB_REPOSITORY`, then the `origin` remote. If it cannot be determined
    and a policy exists, the scan fails closed.

DOES NOT CATCH

    * What Octo STS itself accepts: whether it reads policies only from the
      default branch, and the `sub` a run presents, are #2732 pilot items.
    * Job-level `if:` conditions. A workflow that mixes an allowed event with
      another (ADR: auto-clear keeps `pull_request_target` beside its
      evaluation triggers) fails Part A as written; the auto-clear slice must
      split the file or extend this rule, with its own review.
    * Composite actions under `.github/actions/` and the internals of pinned
      third-party actions.
    * Live repository and owner IDs: the gate checks they are decimal and
      consistent, not that they are this repository's. `render` takes them
      from the owner's readback (see docs/audits/ci-app-credentials-2026-10.md).

Usage:
    ci_app_trust.py                       # self-test, then scan this repo
    ci_app_trust.py --self-test           # embedded cases only
    ci_app_trust.py --check [ROOT] [--repository OWNER/NAME]
    ci_app_trust.py --render IDENTITY --repository OWNER/NAME
        --repository-id N --owner-id N [--app APP] [--immutable]

Exit: 0 clean, 1 violations or a failed self-test, 2 environment/usage error.
"""

import json
import os
import re
import shutil
import subprocess
import sys

NAME = "check_ci_app_trust"

OWNER = "nathanjohnpayne"
HUB = OWNER + "/mergepath"
# Numeric IDs (public `GET /repos/nathanjohnpayne/mergepath`, 2026-10-26). A
# fleet-read policy lives in the target repository but its token comes from
# the hub's run, so its repository and owner claims are always these; a policy
# for an OWNER repository always carries OWNER_ID.
OWNER_ID = "23488723"
HUB_REPOSITORY_ID = "1190939344"
ISSUER = "https://token.actions.githubusercontent.com"

# The numeric ID (or, on a self-hosted deployment, the configured name) of the
# one app every policy pins. Set by the #2732 pilot PR to the hosted Octo STS
# app (`octo-sts`, bot `octo-sts[bot]`; public `GET /apps/octo-sts`,
# 2026-10-26), which the owner confirms on the install screen before that PR
# merges. Every committed policy must pin exactly this value; changing it is a
# Phase 4 change that re-pins every policy in the tree.
APP_PIN = "801323"

# ADR 0004 "Policies per repository". `repo` is whose workflow presents the
# token: "self" for the four fleet-wide identities, "hub" for the two
# conditional fleet-read identities. `events` is both the policy's
# `event_name` alternation and the triggers an allow-listed workflow may have.
IDENTITIES = {
    "review-mutations": {
        "workflow": "trusted-review-mutations.yml",
        "events": ("workflow_run",),
        "permissions": {"pull_requests": "write"},
        "repo": "self",
    },
    "policy-mutations": {
        "workflow": "trusted-policy-mutations.yml",
        "events": ("workflow_run",),
        "permissions": {"pull_requests": "write"},
        "repo": "self",
    },
    "auto-clear": {
        "workflow": "auto-clear-blocking-labels.yml",
        "events": ("workflow_run", "repository_dispatch", "schedule"),
        "permissions": {"contents": "read", "pull_requests": "write", "issues": "read",
                        "checks": "read", "statuses": "read", "actions": "read"},
        "repo": "self",
    },
    "thread-resolution": {
        "workflow": "thread-resolution-lane.yml",
        "events": ("repository_dispatch",),
        "permissions": {"contents": "read", "pull_requests": "write"},
        "repo": "self",
    },
    "fleet-read-sweep": {
        "workflow": "weekly-feedback-sweep.yml",
        "events": ("schedule", "workflow_dispatch"),
        "permissions": {"pull_requests": "read"},
        "repo": "hub",
    },
    "fleet-read-drift": {
        "workflow": "weekly-drift-audit.yml",
        "events": ("schedule", "workflow_dispatch"),
        "permissions": {"contents": "read"},
        "repo": "hub",
    },
}

# (workflow basename, job id) -> identity. Each addition is a Phase 4 change to
# this file, made by the #2727 slice that adds the trusted job.
ALLOWED_ID_TOKEN_JOBS = {
    # C17, the #2732 pilot vehicle: runs only once the lane's trust policy is
    # committed (its `route` job keys on the file), which needs APP_PIN.
    ("thread-resolution-lane.yml", "resolve-app"): "thread-resolution",
    # C6 and C7 (#2727 slice 3c): inert until the owner sets the repository
    # variable CI_APP_POLICY_MUTATIONS and commits the policy-mutations trust
    # policy at cutover (#2730).
    ("trusted-policy-mutations.yml", "mutate"): "policy-mutations",
}

# OIDC jobs that are not CI app consumers, reviewed one by one:
# (repository, workflow basename, job id) -> reason. An entry applies only in
# its own repository, and only while the job stays outside every identity's
# workflow, names Octo STS nowhere, and uses only canonical SHA-pinned
# actions. No trust policy can name its workflow, so it can never mint an app
# token; the entry exists so that the allow-list above is not the only
# control and the grant is still recorded and reviewed.
REVIEWED_OTHER_OIDC_JOBS = {
    ("nathanjohnpayne/nathanpaynedotcom", "build-artifact.yml", "attest"):
        "SLSA build provenance for the deploy artifact (#1238): "
        "actions/attest-build-provenance needs id-token: write; no checkout, no repository code",
}

TRUSTED_CHECKOUT_INPUTS = {"ref", "repository", "persist-credentials", "fetch-depth",
                           "sparse-checkout", "sparse-checkout-cone-mode", "path"}
# owner/repo[/path]@ref with no empty, `.` or `..` component. The runner drops
# empty components, so `actions/checkout/@sha` runs checkout; a spelling this
# does not accept is refused rather than normalised.
ACTION_RE = re.compile(r"^([A-Za-z0-9_.-]+(?:/[A-Za-z0-9_.-]+)+)@([^@\s]+)$")
SHA_RE = re.compile(r"^[0-9a-f]{40}$")
REPO_RE = re.compile(r"^([A-Za-z0-9][A-Za-z0-9-]*)/([A-Za-z0-9._-]+)$")
DIGITS_RE = re.compile(r"^[0-9]+$")
APP_RE = re.compile(r"^(?:[0-9]+|[a-z][a-z0-9-]*)$")
POLICY_SUFFIX = ".sts.yaml"


def _expr(text):
    """`${{ x }}` -> lower-cased `x`, else None."""
    m = re.match(r"^\$\{\{\s*([A-Za-z0-9_.]+)\s*\}\}$", str(text).strip())
    return m.group(1).lower() if m else None


# --- Part B: trust policies --------------------------------------------------

def _re_literal(text):
    return re.sub(r"([.\\^$|?*+()\[\]{}])", r"\\\1", text)


def render_policy(identity, repository, repository_id, owner_id, app, immutable=False):
    """The exact policy document ADR 0004's template yields."""
    spec = IDENTITIES[identity]
    caller = repository if spec["repo"] == "self" else HUB
    owner, name = caller.split("/", 1)
    if spec["repo"] == "hub":
        repository_id = HUB_REPOSITORY_ID
    if owner == OWNER:
        owner_id = OWNER_ID
    if immutable:
        subject = "repo:%s@%s/%s@%s:ref:refs/heads/main" % (owner, owner_id, name, repository_id)
    else:
        subject = "repo:%s:ref:refs/heads/main" % caller
    events = spec["events"]
    return {
        "issuer": ISSUER,
        "subject": subject,
        "claim_pattern": {
            "repository_id": str(repository_id),
            "repository_owner_id": str(owner_id),
            "ref": "refs/heads/main",
            "workflow_ref": "%s/\\.github/workflows/%s@refs/heads/main"
                            % (_re_literal(caller), _re_literal(spec["workflow"])),
            "event_name": events[0] if len(events) == 1 else "(%s)" % "|".join(events),
            "runner_environment": "github-hosted",
        },
        "app": str(app),
        "permissions": dict(spec["permissions"]),
    }


def dump_policy(doc, identity):
    lines = ["# Octo STS trust policy `%s` (ADR 0004; generated by" % identity,
             "# scripts/ci/ci_app_trust.py --render; do not hand-edit).",
             "issuer: %s" % doc["issuer"],
             "subject: %s" % doc["subject"],
             "claim_pattern:"]
    for k, v in doc["claim_pattern"].items():
        lines.append("  %s: %s" % (k, json.dumps(v)))
    lines.append("app: %s" % json.dumps(doc["app"]))
    lines.append("permissions:")
    for k, v in doc["permissions"].items():
        lines.append("  %s: %s" % (k, v))
    return "\n".join(lines) + "\n"


def check_policy(doc, identity, repository, app_pin):
    """Violations for one parsed policy file (without the file-name prefix)."""
    if not isinstance(doc, dict):
        return ["not a mapping"]
    claims = doc.get("claim_pattern")
    claims = claims if isinstance(claims, dict) else {}
    rid, oid, app = claims.get("repository_id"), claims.get("repository_owner_id"), doc.get("app")
    out = []
    for label, value in (("repository_id", rid), ("repository_owner_id", oid)):
        if not isinstance(value, str) or not DIGITS_RE.match(value):
            out.append("claim_pattern.%s must be a quoted decimal ID, got %r" % (label, value))
    if not isinstance(app, str) or not APP_RE.match(app):
        out.append("app must be a quoted numeric app ID or app name, got %r" % (app,))
    if app_pin is None:
        out.append("no app pin is recorded (APP_PIN is None): policies land with the #2732 "
                   "pilot that records it, not before")
    elif app != app_pin:
        out.append("app %r is not the recorded pin %r" % (app, app_pin))
    if out:
        return out
    immutable = "@" in str(doc.get("subject", ""))
    want = render_policy(identity, repository, rid, oid, app, immutable=immutable)
    if doc != want:
        out.append("does not match the ADR 0004 template; expected:\n%s"
                   % dump_policy(want, identity).rstrip())
    return out


def scan_policies(root, load, repository, app_pin):
    violations = []
    pdir = os.path.join(root, ".github", "chainguard")
    if not os.path.isdir(pdir):
        return violations
    names = sorted(os.listdir(pdir))
    if names and repository is None:
        return [".github/chainguard: cannot determine this repository (pass --repository "
                "OWNER/NAME or set GITHUB_REPOSITORY); refusing to validate credential grants blind"]
    apps = set()
    for fname in names:
        rel = ".github/chainguard/" + fname
        identity = fname[:-len(POLICY_SUFFIX)] if fname.endswith(POLICY_SUFFIX) else None
        if identity not in IDENTITIES:
            violations.append("%s: not <identity>%s for an ADR 0004 identity (%s)"
                              % (rel, POLICY_SUFFIX, ", ".join(sorted(IDENTITIES))))
            continue
        try:
            with open(os.path.join(pdir, fname), encoding="utf-8") as fh:
                doc = load(fh.read())
        except Exception as exc:  # noqa: BLE001 - any parse failure fails closed
            violations.append("%s: cannot parse (%s)" % (rel, exc))
            continue
        if isinstance(doc, dict):
            apps.add(str(doc.get("app")))
        violations += ["%s: %s" % (rel, v) for v in check_policy(doc, identity, repository, app_pin)]
    if len(apps) > 1:
        violations.append(".github/chainguard: policies pin different apps %s; one app only"
                          % sorted(apps))
    return violations


# --- Part A: id-token: write -------------------------------------------------

def workflow_events(doc):
    on = doc.get("on", doc.get(True))
    if isinstance(on, str):
        return {on}
    if isinstance(on, (list, dict)):
        return {e for e in on if isinstance(e, str)}
    return set()


def grants_id_token(perms):
    """True, False, or None for a value this gate cannot read (fails closed)."""
    if perms is None:
        return False
    if isinstance(perms, str):
        p = perms.strip().lower()
        if p == "write-all":
            return True
        if p in ("read-all", "{}"):
            return False
        return None
    if isinstance(perms, dict):
        for k, v in perms.items():
            if str(k).strip().lower() == "id-token":
                if str(v).strip().lower() == "write":
                    return True
                if str(v).strip().lower() in ("read", "none"):
                    return False
                return None
        return False
    return None


def _action(step):
    return str(step.get("uses", "")).strip()


def _with(step):
    w = step.get("with")
    return {str(k).lower(): v for k, v in w.items()} if isinstance(w, dict) else {}


def action_ref(uses):
    """(lower-cased name, ref) for a canonical remote action, else None."""
    m = ACTION_RE.match(uses)
    if not m or any(c in (".", "..") for c in m.group(1).split("/")):
        return None
    return m.group(1).lower(), m.group(2)


# Inputs that restore a cache when set, and the setup actions whose cache is
# on by default: those must name the input with a literal `false`, since
# leaving it out (or the whole `with:` block) restores the action's cache.
CACHE_INPUTS = ("cache", "package-manager-cache")
CACHE_DEFAULT_ON = {
    "actions/setup-go": "cache",
    "actions/setup-node": "package-manager-cache",
}


def _off(value):
    """True only for a literal false (YAML boolean or the string)."""
    return str(value).strip().lower() == "false"


def action_violations(uses, where):
    """Violations for one step `uses:` value; also returns its canonical name."""
    low = uses.lower()
    if low.startswith("./") or low.startswith("docker://"):
        return ["%s: local and docker actions are not allowed" % where], None
    ref = action_ref(uses)
    if ref is None:
        return ["%s: not a canonical owner/repo[/path]@ref action reference" % where], None
    if not SHA_RE.match(ref[1]):
        return ["%s: not pinned to a full commit SHA" % where], ref[0]
    return [], ref[0]


def execution_violations(job, events, identity):
    out = []
    allowed = set(IDENTITIES[identity]["events"])
    extra = sorted(events - allowed)
    if not events:
        out.append("workflow triggers cannot be read")
    if extra:
        out.append("workflow also triggers on %s; identity %s allows only %s"
                   % (", ".join(extra), identity, ", ".join(sorted(allowed))))
    if "environment" in job:
        out.append("names an environment (its OIDC sub would lose the ref)")
    if "uses" in job:
        out.append("is a reusable-workflow call")
    for key in ("container", "services"):
        if key in job:
            # Every step, OIDC request variables included, runs in or beside
            # that image: third-party code that could mint the token.
            out.append("declares a job-level %s image" % key)
    for i, step in enumerate(job.get("steps") or []):
        if not isinstance(step, dict):
            out.append("step %d cannot be read" % i)
            continue
        uses = _action(step)
        if not uses:
            continue
        where = "step %d (%s)" % (i, uses)
        v, name = action_violations(uses, where)
        out += v
        if name is None:
            continue
        inputs = _with(step)
        if name in ("actions/download-artifact",) or name.startswith("actions/cache"):
            out.append("%s: artifacts and caches are not allowed" % where)
        for key in CACHE_INPUTS:
            if key in inputs and not _off(inputs[key]):
                out.append("%s: a %s input other than false is not allowed" % (where, key))
        default_on = CACHE_DEFAULT_ON.get(name)
        if default_on and default_on not in inputs:
            out.append("%s: caches by default; set %s: false" % (where, default_on))
        if name == "actions/checkout":
            unknown = sorted(set(inputs) - TRUSTED_CHECKOUT_INPUTS)
            if unknown:
                out.append("%s: checkout input(s) %s not allow-listed" % (where, ", ".join(unknown)))
            if _expr(inputs.get("ref", "")) != "github.workflow_sha":
                out.append("%s: checkout ref must be ${{ github.workflow_sha }}" % where)
            repo = inputs.get("repository")
            if repo is not None and _expr(repo) != "github.repository":
                out.append("%s: checkout repository must be absent or ${{ github.repository }}" % where)
            if str(inputs.get("persist-credentials", "")).strip().lower() != "false":
                out.append("%s: checkout must set persist-credentials: false" % where)
    return out


def other_oidc_violations(job, basename):
    out = []
    if basename in {spec["workflow"] for spec in IDENTITIES.values()}:
        out.append("is in a workflow a trust policy pins; it must be an ALLOWED_ID_TOKEN_JOBS entry")
    if "uses" in job:
        out.append("is a reusable-workflow call")
    if "octo-sts" in json.dumps(job, default=str).lower():
        out.append("mentions Octo STS; an app token exchange belongs on ALLOWED_ID_TOKEN_JOBS")
    for i, step in enumerate(job.get("steps") or []):
        if not isinstance(step, dict):
            out.append("step %d cannot be read" % i)
            continue
        uses = _action(step)
        if uses:
            out += action_violations(uses, "step %d (%s)" % (i, uses))[0]
    return out


def scan_workflow(doc, basename, allowed, repository=None, reviewed_other=None):
    """(violations, set of matched allow-list and reviewed-entry keys)."""
    reviewed_other = reviewed_other or {}
    violations, matched = [], set()
    if not isinstance(doc, dict):
        return ["%s: not a mapping" % basename], matched
    top = grants_id_token(doc.get("permissions"))
    if top is not False:
        violations.append("%s: workflow-level permissions %s id-token: write; grant it per job "
                          "on the allow-list only"
                          % (basename, "grant" if top else "cannot be read and may grant"))
    events = workflow_events(doc)
    jobs = doc.get("jobs")
    for job_id, job in (jobs.items() if isinstance(jobs, dict) else []):
        if not isinstance(job, dict):
            continue
        g = grants_id_token(job.get("permissions"))
        if g is False:
            continue
        key = (basename, str(job_id))
        where = "%s job %s" % key
        if g is None:
            violations.append("%s: permissions cannot be read and may grant id-token: write" % where)
            continue
        identity = allowed.get(key)
        other = (repository, basename, str(job_id))
        # No entry has a None repository, so an unknown repository matches none.
        if identity is None and other in reviewed_other:
            matched.add(other)
            violations += ["%s: %s" % (where, v) for v in other_oidc_violations(job, basename)]
            continue
        if identity is None:
            violations.append("%s: requests id-token: write but is not in ALLOWED_ID_TOKEN_JOBS "
                              "(ADR 0004 'Who may request id-token: write')" % where)
            continue
        matched.add(key)
        if identity not in IDENTITIES or IDENTITIES[identity]["workflow"] != basename:
            violations.append("%s: allow-listed for identity %r, whose policy pins another workflow"
                              % (where, identity))
            continue
        violations += ["%s: %s" % (where, v) for v in execution_violations(job, events, identity)]
    return violations, matched


def workflow_files(root):
    """Every .yml/.yaml file in .github/workflows, dot-prefixed names included:
    GitHub runs them, and glob's `*` skips them."""
    wf_dir = os.path.join(root, ".github", "workflows")
    if not os.path.isdir(wf_dir):
        return []
    return sorted(os.path.join(wf_dir, n) for n in os.listdir(wf_dir)
                  if n.endswith((".yml", ".yaml")) and os.path.isfile(os.path.join(wf_dir, n)))


def scan_workflows(root, load, allowed, repository=None, reviewed_other=None):
    reviewed_other = reviewed_other or {}
    violations, matched, seen = [], set(), set()
    for path in workflow_files(root):
        base = os.path.basename(path)
        seen.add(base)
        try:
            with open(path, encoding="utf-8") as fh:
                doc = load(fh.read())
        except Exception as exc:  # noqa: BLE001 - any parse failure fails closed
            violations.append("%s: cannot parse (%s)" % (base, exc))
            continue
        v, m = scan_workflow(doc, base, allowed, repository, reviewed_other)
        violations += v
        matched |= m
    for key in sorted(allowed):
        if key not in matched:
            violations.append("stale ALLOWED_ID_TOKEN_JOBS entry %s job %s: no such job requests "
                              "id-token: write; remove the entry" % key)
    for key in sorted(reviewed_other):
        if key[0] == repository and key not in matched:
            violations.append("stale REVIEWED_OTHER_OIDC_JOBS entry %s %s job %s: no such job "
                              "requests id-token: write; remove the entry" % key)
    return violations


# --- environment ---------------------------------------------------------------

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


def detect_repository(root):
    env = os.environ.get("GITHUB_REPOSITORY", "").strip()
    if REPO_RE.match(env):
        return env
    url = subprocess.run(["git", "-C", root, "remote", "get-url", "origin"],
                         capture_output=True, text=True).stdout.strip()
    m = re.search(r"github\.com[:/]([A-Za-z0-9-]+/[A-Za-z0-9._-]+?)(?:\.git)?/?$", url)
    return m.group(1) if m else None


# --- self-test -----------------------------------------------------------------

SHA = "0" * 40
GOOD_CHECKOUT = ("      - uses: actions/checkout@%s\n        with:\n"
                 "          ref: ${{ github.workflow_sha }}\n          persist-credentials: false\n" % SHA)
EXCHANGE = ("      - uses: octo-sts/action@%s\n        id: sts\n        with:\n"
            "          scope: ${{ github.repository }}\n          identity: review-mutations\n" % SHA)


def _wf(steps, on="workflow_run", perms="    permissions:\n      id-token: write\n", top="",
        job="consume", extra=""):
    return ("on: %s\n%sjobs:\n  %s:\n    runs-on: ubuntu-latest\n%s%s    steps:\n%s"
            % (on, top, job, perms, extra, steps))


ALLOW = {("trusted-review-mutations.yml", "consume"): "review-mutations"}
WF = "trusted-review-mutations.yml"

# (name, workflow basename, yaml, allow-list, expected violation count)
WORKFLOW_CASES = [
    ("no grant anywhere passes", "x.yml", _wf(GOOD_CHECKOUT, perms=""), {}, 0),
    ("unlisted id-token grant fails", "x.yml", _wf(GOOD_CHECKOUT), {}, 1),
    ("mixed-case key and value still grant", "x.yml",
     _wf(GOOD_CHECKOUT, perms="    permissions:\n      ID-Token: WRITE\n"), {}, 1),
    ("id-token: read passes", "x.yml", _wf(GOOD_CHECKOUT, perms="    permissions:\n      id-token: read\n"), {}, 0),
    ("job write-all grants", "x.yml", _wf(GOOD_CHECKOUT, perms="    permissions: write-all\n"), {}, 1),
    ("job read-all passes", "x.yml", _wf(GOOD_CHECKOUT, perms="    permissions: read-all\n"), {}, 0),
    ("unreadable job permissions fail closed", "x.yml",
     _wf(GOOD_CHECKOUT, perms="    permissions: ${{ fromJSON('{}') }}\n"), {}, 1),
    ("workflow-level grant fails even when the job is listed", WF,
     _wf(GOOD_CHECKOUT + EXCHANGE, top="permissions:\n  id-token: write\n"), ALLOW, 1),
    ("workflow-level write-all fails", "x.yml", _wf(GOOD_CHECKOUT, perms="", top="permissions: write-all\n"), {}, 1),
    ("listed trusted consumer passes", WF, _wf(GOOD_CHECKOUT + EXCHANGE), ALLOW, 0),
    ("listed job on pull_request fails", WF, _wf(GOOD_CHECKOUT + EXCHANGE, on="pull_request"), ALLOW, 1),
    ("listed job beside pull_request_target fails", WF,
     _wf(GOOD_CHECKOUT + EXCHANGE, on="[workflow_run, pull_request_target]"), ALLOW, 1),
    ("listed job on workflow_dispatch fails", WF,
     _wf(GOOD_CHECKOUT + EXCHANGE, on="[workflow_run, workflow_dispatch]"), ALLOW, 1),
    ("listed job naming an environment fails", WF,
     _wf(GOOD_CHECKOUT + EXCHANGE, extra="    environment: review-automation\n"), ALLOW, 1),
    ("listed job with no ref fails", WF,
     _wf(GOOD_CHECKOUT.replace("          ref: ${{ github.workflow_sha }}\n", "") + EXCHANGE), ALLOW, 1),
    ("listed job checking out the run head fails", WF,
     _wf(GOOD_CHECKOUT.replace("github.workflow_sha", "github.event.workflow_run.head_sha") + EXCHANGE), ALLOW, 1),
    ("listed job checking out the default branch name fails", WF,
     _wf(GOOD_CHECKOUT.replace("github.workflow_sha", "github.event.repository.default_branch") + EXCHANGE), ALLOW, 1),
    ("mixed-case trusted ref passes", WF,
     _wf(GOOD_CHECKOUT.replace("github.workflow_sha", "GitHub.Workflow_SHA") + EXCHANGE), ALLOW, 0),
    ("persisted credentials fail", WF,
     _wf(GOOD_CHECKOUT.replace("persist-credentials: false", "persist-credentials: true") + EXCHANGE), ALLOW, 1),
    ("another repository fails", WF,
     _wf(GOOD_CHECKOUT + "          repository: attacker/evil\n" + EXCHANGE), ALLOW, 1),
    ("an unknown checkout input fails", WF,
     _wf(GOOD_CHECKOUT + "          github-server-url: https://evil.example\n" + EXCHANGE), ALLOW, 1),
    ("a mixed-case Ref input is still the ref", WF,
     _wf(GOOD_CHECKOUT.replace("ref:", "Ref:").replace("github.workflow_sha", "github.head_ref") + EXCHANGE), ALLOW, 1),
    ("a local action fails", WF, _wf(GOOD_CHECKOUT + "      - uses: ./.github/actions/x\n" + EXCHANGE), ALLOW, 1),
    ("a tag-pinned action fails", WF, _wf(GOOD_CHECKOUT + EXCHANGE.replace(SHA, "v1.1.1")), ALLOW, 1),
    ("a docker action fails", WF, _wf(GOOD_CHECKOUT + "      - uses: docker://alpine:3\n" + EXCHANGE), ALLOW, 1),
    ("an artifact download fails", WF,
     _wf(GOOD_CHECKOUT + "      - uses: actions/download-artifact@%s\n" % SHA + EXCHANGE), ALLOW, 1),
    ("a cache restore fails", WF,
     _wf(GOOD_CHECKOUT + "      - uses: actions/cache/restore@%s\n" % SHA + EXCHANGE), ALLOW, 1),
    ("a setup cache input fails", WF,
     _wf(GOOD_CHECKOUT + "      - uses: actions/setup-node@%s\n        with:\n          cache: npm\n"
         "          package-manager-cache: false\n" % SHA + EXCHANGE), ALLOW, 1),
    ("setup-go with no with: block fails (cache defaults on)", WF,
     _wf(GOOD_CHECKOUT + "      - uses: actions/setup-go@%s\n" % SHA + EXCHANGE), ALLOW, 1),
    ("setup-go without a cache input fails", WF,
     _wf(GOOD_CHECKOUT + "      - uses: actions/setup-go@%s\n        with:\n          go-version: '1.22'\n" % SHA
         + EXCHANGE), ALLOW, 1),
    ("setup-go with cache: true fails", WF,
     _wf(GOOD_CHECKOUT + "      - uses: actions/setup-go@%s\n        with:\n          cache: true\n" % SHA
         + EXCHANGE), ALLOW, 1),
    ("setup-go with an expression cache fails", WF,
     _wf(GOOD_CHECKOUT + "      - uses: actions/setup-go@%s\n        with:\n          cache: ${{ false }}\n" % SHA
         + EXCHANGE), ALLOW, 1),
    ("setup-go with cache: false passes", WF,
     _wf(GOOD_CHECKOUT + "      - uses: actions/setup-go@%s\n        with:\n          cache: false\n" % SHA
         + EXCHANGE), ALLOW, 0),
    ("mixed-case setup-go with Cache: 'False' passes", WF,
     _wf(GOOD_CHECKOUT + "      - uses: Actions/Setup-Go@%s\n        with:\n          Cache: 'False'\n" % SHA
         + EXCHANGE), ALLOW, 0),
    ("setup-node with no with: block fails (package-manager-cache defaults on)", WF,
     _wf(GOOD_CHECKOUT + "      - uses: actions/setup-node@%s\n" % SHA + EXCHANGE), ALLOW, 1),
    ("setup-node with package-manager-cache: true fails", WF,
     _wf(GOOD_CHECKOUT + "      - uses: actions/setup-node@%s\n        with:\n"
         "          package-manager-cache: true\n" % SHA + EXCHANGE), ALLOW, 1),
    ("setup-node with package-manager-cache: false passes", WF,
     _wf(GOOD_CHECKOUT + "      - uses: actions/setup-node@%s\n        with:\n"
         "          node-version: 22\n          package-manager-cache: false\n" % SHA + EXCHANGE), ALLOW, 0),
    ("a package-manager-cache input on another action fails", WF,
     _wf(GOOD_CHECKOUT + "      - uses: example/setup-x@%s\n        with:\n"
         "          package-manager-cache: yes\n" % SHA + EXCHANGE), ALLOW, 1),
    ("a reusable-workflow call fails", WF,
     "on: workflow_run\njobs:\n  consume:\n    permissions:\n      id-token: write\n"
     "    uses: ./.github/workflows/x.yml\n", ALLOW, 1),
    ("a job-level container image fails", WF,
     _wf(GOOD_CHECKOUT + EXCHANGE, extra="    container: node:20\n"), ALLOW, 1),
    ("a pinned container image still fails", WF,
     _wf(GOOD_CHECKOUT + EXCHANGE, extra="    container:\n      image: node@sha256:%s\n" % ("0" * 64)), ALLOW, 1),
    ("a service container fails", WF,
     _wf(GOOD_CHECKOUT + EXCHANGE, extra="    services:\n      db:\n        image: postgres:16\n"), ALLOW, 1),
    ("a trailing-slash checkout is refused, not trusted", WF,
     _wf(GOOD_CHECKOUT.replace("actions/checkout@", "actions/checkout/@")
         .replace("github.workflow_sha", "github.event.workflow_run.head_sha") + EXCHANGE), ALLOW, 1),
    ("a trailing-slash artifact download is refused", WF,
     _wf(GOOD_CHECKOUT + "      - uses: actions/download-artifact/@%s\n" % SHA + EXCHANGE), ALLOW, 1),
    ("an empty path component is refused", WF,
     _wf(GOOD_CHECKOUT.replace("actions/checkout@", "actions//checkout@") + EXCHANGE), ALLOW, 1),
    ("a dot path component is refused", WF,
     _wf(GOOD_CHECKOUT.replace("actions/checkout@", "actions/./checkout@") + EXCHANGE), ALLOW, 1),
    ("an upper-case checkout is still checkout", WF,
     _wf(GOOD_CHECKOUT.replace("actions/checkout@", "Actions/Checkout@")
         .replace("github.workflow_sha", "github.head_ref") + EXCHANGE), ALLOW, 1),
    ("a listed job in another file fails", "other.yml", _wf(GOOD_CHECKOUT + EXCHANGE),
     {("other.yml", "consume"): "review-mutations"}, 1),
    ("a second, unlisted job in the file fails", WF,
     _wf(GOOD_CHECKOUT + EXCHANGE) + "  extra:\n    runs-on: ubuntu-latest\n"
     "    permissions:\n      id-token: write\n    steps:\n      - run: true\n", ALLOW, 1),
]


def _policy_text(doc):
    # JSON is YAML, and unlike dump_policy it keeps every mutated key.
    return json.dumps(doc)


REPO = "nathanjohnpayne/swipewatch"
PIN = "801323"


def _good(identity="review-mutations", repository=REPO, immutable=False):
    return render_policy(identity, repository, "111", "222", PIN, immutable=immutable)


def _mut(fn, identity="review-mutations"):
    doc = json.loads(json.dumps(_good(identity)))
    fn(doc)
    return doc


# (name, identity, document, app pin, expected violation count > 0)
POLICY_CASES = [
    ("rendered policy passes", "review-mutations", _good(), PIN, False),
    ("immutable subject passes", "review-mutations", _good(immutable=True), PIN, False),
    ("every identity renders clean", None, None, PIN, False),
    ("no recorded pin fails", "review-mutations", _good(), None, True),
    ("another app fails", "review-mutations", _mut(lambda d: d.update(app="999")), PIN, True),
    ("app_pattern fails", "review-mutations", _mut(lambda d: d.update(app_pattern=".*")), PIN, True),
    ("missing app fails", "review-mutations", _mut(lambda d: d.pop("app")), PIN, True),
    ("subject_pattern fails", "review-mutations", _mut(lambda d: d.update(subject_pattern="repo:.*")), PIN, True),
    ("subject_pattern instead of subject fails", "review-mutations",
     _mut(lambda d: d.update(subject_pattern=d.pop("subject"))), PIN, True),
    ("pull_request subject fails", "review-mutations",
     _mut(lambda d: d.update(subject="repo:%s:pull_request" % REPO)), PIN, True),
    ("environment subject fails", "review-mutations",
     _mut(lambda d: d.update(subject="repo:%s:environment:review-automation" % REPO)), PIN, True),
    ("another repository's subject fails", "review-mutations",
     _mut(lambda d: d.update(subject="repo:nathanjohnpayne/matchline:ref:refs/heads/main")), PIN, True),
    ("issuer_pattern fails", "review-mutations", _mut(lambda d: d.update(issuer_pattern=".*")), PIN, True),
    ("audience fails", "review-mutations", _mut(lambda d: d.update(audience="x")), PIN, True),
    ("widened event_name fails", "review-mutations",
     _mut(lambda d: d["claim_pattern"].update(event_name="(workflow_run|pull_request_target)")), PIN, True),
    ("missing event_name fails", "review-mutations", _mut(lambda d: d["claim_pattern"].pop("event_name")), PIN, True),
    ("another workflow_ref fails", "review-mutations",
     _mut(lambda d: d["claim_pattern"].update(workflow_ref=".*")), PIN, True),
    ("unescaped workflow_ref dot fails", "review-mutations",
     _mut(lambda d: d["claim_pattern"].update(
         workflow_ref=d["claim_pattern"]["workflow_ref"].replace("\\.yml", ".yml"))), PIN, True),
    ("an extra claim fails", "review-mutations", _mut(lambda d: d["claim_pattern"].update(actor="x")), PIN, True),
    ("a non-decimal repository_id fails", "review-mutations",
     _mut(lambda d: d["claim_pattern"].update(repository_id="1.*")), PIN, True),
    ("an unquoted repository_id fails", "review-mutations",
     _mut(lambda d: d["claim_pattern"].update(repository_id=111)), PIN, True),
    ("subject ids disagreeing with claims fail", "review-mutations",
     _mut(lambda d: d.update(subject=_good(immutable=True)["subject"].replace("@111", "@333"))), PIN, True),
    ("an added permission fails", "review-mutations",
     _mut(lambda d: d["permissions"].update(contents="write")), PIN, True),
    ("issues: write fails", "review-mutations", _mut(lambda d: d["permissions"].update(issues="write")), PIN, True),
    ("a raised permission fails", "fleet-read-sweep",
     _mut(lambda d: d["permissions"].update(pull_requests="write"), "fleet-read-sweep"), PIN, True),
]


def self_test(load):
    failures, total = 0, 0

    def check(name, ok, detail=""):
        nonlocal failures, total
        total += 1
        if not ok:
            failures += 1
            print("  FAIL: %s%s" % (name, ": " + detail if detail else ""))

    for name, base, text, allowed, want in WORKFLOW_CASES:
        v, _ = scan_workflow(load(text), base, allowed)
        check(name, len(v) == want, "want %d violation(s), got %r" % (want, v))

    for name, identity, doc, pin, bad in POLICY_CASES:
        if identity is None:
            for ident in IDENTITIES:
                v = check_policy(load(_policy_text(_good(ident))), ident, REPO, pin)
                check("%s: %s" % (name, ident), v == [], repr(v))
            continue
        v = check_policy(load(_policy_text(doc)), identity, REPO, pin)
        check(name, bool(v) == bad, repr(v))

    v, _ = scan_workflow(load(_wf(GOOD_CHECKOUT + EXCHANGE, perms="    permissions: ${{ x }}\n")), WF, ALLOW)
    check("a listed job with unreadable permissions fails closed",
          len(v) == 1 and "cannot be read" in v[0], repr(v))
    v, _ = scan_workflow(load(_wf(GOOD_CHECKOUT + "      - uses: ./.github/actions/x@%s\n" % SHA + EXCHANGE)),
                         WF, ALLOW)
    check("a SHA-suffixed local action still fails as local", len(v) == 1 and "local" in v[0], repr(v))

    import contextlib
    import io
    hub_doc = _good("fleet-read-drift")
    check("fleet-read policies carry the hub's repository and owner IDs",
          (hub_doc["claim_pattern"]["repository_id"], hub_doc["claim_pattern"]["repository_owner_id"])
          == (HUB_REPOSITORY_ID, OWNER_ID))
    for ident in ("fleet-read-sweep", "fleet-read-drift"):
        wrong = _mut(lambda d: d["claim_pattern"].update(repository_id="111"), ident)
        v = check_policy(load(_policy_text(wrong)), ident, REPO, PIN)
        check("%s with the storing repository's ID fails" % ident, bool(v), repr(v))
    wrong = _mut(lambda d: d["claim_pattern"].update(repository_owner_id="999"))
    v = check_policy(load(_policy_text(wrong)), "review-mutations", REPO, PIN)
    check("a fleet policy with another owner ID fails", bool(v), repr(v))
    for args, want in (
            (["fleet-read-sweep", "--repository", REPO, "--repository-id", "111", "--owner-id", OWNER_ID,
              "--app", PIN], 2),
            (["fleet-read-sweep", "--repository", REPO, "--repository-id", HUB_REPOSITORY_ID,
              "--owner-id", OWNER_ID, "--app", PIN], 0),
            (["review-mutations", "--repository", REPO, "--repository-id", "111", "--owner-id", "999",
              "--app", PIN], 2)):
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            rc = render_main(list(args))
        check("render %s %s exits %d" % (args[0], args[4], want), rc == want, "got %d" % rc)
    check("fleet-read policies carry the hub's subject", hub_doc["subject"] == "repo:%s:ref:refs/heads/main" % HUB)
    check("fleet-read workflow_ref names the hub",
          hub_doc["claim_pattern"]["workflow_ref"].startswith("nathanjohnpayne/mergepath/"))
    check("auto-clear event_name is the anchored alternation",
          _good("auto-clear")["claim_pattern"]["event_name"] == "(workflow_run|repository_dispatch|schedule)")
    check("rendered workflow_ref escapes every dot",
          _good()["claim_pattern"]["workflow_ref"]
          == "nathanjohnpayne/swipewatch/\\.github/workflows/trusted-review-mutations\\.yml@refs/heads/main")
    check("the shipped allow-list names known identities",
          all(i in IDENTITIES and IDENTITIES[i]["workflow"] == k[0] for k, i in ALLOWED_ID_TOKEN_JOBS.items()))

    # A non-app OIDC job of the nathanpaynedotcom build-artifact.yml `attest`
    # shape, reviewed under REVIEWED_OTHER_OIDC_JOBS.
    site = "nathanjohnpayne/nathanpaynedotcom"
    attest = ("on: push\njobs:\n  attest:\n    runs-on: ubuntu-latest\n    permissions:\n"
              "      contents: read\n      id-token: write\n      attestations: write\n    steps:\n"
              "      - uses: actions/download-artifact@%s\n"
              "      - uses: actions/attest-build-provenance@%s\n" % (SHA, SHA))
    other = {(site, "build-artifact.yml", "attest"): "fixture"}
    for name, text, base, repo, want in (
            ("a reviewed non-app OIDC job passes in its repository", attest, "build-artifact.yml", site, 0),
            ("the same job in another repository fails", attest, "build-artifact.yml", REPO, 1),
            ("the same job with no known repository fails closed", attest, "build-artifact.yml", None, 1),
            ("a reviewed job that adds an Octo STS step fails",
             attest + EXCHANGE, "build-artifact.yml", site, 1),
            ("a reviewed job that curls the exchange fails",
             attest + "      - run: curl https://octo-sts.dev/sts/exchange\n", "build-artifact.yml", site, 1),
            ("a reviewed job with a tag-pinned action fails",
             attest.replace("attest-build-provenance@" + SHA, "attest-build-provenance@v4"),
             "build-artifact.yml", site, 1),
            ("a reviewed job with a non-canonical action fails",
             attest.replace("actions/attest-build-provenance@", "actions/attest-build-provenance/@"),
             "build-artifact.yml", site, 1),
            ("a reviewed job turned into a reusable-workflow call fails",
             "on: push\njobs:\n  attest:\n    permissions:\n      id-token: write\n"
             "    uses: nathanjohnpayne/x/.github/workflows/y.yml@%s\n" % SHA, "build-artifact.yml", site, 1)):
        v, _ = scan_workflow(load(text), base, {}, repo, other)
        check(name, len(v) == want, "want %d, got %r" % (want, v))
    in_identity = {(site, WF, "attest"): "fixture"}
    v, _ = scan_workflow(load(attest), WF, {}, site, in_identity)
    check("a reviewed entry inside a pinned identity workflow fails",
          len(v) == 1 and "trust policy pins" in v[0], repr(v))
    check("the shipped reviewed entries name known identities' complement",
          all(k[1] not in {sp["workflow"] for sp in IDENTITIES.values()} for k in REVIEWED_OTHER_OIDC_JOBS))

    for root in (os.path.join(os.devnull, "missing"), os.devnull):
        with contextlib.redirect_stderr(io.StringIO()):
            rc = main(["--check", root, "--repository", REPO])
        check("--check %s is an environment error, not a pass" % root, rc == 2, "got %d" % rc)

    import tempfile
    with tempfile.TemporaryDirectory() as tmp:
        wf_dir = os.path.join(tmp, ".github", "workflows")
        p_dir = os.path.join(tmp, ".github", "chainguard")
        os.makedirs(wf_dir)
        with open(os.path.join(wf_dir, WF), "w") as fh:
            fh.write(_wf(GOOD_CHECKOUT + EXCHANGE))
        check("scan honours a listed job", scan_workflows(tmp, load, ALLOW) == [])
        v = scan_workflows(tmp, load, {})
        check("the same job unlisted fails", len(v) == 1 and "ALLOWED_ID_TOKEN_JOBS" in v[0], repr(v))
        with open(os.path.join(wf_dir, WF), "w") as fh:
            fh.write(_wf(GOOD_CHECKOUT, perms=""))
        v = scan_workflows(tmp, load, ALLOW)
        check("a stale allow-list entry fails", len(v) == 1 and "stale" in v[0], repr(v))
        os.remove(os.path.join(wf_dir, WF))
        v = scan_workflows(tmp, load, ALLOW)
        check("an entry for an absent workflow is stale", len(v) == 1 and "stale" in v[0], repr(v))
        with open(os.path.join(wf_dir, "bad.yml"), "w") as fh:
            fh.write("on: [workflow_run\n")
        v = scan_workflows(tmp, load, {})
        check("an unparseable workflow fails closed", len(v) == 1 and "cannot parse" in v[0], repr(v))
        os.remove(os.path.join(wf_dir, "bad.yml"))
        with open(os.path.join(wf_dir, ".hidden.yml"), "w") as fh:
            fh.write(_wf(GOOD_CHECKOUT))
        v = scan_workflows(tmp, load, {})
        check("a dot-prefixed workflow is scanned", len(v) == 1 and ".hidden.yml" in v[0], repr(v))
        os.rename(os.path.join(wf_dir, ".hidden.yml"), os.path.join(wf_dir, ".hidden.yaml"))
        v = scan_workflows(tmp, load, {})
        check("a dot-prefixed .yaml workflow is scanned", len(v) == 1, repr(v))
        os.remove(os.path.join(wf_dir, ".hidden.yaml"))
        with open(os.path.join(wf_dir, "build-artifact.yml"), "w") as fh:
            fh.write(attest)
        check("scan honours a reviewed non-app OIDC job", scan_workflows(tmp, load, {}, site, other) == [])
        with open(os.path.join(wf_dir, "build-artifact.yml"), "w") as fh:
            fh.write(attest.replace("      id-token: write\n", ""))
        v = scan_workflows(tmp, load, {}, site, other)
        check("a stale reviewed entry fails in its repository", len(v) == 1 and "stale" in v[0], repr(v))
        check("a reviewed entry for another repository is not stale here",
              scan_workflows(tmp, load, {}, REPO, other) == [])
        os.remove(os.path.join(wf_dir, "build-artifact.yml"))

        check("no policy directory passes", scan_policies(tmp, load, None, None) == [])
        os.makedirs(p_dir)
        check("an empty policy directory passes", scan_policies(tmp, load, None, None) == [])
        with open(os.path.join(p_dir, "review-mutations.sts.yaml"), "w") as fh:
            fh.write(dump_policy(_good(), "review-mutations"))
        check("a generated policy passes", scan_policies(tmp, load, REPO, PIN) == [])
        v = scan_policies(tmp, load, None, PIN)
        check("an undeterminable repository fails closed", len(v) == 1 and "cannot determine" in v[0], repr(v))
        v = scan_policies(tmp, load, "nathanjohnpayne/matchline", PIN)
        check("a policy copied from another repository fails", len(v) == 1, repr(v))
        v = scan_policies(tmp, load, REPO, None)
        check("a policy before the pilot's pin fails", len(v) == 1 and "APP_PIN" in v[0], repr(v))
        other = render_policy("policy-mutations", REPO, "111", "222", "42")
        with open(os.path.join(p_dir, "policy-mutations.sts.yaml"), "w") as fh:
            fh.write(dump_policy(other, "policy-mutations"))
        v = scan_policies(tmp, load, REPO, PIN)
        check("a second app fails", any("different apps" in x for x in v), repr(v))
        os.remove(os.path.join(p_dir, "policy-mutations.sts.yaml"))
        for stray in ("review-mutations.sts.yml", "unknown.sts.yaml", "README.md"):
            with open(os.path.join(p_dir, stray), "w") as fh:
                fh.write("x: 1\n")
            v = scan_policies(tmp, load, REPO, PIN)
            check("stray file %s fails" % stray, len(v) == 1 and "identity" in v[0], repr(v))
            os.remove(os.path.join(p_dir, stray))
        with open(os.path.join(p_dir, "auto-clear.sts.yaml"), "w") as fh:
            fh.write("issuer: [\n")
        v = scan_policies(tmp, load, REPO, PIN)
        check("an unparseable policy fails closed", len(v) == 1 and "cannot parse" in v[0], repr(v))
    for bad in ("bad", "a/b/c", "", "-x/y"):
        with contextlib.redirect_stderr(io.StringIO()):
            rc = main(["--check", os.devnull, "--repository", bad])
        check("--repository %r is a usage error" % bad, rc == 2, "got %d" % rc)
    for args in (["--check", "--repository"], ["--check", os.devnull, "--repository"], ["--check", "--bogus"]):
        with contextlib.redirect_stderr(io.StringIO()):
            rc = main(list(args))
        check("%s is a usage error" % " ".join(args), rc == 2, "got %d" % rc)
    print("%s: self-test %d/%d passed" % (NAME, total - failures, total))
    return failures == 0


# --- CLI -----------------------------------------------------------------------

def _opts(args, names, flags=()):
    opts, rest = {}, []
    while args:
        a = args.pop(0)
        if a in names and args:
            opts[a] = args.pop(0)
        elif a in flags:
            opts[a] = True
        else:
            rest.append(a)
    return opts, rest


def render_main(args):
    opts, rest = _opts(args, ("--repository", "--repository-id", "--owner-id", "--app"), ("--immutable",))
    if len(rest) != 1 or rest[0] not in IDENTITIES or not REPO_RE.match(opts.get("--repository", "")) \
            or not DIGITS_RE.match(opts.get("--repository-id", "")) \
            or not DIGITS_RE.match(opts.get("--owner-id", "")):
        print("usage: %s --render IDENTITY --repository OWNER/NAME --repository-id N --owner-id N "
              "[--app APP] [--immutable]\nidentities: %s" % (NAME, ", ".join(sorted(IDENTITIES))),
              file=sys.stderr)
        return 2
    app = opts.get("--app", APP_PIN)
    if app is None or not APP_RE.match(str(app)):
        print("%s: no app pin: pass --app, or record APP_PIN from the #2732 pilot first" % NAME,
              file=sys.stderr)
        return 2
    doc = render_policy(rest[0], opts["--repository"], opts["--repository-id"], opts["--owner-id"],
                        app, immutable=bool(opts.get("--immutable")))
    claims = doc["claim_pattern"]
    if (claims["repository_id"], claims["repository_owner_id"]) != (opts["--repository-id"], opts["--owner-id"]):
        print("%s: %s presents the IDs of %s (repository %s, owner %s), not the ones passed; "
              "for a fleet-read identity pass the hub's IDs, whatever repository stores the policy"
              % (NAME, rest[0], HUB if IDENTITIES[rest[0]]["repo"] == "hub" else opts["--repository"],
                 claims["repository_id"], claims["repository_owner_id"]), file=sys.stderr)
        return 2
    sys.stdout.write(dump_policy(doc, rest[0]))
    return 0


def main(argv):
    args = list(argv)
    if args and args[0] == "--render":
        return render_main(args[1:])
    mode = "all"
    if args and args[0] in ("--self-test", "--check"):
        mode = args.pop(0)[2:]
    opts, rest = _opts(args, ("--repository",))
    # An option left in `rest` lost its value (`--check --repository`); never
    # let it become the scan root.
    if len(rest) > 1 or (rest and mode != "check") or (opts and mode == "self-test") \
            or any(r.startswith("-") for r in rest) \
            or ("--repository" in opts and not REPO_RE.match(opts["--repository"])):
        print("usage: %s [--self-test | --check [ROOT] [--repository OWNER/NAME] | --render ...]" % NAME,
              file=sys.stderr)
        return 2
    load, err = make_loader()
    if load is None:
        print("%s: ERROR (%s). Install one rather than letting a credential gate skip." % (NAME, err),
              file=sys.stderr)
        return 2
    ok = True
    if mode in ("all", "self-test"):
        ok = self_test(load) and ok
    if mode in ("all", "check"):
        root = rest[0] if rest else (subprocess.run(["git", "rev-parse", "--show-toplevel"],
                                                    capture_output=True, text=True).stdout.strip()
                                     or os.getcwd())
        if not os.path.isdir(os.path.join(root, ".github", "workflows")):
            print("%s: ERROR (%s has no .github/workflows directory; refusing to report a clean "
                  "scan of nothing)" % (NAME, root), file=sys.stderr)
            return 2
        repository = opts.get("--repository") or detect_repository(root)
        violations = scan_workflows(root, load, ALLOWED_ID_TOKEN_JOBS, repository,
                                    REVIEWED_OTHER_OIDC_JOBS) \
            + scan_policies(root, load, repository, APP_PIN)
        for v in violations:
            print("%s: FAIL %s" % (NAME, v))
        if violations:
            ok = False
        else:
            print("%s: scan PASS (%s; %d allow-listed id-token job(s))"
                  % (NAME, root, len(ALLOWED_ID_TOKEN_JOBS)))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
