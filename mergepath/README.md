# Mergepath — surfaces

This directory holds Mergepath's surfaces. The **Playground** is a current static UI. **Cockpit** has an authenticated local server, shared shell, PR/review-budget, CI, Actions-budget, live-agent, agent-history and Fleet observations plus confirmed sync. Tiebreaker and Checks remain reserved names — see [`BRAND.md`](../BRAND.md) at repo root.

## Mergepath Cockpit

`../scripts/cockpit.sh` starts the authenticated loopback server using an already-warm reviewer credential cache. It uses Python standard library and the hub's existing installed mikefarah/yq; it does not install dependencies or read 1Password. The browser opens through a one-use fragment bootstrap; the printed URL contains no secret, and opening it again in the browser it launched returns to the Cockpit while that session lasts. The shell includes connection health, per-resource API evidence, repository filtering, Road components, both themes and live reduced-motion preferences. Open PRs and their review budgets use current-head evidence and read-only policy/accounting helpers; missing observations remain unknown. The two Cockpit display defaults in `cockpit/pr_settings.json` do not alter governing policy or trigger reviews. CI runs include all active work plus a labelled recent window, per-attempt jobs and step drill-down. On-demand FAIL excerpts use bounded shared transport and explicit selected-step or whole-job attribution; displayed rerun commands do not execute. Failed or incomplete refreshes retain explicitly stale evidence. Actions budgets reuse CI run observations for queue pressure and explicitly measured token estimates, add readable net spend, and preserve separate robot-pool evidence when configured. Missing budgets, measurements, billing permissions or robot evidence stay unavailable. Agent history reads configured local accounting records with explicit coverage and cost provenance. Live agents read the machine-local Phase 4b heartbeat directory with verified process identity and explicit stale/unknown states. Fleet runs the trusted audit JSON command on a thirty-minute cadence in a private reviewer-only cache. Its authenticated refresh coalesces repeated requests and respects retry backoff; progress is indeterminate, failed attempts retain visibly stale last-good rows, and sync PR rows reuse current shared PR evidence. There are no fixture records in the product. Fleet Sync opens a fresh preview before a separate confirmation can run the fixed propagation command. Confirmation binds the full hub SHA and consumer evidence, requires explicit existing-PR choices and an additional ahead-of-hub acknowledgment, and reacquires author credentials only through the already-warm canonical cache. Resulting PRs remain open for their normal review process. Contracts are in [`specs/cockpit_foundation.md`](../specs/cockpit_foundation.md), [`specs/cockpit_prs.md`](../specs/cockpit_prs.md), [`specs/cockpit_ci.md`](../specs/cockpit_ci.md), [`specs/cockpit_actions.md`](../specs/cockpit_actions.md), [`specs/cockpit_agents.md`](../specs/cockpit_agents.md), [`specs/cockpit_live_agents.md`](../specs/cockpit_live_agents.md), [`specs/cockpit_fleet.md`](../specs/cockpit_fleet.md) and [`specs/cockpit_sync.md`](../specs/cockpit_sync.md). Run `../tests/test_cockpit.sh` from this directory, or `tests/test_cockpit.sh` from the repository root, for hermetic Python and Node validation.

### Optional Actions inputs

Pass `--actions-settings /absolute/path/settings.json` to the launcher for explicit local budget and measurement inputs. Relative paths are resolved from the caller's working directory; quote paths containing spaces. The file must be a regular, non-symlink JSON object no larger than 64 KiB. It contains observations/settings, never credentials, and is not written back by Cockpit.

`budget` is a positive account budget in USD. `cycle_start` and `cycle_end` are Unix seconds at the exact current UTC calendar-month boundaries; the billing report's year/month must match before Cockpit calculates a percentage or projection. `measurements` maps enrolled `owner/repository` names to objects with `repo`, integer `requests`, positive integer `runs`, Unix-second `window_start`, `window_end` and `observed_at`, and a short `provenance` string describing the actual measurement. Windows may span at most one day; observations expire after one hour. Omitted or invalid inputs remain unavailable. No prototype figures become defaults. See [`specs/cockpit_actions.md`](../specs/cockpit_actions.md) for source and freshness contracts.

### Optional agent-history inputs

Pass `--agents-settings /absolute/path/settings.json` to add trusted local checkout roots and optional model price keys. The same regular-file, 64 KiB and caller-relative-path rules apply. Without this file, Cockpit discovers the hub checkout and its Git worktrees. `checkouts` maps enrolled `owner/repository` names to lists of absolute checkout directories; those checkouts and their worktrees are included, with duplicate roots removed and a 64-root limit. Browser controls cannot choose local paths. `price_keys` optionally maps `claude` or `codex` to an existing corresponding provider/model key in `scripts/phase-4b/prices.json`. Omitted keys leave unreported costs unavailable. Estimates remain labelled API-equivalent; total-only Codex tokens produce cost bounds, never an invented input/output split. Registered reviewer identities for approval cross-checks come from `.github/review-policy.yml`.

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
