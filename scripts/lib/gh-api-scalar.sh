# scripts/lib/gh-api-scalar.sh
#
# `gh_api_scalar` — read ONE scalar field out of the REST API such that an
# UNREADABLE response is distinguishable from an EMPTY one
# (nathanjohnpayne/mergepath#799).
#
# ─────────────────────────────────────────────────────────────────────
# The defect this closes
# ─────────────────────────────────────────────────────────────────────
#
# `gh api <path> --jq <expr>` writes the JSON error body to **stdout** on an
# HTTP failure. Only the human-readable one-liner goes to stderr, and the
# process exits 1. So the shape fifteen call sites used —
#
#     x="$(gh api … --jq '…' 2>/dev/null || true)"
#     [ -z "$x" ] && <handle failure>
#
# — infers failure from EMPTY OUTPUT, and empty output is exactly what a
# failed read does not produce. `$x` holds `{"message":"Not Found",…}`, the
# guard never fires, and the blob travels on as if it were a sha, a login, a
# branch name or a timestamp. Measured against live `gh` while fixing #799:
#
#     $ gh api repos/<owner>/<absent> --jq '.default_branch // "FALLBACK"'
#     {"message":"Not Found","documentation_url":"…","status":"404"}   # stdout
#     gh: Not Found (HTTP 404)                                          # stderr
#     rc: 1
#
# Note the second half of that measurement: `--jq '… // "default"'` does NOT
# protect. `gh` emits the raw error body without running the filter, so the
# `//` alternative never applies. A `--jq` default is not a guard.
#
# ─────────────────────────────────────────────────────────────────────
# The contract — the #831 contract, extended from arrays to scalars
# ─────────────────────────────────────────────────────────────────────
#
# #831 corrected `fetch_api_array` so that a failed read reaches its caller
# ONLY as a return status (3), never as data. This is the same contract for
# the scalar reads, deliberately spelled with the same status so the two do
# not become two parallel notions of failure:
#
#   rc 0  — the response WAS read. The value is on stdout. Empty stdout here
#           means the field is genuinely absent or empty, and a caller may
#           treat it as such.
#   rc 3  — the response could NOT be read (transport failure, HTTP error, or
#           a payload that failed its declared shape). NOTHING is written to
#           stdout; the diagnostic — including gh's error body — goes to
#           stderr.
#
# The invariant that makes emptiness meaningful again is the stdout
# suppression, not the status: a caller that keeps its existing `[ -z "$x" ]`
# guard and nothing else is ALREADY fixed by routing through this helper,
# because a failed read now really does leave `$x` empty. Checking the status
# is still the primary guard and every migrated site does; the suppression is
# what makes the residual emptiness inference honest rather than dead.
#
# ─────────────────────────────────────────────────────────────────────
# --shape: the second line of defence
# ─────────────────────────────────────────────────────────────────────
#
# Status-checking alone assumes gh reports its own failures. The #799 fix in
# #796 added a shape predicate as well (`looks_like_branch_name`), on the
# reasoning that a payload which ever reaches a caller with a ZERO status
# must still read as unresolved. `--shape` builds that in rather than leaving
# it to each call site to remember — the omission is the recurrence mode.
#
# A shape rejection is reported as rc 3 with empty stdout, identical to a
# transport failure, because to the caller they are the same fact: the value
# could not be established.
#
# Sourcing contract: NO top-level side effects, only function defs. No shell
# options are set — a sourced file must not change its caller's `set` state.
# Bash 3.2 portable (no mapfile, no associative arrays, no `${var^^}`).
#
#   source scripts/lib/gh-api-scalar.sh
#   gh_api_scalar [--shape sha|login|timestamp|any] <label> <gh api arg>...
#   looks_like_sha <value>
#   looks_like_login <value>
#   looks_like_timestamp <value>

# Does $1 look like a git object name?
#
# ALL of the discriminating power is in the alphabet, and that is deliberate.
# Every JSON error body gh can leak is excluded by lowercase-hex alone: an
# error body opens with `{` and contains `"`, `:` and a space, none of which
# are hex digits. There is no need for the JSON-specific special cases
# looks_like_branch_name carries, because unlike a branch name a sha has no
# legal punctuation at all.
#
# The length bounds only exclude the empty string and the absurd, and they
# are drawn from git rather than from GitHub's current output:
#   - floor 4, git's own minimum abbreviated object name (`--abbrev` clamps
#     there; shorter is never unique enough for git to print).
#   - ceiling 64, a full SHA-256 object name. Pinning 40 would encode SHA-1
#     as an invariant, and would additionally reject nothing an attacker or
#     an outage can produce — a 41-to-64-character all-hex string is not a
#     failure mode any of the migrated call sites can reach.
# Fixtures across this repo's suites use short hex placeholders (`abc123`,
# `def456`); the floor admits them, which is correct rather than convenient —
# they are legal abbreviated object names and the predicate is not a length
# gate.
#
# Lowercase only: every `.sha` the REST API emits is lowercase, and the two
# call sites that compare against scraped text lowercase it first.
looks_like_sha() {
  local v="$1"
  case "$v" in
    ''|*[!0-9a-f]*) return 1 ;;
  esac
  [ "${#v}" -ge 4 ] || return 1
  [ "${#v}" -le 64 ] || return 1
  return 0
}

# Does $1 look like a GitHub account login?
#
# GitHub's own rule: alphanumerics and single hyphens, no leading or trailing
# hyphen, 39 characters maximum. `[bot]`-suffixed App logins are NOT accepted
# — no migrated call site reads one, and admitting the brackets would widen
# the alphabet for no caller's benefit.
#
# The literal string `null` is rejected explicitly. It is not a possible
# login (a digit-or-letter-only string it may be, but GitHub does not issue
# it) and it IS what `--jq` prints for an absent field, so treating it as a
# value would reintroduce the exact confusion this file exists to remove.
looks_like_login() {
  local v="$1"
  [ -n "$v" ] || return 1
  [ "$v" != "null" ] || return 1
  [ "${#v}" -le 39 ] || return 1
  case "$v" in
    *[!A-Za-z0-9-]*) return 1 ;;
    -*|*-) return 1 ;;
    *--*) return 1 ;;
  esac
  return 0
}

# Does $1 look like the ISO-8601 instant GitHub stamps on API objects?
#
# Exactly `YYYY-MM-DDTHH:MM:SSZ`. Narrow on purpose: the one migrated caller
# compares it as a STRING against other GitHub timestamps, so any format this
# accepts but GitHub does not emit would compare wrongly rather than fail.
# Field ranges are not validated — the point is to reject a JSON blob, not to
# be a calendar.
looks_like_timestamp() {
  local v="$1"
  case "$v" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z) return 0 ;;
  esac
  return 1
}

# Apply a named shape predicate. Unknown names FAIL CLOSED: a typo in a
# `--shape` argument must not silently become "no checking at all".
gh_api_scalar_shape_ok() {  # <shape> <value>
  case "$1" in
    any) return 0 ;;
    sha) looks_like_sha "$2" ;;
    login) looks_like_login "$2" ;;
    timestamp) looks_like_timestamp "$2" ;;
    *) return 1 ;;
  esac
}

# gh_api_scalar [--shape <kind>] <label> <gh api arg>...
#
# <label> is prose for the diagnostic ("PR base sha"), not an endpoint; the
# remaining arguments are passed to `gh api` verbatim, `--jq` included.
gh_api_scalar() {
  local shape=any
  while [ $# -gt 0 ]; do
    case "$1" in
      --shape)
        [ $# -ge 2 ] || { printf '[gh-api-scalar] ERROR: --shape needs a value\n' >&2; return 3; }
        shape="$2"; shift 2 ;;
      *) break ;;
    esac
  done
  if [ $# -lt 2 ]; then
    printf '[gh-api-scalar] ERROR: usage: gh_api_scalar [--shape KIND] <label> <gh api arg>...\n' >&2
    return 3
  fi
  local label="$1"; shift

  # Reject an unknown shape BEFORE spending a request, so the typo surfaces
  # as a usage error rather than as a mysterious unreadable-response report
  # on a response that was read perfectly well.
  case "$shape" in
    any|sha|login|timestamp) ;;
    *) printf '[gh-api-scalar] ERROR: unknown --shape %s (want: any|sha|login|timestamp)\n' "$shape" >&2; return 3 ;;
  esac

  local err_file="" out="" rc=0 detail=""
  # stderr goes to a tmpfile so the human-readable `gh: Not Found (HTTP 404)`
  # line can be quoted in the diagnostic. Falling back to a shared stream
  # when mktemp is unavailable costs the detail, never the verdict — the
  # status check below is what decides, and it is unaffected.
  err_file=$(mktemp "${TMPDIR:-/tmp}/gh-api-scalar-err.XXXXXX" 2>/dev/null) || err_file=""
  if [ -n "$err_file" ]; then
    out=$(gh api "$@" 2>"$err_file") || rc=$?
    detail=$(cat "$err_file" 2>/dev/null || true)
    rm -f "$err_file"
  else
    out=$(gh api "$@" 2>/dev/null) || rc=$?
  fi

  if [ "$rc" -ne 0 ]; then
    # `$out` here is the error BODY, and it is dropped rather than echoed:
    # emitting it is the whole defect. It is reported on stderr instead,
    # where no caller parses it as a value.
    printf '[gh-api-scalar] ERROR: could not read %s (gh rc=%s): %s\n' \
      "$label" "$rc" "$(printf '%s %s' "$detail" "$out" | tr '\n' ' ')" >&2
    return 3
  fi

  if ! gh_api_scalar_shape_ok "$shape" "$out"; then
    printf '[gh-api-scalar] ERROR: %s came back with a value that is not a valid %s; treating it as unread: %s\n' \
      "$label" "$shape" "$(printf '%s' "$out" | tr '\n' ' ')" >&2
    return 3
  fi

  printf '%s' "$out"
}
