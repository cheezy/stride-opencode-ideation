<#
.SYNOPSIS
    Install the Stride ideation bundle for OpenCode.

.DESCRIPTION
    Copies the skills, commands, agents, lib/ helpers, and fixtures into the
    OpenCode discovery paths, and AGENTS.md to the root. By default installs
    project-local into .\.opencode\ ; use -Global to install into
    $env:USERPROFILE\.config\opencode\ .

    There is NO plugin to install — ideation has no lifecycle hooks, so there
    is no "plugin" entry to add to opencode.json.

.PARAMETER Global
    Install into $env:USERPROFILE\.config\opencode\ instead of .\.opencode\ .

.PARAMETER Help
    Print usage information and exit.

.EXAMPLE
    .\install.ps1

    Installs project-local into .\.opencode\ .

.EXAMPLE
    .\install.ps1 -Global

    Installs into $env:USERPROFILE\.config\opencode\ .
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
    Write-Host '  (default)   Install project-local into .\.opencode\'
    Write-Host '  -Global     Install into $env:USERPROFILE\.config\opencode\'
    return
}

if ($Global) {
    $OcDir   = Join-Path $env:USERPROFILE '.config\opencode'
    $RootDir = $OcDir
    Write-Host 'Installing Stride Ideation for OpenCode into $env:USERPROFILE\.config\opencode\ (global)...'
} else {
    $OcDir   = Join-Path (Get-Location) '.opencode'
    $RootDir = (Get-Location).Path
    Write-Host 'Installing Stride Ideation for OpenCode into .opencode\ (project-local)...'
}

# Source: this script's directory if it already contains the bundle, else clone.
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Cleanup = $null
if ((Test-Path (Join-Path $ScriptDir 'AGENTS.md')) -and (Test-Path (Join-Path $ScriptDir 'skills'))) {
    $Src = $ScriptDir
} else {
    $Tmp = Join-Path ([System.IO.Path]::GetTempPath()) ([System.IO.Path]::GetRandomFileName())
    New-Item -ItemType Directory -Force -Path $Tmp | Out-Null
    $Cleanup = $Tmp
    Write-Host "Downloading from $Repo..."
    git clone --quiet --depth 1 $Repo (Join-Path $Tmp 'stride-opencode-ideation')
    $Src = Join-Path $Tmp 'stride-opencode-ideation'
}

try {
    foreach ($d in @('skills', 'commands', 'agents', 'lib', 'fixtures')) {
        $dest = Join-Path $OcDir $d
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
Write-Host 'There is NO plugin to register in opencode.json — ideation has no hooks.'
Write-Host ''
Write-Host 'Next steps:'
Write-Host '  1. Restart OpenCode so it discovers the new commands (/ideate, /stridify).'
Write-Host '  2. For /stridify: create .stride_auth.md in your project root with your'
Write-Host '     Stride API credentials (see the README) and add it to .gitignore.'
