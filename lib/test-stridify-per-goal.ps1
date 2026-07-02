# PowerShell mirror of test-stridify-per-goal.sh — tests for the
# /stride-ideation:stridify --goal flag (W714):
#
#   - Sti-ExtractSeams     parses ## Decomposition seams sections
#   - Sti-ResolveGoal      resolves --goal <name|index> against extracted seams
#   - Sti-ScopeDocToSeam   prunes the seams section to a single matched item
#
# These three helpers live in lib/filename.ps1; this file tests them directly.
# Cases also exercise the documented behavior of the wrapping logic in
# commands/stridify.md Step 1 (argument parsing) and Step 5 (target-path
# slug composition) via small reference PowerShell snippets embedded below.
#
# Full-parity port: every assertion in test-stridify-per-goal.sh has a 1:1
# counterpart here, with the same case labels in the same order.
#
# Run:
#   pwsh -File lib/test-stridify-per-goal.ps1
#
# Exits 0 if all tests pass, non-zero otherwise.

Set-StrictMode -Version Latest

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $ScriptDir 'filename.ps1')

$script:PASS = 0
$script:FAIL = 0
function Pass([string]$msg) { $script:PASS++; Write-Host "  PASS  $msg" }
function Fail([string]$msg, [string]$detail = '') {
    $script:FAIL++
    Write-Host "  FAIL  $msg"
    if ($detail) { Write-Host "        $detail" }
}

Write-Host 'test-stridify-per-goal.ps1 — exercises the --goal parse/resolve/scope helpers'
Write-Host ''

$TMP = Join-Path ([System.IO.Path]::GetTempPath()) "sti-per-goal-$(Get-Random)"
New-Item -ItemType Directory -Path $TMP | Out-Null

try {
    # --- fixture: a realistic seven-surface requirements doc -------------------

    $sevenSurfaces = Join-Path $TMP 'seven-surfaces.md'
    Set-Content -LiteralPath $sevenSurfaces -Encoding UTF8 -Value @'
# Some Feature

## Problem

A description of the problem.

## Goal

The goal.

## Outcome

The outcome.

## Decomposition seams

**This document must be decomposed into seven independent goals.**

The seven surfaces:

1. **Kanban app** (this repo: `lib/kanban_web/...`) — defines the contract.
2. **stride plugin** (this repo: `stride/`) — reference workflow.
3. **stride-copilot** (separate repo) — Copilot CLI adapter.
4. **stride-gemini** (separate repo) — Gemini CLI adapter.
5. **stride-codex** (separate repo) — Codex adapter.
6. **stride-opencode** (separate repo) — OpenCode adapter.
7. **stride-pi** (separate repo) — Pi Coding Agent adapter.

## Assumptions

Assumptions go here.
'@

    # --- fixture: a doc WITHOUT a Decomposition seams section -----------------

    $noSeams = Join-Path $TMP 'no-seams.md'
    Set-Content -LiteralPath $noSeams -Encoding UTF8 -Value @'
# Some Feature

## Problem

Just one goal, no seams.

## Goal

A single goal.

## Outcome

Done.
'@

    # --- fixture: seams section present but the numbered list is empty -------

    $emptySeams = Join-Path $TMP 'empty-seams.md'
    Set-Content -LiteralPath $emptySeams -Encoding UTF8 -Value @'
# Some Feature

## Problem

Foo.

## Decomposition seams

This section was added but no surfaces have been enumerated yet.

## Outcome

Outcome.
'@

    # --- fixture: a doc whose item 2 has a multi-line body --------------------

    $multilineBody = Join-Path $TMP 'multiline-body.md'
    Set-Content -LiteralPath $multilineBody -Encoding UTF8 -Value @'
# Doc

## Decomposition seams

1. **First** — one-liner.
2. **Second** — line one of the body.
   Continuation line two.
   Continuation line three.
3. **Third** — back to one-liners.
'@

    # --- fixture: a doc with a seam literally named "1" -----------------------

    $seamNamedOne = Join-Path $TMP 'seam-named-one.md'
    Set-Content -LiteralPath $seamNamedOne -Encoding UTF8 -Value @'
# Doc

## Decomposition seams

1. **Alpha** — first surface.
2. **1** — second surface, literally named "1".
3. **Gamma** — third surface.
'@

    # --- fixture: items missing the **bold** marker --------------------------

    $missingBold = Join-Path $TMP 'missing-bold.md'
    Set-Content -LiteralPath $missingBold -Encoding UTF8 -Value @'
# Doc

## Decomposition seams

1. **Valid** — has bold name.
2. Plain Name — missing bold; should be skipped.
3. **Also valid** — has bold name.
'@

    # === case 1: --goal absent on a doc without seams stays in "all goals" ====

    # Reference Step 1 parser: extract GOAL_ARG from $ARGUMENTS-style input.
    # Mirrors commands/stridify.md Step 1. Returns a two-element array:
    # (goal-arg — possibly empty, trimmed remainder).
    function Parse-GoalArg([string]$ArgString) {
        $goal = ''
        $out = @()
        $tokens = @($ArgString -split '\s+' | Where-Object { $_ -ne '' })
        $i = 0
        while ($i -lt $tokens.Count) {
            $t = $tokens[$i]
            if ($t -eq '--goal') {
                $i++
                $goal = if ($i -lt $tokens.Count) { $tokens[$i] } else { '' }
                $i++
                continue
            }
            if ($t -like '--goal=*') {
                $goal = $t.Substring('--goal='.Length)
            } else {
                $out += $t
            }
            $i++
        }
        return @($goal, ($out -join ' '))
    }

    $case1 = Parse-GoalArg '/path/to/no-seams.md'
    if ([string]::IsNullOrEmpty($case1[0]) -and $case1[1] -ceq '/path/to/no-seams.md') {
        Pass 'case 1: --goal absent → empty GOAL_ARG, remainder is the path (AC8)'
    } else {
        Fail 'case 1: parse with no flag' "goal='$($case1[0])' rest='$($case1[1])'"
    }

    # === case 2: --goal "Kanban app" resolves to seam 1 by slug ===============

    $case2 = Sti-ResolveGoal -Path $sevenSurfaces -GoalArg 'Kanban app'
    if ($LASTEXITCODE -eq 0) {
        $parts = $case2 -split "`t"
        if ($parts[0] -eq '1' -and $parts[1] -ceq 'Kanban app' -and $parts[2] -ceq 'kanban-app') {
            Pass "case 2: --goal 'Kanban app' → index=1 name='Kanban app' slug=kanban-app (AC1, AC2)"
        } else {
            Fail 'case 2: wrong resolution' "idx=$($parts[0]) name='$($parts[1])' slug=$($parts[2])"
        }
    } else {
        Fail "case 2: Sti-ResolveGoal exited rc=$LASTEXITCODE (expected 0)"
    }

    # === case 3: --goal 3 resolves to seam 3 by integer index =================

    $case3 = Sti-ResolveGoal -Path $sevenSurfaces -GoalArg '3'
    if ($LASTEXITCODE -eq 0) {
        $parts = $case3 -split "`t"
        if ($parts[0] -eq '3' -and $parts[2] -ceq 'stride-copilot') {
            Pass 'case 3: --goal 3 → integer-index resolves to stride-copilot (AC2)'
        } else {
            Fail 'case 3: wrong integer resolution' "idx=$($parts[0]) slug=$($parts[2])"
        }
    } else {
        Fail 'case 3: Sti-ResolveGoal exited non-zero on integer arg'
    }

    # === case 4: hyphenated slug resolves correctly ===========================

    $case4 = Sti-ResolveGoal -Path $sevenSurfaces -GoalArg 'stride-pi'
    if ($LASTEXITCODE -eq 0) {
        $parts = $case4 -split "`t"
        if ($parts[0] -eq '7') {
            Pass 'case 4: --goal stride-pi resolves to seam 7 (hyphenated slug, no integer collision)'
        } else {
            Fail 'case 4: hyphenated slug resolved to wrong index' "idx=$($parts[0])"
        }
    } else {
        Fail 'case 4: Sti-ResolveGoal exited non-zero on hyphenated slug'
    }

    # === case 5: --goal=<value> form parses identically =======================

    $case5a = (Parse-GoalArg '--goal kanban-app /path/to/doc.md')[0]
    $case5b = (Parse-GoalArg '--goal=kanban-app /path/to/doc.md')[0]
    if ($case5a -ceq 'kanban-app' -and $case5b -ceq 'kanban-app') {
        Pass 'case 5: --goal <v> and --goal=<v> parse to identical GOAL_ARG (AC1)'
    } else {
        Fail 'case 5: dual-form parser disagrees' "form1='$case5a' form2='$case5b'"
    }

    # === case 6: unresolved --goal errors with seam listing ===================

    $null = Sti-ResolveGoal -Path $sevenSurfaces -GoalArg 'nonexistent' 2>$null
    if ($LASTEXITCODE -eq 3) {
        Pass 'case 6: unresolved --goal returns rc=3 (AC4)'
    } else {
        Fail "case 6: expected rc=3, got rc=$LASTEXITCODE"
    }
    # The CALLER prints the available-seams list; verify Sti-ExtractSeams gives
    # the data needed for that listing.
    $case6Seams = @(Sti-ExtractSeams -Path $sevenSurfaces)
    if ($case6Seams.Count -eq 7) {
        Pass 'case 6: Sti-ExtractSeams returns 7 seams for the listing (AC4 evidence)'
    } else {
        Fail "case 6: expected 7 seams, got $($case6Seams.Count)"
    }

    # === case 7: absent seams section returns rc=2 ============================

    $null = Sti-ResolveGoal -Path $noSeams -GoalArg 'anything' 2>$null
    if ($LASTEXITCODE -eq 0) {
        Fail 'case 7: resolver returned 0 on doc without seams section'
    } elseif ($LASTEXITCODE -eq 2) {
        Pass 'case 7: doc without seams section → rc=2 (AC3)'
    } else {
        Fail "case 7: expected rc=2 got rc=$LASTEXITCODE"
    }

    # === case 8: empty seams section returns rc=4 =============================

    $null = Sti-ResolveGoal -Path $emptySeams -GoalArg 'anything' 2>$null
    if ($LASTEXITCODE -eq 0) {
        Fail 'case 8: resolver returned 0 on doc with empty seams list'
    } elseif ($LASTEXITCODE -eq 4) {
        Pass 'case 8: empty seams list → rc=4 (testing_strategy edge)'
    } else {
        Fail "case 8: expected rc=4 got rc=$LASTEXITCODE"
    }

    # === case 9: path-suffix construction =====================================

    # Reference Step 5 composition (matches commands/stridify.md Step 5).
    function Get-SlugForPath([string]$DocSlug, [string]$GoalSlug = '') {
        if ($GoalSlug) { return "$DocSlug-$GoalSlug" }
        return $DocSlug
    }

    $targetNoGoal = Sti-UniquePath -Dir $TMP -Timestamp '2026-05-15T210800' `
        -Slug (Get-SlugForPath 'review-queue-code-diffs') -Artifact 'stride-batch' -Extension 'json'
    $expectedNoGoal = "$TMP/2026-05-15T210800-review-queue-code-diffs-stride-batch.json"
    if ($targetNoGoal -ceq $expectedNoGoal) {
        Pass 'case 9a: target path without --goal matches historical format (AC8)'
    } else {
        Fail 'case 9a: target path mismatch' "got=$targetNoGoal want=$expectedNoGoal"
    }

    $targetWithGoal = Sti-UniquePath -Dir $TMP -Timestamp '2026-05-15T210800' `
        -Slug (Get-SlugForPath 'review-queue-code-diffs' 'kanban-app') -Artifact 'stride-batch' -Extension 'json'
    $expectedWithGoal = "$TMP/2026-05-15T210800-review-queue-code-diffs-kanban-app-stride-batch.json"
    if ($targetWithGoal -ceq $expectedWithGoal) {
        Pass 'case 9b: target path with --goal embeds goal slug between doc-slug and artifact (AC6)'
    } else {
        Fail 'case 9b: target path mismatch' "got=$targetWithGoal want=$expectedWithGoal"
    }

    # === case 10: commit-message construction =================================

    # Reference Step 8d commit-message composition.
    function Get-CommitMsg([string]$DocSlug, [string]$GoalSlug = '') {
        if ($GoalSlug) { return "stride-ideation: decomposition for $DocSlug goal $GoalSlug" }
        return "stride-ideation: decomposition for $DocSlug"
    }

    $m10a = Get-CommitMsg 'review-queue-code-diffs'
    $m10b = Get-CommitMsg 'review-queue-code-diffs' 'kanban-app'
    if ($m10a -ceq 'stride-ideation: decomposition for review-queue-code-diffs') {
        Pass 'case 10a: commit message without --goal unchanged (AC8)'
    } else {
        Fail 'case 10a: commit message mismatch' $m10a
    }
    if ($m10b -ceq 'stride-ideation: decomposition for review-queue-code-diffs goal kanban-app') {
        Pass 'case 10b: commit message with --goal includes goal slug (AC6)'
    } else {
        Fail 'case 10b: commit message mismatch' $m10b
    }

    # === case 11: same --goal invoked twice produces -2 sibling ===============

    # Pre-create the first target file, then ask Sti-UniquePath for the next slot.
    $firstPath = Join-Path $TMP '2026-05-15T210800-review-queue-code-diffs-kanban-app-stride-batch.json'
    New-Item -ItemType File -Path $firstPath -Force | Out-Null
    $secondPath = Sti-UniquePath -Dir $TMP -Timestamp '2026-05-15T210800' `
        -Slug 'review-queue-code-diffs-kanban-app' -Artifact 'stride-batch' -Extension 'json'
    $expectedSecond = "$TMP/2026-05-15T210800-review-queue-code-diffs-kanban-app-stride-batch-2.json"
    if ($secondPath -ceq $expectedSecond) {
        Pass 'case 11: re-invoking --goal on same doc produces -2 sibling (AC7)'
    } else {
        Fail 'case 11: second-invocation path mismatch' "got=$secondPath want=$expectedSecond"
    }
    Remove-Item -Force $firstPath -ErrorAction SilentlyContinue

    # === case 12: seam literally named "1" — integer wins =====================

    $case12 = Sti-ResolveGoal -Path $seamNamedOne -GoalArg '1'
    $parts = $case12 -split "`t"
    if ($parts[0] -eq '1' -and $parts[1] -ceq 'Alpha') {
        Pass 'case 12: --goal 1 on doc with literal-1 seam → integer-index 1 wins (Alpha)'
    } else {
        Fail 'case 12: integer-vs-slug heuristic wrong' "idx=$($parts[0]) name=$($parts[1])"
    }

    # === case 13: multi-line item bodies — extractor uses first line only =====

    $case13Seams = @(Sti-ExtractSeams -Path $multilineBody)
    $case13Names = @($case13Seams | ForEach-Object { ($_ -split "`t")[1] }) -join '|'
    if ($case13Seams.Count -eq 3 -and $case13Names -ceq 'First|Second|Third') {
        Pass 'case 13: multi-line item bodies — extractor uses bold-name from first line only (parser robustness)'
    } else {
        Fail 'case 13: multi-line extraction wrong' "count=$($case13Seams.Count) names=$case13Names"
    }

    # === case 14: items missing **bold** are silently skipped =================

    $case14Seams = @(Sti-ExtractSeams -Path $missingBold)
    $case14Names = @($case14Seams | ForEach-Object { ($_ -split "`t")[1] }) -join '|'
    if ($case14Seams.Count -eq 2 -and $case14Names -ceq 'Valid|Also valid') {
        Pass 'case 14: items lacking **bold** are skipped (parser robustness)'
    } else {
        Fail 'case 14: missing-bold handling wrong' "count=$($case14Seams.Count) names=$case14Names"
    }

    # === case 15: prompt scoping — drops other surfaces, keeps matched ========

    $scopedLines = @(Sti-ScopeDocToSeam -Path $sevenSurfaces -Target 1)
    # Matched item present:
    if (@($scopedLines | Where-Object { $_ -match '^1\. \*\*Kanban app\*\*' }).Count -ge 1) {
        Pass 'case 15a: scoped prompt contains the matched item (Kanban app)'
    } else {
        Fail 'case 15a: scoped prompt missing matched item' (($scopedLines | Select-Object -Last 20) -join "`n")
    }
    # Other items absent:
    $otherItems = @($scopedLines | Where-Object { $_ -match '^[2-9]\. \*\*' })
    if ($otherItems.Count -gt 0) {
        Fail 'case 15b: scoped prompt still contains other surface items' ($otherItems -join "`n")
    } else {
        Pass 'case 15b: scoped prompt drops the other six surface items (AC5)'
    }
    # Sections outside seams are preserved:
    if (@($scopedLines | Where-Object { $_ -match '^## Assumptions' }).Count -ge 1) {
        Pass 'case 15c: scoped prompt preserves sections outside seams (## Assumptions still present)'
    } else {
        Fail 'case 15c: scoped prompt dropped a section outside seams'
    }
    # Section heading + scoping notice present:
    if (@($scopedLines | Where-Object { $_.Contains('**Scoped to a single surface for this dispatch.**') }).Count -ge 1) {
        Pass 'case 15d: scoped prompt includes the dispatch-scoping notice'
    } else {
        Fail 'case 15d: scoped prompt missing dispatch-scoping notice'
    }
} finally {
    Remove-Item -Recurse -Force $TMP -ErrorAction SilentlyContinue
}

Write-Host ''
Write-Host ("{0} passed, {1} failed" -f $script:PASS, $script:FAIL)
if ($script:FAIL -gt 0) { exit 1 } else { exit 0 }
