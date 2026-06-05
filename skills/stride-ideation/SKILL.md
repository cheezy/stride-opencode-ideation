---
name: stride-ideation
description: Use when the user has a fuzzy idea, a new feature initiative, or a pre-decomposition scoping need and wants a written requirements document — drives a round-based question loop (up to 4 batched questions per round, with a mandatory round-3 framing checkpoint and a mandatory round-4 premortem; lean-startup additionally runs a mandatory round-5 MVP-design batch) under a named profile (lean / product / discovery / lean-startup), hard-gates the 7 required sections (Goal, Problem, Outcome, Assumptions, Constraints, Non-goals, Success Metrics) with shape requirements on Assumptions (ranked, riskiest marked, premortem-derived) and Success Metrics (both leading and lagging indicators), auto-dispatches an advisory requirements-reviewer pass with profile-aware checks, then commits a timestamped requirements doc and STOPS. The terminal state is the written document — the skill never pushes the user toward /stridify or any other next step.
skills_version: "1.0"
---

# stride-ideation

This skill turns a vague idea into a structured requirements document through a round-based questioning loop. It is invoked by the `/ideate` command. The questioning loop and reviewer logic live in `command/ideate.md` and `agents/requirements-reviewer.md` — this skill defines the surface contract: which sections are required, when the hard gates fire, what the terminal state looks like.

## Hard gate

**The skill MUST NOT write the requirements document to disk until each of the seven required sections below has substantive content.** Placeholders, "TBD", "to be filled in", or single-line gestures are not substantive. If the user attempts to short-circuit ("just write what we have"), the skill asks one more batch of questions covering the missing sections rather than skipping the gate.

The seven required sections:

1. **Goal** — what the user is trying to accomplish
2. **Problem** — what hurts today
3. **Outcome** — what the world looks like after this ships
4. **Assumptions** — load-bearing beliefs that, if wrong, change the design
5. **Constraints** — what cannot change (time, scope, tech, people)
6. **Non-goals** — explicit out-of-scope items
7. **Success Metrics** — how the user will know it worked

Three of the seven sections additionally have **shape requirements** beyond mere presence — the hard gate is not satisfied unless they hold:

- **Assumptions MUST contain premortem-derived content.** At least one entry must describe a plausible failure mode the design depends on NOT happening (e.g., "users will actually open the digest email"), not only expected design properties (e.g., "SMTP relay is available"). Pure expected-properties Assumptions do not satisfy the gate on their own — the round-4 premortem is what supplies this content.
- **Assumptions MUST be ranked, with the riskiest marked.** Order the entries from highest to lowest risk and mark exactly one entry with either `(R)` or `**(riskiest)**`. Either marker form is acceptable; the gate requires one of them on exactly one entry. The marker is what makes the ranking auditable — a sorted list with no marker reads the same as an unsorted list.
- **Success Metrics MUST contain both leading and lagging indicators.** At least one entry must be a leading indicator (something observable while the work is in flight, predicts the outcome) and at least one must be a lagging indicator (the outcome itself, observable only after it has occurred). All-leading or all-lagging metrics fail the gate — a project that can only be measured after it is too late to correct is a calibration failure, as is one that can only be measured by proxy.

Additionally:
- **The skill MUST NOT take any implementation action during the session** — no code edits, no scaffolding, no commits other than the final requirements doc commit, no invocation of decomposition or shipping commands.
- **The skill MUST NEVER overwrite an existing file.** Filename uniqueness is the responsibility of `lib/filename.sh` (`sti_unique_path`); the skill defers to that helper.

## When to invoke

- The user describes a new feature, capability, or initiative in fuzzy terms ("we should probably do X", "what if we…").
- The user explicitly asks for a requirements doc, scoping doc, or design brief.
- A piece of work is too broad to decompose into Stride tasks without first capturing the shape.
- The user is choosing between approaches and needs to articulate goals + constraints before picking one.

## When NOT to invoke

- The work is already scoped (requirements doc exists, or a Stride goal already captures the shape).
- It is a bug fix with a known repro.
- The user is mid-implementation and needs course-correction, not requirements.
- The user is doing exploratory code reading or research — that is not an ideation task.

## Profiles

The skill receives a `profile=<name>` parameter from the calling command. The profile selects which forcing questions run inside the rounds and which optional sections the document may include. The seven hard-gated section names and the round-3 framing checkpoint and round-4 premortem are **identical across all profiles** — the profile only adjusts what additional content the rounds elicit and what the advisory reviewer flags. Profiles do NOT overlap: each augmentation belongs to exactly one profile.

The four profiles:

- **`lean`** (default — applied when `profile=` is absent or empty). The bare-minimum round structure: no profile-specific forcing questions, no profile-specific optional sections, no profile-specific reviewer checks. `profile=lean` is byte-for-byte equivalent to v0.3.0 behavior. Use this when the topic is small, the audience is engineering-only, or the user wants the shortest path to a committed doc.
- **`product`**. Adds a JTBD (jobs-to-be-done) four-forces forcing question to Round 1, framing Problem and Goal around the user's job, the forces pulling them toward and away from a solution, and the habits they're abandoning. Unlocks the optional **Concrete Example** section in the document (a single named scenario with the user, the trigger, the current bad path, and the desired good path). The reviewer flags missing or thin Concrete Example content and missing JTBD framing — both as advisory, never blocking. Use this when the audience includes product/design and the framing benefits from a concrete persona-bound scenario.
- **`discovery`**. Adds a Why-now + Alternative-options forcing question to Round 2, asking what makes this problem worth solving *now* versus later, and which other options were considered and rejected. The reviewer flags missing Why-now content as advisory, never blocking. No new optional sections — the Why-now content folds into the existing Problem and Assumptions sections. Use this when the topic is early-stage and the case-for-action is the riskiest part of the framing.
- **`lean-startup`**. Adds a mandatory Round-5 MVP-design batch (Build-Measure-Learn frame) that anchors on the `(R)`-marked entry from Assumptions and asks the user to design the smallest experiment capable of validating or falsifying that assumption. Unlocks the optional **MVP / Validation experiment** section in the document (riskiest assumption being tested, experiment design, success criteria, failure criteria, time box, pivot-or-persevere decision). The reviewer flags absence of the MVP section under this profile and non-falsifiable success/failure criteria — both as advisory, never blocking. Use this when the next step is a deliberate validation experiment rather than a full implementation, and the project warrants explicit Build-Measure-Learn framing.

The default `lean` profile is the safe choice when nothing else applies. The profile is locked at command invocation time and does not change mid-session.

## The questioning loop

A **round** is one batched set of one to four related questions posed to the user. Rounds proceed until each of the seven required sections has draft content; a typical session uses three to five rounds.

| Round | Default focus (all profiles) | Profile-specific augmentations |
|---|---|---|
| 1 | Goal, Problem, Outcome — what's being built and why | `product`: also runs JTBD four-forces forcing question |
| 2 | Assumptions, Constraints, Non-goals — boundary conditions | `discovery`: also runs Why-now + Alternative-options forcing questions |
| 3 | Success Metrics + framing checkpoint (see below) | (none) |
| 4 | Premortem — challenge Assumptions, fold failure modes back in (see below) | (none) |
| 5 | MVP design — anchor on the `(R)`-marked Assumptions entry and design the smallest validating experiment (lean-startup only; see below) | `lean-startup`: runs the four-question MVP-design batch |
| 6+ | Gap-fill for whichever sections still lack substance | (none) |

The default-focus column is identical across all four profiles — only the augmentation column and Round-5 attendance change. `profile=lean` runs the table with the augmentation column empty and Round 5 skipped (byte-for-byte v0.3.0). `profile=product` adds the Round-1 JTBD batch and skips Round 5. `profile=discovery` adds the Round-2 Why-now + Alternative-options batch and skips Round 5. `profile=lean-startup` runs the Round-5 MVP-design batch (mandatory under this profile; skipped under any other profile). Round 3 (framing) and Round 4 (premortem) are profile-independent and mandatory in all profiles.

Each batched question SHOULD include illustrative scaffolding when the option set benefits from visual comparison (e.g., proposed scope boundaries, alternative success-metric framings) — render the comparison inline in the prompt (e.g., as fenced ASCII blocks or short tables) since OpenCode has no first-class "preview pane" tool. Plain-text choices need no inline scaffolding. Keep each round to at most four related questions.

## Round-3 framing checkpoint

**Mandatory.** Before continuing past round 3 the skill summarizes the current draft state back to the user and asks the framing question explicitly. Example phrasing:

> "Here's what I have so far:
> — **Goal:** ship a notifications digest so users stop missing approval requests
> — **Problem:** approval requests sit in inboxes for days
> — **Outcome:** approvers see a daily summary; SLA drops from days to hours
> — **Assumptions:** users have email; SMTP relay is acceptable
> — **Constraints:** no new infra; reuse existing mailer
> — **Non-goals:** real-time push, in-app inbox
> — **Success Metrics:** approval lag p50 < 8h within two weeks
>
> **Is this still framed correctly, or do you want to reframe before we draft the document?**"

If the user reframes, restart the section that changed and re-batch the follow-on questions. Do not skip this checkpoint because the session "feels clear."

## Round-4 premortem

**Mandatory.** After the round-3 framing is locked in, the skill runs a premortem round before the reviewer pass. The premortem exists because the round-1-to-3 loop tends to surface expected design properties ("the mailer works", "users have email") rather than the failure modes the design actually depends on not happening. Round 4 is a single batched question set that forces the user to invert the framing.

Example phrasing:

> "Imagine it's six months after we ship and this initiative quietly underperformed. Looking back, what's the single most likely reason it disappointed? Pick the one that would surprise you the *least* in retrospect."
>
> *Options offer 3–4 plausible failure-mode framings derived from the current Assumptions and Success Metrics, plus an "Other" free-text option.*

The user's answer (and any follow-up clarification) is folded into the Assumptions section as one or more new entries describing the failure mode the design depends on NOT happening. After folding in the premortem content, the skill **ranks the Assumptions from highest to lowest risk** and marks the riskiest with `(R)` or `**(riskiest)**` — these shape requirements are enforced by the hard gate (see top of file). If the user's premortem answer reveals a Success Metric that has only lagging indicators (or only leading ones), the skill also batches a follow-up to introduce the missing indicator type before exiting Round 4.

**This round runs even on `--continue` mode.** A v0.2.0 requirements doc refined under `--continue` may lack premortem content entirely; the gap-fill use case is exactly when the premortem catches things. Do NOT add a "skip on --continue" carve-out.

## Round 5: MVP design (lean-startup profile only)

**Mandatory when `profile=lean-startup`; skipped under any other profile.** After Round 4 has folded premortem failure modes into the Assumptions section and the `(R)` marker is on the riskiest entry, Round 5 runs as a single batched question set (≤ 4 questions) that designs the smallest experiment capable of validating or falsifying the `(R)`-marked assumption — a Build-Measure-Learn frame applied to the riskiest assumption rather than to the project as a whole.

The Round 5 prompt MUST explicitly lift the `(R)`-marked entry from the Assumptions section as the anchor, quoting it verbatim so the user sees exactly which assumption is being probed. Example phrasing:

> "Your riskiest assumption is `<quoted from Assumptions>`. Let's design the smallest experiment that would validate or falsify it."

The four questions in the batch (one batch, ≤ 4 questions, hard upper bound):

1. **(Q1)** What observable signal would prove the riskiest assumption wrong?
2. **(Q2)** What's the smallest/fastest thing you could build, fake, or measure to produce that signal?
3. **(Q3)** How long would the experiment take and what does it cost?
4. **(Q4)** What pivot-or-persevere decision will the result trigger?

If no Assumptions entry is marked `(R)` (e.g., the user produced a list under `--continue` from a pre-G104 doc that lacked the marker), fall back to lifting the **topmost** Assumptions entry as the anchor and note inline in the prompt that the marker was absent — do NOT abort Round 5, and do NOT silently pick a different entry without surfacing the gap. The user can mark a riskiest entry on a later refinement.

The user's answers are folded into the optional **MVP / Validation experiment** section (see "Optional auxiliary sections" below), which is unlocked exclusively under `profile=lean-startup`. The four-question batch limit is the same ≤ 4 constraint that governs every other round — do NOT extend.

**This round runs even on `--continue` mode** when `profile=lean-startup`. A prior requirements doc refined under `--continue --profile=lean-startup` may lack an MVP section entirely; the gap-fill use case is exactly when Round 5 catches it. Do NOT add a "skip on --continue" carve-out.

## Reviewer pass

After all seven sections have draft content, and before the document is written to disk, the skill auto-dispatches the `requirements-reviewer` subagent (see `agents/requirements-reviewer.md`). The reviewer's output is **advisory** — it surfaces gaps, unstated assumptions, internal contradictions, and ambiguous acceptance criteria.

If the reviewer reports substantive findings, the skill runs **at most one** refinement round to address them, then writes the document regardless of whether the reviewer is fully satisfied. Reviewer findings never block the write indefinitely; perfect is the enemy of shipped.

## Optional auxiliary sections

The document MAY also contain:

- **Sketch** — bullet-form solution shape, if the user produced one during ideation (all profiles)
- **Open Questions** — items the user explicitly deferred (all profiles)
- **Concrete Example** — a single named scenario with the user, the trigger, the current bad path, and the desired good path (**`profile=product` only**)
- **MVP / Validation experiment** — the riskiest assumption being tested (quoted from Assumptions), experiment design, success criteria, failure criteria, time box, and pivot-or-persevere decision (**`profile=lean-startup` only**)

These are **not** gated. Include them only if the conversation generated substantive content for them. The Concrete Example section is exclusive to `profile=product` — under any other profile it MUST NOT appear, even if the conversation drifted toward a concrete scenario. The MVP / Validation experiment section is exclusive to `profile=lean-startup` — under any other profile it MUST NOT appear, even if the user volunteered experiment-shaped content. Profile-exclusive sections never overlap: a single document is produced under exactly one profile and may include at most one of these two profile-exclusive sections.

## Terminal state

After the file is written and committed the skill prints exactly:

> "Requirements written to `<path>`."
> "You can stop here — the doc is the deliverable."
> "Or, to decompose this into Stride tasks and ship them in one shot, run `/stridify <path>` next."

Then the skill **stops**. It does not auto-invoke `/stridify`, does not propose follow-on tasks, does not suggest implementation steps. The terminal state is the written document. The user decides what happens next.

This is a deliberate contrast with brainstorming skills that lock terminal state to a downstream invocation. Stride ideation treats the requirements doc as a standalone deliverable.

## What this skill does NOT cover

- **Question-generation logic** — see `command/ideate.md` for how the ideation command resolves topic, manages `--continue`, and decides which questions to batch in each round.
- **Reviewer rubric** — see `agents/requirements-reviewer.md` for the exact rubric the reviewer applies to a draft.
- **Decomposition into Stride tasks AND shipping to Stride in one shot** — see `command/stridify.md` and `agents/requirements-decomposer.md`. The ideation skill stops at the requirements doc. `/stridify` itself ships with a four-layer resilience model: a preflight advisory when a doc enumerates more than 3 surfaces under `## Decomposition seams`, an optional `--goal <name|index>` flag for per-surface dispatch (consumes a `## Decomposition seams` section, partitioning a many-surface doc into one dispatch per surface), a bounded subagent-dispatch retry (3 attempts with ~30s / ~90s backoff on HTTP 529 / network / "overloaded" failures), and a fallback that writes the assembled prompt to a sibling `*-decomposer-prompt.md` file on retry exhaustion. The Stride API POST is not retried; the user re-invokes on a 4xx/5xx. None of this changes the ideation contract — it is downstream behavior.
- **Filename generation** — see `lib/filename.sh`. The skill defers to `sti_unique_path` and never computes filenames itself.
