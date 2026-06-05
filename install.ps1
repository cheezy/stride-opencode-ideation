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
        Copy-Item (Join-Path $Src $d '*') -Destination $dest -Recurse -Force
    }
    Copy-Item (Join-Path $Src 'AGENTS.md') -Destination (Join-Path $RootDir 'AGENTS.md') -Force
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
