#!/usr/bin/env bash
# tests/test_sync_labels.sh — scripts/sync-labels.sh against a stateful fake
# GitHub: per-repository label state served from files, with writes applied
# through a fake author wrapper.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/sync-labels.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
PASS=0; FAIL=0
pass() { echo "PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $*" >&2; FAIL=$((FAIL + 1)); }

BIN="$WORK/bin"; STATE="$WORK/state"; mkdir -p "$BIN" "$STATE"
cat >"$WORK/manifest.yml" <<'YML'
consumers:
  - name: alpha
    repo: nathanjohnpayne/alpha
  - name: beta
    repo: nathanjohnpayne/beta
YML
cat >"$WORK/infra.sh" <<'INFRA'
BOOTSTRAP_LABELS=(
  "needs-external-review|bf0606|External review required before merge"
  "human-hold|000000|Hard merge freeze - human-remove-only; supersedes all gates"
  "size:S|c2e0c6|Small: one file or a narrow change"
  "phase-4|bfd4f2|Superseded by area:phase-4b."
)
BOOTSTRAP_DEPRECATED_LABELS=(phase-4)
INFRA

cat >"$BIN/gh" <<'GH'
#!/usr/bin/env bash
set -uo pipefail
S=${FAKE_STATE:?}
[ "${1:-}" = api ] || { echo "unsupported: $*" >&2; exit 99; }
shift; endpoint=""; method=GET; input=""
while [ $# -gt 0 ]; do
  case "$1" in
    --method) method=$2; shift 2 ;;
    --input) input=$2; shift 2 ;;
    --paginate) shift ;;
    *) endpoint=$1; shift ;;
  esac
done
echo "$method $endpoint" >>"$S/calls.log"
repo=$(printf '%s' "$endpoint" | sed -E 's#^repos/[^/]+/([^/]+)/labels.*#\1#')
f="$S/$repo.json"
[ "${FAKE_FAIL_REPO:-}" != "$repo" ] || { echo "HTTP 500" >&2; exit 1; }
case "$method" in
  GET) cat "$f" ;;
  POST) jq -c --slurpfile b "$input" '. + [$b[0]]' "$f" >"$f.new" && mv "$f.new" "$f" ;;
  PATCH)
    name=$(python3 -c 'import sys,urllib.parse;print(urllib.parse.unquote(sys.argv[1]))' "${endpoint##*/labels/}")
    jq -c --arg n "$name" --slurpfile b "$input" 'map(if .name == $n then . + $b[0] else . end)' "$f" >"$f.new" && mv "$f.new" "$f" ;;
esac
GH
chmod +x "$BIN/gh"
cat >"$BIN/as-author" <<'W'
#!/usr/bin/env bash
echo "author-write" >>"${FAKE_STATE:?}/author.log"
while [ $# -gt 0 ] && [ "$1" != -- ]; do shift; done; shift
exec "$@"
W
chmod +x "$BIN/as-author"

reset_state() {
  rm -f "$STATE"/*
  # hub: in sync except a colour-case difference (must be treated as equal)
  printf '%s' '[{"name":"needs-external-review","color":"BF0606","description":"External review required before merge"},{"name":"human-hold","color":"000000","description":"Hard merge freeze - human-remove-only; supersedes all gates"},{"name":"size:S","color":"c2e0c6","description":"Small: one file or a narrow change"},{"name":"local-only","color":"123456","description":"not canonical"}]' >"$STATE/mergepath.json"
  # alpha: drifted colour + description, missing human-hold, has deprecated phase-4 drifted
  printf '%s' '[{"name":"needs-external-review","color":"B60205","description":"Blocks merge"},{"name":"size:S","color":"c2e0c6","description":"Small: one file or a narrow change"},{"name":"phase-4","color":"1D76DB","description":"Phase 4"},{"name":"local-only","color":"abcdef","description":"keep me"}]' >"$STATE/alpha.json"
  # beta: lacks everything, including the deprecated label
  printf '%s' '[]' >"$STATE/beta.json"
}
run() { RC=0; OUT=$(PATH="$BIN:$PATH" FAKE_STATE="$STATE" SYNC_LABELS_MANIFEST="$WORK/manifest.yml" \
  SYNC_LABELS_INFRA="$WORK/infra.sh" SYNC_LABELS_AS_AUTHOR="$BIN/as-author" bash "$ROOT/scripts/sync-labels.sh" "$@" 2>&1) || RC=$?; }
label() { jq -c --arg n "$2" '.[] | select(.name == $n) | [.color, .description]' "$STATE/$1.json"; }

# Dry run plans the changes and writes nothing.
reset_state; run
if [ "$RC" = 1 ] && [ ! -f "$STATE/author.log" ] && ! grep -qE '^(POST|PATCH)' "$STATE/calls.log" \
   && printf '%s' "$OUT" | grep -q '= nathanjohnpayne/mergepath: in sync' \
   && printf '%s' "$OUT" | grep -q 'create human-hold' \
   && printf '%s' "$OUT" | grep -q 'update needs-external-review: color B60205 -> bf0606, description' \
   && printf '%s' "$OUT" | grep -q 'update phase-4: color 1D76DB -> bfd4f2, description'; then
  pass "dry run: plans creates and updates, treats colour case as equal, writes nothing, exits 1"
else fail "dry run rc=$RC: $OUT"; fi
if printf '%s' "$OUT" | grep -q 'beta' && ! printf '%s' "$OUT" | grep -A6 'beta' | grep -q 'create phase-4'; then
  pass "dry run: a deprecated label is never created where it is missing"
else fail "deprecated create: $OUT"; fi

# Apply converges every repository and touches nothing outside the canonical list.
reset_state; run --apply
if [ "$RC" = 0 ] \
   && [ "$(label alpha needs-external-review)" = '["bf0606","External review required before merge"]' ] \
   && [ "$(label alpha human-hold)" = '["000000","Hard merge freeze - human-remove-only; supersedes all gates"]' ] \
   && [ "$(label alpha phase-4)" = '["bfd4f2","Superseded by area:phase-4b."]' ] \
   && [ "$(label alpha local-only)" = '["abcdef","keep me"]' ] \
   && [ -z "$(label beta phase-4)" ] && [ -n "$(label beta size:S)" ] \
   && [ "$(label mergepath needs-external-review)" = '["BF0606","External review required before merge"]' ]; then
  pass "apply: creates missing active labels, fixes drift, corrects deprecated only where present, leaves non-canonical labels and case-only colours alone"
else fail "apply rc=$RC: $OUT $(cat "$STATE/alpha.json")"; fi
grep -q author-write "$STATE/author.log" && pass "apply: every write goes through the author wrapper" || fail "writes bypassed the wrapper"
run
[ "$RC" = 0 ] && printf '%s' "$OUT" | grep -q 'every repository matches' && pass "after apply a dry run is clean (exit 0)" || fail "post-apply dry run rc=$RC: $OUT"

# --repos narrows the fleet; an unknown name fails closed.
reset_state; run --repos beta
[ "$RC" = 1 ] && ! printf '%s' "$OUT" | grep -q alpha && pass "--repos limits the run to the named repositories" || fail "--repos: $OUT"
reset_state; run --repos nonesuch
[ "$RC" = 3 ] && pass "--repos with no fleet match fails closed (exit 3)" || fail "--repos nonesuch rc=$RC"

# An unreadable repository is a failure, not "in sync".
reset_state; FAKE_FAIL_REPO=alpha run
[ "$RC" = 3 ] && printf '%s' "$OUT" | grep -q 'alpha: labels unreadable' && pass "an unreadable repository fails the run (exit 3), never reads as in sync" || fail "unreadable rc=$RC: $OUT"

# A malformed canonical source fails closed before any read.
reset_state; printf 'BOOTSTRAP_LABELS=(\n  "broken|nothex|x"\n)\n' >"$WORK/bad.sh"
RC=0; OUT=$(PATH="$BIN:$PATH" FAKE_STATE="$STATE" SYNC_LABELS_MANIFEST="$WORK/manifest.yml" SYNC_LABELS_INFRA="$WORK/bad.sh" \
  SYNC_LABELS_AS_AUTHOR="$BIN/as-author" bash "$ROOT/scripts/sync-labels.sh" 2>&1) || RC=$?
[ "$RC" = 3 ] && [ ! -f "$STATE/calls.log" ] && pass "a malformed canonical label fails closed before any read" || fail "bad canon rc=$RC: $OUT"

# The real canonical source parses, and its deprecated set is a subset of it.
RC=0; canon_ok=$(bash -c 'eval "$(sed -n "/^BOOTSTRAP_LABELS=(/,/^)/p" "$1")"; eval "$(grep -E "^BOOTSTRAP_DEPRECATED_LABELS=\(" "$1")"; for d in "${BOOTSTRAP_DEPRECATED_LABELS[@]}"; do printf "%s\n" "${BOOTSTRAP_LABELS[@]}" | grep -q "^$d|" || { echo "missing:$d"; exit 1; }; done; echo ok' _ "$ROOT/scripts/bootstrap/github-infra.sh") || RC=$?
[ "$canon_ok" = ok ] && pass "every deprecated label in github-infra.sh is a canonical label" || fail "deprecated subset: $canon_ok"

echo
echo "test_sync_labels: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
