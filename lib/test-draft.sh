#!/usr/bin/env bash
# Unit tests for lib/draft.sh — the stride-ideation-ideate intra-session draft
# autosave/resume helpers (W1145). A PowerShell mirror lives at
# lib/test-draft.ps1.
#
# Run:
#   ./lib/test-draft.sh
#
# Exits 0 if all tests pass, non-zero otherwise. Prints a one-line per-test
# status to stdout.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/draft.sh"

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

ok() { PASS=$(( PASS + 1 )); printf 'PASS  %s\n' "$1"; }
no() { FAIL=$(( FAIL + 1 )); printf 'FAIL  %s\n' "$1"; }

# --- draft_path: deterministic for a given ts+slug ---------------------------

assert_eq "draft_path: <dir>/<ts>-<slug>-draft.md" \
  "$(sti_draft_path .stride 2026-05-12T103000 add-notifications)" \
  ".stride/2026-05-12T103000-add-notifications-draft.md"

assert_eq "draft_path: trailing slash on dir is normalized" \
  "$(sti_draft_path .stride/ 2026-05-12T103000 foo)" \
  ".stride/2026-05-12T103000-foo-draft.md"

P1="$(sti_draft_path "$TMP" 2026-05-12T103000 foo)"
P2="$(sti_draft_path "$TMP" 2026-05-12T103000 foo)"
assert_eq "draft_path: deterministic for a given SESSION_TS+slug" "$P1" "$P2"

BAD="$(sti_draft_path "$TMP" 2026-05-12T103000 2>/dev/null || true)"
if [ -z "$BAD" ]; then
  ok "draft_path: missing slug -> empty stdout + non-zero"
else
  no "draft_path: missing slug leaked output: $BAD"
fi

# --- save then load: round-trips content ------------------------------------

DRAFT="$(sti_draft_path "$TMP/.stride" 2026-05-12T103000 round-trip)"
CONTENT="## Goal
Ship the digest.

## Problem
Approvals rot in inboxes.
__round_state__: 2"

if sti_draft_save "$DRAFT" "$CONTENT"; then
  ok "draft_save: writes the scratch file (and creates .stride/ parent)"
else
  no "draft_save: failed to write"
fi

if [ -f "$DRAFT" ]; then
  ok "draft_save: scratch file exists at the computed path"
else
  no "draft_save: scratch file missing after save"
fi

assert_eq "draft_load: round-trips the saved content byte-for-byte" \
  "$(sti_draft_load "$DRAFT")" "$CONTENT"

# --- exists: predicate on non-empty draft -----------------------------------

if sti_draft_exists "$DRAFT"; then
  ok "draft_exists: true for a non-empty draft"
else
  no "draft_exists: false for a non-empty draft (should be true)"
fi

EMPTY="$(sti_draft_path "$TMP/.stride" 2026-05-12T103000 empty-draft)"
: > "$EMPTY"
if sti_draft_exists "$EMPTY"; then
  no "draft_exists: true for an empty draft (should be false)"
else
  ok "draft_exists: false for an empty/zero-length draft (partial -> fresh)"
fi

if sti_draft_exists "$TMP/.stride/nope-draft.md"; then
  no "draft_exists: true for an absent draft (should be false)"
else
  ok "draft_exists: false for an absent draft"
fi

# --- load: absent file -> non-zero, no crash --------------------------------

LOAD_BAD="$(sti_draft_load "$TMP/.stride/missing-draft.md" 2>/dev/null || true)"
if [ -z "$LOAD_BAD" ]; then
  ok "draft_load: absent file -> empty stdout + non-zero (safe, no crash)"
else
  no "draft_load: absent file leaked output: $LOAD_BAD"
fi

# --- save: mkdir-failure branch returns non-zero, no crash ------------------

BLOCKER="$TMP/blocker"
: > "$BLOCKER"
SAVE_ERR="$(sti_draft_save "$BLOCKER/sub/2026-05-12T103000-x-draft.md" "body" 2>&1 || true)"
if sti_draft_save "$BLOCKER/sub/2026-05-12T103000-x-draft.md" "body" 2>/dev/null; then
  no "draft_save: succeeded despite an unmakeable parent dir (should fail)"
else
  ok "draft_save: returns non-zero when the parent dir cannot be created (no crash)"
fi
if printf '%s' "$SAVE_ERR" | grep -q "cannot create scratch directory"; then
  ok "draft_save: mkdir failure emits a one-line diagnostic to stderr"
else
  no "draft_save: mkdir failure produced no diagnostic: $SAVE_ERR"
fi

# --- clear: removes the scratch file (idempotent) ---------------------------

sti_draft_clear "$DRAFT"
if [ -f "$DRAFT" ]; then
  no "draft_clear: scratch file still present after clear"
else
  ok "draft_clear: removes the scratch file"
fi
if sti_draft_clear "$DRAFT"; then
  ok "draft_clear: idempotent (no error when already gone)"
else
  no "draft_clear: errored on an already-absent file"
fi

# --- find: resume detection matches only the same slug ----------------------

FDIR="$TMP/find-stride"
mkdir -p "$FDIR"
sti_draft_save "$(sti_draft_path "$FDIR" 2026-05-12T100000 alpha)" "alpha draft body"
sti_draft_save "$(sti_draft_path "$FDIR" 2026-05-12T110000 beta)"  "beta draft body"
: > "$(sti_draft_path "$FDIR" 2026-05-12T120000 gamma)"   # empty -> ignored

assert_eq "draft_find: returns the matching-slug draft only (two slugs in flight)" \
  "$(sti_draft_find "$FDIR" alpha)" \
  "$FDIR/2026-05-12T100000-alpha-draft.md"

sti_draft_save "$(sti_draft_path "$FDIR" 2026-05-12T130000 oauth)" "oauth body"
NOAUTH="$(sti_draft_find "$FDIR" auth 2>/dev/null || true)"
if [ -z "$NOAUTH" ]; then
  ok "draft_find: slug 'auth' does not match 'oauth' (dash-delimited suffix)"
else
  no "draft_find: 'auth' cross-matched a different slug: $NOAUTH"
fi

NONE="$(sti_draft_find "$FDIR" does-not-exist 2>/dev/null || true)"
if [ -z "$NONE" ]; then
  ok "draft_find: no matching draft -> empty stdout + non-zero (fresh session)"
else
  no "draft_find: leaked output for a slug with no draft: $NONE"
fi

EMPTY_ONLY="$(sti_draft_find "$FDIR" gamma 2>/dev/null || true)"
if [ -z "$EMPTY_ONLY" ]; then
  ok "draft_find: an empty-only draft is not offered for resume (partial -> fresh)"
else
  no "draft_find: offered an empty draft for resume: $EMPTY_ONLY"
fi

sti_draft_save "$(sti_draft_path "$FDIR" 2026-05-12T090000 multi)" "older"
sti_draft_save "$(sti_draft_path "$FDIR" 2026-05-12T140000 multi)" "newer"
assert_eq "draft_find: latest ISO timestamp wins for a repeated slug" \
  "$(sti_draft_find "$FDIR" multi)" \
  "$FDIR/2026-05-12T140000-multi-draft.md"

ABS="$(sti_draft_find "$TMP/no-such-dir" anything 2>/dev/null || true)"
if [ -z "$ABS" ]; then
  ok "draft_find: absent scratch dir -> empty stdout + non-zero (no crash)"
else
  no "draft_find: leaked output for an absent dir: $ABS"
fi

# --- summary ----------------------------------------------------------------

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
