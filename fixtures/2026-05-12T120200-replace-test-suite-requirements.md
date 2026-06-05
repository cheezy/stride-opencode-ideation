# What if we replaced the test suite

*Date: 2026-05-12 12:02*
*Session: 2026-05-12T120200-replace-test-suite*

## Problem
The current test suite has grown to 1,400+ tests across 90+ files. Wall-clock runtime on a dev laptop is around 45 seconds; on CI it pushes past 3 minutes when load is high. More urgently, the testing patterns vary wildly across the codebase — some modules use mox stubs, some use Repo.checkout with explicit transactions, some use Bypass for HTTP boundaries, and a sizeable subset of LiveView tests hit Wallaby with a real browser. Onboarding a new contributor takes a week just to internalize which pattern applies where. We do not know whether the slow tests are slow because they're integration tests (legitimate) or because they're carrying mock-heavy setup we could trim (avoidable).

## Goal
Decide whether to keep extending the current test suite or start a parallel test architecture (with a different test framework, runner, or layering convention) — and if "start parallel," produce a one-month migration plan with a concrete first vertical slice. The output of this ideation session is a decision artifact, not an implementation; the decision then drives either an extension project or a replacement project.

## Success metrics
- A written decision document committed by end of week with a clear "keep / extend / replace" recommendation
- If "replace," a named first vertical slice that can be implemented in one sprint and that demonstrates the new pattern on at least 30 tests
- Either way, a measurement plan that captures the current baseline (wall-clock, mock-vs-integration ratio, flake rate over the last 14 days) so the next decision is data-driven instead of vibes-driven

## Assumptions
- "Replace" here means architecture, not the choice between ExUnit and a third-party framework — we are staying on ExUnit. The replacement question is about layering, test fixtures, and how database state is managed.
- The current 45s/3min runtime is unbearable for at least one core contributor, but we do not yet have evidence it is bottlenecking the team broadly
- Most of the existing tests are correct in what they assert — we are debating ergonomics and runtime, not correctness
- A measurement pass on the current suite (slowest 20 tests, mock-to-integration ratio per module) is cheap and would change the conclusion

## Constraints
- We cannot delete existing tests without coverage replacement — every replaced test must have an equivalent assertion in the new layer
- We will not run two test suites in CI in parallel for longer than the migration window (no permanent duplication)
- We cannot break the existing `mix test` and `mix test --cover` entry points — those are wired into hooks, scripts, and contributor muscle memory
- The migration must be incrementally shippable; no big-bang flag day

## Non-goals
- Picking a third-party testing framework — we are staying on ExUnit; this is not the question
- Coverage tooling changes — `mix test --cover` stays
- Property-based or fuzz testing rollout — separate initiative; mentioning here just to be explicit
- Wallaby removal — separate decision; even if we do replace the unit layer, the browser-test layer is independently scoped

## Outcome
We know whether the right next action is "spend two weeks tightening the existing suite" or "start a parallel architecture with a clear migration plan." Either way, we have measurement data so the team can have the conversation without one person's gut feeling carrying it. The decision is documented so a future contributor can re-derive how we got here.

## Sketch
The decision document this ideation session leads to has these sections, in this order:

1. **Baseline measurements.** Slowest 20 tests with runtime; mock-vs-integration ratio per module; flake rate over last 14 days.
2. **Pain inventory.** Specific moments where a contributor was slowed down by the current architecture, with examples, not generic complaints.
3. **The three candidate paths.** (a) Status quo + tighten slow tests. (b) Layer convention overhaul without replacement (e.g. mandate Bypass for HTTP, Repo.checkout for DB, kill mox stubs) — staged. (c) Start a parallel test suite under a sibling `test_v2/` tree with the new convention; migrate module by module.
4. **The recommendation.** One paragraph stating the recommended path and why.
5. **The first vertical slice.** If the recommendation is (b) or (c), name the first module to migrate and the expected delta.

## Open questions
- Whose decision is this — the team's, the maintainer's, the contributor who's hurting most? Lean: maintainer-led with team input on the recommendation; revisit only if a competing recommendation emerges.
- Is the 45s wall-clock actually a problem for anyone besides the loudest voice? The baseline measurements will tell us; if no, the recommendation defaults to (a).
- Do the existing Wallaby tests count in any of the three paths? Leaving Wallaby out of scope means we are only debating the unit + integration layer.
