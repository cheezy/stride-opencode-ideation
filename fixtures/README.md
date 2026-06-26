# fixtures/

Smoke-test and regression fixtures for the `stride-copilot-ideation` plugin (copilot port of `cheezy/stride-ideation`). Each fixture pair (`*-requirements.md` + `*-stride-batch.json`) shares a timestamp prefix and demonstrates a different shape of decomposition output. The fixtures are copied verbatim from upstream so a Copilot run against the `stride-ideation-stridify` skill should produce comparable shapes when the decomposer agent is invoked against the same requirements doc.

The fixtures serve two purposes:

1. **Calibration reference** — when an implementer is unsure what "good" `stride-ideation-ideate` or `stride-ideation-stridify` skill output looks like for their case, they can open the closest-matching fixture pair as a reference.
2. **Regression check** — when the `requirements-decomposer` agent prompt changes, re-activate the `stride-ideation-stridify` skill against each `*-requirements.md` and diff the result against the committed `*-stride-batch.json`. Material drift means the prompt change altered observable behavior — that may be intentional, but it should be explicit. (Note: the stride-ideation-stridify skill also POSTs the batch to the Stride API, so use a non-prod workspace when running regressions.)

The fixtures are **not** training data. The decomposer prompt should produce these shapes from first principles, not by memorizing these specific outputs. If a prompt change requires rewriting these fixtures to match, that is a yellow flag — confirm the prompt change is more general than just "match the fixtures."

## The three pairs

### 1. Small / single-goal — `dark-mode-toggle`

- **Requirements:** `2026-05-12T120000-dark-mode-toggle-requirements.md`
- **Batch:** `2026-05-12T120000-dark-mode-toggle-stride-batch.json`
- **Shape:** 1 goal, 5 tasks

A small feature where all work lives in one Phoenix layer (the UI). The decomposer keeps everything in a single goal because the tasks are code-coupled — tokens must land before the toggle component can reference them; persistence must land before the FOUC script can read it. No cross-goal coordination needed; `decomposition_notes` explicitly states this.

This is what the decomposer produces for the bulk of single-seam feature work: small, tightly-coupled task graphs that one human can claim and ship in a sitting.

### 2. Multi-goal independent — `notifications-system`

- **Requirements:** `2026-05-12T120100-notifications-system-requirements.md`
- **Batch:** `2026-05-12T120100-notifications-system-stride-batch.json`
- **Shape:** 3 goals, 16 tasks total

An initiative whose `Sketch` section explicitly named three orthogonal seams: event detection + queue (G1), user preferences UI (G2), email rendering + dispatch (G3). The decomposer splits along those seam boundaries.

G2 (preferences UI) is fully independent of the other two — it can be claimed in parallel. G3 (rendering) depends on G1 (queue contract). `decomposition_notes` documents the claim ordering: **G1 first, G2 in parallel, G3 after G1 lands.** The dependency is expressed in plain text, NOT in the `dependencies` arrays (the batch API can't encode cross-goal references at submission time).

### 3. Multi-goal coupled (sizing-driven split) — `replace-test-suite`

- **Requirements:** `2026-05-12T120200-replace-test-suite-requirements.md`
- **Batch:** `2026-05-12T120200-replace-test-suite-stride-batch.json`
- **Shape:** 2 goals, 14 tasks total

A decision-then-execute initiative. Without splitting, this would be a single goal of 14 tasks — past the ~10-task soft cap from the decomposer's methodology. The natural seam is **decide vs execute**: G1 owns measurement + the recommendation document; G2 picks up the first vertical slice from whichever path the recommendation selects.

The dependency between G1 and G2 is hard: G2's first task literally cannot be scoped until G1's recommendation lands in `main`. `decomposition_notes` makes this explicit (`CROSS-GOAL CLAIM ORDERING: Claim G1 first and let its final task... land in main BEFORE claiming G2`).

This is the shape the multi-goal split rule was designed for — code-coupled work that exceeds the soft cap and admits a clean seam.

## Protocol-output fixture (no batch pair)

### 4. Challenge-gate output — `saved-filters-challenge-gate`

- **Requirements:** `2026-05-12T120300-saved-filters-challenge-gate-requirements.md`
- **Batch:** none — this fixture is a standalone `/ideate` output, not a `/stridify` decomposition pair.

Unlike the three pairs above, this fixture exists to demonstrate the **challenge-gate output shape** (added in the `## Challenge gate` section of `skills/stride-ideation/SKILL.md` and the Step-6 `## Design challenge` template in `commands/ideate.md`). It shows what a committed requirements doc looks like *after* the gate has run: a `## Design challenge` section holding two distinct alternatives and a cost/risk/complexity/timeline trade-off comparison, plus an `## Assumptions` section whose entries carry the gate's `(high)`/`(medium)`/`(low)` confidence ratings folded in place (alongside the `(R)` riskiest marker).

It is the calibration reference for "what good challenge-gate output looks like," and it is the fixture the `lib/test-challenge-gate.sh` unit suite (and its `lib/test-challenge-gate.ps1` mirror) and Stage 6 of `lib/run_smoke_test.sh` (and `lib/run_smoke_test.ps1`) assert against. Because it is not a decomposition pair, it has no `*-stride-batch.json` and is not part of the drift-check / validator regression loop.

## Re-running and updating

To verify the fixtures match current decomposer behavior:

```bash
# Validate the committed shape against the schema validator
for f in fixtures/*-stride-batch.json; do
  python3 lib/validate_batch.py "$f" || echo "FAILED: $f"
done

# Re-activate stride-ideation-stridify against each requirements fixture and diff
# (interactive — requires a Copilot CLI session; will also POST to the
# Stride API, so prefer a non-prod workspace for diffing-only runs)
# > Activate stride-ideation-stridify against fixtures/2026-05-12T120000-dark-mode-toggle-requirements.md
# diff fixtures/2026-05-12T120000-dark-mode-toggle-stride-batch.json <newly-written-file>
```

When you intentionally update a fixture (because the requirements fixture changed, or because a prompt update legitimately produces a different shape), recompute the `source_spec_sha256` and update the committed batch file in the same commit. The stamping pipeline in `skills/stride-ideation-stridify/SKILL.md` handles this automatically when the skill is activated.
