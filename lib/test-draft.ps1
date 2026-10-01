# PowerShell mirror of test-draft.sh — unit tests for lib/draft.ps1, the
# /ideate intra-session draft autosave/resume helpers (W1145).
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

    # --- save from stdin ----------------------------------------------------
    $tricky = "Quotes: `"double`" and 'single'`nBackticks: ``whoami```nDollars: `$HOME `${PATH} `$(id)`n`n"
    $sdir = Join-Path (Join-Path $tmpDir 'stdin') '.stride'
    $stdinDraft = Join-Path $sdir '2026-05-12T103000-stdin-draft.md'
    $tricky | Sti-DraftSave $stdinDraft
    if ([System.IO.File]::ReadAllText($stdinDraft) -ceq $tricky) { Pass 'draft_save: content on stdin is written byte for byte (quotes, backticks, dollars, trailing newlines)' }
    else { Fail 'draft_save: stdin content was altered' }
    $argvDraft = Join-Path $sdir '2026-05-12T103000-argv-draft.md'
    Sti-DraftSave $argvDraft 'argv body'
    Assert-Equal 'draft_save: the argv form still works' 'argv body' ([System.IO.File]::ReadAllText($argvDraft))
    $emptyDraft = Join-Path $sdir '2026-05-12T103000-empty-draft.md'
    Sti-DraftSave $emptyDraft ''
    if ((Test-Path -LiteralPath $emptyDraft) -and ((Get-Item -LiteralPath $emptyDraft).Length -eq 0)) { Pass 'draft_save: an explicit empty argument writes an empty draft (stdin is not read)' }
    else { Fail 'draft_save: an explicit empty argument did not write an empty draft' }

    # --- self-ignoring scratch dir ------------------------------------------
    $repo = Join-Path $tmpDir 'fresh repo'
    New-Item -ItemType Directory -Path $repo | Out-Null
    & git -C $repo init -q
    Push-Location -LiteralPath $repo
    try {
        "draft prose`n" | Sti-DraftSave '.stride/2026-05-12T103000-ignored-draft.md'
        Assert-Equal "scratch_dir: the first save creates .stride/.gitignore containing '*'" "*`n" ([System.IO.File]::ReadAllText((Join-Path (Join-Path $repo '.stride') '.gitignore')))
        Assert-Equal 'scratch_dir: git status in a fresh repo shows nothing under .stride/' '' (((& git -C $repo status --porcelain --untracked-files=all) -join "`n").Trim())
        [System.IO.File]::WriteAllText((Join-Path (Join-Path $repo '.stride') '.gitignore'), "# mine`n*.md`n")
        Sti-DraftSave '.stride/2026-05-12T110000-ignored-draft.md' 'again'
        Assert-Equal 'scratch_dir: an existing .stride/.gitignore is left unchanged' "# mine`n*.md`n" ([System.IO.File]::ReadAllText((Join-Path (Join-Path $repo '.stride') '.gitignore')))
    } finally { Pop-Location }
    Push-Location -LiteralPath $tmpDir
    try {
        Sti-ScratchDir 'notes'
        if ((Test-Path -LiteralPath (Join-Path $tmpDir 'notes')) -and -not (Test-Path -LiteralPath (Join-Path (Join-Path $tmpDir 'notes') '.gitignore'))) { Pass 'scratch_dir: a directory not named .stride gets no .gitignore' }
        else { Fail 'scratch_dir: wrote a .gitignore outside .stride/' }
    } finally { Pop-Location }
    Push-Location -LiteralPath $repo
    try {
        $gi = Join-Path (Join-Path $repo '.stride') '.gitignore'
        [System.IO.File]::WriteAllText($gi, "!*-draft.md`n")
        Sti-DraftSave '.stride/2026-05-12T120000-reincluded-draft.md' 'x' 2>$null
        if (($LASTEXITCODE -ne 0) -and -not (Test-Path -LiteralPath (Join-Path (Join-Path $repo '.stride') '2026-05-12T120000-reincluded-draft.md'))) { Pass 'scratch_dir: refuses a draft that an existing .stride/.gitignore re-includes' }
        else { Fail 'scratch_dir: refuses a draft that an existing .stride/.gitignore re-includes' }
        [System.IO.File]::WriteAllText($gi, "*`n")
        [System.IO.File]::WriteAllText((Join-Path (Join-Path $repo '.stride') '2026-05-12T130000-tracked-draft.md'), "tracked`n")
        & git -C $repo add -f .stride/2026-05-12T130000-tracked-draft.md
        Sti-DraftSave '.stride/2026-05-12T130000-tracked-draft.md' 'new prose' 2>$null
        if ($LASTEXITCODE -ne 0) { Pass 'scratch_dir: refuses to write over an already-tracked draft' }
        else { Fail 'scratch_dir: refuses to write over an already-tracked draft' }
        $res = Sti-DraftFind .stride tracked 2>$null
        if ([string]::IsNullOrEmpty($res)) { Pass 'draft_find: never offers a tracked draft for resume' } else { Fail 'draft_find: never offers a tracked draft for resume' "[$res]" }
        $linkOk = $true
        try { New-Item -ItemType SymbolicLink -Path (Join-Path (Join-Path $repo '.stride') '2026-05-12T140000-linkdraft-draft.md') -Target $argvDraft -ErrorAction Stop | Out-Null } catch { $linkOk = $false }
        if ($linkOk) {
            $res = Sti-DraftFind .stride linkdraft 2>$null
            if ([string]::IsNullOrEmpty($res)) { Pass 'draft_find: never offers a symlinked draft for resume' } else { Fail 'draft_find: never offers a symlinked draft for resume' "[$res]" }
        } else { Pass 'draft_find: never offers a symlinked draft for resume (skipped: cannot create symlinks here)' }
    } finally { Pop-Location }
    Push-Location -LiteralPath $repo
    try {
        Sti-DraftSave '2026-05-12T150000-bare-draft.md' 'x' 2>$null
        if ($LASTEXITCODE -ne 0) { Pass 'draft_save: a path with no directory part is checked too (refused when git would track it)' }
        else { Fail 'draft_save: a path with no directory part is checked too (refused when git would track it)' }
    } finally { Pop-Location }
    $dangle = Join-Path $tmpDir 'dangle'
    New-Item -ItemType Directory -Force -Path (Join-Path $dangle '.stride') | Out-Null
    $dangleOk = $true
    try { New-Item -ItemType SymbolicLink -Path (Join-Path (Join-Path $dangle '.stride') '.gitignore') -Target (Join-Path $dangle 'planted-gitignore') -ErrorAction Stop | Out-Null } catch { $dangleOk = $false }
    if ($dangleOk) {
        Push-Location -LiteralPath $dangle
        try { Sti-ScratchDir '.stride' 2>$null } finally { Pop-Location }
        if (-not (Test-Path -LiteralPath (Join-Path $dangle 'planted-gitignore'))) { Pass 'scratch_dir: never writes through a dangling .stride/.gitignore symlink' }
        else { Fail 'scratch_dir: never writes through a dangling .stride/.gitignore symlink' }
    } else { Pass 'scratch_dir: never writes through a dangling .stride/.gitignore symlink (skipped: cannot create symlinks here)' }
    $elsewhere = Join-Path $tmpDir 'elsewhere'
    $linked = Join-Path $tmpDir 'linked'
    New-Item -ItemType Directory -Path $elsewhere, $linked | Out-Null
    $canLink = $true
    try { New-Item -ItemType SymbolicLink -Path (Join-Path $linked '.stride') -Target $elsewhere -ErrorAction Stop | Out-Null } catch { $canLink = $false }
    if ($canLink) {
        Sti-DraftSave (Join-Path (Join-Path $linked '.stride') '2026-05-12T103000-x-draft.md') 'x' 2>$null
        if (($LASTEXITCODE -ne 0) -and -not (Test-Path -LiteralPath (Join-Path $elsewhere '2026-05-12T103000-x-draft.md'))) { Pass 'scratch_dir: a symlinked .stride is refused and nothing is written' }
        else { Fail 'scratch_dir: a symlinked .stride is refused and nothing is written' }
    } else {
        Pass 'scratch_dir: a symlinked .stride is refused and nothing is written (skipped: cannot create symlinks here)'
    }
    $roDir = Join-Path (Join-Path $tmpDir 'ro') '.stride'
    New-Item -ItemType Directory -Path $roDir -Force | Out-Null
    $onWindows = [System.Environment]::OSVersion.Platform -eq 'Win32NT'
    if (-not $onWindows) {
        & chmod 500 $roDir
        Sti-DraftSave (Join-Path $roDir '2026-05-12T103000-ro-draft.md') 'x' 2>$null
        if ($LASTEXITCODE -ne 0) { Pass 'draft_save: a read-only .stride/ is reported as an error' }
        else { Fail 'draft_save: a read-only .stride/ is reported as an error' }
        & chmod 700 $roDir
    } else {
        Pass 'draft_save: a read-only .stride/ is reported as an error (skipped on Windows)'
    }
} finally {
    Remove-Item -Recurse -Force $tmpDir -ErrorAction SilentlyContinue
}

Write-Host ''
Write-Host ("{0} passed, {1} failed" -f $script:PASS, $script:FAIL)
if ($script:FAIL -gt 0) { exit 1 } else { exit 0 }
