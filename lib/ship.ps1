# stride-ideation: ship a validated batch JSON to Stride in ONE process —
# the PowerShell twin of lib/ship.sh, with the same modes, messages and exit
# codes.
#
# Usage:
#   pwsh -NoProfile -File lib/ship.ps1 --check-auth
#       Step 3 preflight: read auth, POST nothing
#   pwsh -NoProfile -File lib/ship.ps1 --check-payload <batch.json>
#       /stridify --batch: refuse a file that contains the token, POST nothing
#   pwsh -NoProfile -File lib/ship.ps1 <batch.json>
#       Steps 9-10: strip, POST, branch, render
#
# Auth file: $env:STRIDE_AUTH_FILE if set, else .stride_auth.md at the git
# toplevel of the working directory, or in the current directory outside a
# git repository.
#
# The token lives only in this process's memory:
#   - never on any process's argv: lib/read_auth.py prints it to this script's
#     captured stdout, and every python helper that needs it reads it on stdin;
#   - the POST is made in-process by System.Net.Http.HttpClient with the
#     header set on the request object, never logged, and with redirects
#     disabled so the header can never follow a 3xx to another host;
#   - every response body or transport message printed is first scrubbed of
#     the token and of any "Bearer <value>" (lib/ship_support.py scrub);
#   - every temp file (payload, response) is removed in a finally block.
#
# Exit codes:
#   0  shipped (2xx) — including a 2xx whose body could not be rendered, which
#      prints a do-not-re-run notice: the batch exists, re-running would
#      create it twice
#   1  auth unreadable, payload unpreparable, transport failure, or non-2xx
#   2  usage error
#
# The POST is never retried: Stride does not guarantee idempotency on a
# partially-failed batch.
#
# Windows PowerShell 5.1 compatible: no ternary, no null-coalescing,
# two-argument Join-Path only.

# Like ship.sh's `set +xva`: a caller's `Set-PSDebug -Trace` would print the
# line that holds the token. -Off must come before Set-StrictMode, which it
# would otherwise reset.
Set-PSDebug -Off
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'
# A caller's preferences must never make this script chatty about requests.
$VerbosePreference = 'SilentlyContinue'
$DebugPreference = 'SilentlyContinue'
$InformationPreference = 'SilentlyContinue'
$ProgressPreference = 'SilentlyContinue'
# The token is piped to python on stdin: UTF-8 with no byte-order mark, so the
# bytes python reads are exactly the token.
$OutputEncoding = New-Object System.Text.UTF8Encoding($false)

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Support   = Join-Path $ScriptDir 'ship_support.py'
$Python    = 'python3'
if (-not (Get-Command python3 -ErrorAction SilentlyContinue)) { $Python = 'python' }

$script:Token = $null
$script:ApiUrl = $null
$script:AuthFile = $null
$script:Temps = New-Object System.Collections.Generic.List[string]

function Write-Err([string]$Message) { [Console]::Error.WriteLine($Message) }

function Exit-Usage {
    Write-Err 'stride-ideation: usage: ship.ps1 --check-auth | ship.ps1 --check-payload <batch.json> | ship.ps1 <batch.json>'
    exit 2
}

function New-StiTemp {
    try {
        $f = [System.IO.Path]::GetTempFileName()
    } catch {
        Write-Err "stride-ideation: could not create a temp file in $([System.IO.Path]::GetTempPath()); nothing was sent"
        exit 1
    }
    $script:Temps.Add($f) | Out-Null
    return $f
}

# read_auth.py prints shell-quoted NAME=value lines (shlex.quote). Undo that
# quoting without evaluating anything.
function ConvertFrom-ShellQuoted([string]$Value) {
    if ($Value.Length -ge 2 -and $Value.StartsWith("'") -and $Value.EndsWith("'")) {
        return $Value.Substring(1, $Value.Length - 2).Replace("'""'""'", "'")
    }
    return $Value
}

function Read-StiAuth {
    $root = (& git rev-parse --show-toplevel 2>$null)
    if ($LASTEXITCODE -ne 0 -or -not $root) { $root = (Get-Location).Path }
    $authFile = $env:STRIDE_AUTH_FILE
    if (-not $authFile) { $authFile = Join-Path "$root" '.stride_auth.md' }
    $script:AuthFile = $authFile
    # Its stderr (passed through) never carries the token.
    $lines = @(& $Python (Join-Path $ScriptDir 'read_auth.py') $authFile)
    if ($LASTEXITCODE -ne 0) {
        Write-Err "stride-ideation: failed to read auth from $authFile"
        exit 1
    }
    foreach ($line in $lines) {
        if ($line -match '^STRIDE_API_URL=(.*)$') { $script:ApiUrl = ConvertFrom-ShellQuoted $Matches[1] }
        elseif ($line -match '^STRIDE_API_TOKEN=(.*)$') {
            # Undone inline with string methods, never by calling a function or
            # cmdlet: Module Logging (event 4103) records the arguments bound
            # to a command, and this value is the token.
            $tokenValue = $Matches[1]
            if ($tokenValue.Length -ge 2 -and $tokenValue.StartsWith("'") -and $tokenValue.EndsWith("'")) {
                $tokenValue = $tokenValue.Substring(1, $tokenValue.Length - 2).Replace("'""'""'", "'")
            }
            $script:Token = $tokenValue
            $tokenValue = $null
        }
    }
    $lines = $null
    if (-not $script:Token -or -not $script:ApiUrl) {
        Write-Err "stride-ideation: failed to read auth from $authFile"
        exit 1
    }
}

# Copy a file to stderr with credentials replaced by [REDACTED]. The token
# reaches python on stdin, never on argv.
function Write-Scrubbed([string]$Path) {
    $script:Token | & $Python $Support scrub $Path
}

# 0 = the file contains the token, 1 = it does not, anything else = the check
# failed. Callers treat ONLY 1 as clean, so a failed check refuses.
function Get-TokenCheck([string]$Path) {
    $script:Token | & $Python $Support has-token $Path
    return $LASTEXITCODE
}

try {
    $argv = @($args)

    if ($argv.Count -eq 2 -and $argv[0] -ceq '--check-payload') {
        # /stridify --batch runs this before its preview: a hand-written or
        # pasted batch could carry the token anywhere, including
        # decomposition_notes, which the preview prints and the POST strip
        # would hide from the payload check below. Nothing is sent.
        $file = [string]$argv[1]
        if ($file.StartsWith('-')) { Exit-Usage }
        if (-not (Test-Path -LiteralPath $file -PathType Leaf)) {
            Write-Err "stride-ideation: batch JSON not found at $file"
            exit 1
        }
        Read-StiAuth
        $check = Get-TokenCheck $file
        if ($check -eq 0) {
            Write-Err "stride-ideation: $file contains the configured Stride API token; nothing was shown or sent. Remove it from the file and retry."
            exit 1
        } elseif ($check -ne 1) {
            Write-Err "stride-ideation: could not check $file for the configured Stride API token; nothing was shown or sent."
            exit 1
        }
        exit 0
    }

    if ($argv.Count -ne 1) { Exit-Usage }

    if ($argv[0] -ceq '--check-auth') {
        Read-StiAuth
        $script:Token = $null
        [Console]::Out.WriteLine("stride-ideation: auth file OK — read from $($script:AuthFile) (API URL $($script:ApiUrl)). The token is checked by the server only when the batch is POSTed.")
        exit 0
    }

    $batchPath = [string]$argv[0]
    if ($batchPath.StartsWith('-')) { Exit-Usage }
    if (-not (Test-Path -LiteralPath $batchPath -PathType Leaf)) {
        Write-Err "stride-ideation: batch JSON not found at $batchPath"
        exit 1
    }

    # (9a) Strip the local-audit fields into a temp file before auth is read.
    # The on-disk batch JSON is not modified.
    $payload = New-StiTemp
    & $Python $Support strip $batchPath $payload
    if ($LASTEXITCODE -ne 0) {
        Write-Err "stride-ideation: failed to prepare API payload from $batchPath"
        exit 1
    }
    # Validate the exact bytes about to be sent.
    & $Python (Join-Path $ScriptDir 'validate_batch.py') $payload > $null
    if ($LASTEXITCODE -ne 0) {
        Write-Err "stride-ideation: $batchPath failed validation; nothing was sent"
        exit 1
    }

    $response = New-StiTemp
    Read-StiAuth

    # Refuse to send the configured API token as task content.
    $check = Get-TokenCheck $payload
    if ($check -eq 0) {
        Write-Err "stride-ideation: the batch contains the configured Stride API token; nothing was sent. Remove it from $batchPath and retry."
        exit 1
    } elseif ($check -ne 1) {
        Write-Err 'stride-ideation: could not check the payload for the configured Stride API token; nothing was sent.'
        exit 1
    }

    # (9b) POST in-process with System.Net.Http.HttpClient: the same on
    # PowerShell 7 and Windows PowerShell 5.1, no exception on a non-2xx, and
    # the exact body bytes for every status. Invoke-WebRequest was not used:
    # with redirects disabled, pwsh 7 throws a bare InvalidOperationException
    # on a 3xx, losing the status. Redirects are never followed (curl in
    # ship.sh does not follow either), so the Authorization header can never
    # be replayed to another host.
    Add-Type -AssemblyName System.Net.Http
    if ($PSVersionTable.PSVersion.Major -lt 6) {
        # Windows PowerShell 5.1 on an older .NET Framework may enable only
        # SSL3/TLS 1.0 explicitly: add TLS 1.2 to that set. When the setting is
        # SystemDefault (0) the OS already negotiates TLS 1.2 or later, and
        # OR-ing a flag in would pin it to 1.2, so leave it alone.
        $current = [System.Net.ServicePointManager]::SecurityProtocol
        if ([int]$current -ne 0) {
            [System.Net.ServicePointManager]::SecurityProtocol = $current -bor [System.Net.SecurityProtocolType]::Tls12
        }
    }
    $handler = New-Object System.Net.Http.HttpClientHandler
    $handler.AllowAutoRedirect = $false
    $client = New-Object System.Net.Http.HttpClient($handler)
    # No client-side timeout, like curl in ship.sh: a slow 2xx must not be
    # reported as a transport failure, which would invite a duplicating re-run.
    $client.Timeout = [System.Threading.Timeout]::InfiniteTimeSpan
    $httpCode = 0
    $transportError = $null
    $message = $null
    try {
        $message = New-Object System.Net.Http.HttpRequestMessage([System.Net.Http.HttpMethod]::Post, ($script:ApiUrl.TrimEnd('/') + '/api/tasks/batch'))
        # ::new, never New-Object: a cmdlet's arguments are written to the
        # event log when PowerShell Module Logging is on; a method call is not.
        $message.Headers.Authorization = [System.Net.Http.Headers.AuthenticationHeaderValue]::new('Bearer', $script:Token)
        $content = New-Object System.Net.Http.ByteArrayContent(,[System.IO.File]::ReadAllBytes($payload))
        $content.Headers.ContentType = New-Object System.Net.Http.Headers.MediaTypeHeaderValue('application/json')
        $message.Content = $content
        $reply = $client.SendAsync($message).GetAwaiter().GetResult()
        $httpCode = [int]$reply.StatusCode
        [System.IO.File]::WriteAllBytes($response, $reply.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult())
    } catch {
        $ex = $_.Exception
        $parts = New-Object System.Collections.Generic.List[string]
        while ($ex) { $parts.Add($ex.Message) | Out-Null; $ex = $ex.InnerException }
        $transportError = $parts -join ' -> '
        $httpCode = 0
    } finally {
        if ($message) { $message.Dispose() }
        $client.Dispose()
        $handler.Dispose()
    }

    if (-not $httpCode) {
        Write-Err 'stride-ideation: HTTP request failed before the Stride API responded:'
        if ($transportError) {
            $msgFile = New-StiTemp
            [System.IO.File]::WriteAllText($msgFile, $transportError + [Environment]::NewLine)
            Write-Scrubbed $msgFile
        } else {
            Write-Err 'stride-ideation:   the request failed with no error message.'
        }
        exit 1
    }

    # (9c) Every non-2xx prints the response body verbatim (token-scrubbed)
    # and exits non-zero.
    if (-not (Test-Path -LiteralPath $response)) { [System.IO.File]::WriteAllText($response, '') }
    if ($httpCode -lt 200 -or $httpCode -ge 300) {
        if ($httpCode -ge 400 -and $httpCode -lt 500) {
            Write-Err "stride-ideation: Stride API rejected the batch (HTTP $httpCode). Response body:"
        } elseif ($httpCode -ge 500 -and $httpCode -lt 600) {
            Write-Err "stride-ideation: Stride API returned HTTP $httpCode. Response body:"
        } else {
            Write-Err "stride-ideation: unexpected HTTP status $httpCode. Response body:"
        }
        Write-Scrubbed $response
        Write-Err ''
        exit 1
    }

    # (10) Render the created identifiers.
    & $Python $Support render $response
    $renderExit = $LASTEXITCODE
    if ($renderExit -eq 0) {
        [Console]::Out.WriteLine('Batch shipped successfully.')
        [Console]::Out.WriteLine("The goals are now visible in the Stride workspace's Backlog column.")
        exit 0
    }
    if ($renderExit -eq 4) {
        Write-Err "stride-ideation: Stride answered HTTP $httpCode but listed no created goals. Check the Stride workspace's Backlog column before re-running. Response body:"
    } else {
        Write-Err "stride-ideation: the batch was created (HTTP $httpCode), but the response could not be rendered — do NOT re-run /stridify: the goals already exist in Stride and a second run would create them twice."
        Write-Err "stride-ideation: check the Stride workspace's Backlog column for the created identifiers. Response body:"
    }
    Write-Scrubbed $response
    Write-Err ''
    exit 0
} finally {
    $script:Token = $null
    foreach ($f in $script:Temps) {
        Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue
    }
}
