# PowerShell mirror of test-filename.sh — smoke tests for filename.ps1
# cmdlets. Verifies the same slugify rules + unique-path collision logic
# the bash version covers, against the same inputs.

Set-StrictMode -Version Latest

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $ScriptDir 'filename.ps1')

$script:PASS = 0
$script:FAIL = 0

function Pass([string]$msg) { $script:PASS++; Write-Host "  PASS  $msg" }
function Fail([string]$msg, [string]$detail = '') {
    $script:FAIL++
    Write-Host "  FAIL  $msg"
    if ($detail) { Write-Host "        $detail" }
}

function Assert-Equal([string]$name, [string]$expected, [string]$actual) {
    if ($expected -ceq $actual) { Pass $name } else { Fail $name "expected=[$expected] actual=[$actual]" }
}

Write-Host 'test-filename.ps1 — Sti-Slugify + Sti-UniquePath + Sti-SlugFromPath'
Write-Host ''

# --- Sti-Slugify rules -----------------------------------------------------

Assert-Equal "slugify lowercases" "add-notifications" (Sti-Slugify -InputText "Add Notifications")
Assert-Equal "slugify dash-separates" "dark-mode-toggle" (Sti-Slugify -InputText "Dark mode toggle")
Assert-Equal "slugify collapses runs" "foo-bar"           (Sti-Slugify -InputText "foo   bar")
Assert-Equal "slugify trims leading" "abc"                (Sti-Slugify -InputText "---abc")
Assert-Equal "slugify trims trailing" "abc"               (Sti-Slugify -InputText "abc---")
Assert-Equal "slugify replaces punct" "what-the-heck"     (Sti-Slugify -InputText "what?the/heck!")
Assert-Equal "slugify preserves digits" "v0-1-prerelease" (Sti-Slugify -InputText "v0.1 prerelease")

# Empty / whitespace-only input should error (returns $null + writes Error).
$emptyOut = Sti-Slugify -InputText '' -ErrorAction SilentlyContinue
if ([string]::IsNullOrEmpty($emptyOut)) { Pass "slugify empty input returns null/empty" } else { Fail "slugify empty input should fail" }

$wsOut = Sti-Slugify -InputText '   ' -ErrorAction SilentlyContinue
if ([string]::IsNullOrEmpty($wsOut)) { Pass "slugify whitespace-only returns null/empty" } else { Fail "slugify whitespace-only should fail" }

# --- Sti-UniquePath collision discriminator -------------------------------

$tmpDir = New-Item -ItemType Directory -Path (Join-Path ([System.IO.Path]::GetTempPath()) "sti-test-$(Get-Random)") -Force
try {
    $p1 = Sti-UniquePath -Dir $tmpDir.FullName -Timestamp '2026-05-12T103000' -Slug 'foo' -Artifact 'requirements' -Extension 'md'
    Assert-Equal "unique_path first call" "$($tmpDir.FullName)/2026-05-12T103000-foo-requirements.md" $p1

    # Create the file at $p1 so the next call discriminates.
    New-Item -ItemType File -Path $p1 -Force | Out-Null
    $p2 = Sti-UniquePath -Dir $tmpDir.FullName -Timestamp '2026-05-12T103000' -Slug 'foo' -Artifact 'requirements' -Extension 'md'
    Assert-Equal "unique_path appends -2" "$($tmpDir.FullName)/2026-05-12T103000-foo-requirements-2.md" $p2

    New-Item -ItemType File -Path $p2 -Force | Out-Null
    $p3 = Sti-UniquePath -Dir $tmpDir.FullName -Timestamp '2026-05-12T103000' -Slug 'foo' -Artifact 'requirements' -Extension 'md'
    Assert-Equal "unique_path appends -3 after -2 collision" "$($tmpDir.FullName)/2026-05-12T103000-foo-requirements-3.md" $p3
} finally {
    Remove-Item -Recurse -Force $tmpDir.FullName -ErrorAction SilentlyContinue
}

# --- Sti-SlugFromPath inverse ---------------------------------------------

Assert-Equal "slug_from_path bare" "add-notifications" `
    (Sti-SlugFromPath -Path 'docs/ideation/2026-05-12T103000-add-notifications-requirements.md' -Artifact 'requirements')
Assert-Equal "slug_from_path with -N suffix" "add-notifications" `
    (Sti-SlugFromPath -Path 'docs/ideation/2026-05-12T103000-add-notifications-requirements-3.md' -Artifact 'requirements')
Assert-Equal "slug_from_path with multi-word artifact" "add-notifications" `
    (Sti-SlugFromPath -Path 'docs/ideation/2026-05-12T103000-add-notifications-stride-batch.json' -Artifact 'stride-batch')

# Path that doesn't match the family should error.
$badPath = Sti-SlugFromPath -Path 'random.md' -Artifact 'requirements' -ErrorAction SilentlyContinue
if ([string]::IsNullOrEmpty($badPath)) { Pass "slug_from_path rejects non-family paths" } else { Fail "slug_from_path should reject non-family paths" "got=[$badPath]" }

# --- summary ---------------------------------------------------------------

Write-Host ''
Write-Host ("{0} passed, {1} failed" -f $script:PASS, $script:FAIL)
if ($script:FAIL -gt 0) { exit 1 } else { exit 0 }
