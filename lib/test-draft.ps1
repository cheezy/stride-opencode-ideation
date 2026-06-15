# PowerShell mirror of test-draft.sh — unit tests for lib/draft.ps1, the
# stride-ideation-ideate intra-session draft autosave/resume helpers (W1145).
#
# Run:
#   pwsh -File lib/test-draft.ps1
#
# Exits 0 if all tests pass, non-zero otherwise.

Set-StrictMode -Version Latest

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $ScriptDir 'draft.ps1')

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

Write-Host 'test-draft.ps1 — exercises Sti-DraftPath/Find/Save/Load/Exists/Clear'
Write-Host ''

$tmpDir = Join-Path ([System.IO.Path]::GetTempPath()) "sti-draft-test-$([System.IO.Path]::GetRandomFileName())"
New-Item -ItemType Directory -Path $tmpDir | Out-Null

try {
    # --- draft_path: deterministic for a given ts+slug --------------------
    Assert-Equal 'draft_path: <dir>/<ts>-<slug>-draft.md' `
        '.stride/2026-05-12T103000-add-notifications-draft.md' `
        (Sti-DraftPath .stride 2026-05-12T103000 add-notifications)

    Assert-Equal 'draft_path: trailing slash on dir is normalized' `
        '.stride/2026-05-12T103000-foo-draft.md' `
        (Sti-DraftPath .stride/ 2026-05-12T103000 foo)

    $p1 = Sti-DraftPath $tmpDir 2026-05-12T103000 foo
    $p2 = Sti-DraftPath $tmpDir 2026-05-12T103000 foo
    Assert-Equal 'draft_path: deterministic for a given SESSION_TS+slug' $p1 $p2

    $bad = Sti-DraftPath $tmpDir 2026-05-12T103000 '' 2>$null
    if ([string]::IsNullOrEmpty($bad)) { Pass 'draft_path: missing slug -> empty stdout + error' }
    else { Fail 'draft_path: missing slug leaked output' "[$bad]" }

    # --- save then load: round-trips content ------------------------------
    $draft = Sti-DraftPath (Join-Path $tmpDir '.stride') 2026-05-12T103000 round-trip
    $content = "## Goal`nShip the digest.`n`n## Problem`nApprovals rot in inboxes.`n__round_state__: 2"

    Sti-DraftSave $draft $content 2>$null
    if ($LASTEXITCODE -eq 0) { Pass 'draft_save: writes the scratch file (and creates .stride/ parent)' }
    else { Fail 'draft_save: failed to write' "rc=$LASTEXITCODE" }

    if (Test-Path -LiteralPath $draft) { Pass 'draft_save: scratch file exists at the computed path' }
    else { Fail 'draft_save: scratch file missing after save' }

    Assert-Equal 'draft_load: round-trips the saved content byte-for-byte' $content (Sti-DraftLoad $draft)

    # --- exists: predicate on non-empty draft -----------------------------
    if (Sti-DraftExists $draft) { Pass 'draft_exists: true for a non-empty draft' }
    else { Fail 'draft_exists: false for a non-empty draft (should be true)' }

    $empty = Sti-DraftPath (Join-Path $tmpDir '.stride') 2026-05-12T103000 empty-draft
    New-Item -ItemType File -Path $empty -Force | Out-Null
    if (Sti-DraftExists $empty) { Fail 'draft_exists: true for an empty draft (should be false)' }
    else { Pass 'draft_exists: false for an empty/zero-length draft (partial -> fresh)' }

    if (Sti-DraftExists (Join-Path $tmpDir '.stride/nope-draft.md')) { Fail 'draft_exists: true for an absent draft (should be false)' }
    else { Pass 'draft_exists: false for an absent draft' }

    # --- load: absent file -> error, no crash -----------------------------
    $loadBad = Sti-DraftLoad (Join-Path $tmpDir '.stride/missing-draft.md') 2>$null
    if ([string]::IsNullOrEmpty($loadBad)) { Pass 'draft_load: absent file -> empty stdout + error (safe, no crash)' }
    else { Fail 'draft_load: absent file leaked output' "[$loadBad]" }

    # --- save: write-failure branch returns non-zero, no crash ------------
    $blocker = Join-Path $tmpDir 'blocker'
    New-Item -ItemType File -Path $blocker -Force | Out-Null
    $blockedDraft = "$blocker/sub/2026-05-12T103000-x-draft.md"
    $saveErr = (Sti-DraftSave $blockedDraft 'body' 2>&1 | Out-String)
    Sti-DraftSave $blockedDraft 'body' 2>$null
    if ($LASTEXITCODE -ne 0) { Pass 'draft_save: returns non-zero when the parent dir cannot be created (no crash)' }
    else { Fail 'draft_save: succeeded despite an unmakeable parent dir (should fail)' }
    if ($saveErr -match 'cannot write scratch draft') { Pass 'draft_save: write failure emits a diagnostic to stderr' }
    else { Fail 'draft_save: write failure produced no diagnostic' "[$saveErr]" }

    # --- clear: removes the scratch file (idempotent) ---------------------
    Sti-DraftClear $draft
    if (Test-Path -LiteralPath $draft) { Fail 'draft_clear: scratch file still present after clear' }
    else { Pass 'draft_clear: removes the scratch file' }
    Sti-DraftClear $draft
    if ($LASTEXITCODE -eq 0) { Pass 'draft_clear: idempotent (no error when already gone)' }
    else { Fail 'draft_clear: errored on an already-absent file' "rc=$LASTEXITCODE" }

    # --- find: resume detection matches only the same slug ----------------
    $fdir = Join-Path $tmpDir 'find-stride'
    New-Item -ItemType Directory -Path $fdir | Out-Null
    Sti-DraftSave (Sti-DraftPath $fdir 2026-05-12T100000 alpha) 'alpha draft body' 2>$null
    Sti-DraftSave (Sti-DraftPath $fdir 2026-05-12T110000 beta)  'beta draft body'  2>$null
    New-Item -ItemType File -Path (Sti-DraftPath $fdir 2026-05-12T120000 gamma) -Force | Out-Null  # empty -> ignored

    Assert-Equal 'draft_find: returns the matching-slug draft only (two slugs in flight)' `
        "$fdir/2026-05-12T100000-alpha-draft.md" `
        (Sti-DraftFind $fdir alpha)

    Sti-DraftSave (Sti-DraftPath $fdir 2026-05-12T130000 oauth) 'oauth body' 2>$null
    $noauth = Sti-DraftFind $fdir auth 2>$null
    if ([string]::IsNullOrEmpty($noauth)) { Pass "draft_find: slug 'auth' does not match 'oauth' (dash-delimited suffix)" }
    else { Fail 'draft_find: auth cross-matched a different slug' "[$noauth]" }

    $none = Sti-DraftFind $fdir does-not-exist 2>$null
    if ([string]::IsNullOrEmpty($none)) { Pass 'draft_find: no matching draft -> empty stdout + non-zero (fresh session)' }
    else { Fail 'draft_find: leaked output for a slug with no draft' "[$none]" }

    $emptyOnly = Sti-DraftFind $fdir gamma 2>$null
    if ([string]::IsNullOrEmpty($emptyOnly)) { Pass 'draft_find: an empty-only draft is not offered for resume (partial -> fresh)' }
    else { Fail 'draft_find: offered an empty draft for resume' "[$emptyOnly]" }

    Sti-DraftSave (Sti-DraftPath $fdir 2026-05-12T090000 multi) 'older' 2>$null
    Sti-DraftSave (Sti-DraftPath $fdir 2026-05-12T140000 multi) 'newer' 2>$null
    Assert-Equal 'draft_find: latest ISO timestamp wins for a repeated slug' `
        "$fdir/2026-05-12T140000-multi-draft.md" `
        (Sti-DraftFind $fdir multi)

    $abs = Sti-DraftFind (Join-Path $tmpDir 'no-such-dir') anything 2>$null
    if ([string]::IsNullOrEmpty($abs)) { Pass 'draft_find: absent scratch dir -> empty stdout + non-zero (no crash)' }
    else { Fail 'draft_find: leaked output for an absent dir' "[$abs]" }
} finally {
    Remove-Item -Recurse -Force $tmpDir -ErrorAction SilentlyContinue
}

Write-Host ''
Write-Host ("{0} passed, {1} failed" -f $script:PASS, $script:FAIL)
if ($script:FAIL -gt 0) { exit 1 } else { exit 0 }
