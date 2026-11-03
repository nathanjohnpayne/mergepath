#!/usr/bin/env bash
# tests/test_review_cost_preview.sh — hermetic coverage for
# scripts/review-cost-preview.sh and the --no-fingerprint seam it uses in
# scripts/workflow/external_review_fingerprint.sh (#1679).
#
# Every case builds a throwaway git repository whose base commit carries its
# own .github/review-policy.yml, commits a branch on top, and runs the preview
# with `--base main`. A `gh` stub that logs and FAILS on any call sits first on
# PATH, and no token or op-preflight cache is visible, so a GitHub call
# anywhere in the preview (or either emitter it drives) is caught twice: the
# call fails the case, and the log must be empty at the end.
#
# Cases: under-threshold, over-threshold, protected path, protected path
# renamed away, 4b trigger with and without Phase 4, a body-only trigger via
# --body-file, a binary file, the synthesized files JSON shape, emitter
# parity, and the --no-fingerprint contract. Bash 3.2 portable.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PREVIEW="$ROOT/scripts/review-cost-preview.sh"
FINGERPRINT="$ROOT/scripts/workflow/external_review_fingerprint.sh"
CLASSIFIER="$ROOT/scripts/phase-4b-classifier.sh"
for f in "$PREVIEW" "$FINGERPRINT" "$CLASSIFIER"; do
  [ -f "$f" ] || { echo "missing $f" >&2; exit 1; }
done
command -v jq >/dev/null 2>&1 || { echo "test_review_cost_preview: jq is required" >&2; exit 1; }
command -v git >/dev/null 2>&1 || { echo "test_review_cost_preview: git is required" >&2; exit 1; }

# A hook or an outer git process can export these; the fixtures must never
# write through them into a real repository.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY 2>/dev/null || true

PASS=0
FAIL=0
pass() { echo "PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $*" >&2; FAIL=$((FAIL + 1)); }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/review-cost-preview-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$WORK/bin" "$WORK/empty-cache"
chmod 700 "$WORK/empty-cache"
GH_LOG="$WORK/gh-calls.log"
: > "$GH_LOG"
cat > "$WORK/bin/gh" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$GH_LOG"
echo "gh stub: no GitHub call is allowed in the preview" >&2
exit 1
STUB
chmod +x "$WORK/bin/gh"

# No credential of any kind is visible: an empty op-preflight cache (the
# classifier sources preflight-helpers.sh, which reads it) and no tokens.
export PATH="$WORK/bin:$PATH"
export OP_PREFLIGHT_CACHE_DIR="$WORK/empty-cache"
unset GH_TOKEN GITHUB_TOKEN OP_PREFLIGHT_REVIEWER_PAT OP_PREFLIGHT_AUTHOR_PAT 2>/dev/null || true
hash -r 2>/dev/null || true

POLICY_SMALL='external_review_threshold: 20
external_review_paths:
  - ".github/**"
  - "**/*secret*"
phase_4b_default: complex-changes
'

gitc() {
  local repo=$1; shift
  git -C "$repo" -c user.name=fixture -c user.email=fixture@example.invalid \
    -c commit.gpgsign=false -c core.hooksPath=/dev/null "$@"
}

# new_repo <name> <policy text>: a repo with one base commit on main holding the
# policy and a seed file, checked out on branch `feature`.
new_repo() {
  local repo="$WORK/$1"
  mkdir -p "$repo/.github" "$repo/docs"
  git init -q -b main "$repo" 2>/dev/null || { git init -q "$repo"; gitc "$repo" checkout -q -b main; }
  printf '%s' "$2" > "$repo/.github/review-policy.yml"
  printf 'seed\n' > "$repo/docs/seed.md"
  gitc "$repo" add -A
  gitc "$repo" commit -q -m base
  gitc "$repo" checkout -q -b feature
  printf '%s' "$repo"
}

commit_all() {
  gitc "$1" add -A
  gitc "$1" commit -q -m "$2"
}

lines() { # lines <n> <prefix>
  local i=1
  while [ "$i" -le "$1" ]; do printf '%s %s\n' "$2" "$i"; i=$((i + 1)); done
}

# run_preview <repo> [args...]: sets OUT, ERR, RC.
run_preview() {
  local repo=$1; shift
  set +e
  OUT=$(cd "$repo" && bash "$PREVIEW" --base main "$@" 2>"$WORK/preview.err")
  RC=$?
  set -e
  ERR=$(cat "$WORK/preview.err")
}

jget() { printf '%s' "$OUT" | jq -c "$1" 2>/dev/null; }

# ── 1. Under threshold ─────────────────────────────────────────────────────
R=$(new_repo under "$POLICY_SMALL")
lines 5 note > "$R/docs/note.md"
commit_all "$R" small
run_preview "$R"
if [ "$RC" -eq 0 ] \
  && [ "$(jget '[.phase_4.required, .phase_4.lines_changed, .phase_4.threshold, .phase_4.reasons, .phase_4b.invoked]')" = '[false,5,20,[],false]' ] \
  && [ "$(jget '.head.sha')" = "\"$(gitc "$R" rev-parse HEAD)\"" ] \
  && [ "$(jget '.head.uncommitted_changes')" = false ] \
  && printf '%s' "$ERR" | grep -q 'Phase 4 external review: not required (5 lines < threshold 20'; then
  pass "under-threshold diff: Phase 4 not required, 5 of 20 lines, full head SHA reported"
else
  fail "under-threshold diff (rc=$RC out=$OUT err=$ERR)"
fi

# ── 2. Over threshold ──────────────────────────────────────────────────────
R=$(new_repo over "$POLICY_SMALL")
lines 25 row > "$R/docs/big.md"
commit_all "$R" big
run_preview "$R"
if [ "$RC" -eq 0 ] \
  && [ "$(jget '[.phase_4.required, .phase_4.lines_changed, .phase_4.reasons]')" = '[true,25,["25 lines changed >= threshold 20"]]' ] \
  && [ "$(jget '[.external_review_fingerprint.fingerprint, .external_review_fingerprint.fingerprint_skipped, .external_review_fingerprint.fingerprint_paths]')" = '["",true,["docs/big.md"]]' ] \
  && [ "$(jget '.phase_4b.invoked')" = false ] \
  && printf '%s' "$ERR" | grep -q 'Phase 4 external review: REQUIRED (25 lines changed >= threshold 20)'; then
  pass "over-threshold diff: Phase 4 required on lines, fingerprint explicitly skipped"
else
  fail "over-threshold diff (rc=$RC out=$OUT err=$ERR)"
fi

# Uncommitted work is reported, not counted.
lines 30 extra > "$R/docs/uncommitted.md"
run_preview "$R"
if [ "$RC" -eq 0 ] && [ "$(jget '[.head.uncommitted_changes, .phase_4.lines_changed]')" = '[true,25]' ] \
  && printf '%s' "$ERR" | grep -q 'uncommitted changes'; then
  pass "uncommitted changes are flagged and left out of the count"
else
  fail "uncommitted changes (rc=$RC out=$OUT)"
fi

# ── 3. Protected path ──────────────────────────────────────────────────────
R=$(new_repo protected "$POLICY_SMALL")
mkdir -p "$R/.github/workflows"
printf 'name: ci\n' > "$R/.github/workflows/ci.yml"
commit_all "$R" workflow
run_preview "$R"
if [ "$RC" -eq 0 ] \
  && [ "$(jget '[.phase_4.required, .phase_4.lines_changed, .phase_4.protected_paths]')" = '[true,1,[".github/workflows/ci.yml"]]' ] \
  && printf '%s' "$ERR" | grep -q 'protected paths modified: .github/workflows/ci.yml'; then
  pass "protected-path diff: one line still requires Phase 4"
else
  fail "protected-path diff (rc=$RC out=$OUT err=$ERR)"
fi

# A protected file renamed to an unprotected path (#763): the synthesized
# record must carry previous_filename so the rename source still matches.
R=$(new_repo rename "$POLICY_SMALL")
mkdir -p "$R/.github/workflows"
lines 12 step > "$R/.github/workflows/deploy.yml"
commit_all "$R" add-workflow
gitc "$R" checkout -q main
gitc "$R" merge -q --ff-only feature
gitc "$R" checkout -q feature
gitc "$R" mv .github/workflows/deploy.yml docs/deploy.yml
commit_all "$R" move
run_preview "$R" --write-files-json "$WORK/rename-files.json"
if [ "$RC" -eq 0 ] \
  && [ "$(jq -c '[.[] | {filename, status, previous_filename, additions, deletions, changes, has_patch: has("patch")}]' "$WORK/rename-files.json")" = '[{"filename":"docs/deploy.yml","status":"renamed","previous_filename":".github/workflows/deploy.yml","additions":0,"deletions":0,"changes":0,"has_patch":false}]' ] \
  && [ "$(jget '[.phase_4.required, .phase_4.protected_paths]')" = '[true,[".github/workflows/deploy.yml"]]' ]; then
  pass "rename away from a protected path: renamed record with previous_filename, Phase 4 required"
else
  fail "protected rename (rc=$RC out=$OUT files=$(cat "$WORK/rename-files.json" 2>/dev/null))"
fi
# A pure rename has no hunk, so (as on GitHub) the classifier cannot inspect it
# and takes the conservative route.
if [ "$(jget '[.phase_4b.invoked, .phase_4b.recommendation, .phase_4b_classifier.exit_code]')" = '[true,"invoke-4b",1]' ] \
  && printf '%s' "$OUT" | jq -e '.phase_4b.rationale | contains("patch unavailable")' >/dev/null; then
  pass "pure rename: no patch, classifier routes to 4b conservatively (#2295)"
else
  fail "pure rename 4b routing (out=$OUT)"
fi

# ── 4. Phase 4b trigger ────────────────────────────────────────────────────
R=$(new_repo trigger "$POLICY_SMALL")
mkdir -p "$R/src"
{ printf 'await Promise.all(jobs);\n'; lines 24 work; } > "$R/src/runner.js"
commit_all "$R" concurrency
run_preview "$R"
if [ "$RC" -eq 0 ] \
  && [ "$(jget '[.phase_4.required, .phase_4b.invoked, .phase_4b.triggers, .phase_4b.recommendation, .phase_4b_classifier.exit_code]')" = '[true,true,["concurrency"],"invoke-4b",1]' ] \
  && printf '%s' "$ERR" | grep -q 'Phase 4b: INVOKED proactively on triggers: concurrency'; then
  pass "4b-trigger diff over threshold: Phase 4b invoked on the concurrency trigger"
else
  fail "4b-trigger diff (rc=$RC out=$OUT err=$ERR)"
fi

# The same trigger under the threshold: the classifier matches, but proactive
# 4b applies only to a PR that needs Phase 4.
R=$(new_repo trigger-small "$POLICY_SMALL")
mkdir -p "$R/src"
printf 'await Promise.all(jobs);\n' > "$R/src/runner.js"
commit_all "$R" concurrency
run_preview "$R"
if [ "$RC" -eq 0 ] \
  && [ "$(jget '[.phase_4.required, .phase_4b.invoked, .phase_4b.match, .phase_4b.triggers]')" = '[false,false,true,["concurrency"]]' ] \
  && printf '%s' "$ERR" | grep -q 'Phase 4b: not invoked, Phase 4 is not required'; then
  pass "4b trigger under threshold: classifier matches, Phase 4b not invoked"
else
  fail "4b trigger under threshold (rc=$RC out=$OUT err=$ERR)"
fi

# A body-only trigger fires only when the draft body is supplied.
R=$(new_repo body "$POLICY_SMALL")
lines 21 rule > "$R/docs/rules.md"
commit_all "$R" rules
run_preview "$R"
no_body=$(jget '[.pr_body_supplied, .phase_4b.triggers]')
no_body_note=no
printf '%s' "$ERR" | grep -q 'PR body not supplied' && no_body_note=yes
printf 'This keeps the ordering invariant intact.\n' > "$WORK/body.md"
run_preview "$R" --body-file "$WORK/body.md"
if [ "$no_body" = '[false,[]]' ] && [ "$no_body_note" = yes ] && [ "$RC" -eq 0 ] \
  && [ "$(jget '[.pr_body_supplied, .phase_4b.invoked, .phase_4b.triggers]')" = '[true,true,["invariant-enforcement"]]' ]; then
  pass "--body-file feeds the classifier's body-only triggers; without it the summary says they were skipped"
else
  fail "body-only trigger (no_body=$no_body note=$no_body_note rc=$RC out=$OUT)"
fi

# ── 5. Policy short-circuit and binary content ─────────────────────────────
R=$(new_repo fallback "external_review_threshold: 20
phase_4b_default: fallback-only
")
{ printf 'await Promise.all(jobs);\n'; lines 24 work; } > "$R/docs/runner.md"
printf '\000\001\002binary' > "$R/docs/blob.bin"
commit_all "$R" mixed
run_preview "$R" --write-files-json "$WORK/binary-files.json"
if [ "$RC" -eq 0 ] \
  && [ "$(jget '[.phase_4.required, .phase_4b.invoked, .phase_4b.recommendation, .phase_4b.phase_4b_default]')" = '[true,false,"fallback-only","fallback-only"]' ] \
  && [ "$(jq -c '[.[] | select(.filename == "docs/blob.bin") | {status, additions, deletions, changes, has_patch: has("patch")}]' "$WORK/binary-files.json")" = '[{"status":"added","additions":0,"deletions":0,"changes":0,"has_patch":false}]' ]; then
  pass "fallback-only policy read from the base; binary file synthesized as 0/0 with no patch"
else
  fail "fallback-only / binary (rc=$RC out=$OUT files=$(cat "$WORK/binary-files.json" 2>/dev/null))"
fi

# ── 6. Synthesized shape and emitter parity ────────────────────────────────
# The record for a modified file matches the pulls/N/files shape, and running
# each emitter directly on the synthesized JSON gives the preview's answers.
R=$(new_repo shape "$POLICY_SMALL")
printf 'seed\nmore\n' > "$R/docs/seed.md"
lines 22 row > "$R/docs/new.md"
commit_all "$R" shape
run_preview "$R" --write-files-json "$WORK/shape-files.json"
seed=$(jq -c '.[] | select(.filename == "docs/seed.md")' "$WORK/shape-files.json")
expected_seed='{"filename":"docs/seed.md","status":"modified","additions":1,"deletions":0,"changes":1,"patch":"@@ -1 +1,2 @@\n seed\n+more"}'
direct_fp=$(bash "$FINGERPRINT" --no-fingerprint --files-json "$WORK/shape-files.json" --config "$R/.github/review-policy.yml" 2>/dev/null || true)
set +e
direct_cl=$(MERGEPATH_REVIEW_POLICY_PATH="$R/.github/review-policy.yml" bash "$CLASSIFIER" 1 --fixture "$WORK/shape-files.json" 2>/dev/null)
set -e
if [ "$RC" -eq 0 ] && [ "$seed" = "$expected_seed" ] \
  && [ "$(printf '%s' "$direct_fp" | jq -cS .)" = "$(jget '.external_review_fingerprint' | jq -cS .)" ] \
  && [ "$(printf '%s' "$direct_cl" | jq -cS '{match, triggers, recommendation}')" = "$(jget '.phase_4b_classifier | {match, triggers, recommendation}' | jq -cS .)" ]; then
  pass "synthesized record has the pulls/N/files shape; both emitters agree with the preview"
else
  fail "shape/parity (rc=$RC seed=$seed direct_fp=$direct_fp direct_cl=$direct_cl out=$OUT)"
fi

# GitHub joins two hunks whose changes sit seven unchanged lines apart into
# one; git's default keeps them apart. The patch must follow GitHub.
R=$(new_repo hunks "$POLICY_SMALL")
lines 20 l > "$R/docs/hunks.md"
commit_all "$R" add-hunks
gitc "$R" checkout -q main
gitc "$R" merge -q --ff-only feature
gitc "$R" checkout -q feature
sed -e 's/^l 2$/changed 2/' -e 's/^l 10$/changed 10/' "$R/docs/hunks.md" > "$WORK/hunks.tmp"
mv "$WORK/hunks.tmp" "$R/docs/hunks.md"
commit_all "$R" two-edits
run_preview "$R" --write-files-json "$WORK/hunks-files.json"
hunk_headers=$(jq -r '.[0].patch' "$WORK/hunks-files.json" | grep -c '^@@' || true)
if [ "$RC" -eq 0 ] && [ "$hunk_headers" = 1 ] \
  && [ "$(jq -r '.[0].patch' "$WORK/hunks-files.json" | head -1)" = '@@ -1,13 +1,13 @@' ]; then
  pass "changes seven lines apart form one hunk, as GitHub's patch does"
else
  fail "hunk joining (rc=$RC headers=$hunk_headers patch=$(jq -c '.[0].patch' "$WORK/hunks-files.json" 2>/dev/null))"
fi

# Local git state GitHub never sees must not move the answer (Codex P2 x2 on
# #2970): a repository diff.context=0 would drop the unchanged Promise.all
# line from the patch the classifier scans, and a local `-diff` attribute (in
# .git/info/attributes or an uncommitted .gitattributes) would turn the file
# binary and zero its count.
R=$(new_repo local-state "external_review_threshold: 1
phase_4b_default: complex-changes
")
mkdir -p "$R/src"
printf 'const a = 1;\nawait Promise.all(jobs);\nconst b = 2;\nconst c = 3;\n' > "$R/src/job.js"
commit_all "$R" add-job
gitc "$R" checkout -q main
gitc "$R" merge -q --ff-only feature
gitc "$R" checkout -q feature
printf 'const a = 1;\nawait Promise.all(jobs);\nconst b = 2;\nconst c = 4;\n' > "$R/src/job.js"
commit_all "$R" edit-job
run_preview "$R"
clean=$(jget '[.phase_4.lines_changed, .phase_4b.triggers]')
git -C "$R" config diff.context 0
git -C "$R" config diff.algorithm histogram
mkdir -p "$(git -C "$R" rev-parse --absolute-git-dir)/info"
printf '*.js -diff\n' >> "$(git -C "$R" rev-parse --absolute-git-dir)/info/attributes"
printf '*.js binary\n' > "$R/.gitattributes"
run_preview "$R"
if [ "$clean" = '[2,["concurrency"]]' ] && [ "$RC" -eq 0 ] \
  && [ "$(jget '[.phase_4.lines_changed, .phase_4b.triggers, .phase_4.required, .phase_4b.invoked]')" = '[2,["concurrency"],true,true]' ]; then
  pass "repository diff config and local attributes do not change the counts or the 4b route"
else
  fail "local git state leaked into the preview (clean=$clean rc=$RC out=$OUT err=$ERR)"
fi

# Live-mode parity for the decision fields: the fingerprint WITHOUT
# --no-fingerprint, on the same files JSON, reports the same requires_review,
# lines_changed, threshold and reasons. Under the threshold the live mode
# returns before its first API read, so the failing gh stub stays silent.
R=$(new_repo live-parity "$POLICY_SMALL")
lines 7 row > "$R/docs/small.md"
commit_all "$R" small
run_preview "$R" --write-files-json "$WORK/live-files.json"
live_fp=$(bash "$FINGERPRINT" --repo o/r --pr 1 --ref "$(gitc "$R" rev-parse HEAD)" --files-json "$WORK/live-files.json" --config "$R/.github/review-policy.yml" 2>/dev/null || true)
if [ "$RC" -eq 0 ] && [ -n "$live_fp" ] \
  && [ "$(printf '%s' "$live_fp" | jq -c '[.requires_review, .lines_changed, .threshold, .reasons]')" = "$(jget '[.phase_4.required, .phase_4.lines_changed, .phase_4.threshold, .phase_4.reasons]')" ] \
  && [ "$(printf '%s' "$live_fp" | jq -c 'has("fingerprint_skipped")')" = false ]; then
  pass "live-mode fingerprint and preview agree on the decision fields; live output has no offline key"
else
  fail "live-mode parity (live=$live_fp out=$OUT)"
fi

# ── 7. Governing policy is the BASE copy, not the branch's edit ────────────
R=$(new_repo base-policy "$POLICY_SMALL")
printf 'external_review_threshold: 100000\nexternal_review_paths: []\n' > "$R/.github/review-policy.yml"
commit_all "$R" loosen
run_preview "$R"
if [ "$RC" -eq 0 ] && [ "$(jget '[.phase_4.required, .phase_4.threshold, .governing_policy.source]')" = '[true,20,"main:.github/review-policy.yml"]' ]; then
  pass "a branch that loosens review-policy.yml is still judged by the base policy"
else
  fail "base policy governs (rc=$RC out=$OUT)"
fi

# ── 8. Errors ──────────────────────────────────────────────────────────────
run_preview "$R" --bogus
if [ "$RC" -eq 2 ]; then pass "unknown argument exits 2"; else fail "unknown argument (rc=$RC)"; fi
set +e
OUT=$(cd "$R" && bash "$PREVIEW" --base no-such-ref 2>/dev/null); RC=$?
set -e
if [ "$RC" -eq 2 ]; then pass "unresolvable --base exits 2"; else fail "unresolvable --base (rc=$RC)"; fi
R=$(new_repo no-policy "")
rm -f "$R/.github/review-policy.yml"
gitc "$R" checkout -q main
rm -f "$R/.github/review-policy.yml"
commit_all "$R" drop-policy
gitc "$R" checkout -q feature
gitc "$R" rebase -q main
run_preview "$R"
if [ "$RC" -eq 2 ] && printf '%s' "$ERR" | grep -q 'governing policy not found'; then
  pass "a base without review-policy.yml fails closed (exit 2)"
else
  fail "missing base policy (rc=$RC err=$ERR)"
fi

# ── 9. --no-fingerprint contract on the emitter itself ─────────────────────
set +e
err=$(bash "$FINGERPRINT" --no-fingerprint --config "$WORK/under/.github/review-policy.yml" 2>&1 >/dev/null); rc=$?
set -e
if [ "$rc" -eq 2 ] && printf '%s' "$err" | grep -q -- '--no-fingerprint requires --files-json'; then
  pass "--no-fingerprint without --files-json exits 2 (it would otherwise need the API)"
else
  fail "--no-fingerprint without --files-json (rc=$rc err=$err)"
fi
set +e
err=$(bash "$FINGERPRINT" --no-fingerprint --pr x --files-json "$WORK/shape-files.json" --config "$WORK/under/.github/review-policy.yml" 2>&1 >/dev/null); rc=$?
set -e
if [ "$rc" -eq 2 ] && printf '%s' "$err" | grep -q -- '--pr must be an integer'; then
  pass "--no-fingerprint still validates a supplied --pr"
else
  fail "--no-fingerprint --pr validation (rc=$rc err=$err)"
fi
set +e
err=$(bash "$FINGERPRINT" --files-json "$WORK/shape-files.json" --config "$WORK/under/.github/review-policy.yml" 2>&1 >/dev/null); rc=$?
set -e
if [ "$rc" -eq 2 ] && printf '%s' "$err" | grep -q '^usage:'; then
  pass "without --no-fingerprint, --repo/--pr/--ref stay required"
else
  fail "live-mode required args (rc=$rc err=$err)"
fi

# ── No GitHub call, anywhere ───────────────────────────────────────────────
if [ ! -s "$GH_LOG" ]; then
  pass "no gh invocation across every case"
else
  fail "gh was invoked: $(tr '\n' '|' < "$GH_LOG")"
fi

echo
echo "test_review_cost_preview: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
