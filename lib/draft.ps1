# stride-ideation intra-session draft autosave helpers
# (PowerShell mirror of lib/draft.sh).
#
# Six pure cmdlets used by the /ideate command to persist an
# in-progress ideation draft to a gitignored scratch file under .stride/, so an
# interruption mid-session is recoverable and a later session can offer resume.
# PascalCase-with-hyphen cmdlet names mirror the snake_case bash functions
# one-to-one:
#
#   sti_draft_path   -> Sti-DraftPath
#   sti_draft_find   -> Sti-DraftFind
#   sti_draft_save   -> Sti-DraftSave
#   sti_draft_load   -> Sti-DraftLoad
#   sti_draft_exists -> Sti-DraftExists
#   sti_draft_clear  -> Sti-DraftClear
#
# Filename rule: the scratch path is <dir>/<ts>-<slug>-draft.md, pairing with
# the eventual requirements doc by its <ts>-<slug> prefix. The draft lives under
# a GITIGNORED .stride/ path so half-finished, possibly sensitive ideation is
# never committed; the helper never serializes any secret — it only writes the
# content it is handed.
#
# Resume keys on the SLUG, not the session timestamp: Sti-DraftFind matches
# every <ts>-<slug>-draft.md (any timestamp) and returns the latest (ISO
# timestamps sort lexically); the `-<slug>-draft.md` suffix is dash-delimited
# so `auth` never matches `oauth`.
#
# Happy-path output goes to stdout via Write-Output. Errors are written via
# Write-Error; value cmdlets return $null and find/save/load/clear set
# $global:LASTEXITCODE. Source via dot-sourcing:
#   . path\to\lib\draft.ps1
#   Sti-DraftPath .stride 2026-05-12T103000 foo

Set-StrictMode -Version Latest

function Sti-DraftPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)][AllowEmptyString()][string]$Dir,
        [Parameter(Mandatory = $true, Position = 1)][AllowEmptyString()][string]$Timestamp,
        [Parameter(Mandatory = $true, Position = 2)][AllowEmptyString()][string]$Slug
    )
    if ([string]::IsNullOrEmpty($Dir) -or [string]::IsNullOrEmpty($Timestamp) -or [string]::IsNullOrEmpty($Slug)) {
        Write-Error 'Sti-DraftPath: usage: Sti-DraftPath <dir> <ts> <slug>'
        return $null
    }
    $dirTrimmed = $Dir.TrimEnd([char]'/', [char]'\')
    # Forward-slash join to match the bash output exactly.
    Write-Output "$dirTrimmed/$Timestamp-$Slug-draft.md"
}

function Sti-DraftFind {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)][AllowEmptyString()][string]$Dir,
        [Parameter(Mandatory = $true, Position = 1)][AllowEmptyString()][string]$Slug
    )
    # Latest NON-EMPTY draft for <slug> under <dir>, any timestamp. Writes the
    # path to stdout and sets LASTEXITCODE 0; on miss / absent dir sets
    # LASTEXITCODE 1 and writes nothing. Empty draft files are ignored so a
    # zero-length scratch never triggers a resume offer.
    if ([string]::IsNullOrEmpty($Dir) -or [string]::IsNullOrEmpty($Slug)) {
        Write-Error 'Sti-DraftFind: usage: Sti-DraftFind <dir> <slug>'
        $global:LASTEXITCODE = 1
        return
    }
    if (-not (Test-Path -LiteralPath $Dir -PathType Container)) {
        $global:LASTEXITCODE = 1
        return
    }
    # The leading dash in the wildcard keeps slug `auth` from matching `oauth`.
    $candidates = @(
        Get-ChildItem -LiteralPath $Dir -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -like "*-$Slug-draft.md" -and $_.Length -gt 0 } |
            Sort-Object Name
    )
    if ($candidates.Count -eq 0) {
        $global:LASTEXITCODE = 1
        return
    }
    $dirTrimmed = $Dir.TrimEnd([char]'/', [char]'\')
    Write-Output "$dirTrimmed/$($candidates[-1].Name)"
    $global:LASTEXITCODE = 0
}

function Sti-DraftSave {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)][AllowEmptyString()][string]$Path,
        [Parameter(Mandatory = $true, Position = 1)][AllowEmptyString()][string]$Content
    )
    # Persist <content> to <path>, creating the parent dir. Only side effect is
    # writing that one file (and the mkdir of its dir).
    if ([string]::IsNullOrEmpty($Path)) {
        Write-Error 'Sti-DraftSave: usage: Sti-DraftSave <path> <content>'
        $global:LASTEXITCODE = 1
        return
    }
    $dir = Split-Path -Parent $Path
    try {
        if ($dir) { New-Item -ItemType Directory -Path $dir -Force -ErrorAction Stop | Out-Null }
        # -NoNewline mirrors bash `printf '%s'` (no trailing newline).
        Set-Content -LiteralPath $Path -Value $Content -NoNewline -Encoding UTF8 -ErrorAction Stop
        $global:LASTEXITCODE = 0
    } catch {
        Write-Error "Sti-DraftSave: cannot write scratch draft: $Path"
        $global:LASTEXITCODE = 1
    }
}

function Sti-DraftLoad {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)][AllowEmptyString()][string]$Path
    )
    # Emit the draft content at <path> to stdout. Errors if the file is absent.
    if ([string]::IsNullOrEmpty($Path)) {
        Write-Error 'Sti-DraftLoad: usage: Sti-DraftLoad <path>'
        $global:LASTEXITCODE = 1
        return $null
    }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        Write-Error "Sti-DraftLoad: no scratch draft at: $Path"
        $global:LASTEXITCODE = 1
        return $null
    }
    $content = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    $global:LASTEXITCODE = 0
    Write-Output $content
}

function Sti-DraftExists {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)][AllowEmptyString()][string]$Path
    )
    # Predicate: $true if <path> is an existing NON-EMPTY draft, else $false.
    # A zero-length scratch is treated as "no resumable draft".
    if ([string]::IsNullOrEmpty($Path)) {
        Write-Error 'Sti-DraftExists: usage: Sti-DraftExists <path>'
        return $false
    }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $false
    }
    return ((Get-Item -LiteralPath $Path).Length -gt 0)
}

function Sti-DraftClear {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)][AllowEmptyString()][string]$Path
    )
    # Remove the scratch draft at <path>. Idempotent: no error if already gone.
    if ([string]::IsNullOrEmpty($Path)) {
        Write-Error 'Sti-DraftClear: usage: Sti-DraftClear <path>'
        $global:LASTEXITCODE = 1
        return
    }
    Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    $global:LASTEXITCODE = 0
}
