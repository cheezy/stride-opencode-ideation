---
description: "End-to-end pipeline from a stride-ideation requirements doc to created Stride goals. Validates the seven required sections, preflights auth, dispatches the requirements-decomposer subagent, stamps source_spec + source_spec_sha256, writes and commits a timestamped sibling batch JSON, then POSTs to the Stride API and renders the created G/W identifiers."
---

# /stridify

Read a stride-ideation requirements markdown document, decompose it into a Stride batch JSON (committed to disk for audit), and POST it to the Stride API in a single invocation. The decomposition logic — natural seams, sizing, multi-goal split rule, batch JSON shape — lives in `agents/requirements-decomposer.md`. This command is the surface: it parses the invocation arguments, validates the input, preflights auth, dispatches the subagent, stamps `source_spec` + `source_spec_sha256`, writes and commits the file, then strips local-audit fields, POSTs to `/api/tasks/batch`, and renders the created G/W identifiers.

**Usage:** `/stridify <path-to-requirements.md> [--goal <name|index>] [--yes]`

The user's invocation arguments are available as `$ARGUMENTS`. Parse the requirements-doc path and the optional `--goal <name|index>` flag out of `$ARGUMENTS` per Step 1. The protocol contract for decomposition lives in the `stride-ideation` skill and the requirements-decomposer custom agent — this command defers to them and never reimplements the decomposition methodology.

**Asking the user.** Every question this command asks goes through OpenCode's `question` tool. The tool adds its own "Type your own answer" choice to every question, so never list an "Other" or catch-all option. If the `question` tool is not available in this client (OpenCode 1.16 registers it only for its app, CLI and desktop clients unless `OPENCODE_ENABLE_QUESTION_TOOL` is set), ask the same question as plain text — numbered options, the recommended one first — and wait for the user's reply before continuing.

### Running the bash fragments

**Every bash call is a fresh shell.** OpenCode's `bash` tool starts a new process for each call, so variables, sourced functions and the result of an earlier fragment do not survive into the next call. Each fragment below is self-contained: it finds and sources the helper it needs itself and starts from the values you hand it. Run each fragment as one `bash` call and check its result before going on.

- **Helper paths.** A fragment that needs a helper finds the installed `lib/` itself, in this order: the project install (`.opencode/stride-ideation/lib` at the git toplevel), the global install (`~/.config/opencode/stride-ideation/lib`), and — only when the project *is* a `stride-opencode-ideation` checkout, with the same marker files the installer checks (`commands/stridify.md`, `commands/ideate.md`, `install.sh`, `AGENTS.md`, `skills/`) — that checkout's `lib/`. A project install is trusted ahead of the global one, the same way OpenCode trusts a project's own `.opencode/` commands: in a repository you do not trust, check its `.opencode/` before running these commands there. It never takes a helper path from an argument, a carried value or an environment variable. If a fragment stops with `cannot find the stride-ideation helpers`, stop the session and tell the user to run the installer; never guess a path.
- **Carry values forward as literals.** A fragment's first comment line, `# Carried forward: ...`, names the values it needs from earlier steps. Prepend one single-quoted assignment per name to the same `bash` call, e.g. `SLUG='dark-mode-toggle'`. Write a single quote inside a value as `'\''` (so `Bob's idea` becomes `TOPIC='Bob'\''s idea'`), write an empty value as `NAME=''`, and never paste a value unquoted. The fragment checks each one and stops with `... was not carried forward` if you missed one; fix the prefix and re-run that step.
- **Values a fragment produces** are printed as `carry: NAME=value` lines. Carry them into later steps exactly as printed.
- **No dollar-sign-plus-digit sequences.** OpenCode replaces each one in this file with the matching invocation argument before you read it, so the fragments use `cut`, `read` and helper functions instead of positional fields. Keep it that way when editing this file.

## What to do

Follow these steps in order. Do NOT skip steps.

### Step 1: Parse `$ARGUMENTS`

The user invoked you with `$ARGUMENTS`. Parse in this fixed order — `--goal` first, then `--yes` / `--auto-approve`, then the trimmed remainder is `REQUIREMENTS_PATH`:

- If `--goal` appears, set `GOAL_ARG` to the value of the **next** token and remove both tokens — or, if the `--goal=<value>` form is used, set `GOAL_ARG` to the post-`=` portion (split on the FIRST `=` only, so a value containing `=` is preserved verbatim) and remove the single token. Accept both shapes — `--goal <value>` and `--goal=<value>` — matching how `/ideate` handles `--continue` and `--profile`. Do NOT validate `GOAL_ARG` here; resolution against the doc's `## Decomposition seams` section happens in new Step 2b, after the doc has been read and the seven-section gate has passed.
- If `--goal` is absent, `GOAL_ARG` and `GOAL_SLUG` are empty: carry them as `GOAL_ARG=''` and `GOAL_SLUG=''` into every step whose fragment names them. The command runs in its historical "all goals" mode.
- If `--yes` **or** `--auto-approve` appears as a bare token, set `AUTO_APPROVE=true` and remove that token. This is a **boolean flag — it takes no value**, so there is no `--yes=<value>` form; treat any token equal to `--yes` or `--auto-approve` as the switch and consume it. The flag bypasses the Step 8.5 preview-and-approval gate, preserving the historical fire-and-forget behavior for scripted / non-interactive callers. If neither token appears, leave `AUTO_APPROVE` unset (equivalently `false`); the command runs interactively and Step 8.5 prompts for approval before the POST. The bypass MUST be an explicit user-supplied flag — never infer it; tasks must never be shipped unreviewed by accident.
- After flag tokens are consumed, trim the remainder and set `REQUIREMENTS_PATH`. If the remainder is empty, print *"Usage: `/stridify <path-to-requirements.md> [--goal <name|index>] [--yes]`"* and exit non-zero.

### Step 2: Validate the requirements doc

Before doing any expensive work, the command must confirm the input is a real, parseable requirements doc produced by (or compatible with) `/ideate`. Run these checks in order; any failure prints a one-line error and exits non-zero:

1. **File exists and is a regular file.** Use `read` or `bash` with `test -f` to confirm. If missing, print *"stride-ideation: requirements doc not found at `<REQUIREMENTS_PATH>`"* and stop.

2. **Filename family matches.** The path SHOULD end in `-requirements.md`. If it does not, warn but proceed — the slug-extraction step below may still succeed for paths produced by older versions of the plugin, and the section-validation pass below is the authoritative check anyway.

3. **All seven hard-gated sections are present.** `lib/check_sections.py` checks that the file has a level-2 heading for each of: `Problem`, `Goal`, `Outcome`, `Assumptions`, `Constraints`, `Non-goals`, `Success metrics`. Headings match case-insensitively with trailing whitespace ignored (so the skill's `Success Metrics` and the template's `Success metrics` both pass), headings inside code fences do not count, and order is not enforced (the doc template orders Problem before Goal, but a hand-edited doc may differ):

   ```bash
   # Carried forward: REQUIREMENTS_PATH
   : "${REQUIREMENTS_PATH:?stride-ideation: REQUIREMENTS_PATH was not carried forward from Step 1}"
   # Find the helpers: the project install, then the global install, then a stride-opencode-ideation checkout.
   STI_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
   if [ -f "$STI_ROOT/.opencode/stride-ideation/lib/filename.sh" ]; then STI_LIB="$STI_ROOT/.opencode/stride-ideation/lib"
   elif [ -f "${HOME:-}/.config/opencode/stride-ideation/lib/filename.sh" ]; then STI_LIB="$HOME/.config/opencode/stride-ideation/lib"
   elif [ -f "$STI_ROOT/commands/stridify.md" ] && [ -f "$STI_ROOT/commands/ideate.md" ] && [ -f "$STI_ROOT/install.sh" ] && [ -f "$STI_ROOT/AGENTS.md" ] && [ -d "$STI_ROOT/skills" ] && [ -f "$STI_ROOT/lib/filename.sh" ]; then STI_LIB="$STI_ROOT/lib"
   else echo "stride-ideation: cannot find the stride-ideation helpers in .opencode/stride-ideation/lib, ~/.config/opencode/stride-ideation/lib or a stride-opencode-ideation checkout — run install.sh, then retry this step" >&2; exit 1; fi
   python3 "$STI_LIB/check_sections.py" "$REQUIREMENTS_PATH" || {
     echo "stride-ideation: either re-run /ideate --continue on this doc to fill them in, or hand-edit the doc to include the missing sections." >&2
     exit 1
   }
   ```

   On a missing section it prints *"stride-ideation: requirements doc is missing required section(s): `<list>`"* plus the remedy line, and exits non-zero. Do NOT proceed with a partial doc — the decomposer subagent's output quality depends on every section being substantive.

4. **Advisory: large-decomposition warning (never blocks).** If the doc contains a `## Decomposition seams` section AND `GOAL_ARG` is empty (the user did NOT invoke with `--goal`), count the seams under that heading. If the count is **greater than 3**, print a single advisory line to stderr and continue execution — this is a UX hint, not a gate. When `--goal` IS set (per-goal mode), do NOT print this advisory — the user has already partitioned and emitting noise on top is counter-productive. When the seams section is absent or enumerates ≤3 surfaces, also skip the advisory.

   **The count is exactly the set of seams `--goal` accepts.** It comes from `sti_extract_seams`, the same parser Step 2b resolves `--goal` against and Step 7e scopes with, so an advisory that recommends `--goal` can always be followed with `--goal 1` … `--goal N`. One item shape counts per section, by precedence:

   | Shape | Item start | Used when |
   |---|---|---|
   | Numbered bold item | `1. **Name** …` | any numbered bold item exists |
   | Bulleted bold item | `- **Name** …` (top level) | no numbered bold items |
   | Level-3 heading | `### Name` | neither of the above |

   So a numbered list's secondary cross-cutting bullets (e.g., "Shared contract" or "Sequencing & dependencies" notes) never inflate the count, and a section written as bullets or headings is countable and addressable just like a numbered one.

   ```bash
   # Carried forward: REQUIREMENTS_PATH, GOAL_ARG (empty without --goal)
   : "${REQUIREMENTS_PATH:?stride-ideation: REQUIREMENTS_PATH was not carried forward from Step 1}"
   : "${GOAL_ARG?stride-ideation: GOAL_ARG was not carried forward from Step 1}"
   # Find the helpers: the project install, then the global install, then a stride-opencode-ideation checkout.
   STI_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
   if [ -f "$STI_ROOT/.opencode/stride-ideation/lib/filename.sh" ]; then STI_LIB="$STI_ROOT/.opencode/stride-ideation/lib"
   elif [ -f "${HOME:-}/.config/opencode/stride-ideation/lib/filename.sh" ]; then STI_LIB="$HOME/.config/opencode/stride-ideation/lib"
   elif [ -f "$STI_ROOT/commands/stridify.md" ] && [ -f "$STI_ROOT/commands/ideate.md" ] && [ -f "$STI_ROOT/install.sh" ] && [ -f "$STI_ROOT/AGENTS.md" ] && [ -d "$STI_ROOT/skills" ] && [ -f "$STI_ROOT/lib/filename.sh" ]; then STI_LIB="$STI_ROOT/lib"
   else echo "stride-ideation: cannot find the stride-ideation helpers in .opencode/stride-ideation/lib, ~/.config/opencode/stride-ideation/lib or a stride-opencode-ideation checkout — run install.sh, then retry this step" >&2; exit 1; fi
   . "$STI_LIB/filename.sh" || exit 1
   if [ -z "$GOAL_ARG" ] && grep -qE '^## Decomposition seams[[:space:]]*$' "$REQUIREMENTS_PATH"; then
     SEAM_COUNT="$(sti_extract_seams "$REQUIREMENTS_PATH" | grep -c '')"
     if [ "$SEAM_COUNT" -gt 3 ]; then
       echo "stride-ideation: requirements doc enumerates $SEAM_COUNT surfaces under Decomposition seams. Consider running /stridify --goal <name|index> $SEAM_COUNT times to reduce subagent-dispatch failure risk on large decompositions. Continuing with all-goals mode." >&2
     fi
   fi
   ```

   The advisory itself **never** exits non-zero — it is informational; the fragment stops only when it cannot find the helpers (see Running the bash fragments). Users who genuinely want all-goals mode on a 7-surface doc see the line once at the top of the run and ignore it; that is a deliberate trade-off, not a defect.

### Step 2b: Resolve `--goal` against `## Decomposition seams` (only if `--goal` was set)

This step runs **only when `GOAL_ARG` is set** (i.e., the user invoked with `--goal <value>`). If `GOAL_ARG` is empty, skip the entire step — the command stays in "all goals" mode and `GOAL_SLUG` stays empty (carry it as `GOAL_SLUG=''`).

The resolver is `sti_resolve_goal` in `lib/filename.sh`. It takes the requirements doc path and the `GOAL_ARG` string and emits `<index>\t<name>\t<slug>` on success; `sti_goal_fields` splits that into the `GOAL_INDEX`, `GOAL_NAME` and `GOAL_SLUG` values the fragment prints as `carry:` lines. Carry all three into Steps 5, 7 and 8:

```bash
# Carried forward: REQUIREMENTS_PATH, GOAL_ARG
: "${REQUIREMENTS_PATH:?stride-ideation: REQUIREMENTS_PATH was not carried forward from Step 1}"
: "${GOAL_ARG:?stride-ideation: GOAL_ARG was not carried forward from Step 1}"
# Find the helpers: the project install, then the global install, then a stride-opencode-ideation checkout.
STI_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
if [ -f "$STI_ROOT/.opencode/stride-ideation/lib/filename.sh" ]; then STI_LIB="$STI_ROOT/.opencode/stride-ideation/lib"
elif [ -f "${HOME:-}/.config/opencode/stride-ideation/lib/filename.sh" ]; then STI_LIB="$HOME/.config/opencode/stride-ideation/lib"
elif [ -f "$STI_ROOT/commands/stridify.md" ] && [ -f "$STI_ROOT/commands/ideate.md" ] && [ -f "$STI_ROOT/install.sh" ] && [ -f "$STI_ROOT/AGENTS.md" ] && [ -d "$STI_ROOT/skills" ] && [ -f "$STI_ROOT/lib/filename.sh" ]; then STI_LIB="$STI_ROOT/lib"
else echo "stride-ideation: cannot find the stride-ideation helpers in .opencode/stride-ideation/lib, ~/.config/opencode/stride-ideation/lib or a stride-opencode-ideation checkout — run install.sh, then retry this step" >&2; exit 1; fi
. "$STI_LIB/filename.sh" || exit 1

GOAL_RESOLVED="$(sti_resolve_goal "$REQUIREMENTS_PATH" "$GOAL_ARG")"
GOAL_RC=$?
case "$GOAL_RC" in
  0)
    GOAL_FIELDS="$(sti_goal_fields "$GOAL_RESOLVED")" || exit 1
    printf '%s\n' "$GOAL_FIELDS" | sed 's/^/carry: /'
    ;;
  2)
    echo "stride-ideation: no Decomposition seams section in $REQUIREMENTS_PATH — cannot scope to single goal" >&2
    exit 1
    ;;
  4)
    echo "stride-ideation: Decomposition seams section in $REQUIREMENTS_PATH is empty — cannot scope to single goal" >&2
    exit 1
    ;;
  3)
    echo "stride-ideation: --goal value '$GOAL_ARG' did not match any Decomposition seam in $REQUIREMENTS_PATH. Available seams:" >&2
    sti_extract_seams "$REQUIREMENTS_PATH" | while IFS="$(printf '\t')" read -r SEAM_IDX SEAM_NAME SEAM_SLUG; do
      printf '  %d. %s (slug: %s)\n' "$SEAM_IDX" "$SEAM_NAME" "$SEAM_SLUG"
    done >&2
    exit 1
    ;;
  *)
    echo "stride-ideation: --goal resolution failed (rc=$GOAL_RC) on $REQUIREMENTS_PATH" >&2
    exit 1
    ;;
esac
```

**Resolution rules** (implemented by `sti_resolve_goal`):

| `GOAL_ARG` shape | Resolution attempt | Fallback |
|---|---|---|
| Purely digits (matches `^[0-9]+$`) | 1-based integer index into the in-document order of `## Decomposition seams` items | If the index is out of range, fall through to slug-match (handles the edge case of a seam literally named `"1"`) |
| Anything else (contains a non-digit) | Slugify via `sti_slugify` and exact-compare against each seam's slug field; first match wins | None — unmatched values raise the rc=3 error above |

**Pitfalls honored here:**
- `--goal` is **not** silently ignored on no-match — every miss raises a non-zero exit with the verbatim "did not match" message and a printed list of the actual seams that ARE present.
- The seams section is **not** required in all docs — `GOAL_ARG` being unset means this step is a no-op. Only when the user explicitly opted into per-goal mode does the absence become an error.
- The parser does not couple to any markdown shape beyond "level-2 heading `## Decomposition seams` followed by numbered `<N>. **Name** ...` items, or else top-level bulleted `- **Name** ...` items, or else `### Name` headings" (one shape per section, in that precedence — the Step 2 table). Intro prose, trailing prose, and item bodies on subsequent lines are all tolerated — only each item's name is used.

### Step 3: Preflight auth from `.stride_auth.md`

Read auth BEFORE the expensive subagent dispatch so a misconfigured `.stride_auth.md` fails fast without first burning a decomposer pass and writing a batch JSON that can't be shipped. Run the ship script's preflight mode:

```bash
# Carried forward: none
# Find the helpers: the project install, then the global install, then a stride-opencode-ideation checkout.
STI_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
if [ -f "$STI_ROOT/.opencode/stride-ideation/lib/filename.sh" ]; then STI_LIB="$STI_ROOT/.opencode/stride-ideation/lib"
elif [ -f "${HOME:-}/.config/opencode/stride-ideation/lib/filename.sh" ]; then STI_LIB="$HOME/.config/opencode/stride-ideation/lib"
elif [ -f "$STI_ROOT/commands/stridify.md" ] && [ -f "$STI_ROOT/commands/ideate.md" ] && [ -f "$STI_ROOT/install.sh" ] && [ -f "$STI_ROOT/AGENTS.md" ] && [ -d "$STI_ROOT/skills" ] && [ -f "$STI_ROOT/lib/filename.sh" ]; then STI_LIB="$STI_ROOT/lib"
else echo "stride-ideation: cannot find the stride-ideation helpers in .opencode/stride-ideation/lib, ~/.config/opencode/stride-ideation/lib or a stride-opencode-ideation checkout — run install.sh, then retry this step" >&2; exit 1; fi
bash "$STI_LIB/ship.sh" --check-auth || exit 1
```

`--check-auth` locates `.stride_auth.md` — `$STRIDE_AUTH_FILE` if set, else the file at the git toplevel of the working directory (so a run from a subdirectory of the project still finds it), else the one in the current directory — reads it through `lib/read_auth.py`, prints one `stride-ideation: auth file OK` line naming the file and the API URL, and POSTs nothing. It checks that the file parses, not that the server accepts the token — a revoked token surfaces as a 401 in Step 9. On failure it exits non-zero after `lib/read_auth.py`'s own stderr, which is engineered to never contain the token value — surface that verbatim and stop.

**The token never enters this shell.** OpenCode's bash tool starts a fresh process for every call, so nothing — the token included — survives from this step to Step 9. The preflight runs in its own process and exports nothing; Step 9 runs the same script again, which reads auth afresh in the process that makes the POST. There is nothing to `eval` here. In particular:
- Do NOT read `.stride_auth.md` yourself, and do NOT `eval` or `source` `lib/read_auth.py` output in this shell. (Its output is shell-quoted, so an eval would no longer execute anything the file contains, but the script makes the eval unnecessary.)
- Do NOT echo the token for diagnostics, and do NOT include it in any message the user sees.
- Do NOT put the token on any process's command line: argv is visible to `ps` for the life of the process, so `curl -H "Authorization: Bearer <token>"` exposes it. `lib/ship.sh` hands it to curl as a config on curl's stdin (`curl -K -`), so it is on no command line and in no file.
- Do NOT use `curl -v` (or anything else that echoes request headers) against the Stride API.

### Step 4: Inherit the session timestamp and slug

The fragment sources `lib/filename.sh` and extracts the inherited values from `REQUIREMENTS_PATH`:

```bash
# Carried forward: REQUIREMENTS_PATH
: "${REQUIREMENTS_PATH:?stride-ideation: REQUIREMENTS_PATH was not carried forward from Step 1}"
# Find the helpers: the project install, then the global install, then a stride-opencode-ideation checkout.
STI_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
if [ -f "$STI_ROOT/.opencode/stride-ideation/lib/filename.sh" ]; then STI_LIB="$STI_ROOT/.opencode/stride-ideation/lib"
elif [ -f "${HOME:-}/.config/opencode/stride-ideation/lib/filename.sh" ]; then STI_LIB="$HOME/.config/opencode/stride-ideation/lib"
elif [ -f "$STI_ROOT/commands/stridify.md" ] && [ -f "$STI_ROOT/commands/ideate.md" ] && [ -f "$STI_ROOT/install.sh" ] && [ -f "$STI_ROOT/AGENTS.md" ] && [ -d "$STI_ROOT/skills" ] && [ -f "$STI_ROOT/lib/filename.sh" ]; then STI_LIB="$STI_ROOT/lib"
else echo "stride-ideation: cannot find the stride-ideation helpers in .opencode/stride-ideation/lib, ~/.config/opencode/stride-ideation/lib or a stride-opencode-ideation checkout — run install.sh, then retry this step" >&2; exit 1; fi
. "$STI_LIB/filename.sh" || exit 1

SOURCE_TS="$(basename "$REQUIREMENTS_PATH" | sed -E 's/^([0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{6})-.*$/\1/')"
SLUG="$(sti_slug_from_path "$REQUIREMENTS_PATH" requirements)" || exit 1
printf 'carry: SOURCE_TS=%s\n' "$SOURCE_TS"
printf 'carry: SLUG=%s\n' "$SLUG"
```

`SOURCE_TS` is **inherited** from the source path so the decomposition JSON pairs cleanly with its requirements doc by filename prefix. Do NOT generate a fresh timestamp — the design spec explicitly couples the two artifacts by shared prefix.

If `sti_slug_from_path` exits non-zero (the path does not match the `YYYY-MM-DDTHHMMSS-<slug>-requirements.md` format), surface the error verbatim and stop.

### Step 5: Compute the target path (don't write yet)

Use `sti_unique_path` to compute the sibling output path. When `--goal` was set, append the goal slug to the doc slug so per-goal batches sit next to each other without collision:

```bash
# Carried forward: REQUIREMENTS_PATH, SOURCE_TS, SLUG, GOAL_SLUG (empty without --goal)
: "${REQUIREMENTS_PATH:?stride-ideation: REQUIREMENTS_PATH was not carried forward from Step 1}"
: "${SOURCE_TS:?stride-ideation: SOURCE_TS was not carried forward from Step 4}"
: "${SLUG:?stride-ideation: SLUG was not carried forward from Step 4}"
: "${GOAL_SLUG?stride-ideation: GOAL_SLUG was not carried forward from Step 2b}"
# Find the helpers: the project install, then the global install, then a stride-opencode-ideation checkout.
STI_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
if [ -f "$STI_ROOT/.opencode/stride-ideation/lib/filename.sh" ]; then STI_LIB="$STI_ROOT/.opencode/stride-ideation/lib"
elif [ -f "${HOME:-}/.config/opencode/stride-ideation/lib/filename.sh" ]; then STI_LIB="$HOME/.config/opencode/stride-ideation/lib"
elif [ -f "$STI_ROOT/commands/stridify.md" ] && [ -f "$STI_ROOT/commands/ideate.md" ] && [ -f "$STI_ROOT/install.sh" ] && [ -f "$STI_ROOT/AGENTS.md" ] && [ -d "$STI_ROOT/skills" ] && [ -f "$STI_ROOT/lib/filename.sh" ]; then STI_LIB="$STI_ROOT/lib"
else echo "stride-ideation: cannot find the stride-ideation helpers in .opencode/stride-ideation/lib, ~/.config/opencode/stride-ideation/lib or a stride-opencode-ideation checkout — run install.sh, then retry this step" >&2; exit 1; fi
. "$STI_LIB/filename.sh" || exit 1

SLUG_FOR_PATH="$SLUG"
if [ -n "$GOAL_SLUG" ]; then
  SLUG_FOR_PATH="${SLUG}-${GOAL_SLUG}"
fi
TARGET_PATH="$(sti_unique_path "$(dirname "$REQUIREMENTS_PATH")" "$SOURCE_TS" "$SLUG_FOR_PATH" stride-batch json)" || exit 1
printf 'carry: SLUG_FOR_PATH=%s\n' "$SLUG_FOR_PATH"
printf 'carry: TARGET_PATH=%s\n' "$TARGET_PATH"
```

`stride-batch` is the artifact name (not `requirements`), so the helper produces a sibling file like `2026-05-12T103000-add-notifications-stride-batch.json` next to the requirements doc. When `--goal` is set, the goal slug is appended between the doc slug and the `-stride-batch` token, producing e.g. `2026-05-15T210800-review-queue-code-diffs-kanban-app-stride-batch.json`.

If a stride-batch file with the inherited timestamp + slug already exists (rare — happens when `/stridify` is rerun on the same input, or when the same `--goal` is invoked twice on the same source doc), `sti_unique_path` appends `-2`, `-3`, … so the prior batch is preserved. **The HARD INVARIANT 'never overwrite an existing file' applies here too** and applies uniformly to both per-goal and full-decomposition runs.

Do NOT create or touch `TARGET_PATH` yet. A pre-created empty file would leave a half-baked artifact if the subagent dispatch fails or is interrupted.

### Step 6: Compute the source SHA-256 and normalize the source path

Compute the SHA-256 of the requirements doc and capture it for the orchestrator-injected fields:

```bash
# Carried forward: REQUIREMENTS_PATH
: "${REQUIREMENTS_PATH:?stride-ideation: REQUIREMENTS_PATH was not carried forward from Step 1}"
SOURCE_SHA="$(python3 -c 'import hashlib, sys; print(hashlib.sha256(open(sys.argv[1], "rb").read()).hexdigest())' "$REQUIREMENTS_PATH")" || exit 1
printf 'carry: SOURCE_SHA=%s\n' "$SOURCE_SHA"
```

`python3` is already required by the path normalization below and by the Step 8 validator, so there is no `shasum` / `sha256sum` variant to fall back to. `hexdigest()` is always **lowercase**, so the on-disk audit field is a stable, canonical value.

**Normalize `REQUIREMENTS_PATH` to a stable form** so the stamped `source_spec` value is consistent across invocations from different working directories. Two acceptable forms:

```bash
# Carried forward: REQUIREMENTS_PATH
: "${REQUIREMENTS_PATH:?stride-ideation: REQUIREMENTS_PATH was not carried forward from Step 1}"
# Preferred: relative to the git repo root.
REPO_ROOT="$(git rev-parse --show-toplevel)"
SOURCE_SPEC="$(python3 -c "import os,sys; print(os.path.relpath(sys.argv[1], sys.argv[2]))" "$REQUIREMENTS_PATH" "$REPO_ROOT")"

# Fallback when not in a git repo: absolute path.
if [ -z "$SOURCE_SPEC" ] || [ "$SOURCE_SPEC" = ".." ] || [[ "$SOURCE_SPEC" == ../* ]]; then
  SOURCE_SPEC="$(cd "$(dirname "$REQUIREMENTS_PATH")" && pwd)/$(basename "$REQUIREMENTS_PATH")"
fi
printf 'carry: SOURCE_SPEC=%s\n' "$SOURCE_SPEC"
```

Do NOT use the raw `$REQUIREMENTS_PATH` as `SOURCE_SPEC` — it depends on the user's current working directory at invocation time and would make the on-disk audit field brittle for tools that read the JSON later.

### Step 7: Dispatch the `requirements-decomposer` custom agent

Read the full content of the requirements doc and dispatch the requirements-decomposer custom agent by calling OpenCode's `task` tool with `subagent_type: "requirements-decomposer"`, a short `description` (e.g. `Decompose requirements doc`) and the prompt below — never with an `@name` mention, which only a user's own prompt turns into an agent call. The dispatch is wrapped in a **bounded retry loop** so the command survives transient Anthropic API capacity spikes (HTTP 529 Overloaded). Subagent dispatch has no side effects on the Stride API — a retried call cannot double-create anything — so retrying it is safe in a way that retrying the Step 9 POST is not.

Call the `task` tool (`subagent_type: "requirements-decomposer"`) with a prompt consisting of the requirements doc text, fenced inside a "Requirements document:" block — the only input the subagent has access to.

The subagent receives the requirements doc as its entire input (no codebase access, no Stride API access, no clarifying-question loop). Its prompt at `agents/requirements-decomposer.md` documents the decomposition methodology, the canonical batch JSON shape, and the output contract.

**(7a) Classify the dispatch outcome.** After each dispatch, classify the result before deciding whether to retry. This mirrors the explicit branching of Step 9c: every outcome maps to exactly one row.

| Outcome | Classification | Action |
|---|---|---|
| Subagent returned a single fenced ```json document parseable as a JSON object | success | Extract the fenced JSON block and continue to Step 8. |
| HTTP 529 Overloaded; transient network error (DNS resolution failure, connection refused, timeout, TLS handshake error); explicit `overloaded` classification string in the error body | transient | Sleep per the backoff schedule, then retry — up to the cap. |
| Bad subagent name (the custom agent does not exist); hard 4xx other than 529; contract violation (response contains no fenced JSON block, contains multiple ambiguous fenced blocks, or the fenced content does not parse as a JSON object) | terminal | Fail fast on attempt 1. **Do NOT retry** — these are not load-related and a retry will not change the result. |

**(7b) Backoff schedule.** Bounded exponential — wait times **~30s / ~90s / ~300s** (factor ~3×). Combined with the cap of **3 attempts**, only the first two intervals actually fire (sleep ~30s after attempt 1 before attempt 2; sleep ~90s after attempt 2 before attempt 3; there is no attempt 4, so the ~300s interval is documented for completeness but never used). The cap is 3 — **do not raise it**. If three attempts spread over ~2 minutes did not succeed, the capacity event is longer than the user's patience budget; surfacing the failure and letting the user re-invoke is the safer contract.

**(7c) Code-flow example.** The custom agent is dispatched directly by the model, not through bash, so the loop below is pseudo-code that names the control flow. The classifier maps a dispatch result to one of `success` / `transient` / `terminal` per the table above.

```
# Assemble the prompt ONCE before the loop (Step 7e). The same string is
# dispatched on every attempt and is also what gets saved to disk on retry
# exhaustion (Step 7.5).
DECOMPOSER_PROMPT="$(assemble_decomposer_prompt "$REQUIREMENTS_PATH" "${GOAL_INDEX:-}" "${GOAL_NAME:-}")"

ATTEMPT=1
MAX_ATTEMPTS=3
LAST_ERROR=""

while [ "$ATTEMPT" -le "$MAX_ATTEMPTS" ]; do
  # One-line attempt header. Do NOT log the full prompt here — it is large
  # and floods stderr on retry. The attempt number is the only signal needed.
  echo "stride-ideation: dispatching requirements-decomposer (attempt $ATTEMPT/$MAX_ATTEMPTS)" >&2

  RESULT="$(task subagent_type=requirements-decomposer description="Decompose requirements doc" prompt="$DECOMPOSER_PROMPT")"

  case "$(classify "$RESULT")" in
    success)
      # Extract the fenced JSON block and break out of the retry loop.
      break
      ;;
    transient)
      LAST_ERROR="$RESULT"
      if [ "$ATTEMPT" -lt "$MAX_ATTEMPTS" ]; then
        case "$ATTEMPT" in
          1) sleep 30  ;;
          2) sleep 90  ;;
        esac
        ATTEMPT=$(( ATTEMPT + 1 ))
        continue
      fi
      # Cap reached. Hand off to Step 7.5 (retry-exhaustion fallback): save
      # the assembled prompt + the last error to disk so the user can
      # hand-drive the decomposition without re-typing the prompt, then exit
      # non-zero WITHOUT attempting the Step 9 POST. The verbatim-error-surface
      # principle of Step 9c is preserved — $LAST_ERROR is recorded in the
      # saved file's "Last error" section unchanged.
      step_7_5_save_prompt_and_exit "$DECOMPOSER_PROMPT" "$LAST_ERROR"
      # step_7_5_save_prompt_and_exit always exits non-zero — control never returns.
      ;;
    terminal)
      # Bad subagent name, contract violation, or non-529 hard 4xx.
      # Retrying will not change the result — fail fast.
      echo "stride-ideation: requirements-decomposer dispatch failed (not retryable). Error:" >&2
      printf '%s\n' "$RESULT" >&2
      exit 1
      ;;
  esac
done
```

**(7d) Extracting the JSON.** On `success`, the contract is: **a single fenced ```json document, no prose outside.** Extract the fenced JSON block. If the response contains anything outside the fence — narrative preamble, multiple JSON blocks, a markdown summary — strip the prose and use ONLY the fenced JSON content. (A response with no fenced JSON block at all, multiple ambiguous fenced blocks, or unparseable JSON inside the fence is a `terminal` classification per the table above — not a `success` — and the loop exits via the terminal branch.)

**(7e) Per-goal prompt scoping.** When `GOAL_SLUG` is unset (the `--goal` flag was absent), the prompt is the unmodified requirements doc text fenced inside a `Requirements document:` block — historical behavior is preserved byte-for-byte.

When `GOAL_SLUG` is set, build a scoped prompt in two layers:

1. **Doc surgery.** Use `sti_scope_doc_to_seam` from `lib/filename.sh` to produce a copy of the doc with its `## Decomposition seams` section pruned to keep only the matched seam item. Everything OUTSIDE the seams section (the seven gated sections — Problem, Goal, Outcome, Assumptions, Constraints, Non-goals, Success metrics — plus any Sketch or Open questions content) is preserved verbatim, so the subagent retains the full shared context. Inside the section, intro and trailing prose are dropped and replaced with a one-line notice — only the matched item's lines (start line + any continuation lines until the next item or the section's end) remain. `sti_scope_doc_to_seam` indexes the same items as `sti_extract_seams`, so `GOAL_INDEX` always selects the seam Step 2b resolved, whichever shape the section uses.

   ```bash
   # Carried forward: REQUIREMENTS_PATH, GOAL_INDEX
   : "${REQUIREMENTS_PATH:?stride-ideation: REQUIREMENTS_PATH was not carried forward from Step 1}"
   : "${GOAL_INDEX:?stride-ideation: GOAL_INDEX was not carried forward from Step 2b}"
   # Find the helpers: the project install, then the global install, then a stride-opencode-ideation checkout.
   STI_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
   if [ -f "$STI_ROOT/.opencode/stride-ideation/lib/filename.sh" ]; then STI_LIB="$STI_ROOT/.opencode/stride-ideation/lib"
   elif [ -f "${HOME:-}/.config/opencode/stride-ideation/lib/filename.sh" ]; then STI_LIB="$HOME/.config/opencode/stride-ideation/lib"
   elif [ -f "$STI_ROOT/commands/stridify.md" ] && [ -f "$STI_ROOT/commands/ideate.md" ] && [ -f "$STI_ROOT/install.sh" ] && [ -f "$STI_ROOT/AGENTS.md" ] && [ -d "$STI_ROOT/skills" ] && [ -f "$STI_ROOT/lib/filename.sh" ]; then STI_LIB="$STI_ROOT/lib"
   else echo "stride-ideation: cannot find the stride-ideation helpers in .opencode/stride-ideation/lib, ~/.config/opencode/stride-ideation/lib or a stride-opencode-ideation checkout — run install.sh, then retry this step" >&2; exit 1; fi
   . "$STI_LIB/filename.sh" || exit 1

   sti_scope_doc_to_seam "$REQUIREMENTS_PATH" "$GOAL_INDEX" || exit 1
   ```

   Its stdout is `SCOPED_DOC`. It goes into the dispatch prompt only — never paste it back into a `bash` call.

2. **Prompt directive.** Prepend a one-line directive above the `Requirements document:` fence telling the subagent the target surface verbatim, so a contract regression in the subagent (it ignores the scoped section and emits all seams it can infer) is at least called out explicitly:

   > `Decompose ONLY the surface named "<GOAL_NAME>" (item <GOAL_INDEX> in the Decomposition seams section). Produce a single-goal batch JSON; do NOT emit other surfaces even if mentioned.`

The dispatch's `prompt` is then the directive line + a blank line + `Requirements document:` + a blank line + the fenced contents of `$SCOPED_DOC`. The on-disk JSON written in Step 8 must still satisfy the validator at `lib/validate_batch.py` — root-key `goals` with at least one entry. In `--goal` mode the validator's check (c) `empty_goals` still applies; a multi-goal output is shape-valid (the validator does not enforce single-goal-ness), so semantic correctness rests on the directive + the surgery.

The reduced prompt size has a second benefit beyond intent: it lowers the per-dispatch token count, which correlates with both lower HTTP 529 risk and shorter roundtrips — one of the two motivations behind this flag's existence.

### Step 7.5: Retry-exhaustion fallback — save prompt and exit

Reached **only** when the Step 7c retry loop hits `MAX_ATTEMPTS` with three consecutive `transient` classifications (the loop's transient → cap-reached branch). When this happens, the user has hit a sustained capacity event longer than the ~2-minute budget; the bounded retry has done its job and now the cheapest recovery is "hand-drive the decomposition" — paste the prompt that was about to be dispatched into a fresh decomposition-capable session, then resume from the resulting JSON.

**Hard rule: the Stride API POST is NOT attempted in this branch.** Step 8 (validate / stamp / write batch JSON) is also skipped — there is no batch JSON to write, only the prompt that would have produced one. Exit non-zero before Step 8.

**(7.5a) Compute the saved-prompt sibling path.** Use `sti_unique_path` with artifact `decomposer-prompt` and extension `md`. Reuse the same `SLUG_FOR_PATH` computation from Step 5 so per-goal exhaustions land with the goal slug in the filename (e.g., `2026-05-15T210800-review-queue-code-diffs-kanban-app-decomposer-prompt.md`). The collision discriminator is identical to Step 5 — reruns that also exhaust produce `-2`, `-3`, … siblings; existing files are never overwritten.

```bash
# Carried forward: REQUIREMENTS_PATH, SOURCE_TS, SLUG_FOR_PATH
: "${REQUIREMENTS_PATH:?stride-ideation: REQUIREMENTS_PATH was not carried forward from Step 1}"
: "${SOURCE_TS:?stride-ideation: SOURCE_TS was not carried forward from Step 4}"
: "${SLUG_FOR_PATH:?stride-ideation: SLUG_FOR_PATH was not carried forward from Step 5}"
# Find the helpers: the project install, then the global install, then a stride-opencode-ideation checkout.
STI_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
if [ -f "$STI_ROOT/.opencode/stride-ideation/lib/filename.sh" ]; then STI_LIB="$STI_ROOT/.opencode/stride-ideation/lib"
elif [ -f "${HOME:-}/.config/opencode/stride-ideation/lib/filename.sh" ]; then STI_LIB="$HOME/.config/opencode/stride-ideation/lib"
elif [ -f "$STI_ROOT/commands/stridify.md" ] && [ -f "$STI_ROOT/commands/ideate.md" ] && [ -f "$STI_ROOT/install.sh" ] && [ -f "$STI_ROOT/AGENTS.md" ] && [ -d "$STI_ROOT/skills" ] && [ -f "$STI_ROOT/lib/filename.sh" ]; then STI_LIB="$STI_ROOT/lib"
else echo "stride-ideation: cannot find the stride-ideation helpers in .opencode/stride-ideation/lib, ~/.config/opencode/stride-ideation/lib or a stride-opencode-ideation checkout — run install.sh, then retry this step" >&2; exit 1; fi
. "$STI_LIB/filename.sh" || exit 1

PROMPT_PATH="$(sti_unique_path "$(dirname "$REQUIREMENTS_PATH")" "$SOURCE_TS" "$SLUG_FOR_PATH" decomposer-prompt md)" || exit 1
printf 'carry: PROMPT_PATH=%s\n' "$PROMPT_PATH"
printf 'carry: STI_LIB=%s\n' "$(cd "$STI_LIB" && pwd -P)"
```

The `STI_LIB` value is the absolute helper directory; the saved file's recovery instructions name it so they work from any directory.

**(7.5b) Compose the file body.** Write a markdown document with these sections, in this order. The structure is fixed so a downstream reader (human, future tool) can parse it. Fill `<STI_LIB>` with the absolute value Step 7.5a printed:

```markdown
# Decomposer Prompt — Saved After Retry Exhaustion

- **Saved at:** <ISO8601 UTC timestamp, e.g. 2026-05-12T103045Z>
- **Source requirements doc:** <REQUIREMENTS_PATH>
- **Source SHA-256:** <SOURCE_SHA>
- **Per-goal scope:** <one of: "all goals (no --goal flag)" OR "<GOAL_NAME> (index <GOAL_INDEX>, slug <GOAL_SLUG>)">
- **Attempts before exhaustion:** 3

## Last error from subagent

<verbatim contents of $LAST_ERROR>

## Subagent prompt (literal — paste this into a fresh session)

<the literal $DECOMPOSER_PROMPT, fenced inside a four-backtick block to allow the prompt's own ```json fences to nest cleanly>

## Recovery instructions

Paste the prompt block above into a fresh session — any model capable
of following the requirements-decomposer contract works (`agents/requirements-decomposer.md`
documents the contract). The session does NOT need codebase access. Save the
resulting fenced ```json block as `<BATCH_TARGET_PATH>` (the target path
computed by Step 5; for the run that produced this file, that path was
`<TARGET_PATH>`). Then run:

    python3 <STI_LIB>/validate_batch.py <BATCH_TARGET_PATH>

to confirm the JSON passes the validator's named checks (see Step 8a of
`commands/stridify.md`; the validator's own header lists them). On success, ship it exactly as Step 9 of
`commands/stridify.md` does:

    bash <STI_LIB>/ship.sh <BATCH_TARGET_PATH>

which reads `.stride_auth.md`, strips the audit fields, POSTs the batch and
renders the created identifiers in one process — never a hand-written curl.
`<STI_LIB>` was the helper directory when this file was saved; if the
extension has been reinstalled or moved since, use
`.opencode/stride-ideation/lib` (project install) or
`~/.config/opencode/stride-ideation/lib` (global install) instead.

This sibling file contains NO authentication material. The Stride API token
never enters the decomposer prompt (the subagent has no API access), so there
is no token in the saved prompt or the recovery README.
```

**(7.5c) Write the file and print the recovery summary.** Use the `write` tool to write the file. On a `write` failure (disk full, permission denied, etc.) surface the error verbatim AND still print the prompt body to stderr — losing the in-memory prompt to a swallowed `write` error is the worst outcome here, far worse than a noisy stderr dump.

After the file is written, print a concise terminal summary that names the saved-prompt path and the next concrete action:

```
stride-ideation: retries exhausted (3/3 transient failures).
Saved decomposer prompt to: <PROMPT_PATH>
Last error from the final attempt:
  <first line of $LAST_ERROR — the saved file holds the full verbatim error>

To recover: paste the prompt block from that file into a fresh
session; save the JSON response as <TARGET_PATH>; then run
`python3 <STI_LIB>/validate_batch.py <TARGET_PATH>` and
`bash <STI_LIB>/ship.sh <TARGET_PATH>` (Step 9 of commands/stridify.md).

The Stride API POST was NOT attempted.
```

Then `exit 1`. **No Stride API POST runs in this branch.**

**Pitfalls honored in this step:**

- The saved file contains the prompt and a recovery README — **never** the Stride API token, the bearer header, or any other auth material. The decomposer prompt has no auth context to begin with (the subagent cannot make Stride API calls), so this is enforced by construction. The doc still calls it out so a future edit cannot quietly leak credentials by widening what gets saved.
- **No partial / malformed batch JSON** is written to disk in this branch. Only the saved-prompt markdown file. A half-baked `*.stride-batch.json` saved here would look like a real artifact and would be picked up by tools that scan for stride-batch siblings.
- **No silent overwrite** — `sti_unique_path` discriminates with `-2`/`-3` suffixes per its hard invariant.
- **No POST after fallback** — the function exits before Step 8 even starts.

### Step 8: Validate output, stamp audit fields, write, and commit

Four sub-steps that together produce the on-disk audit artifact.

**(8a) Validate the subagent output.** First use the `write` tool to write the JSON extracted in Step 7d, verbatim, to `.stride/stridify-subagent-output.json` (the scratch directory `/ideate` also uses; the file is overwritten on every run and never committed). The subagent's output is untrusted, so it never goes into a `bash` call itself — no heredoc, no `printf`, no variable. Then run the structural validator at `lib/validate_batch.py` on that file. The validator owns the canonical implementation of every check; the command body delegates and surfaces the validator's stderr verbatim on failure:

```bash
# Carried forward: none (the JSON is in the scratch file written just before this call)
# Find the helpers: the project install, then the global install, then a stride-opencode-ideation checkout.
STI_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
if [ -f "$STI_ROOT/.opencode/stride-ideation/lib/filename.sh" ]; then STI_LIB="$STI_ROOT/.opencode/stride-ideation/lib"
elif [ -f "${HOME:-}/.config/opencode/stride-ideation/lib/filename.sh" ]; then STI_LIB="$HOME/.config/opencode/stride-ideation/lib"
elif [ -f "$STI_ROOT/commands/stridify.md" ] && [ -f "$STI_ROOT/commands/ideate.md" ] && [ -f "$STI_ROOT/install.sh" ] && [ -f "$STI_ROOT/AGENTS.md" ] && [ -d "$STI_ROOT/skills" ] && [ -f "$STI_ROOT/lib/filename.sh" ]; then STI_LIB="$STI_ROOT/lib"
else echo "stride-ideation: cannot find the stride-ideation helpers in .opencode/stride-ideation/lib, ~/.config/opencode/stride-ideation/lib or a stride-opencode-ideation checkout — run install.sh, then retry this step" >&2; exit 1; fi
python3 "$STI_LIB/validate_batch.py" .stride/stridify-subagent-output.json || exit 1
```

The validator enforces these named checks, in order (`lib/validate_batch.py`'s header is the authoritative list):

| Check | Failure mode | Example error message |
|---|---|---|
| (a) `parse_error` | Input is not valid JSON | `JSON parse failed at line 3 col 7 (char 24): Expecting property name enclosed in double quotes` |
| (b) `wrong_root_key` | Root has `tasks` instead of `goals`, a stray `tasks` alongside `goals`, or any other key in place of `goals` | `root key 'tasks' is the most common batch-API mistake — Stride's POST /api/tasks/batch requires root key 'goals'` |
| (c) `empty_goals` | `goals` missing, not an array, or empty | `root.goals is an empty array — the decomposer returned no goals` |
| (d) `goal_missing_field` | A goal lacks `title`, `type`, or `tasks`; or a task is not an object with a non-empty string `title` and a `type` of `work` or `defect` (a task typed `goal` fails) | `goals[0].tasks[1] is missing required field 'type'` |
| (e) `bad_dependency_index` | A task's `dependencies[]` index is out of range, negative, or a forward / self reference | `goals[0].tasks[1].dependencies references index 5 but goal only has 2 tasks (valid indices 0..1)` |

A validation failure here is a **subagent regression** — the requirements-decomposer agent's contract guarantees a valid root-key=`goals` JSON. If you see one, the agent's prompt has drifted; surface the validator message verbatim and stop. Beyond each task's `title` and `type`, the validator does NOT check per-task Stride-API field shapes — those are the decomposer agent's responsibility, and any slip-through surfaces as a verbatim 422 in Step 9.

After the validator returns zero, also confirm that `decomposition_notes` exists at the root. It is required by the subagent contract for documenting cross-goal claim ordering. If the key is missing, set it to an empty string before the next sub-step and emit a one-line warning — but do NOT fail; some single-goal decompositions legitimately have nothing cross-goal to document.

**(8b) Stamp source_spec and source_spec_sha256.** Inject the local-audit fields at the JSON root. The output JSON MUST have these exact root keys in this exact order (so a human reading the file sees the audit metadata at the top before the goal payload):

```json
{
  "source_spec": "<SOURCE_SPEC>",
  "source_spec_sha256": "<SOURCE_SHA>",
  "decomposition_notes": "...subagent value...",
  "goals": [...subagent value...]
}
```

Use the **normalized** `SOURCE_SPEC` from Step 6 (relative to repo root, or absolute as fallback) — not the raw `$REQUIREMENTS_PATH`. The hex string MUST be **lowercase** for canonical comparison.

**Defensive overwrite.** The decomposer subagent's prompt at `agents/requirements-decomposer.md` explicitly tells the agent NOT to emit `source_spec` or `source_spec_sha256` — but if the agent emits them anyway (regression, prompt drift), this command **always overwrites** them with values computed in Step 6. Never preserve agent-supplied values for these two keys. Concretely, when serializing the merged JSON:

1. Start from the subagent's output object.
2. **Delete** any `source_spec` and `source_spec_sha256` keys the subagent included.
3. Build a new object whose iteration order is `source_spec`, `source_spec_sha256`, `decomposition_notes`, `goals`.

This is the ONLY mutation made to the subagent's output — every other field (per-goal title, tasks, pitfalls, etc.) is preserved verbatim. The three audit fields are stripped from the API payload in Step 9; they remain on disk as the audit trail that pairs this batch JSON with its source requirements doc.

**(8c) Verify path uniqueness and write the file.** Re-run `sti_unique_path` with the same arguments as Step 5 to confirm `TARGET_PATH` is still untaken. If a colliding file appeared between Step 5 and now (concurrent process, manual filesystem action), use the freshly resolved path — never overwrite an existing file. Carry the `TARGET_PATH` this fragment prints into the write and Step 8d:

```bash
# Carried forward: REQUIREMENTS_PATH, SOURCE_TS, SLUG_FOR_PATH, TARGET_PATH
: "${REQUIREMENTS_PATH:?stride-ideation: REQUIREMENTS_PATH was not carried forward from Step 1}"
: "${SOURCE_TS:?stride-ideation: SOURCE_TS was not carried forward from Step 4}"
: "${SLUG_FOR_PATH:?stride-ideation: SLUG_FOR_PATH was not carried forward from Step 5}"
: "${TARGET_PATH:?stride-ideation: TARGET_PATH was not carried forward from Step 5}"
# Find the helpers: the project install, then the global install, then a stride-opencode-ideation checkout.
STI_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
if [ -f "$STI_ROOT/.opencode/stride-ideation/lib/filename.sh" ]; then STI_LIB="$STI_ROOT/.opencode/stride-ideation/lib"
elif [ -f "${HOME:-}/.config/opencode/stride-ideation/lib/filename.sh" ]; then STI_LIB="$HOME/.config/opencode/stride-ideation/lib"
elif [ -f "$STI_ROOT/commands/stridify.md" ] && [ -f "$STI_ROOT/commands/ideate.md" ] && [ -f "$STI_ROOT/install.sh" ] && [ -f "$STI_ROOT/AGENTS.md" ] && [ -d "$STI_ROOT/skills" ] && [ -f "$STI_ROOT/lib/filename.sh" ]; then STI_LIB="$STI_ROOT/lib"
else echo "stride-ideation: cannot find the stride-ideation helpers in .opencode/stride-ideation/lib, ~/.config/opencode/stride-ideation/lib or a stride-opencode-ideation checkout — run install.sh, then retry this step" >&2; exit 1; fi
. "$STI_LIB/filename.sh" || exit 1

RECHECKED_PATH="$(sti_unique_path "$(dirname "$REQUIREMENTS_PATH")" "$SOURCE_TS" "$SLUG_FOR_PATH" stride-batch json)" || exit 1
if [ "$RECHECKED_PATH" != "$TARGET_PATH" ]; then
  echo "stride-ideation: $TARGET_PATH was taken since Step 5; writing to $RECHECKED_PATH instead" >&2
fi
printf 'carry: TARGET_PATH=%s\n' "$RECHECKED_PATH"
```

Use the `write` tool to write the JSON document to the resolved target path. The directory containing `REQUIREMENTS_PATH` already exists (it housed the source doc), so no `mkdir -p` is needed.

**(8d) Commit.**

```bash
# Carried forward: TARGET_PATH, SLUG, GOAL_SLUG (empty without --goal)
: "${TARGET_PATH:?stride-ideation: TARGET_PATH was not carried forward from Step 8c}"
: "${SLUG:?stride-ideation: SLUG was not carried forward from Step 4}"
: "${GOAL_SLUG?stride-ideation: GOAL_SLUG was not carried forward from Step 2b}"
# A carried value that names a directory would let git add sweep in every
# untracked file under it; only the written artifact itself is committed.
if [ ! -f "$TARGET_PATH" ] || [ -L "$TARGET_PATH" ]; then
  echo "stride-ideation: $TARGET_PATH is not the written artifact (not a regular file); nothing was committed" >&2
  exit 1
fi
# Commit ONLY the batch JSON: the pathspec after -- keeps anything the user
# had already staged staged and out of this commit. --literal-pathspecs makes
# a path containing * or a leading : match only itself.
git --literal-pathspecs add -- "$TARGET_PATH" || exit 1
if [ -n "$GOAL_SLUG" ]; then
  git --literal-pathspecs commit -m "stride-ideation: decomposition for $SLUG goal $GOAL_SLUG" -- "$TARGET_PATH" || exit 1
else
  git --literal-pathspecs commit -m "stride-ideation: decomposition for $SLUG" -- "$TARGET_PATH" || exit 1
fi

# BATCH_PATH is the name the ship-side steps below use for the same file.
printf 'carry: BATCH_PATH=%s\n' "$TARGET_PATH"
```

When `--goal` was set, the commit message gains the goal slug so the audit trail records WHICH surface this batch covers — important when multiple per-goal commits ride on the same source requirements doc (their `source_spec_sha256` values match, but their commit subjects disambiguate).

`git add <path>` alone does not keep unrelated work out of this commit: a plain `git commit` commits everything already staged, including files the user staged before running `/stridify`. So the fragment passes the batch path as a pathspec after `--`, which commits that one file and leaves every other staged change staged and uncommitted; `--literal-pathspecs` makes git match that path literally, so a directory or slug containing `*` or a leading `:` cannot widen the match. Keep the `git add` — a pathspec commit of a still-untracked file fails — and never use `git add -A` or `git commit -a`. The source requirements doc is NOT in the commit's file list — `/stridify` reads it but never modifies it.

> **Drift check omitted.** The historical `/ship` command ran a `source_spec_sha256` drift check at this point to catch the case where the user hand-edited the requirements doc between `/decompose` and `/ship`. In the merged `/stridify` flow the batch JSON was just written by this command in the current invocation, so source drift cannot have occurred. The check is skipped.

### Step 8.5: Preview the decomposed tree and gate on human approval

The batch JSON is on disk and committed, but nothing has been sent to Stride yet. Before the Step 9 POST, show the human the goal/task tree that is about to be created and require explicit approval — unless `AUTO_APPROVE` was set in Step 1, in which case this entire step is skipped and control falls straight through to Step 9. This is the single point where a human can catch a bad decomposition before it lands in the workspace.

**(8.5a) Render the tree from the on-disk batch JSON.** Read `$BATCH_PATH` (never `.stride_auth.md`) and print each goal title, its task count, its task titles, and the cross-goal claim order from `decomposition_notes`. The render reads only the on-disk JSON, which contains no auth material — do NOT enrich it from the auth file or any other secret, and never print the token. Reuse the Step 10 identifier-render style, adapted to the pre-POST on-disk shape (no identifiers exist yet — the Stride API assigns G/W identifiers on POST):

```bash
# Carried forward: BATCH_PATH
: "${BATCH_PATH:?stride-ideation: BATCH_PATH was not carried forward from Step 8d}"
python3 - "$BATCH_PATH" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as fp:
    data = json.load(fp)

goals = data.get("goals", [])
notes = data.get("decomposition_notes", "")

print()
print("Goals and tasks to be created:")
print()
for goal in goals:
    title = goal.get("title", "(no title)")
    tasks = goal.get("tasks", []) or []
    n = len(tasks)
    print(f"  Goal: {title}  ({n} task{'s' if n != 1 else ''})")
    for task in tasks:
        print(f"    - {task.get('title', '(no title)')}")
print()
if notes:
    print("Cross-goal claim order:")
    print(f"  {notes}")
    print()
PY
```

**(8.5b) Bypass when `--yes` / `--auto-approve` was set.** If `AUTO_APPROVE` is `true`, the human opted out of the gate explicitly: skip the prompt entirely and proceed to Step 9. Do NOT prompt, do NOT block — scripted and non-interactive callers depend on this path staying byte-for-byte identical to the historical fire-and-forget flow. (The tree render in 8.5a is still printed so the log carries a record of what was shipped, but no interaction is required.)

**(8.5c) Otherwise, require explicit approval.** When `AUTO_APPROVE` is unset, ask the human via OpenCode's `question` tool (the same prompt mechanism `/ideate` uses — NOT Claude Code's `AskUserQuestion`) whether to create these goals and tasks in Stride. Proceed to Step 9 **only** on an explicit approval.

On **decline**, stop cleanly:

```bash
# Carried forward: BATCH_PATH
: "${BATCH_PATH:?stride-ideation: BATCH_PATH was not carried forward from Step 8d}"
# Find the helpers: the project install, then the global install, then a stride-opencode-ideation checkout.
STI_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
if [ -f "$STI_ROOT/.opencode/stride-ideation/lib/filename.sh" ]; then STI_LIB="$STI_ROOT/.opencode/stride-ideation/lib"
elif [ -f "${HOME:-}/.config/opencode/stride-ideation/lib/filename.sh" ]; then STI_LIB="$HOME/.config/opencode/stride-ideation/lib"
elif [ -f "$STI_ROOT/commands/stridify.md" ] && [ -f "$STI_ROOT/commands/ideate.md" ] && [ -f "$STI_ROOT/install.sh" ] && [ -f "$STI_ROOT/AGENTS.md" ] && [ -d "$STI_ROOT/skills" ] && [ -f "$STI_ROOT/lib/filename.sh" ]; then STI_LIB="$STI_ROOT/lib"
else echo "stride-ideation: cannot find the stride-ideation helpers in .opencode/stride-ideation/lib, ~/.config/opencode/stride-ideation/lib or a stride-opencode-ideation checkout — run install.sh, then retry this step" >&2; exit 1; fi
echo "stride-ideation: declined. The batch JSON is on disk at $BATCH_PATH" >&2
echo "(committed in git). Ship it later, unchanged, with: bash $STI_LIB/ship.sh \"$BATCH_PATH\"" >&2
exit 0
```

The decline path is a deliberate user choice, not a failure — exit `0`. **Do NOT delete or rewrite the on-disk batch JSON on decline**: it is the recovery artifact, already committed, and `lib/ship.sh` per Step 9 can ship it unchanged later (a `/stridify` re-run would decompose again and produce a different batch). The token is never printed in the preview or the gate output, and no POST is attempted before approval.

### Step 9: Ship the batch — strip, POST, branch on HTTP status, render

One invocation does all of it, in one process:

```bash
# Carried forward: BATCH_PATH
: "${BATCH_PATH:?stride-ideation: BATCH_PATH was not carried forward from Step 8d}"
# Find the helpers: the project install, then the global install, then a stride-opencode-ideation checkout.
STI_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
if [ -f "$STI_ROOT/.opencode/stride-ideation/lib/filename.sh" ]; then STI_LIB="$STI_ROOT/.opencode/stride-ideation/lib"
elif [ -f "${HOME:-}/.config/opencode/stride-ideation/lib/filename.sh" ]; then STI_LIB="$HOME/.config/opencode/stride-ideation/lib"
elif [ -f "$STI_ROOT/commands/stridify.md" ] && [ -f "$STI_ROOT/commands/ideate.md" ] && [ -f "$STI_ROOT/install.sh" ] && [ -f "$STI_ROOT/AGENTS.md" ] && [ -d "$STI_ROOT/skills" ] && [ -f "$STI_ROOT/lib/filename.sh" ]; then STI_LIB="$STI_ROOT/lib"
else echo "stride-ideation: cannot find the stride-ideation helpers in .opencode/stride-ideation/lib, ~/.config/opencode/stride-ideation/lib or a stride-opencode-ideation checkout — run install.sh, then retry this step" >&2; exit 1; fi
bash "$STI_LIB/ship.sh" "$BATCH_PATH"
```

Carry `BATCH_PATH` from Step 8d (each bash call is a fresh shell, so it is a value you carry forward, not a variable that still exists). Run it once and relay its output. **Exit 0 means the batch exists in Stride — never re-run it or hand-curl the batch after an exit 0**, even when the success table is missing (see the 9c table). Exit 1 means nothing was created by this call, or Stride rejected it; the user fixes the cause and re-invokes. Exit 2 is a usage error (nothing was sent). Exit 129, 130 or 143 means the script was interrupted (`HUP`, `INT`, `TERM`) — if that happened while the POST was in flight the batch **may already exist**, so do not re-run: tell the user to check the Stride workspace's Backlog column first. The script's stdout and stderr never contain the token — it turns off a caller's `xtrace` and `allexport`, and scrubs the token and any `Bearer <value>` from every body or curl message it prints — so relaying its output verbatim is safe.

What the script does, in order (documented here so the behavior is reviewable without reading the script):

**(9a) Strip local-audit fields.** This runs before auth is read, so no child process the script starts before the POST ever sees the token. The batch JSON on disk contains three local-audit fields (`source_spec`, `source_spec_sha256`, `decomposition_notes`) that the Stride API does not accept. `lib/strip_audit_fields.py` removes them into a mode-600 temp file under the system temp dir; the on-disk batch JSON is unchanged, so the audit fields stay available for tools that read it later. The script then runs `lib/validate_batch.py` on that exact payload, so a file edited after Step 8 still cannot ship unvalidated. On failure: a one-line `stride-ideation:` message, exit 1, nothing POSTed.

The per-goal `created_by_agent` stamped in Step 8b is deliberately **not** in the strip set — it is a create-payload field the API accepts and persists for attribution, not a local audit field. It must survive this step and reach the wire; adding it to `lib/strip_audit_fields.py`'s strip list would silently un-attribute every shipped batch.

**(9b) POST to the Stride batch endpoint.** Auth is read afresh through `lib/read_auth.py` (same lookup and same failure messages as Step 3). A payload that contains the configured API token is refused before anything is sent. The `Authorization` header is piped to curl as a config on its stdin (`curl -K -`, written by the shell's `printf` builtin), so the token is never on argv and never on disk; the payload goes with `--data-binary @<file>`, never `-d "<json>"` — so neither the token nor the batch appears in `ps`, and a large batch cannot hit the argument-length limit. curl runs with `-q` first (no `~/.curlrc`), with `-g` (a `{}` or `[]` in the URL is never expanded into a repeated POST), and never with `-v`. Every temp file — payload, response body, curl stderr — is created mode 600 under the system temp dir and removed on success, on failure, and on interrupt (`INT`, `TERM`, `HUP`).

If `curl` failed at the transport layer (non-zero exit, or an empty / `000` status), the script prints `stride-ideation: HTTP request failed before the Stride API responded:` followed by curl's **verbatim** stderr (token-scrubbed) — never a generic "something went wrong" wrapper; the actual cause (DNS resolution failure, connection refused, TLS handshake error, timeout) is the load-bearing diagnostic. Exit 1.

The on-disk batch JSON written in Step 8 is the recovery artifact: if the POST fails for any reason, the user has a complete, audited batch document on disk and in git, and `lib/ship.sh` can ship that file later without re-running the decomposer.

**(9c) Branch on the HTTP status code.** **Hard rule for every non-2xx branch: the response body is printed verbatim.** It is not parsed, reformatted, or summarized — the user needs the literal bytes the Stride API returned to debug the failure. Stride's 422 responses in particular carry a `details` array naming the offending field(s). **The one exception is the token:** before printing, the script replaces the token (also in JSON-escaped or percent-encoded form), anything shaped like a Stride token, and the value of any `Bearer <value>` with `[REDACTED]`, because a development server's debug error page echoes the request headers.

| Status code | What `lib/ship.sh` does |
|---|---|
| 2xx | Renders the created identifiers (Step 10) and exits 0. |
| 2xx, body not renderable | The batch **was created**. Prints `stride-ideation: the batch was created (HTTP <code>), but the response could not be rendered — do NOT re-run /stridify ...`, then the body verbatim, and exits **0**. Relay it and stop: re-running would create every goal twice. |
| 2xx listing no goals | Prints `stride-ideation: Stride answered HTTP <code> but listed no created goals ...`, then the body, and exits **0**. Have the user check the Backlog column before re-running. |
| 4xx | `stride-ideation: Stride API rejected the batch (HTTP <code>). Response body:`, then the full body verbatim. Exit 1. |
| 5xx | `stride-ideation: Stride API returned HTTP <code>. Response body:`, then the full body verbatim. Exit 1. `/stridify` does NOT retry, does NOT exponential-backoff, does NOT rate-limit. |
| Other (1xx, 3xx) | `stride-ideation: unexpected HTTP status <code>. Response body:`, then the full body verbatim. Exit 1. |
| Transport failure | As in 9b: the header line plus curl's verbatim stderr. Exit 1. |

**No retries.** When `/stridify` fails on a 4xx or 5xx, the user is the retry mechanism: they read the verbatim body, fix the underlying issue (regenerate the requirements doc and re-run `/stridify`, hand-edit the on-disk batch JSON and ship it with `lib/ship.sh`, wait out a transient 5xx, etc.), and re-invoke. Stride does not guarantee per-task idempotency on a partially-failed batch, so an automatic retry could double-create some tasks while leaving others to fail again. Manual retry is the safer contract.

### Step 10: Render the created identifiers and print the terminal message

Nothing further to run — the Step 9 invocation already did this. On 2xx the Stride API returns the goals and child tasks with their auto-generated identifiers (G-prefix for goals, W-prefix for work tasks, D-prefix for defects): `{"success": true, "total": N, "goals": [{"goal": {...}, "child_tasks": [...]}]}`. The renderer also accepts the older flat shape (`identifier` / `title` / `tasks` on each goal entry, optionally under `data`). Every goal and task must carry an identifier; `lib/ship.sh` builds the whole table before printing any of it, so a response of an unexpected shape produces the do-not-re-run notice from 9c rather than half a table or a Python traceback.

The table format is two columns: identifier (right-aligned, 6 chars wide for `G123` / `W1234` etc.) followed by the title, with child tasks indented under their goal. A typical successful invocation produces output like:

```
Created goals and tasks:

    G99  stride-ideate v0.1 — /ideate command
   W404    Scaffold the stride-ideation plugin repo layout
   W405    Implement the timestamped filename generator
   W406    Write the stride-ideation SKILL.md
```

After the table, the script prints:

> Batch shipped successfully.
> The goals are now visible in the Stride workspace's Backlog column.

Do NOT print "next step:" suggestions, do NOT propose follow-on commands. The terminal state is the shipped batch.

## Resilience model

`/stridify` is designed to survive a transient Anthropic API capacity spike without losing the assembled prompt or producing partial Stride state. The model has four layers, in execution order: (1) **Preflight advisory** — Step 2 prints a one-line suggestion to use `--goal` when the doc enumerates more than 3 surfaces under `## Decomposition seams` (informational, never blocking). (2) **Per-goal partitioning** — Step 1's optional `--goal <name|index>` flag scopes the prompt to one surface from the doc's `## Decomposition seams` section, reducing per-dispatch token count and the blast radius of a single failure. (3) **Subagent dispatch retry** — Step 7c retries the requirements-decomposer dispatch up to **3 attempts** with ~30s / ~90s backoff (total budget ~2 min) when the failure classifies as transient (HTTP 529, network error, "overloaded" string). Terminal classifications (bad subagent name, contract violation, hard 4xx) fail fast on attempt 1 — retrying will not change the result. (4) **Retry-exhaustion fallback** — Step 7.5 writes the assembled prompt plus metadata to a sibling `<source-stem>-decomposer-prompt.md` file on exhaustion, with a recovery README naming the next concrete action (paste the prompt into a fresh session, save the JSON response at the target path, then run `lib/validate_batch.py` and `lib/ship.sh` per Step 9). **The Stride API POST itself is NOT retried** — Step 9 fails fast on 4xx/5xx and surfaces the response body verbatim. Per-task idempotency on a partially-failed batch is not guaranteed, so an automatic POST retry could double-create some tasks while leaving others to fail again; the recovery contract is "the user reads the verbatim body and re-invokes" rather than "the command retries automatically".

## What this command does NOT do

- **Validate Stride API field shapes** beyond root-key + structure — that's `lib/validate_batch.py`'s job; surface 422 errors verbatim if anything slips through.
- **Modify the source requirements doc** — read-only access. The doc is committed earlier (by `/ideate`) and is treated as the source of truth.
- **Re-run ideation** — if the doc is missing sections, the error message points the user at `/ideate --continue <path>` rather than auto-invoking it.
- **Strip `decomposition_notes` from the on-disk JSON** — that field is part of the saved artifact. The strip writes a temp copy for the POST in Step 9 (removed afterwards); the on-disk file keeps the audit fields.
- **Retry the Stride API POST on transient failures** — fail fast and let the user re-invoke. Idempotency on the Stride side is not guaranteed for partial batches, so an automatic POST retry could double-create some tasks while leaving others to fail again. (This is different from the Step 7 subagent dispatch, which **is** retried with bounded exponential backoff. Subagent dispatch has no Stride-side side effects, so retrying it is safe; a POSTed batch may have partially landed, so retrying it is not.)
- **Drift-check the requirements doc against the batch JSON** — historical `/ship` did this to catch human edits between `/decompose` and `/ship`. The merged flow writes the batch JSON in the current invocation, so source drift cannot have occurred and the check is omitted.
- **Re-validate that a `--goal` value matches the surface the subagent actually emitted** — the Step 7e prompt directive names the target surface, but the on-disk goal `title` is whatever the subagent produced. If the subagent drifts and emits a different surface name, Step 8a still gates root-shape (root key `goals`, non-empty), but a semantic mismatch between the requested `--goal` and the emitted goal `title` is currently surfaced only as whatever the user sees in the Stride backlog. Future hardening could add an Step 8a-extra assertion that `len(goals) == 1 && slugify(goals[0].title) == GOAL_SLUG`; today it is out of scope.
