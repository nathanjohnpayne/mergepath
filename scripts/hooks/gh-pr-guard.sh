#!/usr/bin/env bash
# gh-pr-guard.sh — PreToolUse hook for Claude Code
#
# Gates three operations:
#   1. gh pr create — blocks unless the command text includes
#      "Authoring-Agent:" and "## Self-Review"
#   2. gh pr merge --admin — blocks unless BREAK_GLASS_ADMIN=1
#      (human must explicitly authorize in chat)
#   3. gh pr merge (non-admin) — blocks when the target PR carries
#      the `needs-external-review` label unless CODEX_CLEARED=1
#      (agent must have just run scripts/codex-review-check.sh
#      successfully). This enforces REVIEW_POLICY.md § Phase 4a
#      merge gate at the hook layer so an agent can't accidentally
#      merge past Label Gate by removing the label without running
#      the gate check first.
#
# Exit codes:
#   0 = allow
#   2 = block (hard stop)
#
# Architecture notes:
#
#   The hook does ALL its parsing on a tokenized form of the
#   command produced by `xargs -n 1`, which honors POSIX shell
#   quoting. Earlier iterations used substring `grep` on the raw
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
if ! echo "$COMMAND" | grep -qE '(^|\s)gh(\s|$)'; then
  exit 0
fi

# --- tokenize the command with shell-quote awareness ---
#
# xargs honors POSIX single and double quoting. `gh pr merge
# --body "hello world" 65` tokenizes correctly to (gh, pr, merge,
# --body, hello world, 65) instead of being naively split into
# (gh, pr, merge, --body, "hello, world", 65).
#
# IMPORTANT: pass `printf '%s\n'` as the explicit command. The
# default `xargs` command is `echo`, and `echo` treats tokens
# beginning with `-` (specifically `-n`, `-e`, `-E`) as ITS OWN
# flags rather than printing them. That means a naive `xargs -n 1`
# silently drops `-n` from the token stream, which broke the
# pre-gh walk for inputs like `nice -n 5 gh pr merge 65` (the
# `-n` was missing entirely, so the walk treated `5` as the
# next command and switched to in_unrelated_args mode, missing
# the real `gh` command). Using `printf '%s\n'` instead of the
# implicit echo preserves every token literally.
#
# Fails CLOSED on tokenization error (unmatched quote, bad escape).
# An agent should fix the malformed command and retry.
TOKENS_OUTPUT=""
if ! TOKENS_OUTPUT=$(printf '%s' "$COMMAND" | xargs -n 1 printf '%s\n' 2>&1); then
  echo "BLOCKED: gh-pr-guard could not tokenize the gh command (malformed shell quoting)." >&2
  echo "  command: $COMMAND" >&2
  echo "  xargs error: $TOKENS_OUTPUT" >&2
  echo "  Fix the quoting and retry, or use BREAK_GLASS_ADMIN=1 + --admin." >&2
  exit 2
fi
# Portable read loop in lieu of bash 4+ `mapfile`. Empty lines
# preserved so legitimate empty arg values like `--body ""` are
# consumed correctly by downstream SKIP_NEXT_AS logic.
TOKENS=()
while IFS= read -r line; do
  TOKENS+=("$line")
done <<<"$TOKENS_OUTPUT"

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
#       - compound separators     ;  &&  ||  |  &  (
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
# Tokens BETWEEN `gh` and `pr` are global gh flags. The only global
# value-taking flag we explicitly handle is -R/--repo; everything
# else starting with - is assumed boolean and skipped.
INLINE_CODEX_CLEARED=""
INLINE_BREAK_GLASS_ADMIN=""
GLOBAL_REPO=""
PR_SUBCOMMAND=""
SAW_GH=0
SAW_PR=0
SKIP_GLOBAL_AS=""        # "" | "repo"
AT_COMMAND_POSITION=1    # 1 = at command position, 0 = walking unrelated-command args
SKIP_PREFIX_VALUE=0      # 1 = next token is the value of a prefix-command flag
CURRENT_PREFIX=""        # name of the most recently seen prefix command (sudo/time/etc.)
for tok in "${TOKENS[@]}"; do
  # --- phase 2: walking after gh, looking for pr + subcommand ---
  if [ "$SAW_GH" -eq 1 ]; then
    if [ "$SKIP_GLOBAL_AS" = "repo" ]; then
      GLOBAL_REPO="$tok"
      SKIP_GLOBAL_AS=""
      continue
    fi
    if [ "$SAW_PR" -eq 0 ]; then
      case "$tok" in
        pr)
          SAW_PR=1
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
        *)
          # Non-flag, non-pr token before `pr`. Either gh aliases
          # are in play (out of scope) or the command isn't a `gh
          # pr` invocation. Allow.
          exit 0
          ;;
      esac
    fi
    # SAW_PR=1 — this token IS the pr subcommand.
    PR_SUBCOMMAND="$tok"
    break
  fi

  # --- phase 1: walking pre-gh, looking for gh in command position ---

  # Consume the value of a prefix-command flag (e.g. the `user`
  # in `sudo -u user gh ...`). Stays in command position because
  # the prefix command may have additional flags or transition
  # straight to the actual command.
  if [ "$SKIP_PREFIX_VALUE" -eq 1 ]; then
    SKIP_PREFIX_VALUE=0
    continue
  fi

  # Capture inline env assignments regardless of state. Doing it
  # here means a `CODEX_CLEARED=1 sudo gh pr merge 65` or even
  # `cat foo; CODEX_CLEARED=1 gh pr merge 65` form still picks up
  # the inline value when gh is eventually found.
  case "$tok" in
    CODEX_CLEARED=*)
      INLINE_CODEX_CLEARED="${tok#CODEX_CLEARED=}"
      ;;
    BREAK_GLASS_ADMIN=*)
      INLINE_BREAK_GLASS_ADMIN="${tok#BREAK_GLASS_ADMIN=}"
      ;;
  esac

  # Compound separators always reset us to command position,
  # whether we were in command position or skipping unrelated
  # args. Only standalone `&&` / `||` / `;` / `|` / `&` / `(`
  # tokens count — separators glommed onto adjacent words by
  # missing whitespace (e.g. `foo;`) are NOT detected, which is
  # an acceptable limitation for the agent flow.
  case "$tok" in
    "&&"|"||"|";"|"|"|"&"|"("|")")
      AT_COMMAND_POSITION=1
      CURRENT_PREFIX=""
      continue
      ;;
  esac

  if [ "$AT_COMMAND_POSITION" -eq 0 ]; then
    # Skipping arguments of an unrelated command. Stay until a
    # separator resets us above.
    continue
  fi

  case "$tok" in
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
      CURRENT_PREFIX="$tok"
      continue
      ;;
    gh)
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
      # over-fix from breaking `time -p`.
      case "$CURRENT_PREFIX:$tok" in
        sudo:-u|sudo:-g|sudo:-U|sudo:-h|sudo:-p|sudo:-r|sudo:-s|sudo:-t|sudo:-c|sudo:-D)
          SKIP_PREFIX_VALUE=1
          continue
          ;;
        time:-f|time:-o)
          SKIP_PREFIX_VALUE=1
          continue
          ;;
        nice:-n)
          SKIP_PREFIX_VALUE=1
          continue
          ;;
        ionice:-c|ionice:-n|ionice:-p)
          SKIP_PREFIX_VALUE=1
          continue
          ;;
        env:-u|env:-S)
          SKIP_PREFIX_VALUE=1
          continue
          ;;
      esac
      # Otherwise: boolean flag of the current prefix (or a flag
      # of an unknown prefix, which we conservatively assume is
      # boolean to avoid eating `gh`). Stay in command position.
      continue
      ;;
    *)
      # An unrelated command (echo, printf, cat, find, etc.).
      # gh-as-an-argument should NOT trigger the hook;
      # transition to skip mode and walk past the args.
      AT_COMMAND_POSITION=0
      continue
      ;;
  esac
done

# Effective env values: hook process env wins (set via `export`),
# inline-prefix value falls back. Both forms are documented; both
# must work.
EFFECTIVE_CODEX_CLEARED="${CODEX_CLEARED:-${INLINE_CODEX_CLEARED:-}}"
EFFECTIVE_BREAK_GLASS_ADMIN="${BREAK_GLASS_ADMIN:-${INLINE_BREAK_GLASS_ADMIN:-}}"

# Not a pr create/merge command? Allow.
if [ "$PR_SUBCOMMAND" != "create" ] && [ "$PR_SUBCOMMAND" != "merge" ]; then
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

# --- gh pr merge ---
#
# (PR_SUBCOMMAND must be "merge" by this point.)
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
# `gh pr merge` accepts the selector as <number> | <url> | <branch>;
# we don't parse or validate the form, just pass it through to
# `gh pr view` which accepts the same grammar.
PR_SELECTOR=""
REPO_ARG=""
ADMIN_REQUESTED=0
FOUND_MERGE=0
SKIP_NEXT_AS=""  # "" | "skip" | "repo"
for tok in "${TOKENS[@]}"; do
  if [ "$SKIP_NEXT_AS" = "skip" ]; then
    SKIP_NEXT_AS=""
    continue
  fi
  if [ "$SKIP_NEXT_AS" = "repo" ]; then
    REPO_ARG="$tok"
    SKIP_NEXT_AS=""
    continue
  fi
  if [ "$FOUND_MERGE" -eq 1 ]; then
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
    # First non-flag token after `merge` is the selector. Don't
    # break — keep walking so a `--repo`/`-R` flag or `--admin`
    # flag appearing AFTER the selector still gets captured.
    if [ -z "$PR_SELECTOR" ]; then
      PR_SELECTOR="$tok"
    fi
    continue
  fi
  if [ "$tok" = "merge" ]; then
    FOUND_MERGE=1
  fi
done

# --admin sub-guard: break-glass only. Now token-based: the walk
# above sets ADMIN_REQUESTED=1 only when `--admin` appears as a
# REAL flag of `merge`, not as a substring of another flag's value.
if [ "$ADMIN_REQUESTED" -eq 1 ]; then
  if [ "$EFFECTIVE_BREAK_GLASS_ADMIN" = "1" ]; then
    echo "BREAK-GLASS: --admin merge authorized by human." >&2
    exit 0
  fi
  echo "BLOCKED: --admin merge requires explicit human authorization." >&2
  echo "Ask the human to confirm break-glass, then retry with BREAK_GLASS_ADMIN=1 (export or inline prefix)." >&2
  exit 2
fi

# Subcommand-scoped REPO_ARG wins over global GLOBAL_REPO (mirrors
# gh's typical "more specific flag wins" behavior). Fall back to
# the global value only if the subcommand didn't specify one.
if [ -z "$REPO_ARG" ] && [ -n "$GLOBAL_REPO" ]; then
  REPO_ARG="$GLOBAL_REPO"
fi

# Fetch labels. `gh pr view` with no positional argument resolves
# the PR from the current branch; with a positional argument it
# accepts number / URL / branch forms identically to gh pr merge.
GH_ARGS=(pr view --json labels --jq '[.labels[].name] | join(",")')
if [ -n "$PR_SELECTOR" ]; then
  GH_ARGS=(pr view "$PR_SELECTOR" --json labels --jq '[.labels[].name] | join(",")')
fi
if [ -n "$REPO_ARG" ]; then
  GH_ARGS+=(--repo "$REPO_ARG")
fi

if ! LABELS=$(gh "${GH_ARGS[@]}" 2>&1); then
  echo "BLOCKED: gh-pr-guard could not fetch PR labels to verify merge-gate clearance." >&2
  echo "  error: $LABELS" >&2
  echo "  command: gh ${GH_ARGS[*]}" >&2
  echo "  Fix the underlying gh/auth issue and retry, or set BREAK_GLASS_ADMIN=1 + use --admin if this is a break-glass merge." >&2
  exit 2
fi

case ",$LABELS," in
  *,needs-external-review,*)
    if [ "$EFFECTIVE_CODEX_CLEARED" != "1" ]; then
      echo "BLOCKED: PR carries 'needs-external-review' and CODEX_CLEARED is not set." >&2
      echo "  Phase 4a merge gate: run 'scripts/codex-review-check.sh <PR#>' first." >&2
      echo "  When it exits 0, retry this merge with CODEX_CLEARED=1 (export or inline prefix)." >&2
      echo "  See REVIEW_POLICY.md § Phase 4a for the full flow." >&2
      exit 2
    fi
    echo "CODEX_CLEARED=1 set; PR is labeled needs-external-review but agent claims merge-gate has passed." >&2
    ;;
esac

exit 0
