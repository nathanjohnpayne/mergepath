#!/usr/bin/env bash
# scripts/workflow/dependabot_pin_bump_exemption.sh
#
# The ONE predicate behind the Dependabot action-pin bump lane
# (nathanjohnpayne/mergepath#2164): decides whether a Dependabot pull request
# may be exempted from the `.github/**` protected-path external-review rule
# because every byte it changes is a provenance-verified GitHub Actions pin
# bump and nothing else.
#
# Why this exists
# ---------------
# `external_review_paths` in .github/review-policy.yml lists `.github/**` so a
# human-authored workflow edit gets a cross-agent Phase 4 review. A Dependabot
# bump of a pinned action (`uses: owner/repo@<sha> # vX.Y.Z`) matches that
# rule too, so the PR is labeled `needs-external-review`, Label Gate fails
# closed, Codex never reviews Dependabot PRs, and the PR waits for a human
# admin override (#2131/#2132/#2133 each sat about 17 hours). The diff in that
# case is a version string and a SHA under a pin comment, produced by a
# GitHub-operated bot whose commits are GitHub-committed and signature
# verified — not the case the protected-path rule exists for.
#
# The proof
# ---------
# Modeled on the propagation-lane exemption in pr-review-policy.yml: exempt on
# PROOF, never on the author login or the file name alone. ALL of these must
# hold, in this order:
#
#   1. The live PR is opened by `dependabot[bot]`, and its live head/base pair
#      equals the pair the caller pinned (`--head`/`--base`), when pinned.
#      This is a precondition, not the proof: anyone with push access can add
#      commits to a Dependabot branch and the PR stays "authored by
#      dependabot[bot]".
#   2. The governing policy (`--config`) does not opt out:
#      `dependabot.pin_bump_exemption.enabled` is absent or `true` — read
#      through the shared structured YAML parser, so flow style and quoted
#      keys count and an unparseable policy is "unknown", never "enabled" —
#      and the diff stays under its `external_review_threshold`: the lane
#      carves out only the protected-path rule, never the size rule.
#   3. Commit provenance: EVERY commit on the PR, the pinned head included, is
#      authored by `dependabot[bot]`, committed by GitHub and
#      signature-verified — the shared predicate in
#      scripts/lib/dependabot-commit-provenance.sh, exactly what
#      dependabot-auto-merge.yml and merge-clearance-gate.sh's Dependabot arm
#      already require.
#   4. Diff shape, from the PR files list (GitHub's own merge-base diff), every
#      file bound to the pinned head through its `contents_url` ref:
#        - every file is `.github/workflows/<name>.yml|.yaml`, status
#          `modified`, no rename, a non-empty `patch`, additions == deletions;
#        - every hunk removes and adds the same number of lines, pairs them in
#          order, and EACH pair is a `uses: owner/repo[/path]@<ref>` line —
#          optionally with a trailing `# vX.Y.Z` pin comment — whose text up
#          to the `@` is byte-identical on both sides. Only the ref after `@`
#          and the pin comment may differ. Any other changed line (a new
#          step, a `with:` value, a `permissions:` block, an end-of-file
#          newline change) fails the proof.
#   5. The live head/base pair is re-read after the proof and must not have
#      moved (no atomic read-to-write guarantee is claimed; callers fence
#      again before any write).
#
# A PR that fails the proof is simply not exempt: it keeps the protected-path
# label and the ordinary Phase 4 path. The lane never consults semver
# (patch/minor/major) — that is dependabot-auto-merge.yml's business — and it
# never loosens the Dependabot reviewer gate in merge-clearance-gate.sh, which
# still requires a reviewer-identity APPROVED on the current head.
#
# Contract
# --------
#   usage: dependabot_pin_bump_exemption.sh --repo owner/repo --pr N
#            [--head <40-hex>] [--base <40-hex>] [--config <review-policy.yml>]
#            [--files-json <path>]
#
#   stdout: one JSON object, on EVERY exit code:
#     {"exempt": bool, "status": "exempt"|"not-exempt"|"unreadable",
#      "reason": "...", "head": "...", "base": "...", "author": "...",
#      "provenance": "...", "files": [{"filename": "...", "pins": N}],
#      "pins": N}
#   rc 0  exempt: the proof holds for the reported head/base pair.
#   rc 1  not exempt: a POSITIVE verdict (not Dependabot-authored, opted out,
#         a non-Dependabot commit, a non-pin hunk, a non-workflow file, ...).
#   rc 2  usage error or a missing trusted helper.
#   rc 3  unreadable: the verdict could not be reached (a failed read, a
#         malformed response, a head/base move, a files payload not bound to
#         the pinned head). Callers fail closed — "could not prove" is never
#         "exempt" — and may retry on a later event.
#
# Trust posture: callers run THIS script from a trusted tree (the PR base, or
# the default branch), never from the PR's own checkout, and it sources its
# two libs from its own tree (`../lib`), so a PR cannot shape the proof that
# judges it. `--files-json` is a cache of the same paginated
# `pulls/{n}/files` read the script would otherwise perform; the
# `contents_url` binding is what proves the cached payload describes the
# pinned head.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO=""
PR_NUMBER=""
PIN_HEAD=""
PIN_BASE=""
CONFIG=""
FILES_JSON_PATH=""

usage() {
  cat >&2 <<'EOF'
usage: dependabot_pin_bump_exemption.sh --repo owner/repo --pr N [--head SHA] [--base SHA] [--config path] [--files-json path]
EOF
  exit 2
}

while [ $# -gt 0 ]; do
  case "$1" in
    --repo)
      [ $# -ge 2 ] || usage
      REPO="$2"; shift 2 ;;
    --pr)
      [ $# -ge 2 ] || usage
      PR_NUMBER="$2"; shift 2 ;;
    --head)
      [ $# -ge 2 ] || usage
      PIN_HEAD="$2"; shift 2 ;;
    --base)
      [ $# -ge 2 ] || usage
      PIN_BASE="$2"; shift 2 ;;
    --config)
      [ $# -ge 2 ] || usage
      CONFIG="$2"; shift 2 ;;
    --files-json)
      [ $# -ge 2 ] || usage
      FILES_JSON_PATH="$2"; shift 2 ;;
    -h|--help)
      usage ;;
    *)
      echo "dependabot_pin_bump_exemption.sh: unknown arg: $1" >&2
      usage ;;
  esac
done

[ -n "$REPO" ] || usage
[ -n "$PR_NUMBER" ] || usage
[[ "$PR_NUMBER" =~ ^[0-9]+$ ]] || { echo "dependabot_pin_bump_exemption.sh: --pr must be an integer" >&2; exit 2; }
if [ -n "$PIN_HEAD" ] && ! [[ "$PIN_HEAD" =~ ^[0-9a-f]{40}$ ]]; then
  echo "dependabot_pin_bump_exemption.sh: --head must be a full lowercase 40-hex sha" >&2
  exit 2
fi
if [ -n "$PIN_BASE" ] && ! [[ "$PIN_BASE" =~ ^[0-9a-f]{40}$ ]]; then
  echo "dependabot_pin_bump_exemption.sh: --base must be a full lowercase 40-hex sha" >&2
  exit 2
fi
if [ -n "$CONFIG" ] && [ ! -f "$CONFIG" ]; then
  echo "dependabot_pin_bump_exemption.sh: config not found: $CONFIG" >&2
  exit 2
fi
command -v jq >/dev/null 2>&1 || { echo "dependabot_pin_bump_exemption.sh: jq is required" >&2; exit 2; }

# Hard-required, not existence-guarded (same posture as
# external_review_fingerprint.sh, #799): the proof is a review exemption, so a
# tree missing either lib must error rather than reach a verdict without it.
for lib in gh-api-array.sh dependabot-commit-provenance.sh feedback-policy-helpers.sh; do
  if [ ! -r "$SCRIPT_DIR/../lib/$lib" ]; then
    echo "dependabot_pin_bump_exemption.sh: missing helper: $SCRIPT_DIR/../lib/$lib" >&2
    exit 2
  fi
done
# shellcheck source=../lib/gh-api-array.sh
. "$SCRIPT_DIR/../lib/gh-api-array.sh"
# shellcheck source=../lib/dependabot-commit-provenance.sh
. "$SCRIPT_DIR/../lib/dependabot-commit-provenance.sh"
# shellcheck source=../lib/feedback-policy-helpers.sh
. "$SCRIPT_DIR/../lib/feedback-policy-helpers.sh"

# Report channel. Every exit path prints one JSON object so a caller can log
# the reason without parsing stderr; the exit code is the verdict.
AUTHOR=""
HEAD=""
BASE=""
PROVENANCE=""
FILES_REPORT='[]'
PINS=0

report() {  # <status> <exempt:true|false> <reason>
  jq -n -c \
    --arg status "$1" --argjson exempt "$2" --arg reason "$3" \
    --arg head "$HEAD" --arg base "$BASE" --arg author "$AUTHOR" \
    --arg provenance "$PROVENANCE" --argjson files "$FILES_REPORT" --argjson pins "$PINS" \
    '{exempt:$exempt, status:$status, reason:$reason, head:$head, base:$base,
      author:$author, provenance:$provenance, files:$files, pins:$pins}'
}
not_exempt() { report not-exempt false "$1"; exit 1; }
unreadable() { report unreadable false "$1"; exit 3; }

# Live PR read: author (precondition), head/base pair (pin + fence). The
# object is validated field by field; a missing or malformed field is an
# unreadable verdict, never a pass.
#
# The result travels on stdout as one tab-separated line — `OK<TAB>login<TAB>
# head<TAB>base` or `ERR<TAB>message` — because this runs inside a command
# substitution, where a global set in the function would be lost with the
# subshell (the swallowed-failure shape scripts/lib/gh-api-array.sh exists to
# remove).
read_live_pr() {
  local raw err rc=0 parsed
  err=$(mktemp "${TMPDIR:-/tmp}/dependabot-pin-bump-err.XXXXXX")
  raw=$(gh api "repos/$REPO/pulls/$PR_NUMBER" 2>"$err") || rc=$?
  if [ "$rc" -ne 0 ]; then
    printf 'ERR\tfailed to read PR %s#%s: %s\n' "$REPO" "$PR_NUMBER" "$(tr '\n' ' ' <"$err")"
    rm -f "$err"
    return 0
  fi
  rm -f "$err"
  parsed=$(printf '%s' "$raw" | jq -r '
    select((.user.login | type) == "string")
    | select((.head.sha | type) == "string" and (.head.sha | test("^[0-9a-f]{40}$")))
    | select((.base.sha | type) == "string" and (.base.sha | test("^[0-9a-f]{40}$")))
    | [.user.login, .head.sha, .base.sha] | @tsv' 2>/dev/null) || parsed=""
  if [ -z "$parsed" ]; then
    printf 'ERR\tPR %s#%s response lacks a string user.login or a 40-hex head.sha/base.sha\n' "$REPO" "$PR_NUMBER"
    return 0
  fi
  printf 'OK\t%s\n' "$parsed"
}

# Split a read_live_pr line into AUTHOR/HEAD/BASE, or fail closed on ERR.
take_live_pr() {  # <line>
  local line=$1 rest
  case "${line%%$'\t'*}" in
    OK) ;;
    *) unreadable "${line#*$'\t'}" ;;
  esac
  rest=${line#*$'\t'}
  AUTHOR=${rest%%$'\t'*}
  rest=${rest#*$'\t'}
  HEAD=${rest%%$'\t'*}
  BASE=${rest#*$'\t'}
  if [ -z "$AUTHOR" ] || [ -z "$HEAD" ] || [ -z "$BASE" ]; then
    unreadable "PR $REPO#$PR_NUMBER response could not be split into author, head and base"
  fi
}

take_live_pr "$(read_live_pr)"

if [ -n "$PIN_HEAD" ] && [ "$HEAD" != "$PIN_HEAD" ]; then
  unreadable "live PR head $HEAD is not the pinned head $PIN_HEAD (the branch moved); re-evaluate on the new head"
fi
if [ -n "$PIN_BASE" ] && [ "$BASE" != "$PIN_BASE" ]; then
  unreadable "live PR base $BASE is not the pinned base $PIN_BASE (the PR was retargeted or its base moved); re-evaluate on the new pair"
fi
# Exact native login, never a prefix test: `app/dependabot` is the GraphQL
# rendering gh pr view uses, and `dependabot-lookalike` must not match. The
# REST pulls endpoint read above renders the bot as `dependabot[bot]`.
if [ "$AUTHOR" != 'dependabot[bot]' ]; then
  not_exempt "PR author is '$AUTHOR', not dependabot[bot]; the action-pin bump lane applies only to Dependabot-opened PRs"
fi

# Governing policy, read from the caller's TRUSTED config (the PR-base policy
# in pr-review-policy.yml and, via resolve_base_policy.sh, in the auto-clear
# workflow) through the ONE structured parser the repo already shares
# (scripts/lib/feedback-policy-helpers.sh policy_yaml_to_json), so block
# style, flow style and quoted keys all resolve. A line-oriented reader
# would miss `"dependabot":` or `dependabot: {pin_bump_exemption: {enabled:
# false}}` and silently default an explicit opt-out to enabled; a policy
# that cannot be parsed at all is therefore "unknown", never "enabled".
#
#   dependabot.pin_bump_exemption.enabled  absent => true; true/false (bare
#                                          or quoted) honored; anything else
#                                          (including explicit null) is unreadable.
#   external_review_threshold              absent => 300; a non-negative
#                                          integer; anything else unreadable.
POLICY_JSON='{}'
if [ -n "$CONFIG" ]; then
  POLICY_JSON=$(policy_yaml_to_json "$CONFIG") || POLICY_JSON=""
  if [ -z "$POLICY_JSON" ] || ! jq -e 'type == "object"' <<<"$POLICY_JSON" >/dev/null 2>&1; then
    unreadable "governing policy $CONFIG could not be parsed as a YAML mapping (no parser available, or malformed); the lane cannot establish its opt-out"
  fi
fi
ENABLED=$(jq -r '
  (try (.dependabot.pin_bump_exemption
    | if . == null then true
      elif has("enabled") then .enabled
      else true end) catch "<malformed>")
  | if . == true or . == "true" then "true"
    elif . == false or . == "false" then "false"
    else "<invalid:" + tostring + ">" end' <<<"$POLICY_JSON")
case "$ENABLED" in
  true) ;;
  false) not_exempt "dependabot.pin_bump_exemption.enabled is false in the governing policy; the lane is opted out" ;;
  *) unreadable "dependabot.pin_bump_exemption.enabled must be true or false; got $ENABLED" ;;
esac
THRESHOLD=$(jq -r '
  (try (.external_review_threshold) catch "<malformed>")
  | if . == null then 300
    elif (type == "number" and . == floor and . >= 0) then .
    elif (type == "string" and test("^[0-9]+$")) then tonumber
    else "<invalid:" + tostring + ">" end' <<<"$POLICY_JSON")
[[ "$THRESHOLD" =~ ^[0-9]+$ ]] || unreadable "external_review_threshold must be a non-negative integer; got $THRESHOLD"

# Commit provenance — the shared predicate. rc 1 is a positive "not
# Dependabot-only" verdict; rc 3 establishes nothing and fails closed.
prov_rc=0
dependabot_commit_provenance "$REPO" "$PR_NUMBER" "$HEAD" || prov_rc=$?
PROVENANCE="$DEPENDABOT_PROVENANCE_REASON"
case "$prov_rc" in
  0) ;;
  1) not_exempt "commit provenance is not Dependabot-only: $DEPENDABOT_PROVENANCE_REASON" ;;
  *) unreadable "commit provenance could not be verified: $DEPENDABOT_PROVENANCE_REASON" ;;
esac

# PR files: GitHub's merge-base diff of the PR. A cached payload is accepted
# only when every entry's contents_url names the pinned head, which is what
# binds the cache to the commit the provenance verdict was reached on.
if [ -n "$FILES_JSON_PATH" ]; then
  [ -f "$FILES_JSON_PATH" ] || unreadable "files JSON not found: $FILES_JSON_PATH"
  FILES_JSON=$(jq -c 'if type == "array" then . else error("files JSON is not an array") end' "$FILES_JSON_PATH" 2>/dev/null) \
    || unreadable "files JSON does not parse as an array: $FILES_JSON_PATH"
else
  # Captured through a file, not `$( )`: gh_api_array reports its failure in
  # globals, which a command substitution's subshell would discard.
  FILES_TMP=$(mktemp "${TMPDIR:-/tmp}/dependabot-pin-bump-files.XXXXXX")
  if ! gh_api_array "repos/$REPO/pulls/$PR_NUMBER/files?per_page=100" "PR files" >"$FILES_TMP"; then
    rm -f "$FILES_TMP"
    unreadable "${GH_API_ARRAY_ERROR:-failed to fetch PR files}"
  fi
  FILES_JSON=$(jq -c '.' "$FILES_TMP") || { rm -f "$FILES_TMP"; unreadable "PR files response does not parse"; }
  rm -f "$FILES_TMP"
fi

FILES_COUNT=$(printf '%s' "$FILES_JSON" | jq 'length')
[ "$FILES_COUNT" -gt 0 ] || not_exempt "PR changes no files"
# The files endpoint stops at 3000 entries; a diff that large cannot be
# enumerated, so it cannot be proven pin-only.
[ "$FILES_COUNT" -lt 3000 ] || not_exempt "PR lists $FILES_COUNT files; the pulls files endpoint stops at 3000, so every hunk cannot be verified"

# The lane carves out ONLY the broad `.github/**` protected-path rule (and
# its `.github/workflows/**` spelling). A consumer that lists a narrower or
# different pattern — a specific workflow such as
# `.github/workflows/deploy.yml`, or `**/*secret*` — has asked for review of
# exactly that file, so any match against such a pattern keeps the label.
# Patterns come from the governing policy and are matched with the same
# slash-aware matcher the labeler uses, over both sides of a rename.
MATCHER="$SCRIPT_DIR/match_protected_paths.sh"
if [ ! -f "$MATCHER" ]; then
  echo "dependabot_pin_bump_exemption.sh: missing helper: $MATCHER" >&2
  exit 2
fi
PATTERNS_JSON=$(jq -c '(try .external_review_paths catch "<malformed>") // []' <<<"$POLICY_JSON")
if ! jq -e 'type == "array" and all(.[]; type == "string")' <<<"$PATTERNS_JSON" >/dev/null 2>&1; then
  unreadable "external_review_paths in $CONFIG is not a list of strings; the lane cannot tell the broad rule from a narrower one"
fi
CHANGED_NAMES=$(printf '%s' "$FILES_JSON" | jq -r '.[] | (.filename // empty), (.previous_filename // empty)')
while IFS= read -r pattern; do
  [ -n "$pattern" ] || continue
  case "$pattern" in
    '.github/**'|'.github/workflows/**') continue ;;
  esac
  match_rc=0
  narrow_match=$(printf '%s\n' "$CHANGED_NAMES" | bash "$MATCHER" "$pattern" 2>/dev/null) || match_rc=$?
  if [ "$match_rc" -ne 0 ]; then
    unreadable "protected path matcher failed (rc=$match_rc); narrower protection cannot be ruled out"
  fi
  narrow_match=${narrow_match%%$'\n'*}
  if [ -n "$narrow_match" ]; then
    not_exempt "file $narrow_match matches protected path pattern '$pattern', which is not the broad .github/** rule the lane carves out; that protection is retained"
  fi
done < <(jq -r '.[]' <<<"$PATTERNS_JSON")

# A diff at or above the governing external_review_threshold needs review for
# its size whatever its shape, so it is not exempt — the same eligibility the
# labeler applies before consulting this helper, enforced here so every caller
# gets it. The count uses the labeler's own exclusion of generated files, read
# from the canonical constant in external_review_fingerprint.sh (same trusted
# kit) rather than a second copy that could drift from it.
FINGERPRINT_HELPER="$SCRIPT_DIR/external_review_fingerprint.sh"
EXCLUDE_RE=$(sed -n "s/^EXCLUDE_RE='\(.*\)'\$/\1/p" "$FINGERPRINT_HELPER" 2>/dev/null | head -1)
if [ -z "$EXCLUDE_RE" ]; then
  echo "dependabot_pin_bump_exemption.sh: cannot read EXCLUDE_RE from $FINGERPRINT_HELPER" >&2
  exit 2
fi
LINES_CHANGED=$(printf '%s' "$FILES_JSON" | jq --arg re "$EXCLUDE_RE" '
  [ .[] | select(((.filename // "") | test($re)) | not) | ((.additions // 0) + (.deletions // 0)) ] | add // 0')
if [ "$LINES_CHANGED" -ge "$THRESHOLD" ]; then
  not_exempt "PR changes $LINES_CHANGED line(s), at or above external_review_threshold $THRESHOLD; the lane carves out only the protected-path rule, not the size threshold"
fi

UNBOUND=$(printf '%s' "$FILES_JSON" | jq -r --arg head "$HEAD" '
  [ .[] | select(((.contents_url // "") | type) != "string"
                 or ((.contents_url // "") | endswith("?ref=" + $head) | not))
    | (.filename // "<unnamed>") ] | first // empty')
if [ -n "$UNBOUND" ]; then
  unreadable "files payload entry '$UNBOUND' is not bound to head $HEAD (contents_url ref mismatch); the payload describes another head"
fi

# Per-file shape. The first offending file names the reason; the proof does
# not continue past it.
SHAPE_FAIL=$(printf '%s' "$FILES_JSON" | jq -r '
  def problem:
    if ((.filename // "") | type) != "string" or (.filename // "") == "" then "has no filename"
    elif (.previous_filename != null) then "is a rename (previous_filename=\(.previous_filename))"
    elif (.status // "") != "modified" then "has status \(.status // "<missing>"), not modified"
    elif ((.filename | test("^\\.github/workflows/[^/]+\\.ya?ml$")) | not) then "is not a .github/workflows/*.yml file"
    elif ((.patch // "") | type) != "string" or (.patch // "") == "" then "has no patch text (binary, too large, or omitted by the API)"
    elif ((.additions // -1) != (.deletions // -2)) then "adds \(.additions // "?") and removes \(.deletions // "?") lines; a pin bump replaces lines one for one"
    elif ((.changes // -1) != ((.additions // 0) + (.deletions // 0))) then "reports changes=\(.changes // "?") inconsistent with additions+deletions"
    else empty end;
  [ .[] | (problem) as $p | select($p != null) | "\(.filename // "<unnamed>") \($p)" ] | first // empty')
[ -z "$SHAPE_FAIL" ] || not_exempt "file $SHAPE_FAIL"

# Hunk-level proof, one awk pass per file. Lines are paired in order within a
# hunk; every pair must be a uses: pin line whose text up to the `@` is
# byte-identical on both sides.
USES_RE='^[[:space:]]*(-[[:space:]]+)?uses:[[:space:]]+[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+(/[A-Za-z0-9_./-]+)?@[A-Za-z0-9_./+-]+([[:space:]]+#[[:space:]]*v?[0-9][A-Za-z0-9_.+-]*)?[[:space:]]*$'

check_patch() {  # stdin: patch text; prints "ok\t<pins>" or "fail\t<reason>"
  awk -v uses_re="$USES_RE" '
    function flush(    i, o, n, po, pn) {
      if (hunk == 0 || bad != "") return
      if (nminus != nplus) { bad = "hunk " hunk " removes " nminus " line(s) but adds " nplus; return }
      if (nminus == 0) { bad = "hunk " hunk " changes no lines"; return }
      for (i = 1; i <= nminus; i++) {
        o = minus[i]; n = plus[i]
        if (o !~ uses_re) { bad = "hunk " hunk " removes a line that is not an action pin: " o; return }
        if (n !~ uses_re) { bad = "hunk " hunk " adds a line that is not an action pin: " n; return }
        po = o; sub(/@.*$/, "", po)
        pn = n; sub(/@.*$/, "", pn)
        if (po != pn) { bad = "hunk " hunk " changes the uses: target, not only its pin: " o " -> " n; return }
        if (o == n) { bad = "hunk " hunk " replaces a pin line with an identical line"; return }
        pins++
      }
      nminus = 0; nplus = 0
    }
    BEGIN { hunk = 0; nminus = 0; nplus = 0; pins = 0; bad = "" }
    bad != "" { next }
    /^@@ / { flush(); hunk++; nminus = 0; nplus = 0; next }
    hunk == 0 { bad = "patch does not start with a hunk header"; next }
    /^-/ { minus[++nminus] = substr($0, 2); next }
    /^\+/ { plus[++nplus] = substr($0, 2); next }
    # Context. GitHub renders a blank context line either as a single space
    # or as an empty string; neither can carry a change, so both are context.
    /^ / || /^$/ { next }
    /^\\/ { bad = "hunk " hunk " changes the end-of-file newline"; next }
    { bad = "unrecognized patch line: " $0 }
    END {
      flush()
      if (hunk == 0 && bad == "") bad = "patch has no hunks"
      if (bad != "") { printf "fail\t%s\n", bad; exit 0 }
      printf "ok\t%d\n", pins
    }'
}

FILES_REPORT='[]'
PINS=0
while IFS=$'\t' read -r filename additions; do
  [ -n "$filename" ] || continue
  verdict=$(printf '%s' "$FILES_JSON" | jq -r --arg f "$filename" 'map(select(.filename == $f)) | first | .patch' | check_patch)
  case "${verdict%%$'\t'*}" in
    ok)
      file_pins=${verdict#*$'\t'}
      if [ "$file_pins" != "$additions" ]; then
        not_exempt "file $filename: $file_pins pin pair(s) in the patch but the API reports $additions changed line(s)"
      fi
      FILES_REPORT=$(jq -c --arg f "$filename" --argjson n "$file_pins" '. + [{filename:$f, pins:$n}]' <<<"$FILES_REPORT")
      PINS=$((PINS + file_pins))
      ;;
    fail)
      not_exempt "file $filename: ${verdict#*$'\t'}"
      ;;
    *)
      unreadable "file $filename: could not evaluate the patch"
      ;;
  esac
done < <(printf '%s' "$FILES_JSON" | jq -r '.[] | [.filename, (.additions | tostring)] | @tsv')

[ "$PINS" -gt 0 ] || not_exempt "PR changes no action pin lines"

# Fence: the pair must still be the pair the proof was reached on.
PROVEN_HEAD="$HEAD"
PROVEN_BASE="$BASE"
take_live_pr "$(read_live_pr)"
if [ "$HEAD" != "$PROVEN_HEAD" ] || [ "$BASE" != "$PROVEN_BASE" ]; then
  unreadable "PR head/base moved from $PROVEN_HEAD/$PROVEN_BASE to $HEAD/$BASE during the proof; re-evaluate on the new pair"
fi

report exempt true "every changed line is a Dependabot action pin bump: $PINS pin(s) across $FILES_COUNT workflow file(s); $PROVENANCE"
exit 0
