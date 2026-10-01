#!/usr/bin/env bash
# Tests for lib/check_sections.py — the /stridify Step 2.3
# gate that every requirements doc carries the seven hard-gated sections.
#
# Run:
#   ./lib/test-check-sections.sh
#
# Exits 0 if all tests pass, non-zero otherwise.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
CHECK="${SCRIPT_DIR}/check_sections.py"

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

# run_check <doc> — leaves RC, OUT and ERR.
run_check() {
  python3 "$CHECK" "$1" > "$TMP/out" 2> "$TMP/err"
  RC=$?
  OUT="$(cat "$TMP/out")"
  ERR="$(cat "$TMP/err")"
}

assert_ok() {
  run_check "$2"
  if [ "$RC" -eq 0 ] && [ -z "$OUT$ERR" ]; then pass "$1"; else fail "$1" "rc=$RC out=$OUT err=$ERR"; fi
}

assert_missing() {  # assert_missing <label> <doc> <expected comma list>
  run_check "$2"
  local want="stride-ideation: requirements doc is missing required section(s): $3"
  if [ "$RC" -eq 1 ] && [ "$ERR" = "$want" ]; then pass "$1"; else fail "$1" "rc=$RC err=$ERR"; fi
}

# doc <file> <heading>... — a doc with one level-2 heading per argument.
doc() {
  local f="$1"
  shift
  { printf '# Topic\n\n'
    for h in "$@"; do printf '## %s\n\nbody\n\n' "$h"; done
  } > "$f"
}

# --- all seven present ---------------------------------------------------------

doc "$TMP/template.md" Problem Goal "Success metrics" Assumptions Constraints Non-goals Outcome
assert_ok "all seven (template spelling 'Success metrics') pass with no output" "$TMP/template.md"

doc "$TMP/titlecase.md" Goal Problem Outcome Assumptions Constraints Non-Goals "Success Metrics"
assert_ok "title-case 'Success Metrics' / 'Non-Goals' pass (case-insensitive)" "$TMP/titlecase.md"

doc "$TMP/trailing.md" "Problem  " "Goal	" Outcome Assumptions Constraints Non-goals "Success metrics   "
assert_ok "headings with trailing spaces or tabs pass" "$TMP/trailing.md"

for f in "${PLUGIN_ROOT}"/fixtures/*-requirements.md; do
  assert_ok "fixture passes: $(basename "$f")" "$f"
done

# --- missing sections ------------------------------------------------------------

doc "$TMP/missing-two.md" Problem Goal Assumptions Constraints Non-goals
assert_missing "lists every missing section, in canonical order" "$TMP/missing-two.md" "Outcome, Success metrics"

doc "$TMP/none.md"
assert_missing "an empty doc lists all seven" "$TMP/none.md" \
  "Problem, Goal, Outcome, Assumptions, Constraints, Non-goals, Success metrics"

# Level-3 headings do not count.
{ printf '# Topic\n\n'
  for h in Problem Goal Outcome Assumptions Constraints Non-goals; do printf '## %s\n\nx\n\n' "$h"; done
  printf '### Success metrics\n\nx\n'
} > "$TMP/h3.md"
assert_missing "a level-3 heading does not satisfy a section" "$TMP/h3.md" "Success metrics"

# Headings inside code fences do not count (``` and ~~~).
{ printf '# Topic\n\n'
  for h in Problem Goal Outcome Assumptions Constraints; do printf '## %s\n\nx\n\n' "$h"; done
  printf '```markdown\n## Non-goals\n```\n\n~~~\n## Success metrics\n~~~\n'
} > "$TMP/fenced.md"
assert_missing "headings inside code fences do not count" "$TMP/fenced.md" "Non-goals, Success metrics"

# A shorter fence inside a longer one does not close it (CommonMark).
{ printf '# Topic\n\n'
  for h in Problem Goal Outcome Assumptions Constraints Non-goals; do printf '## %s\n\nx\n\n' "$h"; done
  printf '````markdown\nexample:\n```\n## Success metrics\n```\n````\n'
} > "$TMP/nested-fence.md"
assert_missing "a heading inside a nested fence does not count" "$TMP/nested-fence.md" "Success metrics"

# A section name that only appears in prose does not count.
{ printf '# Topic\n\nOur Success metrics are below. Non-goals: none.\n\n'
  for h in Problem Goal Outcome Assumptions Constraints; do printf '## %s\n\nx\n\n' "$h"; done
} > "$TMP/prose.md"
assert_missing "a section name in prose is not a heading" "$TMP/prose.md" "Non-goals, Success metrics"

# --- usage and I/O -----------------------------------------------------------------

python3 "$CHECK" > /dev/null 2>&1
if [ "$?" -eq 2 ]; then pass "no argument is a usage error (exit 2)"; else fail "usage exit code"; fi

run_check "$TMP/does-not-exist.md"
if [ "$RC" -eq 1 ] && printf '%s' "$ERR" | grep -q '^stride-ideation: could not read'; then
  pass "an unreadable path exits 1 with a stride-ideation: message"
else
  fail "unreadable path" "rc=$RC err=$ERR"
fi

# Read-only: the doc is byte-identical after a check.
cp "$TMP/missing-two.md" "$TMP/before.md"
run_check "$TMP/missing-two.md"
if cmp -s "$TMP/before.md" "$TMP/missing-two.md"; then pass "the doc is never modified"; else fail "the doc was modified"; fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
