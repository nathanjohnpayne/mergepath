#!/usr/bin/env bash
# tests/test_consumer_residue_safety.sh — hub-only RESIDUE-INVARIANCE net.
#
# ─────────────────────────────────────────────────────────────────────
# The gap this closes
# ─────────────────────────────────────────────────────────────────────
#
# tests/test_repo_lint_consumer_safety.sh builds its consumer model by
# STRIPPING a hand-written CONSUMER_ABSENT list out of the hub tree. A
# strip-only simulation can only ever exercise a check against MISSING
# files. Bootstrap residue is the opposite shape: a hub-only file that
# is unexpectedly PRESENT on a consumer, left behind by a bootstrap
# snapshot taken before the mirror exclusion existed. That state cannot
# be produced by stripping, so the existing net is structurally blind to
# it — and the model is optimistic in exactly one direction: stripping
# MORE than a real consumer lacks makes "both-absent" SKIP branches fire
# in simulation that never fire in reality.
#
# The live fleet proves it. gaycruisebingo (bootstrapped 2026-07-07)
# carries ~24 of the paths CONSUMER_ABSENT declares absent — including
# tests/test_repo_lint_consumer_safety.sh itself, the sweep pipeline, the
# 1Password headless-proof tooling, and the branch-protection auditor.
# The ONE exclusion that held on every consumer is the hub marker family
# (.mergepath-sync.yml + scripts/sync-to-downstream.sh + its paired test).
#
# ─────────────────────────────────────────────────────────────────────
# The invariant
# ─────────────────────────────────────────────────────────────────────
#
# Let W be a scripts/ci/check_* wrapper delivered by the scripts/ci/ kit,
# and let H(W) be the set of HUB-ONLY paths that W references. "Hub-only"
# is exactly the set this suite strips to build the consumer baseline:
# every `git ls-files` path under scripts/, tests/ or .github/workflows/
# that the sync manifest does NOT deliver (not an exact paths[].path, not
# inside a kit, not in any requires:). "References" means W's source
# contains the path literally OR contains "/<basename>" — see
# hub_only_refs() for the exact predicate and its residual blind spot.
# Then for a checkout where the hub marker scripts/sync-to-downstream.sh
# is ABSENT:
#
#     for every S subset of H(W):
#         verdict(W, tree + S)  ==  verdict(W, tree)
#
# where verdict is the pair (exit status, whether the canonical
# "<name>: SKIP (...)" line was emitted), and every "tree" in that statement
# is the SAME tree: each probe runs against a fresh restore of the committed
# fixture baseline, so a wrapper that writes cannot make probe N depend on
# probe N-1 (see fixture_reset).
#
# In words: on a consumer, the presence or absence of hub-only bootstrap
# residue must not change a check's answer. A check may pass, and it may
# fail on a real consumer problem — but its verdict must be a function of
# what the manifest delivered, never of what a stale bootstrap left
# behind.
#
# Two STRUCTURAL assertions back the behavioural lattice up, because the
# lattice's own premises are not self-evident. Each is kept non-vacuous
# by a detector self-test near the end of this file, the same way the
# frozen #796 fixture keeps the lattice honest:
#
#   (S1) A wrapper that declares a consumer gate — it tests the hub
#        marker, or emits a "SKIP (consumer" / "consumer checkout" line —
#        must have a NON-EMPTY H, or be recorded in
#        MARKER_ONLY_CONSUMER_GATES. Rationale: H is derived by reading
#        the wrapper's TEXT, so a gate keyed on a dependency the reader
#        cannot see yields H = ∅, and an empty H means the lattice is
#        empty and the wrapper is silently never probed. "You declare a
#        consumer gate but I found no hub-only artifact for it to read"
#        is true and cheap, and unlike a wider regex it cannot be
#        defeated by spelling the dependency differently.
#   (S2) Every SKIP line such a wrapper EMITS must carry the canonical
#        "<name>: SKIP" prefix, because that literal is precisely what
#        run_probe greps for to decide the SKIP half of the verdict pair.
#        Both spellings exist in this tree ("<name>: SKIP (...)" in the
#        wrappers, "SKIP: <reason>" for tooling skips in the suites), so
#        without this the SKIP-ONLY class is enforceable only by
#        convention: a marker-guarded wrapper that prints
#        "SKIP: <name> (consumer checkout: ...)" reads as RUN on both
#        sides of the lattice and its divergence disappears.
#
# What the invariant deliberately does NOT say:
#   - Not "every check exits 0 on a consumer" (that is the #601 net's
#     job). Wrappers with H(W) empty AND no consumer gate — the whole
#     portable population — are simply not in scope here.
#   - Not "a hub-only check must never EXECUTE on a consumer". That
#     stronger rule is desirable but would force migrating ~20 wrappers;
#     a wrapper that executes hub tooling and still exits 0 under every
#     residue subset is invariant-clean here.
#   - Nothing about behaviour when the marker is PRESENT. Hub semantics
#     are untouched.
#   - Nothing about non-check_* propagated surfaces (workflows,
#     scripts/lib/, scripts/workflow/, scripts/phase-4b/).
#
# ─────────────────────────────────────────────────────────────────────
# Why this cannot rot the way CONSUMER_ABSENT did
# ─────────────────────────────────────────────────────────────────────
#
#   1. The consumer model is DERIVED, not hand-written. This suite never
#      reads CONSUMER_ABSENT. It computes hub-only-ness from
#      .mergepath-sync.yml with the same coverage predicate
#      check_propagation_closure documents, and builds the baseline tree
#      by removing every manifest-undelivered path under scripts/,
#      tests/ and .github/workflows/ from `git ls-files`.
#   2. The lattice's INPUT is that same derived set, not a declaration
#      the author controls. H(W) is a subset of the stripped paths, so a
#      new hub-only dependency enrols itself the moment the wrapper names
#      it — there is no bookkeeping to forget. (An earlier draft claimed
#      check_propagation_closure's ALLOW_LIST was the input and that "no
#      edit both satisfies closure and suppresses this test". That was
#      FALSE: closure's own extractor is a literal-text regex over
#      .sh/.cjs/.js, so a gate keyed on any other kind of file demanded
#      no closure declaration and enrolled in no lattice. Assertion S1
#      above is what actually closes that, and it is what the two
#      derivations' agreement can never do — see the cross-check below.)
#   3. Coverage is EXHAUSTIVE over the residue lattice, not a
#      reproduction of one observed fleet shape — so it does not depend
#      on knowing what any consumer happens to carry today.
#
# ─────────────────────────────────────────────────────────────────────
# Reproducibility: one universe, one starting tree
# ─────────────────────────────────────────────────────────────────────
#
# A ratchet is only worth as much as the reproducibility of the verdicts it
# ratchets, so two properties are enforced rather than assumed:
#
#   - ONE FILE UNIVERSE. The fixture is copied from `git ls-files`, the same
#     index H(W) and the strip loop are derived from — never from the working
#     tree, which would smuggle untracked files into the "consumer" as paths
#     no lattice can toggle, and would let a tracked-but-deleted path enter H
#     and abort a probe. A working tree that disagrees with its index is
#     refused up front, by name.
#   - ONE STARTING TREE. Every probe begins at a fresh restore of the
#     committed fixture baseline, so a wrapper that writes a cache, a ledger
#     or a generated file cannot manufacture or mask a later divergence.
#     Consumer CI runs each check once from a clean checkout; the lattice runs
#     one check hundreds of times, which is the only reason this needs saying.
#
# ─────────────────────────────────────────────────────────────────────
# Hub-only, hermetic, offline
# ─────────────────────────────────────────────────────────────────────
#
# Deliberately NOT in .mergepath-sync.yml: it needs the full hub tree and
# the manifest to derive the consumer shape, so it can never travel. `gh`
# is PATH-shimmed to fail closed and every token env var is unset, so no
# probe can reach live GitHub. Residue files carry REAL content (a stub
# that exits 0 would let a wrongly-proceeding wrapper pass), bounded by a
# per-probe `timeout`. yq + git + rsync + timeout are required; missing
# tooling → SKIP, matching the existing suite's posture.

set -euo pipefail

# Anti-recursion belt-and-braces. The wrapper is marker-first so a
# sandbox probe SKIPs before it could ever re-enter this suite, but
# tests/test_repo_lint_consumer_safety.sh (nested inside a probe when it
# is toggled in as residue) re-runs every wired check — refuse outright
# rather than recurse a second level deep.
if [ "${MERGEPATH_RESIDUE_SANDBOX:-0}" = "1" ]; then
  echo "test_consumer_residue_safety: SKIP (already inside a residue sandbox)"
  exit 0
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

for tool in yq git rsync timeout; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "SKIP: $tool not available" >&2
    exit 0
  fi
done

MANIFEST="$ROOT/.mergepath-sync.yml"
CLOSURE="$ROOT/scripts/ci/check_propagation_closure"
if [ ! -f "$MANIFEST" ]; then
  echo "FAIL: $MANIFEST not found — this suite is hub-only and needs the manifest" >&2
  exit 1
fi

# Per-probe wall-clock bound. A wrapper that fails to skip actually
# attempts its hub suite inside a consumer-shaped tree — which is what
# happens on the consumer — so a timeout kill IS a divergence, and a
# wrapper that burns a minute of consumer CI is a defect regardless.
PROBE_TIMEOUT="${MERGEPATH_RESIDUE_PROBE_TIMEOUT:-60}"

# The hub marker is the FIXED premise of the invariant ("a checkout where
# scripts/sync-to-downstream.sh is absent"), not a lattice element. With
# the marker present a hub-only check is SUPPOSED to run, so toggling it
# would manufacture divergence for every marker-guarded wrapper.
HUB_MARKER="scripts/sync-to-downstream.sh"

PASS=0
FAIL=0
pass() { echo "PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $*" >&2; FAIL=$((FAIL + 1)); }
note() { echo "NOTE: $*"; }

# first_nonempty_line <newline-delimited list> → the first non-empty line.
#
# Deliberately NOT `printf '%s' "$list" | sed '/^$/d' | head -1`. `head`
# closes the pipe after its first line while the writer is still writing, so
# once the list outgrows the pipe buffer the writer takes SIGPIPE, `set -o
# pipefail` reports 141 for the whole pipeline, and `set -e` kills the suite
# mid-run — before a single detector self-test, the stale-ratchet sweep or
# the summary. Measured on this machine: a 167 KB list returns 141 every
# time, a 4-byte list returns 0, and the pipe buffer is where it flips. At
# today's 89 hub-only paths (~3.5 KB) the defect is unreachable, which is
# exactly what makes it worth removing rather than tolerating: it would
# arrive as a nondeterministic abort in whichever unrelated PR pushed the
# hub-only set past ~64 KB. Same class as the SIGPIPE trap documented in
# run_probe — a reader that must not be a coin toss must not sit at the end
# of a pipe.
#
# The heredoc is safe where a pipe is not: bash materialises it as a temp
# file (or as a pre-filled pipe when it fits), so there is no concurrent
# external writer to signal when this function returns early.
first_nonempty_line() {
  local line
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    printf '%s' "$line"
    return 0
  done <<EOF
$1
EOF
  return 0
}

# ---------------------------------------------------------------------------
# KNOWN_RESIDUE_VIOLATIONS — the ratchet.
# ---------------------------------------------------------------------------
#
# Wrappers that ALREADY violate residue invariance on main today, each
# recorded as "<check name>|<class>":
#
#   EXIT      — baseline exits 0 on the consumer-shaped tree, but some
#               residue subset makes it exit non-zero. This REDS a real
#               consumer's repo-lint once the next wave delivers the
#               wrapper and its repo_lint.yml step.
#   SKIP-ONLY — exit status is invariant (0 either way) but the canonical
#               consumer-SKIP line disappears: the wrapper executes hub
#               tooling on a consumer and passes by luck.
#
# Every entry is the SAME root cause: the wrapper decides "am I on a
# consumer?" with the both-absent idiom (its own hub-only artifact AND
# the marker must be missing to SKIP), so a bootstrap-residue copy of
# that artifact defeats the gate. The fix in each case is one line —
# test the marker FIRST, on its own — but each wrapper is a separate,
# separately-reviewable change, so they are grandfathered here rather
# than fixed in the PR that introduces this net.
#
# This list is a RATCHET, not an exemption list:
#   - a wrapper NOT listed that diverges          → FAIL (new regression)
#   - a wrapper listed that no longer diverges    → FAIL (stale entry;
#     delete it, so the list can never quietly outlive the bugs)
#   - a wrapper listed whose divergence CLASS
#     changed                                     → FAIL (re-verify)
#
# The class recorded here is the WORST class anywhere in the wrapper's
# lattice, not the class of the first divergent subset, and a listed wrapper
# is probed in escalation mode to establish it (see probe_wrapper). Stopping
# at the first divergence let a listed wrapper hide a NEW regression behind
# its recorded one: a SKIP-ONLY entry whose first divergent subset still only
# drops the SKIP line matched its record and passed even if some later subset
# had started EXITing non-zero — which is the class that actually reds a
# consumer's repo-lint. EXIT is the maximal class, so an entry already
# recorded EXIT settles at its first EXIT divergence and costs nothing extra.
#
# DO NOT add a new check here to make CI green. If a NEW wrapper trips
# this net, fix the wrapper: put the
#   [ -f "$REPO_ROOT/scripts/sync-to-downstream.sh" ] || { echo SKIP; exit 0; }
# marker test ABOVE any test of the wrapper's own hub-only artifacts.
# Marker-first keeps every protection the both-absent idiom claims: if
# the hub loses the wrapped test, the marker is still present, the guard
# does not skip, and the wrapper hard-errors exactly as before. The only
# case the pair idiom covers and marker-first does not — the marker
# deleted while the test survives — is already caught loudly and
# centrally by check_export_consumer_facts and check_sync_manifest.
KNOWN_RESIDUE_VIOLATIONS=(
  "check_admin_merge_codeowners_blocked|EXIT"
  "check_audit_canonical_mirrors|EXIT"
  "check_audit_codex_latency|EXIT"
  "check_audit_review_latency|EXIT"
  "check_bootstrap_board_and_summary|EXIT"
  "check_bootstrap_firebase_and_codereview|EXIT"
  "check_bootstrap_github_infra|EXIT"
  "check_bootstrap_sh|EXIT"
  "check_bootstrap_template_mirror|EXIT"
  "check_bootstrap_wizard|EXIT"
  "check_eslint_config_policy|SKIP-ONLY"
  "check_external_review_helpers|SKIP-ONLY"
  "check_onepassword_headless_proof_workflow|EXIT"
  "check_project_doc_sync|EXIT"
  "check_repo_lint_consumer_safety|EXIT"
  "check_session_finalization|EXIT"
  "check_sweep_unresolved_feedback|EXIT"
  "check_sync_overrides|EXIT"
  "check_sync_to_downstream|EXIT"
  "check_wave_audit|EXIT"
  "check_workflow_verify_propagation_templated|SKIP-ONLY"
)

known_class_of() {
  local name="$1" e
  for e in "${KNOWN_RESIDUE_VIOLATIONS[@]}"; do
    case "$e" in
      "$name|"*) printf '%s' "${e#*|}"; return 0 ;;
    esac
  done
  return 1
}

# ---------------------------------------------------------------------------
# MARKER_ONLY_CONSUMER_GATES — the (S1) exoneration ratchet.
# ---------------------------------------------------------------------------
#
# Wrappers that DO declare a consumer gate and legitimately have an empty
# H, because every file their gate reads is one of:
#
#   - scripts/sync-to-downstream.sh, the hub marker (the invariant's
#     fixed premise, deliberately not a lattice element), or
#   - .mergepath-sync.yml, the marker's definitional companion (stripped
#     from the baseline for the same reason, and absent on all nine live
#     consumers), or
#   - a path the manifest DOES deliver, whose absence is therefore a real
#     consumer defect rather than a bootstrap accident.
#
# Such a gate has nothing residue-shaped to read, so there is no lattice
# to enumerate and its emptiness is correct, not a measurement failure.
#
# This is a RATCHET, not an exemption list:
#   - a listed wrapper whose H is non-empty        → FAIL (stale entry;
#     it is enrolled in the lattice now, delete the entry)
#   - a listed wrapper that no longer exists       → FAIL (stale entry)
#   - a listed wrapper that no longer declares a
#     consumer gate                                → FAIL (stale entry)
#
# DO NOT add a wrapper here to silence assertion S1. The FAIL that sent
# you here means the wrapper's consumer decision reads a file this suite
# could not see, which is exactly the #796 shape — name the dependency by
# its literal path so it enrols in the lattice. An entry belongs here
# ONLY when the gate reads the marker, the manifest, or delivered files,
# and the justification must be recorded next to it.
MARKER_ONLY_CONSUMER_GATES=(
  # Gate: scripts/sync-to-downstream.sh (marker) + .mergepath-sync.yml
  # only. The wrapped tests/test_export_consumer_facts.sh IS manifest-
  # delivered, so it is never residue.
  "check_export_consumer_facts"
  # Gate: scripts/lib/template-substitution.sh + .mergepath-sync.yml, and
  # the lib is manifest-delivered (the wrapper's own header says so — it
  # keys hub-detection on the marker precisely because the lib travels).
  # tests/test_template_substitution.sh is delivered too.
  "check_template_substitution"
)

is_marker_only_gate() {
  local name="$1" e
  for e in "${MARKER_ONLY_CONSUMER_GATES[@]}"; do
    [ "$e" = "$name" ] && return 0
  done
  return 1
}

# ---------------------------------------------------------------------------
# Manifest coverage predicate — the SAME derivation check_propagation_closure
# documents: an exact paths[].path, a declared requires:, or strictly inside
# a kit subtree (slash-bounded, so scripts/ci/ does not cover scripts/cinema/).
# ---------------------------------------------------------------------------
if ! exact_rows=$(yq -r '.paths[].path' "$MANIFEST" 2>&1); then
  echo "FAIL: could not extract manifest paths (yq error):" >&2
  printf '%s\n' "$exact_rows" >&2
  exit 1
fi
if ! requires_rows=$(yq -r '.paths[] | select(has("requires")) | .requires[]' "$MANIFEST" 2>&1); then
  echo "FAIL: could not extract manifest requires: entries (yq error):" >&2
  printf '%s\n' "$requires_rows" >&2
  exit 1
fi
if ! kit_rows=$(yq -r '.paths[] | select(.type == "kit") | .path' "$MANIFEST" 2>&1); then
  echo "FAIL: could not extract kit paths (yq error):" >&2
  printf '%s\n' "$kit_rows" >&2
  exit 1
fi
if [ -z "$exact_rows" ]; then
  echo "FAIL: manifest yielded ZERO paths — refusing to run against an empty coverage set" >&2
  exit 1
fi

exact_set=",$(echo "$exact_rows" | tr '\n' ',')"
requires_set=",$(echo "$requires_rows" | tr '\n' ',')"
kit_prefixes=""
while IFS= read -r kp; do
  [ -z "$kp" ] && continue
  case "$kp" in
    */) kit_prefixes="$kit_prefixes $kp" ;;
    *)  kit_prefixes="$kit_prefixes $kp/" ;;
  esac
done <<< "$kit_rows"

is_covered() {
  local ref="$1" kp
  [[ "$exact_set" == *",$ref,"* ]] && return 0
  [[ "$requires_set" == *",$ref,"* ]] && return 0
  for kp in $kit_prefixes; do
    [[ "$ref" == "$kp"* ]] && return 0
  done
  return 1
}

# ---------------------------------------------------------------------------
# check_propagation_closure's ALLOW_LIST, parsed out for the bookkeeping
# cross-check below.
# ---------------------------------------------------------------------------
#
# SCOPE, stated honestly: this is NOT an independent derivation of
# hub-only-ness. check_propagation_closure extracts references with the
# same literal-text idea this suite started from (its regex at the
# "Extract candidate references" comment covers tests/ + scripts/ paths
# ending .sh/.cjs/.js), so the two can only ever disagree about
# ALLOW_LIST BOOKKEEPING — a ref one of them classifies as needing a
# declaration and the other does not. A dependency neither extractor can
# see is invisible to both, which is precisely why assertion S1 exists.
# The cross-check is therefore applied only to the refs closure's own
# extractor would have demanded a declaration for; anything outside that
# shape (a .py, a .txt, an extension-less script) is silently outside its
# reach and is covered by the lattice + S1 instead.
#
# Entries are stored in an ARRAY, never a whitespace-split string: several
# are globs (scripts/bootstrap/*, tests/test_audit*) and an unquoted
# expansion in a `for` list would pathname-expand them against the CWD,
# silently replacing the pattern with whatever happens to be on disk.
ALLOW_PATTERNS=()
if [ -f "$CLOSURE" ]; then
  while IFS= read -r allow_line; do
    [ -z "$allow_line" ] && continue
    ALLOW_PATTERNS[${#ALLOW_PATTERNS[@]}]="$allow_line"
  done <<EOF
$(awk '
    /^ALLOW_LIST=\(/ { inlist = 1; next }
    inlist && /^\)/   { inlist = 0 }
    inlist {
      sub(/#.*$/, "")
      gsub(/"/, "")
      gsub(/^[ \t]+|[ \t]+$/, "")
      if ($0 != "") print
    }
  ' "$CLOSURE")
EOF
fi
if [ "${#ALLOW_PATTERNS[@]}" -eq 0 ]; then
  echo "FAIL: parsed ZERO entries out of $CLOSURE's ALLOW_LIST — the cross-derivation check would be vacuous" >&2
  exit 1
fi

is_allow_listed() {
  local ref="$1" pat
  for pat in "${ALLOW_PATTERNS[@]}"; do
    # shellcheck disable=SC2254  # intentional glob match against the pattern
    case "$ref" in
      $pat) return 0 ;;
    esac
  done
  return 1
}

# ---------------------------------------------------------------------------
# The fixture's file universe is the INDEX, never the working tree.
# ---------------------------------------------------------------------------
#
# H(W) and the strip loop are both derived from `git ls-files`, so the copy
# that seeds the fixture has to come from the same place. An earlier draft
# rsynced the WORKING TREE instead, which mixed the two universes and let a
# dirty checkout break the model in both directions:
#
#   - An UNTRACKED file under scripts/, tests/ or .github/workflows/ survives
#     into the "consumer" fixture as a path no lattice can toggle. It is
#     constant across every probe, so it can never manufacture a divergence
#     — but it can MASK one: a local scratch copy of a hub-only artifact
#     satisfies a wrapper's required-file loop on every subset, and the
#     wrapper then reads as residue-invariant when it is not.
#   - A TRACKED path deleted from the working tree is the mirror image: it
#     is still in the index, so it still enters H, and the residue `cp` for
#     it used to abort the entire suite with a bare error.
#
# Copying from `git ls-files -z` fixes the first at the source and needs no
# exclude list at all: .git (a FILE in a linked worktree, which is why the
# '.git/' pattern was wrong and cost the #601 suite a fixture `git commit`
# on the real branch), node_modules/ and .DS_Store are untracked by
# construction, so none of them can reach the fixture. The second is caught
# up front by missing_tracked_paths, which names every offending path at
# once instead of dying on whichever one a lattice happened to reach first.
# CI checkouts are clean, so this is about local reproducibility: a run on
# your machine now models the same consumer CI does.

# tracked_list_z <repo> <outfile> — the index, NUL-delimited.
tracked_list_z() {
  git -C "$1" ls-files -z > "$2"
}

# missing_tracked_paths <repo> <NUL list> → newline list of index entries
# with nothing on disk (a `rm` without a `git rm`). -L as well as -e so a
# deliberately broken symlink is not reported as missing.
missing_tracked_paths() {
  local repo="$1" list="$2" rel
  while IFS= read -r -d '' rel; do
    [ -e "$repo/$rel" ] || [ -L "$repo/$rel" ] || printf '%s\n' "$rel"
  done < "$list"
}

# copy_tracked_tree <repo> <dst> <NUL list> — copy exactly the index.
# --files-from implies --relative, so each entry lands at the same path
# under <dst>; -a keeps modes (the executable bit matters) and times.
copy_tracked_tree() {
  rsync -a --from0 --files-from="$3" "$1/" "$2/"
}

# ---------------------------------------------------------------------------
# Build the DERIVED consumer baseline once.
# ---------------------------------------------------------------------------
WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/consumer-residue-safety.XXXXXX")"
trap 'rm -rf "$WORKDIR"' EXIT
FIX="$WORKDIR/consumer"
STAGE="$WORKDIR/stage"
mkdir -p "$FIX" "$STAGE"

TRACKED_Z="$WORKDIR/tracked.z"
tracked_list_z "$ROOT" "$TRACKED_Z"
if [ ! -s "$TRACKED_Z" ]; then
  echo "FAIL: git ls-files returned nothing for $ROOT — refusing to model a consumer from an empty index" >&2
  exit 1
fi

MISSING_TRACKED="$(missing_tracked_paths "$ROOT" "$TRACKED_Z")"
if [ -n "$MISSING_TRACKED" ]; then
  echo "FAIL: the working tree disagrees with the index, so the derived consumer model would be wrong." >&2
  echo "      These paths are tracked but absent from disk:" >&2
  while IFS= read -r m; do
    [ -z "$m" ] && continue
    echo "        $m" >&2
  done <<EOF
$MISSING_TRACKED
EOF
  echo "      Restore them (git checkout -- <path>) or stage the deletion (git rm <path>), then re-run." >&2
  echo "      Every hub-only path is materialised from disk during the lattice, so a stale index entry would abort a probe mid-run." >&2
  exit 1
fi

copy_tracked_tree "$ROOT" "$FIX" "$TRACKED_Z"

# Strip every manifest-undelivered path under the three surfaces a
# consumer receives wholly by propagation. Derived from `git ls-files` +
# the manifest — nothing here is asserted by hand.
#
# .mergepath-sync.yml goes too: it is the marker's definitional companion
# (BOOTSTRAP_MIRROR_EXCLUDES excludes the pair together, and both are
# absent from all nine live consumers), and leaving it would make every
# manifest-gated wrapper behave as the hub.
#
# The stripped paths are retained as HUB_ONLY_PATHS: that set — not a
# regex over wrapper text — is the universe every H(W) is drawn from, so
# the lattice can only ever toggle files the derived consumer genuinely
# lacks.
STRIPPED=0
HUB_ONLY_PATHS=""
NL='
'
while IFS= read -r -d '' rel; do
  case "$rel" in
    scripts/*|tests/*|.github/workflows/*) ;;
    *) continue ;;
  esac
  case "$rel" in
    *"$NL"*)
      # HUB_ONLY_PATHS is newline-delimited from here down (H, the lattice,
      # every message). A path on a probed surface containing a newline would
      # corrupt all of it silently, so refuse rather than mis-model.
      echo "FAIL: tracked path on a probed surface contains a newline, which this suite's newline-delimited path sets cannot represent: $(printf '%q' "$rel")" >&2
      exit 1
      ;;
  esac
  if ! is_covered "$rel"; then
    rm -f "$FIX/$rel"
    HUB_ONLY_PATHS="$HUB_ONLY_PATHS$rel
"
    STRIPPED=$((STRIPPED + 1))
  fi
done < "$TRACKED_Z"
rm -f "$FIX/.mergepath-sync.yml"

# Prune the directory skeleton the strip emptied. The copy creates a parent
# directory for every tracked file including the hub-only ones, and the strip
# loop only removes FILES, so without this the "consumer" baseline still
# carries every hub-only DIRECTORY as an empty dir and a wrapper gating on
# `[ -d "$REPO_ROOT/scripts/sweep-unresolved-feedback" ]` would see the
# hub layout. (Constant across the lattice, so it could never produce a
# false FAIL — but the baseline should be consumer-accurate for -d tests
# too, and fixture_reset's `git clean -fd` keeps it that way per-probe.)
for surface in scripts tests .github/workflows; do
  [ -d "$FIX/$surface" ] || continue
  find "$FIX/$surface" -depth -type d -empty -exec rmdir {} \; 2>/dev/null || true
done

if [ "$STRIPPED" -eq 0 ]; then
  fail "derived consumer baseline stripped ZERO paths — the coverage predicate is broken"
  echo "test_consumer_residue_safety: $PASS passed, $FAIL failed"
  exit 1
fi
if [ -f "$FIX/$HUB_MARKER" ]; then
  fail "derived consumer baseline still carries the hub marker $HUB_MARKER"
  echo "test_consumer_residue_safety: $PASS passed, $FAIL failed"
  exit 1
fi

git -C "$FIX" init -q
# Fail-closed isolation assertion: the fixture repo's toplevel MUST be the
# fixture itself before any add/commit. If a stray gitdir pointer survived,
# abort rather than touch the real repo. (pwd -P on both sides: macOS
# mktemp yields /var/... which git reports as physical /private/var/...)
FIX_TOPLEVEL="$(git -C "$FIX" rev-parse --show-toplevel)"
FIX_PHYS="$(cd "$FIX" && pwd -P)"
if [ "$FIX_TOPLEVEL" != "$FIX_PHYS" ]; then
  echo "FATAL: fixture git toplevel is '$FIX_TOPLEVEL', expected '$FIX_PHYS' — refusing to run git writes" >&2
  exit 1
fi

# Every fixture git command is pinned twice over, because fixture_reset below
# runs `reset --hard` and `clean -fdx`. --git-dir/--work-tree on the command
# line outrank any core.worktree a probe could write into the fixture's
# config, so a probe cannot redirect a destructive command at the real repo;
# and fixture_reset re-checks that $FIX/.git is still a real repository
# directory. The assertion above ran once, before the first write; this pair
# holds for every write after it.
FIX_GIT=(git --git-dir="$FIX/.git" --work-tree="$FIX" -C "$FIX")

# fixture_commit <message> — stage everything and commit it as the new
# baseline. Explicit identity + gpgsign=false so the fixture never depends on
# (or is blocked by) the caller's git config; --allow-empty so a no-op
# cleanup commit cannot abort the suite.
#
# `add -A -f` — FORCE — because the fixture's index must mirror the UPSTREAM
# index, and this repo tracks files its own .gitignore excludes:
# .vscode/settings.json is tracked, yet `.vscode/` is an ignore rule (and
# git never descends into an excluded directory, so the sibling
# `!.vscode/extensions.json` negation cannot re-include anything either).
# Without -f such a file lands in the fixture as untracked-and-ignored, which
# is a state no real checkout is ever in: `git ls-files` inside the fixture
# would not list it, and fixture_reset's `clean -x` would delete it after the
# first probe — making the baseline probe the only one that saw the file. The
# cleanliness assertion below is what keeps this honest.
fixture_commit() {
  "${FIX_GIT[@]}" add -A -f
  "${FIX_GIT[@]}" \
    -c user.name="consumer-fixture" \
    -c user.email="consumer-fixture@example.invalid" \
    -c commit.gpgsign=false \
    commit -q --allow-empty -m "$1"
}

# Mirror the workflow's make_ci_scripts_executable step — BEFORE the baseline
# commit, so the executable bit is recorded in HEAD. After it, every mode
# change would be a permanent diff against HEAD that fixture_reset reverts.
chmod +x "$FIX"/scripts/ci/* 2>/dev/null || true

fixture_commit "derived consumer baseline"

# The fixture baseline must be a CLEAN checkout of its own index — nothing
# modified, nothing untracked, nothing ignored-but-present. That is the
# premise the whole lattice rests on: fixture_reset restores HEAD before
# every probe, so any file sitting outside HEAD is a file the FIRST probe sees
# and no later probe does. Cheap to assert, and it fails loudly on exactly the
# class of mistake that is otherwise invisible (see fixture_commit's -f note).
FIX_DIRT="$("${FIX_GIT[@]}" status --porcelain --ignored)"
if [ -n "$FIX_DIRT" ]; then
  echo "FAIL: the derived consumer baseline is not a clean checkout of its own index. These paths are present but not committed, so only the baseline probe would see them:" >&2
  while IFS= read -r d; do
    [ -z "$d" ] && continue
    echo "        $d" >&2
  done <<EOF
$FIX_DIRT
EOF
  echo "      A tracked-but-gitignored path is the usual cause — fixture_commit must stage with 'add -A -f'." >&2
  exit 1
fi

# Offline guard: a PATH-shimmed gh that fails closed. Hermetic checks
# prepend their own gh stubs (which win); anything reaching THIS shim was
# reaching for live GitHub.
SHIM="$WORKDIR/shim"
mkdir -p "$SHIM"
cat >"$SHIM/gh" <<'SH'
#!/usr/bin/env bash
echo "test_consumer_residue_safety: live gh call blocked (offline fixture): gh $*" >&2
exit 64
SH
chmod +x "$SHIM/gh"

echo "test_consumer_residue_safety: derived consumer baseline built ($STRIPPED manifest-undelivered path(s) stripped)"

# ---------------------------------------------------------------------------
# Probe engine.
# ---------------------------------------------------------------------------

# run_probe <check-name> → "<rc>|<RUN|SKIP>"
run_probe() {
  local name="$1" out rc verdict
  set +e
  out=$(
    cd "$FIX" && \
    env -u GH_TOKEN -u GITHUB_TOKEN \
        -u OP_PREFLIGHT_REVIEWER_PAT -u OP_PREFLIGHT_AUTHOR_PAT \
        GITHUB_REPOSITORY="nathanjohnpayne/consumer-fixture" \
        PATH="$SHIM:$PATH" \
        MERGEPATH_RESIDUE_SANDBOX=1 \
        timeout "$PROBE_TIMEOUT" bash "./scripts/ci/$name" </dev/null 2>&1
  )
  rc=$?
  set -e
  # Literal substring test in-process, NOT `printf ... | grep -qF`. Under
  # `set -o pipefail` a `grep -q` that matches early exits before draining
  # the pipe, the writer takes SIGPIPE, and the PIPELINE reports 141 — so
  # a matched SKIP line can read as RUN, nondeterministically, depending
  # on whether the writer finished first. Measured live on this suite: the
  # same idiom in the consumer-gate detector flipped check_sync_manifest
  # in 3 of 15 runs. A verdict reader must not be a coin toss.
  verdict="RUN"
  case "$out" in
    *"$name: SKIP"*) verdict="SKIP" ;;
  esac
  printf '%s|%s' "$rc" "$verdict"
}

# classify <baseline-verdict> <residue-verdict> → EXIT | SKIP-ONLY
classify() {
  local base="$1" res="$2"
  local brc="${base%%|*}" rrc="${res%%|*}"
  if [ "$brc" != "$rrc" ]; then
    printf 'EXIT'
  else
    printf 'SKIP-ONLY'
  fi
}

# ---------------------------------------------------------------------------
# Probe INDEPENDENCE: every probe starts from the committed baseline.
# ---------------------------------------------------------------------------
#
# A wrapper is entitled to WRITE. Checks in this tree generate files, write
# ledgers under .mergepath/, drop logs, and delete their own scratch output.
# Real consumer CI runs each one ONCE from a fresh checkout; the lattice runs
# one wrapper hundreds of times over the same directory, so without a reset
# probe N inherits probe N-1's leftovers and the verdict stops being a
# function of the residue subset:
#
#   - a leftover can MANUFACTURE a divergence — probe N fails on a sentinel
#     or a half-written cache the previous probe created, and the engine
#     reports a residue violation that no consumer would ever hit;
#   - a leftover can MASK one — a generated artifact satisfies the very
#     required-file loop the residue was supposed to trip, and a real
#     violation reads as invariant.
#
# Either way the answer depends on enumeration order, which is exactly the
# reproducibility the ratchet's PASS/FAIL rests on.
#
# Restoring the committed baseline covers all three shapes of leftover, and
# it takes all three flags to do it: `reset --hard` reverts modifications to
# tracked files AND removes the staged-but-uncommitted residue itself,
# `clean -fd` removes untracked files plus the directories they created
# (which is also what keeps `[ -d ... ]` gates consumer-accurate), and `-x`
# extends that to gitignored output — .mergepath/, tmp/, *.log are all
# ignored here, and a wrapper's ledger writes land exactly there.
#
# Corollary: anything a probe must SEE has to be COMMITTED to the fixture,
# never left staged. That is why the self-test wrappers below are committed.
fixture_reset() {
  if [ ! -d "$FIX/.git" ] || [ ! -f "$FIX/.git/HEAD" ]; then
    echo "FATAL: $FIX/.git is no longer a fixture repository — refusing to run destructive git commands" >&2
    exit 1
  fi
  "${FIX_GIT[@]}" reset -q --hard HEAD
  "${FIX_GIT[@]}" clean -qfdx
}

# residue_apply <H> <mask> <src> — reset to the baseline, then materialise
# exactly the masked subset. Sets RESIDUE_SUBSET to the applied subset (space
# separated). The reset is what makes the "unmasked" half implicit: after it,
# no residue and no side effect from the previous probe exists.
#
# Hot path: this runs once per probe over every element of H, so it uses
# ${r%/*} rather than $(dirname) — the subshell per element dominated an
# early profile (17k subshells on the |H|=32 wrapper alone).
RESIDUE_SUBSET=""
residue_apply() {
  local H="$1" mask="$2" src="$3" i=0 r sub="" d
  fixture_reset
  while IFS= read -r r; do
    [ -z "$r" ] && continue
    if [ $(( (mask >> i) & 1 )) -eq 1 ]; then
      # Named, diagnosable failure instead of a bare `cp` error killing the
      # suite. Unreachable for the real lattice — every H path is a tracked
      # path and missing_tracked_paths already refused a stale index entry up
      # front — so reaching it means the source tree changed mid-run.
      if [ ! -e "$src/$r" ]; then
        echo "FATAL: residue source $src/$r vanished mid-run — cannot materialise the subset, and a partial subset would produce a meaningless verdict" >&2
        exit 1
      fi
      d="${r%/*}"
      [ -d "$FIX/$d" ] || mkdir -p "$FIX/$d"
      cp -p "$src/$r" "$FIX/$r"
      sub="$sub $r"
    fi
    i=$((i + 1))
  done <<EOF
$H
EOF
  # Stage the residue so wrappers that enumerate with `git ls-files` see it.
  # -f for the same reason fixture_commit uses it: a residue path is tracked
  # upstream, so it must be tracked here even if a .gitignore rule matches it.
  "${FIX_GIT[@]}" add -A -f >/dev/null 2>&1 || true
  RESIDUE_SUBSET="${sub# }"
}

# popcount <n> → sets POPCOUNT (no subshell; called O(n * 2^n) times).
POPCOUNT=0
popcount() {
  local m="$1" c=0
  while [ "$m" -gt 0 ]; do
    c=$(( c + (m & 1) ))
    m=$(( m >> 1 ))
  done
  POPCOUNT="$c"
}

# residue_masks <n> → the lattice, as a newline list of masks in
# ascending-popcount order (so the smallest, most diagnostic subset is
# reached first). Exhaustive power set when 2^|H| <= 256; above that cap all
# singletons, then all pairs, then the full set — a 3-file interaction above
# the cap would slip, recorded as a known residual gap in the header of
# scripts/ci/check_consumer_residue_safety.
residue_masks() {
  local n="$1" total mask k i j out=""
  if [ "$n" -le 8 ]; then
    total=$(( (1 << n) - 1 ))
    for k in $(seq 1 "$n"); do
      for mask in $(seq 1 "$total"); do
        popcount "$mask"
        [ "$POPCOUNT" = "$k" ] || continue
        out="$out$mask
"
      done
    done
  else
    for i in $(seq 0 $((n - 1))); do
      out="$out$(( 1 << i ))
"
    done
    for i in $(seq 0 $((n - 2))); do
      for j in $(seq $((i + 1)) $((n - 1))); do
        out="$out$(( (1 << i) | (1 << j) ))
"
      done
    done
    out="$out$(( (1 << n) - 1 ))
"
  fi
  printf '%s' "$out"
}

# Results of the last probe_wrapper call. PROBE_CLASS / PROBE_SUBSET /
# PROBE_RESULT describe the WORST divergence observed (the one the ratchet is
# compared against); PROBE_FIRST_* describe the smallest divergent subset,
# which is the more diagnostic one to fix first. They differ only when a
# later, larger subset escalated the class.
PROBE_BASE=""
PROBE_DIVERGED=0
PROBE_CLASS=""
PROBE_SUBSET=""
PROBE_RESULT=""
PROBE_FIRST_CLASS=""
PROBE_FIRST_SUBSET=""
PROBE_FIRST_RESULT=""
PROBE_COUNT=0

# probe_wrapper <check-name> <H newline-list> <src dir> [stop-mode]
#
# stop-mode:
#   first       (default) stop at the first divergence. For a wrapper with no
#               KNOWN_RESIDUE_VIOLATIONS entry any divergence is a FAIL and
#               the fix is the same marker-first move, so the smallest subset
#               is all the caller needs.
#   escalation  keep enumerating PAST the first divergence until the worst
#               class (EXIT) is observed or the lattice is exhausted. Used for
#               GRANDFATHERED wrappers, where stopping at the first divergence
#               let a new regression hide behind the recorded one: a wrapper
#               recorded SKIP-ONLY whose first divergent subset still only
#               loses its SKIP line, but where some LATER subset now exits
#               non-zero, would match its entry and pass while newly redding
#               a real consumer's repo-lint.
#
# EXIT is the maximal class of the two, which is what makes the early stop in
# escalation mode sound: once an EXIT divergence is in hand nothing worse can
# be found, so a wrapper already recorded EXIT costs no extra probes, and the
# exhaustive scan is paid only by the three SKIP-ONLY entries — whose lattices
# are 1, 15 and 1 subsets wide. Today that is free: the divergence each of the
# three reports is already the LAST subset the enumeration reaches, so the
# suite's probe total is identical either way (596, measured before and after).
# What escalation mode deliberately does NOT report is a second
# divergence of the SAME class on a different subset: the recorded entry
# already declares that failure mode, one marker-first fix removes every
# subset at once, and the stale-entry rule fires the moment it does. Pinning
# the exact divergent subsets instead — the other option — would tie the
# ratchet to lattice enumeration order and to every unrelated edit that adds
# a hub-only path, so it would churn without adding a guarantee.
probe_wrapper() {
  local name="$1" H="$2" src="$3" mode="${4:-first}"
  local n mask res cls
  n=$(printf '%s\n' "$H" | grep -c . || true)

  PROBE_DIVERGED=0
  PROBE_CLASS=""
  PROBE_SUBSET=""
  PROBE_RESULT=""
  PROBE_FIRST_CLASS=""
  PROBE_FIRST_SUBSET=""
  PROBE_FIRST_RESULT=""
  PROBE_COUNT=0

  fixture_reset
  PROBE_BASE="$(run_probe "$name")"

  while IFS= read -r mask; do
    [ -z "$mask" ] && continue
    residue_apply "$H" "$mask" "$src"
    PROBE_COUNT=$((PROBE_COUNT + 1))
    res="$(run_probe "$name")"
    if [ "$res" != "$PROBE_BASE" ]; then
      cls="$(classify "$PROBE_BASE" "$res")"
      if [ "$PROBE_DIVERGED" -eq 0 ]; then
        PROBE_DIVERGED=1
        PROBE_FIRST_CLASS="$cls"
        PROBE_FIRST_SUBSET="$RESIDUE_SUBSET"
        PROBE_FIRST_RESULT="$res"
        PROBE_CLASS="$cls"
        PROBE_SUBSET="$RESIDUE_SUBSET"
        PROBE_RESULT="$res"
      elif [ "$cls" = "EXIT" ] && [ "$PROBE_CLASS" != "EXIT" ]; then
        PROBE_CLASS="$cls"
        PROBE_SUBSET="$RESIDUE_SUBSET"
        PROBE_RESULT="$res"
      fi
      if [ "$mode" != "escalation" ] || [ "$PROBE_CLASS" = "EXIT" ]; then
        break
      fi
    fi
  done <<EOF
$(residue_masks "$n")
EOF

  fixture_reset
  return 0
}

# hub_only_refs <wrapper file> <wrapper rel path> → newline list
#
# H(W): the subset of HUB_ONLY_PATHS — the exact set the derived consumer
# baseline strips — that W references, excluding W's own path and the hub
# marker (the marker is the invariant's fixed premise, not a lattice
# element; toggling it would manufacture divergence for every
# marker-guarded wrapper by design).
#
# The predicate is deliberately NOT a path-shaped regex with an extension
# list. The first draft extracted `(tests|scripts)/…\.(sh|cjs|js)` plus
# `.github/workflows/….ya?ml` and filtered THAT against the manifest,
# which meant a wrapper gating on any other kind of hub-only file — a
# .py, a .txt, an extension-less script — produced H = ∅ and was never
# probed, silently, with no output line to notice. Widening the extension
# list only moves that hole; it does not close it, and it never covers a
# path composed at runtime (TESTS_DIR="$REPO_ROOT/tests";
# SUITE="$TESTS_DIR/test_x.sh").
#
# Matching "/<basename>" against the derived hub-only set closes both:
# every hub-only path lives at least one directory deep, so its literal
# occurrence always contains "/<basename>", and a runtime-composed path
# still contains it ("$TESTS_DIR/test_x.sh" → "/test_x.sh"). There is no
# extension list left to fall behind, and enrolment is fail-open only in
# the harmless direction (a coincidental basename match costs probes, not
# correctness).
#
# Residual: a wrapper that composes the BASENAME itself
# ("$LIB/${STEM}.py") still yields H = ∅. That is what assertion S1 is
# for — such a wrapper cannot also hide the fact that it declares a
# consumer gate.
hub_only_refs() {
  local f="$1" rel="$2" src p bn out=""
  src="$(cat "$f")"
  while IFS= read -r p; do
    [ -z "$p" ] && continue
    [ "$p" = "$rel" ] && continue
    [ "$p" = "$HUB_MARKER" ] && continue
    bn="${p##*/}"
    case "$src" in
      *"/$bn"*) out="$out$p
" ;;
    esac
  done <<EOF
$HUB_ONLY_PATHS
EOF
  printf '%s' "$out" | sed '/^$/d'
}

# declares_consumer_gate <wrapper file> — 0 when the wrapper's CODE (full-line
# comments stripped, so a passing mention in prose does not count) tests the
# hub marker or emits a consumer-SKIP line. Deliberately coarse and
# fail-CLOSED: over-selecting costs a wrapper an S1/S2 assertion it passes
# trivially, under-selecting loses the assertion entirely.
#
# The match itself is an in-process `case`, not a second `grep -q` on the
# end of a pipe: see the SIGPIPE note in run_probe. This detector is the
# gate on both structural assertions, so a probabilistic answer here would
# silently switch them off for a wrapper — which it did, for
# check_sync_manifest, in 3 of 15 measured runs.
declares_consumer_gate() {
  local f="$1" code
  code="$(grep -v '^[[:space:]]*#' "$f" || true)"
  case "$code" in
    *"$HUB_MARKER"*)       return 0 ;;
    *"SKIP (consumer"*)    return 0 ;;
    *"consumer checkout"*) return 0 ;;
  esac
  return 1
}

# assert_canonical_skip_lines <wrapper file> <name> — assertion S2.
#
# run_probe decides the SKIP half of the verdict pair by grepping the
# wrapper's output for the literal "<name>: SKIP". Every SKIP a
# consumer-gated wrapper emits must therefore spell its own name that
# way; "SKIP: <name> (consumer checkout: ...)" — the other spelling in
# this tree, used by the SUITES for tooling skips ("SKIP: yq not
# available") — reads as RUN on both sides of the lattice and hides the
# whole SKIP-ONLY class. The name must appear LITERALLY: a runtime-
# assembled prefix (printf '%s: SKIP' "$n") is behaviourally fine but not
# statically checkable, so it is rejected too, with the same fix.
#
# Split into a pure predicate + a reporter so the detector itself can be
# self-tested below without touching the PASS/FAIL counters.
noncanonical_skip_lines() {
  local f="$1" name="$2" line
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    case "$line" in
      *"$name: SKIP"*) continue ;;
    esac
    printf '%s\n' "$line"
  done <<EOF
$(grep -nE '^[[:space:]]*(echo|printf).*SKIP' "$f" || true)
EOF
}

assert_canonical_skip_lines() {
  local f="$1" name="$2" line
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    fail "$name: non-canonical SKIP line — $line"
    echo "      This wrapper declares a consumer gate, and the residue verdict pair reads the literal '$name: SKIP' out of its output." >&2
    echo "      A SKIP spelled any other way makes the wrapper look like it RAN on both sides of the residue lattice, so a SKIP-ONLY divergence becomes invisible and this net reports PASS for the wrong reason." >&2
    echo "      Fix the wrapper: emit \"$name: SKIP (consumer checkout: ...)\". Reserve the 'SKIP: <reason>' spelling for tooling skips inside tests/, which are not verdicts." >&2
  done <<EOF
$(noncanonical_skip_lines "$f" "$name")
EOF
}

# ---------------------------------------------------------------------------
# Main pass: the two structural assertions over every scripts/ci/check_*,
# then the residue lattice for every wrapper with a non-empty H.
# ---------------------------------------------------------------------------
SEEN_VIOLATORS=""
SEEN_MARKER_ONLY=""
ENTANGLED=0
GATED=0
TOTAL_PROBES=0

while IFS= read -r f; do
  [ -z "$f" ] && continue
  name="$(basename "$f")"
  rel="scripts/ci/$name"
  H="$(hub_only_refs "$f" "$rel")"

  gate=0
  if declares_consumer_gate "$f"; then
    gate=1
    GATED=$((GATED + 1))
    # (S2) — the behavioural detector's premise.
    assert_canonical_skip_lines "$f" "$name"
  fi

  if [ -z "$H" ]; then
    # (S1) — a declared consumer gate with nothing to toggle.
    if [ "$gate" -eq 1 ]; then
      if is_marker_only_gate "$name"; then
        SEEN_MARKER_ONLY="$SEEN_MARKER_ONLY$name
"
        pass "$name: consumer gate reads no hub-only artifact (recorded in MARKER_ONLY_CONSUMER_GATES)"
      else
        fail "$name: declares a consumer gate (hub-marker test and/or a consumer-SKIP line) but H is EMPTY — no hub-only artifact was found for that gate to read, so this wrapper is enrolled in NO residue lattice and this net can say nothing about it."
        echo "      That is the #796 shape exactly: a consumer-SKIP decision keyed on a hub-only file the reference reader cannot see falls through on any consumer that carries the file as bootstrap residue, and no gate objects." >&2
        echo "      Fix the wrapper: name every hub-only file its gate reads by its literal path (\"\$REPO_ROOT/tests/test_x.sh\", not \"\$TESTS_DIR/\${STEM}.sh\"), so the path enrols in the lattice." >&2
        echo "      ONLY if the gate genuinely reads nothing but scripts/sync-to-downstream.sh, .mergepath-sync.yml, or manifest-DELIVERED files, record it in MARKER_ONLY_CONSUMER_GATES with that justification." >&2
      fi
    fi
    continue
  fi

  if is_marker_only_gate "$name"; then
    SEEN_MARKER_ONLY="$SEEN_MARKER_ONLY$name
"
    fail "$name: STALE MARKER_ONLY_CONSUMER_GATES entry — H is non-empty now ($(printf '%s' "$H" | tr '\n' ' ')), so the wrapper IS enrolled in the lattice. Delete its entry."
  fi

  ENTANGLED=$((ENTANGLED + 1))

  # ALLOW_LIST bookkeeping cross-check — NOT an independent derivation.
  # check_propagation_closure FAILS the PR unless every propagated,
  # on-disk, manifest-undelivered tests//scripts/ ref MATCHING ITS OWN
  # EXTRACTOR (.sh/.cjs/.js) is on its ALLOW_LIST. Restricting the
  # comparison to that shape is the honest scope: outside it closure never
  # looked, so a disagreement would be an artefact of the two extractors'
  # different reach rather than drift. Within it, a disagreement means
  # closure is failing this PR or one of the two predicates has moved.
  while IFS= read -r ref; do
    [ -z "$ref" ] && continue
    case "$ref" in
      scripts/*.sh|tests/*.sh|scripts/*.cjs|tests/*.cjs|scripts/*.js|tests/*.js) ;;
      *) continue ;;
    esac
    if ! is_allow_listed "$ref"; then
      fail "$name: hub-only ref '$ref' is NOT on check_propagation_closure's ALLOW_LIST — the two derivations disagree over bookkeeping (closure should already be failing this PR; declare the ref there)"
    fi
  done <<EOF
$H
EOF

  # A grandfathered wrapper is probed in escalation mode: its recorded class
  # must be the WORST class in its lattice, not merely the first one found,
  # so a new EXIT divergence cannot hide behind a recorded SKIP-ONLY.
  known="$(known_class_of "$name" || true)"
  if [ -n "$known" ]; then
    probe_wrapper "$name" "$H" "$ROOT" escalation
  else
    probe_wrapper "$name" "$H" "$ROOT" first
  fi
  TOTAL_PROBES=$((TOTAL_PROBES + PROBE_COUNT))

  if [ "$PROBE_DIVERGED" -eq 1 ]; then
    SEEN_VIOLATORS="$SEEN_VIOLATORS$name
"
    if [ -z "$known" ]; then
      fail "$name: RESIDUE-INVARIANCE VIOLATION ($PROBE_CLASS). Baseline verdict $PROBE_BASE on the derived consumer tree; with hub-only residue [$PROBE_SUBSET] present the verdict becomes $PROBE_RESULT."
      echo "      A consumer bootstrapped before that path was excluded still carries it (gaycruisebingo carries ~24 such paths), so this wrapper's answer depends on bootstrap accident, not on what the manifest delivered." >&2
      echo "      FIX THE WRAPPER, do not add it to KNOWN_RESIDUE_VIOLATIONS: move the scripts/sync-to-downstream.sh marker test ABOVE any test of the wrapper's own hub-only artifacts, so the consumer-SKIP decision reads only the marker." >&2
    elif [ "$known" != "$PROBE_CLASS" ]; then
      fail "$name: known residue violation changed class ($known → $PROBE_CLASS; baseline $PROBE_BASE, worst residue [$PROBE_SUBSET] → $PROBE_RESULT, first divergent residue [$PROBE_FIRST_SUBSET] → $PROBE_FIRST_RESULT). Re-verify and update KNOWN_RESIDUE_VIOLATIONS."
      if [ "$PROBE_CLASS" = "EXIT" ] && [ "$known" = "SKIP-ONLY" ]; then
        echo "      This is an ESCALATION, not a bookkeeping nit: the wrapper used to merely lose its consumer-SKIP line under residue, and now some subset makes it EXIT non-zero — that REDS a real consumer's repo-lint. Fix it marker-first rather than re-recording the class." >&2
      fi
    else
      note "$name: known residue violation ($PROBE_CLASS) — baseline $PROBE_BASE, residue [$PROBE_SUBSET] → $PROBE_RESULT over $PROBE_COUNT subset(s). Grandfathered; needs its own marker-first fix."
      if [ "$PROBE_FIRST_CLASS" != "$PROBE_CLASS" ]; then
        note "$name: the smallest divergent subset [$PROBE_FIRST_SUBSET] → $PROBE_FIRST_RESULT is $PROBE_FIRST_CLASS; the recorded $PROBE_CLASS class comes from a larger subset."
      fi
      pass "$name: residue behaviour matches its recorded KNOWN_RESIDUE_VIOLATIONS entry (worst class over $PROBE_COUNT probed subset(s))"
    fi
  else
    if [ -n "$known" ]; then
      fail "$name: STALE KNOWN_RESIDUE_VIOLATIONS entry — the wrapper is residue-invariant now (baseline $PROBE_BASE over $PROBE_COUNT subset(s)). Delete its entry so the ratchet cannot outlive the bug."
    else
      pass "$name: residue-invariant (baseline $PROBE_BASE held across $PROBE_COUNT residue subset(s))"
    fi
  fi
done <<EOF
$(find "$ROOT/scripts/ci" -maxdepth 1 -type f -name 'check_*' | LC_ALL=C sort)
EOF

if [ "$ENTANGLED" -eq 0 ]; then
  fail "zero hub-entangled wrappers found — the H(W) derivation is broken (it should find ~25)"
fi

# ---------------------------------------------------------------------------
# Engine self-tests (non-vacuity, permanent).
# ---------------------------------------------------------------------------
#
# Every planted wrapper below is COMMITTED to the fixture, not merely staged:
# fixture_reset restores HEAD before each probe, so a staged-only wrapper
# would be deleted out from under its own lattice.
SELF_H="scripts/audit-branch-protection.sh
tests/test_audit_branch_protection.sh
tests/test_audit_branch_protection_workflow.sh
.github/workflows/branch-protection-audit.yml"

# The first two, for the cheap self-tests that only need a 3-subset lattice.
SELF_H2="scripts/audit-branch-protection.sh
tests/test_audit_branch_protection.sh"

# Stage real-content artifacts for the hub-only refs above. The defective
# wrapper never executes them on the diverging subset (it errors in its
# required-file loop first), but they are real files with real modes, not
# exit-0 stubs.
while IFS= read -r r; do
  [ -z "$r" ] && continue
  mkdir -p "$STAGE/$(dirname "$r")"
  case "$r" in
    *.yml) printf 'name: residue-selftest\non: workflow_dispatch\njobs:\n  noop:\n    runs-on: ubuntu-latest\n    steps:\n      - run: "true"\n' > "$STAGE/$r" ;;
    *)     printf '#!/usr/bin/env bash\nset -euo pipefail\necho "residue selftest artifact: %s"\n' "$r" > "$STAGE/$r"
           chmod +x "$STAGE/$r" ;;
  esac
done <<EOF
$SELF_H
EOF

# The #796 round-2 wrapper, frozen verbatim as a fixture. Proves the engine
# reports a violation for the exact defect that motivated this net, and keeps
# proving it after #796 is repaired and merged. Staged under a distinct
# name so it is never confused with a live check.
FIXTURE_DIR="$ROOT/tests/fixtures/consumer-residue"
FIXTURE_CHECK="$FIXTURE_DIR/defective_check_branch_protection_audit"
if [ ! -f "$FIXTURE_CHECK" ]; then
  fail "missing regression fixture $FIXTURE_CHECK — the engine's non-vacuity proof is gone"
else
  SELF_NAME="check_residue_selftest_defective"

  cp "$FIXTURE_CHECK" "$FIX/scripts/ci/$SELF_NAME"
  # The fixture is a verbatim copy of scripts/ci/check_branch_protection_audit
  # and self-identifies by that name; rename its echo prefix so the SKIP-line
  # detection keys off the staged name.
  ORIG_NAME="check_branch_protection_audit"
  if command -v perl >/dev/null 2>&1; then
    perl -pi -e "s/\Q$ORIG_NAME\E/$SELF_NAME/g" "$FIX/scripts/ci/$SELF_NAME"
  else
    sed -i.bak "s/$ORIG_NAME/$SELF_NAME/g" "$FIX/scripts/ci/$SELF_NAME"
    rm -f "$FIX/scripts/ci/$SELF_NAME.bak"
  fi
  chmod +x "$FIX/scripts/ci/$SELF_NAME"
  fixture_commit "stage the #796 regression fixture"

  probe_wrapper "$SELF_NAME" "$SELF_H" "$STAGE"
  if [ "$PROBE_DIVERGED" -eq 1 ] && [ "$PROBE_CLASS" = "EXIT" ]; then
    pass "engine self-test: the frozen #796 round-2 wrapper is flagged (baseline $PROBE_BASE, residue [$PROBE_SUBSET] → $PROBE_RESULT)"
  else
    fail "engine self-test: the frozen #796 round-2 wrapper was NOT flagged (diverged=$PROBE_DIVERGED class='$PROBE_CLASS' baseline=$PROBE_BASE) — the engine has gone vacuous"
  fi

  # Positive control: the same fixture with a marker-FIRST guard must be
  # residue-invariant, so the engine is not simply flagging everything.
  SELF_OK="check_residue_selftest_markerfirst"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'set -euo pipefail\n'
    printf 'REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"\n'
    printf 'if [ ! -f "$REPO_ROOT/scripts/sync-to-downstream.sh" ]; then\n'
    printf '  echo "%s: SKIP (consumer checkout: hub marker absent)"\n' "$SELF_OK"
    printf '  exit 0\n'
    printf 'fi\n'
    printf 'for f in scripts/audit-branch-protection.sh tests/test_audit_branch_protection.sh; do\n'
    printf '  [ -f "$REPO_ROOT/$f" ] || { echo "%s: ERROR missing $f" >&2; exit 1; }\n' "$SELF_OK"
    printf 'done\n'
    printf 'echo "%s: PASS"\n' "$SELF_OK"
  } > "$FIX/scripts/ci/$SELF_OK"
  chmod +x "$FIX/scripts/ci/$SELF_OK"
  fixture_commit "stage the marker-first control"

  probe_wrapper "$SELF_OK" "$SELF_H" "$STAGE"
  if [ "$PROBE_DIVERGED" -eq 0 ]; then
    pass "engine self-test: a marker-first guard over the same refs is residue-invariant ($PROBE_COUNT subset(s), baseline $PROBE_BASE)"
  else
    fail "engine self-test: a marker-first guard was WRONGLY flagged ($PROBE_CLASS, baseline $PROBE_BASE, residue [$PROBE_SUBSET] → $PROBE_RESULT) — false positive in the engine"
  fi

  rm -f "$FIX/scripts/ci/$SELF_NAME" "$FIX/scripts/ci/$SELF_OK"
  fixture_commit "drop the #796 fixture and its control"
fi

# ---------------------------------------------------------------------------
# Engine self-test: PROBE INDEPENDENCE (non-vacuity for fixture_reset).
# ---------------------------------------------------------------------------
#
# A wrapper that writes must not be able to make one probe depend on the
# previous one. The planted wrapper below leaves one leftover per cleanup
# mechanism — a tracked-file edit (needs `reset --hard`), an untracked file
# (needs `clean -fd`) and a gitignored file (needs `clean -x`) — and refuses
# to run if it finds any of them already there. It is residue-INVARIANT by
# construction: it never looks at a single hub-only path, so its verdict can
# only change if the harness let a leftover through.
#
# Drop any one of the three flags from fixture_reset (or the reset itself) and
# this reports a divergence the residue never caused, which is precisely the
# manufactured-verdict failure mode.
SELF_SIDE="check_residue_selftest_sideeffect"
{
  printf '#!/usr/bin/env bash\n'
  printf 'set -euo pipefail\n'
  printf 'REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"\n'
  printf 'MARK="residue-selftest-side-effect-was-here"\n'
  printf 'if grep -q "$MARK" "$REPO_ROOT/scripts/ci/README.md" 2>/dev/null; then\n'
  printf '  echo "%s: leftover TRACKED edit from a previous probe" >&2\n' "$SELF_SIDE"
  printf '  exit 1\n'
  printf 'fi\n'
  printf 'if [ -e "$REPO_ROOT/scripts/residue_selftest_untracked" ]; then\n'
  printf '  echo "%s: leftover UNTRACKED file from a previous probe" >&2\n' "$SELF_SIDE"
  printf '  exit 1\n'
  printf 'fi\n'
  printf 'if [ -e "$REPO_ROOT/tmp/residue_selftest_ignored" ]; then\n'
  printf '  echo "%s: leftover GITIGNORED file from a previous probe" >&2\n' "$SELF_SIDE"
  printf '  exit 1\n'
  printf 'fi\n'
  printf 'echo "$MARK" >> "$REPO_ROOT/scripts/ci/README.md"\n'
  printf ': > "$REPO_ROOT/scripts/residue_selftest_untracked"\n'
  printf 'mkdir -p "$REPO_ROOT/tmp"\n'
  printf ': > "$REPO_ROOT/tmp/residue_selftest_ignored"\n'
  printf 'echo "%s: SKIP (consumer checkout: hub marker absent)"\n' "$SELF_SIDE"
  printf 'exit 0\n'
} > "$FIX/scripts/ci/$SELF_SIDE"
chmod +x "$FIX/scripts/ci/$SELF_SIDE"
fixture_commit "stage the probe-independence self-test"

probe_wrapper "$SELF_SIDE" "$SELF_H2" "$STAGE"
if [ "$PROBE_DIVERGED" -eq 0 ]; then
  pass "engine self-test: probes are independent — a wrapper that writes a tracked edit, an untracked file and a gitignored file every run stayed invariant across $PROBE_COUNT subset(s) (baseline $PROBE_BASE)"
else
  fail "engine self-test: PROBE INDEPENDENCE BROKEN — a side-effecting wrapper diverged ($PROBE_CLASS, baseline $PROBE_BASE, residue [$PROBE_SUBSET] → $PROBE_RESULT) even though it never reads a hub-only path. fixture_reset is not restoring the committed baseline between probes, so every verdict in this run depends on enumeration order."
fi
rm -f "$FIX/scripts/ci/$SELF_SIDE"
fixture_commit "drop the probe-independence self-test"

# ---------------------------------------------------------------------------
# Engine self-test: CLASS ESCALATION (non-vacuity for escalation mode).
# ---------------------------------------------------------------------------
#
# The ratchet compares a grandfathered wrapper's recorded class against the
# WORST class in its lattice. The planted wrapper below has one divergence of
# each class, arranged so the LESSER one is reached first: with only
# scripts/audit-branch-protection.sh present it loses its SKIP line (0|RUN,
# SKIP-ONLY), and with tests/test_audit_branch_protection.sh present it exits
# 1 (EXIT). Ascending-popcount enumeration hits the SKIP-ONLY subset first, so
# this is exactly the shape that used to let a new EXIT regression hide behind
# a recorded SKIP-ONLY entry.
#
# Both modes are asserted: escalation mode must report EXIT, and `first` mode
# must still report SKIP-ONLY — which is both the control for the escalation
# claim and the proof that the old behaviour was the hiding one.
SELF_ESC="check_residue_selftest_escalating"
{
  printf '#!/usr/bin/env bash\n'
  printf 'set -euo pipefail\n'
  printf 'REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"\n'
  printf 'if [ -f "$REPO_ROOT/tests/test_audit_branch_protection.sh" ]; then\n'
  printf '  echo "%s: ERROR hub-only suite present on a consumer" >&2\n' "$SELF_ESC"
  printf '  exit 1\n'
  printf 'fi\n'
  printf 'if [ -f "$REPO_ROOT/scripts/audit-branch-protection.sh" ]; then\n'
  printf '  echo "%s: proceeding against hub tooling (no SKIP line)"\n' "$SELF_ESC"
  printf '  exit 0\n'
  printf 'fi\n'
  printf 'echo "%s: SKIP (consumer checkout: hub marker absent)"\n' "$SELF_ESC"
  printf 'exit 0\n'
} > "$FIX/scripts/ci/$SELF_ESC"
chmod +x "$FIX/scripts/ci/$SELF_ESC"
fixture_commit "stage the class-escalation self-test"

probe_wrapper "$SELF_ESC" "$SELF_H2" "$STAGE" escalation
if [ "$PROBE_DIVERGED" -eq 1 ] && [ "$PROBE_CLASS" = "EXIT" ] && [ "$PROBE_FIRST_CLASS" = "SKIP-ONLY" ]; then
  pass "engine self-test (escalation): a lattice whose first divergence is SKIP-ONLY [$PROBE_FIRST_SUBSET] and whose later subset EXITs [$PROBE_SUBSET] is recorded as EXIT"
else
  fail "engine self-test (escalation): expected first=SKIP-ONLY worst=EXIT, got first='$PROBE_FIRST_CLASS' worst='$PROBE_CLASS' (diverged=$PROBE_DIVERGED, baseline $PROBE_BASE) — escalation probing has gone vacuous and a new EXIT regression can hide behind a recorded SKIP-ONLY entry"
fi

probe_wrapper "$SELF_ESC" "$SELF_H2" "$STAGE" first
if [ "$PROBE_DIVERGED" -eq 1 ] && [ "$PROBE_CLASS" = "SKIP-ONLY" ]; then
  pass "engine self-test (escalation control): the same lattice under first-divergence probing reports only SKIP-ONLY — the class the escalation mode exists to correct"
else
  fail "engine self-test (escalation control): expected SKIP-ONLY under first-divergence probing, got '$PROBE_CLASS' (diverged=$PROBE_DIVERGED) — the two modes are no longer distinguishable, so the escalation assertion above proves nothing"
fi
rm -f "$FIX/scripts/ci/$SELF_ESC"
fixture_commit "drop the class-escalation self-test"

# ---------------------------------------------------------------------------
# Detector self-tests (non-vacuity for S1 and S2, permanent).
# ---------------------------------------------------------------------------
#
# The lattice has the frozen #796 fixture to prove it is not vacuous. The
# two structural assertions need the same treatment, and they can have it
# far more cheaply: both are pure functions of a wrapper's text, so a
# planted wrapper is a heredoc rather than a probe.
DET="$WORKDIR/detectors"
mkdir -p "$DET"

DET_P="$(first_nonempty_line "$HUB_ONLY_PATHS")"
if [ -z "$DET_P" ]; then
  fail "detector self-test: HUB_ONLY_PATHS is empty — cannot plant a hub-only reference"
else
  DET_DIR="${DET_P%/*}"
  DET_BN="${DET_P##*/}"
  DET_HEAD="${DET_BN%"${DET_BN#?}"}"   # first character
  DET_TAIL="${DET_BN#?}"               # the rest

  # (S1) A wrapper whose consumer gate reads a hub-only path assembled at
  # runtime: the gate is unmistakable, the dependency is invisible. That
  # pair — gate declared, H empty — is exactly what S1 fails on, and it is
  # what a wider extractor can never fix.
  {
    printf '#!/usr/bin/env bash\n'
    printf 'REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"\n'
    # Deliberately concatenated so the literal "/<basename>" never appears.
    printf 'TARGET="$REPO_ROOT/%s/%s""%s"\n' "$DET_DIR" "$DET_HEAD" "$DET_TAIL"
    printf 'if [ ! -f "$TARGET" ] && [ ! -f "$REPO_ROOT/%s" ]; then\n' "$HUB_MARKER"
    printf '  echo "check_detector_selftest_composed: SKIP (consumer checkout: hub-only tooling absent)"\n'
    printf '  exit 0\n'
    printf 'fi\n'
  } > "$DET/check_detector_selftest_composed"

  # Negative control: the same gate naming the same file literally.
  {
    printf '#!/usr/bin/env bash\n'
    printf 'REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"\n'
    printf 'TARGET="$REPO_ROOT/%s"\n' "$DET_P"
    printf 'if [ ! -f "$TARGET" ] && [ ! -f "$REPO_ROOT/%s" ]; then\n' "$HUB_MARKER"
    printf '  echo "check_detector_selftest_literal: SKIP (consumer checkout: hub-only tooling absent)"\n'
    printf '  exit 0\n'
    printf 'fi\n'
  } > "$DET/check_detector_selftest_literal"

  det_composed_H="$(hub_only_refs "$DET/check_detector_selftest_composed" "scripts/ci/check_detector_selftest_composed")"
  det_literal_H="$(hub_only_refs "$DET/check_detector_selftest_literal" "scripts/ci/check_detector_selftest_literal")"

  if declares_consumer_gate "$DET/check_detector_selftest_composed" && [ -z "$det_composed_H" ]; then
    pass "detector self-test (S1): a gate on a runtime-composed hub-only path is seen as a consumer gate with an EMPTY H — the condition S1 fails on"
  else
    fail "detector self-test (S1): the composed-path wrapper was not caught (gate=$(declares_consumer_gate "$DET/check_detector_selftest_composed" && echo yes || echo no), H='$det_composed_H') — S1 has gone vacuous"
  fi

  if [ "$det_literal_H" = "$DET_P" ]; then
    pass "detector self-test (S1 control): the same gate written literally enrols '$DET_P' in the lattice"
  else
    fail "detector self-test (S1 control): expected H='$DET_P', got '$det_literal_H' — hub_only_refs is not reading literal paths"
  fi

  # (S2) Both SKIP spellings, same wrapper shape.
  {
    printf '#!/usr/bin/env bash\n'
    printf 'echo "check_detector_selftest_skipfmt: SKIP (consumer checkout: hub marker absent)"\n'
  } > "$DET/check_detector_selftest_skipfmt_ok"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'echo "SKIP: check_detector_selftest_skipfmt (consumer checkout: hub marker absent)"\n'
  } > "$DET/check_detector_selftest_skipfmt_bad"

  det_ok="$(noncanonical_skip_lines "$DET/check_detector_selftest_skipfmt_ok" check_detector_selftest_skipfmt)"
  det_bad="$(noncanonical_skip_lines "$DET/check_detector_selftest_skipfmt_bad" check_detector_selftest_skipfmt)"
  if [ -z "$det_ok" ] && [ -n "$det_bad" ]; then
    pass "detector self-test (S2): the canonical SKIP spelling passes and the reversed one is reported"
  else
    fail "detector self-test (S2): canonical='$det_ok' (want empty), reversed='$det_bad' (want non-empty) — S2 has gone vacuous"
  fi
fi

# ---------------------------------------------------------------------------
# Helper self-tests (non-vacuity for the two readers, permanent).
# ---------------------------------------------------------------------------

# first_nonempty_line at a scale the pipeline form cannot survive. 3,000
# entries is ~167 KB, well past any pipe buffer, so the assertion is not a
# tautology: swap the body back to `printf | sed | head -1` and the
# assignment returns 141 and `set -e` kills the suite here.
hdr_big=""
hdr_i=0
while [ "$hdr_i" -lt 3000 ]; do
  hdr_big="$hdr_big/a/deliberately/long/hub-only/path/entry-$hdr_i/file.sh
"
  hdr_i=$((hdr_i + 1))
done
hdr_first="$(first_nonempty_line "$hdr_big")"
hdr_skip="$(first_nonempty_line "

scripts/second-line.sh
scripts/third-line.sh")"
if [ "$hdr_first" = "/a/deliberately/long/hub-only/path/entry-0/file.sh" ] && [ "$hdr_skip" = "scripts/second-line.sh" ]; then
  pass "helper self-test: first_nonempty_line reads a ${#hdr_big}-byte list without a SIGPIPE abort and skips leading blank lines"
else
  fail "helper self-test: first_nonempty_line returned '$hdr_first' for a ${#hdr_big}-byte list (want the entry-0 path) and '$hdr_skip' with leading blanks (want scripts/second-line.sh)"
fi

# copy_tracked_tree / missing_tracked_paths against a throwaway repo, because
# the real hub tree is clean and would make both assertions vacuous. This is
# the whole reason the fixture is seeded from the index: a working-tree copy
# carries the untracked file into the "consumer" and no lattice can toggle it.
TRACKED_SELFTEST="$WORKDIR/tracked-selftest"
mkdir -p "$TRACKED_SELFTEST/src/scripts" "$TRACKED_SELFTEST/dst"
printf 'tracked\n' > "$TRACKED_SELFTEST/src/scripts/tracked.sh"
printf 'doomed\n'  > "$TRACKED_SELFTEST/src/scripts/deleted.sh"
git -C "$TRACKED_SELFTEST/src" init -q
git -C "$TRACKED_SELFTEST/src" add -A
git -C "$TRACKED_SELFTEST/src" \
  -c user.name="tracked-selftest" \
  -c user.email="tracked-selftest@example.invalid" \
  -c commit.gpgsign=false \
  commit -qm "seed"
printf 'untracked\n' > "$TRACKED_SELFTEST/src/scripts/untracked.sh"

tracked_list_z "$TRACKED_SELFTEST/src" "$TRACKED_SELFTEST/list.z"
copy_tracked_tree "$TRACKED_SELFTEST/src" "$TRACKED_SELFTEST/dst" "$TRACKED_SELFTEST/list.z"
if [ -f "$TRACKED_SELFTEST/dst/scripts/tracked.sh" ] && [ ! -e "$TRACKED_SELFTEST/dst/scripts/untracked.sh" ]; then
  pass "helper self-test: copy_tracked_tree copies the index and leaves an untracked file behind"
else
  fail "helper self-test: copy_tracked_tree copied the working tree, not the index (tracked.sh present=$([ -f "$TRACKED_SELFTEST/dst/scripts/tracked.sh" ] && echo yes || echo no), untracked.sh present=$([ -e "$TRACKED_SELFTEST/dst/scripts/untracked.sh" ] && echo yes || echo no)) — an untracked hub-only artifact would reach the consumer fixture as a path no lattice can toggle"
fi

if [ -n "$(missing_tracked_paths "$TRACKED_SELFTEST/src" "$TRACKED_SELFTEST/list.z")" ]; then
  fail "helper self-test (control): missing_tracked_paths reported a clean tree as dirty — it would refuse to run on every clean checkout"
else
  pass "helper self-test (control): missing_tracked_paths reports nothing for a clean tree"
fi
rm -f "$TRACKED_SELFTEST/src/scripts/deleted.sh"
tracked_missing="$(missing_tracked_paths "$TRACKED_SELFTEST/src" "$TRACKED_SELFTEST/list.z")"
if [ "$tracked_missing" = "scripts/deleted.sh" ]; then
  pass "helper self-test: missing_tracked_paths names a tracked-but-deleted path, so a stale index entry fails up front instead of aborting a probe mid-lattice"
else
  fail "helper self-test: missing_tracked_paths returned '$tracked_missing', want 'scripts/deleted.sh' — a tracked-but-deleted path would enter H and abort the residue copy"
fi

# ---------------------------------------------------------------------------
# Stale-ratchet sweep: every recorded entry must have been observed.
# ---------------------------------------------------------------------------
#
# seen_contains <newline-delimited list> <name> — whole-line membership,
# in-process for the same reason run_probe's verdict test is (a
# `printf | grep -qx` under pipefail can report 141 instead of 0).
seen_contains() {
  case "
$1" in
    *"
$2
"*) return 0 ;;
  esac
  return 1
}

for e in "${KNOWN_RESIDUE_VIOLATIONS[@]}"; do
  n="${e%%|*}"
  if ! seen_contains "$SEEN_VIOLATORS" "$n"; then
    if [ -f "$ROOT/scripts/ci/$n" ]; then
      fail "KNOWN_RESIDUE_VIOLATIONS names '$n' but no violation was observed for it — delete the stale entry"
    else
      fail "KNOWN_RESIDUE_VIOLATIONS names '$n' but scripts/ci/$n no longer exists — delete the stale entry"
    fi
  fi
done

# Same ratchet for the (S1) exoneration list: an entry that was not
# observed as "declares a consumer gate AND H is empty" is stale.
for n in "${MARKER_ONLY_CONSUMER_GATES[@]}"; do
  if ! seen_contains "$SEEN_MARKER_ONLY" "$n"; then
    if [ -f "$ROOT/scripts/ci/$n" ]; then
      fail "MARKER_ONLY_CONSUMER_GATES names '$n' but it no longer declares a consumer gate — delete the stale entry"
    else
      fail "MARKER_ONLY_CONSUMER_GATES names '$n' but scripts/ci/$n no longer exists — delete the stale entry"
    fi
  fi
done

echo ""
echo "test_consumer_residue_safety: $GATED wrapper(s) declare a consumer gate, $ENTANGLED hub-entangled wrapper(s), $TOTAL_PROBES residue probe(s)"
echo "test_consumer_residue_safety: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
