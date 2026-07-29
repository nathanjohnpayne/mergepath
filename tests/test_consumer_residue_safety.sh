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
# "<name>: SKIP (...)" line was emitted).
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
# Build the DERIVED consumer baseline once.
# ---------------------------------------------------------------------------
WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/consumer-residue-safety.XXXXXX")"
trap 'rm -rf "$WORKDIR"' EXIT
FIX="$WORKDIR/consumer"
STAGE="$WORKDIR/stage"
mkdir -p "$FIX" "$STAGE"

# NB: exclude '.git' WITHOUT a trailing slash. In a linked git WORKTREE
# checkout .git is a FILE (a gitdir pointer into the main repo), not a
# directory — '.git/' would not match it, the pointer would be copied into
# the fixture, and every fixture git command would then operate on the REAL
# repo. (This bit the #601 suite once: a fixture `git commit` landed on the
# real branch.)
rsync -a \
  --exclude='.git' \
  --exclude='node_modules/' \
  --exclude='.DS_Store' \
  "$ROOT/" "$FIX/"
rm -rf "$FIX/.git"

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
while IFS= read -r rel; do
  case "$rel" in
    scripts/*|tests/*|.github/workflows/*) ;;
    *) continue ;;
  esac
  if ! is_covered "$rel"; then
    rm -f "$FIX/$rel"
    HUB_ONLY_PATHS="$HUB_ONLY_PATHS$rel
"
    STRIPPED=$((STRIPPED + 1))
  fi
done <<EOF
$(cd "$ROOT" && git ls-files)
EOF
rm -f "$FIX/.mergepath-sync.yml"

# Prune the directory skeleton the strip emptied. rsync copies the hub
# tree wholesale and the strip loop only removes FILES, so without this
# the "consumer" baseline still carries every hub-only DIRECTORY as an
# empty dir and a wrapper gating on
# `[ -d "$REPO_ROOT/scripts/sweep-unresolved-feedback" ]` would see the
# hub layout. (Constant across the lattice, so it could never produce a
# false FAIL — but the baseline should be consumer-accurate for -d tests
# too, and residue_apply/residue_off keep it that way per-probe.)
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
git -C "$FIX" add -A
git -C "$FIX" \
  -c user.name="consumer-fixture" \
  -c user.email="consumer-fixture@example.invalid" \
  -c commit.gpgsign=false \
  commit -qm "derived consumer baseline"

# Mirror the workflow's make_ci_scripts_executable step.
chmod +x "$FIX"/scripts/ci/* 2>/dev/null || true

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

# prune_empty_parents <dir rel path> — after removing a residue file, drop
# the directories it left empty, so "residue absent" means the same thing
# for a `[ -d ... ]` test as it does for a `[ -f ... ]` one. Bounded to
# $FIX and stops at the first non-empty parent (rmdir refuses those).
prune_empty_parents() {
  local d="$1"
  while [ -n "$d" ] && [ "$d" != "." ] && [ "$d" != "/" ]; do
    rmdir "$FIX/$d" 2>/dev/null || break
    case "$d" in
      */*) d="${d%/*}" ;;
      *)   break ;;
    esac
  done
}

# residue_off <H> — remove every H path from the sandbox and restage.
residue_off() {
  local r changed=0
  while IFS= read -r r; do
    [ -z "$r" ] && continue
    if [ -e "$FIX/$r" ]; then
      rm -f "$FIX/$r"
      prune_empty_parents "${r%/*}"
      changed=1
    fi
  done <<EOF
$1
EOF
  if [ "$changed" -eq 1 ]; then
    git -C "$FIX" add -A >/dev/null 2>&1 || true
  fi
}

# residue_apply <H> <mask> <src> — materialise exactly the masked subset.
# Sets RESIDUE_SUBSET to the applied subset (space separated).
#
# Hot path: this runs once per probe over every element of H, so it uses
# ${r%/*} rather than $(dirname) — the subshell per element dominated an
# early profile (17k subshells on the |H|=32 wrapper alone).
RESIDUE_SUBSET=""
residue_apply() {
  local H="$1" mask="$2" src="$3" i=0 r sub="" d changed=0
  while IFS= read -r r; do
    [ -z "$r" ] && continue
    if [ $(( (mask >> i) & 1 )) -eq 1 ]; then
      if [ ! -e "$FIX/$r" ]; then
        d="${r%/*}"
        [ -d "$FIX/$d" ] || mkdir -p "$FIX/$d"
        cp -p "$src/$r" "$FIX/$r"
        changed=1
      fi
      sub="$sub $r"
    elif [ -e "$FIX/$r" ]; then
      rm -f "$FIX/$r"
      prune_empty_parents "${r%/*}"
      changed=1
    fi
    i=$((i + 1))
  done <<EOF
$H
EOF
  if [ "$changed" -eq 1 ]; then
    git -C "$FIX" add -A >/dev/null 2>&1 || true
  fi
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

# Results of the last probe_wrapper call.
PROBE_BASE=""
PROBE_DIVERGED=0
PROBE_CLASS=""
PROBE_SUBSET=""
PROBE_RESULT=""
PROBE_COUNT=0

# probe_wrapper <check-name> <H newline-list> <src dir>
#
# Enumerates the residue lattice in ascending-popcount order (so the
# smallest, most diagnostic subset is the one reported) and stops at the
# first divergence. Exhaustive power set when 2^|H| <= 256; otherwise all
# singletons, then all pairs, then the full set.
probe_wrapper() {
  local name="$1" H="$2" src="$3"
  local n total mask k sub res
  n=$(printf '%s\n' "$H" | grep -c . || true)

  PROBE_DIVERGED=0
  PROBE_CLASS=""
  PROBE_SUBSET=""
  PROBE_RESULT=""
  PROBE_COUNT=0

  residue_off "$H"
  PROBE_BASE="$(run_probe "$name")"

  if [ "$n" -le 8 ]; then
    total=$(( (1 << n) - 1 ))
    for k in $(seq 1 "$n"); do
      for mask in $(seq 1 "$total"); do
        popcount "$mask"
        [ "$POPCOUNT" = "$k" ] || continue
        residue_apply "$H" "$mask" "$src"; sub="$RESIDUE_SUBSET"
        PROBE_COUNT=$((PROBE_COUNT + 1))
        res="$(run_probe "$name")"
        if [ "$res" != "$PROBE_BASE" ]; then
          PROBE_DIVERGED=1
          PROBE_SUBSET="$sub"
          PROBE_RESULT="$res"
          PROBE_CLASS="$(classify "$PROBE_BASE" "$res")"
          residue_off "$H"
          return 0
        fi
      done
    done
  else
    # Above the exhaustive cap: singletons, then pairs, then the full set.
    # A 3-file interaction above the cap would slip; recorded as a known
    # residual gap in the header of scripts/ci/check_consumer_residue_safety.
    local i j
    for i in $(seq 0 $((n - 1))); do
      mask=$(( 1 << i ))
      residue_apply "$H" "$mask" "$src"; sub="$RESIDUE_SUBSET"
      PROBE_COUNT=$((PROBE_COUNT + 1))
      res="$(run_probe "$name")"
      if [ "$res" != "$PROBE_BASE" ]; then
        PROBE_DIVERGED=1; PROBE_SUBSET="$sub"; PROBE_RESULT="$res"
        PROBE_CLASS="$(classify "$PROBE_BASE" "$res")"
        residue_off "$H"; return 0
      fi
    done
    for i in $(seq 0 $((n - 2))); do
      for j in $(seq $((i + 1)) $((n - 1))); do
        mask=$(( (1 << i) | (1 << j) ))
        residue_apply "$H" "$mask" "$src"; sub="$RESIDUE_SUBSET"
        PROBE_COUNT=$((PROBE_COUNT + 1))
        res="$(run_probe "$name")"
        if [ "$res" != "$PROBE_BASE" ]; then
          PROBE_DIVERGED=1; PROBE_SUBSET="$sub"; PROBE_RESULT="$res"
          PROBE_CLASS="$(classify "$PROBE_BASE" "$res")"
          residue_off "$H"; return 0
        fi
      done
    done
    mask=$(( (1 << n) - 1 ))
    residue_apply "$H" "$mask" "$src"; sub="$RESIDUE_SUBSET"
    PROBE_COUNT=$((PROBE_COUNT + 1))
    res="$(run_probe "$name")"
    if [ "$res" != "$PROBE_BASE" ]; then
      PROBE_DIVERGED=1; PROBE_SUBSET="$sub"; PROBE_RESULT="$res"
      PROBE_CLASS="$(classify "$PROBE_BASE" "$res")"
    fi
  fi

  residue_off "$H"
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

  probe_wrapper "$name" "$H" "$ROOT"
  TOTAL_PROBES=$((TOTAL_PROBES + PROBE_COUNT))
  known="$(known_class_of "$name" || true)"

  if [ "$PROBE_DIVERGED" -eq 1 ]; then
    SEEN_VIOLATORS="$SEEN_VIOLATORS$name
"
    if [ -z "$known" ]; then
      fail "$name: RESIDUE-INVARIANCE VIOLATION ($PROBE_CLASS). Baseline verdict $PROBE_BASE on the derived consumer tree; with hub-only residue [$PROBE_SUBSET] present the verdict becomes $PROBE_RESULT."
      echo "      A consumer bootstrapped before that path was excluded still carries it (gaycruisebingo carries ~24 such paths), so this wrapper's answer depends on bootstrap accident, not on what the manifest delivered." >&2
      echo "      FIX THE WRAPPER, do not add it to KNOWN_RESIDUE_VIOLATIONS: move the scripts/sync-to-downstream.sh marker test ABOVE any test of the wrapper's own hub-only artifacts, so the consumer-SKIP decision reads only the marker." >&2
    elif [ "$known" != "$PROBE_CLASS" ]; then
      fail "$name: known residue violation changed class ($known → $PROBE_CLASS; baseline $PROBE_BASE, residue [$PROBE_SUBSET] → $PROBE_RESULT). Re-verify and update KNOWN_RESIDUE_VIOLATIONS."
    else
      note "$name: known residue violation ($PROBE_CLASS) — baseline $PROBE_BASE, residue [$PROBE_SUBSET] → $PROBE_RESULT. Grandfathered; needs its own marker-first fix."
      pass "$name: residue behaviour matches its recorded KNOWN_RESIDUE_VIOLATIONS entry"
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
# Engine self-test (non-vacuity, permanent).
# ---------------------------------------------------------------------------
#
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
  SELF_H="scripts/audit-branch-protection.sh
tests/test_audit_branch_protection.sh
tests/test_audit_branch_protection_workflow.sh
.github/workflows/branch-protection-audit.yml"

  # Stage real-content artifacts for the fixture's four hub-only refs. The
  # defective wrapper never executes them on the diverging subset (it errors
  # in its required-file loop first), but they are real files with real
  # modes, not exit-0 stubs.
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
  git -C "$FIX" add -A >/dev/null 2>&1 || true

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
  git -C "$FIX" add -A >/dev/null 2>&1 || true

  probe_wrapper "$SELF_OK" "$SELF_H" "$STAGE"
  if [ "$PROBE_DIVERGED" -eq 0 ]; then
    pass "engine self-test: a marker-first guard over the same refs is residue-invariant ($PROBE_COUNT subset(s), baseline $PROBE_BASE)"
  else
    fail "engine self-test: a marker-first guard was WRONGLY flagged ($PROBE_CLASS, baseline $PROBE_BASE, residue [$PROBE_SUBSET] → $PROBE_RESULT) — false positive in the engine"
  fi

  rm -f "$FIX/scripts/ci/$SELF_NAME" "$FIX/scripts/ci/$SELF_OK"
  git -C "$FIX" add -A >/dev/null 2>&1 || true
fi

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

DET_P="$(printf '%s' "$HUB_ONLY_PATHS" | sed '/^$/d' | head -1)"
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
