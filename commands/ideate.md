---
description: "Drive an interactive ideation session that turns a fuzzy idea into a committed requirements markdown document. Supports --continue <path> to refine a prior requirements doc, --input <path> to seed draft sections from a freeform brain-dump file (read-only; never committed), and --profile <lean|product|discovery|lean-startup> to select the round structure and reviewer rubric (default lean = v0.3.0 behavior). Hard-gated by the stride-ideation skill on the seven required sections; terminal state is the written doc (does NOT auto-invoke /stridify)."
---

# /ideate

Drive an interactive ideation session that produces a committed `*-requirements.md` document under `docs/ideation/`. The protocol — round-based question batching, hard-gated sections, advisory reviewer pass — is defined in `skills/stride-ideation/SKILL.md`. This command is the surface: it parses the invocation arguments, captures the session timestamp, resolves the slug, drives the skill, and finishes by writing and committing the doc.

**Usage:** `/ideate [<topic>] [--continue <path>] [--input <path>] [--profile <lean|product|discovery|lean-startup>]`

The user's invocation arguments are available as `$ARGUMENTS`. Parse `--continue <path>`, `--input <path>`, and `--profile <name>` out of `$ARGUMENTS` per Step 1; everything remaining is the topic. The protocol contract (the seven-section hard gate, the rounds, the framing checkpoint, the premortem, the profiles) lives in the `stride-ideation` skill — this command defers to it and never reimplements it.

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

The user invoked you with `$ARGUMENTS`. Parse in this fixed order — `--continue` first, then `--input`, then `--profile`, then everything remaining is `TOPIC`:

- If `--continue` appears, set `CONTINUE_PATH` to the value of the **next** token and remove both tokens. In `--continue` mode the topic is inherited from the source file and not re-prompted.
- If `--input` appears (accept both `--input <path>` and `--input=<path>` shapes, matching how `--continue` accepts both forms), set `INPUT_PATH` to the parsed value and remove the consumed tokens. `--input` is a **freeform brain-dump seed** — a Slack thread, scratch notes, meeting notes — that pre-populates draft sections; it is **distinct from `--continue`**, which refines an already-committed `-requirements.md` document. The two are independent and composable: if **both** are passed, `--continue` supplies the starting document and `--input` supplies additional raw seed content; neither overrides the other, nothing is silently dropped, and the slug still follows the `--continue` rule below (see Step 3). `--input` never changes the topic or the slug — it only seeds content.
- If `--profile` appears (accept both `--profile <name>` and `--profile=<name>` shapes, matching how `--continue` accepts both forms), set `PROFILE` to the parsed value and remove the consumed tokens. The accepted values are exactly `lean`, `product`, `discovery`, `lean-startup`. If the value is missing or is not one of these four, print a one-line error naming the offending value and the accepted set (e.g., `stride-ideation: unknown --profile value 'foo'; expected one of: lean, product, discovery, lean-startup`) and exit non-zero **before any session work begins** — do NOT prompt, do NOT default to lean on a typo, and do NOT fall through to the topic parser.
- If `--profile` is absent, **recommend a profile before the rounds begin** rather than silently defaulting. Ask the user once via OpenCode's `question` tool (the same prompt mechanism the command uses elsewhere — NOT Claude Code's `AskUserQuestion`), inferring a suggested profile from the topic (in `--continue` mode, infer from the inherited topic / prior document — never re-elicit the topic) and presenting it using the **"first option = recommended"** convention: the recommended profile is the **first option, labeled `(recommended)`, with a one-line rationale**, followed by the other three profiles as alternatives. The four options are exactly `lean`, `product`, `discovery`, `lean-startup` — the same accepted set as the flag. `lean` is the safe default: when inference is weak or the topic is ambiguous, recommend `lean` first. Set `PROFILE` to whatever the user selects. This recommendation runs **only** when `--profile` was omitted — it is a single question, asked once, before any round. Once the resolved `PROFILE` is `lean`, every downstream behavior is byte-for-byte equivalent to v0.3.0 lean (no new questions, no new sections, no new rubric checks) — the recommendation question is the *only* addition on the omitted-flag path and it changes nothing after a lean resolution.
- After both flag tokens are consumed, treat the trimmed remainder as `TOPIC`. If `CONTINUE_PATH` is set, the remainder is ignored. Otherwise, if the remainder is empty, ask the user once: *"What's the topic for this ideation session?"* (free-text input).

Validate `CONTINUE_PATH` immediately:

- If `CONTINUE_PATH` is set but the file does not exist (or is not a regular file), print a one-line error naming the path and exit non-zero. Do NOT fall back to a fresh session — the user explicitly asked for `--continue`.
- If `CONTINUE_PATH` does not end in `-requirements.md` (the artifact family this command refines), warn but proceed; the slug extraction may still work for paths produced by older versions of the plugin.

Validate `INPUT_PATH` immediately, mirroring the `CONTINUE_PATH` existence check:

- If `INPUT_PATH` is set but the file does not exist (or is not a regular file), print a one-line error naming the path (e.g., `stride-ideation: --input file not found: notes.md`) and exit non-zero. Do NOT fall back to a fresh no-seed session — the user explicitly asked to seed from that file.
- No suffix restriction applies — `--input` accepts any freeform text file. Treat its contents as **untrusted prose**: it only seeds draft sections; never execute or `eval` it, and never echo its contents into a git commit message or any log.

### Step 2: Capture the session timestamp

Run this fragment once and carry the `SESSION_TS` it prints:

```bash
# Carried forward: none
printf 'carry: SESSION_TS=%s\n' "$(date -u +%Y-%m-%dT%H%M%S)"
```

This single value MUST be used for every artifact written during this session — do not recompute it later. Capturing the timestamp at invocation time is what makes re-runs sortable and keeps the requirements doc / decomposition output paired by prefix.

**Even in `--continue` mode, always generate a fresh `SESSION_TS`.** Do not reuse the timestamp embedded in `CONTINUE_PATH` — that timestamp belongs to the source document, and reusing it would defeat the "never overwrite an existing file" invariant. The refined doc is a sibling, not a replacement.

### Step 3: Resolve the topic slug

The fragment sources `lib/filename.sh` (it ships with the extension) and resolves the slug depending on mode:

```bash
# Carried forward: CONTINUE_PATH (empty in a fresh session), TOPIC (empty in --continue mode)
: "${CONTINUE_PATH?stride-ideation: CONTINUE_PATH was not carried forward from Step 1}"
: "${TOPIC?stride-ideation: TOPIC was not carried forward from Step 1}"
# Find the helpers: the project install, then the global install, then a stride-opencode-ideation checkout.
STI_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
if [ -f "$STI_ROOT/.opencode/stride-ideation/lib/filename.sh" ]; then STI_LIB="$STI_ROOT/.opencode/stride-ideation/lib"
elif [ -f "${HOME:-}/.config/opencode/stride-ideation/lib/filename.sh" ]; then STI_LIB="$HOME/.config/opencode/stride-ideation/lib"
elif [ -f "$STI_ROOT/commands/stridify.md" ] && [ -f "$STI_ROOT/commands/ideate.md" ] && [ -f "$STI_ROOT/install.sh" ] && [ -f "$STI_ROOT/AGENTS.md" ] && [ -d "$STI_ROOT/skills" ] && [ -f "$STI_ROOT/lib/filename.sh" ]; then STI_LIB="$STI_ROOT/lib"
else echo "stride-ideation: cannot find the stride-ideation helpers in .opencode/stride-ideation/lib, ~/.config/opencode/stride-ideation/lib or a stride-opencode-ideation checkout — run install.sh, then retry this step" >&2; exit 1; fi
. "$STI_LIB/filename.sh" || exit 1

if [ -n "$CONTINUE_PATH" ]; then
  # --continue mode: inherit slug from source path; never re-prompt.
  SLUG="$(sti_slug_from_path "$CONTINUE_PATH" requirements)" || exit 1
else
  # Fresh session: slugify the user-supplied topic.
  SLUG="$(sti_slugify "$TOPIC")" || exit 1
fi
printf 'carry: SLUG=%s\n' "$SLUG"
```

If either helper exits non-zero, surface the error verbatim and stop — do NOT silently pick a fallback slug.

**Confirm `SLUG` with the user only in fresh-session mode.** In `--continue` mode the slug is inherited and locked — re-prompting would violate the "no re-prompt" acceptance criterion and risk accidentally diverging the artifact family. In fresh-session mode, ask the user to confirm, offering the computed value as the first option and "Type a different slug" as a fallback. Either way, the slug is locked for the rest of the session: carry the confirmed `SLUG` (including one the user typed) into every later step.

### Step 4: Compute the target path (don't write yet)

The fragment calls `sti_unique_path docs/ideation <SESSION_TS> <SLUG> requirements md` and checks the invariant below in the same call:

```bash
# Carried forward: SESSION_TS, SLUG, CONTINUE_PATH (empty in a fresh session)
: "${SESSION_TS:?stride-ideation: SESSION_TS was not carried forward from Step 2}"
: "${SLUG:?stride-ideation: SLUG was not carried forward from Step 3}"
: "${CONTINUE_PATH?stride-ideation: CONTINUE_PATH was not carried forward from Step 1}"
# Find the helpers: the project install, then the global install, then a stride-opencode-ideation checkout.
STI_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
if [ -f "$STI_ROOT/.opencode/stride-ideation/lib/filename.sh" ]; then STI_LIB="$STI_ROOT/.opencode/stride-ideation/lib"
elif [ -f "${HOME:-}/.config/opencode/stride-ideation/lib/filename.sh" ]; then STI_LIB="$HOME/.config/opencode/stride-ideation/lib"
elif [ -f "$STI_ROOT/commands/stridify.md" ] && [ -f "$STI_ROOT/commands/ideate.md" ] && [ -f "$STI_ROOT/install.sh" ] && [ -f "$STI_ROOT/AGENTS.md" ] && [ -d "$STI_ROOT/skills" ] && [ -f "$STI_ROOT/lib/filename.sh" ]; then STI_LIB="$STI_ROOT/lib"
else echo "stride-ideation: cannot find the stride-ideation helpers in .opencode/stride-ideation/lib, ~/.config/opencode/stride-ideation/lib or a stride-opencode-ideation checkout — run install.sh, then retry this step" >&2; exit 1; fi
. "$STI_LIB/filename.sh" || exit 1

TARGET_PATH="$(sti_unique_path docs/ideation "$SESSION_TS" "$SLUG" requirements md)" || exit 1
if [ -n "$CONTINUE_PATH" ] && [ "$TARGET_PATH" = "$CONTINUE_PATH" ]; then
  echo "stride-ideation: refusing to overwrite source document at $CONTINUE_PATH" >&2
  exit 1
fi
printf 'carry: TARGET_PATH=%s\n' "$TARGET_PATH"
```

`TARGET_PATH` is the path you WILL write to in Step 8. Do NOT create or touch this file yet. Pre-creating it as empty would leave a half-baked artifact on the filesystem if the user interrupts mid-session, which is the explicit failure mode the spec is guarding against.

**HARD INVARIANT — `--continue` mode:** `TARGET_PATH` MUST NOT equal `CONTINUE_PATH`. `sti_unique_path` builds the new path from a fresh `SESSION_TS`, so the two paths only collide if the user manually crafted a colliding name on disk in the same second — which the collision discriminator handles. The Step 4 fragment verifies the invariant and stops before printing a `TARGET_PATH` if the two collide.

### Step 4b: Read the prior document (only in `--continue` mode)

If `CONTINUE_PATH` is set, **read-only** load its content via the `read` tool. The skill will receive this content as starting context for the session. The source file is **never** edited, written, moved, or `git add`-ed during this command — read access only. If you find yourself reaching for `write` or `edit` on `CONTINUE_PATH`, stop: that is the failure mode the pitfall forbids.

In fresh-session mode, leave `PRIOR_DOC` empty.

### Step 4c: Read the input brain-dump (only when `--input` is set)

If `INPUT_PATH` is set, **read-only** load its content via the `read` tool into `INPUT_NOTES`. The skill receives this content as raw seed material that pre-populates draft sections wherever the notes clearly map to a gated section. The `--input` file carries the **same read-only invariant as the `--continue` source**: it is **never** edited, written, moved, or `git add`-ed during this command — read access only. Its contents are untrusted prose: never execute or `eval` them, and never copy them into a commit message or log. If `INPUT_PATH` is not set, leave `INPUT_NOTES` empty.

`--input` and `--continue` are independent: both `PRIOR_DOC` and `INPUT_NOTES` may be non-empty in the same session (a prior committed doc *and* a fresh notes file), one may be set without the other, or neither. The seed lowers the starting cost — it does NOT lower the bar: the hard gates, the round-3 framing checkpoint, the premortem, and the reviewer pass all still run, and gaps or weak sections are still asked in the rounds.

### Step 4d: Detect an unfinished draft and resolve the autosave path

The requirements doc is not written until the hard gate passes (Step 8), so an interruption mid-session would otherwise lose every answer. To make a session recoverable, the skill autosaves the in-progress draft to a scratch file under `.stride/` after every round (see Step 5), and on start `/ideate` offers to resume any unfinished draft for the **same slug**. The fragment below also makes `.stride/` ignore itself: `sti_scratch_dir` creates the directory and writes a `.stride/.gitignore` containing `*` when that file is absent (an existing one is left alone), so drafts stay out of `git status` and `git add -A` in any repository — no edit to your project's `.gitignore` is needed or made. If the fragment stops because `.stride/` is a symlink, or because git would not ignore the draft (an existing `.stride/.gitignore` re-includes it, or it is already tracked), stop the session and tell the user what it reported: autosaving there could write the draft somewhere else or commit it.

The fragment sources the draft helper and looks for an existing draft keyed by `SLUG` (resume keys on the slug, not `SESSION_TS`, because a fresh run has a new timestamp), and prints the fresh per-session scratch path alongside it. `lib/draft.ps1` (`Sti-DraftFind`, `Sti-DraftPath`, `Sti-ScratchDir`) mirrors `lib/draft.sh` for PowerShell callers — a PowerShell translation of this fragment must call `Sti-ScratchDir .stride <draft file name>` and stop when it fails, exactly as the bash fragment does. `sti_draft_find` only offers a draft that resuming can safely rewrite: never a symlink, and inside a git work tree only one git ignores, so a tracked old draft is never resumed:

```bash
# Carried forward: SESSION_TS, SLUG
: "${SESSION_TS:?stride-ideation: SESSION_TS was not carried forward from Step 2}"
: "${SLUG:?stride-ideation: SLUG was not carried forward from Step 3}"
# Find the helpers: the project install, then the global install, then a stride-opencode-ideation checkout.
STI_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
if [ -f "$STI_ROOT/.opencode/stride-ideation/lib/filename.sh" ]; then STI_LIB="$STI_ROOT/.opencode/stride-ideation/lib"
elif [ -f "${HOME:-}/.config/opencode/stride-ideation/lib/filename.sh" ]; then STI_LIB="$HOME/.config/opencode/stride-ideation/lib"
elif [ -f "$STI_ROOT/commands/stridify.md" ] && [ -f "$STI_ROOT/commands/ideate.md" ] && [ -f "$STI_ROOT/install.sh" ] && [ -f "$STI_ROOT/AGENTS.md" ] && [ -d "$STI_ROOT/skills" ] && [ -f "$STI_ROOT/lib/filename.sh" ]; then STI_LIB="$STI_ROOT/lib"
else echo "stride-ideation: cannot find the stride-ideation helpers in .opencode/stride-ideation/lib, ~/.config/opencode/stride-ideation/lib or a stride-opencode-ideation checkout — run install.sh, then retry this step" >&2; exit 1; fi
. "$STI_LIB/draft.sh" || exit 1

EXISTING_DRAFT="$(sti_draft_find .stride "$SLUG" 2>/dev/null || true)"
FRESH_DRAFT_PATH="$(sti_draft_path .stride "$SESSION_TS" "$SLUG")" || exit 1
sti_scratch_dir .stride "$(basename "$FRESH_DRAFT_PATH")" || exit 1
printf 'carry: EXISTING_DRAFT=%s\n' "$EXISTING_DRAFT"
printf 'carry: FRESH_DRAFT_PATH=%s\n' "$FRESH_DRAFT_PATH"
```

`sti_draft_find` returns the latest **non-empty** scratch draft matching `<ts>-$SLUG-draft.md` under `.stride/`, or nothing when none exists (an empty or absent scratch yields no offer — a partial/corrupt draft safely falls back to a fresh session). Resolve `DRAFT_PATH` for this session:

- **If `EXISTING_DRAFT` is non-empty**, ask the user via OpenCode's `question` tool (NOT Claude Code's `AskUserQuestion`) whether to **resume** that draft or **start fresh** (offer "Resume" as the first option). On resume, carry `DRAFT_PATH` = the `EXISTING_DRAFT` value, so the session continues autosaving to — and the skill loads from — that same file. On start-fresh, run the fragment below to discard the abandoned draft, then carry `DRAFT_PATH` = the `FRESH_DRAFT_PATH` value.
- **If `EXISTING_DRAFT` is empty** (none found), carry `DRAFT_PATH` = the `FRESH_DRAFT_PATH` value — a fresh per-session scratch path.

```bash
# Carried forward: EXISTING_DRAFT
: "${EXISTING_DRAFT:?stride-ideation: EXISTING_DRAFT was not carried forward from Step 4d}"
# Find the helpers: the project install, then the global install, then a stride-opencode-ideation checkout.
STI_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
if [ -f "$STI_ROOT/.opencode/stride-ideation/lib/filename.sh" ]; then STI_LIB="$STI_ROOT/.opencode/stride-ideation/lib"
elif [ -f "${HOME:-}/.config/opencode/stride-ideation/lib/filename.sh" ]; then STI_LIB="$HOME/.config/opencode/stride-ideation/lib"
elif [ -f "$STI_ROOT/commands/stridify.md" ] && [ -f "$STI_ROOT/commands/ideate.md" ] && [ -f "$STI_ROOT/install.sh" ] && [ -f "$STI_ROOT/AGENTS.md" ] && [ -d "$STI_ROOT/skills" ] && [ -f "$STI_ROOT/lib/filename.sh" ]; then STI_LIB="$STI_ROOT/lib"
else echo "stride-ideation: cannot find the stride-ideation helpers in .opencode/stride-ideation/lib, ~/.config/opencode/stride-ideation/lib or a stride-opencode-ideation checkout — run install.sh, then retry this step" >&2; exit 1; fi
. "$STI_LIB/draft.sh" || exit 1

sti_draft_clear "$EXISTING_DRAFT" || exit 1
```

Only same-slug drafts are ever offered; a draft for a different in-flight topic is never surfaced here. The `.stride/` scratch directory is ignored by its own `.stride/.gitignore` (created above), the scratch file is **never** `git add`-ed or committed, and **never** holds the Stride API token or any other secret — it carries only the in-progress draft prose.

### Step 5: Follow the `stride-ideation` skill

Follow the `stride-ideation` skill, passing the topic, locked slug, session timestamp, target path, the prior document (if any), and the resolved profile:

```
topic=<TOPIC>; slug=<SLUG>; session_ts=<SESSION_TS>; target_path=<TARGET_PATH>; prior_doc=<PRIOR_DOC>; input_notes=<INPUT_NOTES>; draft_path=<DRAFT_PATH>; profile=<PROFILE>
```

When `PRIOR_DOC` is non-empty, the skill starts the session with that content already loaded as context — refining and sharpening rather than re-eliciting every section from scratch. The Q&A loop, the round-3 checkpoint, the hard gates, and the advisory reviewer pass all still run; `--continue` does not lower the bar, only the starting cost.

`draft_path=<DRAFT_PATH>` (resolved in Step 4d) is the self-ignored scratch file for **intra-session autosave**. The skill writes the in-progress draft — the answered sections plus a round-state header — to that path with the `write` tool **after every round** (see **Autosave** in `skills/stride-ideation/SKILL.md`), so an interruption after any round is recoverable rather than losing every answer. If `DRAFT_PATH` already holds content (a resumed draft from Step 4d), the skill loads it with the `read` tool as starting context at round 1. The scratch file holds only draft prose: it is ignored by `.stride/.gitignore`, never `git add`-ed, and never carries the Stride API token or any other secret. Autosave is a recovery convenience, not a gate bypass — the hard gates, framing checkpoint, premortem, and reviewer pass still run in full.

When `INPUT_NOTES` is non-empty, the skill pre-populates draft sections from that freeform brain-dump wherever the notes clearly map to a gated section, then focuses the rounds on the gaps and weak sections rather than re-eliciting every section from scratch. Seeded content is a *draft starting point*, not a confirmed answer: it never satisfies a hard gate on its own — every gated section the seed pre-fills is still confirmed (or sharpened) with the human in the rounds, and sections the notes do not cover are asked normally. `prior_doc` and `input_notes` are independent and may both be present in one session.

The parsed value of `--profile` from Step 1 is threaded into the skill as `profile=<PROFILE>`. It selects which forcing questions run inside the rounds and which optional sections the document may include. See the **Profiles** subsection of `skills/stride-ideation/SKILL.md` for the per-profile augmentations. `--profile=lean` (the default) leaves the round loop unchanged from v0.3.0; `--profile=product`, `--profile=discovery`, and `--profile=lean-startup` add advisory rubric checks and (for `product` and `lean-startup`) one optional section.

The skill enforces:
- the hard gate against premature implementation,
- the round-based question loop (≤ 4 questions per round) — each round asks the user a batched set of up to four related questions,
- the display-only round recap printed before every round (see **Round recap** in `skills/stride-ideation/SKILL.md`) — it reports per-section solid/thin/empty status and the round's target sections without changing the gate, the round order, or the question budget,
- the "I'm not sure — propose candidates" uncertainty path offered on every batched question — gated-section and profile-specific forcing questions alike (see **Uncertainty path** in `skills/stride-ideation/SKILL.md`); it proposes 2–4 topic-tailored candidates but can never satisfy the hard gate without human confirmation,
- the mandatory round-3 framing checkpoint,
- the mandatory round-4 premortem,
- the seven hard-gated sections (Goal, Problem, Outcome, Assumptions, Constraints, Non-goals, Success Metrics),
- the mandatory, profile-independent challenge gate run after the round-4 premortem (and the Round-5 MVP-design batch under `profile=lean-startup`) and before the reviewer pass — its four components (assumption-confidence audit, blind-spot scan, two-alternative generation, and cost/risk/complexity/timeline trade-off analysis) are surfaced to the human as a single multi-select decision through OpenCode's `question` tool (≤ 4 questions; not Claude Code's `AskUserQuestion`) with an explicit "Challenge nothing — write as-is" option that feeds the at-most-one refinement round; the confidence ratings fold back into the Assumptions entries in place and the blind spots, two alternatives, and trade-off comparison fold into the optional `## Design challenge` section, and the gate never blocks the write (see **Challenge gate** in `skills/stride-ideation/SKILL.md`),
- the advisory `requirements-reviewer` pass before the write (dispatch it by calling OpenCode's `task` tool with `subagent_type: "requirements-reviewer"` — never with an `@name` mention, which only a user's own prompt turns into an agent call) — its findings are surfaced to the human as a single multi-select decision through OpenCode's `question` tool (each finding one line, severity-tagged, plus an explicit "Address none — write as-is" option) that feeds the at-most-one refinement round; an `approved` verdict with no findings shows no prompt, and the reviewer never blocks the write (see **Reviewer pass** in `skills/stride-ideation/SKILL.md`).

When the skill returns, you will have a single string `DRAFT_DOC` containing the fully composed requirements markdown — every gated section present and substantive. If the skill returns without a draft (user aborted, hard gate not satisfied), stop here and exit cleanly — do NOT write anything to disk and do NOT commit.

### Step 6: Conform the draft to the spec template

The skill returns prose for each section but the on-disk format is fixed by the design spec's "Output: requirements markdown template". Ensure `DRAFT_DOC` looks like:

```markdown
# <Topic>

*Date: YYYY-MM-DD HH:MM*
*Session: <SESSION_TS>-<SLUG>*

## Problem
<one paragraph max>

## Goal
<outcome, not feature>

## Success metrics
- **leading indicators** (observable while the work is in flight, predict the outcome):
  - <bulleted, each measurable>
- **lagging indicators** (the outcome itself, observable only after it has occurred):
  - <bulleted, each measurable>

## Assumptions
*Ordered highest to lowest risk; the riskiest entry is marked `(R)` (or `**(riskiest)**`). Each entry also carries the challenge gate's confidence rating — `(high)`, `(medium)`, or `(low)` — folded in place by the assumption-confidence audit.*
- <riskiest assumption> (R) (low)
- <next-riskiest assumption> (medium)
- <remaining assumptions, in decreasing risk> (high)

## Constraints
- <bullets — non-negotiable>

## Non-goals
- <bullets, each with a reason>

## Outcome
<what the world looks like after this ships>

## Sketch
<optional; 1–5 paragraphs if present>

## Open questions
<optional; bullets of deferred items>

## Design challenge
<optional (all profiles); present only when the challenge gate surfaced material findings>
- **Blind spots:** <unstated dependencies, omitted stakeholders, untested edge cases, failure modes the premortem missed>
- **Alternative A:** <a distinct alternative approach to the proposed design>
- **Alternative B:** <a second distinct alternative approach>
- **Trade-off comparison:** <proposed design vs Alternative A vs Alternative B across cost, risk, complexity, and timeline>
```

The seven hard-gated sections appear above the three optional ones (`Sketch`, `Open questions`, `Design challenge`). Include the optional sections only if the conversation produced substantive content for them. If the draft is missing any gated section, treat that as a skill bug and abort — do NOT paper over it by writing an incomplete doc.

**The `## Design challenge` section is profile-independent and advisory.** It holds the output of the challenge gate (see Step 5) under every profile (`lean`, `product`, `discovery`, `lean-startup`) — it is NOT a hard gate and is omitted when the gate surfaced nothing material. The assumption-confidence ratings the gate produces do NOT live here; they fold back into the `## Assumptions` entries in place (the `(high)`/`(medium)`/`(low)` annotation shown in the template above). Only the blind spots, the two alternatives, and the trade-off comparison land in this section. Like the round recap, the `Design challenge` section is never one of the seven gated sections.

**Decomposition seams (optional, freeform).** If the conversation surfaced that the work splits across multiple independent surfaces — separate plugins, separate services, separate repos that ship on their own cadences — append a freeform `## Decomposition seams` section after the optional sections. List each surface as a numbered markdown item with a bold name, e.g. `1. **Kanban app** — owns the JSON contract`, `2. **stride plugin** — adapter for the reference workflow`. The section is freeform and the ideation skill does NOT gate it. Its downstream consumer is `/stridify --goal <name|index>`: when a requirements doc has many surfaces, the user can run `/stridify` once per surface (`/stridify <path> --goal 1`, `/stridify <path> --goal 2`, …) to reduce per-dispatch prompt size and the blast radius of a single subagent failure. `/stridify` also prints a one-line preflight advisory suggesting `--goal` when the section enumerates more than 3 surfaces. Producing a Decomposition seams section here is the natural way for the user to discover the partitioning flag.

**Under `profile=lean-startup` only**, append one more optional section after `## Design challenge` — `## MVP / Validation experiment` — produced by the Round 5 MVP-design batch. Its sub-fields, in order:

- **Riskiest assumption being tested:** quote the `(R)`-marked entry from Assumptions verbatim.
- **Experiment design:** what to build, fake, or measure to produce the validating signal.
- **Success criteria:** observable signal that validates the assumption.
- **Failure criteria:** observable signal that falsifies the assumption.
- **Time box:** when results are expected.
- **Pivot-or-persevere decision:** what happens based on result.

This `MVP / Validation experiment` section is profile-conditional — under `lean`, `product`, or `discovery` it MUST NOT appear even if the user volunteered experiment-shaped content. The riskiest-assumption line is a quote of an existing Assumptions entry, not a freshly authored field; the other five sub-fields are authored from the Round 5 answers.

### Step 7: Verify the target path is still untaken

Re-run `sti_unique_path` with the same arguments as Step 4 and confirm the returned path equals `TARGET_PATH`. If it differs (another process wrote a colliding file during the session), use the new value — never overwrite an existing file. This is the HARD INVARIANT documented in `lib/filename.sh`. Carry the `TARGET_PATH` this fragment prints into Steps 8–10:

```bash
# Carried forward: SESSION_TS, SLUG, TARGET_PATH
: "${SESSION_TS:?stride-ideation: SESSION_TS was not carried forward from Step 2}"
: "${SLUG:?stride-ideation: SLUG was not carried forward from Step 3}"
: "${TARGET_PATH:?stride-ideation: TARGET_PATH was not carried forward from Step 4}"
# Find the helpers: the project install, then the global install, then a stride-opencode-ideation checkout.
STI_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
if [ -f "$STI_ROOT/.opencode/stride-ideation/lib/filename.sh" ]; then STI_LIB="$STI_ROOT/.opencode/stride-ideation/lib"
elif [ -f "${HOME:-}/.config/opencode/stride-ideation/lib/filename.sh" ]; then STI_LIB="$HOME/.config/opencode/stride-ideation/lib"
elif [ -f "$STI_ROOT/commands/stridify.md" ] && [ -f "$STI_ROOT/commands/ideate.md" ] && [ -f "$STI_ROOT/install.sh" ] && [ -f "$STI_ROOT/AGENTS.md" ] && [ -d "$STI_ROOT/skills" ] && [ -f "$STI_ROOT/lib/filename.sh" ]; then STI_LIB="$STI_ROOT/lib"
else echo "stride-ideation: cannot find the stride-ideation helpers in .opencode/stride-ideation/lib, ~/.config/opencode/stride-ideation/lib or a stride-opencode-ideation checkout — run install.sh, then retry this step" >&2; exit 1; fi
. "$STI_LIB/filename.sh" || exit 1

RECHECKED_PATH="$(sti_unique_path docs/ideation "$SESSION_TS" "$SLUG" requirements md)" || exit 1
if [ "$RECHECKED_PATH" != "$TARGET_PATH" ]; then
  echo "stride-ideation: $TARGET_PATH was taken during the session; writing to $RECHECKED_PATH instead" >&2
fi
printf 'carry: TARGET_PATH=%s\n' "$RECHECKED_PATH"
```

### Step 8: Write the file

Use the `write` tool to write `DRAFT_DOC` to the resolved target path. The directory `docs/ideation/` may not exist on a fresh repo; create it via `mkdir -p docs/ideation` before the write if Step 4's path resolution depended on it.

### Step 9: Commit

```bash
# Carried forward: TARGET_PATH, SLUG, CONTINUE_PATH (empty in a fresh session), DRAFT_PATH
: "${TARGET_PATH:?stride-ideation: TARGET_PATH was not carried forward from Step 7}"
: "${SLUG:?stride-ideation: SLUG was not carried forward from Step 3}"
: "${CONTINUE_PATH?stride-ideation: CONTINUE_PATH was not carried forward from Step 1}"
: "${DRAFT_PATH:?stride-ideation: DRAFT_PATH was not carried forward from Step 4d}"
# Find the helpers: the project install, then the global install, then a stride-opencode-ideation checkout.
STI_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
if [ -f "$STI_ROOT/.opencode/stride-ideation/lib/filename.sh" ]; then STI_LIB="$STI_ROOT/.opencode/stride-ideation/lib"
elif [ -f "${HOME:-}/.config/opencode/stride-ideation/lib/filename.sh" ]; then STI_LIB="$HOME/.config/opencode/stride-ideation/lib"
elif [ -f "$STI_ROOT/commands/stridify.md" ] && [ -f "$STI_ROOT/commands/ideate.md" ] && [ -f "$STI_ROOT/install.sh" ] && [ -f "$STI_ROOT/AGENTS.md" ] && [ -d "$STI_ROOT/skills" ] && [ -f "$STI_ROOT/lib/filename.sh" ]; then STI_LIB="$STI_ROOT/lib"
else echo "stride-ideation: cannot find the stride-ideation helpers in .opencode/stride-ideation/lib, ~/.config/opencode/stride-ideation/lib or a stride-opencode-ideation checkout — run install.sh, then retry this step" >&2; exit 1; fi
. "$STI_LIB/draft.sh" || exit 1

# A carried value that names a directory would let git add sweep in every
# untracked file under it; only the written artifact itself is committed.
if [ ! -f "$TARGET_PATH" ] || [ -L "$TARGET_PATH" ]; then
  echo "stride-ideation: $TARGET_PATH is not the written artifact (not a regular file); nothing was committed" >&2
  exit 1
fi
# Commit ONLY the new doc: the pathspec after -- keeps anything the user had
# already staged staged and out of this commit. --literal-pathspecs makes a
# path containing * or a leading : match only itself.
git --literal-pathspecs add -- "$TARGET_PATH" || exit 1
if [ -n "$CONTINUE_PATH" ]; then
  git --literal-pathspecs commit -m "stride-ideation: refine requirements for $SLUG" -- "$TARGET_PATH" || exit 1
else
  git --literal-pathspecs commit -m "stride-ideation: requirements for $SLUG" -- "$TARGET_PATH" || exit 1
fi

# The session succeeded — the committed doc supersedes the scratch draft.
# Delete the self-ignored autosave file (sti_draft_clear / Sti-DraftClear) so no
# stale draft lingers to be offered for resume next time. Idempotent: a no-op
# if the draft was never written.
sti_draft_clear "$DRAFT_PATH"
```

Commit message format: `stride-ideation: requirements for <slug>` (fresh) or `stride-ideation: refine requirements for <slug>` (continue). Do not include the session timestamp in the message — the filename already carries it.

The `sti_draft_clear "$DRAFT_PATH"` call (or `Sti-DraftClear` on Windows) runs **only after the commit succeeds** — the scratch draft is the recovery artifact, so it survives until the real doc is committed and is then removed so no stale autosave is offered for resume on a future run. The scratch file lives under the self-ignoring `.stride/` directory and is never part of the commit's file list.

If the working tree had unrelated changes before the session, the commit MUST include only the new requirements doc. `git add <path>` alone does not ensure that: a plain `git commit` commits everything already staged, including files the user staged before running `/ideate`. So the fragment passes the doc as a pathspec after `--`, which commits that one file and leaves every other staged change staged and uncommitted; `--literal-pathspecs` makes git match the path literally, so a slug or directory containing `*` or a leading `:` cannot widen the match. Keep the `git add` — a pathspec commit of a still-untracked file fails — and never use `git add -A` or `git commit -a`. In `--continue` mode the source document MUST NOT appear in the commit's file list (it was not modified, so `git status` will already show it clean — but verify nothing accidental crept in).

### Step 10: Print the neutral terminal message

Print **exactly** these three lines, substituting the resolved path:

> Requirements written to `<TARGET_PATH>`.
> You can stop here — the doc is the deliverable.
> Or, to decompose this into Stride tasks and ship them in one shot, run `/stridify <TARGET_PATH>` next.

Do NOT add follow-up suggestions, do NOT auto-invoke `/stridify`, do NOT propose implementation steps. The terminal state is the written document.

## What this command does NOT do

- Decomposition into Stride tasks AND shipping to a Stride workspace in one shot — see `/stridify`.
- Modifying any file other than the new requirements doc — pre-existing files (including a `--continue` source document) are read-only.
