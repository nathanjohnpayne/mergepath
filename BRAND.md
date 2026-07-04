# Mergepath — brand vocabulary

**Mergepath** is the reference implementation of the AI Agent Tooling Standard. The Standard is methodology-neutral; Mergepath is one concrete implementation of it. The Standard lives in [`ai_agent_tooling_standard.md`](ai_agent_tooling_standard.md) and keeps its neutral framing; Mergepath is this repo.

## Surfaces

- **Mergepath Playground** — interactive review-policy prototyping UI. Lives at [`mergepath/playground/`](mergepath/playground/). Tune the policy knobs, replay recent PRs, copy the resulting YAML. Current.
- **Mergepath Cockpit** *(reserved)* — operator console for in-progress reviews. Future.
- **Mergepath Tiebreaker** *(reserved)* — disagreement and escalation resolver per [`REVIEW_POLICY.md`](REVIEW_POLICY.md) § Disagreements and Tiebreaking. Future.
- **Mergepath Checks** *(reserved)* — CI-surface integrations. Future.

Reserved names exist so a future agent doesn't pick "Cockpit" for the wrong surface. Don't scaffold files for these names until the surface is actually designed.

## Naming history

This project was originally `ai_agent_repo_template`. It was renamed to Mergepath when the umbrella scope (Playground, Cockpit, Tiebreaker, Checks) became clearer than "a template repo for agents." The underlying Standard kept its original name — Mergepath is the reference implementation of the Standard, not the Standard itself.
