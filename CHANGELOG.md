# Changelog

All notable changes to the Stride Ideation extension for OpenCode are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
