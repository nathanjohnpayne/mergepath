#!/usr/bin/env bash
# Parallel no-switch regression for gh-as-author.sh / gh-as-reviewer.sh.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AUTHOR_WRAPPER="$ROOT/scripts/gh-as-author.sh"
REVIEWER_WRAPPER="$ROOT/scripts/gh-as-reviewer.sh"

[[ -x "$AUTHOR_WRAPPER" ]] || { echo "missing or non-executable $AUTHOR_WRAPPER" >&2; exit 1; }
[[ -x "$REVIEWER_WRAPPER" ]] || { echo "missing or non-executable $REVIEWER_WRAPPER" >&2; exit 1; }

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/gh-wrapper-parallel.XXXXXX")"
trap 'rm -rf "$WORKDIR"' EXIT

STUB_DIR="$WORKDIR/stub-bin"
mkdir -p "$STUB_DIR"
LOG="$WORKDIR/gh.log"
: > "$LOG"

cat >"$STUB_DIR/gh" <<'STUB'
#!/usr/bin/env bash
line="GH_TOKEN=${GH_TOKEN:-} gh"
for a in "$@"; do
  line="${line}"$'\t'"$a"
done
printf '%s\n' "$line" >> "${GH_CALLS_LOG:-/dev/null}"

if [ "${1:-}" = "auth" ] && [ "${2:-}" = "switch" ]; then
  echo "gh auth switch must not be called" >&2
  exit 90
fi
if [ "${1:-}" = "api" ] && [ "${2:-}" = "user" ]; then
  case "${GH_TOKEN:-}" in
    author-token) echo "nathanjohnpayne" ;;
    reviewer-token) echo "nathanpayne-codex" ;;
    *) exit 4 ;;
  esac
  exit 0
fi
sleep 0.1
exit 0
STUB
chmod +x "$STUB_DIR/gh"

PATH="$STUB_DIR:$PATH" GH_CALLS_LOG="$LOG" OP_PREFLIGHT_AUTHOR_PAT="author-token" \
  "$AUTHOR_WRAPPER" -- gh pr merge 1 --squash >/dev/null 2>"$WORKDIR/author.err" &
author_pid=$!

PATH="$STUB_DIR:$PATH" GH_CALLS_LOG="$LOG" OP_PREFLIGHT_REVIEWER_PAT="reviewer-token" \
  GH_AS_REVIEWER_IDENTITY="nathanpayne-codex" \
  "$REVIEWER_WRAPPER" -- gh pr review 1 --comment --body "ok" >/dev/null 2>"$WORKDIR/reviewer.err" &
reviewer_pid=$!

author_rc=0
reviewer_rc=0
wait "$author_pid" || author_rc=$?
wait "$reviewer_pid" || reviewer_rc=$?

if [ "$author_rc" -ne 0 ]; then
  echo "FAIL: author wrapper rc=$author_rc stderr=$(cat "$WORKDIR/author.err")" >&2
  exit 1
fi
if [ "$reviewer_rc" -ne 0 ]; then
  echo "FAIL: reviewer wrapper rc=$reviewer_rc stderr=$(cat "$WORKDIR/reviewer.err")" >&2
  exit 1
fi
if grep -q $'gh\tauth\tswitch' "$LOG"; then
  echo "FAIL: wrapper path called gh auth switch" >&2
  cat "$LOG" >&2
  exit 1
fi
if ! grep -q $'GH_TOKEN=author-token gh\tpr\tmerge\t1\t--squash' "$LOG"; then
  echo "FAIL: author write did not run under author-token" >&2
  cat "$LOG" >&2
  exit 1
fi
if ! grep -q $'GH_TOKEN=reviewer-token gh\tpr\treview\t1\t--comment' "$LOG"; then
  echo "FAIL: reviewer write did not run under reviewer-token" >&2
  cat "$LOG" >&2
  exit 1
fi

echo "PASS: parallel wrappers use separate tokens and never call gh auth switch"
exit 0
