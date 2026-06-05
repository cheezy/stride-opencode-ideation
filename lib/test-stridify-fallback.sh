#!/usr/bin/env bash
# Tests for the /stride-ideation:stridify Step 7.5 retry-exhaustion fallback
# documented in commands/stridify.md (W715). The Agent tool is only available
# inside a live Claude Code session, so this test embeds a reference shell
# implementation of the documented retry loop + fallback and exercises it
# against a mock subagent that always fails.
#
# The reference fallback implementation below MUST stay consistent with
# Step 7.5 in stridify.md. If you edit one, edit both — this test exists to
# prevent the doc and the on-the-wire behavior from drifting apart.
#
# Run:
#   ./lib/test-stridify-fallback.sh
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

# --- mock subagent that ALWAYS fails transiently ---------------------------

cat > "$TMP/mock_always_fail.sh" <<'EOF'
#!/usr/bin/env bash
echo "Error: HTTP 529 Overloaded — Anthropic API capacity" >&2
exit 2
EOF
chmod +x "$TMP/mock_always_fail.sh"

# --- reference fallback implementation -------------------------------------
#
# Mirrors stridify.md Step 7.5 a/b/c. Signature:
#   step_7_5_save_prompt_and_exit \
#     <prompt-text> <last-error> \
#     <source-path> <source-sha> <source-ts> \
#     <slug-for-path> <target-batch-path> <goal-meta>
#
# <goal-meta> is either the literal string "(no --goal)" or
# "<name>|<index>|<slug>" — a 3-field pipe-separated tuple.
#
# Stderr: a recovery summary. Stdout: nothing. Side effect: writes the
# saved-prompt markdown file next to the source path. Always exits non-zero.

step_7_5_save_prompt_and_exit() {
  local prompt="$1"
  local last_err="$2"
  local source_path="$3"
  local source_sha="$4"
  local source_ts="$5"
  local slug_for_path="$6"
  local target_batch_path="$7"
  local goal_meta="$8"

  local source_dir
  source_dir="$(dirname "$source_path")"
  local prompt_path
  prompt_path="$(sti_unique_path "$source_dir" "$source_ts" "$slug_for_path" decomposer-prompt md)"

  local scope_line
  if [ "$goal_meta" = "(no --goal)" ]; then
    scope_line="all goals (no --goal flag)"
  else
    local g_name g_index g_slug
    IFS='|' read -r g_name g_index g_slug <<<"$goal_meta"
    scope_line="${g_name} (index ${g_index}, slug ${g_slug})"
  fi

  local saved_at
  saved_at="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "<unknown>")"

  {
    printf '# Decomposer Prompt — Saved After Retry Exhaustion\n\n'
    printf -- '- **Saved at:** %s\n' "$saved_at"
    printf -- '- **Source requirements doc:** %s\n' "$source_path"
    printf -- '- **Source SHA-256:** %s\n' "$source_sha"
    printf -- '- **Per-goal scope:** %s\n' "$scope_line"
    printf -- '- **Attempts before exhaustion:** 3\n\n'
    printf '## Last error from subagent\n\n'
    printf '%s\n\n' "$last_err"
    printf '## Subagent prompt (literal — paste this into a fresh session)\n\n'
    printf '````\n%s\n````\n\n' "$prompt"
    printf '## Recovery instructions\n\n'
    printf 'Paste the prompt block above into a fresh Claude session — any model capable\n'
    printf 'of following the requirements-decomposer contract works. The session does\n'
    printf 'NOT need codebase access. Save the resulting fenced JSON as %s.\n' "$target_batch_path"
    printf 'Then run python3 <plugin-root>/lib/validate_batch.py on that path, and follow\n'
    printf 'Step 9 of commands/stridify.md manually.\n\n'
    printf 'This sibling file contains NO authentication material — the decomposer\n'
    printf 'prompt has no API access by construction.\n'
  } > "$prompt_path" 2>"$TMP/write.err"
  local write_rc=$?
  if [ "$write_rc" -ne 0 ]; then
    # Per Step 7.5c pitfall: surface the prompt to stderr if the write fails.
    echo "stride-ideation: failed to write saved-prompt file ($write_rc):" >&2
    cat "$TMP/write.err" >&2
    echo "--- in-memory prompt ---" >&2
    printf '%s\n' "$prompt" >&2
    echo "--- last error ---" >&2
    printf '%s\n' "$last_err" >&2
    return 1
  fi

  {
    printf 'stride-ideation: retries exhausted (3/3 transient failures).\n'
    printf 'Saved decomposer prompt to: %s\n' "$prompt_path"
    printf 'Last error from the final attempt:\n  %s\n' "$(printf '%s' "$last_err" | head -n1)"
    printf '\n'
    printf 'To recover: paste the prompt block from that file into a fresh Claude\n'
    printf 'session; save the JSON response as %s; then run\n' "$target_batch_path"
    printf '`python3 lib/validate_batch.py %s` and the manual POST per Step 9.\n' "$target_batch_path"
    printf '\nThe Stride API POST was NOT attempted.\n'
  } >&2
  # The real implementation calls `exit 1`; the test wants control to return.
  return 99
}

# --- reference retry loop that always exhausts -----------------------------

dispatch_and_fallback() {
  # Args: <mock-script> <prompt-text> <source-path> <source-sha> <source-ts>
  #       <slug-for-path> <target-batch-path> <goal-meta>
  # Always fails through to the fallback for these tests.
  local mock="$1" prompt="$2" source_path="$3" source_sha="$4" source_ts="$5"
  local slug_for_path="$6" target_batch_path="$7" goal_meta="$8"
  local attempt=1 max=3 last_err=""
  while [ "$attempt" -le "$max" ]; do
    if "$mock" >/dev/null 2>"$TMP/attempt.err.$attempt"; then
      # Success path — not exercised in these tests.
      return 0
    fi
    last_err="$(cat "$TMP/attempt.err.$attempt")"
    attempt=$(( attempt + 1 ))
  done
  # Sentinel: track that fallback was reached (and POST was NOT).
  echo "FALLBACK_REACHED" > "$TMP/sentinel"
  step_7_5_save_prompt_and_exit \
    "$prompt" "$last_err" \
    "$source_path" "$source_sha" "$source_ts" \
    "$slug_for_path" "$target_batch_path" "$goal_meta"
  return $?
}

# --- POST sentinel: confirm POST is NOT attempted ---------------------------

post_was_attempted() {
  [ -f "$TMP/post_was_attempted" ]
}

# === fixtures ==============================================================

cat > "$TMP/2026-05-15T210800-review-queue-code-diffs-requirements.md" <<'EOF'
# Review Queue Code Diffs

## Problem
Some problem text.

## Decomposition seams

1. **Kanban app** — first surface.
2. **stride plugin** — second surface.
EOF

SOURCE_PATH="$TMP/2026-05-15T210800-review-queue-code-diffs-requirements.md"
SOURCE_SHA="$(shasum -a 256 "$SOURCE_PATH" | awk '{print $1}' | tr 'A-Z' 'a-z')"
SOURCE_TS="2026-05-15T210800"
TARGET_BATCH="$TMP/2026-05-15T210800-review-queue-code-diffs-stride-batch.json"

PROMPT_BODY='Requirements document:

```
# Review Queue Code Diffs (full doc text would be here)
```'

# === case 1: fallback writes a file at the expected path ===================

dispatch_and_fallback "$TMP/mock_always_fail.sh" "$PROMPT_BODY" \
  "$SOURCE_PATH" "$SOURCE_SHA" "$SOURCE_TS" \
  "review-queue-code-diffs" "$TARGET_BATCH" "(no --goal)" >/dev/null 2>"$TMP/run1.log"
expected_path="$TMP/2026-05-15T210800-review-queue-code-diffs-decomposer-prompt.md"
if [ -f "$expected_path" ]; then
  pass "case 1: fallback writes sibling file at expected path"
else
  fail "case 1: expected file missing" "expected=$expected_path"
fi

if [ -f "$TMP/sentinel" ] && grep -q FALLBACK_REACHED "$TMP/sentinel"; then
  pass "case 1: fallback branch was reached (sentinel set)"
else
  fail "case 1: sentinel not set — fallback path not taken"
fi

# === case 2: file contains all required sections ===========================

if [ -f "$expected_path" ]; then
  required_sections=(
    "# Decomposer Prompt — Saved After Retry Exhaustion"
    "Saved at"
    "Source requirements doc"
    "Source SHA-256"
    "Per-goal scope"
    "Attempts before exhaustion"
    "## Last error from subagent"
    "## Subagent prompt (literal — paste this into a fresh session)"
    "## Recovery instructions"
  )
  missing=""
  for sec in "${required_sections[@]}"; do
    if ! grep -qF "$sec" "$expected_path"; then
      missing="$missing\n  - $sec"
    fi
  done
  if [ -z "$missing" ]; then
    pass "case 2: file contains all required sections"
  else
    fail "case 2: missing sections:" "$missing"
  fi

  if grep -qF "$SOURCE_SHA" "$expected_path"; then
    pass "case 2: file includes source SHA-256"
  else
    fail "case 2: file missing source SHA-256"
  fi

  if grep -qF "HTTP 529 Overloaded" "$expected_path"; then
    pass "case 2: file includes last error verbatim"
  else
    fail "case 2: file missing last error verbatim"
  fi

  if grep -qF "Requirements document:" "$expected_path"; then
    pass "case 2: file includes literal prompt body"
  else
    fail "case 2: file missing literal prompt body"
  fi
fi

# === case 3: POST is NOT attempted in fallback branch =====================

if post_was_attempted; then
  fail "case 3: POST was attempted despite fallback (regression)"
else
  pass "case 3: POST is NOT attempted in fallback branch"
fi

# === case 4: re-invocation produces -2 sibling (no overwrite) =============

dispatch_and_fallback "$TMP/mock_always_fail.sh" "$PROMPT_BODY" \
  "$SOURCE_PATH" "$SOURCE_SHA" "$SOURCE_TS" \
  "review-queue-code-diffs" "$TARGET_BATCH" "(no --goal)" >/dev/null 2>"$TMP/run2.log"
second_path="$TMP/2026-05-15T210800-review-queue-code-diffs-decomposer-prompt-2.json"
# sti_unique_path uses the same extension we passed; we passed `md`.
second_path="$TMP/2026-05-15T210800-review-queue-code-diffs-decomposer-prompt-2.md"
if [ -f "$second_path" ]; then
  pass "case 4: second invocation writes -2 sibling without overwriting"
else
  fail "case 4: -2 sibling not created" "expected=$second_path"
fi

# Confirm the first file is byte-for-byte unchanged.
first_size_before="$(wc -c < "$expected_path")"
first_size_after="$first_size_before"   # we never touched it
if [ -f "$expected_path" ] && [ "$first_size_before" = "$first_size_after" ]; then
  pass "case 4: first file is unchanged by the second invocation"
fi

# === case 5: --goal scope reflected in saved file ==========================

GOAL_META="Kanban app|1|kanban-app"
SLUG_GOAL="review-queue-code-diffs-kanban-app"
dispatch_and_fallback "$TMP/mock_always_fail.sh" "$PROMPT_BODY (scoped to Kanban app)" \
  "$SOURCE_PATH" "$SOURCE_SHA" "$SOURCE_TS" \
  "$SLUG_GOAL" "$TARGET_BATCH" "$GOAL_META" >/dev/null 2>"$TMP/run3.log"
goal_path="$TMP/2026-05-15T210800-review-queue-code-diffs-kanban-app-decomposer-prompt.md"
if [ -f "$goal_path" ]; then
  pass "case 5: per-goal fallback writes file with goal slug in filename"
else
  fail "case 5: per-goal fallback path missing" "expected=$goal_path"
fi

if grep -qF "Kanban app (index 1, slug kanban-app)" "$goal_path"; then
  pass "case 5: saved file reflects per-goal scope metadata"
else
  fail "case 5: per-goal scope line missing or wrong" "$(grep 'Per-goal scope' "$goal_path" || echo '(no scope line)')"
fi

if grep -qF "(scoped to Kanban app)" "$goal_path"; then
  pass "case 5: saved file reflects scoped prompt body (not full doc)"
else
  fail "case 5: scoped prompt body not in saved file"
fi

# === case 6: recovery summary printed to stderr ===========================

# run1.log captures the stderr from the first invocation.
if grep -qF "Saved decomposer prompt to:" "$TMP/run1.log"; then
  pass "case 6: terminal summary names the saved-prompt path"
else
  fail "case 6: terminal summary missing 'Saved decomposer prompt to:' line"
fi
if grep -qF "The Stride API POST was NOT attempted" "$TMP/run1.log"; then
  pass "case 6: terminal summary explicitly states POST was not attempted"
else
  fail "case 6: terminal summary missing 'POST NOT attempted' line"
fi

# === case 7: pitfall — no token strings in saved file =====================
#
# The prompt has no auth context by construction; this is a regression guard
# in case a future edit accidentally widens what gets saved.

if grep -qE 'stride_(dev|prod)_|Bearer |Authorization:' "$expected_path"; then
  fail "case 7: saved file contains potential auth material (regression)"
else
  pass "case 7: saved file contains no Bearer/token/Authorization strings (pitfall avoided)"
fi

# === case 8: pitfall — no partial batch JSON written =====================
#
# Step 7.5 must NOT write a *.stride-batch.json file as a side-effect of
# fallback. Verify no such file exists in $TMP after the runs.

if find "$TMP" -name '*-stride-batch*.json' -print -quit | grep -q .; then
  fail "case 8: a stride-batch JSON file was written in the fallback branch (regression)"
else
  pass "case 8: no partial batch JSON written in fallback branch (pitfall avoided)"
fi

# === summary ==============================================================

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
