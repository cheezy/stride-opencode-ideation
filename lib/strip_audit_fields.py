#!/usr/bin/env python3
"""Strip local-audit fields from a Stride batch JSON document.

Usage:
    python3 lib/strip_audit_fields.py <path-to-stride-batch.json>

Reads the file at the given path, removes the three local-audit fields
(`source_spec`, `source_spec_sha256`, `decomposition_notes`) that
`/stride-ideation:decompose` stamped at the root, and prints the
API-ready payload to stdout. Exits 0 on success.

The resulting JSON is what `/stride-ideation:ship` POSTs to
Stride's `/api/tasks/batch` endpoint. The three stripped fields are
useful for local audit and drift detection but the Stride API does
not accept them and silently drops them — better to strip
explicitly so the on-the-wire payload matches the API contract.

Exits 1 with a stderr message if the file cannot be read or parsed.
Field-shape validation is NOT performed here — that is the job of
`lib/validate_batch.py`. Run the validator before stripping.
"""

import json
import sys


LOCAL_AUDIT_FIELDS = ("source_spec", "source_spec_sha256", "decomposition_notes")


def main(argv: "list[str]") -> "None":
    if len(argv) != 2:
        sys.stderr.write(
            "usage: strip_audit_fields.py <path-to-stride-batch.json>\n"
        )
        sys.exit(2)

    path = argv[1]
    try:
        with open(path, "r", encoding="utf-8") as fp:
            doc = json.load(fp)
    except (OSError, json.JSONDecodeError) as exc:
        sys.stderr.write(f"stride-ideation: could not read {path}: {exc}\n")
        sys.exit(1)

    if not isinstance(doc, dict):
        sys.stderr.write(
            f"stride-ideation: top-level JSON value must be an object, "
            f"got {type(doc).__name__}\n"
        )
        sys.exit(1)

    for field in LOCAL_AUDIT_FIELDS:
        doc.pop(field, None)

    json.dump(doc, sys.stdout, indent=2)
    sys.stdout.write("\n")


if __name__ == "__main__":
    main(sys.argv)
