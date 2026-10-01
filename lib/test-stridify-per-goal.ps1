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

    # === cases 16-22: one seam definition for count, resolve and scope ======

    function New-SeamsDoc([string]$Name, [string]$Body) {
        $f = Join-Path $TMP $Name
        $text = "# Doc`n`n## Problem`n`np`n`n## Decomposition seams`n`nIntro prose.`n`n" + $Body + "`n## Assumptions`n`na`n"
        [System.IO.File]::WriteAllText($f, $text)
        return $f
    }
    function Get-SeamNames([string]$f) { ((@(Sti-ExtractSeams -Path $f) | ForEach-Object { ($_ -split "`t")[1] }) -join '|') + '|' }
    function Get-SeamCount([string]$f) { @(Sti-ExtractSeams -Path $f).Count }
    # The Step 2 advisory's count, computed exactly as commands/stridify.md does.
    function Get-AdvisoryCount([string]$f) { @(Sti-ExtractSeams -Path $f).Count }
    function Get-Field([string]$tuple, [int]$n) { if ($tuple) { ($tuple -split "`t")[$n] } else { '' } }

    $bulleted = New-SeamsDoc 'bulleted.md' @"
- **Kanban app** — owns the JSON contract
- **stride plugin** — adapter
  - nested note that is not a seam
- **stride-copilot** — port
* **Docs site** — guides

"@
    if (((Get-SeamCount $bulleted) -eq 4) -and ((Get-SeamNames $bulleted) -ceq 'Kanban app|stride plugin|stride-copilot|Docs site|')) {
        Pass 'case 16a: four bulleted bold seams are extracted (nested bullets are not seams)'
    } else { Fail 'case 16a: bulleted extraction' "count=$(Get-SeamCount $bulleted) names=$(Get-SeamNames $bulleted)" }
    $case16ok = $true
    foreach ($i in 1..4) { Sti-ResolveGoal -Path $bulleted -GoalArg "$i" | Out-Null; if ($LASTEXITCODE -ne 0) { $case16ok = $false } }
    if ($case16ok -and ((Get-AdvisoryCount $bulleted) -eq 4)) { Pass 'case 16b: the advisory counts 4 and --goal 1..4 all resolve (rc 0)' }
    else { Fail 'case 16b: advisory and resolver disagree on bulleted seams' }
    $scoped16 = @(Sti-ScopeDocToSeam -Path $bulleted -Target 2)
    if (($scoped16 -contains '- **stride plugin** — adapter') -and ($scoped16 -contains '  - nested note that is not a seam') -and
        -not ($scoped16 | Where-Object { $_ -match '\*\*(Kanban app|stride-copilot|Docs site)\*\*' }) -and
        ($scoped16 | Where-Object { $_ -match '^## Assumptions' })) {
        Pass 'case 16c: scoping a bulleted doc to item 2 keeps only that item (with its nested lines)'
    } else { Fail 'case 16c: bulleted scoping' ($scoped16 -join ' / ') }

    $headings = New-SeamsDoc 'headings.md' @"
### Kanban app

Owns the JSON contract.

#### Detail that stays with the item

### stride plugin

Adapter.

"@
    if ((Get-SeamNames $headings) -ceq 'Kanban app|stride plugin|') { Pass 'case 17a: ### headings are seams when there are no bold items (#### is not)' }
    else { Fail 'case 17a: heading extraction' "names=$(Get-SeamNames $headings)" }
    $case17idx = Get-Field (Sti-ResolveGoal -Path $headings -GoalArg '2') 1
    $case17slug = Get-Field (Sti-ResolveGoal -Path $headings -GoalArg 'kanban-app') 0
    if (($case17idx -ceq 'stride plugin') -and ($case17slug -eq '1')) { Pass 'case 17b: heading seams resolve by index and by slug' }
    else { Fail 'case 17b: heading resolution' "idx2=$case17idx slug->$case17slug" }
    $scoped17 = @(Sti-ScopeDocToSeam -Path $headings -Target 1)
    if (($scoped17 -contains '#### Detail that stays with the item') -and -not ($scoped17 -contains '### stride plugin')) {
        Pass 'case 17c: scoping a heading doc keeps the item and its sub-headings only'
    } else { Fail 'case 17c: heading scoping' ($scoped17 -join ' / ') }

    $mixed = New-SeamsDoc 'mixed.md' @"
1. **Kanban app** — contract
2. **stride plugin** — adapter
3. **stride-copilot** — port

Shared contract:
- **JSON schema** — cross-cutting
- **Auth** — cross-cutting
- **Versioning** — cross-cutting
- **Telemetry** — cross-cutting
- **Docs** — cross-cutting

"@
    if (((Get-AdvisoryCount $mixed) -eq 3) -and ((Get-SeamNames $mixed) -ceq 'Kanban app|stride plugin|stride-copilot|')) {
        Pass "case 18: a numbered list's secondary bullets are not counted as seams (advisory stays quiet at 3)"
    } else { Fail 'case 18: mixed numbered + bullets' "count=$(Get-AdvisoryCount $mixed) names=$(Get-SeamNames $mixed)" }

    $dashName = New-SeamsDoc 'dash-name.md' @"
- **front-end — web** — the UI
- **back-end** — the API

"@
    if ((Get-Field (Sti-ResolveGoal -Path $dashName -GoalArg '1') 1) -ceq 'front-end — web') { Pass 'case 19: a bold name containing dashes is kept verbatim' }
    else { Fail 'case 19: dashed name' (Sti-ResolveGoal -Path $dashName -GoalArg '1') }

    $emptySection = New-SeamsDoc 'empty-section.md' ''
    Sti-ResolveGoal -Path $emptySection -GoalArg '1' | Out-Null
    $case20rc = $LASTEXITCODE
    if (($case20rc -eq 4) -and ((Get-AdvisoryCount $emptySection) -eq 0)) { Pass 'case 20: an empty seams section counts 0 and resolves rc 4 (contract unchanged)' }
    else { Fail 'case 20: empty section' "rc=$case20rc" }

    $skew = New-SeamsDoc 'skew.md' @"
1. **???** — not addressable
2. **Real** — the only real surface

"@
    $case21name = Get-Field (Sti-ResolveGoal -Path $skew -GoalArg '1') 1
    $scoped21 = @(Sti-ScopeDocToSeam -Path $skew -Target 1)
    if (($case21name -ceq 'Real') -and ($scoped21 | Where-Object { $_.Contains('2. **Real**') }) -and -not ($scoped21 | Where-Object { $_.Contains('**???**') })) {
        Pass "case 21: scoping uses the resolver's index (an unaddressable item does not shift it)"
    } else { Fail 'case 21: index skew' "resolved=$case21name scoped=$($scoped21 -join ' / ')" }

    $nestedSteps = New-SeamsDoc 'nested-steps.md' @"
- **Kanban app** — owns the contract
    1. **Schema** — a step, not a seam
    2. **Migration** — a step, not a seam
- **stride plugin** — adapter

"@
    Sti-ResolveGoal -Path $nestedSteps -GoalArg 'stride plugin' | Out-Null
    if (((Get-SeamNames $nestedSteps) -ceq 'Kanban app|stride plugin|') -and ($LASTEXITCODE -eq 0)) {
        Pass 'case 23: a nested numbered sub-list under bulleted seams does not take over the section'
    } else { Fail 'case 23: nested numbered steps' "names=$(Get-SeamNames $nestedSteps)" }

    $case22ok = $true
    foreach ($doc in @($sevenSurfaces, $bulleted, $headings, $mixed, $dashName)) {
        foreach ($tuple in @(Sti-ExtractSeams -Path $doc)) {
            $parts = $tuple -split "`t"
            $text = (@(Sti-ScopeDocToSeam -Path $doc -Target ([int]$parts[0])) -join "`n")
            if (-not $text.Contains($parts[1])) { $case22ok = $false; Fail "case 22: $(Split-Path -Leaf $doc) index $($parts[0]) does not scope to '$($parts[1])'" }
        }
    }
    if ($case22ok) { Pass 'case 22: for every shape, each extracted index scopes to the seam it names' }
} finally {
    Remove-Item -Recurse -Force $TMP -ErrorAction SilentlyContinue
}

Write-Host ''
Write-Host ("{0} passed, {1} failed" -f $script:PASS, $script:FAIL)
if ($script:FAIL -gt 0) { exit 1 } else { exit 0 }
