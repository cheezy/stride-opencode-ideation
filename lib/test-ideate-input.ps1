# PowerShell mirror of test-ideate-input.sh — exercises the
# /ideate --input <file> brain-dump seed documented in
# commands/ideate.md (W1158; ports upstream G235/W1137).
#
# The platform file-read / question UI is only available inside a live OpenCode
# CLI session, so this test embeds reference implementations of the documented
# Step 1 --input parse, the file-exists validation, and the Step 4c read-only
# invariant, and exercises them. The reference implementations MUST stay
# consistent with Step 1 / Step 4c in commands/ideate.md
# and with the bash mirror lib/test-ideate-input.sh — if you edit one, edit all.
#
# Run:
#   pwsh -File lib/test-ideate-input.ps1
#
# Exits 0 if all tests pass, non-zero otherwise.

Set-StrictMode -Version Latest

$script:PASS = 0
$script:FAIL = 0
function Pass($m) { $script:PASS++; Write-Host "  PASS  $m" }
function Fail($m, $d = '') { $script:FAIL++; Write-Host "  FAIL  $m"; if ($d) { Write-Host "        $d" } }

Write-Host 'test-ideate-input.ps1 — exercises the --input parse + read-only seed'
Write-Host ''

# --- reference flag parser -------------------------------------------------
# Mirrors commands/ideate.md Step 1. Returns @{ Continue; Input; Remainder }.
function Parse-Flags([string]$ArgString) {
    $tokens = @($ArgString -split '\s+' | Where-Object { $_ -ne '' })
    $continuePath = ''
    $inputPath = ''
    $rest = @()
    $i = 0
    while ($i -lt $tokens.Count) {
        $t = $tokens[$i]
        if ($t -eq '--continue') {
            $i++
            if ($i -lt $tokens.Count) { $continuePath = $tokens[$i] }
        } elseif ($t -like '--continue=*') {
            $continuePath = $t.Substring('--continue='.Length)
        } elseif ($t -eq '--input') {
            $i++
            if ($i -lt $tokens.Count) { $inputPath = $tokens[$i] }
        } elseif ($t -like '--input=*') {
            $inputPath = $t.Substring('--input='.Length)
        } else {
            $rest += $t
        }
        $i++
    }
    return @{ Continue = $continuePath; Input = $inputPath; Remainder = ($rest -join ' ') }
}

# --- reference --input validation ------------------------------------------
# Mirrors commands/ideate.md Step 1's INPUT_PATH existence check. Returns $true when OK
# (unset or existing file), $false (and writes the error) when set-but-missing.
function Test-InputPath([string]$Path) {
    if ([string]::IsNullOrEmpty($Path)) { return $true }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        Write-Error "stride-ideation: --input file not found: $Path"
        return $false
    }
    return $true
}

# --- reference read-only seed read -----------------------------------------
# Mirrors commands/ideate.md Step 4c. Reads read-only; MUST NOT modify the file.
function Read-InputNotes([string]$Path) {
    if ([string]::IsNullOrEmpty($Path)) { return '' }
    return (Get-Content -LiteralPath $Path -Raw)
}

# === temp dir + fixtures ===================================================

$tmpDir = Join-Path ([System.IO.Path]::GetTempPath()) ('stiideinput_' + [System.IO.Path]::GetRandomFileName())
New-Item -ItemType Directory -Path $tmpDir | Out-Null

$notes = Join-Path $tmpDir 'notes.md'
Set-Content -LiteralPath $notes -Encoding UTF8 -Value @'
# Rough notes

We want a daily digest so approvers stop missing requests.
Assume people read email. SMTP relay is fine.
'@
$notesShaBefore = (Get-FileHash -LiteralPath $notes -Algorithm SHA256).Hash

$prior = Join-Path $tmpDir '2026-05-12T120000-thing-requirements.md'
Set-Content -LiteralPath $prior -Encoding UTF8 -Value "# Thing — requirements`n## Goal`nShip the thing."

$emptyNotes = Join-Path $tmpDir 'empty.md'
# A truly zero-byte file (Set-Content '' would write a trailing newline / BOM).
New-Item -ItemType File -Path $emptyNotes -Force | Out-Null

try {
    # === case 1: --input <path> and --input=<path> both parse =============
    $pSpace = Parse-Flags "--input $notes my topic here"
    $pEquals = Parse-Flags "--input=$notes my topic here"
    if ($pSpace.Input -ceq $notes -and $pEquals.Input -ceq $notes) {
        Pass 'case 1: --input <path> and --input=<path> both parse to INPUT_PATH (AC1)'
    } else {
        Fail 'case 1: --input parse wrong' "space=[$($pSpace.Input)] equals=[$($pEquals.Input)]"
    }
    if ($pSpace.Remainder -ceq 'my topic here' -and $pEquals.Remainder -ceq 'my topic here') {
        Pass 'case 1: the --input tokens are consumed and the TOPIC remainder is preserved'
    } else {
        Fail 'case 1: remainder wrong after --input consumption' "space=[$($pSpace.Remainder)] equals=[$($pEquals.Remainder)]"
    }

    # === case 2: absence leaves INPUT_PATH empty, topic intact ============
    $pNone = Parse-Flags 'just a plain topic'
    if ([string]::IsNullOrEmpty($pNone.Input) -and $pNone.Remainder -ceq 'just a plain topic') {
        Pass 'case 2: no --input leaves INPUT_PATH empty and TOPIC intact'
    } else {
        Fail 'case 2: absence handling wrong' "input=[$($pNone.Input)] rem=[$($pNone.Remainder)]"
    }

    # === case 3: validation — existing file OK, missing file errors (AC1) ==
    if (Test-InputPath $notes) {
        Pass 'case 3: validate accepts an existing --input file (true)'
    } else {
        Fail 'case 3: validate rejected an existing file'
    }
    $missing = Join-Path $tmpDir 'does-not-exist.md'
    if (-not (Test-InputPath $missing 2>$null)) {
        Pass 'case 3: missing --input file -> validation fails (edge case)'
    } else {
        Fail 'case 3: validate accepted a missing file (should fail)'
    }

    # === case 4: unset INPUT_PATH validates OK (no seed) ==================
    if (Test-InputPath '') {
        Pass 'case 4: unset INPUT_PATH validates cleanly (no-seed session)'
    } else {
        Fail 'case 4: unset INPUT_PATH was rejected'
    }

    # === case 5: read is read-only — file byte-for-byte unchanged (AC3) ===
    $seed = Read-InputNotes $notes
    $notesShaAfter = (Get-FileHash -LiteralPath $notes -Algorithm SHA256).Hash
    if ($notesShaBefore -ceq $notesShaAfter) {
        Pass 'case 5: --input file is byte-for-byte unchanged after the read (read-only invariant)'
    } else {
        Fail 'case 5: --input file was modified by the read (pitfall violated)'
    }
    if ($seed -match 'daily digest') {
        Pass 'case 5: Read-InputNotes returns the file contents as seed material'
    } else {
        Fail 'case 5: seed content not returned' $seed
    }
    if (Test-Path -LiteralPath $notes) {
        Pass 'case 5: --input file still exists at its original path (not moved)'
    } else {
        Fail 'case 5: --input file was moved/removed (pitfall violated)'
    }

    # === case 6: --input and --continue parse independently (precedence, AC4) ==
    $pBoth = Parse-Flags "--continue $prior --input $notes leftover topic"
    if ($pBoth.Continue -ceq $prior -and $pBoth.Input -ceq $notes -and $pBoth.Remainder -ceq 'leftover topic') {
        Pass 'case 6: --continue and --input populate independently when both passed (AC4)'
    } else {
        Fail 'case 6: combined parse wrong' "continue=[$($pBoth.Continue)] input=[$($pBoth.Input)] rem=[$($pBoth.Remainder)]"
    }

    # === case 7: empty --input file is valid (falls back to a full session) ===
    if (Test-InputPath $emptyNotes) {
        $emptySeed = Read-InputNotes $emptyNotes
        if ([string]::IsNullOrEmpty($emptySeed)) {
            Pass 'case 7: empty --input file validates and yields empty seed (full session fallback, edge case)'
        } else {
            Fail 'case 7: empty file produced non-empty seed' $emptySeed
        }
    } else {
        Fail 'case 7: empty --input file was rejected by validation'
    }
} finally {
    Remove-Item -Recurse -Force $tmpDir -ErrorAction SilentlyContinue
}

Write-Host ''
Write-Host ("{0} passed, {1} failed" -f $script:PASS, $script:FAIL)
if ($script:FAIL -gt 0) { exit 1 } else { exit 0 }
