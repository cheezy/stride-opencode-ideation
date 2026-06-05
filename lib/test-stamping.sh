#!/usr/bin/env bash
# Unit tests for the source_spec / source_spec_sha256 stamping logic used by
# /stride-ideation:decompose.
#
# The stamping itself runs inside the slash-command body (commands/decompose.md
# Step 5 + Step 8), but the two failure-mode behaviors the AC calls out are
# testable in isolation:
#
#   1. The recorded SHA matches `shasum -a 256` of the supplied requirements
#      doc (canonical constant for a known fixture).
#   2. The lowercasing pipeline preserves expected hex (tr 'A-Z' 'a-z').
#
# Run:
#   ./lib/test-stamping.sh
#
# Exits 0 on success, non-zero on failure.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

PASS=0
FAIL=0

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

# --- canonical SHA for a known fixture ------------------------------------
#
# This SHA is the recorded constant for the dark-mode-toggle requirements
# fixture authored in W410. If you intentionally edit that fixture, recompute
# the SHA with `shasum -a 256 <path>` and update this constant in the same
# commit. Drift between this constant and the file's actual SHA means either
# (a) the fixture changed and the constant is stale, or (b) something in the
# hashing pipeline regressed and the recorded SHA no longer matches reality.

FIXTURE_PATH="${REPO_ROOT}/fixtures/2026-05-12T120000-dark-mode-toggle-requirements.md"
FIXTURE_EXPECTED_SHA="d34c559d08931f1ff1e60fcb6205def5fa6e5cc7a771bccf1885aa9813a40674"

if [ ! -f "$FIXTURE_PATH" ]; then
  FAIL=$(( FAIL + 1 ))
  printf 'FAIL  fixture path missing: %s\n' "$FIXTURE_PATH"
else
  FIXTURE_ACTUAL_SHA="$(shasum -a 256 "$FIXTURE_PATH" | awk '{print $1}' | tr 'A-Z' 'a-z')"
  assert_eq "fixture SHA matches the recorded constant" \
    "$FIXTURE_ACTUAL_SHA" \
    "$FIXTURE_EXPECTED_SHA"
fi

# --- lowercasing of hex output --------------------------------------------
#
# The stamping pipeline pipes shasum's output through `tr 'A-Z' 'a-z'` to force
# lowercase hex so /ship's drift check compares byte-for-byte. Validate that
# the lowercasing actually happens.

UPPER_HEX_SAMPLE="ABCDEF0123456789"
LOWER_HEX_EXPECTED="abcdef0123456789"
assert_eq "tr 'A-Z' 'a-z' lowercases hex" \
  "$(printf '%s' "$UPPER_HEX_SAMPLE" | tr 'A-Z' 'a-z')" \
  "$LOWER_HEX_EXPECTED"

# --- mixed-case hex roundtrip ---------------------------------------------
#
# A platform whose shasum returns mixed-case digits (rare, but observed on
# some BSD variants) should still produce a fully-lowercased value.

MIXED_HEX_SAMPLE="aBcDeF0123456789AbCdEf"
LOWER_MIXED_EXPECTED="abcdef0123456789abcdef"
assert_eq "mixed-case hex collapses to fully lowercase" \
  "$(printf '%s' "$MIXED_HEX_SAMPLE" | tr 'A-Z' 'a-z')" \
  "$LOWER_MIXED_EXPECTED"

# --- summary --------------------------------------------------------------

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
