<#
    Zion CRM — document agent installer

    Registers a scheduled task that runs the agent every 15 minutes as the
    logged-in user. Run once, from install.cmd.

    It writes exactly two files, both beside itself: the configuration and
    the log. It creates one scheduled task. It touches nothing else, and in
    particular it never reads, moves or writes anything in the watched folder
    — that is the agent's job, and even the agent only reads.
#>

$ErrorActionPreference = 'Stop'

$TaskName    = 'Zion CRM document agent'
$ScriptPath  = Join-Path $PSScriptRoot 'zion-agent.ps1'
$ConfigPath  = Join-Path $PSScriptRoot 'zion-agent.config.json'

$DefaultFolder = 'C:\Users\FrancisWeah\OneDrive - Francis Weah Insurance Agency\Office\Zion Healing\Clients'
$DefaultUrl    = 'https://zion-crm-red.vercel.app'

function Ask {
    param([string] $Prompt, [string] $Default)
    if ($Default) {
        $answer = Read-Host "$Prompt [$Default]"
        if ([string]::IsNullOrWhiteSpace($answer)) { return $Default }
        return $answer.Trim()
    }
    return (Read-Host $Prompt).Trim()
}

Write-Host ''
Write-Host '  This will:' -ForegroundColor Cyan
Write-Host '    - save a configuration file beside this installer'
Write-Host '    - register a task that runs every 15 minutes'
Write-Host '    - run it once now'
Write-Host ''
Write-Host '  It will not move, rename or change anything in the watched folder.' -ForegroundColor Cyan
Write-Host ''

$folder = Ask 'Folder to watch' $DefaultFolder
if (-not (Test-Path -LiteralPath $folder)) {
    Write-Host ''
    Write-Host "  That folder is not there:" -ForegroundColor Red
    Write-Host "  $folder"
    Write-Host '  Nothing has been changed.'
    exit 1
}

$url = Ask 'CRM address' $DefaultUrl

Write-Host ''
Write-Host '  The agent secret. This is the AGENT_SECRET set in Vercel.' -ForegroundColor Cyan
$secretSecure = Read-Host '  Secret' -AsSecureString
$secret = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
    [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secretSecure))

if ([string]::IsNullOrWhiteSpace($secret)) {
    Write-Host '  No secret given. Nothing has been changed.' -ForegroundColor Red
    exit 1
}

# ── the configuration ────────────────────────────────────────
@{
    watchFolder = $folder
    baseUrl     = $url
    secret      = $secret
} | ConvertTo-Json | Set-Content -Path $ConfigPath -Encoding utf8

# Readable by this user only. It holds the secret, and the default on a file
# in a user folder is wider than it needs to be.
try {
    $acl = Get-Acl $ConfigPath
    $acl.SetAccessRuleProtection($true, $false)
    $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
        "$env:USERDOMAIN\$env:USERNAME", 'FullControl', 'Allow')
    $acl.SetAccessRule($rule)
    Set-Acl -Path $ConfigPath -AclObject $acl
} catch {
    Write-Host '  (Could not tighten permissions on the config file — not fatal.)' -ForegroundColor Yellow
}

Write-Host ''
Write-Host "  Configuration written to $ConfigPath" -ForegroundColor Green

# ── the scheduled task ───────────────────────────────────────
$action = New-ScheduledTaskAction -Execute 'powershell.exe' `
    -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$ScriptPath`""

# Every 15 minutes, forever, starting at the next quarter hour. Also at logon,
# so a machine that was off overnight catches up without waiting.
$daily = New-ScheduledTaskTrigger -Once -At (Get-Date).Date `
    -RepetitionInterval (New-TimeSpan -Minutes 15) -RepetitionDuration ([TimeSpan]::MaxValue)
$logon = New-ScheduledTaskTrigger -AtLogOn

$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Hours 1) `
    -MultipleInstances IgnoreNew

Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue

Register-ScheduledTask -TaskName $TaskName `
    -Description 'Posts new client PDFs to the Zion CRM. Reads only; never moves or renames.' `
    -Action $action -Trigger @($daily, $logon) -Settings $settings `
    -RunLevel Limited | Out-Null

Write-Host "  Scheduled task registered: $TaskName" -ForegroundColor Green

# ── one run now ──────────────────────────────────────────────
Write-Host ''
Write-Host '  Running it once now. The first run sends everything already there,' -ForegroundColor Cyan
Write-Host '  so it may take a while.' -ForegroundColor Cyan
Write-Host ''

& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $ScriptPath

Write-Host ''
Write-Host '  Done.' -ForegroundColor Green
Write-Host ''
Write-Host '  To check it is running:' -ForegroundColor Cyan
Write-Host '    - in the CRM: Admin -> Document inbox, which shows the last run'
Write-Host '    - on this machine: Task Scheduler, or'
Write-Host '        Get-ScheduledTaskInfo -TaskName "Zion CRM document agent"'
Write-Host "    - the log: $(Join-Path $PSScriptRoot 'zion-agent.log')"
Write-Host ''
Write-Host '  To stop it:' -ForegroundColor Cyan
Write-Host '        Unregister-ScheduledTask -TaskName "Zion CRM document agent" -Confirm:$false'
Write-Host ''
