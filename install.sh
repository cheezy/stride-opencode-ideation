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
# the skills, commands and agents into the OpenCode discovery paths, the lib/
# helpers and fixtures into a bundle-owned stride-ideation/ directory beside
# them, and AGENTS.md to the project root.

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

# Source: this script's directory if it IS this bundle, else clone.
#
# Under `curl ... | bash` (or `bash < install.sh`) the script comes from stdin,
# BASH_SOURCE is unset, and there is no script directory at all. The `:-`
# default keeps that from aborting under `set -u`; an empty SCRIPT_DIR then
# falls through to the clone. The current directory is never a candidate: a
# directory only counts as the bundle when it carries this bundle's own files,
# so a user's project with its own AGENTS.md and skills/ is never copied.
SCRIPT_DIR=""
if [ -n "${BASH_SOURCE[0]:-}" ] && [ -f "${BASH_SOURCE[0]}" ]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi
is_bundle() {
  [ -n "$1" ] &&
    [ -f "$1/commands/stridify.md" ] && [ -f "$1/commands/ideate.md" ] &&
    [ -f "$1/lib/filename.sh" ] && [ -f "$1/AGENTS.md" ] && [ -d "$1/skills" ]
}
CLEANUP=""
trap '[ -n "${CLEANUP:-}" ] && rm -rf "$CLEANUP"' EXIT
if is_bundle "$SCRIPT_DIR"; then
  SRC="$SCRIPT_DIR"
else
  CLONE_DIR="$(mktemp -d)"
  CLEANUP="$CLONE_DIR"
  echo "Downloading from $REPO..."
  git clone --quiet --depth 1 "$REPO" "$CLONE_DIR/stride-opencode-ideation"
  SRC="$CLONE_DIR/stride-opencode-ideation"
  if ! is_bundle "$SRC"; then
    echo "install.sh: the download from $REPO is not a stride-opencode-ideation bundle; nothing was installed." >&2
    exit 1
  fi
fi

# OpenCode discovers skills/, commands/, agents/ (plural) from the config dir.
# Use cp -a to preserve the executable bit on the lib/*.sh helpers.
mkdir -p "$OC_DIR/skills" "$OC_DIR/commands" "$OC_DIR/agents"
cp -a "$SRC/skills/."   "$OC_DIR/skills/"
cp -a "$SRC/commands/." "$OC_DIR/commands/"
cp    "$SRC/agents/"*.md "$OC_DIR/agents/"

# /stridify helpers + smoke-test fixtures live in a bundle-owned directory, so
# the commands have one stable path to call them by and the sibling Stride
# OpenCode bundles, which share $OC_DIR/lib and $OC_DIR/fixtures, are never
# touched. lib/ and fixtures/ stay siblings: lib/run_smoke_test.sh finds its
# fixture through ../fixtures.
PKG_DIR="$OC_DIR/stride-ideation"
mkdir -p "$PKG_DIR/lib" "$PKG_DIR/fixtures"
cp -a "$SRC/lib/."      "$PKG_DIR/lib/"
cp -a "$SRC/fixtures/." "$PKG_DIR/fixtures/"

# Older installs copied the helpers flat into $OC_DIR/lib and $OC_DIR/fixtures.
# Those files are left exactly where they are (a sibling bundle may own a file
# of the same name); name them once so the user can remove them by hand.
LEGACY=""
for f in "$SRC/lib/"* "$SRC/fixtures/"*; do
  rel="$(basename "$(dirname "$f")")/$(basename "$f")"
  if [ -e "$OC_DIR/$rel" ]; then LEGACY="${LEGACY:+$LEGACY, }$OC_DIR/$rel"; fi
done

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
# Matching is WHOLE-LINE exact (`grep -nxF`): marker text embedded mid-line in
# user prose is not a block boundary. install.ps1 uses the same whole-line
# first-BEGIN / first-END / END-after-BEGIN semantics. (One known edge: a
# CRLF-ended marker line refreshes on install.ps1 but appends here — both
# outcomes still preserve user content.)
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
    # Guard the head call: `head -n 0` is illegal on BSD/macOS head, and
    # BEGIN_LINE is 1 whenever the block sits at the top of the file — the
    # exact state a fresh install produces, so re-installs hit this path.
    if [ "$BEGIN_LINE" -gt 1 ]; then
      head -n "$((BEGIN_LINE - 1))" "$DEST_AGENTS"
    fi
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
echo "  Helpers:  $(ls "$PKG_DIR/lib/" 2>/dev/null | wc -l | tr -d ' ') files in $PKG_DIR/lib/"
echo "  Fixtures: $(ls "$PKG_DIR/fixtures/" 2>/dev/null | wc -l | tr -d ' ') files in $PKG_DIR/fixtures/"
echo "  AGENTS.md -> $ROOT_DIR/AGENTS.md ($AGENTS_STATUS)"
echo ""
echo "There is NO plugin to register in opencode.json — ideation has no hooks."
if [ -n "$LEGACY" ]; then
  echo "Note: an older install left these stride-ideation files in the shared lib/ and fixtures/ (no longer used, left in place; remove them if no other bundle needs them): $LEGACY"
fi
echo ""
echo "Next steps:"
echo "  1. Restart OpenCode so it discovers the new commands (/ideate, /stridify)."
echo "  2. For /stridify: create .stride_auth.md in your project root with your"
echo "     Stride API credentials (see the README) and add it to .gitignore."
