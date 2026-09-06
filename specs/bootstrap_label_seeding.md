# Bootstrap Label Seeding

Feature: the canonical issue-label set a bootstrapped repo starts with, and the serialized format that carries it. Stage C of `scripts/bootstrap-new-repo.sh` (implemented in `scripts/bootstrap/github-infra.sh`, step 2 — `bootstrap::_seed_labels`) seeds every entry of `BOOTSTRAP_LABELS` into the new remote, eliminating the first-PR "label not found" friction. The set was extended from 12 to 19 in #1182 to carry the fleet-shared `size:` / `priority:` subset agreed in the 2026-09-04 backlog audit.

## Acceptance criteria

### The serialized format is `name|color|description`

- Each `BOOTSTRAP_LABELS` entry is three `|`-separated fields. The separator is **not** `:`. The original `name:color:description` encoding split on the first two colons, which structurally cannot express a label name that itself contains a colon — and the entire shared taxonomy does. Under that format `"size:S:c2e0c6:Small…"` parsed as `name=size`, `color=S`, which is not valid hex, so the entry failed at the API rather than seeding.
- A `description` MAY contain both `:` and `|` and round-trips intact: only the first two separators are structural, and the remainder of the entry is the description.
- A `name` MAY contain `:`. Every `size:` and `priority:` entry depends on this.

### The malformed-spec guard fails closed

- An entry is rejected, with a warning naming the offending spec, when it does not carry **both** separators, or when the parsed name is empty, the parsed description is empty, or the parsed colour is not exactly six hexadecimal digits.
- The both-separators check runs **before** any field is trusted, and is a shape test on the whole entry rather than a check on a parsed field. This is load-bearing: `${var%%|*}` and `${var#*|}` return the input UNCHANGED when the separator is absent, so a one-separator entry does not fail on its own — it aliases two fields onto one value. `"future-label|abcdef"` otherwise yields `color=abcdef` AND `desc=abcdef`, passes a colour-only check, and creates a label with its colour copied into its description (#1182, Codex P2).
- A rejected entry is skipped, not fatal. One malformed spec must not take the other eighteen labels down with it, matching the per-entry failure posture already applied to a failing `gh label create`.

### The seeded set

- 19 labels: the four merge-gating blocking labels (`needs-external-review`, `needs-human-review`, `policy-violation`, `human-hold`), `human-action`, `decision-needed`, `agent-action`, `phase-0` through `phase-4`, `size:S`/`size:M`/`size:L`, and `priority:critical`/`priority:high`/`priority:normal`/`priority:low`.
- The `size:` and `priority:` names, colours and descriptions are byte-identical to mergepath's own live labels. This is the point of the shared subset: a drifted description is what makes a shared label stop meaning one thing, and the observed fleet drift was exactly that — one repo carried all three size colours identically (making S/M/L indistinguishable in the UI), another carried descriptions on a time axis rather than the canonical scope axis.
- Seeding is idempotent. Every entry is created with `--force`, so re-running against a repo that already has a label updates its colour and description rather than erroring.

### Deliberate exclusions

- `size:XL` is not seeded. It existed in `nathanpaynedotcom` and was applied to zero issues, open or closed.
- `area:*`, `status:*` and repo-local `type:*` values are not seeded. They are per-repo vocabulary; imposing the hub's scheme on a repo with a handful of open issues is bureaucracy rather than standardization.

## Preservation boundaries

- Seeding is **additive**: it creates or updates the entries in its own table and never enumerates the repo's existing labels, so it can neither delete nor rename one. This is what keeps it safe to re-run against a populated repo. Deleting a label strips it from closed issues, and several fleet labels are machine-read — `post-review` is the dedupe key the weekly sweep uses to find its rollup issue, the four blocking labels gate merges via `Label Gate`, and `observation` / `risk` / `automation` are applied by running automation.

## Known gap

- Stage C runs at repo **creation** only. Nothing re-seeds or audits an existing repo, so the set is frozen at enrolment and drift is undetected — the #780 defect class. The re-runnable reconciler and its scheduled drift audit are tracked separately; they touch `.github/**` and a canonical propagating doc and so are a Phase-4 change.
