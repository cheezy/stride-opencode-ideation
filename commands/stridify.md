---
description: "End-to-end pipeline from a stride-ideation requirements doc to created Stride goals. Validates the seven required sections, preflights auth, dispatches the requirements-decomposer subagent, stamps source_spec + source_spec_sha256, writes and commits a timestamped sibling batch JSON, then POSTs to the Stride API and renders the created G/W identifiers."
---

# /stridify

Read a stride-ideation requirements markdown document, decompose it into a Stride batch JSON (committed to disk for audit), and POST it to the Stride API in a single invocation. The decomposition logic — natural seams, sizing, multi-goal split rule, batch JSON shape — lives in `agents/requirements-decomposer.md`. This command is the surface: it parses the invocation arguments, validates the input, preflights auth, dispatches the subagent, stamps `source_spec` + `source_spec_sha256`, writes and commits the file, then strips local-audit fields, POSTs to `/api/tasks/batch`, and renders the created G/W identifiers.

**Usage:** `/stridify <path-to-requirements.md> [--goal <name|index>]`

The user's invocation arguments are available as `$ARGUMENTS`. Parse the requirements-doc path and the optional `--goal <name|index>` flag out of `$ARGUMENTS` per Step 1. The protocol contract for decomposition lives in the `stride-ideation` skill and the requirements-decomposer custom agent — this command defers to them and never reimplements the decomposition methodology.

When you need to run shell, execute it with `shell`, one command at a time, checking the result before proceeding.

## What to do

Follow these steps in order. Do NOT skip steps.

### Step 1: Parse `$ARGUMENTS`

The user invoked you with `$ARGUMENTS`. Parse in this fixed order — `--goal` first, then the trimmed remainder is `REQUIREMENTS_PATH`:

- If `--goal` appears, set `GOAL_ARG` to the value of the **next** token and remove both tokens — or, if the `--goal=<value>` form is used, set `GOAL_ARG` to the post-`=` portion (split on the FIRST `=` only, so a value containing `=` is preserved verbatim) and remove the single token. Accept both shapes — `--goal <value>` and `--goal=<value>` — matching how `/ideate` handles `--continue` and `--profile`. Do NOT validate `GOAL_ARG` here; resolution against the doc's `## Decomposition seams` section happens in new Step 2b, after the doc has been read and the seven-section gate has passed.
- If `--goal` is absent, leave `GOAL_ARG` and `GOAL_SLUG` unset. The command runs in its historical "all goals" mode.
- After flag tokens are consumed, trim the remainder and set `REQUIREMENTS_PATH`. If the remainder is empty, print *"Usage: `/stridify <path-to-requirements.md> [--goal <name|index>]`"* and exit non-zero.

### Step 2: Validate the requirements doc

Before doing any expensive work, the command must confirm the input is a real, parseable requirements doc produced by (or compatible with) `/ideate`. Run these checks in order; any failure prints a one-line error and exits non-zero:

1. **File exists and is a regular file.** Use `read_file` or `shell` with `test -f` to confirm. If missing, print *"stride-ideation: requirements doc not found at `<REQUIREMENTS_PATH>`"* and stop.

2. **Filename family matches.** The path SHOULD end in `-requirements.md`. If it does not, warn but proceed — the slug-extraction step below may still succeed for paths produced by older versions of the plugin, and the section-validation pass below is the authoritative check anyway.

3. **All seven hard-gated sections are present.** Use `grep_search` to verify that the file contains a level-2 heading for each of: `Problem`, `Goal`, `Outcome`, `Assumptions`, `Constraints`, `Non-goals`, `Success metrics`. Order is not enforced (the doc template orders Problem before Goal, but a hand-edited doc may differ). If any heading is missing, print:

   > *"stride-ideation: requirements doc is missing required section(s): `<list>`. Either re-run `/ideate --continue <path>` to fill them in, or hand-edit the doc to include the missing sections."*

   And exit non-zero. Do NOT proceed with a partial doc — the decomposer subagent's output quality depends on every section being substantive.

4. **Advisory: large-decomposition warning (no exit, never blocks).** If the doc contains a `## Decomposition seams` section AND `GOAL_ARG` is unset (the user did NOT invoke with `--goal`), count surface enumerations under that heading. If the count is **greater than 3**, print a single advisory line to stderr and continue execution — this is a UX hint, not a gate. When `--goal` IS set (per-goal mode), do NOT print this advisory — the user has already partitioned and emitting noise on top is counter-productive. When the seams section is absent or enumerates ≤3 surfaces, also skip the advisory.

   **Surface-count heuristic.** Inside the `## Decomposition seams` section body (from the heading exclusive to the next `^## ` heading or EOF), count lines that match any of these three shapes — surface enumerators are intentionally permissive because the section is freeform:

   | Shape | Pattern |
   |---|---|
   | Level-3 heading | `^### ` |
   | Numbered list item | `^[[:space:]]*[0-9]+\.[[:space:]]+` |
   | Bulleted list item | `^[[:space:]]*[-*][[:space:]]+` |

   Count each shape independently, then take the **MAX** across the three. The max-of-shapes rule is friendlier than sum-of-shapes when a section mixes a primary numbered list of surfaces with a secondary bulleted list of cross-cutting notes (e.g., "Shared contract" bullets, "Sequencing & dependencies" bullets) — those secondary bullets should not inflate the surface count.

   ```bash
   if [ -z "${GOAL_ARG:-}" ] && grep -qE '^## Decomposition seams[[:space:]]*$' "$REQUIREMENTS_PATH"; then
     SEAM_COUNT="$(awk '
       /^## Decomposition seams[[:space:]]*$/ { in_section=1; next }
       in_section && /^## / { in_section=0 }
       in_section && /^### / { h3++ }
       in_section && /^[[:space:]]*[0-9]+\.[[:space:]]+/ { num++ }
       in_section && /^[[:space:]]*[-*][[:space:]]+/ { bul++ }
       END {
         h3 = h3 + 0; num = num + 0; bul = bul + 0
         m = h3
         if (num > m) m = num
         if (bul > m) m = bul
         print m
       }
     ' "$REQUIREMENTS_PATH")"
     if [ "$SEAM_COUNT" -gt 3 ]; then
       echo "stride-ideation: requirements doc enumerates $SEAM_COUNT surfaces under Decomposition seams. Consider running /stridify --goal <name|index> $SEAM_COUNT times to reduce subagent-dispatch failure risk on large decompositions. Continuing with all-goals mode." >&2
     fi
   fi
   ```

   The advisory **never** exits non-zero — it is informational. Users who genuinely want all-goals mode on a 7-surface doc see the line once at the top of the run and ignore it; that is a deliberate trade-off, not a defect.

### Step 2b: Resolve `--goal` against `## Decomposition seams` (only if `--goal` was set)

This step runs **only when `GOAL_ARG` is set** (i.e., the user invoked with `--goal <value>`). If `GOAL_ARG` is empty, skip the entire step — the command stays in "all goals" mode and `GOAL_SLUG` remains unset.

The resolver is `sti_resolve_goal` in `lib/filename.sh`. It takes the requirements doc path and the `GOAL_ARG` string and emits `<index>\t<name>\t<slug>` on success. Source `filename.sh` (it is also sourced by Step 4 — sourcing twice is harmless):

```bash
. <plugin-root>/lib/filename.sh

if [ -n "${GOAL_ARG:-}" ]; then
  GOAL_RESOLVED="$(sti_resolve_goal "$REQUIREMENTS_PATH" "$GOAL_ARG")"
  GOAL_RC=$?
  case "$GOAL_RC" in
    0)
      GOAL_INDEX="$(printf '%s' "$GOAL_RESOLVED" | awk -F'\t' '{print $1}')"
      GOAL_NAME="$(printf '%s' "$GOAL_RESOLVED" | awk -F'\t' '{print $2}')"
      GOAL_SLUG="$(printf '%s' "$GOAL_RESOLVED" | awk -F'\t' '{print $3}')"
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
      sti_extract_seams "$REQUIREMENTS_PATH" | awk -F'\t' '{ printf "  %d. %s (slug: %s)\n", $1, $2, $3 }' >&2
      exit 1
      ;;
    *)
      echo "stride-ideation: --goal resolution failed (rc=$GOAL_RC) on $REQUIREMENTS_PATH" >&2
      exit 1
      ;;
  esac
fi
```

**Resolution rules** (implemented by `sti_resolve_goal`):

| `GOAL_ARG` shape | Resolution attempt | Fallback |
|---|---|---|
| Purely digits (matches `^[0-9]+$`) | 1-based integer index into the in-document order of `## Decomposition seams` items | If the index is out of range, fall through to slug-match (handles the edge case of a seam literally named `"1"`) |
| Anything else (contains a non-digit) | Slugify via `sti_slugify` and exact-compare against each seam's slug field; first match wins | None — unmatched values raise the rc=3 error above |

**Pitfalls honored here:**
- `--goal` is **not** silently ignored on no-match — every miss raises a non-zero exit with the verbatim "did not match" message and a printed list of the actual seams that ARE present.
- The seams section is **not** required in all docs — `GOAL_ARG` being unset means this step is a no-op. Only when the user explicitly opted into per-goal mode does the absence become an error.
- The parser does not couple to any markdown shape beyond "level-2 heading `## Decomposition seams` followed by a numbered list of `<N>. **Name** ...` items." Intro prose, trailing prose, and item bodies on subsequent lines are all tolerated — only the bold-named first line of each numbered item is used.

### Step 3: Preflight auth from `.stride_auth.md`

Read auth BEFORE the expensive subagent dispatch so a misconfigured `.stride_auth.md` fails fast without first burning a decomposer pass and writing a batch JSON that can't be shipped. Locate `.stride_auth.md` (the convention is `$CLAUDE_PROJECT_DIR/.stride_auth.md` — the same file the Stride orchestrator reads). Invoke `lib/read_auth.py` via `shell` and source its output:

```bash
AUTH_FILE="${CLAUDE_PROJECT_DIR:-$PWD}/.stride_auth.md"
if [ ! -f "$AUTH_FILE" ]; then
  echo "stride-ideation: .stride_auth.md not found at $AUTH_FILE" >&2
  exit 1
fi

# read_auth.py emits two STRIDE_API_URL= / STRIDE_API_TOKEN= lines.
# Source them, then unset the helper variable so the token isn't visible
# to subsequent `set` / `env` dumps inside the same shell.
AUTH_OUT="$(python3 "<plugin-root>/lib/read_auth.py" "$AUTH_FILE")" || {
  echo "stride-ideation: failed to read auth from $AUTH_FILE" >&2
  exit 1
}
eval "$AUTH_OUT"
unset AUTH_OUT
```

**Never log the token, ever, even in error paths.** This includes:
- Do NOT echo `$STRIDE_API_TOKEN` for diagnostics.
- Do NOT include the token in any error message the user sees.
- Do NOT pass the token on the command line of a process visible to `ps` — `curl -H "Authorization: Bearer $STRIDE_API_TOKEN"` is fine because curl reads the header value and does not expose it via `/proc/<pid>/cmdline` after parse.
- Do NOT save curl output that might echo the request headers back (`curl -v` dumps headers to stderr; never use `-v` here).

If `lib/read_auth.py` exits non-zero, surface its stderr (which is engineered to never contain the token value) and stop.

`$STRIDE_API_URL` and `$STRIDE_API_TOKEN` are now in the environment for use by the POST in Step 9. The token survives until Step 9 explicitly unsets it after the curl call.

### Step 4: Inherit the session timestamp and slug

Source `lib/filename.sh` and extract the inherited values from `REQUIREMENTS_PATH`, running each command via `shell`:

```bash
. <plugin-root>/lib/filename.sh

SOURCE_TS="$(basename "$REQUIREMENTS_PATH" | sed -E 's/^([0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{6})-.*$/\1/')"
SLUG="$(sti_slug_from_path "$REQUIREMENTS_PATH" requirements)"
```

`SOURCE_TS` is **inherited** from the source path so the decomposition JSON pairs cleanly with its requirements doc by filename prefix. Do NOT generate a fresh timestamp — the design spec explicitly couples the two artifacts by shared prefix.

If `sti_slug_from_path` exits non-zero (the path does not match the `YYYY-MM-DDTHHMMSS-<slug>-requirements.md` format), surface the error verbatim and stop.

### Step 5: Compute the target path (don't write yet)

Use `sti_unique_path` to compute the sibling output path. When `--goal` was set, append the goal slug to the doc slug so per-goal batches sit next to each other without collision:

```bash
SLUG_FOR_PATH="$SLUG"
if [ -n "${GOAL_SLUG:-}" ]; then
  SLUG_FOR_PATH="${SLUG}-${GOAL_SLUG}"
fi
TARGET_PATH="$(sti_unique_path "$(dirname "$REQUIREMENTS_PATH")" "$SOURCE_TS" "$SLUG_FOR_PATH" stride-batch json)"
```

`stride-batch` is the artifact name (not `requirements`), so the helper produces a sibling file like `2026-05-12T103000-add-notifications-stride-batch.json` next to the requirements doc. When `--goal` is set, the goal slug is appended between the doc slug and the `-stride-batch` token, producing e.g. `2026-05-15T210800-review-queue-code-diffs-kanban-app-stride-batch.json`.

If a stride-batch file with the inherited timestamp + slug already exists (rare — happens when `/stridify` is rerun on the same input, or when the same `--goal` is invoked twice on the same source doc), `sti_unique_path` appends `-2`, `-3`, … so the prior batch is preserved. **The HARD INVARIANT 'never overwrite an existing file' applies here too** and applies uniformly to both per-goal and full-decomposition runs.

Do NOT create or touch `TARGET_PATH` yet. A pre-created empty file would leave a half-baked artifact if the subagent dispatch fails or is interrupted.

### Step 6: Compute the source SHA-256 and normalize the source path

Compute the SHA-256 of the requirements doc and capture it for the orchestrator-injected fields:

```bash
SOURCE_SHA="$(shasum -a 256 "$REQUIREMENTS_PATH" | awk '{print $1}' | tr 'A-Z' 'a-z')"
```

If `shasum` is unavailable on the host (rare on macOS / Linux), fall back to `sha256sum "$REQUIREMENTS_PATH" | awk '{print $1}' | tr 'A-Z' 'a-z'`. The resulting hex string MUST be **lowercase** so the on-disk audit field is a stable, canonical value.

**Normalize `REQUIREMENTS_PATH` to a stable form** so the stamped `source_spec` value is consistent across invocations from different working directories. Two acceptable forms:

```bash
# Preferred: relative to the git repo root.
REPO_ROOT="$(git rev-parse --show-toplevel)"
SOURCE_SPEC="$(python3 -c "import os,sys; print(os.path.relpath(sys.argv[1], sys.argv[2]))" "$REQUIREMENTS_PATH" "$REPO_ROOT")"

# Fallback when not in a git repo: absolute path.
if [ -z "$SOURCE_SPEC" ] || [ "$SOURCE_SPEC" = ".." ] || [[ "$SOURCE_SPEC" == ../* ]]; then
  SOURCE_SPEC="$(cd "$(dirname "$REQUIREMENTS_PATH")" && pwd)/$(basename "$REQUIREMENTS_PATH")"
fi
```

Do NOT use the raw `$REQUIREMENTS_PATH` as `SOURCE_SPEC` — it depends on the user's current working directory at invocation time and would make the on-disk audit field brittle for tools that read the JSON later.

### Step 7: Dispatch the `requirements-decomposer` custom agent

Read the full content of the requirements doc and dispatch the requirements-decomposer custom agent. The dispatch is wrapped in a **bounded retry loop** so the command survives transient Anthropic API capacity spikes (HTTP 529 Overloaded). Subagent dispatch has no side effects on the Stride API — a retried call cannot double-create anything — so retrying it is safe in a way that retrying the Step 9 POST is not.

Dispatch the requirements-decomposer custom agent with a prompt consisting of the requirements doc text, fenced inside a "Requirements document:" block — the only input the subagent has access to.

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

  RESULT="$(dispatch requirements-decomposer custom agent with prompt=$DECOMPOSER_PROMPT)"

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

1. **Doc surgery.** Use `sti_scope_doc_to_seam` from `lib/filename.sh` to produce a copy of the doc with its `## Decomposition seams` section pruned to keep only the matched seam item. Everything OUTSIDE the seams section (the seven gated sections — Problem, Goal, Outcome, Assumptions, Constraints, Non-goals, Success metrics — plus any Sketch or Open questions content) is preserved verbatim, so the subagent retains the full shared context. Inside the section, intro and trailing prose are dropped and replaced with a one-line notice — only the matched numbered item's lines (start line + any continuation lines until the next item or the section's end) remain.

   ```bash
   SCOPED_DOC="$(sti_scope_doc_to_seam "$REQUIREMENTS_PATH" "$GOAL_INDEX")"
   ```

2. **Prompt directive.** Prepend a one-line directive above the `Requirements document:` fence telling the subagent the target surface verbatim, so a contract regression in the subagent (it ignores the scoped section and emits all seams it can infer) is at least called out explicitly:

   > `Decompose ONLY the surface named "<GOAL_NAME>" (item <GOAL_INDEX> in the Decomposition seams section). Produce a single-goal batch JSON; do NOT emit other surfaces even if mentioned.`

The dispatch's `prompt` is then the directive line + a blank line + `Requirements document:` + a blank line + the fenced contents of `$SCOPED_DOC`. The on-disk JSON written in Step 8 must still satisfy the validator at `lib/validate_batch.py` — root-key `goals` with at least one entry. In `--goal` mode the validator's check (c) `empty_goals` still applies; a multi-goal output is shape-valid (the validator does not enforce single-goal-ness), so semantic correctness rests on the directive + the surgery.

The reduced prompt size has a second benefit beyond intent: it lowers the per-dispatch token count, which correlates with both lower HTTP 529 risk and shorter roundtrips — one of the two motivations behind this flag's existence.

### Step 7.5: Retry-exhaustion fallback — save prompt and exit

Reached **only** when the Step 7c retry loop hits `MAX_ATTEMPTS` with three consecutive `transient` classifications (the loop's transient → cap-reached branch). When this happens, the user has hit a sustained capacity event longer than the ~2-minute budget; the bounded retry has done its job and now the cheapest recovery is "hand-drive the decomposition" — paste the prompt that was about to be dispatched into a fresh decomposition-capable session, then resume from the resulting JSON.

**Hard rule: the Stride API POST is NOT attempted in this branch.** Step 8 (validate / stamp / write batch JSON) is also skipped — there is no batch JSON to write, only the prompt that would have produced one. Exit non-zero before Step 8.

**(7.5a) Compute the saved-prompt sibling path.** Use `sti_unique_path` with artifact `decomposer-prompt` and extension `md`. Reuse the same `SLUG_FOR_PATH` computation from Step 5 so per-goal exhaustions land with the goal slug in the filename (e.g., `2026-05-15T210800-review-queue-code-diffs-kanban-app-decomposer-prompt.md`). The collision discriminator is identical to Step 5 — reruns that also exhaust produce `-2`, `-3`, … siblings; existing files are never overwritten.

```bash
PROMPT_PATH="$(sti_unique_path "$(dirname "$REQUIREMENTS_PATH")" "$SOURCE_TS" "$SLUG_FOR_PATH" decomposer-prompt md)"
```

**(7.5b) Compose the file body.** Write a markdown document with these sections, in this order. The structure is fixed so a downstream reader (human, future tool) can parse it:

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

    python3 <plugin-root>/lib/validate_batch.py <BATCH_TARGET_PATH>

to confirm the JSON parses against the validator's five named checks
(parse_error / wrong_root_key / empty_goals / goal_missing_field /
bad_dependency_index). On success, follow Step 9 of `commands/stridify.md`
manually: strip audit fields via `lib/strip_audit_fields.py`, POST the result
to `$STRIDE_API_URL/api/tasks/batch` with a Bearer token from
`.stride_auth.md`, and render the created identifiers per Step 10.

This sibling file contains NO authentication material. The Stride API token
never enters the decomposer prompt (the subagent has no API access), so there
is no token in the saved prompt or the recovery README.
```

**(7.5c) Write the file and print the recovery summary.** Use the `write_file` tool to write the file. On a `write_file` failure (disk full, permission denied, etc.) surface the error verbatim AND still print the prompt body to stderr — losing the in-memory prompt to a swallowed `write_file` error is the worst outcome here, far worse than a noisy stderr dump.

After the file is written, print a concise terminal summary that names the saved-prompt path and the next concrete action:

```
stride-ideation: retries exhausted (3/3 transient failures).
Saved decomposer prompt to: <PROMPT_PATH>
Last error from the final attempt:
  <first line of $LAST_ERROR — the saved file holds the full verbatim error>

To recover: paste the prompt block from that file into a fresh
session; save the JSON response as <TARGET_PATH>; then run
`python3 lib/validate_batch.py <TARGET_PATH>` and the manual POST per Step 9
of commands/stridify.md.

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

**(8a) Validate the subagent output.** Write the extracted JSON to a temporary file and run the structural validator at `lib/validate_batch.py`. The validator owns the canonical implementation of every check; the command body delegates and surfaces the validator's stderr verbatim on failure:

```bash
TMP_JSON="$(mktemp -t stride_stridify_validate.XXXXXX.json)"
printf '%s' "$RAW_SUBAGENT_JSON" > "$TMP_JSON"

if ! python3 "<plugin-root>/lib/validate_batch.py" "$TMP_JSON" 2>"$TMP_JSON.err"; then
  cat "$TMP_JSON.err" >&2
  rm -f "$TMP_JSON" "$TMP_JSON.err"
  exit 1
fi
rm -f "$TMP_JSON.err"
```

The validator enforces five named checks, in order:

| Check | Failure mode | Example error message |
|---|---|---|
| (a) `parse_error` | Input is not valid JSON | `JSON parse failed at line 3 col 7 (char 24): Expecting property name enclosed in double quotes` |
| (b) `wrong_root_key` | Root has `tasks` or any key other than `goals` | `root key 'tasks' is the most common batch-API mistake — Stride's POST /api/tasks/batch requires root key 'goals'` |
| (c) `empty_goals` | `goals` missing, not an array, or empty | `root.goals is an empty array — the decomposer returned no goals` |
| (d) `goal_missing_field` | A goal lacks `title`, `type`, or `tasks`, or a task is malformed | `goals[0] is missing required field 'title'` |
| (e) `bad_dependency_index` | A task's `dependencies[]` index is out of range, negative, or a forward / self reference | `goals[0].tasks[1].dependencies references index 5 but goal only has 2 tasks (valid indices 0..1)` |

A validation failure here is a **subagent regression** — the requirements-decomposer agent's contract guarantees a valid root-key=`goals` JSON. If you see one, the agent's prompt has drifted; surface the validator message verbatim and stop. The validator does NOT check per-task Stride-API field shapes — those are the decomposer agent's responsibility, and any slip-through surfaces as a verbatim 422 in Step 9.

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

**(8c) Verify path uniqueness and write the file.** Re-run `sti_unique_path` with the same arguments as Step 5 to confirm `TARGET_PATH` is still untaken. If a colliding file appeared between Step 5 and now (concurrent process, manual filesystem action), use the freshly resolved path — never overwrite an existing file.

Use the `write_file` tool to write the JSON document to the resolved target path. The directory containing `REQUIREMENTS_PATH` already exists (it housed the source doc), so no `mkdir -p` is needed.

**(8d) Commit.**

```bash
git add "$TARGET_PATH"
if [ -n "${GOAL_SLUG:-}" ]; then
  git commit -m "stride-ideation: decomposition for $SLUG goal $GOAL_SLUG"
else
  git commit -m "stride-ideation: decomposition for $SLUG"
fi

# Alias for the ship-side steps below — keeps the variable name consistent
# with the historical /ship command body.
BATCH_PATH="$TARGET_PATH"
```

When `--goal` was set, the commit message gains the goal slug so the audit trail records WHICH surface this batch covers — important when multiple per-goal commits ride on the same source requirements doc (their `source_spec_sha256` values match, but their commit subjects disambiguate).

Use `git add <path>` (not `git add -A` or `git commit -a`) to avoid sweeping unrelated working-tree changes into this commit. The source requirements doc is NOT in the commit's file list — `/stridify` reads it but never modifies it.

> **Drift check omitted.** The historical `/ship` command ran a `source_spec_sha256` drift check at this point to catch the case where the user hand-edited the requirements doc between `/decompose` and `/ship`. In the merged `/stridify` flow the batch JSON was just written by this command in the current invocation, so source drift cannot have occurred. The check is skipped.

### Step 9: Strip local-audit fields, POST, and branch on HTTP status

Three sub-steps that together send the payload to Stride.

**(9a) Strip local-audit fields.** The batch JSON on disk contains three local-audit fields (`source_spec`, `source_spec_sha256`, `decomposition_notes`) that the Stride API does not accept. Strip them via `lib/strip_audit_fields.py` before sending:

```bash
API_PAYLOAD="$(python3 "<plugin-root>/lib/strip_audit_fields.py" "$BATCH_PATH")" || {
  echo "stride-ideation: failed to prepare API payload from $BATCH_PATH" >&2
  exit 1
}
```

`$API_PAYLOAD` is the JSON to POST. The on-disk file is unchanged — stripping happens in memory only, so the local audit fields stay available for tools that read the JSON later.

**(9b) POST to the Stride batch endpoint.**

```bash
RESPONSE_FILE="$(mktemp -t stride_stridify_response.XXXXXX.json)"
CURL_ERR_FILE="$(mktemp -t stride_stridify_curl_err.XXXXXX)"
HTTP_CODE="$(
  curl -sS -X POST \
    -H "Authorization: Bearer $STRIDE_API_TOKEN" \
    -H "Content-Type: application/json" \
    -d "$API_PAYLOAD" \
    "$STRIDE_API_URL/api/tasks/batch" \
    -o "$RESPONSE_FILE" \
    -w '%{http_code}' \
    2>"$CURL_ERR_FILE"
)"
CURL_EXIT=$?
unset STRIDE_API_TOKEN  # paranoia: drop the token from the shell as soon as POST returns
```

The `-sS` flags silence the progress bar but keep error output; we capture that stderr to `$CURL_ERR_FILE`. `-w '%{http_code}'` writes the HTTP status code to stdout; the response body goes to `$RESPONSE_FILE` via `-o`. Never use `-v` here — verbose mode would echo the Authorization header.

If `curl` failed at the transport layer (`CURL_EXIT != 0`, or `HTTP_CODE` is empty / `"000"`), the user gets curl's **verbatim** error message — never a generic "something went wrong" wrapper. The actual cause (DNS resolution failure, connection refused, TLS handshake error, timeout, etc.) is the load-bearing diagnostic.

```bash
if [ "$CURL_EXIT" -ne 0 ] || [ -z "$HTTP_CODE" ] || [ "$HTTP_CODE" = "000" ]; then
  echo "stride-ideation: HTTP request failed before the Stride API responded:" >&2
  if [ -s "$CURL_ERR_FILE" ]; then
    # curl wrote a real error — surface it verbatim. curl's messages are
    # already user-friendly ("Could not resolve host: stridelikeaboss.com",
    # "Failed to connect to ... port 443: Connection refused", etc.).
    cat "$CURL_ERR_FILE" >&2
  else
    # curl exited non-zero with no stderr — uncommon but possible. Print
    # the numeric exit code so the user has something to look up.
    echo "  curl exited with status $CURL_EXIT and no stderr output." >&2
  fi
  rm -f "$RESPONSE_FILE" "$CURL_ERR_FILE"
  exit 1
fi
rm -f "$CURL_ERR_FILE"
```

The on-disk batch JSON written in Step 8 is the recovery artifact: if the POST fails for any reason, the user has a complete, audited batch document on disk and in git. A future invocation, a hand-curl, or a follow-up tool can ship that file without re-running the decomposer.

**(9c) Branch on the HTTP status code.** **Hard rule for every non-2xx branch: print the response body verbatim.** Do NOT parse it, do NOT reformat it, do NOT summarize it. The user needs the literal bytes the Stride API returned to debug the failure. Stride's 422 responses in particular carry a `details` array naming the offending field(s); rewriting the JSON would strip that signal.

| Status code | Action |
|---|---|
| 2xx | Continue to Step 10 (render the created identifiers). |
| 4xx | One-line header naming the status code, then the full response body verbatim. Exit non-zero. The body typically looks like `{"error": "...", "details": {...}}` or `{"errors": {"field": ["message"]}}` — both shapes are printed unchanged so the user sees the field-level diagnostic Stride emitted. |
| 5xx | One-line header naming the status code, then the full response body verbatim. Exit non-zero. The user should retry manually or report — `/stridify` does NOT retry, does NOT exponential-backoff, does NOT rate-limit. |
| Other (1xx, 3xx) | One-line header naming the status code, then the full response body verbatim. Exit non-zero. These shouldn't reach this code path (curl follows redirects internally and the Stride API never returns 1xx), but if one shows up we surface it rather than swallow it. |

```bash
case "$HTTP_CODE" in
  2*)
    : # fall through to Step 10
    ;;
  4*)
    echo "stride-ideation: Stride API rejected the batch (HTTP $HTTP_CODE). Response body:" >&2
    cat "$RESPONSE_FILE" >&2
    echo >&2
    rm -f "$RESPONSE_FILE"
    exit 1
    ;;
  5*)
    echo "stride-ideation: Stride API returned HTTP $HTTP_CODE. Response body:" >&2
    cat "$RESPONSE_FILE" >&2
    echo >&2
    rm -f "$RESPONSE_FILE"
    exit 1
    ;;
  *)
    echo "stride-ideation: unexpected HTTP status $HTTP_CODE. Response body:" >&2
    cat "$RESPONSE_FILE" >&2
    echo >&2
    rm -f "$RESPONSE_FILE"
    exit 1
    ;;
esac
```

**No retries.** When `/stridify` fails on a 4xx or 5xx, the user is the retry mechanism: they read the verbatim body, fix the underlying issue (regenerate the requirements doc and re-run `/stridify`, hand-edit the on-disk batch JSON and curl it manually, wait out a transient 5xx, etc.), and re-invoke. Stride does not guarantee per-task idempotency on a partially-failed batch, so an automatic retry could double-create some tasks while leaving others to fail again. Manual retry is the safer contract.

### Step 10: Render the created identifiers and print the terminal message

On 2xx the Stride API returns the goals and child tasks with their auto-generated identifiers (G-prefix for goals, W-prefix for work tasks, D-prefix for defects). Parse the response and print a readable table:

```bash
python3 - "$RESPONSE_FILE" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as fp:
    data = json.load(fp)

# Response shape: {"data": {"goals": [{ "identifier": "G99", "title": "...",
#                                       "tasks": [{"identifier": "W404", "title": "..."}, ...]}, ...]}}
# OR the same shape at the root without the "data" wrapper. Be permissive.
container = data.get("data", data)
goals = container.get("goals", [])

print()
print("Created goals and tasks:")
print()
for goal in goals:
    gid = goal.get("identifier", "?")
    title = goal.get("title", "(no title)")
    print(f"  {gid:>6}  {title}")
    for task in goal.get("tasks", []) or []:
        tid = task.get("identifier", "?")
        ttitle = task.get("title", "(no title)")
        print(f"  {tid:>6}    {ttitle}")
print()
PY

rm -f "$RESPONSE_FILE"
```

The table format is two columns: identifier (right-aligned, 6 chars wide for `G123` / `W1234` etc.) followed by the title, with child tasks indented under their goal. A typical successful invocation produces output like:

```
Created goals and tasks:

    G99  stride-ideate v0.1 — /ideate command
   W404    Scaffold the stride-ideation plugin repo layout
   W405    Implement the timestamped filename generator
   W406    Write the stride-ideation SKILL.md
```

After the table, print:

> Batch shipped successfully.
> The goals are now visible in the Stride workspace's Backlog column.

Do NOT print "next step:" suggestions, do NOT propose follow-on commands. The terminal state is the shipped batch.

## Resilience model

`/stridify` is designed to survive a transient Anthropic API capacity spike without losing the assembled prompt or producing partial Stride state. The model has four layers, in execution order: (1) **Preflight advisory** — Step 2 prints a one-line suggestion to use `--goal` when the doc enumerates more than 3 surfaces under `## Decomposition seams` (informational, never blocking). (2) **Per-goal partitioning** — Step 1's optional `--goal <name|index>` flag scopes the prompt to one surface from the doc's `## Decomposition seams` section, reducing per-dispatch token count and the blast radius of a single failure. (3) **Subagent dispatch retry** — Step 7c retries the requirements-decomposer dispatch up to **3 attempts** with ~30s / ~90s backoff (total budget ~2 min) when the failure classifies as transient (HTTP 529, network error, "overloaded" string). Terminal classifications (bad subagent name, contract violation, hard 4xx) fail fast on attempt 1 — retrying will not change the result. (4) **Retry-exhaustion fallback** — Step 7.5 writes the assembled prompt plus metadata to a sibling `<source-stem>-decomposer-prompt.md` file on exhaustion, with a recovery README naming the next concrete action (paste the prompt into a fresh session, save the JSON response at the target path, then run `lib/validate_batch.py` and the manual POST per Step 9). **The Stride API POST itself is NOT retried** — Step 9 fails fast on 4xx/5xx and surfaces the response body verbatim. Per-task idempotency on a partially-failed batch is not guaranteed, so an automatic POST retry could double-create some tasks while leaving others to fail again; the recovery contract is "the user reads the verbatim body and re-invokes" rather than "the command retries automatically".

## What this command does NOT do

- **Validate Stride API field shapes** beyond root-key + structure — that's `lib/validate_batch.py`'s job; surface 422 errors verbatim if anything slips through.
- **Modify the source requirements doc** — read-only access. The doc is committed earlier (by `/ideate`) and is treated as the source of truth.
- **Re-run ideation** — if the doc is missing sections, the error message points the user at `/ideate --continue <path>` rather than auto-invoking it.
- **Strip `decomposition_notes` from the on-disk JSON** — that field is part of the saved artifact. The strip happens in memory before the POST in Step 9; the on-disk file keeps the audit fields.
- **Retry the Stride API POST on transient failures** — fail fast and let the user re-invoke. Idempotency on the Stride side is not guaranteed for partial batches, so an automatic POST retry could double-create some tasks while leaving others to fail again. (This is different from the Step 7 subagent dispatch, which **is** retried with bounded exponential backoff. Subagent dispatch has no Stride-side side effects, so retrying it is safe; a POSTed batch may have partially landed, so retrying it is not.)
- **Drift-check the requirements doc against the batch JSON** — historical `/ship` did this to catch human edits between `/decompose` and `/ship`. The merged flow writes the batch JSON in the current invocation, so source drift cannot have occurred and the check is omitted.
- **Re-validate that a `--goal` value matches the surface the subagent actually emitted** — the Step 7e prompt directive names the target surface, but the on-disk goal `title` is whatever the subagent produced. If the subagent drifts and emits a different surface name, Step 8a still gates root-shape (root key `goals`, non-empty), but a semantic mismatch between the requested `--goal` and the emitted goal `title` is currently surfaced only as whatever the user sees in the Stride backlog. Future hardening could add an Step 8a-extra assertion that `len(goals) == 1 && slugify(goals[0].title) == GOAL_SLUG`; today it is out of scope.
