#Requires -Version 5.1
<#
.SYNOPSIS
    Universal Podcast Downloader (PowerShell Version)
.DESCRIPTION
    Ein plattformübergreifendes, robustes Skript zur automatisierten Archivierung
    von Podcasts. Unterstützt RSS/Atom-Feeds, OPML-Import, Multithreading (ab PS7),
    Resume-Funktionalität bei Verbindungsabbrüchen und M3U-Playlisten.
#>

param (
    [string]$Url = "https://beispiel-url.de/podcast/feed.rss",
    [string]$Config = "",
    [string]$Opml = "",
    [string]$Output = (Join-Path -Path $(if ($PSScriptRoot) { $PSScriptRoot } else { Get-Location }) -ChildPath "Podcasts"),
    [int]$Limit = 0,
    [int]$Retries = 3,
    [int]$TimeoutSec = 60,
    [int]$Workers = 1,
    [switch]$DryRun,
    [switch]$M3u
)

# Punkt 10: Ungültige Workers-Werte abfangen
if ($Workers -lt 1) { $Workers = 1 }

$global:SharedState = [hashtable]::Synchronized(@{
    AbortEvent = $false
    ChunkSize = 1MB
    MaxFileSize = 1GB
    UserAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"
})

try {
    [System.Console]::add_CancelKeyPress({
        $Event.SourceEventArgs.Cancel = $true
        $global:SharedState.AbortEvent = $true
        Write-Host "`n[WARNUNG] Abbruch durch Benutzer. Stoppe Warteschlange und aktive Downloads..." -ForegroundColor Yellow
    })
} catch {}

$script:ReservedNames = @("CON", "PRN", "AUX", "NUL", "COM1", "COM2", "COM3", "COM4", "COM5", "COM6", "COM7", "COM8", "COM9", "LPT1", "LPT2", "LPT3", "LPT4", "LPT5", "LPT6", "LPT7", "LPT8", "LPT9")

function Write-Log {
    param([string]$Message, [string]$Level="INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $color = switch ($Level) {
        "INFO" { "Cyan" }
        "SUCCESS" { "Green" }
        "WARN" { "Yellow" }
        "ERROR" { "Red" }
        default { "White" }
    }
    Write-Host "[$timestamp] [$Level] $Message" -ForegroundColor $color
}

function Get-SafeFileName {
    param([string]$Title)
    # Punkt 8: Steuerzeichen und trailing Dots/Spaces entfernen
    $safeTitle = $Title -replace '[\x00-\x1F<>:"/\\|?*]', '-'
    $safeTitle = $safeTitle.TrimEnd('. ').Trim()
    if ($safeTitle.Length -gt 150) { $safeTitle = $safeTitle.Substring(0, 150).TrimEnd('. ').Trim() }
    if ($script:ReservedNames -contains $safeTitle.ToUpper()) { $safeTitle = "Episode_$safeTitle" }
    return $safeTitle
}

function Get-DownloadManifest {
    # GUID-Manifest eines Feed-Ordners laden: merkt sich bereits geladene Episoden,
    # damit ein geänderter Titel keinen erneuten Download derselben Episode auslöst.
    param([string]$Folder)
    $manifestPath = Join-Path -Path $Folder -ChildPath ".downloaded.json"
    if (-not (Test-Path $manifestPath)) { return @{} }
    try {
        $raw = Get-Content $manifestPath -Raw | ConvertFrom-Json
        $manifest = @{}
        if ($raw) {
            foreach ($prop in $raw.PSObject.Properties) { $manifest[$prop.Name] = $prop.Value }
        }
        return $manifest
    } catch { return @{} }
}

function Save-DownloadManifest {
    param([string]$Folder, [hashtable]$Manifest)
    $manifestPath = Join-Path -Path $Folder -ChildPath ".downloaded.json"
    try {
        $Manifest | ConvertTo-Json | Out-File -FilePath $manifestPath -Encoding UTF8
    } catch {
        Write-Log "Konnte Manifest nicht speichern: $_" -Level "ERROR"
    }
}

function Invoke-CleanupOldParts {
    param([string]$Folder, [int]$DaysOld = 7)
    if (-not (Test-Path $Folder)) { return }
    $cutoffDate = (Get-Date).AddDays(-$DaysOld)
    $oldParts = Get-ChildItem -Path $Folder -Filter "*.part" -Recurse | Where-Object { $_.LastWriteTime -lt $cutoffDate }

    if ($oldParts) {
        $oldParts | Remove-Item -Force
        Write-Log "Bereinigung: $($oldParts.Count) veraltete .part-Datei(en) gelöscht." -Level "INFO"
    }
}

function Invoke-RobustDownload {
    param(
        [string]$DownloadUrl,
        [string]$FinalPath,
        [string]$PartPath,
        [int]$MaxRetries,
        [int]$TimeoutSec,
        [int]$ProgressId = 1,
        [hashtable]$State
    )

    for ($attempt = 1; $attempt -le $MaxRetries; $attempt++) {
        if ($State.AbortEvent) { return $false }
        $progressStarted = $false

        try {
            $request = [System.Net.HttpWebRequest][System.Net.WebRequest]::Create($DownloadUrl)
            $request.UserAgent = $State.UserAgent
            $request.Timeout = $TimeoutSec * 1000

            $initialSize = 0
            $appendMode = $false

            if (Test-Path -Path $PartPath) {
                $initialSize = (Get-Item -Path $PartPath).Length
                if ($initialSize -gt 0) {
                    $request.AddRange($initialSize)
                    $appendMode = $true
                }
            }

            $response = $request.GetResponse()
            $totalSize = if ($response.ContentLength -ge 0) { $response.ContentLength + $initialSize } else { 0 }

            # Initiale Größenprüfung (Punkt 5)
            if ($totalSize -gt $State.MaxFileSize) {
                Write-Log "Datei überschreitet 1GB-Limit, überspringe: $(Split-Path $FinalPath -Leaf)" -Level "WARN"
                return $false
            }

            $isPartial = ($response.StatusCode -eq [System.Net.HttpStatusCode]::PartialContent)

            if ($initialSize -gt 0 -and -not $isPartial) {
                $initialSize = 0
                $appendMode = $false
            }

            # Content-Type validieren: eine Fehlerseite (z.B. HTML/JSON statt Audio) nicht als Episode speichern
            $rejectedContentTypes = @("text/html", "text/plain", "application/json", "application/xml", "text/xml")
            $contentType = if ($response.ContentType) { $response.ContentType.Split(';')[0].Trim().ToLower() } else { "" }
            if ($rejectedContentTypes -contains $contentType) {
                Write-Log "Unerwarteter Content-Type '$contentType' (evtl. Fehlerseite), überspringe: $(Split-Path $FinalPath -Leaf)" -Level "WARN"
                $response.Close()
                return $false
            }

            $fileMode = if ($appendMode -and $isPartial) { [System.IO.FileMode]::Append } else { [System.IO.FileMode]::Create }
            $fileStream = New-Object System.IO.FileStream($PartPath, $fileMode, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
            $responseStream = $response.GetResponseStream()

            $buffer = New-Object byte[] $State.ChunkSize
            $downloaded = $initialSize
            $progressStarted = $true
            $oversized = $false

            $startTime = [datetime]::Now

            try {
                while (($read = $responseStream.Read($buffer, 0, $buffer.Length)) -gt 0) {
                    if ($State.AbortEvent) { throw "Abbruch durch Benutzer (Event)" }

                    $fileStream.Write($buffer, 0, $read)
                    $downloaded += $read

                    # Punkt 5: Dateigrößen-Limit "In-Flight" überwachen (falls Content-Length fehlte).
                    # Bricht sofort ab (kein Retry) statt zu werfen, da die Datei bei jedem
                    # erneuten Versuch wieder das Limit reißen würde.
                    if ($downloaded -gt $State.MaxFileSize) {
                        $oversized = $true
                        break
                    }

                    $elapsed = ([datetime]::Now - $startTime).TotalSeconds
                    $speedMBps = if ($elapsed -gt 0) { (($downloaded - $initialSize) / 1MB) / $elapsed } else { 0 }

                    if ($totalSize -gt 0) {
                        $pct = ($downloaded / $totalSize) * 100
                        $statusText = "{0:N1} MB / {1:N1} MB | {2:N1} MB/s" -f ($downloaded / 1MB), ($totalSize / 1MB), $speedMBps
                        Write-Progress -Id $ProgressId -Activity "Lade: $(Split-Path $FinalPath -Leaf)" -Status $statusText -PercentComplete $pct
                    } else {
                        $statusText = "{0:N1} MB geladen | {1:N1} MB/s" -f ($downloaded / 1MB), $speedMBps
                        Write-Progress -Id $ProgressId -Activity "Lade: $(Split-Path $FinalPath -Leaf)" -Status $statusText
                    }
                }
            } finally {
                if ($fileStream) { $fileStream.Close() }
                if ($responseStream) { $responseStream.Close() }
                if ($response) { $response.Close() }
                if ($progressStarted) { Write-Progress -Id $ProgressId -Activity "Lade: $(Split-Path $FinalPath -Leaf)" -Completed }
            }

            if ($oversized) {
                Write-Log "Datei überschreitet 1GB-Limit während des Downloads, Abbruch: $(Split-Path $FinalPath -Leaf)" -Level "WARN"
                if (Test-Path $PartPath) { Remove-Item $PartPath -Force }
                return $false
            }

            if ($totalSize -gt 0 -and $downloaded -lt $totalSize) {
                throw "Download unvollständig (Verbindung abgerissen)."
            }

            Move-Item -Path $PartPath -Destination $FinalPath -Force
            return $true

        } catch {
            if ($progressStarted) { Write-Progress -Id $ProgressId -Activity "Lade: $(Split-Path $FinalPath -Leaf)" -Completed }
            if ($State.AbortEvent) { return $false }

            $errMsg = $_.Exception.Message

            # Retry-After-Header bei HTTP 429 auslesen (Sekunden oder HTTP-Datum).
            # .GetResponse() wirft aus einem Methodenaufruf heraus, daher steckt die
            # eigentliche WebException oft in InnerException statt direkt in $_.Exception.
            $retryAfter = $null
            $webException = if ($_.Exception -is [System.Net.WebException]) {
                $_.Exception
            } elseif ($_.Exception.InnerException -is [System.Net.WebException]) {
                $_.Exception.InnerException
            } else {
                $null
            }
            if ($webException -and $webException.Response) {
                $webResponse = $webException.Response
                if ([int]$webResponse.StatusCode -eq 429) {
                    $retryAfterHeader = $webResponse.Headers["Retry-After"]
                    if ($retryAfterHeader) {
                        $seconds = 0
                        if ([int]::TryParse($retryAfterHeader, [ref]$seconds)) {
                            $retryAfter = $seconds
                        } else {
                            try {
                                $retryDate = [datetime]::Parse($retryAfterHeader, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AssumeUniversal -bor [System.Globalization.DateTimeStyles]::AdjustToUniversal)
                                $retryAfter = [math]::Max(($retryDate - [datetime]::UtcNow).TotalSeconds, 0)
                            } catch {}
                        }
                    }
                }
                $webResponse.Close()
            }

            if ($attempt -lt $MaxRetries) {
                # Server-seitige Wartezeit (Retry-After) hat Vorrang vor dem gedeckelten Backoff (max 60s)
                $sleepTime = if ($null -ne $retryAfter) { [math]::Min($retryAfter, 300) } else { [math]::Min([math]::Pow(2, $attempt), 60) }
                Write-Log "Fehler bei Versuch $attempt/${MaxRetries}: $errMsg. Warte ${sleepTime}s..." -Level "WARN"

                for ($i = 0; $i -lt ($sleepTime * 10); $i++) {
                    if ($State.AbortEvent) { return $false }
                    Start-Sleep -Milliseconds 100
                }
            } else {
                Write-Log "Fehlgeschlagen nach $MaxRetries Versuchen: $(Split-Path $FinalPath -Leaf)" -Level "ERROR"
                if (Test-Path $PartPath) { Remove-Item $PartPath -Force }
            }
        }
    }
    return $false
}

function New-M3uPlaylist {
    param([string]$Folder, [string]$Title)
    $mp3Files = Get-ChildItem -Path $Folder -Filter "*.mp3" | Sort-Object Name
    if (-not $mp3Files) { return }

    try {
        $playlistPath = Join-Path -Path $Folder -ChildPath "$Title`_Playlist.m3u"
        $content = @("#EXTM3U") + ($mp3Files.Name)
        $content | Out-File -FilePath $playlistPath -Encoding UTF8
        Write-Log "M3U-Playlist generiert: $(Split-Path $playlistPath -Leaf)" -Level "INFO"
    } catch {
        Write-Log "Konnte M3U nicht erstellen: $_" -Level "ERROR"
    }
}

# ------------------------------------------------------------------------------
# HAUPTSKRIPT (MAIN)
# ------------------------------------------------------------------------------

$feedUrls = @()

# Punkt 6: Config überprüfen mit expliziter Warnung
$configToLoad = ""
if (-not [string]::IsNullOrWhiteSpace($Config)) {
    if (Test-Path $Config) {
        $configToLoad = $Config
    } else {
        Write-Log "Angegebene Konfigurationsdatei '$Config' nicht gefunden! Verwende Standardwerte." -Level "WARN"
    }
} elseif (Test-Path "config.json") {
    $configToLoad = "config.json"
}

if (-not [string]::IsNullOrWhiteSpace($configToLoad)) {
    Write-Log "Lade Konfiguration aus: $configToLoad" -Level "INFO"
    try {
        $cfg = Get-Content $configToLoad -Raw | ConvertFrom-Json
        if ($cfg.url) { $feedUrls += $cfg.url }
        if ($cfg.urls) { $feedUrls += $cfg.urls }
        if ($cfg.output -and $Output -eq (Join-Path -Path $(if ($PSScriptRoot) { $PSScriptRoot } else { Get-Location }) -ChildPath "Podcasts")) { $Output = $cfg.output }

        if ($null -ne $cfg.limit -and $Limit -eq 0) { $Limit = [int]$cfg.limit }
        if ($null -ne $cfg.workers -and $Workers -eq 1) { $Workers = [int]$cfg.workers }
        if ($null -ne $cfg.retries -and $Retries -eq 3) { $Retries = [int]$cfg.retries }
        if ($null -ne $cfg.timeout -and $TimeoutSec -eq 60) { $TimeoutSec = [int]$cfg.timeout }
        if ($null -ne $cfg.m3u -and -not $M3u) { $M3u = [bool]$cfg.m3u }
        if ($null -ne $cfg.dry_run -and -not $DryRun) { $DryRun = [bool]$cfg.dry_run }

        if ($Workers -lt 1) { $Workers = 1 }
    } catch { Write-Log "Fehler beim Lesen der ${configToLoad}: $_" -Level "ERROR" }
}

if (-not [string]::IsNullOrWhiteSpace($Opml) -and (Test-Path $Opml)) {
    try {
        [xml]$opmlXml = Get-Content $Opml
        $feedUrls += @($opmlXml.SelectNodes("//outline[@xmlUrl]") | ForEach-Object { $_.xmlUrl })
    } catch { Write-Log "Fehler beim Parsen der OPML-Datei: $_" -Level "ERROR" }
}

if (-not [string]::IsNullOrWhiteSpace($Url) -and $Url -ne "https://beispiel-url.de/podcast/feed.rss") {
    $feedUrls += $Url
}

if ($feedUrls.Count -eq 0) { $feedUrls += "https://beispiel-url.de/podcast/feed.rss" }

# Punkt 7: Reihenfolge bei der Dublettenprüfung erhalten
$uniqueUrls = @()
foreach ($f in $feedUrls) {
    if ($uniqueUrls -notcontains $f) { $uniqueUrls += $f }
}
$feedUrls = $uniqueUrls

if (-not $DryRun) {
    if (-not (Test-Path -Path $Output)) {
        New-Item -ItemType Directory -Path $Output | Out-Null
        Write-Log "Basis-Verzeichnis erstellt: $Output" -Level "SUCCESS"
    }
    Invoke-CleanupOldParts -Folder $Output
}

if ($PSVersionTable.PSEdition -eq "Desktop") {
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13 }
    catch { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 }
}

$totalDownloaded = 0
$totalSkipped = 0
$totalFailed = 0

foreach ($feedUrl in $feedUrls) {
    if ($global:SharedState.AbortEvent) { break }
    Write-Log "Analysiere Feed: $feedUrl"

    try {
        # Punkt 3: TimeoutSec wird nun korrekt durchgereicht
        $feedRequest = Invoke-WebRequest -Uri $feedUrl -UserAgent $global:SharedState.UserAgent -UseBasicParsing -TimeoutSec $TimeoutSec
        [xml]$feed = $feedRequest.Content
    } catch {
        Write-Log "Überspringe Feed wegen Fehler: $_" -Level "ERROR"
        continue
    }

    # Punkt 1 & 2: Feed-Titel parsen und Unterordner generieren
    $channelTitleNode = $feed.SelectSingleNode("//*[local-name()='channel']/*[local-name()='title'] | //*[local-name()='feed']/*[local-name()='title']")
    $feedTitle = if ($channelTitleNode -and -not [string]::IsNullOrWhiteSpace($channelTitleNode.InnerText)) {
        Get-SafeFileName -Title $channelTitleNode.InnerText
    } else {
        "Unbekannter_Podcast"
    }

    $feedOutputFolder = Join-Path -Path $Output -ChildPath $feedTitle

    if (-not $DryRun -and -not (Test-Path $feedOutputFolder)) {
        New-Item -ItemType Directory -Path $feedOutputFolder | Out-Null
    }

    # GUID-Manifest laden: erkennt bereits geladene Episoden auch dann wieder,
    # wenn sich der Titel (und damit der Dateiname) im Feed geändert hat.
    $manifest = Get-DownloadManifest -Folder $feedOutputFolder

    $items = $feed.SelectNodes("//*[local-name()='item' or local-name()='entry']")
    if (-not $items -or $items.Count -eq 0) { continue }

    if ($Limit -gt 0) { $items = $items | Select-Object -First $Limit }

    $tasks = @()

    foreach ($item in $items) {
        $titleNode = $item.SelectSingleNode("*[local-name()='title']")
        $title = if ($titleNode) { $titleNode.InnerText.Trim() } else { "Unbekannte_Episode" }

        $mediaUrl = $null
        $enclosure = $item.SelectSingleNode("*[local-name()='enclosure']")
        if ($enclosure -and $enclosure.HasAttribute("url")) { $mediaUrl = $enclosure.GetAttribute("url") }
        else {
            $linkNode = $item.SelectSingleNode("*[local-name()='link' and @rel='enclosure']")
            if ($linkNode -and $linkNode.HasAttribute("href")) { $mediaUrl = $linkNode.GetAttribute("href") }
        }

        if (-not [string]::IsNullOrWhiteSpace($mediaUrl)) {
            $safeTitle = Get-SafeFileName -Title $title

            $guidNode = $item.SelectSingleNode("*[local-name()='guid' or local-name()='id']")
            $guid = if ($guidNode -and -not [string]::IsNullOrWhiteSpace($guidNode.InnerText)) { $guidNode.InnerText.Trim() } else { $null }
            $dedupKey = if ($guid) { $guid } else { $mediaUrl }

            $prefix = ""
            $epNode = $item.SelectSingleNode("*[local-name()='episode']")
            if ($epNode -and $epNode.InnerText -match "^\d+$") { $prefix = "{0:D3} - " -f [int]($epNode.InnerText.Trim()) }
            else {
                $pubDateNode = $item.SelectSingleNode("*[local-name()='pubDate' or local-name()='published' or local-name()='updated']")
                if ($pubDateNode) { try { $prefix = ([datetime]$pubDateNode.InnerText).ToString("yyyy-MM-dd") + " - " } catch {} }
            }

            $urlWithoutQuery = $mediaUrl.Split('?')[0]
            $extension = [System.IO.Path]::GetExtension($urlWithoutQuery)
            if ([string]::IsNullOrWhiteSpace($extension)) { $extension = ".mp3" }

            $fileName = "$prefix$safeTitle$extension"
            # Speichere die Datei im neuen Feed-Unterordner
            $filePath = Join-Path -Path $feedOutputFolder -ChildPath $fileName
            $partPath = "$filePath.part"

            # Dedup primär über die GUID, zusätzlich über Dateiexistenz (Altbestand ohne Manifest)
            if ($manifest.ContainsKey($dedupKey) -or (Test-Path -Path $filePath)) {
                Write-Log "Überspringe: $fileName" -Level "INFO"
                $totalSkipped++
            } else {
                $tasks += [PSCustomObject]@{ Url = $mediaUrl; Final = $filePath; Part = $partPath; Name = $fileName; DedupKey = $dedupKey }
            }
        }
    }

    if ($DryRun) {
        foreach ($t in $tasks) { Write-Log "DRY-RUN: Würde laden: $($t.Name)" -Level "INFO" }
        continue
    }

    if ($tasks.Count -gt 0) {
        Write-Log "Starte Download von $($tasks.Count) Episoden in '$feedTitle' (Workers: $Workers)..."

        if ($Workers -gt 1 -and $PSVersionTable.PSVersion.Major -ge 7) {
            $funcRobustStr = ${function:Invoke-RobustDownload}.ToString()
            $funcLogStr = ${function:Write-Log}.ToString()
            $shared = $global:SharedState

            $results = $tasks | ForEach-Object -Parallel {
                Set-Item -Path "Function:Invoke-RobustDownload" -Value ([scriptblock]::Create($using:funcRobustStr))
                Set-Item -Path "Function:Write-Log" -Value ([scriptblock]::Create($using:funcLogStr))

                $task = $_
                $workerId = [System.Threading.Thread]::CurrentThread.ManagedThreadId

                $success = Invoke-RobustDownload -DownloadUrl $task.Url -FinalPath $task.Final -PartPath $task.Part -MaxRetries $using:Retries -TimeoutSec $using:TimeoutSec -ProgressId $workerId -State $using:shared

                if ($success) { Write-Log "✔ Abgeschlossen: $($task.Name)" -Level "SUCCESS" }
                [PSCustomObject]@{ Success = $success; DedupKey = $task.DedupKey; Name = $task.Name }
            } -ThrottleLimit $Workers

            $succeeded = @($results | Where-Object Success -eq $true)
            $totalDownloaded += $succeeded.Count
            $totalFailed += ($results | Where-Object Success -eq $false).Count

            if ($succeeded.Count -gt 0) {
                foreach ($r in $succeeded) { $manifest[$r.DedupKey] = $r.Name }
                Save-DownloadManifest -Folder $feedOutputFolder -Manifest $manifest
            }
        }
        else {
            if ($Workers -gt 1) { Write-Log "Multithreading erfordert PowerShell 7+. Führe Downloads sequenziell aus." -Level "WARN" }

            foreach ($task in $tasks) {
                if ($global:SharedState.AbortEvent) { break }
                $success = Invoke-RobustDownload -DownloadUrl $task.Url -FinalPath $task.Final -PartPath $task.Part -MaxRetries $Retries -TimeoutSec $TimeoutSec -ProgressId 1 -State $global:SharedState

                if ($success) {
                    Write-Log "✔ Abgeschlossen: $($task.Name)" -Level "SUCCESS"
                    $totalDownloaded++
                    $manifest[$task.DedupKey] = $task.Name
                    Save-DownloadManifest -Folder $feedOutputFolder -Manifest $manifest
                } else {
                    if (-not $global:SharedState.AbortEvent) { $totalFailed++ }
                }
            }
        }
    }

    if ($M3u -and -not $DryRun -and -not $global:SharedState.AbortEvent) {
        # Playlist wird nun pro Feed-Ordner und mit passendem Titel erstellt
        New-M3uPlaylist -Folder $feedOutputFolder -Title $feedTitle
    }
}

if (-not $global:SharedState.AbortEvent) {
    Write-Log "=================================================="
    Write-Log "SYNCHRONISATION ABGESCHLOSSEN"
    Write-Log "✅ Heruntergeladen: $totalDownloaded"
    Write-Log "⏭️ Übersprungen:   $totalSkipped"
    if ($totalFailed -gt 0) { Write-Log "❌ Fehlgeschlagen:  $totalFailed" -Level "WARN" }
    Write-Log "=================================================="
    if ($totalFailed -gt 0) { exit 1 }
}
