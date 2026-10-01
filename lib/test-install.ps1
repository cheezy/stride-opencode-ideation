# PowerShell mirror of test-install.sh — tests for install.ps1: source
# detection (local checkout vs. `irm | iex` vs. a user's project that merely
# looks like a bundle), the bundle-owned stride-ideation/ helper layout,
# legacy-file handling, -Global on a portable home directory, and the
# AGENTS.md managed block.
#
# No network: `git` is replaced by a PATH-prepended fake that counts its
# calls and "clones" by copying this checkout's bundle files into the target.
# Each install runs in a child pwsh with HOME/USERPROFILE pointed at a scratch
# directory.
#
# Run:
#   pwsh -NoProfile -File lib/test-install.ps1
#
# Exits 0 if all tests pass, non-zero otherwise.

Set-StrictMode -Version Latest

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Bundle    = Split-Path -Parent $ScriptDir
$Install   = Join-Path $Bundle 'install.ps1'
# $IsWindows does not exist on Windows PowerShell 5.1 (and StrictMode rejects
# an undefined variable), so ask the runtime directly.
$OnWindows = [System.Environment]::OSVersion.Platform -eq 'Win32NT'
$PwshExe   = (Get-Process -Id $PID).Path

$script:PASS = 0
$script:FAIL = 0
function Pass([string]$msg) { $script:PASS++; Write-Host "  PASS  $msg" }
function Fail([string]$msg, [string]$detail = '') {
    $script:FAIL++
    Write-Host "  FAIL  $msg"
    if ($detail) { Write-Host "        $detail" }
}
function Check([string]$name, [bool]$cond, [string]$detail = '') {
    if ($cond) { Pass $name } else { Fail $name $detail }
}
function J([string]$a, [string]$b) { Join-Path $a $b }   # two-arg only (PS 5.1)
function Lines([string]$path) { @(Get-Content -LiteralPath $path) }
function First-LineOf([string]$path, [string]$text) {
    $l = Lines $path
    for ($i = 0; $i -lt $l.Count; $i++) { if ($l[$i] -ceq $text) { return $i + 1 } }
    return 0
}
function Count-Lines([string]$path, [string]$text) {
    @(Lines $path | Where-Object { $_ -ceq $text }).Count
}

$BeginMarker = '<!-- BEGIN stride-ideation -->'
$EndMarker   = '<!-- END stride-ideation -->'

Write-Host 'test-install.ps1 — exercises install.ps1 source detection, layout and -Global'
Write-Host ''

# A space in every scratch path, so an unquoted expansion anywhere fails.
$Root = J ([System.IO.Path]::GetTempPath()) "sti-install-test-$([System.IO.Path]::GetRandomFileName())"
$Tmp  = J $Root 'install tests'
New-Item -ItemType Directory -Force -Path $Tmp | Out-Null

# --- fake git -----------------------------------------------------------------
$Bin = J $Tmp 'bin'
New-Item -ItemType Directory -Force -Path $Bin | Out-Null
@'
# Fake git for lib/test-install.ps1: records the call, then "clones" by
# copying $env:FAKE_GIT_SRC's bundle files into the last argument.
Add-Content -LiteralPath $env:FAKE_GIT_LOG -Value ($args -join ' ')
if ($args.Count -eq 0 -or $args[0] -ne 'clone') { exit 0 }
$dest = $args[$args.Count - 1]
New-Item -ItemType Directory -Force -Path $dest | Out-Null
foreach ($e in @('AGENTS.md', 'README.md', 'install.sh', 'install.ps1', 'commands', 'skills', 'agents', 'lib', 'fixtures')) {
    $p = Join-Path $env:FAKE_GIT_SRC $e
    if (Test-Path -LiteralPath $p) { Copy-Item -LiteralPath $p -Destination $dest -Recurse -Force }
}
exit 0
'@ | Set-Content -LiteralPath (J $Bin 'fakegit.ps1')
if ($OnWindows) {
    "@`"$PwshExe`" -NoProfile -File `"%~dp0fakegit.ps1`" %*" | Set-Content -LiteralPath (J $Bin 'git.cmd')
} else {
    "#!/bin/sh`nexec '$PwshExe' -NoProfile -File `"`$(dirname `"`$0`")/fakegit.ps1`" `"`$@`"" |
        Set-Content -LiteralPath (J $Bin 'git')
    & chmod +x (J $Bin 'git')
}

function Quote([string]$s) { "'" + $s.Replace("'", "''") + "'" }

# Run-Install <case> <local|piped> [-Global] [-Src <dir>] — runs install.ps1
# in a child pwsh from <case>/project. Sets $script:C/P/H/Out/Rc/GitLog.
function Run-Install([string]$Name, [string]$How, [switch]$Global, [string]$Src = $Bundle) {
    $script:C = J $Tmp $Name
    $script:P = J $C 'project'
    $script:H = J $C 'home'
    $script:GitLog = J $C 'git.log'
    New-Item -ItemType Directory -Force -Path $P, $H | Out-Null
    Set-Content -LiteralPath $GitLog -Value $null
    if ($How -eq 'piped') {
        # `irm .../install.ps1 | iex` — no script file, so no script directory.
        $cmd = 'Set-Location -LiteralPath ' + (Quote $P) + '; Invoke-Expression (Get-Content -Raw -LiteralPath ' + (Quote $Install) + ')'
    } else {
        $flag = ''
        if ($Global) { $flag = ' -Global' }
        $cmd = 'Set-Location -LiteralPath ' + (Quote $P) + '; & ' + (Quote $Install) + $flag
    }
    $saved = @{ PATH = $env:PATH; HOME = $env:HOME; USERPROFILE = $env:USERPROFILE }
    try {
        $env:PATH = $Bin + [System.IO.Path]::PathSeparator + $env:PATH
        $env:HOME = $H
        $env:USERPROFILE = $H
        $env:FAKE_GIT_LOG = $GitLog
        $env:FAKE_GIT_SRC = $Src
        $script:Out = (& $PwshExe -NoProfile -NonInteractive -Command $cmd 2>&1 | Out-String)
        $script:Rc = $LASTEXITCODE
    } finally {
        $env:PATH = $saved.PATH
        $env:HOME = $saved.HOME
        $env:USERPROFILE = $saved.USERPROFILE
        Remove-Item Env:FAKE_GIT_LOG, Env:FAKE_GIT_SRC -ErrorAction SilentlyContinue
    }
}
function Git-Calls { @(Get-Content -LiteralPath $script:GitLog | Where-Object { $_ }).Count }

function New-LookalikeProject([string]$dir) {
    New-Item -ItemType Directory -Force -Path (J (J $dir 'skills') 'my-own-skill'), (J $dir 'agents') | Out-Null
    Set-Content -LiteralPath (J $dir 'AGENTS.md') -Value "# My project notes`nKeep this line."
    Set-Content -LiteralPath (J (J (J $dir 'skills') 'my-own-skill') 'SKILL.md') -Value 'my skill'
    Set-Content -LiteralPath (J (J $dir 'agents') 'my-agent.md') -Value 'my agent'
    Set-Content -LiteralPath (J $dir '.stride_auth.md') -Value '- **API Token:** `not-a-real-token`'
}

try {
    # --- 1. irm | iex from a project with its own AGENTS.md and skills/ -------
    Write-Host 'Piped install (irm | iex) from a look-alike project'
    New-LookalikeProject (J (J $Tmp 'piped') 'project')
    Run-Install 'piped' 'piped'
    $oc = J $P '.opencode'
    Check 'piped: exits 0' ($Rc -eq 0) $Out
    Check 'piped: the bundle is cloned (git clone ran once)' ((Git-Calls) -eq 1) "calls=$(Git-Calls)"
    Check 'piped: /stridify command installed' (Test-Path (J (J $oc 'commands') 'stridify.md'))
    Check "piped: the user's own skill is NOT copied" (-not (Test-Path (J (J $oc 'skills') 'my-own-skill')))
    Check "piped: the user's own agent is NOT copied" (-not (Test-Path (J (J $oc 'agents') 'my-agent.md')))
    Check 'piped: helpers land in .opencode/stride-ideation/lib' (Test-Path (J (J (J $oc 'stride-ideation') 'lib') 'filename.sh'))
    Check 'piped: fixtures land in .opencode/stride-ideation/fixtures' (@(Get-ChildItem (J (J $oc 'stride-ideation') 'fixtures')).Count -gt 0)
    Check 'piped: nothing is written to the shared .opencode/lib' (-not (Test-Path (J $oc 'lib')))
    Check "piped: the user's AGENTS.md text stays OUTSIDE the managed block" (((Lines (J $P 'AGENTS.md'))[0..1] -join '|') -ceq '# My project notes|Keep this line.')
    Check 'piped: the managed block is appended after the user text' ((First-LineOf (J $P 'AGENTS.md') $BeginMarker) -gt 2)
    Check 'piped: .stride_auth.md is never copied' (@(Get-ChildItem -Recurse -Force $oc -Filter '.stride_auth.md').Count -eq 0)

    # --- 2. run from a local checkout ----------------------------------------
    Write-Host ''
    Write-Host 'Local install (./install.ps1) into a fresh project'
    Run-Install 'local' 'local'
    $oc = J $P '.opencode'
    $pkg = J $oc 'stride-ideation'
    Check 'local: exits 0' ($Rc -eq 0) $Out
    Check 'local: the checkout itself is the source (git never runs)' ((Git-Calls) -eq 0)
    Check 'local: commands installed' (Test-Path (J (J $oc 'commands') 'ideate.md'))
    Check 'local: helpers land in .opencode/stride-ideation/lib' (Test-Path (J (J $pkg 'lib') 'ship.sh'))
    Check 'local: fixtures stay a sibling of lib' (Test-Path -PathType Container (J $pkg 'fixtures'))
    Check 'local: AGENTS.md is created starting with the managed block' ((First-LineOf (J $P 'AGENTS.md') $BeginMarker) -eq 1)
    Check 'local: no legacy notice on a fresh install' (-not ($Out -match 'Note: an older install'))

    # --- 3. re-install is idempotent and preserves user content --------------
    Write-Host ''
    Write-Host 'Re-install over an existing install'
    Add-Content -LiteralPath (J $P 'AGENTS.md') -Value "`nMy note after the block."
    $before = Get-Content -Raw -LiteralPath (J $P 'AGENTS.md')
    $savedC = $C
    Run-Install 'local' 'local'
    Check 'reinstall: exits 0' ($Rc -eq 0) $Out
    Check 'reinstall: still exactly one BEGIN marker' ((Count-Lines (J $P 'AGENTS.md') $BeginMarker) -eq 1)
    Check 'reinstall: still exactly one END marker' ((Count-Lines (J $P 'AGENTS.md') $EndMarker) -eq 1)
    Check "reinstall: the user's note after the block survives" ((Count-Lines (J $P 'AGENTS.md') 'My note after the block.') -eq 1)
    Check 'reinstall: AGENTS.md is unchanged' ((Get-Content -Raw -LiteralPath (J $P 'AGENTS.md')) -ceq $before)

    # --- 4. legacy flat helpers are left alone and named once ----------------
    Write-Host ''
    Write-Host 'Legacy flat .opencode/lib from an older install'
    $legacyLib = J (J (J (J $Tmp 'legacy') 'project') '.opencode') 'lib'
    New-Item -ItemType Directory -Force -Path $legacyLib | Out-Null
    Set-Content -LiteralPath (J $legacyLib 'filename.sh') -Value 'legacy copy'
    Set-Content -LiteralPath (J $legacyLib 'sibling-bundle.sh') -Value 'sibling bundle file'
    Run-Install 'legacy' 'local'
    Check 'legacy: exits 0' ($Rc -eq 0) $Out
    Check 'legacy: the old .opencode/lib/filename.sh is untouched' ((Get-Content -Raw -LiteralPath (J $legacyLib 'filename.sh')).Trim() -ceq 'legacy copy')
    Check "legacy: a sibling bundle's file is untouched" ((Get-Content -Raw -LiteralPath (J $legacyLib 'sibling-bundle.sh')).Trim() -ceq 'sibling bundle file')
    Check 'legacy: one notice line is printed' (@($Out -split "`n" | Where-Object { $_ -match 'Note: an older install' }).Count -eq 1) $Out
    Check 'legacy: the notice names the leftover file' ($Out.Contains((J $legacyLib 'filename.sh')))
    Check "legacy: the notice does not name another bundle's file" (-not $Out.Contains('sibling-bundle.sh'))

    # --- 5. -Global builds the path from $HOME -------------------------------
    Write-Host ''
    Write-Host 'Global install (-Global) with HOME in a scratch dir'
    Run-Install 'global' 'local' -Global
    $g = J (J $H '.config') 'opencode'
    Check 'global: exits 0' ($Rc -eq 0) $Out
    Check 'global: commands under $HOME/.config/opencode' (Test-Path (J (J $g 'commands') 'stridify.md')) $Out
    Check 'global: helpers under $HOME/.config/opencode/stride-ideation/lib' (Test-Path (J (J (J $g 'stride-ideation') 'lib') 'filename.sh'))
    Check 'global: AGENTS.md at the config root' ((First-LineOf (J $g 'AGENTS.md') $BeginMarker) -ge 1)
    Check 'global: the current project is not touched' (-not (Test-Path (J $P '.opencode')) -and -not (Test-Path (J $P 'AGENTS.md')))
    Check 'global: no literal backslash path is created' (@(Get-ChildItem -Force $H | Where-Object { $_.Name -like '*\*' }).Count -eq 0)

    # --- 6. an orphaned BEGIN marker appends, never truncates ----------------
    Write-Host ''
    Write-Host 'AGENTS.md with an orphaned BEGIN marker'
    $orphanP = J (J $Tmp 'orphan') 'project'
    New-Item -ItemType Directory -Force -Path $orphanP | Out-Null
    Set-Content -LiteralPath (J $orphanP 'AGENTS.md') -Value "Before.`n$BeginMarker`nAfter the orphan."
    Run-Install 'orphan' 'local'
    $l = Lines (J $P 'AGENTS.md')
    Check 'orphan: exits 0' ($Rc -eq 0) $Out
    Check 'orphan: the original content is kept as a prefix' ((($l[0..2]) -join '|') -ceq "Before.|$BeginMarker|After the orphan.")
    Check 'orphan: the block is appended (END marker now present)' ((Count-Lines (J $P 'AGENTS.md') $EndMarker) -eq 1)

    # --- 7. a download that is not this bundle installs nothing --------------
    Write-Host ''
    Write-Host 'Piped install whose download is not the bundle'
    $impostor = J $Tmp 'notbundle-src'
    New-Item -ItemType Directory -Force -Path (J (J $impostor 'skills') 'x') | Out-Null
    Set-Content -LiteralPath (J $impostor 'AGENTS.md') -Value 'impostor'
    Run-Install 'notbundle' 'piped' -Src $impostor
    Check 'not-bundle: exits non-zero' ($Rc -ne 0) "rc=$Rc"
    Check 'not-bundle: says nothing was installed' ($Out -match 'nothing was installed') $Out
    Check 'not-bundle: no .opencode directory is created' (-not (Test-Path (J $P '.opencode')))
    Check 'not-bundle: no AGENTS.md is written' (-not (Test-Path (J $P 'AGENTS.md')))
} finally {
    Remove-Item -Recurse -Force -LiteralPath $Root -ErrorAction SilentlyContinue
}

Write-Host ''
Write-Host ("{0} passed, {1} failed" -f $script:PASS, $script:FAIL)
if ($script:FAIL -gt 0) { exit 1 }
exit 0
