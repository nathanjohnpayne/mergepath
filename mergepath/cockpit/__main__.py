"""Launch the local shell without printing any authentication material."""

import argparse
import json
import stat
import os
import re
import shutil
import subprocess
import sys
import threading
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
if not __package__:
    # The launcher uses -I to ignore ambient Python paths and user site code.
    sys.path.insert(0, str(ROOT))

from mergepath.cockpit.author_budget import AuthorBudgetProvider
from mergepath.cockpit.actions import ActionsProvider, ci_observation
from mergepath.cockpit.agents import AgentsProvider, resolve_history_settings
from mergepath.cockpit.github import ClientError, GitHubClient
from mergepath.cockpit.fleet import FleetProvider
from mergepath.cockpit.inventory import load_inventory
from mergepath.cockpit.live_agents import LiveAgentsProvider, resolve_live_directory
from mergepath.cockpit.ci import (CIProvider, HOT_INTERVAL as CI_HOT_INTERVAL, IDLE_INTERVAL as CI_IDLE_INTERVAL,
                                  LogExcerptCache, OBSERVATION_GAP as CI_OBSERVATION_GAP, TIMEOUT as CI_TIMEOUT)
from mergepath.cockpit.prs import PRProvider
from mergepath.cockpit.server import Application, CockpitServer
from mergepath.cockpit.sync import SyncProvider


def open_browser(url):
    command = "open" if sys.platform == "darwin" else "xdg-open"
    executable = shutil.which(command)
    if not executable:
        return False
    try:
        process = subprocess.Popen([executable, url], stdin=subprocess.DEVNULL,
                                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                   start_new_session=True)
        try:
            return process.wait(timeout=10) == 0
        except subprocess.TimeoutExpired:
            # xdg-open may follow the browser until it exits. A live opener is
            # not a failed launch and must not tear down the healthy server.
            return True
    except (OSError, subprocess.SubprocessError):
        return False


def close_runtime(app, fleet):
    """Stop audit owners before a preview worker waiting on their result."""
    if app is not None:
        app.stopping.set()
        app.scheduler.close()
    try:
        if fleet is not None:
            fleet.close()
    finally:
        if app is not None:
            app.close()


def load_settings_json(path):
    if path is None:
        return {}
    descriptor = os.open(path, os.O_RDONLY | os.O_NONBLOCK | os.O_NOFOLLOW)
    with os.fdopen(descriptor, "rb") as stream:
        if not stat.S_ISREG(os.fstat(stream.fileno()).st_mode):
            raise ValueError("invalid_settings_json")
        raw = stream.read(65537)
    if len(raw) > 65536:
        raise ValueError("invalid_settings_json")
    try:
        value = json.loads(raw)
    except (ValueError, RecursionError):
        raise ValueError("invalid_settings_json") from None
    if type(value) is not dict:
        raise ValueError("invalid_settings_json")
    return value



def load_reviewers(root, run=subprocess.run):
    # Registered identities are configuration, never inferred from review authors.
    env = {"PATH": os.environ.get("PATH", os.defpath), "HOME": str(Path.home())}
    try:
        result = run(["yq", "-o=json", ".available_reviewers", str(root / ".github/review-policy.yml")],
                     capture_output=True, text=True, check=True, timeout=5, env=env)
        if len(result.stdout) > 16384:
            raise ValueError("invalid_reviewer_configuration")
        reviewers = json.loads(result.stdout)
        if (type(reviewers) is not list or not 1 <= len(reviewers) <= 64
                or any(type(name) is not str or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9-]{0,38}", name)
                       for name in reviewers)):
            raise ValueError("invalid_reviewer_configuration")
        return tuple(dict.fromkeys(reviewers))
    except (OSError, ValueError, subprocess.SubprocessError):
        raise ValueError("invalid_reviewer_configuration") from None


def shared_ci_snapshot(app, repo, _fetch_now):
    # Another source can publish while Actions is fetching. Read the copied
    # receipt before the validation clock, so a new observation is not future.
    envelope = app.panel_snapshot("ci")["envelope"]
    return ci_observation(envelope, repo, app.clock(), max_age=CI_OBSERVATION_GAP)


def main(argv=None):
    parser = argparse.ArgumentParser(description="Local Mergepath Cockpit")
    parser.add_argument("--agent", choices=("codex", "claude", "cursor"), default="codex",
                        help="agent whose existing credential cache is used for author telemetry and confirmed sync")
    parser.add_argument("--port", type=int, default=0, help="loopback port; 0 chooses an available port")
    parser.add_argument("--actions-settings", help="local JSON containing explicit budget, cycle and measured coefficients")
    parser.add_argument("--agents-settings", help="local JSON containing explicit checkout roots and optional price keys")
    args = parser.parse_args(argv)
    if not 0 <= args.port <= 65535:
        parser.error("port must be between 0 and 65535")
    app, fleet = None, None
    try:
        actions_settings = load_settings_json(args.actions_settings)
        agents_settings = load_settings_json(args.agents_settings)
        # Eight repositories of pulls, runs, status, job and check pages must stay ETag-cached.
        github = GitHubClient.from_environment(os.environ, cache_pages=768)
        # Resolve the canonical cache once before worker HOME/XDG isolation.
        cache_dir = Path(os.environ.get("OP_PREFLIGHT_CACHE_DIR") or
                         str(Path(os.environ.get("XDG_CACHE_HOME") or Path.home() / ".cache") / "mergepath")).resolve()
        # Only isolated workers may reacquire author credentials through
        # the canonical cache-check wrapper; the server keeps reviewer reads.
        for name in ("OP_PREFLIGHT_REVIEWER_PAT", "OP_PREFLIGHT_AUTHOR_PAT", "GH_TOKEN",
                     "GITHUB_TOKEN", "GH_ENTERPRISE_TOKEN", "GITHUB_ENTERPRISE_TOKEN"):
            os.environ.pop(name, None)
        inventory = load_inventory(ROOT)
        checkouts, price_keys = resolve_history_settings(agents_settings, inventory, ROOT)
        reviewers = load_reviewers(ROOT)
        app = Application(inventory, github, logger=lambda message: print(message, file=sys.stderr))
        app.api_author = AuthorBudgetProvider(ROOT, cache_dir, args.agent)
        app.scheduler.register("api_author", app.api_author.fetch, hot_interval=60, idle_interval=60, timeout=20)
        ci_provider = CIProvider(github, inventory)
        # A full eight-repository scan costs 30 to 55 paid requests and about a minute even at
        # steady state (measured 2026-10-06), so the hot cadence is a minute, not 20 seconds.
        # The Actions budget reads this snapshot within ci.OBSERVATION_GAP, derived from it.
        app.scheduler.register("ci", ci_provider, hot_interval=CI_HOT_INTERVAL, idle_interval=CI_IDLE_INTERVAL, timeout=CI_TIMEOUT)
        app.register_panel("ci", "ci")
        app.ci_excerpts = LogExcerptCache(inventory, lambda repo, job, deadline: github.read_job_log(repo, job, deadline=deadline))
        pr_provider = PRProvider(github, inventory, ROOT, checkout_roots={"nathanjohnpayne/mergepath": ROOT})
        app.scheduler.register("prs", pr_provider, hot_interval=15, idle_interval=120, timeout=30)
        app.register_panel("prs", "prs")
        try:
            fleet = FleetProvider(inventory, ROOT, github._token)
        except (ValueError, OSError):
            print("Fleet audits unavailable: trusted audit tools or private workspace could not be initialized.",
                  file=sys.stderr)
        if fleet is not None:
            app.scheduler.register("fleet", fleet.fetch, hot_interval=1800, idle_interval=1800,
                                   timeout=180, max_backoff=7200)
            app.register_panel("fleet", "fleet")
            def completed():
                if not app.stopping.is_set():
                    app.scheduler.refresh("fleet")
                    app.scheduler.refresh("prs")
            app.sync = SyncProvider(inventory, ROOT, fleet.fetch, cache_dir=cache_dir, agent=args.agent,
                                    changed=app.publish, completed=completed)
        actions_provider = ActionsProvider(github, inventory, settings=actions_settings,
                                           ci_snapshot=lambda repo, now: shared_ci_snapshot(app, repo, now),
                                           ci_max_gap=CI_OBSERVATION_GAP, installation_scan=True)
        app.scheduler.register("actions", actions_provider.fetch, hot_interval=15, idle_interval=120, timeout=30)
        app.register_panel("budget", "actions")
        agents_provider = AgentsProvider(inventory, checkouts, ROOT, price_keys=price_keys, github=github, reviewers=reviewers)
        app.scheduler.register("agents", agents_provider.fetch, hot_interval=30, idle_interval=120, timeout=30)
        app.register_panel("history", "agents")
        live_agents = LiveAgentsProvider(inventory, resolve_live_directory(os.environ.get("P4B_HEARTBEAT_DIR") or None), ROOT)
        app.scheduler.register("live_agents", live_agents.fetch, hot_interval=5, idle_interval=5, timeout=10, max_backoff=60)
        app.register_panel("agents", "live_agents")
        server = CockpitServer(app, args.port)
    except (ClientError, ValueError, OSError):
        close_runtime(app, fleet)
        print("Cockpit cannot start. Check the cached reviewer credential, installed hub yq, settings JSON and loopback port.",
              file=sys.stderr)
        return 1
    port = server.server_address[1]
    print(f"Mergepath Cockpit: http://127.0.0.1:{port}/", flush=True)
    print("Shared observations ready. Ctrl-C stops the local server.", flush=True)
    app.scheduler.start()
    thread = threading.Thread(target=server.serve_forever, daemon=True, name="cockpit-http")
    thread.start()
    try:
        if not open_browser(app.launch_url(port)):
            print("Browser opening failed. Relaunch scripts/cockpit.sh when the local browser is available.",
                  file=sys.stderr)
            return 1
        while thread.is_alive():
            thread.join(timeout=0.5)
    except KeyboardInterrupt:
        pass
    finally:
        close_runtime(app, fleet)
        server.shutdown()
        server.server_close()
        thread.join(timeout=1)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
