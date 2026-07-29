# Repo-local git identity leak (#777) — 2026-07

A fixture identity reached the live repository's `.git/config` twice, silently reattributing and unsigning every commit made from that checkout and from every worktree sharing it. This audit records what wrote it, what did not, and the two decisions the issue asked for but deliberately left open: whether `extensions.worktreeConfig` helps, and what to do about the two misattributed commits already on `main`.

## The corruption

```ini
[user]
	name = nathanjohnpayne
	email = nathan@nathanjohnpayne.example
[commit]
	gpgsign = false
```

Observed on 2026-07-28 and, by inference from the commits below, on 2026-07-02. `.example` is a reserved TLD, so the address is undeliverable — it is a fixture value, not a mistyped real one. The machine's global config was correct and unaffected throughout, which is why `git config --global --get user.email` looked fine and nothing surfaced the override.

## What wrote it

`REVIEW_POLICY.md` § Git Identity Switching. Its "Git commit identity" subsection instructed agents to run, verbatim, `git config user.name "nathanjohnpayne"` and then `git config user.email "nathan@nathanjohnpayne.example"`. <!-- GIT_IDENTITY_SCOPE_EXEMPT: verbatim quote of the #777 writer, recorded here as evidence rather than as an instruction to run -->

Those two values are the leak, exactly. They appear nowhere else in the tree as a config write — only in that code block and in the generated PRD mirror of it. `git config` without `--global` writes the current repository's `.git/config`, so an agent following the snippet from inside a managed checkout wrote the block above into the real repo. `AGENTS.md` sends agents to that section by name ("For the complete policy including … git identity switching instructions, read REVIEW_POLICY.md"), so this was a documented, sanctioned instruction rather than a slip.

The instruction was also stale on its own terms: reviewer identities never author commits — attribution for GitHub activity comes from the token wrappers (`scripts/gh-as-author.sh` / `scripts/gh-as-reviewer.sh`), and commit attribution comes from the machine's global identity. There was no case in which the snippet's "switch to reviewer identity" half was correct to run.

The `commit.gpgsign = false` line has no documented source. The most likely origin is an ad-hoc unblock after SSH signing failed (a locked 1Password vault breaks `op-ssh-sign` while leaving `gh` working), written with the same unscoped `git config` form. The guard covers it either way.

## What did not write it

The test suite. Every `tests/test_*.sh` in the tree was run against a throwaway clone with the clone's own `.git/config` hashed after each suite: 87 suites, 86 exiting 0 and one timing out at 420s, with the config byte-identical from first to last. No suite mutates it.

Two suites did carry the leak-prone *shape* — an unscoped `git config user.email` that happened to be contained by a preceding `cd` (`tests/test_deploy.sh`, `tests/test_worktree_cleanup.sh`) — and both are now scoped with `git -C`. They were latent, not guilty.

## `extensions.worktreeConfig`: evaluated, not a mitigation

The issue asked whether enabling it would stop a stray per-worktree write from poisoning siblings. It would not, for this class.

`extensions.worktreeConfig` enables the `--worktree` *scope*; it does not change where an unscoped or `--local` write goes. Both still land in the shared `.git/config` that every worktree reads. It would contain only a write that explicitly passed `--worktree`, which is not the shape that caused this and not a shape any tooling here uses. It is also already enabled on the operator's mergepath clone, and the leak happened anyway — direct evidence that it is not the control.

Recommendation: leave the setting as each clone has it. Do not enable it as a `#777` mitigation and do not disable it. `scripts/ci/check_git_identity_hygiene` is the control, and it deliberately inspects the `--worktree` scope as well as `--local` so a write through either is caught.

## Disposition of `5ecb10e` and `2c5510e`

| Commit | Date | Author recorded | Signature |
|---|---|---|---|
| `5ecb10e` | 2026-07-02 | `nathanjohnpayne <nathan@nathanjohnpayne.example>` | unsigned |
| `2c5510e` | 2026-07-02 | `nathanjohnpayne <nathan@nathanjohnpayne.example>` | unsigned |

Both are `fix(phase-4b)` commits, both merged to `main`, and both carry the correct committer (`Nathan Payne <github@nathanpayne.com>`) with only the author trailer wrong — the signature is absent because the same leak set `commit.gpgsign = false`.

**Decision: record, do not rewrite.** Correcting the author trailer means rewriting merged history on a protected default branch that nine consumer repositories and every open worktree are pinned to. That invalidates every downstream sha reference — issue and PR bodies, propagation-lane audit records, the wave-audit ledgers, `canonical-sha256` mirror pins — to fix a display string on two commits whose real provenance is already unambiguous (correct committer, correct PR, correct review trail). The cost is fleet-wide and the benefit is cosmetic.

This table is the record. The two commits stay as they are.
