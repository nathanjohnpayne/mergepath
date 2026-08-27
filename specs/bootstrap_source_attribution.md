# Bootstrap Source-SHA Attribution

Feature: a bootstrapped consumer's initial commit names the canonical mergepath tree it was mirrored from, so a drift measurement against that consumer has a recoverable `HUB_REF` (#1056). Implemented in `scripts/bootstrap/template-mirror.sh`, `bootstrap::_init_target_git` / `bootstrap::_resolve_canonical_source_sha`.

A bootstrapped repo has no sync PR, so it carries none of the `Source:`/branch-name provenance `scripts/sync-to-downstream.sh` writes on every sync PR. This feature gives the bootstrap's own single initial commit an equivalent contract. See [`docs/agents/propagation-ordering.md`](../docs/agents/propagation-ordering.md) § Measuring tier membership for how the recovered `HUB_REF` is consumed, and [`docs/agents/bootstrap-runbook.md`](../docs/agents/bootstrap-runbook.md) step 7 for the operator-facing description.

## Acceptance criteria

### Attribution shape, when the source is canonical

- The commit subject reads `Initial commit (bootstrapped from mergepath@<sha7>)` — the short sha, greppable and surviving a squash.
- The commit body carries a `Source: https://github.com/nathanjohnpayne/mergepath/commit/<sha>` trailer with the full sha, matching the `Source:` convention `scripts/sync-to-downstream.sh` already writes on every sync PR.

### Fallback, when the source cannot be verified canonical

- The commit subject reads the un-attributed `Initial commit (bootstrapped from mergepath)`, with no `Source:` trailer, identical to the commit this feature did not exist to produce.
- Fallback is fail-open with respect to the BOOTSTRAP itself: an unverifiable source never blocks or errors the bootstrap, it only omits the attribution.

### What "canonical" requires — four independent, all-required checks

A `source_root` earns SHA attribution only when ALL of the following hold; any one failing falls back per above.

1. **`source_root` IS the git toplevel**, not merely inside a git repo. Git's own repository discovery walks UP from a non-git directory and resolves against an ENCLOSING checkout's `.git` — a plain non-git directory nested inside an unrelated repo must NOT record that ancestor's HEAD. Compared canonicalized (`pwd -P`), so a symlinked path still matches.
2. **`origin` names canonical mergepath by an exact host+path match** — one of the enumerated forms (`https://`, `http://`, `git@host:path` scp-like, `ssh://`) naming exactly `github.com` and exactly `nathanjohnpayne/mergepath` (with or without a `.git` suffix). An unanchored substring/suffix match is insufficient: a origin such as `https://evilgithub.com/nathanjohnpayne/mergepath.git` must NOT pass — the check must not be satisfiable by an origin carrying `github.com` as a suffix of some other hostname.
3. **HEAD is contained in a remote-tracking ref under `refs/remotes/origin`** — a clean, correctly-origined checkout can still carry an unpushed local commit on `main`; such a commit must NOT be attributed, since the canonical remote (and therefore `git ls-tree -r "$HUB_REF"` run elsewhere) has never heard of it.
4. **The working tree is clean, including ignored files, with respect to every path a mirror actually copies** (`git -c core.filemode=true status --porcelain --ignored --untracked-files=all --ignore-submodules=none`, pinned on the command line so the operator's own `status.showUntrackedFiles` / `diff.ignoreSubmodules` / `core.filemode` config cannot suppress entries the mirror would still copy — `core.filemode=false` in particular hides a tracked file's executable bit changing, which rsync's `-a` still preserves into the target) — Stage B's rsync mirrors whatever is physically present in `source_root` regardless of `.gitignore` or commit state, not its committed tree; a source_root passing checks 1-3 can still carry uncommitted tracked edits OR a gitignored-but-present file (a build artifact, a stray `.env`) that rsync would copy but HEAD does not reflect. A failed `status` read itself also falls back — it is never read as "empty output, therefore clean." A dirty path is excused from this check ONLY when it matches the complete effective mirror-removal set — `BOOTSTRAP_MIRROR_EXCLUDES`, the derived hub-only-doc excludes, and the fixed post-mirror orphan list — because such a path can never reach the target regardless of its git status; treating its mere presence as dirty would reject attribution on ordinary operator checkouts (a stray `.DS_Store`) for no integrity benefit. A path outside that complete set still blocks attribution even if some *other* implementation detail (e.g. a static exclude array) does not itself name it. For a rename/copy record (status code containing `R` or `C`), porcelain reports `old -> new` on ONE line; BOTH sides must match the removal set before the record is excused, because a rename FROM tracked content TO an excluded path leaves the mirror with neither side while HEAD still carries the content. One class of path is subtracted from that removal set and always blocks attribution: `BOOTSTRAP_MIRROR_CONTROL_FILES` (currently `.mergepath-sync.yml`). Such a file's own bytes never reach the target, but Stage B READS its content at mirror time (`bootstrap::_derive_hub_only_excludes`) to decide what to exclude, so an uncommitted edit changes the tree the mirror actually produces even though the file itself is not copied. The test is narrower than "is a file ever read by bootstrap": only a file whose CONTENT decides what gets mirrored qualifies.

### Scope

- This is a **forward-only** fix: it changes what a FUTURE bootstrap records. A consumer bootstrapped before this feature existed has no recoverable SHA and cannot be retrofitted; the documented answer for such a consumer is the consumer-to-consumer comparison in `docs/agents/propagation-ordering.md`, which needs no hub ref.
