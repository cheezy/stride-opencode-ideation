#!/usr/bin/env python3
"""Shared helpers for lib/ship.sh and lib/ship.ps1.

Both ship scripts keep the Stride API token in their own memory only. When a
helper here needs it, the token arrives on STDIN — never on argv (visible to
`ps`) and never in the environment — and nothing here ever prints it.

Usage:
    <token on stdin> | python3 ship_support.py scrub <file>
        Copy <file> to stderr with credentials replaced by [REDACTED]: the
        token itself, also in JSON-escaped (\\/) or percent-encoded form;
        anything shaped like a Stride token (stride_<env>_<base64>, which also
        catches a truncated echo); and the value of any "Bearer <value>".
    <token on stdin> | python3 ship_support.py has-token <file>
        Exit 0 when <file> contains the token (raw or JSON-escaped), 1 when
        it does not, 2 when the check could not be made (unreadable file, a
        token outside read_auth.py's character set, any error). Callers treat
        ONLY 1 as clean, so a failed check refuses rather than sends. Prints
        nothing about the token either way.
    python3 ship_support.py strip <batch.json> <payload.json>
        Write the API payload (the batch without its local-audit fields, as
        lib/strip_audit_fields.py prints it) to <payload.json> as UTF-8. Used
        by ship.ps1, whose `>` redirect would re-encode a native command's
        output (UTF-16 on Windows PowerShell 5.1).
    python3 ship_support.py render <response.json>
        Print the created-identifiers table. Exit 3 when the 2xx body cannot be
        rendered, 4 when it lists no goals. The whole table is built before
        anything is printed, so an unexpected shape never leaves half a table.

A trailing CR/LF and a leading UTF-8 byte-order mark on stdin are ignored:
PowerShell appends a newline when it pipes a string to a native command (and
can prepend a BOM, depending on $OutputEncoding), and a token contains
neither.
"""

import json
import re
import sys


TOKEN_SHAPE = re.compile(rb"[A-Za-z0-9_./+=-]*")


def read_token() -> bytes:
    token = sys.stdin.buffer.read().rstrip(b"\r\n")
    if token.startswith(b"\xef\xbb\xbf"):
        token = token[3:]
    return token


def scrub(path: str) -> None:
    token = read_token()
    with open(path, "rb") as fp:
        body = fp.read()
    if token:
        # One pattern per token character: a literal, its %XX escape in either
        # hex case, and for "/" the JSON-escaped "\/" too.
        parts = []
        for byte in token:
            ch = chr(byte)
            alts = [re.escape(bytes([byte]))]
            if not ch.isalnum() and ch != "_":
                alts.append(b"%%%02X" % byte)
                alts.append(b"%%%02x" % byte)
            if ch == "/":
                alts.append(rb"\\/")
            parts.append(b"(?:" + b"|".join(alts) + b")")
        body = re.sub(b"".join(parts), b"[REDACTED]", body)
    body = re.sub(rb"stride_[a-z]{2,10}_[A-Za-z0-9+/=%\\_.-]{8,}", b"[REDACTED]", body)
    body = re.sub(rb"(?i)(bearer(?:\s|%20|&nbsp;)+)[^\s\x22\x27<>]+", rb"\1[REDACTED]", body)
    sys.stderr.buffer.write(body)
    sys.stderr.buffer.flush()


def has_token(path: str) -> None:
    # Fail closed: anything other than a definite "not found" is exit 0 or 2.
    try:
        token = read_token()
        if not token or not TOKEN_SHAPE.fullmatch(token):
            sys.exit(2)
        with open(path, "rb") as fp:
            body = fp.read()
        if token in body or token.replace(b"/", b"\\/") in body:
            sys.exit(0)
        sys.exit(1)
    except SystemExit:
        raise
    except Exception:
        sys.exit(2)


def ident(item) -> str:
    value = item.get("identifier") if isinstance(item, dict) else None
    if not isinstance(value, str) or not value:
        sys.exit(3)
    return value


def render(path: str) -> None:
    try:
        with open(path, "r", encoding="utf-8-sig") as fp:
            data = json.load(fp)
    except (OSError, ValueError):
        sys.exit(3)
    # The server answers {"success": true, "total": N, "goals": [{"goal": {...},
    # "child_tasks": [...]}, ...]} (docs/api/post_tasks_batch.md). Older and
    # test responses put identifier/title/tasks directly on each goal entry,
    # and may wrap everything in "data". Accept both; anything else is
    # unrenderable.
    container = data.get("data", data) if isinstance(data, dict) else None
    goals = container.get("goals") if isinstance(container, dict) else None
    if not isinstance(goals, list):
        sys.exit(3)
    if not goals:
        sys.exit(4)
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


def strip(src: str, dst: str) -> None:
    from strip_audit_fields import LOCAL_AUDIT_FIELDS
    try:
        with open(src, "r", encoding="utf-8") as fp:
            doc = json.load(fp)
    except (OSError, ValueError) as exc:
        sys.stderr.write(f"stride-ideation: could not read {src}: {exc}\n")
        sys.exit(1)
    if not isinstance(doc, dict):
        sys.stderr.write(
            f"stride-ideation: top-level JSON value must be an object, got {type(doc).__name__}\n"
        )
        sys.exit(1)
    for field in LOCAL_AUDIT_FIELDS:
        doc.pop(field, None)
    with open(dst, "w", encoding="utf-8") as fp:
        json.dump(doc, fp, indent=2)
        fp.write("\n")


def main(argv) -> None:
    if len(argv) == 4 and argv[1] == "strip":
        strip(argv[2], argv[3])
        return
    if len(argv) != 3 or argv[1] not in ("scrub", "has-token", "render"):
        sys.stderr.write("usage: ship_support.py scrub|has-token|render <file> | strip <batch> <payload>\n")
        sys.exit(2)
    {"scrub": scrub, "has-token": has_token, "render": render}[argv[1]](argv[2])


if __name__ == "__main__":
    main(sys.argv)
