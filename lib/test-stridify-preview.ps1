# PowerShell mirror of test-stridify-preview.sh — exercises the
# /stridify Step 8.5 preview-and-approval gate and the Step 1
# --yes / --auto-approve bypass documented in
# commands/stridify.md (W1161; ports upstream G235/W1140).
#
# OpenCode's question UI is only available inside a live OpenCode session,
# so this test embeds a reference implementation of the documented flag parse +
# preview render + gate and exercises it against a fixture batch JSON. The human
# approve / decline answer is injected as a parameter (standing in for the
# prompt result). The reference implementations MUST stay consistent with
# Step 1 and Step 8.5 in commands/stridify.md and with the
# bash mirror lib/test-stridify-preview.sh — if you edit one, edit all.
#
# Run:
#   pwsh -File lib/test-stridify-preview.ps1
#
# Exits 0 if all tests pass, non-zero otherwise.

Set-StrictMode -Version Latest

$script:PASS = 0
$script:FAIL = 0
function Pass($m) { $script:PASS++; Write-Host "  PASS  $m" }
function Fail($m, $d = '') { $script:FAIL++; Write-Host "  FAIL  $m"; if ($d) { Write-Host "        $d" } }

Write-Host 'test-stridify-preview.ps1 — exercises the Step 8.5 preview gate + --yes bypass'
Write-Host ''

# --- reference --yes / --auto-approve parser -------------------------------
# Mirrors commands/stridify.md Step 1. Returns a hashtable @{ AutoApprove; Remainder }.
function Parse-YesFlag([string]$ArgString) {
    $tokens = @($ArgString -split '\s+' | Where-Object { $_ -ne '' })
    $yes = $false
    $rest = @()
    foreach ($t in $tokens) {
        if ($t -eq '--yes' -or $t -eq '--auto-approve') { $yes = $true }
        else { $rest += $t }
    }
    return @{ AutoApprove = $yes; Remainder = ($rest -join ' ') }
}

# --- reference preview render ----------------------------------------------
# Mirrors commands/stridify.md Step 8.5a. Reads ONLY the on-disk batch JSON (no auth
# material) and returns the goal/task tree + cross-goal claim order as text.
function Render-Preview([string]$BatchPath) {
    $data = Get-Content -LiteralPath $BatchPath -Raw | ConvertFrom-Json
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('') | Out-Null
    $lines.Add('Goals and tasks to be created:') | Out-Null
    $lines.Add('') | Out-Null
    foreach ($goal in @($data.goals)) {
        $title = if ($goal.PSObject.Properties['title'] -and $goal.title) { $goal.title } else { '(no title)' }
        $tasks = if ($goal.PSObject.Properties['tasks'] -and $goal.tasks) { @($goal.tasks) } else { @() }
        $n = $tasks.Count
        $plural = if ($n -ne 1) { 's' } else { '' }
        $lines.Add("  Goal: $title  ($n task$plural)") | Out-Null
        foreach ($task in $tasks) {
            $tt = if ($task.PSObject.Properties['title'] -and $task.title) { $task.title } else { '(no title)' }
            $lines.Add("    - $tt") | Out-Null
        }
    }
    $lines.Add('') | Out-Null
    $notes = if ($data.PSObject.Properties['decomposition_notes']) { $data.decomposition_notes } else { '' }
    if ($notes) {
        $lines.Add('Cross-goal claim order:') | Out-Null
        $lines.Add("  $notes") | Out-Null
        $lines.Add('') | Out-Null
    }
    return ($lines -join "`n")
}

# --- reference preview + gate ----------------------------------------------
# Mirrors commands/stridify.md Step 8.5 a/b/c. Writes the combined output to $LogPath. On
# bypass ($AutoApprove) or an explicit approve, writes the POST sentinel
# (proceed to Step 9) and returns 0. On decline it appends the clean-stop
# message and returns 10 WITHOUT writing the sentinel or touching the JSON.
function Render-AndGate([string]$BatchPath, [bool]$AutoApprove, [string]$Answer, [string]$SentinelPath, [string]$LogPath) {
    $out = New-Object System.Collections.Generic.List[string]
    $out.Add((Render-Preview $BatchPath)) | Out-Null
    if ($AutoApprove) {
        Set-Content -LiteralPath $SentinelPath -Value 'POST_ATTEMPTED'
        Set-Content -LiteralPath $LogPath -Encoding UTF8 -Value ($out -join "`n")
        return 0
    }
    if ($Answer -eq 'approve') {
        Set-Content -LiteralPath $SentinelPath -Value 'POST_ATTEMPTED'
        Set-Content -LiteralPath $LogPath -Encoding UTF8 -Value ($out -join "`n")
        return 0
    }
    $out.Add("stride-ideation: declined. The batch JSON is on disk at $BatchPath") | Out-Null
    $out.Add('(committed in git) for a later manual ship. No POST was attempted.') | Out-Null
    Set-Content -LiteralPath $LogPath -Encoding UTF8 -Value ($out -join "`n")
    return 10
}

# === temp dir + fixtures ===================================================

$tmpDir = Join-Path ([System.IO.Path]::GetTempPath()) ('stipreview_' + [System.IO.Path]::GetRandomFileName())
New-Item -ItemType Directory -Path $tmpDir | Out-Null

$batch = Join-Path $tmpDir '2026-05-12T120000-fixture-stride-batch.json'
Set-Content -LiteralPath $batch -Encoding UTF8 -Value @'
{
  "source_spec": "2026-05-12T120000-fixture-requirements.md",
  "source_spec_sha256": "0000000000000000000000000000000000000000000000000000000000000000",
  "decomposition_notes": "Claim Goal A (data layer) first; Goal B (UI) depends on A's API surface.",
  "goals": [
    {
      "title": "Goal A — data layer",
      "type": "goal",
      "tasks": [
        { "title": "Create the schema migration" },
        { "title": "Add the context module" }
      ]
    },
    {
      "title": "Goal B — UI layer",
      "type": "goal",
      "tasks": [
        { "title": "Wire the LiveView" }
      ]
    }
  ]
}
'@

$single = Join-Path $tmpDir '2026-05-12T120000-fixture-kanban-app-stride-batch.json'
Set-Content -LiteralPath $single -Encoding UTF8 -Value @'
{
  "source_spec": "2026-05-12T120000-fixture-requirements.md",
  "source_spec_sha256": "1111111111111111111111111111111111111111111111111111111111111111",
  "decomposition_notes": "Single-goal shape, no cross-goal coordination.",
  "goals": [
    {
      "title": "Kanban app — review queue",
      "type": "goal",
      "tasks": [
        { "title": "Add the review column" }
      ]
    }
  ]
}
'@

$sentinel = Join-Path $tmpDir 'post_was_attempted'
$shaBefore = (Get-FileHash -LiteralPath $batch -Algorithm SHA256).Hash

try {
    # === case 1: --yes / --auto-approve parse (both forms + absence) ========
    $rYes = Parse-YesFlag '--yes /path/to/doc.md'
    $rAuto = Parse-YesFlag '--auto-approve /path/to/doc.md'
    $rNone = Parse-YesFlag '/path/to/doc.md'
    if ($rYes.AutoApprove -eq $true -and $rAuto.AutoApprove -eq $true -and $rNone.AutoApprove -eq $false) {
        Pass 'case 1: --yes and --auto-approve set bypass=true; absence leaves bypass=false (AC3)'
    } else {
        Fail 'case 1: bypass flag parse wrong' "yes=$($rYes.AutoApprove) auto=$($rAuto.AutoApprove) none=$($rNone.AutoApprove)"
    }
    if ($rYes.Remainder -ceq '/path/to/doc.md' -and $rNone.Remainder -ceq '/path/to/doc.md') {
        Pass 'case 1: the flag token is consumed and REQUIREMENTS_PATH remainder is preserved'
    } else {
        Fail 'case 1: remainder wrong after flag consumption' "yes=[$($rYes.Remainder)] none=[$($rNone.Remainder)]"
    }

    # === case 2: bypass path reaches POST without an approval prompt (AC3) ===
    Remove-Item -Force $sentinel -ErrorAction SilentlyContinue
    $logBypass = Join-Path $tmpDir 'run_bypass.log'
    $rc = Render-AndGate $batch $true '' $sentinel $logBypass
    if ($rc -eq 0 -and (Test-Path -LiteralPath $sentinel)) {
        Pass 'case 2: --yes bypass proceeds to POST (sentinel set, rc 0)'
    } else {
        Fail 'case 2: bypass did not reach POST' "rc=$rc"
    }
    if (-not (Select-String -LiteralPath $logBypass -Pattern 'declined' -SimpleMatch -Quiet)) {
        Pass 'case 2: bypass path prints no decline / prompt text'
    } else {
        Fail 'case 2: bypass path unexpectedly printed decline text'
    }

    # === case 3: decline path does NOT POST and leaves JSON on disk (AC1/AC4) ===
    Remove-Item -Force $sentinel -ErrorAction SilentlyContinue
    $logDecline = Join-Path $tmpDir 'run_decline.log'
    $rc = Render-AndGate $batch $false 'decline' $sentinel $logDecline
    if ($rc -eq 10 -and -not (Test-Path -LiteralPath $sentinel)) {
        Pass 'case 3: decline does NOT attempt the POST (no sentinel)'
    } else {
        Fail 'case 3: decline attempted the POST (regression)' "rc=$rc"
    }
    if (Test-Path -LiteralPath $batch) {
        Pass 'case 3: declined batch JSON remains on disk'
    } else {
        Fail 'case 3: declined batch JSON was removed (regression)'
    }
    $shaAfter = (Get-FileHash -LiteralPath $batch -Algorithm SHA256).Hash
    if ($shaBefore -ceq $shaAfter) {
        Pass 'case 3: declined batch JSON is byte-for-byte unchanged (recovery artifact preserved)'
    } else {
        Fail 'case 3: declined batch JSON was rewritten (pitfall violated)'
    }
    if (Select-String -LiteralPath $logDecline -Pattern 'No POST was attempted' -SimpleMatch -Quiet) {
        Pass 'case 3: decline message states the POST was not attempted'
    } else {
        Fail "case 3: decline message missing 'No POST was attempted'"
    }

    # === case 4: approve path proceeds to POST (AC2) =======================
    Remove-Item -Force $sentinel -ErrorAction SilentlyContinue
    $logApprove = Join-Path $tmpDir 'run_approve.log'
    $rc = Render-AndGate $batch $false 'approve' $sentinel $logApprove
    if ($rc -eq 0 -and (Test-Path -LiteralPath $sentinel)) {
        Pass 'case 4: explicit approval proceeds to POST (sentinel set, rc 0)'
    } else {
        Fail 'case 4: approval did not reach POST' "rc=$rc"
    }

    # === case 5: render lists every goal and its task count (AC1) ==========
    $preview = Render-Preview $batch
    if ($preview -match 'Goal: Goal A — data layer  \(2 tasks\)' -and $preview -match 'Goal: Goal B — UI layer  \(1 task\)') {
        Pass 'case 5: preview lists each goal with its task count (singular/plural correct)'
    } else {
        Fail 'case 5: goal/task-count render wrong' $preview
    }
    if ($preview -match '- Create the schema migration' -and $preview -match '- Add the context module' -and $preview -match '- Wire the LiveView') {
        Pass 'case 5: preview lists every task title'
    } else {
        Fail 'case 5: task titles missing from render' $preview
    }

    # === case 6: render shows cross-goal claim order from decomposition_notes (AC1, edge case) ===
    if ($preview -match 'Cross-goal claim order:' -and $preview -match 'Claim Goal A \(data layer\) first') {
        Pass 'case 6: preview shows cross-goal claim order from decomposition_notes'
    } else {
        Fail 'case 6: cross-goal claim order missing from render' $preview
    }

    # === case 7: --goal scoped (single-goal) batch renders the one goal (edge case) ===
    $previewSingle = Render-Preview $single
    $goalCount = ([regex]::Matches($previewSingle, 'Goal: ')).Count
    if ($previewSingle -match 'Goal: Kanban app — review queue  \(1 task\)' -and $goalCount -eq 1) {
        Pass 'case 7: --goal scoped batch renders exactly the single scoped goal'
    } else {
        Fail 'case 7: single-goal render wrong' $previewSingle
    }

    # === case 8: pitfall — no token / auth material in any gate output =====
    $allOut = $preview + (Get-Content -Raw -LiteralPath $logBypass) + (Get-Content -Raw -LiteralPath $logDecline) + (Get-Content -Raw -LiteralPath $logApprove)
    if ($allOut -match 'stride_(dev|prod)_' -or $allOut -match 'Bearer ' -or $allOut -match 'Authorization:') {
        Fail 'case 8: gate output contains potential auth material (pitfall violated)'
    } else {
        Pass 'case 8: no Bearer/token/Authorization strings in preview or gate output (pitfall avoided)'
    }
} finally {
    Remove-Item -Recurse -Force $tmpDir -ErrorAction SilentlyContinue
}

Write-Host ''
Write-Host ("{0} passed, {1} failed" -f $script:PASS, $script:FAIL)
if ($script:FAIL -gt 0) { exit 1 } else { exit 0 }
