# scripts/lib/gh-api-array.sh
#
# `gh_api_array` — the ONE definition of the paginated LIST read every review
# sensing script performs (nathanjohnpayne/mergepath#1008).
#
# ─────────────────────────────────────────────────────────────────────
# Why this file exists
# ─────────────────────────────────────────────────────────────────────
#
# `fetch_api_array` was written out eight times — coderabbit-wait.sh (twice,
# counting the best-effort variant), coderabbit-severity-gate.sh,
# merge-clearance-gate.sh, codex-p1-gate.sh, codex-review-check.sh,
# coderabbit-record-feedback.sh, codex-record-feedback.sh and
# codex-review-request.sh. Every copy ran the same four steps (fetch →
# capture → flatten → hand back), and every correctness fix to those steps
# therefore had to be applied eight times by hand:
#
#   - #831/#965 corrected the FAILURE CONTRACT (a failed read must reach the
#     caller as a status, never as an empty list a caller reads as "no
#     results"). It was patched one helper at a time across four PRs.
#   - #966 corrected the STREAM CAPTURE in codex-review-request.sh, and the
#     other seven copies never received it — see "Reconciled drift" below.
#
# Duplication is what regenerates those findings, and this repo already
# publishes the rule (`docs/agents/code-modification-rules.md`: never
# duplicate logic). The algorithm lives here; each caller keeps only its own
# failure ACTION, which is the part that genuinely differs — `die 2` for the
# two required gates and codex-p1-gate.sh, `die 3` for the checkers and
# recorders, `return 3` for the two poll loops, `return 1` for
# coderabbit-wait.sh's deliberately non-fatal best-effort variant.
#
# ─────────────────────────────────────────────────────────────────────
# The contract — the #831 contract, spelled once
# ─────────────────────────────────────────────────────────────────────
#
#   rc 0  — the response WAS read. A JSON array is on stdout.
#   rc 3  — the response could NOT be read (transport failure, HTTP error, or
#           a pagination stream that would not flatten). NOTHING is written to
#           stdout, so a caller that keeps a residual `[ -z "$x" ]` guard reads
#           emptiness honestly rather than reading an outage as a value.
#
# rc 3 is deliberately the SAME status `scripts/lib/gh-api-scalar.sh` (#799)
# returns for an unreadable scalar, so the two readers do not become two
# parallel notions of failure. Callers that exit with a different code (the
# gates' `die 2`) map it themselves; the lib never picks a caller's exit code.
#
# `gh_api_array` does NOT abort its caller, and cannot: every call site in
# this repo is a command substitution (`VAR=$(fetch_api_array …)`), where an
# `exit` would kill only the subshell and let the assigning statement resume
# with an empty string and status 0 — the swallowed-failure shape #831/#966
# exist to remove. Checking the status at EVERY call site is therefore
# unconditional, and the wrapper each script keeps is where that check lives.
#
# ─────────────────────────────────────────────────────────────────────
# Reporting a failure across a command-substitution boundary
# ─────────────────────────────────────────────────────────────────────
#
# The wrapper needs the diagnostic TEXT so it can phrase the failure in its
# own idiom (`die 2 "$GH_API_ARRAY_ERROR"` / `log "ERROR: $GH_API_ARRAY_ERROR"`),
# and it cannot be returned on stdout — stdout is the data channel, and
# writing to it on failure is the defect. It is therefore handed back in
# globals, which works precisely because the wrapper calls `gh_api_array`
# DIRECTLY (same shell) even though the wrapper itself is invoked inside a
# command substitution: a subshell inherits nothing outward, but a plain
# function call inside that subshell shares its variables.
#
#   GH_API_ARRAY_ERROR       the composed, caller-facing message.
#   GH_API_ARRAY_ERROR_KIND  `fetch`, `flatten` or `shape` — which step
#                            failed, so a caller with more than one message
#                            (the best-effort variant) can keep them all.
#   GH_API_ARRAY_DETAIL      gh's stderr text, or empty. Kept separate so a
#                            caller can compose its own message without
#                            string-surgery on GH_API_ARRAY_ERROR.
#
# All three are reset on entry, so a stale value from an earlier call can
# never be read as this call's diagnostic.
#
# ─────────────────────────────────────────────────────────────────────
# Reconciled drift — where the eight copies disagreed, and which won
# ─────────────────────────────────────────────────────────────────────
#
# 1. STREAM CAPTURE. Seven copies ran `gh api --paginate "$endpoint" 2>&1`,
#    folding stderr into the JSON. codex-review-request.sh captured the two
#    streams separately (#966). The SEPARATED form wins, everywhere.
#
#    `gh api` writes diagnostics to stderr on calls that SUCCEED —
#    deprecation notices, retry/backoff chatter, token-scope warnings — and
#    `2>&1` feeds that prose to the `jq -s` slurp, which then fails and
#    reports a healthy fetch as an unreadable one. That is the same
#    dishonesty #831 is about, pointed the other way: a swallowed failure
#    lies about a bad read, a merged stderr stream lies about a good one.
#    The seven merged copies each carried that false-failure; separating the
#    streams removes it from all of them at once.
#
#    Consequence, stated because it is a real change to the seven: on a
#    FAILED read the message now quotes gh's stderr only, not the HTTP error
#    BODY gh writes to stdout. That is the better half to quote — the body is
#    an unbounded, attacker-influenced payload (`gh-api-scalar.sh` measures it
#    landing on stdout), while the stderr line is gh's own one-line
#    diagnostic. The endpoint LABEL, which is what the regressions assert on,
#    is unchanged in every message.
#
# 2. mktemp FAILURE. codex-review-request.sh returned 3 when it could not
#    allocate the stderr capture file; the other copies had no such path.
#    DEGRADING wins, following `gh-api-scalar.sh`: an unavailable temp dir
#    costs the diagnostic detail, never the verdict. The read itself is
#    unaffected, the status check below is what decides, and turning every
#    read into an infra failure because a temp file could not be made is a
#    self-inflicted stall with nothing gained.
#
# 3. FLATTEN MESSAGE. codex-review-request.sh appended gh's stderr to the
#    flatten diagnostic; the other seven dropped it. The RICHER message wins.
#    It is a strict superset — the suffix appears only when gh actually wrote
#    something — and it prefixes identically, so the existing assertions
#    (which match on `failed to flatten <label> pagination output`) are
#    unaffected.
#
# Nothing else differed. The `jq -s 'add // []'` flatten, the `--paginate`
# invocation, the two failure points and their message wording are carried
# over verbatim.
#
# ─────────────────────────────────────────────────────────────────────
# The third response mode — a 200 that was READ but is not a list (#967)
# ─────────────────────────────────────────────────────────────────────
#
# This is the judgement the extraction commit deliberately left for PR #995,
# and it lands here once instead of in eight copies.
#
# #831 enforced two of the three ways "an ARRAY, or a failure" can break: a
# non-zero `gh` exit, and a stream jq itself rejects. The third is a
# SUCCESSFUL read of a 200 whose body is not a list, and it was passed through
# unexamined, because `add` over a one-element stream returns that element:
#
#     $ printf '{}' | jq -s 'add // []'
#     {}
#
# Nothing downstream is told, and jq's object semantics then decide the
# outcome. `{}` makes every `[ .[] | select(…) ]` evaluate to `[]` — a
# confident "no reviews on this head" / "no blocking comments", the identical
# false negative #831 exists to prevent, reached down a different road. A
# NON-empty object (an error payload such as `{"message":"Bad credentials"}`)
# makes `.[]` yield its string VALUES, `select(.user.login == …)` index a
# string, and jq exit non-zero — which on coderabbit-wait's clearance path
# surfaced as exit 5, `rate_limit_stalled`, mislabelling an infra fault as a
# provider state.
#
# ORDER IS THE WHOLE POINT. Judging the FLATTENED value is too late, because
# `add // []` manufactures the very array it would then be asked to judge: a
# body of the JSON value `null`, an EMPTY body, and a `--paginate` stream of
# only `null`s all reduce to `null` under `add` and are rewritten to `[]` by
# the fallback, after which `type` reports `array` and the caller reads a
# confident zero. A `null` page MIXED with real pages is worse — `add` skips
# it in silence, so a partially unreadable pagination looks complete. The RAW
# stream is therefore judged first: at least one document, and every document
# an array. A genuinely empty page (`[]`) is one array document and still
# passes, which is the distinction a test on the flattened value structurally
# cannot make.
#
# Only the raw-stream judgement exists, and that is deliberate: once every
# document is known to be an array, `add` over a non-empty list of arrays is
# an array, the `// []` fallback cannot fire, and a second assertion on the
# flattened value would be unreachable by construction rather than a
# belt-and-braces check.
#
# An unparseable stream keeps the FLATTEN wording it has always had, because
# it is the same condition the flatten would have reported; the new #967
# message is emitted only when the stream parses and its documents are not
# arrays, so the diagnostic can NAME the shape received.
#
# The array case #936 covers (`[42]`: a real array whose ELEMENTS are not
# comment objects) is a neighbour of this, not the same thing — that one is
# caught by the per-item derive guards, which only run once something has
# already agreed the value is a list.
#
# Sourcing contract: NO top-level side effects, only function definitions. No
# shell options are set — a sourced file must not change its caller's `set`
# state. Bash 3.2 portable (no mapfile, no associative arrays).
#
#   source scripts/lib/gh-api-array.sh
#   gh_api_array <endpoint> <label>

# gh_api_array <endpoint> <label>
#
# <endpoint> is a `gh api` path (`repos/o/r/pulls/1/comments`); <label> is
# prose for the diagnostic ("inline comments"). Reads the endpoint with
# `--paginate`, flattens the resulting document stream to a single JSON
# array, and writes that array to stdout.
#
# shellcheck disable=SC2034  # GH_API_ARRAY_* are the caller-facing report
# channel described above; they are read by the wrapper in each consumer
# script, never inside this file.
gh_api_array() {
  GH_API_ARRAY_ERROR=""
  GH_API_ARRAY_ERROR_KIND=""
  GH_API_ARRAY_DETAIL=""

  if [ $# -lt 2 ]; then
    GH_API_ARRAY_ERROR="usage: gh_api_array <endpoint> <label>"
    GH_API_ARRAY_ERROR_KIND="fetch"
    return 3
  fi
  local endpoint=$1
  local label=$2
  local raw="" errfile="" rc=0

  # `raw=$(…)` on its own would trip errexit before rc could be read; the
  # `|| rc=$?` form captures the status without aborting.
  errfile=$(mktemp "${TMPDIR:-/tmp}/gh-api-array.XXXXXX" 2>/dev/null) || errfile=""
  if [ -n "$errfile" ]; then
    raw=$(gh api --paginate "$endpoint" 2>"$errfile") || rc=$?
    GH_API_ARRAY_DETAIL=$(cat "$errfile" 2>/dev/null) || GH_API_ARRAY_DETAIL=""
    rm -f "$errfile"
  else
    raw=$(gh api --paginate "$endpoint" 2>/dev/null) || rc=$?
  fi

  if [ "$rc" -ne 0 ]; then
    # `$raw` here is the HTTP error BODY and is dropped rather than quoted —
    # see "Reconciled drift" note 1 above.
    GH_API_ARRAY_ERROR="failed to fetch $label: $GH_API_ARRAY_DETAIL"
    GH_API_ARRAY_ERROR_KIND="fetch"
    return 3
  fi

  # #967: judge the RAW stream before the empty-list fallback can manufacture
  # an array out of it — see "The third response mode" above. A probe failure
  # here is a PARSE failure, i.e. exactly what the flatten below would have
  # reported, so it keeps the flatten wording and kind rather than inventing a
  # second name for one condition.
  local shape=""
  shape=$(printf '%s\n' "$raw" | jq -rs 'if length == 0 then "no JSON documents at all"
                                         elif any(.[]; type != "array") then
                                           "a stream of " + ([.[] | type] | unique | join("+")) + " values"
                                         else "array" end' 2>/dev/null) || {
    GH_API_ARRAY_ERROR="failed to flatten $label pagination output${GH_API_ARRAY_DETAIL:+ (gh stderr: $GH_API_ARRAY_DETAIL)}"
    GH_API_ARRAY_ERROR_KIND="flatten"
    return 3
  }
  if [ "$shape" != "array" ]; then
    GH_API_ARRAY_ERROR="$label ($endpoint) came back as $shape, not a stream of JSON arrays — the response was READ but is UNUSABLE as a list, so it is reported as a failed read rather than as an empty result (#967). The empty-list fallback is deliberately NOT applied here: it would turn an unreadable response into a confident zero."
    GH_API_ARRAY_ERROR_KIND="shape"
    return 3
  fi

  # `jq -s` slurps the whole stream before emitting anything, so a parse
  # failure leaves stdout untouched — the rc-3 "nothing on stdout" half of
  # the contract holds without an explicit suppression here.
  printf '%s\n' "$raw" | jq -s 'add // []' 2>/dev/null || {
    GH_API_ARRAY_ERROR="failed to flatten $label pagination output${GH_API_ARRAY_DETAIL:+ (gh stderr: $GH_API_ARRAY_DETAIL)}"
    GH_API_ARRAY_ERROR_KIND="flatten"
    return 3
  }
}
