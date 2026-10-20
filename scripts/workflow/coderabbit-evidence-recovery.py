#!/usr/bin/env python3
"""Exact-evidence CodeRabbit recovery selector and Actions escalation (#906).

Default mode is read-only. --escalate is the separately permissioned writer.

The record is an attributed owner decision, not independent proof of a human.
The shared-author-token residual is owned by #928/#2129.
"""
import datetime as dt
import hashlib
import json
import re
import subprocess
import sys
import time

CONTEXT = "CodeRabbit unresolved blocking findings"
PREFIX = "<!-- mergepath-coderabbit-evidence:v1 "
GH_API_TIMEOUT_SECONDS = 30


def digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(",", ":")).encode()).hexdigest()


def api(path, *args):
    result = subprocess.run(["gh", "api", *args, path], check=True, capture_output=True, text=True,
                            timeout=GH_API_TIMEOUT_SECONDS)
    return json.loads(result.stdout)


def pages(path, field=None):
    data = api(path, "--paginate", "--slurp")
    if not isinstance(data, list):
        raise ValueError("unreadable paginated evidence")
    out = []
    for page in data:
        rows = page[field] if field else page
        if not isinstance(rows, list) or not all(isinstance(row, dict) for row in rows):
            raise ValueError("malformed evidence page")
        out.extend(rows)
    return out


def observation(run):
    """Read only the publisher-owned header position, never quoted gate text."""
    lines = (run.get("output", {}).get("summary") or "").splitlines()
    if len(lines) < 2 or not lines[0].startswith("<!-- mergepath-generation:v1 "):
        return None
    line = lines[1]
    if not line.startswith(PREFIX) or not line.endswith(" -->"):
        return None
    value = json.loads(line[len(PREFIX):-4])
    if not isinstance(value, dict):
        raise ValueError("damaged evidence header")
    return value


def select(request, runs, comments, transitions, now):
    repo, pr, head = request["repo"], request["pr"], request["head"]
    kind = request["kind"]
    author = request.get("author_identity", "nathanjohnpayne")
    if not isinstance(author, str) or not author:
        raise ValueError("invalid recovery author identity")
    base = request.get("base_sha")
    if "base_sha" in request and (not isinstance(base, str) or not re.fullmatch(r"[0-9a-f]{40}", base)):
        raise ValueError("invalid recovery policy base")
    if kind not in ("unreadable", "unrecognized"):
        raise ValueError("not a recoverable evidence state")
    if not re.fullmatch(r"[\w.-]+/[\w.-]+", repo) or type(pr) is not int or pr <= 0:
        raise ValueError("invalid PR binding")
    if not re.fullmatch(r"[0-9a-f]{40}", head) or not re.fullmatch(r"[0-9a-f]{40}", request["revision"]):
        raise ValueError("invalid source binding")
    if type(request["max_wait_seconds"]) is not int or request["max_wait_seconds"] < 0:
        raise ValueError("unreadable CodeRabbit timing")
    fingerprint = digest({"repo": repo, "pr": pr, "head": head, "kind": kind,
                          "revision": request["revision"], "evidence": request["evidence"],
                          "head_transitions": transitions, "author_identity": author, "base_sha": base})
    candidates = [r for r in runs if r.get("name") == CONTEXT and r.get("head_sha") == head
                  and r.get("app", {}).get("id") == 15368 and not r.get("external_id")]
    if not candidates or any(type(r.get("id")) is not int or r["id"] <= 0 for r in candidates):
        raise ValueError("missing owned generation")
    candidates.sort(key=lambda r: r["id"])
    # Incomplete openings and metadata-free infrastructure results carry no
    # provider verdict. Only an explicitly readable, bound result ends an
    # episode; a legacy fingerprint-drift failure must not reset its clock.
    prior = None
    for run in reversed(candidates):
        record = observation(run)
        if not record:
            continue
        if record.get("state") == "readable":
            if all(record.get(k) == request[k] for k in ("repo", "pr", "head", "revision")):
                break
            continue
        prior = record
        break
    same = prior and all(prior.get(k) == v for k, v in
                         {"repo": repo, "pr": pr, "head": head, "fingerprint": fingerprint}.items())
    episode = prior["episode"] if same else candidates[-1]["id"]
    first = prior["first_observed"] if same else now
    count = prior["observations"] + 1 if same else 1
    if type(first) is not int or first > now or type(count) is not int or count < 1:
        raise ValueError("invalid episode history")
    retry = request.get("retry_after", 0)
    if type(retry) is not int or retry < 0:
        raise ValueError("unreadable retry-after timing")
    deadline = first + request["max_wait_seconds"]
    if retry > 0:
        deadline = max(deadline, now + retry)
    if same:
        deadline = max(deadline, prior.get("retry_until", 0))
    persistent = count >= 2 if kind == "unrecognized" else now >= deadline
    record = {"repo": repo, "pr": pr, "head": head, "revision": request["revision"], "fingerprint": fingerprint,
              "episode": episode, "first_observed": first, "observations": count,
              "kind": kind, "retry_until": deadline,
              "state": "escalate" if persistent else "pending",
              "retry_after": max(0, deadline - now)}
    token = f"[mergepath-coderabbit-recovery: {repo} {pr} {head} {episode} {fingerprint}]"
    record["recovery_token"] = token
    if not persistent:
        return record
    accepted = []
    for comment in comments:
        body = comment.get("body")
        if not isinstance(body, str) or body.splitlines()[:1] != [token]:
            continue
        if comment.get("user", {}).get("login") != author:
            continue
        # Reposting an older episode, or editing an old comment into a release,
        # is not a fresh decision. Both timestamps must follow the hold.
        created = int(dt.datetime.fromisoformat(comment["created_at"].replace("Z", "+00:00")).timestamp())
        updated = int(dt.datetime.fromisoformat(comment["updated_at"].replace("Z", "+00:00")).timestamp())
        if created < first or updated < created:
            continue
        rationale = body.splitlines()[1:]
        decision = [line.removeprefix("Decision: ") for line in rationale if line.startswith("Decision: ")]
        reason = [line.removeprefix("Reason: ").strip() for line in rationale if line.startswith("Reason: ")]
        if len(decision) != 1 or not re.fullmatch(r"https://github\.com/" + re.escape(repo) +
                r"/issues/" + str(pr) + r"#issuecomment-[1-9][0-9]*", decision[0]):
            continue
        if len(reason) != 1 or not reason[0] or len(reason[0]) > 4000:
            continue
        expected = f"https://github.com/{repo}/issues/{pr}#issuecomment-{comment['id']}"
        if decision[0] != expected:
            continue
        accepted.append((comment["id"], expected, reason[0]))
    if len(accepted) == 1:
        record.update(state="recovery", decision=accepted[0][1], reason=accepted[0][2])
    return record


def write(path, body, method="POST"):
    result = subprocess.run(["gh", "api", "--method", method, path, "--input", "-"],
                            input=json.dumps(body), check=True, capture_output=True, text=True,
                            timeout=GH_API_TIMEOUT_SECONDS)
    return json.loads(result.stdout)


def escalate_one(repo, number, tip):
    pr = api(f"repos/{repo}/pulls/{number}")
    if type(pr["number"]) is not int or pr["number"] != number:
        raise ValueError("escalation target changed")
    head = pr["head"]["sha"]
    runs = pages(f"repos/{repo}/commits/{head}/check-runs?filter=all&per_page=100", "check_runs")
    runs = [r for r in runs if r.get("name") == CONTEXT and r.get("app", {}).get("id") == 15368
            and not r.get("external_id")]
    if not runs:
        return
    newest = max(runs, key=lambda r: r["id"])
    report = observation(newest)
    if not report or report.get("state") != "escalate":
        return
    if (not isinstance(report.get("repo"), str)
            or not re.fullmatch(r"[\w.-]+/[\w.-]+", report["repo"])
            or type(report.get("pr")) is not int or report["pr"] <= 0
            or any(not isinstance(report.get(key), str)
                   or not re.fullmatch(r"[0-9a-f]{40}", report[key])
                   for key in ("head", "revision"))):
        raise ValueError("malformed escalation tuple")
    if (report["repo"], report["pr"], report["head"], report["revision"]) != (repo, number, head, tip):
        print(f"escalation tuple changed for PR #{number}; skipping", file=sys.stderr)
        return
    marker = f"<!-- mergepath-coderabbit-escalation:v1 {report['episode']} {report['fingerprint']} -->"
    comments = pages(f"repos/{repo}/issues/{number}/comments?per_page=100")
    if any(c.get("user", {}).get("login") == "github-actions[bot]" and
           (c.get("body") or "").startswith(marker + "\n") for c in comments):
        return
    drift = ""
    if report["kind"] == "unrecognized":
        drift_marker = "<!-- mergepath-coderabbit-parser-drift:v1 -->"
        issues = pages(f"repos/{repo}/issues?state=open&per_page=100")
        matches = [i for i in issues if not i.get("pull_request") and
                   isinstance(i.get("user"), dict) and
                   i["user"].get("login") == "github-actions[bot]" and
                   (i.get("body") or "").startswith(drift_marker + "\n")]
        if len(matches) > 1:
            raise ValueError("ambiguous parser-drift work item")
        item = matches[0] if matches else write(f"repos/{repo}/issues", {
            "title": "CodeRabbit review serialization drift",
            "body": f"{drift_marker}\nConfirmed persistent unrecognized review evidence on "
                    f"PR #{number}, head `{head}`, trusted revision `{tip}`. "
                    f"Evidence fingerprint `{report['fingerprint']}`.\n\n"
                    "Repair and test the parser at the canonical source, then propagate and verify consumers. "
                    "Elapsed time and this issue do not clear the required gate. "
                    "[Source contract](https://github.com/nathanjohnpayne/mergepath/issues/906)."})
        if matches:
            update_marker = f"<!-- mergepath-coderabbit-drift-evidence:v1 {number} {head} {report['fingerprint']} -->"
            updates = pages(f"repos/{repo}/issues/{item['number']}/comments?per_page=100")
            if not any(c.get("user", {}).get("login") == "github-actions[bot]" and
                       (c.get("body") or "").startswith(update_marker + "\n") for c in updates):
                update_body = (f"{update_marker}\nAlso observed on PR #{number}, full head `{head}`, "
                               f"trusted revision `{tip}`. The evidence hold remains blocked; "
                               "this record provides no review or merge clearance.")
                updated = write(f"repos/{repo}/issues/{item['number']}/comments", {"body": update_body})
                if updated.get("body") != update_body:
                    raise ValueError("parser-drift update readback mismatch")
        drift = f"\n\nParser-drift work: {item['html_url']}"
    body = (f"{marker}\n## CodeRabbit evidence requires a decision\n\n"
            f"{report['kind'].capitalize()} evidence persists on PR #{number}, full head `{head}`. "
            "This gate remains blocked; all other gates remain required. "
            "Elapsed time has not produced a clean provider verdict.\n\n"
            "For an explicit narrow recovery, the owner posts a new comment with these three lines, "
            "then replaces the Decision value with the link to that same comment:\n\n"
            f"```text\n{report['recovery_token']}\nReason: <concrete reason>\n"
            "Decision: <link to this new comment>\n```\n\n"
            "This comment refreshes the API lineage only. If the native `CodeRabbit unresolved blocking findings` "
            "check failed, rerun that native job/workflow for this exact unchanged full head after the API recovery "
            "is visible; verify both native and API checks. A push changes the head and invalidates this decision. "
            "API recovery alone does not clear a native failure, and the rerun remains labeled recovery in its output. "
            "Later readable blocking evidence overrides recovery. Author attribution carries the accepted "
            "shared-token forgery residual "
            "([#928](https://github.com/nathanjohnpayne/mergepath/issues/928) / "
            "[#2129](https://github.com/nathanjohnpayne/mergepath/issues/2129)); "
            "it is not independent human identity proof."
            + drift)
    posted = write(f"repos/{repo}/issues/{number}/comments", {"body": body})
    if posted.get("body") != body:
        raise ValueError("escalation comment readback mismatch")


def escalate(repo, numbers):
    """Actions-only follow-up; one damaged target cannot suppress the rest."""
    if not re.fullmatch(r"[\w.-]+/[\w.-]+", repo):
        raise ValueError("invalid repository")
    if not re.fullmatch(r"[1-9][0-9]*( [1-9][0-9]*)*", numbers):
        raise ValueError("invalid escalation target list")
    tip = api(f"repos/{repo}/commits/HEAD")["sha"]
    failed = False
    for number in sorted({int(n) for n in numbers.split()}):
        try:
            escalate_one(repo, number, tip)
        except (AttributeError, KeyError, TypeError, ValueError, OSError, subprocess.CalledProcessError, subprocess.TimeoutExpired) as error:
            detail = f": {error}" if isinstance(error, ValueError) else ""
            print(f"CodeRabbit recovery evidence unreadable: {type(error).__name__}{detail} (PR #{number})", file=sys.stderr)
            failed = True
    return 3 if failed else 0

def main():
    if len(sys.argv) == 4 and sys.argv[1] == "--escalate":
        return escalate(sys.argv[2], sys.argv[3])
    request = json.load(sys.stdin)
    repo, pr, head = request["repo"], request["pr"], request["head"]
    timeline = pages(f"repos/{repo}/issues/{pr}/timeline")
    transitions = [{k: event.get(k) for k in ("id", "event", "created_at", "commit_id")}
                   for event in timeline if event.get("event") in
                   ("head_ref_force_pushed", "head_ref_deleted", "head_ref_restored")]
    if any(type(t["id"]) is not int or not isinstance(t["created_at"], str) for t in transitions):
        raise ValueError("unreadable head-transition evidence")
    runs = pages(f"repos/{repo}/commits/{head}/check-runs?filter=all&per_page=100", "check_runs")
    comments = pages(f"repos/{repo}/issues/{pr}/comments?per_page=100")
    result = select(request, runs, comments, transitions, int(time.time()))
    # A recovery is never issued for a different live PR/head or old trusted code.
    live = api(f"repos/{repo}/pulls/{pr}")
    tip = api(f"repos/{repo}/commits/HEAD")
    if (live["head"]["sha"] != head or tip["sha"] != request["revision"]
            or ("base_sha" in request and live["base"]["sha"] != request["base_sha"])):
        raise ValueError("recovery binding changed")
    json.dump(result, sys.stdout, separators=(",", ":"))
    sys.stdout.write("\n")
    return 0 if result["state"] == "recovery" else 3


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (KeyError, TypeError, ValueError, OSError, subprocess.CalledProcessError, subprocess.TimeoutExpired) as error:
        print(f"CodeRabbit recovery evidence unreadable: {type(error).__name__}", file=sys.stderr)
        sys.exit(3)
