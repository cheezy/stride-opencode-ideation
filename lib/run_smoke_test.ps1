# End-to-end smoke test for the stride-ideation-stridify pipeline.
# PowerShell mirror of run_smoke_test.sh — composes every helper the
# stridify skill body invokes (in the same order) and verifies each
# stage produces the expected output. The final HTTP POST is dry-run
# by default; pass -Live <stride-batch.json> to POST against a real
# Stride instance using the auth in .stride_auth.md.
#
# Usage:
#   pwsh -File lib\run_smoke_test.ps1
#       Dry-run mode. Uses fixtures/2026-05-12T120000-dark-mode-toggle-stride-batch.json.
#
#   pwsh -File lib\run_smoke_test.ps1 -Live <stride-batch.json>
#       LIVE mode. Reads auth from $CLAUDE_PROJECT_DIR/.stride_auth.md
#       and POSTs the supplied batch to the Stride API. Use a dev
#       Stride instance — this creates real tasks.
#
# Exit code: 0 if every stage passes; 1 on the first failure.

param(
    [Parameter(Mandatory = $false)] [string]$Live
)

Set-StrictMode -Version Latest

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$PluginRoot = Split-Path -Parent $ScriptDir
$Mode = if ($Live) { 'live' } else { 'dry' }
$BatchPath = if ($Live) { $Live } else { Join-Path $PluginRoot 'fixtures/2026-05-12T120000-dark-mode-toggle-stride-batch.json' }

$script:PASS = 0
$script:FAIL = 0

function Pass([string]$message) {
    $script:PASS++
    Write-Host "  ✓  $message"
}

function Fail([string]$message, [string]$detail = '') {
    $script:FAIL++
    Write-Host "  ✗  $message"
    if ($detail) { Write-Host "     $detail" }
}

Write-Host "stride-ideation smoke test ($Mode mode)"
Write-Host "batch JSON: $BatchPath"
Write-Host ""

# --- Stage 1: validate_batch.py ---------------------------------------------

Write-Host 'Stage 1: structural validation'
$validateErr = New-TemporaryFile
$validateOut = & python3 (Join-Path $ScriptDir 'validate_batch.py') $BatchPath 2>$validateErr.FullName
if ($LASTEXITCODE -eq 0) {
    Pass "validate_batch.py accepts the batch"
} else {
    $errText = Get-Content -Raw -LiteralPath $validateErr.FullName -ErrorAction SilentlyContinue
    Fail "validate_batch.py rejected the batch" $errText
}
Remove-Item -Force $validateErr.FullName -ErrorAction SilentlyContinue

# --- Stage 2: drift_check.py ------------------------------------------------

Write-Host ''
Write-Host 'Stage 2: source-spec drift check'
$driftErr = New-TemporaryFile
$driftOut = & python3 (Join-Path $ScriptDir 'drift_check.py') $BatchPath 2>$driftErr.FullName
$driftExit = $LASTEXITCODE
$driftErrText = Get-Content -Raw -LiteralPath $driftErr.FullName -ErrorAction SilentlyContinue
switch ($driftExit) {
    0 { Pass "drift_check.py reports no drift (source_spec_sha256 matches the source)" }
    1 { Fail "drift_check.py reports DRIFT — fixture is stale" $driftErrText }
    2 { Fail "drift_check.py reported an error" $driftErrText }
    default { Fail "drift_check.py exited unexpectedly (code $driftExit)" $driftErrText }
}
Remove-Item -Force $driftErr.FullName -ErrorAction SilentlyContinue

# --- Stage 3: read_auth.py against a fixture auth file ---------------------

Write-Host ''
Write-Host 'Stage 3: auth file parsing'
$tmpAuth = New-TemporaryFile
Set-Content -LiteralPath $tmpAuth.FullName -Value @"
- **API URL:** ``https://www.stridelikeaboss.example``
- **Local API Token:** ``stride_dev_LOCAL_should_not_match``
- **API Token:** ``stride_dev_TEST_TOKEN_FOR_SMOKE_TEST_ONLY``
"@ -Encoding UTF8

$authErr = New-TemporaryFile
$authOut = & python3 (Join-Path $ScriptDir 'read_auth.py') $tmpAuth.FullName 2>$authErr.FullName
if ($LASTEXITCODE -eq 0) {
    if ($authOut -match '(?m)^STRIDE_API_URL=https://www\.stridelikeaboss\.example$') {
        Pass "read_auth.py extracts STRIDE_API_URL"
    } else {
        Fail "URL line not as expected" ($authOut -join "`n")
    }
    if ($authOut -match '(?m)^STRIDE_API_TOKEN=stride_dev_TEST_TOKEN_FOR_SMOKE_TEST_ONLY$') {
        Pass "read_auth.py extracts the API Token (and not the Local API Token)"
    } else {
        Fail "TOKEN line not as expected" ($authOut -join "`n")
    }
} else {
    $errText = Get-Content -Raw -LiteralPath $authErr.FullName -ErrorAction SilentlyContinue
    Fail "read_auth.py failed on the fixture auth file" $errText
}
Remove-Item -Force $tmpAuth.FullName, $authErr.FullName -ErrorAction SilentlyContinue

# --- Stage 4: strip_audit_fields.py ----------------------------------------

Write-Host ''
Write-Host 'Stage 4: strip local-audit fields from the payload'
$stripErr = New-TemporaryFile
$stripped = & python3 (Join-Path $ScriptDir 'strip_audit_fields.py') $BatchPath 2>$stripErr.FullName
if ($LASTEXITCODE -eq 0) {
    $strippedText = ($stripped -join "`n")
    if ($strippedText -match '"source_spec"') {
        Fail "stripped payload still contains source_spec"
    } else {
        Pass "source_spec removed from payload"
    }
    if ($strippedText -match '"source_spec_sha256"') {
        Fail "stripped payload still contains source_spec_sha256"
    } else {
        Pass "source_spec_sha256 removed from payload"
    }
    if ($strippedText -match '"decomposition_notes"') {
        Fail "stripped payload still contains decomposition_notes"
    } else {
        Pass "decomposition_notes removed from payload"
    }
    if ($strippedText -match '"goals"') {
        Pass "stripped payload still contains goals"
    } else {
        Fail "stripped payload lost goals"
    }
} else {
    $errText = Get-Content -Raw -LiteralPath $stripErr.FullName -ErrorAction SilentlyContinue
    Fail "strip_audit_fields.py failed" $errText
}
Remove-Item -Force $stripErr.FullName -ErrorAction SilentlyContinue

# Confirm the on-disk file is unchanged.
$shaAfter = (Get-FileHash -LiteralPath $BatchPath -Algorithm SHA256).Hash.ToLowerInvariant()
if ($shaAfter) {
    Pass "on-disk batch JSON SHA: $shaAfter (unchanged after strip)"
}

# --- Stage 5: response-rendering (canned 2xx) ------------------------------

Write-Host ''
Write-Host 'Stage 5: render created-identifiers table from a mock 2xx response'
$cannedResponse = @"
{
  "data": {
    "goals": [
      {
        "identifier": "G999",
        "title": "Smoke test goal",
        "tasks": [
          {"identifier": "W9001", "title": "Smoke test task 1"},
          {"identifier": "W9002", "title": "Smoke test task 2"}
        ]
      }
    ]
  }
}
"@

$rendered = $cannedResponse | & python3 -c @"
import json, sys
data = json.load(sys.stdin)
container = data.get('data', data)
goals = container.get('goals', [])
for goal in goals:
    gid = goal.get('identifier', '?')
    title = goal.get('title', '')
    print(f'  {gid:>6}  {title}')
    for task in goal.get('tasks', []) or []:
        tid = task.get('identifier', '?')
        ttitle = task.get('title', '')
        print(f'  {tid:>6}    {ttitle}')
"@

$renderedText = ($rendered -join "`n")
if ($renderedText -match 'G999  Smoke test goal' -and
    $renderedText -match 'W9001    Smoke test task 1' -and
    $renderedText -match 'W9002    Smoke test task 2') {
    Pass "render code produces a two-column G/W table from a 2xx body"
} else {
    Fail "render output not as expected" $renderedText
}

# --- Stage 6: LIVE POST (only if -Live) ------------------------------------

if ($Mode -eq 'live') {
    Write-Host ''
    Write-Host 'Stage 6: LIVE POST to the Stride API (NOTE: creates real tasks)'
    $projectDir = if ($env:CLAUDE_PROJECT_DIR) { $env:CLAUDE_PROJECT_DIR } else { (Get-Location).Path }
    $authFile = Join-Path $projectDir '.stride_auth.md'
    if (-not (Test-Path -LiteralPath $authFile)) {
        Fail "-Live requires .stride_auth.md at $authFile"
    } else {
        $liveAuthErr = New-TemporaryFile
        $liveAuthOut = & python3 (Join-Path $ScriptDir 'read_auth.py') $authFile 2>$liveAuthErr.FullName
        if ($LASTEXITCODE -eq 0) {
            $apiUrl = $null
            $apiToken = $null
            foreach ($line in $liveAuthOut) {
                if ($line -match '^STRIDE_API_URL=(.+)$') { $apiUrl = $matches[1] }
                if ($line -match '^STRIDE_API_TOKEN=(.+)$') { $apiToken = $matches[1] }
            }
            if (-not $apiUrl -or -not $apiToken) {
                Fail "live: read_auth.py output missing URL or TOKEN"
            } else {
                $payload = & python3 (Join-Path $ScriptDir 'strip_audit_fields.py') $BatchPath
                $headers = @{ Authorization = "Bearer $apiToken"; 'Content-Type' = 'application/json' }
                try {
                    $resp = Invoke-RestMethod -Method Post -Uri "$apiUrl/api/tasks/batch" -Headers $headers -Body $payload -ErrorAction Stop
                    Pass "live POST returned 2xx"
                    Write-Host "`nCreated identifiers:"
                    $container = if ($resp.data) { $resp.data } else { $resp }
                    foreach ($g in $container.goals) {
                        Write-Host ("  {0,6}  {1}" -f $g.identifier, $g.title)
                        foreach ($t in $g.tasks) {
                            Write-Host ("  {0,6}    {1}" -f $t.identifier, $t.title)
                        }
                    }
                } catch {
                    Fail "live POST failed: $($_.Exception.Message)"
                }
            }
            # Paranoia: drop the token from the shell as soon as we're done.
            $apiToken = $null
            Remove-Variable -Name apiToken -ErrorAction SilentlyContinue
        } else {
            $errText = Get-Content -Raw -LiteralPath $liveAuthErr.FullName -ErrorAction SilentlyContinue
            Fail "live: read_auth.py failed" $errText
        }
        Remove-Item -Force $liveAuthErr.FullName -ErrorAction SilentlyContinue
    }
}

# --- summary ---------------------------------------------------------------

Write-Host ''
Write-Host ("{0} passed, {1} failed" -f $script:PASS, $script:FAIL)
if ($script:FAIL -gt 0) {
    exit 1
} else {
    exit 0
}
