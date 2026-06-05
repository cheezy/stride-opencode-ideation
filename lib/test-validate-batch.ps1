# PowerShell mirror of test-validate-batch.sh — exercises validate_batch.py
# against known-good and known-broken JSON inputs.

Set-StrictMode -Version Latest

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$PluginRoot = Split-Path -Parent $ScriptDir
$Validator = Join-Path $ScriptDir 'validate_batch.py'

$script:PASS = 0
$script:FAIL = 0
function Pass($m) { $script:PASS++; Write-Host "  PASS  $m" }
function Fail($m, $d = '') { $script:FAIL++; Write-Host "  FAIL  $m"; if ($d) { Write-Host "        $d" } }

Write-Host 'test-validate-batch.ps1 — exercises validate_batch.py'
Write-Host ''

function Invoke-Validator([string]$JsonText) {
    $tmp = New-TemporaryFile
    Set-Content -LiteralPath $tmp.FullName -Value $JsonText -Encoding UTF8
    $errFile = New-TemporaryFile
    $stdout = & python3 $Validator $tmp.FullName 2>$errFile.FullName
    $rc = $LASTEXITCODE
    $errText = Get-Content -Raw -LiteralPath $errFile.FullName -ErrorAction SilentlyContinue
    Remove-Item -Force $tmp.FullName, $errFile.FullName -ErrorAction SilentlyContinue
    return @{ rc = $rc; stderr = $errText }
}

# Stage 1: a well-formed minimal batch passes.
$ok = @'
{"goals": [{"title": "Test goal", "type": "goal", "tasks": [{"title": "T1", "type": "work"}]}]}
'@
$r = Invoke-Validator $ok
if ($r.rc -eq 0) { Pass "well-formed batch accepted" } else { Fail "well-formed batch rejected" $r.stderr }

# Stage 2: malformed JSON triggers parse_error.
$r = Invoke-Validator 'not json at all {{'
if ($r.rc -ne 0 -and ($r.stderr -match 'parse|JSON')) { Pass "parse_error reported on bad JSON" } else { Fail "parse_error not detected" $r.stderr }

# Stage 3: wrong root key (tasks instead of goals) reports the common mistake.
$wrongRoot = '{"tasks": [{"title": "x", "type": "work"}]}'
$r = Invoke-Validator $wrongRoot
if ($r.rc -ne 0 -and ($r.stderr -match "(?i)root.*key|tasks|goals")) {
    Pass "wrong_root_key detected"
} else {
    Fail "wrong_root_key not detected" $r.stderr
}

# Stage 4: empty goals array.
$r = Invoke-Validator '{"goals": []}'
if ($r.rc -ne 0 -and ($r.stderr -match "empty|goals")) { Pass "empty_goals detected" } else { Fail "empty_goals not detected" $r.stderr }

# Stage 5: goal missing required field (title).
$missingField = '{"goals": [{"type": "goal", "tasks": []}]}'
$r = Invoke-Validator $missingField
if ($r.rc -ne 0 -and ($r.stderr -match "title|required|missing")) {
    Pass "goal_missing_field detected"
} else {
    Fail "goal_missing_field not detected" $r.stderr
}

# Stage 6: bad dependency index (forward reference).
$badDep = @'
{"goals": [{"title": "G", "type": "goal", "tasks": [
    {"title": "T1", "type": "work", "dependencies": [5]}
]}]}
'@
$r = Invoke-Validator $badDep
if ($r.rc -ne 0 -and ($r.stderr -match "dependency|dependencies|index|references")) {
    Pass "bad_dependency_index detected"
} else {
    Fail "bad_dependency_index not detected" $r.stderr
}

Write-Host ''
Write-Host ("{0} passed, {1} failed" -f $script:PASS, $script:FAIL)
if ($script:FAIL -gt 0) { exit 1 } else { exit 0 }
