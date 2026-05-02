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
#   eval "$(scripts/op-preflight.sh --agent claude --mode all)"
#
#   # Force a fresh fetch even if the session file is still warm:
#   eval "$(scripts/op-preflight.sh --agent claude --mode all --refresh)"
#
#   # Delete the session file + ADC tempfile (end-of-session cleanup):
#   scripts/op-preflight.sh --agent claude --purge
#
# Modes:
#   review  — reviewer PAT + author PAT + SSH key warming
#   deploy  — GCP ADC credential + Cloudflare cache-purge token
#   all     — everything (default)
#
# Flags:
#   --agent <name>   Agent name: claude, cursor, or codex (required except --purge-all)
#   --mode <mode>    review, deploy, or all (default: all)
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
#
# Session file:
#   Path:        $cache_dir/op-preflight-<agent>.env
#   Permissions: 600 (owner read/write only)
#   Format:      bash-sourceable KEY='value' lines (printf %q-escaped)
#   TTL anchor:  OP_PREFLIGHT_CREATED_AT_EPOCH (embedded in file, not mtime)
#
# After eval, downstream usage splits along the gh read/write boundary
# (see CLAUDE.md § Active-account convention):
#
#   # Read-path: GH_TOKEN authenticates the request (no byline involved).
#   GH_TOKEN="$OP_PREFLIGHT_REVIEWER_PAT" gh api user --jq .login
#   GH_TOKEN="$OP_PREFLIGHT_REVIEWER_PAT" scripts/codex-review-check.sh <PR#>
#
#   # Helpers that may also POST a trigger comment — GH_TOKEN authenticates
#   # the API call, but the comment byline is the active keyring account.
#   GH_TOKEN="$OP_PREFLIGHT_REVIEWER_PAT" scripts/coderabbit-wait.sh <PR#>
#   GH_TOKEN="$OP_PREFLIGHT_REVIEWER_PAT" scripts/codex-review-request.sh <PR#>
#
#   # Write-path: active keyring is the byline; GH_TOKEN is irrelevant.
#   # This script warns if active != expected.
#   gh pr review <PR#> --comment --body "..."   # active = nathanpayne-<agent>
#   gh auth switch -u nathanjohnpayne && gh pr merge <PR#> ... && \
#     gh auth switch -u nathanpayne-<agent>     # author write
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

ssh_host_for() {
  case "$1" in
    claude) echo "github-claude" ;;
    cursor) echo "github-cursor" ;;
    codex)  echo "github-codex" ;;
    *)      return 1 ;;
  esac
}

# ── Cache layout ──────────────────────────────────────────────────────
DEFAULT_CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/mergepath"
CACHE_DIR="${OP_PREFLIGHT_CACHE_DIR:-$DEFAULT_CACHE_DIR}"
DEFAULT_TTL_SECONDS=14400  # 4 hours
TTL_SECONDS="${OP_PREFLIGHT_TTL_SECONDS:-$DEFAULT_TTL_SECONDS}"

# ── GCP ADC ───────────────────────────────────────────────────────────
DEFAULT_ADC_OP_URI="${GCP_ADC_OP_URI:-op://Private/c2v6emkwppjzjjaq2bdqk3wnlm/credential}"

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
AGENT=""
MODE="all"
DRY_RUN=false
SKIP_SSH=false
REFRESH=false
PURGE=false
PURGE_ALL=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --agent)  AGENT="$2"; shift 2 ;;
    --mode)   MODE="$2"; shift 2 ;;
    --dry-run) DRY_RUN=true; shift ;;
    --skip-ssh) SKIP_SSH=true; shift ;;
    --refresh) REFRESH=true; shift ;;
    --purge) PURGE=true; shift ;;
    --purge-all) PURGE_ALL=true; shift ;;
    *)
      echo "Error: unknown argument: $1" >&2
      echo "Usage: eval \"\$(scripts/op-preflight.sh --agent claude --mode all)\"" >&2
      exit 1
      ;;
  esac
done

# ── Validate ──────────────────────────────────────────────────────────
if $PURGE_ALL; then
  if [[ -d "$CACHE_DIR" ]]; then
    echo "# Purging all session files under $CACHE_DIR" >&2
    find "$CACHE_DIR" -maxdepth 1 -type f \( -name 'op-preflight-*.env' -o -name 'op-preflight-*-adc.json' -o -name 'op-preflight-*.ssh-warmed' \) -print -delete >&2
  fi
  exit 0
fi

if [[ "$MODE" == "review" || "$MODE" == "all" || "$PURGE" == "true" ]] && [[ -z "$AGENT" ]]; then
  echo "Error: --agent is required for review, all, or --purge mode." >&2
  echo "Usage: eval \"\$(scripts/op-preflight.sh --agent claude --mode all)\"" >&2
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

# ── Cache paths (deterministic per agent) ─────────────────────────────
SESSION_FILE="$CACHE_DIR/op-preflight-$AGENT.env"
ADC_TMPFILE="$CACHE_DIR/op-preflight-$AGENT-adc.json"
SSH_WARM_MARKER="$CACHE_DIR/op-preflight-$AGENT.ssh-warmed"
SSH_WARM_TTL_SECONDS="${OP_PREFLIGHT_SSH_WARM_TTL_SECONDS:-1800}"  # 30 min default; #163

# ── Purge mode ────────────────────────────────────────────────────────
if $PURGE; then
  rm -f "$SESSION_FILE" "$ADC_TMPFILE" "$SSH_WARM_MARKER"
  echo "# Purged session file + ADC tempfile + SSH-warm marker for agent=$AGENT" >&2
  exit 0
fi

# ── Dry run ───────────────────────────────────────────────────────────
if $DRY_RUN; then
  echo "# op-preflight.sh --agent $AGENT --mode $MODE (dry run)" >&2
  echo "#" >&2
  echo "# Session file:   $SESSION_FILE" >&2
  echo "# ADC tempfile:   $ADC_TMPFILE" >&2
  echo "# TTL seconds:    $TTL_SECONDS" >&2
  if [[ -f "$SESSION_FILE" ]]; then
    embedded=$(grep '^OP_PREFLIGHT_CREATED_AT_EPOCH=' "$SESSION_FILE" | cut -d= -f2- | tr -d "'\"")
    now=$(date +%s)
    age=$((now - ${embedded:-0}))
    echo "# Session age:    ${age}s (TTL ${TTL_SECONDS}s)" >&2
  else
    echo "# Session age:    n/a (no session file)" >&2
  fi
  echo "#" >&2
  if [[ "$MODE" == "review" || "$MODE" == "all" ]]; then
    echo "# Would read: reviewer PAT ($(reviewer_pat_item_for "$AGENT"))" >&2
    echo "# Would read: author PAT ($AUTHOR_PAT_ITEM)" >&2
    if ! $SKIP_SSH; then
      echo "# Would warm SSH: $SSH_AUTHOR_HOST (author key)" >&2
      echo "# Would warm SSH: $(ssh_host_for "$AGENT") (reviewer key)" >&2
    fi
  fi
  if [[ "$MODE" == "deploy" || "$MODE" == "all" ]]; then
    echo "# Would read: GCP ADC ($DEFAULT_ADC_OP_URI)" >&2
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
  created_at=$(grep '^OP_PREFLIGHT_CREATED_AT_EPOCH=' "$SESSION_FILE" 2>/dev/null | cut -d= -f2- | tr -d "'\"")
  [[ -z "$created_at" ]] && return 1
  [[ "$created_at" =~ ^[0-9]+$ ]] || return 1
  now=$(date +%s)
  age=$((now - created_at))
  [[ "$age" -lt "$TTL_SECONDS" ]]
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
# Active-account check (warn-only). gh's write paths use the keyring's
# active account regardless of GH_TOKEN. Each agent's machine should
# have its agent identity (nathanpayne-<agent>) as the active gh
# account so reviewer-identity writes (gh pr review --comment) attribute
# correctly without a switch. Author-identity writes (gh pr create /
# merge / edit) still need a temporary `gh auth switch -u nathanjohnpayne`
# around them. See nathanjohnpayne/mergepath#164 for the empirical
# diagnosis (matchline PRs #181, #182 — wrong-byline reviews when active
# was nathanjohnpayne instead of the agent identity).
warn_active_account_mismatch() {
  # Skip silently when no agent is selected (e.g. deploy-only runs that
  # don't need a reviewer identity). The check only makes sense when
  # we know which agent identity SHOULD be active. Codex P2 on PR #171.
  [[ -z "$AGENT" ]] && return 0
  command -v gh >/dev/null 2>&1 || return 0
  local expected="nathanpayne-${AGENT}"
  local actual=""
  # Use `gh config get -h github.com user` to read the active keyring
  # account. This is the GH_TOKEN-immune signal:
  #
  #   - `gh auth status` honors GH_TOKEN — when GH_TOKEN is set, gh
  #     reports the GH_TOKEN entry as Active: true and flips the
  #     keyring entry to Active: false, even though writes still use
  #     the keyring active. Codex CHANGES_REQUESTED on #171 reproduced
  #     this masking: GH_TOKEN=<codex PAT> + keyring active=claude
  #     made `gh auth status` parsers report codex as active, masking
  #     the mismatch the warn function exists to surface.
  #
  #   - `gh config get -h github.com user` reads the keyring's stored
  #     active username directly from ~/.config/gh/hosts.yml. It does
  #     NOT honor GH_TOKEN. Verified: returns `nathanpayne-claude`
  #     unchanged with and without GH_TOKEN set.
  #
  # Wrap in `|| true` so a `gh config` failure (corrupt hosts.yml,
  # no gh login) cannot abort the parent under `set -eo pipefail`.
  actual=$(gh config get -h github.com user 2>/dev/null || true)
  if [[ -n "$actual" ]] && [[ "$actual" != "$expected" ]]; then
    echo "# WARNING: gh active account is '$actual' (expected '$expected')." >&2
    echo "#   Reviewer-identity writes (gh pr review) will mis-attribute." >&2
    echo "#   Fix once: gh auth switch -u $expected" >&2
    echo "#   See CLAUDE.md § Active-account convention for the full pattern." >&2
  fi
}

emit_from_session_file() (
  # Subshell: the (  ... ) above means unset/source/return here do
  # not escape back to the caller. We still "return" rc codes via
  # stdout+exit; parent stays clean.
  unset OP_PREFLIGHT_REVIEWER_PAT OP_PREFLIGHT_AUTHOR_PAT
  unset GOOGLE_APPLICATION_CREDENTIALS OP_PREFLIGHT_ADC_TMPFILE
  unset CF_API_TOKEN
  unset OP_PREFLIGHT_DONE OP_PREFLIGHT_AGENT OP_PREFLIGHT_MODE
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
    if [[ -z "${OP_PREFLIGHT_REVIEWER_PAT:-}" ]] || [[ -z "${OP_PREFLIGHT_AUTHOR_PAT:-}" ]]; then
      exit 2
    fi
  fi
  if [[ "$MODE" == "deploy" || "$MODE" == "all" ]]; then
    # Both `--mode deploy` and `--mode all` require a usable ADC from
    # the cache to take the fast path. If the session file's ADC field
    # is missing or the materialized file is unreadable, return 2 to
    # trigger a full refresh.
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
    if ! adc_is_usable "${GOOGLE_APPLICATION_CREDENTIALS}"; then
      # File exists but refresh token is rejected. Warn and skip the
      # export so downstream deploy callers can fall back to local
      # firebase-login / ADC. OP_PREFLIGHT_DONE stays 1 and PATs are
      # still emitted below, because preflight itself succeeded —
      # only the ADC-specific path is degraded, which matches what
      # the user will see when they run `gcloud auth ...` manually.
      log_stale_adc_guidance
      unset GOOGLE_APPLICATION_CREDENTIALS OP_PREFLIGHT_ADC_TMPFILE
    fi
  fi

  [[ -n "${OP_PREFLIGHT_REVIEWER_PAT:-}" ]] && \
    printf 'export OP_PREFLIGHT_REVIEWER_PAT=%q\n' "$OP_PREFLIGHT_REVIEWER_PAT"
  [[ -n "${OP_PREFLIGHT_AUTHOR_PAT:-}" ]] && \
    printf 'export OP_PREFLIGHT_AUTHOR_PAT=%q\n' "$OP_PREFLIGHT_AUTHOR_PAT"
  [[ -n "${GOOGLE_APPLICATION_CREDENTIALS:-}" ]] && \
    printf 'export GOOGLE_APPLICATION_CREDENTIALS=%q\n' "$GOOGLE_APPLICATION_CREDENTIALS"
  [[ -n "${OP_PREFLIGHT_ADC_TMPFILE:-}" ]] && \
    printf 'export OP_PREFLIGHT_ADC_TMPFILE=%q\n' "$OP_PREFLIGHT_ADC_TMPFILE"
  [[ -n "${CF_API_TOKEN:-}" ]] && \
    printf 'export CF_API_TOKEN=%q\n' "$CF_API_TOKEN"
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
    age=$(( $(date +%s) - $(grep '^OP_PREFLIGHT_CREATED_AT_EPOCH=' "$SESSION_FILE" | cut -d= -f2- | tr -d "'\"") ))
    # Warm SSH keys on the cache-hit path too. The cached PATs are
    # worthless for git push/pull if SSH auth isn't also primed, and
    # the prior implementation skipped this step entirely on cache
    # hit — a repro surfaced on the consumer-repo propagation PRs.
    SUMMARY=()
    if [[ "$MODE" == "review" || "$MODE" == "all" ]] && ! $SKIP_SSH; then
      warm_ssh_keys
    fi
    echo "" >&2
    echo "# ── Preflight cached hit (age ${age}s / TTL ${TTL_SECONDS}s) ──" >&2
    echo "# Session file: $SESSION_FILE" >&2
    for line in "${SUMMARY[@]}"; do
      echo "#   $line" >&2
    done
    echo "# Run with --refresh to force a new biometric fetch." >&2
    warn_active_account_mismatch
    echo "# ──────────────────────────────────────────────────────────" >&2
    exit 0
  fi
  # emit_from_session_file returned non-zero (e.g. ADC file vanished).
  # Fall through to full fetch.
  echo "# Session file stale or incomplete — refreshing" >&2
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

# ── Phase 1: CLI credentials (one biometric prompt + session reuse) ───
if [[ "$MODE" == "review" || "$MODE" == "all" ]]; then
  reviewer_item="$(reviewer_pat_item_for "$AGENT")"

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

if [[ "$MODE" == "deploy" || "$MODE" == "all" ]]; then
  echo "# Preflight: reading GCP ADC (reuses session)..." >&2

  # Deterministic path so subsequent invocations find the same file.
  # Overwrite in place — chmod 600 before writing secret content.
  touch "$ADC_TMPFILE"
  chmod 600 "$ADC_TMPFILE"

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
if [[ "$MODE" == "review" || "$MODE" == "all" ]] && ! $SKIP_SSH; then
  warm_ssh_keys
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
warn_active_account_mismatch
echo "# Human can step away." >&2
echo "# ──────────────────────────────────────────────────────" >&2
