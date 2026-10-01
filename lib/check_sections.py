#!/usr/bin/env python3
"""Check that a stride-ideation requirements doc has all seven gated sections.

Usage:
    python3 lib/check_sections.py <path-to-requirements.md>

The seven hard-gated sections are level-2 headings:

    Problem, Goal, Outcome, Assumptions, Constraints, Non-goals,
    Success metrics

Headings are matched case-insensitively and with trailing whitespace
ignored, so "## Success Metrics" (the skill's spelling) and
"## Success metrics" (the template's) both count. Only level-2 headings
count — "### Goal" does not — and headings inside ``` or ~~~ code fences
are ignored. Order is not enforced.

Exit codes:
  0  all seven sections present (no output)
  1  one or more missing — stderr names them, comma-separated, in canonical
     order:  stride-ideation: requirements doc is missing required
             section(s): Outcome, Success metrics
     (also 1 when the file cannot be read)
  2  usage error

The doc is only read, never modified.
"""

import re
import sys

REQUIRED = (
    "Problem",
    "Goal",
    "Outcome",
    "Assumptions",
    "Constraints",
    "Non-goals",
    "Success metrics",
)

HEADING = re.compile(r"^##[ \t]+(.+?)[ \t]*$")
FENCE = re.compile(r"^[ ]{0,3}(`{3,}|~{3,})(.*)$")


def present_sections(text: str) -> "set[str]":
    found = set()
    fence = None
    for line in text.splitlines():
        m = FENCE.match(line)
        if fence is None:
            if m:
                fence = m.group(1)  # the full opening run, e.g. ```` or ~~~
                continue
        else:
            # CommonMark: a fence closes only on a run of the same character
            # at least as long as the opening one, with nothing after it.
            if (m and m.group(1)[0] == fence[0]
                    and len(m.group(1)) >= len(fence) and not m.group(2).strip()):
                fence = None
            continue
        h = HEADING.match(line)
        if h:
            found.add(h.group(1).strip().casefold())
    return found


def main(argv: "list[str]") -> "None":
    if len(argv) != 2:
        sys.stderr.write("usage: check_sections.py <path-to-requirements.md>\n")
        sys.exit(2)
    path = argv[1]
    try:
        with open(path, "r", encoding="utf-8") as fp:
            text = fp.read()
    except (OSError, UnicodeDecodeError) as exc:
        sys.stderr.write(f"stride-ideation: could not read {path}: {exc}\n")
        sys.exit(1)
    found = present_sections(text)
    missing = [name for name in REQUIRED if name.casefold() not in found]
    if missing:
        sys.stderr.write(
            "stride-ideation: requirements doc is missing required section(s): "
            + ", ".join(missing)
            + "\n"
        )
        sys.exit(1)


if __name__ == "__main__":
    main(sys.argv)
