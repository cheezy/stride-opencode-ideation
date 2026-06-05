#!/usr/bin/env bash
# Unit tests for lib/validate_batch.py.
#
# Each test feeds a fixture JSON document to the validator and asserts the
# expected outcome (zero exit + no output for valid docs; non-zero exit with
# a matching error substring for invalid docs).
#
# Run:
#   ./lib/test-validate-batch.sh
#
# Exits 0 on success, non-zero on failure. Prints one-line per-test status.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VALIDATOR="${SCRIPT_DIR}/validate_batch.py"

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

assert_ok() {
  # Validator must exit 0 with no stderr output.
  local label="$1"
  local fixture="$2"
  local stderr
  if stderr="$(python3 "$VALIDATOR" "$fixture" 2>&1 >/dev/null)"; then
    if [ -z "$stderr" ]; then
      PASS=$(( PASS + 1 ))
      printf 'PASS  %s\n' "$label"
    else
      FAIL=$(( FAIL + 1 ))
      printf 'FAIL  %s\n      unexpected stderr: %s\n' "$label" "$stderr"
    fi
  else
    FAIL=$(( FAIL + 1 ))
    printf 'FAIL  %s\n      exit code != 0; stderr: %s\n' "$label" "$stderr"
  fi
}

assert_fails_with() {
  # Validator must exit non-zero AND stderr must contain the substring.
  local label="$1"
  local fixture="$2"
  local needle="$3"
  local stderr
  if stderr="$(python3 "$VALIDATOR" "$fixture" 2>&1 >/dev/null)"; then
    FAIL=$(( FAIL + 1 ))
    printf 'FAIL  %s\n      expected exit != 0 but got 0\n' "$label"
    return
  fi
  if printf '%s' "$stderr" | grep -Fq "$needle"; then
    PASS=$(( PASS + 1 ))
    printf 'PASS  %s\n' "$label"
  else
    FAIL=$(( FAIL + 1 ))
    printf 'FAIL  %s\n      expected substring: %s\n      actual stderr:      %s\n' \
      "$label" "$needle" "$stderr"
  fi
}

# --- (a) parse_error -------------------------------------------------------

cat > "$TMP/parse_error.json" <<'EOF'
{ this is not json
EOF
assert_fails_with "(a) parse error — invalid JSON exits with parse failure" \
  "$TMP/parse_error.json" \
  "JSON parse failed"

# --- (b) wrong_root_key ----------------------------------------------------

cat > "$TMP/wrong_root_tasks.json" <<'EOF'
{"tasks": [{"title": "x"}]}
EOF
assert_fails_with "(b) wrong root key 'tasks' — dedicated error message" \
  "$TMP/wrong_root_tasks.json" \
  "root key 'tasks' is the most common batch-API mistake"

cat > "$TMP/wrong_root_batch.json" <<'EOF'
{"batch": []}
EOF
assert_fails_with "(b) wrong root key 'batch' — named in error" \
  "$TMP/wrong_root_batch.json" \
  "missing the required 'goals' array"

# --- (c) empty_goals -------------------------------------------------------

cat > "$TMP/empty_goals.json" <<'EOF'
{"goals": []}
EOF
assert_fails_with "(c) empty goals array exits with under-specification hint" \
  "$TMP/empty_goals.json" \
  "empty array"

cat > "$TMP/goals_not_array.json" <<'EOF'
{"goals": {"title": "oops"}}
EOF
assert_fails_with "(c) goals as object — must be an array" \
  "$TMP/goals_not_array.json" \
  "must be an array"

# --- (d) goal_missing_field ------------------------------------------------

cat > "$TMP/missing_title.json" <<'EOF'
{"goals": [{"type": "goal", "tasks": []}]}
EOF
assert_fails_with "(d) goal missing title — names the field" \
  "$TMP/missing_title.json" \
  "goals[0] is missing required field 'title'"

cat > "$TMP/missing_tasks.json" <<'EOF'
{"goals": [{"title": "T", "type": "goal"}]}
EOF
assert_fails_with "(d) goal missing tasks — names the field" \
  "$TMP/missing_tasks.json" \
  "goals[0] is missing required field 'tasks'"

cat > "$TMP/empty_tasks.json" <<'EOF'
{"goals": [{"title": "T", "type": "goal", "tasks": []}]}
EOF
assert_fails_with "(d) goal with empty tasks array fails" \
  "$TMP/empty_tasks.json" \
  "goals[0].tasks is empty"

# --- (e) bad_dependency_index ---------------------------------------------

cat > "$TMP/dep_out_of_range.json" <<'EOF'
{
  "goals": [
    {
      "title": "Test goal",
      "type": "goal",
      "tasks": [
        {"title": "First", "type": "work", "dependencies": []},
        {"title": "Second", "type": "work", "dependencies": [5]}
      ]
    }
  ]
}
EOF
assert_fails_with "(e) dependency index out of range — names the failing path" \
  "$TMP/dep_out_of_range.json" \
  "goals[0].tasks[1].dependencies references index 5 but goal only has 2 tasks"

cat > "$TMP/dep_forward_ref.json" <<'EOF'
{
  "goals": [
    {
      "title": "Test goal",
      "type": "goal",
      "tasks": [
        {"title": "First", "type": "work", "dependencies": [1]},
        {"title": "Second", "type": "work", "dependencies": []}
      ]
    }
  ]
}
EOF
assert_fails_with "(e) forward-reference dependency fails" \
  "$TMP/dep_forward_ref.json" \
  "must point to an earlier sibling"

cat > "$TMP/dep_self_ref.json" <<'EOF'
{
  "goals": [
    {
      "title": "Test goal",
      "type": "goal",
      "tasks": [
        {"title": "First", "type": "work", "dependencies": [0]}
      ]
    }
  ]
}
EOF
assert_fails_with "(e) self-reference dependency fails" \
  "$TMP/dep_self_ref.json" \
  "must point to an earlier sibling"

cat > "$TMP/dep_negative.json" <<'EOF'
{
  "goals": [
    {
      "title": "Test goal",
      "type": "goal",
      "tasks": [
        {"title": "First", "type": "work", "dependencies": [-1]}
      ]
    }
  ]
}
EOF
assert_fails_with "(e) negative dependency index fails" \
  "$TMP/dep_negative.json" \
  "is negative"

# --- happy paths -----------------------------------------------------------

cat > "$TMP/valid_minimal.json" <<'EOF'
{
  "decomposition_notes": "Single goal; no cross-goal deps.",
  "goals": [
    {
      "title": "Minimal goal",
      "type": "goal",
      "tasks": [
        {"title": "First task", "type": "work", "dependencies": []}
      ]
    }
  ]
}
EOF
assert_ok "valid minimal document with one goal and one task" \
  "$TMP/valid_minimal.json"

cat > "$TMP/valid_chained_deps.json" <<'EOF'
{
  "goals": [
    {
      "title": "Chained deps",
      "type": "goal",
      "tasks": [
        {"title": "First", "type": "work", "dependencies": []},
        {"title": "Second", "type": "work", "dependencies": [0]},
        {"title": "Third", "type": "work", "dependencies": [0, 1]}
      ]
    }
  ]
}
EOF
assert_ok "valid document with chained sibling dependencies" \
  "$TMP/valid_chained_deps.json"

cat > "$TMP/valid_string_dep.json" <<'EOF'
{
  "goals": [
    {
      "title": "String identifier dep",
      "type": "goal",
      "tasks": [
        {"title": "First", "type": "work", "dependencies": ["W47"]}
      ]
    }
  ]
}
EOF
assert_ok "valid: string identifier dependencies are not bounds-checked" \
  "$TMP/valid_string_dep.json"

# --- summary --------------------------------------------------------------

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
