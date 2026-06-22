# Stride Ideation for OpenCode

Turn an idea into shipped Stride tasks — from OpenCode.

This extension provides brainstorming and ideation commands for projects that use [Stride](https://www.stridelikeaboss.com). It is the [OpenCode](https://opencode.ai) port of [`cheezy/stride-ideation`](https://github.com/cheezy/stride-ideation) (Claude Code). Run `/ideate` to drive an interactive ideation session that produces a committed requirements markdown document. Stop there if you just want a written spec — or run `/stridify` to decompose the requirements into a Stride batch JSON, commit it for audit, and POST it to the Stride API in a single invocation.

> **No plugin to install.** Ideation has no lifecycle hooks, so this is a skills/commands/agents bundle — there is no TypeScript plugin and no `"plugin"` entry to add to `opencode.json`. OpenCode discovers the pieces from `.opencode/` paths (see Installation).

## Overview

The two native slash commands:

```text
/ideate [<topic>] [--continue <path>] [--profile <lean|product|discovery|lean-startup>]
  Interactive ideation session. Drives a Q&A loop with you to produce a
  timestamped requirements markdown doc. Stop here if you only want a spec.

/stridify <path-to-requirements.md> [--goal <name|index>]
  End-to-end pipeline: validates the requirements doc, preflights auth,
  dispatches the decomposer agent, stamps audit metadata, writes and
  commits a sibling Stride batch JSON, then POSTs it to /api/tasks/batch
  on your Stride instance and renders the created G/W identifiers.
  --goal scopes the dispatch to one surface from the doc's
  ## Decomposition seams section (see "Resilience model" below).
```

`/ideate` is hard-gated on seven required sections (Goal, Problem, Outcome, Assumptions, Constraints, Non-goals, Success Metrics) plus shape requirements on Assumptions (ranked, riskiest marked, premortem-derived) and Success Metrics (both leading and lagging indicators). `/stridify` is gated on a passing structural validation of the decomposer's output before it commits or POSTs anything.

## Installation

OpenCode discovers skills in `.opencode/skills/`, commands in `.opencode/commands/`, and agents in `.opencode/agents/`, and reads `AGENTS.md` from the project root (or the global `~/.config/opencode/` equivalents).

### Using the bundled installer

```bash
git clone https://github.com/cheezy/stride-opencode-ideation.git

# Project-local (.opencode/ in the current directory)
./stride-opencode-ideation/install.sh

# Global (~/.config/opencode/)
./stride-opencode-ideation/install.sh --global
```

On Windows, use the PowerShell installer:

```powershell
.\stride-opencode-ideation\install.ps1            # project-local
.\stride-opencode-ideation\install.ps1 -Global    # global
```

#### Your existing `AGENTS.md` is preserved

The installer never overwrites a user-authored `AGENTS.md`. Its guidance is
confined to a clearly delimited **managed block**:

```markdown
<!-- BEGIN stride-ideation -->
<!-- Managed by the stride-opencode-ideation installer; content between these markers is regenerated on each install. Add your own notes outside this block. -->
...ideation guidance...
<!-- END stride-ideation -->
```

- **No `AGENTS.md` yet** — the file is created containing the managed block.
- **You already have an `AGENTS.md`** — all of your content is kept; the managed
  block is appended (or, if already present, refreshed in place).
- **Re-running the installer is idempotent** — it updates only the managed block
  and never duplicates the guidance. Keep your own notes *outside* the markers;
  anything between them is regenerated on each install.

`install.sh` and `install.ps1` behave identically.

### Manual install

```bash
git clone https://github.com/cheezy/stride-opencode-ideation.git /tmp/stride-opencode-ideation

mkdir -p .opencode/skills .opencode/commands .opencode/agents
cp -R /tmp/stride-opencode-ideation/skills/.   .opencode/skills/
cp -R /tmp/stride-opencode-ideation/commands/. .opencode/commands/
cp     /tmp/stride-opencode-ideation/agents/*.md .opencode/agents/
cp     /tmp/stride-opencode-ideation/AGENTS.md ./AGENTS.md

# /stridify also needs the lib/ helpers and (for the smoke test) fixtures/
cp -R /tmp/stride-opencode-ideation/lib       .opencode/
cp -R /tmp/stride-opencode-ideation/fixtures  .opencode/
```

There is **no `"plugin"` step** — this bundle ships no TypeScript plugin.

## Setup

`/stridify` needs Stride API credentials. Create `.stride_auth.md` in your project root:

```markdown
- **API URL:** `https://www.stridelikeaboss.com`
- **API Token:** `stride_...`
- **User Email:** `you@example.com`
```

Add `.stride_auth.md` to your `.gitignore` — it holds a secret token. The bundled `.gitignore` already excludes it. `/ideate` needs no credentials.

## Commands

### /ideate

Drives the round-based ideation loop defined by the `stride-ideation` skill: Rounds 1–2 capture Goal/Problem/Outcome and the boundary conditions; Round 3 is a mandatory framing checkpoint; Round 4 is a mandatory premortem that folds failure modes into the Assumptions section and ranks them; the `lean-startup` profile adds a Round 5 MVP-design batch. After all seven sections have content, the `requirements-reviewer` agent runs an advisory pass, then the doc is written and committed. The terminal state is the written document — `/ideate` never auto-invokes `/stridify`.

Profiles: `lean` (default), `product` (adds JTBD framing + Concrete Example section), `discovery` (adds Why-now + Alternatives), `lean-startup` (adds the Round-5 MVP / Validation experiment section).

### /stridify

Validates the requirements doc's seven sections, preflights `.stride_auth.md`, and dispatches the `requirements-decomposer` agent to produce a Stride batch JSON. It stamps `source_spec` + `source_spec_sha256` at the JSON root for audit, writes and commits a timestamped sibling batch JSON, strips the audit fields from the POST payload, then POSTs to `/api/tasks/batch` and renders the created G/W identifiers.

#### Resilience model

- **Preflight advisory** when a doc enumerates more than 3 surfaces under `## Decomposition seams`.
- **`--goal <name|index>`** scopes the dispatch to a single surface from `## Decomposition seams`.
- **Bounded decomposer-dispatch retry** — 3 attempts with ~30s / ~90s backoff on HTTP 529 / network / "overloaded" failures.
- **Fallback** — on retry exhaustion the assembled prompt is written to a sibling `*-decomposer-prompt.md` file. The Stride API POST itself is not retried; re-invoke on a 4xx/5xx.

## Skill and Agents

- **`stride-ideation`** skill — the protocol contract (required sections, shape requirements, rounds, premortem, profiles, terminal state).
- **`requirements-reviewer`** agent — advisory gap review of a draft doc; reports only, never edits.
- **`requirements-decomposer`** agent — turns a committed doc into a single fenced batch JSON; no prose.

## How this relates to `stride-opencode`

[`stride-opencode`](https://github.com/cheezy/stride-opencode) covers the **task lifecycle** (claiming, hook execution via its TypeScript plugin, completion). This extension covers **ideation** — turning a fuzzy idea into a requirements doc and seeding a Stride backlog from it. A typical full loop installs both: `/ideate` → `/stridify` here, then claim and ship the resulting tasks with `stride-opencode`.

## License

MIT — see [LICENSE](LICENSE).
