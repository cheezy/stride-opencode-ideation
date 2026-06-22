#!/usr/bin/env bash
# install.sh — Install the Stride ideation bundle for OpenCode
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/cheezy/stride-opencode-ideation/main/install.sh | bash
#
# Or clone and run locally:
#   ./install.sh           # project-local: .opencode/ in the current directory
#   ./install.sh --global  # global:        ~/.config/opencode/
#
# There is NO plugin to install — ideation has no lifecycle hooks. This copies
# the skills, commands, agents, lib/ helpers, and fixtures into the OpenCode
# discovery paths, and AGENTS.md to the project root.

set -euo pipefail

REPO="https://github.com/cheezy/stride-opencode-ideation.git"
MODE="project"

for arg in "$@"; do
  case "$arg" in
    --global) MODE="global" ;;
    --help|-h)
      echo "Usage: install.sh [--global]"
      echo ""
      echo "  (default)   Install project-local to .opencode/ in the current directory"
      echo "  --global    Install to ~/.config/opencode/ (available in all projects)"
      exit 0
      ;;
  esac
done

if [ "$MODE" = "global" ]; then
  OC_DIR="$HOME/.config/opencode"
  ROOT_DIR="$HOME/.config/opencode"
  echo "Installing Stride Ideation for OpenCode into ~/.config/opencode/ (global)..."
else
  OC_DIR=".opencode"
  ROOT_DIR="."
  echo "Installing Stride Ideation for OpenCode into .opencode/ (project-local)..."
fi

# Source: this script's directory if it already contains the bundle, else clone.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$SCRIPT_DIR/AGENTS.md" ] && [ -d "$SCRIPT_DIR/skills" ]; then
  SRC="$SCRIPT_DIR"
  CLEANUP=""
else
  TMPDIR="$(mktemp -d)"
  CLEANUP="$TMPDIR"
  echo "Downloading from $REPO..."
  git clone --quiet --depth 1 "$REPO" "$TMPDIR/stride-opencode-ideation"
  SRC="$TMPDIR/stride-opencode-ideation"
fi
trap '[ -n "${CLEANUP:-}" ] && rm -rf "$CLEANUP"' EXIT

# OpenCode discovers skills/, commands/, agents/ (plural) from the config dir.
# Use cp -a to preserve the executable bit on the lib/*.sh helpers.
mkdir -p "$OC_DIR/skills" "$OC_DIR/commands" "$OC_DIR/agents"
cp -a "$SRC/skills/."   "$OC_DIR/skills/"
cp -a "$SRC/commands/." "$OC_DIR/commands/"
cp    "$SRC/agents/"*.md "$OC_DIR/agents/"

# /stridify helpers + smoke-test fixtures live alongside under the config dir.
mkdir -p "$OC_DIR/lib" "$OC_DIR/fixtures"
cp -a "$SRC/lib/."      "$OC_DIR/lib/"
cp -a "$SRC/fixtures/." "$OC_DIR/fixtures/"

# AGENTS.md orients the main agent; it belongs at the project (or config) root.
# Preserve any existing user-authored AGENTS.md by confining our content to an
# idempotent, clearly delimited managed block. A fresh file is created with the
# block; an existing file keeps ALL of its content and only the block is
# inserted or refreshed in place -- so re-running the installer never clobbers
# the user's own notes and never duplicates the guidance.
DEST_AGENTS="$ROOT_DIR/AGENTS.md"
BEGIN_MARKER="<!-- BEGIN stride-ideation -->"
END_MARKER="<!-- END stride-ideation -->"
NOTE_MARKER="<!-- Managed by the stride-opencode-ideation installer; content between these markers is regenerated on each install. Add your own notes outside this block. -->"

# Build the managed block (markers fence the bundle content). Use a temp file so
# the destination is never read as a script -- we only ever pattern-match it.
MANAGED_BLOCK="$(mktemp)"
{
  printf '%s\n' "$BEGIN_MARKER"
  printf '%s\n' "$NOTE_MARKER"
  cat "$SRC/AGENTS.md"
  printf '%s\n' "$END_MARKER"
} > "$MANAGED_BLOCK"

# Locate a WELL-FORMED managed block: the first BEGIN marker line and the first
# END marker line, where END follows BEGIN. Only a well-formed pair triggers an
# in-place refresh -- an orphaned or malformed marker (e.g. BEGIN with no END)
# must NEVER truncate user content, so it falls through to the append path.
# This mirrors the install.ps1 first-BEGIN / first-END / END-after-BEGIN logic
# exactly so both installers behave identically.
BEGIN_LINE=""
END_LINE=""
if [ -f "$DEST_AGENTS" ]; then
  # `|| true` keeps a no-match grep (exit 1) from tripping `set -euo pipefail`.
  BEGIN_LINE="$(grep -nxF "$BEGIN_MARKER" "$DEST_AGENTS" | head -1 | cut -d: -f1 || true)"
  END_LINE="$(grep -nxF "$END_MARKER" "$DEST_AGENTS" | head -1 | cut -d: -f1 || true)"
fi

if [ ! -f "$DEST_AGENTS" ]; then
  cp "$MANAGED_BLOCK" "$DEST_AGENTS"
  AGENTS_STATUS="created"
elif [ -n "$BEGIN_LINE" ] && [ -n "$END_LINE" ] && [ "$END_LINE" -gt "$BEGIN_LINE" ]; then
  # Refresh the well-formed block in place: keep everything before BEGIN and
  # everything after END, swapping the block between them.
  UPDATED="$(mktemp)"
  {
    head -n "$((BEGIN_LINE - 1))" "$DEST_AGENTS"
    cat "$MANAGED_BLOCK"
    tail -n "+$((END_LINE + 1))" "$DEST_AGENTS"
  } > "$UPDATED"
  mv "$UPDATED" "$DEST_AGENTS"
  AGENTS_STATUS="managed block updated; your content preserved"
else
  # No managed block, or an orphaned/malformed marker: append, never truncate.
  [ -s "$DEST_AGENTS" ] && [ -n "$(tail -c1 "$DEST_AGENTS")" ] && printf '\n' >> "$DEST_AGENTS"
  printf '\n' >> "$DEST_AGENTS"
  cat "$MANAGED_BLOCK" >> "$DEST_AGENTS"
  AGENTS_STATUS="managed block appended; your content preserved"
fi
rm -f "$MANAGED_BLOCK"

echo ""
echo "Stride Ideation for OpenCode installed."
echo ""
echo "Installed into $OC_DIR:"
echo "  Skills:   $(ls -d "$OC_DIR/skills/"*/ 2>/dev/null | wc -l | tr -d ' ')"
echo "  Commands: $(ls "$OC_DIR/commands/"*.md 2>/dev/null | wc -l | tr -d ' ') (/ideate, /stridify)"
echo "  Agents:   $(ls "$OC_DIR/agents/"*.md 2>/dev/null | wc -l | tr -d ' ')"
echo "  Helpers:  $(ls "$OC_DIR/lib/" 2>/dev/null | wc -l | tr -d ' ') files in lib/"
echo "  Fixtures: $(ls "$OC_DIR/fixtures/" 2>/dev/null | wc -l | tr -d ' ') files in fixtures/"
echo "  AGENTS.md -> $ROOT_DIR/AGENTS.md ($AGENTS_STATUS)"
echo ""
echo "There is NO plugin to register in opencode.json — ideation has no hooks."
echo ""
echo "Next steps:"
echo "  1. Restart OpenCode so it discovers the new commands (/ideate, /stridify)."
echo "  2. For /stridify: create .stride_auth.md in your project root with your"
echo "     Stride API credentials (see the README) and add it to .gitignore."
