---
name: stride-ideation
description: Use when the user has a fuzzy idea, a new feature initiative, or a pre-decomposition scoping need and wants a written requirements document — drives a round-based question loop (up to 4 batched questions per round, with a mandatory round-3 framing checkpoint, a mandatory round-4 premortem, and a mandatory challenge gate — assumption-confidence audit, blind-spot scan, two alternatives, trade-off analysis — that runs before the reviewer pass; lean-startup additionally runs a mandatory round-5 MVP-design batch) under a named profile (lean / product / discovery / lean-startup), hard-gates the 7 required sections (Goal, Problem, Outcome, Assumptions, Constraints, Non-goals, Success Metrics) with shape requirements on Assumptions (ranked, riskiest marked, premortem-derived) and Success Metrics (both leading and lagging indicators), auto-dispatches an advisory requirements-reviewer pass with profile-aware checks, then commits a timestamped requirements doc and STOPS. The terminal state is the written document — the skill never pushes the user toward /stridify or any other next step.
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

The skill receives a `profile=<name>` parameter from the calling command. The profile selects which forcing questions run inside the rounds and which optional sections the document may include. The seven hard-gated section names and the round-3 framing checkpoint, the round-4 premortem, and the challenge gate are **identical across all profiles** — the profile only adjusts what additional content the rounds elicit and what the advisory reviewer flags. Profiles do NOT overlap: each augmentation belongs to exactly one profile.

The four profiles:

- **`lean`** (default — applied when `profile=` is absent or empty). The bare-minimum round structure: no profile-specific forcing questions, no profile-specific optional sections, no profile-specific reviewer checks. `profile=lean` is byte-for-byte equivalent to v0.3.0 behavior. Use this when the topic is small, the audience is engineering-only, or the user wants the shortest path to a committed doc.
- **`product`**. Adds a JTBD (jobs-to-be-done) four-forces forcing question to Round 1, framing Problem and Goal around the user's job, the forces pulling them toward and away from a solution, and the habits they're abandoning. Unlocks the optional **Concrete Example** section in the document (a single named scenario with the user, the trigger, the current bad path, and the desired good path). The reviewer flags missing or thin Concrete Example content and missing JTBD framing — both as advisory, never blocking. Use this when the audience includes product/design and the framing benefits from a concrete persona-bound scenario.
- **`discovery`**. Adds a Why-now + Alternative-options forcing question to Round 2, asking what makes this problem worth solving *now* versus later, and which other options were considered and rejected. The reviewer flags missing Why-now content as advisory, never blocking. No new optional sections — the Why-now content folds into the existing Problem and Assumptions sections. Use this when the topic is early-stage and the case-for-action is the riskiest part of the framing.
- **`lean-startup`**. Adds a mandatory Round-5 MVP-design batch (Build-Measure-Learn frame) that anchors on the `(R)`-marked entry from Assumptions and asks the user to design the smallest experiment capable of validating or falsifying that assumption. Unlocks the optional **MVP / Validation experiment** section in the document (riskiest assumption being tested, experiment design, success criteria, failure criteria, time box, pivot-or-persevere decision). The reviewer flags absence of the MVP section under this profile and non-falsifiable success/failure criteria — both as advisory, never blocking. Use this when the next step is a deliberate validation experiment rather than a full implementation, and the project warrants explicit Build-Measure-Learn framing.

The default `lean` profile is the safe choice when nothing else applies. The profile is locked at command invocation time and does not change mid-session.

**Profile recommendation (command surface).** When `/ideate` is invoked **without** an explicit `--profile`, the command recommends a profile before the rounds begin — a single question (via OpenCode's question UI) presenting a best-guess profile first (labeled `(recommended)` with a one-line rationale) and the other three as alternatives, defaulting to `lean` — and passes the resolved choice to this skill as `profile=`. When `--profile` is supplied explicitly, no recommendation runs and the unknown-value fast-fail is unchanged. Either way this skill receives one already-resolved profile; the recommendation is a command-surface concern that does not change any per-profile behavior defined above, and a resolved `lean` is byte-for-byte identical to passing `--profile=lean`. See Step 1 of `commands/ideate.md`.

## The questioning loop

A **round** is one batched set of one to four related questions posed to the user. Rounds proceed until each of the seven required sections has draft content; a typical session uses three to five rounds.

| Round | Default focus (all profiles) | Profile-specific augmentations |
|---|---|---|
| 1 | Goal, Problem, Outcome — what's being built and why | `product`: also runs JTBD four-forces forcing question |
| 2 | Assumptions, Constraints, Non-goals — boundary conditions | `discovery`: also runs Why-now + Alternative-options forcing questions |
| 3 | Success Metrics + framing checkpoint (see below) | (none) |
| 4 | Premortem — challenge Assumptions, fold failure modes back in (see below) | (none) |
| 5 | MVP design — anchor on the `(R)`-marked Assumptions entry and design the smallest validating experiment (lean-startup only; see below) | `lean-startup`: runs the four-question MVP-design batch |
| Challenge | Challenge gate — audit confidence in every assumption, scan blind spots, generate two alternatives, compare trade-offs (see below) | (none) |
| 6+ | Gap-fill for whichever sections still lack substance | (none) |

The default-focus column is identical across all four profiles — only the augmentation column and Round-5 attendance change. `profile=lean` runs the table with the augmentation column empty and Round 5 skipped (byte-for-byte v0.3.0). `profile=product` adds the Round-1 JTBD batch and skips Round 5. `profile=discovery` adds the Round-2 Why-now + Alternative-options batch and skips Round 5. `profile=lean-startup` runs the Round-5 MVP-design batch (mandatory under this profile; skipped under any other profile). Round 3 (framing), Round 4 (premortem), and the challenge gate are profile-independent and mandatory in all profiles.

Each batched question SHOULD include illustrative scaffolding when the option set benefits from visual comparison (e.g., proposed scope boundaries, alternative success-metric framings) — render the comparison inline in the prompt (e.g., as fenced ASCII blocks or short tables) since OpenCode has no first-class "preview pane" tool. Plain-text choices need no inline scaffolding. Keep each round to at most four related questions.

Every gated-section question and every profile-specific forcing question (JTBD, Why-now, MVP design) MUST also carry the uncertainty-path option described in **Uncertainty path** below, so a stuck user always has a supported way to ask for help instead of bailing or entering a low-quality answer.

## Round recap

**Mandatory.** Before every round — including round 1 (all sections empty) and every gap-fill round — the skill prints a compact recap of the seven hard-gated sections with a per-section status, plus a one-line note of which sections the upcoming round targets. The recap exists to orient the user inside an otherwise open-ended interrogation and to show visible progress toward a finished doc, reducing fatigue across the four-to-six round loop.

The recap is **display-only narration rendered through OpenCode's normal output** — plain markdown text, not a question. It is NEVER an extra question round, and it MUST NOT change the gate, the round order, or the per-round question budget. It is printed immediately before the round's batched questions, then the round proceeds normally.

Each of the seven sections gets exactly one of three statuses:

- **empty** — no content captured yet.
- **thin** — some content exists but it does not yet satisfy the gate (a placeholder, a single-line gesture, or — for Assumptions and Success Metrics — content that is present but still missing its shape requirement, e.g. unranked Assumptions or all-lagging Success Metrics).
- **solid** — substantive content that satisfies the gate, including any shape requirement.

The recap lists **only the seven hard-gated sections, always in their canonical order** (Goal, Problem, Outcome, Assumptions, Constraints, Non-goals, Success Metrics). It MUST NOT surface optional or profile-exclusive sections (Concrete Example, MVP / Validation experiment, Sketch, Open Questions, Design challenge) — those are not completeness gates, and listing a profile-locked section under the wrong profile would mislead. Because the seven gate names are identical across all four profiles, the recap rows are emitted unconditionally and identically under `lean`, `product`, `discovery`, and `lean-startup`.

Example phrasing (a round-1 recap, everything still empty):

> **Progress so far** (round 1 of ~4):
> — **Goal:** empty
> — **Problem:** empty
> — **Outcome:** empty
> — **Assumptions:** empty
> — **Constraints:** empty
> — **Non-goals:** empty
> — **Success Metrics:** empty
>
> **This round targets:** Goal, Problem, Outcome.

Example phrasing (a later gap-fill recap, mixed status):

> **Progress so far** (round 6):
> — **Goal:** solid
> — **Problem:** solid
> — **Outcome:** solid
> — **Assumptions:** thin (not yet ranked)
> — **Constraints:** solid
> — **Non-goals:** solid
> — **Success Metrics:** thin (leading indicator only)
>
> **This round targets:** Assumptions, Success Metrics.

On a `--continue` session the round-1 recap reflects whatever the prior document already supplies — sections that arrive substantive start at **solid** rather than **empty**. The recap never lowers the gate or skips a round on the strength of an inherited status; it only reports it.

When the command threads `input_notes` (the `--input` brain-dump seed, analogous to `prior_doc` but raw rather than a committed requirements doc), the skill pre-populates draft sections wherever the notes clearly map to a gated section and the round-1 recap reflects that seeding — but a seeded section starts at **thin**, not **solid**, because unconfirmed brain-dump content has not yet been verified section-by-section with the human. The seed lowers the starting cost, never the bar: every hard gate, the round-3 framing checkpoint, the premortem, and the reviewer pass still run, and the rounds focus on the gaps the notes did not cover. `input_notes` and `prior_doc` are independent and may both be present in one session.

## Uncertainty path

**Mandatory on every gated-section question and every forcing question.** Alongside the real answer choices, every question whose answer feeds a gated section or a profile-specific forcing question MUST offer a first-class choice that means **"I'm not sure — propose candidates for me,"** presented through OpenCode's own question UI (not Claude Code's `AskUserQuestion`). The most valuable moments in ideation are exactly when the user is uncertain; without this escape hatch a forced pick leaves them only two bad choices — bail, or enter a low-quality answer. The choice turns the skill into a thinking partner instead of an interrogator.

Keep the option phrasing **identical across all rounds** (the literal label *"I'm not sure — propose candidates"*) so the user learns it once and recognizes it everywhere. It is a choice *within* a question, not a new question — adding it NEVER increases the round's question count and MUST NOT push a round over the per-round question budget.

When the user picks it, the skill flips into **teaching mode** for that one section:

1. Propose **2–4 concrete candidate answers** for the section, each derived from the **session's actual topic and the content gathered so far** — never generic boilerplate. A candidate for a notifications-digest project must read like it belongs to that project.
2. Give **each candidate a one-line rationale** explaining why it might fit, so the user is choosing between reasoned options rather than guessing.
3. Let the user **pick one, edit one, or reject all and ask for a fresh batch.** If they reject all, propose a new batch rather than looping on the same candidates or giving up.

**Hard rule — the uncertainty path can NEVER auto-satisfy the gate.** A proposed candidate is the skill's suggestion, not the user's answer. It counts as **substantive content** (see **Hard gate**) only after the user explicitly selects or edits one to confirm it. Just as "just write what we have" cannot skip the gate, the skill's own candidates cannot fill a section on the user's behalf — it proposes, the human decides, and the section stays **empty**/**thin** in the round recap until a human-confirmed answer lands. Repeated picks of the uncertainty path keep proposing; they never silently fill the section to make the loop terminate.

Example phrasing (the choice as it appears inside a Success Metrics question):

> "How will you know this worked? Pick a framing, or:
> — **I'm not sure — propose candidates** — I'll suggest 2–4 metric framings drawn from your Goal and Outcome, each with a one-line rationale, and you choose or edit one."

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

## Challenge gate

**Mandatory.** After the round-4 premortem has folded its failure modes into the Assumptions section — and, under `profile=lean-startup`, after the Round-5 MVP-design batch — and **before** the reviewer pass, the skill runs a challenge gate over the assembled draft. The premortem inverts the framing to surface the *single* most likely failure mode; the challenge gate is deliberately **broader**. It audits the confidence behind *every* assumption, scans for blind spots the premortem's single-failure-mode inversion never reaches, and forces a comparison against genuine alternatives. The premortem asks "what's the one thing most likely to go wrong?"; the challenge gate asks "what aren't we even looking at, how sure are we of each belief, and what else could we have built?" The two do not duplicate each other — the confidence audit and blind-spot scan are wider than the premortem's failure-mode inversion, and the gate runs over the premortem's output rather than repeating it.

The gate has four components, run in order:

- **(a) Assumption-confidence audit.** Enumerate every entry in the Assumptions section and rate confidence in each as **high**, **medium**, or **low**. This is a sweep across the whole list, not the premortem's single riskiest-failure-mode inversion.
- **(b) Blind-spot scan.** Surface what the draft has not considered — unstated dependencies, omitted stakeholders, untested edge cases, and failure modes the premortem missed. The premortem captures one inverted failure mode; this scan looks wider, for the things no question in rounds 1–4 thought to ask.
- **(c) Alternative generation.** Produce **two distinct alternative approaches** to the proposed design — not strawmen, but approaches a reasonable person might genuinely prefer.
- **(d) Trade-off analysis.** Compare the proposed design against the two alternatives across **cost, risk, complexity, and timeline**, so the proposed design is chosen against real options rather than by default.

Example phrasing:

> "Before I hand this to the reviewer, let me challenge the design. I've rated confidence in each assumption, scanned for blind spots (unstated dependencies, omitted stakeholders, untested edge cases, failure modes the premortem missed), and sketched two alternative approaches with a cost / risk / complexity / timeline comparison. What would you like to act on?"
>
> *Options are multi-select: one per low-confidence assumption, one per material blind spot, one per alternative worth pursuing, plus an explicit **"Challenge nothing — write as-is"** option so the draft can proceed untouched.*

**The gate is advisory and NEVER blocks the write.** Exactly like the reviewer pass, the findings are the human's decision, not the skill's. The option set MUST include an explicit **"Challenge nothing — write as-is"** choice so the human can proceed with the draft untouched. The human selects what to act on; the skill then runs **at most one** refinement round covering exactly the selected items (selecting nothing, or only the write-as-is option, skips the refinement round entirely) and continues to the reviewer pass regardless of whether every item was resolved. The challenge gate never holds the document hostage — proceed-as-is is always available. Perfect is the enemy of shipped.

Outputs fold back into the document, mirroring the premortem fold-back:

- The **confidence ratings annotate the Assumptions section in place** — each assumption gains its high/medium/low rating where it already sits, the same way the premortem's failure modes are folded into Assumptions rather than parked elsewhere. The audit never reorders the list or disturbs the `(R)` / `**(riskiest)**` marker the premortem set.
- The **blind spots, the two alternatives, and the trade-off comparison fold into a new optional "Design challenge" section** (see "Optional auxiliary sections" below). That section is optional and ungated — it is NOT one of the seven hard-gated sections and is NOT added to the round recap.

The gate is **profile-independent**: it runs identically under `lean`, `product`, `discovery`, and `lean-startup`, exactly like the round-3 framing checkpoint and the round-4 premortem. The profile changes nothing about its four components or its fold-back.

**This gate runs even on `--continue` mode.** A requirements doc refined under `--continue` may never have been challenged; the gap-fill use case is exactly when the confidence audit and blind-spot scan catch what the original rounds missed. Do NOT add a "skip on --continue" carve-out.

## Reviewer pass

After all seven sections have draft content, and before the document is written to disk, the skill auto-dispatches the `requirements-reviewer` subagent (see `agents/requirements-reviewer.md`). The reviewer's output is **advisory** — it surfaces gaps, unstated assumptions, internal contradictions, and ambiguous acceptance criteria.

**The findings are the human's decision, not the skill's.** When the reviewer returns `verdict: "issues_found"`, the skill presents the findings to the human via a single **multi-select** question through OpenCode's own question UI (not Claude Code's `AskUserQuestion`) — one option per finding, each a single line tagged with its `severity` (`blocking` / `advisory`) and naming its `section`. The option set MUST include an explicit **"Address none — write as-is"** choice so the human can ship the document untouched. The human selects which findings to address; the skill then runs **at most one** refinement round covering exactly the selected findings (selecting nothing, or only the write-as-is option, skips the refinement round entirely) and writes the document afterward regardless of whether every finding was resolved. The decision obeys the same `≤ 4`-options ergonomics as the rest of the loop — if the reviewer returns more than a handful of findings, group or summarize them into the option set, but never spawn a second decision round.

Two contracts are load-bearing and unchanged. (1) There is **at most one** refinement round: the human's selection feeds that single round; the skill never runs a second, no matter how many findings were selected. (2) The reviewer **never blocks the write** — findings are advisory input to a human decision, and "write as-is" is always available, so even `blocking`-severity findings cannot hold the document hostage. Perfect is the enemy of shipped.

**When the reviewer returns `verdict: "approved"` (empty `issues`), show no decision prompt at all** — there is nothing to decide, so the skill proceeds straight to writing the document. Never display an empty decision question, or one whose only option is "write as-is".

## Optional auxiliary sections

The document MAY also contain:

- **Sketch** — bullet-form solution shape, if the user produced one during ideation (all profiles)
- **Open Questions** — items the user explicitly deferred (all profiles)
- **Design challenge** — blind spots surfaced by the challenge gate (unstated dependencies, omitted stakeholders, untested edge cases, missed failure modes), the two distinct alternative approaches, and a cost / risk / complexity / timeline trade-off comparison against the proposed design (all profiles)
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
