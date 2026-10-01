# PowerShell mirror of test-check-sections.sh — tests for lib/check_sections.py,
# the /stridify Step 2.3 gate that every requirements doc carries the seven
# hard-gated sections. Same cases, same labels, same order.
#
# Run:
#   pwsh -NoProfile -File lib/test-check-sections.ps1
#
# Exits 0 if all tests pass, non-zero otherwise.

Set-StrictMode -Version Latest

$ScriptDir  = Split-Path -Parent $MyInvocation.MyCommand.Path
$PluginRoot = Split-Path -Parent $ScriptDir
$Check      = Join-Path $ScriptDir 'check_sections.py'
$Python     = if (Get-Command python3 -ErrorAction SilentlyContinue) { 'python3' } else { 'python' }

$script:PASS = 0
$script:FAIL = 0
function Pass([string]$msg) { $script:PASS++; Write-Host "  PASS  $msg" }
function Fail([string]$msg, [string]$detail = '') {
    $script:FAIL++
    Write-Host "  FAIL  $msg"
    if ($detail) { Write-Host "        $detail" }
}

$tmp = Join-Path ([System.IO.Path]::GetTempPath()) "sti-sections-$([System.IO.Path]::GetRandomFileName())"
New-Item -ItemType Directory -Path $tmp | Out-Null

# Invoke-Check <doc> — sets $script:Rc, $script:Out, $script:Err.
function Invoke-Check([string]$Doc) {
    $errFile = Join-Path $tmp 'err'
    $script:Out = ((& $Python $Check $Doc 2> $errFile) | Out-String).Trim()
    $script:Rc = $LASTEXITCODE
    $script:Err = ([System.IO.File]::ReadAllText($errFile)).Trim()
}
function Assert-Ok([string]$Label, [string]$Doc) {
    Invoke-Check $Doc
    if (($Rc -eq 0) -and -not "$Out$Err") { Pass $Label } else { Fail $Label "rc=$Rc out=$Out err=$Err" }
}
function Assert-Missing([string]$Label, [string]$Doc, [string]$Want) {
    Invoke-Check $Doc
    $expected = "stride-ideation: requirements doc is missing required section(s): $Want"
    if (($Rc -eq 1) -and ($Err -ceq $expected)) { Pass $Label } else { Fail $Label "rc=$Rc err=$Err" }
}
# New-Doc <file> <heading>... — a doc with one level-2 heading per argument.
function New-Doc([string]$File, [string[]]$Headings) {
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append("# Topic`n`n")
    foreach ($h in $Headings) { [void]$sb.Append("## $h`n`nbody`n`n") }
    [System.IO.File]::WriteAllText($File, $sb.ToString())
}
function J([string]$name) { Join-Path $tmp $name }

try {
    # --- all seven present -----------------------------------------------------
    New-Doc (J 'template.md') @('Problem', 'Goal', 'Success metrics', 'Assumptions', 'Constraints', 'Non-goals', 'Outcome')
    Assert-Ok "all seven (template spelling 'Success metrics') pass with no output" (J 'template.md')

    New-Doc (J 'titlecase.md') @('Goal', 'Problem', 'Outcome', 'Assumptions', 'Constraints', 'Non-Goals', 'Success Metrics')
    Assert-Ok "title-case 'Success Metrics' / 'Non-Goals' pass (case-insensitive)" (J 'titlecase.md')

    New-Doc (J 'trailing.md') @('Problem  ', "Goal`t", 'Outcome', 'Assumptions', 'Constraints', 'Non-goals', 'Success metrics   ')
    Assert-Ok 'headings with trailing spaces or tabs pass' (J 'trailing.md')

    foreach ($f in (Get-ChildItem -LiteralPath (Join-Path $PluginRoot 'fixtures') -Filter '*-requirements.md' | Sort-Object Name)) {
        Assert-Ok "fixture passes: $($f.Name)" $f.FullName
    }

    # --- missing sections ------------------------------------------------------
    New-Doc (J 'missing-two.md') @('Problem', 'Goal', 'Assumptions', 'Constraints', 'Non-goals')
    Assert-Missing 'lists every missing section, in canonical order' (J 'missing-two.md') 'Outcome, Success metrics'

    New-Doc (J 'none.md') @()
    Assert-Missing 'an empty doc lists all seven' (J 'none.md') 'Problem, Goal, Outcome, Assumptions, Constraints, Non-goals, Success metrics'

    $six = @('Problem', 'Goal', 'Outcome', 'Assumptions', 'Constraints', 'Non-goals')
    $body = "# Topic`n`n" + (($six | ForEach-Object { "## $_`n`nx`n`n" }) -join '') + "### Success metrics`n`nx`n"
    [System.IO.File]::WriteAllText((J 'h3.md'), $body)
    Assert-Missing 'a level-3 heading does not satisfy a section' (J 'h3.md') 'Success metrics'

    $five = @('Problem', 'Goal', 'Outcome', 'Assumptions', 'Constraints')
    $body = "# Topic`n`n" + (($five | ForEach-Object { "## $_`n`nx`n`n" }) -join '') + "``````markdown`n## Non-goals`n```````n`n~~~`n## Success metrics`n~~~`n"
    [System.IO.File]::WriteAllText((J 'fenced.md'), $body)
    Assert-Missing 'headings inside code fences do not count' (J 'fenced.md') 'Non-goals, Success metrics'

    $body = "# Topic`n`n" + (($six | ForEach-Object { "## $_`n`nx`n`n" }) -join '') + "````````markdown`nexample:`n```````n## Success metrics`n```````n`````````n"
    [System.IO.File]::WriteAllText((J 'nested-fence.md'), $body)
    Assert-Missing 'a heading inside a nested fence does not count' (J 'nested-fence.md') 'Success metrics'

    $body = "# Topic`n`nOur Success metrics are below. Non-goals: none.`n`n" + (($five | ForEach-Object { "## $_`n`nx`n`n" }) -join '')
    [System.IO.File]::WriteAllText((J 'prose.md'), $body)
    Assert-Missing 'a section name in prose is not a heading' (J 'prose.md') 'Non-goals, Success metrics'

    # --- usage and I/O ---------------------------------------------------------
    & $Python $Check 2>$null | Out-Null
    if ($LASTEXITCODE -eq 2) { Pass 'no argument is a usage error (exit 2)' } else { Fail 'usage exit code' "rc=$LASTEXITCODE" }

    Invoke-Check (J 'does-not-exist.md')
    if (($Rc -eq 1) -and $Err.StartsWith('stride-ideation: could not read')) { Pass 'an unreadable path exits 1 with a stride-ideation: message' }
    else { Fail 'unreadable path' "rc=$Rc err=$Err" }

    $before = [System.IO.File]::ReadAllBytes((J 'missing-two.md'))
    Invoke-Check (J 'missing-two.md')
    $after = [System.IO.File]::ReadAllBytes((J 'missing-two.md'))
    if ([System.Linq.Enumerable]::SequenceEqual($before, $after)) { Pass 'the doc is never modified' } else { Fail 'the doc was modified' }
} finally {
    Remove-Item -Recurse -Force -LiteralPath $tmp -ErrorAction SilentlyContinue
}

Write-Host ''
Write-Host ("{0} passed, {1} failed" -f $script:PASS, $script:FAIL)
if ($script:FAIL -gt 0) { exit 1 }
exit 0
