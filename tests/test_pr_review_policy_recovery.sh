#!/usr/bin/env bash
# tests/test_pr_review_policy_recovery.sh
#
# Unit tests for scripts/pr-review-policy-recovery.sh — the recovery lane for
# the two required contexts pr-review-policy.yml reports
# (nathanjohnpayne/mergepath#931).
#
# Strategy: PATH-shim `gh` so the script's REST reads return canned payloads
# and every write is recorded instead of sent. The shim APPLIES the `--jq`
# expression the script passes, so the real jq filters are under test rather
# than stubbed out. Same shape as the PATH-shimmed gh in
# tests/test_codex_p1_gate.sh. The Phase 4 derivation is a separate process,
# stubbed through PR_REVIEW_POLICY_RECOVERY_DERIVE_BIN.
#
# Cases covered:
#   1.  No open PRs → exit 0, no write.
#   2.  Context absent on the head → PUBLISHED, stamped with the lane's
#       external_id (the recovery guarantee).
#   3.  Context already reported by the NATIVE job run (a UUID external_id) →
#       NOT published: the lane must not open a second lineage on a healthy
#       head.
#   4.  Context previously published by THIS lane → re-published (refresh), so
#       a stale recovery verdict cannot outlive the state it was derived from.
#   5.  Self-Review: no `## Self-Review` → failure; 5b with one → success;
#       5c a heading inside a fenced code block does not count (routed through
#       scripts/validate-pr-body.sh, not a grep).
#   6.  Label Gate: a blocking label → failure naming it; 6b none → success;
#       6c a non-blocking label → success.
#   7.  Dependabot PR → Self-Review published as `skipped`.
#   8.  The head moves between evaluation and publication → nothing published.
#   9.  The check-runs read fails → nothing published for that context, exit 1.
#   10. The open-PR list read fails → exit 1 and no write at all.
#   11. A PR-detail read fails → that PR is skipped, exit 1, others still swept;
#       11b a head that is not a git object name → nothing published.
#   12. The sweep never issues a mutating call other than the check-run POST.
#
# #1240 Codex round 1:
#   13. Two open PRs share a head → BOTH contexts red on it, neither PR's
#       verdict published; 13b the clean PR's own verdict never appears.
#   14. The check runs for a (head, context) change between the decision and
#       the POST → the now-stale verdict is withheld (the compare-and-swap
#       fence; a label change moves no head SHA, so the head re-read alone
#       cannot catch this).
#   15. Phase 4 applies and no blocking label is present → Label Gate FAILS.
#       The classifier that applies `needs-external-review` runs in the same
#       workflow run as the gate, so in the recovery case the absent label is
#       a symptom of the missing event, not a clearance.
#   16. The Phase 4 derivation exits nonzero → Label Gate red + exit 1;
#       16b it prints something other than true/false → same.
#   17. The label list is read LATE, not from the PR-detail snapshot: a label
#       added after that read still blocks.
#
# Bash 3.2 portable.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/scripts/pr-review-policy-recovery.sh"

[ -x "$SCRIPT" ] || { echo "missing or non-executable $SCRIPT" >&2; exit 1; }

for tool in jq node; do
  command -v "$tool" >/dev/null 2>&1 || {
    echo "FAIL: $tool is required to run this suite (the recovery lane and the PR-body validator both need it)" >&2
    exit 1
  }
done

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/pr-review-policy-recovery-test.XXXXXX")"
trap 'rm -rf "$WORKDIR"' EXIT

PASS=0
FAIL=0
pass() { echo "PASS: $*"; PASS=$((PASS + 1)); }
fail() {
  echo "FAIL: $*" >&2
  # The sweep's own log is the first thing anyone debugging a failure wants,
  # and it is the reason $OUT is captured at all.
  if [ -n "${OUT:-}" ]; then
    printf '  last sweep output:\n' >&2
    printf '%s\n' "$OUT" | sed 's/^/    /' >&2
  fi
  FAIL=$((FAIL + 1))
}

REPO="acme/widget"
RECOVERY_ID="mergepath-pr-review-policy-recovery"

# ---------------------------------------------------------------------------
# PATH-shim `gh`.
#
# It parses the same flags gh accepts, applies `--jq` with real jq, and routes
# by endpoint. Writes are appended to $GH_WRITES instead of being sent, so a
# test can assert both what WAS published and that nothing else was.
# ---------------------------------------------------------------------------
STUB_DIR="$WORKDIR/stub-bin"
mkdir -p "$STUB_DIR"

cat >"$STUB_DIR/gh" <<'STUB'
#!/usr/bin/env bash
LOG="${GH_CALLS_LOG:-/dev/null}"
{
  printf 'gh'
  for a in "$@"; do printf '\t%s' "$a"; done
  printf '\n'
} >> "$LOG"

[ "${1:-}" = "api" ] || { echo "gh-stub: unexpected subcommand ${1:-}" >&2; exit 1; }
shift

method="GET"
jqexpr=""
endpoint=""
fields=""
while [ $# -gt 0 ]; do
  case "$1" in
    --paginate) shift ;;
    -X|--method) method="$2"; shift 2 ;;
    --jq) jqexpr="$2"; shift 2 ;;
    -f|-F) fields="$fields
$2"; shift 2 ;;
    *) [ -n "$endpoint" ] || endpoint="$1"; shift ;;
  esac
done

emit() {  # <file>
  if [ -n "$jqexpr" ]; then
    jq -r "$jqexpr" < "$1"
  else
    cat "$1"
  fi
}

case "$method:$endpoint" in
  POST:*check-runs)
    {
      printf 'POST check-runs'
      printf '%s' "$fields" | while IFS= read -r f; do
        [ -n "$f" ] && printf '\t%s' "$f"
      done
      printf '\n'
    } >> "${GH_WRITES:-/dev/null}"
    printf '{"id":1}\n'
    exit 0
    ;;
esac

case "$endpoint" in
  *"/pulls?state=open"*)
    [ -z "${FAIL_OPEN_PRS:-}" ] || { echo "gh: HTTP 502 (pulls list)" >&2; printf '{"message":"Bad gateway"}\n'; exit 1; }
    emit "${FIXTURE_OPEN_PRS:?FIXTURE_OPEN_PRS unset}"
    exit 0
    ;;
  *"/check-runs?check_name="*)
    name="self-review"
    case "$endpoint" in
      *"check_name=Label%20Gate"*) name="label-gate" ;;
    esac
    sha="${endpoint#*/commits/}"
    sha="${sha%%/check-runs*}"
    # Fixture lookups are keyed by sha, and a sha the script passes through
    # need not be a valid shell identifier. Normalise before the indirect
    # expansion so the STUB cannot fail on an input the production script
    # handles — a stub crash would look exactly like the guard under test.
    sha=$(printf '%s' "$sha" | tr -c 'A-Za-z0-9' '_')
    slug="${name//-/_}"
    fail_var="FAIL_CHECKRUNS_${slug}"
    [ -z "${!fail_var:-}" ] || { echo "gh: HTTP 502 (check-runs)" >&2; printf '{"message":"Bad gateway"}\n'; exit 1; }

    # Call counter per (context, sha). The recovery lane reads this listing
    # TWICE per publication — once to decide, once as the compare-and-swap
    # fence immediately before the POST — so a FIXTURE_CHECKRUNS2_* fixture
    # lets a test model the state changing in between.
    counter="${GH_STUB_COUNTER_DIR:?GH_STUB_COUNTER_DIR unset}/${slug}_${sha}"
    n=0
    [ -f "$counter" ] && n=$(cat "$counter")
    n=$((n + 1))
    printf '%s' "$n" > "$counter"

    # FAIL_CHECKRUNS_AT_<slug>=<n> fails ONLY the nth read. A blanket failure
    # breaks both reads at once and the surviving one masks the other: the
    # decision read and the compare-and-swap read have separate fail-closed
    # branches, and each has to be provable on its own.
    at_var="FAIL_CHECKRUNS_AT_${slug}"
    if [ "${!at_var:-}" = "$n" ]; then
      echo "gh: HTTP 502 (check-runs read #$n)" >&2
      printf '{"message":"Bad gateway"}\n'
      exit 1
    fi

    src=""
    if [ "$n" -ge 2 ]; then
      second="FIXTURE_CHECKRUNS2_${slug}_${sha}"
      src="${!second:-}"
    fi
    if [ -z "$src" ]; then
      f="FIXTURE_CHECKRUNS_${slug}_${sha}"
      src="${!f:-}"
    fi
    [ -n "$src" ] || src="$GH_STUB_EMPTY_CHECKRUNS"
    emit "$src"
    exit 0
    ;;
  */pulls/*)
    pr="${endpoint##*/pulls/}"
    fail_var="FAIL_PR_${pr}"
    [ -z "${!fail_var:-}" ] || { echo "gh: HTTP 502 (pull detail)" >&2; printf '{"message":"Bad gateway"}\n'; exit 1; }
    # The live-head re-read is the only call that asks for .head.sha alone;
    # LIVE_HEAD_<pr> lets a test move the head between evaluation and publish.
    if [ "$jqexpr" = ".head.sha" ]; then
      live_var="LIVE_HEAD_${pr}"
      if [ -n "${!live_var:-}" ]; then
        printf '%s\n' "${!live_var}"
        exit 0
      fi
    fi
    # The LABEL read is a distinct, later call than the detail read.
    # FIXTURE_LATE_LABELS_<pr> answers only that one, so a test can prove the
    # labels are not taken from the earlier snapshot.
    if [ "$jqexpr" = '(.labels // [])[].name' ]; then
      late_var="FIXTURE_LATE_LABELS_${pr}"
      if [ -n "${!late_var:-}" ]; then
        emit "${!late_var}"
        exit 0
      fi
    fi
    f="FIXTURE_PR_${pr}"
    emit "${!f:?FIXTURE_PR_${pr} unset}"
    exit 0
    ;;
esac

echo "gh-stub: unrouted endpoint '$endpoint'" >&2
exit 1
STUB
chmod +x "$STUB_DIR/gh"

GH_STUB_EMPTY_CHECKRUNS="$WORKDIR/check-runs-empty.json"
printf '{"total_count":0,"check_runs":[]}\n' > "$GH_STUB_EMPTY_CHECKRUNS"
export GH_STUB_EMPTY_CHECKRUNS

# ---------------------------------------------------------------------------
# Phase 4 derivation stub. The real derivation is
# scripts/merge-clearance-gate.sh --derive-phase-4-requiredness, a separate
# process with its own API surface; the lane's contract with it is exactly
# "prints true or false on exit 0, anything else is fail-closed", which is
# what this models. scripts/ci/check_pr_review_policy_recovery asserts the
# production default still resolves to that script and flag.
# ---------------------------------------------------------------------------
DERIVE_STUB="$WORKDIR/derive-stub.sh"
cat >"$DERIVE_STUB" <<'DERIVE'
#!/usr/bin/env bash
printf '%s\tphase4\t%s\n' "derive" "$*" >> "${GH_CALLS_LOG:-/dev/null}"
# Flag-strict on purpose. --derive-external-requiredness answers a DIFFERENT
# question — it folds in whether the optional merge gate is enabled, which is
# off by default on consumers — so a lane that asked it would read "no Phase 4
# gate is enforced here" as "Phase 4 does not apply" and green the very PRs
# this fence exists to hold. Anything but the exact query is unanswerable.
if [ "${1:-}" != "--derive-phase-4-requiredness" ]; then
  echo "derive-stub: refusing unexpected query '${1:-}'" >&2
  exit 3
fi
case "${DERIVE_MODE:-false}" in
  fail) echo "derive: boom" >&2; exit 2 ;;
  garbage) printf 'maybe\n'; exit 0 ;;
  true) printf 'true\n' ;;
  *) printf 'false\n' ;;
esac
DERIVE
chmod +x "$DERIVE_STUB"
export PR_REVIEW_POLICY_RECOVERY_DERIVE_BIN="$DERIVE_STUB"

# ---------------------------------------------------------------------------
# Fixture builders.
# ---------------------------------------------------------------------------
HEAD_A="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
HEAD_B="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

write_pr() {  # <number> <head> <author> <body> <label>...
  local number="$1" head="$2" author="$3" body="$4"; shift 4
  local labels_json="[]"
  if [ $# -gt 0 ]; then
    labels_json=$(printf '%s\n' "$@" | jq -R . | jq -s 'map({name: .})')
  fi
  jq -n --argjson number "$number" --arg head "$head" --arg author "$author" \
    --arg body "$body" --argjson labels "$labels_json" \
    '{number: $number, head: {sha: $head}, user: {login: $author}, body: $body, labels: $labels}' \
    > "$WORKDIR/pr-$number.json"
  eval "export FIXTURE_PR_$number=\"\$WORKDIR/pr-$number.json\""
}

# write_open_prs <number>:<head> ... — the listing the sweep enumerates.
write_open_prs() {
  if [ $# -eq 0 ]; then
    printf '[]\n' > "$WORKDIR/open-prs.json"
  else
    local entry
    : > "$WORKDIR/open-prs.raw"
    for entry in "$@"; do
      jq -n --argjson n "${entry%%:*}" --arg h "${entry#*:}" \
        '{number: $n, head: {sha: $h}}' >> "$WORKDIR/open-prs.raw"
    done
    jq -s . "$WORKDIR/open-prs.raw" > "$WORKDIR/open-prs.json"
  fi
  export FIXTURE_OPEN_PRS="$WORKDIR/open-prs.json"
}

_checkruns_file() {  # <path> <external_id>...
  local path="$1"; shift
  printf '%s\n' "$@" | jq -R . \
    | jq -s 'to_entries | map({id: (.key + 100), external_id: .value}) | {total_count: length, check_runs: .}' \
    > "$path"
}

write_check_runs() {  # <context-slug> <sha> <external_id>...
  local slug="$1" sha="$2"; shift 2
  local key path
  key=$(printf '%s' "$sha" | tr -c 'A-Za-z0-9' '_')
  path="$WORKDIR/check-runs-$slug-$key.json"
  _checkruns_file "$path" "$@"
  eval "export FIXTURE_CHECKRUNS_${slug//-/_}_${key}=\"\$path\""
}

# The listing served from the SECOND read onward — the compare-and-swap fence.
write_check_runs_second() {  # <context-slug> <sha> <external_id>...
  local slug="$1" sha="$2"; shift 2
  local key path
  key=$(printf '%s' "$sha" | tr -c 'A-Za-z0-9' '_')
  path="$WORKDIR/check-runs2-$slug-$key.json"
  _checkruns_file "$path" "$@"
  eval "export FIXTURE_CHECKRUNS2_${slug//-/_}_${key}=\"\$path\""
}

write_late_labels() {  # <pr> <label>...
  local pr="$1"; shift
  local path="$WORKDIR/late-labels-$pr.json"
  if [ $# -eq 0 ]; then
    printf '{"labels":[]}\n' > "$path"
  else
    printf '%s\n' "$@" | jq -R . | jq -s '{labels: map({name: .})}' > "$path"
  fi
  eval "export FIXTURE_LATE_LABELS_$pr=\"\$path\""
}

SELF_REVIEW_BODY='Authoring-Agent: claude

Closes #1.

## Self-Review

- [x] Correctness'

NO_SELF_REVIEW_BODY='Authoring-Agent: claude

Closes #1. No self review here.'

FENCED_SELF_REVIEW_BODY='Authoring-Agent: claude

```
## Self-Review
```
'

reset_env() {
  local v
  for v in $(env | sed -n 's/^\(FIXTURE_[A-Za-z0-9_]*\)=.*/\1/p'); do unset "$v"; done
  for v in $(env | sed -n 's/^\(FAIL_[A-Za-z0-9_]*\)=.*/\1/p'); do unset "$v"; done
  for v in $(env | sed -n 's/^\(LIVE_HEAD_[A-Za-z0-9_]*\)=.*/\1/p'); do unset "$v"; done
  unset DERIVE_MODE || true
  export GH_STUB_EMPTY_CHECKRUNS
}

# run_sweep — invoke the script with the shim on PATH. Sets RC, OUT, WRITES.
run_sweep() {
  GH_WRITES="$WORKDIR/writes.log"
  GH_CALLS_LOG="$WORKDIR/calls.log"
  GH_STUB_COUNTER_DIR="$WORKDIR/counters"
  rm -rf "$GH_STUB_COUNTER_DIR"
  mkdir -p "$GH_STUB_COUNTER_DIR"
  : > "$GH_WRITES"
  : > "$GH_CALLS_LOG"
  export GH_WRITES GH_CALLS_LOG GH_STUB_COUNTER_DIR
  RC=0
  OUT=$(PATH="$STUB_DIR:$PATH" "$SCRIPT" "$REPO" 2>&1) || RC=$?
  WRITES=$(cat "$GH_WRITES")
}

published_conclusion() {  # <context> — prints the conclusion(s) published for it
  printf '%s\n' "$WRITES" | awk -v ctx="name=$1" '
    index($0, ctx) {
      for (i = 1; i <= NF; i++) if ($i ~ /^conclusion=/) { sub(/^conclusion=/, "", $i); print $i }
    }' FS='\t'
}

published_field() {  # <context> <field>
  printf '%s\n' "$WRITES" | awk -v ctx="name=$1" -v key="$2=" '
    index($0, ctx) {
      for (i = 1; i <= NF; i++) if (index($i, key) == 1) { print substr($i, length(key) + 1) }
    }' FS='\t'
}

uniq_conclusions() {  # <context>
  published_conclusion "$1" | sort -u | tr '\n' ',' | sed 's/,$//'
}

# ---------------------------------------------------------------------------
# 1. No open PRs → clean no-op.
# ---------------------------------------------------------------------------
reset_env
write_open_prs
run_sweep
if [ "$RC" -eq 0 ] && [ -z "$WRITES" ]; then
  pass "no open PRs → exit 0 and no write"
else
  fail "no open PRs must be a clean no-op (rc=$RC, writes=[$WRITES])"
fi

# ---------------------------------------------------------------------------
# 2. Both contexts absent on the head → both published, stamped as recovery.
# 5.  Self-Review failure on a body with no section.
# 6b. Label Gate success with no labels (Phase 4 does not apply).
# ---------------------------------------------------------------------------
reset_env
write_open_prs "7:$HEAD_A"
write_pr 7 "$HEAD_A" "someone" "$NO_SELF_REVIEW_BODY"
run_sweep
if [ "$RC" -eq 0 ] \
  && [ "$(published_conclusion 'Self-Review Required')" = "failure" ] \
  && [ "$(published_conclusion 'Label Gate')" = "success" ] \
  && [ "$(published_field 'Self-Review Required' external_id)" = "$RECOVERY_ID" ] \
  && [ "$(published_field 'Label Gate' head_sha)" = "$HEAD_A" ]; then
  pass "absent contexts are published on the PR head, stamped with the recovery external_id"
else
  fail "an absent context must be recovered (rc=$RC, writes=[$WRITES])"
fi

# ---------------------------------------------------------------------------
# 5b. A body carrying a real `## Self-Review` → success.
# ---------------------------------------------------------------------------
reset_env
write_open_prs "7:$HEAD_A"
write_pr 7 "$HEAD_A" "someone" "$SELF_REVIEW_BODY"
run_sweep
if [ "$(published_conclusion 'Self-Review Required')" = "success" ]; then
  pass "a body with a Self-Review section publishes success"
else
  fail "a body with a Self-Review section must publish success (writes=[$WRITES])"
fi

# ---------------------------------------------------------------------------
# 5c. A heading inside a fenced code block does not satisfy the contract.
# ---------------------------------------------------------------------------
reset_env
write_open_prs "7:$HEAD_A"
write_pr 7 "$HEAD_A" "someone" "$FENCED_SELF_REVIEW_BODY"
run_sweep
if [ "$(published_conclusion 'Self-Review Required')" = "failure" ]; then
  pass "a fenced Self-Review heading does not satisfy the recovered context"
else
  fail "a fenced heading must not satisfy Self-Review Required (writes=[$WRITES])"
fi

# ---------------------------------------------------------------------------
# 3. A native job run already reported → the lane must NOT publish.
# ---------------------------------------------------------------------------
reset_env
write_open_prs "7:$HEAD_A"
write_pr 7 "$HEAD_A" "someone" "$NO_SELF_REVIEW_BODY"
write_check_runs self-review "$HEAD_A" "3f0b2b3e-0000-4000-8000-000000000001"
write_check_runs label-gate "$HEAD_A" "3f0b2b3e-0000-4000-8000-000000000002"
run_sweep
if [ "$RC" -eq 0 ] && [ -z "$WRITES" ]; then
  pass "a head whose contexts already reported natively gains no second lineage"
else
  fail "the lane must not publish over a native producer (rc=$RC, writes=[$WRITES])"
fi

# ---------------------------------------------------------------------------
# 4. A run THIS lane published → refreshed from live state.
# ---------------------------------------------------------------------------
reset_env
write_open_prs "7:$HEAD_A"
write_pr 7 "$HEAD_A" "someone" "$SELF_REVIEW_BODY"
write_check_runs self-review "$HEAD_A" "$RECOVERY_ID"
write_check_runs label-gate "$HEAD_A" "$RECOVERY_ID"
run_sweep
if [ "$(published_conclusion 'Self-Review Required')" = "success" ] \
  && [ "$(published_conclusion 'Label Gate')" = "success" ]; then
  pass "a context this lane already owns is refreshed from live state"
else
  fail "the lane must refresh its own lineage (writes=[$WRITES])"
fi

# ---------------------------------------------------------------------------
# 6. A blocking label fails the recovered Label Gate and names it; 6c a
#    non-blocking label does not.
# ---------------------------------------------------------------------------
reset_env
write_open_prs "7:$HEAD_A"
write_pr 7 "$HEAD_A" "someone" "$SELF_REVIEW_BODY" "needs-human-review" "size:M"
run_sweep
if [ "$(published_conclusion 'Label Gate')" = "failure" ] \
  && printf '%s\n' "$WRITES" | grep -qF 'needs-human-review'; then
  pass "a blocking label fails the recovered Label Gate and is named in the summary"
else
  fail "a blocking label must fail the recovered Label Gate (writes=[$WRITES])"
fi

reset_env
write_open_prs "7:$HEAD_A"
write_pr 7 "$HEAD_A" "someone" "$SELF_REVIEW_BODY" "size:M" "documentation"
run_sweep
if [ "$(published_conclusion 'Label Gate')" = "success" ]; then
  pass "non-blocking labels leave the recovered Label Gate green"
else
  fail "non-blocking labels must not fail the Label Gate (writes=[$WRITES])"
fi

# ---------------------------------------------------------------------------
# 7. Dependabot keeps the event-driven job's exemption.
# ---------------------------------------------------------------------------
reset_env
write_open_prs "7:$HEAD_A"
write_pr 7 "$HEAD_A" 'dependabot[bot]' "$NO_SELF_REVIEW_BODY"
run_sweep
if [ "$(published_conclusion 'Self-Review Required')" = "skipped" ] \
  && [ "$(published_conclusion 'Label Gate')" = "success" ]; then
  pass "a Dependabot PR recovers Self-Review as skipped and still evaluates Label Gate"
else
  fail "Dependabot must stay exempt from Self-Review Required (writes=[$WRITES])"
fi

# ---------------------------------------------------------------------------
# 8. The head moves between evaluation and publication → publish nothing.
# ---------------------------------------------------------------------------
reset_env
write_open_prs "7:$HEAD_A"
write_pr 7 "$HEAD_A" "someone" "$SELF_REVIEW_BODY"
export LIVE_HEAD_7="$HEAD_B"
run_sweep
if [ -z "$WRITES" ]; then
  pass "a head that moved during evaluation gets no verdict pinned to it"
else
  fail "a moved head must not be published to (writes=[$WRITES])"
fi

# ---------------------------------------------------------------------------
# 14. The compare-and-swap fence: the check runs for a (head, context) change
#     between the decision and the POST, so the verdict is stale. The head has
#     NOT moved — a label change never moves it — which is exactly why the
#     head re-read cannot stand in for this fence.
# ---------------------------------------------------------------------------
reset_env
write_open_prs "7:$HEAD_A"
write_pr 7 "$HEAD_A" "someone" "$SELF_REVIEW_BODY"
write_check_runs_second self-review "$HEAD_A" "3f0b2b3e-0000-4000-8000-000000000009"
write_check_runs_second label-gate "$HEAD_A" "3f0b2b3e-0000-4000-8000-00000000000a"
run_sweep
if [ -z "$WRITES" ]; then
  pass "a verdict is withheld when the check runs it was decided over changed underneath it"
else
  fail "the compare-and-swap fence must withhold a stale verdict (writes=[$WRITES])"
fi

# ---------------------------------------------------------------------------
# 15. Phase 4 applies and no blocking label is present → Label Gate FAILS.
# ---------------------------------------------------------------------------
reset_env
write_open_prs "7:$HEAD_A"
write_pr 7 "$HEAD_A" "someone" "$SELF_REVIEW_BODY"
export DERIVE_MODE=true
run_sweep
if [ "$(published_conclusion 'Label Gate')" = "failure" ] \
  && printf '%s\n' "$WRITES" | grep -qF 'requires Phase 4 external review'; then
  pass "an unlabelled PR that requires Phase 4 does not get a green Label Gate"
else
  fail "a Phase-4-requiring PR must not be greened from the absent label alone (writes=[$WRITES])"
fi

# ---------------------------------------------------------------------------
# 16. The derivation exits nonzero → red and exit 1; 16b non-boolean output
#     is the same fail-closed answer, not a silent green.
# ---------------------------------------------------------------------------
reset_env
write_open_prs "7:$HEAD_A"
write_pr 7 "$HEAD_A" "someone" "$SELF_REVIEW_BODY"
export DERIVE_MODE=fail
run_sweep
if [ "$RC" -eq 1 ] && [ "$(published_conclusion 'Label Gate')" = "failure" ]; then
  pass "a failed Phase 4 derivation publishes red and reddens the sweep"
else
  fail "a failed derivation must fail closed (rc=$RC, writes=[$WRITES])"
fi

reset_env
write_open_prs "7:$HEAD_A"
write_pr 7 "$HEAD_A" "someone" "$SELF_REVIEW_BODY"
export DERIVE_MODE=garbage
run_sweep
if [ "$RC" -eq 1 ] && [ "$(published_conclusion 'Label Gate')" = "failure" ]; then
  pass "a non-boolean Phase 4 answer is fail-closed, not read as false"
else
  fail "a non-boolean derivation answer must fail closed (rc=$RC, writes=[$WRITES])"
fi

# ---------------------------------------------------------------------------
# 17. The labels are read LATE. A label present only in the later read still
#     blocks, which proves the verdict does not come from the PR-detail
#     snapshot taken at the top of the iteration.
# ---------------------------------------------------------------------------
reset_env
write_open_prs "7:$HEAD_A"
write_pr 7 "$HEAD_A" "someone" "$SELF_REVIEW_BODY"
write_late_labels 7 "human-hold"
run_sweep
if [ "$(published_conclusion 'Label Gate')" = "failure" ] \
  && printf '%s\n' "$WRITES" | grep -qF 'human-hold'; then
  pass "the Label Gate verdict comes from a late label read, not the detail snapshot"
else
  fail "a label added after the detail read must still block (writes=[$WRITES])"
fi

# ---------------------------------------------------------------------------
# 13. Two open PRs share a head → both contexts red on it, and neither PR's
#     own verdict is published. PR 8 is clean and would otherwise green the
#     slot that PR 7's `human-hold` must keep red.
# ---------------------------------------------------------------------------
reset_env
write_open_prs "7:$HEAD_A" "8:$HEAD_A"
write_pr 7 "$HEAD_A" "someone" "$SELF_REVIEW_BODY" "human-hold"
write_pr 8 "$HEAD_A" "someone" "$SELF_REVIEW_BODY"
run_sweep
if [ "$RC" -eq 1 ] \
  && [ "$(uniq_conclusions 'Label Gate')" = "failure" ] \
  && [ "$(uniq_conclusions 'Self-Review Required')" = "failure" ] \
  && printf '%s\n' "$WRITES" | grep -qF 'More than one open PR carries'; then
  pass "a head carried by two open PRs is published red on both contexts"
else
  fail "an ambiguous head must fail closed (rc=$RC, conclusions=[$(uniq_conclusions 'Label Gate')] [$(uniq_conclusions 'Self-Review Required')])"
fi

# ---------------------------------------------------------------------------
# 9. An unreadable check-runs listing withholds that context and reddens the
#    run — publishing into unknown state is the failure mode to avoid.
# ---------------------------------------------------------------------------
reset_env
write_open_prs "7:$HEAD_A"
write_pr 7 "$HEAD_A" "someone" "$SELF_REVIEW_BODY"
export FAIL_CHECKRUNS_self_review=1
run_sweep
if [ "$RC" -eq 1 ] \
  && [ -z "$(published_conclusion 'Self-Review Required')" ] \
  && [ "$(published_conclusion 'Label Gate')" = "success" ]; then
  pass "an unreadable check-runs listing withholds that context and exits 1"
else
  fail "an unreadable listing must withhold and fail closed (rc=$RC, writes=[$WRITES])"
fi

# ---------------------------------------------------------------------------
# 9b. The DECISION read alone fails (the compare-and-swap read would have
#     succeeded). Its own fail-closed branch has to hold without the CAS
#     fence standing in for it.
# ---------------------------------------------------------------------------
reset_env
write_open_prs "7:$HEAD_A"
write_pr 7 "$HEAD_A" "someone" "$SELF_REVIEW_BODY"
export FAIL_CHECKRUNS_AT_self_review=1
run_sweep
if [ "$RC" -eq 1 ] \
  && [ -z "$(published_conclusion 'Self-Review Required')" ] \
  && [ "$(published_conclusion 'Label Gate')" = "success" ]; then
  pass "a failed decision read withholds that context on its own"
else
  fail "a failed decision read must withhold (rc=$RC, writes=[$WRITES])"
fi

# ---------------------------------------------------------------------------
# 9c. The compare-and-swap read alone fails, after a clean decision read.
#     Unknown state is possibly-newer state, so the verdict is withheld rather
#     than posted over whatever landed.
# ---------------------------------------------------------------------------
reset_env
write_open_prs "7:$HEAD_A"
write_pr 7 "$HEAD_A" "someone" "$SELF_REVIEW_BODY"
export FAIL_CHECKRUNS_AT_self_review=2
run_sweep
if [ "$RC" -eq 1 ] \
  && [ -z "$(published_conclusion 'Self-Review Required')" ] \
  && [ "$(published_conclusion 'Label Gate')" = "success" ]; then
  pass "a failed compare-and-swap read withholds rather than assuming nothing changed"
else
  fail "a failed CAS read must withhold (rc=$RC, writes=[$WRITES])"
fi

# ---------------------------------------------------------------------------
# 10. An unreadable open-PR list sweeps nothing at all.
# ---------------------------------------------------------------------------
reset_env
write_open_prs "7:$HEAD_A"
write_pr 7 "$HEAD_A" "someone" "$SELF_REVIEW_BODY"
export FAIL_OPEN_PRS=1
run_sweep
if [ "$RC" -eq 1 ] && [ -z "$WRITES" ]; then
  pass "an unreadable open-PR list exits 1 with no write"
else
  fail "an unreadable open-PR list must fail closed (rc=$RC, writes=[$WRITES])"
fi

# ---------------------------------------------------------------------------
# 11. One unreadable PR does not abandon the rest of the sweep.
# ---------------------------------------------------------------------------
reset_env
write_open_prs "7:$HEAD_A" "8:$HEAD_B"
write_pr 7 "$HEAD_A" "someone" "$SELF_REVIEW_BODY"
write_pr 8 "$HEAD_B" "someone" "$SELF_REVIEW_BODY"
export FAIL_PR_7=1
run_sweep
if [ "$RC" -eq 1 ] \
  && [ "$(published_field 'Label Gate' head_sha)" = "$HEAD_B" ] \
  && ! printf '%s\n' "$WRITES" | grep -qF "$HEAD_A"; then
  pass "an unreadable PR is skipped and flagged while the rest of the sweep continues"
else
  fail "one bad PR must not abandon the sweep (rc=$RC, writes=[$WRITES])"
fi

# ---------------------------------------------------------------------------
# 11b. A head that does not read as a git object name publishes nothing.
# ---------------------------------------------------------------------------
reset_env
write_open_prs "7:"
write_pr 7 "" "someone" "$SELF_REVIEW_BODY"
run_sweep
if [ "$RC" -eq 1 ] && [ -z "$WRITES" ]; then
  pass "a PR with no usable head sha is skipped and flagged"
else
  fail "an unusable head sha must not be published to (rc=$RC, writes=[$WRITES])"
fi

# ---------------------------------------------------------------------------
# 12. The lane's only mutating call is the check-run POST. It must never
#     label, comment, or otherwise write PR state — its job permissions grant
#     `pull-requests: read`, so a mutation added here would 403 in production
#     rather than fail visibly in review.
# ---------------------------------------------------------------------------
reset_env
write_open_prs "7:$HEAD_A"
write_pr 7 "$HEAD_A" "someone" "$NO_SELF_REVIEW_BODY" "needs-human-review"
run_sweep
mutations=$(grep -E '(-X|--method)'$'\t''(POST|PATCH|PUT|DELETE)' "$WORKDIR/calls.log" || true)
non_checkrun=$(printf '%s\n' "$mutations" | grep -v 'check-runs' | grep -c . || true)
if [ "$non_checkrun" -eq 0 ] && [ -n "$mutations" ]; then
  pass "the only mutating call the lane makes is the check-run POST"
else
  fail "the lane must issue no mutation other than the check-run POST (mutations=[$mutations])"
fi

echo
echo "pr-review-policy-recovery: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
