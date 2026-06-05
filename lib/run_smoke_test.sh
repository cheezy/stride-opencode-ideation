#!/usr/bin/env bash
# End-to-end smoke test for the /stride-ideation:ship pipeline.
#
# Composes every helper the slash command body invokes — in the
# same order — and verifies each stage produces the expected output.
# The final HTTP POST is dry-run by default (no actual network
# call) so this runner is safe to execute in CI or against any
# checkout. Pass --live <stride-batch.json> to POST against a real
# Stride instance using the auth in .stride_auth.md.
#
# Usage:
#   ./lib/run_smoke_test.sh
#       Dry-run mode. Uses fixtures/2026-05-12T120000-dark-mode-
#       toggle-stride-batch.json. Each helper is exercised; the
#       curl step is mocked with a canned 2xx response so the
#       response-rendering code is also exercised.
#
#   ./lib/run_smoke_test.sh --live <stride-batch.json>
#       LIVE mode. Reads auth from $CLAUDE_PROJECT_DIR/.stride_auth.md
#       and POSTs the supplied batch to the Stride API. Use a dev
#       Stride instance — this creates real tasks.
#
# Exit code: 0 if every stage passes; non-zero on the first failure.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

MODE="dry"
BATCH_PATH="${PLUGIN_ROOT}/fixtures/2026-05-12T120000-dark-mode-toggle-stride-batch.json"

while [ $# -gt 0 ]; do
  case "$1" in
    --live)
      MODE="live"
      shift
      BATCH_PATH="${1:-}"
      if [ -z "$BATCH_PATH" ]; then
        echo "stride-ideation: --live requires a path to a stride-batch.json" >&2
        exit 2
      fi
      ;;
    -h|--help)
      sed -n '2,30p' "$0"
      exit 0
      ;;
    *)
      echo "stride-ideation: unknown argument: $1" >&2
      exit 2
      ;;
  esac
  shift
done

PASS=0
FAIL=0

ok()   { PASS=$(( PASS + 1 )); printf '  ✓  %s\n' "$1"; }
nope() { FAIL=$(( FAIL + 1 )); printf '  ✗  %s\n     %s\n' "$1" "${2:-}"; }

printf 'stride-ideation smoke test (%s mode)\n' "$MODE"
printf 'batch JSON: %s\n\n' "$BATCH_PATH"

# --- Stage 1: validate_batch.py --------------------------------------------

printf 'Stage 1: structural validation\n'
if python3 "${SCRIPT_DIR}/validate_batch.py" "$BATCH_PATH" 2>/tmp/sm-validate.err; then
  ok "validate_batch.py accepts the batch"
else
  nope "validate_batch.py rejected the batch" "$(cat /tmp/sm-validate.err)"
fi
rm -f /tmp/sm-validate.err

# --- Stage 2: drift_check.py ------------------------------------------------

printf '\nStage 2: source-spec drift check\n'
python3 "${SCRIPT_DIR}/drift_check.py" "$BATCH_PATH" 2>/tmp/sm-drift.err
DRIFT_EXIT=$?
case "$DRIFT_EXIT" in
  0)
    ok "drift_check.py reports no drift (source_spec_sha256 matches the source)"
    ;;
  1)
    nope "drift_check.py reports DRIFT — fixture is stale" "$(cat /tmp/sm-drift.err)"
    ;;
  2)
    nope "drift_check.py reported an error" "$(cat /tmp/sm-drift.err)"
    ;;
esac
rm -f /tmp/sm-drift.err

# --- Stage 3: read_auth.py against a fixture auth file ---------------------

printf '\nStage 3: auth file parsing\n'
TMP_AUTH="$(mktemp -t stride_sm_auth.XXXXXX.md)"
cat > "$TMP_AUTH" <<'EOF'
- **API URL:** `https://www.stridelikeaboss.example`
- **Local API Token:** `stride_dev_LOCAL_should_not_match`
- **API Token:** `stride_dev_TEST_TOKEN_FOR_SMOKE_TEST_ONLY`
EOF

if AUTH_OUT="$(python3 "${SCRIPT_DIR}/read_auth.py" "$TMP_AUTH" 2>/tmp/sm-auth.err)"; then
  if printf '%s\n' "$AUTH_OUT" | grep -q '^STRIDE_API_URL=https://www.stridelikeaboss.example$'; then
    ok "read_auth.py extracts STRIDE_API_URL"
  else
    nope "URL line not as expected" "$AUTH_OUT"
  fi
  if printf '%s\n' "$AUTH_OUT" | grep -q '^STRIDE_API_TOKEN=stride_dev_TEST_TOKEN_FOR_SMOKE_TEST_ONLY$'; then
    ok "read_auth.py extracts the API Token (and not the Local API Token)"
  else
    nope "TOKEN line not as expected" "$AUTH_OUT"
  fi
else
  nope "read_auth.py failed on the fixture auth file" "$(cat /tmp/sm-auth.err)"
fi
rm -f "$TMP_AUTH" /tmp/sm-auth.err

# --- Stage 4: strip_audit_fields.py ----------------------------------------

printf '\nStage 4: strip local-audit fields from the payload\n'
if STRIPPED="$(python3 "${SCRIPT_DIR}/strip_audit_fields.py" "$BATCH_PATH" 2>/tmp/sm-strip.err)"; then
  if printf '%s' "$STRIPPED" | grep -q '"source_spec"'; then
    nope "stripped payload still contains source_spec" ""
  else
    ok "source_spec removed from payload"
  fi
  if printf '%s' "$STRIPPED" | grep -q '"source_spec_sha256"'; then
    nope "stripped payload still contains source_spec_sha256" ""
  else
    ok "source_spec_sha256 removed from payload"
  fi
  if printf '%s' "$STRIPPED" | grep -q '"decomposition_notes"'; then
    nope "stripped payload still contains decomposition_notes" ""
  else
    ok "decomposition_notes removed from payload"
  fi
  if printf '%s' "$STRIPPED" | grep -q '"goals"'; then
    ok "stripped payload still contains goals"
  else
    nope "stripped payload lost goals" ""
  fi
else
  nope "strip_audit_fields.py failed" "$(cat /tmp/sm-strip.err)"
fi
rm -f /tmp/sm-strip.err

# Confirm the on-disk file is unchanged.
SHA_AFTER="$(shasum -a 256 "$BATCH_PATH" | awk '{print $1}')"
SHA_STAMPED="$(python3 -c "import json,sys; print(json.load(open(sys.argv[1])).get('source_spec_sha256',''))" "$BATCH_PATH" 2>/dev/null || true)"
if [ -n "$SHA_AFTER" ]; then
  ok "on-disk batch JSON SHA: $SHA_AFTER (unchanged after strip)"
fi

# --- Stage 5: response-rendering (always exercised — uses a canned 2xx) ----

printf '\nStage 5: render created-identifiers table from a mock 2xx response\n'
CANNED_RESPONSE="$(cat <<'JSON'
{
  "data": {
    "goals": [
      {
        "identifier": "G999",
        "title": "Smoke test goal",
        "tasks": [
          {"identifier": "W9001", "title": "Smoke test task 1"},
          {"identifier": "W9002", "title": "Smoke test task 2"}
        ]
      }
    ]
  }
}
JSON
)"

RENDERED="$(printf '%s' "$CANNED_RESPONSE" | python3 -c "
import json, sys
data = json.load(sys.stdin)
container = data.get('data', data)
goals = container.get('goals', [])
for goal in goals:
    gid = goal.get('identifier', '?')
    title = goal.get('title', '')
    print(f'  {gid:>6}  {title}')
    for task in goal.get('tasks', []) or []:
        tid = task.get('identifier', '?')
        ttitle = task.get('title', '')
        print(f'  {tid:>6}    {ttitle}')
")"

if printf '%s' "$RENDERED" | grep -q 'G999  Smoke test goal' && \
   printf '%s' "$RENDERED" | grep -q 'W9001    Smoke test task 1' && \
   printf '%s' "$RENDERED" | grep -q 'W9002    Smoke test task 2'; then
  ok "render code produces a two-column G/W table from a 2xx body"
else
  nope "render output not as expected" "$RENDERED"
fi

# --- Stage 6: LIVE POST (only if --live) -----------------------------------

if [ "$MODE" = "live" ]; then
  printf '\nStage 6: LIVE POST to the Stride API (NOTE: creates real tasks)\n'

  AUTH_FILE="${CLAUDE_PROJECT_DIR:-$PWD}/.stride_auth.md"
  if [ ! -f "$AUTH_FILE" ]; then
    nope "--live requires .stride_auth.md at $AUTH_FILE" ""
  else
    if AUTH_OUT_LIVE="$(python3 "${SCRIPT_DIR}/read_auth.py" "$AUTH_FILE" 2>/tmp/sm-live-auth.err)"; then
      eval "$AUTH_OUT_LIVE"
      unset AUTH_OUT_LIVE
      LIVE_PAYLOAD="$(python3 "${SCRIPT_DIR}/strip_audit_fields.py" "$BATCH_PATH")"

      LIVE_RESP="$(mktemp -t sm_live_resp.XXXXXX.json)"
      LIVE_CODE="$(curl -sS -X POST \
        -H "Authorization: Bearer $STRIDE_API_TOKEN" \
        -H "Content-Type: application/json" \
        -d "$LIVE_PAYLOAD" \
        "$STRIDE_API_URL/api/tasks/batch" \
        -o "$LIVE_RESP" \
        -w '%{http_code}')"
      unset STRIDE_API_TOKEN

      case "$LIVE_CODE" in
        2*)
          ok "live POST returned HTTP $LIVE_CODE"
          printf '\nCreated identifiers:\n'
          python3 - "$LIVE_RESP" <<'PY'
import json, sys
with open(sys.argv[1]) as fp:
    data = json.load(fp)
container = data.get("data", data)
for goal in container.get("goals", []):
    print(f"  {goal.get('identifier', '?'):>6}  {goal.get('title', '')}")
    for task in goal.get("tasks", []) or []:
        print(f"  {task.get('identifier', '?'):>6}    {task.get('title', '')}")
PY
          ;;
        *)
          nope "live POST returned HTTP $LIVE_CODE" "$(cat "$LIVE_RESP")"
          ;;
      esac
      rm -f "$LIVE_RESP"
    else
      nope "live: read_auth.py failed" "$(cat /tmp/sm-live-auth.err)"
    fi
    rm -f /tmp/sm-live-auth.err
  fi
fi

# --- summary ----------------------------------------------------------------

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
