#!/usr/bin/env bash
# Tests for lib/ship.sh (the /stridify Step 3 preflight and
# Steps 9-10 POST + render) and for the shell-safe output of lib/read_auth.py.
#
# curl is replaced by a PATH-prepended fake that counts its invocations,
# records its argv and environment, captures the -K config it reads from
# stdin, copies the --data-binary payload it was handed and reports its file
# mode, and answers with a canned status/body/stderr/exit taken from FAKE_*
# env vars. The call count is what lets a test catch a retried POST.
# No network access is needed. Every run of ship.sh gets its own TMPDIR so the
# tests can assert that no temp file outlives the script.
#
# Run:
#   ./lib/test-ship.sh
#
# Exits 0 if all tests pass, non-zero otherwise.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SHIP="${SCRIPT_DIR}/ship.sh"
READ_AUTH="${SCRIPT_DIR}/read_auth.py"

# A fake value only — the tests assert it never escapes into argv or output.
TOKEN="stride_dev_SHIP_TEST_TOKEN_9f3k"

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

# --- fixtures -----------------------------------------------------------------

cat > "$TMP/auth.md" <<EOF
# Stride API Authentication

- **API URL:** \`https://stride.example\`
- **Local API Token:** \`stride_dev_LOCAL_TOKEN_SHOULD_NOT_MATCH\`
- **API Token:** \`$TOKEN\`
EOF

cat > "$TMP/auth-local-only.md" <<'EOF'
- **API URL:** `https://stride.example`
- **Local API Token:** `stride_dev_LOCAL_ONLY_TOKEN_abc`
EOF

cat > "$TMP/batch.json" <<'EOF'
{
  "source_spec": "docs/ideation/x-requirements.md",
  "source_spec_sha256": "abc123",
  "decomposition_notes": "claim order: G1 first",
  "goals": [
    {
      "title": "Goal one",
      "type": "goal",
      "created_by_agent": "Claude Opus 5.5",
      "tasks": [{"title": "Task one", "type": "work"}]
    }
  ]
}
EOF

# The shape the server really returns (docs/api/post_tasks_batch.md).
cat > "$TMP/created.json" <<'EOF'
{"success": true, "total": 1, "goals": [
  {"goal": {"id": 1, "identifier": "G77", "title": "Goal one", "type": "goal"},
   "child_tasks": [{"id": 2, "identifier": "W901", "title": "Task one"},
                   {"id": 3, "identifier": "D12", "title": "Task two"}]}]}
EOF

# The flat shape older responses and the old Step 10 renderer used.
cat > "$TMP/created-flat.json" <<'EOF'
{"data": {"goals": [{"identifier": "G78", "title": "Flat goal",
  "tasks": [{"identifier": "W902", "title": "Flat task"}]}]}}
EOF

printf '{"success": true, "total": 0, "goals": []}' > "$TMP/empty-goals.json"
printf '{"success": true, "goals": [{"goal": {"title": "no identifier"}, "child_tasks": []}]}' > "$TMP/no-ident.json"

# A dev server's debug error page echoes the request headers, token included.
printf '<html><dt>authorization</dt><dd>Bearer %s</dd><p>raw %s</p><p>other Bearer abc.DEF-123</p></html>' "$TOKEN" "$TOKEN" > "$TMP/500-debug.html"

printf '{"error":"Validation failed","details":{"goals":["is invalid"]}}' > "$TMP/422.json"
printf '<html>Bad gateway</html>' > "$TMP/502.html"
printf '<html>moved</html>' > "$TMP/302.html"
printf 'OK, but this is not JSON' > "$TMP/notjson.txt"
printf '[1, 2, 3]' > "$TMP/list.json"
python3 -c 'import sys; sys.stdout.write("{\"error\":\"" + "x" * 200000 + "\"}")' > "$TMP/big.json"

# --- fake curl ----------------------------------------------------------------

mkdir -p "$TMP/bin"
cat > "$TMP/bin/curl" <<'EOF'
#!/usr/bin/env bash
# Fake curl for lib/test-ship.sh. Behaviour comes from FAKE_* env vars.
log="$FAKE_LOG_DIR"
echo x >> "$log/calls"
: > "$log/argv"
for a in "$@"; do printf '%s\n' "$a" >> "$log/argv"; done
out="" cfg="" data=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) out="$2"; shift ;;
    -K) cfg="$2"; shift ;;
    --data-binary) data="$2"; shift ;;
  esac
  shift
done
mode() { python3 -c 'import os,sys; print(oct(os.stat(sys.argv[1]).st_mode & 0o777))' "$1"; }
if [ "$cfg" = "-" ]; then cat > "$log/config"; elif [ -n "$cfg" ]; then cp "$cfg" "$log/config"; fi
if env | grep -q '^STRIDE_API_TOKEN='; then echo yes > "$log/env-token"; else echo no > "$log/env-token"; fi
case "$data" in
  @*) cp "${data#@}" "$log/payload"; mode "${data#@}" > "$log/payload.mode" ;;
esac
: > "$log/started"
if [ -n "${FAKE_SLEEP:-}" ]; then sleep "$FAKE_SLEEP"; fi
if [ -n "${FAKE_STDERR:-}" ]; then printf '%s\n' "$FAKE_STDERR" >&2; fi
if [ -n "$out" ] && [ -n "${FAKE_BODY:-}" ]; then cp "$FAKE_BODY" "$out"; fi
printf '%s' "${FAKE_CODE:-200}"
exit "${FAKE_EXIT:-0}"
EOF
chmod +x "$TMP/bin/curl"

# run_ship <case> <args...> — runs ship.sh against the fake curl with an
# isolated TMPDIR. Leaves $C/out, $C/err, $C/rc, $C/log/* and $C/tmpdir.
run_ship() {
  local name="$1"; shift
  C="$TMP/case-$name"
  mkdir -p "$C/log" "$C/tmpdir"
  PATH="$TMP/bin:$PATH" TMPDIR="$C/tmpdir" FAKE_LOG_DIR="$C/log" \
    STRIDE_AUTH_FILE="${AUTH_FILE_OVERRIDE:-$TMP/auth.md}" \
    bash "$SHIP" "$@" > "$C/out" 2> "$C/err"
  echo "$?" > "$C/rc"
}

rc_is() {
  local label="$1" want="$2" got
  got="$(cat "$C/rc")"
  if [ "$got" = "$want" ]; then pass "$label"; else fail "$label" "exit $got, want $want; stderr: $(head -c 400 "$C/err")"; fi
}

contains() {
  local label="$1" file="$2" needle="$3"
  if grep -qF -- "$needle" "$file"; then pass "$label"; else fail "$label" "missing '$needle' in $(basename "$file")"; fi
}

lacks() {
  local label="$1" file="$2" needle="$3"
  if [ -f "$file" ] && grep -qF -- "$needle" "$file"; then fail "$label" "found '$needle' in $(basename "$file")"; else pass "$label"; fi
}

no_temp_left() {
  local left
  left="$(ls -A "$C/tmpdir")"
  if [ -z "$left" ]; then pass "$1"; else fail "$1" "left behind: $left"; fi
}

# calls_are <label> <n> — curl ran exactly n times in this case. A retried
# POST could double-create goals, so every request-making case checks for 1.
calls_are() {
  local label="$1" want="$2" got=0
  if [ -f "$C/log/calls" ]; then got="$(wc -l < "$C/log/calls" | tr -d ' ')"; fi
  if [ "$got" = "$want" ]; then pass "$label"; else fail "$label" "curl ran $got time(s), want $want"; fi
}

no_token_anywhere() {
  if grep -qF -- "$TOKEN" "$C/out" "$C/err" "$C/log/argv" 2>/dev/null; then
    fail "$1" "token found in stdout, stderr or curl argv"
  else
    pass "$1"
  fi
}

# verbatim_body <label> <header-line> <body-file>: stderr is exactly the
# header line, the body bytes, and one newline.
verbatim_body() {
  { printf '%s\n' "$2"; cat "$3"; echo; } > "$C/expected.err"
  if cmp -s "$C/expected.err" "$C/err"; then pass "$1"; else fail "$1" "stderr is not header + verbatim body"; fi
}

# --- read_auth.py: shell-safe output -------------------------------------------

mkdir -p "$TMP/evaldir"
cat > "$TMP/auth-amp.md" <<'EOF'
- **API URL:** `https://stride.example/p?a=1&b=2`
- **API Token:** `stride_dev_AMP_abc`
EOF
out="$(cd "$TMP/evaldir" && eval "$(python3 "$READ_AUTH" "$TMP/auth-amp.md")" && printf '%s' "$STRIDE_API_URL")"
if [ "$out" = "https://stride.example/p?a=1&b=2" ]; then
  pass "read_auth: a URL containing & evals back unchanged"
else
  fail "read_auth: & URL did not round-trip" "$out"
fi

cat > "$TMP/auth-subst.md" <<'EOF'
- **API URL:** `https://stride.example/$(touch${IFS}pwned)x;touch${IFS}pwned2`
- **API Token:** `stride_dev_SUBST_abc`
EOF
out="$(cd "$TMP/evaldir" && eval "$(python3 "$READ_AUTH" "$TMP/auth-subst.md")" && printf '%s' "$STRIDE_API_URL")"
# shellcheck disable=SC2016  # the literal string is the point
if [ "$out" = 'https://stride.example/$(touch${IFS}pwned)x;touch${IFS}pwned2' ]; then
  pass "read_auth: command-substitution and ; in a URL eval back literally"
else
  fail "read_auth: substitution URL did not round-trip" "$out"
fi
if [ ! -e "$TMP/evaldir/pwned" ] && [ ! -e "$TMP/evaldir/pwned2" ]; then
  pass "read_auth: eval of a hostile URL executes nothing"
else
  fail "read_auth: eval of the auth output executed a command"
fi

auth_out="$(python3 "$READ_AUTH" "$TMP/auth.md")"
if [ "$auth_out" = "$(printf 'STRIDE_API_URL=https://stride.example\nSTRIDE_API_TOKEN=%s' "$TOKEN")" ]; then
  pass "read_auth: plain values are still printed unquoted"
else
  fail "read_auth: plain-value output changed" "$auth_out"
fi

# --- usage --------------------------------------------------------------------

run_ship usage
rc_is "ship: no argument is a usage error (exit 2)" 2
contains "ship: usage error names every form" "$C/err" "ship.sh --check-auth | ship.sh --check-payload <batch.json> | ship.sh <batch.json>"

run_ship missing "$TMP/does-not-exist.json"
rc_is "ship: a missing batch file exits 1" 1
contains "ship: missing batch file is named" "$C/err" "batch JSON not found at"
if [ ! -s "$C/log/argv" ]; then pass "ship: a missing batch file never reaches curl"; else fail "ship: curl ran for a missing batch file"; fi

# --- --check-auth ---------------------------------------------------------------

run_ship check-ok --check-auth
calls_are "check-auth: curl never runs" 0
rc_is "check-auth: valid auth exits 0" 0
contains "check-auth: reports the API URL" "$C/out" "API URL https://stride.example"
no_token_anywhere "check-auth: token is not printed"
if [ ! -s "$C/log/argv" ]; then pass "check-auth: makes no request"; else fail "check-auth: curl was invoked"; fi

AUTH_FILE_OVERRIDE="$TMP/auth-local-only.md" run_ship check-local --check-auth
rc_is "check-auth: a file with only a Local API Token exits 1" 1
contains "check-auth: Local-only file reports the missing token" "$C/err" "STRIDE_API_TOKEN not found"
lacks "check-auth: Local token value is not echoed" "$C/err" "stride_dev_LOCAL_ONLY_TOKEN_abc"

AUTH_FILE_OVERRIDE="$TMP/no-such-auth.md" run_ship check-missing --check-auth
rc_is "check-auth: a missing auth file exits 1" 1
contains "check-auth: missing auth file is named" "$C/err" "failed to read auth from $TMP/no-such-auth.md"

# --- 2xx with a renderable body --------------------------------------------------

FAKE_CODE=201 FAKE_BODY="$TMP/created.json" run_ship ok "$TMP/batch.json"
calls_are "2xx: curl runs exactly once (no retry)" 1
rc_is "2xx: exits 0" 0
contains "2xx: renders the goal row" "$C/out" "     G77  Goal one"
contains "2xx: renders a task row under its goal" "$C/out" "    W901    Task one"
contains "2xx: renders a defect row" "$C/out" "     D12    Task two"
contains "2xx: prints the terminal message" "$C/out" "Batch shipped successfully."
no_token_anywhere "2xx: token is absent from argv, stdout and stderr"
contains "2xx: token reached curl through the -K config on stdin" "$C/log/config" "header = \"Authorization: Bearer $TOKEN\""
if grep -qx -- '-K' "$C/log/argv" && [ "$(grep -A1 -x -- '-K' "$C/log/argv" | tail -n 1)" = "-" ]; then
  pass "2xx: curl reads its config from stdin (-K -), not a file"
else
  fail "2xx: curl config is not read from stdin" "$(tr '\n' ' ' < "$C/log/argv")"
fi
if grep -qx -- '-g' "$C/log/argv"; then pass "2xx: URL globbing is off (-g)"; else fail "2xx: curl run without -g"; fi
if [ "$(cat "$C/log/payload.mode")" = "0o600" ]; then pass "2xx: payload file is mode 600"; else fail "2xx: payload mode" "$(cat "$C/log/payload.mode")"; fi
if grep -qx -- '--data-binary' "$C/log/argv" && grep -q '^@' "$C/log/argv"; then
  pass "2xx: payload is sent with --data-binary @file"
else
  fail "2xx: payload was not sent with --data-binary @file" "$(tr '\n' ' ' < "$C/log/argv")"
fi
if grep -qx -- '-d' "$C/log/argv" || grep -qx -- '--data' "$C/log/argv"; then
  fail "2xx: payload passed with -d/--data"
else
  pass "2xx: no -d/--data argument"
fi
if [ "$(head -n 1 "$C/log/argv")" = "-q" ]; then pass "2xx: -q is curl's first argument (no ~/.curlrc)"; else fail "2xx: -q is not first" "$(head -n 1 "$C/log/argv")"; fi
if grep -qx -- '-v' "$C/log/argv" || grep -qx -- '--verbose' "$C/log/argv"; then fail "2xx: curl run verbose"; else pass "2xx: curl is never run verbose"; fi
contains "2xx: POSTs to the batch endpoint" "$C/log/argv" "https://stride.example/api/tasks/batch"
lacks "2xx: source_spec is stripped from the payload" "$C/log/payload" "source_spec"
lacks "2xx: decomposition_notes is stripped from the payload" "$C/log/payload" "decomposition_notes"
contains "2xx: created_by_agent survives the strip" "$C/log/payload" '"created_by_agent": "Claude Opus 5.5"'
if grep -q '"source_spec"' "$TMP/batch.json"; then pass "2xx: the on-disk batch JSON is not modified"; else fail "2xx: on-disk batch JSON lost its audit fields"; fi
no_temp_left "2xx: every temp file is removed"

# /stridify --batch ships a batch that may have been written by hand, with no
# local audit fields at all: it must ship as-is.
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); [d.pop(k, None) for k in ("source_spec","source_spec_sha256","decomposition_notes")]; json.dump(d, open(sys.argv[2], "w"), indent=2)' "$TMP/batch.json" "$TMP/hand-batch.json"
cp "$TMP/hand-batch.json" "$TMP/hand-batch.before"
FAKE_CODE=201 FAKE_BODY="$TMP/created.json" run_ship handbatch "$TMP/hand-batch.json"
rc_is "--batch: a hand-written batch with no audit fields ships (exit 0)" 0
contains "--batch: a hand-written batch renders the created identifiers" "$C/out" "G77"
calls_are "--batch: curl runs exactly once" 1
if cmp -s "$TMP/hand-batch.before" "$TMP/hand-batch.json"; then pass "--batch: the batch file is shipped as-is, never rewritten"; else fail "--batch: the batch file was modified"; fi

FAKE_CODE=201 FAKE_BODY="$TMP/created-flat.json" run_ship flat "$TMP/batch.json"
rc_is "2xx flat shape: exits 0" 0
contains "2xx flat shape: renders the goal row" "$C/out" "     G78  Flat goal"
contains "2xx flat shape: renders the task row" "$C/out" "    W902    Flat task"

FAKE_CODE=201 FAKE_BODY="$TMP/no-ident.json" run_ship noident "$TMP/batch.json"
rc_is "2xx without identifiers: exits 0" 0
contains "2xx without identifiers: prints the do-not-re-run notice" "$C/err" "do NOT re-run /stridify"
if [ ! -s "$C/out" ]; then pass "2xx without identifiers: prints no placeholder table"; else fail "2xx without identifiers: stdout not empty" "$(cat "$C/out")"; fi

FAKE_CODE=201 FAKE_BODY="$TMP/empty-goals.json" run_ship emptygoals "$TMP/batch.json"
rc_is "2xx listing no goals: exits 0" 0
contains "2xx listing no goals: says no goals were listed" "$C/err" "listed no created goals"
lacks "2xx listing no goals: does not claim goals already exist" "$C/err" "already exist"

# --- --check-payload (/stridify --batch, before its preview) ----------------------

python3 - "$TMP/batch.json" "$TMP/notes-token.json" "$TOKEN" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1]))
doc["decomposition_notes"] = "pasted from a transcript: " + sys.argv[3]
json.dump(doc, open(sys.argv[2], "w"))
PY
run_ship checkpayload-token --check-payload "$TMP/notes-token.json"
rc_is "check-payload: a token in decomposition_notes is refused (exit 1)" 1
contains "check-payload: says nothing was shown or sent" "$C/err" "nothing was shown or sent"
no_token_anywhere "check-payload: the token is not printed"
calls_are "check-payload: curl never runs" 0
run_ship checkpayload-clean --check-payload "$TMP/batch.json"
rc_is "check-payload: a clean batch passes (exit 0)" 0
calls_are "check-payload: a clean batch makes no request" 0
run_ship checkpayload-missing --check-payload "$TMP/nope.json"
rc_is "check-payload: a missing file exits 1" 1
run_ship checkpayload-dash --check-payload -x.json
rc_is "check-payload: a path starting with '-' is a usage error" 2
no_temp_left "check-payload: leaves no temp file"

# --- the token check fails closed (lib/ship_support.py has-token) ------------------

SUPPORT="${SCRIPT_DIR}/ship_support.py"
printf 'x %s y' "$TOKEN" > "$TMP/has-token.txt"
printf '\357\273\277%s\n' "$TOKEN" | python3 "$SUPPORT" has-token "$TMP/has-token.txt"
rc_val=$?; [ "$rc_val" = 0 ] && pass "has-token: a BOM-prefixed token on stdin is still found (exit 0)" || fail "has-token: BOM-prefixed token" "rc=$rc_val"
printf '%s' "$TOKEN" | python3 "$SUPPORT" has-token "$TMP/batch.json"
rc_val=$?; [ "$rc_val" = 1 ] && pass "has-token: a clean file is reported clean (exit 1)" || fail "has-token: clean file" "rc=$rc_val"
printf 'not a token!' | python3 "$SUPPORT" has-token "$TMP/batch.json"
rc_val=$?; [ "$rc_val" = 2 ] && pass "has-token: a token outside the expected charset fails the check (exit 2)" || fail "has-token: malformed token" "rc=$rc_val"
printf '%s' "$TOKEN" | python3 "$SUPPORT" has-token "$TMP/no-such-file.json" 2>/dev/null
rc_val=$?; [ "$rc_val" = 2 ] && pass "has-token: an unreadable file fails the check (exit 2)" || fail "has-token: unreadable file" "rc=$rc_val"
if [ "$(id -u)" != "0" ]; then
  cp "$TMP/batch.json" "$TMP/unreadable.json"; chmod 000 "$TMP/unreadable.json"
  run_ship checkpayload-unreadable --check-payload "$TMP/unreadable.json"
  rc_is "check-payload: a failed token check refuses (exit 1)" 1
  contains "check-payload: says the file could not be checked" "$C/err" "could not check"
  chmod 600 "$TMP/unreadable.json"
else
  pass "check-payload: a failed token check refuses (exit 1) (skipped as root)"
  pass "check-payload: says the file could not be checked (skipped as root)"
fi

# --- failures before any request ------------------------------------------------

# The configured token pasted into task text is refused before any request.
python3 - "$TMP/batch.json" "$TMP/token-batch.json" "$TOKEN" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1]))
doc["goals"][0]["tasks"][0]["description"] = "auth is " + sys.argv[3]
json.dump(doc, open(sys.argv[2], "w"))
PY
FAKE_CODE=201 FAKE_BODY="$TMP/created.json" run_ship tokenbatch "$TMP/token-batch.json"
calls_are "token in batch: curl never runs" 0
rc_is "token in batch: exits 1" 1
contains "token in batch: says nothing was sent" "$C/err" "contains the configured Stride API token; nothing was sent"
if [ ! -s "$C/log/argv" ]; then pass "token in batch: nothing is POSTed"; else fail "token in batch: curl ran"; fi
no_token_anywhere "token in batch: the token is not printed"
no_temp_left "token in batch: every temp file is removed"

# ship.sh validates the exact payload it sends, in its own process.
printf '{"goals": []}\n' > "$TMP/invalid-batch.json"
FAKE_CODE=201 FAKE_BODY="$TMP/created.json" run_ship invalidbatch "$TMP/invalid-batch.json"
calls_are "invalid batch: curl never runs" 0
rc_is "invalid batch: exits 1" 1
contains "invalid batch: says nothing was sent" "$C/err" "failed validation; nothing was sent"
contains "invalid batch: the validator's reason is shown" "$C/err" "empty array"
if [ ! -s "$C/log/argv" ]; then pass "invalid batch: nothing is POSTed"; else fail "invalid batch: curl ran"; fi
no_temp_left "invalid batch: every temp file is removed"

printf '{"goals": [' > "$TMP/broken.json"
FAKE_CODE=201 FAKE_BODY="$TMP/created.json" run_ship badpayload "$TMP/broken.json"
rc_is "unparseable batch: exits 1" 1
contains "unparseable batch: names the payload failure" "$C/err" "failed to prepare API payload from $TMP/broken.json"
if [ ! -s "$C/log/argv" ]; then pass "unparseable batch: nothing is POSTed"; else fail "unparseable batch: curl ran"; fi
no_token_anywhere "unparseable batch: token is not printed"
no_temp_left "unparseable batch: every temp file is removed"

C="$TMP/case-notmp"
mkdir -p "$C/log"
PATH="$TMP/bin:$PATH" TMPDIR="$C/no-such-dir" FAKE_LOG_DIR="$C/log" STRIDE_AUTH_FILE="$TMP/auth.md" \
  FAKE_CODE=201 FAKE_BODY="$TMP/created.json" bash "$SHIP" "$TMP/batch.json" > "$C/out" 2> "$C/err"
echo "$?" > "$C/rc"
rc_is "unusable temp dir: exits 1" 1
contains "unusable temp dir: says so" "$C/err" "could not create a temp file"
if [ ! -s "$C/log/argv" ]; then pass "unusable temp dir: nothing is POSTed"; else fail "unusable temp dir: curl ran"; fi

STRIDE_API_TOKEN="stride_dev_INHERITED_ENV_TOKEN" FAKE_CODE=201 FAKE_BODY="$TMP/created.json" run_ship envtoken "$TMP/batch.json"
rc_is "inherited STRIDE_API_TOKEN: still ships" 0
if [ "$(cat "$C/log/env-token")" = "no" ]; then pass "inherited STRIDE_API_TOKEN: curl's environment carries no token"; else fail "inherited STRIDE_API_TOKEN: curl saw STRIDE_API_TOKEN in its environment"; fi
contains "inherited STRIDE_API_TOKEN: the auth file's token is the one sent" "$C/log/config" "Bearer $TOKEN"

# --- auth file at the git toplevel, run from a subdirectory -------------------------

AUTHREPO="$TMP/auth repo"
mkdir -p "$AUTHREPO/docs/ideation"
git -C "$AUTHREPO" init -q
cp "$TMP/auth.md" "$AUTHREPO/.stride_auth.md"
C="$TMP/case-toplevel"
mkdir -p "$C/log" "$C/tmpdir"
( cd "$AUTHREPO/docs/ideation" && env -u STRIDE_AUTH_FILE PATH="$TMP/bin:$PATH" TMPDIR="$C/tmpdir" FAKE_LOG_DIR="$C/log" \
    bash "$SHIP" --check-auth > "$C/out" 2> "$C/err" )
echo "$?" > "$C/rc"
rc_is "auth lookup: --check-auth from a subdirectory exits 0" 0
contains "auth lookup: .stride_auth.md is found at the git toplevel" "$C/out" "auth repo/.stride_auth.md"

C="$TMP/case-noauth"
mkdir -p "$C/log" "$C/tmpdir" "$TMP/no auth here"
( cd "$TMP/no auth here" && env -u STRIDE_AUTH_FILE PATH="$TMP/bin:$PATH" TMPDIR="$C/tmpdir" FAKE_LOG_DIR="$C/log" \
    bash "$SHIP" --check-auth > "$C/out" 2> "$C/err" )
echo "$?" > "$C/rc"
rc_is "auth lookup: outside a repo with no auth file in \$PWD exits 1" 1
contains "auth lookup: names the \$PWD path it tried" "$C/err" "no auth here/.stride_auth.md"

# --- 2xx with a body that cannot be rendered --------------------------------------

FAKE_CODE=201 FAKE_BODY="$TMP/notjson.txt" run_ship notjson "$TMP/batch.json"
calls_are "2xx non-JSON: curl runs exactly once (no retry)" 1
rc_is "2xx non-JSON: exits 0 (the batch exists)" 0
contains "2xx non-JSON: prints the do-not-re-run notice" "$C/err" "do NOT re-run /stridify"
contains "2xx non-JSON: shows the body verbatim" "$C/err" "OK, but this is not JSON"
lacks "2xx non-JSON: no Python traceback" "$C/err" "Traceback"
lacks "2xx non-JSON: no success message" "$C/out" "Batch shipped successfully."
no_temp_left "2xx non-JSON: every temp file is removed"

FAKE_CODE=200 FAKE_BODY="$TMP/list.json" run_ship listroot "$TMP/batch.json"
rc_is "2xx JSON of the wrong shape: exits 0" 0
contains "2xx JSON of the wrong shape: prints the do-not-re-run notice" "$C/err" "do NOT re-run /stridify"
lacks "2xx JSON of the wrong shape: no Python traceback" "$C/err" "Traceback"
if [ ! -s "$C/out" ]; then pass "2xx JSON of the wrong shape: prints no partial table"; else fail "2xx JSON of the wrong shape: stdout not empty" "$(cat "$C/out")"; fi

# --- non-2xx --------------------------------------------------------------------

FAKE_CODE=422 FAKE_BODY="$TMP/422.json" run_ship 422 "$TMP/batch.json"
calls_are "422: curl runs exactly once (no retry)" 1
rc_is "422: exits 1" 1
verbatim_body "422: header line then the body verbatim" "stride-ideation: Stride API rejected the batch (HTTP 422). Response body:" "$TMP/422.json"
no_token_anywhere "422: token is not printed"
no_temp_left "422: every temp file is removed"

FAKE_CODE=502 FAKE_BODY="$TMP/502.html" run_ship 502 "$TMP/batch.json"
calls_are "502: curl runs exactly once (no retry)" 1
rc_is "5xx: exits 1" 1
verbatim_body "5xx: header line then the body verbatim" "stride-ideation: Stride API returned HTTP 502. Response body:" "$TMP/502.html"
no_temp_left "5xx: every temp file is removed"

FAKE_CODE=500 FAKE_BODY="$TMP/500-debug.html" run_ship debug500 "$TMP/batch.json"
rc_is "5xx debug page: exits 1" 1
no_token_anywhere "5xx debug page: the echoed token is scrubbed from stderr"
contains "5xx debug page: the token is shown as [REDACTED]" "$C/err" "<dd>Bearer [REDACTED]</dd><p>raw [REDACTED]</p>"
contains "5xx debug page: any other Bearer value is scrubbed too" "$C/err" "other Bearer [REDACTED]</p>"

FAKE_CODE=302 FAKE_BODY="$TMP/302.html" run_ship 302 "$TMP/batch.json"
rc_is "3xx: exits 1" 1
verbatim_body "3xx: header line then the body verbatim" "stride-ideation: unexpected HTTP status 302. Response body:" "$TMP/302.html"

FAKE_CODE=422 FAKE_BODY="$TMP/big.json" run_ship big "$TMP/batch.json"
rc_is "large 422 body: exits 1" 1
verbatim_body "large 422 body: printed verbatim in full" "stride-ideation: Stride API rejected the batch (HTTP 422). Response body:" "$TMP/big.json"

# --- transport failures -----------------------------------------------------------

FAKE_CODE=000 FAKE_EXIT=6 FAKE_STDERR="curl: (6) Could not resolve host: stride.example" run_ship dns "$TMP/batch.json"
calls_are "transport failure: curl runs exactly once (no retry)" 1
rc_is "transport failure: exits 1" 1
{ printf 'stride-ideation: HTTP request failed before the Stride API responded:\n'; printf 'curl: (6) Could not resolve host: stride.example\n'; } > "$C/expected.err"
if cmp -s "$C/expected.err" "$C/err"; then pass "transport failure: curl stderr is printed verbatim"; else fail "transport failure: stderr mismatch" "$(cat "$C/err")"; fi
no_token_anywhere "transport failure: token is not printed"
no_temp_left "transport failure: every temp file is removed"

FAKE_CODE=000 FAKE_EXIT=28 run_ship silent "$TMP/batch.json"
rc_is "silent transport failure: exits 1" 1
contains "silent transport failure: names curl's exit status" "$C/err" "curl exited with status 28 and no stderr output."

# A token with the Base64 characters real Stride tokens carry, echoed back in
# transformed forms a server or proxy might use.
SLASH_TOKEN="stride_dev_Ab/Cd+Ef=Gh/IjKl"
cat > "$TMP/auth-slash.md" <<EOF
- **API URL:** \`https://stride.example\`
- **API Token:** \`$SLASH_TOKEN\`
EOF
python3 - "$SLASH_TOKEN" "$TMP/500-encoded.html" <<'PY'
import sys, urllib.parse
tok, out = sys.argv[1], sys.argv[2]
body = ("json-escaped: " + tok.replace("/", "\\/") + "\n"
        + "percent-upper: " + urllib.parse.quote(tok, safe="") + "\n"
        + "percent-lower: " + urllib.parse.quote(tok, safe="").replace("%2F", "%2f").replace("%2B", "%2b").replace("%3D", "%3d") + "\n"
        + "truncated: " + tok[:20] + "\n"
        + "header: Bearer%20" + urllib.parse.quote(tok, safe="") + "\n")
open(out, "w").write(body)
PY
AUTH_FILE_OVERRIDE="$TMP/auth-slash.md" FAKE_CODE=500 FAKE_BODY="$TMP/500-encoded.html" run_ship encoded "$TMP/batch.json"
rc_is "5xx encoded echoes: exits 1" 1
if python3 - "$SLASH_TOKEN" "$C/err" <<'PY'
import sys, urllib.parse
tok, err = sys.argv[1], open(sys.argv[2]).read()
q = urllib.parse.quote(tok, safe="")
leaks = [f for f in (tok, tok.replace("/", "\\/"), q, q.lower(), tok[:20], "Ab/Cd", "Ab%2FCd") if f in err]
sys.exit(1 if leaks else 0)
PY
then
  pass "5xx encoded echoes: JSON-escaped, percent-encoded and truncated token forms are all scrubbed"
else
  fail "5xx encoded echoes: a transformed token form reached stderr"
fi
contains "5xx encoded echoes: the surrounding text is kept" "$C/err" "json-escaped: [REDACTED]"

# --- caller-enabled tracing --------------------------------------------------------

C="$TMP/case-xtrace-check"
mkdir -p "$C/log" "$C/tmpdir"
PATH="$TMP/bin:$PATH" TMPDIR="$C/tmpdir" FAKE_LOG_DIR="$C/log" STRIDE_AUTH_FILE="$TMP/auth.md" \
  bash -x "$SHIP" --check-auth > "$C/out" 2> "$C/err"
echo "$?" > "$C/rc"
rc_is "bash -x --check-auth: exits 0" 0
no_token_anywhere "bash -x --check-auth: xtrace prints no token"

C="$TMP/case-xtrace-post"
mkdir -p "$C/log" "$C/tmpdir"
(
  set -x
  export SHELLOPTS
  PATH="$TMP/bin:$PATH" TMPDIR="$C/tmpdir" FAKE_LOG_DIR="$C/log" STRIDE_AUTH_FILE="$TMP/auth.md" \
    FAKE_CODE=422 FAKE_BODY="$TMP/422.json" bash "$SHIP" "$TMP/batch.json" > "$C/out" 2> "$C/err"
  echo "$?" > "$C/rc"
) 2>/dev/null
rc_is "SHELLOPTS=xtrace POST: exits 1 on the 422" 1
no_token_anywhere "SHELLOPTS=xtrace POST: xtrace prints no token"

C="$TMP/case-allexport"
mkdir -p "$C/log" "$C/tmpdir"
PATH="$TMP/bin:$PATH" TMPDIR="$C/tmpdir" FAKE_LOG_DIR="$C/log" STRIDE_AUTH_FILE="$TMP/auth.md" \
  FAKE_CODE=201 FAKE_BODY="$TMP/created.json" bash -a "$SHIP" "$TMP/batch.json" > "$C/out" 2> "$C/err"
echo "$?" > "$C/rc"
rc_is "bash -a (allexport): still ships" 0
if [ "$(cat "$C/log/env-token")" = "no" ]; then pass "bash -a (allexport): curl's environment carries no token"; else fail "bash -a (allexport): curl saw STRIDE_API_TOKEN in its environment"; fi

# --- interrupt mid-POST -------------------------------------------------------------

for sig in INT TERM; do
  C="$TMP/case-sig-$sig"
  mkdir -p "$C/log" "$C/tmpdir"
  (
    set -m  # job control: the background ship.sh must not start with SIGINT ignored
    PATH="$TMP/bin:$PATH" TMPDIR="$C/tmpdir" FAKE_LOG_DIR="$C/log" STRIDE_AUTH_FILE="$TMP/auth.md" \
      FAKE_SLEEP=2 FAKE_CODE=201 FAKE_BODY="$TMP/created.json" \
      bash "$SHIP" "$TMP/batch.json" > "$C/out" 2> "$C/err" &
    pid=$!
    i=0
    while [ ! -e "$C/log/started" ] && [ "$i" -lt 100 ]; do sleep 0.1; i=$(( i + 1 )); done
    kill "-$sig" "$pid"
    wait "$pid"
    echo "$?" > "$C/rc"
  )
  if [ "$sig" = INT ]; then want=130; else want=143; fi
  rc_is "SIG$sig mid-POST: exits $want" "$want"
  no_temp_left "SIG$sig mid-POST: every temp file is removed"
  lacks "SIG$sig mid-POST: does not render or claim success" "$C/out" "Batch shipped successfully."
done

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
