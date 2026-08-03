#!/usr/bin/env python3
"""owl-rules-check — verify the Mergepath rules ontology catches rule violations.

Loads docs/ontology/mergepath-rules.ttl (the TBox of OWL axioms encoding the
docs/ontology/rules.md catalog's configuration rules), runs the OWL-RL
deductive closure over it plus a fixture ABox, and reads the two detection
channels:

  1. individuals entailed into owl:Nothing (GCI-to-Nothing axioms);
  2. reasoner inconsistency messages (disjoint classes, disjoint properties,
     functional-property + differentFrom clashes), which owlrl records as
     err:ErrorMessage nodes in the closed graph.

Three passes, all of which must hold for --check to exit 0:

  A. the TBox alone is consistent (no catches);
  B. TBox + fixtures/consistent.ttl is consistent — the legal edge cases
     (under-threshold self-approval, same-head clearance, canonical
     propagation, templated identity-doc carriage) must NOT be flagged;
  C. TBox + fixtures/violations.ttl — every individual carrying
     mp:seededViolation must be caught, and no individual typed owl:Nothing
     may lack the seeding annotation (message-channel mentions of supporting
     individuals are expected and not counted as catches).

Self-bootstrap: if rdflib/owlrl are unavailable the check soft-passes
(exit 0) with a note, mirroring the repo's "soft-pass if the tool isn't
present yet" idiom (md-prose-wrap, repo_lint.yml). Install with:
  pip install rdflib owlrl

Exit codes: 0 pass (or soft-pass), 1 expectation failure, 2 usage/load error.
"""

import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
TBOX = REPO_ROOT / "docs" / "ontology" / "mergepath-rules.ttl"
CONSISTENT = REPO_ROOT / "docs" / "ontology" / "fixtures" / "consistent.ttl"
VIOLATIONS = REPO_ROOT / "docs" / "ontology" / "fixtures" / "violations.ttl"

# Ratchet: the number of seeded violation individuals the fixture must carry.
# Bump deliberately when adding an axiom + fixture; a lower live count fails,
# so deleting seeds (or emptying the fixture) can never buy a silent pass.
SEEDED_MIN = 19


def closure(*paths):
    """Parse the given Turtle files into one graph and expand its OWL-RL closure."""
    g = rdflib.Graph()
    for p in paths:
        g.parse(p, format="turtle")
    owlrl.DeductiveClosure(owlrl.OWLRL_Semantics).expand(g)
    return g


def catches(g):
    """Return (nothing_members, error_messages) — the two detection channels."""
    nothing = {
        s for s in g.subjects(RDF.type, OWL.Nothing) if isinstance(s, rdflib.URIRef)
    }
    # owlrl axiomatizes owl:Nothing subClassOf owl:Thing etc.; the class IRI
    # itself is never a violation.
    nothing.discard(OWL.Nothing)
    messages = sorted(
        str(o)
        for s in g.subjects(RDF.type, ERR.ErrorMessage)
        for o in g.objects(s, ERR.error)
    )
    return nothing, messages


def caught_in(term, nothing, messages):
    t = str(term)
    return term in nothing or any(t in m for m in messages)


def report_pass(name, ok, detail=""):
    print(f"  [{'ok' if ok else 'FAIL'}] {name}{': ' + detail if detail else ''}")
    return ok


def main():
    # Usage and fixture-presence errors report BEFORE the dependency soft-pass,
    # so a bad invocation or a gutted checkout can never ride the SKIP to 0.
    mode = sys.argv[1] if len(sys.argv) > 1 else "--check"
    if mode not in ("--check", "--report"):
        print(__doc__)
        return 2
    for p in (TBOX, CONSISTENT, VIOLATIONS):
        if not p.is_file():
            print(f"owl-rules-check: missing {p}")
            return 2

    global rdflib, RDF, OWL, MP, ERR, owlrl
    try:
        import rdflib
        from rdflib import RDF, OWL, Namespace
        import owlrl
    except ImportError:
        print("owl-rules-check: SKIP (rdflib/owlrl not installed; pip install rdflib owlrl)")
        return 0
    MP = Namespace("https://github.com/nathanjohnpayne/mergepath/ontology#")
    ERR = Namespace("http://www.daml.org/2002/03/agents/agent-ont#")

    ok = True
    print("owl-rules-check: OWL-RL closure over the Mergepath rules ontology")

    # Pass A — TBox alone.
    nothing, messages = catches(closure(TBOX))
    ok &= report_pass(
        "A: TBox alone is consistent",
        not nothing and not messages,
        f"{len(nothing)} owl:Nothing, {len(messages)} errors" if (nothing or messages) else "",
    )

    # Pass B — consistent control world.
    nothing, messages = catches(closure(TBOX, CONSISTENT))
    ok &= report_pass(
        "B: consistent control world stays clean",
        not nothing and not messages,
        "; ".join(messages[:3]) if (nothing or messages) else "",
    )

    # Pass C — every seeded violation is caught; nothing unseeded lands in owl:Nothing.
    g = closure(TBOX, VIOLATIONS)
    nothing, messages = catches(g)
    seeded = {s: str(next(g.objects(s, MP.seededViolation))) for s in g.subjects(MP.seededViolation, None)}
    witnesses = {s: set(g.objects(s, MP.violationWitness)) for s in seeded}

    # C0 — the seeded inventory itself is ratcheted: an emptied or trimmed
    # fixture fails rather than making C1 vacuously true.
    ok &= report_pass(
        f"C0: seeded inventory holds at least {SEEDED_MIN} violations",
        len(seeded) >= SEEDED_MIN,
        f"found {len(seeded)}",
    )

    def violation_caught(s):
        return caught_in(s, nothing, messages) or any(
            caught_in(w, nothing, messages) for w in witnesses[s]
        )

    missed = {s: r for s, r in seeded.items() if not violation_caught(s)}
    unexpected = {s for s in nothing if s not in seeded}

    for s, rule in sorted(seeded.items(), key=lambda kv: kv[1]):
        channel = (
            "owl:Nothing" if s in nothing
            else "inconsistency message" if caught_in(s, nothing, messages)
            else "via witness" if violation_caught(s)
            else "NOT CAUGHT"
        )
        print(f"    {rule:16s} {str(s).split('#')[-1]:32s} -> {channel}")

    ok &= report_pass("C1: every seeded violation is caught", not missed,
                      ", ".join(str(s).split("#")[-1] for s in missed) if missed else "")
    ok &= report_pass("C2: no unseeded individual entailed into owl:Nothing", not unexpected,
                      ", ".join(str(s).split("#")[-1] for s in unexpected) if unexpected else "")

    if mode == "--report":
        print("  inconsistency messages:")
        for m in messages:
            print(f"    - {m}")

    print(f"owl-rules-check: {'PASS' if ok else 'FAIL'} "
          f"({len(seeded)} seeded violations, {len(nothing)} in owl:Nothing, {len(messages)} messages)")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
