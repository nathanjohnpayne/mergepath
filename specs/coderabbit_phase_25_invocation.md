# CodeRabbit Phase 2.5 Invocation

Feature: `scripts/coderabbit-should-invoke.sh` decides whether Phase 2.5 runs for a given PR, so that the agent's CodeRabbit wait is spent on changes that warrant it instead of on every one-line docs PR. The decision is a script rather than agent judgement because it must be reproducible across sessions, across agents, and identically in CI and at the keyboard. This spec pins the decision contract, the parsing rules that feed it, and the boundary of what the knob does and does not control.

## Scope boundary

- The knob gates **Phase 2.5**: the agent's wait and disposition. It does **not** stop the CodeRabbit App from reviewing. The shipped `.coderabbit.yml` sets `auto_review.enabled: true`, so the App starts on PR open, before this decision runs.
- Skipping therefore saves the agent's wait (bounded by `coderabbit.max_wait_seconds`). It does **not** reduce provider invocations or rate-limit pressure, and findings the App posts afterwards remain unresolved review conversations that the pre-merge conversation gate blocks on — a skipped PR can still need thread triage.
- Reducing invocations requires an App-side opt-out (`auto_review` off, or path filters) and is out of scope for this contract.

## Acceptance criteria

### Decision contract

- Exit `0` invokes Phase 2.5, exit `1` skips it, exit `3` is a usage error. There is deliberately **no** config-error exit: the two directions are not symmetric, so every ambiguity resolves toward invoking.
- `coderabbit.enabled: false` skips regardless of `invoke`.
- `coderabbit.invoke` accepts exactly three literals: `always`, `complex-changes`, `never`. An absent key means `always`, so a repo that has not adopted the knob is unaffected.
- Any value that is not exactly one of those three literals invokes, and says so on stderr. Normalization must never manufacture a valid mode out of input that does not unambiguously contain one.
- `--json` is emitted by a JSON encoder, never by string interpolation, and requires `jq`; its absence is exit `3` rather than a decision code with empty output.

### Fail-toward-invoking parsing

The reader answers only from an unambiguous file. Each of the following invokes rather than resolving to a value:

- More than one top-level `coderabbit:` block, even when every field inside occurs once.
- A direct field appearing more than once within the block.
- An unterminated quoted scalar (`invoke: "never`).
- A quoted scalar followed by anything other than whitespace or a comment (`invoke: "never" junk`).
- An unreadable or absent config file.

The reader accepts ordinary YAML spellings rather than one fixed shape, and must not treat a legal spelling as absent:

- Block child indentation is **derived from the block's first child**, not assumed. A four-space-indented policy must be read, not silently defaulted.
- A quoted key (`"invoke": …`) is the same key as its bare spelling, for both value lookup and duplicate detection.
- A `#` opens a comment only when preceded by whitespace, so `invoke: "never"#junk` is malformed rather than a commented value.

And the reader must answer from the right place:

- Only **direct children** of `coderabbit:` are eligible. A nested map that shares a key name — `severity_gate.enabled` versus `coderabbit.enabled` — must never answer for its parent, in either document order. YAML mapping order is not semantic, so reordering two keys may not change the decision.
- A `#` inside a quoted scalar is content. Outside quotes it opens a comment only when preceded by whitespace.
- The policy is resolved from the script's own checkout, following symlinks, not from `$PWD`.

### Complexity assessment

- `complex-changes` defers to `scripts/phase-4b-classifier.sh` rather than defining a second notion of complexity. The Phase 4b trigger taxonomy is the repository's existing definition of a change warranting more eyes, and a second threshold would drift from it.
- The classifier is invoked with `--detect-only`, which suppresses its `phase_4b_default` short-circuits so the trigger detectors actually run. Those short-circuits answer "should 4b run" — a disposition question — and return no complexity signal: `fallback-only` exits 0 without inspecting, `always` exits 1 without inspecting.
- Selectivity is therefore independent of `phase_4b_default`. A routine PR skips under any 4b mode; a complex PR invokes under any 4b mode.
- If the classifier rejects `--detect-only` (exit `3`, an older copy on a not-yet-synced consumer), the call retries without it, so propagation lag degrades to the previous behaviour instead of invoking on everything.
- A classifier result reporting `files_inspected: 0` means the diff was not assessed — a short-circuit on an older copy, or an empty diff — and invokes.
- Any other classifier failure invokes.

### Consumer parity

- The decision is enforced **only** through agent instructions, so every runbook that describes Phase 2.5 must call the decider rather than reading `coderabbit.enabled` directly: `AGENTS.md`, `.github/copilot-instructions.md`, and the Phase 2.5 preamble in `.github/review-policy.yml`. An un-updated runbook is an un-implemented feature for whoever reads it.
- `mergepath/playground/index.html` must expose the mode as a control, carry it in state and in every preset, serialize it into the YAML preview, and reflect it in the routing simulation. A generated policy that omits `invoke` silently falls back to `always`.
