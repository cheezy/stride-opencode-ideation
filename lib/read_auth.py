#!/usr/bin/env python3
"""Extract Stride auth credentials from a .stride_auth.md file.

Usage:
    python3 lib/read_auth.py <path-to-.stride_auth.md>

Prints two lines to stdout (in this exact order):
    STRIDE_API_URL=<url>
    STRIDE_API_TOKEN=<token>

The calling shell can source these directly:
    eval "$(python3 lib/read_auth.py .stride_auth.md)"

Expected file format (markdown bullets with backticks):
    - **API URL:** `https://www.stridelikeaboss.com`
    - **API Token:** `stride_xxx...`

Permissive about other lines and formatting variations. Strict about
the two required fields — exits non-zero with an explicit error if
either is missing. The error message NEVER contains the token value
(security: tokens go to stdout, not stderr; stderr is the channel
the user sees on failure).
"""

import re
import sys


URL_PATTERNS = (
    # "- **API URL:** `https://...`" or "- API URL: https://..."
    re.compile(r"\*\*API URL:?\*\*\s*[`']?(https?://[^\s`']+)", re.IGNORECASE),
    re.compile(r"^\s*-?\s*API URL:?\s*`?(https?://[^\s`']+)", re.IGNORECASE | re.MULTILINE),
)

# "- **API Token:** `stride_xxx`" — match plain "API Token", NOT
# "Local API Token" or "API Token Name" (those are different keys).
TOKEN_PATTERNS = (
    re.compile(r"(?<!Local )\*\*API Token:?\*\*\s*[`']?([A-Za-z0-9_./+=-]+)", re.IGNORECASE),
    re.compile(r"^\s*-?\s*(?<!Local )API Token:?\s*`?([A-Za-z0-9_./+=-]+)", re.IGNORECASE | re.MULTILINE),
)


def find_first(patterns: "tuple", text: str) -> "str | None":
    for pat in patterns:
        m = pat.search(text)
        if m:
            return m.group(1).strip()
    return None


def main(argv: "list[str]") -> "None":
    if len(argv) != 2:
        sys.stderr.write("usage: read_auth.py <path-to-.stride_auth.md>\n")
        sys.exit(2)

    path = argv[1]
    try:
        with open(path, "r", encoding="utf-8") as fp:
            text = fp.read()
    except FileNotFoundError:
        sys.stderr.write(
            f"stride-ideation: .stride_auth.md not found at {path}.\n"
            f"\n"
            f"Create it by following the Stride onboarding instructions at\n"
            f"  https://www.stridelikeaboss.com/api/agent/onboarding\n"
            f"\n"
            f"The file should contain at minimum:\n"
            f"  - **API URL:** `https://www.stridelikeaboss.com`\n"
            f"  - **API Token:** `stride_xxx...`  (your bearer token)\n"
            f"\n"
            f"Add the file to .gitignore — it contains a secret.\n"
        )
        sys.exit(1)
    except OSError as exc:
        sys.stderr.write(
            f"stride-ideation: could not read .stride_auth.md at {path}: {exc}\n"
        )
        sys.exit(1)

    url = find_first(URL_PATTERNS, text)
    token = find_first(TOKEN_PATTERNS, text)

    if not url:
        sys.stderr.write(
            f"stride-ideation: STRIDE_API_URL not found in {path}.\n"
            f"Expected a line like:\n"
            f"  - **API URL:** `https://www.stridelikeaboss.com`\n"
            f"See the setup instructions at:\n"
            f"  https://www.stridelikeaboss.com/api/agent/onboarding\n"
        )
        sys.exit(1)

    if not token:
        # NOTE: never include the token value in stderr — even on partial
        # matches. The stderr channel is what the user sees on failure.
        sys.stderr.write(
            f"stride-ideation: STRIDE_API_TOKEN not found in {path}.\n"
            f"Expected a line like:\n"
            f"  - **API Token:** `stride_xxx...`\n"
            f"(the token line MUST NOT be prefixed by 'Local ' — that names a "
            f"different field).\n"
            f"See the setup instructions at:\n"
            f"  https://www.stridelikeaboss.com/api/agent/onboarding\n"
        )
        sys.exit(1)

    # Print as a sourceable two-line block.
    sys.stdout.write(f"STRIDE_API_URL={url}\n")
    sys.stdout.write(f"STRIDE_API_TOKEN={token}\n")


if __name__ == "__main__":
    main(sys.argv)
