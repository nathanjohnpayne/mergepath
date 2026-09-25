#!/usr/bin/env bash
# op-preflight.sh — Front-load all 1Password credential reads for a session.
#
# Triggers biometric prompts once at the start, then writes resolved secrets
# to a chmod-600 session file under $XDG_CACHE_HOME/mergepath/ (default
# $HOME/.cache/mergepath/). Subsequent invocations within the TTL window
# read the session file and emit the same export statements WITHOUT
# triggering biometric.
#
# This is what makes the script usable from agent drivers (Claude Code,
# Cursor, Codex CLI) where each tool call spawns a fresh subshell and
# cannot see env vars exported by a prior call. The first tool call in a
# session warms the cache (one biometric prompt); every subsequent tool
# call reuses the session file until it rotates. See
# nathanjohnpayne/mergepath#139 for the observed failure mode that
# motivated this design.
#
# Usage:
#   # Session start (one biometric burst) — review mode is the default:
#   eval "$(scripts/op-preflight.sh --agent claude --mode review)"
#
#   # Idempotent re-check at the top of every subsequent tool call. NEVER
#   # prompts for biometric; exits non-zero if no fresh cache exists:
#   eval "$(scripts/op-preflight.sh --agent claude --check --print-exports)"
#
#   # Force a fresh fetch even if the session file is still warm:
#   eval "$(scripts/op-preflight.sh --agent claude --refresh)"
#
#   # Deploy scripts that genuinely need deploy credentials:
#   eval "$(scripts/op-preflight.sh --agent claude --mode deploy)"
#
#   # Delete the session file + ADC tempfile (end-of-session cleanup):
#   scripts/op-preflight.sh --agent claude --purge
#
# Modes:
#   review  — reviewer PAT + author PAT + SSH key warming (DEFAULT)
#   deploy  — Firebase project SA key (when .firebaserc is present),
#             else GCP ADC credential + Cloudflare cache-purge token
#   all     — everything
#
# Flags:
#   --agent <name>   Agent name: claude, cursor, or codex (required except --purge-all)
#   --mode <mode>    review, deploy, or all (default: review). #282
#   --check          Validate the session file is fresh, WITHOUT invoking
#   --status         (alias for --check) op. Never burns biometric, never
#                    warms SSH, never reads ADC. Exits non-zero if cache
#                    missing/stale. Mutually exclusive with --refresh,
#                    --purge, --purge-all. #282
#                    Writes NO credential material to stdout or stderr on
#                    any exit path (#1021): the status line goes to stderr
#                    and the cached exports are emitted only when
#                    --print-exports is also passed. Running it bare is
#                    the liveness check; it is safe in a transcript.
#   --print-exports  With --check, print the cached `export OP_PREFLIGHT_*`
#                    statements on stdout for `eval "$(...)"`. Meaningless
#                    elsewhere: --mode review/deploy/all and --refresh are
#                    deliberate export paths and still print by default.
#   --dry-run        Show what would be fetched without prompting
#   --skip-ssh       Skip SSH key warming (useful in CI or non-interactive)
#   --refresh        Force biometric fetch even if session file is fresh
#   --purge          Delete session file + ADC tempfile for the given --agent
#   --purge-all      Delete ALL session files + ADC tempfiles under the cache dir
#
# Environment:
#   OP_PREFLIGHT_TTL_SECONDS  Override default TTL (36000s = 10h; raised
#                             from 4h in #765). Shortens or lengthens the
#                             window. Age is measured against the session
#                             file's embedded timestamp, not file mtime,
#                             so `touch`-ing the file does NOT extend its
#                             effective lifetime.
#   OP_PREFLIGHT_CACHE_DIR    Override cache dir (default
#                             $XDG_CACHE_HOME/mergepath or $HOME/.cache/mergepath).
#   OP_PREFLIGHT_SSH_WARM_TTL_SECONDS
#                             Override SSH-warm freshness window (default
#                             1800s = 30 min). Independent of the PAT
#                             cache TTL because the 1Password SSH agent
#                             has its own session lifetime, typically
#                             much shorter than 10h — it does NOT move
#                             with the PAT TTL. Skipping re-warm within
#                             this window prevents a biometric prompt on
#                             every cache-hit invocation. See #163.
#   OP_PREFLIGHT_DEPLOY_DEGRADED_BACKOFF_SECONDS
#                             How long a `--mode all` cache written without
#                             deploy credentials (no Firebase SA, no usable
#                             ADC) satisfies later `--mode all` hits in the
#                             same Firebase-project context before a fresh
#                             fetch retries (default 900s = 15 min).
#                             `--mode deploy` never accepts it.
#   OP_PREFLIGHT_QUIET        When set to 1, suppress the verbose
#                             cached-hit stderr block. A single-line
#                             "# preflight: cache hit, no biometric
#                             burned" message replaces it. Refresh
#                             notices and warnings are unaffected. #282
#   OP_SERVICE_ACCOUNT_TOKEN  Explicit CI/headless lane. When set,
#                             review mode reads ONLY the scoped reviewer
#                             PAT through the 1Password CLI service-
#                             account auth path. Author PAT, deploy
#                             secrets, SSH warming, and gh keyring
#                             repair stay out of scope.
#   OP_PREFLIGHT_REVIEWER_PAT_REF
#                             Required op://vault/item/field reference for
#                             the reviewer PAT in service-account token
#                             mode. Must point to a service-account-
#                             accessible vault; Private/Personal vaults
#                             are rejected before op read.
#
# Session file:
#   Path:        $cache_dir/op-preflight-<agent>.env
#   Permissions: 600 (owner read/write only)
#   Format:      bash-sourceable KEY='value' lines (printf %q-escaped)
#   TTL anchor:  OP_PREFLIGHT_CREATED_AT_EPOCH (embedded in file, not mtime)
#   Deploy creds: per Firebase-project context in
#                $cache_dir/op-preflight-<agent>-deploy-<fb-project|adc>.slot
#                (own TTL anchor OP_PREFLIGHT_DEPLOY_CREATED_AT_EPOCH), SA
#                keys in op-preflight-<agent>-firebase-sa-fb-<project>.json
#
# After eval, downstream gh usage is token-first (see REVIEW_POLICY.md
# § Reviewer PAT Quick Start):
#
#   # Read-path: GH_TOKEN authenticates the request (no byline involved).
#   GH_TOKEN="$OP_PREFLIGHT_REVIEWER_PAT" gh api user --jq .login
#   GH_TOKEN="$OP_PREFLIGHT_REVIEWER_PAT" scripts/codex-review-check.sh <PR#>
#
#   # Helpers use cached PATs so repeated checks do not prompt.
#   GH_TOKEN="$OP_PREFLIGHT_REVIEWER_PAT" scripts/coderabbit-wait.sh <PR#>
#   scripts/codex-review-request.sh <PR#>  # auto-sources the author token for the trigger
#
#   # Write-path: wrappers verify the selected token immediately before
#   # the command, set process-local GH_TOKEN, and never mutate gh state.
#   GH_AS_REVIEWER_IDENTITY=nathanpayne-<agent> \
#     scripts/gh-as-reviewer.sh -- gh pr review <PR#> --comment --body "..."
#   scripts/gh-as-author.sh -- gh pr merge <PR#> --squash --delete-branch
#
#   # gcloud/firebase use GOOGLE_APPLICATION_CREDENTIALS automatically.

set -eo pipefail
umask 077  # Restrict file permissions before any mktemp/cache writes

# ── PAT lookup table ──────────────────────────────────────────────────
# Must match REVIEW_POLICY.md § PAT lookup table.
AUTHOR_PAT_ITEM="sm5kopwk6t6p3xmu2igesndzhe"

reviewer_pat_item_for() {
  case "$1" in
    claude) echo "pvbq24vl2h6gl7yjclxy2hbote" ;;
    cursor) echo "bslrih4spwxgookzfy6zedz5g4" ;;
    codex)  echo "etak327mpz4drd4byxszfex4vm" ;;
    *)      return 1 ;;
  esac
}

reviewer_pat_ref_for() {
  local item
  item="$(reviewer_pat_item_for "$1")" || return 1
  printf '%s\n' "${OP_PREFLIGHT_REVIEWER_PAT_REF:-op://Private/${item}/token}"
}

is_op_secret_ref() {
  case "$1" in
    op://*/*/*) return 0 ;;
    *) return 1 ;;
  esac
}

is_private_or_personal_ref() {
  case "$1" in
    op://Private/*|op://Personal/*) return 0 ;;
    *) return 1 ;;
  esac
}

ssh_host_for() {
  case "$1" in
    claude) echo "github-claude" ;;
    cursor) echo "github-cursor" ;;
    codex)  echo "github-codex" ;;
    *)      return 1 ;;
  esac
}

# ── Cache layout ──────────────────────────────────────────────────────
# Cache directory is intentionally shared across all consumer repos and is
# NOT namespaced per repo. The session file is keyed by --agent (see
# SESSION_FILE below), and each agent's credentials are per-identity and
# machine-wide: one reviewer PAT per agent, not per-repo (see CLAUDE.md /
# REVIEW_POLICY.md PAT lookup table). So the same agent's cached token is
# identical regardless of which repo invoked preflight — a shared,
# agent-keyed cache is correct today and a per-repo cache would only
# duplicate identical material.
#
# Per-repo namespacing (e.g. $HOME/.cache/mergepath/$REPO) is a DEFERRED
# fleet-wide architecture decision (mergepath#532), to revisit only if any
# consumer ever needs a repo-scoped PAT for the same agent. Until then, do
# NOT namespace this path — it would fragment the cache and multiply the
# biometric burst across repos for no security gain.
DEFAULT_CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/mergepath"
CACHE_DIR="${OP_PREFLIGHT_CACHE_DIR:-$DEFAULT_CACHE_DIR}"
DEFAULT_TTL_SECONDS=36000  # 10 hours
TTL_SECONDS="${OP_PREFLIGHT_TTL_SECONDS:-$DEFAULT_TTL_SECONDS}"

# How long a `--mode all` fetch that could NOT load a deploy credential
# (no Firebase SA key for this project and no usable GCP ADC) is reused by
# later `--mode all` cache hits before a fresh fetch retries it. Without
# this window every `--mode all` hit re-fetched (the cache has no
# GOOGLE_APPLICATION_CREDENTIALS), re-prompted biometric, wrote the same
# degraded cache, and looped: 39 Touch ID prompts in ~1h on 2026-09-24.
# Short on purpose — a human who fixes ADC is picked up within the window,
# and --refresh retries immediately.
DEFAULT_DEPLOY_DEGRADED_BACKOFF_SECONDS=900  # 15 min
DEPLOY_DEGRADED_BACKOFF_SECONDS="${OP_PREFLIGHT_DEPLOY_DEGRADED_BACKOFF_SECONDS:-$DEFAULT_DEPLOY_DEGRADED_BACKOFF_SECONDS}"
if [[ ! "$DEPLOY_DEGRADED_BACKOFF_SECONDS" =~ ^[0-9]+$ ]]; then
  echo "# WARNING: OP_PREFLIGHT_DEPLOY_DEGRADED_BACKOFF_SECONDS='$DEPLOY_DEGRADED_BACKOFF_SECONDS' is not a non-negative integer; falling back to default ${DEFAULT_DEPLOY_DEGRADED_BACKOFF_SECONDS}s" >&2
  DEPLOY_DEGRADED_BACKOFF_SECONDS=$DEFAULT_DEPLOY_DEGRADED_BACKOFF_SECONDS
fi
# Force decimal: `0900` passes the digit check but is invalid octal in
# arithmetic, which would silently turn every hit into a retry.
DEPLOY_DEGRADED_BACKOFF_SECONDS=$(( 10#$DEPLOY_DEGRADED_BACKOFF_SECONDS ))

# ── GCP ADC ───────────────────────────────────────────────────────────
DEFAULT_ADC_OP_URI="${GCP_ADC_OP_URI:-op://Private/c2v6emkwppjzjjaq2bdqk3wnlm/credential}"

# ── Firebase deploy SA key ────────────────────────────────────────────
SA_NAME="${FIREBASE_DEPLOY_SA_NAME:-firebase-deployer}"
FIREBASE_SA_VAULT="${FIREBASE_SA_VAULT:-Firebase}"

# ── Cloudflare Cache Purge token (#167) ───────────────────────────────
# Shared API token with Purge:Edit permission across all domains. Wired
# into preflight so scripts/deploy.sh's existing CF purge step
# (currently no-op when CF_API_TOKEN is unset) actually fires on
# agent-driven deploys without an extra biometric prompt. CF_ZONE_ID
# is intentionally NOT sourced here — it's per-repo and lives in each
# downstream consumer's own bootstrap, not in this shared wiring.
DEFAULT_CF_TOKEN_OP_URI="${CF_TOKEN_OP_URI:-op://Private/4x6wslp3f6pal5t6h3jhhe63ie/credential}"
SSH_AUTHOR_HOST="github.com"

# ── Parse arguments ───────────────────────────────────────────────────
# Default --mode is `review` (was `all` prior to #282). The vast majority
# of agent tool calls only need the reviewer/author PATs + SSH warming;
# loading ADC + Cloudflare on every preflight bloated the biometric
# burst for no reason. Deploy scripts that genuinely need deploy
# credentials must pass `--mode deploy` or `--mode all` explicitly.
AGENT=""
MODE="review"
DRY_RUN=false
SKIP_SSH=false
REFRESH=false
PURGE=false
PURGE_ALL=false
CHECK=false
PRINT_EXPORTS=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --agent)  AGENT="$2"; shift 2 ;;
    --mode)   MODE="$2"; shift 2 ;;
    --dry-run) DRY_RUN=true; shift ;;
    --skip-ssh) SKIP_SSH=true; shift ;;
    --refresh) REFRESH=true; shift ;;
    --purge) PURGE=true; shift ;;
    --purge-all) PURGE_ALL=true; shift ;;
    --check|--status) CHECK=true; shift ;;
    --print-exports) PRINT_EXPORTS=true; shift ;;
    *)
      echo "Error: unknown argument: $1" >&2
      echo "Usage: eval \"\$(scripts/op-preflight.sh --agent claude --mode review)\"" >&2
      exit 1
      ;;
  esac
done

# ── --check / --status mutual exclusion (#282) ────────────────────────
# --check is the "never invoke op, never warm SSH, never touch ADC"
# read-only validator. It is mutually exclusive with anything that
# would mutate state or burn biometric.
if $CHECK; then
  if $REFRESH || $PURGE || $PURGE_ALL; then
    echo "Error: --check / --status is mutually exclusive with --refresh, --purge, --purge-all." >&2
    exit 1
  fi
fi

# ── Validate ──────────────────────────────────────────────────────────
if $PURGE_ALL; then
  if [[ -d "$CACHE_DIR" ]]; then
    echo "# Purging all session files under $CACHE_DIR" >&2
    find "$CACHE_DIR" -maxdepth 1 -type f \( -name 'op-preflight-*.env' -o -name 'op-preflight-*-adc.json' -o -name 'op-preflight-*-firebase-sa*.json' -o -name 'op-preflight-*.staged.*' -o -name 'op-preflight-*-deploy-*.slot' -o -name 'op-preflight-*.ssh-warmed' \) -print -delete >&2
  fi
  exit 0
fi

# --agent is required for every mode except --purge-all (handled above).
# `deploy` MUST stay in this gate: cache paths are unconditionally
# $AGENT-interpolated (op-preflight-$AGENT.env / -adc.json /
# -firebase-sa.json), so `--mode deploy` with no --agent writes a shared
# anonymous ("") bucket that `--purge --agent <name>` can never reclaim and
# that concurrent agent sessions clobber. This was added in #259, silently
# dropped by a bulk sync, and restored in #534 — the regression test
# test_deploy_mode_requires_agent guards against another drop.
if [[ "$MODE" == "review" || "$MODE" == "all" || "$MODE" == "deploy" || "$PURGE" == "true" || "$CHECK" == "true" ]] && [[ -z "$AGENT" ]]; then
  echo "Error: --agent is required for review, deploy, all, --purge, or --check mode." >&2
  echo "Usage: eval \"\$(scripts/op-preflight.sh --agent claude --mode review)\"" >&2
  exit 1
fi

if [[ -n "$AGENT" ]] && [[ -z "$(reviewer_pat_item_for "$AGENT" 2>/dev/null || true)" ]]; then
  echo "Error: unknown agent '$AGENT'. Valid: claude, cursor, codex" >&2
  exit 1
fi

if ! [[ "$TTL_SECONDS" =~ ^[0-9]+$ ]]; then
  echo "Error: OP_PREFLIGHT_TTL_SECONDS must be an integer; got '$TTL_SECONDS'" >&2
  exit 1
fi

SERVICE_ACCOUNT_TOKEN_MODE=false
if [[ -n "${OP_SERVICE_ACCOUNT_TOKEN:-}" ]]; then
  SERVICE_ACCOUNT_TOKEN_MODE=true
fi

# ── Cache paths (deterministic per agent) ─────────────────────────────
SESSION_FILE="$CACHE_DIR/op-preflight-$AGENT.env"
ADC_TMPFILE="$CACHE_DIR/op-preflight-$AGENT-adc.json"
SSH_WARM_MARKER="$CACHE_DIR/op-preflight-$AGENT.ssh-warmed"
BIOMETRIC_LOG="$CACHE_DIR/biometric-log"  # #282: append a one-line
                                          # record on each fresh fetch.
SSH_WARM_TTL_SECONDS="${OP_PREFLIGHT_SSH_WARM_TTL_SECONDS:-1800}"  # 30 min default; #163

# ── Clearing deploy variables in the CALLER's shell ───────────────────
# Emitted (and evaluated by the caller) before any deploy export, on review
# hits, deploy/all hits, full fetches and deploy failures. It clears the
# preflight markers unconditionally, but clears
# GOOGLE_APPLICATION_CREDENTIALS only when a preflight marker in that shell
# proves preflight put it there: a value with no matching marker is the
# human override DEPLOYMENT.md ranks first (Codex on #1318), and a degraded
# or failed run must not erase it. It runs in the caller (bash or zsh), so
# it is plain POSIX test syntax.
# shellcheck disable=SC2016  # expands in the caller's shell, by design
DEPLOY_CLEAR_STMT='if [ -n "${GOOGLE_APPLICATION_CREDENTIALS:-}" ] && { [ "$GOOGLE_APPLICATION_CREDENTIALS" = "${OP_PREFLIGHT_ADC_TMPFILE:-}" ] || [ "$GOOGLE_APPLICATION_CREDENTIALS" = "${OP_PREFLIGHT_FIREBASE_SA_TMPFILE:-}" ]; }; then unset GOOGLE_APPLICATION_CREDENTIALS; fi; unset OP_PREFLIGHT_ADC_TMPFILE OP_PREFLIGHT_FIREBASE_SA_TMPFILE OP_PREFLIGHT_FIREBASE_PROJECT'
# CF_API_TOKEN carries no ownership marker and is one shared purge token, not
# a per-project identity, so deploy/all output only ever (re)exports it and
# never clears it: an ambient token survives a run whose optional 1Password
# read failed (Codex on #1318). A review-mode request keeps #466's behavior
# of clearing every deploy variable, CF_API_TOKEN included.
REVIEW_CLEAR_STMT="$DEPLOY_CLEAR_STMT; unset CF_API_TOKEN"

# ── Deploy-credential slots (one per Firebase-project context) ────────
# Deploy credentials are cached per context, not per agent: one slot per
# Firebase project (with its own SA key file), plus one `adc` slot for
# checkouts with no .firebaserc. Everything the deploy phase fetches
# (including CF_API_TOKEN) lives in the slot, so a later `--mode review`
# rewrite of the main session file (PATs only) cannot strip part of it.
#
# A single per-agent slot made concurrent sessions in two Firebase repos
# (e.g. nathanpaynedotcom and fiveacross/gaycruisebingo, both `--mode all`
# as claude) evict each other: each run saw the other project's cached key,
# treated the mismatch as a miss, re-fetched with a biometric prompt, and
# overwrote the one shared key file -- under the PATH the other session had
# already exported as GOOGLE_APPLICATION_CREDENTIALS. Per-context slots end
# both the ping-pong and that cross-project key swap.
deploy_context_slug() { # <firebase_project or "">
  if [[ -z "${1:-}" ]]; then
    printf 'adc'
  else
    # GCP project ids are [a-z0-9-]; anything else is folded to `_`. A
    # fold collision is harmless: the slot records its exact context and
    # a mismatch is a cache miss.
    printf 'fb-%s' "$(printf '%s' "$1" | tr -c 'A-Za-z0-9-' '_')"
  fi
}
deploy_slot_file_for() { # <firebase_project or "">
  # `.slot`, never `.env`: scripts/lib/preflight-helpers.sh discovers the
  # agent from the single `op-preflight-*.env` in the cache dir, and a slot
  # matching that glob would break helper auto-sourcing after any deploy run.
  printf '%s/op-preflight-%s-deploy-%s.slot' "$CACHE_DIR" "$AGENT" "$(deploy_context_slug "${1:-}")"
}
# The ONE context selector for slots, used identically by the full-fetch
# writer, the cache-hit reader, and --check. It is the probe-free parser, so
# a host with no (or a broken) python3 cannot write one slot and then check
# another. (detect_firebase_project stays for the pre-slot validation path.)
deploy_context_project() {
  detect_firebase_project_no_python
}
firebase_sa_file_for() { # <firebase_project>
  printf '%s/op-preflight-%s-firebase-sa-%s.json' "$CACHE_DIR" "$AGENT" "$(deploy_context_slug "$1")"
}

detect_firebase_project() {
  if [[ -n "${OP_PREFLIGHT_FIREBASE_PROJECT_ID:-}" ]]; then
    printf '%s\n' "$OP_PREFLIGHT_FIREBASE_PROJECT_ID"
    return 0
  fi
  [[ -f .firebaserc ]] || return 1
  command -v python3 >/dev/null 2>&1 || return 1
  python3 - <<'PY'
import json
import pathlib
import sys

try:
    project = json.loads(pathlib.Path(".firebaserc").read_text())["projects"]["default"]
except Exception:
    sys.exit(1)
# A project containing control characters (newline, NUL, ...) is not a
# usable Firebase project id and must never reach a cache file or a vault
# item name; both .firebaserc parsers reject it identically.
if not isinstance(project, str) or not project or any(ord(ch) < 32 or ord(ch) == 127 for ch in project):
    sys.exit(1)
print(project)
PY
}

json_string_field_no_python() {
  local file="${1:-}" field="${2:-}"
  [[ -n "$file" && -f "$file" && -n "$field" ]] || return 1
  awk -v field="$field" '
    { text = text $0 " " }
    END {
      pattern = "\"" field "\"[[:space:]]*:[[:space:]]*\"[^\"]+\""
      if (!match(text, pattern)) {
        exit 1
      }
      matched = substr(text, RSTART, RLENGTH)
      if (split(matched, parts, "\"") < 4) {
        exit 1
      }
      print parts[4]
    }
  ' "$file"
}

# Root `projects.default` of .firebaserc, without python3. This is the
# deploy-slot context selector (deploy_context_project), so it must read the
# SAME value as the python parser and the Firebase CLI: a textual first-match
# regex picked a nested "projects" object that preceded the root one and
# cached another project's key (Codex on #1318). So this is a small JSON
# scanner, not a regex: it tracks string/escape state and nesting depth,
# reads `default` only from a depth-1 "projects" object, and mirrors
# json.loads duplicate-key semantics (the last root "projects" and the last
# "default" in it win; a non-string or empty default is no project). String
# escapes are decoded like json.loads (\uXXXX -> UTF-8, surrogate pairs
# joined; LC_ALL=C so %c emits raw bytes in every awk); a lone surrogate,
# which python cannot print, yields no project (and in a KEY never aliases
# an ordinary key); an escaped NUL is treated the same way, since awk cannot
# represent it. A project containing any control character is rejected by
# both parsers. It is ALSO a strict JSON
# validator (grammar, trailing input, number/literal forms including
# json.loads' NaN/Infinity, raw control characters, UTF-8 validity): a
# malformed or truncated .firebaserc selects no project, as python and the
# Firebase CLI reject it, rather than whatever prefix looked valid.
firebaserc_default_project_no_python() {
  [[ -f .firebaserc ]] || return 1
  LC_ALL=C awk '
    function hexval(h,    k, d, v) {
      if (length(h) != 4) return -1
      v = 0
      for (k = 1; k <= 4; k++) {
        d = index("0123456789abcdef", tolower(substr(h, k, 1)))
        if (d == 0) return -1
        v = v * 16 + d - 1
      }
      return v
    }
    function utf8(cp) {
      if (cp < 128) return sprintf("%c", cp)
      if (cp < 2048) return sprintf("%c%c", 192 + int(cp / 64), 128 + cp % 64)
      if (cp < 65536) return sprintf("%c%c%c", 224 + int(cp / 4096), 128 + int(cp / 64) % 64, 128 + cp % 64)
      return sprintf("%c%c%c%c", 240 + int(cp / 262144), 128 + int(cp / 4096) % 64, 128 + int(cp / 64) % 64, 128 + cp % 64)
    }
    # Consumed one scalar/container value at the current depth.
    function after_value() {
      if (depth == 0) expect = "done"
      else if (st[depth] == "o") expect = "comma_or_end_o"
      else expect = "comma_or_end_a"
    }
    function is_value_state() { return expect == "value" || expect == "value_or_end_a" }
    BEGIN { for (b = 1; b < 256; b++) ord[sprintf("%c", b)] = b }
    { text = text $0 "\n" }
    END {
      n = length(text); depth = 0; expect = "value"
      proj_depth = 0; val = ""; seen = 0
      for (i = 1; i <= n; i++) {
        c = substr(text, i, 1)
        if (c == " " || c == "\t" || c == "\n" || c == "\r") continue
        if (expect == "done") exit 1
        if (c == "\"") {
          # String token: decode escapes, reject raw control chars and
          # invalid UTF-8 (python reads the file as UTF-8 and json.loads is
          # strict about control characters).
          str = ""; bad = 0; closed = 0
          for (i++; i <= n; i++) {
            c = substr(text, i, 1); o = ord[c]
            if (c == "\"") { closed = 1; break }
            if (o < 32) exit 1
            if (c == "\\") {
              i++; c = substr(text, i, 1)
              if (c == "u") {
                cp = hexval(substr(text, i + 1, 4))
                if (cp < 0) exit 1
                i += 4
                if (cp >= 55296 && cp <= 56319) {
                  lo = (substr(text, i + 1, 2) == "\\u") ? hexval(substr(text, i + 3, 4)) : -1
                  if (lo >= 56320 && lo <= 57343) { cp = 65536 + (cp - 55296) * 1024 + (lo - 56320); i += 6 }
                  else { bad = 1; continue }
                } else if (cp >= 56320 && cp <= 57343) { bad = 1; continue }
                if (cp == 0) { bad = 1; continue }
                str = str utf8(cp)
              }
              else if (c == "\"" || c == "\\" || c == "/") str = str c
              else if (c == "n") str = str "\n"
              else if (c == "t") str = str "\t"
              else if (c == "r") str = str "\r"
              else if (c == "b") str = str "\b"
              else if (c == "f") str = str "\f"
              else exit 1
              continue
            }
            if (o >= 128) {
              if (o >= 194 && o <= 223) { need = 1; lo_b = 128; hi_b = 191 }
              else if (o == 224) { need = 2; lo_b = 160; hi_b = 191 }
              else if ((o >= 225 && o <= 236) || o == 238 || o == 239) { need = 2; lo_b = 128; hi_b = 191 }
              else if (o == 237) { need = 2; lo_b = 128; hi_b = 159 }
              else if (o == 240) { need = 3; lo_b = 144; hi_b = 191 }
              else if (o >= 241 && o <= 243) { need = 3; lo_b = 128; hi_b = 191 }
              else if (o == 244) { need = 3; lo_b = 128; hi_b = 143 }
              else exit 1
              seq = c
              for (k = 1; k <= need; k++) {
                cb = ord[substr(text, i + k, 1)]
                if (k == 1 && (cb < lo_b || cb > hi_b)) exit 1
                if (k > 1 && (cb < 128 || cb > 191)) exit 1
                seq = seq substr(text, i + k, 1)
              }
              i += need; str = str seq
              continue
            }
            str = str c
          }
          if (!closed) exit 1
          if (expect == "key_or_end" || expect == "key") {
            # A key holding a lone surrogate is a distinct key to json.loads;
            # prefix a byte no decoded string can contain (0xFF is never
            # valid UTF-8) so it can never alias "projects" or "default".
            keys[depth] = (bad ? "\377" str : str); expect = "colon"
            continue
          }
          if (!is_value_state()) exit 1
          if (st[depth] == "o" && depth == proj_depth && keys[depth] == "default") val = (bad ? "" : str)
          if (depth == 1 && st[1] == "o" && keys[1] == "projects") { val = ""; seen = 1 }
          after_value()
          continue
        }
        if (c == "{" || c == "[") {
          if (!is_value_state()) exit 1
          if (depth == 1 && st[1] == "o" && keys[1] == "projects") {
            val = ""; seen = 1
            if (c == "{") proj_depth = 2
          }
          depth++; st[depth] = (c == "{") ? "o" : "a"; keys[depth] = ""
          expect = (c == "{") ? "key_or_end" : "value_or_end_a"
          continue
        }
        if (c == "}" || c == "]") {
          if (c == "}" && expect != "key_or_end" && expect != "comma_or_end_o") exit 1
          if (c == "]" && expect != "value_or_end_a" && expect != "comma_or_end_a") exit 1
          if (depth == proj_depth) proj_depth = 0
          depth--
          after_value()
          continue
        }
        if (c == ":") {
          if (expect != "colon") exit 1
          if (depth == proj_depth && keys[depth] == "default") val = ""
          expect = "value"
          continue
        }
        if (c == ",") {
          if (expect == "comma_or_end_o") expect = "key"
          else if (expect == "comma_or_end_a") expect = "value"
          else exit 1
          continue
        }
        # Number or literal: take the maximal run and validate it exactly
        # as json.loads would (it also accepts NaN / Infinity / -Infinity).
        if (!is_value_state()) exit 1
        tok = ""
        while (i <= n && substr(text, i, 1) ~ /[A-Za-z0-9+.-]/) { tok = tok substr(text, i, 1); i++ }
        i--
        if (tok !~ /^(true|false|null|NaN|Infinity|-Infinity)$/ && \
            tok !~ /^-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][-+]?[0-9]+)?$/) exit 1
        if (depth == 1 && st[1] == "o" && keys[1] == "projects") { val = ""; seen = 1 }
        after_value()
      }
      if (expect != "done" || !seen || val == "") exit 1
      # Control characters (newline, DEL, ...) are rejected exactly as the
      # python parser rejects them: never a usable project id.
      if (val ~ /[\001-\037\177]/) exit 1
      print val
    }
  ' .firebaserc
}

detect_firebase_project_no_python() {
  if [[ -n "${OP_PREFLIGHT_FIREBASE_PROJECT_ID:-}" ]]; then
    printf '%s\n' "$OP_PREFLIGHT_FIREBASE_PROJECT_ID"
    return 0
  fi
  firebaserc_default_project_no_python
}

firebase_sa_matches_project_no_python() {
  local file="${1:-}" project="${2:-}" client_email expected
  [[ -n "$file" && -f "$file" && -s "$file" && -n "$project" ]] || return 1
  client_email="$(json_string_field_no_python "$file" "client_email" || true)"
  expected="${SA_NAME}@${project}.iam.gserviceaccount.com"
  [[ "$client_email" == "$expected" ]]
}

# Validate the override is a non-negative integer before any arithmetic
# context (`[[ "$age" -lt "$SSH_WARM_TTL_SECONDS" ]]` later in the
# script). A non-numeric override (`OP_PREFLIGHT_SSH_WARM_TTL_SECONDS=foo`)
# would otherwise abort the run under `set -e` with a "value too great
# for base" error — one bad local env value would break every cache-hit
# review. Fall back to the documented default with a warning rather
# than crashing. (CodeRabbit Major, #272.)
if [[ ! "$SSH_WARM_TTL_SECONDS" =~ ^[0-9]+$ ]]; then
  echo "# WARNING: OP_PREFLIGHT_SSH_WARM_TTL_SECONDS='$SSH_WARM_TTL_SECONDS' is not a non-negative integer; falling back to default 1800s" >&2
  SSH_WARM_TTL_SECONDS=1800
fi

# ── Biometric trigger log (#282) ──────────────────────────────────────
# Append a one-line record every time the interactive lane triggers a
# fresh op fetch (i.e. every time `op inject` or deploy `op read` is
# invoked for cache population).
# Format: `<ISO8601> agent=<agent> mode=<mode> reason=<reason>` so a
# session audit can correlate biometric prompts against agent behavior.
# Always-on (independent of OP_PREFLIGHT_QUIET) — the file is local-only
# and there's no privacy / log-volume tradeoff to suppress it for.
log_biometric_trigger() {
  local reason="${1:-full-fetch}"
  local now_iso
  now_iso=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u +%FT%TZ)
  mkdir -p "$CACHE_DIR" 2>/dev/null || true
  if [[ ! -f "$BIOMETRIC_LOG" ]]; then
    touch "$BIOMETRIC_LOG" 2>/dev/null || return 0
    chmod 600 "$BIOMETRIC_LOG" 2>/dev/null || true
  fi
  printf '%s agent=%s mode=%s reason=%s\n' \
    "$now_iso" "${AGENT:-unknown}" "${MODE:-unknown}" "$reason" \
    >> "$BIOMETRIC_LOG" 2>/dev/null || true
}

# ── Purge mode ────────────────────────────────────────────────────────
if $PURGE; then
  rm -f "$SESSION_FILE" "$ADC_TMPFILE" "$SSH_WARM_MARKER"
  # Per-project SA keys + deploy slots, and the pre-slot single SA file.
  rm -f "$CACHE_DIR/op-preflight-$AGENT-firebase-sa.json" \
        "$CACHE_DIR/op-preflight-$AGENT-firebase-sa-"*.json \
        "$CACHE_DIR/op-preflight-$AGENT-deploy-"*.slot \
        "$CACHE_DIR/op-preflight-$AGENT-"*.staged.*
  echo "# Purged session file + ADC tempfile + Firebase SA tempfiles + deploy slots + SSH-warm marker for agent=$AGENT" >&2
  exit 0
fi

if $SERVICE_ACCOUNT_TOKEN_MODE && [[ "$MODE" != "review" ]]; then
  echo "Error: OP_SERVICE_ACCOUNT_TOKEN mode is scoped to reviewer PAT reads only; mode '$MODE' is out of scope." >&2
  exit 2
fi

# ── Dry run ───────────────────────────────────────────────────────────
if $DRY_RUN; then
  echo "# op-preflight.sh --agent $AGENT --mode $MODE (dry run)" >&2
  echo "#" >&2
  echo "# Session file:   $SESSION_FILE" >&2
  echo "# ADC tempfile:   $ADC_TMPFILE" >&2
  echo "# Deploy slot:    $(deploy_slot_file_for "$(deploy_context_project 2>/dev/null || true)")" >&2
  echo "# TTL seconds:    $TTL_SECONDS" >&2
  if [[ -f "$SESSION_FILE" ]]; then
    # `|| true` so a missing epoch key doesn't take down dry-run under
    # set -e + pipefail (grep exits 1 on no match). The numeric-only
    # validation + `10#` decimal coercion below covers the OTHER bad
    # case CodeRabbit caught on PR #278: a key present with a garbage
    # value (e.g. `123abc` errors in arithmetic, or `08` is parsed as
    # invalid octal). On bad input we fall back to age=$now → huge →
    # cache miss + refresh (the correct fallback). (CodeRabbit, #272.)
    embedded=$(grep '^OP_PREFLIGHT_CREATED_AT_EPOCH=' "$SESSION_FILE" | cut -d= -f2- | tr -d "'\"" || true)
    now=$(date +%s)
    if [[ "$embedded" =~ ^[0-9]+$ ]]; then
      age=$(( now - 10#$embedded ))
    else
      age=$now
    fi
    echo "# Session age:    ${age}s (TTL ${TTL_SECONDS}s)" >&2
  else
    echo "# Session age:    n/a (no session file)" >&2
  fi
  echo "#" >&2
  if [[ "$MODE" == "review" || "$MODE" == "all" ]]; then
    if $SERVICE_ACCOUNT_TOKEN_MODE; then
      if [[ -n "${OP_PREFLIGHT_REVIEWER_PAT_REF:-}" ]]; then
        echo "# Would read: reviewer PAT ($(reviewer_pat_ref_for "$AGENT")) via OP_SERVICE_ACCOUNT_TOKEN" >&2
      else
        echo "# Would require: OP_PREFLIGHT_REVIEWER_PAT_REF (service-account-accessible op://vault/item/field)" >&2
      fi
      echo "# Would skip: author PAT (out of token-mode scope)" >&2
      echo "# Would skip: SSH warming (out of token-mode scope)" >&2
      echo "# Would skip: gh keyring repair (out of token-mode scope)" >&2
    else
      echo "# Would read: reviewer PAT ($(reviewer_pat_item_for "$AGENT"))" >&2
      echo "# Would read: author PAT ($AUTHOR_PAT_ITEM)" >&2
    fi
    if ! $SKIP_SSH && ! $SERVICE_ACCOUNT_TOKEN_MODE; then
      echo "# Would warm SSH: $SSH_AUTHOR_HOST (author key)" >&2
      echo "# Would warm SSH: $(ssh_host_for "$AGENT") (reviewer key)" >&2
    fi
  fi
  if [[ "$MODE" == "deploy" || "$MODE" == "all" ]]; then
    if firebase_project="$(deploy_context_project 2>/dev/null || true)" && [[ -n "$firebase_project" ]]; then
      echo "# Would read: Firebase project SA key (${firebase_project} — Firebase Deployer SA Key in vault ${FIREBASE_SA_VAULT})" >&2
      echo "# Would fall back to: GCP ADC ($DEFAULT_ADC_OP_URI)" >&2
    else
      echo "# Would read: GCP ADC ($DEFAULT_ADC_OP_URI)" >&2
    fi
    echo "# Would read: Cloudflare cache-purge token ($DEFAULT_CF_TOKEN_OP_URI)" >&2
  fi
  exit 0
fi

# ── Ensure cache dir exists (mode 0700) ───────────────────────────────
mkdir -p "$CACHE_DIR"
chmod 700 "$CACHE_DIR" 2>/dev/null || true

# ── Session file freshness check ──────────────────────────────────────
# Prefer an embedded CREATED_AT epoch over file mtime so `touch`-ing the
# file cannot silently extend its effective lifetime.
session_is_fresh() {
  [[ -f "$SESSION_FILE" ]] || return 1
  local created_at now age
  created_at=$(grep '^OP_PREFLIGHT_CREATED_AT_EPOCH=' "$SESSION_FILE" 2>/dev/null | cut -d= -f2- | tr -d "'\"" || true)
  [[ -z "$created_at" ]] && return 1
  [[ "$created_at" =~ ^[0-9]+$ ]] || return 1
  now=$(date +%s)
  age=$((now - created_at))
  [[ "$age" -lt "$TTL_SECONDS" ]]
}

session_is_token_mode() {
  [[ -f "$SESSION_FILE" ]] || return 1
  grep -q '^OP_PREFLIGHT_TOKEN_MODE=1$' "$SESSION_FILE" 2>/dev/null
}

scrub_op_error() {
  local file="${1:-}" raw token redacted
  [[ -n "$file" && -f "$file" ]] || return 0
  raw="$(tr '\n' ' ' < "$file" || true)"
  token="${OP_SERVICE_ACCOUNT_TOKEN:-}"
  if [[ -n "$raw" && -n "$token" ]]; then
    redacted="$(awk -v s="$raw" -v token="$token" 'BEGIN {
      while ((i = index(s, token)) > 0) {
        s = substr(s, 1, i - 1) "[redacted]" substr(s, i + length(token))
      }
      print s
    }')"
  else
    redacted="$raw"
  fi
  printf '%s\n' "${redacted:0:500}"
}

# Validate that a materialized ADC file still mints a token. Mirrors the
# source_cred_is_usable check in scripts/firebase/op-firebase-deploy so a
# stale 1Password ADC item (refresh_token expired by Google) gets caught
# in preflight instead of inside firebase CLI after the user has already
# eval'd the exports. See nathanjohnpayne/mergepath#137 failure mode B
# for the concrete repro: 1Password holds an authorized_user cred whose
# refresh_token has expired; op read succeeds and writes the file, but
# the OAuth2 /token round-trip fails. Without this check, preflight
# reports "GCP ADC: loaded" and downstream callers see
# "GOOGLE_APPLICATION_CREDENTIALS points to an unusable credential file"
# from inside op-firebase-deploy.
#
# Returns 0 if the file exists and mints a token (or is a self-contained
# service_account key). Returns 1 otherwise — including when python3 is
# unavailable or the oauth2 endpoint is unreachable in which case the
# safer behavior is to treat the cred as stale and let downstream
# callers fall back to their own auth path.
adc_is_usable() {
  local file="${1:-}"
  [[ -n "$file" && -f "$file" && -s "$file" ]] || return 1
  command -v python3 >/dev/null 2>&1 || return 1
  python3 - "$file" <<'PY'
import json, pathlib, sys, urllib.request, urllib.parse

try:
    cred = json.loads(pathlib.Path(sys.argv[1]).read_text())
except Exception:
    sys.exit(1)

while cred.get("type") == "impersonated_service_account" and "source_credentials" in cred:
    cred = cred["source_credentials"]

if cred.get("type") == "service_account":
    sys.exit(0)

refresh_token = cred.get("refresh_token", "")
client_id     = cred.get("client_id", "")
client_secret = cred.get("client_secret", "")

if not all([refresh_token, client_id, client_secret]):
    sys.exit(1)

data = urllib.parse.urlencode({
    "client_id": client_id,
    "client_secret": client_secret,
    "refresh_token": refresh_token,
    "grant_type": "refresh_token",
}).encode()
try:
    req = urllib.request.Request("https://oauth2.googleapis.com/token", data=data)
    urllib.request.urlopen(req, timeout=10)
except Exception:
    sys.exit(1)
PY
}

firebase_sa_matches_project() {
  local file="${1:-}" project="${2:-}"
  [[ -n "$file" && -f "$file" && -s "$file" && -n "$project" ]] || return 1
  command -v python3 >/dev/null 2>&1 || return 1
  python3 - "$file" "$project" "$SA_NAME" <<'PY'
import json
import pathlib
import sys

path, project, sa_name = sys.argv[1:4]
expected = f"{sa_name}@{project}.iam.gserviceaccount.com"
try:
    cred = json.loads(pathlib.Path(path).read_text())
except Exception:
    sys.exit(1)

if cred.get("type") == "service_account" and cred.get("client_email") == expected:
    sys.exit(0)
sys.exit(1)
PY
}

# Emit the human-facing guidance for a stale 1Password ADC item. Called
# from both the full-fetch path (after op read + adc_is_usable fails)
# and the fast-path cache-hit path (when a cached ADC fails the same
# check on the next invocation).
log_stale_adc_guidance() {
  echo "# ──────────────────────────────────────────────────────" >&2
  echo "# WARNING: 1Password ADC item is stale (OAuth2 refresh rejected)." >&2
  echo "#" >&2
  echo "# The credential stored at $DEFAULT_ADC_OP_URI" >&2
  echo "# was read successfully but Google rejected its refresh token —" >&2
  echo "# typical causes: token revoked, expired (RAPT), or user account" >&2
  echo "# password changed. Refresh it with:" >&2
  echo "#" >&2
  echo "#   gcloud auth application-default login" >&2
  echo "#   op document edit 'GCP ADC' --vault=Private \\" >&2
  echo "#     ~/.config/gcloud/application_default_credentials.json" >&2
  echo "#" >&2
  echo "# (use 'op item edit' if the ADC is stored as an item field instead)" >&2
  echo "#" >&2
  echo "# Preflight will NOT export GOOGLE_APPLICATION_CREDENTIALS this run" >&2
  echo "# so downstream callers (op-firebase-deploy, gcloud wrappers) can" >&2
  echo "# fall back to the local firebase-login / ADC path." >&2
  echo "# See nathanjohnpayne/mergepath#137 for the failure mode this guards." >&2
  echo "# ──────────────────────────────────────────────────────" >&2
}

# Emit the session file's export statements to stdout. Caller eval's them.
#
# Runs in a subshell with the relevant variables pre-unset so the
# sourced file's definitions are NOT aliased to whatever the parent
# shell happened to have in scope. Without this isolation a prior
# `--agent claude` invocation could leak its PATs into an
# `--agent codex --mode review` fast-path check, making an
# incomplete codex session file look valid and causing gh to run as
# the wrong identity. See round-5 Codex finding on the propagation
# PRs for the multi-agent repro.
# Compatibility shim for the retired stored-account repair path.
#
# #411 flips GitHub attribution to verified process-local tokens. The
# old preflight behavior repaired the global gh account selection on
# normal review/check paths.
# That mutation is exactly what made concurrent agents fight over
# ~/.config/gh/hosts.yml, so preflight no longer reads or changes the
# selected account. The wrappers verify the effective token immediately
# before each write instead.
restore_active_account_or_warn() {
  return 0
}

# Backwards-compat shim: the prior `warn_active_account_mismatch`
# name is still referenced in downstream consumers' wrappers.
warn_active_account_mismatch() {
  restore_active_account_or_warn "$@"
}

emit_from_session_file() (
  # Subshell: the (  ... ) above means unset/source/return here do
  # not escape back to the caller. We still "return" rc codes via
  # stdout+exit; parent stays clean.
  unset OP_PREFLIGHT_REVIEWER_PAT OP_PREFLIGHT_AUTHOR_PAT
  unset GOOGLE_APPLICATION_CREDENTIALS OP_PREFLIGHT_ADC_TMPFILE
  unset OP_PREFLIGHT_FIREBASE_SA_TMPFILE OP_PREFLIGHT_FIREBASE_PROJECT
  unset CF_API_TOKEN
  unset OP_PREFLIGHT_DONE OP_PREFLIGHT_AGENT OP_PREFLIGHT_MODE
  unset OP_PREFLIGHT_TOKEN_MODE OP_PREFLIGHT_REVIEWER_PAT_SOURCE_REF
  unset OP_PREFLIGHT_CREATED_AT_EPOCH OP_PREFLIGHT_TTL_SECONDS
  unset OP_PREFLIGHT_DEPLOY_DEGRADED OP_PREFLIGHT_DEPLOY_DEGRADED_AT_EPOCH
  unset OP_PREFLIGHT_DEPLOY_CREATED_AT_EPOCH OP_PREFLIGHT_DEPLOY_CONTEXT

  # Source the session file and re-emit only the vars we own, so a
  # hand-edited file with arbitrary content cannot inject exports.
  # Permissions are 0600 in a 0700 cache dir (enforced at write time
  # and re-checked here via stat), so the source boundary is "file
  # owner writes the file; we trust them." Rebuttal to the P2
  # safe-parse finding on the propagation PRs — a reader that also
  # writes the file cannot protect themselves from themselves.
  # shellcheck disable=SC1090
  . "$SESSION_FILE"

  # Validate the session file actually contains the credentials the
  # CURRENT invocation's --mode is asking for. A stale cross-mode cache
  # (e.g. a prior `--mode deploy` run wrote only ADC fields, and this
  # run is `--mode review`) would otherwise hit the fast path and emit
  # no PAT exports — downstream `gh` review commands then run
  # unauthenticated. Return non-zero to trigger the refresh path in
  # each case. See #141 round-1 Codex finding (P1, line 223).
  if [[ "$MODE" == "review" || "$MODE" == "all" ]]; then
    if $SERVICE_ACCOUNT_TOKEN_MODE && [[ "${OP_PREFLIGHT_TOKEN_MODE:-0}" != "1" ]]; then
      exit 2
    fi
    if ! $SERVICE_ACCOUNT_TOKEN_MODE && [[ "${OP_PREFLIGHT_TOKEN_MODE:-0}" == "1" ]]; then
      exit 2
    fi
    if [[ "${OP_PREFLIGHT_TOKEN_MODE:-0}" == "1" ]]; then
      [[ -n "${OP_PREFLIGHT_REVIEWER_PAT_REF:-}" ]] || exit 2
      desired_reviewer_ref="$(reviewer_pat_ref_for "$AGENT" 2>/dev/null || true)"
      is_op_secret_ref "$desired_reviewer_ref" || exit 2
      is_private_or_personal_ref "$desired_reviewer_ref" && exit 2
      if [[ "${OP_PREFLIGHT_REVIEWER_PAT_SOURCE_REF:-}" != "$desired_reviewer_ref" ]]; then
        exit 2
      fi
      if [[ "$MODE" == "all" ]] || [[ -z "${OP_PREFLIGHT_REVIEWER_PAT:-}" ]]; then
        exit 2
      fi
    else
      if [[ -z "${OP_PREFLIGHT_REVIEWER_PAT:-}" ]] || [[ -z "${OP_PREFLIGHT_AUTHOR_PAT:-}" ]]; then
        exit 2
      fi
      # Reject a cache minted from a DIFFERENT 1Password item than the
      # one this agent now maps to, so an agent->item remap takes effect
      # immediately instead of after the TTL. Absent on caches written
      # before this field existed: treat that as stale too (exit 2 =>
      # full refresh) rather than trusting an unattributable token.
      desired_reviewer_ref="$(reviewer_pat_ref_for "$AGENT" 2>/dev/null || true)"
      if [[ -n "$desired_reviewer_ref" ]] \
         && [[ "${OP_PREFLIGHT_REVIEWER_PAT_SOURCE_REF:-}" != "$desired_reviewer_ref" ]]; then
        exit 2
      fi
    fi
  fi
  # Deploy credentials live in the slot for the CURRENT Firebase-project
  # context (see deploy_slot_file_for), so a concurrent session in another
  # Firebase repo can neither evict nor swap them. A present slot supersedes
  # any deploy fields a pre-slot session file still carries; with no slot,
  # those legacy fields fall through to the same project/usability checks
  # below. A slot is honoured only within the session TTL and only for the
  # exact context it recorded.
  #
  # A `--mode all` fetch that could not load ANY deploy credential records
  # OP_PREFLIGHT_DEPLOY_DEGRADED in its slot. Within the backoff window a
  # `--mode all` hit reuses that verdict instead of exit 2 -> full fetch ->
  # the same degraded write -> a fresh biometric on every call. This does
  # NOT reopen friends-and-family-billing#227 round 3 (below): a review-only
  # cache has no slot, so it still cannot satisfy `all`; the marker means
  # "deploy creds were attempted for this context and failed moments ago",
  # not "deploy creds were never loaded". Only `all` writes it (`deploy`
  # exits 1 on that path) and `--mode deploy` never accepts it. rc 3 = the
  # window expired, so the refetch is logged as a retry, not a cross-mode miss.
  deploy_degraded_hit=false
  if [[ "$MODE" == "deploy" || "$MODE" == "all" ]]; then
    current_firebase_project="$(deploy_context_project 2>/dev/null || true)"
    deploy_slot_file="$(deploy_slot_file_for "$current_firebase_project")"
    # Propagation skew (Codex on #1318): a consumer still on the pre-slot
    # script keeps writing freshly fetched deploy fields into the shared
    # session file and never touches the slot. When that write is NEWER than
    # the slot and actually carries a credential, it wins; its fields then
    # go through the same pre-slot project/usability checks below. A
    # slot-aware writer never puts deploy fields in the session file, so
    # this only ever fires for a pre-slot write. It must also be for THIS
    # context (Codex on #1318): a pre-slot Firebase SA only for the current
    # project, and pre-slot ADC (which records no project) only for the
    # `adc` context -- never over a Firebase project's slot, which would
    # swap the project SA for the shared ADC.
    #
    # A pre-slot SA is NEVER exported, though (Phase 4b on #1318): it points
    # at the one shared op-preflight-<agent>-firebase-sa.json that every
    # pre-slot checkout still overwrites, whatever its project, so exporting
    # it would re-open the cross-project key swap slots exist to close. A
    # newer pre-slot SA for this project instead forces a fetch into the
    # project-owned slot. Only pre-slot ADC (identical content for every
    # context that uses it) can supersede.
    legacy_supersedes_slot=false
    legacy_context_matches=false
    legacy_is_sa=false
    if [[ -n "${OP_PREFLIGHT_FIREBASE_SA_TMPFILE:-}" \
          && "${GOOGLE_APPLICATION_CREDENTIALS:-}" == "$OP_PREFLIGHT_FIREBASE_SA_TMPFILE" ]]; then
      legacy_is_sa=true
      [[ -n "$current_firebase_project" && "${OP_PREFLIGHT_FIREBASE_PROJECT:-}" == "$current_firebase_project" ]] \
        && legacy_context_matches=true
    elif [[ -z "$current_firebase_project" ]]; then
      legacy_context_matches=true
    fi
    if [[ -f "$deploy_slot_file" && -n "${GOOGLE_APPLICATION_CREDENTIALS:-}" ]] && $legacy_context_matches; then
      slot_created="$(grep '^OP_PREFLIGHT_DEPLOY_CREATED_AT_EPOCH=' "$deploy_slot_file" | cut -d= -f2- | tr -d "'\"" || true)"
      session_created="${OP_PREFLIGHT_CREATED_AT_EPOCH:-}"
      if [[ "$slot_created" =~ ^[0-9]+$ && "$session_created" =~ ^[0-9]+$ ]] \
         && (( 10#$session_created > 10#$slot_created )); then
        $legacy_is_sa && exit 2
        legacy_supersedes_slot=true
      fi
    fi
    slot_loaded=false
    if [[ -f "$deploy_slot_file" ]] && ! $legacy_supersedes_slot; then
      slot_loaded=true
      # A pre-slot writer persists CF_API_TOKEN whether or not its deploy
      # credential loaded, so a newer session-file token must survive the
      # slot load on its own (Codex on #1318). Slot-aware writers never put
      # it in the session file, so this only ever carries a pre-slot write.
      session_cf_token="${CF_API_TOKEN:-}"
      session_created="${OP_PREFLIGHT_CREATED_AT_EPOCH:-}"
      unset GOOGLE_APPLICATION_CREDENTIALS OP_PREFLIGHT_ADC_TMPFILE
      unset OP_PREFLIGHT_FIREBASE_SA_TMPFILE OP_PREFLIGHT_FIREBASE_PROJECT
      unset CF_API_TOKEN
      # shellcheck disable=SC1090
      . "$deploy_slot_file"
      slot_created="${OP_PREFLIGHT_DEPLOY_CREATED_AT_EPOCH:-}"
      [[ "$slot_created" =~ ^[0-9]+$ ]] || exit 2
      if [[ -n "$session_cf_token" && "$session_created" =~ ^[0-9]+$ ]] \
         && (( 10#$session_created > 10#$slot_created )); then
        CF_API_TOKEN="$session_cf_token"
      fi
      slot_age=$(( $(date +%s) - 10#$slot_created ))
      [[ "$slot_age" -ge 0 && "$slot_age" -lt "$TTL_SECONDS" ]] || exit 2
      [[ "${OP_PREFLIGHT_DEPLOY_CONTEXT-__unset__}" == "$current_firebase_project" ]] || exit 2
      if [[ "$MODE" == "all" && -z "${GOOGLE_APPLICATION_CREDENTIALS:-}" \
            && "${OP_PREFLIGHT_DEPLOY_DEGRADED:-0}" == "1" ]]; then
        degraded_at="${OP_PREFLIGHT_DEPLOY_DEGRADED_AT_EPOCH:-}"
        [[ "$degraded_at" =~ ^[0-9]+$ ]] || exit 3
        degraded_age=$(( $(date +%s) - 10#$degraded_at ))
        if [[ "$degraded_age" -ge 0 && "$degraded_age" -lt "$DEPLOY_DEGRADED_BACKOFF_SECONDS" ]]; then
          deploy_degraded_hit=true
          echo "# WARNING: deploy credentials unavailable (Firebase project '${current_firebase_project:-none}', checked ${degraded_age}s ago); serving cached PATs without GOOGLE_APPLICATION_CREDENTIALS. Retry in $(( DEPLOY_DEGRADED_BACKOFF_SECONDS - degraded_age ))s, or now with --refresh." >&2
        else
          exit 3
        fi
      fi
    fi
    # With no slot in play, pre-slot session fields obey the same context
    # rule as everywhere else: pre-slot ADC (which records no project) is
    # never a Firebase project's credential. Otherwise a failed --refresh
    # there (which removes the slot) would be followed by a plain deploy
    # that silently reuses the old ADC file (Phase 4b on #1318). A pre-slot
    # SA is checked against the project by the validation below.
    # For the same reason, with no slot a pre-slot SA is never exported:
    # force a fetch into the project-owned slot instead.
    if ! $slot_loaded && $legacy_is_sa; then
      exit 2
    fi
    if ! $slot_loaded && [[ -n "$current_firebase_project" && -n "${GOOGLE_APPLICATION_CREDENTIALS:-}" ]] \
       && ! [[ -n "${OP_PREFLIGHT_FIREBASE_SA_TMPFILE:-}" \
               && "$GOOGLE_APPLICATION_CREDENTIALS" == "$OP_PREFLIGHT_FIREBASE_SA_TMPFILE" ]]; then
      exit 2
    fi
  fi
  if [[ "$MODE" == "deploy" || "$MODE" == "all" ]] && ! $deploy_degraded_hit; then
    # Both `--mode deploy` and `--mode all` require a usable deploy
    # credential from the cache to take the fast path. If the session
    # file's credential field is missing or the materialized file is
    # unreadable, return 2 to trigger a full refresh.
    #
    # An earlier iteration of this code treated missing-ADC on
    # `--mode all` as a partial hit (emit PATs, skip ADC) to spare
    # biometric re-prompts when 1Password had been offline during the
    # original fetch. That violated the `all` contract: a later
    # `--mode all` on a review-only cache would silently never load
    # deploy credentials until TTL expiry, breaking deploy flows in
    # the same session. `all` means "everything"; honor it. See
    # friends-and-family-billing#227 round-3 Codex P1 — Codex's
    # earlier P2 (round 1) asking for the partial-hit shape was a
    # reversal it itself caught once I shipped it.
    if [[ -z "${GOOGLE_APPLICATION_CREDENTIALS:-}" ]] || [[ ! -s "${GOOGLE_APPLICATION_CREDENTIALS:-}" ]]; then
      exit 2
    fi
    if [[ -n "${OP_PREFLIGHT_FIREBASE_SA_TMPFILE:-}" && "${GOOGLE_APPLICATION_CREDENTIALS}" == "${OP_PREFLIGHT_FIREBASE_SA_TMPFILE}" ]]; then
      if [[ "${OP_PREFLIGHT_CHECK_MODE:-0}" == "1" ]]; then
        current_firebase_project="$(detect_firebase_project_no_python 2>/dev/null || true)"
        firebase_sa_matches_project_check() {
          firebase_sa_matches_project_no_python "${GOOGLE_APPLICATION_CREDENTIALS}" "$current_firebase_project"
        }
      else
        current_firebase_project="$(detect_firebase_project 2>/dev/null || true)"
        firebase_sa_matches_project_check() {
          firebase_sa_matches_project "${GOOGLE_APPLICATION_CREDENTIALS}" "$current_firebase_project"
        }
      fi
      if [[ -z "$current_firebase_project" || "$current_firebase_project" != "${OP_PREFLIGHT_FIREBASE_PROJECT:-}" ]]; then
        echo "# WARNING: cached Firebase project SA key is for '${OP_PREFLIGHT_FIREBASE_PROJECT:-unknown}', but current project is '${current_firebase_project:-none}'; refreshing deploy credentials." >&2
        exit 2
      fi
      if ! firebase_sa_matches_project_check; then
        echo "# WARNING: cached Firebase project SA key file does not match current project '$current_firebase_project'; refreshing deploy credentials." >&2
        exit 2
      fi
    fi
    # --check is the "no external probes" contract — never invoke op,
    # ssh, OR python3. The `adc_is_usable` probe spawns python3 to
    # validate the OAuth2 refresh token, which fires a network call.
    # Under --check we trust the cache as-is and emit the ADC path
    # without validating it; downstream deploy callers will surface
    # their own auth failure if the cred is actually broken.
    # (nathanpayne-codex Phase 4b r1 on PR #292 — they verified
    # `--check --mode deploy` still spawned python3.)
    if [[ "${OP_PREFLIGHT_CHECK_MODE:-0}" != "1" ]] && \
       ! adc_is_usable "${GOOGLE_APPLICATION_CREDENTIALS}"; then
      # File exists but the credential is unusable. Warn and skip the
      # export so downstream deploy callers can fall back through their
      # own resolver. OP_PREFLIGHT_DONE stays 1 and PATs are still
      # emitted below, because preflight itself succeeded — only the
      # deploy-credential path is degraded.
      if [[ -n "${OP_PREFLIGHT_FIREBASE_SA_TMPFILE:-}" && "${GOOGLE_APPLICATION_CREDENTIALS}" == "${OP_PREFLIGHT_FIREBASE_SA_TMPFILE}" ]]; then
        echo "# WARNING: cached Firebase project SA key is unusable; refreshing deploy credentials." >&2
        unset GOOGLE_APPLICATION_CREDENTIALS OP_PREFLIGHT_ADC_TMPFILE
        unset OP_PREFLIGHT_FIREBASE_SA_TMPFILE OP_PREFLIGHT_FIREBASE_PROJECT
        exit 2
      else
        # Force a full re-fetch (exit 2) rather than degrading in place
        # (#469): the cached ADC tempfile is stale, but the 1Password ADC
        # item may have been refreshed since this cache was written.
        # Re-reading from op on the full-fetch path gives it that chance;
        # if op's copy is ALSO stale, the full-fetch path calls
        # log_stale_adc_guidance and degrades there. This matches the
        # Firebase-SA branch above, which already exits 2 on a stale cache.
        echo "# WARNING: cached GCP ADC is unusable; refreshing deploy credentials." >&2
        unset GOOGLE_APPLICATION_CREDENTIALS OP_PREFLIGHT_ADC_TMPFILE
        unset OP_PREFLIGHT_FIREBASE_SA_TMPFILE OP_PREFLIGHT_FIREBASE_PROJECT
        exit 2
      fi
    fi
  fi

  [[ -n "${OP_PREFLIGHT_REVIEWER_PAT:-}" ]] && \
    printf 'export OP_PREFLIGHT_REVIEWER_PAT=%q\n' "$OP_PREFLIGHT_REVIEWER_PAT"  # TOKEN_OUTPUT_EXEMPT: writing these values to the cache IS op-preflight's contract (#996)
  [[ -n "${OP_PREFLIGHT_AUTHOR_PAT:-}" ]] && \
    printf 'export OP_PREFLIGHT_AUTHOR_PAT=%q\n' "$OP_PREFLIGHT_AUTHOR_PAT"  # TOKEN_OUTPUT_EXEMPT: writing these values to the cache IS op-preflight's contract (#996)
  [[ "${OP_PREFLIGHT_TOKEN_MODE:-0}" == "1" ]] && \
    printf 'export OP_PREFLIGHT_TOKEN_MODE=1\n'
  # Mode-scope the deploy-credential emission (#466): a review-mode (or
  # default --check) cache hit must NOT re-export deploy credentials that a
  # prior `--mode deploy` / `--mode all` run left in the session file. The
  # deploy-validation block above is already skipped for review mode, so
  # without this gate a review request silently re-exports stale deploy
  # creds (GOOGLE_APPLICATION_CREDENTIALS, Firebase SA, CF_API_TOKEN).
  # Emit them only when the CURRENT request actually asked for deploy creds.
  if [[ "$MODE" == "deploy" || "$MODE" == "all" ]]; then
    # Clear first, then export what THIS context's cache holds, so the
    # caller's shell mirrors the cache exactly: a degraded `all` hit, or a
    # `cd` into another Firebase repo, must not leave a GOOGLE_APPLICATION_
    # CREDENTIALS from an earlier eval (possibly another project's key) live.
    printf '%s\n' "$DEPLOY_CLEAR_STMT"
    [[ -n "${GOOGLE_APPLICATION_CREDENTIALS:-}" ]] && \
      printf 'export GOOGLE_APPLICATION_CREDENTIALS=%q\n' "$GOOGLE_APPLICATION_CREDENTIALS"
    [[ -n "${OP_PREFLIGHT_ADC_TMPFILE:-}" ]] && \
      printf 'export OP_PREFLIGHT_ADC_TMPFILE=%q\n' "$OP_PREFLIGHT_ADC_TMPFILE"
    [[ -n "${OP_PREFLIGHT_FIREBASE_SA_TMPFILE:-}" ]] && \
      printf 'export OP_PREFLIGHT_FIREBASE_SA_TMPFILE=%q\n' "$OP_PREFLIGHT_FIREBASE_SA_TMPFILE"
    [[ -n "${OP_PREFLIGHT_FIREBASE_PROJECT:-}" ]] && \
      printf 'export OP_PREFLIGHT_FIREBASE_PROJECT=%q\n' "$OP_PREFLIGHT_FIREBASE_PROJECT"
    [[ -n "${CF_API_TOKEN:-}" ]] && \
      printf 'export CF_API_TOKEN=%q\n' "$CF_API_TOKEN"  # TOKEN_OUTPUT_EXEMPT: writing these values to the cache IS op-preflight's contract (#996)
  else
    # Review-only request (#466 r2): actively clear any deploy credentials a
    # prior --mode deploy / --mode all eval exported into the caller's
    # shell, so a review session does not retain stale deploy creds in its
    # environment (not just refrain from re-exporting them). Emitting unset
    # is idempotent when the caller never had them.
    printf '%s\n' "$REVIEW_CLEAR_STMT"
  fi
  printf 'export OP_PREFLIGHT_DONE=1\n'
  printf 'export OP_PREFLIGHT_AGENT=%q\n' "$AGENT"
  # Keep exporting the preflight mode on the cache-hit path (#521): a
  # consumer that evals this output (e.g. a deploy wrapper that took the
  # fast path and skipped a fresh fetch) can read OP_PREFLIGHT_MODE to see
  # which mode actually ran. $MODE is this invocation's mode, which the
  # cross-mode validation above already proved the cache satisfies.
  printf 'export OP_PREFLIGHT_MODE=%q\n' "$MODE"
  exit 0
)

# Warm author + reviewer SSH keys. Idempotent — each `ssh -T` exits
# immediately with "You've successfully authenticated" when the agent
# has the key, otherwise triggers the 1Password SSH-agent biometric
# prompt for the underlying key. Called from both the full-fetch path
# and the cache-hit fast path: skipping SSH warming on the fast path
# means subsequent git/gh SSH operations can still block on auth even
# after preflight reports success (friends-and-family-billing#227
# round-5 Codex P2). Output goes to stderr so it's not eval'd.
#
# SSH-warm freshness (#163): the 1Password SSH agent has its OWN
# session TTL — independent of the chmod-600 PAT cache. Re-warming
# on every cache-hit invocation re-prompts biometric whenever the
# 1Password agent's own session has expired (typically much shorter
# than the 10h PAT TTL). Track an SSH-warm marker file and skip the
# warm if it's recent enough. The marker's age is the only thing
# that matters here — if the 1Password agent expires inside our
# SSH_WARM_TTL window, the next git push/pull still triggers
# biometric, but at least preflight itself doesn't multiply that.
ssh_warm_is_fresh() {
  [[ -f "$SSH_WARM_MARKER" ]] || return 1
  local mtime now age
  mtime=$(stat -f %m "$SSH_WARM_MARKER" 2>/dev/null || stat -c %Y "$SSH_WARM_MARKER" 2>/dev/null || echo 0)
  now=$(date +%s)
  age=$((now - mtime))
  [[ "$age" -lt "$SSH_WARM_TTL_SECONDS" ]]
}

warm_ssh_keys() {
  if ssh_warm_is_fresh; then
    local mtime now age
    mtime=$(stat -f %m "$SSH_WARM_MARKER" 2>/dev/null || stat -c %Y "$SSH_WARM_MARKER" 2>/dev/null || echo 0)
    now=$(date +%s); age=$((now - mtime))
    echo "# Preflight: SSH keys recently warmed (${age}s ago / TTL ${SSH_WARM_TTL_SECONDS}s) — skipping" >&2
    SUMMARY+=("SSH keys: cached (${age}s ago)")
    return 0
  fi
  echo "# Preflight: warming SSH keys..." >&2
  if ssh -T "git@${SSH_AUTHOR_HOST}" 2>&1 | grep -qi "successfully authenticated"; then
    SUMMARY+=("SSH key ($SSH_AUTHOR_HOST): authorized")
  else
    SUMMARY+=("SSH key ($SSH_AUTHOR_HOST): warming attempted")
  fi
  local reviewer_host
  reviewer_host="$(ssh_host_for "$AGENT")"
  if ssh -T "git@${reviewer_host}" 2>&1 | grep -qi "successfully authenticated"; then
    SUMMARY+=("SSH key ($reviewer_host): authorized")
  else
    SUMMARY+=("SSH key ($reviewer_host): warming attempted")
  fi
  # Touch the marker AFTER both warms attempted. If either warm failed
  # (network blip, key not in agent) we still set the marker — the next
  # git op will surface the underlying problem rather than masking it
  # with a re-warm cycle. Marker-touch failures are non-fatal.
  touch "$SSH_WARM_MARKER" 2>/dev/null || true
  chmod 600 "$SSH_WARM_MARKER" 2>/dev/null || true
}

# ── --check / --status mode (#282) ────────────────────────────────────
# Read-only validator: emit cached exports if the session file is fresh,
# OR exit non-zero with a diagnostic if it is missing/stale. NEVER
# invokes op, NEVER warms SSH, NEVER reads ADC. Designed to be re-run
# at the top of every agent tool call without the biometric prompt risk
# of `--mode review`.
# TEMPORARY, #1021. Before the split, `eval "$(... --check)"` populated
# OP_PREFLIGHT_*_PAT. After it, an un-migrated caller would evaluate an empty
# string and leave both variables UNSET -- and an empty GH_TOKEN does not fail:
# `GH_TOKEN="" gh api user` exits 0 and silently attributes to whatever account
# the gh keyring has active. That is a wrong byline nobody sees, which is worse
# than the leak this change closes. So stdout carries a guard that is inert when
# read but fails loudly when evaluated. Remove it once every consumer passes
# --print-exports; tracked separately.
# The emitted line is EVALUATED by the caller, so every interpolated value must
# be shell-quoted -- $MODE is not validated on the --check path, and
# `--mode 'review"; <command>; echo "'` escaped the double-quoted echo and ran
# in the caller's shell (CodeRabbit, round 2; reproduced before fixing). Quoting
# happens HERE, once, rather than at each call site: a later caller cannot
# forget it. This is the same `printf '%q'` treatment the export emitters
# already give $AGENT.
emit_eval_guard() { # <message>
  printf 'echo %s >&2; return 1 2>/dev/null || exit 1\n' "$(printf '%q' "op-preflight: $1")"
}
emit_check_compat_guard() {
  emit_eval_guard "--check no longer prints exports (mergepath#1021); re-run with --print-exports to populate OP_PREFLIGHT_*_PAT"
}
# The ERROR paths need a guard even WITH --print-exports, and that is not the
# same hazard as the compat one. `eval "$(cmd)"` discards the command
# substitution's exit status: a script that exits 2 having printed nothing makes
# `eval` return 0, so the documented caller sails on with both PATs unset --
# verified, `eval "$(... --check --print-exports)"` against a missing cache
# returns rc=0 with OP_PREFLIGHT_REVIEWER_PAT unset. That is the same silent
# keyring fallback #1021 is closing, reached through the path this change now
# tells everyone to use. The invariant is therefore: stdout always carries
# something that FAILS when evaluated, unless real exports are being emitted.
emit_check_failure_guard() {
  emit_eval_guard "--check found no usable cache for agent=$AGENT (mode=$MODE); run: scripts/op-preflight.sh --agent $AGENT --mode $MODE"
}
# `--mode deploy` fails closed when no deploy credential loads, but a bare
# `exit 1` prints nothing: `eval "$(...)"` then returns 0 and the caller keeps
# whatever GOOGLE_APPLICATION_CREDENTIALS an earlier eval exported. With
# per-project SA files that is a LIVE key for another project (Codex on
# #1318), so the next deploy would run under the wrong identity. Clear the
# deploy variables, then fail the eval.
# A failed --mode deploy (typically --refresh during a key rotation or
# revocation) must also invalidate this context's slot: otherwise the next
# plain --mode deploy finds it fresh and silently re-exports the old key
# without asking 1Password (Codex on #1318). The key FILE stays, because
# shells that already exported it are still using it.
#
# The same goes for pre-slot deploy fields a not-yet-updated consumer wrote
# into the shared session file (propagation skew): with the slot gone, the
# next deploy would fall back to them and reuse the rotated key (Codex on
# #1318). Strip them too -- staged + renamed, PATs kept -- rather than
# deleting the whole file and forcing a PAT re-prompt.
#
# Only fields for THIS context are stripped (CodeRabbit on #1318), by the
# same rule that lets pre-slot fields supersede a slot: a pre-slot Firebase
# SA only when it is for the failing project, pre-slot ADC only when the
# failing context is `adc`. Another project's pre-slot entry is untouched.
session_field() { # <variable name>: its value in the session file, or ""
  # shellcheck disable=SC1090
  ( unset "$1"; . "$SESSION_FILE" 2>/dev/null; printf '%s' "${!1:-}" )
}
invalidate_deploy_slot() {
  rm -f "$(deploy_slot_file_for "${firebase_project:-}")"
  [[ -f "$SESSION_FILE" ]] || return 0
  local legacy_gac legacy_sa legacy_project
  legacy_gac="$(session_field GOOGLE_APPLICATION_CREDENTIALS)"
  legacy_sa="$(session_field OP_PREFLIGHT_FIREBASE_SA_TMPFILE)"
  legacy_project="$(session_field OP_PREFLIGHT_FIREBASE_PROJECT)"
  [[ -n "$legacy_gac" ]] || return 0
  if [[ -n "$legacy_sa" && "$legacy_gac" == "$legacy_sa" ]]; then
    [[ -n "${firebase_project:-}" && "$legacy_project" == "$firebase_project" ]] || return 0
  else
    [[ -z "${firebase_project:-}" ]] || return 0
  fi
  if grep -Eq '^(GOOGLE_APPLICATION_CREDENTIALS|OP_PREFLIGHT_ADC_TMPFILE|OP_PREFLIGHT_FIREBASE_SA_TMPFILE|OP_PREFLIGHT_FIREBASE_PROJECT)=' "$SESSION_FILE"; then
    local session_staged
    session_staged="$(mktemp "$CACHE_DIR/op-preflight-$AGENT-session.staged.XXXXXX")"
    grep -Ev '^(GOOGLE_APPLICATION_CREDENTIALS|OP_PREFLIGHT_ADC_TMPFILE|OP_PREFLIGHT_FIREBASE_SA_TMPFILE|OP_PREFLIGHT_FIREBASE_PROJECT)=' \
      "$SESSION_FILE" > "$session_staged" || true
    chmod 600 "$session_staged"
    mv -f "$session_staged" "$SESSION_FILE"
  fi
}
emit_deploy_failure_guard() {
  printf '%s\n' "$DEPLOY_CLEAR_STMT"
  emit_eval_guard "--mode deploy loaded no deploy credential for Firebase project '${firebase_project:-none}'; deploy variables cleared (see stderr)"
}

if $CHECK; then
  if ! session_is_fresh; then
    echo "# preflight: cache missing or stale for agent=$AGENT" >&2
    echo "#   run: scripts/op-preflight.sh --agent $AGENT --mode review" >&2
    echo "#   then re-run this command." >&2
    emit_check_failure_guard
    exit 2
  fi
  # The session is fresh. Emit the cached exports the same way the fast
  # path does — but DO NOT warm SSH and DO NOT call any other helpers
  # that might prompt. Setting OP_PREFLIGHT_CHECK_MODE=1 tells
  # emit_from_session_file to skip the ADC-usability python3 probe
  # under `--mode deploy`/`--mode all` so the helper stays probe-free
  # in --check mode. (nathanpayne-codex Phase 4b r1 on PR #292.)
  if cached_exports=$(OP_PREFLIGHT_CHECK_MODE=1 emit_from_session_file); then
    rc=0
  else
    rc=$?
  fi
  if [[ "$rc" != "0" ]]; then
    echo "# preflight: cache present but incomplete for agent=$AGENT (mode=$MODE)" >&2
    echo "#   run: scripts/op-preflight.sh --agent $AGENT --mode review" >&2
    emit_check_failure_guard
    exit 2
  fi
  # #1021: the liveness check and the token dump used to be the SAME
  # command. `--check` is documented as the thing every agent re-runs at the
  # top of every tool call, so an agent testing whether the cache was warm
  # wrote both live PATs into its transcript in plaintext -- observed twice
  # in one session, by two different agents, both of which had been warned
  # about credential hygiene. When careful actors break a rule repeatedly,
  # the affordance is the defect. Printing now requires saying so.
  if $PRINT_EXPORTS; then
    echo "$cached_exports"
  else
    emit_check_compat_guard
  fi
  if [[ "${OP_PREFLIGHT_QUIET:-0}" != "1" ]]; then
    epoch=$(grep '^OP_PREFLIGHT_CREATED_AT_EPOCH=' "$SESSION_FILE" | cut -d= -f2- | tr -d "'\"" || true)
    now=$(date +%s)
    if [[ "$epoch" =~ ^[0-9]+$ ]]; then
      age=$(( now - 10#$epoch ))
    else
      age=$now
    fi
    echo "# preflight: --check ok (age ${age}s / TTL ${TTL_SECONDS}s, no biometric)" >&2
  else
    echo "# preflight: cache hit, no biometric burned" >&2
  fi
  exit 0
fi

# ── Refresh forces both PAT cache + SSH-warm marker invalidation ─────
# (--refresh is the "I want a brand-new biometric burst" knob; honor
# it for SSH too, otherwise the warm would skip via the marker.)
if $REFRESH; then
  rm -f "$SSH_WARM_MARKER"
fi

# ── Fast path: reuse session file when fresh ──────────────────────────
if ! $REFRESH && session_is_fresh; then
  # Use if-condition to capture exit code without tripping `set -e`.
  # Bare `cached_exports=$(emit_from_session_file); rc=$?` would be
  # sensitive to errexit — a non-zero exit inside `$(...)` aborts the
  # outer script before `rc=$?` runs, so the intended refresh-fallback
  # path below never executes (reproducible: populate a review-only
  # cache, invoke --mode deploy; old code exits 2 with zero exports,
  # new code falls through to the full fetch). See the propagation-
  # round Codex review across all 6 consumer PRs.
  if cached_exports=$(emit_from_session_file); then
    rc=0
  else
    rc=$?
  fi
  if [[ "$rc" == "0" ]]; then
    echo "$cached_exports"
    # `|| true` + numeric-only validation + `10#` decimal coercion so
    # neither a missing key NOR a garbage value (e.g. `123abc` errors
    # in arithmetic; `08` is parsed as invalid octal) takes down the
    # cache-hit path under set -e + pipefail. On bad input we fall
    # back to age = $now → huge → cache miss + refresh (the correct
    # fallback). (CodeRabbit Minor on PR #278, #272.)
    epoch=$(grep '^OP_PREFLIGHT_CREATED_AT_EPOCH=' "$SESSION_FILE" | cut -d= -f2- | tr -d "'\"" || true)
    now=$(date +%s)
    if [[ "$epoch" =~ ^[0-9]+$ ]]; then
      age=$(( now - 10#$epoch ))
    else
      age=$now
    fi
    CACHE_TOKEN_MODE=false
    if session_is_token_mode; then
      CACHE_TOKEN_MODE=true
    fi
    # Warm SSH keys on the cache-hit path too. The cached PATs are
    # worthless for git push/pull if SSH auth isn't also primed, and
    # the prior implementation skipped this step entirely on cache
    # hit — a repro surfaced on the consumer-repo propagation PRs.
    SUMMARY=()
    if $CACHE_TOKEN_MODE; then
      SUMMARY+=("Service-account token cache: reviewer PAT only; SSH/keyring skipped")
    fi
    if [[ "$MODE" == "review" || "$MODE" == "all" ]] && ! $SKIP_SSH && ! $CACHE_TOKEN_MODE; then
      warm_ssh_keys
    fi
    if [[ "${OP_PREFLIGHT_QUIET:-0}" == "1" ]]; then
      # #282: agents that re-run preflight at the top of every tool
      # call want a single-line confirmation, not the verbose block.
      # Refresh notices and warnings remain unaffected; only this
      # routine cache-hit block collapses.
      echo "# preflight: cache hit, no biometric burned" >&2
      if ! $CACHE_TOKEN_MODE; then
        warn_active_account_mismatch
      fi
    else
      echo "" >&2
      echo "# ── Preflight cached hit (age ${age}s / TTL ${TTL_SECONDS}s) ──" >&2
      echo "# Session file: $SESSION_FILE" >&2
      for line in "${SUMMARY[@]}"; do
        echo "#   $line" >&2
      done
      echo "# Run with --refresh to force a new biometric fetch." >&2
      if ! $CACHE_TOKEN_MODE; then
        warn_active_account_mismatch
      fi
      echo "# ──────────────────────────────────────────────────────────" >&2
    fi
    exit 0
  fi
  # emit_from_session_file returned non-zero (e.g. ADC file vanished).
  # Fall through to full fetch.
  echo "# Session file stale or incomplete — refreshing" >&2
  # Distinguish a partial-cache miss (stale ADC, cross-mode invalidation)
  # from a full-fetch when logging the biometric trigger reason. The rc
  # from emit_from_session_file is in scope thanks to the if-condition
  # capture above. rc=2 means cross-mode invalidation; rc=3 means a
  # degraded `--mode all` cache outlived its backoff window; anything else
  # is treated as stale-ADC by default for log clarity.
  if [[ "${rc:-0}" == "2" ]]; then
    BIOMETRIC_REASON="cross-mode-invalidation"
  elif [[ "${rc:-0}" == "3" ]]; then
    BIOMETRIC_REASON="deploy-degraded-retry"
  else
    BIOMETRIC_REASON="stale-adc"
  fi
fi

# Default reason for full-fetch path (no cache hit at all, or --refresh).
if [[ -z "${BIOMETRIC_REASON:-}" ]]; then
  if $REFRESH; then
    BIOMETRIC_REASON="refresh"
  else
    BIOMETRIC_REASON="full-fetch"
  fi
fi

# ── Preflight checks for full fetch ──────────────────────────────────
if ! command -v op &>/dev/null; then
  echo "Error: 1Password CLI (op) not found." >&2
  exit 1
fi

# ── Collect export statements + session-file lines ───────────────────
EXPORTS=()
SESSION_LINES=()
DEPLOY_SLOT_LINES=()  # -> $(deploy_slot_file_for <context>), not the session file
SUMMARY=()
DEPLOY_BIOMETRIC_LOGGED=false

log_deploy_biometric_once() {
  if [[ "$MODE" == "deploy" && "$DEPLOY_BIOMETRIC_LOGGED" == "false" ]]; then
    log_biometric_trigger "$BIOMETRIC_REASON"
    DEPLOY_BIOMETRIC_LOGGED=true
  fi
}

# ── Phase 1: CLI credentials (one biometric prompt + session reuse) ───
if [[ "$MODE" == "review" || "$MODE" == "all" ]]; then
  reviewer_item="$(reviewer_pat_item_for "$AGENT")"

  if $SERVICE_ACCOUNT_TOKEN_MODE; then
    if [[ -z "${OP_PREFLIGHT_REVIEWER_PAT_REF:-}" ]]; then
      echo "Error: OP_PREFLIGHT_REVIEWER_PAT_REF is required in OP_SERVICE_ACCOUNT_TOKEN mode." >&2
      echo "       Use a service-account-accessible op://vault/item/field reference; Private/Personal vaults are out of scope." >&2
      exit 1
    fi
    reviewer_ref="$(reviewer_pat_ref_for "$AGENT")"
    if ! is_op_secret_ref "$reviewer_ref"; then
      echo "Error: OP_PREFLIGHT_REVIEWER_PAT_REF must be an op:// secret reference." >&2
      exit 1
    fi
    if is_private_or_personal_ref "$reviewer_ref"; then
      echo "Error: OP_PREFLIGHT_REVIEWER_PAT_REF cannot point to Private or Personal vaults in OP_SERVICE_ACCOUNT_TOKEN mode." >&2
      exit 1
    fi
    echo "# Preflight: reading reviewer PAT via OP_SERVICE_ACCOUNT_TOKEN..." >&2
    op_err_file="$(mktemp "${TMPDIR:-/tmp}/op-preflight-read-err-XXXXXX")"
    reviewer_pat=""
    op_read_rc=0
    if reviewer_pat="$(op read "$reviewer_ref" 2>"$op_err_file")"; then
      op_read_rc=0
    else
      op_read_rc=$?
    fi
    if [[ "$op_read_rc" -ne 0 || -z "$reviewer_pat" ]]; then
      op_error="$(scrub_op_error "$op_err_file")"
      rm -f "$op_err_file"
      echo "Error: failed to read reviewer PAT for $AGENT via OP_SERVICE_ACCOUNT_TOKEN." >&2
      if [[ -n "$op_error" ]]; then
        echo "1Password CLI: $op_error" >&2
      fi
      exit 1
    fi
    rm -f "$op_err_file"
    EXPORTS+=("export OP_PREFLIGHT_REVIEWER_PAT=$(printf '%q' "$reviewer_pat")")
    EXPORTS+=("export OP_PREFLIGHT_TOKEN_MODE=1")
    SESSION_LINES+=("OP_PREFLIGHT_TOKEN_MODE=1")
    SESSION_LINES+=("OP_PREFLIGHT_REVIEWER_PAT_SOURCE_REF=$(printf '%q' "$reviewer_ref")")
    SESSION_LINES+=("OP_PREFLIGHT_REVIEWER_PAT=$(printf '%q' "$reviewer_pat")")
    SUMMARY+=("Reviewer PAT ($AGENT): loaded via service account token")
    SUMMARY+=("Author PAT: skipped (service account token mode)")
  else
    # Build an op inject template for both PATs. op inject resolves all
    # op:// references in a single process — one biometric prompt covers
    # both reads.
    tpl_file="$(mktemp "${TMPDIR:-/tmp}/op-preflight-tpl-XXXXXX")"
    trap 'rm -f "$tpl_file"' EXIT

    cat > "$tpl_file" <<TPL
REVIEWER_PAT={{ op://Private/${reviewer_item}/token }}
AUTHOR_PAT={{ op://Private/${AUTHOR_PAT_ITEM}/token }}
TPL

    echo "# Preflight: reading PATs (one biometric prompt)..." >&2
    log_biometric_trigger "$BIOMETRIC_REASON"
    resolved="$(op inject -i "$tpl_file")"
    rm -f "$tpl_file"

    reviewer_pat="$(echo "$resolved" | grep '^REVIEWER_PAT=' | cut -d= -f2-)"
    author_pat="$(echo "$resolved" | grep '^AUTHOR_PAT=' | cut -d= -f2-)"

    if [[ -z "$reviewer_pat" ]]; then
      echo "Error: failed to read reviewer PAT for $AGENT." >&2
      exit 1
    fi
    if [[ -z "$author_pat" ]]; then
      echo "Error: failed to read author PAT." >&2
      exit 1
    fi

    EXPORTS+=("export OP_PREFLIGHT_REVIEWER_PAT=$(printf '%q' "$reviewer_pat")")
    EXPORTS+=("export OP_PREFLIGHT_AUTHOR_PAT=$(printf '%q' "$author_pat")")
    SESSION_LINES+=("OP_PREFLIGHT_REVIEWER_PAT=$(printf '%q' "$reviewer_pat")")
    SESSION_LINES+=("OP_PREFLIGHT_AUTHOR_PAT=$(printf '%q' "$author_pat")")
    # Record WHICH 1Password item this PAT came from. The cache stores a
    # resolved token, so a change to the agent->item mapping is invisible
    # to a warm cache: session_is_fresh only compares the TTL, and the
    # fast path would keep serving a token from the OLD item for up to
    # TTL_SECONDS. That is not hypothetical — item
    # o6ekjxjjl5gq6rmcneomrjahpu was repurposed from codex to the robot CI
    # account on 2026-08-21, and every warm codex cache kept emitting a
    # robot token after the mapping was corrected. Token mode already
    # guarded this; the interactive path did not.
    SESSION_LINES+=("OP_PREFLIGHT_REVIEWER_PAT_SOURCE_REF=$(printf '%q' "op://Private/${reviewer_item}/token")")
    SUMMARY+=("Reviewer PAT ($AGENT): loaded")
    SUMMARY+=("Author PAT: loaded")
  fi
fi

if [[ "$MODE" == "deploy" || "$MODE" == "all" ]]; then
  # Same clear-then-export contract as the cache-hit path.
  EXPORTS+=("$DEPLOY_CLEAR_STMT")
  firebase_project="$(deploy_context_project 2>/dev/null || true)"
  firebase_sa_loaded=false
  adc_loaded=false
  firebase_sa_file=""

  if [[ -n "$firebase_project" ]]; then
    echo "# Preflight: reading Firebase project SA key for $firebase_project..." >&2

    # Deterministic path so subsequent invocations and op-firebase-deploy
    # can reuse the same cached project SA key without a second biometric
    # prompt. Overwrite in place — chmod 600 before writing secret content.
    # One file per project (never shared across projects), so a concurrent
    # session in another Firebase repo cannot overwrite the key this
    # session exported as GOOGLE_APPLICATION_CREDENTIALS.
    # Download to a staged sibling (0600 under umask 077) and move it into
    # place only once it validates: a failed fetch must never truncate or
    # delete the key another session of the SAME project already exported.
    firebase_sa_file="$(firebase_sa_file_for "$firebase_project")"
    firebase_sa_staged="$(mktemp "$CACHE_DIR/op-preflight-$AGENT-firebase-sa.staged.XXXXXX")"

    # For --mode deploy (no review credentials loaded), this is the first
    # op call of the run — log it. For --mode all, the Phase 1 op inject
    # above already logged a single line covering the whole biometric
    # burst, so no second log entry is needed here.
    log_deploy_biometric_once
    if op document get "${firebase_project} — Firebase Deployer SA Key" \
         --vault "$FIREBASE_SA_VAULT" \
         --out-file "$firebase_sa_staged" \
         --force >/dev/null 2>&1 \
       && firebase_sa_matches_project "$firebase_sa_staged" "$firebase_project"; then
      mv -f "$firebase_sa_staged" "$firebase_sa_file"
      EXPORTS+=("export GOOGLE_APPLICATION_CREDENTIALS=$(printf '%q' "$firebase_sa_file")")
      EXPORTS+=("export OP_PREFLIGHT_FIREBASE_SA_TMPFILE=$(printf '%q' "$firebase_sa_file")")
      EXPORTS+=("export OP_PREFLIGHT_FIREBASE_PROJECT=$(printf '%q' "$firebase_project")")
      DEPLOY_SLOT_LINES+=("GOOGLE_APPLICATION_CREDENTIALS=$(printf '%q' "$firebase_sa_file")")
      DEPLOY_SLOT_LINES+=("OP_PREFLIGHT_FIREBASE_SA_TMPFILE=$(printf '%q' "$firebase_sa_file")")
      DEPLOY_SLOT_LINES+=("OP_PREFLIGHT_FIREBASE_PROJECT=$(printf '%q' "$firebase_project")")
      SUMMARY+=("Firebase SA key ($firebase_project): loaded -> $firebase_sa_file")
      firebase_sa_loaded=true
    else
      rm -f "$firebase_sa_staged"
      SUMMARY+=("Firebase SA key ($firebase_project): SKIPPED (not found or did not match ${SA_NAME}@${firebase_project}.iam.gserviceaccount.com)")
    fi
  else
    SUMMARY+=("Firebase SA key: SKIPPED (no .firebaserc default project detected)")
  fi

  if [[ "$firebase_sa_loaded" != "true" ]]; then
    echo "# Preflight: reading GCP ADC (reuses session)..." >&2

    # Deterministic path so subsequent invocations find the same file. It is
    # shared by every context that resolves to ADC (the `adc` slot plus any
    # Firebase project without an SA key), so read into a staged sibling
    # (0600 under umask 077) and move it into place only once it validates:
    # a failed or stale fetch in one context must not truncate or delete the
    # file another context's session already exported.
    adc_staged="$(mktemp "$CACHE_DIR/op-preflight-$AGENT-adc.staged.XXXXXX")"

    log_deploy_biometric_once
    # Capture op's stderr so the could-not-read warning can say WHY (vault
    # locked / item not found / sign-in expired) instead of a bare "not
    # available" (#534.3). Routed through scrub_op_error so a service-account
    # token can never leak into the diagnostic, mirroring the Phase 1 reader.
    ADC_OP_ERR="$(mktemp "${TMPDIR:-/tmp}/op-preflight-adc-err.XXXXXX")"
    if op read "$DEFAULT_ADC_OP_URI" > "$adc_staged" 2>"$ADC_OP_ERR" && [[ -s "$adc_staged" ]]; then
      rm -f "$ADC_OP_ERR"
      if adc_is_usable "$adc_staged"; then
        mv -f "$adc_staged" "$ADC_TMPFILE"
        EXPORTS+=("export GOOGLE_APPLICATION_CREDENTIALS=$(printf '%q' "$ADC_TMPFILE")")
        EXPORTS+=("export OP_PREFLIGHT_ADC_TMPFILE=$(printf '%q' "$ADC_TMPFILE")")
        DEPLOY_SLOT_LINES+=("GOOGLE_APPLICATION_CREDENTIALS=$(printf '%q' "$ADC_TMPFILE")")
        DEPLOY_SLOT_LINES+=("OP_PREFLIGHT_ADC_TMPFILE=$(printf '%q' "$ADC_TMPFILE")")
        SUMMARY+=("GCP ADC: loaded -> $ADC_TMPFILE")
        adc_loaded=true
      else
        rm -f "$adc_staged"
        log_stale_adc_guidance
        SUMMARY+=("GCP ADC: STALE (refresh_token rejected — see warning above)")
        # Fail closed (#534.2): under `--mode deploy` a deploy script needs a
        # real credential. Degrading in place (continuing to OP_PREFLIGHT_DONE=1
        # with no GOOGLE_APPLICATION_CREDENTIALS) is the cache-hit path's
        # `exit 2` failure mode replayed on the full-fetch path — symmetric to
        # the line-696 cache-hit guard. `--mode all` deliberately keeps
        # degrading (callers still want the PATs), so scope this to deploy.
        if [[ "$MODE" == "deploy" ]]; then invalidate_deploy_slot; emit_deploy_failure_guard; exit 1; fi
      fi
    else
      adc_op_reason="$(scrub_op_error "$ADC_OP_ERR")"
      rm -f "$adc_staged" "$ADC_OP_ERR"
      if [[ -n "$adc_op_reason" ]]; then
        echo "# Warning: could not read GCP ADC. Deploy credentials not cached. (op: ${adc_op_reason})" >&2
      else
        echo "# Warning: could not read GCP ADC. Deploy credentials not cached." >&2
      fi
      SUMMARY+=("GCP ADC: SKIPPED (not available)")
      # Fail closed (#534.2): see STALE branch above.
      if [[ "$MODE" == "deploy" ]]; then invalidate_deploy_slot; emit_deploy_failure_guard; exit 1; fi
    fi
  fi

  # Only `--mode all` reaches here without a deploy credential (`deploy`
  # exited 1 above). Record the degradation in this context's slot so the
  # next `--mode all` cache hit here can reuse the verdict for
  # DEPLOY_DEGRADED_BACKOFF_SECONDS instead of re-prompting biometric just
  # to fail the same way. See emit_from_session_file.
  if [[ "$firebase_sa_loaded" != "true" && "$adc_loaded" != "true" ]]; then
    DEPLOY_SLOT_LINES+=("OP_PREFLIGHT_DEPLOY_DEGRADED=1")
    DEPLOY_SLOT_LINES+=("OP_PREFLIGHT_DEPLOY_DEGRADED_AT_EPOCH=$(date +%s)")
    SUMMARY+=("Deploy credentials: DEGRADED — later --mode all runs reuse this for ${DEPLOY_DEGRADED_BACKOFF_SECONDS}s (--refresh retries now)")
  fi

  # Cloudflare cache-purge token (#167). Optional — if 1Password is
  # unreachable for this item the deploy still proceeds; deploy.sh's
  # CF purge step gracefully no-ops on empty CF_API_TOKEN.
  echo "# Preflight: reading Cloudflare cache-purge token..." >&2
  cf_token=$(op read "$DEFAULT_CF_TOKEN_OP_URI" 2>/dev/null || true)
  if [[ -n "$cf_token" ]]; then
    EXPORTS+=("export CF_API_TOKEN=$(printf '%q' "$cf_token")")
    DEPLOY_SLOT_LINES+=("CF_API_TOKEN=$(printf '%q' "$cf_token")")
    SUMMARY+=("Cloudflare cache-purge token: loaded")
  else
    echo "# Warning: could not read Cloudflare cache-purge token. CF_API_TOKEN not exported; deploy.sh will skip the purge step." >&2
    SUMMARY+=("Cloudflare cache-purge token: SKIPPED (not available)")
  fi
fi

# ── Phase 2: SSH key warming ──────────────────────────────────────────
if [[ "$MODE" == "review" || "$MODE" == "all" ]] && ! $SKIP_SSH && ! $SERVICE_ACCOUNT_TOKEN_MODE; then
  warm_ssh_keys
elif $SERVICE_ACCOUNT_TOKEN_MODE; then
  SUMMARY+=("SSH/keyring: skipped (service account token mode)")
fi

# ── Persist session file ──────────────────────────────────────────────
CREATED_AT=$(date +%s)
{
  printf '# op-preflight session cache — do NOT edit by hand.\n'
  printf '# Agent:      %s\n' "$AGENT"
  printf '# Mode:       %s\n' "$MODE"
  printf '# Created:    %s (epoch %s)\n' "$(date -u -r "$CREATED_AT" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "@$CREATED_AT" +%Y-%m-%dT%H:%M:%SZ)" "$CREATED_AT"
  printf '# TTL:        %s seconds\n' "$TTL_SECONDS"
  printf 'OP_PREFLIGHT_CREATED_AT_EPOCH=%s\n' "$CREATED_AT"
  printf 'OP_PREFLIGHT_TTL_SECONDS=%s\n' "$TTL_SECONDS"
  printf 'OP_PREFLIGHT_AGENT=%q\n' "$AGENT"
  printf 'OP_PREFLIGHT_MODE=%q\n' "$MODE"
  printf 'OP_PREFLIGHT_DONE=1\n'
  for line in "${SESSION_LINES[@]}"; do
    printf '%s\n' "$line"
  done
} > "$SESSION_FILE"
chmod 600 "$SESSION_FILE"

if [[ "$MODE" == "deploy" || "$MODE" == "all" ]]; then
  deploy_slot_file="$(deploy_slot_file_for "$firebase_project")"
  # Stage then rename: a concurrent session of the same context sources this
  # path, and a half-written slot would read as stale (exit 2 -> refetch).
  deploy_slot_staged="$(mktemp "$CACHE_DIR/op-preflight-$AGENT-deploy-slot.staged.XXXXXX")"
  {
    printf '# op-preflight deploy-credential slot — do NOT edit by hand.\n'
    # The slot is SOURCED on the next read, so nothing here may be written
    # raw: a .firebaserc project decoded from JSON escapes can contain
    # newlines, and an unescaped comment line would turn them into commands
    # (Phase 4b on #1318). Every value is %q-quoted; the comment carries
    # only the slug, which deploy_context_slug restricts to [A-Za-z0-9_-].
    printf '# Agent: %s  Context: %s\n' "$AGENT" "$(deploy_context_slug "$firebase_project")"
    printf 'OP_PREFLIGHT_DEPLOY_CREATED_AT_EPOCH=%s\n' "$CREATED_AT"
    printf 'OP_PREFLIGHT_DEPLOY_CONTEXT=%q\n' "$firebase_project"
    for line in "${DEPLOY_SLOT_LINES[@]}"; do
      printf '%s\n' "$line"
    done
  } > "$deploy_slot_staged"
  chmod 600 "$deploy_slot_staged"
  mv -f "$deploy_slot_staged" "$deploy_slot_file"
fi

# ── Output ────────────────────────────────────────────────────────────
EXPORTS+=("export OP_PREFLIGHT_DONE=1")
EXPORTS+=("export OP_PREFLIGHT_AGENT=$(printf '%q' "$AGENT")")
# Export the mode on the full-fetch path too (#521), symmetric to the
# cache-hit path above, so consumers can read which mode ran regardless of
# whether the fetch was fresh or a cache hit.
EXPORTS+=("export OP_PREFLIGHT_MODE=$(printf '%q' "$MODE")")

# Print export statements to stdout (caller evals them)
for exp in "${EXPORTS[@]}"; do
  echo "$exp"
done

# Print summary to stderr (visible to user, not eval'd)
echo "" >&2
echo "# ── Preflight complete ──────────────────────────────" >&2
for line in "${SUMMARY[@]}"; do
  echo "#   $line" >&2
done
echo "# Session file: $SESSION_FILE (TTL ${TTL_SECONDS}s)" >&2
echo "# OP_PREFLIGHT_DONE=1" >&2
if ! $SERVICE_ACCOUNT_TOKEN_MODE; then
  warn_active_account_mismatch
fi
echo "# Human can step away." >&2
echo "# ──────────────────────────────────────────────────────" >&2
