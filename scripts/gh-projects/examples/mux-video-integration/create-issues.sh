#!/usr/bin/env bash
# Rerunnable driver that creates every parent + child issue for the MUX Video
# Integration initiative (GitHub Project #5), links them as native sub-issues,
# and adds each to the project board.
#
# This is the canonical worked example for scripts/gh-projects/ — see the
# README one level up for the pattern.
#
# Preconditions:
#   eval "$(scripts/op-preflight.sh --agent claude --mode all)"
#   export GH_TOKEN="$OP_PREFLIGHT_AUTHOR_PAT"
#
# Already-executed on 2026-04-18: produced parent issues #210, #215, #220, #225.
# Re-running will create a duplicate set — the script is not idempotent. Use
# only against a fresh project or after wiping the existing issues.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

export REPO="nathanjohnpayne/nathanpaynedotcom"
export OWNER="nathanjohnpayne"
export PROJECT=5

# Safety gate (CodeRabbit on PR #180): this script writes to LIVE
# project coordinates. Re-running creates duplicate issues #210+ and
# spams the project board. Require explicit confirmation that the
# operator knows they're hitting prod.
#
# Override:
#   GHP_CONFIRM_LIVE=I_AM_REPOPULATING_PROJECT_5 ./create-issues.sh
#
# To repurpose this driver against a different project, change REPO/OWNER/
# PROJECT above (and the override token) before running. This file is
# the canonical worked example — copy it to your own examples/<initiative>/
# directory before adapting, don't edit in place.
if [[ "${GHP_CONFIRM_LIVE:-}" != "I_AM_REPOPULATING_PROJECT_5" ]]; then
  echo "Refusing to run: this driver writes to live project coordinates"
  echo "($REPO project #$PROJECT). Re-running creates duplicate issues."
  echo ""
  echo "If you're adapting this as a template for a different initiative,"
  echo "COPY THE FILE to scripts/gh-projects/examples/<your-initiative>/"
  echo "and edit REPO/OWNER/PROJECT plus this safety gate's override token"
  echo "before running."
  echo ""
  echo "If you genuinely intend to repopulate $REPO project #$PROJECT,"
  echo "set GHP_CONFIRM_LIVE=I_AM_REPOPULATING_PROJECT_5 and re-run."
  exit 1
fi

# shellcheck source=../../lib.sh
source "$SCRIPT_DIR/../../lib.sh"

# -----------------------------------------------------------------------------
# Labels (idempotent)
# -----------------------------------------------------------------------------
ensure_label "mux" "FF3366" "MUX video integration"
ensure_label "phase-1" "0E8A16" "Phase 1 of a multi-phase project"
ensure_label "phase-2" "1D76DB" "Phase 2 of a multi-phase project"
ensure_label "phase-3" "5319E7" "Phase 3 of a multi-phase project"
ensure_label "phase-4" "B60205" "Phase 4 of a multi-phase project"

# -----------------------------------------------------------------------------
# Phase 1 — Component + Swipe Watch integration
# -----------------------------------------------------------------------------
P1_URL=$(create_parent "Phase 1: Add MuxPlayer to Swipe Watch hero" \
  "$SCRIPT_DIR/phase-1/parent.md" "mux,phase-1")
P1_NUM="${P1_URL##*/}"
echo "P1 PARENT: $P1_URL"

F=$(prep_body "$SCRIPT_DIR/phase-1/c1.md" "$P1_NUM")
read P1_C1_URL P1_C1_NUM _ <<<"$(create_child "Install @mux/mux-player-astro dependency" \
  "$F" "mux,phase-1" "$P1_NUM")"
echo "  C1: $P1_C1_URL"

F=$(prep_body "$SCRIPT_DIR/phase-1/c2.md" "$P1_NUM")
read P1_C2_URL P1_C2_NUM _ <<<"$(create_child "Extend projects schema with optional muxPlaybackId" \
  "$F" "mux,phase-1" "$P1_NUM")"
echo "  C2: $P1_C2_URL"

F=$(prep_body "$SCRIPT_DIR/phase-1/c3.md" "$P1_NUM")
read P1_C3_URL P1_C3_NUM _ <<<"$(create_child "Wire MuxPlayer into ProjectLayout + CSS + swipe-watch frontmatter" \
  "$F" "mux,phase-1" "$P1_NUM")"
echo "  C3: $P1_C3_URL"

# C4 references C3 via __C3_NUM__
F=$(prep_body "$SCRIPT_DIR/phase-1/c4.md" "$P1_NUM" "" "" "$P1_C3_NUM")
read P1_C4_URL P1_C4_NUM _ <<<"$(create_child "Phase 1 manual QA: player, fallback, OG, screenshot" \
  "$F" "mux,phase-1" "$P1_NUM")"
echo "  C4: $P1_C4_URL"

# -----------------------------------------------------------------------------
# Phase 2 — Mux Data (analytics)
# -----------------------------------------------------------------------------
P2_URL=$(create_parent "Phase 2: Wire Mux Data via PUBLIC_MUX_ENV_KEY" \
  "$SCRIPT_DIR/phase-2/parent.md" "mux,phase-2")
P2_NUM="${P2_URL##*/}"
echo "P2 PARENT: $P2_URL"

F=$(prep_body "$SCRIPT_DIR/phase-2/c1.md" "$P2_NUM")
read P2_C1_URL P2_C1_NUM _ <<<"$(create_child "Add .env.example for PUBLIC_MUX_ENV_KEY" \
  "$F" "mux,phase-2" "$P2_NUM")"
echo "  C1: $P2_C1_URL"

# Create C3 before C2 because C2 references C3 via __C3_NUM__
F=$(prep_body "$SCRIPT_DIR/phase-2/c3.md" "$P2_NUM")
read P2_C3_URL P2_C3_NUM _ <<<"$(create_child "Pass env-key and metadata to MuxPlayer" \
  "$F" "mux,phase-2" "$P2_NUM")"
echo "  C3: $P2_C3_URL"

F=$(prep_body "$SCRIPT_DIR/phase-2/c2.md" "$P2_NUM" "" "" "$P2_C3_NUM")
read P2_C2_URL P2_C2_NUM _ <<<"$(create_child "Provision PUBLIC_MUX_ENV_KEY in 1Password + Firebase" \
  "$F" "mux,phase-2" "$P2_NUM")"
echo "  C2: $P2_C2_URL"

F=$(prep_body "$SCRIPT_DIR/phase-2/c4.md" "$P2_NUM")
read P2_C4_URL P2_C4_NUM _ <<<"$(create_child "Phase 2 manual QA: confirm Mux Data views" \
  "$F" "mux,phase-2" "$P2_NUM")"
echo "  C4: $P2_C4_URL"

# -----------------------------------------------------------------------------
# Phase 3 — Extract reusable ProjectMuxPlayer component
# -----------------------------------------------------------------------------
P3_URL=$(create_parent "Phase 3: Extract reusable ProjectMuxPlayer component" \
  "$SCRIPT_DIR/phase-3/parent.md" "mux,phase-3")
P3_NUM="${P3_URL##*/}"
echo "P3 PARENT: $P3_URL"

F=$(prep_body "$SCRIPT_DIR/phase-3/c1.md" "$P3_NUM")
read P3_C1_URL P3_C1_NUM _ <<<"$(create_child "Extract ProjectMuxPlayer.astro component" \
  "$F" "mux,phase-3" "$P3_NUM")"
echo "  C1: $P3_C1_URL"

# C2 references C1
F=$(prep_body "$SCRIPT_DIR/phase-3/c2.md" "$P3_NUM" "$P3_C1_NUM")
read P3_C2_URL P3_C2_NUM _ <<<"$(create_child "Swap ProjectLayout to call ProjectMuxPlayer" \
  "$F" "mux,phase-3" "$P3_NUM")"
echo "  C2: $P3_C2_URL"

F=$(prep_body "$SCRIPT_DIR/phase-3/c3.md" "$P3_NUM")
read P3_C3_URL P3_C3_NUM _ <<<"$(create_child "Document MUX video extension path in AGENTS.md" \
  "$F" "mux,phase-3" "$P3_NUM")"
echo "  C3: $P3_C3_URL"

F=$(prep_body "$SCRIPT_DIR/phase-3/c4.md" "$P3_NUM")
read P3_C4_URL P3_C4_NUM _ <<<"$(create_child "Phase 3 theming QA: verify all accent classes" \
  "$F" "mux,phase-3" "$P3_NUM")"
echo "  C4: $P3_C4_URL"

# -----------------------------------------------------------------------------
# Phase 4 — Replace static GIF with Mux-generated GIF
# -----------------------------------------------------------------------------
P4_URL=$(create_parent "Phase 4: Replace static GIF with Mux-generated GIF" \
  "$SCRIPT_DIR/phase-4/parent.md" "mux,phase-4")
P4_NUM="${P4_URL##*/}"
echo "P4 PARENT: $P4_URL"

F=$(prep_body "$SCRIPT_DIR/phase-4/c1.md" "$P4_NUM")
read P4_C1_URL P4_C1_NUM _ <<<"$(create_child "Add scripts/refresh-mux-gifs.mjs" \
  "$F" "mux,phase-4" "$P4_NUM")"
echo "  C1: $P4_C1_URL"

F=$(prep_body "$SCRIPT_DIR/phase-4/c2.md" "$P4_NUM")
read P4_C2_URL P4_C2_NUM _ <<<"$(create_child "Skip Mux-backed projects in refresh-hero-images.mjs" \
  "$F" "mux,phase-4" "$P4_NUM")"
echo "  C2: $P4_C2_URL"

# C3 references C1 and C2
F=$(prep_body "$SCRIPT_DIR/phase-4/c3.md" "$P4_NUM" "$P4_C1_NUM" "$P4_C2_NUM")
read P4_C3_URL P4_C3_NUM _ <<<"$(create_child "Wire refresh-mux-gifs.mjs into build" \
  "$F" "mux,phase-4" "$P4_NUM")"
echo "  C3: $P4_C3_URL"

# C4 references C3
F=$(prep_body "$SCRIPT_DIR/phase-4/c4.md" "$P4_NUM" "" "" "$P4_C3_NUM")
read P4_C4_URL P4_C4_NUM _ <<<"$(create_child "Document Mux GIF refresher in AGENTS.md" \
  "$F" "mux,phase-4" "$P4_NUM")"
echo "  C4: $P4_C4_URL"

F=$(prep_body "$SCRIPT_DIR/phase-4/c5.md" "$P4_NUM")
read P4_C5_URL P4_C5_NUM _ <<<"$(create_child "Phase 4 manual QA: GIF regeneration + hero refresher skip" \
  "$F" "mux,phase-4" "$P4_NUM")"
echo "  C5: $P4_C5_URL"

echo ""
echo "=== DONE ==="
echo "Phase 1: $P1_URL"
echo "Phase 2: $P2_URL"
echo "Phase 3: $P3_URL"
echo "Phase 4: $P4_URL"
