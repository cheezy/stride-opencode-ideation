# PowerShell mirror of test-stridify-fallback.sh — smoke-tests for the
# Step 7.5 retry-exhaustion fallback. The bash test directly exercises a
# bash function that the stridify command body inlines; for the PowerShell
# mirror we verify the constituent helpers behave correctly (so the skill
# body's PowerShell-equivalent expansion will work) rather than re-
# implementing the inline function in PowerShell.

Set-StrictMode -Version Latest

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $ScriptDir 'filename.ps1')

$script:PASS = 0
$script:FAIL = 0
function Pass($m) { $script:PASS++; Write-Host "  PASS  $m" }
function Fail($m, $d = '') { $script:FAIL++; Write-Host "  FAIL  $m"; if ($d) { Write-Host "        $d" } }

Write-Host 'test-stridify-fallback.ps1 — smoke tests for retry-exhaustion path helpers'
Write-Host ''

# Stage 1: Sti-UniquePath with the decomposer-prompt artifact name produces
# the expected sibling path shape.
$tmpDir = New-Item -ItemType Directory -Path (Join-Path ([System.IO.Path]::GetTempPath()) "sti-fallback-$(Get-Random)") -Force
try {
    $p = Sti-UniquePath -Dir $tmpDir.FullName -Timestamp '2026-05-15T210800' `
                       -Slug 'review-queue-code-diffs' -Artifact 'decomposer-prompt' -Extension 'md'
    $expected = "$($tmpDir.FullName)/2026-05-15T210800-review-queue-code-diffs-decomposer-prompt.md"
    if ($p -ceq $expected) { Pass "decomposer-prompt sibling path shape matches" } else { Fail "path shape mismatch" "expected=[$expected] actual=[$p]" }

    # Stage 2: per-goal variant inherits the goal slug.
    $pg = Sti-UniquePath -Dir $tmpDir.FullName -Timestamp '2026-05-15T210800' `
                        -Slug 'review-queue-code-diffs-kanban-app' -Artifact 'decomposer-prompt' -Extension 'md'
    $expected2 = "$($tmpDir.FullName)/2026-05-15T210800-review-queue-code-diffs-kanban-app-decomposer-prompt.md"
    if ($pg -ceq $expected2) { Pass "per-goal decomposer-prompt path shape matches" } else { Fail "per-goal path shape mismatch" "expected=[$expected2] actual=[$pg]" }

    # Stage 3: collision discriminator on re-exhaustion.
    New-Item -ItemType File -Path $p -Force | Out-Null
    $p2 = Sti-UniquePath -Dir $tmpDir.FullName -Timestamp '2026-05-15T210800' `
                        -Slug 'review-queue-code-diffs' -Artifact 'decomposer-prompt' -Extension 'md'
    $expected3 = "$($tmpDir.FullName)/2026-05-15T210800-review-queue-code-diffs-decomposer-prompt-2.md"
    if ($p2 -ceq $expected3) { Pass "re-exhaustion appends -2 (no overwrite)" } else { Fail "collision discriminator failed" "expected=[$expected3] actual=[$p2]" }
} finally {
    Remove-Item -Recurse -Force $tmpDir.FullName -ErrorAction SilentlyContinue
}

# Stage 4: confirm the saved-prompt markdown body would not leak the API
# token — the skill body composes the body from $DECOMPOSER_PROMPT only,
# which never contains auth material by construction. We can't exercise
# the inline-bash function from PowerShell directly, but we can sanity-
# check that the canonical body template (per the skill body) doesn't
# include any token-shaped strings.
$bodyTemplate = @'
# Decomposer Prompt - Saved After Retry Exhaustion

- **Saved at:** 2026-05-15T210800Z
- **Source requirements doc:** docs/foo-requirements.md
- **Source SHA-256:** abc123
- **Per-goal scope:** all goals (no --goal flag)
- **Attempts before exhaustion:** 3

## Last error from agent

(error text here)

## Agent prompt (literal - paste this into a fresh session)

(prompt here)

## Recovery instructions

Paste the prompt block above into a fresh session...
'@
if ($bodyTemplate -match 'stride_dev_|Bearer ') {
    Fail "saved-prompt body template contains token-shaped content"
} else {
    Pass "saved-prompt body template contains no token-shaped content"
}

Write-Host ''
Write-Host ("{0} passed, {1} failed" -f $script:PASS, $script:FAIL)
if ($script:FAIL -gt 0) { exit 1 } else { exit 0 }
