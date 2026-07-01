# Mergepath Playground Plan

## Purpose

Justify the top-level `mergepath/` directory as the home for static,
single-file UI prototypes that illustrate how the template's
review-policy tooling is meant to be used. These prototypes must not
live in `dist/` (which is build output) or imply a production
application framework.

## Scope

1. Ship a single dashboard at `mergepath/playground/index.html`. Product
   name is **Mergepath Playground** — one surface of the Mergepath
   umbrella (see [`BRAND.md`](../BRAND.md)). The file is self-contained —
   no build step, no network, no auth.
2. Ship a helper `scripts/policy-sim.sh` that uses `gh` to pull the
   repo's recent merged PRs and bakes them into a temp copy of the
   dashboard via an HTML comment injection marker.
3. Document the dashboard in `mergepath/README.md` and formalize its
   intended behavior and hardening requirements in
   `specs/mergepath_playground.md`.
4. Exercise the dashboard and helper from
   `tests/test_mergepath_playground.sh` — verify structure, injection
   contract, XSS-safe rendering, and JavaScript syntactic validity.

## Deliberate cuts

Earlier iterations of this plan aimed for a full policy editor that
loaded and wrote back `.github/review-policy.yml`, surfaced an
identities panel, and exposed advanced Codex knobs (bot login,
reaction freshness, CI-green gate, timeouts). Those were cut. The
dashboard is now a playground for the frequently-tuned subset:
threshold, protected paths, automation toggles, max rounds, reviewer
roster, the feedback-disposition policy (address-all vs per-priority
tiers), and presets.

If a future iteration needs the full schema or read/write behavior, it
should ship as a separate page (likely `mergepath/cockpit/` — see the
reserved brand vocabulary in [`BRAND.md`](../BRAND.md)) and keep the
Playground simple.
