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

**Document validity is decided by a real parser, not by this list.** When `yq` is on `PATH` it rules on whether the file parses, and a document it rejects invokes. Enumerating malformed shapes does not terminate — review found tab indentation, then colonless children, then unclosed flow collections and undefined anchors, each a document no parser accepts and each reached only after the previous was patched — and deciding whether an arbitrary document parses *is* parsing YAML. `scripts/lib/ensure-yq.sh` is canonical to every consumer with a pinned version, so this adds no dependency.

Delegation is **validity only**. `yq` never supplies field values, and the reason is a defect this spec previously asserted was impossible: go-yaml resolves duplicate keys and duplicate blocks **last-wins and silently**, so `invoke: always` followed by `invoke: never` reads as a clean `never`. An earlier revision claimed the hand-rolled duplicate detector "runs first and stays authoritative" and therefore made value-reading safe. **That was false**, because the detector matches the block header at column zero and cannot see a consistently indented root *at all* — for that shape it never ran, `yq` applied last-wins, and the decider **skipped** review. The mutation test meant to pin the ordering used column-zero fixtures, so it passed throughout.

Reading fields through a parser therefore requires duplicate detection that also sees parser-discovered roots. Until that exists (#1090), `yq` answers exactly one question: does this document parse.

**Known limitation, deliberately fail-safe.** A consistently indented root mapping is legal YAML that the reader does not open, so it defaults to `always` and invokes — an explicit `invoke: never` there is not honoured. Flow-style (`coderabbit: {…}`) and anchored (`coderabbit: &policy`) block headers are classified as non-mappings and likewise invoke. A double-quoted block or direct key containing a YAML escape is conservatively treated as ambiguous rather than decoded; otherwise a semantic duplicate such as `"invo\u006be"` could sit beside `invoke: never` and suppress review. Nonliteral key forms are also ambiguous: tags (`!`), aliases (`*`), explicit mapping keys (`?`), and anchors (`&`) can all change the spelling visible to the local reader without changing the parser-resolved string key. These shapes cost an unnecessary wait; none can suppress a review, which is the asymmetry that governs every choice in this file. #1090 tracks replacing the field reader with parser-aware duplicate detection.

When `yq` is absent, the decider may not suppress review. CI first asks the canonical pinned bootstrap to provide the parser; if no parser is then available, the decision is `invoke` even when the local reader found `enabled: false`, `never`, or a routine `complex-changes` result. The hand-rolled reader detects strictly less, so accepting its suppressing answer alone would let malformed YAML elsewhere in the document skip a review. #1090 tracks replacing the field reader outright; parser-aware duplicate detection has to survive that migration.

The reader accepts ordinary YAML spellings rather than one fixed shape, and must not treat a legal spelling as absent:

- Block child indentation is **derived from the block's first child**, not assumed. A four-space-indented policy must be read, not silently defaulted. (A consistently indented *root* mapping is a separate, unhandled case — see the known limitation above.)
- A quoted key (`"invoke": …`) is the same key as its bare spelling, for both value lookup and duplicate detection.
- `invoke: "never"#junk` invokes. This is a **deliberate divergence** from go-yaml, which opens a comment straight after a closing quote and yields a clean `never`; the whitespace-before-`#` rule governs plain scalars, not that position. A value wearing unintended trailing junk is a typo, and the asymmetry holds — the cost of being wrong here is one unnecessary wait, the cost the other way is a silently skipped round.

And the reader must answer from the right place:

- Only **direct children** of `coderabbit:` are eligible. A nested map that shares a key name — `severity_gate.enabled` versus `coderabbit.enabled` — must never answer for its parent, in either document order. YAML mapping order is not semantic, so reordering two keys may not change the decision.
- A `#` inside a quoted scalar is content. Outside quotes it opens a comment only when preceded by whitespace.
- The policy is resolved from the script's own checkout, following symlinks, not from `$PWD`.

### Complexity assessment

- `complex-changes` defers to `scripts/phase-4b-classifier.sh` rather than defining a second notion of complexity. The Phase 4b trigger taxonomy is the repository's existing definition of a change warranting more eyes, and a second threshold would drift from it.
- The classifier is invoked with `--detect-only`, which suppresses its `phase_4b_default` short-circuits so the trigger detectors actually run. Those short-circuits answer "should 4b run" — a disposition question — and return no complexity signal: `fallback-only` exits 0 without inspecting, `always` exits 1 without inspecting.
- Selectivity is therefore independent of `phase_4b_default`. A routine PR skips under any 4b mode; a complex PR invokes under any 4b mode.
- If the classifier rejects `--detect-only` (exit `3`, an older copy on a not-yet-synced consumer), the call retries without it. An older classifier may then short-circuit with `files_inspected: 0`, which deliberately invokes CodeRabbit for every such unassessed PR until propagation catches up; compatibility does not preserve selectivity at the cost of silently skipping review.
- A classifier result reporting `files_inspected: 0` means the diff was not assessed — a short-circuit on an older copy, or an empty diff — and invokes.
- A changed-file entry with a missing, null, non-string, or empty `patch` makes the classifier exit as unassessed; content-based detectors did not inspect that file, so a no-match cannot safely suppress review.
- Any other classifier failure invokes.

### Consumer parity

- The decision is enforced **only** through agent instructions, so every runbook that describes Phase 2.5 must call the decider rather than reading `coderabbit.enabled` directly: `AGENTS.md`, `.github/copilot-instructions.md`, and the Phase 2.5 preamble in `.github/review-policy.yml`. An un-updated runbook is an un-implemented feature for whoever reads it.
- `mergepath/playground/index.html` must expose the mode as a control, carry it in state and in every preset, serialize it into the YAML preview, and reflect it in the routing simulation. A generated policy that omits `invoke` silently falls back to `always`.
