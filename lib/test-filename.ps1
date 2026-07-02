# PowerShell mirror of test-filename.sh — unit tests for lib/filename.ps1
# (Sti-Slugify + Sti-UniquePath + Sti-SlugFromPath).
#
# Full-parity port: every assertion in test-filename.sh has a 1:1 counterpart
# here, with the same case labels in the same order. This file additionally
# keeps 4 PowerShell-only assertions (two extra slugify rule variants plus the
# empty-input and whitespace-only error cases), so it reports 22 assertions
# where the sh twin reports 18 — the +4 surplus is intentional.
#
# Run:
#   pwsh -File lib/test-filename.ps1
#
# Exits 0 if all tests pass, non-zero otherwise. Prints a one-line
# per-test status to stdout.

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

# --- slugify -----------------------------------------------------------------

Assert-Equal 'slugify lowercases and dash-separates words' `
    'add-notifications' (Sti-Slugify -InputText 'Add Notifications')

Assert-Equal 'slugify replaces non-alphanumerics with dashes (not deleted)' `
    'add-push-notifications' (Sti-Slugify -InputText 'Add Push! Notifications?')

Assert-Equal 'slugify collapses runs of dashes' `
    'foo-bar-baz' (Sti-Slugify -InputText 'foo   bar---baz')

Assert-Equal 'slugify trims leading and trailing dashes' `
    'hello-world' (Sti-Slugify -InputText '---Hello World---')

Assert-Equal 'slugify preserves numbers' `
    'oauth2-login' (Sti-Slugify -InputText 'oauth2 login')

# --- slugify: PowerShell-only extras (part of the +4 surplus) -----------------

Assert-Equal 'slugify dash-separates (extra: ps1-only)' `
    'dark-mode-toggle' (Sti-Slugify -InputText 'Dark mode toggle')

Assert-Equal 'slugify replaces punct (extra: ps1-only)' `
    'what-the-heck' (Sti-Slugify -InputText 'what?the/heck!')

# Empty / whitespace-only input should error (returns $null + writes Error).
$emptyOut = Sti-Slugify -InputText '' -ErrorAction SilentlyContinue
if ([string]::IsNullOrEmpty($emptyOut)) { Pass 'slugify empty input returns null/empty (extra: ps1-only)' } else { Fail 'slugify empty input should fail' }

$wsOut = Sti-Slugify -InputText '   ' -ErrorAction SilentlyContinue
if ([string]::IsNullOrEmpty($wsOut)) { Pass 'slugify whitespace-only returns null/empty (extra: ps1-only)' } else { Fail 'slugify whitespace-only should fail' }

# --- unique_path ---------------------------------------------------------------

$TMP = Join-Path ([System.IO.Path]::GetTempPath()) "sti-filename-$(Get-Random)"
New-Item -ItemType Directory -Path $TMP | Out-Null

try {
    $TS = '2026-05-12T103000'
    $SLUG = 'add-notifications'

    # Fresh: no collision -> base name returned.
    $expectedFresh = "$TMP/$TS-$SLUG-requirements.md"
    Assert-Equal 'fresh timestamp produces base name' `
        $expectedFresh `
        (Sti-UniquePath -Dir $TMP -Timestamp $TS -Slug $SLUG -Artifact 'requirements' -Extension 'md')

    # Single collision: base exists -> -2 returned.
    New-Item -ItemType File -Path $expectedFresh -Force | Out-Null
    $expectedTwo = "$TMP/$TS-$SLUG-requirements-2.md"
    Assert-Equal 'collision produces -2 suffix' `
        $expectedTwo `
        (Sti-UniquePath -Dir $TMP -Timestamp $TS -Slug $SLUG -Artifact 'requirements' -Extension 'md')

    # Double collision: base AND -2 exist -> -3 returned.
    New-Item -ItemType File -Path $expectedTwo -Force | Out-Null
    $expectedThree = "$TMP/$TS-$SLUG-requirements-3.md"
    Assert-Equal 'double collision produces -3 suffix' `
        $expectedThree `
        (Sti-UniquePath -Dir $TMP -Timestamp $TS -Slug $SLUG -Artifact 'requirements' -Extension 'md')

    # Hard invariant: helper must never return a path that already exists.
    New-Item -ItemType File -Path $expectedThree -Force | Out-Null
    $nextPath = Sti-UniquePath -Dir $TMP -Timestamp $TS -Slug $SLUG -Artifact 'requirements' -Extension 'md'
    if (Test-Path -LiteralPath $nextPath) {
        Fail "HARD INVARIANT: returned an existing path: $nextPath"
    } else {
        Pass "HARD INVARIANT: returned path does not exist ($(Split-Path -Leaf $nextPath))"
    }

    # Slug normalization happens upstream, but the test below proves that
    # Sti-Slugify + Sti-UniquePath together produce a path with the expected
    # normalized slug from a noisy human-typed input.
    $noisyTs = '2026-05-12T110000'
    $slugFromHuman = Sti-Slugify -InputText 'Add Notifications'
    $expectedCombined = "$TMP/$noisyTs-$slugFromHuman-stride-batch.json"
    Assert-Equal 'slug with spaces normalizes correctly through unique_path' `
        $expectedCombined `
        (Sti-UniquePath -Dir $TMP -Timestamp $noisyTs -Slug $slugFromHuman -Artifact 'stride-batch' -Extension 'json')
} finally {
    Remove-Item -Recurse -Force $TMP -ErrorAction SilentlyContinue
}

# --- slug_from_path -------------------------------------------------------------

Assert-Equal 'slug_from_path: simple requirements artifact' `
    'add-notifications' `
    (Sti-SlugFromPath -Path 'docs/ideation/2026-05-12T103000-add-notifications-requirements.md' -Artifact 'requirements')

Assert-Equal 'slug_from_path: works without a directory prefix' `
    'add-notifications' `
    (Sti-SlugFromPath -Path '2026-05-12T103000-add-notifications-requirements.md' -Artifact 'requirements')

Assert-Equal 'slug_from_path: strips a -2 collision discriminator' `
    'add-notifications' `
    (Sti-SlugFromPath -Path '2026-05-12T103000-add-notifications-requirements-2.md' -Artifact 'requirements')

Assert-Equal 'slug_from_path: strips a -10 collision discriminator' `
    'add-notifications' `
    (Sti-SlugFromPath -Path '2026-05-12T103000-add-notifications-requirements-10.md' -Artifact 'requirements')

Assert-Equal 'slug_from_path: preserves trailing slug digits when artifact follows them' `
    'oauth2-login' `
    (Sti-SlugFromPath -Path '2026-05-12T103000-oauth2-login-requirements.md' -Artifact 'requirements')

Assert-Equal 'slug_from_path: multi-word artifact (stride-batch)' `
    'add-notifications' `
    (Sti-SlugFromPath -Path '2026-05-12T103000-add-notifications-stride-batch.json' -Artifact 'stride-batch')

Assert-Equal 'slug_from_path: multi-word artifact with collision discriminator' `
    'add-notifications' `
    (Sti-SlugFromPath -Path '2026-05-12T103000-add-notifications-stride-batch-3.json' -Artifact 'stride-batch')

# Negative case: path that doesn't match the expected family should fail
# and produce no stdout.
$badOut = Sti-SlugFromPath -Path 'not-a-timestamped-filename.md' -Artifact 'requirements' -ErrorAction SilentlyContinue
if ([string]::IsNullOrEmpty($badOut)) {
    Pass 'slug_from_path: malformed path produces empty stdout (non-zero exit)'
} else {
    Fail "slug_from_path: malformed path leaked output: $badOut"
}

# --- summary ---------------------------------------------------------------

Write-Host ''
Write-Host ("{0} passed, {1} failed" -f $script:PASS, $script:FAIL)
if ($script:FAIL -gt 0) { exit 1 } else { exit 0 }
