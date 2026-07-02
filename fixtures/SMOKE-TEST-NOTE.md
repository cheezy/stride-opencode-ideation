# Smoke-test note

Captured at `2026-05-12T19:42:00Z` against the upstream `stride-ideation` plugin checkout and ported verbatim. The end-to-end pipeline composition was verified upstream via `lib/run_smoke_test.sh` in dry mode (no network call, no real tasks created). Live mode is available via `--live <batch.json>` (bash) or `-Live <batch.json>` (PowerShell mirror) but was not exercised during this capture per the W422 pitfall "Do not test against prod Stride." On Windows, run the smoke test via `pwsh -File lib\run_smoke_test.ps1`.

## What was verified (dry mode, `lib/run_smoke_test.sh`)

| Stage | Helper | Outcome |
|---|---|---|
| 1 | `lib/validate_batch.py` against `fixtures/2026-05-12T120000-dark-mode-toggle-stride-batch.json` | accepted (no validator errors) |
| 2 | `lib/drift_check.py` against the same fixture | no drift (stamped `source_spec_sha256` matches the recomputed SHA of `fixtures/2026-05-12T120000-dark-mode-toggle-requirements.md`) |
| 3 | `lib/read_auth.py` against a fixture `.stride_auth.md` | extracts `STRIDE_API_URL` and the `API Token` line (NOT the `Local API Token` line — the negative-lookbehind in `read_auth.py` does the right thing) |
| 4 | `lib/strip_audit_fields.py` against the same batch | `source_spec`, `source_spec_sha256`, `decomposition_notes` removed from the in-memory payload; `goals` preserved; on-disk file byte-for-byte unchanged |
| 5 | Response-rendering logic from `commands/stridify.md` (Step 10) against a canned 2xx body | renders a two-column `G/W` identifier table |
| 6 | Challenge-gate fixture shape against `fixtures/2026-05-12T120300-saved-filters-challenge-gate-requirements.md` | `## Design challenge` section present with two alternatives and a cost/risk/complexity/timeline trade-off; Assumptions carry `(high)`/`(medium)`/`(low)` confidence ratings |

Result: **14 ✓, 0 ✗**, `14 passed, 0 failed`.

## What was NOT verified in this capture

- **Stage 7: live HTTP POST to a Stride instance.** `lib/run_smoke_test.sh --live <batch.json>` exercises this stage end-to-end (read auth → strip → POST → render real response). It was not run during this capture because the available Stride instance (`https://www.stridelikeaboss.com`) is the human's production workspace, not a dedicated dev environment. The W422 pitfall explicitly warned against testing against prod.

- **Interactive `/ideate` Q&A loop.** The ideation protocol drives a multi-turn question-and-answer conversation via OpenCode's question UI that cannot be exercised from a non-interactive smoke-test runner. Coverage of that flow is a human-driven end-to-end run: `/ideate` in an OpenCode session through to the committed requirements doc, then `/stridify` against it — the command walkthroughs in the top-level `README.md` describe both.

## How to re-run

```bash
# Dry mode (safe — no network call):
./lib/run_smoke_test.sh

# Live mode — POSTs to the Stride API using the auth in
# ${CLAUDE_PROJECT_DIR:-$PWD}/.stride_auth.md (the project dir when set,
# falling back to the current directory — the same resolution
# commands/stridify.md Step 3 uses).
# Use a dev Stride instance. Created tasks are NOT auto-cleaned.
./lib/run_smoke_test.sh --live fixtures/2026-05-12T120000-dark-mode-toggle-stride-batch.json
```

The interactive `/ideate` flow has to be re-run by a human in an OpenCode session — the top-level `README.md` walks through the command.

## Why a fixture batch JSON instead of a fresh ideate run

`fixtures/2026-05-12T120000-dark-mode-toggle-stride-batch.json` is the smallest of the three v0.2 fixtures (1 goal, 5 tasks). It pairs with `fixtures/2026-05-12T120000-dark-mode-toggle-requirements.md` and was authored explicitly to serve this purpose. Using it for the smoke test means:

- The smoke test runs deterministically — the same fixture every time, no Q&A variability.
- The fixture is already exercised by the v0.2 validator + drift-check + fixture-pairing tests, so any regression in those helpers also surfaces here.
- The live mode (`--live`) creates exactly one goal and five tasks per run, which is small enough to clean up by hand and big enough to demonstrate the end-to-end shape.

## What success looks like in live mode

If you do run `--live`, the expected output is approximately:

```
Stage 7: LIVE POST to the Stride API (NOTE: creates real tasks)
  ✓  live POST returned HTTP 201

Created identifiers:
   GXX  Add a dark mode toggle to the app header
  WXXX    Migrate hardcoded colors in core_components to daisyUI semantic tokens
  WXXX    Migrate hardcoded colors in delayed_modal to daisyUI semantic tokens
  WXXX    Add user_preferences.theme column for dark mode persistence
  WXXX    Add theme_toggle LiveView component and wire it into the header
  WXXX    Add FOUC-prevention script to read the theme preference before CSS loads
```

The exact `G` and `W` numbers depend on the receiving Stride workspace's identifier counter. The titles, complexity (small), priority (medium), and dependency edges within the goal should match the fixture batch JSON exactly.
