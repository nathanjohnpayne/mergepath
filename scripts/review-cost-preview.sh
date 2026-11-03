#!/usr/bin/env bash
# scripts/review-cost-preview.sh — pre-PR review cost preview (#1679, part of
# the #816 discretionary-work budget).
#
# Answers, before a PR exists and without one GitHub API call, what the review
# gates will ask of the committed branch: whether Phase 4 external review is
# required and why, whether Phase 4b runs proactively and on which triggers,
# and the lines changed against the threshold.
#
# It decides nothing itself. It synthesizes the PR-files JSON GitHub would
# return for `git diff <merge-base>...HEAD` and feeds it to the two emitters
# through their offline seams:
#
#   scripts/workflow/external_review_fingerprint.sh --no-fingerprint --files-json
#   scripts/phase-4b-classifier.sh --fixture
#
# so the threshold, protected paths and 4b policy are read by the same parsers
# the gates use, from the same governing policy: `.github/review-policy.yml`
# at the base ref, the policy a PR into that base is judged by
# (scripts/workflow/resolve_base_policy.sh). No new threshold parser.
#
# Usage:
#   scripts/review-cost-preview.sh [--base <ref>] [--body-file <path>]
#                                  [--write-files-json <path>]
#
#   --base REF               the branch the PR will target (default: the
#                            remote default branch, refs/remotes/origin/HEAD,
#                            then origin/main, then main). Fetch it first: the
#                            preview reads the local ref and never the API.
#   --body-file PATH         the draft PR body. Two 4b triggers also read the
#                            body (state machine / invariant mentions); without
#                            it they are not evaluated, and the summary says so.
#   --write-files-json PATH  also write the synthesized PR-files JSON there.
#
# Output: JSON on stdout, the same summary lines as plain text on stderr.
#   {
#     "schema": "review-cost-preview:v1",
#     "base": {"ref", "sha", "merge_base"},
#     "head": {"sha", "uncommitted_changes"},
#     "governing_policy": {"source", "blob_sha"},
#     "files_changed": N,
#     "pr_body_supplied": bool,
#     "phase_4": {"required", "lines_changed", "threshold",
#                 "protected_paths", "reasons"},
#     "phase_4b": {"invoked", "recommendation", "match", "triggers",
#                  "rationale", "phase_4b_default"},
#     "external_review_fingerprint": <emitter output, verbatim>,
#     "phase_4b_classifier": <emitter output, verbatim, plus exit_code>,
#     "summary": ["..."]
#   }
#
# `head.sha` is the full SHA of the committed HEAD the preview read, which is
# the head a #1688 acknowledgment binds to. The rest of that binding (the PR
# number and the discretionary budget snapshot) needs GitHub reads and is added
# by #1688, not here.
#
# `phase_4b.invoked` is the proactive route only: Phase 4b triggers apply to
# PRs that already need Phase 4 (REVIEW_POLICY.md § Phase 4b Triggers), so it
# is true only when Phase 4 is required AND the classifier recommends 4b. The
# 4b fallback (Phase 4a unavailable or timed out) cannot be previewed.
#
# Known differences from the live PR, all on the preview's side of the line:
# uncommitted changes are not counted (reported as `head.uncommitted_changes`);
# a diff over GitHub's 3000-file cap counts every file, where the API would
# truncate (requiredness is the same, true either way); and no fingerprint
# hash is computed, because it needs the PR's base SHA from the API.
#
# Exit codes: 0 preview produced (whatever it says), 2 usage or error.

set -euo pipefail

die() { echo "review-cost-preview.sh: $*" >&2; exit 2; }

usage() {
  cat >&2 <<'EOF'
usage: scripts/review-cost-preview.sh [--base <ref>] [--body-file <path>] [--write-files-json <path>]
EOF
  exit 2
}

BASE=""
BODY_FILE=""
FILES_OUT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --base)
      [ $# -ge 2 ] && [ -n "$2" ] || usage
      BASE="$2"; shift 2 ;;
    --body-file)
      [ $# -ge 2 ] && [ -n "$2" ] || usage
      BODY_FILE="$2"; shift 2 ;;
    --write-files-json)
      [ $# -ge 2 ] && [ -n "$2" ] || usage
      FILES_OUT="$2"; shift 2 ;;
    -h|--help) usage ;;
    *) echo "review-cost-preview.sh: unknown arg: $1" >&2; usage ;;
  esac
done

command -v git >/dev/null 2>&1 || die "git is required"
command -v jq >/dev/null 2>&1 || die "jq is required"
if [ -n "$BODY_FILE" ] && [ ! -r "$BODY_FILE" ]; then
  die "--body-file not readable: $BODY_FILE"
fi

# Locate the emitters beside this script, following a PATH symlink the way
# phase-4b-classifier.sh does (bash 3.2: no portable readlink -f).
src="${BASH_SOURCE[0]}"
while [ -L "$src" ]; do
  link_target="$(readlink "$src")"
  case "$link_target" in
    /*) src="$link_target" ;;
    *)  src="$(cd -P "$(dirname "$src")" && pwd)/$link_target" ;;
  esac
done
SCRIPT_DIR="$(cd -P "$(dirname "$src")" && pwd)"
FINGERPRINT="$SCRIPT_DIR/workflow/external_review_fingerprint.sh"
CLASSIFIER="$SCRIPT_DIR/phase-4b-classifier.sh"
[ -r "$FINGERPRINT" ] || die "missing emitter: $FINGERPRINT"
[ -r "$CLASSIFIER" ] || die "missing emitter: $CLASSIFIER"

TOP=$(git rev-parse --show-toplevel 2>/dev/null) || die "not inside a git work tree"

g() { git -C "$TOP" -c core.quotepath=false "$@"; }

if [ -z "$BASE" ]; then
  BASE=$(g symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null || true)
  if [ -z "$BASE" ]; then
    if g rev-parse --verify --quiet "refs/remotes/origin/main^{commit}" >/dev/null; then
      BASE="origin/main"
    elif g rev-parse --verify --quiet "refs/heads/main^{commit}" >/dev/null; then
      BASE="main"
    else
      die "cannot infer the base branch; pass --base <ref>"
    fi
  fi
fi

BASE_SHA=$(g rev-parse --verify --quiet "${BASE}^{commit}") || die "base ref does not resolve to a commit: $BASE"
HEAD_SHA=$(g rev-parse --verify --quiet "HEAD^{commit}") || die "HEAD does not resolve to a commit"
MERGE_BASE=$(g merge-base "$BASE_SHA" "$HEAD_SHA") || die "no merge base between $BASE and HEAD"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/review-cost-preview.XXXXXX") || die "mktemp failed"
trap 'rm -rf "$WORK"' EXIT

g status --porcelain > "$WORK/status.txt" 2>/dev/null || die "git status failed"
UNCOMMITTED=false
if [ -s "$WORK/status.txt" ]; then
  UNCOMMITTED=true
fi

# ── Governing policy: the base ref's own copy ────────────────────────────────
POLICY_REL=".github/review-policy.yml"
POLICY="$WORK/review-policy.yml"
if ! POLICY_BLOB=$(g rev-parse --verify --quiet "${BASE_SHA}:${POLICY_REL}"); then
  die "governing policy not found: ${BASE}:${POLICY_REL}"
fi
g cat-file blob "$POLICY_BLOB" > "$POLICY" || die "cannot read ${BASE}:${POLICY_REL}"

# ── An isolated view of the two commits ─────────────────────────────────────
# Both endpoints are commits, but `git diff` between them still reads local
# state GitHub never sees: user, system and repository config (diff.context,
# diff.algorithm, diff.relative, an external driver, textconv, quoted paths)
# and local attributes (.git/info/attributes, core.attributesFile, an
# uncommitted .gitattributes), any of which can turn a file binary or change
# the patch the classifier scans. So the diffs run in a throwaway bare
# repository that borrows this repository's objects through `alternates` and
# has no config, no work tree and no info/attributes of its own. Attributes
# come only from the committed HEAD tree (attr.tree; a git older than 2.42
# ignores the key and reads none). The options below are pinned on top.
COMMON_DIR=$(cd "$TOP" && cd "$(git rev-parse --git-common-dir)" && pwd -P) \
  || die "cannot locate the git directory"
[ -d "$COMMON_DIR/objects" ] || die "no object directory under $COMMON_DIR"
ISO="$WORK/iso.git"
iso_git() {
  env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE -u GIT_COMMON_DIR \
    -u GIT_OBJECT_DIRECTORY -u GIT_CONFIG -u GIT_CONFIG_PARAMETERS -u GIT_CONFIG_COUNT \
    HOME="$WORK" XDG_CONFIG_HOME="$WORK" GIT_CONFIG_NOSYSTEM=1 \
    GIT_CONFIG_GLOBAL=/dev/null GIT_ATTR_NOSYSTEM=1 GIT_TEMPLATE_DIR="$WORK/no-templates" \
    git "$@"
}
gi() {
  iso_git --git-dir="$ISO" -c core.quotepath=false -c core.attributesFile=/dev/null \
    -c attr.tree="$HEAD_SHA" "$@"
}
mkdir -p "$WORK/no-templates"
iso_git init -q --bare "$ISO" >/dev/null 2>&1 || die "cannot create the isolated diff repository"
mkdir -p "$ISO/objects/info"
printf '%s\n' "$COMMON_DIR/objects" > "$ISO/objects/info/alternates" \
  || die "cannot link the isolated diff repository to $COMMON_DIR/objects"
for sha in "$HEAD_SHA" "$MERGE_BASE"; do
  gi cat-file -e "${sha}^{commit}" 2>/dev/null \
    || die "the isolated diff repository cannot read commit $sha"
done
# --unified is pinned only on the patch call below: it implies -p, which would
# mix patch text into the --raw and --numstat listings.
DIFF_OPTS=(--no-color --no-ext-diff --no-textconv --no-relative --diff-algorithm=myers
  --indent-heuristic -M)

# ── Synthesize the PR-files JSON (gh api repos/O/R/pulls/N/files shape) ──────
# --raw gives the status (and the rename source), --numstat the counts. Both
# walk the same diff queue in the same order; the paths are cross-checked.
# Each listing goes to a file first so a failed diff stops the preview: read
# through a process substitution, its failure would arrive as an empty diff,
# which is the "nothing to review" answer.
gi diff "${DIFF_OPTS[@]}" -z --raw "$MERGE_BASE" "$HEAD_SHA" > "$WORK/raw.z" \
  || die "git diff --raw failed"
gi diff "${DIFF_OPTS[@]}" -z --numstat "$MERGE_BASE" "$HEAD_SHA" > "$WORK/numstat.z" \
  || die "git diff --numstat failed"
RAW_TOKENS=()
while IFS= read -r -d '' tok; do RAW_TOKENS+=("$tok"); done < "$WORK/raw.z"
NUM_TOKENS=()
while IFS= read -r -d '' tok; do NUM_TOKENS+=("$tok"); done < "$WORK/numstat.z"

: > "$WORK/files.jsonl"
ri=0
ni=0
n_raw=${#RAW_TOKENS[@]}
n_num=${#NUM_TOKENS[@]}
while [ "$ri" -lt "$n_raw" ]; do
  meta="${RAW_TOKENS[$ri]}"
  code="${meta##* }"
  letter="${code:0:1}"
  prev=""
  case "$letter" in
    R|C)
      [ $((ri + 2)) -lt "$n_raw" ] || die "truncated --raw rename record"
      prev="${RAW_TOKENS[$((ri + 1))]}"
      path="${RAW_TOKENS[$((ri + 2))]}"
      ri=$((ri + 3)) ;;
    *)
      [ $((ri + 1)) -lt "$n_raw" ] || die "truncated --raw record"
      path="${RAW_TOKENS[$((ri + 1))]}"
      ri=$((ri + 2)) ;;
  esac
  case "$letter" in
    A) status=added ;;
    D) status=removed ;;
    R) status=renamed ;;
    C) status=copied ;;
    T) status=changed ;;
    *) status=modified ;;
  esac

  [ "$ni" -lt "$n_num" ] || die "--numstat ended before --raw (at $path)"
  counts="${NUM_TOKENS[$ni]}"
  adds="${counts%%$'\t'*}"
  rest="${counts#*$'\t'}"
  dels="${rest%%$'\t'*}"
  num_path="${rest#*$'\t'}"
  if [ -z "$num_path" ]; then
    # Rename/copy: "adds<TAB>dels<TAB>" then source and destination tokens.
    [ $((ni + 2)) -lt "$n_num" ] || die "truncated --numstat rename record"
    num_prev="${NUM_TOKENS[$((ni + 1))]}"
    num_path="${NUM_TOKENS[$((ni + 2))]}"
    ni=$((ni + 3))
    [ "$num_prev" = "$prev" ] || die "--raw and --numstat disagree on a rename source: $prev vs $num_prev"
  else
    ni=$((ni + 1))
  fi
  [ "$num_path" = "$path" ] || die "--raw and --numstat disagree: $path vs $num_path"

  # Binary content: GitHub counts it as 0/0 and sends no patch.
  [ "$adds" = "-" ] && adds=0
  [ "$dels" = "-" ] && dels=0
  case "$adds$dels" in *[!0-9]*) die "unparseable --numstat counts for $path" ;; esac

  # GitHub's patch is the hunk text only, from the first @@ line on, with no
  # trailing newline. A binary or content-free (pure rename, mode-only) change
  # has no hunk, and GitHub omits the field. GitHub joins hunks one line
  # closer than git's default, so --inter-hunk-context=1: measured against
  # pulls/N/files for 31 merged mergepath PRs, it matched every patch that
  # 0 and 2 through 5 matched and more. The remaining differences seen were
  # hunk-header function names (GitHub picks its own) and squash-base drift.
  pathspec=(":(literal)$path")
  [ -z "$prev" ] || pathspec+=(":(literal)$prev")
  gi diff "${DIFF_OPTS[@]}" --unified=3 --inter-hunk-context=1 "$MERGE_BASE" "$HEAD_SHA" -- "${pathspec[@]}" \
    | awk 'f || /^@@/ { f = 1; print }' > "$WORK/patch.raw" \
    || die "cannot diff $path"
  printf '%s' "$(cat "$WORK/patch.raw")" > "$WORK/patch.txt"

  jq -n -c \
    --arg filename "$path" \
    --arg status "$status" \
    --argjson additions "$adds" \
    --argjson deletions "$dels" \
    --arg previous "$prev" \
    --rawfile patch "$WORK/patch.txt" \
    '{filename: $filename, status: $status, additions: $additions,
      deletions: $deletions, changes: ($additions + $deletions)}
     + (if $patch == "" then {} else {patch: $patch} end)
     + (if $previous == "" then {} else {previous_filename: $previous} end)' \
    >> "$WORK/files.jsonl" || die "cannot encode the record for $path"
done
[ "$ni" -eq "$n_num" ] || die "--numstat has records --raw does not"

FILES_JSON="$WORK/files.json"
jq -s -c '.' "$WORK/files.jsonl" > "$FILES_JSON" || die "cannot assemble the files JSON"
if [ -n "$FILES_OUT" ]; then
  cp "$FILES_JSON" "$FILES_OUT" || die "cannot write --write-files-json $FILES_OUT"
fi

BODY_SUPPLIED=false
if [ -n "$BODY_FILE" ]; then
  BODY_SUPPLIED=true
  jq -n -c --rawfile body "$BODY_FILE" --slurpfile files "$FILES_JSON" \
    '{body: $body, files: $files[0]}' > "$WORK/classifier-fixture.json" \
    || die "cannot build the classifier fixture"
else
  jq -n -c --slurpfile files "$FILES_JSON" \
    '{body: "", files: $files[0]}' > "$WORK/classifier-fixture.json" \
    || die "cannot build the classifier fixture"
fi

# ── The two emitters, offline ───────────────────────────────────────────────
set +e
FP_OUT=$(bash "$FINGERPRINT" --no-fingerprint --files-json "$FILES_JSON" --config "$POLICY" 2>"$WORK/fp.err")
FP_RC=$?
set -e
if [ "$FP_RC" -ne 0 ] || ! printf '%s' "$FP_OUT" | jq -e 'type == "object"' >/dev/null 2>&1; then
  cat "$WORK/fp.err" >&2
  die "external_review_fingerprint.sh failed (exit $FP_RC)"
fi

# The classifier validates a PR number even on --fixture, where it is unused;
# 1 is a placeholder, not a PR.
set +e
CL_OUT=$(MERGEPATH_REVIEW_POLICY_PATH="$POLICY" bash "$CLASSIFIER" 1 --fixture "$WORK/classifier-fixture.json" 2>"$WORK/cl.err")
CL_RC=$?
set -e
if { [ "$CL_RC" -ne 0 ] && [ "$CL_RC" -ne 1 ]; } || ! printf '%s' "$CL_OUT" | jq -e 'type == "object"' >/dev/null 2>&1; then
  cat "$WORK/cl.err" >&2
  die "phase-4b-classifier.sh failed (exit $CL_RC)"
fi

FILES_COUNT=$(jq 'length' "$FILES_JSON")

RESULT=$(jq -n \
  --arg base_ref "$BASE" \
  --arg base_sha "$BASE_SHA" \
  --arg merge_base "$MERGE_BASE" \
  --arg head_sha "$HEAD_SHA" \
  --argjson uncommitted "$UNCOMMITTED" \
  --arg policy_source "${BASE}:${POLICY_REL}" \
  --arg policy_blob "$POLICY_BLOB" \
  --argjson files "$FILES_COUNT" \
  --argjson body "$BODY_SUPPLIED" \
  --argjson fp "$FP_OUT" \
  --argjson cl "$CL_OUT" \
  --argjson cl_rc "$CL_RC" '
  ($fp.requires_review == true) as $p4
  | ($p4 and $cl.recommendation == "invoke-4b") as $p4b
  | {
      schema: "review-cost-preview:v1",
      base: {ref: $base_ref, sha: $base_sha, merge_base: $merge_base},
      head: {sha: $head_sha, uncommitted_changes: $uncommitted},
      governing_policy: {source: $policy_source, blob_sha: $policy_blob},
      files_changed: $files,
      pr_body_supplied: $body,
      phase_4: {
        required: $p4,
        lines_changed: $fp.lines_changed,
        threshold: $fp.threshold,
        protected_paths: $fp.protected_paths,
        reasons: $fp.reasons
      },
      phase_4b: {
        invoked: $p4b,
        recommendation: $cl.recommendation,
        match: $cl.match,
        triggers: $cl.triggers,
        rationale: $cl.rationale,
        phase_4b_default: $cl.phase_4b_default
      },
      external_review_fingerprint: $fp,
      phase_4b_classifier: ($cl + {exit_code: $cl_rc})
    }
  | .summary = [
      "Review cost preview: \(.base.ref) (\(.base.sha[0:12])) ... HEAD \(.head.sha), \(.files_changed) file(s) changed",
      (if $p4
        then "Phase 4 external review: REQUIRED (\(.phase_4.reasons | join("; ")))"
        else "Phase 4 external review: not required (\(.phase_4.lines_changed) lines < threshold \(.phase_4.threshold); no protected path)"
       end),
      "Lines changed: \(.phase_4.lines_changed) of threshold \(.phase_4.threshold)",
      (if $p4b
        then (if (.phase_4b.triggers | length) > 0
                then "Phase 4b: INVOKED proactively on triggers: \(.phase_4b.triggers | join(", "))"
                else "Phase 4b: INVOKED proactively (\(.phase_4b.rationale))"
              end)
        elif $p4 | not
        then (if .phase_4b.recommendation == "invoke-4b"
                then "Phase 4b: not invoked, Phase 4 is not required (the classifier alone would say invoke-4b: \(.phase_4b.rationale))"
                else "Phase 4b: not invoked, Phase 4 is not required"
              end)
        else "Phase 4b: not invoked proactively (\(.phase_4b.rationale)); it still runs as the fallback if Phase 4a is unavailable"
       end)
    ]
    + (if $p4 then ["External-review fingerprint: not computed offline (it needs the PR base SHA); requiredness above does not depend on it"] else [] end)
    + (if $body then [] else ["PR body not supplied: the body-only 4b triggers (state machine, invariant mentions) were not evaluated; pass --body-file"] end)
    + (if $uncommitted then ["Working tree has uncommitted changes: the preview covers committed HEAD only"] else [] end)
  ') || die "cannot assemble the preview JSON"

printf '%s\n' "$RESULT" | jq -r '.summary[]' >&2
printf '%s\n' "$RESULT"
