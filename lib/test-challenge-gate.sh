#!/usr/bin/env bash
# Tests for the challenge-gate output shape documented in
# skills/stride-ideation/SKILL.md ("Challenge gate") and wired into
# commands/ideate.md (the Step-6 "## Design challenge" template). The gate is
# an interactive question step — surfaced through OpenCode's question UI — that
# cannot be driven from a non-interactive runner, so this test asserts the
# *output contract* — the shape a committed requirements doc must exhibit once
# the gate has run — against the committed fixture
# fixtures/2026-05-12T120300-saved-filters-challenge-gate-requirements.md.
#
# The shape assertions below MUST stay consistent with the "Challenge gate"
# section of SKILL.md and the Step-6 "## Design challenge" template in
# commands/ideate.md. If you change the documented gate output, update this
# test and the fixture together — this test exists to catch drift between the
# documented contract and a real example of its output.
#
# Run:
#   ./lib/test-challenge-gate.sh
#
# Exits 0 if all tests pass, non-zero otherwise. No network, no external deps.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
FIXTURE="${PLUGIN_ROOT}/fixtures/2026-05-12T120300-saved-filters-challenge-gate-requirements.md"

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

# --- reference shape assertions --------------------------------------------
#
# Each returns 0 when the supplied requirements-doc file exhibits the gate
# output shape, non-zero otherwise. Pure grep/awk — no external deps.

# A "## Design challenge" H2 section is present.
gate_has_design_challenge_section() {
  grep -qE '^## Design challenge[[:space:]]*$' "$1"
}

# The Design challenge section names at least two distinct alternatives.
gate_has_two_alternatives() {
  local count
  count="$(grep -cE '\*\*Alternative [A-Z]' "$1")"
  [ "$count" -ge 2 ]
}

# The trade-off comparison covers all four dimensions: cost, risk,
# complexity, timeline (case-insensitive). Scoped to the trade-off TABLE —
# each dimension must appear as the first cell of a table row (e.g.
# "| Cost | ... |"), not merely somewhere in the prose. This prevents the
# check from passing on a doc that mentions the words but dropped the table.
gate_has_trade_off_dimensions() {
  local f="$1" dim
  for dim in Cost Risk Complexity Timeline; do
    if ! grep -qiE "^[[:space:]]*\|[[:space:]]*${dim}[[:space:]]*\|" "$f"; then
      return 1
    fi
  done
  return 0
}

# The Assumptions section carries at least one (high)/(medium)/(low)
# confidence rating produced by the assumption-confidence audit.
gate_has_confidence_ratings() {
  awk '
    /^## Assumptions[[:space:]]*$/ { in_a = 1; next }
    /^## / && in_a { in_a = 0 }
    in_a && /\((high|medium|low)\)/ { found = 1 }
    END { exit(found ? 0 : 1) }
  ' "$1"
}

# === case 0: the fixture exists ===========================================

if [ -f "$FIXTURE" ]; then
  pass "case 0: challenge-gate fixture exists at fixtures/$(basename "$FIXTURE")"
else
  fail "case 0: challenge-gate fixture missing" "$FIXTURE"
  printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
  exit 1
fi

# === case 1: Design challenge section present (AC1) ========================

if gate_has_design_challenge_section "$FIXTURE"; then
  pass "case 1: fixture has a '## Design challenge' section"
else
  fail "case 1: fixture is missing the '## Design challenge' section"
fi

# === case 2: two alternatives (AC1) =======================================

if gate_has_two_alternatives "$FIXTURE"; then
  pass "case 2: Design challenge names at least two alternatives"
else
  fail "case 2: fewer than two alternatives in the fixture"
fi

# === case 3: trade-off covers cost/risk/complexity/timeline (AC1) =========

if gate_has_trade_off_dimensions "$FIXTURE"; then
  pass "case 3: trade-off comparison covers cost, risk, complexity, and timeline"
else
  fail "case 3: trade-off comparison is missing one of the four dimensions"
fi

# === case 4: Assumptions carry confidence ratings (AC2) ===================

if gate_has_confidence_ratings "$FIXTURE"; then
  pass "case 4: Assumptions section shows per-assumption confidence ratings"
else
  fail "case 4: no (high)/(medium)/(low) confidence ratings under Assumptions"
fi

# === case 5: negative control — a doc with no alternatives must FAIL =======
# (testing_strategy edge case: "A fixture with no alternatives should fail
#  the new assertion".) This guards against an assertion that vacuously
#  passes on any input.

NO_ALTS="$TMP/no-alternatives-requirements.md"
cat > "$NO_ALTS" <<'EOF'
# Bad fixture — gate output without alternatives

## Assumptions
- Users want this (R) (low)

## Design challenge
- **Blind spots:** we never considered the support team.
- **Trade-off comparison:** cost, risk, complexity, timeline — but no alternatives to compare against.
EOF

if gate_has_two_alternatives "$NO_ALTS"; then
  fail "case 5: two-alternatives assertion wrongly passed a doc with no alternatives"
else
  pass "case 5: two-alternatives assertion correctly fails a doc with no alternatives (negative control)"
fi

# === case 6: negative control — a doc with no confidence ratings must FAIL =

NO_CONF="$TMP/no-confidence-requirements.md"
cat > "$NO_CONF" <<'EOF'
# Bad fixture — assumptions without confidence ratings

## Assumptions
- Users want this (R)
- Storage is cheap

## Constraints
- Reuse existing storage (low effort)
EOF

if gate_has_confidence_ratings "$NO_CONF"; then
  fail "case 6: confidence-rating assertion wrongly passed unrated Assumptions" \
    "the '(low effort)' under Constraints must not be mistaken for an Assumptions rating"
else
  pass "case 6: confidence-rating assertion correctly fails unrated Assumptions, scoped to the Assumptions section (negative control)"
fi

# === case 7: negative control — prose dimensions but no table must FAIL ====
# Guards the trade-off check against a vacuous pass: a doc that name-drops
# cost/risk/complexity/timeline in prose but has no comparison table must not
# satisfy gate_has_trade_off_dimensions.

NO_TABLE="$TMP/no-trade-off-table-requirements.md"
cat > "$NO_TABLE" <<'EOF'
# Bad fixture — trade-off words in prose, no table

## Assumptions
- Users want this (R) (low)

## Design challenge
- **Alternative A:** do it one way.
- **Alternative B:** do it another way.
- **Trade-off comparison:** we weighed cost, risk, complexity, and timeline in our heads but never tabulated them.
EOF

if gate_has_trade_off_dimensions "$NO_TABLE"; then
  fail "case 7: trade-off-dimensions assertion wrongly passed prose-only dimensions with no table"
else
  pass "case 7: trade-off-dimensions assertion correctly fails when the comparison table is absent (negative control)"
fi

# === summary ==============================================================

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
