"""Read-only, head-pinned PR observations and advisory review-budget rows."""

import base64
import copy
import json
import math
import os
import re
import signal
import socket
import subprocess
import sys
import tempfile
import time
from datetime import datetime
from pathlib import Path

from .github import ClientError, GitHubClient, MAX_BODY, copy_json_tree
from .inventory import REPO
from .scheduler import Sample

SAFE_INTEGER = 2**53 - 1
SHA = re.compile(r"[0-9a-f]{40}\Z")
GATE_LABELS = ("needs-external-review", "needs-human-review", "human-hold", "policy-violation")
HELPER_FAILURES = (ClientError, OSError, ValueError, KeyError, TypeError, AttributeError, subprocess.SubprocessError)


def helper_failure(error):
    category = error.category if isinstance(error, ClientError) else "deadline_exceeded" if isinstance(error, subprocess.TimeoutExpired) else "source_failed"
    return {"data": None, "error": category}


BUDGETS = (
    ("blocking", "blk", "Codex blocking reviews", "codex-review-ledger.sh", False),
    ("requests", "req", "Codex requests (ceiling)", "codex-review-ledger.sh", False),
    ("rounds", "rnd", "Codex rounds before automated Phase 4b", "Cockpit advisory setting · ledger", True),
    ("reruns", "4b", "Phase 4b reruns after CHANGES_REQUESTED", "Cockpit advisory setting · phase-4b-loops", True),
    ("commits", "CR", "CodeRabbit commits · advisory threshold", "reviewed-commit anchor · Cockpit 5-commit display threshold", True),
)
CHECK_RUN_FIELDS = "id name status conclusion detailsUrl startedAt checkSuite { app { id slug } workflowRun { id workflow { id } } }"
FIELDS = """id number title url state isDraft headRefOid createdAt updatedAt mergedAt closedAt
 author { login } mergeStateStatus reviewDecision
 labels(first:100) { nodes { name } pageInfo { hasNextPage endCursor } }
 commits(last:1) { nodes { commit { oid pushedDate committedDate
  statusCheckRollup { contexts(first:100) { nodes {
   __typename ... on CheckRun { """ + CHECK_RUN_FIELDS + """ }
   ... on StatusContext { id context state targetUrl }
  } pageInfo { hasNextPage endCursor } } }
 } } }
"""
QUERY = "query CockpitPRs($owner:String!,$name:String!,$cursor:String) { repository(owner:$owner,name:$name) { pullRequests(first:50,states:OPEN,after:$cursor,orderBy:{field:UPDATED_AT,direction:DESC}) { nodes { " + FIELDS + " } pageInfo { hasNextPage endCursor } } } }"


def required_query(rows):
    aliases = []
    for i, raw in enumerate(rows):
        number = raw.get("number")
        if type(number) is not int or not 0 < number <= 2147483647:
            raise ClientError("invalid_upstream_json")
        fields = f'''headRefOid commits(last:1) {{ nodes {{ commit {{ oid statusCheckRollup {{
          contexts(first:100) {{ nodes {{ __typename
            ... on CheckRun {{ {CHECK_RUN_FIELDS} isRequired(pullRequestNumber:{number}) }}
            ... on StatusContext {{ id context state targetUrl isRequired(pullRequestNumber:{number}) }}
          }} pageInfo {{ hasNextPage endCursor }} }}
        }} }} }} }}'''
        aliases.append(f"p{i}:pullRequest(number:{number}) {{ {fields} }}")
    return "query CockpitPRRequired($owner:String!,$name:String!) { repository(owner:$owner,name:$name) { " + " ".join(aliases) + " } }"


def integer(value):
    return value if type(value) is int and 0 <= value <= SAFE_INTEGER else None


def exact(value):
    """Counts beyond JS precision are exact strings; identities always strings."""
    return str(value) if type(value) is int and abs(value) > SAFE_INTEGER else value


def epoch(value):
    if type(value) in (int, float):
        try:
            return value if math.isfinite(value) and value >= 0 else None
        except OverflowError:
            return None
    if type(value) is str:
        try:
            return datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp()
        except (ValueError, OverflowError):
            pass
    return None


def load_settings(path=None):
    try:
        value = json.loads(Path(path or Path(__file__).with_name("pr_settings.json")).read_text())
        if (value.get("schema") != "cockpit-pr-settings/v1" or value.get("advisory") is not True
                or any(integer(value.get(key)) is None for key in ("rounds_before_phase_4b", "phase_4b_reruns"))):
            raise ValueError()
        return value
    except (OSError, ValueError, AttributeError):
        # Unreadable settings never silently become a default denominator.
        return {"schema": "cockpit-pr-settings/v1", "advisory": True,
                "rounds_before_phase_4b": None, "phase_4b_reruns": None}


def budget(key, used, limit, observed_at=None, stale=False):
    _, abbr, name, source, advisory = next(item for item in BUDGETS if item[0] == key)
    used, limit = integer(used), integer(limit)
    left = max(0, limit - used) if used is not None and limit is not None else None
    state = "idle" if left is None else "boulder" if left == 0 else "bump" if limit >= 5 and left <= 2 else "clear"
    return dict(id=key, abbr=abbr, name=name, source=source, advisory=advisory,
                used=used, limit=limit, remaining=left, state=state,
                observed_at=epoch(observed_at), stale=stale,
                ratio=min(1, used / limit) if left is not None and limit > 0 else None,
                threshold=(limit - 2) / limit if limit and limit >= 5 else 1)


def _receipt(enrichment, source, head):
    receipt = enrichment.get(source) if isinstance(enrichment, dict) else None
    if not isinstance(receipt, dict) or receipt.get("head") != head:
        return {"data": None, "observed_at": None, "stale": False, "error": "unavailable"}
    return receipt


def _check(node):
    if not isinstance(node, dict) or node.get("isRequired") is not True:
        return None
    status = node.get("status", node.get("state"))
    conclusion = node.get("conclusion")
    tone = "running" if status in {"IN_PROGRESS", "PENDING", "EXPECTED", "QUEUED", "WAITING", "REQUESTED"} else "clear" if conclusion in {"SUCCESS", "NEUTRAL", "SKIPPED"} or status == "SUCCESS" else "boulder" if conclusion in {"FAILURE", "TIMED_OUT", "CANCELLED", "ACTION_REQUIRED", "STARTUP_FAILURE", "STALE"} or status in {"FAILURE", "ERROR"} else "idle"
    return {"id": str(node["id"]), "name": node.get("name", node.get("context", "Check")),
            "state": tone, "url": node.get("detailsUrl", node.get("targetUrl"))}


def _check_producer(node):
    # Display names alone never establish a producing app or Actions workflow.
    if node.get("__typename") != "CheckRun" or type(node.get("name")) is not str or not node["name"]:
        return None
    suite = node.get("checkSuite")
    app = suite.get("app") if type(suite) is dict else None
    if type(app) is not dict or type(app.get("id")) is not str or not app["id"] or type(app.get("slug")) is not str or not app["slug"]:
        return None
    run, workflow_id, run_id = suite.get("workflowRun"), None, None
    if app["slug"] == "github-actions" or run is not None:
        workflow = run.get("workflow") if type(run) is dict else None
        if type(workflow) is not dict or type(workflow.get("id")) is not str or not workflow["id"]:
            return None
        if type(run.get("id")) is not str or not run["id"]:
            return None
        workflow_id, run_id = workflow["id"], run["id"]
    return app["id"], workflow_id, run_id, node["name"]


def _current_required_contexts(contexts):
    required = [node for node in contexts if type(node) is dict and node.get("isRequired") is True]
    groups, selected = {}, set(range(len(required)))
    for index, node in enumerate(required):
        producer = _check_producer(node)
        if producer is not None:
            groups.setdefault(producer, []).append(index)
    for indices in groups.values():
        times = [epoch(required[index].get("startedAt")) if type(required[index].get("startedAt")) is str else None for index in indices]
        # Unknown or tied ordering cannot erase a failure or an unstarted rerun.
        if any(value is None for value in times):
            continue
        newest = max(times)
        if times.count(newest) != 1:
            continue
        winner = indices[times.index(newest)]
        selected.difference_update(index for index in indices if index != winner)
    return [node for index, node in enumerate(required) if index in selected]


def commits_since_review(reviews, comments, commits, head, *, trusted_reviewers=(), bot_login="coderabbitai[bot]"):
    """Count identities after the reviewed commit, never commit author/committer timestamps."""
    if (type(trusted_reviewers) not in (list, tuple) or any(type(login) is not str or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9-]*", login) for login in trusted_reviewers)
            or type(bot_login) is not str or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9-]*(?:\[bot\])?", bot_login)):
        raise ClientError("source_failed")
    resume_authors = {"nathanjohnpayne", *trusted_reviewers}
    command = "@" + bot_login.removesuffix("[bot]") + " resume"
    events = [(epoch(item.get("submitted_at")), item.get("commit_id")) for item in reviews
              if (item.get("user") or {}).get("login") == bot_login and item.get("body")]
    # A resume comment has no commit anchor; if it is newest, the exact count is unavailable.
    events += [(epoch(item.get("created_at")), None) for item in comments
               if (item.get("user") or {}).get("login") in resume_authors
               and (item.get("body") or "").partition("\n")[0] == command]
    if not events or any(date is None for date, _ in events):
        raise ClientError("source_failed")
    newest = max(date for date, _ in events)
    anchors = {anchor for date, anchor in events if date == newest}
    if None in anchors:
        return None  # Successfully observed resume; do not retain an obsolete numeric count.
    if len(anchors) != 1:
        raise ClientError("source_failed")
    anchor = anchors.pop()
    identities = [item.get("sha") for item in commits]
    if (any(type(value) is not str or not SHA.fullmatch(value) for value in identities)
            or len(set(identities)) != len(identities) or not identities or identities[-1] != head
            or anchor not in identities):
        raise ClientError("source_failed")
    return len(identities) - identities.index(anchor) - 1


def build_row(repo, raw, enrichment=None, settings=None, observed_at=None):
    """Reusable provider enrichment: missing evidence stays explicitly unknown."""
    if (not REPO.fullmatch(repo) or type(raw) is not dict or type(raw.get("number")) is not int
            or raw["number"] <= 0 or not SHA.fullmatch(raw.get("headRefOid", ""))):
        raise ClientError("invalid_upstream_json")
    head, number = raw["headRefOid"], str(raw["number"])
    settings = settings if settings is not None else load_settings()
    receipts = {key: _receipt(enrichment, key, head) for key in ("ledger", "feedback", "coderabbit", "accounting", "commits")}
    ledger = receipts["ledger"]["data"] or {}
    summary, limits = ledger.get("summary", {}), ledger.get("limits", {})
    budgets = [budget("blocking", summary.get("blocking_responses_solicited"), limits.get("max_blocking_reviews"), receipts["ledger"]["observed_at"], receipts["ledger"]["stale"]),
               budget("requests", summary.get("requests"), limits.get("max_review_rounds"), receipts["ledger"]["observed_at"], receipts["ledger"]["stale"]),
               budget("rounds", summary.get("requests"), settings.get("rounds_before_phase_4b"), receipts["ledger"]["observed_at"], receipts["ledger"]["stale"]),
               budget("reruns", (receipts["accounting"]["data"] or {}).get("reruns"), settings.get("phase_4b_reruns"), receipts["accounting"]["observed_at"], receipts["accounting"]["stale"]),
               budget("commits", (receipts["commits"]["data"] or {}).get("used"), 5, receipts["commits"]["observed_at"], receipts["commits"]["stale"])]
    commits = raw.get("commits", {}).get("nodes", [])
    commit = commits[-1].get("commit", {}) if commits else {}
    rollup = commit.get("statusCheckRollup")
    contexts = rollup.get("contexts", {}).get("nodes", []) if isinstance(rollup, dict) else []
    checks = [_check(node) for node in _current_required_contexts(contexts)]
    checks_known = isinstance(rollup, dict) and all(type(node) is dict and type(node.get("isRequired")) is bool for node in contexts)
    labels = [node["name"] for node in raw.get("labels", {}).get("nodes", []) if node.get("name") in GATE_LABELS]
    feedback = receipts["feedback"]["data"] or {}
    cr = receipts["coderabbit"]["data"] or {}
    human_stops = ledger.get("human_stops")
    human = any(label in labels for label in ("human-hold", "policy-violation", "needs-human-review")) or bool(human_stops)
    state, label = "idle", "Waiting"
    merge_state = raw.get("mergeStateStatus")
    spent = [item for item in budgets if item["state"] == "boulder"]
    near = [item for item in budgets if item["state"] == "bump"]
    if human:
        state, label = "boulder", "Human stop"
    elif merge_state == "UNSTABLE":
        state, label = "boulder", "Unstable"
    elif merge_state == "DIRTY":
        state, label = "boulder", "Conflicts"
    elif spent:
        state, label = "boulder", "Budget spent"
    elif near:
        state, label = "bump", "Budget near"
    elif cr.get("status") in {"paused", "rate_limit_stalled"} or cr.get("skip_reason") == "paused":
        state, label = "bump", "CodeRabbit paused" if cr.get("skip_reason") == "paused" or cr.get("status") == "paused" else "Rate-limited"
    elif merge_state == "BEHIND":
        state, label = "bump", "Behind main"
    elif integer(feedback.get("accounted")) is not None and integer(feedback.get("posted")) is not None and feedback["accounted"] < feedback["posted"]:
        state, label = "bump", "Unaccounted"
    elif raw.get("isDraft") is True:
        label = "Draft"
    elif merge_state == "CLEAN":
        state, label = "clear", "Clean · GitHub state"
    elif any(item["state"] == "running" for item in checks) or ledger.get("in_flight_on_head") is True:
        state, label = "running", "In progress"
    lifecycle = raw.get("state", "OPEN")
    if lifecycle == "MERGED":
        state, label = "done", "Merged"
    elif lifecycle == "CLOSED":
        state, label = "idle", "Closed"
    running = [item["name"] for item in checks if item["state"] == "running"]
    reason = (f"{running[0]} in progress" if merge_state == "BLOCKED" and running else
              "GitHub merge state only; policy clearance is not asserted" if merge_state == "CLEAN" else
              "Required checks or review gates may still be pending" if merge_state == "BLOCKED" else
              "Conflicts with the base branch" if merge_state == "DIRTY" else
              "Base branch has moved" if merge_state == "BEHIND" else "GitHub merge-state observation")
    details = "; ".join(item["name"] + f": {item['remaining']} left of {item['limit']}" + (" · advisory display" if item["advisory"] else "") for item in spent + near)
    detail = details if label in {"Budget spent", "Budget near"} else ", ".join(labels + (human_stops or [])) if human else reason
    stale = any(value["stale"] for value in receipts.values())
    row = {"id": repo + "#" + number, "repo": repo, "number": number, "title": raw.get("title", "PR title unavailable"),
           "url": f"https://github.com/{repo}/pull/{number}", "author": (raw.get("author") or {}).get("login"),
           "draft": raw.get("isDraft") is True, "head": head, "lifecycle": lifecycle,
           "created_at": epoch(raw.get("createdAt")), "last_push": epoch(commit.get("pushedDate")),
           "updated_at": epoch(raw.get("updatedAt")), "merged_at": epoch(raw.get("mergedAt")),
           "observed_at": epoch(observed_at), "stale": stale, "merge_state": merge_state,
           "review_decision": raw.get("reviewDecision"), "state": state, "label": label, "reason": reason,
           "checks": checks, "checks_known": checks_known, "labels": labels, "budgets": budgets,
           "feedback": {"accounted": integer(feedback.get("accounted")), "posted": integer(feedback.get("posted")), **{k: receipts["feedback"][k] for k in ("observed_at", "stale", "error")}},
           "codex": {"in_flight_on_head": ledger.get("in_flight_on_head"), "outstanding": integer(ledger.get("outstanding")),
                     "human_stops": human_stops, "url": ledger.get("url"), **{k: receipts["ledger"][k] for k in ("observed_at", "stale", "error")}},
           "coderabbit": {"status": cr.get("status", "unknown"), "head": cr.get("head_sha"), "skip_reason": cr.get("skip_reason"),
                          **{k: receipts["coderabbit"][k] for k in ("observed_at", "stale", "error")}},
           "spend": {"totals": (receipts["accounting"]["data"] or {}).get("totals"), "coverage": (receipts["accounting"]["data"] or {}).get("coverage", "unavailable"),
                     "codex_split": "unavailable", **{k: receipts["accounting"][k] for k in ("observed_at", "stale", "error")}}, "hazards": []}
    if state in {"bump", "boulder"}:
        row["hazards"].append({"id": "prs-" + row["id"], "source": "prs", "section": "prs", "repo": repo,
            "state": state, "title": repo + " #" + number + " · " + label, "detail": detail or label,
            "timing": {"kind": "unknown"} if label in {"Budget near", "Rate-limited", "CodeRabbit paused"} else {"kind": "now"},
            "observed_at": row["observed_at"], "stale": stale})
    return row


def partial_row(repo, number, *, head=None, title=None, merge_state=None, draft=False, observed_at=None):
    """An audit-reported sync PR can use the same view without the panel."""
    if type(number) is str and re.fullmatch(r"[1-9][0-9]*", number):
        number = int(number)
    row = build_row(repo, {"number": number, "headRefOid": head or "0" * 40, "title": title or "Sync PR · enrichment unavailable", "mergeStateStatus": merge_state, "isDraft": draft}, observed_at=observed_at)
    if head is None:
        row["head"] = None
    row["partial"] = True
    return row


# Child gh is a read-only RPC stub. It has neither credentials nor network logic.
_GH_SHIM = r'''import json,os,socket,sys
s=socket.socket(socket.AF_UNIX,socket.SOCK_STREAM)
s.settimeout(float(os.environ['COCKPIT_BRIDGE_TIMEOUT']))
s.connect(os.environ['COCKPIT_BRIDGE_SOCKET'])
s.sendall(json.dumps(sys.argv[1:]).encode()+b'\n')
f=s.makefile('rb'); d=json.loads(f.readline(8388609)); s.close()
sys.stdout.write(d.get('stdout',''));sys.exit(d.get('exit',1))
'''


class HelperReader:
    """Fixed trusted read helpers with one deadline and the shared transport."""
    def __init__(self, client, root, *, checkout_roots=None, monotonic=time.monotonic):
        self.client, self.root, self.monotonic = client, Path(root), monotonic
        self.checkout_roots = dict(checkout_roots or {})

    def _api(self, arguments, repo, deadline):
        if not arguments or arguments[0] != "api":
            raise ClientError("query_only")
        endpoint, jq_filter, raw, paginate, fields = None, None, False, False, {}
        args = iter(arguments[1:])
        for arg in args:
            if arg == "--paginate":
                paginate = True
            elif arg in {"--jq", "-q"}:
                jq_filter = next(args)
            elif arg in {"-H", "--header"}:
                raw = "application/vnd.github.raw" in next(args)
            elif arg in {"-X", "--method"}:
                if next(args).upper() != "GET":
                    raise ClientError("query_only")
            elif arg in {"-f", "-F", "--field", "--raw-field"}:
                name, value = next(args).split("=", 1)
                fields[name] = int(value) if arg in {"-F", "--field"} and value.isdecimal() else value
            elif arg.startswith("-") or endpoint is not None:
                raise ClientError("query_only")
            else:
                endpoint = arg.lstrip("/")
        if endpoint and endpoint.startswith("repos/" + repo + "/") and not fields:
            payload = self.client.pages("/" + endpoint, deadline=deadline) if paginate else self.client.get("/" + endpoint, deadline=deadline)
        else:
            raise ClientError("query_only")
        if raw:
            if not isinstance(payload, dict) or payload.get("encoding") != "base64":
                raise ClientError("invalid_upstream_json")
            output = base64.b64decode(payload["content"], validate=False).decode()
        else:
            output = json.dumps(payload, allow_nan=False)
        if jq_filter is not None:
            result = subprocess.run(["jq", "-r", jq_filter], input=output, text=True, capture_output=True,
                                    timeout=max(.01, deadline - self.monotonic()), check=True,
                                    env={"PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"})
            output = result.stdout
        return output

    def _run(self, command, repo, deadline, *, payload=None, allowed=(0,), policy=None, coderabbit=None):
        """Never invoke real gh; private socket and scratch dir die with the call."""
        deadline = min(deadline, self.monotonic() + 10)
        if deadline <= self.monotonic():
            raise ClientError("deadline_exceeded")
        with tempfile.TemporaryDirectory(prefix="cockpit-pr-helper-") as directory:
            directory = Path(directory)
            shim = directory / "gh"
            shim.write_text("#!" + sys.executable + "\n" + _GH_SHIM)
            shim.chmod(0o700)
            input_file = directory / "input.json"
            input_file.write_text(json.dumps(payload, allow_nan=False))
            listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            listener.bind(str(directory / "rpc")); listener.listen(1); listener.settimeout(.05)
            env = {"PATH": str(directory) + ":/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin", "HOME": str(directory),
                   "TMPDIR": str(directory), "GH_TOKEN": "cockpit-read-bridge", "GH_PAGER": "cat", "GH_PROMPT_DISABLED": "1",
                   "COCKPIT_BRIDGE_SOCKET": str(directory / "rpc"), "COCKPIT_BRIDGE_TIMEOUT": str(max(.1, deadline - self.monotonic()))}
            cwd = self.root
            if policy is not None:
                if type(policy) is not str or not policy.strip() or len(policy.encode()) > MAX_BODY:
                    raise ClientError("source_failed")
                cwd = directory / "context"; (cwd / ".github").mkdir(parents=True)
                config = cwd / ".github" / "review-policy.yml"; config.write_text(policy)
                env["MERGEPATH_REVIEW_POLICY_PATH"] = str(config)
                if coderabbit is not None:
                    if type(coderabbit) is not str or len(coderabbit.encode()) > MAX_BODY:
                        raise ClientError("source_failed")
                    (cwd / ".coderabbit.yml").write_text(coderabbit)
            with (directory / "out").open("w+b") as out, (directory / "err").open("w+b") as err:
                process = subprocess.Popen(command + ([str(input_file)] if payload is not None else []), cwd=cwd, env=env, stdout=out, stderr=err, start_new_session=True)
                try:
                    while process.poll() is None:
                        if self.monotonic() >= deadline or out.tell() > MAX_BODY or err.tell() > MAX_BODY:
                            raise ClientError("deadline_exceeded")
                        try:
                            connection, _ = listener.accept()
                        except socket.timeout:
                            continue
                        with connection:
                            connection.settimeout(max(.01, deadline - self.monotonic()))
                            request = connection.makefile("rb").readline(MAX_BODY + 1)
                            try:
                                args = json.loads(request)
                                if type(args) is not list or any(type(item) is not str for item in args):
                                    raise ValueError()
                                response = {"stdout": self._api(args, repo, deadline), "exit": 0}
                            except Exception:
                                response = {"stdout": "", "exit": 1}
                            connection.sendall(json.dumps(response).encode() + b"\n")
                    out.seek(0)
                    output = out.read(MAX_BODY + 1)
                    if process.returncode not in allowed or len(output) > MAX_BODY:
                        raise ClientError("source_failed")
                    return json.loads(output)
                except (OSError, ValueError, subprocess.SubprocessError):
                    raise ClientError("source_failed") from None
                finally:
                    if process.poll() is None:
                        os.killpg(process.pid, signal.SIGKILL)
                    try:
                        process.wait(timeout=1)
                    finally:
                        listener.close()

    def read(self, repo, number, head, deadline):
        script = str(self.root / "scripts")
        # Constants only; data travels through argv/files, never shell interpolation.
        command = r'''set -euo pipefail
s=$1; repo=$2; pr=$3; head=$4
. "$s/lib/feedback-policy-helpers.sh"
. "$s/lib/codex-request-evidence.sh"
. "$s/lib/codex-review-ledger.sh"
metadata=$(gh api "repos/$repo/pulls/$pr")
[ "$(printf '%s' "$metadata" | jq -r '.head.sha')" = "$head" ]
tuple=$(printf '%s' "$metadata" | jq -ce '{head:.head.sha,base:.base.sha,ref:.base.ref,repository:.base.repo.id}')
base=$(printf '%s' "$metadata" | jq -er '.base.sha')
ref=$(printf '%s' "$metadata" | jq -er '.base.ref')
default=$(printf '%s' "$metadata" | jq -er '.base.repo.default_branch')
p=$("$s/workflow/resolve_base_policy.sh" --repo "$repo" --base-ref "$ref" --base-sha "$base" --default-branch "$default" --materialize-default)
trap 'rm -f "$p"' EXIT
policy=$(policy_yaml_to_json "$p"); fp=$(crqe_policy_fingerprint "$policy")
ledger=$("$s/codex-review-ledger.sh" --repo "$repo" --expect-head "$head" --expect-policy "$fp" "$pr")
max=$(printf '%s' "$ledger" | jq -r '.max_blocking_reviews')
ceiling=$(printf '%s' "$policy" | jq -er '.codex.max_review_rounds // 20')
author=$(printf '%s' "$ledger" | jq -r '.author')
stops=$(crl_human_stops "$ledger" "$head" "$author" "$max" "$ceiling")
metadata=$(gh api "repos/$repo/pulls/$pr")
[ "$(printf '%s' "$metadata" | jq -ce '{head:.head.sha,base:.base.sha,ref:.base.ref,repository:.base.repo.id}')" = "$tuple" ]
printf '%s' "$ledger" | jq --argjson policy "$policy" --arg policy_yaml "$(cat "$p")" --arg base "$base" --argjson tuple "$tuple" --argjson stops "$stops" --argjson ceiling "$ceiling" '{policy_yaml:$policy_yaml,commit_context:{reviewers:($policy.available_reviewers // []),bot_login:($policy.coderabbit.bot_login // "coderabbitai[bot]")},base_sha:$base,tuple:$tuple,summary:.summary, limits:{max_blocking_reviews:.max_blocking_reviews,max_review_rounds:$ceiling},human_stops:$stops.stops,outstanding:.summary.outcomes.no_response_yet,in_flight_on_head:(if .current_summary.status == "running" and (.current_summary.commit as $commit | .head_sha | startswith($commit // "impossible")) then true else null end),url:(if .current_summary.comment_id then "https://github.com/" + .repo + "/pull/" + (.pr|tostring) + "#issuecomment-" + (.current_summary.comment_id|tostring) elif (.requests|length)>0 then "https://github.com/" + .repo + "/pull/" + (.pr|tostring) + "#issuecomment-" + (.requests[-1].id|tostring) else null end)}'
'''
        result = {}
        target_policy = None
        commit_context = None
        calls = {"ledger": (["bash", "-c", command, "cockpit-pr-ledger", script, repo, number, head], (0,)),
                 "feedback": ([str(self.root / "scripts/review-feedback-accounting.sh"), number, repo], (0, 1)),
                 "coderabbit": ([str(self.root / "scripts/coderabbit-wait.sh"), "--probe", number, repo], (0, 2, 4, 5, 6, 7))}
        for source, (args, allowed) in calls.items():
            try:
                if source == "coderabbit":
                    if target_policy is None:
                        raise ClientError("source_failed")
                    self._same_tuple(repo, number, result["ledger"]["data"].get("tuple"), deadline)
                    base = result["ledger"]["data"].get("base_sha")
                    if type(base) is not str or not SHA.fullmatch(base):
                        raise ClientError("source_failed")
                    cr_config = self._api(["api", f"repos/{repo}/contents/.coderabbit.yml?ref={base}", "-H", "Accept: application/vnd.github.raw"], repo, deadline)
                    data = self._run(args, repo, deadline, allowed=allowed, policy=target_policy, coderabbit=cr_config)
                else:
                    data = self._run(args, repo, deadline, allowed=allowed)
                if type(data) is not dict:
                    raise ClientError("source_failed")
                if source == "ledger":
                    target_policy = data.pop("policy_yaml", None)
                    commit_context = data.pop("commit_context", None)
                if source == "coderabbit" and data.get("head_sha") != head:
                    raise ClientError("source_failed")
                result[source] = {"data": data, "error": None}
            except HELPER_FAILURES as error:
                result[source] = helper_failure(error)
        # Count CR commits only from a proven anchor. Never assume zero.
        try:
            reviews = self.client.pages(f"/repos/{repo}/pulls/{number}/reviews?per_page=100", deadline=deadline)
            comments = self.client.pages(f"/repos/{repo}/issues/{number}/comments?per_page=100", deadline=deadline)
            commits = self.client.pages(f"/repos/{repo}/pulls/{number}/commits?per_page=100", deadline=deadline)
            if type(commit_context) is not dict:
                raise ClientError("source_failed")
            result["commits"] = {"data": {"used": commits_since_review(reviews, comments, commits, head,
                trusted_reviewers=commit_context.get("reviewers"), bot_login=commit_context.get("bot_login"))}, "error": None}
        except HELPER_FAILURES as error:
            result.setdefault("commits", helper_failure(error))
        try:
            if "reviews" not in locals():
                raise ClientError("source_failed")
            result["accounting"] = {"data": self._accounting(repo, number, reviews, deadline, policy=target_policy), "error": None}
        except HELPER_FAILURES as error:
            result["accounting"] = helper_failure(error)
        try:
            if target_policy is None:
                raise ClientError("source_failed")
            self._same_tuple(repo, number, result["ledger"]["data"].get("tuple"), deadline)
        except HELPER_FAILURES as error:
            return {source: helper_failure(error) for source in result}
        return result

    def _same_tuple(self, repo, number, expected, deadline):
        if type(expected) is not dict:
            raise ClientError("source_failed")
        metadata = self.client.get(f"/repos/{repo}/pulls/{number}", deadline=deadline)
        if type(metadata) is not dict or type(metadata.get("base")) is not dict or type(metadata.get("head")) is not dict:
            raise ClientError("source_failed")
        base = metadata["base"]
        if type(base.get("repo")) is not dict:
            raise ClientError("source_failed")
        observed = {"head": metadata["head"].get("sha"), "base": base.get("sha"),
                    "ref": base.get("ref"), "repository": base["repo"].get("id")}
        if observed != expected:
            raise ClientError("source_failed")

    def _accounting(self, repo, number, reviews, deadline, *, policy=None):
        # One explicit canonical local checkout per repository. Later #1590 owns fleet discovery/dedup.
        checkout = self.checkout_roots.get(repo)
        if policy is None:
            raise ClientError("source_failed")
        extraction = r'''set -euo pipefail
. "$1/phase-4b/accounting.sh"
trusted=$(p4b_acct_available_reviewers_json)
[ "$trusted" != '[]' ]
jq -r --argjson trusted "$trusted" '.[] | (.user.login // "") as $login | select(($trusted | index($login)) != null) | .body // empty' "$2" | p4b_acct_extract_records | jq -s .
'''
        extracted = self._run(["bash", "-c", extraction, "cockpit-pr-records", str(self.root / "scripts")],
                              repo, deadline, payload=reviews, policy=policy)
        if type(extracted) is not list or any(type(record) is not dict for record in extracted):
            raise ClientError("source_failed")
        records = []
        for record in extracted:
            if str(record.get("pr")) == number and record.get("automation_state") == "posted":
                records.append(record)
        loops = []
        # Latest posted record is cumulative within its segment; use complete archived record segments.
        for record in records:
            if type(record.get("loops")) is not list:
                raise ClientError("source_failed")
            loops.extend(record["loops"])
        if checkout is not None:
            slug = repo.replace("/", "-")
            path = Path(checkout) / ".mergepath" / "phase-4b-loops" / f"{slug}-pr{number}.jsonl"
            if path.exists():
                if path.stat().st_size > MAX_BODY:
                    raise ClientError("response_too_large")
                for line in path.read_text().splitlines():
                    loops.append(json.loads(line)["loop"])
        if not loops:
            raise ClientError("source_failed")
        seen, unidentified, distinct = {}, set(), []
        for loop in loops:
            if type(loop) is not dict or loop.get("tokens") is not None and type(loop["tokens"]) is not dict:
                raise ClientError("source_failed")
            identity = loop.get("run_id")
            if type(identity) is str and identity and not identity.startswith("pid-"):
                if identity in seen:
                    if seen[identity] != loop:
                        raise ClientError("source_failed")
                    continue
                seen[identity] = loop
            else:
                # Posted/live overlap has no reliable identity in older producer records.
                # Equal unidentified observations cannot prove one invocation or two.
                fingerprint = json.dumps(loop, sort_keys=True, separators=(",", ":"))
                if fingerprint in unidentified:
                    raise ClientError("source_failed")
                unidentified.add(fingerprint)
            distinct.append(loop)
        command = r'''set -euo pipefail
. "$1/phase-4b/accounting.sh"
loops=$(cat "$2")
notional=$(p4b_acct_notional_for_loops "$loops" || true)
ptv=$(p4b_acct_price_table_version || true)
p4b_acct_compute_totals "$loops" "$ptv" "$notional"
'''
        totals = self._run(["bash", "-c", command, "cockpit-pr-totals", str(self.root / "scripts")], repo, deadline, payload=distinct, policy=policy)
        # Preserve the helper's measured-only sum semantics without jq double rounding at the browser boundary.
        token_values = [(loop.get("tokens") or {}).get("total") for loop in distinct]
        if any(value is not None and (type(value) is not int or value < 0) for value in token_values):
            raise ClientError("source_failed")
        measured = [value for value in token_values if value is not None]
        totals["tokens_total"] = sum(measured) if measured else None
        totals = {key: exact(value) for key, value in totals.items() if key in {"tokens_total", "notional_usd", "reported_cost_usd", "adapter_invocations"}}
        # Each invocation after a CHANGES_REQUESTED is a rerun; the initial pass is never one.
        prior_changes, reruns = False, 0
        for loop in distinct:
            if prior_changes:
                reruns += 1
            prior_changes = loop.get("verdict") == "CHANGES_REQUESTED"
        return {"totals": totals, "reruns": reruns,
                "coverage": f"{len(measured)} of {len(distinct)} observed loops expose tokens; totals cover measured observations"}


class PRProvider:
    """Scheduler callback; browser filters reuse this one full cached observation."""
    def __init__(self, client, inventory, root, *, helper=None, checkout_roots=None,
                 clock=time.time, monotonic=time.monotonic, slow_interval=120,
                 max_enrichments=1, max_pages=20, settings_path=None):
        self.client, self.inventory, self.root = client, tuple(inventory), Path(root)
        self.clock, self.monotonic, self.slow_interval = clock, monotonic, slow_interval
        self.max_enrichments, self.max_pages = max_enrichments, max_pages
        self.settings_path = settings_path
        self.helper = helper or HelperReader(client, root, checkout_roots=checkout_roots, monotonic=monotonic)
        self.previous, self.enrichment, self.queue = {}, {}, []
        self.repository_offset = 0

    def _connection(self, connection):
        if type(connection) is not dict or type(connection.get("nodes")) is not list:
            raise ClientError("incomplete_graphql_connection")
        return self.client.next_cursor(connection)

    def _repository_data(self, data):
        repository = data.get("repository") if type(data) is dict else None
        if type(repository) is not dict:
            raise ClientError("incomplete_graphql")
        return repository

    def _repository(self, repo, deadline):
        owner, name = repo.split("/")
        cursor, seen, rows = None, set(), []
        for _ in range(self.max_pages):
            data = self.client.query(QUERY, {"owner": owner, "name": name, "cursor": cursor}, deadline=deadline)
            connection = self._repository_data(data).get("pullRequests")
            cursor = self._connection(connection)
            rows.extend(connection["nodes"])
            if cursor is None:
                break
            if cursor in seen:
                raise ClientError("pagination_cycle")
            seen.add(cursor)
        else:
            raise ClientError("page_limit")
        numbers = set()
        for raw in rows:
            if type(raw) is not dict or raw.get("number") in numbers:
                raise ClientError("invalid_upstream_json")
            numbers.add(raw.get("number"))
        # Query only known disappeared identities. Never infer merge from absence.
        missing = [row for row in self.previous.get(repo, {}).get("rows", []) if int(row["number"]) not in numbers and row["lifecycle"] == "OPEN"]
        if missing:
            aliases = " ".join(f'p{i}:pullRequest(number:{row["number"]}) {{ {FIELDS} }}' for i, row in enumerate(missing))
            data = self.client.query("query CockpitPRTransitions($owner:String!,$name:String!) { repository(owner:$owner,name:$name) { " + aliases + " } }", {"owner": owner, "name": name}, deadline=deadline)
            data = self._repository_data(data)
            for i in range(len(missing)):
                raw = data.get(f"p{i}")
                if not isinstance(raw, dict) or raw.get("state") not in {"MERGED", "CLOSED"}:
                    raise ClientError("incomplete_graphql")
                rows.append(raw)
        self._required(repo, rows, deadline)
        for raw in rows:
            self._nested(repo, raw, deadline)
        return rows

    def _required(self, repo, rows, deadline):
        # isRequired needs an explicit PR context, which a connection node cannot supply dynamically.
        # Known numbers let one alias batch cover each page rather than one request per PR.
        owner, name = repo.split("/")
        for start in range(0, len(rows), 50):
            chunk = rows[start:start + 50]
            query = required_query(chunk)
            data = self._repository_data(self.client.query(query, {"owner": owner, "name": name}, deadline=deadline))
            for i, raw in enumerate(chunk):
                value = data.get(f"p{i}")
                if not isinstance(value, dict) or value.get("headRefOid") != raw.get("headRefOid"):
                    raise ClientError("incomplete_graphql")
                commits = value.get("commits", {}).get("nodes", [])
                original = raw.get("commits", {}).get("nodes", [])
                if bool(commits) != bool(original):
                    raise ClientError("incomplete_graphql")
                if commits:
                    commit = commits[-1].get("commit", {})
                    if commit.get("oid") != raw["headRefOid"]:
                        raise ClientError("incomplete_graphql")
                    original[-1]["commit"]["statusCheckRollup"] = copy.deepcopy(commit.get("statusCheckRollup"))

    def _nested(self, repo, raw, deadline):
        # Batched initial data, cursor continuations only when GitHub reports more.
        labels = raw.get("labels")
        self._extend(labels, lambda cursor: ('labels(first:100,after:$cursor) { nodes { name } pageInfo { hasNextPage endCursor } }', "labels"), repo, raw, deadline)
        commits = raw.get("commits", {}).get("nodes", [])
        commit = commits[-1].get("commit", {}) if commits else {}
        rollup = commit.get("statusCheckRollup")
        if isinstance(rollup, dict):
            self._extend(rollup.get("contexts"), lambda cursor: ('commits(last:1) { nodes { commit { oid statusCheckRollup { contexts(first:100,after:$cursor) { nodes { __typename ... on CheckRun { ' + CHECK_RUN_FIELDS + ' isRequired(pullRequestNumber:$number) } ... on StatusContext { id context state targetUrl isRequired(pullRequestNumber:$number) } } pageInfo { hasNextPage endCursor } } } } } }', "checks"), repo, raw, deadline)

    def _extend(self, connection, field, repo, raw, deadline):
        cursor, seen = self._connection(connection), set()
        owner, name = repo.split("/")
        for _ in range(self.max_pages):
            if cursor is None:
                return
            if cursor in seen:
                raise ClientError("pagination_cycle")
            seen.add(cursor)
            selection, kind = field(cursor)
            query = 'query CockpitPRPage($owner:String!,$name:String!,$number:Int!,$cursor:String!) { repository(owner:$owner,name:$name) { pullRequest(number:$number) { headRefOid ' + selection + ' } } }'
            data = self.client.query(query, {"owner": owner, "name": name, "number": raw["number"], "cursor": cursor}, deadline=deadline)
            value = self._repository_data(data).get("pullRequest")
            if type(value) is not dict or value.get("headRefOid") != raw["headRefOid"]:
                raise ClientError("incomplete_graphql")
            if kind == "labels":
                page = value["labels"]
            else:
                page = value["commits"]["nodes"][-1]["commit"]["statusCheckRollup"]["contexts"]
            cursor = self._connection(page)
            connection["nodes"].extend(page["nodes"])
            connection["pageInfo"] = copy.deepcopy(page["pageInfo"])
        raise ClientError("page_limit")

    def __call__(self, deadline):
        # Leave time to publish retained coverage even when an upstream exhausts its request budget.
        request_deadline = deadline - .25
        settings, observations, now = load_settings(self.settings_path), [], self.clock()
        raw_by_id = {}
        ordered = self.inventory[self.repository_offset:] + self.inventory[:self.repository_offset]
        if self.inventory:
            self.repository_offset = (self.repository_offset + 1) % len(self.inventory)
        for repository in ordered:
            repo = repository.repo
            try:
                if self.monotonic() >= request_deadline:
                    raise ClientError("deadline_exceeded")
                raw_rows = self._repository(repo, request_deadline)
                entry = {"repo": repo, "rows": [], "observed_at": now, "stale": False, "error": None}
                for raw in raw_rows:
                    key = repo + "#" + str(raw["number"])
                    raw_by_id[key] = (repo, raw)
                    cache = self.enrichment.get(key)
                    if cache and cache["head"] != raw["headRefOid"]:
                        self.enrichment.pop(key); cache = None
                    due = not cache or cache["due"] <= self.monotonic() or cache["updated_at"] != raw.get("updatedAt")
                    if due and key not in self.queue and raw.get("state", "OPEN") == "OPEN":
                        self.queue.append(key)
                    entry["rows"].append(build_row(repo, raw, cache["receipts"] if cache else None, settings, now))
                observations.append(entry)
            except (ClientError, KeyError, TypeError, ValueError) as error:
                entry = copy.deepcopy(self.previous.get(repo, {"repo": repo, "rows": [], "observed_at": None}))
                entry.update(stale=True, error=error.category if isinstance(error, ClientError) else "invalid_upstream_json")
                for row in entry["rows"]:
                    row["stale"] = True
                    for hazard in row["hazards"]:
                        hazard["stale"] = True
                observations.append(entry)
        for _ in range(min(self.max_enrichments, len(self.queue))):
            if request_deadline - self.monotonic() < .1:
                break
            key = self.queue.pop(0)
            if key not in raw_by_id:
                continue
            repo, raw = raw_by_id[key]
            old = self.enrichment.get(key, {}).get("receipts", {})
            failure = {"data": None, "error": "unavailable"}
            try:
                results = self.helper.read(repo, str(raw["number"]), raw["headRefOid"], request_deadline)
                if type(results) is not dict:
                    raise ClientError("source_failed")
            except HELPER_FAILURES as error:
                results, failure = {}, helper_failure(error)
            receipts = {}
            for source in ("ledger", "feedback", "coderabbit", "accounting", "commits"):
                value = results.get(source, failure)
                if type(value) is not dict or value.get("data") is not None and type(value["data"]) is not dict:
                    value = {"data": None, "error": "source_failed"}
                if value.get("data") is None and source in old:
                    receipt = copy.deepcopy(old[source]); receipt.update(stale=True, error=value.get("error", "source_failed"))
                else:
                    receipt = {"head": raw["headRefOid"], "data": value.get("data"), "error": value.get("error"), "stale": False, "observed_at": self.clock() if value.get("data") is not None else None}
                receipts[source] = receipt
            self.enrichment[key] = {"head": raw["headRefOid"], "updated_at": raw.get("updatedAt"), "due": self.monotonic() + self.slow_interval, "receipts": receipts}
            for entry in observations:
                if entry["repo"] == repo and not entry["stale"]:
                    entry["rows"] = [build_row(repo, raw, receipts, settings, entry["observed_at"]) if row["id"] == key else row for row in entry["rows"]]
        observations.sort(key=lambda entry: next(i for i, repo in enumerate(self.inventory) if repo.repo == entry["repo"]))
        self.previous = copy.deepcopy({entry["repo"]: entry for entry in observations})
        live = {row["id"] for entry in observations for row in entry["rows"] if row["lifecycle"] == "OPEN"}
        self.queue = [key for key in self.queue if key in live]
        self.enrichment = {key: value for key, value in self.enrichment.items() if key in live}
        return Sample(copy_json_tree({"schema": "cockpit-prs/v1", "repositories": observations, "settings": settings}), hot=bool(live))
