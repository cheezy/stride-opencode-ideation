# Tests for lib/ship.ps1, the PowerShell twin of lib/ship.sh.
#
# No network: the "Stride API" is a minimal HTTP/1.1 responder on a raw
# System.Net.Sockets.TcpListener bound to 127.0.0.1 in this test process (no
# HttpListener, so no Windows URL-ACL reservation or elevation is needed). Each case runs ship.ps1 in a CHILD pwsh (so its `exit`
# codes are real), the listener answers one request with a canned status and
# body, and the test records what was sent (method, path, Authorization
# header, payload) so it can assert on the request as well as the output.
# Every child gets its own TMPDIR so the tests can assert that no temp file
# outlives the script.
#
# Run:
#   pwsh -NoProfile -File lib/test-ship.ps1
#
# Exits 0 if all tests pass, non-zero otherwise.

Set-StrictMode -Version Latest

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Ship      = Join-Path $ScriptDir 'ship.ps1'
$PwshExe   = (Get-Process -Id $PID).Path

$script:PASS = 0
$script:FAIL = 0
function Pass([string]$msg) { $script:PASS++; Write-Host "  PASS  $msg" }
function Fail([string]$msg, [string]$detail = '') {
    $script:FAIL++
    Write-Host "  FAIL  $msg"
    if ($detail) { Write-Host "        $detail" }
}
function Check([string]$Label, [bool]$Cond, [string]$Detail = '') { if ($Cond) { Pass $Label } else { Fail $Label $Detail } }

# A fake value only — the tests assert it never escapes into output.
$Token = 'stride_dev_PS_SHIP_TEST_TOKEN_9f3k'

$root = Join-Path ([System.IO.Path]::GetTempPath()) "sti-ship-ps1-$([System.IO.Path]::GetRandomFileName())"
$tmp = Join-Path $root 'ship tests'
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
function J([string]$name) { Join-Path $tmp $name }

# A free loopback port for the fake API, and a closed one for transport failure.
function Get-FreePort {
    $l = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, 0)
    $l.Start(); $port = $l.LocalEndpoint.Port; $l.Stop()
    return $port
}
$port = Get-FreePort
$closedPort = Get-FreePort
$listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, $port)
$listener.Start()
$script:Pending = $null

# Read one HTTP/1.1 request from a socket: request line, headers, and a
# Content-Length body. Returns method, path, Authorization, Content-Type, body.
function Read-HttpRequest($Stream) {
    $buffer = New-Object System.IO.MemoryStream
    $chunk = New-Object byte[] 4096
    $headerEnd = -1
    while ($headerEnd -lt 0) {
        $n = $Stream.Read($chunk, 0, $chunk.Length)
        if ($n -le 0) { break }
        $buffer.Write($chunk, 0, $n)
        $text = [System.Text.Encoding]::ASCII.GetString($buffer.ToArray())
        $headerEnd = $text.IndexOf("`r`n`r`n")
    }
    $all = $buffer.ToArray()
    $head = [System.Text.Encoding]::ASCII.GetString($all, 0, [Math]::Max(0, $headerEnd))
    $lines = $head -split "`r`n"
    $parts = $lines[0] -split ' '
    $headers = @{}
    foreach ($h in ($lines | Select-Object -Skip 1)) {
        $i = $h.IndexOf(':')
        if ($i -gt 0) { $headers[$h.Substring(0, $i).Trim().ToLowerInvariant()] = $h.Substring($i + 1).Trim() }
    }
    $length = 0
    if ($headers.ContainsKey('content-length')) { $length = [int]$headers['content-length'] }
    $bodyBytes = New-Object System.IO.MemoryStream
    $already = $all.Length - ($headerEnd + 4)
    if ($already -gt 0) { $bodyBytes.Write($all, $headerEnd + 4, $already) }
    while ($bodyBytes.Length -lt $length) {
        $n = $Stream.Read($chunk, 0, $chunk.Length)
        if ($n -le 0) { break }
        $bodyBytes.Write($chunk, 0, $n)
    }
    $auth = $null; if ($headers.ContainsKey('authorization')) { $auth = $headers['authorization'] }
    $type = $null; if ($headers.ContainsKey('content-type')) { $type = $headers['content-type'] }
    return [pscustomobject]@{
        Method = $parts[0]
        Path   = ($parts[1] -split '\?')[0]
        Auth   = $auth
        Type   = $type
        Body   = [System.Text.Encoding]::UTF8.GetString($bodyBytes.ToArray())
    }
}

function Write-Auth([string]$Path, [string]$Url) {
    [System.IO.File]::WriteAllText($Path, "- **API URL:** ``$Url```n- **API Token:** ``$Token```n")
}
Write-Auth (J 'auth.md') "http://127.0.0.1:$port"
Write-Auth (J 'auth-closed.md') "http://127.0.0.1:$closedPort"

$batchJson = @'
{
  "source_spec": "docs/ideation/x-requirements.md",
  "source_spec_sha256": "0000000000000000000000000000000000000000000000000000000000000000",
  "decomposition_notes": "single goal",
  "goals": [
    {"title": "Goal one", "type": "goal", "created_by_agent": "Claude Opus 5.5",
     "tasks": [{"title": "Task one", "type": "work"}, {"title": "Task two", "type": "defect"}]}
  ]
}
'@
[System.IO.File]::WriteAllText((J 'batch.json'), $batchJson)
$created = '{"success": true, "total": 1, "goals": [{"goal": {"id": 1, "identifier": "G77", "title": "Goal one", "type": "goal"}, "child_tasks": [{"id": 2, "identifier": "W901", "title": "Task one"}, {"id": 3, "identifier": "D12", "title": "Task two"}]}]}'
$createdFlat = '{"data": {"goals": [{"identifier": "G78", "title": "Flat goal", "tasks": [{"identifier": "W902", "title": "Flat task"}]}]}}'

# Invoke-Ship <case> <args> [-Code n] [-Body s] [-Auth file] — runs ship.ps1 in
# a child pwsh. When -Code is given, the listener answers one request with it.
# Sets $script:Rc, Out, Err, Req (method, path, auth, body or $null), TmpDir.
function Invoke-Ship {
    param([string]$Case, [string[]]$ShipArgs, [int]$Code = 0, [string]$Body = '', [string]$Auth = (J 'auth.md'), [switch]$Bom)
    $script:TmpDir = J "tmp-$Case"
    New-Item -ItemType Directory -Force -Path $script:TmpDir | Out-Null
    if (-not $script:Pending) { $script:Pending = $listener.AcceptTcpClientAsync() }
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $PwshExe
    $quoted = @('-NoProfile', '-NonInteractive', '-File', ('"' + $Ship + '"')) + @($ShipArgs | ForEach-Object { '"' + $_ + '"' })
    $psi.Arguments = $quoted -join ' '
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.WorkingDirectory = $tmp
    $psi.EnvironmentVariables['STRIDE_AUTH_FILE'] = $Auth
    $psi.EnvironmentVariables['TMPDIR'] = $script:TmpDir
    $psi.EnvironmentVariables['TMP'] = $script:TmpDir
    $psi.EnvironmentVariables['TEMP'] = $script:TmpDir
    $p = [System.Diagnostics.Process]::Start($psi)
    $outTask = $p.StandardOutput.ReadToEndAsync()
    $errTask = $p.StandardError.ReadToEndAsync()
    $script:Req = $null
    $deadline = [DateTime]::UtcNow.AddSeconds(60)
    while (-not $p.HasExited -and [DateTime]::UtcNow -lt $deadline) {
        if ($script:Pending.Wait(100)) {
            $conn = $script:Pending.Result
            $script:Pending = $listener.AcceptTcpClientAsync()
            $stream = $conn.GetStream()
            $script:Req = Read-HttpRequest $stream
            $status = 200
            if ($Code) { $status = $Code }
            $bytes = [System.Text.Encoding]::UTF8.GetBytes($Body)
            if ($Bom) { $bytes = [byte[]](0xEF, 0xBB, 0xBF) + $bytes }
            $head = "HTTP/1.1 $status Canned`r`nContent-Type: application/json`r`nContent-Length: $($bytes.Length)`r`nConnection: close`r`n"
            if ($status -ge 300 -and $status -lt 400) { $head += "Location: http://127.0.0.1:1/elsewhere`r`n" }
            $headBytes = [System.Text.Encoding]::ASCII.GetBytes($head + "`r`n")
            $stream.Write($headBytes, 0, $headBytes.Length)
            $stream.Write($bytes, 0, $bytes.Length)
            $stream.Flush()
            $conn.Close()
        }
    }
    $p.WaitForExit()
    $script:Rc = $p.ExitCode
    $script:Out = $outTask.Result
    $script:Err = $errTask.Result
}
function Rc-Is([string]$Label, [int]$Want) { Check $Label ($Rc -eq $Want) "exit $Rc, want $Want; stderr: $($Err.Substring(0, [Math]::Min(300, $Err.Length)))" }
function Has([string]$Label, [string]$Text, [string]$Needle) { Check $Label ($Text.Contains($Needle)) "missing [$Needle]" }
function Lacks([string]$Label, [string]$Text, [string]$Needle) { Check $Label (-not $Text.Contains($Needle)) "found [$Needle]" }
function No-TokenAnywhere([string]$Label) { Check $Label (-not ("$Out$Err").Contains($Token)) 'token found in stdout or stderr' }
function No-TempLeft([string]$Label) {
    $left = @(Get-ChildItem -Force -LiteralPath $TmpDir | ForEach-Object { $_.Name })
    if ($left.Count -eq 0) { Pass $Label } else { Fail $Label ('left behind: ' + ($left -join ', ')) }
}
function No-Request([string]$Label) {
    if ($null -eq $Req) { Pass $Label } else { Fail $Label "a request was sent: $($Req.Method) $($Req.Path)" }
}

Write-Host 'test-ship.ps1 — exercises lib/ship.ps1 against a local fake API'
Write-Host ''

try {
    # --- usage -----------------------------------------------------------------
    Invoke-Ship 'usage' @()
    Rc-Is 'ship: no argument is a usage error (exit 2)' 2
    Has 'ship: usage error names every form' $Err 'ship.ps1 --check-auth | ship.ps1 --check-payload <batch.json> | ship.ps1 <batch.json>'
    Invoke-Ship 'missing' @((J 'does-not-exist.json'))
    Rc-Is 'ship: a missing batch file exits 1' 1
    Has 'ship: a missing batch file is named' $Err 'batch JSON not found at'
    No-Request 'ship: a missing batch file never reaches the API'

    # --- --check-auth ------------------------------------------------------------
    Invoke-Ship 'check-ok' @('--check-auth')
    Rc-Is 'check-auth: a readable auth file exits 0' 0
    Has 'check-auth: names the auth file and URL' $Out 'auth file OK'
    No-TokenAnywhere 'check-auth: the token is not printed'
    No-Request 'check-auth: makes no request'
    Invoke-Ship 'check-missing' @('--check-auth') -Auth (J 'no-such-auth.md')
    Rc-Is 'check-auth: a missing auth file exits 1' 1
    Has 'check-auth: says the auth could not be read' $Err 'failed to read auth from'

    # --- 2xx -------------------------------------------------------------------------
    $beforeBatch = [System.IO.File]::ReadAllText((J 'batch.json'))
    Invoke-Ship 'ok' @((J 'batch.json')) -Code 201 -Body $created
    Rc-Is '2xx: exits 0' 0
    Has '2xx: renders the goal identifier' $Out 'G77'
    Has '2xx: renders the task identifiers' $Out 'W901'
    Has '2xx: says the batch shipped' $Out 'Batch shipped successfully.'
    No-TokenAnywhere '2xx: the token is absent from stdout and stderr'
    Check '2xx: POSTs to the batch endpoint' (($null -ne $Req) -and ($Req.Method -eq 'POST') -and ($Req.Path -eq '/api/tasks/batch'))
    Check '2xx: sends the bearer token in the Authorization header' (($null -ne $Req) -and ($Req.Auth -ceq "Bearer $Token"))
    Check '2xx: sends JSON' (($null -ne $Req) -and ($Req.Type -like 'application/json*'))
    Check '2xx: source_spec is stripped from the payload' (($null -ne $Req) -and -not $Req.Body.Contains('source_spec'))
    Check '2xx: decomposition_notes is stripped from the payload' (($null -ne $Req) -and -not $Req.Body.Contains('decomposition_notes'))
    Check '2xx: created_by_agent survives the strip' (($null -ne $Req) -and $Req.Body.Contains('"created_by_agent": "Claude Opus 5.5"'))
    Check '2xx: the on-disk batch JSON is not modified' ([System.IO.File]::ReadAllText((J 'batch.json')) -ceq $beforeBatch)
    No-TempLeft '2xx: every temp file is removed'

    Invoke-Ship 'flat' @((J 'batch.json')) -Code 201 -Body $createdFlat
    Rc-Is '2xx flat shape: exits 0' 0
    Has '2xx flat shape: renders the flat identifiers' $Out 'G78'

    Invoke-Ship 'bom' @((J 'batch.json')) -Code 201 -Body $created -Bom
    Rc-Is '2xx with a UTF-8 BOM: exits 0' 0
    Has '2xx with a UTF-8 BOM: still renders the identifiers' $Out 'G77'

    Invoke-Ship 'notjson' @((J 'batch.json')) -Code 201 -Body 'OK, but this is not JSON'
    Rc-Is '2xx non-JSON: exits 0 (the batch was created)' 0
    Has '2xx non-JSON: prints the do-not-re-run notice' $Err 'do NOT re-run /stridify'
    Has '2xx non-JSON: prints the body verbatim' $Err 'OK, but this is not JSON'
    No-TempLeft '2xx non-JSON: every temp file is removed'

    Invoke-Ship 'emptygoals' @((J 'batch.json')) -Code 201 -Body '{"success": true, "total": 0, "goals": []}'
    Rc-Is '2xx listing no goals: exits 0' 0
    Has '2xx listing no goals: says no goals were listed' $Err 'listed no created goals'

    # --- non-2xx ---------------------------------------------------------------
    Invoke-Ship '422' @((J 'batch.json')) -Code 422 -Body '{"error":"Validation failed","details":{"goals":["is invalid"]}}'
    Rc-Is '422: exits 1' 1
    Has '422: says Stride rejected the batch' $Err 'Stride API rejected the batch (HTTP 422)'
    Has '422: prints the body verbatim' $Err '{"error":"Validation failed","details":{"goals":["is invalid"]}}'
    No-TempLeft '422: every temp file is removed'

    Invoke-Ship '502' @((J 'batch.json')) -Code 502 -Body '<html>Bad gateway</html>'
    Rc-Is '502: exits 1' 1
    Has '502: names the status' $Err 'Stride API returned HTTP 502'
    Has '502: prints the body verbatim' $Err '<html>Bad gateway</html>'

    Invoke-Ship 'debug500' @((J 'batch.json')) -Code 500 -Body "<html><dd>Bearer $Token</dd><p>raw $Token</p><p>other Bearer abc.DEF-123</p></html>"
    Rc-Is '500 debug page: exits 1' 1
    No-TokenAnywhere '500 debug page: the echoed token is scrubbed'
    Has '500 debug page: credentials become [REDACTED]' $Err '[REDACTED]'
    Lacks "500 debug page: another Bearer value is scrubbed too" $Err 'abc.DEF-123'

    Invoke-Ship '302' @((J 'batch.json')) -Code 302 -Body '<html>moved</html>'
    Rc-Is '302: exits 1' 1
    Has '302: reports an unexpected status' $Err 'unexpected HTTP status 302'

    Invoke-Ship 'transport' @((J 'batch.json')) -Auth (J 'auth-closed.md')
    Rc-Is 'transport failure: exits 1' 1
    Has 'transport failure: says the request failed before the API responded' $Err 'HTTP request failed before the Stride API responded'
    No-TokenAnywhere 'transport failure: the token is not printed'
    No-TempLeft 'transport failure: every temp file is removed'

    # --- failures before any request -----------------------------------------------
    $doc = $batchJson | ConvertFrom-Json
    $doc.goals[0].tasks[0] | Add-Member -NotePropertyName description -NotePropertyValue "auth is $Token"
    [System.IO.File]::WriteAllText((J 'token-batch.json'), ($doc | ConvertTo-Json -Depth 10))
    Invoke-Ship 'tokenbatch' @((J 'token-batch.json')) -Code 201 -Body $created
    Rc-Is 'token in batch: exits 1' 1
    Has 'token in batch: says nothing was sent' $Err 'nothing was sent'
    No-Request 'token in batch: nothing is POSTed'
    No-TokenAnywhere 'token in batch: the token is not printed'

    [System.IO.File]::WriteAllText((J 'invalid-batch.json'), '{"goals": []}')
    Invoke-Ship 'invalidbatch' @((J 'invalid-batch.json')) -Code 201 -Body $created
    Rc-Is 'invalid batch: exits 1' 1
    Has 'invalid batch: says nothing was sent' $Err 'failed validation; nothing was sent'
    No-Request 'invalid batch: nothing is POSTed'

    # --- --check-payload ----------------------------------------------------------
    $notes = $batchJson | ConvertFrom-Json
    $notes.decomposition_notes = "pasted from a transcript: $Token"
    [System.IO.File]::WriteAllText((J 'notes-token.json'), ($notes | ConvertTo-Json -Depth 10))
    Invoke-Ship 'cp-token' @('--check-payload', (J 'notes-token.json'))
    Rc-Is 'check-payload: a token in decomposition_notes is refused (exit 1)' 1
    Has 'check-payload: says nothing was shown or sent' $Err 'nothing was shown or sent'
    No-TokenAnywhere 'check-payload: the token is not printed'
    No-Request 'check-payload: makes no request'
    Invoke-Ship 'cp-clean' @('--check-payload', (J 'batch.json'))
    Rc-Is 'check-payload: a clean batch passes (exit 0)' 0
    Invoke-Ship 'cp-dash' @('--check-payload', '-x.json')
    Rc-Is "check-payload: a path starting with '-' is a usage error" 2

    # --- the token check fails closed -------------------------------------------
    $onWindows = [System.Environment]::OSVersion.Platform -eq 'Win32NT'
    if (-not $onWindows) {
        Copy-Item -LiteralPath (J 'batch.json') -Destination (J 'unreadable.json')
        & chmod 000 (J 'unreadable.json')
        Invoke-Ship 'cp-unreadable' @('--check-payload', (J 'unreadable.json'))
        & chmod 600 (J 'unreadable.json')
        Rc-Is 'check-payload: a failed token check refuses (exit 1)' 1
        Has 'check-payload: says the file could not be checked' $Err 'could not check'
    } else {
        Pass 'check-payload: a failed token check refuses (exit 1) (skipped on Windows)'
        Pass 'check-payload: says the file could not be checked (skipped on Windows)'
    }
    # Module Logging (event 4103) records the arguments bound to every
    # cmdlet and function, so the token may only appear in these shapes: an
    # assignment from a plain variable or $null, a truthiness test, a pipe to
    # a native python helper on stdin, or a .NET ::new() call.
    $allowed = @(
        '^\s*\$script:Token = (\$null|\$tokenValue)\s*$',
        '-not \$script:Token\b',
        '^\s*\$script:Token \| & \$Python ',
        '::new\(''Bearer'', \$script:Token\)',
        '^\s*\$tokenValue = (\$Matches\[1\]|\$null)\s*$',
        '^\s*if \(\$tokenValue\.Length -ge 2 -and \$tokenValue\.StartsWith\("''"\) -and \$tokenValue\.EndsWith\("''"\)\) \{\s*$',
        '^\s*\$tokenValue = \$tokenValue\.Substring\(1, \$tokenValue\.Length - 2\)\.Replace\('
    )
    function Test-TokenLineAllowed([string]$Line) {
        if ($Line.TrimStart().StartsWith('#')) { return $true }
        if ($Line -notmatch '\$script:Token|\$tokenValue') { return $true }
        foreach ($a in $allowed) { if ($Line -match $a) { return $true } }
        return $false
    }
    $tokenLines = @(Select-String -LiteralPath $Ship -Pattern '\$script:Token|\$tokenValue' | Where-Object { -not (Test-TokenLineAllowed $_.Line) })
    Check 'ship.ps1: the token never goes through a cmdlet or function parameter (Module Logging)' ($tokenLines.Count -eq 0) (($tokenLines | ForEach-Object { "$($_.LineNumber): $($_.Line.Trim())" }) -join ' | ')
    $mutations = @(
        '            $tokenValue = ConvertFrom-ShellQuoted $Matches[1]',
        '            $script:Token = ConvertFrom-ShellQuoted $tokenValue',
        '        $h = New-Object System.Net.Http.Headers.AuthenticationHeaderValue(''Bearer'', $script:Token)',
        '    Write-Host $script:Token'
    )
    $missed = @($mutations | Where-Object { Test-TokenLineAllowed $_ })
    Check 'the Module Logging guard rejects a function, cmdlet or host call on the token' ($missed.Count -eq 0) ($missed -join ' | ')

    # Windows PowerShell 5.1 reads a BOM-less script in the ANSI code page: a
    # UTF-8 em dash becomes bytes that can end a string literal early. Every
    # lib/*.ps1 must parse exactly as 5.1 would read it.
    $ansi = [System.Text.Encoding]::GetEncoding(1252)
    $badParse = @()
    foreach ($f in (Get-ChildItem -LiteralPath $ScriptDir -Filter '*.ps1')) {
        $bytes = [System.IO.File]::ReadAllBytes($f.FullName)
        if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
            $text = [System.Text.Encoding]::UTF8.GetString($bytes, 3, $bytes.Length - 3)
        } else {
            $text = $ansi.GetString($bytes)
        }
        $tokens = $null; $errors = $null
        [void][System.Management.Automation.Language.Parser]::ParseInput($text, [ref]$tokens, [ref]$errors)
        if ($errors.Count -gt 0) { $badParse += $f.Name }
    }
    Check 'every lib/*.ps1 parses the way Windows PowerShell 5.1 reads it (BOM or ASCII)' ($badParse.Count -eq 0) ($badParse -join ', ')

    # --- unparseable batch ----------------------------------------------------------
    [System.IO.File]::WriteAllText((J 'broken.json'), '{"goals": [')
    Invoke-Ship 'badpayload' @((J 'broken.json')) -Code 201 -Body $created
    Rc-Is 'unparseable batch: exits 1' 1
    Has 'unparseable batch: names the payload failure' $Err 'failed to prepare API payload from'
    No-Request 'unparseable batch: nothing is POSTed'
    No-TokenAnywhere 'unparseable batch: token is not printed'
    No-TempLeft 'unparseable batch: every temp file is removed'

    # --- /stridify --batch: a hand-written batch -----------------------------------
    $hand = $batchJson | ConvertFrom-Json
    $hand.PSObject.Properties.Remove('source_spec')
    $hand.PSObject.Properties.Remove('source_spec_sha256')
    $hand.PSObject.Properties.Remove('decomposition_notes')
    [System.IO.File]::WriteAllText((J 'hand-batch.json'), ($hand | ConvertTo-Json -Depth 10))
    $beforeHand = [System.IO.File]::ReadAllText((J 'hand-batch.json'))
    Invoke-Ship 'handbatch' @((J 'hand-batch.json')) -Code 201 -Body $created
    Rc-Is '--batch: a hand-written batch with no audit fields ships (exit 0)' 0
    Has '--batch: a hand-written batch renders the created identifiers' $Out 'G77'
    Check '--batch: the batch file is shipped as-is, never rewritten' ([System.IO.File]::ReadAllText((J 'hand-batch.json')) -ceq $beforeHand)
} finally {
    $listener.Stop()
    Remove-Item -Recurse -Force -LiteralPath $root -ErrorAction SilentlyContinue
}

Write-Host ''
Write-Host ("{0} passed, {1} failed" -f $script:PASS, $script:FAIL)
if ($script:FAIL -gt 0) { exit 1 }
exit 0
