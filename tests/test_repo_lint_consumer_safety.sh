#!/usr/bin/env bash
# tests/test_repo_lint_consumer_safety.sh — hub-only consumer-safety net
# for the #601 repo_lint.yml wiring-propagation contract.
#
# repo_lint.yml is manifest-canonical (consumers: all) as of #601, so
# EVERY `run: ./scripts/ci/check_*` step in it executes on every consumer
# on every push/PR after the first sync wave. This suite builds a
# consumer-shaped fixture tree — the current checkout minus everything a
# consumer does not have — and runs every check wired in repo_lint.yml
# against it, asserting each exits 0 (PASS or SKIP). A check that fails
# here would red every consumer's repo-lint on the first #601 wave.
#
# Consumer shape modeled (worst case, matching the live-consumer audit
# recorded in check_propagation_closure's ALLOW_LIST, 2026-06-24):
#   - the bootstrap template-mirror excludes are absent
#     (BOOTSTRAP_MIRROR_EXCLUDES in scripts/bootstrap/template-mirror.sh):
#     .mergepath-sync.yml, scripts/sync-to-downstream.sh, the
#     project-doc-sync surface, mergepath/, packaging/, dist/, ...
#   - the hub-only files named in check_propagation_closure's ALLOW_LIST
#     are absent: bootstrap seeders + their tests, the weekly sweep
#     pipeline, the 1Password headless-proof tooling, and the self-tests
#     of hub-only checks. Live consumers were bootstrapped from older
#     template snapshots and verifiably carry none of these.
#   - hub-only STALE RESIDUE is PRESENT (CONSUMER_RESIDUE_PRESENT below).
#     Adding a path to BOOTSTRAP_MIRROR_EXCLUDES stops FUTURE seeding; it
#     does not retroactively scrub the consumers already carrying the file.
#     A consumer bootstrapped before the exclusion therefore keeps it
#     forever, and any wrapper that infers "hub checkout" from that file's
#     presence misfires there. Modeling these as absent is what made #774
#     round 2 ship a wrapper that hard-failed gaycruisebingo (see below).
#   Everything manifest-propagated (canonical entries, kits, requires:)
#   stays present — that is exactly what a post-#601 sync guarantees.
#
# ⚠ This fixture is a HAND-WRITTEN MODEL of consumer state, not an
# observation of it. It is only as good as its last reconciliation against
# the fleet, and a wrong model produces confident green on a check that is
# live-broken. When adding a hub-only path here, VERIFY against live
# consumer state rather than against this file's existing assumptions:
#
#   for repo in matchline nathanpaynedotcom overridebroadway \
#               device-source-of-truth friends-and-family-billing \
#               device-platform-reporting swipewatch tadlockpsychiatry \
#               gaycruisebingo; do
#     gh api "repos/nathanjohnpayne/$repo/contents/<path>" --jq .sha \
#       >/dev/null 2>&1 && echo "$repo: PRESENT"
#   done
#
# A path that comes back PRESENT anywhere belongs in
# CONSUMER_RESIDUE_PRESENT, not in CONSUMER_ABSENT.
#
# Scope note: every wired check runs; there is currently no exclusion
# list. If a future check is irreducibly hub-entangled, prefer giving it
# the standard consumer SKIP guard (scripts/sync-to-downstream.sh marker
# — see check_sync_manifest) over excluding it here.
#
# Hub-only: this test is deliberately NOT in .mergepath-sync.yml (like
# tests/test_bootstrap*, it encodes hub-only surfaces — including the
# removal list above) and is not itself consumer-safe.
#
# Deterministic + offline: `gh` is PATH-shimmed to fail closed (wired
# checks must be hermetic — a check that reaches for live gh on a
# consumer runner would be flaky there too); the fixture is git-init'ed
# so git-based checks (git ls-files / rev-parse) see a plain consumer
# repo. yq + node + ruby + rsync are required (the repo-lint workflow
# provides all of them on every runner); missing tooling → SKIP.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../scripts/lib/repo-lint-check-selection.sh
source "$ROOT/scripts/lib/repo-lint-check-selection.sh"

for tool in yq node ruby rsync git python3 jq; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "SKIP: $tool not available" >&2
    exit 0
  fi
done

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/repo-lint-consumer-safety.XXXXXX")"
trap 'rm -rf "$WORKDIR"' EXIT

PASS=0
FAIL=0
pass() { echo "PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $*" >&2; FAIL=$((FAIL + 1)); }

# ---------------------------------------------------------------------------
# Build the consumer-shaped fixture tree.
# ---------------------------------------------------------------------------
FIX="$WORKDIR/consumer"
mkdir -p "$FIX"

# NB: exclude '.git' WITHOUT a trailing slash. In a linked git WORKTREE
# checkout, .git is a FILE (a gitdir pointer into the main repo), not a
# directory — '.git/' would not match it, the pointer would be copied
# into the fixture, and every fixture git command would then operate on
# the REAL repo (this bit once: a fixture `git commit` landed on the
# real branch).
rsync -a \
  --exclude='.git' \
  --exclude='node_modules/' \
  --exclude='.DS_Store' \
  "$ROOT/" "$FIX/"
rm -rf "$FIX/.git"

# Consumer-absent paths. Two sources of truth, kept in the header
# comment above:
#   (a) BOOTSTRAP_MIRROR_EXCLUDES (scripts/bootstrap/template-mirror.sh)
#   (b) check_propagation_closure's ALLOW_LIST (hub-only, never travels)
# Globs are intentional (expanded by the loop below).
CONSUMER_ABSENT=(
  # (a) template-mirror excludes — never even seeded at bootstrap.
  ".mergepath-sync.yml"
  "scripts/sync-to-downstream.sh"
  "tests/test_sync_to_downstream.sh"
  ".github/workflows/weekly-drift-audit.yml"
  ".mergepath-project-docs.yml"
  "docs/projects"
  "scripts/project-doc-sync.sh"
  "tests/test_project_doc_sync.sh"
  "mergepath"
  "packaging"
  "dist"
  "scripts/policy-sim.sh"
  "specs/mergepath_playground.md"
  "plans/mergepath-playground.md"
  "tests/test_mergepath_playground.sh"
  "specs/bootstrap_consumer_identity.md"
  "bugs/screenshots"
  ".github/screenshots"
  # #774 fleet branch-protection audit — the two paths NO consumer has.
  # Both postdate every bootstrap, so they left no residue anywhere
  # (verified against all nine consumers, 2026-07-28). The auditor and
  # its first suite DO survive on gaycruisebingo — they are modeled in
  # CONSUMER_RESIDUE_PRESENT below, NOT here.
  ".github/workflows/branch-protection-audit.yml"
  "tests/test_audit_branch_protection_workflow.sh"
  # (b) hub-only per check_propagation_closure ALLOW_LIST — absent from
  # live consumers (older bootstrap snapshots; never manifest-propagated).
  "scripts/bootstrap.sh"
  "scripts/bootstrap-new-repo.sh"
  "scripts/bootstrap-config.sh"
  "scripts/bootstrap"
  "tests/test_bootstrap"'*'
  "scripts/sweep-unresolved-feedback"
  "tests/test_sweep"'*'
  "tests/test_backfill_unresolved_feedback.sh"
  ".github/workflows/weekly-feedback-sweep.yml"
  "scripts/onepassword-headless-proof-setup.sh"
  ".github/workflows/onepassword-headless-proof.yml"
  "tests/test_sync_overrides.sh"
  "tests/test_eslint_policy_check.sh"
  "tests/test_check_mktemp_portability.sh"
  "tests/test_session_finalization_check.sh"
  "tests/test_check_sync_manifest.sh"
  "tests/test_verify_propagation_pr_templated.sh"
  "scripts/audit-codex-latency.sh"
  "tests/test_audit_codex_latency.sh"
  "tests/fixtures/audit-codex-latency"
  "scripts/audit-review-latency.sh"
  "tests/test_audit_review_latency.sh"
  "scripts/audit-canonical-mirrors.sh"
  "tests/test_audit_canonical_mirrors.sh"
  "scripts/wave-audit.sh"
  "tests/test_wave_audit.sh"
  # Hub-only test harnesses that drive checks (not driven BY them) —
  # not in the manifest, so consumers do not have them.
  "tests/test_ci_scripts_wired.sh"
  "tests/test_repo_lint_consumer_safety.sh"
  # Same rationale as the line above, and its omission is why this net
  # passed on the hub while check_repo_lint_optimization hard-failed on a
  # real consumer (#1068): the fixture kept the file, so the wrapper found
  # it present and the assertions that read it never fired. #1069.
  "tests/test_consumer_residue_safety.sh"
)

# Hub-only STALE RESIDUE: excluded from the template mirror NOW, but still
# present in at least one live consumer that was bootstrapped BEFORE the
# exclusion landed. These must stay in the fixture — they are the shape that
# breaks a wrapper keying on "wrapped file present ⇒ hub checkout".
#
# Each entry records the live evidence that put it here. Re-verify with the
# probe loop in the header comment before removing one.
CONSUMER_RESIDUE_PRESENT=(
  # nathanjohnpayne/gaycruisebingo carries both, from commit a2965a93
  # "Initial commit (bootstrapped from mergepath)" (2026-07-07) — a
  # snapshot predating the #774 BOOTSTRAP_MIRROR_EXCLUDES entry. It has
  # NEITHER the workflow, NOR tests/test_audit_branch_protection_workflow.sh,
  # NOR the scripts/sync-to-downstream.sh hub marker. Verified against all
  # nine consumers 2026-07-28: gaycruisebingo is the only one.
  # This is the exact tree that made check_branch_protection_audit's
  # original both-absent SKIP branch miss and hard-fail on the missing
  # workflow; the wrapper now keys on the hub marker FIRST.
  "scripts/audit-branch-protection.sh"
  "tests/test_audit_branch_protection.sh"
)

# Hub-only content FROZEN AT BOOTSTRAP: the path is PRESENT on every
# consumer, but it is not a manifest entry, so it was seeded once by the
# template mirror and has never received a hub update. Neither existing
# list can express this — CONSUMER_ABSENT models "missing" and
# CONSUMER_RESIDUE_PRESENT models "a hub-only file an old bootstrap left
# behind", and this is neither: the file is present, expected, and simply
# stale.
#
# It is the class that produced the second half of #1068.
# check_git_identity_hygiene cases 26b/26c assert hub-CURRENT policy prose
# against $ROOT/REVIEW_POLICY.md; gaycruisebingo carries a 1181-line
# snapshot from its 2026-07-07 bootstrap, so three of those four assertions
# failed on the consumer and the fourth — a negative assertion — passed
# VACUOUSLY, which is the more dangerous half. A presence test cannot see
# any of it, because the file is there.
#
# The fixture models the PROPERTY (present, parseable, but not carrying the
# hub's current content), not one consumer's exact bytes: the net is
# hermetic and cannot fetch live consumers, and pinning real bytes would
# rot on the next edit. Each stub stays structurally valid so a check that
# parses the file fails on its ASSERTIONS rather than on a parse error,
# which would be a different bug than the one being modelled.
CONSUMER_FROZEN_CONTENT=(
  "REVIEW_POLICY.md"
  ".github/workflows/md-prose-wrap.yml"
)

# Mutual exclusivity with BOTH other lists. The comment previously claimed
# "absent or residue" while the loop only walked CONSUMER_ABSENT; a path in
# both frozen and residue would then pass silently, and because the
# frozen rewrite leaves the file present the later residue guard would pass
# too — so the modelled state would depend on which transformation ran last.
for frozen in "${CONSUMER_FROZEN_CONTENT[@]}"; do
  for pat in "${CONSUMER_ABSENT[@]}"; do
    if [ "$frozen" = "$pat" ]; then
      echo "FATAL: '$frozen' is in BOTH CONSUMER_FROZEN_CONTENT and CONSUMER_ABSENT." >&2
      echo "       A path cannot be simultaneously missing and present-but-stale." >&2
      exit 1
    fi
  done
  for res in "${CONSUMER_RESIDUE_PRESENT[@]}"; do
    if [ "$frozen" = "$res" ]; then
      echo "FATAL: '$frozen' is in BOTH CONSUMER_FROZEN_CONTENT and CONSUMER_RESIDUE_PRESENT." >&2
      echo "       Those model different things: residue is a HUB-ONLY file an old" >&2
      echo "       bootstrap left behind, frozen is a NON-MANIFEST file every" >&2
      echo "       consumer has at bootstrap-era content. Pick one." >&2
      exit 1
    fi
  done
done

for pat in "${CONSUMER_ABSENT[@]}"; do
  # Expand the glob inside the fixture; nullglob-style via compgen.
  while IFS= read -r hit; do
    [ -z "$hit" ] && continue
    rm -rf "$hit"
  done <<EOF
$(compgen -G "$FIX/$pat" || true)
EOF
done

# Apply the frozen-content model. The path must already exist in the hub
# tree — if it does not, the entry is stale and the fixture would silently
# model nothing, so fail loudly instead.
# A frozen entry is only meaningful while the manifest does NOT deliver the
# path. The moment one is added to .mergepath-sync.yml as a canonical entry
# or lands inside a kit directory, consumers receive its CURRENT contents and
# this model describes a consumer state that no longer exists — silently, and
# in the direction of validating marker guards that are no longer needed.
# Derive the closure from the manifest rather than restating it.
# BOTH .path and .dest: templated entries carry source/dest instead of path,
# so a .path-only extractor (with a null-drop that silently discards exactly
# those entries) would let a frozen path delivered as a templated dest slip
# through and model a consumer state that no longer exists.
#
# Only FLEET-WIDE entries retire a frozen fixture. The manifest supports
# consumer-scoped delivery (`consumers:` as a list rather than `all`), and
# two entries already use it. A frozen path added to such an entry is still
# frozen on every NON-enrolled consumer, so fataling there would force the
# fixture out while the consumers it models still need the coverage. Scoped
# entries are reported and allowed; the frozen state retires only once the
# modeled population is fully covered.
# Effective delivery is resolved PER FROZEN PATH by unioning every covering
# manifest entry -- the exact destination AND any containing kit directory.
#
# Grouping on the literal destination alone repeats the first-match bug that
# #467 already fixed in the closure check: tests/test_check_sync_manifest.sh
# Case 20 documents that coverage is UNIONED across every covering entry,
# because a path can be delivered to complementary consumer sets by a narrow
# exact entry and a broad kit at the same time. Taking either in isolation
# understates coverage and preserves a stale stub that every consumer has
# already moved past.
#
# `(.dest // .path)` is the DELIVERED path, matching how
# scripts/sync-to-downstream.sh resolves it; emitting both fields would treat
# a templated entry's SOURCE as consumer-delivered, which it never is.
frozen_manifest_json=$(yq -o=json '.' "$ROOT/.mergepath-sync.yml" 2>/dev/null)
if [ -z "$frozen_manifest_json" ]; then
  echo "FATAL: could not read .mergepath-sync.yml as JSON." >&2
  echo "       CONSUMER_FROZEN_CONTENT cannot be validated against effective" >&2
  echo "       delivery, and an entry the manifest now delivers would model a" >&2
  echo "       consumer state that does not exist. Failing closed." >&2
  exit 1
fi

# "fleetwide" | "partial" | "none" for one path.
frozen_delivery_for() {
  printf '%s' "$frozen_manifest_json" | jq -r --arg p "$1" '
    ([.consumers[].name] | unique) as $fleet
    | [ .paths[]
        | (.dest // .path) as $d
        | select($d != null)
        | select($d == $p or (($d | endswith("/")) and ($p | startswith($d))))
      ] as $covering
    | if ($covering | length) == 0 then "none"
      elif any($covering[]; .consumers == "all") then "fleetwide"
      elif (([$covering[] | select(.consumers != "all") | .consumers[]] | unique) == $fleet) then "fleetwide"
      else "partial" end'
}
for frozen in "${CONSUMER_FROZEN_CONTENT[@]}"; do
  case "$(frozen_delivery_for "$frozen")" in
    fleetwide)
      echo "FATAL: frozen-content path '$frozen' is delivered to EVERY consumer" >&2
      echo "       by the manifest (exact entry, containing kit, or the union of" >&2
      echo "       consumer-scoped entries). Consumers receive its current" >&2
      echo "       contents, so it is not frozen -- remove it from" >&2
      echo "       CONSUMER_FROZEN_CONTENT." >&2
      exit 1
      ;;
    partial)
      echo "NOTE: frozen-content path '$frozen' is delivered to SOME consumers only."
      echo "      Still frozen on every non-enrolled consumer, so the fixture stays."
      echo "      Retire it from CONSUMER_FROZEN_CONTENT once delivery covers all consumers."
      ;;
  esac
  if [ ! -f "$FIX/$frozen" ]; then
    echo "FATAL: frozen-content path '$frozen' is not a file in the fixture." >&2
    echo "       It is PRESENT on live consumers; if it moved or was deleted" >&2
    echo "       upstream, update CONSUMER_FROZEN_CONTENT rather than leaving a" >&2
    echo "       stale entry that models nothing." >&2
    exit 1
  fi
  case "$frozen" in
    *.yml|*.yaml)
      cat > "$FIX/$frozen" <<'FROZEN_YML'
# Bootstrap-era stand-in (tests/test_repo_lint_consumer_safety.sh).
# Structurally valid, deliberately missing every hub-current assertion.
name: frozen-bootstrap-stand-in
on:
  pull_request:
jobs:
  noop:
    runs-on: ubuntu-latest
    steps:
      - run: 'true'
FROZEN_YML
      ;;
    REVIEW_POLICY.md)
      # Path-specific, because a generic stub LAUNDERS the file: an
      # assertion that a check makes NEGATIVELY (this text must NOT be
      # here) passes vacuously once the offending text is gone, so the
      # fixture reports green on a consumer state that really fails.
      # That is the same vacuous-pass this whole model exists to catch,
      # reproduced one level up.
      #
      # A frozen file therefore has to carry BOTH shapes: it must LACK the
      # hub's current prose (so required-current assertions fail) and it
      # must STILL CARRY the obsolete text newer checks forbid (so
      # forbidden-stale assertions fail too). check_git_identity_hygiene
      # case 26b is exactly that pair: it rejects a runnable
      # `git config --global` placeholder AND requires the string
      # "verified machine setup".
      #
      # The placeholder below is inert fixture data, and the marker on its
      # line is what keeps this file's own tracked bytes from tripping the
      # static scan the placeholder is modelling.
      cat > "$FIX/$frozen" <<'FROZEN_REVIEW_POLICY'
# Bootstrap-era stand-in

PRESENT on every consumer but not a manifest entry, so it was seeded once
at bootstrap and never updated. It carries none of the hub's current prose
-- in particular it omits the machine-setup phrase case 26b greps for, which
is deliberately NOT reproduced anywhere in this file's heredoc, because
naming it here would satisfy the very assertion the stub must fail.

It also still publishes the runnable placeholder identity write that newer
policy forbids, so the NEGATIVE half of case 26b is exercised too:

    git config --global user.email you@example.com  # GIT_IDENTITY_SCOPE_EXEMPT: inert fixture stand-in, never executed
FROZEN_REVIEW_POLICY
      ;;
    *)
      cat > "$FIX/$frozen" <<'FROZEN_MD'
# Bootstrap-era stand-in

This file is PRESENT on every consumer but is not a manifest entry, so it
was seeded once at bootstrap and never updated. It deliberately carries
none of the hub's current prose.
FROZEN_MD
      ;;
  esac
done

# Guard the residue model against a future author "tidying" a residue path
# into CONSUMER_ABSENT — that edit would silently restore the clean-bootstrap
# assumption this suite exists to disprove, and hand back the same false
# green. Fail loudly instead.
for res in "${CONSUMER_RESIDUE_PRESENT[@]}"; do
  if [ ! -e "$FIX/$res" ]; then
    echo "FATAL: residue path '$res' is missing from the consumer fixture." >&2
    echo "       It is PRESENT in a live consumer, so the fixture must keep it." >&2
    echo "       Do not add CONSUMER_RESIDUE_PRESENT paths to CONSUMER_ABSENT;" >&2
    echo "       re-verify against live consumer state before changing either list." >&2
    exit 1
  fi
done

# A consumer checkout is a plain git repo (several checks run
# git ls-files / git rev-parse --show-toplevel against it).
git -C "$FIX" init -q
# Fail-closed isolation assertion: the fixture repo's toplevel MUST be
# the fixture itself before any add/commit. If a stray gitdir pointer
# survived, abort rather than touch the real repo.
# (pwd -P on both sides: macOS mktemp yields /var/... which git reports
# as the physical /private/var/... path.)
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
  commit -qm "consumer fixture"

# Mirror the workflow's make_ci_scripts_executable step.
chmod +x "$FIX"/scripts/ci/*

# ---------------------------------------------------------------------------
# Offline guard: PATH-shimmed gh that fails closed. Hermetic checks
# PATH-shim their own gh stubs (which win by prepending); anything that
# falls through to THIS shim was reaching for live GitHub.
# ---------------------------------------------------------------------------
SHIM="$WORKDIR/shim"
mkdir -p "$SHIM"
cat >"$SHIM/gh" <<'SH'
#!/usr/bin/env bash
echo "test_repo_lint_consumer_safety: live gh call blocked (offline fixture): gh $*" >&2
exit 64
SH
chmod +x "$SHIM/gh"

# ---------------------------------------------------------------------------
# Enumerate the wired checks from the FIXTURE's repo_lint.yml with the
# same awk run-line detection check_ci_scripts_wired uses (comment-only
# mentions do not count; inline `run: |` bodies do not count).
# ---------------------------------------------------------------------------
WIRED=$(awk '
  {
    sub(/[[:space:]]*#.*$/, "")
    if (match($0, /^[[:space:]]*run:[[:space:]]*\.\/scripts\/ci\/check_[A-Za-z0-9_]+/)) {
      line = substr($0, RSTART, RLENGTH)
      sub(/^[[:space:]]*run:[[:space:]]*\.\/scripts\/ci\//, "", line)
      print line
    }
  }
' "$FIX/.github/workflows/repo_lint.yml" | LC_ALL=C sort -u)

if [ -z "$WIRED" ]; then
  fail "no wired checks found in the fixture repo_lint.yml (awk extraction broken?)"
  echo "test_repo_lint_consumer_safety: 0 passed, 1 failed"
  exit 1
fi

WIRED_COUNT=$(printf '%s\n' "$WIRED" | wc -l | tr -d ' ')
echo "test_repo_lint_consumer_safety: running $WIRED_COUNT wired checks against the consumer fixture"

# ---------------------------------------------------------------------------
# Run every wired check from the fixture root; each must exit 0.
# ---------------------------------------------------------------------------
while IFS= read -r name; do
  [ -z "$name" ] && continue
  if ! repo_lint_check_is_selected "$name"; then
    continue
  fi
  set +e
  out=$(
    cd "$FIX" && \
    env -u GH_TOKEN -u GITHUB_TOKEN \
        -u OP_PREFLIGHT_REVIEWER_PAT -u OP_PREFLIGHT_AUTHOR_PAT \
        MERGEPATH_CONSUMER_SAFETY=1 \
        GITHUB_REPOSITORY="nathanjohnpayne/consumer-fixture" \
        PATH="$SHIM:$PATH" \
        bash "./scripts/ci/$name" </dev/null 2>&1
  )
  rc=$?
  set -e
  if [ "$rc" -eq 0 ]; then
    # Surface the wrapper's OWN verdict. Nested regression suites also print
    # SKIP for optional fixtures; treating any occurrence as the wrapper's
    # disposition made fully-executed checks look skipped in timing audits.
    verdict=$(printf '%s\n' "$out" | bash "$FIX/scripts/ci/repo-lint-consumer-verdict.sh" "$name")
    pass "$name: consumer-safe ($verdict)"
  else
    fail "$name: exit $rc on the consumer fixture — would red every consumer repo-lint. Output tail:"
    echo "$out" | tail -15 >&2
  fi
done <<< "$WIRED"

# ---------------------------------------------------------------------------
# #979 — KIT-LESS consumer safety.
#
# The fixture above models a consumer that received the whole manifest
# (`.github/workflows/repo_lint.yml` carries `requires: ["scripts/ci/"]`, so
# the kit travels with it). That model has a hole: a consumer may SKIP the kit
# in its `.sync-overrides.yml` — gaycruisebingo does today, for the whole
# `scripts/ci/` directory — and then receive this workflow WITHOUT the scripts
# it invokes. A bare `run: ./scripts/ci/check_X` reds that consumer's lint on
# rc 127 forever, and the consumer cannot fix it: the hub owns the kit.
#
# So every `run: ./scripts/ci/check_X` step must carry the #590 missing-file
# soft-pass tail. This block asserts that BEHAVIOURALLY, by executing each
# step's actual `run:` body under the Actions default shell against three
# throwaway trees, rather than by grepping for one blessed spelling of the
# idiom (two spellings are in use) or by hand-listing the check names — a
# check added tomorrow is covered the moment its step lands:
#
#   (a) kit-less   — scripts/ci/ exists but is EMPTY  → must exit 0
#   (b) stub PASS  — scripts/ci/check_X exits 0       → must exit 0
#   (c) stub FAIL  — scripts/ci/check_X exits 3       → must exit 3
#
# (c) is the load-bearing half: a soft-pass that swallowed a real violation
# would be worse than the 127 it replaces.
#
# Steps are enumerated by PARSING the workflow document (ruby -ryaml), not by
# scanning lines, so a `run:` body is read exactly as Actions reads it. Two
# fences keep that enumeration honest: a multi-line `run: |` body that invokes
# a kit check is a hard failure (it would slip past the single-line matcher),
# and the parsed name set must equal the awk-derived $WIRED set used above.
#
# Paired hub-side assertion: because the tail exits 0 on an ABSENT script, it
# would also mask a script deleted from the hub while its wire stayed. Every
# wired name must therefore resolve to a file in the hub's scripts/ci/.
# ---------------------------------------------------------------------------
GUARD_DIR="$WORKDIR/guard"
mkdir -p "$GUARD_DIR"

cat >"$GUARD_DIR/extract.rb" <<'RB'
require 'yaml'
require 'fileutils'
doc = YAML.safe_load(File.read(ARGV.fetch(0)), aliases: false)
abort('workflow did not parse as a mapping') unless doc.is_a?(Hash)
bodies = ARGV.fetch(1)
FileUtils.mkdir_p(bodies)
# `pos` is the step's ORDINAL in the job, counted over every step carrying a
# run: body. It is what lets the caller assert ORDERING — a setup step that
# makes the kit executable is only useful if it runs BEFORE the first check
# wire, and Actions runs steps in document order.
pos = 0
first_wire = nil
(doc['jobs'] || {}).each_value do |job|
  next unless job.is_a?(Hash)
  (job['steps'] || []).each do |step|
    next unless step.is_a?(Hash)
    run = step['run']
    next unless run.is_a?(String)
    pos += 1
    wire = run.match(%r{\A\./scripts/ci/(check_[A-Za-z0-9_]+)})
    if run.include?("\n")
      # A multi-line body invoking a kit check would escape the single-line
      # matcher below and go unguarded. Report it; the caller fails on it.
      puts "MULTILINE\t#{step['name']}\t" if run =~ %r{\./scripts/ci/check_[A-Za-z0-9_]+}
    elsif wire
      first_wire = pos if first_wire.nil?
      puts "STEP\t#{wire[1]}\t#{run}"
      next
    end
    # Any step that touches the kit path WITHOUT being a check wire is a
    # setup step: it runs ahead of the guarded checks, so if it dies on a
    # kit-less consumer none of their soft-pass tails is ever reached. The
    # body can be multi-line, so it travels via a file rather than the TSV;
    # the body file is named by `pos`, so the row carries its own ordinal.
    next if wire
    next unless run.include?('scripts/ci')
    File.write(File.join(bodies, pos.to_s), run)
    puts "SETUP\t#{step['name']}\t#{pos}"
  end
end
puts "FIRSTWIRE\t\t#{first_wire}" unless first_wire.nil?
RB

if ! ruby "$GUARD_DIR/extract.rb" "$ROOT/.github/workflows/repo_lint.yml" \
      "$GUARD_DIR/bodies" \
      >"$GUARD_DIR/steps.tsv" 2>"$GUARD_DIR/extract.err"; then
  fail "#979 guard: could not parse repo_lint.yml: $(tail -3 "$GUARD_DIR/extract.err")"
  echo ""
  echo "test_repo_lint_consumer_safety: $PASS passed, $FAIL failed"
  exit 1
fi

if grep -q '^MULTILINE' "$GUARD_DIR/steps.tsv"; then
  while IFS=$'\t' read -r _ stepname _; do
    fail "#979 guard: step '$stepname' invokes a scripts/ci check from a multi-line run: body — it cannot carry the one-line soft-pass tail and escapes this assertion; make it a single-line run:"
  done < <(grep '^MULTILINE' "$GUARD_DIR/steps.tsv")
fi

awk -F'\t' '$1 == "STEP" { print $2 }' "$GUARD_DIR/steps.tsv" \
  | LC_ALL=C sort -u >"$GUARD_DIR/parsed_names.txt"
printf '%s\n' "$WIRED" >"$GUARD_DIR/awk_names.txt"
if ! diff -u "$GUARD_DIR/awk_names.txt" "$GUARD_DIR/parsed_names.txt" >"$GUARD_DIR/names.diff" 2>&1; then
  fail "#979 guard: the parsed step set disagrees with the awk-derived wired set (one enumeration is stale):"
  head -20 "$GUARD_DIR/names.diff" >&2
else
  pass "#979 guard: parsed step set matches the awk-derived wired set ($(wc -l <"$GUARD_DIR/parsed_names.txt" | tr -d ' ') checks)"
fi

# Actions' default shell for a `run:` body, so the tail is exercised under the
# same `-e -o pipefail` semantics it runs under in CI.
guard_run() {  # $1 = tree, $2 = command
  ( cd "$1" && bash --noprofile --norc -e -o pipefail -c "$2" ) >/dev/null 2>&1
}

guard_tree() {  # $1 = dir, $2 = check name, $3 = stub exit code ("" for none)
  rm -rf "$1"
  mkdir -p "$1/scripts/ci"
  if [ -n "$3" ]; then
    printf '#!/bin/sh\nexit %s\n' "$3" >"$1/scripts/ci/$2"
    chmod +x "$1/scripts/ci/$2"
  fi
}

GUARDED=0
while IFS=$'\t' read -r kind name cmd; do
  [ "$kind" = "STEP" ] || continue

  # Hub-side pairing: the tail exits 0 when the script is absent, so a wire
  # whose script vanished from the hub must be caught here instead.
  if [ ! -f "$ROOT/scripts/ci/$name" ]; then
    fail "#979 guard: repo_lint.yml wires $name but scripts/ci/$name does not exist on the hub (the soft-pass tail would silently swallow this)"
    continue
  fi

  ok=1

  guard_tree "$GUARD_DIR/kitless" "$name" ""
  if ! guard_run "$GUARD_DIR/kitless" "$cmd"; then
    ok=0
    fail "#979 guard: $name — the run: body exits nonzero when scripts/ci/ is EMPTY; a consumer that skips the kit (gaycruisebingo) reds its repo-lint on rc 127. Add the #590 soft-pass tail: || { rc=\$?; if [ ! -f scripts/ci/$name ]; then echo '...'; exit 0; fi; exit \"\$rc\"; }"
  fi

  guard_tree "$GUARD_DIR/stubpass" "$name" 0
  if ! guard_run "$GUARD_DIR/stubpass" "$cmd"; then
    ok=0
    fail "#979 guard: $name — the run: body exits nonzero when the script is PRESENT and passing"
  fi

  guard_tree "$GUARD_DIR/stubfail" "$name" 3
  set +e
  guard_run "$GUARD_DIR/stubfail" "$cmd"
  frc=$?
  set -e
  if [ "$frc" -ne 3 ]; then
    ok=0
    fail "#979 guard: $name — the run: body exits $frc (expected 3) when the script is PRESENT and FAILING; the soft-pass must never swallow a real violation"
  fi

  # NB: an `[ ... ] && GUARDED=$((...))` one-liner here would abort the whole
  # suite under `set -e` on the first failing step (a failing AND-list as the
  # last command of a loop body is fatal), reporting one finding instead of
  # all of them. Keep the explicit `if`.
  if [ "$ok" -eq 1 ]; then
    GUARDED=$((GUARDED + 1))
  fi
done <"$GUARD_DIR/steps.tsv"

if [ "$GUARDED" -gt 0 ]; then
  pass "#979 guard: $GUARDED wired steps soft-pass a missing script, pass a passing one, and propagate a real failure"
fi

# ---------------------------------------------------------------------------
# #979 round 2 — the SETUP steps ahead of the guarded checks.
#
# The block above proves each check wire survives a kit-less consumer. That is
# necessary and not sufficient: a step that touches scripts/ci/ WITHOUT being
# a check wire runs first, and if it dies on a kit-less tree the job reds
# there and no tail below it is ever reached. `make_ci_scripts_executable`
# was exactly that — `chmod +x scripts/ci/*` hands the unmatched glob to chmod
# literally, which exits nonzero on a consumer that skipped the kit.
#
# Two consumer shapes, because they are not the same file system state:
#   (a) no scripts/ci/ directory at all — a consumer that skipped the kit;
#   (b) scripts/ci/ present but EMPTY — the shape the guard loop above uses.
# Both must exit 0. A third probe keeps the assertion honest: on a POPULATED
# kit the setup steps must still do their job, so a mode-644 check_* must come
# out executable. Without it, deleting the step entirely would pass (a) and
# (b) and silently break every check invocation in CI.
# ---------------------------------------------------------------------------
SETUP_SEEN=0
while IFS=$'\t' read -r kind stepname bodyid; do
  [ "$kind" = "SETUP" ] || continue
  SETUP_SEEN=$((SETUP_SEEN + 1))
  setup_body="$(cat "$GUARD_DIR/bodies/$bodyid")"

  rm -rf "$GUARD_DIR/nokit"
  mkdir -p "$GUARD_DIR/nokit/scripts"
  if guard_run "$GUARD_DIR/nokit" "$setup_body"; then
    pass "#979 setup: '$stepname' exits 0 with no scripts/ci/ directory"
  else
    fail "#979 setup: step '$stepname' exits nonzero when scripts/ci/ is ABSENT — it runs before every guarded check, so a consumer that skipped the kit reds repo-lint here and no soft-pass tail below is ever reached. Guard it on the directory existing."
  fi

  rm -rf "$GUARD_DIR/emptykit"
  mkdir -p "$GUARD_DIR/emptykit/scripts/ci"
  if guard_run "$GUARD_DIR/emptykit" "$setup_body"; then
    pass "#979 setup: '$stepname' exits 0 with an EMPTY scripts/ci/"
  else
    fail "#979 setup: step '$stepname' exits nonzero when scripts/ci/ is present but EMPTY (an unmatched glob is passed through literally)"
  fi
done <"$GUARD_DIR/steps.tsv"

FIRST_WIRE_POS="$(awk -F'\t' '$1 == "FIRSTWIRE" { print $3 }' "$GUARD_DIR/steps.tsv")"

if [ "$SETUP_SEEN" -eq 0 ]; then
  fail "#979 setup: no non-check step referencing scripts/ci/ was found in repo_lint.yml — the kit is made executable somewhere, so this enumeration has gone stale and stopped covering it"
elif [ -z "$FIRST_WIRE_POS" ]; then
  fail "#979 setup: the parser found no check wire at all, so step ORDER cannot be established (extraction is stale)"
else
  # ORDER matters, not just presence. Actions runs steps in document order, so
  # a setup step that makes the kit executable is only doing its job if it
  # runs BEFORE the first check wire — move it below them and production
  # fails at the first check with rc 126 while a presence-only probe still
  # goes green. Replay ONLY the setup steps that precede the first wire, and
  # require the kit to be executable after them.
  rm -rf "$GUARD_DIR/populated"
  mkdir -p "$GUARD_DIR/populated/scripts/ci"
  printf '#!/bin/sh\nexit 0\n' >"$GUARD_DIR/populated/scripts/ci/check_probe"
  chmod 644 "$GUARD_DIR/populated/scripts/ci/check_probe"
  setup_ok=1
  PRE_WIRE_SETUP=0
  while IFS=$'\t' read -r kind _stepname bodyid; do
    [ "$kind" = "SETUP" ] || continue
    [ "$bodyid" -lt "$FIRST_WIRE_POS" ] || continue
    PRE_WIRE_SETUP=$((PRE_WIRE_SETUP + 1))
    if ! guard_run "$GUARD_DIR/populated" "$(cat "$GUARD_DIR/bodies/$bodyid")"; then
      setup_ok=0
    fi
  done <"$GUARD_DIR/steps.tsv"
  if [ "$PRE_WIRE_SETUP" -eq 0 ]; then
    fail "#979 setup: no kit-touching setup step runs BEFORE the first check wire (first wire is step $FIRST_WIRE_POS) — the checks would execute against a non-executable kit and fail with rc 126"
  elif [ "$setup_ok" -eq 1 ] && [ -x "$GUARD_DIR/populated/scripts/ci/check_probe" ]; then
    pass "#979 setup: the $PRE_WIRE_SETUP setup step(s) ahead of the first check wire make a populated scripts/ci/ executable"
  else
    fail "#979 setup: after running the pre-wire setup step(s) on a POPULATED tree, scripts/ci/check_probe is not executable — the kit-less guard must not cost the step its actual job"
  fi
fi

echo ""
echo "test_repo_lint_consumer_safety: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
