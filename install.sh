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
cp "$SRC/AGENTS.md" "$ROOT_DIR/AGENTS.md"

echo ""
echo "Stride Ideation for OpenCode installed."
echo ""
echo "Installed into $OC_DIR:"
echo "  Skills:   $(ls -d "$OC_DIR/skills/"*/ 2>/dev/null | wc -l | tr -d ' ')"
echo "  Commands: $(ls "$OC_DIR/commands/"*.md 2>/dev/null | wc -l | tr -d ' ') (/ideate, /stridify)"
echo "  Agents:   $(ls "$OC_DIR/agents/"*.md 2>/dev/null | wc -l | tr -d ' ')"
echo "  Helpers:  $(ls "$OC_DIR/lib/" 2>/dev/null | wc -l | tr -d ' ') files in lib/"
echo "  Fixtures: $(ls "$OC_DIR/fixtures/" 2>/dev/null | wc -l | tr -d ' ') files in fixtures/"
echo "  AGENTS.md -> $ROOT_DIR/AGENTS.md"
echo ""
echo "There is NO plugin to register in opencode.json — ideation has no hooks."
echo ""
echo "Next steps:"
echo "  1. Restart OpenCode so it discovers the new commands (/ideate, /stridify)."
echo "  2. For /stridify: create .stride_auth.md in your project root with your"
echo "     Stride API credentials (see the README) and add it to .gitignore."
