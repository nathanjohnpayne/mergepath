#!/usr/bin/env bash
# Exact real Git objects, immutable bytes and context-bound verdicts (#1753).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../scripts/phase-4b/immutable-input.sh
. "$ROOT/scripts/phase-4b/immutable-input.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/p4b-immutable-test.XXXXXX")"
trap 'chmod -R u+w "$WORK"; rm -rf "$WORK"' EXIT
PASS=0; FAIL=0
pass() { printf 'PASS: %s\n' "$*"; PASS=$((PASS+1)); }
fail() { printf 'FAIL: %s\n' "$*" >&2; FAIL=$((FAIL+1)); }
unset GH_TOKEN GITHUB_TOKEN OP_PREFLIGHT_AUTHOR_PAT OP_PREFLIGHT_REVIEWER_PAT
INPUT_REAL_GIT="$(command -v git)"
export INPUT_REAL_GIT INPUT_FIXTURE="$WORK/repo" INPUT_WORK="$WORK"
mkdir -p "$WORK/bin" "$INPUT_FIXTURE"
"$INPUT_REAL_GIT" -C "$INPUT_FIXTURE" init -q
printf 'base\n' > "$INPUT_FIXTURE/file"
"$INPUT_REAL_GIT" -C "$INPUT_FIXTURE" add file
"$INPUT_REAL_GIT" -C "$INPUT_FIXTURE" -c user.name=Fixture -c user.email=fixture@example.invalid commit -qm base
BASE="$("$INPUT_REAL_GIT" -C "$INPUT_FIXTURE" rev-parse HEAD)"
printf 'head A\n' > "$INPUT_FIXTURE/file"
"$INPUT_REAL_GIT" -C "$INPUT_FIXTURE" -c user.name=Fixture -c user.email=fixture@example.invalid commit -qam A
HEAD_A="$("$INPUT_REAL_GIT" -C "$INPUT_FIXTURE" rev-parse HEAD)"
printf 'head B MUST NOT BE REVIEWED\n' > "$INPUT_FIXTURE/file"
"$INPUT_REAL_GIT" -C "$INPUT_FIXTURE" -c user.name=Fixture -c user.email=fixture@example.invalid commit -qam B
# Mutable branch now names B; capture must derive A from its immutable ID.
cat > "$WORK/bin/git" <<'SH'
#!/usr/bin/env bash
set -eu
args=()
for arg in "$@"; do
 case "$arg" in https://github.com/fixture/repo.git) arg="$INPUT_FIXTURE" ;; esac
 args+=("$arg")
done
printf '%s\n' "$*" >> "$INPUT_WORK/git-calls"
exec "$INPUT_REAL_GIT" "${args[@]}"
SH
cat > "$WORK/bin/gh" <<'SH'
#!/usr/bin/env bash
set -eu
printf '%s\n' "$*" >> "$INPUT_WORK/gh-calls"
if [ "$1" = api ] && [ "$2" = --paginate ] && [ "$3" = --slurp ]; then
 if [ -e "$INPUT_WORK/aba" ]; then
  printf '[[{"id":1,"event":"head_ref_force_pushed","created_at":"2026-10-08T00:00:01Z","commit_id":null},{"id":2,"event":"head_ref_force_pushed","created_at":"2026-10-08T00:00:02Z","commit_id":null}]]\n'
 else printf '[[]]\n'; fi
 exit 0
fi
# A mutable PR diff read would violate the production capture contract.
exit 99
SH
chmod +x "$WORK/bin/git" "$WORK/bin/gh"
export PATH="$WORK/bin:$PATH"
mkdir "$WORK/input"
if p4b_capture_input fixture/repo 1753 "$BASE" "$HEAD_A" "$WORK/input"; then pass 'capture succeeds from exact real Git objects'; else fail 'capture'; fi
"$INPUT_REAL_GIT" -C "$INPUT_FIXTURE" diff --binary --full-index --no-ext-diff --no-textconv "$BASE" "$HEAD_A" -- > "$WORK/expected.diff"
if cmp -s "$WORK/input/review.diff" "$WORK/expected.diff" && ! grep -q 'MUST NOT BE REVIEWED' "$WORK/input/review.diff"; then
 pass 'mutable B branch cannot change captured A diff'
else fail 'immutable object derivation'; fi
if grep -Fq "https://github.com/fixture/repo.git $BASE $HEAD_A" "$WORK/git-calls" && ! grep -q 'pr diff' "$WORK/gh-calls"; then
 pass 'fetch names both full immutable objects and never reads mutable PR diff'
else fail 'capture endpoints'; fi
# Read numeric permission bits without a platform-specific stat dialect.
mode="$(node -e 'process.stdout.write((require("node:fs").statSync(process.argv[1]).mode & 0o777).toString(8))' "$WORK/input")"
file_mode="$(node -e 'process.stdout.write((require("node:fs").statSync(process.argv[1]).mode & 0o777).toString(8))' "$WORK/input/review.diff")"
[ "$mode" = 700 ] && [ "$file_mode" = 400 ] && pass 'private directory and read-only diff' || fail 'input protection'
VERDICT='{"verdict":"APPROVED","summary":"A reviewed","findings":[],"usage":null,"cli_version":null}'
BOUND="$(p4b_bind_input "$WORK/input/input.json" "$WORK/input/review.diff" "$WORK/input/review.diff" "$VERDICT")"
if p4b_validate_bound_input "$BOUND" "$WORK/input/input.json" "$WORK/input/review.diff"; then pass 'trusted adapter binds base head and input digests'; else fail 'bound verdict'; fi
if p4b_revalidate_input fixture/repo 1753 "$WORK/input"; then pass 'authorized unchanged input survives the generation fence'; else fail 'positive revalidation'; fi
TAMPERED="$(printf '%s' "$BOUND" | jq -c --arg base "$BASE" '.review_input.head_sha=$base')"
if p4b_validate_bound_input "$TAMPERED" "$WORK/input/input.json" "$WORK/input/review.diff"; then fail 'wrong-head verdict accepted'; else pass 'wrong-head binding is rejected'; fi
STANDALONE="$(p4b_bind_input '' "$WORK/input/review.diff" "$WORK/input/review.diff" "$VERDICT")"
if p4b_validate_bound_input "$STANDALONE" "$WORK/input/input.json" "$WORK/input/review.diff"; then fail 'standalone verdict has post authority'; else pass 'standalone reasoning has no postable binding'; fi
: > "$WORK/aba"
if p4b_revalidate_input fixture/repo 1753 "$WORK/input"; then fail 'A-B-A transition accepted'; else pass 'observed A-B-A generation refuses unchanged final A'; fi
rm "$WORK/aba"
chmod 600 "$WORK/input/review.diff"
printf '+changed after capture\n' >> "$WORK/input/review.diff"
if p4b_validate_bound_input "$BOUND" "$WORK/input/input.json" "$WORK/input/review.diff"; then fail 'changed input accepted'; else pass 'changed diff cannot retain bound approval'; fi
if p4b_capture_input fixture/repo 1753 "${BASE:0:7}" "$HEAD_A" "$WORK/input"; then fail 'abbreviated base accepted'; else pass 'abbreviated capture IDs are rejected'; fi
printf '\ntest_phase_4b_immutable_input: %s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
