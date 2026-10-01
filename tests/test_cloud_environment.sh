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
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q 'capability tier `author-writes`' \
   && printf '%s' "$out" | grep -q -- '- push-multi-branch: no, documented (proxy ceiling: hand this step to a local session or CI)' \
   && printf '%s' "$out" | grep -q -- '- reviewer-writes: no, no-verified-token (fix the credential, tools or setup, then re-run' \
   && printf '%s' "$out" | grep -q -- '- graphql: no, viewer query returned 500 (fix the credential, tools or setup' \
   && printf '%s' "$out" | grep -q -- '- cross-repo: no, GET repos/x/y returned 403 (fix the credential, tools or setup' \
   && printf '%s' "$out" | grep -q -- '- author-writes: yes, a$' \
   && ! printf '%s' "$out" | grep -q -- 'may be transient' \
   && grep -q -- '--quiet' "$WORKDIR/probe.log"; then
  pass "hook, cloud session: classifies each no from the probe's basis and reason (a documented denial is a ceiling; a GraphQL 500 or a bare cross-repo 403 is fix-first)"
else
  fail "hook cloud: rc=$rc out=$out"
fi

# A run with a transient failure (a rate-limited 403 among them) re-probes its
# measured "no" answers before calling them a setup problem or a ceiling.
out="$(CLAUDE_CODE_REMOTE=true PROBE_TRANSIENT=true PROBE_LOG="$WORKDIR/probe.log" bash "$HOOK")"; rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q -- '- cross-repo: no, GET repos/x/y returned 403 (may be transient: re-run' \
   && printf '%s' "$out" | grep -q -- '- graphql: no, viewer query returned 500 (may be transient' \
   && printf '%s' "$out" | grep -q -- '- push-multi-branch: no, documented (proxy ceiling' \
   && ! printf '%s' "$out" | grep -q -- 'fix the credential, tools or setup, then'; then
  pass "hook, transient run: a measured no is marked may-be-transient, a documented ceiling stays a ceiling"
else
  fail "hook transient: rc=$rc out=$out"
fi

# A fine-grained token is unverifiable, not broken: no re-probe can grant it
# and the wrappers accept it, so it is not sent round the fix-and-re-probe
# loop (Codex on #1552).
out="$(CLAUDE_CODE_REMOTE=true PROBE_RW_BASIS=unverifiable PROBE_LOG="$WORKDIR/probe.log" bash "$HOOK")"; rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q -- "- reviewer-writes: no, no-verified-token (not provable: GitHub does not expose this token type's permissions; the wrappers still verify" \
   && ! printf '%s' "$out" | grep -q -- '- reviewer-writes: .*fix the credential' \
   && ! printf '%s' "$out" | grep -qi -- 'any other no'; then
  pass "hook, unverifiable token: reported as not provable, not as a setup problem to fix and re-probe"
else
  fail "hook unverifiable: rc=$rc out=$out"
fi

out="$(CLAUDE_CODE_REMOTE=true PROBE_MODE=fail PROBE_LOG="$WORKDIR/probe.log" bash "$HOOK")"; rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q "capabilities unknown"; then
  pass "hook, probe failure: still exits 0 and says the capabilities are unknown"
else
  fail "hook probe failure: rc=$rc out=$out"
fi

rm -f "$HFIX/scripts/agent-capability-probe.sh"
out="$(CLAUDE_CODE_REMOTE=true bash "$HOOK")"; rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q "probe missing"; then
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
for tool in bash awk tar gzip mkdir cp chmod mktemp rm head sha256sum shasum perl sed tr cat env jq dirname; do
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
  *) exit 22 ;;
esac
C
chmod +x "$SBIN/uname" "$SBIN/curl"

run_setup() { # <prefix> [env...]  (MERGEPATH_GH_VERSION defaults to the unpinned fixture version)
  local prefix="$1"; shift
  env -i HOME="$WORKDIR" PATH="$SBIN" MERGEPATH_GH_VERSION="$VER" MERGEPATH_TOOL_PREFIX="$prefix" "$@" \
    "$SBIN/bash" "$SETUP"
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

echo
echo "test_cloud_environment: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
