# PowerShell mirror of test-command-templates.sh — the static half: lints
# commands/ideate.md and commands/stridify.md for dollar-digit sequences
# (OpenCode's command expansion rewrites them with the user's arguments),
# <plugin-root> placeholders, the fresh-shell rule, and per-block helper
# sourcing and carried-forward values; proves each rule fires on a planted
# file; and checks both templates are unchanged by OpenCode's expansion.
#
# The fragments themselves are bash, so running them in fresh shells is
# covered by test-command-templates.sh only.
#
# Run:
#   pwsh -NoProfile -File lib/test-command-templates.ps1
#
# Exits 0 if all tests pass, non-zero otherwise.

Set-StrictMode -Version Latest

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Bundle    = Split-Path -Parent $ScriptDir
$Commands  = Join-Path $Bundle 'commands'

$script:PASS = 0
$script:FAIL = 0
function Pass([string]$msg) { $script:PASS++; Write-Host "  PASS  $msg" }
function Fail([string]$msg, [string]$detail = '') {
    $script:FAIL++
    Write-Host "  FAIL  $msg"
    if ($detail) { Write-Host "        $detail" }
}

if (-not (Test-Path (Join-Path $Commands 'ideate.md'))) {
    Write-Host 'SKIP  commands/ not found beside lib/ (run this from a checkout)'
    Write-Host ''
    Write-Host '0 passed, 0 failed'
    exit 0
}

$ResolverFirst = '# Find the helpers: the project install, then the global install, then a stride-opencode-ideation checkout.'
$Rule          = '**Every bash call is a fresh shell.**'
$AlwaysSet     = @('HOME', 'STI_ROOT', 'STI_LIB')
# OpenCode's @-reference pattern for command templates (1.16); a match naming
# one of this bundle's agents becomes an agent call at expansion time.
$FileRef       = '(?<![\w`])@(\.?[^\s`,.]*(?:\.[^\s`,.]+)*)'
# Which lib/*.sh defines each sti_ function, read from the helpers themselves.
$HelperFiles   = @{}
foreach ($f in (Get-ChildItem -LiteralPath (Join-Path $Bundle 'lib') -Filter '*.sh')) {
    foreach ($m in [regex]::Matches([System.IO.File]::ReadAllText($f.FullName), '(?m)^(sti_[a-z_]+)\(\)')) { $HelperFiles[$m.Groups[1].Value] = $f.Name }
}
$AgentNames    = @(Get-ChildItem -LiteralPath (Join-Path $Bundle 'agents') -Filter '*.md' | ForEach-Object { $_.BaseName })

function Get-Blocks([string[]]$Lines) {
    $result = @()
    $i = 0
    while ($i -lt $Lines.Count) {
        if ($Lines[$i] -match '^(\s*)```bash\s*$') {
            $indent = $Matches[1]
            $start = $i + 1
            $body = @()
            $j = $i + 1
            while (($j -lt $Lines.Count) -and ($Lines[$j].Trim() -ne '```')) {
                $l = $Lines[$j]
                if ($indent -and $l.StartsWith($indent)) { $l = $l.Substring($indent.Length) }
                $body += $l
                $j++
            }
            $result += ,@{ Start = $start; Body = $body }
            $i = $j
        }
        $i++
    }
    return $result
}

function Get-LintViolations([string]$Path) {
    $out = @()
    $text = [System.IO.File]::ReadAllText($Path)
    $lines = $text -split "`n"
    for ($n = 0; $n -lt $lines.Count; $n++) {
        if ($lines[$n] -match '\$\{?[0-9]') { $out += "${Path}:$($n + 1): dollar-digit sequence (OpenCode rewrites it)" }
        if ($lines[$n].Contains('<plugin-root>')) { $out += "${Path}:$($n + 1): <plugin-root> placeholder" }
        foreach ($m in [regex]::Matches($lines[$n], $FileRef)) {
            if ($AgentNames -contains $m.Groups[1].Value) { $out += "${Path}:$($n + 1): bare @$($m.Groups[1].Value) (OpenCode turns it into an agent call at expansion time)" }
        }
    }
    $ruleCount = ([regex]::Matches($text, [regex]::Escape($Rule))).Count
    if ($ruleCount -ne 1) { $out += "${Path}: the fresh-shell rule appears $ruleCount times, want 1" }
    foreach ($b in (Get-Blocks $lines)) {
        $where = "${Path}:$($b.Start)"
        $body = @($b.Body)
        if (($body.Count -eq 0) -or (-not $body[0].StartsWith('# Carried forward:'))) {
            $out += "${where}: block does not start with a ""# Carried forward:"" line"
            continue
        }
        $carriedLine = $body[0] -replace '\([^)]*\)', ''
        $carried = @([regex]::Matches($carriedLine, '\b[A-Z_][A-Z0-9_]*\b') | ForEach-Object { $_.Value })
        $joined = $body -join "`n"
        $resolverAt = -1
        for ($k = 0; $k -lt $body.Count; $k++) { if ($body[$k] -ceq $ResolverFirst) { $resolverAt = $k; break } }
        $usesLib = $joined.Contains('$STI_LIB')
        $stiCalls = @()
        for ($k = 0; $k -lt $body.Count; $k++) {
            foreach ($m in [regex]::Matches($body[$k], '\b(sti_[a-z_]+)\b')) { $stiCalls += ,@($k, $m.Groups[1].Value) }
        }
        if (($usesLib -or ($stiCalls.Count -gt 0)) -and ($resolverAt -lt 0)) { $out += "${where}: uses the helpers but has no resolver" }
        $sourced = @{}
        for ($k = 0; $k -lt $body.Count; $k++) {
            if ($body[$k] -match '^\s*\.\s+"\$STI_LIB/([a-z_]+\.sh)"') {
                if (-not $sourced.ContainsKey($Matches[1])) { $sourced[$Matches[1]] = $k }
                if (($resolverAt -lt 0) -or ($k -lt $resolverAt)) { $out += "${where}: sources $($Matches[1]) before resolving the helper dir" }
            }
        }
        foreach ($c in $stiCalls) {
            $need = 'an unknown helper file'
            if ($HelperFiles.ContainsKey($c[1])) { $need = $HelperFiles[$c[1]] }
            if ((-not $sourced.ContainsKey($need)) -or ($sourced[$need] -gt $c[0])) {
                $out += "${where}: calls $($c[1]) without sourcing $need earlier in the same block"
            }
        }
        $code = @($body | Select-Object -Skip 1 | Where-Object { -not $_.TrimStart().StartsWith('#') })
        $assigned = @{}
        foreach ($a in $AlwaysSet) { $assigned[$a] = $true }
        foreach ($l in $code) {
            foreach ($m in [regex]::Matches($l, '(?:^|[\s;(])([A-Z_][A-Z0-9_]*)=')) { $assigned[$m.Groups[1].Value] = $true }
            foreach ($m in [regex]::Matches($l, '\bread\s+(?:-r\s+)?([A-Z_][A-Z0-9_ ]*)')) {
                foreach ($v in ($m.Groups[1].Value -split '\s+')) { if ($v) { $assigned[$v] = $true } }
            }
        }
        foreach ($l in $code) {
            foreach ($m in [regex]::Matches($l, '\$\{?([A-Z_][A-Z0-9_]*)')) {
                $v = $m.Groups[1].Value
                if ((-not $assigned.ContainsKey($v)) -and ($carried -notcontains $v)) {
                    $out += "${where}: reads $v, which is neither assigned nor carried forward"
                }
            }
        }
        foreach ($v in $carried) {
            if (@('Carried', 'forward', 'none') -contains $v) { continue }
            if ($joined -notmatch (':\s+"\$\{' + $v + ':?\?')) { $out += "${where}: carried value $v has no check" }
        }
    }
    return ,$out
}

Write-Host 'test-command-templates.ps1 — lint of the command templates'
Write-Host ''

$tmp = Join-Path ([System.IO.Path]::GetTempPath()) "sti-templates-$([System.IO.Path]::GetRandomFileName())"
New-Item -ItemType Directory -Path $tmp | Out-Null

try {
    foreach ($f in @('ideate.md', 'stridify.md')) {
        $v = Get-LintViolations (Join-Path $Commands $f)
        if ($v.Count -eq 0) { Pass "lint: commands/$f is clean" }
        else { Fail "lint: commands/$f has violations" (($v | Select-Object -First 5) -join ' | ') }
    }

    $ideateLines = @(Get-Content -LiteralPath (Join-Path $Commands 'ideate.md'))
    $at = [array]::IndexOf($ideateLines, $ResolverFirst)
    $resolverText = ($ideateLines[$at..($at + 5)]) -join "`n"
    function Plant([string]$Name, [string]$Body) {
        $p = Join-Path $tmp "$Name.md"
        [System.IO.File]::WriteAllText($p, "$Rule`n`n" + '```bash' + "`n$Body`n" + '```' + "`n")
        return $p
    }
    function Expect-Caught([string]$Label, [string]$Needle, [string]$Path) {
        $v = Get-LintViolations $Path
        if (($v.Count -gt 0) -and (($v -join "`n").Contains($Needle))) { Pass $Label }
        else { Fail $Label ("lint said: " + ($v -join ' | ')) }
    }

    Write-Host ''
    Write-Host 'The lint catches planted defects'
    Expect-Caught 'lint: catches an awk positional field' 'dollar-digit' (Plant 'dollar' ("# Carried forward: none`nprintf x | awk '{print " + '$' + "1}'"))
    Expect-Caught 'lint: catches a braced positional parameter' 'dollar-digit' (Plant 'braced' ("# Carried forward: none`necho " + '"${2}"'))
    Expect-Caught 'lint: catches a backslash-escaped one too' 'dollar-digit' (Plant 'escaped' ("# Carried forward: none`necho " + '"\$1"'))
    Expect-Caught 'lint: catches <plugin-root>' '<plugin-root>' (Plant 'placeholder' "# Carried forward: none`n. <plugin-root>/lib/filename.sh")
    Expect-Caught 'lint: catches a helper call with no source in the block' 'without sourcing filename.sh' (Plant 'nosource' ("# Carried forward: TOPIC`n" + ': "${TOPIC?x}"' + "`n$resolverText`n" + 'SLUG="$(sti_slugify "$TOPIC")"'))
    Expect-Caught 'lint: catches a draft helper sourced from the wrong file' 'without sourcing draft.sh' (Plant 'wrongsource' ("# Carried forward: SLUG`n" + ': "${SLUG?x}"' + "`n$resolverText`n" + '. "$STI_LIB/filename.sh" || exit 1' + "`n" + 'sti_draft_find .stride "$SLUG"'))
    Expect-Caught 'lint: catches a block with no resolver' 'has no resolver' (Plant 'noresolver' ("# Carried forward: none`n" + '. "$STI_LIB/filename.sh" || exit 1' + "`nsti_slugify x"))
    Expect-Caught 'lint: catches a value read but never carried forward' 'reads TARGET_PATH' (Plant 'uncarried' ("# Carried forward: none`n" + 'echo "$TARGET_PATH"'))
    Expect-Caught 'lint: catches a carried value with no check' 'has no check' (Plant 'unchecked' ("# Carried forward: SLUG`n" + 'echo "$SLUG"'))
    Expect-Caught 'lint: catches a block with no Carried forward line' 'Carried forward' (Plant 'nocarry' 'echo hi')
    $atRef = Join-Path $tmp 'atref.md'
    [System.IO.File]::WriteAllText($atRef, "$Rule`n`nThen dispatch @requirements-decomposer with the prompt.`n")
    Expect-Caught 'lint: catches a bare @agent reference' 'bare @requirements-decomposer' $atRef
    $atOk = Join-Path $tmp 'atref-ok.md'
    [System.IO.File]::WriteAllText($atOk, "$Rule`n`nNever use ``@requirements-decomposer``; call the task tool.`n")
    if ((Get-LintViolations $atOk).Count -eq 0) { Pass 'lint: a backticked @agent name is left alone' }
    else { Fail 'lint: a backticked @agent name is left alone' }
    $noRule = Join-Path $tmp 'norule.md'
    [System.IO.File]::WriteAllText($noRule, '```bash' + "`n# Carried forward: none`necho hi`n" + '```' + "`n")
    Expect-Caught 'lint: catches a file without the fresh-shell rule' 'appears 0 times' $noRule

    Write-Host ''
    Write-Host "OpenCode's template expansion leaves the files unchanged"
    $argv = @('docs/x-requirements.md', '--goal', '2')
    foreach ($f in @('ideate.md', 'stridify.md')) {
        $orig = [System.IO.File]::ReadAllText((Join-Path $Commands $f))
        $expanded = [regex]::Replace($orig, '\$(\d+)', {
            param($m)
            $i = [int]$m.Groups[1].Value
            if (($i -ge 1) -and ($i -le $argv.Count)) { $argv[$i - 1] } else { '' }
        })
        if ($expanded -ceq $orig) { Pass "expansion: $f is unchanged by expanding with 'docs/x-requirements.md --goal 2'" }
        else { Fail "expansion: $f changed under expansion" }
    }
} finally {
    Remove-Item -Recurse -Force -LiteralPath $tmp -ErrorAction SilentlyContinue
}

Write-Host ''
Write-Host ("{0} passed, {1} failed" -f $script:PASS, $script:FAIL)
if ($script:FAIL -gt 0) { exit 1 }
exit 0
