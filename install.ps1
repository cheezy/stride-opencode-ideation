<#
.SYNOPSIS
    Install the Stride ideation bundle for OpenCode.

.DESCRIPTION
    Copies the skills, commands and agents into the OpenCode discovery paths,
    the lib/ helpers and fixtures into a bundle-owned stride-ideation/
    directory beside them, and AGENTS.md to the root. By default installs
    project-local into .opencode/ ; use -Global to install into
    ~/.config/opencode/ ($HOME, falling back to USERPROFILE).

    There is NO plugin to install — ideation has no lifecycle hooks, so there
    is no "plugin" entry to add to opencode.json.

.PARAMETER Global
    Install into ~/.config/opencode/ instead of .opencode/ .

.PARAMETER Help
    Print usage information and exit.

.EXAMPLE
    .\install.ps1

    Installs project-local into .\.opencode\ .

.EXAMPLE
    .\install.ps1 -Global

    Installs into ~/.config/opencode/ .
#>

[CmdletBinding()]
param(
    [switch]$Global,
    [switch]$Help
)

$ErrorActionPreference = 'Stop'

$Repo = 'https://github.com/cheezy/stride-opencode-ideation.git'

if ($Help) {
    Write-Host 'Usage: install.ps1 [-Global]'
    Write-Host ''
    Write-Host '  (default)   Install project-local into .opencode/'
    Write-Host '  -Global     Install into ~/.config/opencode/'
    return
}

if ($Global) {
    # $HOME is set by PowerShell on every platform (on Windows it equals
    # USERPROFILE); USERPROFILE alone is null on macOS and Linux pwsh. Build the
    # path from separate segments so no '\' separator is baked in.
    $UserHome = $HOME
    if (-not $UserHome) { $UserHome = $env:USERPROFILE }
    if (-not $UserHome) { throw 'install.ps1: cannot locate the home directory ($HOME and USERPROFILE are both empty).' }
    $OcDir   = Join-Path (Join-Path $UserHome '.config') 'opencode'
    $RootDir = $OcDir
    Write-Host "Installing Stride Ideation for OpenCode into $OcDir (global)..."
} else {
    $OcDir   = Join-Path (Get-Location) '.opencode'
    $RootDir = (Get-Location).Path
    Write-Host 'Installing Stride Ideation for OpenCode into .opencode\ (project-local)...'
}

# Source: this script's directory if it IS this bundle, else clone.
# Run as `irm ... | iex` there is no script file, so $PSCommandPath is empty
# and the clone path is taken. The current directory is never a candidate: a
# directory only counts as the bundle when it carries this bundle's own files,
# so a user's project with its own AGENTS.md and skills/ is never copied.
function Test-IdeationBundle([string]$Dir) {
    if (-not $Dir) { return $false }
    # Nested Join-Path: the three-argument form requires PowerShell 6+.
    return (Test-Path -PathType Leaf (Join-Path (Join-Path $Dir 'commands') 'stridify.md')) -and
           (Test-Path -PathType Leaf (Join-Path (Join-Path $Dir 'commands') 'ideate.md')) -and
           (Test-Path -PathType Leaf (Join-Path (Join-Path $Dir 'lib') 'filename.sh')) -and
           (Test-Path -PathType Leaf (Join-Path $Dir 'AGENTS.md')) -and
           (Test-Path -PathType Container (Join-Path $Dir 'skills'))
}
$ScriptDir = $null
if ($PSCommandPath) { $ScriptDir = Split-Path -Parent $PSCommandPath }
$Cleanup = $null
if (Test-IdeationBundle $ScriptDir) {
    $Src = $ScriptDir
} else {
    $Tmp = Join-Path ([System.IO.Path]::GetTempPath()) ([System.IO.Path]::GetRandomFileName())
    New-Item -ItemType Directory -Force -Path $Tmp | Out-Null
    $Cleanup = $Tmp
    Write-Host "Downloading from $Repo..."
    $Src = Join-Path $Tmp 'stride-opencode-ideation'
    git clone --quiet --depth 1 $Repo $Src
    if (-not (Test-IdeationBundle $Src)) {
        Remove-Item -Recurse -Force $Cleanup
        throw "install.ps1: the download from $Repo is not a stride-opencode-ideation bundle; nothing was installed."
    }
}

# lib/ and fixtures/ go to a bundle-owned directory, so the commands have one
# stable path to call them by and the sibling Stride OpenCode bundles, which
# share .opencode/lib and .opencode/fixtures, are never touched. They stay
# siblings: lib/run_smoke_test.* finds its fixture through ../fixtures.
$PkgDir = Join-Path $OcDir 'stride-ideation'
$Legacy = @()

try {
    foreach ($d in @('skills', 'commands', 'agents', 'lib', 'fixtures')) {
        if (($d -eq 'lib') -or ($d -eq 'fixtures')) {
            $dest = Join-Path $PkgDir $d
            # Older installs copied these flat into the shared directory. Leave
            # them exactly where they are; name them once below.
            foreach ($f in (Get-ChildItem -Force (Join-Path $Src $d))) {
                $old = Join-Path (Join-Path $OcDir $d) $f.Name
                if (Test-Path $old) { $Legacy += $old }
            }
        } else {
            $dest = Join-Path $OcDir $d
        }
        New-Item -ItemType Directory -Force -Path $dest | Out-Null
        # Nested Join-Path: the three-argument form requires PowerShell 6+;
        # nesting keeps this runnable on stock Windows PowerShell 5.1.
        Copy-Item (Join-Path (Join-Path $Src $d) '*') -Destination $dest -Recurse -Force
    }
    # AGENTS.md orients the main agent. Preserve any existing user-authored file
    # by confining our content to an idempotent, clearly delimited managed block:
    # a fresh file gets the block; an existing file keeps ALL of its content and
    # only the block is inserted or refreshed in place (never clobbered, never
    # duplicated). Mirrors the install.sh logic exactly.
    $DestAgents  = Join-Path $RootDir 'AGENTS.md'
    $BeginMarker = '<!-- BEGIN stride-ideation -->'
    $EndMarker   = '<!-- END stride-ideation -->'
    $NoteMarker  = '<!-- Managed by the stride-opencode-ideation installer; content between these markers is regenerated on each install. Add your own notes outside this block. -->'
    $Bundle      = (Get-Content -Raw (Join-Path $Src 'AGENTS.md')).TrimEnd("`r", "`n")
    $Block       = $BeginMarker + "`n" + $NoteMarker + "`n" + $Bundle + "`n" + $EndMarker

    if (-not (Test-Path $DestAgents)) {
        Set-Content -Path $DestAgents -Value ($Block + "`n") -NoNewline
    } else {
        # Read as plain text; never evaluate or source the destination contents.
        $Existing = Get-Content -Raw $DestAgents
        # Locate a WELL-FORMED managed block: the first LINE that is exactly the
        # BEGIN marker and the first LINE that is exactly the END marker, where
        # END follows BEGIN. Whole-line matching mirrors install.sh's
        # `grep -nxF` semantics: marker text embedded mid-line in user prose is
        # NOT a block boundary and must never trigger an in-place refresh
        # (which could truncate user content). Anything ambiguous falls through
        # to the append path. (One known edge: a CRLF-ended marker line matches
        # here but not in install.sh, which appends instead — both outcomes
        # still preserve user content.)
        $lines = $Existing -split "`r?`n"
        $beginLine = -1
        $endLine   = -1
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if (($beginLine -lt 0) -and ($lines[$i] -ceq $BeginMarker)) { $beginLine = $i }
            if (($endLine -lt 0) -and ($lines[$i] -ceq $EndMarker)) { $endLine = $i }
        }
        if (($beginLine -ge 0) -and ($endLine -gt $beginLine)) {
            # Refresh the existing managed block in place (marker lines inclusive).
            $before = @()
            if ($beginLine -gt 0) { $before = $lines[0..($beginLine - 1)] }
            $after = @()
            if ($endLine -lt ($lines.Count - 1)) { $after = $lines[($endLine + 1)..($lines.Count - 1)] }
            $newLines = @($before) + ($Block -split "`n") + @($after)
            Set-Content -Path $DestAgents -Value (($newLines -join "`n")) -NoNewline
        } else {
            # Existing user file with no well-formed managed block (including an
            # orphaned BEGIN with no END after it): append, preserving content.
            $sep = if ($Existing.EndsWith("`n")) { "`n" } else { "`n`n" }
            Add-Content -Path $DestAgents -Value ($sep + $Block + "`n") -NoNewline
        }
    }
} finally {
    if ($Cleanup) { Remove-Item -Recurse -Force $Cleanup }
}

Write-Host ''
Write-Host "Stride Ideation for OpenCode installed into $OcDir"
Write-Host "Helpers and fixtures: $PkgDir"
Write-Host 'There is NO plugin to register in opencode.json — ideation has no hooks.'
if ($Legacy.Count -gt 0) {
    Write-Host ("Note: an older install left these stride-ideation files in the shared lib/ and fixtures/ (no longer used, left in place; remove them if no other bundle needs them): " + ($Legacy -join ', '))
}
Write-Host ''
Write-Host 'Next steps:'
Write-Host '  1. Restart OpenCode so it discovers the new commands (/ideate, /stridify).'
Write-Host '  2. For /stridify: create .stride_auth.md in your project root with your'
Write-Host '     Stride API credentials (see the README) and add it to .gitignore.'
