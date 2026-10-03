#!/usr/bin/env bash
# Hermetic foundation suite: expected <15s; hard process bound 60s.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
PYTHONDONTWRITEBYTECODE=1 python3 - <<'PY'
import subprocess
import os
import sys
os.environ["COCKPIT_SHARED_APP"] = os.path.abspath("mergepath/cockpit/assets/app.js")
for command in ([sys.executable, '-B', 'tests/test_cockpit.py'], ['node', '--test', 'tests/test_cockpit_ui.cjs'],
                [sys.executable, '-B', 'tests/test_cockpit_ci.py'],
                ['node', '--test', 'tests/test_cockpit_ci_ui.cjs'],
                [sys.executable, '-B', 'tests/test_cockpit_logs.py'],
                [sys.executable, '-B', 'tests/test_cockpit_prs.py'],
                ['node', '--test', 'tests/test_cockpit_prs_ui.cjs'],
                [sys.executable, '-B', '-m', 'unittest', 'discover', '-s', 'tests', '-p', 'test_cockpit_actions.py'],
                ['node', '--test', 'tests/test_cockpit_actions_ui.cjs'],
                [sys.executable, '-B', '-m', 'unittest', 'tests.test_cockpit_agents'],
                ['node', '--test', 'tests/test_cockpit_agents_ui.cjs'],
                [sys.executable, '-B', '-m', 'unittest', 'tests.test_cockpit_live_agents'],
                ['node', '--test', 'tests/test_cockpit_live_agents_ui.cjs']):
    result = subprocess.run(command, timeout=60)
    if result.returncode:
        raise SystemExit(result.returncode)
PY
