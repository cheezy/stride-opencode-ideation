#!/usr/bin/env bash
# Unit tests for lib/filename.sh.
#
# Run:
#   ./lib/test-filename.sh
#
# Exits 0 if all tests pass, non-zero otherwise. Prints a one-line
# per-test status to stdout.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/filename.sh"

PASS=0
FAIL=0
TMP=""

cleanup() {
  if [ -n "$TMP" ] && [ -d "$TMP" ]; then
    rm -rf "$TMP"
  fi
}
trap cleanup EXIT

TMP="$(mktemp -d)"

assert_eq() {
  local label="$1"
  local actual="$2"
  local expected="$3"
  if [ "$actual" = "$expected" ]; then
    PASS=$(( PASS + 1 ))
    printf 'PASS  %s\n' "$label"
  else
    FAIL=$(( FAIL + 1 ))
    printf 'FAIL  %s\n      expected: %s\n      actual:   %s\n' "$label" "$expected" "$actual"
  fi
}

# --- slugify ---------------------------------------------------------------

assert_eq "slugify lowercases and dash-separates words" \
  "$(sti_slugify 'Add Notifications')" "add-notifications"

assert_eq "slugify replaces non-alphanumerics with dashes (not deleted)" \
  "$(sti_slugify 'Add Push! Notifications?')" "add-push-notifications"

assert_eq "slugify collapses runs of dashes" \
  "$(sti_slugify 'foo   bar---baz')" "foo-bar-baz"

assert_eq "slugify trims leading and trailing dashes" \
  "$(sti_slugify '---Hello World---')" "hello-world"

assert_eq "slugify preserves numbers" \
  "$(sti_slugify 'oauth2 login')" "oauth2-login"

# --- unique_path -----------------------------------------------------------

TS="2026-05-12T103000"
SLUG="add-notifications"

# Fresh: no collision → base name returned.
EXPECTED_FRESH="${TMP}/${TS}-${SLUG}-requirements.md"
assert_eq "fresh timestamp produces base name" \
  "$(sti_unique_path "$TMP" "$TS" "$SLUG" requirements md)" \
  "$EXPECTED_FRESH"

# Single collision: base exists → -2 returned.
touch "$EXPECTED_FRESH"
EXPECTED_TWO="${TMP}/${TS}-${SLUG}-requirements-2.md"
assert_eq "collision produces -2 suffix" \
  "$(sti_unique_path "$TMP" "$TS" "$SLUG" requirements md)" \
  "$EXPECTED_TWO"

# Double collision: base AND -2 exist → -3 returned.
touch "$EXPECTED_TWO"
EXPECTED_THREE="${TMP}/${TS}-${SLUG}-requirements-3.md"
assert_eq "double collision produces -3 suffix" \
  "$(sti_unique_path "$TMP" "$TS" "$SLUG" requirements md)" \
  "$EXPECTED_THREE"

# Hard invariant: helper must never return a path that already exists.
touch "$EXPECTED_THREE"
NEXT_PATH="$(sti_unique_path "$TMP" "$TS" "$SLUG" requirements md)"
if [ -e "$NEXT_PATH" ]; then
  FAIL=$(( FAIL + 1 ))
  printf 'FAIL  HARD INVARIANT: returned an existing path: %s\n' "$NEXT_PATH"
else
  PASS=$(( PASS + 1 ))
  printf 'PASS  HARD INVARIANT: returned path does not exist (%s)\n' "$(basename "$NEXT_PATH")"
fi

# Slug normalization happens upstream, but the test below proves that
# sti_slugify + sti_unique_path together produce a path with the expected
# normalized slug from a noisy human-typed input.
NOISY_TS="2026-05-12T110000"
SLUG_FROM_HUMAN="$(sti_slugify 'Add Notifications')"
EXPECTED_COMBINED="${TMP}/${NOISY_TS}-${SLUG_FROM_HUMAN}-stride-batch.json"
assert_eq "slug with spaces normalizes correctly through unique_path" \
  "$(sti_unique_path "$TMP" "$NOISY_TS" "$SLUG_FROM_HUMAN" stride-batch json)" \
  "$EXPECTED_COMBINED"

# --- slug_from_path --------------------------------------------------------

assert_eq "slug_from_path: simple requirements artifact" \
  "$(sti_slug_from_path 'docs/ideation/2026-05-12T103000-add-notifications-requirements.md' requirements)" \
  "add-notifications"

assert_eq "slug_from_path: works without a directory prefix" \
  "$(sti_slug_from_path '2026-05-12T103000-add-notifications-requirements.md' requirements)" \
  "add-notifications"

assert_eq "slug_from_path: strips a -2 collision discriminator" \
  "$(sti_slug_from_path '2026-05-12T103000-add-notifications-requirements-2.md' requirements)" \
  "add-notifications"

assert_eq "slug_from_path: strips a -10 collision discriminator" \
  "$(sti_slug_from_path '2026-05-12T103000-add-notifications-requirements-10.md' requirements)" \
  "add-notifications"

assert_eq "slug_from_path: preserves trailing slug digits when artifact follows them" \
  "$(sti_slug_from_path '2026-05-12T103000-oauth2-login-requirements.md' requirements)" \
  "oauth2-login"

assert_eq "slug_from_path: multi-word artifact (stride-batch)" \
  "$(sti_slug_from_path '2026-05-12T103000-add-notifications-stride-batch.json' stride-batch)" \
  "add-notifications"

assert_eq "slug_from_path: multi-word artifact with collision discriminator" \
  "$(sti_slug_from_path '2026-05-12T103000-add-notifications-stride-batch-3.json' stride-batch)" \
  "add-notifications"

# Negative case: path that doesn't match the expected family should fail
# and produce no stdout (we redirect stderr so the harness output stays clean).
BAD_OUT="$(sti_slug_from_path 'not-a-timestamped-filename.md' requirements 2>/dev/null || true)"
if [ -z "$BAD_OUT" ]; then
  PASS=$(( PASS + 1 ))
  printf 'PASS  slug_from_path: malformed path produces empty stdout (non-zero exit)\n'
else
  FAIL=$(( FAIL + 1 ))
  printf 'FAIL  slug_from_path: malformed path leaked output: %s\n' "$BAD_OUT"
fi

# --- goal_fields -----------------------------------------------------------

TAB="$(printf '\t')"
assert_eq "goal_fields: splits a resolved seam into index, name and slug" \
  "$(sti_goal_fields "2${TAB}Kanban app${TAB}kanban-app")" \
  "$(printf 'GOAL_INDEX=2\nGOAL_NAME=Kanban app\nGOAL_SLUG=kanban-app')"
assert_eq "goal_fields: a name with spaces, dashes and an equals sign is kept whole" \
  "$(sti_goal_fields "10${TAB}A - B = C${TAB}a-b-c" | sed -n 2p)" \
  "GOAL_NAME=A - B = C"
for bad in "" "2" "2${TAB}name" "x${TAB}name${TAB}slug" "2${TAB}${TAB}slug" "2${TAB}name${TAB}" "2${TAB}a${TAB}b${TAB}c"; do
  if BAD_OUT="$(sti_goal_fields "$bad" 2>/dev/null)"; then
    FAIL=$(( FAIL + 1 )); printf 'FAIL  goal_fields: accepted a malformed tuple: [%s]\n' "$bad"
  elif [ -n "$BAD_OUT" ]; then
    FAIL=$(( FAIL + 1 )); printf 'FAIL  goal_fields: malformed tuple leaked output: %s\n' "$BAD_OUT"
  else
    PASS=$(( PASS + 1 )); printf 'PASS  goal_fields: rejects a malformed tuple with no stdout\n'
  fi
done
DOC="$(mktemp)"
printf '# T\n\n## Decomposition seams\n\n1. **Kanban app** \xe2\x80\x94 owns it\n2. **stride plugin** \xe2\x80\x94 adapter\n' > "$DOC"
assert_eq "goal_fields: chains from sti_resolve_goal by name" \
  "$(sti_goal_fields "$(sti_resolve_goal "$DOC" "stride plugin")" | tr '\n' '|')" \
  "GOAL_INDEX=2|GOAL_NAME=stride plugin|GOAL_SLUG=stride-plugin|"
rm -f "$DOC"

# --- summary ---------------------------------------------------------------

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
