# Worktree Placement

> Canonical source: `mergepath/docs/agents/worktree-placement.md`. This file is propagated verbatim to consumer repos via the propagation manifest; edit it at the canonical source, never in a consumer copy. Machine-local vendor files (e.g. a `~/GitHub/CLAUDE.md`, `~/.codex/AGENTS.md`) that mirror this convention must carry a `> Canonical source:` annotation pointing back here — see the canonical-source discipline rule in `docs/agents/documentation-rules.md`.
>
> Consumer maintainers: the sync delivers this file but does not announce it. Link it from your repo's own agent-docs index (your `AGENTS.md` reading order or operating-rules equivalent) so agents actually discover it — this file is its own landing page, and nothing else in a consumer repo references it until you add that link.

This convention is deliberately tech-stack-independent: it says nothing about languages, frameworks, or build tooling, only where agent-created git checkouts live on disk. It applies identically in every repo that receives it.

## The convention

Any git worktree or additional checkout an agent creates for PR/branch work lives in a **hidden per-repo folder** on the operator machine:

```
~/GitHub/.<repo>-worktrees/<slug>
```

- **Never** create agent checkouts in `/tmp` (or any system temp directory). Temp-dir checkouts are invisible to worktree audits, survive as untracked clutter after reboots on some platforms, and detach the work from the machine's per-repo hygiene tooling.
- **Never** create visible sibling directories (e.g. `~/GitHub/<repo>-pr3`). They make the parent folder look like it is full of stray repos.
- This covers **every** agent-created checkout, including review-side ones: a Phase 4b external-reviewer session and any trusted main-ref checkout used to run review tooling (the trusted-path rule constrains which *ref* you run from; this convention constrains *where on disk* that checkout lives — both apply at once).
- **Slug naming.** For a checkout tied to a specific PR, start the slug with a parseable PR number: `pr-<number>` or `pr-<number>-<short-desc>` (e.g. `.<repo>-worktrees/pr-123-fix-login`). Where a machine carries cleanup tooling that cross-checks PR state, that prefix is what lets it identify a stale checkout for a closed/merged PR as automatically removable. Free-form slugs are fine for checkouts not tied to a single PR, but PR-state-aware tooling can then only list, never auto-remove, such checkouts.

```bash
# Correct — worktree lands in the hidden per-repo folder
git -C ~/GitHub/<repo> worktree add ~/GitHub/.<repo>-worktrees/<slug> <branch>

# Wrong — clutters the parent folder with a visible sibling
git -C ~/GitHub/<repo> worktree add ../<repo>-<slug> <branch>

# Wrong — /tmp checkout, invisible to worktree hygiene tooling
git clone ... /tmp/<repo>-pr123-review
```

## Relocating and removing

- Relocate a stray worktree with `git worktree move <old> ~/GitHub/.<repo>-worktrees/<slug>` — never plain `mv`, which breaks git's `gitdir` back-pointers.
- Remove a merged or stale worktree with `git worktree remove <path>`. Cleanup policy and audit tooling live in `docs/agents/operating-rules.md` § Worktree lifecycle.

### Two hazards for anyone writing cleanup tooling

Both of these make a *merged* branch or its checkout look like live work, so tooling that gets either wrong retains stale state forever while reporting a clean run.

- **A squash-merged branch is not an ancestor of the default branch.** Under squash merge the branch's own commits never enter the default branch's history, so `git rev-list --count origin/main..<branch>` stays permanently non-zero for a branch whose PR demonstrably merged. Decide "merged" from PR state — `gh pr list --head <branch> --state merged`, comparing the merged PR's recorded head against the local tip — never from ancestry against the default branch. An ancestry test is the natural thing to reach for and it is wrong: it reads as a confident "unmerged, do not touch" for every squash-merged branch.
- **"Upstream gone" is a separate signal from "merged", and it lags.** `git branch -vv`'s `[origin/<branch>: gone]` marker appears only after a `git fetch --prune` has removed the stale `refs/remotes/origin/<branch>`, so a branch whose remote was deleted on merge keeps a live-looking upstream until someone happens to prune. Tooling that treats gone-upstream as a *precondition* for its merged check must either prune first or probe the remote directly (`git ls-remote`), or a merged branch is silently retained and never reaches the merged check at all.

## Scope and enforcement honesty

This is a machine-local filesystem convention. Repository CI cannot see or enforce anything about paths outside the repo checkout it runs in, so there is no CI gate for it and none should be added. It is enforced by agents following it, by local audit tooling run on demand, and by reviewers flagging violations when a checkout path surfaces in a review or handoff transcript.

Tool-managed workspaces that a specific agent harness creates and cleans up itself (for example a session worktree under the repo's own `.claude/worktrees/`) are governed by that tool's lifecycle, not this convention; the convention governs checkouts an agent creates by hand.
