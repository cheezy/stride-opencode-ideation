#!/usr/bin/env bash
# Tests for the /stride-ideation:stridify --goal flag (W714):
#
#   - sti_extract_seams      parses ## Decomposition seams sections
#   - sti_resolve_goal       resolves --goal <name|index> against extracted seams
#   - sti_scope_doc_to_seam  prunes the seams section to a single matched item
#
# These three helpers live in lib/filename.sh; this file tests them directly
# (no embedded reference implementation — unlike test-stridify-retry.sh,
# the logic IS in the helper, not pseudo-code in the markdown).
#
# Cases also exercise the documented behavior of the wrapping logic in
# commands/stridify.md Step 1 (argument parsing) and Step 5 (target-path
# slug composition) via small reference shell snippets embedded below.
#
# Run:
#   ./lib/test-stridify-per-goal.sh
#
# Exits 0 if all tests pass, non-zero otherwise.

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

pass() { PASS=$(( PASS + 1 )); printf 'PASS  %s\n' "$1"; }
fail() {
  FAIL=$(( FAIL + 1 ))
  printf 'FAIL  %s\n' "$1"
  if [ "${2:-}" != "" ]; then
    printf '      %s\n' "$2"
  fi
}

# --- fixture: a realistic seven-surface requirements doc -------------------

cat > "$TMP/seven-surfaces.md" <<'EOF'
# Some Feature

## Problem

A description of the problem.

## Goal

The goal.

## Outcome

The outcome.

## Decomposition seams

**This document must be decomposed into seven independent goals.**

The seven surfaces:

1. **Kanban app** (this repo: `lib/kanban_web/...`) — defines the contract.
2. **stride plugin** (this repo: `stride/`) — reference workflow.
3. **stride-copilot** (separate repo) — Copilot CLI adapter.
4. **stride-gemini** (separate repo) — Gemini CLI adapter.
5. **stride-codex** (separate repo) — Codex adapter.
6. **stride-opencode** (separate repo) — OpenCode adapter.
7. **stride-pi** (separate repo) — Pi Coding Agent adapter.

## Assumptions

Assumptions go here.
EOF

# --- fixture: a doc WITHOUT a Decomposition seams section -----------------

cat > "$TMP/no-seams.md" <<'EOF'
# Some Feature

## Problem

Just one goal, no seams.

## Goal

A single goal.

## Outcome

Done.
EOF

# --- fixture: seams section present but the numbered list is empty -------

cat > "$TMP/empty-seams.md" <<'EOF'
# Some Feature

## Problem

Foo.

## Decomposition seams

This section was added but no surfaces have been enumerated yet.

## Outcome

Outcome.
EOF

# --- fixture: a doc whose item 2 has a multi-line body --------------------

cat > "$TMP/multiline-body.md" <<'EOF'
# Doc

## Decomposition seams

1. **First** — one-liner.
2. **Second** — line one of the body.
   Continuation line two.
   Continuation line three.
3. **Third** — back to one-liners.
EOF

# --- fixture: a doc with a seam literally named "1" -----------------------

cat > "$TMP/seam-named-one.md" <<'EOF'
# Doc

## Decomposition seams

1. **Alpha** — first surface.
2. **1** — second surface, literally named "1".
3. **Gamma** — third surface.
EOF

# --- fixture: items missing the **bold** marker --------------------------

cat > "$TMP/missing-bold.md" <<'EOF'
# Doc

## Decomposition seams

1. **Valid** — has bold name.
2. Plain Name — missing bold; should be skipped.
3. **Also valid** — has bold name.
EOF

# === case 1: --goal absent on a doc without seams stays in "all goals" ====

# Reference Step 1 parser: extract GOAL_ARG from $ARGUMENTS-style input.
# Mirrors commands/stridify.md Step 1.
parse_goal_arg() {
  # Stdout: <goal_arg> (possibly empty) followed by a NUL and then the trimmed remainder
  # Exit: 0 always; the caller decides whether GOAL_ARG=""
  local args="$1"
  local goal=""
  local rest=""
  # Tokenize into an array.
  read -r -a tokens <<<"$args"
  local i=0
  local out=()
  while [ "$i" -lt "${#tokens[@]}" ]; do
    local t="${tokens[$i]}"
    if [ "$t" = "--goal" ]; then
      i=$(( i + 1 ))
      goal="${tokens[$i]:-}"
      i=$(( i + 1 ))
      continue
    fi
    case "$t" in
      --goal=*)
        goal="${t#--goal=}"
        ;;
      *)
        out+=("$t")
        ;;
    esac
    i=$(( i + 1 ))
  done
  rest="${out[*]:-}"
  printf '%s\n%s' "$goal" "$rest"
}

case1_out="$(parse_goal_arg "/path/to/no-seams.md")"
case1_goal="$(printf '%s' "$case1_out" | head -n1)"
case1_rest="$(printf '%s' "$case1_out" | tail -n1)"
if [ -z "$case1_goal" ] && [ "$case1_rest" = "/path/to/no-seams.md" ]; then
  pass "case 1: --goal absent → empty GOAL_ARG, remainder is the path (AC8)"
else
  fail "case 1: parse with no flag" "goal='$case1_goal' rest='$case1_rest'"
fi

# === case 2: --goal "Kanban app" resolves to seam 1 by slug ===============

case2_out="$(sti_resolve_goal "$TMP/seven-surfaces.md" "Kanban app")"
case2_rc=$?
if [ "$case2_rc" = "0" ]; then
  case2_idx="$(printf '%s' "$case2_out" | awk -F'\t' '{print $1}')"
  case2_name="$(printf '%s' "$case2_out" | awk -F'\t' '{print $2}')"
  case2_slug="$(printf '%s' "$case2_out" | awk -F'\t' '{print $3}')"
  if [ "$case2_idx" = "1" ] && [ "$case2_name" = "Kanban app" ] && [ "$case2_slug" = "kanban-app" ]; then
    pass "case 2: --goal 'Kanban app' → index=1 name='Kanban app' slug=kanban-app (AC1, AC2)"
  else
    fail "case 2: wrong resolution" "idx=$case2_idx name='$case2_name' slug=$case2_slug"
  fi
else
  fail "case 2: sti_resolve_goal exited rc=$case2_rc (expected 0)"
fi

# === case 3: --goal 3 resolves to seam 3 by integer index =================

case3_out="$(sti_resolve_goal "$TMP/seven-surfaces.md" "3")"
if [ "$?" = "0" ]; then
  case3_idx="$(printf '%s' "$case3_out" | awk -F'\t' '{print $1}')"
  case3_slug="$(printf '%s' "$case3_out" | awk -F'\t' '{print $3}')"
  if [ "$case3_idx" = "3" ] && [ "$case3_slug" = "stride-copilot" ]; then
    pass "case 3: --goal 3 → integer-index resolves to stride-copilot (AC2)"
  else
    fail "case 3: wrong integer resolution" "idx=$case3_idx slug=$case3_slug"
  fi
else
  fail "case 3: sti_resolve_goal exited non-zero on integer arg"
fi

# === case 4: hyphenated slug resolves correctly ===========================

case4_out="$(sti_resolve_goal "$TMP/seven-surfaces.md" "stride-pi")"
if [ "$?" = "0" ]; then
  case4_idx="$(printf '%s' "$case4_out" | awk -F'\t' '{print $1}')"
  if [ "$case4_idx" = "7" ]; then
    pass "case 4: --goal stride-pi resolves to seam 7 (hyphenated slug, no integer collision)"
  else
    fail "case 4: hyphenated slug resolved to wrong index" "idx=$case4_idx"
  fi
else
  fail "case 4: sti_resolve_goal exited non-zero on hyphenated slug"
fi

# === case 5: --goal=<value> form parses identically =======================

case5a="$(parse_goal_arg "--goal kanban-app /path/to/doc.md" | head -n1)"
case5b="$(parse_goal_arg "--goal=kanban-app /path/to/doc.md" | head -n1)"
if [ "$case5a" = "kanban-app" ] && [ "$case5b" = "kanban-app" ]; then
  pass "case 5: --goal <v> and --goal=<v> parse to identical GOAL_ARG (AC1)"
else
  fail "case 5: dual-form parser disagrees" "form1='$case5a' form2='$case5b'"
fi

# === case 6: unresolved --goal errors with seam listing ===================

case6_out="$(sti_resolve_goal "$TMP/seven-surfaces.md" "nonexistent" 2>&1)"
case6_rc=$?
if [ "$case6_rc" = "3" ]; then
  pass "case 6: unresolved --goal returns rc=3 (AC4)"
else
  fail "case 6: expected rc=3, got rc=$case6_rc"
fi
# The CALLER prints the available-seams list; verify sti_extract_seams gives
# the data needed for that listing.
case6_seams="$(sti_extract_seams "$TMP/seven-surfaces.md")"
case6_count="$(printf '%s\n' "$case6_seams" | wc -l | tr -d ' ')"
if [ "$case6_count" = "7" ]; then
  pass "case 6: sti_extract_seams returns 7 seams for the listing (AC4 evidence)"
else
  fail "case 6: expected 7 seams, got $case6_count"
fi

# === case 7: absent seams section returns rc=2 ============================

if sti_resolve_goal "$TMP/no-seams.md" "anything" >/dev/null 2>&1; then
  fail "case 7: resolver returned 0 on doc without seams section"
else
  rc7=$?
  if [ "$rc7" = "2" ]; then
    pass "case 7: doc without seams section → rc=2 (AC3)"
  else
    fail "case 7: expected rc=2 got rc=$rc7"
  fi
fi

# === case 8: empty seams section returns rc=4 =============================

if sti_resolve_goal "$TMP/empty-seams.md" "anything" >/dev/null 2>&1; then
  fail "case 8: resolver returned 0 on doc with empty seams list"
else
  rc8=$?
  if [ "$rc8" = "4" ]; then
    pass "case 8: empty seams list → rc=4 (testing_strategy edge)"
  else
    fail "case 8: expected rc=4 got rc=$rc8"
  fi
fi

# === case 9: path-suffix construction =====================================

# Reference Step 5 composition (matches commands/stridify.md Step 5).
SLUG_FOR_PATH_test() {
  local doc_slug="$1" goal_slug="${2:-}"
  if [ -n "$goal_slug" ]; then
    printf '%s' "${doc_slug}-${goal_slug}"
  else
    printf '%s' "$doc_slug"
  fi
}

target_no_goal="$(sti_unique_path "$TMP" "2026-05-15T210800" "$(SLUG_FOR_PATH_test review-queue-code-diffs)" stride-batch json)"
expected_no_goal="$TMP/2026-05-15T210800-review-queue-code-diffs-stride-batch.json"
if [ "$target_no_goal" = "$expected_no_goal" ]; then
  pass "case 9a: target path without --goal matches historical format (AC8)"
else
  fail "case 9a: target path mismatch" "got=$target_no_goal want=$expected_no_goal"
fi

target_with_goal="$(sti_unique_path "$TMP" "2026-05-15T210800" "$(SLUG_FOR_PATH_test review-queue-code-diffs kanban-app)" stride-batch json)"
expected_with_goal="$TMP/2026-05-15T210800-review-queue-code-diffs-kanban-app-stride-batch.json"
if [ "$target_with_goal" = "$expected_with_goal" ]; then
  pass "case 9b: target path with --goal embeds goal slug between doc-slug and artifact (AC6)"
else
  fail "case 9b: target path mismatch" "got=$target_with_goal want=$expected_with_goal"
fi

# === case 10: commit-message construction =================================

# Reference Step 8d commit-message composition.
commit_msg_test() {
  local doc_slug="$1" goal_slug="${2:-}"
  if [ -n "$goal_slug" ]; then
    printf 'stride-ideation: decomposition for %s goal %s' "$doc_slug" "$goal_slug"
  else
    printf 'stride-ideation: decomposition for %s' "$doc_slug"
  fi
}

m10a="$(commit_msg_test review-queue-code-diffs)"
m10b="$(commit_msg_test review-queue-code-diffs kanban-app)"
if [ "$m10a" = "stride-ideation: decomposition for review-queue-code-diffs" ]; then
  pass "case 10a: commit message without --goal unchanged (AC8)"
else
  fail "case 10a: commit message mismatch" "$m10a"
fi
if [ "$m10b" = "stride-ideation: decomposition for review-queue-code-diffs goal kanban-app" ]; then
  pass "case 10b: commit message with --goal includes goal slug (AC6)"
else
  fail "case 10b: commit message mismatch" "$m10b"
fi

# === case 11: same --goal invoked twice produces -2 sibling ===============

# Pre-create the first target file, then ask sti_unique_path for the next slot.
first_path="$TMP/2026-05-15T210800-review-queue-code-diffs-kanban-app-stride-batch.json"
touch "$first_path"
second_path="$(sti_unique_path "$TMP" "2026-05-15T210800" "review-queue-code-diffs-kanban-app" stride-batch json)"
expected_second="$TMP/2026-05-15T210800-review-queue-code-diffs-kanban-app-stride-batch-2.json"
if [ "$second_path" = "$expected_second" ]; then
  pass "case 11: re-invoking --goal on same doc produces -2 sibling (AC7)"
else
  fail "case 11: second-invocation path mismatch" "got=$second_path want=$expected_second"
fi
rm -f "$first_path"

# === case 12: seam literally named "1" — integer wins =====================

case12_out="$(sti_resolve_goal "$TMP/seam-named-one.md" "1")"
case12_idx="$(printf '%s' "$case12_out" | awk -F'\t' '{print $1}')"
case12_name="$(printf '%s' "$case12_out" | awk -F'\t' '{print $2}')"
if [ "$case12_idx" = "1" ] && [ "$case12_name" = "Alpha" ]; then
  pass "case 12: --goal 1 on doc with literal-1 seam → integer-index 1 wins (Alpha)"
else
  fail "case 12: integer-vs-slug heuristic wrong" "idx=$case12_idx name=$case12_name"
fi

# === case 13: multi-line item bodies — extractor uses first line only =====

case13_seams="$(sti_extract_seams "$TMP/multiline-body.md")"
case13_count="$(printf '%s\n' "$case13_seams" | wc -l | tr -d ' ')"
case13_names="$(printf '%s\n' "$case13_seams" | awk -F'\t' '{print $2}' | tr '\n' '|')"
if [ "$case13_count" = "3" ] && [ "$case13_names" = "First|Second|Third|" ]; then
  pass "case 13: multi-line item bodies — extractor uses bold-name from first line only (parser robustness)"
else
  fail "case 13: multi-line extraction wrong" "count=$case13_count names=$case13_names"
fi

# === case 14: items missing **bold** are silently skipped =================

case14_seams="$(sti_extract_seams "$TMP/missing-bold.md")"
case14_count="$(printf '%s\n' "$case14_seams" | wc -l | tr -d ' ')"
case14_names="$(printf '%s\n' "$case14_seams" | awk -F'\t' '{print $2}' | tr '\n' '|')"
if [ "$case14_count" = "2" ] && [ "$case14_names" = "Valid|Also valid|" ]; then
  pass "case 14: items lacking **bold** are skipped (parser robustness)"
else
  fail "case 14: missing-bold handling wrong" "count=$case14_count names=$case14_names"
fi

# === case 15: prompt scoping — drops other surfaces, keeps matched ========

scoped="$(sti_scope_doc_to_seam "$TMP/seven-surfaces.md" 1)"
# Matched item present:
if printf '%s' "$scoped" | grep -qE '^1\. \*\*Kanban app\*\*'; then
  pass "case 15a: scoped prompt contains the matched item (Kanban app)"
else
  fail "case 15a: scoped prompt missing matched item" "$(printf '%s' "$scoped" | tail -20)"
fi
# Other items absent:
if printf '%s' "$scoped" | grep -qE '^[2-9]\. \*\*'; then
  fail "case 15b: scoped prompt still contains other surface items" "$(printf '%s' "$scoped" | grep -E '^[0-9]+\. \*\*')"
else
  pass "case 15b: scoped prompt drops the other six surface items (AC5)"
fi
# Sections outside seams are preserved:
if printf '%s' "$scoped" | grep -qE '^## Assumptions'; then
  pass "case 15c: scoped prompt preserves sections outside seams (## Assumptions still present)"
else
  fail "case 15c: scoped prompt dropped a section outside seams"
fi
# Section heading + scoping notice present:
if printf '%s' "$scoped" | grep -qF '**Scoped to a single surface for this dispatch.**'; then
  pass "case 15d: scoped prompt includes the dispatch-scoping notice"
else
  fail "case 15d: scoped prompt missing dispatch-scoping notice"
fi

# === summary ==============================================================

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
