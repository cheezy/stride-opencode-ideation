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
#   sti_scratch_dir  -> Sti-ScratchDir
#   sti_draft_save   -> Sti-DraftSave
#   sti_draft_load   -> Sti-DraftLoad
#   sti_draft_exists -> Sti-DraftExists
#   sti_draft_clear  -> Sti-DraftClear
#
# Filename rule: the scratch path is <dir>/<ts>-<slug>-draft.md, pairing with
# the eventual requirements doc by its <ts>-<slug> prefix. The draft lives under
# .stride/, which ignores itself (Sti-ScratchDir writes .stride/.gitignore
# containing '*' — the user's own .gitignore is never touched), so
# half-finished, possibly sensitive ideation is never committed; the helper
# never serializes any secret — it only writes the content it is handed.
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
    # Only offer a draft resuming can safely rewrite: never a symlink, and
    # inside a git work tree only one git ignores (a tracked or re-included
    # draft would carry the new prose into a commit).
    $inGit = $false
    if (Get-Command git -ErrorAction SilentlyContinue) {
        & git -C $Dir rev-parse --is-inside-work-tree 2>$null | Out-Null
        $inGit = ($LASTEXITCODE -eq 0)
    }
    $candidates = @(
        Get-ChildItem -LiteralPath $Dir -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -like "*-$Slug-draft.md" -and $_.Length -gt 0 -and -not $_.LinkType } |
            Where-Object {
                if (-not $inGit) { return $true }
                & git -C $Dir check-ignore -q -- $_.Name 2>$null
                return ($LASTEXITCODE -eq 0)
            } |
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

function Sti-ScratchDir {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)][AllowEmptyString()][string]$Dir,
        [Parameter(Position = 1)][string]$Name = '0000-00-00T000000-probe-draft.md'
    )
    # Inside a git work tree, refuse unless git ignores <dir>/<name> (an
    # existing .gitignore that re-includes drafts, or a tracked draft, would
    # otherwise let draft prose reach a commit).
    # Create the scratch directory <dir> if needed. When it is named .stride,
    # also write <dir>/.gitignore containing '*' if absent (an existing one is
    # left as it is), so drafts never show in `git status` — without editing the
    # user's own .gitignore. Any other name gets no .gitignore. A symlinked
    # <dir> is refused. Sets LASTEXITCODE.
    if ([string]::IsNullOrEmpty($Dir)) {
        Write-Error 'Sti-ScratchDir: usage: Sti-ScratchDir <dir> [<name>]'
        $global:LASTEXITCODE = 1
        return
    }
    if ($Name.Contains('/') -or $Name.Contains('\')) {
        Write-Error "Sti-ScratchDir: <name> must be a file name, not a path: $Name"
        $global:LASTEXITCODE = 1
        return
    }
    $d = $Dir.TrimEnd([char]'/', [char]'\')
    $item = Get-Item -LiteralPath $d -Force -ErrorAction SilentlyContinue
    if ($item -and $item.LinkType) {
        Write-Error "Sti-ScratchDir: refusing a symlinked scratch directory: $d"
        $global:LASTEXITCODE = 1
        return
    }
    try {
        New-Item -ItemType Directory -Path $d -Force -ErrorAction Stop | Out-Null
    } catch {
        Write-Error "Sti-ScratchDir: cannot create scratch directory: $d"
        $global:LASTEXITCODE = 1
        return
    }
    $ignore = Join-Path $d '.gitignore'
    # Get-Item -Force sees a dangling symlink that Test-Path reports as absent;
    # anything already at that path (file or link) is left alone, never written
    # through, so a planted link can never create a file outside .stride/.
    $existingIgnore = Get-Item -LiteralPath $ignore -Force -ErrorAction SilentlyContinue
    if (((Split-Path -Leaf $d) -ceq '.stride') -and -not $existingIgnore) {
        try {
            [System.IO.File]::WriteAllText((Resolve-StiPath $ignore), "*`n")
        } catch {
            Write-Error "Sti-ScratchDir: cannot write $ignore"
            $global:LASTEXITCODE = 1
            return
        }
    }
    if (Get-Command git -ErrorAction SilentlyContinue) {
        & git -C $d rev-parse --is-inside-work-tree 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0) {
            & git -C $d check-ignore -q -- $Name 2>$null
            if ($LASTEXITCODE -ne 0) {
                Write-Error "Sti-ScratchDir: git would not ignore $d/$Name (a .gitignore re-includes it, or it is already tracked); refusing to write a draft there"
                $global:LASTEXITCODE = 1
                return
            }
        }
    }
    $global:LASTEXITCODE = 0
}

function Resolve-StiPath([string]$P) {
    # .NET file APIs resolve relative paths against the process directory, not
    # PowerShell's current location; anchor them to the latter.
    if ([System.IO.Path]::IsPathRooted($P)) { return $P }
    return (Join-Path (Get-Location).Path $P)
}

function Sti-DraftSave {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)][AllowEmptyString()][string]$Path,
        [Parameter(Position = 1, ValueFromPipeline = $true)][AllowEmptyString()][AllowNull()][string]$Content
    )
    # Persist the draft to <path>, creating the parent dir via Sti-ScratchDir
    # (so a .stride/ parent ignores itself). The content is -Content when it is
    # given, else the pipeline (several piped strings are joined with "`n"),
    # else redirected stdin — written byte for byte, never re-quoted.
    begin { $parts = New-Object System.Collections.Generic.List[string] }
    process { if ($PSBoundParameters.ContainsKey('Content')) { $parts.Add([string]$Content) } }
    end {
        if ([string]::IsNullOrEmpty($Path)) {
            Write-Error 'Sti-DraftSave: usage: Sti-DraftSave <path> [<content>]  (content from the pipeline or stdin when omitted)'
            $global:LASTEXITCODE = 1
            return
        }
        if ($parts.Count -gt 0) { $text = $parts -join "`n" }
        elseif ([Console]::IsInputRedirected) { $text = [Console]::In.ReadToEnd() }
        else {
            # No content argument, no pipeline and an interactive stdin: a usage
            # error, never an empty draft (bash refuses a terminal stdin too).
            Write-Error 'Sti-DraftSave: no content given (pass it as an argument, or pipe it in)'
            $global:LASTEXITCODE = 1
            return
        }
        # Like bash's dirname, a parent-less path lives in '.', and the
        # fail-closed check runs for it too.
        $dir = Split-Path -Parent $Path
        if (-not $dir) { $dir = '.' }
        Sti-ScratchDir $dir (Split-Path -Leaf $Path)
        if ($LASTEXITCODE -ne 0) { return }
        try {
            # No BOM and no added newline, so bash and PowerShell write
            # identical files (mirrors bash `printf '%s'`).
            [System.IO.File]::WriteAllText((Resolve-StiPath $Path), $text, (New-Object System.Text.UTF8Encoding($false)))
            $global:LASTEXITCODE = 0
        } catch {
            Write-Error "Sti-DraftSave: cannot write scratch draft: $Path"
            $global:LASTEXITCODE = 1
        }
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
