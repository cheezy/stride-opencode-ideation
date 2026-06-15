#!/usr/bin/env bash
# Tests for the /ideate --input <file> brain-dump seed
# documented in commands/ideate.md (W1158; ports upstream G235/W1137). The platform
# file-read / question UI is only available inside a live OpenCode session,
# so this test embeds reference shell implementations of the documented Step 1
# --input parse, the file-exists validation, and the Step 4c read-only
# invariant, and exercises them.
#
# The reference implementations MUST stay consistent with Step 1 (the --input
# parse + validation) and Step 4c (the read-only seed read) in
# commands/ideate.md, and with the PowerShell mirror
# lib/test-ideate-input.ps1. If you edit one, edit all.
#
# Run:
#   ./lib/test-ideate-input.sh
#
# Exits 0 if all tests pass, non-zero otherwise.

set -u

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

pass() { PASS=$(( PASS + 1 )); printf 'PASS  %s\n' "$1"; }
fail() {
  FAIL=$(( FAIL + 1 ))
  printf 'FAIL  %s\n' "$1"
  if [ "${2:-}" != "" ]; then
    printf '      %s\n' "$2"
  fi
}

# --- reference flag parser -------------------------------------------------
#
# Mirrors commands/ideate.md Step 1: parse --continue and --input (each in both
# `--flag <value>` and `--flag=<value>` forms), consuming their tokens;
# everything left over is the TOPIC remainder. Prints three lines:
#   line 1 = CONTINUE_PATH, line 2 = INPUT_PATH, line 3 = trimmed remainder.

parse_flags() {
  local args="$1"
  local continue_path="" input_path="" out=""
  # shellcheck disable=SC2206
  local toks=( $args )
  local n=${#toks[@]} i=0
  while [ "$i" -lt "$n" ]; do
    local t="${toks[$i]}"
    case "$t" in
      --continue)
        i=$(( i + 1 ))
        if [ "$i" -lt "$n" ]; then continue_path="${toks[$i]}"; fi
        ;;
      --continue=*)
        continue_path="${t#--continue=}"
        ;;
      --input)
        i=$(( i + 1 ))
        if [ "$i" -lt "$n" ]; then input_path="${toks[$i]}"; fi
        ;;
      --input=*)
        input_path="${t#--input=}"
        ;;
      *)
        out="${out:+$out }$t"
        ;;
    esac
    i=$(( i + 1 ))
  done
  printf '%s\n%s\n%s\n' "$continue_path" "$input_path" "$out"
}

# --- reference --input validation ------------------------------------------
#
# Mirrors commands/ideate.md Step 1's INPUT_PATH existence check: unset is OK (no seed);
# a set-but-missing path is a one-line error + non-zero stop; an existing
# regular file is OK.

validate_input_path() {
  local path="$1"
  if [ -z "$path" ]; then
    return 0
  fi
  if [ ! -f "$path" ]; then
    echo "stride-ideation: --input file not found: $path" >&2
    return 1
  fi
  return 0
}

# --- reference read-only seed read -----------------------------------------
#
# Mirrors commands/ideate.md Step 4c: read the file read-only into a variable. It MUST
# NOT write, move, or modify the file in any way.

read_input_notes() {
  local path="$1"
  if [ -z "$path" ]; then
    printf ''
    return 0
  fi
  cat "$path"
}

# === fixtures ==============================================================

NOTES="$TMP/notes.md"
cat > "$NOTES" <<'EOF'
# Rough notes

We want a daily digest so approvers stop missing requests.
Assume people read email. SMTP relay is fine.
EOF
NOTES_SHA_BEFORE="$(shasum -a 256 "$NOTES" | awk '{print $1}')"

PRIOR="$TMP/2026-05-12T120000-thing-requirements.md"
cat > "$PRIOR" <<'EOF'
# Thing — requirements
## Goal
Ship the thing.
EOF

EMPTY_NOTES="$TMP/empty.md"
: > "$EMPTY_NOTES"

# === case 1: --input <path> and --input=<path> both parse =================

p_space="$(parse_flags "--input $NOTES my topic here")"
p_equals="$(parse_flags "--input=$NOTES my topic here")"

if [ "$(printf '%s' "$p_space" | sed -n 2p)" = "$NOTES" ] \
   && [ "$(printf '%s' "$p_equals" | sed -n 2p)" = "$NOTES" ]; then
  pass "case 1: --input <path> and --input=<path> both parse to INPUT_PATH (AC1)"
else
  fail "case 1: --input parse wrong" \
    "space=$(printf '%s' "$p_space" | sed -n 2p) equals=$(printf '%s' "$p_equals" | sed -n 2p)"
fi

if [ "$(printf '%s' "$p_space" | sed -n 3p)" = "my topic here" ] \
   && [ "$(printf '%s' "$p_equals" | sed -n 3p)" = "my topic here" ]; then
  pass "case 1: the --input tokens are consumed and the TOPIC remainder is preserved"
else
  fail "case 1: remainder wrong after --input consumption" \
    "space=$(printf '%s' "$p_space" | sed -n 3p) equals=$(printf '%s' "$p_equals" | sed -n 3p)"
fi

# === case 2: absence leaves INPUT_PATH empty, topic intact ================

p_none="$(parse_flags "just a plain topic")"
if [ -z "$(printf '%s' "$p_none" | sed -n 2p)" ] \
   && [ "$(printf '%s' "$p_none" | sed -n 3p)" = "just a plain topic" ]; then
  pass "case 2: no --input leaves INPUT_PATH empty and TOPIC intact"
else
  fail "case 2: absence handling wrong" "$(printf '%s' "$p_none" | tr '\n' '|')"
fi

# === case 3: validation — existing file OK, missing file errors (AC1) =====

if validate_input_path "$NOTES" 2>/dev/null; then
  pass "case 3: validate accepts an existing --input file (rc 0)"
else
  fail "case 3: validate rejected an existing file"
fi

if validate_input_path "$TMP/does-not-exist.md" 2>"$TMP/verr"; then
  fail "case 3: validate accepted a missing file (should fail)"
else
  if grep -qF -- "--input file not found: $TMP/does-not-exist.md" "$TMP/verr"; then
    pass "case 3: missing --input file -> one-line error naming the path + non-zero (edge case)"
  else
    fail "case 3: missing-file error message wrong" "$(cat "$TMP/verr")"
  fi
fi

# === case 4: unset INPUT_PATH validates OK (no seed) ======================

if validate_input_path "" 2>/dev/null; then
  pass "case 4: unset INPUT_PATH validates cleanly (no-seed session)"
else
  fail "case 4: unset INPUT_PATH was rejected"
fi

# === case 5: read is read-only — file byte-for-byte unchanged (AC3) =======

seed="$(read_input_notes "$NOTES")"
NOTES_SHA_AFTER="$(shasum -a 256 "$NOTES" | awk '{print $1}')"
if [ "$NOTES_SHA_BEFORE" = "$NOTES_SHA_AFTER" ]; then
  pass "case 5: --input file is byte-for-byte unchanged after the read (read-only invariant)"
else
  fail "case 5: --input file was modified by the read (pitfall violated)"
fi
if printf '%s' "$seed" | grep -qF "daily digest"; then
  pass "case 5: read_input_notes returns the file contents as seed material"
else
  fail "case 5: seed content not returned" "$seed"
fi
if [ -f "$NOTES" ]; then
  pass "case 5: --input file still exists at its original path (not moved)"
else
  fail "case 5: --input file was moved/removed (pitfall violated)"
fi

# === case 6: --input and --continue parse independently (precedence, AC4) ==

p_both="$(parse_flags "--continue $PRIOR --input $NOTES leftover topic")"
b_continue="$(printf '%s' "$p_both" | sed -n 1p)"
b_input="$(printf '%s' "$p_both" | sed -n 2p)"
b_rem="$(printf '%s' "$p_both" | sed -n 3p)"
if [ "$b_continue" = "$PRIOR" ] && [ "$b_input" = "$NOTES" ] && [ "$b_rem" = "leftover topic" ]; then
  pass "case 6: --continue and --input populate independently when both passed (AC4)"
else
  fail "case 6: combined parse wrong" \
    "continue=$b_continue input=$b_input rem=$b_rem"
fi

# === case 7: empty --input file is valid (falls back to a full session) ===

if validate_input_path "$EMPTY_NOTES" 2>/dev/null; then
  empty_seed="$(read_input_notes "$EMPTY_NOTES")"
  if [ -z "$empty_seed" ]; then
    pass "case 7: empty --input file validates and yields empty seed (full session fallback, edge case)"
  else
    fail "case 7: empty file produced non-empty seed" "$empty_seed"
  fi
else
  fail "case 7: empty --input file was rejected by validation"
fi

# === summary ==============================================================

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
