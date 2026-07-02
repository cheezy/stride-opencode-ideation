# PowerShell mirror of test-drift-check.sh — unit tests for lib/drift_check.py.
#
# Full-parity port: every assertion in test-drift-check.sh has a 1:1
# counterpart here, with the same case labels in the same order.
#
# Run:
#   pwsh -File lib/test-drift-check.ps1
#
# Exits 0 if all tests pass, non-zero otherwise.

Set-StrictMode -Version Latest

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Drift = Join-Path $ScriptDir 'drift_check.py'

$script:PASS = 0
$script:FAIL = 0
function Pass([string]$msg) { $script:PASS++; Write-Host "  PASS  $msg" }
function Fail([string]$msg, [string]$detail = '') {
    $script:FAIL++
    Write-Host "  FAIL  $msg"
    if ($detail) { Write-Host "        $detail" }
}

Write-Host 'test-drift-check.ps1 — exercises drift_check.py'
Write-Host ''

$tmpDir = Join-Path ([System.IO.Path]::GetTempPath()) "sti-drift-$(Get-Random)"
New-Item -ItemType Directory -Path $tmpDir | Out-Null

$errFile = Join-Path $tmpDir 'last.err'

function Get-LastErr {
    if (Test-Path -LiteralPath $errFile) {
        $raw = Get-Content -LiteralPath $errFile -Raw
        if ($null -ne $raw) { return $raw }
    }
    return ''
}

function Assert-Exit([string]$label, [string]$fixture, [int]$expected) {
    & python3 $Drift $fixture 2> $errFile | Out-Null
    $actual = $LASTEXITCODE
    if ($actual -eq $expected) {
        Pass $label
    } else {
        Fail $label "expected exit $expected, got $actual; stderr: $(Get-LastErr)"
    }
}

function Assert-ExitWithMsg([string]$label, [string]$fixture, [int]$expected, [string]$needle) {
    & python3 $Drift $fixture 2> $errFile | Out-Null
    $actual = $LASTEXITCODE
    if ($actual -ne $expected) {
        Fail $label "expected exit $expected, got $actual; stderr: $(Get-LastErr)"
        return
    }
    if ((Get-LastErr).Contains($needle)) {
        Pass $label
    } else {
        Fail $label "expected substring: $needle; actual stderr: $(Get-LastErr)"
    }
}

try {
    # --- fixture: a known source doc + its real SHA --------------------------
    # The source doc lives BESIDE the batch JSON and is referenced RELATIVELY:
    # drift_check.py resolves relative source_spec values against the batch
    # JSON's directory. The SHA is computed with Get-FileHash on the file
    # actually written (Set-Content appends a trailing newline — never hash an
    # in-memory string).

    $srcPath = Join-Path $tmpDir 'requirements.md'
    Set-Content -LiteralPath $srcPath -Encoding UTF8 -Value @'
# Fake requirements doc

## Problem
test
'@

    $realSha = (Get-FileHash -LiteralPath $srcPath -Algorithm SHA256).Hash.ToLowerInvariant()

    # --- no drift: matching SHA ----------------------------------------------

    $noDrift = Join-Path $tmpDir 'no_drift.json'
    Set-Content -LiteralPath $noDrift -Encoding UTF8 -Value @"
{
  "source_spec": "requirements.md",
  "source_spec_sha256": "$realSha",
  "decomposition_notes": "",
  "goals": [{"title": "G", "type": "goal", "tasks": [{"title": "T", "type": "work"}]}]
}
"@
    Assert-Exit 'no drift: matching SHA exits 0 silently' $noDrift 0

    # Verify stderr is empty on no-drift
    if ((Get-LastErr).Length -gt 0) {
        Fail 'no drift: stderr should be empty' (Get-LastErr)
    } else {
        Pass 'no drift: stderr is empty'
    }

    # --- drift: mismatched SHA ------------------------------------------------

    $driftJson = Join-Path $tmpDir 'drift.json'
    Set-Content -LiteralPath $driftJson -Encoding UTF8 -Value @'
{
  "source_spec": "requirements.md",
  "source_spec_sha256": "0000000000000000000000000000000000000000000000000000000000000000",
  "decomposition_notes": "",
  "goals": [{"title": "G", "type": "goal", "tasks": [{"title": "T", "type": "work"}]}]
}
'@
    Assert-ExitWithMsg 'drift: mismatched SHA exits 1 with DRIFT DETECTED message' `
        $driftJson 1 'DRIFT DETECTED'

    # --- drift: stderr names both stamped and recomputed SHA -------------------

    $lastErr = Get-LastErr
    if ($lastErr.Contains('stamped SHA-256:') -and $lastErr.Contains('recomputed SHA-256:')) {
        Pass 'drift: stderr names both stamped and recomputed SHA values'
    } else {
        Fail 'drift: stderr missing stamped/recomputed labels' $lastErr
    }

    # --- absent source_spec: hand-written-JSON path proceeds silently ----------

    $noSourceSpec = Join-Path $tmpDir 'no_source_spec.json'
    Set-Content -LiteralPath $noSourceSpec -Encoding UTF8 -Value @'
{"goals": [{"title": "G", "type": "goal", "tasks": [{"title": "T", "type": "work"}]}]}
'@
    Assert-Exit 'absent source_spec: exits 0 (hand-written path)' $noSourceSpec 0
    if ((Get-LastErr).Length -gt 0) {
        Fail 'absent source_spec: stderr should be empty' (Get-LastErr)
    } else {
        Pass 'absent source_spec: stderr is empty'
    }

    # --- present source_spec but absent SHA: proceed silently ------------------

    $noSha = Join-Path $tmpDir 'no_sha.json'
    Set-Content -LiteralPath $noSha -Encoding UTF8 -Value @'
{
  "source_spec": "requirements.md",
  "goals": [{"title": "G", "type": "goal", "tasks": [{"title": "T", "type": "work"}]}]
}
'@
    Assert-Exit 'source_spec present but SHA absent: exits 0 (no baseline)' $noSha 0

    # --- source_spec points at a missing file ----------------------------------

    $missingSource = Join-Path $tmpDir 'missing_source.json'
    Set-Content -LiteralPath $missingSource -Encoding UTF8 -Value @'
{
  "source_spec": "does_not_exist.md",
  "source_spec_sha256": "abcdef",
  "goals": [{"title": "G", "type": "goal", "tasks": [{"title": "T", "type": "work"}]}]
}
'@
    Assert-ExitWithMsg 'missing source_spec file: exits 2 with resolution error' `
        $missingSource 2 'could not be resolved'

    # --- malformed batch JSON itself --------------------------------------------

    $bad = Join-Path $tmpDir 'bad.json'
    Set-Content -LiteralPath $bad -Encoding UTF8 -Value 'not json'
    Assert-ExitWithMsg 'malformed batch JSON: exits 2 with read/parse error' `
        $bad 2 'could not read batch JSON'

    # --- source_spec given as absolute path -------------------------------------

    $absSource = Join-Path $tmpDir 'abs_source.json'
    $srcPathJson = $srcPath.Replace('\', '/')
    Set-Content -LiteralPath $absSource -Encoding UTF8 -Value @"
{
  "source_spec": "$srcPathJson",
  "source_spec_sha256": "$realSha",
  "goals": [{"title": "G", "type": "goal", "tasks": [{"title": "T", "type": "work"}]}]
}
"@
    Assert-Exit 'absolute source_spec path resolves correctly' $absSource 0
} finally {
    Remove-Item -Recurse -Force $tmpDir -ErrorAction SilentlyContinue
}

Write-Host ''
Write-Host ("{0} passed, {1} failed" -f $script:PASS, $script:FAIL)
if ($script:FAIL -gt 0) { exit 1 } else { exit 0 }
