# PowerShell mirror of test-ship-helpers.sh — unit tests for the
# /stridify ship helpers:
#
#   - lib/strip_audit_fields.py  strips source_spec/sha256/decomposition_notes
#   - lib/read_auth.py            extracts STRIDE_API_URL and STRIDE_API_TOKEN
#                                 from .stride_auth.md
#
# Full-parity port: every assertion in test-ship-helpers.sh has a 1:1
# counterpart here, with the same case labels in the same order.
#
# Run:
#   pwsh -File lib/test-ship-helpers.ps1
#
# Exits 0 if all tests pass, non-zero otherwise.

Set-StrictMode -Version Latest

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Strip = Join-Path $ScriptDir 'strip_audit_fields.py'
$ReadAuth = Join-Path $ScriptDir 'read_auth.py'

$script:PASS = 0
$script:FAIL = 0
function Pass([string]$msg) { $script:PASS++; Write-Host "  PASS  $msg" }
function Fail([string]$msg, [string]$detail = '') {
    $script:FAIL++
    Write-Host "  FAIL  $msg"
    if ($detail) { Write-Host "        $detail" }
}

Write-Host 'test-ship-helpers.ps1 — exercises strip_audit_fields.py + read_auth.py'
Write-Host ''

$TMP = Join-Path ([System.IO.Path]::GetTempPath()) "sti-ship-$(Get-Random)"
New-Item -ItemType Directory -Path $TMP | Out-Null

function Read-FileRaw([string]$path) {
    if (-not (Test-Path -LiteralPath $path)) { return '' }
    $raw = Get-Content -LiteralPath $path -Raw -Encoding UTF8
    if ($null -eq $raw) { return '' }
    return $raw
}

try {
    # --- strip_audit_fields: happy path --------------------------------------

    $withAudit = Join-Path $TMP 'with_audit.json'
    Set-Content -LiteralPath $withAudit -Encoding UTF8 -Value @'
{
  "source_spec": "fixtures/x.md",
  "source_spec_sha256": "abc123",
  "decomposition_notes": "notes",
  "goals": [
    {"title": "G1", "type": "goal", "tasks": [{"title": "T1", "type": "work"}]}
  ]
}
'@

    # Record the on-disk file's pre-strip SHA + contents so the
    # "file is unchanged" assertion below has a fixed baseline.
    $withAuditShaBefore = (Get-FileHash -LiteralPath $withAudit -Algorithm SHA256).Hash.ToLowerInvariant()
    $withAuditContentBefore = Read-FileRaw $withAudit

    $stripped = (& python3 $Strip $withAudit 2>&1) -join "`n"
    if ($LASTEXITCODE -eq 0) {
        if (-not $stripped.Contains('source_spec')) {
            if (-not $stripped.Contains('source_spec_sha256')) {
                if (-not $stripped.Contains('decomposition_notes')) {
                    if ($stripped.Contains('goals')) {
                        Pass 'strip: removes all three audit fields; preserves goals'
                    } else {
                        Fail 'strip: removes audit fields but lost goals' $stripped
                    }
                } else {
                    Fail 'strip: did not remove decomposition_notes' $stripped
                }
            } else {
                Fail 'strip: did not remove source_spec_sha256' $stripped
            }
        } else {
            Fail 'strip: did not remove source_spec' $stripped
        }
    } else {
        Fail 'strip: exited non-zero on valid input' $stripped
    }

    # AC: the on-disk file must be unchanged after stripping. This is the
    # audit-trail guarantee — the local-audit fields stay on disk so the
    # v0.2 drift check has something to compare against.
    $withAuditShaAfter = (Get-FileHash -LiteralPath $withAudit -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($withAuditShaBefore -ceq $withAuditShaAfter) {
        if ($withAuditContentBefore -ceq (Read-FileRaw $withAudit)) {
            Pass 'strip: on-disk file is byte-for-byte unchanged after run'
        } else {
            Fail 'strip: SHAs matched but content comparison disagreed'
        }
    } else {
        Fail 'strip: on-disk file was modified by the helper' `
            "before SHA=$withAuditShaBefore after SHA=$withAuditShaAfter"
    }

    # --- strip_audit_fields: idempotent when fields already absent -----------

    $noAudit = Join-Path $TMP 'no_audit.json'
    Set-Content -LiteralPath $noAudit -Encoding UTF8 -Value @'
{"goals": [{"title": "G1", "type": "goal", "tasks": [{"title": "T1", "type": "work"}]}]}
'@

    $stripped2 = (& python3 $Strip $noAudit 2>&1) -join "`n"
    if ($LASTEXITCODE -eq 0) {
        if ($stripped2.Contains('goals')) {
            Pass 'strip: idempotent — passes through when audit fields absent'
        } else {
            Fail 'strip: passes through but lost goals' $stripped2
        }
    } else {
        Fail 'strip: failed on input that already lacked audit fields'
    }

    # --- strip_audit_fields: malformed JSON ----------------------------------

    $bad = Join-Path $TMP 'bad.json'
    Set-Content -LiteralPath $bad -Encoding UTF8 -Value '{ not json'

    $badErr = Join-Path $TMP 'bad.err'
    & python3 $Strip $bad 2> $badErr | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Fail 'strip: exited 0 on malformed JSON (expected non-zero)'
    } else {
        if ((Read-FileRaw $badErr).Contains('could not read')) {
            Pass 'strip: surfaces a read/parse error on malformed JSON'
        } else {
            Fail 'strip: failed on malformed JSON but error message missing' (Read-FileRaw $badErr)
        }
    }

    # --- read_auth: happy path ------------------------------------------------

    $authFile = Join-Path $TMP '.stride_auth.md'
    Set-Content -LiteralPath $authFile -Encoding UTF8 -Value @'
# Stride API Authentication

## API Configuration

- **API URL:** `https://www.stridelikeaboss.com`
- **Local API Token:** `stride_dev_LOCAL_TOKEN_SHOULD_NOT_MATCH`
- **API Token:** `stride_dev_REAL_TOKEN_xyz123`
- **User Email:** `cheezy@example.com`
'@

    $authOut = @(& python3 $ReadAuth $authFile 2>&1)
    if ($LASTEXITCODE -eq 0) {
        $urlLine = @($authOut | Where-Object { $_ -match '^STRIDE_API_URL=' }) -join ''
        $tokenLine = @($authOut | Where-Object { $_ -match '^STRIDE_API_TOKEN=' }) -join ''
        if ($urlLine -ceq 'STRIDE_API_URL=https://www.stridelikeaboss.com') {
            Pass 'read_auth: extracts STRIDE_API_URL'
        } else {
            Fail 'read_auth: URL line mismatch' $urlLine
        }
        if ($tokenLine -ceq 'STRIDE_API_TOKEN=stride_dev_REAL_TOKEN_xyz123') {
            Pass 'read_auth: extracts API Token (NOT the Local API Token)'
        } else {
            Fail 'read_auth: token mismatch — picked up wrong line' $tokenLine
        }
    } else {
        Fail 'read_auth: exited non-zero on a valid file' ($authOut -join "`n")
    }

    # --- read_auth: missing URL ------------------------------------------------

    $noUrl = Join-Path $TMP 'no_url.md'
    Set-Content -LiteralPath $noUrl -Encoding UTF8 -Value '- **API Token:** `stride_xxx`'

    $noUrlErr = Join-Path $TMP 'no_url.err'
    & python3 $ReadAuth $noUrl 2> $noUrlErr | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Fail 'read_auth: exited 0 when URL missing'
    } else {
        if ((Read-FileRaw $noUrlErr).Contains('STRIDE_API_URL not found')) {
            Pass 'read_auth: errors on missing API URL with the right message'
        } else {
            Fail 'read_auth: missing-URL error message wrong' (Read-FileRaw $noUrlErr)
        }
    }

    # --- read_auth: missing token ----------------------------------------------

    $noToken = Join-Path $TMP 'no_token.md'
    Set-Content -LiteralPath $noToken -Encoding UTF8 -Value '- **API URL:** `https://www.stridelikeaboss.com`'

    $noTokenErr = Join-Path $TMP 'no_token.err'
    & python3 $ReadAuth $noToken 2> $noTokenErr | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Fail 'read_auth: exited 0 when token missing'
    } else {
        if ((Read-FileRaw $noTokenErr).Contains('STRIDE_API_TOKEN not found')) {
            Pass 'read_auth: errors on missing API Token with the right message'
        } else {
            Fail 'read_auth: missing-token error message wrong' (Read-FileRaw $noTokenErr)
        }
    }

    # --- read_auth: token MUST NOT appear in stderr (security pitfall) ---------

    $withToken = Join-Path $TMP 'with_token.md'
    Set-Content -LiteralPath $withToken -Encoding UTF8 -Value @'
- **API URL:** `https://example.com`
- **API Token:** `stride_dev_SUPER_SECRET_TOKEN_xyz_DO_NOT_LEAK`
'@

    # This is the happy-path file but we want to deliberately tickle the
    # missing-token branch by stripping the URL line, to confirm stderr never
    # carries the token value if any other branch happened to surface text.
    # Capture REAL stderr via `2>` — never 2>&1 — so stdout can't mask a leak.
    $leakTest = Join-Path $TMP 'leak_test.md'
    $leakLines = @(Get-Content -LiteralPath $withToken -Encoding UTF8 | ForEach-Object {
        if ($_ -match '- \*\*API URL') { '' } else { $_ }
    })
    Set-Content -LiteralPath $leakTest -Encoding UTF8 -Value ($leakLines -join "`n")

    $leakErr = Join-Path $TMP 'leak_test.err'
    & python3 $ReadAuth $leakTest 2> $leakErr | Out-Null
    if ((Read-FileRaw $leakErr).Contains('stride_dev_SUPER_SECRET_TOKEN')) {
        Fail 'read_auth: token value LEAKED in stderr' (Read-FileRaw $leakErr)
    } else {
        Pass 'read_auth: token value NEVER appears in stderr (security)'
    }

    # --- read_auth: nonexistent path --------------------------------------------

    $missingErr = Join-Path $TMP 'missing.err'
    & python3 $ReadAuth (Join-Path $TMP 'does_not_exist.md') 2> $missingErr | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Fail 'read_auth: exited 0 on nonexistent file'
    } else {
        if ((Read-FileRaw $missingErr).Contains('.stride_auth.md not found')) {
            Pass 'read_auth: errors cleanly on missing file'
        } else {
            Fail 'read_auth: missing-file error message wrong' (Read-FileRaw $missingErr)
        }
    }

    # --- read_auth: missing file error includes setup-doc link ------------------

    if ((Read-FileRaw $missingErr).Contains('https://www.stridelikeaboss.com/api/agent/onboarding')) {
        Pass 'read_auth: missing-file error links to the setup docs'
    } else {
        Fail 'read_auth: missing-file error does not link to setup docs' (Read-FileRaw $missingErr)
    }

    # --- read_auth: missing-URL error also links to setup docs ------------------

    if ((Read-FileRaw $noUrlErr).Contains('https://www.stridelikeaboss.com/api/agent/onboarding')) {
        Pass 'read_auth: missing-URL error links to the setup docs'
    } else {
        Fail 'read_auth: missing-URL error does not link to setup docs' (Read-FileRaw $noUrlErr)
    }

    # --- read_auth: missing-token error also links to setup docs ----------------

    if ((Read-FileRaw $noTokenErr).Contains('https://www.stridelikeaboss.com/api/agent/onboarding')) {
        Pass 'read_auth: missing-token error links to the setup docs'
    } else {
        Fail 'read_auth: missing-token error does not link to setup docs' (Read-FileRaw $noTokenErr)
    }
} finally {
    Remove-Item -Recurse -Force $TMP -ErrorAction SilentlyContinue
}

Write-Host ''
Write-Host ("{0} passed, {1} failed" -f $script:PASS, $script:FAIL)
if ($script:FAIL -gt 0) { exit 1 } else { exit 0 }
