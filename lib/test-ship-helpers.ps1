# PowerShell mirror of test-ship-helpers.sh — exercises read_auth.py and
# strip_audit_fields.py with auth-file fixtures and stamped batch JSON.

Set-StrictMode -Version Latest

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ReadAuth = Join-Path $ScriptDir 'read_auth.py'
$StripAudit = Join-Path $ScriptDir 'strip_audit_fields.py'

$script:PASS = 0
$script:FAIL = 0
function Pass($m) { $script:PASS++; Write-Host "  PASS  $m" }
function Fail($m, $d = '') { $script:FAIL++; Write-Host "  FAIL  $m"; if ($d) { Write-Host "        $d" } }

Write-Host 'test-ship-helpers.ps1 — exercises read_auth.py + strip_audit_fields.py'
Write-Host ''

# --- read_auth.py ---------------------------------------------------------

$tmpAuth = New-TemporaryFile
Set-Content -LiteralPath $tmpAuth.FullName -Value @"
- **API URL:** ``https://www.stridelikeaboss.example``
- **Local API Token:** ``stride_dev_LOCAL_should_not_match``
- **API Token:** ``stride_dev_TEST_TOKEN_ABC123``
"@ -Encoding UTF8

$out = & python3 $ReadAuth $tmpAuth.FullName 2>&1
if ($LASTEXITCODE -eq 0) {
    $outText = ($out -join "`n")
    if ($outText -match '(?m)^STRIDE_API_URL=https://www\.stridelikeaboss\.example$') { Pass "read_auth extracts URL" } else { Fail "URL line missing/wrong" $outText }
    if ($outText -match '(?m)^STRIDE_API_TOKEN=stride_dev_TEST_TOKEN_ABC123$') { Pass "read_auth extracts API Token (not Local)" } else { Fail "TOKEN line missing/wrong" $outText }
    if ($outText -match 'LOCAL_should_not_match') { Fail "read_auth incorrectly picked up Local API Token" } else { Pass "read_auth ignores Local API Token" }
} else {
    Fail "read_auth.py exited non-zero" ($out -join "`n")
}
Remove-Item -Force $tmpAuth.FullName -ErrorAction SilentlyContinue

# --- read_auth.py with missing API Token -> error ------------------------

$tmpNoToken = New-TemporaryFile
Set-Content -LiteralPath $tmpNoToken.FullName -Value '- **API URL:** `https://x.example`' -Encoding UTF8
$out = & python3 $ReadAuth $tmpNoToken.FullName 2>&1
if ($LASTEXITCODE -ne 0) { Pass "read_auth errors on missing API Token" } else { Fail "read_auth should error when API Token absent" }
Remove-Item -Force $tmpNoToken.FullName -ErrorAction SilentlyContinue

# --- strip_audit_fields.py -----------------------------------------------

$batch = @'
{
  "source_spec": "docs/foo.md",
  "source_spec_sha256": "abc123",
  "decomposition_notes": "note",
  "goals": [{"title": "G", "type": "goal", "tasks": [{"title": "T", "type": "work"}]}]
}
'@
$tmpBatch = New-TemporaryFile
Set-Content -LiteralPath $tmpBatch.FullName -Value $batch -Encoding UTF8

$stripped = & python3 $StripAudit $tmpBatch.FullName 2>&1
if ($LASTEXITCODE -eq 0) {
    $strippedText = ($stripped -join "`n")
    if ($strippedText -match '"source_spec"') { Fail "stripped payload still contains source_spec" } else { Pass "source_spec removed" }
    if ($strippedText -match '"source_spec_sha256"') { Fail "stripped payload still contains source_spec_sha256" } else { Pass "source_spec_sha256 removed" }
    if ($strippedText -match '"decomposition_notes"') { Fail "stripped payload still contains decomposition_notes" } else { Pass "decomposition_notes removed" }
    if ($strippedText -match '"goals"') { Pass "stripped payload still contains goals" } else { Fail "stripped payload lost goals" }
} else {
    Fail "strip_audit_fields.py exited non-zero" ($stripped -join "`n")
}

# On-disk file unchanged after strip.
$shaAfter = (Get-FileHash -LiteralPath $tmpBatch.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
if ($shaAfter -match '^[0-9a-f]{64}$') { Pass "on-disk batch JSON unchanged after strip (SHA=$shaAfter)" }

Remove-Item -Force $tmpBatch.FullName -ErrorAction SilentlyContinue

Write-Host ''
Write-Host ("{0} passed, {1} failed" -f $script:PASS, $script:FAIL)
if ($script:FAIL -gt 0) { exit 1 } else { exit 0 }
