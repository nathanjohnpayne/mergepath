"""Launch the local shell without printing any authentication material."""

import argparse
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

from mergepath.cockpit.github import ClientError, GitHubClient
from mergepath.cockpit.fleet import FleetProvider
from mergepath.cockpit.inventory import load_inventory
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


def main(argv=None):
    parser = argparse.ArgumentParser(description="Local Mergepath Cockpit")
    parser.add_argument("--port", type=int, default=0, help="loopback port; 0 chooses an available port")
    args = parser.parse_args(argv)
    if not 0 <= args.port <= 65535:
        parser.error("port must be between 0 and 65535")
    app, fleet = None, None
    try:
        github = GitHubClient.from_environment(os.environ)
        # Drop credentials the read-only foundation does not need. Future
        # owner-only reads/write wrappers have their own explicit contracts.
        for name in ("OP_PREFLIGHT_REVIEWER_PAT", "OP_PREFLIGHT_AUTHOR_PAT", "GH_TOKEN",
                     "GITHUB_TOKEN", "GH_ENTERPRISE_TOKEN", "GITHUB_ENTERPRISE_TOKEN"):
            os.environ.pop(name, None)
        inventory = load_inventory(ROOT)
        app = Application(inventory, github, logger=lambda message: print(message, file=sys.stderr))
        provider = PRProvider(github, inventory, ROOT, checkout_roots={"nathanjohnpayne/mergepath": ROOT})
        app.scheduler.register("prs", provider, hot_interval=15, idle_interval=120, timeout=30)
        app.register_panel("prs", "prs")
        fleet = FleetProvider(inventory, ROOT, github._token)
        app.scheduler.register("fleet", fleet.fetch, hot_interval=1800, idle_interval=1800,
                               timeout=180, max_backoff=7200)
        app.register_panel("fleet", "fleet")
        server = CockpitServer(app, args.port)
    except (ClientError, ValueError, OSError):
        if app is not None:
            app.close()
        if fleet is not None:
            fleet.close()
        print("Cockpit cannot start. Check the cached reviewer credential, installed hub yq and loopback port.",
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
        fleet.close()
        server.shutdown()
        server.server_close()
        thread.join(timeout=1)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
