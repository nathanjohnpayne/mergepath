# Model Routing

> Canonical source: `mergepath/docs/agents/model-routing.md`. This file is propagated verbatim to consumer repos via the propagation manifest; edit it at the canonical source, never in a consumer copy. A change here reaches every repo through a propagation wave, so every sentence must be true in all of them.

This file owns one decision: which model and effort an issue should be routed to. It is the single home of the routing tier table, for agents filing an issue, for a board-triage pass, and for anyone re-routing an issue later.

It does not define how a route is recorded or honored. The `mergepath-route` marker, with its format, its value vocabulary, and the rules for writing and changing it, is defined in [Shared Agent Operating Rules § The route marker](shared-operating-rules.md#the-route-marker), and what an agent does with a route when it starts an issue is in [§ Starting an issue: read and honor its route](shared-operating-rules.md#starting-an-issue-read-and-honor-its-route). Use the table below to pick a tier, then record that tier's routes in the marker.

## Routing tiers

Every routed issue gets both an Anthropic route and an OpenAI route, because an agent from either provider may execute it. A `size:L` parent is not routed; each of its sub-issues is.

| Tier | Use when | Anthropic | OpenAI |
|---|---|---|---|
| Mechanical | `size:S`, fully specified, no judgment calls | Haiku 4.5, low | GPT-6 Luna, low |
| Conventional | `size:S` or `size:M`, follows existing patterns, clear repro | Sonnet 5.5, medium | GPT-6 Luna, medium (`size:S`); GPT-6.1 Sol, medium (`size:M`) |
| High-stakes | `size:M` with a real design choice; or touches auth, payments, persisted data, migrations, concurrency, CI gates, or review policy; or a bug without a repro | Opus 5.5, high | GPT-6.1 Sol, high |
| Frontier | Novel design with no existing pattern, a contract change that cannot be split, or the high-stakes route already failed on this issue | Fable 5.1, high | GPT-6 Astra, high |

## Choosing between two tiers

When an issue sits between two tiers, go up if it touches money, auth, persisted data, or merge gating; otherwise go down.

Ambiguity is not resolved by routing higher. If the tier depends on something the issue does not say (what the change touches, whether a repro exists, whether a design choice is open), the issue gets `decision-needed` and a stated question instead of a stronger route.

## Changing this table

A model or effort that is not already an option on the boards' routing fields cannot be recorded in a marker. Adding one means adding the option to every board's routing field and its marker value to the shared rules no later than the change that adds the row using it, so the table never names a route that cannot be written down.
