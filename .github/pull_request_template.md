Authoring-Agent: <!-- claude | codex | cursor -->

> **Merge disposition — default: full automation.** This PR proceeds
> author → review → merge with no human checkpoint — reviewer-identity
> approval for under-threshold PRs, Phase 4 external clearance for
> above-threshold / protected-path PRs (where the authoring agent's reviewer
> identity posts `--comment` only). Agents do not pause to ask "should I
> merge?" / "how far should I take this?" — favoring automation is the point of
> Mergepath. The path defers to a human for only two reasons: (1) **the human
> says otherwise** — an explicit instruction, or a
> `human-hold` / `needs-human-review` / `policy-violation` label (`human-hold`
> is a human-remove-only freeze) — or (2) **a human handoff or escalation is
> required** — a Phase 4b handoff (an above-threshold / protected-path PR
> routed to external review) or a Phase 4a reviewer-disagreement escalation to
> the human tiebreaker. A stuck required gate is separate from merge
> disposition: red checks must go green, unresolved GitHub review conversations
> must be cleared, and a CodeRabbit rate-limit stall waits for human direction.

## Summary
- Describe the change.
- Call out any user-visible behavior or deployment notes.

## Testing
- [ ] Tests pass
- [ ] Build succeeds
- [ ] Manual verification completed when needed

## Self-Review
- [ ] Correctness: changes match stated requirements
- [ ] Regression risk: no unintended impact on existing behavior
- [ ] Style and conventions: follows repository standards
- [ ] Test coverage: new paths tested, existing tests passing
- [ ] Security and dependency hygiene: no new vulnerabilities or unnecessary deps
