"""Launch the local shell without printing any authentication material."""

import argparse
import json
import stat
import os
import shutil
import subprocess
import sys
import threading
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
if not __package__:
    # The launcher uses -I to ignore ambient Python paths and user site code.
    sys.path.insert(0, str(ROOT))

from mergepath.cockpit.actions import ActionsProvider, ci_observation
from mergepath.cockpit.github import ClientError, GitHubClient
from mergepath.cockpit.fleet import FleetProvider
from mergepath.cockpit.inventory import load_inventory
from mergepath.cockpit.ci import CIProvider, LogExcerptCache
from mergepath.cockpit.prs import PRProvider
from mergepath.cockpit.server import Application, CockpitServer


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


def load_actions_settings(path):
    if path is None:
        return {}
    descriptor = os.open(path, os.O_RDONLY | os.O_NONBLOCK | os.O_NOFOLLOW)
    with os.fdopen(descriptor, "rb") as stream:
        if not stat.S_ISREG(os.fstat(stream.fileno()).st_mode):
            raise ValueError("invalid_actions_settings")
        raw = stream.read(65537)
    if len(raw) > 65536:
        raise ValueError("invalid_actions_settings")
    try:
        value = json.loads(raw)
    except (ValueError, RecursionError):
        raise ValueError("invalid_actions_settings") from None
    if type(value) is not dict:
        raise ValueError("invalid_actions_settings")
    return value


def shared_ci_snapshot(app, repo, _fetch_now):
    # Another source can publish while Actions is fetching. Read the copied
    # receipt before the validation clock, so a new observation is not future.
    envelope = app.panel_snapshot("ci")["envelope"]
    return ci_observation(envelope, repo, app.clock())


def main(argv=None):
    parser = argparse.ArgumentParser(description="Local Mergepath Cockpit")
    parser.add_argument("--port", type=int, default=0, help="loopback port; 0 chooses an available port")
    parser.add_argument("--actions-settings", help="local JSON containing explicit budget, cycle and measured coefficients")
    args = parser.parse_args(argv)
    if not 0 <= args.port <= 65535:
        parser.error("port must be between 0 and 65535")
    app, fleet = None, None
    try:
        actions_settings = load_actions_settings(args.actions_settings)
        github = GitHubClient.from_environment(os.environ)
        # Drop credentials the read-only foundation does not need. Future
        # owner-only reads/write wrappers have their own explicit contracts.
        for name in ("OP_PREFLIGHT_REVIEWER_PAT", "OP_PREFLIGHT_AUTHOR_PAT", "GH_TOKEN",
                     "GITHUB_TOKEN", "GH_ENTERPRISE_TOKEN", "GITHUB_ENTERPRISE_TOKEN"):
            os.environ.pop(name, None)
        inventory = load_inventory(ROOT)
        app = Application(inventory, github, logger=lambda message: print(message, file=sys.stderr))
        ci_provider = CIProvider(github, inventory)
        app.scheduler.register("ci", ci_provider, hot_interval=20, idle_interval=120, timeout=60)
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
        actions_provider = ActionsProvider(github, inventory, settings=actions_settings,
                                           ci_snapshot=lambda repo, now: shared_ci_snapshot(app, repo, now))
        app.scheduler.register("actions", actions_provider.fetch, hot_interval=15, idle_interval=120, timeout=30)
        app.register_panel("budget", "actions")
        server = CockpitServer(app, args.port)
    except (ClientError, ValueError, OSError):
        if app is not None:
            app.close()
        if fleet is not None:
            fleet.close()
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
        app.close()
        if fleet is not None:
            fleet.close()
        server.shutdown()
        server.server_close()
        thread.join(timeout=1)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
