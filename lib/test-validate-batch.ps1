# PowerShell mirror of test-validate-batch.sh — unit tests for
# lib/validate_batch.py.
#
# Each test feeds a fixture JSON document to the validator and asserts the
# expected outcome (zero exit + no stderr for valid docs; non-zero exit with
# a matching error substring for invalid docs).
#
# Full-parity port: every assertion in test-validate-batch.sh has a 1:1
# counterpart here, with the same case labels in the same order. Error
# substrings contain []-style brackets, so matching uses ordinal .Contains()
# rather than -match/-like.
#
# Run:
#   pwsh -File lib/test-validate-batch.ps1
#
# Exits 0 on success, non-zero on failure. Prints one-line per-test status.

Set-StrictMode -Version Latest

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Validator = Join-Path $ScriptDir 'validate_batch.py'

$script:PASS = 0
$script:FAIL = 0
function Pass([string]$msg) { $script:PASS++; Write-Host "  PASS  $msg" }
function Fail([string]$msg, [string]$detail = '') {
    $script:FAIL++
    Write-Host "  FAIL  $msg"
    if ($detail) { Write-Host "        $detail" }
}

Write-Host 'test-validate-batch.ps1 — exercises validate_batch.py'
Write-Host ''

$TMP = Join-Path ([System.IO.Path]::GetTempPath()) "sti-validate-$(Get-Random)"
New-Item -ItemType Directory -Path $TMP | Out-Null

$errFile = Join-Path $TMP 'last.err'

function Get-LastErr {
    if (Test-Path -LiteralPath $errFile) {
        $raw = Get-Content -LiteralPath $errFile -Raw
        if ($null -ne $raw) { return $raw }
    }
    return ''
}

function Assert-Ok([string]$label, [string]$fixture) {
    # Validator must exit 0 with no stderr output.
    & python3 $Validator $fixture 2> $errFile | Out-Null
    if ($LASTEXITCODE -eq 0) {
        if ((Get-LastErr).Length -eq 0) {
            Pass $label
        } else {
            Fail $label "unexpected stderr: $(Get-LastErr)"
        }
    } else {
        Fail $label "exit code != 0; stderr: $(Get-LastErr)"
    }
}

function Assert-FailsWith([string]$label, [string]$fixture, [string]$needle) {
    # Validator must exit non-zero AND stderr must contain the substring.
    & python3 $Validator $fixture 2> $errFile | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Fail $label 'expected exit != 0 but got 0'
        return
    }
    if ((Get-LastErr).Contains($needle)) {
        Pass $label
    } else {
        Fail $label "expected substring: $needle; actual stderr: $(Get-LastErr)"
    }
}

function Write-Fixture([string]$name, [string]$content) {
    $path = Join-Path $TMP $name
    Set-Content -LiteralPath $path -Encoding UTF8 -Value $content
    return $path
}

try {
    # --- (a) parse_error -------------------------------------------------------

    $f = Write-Fixture 'parse_error.json' '{ this is not json'
    Assert-FailsWith '(a) parse error — invalid JSON exits with parse failure' `
        $f 'JSON parse failed'

    # --- (b) wrong_root_key ----------------------------------------------------

    $f = Write-Fixture 'wrong_root_tasks.json' '{"tasks": [{"title": "x"}]}'
    Assert-FailsWith "(b) wrong root key 'tasks' — dedicated error message" `
        $f "root key 'tasks' is the most common batch-API mistake"

    $f = Write-Fixture 'wrong_root_batch.json' '{"batch": []}'
    Assert-FailsWith "(b) wrong root key 'batch' — named in error" `
        $f "missing the required 'goals' array"

    # --- (c) empty_goals -------------------------------------------------------

    $f = Write-Fixture 'empty_goals.json' '{"goals": []}'
    Assert-FailsWith '(c) empty goals array exits with under-specification hint' `
        $f 'empty array'

    $f = Write-Fixture 'goals_not_array.json' '{"goals": {"title": "oops"}}'
    Assert-FailsWith '(c) goals as object — must be an array' `
        $f 'must be an array'

    # --- (d) goal_missing_field ------------------------------------------------

    $f = Write-Fixture 'missing_title.json' '{"goals": [{"type": "goal", "tasks": []}]}'
    Assert-FailsWith '(d) goal missing title — names the field' `
        $f "goals[0] is missing required field 'title'"

    $f = Write-Fixture 'missing_tasks.json' '{"goals": [{"title": "T", "type": "goal"}]}'
    Assert-FailsWith '(d) goal missing tasks — names the field' `
        $f "goals[0] is missing required field 'tasks'"

    $f = Write-Fixture 'empty_tasks.json' '{"goals": [{"title": "T", "type": "goal", "tasks": []}]}'
    Assert-FailsWith '(d) goal with empty tasks array fails' `
        $f 'goals[0].tasks is empty'

    # --- (e) bad_dependency_index ---------------------------------------------

    $f = Write-Fixture 'dep_out_of_range.json' @'
{
  "goals": [
    {
      "title": "Test goal",
      "type": "goal",
      "tasks": [
        {"title": "First", "type": "work", "dependencies": []},
        {"title": "Second", "type": "work", "dependencies": [5]}
      ]
    }
  ]
}
'@
    Assert-FailsWith '(e) dependency index out of range — names the failing path' `
        $f 'goals[0].tasks[1].dependencies references index 5 but goal only has 2 tasks'

    $f = Write-Fixture 'dep_forward_ref.json' @'
{
  "goals": [
    {
      "title": "Test goal",
      "type": "goal",
      "tasks": [
        {"title": "First", "type": "work", "dependencies": [1]},
        {"title": "Second", "type": "work", "dependencies": []}
      ]
    }
  ]
}
'@
    Assert-FailsWith '(e) forward-reference dependency fails' `
        $f 'must point to an earlier sibling'

    $f = Write-Fixture 'dep_self_ref.json' @'
{
  "goals": [
    {
      "title": "Test goal",
      "type": "goal",
      "tasks": [
        {"title": "First", "type": "work", "dependencies": [0]}
      ]
    }
  ]
}
'@
    Assert-FailsWith '(e) self-reference dependency fails' `
        $f 'must point to an earlier sibling'

    $f = Write-Fixture 'dep_negative.json' @'
{
  "goals": [
    {
      "title": "Test goal",
      "type": "goal",
      "tasks": [
        {"title": "First", "type": "work", "dependencies": [-1]}
      ]
    }
  ]
}
'@
    Assert-FailsWith '(e) negative dependency index fails' `
        $f 'is negative'

    # --- happy paths -----------------------------------------------------------

    $f = Write-Fixture 'valid_minimal.json' @'
{
  "decomposition_notes": "Single goal; no cross-goal deps.",
  "goals": [
    {
      "title": "Minimal goal",
      "type": "goal",
      "tasks": [
        {"title": "First task", "type": "work", "dependencies": []}
      ]
    }
  ]
}
'@
    Assert-Ok 'valid minimal document with one goal and one task' $f

    $f = Write-Fixture 'valid_chained_deps.json' @'
{
  "goals": [
    {
      "title": "Chained deps",
      "type": "goal",
      "tasks": [
        {"title": "First", "type": "work", "dependencies": []},
        {"title": "Second", "type": "work", "dependencies": [0]},
        {"title": "Third", "type": "work", "dependencies": [0, 1]}
      ]
    }
  ]
}
'@
    Assert-Ok 'valid document with chained sibling dependencies' $f

    $f = Write-Fixture 'valid_string_dep.json' @'
{
  "goals": [
    {
      "title": "String identifier dep",
      "type": "goal",
      "tasks": [
        {"title": "First", "type": "work", "dependencies": ["W47"]}
      ]
    }
  ]
}
'@
    Assert-Ok 'valid: string identifier dependencies are not bounds-checked' $f
} finally {
    Remove-Item -Recurse -Force $TMP -ErrorAction SilentlyContinue
}

Write-Host ''
Write-Host ("{0} passed, {1} failed" -f $script:PASS, $script:FAIL)
if ($script:FAIL -gt 0) { exit 1 } else { exit 0 }
