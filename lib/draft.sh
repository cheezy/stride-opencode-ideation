#!/usr/bin/env bash
# stride-ideation intra-session draft autosave helpers.
#
# Pure functions used by the /ideate command to persist an
# in-progress ideation draft (answered sections + round state) to a gitignored
# scratch file under .stride/, so an interruption mid-session is recoverable and
# a later session can offer to resume it:
#
#   sti_draft_path  <dir> <ts> <slug>   -> <dir>/<ts>-<slug>-draft.md
#   sti_draft_find  <dir> <slug>        -> path of the latest NON-EMPTY draft
#                                          for <slug> (any timestamp), or
#                                          non-zero if none
#   sti_draft_save  <path> <content>    -> writes <content> to <path>
#                                          (creating its parent dir)
#   sti_draft_load  <path>              -> emits the draft content to stdout
#   sti_draft_exists <path>             -> exit 0 if the draft exists and is
#                                          non-empty, non-zero otherwise
#   sti_draft_clear <path>              -> removes the draft (no error if gone)
#
# A PowerShell mirror lives at lib/draft.ps1 (PascalCase-with-hyphen cmdlets).
#
# Filename rule: the scratch path pairs with the eventual requirements doc by
# reusing the <ts>-<slug>-<artifact> convention from sti_unique_path, with the
# artifact token `draft`. The draft lives under a GITIGNORED .stride/ path so
# half-finished, possibly sensitive ideation is never committed; the helper
# never serializes any secret — it only writes the content it is handed.
#
# Resume keys on the SLUG, not the session timestamp: a fresh session has a new
# timestamp, so sti_draft_find globs every <ts>-<slug>-draft.md under the
# scratch dir and returns the latest match (ISO timestamps sort lexically). A
# different slug never matches, because the `-<slug>-draft.md` suffix is
# dash-delimited.
#
# All non-error output is written to stdout. Errors go to stderr with a
# non-zero exit code. Source this file, or call functions directly via:
#   bash -c '. lib/draft.sh; sti_draft_path .stride 2026-05-12T103000 foo'

set -u

sti_draft_path() {
  local dir="${1:-}"
  local ts="${2:-}"
  local slug="${3:-}"
  if [ -z "$dir" ] || [ -z "$ts" ] || [ -z "$slug" ]; then
    echo "sti_draft_path: usage: sti_draft_path <dir> <ts> <slug>" >&2
    return 1
  fi
  printf '%s' "${dir%/}/${ts}-${slug}-draft.md"
}

sti_draft_find() {
  # Find the latest NON-EMPTY scratch draft for <slug> under <dir>, regardless
  # of session timestamp. Returns its path on stdout, or non-zero (no stdout)
  # when the directory is absent or no non-empty draft matches. Empty draft
  # files are ignored so a zero-length scratch never triggers a resume offer.
  local dir="${1:-}"
  local slug="${2:-}"
  if [ -z "$dir" ] || [ -z "$slug" ]; then
    echo "sti_draft_find: usage: sti_draft_find <dir> <slug>" >&2
    return 1
  fi
  [ -d "$dir" ] || return 1
  local latest=""
  local f
  # The leading dash in the glob keeps slug `auth` from matching `oauth`.
  # With no match (and nullglob unset), the loop iterates once over the
  # literal unexpanded pattern; the `[ -e "$f" ]` guard skips it.
  for f in "${dir%/}/"*"-${slug}-draft.md"; do
    [ -e "$f" ] || continue
    [ -s "$f" ] || continue
    # Bash expands globs in collation order, but compare explicitly so the
    # "latest ISO timestamp wins" contract does not depend on locale ordering.
    if [ -z "$latest" ] || [ "$f" \> "$latest" ]; then
      latest="$f"
    fi
  done
  if [ -z "$latest" ]; then
    return 1
  fi
  printf '%s' "$latest"
}

sti_draft_save() {
  # Persist <content> to <path>, creating the parent directory if needed.
  # The only side effect is writing that one file (and mkdir -p of its dir).
  local path="${1:-}"
  local content="${2:-}"
  if [ -z "$path" ]; then
    echo "sti_draft_save: usage: sti_draft_save <path> <content>" >&2
    return 1
  fi
  local dir
  dir="$(dirname "$path")"
  if ! mkdir -p "$dir" 2>/dev/null; then
    echo "sti_draft_save: cannot create scratch directory: $dir" >&2
    return 1
  fi
  if ! printf '%s' "$content" > "$path" 2>/dev/null; then
    echo "sti_draft_save: cannot write scratch draft: $path" >&2
    return 1
  fi
}

sti_draft_load() {
  # Emit the draft content at <path> to stdout. Errors if the file is absent.
  local path="${1:-}"
  if [ -z "$path" ]; then
    echo "sti_draft_load: usage: sti_draft_load <path>" >&2
    return 1
  fi
  if [ ! -f "$path" ]; then
    echo "sti_draft_load: no scratch draft at: $path" >&2
    return 1
  fi
  cat "$path"
}

sti_draft_exists() {
  # Predicate: exit 0 if <path> is an existing NON-EMPTY draft, else non-zero.
  # No stdout. A zero-length scratch is treated as "no resumable draft".
  local path="${1:-}"
  if [ -z "$path" ]; then
    echo "sti_draft_exists: usage: sti_draft_exists <path>" >&2
    return 1
  fi
  [ -s "$path" ]
}

sti_draft_clear() {
  # Remove the scratch draft at <path>. Idempotent: no error if already gone.
  local path="${1:-}"
  if [ -z "$path" ]; then
    echo "sti_draft_clear: usage: sti_draft_clear <path>" >&2
    return 1
  fi
  rm -f "$path"
}
