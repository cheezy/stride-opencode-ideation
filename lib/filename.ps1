# stride-ideation filename helpers (PowerShell mirror of filename.sh).
#
# Six pure functions used by the stride-ideation-ideate and
# stride-ideation-stridify skills to compute unique artifact paths,
# extract slugs, parse Decomposition seams, and scope a requirements
# doc to a single seam. PascalCase-with-hyphen cmdlet names mirror the
# snake_case bash functions one-to-one:
#
#   sti_slugify           -> Sti-Slugify
#   sti_slug_from_path    -> Sti-SlugFromPath
#   sti_extract_seams     -> Sti-ExtractSeams
#   sti_resolve_goal      -> Sti-ResolveGoal
#   sti_scope_doc_to_seam -> Sti-ScopeDocToSeam
#   sti_unique_path       -> Sti-UniquePath
#
# Slug rules: lowercase, dash-separated. Any character outside [a-z0-9-]
# is REPLACED with a dash (never deleted — preserves word boundaries).
# Leading/trailing dashes are trimmed; runs of dashes are collapsed.
#
# Filename rule: the HARD INVARIANT is "never overwrite an existing file."
# When a collision occurs the helper iterates the suffix counter starting
# at 2.
#
# Output goes to stdout via Write-Output. Errors are written via Write-Error
# and signaled by throwing or returning $null.
#
# Source via dot-sourcing:
#   . path\to\lib\filename.ps1
#   Sti-UniquePath docs/spec 2026-05-12T103000 foo requirements md

Set-StrictMode -Version Latest

function Sti-Slugify {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [AllowEmptyString()]
        [string]$InputText
    )
    if ([string]::IsNullOrEmpty($InputText)) {
        Write-Error "Sti-Slugify: empty input"
        return $null
    }
    $lowered = $InputText.ToLowerInvariant()
    # Replace anything outside [a-z0-9-] with a dash, collapse runs of dashes,
    # trim leading/trailing dashes.
    $replaced = [regex]::Replace($lowered, '[^a-z0-9-]+', '-')
    $replaced = [regex]::Replace($replaced, '-+', '-')
    $replaced = $replaced.Trim('-')
    if ([string]::IsNullOrEmpty($replaced)) {
        Write-Error "Sti-Slugify: slug normalized to empty string"
        return $null
    }
    return $replaced
}

function Sti-SlugFromPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)] [string]$Path,
        [Parameter(Mandatory = $true, Position = 1)] [string]$Artifact
    )
    # Extract the topic slug from a previously generated artifact path:
    #   <dir>/YYYY-MM-DDTHHMMSS-<slug>-<artifact>(-<N>)?.<ext>
    # Strips an optional `-N` collision discriminator so reruns inherit
    # the original slug.
    if ([string]::IsNullOrEmpty($Path) -or [string]::IsNullOrEmpty($Artifact)) {
        Write-Error "Sti-SlugFromPath: usage: Sti-SlugFromPath <path> <artifact>"
        return $null
    }
    $base = [System.IO.Path]::GetFileName($Path)
    # Strip the extension (last dot onward); matches bash `${base%.*}`.
    $stem = [System.IO.Path]::GetFileNameWithoutExtension($base)
    $artifactEscaped = [regex]::Escape($Artifact)
    $pattern = "^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{6}-(.+)-$artifactEscaped(-[0-9]+)?`$"
    $match = [regex]::Match($stem, $pattern)
    if (-not $match.Success) {
        Write-Error "Sti-SlugFromPath: path does not match the expected filename family for artifact '$Artifact': $Path"
        return $null
    }
    return $match.Groups[1].Value
}

function Sti-ExtractSeams {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)] [string]$Path
    )
    # Parse a requirements doc's "## Decomposition seams" section and emit
    # one line per surface in the form: <index>\t<name>\t<slug>
    # Multi-line item bodies are ignored — only the bold-name from the
    # item's first line yields a seam tuple.
    #
    # Exit codes / behavior (PowerShell mirror returns special sentinels via
    # exit-code semantics: callers should check $LASTEXITCODE after invocation):
    #   0  section present (possibly zero parseable items) — stdout has tuples
    #   1  I/O error / bad usage
    #   2  section absent
    if ([string]::IsNullOrEmpty($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        Write-Error "Sti-ExtractSeams: not a file: $Path"
        $global:LASTEXITCODE = 1
        return
    }
    $lines = @(Get-Content -LiteralPath $Path -Encoding UTF8)
    $sectionLineRegex = '^## Decomposition seams[ \t]*$'
    $sectionPresent = $lines | Where-Object { $_ -match $sectionLineRegex } | Select-Object -First 1
    if (-not $sectionPresent) {
        $global:LASTEXITCODE = 2
        return
    }
    $body = @()
    $inSection = $false
    foreach ($line in $lines) {
        if ($line -match $sectionLineRegex) { $inSection = $true; continue }
        if ($inSection -and $line -match '^## ') { $inSection = $false }
        if ($inSection) { $body += $line }
    }
    $itemPattern = '^[ \t]*[0-9]+\.[ \t]+\*\*([^*]+)\*\*'
    $idx = 0
    foreach ($line in $body) {
        $m = [regex]::Match($line, $itemPattern)
        if (-not $m.Success) { continue }
        $rawName = $m.Groups[1].Value
        $slug = Sti-Slugify -InputText $rawName -ErrorAction SilentlyContinue
        if (-not $slug) { continue }
        $idx++
        Write-Output ("{0}`t{1}`t{2}" -f $idx, $rawName, $slug)
    }
    $global:LASTEXITCODE = 0
}

function Sti-ResolveGoal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)] [string]$Path,
        [Parameter(Mandatory = $true, Position = 1)] [string]$GoalArg
    )
    # Resolve a user-supplied --goal value against the seams in a
    # requirements doc. Emits "<index>\t<name>\t<slug>" on match.
    #
    # Exit codes (via $LASTEXITCODE):
    #   0  match (tuple on stdout)
    #   1  bad usage
    #   2  section absent
    #   3  no match
    #   4  section present but empty
    if ([string]::IsNullOrEmpty($Path) -or [string]::IsNullOrEmpty($GoalArg)) {
        Write-Error "Sti-ResolveGoal: usage: Sti-ResolveGoal <markdown-path> <goal-arg>"
        $global:LASTEXITCODE = 1
        return
    }
    $seams = @(Sti-ExtractSeams -Path $Path)
    $extractRc = $LASTEXITCODE
    if ($extractRc -ne 0) {
        $global:LASTEXITCODE = $extractRc
        return
    }
    if ($seams.Count -eq 0) {
        $global:LASTEXITCODE = 4
        return
    }
    # If GoalArg is purely digits, try integer-index first.
    if ($GoalArg -match '^[0-9]+$') {
        foreach ($tuple in $seams) {
            $parts = $tuple -split "`t"
            if ($parts[0] -eq $GoalArg) {
                Write-Output $tuple
                $global:LASTEXITCODE = 0
                return
            }
        }
        # Fall through to slug-match (covers a seam literally named "1").
    }
    $argSlug = Sti-Slugify -InputText $GoalArg -ErrorAction SilentlyContinue
    if (-not $argSlug) {
        $global:LASTEXITCODE = 3
        return
    }
    foreach ($tuple in $seams) {
        $parts = $tuple -split "`t"
        if ($parts[2] -eq $argSlug) {
            Write-Output $tuple
            $global:LASTEXITCODE = 0
            return
        }
    }
    $global:LASTEXITCODE = 3
}

function Sti-ScopeDocToSeam {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)] [string]$Path,
        [Parameter(Mandatory = $true, Position = 1)] [int]$Target
    )
    # Rewrite a requirements doc to scope its "## Decomposition seams"
    # section to one surface. Emits the doc text on stdout with the
    # section body replaced by a one-line notice followed by the matched
    # item's verbatim lines.
    if ([string]::IsNullOrEmpty($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        Write-Error "Sti-ScopeDocToSeam: usage: Sti-ScopeDocToSeam <markdown-path> <seam-index>"
        $global:LASTEXITCODE = 1
        return
    }
    $lines = @(Get-Content -LiteralPath $Path -Encoding UTF8)
    $sectionLineRegex = '^## Decomposition seams[ \t]*$'
    $itemStartRegex = '^[ \t]*[0-9]+\.[ \t]+\*\*'

    $state = 0   # 0=before, 1=inside, 2=after
    $itemIdx = 0
    $collecting = $false
    foreach ($line in $lines) {
        switch ($state) {
            0 {
                if ($line -match $sectionLineRegex) {
                    Write-Output $line
                    Write-Output ''
                    Write-Output '**Scoped to a single surface for this dispatch.**'
                    Write-Output ''
                    $state = 1
                    break
                }
                Write-Output $line
                break
            }
            1 {
                if ($line -match '^## ') {
                    $state = 2
                    Write-Output ''
                    Write-Output $line
                    break
                }
                if ($line -match $itemStartRegex) {
                    $itemIdx++
                    $collecting = ($itemIdx -eq $Target)
                }
                if ($collecting) { Write-Output $line }
                break
            }
            2 {
                Write-Output $line
                break
            }
        }
    }
    $global:LASTEXITCODE = 0
}

function Sti-UniquePath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)] [string]$Dir,
        [Parameter(Mandatory = $true, Position = 1)] [string]$Timestamp,
        [Parameter(Mandatory = $true, Position = 2)] [string]$Slug,
        [Parameter(Mandatory = $true, Position = 3)] [string]$Artifact,
        [Parameter(Mandatory = $true, Position = 4)] [string]$Extension
    )
    if ([string]::IsNullOrEmpty($Dir) -or [string]::IsNullOrEmpty($Timestamp) -or
        [string]::IsNullOrEmpty($Slug) -or [string]::IsNullOrEmpty($Artifact) -or
        [string]::IsNullOrEmpty($Extension)) {
        Write-Error "Sti-UniquePath: usage: Sti-UniquePath <dir> <ts> <slug> <artifact> <ext>"
        $global:LASTEXITCODE = 1
        return
    }
    $dirTrimmed = $Dir.TrimEnd([char]'/', [char]'\')
    # Use forward-slash join to match the bash output exactly (skill bodies
    # and tests check for `<dir>/<ts>-...` literal substrings).
    $base = "$dirTrimmed/$Timestamp-$Slug-$Artifact"
    $candidate = "$base.$Extension"
    if (-not (Test-Path -LiteralPath $candidate)) {
        Write-Output $candidate
        $global:LASTEXITCODE = 0
        return
    }
    $n = 2
    while (Test-Path -LiteralPath "$base-$n.$Extension") {
        $n++
        if ($n -gt 1000) {
            Write-Error "Sti-UniquePath: refusing to scan past -1000 collisions"
            $global:LASTEXITCODE = 1
            return
        }
    }
    Write-Output "$base-$n.$Extension"
    $global:LASTEXITCODE = 0
}
