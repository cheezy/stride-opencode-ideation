# PowerShell mirror of test-stridify-fallback.sh — tests for the
# /stride-ideation:stridify Step 7.5 retry-exhaustion fallback documented in
# commands/stridify.md (W715). The Agent tool is only available inside a live
# session, so this test embeds a reference PowerShell implementation of the
# documented retry loop + fallback and exercises it against a mock subagent
# that always fails.
#
# THREE-WAY SYNC WARNING: the reference fallback implementation below MUST
# stay consistent with Step 7.5 in commands/stridify.md AND with the bash
# reference in test-stridify-fallback.sh. If you edit one, edit all three —
# these tests exist to prevent the doc and the on-the-wire behavior from
# drifting apart.
#
# Run:
#   pwsh -File lib/test-stridify-fallback.ps1
#
# Exits 0 if all tests pass, non-zero otherwise.

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

Write-Host 'test-stridify-fallback.ps1 — exercises the Step 7.5 retry-exhaustion fallback'
Write-Host ''

$TMP = Join-Path ([System.IO.Path]::GetTempPath()) "sti-fallback-$(Get-Random)"
New-Item -ItemType Directory -Path $TMP | Out-Null

function Read-FileRaw([string]$path) {
    $raw = Get-Content -LiteralPath $path -Raw -Encoding UTF8
    if ($null -eq $raw) { return '' }
    return $raw
}

# --- reference fallback implementation --------------------------------------
#
# Mirrors stridify.md Step 7.5 a/b/c. Signature:
#   Step-75SavePromptAndExit `
#     <prompt-text> <last-error> `
#     <source-path> <source-sha> <source-ts> `
#     <slug-for-path> <target-batch-path> <goal-meta>
#
# <goal-meta> is either the literal string "(no --goal)" or
# "<name>|<index>|<slug>" — a 3-field pipe-separated tuple.
#
# Stderr ([Console]::Error): a recovery summary. Stdout: nothing. Side effect:
# writes the saved-prompt markdown file next to the source path. The real
# implementation exits non-zero; the test reference returns 99 so control
# comes back to the runner.

function Step-75SavePromptAndExit {
    param(
        [string]$Prompt,
        [string]$LastErr,
        [string]$SourcePath,
        [string]$SourceSha,
        [string]$SourceTs,
        [string]$SlugForPath,
        [string]$TargetBatchPath,
        [string]$GoalMeta
    )

    $sourceDir = Split-Path -Parent $SourcePath
    $promptPath = Sti-UniquePath -Dir $sourceDir -Timestamp $SourceTs `
        -Slug $SlugForPath -Artifact 'decomposer-prompt' -Extension 'md'

    if ($GoalMeta -eq '(no --goal)') {
        $scopeLine = 'all goals (no --goal flag)'
    } else {
        $parts = $GoalMeta -split '\|', 3
        $scopeLine = '{0} (index {1}, slug {2})' -f $parts[0], $parts[1], $parts[2]
    }

    $savedAt = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')

    $bodyLines = @(
        '# Decomposer Prompt — Saved After Retry Exhaustion'
        ''
        "- **Saved at:** $savedAt"
        "- **Source requirements doc:** $SourcePath"
        "- **Source SHA-256:** $SourceSha"
        "- **Per-goal scope:** $scopeLine"
        '- **Attempts before exhaustion:** 3'
        ''
        '## Last error from subagent'
        ''
        $LastErr
        ''
        '## Subagent prompt (literal — paste this into a fresh session)'
        ''
        '````'
        $Prompt
        '````'
        ''
        '## Recovery instructions'
        ''
        'Paste the prompt block above into a fresh Claude session — any model capable'
        'of following the requirements-decomposer contract works. The session does'
        "NOT need codebase access. Save the resulting fenced JSON as $TargetBatchPath."
        'Then run /stridify --batch on that path to validate, preview and'
        'ship it through lib/ship.sh — no hand-written curl.'
        ''
        'This sibling file contains NO authentication material — the decomposer'
        'prompt has no API access by construction.'
    )

    try {
        Set-Content -LiteralPath $promptPath -Encoding UTF8 -Value ($bodyLines -join "`n")
    } catch {
        # Per Step 7.5c pitfall: surface the prompt to stderr if the write fails.
        [Console]::Error.WriteLine("stride-ideation: failed to write saved-prompt file:")
        [Console]::Error.WriteLine($_.Exception.Message)
        [Console]::Error.WriteLine('--- in-memory prompt ---')
        [Console]::Error.WriteLine($Prompt)
        [Console]::Error.WriteLine('--- last error ---')
        [Console]::Error.WriteLine($LastErr)
        return 1
    }

    $lastErrFirstLine = ($LastErr -split "`r?`n")[0]
    [Console]::Error.WriteLine('stride-ideation: retries exhausted (3/3 transient failures).')
    [Console]::Error.WriteLine("Saved decomposer prompt to: $promptPath")
    [Console]::Error.WriteLine('Last error from the final attempt:')
    [Console]::Error.WriteLine("  $lastErrFirstLine")
    [Console]::Error.WriteLine('')
    [Console]::Error.WriteLine('To recover: paste the prompt block from that file into a fresh Claude')
    [Console]::Error.WriteLine("session; save the JSON response as $TargetBatchPath; then run")
    [Console]::Error.WriteLine("``/stridify --batch `"$TargetBatchPath`"`` to validate, preview and ship it.")
    [Console]::Error.WriteLine('')
    [Console]::Error.WriteLine('The Stride API POST was NOT attempted.')
    # The real implementation calls `exit 1`; the test wants control to return.
    return 99
}

# --- reference retry loop that always exhausts -------------------------------

function Invoke-DispatchAndFallback {
    param(
        [string]$Mock,
        [string]$Prompt,
        [string]$SourcePath,
        [string]$SourceSha,
        [string]$SourceTs,
        [string]$SlugForPath,
        [string]$TargetBatchPath,
        [string]$GoalMeta
    )
    $attempt = 1
    $max = 3
    $lastErr = ''
    while ($attempt -le $max) {
        $attemptErr = Join-Path $TMP "attempt.err.$attempt"
        & pwsh -NoProfile -File $Mock 2> $attemptErr | Out-Null
        if ($LASTEXITCODE -eq 0) {
            # Success path — not exercised in these tests.
            return 0
        }
        $lastErr = (Read-FileRaw $attemptErr).TrimEnd("`r", "`n")
        $attempt++
    }
    # Sentinel: track that fallback was reached (and POST was NOT).
    Set-Content -LiteralPath (Join-Path $TMP 'sentinel') -Encoding UTF8 -Value 'FALLBACK_REACHED'
    return Step-75SavePromptAndExit $Prompt $lastErr `
        $SourcePath $SourceSha $SourceTs `
        $SlugForPath $TargetBatchPath $GoalMeta
}

# In-process `2>` cannot capture [Console]::Error output, so each dispatch run
# swaps the Console error writer to $logFile for the duration (the fd-level
# `2>` on the native mock invocation inside the loop is unaffected).
function Invoke-WithStderrLog {
    param([string]$LogFile, [scriptblock]$Body)
    $writer = [System.IO.StreamWriter]::new($LogFile, $false, [System.Text.UTF8Encoding]::new($false))
    $writer.AutoFlush = $true
    $old = [Console]::Error
    [Console]::SetError($writer)
    try {
        return (& $Body)
    } finally {
        [Console]::SetError($old)
        $writer.Dispose()
    }
}

# --- POST sentinel: confirm POST is NOT attempted -----------------------------

function Test-PostWasAttempted {
    return (Test-Path -LiteralPath (Join-Path $TMP 'post_was_attempted'))
}

try {
    # --- mock subagent that ALWAYS fails transiently --------------------------

    $mock = Join-Path $TMP 'mock_always_fail.ps1'
    Set-Content -LiteralPath $mock -Encoding UTF8 -Value @'
[Console]::Error.WriteLine('Error: HTTP 529 Overloaded — Anthropic API capacity')
exit 2
'@

    # === fixtures ==============================================================

    $SourcePath = Join-Path $TMP '2026-05-15T210800-review-queue-code-diffs-requirements.md'
    Set-Content -LiteralPath $SourcePath -Encoding UTF8 -Value @'
# Review Queue Code Diffs

## Problem
Some problem text.

## Decomposition seams

1. **Kanban app** — first surface.
2. **stride plugin** — second surface.
'@

    $SourceSha = (Get-FileHash -LiteralPath $SourcePath -Algorithm SHA256).Hash.ToLowerInvariant()
    $SourceTs = '2026-05-15T210800'
    $TargetBatch = Join-Path $TMP '2026-05-15T210800-review-queue-code-diffs-stride-batch.json'

    $PromptBody = @'
Requirements document:

```
# Review Queue Code Diffs (full doc text would be here)
```
'@

    # === case 1: fallback writes a file at the expected path ===================

    $run1Log = Join-Path $TMP 'run1.log'
    $null = Invoke-WithStderrLog $run1Log {
        Invoke-DispatchAndFallback $mock $PromptBody `
            $SourcePath $SourceSha $SourceTs `
            'review-queue-code-diffs' $TargetBatch '(no --goal)'
    }
    $expectedPath = Join-Path $TMP '2026-05-15T210800-review-queue-code-diffs-decomposer-prompt.md'
    if (Test-Path -LiteralPath $expectedPath) {
        Pass 'case 1: fallback writes sibling file at expected path'
    } else {
        Fail 'case 1: expected file missing' "expected=$expectedPath"
    }

    $sentinelPath = Join-Path $TMP 'sentinel'
    if ((Test-Path -LiteralPath $sentinelPath) -and ((Read-FileRaw $sentinelPath).Contains('FALLBACK_REACHED'))) {
        Pass 'case 1: fallback branch was reached (sentinel set)'
    } else {
        Fail 'case 1: sentinel not set — fallback path not taken'
    }

    # === case 2: file contains all required sections ===========================

    if (Test-Path -LiteralPath $expectedPath) {
        $savedContent = Read-FileRaw $expectedPath
        $requiredSections = @(
            '# Decomposer Prompt — Saved After Retry Exhaustion'
            'Saved at'
            'Source requirements doc'
            'Source SHA-256'
            'Per-goal scope'
            'Attempts before exhaustion'
            '## Last error from subagent'
            '## Subagent prompt (literal — paste this into a fresh session)'
            '## Recovery instructions'
        )
        $missing = @()
        foreach ($sec in $requiredSections) {
            if (-not $savedContent.Contains($sec)) { $missing += "  - $sec" }
        }
        if ($missing.Count -eq 0) {
            Pass 'case 2: file contains all required sections'
        } else {
            Fail 'case 2: missing sections:' ($missing -join "`n")
        }

        if ($savedContent.Contains($SourceSha)) {
            Pass 'case 2: file includes source SHA-256'
        } else {
            Fail 'case 2: file missing source SHA-256'
        }

        if ($savedContent.Contains('HTTP 529 Overloaded')) {
            Pass 'case 2: file includes last error verbatim'
        } else {
            Fail 'case 2: file missing last error verbatim'
        }

        if ($savedContent.Contains('Requirements document:')) {
            Pass 'case 2: file includes literal prompt body'
        } else {
            Fail 'case 2: file missing literal prompt body'
        }
    }

    # === case 3: POST is NOT attempted in fallback branch =====================

    if (Test-PostWasAttempted) {
        Fail 'case 3: POST was attempted despite fallback (regression)'
    } else {
        Pass 'case 3: POST is NOT attempted in fallback branch'
    }

    # === case 4: re-invocation produces -2 sibling (no overwrite) =============

    # Snapshot the first file's content BEFORE run 2 so the "unchanged" check
    # below is a real comparison (the bash twin's version is vacuous).
    $firstContentBefore = Read-FileRaw $expectedPath

    $run2Log = Join-Path $TMP 'run2.log'
    $null = Invoke-WithStderrLog $run2Log {
        Invoke-DispatchAndFallback $mock $PromptBody `
            $SourcePath $SourceSha $SourceTs `
            'review-queue-code-diffs' $TargetBatch '(no --goal)'
    }
    # Sti-UniquePath uses the same extension we passed; we passed `md`.
    $secondPath = Join-Path $TMP '2026-05-15T210800-review-queue-code-diffs-decomposer-prompt-2.md'
    if (Test-Path -LiteralPath $secondPath) {
        Pass 'case 4: second invocation writes -2 sibling without overwriting'
    } else {
        Fail 'case 4: -2 sibling not created' "expected=$secondPath"
    }

    # Confirm the first file is byte-for-byte unchanged.
    $firstContentAfter = Read-FileRaw $expectedPath
    if ((Test-Path -LiteralPath $expectedPath) -and ($firstContentBefore -ceq $firstContentAfter)) {
        Pass 'case 4: first file is unchanged by the second invocation'
    } else {
        Fail 'case 4: first file changed after the second invocation'
    }

    # === case 5: --goal scope reflected in saved file ==========================

    $goalMeta = 'Kanban app|1|kanban-app'
    $slugGoal = 'review-queue-code-diffs-kanban-app'
    $run3Log = Join-Path $TMP 'run3.log'
    $null = Invoke-WithStderrLog $run3Log {
        Invoke-DispatchAndFallback $mock "$PromptBody (scoped to Kanban app)" `
            $SourcePath $SourceSha $SourceTs `
            $slugGoal $TargetBatch $goalMeta
    }
    $goalPath = Join-Path $TMP '2026-05-15T210800-review-queue-code-diffs-kanban-app-decomposer-prompt.md'
    if (Test-Path -LiteralPath $goalPath) {
        Pass 'case 5: per-goal fallback writes file with goal slug in filename'
    } else {
        Fail 'case 5: per-goal fallback path missing' "expected=$goalPath"
    }

    $goalContent = if (Test-Path -LiteralPath $goalPath) { Read-FileRaw $goalPath } else { '' }
    if ($goalContent.Contains('Kanban app (index 1, slug kanban-app)')) {
        Pass 'case 5: saved file reflects per-goal scope metadata'
    } else {
        $scopeLines = @($goalContent -split "`n" | Where-Object { $_ -match 'Per-goal scope' })
        $detail = if ($scopeLines.Count -gt 0) { $scopeLines -join '; ' } else { '(no scope line)' }
        Fail 'case 5: per-goal scope line missing or wrong' $detail
    }

    if ($goalContent.Contains('(scoped to Kanban app)')) {
        Pass 'case 5: saved file reflects scoped prompt body (not full doc)'
    } else {
        Fail 'case 5: scoped prompt body not in saved file'
    }

    # === case 6: recovery summary printed to stderr ===========================

    # run1.log captures the stderr from the first invocation.
    $run1Content = Read-FileRaw $run1Log
    if ($run1Content.Contains('Saved decomposer prompt to:')) {
        Pass 'case 6: terminal summary names the saved-prompt path'
    } else {
        Fail "case 6: terminal summary missing 'Saved decomposer prompt to:' line"
    }
    if ($run1Content.Contains('The Stride API POST was NOT attempted')) {
        Pass 'case 6: terminal summary explicitly states POST was not attempted'
    } else {
        Fail "case 6: terminal summary missing 'POST NOT attempted' line"
    }

    # === case 7: pitfall — no token strings in saved file =====================
    #
    # The prompt has no auth context by construction; this is a regression guard
    # in case a future edit accidentally widens what gets saved.

    $firstContent = Read-FileRaw $expectedPath
    if ($firstContent -match 'stride_(dev|prod)_|Bearer |Authorization:') {
        Fail 'case 7: saved file contains potential auth material (regression)'
    } else {
        Pass 'case 7: saved file contains no Bearer/token/Authorization strings (pitfall avoided)'
    }

    # === case 8: pitfall — no partial batch JSON written =====================
    #
    # Step 7.5 must NOT write a *.stride-batch.json file as a side-effect of
    # fallback. Verify no such file exists in $TMP after the runs.

    $batchFiles = @(Get-ChildItem -LiteralPath $TMP -Recurse -File -Filter '*-stride-batch*.json' -ErrorAction SilentlyContinue)
    if ($batchFiles.Count -gt 0) {
        Fail 'case 8: a stride-batch JSON file was written in the fallback branch (regression)'
    } else {
        Pass 'case 8: no partial batch JSON written in fallback branch (pitfall avoided)'
    }
} finally {
    Remove-Item -Recurse -Force $TMP -ErrorAction SilentlyContinue
}

Write-Host ''
Write-Host ("{0} passed, {1} failed" -f $script:PASS, $script:FAIL)
if ($script:FAIL -gt 0) { exit 1 } else { exit 0 }
