# Mergepath — surfaces

This directory holds Mergepath's surfaces. The **Playground** is a current static UI. **Cockpit** has an authenticated local server, shared shell, PR/review-budget panel and read-only Fleet audits; remaining panels are in development. Tiebreaker and Checks remain reserved names — see [`BRAND.md`](../BRAND.md) at repo root.

## Mergepath Cockpit

`../scripts/cockpit.sh` starts the authenticated loopback server using an already-warm reviewer credential cache. It uses Python standard library and the hub's existing installed mikefarah/yq; it does not install dependencies or read 1Password. The browser opens through a one-use fragment bootstrap; the printed URL contains no secret. The shell includes connection health, per-resource API evidence, repository filtering, Road components, both themes and live reduced-motion preferences. Open PRs and their review budgets use current-head evidence and read-only policy/accounting helpers; missing observations remain unknown, and failed refreshes retain explicitly stale evidence. The two Cockpit display defaults in `cockpit/pr_settings.json` do not alter governing policy or trigger reviews. Fleet runs the trusted audit JSON command on a thirty-minute cadence in a private reviewer-only cache. Its authenticated refresh coalesces repeated requests and respects retry backoff; progress is indeterminate, failed attempts retain visibly stale last-good rows, and sync PR rows reuse current shared PR evidence. CI runs, live agents, agent history and Actions budgets show unavailable until their owning providers are connected. There are no fixture records or sync actions in the product. The contracts are in [`specs/cockpit_foundation.md`](../specs/cockpit_foundation.md), [`specs/cockpit_prs.md`](../specs/cockpit_prs.md) and [`specs/cockpit_fleet.md`](../specs/cockpit_fleet.md). Run `../tests/test_cockpit.sh` from this directory, or `tests/test_cockpit.sh` from the repository root, for hermetic Python and Node validation.

## Mergepath Playground

`playground/index.html` is the current Playground. It lets you tune the policy knobs from `.github/review-policy.yml` and replay recent PRs against the draft policy so you can feel the shape of the change before committing the YAML.

### What you can change

- **External review threshold.** Lines changed at or above this value escalate a PR to Phase 4.
- **Protected paths.** Glob patterns (`*`, `**`, `?`). Any match forces Phase 4 regardless of size.
- **CodeRabbit.** Toggles the Phase 2.5 advisory auto-review.
- **Codex GitHub App.** Toggles Phase 4a automated external review, with a max-rounds cap.
- **Reviewers.** The identities eligible to serve as internal reviewer.
- **Feedback policy.** Which bot-review findings the agent must disposition (fix or rebut + resolve) before merge — either "address or rebut all feedback" (`mode: address-all`) or a per-priority checkbox group (P0–P3) that marks each tier `required` or `discretionary`.
- **Presets.** Strict / Standard / Loose starting points.

### How to run it

```bash
# From the repo root, open directly in your default browser:
open mergepath/playground/index.html             # macOS
xdg-open mergepath/playground/index.html         # Linux
start mergepath\playground\index.html            # Windows
```

It opens with a synthetic set of sample PRs so the page demos without any setup. The header badge reads **synthetic · 8**.

### Replaying your real PRs

```bash
./scripts/policy-sim.sh        # default: last 20 merged PRs
./scripts/policy-sim.sh 50     # custom limit
```

The helper runs `gh pr list --state merged`, shapes the JSON into the `window.__PRS` format, injects it into a temporary copy of `playground/index.html`, and opens that copy in a new tab. The header badge flips to **live · N** and the routing simulation replays each PR against whichever policy draft you have loaded.

Requirements: `gh`, `jq`, and `python3` on `PATH`; `gh auth status` must show you're signed in. Nothing is written back to the repo — the baked copy lives in a temp file.

### Contract for `scripts/policy-sim.sh`

The injection marker in the HTML is this HTML comment:

```html
<!-- MERGEPATH_INJECT -->
```

The script rewrites it to:

```html
<script>window.__PRS = [ ... ];</script>
```

Each entry in the array must be `{ id, title, author, lines, paths }`. The page tolerates missing fields but expects those keys.

The legacy marker `<!-- RUBRIC_INJECT -->` is still recognized for scripts carried over from earlier versions of this Playground; new tooling should target `MERGEPATH_INJECT`.

### What this isn't

- **Not a backend.** No network calls, no auth, no server. Everything renders from the static file plus whatever the injection script bakes in.
- **Not a generator.** The draft YAML panel shows what the current knob configuration would look like as `.github/review-policy.yml`. It does not write to disk. Copy it yourself if you want to apply.
- **Not canonical.** The spec for this page is `specs/mergepath_playground.md`. If the spec and the page disagree, the spec wins.
