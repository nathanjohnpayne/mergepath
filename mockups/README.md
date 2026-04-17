# Mockups

Static, single-file UI prototypes that illustrate how this template's
review-policy tooling is meant to be used. Nothing here is wired to a
backend or a build system. Open the HTML in a browser and it works.

## Mergepath

`mergepath.html` is the current dashboard. It lets you tune the policy
knobs from `.github/review-policy.yml` and replay recent PRs against
the draft policy so you can feel the shape of the change before
committing the YAML.

### What you can change

- **External review threshold.** Lines changed at or above this value
  escalate a PR to Phase 4.
- **Protected paths.** Glob patterns (`*`, `**`, `?`). Any match forces
  Phase 4 regardless of size.
- **CodeRabbit.** Toggles the Phase 2.5 advisory auto-review.
- **Codex GitHub App.** Toggles Phase 4a automated external review,
  with a max-rounds cap.
- **Reviewers.** The identities eligible to serve as internal reviewer.
- **Presets.** Strict / Standard / Loose starting points.

### How to run it

```bash
# From the repo root, open directly in your default browser:
open mockups/mergepath.html             # macOS
xdg-open mockups/mergepath.html         # Linux
start mockups\mergepath.html            # Windows
```

It opens with a synthetic set of sample PRs so the page demos without
any setup. The header badge reads **synthetic · 8**.

### Replaying your real PRs

```bash
./scripts/policy-sim.sh        # default: last 20 merged PRs
./scripts/policy-sim.sh 50     # custom limit
```

The helper runs `gh pr list --state merged`, shapes the JSON into the
`window.__PRS` format, injects it into a temporary copy of
`mergepath.html`, and opens that copy in a new tab. The header badge
flips to **live · N** and the routing simulation replays each PR
against whichever policy draft you have loaded.

Requirements: `gh`, `jq`, and `python3` on `PATH`; `gh auth status`
must show you're signed in. Nothing is written back to the repo — the
baked copy lives in a temp file.

### Contract for `scripts/policy-sim.sh`

The injection marker in the HTML is this HTML comment:

```html
<!-- MERGEPATH_INJECT -->
```

The script rewrites it to:

```html
<script>window.__PRS = [ ... ];</script>
```

Each entry in the array must be `{ id, title, author, lines, paths }`.
The page tolerates missing fields but expects those keys.

The legacy marker `<!-- RUBRIC_INJECT -->` is still recognized for
scripts carried over from earlier versions of this mockup; new tooling
should target `MERGEPATH_INJECT`.

### What this isn't

- **Not a backend.** No network calls, no auth, no server. Everything
  renders from the static file plus whatever the injection script
  bakes in.
- **Not a generator.** The draft YAML panel shows what the current
  knob configuration would look like as `.github/review-policy.yml`.
  It does not write to disk. Copy it yourself if you want to apply.
- **Not canonical.** The spec for this page is
  `specs/mergepath_policy_configurator.md`. If the spec and the page
  disagree, the spec wins.
