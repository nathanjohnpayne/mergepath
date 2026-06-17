#!/usr/bin/env bash
set -euo pipefail

# verify-propagation-pr.sh — authoritative faithful-mirror check for
# the propagation-PR review lane (REVIEW_POLICY.md § Propagation PR
# review lane, mergepath#264 / #268 / #323).
#
# The lane exempts a sync PR from Phase 4 external review. That is
# only safe if the PR is PROVABLY a verbatim mirror of mergepath's
# canonical/kit content — not merely "confined to manifest-typed
# paths" (Codex P1 on #268: a mergepath-sync/* PR could otherwise
# hand-edit a workflow, which IS a manifest path, and skip review).
#
# This script is the teeth. It byte-compares every file the PR
# changes against the SAME path in a checkout of mergepath at the
# sync's source commit. It is TRUSTED ONLY when invoked from that
# mergepath checkout (the immutable, public commit the PR's branch
# name points at) — never from the PR's own checkout, which the PR
# could have tampered with.
#
# Two verification surfaces:
#
#   A. Canonical / kit entries — byte-for-byte equality against
#      mergepath@<sha>. Implemented as a `git ls-tree` mode+oid
#      compare so an exec-bit flip is also caught.
#
#   B. Templated entries (#323) — render the source template at
#      mergepath@<sha> with the consumer's facts (loaded from the
#      mergepath-side manifest via export_consumer_facts) and
#      byte-compare the rendered output against the PR's dest
#      content. Drift, template syntax errors, and missing facts in
#      strict mode all fail the verification with a typed
#      diagnostic. On pass, a structured line of the form
#      "[mergepath-verify: templated-render] <dest> <consumer> <source>"
#      is emitted on stdout so a calling workflow can post it as a
#      thread tag-reply. This script intentionally stays read-only —
#      it does NOT post to GitHub.
#
# Consumer inference (templated surface only):
#   1. $MERGEPATH_CONSUMER env override (test/CI escape hatch).
#   2. consumer_dir's `origin` remote URL → matched against the
#      manifest's .consumers[].repo field.
#   3. If neither resolves, the templated surface is SKIPPED with a
#      stderr note (the canonical/kit surface still runs). This is
#      conservative: a templated entry whose consumer can't be
#      identified is just left to the existing path-confinement
#      check, which will fail because the templated dest doesn't
#      equal the templated .path — the PR then routes to normal
#      Phase 4 review, same as the pre-#323 status quo.
#
# Usage:
#   verify-propagation-pr.sh <mergepath_dir> <consumer_dir> <base_sha> <head_sha>
#
#   mergepath_dir  a checkout of nathanjohnpayne/mergepath at the
#                  sync's source commit (the <sha> in the PR branch
#                  name mergepath-sync/[sync-all-]<sha>). Provides BOTH
#                  the authoritative manifest AND the canonical content
#                  to compare against.
#   consumer_dir   the consumer repo's PR checkout (a git work tree;
#                  base..head must be resolvable in it).
#   base_sha       PR base SHA.
#   head_sha       PR head SHA.
#
# Exit codes:
#   0  faithful mirror — every changed file is under a manifest path
#      AND its end-state byte-matches mergepath@<sha> (both-present-
#      equal, or both-absent), with templated dests matching their
#      re-rendered output. The PR is lane-eligible.
#   1  NOT a faithful mirror — at least one changed file is off-
#      manifest, deviates from mergepath@<sha>, or its templated
#      re-render diverges. The PR must go through normal Phase 3/4
#      review. Deviations are listed on stderr.
#   2  usage / environment error (bad args, missing manifest, etc.).
#
# Bash 3.2 portable: no `mapfile`, no associative arrays.

usage() {
  echo "usage: verify-propagation-pr.sh <mergepath_dir> <consumer_dir> <base_sha> <head_sha>" >&2
  exit 2
}

MERGEPATH_DIR="${1:-}"
CONSUMER_DIR="${2:-}"
BASE_SHA="${3:-}"
HEAD_SHA="${4:-}"
[ -n "$MERGEPATH_DIR" ] && [ -n "$CONSUMER_DIR" ] && [ -n "$BASE_SHA" ] && [ -n "$HEAD_SHA" ] || usage

MANIFEST="$MERGEPATH_DIR/.mergepath-sync.yml"
if [ ! -f "$MANIFEST" ]; then
  echo "verify-propagation-pr.sh: no .mergepath-sync.yml in mergepath checkout: $MANIFEST" >&2
  exit 2
fi

# The parser is taken from the mergepath checkout too — TRUSTED,
# same provenance as the manifest and the canonical content.
PARSE_MANIFEST="$MERGEPATH_DIR/scripts/workflow/parse_manifest_paths.sh"
MATCH_PATHS="$MERGEPATH_DIR/scripts/workflow/match_protected_paths.sh"
for h in "$PARSE_MANIFEST" "$MATCH_PATHS"; do
  if [ ! -f "$h" ]; then
    echo "verify-propagation-pr.sh: missing trusted helper in mergepath checkout: $h" >&2
    exit 2
  fi
done

# Authoritative propagation surface — from mergepath@<sha>, NOT the PR.
MAN_PATTERNS=()
while IFS= read -r p; do
  [ -n "$p" ] && MAN_PATTERNS+=("$p")
done < <(bash "$PARSE_MANIFEST" "$MANIFEST")
if [ "${#MAN_PATTERNS[@]}" -eq 0 ]; then
  echo "verify-propagation-pr.sh: manifest declares no propagation paths" >&2
  exit 2
fi

# Files the PR changes (three-dot: changes since the merge-base, the
# same range the External Review Check uses).
CHANGED_FILES=$(git -C "$CONSUMER_DIR" diff --name-only "$BASE_SHA...$HEAD_SHA")
if [ -z "$CHANGED_FILES" ]; then
  echo "verify-propagation-pr.sh: PR has no changed files — nothing to verify" >&2
  exit 1
fi

# Failure aggregation. Three typed categories so the summary at exit
# can distinguish the failure mode for diagnostics:
#   CANONICAL_FAILURES  — off-manifest / mode-or-blob drift on
#                         canonical or kit entries.
#   TEMPLATED_FAILURES  — re-rendered output diverges from PR dest
#                         content.
#   TEMPLATED_ERRORS    — render itself failed (malformed template,
#                         strict-mode unset fact, source missing
#                         from mergepath@<sha>).
FAILURES=""
CANONICAL_FAILURES=""
TEMPLATED_FAILURES=""
TEMPLATED_ERRORS=""
fail() { FAILURES="${FAILURES}  - $1"$'\n'; CANONICAL_FAILURES="${CANONICAL_FAILURES}  - $1"$'\n'; }
fail_templated_drift() { FAILURES="${FAILURES}  - $1"$'\n'; TEMPLATED_FAILURES="${TEMPLATED_FAILURES}  - $1"$'\n'; }
fail_templated_error() { FAILURES="${FAILURES}  - $1"$'\n'; TEMPLATED_ERRORS="${TEMPLATED_ERRORS}  - $1"$'\n'; }

# -------------------------------------------------------------------
# Templated surface (#323) — handled BEFORE the canonical loop so
# verified templated dests are exempted from the path-confinement
# check (the dest doesn't equal any .path and would otherwise fail).
# -------------------------------------------------------------------

# VERIFIED_TEMPLATED_DESTS — list (newline-separated, sentinel-padded)
# of consumer-side dest paths whose re-render matched. Checked in the
# canonical loop below so we don't double-fail-them as off-manifest.
VERIFIED_TEMPLATED_DESTS=""

# infer_consumer_from_pr_context — determine which consumer this PR
# belongs to, for templated render. Strategies, in order:
#   1. $MERGEPATH_CONSUMER env override (test/CI escape hatch).
#   2. consumer_dir's `origin` remote URL → matched against the
#      manifest's .consumers[].repo field.
# Echoes the consumer name on success (sets RC=0), empty on failure
# (RC=1). The caller treats RC=1 as "skip templated verification" —
# canonical/kit verification still runs.
infer_consumer_from_pr_context() {
  if [ -n "${MERGEPATH_CONSUMER:-}" ]; then
    printf '%s' "$MERGEPATH_CONSUMER"
    return 0
  fi
  # Read origin URL. `git remote get-url origin` is the modern form;
  # older gits used `git config remote.origin.url` — both work here.
  local remote_url
  remote_url=$(git -C "$CONSUMER_DIR" remote get-url origin 2>/dev/null || \
               git -C "$CONSUMER_DIR" config remote.origin.url 2>/dev/null || \
               printf '')
  [ -z "$remote_url" ] && return 1
  # Normalize the URL to an "owner/repo" slug so we can string-match
  # against the manifest's .consumers[].repo field. Handles:
  #   https://github.com/owner/repo.git → owner/repo
  #   git@github.com:owner/repo.git     → owner/repo
  #   ssh://git@github.com/owner/repo   → owner/repo
  local slug
  # Strip scheme + host (https://, git@host:, ssh://git@host/).
  slug=$(printf '%s' "$remote_url" | sed -E '
    s|^https?://[^/]+/||
    s|^ssh://git@[^/]+/||
    s|^git@[^:]+:||
    s|\.git$||
  ')
  # Lookup in the manifest. We don't have yq guaranteed at this
  # surface (the canonical loop above uses an awk parser), so fall
  # back to a simple awk-based lookup over the consumers block.
  if command -v yq >/dev/null 2>&1; then
    local name
    name=$(yq -r ".consumers[] | select(.repo == \"$slug\") | .name" "$MANIFEST" 2>/dev/null | head -n1)
    if [ -n "$name" ]; then
      printf '%s' "$name"
      return 0
    fi
  fi
  # awk fallback — pairs `- name:` and `repo:` inside the
  # `consumers:` block, prints the name when repo matches.
  local name
  name=$(awk -v target="$slug" '
    /^consumers:/ { in_c = 1; next }
    in_c && /^[^[:space:]#]/ { in_c = 0 }
    !in_c { next }
    /^[[:space:]]*-[[:space:]]*name:/ {
      cur_name = $0
      sub(/^[[:space:]]*-[[:space:]]*name:[[:space:]]*/, "", cur_name)
      sub(/[[:space:]]*#.*$/, "", cur_name)
      gsub(/^[[:space:]]+|[[:space:]]+$|^"|"$/, "", cur_name)
    }
    /^[[:space:]]*repo:/ {
      cur_repo = $0
      sub(/^[[:space:]]*repo:[[:space:]]*/, "", cur_repo)
      sub(/[[:space:]]*#.*$/, "", cur_repo)
      gsub(/^[[:space:]]+|[[:space:]]+$|^"|"$/, "", cur_repo)
      if (cur_repo == target) { print cur_name; exit }
    }
  ' "$MANIFEST")
  if [ -n "$name" ]; then
    printf '%s' "$name"
    return 0
  fi
  return 1
}

# Source the template lib and facts helper from the TRUSTED mergepath
# checkout. Same provenance rule as the parser helpers above — never
# from the PR's working tree.
TEMPLATE_LIB="$MERGEPATH_DIR/scripts/lib/template-substitution.sh"
FACTS_HELPER="$MERGEPATH_DIR/scripts/lib/manifest-fact-helpers.sh"

# Only attempt the templated surface if both trusted helpers are
# present in mergepath@<sha>. Missing helpers → fall through to the
# canonical loop (which will fail-closed on the templated dest path).
TEMPLATED_SURFACE_ACTIVE=0
if [ -f "$TEMPLATE_LIB" ] && [ -f "$FACTS_HELPER" ] && command -v yq >/dev/null 2>&1; then
  TEMPLATED_SURFACE_ACTIVE=1
fi

if [ "$TEMPLATED_SURFACE_ACTIVE" = "1" ]; then
  # Resolve consumer. RC=1 → skip templated surface with a log line.
  CONSUMER_NAME=""
  if CONSUMER_NAME=$(infer_consumer_from_pr_context) && [ -n "$CONSUMER_NAME" ]; then
    :
  else
    echo "verify-propagation-pr.sh: cannot infer consumer from PR context (no MERGEPATH_CONSUMER env, no origin remote match in manifest) — skipping templated re-render surface" >&2
    CONSUMER_NAME=""
  fi
fi

if [ "$TEMPLATED_SURFACE_ACTIVE" = "1" ] && [ -n "$CONSUMER_NAME" ]; then
  # shellcheck disable=SC1090
  source "$FACTS_HELPER"
  # shellcheck disable=SC1090
  source "$TEMPLATE_LIB"

  # Pull templated entries (source, dest, consumers) as TSV.
  TEMPLATED_TSV=$(yq -r '
    .paths[]
    | select(.type == "templated")
    | [(.source // .path), (.dest // .path), ((.consumers // [] | type == "!!str") | tostring), (.consumers // [] | (select(type == "!!str") // (join(","))) | tostring)]
    | @tsv
  ' "$MANIFEST" 2>/dev/null || printf '')

  if [ -n "$TEMPLATED_TSV" ]; then
    while IFS=$'\t' read -r tpl_source tpl_dest is_str_consumers consumers_csv; do
      [ -z "$tpl_source" ] && continue
      [ -z "$tpl_dest" ] && continue
      # consumers field can be the literal "all" or a CSV of names.
      # is_str_consumers is "true" when the manifest used a scalar
      # `consumers: all`, else "false" (i.e. it was a sequence).
      consumer_matches=0
      if [ "$is_str_consumers" = "true" ] && [ "$consumers_csv" = "all" ]; then
        consumer_matches=1
      elif [ "$is_str_consumers" = "false" ]; then
        case ",$consumers_csv," in
          *",$CONSUMER_NAME,"*) consumer_matches=1 ;;
        esac
      fi
      [ "$consumer_matches" -eq 0 ] && continue

      # Templated dest must actually be in the PR's changed files —
      # otherwise there's nothing to verify for this entry.
      dest_in_diff=0
      while IFS= read -r cf; do
        [ -z "$cf" ] && continue
        if [ "$cf" = "$tpl_dest" ]; then dest_in_diff=1; break; fi
      done <<< "$CHANGED_FILES"
      [ "$dest_in_diff" -eq 0 ] && continue

      # Source must exist in the trusted mergepath checkout.
      mp_source_abs="$MERGEPATH_DIR/$tpl_source"
      if [ ! -f "$mp_source_abs" ]; then
        fail_templated_error "$tpl_dest — templated source '$tpl_source' missing from mergepath@<sha> (consumer=$CONSUMER_NAME)"
        continue
      fi

      # Render in a subshell so the facts export + lib sourcing don't
      # leak between iterations.
      rendered=$(mktemp "${TMPDIR:-/tmp}/verify-prop-rendered.XXXXXX")
      render_err=$(mktemp "${TMPDIR:-/tmp}/verify-prop-render-err.XXXXXX")
      render_rc=0
      (
        # `|| exit $?` explicitly propagates a fail-closed export rc as the
        # subshell's exit status. Relying on `set -e` alone is unsafe here:
        # the subshell is the left operand of `|| render_rc=$?`, a context
        # in which bash suppresses `set -e` for the commands inside it, so
        # export_consumer_facts returning 1 would otherwise be masked by
        # template_substitution::render's rc. See #457.
        export_consumer_facts "$CONSUMER_NAME" "$MANIFEST" || exit $?
        template_substitution::render "$mp_source_abs"
      ) > "$rendered" 2> "$render_err" || render_rc=$?

      if [ "$render_rc" != "0" ]; then
        # Surface the renderer's stderr for diagnostics, then fail.
        if [ -s "$render_err" ]; then
          {
            echo "verify-propagation-pr.sh: template render error for $tpl_source (consumer=$CONSUMER_NAME, rc=$render_rc):"
            sed 's/^/    /' "$render_err"
          } >&2
        fi
        fail_templated_error "$tpl_dest — templated render failed (source=$tpl_source, consumer=$CONSUMER_NAME, rc=$render_rc)"
        rm -f "$rendered" "$render_err"
        continue
      fi
      rm -f "$render_err"

      # Pull the PR's dest content at HEAD via `git show`.
      pr_content=$(mktemp "${TMPDIR:-/tmp}/verify-prop-pr.XXXXXX")
      if ! git -C "$CONSUMER_DIR" show "${HEAD_SHA}:${tpl_dest}" > "$pr_content" 2>/dev/null; then
        fail_templated_error "$tpl_dest — templated dest not present at PR HEAD (consumer=$CONSUMER_NAME)"
        rm -f "$rendered" "$pr_content"
        continue
      fi

      if diff -q "$rendered" "$pr_content" >/dev/null 2>&1; then
        # Byte-compare cleared. Now check the tree entry's mode + type
        # match the expected `100644 blob` shape — otherwise metadata-
        # only tampering (chmod +x flip, regular-file ↔ symlink swap)
        # passes lane verification while changing the consumer's
        # on-disk file behavior. Codex P1 #329 round 2 caught this:
        # the templated arm was byte-only while the canonical loop's
        # tree-entry compare (mode + type + oid via `git ls-tree`)
        # was being skipped via the VERIFIED_TEMPLATED_DESTS exempt.
        # Derive the SOURCE template's expected mode+type from the trusted
        # mergepath checkout (#471): a templated source can be executable
        # (e.g. a templated shell script), so the rendered dest must inherit
        # the SOURCE mode rather than a hardcoded 100644. Compare mode+type
        # only — the render changes content by design, so the oid
        # legitimately differs.
        #
        # Prefer the COMMITTED git mode (CodeRabbit on PR #475): the on-disk
        # exec bit can drift from the recorded git mode, and the consumer
        # side below — plus the canonical loop's mergepath-side read — both
        # read git modes, so reading the source on-disk broke parity. Use
        # `git ls-tree HEAD` when MERGEPATH_DIR is a git checkout (always so
        # in production); fall back to an on-disk stat only when it is not
        # (test fixtures that stage files without a repo), mirroring the
        # canonical loop's git-or-disk handling below.
        if [ -d "$MERGEPATH_DIR/.git" ] || [ -f "$MERGEPATH_DIR/.git" ]; then
          # Git checkout (always so in production): the committed mode is
          # authoritative.
          tpl_source_entry=$(git -C "$MERGEPATH_DIR" ls-tree HEAD -- "$tpl_source" 2>/dev/null | awk '{print $1, $2}')
        else
          # Non-git fixture dir (tests stage files without a repo): the
          # filesystem exec bit is the only signal available.
          if [ -x "$mp_source_abs" ]; then
            tpl_source_entry="100755 blob"
          else
            tpl_source_entry="100644 blob"
          fi
        fi
        # Fail closed unless the source resolves to a regular-file blob.
        # check_sync_manifest already requires templated sources to be
        # regular files; an empty read (source not tracked at HEAD in the
        # trusted checkout) or a symlink/submodule entry here is a
        # misconfiguration, not a faithful render — reject rather than
        # produce a confusing tree-entry diff. Both review bots on PR #475
        # asked for this explicit guard.
        case "$tpl_source_entry" in
          "100644 blob"|"100755 blob") ;;
          *)
            fail_templated_error "$tpl_dest — unsupported/absent templated source tree entry [$tpl_source_entry] (source=$tpl_source, consumer=$CONSUMER_NAME)"
            rm -f "$rendered" "$pr_content"
            continue
            ;;
        esac
        tpl_consumer_entry=$(git -C "$CONSUMER_DIR" ls-tree "$HEAD_SHA" -- "$tpl_dest" 2>/dev/null | awk '{print $1, $2}')
        if [ "$tpl_consumer_entry" != "$tpl_source_entry" ]; then
          {
            echo "verify-propagation-pr.sh: templated dest $tpl_dest has unexpected tree entry [$tpl_consumer_entry], expected [$tpl_source_entry] from source $tpl_source (mode/type tampering — chmod +x flip or symlink swap, not a faithful render)"
          } >&2
          fail_templated_drift "$tpl_dest — templated dest tree entry [$tpl_consumer_entry] differs from source [$tpl_source_entry] (source=$tpl_source, consumer=$CONSUMER_NAME)"
          rm -f "$rendered" "$pr_content"
          continue
        fi
        echo "verify-propagation-pr.sh: templated re-render matches PR content for $tpl_dest (consumer=$CONSUMER_NAME, source=$tpl_source)"
        # Emit structured tag-reply line for the calling workflow.
        # Format MUST stay parseable; see CLAUDE.md § resolve-pr-threads
        # tag class and #323 for the consumer of these lines.
        printf '[mergepath-verify: templated-render] %s %s %s\n' "$tpl_dest" "$CONSUMER_NAME" "$tpl_source"
        VERIFIED_TEMPLATED_DESTS="${VERIFIED_TEMPLATED_DESTS}${tpl_dest}"$'\n'
      else
        {
          echo "verify-propagation-pr.sh: templated re-render diverges from PR content for $tpl_dest (consumer=$CONSUMER_NAME, source=$tpl_source). Diff (expected → PR):"
          diff "$rendered" "$pr_content" | sed 's/^/    /' || true
        } >&2
        fail_templated_drift "$tpl_dest — templated re-render diverges from PR content (source=$tpl_source, consumer=$CONSUMER_NAME)"
      fi
      rm -f "$rendered" "$pr_content"
    done <<< "$TEMPLATED_TSV"
  fi
fi

while IFS= read -r f; do
  [ -z "$f" ] && continue

  # #323: skip files already verified by the templated re-render
  # surface above. Their dest path doesn't match any .path glob
  # (which is the whole point of source ≠ dest), so the canonical
  # path-confinement check below would false-fail them.
  if [ -n "$VERIFIED_TEMPLATED_DESTS" ]; then
    case $'\n'"$VERIFIED_TEMPLATED_DESTS" in
      *$'\n'"$f"$'\n'*) continue ;;
    esac
  fi

  # 1. Path confinement: f must be under a manifest-declared path.
  if ! printf '%s\n' "$f" | bash "$MATCH_PATHS" "${MAN_PATTERNS[@]}" | grep -qxF "$f"; then
    fail "$f — not under any .mergepath-sync.yml path (off propagation surface)"
    continue
  fi

  # 2. Tree-entry equality of the END STATE against mergepath@<sha>.
  #    Compare the full git TREE ENTRY (mode + type + oid) rather
  #    than just the blob hash, so a file-mode change (exec-bit
  #    flip, regular file ↔ symlink) is caught too — a hand-edited
  #    `chmod +x` on a canonical script would otherwise pass the
  #    blob-only check while leaving the consumer's on-disk mode
  #    different from mergepath. `git ls-tree` returns
  #    `<mode> <type> <oid>\t<path>`; we drop the path field (always
  #    $f) and compare the mode+type+oid tuple. Empty output ⇒ path
  #    not present at that ref. (CodeRabbit Major, #272/#274.)
  consumer_present=1
  consumer_entry=$(git -C "$CONSUMER_DIR" ls-tree "$HEAD_SHA" -- "$f" 2>/dev/null | awk '{print $1, $2, $3}')
  [ -z "$consumer_entry" ] && consumer_present=0
  mergepath_present=1
  if [ -d "$MERGEPATH_DIR/.git" ] || [ -f "$MERGEPATH_DIR/.git" ]; then
    # mergepath_dir is a git checkout — `ls-tree HEAD` gives the
    # authoritative tree entry (mode/type from git's index, not a
    # filesystem mode that could vary by clone permissions).
    mergepath_entry=$(git -C "$MERGEPATH_DIR" ls-tree HEAD -- "$f" 2>/dev/null | awk '{print $1, $2, $3}')
    [ -z "$mergepath_entry" ] && mergepath_present=0
  else
    # Test harness fallback: mergepath_dir is a plain directory.
    # Synthesize a tree entry from the on-disk file: mode 100755 if
    # executable else 100644, type blob, oid via hash-object.
    if [ -f "$MERGEPATH_DIR/$f" ]; then
      if [ -x "$MERGEPATH_DIR/$f" ]; then mode="100755"; else mode="100644"; fi
      mp_oid=$(git hash-object "$MERGEPATH_DIR/$f")
      mergepath_entry="$mode blob $mp_oid"
    else
      mergepath_entry=""; mergepath_present=0
    fi
  fi

  if [ "$consumer_present" -eq 0 ] && [ "$mergepath_present" -eq 0 ]; then
    # Faithful delete: f removed in the PR, and absent at mergepath@<sha>.
    continue
  fi
  if [ "$consumer_present" -eq 1 ] && [ "$mergepath_present" -eq 0 ]; then
    fail "$f — present in the PR but absent at mergepath@<sha> (a faithful sync never adds/keeps a file mergepath does not have under a manifest path)"
    continue
  fi
  if [ "$consumer_present" -eq 0 ] && [ "$mergepath_present" -eq 1 ]; then
    fail "$f — deleted in the PR but still present at mergepath@<sha> (not a faithful delete-propagation)"
    continue
  fi
  # Both present — tree entries (mode + type + oid) must match.
  if [ "$consumer_entry" != "$mergepath_entry" ]; then
    fail "$f — tree entry differs from mergepath@<sha> (mode/type/oid mismatch; hand-edited or mode-flipped, not a verbatim mirror). consumer=[$consumer_entry] mergepath=[$mergepath_entry]"
    continue
  fi
done <<< "$CHANGED_FILES"

if [ -n "$FAILURES" ]; then
  echo "verify-propagation-pr.sh: NOT a faithful mirror — the PR is not lane-eligible:" >&2
  # Typed sub-summaries so the reader can tell at a glance whether a
  # failure is canonical-mismatch, templated-drift, or templated-error
  # (#323). Categories are mutually exclusive — a given failure lands
  # in exactly one bucket.
  if [ -n "$CANONICAL_FAILURES" ]; then
    echo "  Canonical / kit drift (path confinement + tree-entry compare):" >&2
    printf '%s' "$CANONICAL_FAILURES" >&2
  fi
  if [ -n "$TEMPLATED_FAILURES" ]; then
    echo "  Templated re-render mismatch (rendered output differs from PR dest):" >&2
    printf '%s' "$TEMPLATED_FAILURES" >&2
  fi
  if [ -n "$TEMPLATED_ERRORS" ]; then
    echo "  Templated re-render error (malformed template / missing source / strict-mode unset fact):" >&2
    printf '%s' "$TEMPLATED_ERRORS" >&2
  fi
  echo "  → this PR must go through normal Phase 3/4 review." >&2
  exit 1
fi

echo "verify-propagation-pr.sh: faithful mirror confirmed — every changed file byte-matches mergepath@<sha> under a manifest path."
exit 0
