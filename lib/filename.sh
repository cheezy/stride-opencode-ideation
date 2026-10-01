#!/usr/bin/env bash
# stride-ideation filename helpers.
#
# Pure functions used by the /ideate and /stridify commands to compute
# unique artifact paths (and, further down, slugs and Decomposition seams):
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
  # /ideate --continue to lock the topic slug to the source
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

_sti_seam_candidates() {
  # Internal. Print "<line>\t<name>" for every seam item start inside the
  # "## Decomposition seams" section of <path>, in document order. The whole
  # section uses ONE item shape, chosen by precedence:
  #
  #   1. numbered bold items   ^ {0,3}<digits>.\s+**<Name>**...  (top level:
  #                            at most 3 leading spaces, as markdown defines
  #                            a list item, so a nested numbered sub-list
  #                            under a bulleted seam never takes over)
  #   2. top-level bulleted    ^[-*]\s+**<Name>**...   (only if no 1.)
  #   3. level-3 headings      ^###\s+<Name>            (only if no 1. or 2.)
  #
  # so a numbered list's secondary cross-cutting bullets are never seams. A
  # bold name may not contain `*`; a line that does not match the chosen
  # shape is part of the item above it. sti_extract_seams and
  # sti_scope_doc_to_seam both read this list, so they always index the same
  # items — the index the resolver returns is the item the scoper keeps.
  awk '
    /^## Decomposition seams[[:space:]]*$/ { in_s = 1; next }
    in_s && /^## / { in_s = 0 }
    in_s {
      n++; line[n] = NR; text[n] = $0
      if ($0 ~ /^ ? ? ?[0-9]+\.[[:space:]]+\*\*[^*]+\*\*/) has_num = 1
      else if ($0 ~ /^[-*][[:space:]]+\*\*[^*]+\*\*/) has_bul = 1
      else if ($0 ~ /^###[[:space:]]+[^[:space:]]/) has_h3 = 1
    }
    END {
      shape = has_num ? "num" : (has_bul ? "bul" : (has_h3 ? "h3" : ""))
      for (i = 1; i <= n; i++) {
        s = text[i]; name = ""
        if (shape == "num" && s ~ /^ ? ? ?[0-9]+\.[[:space:]]+\*\*[^*]+\*\*/) {
          sub(/^ ? ? ?[0-9]+\.[[:space:]]+\*\*/, "", s)
          name = substr(s, 1, index(s, "**") - 1)
        } else if (shape == "bul" && s ~ /^[-*][[:space:]]+\*\*[^*]+\*\*/) {
          sub(/^[-*][[:space:]]+\*\*/, "", s)
          name = substr(s, 1, index(s, "**") - 1)
        } else if (shape == "h3" && s ~ /^###[[:space:]]+[^[:space:]]/) {
          sub(/^###[[:space:]]+/, "", s)
          sub(/[[:space:]]+$/, "", s)
          name = s
        }
        if (name != "") printf "%d\t%s\n", line[i], name
      }
    }
  ' "$1"
}

_sti_seam_items() {
  # Internal. Print "<line>\t<name>\t<slug>" for every ADDRESSABLE seam: the
  # candidates above whose name slugifies. A name that does not slugify is
  # skipped here, once, for both extraction and scoping.
  local tab line raw_name slug
  tab="$(printf '\t')"
  _sti_seam_candidates "$1" | while IFS="$tab" read -r line raw_name; do
    slug="$(sti_slugify "$raw_name" 2>/dev/null)" || continue
    printf '%s\t%s\t%s\n' "$line" "$raw_name" "$slug"
  done
}

sti_extract_seams() {
  # Parse a requirements doc's "## Decomposition seams" section and emit one
  # line per surface in the form:
  #
  #   <index>\t<name>\t<slug>
  #
  # <index> is 1-based and re-numbered in document order (the markdown
  # author's literal numbering is ignored — markdown renderers do the same).
  # <name> is the item's name verbatim (may contain spaces and dashes).
  # <slug> is the slugified name via sti_slugify.
  #
  # Accepted item shapes (one per section, by precedence — see
  # _sti_seam_candidates): numbered `<N>. **Name** ...` items; else top-level
  # bulleted `- **Name** ...` items; else `### Name` headings. Multi-line
  # item bodies are ignored — only the name yields a seam tuple. Items
  # without a bold name (numbered/bulleted) are silently skipped (they
  # cannot be addressed by --goal anyway), as are names that do not slugify.
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
  _sti_seam_items "$path" | awk -F'\t' '{ printf "%d\t%s\t%s\n", NR, $2, $3 }'
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

sti_goal_fields() {
  # Split a sti_resolve_goal tuple ("<index>\t<name>\t<slug>") into three
  # KEY=value lines, in this order:
  #
  #   GOAL_INDEX=<index>
  #   GOAL_NAME=<name>
  #   GOAL_SLUG=<slug>
  #
  # It exists so commands/stridify.md needs no awk positional-field
  # references: OpenCode's command expansion replaces every dollar sign
  # followed by a digit in a command template with the user's arguments,
  # which silently rewrote those references.
  #
  # Usage: sti_goal_fields <tuple>
  #
  # Exit codes:
  #   0  three lines on stdout
  #   1  bad usage — empty, not exactly three tab-separated fields, a
  #      non-numeric index, or an empty name or slug
  local tuple="${1:-}"
  local tab idx name slug rest
  tab="$(printf '\t')"
  case "$tuple" in
    *"$tab"*"$tab"*"$tab"*|"") echo "sti_goal_fields: usage: sti_goal_fields <index<TAB>name<TAB>slug>" >&2; return 1 ;;
    *"$tab"*"$tab"*) ;;
    *) echo "sti_goal_fields: usage: sti_goal_fields <index<TAB>name<TAB>slug>" >&2; return 1 ;;
  esac
  idx="${tuple%%"$tab"*}"
  rest="${tuple#*"$tab"}"
  name="${rest%%"$tab"*}"
  slug="${rest#*"$tab"}"
  if ! printf '%s' "$idx" | grep -qE '^[0-9]+$' || [ -z "$name" ] || [ -z "$slug" ]; then
    echo "sti_goal_fields: usage: sti_goal_fields <index<TAB>name<TAB>slug>" >&2
    return 1
  fi
  printf 'GOAL_INDEX=%s\nGOAL_NAME=%s\nGOAL_SLUG=%s\n' "$idx" "$name" "$slug"
}

sti_scope_doc_to_seam() {
  # Rewrite a requirements doc to scope its "## Decomposition seams" section
  # to one surface. Emits the doc text on stdout with the section body
  # replaced by a one-line "Scoped to a single surface for this dispatch."
  # notice followed by the matched item's verbatim lines (start line + any
  # continuation lines until the next item start or the section's end).
  #
  # <seam-index> is the index sti_extract_seams assigns: both read the same
  # item list (_sti_seam_items), so a resolved --goal always scopes to the
  # surface it named, whichever item shape the section uses.
  #
  # Content OUTSIDE the section is preserved verbatim. Content inside the
  # section that is NOT part of the matched item (intro prose, "The seven
  # surfaces:" lead-in, other items, etc.) is dropped — the directive line
  # replaces it.
  #
  # Usage: sti_scope_doc_to_seam <markdown-path> <seam-index>
  local path="${1:-}"
  local target="${2:-}"
  if [ -z "$path" ] || [ -z "$target" ] || [ ! -f "$path" ]; then
    echo "sti_scope_doc_to_seam: usage: sti_scope_doc_to_seam <markdown-path> <seam-index>" >&2
    return 1
  fi
  local start end
  start="$(_sti_seam_items "$path" | awk -F'\t' -v t="$target" 'NR == t + 0 && t ~ /^[0-9]+$/ { print $1; exit }')"
  end=""
  if [ -n "$start" ]; then
    end="$(_sti_seam_candidates "$path" | awk -F'\t' -v s="$start" '$1 + 0 > s + 0 { print $1; exit }')"
  fi
  awk -v start="${start:-0}" -v end="${end:-0}" '
    BEGIN { state = 0 }
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
      if (start > 0 && NR >= start + 0 && (end + 0 == 0 || NR < end + 0)) print
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
