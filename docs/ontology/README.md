# The Mergepath ontology layer

Three artifacts model Mergepath's domain, complementing the root [`CONTEXT.md`](https://github.com/nathanjohnpayne/mergepath/blob/main/CONTEXT.md) glossary (the ubiquitous language):

- [`rules.md`](rules.md) — every normative rule of Mergepath documented in English with a stable ID (R-1…R-203 for the review pipeline, G-1…G-377 for structure, governance, the CodeRabbit configuration posture, and deployment — the `docs/agents` tree, the Standard, the manifest, and the canonical root `DEPLOYMENT.md`), each citing its canonical source. **●** marks configuration rules (machine-checkable arrangements of entities), **○** procedural ones.
- [`mergepath-rules.ttl`](mergepath-rules.ttl) — an OWL ontology formalizing a core subset of the ● rules as axioms whose violation a reasoner detects. Every violation-catching axiom carries an `mp:encodesRule` annotation naming the catalog IDs it encodes.
- [`fixtures/`](fixtures/) — `violations.ttl`, nineteen individuals each deliberately breaking one encoded rule (annotated `mp:seededViolation`; the checker's C0 ratchet pins the floor), and `consistent.ttl`, a correct world modeled on a real merged PR that also exercises the deliberately-legal edge cases (under-threshold self-approval, a same-head clearance, canonical propagation, an identity doc on a templated entry) which the axioms must not flag.

All three are **derived models**: on any divergence, `REVIEW_POLICY.md`, `AGENTS.md`, `rules/repo_rules.md`, the `docs/agents/` tree, and the propagation manifest win.

## Running the checker

```bash
python3 scripts/owl-rules-check.py --check
```

The checker loads the TBox, expands the OWL-RL deductive closure (pure-Python `rdflib` + `owlrl`, no Java), and verifies three passes: the TBox alone is consistent; the consistent control world produces no findings; every seeded violation is caught and no unseeded individual is entailed into `owl:Nothing`. `--report` additionally prints the reasoner's inconsistency messages. If `rdflib`/`owlrl` are not installed the check soft-passes with a note, mirroring the repo's md-prose-wrap idiom; install them with `pip install rdflib owlrl` (a venv works fine).

## How violations surface

Two detection channels, both read by the checker:

1. **`owl:Nothing` membership** — an axiom of the shape `C ⊓ ∃p.D ⊑ owl:Nothing` entails the offending individual directly into the empty class (e.g. a merged PR carrying a blocking label, a hub-only doc propagated to a consumer).
2. **Inconsistency messages** — disjoint-class, disjoint-property, and `sameAs`/`differentFrom` clashes surface as reasoner error messages naming the individuals involved. Some name a *witness* rather than the seeded subject (the reviewer identity inferred into `AuthorIdentity`, the two commits a stale clearance forces `sameAs`); fixtures declare these via `mp:violationWitness`.

The axiom shapes in use: class disjointness (identities, actor kinds, ownership classes, manifest entry types, threshold classes), property disjointness (`authoredByAgent` vs `phase4ApprovedByAgent` — the no-self-approve rule, correctly scoped so under-threshold self-approval stays legal), universal restrictions feeding disjointness (only the author identity merges or authors commits), GCIs to `owl:Nothing` (label gate, conversation gate, gate (a), human-thread resolution, denylist carriage, residue propagation), and a property chain plus a functional property (`mergeClearedBy ∘ anchorsCommit ⊑ prHead` with `prHead` functional — the HEAD-pinned clearance axiom that formalizes the stale-clearance/mutable-proxy failure the Merge clearance gate exists to close).

## What OWL catches, and honestly what it cannot

OWL reasoning is **open-world**: it detects *contradictions* — a forbidden configuration actually asserted — and that is exactly what these axioms encode. It cannot detect *missing evidence* (a merged PR with no recorded approval is satisfiable: the approval might merely be unstated), and it does not model *procedure* (orderings, waits, judgment calls — the ○ rules). One further boundary is the **OWL-RL profile** this checker runs: enumerations (`owl:oneOf`, used to pin the author identity and the two sanctioned label automations) do not classify new individuals under RL, so an *unclassified* individual in a restricted role is inferred into the restricting class rather than refuted; the RL-catchable case is an individual provably typed into a disjoint class, and a full-DL reasoner (e.g. HermiT) would additionally refute via the enumerations. Likewise the Phase 4 approval specialization (`phase4ApprovedByAgent`) is asserted by whoever populates the ABox, not derived from the PR's threshold class — deriving it would need rules beyond RL (SWRL) — so the modeling layer mirrors the threshold check, and the guard hook remains the operational enforcement of the no-self-approve rule. Those remain the province of the shell gates, the guard hooks, and reviewers: the `scripts/ci/check_*` roster and the required-check workflows are the closed-world enforcement, and this layer is a complementary formal net over the relational core, not a replacement for them.

## Maintenance

When a rule changes at its source: update the catalog entry in `rules.md` first; if the rule is encoded, update the axiom and keep its `mp:encodesRule` annotation accurate; seed or adjust a violation fixture for any new axiom (with a `mp:violationWitness` when the reasoner surfaces a different individual); run the checker. The checker is enforced in CI by the mergepath-local workflow `.github/workflows/owl-rules-check.yml`, which installs the pinned reasoner stack and runs `--check` on every push and PR — the same standalone, deliberately-unpropagated posture as the md-prose-wrap gate. It is not wired into the propagated `repo_lint.yml`, so consumer CI is untouched.
