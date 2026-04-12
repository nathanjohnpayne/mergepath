# Agent Operating Rules

Read in this order before taking any action:

1. `README.md` — understand the project
2. `AGENTS.md` — load behavioral instructions (index pointing to this directory)
3. `rules/repo_rules.md` — load binding constraints
4. Relevant `specs/` files — understand intended behavior
5. `.ai_context.md` — load supplemental context

Conflict resolution:

- If code conflicts with `specs/`: flag the conflict, update spec or
  tests first, then update code. Do not silently modify behavior.
- If a proposed change violates `rules/repo_rules.md`: stop and flag
  the violation. Do not proceed without resolution.
- If a tool folder contains instructions that conflict with `AGENTS.md`
  or these sub-files: follow the canonical docs and flag the duplication
  for removal.
- If `AGENTS.md` or its sub-files are missing required sections: flag
  the gap and do not assume behavior for missing sections.

## 1Password CLI authentication failures

If any `op` command (`op read`, `op inject`, `op run`, `op document get`,
or any script that wraps them) fails with a sign-in or authentication
error — including but not limited to:

- `[ERROR] ... not currently signed in`
- `session expired`
- `biometric unlock ... timed out`
- `authorization prompt dismissed`
- `error initializing client: authorization`

Then follow this procedure:

1. **Stop immediately.** Do not retry the command, do not attempt
   workarounds (manual token entry, environment variable overrides,
   fallback credential paths, or skipping the credential step).
2. **Check if preflight was run.** If `OP_PREFLIGHT_DONE` is not set,
   suggest running the preflight script:
   > "1Password auth failed. Would you like to run credential preflight
   > to cache all credentials at once?
   > `eval \"$(scripts/op-preflight.sh --agent claude --mode all)\"`"
3. **If preflight was already run** but credentials expired (rare —
   only after 1Password locks or the 12-hour hard limit), prompt
   the human and suggest re-running preflight:
   > "Preflight credentials appear to have expired. Could you re-run
   > preflight when you're back? I need to resume the review."
4. **Wait for the human to confirm** they are present and ready before
   re-running preflight (not individual `op read` commands).
5. After confirmation, re-run preflight. If it fails again, report the
   full error output and wait — do not loop.

This rule applies only to 1Password CLI sign-in and authentication
errors. Other `op` failures (wrong item ID, missing field, network
errors, vault permission errors) should be diagnosed and resolved
normally.

## Bug fix escalation policy

These rules prevent agents from repeatedly patching symptoms of a
structural defect. They are derived from a real failure where one agent
made six unsuccessful fix attempts on the same issue because every
attempt preserved the same broken architectural assumption.

### Two-strike audit rule

If an agent has made **two or more failed fix attempts** on the same
issue (i.e., two merged PRs that were each intended to resolve the issue
but did not), the next attempt **must** begin with a written audit of
all prior attempts before any code changes. The audit must:

1. List every prior PR that targeted this issue.
2. For each, state what it changed and why it was insufficient.
3. Identify the **shared assumption** across all prior attempts.
4. Propose a fix that addresses that assumption directly, not another
   symptom within it.

The audit should appear in the PR description under a section titled
"Audit Of Prior Failed Fixes."

If the agent cannot identify a shared assumption, it must flag the issue
to the human rather than filing another incremental fix.

### Agent rotation for retries

When an agent's fixes are not resolving an issue after two attempts,
**hand the problem to a different agent**. A fresh agent without the
prior context is less likely to inherit implicit assumptions about the
system's architecture. The new agent should be given:

- The issue description
- Links to all prior fix PRs
- No additional narrative framing (let it form its own model)

This is a recommendation, not a hard rule. The human decides when to
rotate.

### Serialization layer review requirement

When reviewing a PR that introduces or modifies a **serialization or
deserialization layer**—any code that converts structured data to a flat
format (strings, JSON, markdown, plain text) and back—the reviewer must
verify:

1. **Losslessness:** Does the round-trip preserve all semantically
   meaningful information? If not, what is discarded?
2. **Consumer parity:** Do all consumers of the serialized format
   produce identical output from identical input? If there are multiple
   parsers/renderers, are they tested for equivalence?
3. **Necessity:** Is the intermediate format required, or can consumers
   read the structured format directly?

If the round-trip is lossy, the reviewer must flag the information loss
as a design risk and require either:
- An explicit justification for why the loss is acceptable, or
- A plan to eliminate the intermediate format

## Worktree lifecycle

Worktrees created for a task must be removed immediately after the corresponding
branch is merged or deleted from the remote. Never leave a worktree checked out
for a branch that is `[gone]` on the remote.

**After merging a PR whose branch had a worktree:**

```bash
git worktree remove --force .claude/worktrees/<name>
git worktree prune
```

**To find stale worktrees:**

```bash
git worktree list   # all worktrees and their branches
git branch -vv      # [gone] next to branches whose remote was deleted
```

If a worktree directory exists but `git worktree list` no longer shows it
(orphaned after `--force` removal), run `git worktree prune` to clean up
the git metadata, then `rm -rf` the leftover directory.
