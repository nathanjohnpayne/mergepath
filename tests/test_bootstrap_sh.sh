#!/usr/bin/env bash
# tests/test_bootstrap_sh.sh
#
# Regression coverage for scripts/bootstrap.sh, the legacy per-repo
# config restore helper. The newer bootstrap wizard has separate test
# suites; this file focuses on the runtime-secret bootstrap contract.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/scripts/bootstrap.sh"

[[ -x "$SCRIPT" ]] || { echo "missing or non-executable $SCRIPT" >&2; exit 1; }

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/bootstrap-sh-test.XXXXXX")"
trap 'rm -rf "$WORKDIR"' EXIT

PASS=0
FAIL=0
pass() { echo "PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $*" >&2; FAIL=$((FAIL + 1)); }

make_fixture() {
  local fixture="$WORKDIR/$1"
  mkdir -p "$fixture/scripts"
  cp "$SCRIPT" "$fixture/scripts/bootstrap.sh"
  chmod +x "$fixture/scripts/bootstrap.sh"
  printf '%s\n' "$fixture"
}

# --help should advertise only the restore contract.
help_out="$("$SCRIPT" --help 2>&1)"
if grep -q "Usage: .*\\[--dry-run\\] \\[--force\\]" <<<"$help_out"; then
  pass "--help renders restore-only usage"
else
  fail "--help did not include restore-only usage: $help_out"
fi

if grep -q -- "--sync" <<<"$help_out"; then
  fail "--help should not advertise removed --sync mode"
else
  pass "--help omits removed --sync mode"
fi

if grep -q "^set -euo pipefail$" "$SCRIPT"; then
  pass "script enables full shell strict mode"
else
  fail "script should use set -euo pipefail"
fi

# --sync is a removed legacy path and must fail before touching 1Password.
set +e
sync_out="$("$SCRIPT" --sync 2>&1)"
sync_ec=$?
set -e
if [[ "$sync_ec" -eq 2 ]] && grep -q "was removed" <<<"$sync_out"; then
  pass "--sync exits 2 with removal diagnostic"
else
  fail "--sync should exit 2 with removal diagnostic; rc=$sync_ec out=$sync_out"
fi

set +e
unknown_out="$("$SCRIPT" --not-a-real-flag 2>&1)"
unknown_ec=$?
set -e
if [[ "$unknown_ec" -eq 1 ]] && grep -q "unknown option: --not-a-real-flag" <<<"$unknown_out"; then
  pass "unknown flags exit 1 with diagnostic"
else
  fail "unknown flags should exit 1 with diagnostic; rc=$unknown_ec out=$unknown_out"
fi

# An empty config should point maintainers at INJECT_FILES only.
empty_fixture="$(make_fixture empty)"
set +e
empty_out="$("$empty_fixture/scripts/bootstrap.sh" --dry-run 2>&1)"
empty_ec=$?
set -e
if [[ "$empty_ec" -eq 1 ]] && grep -q "INJECT_FILES" <<<"$empty_out"; then
  pass "empty config exits 1 with INJECT_FILES guidance"
else
  fail "empty config should exit 1 with INJECT_FILES guidance; rc=$empty_ec out=$empty_out"
fi

if grep -q "BOOTSTRAP_FILES=(" <<<"$empty_out"; then
  fail "empty-config guidance should not suggest legacy BOOTSTRAP_FILES"
else
  pass "empty-config guidance omits BOOTSTRAP_FILES"
fi

# A stale consumer config with non-empty BOOTSTRAP_FILES must fail loud.
legacy_fixture="$(make_fixture legacy)"
cat >"$legacy_fixture/scripts/bootstrap-config.sh" <<'EOF_LEGACY'
BOOTSTRAP_FILES=("old-item:.env.local")
EOF_LEGACY

set +e
legacy_out="$("$legacy_fixture/scripts/bootstrap.sh" --dry-run 2>&1)"
legacy_ec=$?
set -e
if [[ "$legacy_ec" -eq 2 ]] && grep -q "legacy BOOTSTRAP_FILES / notesPlain" <<<"$legacy_out"; then
  pass "legacy BOOTSTRAP_FILES exits 2 with migration diagnostic"
else
  fail "legacy BOOTSTRAP_FILES should exit 2 with migration diagnostic; rc=$legacy_ec out=$legacy_out"
fi

# INJECT_FILES remains the supported generated-file path and must use
# op inject, not the removed op read/notesPlain flow.
inject_fixture="$(make_fixture inject)"
mkdir -p "$inject_fixture/bin"
cat >"$inject_fixture/bin/op" <<'EOF_OP'
#!/usr/bin/env bash
set -euo pipefail
echo "$*" >>"${OP_LOG:?}"

case "$1" in
  account)
    [[ "${2:-}" == "list" ]] && exit 0
    ;;
  vault)
    [[ "${2:-}" == "list" ]] && exit 0
    ;;
  inject)
    shift
    input=""
    output=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        -i)
          input="$2"
          shift 2
          ;;
        -o)
          output="$2"
          shift 2
          ;;
        *)
          shift
          ;;
      esac
    done
    [[ -n "$input" && -n "$output" ]]
    cp "$input" "$output"
    exit 0
    ;;
  read)
    echo "unexpected op read" >&2
    exit 99
    ;;
esac

echo "unexpected op command: $*" >&2
exit 98
EOF_OP
chmod +x "$inject_fixture/bin/op"

cat >"$inject_fixture/scripts/bootstrap-config.sh" <<'EOF_CONFIG'
INJECT_FILES=(".env.tpl:.env.local")
EOF_CONFIG
printf '%s\n' 'TOKEN=op://Private/example/password' >"$inject_fixture/.env.tpl"

inject_log="$inject_fixture/op.log"
set +e
inject_out="$(PATH="$inject_fixture/bin:$PATH" OP_LOG="$inject_log" "$inject_fixture/scripts/bootstrap.sh" --force 2>&1)"
inject_ec=$?
set -e
if [[ "$inject_ec" -eq 0 ]] && [[ -f "$inject_fixture/.env.local" ]]; then
  pass "INJECT_FILES restore succeeds with op inject"
else
  fail "INJECT_FILES restore should succeed; rc=$inject_ec out=$inject_out"
fi

if grep -q "^inject " "$inject_log" && ! grep -q "^read " "$inject_log"; then
  pass "restore path uses op inject and never op read"
else
  fail "restore path should use op inject only; log=$(cat "$inject_log" 2>/dev/null || true)"
fi

if [[ "$FAIL" -ne 0 ]]; then
  echo
  echo "test_bootstrap_sh: $PASS passed, $FAIL failed" >&2
  exit 1
fi

echo
echo "test_bootstrap_sh: $PASS passed, 0 failed"
