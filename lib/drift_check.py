#!/usr/bin/env python3
"""Check whether a Stride batch JSON's source_spec has drifted from its
stamped source_spec_sha256.

Usage:
    python3 lib/drift_check.py <path-to-stride-batch.json>

Exit codes:
    0  no drift OR no source_spec stamped (proceed silently)
    1  drift detected: stderr contains a human-readable warning
       naming source_spec, the stamped SHA, and the recomputed SHA
    2  source_spec stamped but the referenced file can't be read or hashed
       (stderr contains the underlying error)

The helper does NOT prompt the user — that is the slash-command body's
concern. The helper's job is purely detection: report drift or no drift
via exit code, and surface a precise diagnostic on stderr.

Behavior contract:

  - If `source_spec` is absent from the JSON root → exit 0 with no
    output. Hand-written-JSON path; drift detection does not apply.

  - If `source_spec` is present but `source_spec_sha256` is absent →
    exit 0 with no output. We do not have a baseline to compare against;
    treat the same as the hand-written case.

  - If both fields are present, resolve `source_spec` to a real path:
       * If absolute, use as-is.
       * Otherwise, resolve relative to the BATCH JSON file's directory
         first; if not found, fall back to the current working
         directory. Surface a clear error if neither resolves.

  - Compute SHA-256 of the resolved file and compare against the
    stamped value (both lowered for case-insensitive comparison).

  - Match → exit 0 with no output.
  - Mismatch → exit 1 with a multi-line stderr warning.

The helper deliberately does NOT enforce field-shape validity beyond
the bare minimum (string fields). Use `lib/validate_batch.py` for that.
"""

import hashlib
import json
import os
import sys


def fail(message: str, exit_code: int) -> "None":
    sys.stderr.write(message)
    if not message.endswith("\n"):
        sys.stderr.write("\n")
    sys.exit(exit_code)


def resolve_source_path(source_spec: str, batch_path: str) -> str:
    """Resolve a stamped source_spec to a real filesystem path.

    Try (in order): absolute, batch-JSON-directory-relative, cwd-relative.
    Returns the first path that exists. Raises FileNotFoundError otherwise.
    """
    if os.path.isabs(source_spec):
        if os.path.isfile(source_spec):
            return source_spec
        raise FileNotFoundError(source_spec)

    batch_dir = os.path.dirname(os.path.abspath(batch_path))
    candidates = [
        os.path.join(batch_dir, source_spec),
        os.path.abspath(source_spec),
    ]
    for cand in candidates:
        if os.path.isfile(cand):
            return cand
    raise FileNotFoundError(source_spec)


def sha256_of(path: str) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as fp:
        for chunk in iter(lambda: fp.read(65536), b""):
            h.update(chunk)
    return h.hexdigest()


def main(argv: "list[str]") -> "None":
    if len(argv) != 2:
        sys.stderr.write("usage: drift_check.py <path-to-stride-batch.json>\n")
        sys.exit(2)

    batch_path = argv[1]
    try:
        with open(batch_path, "r", encoding="utf-8") as fp:
            doc = json.load(fp)
    except (OSError, json.JSONDecodeError) as exc:
        fail(
            f"stride-ideation: could not read batch JSON at {batch_path}: {exc}",
            2,
        )

    if not isinstance(doc, dict):
        fail(
            f"stride-ideation: top-level JSON value must be an object, "
            f"got {type(doc).__name__}",
            2,
        )

    source_spec = doc.get("source_spec")
    stamped_sha = doc.get("source_spec_sha256")

    # Hand-written JSON path: either field absent → no check, proceed silently.
    if not source_spec or not stamped_sha:
        sys.exit(0)

    if not isinstance(source_spec, str) or not isinstance(stamped_sha, str):
        fail(
            f"stride-ideation: source_spec and source_spec_sha256 must be "
            f"strings; got source_spec={type(source_spec).__name__}, "
            f"source_spec_sha256={type(stamped_sha).__name__}",
            2,
        )

    try:
        resolved = resolve_source_path(source_spec, batch_path)
    except FileNotFoundError:
        fail(
            f"stride-ideation: source_spec '{source_spec}' could not be "
            f"resolved (tried absolute, batch-JSON-dir-relative, and "
            f"cwd-relative). The stamped requirements doc may have been "
            f"moved or deleted.",
            2,
        )

    try:
        actual_sha = sha256_of(resolved)
    except OSError as exc:
        fail(
            f"stride-ideation: could not hash source_spec at {resolved}: {exc}",
            2,
        )

    if actual_sha.lower() == stamped_sha.lower():
        # No drift.
        sys.exit(0)

    # Drift detected.
    msg = (
        f"stride-ideation: DRIFT DETECTED — source_spec has changed "
        f"since the batch JSON was decomposed.\n"
        f"  source_spec:         {source_spec}\n"
        f"  resolved to:         {resolved}\n"
        f"  stamped SHA-256:     {stamped_sha}\n"
        f"  recomputed SHA-256:  {actual_sha}\n"
    )
    fail(msg, 1)


if __name__ == "__main__":
    main(sys.argv)
