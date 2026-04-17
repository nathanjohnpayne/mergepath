# Mergepath Policy Configurator

Feature: static, single-file review-policy playground for the template
repo. Product name **Mergepath**.

## Acceptance criteria

- The dashboard lives at `mockups/mergepath.html` and is a single
  self-contained HTML file with no network, build, or runtime
  dependencies.
- The page opens directly from the filesystem and renders a synthetic
  set of sample PRs when no live data has been injected.
- The left control rail exposes, at minimum:
  - external review threshold (slider)
  - protected-path globs (add / remove chips)
  - CodeRabbit toggle
  - Codex toggle with a max-review-rounds slider
  - reviewer-identity checkboxes
  - Strict / Standard / Loose presets
- The right workspace shows summary stats, a per-PR routing flow, and
  a live YAML preview of the draft policy with a copy-to-clipboard
  button.
- The YAML preview reflects the current knob state and matches the
  schema of `.github/review-policy.yml` for the subset of keys the UI
  exposes.
- Changing any knob updates stats, flows, and YAML without a full
  reload.
- The page carries an HTML comment injection marker
  `<!-- MERGEPATH_INJECT -->` that `scripts/policy-sim.sh` rewrites
  to `<script>window.__PRS = [...]</script>`. The legacy marker
  `<!-- RUBRIC_INJECT -->` is also recognized for backward
  compatibility.
- When `window.__PRS` is populated, the header badge reads
  `live · N` and the simulation replays the injected PRs. Otherwise
  the badge reads `synthetic · N`.

## Hardening requirements

- **XSS.** No dynamic content is injected via `innerHTML`. All
  user-supplied or injected data (path globs, PR titles, author
  handles, paths) is rendered through `textContent` or DOM node
  creation.
- **Input validation.** Protected-path input is trimmed, length-capped
  at 200 characters, deduped, and rejected if it contains characters
  outside `[A-Za-z0-9_.\-/*?[\]{}:@+,!~$^=]`. The list is capped at
  25 entries.
- **Glob safety.** Glob compilation is wrapped in try/catch; an
  invalid pattern falls back to "no match" rather than throwing.
- **Clipboard.** Uses `navigator.clipboard.writeText` when available
  in a secure context, and falls back to a hidden-textarea
  `document.execCommand('copy')`. Both success and failure surface
  via the live region.
- **Accessibility.** The modal is a true dialog: `role="dialog"`,
  `aria-modal`, `aria-labelledby`, `aria-describedby`, focus moves
  into the dialog on open and returns to the trigger on close, Tab
  wraps within the dialog, Escape closes. An `aria-live="polite"`
  region announces path add/remove, preset application, YAML and
  command copy. Reduced-motion preferences are respected.
- **PR normalization.** Injected PR entries are coerced through a
  `normalizePR` function that tolerates missing fields; malformed
  entries are dropped rather than crashing the render.

## Non-goals

- Writing to `.github/review-policy.yml`, to the repo, or to any
  server. The dashboard is read-only against the repo.
- Loading the live policy from disk. The YAML panel is a preview of
  the draft built from the current knobs, not a render of the repo's
  current policy.
- Covering every key in the full policy schema. The page is a
  playground for the frequently-tuned subset.
