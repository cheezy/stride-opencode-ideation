#!/usr/bin/env bash
# stride-ideation: ship a validated batch JSON to Stride in ONE process.
#
# Usage:
#   bash lib/ship.sh --check-auth      # Step 3 preflight: read auth, POST nothing
#   bash lib/ship.sh <batch.json>      # Steps 9-10: strip, POST, branch, render
#
# Auth file: $STRIDE_AUTH_FILE if set, else .stride_auth.md at the git toplevel
# of the working directory (so a run from a subdirectory still finds it), or
# in $PWD outside a git repository.
#
# Why one script: /stridify's Steps 3, 9 and 10 used to be separate bash
# fragments the model ran in separate Bash tool calls. Shell state does not
# persist between those calls, so the token had to be re-read (or pasted) for
# the POST, and the fragments put it on curl's command line. Here the token
# lives only in this shell's memory and in a pipe to curl:
#
#   - never on any process's argv (argv is visible to `ps`), never in a file,
#     and never in a child's environment (an inherited export is dropped);
#   - never on stdout or stderr: xtrace is forced off, and every response body
#     or curl message printed is first scrubbed of the token and of any
#     `Bearer <value>` (a dev server's debug error page echoes request
#     headers);
#   - the payload goes out with --data-binary from a file, not -d "<json>";
#   - every temp file (payload, response, curl stderr) is created mode 600
#     under the system temp dir and removed on success, failure and interrupt.
#
# The payload is validated with lib/validate_batch.py in this process before
# anything is sent.
#
# Exit codes:
#   0  shipped (2xx) — including a 2xx whose body could not be rendered, which
#      prints a do-not-re-run notice: the batch exists, re-running would
#      create it twice
#   1  auth unreadable, payload unpreparable, transport failure, or non-2xx
#   2  usage error
#   129/130/143  interrupted (HUP/INT/TERM); if the POST was in flight the
#      batch may exist
#
# The POST is never retried: Stride does not guarantee idempotency on a
# partially-failed batch.

# A caller's `bash -x` or exported SHELLOPTS=xtrace would print every line
# that handles the token, and `bash -a` / SHELLOPTS=allexport would export it
# into every child's environment. Turn all three off before anything runs.
set +xva
set -u
umask 077

# Drop any inherited copy: eval below would otherwise update an EXPORTED
# variable, and every child started afterwards would carry the token in its
# environment (readable with `ps -E`).
unset STRIDE_API_TOKEN STRIDE_API_URL

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PAYLOAD_FILE=""
RESPONSE_FILE=""
CURL_ERR_FILE=""

cleanup() {
  local f
  for f in "$PAYLOAD_FILE" "$RESPONSE_FILE" "$CURL_ERR_FILE"; do
    [ -n "$f" ] && rm -f -- "$f"
  done
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

usage() {
  echo "stride-ideation: usage: ship.sh --check-auth | ship.sh <batch.json>" >&2
  exit 2
}

# new_temp VAR — create a mode-600 temp file and store its path in VAR. Runs
# in this shell (not inside $(...)), so a failure really stops the script.
new_temp() {
  local f
  f="$(mktemp "${TMPDIR:-/tmp}/stride-ideation-ship.XXXXXX")" && [ -n "$f" ] || {
    echo "stride-ideation: could not create a temp file in ${TMPDIR:-/tmp}; nothing was sent" >&2
    exit 1
  }
  printf -v "$1" '%s' "$f"
}

read_auth() {
  local auth_file auth_out
  local root
  root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
  auth_file="${STRIDE_AUTH_FILE:-$root/.stride_auth.md}"
  # read_auth.py prints shell-quoted assignments, so eval cannot execute
  # anything the auth file contains. Its stderr never carries the token.
  auth_out="$(python3 "$SCRIPT_DIR/read_auth.py" "$auth_file")" || {
    echo "stride-ideation: failed to read auth from $auth_file" >&2
    exit 1
  }
  eval "$auth_out"
  unset auth_out
  # Belt and braces for the allexport case: never let these reach a child.
  export -n STRIDE_API_TOKEN STRIDE_API_URL
  AUTH_FILE="$auth_file"
}

# print_scrubbed FILE — copy FILE to stderr verbatim except that credentials
# become [REDACTED]: the token itself, also in JSON-escaped (\/) or
# percent-encoded form; anything shaped like a Stride token
# (stride_<env>_<base64>, which also catches a truncated echo); and the value
# of any "Bearer <value>". The token reaches python on stdin, never on argv
# or in its environment.
print_scrubbed() {
  printf '%s' "$STRIDE_API_TOKEN" | python3 -c '
import re, sys
token = sys.stdin.read()
with open(sys.argv[1], "rb") as fp:
    body = fp.read()
if token:
    # One pattern per token character: a literal, its %XX escape in either
    # hex case, and for "/" the JSON-escaped "\/" too.
    parts = []
    for ch in token:
        alts = [re.escape(ch.encode())]
        if not ch.isalnum() and ch != "_":
            alts.append(b"%%%02X" % ord(ch))
            alts.append(b"%%%02x" % ord(ch))
        if ch == "/":
            alts.append(rb"\\/")
        parts.append(b"(?:" + b"|".join(alts) + b")")
    body = re.sub(b"".join(parts), b"[REDACTED]", body)
body = re.sub(rb"stride_[a-z]{2,10}_[A-Za-z0-9+/=%\\_.-]{8,}", b"[REDACTED]", body)
body = re.sub(rb"(?i)(bearer(?:\s|%20|&nbsp;)+)[^\s\x22\x27<>]+", rb"\1[REDACTED]", body)
sys.stderr.buffer.write(body)
' "$1"
}

[ "$#" -eq 1 ] || usage

if [ "$1" = "--check-auth" ]; then
  read_auth
  unset STRIDE_API_TOKEN
  echo "stride-ideation: auth file OK — read from $AUTH_FILE (API URL $STRIDE_API_URL). The token is checked by the server only when the batch is POSTed."
  exit 0
fi

case "$1" in
  -*) usage ;;
esac

BATCH_PATH="$1"
if [ ! -f "$BATCH_PATH" ]; then
  echo "stride-ideation: batch JSON not found at $BATCH_PATH" >&2
  exit 1
fi

# (9a) Strip the local-audit fields into a mode-600 temp file. This runs
# before auth is read, so this child never has the token anywhere. The
# on-disk batch JSON is not modified.
new_temp PAYLOAD_FILE
python3 "$SCRIPT_DIR/strip_audit_fields.py" "$BATCH_PATH" > "$PAYLOAD_FILE" || {
  echo "stride-ideation: failed to prepare API payload from $BATCH_PATH" >&2
  exit 1
}
# Validate the exact bytes about to be sent, in this process: the file on
# disk may have changed since /stridify validated and previewed it (those
# are separate Bash calls). Advisory warnings were already
# shown at that step, so only the fatal diagnostic is surfaced here.
python3 "$SCRIPT_DIR/validate_batch.py" "$PAYLOAD_FILE" > /dev/null || {
  echo "stride-ideation: $BATCH_PATH failed validation; nothing was sent" >&2
  exit 1
}

new_temp RESPONSE_FILE
new_temp CURL_ERR_FILE

read_auth

# Refuse to send the configured API token as task content: a pasted recovery
# transcript or a decomposer that read the wrong file could carry it into the
# batch, which is POSTed where every board member can read it. The token
# reaches python on stdin, never argv or env; matches print no value.
if ! printf '%s' "$STRIDE_API_TOKEN" | python3 -c '
import sys
token = sys.stdin.read()
body = open(sys.argv[1], "rb").read()
if token and (token.encode() in body or token.replace("/", "\\/").encode() in body):
    sys.exit(1)
' "$PAYLOAD_FILE"; then
  echo "stride-ideation: the batch contains the configured Stride API token; nothing was sent. Remove it from $BATCH_PATH and retry." >&2
  exit 1
fi

# (9b) The Authorization header reaches curl as a config on its stdin
# (-K -), written by the printf builtin: no argv, no file. -q must come
# first so ~/.curlrc cannot switch on --verbose/--trace; -g stops a {} or []
# in the URL from expanding into more than one POST.
token_escaped="${STRIDE_API_TOKEN//\\/\\\\}"
token_escaped="${token_escaped//\"/\\\"}"
HTTP_CODE="$(
  printf 'header = "Authorization: Bearer %s"\n' "$token_escaped" |
    curl -q -g -sS -X POST \
      -K - \
      -H "Content-Type: application/json" \
      --data-binary "@$PAYLOAD_FILE" \
      -o "$RESPONSE_FILE" \
      -w '%{http_code}' \
      "${STRIDE_API_URL%/}/api/tasks/batch" \
      2>"$CURL_ERR_FILE"
)"
CURL_EXIT=$?
unset token_escaped

if [ "$CURL_EXIT" -ne 0 ] || [ -z "$HTTP_CODE" ] || [ "$HTTP_CODE" = "000" ]; then
  echo "stride-ideation: HTTP request failed before the Stride API responded:" >&2
  if [ -s "$CURL_ERR_FILE" ]; then
    print_scrubbed "$CURL_ERR_FILE"
  else
    echo "stride-ideation:   curl exited with status $CURL_EXIT and no stderr output." >&2
  fi
  exit 1
fi

# (9c) Every non-2xx prints the response body verbatim (token-scrubbed) and
# exits non-zero.
case "$HTTP_CODE" in
  2*)
    ;;
  4*)
    echo "stride-ideation: Stride API rejected the batch (HTTP $HTTP_CODE). Response body:" >&2
    print_scrubbed "$RESPONSE_FILE"
    echo >&2
    exit 1
    ;;
  5*)
    echo "stride-ideation: Stride API returned HTTP $HTTP_CODE. Response body:" >&2
    print_scrubbed "$RESPONSE_FILE"
    echo >&2
    exit 1
    ;;
  *)
    echo "stride-ideation: unexpected HTTP status $HTTP_CODE. Response body:" >&2
    print_scrubbed "$RESPONSE_FILE"
    echo >&2
    exit 1
    ;;
esac

# (10) Render the created identifiers. The table is built in full before
# anything is printed, so an unexpected shape never leaves half a table.
# Exit 3: 2xx but not renderable. Exit 4: 2xx listing no goals at all.
python3 - "$RESPONSE_FILE" <<'PY'
import json
import sys

try:
    with open(sys.argv[1], "r", encoding="utf-8") as fp:
        data = json.load(fp)
except (OSError, ValueError):
    sys.exit(3)

# The server answers {"success": true, "total": N, "goals": [{"goal": {...},
# "child_tasks": [...]}, ...]} (docs/api/post_tasks_batch.md). Older and
# test responses put identifier/title/tasks directly on each goal entry, and
# may wrap everything in "data". Accept both; anything else is unrenderable.
container = data.get("data", data) if isinstance(data, dict) else None
goals = container.get("goals") if isinstance(container, dict) else None
if not isinstance(goals, list):
    sys.exit(3)
if not goals:
    sys.exit(4)


def ident(item):
    value = item.get("identifier") if isinstance(item, dict) else None
    if not isinstance(value, str) or not value:
        sys.exit(3)
    return value


lines = ["", "Created goals and tasks:", ""]
for entry in goals:
    if not isinstance(entry, dict):
        sys.exit(3)
    goal = entry["goal"] if isinstance(entry.get("goal"), dict) else entry
    tasks = entry.get("child_tasks", entry.get("tasks")) or []
    if not isinstance(tasks, list):
        sys.exit(3)
    lines.append(f"  {ident(goal):>6}  {goal.get('title') or '(no title)'}")
    for task in tasks:
        lines.append(f"  {ident(task):>6}    {task.get('title') or '(no title)'}")
lines.append("")
print("\n".join(lines))
PY
RENDER_EXIT=$?

if [ "$RENDER_EXIT" -eq 0 ]; then
  echo "Batch shipped successfully."
  echo "The goals are now visible in the Stride workspace's Backlog column."
  exit 0
fi

if [ "$RENDER_EXIT" -eq 4 ]; then
  echo "stride-ideation: Stride answered HTTP $HTTP_CODE but listed no created goals. Check the Stride workspace's Backlog column before re-running. Response body:" >&2
else
  echo "stride-ideation: the batch was created (HTTP $HTTP_CODE), but the response could not be rendered — do NOT re-run /stridify: the goals already exist in Stride and a second run would create them twice." >&2
  echo "stride-ideation: check the Stride workspace's Backlog column for the created identifiers. Response body:" >&2
fi
print_scrubbed "$RESPONSE_FILE"
echo >&2
exit 0
