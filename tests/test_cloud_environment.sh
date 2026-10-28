#!/usr/bin/env bash
# tests/test_cloud_environment.sh
#
# Regression suite for the committed cloud-environment recipe (#1057 item F):
#   - scripts/hooks/cloud-session-start.sh (Claude Code SessionStart hook)
#   - scripts/cloud-setup.sh (setup script for Claude and Codex cloud)
#   - docs/agents/cloud-environments.md names only files that exist, and
#     .claude/settings.json actually wires the hook the doc describes
#
# The setup script's install path is exercised offline: `uname`, `curl` and
# the checksum tool are real or shimmed so a fake release tarball is
# "downloaded" from a local fixture, and the checksum gate is tested in both
# directions.
#
# Bash 3.2 portable.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
command -v jq >/dev/null 2>&1 || { echo "jq is required" >&2; exit 1; }

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/cloud-environment-test.XXXXXX")"
trap 'rm -rf "$WORKDIR"' EXIT

PASS=0
FAIL=0
pass() { echo "PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $*" >&2; FAIL=$((FAIL + 1)); }

# ---------------------------------------------------------------------------
# SessionStart hook
# ---------------------------------------------------------------------------
HFIX="$WORKDIR/hook-repo"
mkdir -p "$HFIX/scripts/hooks"
cp "$ROOT/scripts/hooks/cloud-session-start.sh" "$HFIX/scripts/hooks/"
cat >"$HFIX/scripts/agent-capability-probe.sh" <<'PROBE'
#!/usr/bin/env bash
echo "probe $*" >>"$PROBE_LOG"
[ "${PROBE_MODE:-ok}" = fail ] && exit 1
cat <<JSON
{"surface":"claude-cloud","repo":"o/r","tier":"author-writes","transient_failures":${PROBE_TRANSIENT:-false},
 "capabilities":{"read":{"granted":true,"reason":"r"},"author-writes":{"granted":true,"reason":"a"},
 "reviewer-writes":{"granted":false,"basis":"${PROBE_RW_BASIS:-measured}","reason":"no-verified-token"},
 "graphql":{"granted":false,"basis":"measured","reason":"viewer query returned 500"},
 "cross-repo":{"granted":false,"basis":"measured","reason":"GET repos/x/y returned 403"},
 "push-multi-branch":{"granted":false,"basis":"documented","reason":"documented"}}}
JSON
PROBE
chmod +x "$HFIX/scripts/agent-capability-probe.sh"
HOOK="$HFIX/scripts/hooks/cloud-session-start.sh"

: >"$WORKDIR/probe.log"
out="$(env -u CLAUDE_CODE_REMOTE PROBE_LOG="$WORKDIR/probe.log" bash "$HOOK")"; rc=$?
if [ "$rc" -eq 0 ] && [ -z "$out" ] && [ ! -s "$WORKDIR/probe.log" ]; then
  pass "hook, local session: exits 0, prints nothing, never runs the probe"
else
  fail "hook local: rc=$rc out=$out probe=$(cat "$WORKDIR/probe.log")"
fi

out="$(CLAUDE_CODE_REMOTE=true PROBE_LOG="$WORKDIR/probe.log" bash "$HOOK")"; rc=$?
if [ "$rc" -eq 0 ] && grep -q 'capability tier `author-writes`' <<<"$out" \
   && grep -q -- '- push-multi-branch: no, documented (proxy ceiling: hand this step to a local session or CI)' <<<"$out" \
   && grep -q -- '- reviewer-writes: no, no-verified-token (fix the credential, tools or setup, then re-run' <<<"$out" \
   && grep -q -- '- graphql: no, viewer query returned 500 (fix the credential, tools or setup' <<<"$out" \
   && grep -q -- '- cross-repo: no, GET repos/x/y returned 403 (fix the credential, tools or setup' <<<"$out" \
   && grep -q -- '- author-writes: yes, a$' <<<"$out" \
   && ! grep -q -- 'may be transient' <<<"$out" \
   && grep -q -- '--quiet' "$WORKDIR/probe.log"; then
  pass "hook, cloud session: classifies each no from the probe's basis and reason (a documented denial is a ceiling; a GraphQL 500 or a bare cross-repo 403 is fix-first)"
else
  fail "hook cloud: rc=$rc out=$out"
fi

# A run with a transient failure (a rate-limited 403 among them) re-probes its
# measured "no" answers before calling them a setup problem or a ceiling.
out="$(CLAUDE_CODE_REMOTE=true PROBE_TRANSIENT=true PROBE_LOG="$WORKDIR/probe.log" bash "$HOOK")"; rc=$?
if [ "$rc" -eq 0 ] && grep -q -- '- cross-repo: no, GET repos/x/y returned 403 (may be transient: re-run' <<<"$out" \
   && grep -q -- '- graphql: no, viewer query returned 500 (may be transient' <<<"$out" \
   && grep -q -- '- push-multi-branch: no, documented (proxy ceiling' <<<"$out" \
   && ! grep -q -- 'fix the credential, tools or setup, then' <<<"$out"; then
  pass "hook, transient run: a measured no is marked may-be-transient, a documented ceiling stays a ceiling"
else
  fail "hook transient: rc=$rc out=$out"
fi

# A fine-grained token is unverifiable, not broken: no re-probe can grant it
# and the wrappers accept it, so it is not sent round the fix-and-re-probe
# loop (Codex on #1552).
out="$(CLAUDE_CODE_REMOTE=true PROBE_RW_BASIS=unverifiable PROBE_LOG="$WORKDIR/probe.log" bash "$HOOK")"; rc=$?
if [ "$rc" -eq 0 ] && grep -q -- "- reviewer-writes: no, no-verified-token (not provable: GitHub does not expose this token type's permissions; the wrappers still verify" <<<"$out" \
   && ! grep -q -- '- reviewer-writes: .*fix the credential' <<<"$out" \
   && ! grep -qi -- 'any other no' <<<"$out"; then
  pass "hook, unverifiable token: reported as not provable, not as a setup problem to fix and re-probe"
else
  fail "hook unverifiable: rc=$rc out=$out"
fi

out="$(CLAUDE_CODE_REMOTE=true PROBE_MODE=fail PROBE_LOG="$WORKDIR/probe.log" bash "$HOOK")"; rc=$?
if [ "$rc" -eq 0 ] && grep -q "capabilities unknown" <<<"$out"; then
  pass "hook, probe failure: still exits 0 and says the capabilities are unknown"
else
  fail "hook probe failure: rc=$rc out=$out"
fi

# The hook runs the setup first: it reports what setup installed, reports a
# setup failure, and probes either way.
cat >"$HFIX/scripts/cloud-setup.sh" <<'SETUP'
#!/usr/bin/env bash
echo "setup ran" >>"$PROBE_LOG"
echo "cloud-setup: gh present: gh version 9 (fixture)" >&2
case "${SETUP_MODE:-noop}" in
  install) echo "cloud-setup: installed yq v4.53.6 to /x/bin/yq (sha256 verified)" >&2 ;;
  fail) echo "cloud-setup: checksum mismatch for yq; refusing to install" >&2; exit 1 ;;
esac
exit 0
SETUP
# A PATH with only the tools the hook and its fixtures run, so timeout command
# selection is decided here, not by the host: HBIN has `timeout`, HBIN_GT has
# only `gtimeout`, and HBIN_NT has neither.
HBIN="$WORKDIR/hook-bin"
HBIN_GT="$WORKDIR/hook-bin-gtimeout"
HBIN_NT="$WORKDIR/hook-bin-notimeout"
mkdir -p "$HBIN" "$HBIN_GT" "$HBIN_NT"
for tool in bash env cat sed paste tail head dirname jq; do
  real="$(command -v "$tool" 2>/dev/null || true)"
  case "$real" in
    /*) ln -sf "$real" "$HBIN/$tool"; ln -sf "$real" "$HBIN_GT/$tool"; ln -sf "$real" "$HBIN_NT/$tool" ;;
  esac
done
cat >"$HBIN/timeout" <<T
#!/usr/bin/env bash
echo "timeout \$1" >>"$WORKDIR/timeout.log"
shift
exec "\$@"
T
chmod +x "$HBIN/timeout"
cat >"$HBIN_GT/gtimeout" <<T
#!/usr/bin/env bash
echo "gtimeout \$1" >>"$WORKDIR/timeout.log"
shift
exec "\$@"
T
chmod +x "$HBIN_GT/gtimeout"
: >"$WORKDIR/probe.log"
: >"$WORKDIR/timeout.log"
out="$(CLAUDE_CODE_REMOTE=true SETUP_MODE=install PROBE_LOG="$WORKDIR/probe.log" PATH="$HBIN" bash "$HOOK")"; rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | head -1 | grep -qx 'mergepath cloud session: installed yq v4.53.6 (scripts/cloud-setup.sh).' \
   && grep -q 'capability tier `author-writes`' <<<"$out" \
   && [ "$(head -1 "$WORKDIR/probe.log")" = "setup ran" ] && grep -q '^probe ' "$WORKDIR/probe.log" \
   && [ "$(head -1 "$WORKDIR/timeout.log")" = "timeout 60" ] \
   && [ "$(tail -1 "$WORKDIR/timeout.log")" = "timeout 90" ]; then
  pass "hook, cloud session: bounds setup and probe before reporting what setup installed"
else
  fail "hook setup install: rc=$rc out=$out log=$(cat "$WORKDIR/probe.log") timeout=$(cat "$WORKDIR/timeout.log")"
fi
# MERGEPATH_CLOUD_SETUP_TIMEOUT may lower the bound to 1..60 seconds; a larger,
# zero or non-numeric value keeps 60 with a notice, so setup can never outlast the
# hook's 120-second limit and starve the probe (#1835 review).
for case_spec in "30:30:no" "500:60:yes" "0:60:yes" "abc:60:yes" "060:60:yes"; do
  requested="${case_spec%%:*}"; rest="${case_spec#*:}"; expected="${rest%%:*}"; notice="${rest#*:}"
  : >"$WORKDIR/probe.log"; : >"$WORKDIR/timeout.log"
  out="$(CLAUDE_CODE_REMOTE=true SETUP_MODE=install PROBE_LOG="$WORKDIR/probe.log" MERGEPATH_CLOUD_SETUP_TIMEOUT="$requested" PATH="$HBIN" bash "$HOOK")"; rc=$?
  noticed=no
  grep -q 'MERGEPATH_CLOUD_SETUP_TIMEOUT must be a whole number of seconds from 1 to 60' <<<"$out" && noticed=yes
  if [ "$rc" -eq 0 ] && [ "$(head -1 "$WORKDIR/timeout.log")" = "timeout $expected" ] \
     && [ "$(wc -l <"$WORKDIR/timeout.log" | tr -d ' ')" = "2" ] \
     && [ "$noticed" = "$notice" ] && grep -q '^probe ' "$WORKDIR/probe.log"; then
    pass "hook, MERGEPATH_CLOUD_SETUP_TIMEOUT=$requested: setup bound $expected, notice $notice, the probe still runs"
  else
    fail "hook setup bound $requested: rc=$rc out=$out timeout=$(cat "$WORKDIR/timeout.log")"
  fi
done
# With neither timeout executable setup is skipped and the probe keeps its
# existing unbounded fallback behavior.
: >"$WORKDIR/probe.log"
: >"$WORKDIR/timeout.log"
out="$(CLAUDE_CODE_REMOTE=true SETUP_MODE=install PROBE_LOG="$WORKDIR/probe.log" PATH="$HBIN_NT" bash "$HOOK")"; rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | sed -n '1p' | grep -x 'mergepath cloud session: tool setup skipped because timeout is not available to bound it; run bash scripts/cloud-setup.sh by hand.' >/dev/null \
   && ! printf '%s' "$out" | grep 'installed yq' >/dev/null \
   && printf '%s' "$out" | grep 'capability tier `author-writes`' >/dev/null \
   && ! grep -q 'setup ran' "$WORKDIR/probe.log" && grep -q '^probe ' "$WORKDIR/probe.log" \
   && [ ! -s "$WORKDIR/timeout.log" ]; then
  pass "hook, no timeout available: skips setup with a one-line notice, the probe still runs, the hook still exits 0"
else
  fail "hook no timeout: rc=$rc out=$out log=$(cat "$WORKDIR/probe.log")"
fi
# gtimeout-only hosts receive the same setup and probe bounds.
: >"$WORKDIR/probe.log"
: >"$WORKDIR/timeout.log"
out="$(CLAUDE_CODE_REMOTE=true SETUP_MODE=install PROBE_LOG="$WORKDIR/probe.log" PATH="$HBIN_GT" bash "$HOOK")"; rc=$?
if [ "$rc" -eq 0 ] && [ "$(head -1 "$WORKDIR/timeout.log")" = "gtimeout 60" ] \
   && [ "$(tail -1 "$WORKDIR/timeout.log")" = "gtimeout 90" ] && grep -q '^probe ' "$WORKDIR/probe.log"; then
  pass "hook, gtimeout-only host: bounds setup and probe"
else
  fail "hook gtimeout-only: rc=$rc out=$out timeout=$(cat "$WORKDIR/timeout.log")"
fi
# The timeout requested for the probe is limited by the elapsed setup budget.
# Virtual elapsed time is injected only into this copied hook at its single
# asserted pre-probe timing seam; production has no clock-injection setting.
HFIX_VIRTUAL="$WORKDIR/hook-repo-virtual-clock"
cp -R "$HFIX" "$HFIX_VIRTUAL"
HOOK_VIRTUAL="$HFIX_VIRTUAL/scripts/hooks/cloud-session-start.sh"
if [ "$(grep -Fxc 'probe_elapsed=$((SECONDS - hook_started))' "$HOOK_VIRTUAL")" = "1" ]; then
  sed 's/probe_elapsed=$((SECONDS - hook_started))/SECONDS=$((hook_started + ${TEST_VIRTUAL_ELAPSED:-0})); probe_elapsed=$((SECONDS - hook_started))/' \
    "$HOOK_VIRTUAL" >"$HOOK_VIRTUAL.tmp"
  mv "$HOOK_VIRTUAL.tmp" "$HOOK_VIRTUAL"
  : >"$WORKDIR/timeout.log"
  out="$(CLAUDE_CODE_REMOTE=true SETUP_MODE=install PROBE_LOG="$WORKDIR/probe.log" TEST_VIRTUAL_ELAPSED=60 PATH="$HBIN" bash "$HOOK_VIRTUAL")"; rc=$?
  if [ "$rc" -eq 0 ] && [ "$(head -1 "$WORKDIR/timeout.log")" = "timeout 60" ] \
     && awk -v line="$(tail -1 "$WORKDIR/timeout.log")" 'BEGIN { split(line, a, " "); exit !(a[1] == "timeout" && a[2] > 0 && a[2] <= 55) }'; then
    pass "hook, virtual full setup budget: probe receives at most 55 seconds and retains five seconds for the summary"
  else
    fail "hook virtual elapsed budget: rc=$rc out=$out timeout=$(cat "$WORKDIR/timeout.log")"
  fi
  : >"$WORKDIR/probe.log"
  : >"$WORKDIR/timeout.log"
  out="$(CLAUDE_CODE_REMOTE=true SETUP_MODE=install PROBE_LOG="$WORKDIR/probe.log" TEST_VIRTUAL_ELAPSED=120 PATH="$HBIN" bash "$HOOK_VIRTUAL")"; rc=$?
  if [ "$rc" -eq 0 ] && grep -q 'capabilities unknown' <<<"$out" \
     && [ "$(cat "$WORKDIR/timeout.log")" = "timeout 60" ] && ! grep -q '^probe ' "$WORKDIR/probe.log"; then
    pass "hook, exhausted budget: skips the probe and prints the existing unknown summary"
  else
    fail "hook exhausted budget: rc=$rc out=$out timeout=$(cat "$WORKDIR/timeout.log") probe=$(cat "$WORKDIR/probe.log")"
  fi

  for case_spec in "1:1:no" "030:30:no" "119:deadline:no" "0:90:yes" "120:90:yes" "999999999999999999999:90:yes" "0000000000000000001:90:yes" "abc:90:yes"; do
    requested="${case_spec%%:*}"; rest="${case_spec#*:}"; expected="${rest%%:*}"; notice="${rest#*:}"
    : >"$WORKDIR/timeout.log"
    out="$(CLAUDE_CODE_REMOTE=true SETUP_MODE=install PROBE_LOG="$WORKDIR/probe.log" TEST_VIRTUAL_ELAPSED=0 MERGEPATH_CLOUD_PROBE_TIMEOUT="$requested" PATH="$HBIN" bash "$HOOK_VIRTUAL")"; rc=$?
    noticed=no
    grep -q 'MERGEPATH_CLOUD_PROBE_TIMEOUT must be a positive whole number below 120' <<<"$out" && noticed=yes
    if [ "$expected" = deadline ]; then
      bound_ok=no
      if awk -v line="$(tail -1 "$WORKDIR/timeout.log")" 'BEGIN { split(line, a, " "); exit !(a[1] == "timeout" && a[2] > 0 && a[2] <= 115) }'; then
        bound_ok=yes
      fi
    else
      [ "$(tail -1 "$WORKDIR/timeout.log")" = "timeout $expected" ] && bound_ok=yes || bound_ok=no
    fi
    if [ "$rc" -eq 0 ] && [ "$bound_ok" = yes ] && [ "$noticed" = "$notice" ]; then
      pass "hook, MERGEPATH_CLOUD_PROBE_TIMEOUT=$requested: effective bound $expected, notice $notice"
    else
      fail "hook probe override $requested: rc=$rc out=$out timeout=$(cat "$WORKDIR/timeout.log")"
    fi
  done
else
  fail "hook test fixture: expected exactly one pre-probe elapsed-time seam for virtual-clock evidence"
fi
# Exercise a real deadline with an isolated sleeper and a test-only Perl alarm
# shim, so the regression does not depend on GNU coreutils being installed.
if ! command -v perl >/dev/null 2>&1; then
  fail "test prerequisite: perl is required to prove the sleeping-probe alarm path"
else
HFIX_SLEEP="$WORKDIR/hook-repo-sleeper"
mkdir -p "$HFIX_SLEEP/scripts/hooks"
cp "$HOOK" "$HFIX_SLEEP/scripts/hooks/cloud-session-start.sh"
cat >"$HFIX_SLEEP/scripts/agent-capability-probe.sh" <<'SLEEPER'
#!/usr/bin/env bash
printf 'started\n' >>"$PROBE_SLEEP_LOG"
exec sleep "${PROBE_SLEEP:-5}"
SLEEPER
chmod +x "$HFIX_SLEEP/scripts/agent-capability-probe.sh"
HBIN_REAL="$WORKDIR/hook-bin-real-timeout"
mkdir -p "$HBIN_REAL"
for tool in bash env sleep perl dirname jq sed paste tail head; do
  real="$(command -v "$tool" 2>/dev/null || true)"
  case "$real" in /*) ln -sf "$real" "$HBIN_REAL/$tool" ;; esac
done
cat >"$HBIN_REAL/timeout" <<'REALTIMEOUT'
#!/usr/bin/env bash
seconds="$1"; shift
printf '%s\n' "$seconds" "$@" >"$TEST_TIMEOUT_COMMAND"
exec perl -e '
  my $seconds = shift;
  my $pid = fork();
  die "fork failed" unless defined $pid;
  if (!$pid) {
    sleep($ENV{TEST_TIMEOUT_CHILD_START_DELAY} || 0);
    exec @ARGV or die "exec failed: $!";
  }
$SIG{ALRM} = sub {
  my $sent = kill "TERM", $pid;
  if ($sent) {
    waitpid($pid, 0);
    if (open my $fh, ">>", $ENV{TEST_TIMEOUT_MARKER}) {
      print $fh "124\n";
      close $fh;
    }
    exit 124;
  }
  waitpid($pid, 0);
  exit 127;
};
  alarm $seconds;
  waitpid($pid, 0);
  alarm 0;
  exit(($? >> 8) & 255);
' "$seconds" "$@"
REALTIMEOUT
chmod +x "$HBIN_REAL/timeout"
# A correct deadline may expire before the child gets scheduled. Verify the
# exact dispatched command rather than requiring the child's first write.
# The hook derives its root with `cd ... && pwd`, which collapses the double
# slash a trailing-slash TMPDIR (macOS) puts in WORKDIR; canonicalize the same
# way so the comparison stays byte-exact on every platform.
printf '1\n%s\n--quiet\n' "$(cd "$HFIX_SLEEP" && pwd)/scripts/agent-capability-probe.sh" >"$WORKDIR/expected-probe-command"
for startup_delay in 0 2; do
  rm -f "$WORKDIR/probe-start.log" "$WORKDIR/alarm.log" "$WORKDIR/probe-command.log"
  started="$(date +%s)"
  out="$(CLAUDE_CODE_REMOTE=true MERGEPATH_CLOUD_PROBE_TIMEOUT=1 PROBE_SLEEP_LOG="$WORKDIR/probe-start.log" TEST_TIMEOUT_MARKER="$WORKDIR/alarm.log" TEST_TIMEOUT_COMMAND="$WORKDIR/probe-command.log" TEST_TIMEOUT_CHILD_START_DELAY="$startup_delay" PATH="$HBIN_REAL" bash "$HFIX_SLEEP/scripts/hooks/cloud-session-start.sh")"; rc=$?
  elapsed=$(( $(date +%s) - started ))
  if [ "$rc" -eq 0 ] && [ "$elapsed" -le 3 ] \
     && cmp -s "$WORKDIR/probe-command.log" "$WORKDIR/expected-probe-command" \
     && [ "$(cat "$WORKDIR/alarm.log")" = "124" ] \
     && printf '%s' "$out" | grep 'capabilities unknown' >/dev/null \
     && { [ "$startup_delay" -eq 0 ] || [ ! -s "$WORKDIR/probe-start.log" ]; }; then
    pass "hook, sleeping probe (startup delay ${startup_delay}s): exact dispatch, alarm/124 and unknown summary within the shortened bound"
  else
    fail "hook sleeping probe: delay=$startup_delay rc=$rc elapsed=${elapsed}s command=$(cat "$WORKDIR/probe-command.log" 2>/dev/null) start=$(cat "$WORKDIR/probe-start.log" 2>/dev/null) alarm=$(cat "$WORKDIR/alarm.log" 2>/dev/null) out=$out"
  fi
done
fi
out="$(CLAUDE_CODE_REMOTE=true SETUP_MODE=fail PROBE_LOG="$WORKDIR/probe.log" PATH="$HBIN" bash "$HOOK")"; rc=$?
if [ "$rc" -eq 0 ] && grep -q 'tool setup failed or timed out (bash scripts/cloud-setup.sh to see why): cloud-setup: checksum mismatch for yq' <<<"$out" \
   && grep -q 'capability tier `author-writes`' <<<"$out"; then
  pass "hook, setup failure: reported in the summary, the probe still runs, the hook still exits 0"
else
  fail "hook setup failure: rc=$rc out=$out"
fi
out="$(CLAUDE_CODE_REMOTE=true PROBE_LOG="$WORKDIR/probe.log" PATH="$HBIN" bash "$HOOK")"; rc=$?
if [ "$rc" -eq 0 ] && ! grep -q 'cloud-setup\|tool setup' <<<"$out"; then
  pass "hook, setup with nothing to install: adds nothing to the summary"
else
  fail "hook setup noop: rc=$rc out=$out"
fi
rm -f "$HFIX/scripts/cloud-setup.sh"

rm -f "$HFIX/scripts/agent-capability-probe.sh"
out="$(CLAUDE_CODE_REMOTE=true bash "$HOOK")"; rc=$?
if [ "$rc" -eq 0 ] && grep -q "probe missing" <<<"$out"; then
  pass "hook, probe absent: exits 0 and says so"
else
  fail "hook probe absent: rc=$rc out=$out"
fi

# ---------------------------------------------------------------------------
# .claude/settings.json wires the hook the recipe describes. Hub only:
# .claude/settings.json is per-repo and not propagated, so a consumer wires the
# hook itself (the recipe says how); the sync marker identifies the hub.
# ---------------------------------------------------------------------------
if [ ! -f "$ROOT/scripts/sync-to-downstream.sh" ]; then
  pass ".claude/settings.json wiring: not asserted on a consumer checkout"
elif jq -e '.hooks.SessionStart[]?.hooks[]? | select(.type == "command") | .command | test("scripts/hooks/cloud-session-start\\.sh")' \
     "$ROOT/.claude/settings.json" >/dev/null 2>&1; then
  pass ".claude/settings.json wires the SessionStart hook"
else
  fail ".claude/settings.json does not wire scripts/hooks/cloud-session-start.sh as a SessionStart hook"
fi

# ---------------------------------------------------------------------------
# The recipe names only repository files that exist
# ---------------------------------------------------------------------------
# Paths the recipe names that do not exist under <root>. .claude/ is per-repo
# and not propagated: a consumer wires it itself, as the recipe says, so it is
# required only on the hub, which the sync marker identifies (Codex on #1552).
doc_missing_paths() { # <root>
  local root="$1" path missing=""
  for path in $(grep -oE '`(scripts|\.claude|\.codex|docs)/[A-Za-z0-9._/-]+`' "$root/docs/agents/cloud-environments.md" | tr -d '`' | sort -u); do
    case "$path" in .claude/*) [ -f "$root/scripts/sync-to-downstream.sh" ] || continue ;; esac
    [ -e "$root/$path" ] || missing="$missing $path"
  done
  printf '%s' "$missing"
}
DOC="$ROOT/docs/agents/cloud-environments.md"
if [ -r "$DOC" ]; then
  missing="$(doc_missing_paths "$ROOT")"
  if [ -z "$missing" ]; then
    pass "docs/agents/cloud-environments.md names only files that exist"
  else
    fail "docs/agents/cloud-environments.md names missing files:$missing"
  fi
else
  fail "docs/agents/cloud-environments.md is missing"
fi

# The same scan on a consumer checkout (no sync-to-downstream.sh, no
# .claude/settings.json, every propagated file present) reports nothing.
CONS="$WORKDIR/consumer"
mkdir -p "$CONS/docs/agents"
cp "$DOC" "$CONS/docs/agents/"
for path in $(grep -oE '`(scripts|\.codex)/[A-Za-z0-9._/-]+`' "$DOC" | tr -d '`' | sort -u); do
  mkdir -p "$CONS/$(dirname "$path")"; : >"$CONS/$path"
done
cmissing="$(doc_missing_paths "$CONS")"
if [ -z "$cmissing" ]; then
  pass "doc file scan on a consumer checkout: the per-repo .claude/settings.json is not required"
else
  fail "doc file scan on a consumer checkout reports:$cmissing"
fi

# ---------------------------------------------------------------------------
# scripts/cloud-setup.sh
# ---------------------------------------------------------------------------
SETUP="$ROOT/scripts/cloud-setup.sh"
VER=9.9.9
REL="$WORKDIR/release"
mkdir -p "$REL/gh_${VER}_linux_amd64/bin"
printf '#!/usr/bin/env bash\necho "gh version %s (fixture)"\n' "$VER" >"$REL/gh_${VER}_linux_amd64/bin/gh"
chmod +x "$REL/gh_${VER}_linux_amd64/bin/gh"
tar -czf "$REL/gh_${VER}_linux_amd64.tar.gz" -C "$REL" "gh_${VER}_linux_amd64"
if command -v sha256sum >/dev/null 2>&1; then
  sum="$(sha256sum "$REL/gh_${VER}_linux_amd64.tar.gz" | awk '{print $1}')"
else
  sum="$(shasum -a 256 "$REL/gh_${VER}_linux_amd64.tar.gz" | awk '{print $1}')"
fi

# A PATH with the real tools the script needs, minus gh, plus shims for
# uname (pretend Linux x86_64) and curl (serve from the fixture dir).
SBIN="$WORKDIR/setup-bin"
mkdir -p "$SBIN"
# gzip: GNU tar runs it from PATH for -z (bsdtar on macOS does not), so a
# hermetic PATH without it fails every unpack on Linux (Codex on #1552).
for tool in bash awk tar gzip mkdir cp chmod mktemp mv rm head sha256sum shasum perl sed tr cat env jq dirname cmp stat; do
  real="$(command -v "$tool" 2>/dev/null || true)"
  case "$real" in /*) ln -sf "$real" "$SBIN/$tool" ;; esac
done
cat >"$SBIN/uname" <<'U'
#!/usr/bin/env bash
case "$1" in -s) echo Linux ;; -m) echo x86_64 ;; *) echo Linux ;; esac
U
cat >"$SBIN/curl" <<C
#!/usr/bin/env bash
out=""; url=""
while [ "\$#" -gt 0 ]; do case "\$1" in -o) out="\$2"; shift 2 ;; http*) url="\$1"; shift ;; *) shift ;; esac; done
echo "\$url" >>"$WORKDIR/curl.log"
case "\$url" in
  *checksums.txt) exit 22 ;;  # never fetched: the expected hash is pinned, not downloaded
  *.tar.gz) f="$REL/\${url##*/}"; [ -f "\$f" ] || f="$REL/gh_${VER}_linux_amd64.tar.gz"; cp "\$f" "\$out" ;;
  */yq_linux_*) f="$REL/yq/\${url##*/}"; [ -f "\$f" ] || exit 22; cp "\$f" "\$out" ;;
  *) exit 22 ;;
esac
C
chmod +x "$SBIN/uname" "$SBIN/curl"
# The gh cases above and below are about gh: give them a mikefarah/yq v4 so
# the setup's yq step finds one present and stays out of their way.
printf '#!/usr/bin/env bash\necho "yq (https://github.com/mikefarah/yq/) version v4.53.6"\n' >"$SBIN/yq"
chmod +x "$SBIN/yq"
# yq release fixtures: a v4 binary for an unpinned version (the server below
# answers every version with it), and later a binary that runs but is not
# mikefarah/yq.
YQVER=v4.99.0
mkdir -p "$REL/yq"
printf '#!/usr/bin/env bash\necho "yq (https://github.com/mikefarah/yq/) version %s"\n' "$YQVER" >"$REL/yq/yq_linux_amd64"
yqsum="$(sha256sum "$REL/yq/yq_linux_amd64" 2>/dev/null | awk '{print $1}')"
[ -n "$yqsum" ] || yqsum="$(shasum -a 256 "$REL/yq/yq_linux_amd64" | awk '{print $1}')"

run_setup() { # <prefix> [env...]  (MERGEPATH_GH_VERSION defaults to the unpinned fixture version)
  local prefix="$1"; shift
  env -i HOME="$WORKDIR" PATH="$SBIN" MERGEPATH_GH_VERSION="$VER" MERGEPATH_TOOL_PREFIX="$prefix" "$@" \
    "$SBIN/bash" "$SETUP"
}
run_setup_dry() { # <prefix> [env...]
  local prefix="$1"; shift
  env -i HOME="$WORKDIR" PATH="$prefix/bin:$NOYQ" MERGEPATH_GH_VERSION="$VER" MERGEPATH_TOOL_PREFIX="$prefix" "$@" \
    "$SBIN/bash" "$SETUP" --dry-run
}

set +e
run_setup "$WORKDIR/p-good" MERGEPATH_GH_SHA256="$sum" PATH="$WORKDIR/p-good/bin:$SBIN" >/dev/null 2>"$WORKDIR/setup.err"; rc=$?
set -e
if [ "$rc" -eq 0 ] && [ -x "$WORKDIR/p-good/bin/gh" ] && grep -q "sha256 verified" "$WORKDIR/setup.err" \
   && grep -q "releases/download/v$VER/gh_${VER}_linux_amd64.tar.gz" "$WORKDIR/curl.log" \
   && ! grep -q checksums "$WORKDIR/curl.log"; then
  pass "setup, unpinned version with its SHA-256 supplied: installs, never downloads a checksums file"
else
  fail "setup install: rc=$rc err=$(cat "$WORKDIR/setup.err") curl=$(cat "$WORKDIR/curl.log")"
fi

for spec in "p-bad:0000000000000000000000000000000000000000000000000000000000000000:checksum mismatch" \
            "p-absent::no pinned SHA-256" "p-malformed:xyz:no pinned SHA-256"; do
  dir="${spec%%:*}"; rest="${spec#*:}"; hash="${rest%%:*}"; want="${rest#*:}"
  set +e
  if [ -n "$hash" ]; then run_setup "$WORKDIR/$dir" MERGEPATH_GH_SHA256="$hash" >/dev/null 2>"$WORKDIR/setup.err"
  else run_setup "$WORKDIR/$dir" >/dev/null 2>"$WORKDIR/setup.err"; fi
  rc=$?
  set -e
  if [ "$rc" -eq 1 ] && [ ! -e "$WORKDIR/$dir/bin/gh" ] && grep -q "$want" "$WORKDIR/setup.err"; then
    pass "setup, $dir: refuses ($want), installs nothing"
  else
    fail "setup $dir: rc=$rc err=$(cat "$WORKDIR/setup.err")"
  fi
done

# Every install step checks its own status: an unwritable prefix fails the
# install instead of logging "installed" (CodeRabbit and Codex on #1552).
# The prefix is a regular FILE, so `mkdir -p <prefix>/bin` fails for any
# user, root included (mode bits do not stop root; CodeRabbit and Codex on
# #1552).
: >"$WORKDIR/p-ro"
set +e
run_setup "$WORKDIR/p-ro" MERGEPATH_GH_SHA256="$sum" PATH="$WORKDIR/p-ro/bin:$SBIN" >/dev/null 2>"$WORKDIR/setup.err"; rc=$?
set -e
if [ "$rc" -eq 1 ] && [ -f "$WORKDIR/p-ro" ] && ! grep -q "installed gh" "$WORKDIR/setup.err" \
   && grep -q "could not create $WORKDIR/p-ro/bin" "$WORKDIR/setup.err"; then
  pass "setup, unwritable prefix: fails the install, never reports it installed"
else
  fail "setup unwritable prefix: rc=$rc err=$(cat "$WORKDIR/setup.err")"
fi

# Installed where nothing will find it: a prefix whose bin is not on PATH fails
# setup instead of exiting 0 with a note (Codex on #1552).
set +e
run_setup "$WORKDIR/p-offpath" MERGEPATH_GH_SHA256="$sum" >/dev/null 2>"$WORKDIR/setup.err"; rc=$?
set -e
if [ "$rc" -eq 1 ] && grep -q "is not on PATH, so later commands cannot find gh" "$WORKDIR/setup.err" \
   && grep -q "PARENT of a directory already on PATH" "$WORKDIR/setup.err"; then
  pass "setup, install directory off PATH: fails and names the PATH entry to add"
else
  fail "setup off-PATH: rc=$rc err=$(cat "$WORKDIR/setup.err")"
fi

# The default version's hash is pinned in the script: a tarball that does not
# match it (here the fixture, served for the real asset name) is refused.
set +e
run_setup "$WORKDIR/p-pinned" MERGEPATH_GH_VERSION=2.101.0 >/dev/null 2>"$WORKDIR/setup.err"; rc=$?
set -e
if [ "$rc" -eq 1 ] && [ ! -e "$WORKDIR/p-pinned/bin/gh" ] && grep -q "checksum mismatch" "$WORKDIR/setup.err" \
   && grep -q "expected 9bca2d1c16825f109907a23307628a2f0698fbf99662b73a5cf0b020293072b8" "$WORKDIR/setup.err"; then
  pass "setup, default version: verified against the hash pinned in the script, not a downloaded one"
else
  fail "setup pinned: rc=$rc err=$(cat "$WORKDIR/setup.err")"
fi

# Only no argument or --dry-run: a typo refuses before anything is fetched.
for bad in --dryrun "--dry-run extra" -n; do
  : >"$WORKDIR/curl.log"
  set +e
  # shellcheck disable=SC2086
  env -i HOME="$WORKDIR" PATH="$SBIN" MERGEPATH_GH_VERSION="$VER" MERGEPATH_TOOL_PREFIX="$WORKDIR/p-badarg" \
    "$SBIN/bash" "$SETUP" $bad >/dev/null 2>"$WORKDIR/setup.err"; rc=$?
  set -e
  if [ "$rc" -eq 2 ] && [ ! -s "$WORKDIR/curl.log" ] && [ ! -e "$WORKDIR/p-badarg/bin/gh" ] && grep -q "usage:" "$WORKDIR/setup.err"; then
    pass "setup, argument '$bad': refused (exit 2) before any download"
  else
    fail "setup argument '$bad': rc=$rc curl=$(cat "$WORKDIR/curl.log")"
  fi
done

# A PATH entry with a trailing slash still resolves the installed gh: the check
# is real command resolution, not a string match (Codex on #1552).
set +e
run_setup "$WORKDIR/p-slash" MERGEPATH_GH_SHA256="$sum" PATH="$WORKDIR/p-slash/bin/:$SBIN" >/dev/null 2>"$WORKDIR/setup.err"; rc=$?
set -e
if [ "$rc" -eq 0 ] && [ -x "$WORKDIR/p-slash/bin/gh" ]; then
  pass "setup, install directory on PATH with a trailing slash: accepted"
else
  fail "setup trailing-slash PATH: rc=$rc err=$(cat "$WORKDIR/setup.err")"
fi

# A literal ~/ prefix, as an environment setting passes it, is $HOME, not a
# directory named ~ under the current one (Codex on #1552).
mkdir -p "$WORKDIR/tilde-cwd"
set +e
# shellcheck disable=SC2088  # the unexpanded ~ is the input under test
( cd "$WORKDIR/tilde-cwd" && run_setup '~/p-tilde' MERGEPATH_GH_SHA256="$sum" PATH="$WORKDIR/p-tilde/bin:$SBIN" ) >/dev/null 2>"$WORKDIR/setup.err"; rc=$?
set -e
if [ "$rc" -eq 0 ] && [ -x "$WORKDIR/p-tilde/bin/gh" ] && [ ! -e "$WORKDIR/tilde-cwd/~" ]; then
  pass "setup, MERGEPATH_TOOL_PREFIX=~/...: expanded to \$HOME, not created under the current directory"
else
  fail "setup tilde prefix: rc=$rc err=$(cat "$WORKDIR/setup.err")"
fi

# A TMPDIR containing a quote is a path, never shell code: the install
# succeeds and its temporary directory is removed (Codex on #1552).
mkdir -p "$WORKDIR/it's tmp"
set +e
run_setup "$WORKDIR/p-quote" MERGEPATH_GH_SHA256="$sum" PATH="$WORKDIR/p-quote/bin:$SBIN" TMPDIR="$WORKDIR/it's tmp" >/dev/null 2>"$WORKDIR/setup.err"; rc=$?
set -e
if [ "$rc" -eq 0 ] && [ -x "$WORKDIR/p-quote/bin/gh" ] && [ -z "$(ls -A "$WORKDIR/it's tmp")" ]; then
  pass "setup, TMPDIR with a quote: installs, and the cleanup removes its temporary directory"
else
  fail "setup quoted TMPDIR: rc=$rc left=$(ls -A "$WORKDIR/it's tmp") err=$(cat "$WORKDIR/setup.err")"
fi

# A relative PATH entry resolves gh to a relative path; the same-file test
# still accepts the install (CodeRabbit on #1552).
mkdir -p "$WORKDIR/relroot"
set +e
( cd "$WORKDIR/relroot" && env -i HOME="$WORKDIR" PATH="tools/bin:$SBIN" MERGEPATH_GH_VERSION="$VER" \
    MERGEPATH_TOOL_PREFIX=tools MERGEPATH_GH_SHA256="$sum" "$SBIN/bash" "$SETUP" ) >/dev/null 2>"$WORKDIR/setup.err"; rc=$?
set -e
if [ "$rc" -eq 1 ] && grep -q "relative PATH entry" "$WORKDIR/setup.err"; then
  pass "setup, gh reachable only through a relative PATH entry: refused (it would not resolve from another directory)"
else
  fail "setup relative PATH: rc=$rc err=$(cat "$WORKDIR/setup.err")"
fi

# An installed binary that does not run (noexec mount, incompatible build)
# fails setup even though its executable bits are set (Codex on #1552).
BVER=8.8.8
mkdir -p "$REL/gh_${BVER}_linux_amd64/bin"
printf '#!/usr/bin/env bash\nexit 126\n' >"$REL/gh_${BVER}_linux_amd64/bin/gh"
chmod +x "$REL/gh_${BVER}_linux_amd64/bin/gh"
tar -czf "$REL/gh_${BVER}_linux_amd64.tar.gz" -C "$REL" "gh_${BVER}_linux_amd64"
if command -v sha256sum >/dev/null 2>&1; then bsum="$(sha256sum "$REL/gh_${BVER}_linux_amd64.tar.gz" | awk '{print $1}')"
else bsum="$(shasum -a 256 "$REL/gh_${BVER}_linux_amd64.tar.gz" | awk '{print $1}')"; fi
set +e
run_setup "$WORKDIR/p-norun" MERGEPATH_GH_VERSION="$BVER" MERGEPATH_GH_SHA256="$bsum" PATH="$WORKDIR/p-norun/bin:$SBIN" >/dev/null 2>"$WORKDIR/setup.err"; rc=$?
set -e
if [ "$rc" -eq 1 ] && grep -q "does not run (gh --version failed" "$WORKDIR/setup.err"; then
  pass "setup, installed binary that does not run: fails instead of reporting success"
else
  fail "setup unrunnable install: rc=$rc err=$(cat "$WORKDIR/setup.err")"
fi

# The shared operating rules (propagated) point every repo at the recipe.
if grep -q '\[Cloud Agent Environments\](cloud-environments.md)' "$ROOT/docs/agents/shared-operating-rules.md"; then
  pass "shared operating rules link the cloud recipe, so consumers can find it"
else
  fail "docs/agents/shared-operating-rules.md does not link cloud-environments.md"
fi

# A tool on PATH that does not run is not present: setup fails (Codex on #1552).
for tool in gh jq; do
  BROKE="$WORKDIR/broken-$tool"
  mkdir -p "$BROKE"
  printf '#!/usr/bin/env bash\nexit 126\n' >"$BROKE/$tool"
  chmod +x "$BROKE/$tool"
  [ "$tool" = gh ] || ln -sf "$WORKDIR/p-good/bin/gh" "$BROKE/gh"
  : >"$WORKDIR/curl.log"
  set +e
  run_setup "$WORKDIR/p-broken-$tool" PATH="$BROKE:$SBIN" >/dev/null 2>"$WORKDIR/setup.err"; rc=$?
  set -e
  if [ "$rc" -eq 1 ] && grep -q "$tool is on PATH .* but does not run" "$WORKDIR/setup.err"; then
    pass "setup, a $tool on PATH that does not run: fails instead of reporting it present"
  else
    fail "setup broken $tool: rc=$rc err=$(cat "$WORKDIR/setup.err")"
  fi
done

# A tool already on PATH that resolves only through a relative entry is
# refused, as an installed one is: a re-run must not accept what the install
# path refuses (Phase 4b on #1552, #1554).
for tool in gh jq; do
  RELP="$WORKDIR/relpresent-$tool"
  mkdir -p "$RELP/rbin"
  if [ "$tool" = gh ]; then
    ln -sf "$WORKDIR/p-good/bin/gh" "$RELP/rbin/gh"
    relpath="rbin:$SBIN"
  else
    ln -sf "$SBIN/jq" "$RELP/rbin/jq"
    relpath="rbin:$WORKDIR/p-good/bin:$SBIN"
  fi
  : >"$WORKDIR/curl.log"
  set +e
  ( cd "$RELP" && run_setup "$WORKDIR/p-relpresent-$tool" PATH="$relpath" ) >/dev/null 2>"$WORKDIR/setup.err"; rc=$?
  set -e
  if [ "$rc" -eq 1 ] && [ ! -s "$WORKDIR/curl.log" ] && grep -q "$tool resolves through a relative PATH entry" "$WORKDIR/setup.err"; then
    pass "setup, a present $tool reachable only through a relative PATH entry: refused, as an install there is"
  else
    fail "setup relative present $tool: rc=$rc err=$(cat "$WORKDIR/setup.err")"
  fi
done

# gh already present: nothing is downloaded.
ln -sf "$WORKDIR/p-good/bin/gh" "$SBIN/gh"
: >"$WORKDIR/curl.log"
set +e
run_setup "$WORKDIR/p-noop" >/dev/null 2>"$WORKDIR/setup.err"; rc=$?
set -e
if [ "$rc" -eq 0 ] && [ ! -s "$WORKDIR/curl.log" ] && grep -q "gh present" "$WORKDIR/setup.err"; then
  pass "setup, gh present: downloads nothing"
else
  fail "setup no-op: rc=$rc curl=$(cat "$WORKDIR/curl.log")"
fi

# ---------------------------------------------------------------------------
# yq: the guarded tooling reads YAML with mikefarah/yq v4. The Claude cloud
# image ships the Python jq wrapper under the same name, which rejects v4
# syntax, so setup installs the pinned mikefarah/yq ahead of it.
# ---------------------------------------------------------------------------
NOYQ="$WORKDIR/noyq-bin"
mkdir -p "$NOYQ"
for f in "$SBIN"/*; do [ "$(basename "$f")" = yq ] || ln -sf "$f" "$NOYQ/$(basename "$f")"; done
PYYQ="$WORKDIR/pyyq-bin"
mkdir -p "$PYYQ"
printf '#!/usr/bin/env bash\necho "yq 0.0.0"\n' >"$PYYQ/yq"
chmod +x "$PYYQ/yq"

# The release tag is validated before dry-run success. A checksum-shaped
# override cannot make an older, unprefixed or malformed tag look installable.
for spec in "y-dry-old:v4.52.0:v-prefixed v4 tag at least v4.53.6" "y-dry-invalid:v4.bad.0:v-prefixed v4 tag at least v4.53.6" "y-dry-unprefixed:4.54.1:v-prefixed v4 tag at least v4.53.6" "y-dry-leading-zero-major:v04.54.0:v-prefixed v4 tag at least v4.53.6" "y-dry-leading-zero-minor:v4.054.0:v-prefixed v4 tag at least v4.53.6" "y-dry-leading-zero-patch:v4.54.00:v-prefixed v4 tag at least v4.53.6" "y-dry-unsupported-major:v5.0.0:v-prefixed v4 tag at least v4.53.6"; do
  dir="${spec%%:*}"; rest="${spec#*:}"; version="${rest%%:*}"; want="${rest#*:}"
  : >"$WORKDIR/curl.log"
  set +e
  run_setup_dry "$WORKDIR/$dir" MERGEPATH_YQ_VERSION="$version" MERGEPATH_YQ_SHA256="$(printf 'a%.0s' {1..64})" >/dev/null 2>"$WORKDIR/setup.err"; rc=$?
  set -e
  if [ "$rc" -eq 1 ] && grep -q "$want" "$WORKDIR/setup.err" && [ ! -s "$WORKDIR/curl.log" ]; then
    pass "setup dry-run, yq $version: refuses before download"
  else
    fail "setup dry-run yq $version: rc=$rc err=$(cat "$WORKDIR/setup.err") curl=$(cat "$WORKDIR/curl.log")"
  fi
done

# Canonical v-prefixed release tags, including valid zero components, pass.
for version in v4.54.0 v4.54.1 v4.9223372036854775808.0; do
  : >"$WORKDIR/curl.log"
  set +e
  run_setup_dry "$WORKDIR/y-dry-tag-${version//./-}" MERGEPATH_YQ_VERSION="$version" MERGEPATH_YQ_SHA256="$(printf 'a%.0s' {1..64})" >/dev/null 2>"$WORKDIR/setup.err"; rc=$?
  set -e
  if [ "$rc" -eq 0 ] && grep -q "would install yq $version" "$WORKDIR/setup.err" && [ ! -s "$WORKDIR/curl.log" ]; then
    pass "setup dry-run, yq $version: accepts a valid v-prefixed stable release tag"
  else
    fail "setup dry-run yq $version: rc=$rc err=$(cat "$WORKDIR/setup.err") curl=$(cat "$WORKDIR/curl.log")"
  fi
done

: >"$WORKDIR/curl.log"
set +e
run_setup_dry "$WORKDIR/y-dry-default" >/dev/null 2>"$WORKDIR/setup.err"; rc=$?
set -e
if [ "$rc" -eq 0 ] && grep -q "would install yq v4.53.6" "$WORKDIR/setup.err" && [ ! -s "$WORKDIR/curl.log" ]; then
  pass "setup dry-run, default yq version: still plans the pinned v4.53.6 install without downloading"
else
  fail "setup default yq dry-run: rc=$rc err=$(cat "$WORKDIR/setup.err") curl=$(cat "$WORKDIR/curl.log")"
fi

: >"$WORKDIR/curl.log"
set +e
run_setup "$WORKDIR/y-absent" MERGEPATH_YQ_VERSION="$YQVER" MERGEPATH_YQ_SHA256="$yqsum" PATH="$WORKDIR/y-absent/bin:$NOYQ" >/dev/null 2>"$WORKDIR/setup.err"; rc=$?
set -e
if [ "$rc" -eq 0 ] && [ -x "$WORKDIR/y-absent/bin/yq" ] && grep -q "installed yq $YQVER" "$WORKDIR/setup.err" \
   && grep -q "mikefarah/yq/releases/download/$YQVER/yq_linux_amd64" "$WORKDIR/curl.log" && ! grep -q checksums "$WORKDIR/curl.log"; then
  pass "setup, yq absent: installs mikefarah/yq after verifying the supplied SHA-256, never downloads a checksums file"
else
  fail "setup yq absent: rc=$rc err=$(cat "$WORKDIR/setup.err") curl=$(cat "$WORKDIR/curl.log")"
fi

set +e
run_setup "$WORKDIR/y-py" MERGEPATH_YQ_VERSION="$YQVER" MERGEPATH_YQ_SHA256="$yqsum" PATH="$WORKDIR/y-py/bin:$PYYQ:$NOYQ" >/dev/null 2>"$WORKDIR/setup.err"; rc=$?
set -e
if [ "$rc" -eq 0 ] && grep -q "is not mikefarah/yq v4 (yq 0.0.0)" "$WORKDIR/setup.err" && [ -x "$WORKDIR/y-py/bin/yq" ]; then
  pass "setup, the Python yq on PATH: installs mikefarah/yq ahead of it"
else
  fail "setup python yq: rc=$rc err=$(cat "$WORKDIR/setup.err")"
fi

set +e
run_setup "$WORKDIR/y-shadow" MERGEPATH_YQ_VERSION="$YQVER" MERGEPATH_YQ_SHA256="$yqsum" PATH="$PYYQ:$WORKDIR/y-shadow/bin:$NOYQ" >/dev/null 2>"$WORKDIR/setup.err"; rc=$?
set -e
if [ "$rc" -eq 1 ] && grep -q "yq still resolves to $PYYQ/yq, ahead of" "$WORKDIR/setup.err"; then
  pass "setup, the Python yq earlier on PATH than the install: fails and names the shadowing entry"
else
  fail "setup shadowed yq: rc=$rc err=$(cat "$WORKDIR/setup.err")"
fi

# A mikefarah/yq v4 older than the checks need (v4.52.0)
# is not kept: setup installs the pinned one ahead of it. The minimum itself
# and a newer release, compared as numbers (v4.100.0 > v4.53.6), are kept and
# nothing is downloaded.
yq_stub_dir() { # <dir> <version>
  mkdir -p "$1"
  printf '#!/usr/bin/env bash\necho "yq (https://github.com/mikefarah/yq/) version %s"\n' "$2" >"$1/yq"
  chmod +x "$1/yq"
}
yq_stub_dir "$WORKDIR/yq-old" v4.52.0
: >"$WORKDIR/curl.log"
set +e
run_setup "$WORKDIR/y-old" MERGEPATH_YQ_VERSION="$YQVER" MERGEPATH_YQ_SHA256="$yqsum" PATH="$WORKDIR/y-old/bin:$WORKDIR/yq-old:$NOYQ" >/dev/null 2>"$WORKDIR/setup.err"; rc=$?
set -e
if [ "$rc" -eq 0 ] && grep -q "is older than mikefarah/yq v4.53.6, which the repository checks need (yq (https://github.com/mikefarah/yq/) version v4.52.0)" "$WORKDIR/setup.err" \
   && [ -x "$WORKDIR/y-old/bin/yq" ] && grep -q "installed yq $YQVER" "$WORKDIR/setup.err" \
   && grep -q "mikefarah/yq/releases/download/$YQVER/yq_linux_amd64" "$WORKDIR/curl.log"; then
  pass "setup, mikefarah/yq v4.52.0 on PATH: older than the minimum, so the pinned yq is installed ahead of it"
else
  fail "setup old yq: rc=$rc err=$(cat "$WORKDIR/setup.err") curl=$(cat "$WORKDIR/curl.log")"
fi
# A prerelease of the minimum (v4.53.6-rc1) is not the stable minimum: replaced (#1835 review).
yq_stub_dir "$WORKDIR/yq-rc" v4.53.6-rc1
: >"$WORKDIR/curl.log"
set +e
run_setup "$WORKDIR/y-rc" MERGEPATH_YQ_VERSION="$YQVER" MERGEPATH_YQ_SHA256="$yqsum" PATH="$WORKDIR/y-rc/bin:$WORKDIR/yq-rc:$NOYQ" >/dev/null 2>"$WORKDIR/setup.err"; rc=$?
set -e
if [ "$rc" -eq 0 ] && [ -x "$WORKDIR/y-rc/bin/yq" ] && grep -q "installed yq $YQVER" "$WORKDIR/setup.err" \
   && grep -q "mikefarah/yq/releases/download/$YQVER/yq_linux_amd64" "$WORKDIR/curl.log"; then
  pass "setup, mikefarah/yq v4.53.6-rc1 on PATH: a prerelease is not the stable minimum, so the pinned yq is installed ahead of it"
else
  fail "setup prerelease yq: rc=$rc err=$(cat "$WORKDIR/setup.err") curl=$(cat "$WORKDIR/curl.log")"
fi
for keep in v4.53.6 v4.100.0 v4.9223372036854775808.0; do
  yq_stub_dir "$WORKDIR/yq-keep-$keep" "$keep"
  : >"$WORKDIR/curl.log"
  set +e
  run_setup "$WORKDIR/y-keep-$keep" PATH="$WORKDIR/yq-keep-$keep:$NOYQ" >/dev/null 2>"$WORKDIR/setup.err"; rc=$?
  set -e
  if [ "$rc" -eq 0 ] && grep -q "yq present: yq (https://github.com/mikefarah/yq/) version $keep" "$WORKDIR/setup.err" \
     && [ ! -s "$WORKDIR/curl.log" ] && [ ! -e "$WORKDIR/y-keep-$keep/bin/yq" ]; then
    pass "setup, mikefarah/yq $keep on PATH: at least the minimum, kept, nothing downloaded"
  else
    fail "setup keep yq $keep: rc=$rc err=$(cat "$WORKDIR/setup.err") curl=$(cat "$WORKDIR/curl.log")"
  fi
done

set +e
run_setup "$WORKDIR/y-mismatch" PATH="$WORKDIR/y-mismatch/bin:$NOYQ" >/dev/null 2>"$WORKDIR/setup.err"; rc=$?
set -e
# Default version: the fixture server answers it with the v4.99.0 fixture, whose hash is not the pin.
if [ "$rc" -eq 1 ] && [ ! -e "$WORKDIR/y-mismatch/bin/yq" ] \
   && grep -q "checksum mismatch for yq v4.53.6 yq_linux_amd64 (expected c5f056448f973ae7d39b5401949648a78f2dc1947d6a8eb65be60d5c504b9385" "$WORKDIR/setup.err"; then
  pass "setup, default yq version: verified against the hash pinned in the script, not a downloaded one"
else
  fail "setup yq pinned mismatch: rc=$rc err=$(cat "$WORKDIR/setup.err")"
fi

# Exercise the default release's install path with a fake download and a
# checksum-tool boundary stub. The stub reports the official pinned digest so
# the test reaches binary validation; these fixture bytes are not a copy of the
# official release and this does not claim to verify that release's contents.
printf '#!/usr/bin/env bash\necho "yq (https://github.com/mikefarah/yq/) version v4.53.6"\n' >"$REL/yq/yq_linux_amd64"
DEFAULT_YQ_FIXTURE="$WORKDIR/default-yq-fixture"
cp "$REL/yq/yq_linux_amd64" "$DEFAULT_YQ_FIXTURE"
DEFAULT_SUM_BIN="$WORKDIR/default-sum-bin"
mkdir -p "$DEFAULT_SUM_BIN"
for f in "$SBIN"/*; do case "$(basename "$f")" in sha256sum|yq) ;; *) ln -sf "$f" "$DEFAULT_SUM_BIN/$(basename "$f")" ;; esac; done
cat >"$DEFAULT_SUM_BIN/sha256sum" <<'SUM'
#!/usr/bin/env bash
printf '%s  %s\n' c5f056448f973ae7d39b5401949648a78f2dc1947d6a8eb65be60d5c504b9385 "$1"
printf '%s  %s\n' c5f056448f973ae7d39b5401949648a78f2dc1947d6a8eb65be60d5c504b9385 "$1" >>"$CHECKSUM_LOG"
SUM
chmod +x "$DEFAULT_SUM_BIN/sha256sum"
: >"$WORKDIR/default-checksum.log"
: >"$WORKDIR/curl.log"
set +e
run_setup "$WORKDIR/y-default-install" CHECKSUM_LOG="$WORKDIR/default-checksum.log" PATH="$DEFAULT_SUM_BIN:$WORKDIR/y-default-install/bin:$NOYQ" >/dev/null 2>"$WORKDIR/setup.err"; rc=$?
set -e
installed_mode="$(stat -c %a "$WORKDIR/y-default-install/bin/yq" 2>/dev/null || stat -f %Lp "$WORKDIR/y-default-install/bin/yq" 2>/dev/null || true)"
if [ "$rc" -eq 0 ] && [ -x "$WORKDIR/y-default-install/bin/yq" ] \
   && [ "$installed_mode" = 755 ] \
   && cmp -s "$DEFAULT_YQ_FIXTURE" "$WORKDIR/y-default-install/bin/yq" \
   && "$WORKDIR/y-default-install/bin/yq" --version | grep -q 'version v4.53.6' \
   && grep -q 'releases/download/v4.53.6/yq_linux_amd64' "$WORKDIR/curl.log" \
   && grep -q 'c5f056448f973ae7d39b5401949648a78f2dc1947d6a8eb65be60d5c504b9385' "$WORKDIR/default-checksum.log"; then
  pass "setup, default yq v4.53.6: installs fixture bytes through the checksum stub with mode 755, expected URL and version"
else
  fail "setup default yq install: rc=$rc err=$(cat "$WORKDIR/setup.err") curl=$(cat "$WORKDIR/curl.log") checksum=$(cat "$WORKDIR/default-checksum.log")"
fi

# A checksum-verified older mikefarah/yq binary must be rejected before
# replacing an existing prefix binary. The release tag itself is valid and
# above minimum, so this exercises validation of the downloaded artifact.
printf '#!/usr/bin/env bash\necho "yq (https://github.com/mikefarah/yq/) version v4.52.0"\n' >"$REL/yq/yq_linux_amd64"
oldsum="$(sha256sum "$REL/yq/yq_linux_amd64" 2>/dev/null | awk '{print $1}')"
[ -n "$oldsum" ] || oldsum="$(shasum -a 256 "$REL/yq/yq_linux_amd64" | awk '{print $1}')"
mkdir -p "$WORKDIR/y-oldinstall/bin"
printf 'existing yq must survive\n' >"$WORKDIR/y-oldinstall/bin/yq"
set +e
run_setup "$WORKDIR/y-oldinstall" MERGEPATH_YQ_VERSION="$YQVER" MERGEPATH_YQ_SHA256="$oldsum" PATH="$WORKDIR/y-oldinstall/bin:$NOYQ" >/dev/null 2>"$WORKDIR/setup.err"; rc=$?
set -e
if [ "$rc" -eq 1 ] && grep -q "verified download for yq $YQVER does not run as mikefarah/yq v4 at v4.53.6 or later" "$WORKDIR/setup.err" \
   && ! grep -q "installed yq" "$WORKDIR/setup.err" \
   && [ "$(cat "$WORKDIR/y-oldinstall/bin/yq")" = "existing yq must survive" ]; then
  pass "setup, a valid release tag with mikefarah/yq v4.52.0: refuses before replacing the existing prefix binary"
else
  fail "setup yq old install: rc=$rc err=$(cat "$WORKDIR/setup.err")"
fi

printf '#!/usr/bin/env bash\necho "yq 0.0.0"\n' >"$REL/yq/yq_linux_amd64"
badsum="$(sha256sum "$REL/yq/yq_linux_amd64" 2>/dev/null | awk '{print $1}')"
[ -n "$badsum" ] || badsum="$(shasum -a 256 "$REL/yq/yq_linux_amd64" | awk '{print $1}')"
set +e
run_setup "$WORKDIR/y-notv4" MERGEPATH_YQ_VERSION="$YQVER" MERGEPATH_YQ_SHA256="$badsum" PATH="$WORKDIR/y-notv4/bin:$NOYQ" >/dev/null 2>"$WORKDIR/setup.err"; rc=$?
set -e
if [ "$rc" -eq 1 ] && grep -q "does not run as mikefarah/yq v4" "$WORKDIR/setup.err"; then
  pass "setup, a verified download that is not mikefarah/yq v4: fails instead of reporting success"
else
  fail "setup yq not v4: rc=$rc err=$(cat "$WORKDIR/setup.err")"
fi

# #2754 / #2772: validation runs where the binary will run. The fixture models
# a noexec filesystem hermetically: it refuses to run (status 126, as exec
# does) when its own path is under YQ_FIXTURE_NOEXEC. Staging files are
# `.yq-stage.*` in the prefix's bin directory and must never outlive a run.
cat >"$REL/yq/yq_linux_amd64" <<'NOEXEC_FIXTURE'
#!/usr/bin/env bash
case "$0" in "${YQ_FIXTURE_NOEXEC:-/nonexistent-2754}"/*) echo "$0: Permission denied" >&2; exit 126 ;; esac
echo "yq (https://github.com/mikefarah/yq/) version v4.99.0"
NOEXEC_FIXTURE
nxsum="$(sha256sum "$REL/yq/yq_linux_amd64" 2>/dev/null | awk '{print $1}')"
[ -n "$nxsum" ] || nxsum="$(shasum -a 256 "$REL/yq/yq_linux_amd64" | awk '{print $1}')"
no_stage() { ! ls -A "$1/bin" 2>/dev/null | grep -q '^\.yq-stage\.'; }

mkdir -p "$WORKDIR/noexec-tmp" "$WORKDIR/y-noexec-tmp/bin"
printf 'existing yq replaced only after validation\n' >"$WORKDIR/y-noexec-tmp/bin/yq"
set +e
run_setup "$WORKDIR/y-noexec-tmp" MERGEPATH_YQ_VERSION="$YQVER" MERGEPATH_YQ_SHA256="$nxsum" \
  TMPDIR="$WORKDIR/noexec-tmp" YQ_FIXTURE_NOEXEC="$WORKDIR/noexec-tmp" \
  PATH="$WORKDIR/y-noexec-tmp/bin:$NOYQ" >/dev/null 2>"$WORKDIR/setup.err"; rc=$?
set -e
if [ "$rc" -eq 0 ] && grep -q "installed yq $YQVER" "$WORKDIR/setup.err" \
   && cmp -s "$REL/yq/yq_linux_amd64" "$WORKDIR/y-noexec-tmp/bin/yq" \
   && no_stage "$WORKDIR/y-noexec-tmp" && [ -z "$(ls -A "$WORKDIR/noexec-tmp")" ]; then
  pass "setup, noexec TMPDIR with an executable prefix: validates the staged yq in the prefix and installs it"
else
  fail "setup noexec TMPDIR: rc=$rc err=$(cat "$WORKDIR/setup.err") bin=$(ls -A "$WORKDIR/y-noexec-tmp/bin")"
fi

# The ordinary case still installs, and leaves no staging file.
set +e
run_setup "$WORKDIR/y-exec-tmp" MERGEPATH_YQ_VERSION="$YQVER" MERGEPATH_YQ_SHA256="$nxsum" \
  PATH="$WORKDIR/y-exec-tmp/bin:$NOYQ" >/dev/null 2>"$WORKDIR/setup.err"; rc=$?
set -e
if [ "$rc" -eq 0 ] && cmp -s "$REL/yq/yq_linux_amd64" "$WORKDIR/y-exec-tmp/bin/yq" && no_stage "$WORKDIR/y-exec-tmp"; then
  pass "setup, executable TMPDIR: installs from the prefix staging file and leaves none behind"
else
  fail "setup exec TMPDIR: rc=$rc err=$(cat "$WORKDIR/setup.err") bin=$(ls -A "$WORKDIR/y-exec-tmp/bin")"
fi

# A non-executable destination still fails closed, keeping the prior binary.
mkdir -p "$WORKDIR/y-noexec-dest/bin"
printf 'existing yq must survive a noexec prefix\n' >"$WORKDIR/y-noexec-dest/bin/yq"
set +e
run_setup "$WORKDIR/y-noexec-dest" MERGEPATH_YQ_VERSION="$YQVER" MERGEPATH_YQ_SHA256="$nxsum" \
  YQ_FIXTURE_NOEXEC="$WORKDIR/y-noexec-dest/bin" \
  PATH="$WORKDIR/y-noexec-dest/bin:$NOYQ" >/dev/null 2>"$WORKDIR/setup.err"; rc=$?
set -e
if [ "$rc" -eq 1 ] && grep -q "does not run as mikefarah/yq v4" "$WORKDIR/setup.err" \
   && ! grep -q "installed yq" "$WORKDIR/setup.err" \
   && [ "$(cat "$WORKDIR/y-noexec-dest/bin/yq")" = "existing yq must survive a noexec prefix" ] \
   && no_stage "$WORKDIR/y-noexec-dest"; then
  pass "setup, non-executable prefix: fails closed, keeps the prior yq, removes the staging file"
else
  fail "setup noexec prefix: rc=$rc err=$(cat "$WORKDIR/setup.err") bin=$(ls -A "$WORKDIR/y-noexec-dest/bin")"
fi

# A bad checksum never stages anything and keeps the prior binary.
mkdir -p "$WORKDIR/y-badsum/bin"
printf 'existing yq must survive a bad checksum\n' >"$WORKDIR/y-badsum/bin/yq"
set +e
run_setup "$WORKDIR/y-badsum" MERGEPATH_YQ_VERSION="$YQVER" MERGEPATH_YQ_SHA256="$(printf '0%.0s' $(seq 64))" \
  PATH="$WORKDIR/y-badsum/bin:$NOYQ" >/dev/null 2>"$WORKDIR/setup.err"; rc=$?
set -e
if [ "$rc" -eq 1 ] && grep -q "checksum mismatch for yq $YQVER" "$WORKDIR/setup.err" \
   && [ "$(cat "$WORKDIR/y-badsum/bin/yq")" = "existing yq must survive a bad checksum" ] \
   && no_stage "$WORKDIR/y-badsum"; then
  pass "setup, bad yq checksum: keeps the prior yq and stages nothing"
else
  fail "setup yq bad checksum: rc=$rc err=$(cat "$WORKDIR/setup.err") bin=$(ls -A "$WORKDIR/y-badsum/bin")"
fi

# The earlier unsuitable-binary cases left no staging file either.
for d in y-oldinstall y-notv4; do
  if no_stage "$WORKDIR/$d"; then
    pass "setup, $d: the refused download left no staging file in the prefix"
  else
    fail "setup $d: staging file left behind: $(ls -A "$WORKDIR/$d/bin")"
  fi
done

echo
echo "test_cloud_environment: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
