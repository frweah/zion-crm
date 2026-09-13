<#
    Zion CRM — document agent
    ==========================

    Watches one folder on this machine and posts new PDFs to the CRM.

    Why this exists rather than a cloud connection: reading the folder from
    the internet would have meant granting an application write access to the
    whole of a OneDrive, because Microsoft Graph has no permission narrower
    than that. Nothing is granted. This runs where the files already are.

    What it will not do, ever:

      * move, rename, delete or modify anything in the watched folder
      * write to any other folder on this machine
      * send anything but PDFs, and only from inside the watched folder

    It sends a list of hashes first and uploads only what the CRM has never
    seen, so running it every fifteen minutes on a folder of two thousand
    files costs one small request.

    PowerShell 5.1, which is what Windows already has. No modules to install.
#>

[CmdletBinding()]
param(
    # No default here. Under Windows PowerShell 5.1, $PSScriptRoot is still
    # empty while a param block's defaults are evaluated for a script run with
    # powershell.exe -File - which is exactly how the scheduled task runs it.
    # Join-Path then threw before a single line of the script ran: exit code 1,
    # no log, no request. That silently stopped the first real install.
    [string] $ConfigPath
)

$ErrorActionPreference = 'Stop'
$AgentVersion = '1.0.1'

# Where this script lives, worked out in the body where it is reliable, with a
# fallback for the cases where even there it is not populated.
$Here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Definition }
if (-not $ConfigPath) { $ConfigPath = Join-Path $Here 'zion-agent.config.json' }

# ── where the log goes ───────────────────────────────────────
# Beside the script, rotated by hand if it ever matters. A scheduled task with
# nowhere to write is a scheduled task nobody can debug.
$LogPath = Join-Path $Here 'zion-agent.log'

function Write-Log {
    param([string] $Message, [string] $Level = 'info')
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 's'), $Level, $Message
    Write-Output $line
    try { Add-Content -Path $LogPath -Value $line -Encoding utf8 } catch { }
}

function Trim-Log {
    # Keep the last 2000 lines. Long enough to see last week, short enough
    # that nobody has to think about it.
    try {
        if (Test-Path $LogPath) {
            $lines = Get-Content $LogPath
            if ($lines.Count -gt 2000) {
                $lines[-2000..-1] | Set-Content -Path $LogPath -Encoding utf8
            }
        }
    } catch { }
}

# ── configuration ────────────────────────────────────────────
# A file called PAUSED beside this script stops every run before it reads
# anything or contacts the CRM. The scheduled task is registered with
# administrator rights, so disabling it needs an elevated shell; this does not.
# Delete the file to resume.
$PausePath = Join-Path $Here 'PAUSED'
if (Test-Path -LiteralPath $PausePath) {
    Write-Log "Paused: $PausePath exists. Delete it to resume."
    Trim-Log
    exit 0
}
if (-not (Test-Path $ConfigPath)) {
    Write-Log "No configuration at $ConfigPath. Run install.cmd first." 'error'
    exit 1
}

$config = Get-Content $ConfigPath -Raw | ConvertFrom-Json

$WatchFolder = $config.watchFolder
$BaseUrl     = $config.baseUrl.TrimEnd('/')
$Secret      = $config.secret

if (-not (Test-Path -LiteralPath $WatchFolder)) {
    Write-Log "The watched folder is not there: $WatchFolder" 'error'
    exit 1
}

$headers = @{ 'x-zion-agent' = $Secret }

Write-Log "Run starting. Watching: $WatchFolder"

# ── list what is there ───────────────────────────────────────
# One subfolder per client. Files loose at the top level are included with an
# empty folder name, which lands them in the review list rather than being
# skipped silently.
$files = @()
try {
    $files = Get-ChildItem -LiteralPath $WatchFolder -Recurse -File -Filter '*.pdf' -ErrorAction Stop
} catch {
    Write-Log "Could not read the folder: $($_.Exception.Message)" 'error'
    exit 1
}

Write-Log "Found $($files.Count) PDF file(s)."

$entries = @()
foreach ($f in $files) {
    try {
        $hash = (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash.ToLower()
    } catch {
        Write-Log "Could not hash $($f.FullName): $($_.Exception.Message)" 'warn'
        continue
    }

    # The folder directly under the watched root is the client name. A file
    # two levels down keeps its top-level folder, because that is the client.
    $relative = $f.FullName.Substring($WatchFolder.Length).TrimStart('\', '/')
    $parts    = $relative -split '[\\/]'
    $folder   = if ($parts.Count -gt 1) { $parts[0] } else { '' }

    $entries += [pscustomobject]@{
        hash     = $hash
        path     = $relative
        folder   = $folder
        size     = $f.Length
        modified = $f.LastWriteTimeUtc.ToString('o')
        full     = $f.FullName
    }
}

# ── ask what is wanted ───────────────────────────────────────
$wanted = @()
try {
    $manifest = @{
        machine = $env:COMPUTERNAME
        version = $AgentVersion
        files   = @($entries | Select-Object hash, path, folder, size, modified)
    } | ConvertTo-Json -Depth 5 -Compress

    $response = Invoke-RestMethod -Method Post -Uri "$BaseUrl/api/agent/manifest" `
        -Headers $headers -ContentType 'application/json' -Body $manifest -TimeoutSec 120

    $wanted = @($response.wanted)
} catch {
    Write-Log "The CRM did not answer the manifest: $($_.Exception.Message)" 'error'
    Trim-Log
    exit 1
}

Write-Log "$($wanted.Count) file(s) the CRM has not seen."

if ($wanted.Count -eq 0) {
    Write-Log 'Nothing to send. Run finished.'
    Trim-Log
    exit 0
}

# ── send them ────────────────────────────────────────────────
$sent = 0
$failed = 0

foreach ($entry in ($entries | Where-Object { $wanted -contains $_.hash })) {
    try {
        # PowerShell 5.1 has no -Form, so the multipart body is built by hand.
        $boundary = [System.Guid]::NewGuid().ToString()
        $LF = "`r`n"

        $fileBytes = [System.IO.File]::ReadAllBytes($entry.full)
        $fileEnc   = [System.Text.Encoding]::GetEncoding('iso-8859-1').GetString($fileBytes)

        $name = [System.IO.Path]::GetFileName($entry.full)

        $body = (
            "--$boundary", "Content-Disposition: form-data; name=`"hash`"$LF", $entry.hash,
            "--$boundary", "Content-Disposition: form-data; name=`"folder`"$LF", $entry.folder,
            "--$boundary", "Content-Disposition: form-data; name=`"path`"$LF", $entry.path,
            "--$boundary", "Content-Disposition: form-data; name=`"modified`"$LF", $entry.modified,
            "--$boundary",
            "Content-Disposition: form-data; name=`"file`"; filename=`"$name`"",
            "Content-Type: application/pdf$LF",
            $fileEnc,
            "--$boundary--$LF"
        ) -join $LF

        $result = Invoke-RestMethod -Method Post -Uri "$BaseUrl/api/agent/file" `
            -Headers $headers -ContentType "multipart/form-data; boundary=$boundary" `
            -Body ([System.Text.Encoding]::GetEncoding('iso-8859-1').GetBytes($body)) `
            -TimeoutSec 300

        if ($result.already) {
            Write-Log "Already had: $($entry.path)"
        } else {
            Write-Log "Sent: $($entry.path) -> $($result.kind)"
        }
        $sent++
    } catch {
        Write-Log "Failed to send $($entry.path): $($_.Exception.Message)" 'warn'
        $failed++
    }
}

Write-Log "Run finished. $sent sent, $failed failed."
Trim-Log

# A run that could not send anything it meant to is a failed run, so the task
# history shows red rather than green.
if ($failed -gt 0 -and $sent -eq 0) { exit 1 }
exit 0
