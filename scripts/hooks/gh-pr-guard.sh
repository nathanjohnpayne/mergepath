#!/usr/bin/env bash
# gh-pr-guard.sh — PreToolUse hook for Claude Code
#
# Gates core write operations:
#   1. gh pr create — blocks unless the command is routed through
#      scripts/gh-as-author.sh and the command text includes
#      "Authoring-Agent:" and "## Self-Review". The wrapper verifies
#      an author token before the write and verifies the created PR
#      author afterward with the same token.
#   2. gh pr merge --admin — blocks unless BREAK_GLASS_ADMIN=1
#      (human must explicitly authorize in chat)
#   3. gh pr merge (any flavor) — blocks when the target PR's
#      `mergeStateStatus` is BLOCKED / DIRTY / UNSTABLE / BEHIND /
#      DRAFT (or any unrecognized future value) unless
#      BREAK_GLASS_MERGE_STATE=1. This is the defense-in-depth
#      layer behind GitHub branch protection — see #170 / #171 for
#      the merge-gate gap this closes (a PR can otherwise be merged
#      with failing CI because nothing in the merge path actually
#      blocks). Originated downstream (matchline #170/#171) and is
#      unified into the canonical hook here so propagation no longer
#      clobbers the feature — see the propagation-wave retro.
#   4. gh pr merge (any flavor) — blocks when the target PR carries
#      `human-hold`, with no CODEX_CLEARED / BREAK_GLASS_* bypass.
#      This is the human-controlled hard freeze: agents may add the
#      label, but only the human releases it.
#   5. gh pr merge (non-admin) — blocks when the target PR carries
#      the `needs-external-review` label unless CODEX_CLEARED=1
#      (agent must have just run scripts/codex-review-check.sh
#      successfully). This enforces REVIEW_POLICY.md § Phase 4a
#      merge gate at the hook layer so an agent can't accidentally
#      merge past Label Gate by removing the label without running
#      the gate check first.
#
# Byline-sensitive command coverage (#284/#411):
#
#   Beyond the pr-create / pr-merge gates above, the hook ALSO
#   guards a class of commands whose byline is identity-load-bearing
#   in this codebase:
#
#     - gh pr comment <PR#> --body "..."
#     - gh pr review <PR#> --comment / --approve / --request-changes
#     - gh issue comment <issue#> --body "..."
#
#   All three must be routed through scripts/gh-as-reviewer.sh. The
#   expected reviewer resolves as: explicit
#   GH_PR_GUARD_EXPECTED_REVIEWER override, else
#   nathanpayne-$MERGEPATH_AGENT, else nathanpayne-claude. The hook
#   validates the wrapper configuration and blocks direct or inline
#   token forms so the wrapper can verify the effective token before
#   any comment/review lands.
#
#   `gh issue create` is intentionally NOT in this set. It was briefly
#   guarded (#317, after the mergepath#315 misattribution) but that
#   overreached: filing issues under the author identity
#   (nathanjohnpayne) is a long-standing, intended workflow, so the
#   issue-create byline clause was reverted. Issue creation is allowed
#   under any identity.
#
#   Additionally, `gh pr review --approve` is blocked when the
#   target PR is OVER-threshold AND the reviewer wrapper identity is the
#   agent's own reviewer identity AND the PR's body contains an
#   `Authoring-Agent:` line that names the SAME agent. This is the no-self-approve
#   policy from REVIEW_POLICY.md § No-self-approve scoping enforced
#   at the hook layer: a `claude` reviewer must not approve a PR
#   whose `Authoring-Agent: claude` line means claude wrote it. The
#   over/under-threshold determination uses .github/review-policy.yml
#   if present; without the file the hook conservatively assumes
#   over-threshold so the self-approve block fires on safer side.
#
#   The self-approve guard has one carve-out (#334): propagation-lane
#   sync PRs are EXEMPT. A PR qualifies as a lane PR when (1) its
#   branch name starts with `mergepath-sync/` (configurable via
#   GH_PR_GUARD_PROPAGATION_BRANCH_PREFIX) and (2) its GitHub author
#   is the configured `nathanjohnpayne` identity. For lane PRs, the
#   self-approve guard returns exit 0 without checking
#   Authoring-Agent, size, or threshold — REVIEW_POLICY.md
#   § Propagation PR review lane explicitly allows internal reviewer-
#   identity APPROVED regardless of size, because the content is a
#   verbatim mirror that was already reviewed in the upstream
#   mergepath PR. The manifest-confinement third lane criterion is
#   intentionally deferred to scripts/workflow/verify-propagation-
#   pr.sh; branch_prefix + author is sufficient signal at this layer.
#
#   These guards are scoped to `gh pr comment` / `gh pr review` /
#   `gh issue comment` exactly. `gh issue create` was briefly added by
#   #317 (after the mergepath#315 misattribution) but later reverted —
#   see the byline-coverage note above — so issue creation is no
#   longer gated by this hook.
#
#   Raw `gh api -X POST .../comments` is still intentionally NOT
#   covered — the token/keyring auth matrix for raw `gh api` writes
#   is not yet precise enough to block on without false positives.
#   See REVIEW_POLICY.md § Operation-to-Identity Matrix (graphql
#   write — PAT-attributed) for the auth-split context and the
#   follow-up tracked under #284.
#
# The identity check (1a) honors a
# BOOTSTRAP_GH_PR_GUARD_SKIP_IDENTITY_CHECK=1 escape hatch for tests
# that PATH-shim gh and have no real keyring. Production code should
# never set this — the wrapper script gh-as-author.sh switches to the
# author identity BEFORE the gh pr create call lands, so the check
# passes naturally without the bypass.
#
# Exit codes:
#   0 = allow
#   2 = block (hard stop)
#
# Architecture notes:
#
#   The hook does ALL its parsing on a tokenized form of the
#   command produced by a python3 shlex.split tokenizer (see the
#   tokenizer section below; an earlier version used `xargs -n 1`),
#   which honors POSIX shell quoting. Earlier iterations used substring `grep` on the raw
#   command string and were buggy in two correlated ways:
#
#     1. nathanpayne-codex caught (PR #66 round 2) that
#        `TOKENS=( $COMMAND )` performed bash word splitting that
#        ignored shell quotes — `gh pr merge --body "hello world"
#        65` would split into (gh, pr, merge, --body, "hello,
#        world", 65) and confuse the value-flag SKIP logic.
#
#     2. nathanpayne-codex caught (PR #66 round 3) that the
#        top-level matcher `^\s*gh\s+pr\s+(create|merge)` only
#        recognized the bare form. gh accepts a global -R/--repo
#        flag BEFORE the subcommand: `gh -R foo/bar pr merge 65`
#        and `gh --repo foo/bar pr create ...` would bypass the
#        hook entirely.
#
#   Both bugs trace to the same shape — substring matching on a
#   string of unknown structure. The fix is to tokenize once at
#   the top with quote awareness, walk the tokens to identify the
#   pr subcommand (capturing any global -R/--repo along the way),
#   and reuse the same TOKENS array in the create and merge
#   branches.
#
# Design notes:
#
#   - Compound Bash tool calls that contain multiple command-position
#     `gh` invocations now fail closed when any invocation is a
#     guarded write (pr create/merge/comment/review or issue
#     comment). This is deliberately conservative: split multi-step
#     GitHub work into separate Bash tool calls so each write gets
#     the same single-command guard path (#348).
#
#   - eval / sh -c / bash -c / dash -c payloads are re-tokenized so a
#     guarded gh write hidden inside a quoted shell-string payload is
#     surfaced to the token walk instead of passing as one opaque
#     token. The python tokenizer expands these recursively before the
#     walk runs (over-expansion is safe — the walk re-establishes
#     command position on the expanded stream), and malformed inner
#     quoting fails closed like any other parse error. Closes the
#     eval / bash -c / sh -c admin-merge bypass (#533 item 1).
#
#   - The CODEX_CLEARED check is a hook-layer defense-in-depth.
#     The authoritative merge gate is scripts/codex-review-check.sh;
#     the hook only verifies the agent claims to have run it. An
#     agent that sets CODEX_CLEARED=1 without actually running the
#     check is violating policy — the hook is not an integrity
#     check, it is an ordering check.
#
#   - PR selector is parsed from the command tokens: first non-flag
#     positional argument after `merge`. Accepts <number> | <url> |
#     <branch> per the gh CLI grammar. If no selector is present,
#     the hook falls back to `gh pr view --json labels` with no
#     positional so gh resolves the PR from the current branch.
#
#   - Label lookup calls the GitHub API. This is a side effect of
#     the hook but consistent with the agent's own label-check
#     behavior elsewhere in the policy flow. Failure to reach the
#     API (offline, auth issue) fails CLOSED with a diagnostic.
#
#   - Bash 3.2 portability: macOS ships bash 3.2 by default. The
#     hook avoids bash 4+ features (no `mapfile`, no `[[ =~ ]]` in
#     places where `[[ == ]]` works, etc.).
#
# Inline environment assignments:
#
#   The bash form `VAR=value command args` sets VAR in the spawned
#   command's environment but NOT in the hook process. The PreToolUse
#   hook fires before bash executes the command, so it can't read
#   inline-prefixed env vars from its own ${VAR} expansion. The
#   documented happy paths use exactly this form:
#
#     CODEX_CLEARED=1 gh pr merge 65 --squash --delete-branch
#     BREAK_GLASS_ADMIN=1 gh pr merge --admin 65 ...
#
#   So the hook must parse env assignments out of the command string
#   before the `gh` token and treat them as if they were exported.
#   nathanpayne-codex caught the bypass on PR #66 round 4: with the
#   round-3 hook, both forms hit the early `^\s*gh(\s|$)` matcher,
#   missed it, and exited 0 before any guard ran.
#
#   Round 4 fix: the early matcher now allows leading prefix material
#   before `gh`, and the top-level token walk captures CODEX_CLEARED
#   and BREAK_GLASS_ADMIN from the pre-gh tokens into INLINE_ vars.
#   The merge guard then uses these as fallbacks if the hook's own
#   environment doesn't have the corresponding variable set via
#   `export`.
#
# Limitations (documented as known gaps):
#
#   - Backslash escapes inside double-quoted strings (`"with
#     \"escape\""`) are not handled by xargs and will fail closed
#     with the tokenization error.
#
#   - Custom gh aliases (`gh alias set merge ...`) that expand
#     `merge` to something else are not recognized — the hook
#     guards a specific literal command grammar.
#
#   - Unknown global flags (anything other than `-R/--repo` and
#     boolean flags like `--help`/`--version`) are assumed boolean.
#     If gh adds new value-taking globals, the hook needs an
#     update; misclassifying them as boolean would let the next
#     token leak through as the subcommand.
#
#   - Other env vars in the inline prefix (anything other than
#     CODEX_CLEARED and BREAK_GLASS_ADMIN) are skipped without
#     interpretation. This is fine because no other env var is
#     consulted by hook policy decisions.

set -euo pipefail

INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty')

# Quick exit if there's no `gh` token in the command at all. This
# uses a whitespace-bounded match rather than `^\s*gh` so that
# leading prefix material (env assignments, `eval`, `time`, `sudo`,
# compound separators like `;` followed by a space) doesn't bypass
# the hook entirely. False positives where `gh` appears in the
# middle of an unrelated command are caught downstream by the token
# walk, which exits 0 if no `gh pr (create|merge)` subcommand is
# present.
# Strip quotes before the quick-exit scan (#466 r2): a quoted, path-
# qualified invocation like '/usr/bin/gh' pr merge would otherwise leave
# the closing quote glued to `gh` and slip past the boundary. The shlex
# token walk below strips quotes itself and the */gh case catches it — but
# only if we do NOT early-exit here. Stripping quotes for this fast-path
# probe is safe; it only governs whether the authoritative tokenizer runs.
#
# #540 Phase-4b: the boundary classes are [^A-Za-z0-9_] on BOTH sides, not
# just whitespace, so a `gh` reached through a command substitution or a
# subshell — `$(gh ...)`, `(gh ...)`, `;gh`, backtick gh — is not skipped
# here (after quote-stripping it is preceded by `(` / `$` / `;` / a
# backtick, never a space, so the old whitespace-only boundary missed it
# and the hook exited before tokenizing). Erring toward NOT early-exiting
# is the fail-closed direction: a false positive costs one tokenizer run;
# a false negative is a bypass.
# #551 (Codex): env -S / --split-string can synthesize `gh` dynamically (e.g.
# from an octal printf in a $(...) substitution), so the raw command may carry
# NO literal `gh` yet still run `gh pr merge`. A no-`gh` early-exit would then
# skip the env -S fail-closed branch in the tokenizer below. Force tokenization
# whenever the command carries `gh` OR an env -S / --split-string flag (the
# tokenizer then blocks the env -S, fail-closed). Over-matching only costs one
# tokenizer run; a false negative is a bypass.
NEEDS_TOKENIZE=0
if echo "$COMMAND" | tr -d "\"'\\\\" | grep -qE '(^|[^A-Za-z0-9_])([^[:space:]]*/)?gh([^A-Za-z0-9_]|$)'; then
  NEEDS_TOKENIZE=1
elif echo "$COMMAND" | tr -d "\"'\\\\" | grep -qE '(^|[^A-Za-z0-9_])env([[:space:]]|$)' \
     && echo "$COMMAND" | tr -d "\"'\\\\" | grep -qE '(-[A-Za-z]*S|--split-string)'; then
  # Quote-stripped (Codex #551): a quoted `'env'` runs env but would otherwise
  # leave a quote, not whitespace, after `env` and dodge this probe. Backslashes
  # are stripped alongside quotes (#611 round 3): bash unescapes `g\h` / `e\nv`
  # to `gh` / `env` at execution, so escape-spelled literals must reach the
  # probes in their canonical form too.
  NEEDS_TOKENIZE=1
elif echo "$COMMAND" | grep -qE '\$\(|`'; then
  # #553 / #560 / #573: a command substitution (or backtick) can synthesize ANY
  # token of a gh write — the executable (`$(printf '\147\150')` -> gh), the
  # noun (`gh pr`), and even the verb in escape-spelled form (`m\erge`) that no
  # literal probe can enumerate (#611 round 3: `$(printf '\147\150\40\160\162')
  # m\erge` carries no raw `gh`, `pr`, or `merge` text at all). Earlier
  # revisions paired the cmdsub probe with a literal noun/verb probe; every
  # such pairing leaves an escape/quoting spelling that dodges it, so the mere
  # PRESENCE of a substitution now forces tokenization. shlex then normalizes
  # quotes and escapes, and the command-position forward pass (_synth_ walk)
  # below fails closed ONLY on guarded-write evidence after a command-position
  # placeholder, ignoring benign cmdsubs, arguments, and non-command-position
  # verbs. Over-matching costs one tokenizer run; a false negative is a bypass.
  NEEDS_TOKENIZE=1
elif printf '%s' "$COMMAND" | grep -qF "\$'"; then
  # #611 r14: bash ANSI-C quoting ($'...') decodes backslash escapes, so
  # `$'\147\150' pr merge` runs `gh pr merge` with no literal gh in the raw
  # text (and shlex does not decode $'...'). Force tokenization on any $'
  # so the python flatten decodes it before the walk.
  NEEDS_TOKENIZE=1
fi
if [ "$NEEDS_TOKENIZE" -eq 0 ]; then
  exit 0
fi

# --- tokenize the command with shell-quote awareness ---
#
# Use python3 shlex.split which honors POSIX single and double
# quoting AND handles multi-line quoted strings. `gh pr merge
# --body "hello world" 65` tokenizes correctly to (gh, pr, merge,
# --body, hello world, 65), and `gh pr create --body "Authoring-
# Agent: claude\n## Self-Review\nok"` (with literal newlines in
# the body) also tokenizes correctly because shlex.split treats
# newlines inside quotes as literal characters, not as token
# separators.
#
# Earlier versions used `xargs -n 1` (with the implicit `echo`
# command), which:
#   - Silently drops -n / -e / -E (echo's own flags). Codex caught
#     this on PR #66 round 6 and the workaround was `xargs -n 1
#     printf '%s\n'`.
#   - Treats embedded newlines as token separators, breaking
#     valid `gh pr create --body "...multiline..."` invocations.
#     Codex caught this on nathanpaynedotcom propagation PR #180
#     round 4. xargs has no flag to disable this behavior; the
#     fix is to switch tokenizers entirely.
#
# python3 is available on macOS 12+ by default and on every Linux
# distro the agent flow runs on. Python startup cost is ~50ms per
# invocation; acceptable for a hook that already does an API call.
#
# Fails CLOSED on tokenization error (unmatched quote, bad escape).
# An agent should fix the malformed command and retry.
#
# python3 emits tokens NUL-delimited so bash's read -d '' can
# preserve embedded newlines. The output goes via a tempfile
# rather than $(...) command substitution because bash command
# substitution silently strips NUL bytes from its capture buffer,
# which would re-jam all tokens together. Earlier versions used
# newline-delimited output via print(tok), which silently SPLIT
# any token containing a literal newline (e.g., the body of a
# `gh pr create --body "Authoring-Agent: claude\n## Self-Review
# \nok"`) into multiple bash tokens. Codex caught the bash-side
# split on nathanpaynedotcom propagation PR #180 round 5.
TMP_TOKENS=$(mktemp)
TMP_TOKENS_ERR=$(mktemp)
trap 'rm -f "$TMP_TOKENS" "$TMP_TOKENS_ERR"' EXIT
# The python preprocessor first converts UNQUOTED newlines into `;`
# command separators (so that multi-command inputs like
# `echo ok\ngh pr merge 123 --admin` are split into two commands)
# while preserving QUOTED newlines as literal characters in the
# token (so that `gh pr create --body "line1\nline2"` keeps the
# body as one token). Codex caught the unquoted-newline collapse
# on swipewatch propagation PR #33 round 6 — privilege escalation
# via newline-separated prefix command was the same shape as the
# round-5 echo-prefix env spoof, just on a different separator.
#
# --- #546: single source of truth for prefix value-consuming options ---
# Both the python pre-pass (which surfaces a bash -c payload hidden behind a
# prefix) and the bash compound-scan + main walk (which skip prefix options
# to find a command-position gh) MUST agree on which options consume the
# NEXT token. If the two drift, a "<prefix> <value-opt> VALUE bash -c
# <gh write>" payload slips through whichever layer is missing the option
# (#546 gap 2: the bash walk lacked the long forms the python table had).
# Defined ONCE here and read by BOTH, so they cannot drift. Per-prefix
# because the same letter differs by tool (nice -n takes a value; sudo -n
# does not). Format: ";"-joined "<prefix>=<opt>,<opt>,..." entries. ONLY
# value-CONSUMING options belong here: ionice -t/--ignore is a no-value flag
# (CodeRabbit #551), and env -S/--split-string is NOT a value either — it runs
# its argument as a SPLIT command with exotic dynamic semantics, so it FAILS
# CLOSED in expand_wrappers (Codex #551) rather than being skipped here.
PREFIX_VALUE_OPTS_SPEC="sudo=-u,--user,-g,--group,-p,--prompt,-h,--host,-t,--type,-r,--role,-C,--close-from,-D,--chdir,-R,--chroot,-U,--other-user,-T,--command-timeout;nice=-n,--adjustment;ionice=-c,--class,-n,--classdata,-p,--pid;env=-u,--unset,-C,--chdir;exec=-a;time=-f,--format,-o,--output"
export PREFIX_VALUE_OPTS_SPEC
if ! printf '%s' "$COMMAND" | python3 -c '
import sys, shlex, re, os

# chr(39)/chr(34) are single/double quote; chr() avoids embedding a
# literal single quote inside the python3 -c surrounding heredoc.
_SQ = chr(39)
_DQ = chr(34)

def _read_paren_span(cmd, start):
    # `start` points just AFTER the opening "$(". Return (inner, index
    # after the matching ")"). Tracks nested $( / ( and an INDEPENDENT
    # quote context (a ) inside quotes does not close the span), matching
    # bash command-substitution parsing. Raises on an unterminated span.
    depth = 1
    i = start
    n = len(cmd)
    in_single = False
    in_double = False
    while i < n:
        c = cmd[i]
        if c == "\\" and not in_single and i + 1 < n:
            i += 2
            continue
        if c == _SQ and not in_double:
            in_single = not in_single
            i += 1
            continue
        if c == _DQ and not in_single:
            in_double = not in_double
            i += 1
            continue
        if not in_single and not in_double:
            if c == "$" and i + 1 < n and cmd[i + 1] == "(":
                depth += 1
                i += 2
                continue
            if c == "(":
                depth += 1
                i += 1
                continue
            if c == ")":
                depth -= 1
                if depth == 0:
                    return cmd[start:i], i + 1
                i += 1
                continue
        i += 1
    raise ValueError("unterminated command substitution")

def _read_backtick_span(cmd, start):
    # `start` points just AFTER the opening backtick. Return (inner, index
    # after the closing backtick). Backticks do not nest; backslash escapes
    # the next char. Raises on an unterminated span.
    i = start
    n = len(cmd)
    bt = chr(96)
    while i < n:
        c = cmd[i]
        if c == "\\" and i + 1 < n:
            i += 2
            continue
        if c == bt:
            return cmd[start:i], i + 1
        i += 1
    raise ValueError("unterminated backtick substitution")

# --- #611 round 2/3: statically expand literal-only printf/echo spans ---
# A substitution like $(printf "\147\150\40\160\162\40\155\145\162\147\145")
# can synthesize an ENTIRE guarded write with zero literal evidence left in
# the outer command, which no placeholder heuristic can decide. But such a
# span is a PURE FUNCTION of literal text — the guard can emulate it and
# splice the real expansion into the token stream, deciding the command
# exactly: a synthesized `gh pr merge` is blocked as the guarded write it
# is, and a synthesized `hello world` is allowed as the data it is. Only
# unquoted spans whose argv is a flag-free echo or a %s-only printf with
# fully literal arguments are expanded; anything dynamic (variables, nested
# substitutions, other commands, exotic directives) falls back to the
# placeholder + evidence scan. The spliced text is restricted to a shell-
# inert charset so it can never introduce new syntax.

def _decode_fmt_escapes(s):
    # bash printf decodes backslash escapes in its FORMAT argument:
    # \NNN (octal), \xHH (hex), and the C letters. Unknown escapes stay
    # verbatim (bash prints them as-is).
    simple = {"a": "\a", "b": "\b", "f": "\f", "n": "\n",
              "r": "\r", "t": "\t", "v": "\v", "\\": "\\"}
    out = []
    i = 0
    n = len(s)
    while i < n:
        c = s[i]
        if c != "\\" or i + 1 >= n:
            out.append(c)
            i += 1
            continue
        nxt = s[i + 1]
        if nxt in simple:
            out.append(simple[nxt])
            i += 2
            continue
        if nxt == "x":
            m = re.match(r"[0-9A-Fa-f]{1,2}", s[i + 2:i + 4])
            if m:
                out.append(chr(int(m.group(0), 16)))
                i += 2 + len(m.group(0))
                continue
            out.append("\\")
            i += 1
            continue
        m = re.match(r"[0-7]{1,3}", s[i + 1:i + 4])
        if m:
            out.append(chr(int(m.group(0), 8)))
            i += 1 + len(m.group(0))
            continue
        out.append("\\")
        out.append(nxt)
        i += 2
    return "".join(out)

_SPLICE_SAFE_RE = re.compile(r"[A-Za-z0-9_./,:@+% -]*\Z")

def _decode_ansi_c(s):
    # bash ANSI-C quoting ($ + single-quoted string) decodes C escapes:
    # \NNN octal, \xHH hex, the C letters, and quote escapes. Unknown
    # escapes stay verbatim (bash keeps them).
    simple = {"a": "\a", "b": "\b", "f": "\f", "n": "\n", "r": "\r",
              "t": "\t", "v": "\v", "\\": "\\", _SQ: _SQ, _DQ: _DQ}
    out = []
    i = 0
    n = len(s)
    while i < n:
        c = s[i]
        if c != "\\" or i + 1 >= n:
            out.append(c)
            i += 1
            continue
        nxt = s[i + 1]
        if nxt in simple:
            out.append(simple[nxt])
            i += 2
            continue
        if nxt == "x":
            m = re.match(r"[0-9A-Fa-f]{1,2}", s[i + 2:i + 4])
            if m:
                out.append(chr(int(m.group(0), 16)))
                i += 2 + len(m.group(0))
                continue
            out.append("\\")
            i += 1
            continue
        m = re.match(r"[0-7]{1,3}", s[i + 1:i + 4])
        if m:
            out.append(chr(int(m.group(0), 8)))
            i += 1 + len(m.group(0))
            continue
        out.append("\\")
        out.append(nxt)
        i += 2
    return "".join(out)

def _rewrite_ansi_c(span, neutral):
    # Rewrite every $-single-quote ANSI-C string in span to a PLAIN
    # single-quoted string holding its decoded text, so the downstream
    # literal classification and shlex see the real content (#611 round 6:
    # $(echo $-quoted octal for a gh write) dodged the literal classifier
    # via its $). A decoded chunk that cannot be re-wrapped (contains a
    # single quote) is replaced by `neutral` when given — classification
    # still sees a literal printf/echo and the span fails closed as
    # unexpandable — or aborts the rewrite when neutral is None
    # (_static_expand: not expandable). Unterminated quoting aborts too.
    out = []
    i = 0
    n = len(span)
    while i < n:
        c = span[i]
        if c == "$" and i + 1 < n and span[i + 1] == _DQ:
            # bash LOCALE quoting ($ + double-quoted string) is its literal
            # content for any untranslated string — same dodge shape as
            # ANSI-C, preempted alongside it: drop the $ and let the plain
            # double-quoted string flow through classification/shlex.
            i += 1
            continue
        if c == "$" and i + 1 < n and span[i + 1] == _SQ:
            j = i + 2
            buf = []
            closed = False
            while j < n:
                d = span[j]
                if d == "\\" and j + 1 < n:
                    buf.append(d)
                    buf.append(span[j + 1])
                    j += 2
                    continue
                if d == _SQ:
                    closed = True
                    j += 1
                    break
                buf.append(d)
                j += 1
            if not closed:
                return (None, False)
            dec = _decode_ansi_c("".join(buf))
            if _SQ in dec:
                if neutral is None:
                    return (None, False)
                out.append(neutral)
            else:
                out.append(_SQ + dec + _SQ)
            i = j
            continue
        out.append(c)
        i += 1
    return ("".join(out), True)

def _is_literal_printf_echo(span):
    # True when the span is a PURE-LITERAL printf/echo invocation (no shell-
    # active characters, tokenizable, printf/echo command) — the class
    # _static_expand emulates. Used to fail closed when such a span is NOT
    # expandable (%b and other decoder directives, format-reuse forms): a
    # literal printf can synthesize an entire guarded write with zero outside
    # evidence, so an unexpandable one in command position is blocked rather
    # than allowed through as an anonymous placeholder (#611 round 5).
    span, ok = _rewrite_ansi_c(span, _SQ + "MPANSIC" + _SQ)
    if not ok:
        return False
    for ch in ("$", chr(96), ";", "|", "&", "<", ">", "(", ")", "{", "}"):
        if ch in span:
            return False
    try:
        argv = shlex.split(span)
    except ValueError:
        return False
    argv = _unwrap_synth_prefixes(argv)  # command printf ... (#611 r12)
    # Match the command-word BASENAME (#611 r10): $(/bin/echo ...) and
    # $(/usr/bin/printf ...) word-split into the same synthesized write as
    # the bare forms, so a path-qualified printf/echo is just as much a
    # literal synth source.
    return bool(argv) and argv[0].rsplit("/", 1)[-1] in ("printf", "echo")

# #611 round 7: an IFS assignment anywhere in the command re-defines how
# bash word-splits unquoted substitution output (IFS=/ makes a synthesized
# gh-slash split into a gh word), which the whitespace-based splicer cannot
# model. When the raw command touches IFS, static expansion is disabled
# entirely — literal spans then fail closed via the unexpandable sentinel
# in command position and stay inert elsewhere. Set before flattening.
_IFS_TOUCHED = False

# Prefix commands that can precede a real command inside a substitution
# ($(command printf ...), $(env printf ...)) — bash runs the wrapped command,
# so the synth classifier must unwrap them to see the real printf/echo (#611
# r12). Reuses the flatten prefix set plus leading flags/assignments.
_SYNTH_PREFIX_CMDS = {"command", "env", "sudo", "exec", "nice",
                      "ionice", "nohup", "time", "builtin"}

def _unwrap_synth_prefixes(argv):
    k = 0
    prefix = ""
    while k < len(argv):
        t = argv[k]
        if t in _SYNTH_PREFIX_CMDS:
            prefix = t
            k += 1
            continue
        if re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", t):
            k += 1
            continue
        if t.startswith("-"):
            # A value-taking prefix option consumes its VALUE too (#611 r14:
            # env -u X printf — X is the value of -u, not the command), using
            # the same per-prefix table as the walks so they cannot drift.
            opts = _PREFIX_VALUE_OPTS.get(prefix, _EMPTY_FROZENSET)
            if "=" not in t and t in opts:
                k += 2
            else:
                k += 1
            continue
        break
    return argv[k:]

def _static_expand(span):
    # Return the literal expansion of a pure printf/echo span, or None when
    # the span is dynamic or the expansion is not splice-safe.
    if _IFS_TOUCHED:
        return None
    span, ok = _rewrite_ansi_c(span, None)
    if not ok:
        return None
    for ch in ("$", chr(96), ";", "|", "&", "<", ">", "(", ")", "{", "}"):
        if ch in span:
            return None
    try:
        argv = shlex.split(span)
    except ValueError:
        return None
    argv = _unwrap_synth_prefixes(argv)  # command printf ... (#611 r12)
    if not argv:
        return None
    # Match the command-word BASENAME (#611 r10): /bin/echo, /usr/bin/printf
    # expand identically to their bare forms.
    cmd0 = argv[0].rsplit("/", 1)[-1]
    if cmd0 == "echo":
        args = argv[1:]
        if args and args[0] == "-n":
            args = args[1:]
        if args and args[0].startswith("-"):
            return None  # -e/-E/clustered flags: bail to the placeholder
        out = " ".join(args)
    elif cmd0 == "printf":
        if len(argv) < 2:
            return None
        fmt = _decode_fmt_escapes(argv[1])
        args = argv[2:]
        # Split the format on %s directives; reject any other directive.
        pieces = []
        cur = []
        i = 0
        ns = 0
        while i < len(fmt):
            c = fmt[i]
            if c == "%":
                if i + 1 < len(fmt) and fmt[i + 1] == "%":
                    cur.append("%")
                    i += 2
                    continue
                if i + 1 < len(fmt) and fmt[i + 1] == "s":
                    pieces.append("".join(cur))
                    cur = []
                    ns += 1
                    i += 2
                    continue
                return None
            cur.append(c)
            i += 1
        pieces.append("".join(cur))
        if ns == 0:
            if args:
                return None  # format-reuse semantics: bail
            out = pieces[0]
        else:
            # The format is reused until all args are consumed; missing
            # args behave as empty strings (bash printf semantics).
            reps = ((len(args) + ns - 1) // ns) if args else 1
            parts = []
            ai = 0
            for _ in range(reps):
                for j in range(ns):
                    parts.append(pieces[j])
                    parts.append(args[ai] if ai < len(args) else "")
                    ai += 1
                parts.append(pieces[ns])
            out = "".join(parts)
    else:
        return None
    # bash removes TRAILING newlines from substitution output before any
    # concatenation (#611 round 6: printf gh-then-newline glued to pr runs
    # ghpr, not gh pr) — strip them first. Remaining IFS whitespace inside
    # the expansion word-splits exactly like a space (#611 round 4: printf
    # newlines between synthesized words), so normalize space/tab/newline
    # RUNS to single spaces BEFORE the splice-safety check. No other strip:
    # a leading (or trailing space/tab) separator still separates the
    # expansion from glued adjacent text, exactly as bash field-splits it.
    out = re.sub(r"\n+\Z", "", out)
    out = re.sub(r"[ \t\n]+", " ", out)
    if not _SPLICE_SAFE_RE.match(out):
        return None
    return out

_LINE_PREFIX_CMDS = {"sudo", "env", "command", "exec", "nice",
                     "ionice", "nohup", "time"}
_LINE_INTERPRETERS = {"sh", "bash", "dash", "zsh", "ksh", "eval",
                      "source", "."}

def _read_heredoc_delimiter(cmd, j):
    # cmd[j:] begins at the heredoc delimiter WORD (after `<<`, an optional
    # `-`, and optional blanks). Return (literal_tag, quoted, end_index).
    # A delimiter is "quoted" (bash disables body expansion) if ANY part is
    # single/double-quoted OR backslash-escaped — covers <<'EOF', <<"EOF",
    # <<\EOF, <<E\OF, and quoted tags with punctuation like <<'EOF-MP'
    # (#611 r10). The literal tag is the word with quotes/backslashes removed
    # (what the closing line must equal). An empty word ends the scan.
    n = len(cmd)
    chars = []
    quoted = False
    while j < n:
        c = cmd[j]
        if c == "\\" and j + 1 < n:
            quoted = True
            chars.append(cmd[j + 1])
            j += 2
            continue
        if c == _SQ:
            quoted = True
            j += 1
            while j < n and cmd[j] != _SQ:
                chars.append(cmd[j]); j += 1
            if j < n:
                j += 1
            continue
        if c == _DQ:
            quoted = True
            j += 1
            while j < n and cmd[j] != _DQ:
                if cmd[j] == "\\" and j + 1 < n:
                    chars.append(cmd[j + 1]); j += 2; continue
                chars.append(cmd[j]); j += 1
            if j < n:
                j += 1
            continue
        if c in (" ", "\t", "\n", ";", "&", "|", "(", ")", "<", ">"):
            break
        chars.append(c)
        j += 1
    return "".join(chars), quoted, j

def _segment_command_word(toks):
    # The command-word BASENAME of one pipeline/list SEGMENT (already
    # whitespace-split, escapes/quotes stripped), with redirections and their
    # targets, leading env assignments, and prefix commands + flags skipped
    # (#611 r10: `bash` in a redirection path or an argument must NOT be read
    # as the interpreter). A value-taking prefix option consumes its VALUE
    # too (#611 r13: sudo -u nobody bash — nobody is the value of -u, not the
    # command), using the same per-prefix PREFIX_VALUE_OPTS_SPEC table as the
    # main walk so the two cannot drift.
    k = 0
    prefix = ""
    while k < len(toks):
        t = toks[k]
        if re.match(r"^[0-9]*(>>|>|<<?|>&|&>)", t):
            # A redirection operator; a bare operator token also consumes its
            # target. `<<TAG` / `>file` (attached) consume only themselves.
            if t in (">", ">>", "<", ">&", "&>", "1>", "2>", "0<"):
                k += 2
            else:
                k += 1
            continue
        if re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", t):
            k += 1
            continue
        if t in _LINE_PREFIX_CMDS:
            prefix = t
            k += 1
            continue
        if t.startswith("-"):
            opts = _PREFIX_VALUE_OPTS.get(prefix, _EMPTY_FROZENSET)
            if "=" not in t and t in opts:
                k += 2  # value-taking option consumes the next token
            else:
                k += 1
            continue
        return t.rsplit("/", 1)[-1]
    return ""

def _line_command_words(line):
    # Command-word basenames of EVERY pipeline/list segment of a shell line
    # (#611 r11: a quoted heredoc piped into a shell — `cat <<'EOF' | bash` —
    # executes the body even though the FIRST command word is cat, so the
    # interpreter check must see the pipe target too). Split the
    # escape/quote-stripped line on top-level pipe/list operators and take
    # the command word of each segment. Backslash/quote-stripped first so an
    # escape-spelled command word is recognized (#611 r9).
    stripped = line.replace("\\", "").replace(_SQ, "").replace(_DQ, "")
    words = []
    for seg in re.split(r"\|\||&&|[|;&]", stripped):
        w = _segment_command_word(seg.split())
        if w:
            words.append(w)
    return words

def flatten_command(cmd, depth=0):
    """Normalize a command for shlex tokenization so the downstream walk
    sees every command-position gh write. Three jobs (#533, plus the #540
    Phase-4b findings):
      1. Replace UNQUOTED newlines AND shell separators (; | & && || |& ( ))
         with space-padded standalone tokens. shlex never splits on these,
         so without padding a `"foo";gh pr merge` or `$(...)`-glued `;`
         leaves a top-level guarded write fused to a data token and unseen.
      2. Extract $(...) and `...` command-substitution spans (with correct
         nested + independent-quote tracking) and append each as its own
         `; <span>` command segment, so a gh write that EXECUTES inside a
         substitution is surfaced. The outer keeps a placeholder token.
      3. Preserve quoted separators/newlines verbatim.
    Unbalanced quotes / unterminated substitutions raise ValueError -> the
    hook fails closed exactly like any other parse error."""
    if depth > 25:
        raise ValueError("command-substitution nesting too deep")
    out = []
    spans = []
    i = 0
    n = len(cmd)
    in_single = False
    in_double = False
    # cur_word tracks the text of the shell word being built (reset on
    # unquoted whitespace/separators, quotes kept in place) so a splice can
    # tell whether it lands inside an ASSIGNMENT word — bash does not
    # field-split a substitution in an assignment value, so whitespace
    # spliced there must be quoted to keep one token (#611 round 5:
    # X=$(printf "a b") $(printf gh) pr merge shifted command position).
    cur_word = ""
    # #611 round 8: a QUOTED-tag heredoc body is pure data — bash performs
    # no expansion in it and the receiving command just reads it — so its
    # lines must NOT be flattened into command segments (a fixture write
    # like cat with a quoted-tag heredoc containing an encoded substitution
    # was statically expanded and blocked). Bodies are skipped verbatim
    # UNLESS a shell interpreter appears on the heredoc line (a bash-fed
    # body executes as a script; keep scanning those, fail-closed).
    # Unquoted-tag heredocs keep the existing behavior: bash DOES expand
    # their substitutions, so scanning them is correct.
    pending_heredocs = []
    heredoc_count_line = 0
    line_start = 0

    def _splice(span, in_double_now):
        # Returns the text to append for a substitution span. Three cases:
        #   1. statically expandable literal printf/echo -> the expansion
        #      (quoted when whitespace lands inside an assignment word);
        #   2. literal printf/echo that CANNOT be expanded (%b and other
        #      decoder directives, format-reuse forms) -> a distinct
        #      fail-closed sentinel: such a span can synthesize an entire
        #      guarded write with zero outside evidence (#611 round 5);
        #   3. anything dynamic -> the ordinary placeholder + evidence scan.
        exp = _static_expand(span)
        if exp is not None:
            if in_double_now:
                # Inside double quotes the expansion is one word (no field
                # split), but it MUST still be spliced literally (#611 r14):
                # a quoted literal substitution reparsed by eval or bash -c
                # executes the expansion, so a placeholder would hide the
                # write. We are already inside the open double-quote context,
                # so emit the raw expansion glued in place.
                return exp
            if _ASSIGN_RE.match(cur_word) and (" " in exp):
                return _DQ + exp + _DQ
            # NO padding: the expansion must stay glued to adjacent text
            # exactly as bash glues it (G=$(printf gh) is ONE assignment
            # word `G=gh`, not an assignment plus a command).
            return exp
        spans.append(span)
        if not in_double_now and _is_literal_printf_echo(span):
            return " __MERGEPATH_CMDSUB_LITERAL__ "
        return " __MERGEPATH_CMDSUB__ "

    while i < n:
        c = cmd[i]
        if c == "\\" and not in_single and i + 1 < n:
            out.append(c)
            out.append(cmd[i + 1])
            cur_word += c + cmd[i + 1]
            i += 2
            continue
        if c == _SQ and not in_double:
            in_single = not in_single
            out.append(c)
            cur_word += c
            i += 1
            continue
        if c == _DQ and not in_single:
            in_double = not in_double
            out.append(c)
            cur_word += c
            i += 1
            continue
        # Command substitution is performed unquoted AND inside double
        # quotes, never inside single quotes.
        if not in_single and c == "$" and i + 1 < n and cmd[i + 1] == "(":
            span, j = _read_paren_span(cmd, i + 2)
            piece = _splice(span, in_double)
            out.append(piece)
            cur_word = "" if piece.endswith(" ") else cur_word + piece
            i = j
            continue
        if not in_single and c == chr(96):
            span, j = _read_backtick_span(cmd, i + 1)
            piece = _splice(span, in_double)
            out.append(piece)
            cur_word = "" if piece.endswith(" ") else cur_word + piece
            i = j
            continue
        if (not in_single and not in_double and c == "<" and i + 1 < n
                and cmd[i + 1] == "<" and (i + 2 >= n or cmd[i + 2] != "<")):
            # Heredoc operator (not a <<< herestring). A QUOTED-delimiter
            # heredoc (bash disables body expansion) queues the body for
            # verbatim skipping at the next newline; an UNQUOTED delimiter
            # keeps the raw operator text and the existing body scanning
            # (bash DOES expand unquoted-tag bodies, #611 r9).
            j = i + 2
            allow_tabs = False
            if j < n and cmd[j] == "-":
                allow_tabs = True
                j += 1
            while j < n and cmd[j] in (" ", "\t"):
                j += 1
            tag, quoted, k2 = _read_heredoc_delimiter(cmd, j)
            heredoc_count_line += 1
            if quoted and tag:
                pending_heredocs.append((tag, allow_tabs))
                out.append(" __MERGEPATH_HEREDOC__ ")
                cur_word = ""
                i = k2
                continue
            out.append(cmd[i:i + 2])
            cur_word += cmd[i:i + 2]
            i += 2
            continue
        if not in_single and not in_double:
            two = cmd[i:i + 2]
            if two in ("&&", "||", "|&"):
                out.append(" " + two + " ")
                cur_word = ""
                i += 2
                continue
            if c in (";", "|", "&", "(", ")"):
                out.append(" " + c + " ")
                cur_word = ""
                i += 1
                continue
            if c == "\n":
                out.append(" ; ")
                cur_word = ""
                line = cmd[line_start:i]
                i += 1
                # A quoted heredoc body is skipped as inert data ONLY when the
                # producer line is SIMPLE enough to model exactly (#611 r12):
                #   * every heredoc on the line is quoted (no unquoted-tag body
                #     whose substitutions bash DOES expand — cat <<A <<'B'),
                #   * no process substitution ( >(sh) / <(bash) feeds the body
                #     to a shell the pipeline scan cannot see), AND
                #   * no pipeline/list segment command word is a shell
                #     interpreter (cat <<'EOF' | bash runs the body, #611 r11;
                #     a shell name in a redirection target does NOT count, r10).
                # Any other shape fails closed: the bodies flow into the token
                # stream and are scanned, exactly as bash would execute them.
                line_simple = (
                    len(pending_heredocs) == heredoc_count_line
                    and not re.search(r"[<>]\(", line)
                    and not any(w in _LINE_INTERPRETERS
                                for w in _line_command_words(line)))
                if pending_heredocs and line_simple:
                    for _tag, _allow_tabs in pending_heredocs:
                        while i < n:
                            nl = cmd.find("\n", i)
                            body_line = cmd[i:] if nl == -1 else cmd[i:nl]
                            i = n if nl == -1 else nl + 1
                            chk = body_line.lstrip("\t") if _allow_tabs else body_line
                            if chk == _tag:
                                break
                pending_heredocs = []
                heredoc_count_line = 0
                line_start = i
                continue
            if c in (" ", "\t"):
                out.append(c)
                cur_word = ""
                i += 1
                continue
        out.append(c)
        cur_word += c
        i += 1
    if in_single or in_double:
        raise ValueError("unbalanced quote")
    result = "".join(out)
    for span in spans:
        result = result + " ; " + flatten_command(span, depth + 1)
    return result

# --- #533 item 1: surface inner commands hidden behind eval / sh -c ---
# eval "<payload>" and sh|bash|dash -c "<payload>" run <payload> as a
# fresh command line, but shlex keeps that payload as one opaque token,
# so the downstream walk never sees the inner gh write and SAW_GH stays
# 0 (the admin-merge bypass: eval/bash -c/sh -c forms passed rc=0).
# Re-tokenize those payloads here, recursively, so the walk evaluates
# the real inner gh write. Over-expansion is safe: the walk re-
# establishes command position on the expanded stream, so a quoted-data
# gh (echo "gh ...") is still not in command position. Malformed inner
# quoting raises ValueError, failing closed exactly like a top-level
# parse error.
_SEPARATORS = {"&&", "||", ";", "|", "|&", "&", "(", ")"}
_SHELL_BASENAMES = {"sh", "bash", "dash", "zsh", "ksh"}
_PREFIX_CMDS = {"sudo", "time", "nohup", "env", "command", "exec", "nice", "ionice"}
# The canonical gh wrappers run "<wrapper> -- <command>". Treat the wrapper
# (and the -- separator) as prefix-like so a "<wrapper> -- bash -c <gh write>"
# payload keeps command position and the inner gh write is surfaced and
# re-checked, not hidden behind the wrapper as an opaque shell-c token
# (#546 gap 1).
_WRAPPER_CMDS = {"gh-as-author.sh", "gh-as-reviewer.sh"}
# sh/bash options that consume the NEXT token as their value, so the -c
# command flag (and the script positional) lie AFTER that value. Skipping
# only the option (not its value) would mis-read the value as the script
# and miss a trailing -c (#540: bash --rcfile FILE -c "<payload>").
_SHELL_VALUE_OPTS = {"--rcfile", "--init-file", "-o", "+o", "-O", "+O"}
_ASSIGN_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=")
# Per-prefix options that consume the NEXT token as a value, so the value
# is not mistaken for the wrapped command. Read from the shared
# PREFIX_VALUE_OPTS_SPEC env var (#546) so THIS python table and the bash
# prefix_flag_takes_value table cannot drift. Per-prefix because the same
# letter differs by tool: nice -n N takes a value, but sudo -n is a
# no-value flag. A prefix not listed is treated as flags-only. Fail closed
# when the spec is absent: without it every prefix looks flags-only and a
# "value-opt VALUE" pair would be mis-read as the wrapped command, hiding a
# trailing bash -c gh-write.
_PREFIX_VALUE_OPTS = {}
_RAW_PREFIX_SPEC = os.environ.get("PREFIX_VALUE_OPTS_SPEC", "")
if not _RAW_PREFIX_SPEC:
    print("gh-pr-guard: PREFIX_VALUE_OPTS_SPEC unset", file=sys.stderr)
    sys.exit(1)
for _entry in _RAW_PREFIX_SPEC.split(";"):
    if not _entry:
        continue
    _pfx, _eq, _opts = _entry.partition("=")
    _PREFIX_VALUE_OPTS[_pfx] = frozenset(o for o in _opts.split(",") if o)
_EMPTY_FROZENSET = frozenset()

def expand_wrappers(tokens, depth=0):
    if depth > 25:
        raise ValueError("eval/shell -c nesting too deep")
    out = []
    i = 0
    n = len(tokens)
    at_cmd = True
    while i < n:
        tok = tokens[i]
        if tok in _SEPARATORS:
            out.append(tok)
            at_cmd = True
            i += 1
            continue
        if not at_cmd:
            out.append(tok)
            i += 1
            continue
        if _ASSIGN_RE.match(tok):
            out.append(tok)
            i += 1
            # NAME=$(...) is split by flatten_command into "NAME=" + the
            # __MERGEPATH_CMDSUB__ placeholder; re-attach the placeholder as the
            # assignment value so it does not read as "NAME= <command>" and let
            # a following prefix lose command position (Codex #551:
            # G=$(printf gh) env -S "${G} ..." must still reach the env -S
            # fail-closed branch). Only a trailing-"=" (empty-value) assignment
            # immediately followed by the placeholder is the flatten artifact.
            if tok.endswith("=") and i < n and tokens[i] in (
                    "__MERGEPATH_CMDSUB__", "__MERGEPATH_CMDSUB_LITERAL__"):
                out.append(tokens[i])
                i += 1
            continue
        base = tok.rsplit("/", 1)[-1]
        if base == "eval":
            # eval joins its args and parses the result as a command.
            j = i + 1
            while j < n and tokens[j] not in _SEPARATORS:
                j += 1
            inner = " ".join(tokens[i + 1:j])
            out.extend(expand_wrappers(shlex.split(flatten_command(inner)), depth + 1))
            i = j
            continue
        if base in _SHELL_BASENAMES:
            # sh|bash|dash -c "<payload>" runs <payload> as a command.
            seg_end = i + 1
            while seg_end < n and tokens[seg_end] not in _SEPARATORS:
                seg_end += 1
            inner = None
            k = i + 1
            while k < seg_end:
                t = tokens[k]
                # A value-taking option consumes the NEXT token; skip both so
                # the value is not mistaken for the script positional and a
                # trailing -c is still found (#540: bash --rcfile FILE -c CMD).
                if t in _SHELL_VALUE_OPTS:
                    k += 2
                    continue
                # A long option (--norc, --noprofile, --rcfile=FILE, ...) is
                # NOT the -c command-string flag even when it contains a c.
                # #540 finding 1: matching any "c in t" let --norc consume the
                # real -c as its payload and discard the command string.
                if t.startswith("--"):
                    k += 1
                    continue
                # A single-dash cluster including c IS the -c command flag
                # (-c, -lc, -xc, ...). The command is the text attached after
                # the c (-cCMD) or, failing that, the next token (-c CMD).
                if t.startswith("-") and "c" in t:
                    cpos = t.index("c", 1)
                    attached = t[cpos + 1:]
                    if attached:
                        inner = attached
                    elif k + 1 < seg_end:
                        inner = tokens[k + 1]
                    break
                if t.startswith("-"):
                    k += 1
                    continue
                break
            if inner is not None:
                out.extend(expand_wrappers(shlex.split(flatten_command(inner)), depth + 1))
            else:
                out.extend(tokens[i:seg_end])
            i = seg_end
            continue
        if base in _PREFIX_CMDS:
            out.append(tok)
            i += 1
            # Consume the options that belong to this prefix before the
            # wrapped command, keeping command position so a
            # <prefix> [opts] bash -c "<payload>" form is still expanded.
            # Value-taking options (sudo -u USER, nice -n N, ...) consume
            # their value too; env NAME=VALUE assignments are skipped. The
            # first shell / nested-prefix / eval / bare token is the wrapped
            # command, left for the main loop at command position. #540 P1:
            # a prefix option used to fall through and flip at_cmd off,
            # hiding a trailing bash -c gh-write.
            vopts = _PREFIX_VALUE_OPTS.get(base, _EMPTY_FROZENSET)
            while i < n:
                a = tokens[i]
                if a in _SEPARATORS:
                    break
                a_base = a.rsplit("/", 1)[-1]
                if a_base in _SHELL_BASENAMES or a_base in _PREFIX_CMDS or a_base == "eval":
                    break
                if _ASSIGN_RE.match(a):
                    out.append(a)
                    i += 1
                    continue
                # env -S STRING / --split-string STRING runs STRING as a SPLIT
                # command, so its argument is a NESTED command, not a value to
                # skip: re-tokenize + expand it so a "env -S bash -c <gh write>"
                # payload is surfaced (CodeRabbit #551, a pre-existing exotic
                # gap). Handles the next-token, --split-string=STR, and -SSTR
                # (attached) forms.
                if base == "env" and (a == "--split-string"
                                      or a.startswith("--split-string=")
                                      or (a.startswith("-") and not a.startswith("--")
                                          and next((c for c in a[1:] if c in "uCS"), "") == "S")):
                    # A short cluster IS env -S when the first value-taking-or-S
                    # option in it is S (CodeRabbit #551: -vS etc., not only a
                    # leading -S). -u/-C consume the rest of the cluster as their
                    # value, so an S inside e.g. -uNAME_WITH_S is NOT the split
                    # flag (keeps the #451 env -uNAME tests passing).
                    # env -S / --split-string FAILS CLOSED (Codex #551 r1-r4).
                    # GNU env -S has rich, exotic semantics: whitespace
                    # splitting, $VAR/${VAR} expansion, $(...)/backtick
                    # substitution (bash expands those first), AND appending the
                    # remaining argv after the split string (env -S "bash -c"
                    # "<payload>"). Each partial model we tried surfaced a new
                    # bypass, and env -S on a command line is an exotic shebang
                    # feature no gh workflow needs, so BLOCK any env -S rather
                    # than risk a hidden write. Reformulate without -S if needed.
                    raise ValueError("env -S / --split-string is not statically resolvable; reformulate without -S")
                if a in vopts:
                    out.append(a)
                    i += 1
                    if i < n and tokens[i] not in _SEPARATORS:
                        out.append(tokens[i])
                        i += 1
                    continue
                if a.startswith("-"):
                    out.append(a)
                    i += 1
                    continue
                break
            continue
        if base in _WRAPPER_CMDS:
            # Wrapper invocation (gh-as-author.sh / gh-as-reviewer.sh): keep
            # command position through the -- arg separator and any wrapper
            # flags so a trailing bash -c / sh -c / prefix / eval payload is
            # expanded by the main loop and the inner gh write is re-checked,
            # instead of running under the verified token without the
            # merge-state / CODEX_CLEARED gate (#546 gap 1). A normal
            # "<wrapper> -- gh pr merge" is unaffected (gh is not a shell to
            # expand), so this only matters when a shell/prefix follows.
            out.append(tok)
            i += 1
            while i < n:
                a = tokens[i]
                if a in _SEPARATORS:
                    break
                a_base = a.rsplit("/", 1)[-1]
                if (a_base in _SHELL_BASENAMES or a_base in _PREFIX_CMDS
                        or a_base in _WRAPPER_CMDS or a_base == "eval"):
                    break
                if a == "--" or a.startswith("-"):
                    out.append(a)
                    i += 1
                    continue
                break
            continue
        out.append(tok)
        at_cmd = False
        i += 1
    return out

try:
    cmd = sys.stdin.read()
    _IFS_TOUCHED = bool(re.search(r"(^|[^A-Za-z0-9_])IFS=", cmd))
    # #611 r14: decode ANSI-C quoting ($'...') across the WHOLE command
    # before flattening, so an ANSI-C-spelled command word ($'\147\150' pr
    # merge -> gh pr merge) is canonicalized for shlex, which does not
    # implement $'...' decoding. An undecodable string (one that would need a
    # bare single quote) leaves the command unchanged and falls to the
    # fail-closed tokenizer path.
    _ac, _ac_ok = _rewrite_ansi_c(cmd, None)
    if _ac_ok:
        cmd = _ac
    cmd = flatten_command(cmd)
    for tok in expand_wrappers(shlex.split(cmd)):
        sys.stdout.buffer.write(tok.encode("utf-8", errors="replace") + b"\x00")
except ValueError as e:
    print(f"shlex error: {e}", file=sys.stderr)
    sys.exit(1)
' > "$TMP_TOKENS" 2> "$TMP_TOKENS_ERR"; then
  # #611 round 4 (Codex P2): the broadened fast path tokenizes ANY command
  # carrying a substitution, including valid-but-unmodeled shell (e.g. a
  # heredoc body with an unbalanced quote) that this parser cannot
  # tokenize. Failing closed on those would turn the gh guard into a
  # blocker for unrelated shell work. Restore pre-broadening parity: a
  # parse failure with NO guarded-write evidence anywhere in the raw text
  # (no gh in stripped or octal/hex escape spelling, no env -S, no
  # pr/issue noun, no guarded verb) exits 0 exactly like the evidence-free
  # fast path always did. ANY evidence keeps the fail-closed block below.
  #
  # #611 round 6 (Codex P2): QUOTED-tag heredoc BODIES are data for the
  # receiving command (cat/tee templates legitimately contain shell-looking
  # text and guarded verbs), so they are excluded from the evidence probe —
  # UNLESS a shell interpreter appears outside the bodies (bash <<EOF
  # executes its body; keep full-text evidence there, matching the
  # pre-broadening behavior where a literal in-body gh blocked the parse
  # failure). #611 round 9: UNQUOTED-tag bodies are NOT stripped — bash
  # expands their command substitutions while building the heredoc, so an
  # in-body $(gh ...) executes and its evidence must keep failing closed.
  EVIDENCE_TEXT="$COMMAND"
  STRIPPED_TEXT=$(printf '%s\n' "$COMMAND" | awk '
    skip == 1 {
      line = $0
      sub(/^\t+/, "", line)
      if (line == tag) { skip = 0 }
      next
    }
    {
      print
      if (match($0, /<<-?[[:space:]]*["'\''][A-Za-z_][A-Za-z0-9_]*/)) {
        t = substr($0, RSTART, RLENGTH)
        sub(/<<-?[[:space:]]*["'\'']/, "", t)
        tag = t
        skip = 1
      }
    }')
  # `source` and the `.` builtin execute their input too (#611 r7:
  # `source /dev/stdin <<EOF` runs the body) — a standalone dot token is
  # probed as start-or-space + dot + space.
  if ! printf '%s\n' "$STRIPPED_TEXT" | tr -d "\"'\\\\" | grep -qE '(^|[^A-Za-z0-9_])(sh|bash|dash|zsh|ksh|eval|source)([^A-Za-z0-9_]|$)|(^|[[:space:]])\.[[:space:]]'; then
    EVIDENCE_TEXT="$STRIPPED_TEXT"
  fi
  if ! printf '%s\n' "$EVIDENCE_TEXT" | tr -d "\"'\\\\" | grep -qE '(^|[^A-Za-z0-9_])(([^[:space:]]*/)?gh|pr|issue|create|merge|comment|review|edit)([^A-Za-z0-9_]|$)' \
     && ! printf '%s\n' "$EVIDENCE_TEXT" | tr -d "\"'\\\\" | grep -qE '(^|[^A-Za-z0-9_])env([[:space:]]|$)' \
     && ! printf '%s\n' "$EVIDENCE_TEXT" | grep -qE '\\(147|150|107|110|x67|x68|x47|x48)'; then
    exit 0
  fi
  echo "BLOCKED: gh-pr-guard could not tokenize the gh command (malformed shell quoting)." >&2
  echo "  command: $COMMAND" >&2
  echo "  shlex error: $(cat "$TMP_TOKENS_ERR")" >&2
  echo "  Fix the quoting and retry, or use BREAK_GLASS_ADMIN=1 + --admin." >&2
  exit 2
fi
# Read NUL-delimited tokens from the tempfile. `read -d ''` means
# "read until NUL". Each iteration appends one whole token,
# preserving any embedded newlines.
TOKENS=()
while IFS= read -r -d '' tok; do
  TOKENS+=("$tok")
done < "$TMP_TOKENS"

# #348 defense: the main parser below intentionally identifies one
# `gh` invocation and then routes it through the existing per-command
# policy. That was enough for single commands, but a compound shell
# input could put an allow-listed `gh` first and a guarded write second
# (`gh issue close 1 && gh pr merge --admin 2`). The first command hit
# an allow-exit and the second write never reached the guard. Keep the
# per-command parser unchanged for normal commands, but fail closed when
# one Bash tool call contains multiple command-position gh invocations
# and any of them is a guarded write.
is_guard_separator() {
  case "$1" in
    "&&"|"||"|";"|"|"|"|&"|"&"|"("|")")
      return 0
      ;;
  esac
  return 1
}

prefix_flag_takes_value() {
  # Single source of truth: PREFIX_VALUE_OPTS_SPEC (#546). The python
  # pre-pass and this bash walk read the SAME spec, so the two prefix-option
  # tables cannot drift. The old hand-maintained case list HAD drifted: it
  # lacked the long forms the python table carried, so "sudo --user X bash
  # -c <gh write>" surfaced the inner gh in python but the bash compound
  # scan mis-read X as the command and never saw it. Spec: ";"-joined
  # "<prefix>=<opt>,<opt>,..." entries.
  local pfx="$1" opt="$2" spec opts o
  spec=";$PREFIX_VALUE_OPTS_SPEC"
  case "$spec" in
    *";$pfx="*) ;;
    *) return 1 ;;
  esac
  opts="${spec##*;$pfx=}"   # text after the (unique) ";<pfx>="
  opts="${opts%%;*}"        # up to the next prefix entry
  # Literal equality (NOT a case glob) so an attacker-supplied option token
  # such as "-*" cannot glob-match a real value-option and mis-skip the
  # following gh write.
  local IFS=,
  for o in $opts; do
    [ "$o" = "$opt" ] && return 0
  done
  return 1
}

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_REPO_ROOT="$(cd "$HOOK_DIR/../.." && pwd)"

# Locate the governing review-policy.yml without trusting the caller's
# cwd to BE the repo root (Codex P2 on PR #442 r21): walk upward from
# the cwd (covers subdirectory invocations and out-of-tree fixture
# repos), then fall back to the hook's own repo root (the hook is
# installed at <root>/scripts/hooks/, so script root == project root
# in production). Echoes the path or nothing.
guard_policy_file() {
  local d="$PWD"
  while [ -n "$d" ] && [ "$d" != "/" ]; do
    if [ -f "$d/.github/review-policy.yml" ]; then
      printf '%s\n' "$d/.github/review-policy.yml"
      return 0
    fi
    d="$(dirname "$d")"
  done
  if [ -f "$GUARD_REPO_ROOT/.github/review-policy.yml" ]; then
    printf '%s\n' "$GUARD_REPO_ROOT/.github/review-policy.yml"
    return 0
  fi
  return 1
}
REPO_ROOT="$(cd "$HOOK_DIR/../.." && pwd)"
CANON_AUTHOR_WRAPPER="$REPO_ROOT/scripts/gh-as-author.sh"
CANON_REVIEWER_WRAPPER="$REPO_ROOT/scripts/gh-as-reviewer.sh"

is_author_wrapper_token() {
  [ "$1" = "scripts/gh-as-author.sh" ] || \
    [ "$1" = "./scripts/gh-as-author.sh" ] || \
    [ "$1" = "$CANON_AUTHOR_WRAPPER" ]
}

is_reviewer_wrapper_token() {
  [ "$1" = "scripts/gh-as-reviewer.sh" ] || \
    [ "$1" = "./scripts/gh-as-reviewer.sh" ] || \
    [ "$1" = "$CANON_REVIEWER_WRAPPER" ]
}

is_any_wrapper_named_token() {
  case "$1" in
    */gh-as-author.sh|gh-as-author.sh|*/gh-as-reviewer.sh|gh-as-reviewer.sh)
      return 0
      ;;
  esac
  return 1
}

# guarded_gh_invocation_label INDEX [MODE]
#
# Scan forward from INDEX for a guarded pr/issue write and print its label.
# MODE picks the fail-closed posture for __MERGEPATH_CMDSUB__ placeholders in
# the subcommand stream (#611 round 3):
#
#   strict   (default; INDEX is a LITERAL `gh`): the executable is known to be
#            gh, so a substitution in noun or verb position can expand to any
#            subcommand — including a guarded write (`gh $(x) 123` runs
#            `gh pr merge 123` when x prints the noun AND verb). No literal
#            evidence can decide it; fail closed on the placeholder itself.
#   evidence (INDEX is a command-position placeholder in the _synth_ walk):
#            the executable itself is unproven, so placeholders alone cannot
#            block (`$(cc) $(cflags) -o out` is benign). Placeholders are
#            TRANSPARENT — they may expand to nothing (`$(true)`), the exe, or
#            the noun — and the scan keeps looking for literal guarded
#            evidence past them: a literal `pr`/`issue` noun reached across a
#            placeholder run, a literal guarded verb after it, or a bare
#            guarded verb with the noun synthesized. A literal noun followed
#            by a placeholder in VERB position also fails closed (the verb is
#            unverifiable on a plausible gh-noun: `$(a) pr $(b) 123`).
guarded_gh_invocation_label() {
  local gh_index="$1"
  local mode="${2:-strict}"
  local parent=""
  local skip_global_as=""
  local saw_ph=0
  local k
  local tok

  for k in "${!TOKENS[@]}"; do
    if [ "$k" -le "$gh_index" ]; then
      continue
    fi

    tok="${TOKENS[$k]}"
    if is_guard_separator "$tok"; then
      return 1
    fi

    if [ "$skip_global_as" = "repo" ]; then
      skip_global_as=""
      continue
    fi

    if [ -z "$parent" ]; then
      case "$tok" in
        __MERGEPATH_CMDSUB__|__MERGEPATH_CMDSUB_LITERAL__)
          if [ "$mode" = "strict" ]; then
            # Literal gh + unverifiable subcommand stream: the substitution
            # may synthesize `pr merge` wholesale. Fail closed.
            printf 'gh <unverifiable command substitution in subcommand position>\n'
            return 0
          fi
          saw_ph=1
          continue
          ;;
        pr|issue)
          parent="$tok"
          continue
          ;;
        create|merge|comment|review|edit)
          if [ "$saw_ph" -eq 1 ]; then
            # Guarded verb reached across a placeholder run with no literal
            # noun: the noun (and possibly the exe) was synthesized —
            # `$(printf '\147\150') $(printf '\160\162') merge` (#611 round 3).
            printf 'gh <synthesized> %s\n' "$tok"
            return 0
          fi
          return 1
          ;;
        -R|--repo)
          skip_global_as="repo"
          continue
          ;;
        -R=*|--repo=*)
          continue
          ;;
        -*)
          continue
          ;;
        *)
          return 1
          ;;
      esac
    fi

    case "$tok" in
      __MERGEPATH_CMDSUB__|__MERGEPATH_CMDSUB_LITERAL__)
        # Literal pr/issue noun with a substitution in VERB position: the verb
        # is unverifiable (`gh pr $(printf '\155...')  123` / `$(a) pr $(b)`).
        # Fail closed in both modes — the noun is literal guarded evidence.
        printf 'gh %s <synthesized verb>\n' "$parent"
        return 0
        ;;
      -R|--repo)
        skip_global_as="repo"
        continue
        ;;
      -R=*|--repo=*)
        continue
        ;;
      -*)
        continue
        ;;
    esac

    case "$parent:$tok" in
      pr:create|pr:merge|pr:comment|pr:review|pr:edit)
        printf 'gh pr %s\n' "$tok"
        return 0
        ;;
      issue:comment)
        printf 'gh issue comment\n'
        return 0
        ;;
      *)
        return 1
        ;;
    esac
  done

  return 1
}

# #573: a command substitution in COMMAND position can synthesize BOTH the
# executable AND the noun (e.g. $(printf '\147\150\40\160\162') -> `gh pr`), so
# after flattening the __MERGEPATH_CMDSUB__ placeholder is followed directly by
# a bare gh-write VERB (`merge`, `create`, ...) with NO literal `pr`/`issue`
# token in between. guarded_gh_invocation_label needs that `pr`/`issue` parent,
# so it returns "not guarded" for this shape. This companion recognizes a
# placeholder whose first significant (non-flag) token is a gh-write verb and
# reports it as a guarded write. Only ever consulted for the cmdsub placeholder
# in the _synth_ command-position pass (NEVER for a literal `gh`, where a bare
# verb like `gh auth login` is not a pr/issue write) — so it does not widen the
# literal-gh compound scan. Global -R/--repo (value + = forms) and any other
# -flag before the verb are skipped, mirroring guarded_gh_invocation_label; a
# separator ends the search (return 1).
synth_cmdsub_write_label() {
  local ph_index="$1"
  local skip_global_as=""
  local k
  local tok

  for k in "${!TOKENS[@]}"; do
    if [ "$k" -le "$ph_index" ]; then
      continue
    fi

    tok="${TOKENS[$k]}"
    if is_guard_separator "$tok"; then
      return 1
    fi

    if [ "$skip_global_as" = "repo" ]; then
      skip_global_as=""
      continue
    fi

    case "$tok" in
      -R|--repo)
        skip_global_as="repo"
        continue
        ;;
      -R=*|--repo=*)
        continue
        ;;
      -*)
        continue
        ;;
    esac

    # First significant non-flag token. A synthesized `gh pr` / `gh issue`
    # leaves a bare write verb here. `comment` covers both `gh pr comment`
    # and `gh issue comment`; either way it is a guarded write, so blocking
    # is the fail-closed answer.
    case "$tok" in
      create|merge|comment|review|edit)
        printf 'gh <synthesized> %s\n' "$tok"
        return 0
        ;;
      *)
        return 1
        ;;
    esac
  done

  return 1
}

# #553 / #560: a command substitution in COMMAND position can synthesize the
# executable name ($(printf '\147\150') -> gh), so the flattened
# __MERGEPATH_CMDSUB__ placeholder sits where the command name belongs and the
# literal-`gh` detection below misses it entirely. A single forward pass tracks
# command position exactly as the main walk does — through prefix commands and
# their boolean / value-taking flags (`prefix_flag_takes_value`) and
# env-assignment prefixes — so a placeholder reached AT command position AND
# directly followed by a guarded pr/issue write fails closed, even after
# `command -p`, `env -i`, `env -u NAME`, or a quoted assignment (`FOO="a b"`)
# (#560). A placeholder consumed as a value-taking flag's argument, or as a bare
# assignment's VALUE (`X=$(gh pr merge)` lifts the real write into a later
# ;-segment, #540), is NOT flagged; the main gh walk still catches any real write
# lifted out of the substitution. Keeping this OUT of the main walk (no SAW_GH)
# avoids the assignment-substitution command-position ambiguity.
_synth_cp=1
_synth_skip_val=0
_synth_prefix=""
for _ci in "${!TOKENS[@]}"; do
  _stok="${TOKENS[$_ci]}"
  if is_guard_separator "$_stok"; then
    _synth_cp=1
    _synth_skip_val=0
    _synth_prefix=""
    continue
  fi
  if [ "$_synth_skip_val" -eq 1 ]; then
    _synth_skip_val=0
    continue
  fi
  if [ "$_synth_cp" -eq 0 ]; then
    continue
  fi
  case "$_stok" in
    __MERGEPATH_CMDSUB_LITERAL__)
      # #611 round 5: a command-position literal printf/echo that could NOT
      # be statically expanded (%b and other decoder directives, format-reuse
      # forms) can synthesize an ENTIRE guarded write with zero outside
      # evidence — the exact class the static expander decides for %s-only
      # spans. Unconditional fail closed.
      echo "BLOCKED: command-position printf/echo substitution could not be statically verified (#611)." >&2
      echo "  A literal printf with a decoder directive (e.g. %b) can synthesize a full gh write" >&2
      echo "  with no literal evidence outside the substitution. Rewrite without the substitution" >&2
      echo "  in command position, or run the write through the token-verifying wrapper:" >&2
      echo "    scripts/gh-as-author.sh -- gh ..." >&2
      echo "    scripts/gh-as-reviewer.sh -- gh ..." >&2
      exit 2
      ;;
    __MERGEPATH_CMDSUB__)
      # Synthesis shapes, all fail closed:
      #   (a) exe synthesized, noun literal:  $(printf gh) pr merge
      #       -> guarded_gh_invocation_label sees `pr merge` after the placeholder.
      #   (b) exe AND noun synthesized:        $(printf 'gh pr') merge   (#573)
      #       -> no literal `pr`/`issue`; synth_cmdsub_write_label sees the bare
      #          write verb (`merge`) directly after the placeholder.
      #   (c) exe and noun split across a placeholder RUN (#611 round 3):
      #       $(printf '\147\150') $(printf '\160\162') merge
      #       -> evidence mode treats placeholders as transparent and blocks on
      #          the literal guarded verb (or literal noun + synthesized verb)
      #          reached across the run.
      if _synth_label=$(guarded_gh_invocation_label "$_ci" evidence) \
         || _synth_label=$(synth_cmdsub_write_label "$_ci"); then
        echo "BLOCKED: command-position command substitution may synthesize a gh write ($_synth_label)." >&2
        echo "  A \$(...) or backtick in command position can produce the executable name" >&2
        echo "  (e.g. \$(printf '\\147\\150') -> gh) AND the noun (e.g. \$(printf '\\147\\150\\40\\160\\162') -> gh pr)," >&2
        echo "  so the guard cannot verify it. Run the write directly through the verifying wrapper instead:" >&2
        echo "    scripts/gh-as-author.sh -- gh ..." >&2
        echo "    scripts/gh-as-reviewer.sh -- gh ..." >&2
        exit 2
      fi
      # In command position but NOT followed by a guarded write (e.g. `$(date)`,
      # or `X=$(gh pr merge)` whose real write is lifted past a `;`): treat the
      # placeholder as the command and skip its arguments.
      _synth_cp=0
      continue
      ;;
    [A-Za-z_]*=)
      # Bare assignment `NAME=`: the NEXT token is its VALUE (e.g. `X=$(...)`),
      # not a command — consume it so a placeholder-as-value is not mis-read.
      _synth_skip_val=1
      continue
      ;;
    [A-Za-z_]*=*)
      # Env-assignment prefix WITH an inline value (`FOO=1`, `FOO="a b"`): the
      # real command (which may be a synth cmdsub) follows — stay command position.
      continue
      ;;
    sudo|eval|time|nohup|env|command|exec|nice|ionice)
      _synth_prefix="$_stok"
      continue
      ;;
    -*)
      # Flag of the current prefix command. A value-taking flag (`env -u NAME`,
      # `sudo -u USER`) consumes the NEXT token as its value; a boolean flag
      # (`command -p`, `env -i`) does not — either way we stay command position.
      if prefix_flag_takes_value "$_synth_prefix" "$_stok"; then
        _synth_skip_val=1
      fi
      continue
      ;;
    *)
      # A real (non-gh) command — its arguments are not command position.
      _synth_cp=0
      continue
      ;;
  esac
done

COMPOUND_GH_COUNT=0
COMPOUND_GUARDED_COUNT=0
COMPOUND_GUARDED_EXAMPLES=""
SCAN_AT_COMMAND_POSITION=1
SCAN_SKIP_PREFIX_VALUE=0
SCAN_CURRENT_PREFIX=""
for i in "${!TOKENS[@]}"; do
  tok="${TOKENS[$i]}"

  if is_guard_separator "$tok"; then
    SCAN_AT_COMMAND_POSITION=1
    SCAN_SKIP_PREFIX_VALUE=0
    SCAN_CURRENT_PREFIX=""
    continue
  fi

  if [ "$SCAN_SKIP_PREFIX_VALUE" -eq 1 ]; then
    SCAN_SKIP_PREFIX_VALUE=0
    continue
  fi

  if [ "$SCAN_AT_COMMAND_POSITION" -eq 0 ]; then
    continue
  fi

  case "$tok" in
    [A-Za-z_]*=)
      # Bare assignment (#611 r9): a flattened X=$(...) leaves X= followed
      # by a PLACEHOLDER that is really the assignment VALUE — consume it
      # and stay in command position, so a following spliced gh write is
      # scanned as the command (FOO=$(date) $(printf gh) pr merge). Any
      # OTHER next token means a genuinely EMPTY assignment (X= cmd) whose
      # next token IS the command — do not consume it.
      case "${TOKENS[$((i+1))]:-}" in
        __MERGEPATH_CMDSUB__|__MERGEPATH_CMDSUB_LITERAL__)
          SCAN_SKIP_PREFIX_VALUE=1
          ;;
      esac
      continue
      ;;
    [A-Za-z_]*=*)
      continue
      ;;
    sudo|eval|time|nohup|env|command|exec|nice|ionice)
      SCAN_CURRENT_PREFIX="$tok"
      continue
      ;;
    *)
      if is_author_wrapper_token "$tok" || is_reviewer_wrapper_token "$tok"; then
        SCAN_CURRENT_PREFIX="$tok"
        continue
      fi
      ;;
  esac

  case "$tok" in
    -*)
      if prefix_flag_takes_value "$SCAN_CURRENT_PREFIX" "$tok"; then
        SCAN_SKIP_PREFIX_VALUE=1
      fi
      continue
      ;;
    gh|*/gh)
      COMPOUND_GH_COUNT=$((COMPOUND_GH_COUNT + 1))
      if guarded_label=$(guarded_gh_invocation_label "$i"); then
        COMPOUND_GUARDED_COUNT=$((COMPOUND_GUARDED_COUNT + 1))
        if [ -z "$COMPOUND_GUARDED_EXAMPLES" ]; then
          COMPOUND_GUARDED_EXAMPLES="$guarded_label"
        elif ! printf '%s\n' "$COMPOUND_GUARDED_EXAMPLES" | grep -Fxq "$guarded_label"; then
          COMPOUND_GUARDED_EXAMPLES="${COMPOUND_GUARDED_EXAMPLES}
$guarded_label"
        fi
      fi
      SCAN_AT_COMMAND_POSITION=0
      continue
      ;;
    *)
      SCAN_AT_COMMAND_POSITION=0
      continue
      ;;
  esac
done

if [ "$COMPOUND_GH_COUNT" -gt 1 ] && [ "$COMPOUND_GUARDED_COUNT" -gt 0 ]; then
  echo "BLOCKED: compound gh command contains a guarded write (#348)." >&2
  echo "  Detected $COMPOUND_GH_COUNT command-position gh invocations in one Bash call." >&2
  echo "  Guarded write(s) present:" >&2
  printf '%s\n' "$COMPOUND_GUARDED_EXAMPLES" | sed 's/^/    - /' >&2
  echo "  Split this into separate Bash tool calls so gh-pr-guard can evaluate each gh write independently." >&2
  exit 2
fi

# --- detect the pr subcommand, capturing any global -R/--repo ---
#
# Walk tokens to find `gh` IN COMMAND POSITION, then identify the
# subcommand and any global -R/--repo. The pre-gh walk runs as a
# small state machine so we don't blindly skip ANY pre-gh token —
# round 5 had that bug, and nathanpayne-codex caught that
# `echo gh pr merge 66` and `printf %s gh pr merge 66` were treated
# as real merges.
#
# State machine:
#
#   AT_COMMAND_POSITION (initial state):
#     The next token is either the command name or a continuation
#     that keeps us in command position. Allowed continuations:
#       - env assignments         VAR=value
#       - prefix commands         sudo, eval, time, nohup, env,
#                                 command, exec, nice, ionice
#       - flags of those prefixes -X
#       - compound separators     ;  &&  ||  |  |&  &  (
#       - gh                      → transition to phase 2
#     Any other token is treated as the START of a non-gh command,
#     and we transition to IN_UNRELATED_ARGS to skip its arguments.
#
#   IN_UNRELATED_ARGS:
#     We're walking the arguments of a non-gh command. Skip
#     everything until we hit a compound separator, at which point
#     we're back in command position. End-of-input without finding
#     gh in command position falls through to the post-walk check
#     and exits 0.
#
# Tokens BEFORE `gh` (in either state) that match an env assignment
# pattern are also captured into INLINE_CODEX_CLEARED /
# INLINE_BREAK_GLASS_ADMIN, even when in IN_UNRELATED_ARGS — the
# inline-env-prefix support from round 5 should keep working
# regardless of whether the env assignment turns out to be for a
# gh command or some other command. (Capturing for non-gh commands
# is harmless: the EFFECTIVE_* values are only consulted by the
# create/merge guards, which only run when SAW_GH=1.)
#
# Tokens BETWEEN `gh` and `pr` (and parent-level tokens between
# `pr`/`issue` and the subcommand) may contain inherited gh flags. The
# only value-taking flag we explicitly handle is -R/--repo; everything
# else starting with - is assumed boolean and skipped.
INLINE_CODEX_CLEARED=""
INLINE_BREAK_GLASS_ADMIN=""
INLINE_BREAK_GLASS_MERGE_STATE=""
INLINE_GH_AS_AUTHOR_IDENTITY=""
INLINE_GH_AS_REVIEWER_IDENTITY=""
# Standalone (own-segment) identity assignments persist as shell
# variables and — when the name already carries the export attribute in
# the calling shell — ALSO reach later processes. The hook cannot see
# the export attribute, so these are tracked separately as
# possibly-effective candidates that the byline guards must validate
# alongside the environment value (fail closed on the ambiguity).
# Codex P1 on PR #442 r4.
STANDALONE_GH_AS_AUTHOR_IDENTITY=""
STANDALONE_GH_AS_REVIEWER_IDENTITY=""
# Set-ness flags: an EMPTY assignment (`GH_AS_AUTHOR_IDENTITY= wrapper`)
# is NOT absent — it resets the wrapper to its hardcoded default, which
# in a custom-author repo differs from the expected author (Codex P1 on
# PR #442 r15). Every capture records both the value and that an
# assignment happened.
INLINE_GH_AS_AUTHOR_IDENTITY_SET=0
INLINE_GH_AS_REVIEWER_IDENTITY_SET=0
STANDALONE_GH_AS_AUTHOR_IDENTITY_SET=0
STANDALONE_GH_AS_REVIEWER_IDENTITY_SET=0
GLOBAL_REPO=""
PR_SUBCOMMAND=""
PR_SUBCOMMAND_INDEX=-1    # index in TOKENS where the gh pr subcommand was found
WRAPPER_KIND=""           # "" | "author" | "reviewer"
SAW_GH=0
SAW_PR=0
SAW_ISSUE=0
SKIP_GLOBAL_AS=""        # "" | "repo"
AT_COMMAND_POSITION=1    # 1 = at command position, 0 = walking unrelated-command args
SEGMENT_HAS_COMMAND=0    # 1 = this segment has seen a non-assignment command (echo, cat, etc.)
SKIP_PREFIX_VALUE=0      # 1 = next token is the value of a prefix-command flag
CURRENT_PREFIX=""        # name of the most recently seen prefix command (sudo/time/etc.)
IN_EXPORT_SEGMENT=0      # 1 = current segment is an `export` command (its
                         # assignment args reach all later processes)
SEGMENT_HAS_EVAL=0       # 1 = current segment ran `eval` — an eval'd
                         # assignment persists like a bare standalone
PENDING_PREFIX_FLAG=""   # "<prefix>:<flag>" whose value the next token is
                         # (lets the consumer recognize `env -u NAME`)
IDENTITY_ENV_CLEARED_FOR_WRAPPER=0  # 1 = env -i seen: the wrapper sees an
                         # EMPTY environment (no MERGEPATH_AGENT either)

# #611 round 3: a substitution in a LITERAL gh's subcommand stream can
# synthesize the noun, the verb, or a whole guarded write — `gh $(printf
# '\160\162') merge`, `gh pr $(printf '\155...')`, `gh $(true) pr merge`
# (empty expansion shifts the literal tokens into place). No literal evidence
# can classify it, so the walk below fails closed the moment a placeholder
# appears between gh and its resolved subcommand.
block_cmdsub_in_gh_stream() {
  echo "BLOCKED: unverifiable command substitution inside a gh command (#611)." >&2
  echo "  A \$(...) or backtick between gh and its subcommand can synthesize the" >&2
  echo "  noun or verb of a guarded write (e.g. gh \$(printf '\\160\\162') merge)," >&2
  echo "  so the guard cannot classify this invocation. Use literal gh" >&2
  echo "  subcommands, and run writes through the token-verifying wrapper:" >&2
  echo "    scripts/gh-as-author.sh -- gh ..." >&2
  echo "    scripts/gh-as-reviewer.sh -- gh ..." >&2
  exit 2
}

for i in "${!TOKENS[@]}"; do
  tok="${TOKENS[$i]}"
  # --- phase 2: walking after gh, looking for pr + subcommand ---
  if [ "$SAW_GH" -eq 1 ]; then
    if [ "$SKIP_GLOBAL_AS" = "repo" ]; then
      # #611 r14: a command substitution as the -R/--repo VALUE
      # (gh pr -R $(cat file) 1) is unverifiable — bash word-splits the
      # substitution output, so it can inject additional argv including a
      # guarded verb (-R "owner/repo merge" -> ... merge ...). Fail closed
      # rather than swallow the placeholder as an opaque repo value.
      if [ "$tok" = "__MERGEPATH_CMDSUB__" ] || [ "$tok" = "__MERGEPATH_CMDSUB_LITERAL__" ]; then
        block_cmdsub_in_gh_stream
      fi
      GLOBAL_REPO="$tok"
      SKIP_GLOBAL_AS=""
      continue
    fi
    if [ "$SAW_PR" -eq 0 ] && [ "$SAW_ISSUE" -eq 0 ]; then
      case "$tok" in
        pr)
          SAW_PR=1
          continue
          ;;
        issue)
          # We only guard `gh issue comment`; other gh issue
          # subcommands fall through to allow. Track that we saw
          # `issue` so the next iteration captures the subcommand.
          SAW_ISSUE=1
          continue
          ;;
        -R|--repo)
          SKIP_GLOBAL_AS="repo"
          continue
          ;;
        -R=*)
          GLOBAL_REPO="${tok#-R=}"
          continue
          ;;
        --repo=*)
          GLOBAL_REPO="${tok#--repo=}"
          continue
          ;;
        -*)
          # Unknown global flag — assume boolean (--help,
          # --version, etc.) and skip. See "Limitations" in the
          # header for the caveat about future value-taking
          # globals.
          continue
          ;;
        __MERGEPATH_CMDSUB__|__MERGEPATH_CMDSUB_LITERAL__)
          # Placeholder in NOUN position (#611 r3): fail closed.
          block_cmdsub_in_gh_stream
          ;;
        *)
          # Non-flag, non-pr, non-issue token before the parent. Either
          # gh aliases are in play (out of scope) or this is a gh
          # subcommand we don't guard (repo, workflow, etc.). Allow.
          exit 0
          ;;
      esac
    fi
    # SAW_PR=1 OR SAW_ISSUE=1 — parent-level gh flags may still
    # appear before the subcommand, e.g. `gh pr -R owner/repo merge`.
    case "$tok" in
      -R|--repo)
        SKIP_GLOBAL_AS="repo"
        continue
        ;;
      -R=*)
        GLOBAL_REPO="${tok#-R=}"
        continue
        ;;
      --repo=*)
        GLOBAL_REPO="${tok#--repo=}"
        continue
        ;;
      -*)
        continue
        ;;
    esac

    # SAW_PR=1 OR SAW_ISSUE=1 — this token IS the subcommand.
    if [ "$tok" = "__MERGEPATH_CMDSUB__" ] || [ "$tok" = "__MERGEPATH_CMDSUB_LITERAL__" ]; then
      # Placeholder in VERB position (#611 r3): `gh pr $(...) 123` executes
      # whatever the substitution yields as the subcommand. Fail closed.
      block_cmdsub_in_gh_stream
    fi
    PR_SUBCOMMAND="$tok"
    PR_SUBCOMMAND_INDEX=$i
    break
  fi

  # --- phase 1: walking pre-gh, looking for gh in command position ---

  # Consume the value of a prefix-command flag (e.g. the `user`
  # in `sudo -u user gh ...`). Stays in command position because
  # the prefix command may have additional flags or transition
  # straight to the actual command.
  if [ "$SKIP_PREFIX_VALUE" -eq 1 ]; then
    SKIP_PREFIX_VALUE=0
    # `env -u NAME` removes NAME from the wrapped command's
    # environment: for the identity variables that is exactly the
    # r15 empty-override semantics — the wrapper falls back to its
    # hardcoded default, which a custom-author repo must fail closed
    # on (Codex P2 on PR #442 r17, env --help verified).
    if [ "$PENDING_PREFIX_FLAG" = "env:-u" ] || [ "$PENDING_PREFIX_FLAG" = "env:--unset" ]; then
      case "$tok" in
        GH_AS_AUTHOR_IDENTITY)
          INLINE_GH_AS_AUTHOR_IDENTITY=""
          INLINE_GH_AS_AUTHOR_IDENTITY_SET=1
          ;;
        GH_AS_REVIEWER_IDENTITY)
          INLINE_GH_AS_REVIEWER_IDENTITY=""
          INLINE_GH_AS_REVIEWER_IDENTITY_SET=1
          ;;
      esac
    fi
    PENDING_PREFIX_FLAG=""
    continue
  fi

  # Compound separators always reset us to command position,
  # whether we were in command position or skipping unrelated
  # args. Only standalone `&&` / `||` / `;` / `|` / `&` / `(`
  # tokens count — separators glommed onto adjacent words by
  # missing whitespace (e.g. `foo;`) are NOT detected, which is
  # an acceptable limitation for the agent flow.
  #
  # IMPORTANT: separator handling MUST run before the env-assignment
  # capture below. Otherwise `echo CODEX_CLEARED=1 ; gh pr merge 65`
  # would capture the literal `CODEX_CLEARED=1` arg of `echo` as a
  # spoofed inline env var even though it never actually gets exported
  # to the gh process. nathanpayne-codex caught this on swipewatch
  # propagation PR #33 round 5 — privilege escalation potential.
  case "$tok" in
    "&&"|"||"|";"|"|"|"|&"|"&"|"("|")")
      AT_COMMAND_POSITION=1
      CURRENT_PREFIX=""
      WRAPPER_KIND=""
      IN_EXPORT_SEGMENT=0
      # Clear inline env vars ONLY when the segment that just ended
      # contained a non-assignment command. That means the assignment
      # was a PREFIX scoped to that command, not a standalone
      # assignment that persists in the shell:
      #
      #   BREAK_GLASS_ADMIN=1 echo ok ; gh pr merge --admin 65
      #     → segment had `echo` (SEGMENT_HAS_COMMAND=1)
      #     → assignment was prefix to echo → CLEAR at `;`
      #
      #   CODEX_CLEARED=1 && gh pr merge 76 --squash
      #     → segment was ONLY the assignment (SEGMENT_HAS_COMMAND=0)
      #     → standalone assignment → DON'T clear at `&&`
      #
      # nathanpayne-codex caught the over-clearing on template PR #76
      # round 1 — `CODEX_CLEARED=1 && gh pr merge` was being cleared
      # even though the assignment was standalone.
      if [ "$SEGMENT_HAS_COMMAND" -eq 1 ]; then
        INLINE_CODEX_CLEARED=""
        INLINE_BREAK_GLASS_ADMIN=""
        INLINE_BREAK_GLASS_MERGE_STATE=""
      fi
      # Identity assignments: their consumer is the WRAPPER process
      # environment, not this hook, and what survives a separator
      # depends on HOW the assignment appeared (Codex P2s/P1 on PR
      # #442 r1/r3/r4):
      #   - PREFIX to an earlier command (`VAR=x echo ok ; wrapper`):
      #     the shell restores the variable after that command —
      #     provably ineffective for later segments. Drop it, or a
      #     stale value falsely blocks later wrapper writes (r1).
      #   - STANDALONE (`VAR=x ; wrapper` / `VAR=x && wrapper`): the
      #     value persists as a shell variable, and IF the name
      #     already carries the export attribute in the calling shell
      #     it also reaches the wrapper (r4). The hook cannot see the
      #     export attribute, so the value is stashed as a
      #     possibly-effective candidate that the byline guards
      #     validate IN ADDITION to the environment/default value —
      #     fail closed on the ambiguity (this also covers r3, where
      #     an unexported standalone value would have masked the
      #     wrapper falling back to its stock default).
      if [ "$SEGMENT_HAS_COMMAND" -eq 0 ] || [ "${SEGMENT_HAS_EVAL:-0}" -eq 1 ]; then
        # Bare standalone segment, or an eval segment — in both, a
        # captured assignment persists past the separator (eval'd
        # assignments are standalone-equivalent; assignments that
        # were prefixes TO the eval are over-captured on purpose,
        # the fail-closed direction).
        if [ "$INLINE_GH_AS_AUTHOR_IDENTITY_SET" -eq 1 ]; then
          STANDALONE_GH_AS_AUTHOR_IDENTITY="$INLINE_GH_AS_AUTHOR_IDENTITY"
          STANDALONE_GH_AS_AUTHOR_IDENTITY_SET=1
        fi
        if [ "$INLINE_GH_AS_REVIEWER_IDENTITY_SET" -eq 1 ]; then
          STANDALONE_GH_AS_REVIEWER_IDENTITY="$INLINE_GH_AS_REVIEWER_IDENTITY"
          STANDALONE_GH_AS_REVIEWER_IDENTITY_SET=1
        fi
      fi
      SEGMENT_HAS_EVAL=0
      INLINE_GH_AS_AUTHOR_IDENTITY=""
      INLINE_GH_AS_REVIEWER_IDENTITY=""
      INLINE_GH_AS_AUTHOR_IDENTITY_SET=0
      INLINE_GH_AS_REVIEWER_IDENTITY_SET=0
      SEGMENT_HAS_COMMAND=0
      continue
      ;;
  esac

  # Capture inline env assignments ONLY when AT_COMMAND_POSITION=1.
  # Tokens in IN_UNRELATED_ARGS are arguments to an unrelated
  # command (e.g., `echo BREAK_GLASS_ADMIN=1 ; gh pr merge --admin
  # 65`) and do NOT export to the spawned gh process — capturing
  # them would let an agent spoof guard variables by prefixing the
  # command with an echo. Only assignments that are themselves in
  # command position (e.g., `CODEX_CLEARED=1 gh pr merge 65` or
  # `CODEX_CLEARED=1 sudo gh pr merge 65`) count.
  if [ "$AT_COMMAND_POSITION" -eq 1 ]; then
    case "$tok" in
      CODEX_CLEARED=*)
        INLINE_CODEX_CLEARED="${tok#CODEX_CLEARED=}"
        ;;
      BREAK_GLASS_ADMIN=*)
        INLINE_BREAK_GLASS_ADMIN="${tok#BREAK_GLASS_ADMIN=}"
        ;;
      BREAK_GLASS_MERGE_STATE=*)
        INLINE_BREAK_GLASS_MERGE_STATE="${tok#BREAK_GLASS_MERGE_STATE=}"
        ;;
      GH_AS_AUTHOR_IDENTITY=*)
        INLINE_GH_AS_AUTHOR_IDENTITY="${tok#GH_AS_AUTHOR_IDENTITY=}"
        INLINE_GH_AS_AUTHOR_IDENTITY_SET=1
        ;;
      GH_AS_REVIEWER_IDENTITY=*)
        INLINE_GH_AS_REVIEWER_IDENTITY="${tok#GH_AS_REVIEWER_IDENTITY=}"
        INLINE_GH_AS_REVIEWER_IDENTITY_SET=1
        ;;
    esac
  fi

  if [ "$AT_COMMAND_POSITION" -eq 0 ]; then
    # Arguments of an `export` command are DEFINITELY-effective
    # identity assignments: `export GH_AS_AUTHOR_IDENTITY=x ; wrapper`
    # puts the value in every later process's environment, while this
    # walk would otherwise skip the token as an unrelated-command
    # argument and the byline guard would fall back to the default
    # candidate (Codex P1 on PR #442 r11 — the wrong-byline class).
    # Capture them into the standalone (possibly-effective) slots the
    # candidate model already validates.
    if [ "$IN_EXPORT_SEGMENT" -eq 1 ]; then
      case "$tok" in
        GH_AS_AUTHOR_IDENTITY=*)
          STANDALONE_GH_AS_AUTHOR_IDENTITY="${tok#GH_AS_AUTHOR_IDENTITY=}"
          STANDALONE_GH_AS_AUTHOR_IDENTITY_SET=1
          ;;
        GH_AS_REVIEWER_IDENTITY=*)
          STANDALONE_GH_AS_REVIEWER_IDENTITY="${tok#GH_AS_REVIEWER_IDENTITY=}"
          STANDALONE_GH_AS_REVIEWER_IDENTITY_SET=1
          ;;
        GH_AS_AUTHOR_IDENTITY)
          # Bare name as an `unset` argument: the variable is removed
          # from the shell AND the child environment — the r15
          # empty-override semantics, persisting past separators.
          if [ "${DECLARATION_KIND:-}" = "unset" ]; then
            STANDALONE_GH_AS_AUTHOR_IDENTITY=""
            STANDALONE_GH_AS_AUTHOR_IDENTITY_SET=1
          fi
          ;;
        GH_AS_REVIEWER_IDENTITY)
          if [ "${DECLARATION_KIND:-}" = "unset" ]; then
            STANDALONE_GH_AS_REVIEWER_IDENTITY=""
            STANDALONE_GH_AS_REVIEWER_IDENTITY_SET=1
          fi
          ;;
      esac
    fi
    # Skipping arguments of an unrelated command. Stay until a
    # separator resets us above.
    continue
  fi

  # Declaration builtins (`export`, `declare`, `typeset`, `readonly`,
  # `local`) at command position: their assignment arguments can reach
  # all later processes (-x exports; readonly -x verified on PR #442
  # r14). Flag the segment so the skip-path above captures the
  # identity assignments that follow. Variants without -x are
  # over-captured on purpose — the candidate model only blocks
  # MISMATCHED values, so the cost of the ambiguity is a false block
  # on a non-exported mismatched declaration, which is the fail-closed
  # direction for a byline guard.
  case "$tok" in export|declare|typeset|readonly|local|unset) IS_DECLARATION_BUILTIN=1 ;; *) IS_DECLARATION_BUILTIN=0 ;; esac
  if [ "$IS_DECLARATION_BUILTIN" -eq 1 ]; then
    DECLARATION_KIND="$tok"
    IN_EXPORT_SEGMENT=1
    SEGMENT_HAS_COMMAND=1
    AT_COMMAND_POSITION=0
    # A prefix assignment BEFORE the export command in the same
    # segment (`VAR=x export VAR`) both persists in the shell and is
    # exported — bash applies the prefix to the declaration builtin
    # and the bare-name export then marks the variable. Promote any
    # already-captured inline identity to the definitely-effective
    # slots, or the separator path would discard it as an ordinary
    # command prefix (Codex P1 on PR #442 r12 — wrong-byline class).
    if [ "$INLINE_GH_AS_AUTHOR_IDENTITY_SET" -eq 1 ]; then
      STANDALONE_GH_AS_AUTHOR_IDENTITY="$INLINE_GH_AS_AUTHOR_IDENTITY"
      STANDALONE_GH_AS_AUTHOR_IDENTITY_SET=1
    fi
    if [ "$INLINE_GH_AS_REVIEWER_IDENTITY_SET" -eq 1 ]; then
      STANDALONE_GH_AS_REVIEWER_IDENTITY="$INLINE_GH_AS_REVIEWER_IDENTITY"
      STANDALONE_GH_AS_REVIEWER_IDENTITY_SET=1
    fi
    continue
  fi

  if is_any_wrapper_named_token "$tok"; then
    if is_author_wrapper_token "$tok"; then
      WRAPPER_KIND="author"
      CURRENT_PREFIX="$tok"
      continue
    fi
    if is_reviewer_wrapper_token "$tok"; then
      WRAPPER_KIND="reviewer"
      CURRENT_PREFIX="$tok"
      continue
    fi
    echo "BLOCKED: non-canonical GitHub write wrapper path '$tok'." >&2
    echo "  Use the repository wrapper so token verification is guaranteed:" >&2
    echo "    scripts/gh-as-author.sh -- gh ..." >&2
    echo "    scripts/gh-as-reviewer.sh -- gh ..." >&2
    exit 2
  fi

  case "$tok" in
    [A-Za-z_]*=)
      # Bare assignment (#611 r9): a flattened X=$(...) leaves X= followed
      # by a PLACEHOLDER that is really the assignment VALUE — consume it
      # and stay in command position, so a following spliced gh write is
      # scanned as the command (FOO=$(date) $(printf gh) pr merge ran gh
      # unguarded). Any OTHER next token means a genuinely EMPTY assignment
      # (X= cmd, e.g. the identity-override wrapper forms) whose next token
      # IS the command — do not consume it.
      case "${TOKENS[$((i+1))]:-}" in
        __MERGEPATH_CMDSUB__|__MERGEPATH_CMDSUB_LITERAL__)
          SKIP_PREFIX_VALUE=1
          PENDING_PREFIX_FLAG=""
          ;;
      esac
      continue
      ;;
    [A-Za-z_]*=*)
      # Env assignment. Stay in command position.
      continue
      ;;
    sudo|eval|time|nohup|env|command|exec|nice|ionice)
      # Known prefix command. Stay in command position so the
      # next non-flag token is still treated as the command.
      # Track which prefix we're parsing flags for so we can
      # tell value-taking flags from boolean ones — short flags
      # like `-p` mean different things to different commands
      # (boolean for time, value-taking for ionice/sudo).
      #
      # eval is special: it executes its arguments as a NEW command
      # line, so an assignment argument (`eval VAR=x`) becomes a
      # STANDALONE assignment persisting in the shell — unlike an
      # ordinary prefix the shell restores. The separator path
      # promotes captured identities from eval segments to the
      # possibly-effective slots instead of discarding them.
      if [ "$tok" = "eval" ]; then
        SEGMENT_HAS_EVAL=1
      fi
      CURRENT_PREFIX="$tok"
      continue
      ;;
    gh|*/gh)
      SAW_GH=1
      continue
      ;;
    -*)
      # Flag of the most recently seen prefix command. Whether
      # the next token is a value depends on which prefix command
      # this flag belongs to. Without this distinction, putting
      # `-p` on a generic value-flag list would consume `gh` as
      # the value of `time -p` (which is actually the POSIX
      # boolean format flag), and putting `-p` on a generic
      # boolean list would let `ionice -p PID gh ...` walk past
      # `PID` thinking it's the next command.
      #
      # Per-prefix value-flag map. nathanpayne-codex caught the
      # original bug (sudo -u, time -f, nice -n) on PR #66
      # round 6; the per-prefix scoping prevents the obvious
      # over-fix from breaking `time -p`. Keep this shared with
      # the #348 compound pre-scan so both walks classify prefixes
      # identically.
      if prefix_flag_takes_value "$CURRENT_PREFIX" "$tok"; then
        SKIP_PREFIX_VALUE=1
        PENDING_PREFIX_FLAG="$CURRENT_PREFIX:$tok"
        continue
      fi
      # env's combined/long forms that drop identity variables from
      # the wrapped command's environment (same r15 empty-override
      # semantics as `env -u NAME` above): --unset=NAME, -u=NAME, the
      # COMPACT -uNAME (flag and name attached, no `=` — #451), and -i
      # which clears the whole environment. The space forms `-u NAME` /
      # `--unset NAME` are consumed by the value-flag path above; only the
      # attached forms reach this case, and -uNAME is the one
      # prefix_flag_takes_value (which matches only the bare `-u`) cannot
      # recognize, so it must be modeled explicitly here.
      if [ "$CURRENT_PREFIX" = "env" ]; then
        case "$tok" in
          --unset=GH_AS_AUTHOR_IDENTITY|-u=GH_AS_AUTHOR_IDENTITY|-uGH_AS_AUTHOR_IDENTITY)
            INLINE_GH_AS_AUTHOR_IDENTITY=""
            INLINE_GH_AS_AUTHOR_IDENTITY_SET=1
            continue
            ;;
          --unset=GH_AS_REVIEWER_IDENTITY|-u=GH_AS_REVIEWER_IDENTITY|-uGH_AS_REVIEWER_IDENTITY)
            INLINE_GH_AS_REVIEWER_IDENTITY=""
            INLINE_GH_AS_REVIEWER_IDENTITY_SET=1
            continue
            ;;
          -i|--ignore-environment)
            INLINE_GH_AS_AUTHOR_IDENTITY=""
            INLINE_GH_AS_AUTHOR_IDENTITY_SET=1
            INLINE_GH_AS_REVIEWER_IDENTITY=""
            INLINE_GH_AS_REVIEWER_IDENTITY_SET=1
            # env -i clears EVERYTHING the wrapper would see —
            # including MERGEPATH_AGENT — so the reviewer fallback
            # must be the wrapper's bare hardcoded default, not the
            # hook environment's agent chain (Codex P1 on PR #442
            # r19).
            IDENTITY_ENV_CLEARED_FOR_WRAPPER=1
            continue
            ;;
        esac
      fi
      # Otherwise: boolean flag of the current prefix (or a flag
      # of an unknown prefix, which we conservatively assume is
      # boolean to avoid eating `gh`). Stay in command position.
      continue
      ;;
    *)
      # An unrelated command (echo, printf, cat, find, etc.).
      # gh-as-an-argument should NOT trigger the hook;
      # transition to skip mode and walk past the args.
      # Mark the segment as having a real command so that
      # separator-clearing of inline env vars fires correctly.
      AT_COMMAND_POSITION=0
      SEGMENT_HAS_COMMAND=1
      continue
      ;;
  esac
done

# Effective env values: hook process env wins (set via `export`),
# inline-prefix value falls back. Both forms are documented; both
# must work.
EFFECTIVE_CODEX_CLEARED="${CODEX_CLEARED:-${INLINE_CODEX_CLEARED:-}}"
EFFECTIVE_BREAK_GLASS_ADMIN="${BREAK_GLASS_ADMIN:-${INLINE_BREAK_GLASS_ADMIN:-}}"
EFFECTIVE_BREAK_GLASS_MERGE_STATE="${BREAK_GLASS_MERGE_STATE:-${INLINE_BREAK_GLASS_MERGE_STATE:-}}"

# Distinguish `gh pr comment` from `gh issue comment` (both share the
# subcommand label `comment` but route through different parent
# tokens). `gh issue create` is intentionally NOT guarded (the #317
# clause was reverted — see header), so it needs no flag of its own.
IS_ISSUE_COMMENT=0
if [ "$SAW_ISSUE" -eq 1 ] && [ "$PR_SUBCOMMAND" = "comment" ]; then
  IS_ISSUE_COMMENT=1
fi

# A `gh issue <X>` invocation where X is anything OTHER than `comment`
# (issue create / close / view / list / edit / etc.) is out of scope
# for this hook. Allow. `gh issue create` was briefly byline-guarded
# (#317) but reverted — filing issues under the author identity is an
# intended, long-standing workflow.
if [ "$SAW_ISSUE" -eq 1 ] && [ "$IS_ISSUE_COMMENT" -eq 0 ]; then
  exit 0
fi

# Not a covered command? Allow.
if [ "$PR_SUBCOMMAND" != "create" ] && \
   [ "$PR_SUBCOMMAND" != "merge" ] && \
   [ "$PR_SUBCOMMAND" != "comment" ] && \
   [ "$PR_SUBCOMMAND" != "edit" ] && \
   [ "$PR_SUBCOMMAND" != "review" ] && \
   [ "$IS_ISSUE_COMMENT" -eq 0 ]; then
  exit 0
fi

cmd_label=""
case "$PR_SUBCOMMAND" in
  create)  cmd_label="gh pr create" ;;
  merge)   cmd_label="gh pr merge" ;;
  comment) cmd_label="gh pr comment" ;;
  review)  cmd_label="gh pr review" ;;
  edit)    cmd_label="gh pr edit" ;;
esac
[ "$IS_ISSUE_COMMENT" -eq 1 ] && cmd_label="gh issue comment"

PR_COMMENT_BODY_HAS_CODEX_TRIGGER=0
if [ "$PR_SUBCOMMAND" = "comment" ] && [ "$IS_ISSUE_COMMENT" -eq 0 ]; then
  # Only author-wrapper pr comments that actually pass @codex review in
  # the gh pr comment body are allowed. Looking at the whole shell
  # command would let an earlier `echo "@codex review"` spoof this gate.
  comment_walk_start=$((PR_SUBCOMMAND_INDEX + 1))
  comment_skip_next=""
  for j in "${!TOKENS[@]}"; do
    if [ "$j" -lt "$comment_walk_start" ]; then
      continue
    fi
    tok="${TOKENS[$j]}"
    case "$tok" in
      "&&"|"||"|";"|"|"|"|&"|"&"|"("|")") break ;;
    esac
    if [ -n "$comment_skip_next" ]; then
      comment_skip_next=""
      continue
    fi
    case "$tok" in
      --body|-b)
        next_index=$((j + 1))
        body_value="${TOKENS[$next_index]:-}"
        case "$body_value" in
          *"@codex review"*) PR_COMMENT_BODY_HAS_CODEX_TRIGGER=1 ;;
        esac
        comment_skip_next=1
        ;;
      --body=*)
        body_value="${tok#--body=}"
        case "$body_value" in
          *"@codex review"*) PR_COMMENT_BODY_HAS_CODEX_TRIGGER=1 ;;
        esac
        ;;
      --body-file|-F)
        comment_skip_next=1
        ;;
    esac
  done
fi

if [ -z "$WRAPPER_KIND" ]; then
  echo "BLOCKED: $cmd_label is a guarded GitHub write and must use a token-verifying wrapper (#411)." >&2
  echo "" >&2
  echo "  Direct or inline-token gh writes are not hook-verifiable before shell expansion." >&2
  echo "  Use the wrapper that verifies the effective token immediately before the write:" >&2
  echo "" >&2
  case "$PR_SUBCOMMAND:$IS_ISSUE_COMMENT" in
    create:*|merge:*|edit:*)
      echo "    scripts/gh-as-author.sh -- $cmd_label ..." >&2
      ;;
    comment:0)
      echo "    scripts/gh-as-reviewer.sh -- $cmd_label ..." >&2
      echo "    scripts/gh-as-author.sh -- gh pr comment ... --body '@codex review'   # Codex trigger only" >&2
      ;;
    review:*)
      echo "    scripts/gh-as-reviewer.sh -- $cmd_label ..." >&2
      ;;
    *:1)
      echo "    scripts/gh-as-reviewer.sh -- gh issue comment ..." >&2
      ;;
  esac
  echo "" >&2
  echo "  See REVIEW_POLICY.md § Operation-to-Identity Matrix." >&2
  exit 2
fi

AUTHOR_WRAPPER_ALLOWED=0
REVIEWER_WRAPPER_ALLOWED=0
case "$PR_SUBCOMMAND:$IS_ISSUE_COMMENT" in
  create:*|merge:*|edit:*) AUTHOR_WRAPPER_ALLOWED=1 ;;
  comment:0)
    if [ "$PR_COMMENT_BODY_HAS_CODEX_TRIGGER" -eq 1 ]; then
      AUTHOR_WRAPPER_ALLOWED=1
    fi
    REVIEWER_WRAPPER_ALLOWED=1
    ;;
  review:*) REVIEWER_WRAPPER_ALLOWED=1 ;;
  *:1) REVIEWER_WRAPPER_ALLOWED=1 ;;
esac

if [ "$WRAPPER_KIND" = "author" ] && [ "$AUTHOR_WRAPPER_ALLOWED" -ne 1 ]; then
  echo "BLOCKED: $cmd_label was routed through gh-as-author.sh, but this write must use a reviewer token." >&2
  echo "  Use scripts/gh-as-reviewer.sh -- $cmd_label ..." >&2
  exit 2
fi
if [ "$WRAPPER_KIND" = "reviewer" ] && [ "$REVIEWER_WRAPPER_ALLOWED" -ne 1 ]; then
  echo "BLOCKED: $cmd_label was routed through gh-as-reviewer.sh, but this write must use the author token." >&2
  echo "  Use scripts/gh-as-author.sh -- $cmd_label ..." >&2
  exit 2
fi

# --- byline guard for author-wrapper writes (#438) --------------------
#
# gh-as-author.sh verifies the token for whatever login
# GH_AS_AUTHOR_IDENTITY names — its default is nathanjohnpayne, but a
# shell where the variable is exported (or inline-prefixed) as a
# different login makes the wrapper verify THAT login's token and run
# `gh pr merge`/`edit`/`create` under it. Pin the wrapper's effective
# author identity to the expected author, exactly as the reviewer
# branch below pins the reviewer identity. Without this,
# `GH_AS_AUTHOR_IDENTITY=nathanpayne-codex scripts/gh-as-author.sh --
# gh pr merge ...` re-opens the wrong-byline merge/edit path the
# wrapper migration closed (the #359 class).
if [ "$WRAPPER_KIND" = "author" ]; then
  # Expected-author resolution order: explicit env override, then the
  # repo's review-policy.yml author_identity (so custom-author repos
  # need no hook-specific variable — Codex P2 on PR #442 round 2),
  # then the fleet default.
  EXPECTED_AUTHOR="${GH_PR_GUARD_EXPECTED_AUTHOR:-}"
  GUARD_POLICY_FILE="$(guard_policy_file || true)"
  if [ -z "$EXPECTED_AUTHOR" ] && [ -n "$GUARD_POLICY_FILE" ]; then
    # Strip surrounding double OR single quotes — both are valid YAML
    # scalars (`author_identity: "custom-owner"` / `'custom-owner'`),
    # matching the quote-tolerance of the sibling policy parsers
    # (Codex P2s on PR #442 r6/r7). Policy located via upward walk +
    # script-root fallback per r21.
    EXPECTED_AUTHOR=$(grep -m1 '^author_identity:' "$GUARD_POLICY_FILE" | awk '{print $2}' | sed -E "s/^[\"']//; s/[\"']\$//" || true)
  fi
  EXPECTED_AUTHOR="${EXPECTED_AUTHOR:-nathanjohnpayne}"
  # Candidate model (Codex P1 on PR #442 r4): a same-segment prefix on
  # the wrapper command is DEFINITIVE (it reaches the wrapper's
  # environment regardless of export attribute). Otherwise the wrapper
  # may see EITHER the hook's environment value / the wrapper's hard
  # default (nathanjohnpayne) OR a standalone assignment from an
  # earlier segment (effective only if the name carries the export
  # attribute, which the hook cannot observe). Every possibly-effective
  # candidate must match the expected author — fail closed on the
  # ambiguity.
  if [ "$INLINE_GH_AS_AUTHOR_IDENTITY_SET" -eq 1 ]; then
    # Same-segment prefix is definitive. An EMPTY override is not
    # "absent" — it resets the wrapper to its hardcoded default
    # (Codex P1 on PR #442 r15).
    AUTHOR_IDENTITY_CANDIDATES="${INLINE_GH_AS_AUTHOR_IDENTITY:-nathanjohnpayne}"
  else
    AUTHOR_IDENTITY_CANDIDATES="${GH_AS_AUTHOR_IDENTITY:-nathanjohnpayne}"
    if [ "$STANDALONE_GH_AS_AUTHOR_IDENTITY_SET" -eq 1 ]; then
      AUTHOR_IDENTITY_CANDIDATES="$AUTHOR_IDENTITY_CANDIDATES ${STANDALONE_GH_AS_AUTHOR_IDENTITY:-nathanjohnpayne}"
    fi
  fi
  for WRAPPER_AUTHOR_IDENTITY in $AUTHOR_IDENTITY_CANDIDATES; do
    if [ "$WRAPPER_AUTHOR_IDENTITY" != "$EXPECTED_AUTHOR" ]; then
      echo "BLOCKED: $cmd_label wrapper may run under author identity '$WRAPPER_AUTHOR_IDENTITY', not expected author '$EXPECTED_AUTHOR'." >&2
      echo "  gh-as-author.sh verifies whatever login GH_AS_AUTHOR_IDENTITY names; a non-author login here lands the write under the wrong byline (#438)." >&2
      echo "  Unset GH_AS_AUTHOR_IDENTITY (wrapper default: nathanjohnpayne) and drop any standalone GH_AS_AUTHOR_IDENTITY=... assignment from the command, or set GH_PR_GUARD_EXPECTED_AUTHOR if this repo's author identity genuinely differs." >&2
      exit 2
    fi
  done
fi

# --- byline guard for pr comment / pr review / issue comment ---
#
# These three subcommands share a single policy: reviewer writes must be
# routed through gh-as-reviewer.sh, and that wrapper must be configured
# for the expected reviewer identity.
#
# `gh issue create` is deliberately excluded — it was briefly guarded
# here (#317, after the mergepath#315 misattribution) but reverted,
# since filing issues under the author identity is an intended,
# long-standing workflow. See the header note.
#
# The `gh pr review --approve` self-approve sub-guard runs after this
# block — only if we made it past the basic byline check does the
# self-approve question even arise.
if [ -n "${GH_PR_GUARD_EXPECTED_REVIEWER:-}" ]; then
  EXPECTED_REVIEWER="$GH_PR_GUARD_EXPECTED_REVIEWER"
  EXPECTED_REVIEWER_SOURCE="GH_PR_GUARD_EXPECTED_REVIEWER"
else
  EXPECTED_REVIEWER_AGENT="${MERGEPATH_AGENT:-claude}"
  EXPECTED_REVIEWER="nathanpayne-$EXPECTED_REVIEWER_AGENT"
  if [ -n "${MERGEPATH_AGENT:-}" ]; then
    EXPECTED_REVIEWER_SOURCE="MERGEPATH_AGENT"
  else
    EXPECTED_REVIEWER_SOURCE="default"
  fi
fi
if [ "$PR_SUBCOMMAND" = "comment" ] || [ "$PR_SUBCOMMAND" = "review" ] || [ "$IS_ISSUE_COMMENT" -eq 1 ]; then
  if [ "$WRAPPER_KIND" = "reviewer" ]; then
    # Same candidate model as the author guard above (Codex P1 on PR
    # #442 r4): a same-segment prefix is definitive; otherwise both
    # the env/default resolution AND any standalone assignment from an
    # earlier segment are possibly effective and must ALL match.
    # The wrapper resolves an EMPTY GH_AS_REVIEWER_IDENTITY through its
    # env-free chain (MERGEPATH_AGENT, then nathanpayne-claude) — an
    # empty-set assignment maps to that, not to "absent" (r15).
    REVIEWER_EMPTY_FALLBACK="nathanpayne-claude"
    if [ -n "${MERGEPATH_AGENT:-}" ] && [ "$IDENTITY_ENV_CLEARED_FOR_WRAPPER" -eq 0 ]; then
      # env -i strips MERGEPATH_AGENT from the wrapper too — in that
      # case the wrapper's chain bottoms out at its hardcoded default
      # regardless of the hook environment (r19).
      REVIEWER_EMPTY_FALLBACK="nathanpayne-$MERGEPATH_AGENT"
    fi
    if [ "$INLINE_GH_AS_REVIEWER_IDENTITY_SET" -eq 1 ]; then
      REVIEWER_IDENTITY_CANDIDATES="${INLINE_GH_AS_REVIEWER_IDENTITY:-$REVIEWER_EMPTY_FALLBACK}"
    else
      REVIEWER_IDENTITY_CANDIDATES="${GH_AS_REVIEWER_IDENTITY:-}"
      if [ -z "$REVIEWER_IDENTITY_CANDIDATES" ]; then
        REVIEWER_IDENTITY_CANDIDATES="$REVIEWER_EMPTY_FALLBACK"
      fi
      if [ "$STANDALONE_GH_AS_REVIEWER_IDENTITY_SET" -eq 1 ]; then
        REVIEWER_IDENTITY_CANDIDATES="$REVIEWER_IDENTITY_CANDIDATES ${STANDALONE_GH_AS_REVIEWER_IDENTITY:-$REVIEWER_EMPTY_FALLBACK}"
      fi
    fi
    for WRAPPER_REVIEWER_IDENTITY in $REVIEWER_IDENTITY_CANDIDATES; do
      if [ "$WRAPPER_REVIEWER_IDENTITY" != "$EXPECTED_REVIEWER" ]; then
        echo "BLOCKED: $cmd_label wrapper may run under '$WRAPPER_REVIEWER_IDENTITY', not expected reviewer '$EXPECTED_REVIEWER'." >&2
        echo "  Expected reviewer source: $EXPECTED_REVIEWER_SOURCE" >&2
        echo "  Set GH_AS_REVIEWER_IDENTITY=$EXPECTED_REVIEWER or MERGEPATH_AGENT=<agent> consistently, and drop any standalone GH_AS_REVIEWER_IDENTITY=... assignment from the command." >&2
        exit 2
      fi
    done
  fi
fi

# --- gh pr review --approve self-approve sub-guard --------------------
#
# Over-threshold PRs may NOT be approved by the agent that authored
# them, per REVIEW_POLICY.md § No-self-approve scoping. The hook
# detects:
#   - PR_SUBCOMMAND=review with --approve in the args
#   - reviewer wrapper identity = nathanpayne-<agent>
#   - PR body contains `Authoring-Agent: <agent>` matching the same
#     agent suffix
#   - PR is over-threshold (determined from .github/review-policy.yml
#     when readable; assumed over-threshold when the file is missing)
#
# When all four conditions hold the hook blocks. The author of the PR
# must use a DIFFERENT reviewer identity (the cross-agent review path
# in Phase 4) to approve.
if [ "$PR_SUBCOMMAND" = "review" ]; then
  # Walk tokens AFTER the literal `review` subcommand looking for
  # `--approve` and a PR selector (first non-flag positional).
  REVIEW_APPROVE=0
  REVIEW_PR_SELECTOR=""
  REVIEW_REPO=""
  review_skip_next=""
  review_walk_start=$((PR_SUBCOMMAND_INDEX + 1))
  for j in "${!TOKENS[@]}"; do
    if [ "$j" -lt "$review_walk_start" ]; then
      continue
    fi
    tok="${TOKENS[$j]}"
    if [ "$review_skip_next" = "skip" ]; then
      review_skip_next=""
      continue
    fi
    if [ "$review_skip_next" = "repo" ]; then
      REVIEW_REPO="$tok"
      review_skip_next=""
      continue
    fi
    case "$tok" in
      --approve|-a)
        REVIEW_APPROVE=1
        continue
        ;;
      --repo|-R)
        review_skip_next="repo"
        continue
        ;;
      --repo=*)
        REVIEW_REPO="${tok#--repo=}"
        continue
        ;;
      -R=*)
        REVIEW_REPO="${tok#-R=}"
        continue
        ;;
      --body|-b|--body-file|-F)
        review_skip_next="skip"
        continue
        ;;
      -*)
        continue
        ;;
    esac
    if [ -z "$REVIEW_PR_SELECTOR" ]; then
      REVIEW_PR_SELECTOR="$tok"
    fi
  done
  if [ -z "$REVIEW_REPO" ] && [ -n "$GLOBAL_REPO" ]; then
    REVIEW_REPO="$GLOBAL_REPO"
  fi

  if [ "$REVIEW_APPROVE" -eq 1 ] && [ "${BOOTSTRAP_GH_PR_GUARD_SKIP_IDENTITY_CHECK:-0}" != "1" ]; then
    REVIEWER_FOR_APPROVE="${WRAPPER_REVIEWER_IDENTITY:-}"
    REVIEWER_AGENT=""
    case "$REVIEWER_FOR_APPROVE" in
      nathanpayne-*) REVIEWER_AGENT="${REVIEWER_FOR_APPROVE#nathanpayne-}" ;;
    esac

    if [ -n "$REVIEWER_AGENT" ]; then
      # Fetch PR body + lines-changed + headRefName + author for the
      # self-approve check. headRefName + author drive the propagation-
      # lane bypass (#334): lane PRs (branch starts with
      # `mergepath-sync/`, author = nathanjohnpayne) are exempt from
      # cross-agent review per REVIEW_POLICY.md § Propagation PR
      # review lane, so the same-agent self-approve guard shouldn't
      # fire on them regardless of size or Authoring-Agent body line.
      review_gh_args=(pr view --json body,additions,deletions,files,headRefName,author --jq '{body: .body, additions: .additions, deletions: .deletions, files: [.files[].path], head: .headRefName, author: .author.login}')
      if [ -n "$REVIEW_PR_SELECTOR" ]; then
        review_gh_args=(pr view "$REVIEW_PR_SELECTOR" --json body,additions,deletions,files,headRefName,author --jq '{body: .body, additions: .additions, deletions: .deletions, files: [.files[].path], head: .headRefName, author: .author.login}')
      fi
      if [ -n "$REVIEW_REPO" ]; then
        review_gh_args+=(--repo "$REVIEW_REPO")
      fi
      REVIEW_GH_STDERR=$(mktemp)
      # Append to the EXIT trap (the merge path may overwrite it
      # below; we do this here so it works on the review-only exit
      # path too).
      trap 'rm -f "$TMP_TOKENS" "$TMP_TOKENS_ERR" "$REVIEW_GH_STDERR"' EXIT
      if ! REVIEW_PR_JSON=$(gh "${review_gh_args[@]}" 2>"$REVIEW_GH_STDERR"); then
        echo "BLOCKED: gh-pr-guard could not fetch PR metadata for self-approve check." >&2
        echo "  stderr: $(cat "$REVIEW_GH_STDERR")" >&2
        echo "  command: gh ${review_gh_args[*]}" >&2
        exit 2
      fi

      # Propagation-lane bypass (#334). The lane criteria are:
      #   (1) branch name starts with the configured branch_prefix
      #       (default `mergepath-sync/`; override via
      #       GH_PR_GUARD_PROPAGATION_BRANCH_PREFIX)
      #   (2) PR author = configured author identity (default
      #       nathanjohnpayne; reuses GH_PR_GUARD_EXPECTED_AUTHOR)
      #
      # REVIEW_POLICY.md § Propagation PR review lane explicitly
      # exempts these PRs from the cross-agent Phase 4 requirement,
      # because the content is a verbatim mirror that was already
      # reviewed in the upstream mergepath PR. The lane PR still
      # needs an internal reviewer-identity APPROVED, which is what
      # the agent is trying to post — so the self-approve guard
      # MUST step aside for lane PRs even when active=reviewer-agent
      # AND PR body has `Authoring-Agent: <agent>` AND size > threshold.
      #
      # We deliberately skip the manifest-confinement third lane
      # criterion (every changed file under a manifest-declared
      # path) — that check belongs in verify-propagation-pr.sh, not
      # the local pre-write hook. Branch_prefix + author is enough
      # signal that this is a sync PR and the agent's approve is
      # the documented next step.
      PR_HEAD_REF=$(printf '%s\n' "$REVIEW_PR_JSON" | grep -oE '"head":[[:space:]]*"[^"]*"' | head -1 | sed -E 's/.*"head":[[:space:]]*"([^"]*)".*/\1/' || true)
      PR_AUTHOR=$(printf '%s\n' "$REVIEW_PR_JSON" | grep -oE '"author":[[:space:]]*"[^"]*"' | head -1 | sed -E 's/.*"author":[[:space:]]*"([^"]*)".*/\1/' || true)
      LANE_BRANCH_PREFIX="${GH_PR_GUARD_PROPAGATION_BRANCH_PREFIX:-mergepath-sync/}"
      LANE_AUTHOR="${GH_PR_GUARD_EXPECTED_AUTHOR:-nathanjohnpayne}"

      # #533 item 2: honor propagation_prs.enabled before granting the
      # lane bypass. A repo that explicitly opts out
      # (propagation_prs.enabled: false) must NOT get the local
      # self-approve bypass — mirror the CI Merge Clearance Gate, which
      # already reads this key. Per the DEFAULT-ON convention (#434) an
      # absent block or absent `enabled` key counts as enabled; otherwise
      # ONLY a literal `true` keeps the lane on — any other present value
      # (`false`, `TRUE`, `yes`, `1`, a typo) fails closed and disables
      # the bypass (#540), matching the propagation-lane audit's
      # exact-match rule so a misconfigured policy never silently grants
      # self-approve. Parsed with the same
      # grep/awk posture the rest of this hook uses (no yq dependency in
      # the pre-write hook). The block scoping keeps a sibling block's
      # `enabled:` (coderabbit/codex/...) from being read by mistake.
      LANE_ENABLED=1
      LANE_POLICY_PATH="$(guard_policy_file || true)"
      if [ -f "$LANE_POLICY_PATH" ]; then
        LANE_PROP_ENABLED=$(awk '
          # Accept a trailing comment / text after the key (propagation_prs: # opt-out),
          # matching the workflow parser; an exact-EOL match failed open (#540 P2).
          /^propagation_prs:([[:space:]]|$)/ { inblock=1; next }
          inblock && /^[^[:space:]#]/ { inblock=0 }
          inblock && /^[[:space:]]+enabled:/ { print $2; exit }
        ' "$LANE_POLICY_PATH" 2>/dev/null | sed -E "s/^[\"']//; s/[\"']\$//" || true)
        if [ -n "$LANE_PROP_ENABLED" ] && [ "$LANE_PROP_ENABLED" != "true" ]; then
          LANE_ENABLED=0
        fi
      fi

      if [ "$LANE_ENABLED" -eq 1 ] \
         && [ -n "$PR_HEAD_REF" ] && [ -n "$PR_AUTHOR" ] \
         && [ "$PR_AUTHOR" = "$LANE_AUTHOR" ] \
         && [ "${PR_HEAD_REF#"$LANE_BRANCH_PREFIX"}" != "$PR_HEAD_REF" ]; then
        # Lane criteria met (and lane enabled) — skip the self-approve
        # guard entirely. Allow the gh pr review --approve to proceed.
        exit 0
      fi

      PR_AUTHORING_AGENT=$(printf '%s\n' "$REVIEW_PR_JSON" | grep -oiE 'Authoring-Agent:[[:space:]]*[A-Za-z0-9_-]+' | head -1 | sed -E 's/Authoring-Agent:[[:space:]]*//I' | tr '[:upper:]' '[:lower:]' || true)

      if [ -n "$PR_AUTHORING_AGENT" ] && [ "$PR_AUTHORING_AGENT" = "$REVIEWER_AGENT" ]; then
        # Same-agent author + reviewer. Decide over/under-threshold.
        # Heuristic: parse `external_review_threshold` from
        # .github/review-policy.yml (line count); compute
        # additions + deletions from the PR JSON; over if sum >= threshold
        # OR threshold can't be determined (fail safe).
        threshold=""
        policy_path="$(guard_policy_file || true)"
        if [ -f "$policy_path" ]; then
          threshold=$(grep -oE '^[[:space:]]*external_review_threshold:[[:space:]]*[0-9]+' "$policy_path" | head -1 | grep -oE '[0-9]+$' || true)
        fi
        additions=$(printf '%s\n' "$REVIEW_PR_JSON" | grep -oE '"additions"[[:space:]]*:[[:space:]]*[0-9]+' | grep -oE '[0-9]+$' | head -1 || true)
        deletions=$(printf '%s\n' "$REVIEW_PR_JSON" | grep -oE '"deletions"[[:space:]]*:[[:space:]]*[0-9]+' | grep -oE '[0-9]+$' | head -1 || true)
        additions=${additions:-0}
        deletions=${deletions:-0}
        total=$((additions + deletions))

        is_over=1
        if [ -n "$threshold" ] && [ "$total" -lt "$threshold" ]; then
          is_over=0
        fi

        if [ "$is_over" -eq 1 ]; then
          echo "BLOCKED: self-approve detected on an over-threshold PR." >&2
          echo "" >&2
          echo "  Reviewer wrapper identity: $REVIEWER_FOR_APPROVE" >&2
          echo "  PR Authoring-Agent:      $PR_AUTHORING_AGENT" >&2
          echo "  PR size:                 $total lines changed (threshold: ${threshold:-unknown})" >&2
          echo "" >&2
          echo "  REVIEW_POLICY.md § No-self-approve scoping forbids the same agent identity that authored" >&2
          echo "  a Phase 4 (over-threshold) PR from approving it. Post --comment instead, and let the" >&2
          echo "  cross-agent merge gate (Codex 👍 for Phase 4a, or external CLI APPROVED for Phase 4b)" >&2
          echo "  carry the approval." >&2
          echo "" >&2
          echo "  If this PR is actually under-threshold and the heuristic mis-classified it, set" >&2
          echo "  BOOTSTRAP_GH_PR_GUARD_SKIP_IDENTITY_CHECK=1 for the single call (the identity check" >&2
          echo "  bypass also disables this sub-guard)." >&2
          exit 2
        fi
      fi
    fi
  fi

  # gh pr review (any flavor) is a write — but it's not a merge or
  # create, so the rest of the merge guard doesn't apply. Allow.
  exit 0
fi

# gh pr comment / gh issue comment: byline guard already ran. No
# further checks apply.
if [ "$PR_SUBCOMMAND" = "comment" ] || [ "$IS_ISSUE_COMMENT" -eq 1 ]; then
  exit 0
fi

# --- gh pr create ---
#
# Substring grep on the raw command is fine here — the body markers
# `Authoring-Agent:` and `## Self-Review` are content checks, not
# structural ones, and they don't depend on argument positions or
# global flags.
if [ "$PR_SUBCOMMAND" = "create" ]; then
  MISSING=""

  if ! echo "$COMMAND" | grep -qi 'Authoring-Agent:'; then
    MISSING="${MISSING}  - Missing 'Authoring-Agent:' in PR body\n"
  fi

  if ! echo "$COMMAND" | grep -qi '## Self-Review'; then
    MISSING="${MISSING}  - Missing '## Self-Review' section in PR body\n"
  fi

  if [ -n "$MISSING" ]; then
    echo "BLOCKED: PR description is missing required sections per REVIEW_POLICY.md:" >&2
    echo -e "$MISSING" >&2
    echo "Add these to the PR body before creating." >&2
    exit 2
  fi

  exit 0
fi

# gh pr edit is a guarded write for attribution, but label-specific
# edit policy is enforced by label-removal-guard.sh. Once the author
# wrapper has been verified above, no merge-state checks apply here.
if [ "$PR_SUBCOMMAND" = "edit" ]; then
  exit 0
fi

# --- gh pr merge ---
#
# (PR_SUBCOMMAND must be "merge" and PR_SUBCOMMAND_INDEX must point
# to the actual `merge` subcommand token in TOKENS by this point.)
#
# Walk tokens AFTER the literal `merge` subcommand token to extract:
#   - PR_SELECTOR (first non-flag positional)
#   - REPO_ARG (--repo / -R value if present)
#   - ADMIN_REQUESTED (--admin flag)
#
# All three are derived from the SAME tokenized walk so that
# value-taking flags (--body / --body-file / --subject /
# --author-email / --match-head-commit / --repo / -R) correctly
# consume their next token as the value. An earlier round used
# `grep -q -- --admin` on the raw command string for the admin
# check, which over-matched any `--admin` substring inside a
# quoted flag value (e.g., `--subject "--admin follow-up"`).
# nathanpayne-codex caught that on PR #66 round 6.
#
# An even earlier version of this walk used a separate `FOUND_MERGE`
# scan that latched onto the FIRST `merge` token anywhere in the
# command, not specifically the gh-context one. With chained inputs
# like `echo merge ; gh pr merge 65`, the walk would latch onto the
# echo arg and then capture `;` as the selector. Codex caught that
# on the swipewatch propagation PR #33; the fix is to use the
# PR_SUBCOMMAND_INDEX captured during phase 1 as the starting point
# of the merge walk, eliminating the FOUND_MERGE state entirely.
#
# `gh pr merge` accepts the selector as <number> | <url> | <branch>;
# we don't parse or validate the form, just pass it through to
# `gh pr view` which accepts the same grammar.
PR_SELECTOR=""
REPO_ARG=""
ADMIN_REQUESTED=0
SKIP_NEXT_AS=""  # "" | "skip" | "repo"
merge_walk_start=$((PR_SUBCOMMAND_INDEX + 1))
for j in "${!TOKENS[@]}"; do
  if [ "$j" -lt "$merge_walk_start" ]; then
    continue
  fi
  tok="${TOKENS[$j]}"
  if [ "$SKIP_NEXT_AS" = "skip" ]; then
    SKIP_NEXT_AS=""
    continue
  fi
  if [ "$SKIP_NEXT_AS" = "repo" ]; then
    REPO_ARG="$tok"
    SKIP_NEXT_AS=""
    continue
  fi
  case "$tok" in
    --admin)
      ADMIN_REQUESTED=1
      continue
      ;;
    --repo|-R)
      SKIP_NEXT_AS="repo"
      continue
      ;;
    --repo=*)
      REPO_ARG="${tok#--repo=}"
      continue
      ;;
    -R=*)
      REPO_ARG="${tok#-R=}"
      continue
      ;;
    --body|-b|--body-file|-F|--subject|-t|--author-email|-A|--match-head-commit)
      SKIP_NEXT_AS="skip"
      continue
      ;;
  esac
  case "$tok" in
    -*)
      continue
      ;;
  esac
  # First non-flag token after the gh-context `merge` is the
  # selector. Don't break — keep walking so a `--repo`/`-R` flag or
  # `--admin` flag appearing AFTER the selector still gets captured.
  if [ -z "$PR_SELECTOR" ]; then
    PR_SELECTOR="$tok"
  fi
done

# Subcommand-scoped REPO_ARG wins over global GLOBAL_REPO (mirrors
# gh's typical "more specific flag wins" behavior). Fall back to
# the global value only if the subcommand didn't specify one.
if [ -z "$REPO_ARG" ] && [ -n "$GLOBAL_REPO" ]; then
  REPO_ARG="$GLOBAL_REPO"
fi

# Fetch labels AND mergeStateStatus in a single API call. `gh pr
# view` with no positional argument resolves the PR from the
# current branch; with a positional argument it accepts number /
# URL / branch forms identically to gh pr merge.
#
# Output format: mergeStateStatus on line 1, then one label name
# per line (zero or more lines). The `--jq` filter is
# `.mergeStateStatus, .labels[].name` — jq emits each result on
# its own line. NEWLINE-delimited, NOT comma-joined: GitHub label
# names may legally contain commas (and spaces), so a CSV join
# would make the later exact-match label gate ambiguous — a label
# literally named `team,needs-external-review` would be parsed as
# two labels and false-match the real `needs-external-review`
# gate (CodeRabbit caught this on PR #263). Label names cannot
# contain newlines, so one-label-per-line is unambiguous.
#
# #171 / #170 retrospective: pre-this-change the hook fetched
# only labels and let `gh pr merge` run even when GitHub's
# `mergeStateStatus` was BLOCKED (failing CI / active
# CHANGES_REQUESTED). A PR could merge with red CI on every
# matrix cell because nothing in the merge path actually
# blocked. The new check is defense-in-depth behind branch
# protection: even if branch protection is misconfigured or
# disabled for an emergency hotfix, the hook will still refuse
# to dispatch the merge.
#
# #553 (CodeRabbit Major): a check group counts as green ONLY if no run is
# still pending AND its latest terminal run is green. The prior `max_by(.t).c`
# alone mis-ranked an un-timestamped PENDING re-run (t="" sorts lowest) behind a
# timestamped SUCCESS, so an UNSTABLE PR with a check still re-running counted
# all-green and could merge before CI finished. `if any(.[]; .c=="PENDING")`
# treats a group with ANY in-progress run as non-green regardless of timestamps.
GH_JQ='.mergeStateStatus, .mergeable, ([.statusCheckRollup[] | {n:(.name//.context//"?"), c:(.conclusion//.state//"PENDING"), t:(.completedAt//.startedAt//"")}] | group_by(.n) | map(if any(.[]; .c == "PENDING") then "PENDING" else max_by(.t).c end) | map(select(. != "SUCCESS" and . != "SKIPPED" and . != "NEUTRAL")) | length), .labels[].name'
GH_ARGS=(pr view --json labels,mergeStateStatus,mergeable,statusCheckRollup --jq "$GH_JQ")
if [ -n "$PR_SELECTOR" ]; then
  GH_ARGS=(pr view "$PR_SELECTOR" --json labels,mergeStateStatus,mergeable,statusCheckRollup --jq "$GH_JQ")
fi
if [ -n "$REPO_ARG" ]; then
  GH_ARGS+=(--repo "$REPO_ARG")
fi

# Capture stdout and stderr separately. Codex P1 on matchline PR
# #174 r2: a `2>&1` form would prepend ANY non-fatal stderr gh
# emitted (update notifier, deprecation warnings, etc.) to the
# stdout payload, then the line-1 `MERGE_STATE` extraction would
# parse that noise as MERGE_STATE — corrupting a CLEAN PR into the
# unrecognized-state block path. Routing stderr to a tempfile
# keeps MERGE_STATE pure. We still surface stderr in the error
# path for diagnostics.
GH_STDERR=$(mktemp)
# Re-declare the EXIT trap so $GH_STDERR is also cleaned up. The
# trap call replaces (not appends) any prior trap; keep all three
# tempfile names listed here so a future edit doesn't drop one.
trap 'rm -f "$TMP_TOKENS" "$TMP_TOKENS_ERR" "$GH_STDERR"' EXIT
if ! GH_OUTPUT=$(gh "${GH_ARGS[@]}" 2>"$GH_STDERR"); then
  echo "BLOCKED: gh-pr-guard could not fetch PR metadata to verify merge-gate clearance." >&2
  if [ -s "$GH_STDERR" ]; then
    echo "  stderr: $(cat "$GH_STDERR")" >&2
  fi
  echo "  command: gh ${GH_ARGS[*]}" >&2
  # The metadata fetch is unconditional and runs BEFORE any break-
  # glass override, so a BREAK_GLASS_* env var cannot bypass this
  # failure — the only fix is restoring gh/auth connectivity. Once
  # that's restored, BREAK_GLASS_MERGE_STATE / BREAK_GLASS_ADMIN
  # are still available downstream if the PR's merge state or admin
  # gate need to be overridden.
  echo "  Fix the underlying gh/auth issue and retry." >&2
  exit 2
fi

# Line 1 is mergeStateStatus; line 2 is mergeable (MERGEABLE /
# CONFLICTING / UNKNOWN — conflict-only, NOT a check-pass signal);
# line 3 is the count of check names whose LATEST run is non-green
# (a stale failure superseded by a later passing run does NOT count);
# lines 4..N are label names (one per line, possibly zero).
# Empty/missing MERGE_STATE (e.g. transient API state) falls into the
# `*` case below and fails closed. LABELS keeps the newline-delimited
# remainder for the exact-match gate further down — never re-join it
# into a delimited string.
MERGE_STATE=$(printf '%s\n' "$GH_OUTPUT" | sed -n '1p')
MERGEABLE_STATE=$(printf '%s\n' "$GH_OUTPUT" | sed -n '2p')
ROLLUP_NONGREEN=$(printf '%s\n' "$GH_OUTPUT" | sed -n '3p')
LABELS=$(printf '%s\n' "$GH_OUTPUT" | sed -n '4,$p')

# `human-hold` is a human-controlled hard freeze. Check it before
# mergeStateStatus, --admin, or needs-external-review handling so no
# agent-side bypass variable can release the hold. The only release
# path is the human removing the label.
if printf '%s\n' "$LABELS" | grep -Fxq "human-hold"; then
  echo "BLOCKED: PR carries 'human-hold'." >&2
  echo "  This is a human-remove-only hard hold and supersedes all merge gates." >&2
  echo "  Ask the human to remove the label before merging; no agent bypass is available." >&2
  exit 2
fi

# mergeStateStatus check (#171 layer 2). API enum (full set per
# GitHub GraphQL `MergeStateStatus`):
#   CLEAN       — checks pass, no merge conflicts, ready to merge
#   HAS_HOOKS   — branch has post-commit hooks (legacy state)
#   UNKNOWN     — state not yet determined (often transient; allow
#                 rather than wedge on slow API responses)
#   BLOCKED     — required check failing OR active CHANGES_REQUESTED
#                 review
#   DIRTY       — merge conflict
#   UNSTABLE    — a non-passing commit status. Allowed ONLY when the
#                 check rollup confirms every check name's LATEST run is
#                 green (a stale pre-approval failure superseded by a
#                 later pass) AND mergeable=MERGEABLE. A genuinely-red
#                 (or misconfigured-required) check is NOT trusted as
#                 benign just because mergeable — which is conflict-only
#                 — says MERGEABLE; that would reopen #170/#171 (#547)
#   BEHIND      — base has commits the head lacks (with "Require
#                 branches to be up to date" enabled)
#   DRAFT       — PR is in draft mode (covered explicitly so the
#                 diagnostic points at the right fix, "mark draft
#                 as ready," not at "update the case statement for
#                 a future state")
#
# Unknown future states (anything not in the case below) fail
# CLOSED — a new GitHub API state shouldn't silently bypass the
# guard. Override with BREAK_GLASS_MERGE_STATE=1 if needed.
case "$MERGE_STATE" in
  CLEAN|HAS_HOOKS|UNKNOWN)
    ;;  # allow
  DRAFT)
    if [ "$EFFECTIVE_BREAK_GLASS_MERGE_STATE" = "1" ]; then
      echo "BREAK-GLASS: merge of draft PR authorized by human." >&2
    else
      echo "BLOCKED: PR is a draft (mergeStateStatus=DRAFT)." >&2
      echo "  Mark the PR as ready for review before merging (gh pr ready <PR#>)." >&2
      echo "  Override: BREAK_GLASS_MERGE_STATE=1 (export or inline prefix)." >&2
      exit 2
    fi
    ;;
  UNSTABLE)
    # UNSTABLE = a non-passing commit status, but mergeable. The naive
    # read (allow because mergeable=MERGEABLE) is WRONG: GitHub defines
    # `mergeable` purely by merge CONFLICTS, not check status, so a red
    # REQUIRED check surfaced as UNSTABLE (or branch protection
    # misconfigured) would still be MERGEABLE and slip through —
    # reopening the #170/#171 red-CI bypass. So verify the check ROLLUP:
    # allow only when every check name's LATEST run is green
    # (ROLLUP_NONGREEN == 0). That clears the real #547 case — a STALE
    # pre-approval failed check-suite superseded by a later passing run
    # (its latest is green) — while a genuinely-red latest check (count
    # > 0) stays blocked. mergeable=MERGEABLE is kept as a belt-and-
    # suspenders conflict guard. BLOCKED/DIRTY/BEHIND still block below.
    if [ "$ROLLUP_NONGREEN" = "0" ] && [ "$MERGEABLE_STATE" = "MERGEABLE" ]; then
      echo "ALLOW: mergeStateStatus=UNSTABLE, but every check name's LATEST run is green and mergeable=MERGEABLE — a stale check-suite superseded by a later pass (#547)." >&2
    elif [ "$EFFECTIVE_BREAK_GLASS_MERGE_STATE" = "1" ]; then
      echo "BREAK-GLASS: merge with mergeStateStatus=UNSTABLE (non-green latest checks=$ROLLUP_NONGREEN, mergeable=$MERGEABLE_STATE) authorized by human." >&2
    else
      echo "BLOCKED: PR mergeStateStatus is UNSTABLE with $ROLLUP_NONGREEN check(s) whose latest run is not green (mergeable=$MERGEABLE_STATE) — fail-closed; a red required check is NOT trusted as benign (mergeable is conflict-only)." >&2
      echo "  Resolve the failing checks, or wait for GitHub's recompute, then retry." >&2
      echo "  Override: BREAK_GLASS_MERGE_STATE=1 (export or inline prefix; must be authorized by human in chat)." >&2
      echo "  See #170 / #171 for the regression this guard closes." >&2
      exit 2
    fi
    ;;
  BLOCKED|DIRTY|BEHIND)
    if [ "$EFFECTIVE_BREAK_GLASS_MERGE_STATE" = "1" ]; then
      echo "BREAK-GLASS: merge with mergeStateStatus=$MERGE_STATE authorized by human." >&2
    else
      echo "BLOCKED: PR mergeStateStatus is $MERGE_STATE." >&2
      echo "  Resolve required checks / merge conflicts / change requests first." >&2
      echo "  Override: BREAK_GLASS_MERGE_STATE=1 (export or inline prefix; must be authorized by human in chat)." >&2
      echo "  See #170 / #171 for the regression this guard closes." >&2
      exit 2
    fi
    ;;
  *)
    # Unknown state — fail closed with a hint pointing to the
    # case statement above. New API states should be classified
    # explicitly, not absorbed into a default-allow.
    if [ "$EFFECTIVE_BREAK_GLASS_MERGE_STATE" = "1" ]; then
      echo "BREAK-GLASS: merge with unrecognized mergeStateStatus=$MERGE_STATE authorized by human." >&2
    else
      echo "BLOCKED: PR mergeStateStatus=$MERGE_STATE is not recognized by gh-pr-guard." >&2
      echo "  Update the case statement in scripts/hooks/gh-pr-guard.sh to classify it." >&2
      echo "  Override: BREAK_GLASS_MERGE_STATE=1 (export or inline prefix)." >&2
      exit 2
    fi
    ;;
esac

# --admin sub-guard: break-glass only. Now token-based: the walk
# above sets ADMIN_REQUESTED=1 only when `--admin` appears as a
# REAL flag of `merge`, not as a substring of another flag's value.
#
# Ordering note (#171): this guard is evaluated AFTER the
# mergeStateStatus check above. Pre-this-ordering, `--admin +
# BREAK_GLASS_ADMIN=1` exited before the merge-state guard ran —
# meaning an emergency `--admin` merge would silently bypass the
# BLOCKED/DIRTY/UNSTABLE/BEHIND refusal. The two break-glass
# overrides are independent decisions: BREAK_GLASS_ADMIN authorizes
# admin-flag use, BREAK_GLASS_MERGE_STATE authorizes merging despite
# a failing merge state. Requiring both for the worst-case merge
# (admin AND failing CI) is intentional.
if [ "$ADMIN_REQUESTED" -eq 1 ]; then
  if [ "$EFFECTIVE_BREAK_GLASS_ADMIN" = "1" ]; then
    echo "BREAK-GLASS: --admin merge authorized by human." >&2
    exit 0
  fi
  echo "BLOCKED: --admin merge requires explicit human authorization." >&2
  echo "Ask the human to confirm break-glass, then retry with BREAK_GLASS_ADMIN=1 (export or inline prefix)." >&2
  exit 2
fi

# Exact-match the label gate against the newline-delimited LABELS
# list. `grep -Fxq` = fixed-string, whole-line, quiet — so a label
# literally named `team,needs-external-review` (commas are legal in
# GitHub label names) is its own line and does NOT false-match the
# real `needs-external-review` gate.
if printf '%s\n' "$LABELS" | grep -Fxq "needs-external-review"; then
  if [ "$EFFECTIVE_CODEX_CLEARED" != "1" ]; then
    echo "BLOCKED: PR carries 'needs-external-review' and CODEX_CLEARED is not set." >&2
    echo "  Phase 4a merge gate: run 'scripts/codex-review-check.sh <PR#>' first." >&2
    echo "  When it exits 0, retry this merge with CODEX_CLEARED=1 (export or inline prefix)." >&2
    echo "  See REVIEW_POLICY.md § Phase 4a for the full flow." >&2
    exit 2
  fi
  echo "CODEX_CLEARED=1 set; PR is labeled needs-external-review but agent claims merge-gate has passed." >&2
fi

exit 0
