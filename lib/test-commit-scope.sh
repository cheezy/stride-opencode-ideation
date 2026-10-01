#!/usr/bin/env bash
# Tests that the commit fragments in /ideate (Step 9) and /stridify (Step 8d)
# commit ONLY the artifact they wrote.
#
# A plain `git add <path>; git commit -m ...` commits everything already
# staged, so a user's unrelated staged work would ride along in a
# "stride-ideation:" commit. The fragments pass the artifact as a pathspec
# after `--`. These tests extract the real fragments from the command files
# and run each in a brand-new `bash --noprofile --norc -u`, in scratch repos
# that have other files staged beforehand. A PowerShell mirror lives at
# lib/test-commit-scope.ps1.
#
# Run:
#   ./lib/test-commit-scope.sh
#
# Exits 0 if all tests pass, non-zero otherwise.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUNDLE="$(cd "${SCRIPT_DIR}/.." && pwd)"

if [ ! -f "$BUNDLE/commands/ideate.md" ] || [ ! -f "$BUNDLE/commands/stridify.md" ]; then
  printf 'SKIP  commands/ not found beside lib/ (run this from a checkout)\n\n0 passed, 0 failed\n'
  exit 0
fi

PASS=0
FAIL=0
ROOT=""

cleanup() {
  if [ -n "$ROOT" ] && [ -d "$ROOT" ]; then
    rm -rf "$ROOT"
  fi
}
trap cleanup EXIT

ROOT="$(mktemp -d)"
TMP="$ROOT/commit scope"
mkdir -p "$TMP"

pass() { PASS=$(( PASS + 1 )); printf 'PASS  %s\n' "$1"; }
fail() { FAIL=$(( FAIL + 1 )); printf 'FAIL  %s\n' "$1"; if [ -n "${2:-}" ]; then printf '      %s\n' "$2"; fi; }
expect_eq() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "got [$2] want [$3]"; fi; }

# extract <command.md> <needle> <out> — the fenced bash block containing <needle>.
extract() {
  python3 - "$1" "$2" "$3" <<'PY'
import re
import sys

src, needle, out = sys.argv[1:4]
blocks, cur = [], None
for line in open(src, encoding='utf-8').read().split('\n'):
    if cur is None and re.match(r'^```bash\s*$', line):
        cur = []
    elif cur is not None and line.strip() == '```':
        blocks.append('\n'.join(cur))
        cur = None
    elif cur is not None:
        cur.append(line)
hits = [b for b in blocks if needle in b]
if len(hits) != 1:
    sys.exit(f'expected exactly one block containing {needle!r}, found {len(hits)}')
open(out, 'w', encoding='utf-8').write(hits[0] + '\n')
PY
}

extract "$BUNDLE/commands/ideate.md" 'stride-ideation: requirements for' "$TMP/ideate-commit.sh" || { fail "found the ideate Step 9 fragment"; exit 1; }
extract "$BUNDLE/commands/stridify.md" 'stride-ideation: decomposition for' "$TMP/stridify-commit.sh" || { fail "found the stridify Step 8d fragment"; exit 1; }
pass "found the ideate Step 9 and stridify Step 8d fragments"

# new_repo <name> — a scratch repo with a project-local helper install, an
# initial commit, and one unrelated file the user has already staged.
new_repo() {
  R="$TMP/$1"
  mkdir -p "$R/.opencode/stride-ideation"
  git -C "$R" init -q
  git -C "$R" config user.email t@example.com
  git -C "$R" config user.name tester
  printf 'base\n' > "$R/README"
  git -C "$R" add README
  git -C "$R" commit -q -m init
  cp -R "$BUNDLE/lib" "$R/.opencode/stride-ideation/lib"
  printf 'secret-ish user work\n' > "$R/userwork.txt"
  git -C "$R" add userwork.txt
}

# run_commit <fragment> NAME=value... — runs it in a fresh shell in $R.
run_commit() {
  local frag="$1" kv script="$TMP/run.sh"; shift
  : > "$script"
  for kv in "$@"; do
    printf "%s='%s'\n" "${kv%%=*}" "$(printf '%s' "${kv#*=}" | sed "s/'/'\\\\''/g")" >> "$script"
  done
  cat "$frag" >> "$script"
  (cd "$R" && env -i PATH="$PATH" HOME="$TMP" bash --noprofile --norc -u "$script" > "$TMP/out" 2> "$TMP/err")
  RC=$?
}
committed() { git -C "$R" show --name-only --format= HEAD; }
staged() { git -C "$R" diff --cached --name-only; }

# --- /ideate Step 9 ------------------------------------------------------------

printf '\n/ideate Step 9 with unrelated work already staged\n'
new_repo ideate
DOC="docs/ideation/2026-05-12T120000-dark-mode-requirements.md"
mkdir -p "$R/docs/ideation"
printf '# Dark mode\n' > "$R/$DOC"
run_commit "$TMP/ideate-commit.sh" "TARGET_PATH=$DOC" "SLUG=dark-mode" "CONTINUE_PATH=" "DRAFT_PATH=.stride/none-draft.md"
expect_eq "ideate: the commit succeeds" "$RC" "0"
expect_eq "ideate: the commit contains only the doc" "$(committed)" "$DOC"
expect_eq "ideate: the user's staged file stays staged" "$(staged)" "userwork.txt"
expect_eq "ideate: commit subject" "$(git -C "$R" log -1 --format=%s)" "stride-ideation: requirements for dark-mode"

printf '\n/ideate Step 9 in --continue mode\n'
new_repo cont
SRC_DOC="docs/ideation/2026-05-12T120000-dark-mode-requirements.md"
NEW_DOC="docs/ideation/2026-05-13T090000-dark-mode-requirements.md"
mkdir -p "$R/docs/ideation"
printf '# v1\n' > "$R/$SRC_DOC"
git -C "$R" add "$SRC_DOC" && git -C "$R" commit -q -m "v1" -- "$SRC_DOC"
printf '# v1, edited by the user\n' > "$R/$SRC_DOC"
git -C "$R" add "$SRC_DOC"
printf '# v2\n' > "$R/$NEW_DOC"
run_commit "$TMP/ideate-commit.sh" "TARGET_PATH=$NEW_DOC" "SLUG=dark-mode" "CONTINUE_PATH=$SRC_DOC" "DRAFT_PATH=.stride/none-draft.md"
expect_eq "continue: the commit succeeds" "$RC" "0"
expect_eq "continue: the commit contains only the refined doc" "$(committed)" "$NEW_DOC"
expect_eq "continue: commit subject" "$(git -C "$R" log -1 --format=%s)" "stride-ideation: refine requirements for dark-mode"
if staged | grep -qxF "$SRC_DOC"; then pass "continue: a staged edit to the source doc stays staged, uncommitted"; else fail "continue: the source doc edit was swept in"; fi

printf '\n/ideate Step 9 with nothing else staged\n'
new_repo clean
git -C "$R" rm -q --cached userwork.txt
DOC="docs/ideation/2026-05-12T120000-solo-requirements.md"
mkdir -p "$R/docs/ideation"
printf '# Solo\n' > "$R/$DOC"
run_commit "$TMP/ideate-commit.sh" "TARGET_PATH=$DOC" "SLUG=solo" "CONTINUE_PATH=" "DRAFT_PATH=.stride/none-draft.md"
expect_eq "clean: the commit succeeds" "$RC" "0"
expect_eq "clean: the commit contains the doc" "$(committed)" "$DOC"
expect_eq "clean: nothing is left staged" "$(staged)" ""

printf '\n/ideate Step 9 refuses a TARGET_PATH that is not a regular file\n'
new_repo notfile
mkdir -p "$R/docs/ideation"
printf 'stray untracked notes\n' > "$R/docs/ideation/stray.md"
HEAD_BEFORE="$(git -C "$R" rev-parse HEAD)"
run_commit "$TMP/ideate-commit.sh" "TARGET_PATH=docs/ideation" "SLUG=x" "CONTINUE_PATH=" "DRAFT_PATH=.stride/none-draft.md"
expect_eq "not-a-file: a directory TARGET_PATH stops the fragment" "$RC" "1"
expect_eq "not-a-file: nothing is committed" "$(git -C "$R" rev-parse HEAD)" "$HEAD_BEFORE"
if git -C "$R" ls-files --error-unmatch docs/ideation/stray.md > /dev/null 2>&1; then fail "not-a-file: the stray file was added"; else pass "not-a-file: the stray file is not added"; fi
ln -s README "$R/docs/ideation/link-requirements.md"
run_commit "$TMP/ideate-commit.sh" "TARGET_PATH=docs/ideation/link-requirements.md" "SLUG=x" "CONTINUE_PATH=" "DRAFT_PATH=.stride/none-draft.md"
expect_eq "not-a-file: a symlink TARGET_PATH stops the fragment" "$RC" "1"

# --- /stridify Step 8d ----------------------------------------------------------

printf '\n/stridify Step 8d with unrelated work already staged and spaces in the path\n'
new_repo stridify
BATCH="docs/my ideas/2026-05-12T120000-dark-mode-kanban-app-stride-batch.json"
mkdir -p "$R/docs/my ideas"
printf '{"goals": []}\n' > "$R/$BATCH"
run_commit "$TMP/stridify-commit.sh" "TARGET_PATH=$BATCH" "SLUG=dark-mode" "GOAL_SLUG=kanban-app"
expect_eq "stridify: the commit succeeds" "$RC" "0"
expect_eq "stridify: the commit contains only the batch JSON" "$(committed)" "$BATCH"
expect_eq "stridify: the user's staged file stays staged" "$(staged)" "userwork.txt"
expect_eq "stridify: commit subject names the goal" "$(git -C "$R" log -1 --format=%s)" "stride-ideation: decomposition for dark-mode goal kanban-app"
expect_eq "stridify: carries BATCH_PATH" "$(sed -n 's/^carry: BATCH_PATH=//p' "$TMP/out")" "$BATCH"

printf '\n/stridify Step 8d refuses a TARGET_PATH that is not a regular file\n'
new_repo stridify-notfile
mkdir -p "$R/docs"
printf 'stray untracked notes\n' > "$R/docs/stray.json"
HEAD_BEFORE="$(git -C "$R" rev-parse HEAD)"
run_commit "$TMP/stridify-commit.sh" "TARGET_PATH=docs" "SLUG=x" "GOAL_SLUG="
expect_eq "stridify not-a-file: a directory TARGET_PATH stops the fragment" "$RC" "1"
expect_eq "stridify not-a-file: nothing is committed" "$(git -C "$R" rev-parse HEAD)" "$HEAD_BEFORE"

printf '\n/stridify Step 8d with pathspec-magic characters in the path\n'
new_repo magic
printf 'other\n' > "$R/docs-other.json"
git -C "$R" add docs-other.json
BATCH="docs/*-stride-batch.json"
mkdir -p "$R/docs"
printf '{"goals": []}\n' > "$R/$BATCH"
printf 'decoy\n' > "$R/docs/decoy-stride-batch.json"
run_commit "$TMP/stridify-commit.sh" "TARGET_PATH=$BATCH" "SLUG=dark-mode" "GOAL_SLUG="
expect_eq "magic: the commit succeeds" "$RC" "0"
expect_eq "magic: a * in the path matches only that file" "$(committed)" "$BATCH"
if git -C "$R" ls-files --error-unmatch docs/decoy-stride-batch.json > /dev/null 2>&1; then fail "magic: the decoy was added"; else pass "magic: the decoy is not added"; fi

# --- summary -----------------------------------------------------------------

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
