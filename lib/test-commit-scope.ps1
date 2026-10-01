# PowerShell mirror of test-commit-scope.sh — checks that the commit
# fragments in /ideate (Step 9) and /stridify (Step 8d) commit ONLY the
# artifact they wrote, leaving a user's other staged work staged.
#
# The fragments are bash, so each is extracted from its command file and run
# with `bash --noprofile --norc -u` in a scratch repo that already has an
# unrelated file staged. Without bash on PATH the suite skips.
#
# Run:
#   pwsh -NoProfile -File lib/test-commit-scope.ps1
#
# Exits 0 if all tests pass, non-zero otherwise.

Set-StrictMode -Version Latest

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Bundle    = Split-Path -Parent $ScriptDir
$Commands  = Join-Path $Bundle 'commands'

$script:PASS = 0
$script:FAIL = 0
function Pass([string]$msg) { $script:PASS++; Write-Host "  PASS  $msg" }
function Fail([string]$msg, [string]$detail = '') {
    $script:FAIL++
    Write-Host "  FAIL  $msg"
    if ($detail) { Write-Host "        $detail" }
}
function Assert-Equal([string]$name, [string]$actual, [string]$expected) {
    if ($expected -ceq $actual) { Pass $name } else { Fail $name "got [$actual] want [$expected]" }
}

if (-not (Test-Path (Join-Path $Commands 'ideate.md'))) {
    Write-Host 'SKIP  commands/ not found beside lib/ (run this from a checkout)'
    Write-Host ''; Write-Host '0 passed, 0 failed'; exit 0
}
if (-not (Get-Command bash -ErrorAction SilentlyContinue)) {
    Write-Host 'SKIP  bash is not on PATH; the commit fragments are bash'
    Write-Host ''; Write-Host '0 passed, 0 failed'; exit 0
}

function Get-Fragment([string]$Path, [string]$Needle) {
    $blocks = @()
    $cur = $null
    foreach ($line in ([System.IO.File]::ReadAllText($Path) -split "`n")) {
        if (($null -eq $cur) -and ($line -match '^```bash\s*$')) { $cur = @() }
        elseif (($null -ne $cur) -and ($line.Trim() -eq '```')) { $blocks += ,($cur -join "`n"); $cur = $null }
        elseif ($null -ne $cur) { $cur += $line }
    }
    $hits = @($blocks | Where-Object { $_.Contains($Needle) })
    if ($hits.Count -ne 1) { return $null }
    return $hits[0]
}

function Quote([string]$s) { "'" + $s.Replace("'", "'\''") + "'" }
function J([string]$a, [string]$b) { Join-Path $a $b }

Write-Host 'test-commit-scope.ps1 — commit fragments commit only their artifact'

$tmpRoot = J ([System.IO.Path]::GetTempPath()) "sti-commit-$([System.IO.Path]::GetRandomFileName())"
$tmp = J $tmpRoot 'commit scope'
New-Item -ItemType Directory -Force -Path $tmp | Out-Null

function New-Repo([string]$Name) {
    $r = J $tmp $Name
    New-Item -ItemType Directory -Force -Path (J (J $r '.opencode') 'stride-ideation') | Out-Null
    & git -C $r init -q
    & git -C $r config user.email t@example.com
    & git -C $r config user.name tester
    Set-Content -LiteralPath (J $r 'README') -Value 'base'
    & git -C $r add README
    & git -C $r commit -q -m init
    Copy-Item -Recurse -LiteralPath (J $Bundle 'lib') -Destination (J (J (J $r '.opencode') 'stride-ideation') 'lib')
    Set-Content -LiteralPath (J $r 'userwork.txt') -Value 'secret-ish user work'
    & git -C $r add userwork.txt
    return $r
}

function Invoke-Fragment([string]$Repo, [string]$Fragment, [hashtable]$Carry) {
    $lines = @()
    foreach ($k in $Carry.Keys) { $lines += "$k=$(Quote $Carry[$k])" }
    $script = J $tmp 'run.sh'
    [System.IO.File]::WriteAllText($script, (($lines + $Fragment) -join "`n") + "`n")
    Push-Location -LiteralPath $Repo
    try {
        $script:Out = (& bash --noprofile --norc -u $script 2>&1 | Out-String)
        $script:Rc = $LASTEXITCODE
    } finally { Pop-Location }
}
function Committed([string]$Repo) { ((& git -C $Repo show --name-only --format= HEAD) -join "`n").Trim() }
function Staged([string]$Repo) { ((& git -C $Repo diff --cached --name-only) -join "`n").Trim() }

try {
    $ideate = Get-Fragment (J $Commands 'ideate.md') 'stride-ideation: requirements for'
    $stridify = Get-Fragment (J $Commands 'stridify.md') 'stride-ideation: decomposition for'
    if ($ideate -and $stridify) { Pass 'found the ideate Step 9 and stridify Step 8d fragments' }
    else { Fail 'found the ideate Step 9 and stridify Step 8d fragments'; throw 'done' }

    Write-Host ''
    Write-Host '/ideate Step 9 with unrelated work already staged'
    $r = New-Repo 'ideate'
    $doc = 'docs/ideation/2026-05-12T120000-dark-mode-requirements.md'
    New-Item -ItemType Directory -Force -Path (J (J $r 'docs') 'ideation') | Out-Null
    Set-Content -LiteralPath (J $r $doc) -Value '# Dark mode'
    Invoke-Fragment $r $ideate @{ TARGET_PATH = $doc; SLUG = 'dark-mode'; CONTINUE_PATH = ''; DRAFT_PATH = '.stride/none-draft.md' }
    Assert-Equal 'ideate: the commit succeeds' "$Rc" '0'
    Assert-Equal 'ideate: the commit contains only the doc' (Committed $r) $doc
    Assert-Equal "ideate: the user's staged file stays staged" (Staged $r) 'userwork.txt'

    Write-Host ''
    Write-Host '/ideate Step 9 in --continue mode'
    $r = New-Repo 'cont'
    $src = 'docs/ideation/2026-05-12T120000-dark-mode-requirements.md'
    $new = 'docs/ideation/2026-05-13T090000-dark-mode-requirements.md'
    New-Item -ItemType Directory -Force -Path (J (J $r 'docs') 'ideation') | Out-Null
    Set-Content -LiteralPath (J $r $src) -Value '# v1'
    & git -C $r add $src; & git -C $r commit -q -m v1 -- $src
    Set-Content -LiteralPath (J $r $src) -Value '# v1, edited by the user'
    & git -C $r add $src
    Set-Content -LiteralPath (J $r $new) -Value '# v2'
    Invoke-Fragment $r $ideate @{ TARGET_PATH = $new; SLUG = 'dark-mode'; CONTINUE_PATH = $src; DRAFT_PATH = '.stride/none-draft.md' }
    Assert-Equal 'continue: the commit succeeds' "$Rc" '0'
    Assert-Equal 'continue: the commit contains only the refined doc' (Committed $r) $new
    if ((Staged $r) -split "`n" -contains $src) { Pass 'continue: a staged edit to the source doc stays staged, uncommitted' }
    else { Fail 'continue: the source doc edit was swept in' }

    Write-Host ''
    Write-Host '/ideate Step 9 refuses a TARGET_PATH that is not a regular file'
    $r = New-Repo 'notfile'
    New-Item -ItemType Directory -Force -Path (J (J $r 'docs') 'ideation') | Out-Null
    Set-Content -LiteralPath (J (J (J $r 'docs') 'ideation') 'stray.md') -Value 'stray untracked notes'
    $headBefore = (& git -C $r rev-parse HEAD)
    Invoke-Fragment $r $ideate @{ TARGET_PATH = 'docs/ideation'; SLUG = 'x'; CONTINUE_PATH = ''; DRAFT_PATH = '.stride/none-draft.md' }
    Assert-Equal 'not-a-file: a directory TARGET_PATH stops the fragment' "$Rc" '1'
    Assert-Equal 'not-a-file: nothing is committed' (& git -C $r rev-parse HEAD) $headBefore

    Write-Host ''
    Write-Host '/stridify Step 8d with unrelated work already staged and spaces in the path'
    $r = New-Repo 'stridify'
    $batch = 'docs/my ideas/2026-05-12T120000-dark-mode-kanban-app-stride-batch.json'
    New-Item -ItemType Directory -Force -Path (J (J $r 'docs') 'my ideas') | Out-Null
    Set-Content -LiteralPath (J $r $batch) -Value '{"goals": []}'
    Invoke-Fragment $r $stridify @{ TARGET_PATH = $batch; SLUG = 'dark-mode'; GOAL_SLUG = 'kanban-app' }
    Assert-Equal 'stridify: the commit succeeds' "$Rc" '0'
    Assert-Equal 'stridify: the commit contains only the batch JSON' (Committed $r) $batch
    Assert-Equal "stridify: the user's staged file stays staged" (Staged $r) 'userwork.txt'

    Write-Host ''
    Write-Host '/stridify Step 8d with pathspec-magic characters in the path'
    if ([System.Environment]::OSVersion.Platform -eq 'Win32NT') {
        # Windows file names cannot contain '*'; test-commit-scope.sh covers it.
        Write-Host '  SKIP  a file name containing * cannot exist on Windows'
        throw 'done'
    }
    $r = New-Repo 'magic'
    $batch = 'docs/*-stride-batch.json'
    New-Item -ItemType Directory -Force -Path (J $r 'docs') | Out-Null
    [System.IO.File]::WriteAllText((J (J $r 'docs') '*-stride-batch.json'), "{`"goals`": []}`n")
    Set-Content -LiteralPath (J (J $r 'docs') 'decoy-stride-batch.json') -Value 'decoy'
    Invoke-Fragment $r $stridify @{ TARGET_PATH = $batch; SLUG = 'dark-mode'; GOAL_SLUG = '' }
    Assert-Equal 'magic: the commit succeeds' "$Rc" '0'
    Assert-Equal 'magic: a * in the path matches only that file' (Committed $r) $batch
} catch {
    if ("$_" -ne 'done') { Fail 'unexpected error' "$_" }
} finally {
    Remove-Item -Recurse -Force -LiteralPath $tmpRoot -ErrorAction SilentlyContinue
}

Write-Host ''
Write-Host ("{0} passed, {1} failed" -f $script:PASS, $script:FAIL)
if ($script:FAIL -gt 0) { exit 1 }
exit 0
