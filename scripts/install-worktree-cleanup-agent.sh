#!/usr/bin/env bash
# install-worktree-cleanup-agent.sh — install a macOS launchd agent that runs
# `scripts/worktree-cleanup.sh --apply --min-age 24h` once a day on this
# clone's main checkout. Hub-only, machine-local tooling.
#
# The job removes only what a plain --apply already treats as safe (upstream
# gone or PR closed/merged, nothing git refuses to remove) and keeps anything
# touched in the last day, so a session still working in a merged worktree is
# left alone. Locked worktrees and orphan directories are never touched: the
# job never passes --force-locked or --orphan-clean. Committed work survives
# either way, because `git worktree remove` keeps the branch ref.
#
# The agent always runs the main checkout's copy of worktree-cleanup.sh, not
# the linked worktree the installer ran from, since that worktree is itself a
# cleanup candidate once its PR merges. Output is appended to
# ~/.cache/mergepath/worktree-cleanup.log, about 20 KB per run.
#
# Usage:
#   scripts/install-worktree-cleanup-agent.sh             install or refresh the agent
#   scripts/install-worktree-cleanup-agent.sh --check     exit 0 if installed and loaded, 1 if not
#   scripts/install-worktree-cleanup-agent.sh --uninstall unload and remove the agent
#   scripts/install-worktree-cleanup-agent.sh --print     print the plist without installing
#   scripts/install-worktree-cleanup-agent.sh --run-now   start one run immediately (agent must be installed)
#
# Environment (tests): MERGEPATH_LAUNCH_AGENTS_DIR replaces
# ~/Library/LaunchAgents, MERGEPATH_LAUNCHCTL replaces launchctl.

set -euo pipefail

LABEL=com.nathanjohnpayne.mergepath.worktree-cleanup
MIN_AGE=24h
HOUR=4
MINUTE=17
ACTION=install
while [ "$#" -gt 0 ]; do
  case "$1" in
    --check) ACTION=check ;;
    --uninstall) ACTION=uninstall ;;
    --print) ACTION=print ;;
    --run-now) ACTION=run-now ;;
    -h|--help) awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"; exit 0 ;;
    *) echo "install-worktree-cleanup-agent: unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done

AGENTS_DIR=${MERGEPATH_LAUNCH_AGENTS_DIR:-$HOME/Library/LaunchAgents}
LAUNCHCTL=${MERGEPATH_LAUNCHCTL:-launchctl}
PLIST="$AGENTS_DIR/$LABEL.plist"
DOMAIN="gui/$(id -u)"

# The first `worktree` record is always the main checkout.
main=$(git worktree list --porcelain 2>/dev/null | sed -n '1s/^worktree //p') || main=""
if [ -z "$main" ] || [ ! -f "$main/scripts/worktree-cleanup.sh" ]; then
  echo "install-worktree-cleanup-agent: run this inside a mergepath clone whose main checkout has scripts/worktree-cleanup.sh" >&2
  exit 2
fi
LOG_DIR="$HOME/.cache/mergepath"

xml() { sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' <<<"$1"; }

render() {
  cat <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>$(xml "$main/scripts/worktree-cleanup.sh")</string>
    <string>--apply</string>
    <string>--min-age</string>
    <string>$MIN_AGE</string>
    <string>--no-color</string>
  </array>
  <key>WorkingDirectory</key>
  <string>$(xml "$main")</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key>
    <string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string>
  </dict>
  <key>StartCalendarInterval</key>
  <dict>
    <key>Hour</key>
    <integer>$HOUR</integer>
    <key>Minute</key>
    <integer>$MINUTE</integer>
  </dict>
  <key>StandardOutPath</key>
  <string>$(xml "$LOG_DIR/worktree-cleanup.log")</string>
  <key>StandardErrorPath</key>
  <string>$(xml "$LOG_DIR/worktree-cleanup.log")</string>
  <key>ProcessType</key>
  <string>Background</string>
  <key>LowPriorityIO</key>
  <true/>
</dict>
</plist>
PLIST
}

loaded() { "$LAUNCHCTL" print "$DOMAIN/$LABEL" >/dev/null 2>&1; }

# The job runs whatever branch the main checkout has, which may predate (or,
# after a switch, fall back behind) --min-age.
supports_min_age() { grep -Fq -- '--min-age)' "$main/scripts/worktree-cleanup.sh"; }
MIN_AGE_MISSING="$main/scripts/worktree-cleanup.sh has no --min-age, so the daily run would fail; update the main checkout first (git -C \"$main\" switch main && git -C \"$main\" pull)"

case "$ACTION" in
  print)
    render
    exit 0
    ;;
  check)
    if [ ! -f "$PLIST" ]; then
      echo "install-worktree-cleanup-agent: not installed ($PLIST is missing)"
      exit 1
    fi
    if [ "$(cat "$PLIST")" != "$(render)" ]; then
      echo "install-worktree-cleanup-agent: $PLIST differs from what this checkout would install; rerun the installer to refresh it"
      exit 1
    fi
    if ! loaded; then
      echo "install-worktree-cleanup-agent: $PLIST exists but launchd has not loaded $LABEL; rerun the installer"
      exit 1
    fi
    if ! supports_min_age; then
      echo "install-worktree-cleanup-agent: installed, but $MIN_AGE_MISSING"
      exit 1
    fi
    echo "install-worktree-cleanup-agent: installed and loaded (daily at $(printf '%02d:%02d' "$HOUR" "$MINUTE"), --min-age $MIN_AGE, log $LOG_DIR/worktree-cleanup.log)"
    exit 0
    ;;
  uninstall)
    if loaded; then
      "$LAUNCHCTL" bootout "$DOMAIN/$LABEL"
    fi
    if [ -f "$PLIST" ]; then
      rm -f "$PLIST"
      echo "install-worktree-cleanup-agent: removed $LABEL"
    else
      echo "install-worktree-cleanup-agent: nothing to remove"
    fi
    exit 0
    ;;
  run-now)
    if ! loaded; then
      echo "install-worktree-cleanup-agent: $LABEL is not loaded; install it first" >&2
      exit 1
    fi
    "$LAUNCHCTL" kickstart "$DOMAIN/$LABEL"
    echo "install-worktree-cleanup-agent: started one run; output goes to $LOG_DIR/worktree-cleanup.log"
    exit 0
    ;;
esac

if ! supports_min_age; then
  echo "install-worktree-cleanup-agent: $MIN_AGE_MISSING" >&2
  exit 1
fi
mkdir -p "$AGENTS_DIR" "$LOG_DIR"
tmp=$(mktemp "$AGENTS_DIR/.$LABEL.XXXXXX")
trap 'rm -f "$tmp"' EXIT
render >"$tmp"
if command -v plutil >/dev/null 2>&1; then
  # No -s: Swift's Linux plutil scopes it to conversion and rejects it here.
  plutil -lint "$tmp" >/dev/null || { echo "install-worktree-cleanup-agent: rendered plist failed plutil -lint" >&2; exit 1; }
fi
# Unload the old definition first: bootstrap refuses a label that is already loaded.
if loaded; then
  "$LAUNCHCTL" bootout "$DOMAIN/$LABEL"
fi
mv -f "$tmp" "$PLIST"
"$LAUNCHCTL" bootstrap "$DOMAIN" "$PLIST"
if ! loaded; then
  echo "install-worktree-cleanup-agent: launchctl bootstrap returned but $LABEL is not loaded" >&2
  exit 1
fi
echo "install-worktree-cleanup-agent: installed $LABEL (daily at $(printf '%02d:%02d' "$HOUR" "$MINUTE") on $main, --min-age $MIN_AGE)"
echo "install-worktree-cleanup-agent: log: $LOG_DIR/worktree-cleanup.log; remove with --uninstall"
