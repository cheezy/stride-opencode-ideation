# Saved board filters

*Date: 2026-05-12 12:03*
*Session: 2026-05-12T120300-saved-filters-challenge-gate*

## Problem
Power users re-apply the same combination of column, assignee, and label filters dozens of times a day. The board remembers nothing between visits, so every session starts from the unfiltered firehose and the user rebuilds the same view by hand. The repeated setup is friction that scales with how engaged the user is — the most active users pay the highest tax.

## Goal
A user can name and save a filter combination once and re-apply it in a single click on any later visit, so the board opens to the view they actually work in rather than the unfiltered default.

## Success metrics
- **leading indicators** (observable while the work is in flight, predict the outcome):
  - At least 30 percent of weekly-active users create at least one saved filter within two weeks of launch
  - Median time-to-first-meaningful-view on board open drops below 3 seconds (measured from board mount to first filter application)
- **lagging indicators** (the outcome itself, observable only after it has occurred):
  - Manual filter re-application events per active user per day drop by 50 percent eight weeks after launch
  - Board-open-to-first-card-interaction time p50 improves measurably quarter over quarter

## Assumptions
*Ordered highest to lowest risk; the riskiest entry is marked `(R)` (or `**(riskiest)**`). Each entry also carries the challenge gate's confidence rating — `(high)`, `(medium)`, or `(low)` — folded in place by the assumption-confidence audit.*
- Users actually want to save filters rather than just wanting a smarter default view the system picks for them (R) (low)
- The existing filter state is fully serializable to a small JSON blob with no server-derived fields that go stale (medium)
- Per-user storage of a handful of named filters adds negligible load to the existing user-preferences table (high)
- Users will manage (rename, delete) their saved filters rarely enough that a minimal management UI is sufficient for v1 (medium)

## Constraints
- Reuse the existing `user_preferences` storage seam — do not introduce a new table or a new persistence library
- Saved filters are per-user and never shared across users in v1 (no team-shared views)
- The feature must not change the unfiltered default for users who never create a saved filter

## Non-goals
- Team-shared or board-shared saved filters — deferred to a later initiative
- Smart/automatic view selection (ML-ranked default) — explicitly out of scope
- Saved sorts or saved column layouts — this initiative is filters only

## Outcome
Returning users land on the view they work in, not the unfiltered firehose. The most active users — who paid the highest repeated-setup tax — get the largest time saving. The board feels like it remembers them.

## Open questions
- Should a saved filter capture the active search text, or only the structured column/assignee/label filters? Lean structured-only for v1, revisit if users ask.
- Cap on the number of saved filters per user? Lean a soft cap of 10 with no hard enforcement in v1.

## Design challenge
- **Blind spots:** the premortem covered low adoption, but the audit surfaced three things rounds 1–4 never asked about — (1) an unstated dependency on the filter state being serializable without server-derived fields that can go stale between save and re-apply; (2) an omitted stakeholder, the support team, who will field "my saved filter shows nothing" tickets when a saved label is later deleted; (3) an untested edge case where a saved filter references a column or assignee that no longer exists, which must degrade gracefully rather than error.
- **Alternative A — smarter default view instead of explicit saves:** the system infers and restores each user's most-recent filter automatically, with no naming and no management UI. Removes the "will users bother to save?" adoption risk entirely but gives up multi-view switching and makes the behavior implicit (harder to reason about, harder to turn off).
- **Alternative B — shareable saved views as URL state:** encode the filter combination in the board URL so a view is saved and shared by bookmarking or pasting a link, with no per-user storage at all. Cheapest to build and unlocks sharing for free, but leans on users managing bookmarks themselves and does not survive a user who never bookmarks.
- **Trade-off comparison:**

  | Dimension | Proposed (named per-user saves) | Alternative A (smart default) | Alternative B (URL state) |
  |---|---|---|---|
  | Cost | Medium — storage + management UI | Low — no UI, infer-and-restore | Low — encode/decode URL only |
  | Risk | Medium — adoption depends on users saving | Low — zero user effort to benefit | Medium — relies on user bookmarking habits |
  | Complexity | Medium — CRUD + apply path | Medium — inference + restore heuristic | Low — stateless URL round-trip |
  | Timeline | ~2 sprints | ~1.5 sprints | ~1 sprint |
