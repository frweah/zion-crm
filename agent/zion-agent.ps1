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
      * write outside its own folder, except the page images OCR needs, in a
        folder of their own under %TEMP%, deleted as soon as they are read
      * send anything but PDFs, and only from inside the watched folder
      * send a document, or its text, anywhere but the CRM

    It sends a list of hashes first and uploads only what the CRM has never
    seen, so running it every fifteen minutes on a folder of two thousand
    files costs one small request.

    Scans: a PDF with no text layer is read with Tesseract on this machine
    (zion-ocr.ps1) and the text goes up with the file, marked as OCR. When
    Tesseract is not installed, scans go up as they are, as before.

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
$AgentVersion = '1.2.0'

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
    # To the host, never the output stream. In PowerShell whatever a function
    # writes to output is part of what it returns: logged from inside Get-Ocr,
    # a failed read came back as the log line instead of $null, looked like a
    # reading, and was sent to the CRM as "nothing readable" (agent 1.1.1).
    Write-Host $line
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

Write-Log "Run starting ($AgentVersion). Watching: $WatchFolder"

# ── OCR ──────────────────────────────────────────────────────
# Optional. Without Tesseract the agent does exactly what it did before.
# How many older scans to read per run, when the CRM asks for them: enough to
# work through a backlog, few enough that a run never takes the machine for an
# hour. "ocrPerRun" in the configuration overrides it; 0 turns that off.
$OcrPerRun = if ($null -ne $config.ocrPerRun) { [int]$config.ocrPerRun } else { 15 }
$Tesseract = $null
$OcrEngine = ''
try {
    . (Join-Path $Here 'zion-ocr.ps1')
    $Tesseract = Find-Tesseract ([string]$config.tesseractPath)
    if ($Tesseract) {
        $OcrEngine = Get-TesseractVersion $Tesseract
        Initialize-WinRt
        Write-Log "OCR available: $OcrEngine"
    } else {
        Write-Log 'Tesseract is not installed, so scans are sent without OCR.' 'warn'
    }
} catch {
    Write-Log "OCR is not available: $($_.Exception.Message)" 'warn'
    $Tesseract = $null
}

# A reading, or $null when OCR failed. An empty reading - the pages were read
# and nothing is on them - is still a reading, and is the only thing reported
# to the CRM as "nothing readable". A failure is never reported: the CRM keeps
# the document on its list and it is tried again next run. Agent 1.1.0 sent a
# failure as an empty reading, and the CRM stopped asking for those scans.
function Get-Ocr {
    param([string] $FullPath)
    if (-not $Tesseract) { return $null }
    try {
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $r = Invoke-PdfOcr -Path $FullPath -Exe $Tesseract -Engine $OcrEngine -MaxPages 10
        $sw.Stop()
        if ($r.Text) {
            Write-Log ("OCR read {0} of {1} page(s), confidence {2}%, in {3:N0}s" -f $r.Pages, $r.PageCount, $r.Confidence, $sw.Elapsed.TotalSeconds)
        } else {
            Write-Log ("OCR read {0} page(s) and found no text." -f $r.Pages)
        }
        return $r
    } catch {
        Write-Log "OCR failed, will try again next run: $($_.Exception.Message)" 'warn'
        return $null
    }
}

# The OCR fields as the CRM reads them. The text travels as base64 of UTF-8:
# the ordinary upload body is built as Latin-1 to carry the PDF's bytes, and
# an accent or a curly quote in the text would not survive that.
function Get-OcrFields {
    param($Ocr)
    $inv = [System.Globalization.CultureInfo]::InvariantCulture
    $fields = [ordered]@{
        ocr_text_b64   = if ($Ocr) { ConvertTo-Base64Utf8 $Ocr.Text } else { '' }
        ocr_engine     = $OcrEngine
        ocr_confidence = if ($Ocr) { ([double]$Ocr.Confidence).ToString($inv) } else { '' }
        ocr_pages      = if ($Ocr) { [string]$Ocr.Pages } else { '' }
    }
    return $fields
}

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

# Warrants are not a client. A _Warrants folder inside the client folders is
# read by the warrant pass below, never sent to the document inbox.
$warrantsInside = (Join-Path $WatchFolder '_Warrants') + '\'
$files = @($files | Where-Object { -not $_.FullName.StartsWith($warrantsInside, [System.StringComparison]::OrdinalIgnoreCase) })

Write-Log "Found $($files.Count) PDF file(s)."

$entries = @()
foreach ($f in $files) {
    # An empty file is not a document - usually a save that never finished.
    # Nothing can be read from it and the CRM refuses it, so it is logged and
    # left out, rather than failing on every run until somebody replaces it.
    if ($f.Length -eq 0) {
        Write-Log "Empty file, not sent: $($f.Directory.Name)/$($f.Name)" 'warn'
        continue
    }
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

# ── send them ────────────────────────────────────────────────
$sent = 0
$failed = 0

# Vercel refuses any request body over 4.5 MB before the CRM sees it (413), so
# a larger file goes straight to storage on a one-use signed address and the
# CRM is then told to read it from there. 4 MB leaves room for the multipart
# wrapping around a file sent the ordinary way.
$DirectLimit  = 4MB
# The client-files bucket's own per-file cap. Anything over it cannot be kept
# however it is sent, so it is logged and skipped rather than failing inside
# storage on every run.
$StorageLimit = 50MB

function Send-Fields {
    param([System.Collections.Specialized.OrderedDictionary] $Fields)
    $boundary = [System.Guid]::NewGuid().ToString()
    $LF = "`r`n"
    $parts = foreach ($k in $Fields.Keys) {
        "--$boundary", "Content-Disposition: form-data; name=`"$k`"$LF", [string]$Fields[$k]
    }
    $body = (@($parts) + "--$boundary--$LF") -join $LF
    Invoke-RestMethod -Method Post -Uri "$BaseUrl/api/agent/file" `
        -Headers $headers -ContentType "multipart/form-data; boundary=$boundary" `
        -Body ([System.Text.Encoding]::UTF8.GetBytes($body)) -TimeoutSec 300
}

# A scan already with the CRM, and its OCR (or the news that there was none).
function Send-Ocr {
    param([string] $Hash, $Ocr)
    $fields = [ordered]@{ ocr = '1'; hash = $Hash }
    $ocrFields = Get-OcrFields $Ocr
    foreach ($k in $ocrFields.Keys) { $fields[$k] = $ocrFields[$k] }
    Send-Fields $fields
}

foreach ($entry in ($entries | Where-Object { $wanted -contains $_.hash })) {
    try {
        if ($entry.size -gt $StorageLimit) {
            Write-Log ("Too large to keep ({0:N1} MB; the limit is 50 MB): {1}" -f ($entry.size / 1MB), $entry.path) 'warn'
            $failed++
            continue
        }

        $name = [System.IO.Path]::GetFileName($entry.full)

        # A PDF with no text layer is read before it goes, so the text arrives
        # with it. When this cannot tell, it goes as it is and the CRM's answer
        # below decides.
        $ocr = $null
        if ($Tesseract) {
            $hasText = $true
            try { $hasText = Test-PdfHasTextLayer $entry.full } catch { $hasText = $true }
            if (-not $hasText) {
                Write-Log "No text layer, reading with OCR: $($entry.path)"
                $ocr = Get-Ocr $entry.full
                # Nothing on the pages is worth nothing to the CRM here; it
                # records that when it asks for the document later.
                if ($ocr -and -not $ocr.Text) { $ocr = $null }
            }
        }

        if ($entry.size -gt $DirectLimit) {
            $ticket = Invoke-RestMethod -Method Post -Uri "$BaseUrl/api/agent/upload-url" `
                -Headers $headers -ContentType 'application/json' `
                -Body (@{ hash = $entry.hash; size = $entry.size } | ConvertTo-Json -Compress) `
                -TimeoutSec 60

            if ($ticket.already) {
                Write-Log "Already had: $($entry.path)"
                $sent++
                continue
            }

            Invoke-WebRequest -Method Put -Uri $ticket.signedUrl -InFile $entry.full `
                -ContentType 'application/pdf' -Headers @{ 'x-upsert' = 'true' } `
                -UseBasicParsing -TimeoutSec 600 | Out-Null

            $fields = [ordered]@{
                stored   = '1'
                hash     = $entry.hash
                folder   = $entry.folder
                path     = $entry.path
                modified = $entry.modified
                filename = $name
            }
            if ($ocr) {
                $ocrFields = Get-OcrFields $ocr
                foreach ($k in $ocrFields.Keys) { $fields[$k] = $ocrFields[$k] }
            }
            $result = Send-Fields $fields
        } else {
            # PowerShell 5.1 has no -Form, so the multipart body is built by hand.
            $boundary = [System.Guid]::NewGuid().ToString()
            $LF = "`r`n"

            $fileBytes = [System.IO.File]::ReadAllBytes($entry.full)
            $fileEnc   = [System.Text.Encoding]::GetEncoding('iso-8859-1').GetString($fileBytes)

            $pieces = @(
                "--$boundary", "Content-Disposition: form-data; name=`"hash`"$LF", $entry.hash,
                "--$boundary", "Content-Disposition: form-data; name=`"folder`"$LF", $entry.folder,
                "--$boundary", "Content-Disposition: form-data; name=`"path`"$LF", $entry.path,
                "--$boundary", "Content-Disposition: form-data; name=`"modified`"$LF", $entry.modified
            )
            if ($ocr) {
                $ocrFields = Get-OcrFields $ocr
                foreach ($k in $ocrFields.Keys) {
                    $pieces += "--$boundary"
                    $pieces += "Content-Disposition: form-data; name=`"$k`"$LF"
                    $pieces += [string]$ocrFields[$k]
                }
            }
            $pieces += @(
                "--$boundary",
                "Content-Disposition: form-data; name=`"file`"; filename=`"$name`"",
                "Content-Type: application/pdf$LF",
                $fileEnc,
                "--$boundary--$LF"
            )
            $body = $pieces -join $LF

            $result = Invoke-RestMethod -Method Post -Uri "$BaseUrl/api/agent/file" `
                -Headers $headers -ContentType "multipart/form-data; boundary=$boundary" `
                -Body ([System.Text.Encoding]::GetEncoding('iso-8859-1').GetBytes($body)) `
                -TimeoutSec 300
        }

        if ($result.already) {
            Write-Log "Already had: $($entry.path)"
        } else {
            # The reason rides along so a wrong answer leads to the rule, or
            # the error, that gave it.
            $why = if ($result.reason) { " ($($result.reason))" } else { '' }
            Write-Log "Sent: $($entry.path) -> $($result.kind)$why"

            # The CRM found no text in a PDF this could not tell about: read it
            # now rather than waiting for the CRM to ask.
            if ($Tesseract -and -not $ocr -and $result.kind -eq 'Unreadable') {
                Write-Log "The CRM found no text; reading with OCR: $($entry.path)"
                $late = Get-Ocr $entry.full
                if ($late) {
                    try {
                        $answer = Send-Ocr $entry.hash $late
                        Write-Log "OCR sent: $($entry.path) -> $($answer.ocr)"
                    } catch {
                        Write-Log "OCR not sent for $($entry.path): $($_.Exception.Message)" 'warn'
                    }
                }
            }
        }
        $sent++
    } catch {
        Write-Log "Failed to send $($entry.path): $($_.Exception.Message)" 'warn'
        $failed++
    }
}

# ── warrants ─────────────────────────────────────────────────
# USOR's warrant stubs, one page per warrant, dropped in a _Warrants folder:
# beside the client folders, inside them, or wherever "warrantsFolder" in the
# configuration says. Each page is turned upright, read with Tesseract, and
# sent with a picture of it; the CRM checks the page against itself and the
# authorizations on file, and records what it can prove.
$WarrantsFolder = $null
$warrantCandidates = @()
if ($config.warrantsFolder) { $warrantCandidates += [string]$config.warrantsFolder }
$warrantCandidates += (Join-Path (Split-Path -Parent $WatchFolder) '_Warrants')
$warrantCandidates += (Join-Path $WatchFolder '_Warrants')
foreach ($candidate in $warrantCandidates) {
    if ($candidate -and (Test-Path -LiteralPath $candidate)) { $WarrantsFolder = $candidate; break }
}
$WarrantPagesPerRun = if ($null -ne $config.warrantPagesPerRun) { [int]$config.warrantPagesPerRun } else { 60 }
$warrantPagesSent = 0

function Send-WarrantPage {
    param($Entry, [int] $PageNo, [int] $PageCount, $Read, [int] $Rotation, [string] $JpegPath)
    $boundary = [System.Guid]::NewGuid().ToString()
    $LF = "`r`n"
    $latin1 = [System.Text.Encoding]::GetEncoding('iso-8859-1')
    $inv = [System.Globalization.CultureInfo]::InvariantCulture
    $fields = [ordered]@{
        hash           = $Entry.hash
        filename       = [System.IO.Path]::GetFileName($Entry.full)
        path           = $Entry.path
        page_no        = [string]$PageNo
        page_count     = [string]$PageCount
        rotation       = [string]$Rotation
        ocr_text_b64   = ConvertTo-Base64Utf8 $Read.Text
        ocr_confidence = ([double]$Read.Confidence).ToString($inv)
        ocr_engine     = $OcrEngine
    }
    $pieces = @()
    foreach ($k in $fields.Keys) {
        $pieces += "--$boundary"
        $pieces += "Content-Disposition: form-data; name=`"$k`"$LF"
        $pieces += [string]$fields[$k]
    }
    $pieces += "--$boundary"
    $pieces += "Content-Disposition: form-data; name=`"image`"; filename=`"page.jpg`""
    $pieces += "Content-Type: image/jpeg$LF"
    $pieces += $latin1.GetString([System.IO.File]::ReadAllBytes($JpegPath))
    $pieces += "--$boundary--$LF"
    Invoke-RestMethod -Method Post -Uri "$BaseUrl/api/agent/warrants/page" `
        -Headers $headers -ContentType "multipart/form-data; boundary=$boundary" `
        -Body ($latin1.GetBytes($pieces -join $LF)) -TimeoutSec 120
}

if ($WarrantsFolder -and -not $Tesseract) {
    Write-Log "Warrants wait in $WarrantsFolder, but Tesseract is not installed to read them." 'warn'
} elseif ($WarrantsFolder) {
    $warrantEntries = @()
    try {
        foreach ($wf in @(Get-ChildItem -LiteralPath $WarrantsFolder -Recurse -File -Filter '*.pdf' -ErrorAction Stop)) {
            if ($wf.Length -eq 0) { continue }
            $warrantEntries += [pscustomobject]@{
                hash = (Get-FileHash -LiteralPath $wf.FullName -Algorithm SHA256).Hash.ToLower()
                path = $wf.FullName.Substring($WarrantsFolder.Length).TrimStart('\', '/')
                full = $wf.FullName
            }
        }
    } catch {
        Write-Log "Could not read the warrants folder: $($_.Exception.Message)" 'warn'
    }

    $wantedWarrants = @()
    if ($warrantEntries.Count) {
        try {
            $answer = Invoke-RestMethod -Method Post -Uri "$BaseUrl/api/agent/warrants/manifest" `
                -Headers $headers -ContentType 'application/json' `
                -Body (@{ files = @($warrantEntries | Select-Object hash, path) } | ConvertTo-Json -Depth 4 -Compress) -TimeoutSec 60
            $wantedWarrants = @($answer.wanted)
        } catch {
            Write-Log "The CRM did not answer about warrants: $($_.Exception.Message)" 'warn'
        }
    }

    foreach ($w in $wantedWarrants) {
        if (-not $w -or $warrantPagesSent -ge $WarrantPagesPerRun) { continue }
        $entry = $warrantEntries | Where-Object { $_.hash -eq $w.hash } | Select-Object -First 1
        if (-not $entry) { continue }
        $have = @($w.have | ForEach-Object { [int]$_ })
        Write-Log "Reading warrants: $($entry.path) ($($have.Count) page(s) already with the CRM)"

        $work = Join-Path $env:TEMP ('zion-agent-warrant-' + [System.Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $work -Force | Out-Null
        try {
            $rendered = Convert-PdfToPngs -Path $entry.full -WorkDir $work -MaxPages 500
            for ($i = 0; $i -lt $rendered.Pages.Count; $i++) {
                $pageNo = $i + 1
                if ($have -contains $pageNo) { continue }
                if ($warrantPagesSent -ge $WarrantPagesPerRun) { break }
                $png = $rendered.Pages[$i]
                try {
                    # Stubs are scanned on their side. Tesseract's orientation
                    # check says how far to turn the page; if the reading is
                    # still poor, the other right angles are tried and the best
                    # reading kept.
                    $rotation = Get-PageRotation -Exe $Tesseract -Png $png
                    $upright = Rotate-Png -Png $png -Degrees $rotation
                    $read = Read-PngWithTesseract -Exe $Tesseract -Png $upright -Psm '6'
                    if ($read.Confidence -lt 60) {
                        foreach ($alt in 0, 90, 180, 270) {
                            if ($alt -eq $rotation) { continue }
                            $altPng = Rotate-Png -Png $png -Degrees $alt
                            $altRead = Read-PngWithTesseract -Exe $Tesseract -Png $altPng -Psm '6'
                            if ($altRead.Confidence -gt $read.Confidence + 10) {
                                $read = $altRead; $upright = $altPng; $rotation = $alt
                            }
                        }
                    }
                    $jpeg = Join-Path $work ('page{0:D3}.jpg' -f $pageNo)
                    Save-PageJpeg -Png $upright -Out $jpeg
                    $sentPage = Send-WarrantPage -Entry $entry -PageNo $pageNo -PageCount $rendered.PageCount `
                        -Read $read -Rotation $rotation -JpegPath $jpeg
                    if ($sentPage.already) {
                        Write-Log "Warrant page $pageNo of $($entry.path) was already with the CRM."
                    } else {
                        Write-Log ("Warrant page {0}/{1} ({2}, turned {3}, confidence {4}%): {5} - {6} line(s), {7} reconciled, {8} already recorded, {9} to review" -f `
                            $pageNo, $rendered.PageCount, $sentPage.warrant_no, $rotation, [Math]::Round($read.Confidence),
                            $sentPage.status, $sentPage.lines, $sentPage.reconciled, $sentPage.already_recorded, $sentPage.needs_review)
                    }
                    $warrantPagesSent++
                } catch {
                    Write-Log "Warrant page $pageNo of $($entry.path) not sent, will try again: $($_.Exception.Message)" 'warn'
                }
            }
        } catch {
            Write-Log "Could not read $($entry.path): $($_.Exception.Message)" 'warn'
        } finally {
            Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

# ── scans the CRM would like read ────────────────────────────
# Documents the CRM holds with no text and no OCR yet - ones that arrived
# before this machine had Tesseract, or that this could not tell about. Read
# from this machine's own copy, matched by hash, a few per run.
$ocrSent = 0

# Scans OCR could not finish, and when, kept beside this script. One scan with
# a page Tesseract cannot read in two minutes would otherwise be the first
# thing the CRM asks for on every run, costing minutes each time; it is tried
# again after a week. A read that succeeds - text or none - takes it off.
$FailedPath = Join-Path $Here 'ocr-failed.json'
$failedOcr = @{}
try {
    if (Test-Path -LiteralPath $FailedPath) {
        $saved = Get-Content -LiteralPath $FailedPath -Raw | ConvertFrom-Json
        foreach ($p in $saved.PSObject.Properties) { $failedOcr[$p.Name] = [datetime]$p.Value }
    }
} catch { $failedOcr = @{} }

if ($Tesseract -and $OcrPerRun -gt 0) {
    $ask = $null
    try {
        $ask = Invoke-RestMethod -Method Post -Uri "$BaseUrl/api/agent/ocr-wanted" `
            -Headers $headers -ContentType 'application/json' `
            -Body (@{ limit = $OcrPerRun } | ConvertTo-Json -Compress) -TimeoutSec 60
    } catch {
        # A CRM that does not have this address yet is not this run failing.
        Write-Log "The CRM did not ask for any OCR: $($_.Exception.Message)" 'warn'
    }
    foreach ($w in @($ask.wanted)) {
        if (-not $w) { continue }
        $local = $entries | Where-Object { $_.hash -eq $w.hash } | Select-Object -First 1
        if (-not $local) { continue }
        if ($failedOcr.ContainsKey($w.hash) -and $failedOcr[$w.hash] -gt (Get-Date).AddDays(-7)) {
            Write-Log "Skipping OCR for now (failed $($failedOcr[$w.hash].ToString('s'))): $($local.path)"
            continue
        }
        Write-Log "The CRM asked for OCR: $($local.path)"
        $read = Get-Ocr $local.full
        if (-not $read) {
            $failedOcr[$w.hash] = Get-Date
            continue
        }
        $failedOcr.Remove($w.hash)
        try {
            $answer = Send-Ocr $w.hash $read
            $filed = if ($answer.filed) { " ($($answer.filed))" } else { '' }
            Write-Log "OCR sent: $($local.path) -> $($answer.ocr)$filed"
            $ocrSent++
        } catch {
            Write-Log "OCR not sent for $($local.path): $($_.Exception.Message)" 'warn'
        }
    }
}

try {
    $keep = [ordered]@{}
    foreach ($k in $failedOcr.Keys) {
        if ($failedOcr[$k] -gt (Get-Date).AddDays(-7)) { $keep[$k] = $failedOcr[$k].ToString('o') }
    }
    ($keep | ConvertTo-Json -Compress) | Set-Content -LiteralPath $FailedPath -Encoding utf8
} catch { }

Write-Log "Run finished. $sent sent, $failed failed, $ocrSent read with OCR on request, $warrantPagesSent warrant page(s) read."
Trim-Log

# A run that could not send anything it meant to is a failed run, so the task
# history shows red rather than green.
if ($failed -gt 0 -and $sent -eq 0) { exit 1 }
exit 0
