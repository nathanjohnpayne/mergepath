#!/usr/bin/env bash
# scripts/pr-assets-upload.sh — upload PR screenshots to nathanjohnpayne/pr-assets
# and print SHA-pinned Markdown image lines (mergepath#2938, part of #2935).
#
# The usage text below (print_usage) is the contract the canonical docs rule
# cites (#2939); keep the two in step.
#
# Design notes (the why; the what is in print_usage):
#
#   * One commit per invocation, built without a checkout: a shallow,
#     blob-less bare clone of pr-assets main (trees only, so the cost does
#     not grow with the store), the new blobs hashed into it, a tree written
#     through a private index, and `git commit-tree` on top of the fetched
#     tip. Nothing in the store is downloaded. The commit honours the
#     caller's signing configuration as resolved in the directory the script
#     was invoked from (repository-local and includeIf settings included):
#     commit.gpgSign is read and passed to commit-tree as -S (commit-tree
#     ignores the setting on its own), and the user.* / author.* /
#     committer.* / gpg.* settings are passed with -c, so user.signingkey,
#     gpg.format and gpg.*.program apply as for `git commit` there.
#     A signing failure stops the upload; an unsigned commit (signing not
#     configured) is pushed with a warning.
#
#   * Every network git operation (clone, fetch, push) runs with the caller's
#     git configuration switched off (GIT_CONFIG_GLOBAL=/dev/null, no system
#     config, no GIT_CONFIG_PARAMETERS/COUNT). A `url.<x>.insteadOf` rewrite,
#     an ambient credential helper (osxkeychain would store the token), a
#     hooksPath or a proxy helper in the caller's config can therefore neither
#     redirect the push nor see the credential. The fetch is anonymous (the
#     store is public). The push gets the token through a one-shot credential
#     helper that answers only `get` for https://github.com, from an
#     environment variable set on that one git process. The token is never
#     written to git config, to disk, or to argv.
#
#   * The push is a plain fast-forward to refs/heads/main (protected: no force
#     push, no deletion). When it is rejected because another upload landed
#     first, the script re-fetches, re-checks collisions against the new tip,
#     rebuilds and re-signs its commit, and retries, at most
#     PUSH_ATTEMPTS times. It never forces.
#
#   * The source repository is only ever READ, over the REST API (two GETs:
#     the repository and the issue/PR). This script never runs git against
#     it, so it cannot create a branch, tag or any other ref there.
#
#   * SVG is refused in v1. An SVG is an active document (script, external
#     references, CSS), not pixels: GitHub sanitises how it renders one, but
#     the store keeps the bytes forever and is cloned by nobody who could
#     review them, and every screenshot tool emits a raster format anyway.
#     Convert to PNG instead.
#
# Bash 3.2 portable (macOS /bin/bash).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Constants ─────────────────────────────────────────────────────────
STORE_REPO="nathanjohnpayne/pr-assets"
STORE_URL="https://github.com/${STORE_REPO}.git"
STORE_BRANCH="main"
AUTHOR_LOGIN="nathanjohnpayne"
SOURCE_OWNER="nathanjohnpayne"
RAW_BASE="https://raw.githubusercontent.com/${STORE_REPO}"
PUSH_ATTEMPTS=3
MAX_FILE_BYTES=$((20 * 1024 * 1024))
MAX_NAME_LEN=100

EXIT_USAGE=1
EXIT_INPUT=2
EXIT_REFUSED=3
EXIT_FAILED=4

print_usage() {
  cat <<'USAGE'
Usage:
  scripts/pr-assets-upload.sh --repo <owner/name> --pr <number> <file>...
  scripts/pr-assets-upload.sh --smoke <file>...

Uploads review evidence (screenshots) to the public assets repository
nathanjohnpayne/pr-assets, under <repo>/<number>/<file> (or _smoke/<file>),
in ONE commit, and prints one Markdown image line per file on stdout, pinned
to that commit's full SHA:

  ![<file>](https://raw.githubusercontent.com/nathanjohnpayne/pr-assets/<sha>/<repo>/<number>/<file>)

Paste the lines into the PR body or a comment. Nothing else goes to stdout.
Screenshots never go into the code repository or onto a branch of it; this
script never touches the source repository's git refs.

Options:
  --repo <owner/name>  The repository the evidence belongs to. It must be a
                       PUBLIC repository owned by nathanjohnpayne. A private
                       or internal repository is refused: its evidence never
                       goes to the public store. Use an approved private
                       method for visual evidence instead, or report that none
                       is available. The folder is the repository's name.
  --pr <number>        The pull request (or issue) number in --repo. It must
                       exist.
  --smoke              Upload to _smoke/ instead: upload and rendering checks
                       only, never review evidence. Not with --repo or --pr.
  -h, --help           Show this help.

Files:
  - PNG, JPEG, GIF or WebP only: the extension (.png, .jpg, .jpeg, .gif,
    .webp, lowercase) must match the file's content. SVG is refused; convert
    it to PNG.
  - The file's basename is its name in the store; rename it locally to choose
    the name. Names use letters, digits, '.', '_' and '-', start with a
    letter or digit, and are at most 100 characters. No personal data in a
    name. At most 20 MiB per file; two files in one call may not share a name.
  - Nothing is ever replaced or deleted (retention: keep everything). A name
    already in the folder with DIFFERENT content is refused; pick a new name.
    The same name with IDENTICAL content is not re-uploaded, and its line is
    printed again.

Privacy: everything in the store is public. A screenshot must meet the bar
of a public PR body: nothing from signed-in analytics or vendor dashboards,
no personal data, nothing from a private repository.

Credential: the identity-checked author credential scoped to pr-assets, read
from OP_PREFLIGHT_PR_ASSETS_PAT, which preflight caches:

  eval "$(scripts/op-preflight.sh --agent <agent> --mode pr-assets)"
  scripts/pr-assets-upload.sh --repo nathanjohnpayne/<name> --pr <N> desktop.png phone.png

Before writing, the script verifies that the token is a fine-grained PAT
that writes as nathanjohnpayne, and that the destination is exactly the
public nathanjohnpayne/pr-assets with push access. Ambient gh auth, GH_TOKEN
and reviewer identities are never used. The push is a fast-forward to main,
retried on a concurrent upload, never forced. The commit is signed when your
git signing configuration signs commits.

Exit codes:
  0  uploaded (or every file already present, identical); lines printed
  1  usage error
  2  input refused: missing file, type, name, size, or collision
  3  refused: credential, identity, destination, source repository
     (private, internal, other owner) or PR number
  4  failed: git, network, signing, push retries exhausted, or the pushed
     commit could not be confirmed on GitHub
USAGE
}

die() { # <exit code> <message> [<more lines>...]
  local code="$1"
  shift
  printf 'pr-assets-upload: %s\n' "$1" >&2
  shift
  if [ "$#" -gt 0 ]; then printf 'pr-assets-upload:   %s\n' "$@" >&2; fi
  exit "$code"
}

note() { printf 'pr-assets-upload: %s\n' "$*" >&2; }

# ── Environment hygiene ───────────────────────────────────────────────
# The scoped credential is taken into a shell variable and removed from the
# exported environment, together with every other credential an eval of
# preflight may have exported: no child process (git, the signing program,
# gh for a call that is not ours) inherits them. Inherited git location
# variables would point git at another repository entirely.
PR_ASSETS_TOKEN="${OP_PREFLIGHT_PR_ASSETS_PAT:-}"
unset OP_PREFLIGHT_PR_ASSETS_PAT OP_PREFLIGHT_AUTHOR_PAT OP_PREFLIGHT_REVIEWER_PAT \
  GH_TOKEN GITHUB_TOKEN GH_ENTERPRISE_TOKEN GITHUB_ENTERPRISE_TOKEN GH_HOST \
  GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY \
  GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_NAMESPACE GIT_COMMON_DIR
# Where the caller's own git configuration (identity, signing) is resolved.
CALLER_DIR="$(pwd -P)"
# Every git trace control, by prefix rather than by list: Trace2
# (GIT_TRACE2_EVENT with GIT_TRACE2_ENV_VARS=PR_ASSETS_PUSH_CREDENTIAL)
# records named environment variables, so the push credential would be
# written to the trace target in plain text, and the classic GIT_TRACE_*
# family can trace the HTTP exchange. A new trace variable is covered too.
for _v in $(compgen -e); do
  case "$_v" in GIT_TRACE*) unset "$_v" ;; esac
done
unset _v

# ── Arguments ─────────────────────────────────────────────────────────
SRC_REPO=""
PR_NUMBER=""
SMOKE=false
FILES=()

while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help) print_usage; exit 0 ;;
    --repo)
      [ "$#" -ge 2 ] || die "$EXIT_USAGE" "--repo requires a value (owner/name)."
      SRC_REPO="$2"; shift 2 ;;
    --repo=*) SRC_REPO="${1#--repo=}"; shift ;;
    --pr)
      [ "$#" -ge 2 ] || die "$EXIT_USAGE" "--pr requires a value (a number)."
      PR_NUMBER="$2"; shift 2 ;;
    --pr=*) PR_NUMBER="${1#--pr=}"; shift ;;
    --smoke) SMOKE=true; shift ;;
    --) shift; while [ "$#" -gt 0 ]; do FILES+=("$1"); shift; done ;;
    -*) die "$EXIT_USAGE" "unknown option: $1" "Run with --help for usage." ;;
    *) FILES+=("$1"); shift ;;
  esac
done

if $SMOKE; then
  if [ -n "$SRC_REPO" ] || [ -n "$PR_NUMBER" ]; then
    die "$EXIT_USAGE" "--smoke uploads to _smoke/ and takes no --repo or --pr."
  fi
else
  [ -n "$SRC_REPO" ] || die "$EXIT_USAGE" "--repo <owner/name> is required (or --smoke)." "Run with --help for usage."
  [ -n "$PR_NUMBER" ] || die "$EXIT_USAGE" "--pr <number> is required (or --smoke)." "Run with --help for usage."
  if ! printf '%s' "$SRC_REPO" | grep -Eq '^[A-Za-z0-9-]+/[A-Za-z0-9][A-Za-z0-9._-]*$'; then
    die "$EXIT_USAGE" "--repo must be owner/name, got '$SRC_REPO'."
  fi
  if ! printf '%s' "$PR_NUMBER" | grep -Eq '^[1-9][0-9]{0,9}$'; then
    die "$EXIT_USAGE" "--pr must be a positive integer, got '$PR_NUMBER'."
  fi
fi
[ "${#FILES[@]}" -gt 0 ] || die "$EXIT_USAGE" "no files given." "Run with --help for usage."

# ── File validation (local only; nothing touches the network yet) ─────
# Lowercase hex of the first 12 bytes.
magic_hex() {
  LC_ALL=C od -An -tx1 -N12 -- "$1" 2>/dev/null | tr -d ' \n'
}

# Does the content match the extension's image format?
content_matches_ext() { # <file> <ext>
  local hex
  hex="$(magic_hex "$1")"
  case "$2" in
    png) case "$hex" in 89504e470d0a1a0a*) return 0 ;; esac ;;
    jpg|jpeg) case "$hex" in ffd8ff*) return 0 ;; esac ;;
    gif) case "$hex" in 474946383761*|474946383961*) return 0 ;; esac ;;
    webp)
      # RIFF <4-byte size> WEBP
      case "$hex" in 52494646????????57454250) return 0 ;; esac ;;
  esac
  return 1
}

NAMES=()
ABS_FILES=()
for f in "${FILES[@]}"; do
  [ -e "$f" ] || die "$EXIT_INPUT" "file not found: $f"
  [ -f "$f" ] || die "$EXIT_INPUT" "not a regular file: $f"
  [ -r "$f" ] || die "$EXIT_INPUT" "file not readable: $f"
  name="$(basename -- "$f")"
  if [ "${#name}" -gt "$MAX_NAME_LEN" ]; then
    die "$EXIT_INPUT" "file name longer than $MAX_NAME_LEN characters: $name"
  fi
  if ! printf '%s' "$name" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9._-]*$'; then
    die "$EXIT_INPUT" "file name '$name' is not allowed." \
      "Names use letters, digits, '.', '_' and '-', and start with a letter or digit. Rename the file locally."
  fi
  ext="${name##*.}"
  [ "$ext" != "$name" ] || die "$EXIT_INPUT" "file name '$name' has no extension."
  case "$ext" in
    png|jpg|jpeg|gif|webp) ;;
    svg|SVG)
      die "$EXIT_INPUT" "'$name': SVG is refused (an SVG is an active document, not pixels)." \
        "Convert it to PNG and upload that." ;;
    *)
      die "$EXIT_INPUT" "'$name': only .png, .jpg, .jpeg, .gif and .webp (lowercase) are accepted." ;;
  esac
  size="$(wc -c < "$f" | tr -d ' ')"
  [ "$size" -gt 0 ] || die "$EXIT_INPUT" "'$name' is empty."
  if [ "$size" -gt "$MAX_FILE_BYTES" ]; then
    die "$EXIT_INPUT" "'$name' is $size bytes; the limit is $MAX_FILE_BYTES (20 MiB)."
  fi
  if ! content_matches_ext "$f" "$ext"; then
    die "$EXIT_INPUT" "'$name': the content is not a .$ext image." \
      "Only real PNG, JPEG, GIF and WebP files are accepted, with a matching extension."
  fi
  if [ "${#NAMES[@]}" -gt 0 ]; then
    for seen in "${NAMES[@]}"; do
      [ "$seen" != "$name" ] || die "$EXIT_INPUT" "two files share the name '$name'; each file needs its own name."
    done
  fi
  NAMES+=("$name")
  # Absolute from here on: git later runs with -C <work repo>, where a
  # relative path would resolve against the wrong directory.
  dir="$(cd -P -- "$(dirname -- "$f")" && pwd)" || die "$EXIT_INPUT" "cannot resolve the directory of $f"
  ABS_FILES+=("$dir/$name")
done

# ── Credential: present, fine-grained, identity-checked ───────────────
if [ -z "$PR_ASSETS_TOKEN" ]; then
  die "$EXIT_REFUSED" "OP_PREFLIGHT_PR_ASSETS_PAT is not set." \
    "Run: eval \"\$(scripts/op-preflight.sh --agent <agent> --mode pr-assets)\"" \
    "Ambient gh auth and GH_TOKEN are never used for uploads."
fi

CLASS_LIB="$SCRIPT_DIR/lib/credential-class.sh"
IDENTITY_CHECK="$SCRIPT_DIR/identity-check.sh"
[ -r "$CLASS_LIB" ] || die "$EXIT_REFUSED" "credential classifier missing: $CLASS_LIB"
[ -x "$IDENTITY_CHECK" ] || die "$EXIT_REFUSED" "identity checker missing or not executable: $IDENTITY_CHECK"
# shellcheck source=lib/credential-class.sh
. "$CLASS_LIB"

# A fine-grained PAT is the only form that can be scoped to one repository,
# which the owner decision on #2936 requires.
if ! credential_meets_author_token_class fine-grained "$PR_ASSETS_TOKEN"; then
  die "$EXIT_REFUSED" "OP_PREFLIGHT_PR_ASSETS_PAT is not a fine-grained personal access token." \
    "Uploads use only the author credential scoped to $STORE_REPO (a github_pat_ token)."
fi

command -v gh >/dev/null 2>&1 || die "$EXIT_FAILED" "gh is required and was not found on PATH."
command -v git >/dev/null 2>&1 || die "$EXIT_FAILED" "git is required and was not found on PATH."

# Every gh call: the scoped token only, pinned to github.com, GET only.
gh_get() {
  GH_TOKEN="$PR_ASSETS_TOKEN" GH_HOST=github.com GH_PROMPT_DISABLED=1 \
    gh api --hostname github.com --method GET "$@"
}

if ! GH_TOKEN="$PR_ASSETS_TOKEN" GH_HOST=github.com \
     "$IDENTITY_CHECK" --expect-write-identity "$AUTHOR_LOGIN" >/dev/null; then
  die "$EXIT_REFUSED" "the pr-assets credential does not verify as $AUTHOR_LOGIN (see identity-check above)." \
    "Uploads are made only as the author identity, never as a reviewer or bot."
fi

# ── Destination: exactly the public store, writable ───────────────────
if ! dest_info="$(gh_get "repos/$STORE_REPO" \
     --jq '[.full_name, .visibility, (.permissions.push | tostring), .default_branch] | @tsv' 2>/dev/null)"; then
  die "$EXIT_REFUSED" "could not read $STORE_REPO with the pr-assets credential."
fi
IFS=$'\t' read -r dest_name dest_vis dest_push dest_branch <<EOF
$dest_info
EOF
if [ "$dest_name" != "$STORE_REPO" ]; then
  die "$EXIT_REFUSED" "destination resolves to '$dest_name', not $STORE_REPO (renamed or transferred?)." \
    "Refusing to write anywhere but $STORE_REPO."
fi
[ "$dest_vis" = "public" ] || die "$EXIT_REFUSED" "$STORE_REPO is '$dest_vis', not public; refusing to upload."
[ "$dest_push" = "true" ] || die "$EXIT_REFUSED" "the pr-assets credential has no push access to $STORE_REPO."
[ "$dest_branch" = "$STORE_BRANCH" ] || die "$EXIT_REFUSED" "$STORE_REPO default branch is '$dest_branch', not $STORE_BRANCH."

# ── Source repository: public, ours, and the PR exists ────────────────
if $SMOKE; then
  DEST_DIR="_smoke"
  SUBJECT="smoke-check"
  REF_LINE=""
else
  if ! src_info="$(gh_get "repos/$SRC_REPO" \
       --jq '[.full_name, .owner.login, .name, .visibility, (.private | tostring)] | @tsv' 2>/dev/null)"; then
    die "$EXIT_REFUSED" "could not read $SRC_REPO as a public repository." \
      "A private repository reads as not found with this credential, and private evidence never goes to the public store." \
      "Use an approved private method for visual evidence, or report that none is available."
  fi
  IFS=$'\t' read -r src_full src_owner src_name src_vis src_private <<EOF
$src_info
EOF
  if [ "$src_vis" != "public" ] || [ "$src_private" != "false" ]; then
    die "$EXIT_REFUSED" "$src_full is ${src_vis:-not public}; its screenshots never go to the public store." \
      "Use an approved private method for visual evidence, or report that none is available."
  fi
  if [ "$src_owner" != "$SOURCE_OWNER" ]; then
    die "$EXIT_REFUSED" "$src_full is not owned by $SOURCE_OWNER; the store holds evidence for $SOURCE_OWNER's repositories only."
  fi
  if ! printf '%s' "$src_name" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9._-]*$'; then
    die "$EXIT_REFUSED" "unexpected repository name from the API: '$src_name'."
  fi
  if ! pr_found="$(gh_get "repos/$src_full/issues/$PR_NUMBER" --jq '.number' 2>/dev/null)" \
     || [ "$pr_found" != "$PR_NUMBER" ]; then
    die "$EXIT_REFUSED" "$src_full has no pull request or issue #$PR_NUMBER."
  fi
  DEST_DIR="$src_name/$PR_NUMBER"
  SUBJECT="$src_full#$PR_NUMBER"
  REF_LINE="Refs $src_full#$PR_NUMBER"
fi

# ── Work area ─────────────────────────────────────────────────────────
WORK_PARENT="$(mktemp -d "${TMPDIR:-/tmp}/pr-assets-upload.XXXXXX")"
trap 'rm -rf "$WORK_PARENT"' EXIT
WORK="$WORK_PARENT/store.git"
INDEX="$WORK_PARENT/index"

REMOTE_URL="$STORE_URL"
if [ -n "${PR_ASSETS_TEST_REMOTE_URL:-}" ]; then
  # Test seam only: a local bare repository standing in for the store. A
  # file:// URL never consults a credential helper, so the token cannot
  # reach it; anything else is refused.
  case "$PR_ASSETS_TEST_REMOTE_URL" in
    file:///*) REMOTE_URL="$PR_ASSETS_TEST_REMOTE_URL"
      note "TEST MODE: pushing to $REMOTE_URL, not $STORE_URL." ;;
    *) die "$EXIT_REFUSED" "PR_ASSETS_TEST_REMOTE_URL must be a file:// URL (test seam); refusing '$PR_ASSETS_TEST_REMOTE_URL'." ;;
  esac
fi

# Git with the caller's configuration switched off. Used for every operation
# except commit-tree. Also dropped: environment that would disable TLS
# verification, or trace the HTTP exchange (and so the Authorization header)
# to stderr. HOME points at an empty directory: git's HTTP transport reads
# $HOME/.netrc (CURL_NETRC_OPTIONAL) whatever the config says, so the
# caller's netrc could otherwise supply an unchecked credential to the push.
ISOLATED_HOME="$WORK_PARENT/home"
mkdir -p "$ISOLATED_HOME"
git_h() {
  env -u GIT_CONFIG_PARAMETERS -u GIT_CONFIG_COUNT -u GIT_ASKPASS -u SSH_ASKPASS \
    -u GIT_SSL_NO_VERIFY -u GIT_TRACE -u GIT_TRACE_CURL -u GIT_TRACE_CURL_NO_DATA \
    -u GIT_TRACE_PACKET -u GIT_CURL_VERBOSE -u GIT_TRACE_REDACT -u XDG_CONFIG_HOME \
    HOME="$ISOLATED_HOME" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_TERMINAL_PROMPT=0 \
    git "$@"
}

# The one-shot credential helper: answers `get` for https://github.com only.
# The token reaches it through PR_ASSETS_PUSH_CREDENTIAL, set on the push
# process alone. `credential.helper=` first clears any helper list.
# shellcheck disable=SC2016  # expanded by the helper's shell, by design
CRED_HELPER='!f() { test "$1" = get || exit 0; p=; h=; while IFS= read -r l; do case "$l" in protocol=https) p=1 ;; host=github.com) h=1 ;; esac; done; test -n "$p" && test -n "$h" || exit 0; printf "username=x-access-token\npassword=%s\n" "$PR_ASSETS_PUSH_CREDENTIAL"; }; f'

if ! git_h clone --quiet --bare --depth=1 --filter=blob:none --single-branch \
     --branch "$STORE_BRANCH" --no-tags -c credential.helper= "$REMOTE_URL" "$WORK" 2>"$WORK_PARENT/clone.err"; then
  sed 's/^/pr-assets-upload:   git: /' "$WORK_PARENT/clone.err" >&2 || true
  die "$EXIT_FAILED" "could not fetch $STORE_REPO $STORE_BRANCH."
fi
git_h -C "$WORK" config credential.helper ""

# Hash every file into the work repository once; the blob ids do not
# depend on the base, so retries reuse them.
OIDS=()
i=0
while [ "$i" -lt "${#ABS_FILES[@]}" ]; do
  oid="$(git_h -C "$WORK" hash-object -w --no-filters -- "${ABS_FILES[$i]}")" \
    || die "$EXIT_FAILED" "could not hash ${ABS_FILES[$i]}."
  OIDS+=("$oid")
  i=$((i + 1))
done

# Build and commit on top of BASE. Sets NEW_COMMIT (empty when every file is
# already present with identical content) and ADDED_COUNT.
build_commit() { # <base sha>
  local base="$1" j=0 path existing type eoid added=0 msg tree
  NEW_COMMIT=""
  rm -f "$INDEX"
  GIT_INDEX_FILE="$INDEX" git_h -C "$WORK" read-tree "$base" \
    || die "$EXIT_FAILED" "could not read the $STORE_BRANCH tree."
  while [ "$j" -lt "${#NAMES[@]}" ]; do
    path="$DEST_DIR/${NAMES[$j]}"
    existing="$(git_h -C "$WORK" ls-tree "$base" -- "$path")"
    if [ -n "$existing" ]; then
      read -r _ type eoid _ <<EOF
$existing
EOF
      if [ "$type" != "blob" ]; then
        die "$EXIT_INPUT" "$path already exists in $STORE_REPO as a $type; refusing to upload over it."
      fi
      if [ "$eoid" != "${OIDS[$j]}" ]; then
        die "$EXIT_INPUT" "$path already exists in $STORE_REPO with different content." \
          "Nothing is ever replaced (retention: keep everything). Rename the file and upload it again."
      fi
      note "$path is already in $STORE_REPO with identical content; not re-uploading."
    else
      GIT_INDEX_FILE="$INDEX" git_h -C "$WORK" update-index --add \
        --cacheinfo "100644,${OIDS[$j]},$path" \
        || die "$EXIT_INPUT" "could not add $path (does a file block the folder?)."
      added=$((added + 1))
    fi
    j=$((j + 1))
  done
  ADDED_COUNT="$added"
  [ "$added" -gt 0 ] || return 0
  tree="$(GIT_INDEX_FILE="$INDEX" git_h -C "$WORK" write-tree --missing-ok)" \
    || die "$EXIT_FAILED" "could not write the new tree."
  if $SMOKE; then
    msg="chore(_smoke): add $added upload-check file(s)"
  else
    msg="chore($src_name): add $added screenshot(s) for $SUBJECT"
  fi
  msg="$msg

Uploaded by scripts/pr-assets-upload.sh into $DEST_DIR/."
  [ -z "$REF_LINE" ] || msg="$msg

$REF_LINE"
  # The caller's own git config, deliberately: identity and signing.
  # commit-tree does not read commit.gpgSign itself (only `git commit`
  # does), so the setting is read here and turned into -S; the key, format
  # and program then come from user.signingkey / gpg.* as usual.
  if ! NEW_COMMIT="$(printf '%s\n' "$msg" | git ${COMMIT_CFG[@]+"${COMMIT_CFG[@]}"} -C "$WORK" commit-tree ${SIGN_ARGS[@]+"${SIGN_ARGS[@]}"} "$tree" -p "$base" 2>"$WORK_PARENT/commit.err")"; then
    sed 's/^/pr-assets-upload:   git: /' "$WORK_PARENT/commit.err" >&2 || true
    die "$EXIT_FAILED" "could not create the commit (signing failure?). Nothing was pushed."
  fi
  if ! git_h -C "$WORK" cat-file commit "$NEW_COMMIT" | grep -q '^gpgsig'; then
    note "WARNING: commit $NEW_COMMIT is unsigned (your git config does not sign commits); pr-assets pushes should be signed."
  fi
}

fetch_tip() {
  git_h -C "$WORK" fetch --quiet --depth=1 --no-tags origin \
    "+refs/heads/$STORE_BRANCH:refs/heads/$STORE_BRANCH" 2>/dev/null \
    || return 1
  git_h -C "$WORK" rev-parse --verify "refs/heads/$STORE_BRANCH^{commit}"
}

BASE="$(git_h -C "$WORK" rev-parse --verify "refs/heads/$STORE_BRANCH^{commit}")" \
  || die "$EXIT_FAILED" "fetched $STORE_REPO has no $STORE_BRANCH."

# Read with the caller's config (not git_h), in the caller's directory: the
# same answer `git commit` would act on there. Read in "$WORK" instead, a
# repository-local or includeIf-scoped setting of the invoking repository
# would be lost. An unreadable value is an error, not "off".
SIGN_ARGS=()
gpgsign_rc=0
gpgsign="$(git -C "$CALLER_DIR" config --type=bool --get commit.gpgsign 2>/dev/null)" || gpgsign_rc=$?
case "$gpgsign_rc" in
  0) [ "$gpgsign" != "true" ] || SIGN_ARGS=(-S) ;;
  1) ;;
  *) die "$EXIT_FAILED" "could not read commit.gpgSign from your git config." ;;
esac
# Identity and signing settings (user.*, author.*, committer.*, gpg.*) as
# resolved in the caller's directory, passed to commit-tree with -c so they
# apply inside "$WORK". Whole sections, so a key commit-tree consults is not
# dropped by an incomplete list. Only commit-tree gets them; it is local.
COMMIT_CFG=()
cfg_rc=0
cfg_dump="$WORK_PARENT/commit-config"
git -C "$CALLER_DIR" config -z --get-regexp '^(user|author|committer|gpg)\.' >"$cfg_dump" 2>/dev/null || cfg_rc=$?
case "$cfg_rc" in
  0|1) ;;
  *) die "$EXIT_FAILED" "could not read identity and signing settings from your git config." ;;
esac
while IFS= read -r -d '' cfg_entry; do
  case "$cfg_entry" in
    *$'\n'*) COMMIT_CFG+=(-c "${cfg_entry%%$'\n'*}=${cfg_entry#*$'\n'}") ;;
    *) COMMIT_CFG+=(-c "$cfg_entry") ;;
  esac
done <"$cfg_dump"

PINNED=""
attempt=1
while :; do
  build_commit "$BASE"
  if [ -z "$NEW_COMMIT" ]; then
    PINNED="$BASE"
    break
  fi
  if PR_ASSETS_PUSH_CREDENTIAL="$PR_ASSETS_TOKEN" git_h -C "$WORK" \
       -c credential.helper= -c "credential.helper=$CRED_HELPER" \
       push --quiet --no-verify "$REMOTE_URL" "$NEW_COMMIT:refs/heads/$STORE_BRANCH" \
       2>"$WORK_PARENT/push.err"; then
    PINNED="$NEW_COMMIT"
    break
  fi
  # Rejected. Retry only when the store moved underneath us; anything else
  # (auth, protection, network) is a hard failure.
  if ! tip="$(fetch_tip)"; then
    sed 's/^/pr-assets-upload:   git: /' "$WORK_PARENT/push.err" >&2 || true
    die "$EXIT_FAILED" "push failed and $STORE_REPO could not be re-fetched."
  fi
  if [ "$tip" = "$BASE" ]; then
    sed 's/^/pr-assets-upload:   git: /' "$WORK_PARENT/push.err" >&2 || true
    die "$EXIT_FAILED" "push to $STORE_REPO $STORE_BRANCH was rejected (not a concurrent upload)."
  fi
  if [ "$attempt" -ge "$PUSH_ATTEMPTS" ]; then
    die "$EXIT_FAILED" "$STORE_REPO $STORE_BRANCH kept moving; gave up after $PUSH_ATTEMPTS attempts. Nothing of this upload was pushed."
  fi
  note "$STORE_BRANCH moved (concurrent upload); rebuilding on ${tip:0:12} (attempt $((attempt + 1)) of $PUSH_ATTEMPTS)."
  BASE="$tip"
  attempt=$((attempt + 1))
done

# ── Confirm the pinned commit on GitHub, then print ───────────────────
confirmed=""
for try in 1 2 3; do
  confirmed="$(gh_get "repos/$STORE_REPO/commits/$PINNED" --jq '.sha' 2>/dev/null || true)"
  [ "$confirmed" != "$PINNED" ] || break
  [ "$try" -eq 3 ] || sleep 2
done
if [ "$confirmed" != "$PINNED" ]; then
  die "$EXIT_FAILED" "commit $PINNED could not be confirmed on GitHub; not printing unverified links." \
    "Re-run the same command: files already present with identical content are not re-uploaded."
fi

if [ "$ADDED_COUNT" -gt 0 ]; then
  note "uploaded $ADDED_COUNT file(s) to $STORE_REPO in $PINNED."
fi
for name in "${NAMES[@]}"; do
  printf '![%s](%s/%s/%s/%s)\n' "$name" "$RAW_BASE" "$PINNED" "$DEST_DIR" "$name"
done
