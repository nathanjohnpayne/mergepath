#!/usr/bin/env bash
# Unit tests for scripts/hooks/gh-pr-guard.sh under the #411
# wrapper-mandatory token contract.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK="$ROOT/scripts/hooks/gh-pr-guard.sh"

[[ -x "$HOOK" ]] || { echo "missing or non-executable $HOOK" >&2; exit 1; }

if ! command -v python3 >/dev/null 2>&1; then
  echo "SKIP: python3 not available" >&2
  exit 0
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "SKIP: jq not available" >&2
  exit 0
fi

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/gh-pr-guard-test.XXXXXX")"
trap 'rm -rf "$WORKDIR"' EXIT

PASS=0
FAIL=0
pass() { echo "PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $*" >&2; FAIL=$((FAIL + 1)); }

STUB_DIR="$WORKDIR/stub-bin"
mkdir -p "$STUB_DIR"
cat >"$STUB_DIR/gh" <<'STUB'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "config get")
    echo "${STUB_ACTIVE_USER:-nathanpayne-claude}"
    exit 0
    ;;
  "pr view")
    json_fields=""
    for ((i=1; i<=$#; i++)); do
      if [ "${!i}" = "--json" ]; then
        next=$((i+1))
        json_fields="${!next}"
        break
      fi
    done
    case "$json_fields" in
      *body*)
        printf '%s\n' "${STUB_PR_BODY:-}"
        printf '"additions": %s\n' "${STUB_PR_ADDITIONS:-0}"
        printf '"deletions": %s\n' "${STUB_PR_DELETIONS:-0}"
        printf '"head": "%s"\n' "${STUB_PR_HEAD:-feature/some-branch}"
        printf '"author": "%s"\n' "${STUB_PR_AUTHOR:-nathanjohnpayne}"
        exit 0
        ;;
      *)
        echo "${STUB_MERGE_STATE:-CLEAN}"
        echo "${STUB_MERGEABLE:-MERGEABLE}"
        echo "${STUB_ROLLUP_NONGREEN:-0}"
        if [ -n "${STUB_LABELS:-}" ]; then
          echo "$STUB_LABELS" | tr ';' '\n'
        fi
        exit 0
        ;;
    esac
    ;;
  *)
    exit 0
    ;;
esac
STUB
chmod +x "$STUB_DIR/gh"

run_hook() {
  local cmd="$1"
  local merge_state="${2:-CLEAN}"
  local labels="${3:-}"
  local expected_reviewer="${4:-nathanpayne-claude}"
  local pr_body="${5:-}"
  local additions="${6:-0}"
  local deletions="${7:-0}"
  local pr_head="${8:-feature/some-branch}"
  local pr_author="${9:-nathanjohnpayne}"
  local payload
  payload=$(jq -n --arg c "$cmd" '{tool_input: {command: $c}}')
  PATH="$STUB_DIR:$PATH" \
  STUB_MERGE_STATE="$merge_state" \
  STUB_MERGEABLE="${STUB_MERGEABLE:-MERGEABLE}" \
  STUB_ROLLUP_NONGREEN="${STUB_ROLLUP_NONGREEN:-0}" \
  STUB_LABELS="$labels" \
  STUB_PR_BODY="$pr_body" \
  STUB_PR_ADDITIONS="$additions" \
  STUB_PR_DELETIONS="$deletions" \
  STUB_PR_HEAD="$pr_head" \
  STUB_PR_AUTHOR="$pr_author" \
  GH_PR_GUARD_EXPECTED_REVIEWER="$expected_reviewer" \
    bash "$HOOK" <<<"$payload"
}

assert_rc_contains() {
  local label="$1" expected_rc="$2" needle="$3"; shift 3
  local out rc
  set +e
  out=$(run_hook "$@" 2>&1)
  rc=$?
  set -e
  if [ "$rc" -ne "$expected_rc" ]; then
    fail "$label: rc=$rc expected $expected_rc; output: $out"
  elif [ -n "$needle" ] && ! echo "$out" | grep -qi "$needle"; then
    fail "$label: missing '$needle'; output: $out"
  else
    pass "$label"
  fi
}

assert_rc_contains "direct pr create blocked" 2 "token-verifying wrapper" \
  'gh pr create --title "t" --body "Authoring-Agent: claude

## Self-Review
- ok"'

assert_rc_contains "inline-token pr create blocked" 2 "not hook-verifiable" \
  'GH_TOKEN=author-token gh pr create --title "t" --body "Authoring-Agent: claude

## Self-Review
- ok"'

assert_rc_contains "wrapper substring spoof still blocked" 2 "token-verifying wrapper" \
  'echo scripts/gh-as-author.sh && gh pr create --title "t" --body "Authoring-Agent: claude

## Self-Review
- ok"'

# #466: a path-qualified gh (e.g. /usr/bin/gh) must NOT bypass the guard.
# Before the fix the quick-exit grep only matched bare `gh`, so a
# path-qualified write skipped the hook entirely (exit 0).
assert_rc_contains "path-qualified gh pr create blocked (#466)" 2 "token-verifying wrapper" \
  '/usr/bin/gh pr create --title "t" --body "Authoring-Agent: claude

## Self-Review
- ok"'

assert_rc_contains "path-qualified gh pr merge blocked (#466)" 2 "" \
  '/usr/bin/gh pr merge 123 --squash --delete-branch'

# #466 r2: a QUOTED path-qualified (or bare) gh must not bypass either.
# The closing quote glued to `gh` previously slipped past the quick-exit
# grep boundary (verified live by the nathanpayne-codex review).
assert_rc_contains "quoted path-qualified gh pr merge blocked (#466 r2)" 2 "" \
  "'/usr/bin/gh' pr merge 123 --squash --delete-branch"

assert_rc_contains "quoted bare gh pr merge blocked (#466 r2)" 2 "" \
  "'gh' pr merge 5 --squash"

assert_rc_contains "wrapper state does not cross separator" 2 "token-verifying wrapper" \
  'scripts/gh-as-author.sh -- echo ok ; gh pr create --title "t" --body "Authoring-Agent: claude

## Self-Review
- ok"'

assert_rc_contains "non-canonical author wrapper path blocked" 2 "non-canonical" \
  '/tmp/gh-as-author.sh -- gh pr create --title "t" --body "Authoring-Agent: claude

## Self-Review
- ok"'

assert_rc_contains "bare reviewer wrapper command blocked" 2 "non-canonical" \
  'gh-as-reviewer.sh -- gh pr review 123 --comment --body "review"'

assert_rc_contains "wrapper non-guarded then bare guarded compound blocked" 2 "#348" \
  'scripts/gh-as-author.sh -- gh pr view 123 && gh pr merge 123 --squash'

assert_rc_contains "author wrapper pr create valid body allowed" 0 "" \
  'scripts/gh-as-author.sh -- gh pr create --title "t" --body "Authoring-Agent: claude

## Self-Review
- ok"'

assert_rc_contains "author wrapper pr create missing body blocked" 2 "Self-Review" \
  'scripts/gh-as-author.sh -- gh pr create --title "t" --body "Authoring-Agent: claude"'

assert_rc_contains "reviewer wrapper pr create blocked" 2 "author token" \
  'scripts/gh-as-reviewer.sh -- gh pr create --title "t" --body "Authoring-Agent: claude

## Self-Review
- ok"'

assert_rc_contains "author wrapper pr merge clean allowed" 0 "" \
  'scripts/gh-as-author.sh -- gh pr merge 123 --squash' "CLEAN" ""

assert_rc_contains "direct pr merge blocked" 2 "token-verifying wrapper" \
  'gh pr merge 123 --squash' "CLEAN" ""

assert_rc_contains "author wrapper pr merge blocked state" 2 "mergeStateStatus is BLOCKED" \
  'scripts/gh-as-author.sh -- gh pr merge 123 --squash' "BLOCKED" ""

# #547: UNSTABLE is a non-passing commit status. It is allowed ONLY when
# the check ROLLUP confirms every check name's LATEST run is green
# (ROLLUP_NONGREEN=0 — a stale failure superseded by a later pass) AND
# mergeable=MERGEABLE. A genuinely-red check (rollup non-green > 0) is NOT
# trusted as benign just because mergeable is MERGEABLE: mergeable is
# conflict-only, so trusting it would reopen the #170/#171 red-CI bypass.
assert_rc_contains "UNSTABLE + green rollup + MERGEABLE allowed (#547)" 0 "" \
  'scripts/gh-as-author.sh -- gh pr merge 123 --squash' "UNSTABLE" ""
STUB_ROLLUP_NONGREEN=1 \
  assert_rc_contains "UNSTABLE + a red latest check fails closed (#547)" 2 "latest run is not green" \
  'scripts/gh-as-author.sh -- gh pr merge 123 --squash' "UNSTABLE" ""
STUB_MERGEABLE=UNKNOWN \
  assert_rc_contains "UNSTABLE + green rollup but mergeable=UNKNOWN fails closed (#547)" 2 "fail-closed" \
  'scripts/gh-as-author.sh -- gh pr merge 123 --squash' "UNSTABLE" ""
STUB_ROLLUP_NONGREEN=1 \
  assert_rc_contains "UNSTABLE + red rollup + break-glass allowed (#547)" 0 "BREAK-GLASS" \
  'BREAK_GLASS_MERGE_STATE=1 scripts/gh-as-author.sh -- gh pr merge 123 --squash' "UNSTABLE" ""
# DIRTY (merge conflict) stays blocked regardless — the UNSTABLE allowance
# must not leak to the other non-CLEAN states.
assert_rc_contains "DIRTY stays blocked (#547 split)" 2 "mergeStateStatus is DIRTY" \
  'scripts/gh-as-author.sh -- gh pr merge 123 --squash' "DIRTY" ""

assert_rc_contains "author wrapper pr merge human-hold blocks" 2 "human-hold" \
  'CODEX_CLEARED=1 BREAK_GLASS_ADMIN=1 BREAK_GLASS_MERGE_STATE=1 scripts/gh-as-author.sh -- gh pr merge 123 --admin --squash' "DIRTY" "human-hold"

assert_rc_contains "direct pr comment blocked" 2 "token-verifying wrapper" \
  'gh pr comment 123 --body "ping"'

assert_rc_contains "reviewer wrapper pr comment allowed" 0 "" \
  'scripts/gh-as-reviewer.sh -- gh pr comment 123 --body "ping"'

assert_rc_contains "reviewer wrapper identity mismatch blocked" 2 "not expected reviewer" \
  'GH_AS_REVIEWER_IDENTITY=nathanpayne-codex scripts/gh-as-reviewer.sh -- gh pr comment 123 --body "ping"'

assert_rc_contains "author wrapper normal pr comment blocked" 2 "reviewer token" \
  'scripts/gh-as-author.sh -- gh pr comment 123 --body "ping"'

assert_rc_contains "author wrapper codex trigger allowed" 0 "" \
  'scripts/gh-as-author.sh -- gh pr comment 123 --body "@codex review"'

assert_rc_contains "author wrapper codex trigger echo spoof blocked" 2 "reviewer token" \
  'echo "@codex review" && scripts/gh-as-author.sh -- gh pr comment 123 --body "ping"'

assert_rc_contains "reviewer wrapper pr review comment allowed" 0 "" \
  'scripts/gh-as-reviewer.sh -- gh pr review 123 --comment --body "review"'

assert_rc_contains "direct issue comment blocked" 2 "token-verifying wrapper" \
  'gh issue comment 7 --body "thanks"'

assert_rc_contains "reviewer wrapper issue comment allowed" 0 "" \
  'scripts/gh-as-reviewer.sh -- gh issue comment 7 --body "thanks"'

assert_rc_contains "author wrapper issue comment blocked" 2 "reviewer token" \
  'scripts/gh-as-author.sh -- gh issue comment 7 --body "thanks"'

assert_rc_contains "direct pr edit blocked" 2 "token-verifying wrapper" \
  'gh pr edit 123 --title "new"'

assert_rc_contains "author wrapper pr edit allowed" 0 "" \
  'scripts/gh-as-author.sh -- gh pr edit 123 --title "new"'

assert_rc_contains "reviewer wrapper pr edit blocked" 2 "author token" \
  'scripts/gh-as-reviewer.sh -- gh pr edit 123 --title "new"'

assert_rc_contains "self-approve over-threshold blocked from wrapper identity" 2 "self-approve detected" \
  'scripts/gh-as-reviewer.sh -- gh pr review 123 --approve --body "lgtm"' "CLEAN" "" "nathanpayne-claude" "Authoring-Agent: claude" "5000" "0"

assert_rc_contains "cross-agent approve allowed" 0 "" \
  'GH_AS_REVIEWER_IDENTITY=nathanpayne-codex scripts/gh-as-reviewer.sh -- gh pr review 123 --approve --body "lgtm"' "CLEAN" "" "nathanpayne-codex" "Authoring-Agent: claude" "5000" "0"

ORIG_DIR="$(pwd)"
mkdir -p "$WORKDIR/repo-with-policy/.github"
cat >"$WORKDIR/repo-with-policy/.github/review-policy.yml" <<'YML'
external_review_threshold: 500
YML
cd "$WORKDIR/repo-with-policy"
assert_rc_contains "same-agent under-threshold approve allowed" 0 "" \
  'scripts/gh-as-reviewer.sh -- gh pr review 123 --approve --body "small"' "CLEAN" "" "nathanpayne-claude" "Authoring-Agent: claude" "10" "5"
cd "$ORIG_DIR"

# --- #533 item 2: propagation lane bypass honors propagation_prs.enabled
# A mergepath-sync/* PR authored by the author identity skips the
# same-agent self-approve guard even when over-threshold — but ONLY when
# the lane is enabled. DEFAULT-ON: an absent propagation_prs block counts
# as enabled; an explicit `enabled: false` must re-impose the guard, and
# per #540 any other present non-`true` value (e.g. `yes`, a typo) also
# re-imposes it (fail-closed exact-match).
mkdir -p "$WORKDIR/repo-lane-default/.github"
cat >"$WORKDIR/repo-lane-default/.github/review-policy.yml" <<'YML'
external_review_threshold: 300
YML
cd "$WORKDIR/repo-lane-default"
assert_rc_contains "lane bypass allowed (default-on absent block)" 0 "" \
  'scripts/gh-as-reviewer.sh -- gh pr review 123 --approve --body "sync"' "CLEAN" "" "nathanpayne-claude" "Authoring-Agent: claude" "5000" "0" "mergepath-sync/abc123" "nathanjohnpayne"
cd "$ORIG_DIR"

mkdir -p "$WORKDIR/repo-lane-off/.github"
cat >"$WORKDIR/repo-lane-off/.github/review-policy.yml" <<'YML'
external_review_threshold: 300
propagation_prs:
  enabled: false
YML
cd "$WORKDIR/repo-lane-off"
assert_rc_contains "lane bypass denied when propagation_prs.enabled false (#533)" 2 "self-approve detected" \
  'scripts/gh-as-reviewer.sh -- gh pr review 123 --approve --body "sync"' "CLEAN" "" "nathanpayne-claude" "Authoring-Agent: claude" "5000" "0" "mergepath-sync/abc123" "nathanjohnpayne"
cd "$ORIG_DIR"

mkdir -p "$WORKDIR/repo-lane-typo/.github"
cat >"$WORKDIR/repo-lane-typo/.github/review-policy.yml" <<'YML'
external_review_threshold: 300
propagation_prs:
  enabled: yes
YML
cd "$WORKDIR/repo-lane-typo"
assert_rc_contains "lane bypass denied when propagation_prs.enabled is a present non-true value (#540)" 2 "self-approve detected" \
  'scripts/gh-as-reviewer.sh -- gh pr review 123 --approve --body "sync"' "CLEAN" "" "nathanpayne-claude" "Authoring-Agent: claude" "5000" "0" "mergepath-sync/abc123" "nathanjohnpayne"
cd "$ORIG_DIR"

# #540 P2 (4a review): a trailing comment on the propagation_prs header
# (propagation_prs: # opt-out) must still be parsed, so enabled:false
# disables the lane. The prior exact-EOL header match missed it and the
# lane failed open.
mkdir -p "$WORKDIR/repo-lane-comment/.github"
cat >"$WORKDIR/repo-lane-comment/.github/review-policy.yml" <<'YML'
external_review_threshold: 300
propagation_prs:  # this repo opted out of the self-approve lane
  enabled: false
YML
cd "$WORKDIR/repo-lane-comment"
assert_rc_contains "lane bypass denied when propagation_prs header has a trailing comment (#540 P2)" 2 "self-approve detected" \
  'scripts/gh-as-reviewer.sh -- gh pr review 123 --approve --body "sync"' "CLEAN" "" "nathanpayne-claude" "Authoring-Agent: claude" "5000" "0" "mergepath-sync/abc123" "nathanjohnpayne"
cd "$ORIG_DIR"

assert_rc_contains "compound direct guarded write blocked" 2 "#348" \
  'gh issue close 7 && gh pr merge --admin 123'

# --- #533 item 1: eval / sh -c / bash -c admin-merge bypass -----------
# Each of these returned rc=0 (BYPASS) before the python tokenizer
# re-tokenized eval/shell -c payloads: shlex kept the inner command as
# one opaque token, so SAW_GH stayed 0 and the guard exited early. They
# must now surface the inner guarded gh write and BLOCK (rc=2).
assert_rc_contains "eval-wrapped gh pr merge --admin blocked (#533)" 2 "token-verifying wrapper" \
  'eval "gh pr merge 123 --admin"'

assert_rc_contains "eval split-arg gh pr merge --admin blocked (#533)" 2 "token-verifying wrapper" \
  'eval "gh pr" "merge 123 --admin"'

assert_rc_contains "bash -lc gh pr merge --admin blocked (#533)" 2 "token-verifying wrapper" \
  'bash -lc "gh pr merge 123 --admin"'

assert_rc_contains "bash -c gh pr merge --admin blocked (#533)" 2 "token-verifying wrapper" \
  'bash -c "gh pr merge 123 --admin"'

assert_rc_contains "sh -c gh pr merge --admin blocked (#533)" 2 "token-verifying wrapper" \
  'sh -c "gh pr merge 123 --admin"'

# Recursion: a shell wrapper nesting eval (bash -c -> eval -> gh) must
# expand all the way down.
assert_rc_contains "bash -c eval gh pr merge blocked (#533 recursion)" 2 "token-verifying wrapper" \
  'bash -c "eval gh pr merge 123 --admin"'

# A guarded write hidden inside a shell -c compound must still trip #348.
assert_rc_contains "shell -c compound guarded write blocked (#533/#348)" 2 "#348" \
  'sh -c "gh issue close 1 && gh pr merge 123 --admin"'

# No false positives: a wrapped command with no command-position gh
# write stays allowed (the walk re-establishes command position on the
# expanded stream, so a gh token that is mere data is not a write).
assert_rc_contains "eval echo allowed (no gh)" 0 "" \
  'eval "echo hello world"'

assert_rc_contains "bash -c echo of gh text allowed (gh not in cmd position)" 0 "" \
  'bash -c "echo gh pr merge --admin"'

# --- #540 Phase-4b: nathanpayne-codex found two more guard bypasses ----
# (1) bash --noprofile --norc -c "<payload>": the option scan matched any
#     flag containing a 'c', so --norc consumed the real -c and dropped the
#     command string. Long (--) options are now skipped so the real -c is
#     found.
assert_rc_contains "bash --norc -c gh pr merge --admin blocked (#540)" 2 "" \
  'bash --noprofile --norc -c "gh pr merge 1 --admin"'
assert_rc_contains "bash --rcfile -c still finds the real -c (#540)" 2 "" \
  'bash --rcfile /dev/null -c "gh pr merge 1 --admin"'

# (3) <prefix> [opts] bash -c "<payload>": a prefix command with its OWN
#     options (env -i, sudo -u USER, nice -n N) must consume those options
#     so the wrapped bash -c is still found. Previously a prefix option
#     fell through and flipped command-position off, hiding the bash -c
#     gh-write (#540 P1, 4a review).
assert_rc_contains "env -i bash -c gh pr merge blocked (#540 P1)" 2 "" \
  'env -i bash -c "gh pr merge 1 --admin"'
assert_rc_contains "sudo -u USER bash -c gh pr merge blocked (#540 P1)" 2 "" \
  'sudo -u nobody bash -c "gh pr merge 1 --admin"'
assert_rc_contains "nice -n N bash -c gh pr merge blocked (#540 P1)" 2 "" \
  'nice -n 5 bash -c "gh pr merge 1 --admin"'
# sudo -n is a no-value FLAG (unlike nice -n), so bash stays in command
# position and is still expanded (per-prefix value-option table).
assert_rc_contains "sudo -n bash -c gh pr merge blocked (#540 P1)" 2 "" \
  'sudo -n bash -c "gh pr merge 1 --admin"'
# An env NAME=VALUE assignment before the shell is skipped, not mistaken
# for the wrapped command.
assert_rc_contains "env VAR=x bash -c gh pr merge blocked (#540 P1)" 2 "" \
  'env FOO=bar bash -c "gh pr merge 1 --admin"'
# Control: a prefix wrapping a benign echo of gh text stays allowed (gh is
# not in command position inside the echo).
assert_rc_contains "sudo -u x bash -c echo gh text allowed (#540 P1)" 0 "" \
  'sudo -u nobody bash -c "echo gh pr merge --admin"'

# (2) a command substitution with a quoted ) desynced shlex quote tracking
#     and glued a top-level "; gh ..." into a data token. The python
#     preprocessor is now command-substitution aware: it pads unquoted
#     separators and surfaces commands inside $(...) / backticks.
assert_rc_contains "cmd-sub quoted-paren hides top-level gh merge blocked (#540)" 2 "" \
  'echo "$(printf %s ")")"; gh pr merge 1 --admin'

# Related command-substitution / subshell vectors the same fix closes: a
# gh write that EXECUTES inside $(...), a backtick, a subshell, or an
# assignment substitution is surfaced and blocked (also required the
# fast-path pre-filter boundary to count ( / $ / ; / backtick, not only
# whitespace, so the hook does not early-exit before tokenizing).
assert_rc_contains "gh write inside command substitution blocked (#540)" 2 "" \
  'echo "$(gh pr merge 1 --admin)"'
assert_rc_contains "gh write in subshell blocked (#540)" 2 "" \
  '(gh pr merge 1 --admin)'
assert_rc_contains "gh write in assignment substitution blocked (#540)" 2 "" \
  'X=$(gh pr merge 1 --admin)'
assert_rc_contains "gh write in backtick substitution blocked (#540)" 2 "" \
  'echo `gh pr merge 1 --admin`'

# Control: a READ inside a substitution is not a guarded write -> allowed.
assert_rc_contains "gh read inside command substitution allowed (#540)" 0 "" \
  'echo "$(gh pr view 1)"'

# --- author-wrapper identity pin (#438) -------------------------------

assert_rc_contains "author wrapper inline non-author identity blocked" 2 "author identity" \
  'GH_AS_AUTHOR_IDENTITY=nathanpayne-codex scripts/gh-as-author.sh -- gh pr merge 123 --squash' "CLEAN" ""

assert_rc_contains "author wrapper inline matching author identity allowed" 0 "" \
  'GH_AS_AUTHOR_IDENTITY=nathanjohnpayne scripts/gh-as-author.sh -- gh pr merge 123 --squash' "CLEAN" ""

assert_rc_contains "author wrapper inline non-author identity blocked on pr create" 2 "author identity" \
  'GH_AS_AUTHOR_IDENTITY=nathanpayne-cursor scripts/gh-as-author.sh -- gh pr create --title "t" --body "Authoring-Agent: claude

## Self-Review
- ok"'

assert_rc_contains "author wrapper inline non-author identity blocked on codex trigger" 2 "author identity" \
  'GH_AS_AUTHOR_IDENTITY=nathanpayne-codex scripts/gh-as-author.sh -- gh pr comment 123 --body "@codex review"'

# A stale inline assignment scoped to an EARLIER command segment must
# not leak into the author byline guard — the shell would not pass it
# to the wrapper (Codex P2 on PR #442).
assert_rc_contains "stale inline author identity from earlier segment does not block" 0 "" \
  'GH_AS_AUTHOR_IDENTITY=nathanpayne-codex echo ok ; scripts/gh-as-author.sh -- gh pr merge 123 --squash' "CLEAN" ""

# A standalone assignment (no command in its segment) persists as a
# shell variable, and IF the name carries the export attribute in the
# calling shell it ALSO reaches the wrapper (Codex P1 on PR #442 r4).
# The hook cannot observe the export attribute, so a standalone
# non-author value must fail closed even though it might be inert.
assert_rc_contains "standalone non-author identity assignment fails closed" 2 "author identity" \
  'GH_AS_AUTHOR_IDENTITY=nathanpayne-codex ; scripts/gh-as-author.sh -- gh pr merge 123 --squash' "CLEAN" ""

# ...but a standalone assignment of the EXPECTED author is fine either
# way (exported: wrapper gets the expected value; unexported: wrapper
# default is the same value).
assert_rc_contains "standalone matching author identity assignment allowed" 0 "" \
  'GH_AS_AUTHOR_IDENTITY=nathanjohnpayne ; scripts/gh-as-author.sh -- gh pr merge 123 --squash' "CLEAN" ""

# `export VAR=x ; wrapper` is DEFINITELY effective — the assignment is
# an argument of the export command, not a bare prefix, and reaches
# every later process (Codex P1 on PR #442 r11).
assert_rc_contains "exported-via-export-command non-author identity blocked" 2 "author identity" \
  'export GH_AS_AUTHOR_IDENTITY=nathanpayne-codex ; scripts/gh-as-author.sh -- gh pr merge 123 --squash' "CLEAN" ""

assert_rc_contains "exported-via-export-command matching author identity allowed" 0 "" \
  'export GH_AS_AUTHOR_IDENTITY=nathanjohnpayne && scripts/gh-as-author.sh -- gh pr merge 123 --squash' "CLEAN" ""

assert_rc_contains "exported-via-export-command non-reviewer identity blocked" 2 "expected reviewer" \
  'export GH_AS_REVIEWER_IDENTITY=nathanpayne-codex ; scripts/gh-as-reviewer.sh -- gh pr comment 123 --body "ping"' "CLEAN" ""

# Prefix-assignment BEFORE the export command in the same segment
# (`VAR=x export VAR`) persists AND exports (Codex P1 on PR #442 r12).
assert_rc_contains "prefix-then-export non-author identity blocked" 2 "author identity" \
  'GH_AS_AUTHOR_IDENTITY=nathanpayne-codex export GH_AS_AUTHOR_IDENTITY ; scripts/gh-as-author.sh -- gh pr comment 123 --body "@codex review"' "CLEAN" ""

assert_rc_contains "prefix-then-export matching author identity allowed" 0 "" \
  'GH_AS_AUTHOR_IDENTITY=nathanjohnpayne export GH_AS_AUTHOR_IDENTITY ; scripts/gh-as-author.sh -- gh pr merge 123 --squash' "CLEAN" ""

# declare -x is export-equivalent (Codex P1 r12 family, preempted).
assert_rc_contains "declare -x non-author identity blocked" 2 "author identity" \
  'declare -x GH_AS_AUTHOR_IDENTITY=nathanpayne-codex ; scripts/gh-as-author.sh -- gh pr merge 123 --squash' "CLEAN" ""

# env-prefix on the wrapper command is a definitive same-segment prefix.
assert_rc_contains "env-prefixed non-author identity blocked" 2 "author identity" \
  'env GH_AS_AUTHOR_IDENTITY=nathanpayne-codex scripts/gh-as-author.sh -- gh pr merge 123 --squash' "CLEAN" ""

# eval'd assignments persist like bare standalones (preempted, r14
# family): possibly-effective, so a mismatch fails closed.
assert_rc_contains "eval'd non-author identity assignment fails closed" 2 "author identity" \
  'eval GH_AS_AUTHOR_IDENTITY=nathanpayne-codex ; scripts/gh-as-author.sh -- gh pr merge 123 --squash' "CLEAN" ""

# readonly -x exports too (Codex P1 on PR #442 r14, hook-verified).
assert_rc_contains "readonly -x non-author identity blocked" 2 "author identity" \
  'readonly -x GH_AS_AUTHOR_IDENTITY=nathanpayne-codex ; scripts/gh-as-author.sh -- gh pr create --title "t" --body "Authoring-Agent: claude

## Self-Review
- ok"' "CLEAN" ""

# The custom-author shape from the r3 finding: standalone assignment of
# the CUSTOM identity must NOT satisfy the guard — the wrapper would
# actually verify its stock default.
mkdir -p "$WORKDIR/repo-custom-author-standalone/.github"
cat >"$WORKDIR/repo-custom-author-standalone/.github/review-policy.yml" <<'YML'
author_identity: custom-owner
YML
cd "$WORKDIR/repo-custom-author-standalone"
assert_rc_contains "standalone custom-identity assignment does not mask the wrapper default" 2 "author identity" \
  'GH_AS_AUTHOR_IDENTITY=custom-owner && scripts/gh-as-author.sh -- gh pr merge 123 --squash' "CLEAN" ""
cd "$ORIG_DIR"

# Exported (non-inline) GH_AS_AUTHOR_IDENTITY must be caught too — the
# wrapper reads its environment, so the hook must read the same.
set +e
out=$(GH_AS_AUTHOR_IDENTITY=nathanpayne-codex run_hook 'scripts/gh-as-author.sh -- gh pr merge 123 --squash' "CLEAN" "" 2>&1)
rc=$?
set -e
if [ "$rc" -eq 2 ] && echo "$out" | grep -qi "author identity"; then
  pass "author wrapper exported non-author identity blocked"
else
  fail "author wrapper exported non-author identity blocked: rc=$rc; output: $out"
fi

# The expected author defaults from review-policy.yml author_identity
# when GH_PR_GUARD_EXPECTED_AUTHOR is unset (Codex P2 on PR #442 r2) —
# custom-author repos need no hook-specific variable.
mkdir -p "$WORKDIR/repo-custom-author/.github"
cat >"$WORKDIR/repo-custom-author/.github/review-policy.yml" <<'YML'
author_identity: custom-owner
YML
cd "$WORKDIR/repo-custom-author"
assert_rc_contains "author identity from review-policy.yml allows matching wrapper identity" 0 "" \
  'GH_AS_AUTHOR_IDENTITY=custom-owner scripts/gh-as-author.sh -- gh pr merge 123 --squash' "CLEAN" ""
assert_rc_contains "author identity from review-policy.yml blocks the stock default" 2 "author identity" \
  'scripts/gh-as-author.sh -- gh pr merge 123 --squash' "CLEAN" ""
cd "$ORIG_DIR"

# An EMPTY inline override resets the wrapper to its hardcoded default
# (Codex P1 on PR #442 r15): in a custom-author repo that is a
# wrong-byline reset and must fail closed, even when the hook's own
# environment carries the correct custom identity.
mkdir -p "$WORKDIR/repo-custom-author-empty/.github"
cat >"$WORKDIR/repo-custom-author-empty/.github/review-policy.yml" <<'YML'
author_identity: custom-owner
YML
cd "$WORKDIR/repo-custom-author-empty"
set +e
out=$(GH_AS_AUTHOR_IDENTITY=custom-owner run_hook 'GH_AS_AUTHOR_IDENTITY= scripts/gh-as-author.sh -- gh pr merge 123 --squash' "CLEAN" "" 2>&1)
rc=$?
set -e
if [ "$rc" -eq 2 ] && echo "$out" | grep -qi "author identity"; then
  pass "empty inline author override fails closed in custom-author repo"
else
  fail "empty inline author override fails closed in custom-author repo: rc=$rc; output: $out"
fi
cd "$ORIG_DIR"

# env -u / --unset / -i remove the identity from the WRAPPER's
# environment — the r15 empty-override semantics (Codex P2 r17).
cd "$WORKDIR/repo-custom-author-empty"
set +e
out=$(GH_AS_AUTHOR_IDENTITY=custom-owner run_hook 'env -u GH_AS_AUTHOR_IDENTITY scripts/gh-as-author.sh -- gh pr merge 123 --squash' "CLEAN" "" 2>&1)
rc=$?
set -e
if [ "$rc" -eq 2 ] && echo "$out" | grep -qi "author identity"; then
  pass "env -u identity unset fails closed in custom-author repo"
else
  fail "env -u identity unset fails closed in custom-author repo: rc=$rc; output: $out"
fi
set +e
out=$(GH_AS_AUTHOR_IDENTITY=custom-owner run_hook 'env --unset=GH_AS_AUTHOR_IDENTITY scripts/gh-as-author.sh -- gh pr merge 123 --squash' "CLEAN" "" 2>&1)
rc=$?
set -e
if [ "$rc" -eq 2 ] && echo "$out" | grep -qi "author identity"; then
  pass "env --unset= identity fails closed in custom-author repo"
else
  fail "env --unset= identity fails closed in custom-author repo: rc=$rc; output: $out"
fi
cd "$ORIG_DIR"

assert_rc_contains "env -u identity unset allowed in default repo" 0 "" \
  'env -u GH_AS_AUTHOR_IDENTITY scripts/gh-as-author.sh -- gh pr merge 123 --squash' "CLEAN" ""

# Space-separated long form: `env --unset NAME` (Codex P1 r18) — the
# value flag must be consumed or the walk loses the wrapper entirely
# and skips ALL checks.
cd "$WORKDIR/repo-custom-author-empty"
set +e
out=$(GH_AS_AUTHOR_IDENTITY=custom-owner run_hook 'env --unset GH_AS_AUTHOR_IDENTITY scripts/gh-as-author.sh -- gh pr merge 123 --squash' "CLEAN" "" 2>&1)
rc=$?
set -e
if [ "$rc" -eq 2 ] && echo "$out" | grep -qi "author identity"; then
  pass "env --unset NAME (space form) fails closed in custom-author repo"
else
  fail "env --unset NAME (space form) fails closed in custom-author repo: rc=$rc; output: $out"
fi
cd "$ORIG_DIR"

# ...and in a default repo the walk must still SEE the wrapper and
# evaluate the merge-state checks (BLOCKED state proves the walk
# reached the merge guard rather than bailing at the unset arg).
assert_rc_contains "env --unset NAME still reaches merge-state checks" 2 "mergeStateStatus is BLOCKED" \
  'env --unset GH_AS_AUTHOR_IDENTITY scripts/gh-as-author.sh -- gh pr merge 123 --squash' "BLOCKED" ""

# Compact `env -uNAME` form (#451) — flag and name attached, no `=`.
# prefix_flag_takes_value matches only the bare `-u`, so this token would
# fall through as a boolean flag unless the case block models it
# explicitly. Same r15 empty-override semantics as `env -u NAME`.
cd "$WORKDIR/repo-custom-author-empty"
set +e
out=$(GH_AS_AUTHOR_IDENTITY=custom-owner run_hook 'env -uGH_AS_AUTHOR_IDENTITY scripts/gh-as-author.sh -- gh pr merge 123 --squash' "CLEAN" "" 2>&1)
rc=$?
set -e
if [ "$rc" -eq 2 ] && echo "$out" | grep -qi "author identity"; then
  pass "#451: env -uNAME (compact) author unset fails closed in custom-author repo"
else
  fail "#451: env -uNAME (compact) author unset fails closed in custom-author repo: rc=$rc; output: $out"
fi
cd "$ORIG_DIR"

# ...and in a default repo the compact form must still reach the merge-state
# checks (BLOCKED proves the walk didn't bail at the unset arg and skip checks).
assert_rc_contains "#451: env -uNAME (compact) author unset reaches merge-state checks in default repo" 2 "mergeStateStatus is BLOCKED" \
  'env -uGH_AS_AUTHOR_IDENTITY scripts/gh-as-author.sh -- gh pr merge 123 --squash' "BLOCKED" ""

# Reviewer analog: the compact unset falls the wrapper back to its default
# reviewer; with a different expected reviewer that must fail closed.
assert_rc_contains "#451: env -uNAME (compact) reviewer unset fails closed vs different expected reviewer" 2 "not expected reviewer" \
  'env -uGH_AS_REVIEWER_IDENTITY scripts/gh-as-reviewer.sh -- gh pr comment 123 --body "ping"' "CLEAN" "" "nathanpayne-codex"

# The unset BUILTIN persists past separators (preempted, r17 family).
cd "$WORKDIR/repo-custom-author-empty"
set +e
out=$(GH_AS_AUTHOR_IDENTITY=custom-owner run_hook 'unset GH_AS_AUTHOR_IDENTITY ; scripts/gh-as-author.sh -- gh pr merge 123 --squash' "CLEAN" "" 2>&1)
rc=$?
set -e
if [ "$rc" -eq 2 ] && echo "$out" | grep -qi "author identity"; then
  pass "unset builtin identity removal fails closed in custom-author repo"
else
  fail "unset builtin identity removal fails closed in custom-author repo: rc=$rc; output: $out"
fi
cd "$ORIG_DIR"

assert_rc_contains "unset builtin identity removal allowed in default repo" 0 "" \
  'unset GH_AS_AUTHOR_IDENTITY ; scripts/gh-as-author.sh -- gh pr merge 123 --squash' "CLEAN" ""

# In a DEFAULT repo an empty override is a no-op (wrapper default ==
# expected) and must not block.
assert_rc_contains "empty inline author override allowed in default repo" 0 "" \
  'GH_AS_AUTHOR_IDENTITY= scripts/gh-as-author.sh -- gh pr merge 123 --squash' "CLEAN" ""

# Subdirectory invocation: the policy is found by upward walk (r21).
mkdir -p "$WORKDIR/repo-custom-author/subdir"
cd "$WORKDIR/repo-custom-author/subdir"
assert_rc_contains "author identity policy found from a subdirectory" 2 "author identity" \
  'scripts/gh-as-author.sh -- gh pr merge 123 --squash' "CLEAN" ""
cd "$ORIG_DIR"

# Quoted author_identity is valid YAML — double AND single quotes must
# be stripped before comparison (Codex P2s on PR #442 r6/r7).
mkdir -p "$WORKDIR/repo-quoted-author/.github"
cat >"$WORKDIR/repo-quoted-author/.github/review-policy.yml" <<'YML'
author_identity: "custom-owner"
YML
cd "$WORKDIR/repo-quoted-author"
assert_rc_contains "double-quoted author_identity allows matching wrapper identity" 0 "" \
  'GH_AS_AUTHOR_IDENTITY=custom-owner scripts/gh-as-author.sh -- gh pr merge 123 --squash' "CLEAN" ""
cd "$ORIG_DIR"

mkdir -p "$WORKDIR/repo-squoted-author/.github"
cat >"$WORKDIR/repo-squoted-author/.github/review-policy.yml" <<'YML'
author_identity: 'custom-owner'
YML
cd "$WORKDIR/repo-squoted-author"
assert_rc_contains "single-quoted author_identity allows matching wrapper identity" 0 "" \
  'GH_AS_AUTHOR_IDENTITY=custom-owner scripts/gh-as-author.sh -- gh pr merge 123 --squash' "CLEAN" ""
cd "$ORIG_DIR"

# Custom expected author: identity must match the override...
set +e
out=$(GH_PR_GUARD_EXPECTED_AUTHOR=custom-owner run_hook 'GH_AS_AUTHOR_IDENTITY=custom-owner scripts/gh-as-author.sh -- gh pr merge 123 --squash' "CLEAN" "" 2>&1)
rc=$?
set -e
if [ "$rc" -eq 0 ]; then
  pass "author wrapper custom expected author with matching identity allowed"
else
  fail "author wrapper custom expected author with matching identity allowed: rc=$rc; output: $out"
fi

# ...and an UNSET identity fails closed under a custom expected author,
# because the wrapper would verify its stock default (nathanjohnpayne),
# not the override.
set +e
out=$(GH_PR_GUARD_EXPECTED_AUTHOR=custom-owner run_hook 'scripts/gh-as-author.sh -- gh pr merge 123 --squash' "CLEAN" "" 2>&1)
rc=$?
set -e
if [ "$rc" -eq 2 ] && echo "$out" | grep -qi "author identity"; then
  pass "author wrapper unset identity under custom expected author fails closed"
else
  fail "author wrapper unset identity under custom expected author fails closed: rc=$rc; output: $out"
fi

# --- #546: parser-completeness hardening (gap 1 + gap 2) --------------
# Gap 1 — a blessed wrapper must not hide a shell-c payload. Before #546 the
# wrappers were not prefix-like in expand_wrappers, so a "<wrapper> -- bash
# -c <gh write>" left the inner write opaque and it ran under the verified
# token WITHOUT the merge-state / admin / CODEX gate. The inner write must
# now surface and face the same checks as a visible "<wrapper> -- gh ...".
assert_rc_contains "author wrapper hides bash -c merge: state still checked (#546 gap 1)" 2 "mergeStateStatus is BLOCKED" \
  'scripts/gh-as-author.sh -- bash -c "gh pr merge 123 --squash"' "BLOCKED" ""
assert_rc_contains "author wrapper bash -c clean merge still allowed (#546 gap 1, no false block)" 0 "" \
  'scripts/gh-as-author.sh -- bash -c "gh pr merge 123 --squash"' "CLEAN" ""
assert_rc_contains "author wrapper hides eval admin merge: surfaced + blocked (#546 gap 1)" 2 "" \
  'scripts/gh-as-author.sh -- eval "gh pr merge 123 --admin"' "CLEAN" ""
assert_rc_contains "reviewer wrapper hides bash -c admin merge: surfaced + blocked (#546 gap 1)" 2 "" \
  'scripts/gh-as-reviewer.sh -- bash -c "gh pr merge 123 --admin"' "CLEAN" ""
assert_rc_contains "wrapper bash -c echo of gh text is not a write (#546 gap 1, no false positive)" 0 "" \
  'scripts/gh-as-author.sh -- bash -c "echo gh pr merge --admin"' "CLEAN" ""

# Gap 2 — the python pre-pass and the bash walk read ONE shared
# PREFIX_VALUE_OPTS_SPEC, so a long-form prefix value-option no longer
# mis-skips. Before #546 python expanded "sudo --user X bash -c <gh write>"
# but the bash compound scan (short-forms only) mis-read X as the command
# and never saw the surfaced gh, so a guarded write passed rc=0.
assert_rc_contains "sudo --user long form bash -c gh write surfaced (#546 gap 2)" 2 "token-verifying wrapper" \
  'sudo --user root bash -c "gh pr merge 123 --admin"'
assert_rc_contains "nice --adjustment long form bash -c gh write surfaced (#546 gap 2)" 2 "token-verifying wrapper" \
  'nice --adjustment 10 bash -c "gh pr merge 123 --admin"'
assert_rc_contains "time -f value option bash -c gh write surfaced (#546 gap 2)" 2 "token-verifying wrapper" \
  'time -f FMT bash -c "gh pr merge 123 --admin"'
# Bogus sudo:-s / sudo:-c removed from the shared spec: -s is a no-value
# flag, so the FOLLOWING token is the command, not -s's value. Before #546
# the bash table wrongly skipped it and lost the gh write.
assert_rc_contains "sudo -s no-value flag does not swallow the gh write (#546 gap 2)" 2 "token-verifying wrapper" \
  'sudo -s gh pr merge 123 --admin'

# --- #546 follow-on (CodeRabbit #551): spec correctness for ionice/env ----
# ionice -t/--ignore is a no-value FLAG, so it must not consume the next
# token; before this it swallowed the bash that followed and hid the write.
assert_rc_contains "ionice -t flag does not swallow bash -c gh write (#551)" 2 "token-verifying wrapper" \
  'ionice -t bash -c "gh pr merge 123 --admin"'
# ionice -c is still a real value option (regression: must skip its value).
assert_rc_contains "ionice -c value option still skips its value, then surfaces gh (#551)" 2 "token-verifying wrapper" \
  'ionice -c 2 bash -c "gh pr merge 123 --admin"'
# env -S / --split-string FAILS CLOSED (#551, Codex r1-r4). GNU env -S has
# exotic dynamic semantics — whitespace splitting, $VAR expansion,
# $(...)/backtick substitution, AND appending the remaining argv after the
# split string — that the guard cannot safely + completely model (each partial
# model surfaced a new bypass). env -S on a command line is an exotic shebang
# feature no gh workflow needs, so ANY env -S is blocked rather than risk a
# hidden write.
assert_rc_contains "env -S gh write fails closed (#551)" 2 "tokenize" \
  'env -S "gh pr merge 123 --admin"'
assert_rc_contains "env --split-string gh write fails closed (#551)" 2 "tokenize" \
  'env --split-string "gh pr merge 123 --admin"'
assert_rc_contains "env --split-string=STR gh write fails closed (#551)" 2 "tokenize" \
  'env --split-string="gh pr merge 123 --admin"'
assert_rc_contains "env -S variable-expansion payload fails closed (#551 Codex)" 2 "tokenize" \
  'G=gh env -S "${G} pr merge 123 --admin"'
assert_rc_contains "env -S command-substitution payload fails closed (#551 Codex)" 2 "tokenize" \
  'env -S "$(printf gh) pr merge 123 --admin"'
assert_rc_contains "env -S following-argv payload fails closed (#551 Codex)" 2 "tokenize" \
  'env -S "bash -c" "gh pr merge 123 --admin"'
# No literal "gh" in the raw command (gh synthesized via octal printf), so the
# no-gh fast-path would skip the tokenizer — but env -S forces tokenization and
# then fails closed (Codex #551 r5: tokenize env -S even without a literal gh).
assert_rc_contains "env -S without a literal gh still fails closed (#551 Codex)" 2 "tokenize" \
  'G=$(printf "\147\150") env -S "${G} pr merge 123 --admin"'
# Clustered env split-string flag (-vS), not just a leading -S (CodeRabbit #551).
assert_rc_contains "env clustered -vS fails closed (#551)" 2 "tokenize" \
  'env -vS "gh pr merge 123 --admin"'
# Quoted `env` (the shell strips the quotes and runs env) with no literal gh:
# the fast-path quote-strips before probing, then env -S fails closed (Codex #551).
assert_rc_contains "quoted env -S without a literal gh fails closed (#551 Codex)" 2 "tokenize" \
  'G=$(printf "\147\150") "env" -S "${G} pr merge 123 --admin"'
# A plain env prefix (no -S) is unaffected — it still surfaces the wrapped write.
assert_rc_contains "plain env prefix still surfaces the gh write (#551 regression)" 2 "token-verifying wrapper" \
  'env FOO=bar gh pr merge 123 --admin'

# #553 (CodeRabbit Critical): a command substitution in COMMAND position can
# synthesize the executable name ($(printf "\147\150") is octal for gh), so the
# raw command carries no literal gh. The fast-path now force-tokenizes a
# command-position cmdsub, and the walk treats the flattened placeholder as a
# potential gh, failing closed on any pr/issue WRITE that follows. A placeholder
# NOT followed by a guarded write subcommand stays allowed.
assert_rc_contains "cmdsub-synth pr merge fails closed (#553)" 2 "wrapper" \
  '$(printf "\147\150") pr merge 123 --admin'
assert_rc_contains "backtick-synth issue comment fails closed (#553)" 2 "wrapper" \
  '`printf "\147\150"` issue comment 5 --body hi'
assert_rc_contains "assignment-prefixed cmdsub-synth pr merge fails closed (#553)" 2 "wrapper" \
  'FOO=1 $(printf "\147\150") pr merge 1'
assert_rc_contains "separator-then cmdsub-synth pr merge fails closed (#553 empirical)" 2 "wrapper" \
  'gh --version ; $(printf "\147\150") pr merge 123 --admin'
assert_rc_contains "command-position cmdsub with NO gh write stays allowed (#553)" 0 "" \
  '$(date -u) >/dev/null'
# #553 regression: a benign command-position cmdsub (the ubiquitous
# `eval "$(brew shellenv)"`) before a WRAPPED write must NOT false-trip the
# compound #348 block. An interim fix counted the placeholder as a gh
# invocation in the pre-scan; the synth bypass is caught by the main walk, not
# the compound pre-scan, so the pre-scan must ignore the placeholder.
assert_rc_contains "eval cmdsub before a wrapped write is allowed (#553)" 0 "" \
  'eval "$(/opt/homebrew/bin/brew shellenv)" && scripts/gh-as-author.sh -- gh pr merge 1 --repo o/r --squash'

# #560 (residual of #553): a command-position cmdsub-synthesized gh must fail
# closed even after a prefix command + options (command -p, env -i), a
# value-taking flag (env -u NAME), or a quoted env assignment (FOO="a b"). The
# command-position forward pass tracks position through prefix/flag/assignment
# tokens (via prefix_flag_takes_value), not just the immediate previous token.
assert_rc_contains "command -p cmdsub-synth pr merge fails closed (#560)" 2 "wrapper" \
  'command -p $(printf "\147\150") pr merge 1'
assert_rc_contains "env -i cmdsub-synth pr merge fails closed (#560)" 2 "wrapper" \
  'env -i $(printf "\147\150") pr merge 1'
assert_rc_contains "quoted-assignment cmdsub-synth pr merge fails closed (#560)" 2 "wrapper" \
  'FOO="bar baz" $(printf "\147\150") pr merge 1'
assert_rc_contains "value-flag arg then cmdsub-synth pr merge fails closed (#560)" 2 "wrapper" \
  'env -u FOO $(printf "\147\150") pr merge 1'
assert_rc_contains "sudo -n cmdsub-synth issue comment fails closed (#560)" 2 "wrapper" \
  'sudo -n $(printf "\147\150") issue comment 5 --body hi'
# Controls: a cmdsub CONSUMED as a value-taking flag's argument is NOT command
# position (env -u $(...) -> the synth is the var NAME, `pr merge` is the cmd),
# and an echo argument just prints. Both stay allowed.
assert_rc_contains "cmdsub as value-taking flag arg stays allowed (#560)" 0 "" \
  'env -u $(printf "\147\150") pr merge 1'
assert_rc_contains "cmdsub as echo argument stays allowed (#560)" 0 "" \
  'echo $(printf "\147\150") pr merge'

# #553 fix (b): the merge-state jq counts an un-timestamped PENDING re-run as
# non-green even when a timestamped SUCCESS exists for the same check (the prior
# max_by(.t) mis-ranked the empty-timestamp PENDING behind the SUCCESS, so an
# UNSTABLE PR with a check still re-running could merge before CI finished).
GH_JQ_def=$(grep -m1 '^GH_JQ=' "$HOOK")
eval "$GH_JQ_def"
_ng=$(printf '%s' '{"statusCheckRollup":[{"name":"ci","conclusion":"SUCCESS","completedAt":"2026-06-28T10:00:00Z"},{"name":"ci","state":"PENDING"}],"labels":[]}' | jq -r "$GH_JQ" | sed -n '3p')
if [ "${_ng:-0}" -ge 1 ]; then pass "merge-state jq: un-timestamped PENDING re-run counts non-green (#553)"; else fail "merge-state jq (#553): expected non-green >= 1, got '$_ng'"; fi
_ng2=$(printf '%s' '{"statusCheckRollup":[{"name":"ci","conclusion":"SUCCESS","completedAt":"2026-06-28T10:00:00Z"},{"name":"lint","conclusion":"SUCCESS","completedAt":"2026-06-28T11:00:00Z"}],"labels":[]}' | jq -r "$GH_JQ" | sed -n '3p')
if [ "${_ng2:-x}" = "0" ]; then pass "merge-state jq: all-terminal-green stays 0 (no false block) (#553)"; else fail "merge-state jq (#553): expected 0, got '$_ng2'"; fi

echo ""
echo "test_gh_pr_guard: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
