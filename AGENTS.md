# Stride Ideation Extension for OpenCode

Turns a fuzzy idea into a committed requirements document, and seeds a Stride backlog from it. This extension covers **ideation**; the companion [stride-opencode](https://github.com/cheezy/stride-opencode) extension covers the **task lifecycle** (claiming, hooks, completion).

There is **no plugin to install** — ideation has no lifecycle hooks, so this is a skills/commands/agents bundle. OpenCode discovers the pieces from `.opencode/` paths (see Installation).

## Commands

Two native slash commands drive the workflow. The protocol contract they enforce lives in the `stride-ideation` skill — the commands defer to it rather than restating it.

| Command | When to use |
|---------|-------------|
| `/ideate [<topic>] [--continue <path>] [--profile <lean\|product\|discovery\|lean-startup>]` | Brainstorm and scope a fuzzy idea into a committed requirements markdown doc. Drives the round-based question loop, the round-3 framing checkpoint, the round-4 premortem, and (lean-startup) the round-5 MVP batch. Hard-gated on the seven required sections. Terminal state is the written doc — it does NOT auto-invoke `/stridify`. |
| `/stridify <path-to-requirements.md> [--goal <name\|index>]` | Decompose a committed requirements doc into Stride tasks and POST them. Validates the seven sections, preflights `.stride_auth.md`, dispatches the requirements-decomposer agent, stamps `source_spec` + `source_spec_sha256`, writes and commits a timestamped batch JSON, then POSTs to `/api/tasks/batch` and renders the created G/W identifiers. |

`/stridify` is optional — the requirements doc is a deliverable on its own. Run it only when you want the tasks created in Stride.

## Skill

- **`stride-ideation`** — the protocol contract: the seven required sections (Goal, Problem, Outcome, Assumptions, Constraints, Non-goals, Success Metrics), the shape requirements (premortem-derived + ranked Assumptions with the riskiest marked; leading **and** lagging Success Metrics), the round structure / framing checkpoint / premortem / profile augmentations, and the terminal state. The `/ideate` command drives this skill; `/stridify` references it for the section gate. Invoke it via OpenCode's `skill` tool; readers usually do not activate it directly — the commands do.

## Custom Agents

Two subagents are dispatched by the commands (via `@mention`); they are not invoked directly from a user prompt.

- **requirements-reviewer** — Advisory pass over a draft requirements document. Reports gaps, contradictions, and ambiguous acceptance criteria; **never edits the doc**. Dispatched by `/ideate` after the seven sections have draft content and before the doc is committed.
- **requirements-decomposer** — Reads a committed requirements document end-to-end and emits a single fenced ```json batch document matching `POST /api/tasks/batch`. Dispatched by `/stridify` before the batch JSON is written and committed. Its only output is the fenced JSON — no prose.

Both agents live at `agents/<name>.md` (OpenCode subagent format: `mode: subagent`, read-only `tools`).

## Installation

OpenCode discovers skills, commands, and agents from `.opencode/` (project) or `~/.config/opencode/` (global), and reads `AGENTS.md` from the project root. Copy the pieces into place (the bundled `install.sh` / `install.ps1` does this):

```
skills/   -> .opencode/skills/
commands/ -> .opencode/commands/
agents/   -> .opencode/agents/
AGENTS.md -> ./AGENTS.md
```

`lib/` and `fixtures/` ship alongside for the `/stridify` helpers and the smoke test. **No plugin install** (no `"plugin"` entry in `opencode.json`) is needed — there is no TypeScript plugin.

## Workflow Sequence

```
/ideate [topic] [--profile <name>]
  -> drives the question loop, gates on the seven required sections,
     dispatches @requirements-reviewer, writes and commits the doc
  -> STOP — the committed doc is a valid terminal state

/stridify <path-to-requirements.md> [--goal <name|index>]
  -> validates the seven sections, preflights .stride_auth.md,
     dispatches @requirements-decomposer (with bounded retry on
     transient failures), stamps audit metadata, writes and commits
     the batch JSON, POSTs to /api/tasks/batch, renders the G/W table
```

## API Authorization

The `/stridify` command reads `.stride_auth.md` from the project root for `STRIDE_API_URL` and `STRIDE_API_TOKEN`. The user authorizes Stride API calls by initiating the workflow — **never prompt for permission before the POST**. **Never log the token, even in error paths.**

`.stride_auth.md` must be listed in `.gitignore`. The bundled `.gitignore` already excludes it.

## Tool Name Mapping

The skill, command, and agent bodies reference OpenCode tool names directly. When porting prompts that originated on another platform (the upstream Claude Code plugin, or the Gemini/Codex ports), use these equivalents:

| Other-platform reference | OpenCode Tool |
|--------------------------|---------------|
| `Read` | `read_file` |
| `Grep` | `grep_search` |
| `Glob` | `glob` |
| `Bash` | `shell` |
| `Edit` | `edit_file` |
| `Write` | `write_file` |
| `Agent` (subagent dispatch) | `@agent-name` mention |

OpenCode has no first-class "preview pane" question tool, so option comparisons are rendered inline (fenced ASCII blocks or short tables) rather than via a preview field.

## How this extension relates to `stride-opencode`

`stride-opencode` covers the **task lifecycle** (claiming, hook execution via its TypeScript plugin, completion). This extension covers **ideation** — turning a fuzzy idea into a requirements doc and seeding a Stride backlog from it. A typical full loop installs both: `/ideate` -> `/stridify` with this extension, then claim and ship the resulting tasks with `stride-opencode`.
