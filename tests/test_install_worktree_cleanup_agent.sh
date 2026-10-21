#!/usr/bin/env bash
# Tests for scripts/install-worktree-cleanup-agent.sh against a fixture clone
# and a stub launchctl; the real ~/Library/LaunchAgents and launchd are never
# touched.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALLER="$ROOT/scripts/install-worktree-cleanup-agent.sh"
WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/wcagent-test.XXXXXX")"
trap 'rm -rf "$WORKDIR"' EXIT
WORKDIR=$(cd "$WORKDIR" && pwd -P)

PASS=0
FAIL=0
pass() { echo "PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $*" >&2; FAIL=$((FAIL + 1)); }

# An ampersand in the clone path proves the plist escapes XML.
MAIN="$WORKDIR/R&D clone"
git init -q -b main "$MAIN"
git -C "$MAIN" config user.email "test@example.com"
git -C "$MAIN" config user.name "Test"
git -C "$MAIN" config commit.gpgsign false
mkdir -p "$MAIN/scripts"
# shellcheck disable=SC2016 # literal fixture script text
printf '#!/usr/bin/env bash\ncase "$1" in --min-age) ;; esac\n' >"$MAIN/scripts/worktree-cleanup.sh"
git -C "$MAIN" add scripts && git -C "$MAIN" commit -q -m fixture
LINKED="$WORKDIR/linked"
git -C "$MAIN" worktree add -q --detach "$LINKED"

STATE="$WORKDIR/launchd-state"
CALLS="$WORKDIR/launchctl-calls"
cat >"$WORKDIR/launchctl" <<STUB
#!/usr/bin/env bash
echo "\$*" >>"$CALLS"
case "\$1" in
  print) [ -f "$STATE" ] ;;
  bootstrap) [ ! -f "$STATE" ] || { echo "already loaded" >&2; exit 5; }; touch "$STATE" ;;
  bootout) rm -f "$STATE" ;;
  kickstart) [ -f "$STATE" ] ;;
esac
STUB
chmod +x "$WORKDIR/launchctl"
AGENTS="$WORKDIR/LaunchAgents"
PLIST="$AGENTS/com.nathanjohnpayne.mergepath.worktree-cleanup.plist"
run() {
  ( cd "$LINKED" && HOME="$WORKDIR/home" MERGEPATH_LAUNCH_AGENTS_DIR="$AGENTS" \
      MERGEPATH_LAUNCHCTL="$WORKDIR/launchctl" bash "$INSTALLER" "$@" 2>&1 )
}

set +e
OUT=$(run --check); RC=$?
set -e
if [ "$RC" -eq 1 ] && grep -Fq "not installed" <<<"$OUT"; then pass "--check before install exits 1"; else fail "--check before install: rc=$RC $OUT"; fi

OUT=$(run)
if [ -f "$PLIST" ] && [ -f "$STATE" ] && grep -Fq "bootstrap gui/$(id -u) $PLIST" "$CALLS"; then
  pass "install writes the plist and bootstraps it"
else
  fail "install did not write and bootstrap: $OUT"
fi
if grep -Fq "<string>$WORKDIR/R&amp;D clone/scripts/worktree-cleanup.sh</string>" "$PLIST" \
   && ! grep -Fq "$LINKED" "$PLIST"; then
  pass "the plist runs the main checkout's script, XML-escaped, never the linked worktree"
else
  fail "the plist does not point at the escaped main checkout"; cat "$PLIST" >&2
fi
args=$(sed -n '/<key>ProgramArguments<\/key>/,/<\/array>/p' "$PLIST" | sed -n 's/.*<string>\(.*\)<\/string>.*/\1/p' | tail -n +3 | tr '\n' ' ')
if [ "$args" = "--apply --min-age 24h --no-color " ]; then
  pass "the job passes exactly --apply --min-age 24h --no-color"
else
  fail "unexpected job arguments: '$args'"
fi
if command -v plutil >/dev/null 2>&1; then
  if plutil -lint "$PLIST" >/dev/null; then pass "plutil accepts the plist"; else fail "plutil rejected the plist"; fi
fi

OUT=$(run --check)
if grep -Fq "installed and loaded" <<<"$OUT"; then pass "--check after install exits 0"; else fail "--check after install: $OUT"; fi

: >"$CALLS"
OUT=$(run)
if [ "$(grep -c '' "$CALLS")" -ge 3 ] && [ "$(grep -n 'bootout' "$CALLS" | head -1 | cut -d: -f1)" -lt "$(grep -n 'bootstrap' "$CALLS" | head -1 | cut -d: -f1)" ]; then
  pass "reinstalling unloads the old definition before bootstrapping"
else
  fail "reinstall did not boot out first: $(tr '\n' ';' <"$CALLS") $OUT"
fi

OUT=$(run --run-now)
if grep -Fq "kickstart gui/$(id -u)/com.nathanjohnpayne.mergepath.worktree-cleanup" "$CALLS"; then pass "--run-now kickstarts the job"; else fail "--run-now: $OUT"; fi

cp "$MAIN/scripts/worktree-cleanup.sh" "$WORKDIR/cleanup-current"
printf '#!/usr/bin/env bash\n' >"$MAIN/scripts/worktree-cleanup.sh"
set +e
OUT=$(run --check); RC=$?
set -e
if [ "$RC" -eq 1 ] && grep -Fq "installed, but" <<<"$OUT" && grep -Fq "has no --min-age" <<<"$OUT"; then pass "--check notices the main checkout fell back behind --min-age"; else fail "--check after a cleanup-script downgrade: rc=$RC $OUT"; fi
cp "$WORKDIR/cleanup-current" "$MAIN/scripts/worktree-cleanup.sh"

echo "<!-- edited -->" >>"$PLIST"
set +e
OUT=$(run --check); RC=$?
set -e
if [ "$RC" -eq 1 ] && grep -Fq "differs" <<<"$OUT"; then pass "--check notices a stale plist"; else fail "--check stale plist: rc=$RC $OUT"; fi

OUT=$(run --uninstall)
if [ ! -f "$PLIST" ] && [ ! -f "$STATE" ]; then pass "--uninstall unloads and removes the plist"; else fail "--uninstall left state: $OUT"; fi

printf '#!/usr/bin/env bash\n' >"$MAIN/scripts/worktree-cleanup.sh"
set +e
OUT=$(run); RC=$?
set -e
if [ "$RC" -eq 1 ] && grep -Fq "has no --min-age" <<<"$OUT" && [ ! -f "$PLIST" ]; then
  pass "install refuses a main checkout whose cleanup script lacks --min-age"
else
  fail "install did not refuse an old cleanup script: rc=$RC $OUT"
fi

echo ""
echo "RESULTS: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
