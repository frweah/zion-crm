<#
    Zion CRM - OCR for scanned PDFs
    ================================

    Dot-sourced by zion-agent.ps1. Reads the text off a PDF that has none of its
    own - a scan - so the CRM has something to read.

    Everything happens on this machine:

      * pages are drawn to images by Windows' own PDF renderer
        (Windows.Data.Pdf), which every copy of Windows 10 and 11 has
      * the images are read by Tesseract (tesseract.exe), installed locally
      * the images are written to a folder of their own under %TEMP% and
        deleted as soon as they have been read

    No page image or text goes anywhere but the CRM, and only with its file.

    PowerShell 5.1. No modules.
#>

# ── Tesseract ────────────────────────────────────────────────
function Find-Tesseract {
    param([string] $Configured)
    $candidates = @(
        $Configured,
        (Join-Path $env:ProgramFiles 'Tesseract-OCR\tesseract.exe'),
        (Join-Path ${env:ProgramFiles(x86)} 'Tesseract-OCR\tesseract.exe'),
        (Join-Path $env:LOCALAPPDATA 'Programs\Tesseract-OCR\tesseract.exe')
    ) | Where-Object { $_ }
    foreach ($c in $candidates) { if (Test-Path -LiteralPath $c) { return $c } }
    return $null
}

function Get-TesseractVersion {
    param([string] $Exe)
    $out = [System.IO.Path]::GetTempFileName()
    try {
        # Tesseract prints its version to stdout on 5.x and stderr on older
        # builds; both are captured, neither is allowed to throw.
        Start-Process -FilePath $Exe -ArgumentList '--version' -NoNewWindow -Wait `
            -RedirectStandardOutput $out -RedirectStandardError "$out.err" | Out-Null
        $first = @(Get-Content $out, "$out.err" -ErrorAction SilentlyContinue | Where-Object { $_ -match 'tesseract' })[0]
        if ($first) { return ($first.Trim()) } else { return 'tesseract' }
    } finally {
        Remove-Item $out, "$out.err" -ErrorAction SilentlyContinue
    }
}

# ── does it have text of its own? ────────────────────────────
# Text on a PDF page is drawn by operators inside the page's content stream:
# BT ... Tj/TJ ... ET. A scan's content stream only places an image. So each
# stream that is not itself an image is unpacked (Flate, the compression nearly
# every PDF uses) and searched for those operators.
#
# Looking for "/Font" was tried first and is wrong: scanner software often
# declares a font it never uses, and the first real scan tested said "has
# text" with nothing on its pages to read.
#
# A mistake either way costs little. Called "no text" wrongly, a PDF is read by
# Tesseract for nothing and the CRM ignores the OCR because it has a text layer.
# Called "has text" wrongly, the CRM finds no text and asks for OCR on the next
# run (/api/agent/ocr-wanted).
function Test-PdfHasTextLayer {
    param([string] $Path)
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $latin1 = [System.Text.Encoding]::GetEncoding('iso-8859-1')
    $raw = $latin1.GetString($bytes)
    $textOps = [regex] '(?s)\bBT\b.{0,4000}?(?:\bTj\b|\bTJ\b|\s''|\s")'

    $pos = 0
    while ($true) {
        $s = $raw.IndexOf('stream', $pos)
        if ($s -lt 0) { break }
        if ($s -ge 3 -and $raw.Substring($s - 3, 3) -eq 'end') { $pos = $s + 6; continue }

        $start = $s + 6
        if ($start -lt $raw.Length -and $raw[$start] -eq "`r") { $start++ }
        if ($start -lt $raw.Length -and $raw[$start] -eq "`n") { $start++ }
        $end = $raw.IndexOf('endstream', $start)
        if ($end -lt 0) { break }
        $pos = $end + 9

        $dictFrom = [Math]::Max(0, $s - 400)
        $dict = $raw.Substring($dictFrom, $s - $dictFrom)
        $dict = $dict.Substring([Math]::Max(0, $dict.LastIndexOf('obj')))
        if ($dict -match '/Subtype\s*/Image') { continue }

        $length = $end - $start
        $content = $null
        if ($dict -match '/FlateDecode') {
            if ($length -lt 3 -or $length -gt 20MB) { continue }
            try {
                # Skip the two-byte zlib header; DeflateStream wants raw deflate.
                $ms = New-Object System.IO.MemoryStream($bytes, $start + 2, $length - 2)
                $ds = New-Object System.IO.Compression.DeflateStream($ms, [System.IO.Compression.CompressionMode]::Decompress)
                $out = New-Object System.IO.MemoryStream
                $buffer = New-Object byte[] 65536
                while (($n = $ds.Read($buffer, 0, $buffer.Length)) -gt 0) {
                    $out.Write($buffer, 0, $n)
                    if ($out.Length -gt 8MB) { break }
                }
                $content = $latin1.GetString($out.ToArray())
                $ds.Dispose(); $ms.Dispose(); $out.Dispose()
            } catch {
                continue
            }
        } elseif ($dict -notmatch '/Filter') {
            $content = $raw.Substring($start, [Math]::Min($length, 8MB))
        }

        if ($content -and $textOps.IsMatch($content)) { return $true }
    }
    return $false
}

# ── Windows' PDF renderer ────────────────────────────────────
$script:WinRtReady = $false
function Initialize-WinRt {
    if ($script:WinRtReady) { return }
    Add-Type -AssemblyName System.Runtime.WindowsRuntime
    $null = [Windows.Storage.StorageFile, Windows.Storage, ContentType = WindowsRuntime]
    $null = [Windows.Data.Pdf.PdfDocument, Windows.Data.Pdf, ContentType = WindowsRuntime]
    $null = [Windows.Data.Pdf.PdfPageRenderOptions, Windows.Data.Pdf, ContentType = WindowsRuntime]
    $null = [Windows.Storage.Streams.InMemoryRandomAccessStream, Windows.Storage.Streams, ContentType = WindowsRuntime]
    $methods = [System.WindowsRuntimeSystemExtensions].GetMethods()
    $script:AsTaskOperation = $methods | Where-Object {
        $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and
        $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1'
    } | Select-Object -First 1
    $script:AsTaskAction = $methods | Where-Object {
        $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and
        $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncAction'
    } | Select-Object -First 1
    $script:WinRtReady = $true
}

function Wait-WinRtOperation {
    param($Operation, [Type] $ResultType)
    $task = $script:AsTaskOperation.MakeGenericMethod($ResultType).Invoke($null, @($Operation))
    [void] $task.Wait()
    return $task.Result
}

function Wait-WinRtAction {
    param($Action)
    $task = $script:AsTaskAction.Invoke($null, @($Action))
    [void] $task.Wait()
}

<#
    Draws pages of a PDF to PNG files at 300 dpi, the resolution Tesseract is
    trained for. Returns the file paths, in page order.
#>
function Convert-PdfToPngs {
    param([string] $Path, [string] $WorkDir, [int] $MaxPages = 10, [int] $Dpi = 300)
    Initialize-WinRt
    $file = Wait-WinRtOperation ([Windows.Storage.StorageFile]::GetFileFromPathAsync($Path)) ([Windows.Storage.StorageFile])
    $pdf  = Wait-WinRtOperation ([Windows.Data.Pdf.PdfDocument]::LoadFromFileAsync($file)) ([Windows.Data.Pdf.PdfDocument])

    $scale = $Dpi / 96.0
    $count = [Math]::Min([int]$pdf.PageCount, $MaxPages)
    $pngs = @()
    for ($i = 0; $i -lt $count; $i++) {
        $page = $pdf.GetPage([uint32]$i)
        try {
            $options = New-Object Windows.Data.Pdf.PdfPageRenderOptions
            $options.DestinationWidth  = [uint32][Math]::Round($page.Size.Width * $scale)
            $options.DestinationHeight = [uint32][Math]::Round($page.Size.Height * $scale)

            $stream = New-Object Windows.Storage.Streams.InMemoryRandomAccessStream
            try {
                Wait-WinRtAction ($page.RenderToStreamAsync($stream, $options))
                $png = Join-Path $WorkDir ('page{0:D3}.png' -f ($i + 1))
                $input = [System.IO.WindowsRuntimeStreamExtensions]::AsStreamForRead($stream.GetInputStreamAt(0))
                $output = [System.IO.File]::Create($png)
                try { $input.CopyTo($output) } finally { $output.Dispose(); $input.Dispose() }
                $pngs += $png
            } finally {
                $stream.Dispose()
            }
        } finally {
            $page.Dispose()
        }
    }
    return [pscustomobject]@{ Pages = $pngs; PageCount = [int]$pdf.PageCount }
}

<#
    One page image through Tesseract, as TSV so every word comes with its
    confidence. The text is rebuilt line by line from the words, and the
    confidence is the mean over the words Tesseract actually recognised.
#>
function Read-PngWithTesseract {
    param([string] $Exe, [string] $Png, [string] $Language = 'eng', [int] $TimeoutSeconds = 120)
    $base = [System.IO.Path]::Combine([System.IO.Path]::GetDirectoryName($Png), [System.IO.Path]::GetFileNameWithoutExtension($Png))
    $err  = "$base.err"
    $proc = Start-Process -FilePath $Exe -ArgumentList @("`"$Png`"", "`"$base`"", '-l', $Language, '--dpi', '300', 'tsv') `
        -NoNewWindow -PassThru -RedirectStandardError $err -RedirectStandardOutput "$base.out"
    # Hold the process handle now. Windows PowerShell 5.1 hands back an empty
    # ExitCode for a process started with -PassThru and waited on with a
    # timeout unless its handle was taken while it ran - and an empty exit code
    # is "not 0". Agent 1.1.0 shipped without this line: every page Tesseract
    # read perfectly well was reported as a failure.
    $null = $proc.Handle

    # A page normally takes a few seconds. The first backfill met one that
    # Tesseract was still chewing on after five minutes; left alone, one bad
    # page would hold every scheduled run behind it. Two minutes, then give up
    # on that document and move on.
    if (-not $proc.WaitForExit($TimeoutSeconds * 1000)) {
        try { $proc.Kill() } catch { }
        throw "tesseract gave up after $TimeoutSeconds seconds on one page"
    }
    # The timed wait can return before redirected output is flushed; the
    # untimed one after it finishes the job and fills in the exit code.
    $proc.WaitForExit()
    if ($proc.ExitCode -ne 0) {
        $why = (Get-Content $err -ErrorAction SilentlyContinue | Select-Object -Last 1)
        throw "tesseract exited $($proc.ExitCode): $why"
    }

    $rows = Import-Csv -Path "$base.tsv" -Delimiter "`t" -Encoding UTF8
    $lines = [ordered]@{}
    $confs = New-Object System.Collections.Generic.List[double]
    foreach ($r in $rows) {
        if ($r.level -ne '5') { continue }
        $word = [string]$r.text
        if (-not $word.Trim()) { continue }
        $key = '{0}.{1}.{2}.{3}' -f $r.page_num, $r.block_num, $r.par_num, $r.line_num
        if (-not $lines.Contains($key)) { $lines[$key] = New-Object System.Collections.Generic.List[string] }
        $lines[$key].Add($word)
        $c = 0.0
        if ([double]::TryParse($r.conf, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$c) -and $c -ge 0) {
            $confs.Add($c)
        }
    }
    $text = ($lines.Values | ForEach-Object { $_ -join ' ' }) -join "`n"
    $mean = if ($confs.Count) { ($confs | Measure-Object -Average).Average } else { 0 }
    return [pscustomobject]@{ Text = $text; Confidence = $mean; Words = $confs.Count }
}

<#
    A whole PDF. Returns text, confidence (mean over all words), the engine,
    and how many pages were read. Text is empty when Tesseract read the pages
    and found nothing; a failure throws instead, so "nothing on the page" and
    "could not read the page" can never be confused. Temporary images are
    removed whatever happens.
#>
function Invoke-PdfOcr {
    param([string] $Path, [string] $Exe, [string] $Engine, [int] $MaxPages = 10)
    $work = Join-Path $env:TEMP ('zion-agent-ocr-' + [System.Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $work -Force | Out-Null
    try {
        $rendered = Convert-PdfToPngs -Path $Path -WorkDir $work -MaxPages $MaxPages
        $texts = @()
        $weighted = 0.0
        $words = 0
        foreach ($png in $rendered.Pages) {
            $page = Read-PngWithTesseract -Exe $Exe -Png $png
            $texts += $page.Text
            $weighted += $page.Confidence * $page.Words
            $words += $page.Words
        }
        $text = ($texts -join "`n`f`n").Trim()
        return [pscustomobject]@{
            Text       = $text
            Confidence = if ($words) { [Math]::Round($weighted / $words, 2) } else { 0 }
            Engine     = $Engine
            Pages      = $rendered.Pages.Count
            PageCount  = $rendered.PageCount
        }
    } finally {
        Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function ConvertTo-Base64Utf8 {
    param([string] $Text)
    return [System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($Text))
}
