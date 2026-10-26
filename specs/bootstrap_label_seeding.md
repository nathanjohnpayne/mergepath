# Bootstrap Label Seeding

Feature: the canonical issue-label set a bootstrapped repo starts with, and the serialized format that carries it. Stage C of `scripts/bootstrap-new-repo.sh` (implemented in `scripts/bootstrap/github-infra.sh`, step 2 — `bootstrap::_seed_labels`) seeds every active entry of `BOOTSTRAP_LABELS` into the new remote, all but the deprecated ones listed in `BOOTSTRAP_DEPRECATED_LABELS`, eliminating the first-PR "label not found" friction. The set was extended from 12 to 19 in #1182 to carry the fleet-shared `size:` / `priority:` subset agreed in the 2026-09-04 backlog audit, to 20 when #1555 added `needs-local-agent`, and to 21 with `status:blocked`, which marks a blocker that no issue can point at under the same lane rule on every repository's board.

## Acceptance criteria

### The serialized format is `name|color|description`

- Each `BOOTSTRAP_LABELS` entry is three `|`-separated fields. The separator is **not** `:`. The original `name:color:description` encoding split on the first two colons, which structurally cannot express a label name that itself contains a colon — and the entire shared taxonomy does. Under that format `"size:S:c2e0c6:Small…"` parsed as `name=size`, `color=S`, which is not valid hex, so the entry failed at the API rather than seeding.
- A `description` MAY contain both `:` and `|` and round-trips intact: only the first two separators are structural, and the remainder of the entry is the description.
- A `name` MAY contain `:`. Every `size:` and `priority:` entry depends on this.

### The malformed-spec guard fails closed

- An entry is rejected, with a warning naming the offending spec, when it does not carry **both** separators, or when the parsed name is empty, the parsed description is empty, or the parsed colour is not exactly six hexadecimal digits.
- The both-separators check runs **before** any field is trusted, and is a shape test on the whole entry rather than a check on a parsed field. This is load-bearing: `${var%%|*}` and `${var#*|}` return the input UNCHANGED when the separator is absent, so a one-separator entry does not fail on its own — it aliases two fields onto one value. `"future-label|abcdef"` otherwise yields `color=abcdef` AND `desc=abcdef`, passes a colour-only check, and creates a label with its colour copied into its description (#1182, Codex P2).
- A rejected entry is skipped, not fatal. One malformed spec must not take the other labels down with it, matching the per-entry failure posture already applied to a failing `gh label create`.

### The seeded set

- 21 canonical labels in `BOOTSTRAP_LABELS`: the four merge-gating blocking labels (`needs-external-review`, `needs-human-review`, `policy-violation`, `human-hold`), `needs-local-agent`, `human-action`, `decision-needed`, `agent-action`, `phase-0` through `phase-4`, `size:S`/`size:M`/`size:L`, `priority:critical`/`priority:high`/`priority:normal`/`priority:low`, and `status:blocked`.
- 16 of them are seeded. The five in `BOOTSTRAP_DEPRECATED_LABELS` (`phase-0` through `phase-4`) stay canonical but are never created. Their replacement (`area:phase-4b`) is hub taxonomy, so their descriptions would point at a label most consumers do not have (owner decision, 2026-10-21). `decision-needed` stays active: every repository carries it, and it is the one label that marks an issue as waiting on a human decision (owner decision, 2026-10-22). Every description is at most 100 characters, GitHub's limit; `scripts/sync-labels.sh` refuses a longer one before any read.
- The `size:`, `priority:` and `status:blocked` names, colours and descriptions are byte-identical to mergepath's own live labels. This is the point of the shared subset: a drifted description is what makes a shared label stop meaning one thing, and the observed fleet drift was exactly that — one repo carried all three size colours identically (making S/M/L indistinguishable in the UI), another carried descriptions on a time axis rather than the canonical scope axis.
- Seeding is idempotent. Every seeded (active) entry is created with `--force`, so re-running against a repo that already has a label updates its colour and description rather than erroring. A deprecated entry is still validated, and a malformed one still warns, but it is not created.
- Existing repositories stay in step through `scripts/sync-labels.sh`, a sync-wave step. It reads the same `BOOTSTRAP_LABELS` and `BOOTSTRAP_DEPRECATED_LABELS` and, for the hub and every manifest consumer, creates missing active labels and updates a drifted colour (compared without regard to case) or description. It corrects deprecated labels only where they exist. Names match without regard to case, as GitHub matches them, and an update keeps the live spelling. It never deletes, renames or recreates a label, and never touches a label outside the canonical list. The default is a dry run that exits 1 when changes are planned; `--apply` writes through `scripts/gh-as-author.sh`. Every read is paginated REST.

### Deliberate exclusions

- `size:XL` is not seeded. It existed in `nathanpaynedotcom` and was applied to zero issues, open or closed.
- `area:*`, every `status:*` value other than `status:blocked`, and repo-local `type:*` values are not seeded. They are per-repo vocabulary; imposing the hub's scheme on a repo with a handful of open issues is bureaucracy rather than standardization. `status:blocked` is the exception because it marks a blocker that no issue can point at, such as a vendor or an outside event, under the same lane rule on every board (`scripts/gh-projects/README.md` § Status lanes), so it must mean the same thing in every repository.

### Priority decision and audit rule

`priority:high` means an issue is actionable now and delaying it has a demonstrated material cost. Apply these questions in order: can engineering make meaningful progress now; does evidence show material impact; and should this issue be scheduled ahead of other actionable high-priority work? A “no” at any step means the issue does not qualify as high.

Material impact includes a currently reachable safety or correctness defect with meaningful blast radius, a recurring production or workflow failure with measured cost, a direct blocker of other high-value work that is ready to proceed, or time-sensitive delay that materially increases risk or cost. “Improvement,” “optimization,” or “architecture” describes solution shape and does not exclude an issue from high priority; assess the problem's demonstrated impact. A `type:bug` label does not by itself qualify an issue. Eventual automatic recovery does not mitigate the impact that occurred while the failure was active.

`status:blocked` does not qualify as high while the issue remains blocked. `type:decision` does not qualify merely because the decision matters; assess it under the same actionability, evidence, and comparative-urgency criteria. An existing `priority:high` label is not evidence that the issue still qualifies.

Use asymmetric evidence review when auditing priorities. A proposed promotion may start from a summary, but verify the full issue evidence before applying it. Before demoting an existing `priority:high` for absent or insufficient evidence, read the complete issue and inspect every relevant evidence section, including sections headed Evidence, Observed, Impact, Reproduction, Incident, or equivalent. Do not infer absence of evidence from an excerpt or from the issue's opening paragraphs. Automatic recovery or later resolution does not erase evidence of prior impact.

As a backlog health check, `priority:high` should ordinarily cover about 10–15% of open issues. A substantially higher share is a signal to re-audit the decisions, not a quota or a target: retain every issue that meets the material-impact rule and do not promote or demote issues merely to reach the band.

## Preservation boundaries

- Seeding is **additive**: it creates or updates the entries in its own table and never enumerates the repo's existing labels, so it can neither delete nor rename one. This is what keeps it safe to re-run against a populated repo. Deleting a label strips it from closed issues, and several fleet labels are machine-read — `post-review` is the dedupe key the weekly sweep uses to find its rollup issue, the four blocking labels gate merges via `Label Gate`, and `observation` / `risk` / `automation` are applied by running automation.

## Keeping existing repositories in step

- Stage C runs at repo **creation** only. Existing repositories are kept in step by `scripts/sync-labels.sh`, run as a sync-wave step (see the criterion above and `docs/agents/propagation-ordering.md`), which closes the #780 drift class for the canonical subset. A scheduled drift audit that runs it in dry-run mode between waves is not built yet.
