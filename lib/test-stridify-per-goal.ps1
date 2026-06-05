# PowerShell mirror of test-stridify-per-goal.sh — exercises the
# Sti-ResolveGoal, Sti-ExtractSeams, and Sti-ScopeDocToSeam cmdlets that
# the stride-ideation-stridify skill's --goal flow depends on.

Set-StrictMode -Version Latest

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $ScriptDir 'filename.ps1')

$script:PASS = 0
$script:FAIL = 0
function Pass($m) { $script:PASS++; Write-Host "  PASS  $m" }
function Fail($m, $d = '') { $script:FAIL++; Write-Host "  FAIL  $m"; if ($d) { Write-Host "        $d" } }

Write-Host 'test-stridify-per-goal.ps1 — exercises Sti-ResolveGoal + Sti-ExtractSeams + Sti-ScopeDocToSeam'
Write-Host ''

# Build a synthetic requirements doc with a Decomposition seams section.
$tmp = New-TemporaryFile
$docPath = "$($tmp.FullName).md"
Move-Item -LiteralPath $tmp.FullName -Destination $docPath
Set-Content -LiteralPath $docPath -Encoding UTF8 -Value @'
# Test doc

## Goal
A goal.

## Decomposition seams

The surfaces:

1. **Kanban app** — owns the JSON contract for the workflow
2. **stride plugin** — adapter for the Claude reference workflow
3. **stride-copilot** — adapter for GitHub Copilot

Shared notes:
- All three surfaces ship independently
- Coordination via SemVer

## Other section
Unaffected.
'@

try {
    # Stage 1: Sti-ExtractSeams emits 3 tuples in order.
    $seams = @(Sti-ExtractSeams -Path $docPath)
    if ($LASTEXITCODE -eq 0 -and $seams.Count -eq 3) {
        Pass "Sti-ExtractSeams emits 3 tuples"
    } else {
        Fail "Sti-ExtractSeams unexpected count" "rc=$LASTEXITCODE count=$($seams.Count)"
    }

    if ($seams.Count -ge 1 -and ($seams[0] -split "`t")[0] -eq '1') { Pass "first tuple has index 1" } else { Fail "first tuple index wrong" }
    if ($seams.Count -ge 1 -and ($seams[0] -split "`t")[2] -ceq 'kanban-app') { Pass "first tuple slug is 'kanban-app'" } else { Fail "first tuple slug wrong" "[$($seams[0])]" }
    if ($seams.Count -ge 3 -and ($seams[2] -split "`t")[2] -ceq 'stride-copilot') { Pass "third tuple slug is 'stride-copilot'" } else { Fail "third tuple slug wrong" }

    # Stage 2: Sti-ResolveGoal with digit input resolves by index.
    $r = Sti-ResolveGoal -Path $docPath -GoalArg '2'
    if ($LASTEXITCODE -eq 0 -and ($r -split "`t")[1] -ceq 'stride plugin') {
        Pass "digit '2' resolves to second seam"
    } else {
        Fail "digit resolution failed" "rc=$LASTEXITCODE r=[$r]"
    }

    # Stage 3: Sti-ResolveGoal with slug input resolves by slug.
    $r = Sti-ResolveGoal -Path $docPath -GoalArg 'stride-copilot'
    if ($LASTEXITCODE -eq 0 -and ($r -split "`t")[0] -eq '3') {
        Pass "slug 'stride-copilot' resolves to index 3"
    } else {
        Fail "slug resolution failed" "rc=$LASTEXITCODE r=[$r]"
    }

    # Stage 4: Sti-ResolveGoal with name input (will slugify) resolves.
    $r = Sti-ResolveGoal -Path $docPath -GoalArg 'Kanban app'
    if ($LASTEXITCODE -eq 0 -and ($r -split "`t")[0] -eq '1') {
        Pass "name 'Kanban app' resolves via slugify"
    } else {
        Fail "name slugify resolution failed" "rc=$LASTEXITCODE r=[$r]"
    }

    # Stage 5: No-match returns rc=3.
    $null = Sti-ResolveGoal -Path $docPath -GoalArg 'nonexistent'
    if ($LASTEXITCODE -eq 3) { Pass "no-match returns rc=3" } else { Fail "no-match should return 3" "rc=$LASTEXITCODE" }

    # Stage 6: Sti-ScopeDocToSeam keeps only the matched item in the seams section.
    $scoped = @(Sti-ScopeDocToSeam -Path $docPath -Target 2)
    $scopedText = $scoped -join "`n"
    if ($scopedText -match 'Scoped to a single surface') { Pass "scoped doc has scoped-notice line" } else { Fail "scoped notice missing" }
    if ($scopedText -match 'stride plugin') { Pass "scoped doc retains item 2" } else { Fail "scoped doc dropped target item" }
    # Other items should be absent.
    if ($scopedText -notmatch 'Kanban app' -and $scopedText -notmatch 'stride-copilot') {
        Pass "scoped doc drops non-target items"
    } else {
        Fail "scoped doc retained non-target items"
    }
    # Other sections preserved.
    if ($scopedText -match 'Other section') { Pass "scoped doc preserves other sections" } else { Fail "scoped doc dropped other sections" }

    # Stage 7: doc without Decomposition seams -> Sti-ExtractSeams rc=2.
    $noSeams = "$($docPath).noseams.md"
    Set-Content -LiteralPath $noSeams -Encoding UTF8 -Value "# foo`n## Goal`nA"
    $null = Sti-ExtractSeams -Path $noSeams
    if ($LASTEXITCODE -eq 2) { Pass "Sti-ExtractSeams returns rc=2 when section absent" } else { Fail "section-absent should return rc=2" "rc=$LASTEXITCODE" }
    Remove-Item -Force $noSeams -ErrorAction SilentlyContinue
} finally {
    Remove-Item -Force $docPath -ErrorAction SilentlyContinue
}

Write-Host ''
Write-Host ("{0} passed, {1} failed" -f $script:PASS, $script:FAIL)
if ($script:FAIL -gt 0) { exit 1 } else { exit 0 }
