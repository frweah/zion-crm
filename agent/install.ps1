<#
    Zion CRM — document agent installer

    Registers two scheduled tasks, both as the logged-in user. Run once, from
    install.cmd.

      Zion CRM document agent            10:00 and 19:00 — the full pass:
                                         the client folders and the warrants
      Zion CRM document agent (photos)   every 15 minutes, and at logon —
                                         the phone photos, and any extra pass
                                         asked for from Admin → Documents

    Two of them because the two jobs cost different things (owner, 23 November
    2026). Walking and hashing two thousand files is most of what this machine
    used to do all day, for folders that change a few times a week; reading a
    photo somebody has just taken of a signed form has to happen while they
    are still standing there. So the folders are read twice a day and the
    photos every quarter of an hour - and "Run now" on Admin → Documents asks
    the quarter-hourly task to do the folders as well on its next wake, which
    is never more than fifteen minutes away.

    Run it again whenever the schedule changes: it keeps the configuration it
    already wrote and only re-registers the tasks.

    It writes exactly two files, both beside itself: the configuration and
    the log. It creates one scheduled task. It touches nothing else, and in
    particular it never reads, moves or writes anything in the watched folder
    — that is the agent's job, and even the agent only reads.
#>

$ErrorActionPreference = 'Stop'

$TaskName    = 'Zion CRM document agent'
$PhotoTask   = 'Zion CRM document agent (photos)'
$ScriptPath  = Join-Path $PSScriptRoot 'zion-agent.ps1'
$ConfigPath  = Join-Path $PSScriptRoot 'zion-agent.config.json'

# The hours of the full pass. Local time on this machine, which is Utah's.
$ScanHours   = @(10, 19)

$DefaultFolder = 'C:\Users\FrancisWeah\OneDrive - Francis Weah Insurance Agency\Office\Zion Healing\Clients'
$DefaultUrl    = 'https://crm.zionvocrehab.com'

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
Write-Host '    - save a configuration file beside this installer, or keep the one that is there'
Write-Host '    - register a task that reads the client folders at 10:00 and 19:00'
Write-Host '    - register a task that reads phone photos every 15 minutes'
Write-Host '    - run the full pass once now'
Write-Host ''
Write-Host '  It will not move, rename or change anything in the watched folder.' -ForegroundColor Cyan
Write-Host ''

# ── the configuration that is already here ───────────────────
# Run again to change the schedule and nothing is asked: the folder, the
# address and the secret are already written down, and asking for the secret
# again is how somebody ends up typing it into a terminal they did not need
# to. Delete the file, or answer no, to set it up from scratch.
$existing = $null
if (Test-Path -LiteralPath $ConfigPath) {
    try { $existing = Get-Content $ConfigPath -Raw | ConvertFrom-Json } catch { $existing = $null }
}
if ($existing -and $existing.watchFolder -and $existing.secret) {
    Write-Host "  Using the configuration already here:" -ForegroundColor Green
    Write-Host "    folder:  $($existing.watchFolder)"
    Write-Host "    address: $($existing.baseUrl)"
    Write-Host '    secret:  kept as it is'
    Write-Host ''
    $again = Read-Host '  Set it up from scratch instead? (y/N)'
    if ($again -notmatch '^[Yy]') { $KeepConfig = $true }
}

$folder = if ($KeepConfig) { $existing.watchFolder } else { Ask 'Folder to watch' $DefaultFolder }
if (-not (Test-Path -LiteralPath $folder)) {
    Write-Host ''
    Write-Host "  That folder is not there:" -ForegroundColor Red
    Write-Host "  $folder"
    Write-Host '  Nothing has been changed.'
    exit 1
}

$url = if ($KeepConfig) { $existing.baseUrl } else { Ask 'CRM address' $DefaultUrl }

$secret = $null
if ($KeepConfig) {
    $secret = $existing.secret
} else {
    Write-Host ''
    Write-Host '  The agent secret. This is the AGENT_SECRET set in Vercel.' -ForegroundColor Cyan
    $secretSecure = Read-Host '  Secret' -AsSecureString
    $secret = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
        [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secretSecure))
}

if ([string]::IsNullOrWhiteSpace($secret)) {
    Write-Host '  No secret given. Nothing has been changed.' -ForegroundColor Red
    exit 1
}

# ── the configuration ────────────────────────────────────────
# Anything else already in the file is kept - ocrPerRun and tesseractPath
# are set by hand on this machine and are not worth losing to a re-install.
$settings = [ordered]@{
    watchFolder = $folder
    baseUrl     = $url
    secret      = $secret
}
if ($existing) {
    foreach ($p in $existing.PSObject.Properties) {
        if (-not $settings.Contains($p.Name)) { $settings[$p.Name] = $p.Value }
    }
}
$settings | ConvertTo-Json | Set-Content -Path $ConfigPath -Encoding utf8

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
# Two actions, one script. The full pass is told so with -Scan; the light
# one is not, and reads the phone photos and whatever the CRM has asked for.
$scanAction = New-ScheduledTaskAction -Execute 'powershell.exe' `
    -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$ScriptPath`" -Scan"
$lightAction = New-ScheduledTaskAction -Execute 'powershell.exe' `
    -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$ScriptPath`""

# The full pass: one daily trigger per hour in $ScanHours. Daily rather than
# a repetition, because "at ten and at seven" is what somebody reads in Task
# Scheduler and what the install notes say.
#
# -StartWhenAvailable below is what covers a machine that was asleep at ten:
# Task Scheduler runs the missed one when it wakes.
$scanTriggers = @()
foreach ($h in $ScanHours) {
    $scanTriggers += New-ScheduledTaskTrigger -Daily -At ([datetime]::Today.AddHours($h))
}

# The light pass: every 15 minutes, indefinitely, and at logon so a machine
# that was off overnight catches up without waiting.
#
# No -RepetitionDuration, on purpose. Leaving it out is what Task Scheduler
# records as "indefinitely". The obvious alternative, [TimeSpan]::MaxValue,
# becomes P99999999DT23H59M59S in the task XML, which Task Scheduler refuses
# ("incorrectly formatted or out of range") - that stopped the first real
# install at this line. A long finite duration would be accepted but would
# quietly stop the agent the day it ran out.
$quarterly = New-ScheduledTaskTrigger -Once -At (Get-Date).Date `
    -RepetitionInterval (New-TimeSpan -Minutes 15)
$logon = New-ScheduledTaskTrigger -AtLogOn

$taskSettings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Hours 1) `
    -MultipleInstances IgnoreNew

Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
Unregister-ScheduledTask -TaskName $PhotoTask -Confirm:$false -ErrorAction SilentlyContinue

Register-ScheduledTask -TaskName $TaskName `
    -Description "Reads the client folders and the warrants twice a day and posts what the CRM has not seen. Reads only; never moves or renames." `
    -Action $scanAction -Trigger $scanTriggers -Settings $taskSettings `
    -RunLevel Limited | Out-Null

Register-ScheduledTask -TaskName $PhotoTask `
    -Description 'Reads phone photos every 15 minutes, and does an extra pass over the folders when one is asked for in the CRM. Reads only.' `
    -Action $lightAction -Trigger @($quarterly, $logon) -Settings $taskSettings `
    -RunLevel Limited | Out-Null

Write-Host "  Scheduled task registered: $TaskName ($($ScanHours -join ':00, '):00)" -ForegroundColor Green
Write-Host "  Scheduled task registered: $PhotoTask (every 15 minutes)" -ForegroundColor Green

# ── one run now ──────────────────────────────────────────────
Write-Host ''
Write-Host '  Running the full pass once now. The first run sends everything already' -ForegroundColor Cyan
Write-Host '  there, so it may take a while.' -ForegroundColor Cyan
Write-Host ''

& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $ScriptPath -Scan

Write-Host ''
Write-Host '  Done.' -ForegroundColor Green
Write-Host ''
Write-Host '  To check it is running:' -ForegroundColor Cyan
Write-Host '    - in the CRM: Admin -> Documents, which shows the last run and'
Write-Host '      offers Run now for an extra pass'
Write-Host '    - on this machine: Task Scheduler, or'
Write-Host '        Get-ScheduledTaskInfo -TaskName "Zion CRM document agent"'
Write-Host '        Get-ScheduledTaskInfo -TaskName "Zion CRM document agent (photos)"'
Write-Host "    - the log: $(Join-Path $PSScriptRoot 'zion-agent.log')"
Write-Host ''
Write-Host '  To stop it, both of them:' -ForegroundColor Cyan
Write-Host '        Unregister-ScheduledTask -TaskName "Zion CRM document agent" -Confirm:$false'
Write-Host '        Unregister-ScheduledTask -TaskName "Zion CRM document agent (photos)" -Confirm:$false'
Write-Host ''
