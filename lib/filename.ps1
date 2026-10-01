# stride-ideation filename helpers (PowerShell mirror of filename.sh).
#
# Pure functions used by the /ideate and /stridify commands to compute
# unique artifact paths,
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

function Get-StiSeamCandidates {
    # Internal. Return one object (Line = 1-based doc line, Name) per seam item
    # start inside the "## Decomposition seams" section, in document order. The
    # whole section uses ONE item shape, chosen by precedence, exactly as
    # _sti_seam_candidates in filename.sh:
    #
    #   1. numbered bold items   ^ {0,3}<digits>.\s+**<Name>**...  (top level)
    #   2. top-level bulleted    ^[-*]\s+**<Name>**...   (only if no 1.)
    #   3. level-3 headings      ^###\s+<Name>            (only if no 1. or 2.)
    #
    # so a numbered list's secondary cross-cutting bullets are never seams.
    param([string[]]$Lines)
    $num = '^ {0,3}[0-9]+\.[ \t]+\*\*([^*]+)\*\*'
    $bul = '^[-*][ \t]+\*\*([^*]+)\*\*'
    $h3  = '^###[ \t]+(\S.*?)[ \t]*$'
    $section = @()
    $inSection = $false
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        if ($Lines[$i] -match '^## Decomposition seams[ \t]*$') { $inSection = $true; continue }
        if ($inSection -and $Lines[$i] -match '^## ') { $inSection = $false }
        if ($inSection) { $section += ,@(($i + 1), $Lines[$i]) }
    }
    $shape = $null
    foreach ($pair in $section) { if ($pair[1] -match $num) { $shape = $num; break } }
    if (-not $shape) { foreach ($pair in $section) { if ($pair[1] -match $bul) { $shape = $bul; break } } }
    if (-not $shape) { foreach ($pair in $section) { if ($pair[1] -match $h3) { $shape = $h3; break } } }
    if (-not $shape) { return }
    foreach ($pair in $section) {
        $m = [regex]::Match($pair[1], $shape)
        if ($m.Success) { [pscustomobject]@{ Line = $pair[0]; Name = $m.Groups[1].Value } }
    }
}

function Get-StiSeamItems {
    # Internal. The candidates above whose name slugifies, with the slug — the
    # ADDRESSABLE seams that both Sti-ExtractSeams and Sti-ScopeDocToSeam index.
    param([string[]]$Lines)
    foreach ($c in @(Get-StiSeamCandidates -Lines $Lines)) {
        $slug = Sti-Slugify -InputText $c.Name -ErrorAction SilentlyContinue
        if ($slug) { [pscustomobject]@{ Line = $c.Line; Name = $c.Name; Slug = $slug } }
    }
}

function Sti-ExtractSeams {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)] [string]$Path
    )
    # Parse a requirements doc's "## Decomposition seams" section and emit
    # one line per surface in the form: <index>\t<name>\t<slug>
    # Accepted item shapes (one per section, by precedence — see
    # Get-StiSeamCandidates): numbered `<N>. **Name**` items; else top-level
    # bulleted `- **Name**` items; else `### Name` headings. Multi-line item
    # bodies are ignored; names that do not slugify are skipped.
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
    $sectionPresent = $lines | Where-Object { $_ -match '^## Decomposition seams[ \t]*$' } | Select-Object -First 1
    if (-not $sectionPresent) {
        $global:LASTEXITCODE = 2
        return
    }
    $idx = 0
    foreach ($item in @(Get-StiSeamItems -Lines $lines)) {
        $idx++
        Write-Output ("{0}`t{1}`t{2}" -f $idx, $item.Name, $item.Slug)
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
    # If GoalArg is purely digits, try integer-index first. Compare as numbers,
    # as sti_resolve_goal's awk does, so '01' and '1' both select seam 1:
    # strip leading zeros rather than parse, so an arbitrarily long digit
    # string can never overflow.
    if ($GoalArg -match '^[0-9]+$') {
        $wantIndex = $GoalArg.TrimStart('0')
        if (-not $wantIndex) { $wantIndex = '0' }
        foreach ($tuple in $seams) {
            $parts = $tuple -split "`t"
            if ($parts[0] -eq $wantIndex) {
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

function Sti-GoalFields {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)] [string]$Tuple
    )
    # Split a Sti-ResolveGoal tuple ("<index>`t<name>`t<slug>") into three
    # KEY=value strings, in order: GOAL_INDEX=, GOAL_NAME=, GOAL_SLUG=.
    # Mirrors sti_goal_fields in filename.sh, which exists so the command
    # templates need no positional-field references that OpenCode's command
    # expansion would rewrite.
    #
    # Exit codes (via $LASTEXITCODE):
    #   0  three strings on the output stream
    #   1  bad usage — empty, not exactly three tab-separated fields, a
    #      non-numeric index, or an empty name or slug
    $parts = @()
    if (-not [string]::IsNullOrEmpty($Tuple)) { $parts = @($Tuple -split "`t") }
    if (($parts.Count -ne 3) -or ($parts[0] -notmatch '^[0-9]+$') -or
        [string]::IsNullOrEmpty($parts[1]) -or [string]::IsNullOrEmpty($parts[2])) {
        Write-Error "Sti-GoalFields: usage: Sti-GoalFields <index<TAB>name<TAB>slug>"
        $global:LASTEXITCODE = 1
        return
    }
    Write-Output ("GOAL_INDEX=" + $parts[0])
    Write-Output ("GOAL_NAME=" + $parts[1])
    Write-Output ("GOAL_SLUG=" + $parts[2])
    $global:LASTEXITCODE = 0
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
    # item's verbatim lines (start line + continuation lines until the next
    # item start or the section's end). <Target> is the index
    # Sti-ExtractSeams assigns: both read Get-StiSeamItems, so a resolved
    # --goal always scopes to the surface it named, whatever the item shape.
    if ([string]::IsNullOrEmpty($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        Write-Error "Sti-ScopeDocToSeam: usage: Sti-ScopeDocToSeam <markdown-path> <seam-index>"
        $global:LASTEXITCODE = 1
        return
    }
    $lines = @(Get-Content -LiteralPath $Path -Encoding UTF8)
    $items = @(Get-StiSeamItems -Lines $lines)
    $start = 0
    $end = 0
    if (($Target -ge 1) -and ($Target -le $items.Count)) {
        $start = $items[$Target - 1].Line
        foreach ($c in @(Get-StiSeamCandidates -Lines $lines)) {
            if ($c.Line -gt $start) { $end = $c.Line; break }
        }
    }
    $state = 0   # 0=before, 1=inside, 2=after
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        $nr = $i + 1
        if ($state -eq 0) {
            Write-Output $line
            if ($line -match '^## Decomposition seams[ \t]*$') {
                Write-Output ''
                Write-Output '**Scoped to a single surface for this dispatch.**'
                Write-Output ''
                $state = 1
            }
            continue
        }
        if ($state -eq 1) {
            if ($line -match '^## ') {
                $state = 2
                Write-Output ''
                Write-Output $line
                continue
            }
            if (($start -gt 0) -and ($nr -ge $start) -and (($end -eq 0) -or ($nr -lt $end))) { Write-Output $line }
            continue
        }
        Write-Output $line
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
