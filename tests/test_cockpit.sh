#!/usr/bin/env bash
# Hermetic combined Cockpit suite: expected ~60s; each test process bounded60s.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
PYTHONDONTWRITEBYTECODE=1 python3 - <<'PY'
import subprocess
import os
import sys
os.environ["COCKPIT_SHARED_APP"] = os.path.abspath("mergepath/cockpit/assets/app.js")
for command in ([sys.executable, '-B', 'tests/test_cockpit.py'], [sys.executable, '-B', 'tests/test_cockpit_author_budget.py'], ['node', '--test', 'tests/test_cockpit_ui.cjs'],
                ['node', '--test', 'tests/test_cockpit_layout_ui.cjs'],
                [sys.executable, '-B', 'tests/test_cockpit_ci.py'],
                ['node', '--test', 'tests/test_cockpit_ci_ui.cjs'],
                [sys.executable, '-B', 'tests/test_cockpit_logs.py'],
                [sys.executable, '-B', 'tests/test_cockpit_prs.py'],
                ['node', '--test', 'tests/test_cockpit_prs_ui.cjs'],
                [sys.executable, '-B', 'tests/test_cockpit_fleet.py'],
                ['node', '--test', 'tests/test_cockpit_fleet_ui.cjs'],
                [sys.executable, '-B', 'tests/test_cockpit_sync.py'],
                ['node', '--test', 'tests/test_cockpit_sync_ui.cjs'],
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

# #1832: check_cockpit --check against a fixture copy of the Cockpit tree. Each
# case breaks one file the check must parse and expects a failure naming it.
CHECK_FIXTURE="$(mktemp -d "${TMPDIR:-/tmp}/check-cockpit.XXXXXX")"
trap 'rm -rf "$CHECK_FIXTURE"' EXIT
mkdir -p "$CHECK_FIXTURE/scripts/ci" "$CHECK_FIXTURE/scripts/lib" "$CHECK_FIXTURE/tests" \
  "$CHECK_FIXTURE/specs" "$CHECK_FIXTURE/mergepath"
cp scripts/ci/check_cockpit "$CHECK_FIXTURE/scripts/ci/"
cp scripts/lib/ci-check-modes.sh "$CHECK_FIXTURE/scripts/lib/"
cp scripts/cockpit.sh "$CHECK_FIXTURE/scripts/"
: > "$CHECK_FIXTURE/scripts/sync-to-downstream.sh"
cp -R mergepath/cockpit "$CHECK_FIXTURE/mergepath/"
cp tests/test_cockpit* "$CHECK_FIXTURE/tests/"
cp specs/cockpit_*.md "$CHECK_FIXTURE/specs/"

check_fixture_case() {
  local label="$1" broken="$2" content="$3" saved="" output="" status=0
  if [ -f "$CHECK_FIXTURE/$broken" ]; then
    saved="$CHECK_FIXTURE/.saved"
    cp "$CHECK_FIXTURE/$broken" "$saved"
  fi
  printf '%s\n' "$content" >> "$CHECK_FIXTURE/$broken"
  output="$(bash "$CHECK_FIXTURE/scripts/ci/check_cockpit" --check 2>&1)" || status=$?
  if [ -n "$saved" ]; then
    mv "$saved" "$CHECK_FIXTURE/$broken"
  else
    rm -f "$CHECK_FIXTURE/$broken"
  fi
  if [ "$status" -eq 0 ]; then
    echo "FAIL: check_cockpit passed with $label ($broken)" >&2
    exit 1
  fi
  case "$output" in
    *"$broken"*) echo "PASS: check_cockpit rejects $label" ;;
    *) echo "FAIL: check_cockpit failure for $label does not name $broken: $output" >&2; exit 1 ;;
  esac
}

bash "$CHECK_FIXTURE/scripts/ci/check_cockpit" --check >/dev/null
echo "PASS: check_cockpit accepts the fixture Cockpit tree"
check_fixture_case "a broken second bash -n subject" tests/test_cockpit.sh 'if then fi'
check_fixture_case "a new unlisted Python test" tests/test_cockpit_zz_new.py 'def broken(:'
check_fixture_case "a new unlisted Python module" mergepath/cockpit/zz_new.py 'def broken(:'
check_fixture_case "a new unlisted asset script" mergepath/cockpit/assets/zz_new.js 'function broken( {'
check_fixture_case "a new unlisted UI test" tests/test_cockpit_zz_new_ui.cjs 'function broken( {'
check_fixture_case "invalid PR settings JSON" mergepath/cockpit/pr_settings.json '{'
check_fixture_case "invalid asset JSON" mergepath/cockpit/assets/fonts/manifest.json '{'
# A JSON file with whitespace in its name is read whole: valid passes, invalid fails naming it.
printf '{}\n' > "$CHECK_FIXTURE/mergepath/cockpit/assets/spaced name.json"
bash "$CHECK_FIXTURE/scripts/ci/check_cockpit" --check >/dev/null
echo "PASS: check_cockpit accepts a valid JSON file with whitespace in its name"
check_fixture_case "invalid JSON with whitespace in its name" "mergepath/cockpit/assets/spaced name.json" '{'
rm -f "$CHECK_FIXTURE/mergepath/cockpit/assets/spaced name.json"
