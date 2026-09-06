# Bootstrap Source Revision

Feature: a bootstrapped consumer's initial commit names which mergepath revision the bootstrap was based on, so a drift measurement against that consumer has a starting `HUB_REF` to work from (#1056). Implemented in `scripts/bootstrap/template-mirror.sh`, `bootstrap::_init_target_git` / `bootstrap::_resolve_bootstrap_source_revision`.

A bootstrapped repo has no sync PR, so it carries none of the `Source:`/branch-name provenance `scripts/sync-to-downstream.sh` writes on every sync PR. This feature gives the bootstrap's own single initial commit an equivalent, lighter-weight pointer. See [`docs/agents/propagation-ordering.md`](../docs/agents/propagation-ordering.md) § Measuring tier membership for how the recorded revision is used, and [`docs/agents/bootstrap-runbook.md`](../docs/agents/bootstrap-runbook.md) step 7 for the operator-facing description.

## What this is, and what it deliberately is not

This records **which mergepath revision the bootstrap was based on** — informational provenance, the same kind of fact a human would note by hand ("branched from around commit X"). It is not a claim that the resulting consumer commit's tree is byte-for-byte derivable from that sha: `template-mirror.sh` copies a working tree through exclusions, substitutions, removals, and identity scaffolding, so the mirrored tree is never identical to the source tree at that sha in the first place. Proving exact derivability would mean modeling every way that transformation pipeline can diverge from a single git commit, which is a much larger and different problem than #1056 asked for. Do not read the eligibility checks below as an attempt at that proof — they are a cheap, conservative gate against attributing a sha that is *obviously* wrong, not a guarantee the mirrored bytes exactly match it.

## Acceptance criteria

### Attribution shape, when the source is eligible

- The commit subject reads `Initial commit (bootstrapped from mergepath@<sha7>)` — the short sha, greppable and surviving a squash.
- The commit body additionally carries a `Source: https://github.com/nathanjohnpayne/mergepath/commit/<sha>` trailer, with the full sha, **only when** that sha is reachable from a ref under `source_root`'s own `refs/remotes/origin/*` — an unpushed local commit is still legitimate provenance for the subject's short sha, but recording a GitHub link for it would 404.

### Fallback, when the source is not eligible

- The commit subject reads the un-attributed `Initial commit (bootstrapped from mergepath)`, with no `Source:` trailer, identical to the commit this feature did not exist to produce.
- Fallback is fail-open with respect to the bootstrap itself: an ineligible source never blocks or errors the bootstrap, it only omits the attribution.

### Eligibility — two independent, both-required checks

A `source_root` is eligible for subject attribution only when both of the following hold; either failing falls back per above.

1. **`origin` names canonical mergepath by an exact host+path match** — one of the enumerated forms (`https://`, `http://`, `git@host:path` scp-like, `ssh://`) naming exactly `github.com` and exactly `nathanjohnpayne/mergepath` (with or without a `.git` suffix). An unanchored substring/suffix match is insufficient: an origin such as `https://evilgithub.com/nathanjohnpayne/mergepath.git` must not pass. This also fails closed when `source_root` is not a git repository at all — there is no origin to read.
2. **A plain, unconfigured `git status --porcelain` succeeds and is empty.** This is a conservative eligibility gate against a known mismatch risk — uncommitted or untracked changes at `source_root` that `HEAD` does not reflect — not an attempt to reconcile every path the mirror's own exclude, rsync, or resume behavior might separately drop or keep. A failed `status` read is also treated as ineligible, never as "empty output, therefore clean."

The `Source:` trailer's GitHub link carries one further, independent check: the resolved sha must be reachable from some ref under `refs/remotes/origin/*` at `source_root`. This gates only the trailer, not the subject's short sha.

### Scope

- This is a **forward-only** fix: it changes what a future bootstrap records. A consumer bootstrapped before this feature existed has no recoverable revision and cannot be retrofitted; the documented answer for such a consumer is the consumer-to-consumer comparison in `docs/agents/propagation-ordering.md`, which needs no hub ref.
- No other bootstrap behavior changes as part of this feature: rsync exclusion, resume handling, and post-mirror cleanup are unchanged.
