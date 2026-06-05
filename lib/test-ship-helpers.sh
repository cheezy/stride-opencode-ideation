#!/usr/bin/env bash
# Unit tests for the /stride-ideation:ship helpers:
#
#   - lib/strip_audit_fields.py  strips source_spec/sha256/decomposition_notes
#   - lib/read_auth.py            extracts STRIDE_API_URL and STRIDE_API_TOKEN
#                                 from .stride_auth.md
#
# Run:
#   ./lib/test-ship-helpers.sh
#
# Exits 0 if all tests pass, non-zero otherwise.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STRIP="${SCRIPT_DIR}/strip_audit_fields.py"
READ_AUTH="${SCRIPT_DIR}/read_auth.py"

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

# --- strip_audit_fields: happy path -----------------------------------------

cat > "$TMP/with_audit.json" <<'EOF'
{
  "source_spec": "fixtures/x.md",
  "source_spec_sha256": "abc123",
  "decomposition_notes": "notes",
  "goals": [
    {"title": "G1", "type": "goal", "tasks": [{"title": "T1", "type": "work"}]}
  ]
}
EOF

# Record the on-disk file's pre-strip SHA + contents so the
# "file is unchanged" assertion below has a fixed baseline.
WITH_AUDIT_SHA_BEFORE="$(shasum -a 256 "$TMP/with_audit.json" | awk '{print $1}')"
cp "$TMP/with_audit.json" "$TMP/with_audit.json.before"

if STRIPPED="$(python3 "$STRIP" "$TMP/with_audit.json" 2>&1)"; then
  if ! printf '%s' "$STRIPPED" | grep -q 'source_spec'; then
    if ! printf '%s' "$STRIPPED" | grep -q 'source_spec_sha256'; then
      if ! printf '%s' "$STRIPPED" | grep -q 'decomposition_notes'; then
        if printf '%s' "$STRIPPED" | grep -q 'goals'; then
          pass "strip: removes all three audit fields; preserves goals"
        else
          fail "strip: removes audit fields but lost goals" "$STRIPPED"
        fi
      else
        fail "strip: did not remove decomposition_notes" "$STRIPPED"
      fi
    else
      fail "strip: did not remove source_spec_sha256" "$STRIPPED"
    fi
  else
    fail "strip: did not remove source_spec" "$STRIPPED"
  fi
else
  fail "strip: exited non-zero on valid input" "$STRIPPED"
fi

# AC: the on-disk file must be unchanged after stripping. This is the
# audit-trail guarantee — the local-audit fields stay on disk so the
# v0.2 drift check has something to compare against.
WITH_AUDIT_SHA_AFTER="$(shasum -a 256 "$TMP/with_audit.json" | awk '{print $1}')"
if [ "$WITH_AUDIT_SHA_BEFORE" = "$WITH_AUDIT_SHA_AFTER" ]; then
  if diff -q "$TMP/with_audit.json.before" "$TMP/with_audit.json" >/dev/null 2>&1; then
    pass "strip: on-disk file is byte-for-byte unchanged after run"
  else
    fail "strip: SHAs matched but diff disagreed" "diff output above"
  fi
else
  fail "strip: on-disk file was modified by the helper" \
    "before SHA=$WITH_AUDIT_SHA_BEFORE after SHA=$WITH_AUDIT_SHA_AFTER"
fi

# --- strip_audit_fields: idempotent when fields already absent --------------

cat > "$TMP/no_audit.json" <<'EOF'
{"goals": [{"title": "G1", "type": "goal", "tasks": [{"title": "T1", "type": "work"}]}]}
EOF

if STRIPPED2="$(python3 "$STRIP" "$TMP/no_audit.json" 2>&1)"; then
  if printf '%s' "$STRIPPED2" | grep -q 'goals'; then
    pass "strip: idempotent — passes through when audit fields absent"
  else
    fail "strip: passes through but lost goals" "$STRIPPED2"
  fi
else
  fail "strip: failed on input that already lacked audit fields"
fi

# --- strip_audit_fields: malformed JSON -------------------------------------

cat > "$TMP/bad.json" <<'EOF'
{ not json
EOF

if python3 "$STRIP" "$TMP/bad.json" >/dev/null 2>"$TMP/bad.err"; then
  fail "strip: exited 0 on malformed JSON (expected non-zero)"
else
  if grep -q "could not read" "$TMP/bad.err"; then
    pass "strip: surfaces a read/parse error on malformed JSON"
  else
    fail "strip: failed on malformed JSON but error message missing" "$(cat "$TMP/bad.err")"
  fi
fi

# --- read_auth: happy path --------------------------------------------------

cat > "$TMP/.stride_auth.md" <<'EOF'
# Stride API Authentication

## API Configuration

- **API URL:** `https://www.stridelikeaboss.com`
- **Local API Token:** `stride_dev_LOCAL_TOKEN_SHOULD_NOT_MATCH`
- **API Token:** `stride_dev_REAL_TOKEN_xyz123`
- **User Email:** `cheezy@example.com`
EOF

if AUTH_OUT="$(python3 "$READ_AUTH" "$TMP/.stride_auth.md" 2>&1)"; then
  url_line="$(printf '%s' "$AUTH_OUT" | grep '^STRIDE_API_URL=' || true)"
  token_line="$(printf '%s' "$AUTH_OUT" | grep '^STRIDE_API_TOKEN=' || true)"
  if [ "$url_line" = "STRIDE_API_URL=https://www.stridelikeaboss.com" ]; then
    pass "read_auth: extracts STRIDE_API_URL"
  else
    fail "read_auth: URL line mismatch" "$url_line"
  fi
  if [ "$token_line" = "STRIDE_API_TOKEN=stride_dev_REAL_TOKEN_xyz123" ]; then
    pass "read_auth: extracts API Token (NOT the Local API Token)"
  else
    fail "read_auth: token mismatch — picked up wrong line" "$token_line"
  fi
else
  fail "read_auth: exited non-zero on a valid file" "$AUTH_OUT"
fi

# --- read_auth: missing URL --------------------------------------------------

cat > "$TMP/no_url.md" <<'EOF'
- **API Token:** `stride_xxx`
EOF

if python3 "$READ_AUTH" "$TMP/no_url.md" >/dev/null 2>"$TMP/no_url.err"; then
  fail "read_auth: exited 0 when URL missing"
else
  if grep -q "STRIDE_API_URL not found" "$TMP/no_url.err"; then
    pass "read_auth: errors on missing API URL with the right message"
  else
    fail "read_auth: missing-URL error message wrong" "$(cat "$TMP/no_url.err")"
  fi
fi

# --- read_auth: missing token ----------------------------------------------

cat > "$TMP/no_token.md" <<'EOF'
- **API URL:** `https://www.stridelikeaboss.com`
EOF

if python3 "$READ_AUTH" "$TMP/no_token.md" >/dev/null 2>"$TMP/no_token.err"; then
  fail "read_auth: exited 0 when token missing"
else
  if grep -q "STRIDE_API_TOKEN not found" "$TMP/no_token.err"; then
    pass "read_auth: errors on missing API Token with the right message"
  else
    fail "read_auth: missing-token error message wrong" "$(cat "$TMP/no_token.err")"
  fi
fi

# --- read_auth: token MUST NOT appear in stderr (security pitfall) ----------

cat > "$TMP/with_token.md" <<'EOF'
- **API URL:** `https://example.com`
- **API Token:** `stride_dev_SUPER_SECRET_TOKEN_xyz_DO_NOT_LEAK`
EOF

# This is the happy-path file but we want to deliberately tickle the
# missing-token branch by stripping the URL line, to confirm stderr never
# carries the token value if any other branch happened to surface text.
sed -E 's/- \*\*API URL.*//' "$TMP/with_token.md" > "$TMP/leak_test.md"
python3 "$READ_AUTH" "$TMP/leak_test.md" >/dev/null 2>"$TMP/leak_test.err"
if grep -q 'stride_dev_SUPER_SECRET_TOKEN' "$TMP/leak_test.err"; then
  fail "read_auth: token value LEAKED in stderr" "$(cat "$TMP/leak_test.err")"
else
  pass "read_auth: token value NEVER appears in stderr (security)"
fi

# --- read_auth: nonexistent path --------------------------------------------

if python3 "$READ_AUTH" "$TMP/does_not_exist.md" >/dev/null 2>"$TMP/missing.err"; then
  fail "read_auth: exited 0 on nonexistent file"
else
  if grep -q ".stride_auth.md not found" "$TMP/missing.err"; then
    pass "read_auth: errors cleanly on missing file"
  else
    fail "read_auth: missing-file error message wrong" "$(cat "$TMP/missing.err")"
  fi
fi

# --- read_auth: missing file error includes setup-doc link ------------------

if grep -Fq "https://www.stridelikeaboss.com/api/agent/onboarding" "$TMP/missing.err"; then
  pass "read_auth: missing-file error links to the setup docs"
else
  fail "read_auth: missing-file error does not link to setup docs" \
    "$(cat "$TMP/missing.err")"
fi

# --- read_auth: missing-URL error also links to setup docs ------------------

if grep -Fq "https://www.stridelikeaboss.com/api/agent/onboarding" "$TMP/no_url.err"; then
  pass "read_auth: missing-URL error links to the setup docs"
else
  fail "read_auth: missing-URL error does not link to setup docs" \
    "$(cat "$TMP/no_url.err")"
fi

# --- read_auth: missing-token error also links to setup docs ----------------

if grep -Fq "https://www.stridelikeaboss.com/api/agent/onboarding" "$TMP/no_token.err"; then
  pass "read_auth: missing-token error links to the setup docs"
else
  fail "read_auth: missing-token error does not link to setup docs" \
    "$(cat "$TMP/no_token.err")"
fi

# --- summary ----------------------------------------------------------------

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
