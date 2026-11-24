<#
    Does the agent parse?

    A syntax check for the two PowerShell files in this folder, so an edit to
    a script that only ever runs on a scheduled task is not found by the
    scheduled task. Run it from here:

        powershell -NoProfile -ExecutionPolicy Bypass -File agent\parse-check.ps1

    It reads the files and nothing else, and prints one line per file.
#>

$ErrorActionPreference = 'Stop'
$bad = 0

foreach ($name in @('zion-agent.ps1', 'zion-ocr.ps1', 'install.ps1')) {
    $path = Join-Path $PSScriptRoot $name
    if (-not (Test-Path -LiteralPath $path)) {
        Write-Host "  missing  $name"
        $bad = 1
        continue
    }
    $errors = $null
    $null = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref] $null, [ref] $errors)
    if ($errors -and $errors.Count -gt 0) {
        Write-Host "  FAILED   $name"
        foreach ($e in $errors) {
            Write-Host ("           line {0}: {1}" -f $e.Extent.StartLineNumber, $e.Message)
        }
        $bad = 1
    } else {
        Write-Host "  ok       $name parses"
    }
}

exit $bad
