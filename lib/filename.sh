#!/usr/bin/env bash
# stride-ideation filename helpers.
#
# Two pure functions used by /stride-ideation:ideate and
# /stride-ideation:decompose to compute unique artifact paths:
#
#   sti_slugify "Add Notifications!"            -> "add-notifications"
#   sti_unique_path <dir> <ts> <slug> <artifact> <ext>
#       -> <dir>/<ts>-<slug>-<artifact>.<ext> if it does not exist,
#          else appends -2, -3, ... until it does not.
#
# Slug rules: lowercase, dash-separated. Any character outside [a-z0-9-]
# is REPLACED with a dash (never deleted — preserves word boundaries).
# Leading/trailing dashes are trimmed; runs of dashes are collapsed.
#
# Filename rule: the HARD INVARIANT is "never overwrite an existing file."
# When a collision occurs the helper iterates the suffix counter starting
# at 2; a single file at `<base>.<ext>` and another at `<base>-2.<ext>`
# means the next attempt yields `<base>-3.<ext>`.
#
# All output is written to stdout. Errors go to stderr with a non-zero
# exit code. Source this file, or call functions directly via:
#   bash -c '. lib/filename.sh; sti_unique_path docs/spec 2026-05-12T103000 foo requirements md'

set -u

sti_slugify() {
  local input="${1:-}"
  if [ -z "$input" ]; then
    echo "sti_slugify: empty input" >&2
    return 1
  fi
  local lowered
  lowered="$(printf '%s' "$input" | tr '[:upper:]' '[:lower:]')"
  # Replace anything outside [a-z0-9-] with a dash, collapse runs,
  # trim leading/trailing dashes.
  local replaced
  replaced="$(printf '%s' "$lowered" | sed -E 's/[^a-z0-9-]+/-/g; s/-+/-/g; s/^-//; s/-$//')"
  if [ -z "$replaced" ]; then
    echo "sti_slugify: slug normalized to empty string" >&2
    return 1
  fi
  printf '%s' "$replaced"
}

sti_slug_from_path() {
  # Extract the topic slug from a previously generated artifact path:
  #   <dir>/YYYY-MM-DDTHHMMSS-<slug>-<artifact>(-<N>)?.<ext>
  #
  # Usage: sti_slug_from_path <path> <artifact>
  #
  # <artifact> is the literal artifact token used when the path was generated
  # (e.g. `requirements`, `stride-batch`). Required because some artifact
  # tokens contain dashes (e.g. `stride-batch`) and the parse would otherwise
  # be ambiguous.
  #
  # Strips an optional `-N` collision discriminator inserted by
  # sti_unique_path so reruns inherit the original slug. Used by
  # /stride-ideation:ideate --continue to lock the topic slug to the source
  # document's slug — never re-prompts, so the refined doc pairs with the
  # original by filename family.
  local path="${1:-}"
  local artifact="${2:-}"
  if [ -z "$path" ] || [ -z "$artifact" ]; then
    echo "sti_slug_from_path: usage: sti_slug_from_path <path> <artifact>" >&2
    return 1
  fi
  local base
  base="$(basename "$path")"
  local stem="${base%.*}"
  # Match: YYYY-MM-DDTHHMMSS-<slug>-<artifact>(-<digits>)?
  # Capture only the slug. Portable across BSD and GNU sed via -E.
  local slug
  slug="$(printf '%s' "$stem" \
    | sed -E "s/^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{6}-(.+)-${artifact}(-[0-9]+)?$/\\1/")"
  if [ -z "$slug" ] || [ "$slug" = "$stem" ]; then
    echo "sti_slug_from_path: path does not match the expected filename family for artifact '$artifact': $path" >&2
    return 1
  fi
  printf '%s' "$slug"
}

sti_extract_seams() {
  # Parse a requirements doc's "## Decomposition seams" section and emit one
  # line per surface in the form:
  #
  #   <index>\t<name>\t<slug>
  #
  # <index> is 1-based and re-numbered in document order (the markdown
  # author's literal numbering is ignored — markdown renderers do the same).
  # <name> is the bold-name verbatim (may contain spaces and dashes).
  # <slug> is the slugified name via sti_slugify.
  #
  # Item-start pattern (anchored at line start, leading whitespace tolerated):
  #
  #   ^\s*<digits>.\s+\*\*<Name>\*\*...
  #
  # Multi-line item bodies are ignored — only the bold-name from the item's
  # first line yields a seam tuple. Items whose first line lacks **bold**
  # are silently skipped (they cannot be addressed by --goal anyway).
  #
  # Exit codes:
  #   0  section present (possibly with zero parseable items)
  #   1  I/O error / bad usage
  #   2  section absent — the "## Decomposition seams" heading is not in the doc
  #
  # The caller distinguishes "absent" (exit 2) from "present but empty"
  # (exit 0 with no stdout) — they produce different user-facing errors.
  local path="${1:-}"
  if [ -z "$path" ] || [ ! -f "$path" ]; then
    echo "sti_extract_seams: not a file: $path" >&2
    return 1
  fi
  if ! grep -qE '^## Decomposition seams[[:space:]]*$' "$path"; then
    return 2
  fi
  local body
  body="$(awk '
    /^## Decomposition seams[[:space:]]*$/ { in_section=1; next }
    in_section && /^## / { in_section=0 }
    in_section { print }
  ' "$path")"
  local idx=0
  printf '%s\n' "$body" \
    | sed -nE 's/^[[:space:]]*[0-9]+\.[[:space:]]+\*\*([^*]+)\*\*.*/\1/p' \
    | while IFS= read -r raw_name; do
        local slug
        slug="$(sti_slugify "$raw_name" 2>/dev/null)" || continue
        idx=$(( idx + 1 ))
        printf '%d\t%s\t%s\n' "$idx" "$raw_name" "$slug"
      done
}

sti_resolve_goal() {
  # Resolve a user-supplied --goal value against the seams in a requirements
  # doc. Echoes "<index>\t<name>\t<slug>" on match.
  #
  # Usage: sti_resolve_goal <markdown-path> <goal-arg>
  #
  # Resolution order:
  #   1. If <goal-arg> is purely digits AND a seam exists at that 1-based
  #      index, integer-match wins.
  #   2. Otherwise (or if integer-index miss), slugify <goal-arg> and
  #      exact-match against each seam's slug field. First match wins.
  #
  # Exit codes:
  #   0  match (tuple on stdout)
  #   1  bad usage
  #   2  section absent in doc
  #   3  no match (caller surfaces "did not match" error + lists seams)
  #   4  section present but empty
  local path="${1:-}"
  local arg="${2:-}"
  if [ -z "$path" ] || [ -z "$arg" ]; then
    echo "sti_resolve_goal: usage: sti_resolve_goal <markdown-path> <goal-arg>" >&2
    return 1
  fi
  local seams extract_rc
  seams="$(sti_extract_seams "$path")"
  extract_rc=$?
  if [ "$extract_rc" -ne 0 ]; then
    return "$extract_rc"
  fi
  if [ -z "$seams" ]; then
    return 4
  fi
  if printf '%s' "$arg" | grep -qE '^[0-9]+$'; then
    local int_match
    int_match="$(printf '%s\n' "$seams" | awk -F'\t' -v i="$arg" '$1 == i { print; exit }')"
    if [ -n "$int_match" ]; then
      printf '%s' "$int_match"
      return 0
    fi
    # Fall through to slug-match (covers a seam literally named "1" addressed by its slug).
  fi
  local arg_slug
  arg_slug="$(sti_slugify "$arg" 2>/dev/null)" || return 3
  local slug_match
  slug_match="$(printf '%s\n' "$seams" | awk -F'\t' -v s="$arg_slug" '$3 == s { print; exit }')"
  if [ -n "$slug_match" ]; then
    printf '%s' "$slug_match"
    return 0
  fi
  return 3
}

sti_scope_doc_to_seam() {
  # Rewrite a requirements doc to scope its "## Decomposition seams" section
  # to one surface. Emits the doc text on stdout with the section body
  # replaced by a one-line "Scoped to a single surface for this dispatch."
  # notice followed by the matched item's verbatim lines (start line + any
  # continuation lines until the next numbered item or the section's end).
  #
  # Content OUTSIDE the section is preserved verbatim. Content inside the
  # section that is NOT part of any numbered item (intro prose, "The seven
  # surfaces:" lead-in, etc.) is dropped — the directive line replaces it.
  #
  # Usage: sti_scope_doc_to_seam <markdown-path> <seam-index>
  local path="${1:-}"
  local target="${2:-}"
  if [ -z "$path" ] || [ -z "$target" ] || [ ! -f "$path" ]; then
    echo "sti_scope_doc_to_seam: usage: sti_scope_doc_to_seam <markdown-path> <seam-index>" >&2
    return 1
  fi
  awk -v target="$target" '
    BEGIN { state = 0; item_idx = 0; collecting = 0 }
    # state 0: before the seams section (print verbatim)
    # state 1: inside the seams section (only the matched item is kept)
    # state 2: after the seams section (print verbatim)
    state == 0 && /^## Decomposition seams[[:space:]]*$/ {
      print
      print ""
      print "**Scoped to a single surface for this dispatch.**"
      print ""
      state = 1
      next
    }
    state == 0 { print; next }
    state == 1 {
      if (/^## /) {
        state = 2
        print ""
        print
        next
      }
      if (match($0, /^[[:space:]]*[0-9]+\.[[:space:]]+\*\*/)) {
        item_idx = item_idx + 1
        collecting = (item_idx == target) ? 1 : 0
      }
      if (collecting) print
      next
    }
    state == 2 { print; next }
  ' "$path"
}

sti_unique_path() {
  local dir="${1:-}"
  local ts="${2:-}"
  local slug="${3:-}"
  local artifact="${4:-}"
  local ext="${5:-}"
  if [ -z "$dir" ] || [ -z "$ts" ] || [ -z "$slug" ] || [ -z "$artifact" ] || [ -z "$ext" ]; then
    echo "sti_unique_path: usage: sti_unique_path <dir> <ts> <slug> <artifact> <ext>" >&2
    return 1
  fi
  local base="${dir%/}/${ts}-${slug}-${artifact}"
  local candidate="${base}.${ext}"
  if [ ! -e "$candidate" ]; then
    printf '%s' "$candidate"
    return 0
  fi
  local n=2
  while [ -e "${base}-${n}.${ext}" ]; do
    n=$(( n + 1 ))
    if [ "$n" -gt 1000 ]; then
      echo "sti_unique_path: refusing to scan past -1000 collisions" >&2
      return 1
    fi
  done
  printf '%s' "${base}-${n}.${ext}"
}
