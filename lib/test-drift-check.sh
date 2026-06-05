#!/usr/bin/env bash
# Unit tests for lib/drift_check.py.
#
# Run:
#   ./lib/test-drift-check.sh
#
# Exits 0 if all tests pass, non-zero otherwise.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DRIFT="${SCRIPT_DIR}/drift_check.py"

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
fail_msg() {
  FAIL=$(( FAIL + 1 ))
  printf 'FAIL  %s\n' "$1"
  if [ "${2:-}" != "" ]; then printf '      %s\n' "$2"; fi
}

assert_exit() {
  # assert_exit <label> <fixture> <expected-exit>
  local label="$1"
  local fixture="$2"
  local expected="$3"
  python3 "$DRIFT" "$fixture" >/dev/null 2>"$TMP/last.err"
  local actual=$?
  if [ "$actual" = "$expected" ]; then
    pass "$label"
  else
    fail_msg "$label" "expected exit $expected, got $actual; stderr: $(cat "$TMP/last.err")"
  fi
}

assert_exit_with_msg() {
  # assert_exit_with_msg <label> <fixture> <expected-exit> <stderr-substring>
  local label="$1"
  local fixture="$2"
  local expected="$3"
  local needle="$4"
  python3 "$DRIFT" "$fixture" >/dev/null 2>"$TMP/last.err"
  local actual=$?
  if [ "$actual" != "$expected" ]; then
    fail_msg "$label" "expected exit $expected, got $actual; stderr: $(cat "$TMP/last.err")"
    return
  fi
  if grep -Fq "$needle" "$TMP/last.err"; then
    pass "$label"
  else
    fail_msg "$label" "expected substring: $needle; actual stderr: $(cat "$TMP/last.err")"
  fi
}

# --- fixture: a known source doc + its real SHA -----------------------------

cat > "$TMP/requirements.md" <<'EOF'
# Fake requirements doc

## Problem
test
EOF

REAL_SHA="$(shasum -a 256 "$TMP/requirements.md" | awk '{print $1}' | tr 'A-Z' 'a-z')"

# --- no drift: matching SHA ------------------------------------------------

cat > "$TMP/no_drift.json" <<EOF
{
  "source_spec": "requirements.md",
  "source_spec_sha256": "${REAL_SHA}",
  "decomposition_notes": "",
  "goals": [{"title": "G", "type": "goal", "tasks": [{"title": "T", "type": "work"}]}]
}
EOF
assert_exit "no drift: matching SHA exits 0 silently" "$TMP/no_drift.json" 0

# Verify stderr is empty on no-drift
if [ -s "$TMP/last.err" ]; then
  fail_msg "no drift: stderr should be empty" "$(cat "$TMP/last.err")"
else
  pass "no drift: stderr is empty"
fi

# --- drift: mismatched SHA -------------------------------------------------

cat > "$TMP/drift.json" <<EOF
{
  "source_spec": "requirements.md",
  "source_spec_sha256": "0000000000000000000000000000000000000000000000000000000000000000",
  "decomposition_notes": "",
  "goals": [{"title": "G", "type": "goal", "tasks": [{"title": "T", "type": "work"}]}]
}
EOF
assert_exit_with_msg "drift: mismatched SHA exits 1 with DRIFT DETECTED message" \
  "$TMP/drift.json" 1 "DRIFT DETECTED"

# --- drift: stderr names both stamped and recomputed SHA -------------------

if grep -Fq "stamped SHA-256:" "$TMP/last.err" && grep -Fq "recomputed SHA-256:" "$TMP/last.err"; then
  pass "drift: stderr names both stamped and recomputed SHA values"
else
  fail_msg "drift: stderr missing stamped/recomputed labels" "$(cat "$TMP/last.err")"
fi

# --- absent source_spec: hand-written-JSON path proceeds silently -----------

cat > "$TMP/no_source_spec.json" <<'EOF'
{"goals": [{"title": "G", "type": "goal", "tasks": [{"title": "T", "type": "work"}]}]}
EOF
assert_exit "absent source_spec: exits 0 (hand-written path)" "$TMP/no_source_spec.json" 0
if [ -s "$TMP/last.err" ]; then
  fail_msg "absent source_spec: stderr should be empty" "$(cat "$TMP/last.err")"
else
  pass "absent source_spec: stderr is empty"
fi

# --- present source_spec but absent SHA: proceed silently -------------------

cat > "$TMP/no_sha.json" <<'EOF'
{
  "source_spec": "requirements.md",
  "goals": [{"title": "G", "type": "goal", "tasks": [{"title": "T", "type": "work"}]}]
}
EOF
assert_exit "source_spec present but SHA absent: exits 0 (no baseline)" \
  "$TMP/no_sha.json" 0

# --- source_spec points at a missing file ----------------------------------

cat > "$TMP/missing_source.json" <<'EOF'
{
  "source_spec": "does_not_exist.md",
  "source_spec_sha256": "abcdef",
  "goals": [{"title": "G", "type": "goal", "tasks": [{"title": "T", "type": "work"}]}]
}
EOF
assert_exit_with_msg "missing source_spec file: exits 2 with resolution error" \
  "$TMP/missing_source.json" 2 "could not be resolved"

# --- malformed batch JSON itself --------------------------------------------

cat > "$TMP/bad.json" <<'EOF'
not json
EOF
assert_exit_with_msg "malformed batch JSON: exits 2 with read/parse error" \
  "$TMP/bad.json" 2 "could not read batch JSON"

# --- source_spec given as absolute path -------------------------------------

cat > "$TMP/abs_source.json" <<EOF
{
  "source_spec": "${TMP}/requirements.md",
  "source_spec_sha256": "${REAL_SHA}",
  "goals": [{"title": "G", "type": "goal", "tasks": [{"title": "T", "type": "work"}]}]
}
EOF
assert_exit "absolute source_spec path resolves correctly" "$TMP/abs_source.json" 0

# --- summary ----------------------------------------------------------------

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
