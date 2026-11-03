#!/usr/bin/env bash
# Backfill `mergepath-route` markers onto issues from the per-repo boards'
# routing fields (nathanjohnpayne/mergepath#2850, part of #2845).
#
# Usage:
#   eval "$(scripts/op-preflight.sh --agent claude --mode review)"
#   GH_TOKEN="$OP_PREFLIGHT_AUTHOR_PAT" \
#     scripts/gh-projects/backfill-route-markers.sh --dry-run [--board N]... [--json FILE]
#   GH_TOKEN="$OP_PREFLIGHT_AUTHOR_PAT" \
#     scripts/gh-projects/backfill-route-markers.sh --live [--board N]... [--json FILE]
#       [--pace SECONDS] [--max-writes N] [--budget-floor N]
#
# Exactly one of --dry-run / --live is required; there is no default mode, so
# a bare invocation never writes. --dry-run makes only GET calls and prints the
# full plan and the per-repository report. --live prints the same, after
# appending the marker to each issue the plan says to write.
#
# What it reads (REST only, GH_TOKEN, which must be able to read the owner's
# Projects v2 boards: the author PAT with `project`):
#   GET users/OWNER/projectsV2                      the boards (all, unless --board)
#   GET users/OWNER/projectsV2/N/fields             the four routing field ids
#   GET users/OWNER/projectsV2/N/items?fields[]=... every item, paginated, with
#       an explicit fields[]=<id> per routing field (without it the endpoint
#       returns only the Title). Each item's repository is its own
#       content.repository, never the board's title.
#   GET repos/OWNER/REPO                            once per repository holding
#       a routed issue (cached), for its `archived` flag.
#
# What it decides, per issue item (open or closed) with any routing field set.
# The marker contract is docs/agents/shared-operating-rules.md § The route
# marker; board option names map to marker values by lowercasing and replacing
# spaces with `-`, and the vocabulary is read from `read-route.sh --vocabulary`
# (its single home), never restated here:
#   would-write      all four fields set and in the vocabulary, and the body
#                    has no marker: append the marker on its own line.
#   already-present  the body's marker equals the board's route.
#   conflict         the body's marker differs (different-marker), is
#                    malformed or out of the vocabulary (malformed-marker), or
#                    is duplicated (duplicated-marker); or two boards hold
#                    different values for the same issue (board-disagreement).
#                    Never overwritten.
#   partial          a model without its effort, the reverse, or only one
#                    provider set. The contract requires both halves, so a
#                    one-provider marker is not legal; nothing is guessed and
#                    nothing is written.
#   out-of-vocabulary  a board option that maps outside the vocabulary.
#                    Reported, never written.
#   unwritable       the appended marker would not parse as the board's route
#                    (for example the body ends inside an unclosed code fence).
#   skipped          pull requests, draft items, size:L parents (by label),
#                    routed issues in an archived repository (read-only, and
#                    out of scope for fleet work: archived-repository), and
#                    items whose issue content is unavailable.
#   no-route         an issue with no routing field set (counted, not listed).
# The already-present and conflict verdicts come from read-route.sh
# --body-file, the one marker parser; the composed body is parsed by it too
# before any write.
#
# Live writes, one at a time, for each would-write in plan order:
#   1. a fresh `GET repos/R/issues/N` immediately before the write; the item is
#      re-checked (still an issue, still not size:L, still no marker) against
#      that fresh body, and anything that changed is reported, not written;
#   2. the new body (fresh body + separator + marker line) through
#      `scripts/gh-as-author.sh -- gh issue edit N --repo R --body-file F`;
#   3. a readback `GET repos/R/issues/N` whose body must equal the written
#      file byte for byte. A failed write or a mismatched readback stops the
#      run (fail closed), so at most one issue is left to inspect by hand;
#   4. a pause of --pace seconds (default 10, about 360 writes an hour, well
#      inside GitHub's content-creation limit of 500 an hour) and a budget
#      check: the run stops before a write when the REST core or GraphQL
#      remaining budget (GET rate_limit, which costs nothing) is under
#      --budget-floor (default 1000). `gh issue edit` spends GraphQL points.
# GitHub's issue update has no compare-and-swap (no If-Match, no expected-body
# input), so an edit landing between step 1 and step 2 would be overwritten:
# the window is one round trip, and whoever runs --live does not edit fleet
# issue bodies meanwhile. The issue's edit history keeps every prior body.
# A second run after the writes finds every marker present and writes nothing.
#
# Exit: 0 the run completed (conflicts, partial routes and skips are report
# lines, not failures, and so is a --max-writes cap); 1 a read failed, or in
# --live a write, readback or budget stop; 2 usage.
#
# Environment:
#   GH_TOKEN             read auth for the boards and issues (required).
#   BACKFILL_AS_AUTHOR   the author wrapper (default scripts/gh-as-author.sh);
#                        a test seam. --dry-run never invokes it.

set -euo pipefail

NAME="backfill-route-markers.sh"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
READ_ROUTE="$ROOT/scripts/gh-projects/read-route.sh"
BACKFILL_AS_AUTHOR="${BACKFILL_AS_AUTHOR:-$ROOT/scripts/gh-as-author.sh}"

usage() {
  echo "usage: $NAME (--dry-run | --live) [--owner LOGIN] [--board N]... [--json FILE]" >&2
  echo "       [--pace SECONDS] [--max-writes N] [--budget-floor N]" >&2
}
die_usage() { echo "$NAME: usage: $1" >&2; usage; exit 2; }
# At most 9 digits: a longer value could overflow `[ -lt ]`, which would then
# fail as "integer expression expected" and silently disable the guard.
is_uint() { case "$1" in ''|*[!0-9]*) return 1 ;; esac; [ "${#1}" -le 9 ]; }

MODE=""
OWNER="nathanjohnpayne"
BOARDS=""
JSON_OUT=""
PACE=10
MAX_WRITES=0
BUDGET_FLOOR=1000
while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --dry-run|--live)
      m="${1#--}"
      [ -z "$MODE" ] || [ "$MODE" = "$m" ] || die_usage "--dry-run and --live are exclusive"
      MODE="$m"; shift
      ;;
    --owner|--board|--json|--pace|--max-writes|--budget-floor)
      [ "$#" -ge 2 ] && [ -n "$2" ] || die_usage "$1 needs a value"
      case "$1" in
        --owner) OWNER="$2" ;;
        --board) is_uint "$2" || die_usage "--board needs a board number, got '$2'"; BOARDS="$BOARDS $2" ;;
        --json) JSON_OUT="$2" ;;
        --pace) is_uint "$2" || die_usage "--pace needs whole seconds, got '$2'"; PACE="$2" ;;
        --max-writes) is_uint "$2" || die_usage "--max-writes needs a count, got '$2'"; MAX_WRITES="$2" ;;
        --budget-floor) is_uint "$2" || die_usage "--budget-floor needs a count, got '$2'"; BUDGET_FLOOR="$2" ;;
      esac
      shift 2
      ;;
    *) die_usage "unknown argument: $1" ;;
  esac
done
[ -n "$MODE" ] || die_usage "pass --dry-run or --live"
case "$OWNER" in ''|*[!A-Za-z0-9-]*) die_usage "--owner must be a GitHub login, got '$OWNER'" ;; esac

command -v gh >/dev/null 2>&1 || { echo "$NAME: gh CLI not on PATH" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "$NAME: jq not on PATH" >&2; exit 1; }
[ -f "$READ_ROUTE" ] || { echo "$NAME: $READ_ROUTE is missing (the marker parser this script reuses)" >&2; exit 1; }
: "${GH_TOKEN:?Set GH_TOKEN from OP_PREFLIGHT_AUTHOR_PAT (it must be able to read the owner Projects v2 boards)}"
if [ "$MODE" = "live" ] && [ ! -x "$BACKFILL_AS_AUTHOR" ]; then
  echo "$NAME: the author wrapper $BACKFILL_AS_AUTHOR is missing or not executable" >&2
  exit 1
fi

if base64 --decode </dev/null >/dev/null 2>&1; then B64D="--decode"; else B64D="-D"; fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/mergepath-backfill-route.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# Reads are pinned to github.com and never fall through to GITHUB_TOKEN.
ghr() (
  unset GITHUB_TOKEN
  GH_HOST=github.com gh "$@"
)

# The vocabulary has one home, read-route.sh.
VOCAB="$(bash "$READ_ROUTE" --vocabulary)"
vocab() { sed -n "s/^$1=//p" <<<"$VOCAB"; }
A_MODELS="$(vocab anthropic.models)"
A_EFFORTS="$(vocab anthropic.efforts)"
O_MODELS="$(vocab openai.models)"
O_EFFORTS="$(vocab openai.efforts)"
for v in "$A_MODELS" "$A_EFFORTS" "$O_MODELS" "$O_EFFORTS"; do
  [ -n "$v" ] || { echo "$NAME: read-route.sh --vocabulary returned an empty list" >&2; exit 1; }
done

# ---------------------------------------------------------------------------
# 1. Boards.
# ---------------------------------------------------------------------------
if ! ghr api --paginate "users/$OWNER/projectsV2?per_page=100" >"$WORK/projects.raw"; then
  echo "$NAME: could not list users/$OWNER/projectsV2 (does GH_TOKEN carry project read access?)" >&2
  exit 1
fi
jq -s '[.[][]] | map({number, title})' "$WORK/projects.raw" >"$WORK/projects.json"
if [ -z "$BOARDS" ]; then
  BOARDS="$(jq -r '.[].number' "$WORK/projects.json" | sort -n | tr '\n' ' ')"
fi
for n in $BOARDS; do
  jq -e --argjson n "$n" 'any(.[]; .number == $n)' "$WORK/projects.json" >/dev/null ||
    { echo "$NAME: board $n is not among users/$OWNER/projectsV2" >&2; exit 1; }
done
[ -n "${BOARDS// /}" ] || { echo "$NAME: users/$OWNER has no Projects v2 boards" >&2; exit 1; }

FIELD_NAMES=("Anthropic model" "Anthropic effort" "OpenAI model" "OpenAI effort")
: >"$WORK/records.jsonl"
: >"$WORK/boards.jsonl"
for n in $BOARDS; do
  title="$(jq -r --argjson n "$n" '.[] | select(.number == $n) | .title' "$WORK/projects.json")"
  if ! ghr api --paginate "users/$OWNER/projectsV2/$n/fields?per_page=100" >"$WORK/fields-$n.raw"; then
    echo "$NAME: could not read the fields of board $n" >&2
    exit 1
  fi
  jq -s '[.[][]]' "$WORK/fields-$n.raw" >"$WORK/fields-$n.json"
  ids=()
  missing=""
  for f in "${FIELD_NAMES[@]}"; do
    id="$(jq -r --arg f "$f" '[.[] | select(.name == $f and .data_type == "single_select") | .id] | if length == 1 then .[0] else "" end' "$WORK/fields-$n.json")"
    if [ -z "$id" ]; then missing="$missing${missing:+, }$f"; else ids+=("$id"); fi
  done
  # Options on the board that map outside the vocabulary, per field.
  notes="$(jq -c --arg sq "'" --arg am "$A_MODELS" --arg ae "$A_EFFORTS" --arg om "$O_MODELS" --arg oe "$O_EFFORTS" '
    def norm: ascii_downcase | gsub(" "; "-");
    def oname: if type == "object" then (.raw // .name // "") else . end;
    {"Anthropic model": $am, "Anthropic effort": $ae, "OpenAI model": $om, "OpenAI effort": $oe} as $v
    | [ .[] | select(.name as $x | $v | has($x)) | .name as $f
        | (.options // [])[] | (.name | oname) as $o
        | select(($v[$f] | split(" ")) | index($o | norm) | not)
        | "field \($sq)\($f)\($sq) has option \($sq)\($o)\($sq) (\($sq)\($o | norm)\($sq)), outside the vocabulary" ]' "$WORK/fields-$n.json")"
  if [ -n "$missing" ]; then
    jq -cn --argjson n "$n" --arg t "$title" --arg m "$missing" --argjson notes "$notes" \
      '{number: $n, title: $t, status: "skipped", reason: ("missing routing field(s): " + $m), items_read: 0, notes: $notes}' >>"$WORK/boards.jsonl"
    continue
  fi
  q="per_page=100&fields[]=${ids[0]}&fields[]=${ids[1]}&fields[]=${ids[2]}&fields[]=${ids[3]}"
  if ! ghr api --paginate "users/$OWNER/projectsV2/$n/items?$q" >"$WORK/items-$n.raw"; then
    echo "$NAME: could not list the items of board $n" >&2
    exit 1
  fi
  jq -c --argjson board "$n" --argjson am "${ids[0]}" --argjson ae "${ids[1]}" --argjson om "${ids[2]}" --argjson oe "${ids[3]}" '
    def fv($id): [(.fields // [])[] | select(.id == $id) | .value
                  | if . == null then null
                    else (.name | if type == "object" then .raw else . end) end][0];
    .[] | {
      board: $board,
      item_id: .id,
      type: (.content_type // "unknown"),
      archived: (.archived_at != null),
      repo: (.content.repository.full_name? // null),
      number: (.content.number? // null),
      state: (.content.state? // null),
      is_pr: ((.content_type == "PullRequest") or ((.content.pull_request? // null) != null)),
      size_l: ([(.content.labels? // [])[] | .name] | index("size:L") != null),
      am: fv($am), ae: fv($ae), om: fv($om), oe: fv($oe),
      body: (.content.body? // ""),
      # A listing that omits the body must not read as an empty body.
      body_present: (((.content | type) == "object") and (.content | has("body")))
    }' "$WORK/items-$n.raw" >"$WORK/items-$n.jsonl"
  cat "$WORK/items-$n.jsonl" >>"$WORK/records.jsonl"
  count="$(wc -l <"$WORK/items-$n.jsonl" | tr -d ' ')"
  jq -cn --argjson n "$n" --arg t "$title" --argjson c "$count" --argjson notes "$notes" \
    --argjson ids "[${ids[0]},${ids[1]},${ids[2]},${ids[3]}]" \
    '{number: $n, title: $t, status: "read", field_ids: $ids, items_read: $c, notes: $notes}' >>"$WORK/boards.jsonl"
done

# ---------------------------------------------------------------------------
# 2. Archived repositories: one `GET repos/OWNER/REPO` per repository that
#    holds a routed issue, cached. An archived repository is read-only (and out
#    of scope for fleet work), so its items are skipped, never written.
# ---------------------------------------------------------------------------
: >"$WORK/archived.jsonl"
jq -r 'select(.type == "Issue" and (.is_pr | not) and .repo != null and .number != null
              and (.am != null or .ae != null or .om != null or .oe != null)) | .repo' \
  "$WORK/records.jsonl" | sort -u >"$WORK/repos.txt"
while IFS= read -r r <&3; do
  if ! a="$(ghr api "repos/$r" --jq '.archived')"; then
    echo "$NAME: could not read repos/$r (needed to tell whether it is archived)" >&2
    exit 1
  fi
  case "$a" in true|false) ;; *) echo "$NAME: repos/$r returned archived='$a', not true or false" >&2; exit 1 ;; esac
  jq -cn --arg r "$r" --argjson a "$a" '{($r): $a}' >>"$WORK/archived.jsonl"
done 3<"$WORK/repos.txt"
jq -s 'add // {}' "$WORK/archived.jsonl" >"$WORK/archived.json"

# ---------------------------------------------------------------------------
# 3. Classify everything that does not depend on the body's marker.
# ---------------------------------------------------------------------------
jq -s -c --slurpfile arch "$WORK/archived.json" --arg am "$A_MODELS" --arg ae "$A_EFFORTS" --arg om "$O_MODELS" --arg oe "$O_EFFORTS" '
  def norm: ascii_downcase | gsub(" "; "-");
  def inv($v; $l): ($l | split(" ") | index($v)) != null;
  def vals: {"Anthropic model": .am, "Anthropic effort": .ae, "OpenAI model": .om, "OpenAI effort": .oe};
  def routed: (.am != null or .ae != null or .om != null or .oe != null);
  def base: {board: .board, boards: [.board], repo, number, state, type, archived,
             board_values: vals, route: null, existing: null, detail: null};
  # Issue rows that hold routing values, grouped by issue: two boards that
  # disagree about one issue are a conflict, never a pick.
  ( [ .[] | select(.type == "Issue" and (.is_pr | not) and .repo != null and .number != null and routed) ]
    | group_by([.repo, .number]) ) as $groups
  | ( .[] | select((.type == "Issue" and (.is_pr | not) and .repo != null and .number != null and routed) | not)
      | base + (
          if .type == "DraftIssue" then {category: "skipped", reason: "draft"}
          elif .is_pr then {category: "skipped", reason: "pull-request"}
          elif .type != "Issue" then {category: "skipped", reason: ("non-issue:" + .type)}
          elif (.repo == null or .number == null) then {category: "skipped", reason: "unreadable"}
          else {category: "no-route", reason: null} end) ),
    ( $groups[]
      | . as $g
      | ($g | map(vals) | unique) as $distinct
      | $g[0] as $r
      | ($r | base) + {boards: ($g | map(.board) | unique)}
      | if ($arch[0][$r.repo] // false) then . + {category: "skipped", reason: "archived-repository"}
        elif ($distinct | length) > 1 then
          . + {category: "conflict", reason: "board-disagreement",
               detail: ($g | map({board, board_values: vals}))}
        elif $r.size_l then . + {category: "skipped", reason: "size-l-parent"}
        else
          ({am: ($r.am // null | if . == null then null else norm end),
            ae: ($r.ae // null | if . == null then null else norm end),
            om: ($r.om // null | if . == null then null else norm end),
            oe: ($r.oe // null | if . == null then null else norm end)}) as $m
          | ([ (if $m.am != null and (inv($m.am; $am) | not) then "Anthropic model=\($r.am)" else empty end),
               (if $m.ae != null and (inv($m.ae; $ae) | not) then "Anthropic effort=\($r.ae)" else empty end),
               (if $m.om != null and (inv($m.om; $om) | not) then "OpenAI model=\($r.om)" else empty end),
               (if $m.oe != null and (inv($m.oe; $oe) | not) then "OpenAI effort=\($r.oe)" else empty end) ]) as $oov
          | ($r | vals | to_entries | map(select(.value == null) | .key)) as $missing
          | if ($oov | length) > 0 then
              . + {category: "out-of-vocabulary", reason: ($oov | join(", ")),
                   detail: (if ($missing | length) > 0 then "also unset: " + ($missing | join(", ")) else null end)}
            elif ($missing | length) > 0 then
              . + {category: "partial", reason: ("unset: " + ($missing | join(", ")))}
            else
              . + {category: "candidate", reason: null,
                   route: "anthropic=\($m.am)/\($m.ae) openai=\($m.om)/\($m.oe)",
                   body_b64: (if $r.body_present then ($r.body | @base64) else null end)}
            end
        end )
' "$WORK/records.jsonl" >"$WORK/classified.jsonl"

# ---------------------------------------------------------------------------
# 4. The marker verdicts, from read-route.sh (the one parser).
# ---------------------------------------------------------------------------
# parse_body <repo> <number> <body-file>: sets P_RC, P_OUT, P_ERR.
parse_body() {
  set +e
  P_OUT="$(bash "$READ_ROUTE" "$2" --repo "$1" --body-file "$3" 2>"$WORK/parse.err")"
  P_RC=$?
  set -e
  P_ERR="$(head -n 1 "$WORK/parse.err")"
}
# compose <body-file> <route> <out-file>: the body plus the marker on its own
# line, separated by one blank line, in the body's own line ending (CRLF when
# the body has any CR, as web-edited bodies do). No trailing newline is added.
compose() {
  local nl=$'\n' last
  if grep -q $'\r' "$1"; then nl=$'\r\n'; fi
  if [ ! -s "$1" ]; then
    printf '%s' "<!-- mergepath-route: $2 -->" >"$3"
    return
  fi
  last="$(tail -c 1 "$1" | od -An -tx1 | tr -d ' \n')"
  if [ "$last" = "0a" ]; then
    { cat "$1"; printf '%s%s' "$nl" "<!-- mergepath-route: $2 -->"; } >"$3"
  else
    { cat "$1"; printf '%s%s%s' "$nl" "$nl" "<!-- mergepath-route: $2 -->"; } >"$3"
  fi
}
# The marker-shaped lines of a body, for the report only (verdicts come from
# read-route.sh): every line mentioning the token, CR stripped.
# awk, not head: head would close the pipe early and, under pipefail, a body
# with many such lines would abort the run on SIGPIPE.
marker_lines() { { grep -F 'mergepath-route' "$1" || true; } | tr -d '\r' | awk 'NR <= 5' | jq -Rsc 'split("\n") | map(select(length > 0))'; }

# judge <repo> <number> <route> <body-file>: sets J_CAT, J_REASON, J_EXISTING.
judge() {
  J_EXISTING="null"
  parse_body "$1" "$2" "$4"
  case "$P_RC" in
    3)
      compose "$4" "$3" "$WORK/composed"
      parse_body "$1" "$2" "$WORK/composed"
      if [ "$P_RC" -eq 0 ] && [ "$P_OUT" = "$3" ]; then
        J_CAT="would-write"; J_REASON=""
      else
        J_CAT="unwritable"; J_REASON="the appended marker would not parse as the route (${P_ERR:-rc $P_RC})"
      fi
      ;;
    0)
      J_EXISTING="$(jq -cn --arg r "$P_OUT" '$r')"
      if [ "$P_OUT" = "$3" ]; then J_CAT="already-present"; J_REASON=""
      else J_CAT="conflict"; J_REASON="different-marker"; fi
      ;;
    4) J_CAT="conflict"; J_REASON="malformed-marker"; J_EXISTING="$(marker_lines "$4")" ;;
    5) J_CAT="conflict"; J_REASON="duplicated-marker"; J_EXISTING="$(marker_lines "$4")" ;;
    *) J_CAT="error"; J_REASON="read-route.sh exit $P_RC: $P_ERR" ;;
  esac
}

jq -c 'select(.category != "candidate")' "$WORK/classified.jsonl" >"$WORK/results.jsonl"
jq -c 'select(.category == "candidate")' "$WORK/classified.jsonl" >"$WORK/candidates.jsonl"
# One line per candidate: repo, number, route, then the body and the row as
# base64 (so neither a tab, a newline nor a backslash in them can shift a field;
# the `b:` prefix keeps an empty body's field from collapsing, since a tab is
# IFS whitespace).
# A body the listing omitted is `missing` and is read from the issue instead.
jq -r '[.repo, (.number | tostring), .route, (if .body_b64 == null then "missing" else "b:" + .body_b64 end), (del(.body_b64) | tojson | @base64)] | join("\t")' \
  "$WORK/candidates.jsonl" >"$WORK/candidates.tsv"
while IFS=$'\t' read -r repo num route b64 row64 <&3; do
  row="$(printf '%s' "$row64" | base64 "$B64D")"
  if [ "$b64" = "missing" ]; then
    if ! ghr api "repos/$repo/issues/$num" >"$WORK/body.json" || ! jq -j '.body // ""' "$WORK/body.json" >"$WORK/body"; then
      jq -c '. + {category: "error", reason: "the listing omitted the body and the issue read failed", existing: null}' \
        <<<"$row" >>"$WORK/results.jsonl"
      continue
    fi
  else
    printf '%s' "${b64#b:}" | base64 "$B64D" >"$WORK/body"
  fi
  judge "$repo" "$num" "$route" "$WORK/body"
  jq -c --arg c "$J_CAT" --arg r "$J_REASON" --argjson e "$J_EXISTING" \
    '. + {category: $c, reason: (if $r == "" then null else $r end), existing: $e}' <<<"$row" >>"$WORK/results.jsonl"
done 3<"$WORK/candidates.tsv"

# ---------------------------------------------------------------------------
# 5. Live writes.
# ---------------------------------------------------------------------------
STOP_REASON=""
CAPPED=0
WRITES=0
if [ "$MODE" = "live" ]; then
  jq -c 'select(.category != "would-write")' "$WORK/results.jsonl" >"$WORK/results.live.jsonl"
  jq -c 'select(.category == "would-write")' "$WORK/results.jsonl" | jq -s -c 'sort_by(.repo, .number) | .[]' >"$WORK/writes.jsonl"
  while IFS= read -r line <&3; do
    if [ -n "$STOP_REASON" ]; then
      jq -c --arg s "$STOP_REASON" '. + {category: "not-written", reason: ("run stopped: " + $s)}' <<<"$line" >>"$WORK/results.live.jsonl"
      continue
    fi
    repo="$(jq -r '.repo' <<<"$line")"
    num="$(jq -r '.number' <<<"$line")"
    route="$(jq -r '.route' <<<"$line")"
    outcome="" ; reason=""
    if [ "$MAX_WRITES" -gt 0 ] && [ "$WRITES" -ge "$MAX_WRITES" ]; then
      STOP_REASON="--max-writes $MAX_WRITES reached"; CAPPED=1
    else
      budget="$(ghr api rate_limit --jq '[.resources.core.remaining, .resources.graphql.remaining] | map(tostring) | join(" ")' 2>/dev/null || echo "")"
      core="${budget%% *}"; gql="${budget##* }"
      if ! is_uint "$core" || ! is_uint "$gql"; then
        STOP_REASON="could not read the rate-limit budget"
      elif [ "$core" -lt "$BUDGET_FLOOR" ] || [ "$gql" -lt "$BUDGET_FLOOR" ]; then
        STOP_REASON="budget under --budget-floor $BUDGET_FLOOR (core $core, graphql $gql)"
      fi
    fi
    if [ -n "$STOP_REASON" ]; then
      jq -c --arg s "$STOP_REASON" '. + {category: "not-written", reason: ("run stopped: " + $s)}' <<<"$line" >>"$WORK/results.live.jsonl"
      continue
    fi
    # 1. Fresh read immediately before the write.
    if ! ghr api "repos/$repo/issues/$num" >"$WORK/fresh.json"; then
      outcome="error"; reason="fresh read failed"; STOP_REASON="fresh read of $repo#$num failed"
    elif ! jq -e '.pull_request == null' "$WORK/fresh.json" >/dev/null; then
      outcome="skipped"; reason="pull-request"
    elif jq -e '[.labels[]?.name] | index("size:L") != null' "$WORK/fresh.json" >/dev/null; then
      outcome="skipped"; reason="size-l-parent"
    else
      jq -j '.body // ""' "$WORK/fresh.json" >"$WORK/fresh.body"
      judge "$repo" "$num" "$route" "$WORK/fresh.body"
      if [ "$J_CAT" != "would-write" ]; then
        outcome="$J_CAT"; reason="changed since the plan: ${J_REASON:-$J_CAT}"
      else
        compose "$WORK/fresh.body" "$route" "$WORK/new.body"
        # 2. The write, through the verified author wrapper.
        if ! "$BACKFILL_AS_AUTHOR" -- gh issue edit "$num" --repo "$repo" --body-file "$WORK/new.body" >"$WORK/write.out" 2>&1; then
          outcome="error"; reason="write failed: $(tail -n 1 "$WORK/write.out")"; STOP_REASON="write to $repo#$num failed"
        # 3. Byte-equality readback.
        elif ! ghr api "repos/$repo/issues/$num" >"$WORK/readback.json"; then
          outcome="error"; reason="readback failed"; STOP_REASON="readback of $repo#$num failed"
        else
          jq -j '.body // ""' "$WORK/readback.json" >"$WORK/readback.body"
          if cmp -s "$WORK/new.body" "$WORK/readback.body"; then
            outcome="written"; WRITES=$((WRITES + 1))
          else
            outcome="error"; reason="readback differs from the written body"; STOP_REASON="readback of $repo#$num differs from the written body"
          fi
        fi
      fi
    fi
    jq -c --arg c "$outcome" --arg r "$reason" '. + {category: $c, reason: (if $r == "" then null else $r end)}' <<<"$line" >>"$WORK/results.live.jsonl"
    # 4. Pace.
    if [ "$outcome" = "written" ] && [ "$PACE" -gt 0 ]; then sleep "$PACE"; fi
  done 3<"$WORK/writes.jsonl"
  mv "$WORK/results.live.jsonl" "$WORK/results.jsonl"
fi

# ---------------------------------------------------------------------------
# 6. Plan and report.
# ---------------------------------------------------------------------------
GENERATED="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
jq -n --arg mode "$MODE" --arg owner "$OWNER" --arg gen "$GENERATED" --arg stop "$STOP_REASON" \
  --slurpfile boards "$WORK/boards.jsonl" --slurpfile results "$WORK/results.jsonl" --slurpfile records <(jq -c '{repo, type}' "$WORK/records.jsonl") '
  def key: (.repo // "(no repository: drafts)");
  ["would-write", "written", "already-present", "conflict", "partial", "out-of-vocabulary", "unwritable", "skipped", "not-written", "error", "no-route"] as $cats
  | ($records | group_by(key) | map({(.[0] | key): length}) | add // {}) as $read
  | ($results | group_by(key)) as $by
  | {generated_at: $gen, mode: $mode, owner: $owner, stopped: (if $stop == "" then null else $stop end),
     boards: $boards,
     repositories: ([$by[] | {repository: (.[0] | key), items_read: ($read[.[0] | key] // 0)}
                     + (reduce $cats[] as $c ({}; . + {($c): 0}))
                     + (group_by(.category) | map({(.[0].category): length}) | add)
                     + {skipped_by_reason: (map(select(.category == "skipped")) | group_by(.reason) | map({(.[0].reason): length}) | add // {})}]
                    | sort_by(.repository)),
     results: ($results | sort_by(.repo // "", .number // 0, .category))}
  | .totals = (reduce .repositories[] as $r ({items_read: 0}; reduce ($cats[], "items_read") as $c (.; .[$c] = ((.[$c] // 0) + ($r[$c] // 0)))))
' >"$WORK/report.json"

if [ -n "$JSON_OUT" ]; then cp "$WORK/report.json" "$JSON_OUT"; fi

jq -r '
  def v: .board_values | "Anthropic model=\(.["Anthropic model"] // "-"), Anthropic effort=\(.["Anthropic effort"] // "-"), OpenAI model=\(.["OpenAI model"] // "-"), OpenAI effort=\(.["OpenAI effort"] // "-")";
  def who: "\(.repo // "(draft)")#\(.number // "-") [\(.state // "-")] board \(.boards | map(tostring) | join(","))";
  "\(env.NAME // "backfill-route-markers.sh"): mode=\(.mode) owner=\(.owner) generated=\(.generated_at)",
  (if .stopped then "STOPPED: \(.stopped)" else empty end),
  "",
  "BOARDS",
  (.boards[] | "  board \(.number) \"\(.title)\": \(.status)\(if .reason then " (" + .reason + ")" else "" end), items read \(.items_read)"
     + (if (.notes | length) > 0 then "\n" + (.notes | map("    note: " + .) | join("\n")) else "" end)),
  "",
  "PLAN (every item that is not no-route)",
  (.results[] | select(.category != "no-route")
     | "  \(.category)\(if .reason then " (" + .reason + ")" else "" end)  \(who)"
       + (if .route then "  route: " + .route else "" end)
       + (if .type == "Issue" and .category != "would-write" and .category != "written" and .category != "already-present" then "\n      board: " + v else "" end)
       + (if .existing != null then "\n      existing: " + (.existing | if type == "array" then join(" | ") else tostring end) else "" end)
       + (if .detail != null then "\n      detail: " + (.detail | if type == "string" then . else tojson end) else "" end)),
  "",
  "REPORT (per repository)",
  "  repository | items read | would-write | written | already present | conflicts | partial | out-of-vocabulary | unwritable | skipped (by reason) | not written | errors | no route",
  (.repositories[], (.totals + {repository: "TOTAL", skipped_by_reason: null})
     | "  \(.repository) | \(.items_read) | \(.["would-write"]) | \(.written) | \(.["already-present"]) | \(.conflict) | \(.partial) | \(.["out-of-vocabulary"]) | \(.unwritable) | \(.skipped)\(if (.skipped_by_reason // {}) != {} then " (" + (.skipped_by_reason | to_entries | map("\(.key) \(.value)") | join(", ")) + ")" else "" end) | \(.["not-written"]) | \(.error) | \(.["no-route"])")
' "$WORK/report.json"

# A --max-writes cap is a planned partial run, not a failure; any other stop is.
if { [ -n "$STOP_REASON" ] && [ "$CAPPED" = "0" ]; } || jq -e '.totals.error > 0' "$WORK/report.json" >/dev/null; then
  exit 1
fi
exit 0
