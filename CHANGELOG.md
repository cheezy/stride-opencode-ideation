# Changelog

All notable changes to the Stride Ideation extension for OpenCode are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.2.0] - 2026-06-17

Human-interaction improvements ported from [`cheezy/stride-ideation`](https://github.com/cheezy/stride-ideation) (G235) — the lower-friction, higher-confidence ideation flow, adapted to OpenCode.

### Added

- **Section-completeness round recap** — before every question round, a display-only recap of the seven hard-gated sections (solid/thin/empty) plus the round's target sections. Never an extra question; never changes the gate, round order, or per-round question budget.
- **"I'm not sure — propose candidates" uncertainty path** — every gated-section and forcing question offers a first-class uncertainty option that flips into teaching mode (2–4 topic-tailored candidates with rationales). A candidate can never satisfy the hard gate without explicit human confirmation.
- **Profile recommendation** — when `--profile` is omitted, `/ideate` recommends a profile (recommended-first, `lean` default) before the rounds instead of silently defaulting. No recommendation runs when `--profile` is explicit; resolved-`lean` behavior is unchanged.
- **`--input <file>` brain-dump seed** — seed the session from a freeform notes file (read-only): it pre-fills draft sections and focuses the rounds on the gaps. Distinct from `--continue`; the input file is never modified, moved, or committed, and all gates still run.
- **Intra-session draft autosave & resume** — the in-progress draft autosaves to a gitignored `.stride/` scratch file after every round and is offered for resume on the next same-slug session; the scratch file is cleared after a successful commit. New `lib/draft.{sh,ps1}` helpers with `lib/test-draft.{sh,ps1}` suites.
- **Advisory reviewer findings as an explicit decision** — the `requirements-reviewer` findings are surfaced to the human as a single multi-select decision (with an explicit "Address none — write as-is") feeding the at-most-one refinement round. A clean approval shows no prompt; the reviewer never blocks the write.
- **Stridify preview + approval gate** — before the `POST /api/tasks/batch`, `/stridify` renders the decomposed goal/task tree and requires explicit human approval; `--yes` / `--auto-approve` bypasses the gate for scripted use. On decline, the committed batch JSON is left on disk and no POST is attempted. New `lib/test-stridify-preview.{sh,ps1}` suites.

### Notes

- Protocol content stays faithful to the Claude Code source; these are interaction-surface improvements only. Platform adaptations: OpenCode's question UI (never Claude Code's `AskUserQuestion`), OpenCode tool vocabulary, and `.ps1` Windows-parity mirrors for every new `.sh`.

## [0.1.0] - 2026-06-05

Initial release — OpenCode port of [`cheezy/stride-ideation`](https://github.com/cheezy/stride-ideation) (Claude Code).

### Added

- **`commands/ideate.md`** native `/ideate` command — drives the round-based ideation loop and commits a timestamped requirements markdown document. Supports `--continue <path>` and `--profile <lean|product|discovery|lean-startup>`.
- **`commands/stridify.md`** native `/stridify` command — validates a requirements doc, preflights `.stride_auth.md`, dispatches the decomposer, stamps `source_spec` + `source_spec_sha256`, commits a sibling batch JSON, and POSTs to `/api/tasks/batch`. Supports `--goal <name|index>` and the four-layer resilience model (preflight advisory, per-surface dispatch, bounded retry with backoff, prompt-file fallback).
- **`stride-ideation`** skill — the protocol contract: the seven hard-gated sections, the shape requirements on Assumptions and Success Metrics, the round structure / framing checkpoint / premortem, the four profiles, and the terminal state.
- **`requirements-reviewer`** subagent (OpenCode `mode: subagent`) — advisory, report-only gap review of a draft requirements document.
- **`requirements-decomposer`** subagent — turns a committed requirements document into a single fenced batch JSON matching `POST /api/tasks/batch`.
- **`lib/`** helper suite — `validate_batch.py`, `drift_check.py`, `read_auth.py`, `strip_audit_fields.py`, `filename.{sh,ps1}`, `run_smoke_test.{sh,ps1}`, and the `test-*.{sh,ps1}` suite (bash + PowerShell mirrors for cross-platform parity).
- **`fixtures/`** — three requirements + batch calibration pairs plus README and SMOKE-TEST-NOTE, exercised by the smoke test.
- **`AGENTS.md`** context file, `install.sh` / `install.ps1`, `.gitignore`, and `LICENSE`.

### Notes

- Ported faithfully from the Claude Code source (via the stride-gemini-ideation sibling). Protocol content (sections, rounds, premortem, profiles, resilience model) is preserved verbatim. Platform adaptations only: native OpenCode commands in the plural `commands/` directory, OpenCode tool-name vocabulary (`read_file` / `grep_search` / `glob` / `shell` / `edit_file` / `write_file` / `@agent-name`), `$ARGUMENTS` arguments, OpenCode `mode: subagent` agent frontmatter, and inline option comparisons (OpenCode has no preview-pane tool).
- **No TypeScript plugin** — ideation has no lifecycle hooks, so there is no `package.json`/`src/` plugin and no `"plugin"` entry to add to `opencode.json`. The companion [`stride-opencode`](https://github.com/cheezy/stride-opencode) extension covers the task lifecycle.
