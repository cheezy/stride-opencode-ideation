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
#   sti_scratch_dir <dir> [<name>]      -> creates <dir>; when it is named
#                                          .stride, also writes .stride/.gitignore
#                                          containing '*' if absent; inside a git
#                                          work tree, refuses unless git ignores
#                                          <dir>/<name>
#   sti_draft_save  <path> [<content>]  -> writes <content> to <path>, or
#                                          stdin when no content argument is
#                                          given (creating its parent dir via
#                                          sti_scratch_dir)
#   sti_draft_load  <path>              -> emits the draft content to stdout
#   sti_draft_exists <path>             -> exit 0 if the draft exists and is
#                                          non-empty, non-zero otherwise
#   sti_draft_clear <path>              -> removes the draft (no error if gone)
#
# A PowerShell mirror lives at lib/draft.ps1 (PascalCase-with-hyphen cmdlets).
#
# Filename rule: the scratch path pairs with the eventual requirements doc by
# reusing the <ts>-<slug>-<artifact> convention from sti_unique_path, with the
# artifact token `draft`. The draft lives under .stride/, which ignores itself
# (sti_scratch_dir writes .stride/.gitignore containing '*' — the user's own
# .gitignore is never touched), so half-finished, possibly sensitive ideation
# never shows in `git status` and is never swept into a commit; the helper
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
  # Only offer a draft resuming can safely rewrite: never a symlink (the write
  # would land at its target), and inside a git work tree only one git ignores
  # (a tracked or re-included draft would carry the new prose into a commit).
  local in_git=0
  if git -C "$dir" rev-parse --is-inside-work-tree > /dev/null 2>&1; then in_git=1; fi
  local latest=""
  local f
  # The leading dash in the glob keeps slug `auth` from matching `oauth`.
  # With no match (and nullglob unset), the loop iterates once over the
  # literal unexpanded pattern; the `[ -e "$f" ]` guard skips it.
  for f in "${dir%/}/"*"-${slug}-draft.md"; do
    [ -e "$f" ] || continue
    [ -L "$f" ] && continue
    [ -s "$f" ] || continue
    if [ "$in_git" = 1 ] && ! git -C "$dir" check-ignore -q -- "$(basename "$f")" 2>/dev/null; then
      continue
    fi
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

sti_scratch_dir() {
  # Create the scratch directory <dir> if needed. When <dir> is named .stride,
  # also make it ignore itself: write <dir>/.gitignore containing '*' if that
  # file is absent (an existing one is left exactly as it is), so drafts never
  # show in `git status` or `git add -A` in any repository — without editing the
  # user's own .gitignore. Any other directory name gets no .gitignore, so a
  # draft path outside .stride/ can never hide a user's files. A symlinked
  # <dir> is refused: writing through it could land a draft somewhere else.
  #
  # Fail closed inside a git work tree: unless git actually ignores
  # <dir>/<name> (default: a probe draft name), refuse — an existing
  # .stride/.gitignore that re-includes drafts, or a draft that is already
  # tracked, would otherwise let half-finished prose reach a commit.
  local dir="${1:-}"
  local name="${2:-0000-00-00T000000-probe-draft.md}"
  if [ -z "$dir" ]; then
    echo "sti_scratch_dir: usage: sti_scratch_dir <dir> [<name>]" >&2
    return 1
  fi
  case "$name" in
    */*) echo "sti_scratch_dir: <name> must be a file name, not a path: $name" >&2; return 1 ;;
  esac
  dir="${dir%/}"
  if [ -L "$dir" ]; then
    echo "sti_scratch_dir: refusing a symlinked scratch directory: $dir" >&2
    return 1
  fi
  if ! mkdir -p "$dir" 2>/dev/null; then
    echo "sti_scratch_dir: cannot create scratch directory: $dir" >&2
    return 1
  fi
  if [ "$(basename "$dir")" = ".stride" ] && [ ! -e "$dir/.gitignore" ] && [ ! -L "$dir/.gitignore" ]; then
    if ! printf '*\n' > "$dir/.gitignore" 2>/dev/null; then
      echo "sti_scratch_dir: cannot write $dir/.gitignore" >&2
      return 1
    fi
  fi
  if git -C "$dir" rev-parse --is-inside-work-tree > /dev/null 2>&1 &&
     ! git -C "$dir" check-ignore -q -- "$name" 2>/dev/null; then
    echo "sti_scratch_dir: git would not ignore $dir/$name (a .gitignore re-includes it, or it is already tracked); refusing to write a draft there" >&2
    return 1
  fi
}

sti_draft_save() {
  # Persist the draft to <path>, creating the parent directory if needed (via
  # sti_scratch_dir, so a .stride/ parent ignores itself). The content is the
  # second argument when one is given — even an empty one — and otherwise
  # stdin, written byte for byte, so arbitrary prose never has to be
  # shell-quoted onto a command line. The only side effects are that one file
  # and the scratch directory (plus its .gitignore).
  local path="${1:-}"
  if [ -z "$path" ]; then
    echo "sti_draft_save: usage: sti_draft_save <path> [<content>]  (content from stdin when omitted)" >&2
    return 1
  fi
  local content
  if [ "$#" -ge 2 ]; then
    content="$2"
  elif [ -t 0 ]; then
    # No content argument and an interactive stdin: a usage error rather than
    # a silent wait for input (Sti-DraftSave refuses the same case).
    echo "sti_draft_save: no content given (pass it as an argument, or pipe it in)" >&2
    return 1
  else
    # The trailing sentinel keeps command substitution from stripping the
    # draft's own trailing newlines.
    content="$(cat; printf '.')"
    content="${content%.}"
  fi
  sti_scratch_dir "$(dirname "$path")" "$(basename "$path")" || return 1
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
