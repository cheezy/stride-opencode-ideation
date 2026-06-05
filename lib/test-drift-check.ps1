# PowerShell mirror of test-drift-check.sh — exercises drift_check.py
# against in-sync and drifted batch JSON inputs.

Set-StrictMode -Version Latest

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$DriftChecker = Join-Path $ScriptDir 'drift_check.py'

$script:PASS = 0
$script:FAIL = 0
function Pass($m) { $script:PASS++; Write-Host "  PASS  $m" }
function Fail($m, $d = '') { $script:FAIL++; Write-Host "  FAIL  $m"; if ($d) { Write-Host "        $d" } }

Write-Host 'test-drift-check.ps1 — exercises drift_check.py'
Write-Host ''

# Set up a temp dir with a source doc + a batch JSON whose source_spec_sha256
# matches the source doc's actual SHA-256.
$tmpDir = New-Item -ItemType Directory -Path (Join-Path ([System.IO.Path]::GetTempPath()) "sti-drift-$(Get-Random)") -Force
try {
    $srcPath = Join-Path $tmpDir.FullName 'requirements.md'
    Set-Content -LiteralPath $srcPath -Value "# Test`n`n## Goal`nA" -Encoding UTF8

    $sha = (Get-FileHash -LiteralPath $srcPath -Algorithm SHA256).Hash.ToLowerInvariant()

    $batchPath = Join-Path $tmpDir.FullName 'batch.json'
    $inSync = @{
        source_spec = $srcPath
        source_spec_sha256 = $sha
        goals = @(@{ title = 'G'; type = 'goal'; tasks = @(@{ title = 'T'; type = 'work' }) })
    } | ConvertTo-Json -Depth 5
    Set-Content -LiteralPath $batchPath -Value $inSync -Encoding UTF8

    # Stage 1: in-sync hash -> exit 0.
    & python3 $DriftChecker $batchPath 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) { Pass "in-sync hash returns exit 0" } else { Fail "in-sync hash should return 0" "rc=$LASTEXITCODE" }

    # Stage 2: bump the source doc so its SHA differs -> drift detected.
    Add-Content -LiteralPath $srcPath -Value "`nNew line" -Encoding UTF8
    & python3 $DriftChecker $batchPath 2>$null | Out-Null
    if ($LASTEXITCODE -eq 1) { Pass "drift detected when source modified" } else { Fail "drift should return exit 1" "rc=$LASTEXITCODE" }

    # Stage 3: malformed batch JSON -> exit 2 (error).
    Set-Content -LiteralPath $batchPath -Value 'not json' -Encoding UTF8
    & python3 $DriftChecker $batchPath 2>$null | Out-Null
    if ($LASTEXITCODE -eq 2) { Pass "malformed batch returns exit 2" } else { Fail "malformed batch should return 2" "rc=$LASTEXITCODE" }
} finally {
    Remove-Item -Recurse -Force $tmpDir.FullName -ErrorAction SilentlyContinue
}

Write-Host ''
Write-Host ("{0} passed, {1} failed" -f $script:PASS, $script:FAIL)
if ($script:FAIL -gt 0) { exit 1 } else { exit 0 }
