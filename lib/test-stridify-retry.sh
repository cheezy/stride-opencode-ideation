#!/usr/bin/env bash
# Tests for the /stride-ideation:stridify Step 7 retry classification documented
# in commands/stridify.md. The Agent tool is only available inside a live
# Claude Code session, so this test embeds a reference shell implementation of
# the documented retry loop and exercises it against a mock subagent script.
#
# The reference implementation below MUST stay consistent with the pseudo-code
# in stridify.md Step 7 (7a classification table, 7b backoff, 7c code-flow).
# If you edit one, edit both — the test exists to prevent the doc and the
# real implementation from drifting apart.
#
# Run:
#   ./lib/test-stridify-retry.sh
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

# --- mock subagent ----------------------------------------------------------
#
# The mock simulates the Agent tool: it consults a per-test counter file and
# a per-test mode file, fails the first N calls, then succeeds.
#
#   counter file : integer; decremented each call until 0, then mock succeeds
#   mode file    : "transient" or "terminal" — only matters while counter > 0
#
# Stdout on success: a fenced ```json block matching the requirements-decomposer
# output contract. Stderr on failure: a mode-specific error string.

cat > "$TMP/mock_agent.sh" <<'EOF'
#!/usr/bin/env bash
set -u
COUNTER_FILE="$1"
MODE_FILE="$2"
remaining="$(cat "$COUNTER_FILE")"
mode="$(cat "$MODE_FILE")"
if [ "$remaining" -gt 0 ]; then
  remaining=$(( remaining - 1 ))
  printf '%s' "$remaining" > "$COUNTER_FILE"
  case "$mode" in
    transient)
      printf 'Error: HTTP 529 Overloaded — Anthropic API capacity\n' >&2
      exit 2
      ;;
    terminal)
      printf 'Error: subagent returned non-JSON response (contract violation)\n' >&2
      exit 3
      ;;
    *)
      printf 'Error: unknown mode %s\n' "$mode" >&2
      exit 4
      ;;
  esac
fi
cat <<'JSON'
```json
{"goals":[{"title":"G1","type":"goal","tasks":[{"title":"T1","type":"work"}]}]}
```
JSON
EOF
chmod +x "$TMP/mock_agent.sh"

# --- reference retry implementation ----------------------------------------
#
# Mirrors stridify.md Step 7 (7a/7b/7c). Backoffs are zeroed by default so the
# suite runs in well under a second; the documented schedule is 30s / 90s.

MAX_ATTEMPTS=3
BACKOFF_1="${BACKOFF_1:-0}"
BACKOFF_2="${BACKOFF_2:-0}"

classify_dispatch_error() {
  # Args: <err_text>. Echoes "transient" or "terminal".
  local err_text="$1"
  case "$err_text" in
    *529*|*Overloaded*|*overloaded*) echo "transient"; return ;;
    *"Could not resolve"*|*"Connection refused"*|*"timeout"*|*"TLS handshake"*) echo "transient"; return ;;
    *) echo "terminal" ;;
  esac
}

dispatch_with_retry() {
  # Args: <counter_file> <mode_file>
  # Stdout on success: the mock's stdout (fenced JSON).
  # Stderr always: one-line attempt headers + final error on failure.
  local counter_file="$1"
  local mode_file="$2"
  local attempt=1
  local last_error=""
  local result_file="$TMP/result.$$"
  local err_file
  while [ "$attempt" -le "$MAX_ATTEMPTS" ]; do
    printf 'dispatching attempt %d/%d\n' "$attempt" "$MAX_ATTEMPTS" >&2
    err_file="$TMP/err.$$.$attempt"
    if "$TMP/mock_agent.sh" "$counter_file" "$mode_file" >"$result_file" 2>"$err_file"; then
      cat "$result_file"
      rm -f "$result_file" "$err_file"
      return 0
    fi
    last_error="$(cat "$err_file")"
    rm -f "$err_file"
    local cls
    cls="$(classify_dispatch_error "$last_error")"
    if [ "$cls" = "terminal" ]; then
      printf 'TERMINAL: %s\n' "$last_error" >&2
      rm -f "$result_file"
      return 1
    fi
    if [ "$attempt" -lt "$MAX_ATTEMPTS" ]; then
      case "$attempt" in
        1) sleep "$BACKOFF_1" ;;
        2) sleep "$BACKOFF_2" ;;
      esac
      attempt=$(( attempt + 1 ))
      continue
    fi
    printf 'EXHAUSTED: %s\n' "$last_error" >&2
    rm -f "$result_file"
    return 1
  done
  rm -f "$result_file"
  return 1
}

# --- case 1: success on first attempt (no retry path exercised) ------------

echo 0 > "$TMP/counter1"
echo transient > "$TMP/mode1"
if OUT1="$(dispatch_with_retry "$TMP/counter1" "$TMP/mode1" 2>"$TMP/log1")"; then
  if printf '%s' "$OUT1" | grep -q '```json'; then
    pass "case 1: succeeds on first attempt with valid fenced JSON"
  else
    fail "case 1: succeeded but output lacked fenced JSON" "$OUT1"
  fi
else
  fail "case 1: dispatch_with_retry returned non-zero on first-attempt success" "$(cat "$TMP/log1")"
fi
attempts1="$(grep -c '^dispatching attempt' "$TMP/log1" || true)"
if [ "$attempts1" = "1" ]; then
  pass "case 1: exactly 1 attempt logged (no retry on success)"
else
  fail "case 1: expected 1 attempt, got $attempts1"
fi

# --- case 2: 2× transient then success on attempt 3 ------------------------

echo 2 > "$TMP/counter2"
echo transient > "$TMP/mode2"
if OUT2="$(dispatch_with_retry "$TMP/counter2" "$TMP/mode2" 2>"$TMP/log2")"; then
  if printf '%s' "$OUT2" | grep -q '```json'; then
    pass "case 2: 2× transient then success on attempt 3"
  else
    fail "case 2: succeeded but output lacked fenced JSON" "$OUT2"
  fi
else
  fail "case 2: failed after 2× transient + 1× success" "$(cat "$TMP/log2")"
fi
attempts2="$(grep -c '^dispatching attempt' "$TMP/log2" || true)"
if [ "$attempts2" = "3" ]; then
  pass "case 2: exactly 3 attempts logged"
else
  fail "case 2: expected 3 attempts, got $attempts2"
fi

# --- case 3: 3× transient → exhaust + surface LAST error verbatim ----------

echo 3 > "$TMP/counter3"
echo transient > "$TMP/mode3"
if dispatch_with_retry "$TMP/counter3" "$TMP/mode3" >/dev/null 2>"$TMP/log3"; then
  fail "case 3: returned 0 after 3× transient (expected non-zero)"
else
  if grep -q '^EXHAUSTED' "$TMP/log3"; then
    pass "case 3: exhausts retries and exits non-zero"
  else
    fail "case 3: failed but did not log EXHAUSTED" "$(cat "$TMP/log3")"
  fi
  if grep -q 'HTTP 529 Overloaded' "$TMP/log3"; then
    pass "case 3: surfaces LAST attempt's error verbatim"
  else
    fail "case 3: terminal output did not include last error verbatim" "$(cat "$TMP/log3")"
  fi
fi
attempts3="$(grep -c '^dispatching attempt' "$TMP/log3" || true)"
if [ "$attempts3" = "3" ]; then
  pass "case 3: cap honored — exactly 3 attempts"
else
  fail "case 3: expected 3 attempts, got $attempts3 (cap not honored)"
fi

# --- case 4: contract violation → fail fast, no retry ----------------------

echo 5 > "$TMP/counter4"   # would fail 5× if it kept retrying
echo terminal > "$TMP/mode4"
if dispatch_with_retry "$TMP/counter4" "$TMP/mode4" >/dev/null 2>"$TMP/log4"; then
  fail "case 4: returned 0 on contract violation (expected non-zero)"
else
  if grep -q '^TERMINAL' "$TMP/log4"; then
    pass "case 4: classifies contract violation as terminal"
  else
    fail "case 4: terminal classification not logged" "$(cat "$TMP/log4")"
  fi
fi
attempts4="$(grep -c '^dispatching attempt' "$TMP/log4" || true)"
if [ "$attempts4" = "1" ]; then
  pass "case 4: fails fast on attempt 1 (terminal does NOT retry)"
else
  fail "case 4: expected 1 attempt, got $attempts4 — terminal retried!"
fi

# --- case 5: 'overloaded' string in body classifies as transient -----------

cls5="$(classify_dispatch_error 'API returned: overloaded; try again later')"
if [ "$cls5" = "transient" ]; then
  pass "case 5: 'overloaded' string in error body classifies as transient"
else
  fail "case 5: 'overloaded' classified as $cls5 (expected transient)"
fi

# --- case 6: unknown subagent type classifies as terminal ------------------

cls6="$(classify_dispatch_error 'unknown subagent type: foo')"
if [ "$cls6" = "terminal" ]; then
  pass "case 6: unknown subagent type classifies as terminal"
else
  fail "case 6: unknown subagent type classified as $cls6 (expected terminal)"
fi

# --- case 7: network error (Connection refused) classifies as transient ----

cls7="$(classify_dispatch_error 'curl: (7) Failed to connect: Connection refused')"
if [ "$cls7" = "transient" ]; then
  pass "case 7: 'Connection refused' classifies as transient"
else
  fail "case 7: 'Connection refused' classified as $cls7 (expected transient)"
fi

# --- case 8: attempt headers must NOT include the full prompt --------------
#
# Pitfall: the retry loop must log a one-line "attempt N/3" header per attempt,
# never the full requirements-doc prompt. The reference implementation only
# emits the header; this asserts that contract is honored.

echo 2 > "$TMP/counter8"
echo transient > "$TMP/mode8"
dispatch_with_retry "$TMP/counter8" "$TMP/mode8" >/dev/null 2>"$TMP/log8" || true
# Each attempt's log lines should be at most: one header line + one error line.
# Reject any attempt block that exceeds ~4 lines (header + classification + a
# bit of slack), which would indicate the prompt is being echoed.
log_lines="$(wc -l < "$TMP/log8" | tr -d ' ')"
if [ "$log_lines" -le 8 ]; then
  pass "case 8: retry log is concise — no prompt echoed (${log_lines} lines)"
else
  fail "case 8: retry log too long (${log_lines} lines) — prompt may be leaking" "$(cat "$TMP/log8")"
fi

# --- summary ---------------------------------------------------------------

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
