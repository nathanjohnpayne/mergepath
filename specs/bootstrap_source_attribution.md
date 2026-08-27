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

### What "canonical" requires — three independent, all-required checks

A `source_root` earns SHA attribution only when ALL of the following hold; any one failing falls back per above.

1. **`source_root` IS the git toplevel**, not merely inside a git repo. Git's own repository discovery walks UP from a non-git directory and resolves against an ENCLOSING checkout's `.git` — a plain non-git directory nested inside an unrelated repo must NOT record that ancestor's HEAD. Compared canonicalized (`pwd -P`), so a symlinked path still matches.
2. **`origin` names canonical mergepath by an exact host+path match** — one of the enumerated forms (`https://`, `http://`, `git@host:path` scp-like, `ssh://`) naming exactly `github.com` and exactly `nathanjohnpayne/mergepath` (with or without a `.git` suffix). An unanchored substring/suffix match is insufficient: a origin such as `https://evilgithub.com/nathanjohnpayne/mergepath.git` must NOT pass — the check must not be satisfiable by an origin carrying `github.com` as a suffix of some other hostname.
3. **HEAD is contained in a remote-tracking ref under `refs/remotes/origin`** — a clean, correctly-origined checkout can still carry an unpushed local commit on `main`; such a commit must NOT be attributed, since the canonical remote (and therefore `git ls-tree -r "$HUB_REF"` run elsewhere) has never heard of it.

### Scope

- This is a **forward-only** fix: it changes what a FUTURE bootstrap records. A consumer bootstrapped before this feature existed has no recoverable SHA and cannot be retrofitted; the documented answer for such a consumer is the consumer-to-consumer comparison in `docs/agents/propagation-ordering.md`, which needs no hub ref.
