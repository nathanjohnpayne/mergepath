# Mergepath Playground

Feature: static, single-file review-policy playground. One surface of the Mergepath system — future surfaces (Cockpit, Tiebreaker, Checks) are reserved, see [`BRAND.md`](../BRAND.md).

## Acceptance criteria

- The dashboard lives at `mergepath/playground/index.html` and is a single self-contained HTML file with no network, build, or runtime dependencies.
- The page opens directly from the filesystem and renders a synthetic set of sample PRs when no live data has been injected.
- The left control rail exposes, at minimum:
  - external review threshold (slider)
  - protected-path globs (add / remove chips)
  - CodeRabbit toggle
  - Codex toggle with a max-review-rounds slider and a "request `@codex` on every PR" checkbox (mirrors `codex.request_by_default`; greyed out / hidden with the rest of the Codex nested controls when the Codex toggle is off)
  - reviewer-identity checkboxes
  - a feedback-policy panel: an "address or rebut all feedback" switch (mode `address-all`) and, when it is off (mode `by-priority`), a "require disposition by priority" checkbox group — P0 / P1 / P2 / P3. A checked tier is `required`; unchecked is `discretionary` (`ignore` is a YAML-only advanced value). When the address-all switch is on, the per-tier checkboxes are forced checked and disabled and the group greys out — the same visual cue the Codex nested controls use when the Codex toggle is off.
  - Strict / Standard / Loose presets
- The right workspace shows summary stats, a per-PR routing flow, and a live YAML preview of the draft policy with a copy-to-clipboard button.
- The YAML preview reflects the current knob state and matches the schema of `.github/review-policy.yml` for the subset of keys the UI exposes. When Codex is enabled, the `codex:` block serializes `request_by_default` alongside `enabled` and `max_review_rounds`.
- The YAML preview serializes a `feedback_policy:` block from the feedback-policy panel. In `address-all` mode it emits only `mode: address-all` and **omits** the `priorities:` map (that map is ignored in that mode). In `by-priority` mode it emits `mode: by-priority` plus a `priorities:` map with each tier set to `required` (checked) or `discretionary` (unchecked). The preview also always carries the two feedback-gate switches — `codex.p1_gate.enabled` (nested under `codex:`) and `coderabbit.severity_gate.enabled` (nested under `coderabbit:`) — so it stays a legal drop-in for `.github/review-policy.yml`.
- Changing any knob updates stats, flows, and YAML without a full reload. With the "request `@codex` on every PR" checkbox on, the routing flow shows the Phase 4a (Codex) leg on **every** PR, not only above-threshold ones.
- The control rail and workspace are their own scroll containers. In the side-by-side (desktop) layout they scroll in sync: scrolling one advances the other proportionally so a long PR list and a short control stack stay aligned without the shorter pane getting stranded. At the `max-width: 960px` stacked breakpoint the columns stack vertically and scroll independently — the sync is disabled there (it would otherwise fight the user), gated on a `matchMedia('(max-width: 960px)')` check read live on each scroll.
- The page carries an HTML comment injection marker `<!-- MERGEPATH_INJECT -->` that `scripts/policy-sim.sh` rewrites to `<script>window.__PRS = [...]</script>`. The legacy marker `<!-- RUBRIC_INJECT -->` is also recognized for backward compatibility. The injected JSON must be script-safe serialized — `<`, `>`, `&`, and the line/paragraph separators `U+2028` / `U+2029` are escaped to their `\uXXXX` forms before embedding — so a PR title or path containing `</script>` cannot terminate the inline block and inject markup.
- When `window.__PRS` is populated, the header badge reads `live · N` and the simulation replays the injected PRs. Otherwise the badge reads `synthetic · N`.

## Hardening requirements

- **XSS.** No dynamic content is injected via `innerHTML`. All user-supplied or injected data (path globs, PR titles, author handles, paths) is rendered through `textContent` or DOM node creation.
- **Input validation.** Protected-path input is trimmed, length-capped at 200 characters, deduped, and rejected if it contains characters outside `[A-Za-z0-9_.\-/*?[\]{}:@+,!~$^=]`. The list is capped at 25 entries.
- **Glob safety.** Glob compilation is wrapped in try/catch; an invalid pattern falls back to "no match" rather than throwing.
- **Clipboard.** Uses `navigator.clipboard.writeText` when available in a secure context, and falls back to a hidden-textarea `document.execCommand('copy')`. Both success and failure surface via the live region.
- **Accessibility.** The modal is a true dialog: `role="dialog"`, `aria-modal`, `aria-labelledby`, `aria-describedby`, focus moves into the dialog on open and returns to the trigger on close, Tab wraps within the dialog, and the modal closes on Escape **or** on a click on the backdrop outside the dialog surface (the backdrop click is ignored when it originates inside the dialog). An `aria-live="polite"` region announces path add/remove, preset application, YAML and command copy. Reduced-motion preferences are respected.
- **PR normalization.** Injected PR entries are coerced through a `normalizePR` function that tolerates missing fields; malformed entries are dropped rather than crashing the render.

## Non-goals

- Writing to `.github/review-policy.yml`, to the repo, or to any server. The dashboard is read-only against the repo.
- Loading the live policy from disk. The YAML panel is a preview of the draft built from the current knobs, not a render of the repo's current policy.
- Covering every key in the full policy schema. The page is a playground for the frequently-tuned subset.
