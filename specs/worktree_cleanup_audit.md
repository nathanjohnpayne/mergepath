# Worktree Cleanup Audit

Feature: `scripts/worktree-cleanup.sh` reports the machine-local state of git worktrees and branches through an exit status whose meaning is stable enough for a caller to branch on. A dry run distinguishes three outcomes — clean, complete-with-findings, and incomplete — so that a report which could not evaluate part of the tree can never be mistaken for one that evaluated it and found nothing. This closes the failure class recorded in #992: a failed remote read rendered identically to a clean tree, and a later `--apply` acted on branches the preview had never listed.

## Exit contract

- Exit `0`: the audit completed and found nothing actionable.
- Exit `1`: a generic error — bad invocation, an unsupported state, or a git failure the script does not model.
- Exit `2`: the audit **completed** and found something actionable. `2` does not promise that a plain `--apply` clears it. `SUMMARY_DIVERGED_KEPT` and `SUMMARY_UNCLEAN_KEPT` need a human decision and `--apply` deliberately never touches them; locked entries and orphans require `--force-locked` / `--orphan-clean`. The per-record lines state which class each candidate belongs to.
- Exit `3`: the audit is **incomplete**. A read it depends on failed in a way that would otherwise be invisible, so one of the report's silences is not evidence.

The `2`-versus-`3` axis is **completeness**, not who can act. A `2` may still require a human; a `3` says the run does not know what it is looking at. A caller that branches only on `2` is unaffected by `3`; a caller treating any non-zero as actionable still observes it.

## What produces an incomplete audit

Only a failure whose absence of output is indistinguishable from a real answer. Today that is the **stale-unpruned probe as a whole**, which is dry-run only — `--apply` never exits `3`. Every step the probe depends on qualifies, not just its network read: entering the main worktree, reading the local branch list, allocating and writing the eligible-branch list, taking the remote-heads snapshot, and allocating and writing that snapshot. Each of them ends with the probe reporting nothing, and reporting nothing is exactly what a clean tree looks like.

- The probe reports one of three states. `ok`: every step it depends on succeeded and the reported set is authoritative. `declined`: `remote.origin.fetch` is not the conventional `+refs/heads/*:refs/remotes/origin/*`, so the tracking-ref-to-remote-head mapping is unknowable and the probe does not guess. `unknown`: one of those steps failed and nothing is known either way. The cause is recorded alongside it so the remedy can match, because the failing step is not always the remote one.
- `declined` is not `unknown`. It is a standing, documented limitation with a stable answer, and collapsing the two would put every non-conventional checkout at a permanent exit `3`.
- Eligibility is resolved before the network is consulted. When no local branch tracks `refs/remotes/origin/*`, the stale set is provably empty from local reads and the remote has no say in it; an unreachable remote must not turn such a run into an incomplete audit on the strength of a read nobody needed. An empty eligible list is `ok`, not `unknown` — the answer is known, and it is nothing.
- An `unknown` state annotates its counter with a `NOT MEASURED` line and names the cause, because that counter reads `0` when nothing was checked exactly as it does when nothing is stale. The counter itself still reports `0`: the audit adds a qualifier rather than inventing a figure it could not obtain.

## Remediation is cause-specific

The remedy printed with an incomplete audit must match the failure, because a wrong remedy is more expensive than a vague one — it looks actionable.

- A `remote` cause means the `git ls-remote --heads origin` snapshot failed. Re-run once the remote is reachable.
- A `storage` cause means the audit could not allocate or write its own working state, almost always a `TMPDIR` that is unwritable or full. Fix the temporary storage. The remote may have been perfectly reachable; one of these paths fails *after* a successful remote read.
- A `refs` cause means this repository's own refs could not be read, or its main worktree could not be entered. Check the repository, not the network and not temporary storage.
- The three are distinguished at the point of failure rather than inferred afterwards. A git read and a temp-file write must not share one guarded pipeline: under `pipefail` an unreadable ref database would surface as a storage failure and send the operator to check `TMPDIR` for a problem in the repository.
- An unrecognised cause renders a generic incomplete-audit line rather than guessing, so a future failure path cannot silently inherit the wrong advice.
- In no case is re-running with `--apply` the remedy. A wrong remedy is more expensive than a vague one, because it looks actionable.

## What does not change the exit status

A failure that announces itself is reported without changing the status.

A failed merged-PR lookup (`gh` missing, unauthenticated, or an API error) carries its own counter (`gone unverified (lookup failed)`), its own per-branch records, and its own `NOT MEASURED` annotation. Nothing about it is mistakable for a clean result, which is the property exit `3` exists to protect. It is also excluded from `total_candidates` deliberately: on a `gh`-less machine every gone branch is unverifiable, and routing that to either `2` or `3` would make the audit useless exactly where it can verify least. Whether an announced-but-unevaluated read deserves its own status is tracked in #1114 rather than settled here.

## Read-only by default

Dry run performs no ref mutation. The stale-unpruned probe is a network **read** (`git ls-remote`), never a local ref write, and nothing in the script prunes; teaching `--apply` to act on the stale-unpruned class is tracked in #932.

The probe is **not** yet non-interactive or time-bounded. It invokes `git ls-remote` directly, so on an SSH origin needing a host-key confirmation or a passphrase, or an HTTPS origin with no cached credential, an unattended audit can still prompt or stall — and the caller hides stderr, so the prompt is invisible. `git ls-remote` offers no option that would change this; it requires environment and transport controls the invocation does not yet set. That work is #933 and this section is updated when it lands, not before.

## Non-goals

- This helper is local-only. Worktree state is machine-local and does not gate repository CI (#288).
- Exit `3` is not a health check for the whole script. Five top-level temp-file write sites still fail loudly rather than reporting, which is a different failure shape and is tracked in #1115.
