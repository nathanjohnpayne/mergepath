#!/usr/bin/env bash
# Exact real Git objects, immutable bytes and context-bound verdicts (#1753).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../scripts/phase-4b/immutable-input.sh
. "$ROOT/scripts/phase-4b/immutable-input.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/p4b-immutable-test.XXXXXX")"
trap 'chmod -R u+w "$WORK"; rm -rf "$WORK"' EXIT
PASS=0; FAIL=0
INPUT_BASE_PATH="$PATH"
pass() { printf 'PASS: %s\n' "$*"; PASS=$((PASS+1)); }
fail() { printf 'FAIL: %s\n' "$*" >&2; FAIL=$((FAIL+1)); }
unset GH_TOKEN GITHUB_TOKEN OP_PREFLIGHT_AUTHOR_PAT OP_PREFLIGHT_REVIEWER_PAT
# Hooks may export redirects to their own repository. Fixture writes must not.
for input_variable in $(compgen -e); do
  case "$input_variable" in GIT_*) unset "$input_variable" ;; esac
done
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
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
export HEAD_A BASE
printf 'head B MUST NOT BE REVIEWED\n' > "$INPUT_FIXTURE/file"
"$INPUT_REAL_GIT" -C "$INPUT_FIXTURE" -c user.name=Fixture -c user.email=fixture@example.invalid commit -qam B
# Mutable branch now names B; capture must derive A from its immutable ID.
cat > "$WORK/bin/git" <<'SH'
#!/usr/bin/env bash
set -eu
args=()
for arg in "$@"; do
 case "$arg" in
  https://github.com/fixture/repo.git) arg="$INPUT_FIXTURE" ;;
  https://*) printf 'unexpected remote: %s\n' "$arg" >> "$INPUT_WORK/git-calls"; exit 99 ;;
 esac
 args+=("$arg")
done
prefix=(); is_fetch=0
for arg in "$@"; do
 if [ "$arg" = fetch ]; then is_fetch=1; break; fi
 prefix+=("$arg")
done
if [ "${INPUT_REQUIRE_AUTH_CONTEXT:-0}" = 1 ] && [ "$is_fetch" = 1 ]; then
 printf 'protocol=https\nhost=github.com\n\n' | "$INPUT_REAL_GIT" "${prefix[@]}" credential fill >/dev/null
fi
printf '%s\n' "$*" >> "$INPUT_WORK/git-calls"
exec "$INPUT_REAL_GIT" "${args[@]}"
SH
cat > "$WORK/bin/gh" <<'SH'
#!/usr/bin/env bash
set -eu
printf '%s\n' "$*" >> "$INPUT_WORK/gh-calls"
if [ "${INPUT_REQUIRE_AUTH_CONTEXT:-0}" = 1 ]; then
 if [ "$INPUT_AUTH_SOURCE" = token ]; then
  [ "${GITHUB_TOKEN:-}" = fixture-token ] || exit 92
 else
  [ -f "${GH_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/gh}/hosts.yml" ] || exit 93
 fi
fi
if [ "$1" = auth ] && [ "$2" = git-credential ]; then
 printf 'username=fixture\npassword=fixture\n'; exit 0
fi
if [ "$1" = api ] && [ "$2" = --paginate ] && [ "$3" = --slurp ]; then
 if [ -e "$INPUT_WORK/base-moves-during-timeline" ]; then
  printf '%s\n' "$HEAD_A" > "$INPUT_WORK/live-base"
 fi
 if [ -e "$INPUT_WORK/aba" ]; then
  printf '[[{"id":1,"event":"head_ref_force_pushed","created_at":"2026-10-08T00:00:01Z","commit_id":null},{"id":2,"event":"head_ref_force_pushed","created_at":"2026-10-08T00:00:02Z","commit_id":null}]]\n'
 else printf '[[]]\n'; fi
 exit 0
fi
if [ "$1" = api ] && [ "$2" = repos/fixture/repo/pulls/1753 ]; then
 [ ! -e "$INPUT_WORK/tuple-fails" ] || exit 1
 live_base="$BASE"
 if [ -e "$INPUT_WORK/live-base" ]; then live_base="$(cat "$INPUT_WORK/live-base")"; fi
 jq -cn --arg head "$HEAD_A" --arg base "$live_base" --arg source "${SOURCE_HEAD:-$HEAD_A}" \
  '{number:1753,head:{sha:$head,ref:("mergepath-sync/"+$source)},base:{sha:$base,ref:"main",repo:{default_branch:"main"}},user:{login:"fixture"}}'
 exit 0
fi
if [ "$1" = api ] && [ "$2" = "repos/fixture/repo/contents/.github/review-policy.yml?ref=$BASE" ]; then
 [ ! -e "$INPUT_WORK/policy-fails" ] || exit 1
 cat "$INPUT_WORK/consumer-policy.yml"
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
: > "$WORK/base-moves-during-timeline"
if p4b_revalidate_input fixture/repo 1753 "$WORK/input"; then
 fail 'base-only move during timeline accepted'
else pass 'base-only move during final timeline read refuses unchanged head and bytes'; fi
rm "$WORK/base-moves-during-timeline" "$WORK/live-base"
: > "$WORK/tuple-fails"
if p4b_revalidate_input fixture/repo 1753 "$WORK/input"; then
 fail 'unreadable final tuple accepted'
else pass 'unreadable final coherent tuple refuses review'; fi
rm "$WORK/tuple-fails"
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

mkdir -p "$WORK/auth-home/.config/gh"
printf 'fixture auth configuration\n' > "$WORK/auth-home/.config/gh/hosts.yml"
for auth_source in stored explicit token; do
 if (
  export INPUT_REQUIRE_AUTH_CONTEXT=1 INPUT_AUTH_SOURCE="$auth_source"
  export XDG_CONFIG_HOME="$WORK/auth-home/.config"
  unset GH_CONFIG_DIR GH_TOKEN GITHUB_TOKEN
  if [ "$auth_source" = explicit ]; then export GH_CONFIG_DIR="$WORK/auth-home/.config/gh"; fi
  if [ "$auth_source" = token ]; then export GITHUB_TOKEN=fixture-token; fi
  mkdir "$WORK/auth-$auth_source"
  p4b_capture_input fixture/repo 1753 "$BASE" "$HEAD_A" "$WORK/auth-$auth_source"
 ); then pass "isolated real Git credential helper retains $auth_source gh auth"
 else fail "$auth_source gh auth lost during capture"; fi
done

# Curated wave tooling is hub-only. Missing tooling on the hub still fails;
# consumers retain the regular immutable-input and collector assertions.
if [ -f "$ROOT/scripts/sync-to-downstream.sh" ]; then
# Curated-wave input deliberately differs from the complete consumer PR diff.
# Execute real trusted wave regeneration over a separate committed canonical
# range; only the external live-byte provider is replaced with a fixed proof.
CANON="$WORK/canonical"
mkdir -p "$CANON/scripts/phase-4b" "$CANON/scripts/workflow" "$CANON/docs" "$CANON/.github"
"$INPUT_REAL_GIT" -C "$CANON" init -q
printf 'canonical base\n' >"$CANON/file"
printf 'excluded base\n' >"$CANON/docs/excluded"
printf 'paths:\n  - path: file\n  - path: docs/\n' >"$CANON/.mergepath-sync.yml"
printf 'propagation_audit:\n  scope_exclude_prefixes:\n    - docs/\n' >"$CANON/.github/review-policy.yml"
"$INPUT_REAL_GIT" -C "$CANON" add file docs .mergepath-sync.yml
"$INPUT_REAL_GIT" -C "$CANON" -c user.name=Fixture -c user.email=fixture@example.invalid commit -qm canonical-base
SOURCE_BASE="$("$INPUT_REAL_GIT" -C "$CANON" rev-parse HEAD)"
printf 'canonical head\n' >"$CANON/file"
printf 'excluded head\n' >"$CANON/docs/excluded"
"$INPUT_REAL_GIT" -C "$CANON" -c user.name=Fixture -c user.email=fixture@example.invalid commit -qam canonical-head
SOURCE_HEAD="$("$INPUT_REAL_GIT" -C "$CANON" rev-parse HEAD)"
export SOURCE_HEAD HEAD_A BASE
cp "$ROOT/scripts/phase-4b/immutable-input.sh" "$CANON/scripts/phase-4b/"
cp "$ROOT/scripts/workflow/resolve_base_policy.sh" "$CANON/scripts/workflow/"
cp "$ROOT/scripts/wave-audit.sh" "$CANON/scripts/wave-audit-real.sh"
cat > "$CANON/scripts/wave-audit.sh" <<'SH'
#!/usr/bin/env bash
set -eu
[ -f "${GH_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/gh}/hosts.yml" ] || exit 94
printf 'wave auth preserved\n' >> "$INPUT_WORK/auth-boundaries"
exec bash "$(dirname "${BASH_SOURCE[0]}")/wave-audit-real.sh" "$@"
SH
printf '#!/usr/bin/env bash\nexit 99\n' >"$CANON/scripts/phase-4b-review.sh"
cat >"$CANON/scripts/workflow/verify-live-propagation.sh" <<'SH'
#!/usr/bin/env bash
cat >/dev/null
[ ! -e "$INPUT_WORK/proof-fails" ] || exit 2
cmp -s "$5" "$INPUT_WORK/consumer-policy.yml" || exit 2
[ -f "${GH_CONFIG_DIR:-}/hosts.yml" ] || exit 2
jq -cn --arg source "$SOURCE_HEAD" --arg head "$HEAD_A" --arg base "$BASE" \
 '{source_sha:$source,head_sha:$head,base_sha:$base}'
SH
printf 'propagation_audit:\n  scope_exclude_prefixes:\n    - docs/\n' >"$WORK/wave-policy.yml"
printf 'propagation_prs:\n  enabled: true\n' >"$INPUT_WORK/consumer-policy.yml"
jq -n --arg base "$SOURCE_BASE" --arg head "$SOURCE_HEAD" \
 '{version:1,canonical_base_sha:$base,canonical_head_sha:$head,historical_end_sha:"",finalize_historical:false}' >"$WORK/scope-request.json"
mkdir "$WORK/wave-input"
# Function source paths now point at the separate trusted fixture checkout.
. "$CANON/scripts/phase-4b/immutable-input.sh"
p4b_capture_input fixture/repo 1753 "$BASE" "$HEAD_A" "$WORK/wave-input"
# Caller overrides and dirty source files must not alter pinned scope or bytes.
printf 'dirty canonical bytes MUST NOT BE REVIEWED\n' >"$CANON/file"
export WAVE_AUDIT_MANIFEST_RELPATH=attacker.yml WAVE_AUDIT_REPO_DIR=/nonexistent
export XDG_CONFIG_HOME="$WORK/auth-home/.config" INPUT_REQUIRE_AUTH_CONTEXT=1 INPUT_AUTH_SOURCE=stored
unset GH_CONFIG_DIR
if p4b_capture_wave_input fixture/repo 1753 "$BASE" "$HEAD_A" "$WORK/scope-request.json" "$WORK/wave-input" "$WORK/wave-policy.yml"; then
 pass 'curated canonical range is regenerated independently of the canary diff'
else fail 'trusted curated regeneration'; fi
unset WAVE_AUDIT_MANIFEST_RELPATH WAVE_AUDIT_REPO_DIR
if grep -q 'wave auth preserved' "$INPUT_WORK/auth-boundaries"; then
 pass 'isolated wave subprocess retains the original gh configuration'
else fail 'wave gh auth context lost'; fi
"$INPUT_REAL_GIT" -C "$CANON" diff "$SOURCE_BASE" "$SOURCE_HEAD" -- file >"$WORK/curated-expected.diff"
if cmp -s "$WORK/wave-input/review.diff" "$WORK/curated-expected.diff" \
   && cmp -s "$WORK/wave-input/pr.diff" "$WORK/expected.diff"; then
 pass 'curated bytes exclude configured paths and preserve the complete canary diff'
else fail 'curated byte derivation'; fi
WAVE_BOUND="$(p4b_bind_input "$WORK/wave-input/input.json" "$WORK/wave-input/review.diff" "$WORK/wave-input/review.diff" "$VERDICT")"
if p4b_validate_bound_input "$WAVE_BOUND" "$WORK/wave-input/input.json" "$WORK/wave-input/review.diff" \
   && p4b_revalidate_input fixture/repo 1753 "$WORK/wave-input"; then
 pass 'curated binding preserves source scope, PR tuple and transition generation'
else fail 'curated binding'; fi
jq --arg head "$SOURCE_BASE" '.canonical_head_sha=$head' "$WORK/scope-request.json" >"$WORK/wrong-scope.json"
if p4b_capture_wave_input fixture/repo 1753 "$BASE" "$HEAD_A" "$WORK/wrong-scope.json" "$WORK/wave-input" "$WORK/wave-policy.yml"; then
 fail 'unverified canonical source accepted'
else pass 'curated request cannot substitute a different canonical head'; fi
: >"$WORK/proof-fails"
if p4b_capture_wave_input fixture/repo 1753 "$BASE" "$HEAD_A" "$WORK/scope-request.json" "$WORK/wave-input" "$WORK/wave-policy.yml"; then
 fail 'failed live byte proof accepted'
else pass 'curated input fails closed without live canary byte proof'; fi
rm "$WORK/proof-fails"
# Execute the production verifier for an enabled hub / opted-out consumer.
# A refusal must happen before Git verification or curated regeneration.
mkdir -p "$CANON/scripts/lib"
cp "$ROOT/scripts/lib/feedback-policy-helpers.sh" "$CANON/scripts/lib/"
cp "$ROOT/scripts/workflow/verify-live-propagation.sh" "$CANON/scripts/workflow/"
mkdir "$WORK/disabled-input"
p4b_capture_input fixture/repo 1753 "$BASE" "$HEAD_A" "$WORK/disabled-input"
cp "$INPUT_WORK/git-calls" "$WORK/git-calls-before-disabled"
cp "$INPUT_WORK/auth-boundaries" "$WORK/wave-calls-before-disabled"
printf 'propagation_prs:\n  enabled: false\n' >"$INPUT_WORK/consumer-policy.yml"
if p4b_capture_wave_input fixture/repo 1753 "$BASE" "$HEAD_A" "$WORK/scope-request.json" "$WORK/disabled-input" "$WORK/wave-policy.yml"; then
 fail 'hub policy overrode the consumer exemption opt-out'
elif cmp -s "$INPUT_WORK/git-calls" "$WORK/git-calls-before-disabled" \
  && cmp -s "$INPUT_WORK/auth-boundaries" "$WORK/wave-calls-before-disabled" \
  && grep -Fq "contents/.github/review-policy.yml?ref=$BASE" "$INPUT_WORK/gh-calls"; then
 pass 'exact consumer base policy disables curated capture before Git or wave dispatch'
else fail 'consumer opt-out refused through the wrong boundary'; fi
: > "$INPUT_WORK/policy-fails"
if p4b_capture_wave_input fixture/repo 1753 "$BASE" "$HEAD_A" "$WORK/scope-request.json" "$WORK/disabled-input" "$WORK/wave-policy.yml"; then
 fail 'unreadable consumer policy fell back to the hub'
else pass 'unreadable exact consumer policy refuses curated capture'; fi
rm "$INPUT_WORK/policy-fails"
chmod 600 "$WORK/wave-input/pr.diff"
printf 'tampered PR bytes\n' >>"$WORK/wave-input/pr.diff"
if p4b_revalidate_input fixture/repo 1753 "$WORK/wave-input"; then
 fail 'tampered complete PR diff accepted'
else pass 'curated review also fences the complete canary diff digest'; fi
else
 printf 'SKIP: curated-wave fixture is hub-only\n'
fi
# Exercise the real collector's allocation failure without provider access.
INPUT_REAL_MKTEMP="$(command -v mktemp)"
export INPUT_REAL_MKTEMP
cat > "$WORK/bin/mktemp" <<'SH'
#!/usr/bin/env bash
case "$*" in *p4b-evidence-input.*) exit 1 ;; esac
exec "$INPUT_REAL_MKTEMP" "$@"
SH
cat > "$WORK/bin/evidence-codex" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = --version ] || exit 99
printf 'fixture-codex 1\n'
SH
chmod +x "$WORK/bin/mktemp" "$WORK/bin/evidence-codex"
printf '{"auth_mode":"chatgpt"}\n' > "$WORK/evidence-auth.json"
printf 'phase_4b_automation: {enabled: true}\n' > "$WORK/evidence-policy.yml"
cp "$WORK/gh-calls" "$WORK/gh-calls-before-evidence"
rc=0
out=$(env -u OPENAI_API_KEY -u CODEX_API_KEY -u ANTHROPIC_API_KEY -u ANTHROPIC_AUTH_TOKEN \
  MERGEPATH_REVIEW_POLICY_PATH="$WORK/evidence-policy.yml" P4B_CODEX_AUTH_FILE="$WORK/evidence-auth.json" \
  CODEX_BIN="$WORK/bin/evidence-codex" CLAUDE_BIN="$WORK/missing-claude" \
  bash "$ROOT/scripts/phase-4b/collect-enablement-evidence.sh" --json --pr 1753 --repo fixture/repo) || rc=$?
if [ "$rc" = 1 ] && printf '%s' "$out" | jq -e '.ready == false and (.adapters.codex.dry_run | contains("immutable PR input unavailable"))' >/dev/null \
  && cmp -s "$WORK/gh-calls" "$WORK/gh-calls-before-evidence"; then
 pass 'collector allocation failure emits BLOCKED without GitHub reads or adapter dispatch'
else fail "collector allocation failure rc=$rc: $out"; fi
rm "$WORK/bin/mktemp"

# Execute the exact propagated test with only its declared consumer closure.
# The child has no hub marker or wave tool, so it cannot recurse into this arm.
if [ -f "$ROOT/scripts/sync-to-downstream.sh" ]; then
 CONSUMER="$WORK/consumer-root"
 mkdir -p "$CONSUMER/scripts" "$CONSUMER/tests"
 cp -R "$ROOT/scripts/phase-4b" "$CONSUMER/scripts/"
 cp "$ROOT/tests/test_phase_4b_immutable_input.sh" "$CONSUMER/tests/"
 if PATH="$INPUT_BASE_PATH" bash "$CONSUMER/tests/test_phase_4b_immutable_input.sh" >"$WORK/consumer.log" 2>&1 \
   && grep -Fq 'PASS: authorized unchanged input survives the generation fence' "$WORK/consumer.log" \
   && grep -Fq 'PASS: observed A-B-A generation refuses unchanged final A' "$WORK/consumer.log" \
   && grep -Fq 'SKIP: curated-wave fixture is hub-only' "$WORK/consumer.log"; then
  pass 'declared consumer closure runs core assertions without hub-only wave tooling'
 else
  cat "$WORK/consumer.log" >&2
  fail 'propagated consumer immutable-input test'
 fi
fi

printf '\ntest_phase_4b_immutable_input: %s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
