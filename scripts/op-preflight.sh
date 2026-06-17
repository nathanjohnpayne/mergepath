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
#   eval "$(scripts/op-preflight.sh --agent claude --check)"
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
#   --check          Validate the session file is fresh and emit cached
#   --status         (alias for --check) exports WITHOUT invoking op.
#                    Never burns biometric, never warms SSH, never reads
#                    ADC. Exits non-zero if cache missing/stale. Mutually
#                    exclusive with --refresh, --purge, --purge-all. #282
#   --dry-run        Show what would be fetched without prompting
#   --skip-ssh       Skip SSH key warming (useful in CI or non-interactive)
#   --refresh        Force biometric fetch even if session file is fresh
#   --purge          Delete session file + ADC tempfile for the given --agent
#   --purge-all      Delete ALL session files + ADC tempfiles under the cache dir
#
# Environment:
#   OP_PREFLIGHT_TTL_SECONDS  Override default TTL (14400s = 4h). Age is
#                             measured against the session file's embedded
#                             timestamp, not file mtime, so `touch`-ing the
#                             file does NOT extend its effective lifetime.
#   OP_PREFLIGHT_CACHE_DIR    Override cache dir (default
#                             $XDG_CACHE_HOME/mergepath or $HOME/.cache/mergepath).
#   OP_PREFLIGHT_SSH_WARM_TTL_SECONDS
#                             Override SSH-warm freshness window (default
#                             1800s = 30 min). Independent of the PAT
#                             cache TTL because the 1Password SSH agent
#                             has its own session lifetime, typically
#                             shorter than 4h. Skipping re-warm within
#                             this window prevents a biometric prompt on
#                             every cache-hit invocation. See #163.
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
    codex)  echo "o6ekjxjjl5gq6rmcneomrjahpu" ;;
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
# Cache directory is intentionally shared across all consumer repos:
#   - The session file is keyed by --agent (see SESSION_FILE below).
#   - PATs are agent-keyed and currently uniform across the Phase 4
#     propagation set, so a shared cache is functionally correct.
# Re-evaluate if per-repo PATs ever diverge — at that point, namespace
# the cache path per consumer repo (e.g. $HOME/.cache/mergepath/$REPO).
DEFAULT_CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/mergepath"
CACHE_DIR="${OP_PREFLIGHT_CACHE_DIR:-$DEFAULT_CACHE_DIR}"
DEFAULT_TTL_SECONDS=14400  # 4 hours
TTL_SECONDS="${OP_PREFLIGHT_TTL_SECONDS:-$DEFAULT_TTL_SECONDS}"

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
    find "$CACHE_DIR" -maxdepth 1 -type f \( -name 'op-preflight-*.env' -o -name 'op-preflight-*-adc.json' -o -name 'op-preflight-*-firebase-sa.json' -o -name 'op-preflight-*.ssh-warmed' \) -print -delete >&2
  fi
  exit 0
fi

if [[ "$MODE" == "review" || "$MODE" == "all" || "$PURGE" == "true" || "$CHECK" == "true" ]] && [[ -z "$AGENT" ]]; then
  echo "Error: --agent is required for review, all, --purge, or --check mode." >&2
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
FIREBASE_SA_TMPFILE="$CACHE_DIR/op-preflight-$AGENT-firebase-sa.json"
SSH_WARM_MARKER="$CACHE_DIR/op-preflight-$AGENT.ssh-warmed"
BIOMETRIC_LOG="$CACHE_DIR/biometric-log"  # #282: append a one-line
                                          # record on each fresh fetch.
SSH_WARM_TTL_SECONDS="${OP_PREFLIGHT_SSH_WARM_TTL_SECONDS:-1800}"  # 30 min default; #163

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
if not isinstance(project, str) or not project:
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

firebaserc_default_project_no_python() {
  [[ -f .firebaserc ]] || return 1
  awk '
    { text = text $0 " " }
    END {
      if (!match(text, /"projects"[[:space:]]*:[[:space:]]*\{[^}]*\}/)) {
        exit 1
      }
      projects = substr(text, RSTART, RLENGTH)
      if (!match(projects, /"default"[[:space:]]*:[[:space:]]*"[^"]+"/)) {
        exit 1
      }
      matched = substr(projects, RSTART, RLENGTH)
      if (split(matched, parts, "\"") < 4) {
        exit 1
      }
      print parts[4]
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
  rm -f "$SESSION_FILE" "$ADC_TMPFILE" "$FIREBASE_SA_TMPFILE" "$SSH_WARM_MARKER"
  echo "# Purged session file + ADC tempfile + Firebase SA tempfile + SSH-warm marker for agent=$AGENT" >&2
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
  echo "# Firebase SA tempfile: $FIREBASE_SA_TMPFILE" >&2
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
    if firebase_project="$(detect_firebase_project 2>/dev/null || true)" && [[ -n "$firebase_project" ]]; then
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
    fi
  fi
  if [[ "$MODE" == "deploy" || "$MODE" == "all" ]]; then
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
    printf 'export OP_PREFLIGHT_REVIEWER_PAT=%q\n' "$OP_PREFLIGHT_REVIEWER_PAT"
  [[ -n "${OP_PREFLIGHT_AUTHOR_PAT:-}" ]] && \
    printf 'export OP_PREFLIGHT_AUTHOR_PAT=%q\n' "$OP_PREFLIGHT_AUTHOR_PAT"
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
    [[ -n "${GOOGLE_APPLICATION_CREDENTIALS:-}" ]] && \
      printf 'export GOOGLE_APPLICATION_CREDENTIALS=%q\n' "$GOOGLE_APPLICATION_CREDENTIALS"
    [[ -n "${OP_PREFLIGHT_ADC_TMPFILE:-}" ]] && \
      printf 'export OP_PREFLIGHT_ADC_TMPFILE=%q\n' "$OP_PREFLIGHT_ADC_TMPFILE"
    [[ -n "${OP_PREFLIGHT_FIREBASE_SA_TMPFILE:-}" ]] && \
      printf 'export OP_PREFLIGHT_FIREBASE_SA_TMPFILE=%q\n' "$OP_PREFLIGHT_FIREBASE_SA_TMPFILE"
    [[ -n "${OP_PREFLIGHT_FIREBASE_PROJECT:-}" ]] && \
      printf 'export OP_PREFLIGHT_FIREBASE_PROJECT=%q\n' "$OP_PREFLIGHT_FIREBASE_PROJECT"
    [[ -n "${CF_API_TOKEN:-}" ]] && \
      printf 'export CF_API_TOKEN=%q\n' "$CF_API_TOKEN"
  else
    # Review-only request (#466 r2): actively clear any deploy credentials a
    # prior --mode deploy / --mode all eval exported into the caller's
    # shell, so a review session does not retain stale deploy creds in its
    # environment (not just refrain from re-exporting them). Emitting unset
    # is idempotent when the caller never had them.
    printf 'unset GOOGLE_APPLICATION_CREDENTIALS OP_PREFLIGHT_ADC_TMPFILE OP_PREFLIGHT_FIREBASE_SA_TMPFILE OP_PREFLIGHT_FIREBASE_PROJECT CF_API_TOKEN\n'
  fi
  printf 'export OP_PREFLIGHT_DONE=1\n'
  printf 'export OP_PREFLIGHT_AGENT=%q\n' "$AGENT"
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
# than the 4h PAT TTL). Track an SSH-warm marker file and skip the
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
if $CHECK; then
  if ! session_is_fresh; then
    echo "# preflight: cache missing or stale for agent=$AGENT" >&2
    echo "#   run: scripts/op-preflight.sh --agent $AGENT --mode review" >&2
    echo "#   then re-run this command." >&2
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
    exit 2
  fi
  echo "$cached_exports"
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
  # capture above. rc=2 means cross-mode invalidation; anything else is
  # treated as stale-ADC by default for log clarity.
  if [[ "${rc:-0}" == "2" ]]; then
    BIOMETRIC_REASON="cross-mode-invalidation"
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
    SUMMARY+=("Reviewer PAT ($AGENT): loaded")
    SUMMARY+=("Author PAT: loaded")
  fi
fi

if [[ "$MODE" == "deploy" || "$MODE" == "all" ]]; then
  firebase_project="$(detect_firebase_project 2>/dev/null || true)"
  firebase_sa_loaded=false

  if [[ -n "$firebase_project" ]]; then
    echo "# Preflight: reading Firebase project SA key for $firebase_project..." >&2

    # Deterministic path so subsequent invocations and op-firebase-deploy
    # can reuse the same cached project SA key without a second biometric
    # prompt. Overwrite in place — chmod 600 before writing secret content.
    touch "$FIREBASE_SA_TMPFILE"
    chmod 600 "$FIREBASE_SA_TMPFILE"
    : > "$FIREBASE_SA_TMPFILE"

    # For --mode deploy (no review credentials loaded), this is the first
    # op call of the run — log it. For --mode all, the Phase 1 op inject
    # above already logged a single line covering the whole biometric
    # burst, so no second log entry is needed here.
    log_deploy_biometric_once
    if op document get "${firebase_project} — Firebase Deployer SA Key" \
         --vault "$FIREBASE_SA_VAULT" \
         --out-file "$FIREBASE_SA_TMPFILE" \
         --force >/dev/null 2>&1 \
       && firebase_sa_matches_project "$FIREBASE_SA_TMPFILE" "$firebase_project"; then
      EXPORTS+=("export GOOGLE_APPLICATION_CREDENTIALS=$(printf '%q' "$FIREBASE_SA_TMPFILE")")
      EXPORTS+=("export OP_PREFLIGHT_FIREBASE_SA_TMPFILE=$(printf '%q' "$FIREBASE_SA_TMPFILE")")
      EXPORTS+=("export OP_PREFLIGHT_FIREBASE_PROJECT=$(printf '%q' "$firebase_project")")
      SESSION_LINES+=("GOOGLE_APPLICATION_CREDENTIALS=$(printf '%q' "$FIREBASE_SA_TMPFILE")")
      SESSION_LINES+=("OP_PREFLIGHT_FIREBASE_SA_TMPFILE=$(printf '%q' "$FIREBASE_SA_TMPFILE")")
      SESSION_LINES+=("OP_PREFLIGHT_FIREBASE_PROJECT=$(printf '%q' "$firebase_project")")
      SUMMARY+=("Firebase SA key ($firebase_project): loaded -> $FIREBASE_SA_TMPFILE")
      firebase_sa_loaded=true
    else
      rm -f "$FIREBASE_SA_TMPFILE"
      SUMMARY+=("Firebase SA key ($firebase_project): SKIPPED (not found or did not match ${SA_NAME}@${firebase_project}.iam.gserviceaccount.com)")
    fi
  else
    SUMMARY+=("Firebase SA key: SKIPPED (no .firebaserc default project detected)")
  fi

  if [[ "$firebase_sa_loaded" != "true" ]]; then
    echo "# Preflight: reading GCP ADC (reuses session)..." >&2

    # Deterministic path so subsequent invocations find the same file.
    # Overwrite in place — chmod 600 before writing secret content.
    touch "$ADC_TMPFILE"
    chmod 600 "$ADC_TMPFILE"

    log_deploy_biometric_once
    if op read "$DEFAULT_ADC_OP_URI" > "$ADC_TMPFILE" 2>/dev/null && [[ -s "$ADC_TMPFILE" ]]; then
      if adc_is_usable "$ADC_TMPFILE"; then
        EXPORTS+=("export GOOGLE_APPLICATION_CREDENTIALS=$(printf '%q' "$ADC_TMPFILE")")
        EXPORTS+=("export OP_PREFLIGHT_ADC_TMPFILE=$(printf '%q' "$ADC_TMPFILE")")
        SESSION_LINES+=("GOOGLE_APPLICATION_CREDENTIALS=$(printf '%q' "$ADC_TMPFILE")")
        SESSION_LINES+=("OP_PREFLIGHT_ADC_TMPFILE=$(printf '%q' "$ADC_TMPFILE")")
        SUMMARY+=("GCP ADC: loaded -> $ADC_TMPFILE")
      else
        rm -f "$ADC_TMPFILE"
        log_stale_adc_guidance
        SUMMARY+=("GCP ADC: STALE (refresh_token rejected — see warning above)")
      fi
    else
      rm -f "$ADC_TMPFILE"
      echo "# Warning: could not read GCP ADC. Deploy credentials not cached." >&2
      SUMMARY+=("GCP ADC: SKIPPED (not available)")
    fi
  fi

  # Cloudflare cache-purge token (#167). Optional — if 1Password is
  # unreachable for this item the deploy still proceeds; deploy.sh's
  # CF purge step gracefully no-ops on empty CF_API_TOKEN.
  echo "# Preflight: reading Cloudflare cache-purge token..." >&2
  cf_token=$(op read "$DEFAULT_CF_TOKEN_OP_URI" 2>/dev/null || true)
  if [[ -n "$cf_token" ]]; then
    EXPORTS+=("export CF_API_TOKEN=$(printf '%q' "$cf_token")")
    SESSION_LINES+=("CF_API_TOKEN=$(printf '%q' "$cf_token")")
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

# ── Output ────────────────────────────────────────────────────────────
EXPORTS+=("export OP_PREFLIGHT_DONE=1")
EXPORTS+=("export OP_PREFLIGHT_AGENT=$(printf '%q' "$AGENT")")

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
