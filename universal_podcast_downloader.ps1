#Requires -Version 5.1
<#
.SYNOPSIS
    Universal Podcast Downloader (PowerShell Version)
.DESCRIPTION
    Ein plattformübergreifendes, robustes Skript zur automatisierten Archivierung
    von Podcasts. Unterstützt RSS/Atom-Feeds, OPML-Import, Multithreading (ab PS7), 
    Resume-Funktionalität bei Verbindungsabbrüchen und M3U-Playlisten.
#>

# ==============================================================================
# BENUTZER-EINSTELLUNGEN / CLI-PARAMETER
# ==============================================================================
param (
    [string]$Url = "https://beispiel-url.de/podcast/feed.rss",
    [string]$Config = "",
    [string]$Opml = "",
    [string]$Output = (Join-Path -Path $HOME -ChildPath "Podcasts\MeinPodcast"),
    [int]$Limit = 0,
    [int]$Retries = 3,
    [int]$TimeoutSec = 60,
    [int]$Workers = 1,
    [switch]$DryRun,
    [switch]$M3u
)

# ------------------------------------------------------------------------------
# GLOBALER ZUSTAND (Thread-Safe für Parallel-Verarbeitung)
# ------------------------------------------------------------------------------
# In isolierten Threads (Runspaces) sind reguläre $global Variablen nicht verfügbar.
# Wir nutzen eine synchronisierte Hashtabelle, damit der Haupt-Thread (Strg+C) 
# sicher mit den Download-Threads kommunizieren kann.
$global:SharedState = [hashtable]::Synchronized(@{
    AbortEvent = $false
    ChunkSize = 1MB
    MaxFileSize = 1GB
    UserAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"
})

# Registrierung eines .NET-Events, um Strg+C (KeyboardInterrupt) sauber abzufangen
try {
    [System.Console]::add_CancelKeyPress({
        $Event.SourceEventArgs.Cancel = $true
        $global:SharedState.AbortEvent = $true
        Write-Host "`n[WARNUNG] Abbruch durch Benutzer. Stoppe Warteschlange und aktive Downloads..." -ForegroundColor Yellow
    })
} catch {
    # Fallback, falls die Konsole das Event nicht unterstützt
}

# Reservierte Windows-Namen auf Skript-Ebene abfangen
$script:ReservedNames = @("CON", "PRN", "AUX", "NUL", "COM1", "COM2", "COM3", "COM4", "COM5", "COM6", "COM7", "COM8", "COM9", "LPT1", "LPT2", "LPT3", "LPT4", "LPT5", "LPT6", "LPT7", "LPT8", "LPT9")

# ------------------------------------------------------------------------------
# HILFSFUNKTIONEN
# ------------------------------------------------------------------------------

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
    $safeTitle = $Title -replace '[<>:"/\\|?*]', '-'
    if ($safeTitle.Length -gt 150) { $safeTitle = $safeTitle.Substring(0, 150).Trim() }
    if ($script:ReservedNames -contains $safeTitle.ToUpper()) { $safeTitle = "Episode_$safeTitle" }
    return $safeTitle.Trim()
}

function Invoke-CleanupOldParts {
    param([string]$Folder, [int]$DaysOld = 7)
    $cutoffDate = (Get-Date).AddDays(-$DaysOld)
    $oldParts = Get-ChildItem -Path $Folder -Filter "*.part" | Where-Object { $_.LastWriteTime -lt $cutoffDate }
    
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
        [int]$ProgressId = 1, # Eindeutige ID für parallele Fortschrittsbalken
        [hashtable]$State     # Der übergebene thread-sichere Status
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
            
            if ($totalSize -gt $State.MaxFileSize) {
                Write-Log "Datei überschreitet 1GB-Limit, überspringe: $(Split-Path $FinalPath -Leaf)" -Level "WARN"
                return $false
            }

            $isPartial = ($response.StatusCode -eq [System.Net.HttpStatusCode]::PartialContent)
            
            if ($initialSize -gt 0 -and -not $isPartial) {
                $initialSize = 0
                $appendMode = $false
            }

            $fileMode = if ($appendMode -and $isPartial) { [System.IO.FileMode]::Append } else { [System.IO.FileMode]::Create }
            $fileStream = New-Object System.IO.FileStream($PartPath, $fileMode, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
            $responseStream = $response.GetResponseStream()

            $buffer = New-Object byte[] $State.ChunkSize
            $downloaded = $initialSize
            $progressStarted = $true
            
            $startTime = [datetime]::Now

            try {
                while (($read = $responseStream.Read($buffer, 0, $buffer.Length)) -gt 0) {
                    if ($State.AbortEvent) { throw "Abbruch durch Benutzer (Event)" }
                    
                    $fileStream.Write($buffer, 0, $read)
                    $downloaded += $read

                    # PowerShell generiert native, parallele Balken über eindeutige IDs
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

            if ($totalSize -gt 0 -and $downloaded -lt $totalSize) {
                throw "Download unvollständig (Verbindung abgerissen)."
            }

            Move-Item -Path $PartPath -Destination $FinalPath -Force
            return $true

        } catch {
            if ($progressStarted) { Write-Progress -Id $ProgressId -Activity "Lade: $(Split-Path $FinalPath -Leaf)" -Completed }
            if ($State.AbortEvent) { return $false }

            $errMsg = $_.Exception.Message
            if ($attempt -lt $MaxRetries) {
                $sleepTime = [math]::Pow(2, $attempt)
                Write-Log "Fehler bei Versuch $attempt/${MaxRetries}: $errMsg. Warte ${sleepTime}s..." -Level "WARN"
                
                # Sleep in Schritten, um auf ABORT_EVENT reagieren zu können
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
        $playlistPath = Join-Path -Path $Folder -ChildPath "$(Get-SafeFileName -Title $Title)_Playlist.m3u"
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

# 1. Konfiguration einlesen (CLI -> JSON -> OPML -> Defaults)
$feedUrls = @()

# Automatische Erkennung: Falls kein Parameter übergeben wurde, nach config.json suchen
if ([string]::IsNullOrWhiteSpace($Config) -and (Test-Path "config.json")) {
    $Config = "config.json"
}

if (-not [string]::IsNullOrWhiteSpace($Config) -and (Test-Path $Config)) {
    Write-Log "Lade Konfiguration aus: $Config" -Level "INFO"
    try {
        $cfg = Get-Content $Config -Raw | ConvertFrom-Json
        if ($cfg.url) { $feedUrls += $cfg.url }
        if ($cfg.urls) { $feedUrls += $cfg.urls }
        if ($cfg.output -and $Output -eq (Join-Path $HOME "Podcasts\MeinPodcast")) { $Output = $cfg.output }
        
        # Neue Parameter auswerten
        if ($null -ne $cfg.limit -and $Limit -eq 0) { $Limit = [int]$cfg.limit }
        if ($null -ne $cfg.workers -and $Workers -eq 1) { $Workers = [int]$cfg.workers }
        if ($null -ne $cfg.retries -and $Retries -eq 3) { $Retries = [int]$cfg.retries }
        if ($null -ne $cfg.timeout -and $TimeoutSec -eq 60) { $TimeoutSec = [int]$cfg.timeout }
        if ($null -ne $cfg.m3u -and -not $M3u) { $M3u = [bool]$cfg.m3u }
        if ($null -ne $cfg.dry_run -and -not $DryRun) { $DryRun = [bool]$cfg.dry_run }
    } catch { Write-Log "Fehler beim Lesen der config.json: $_" -Level "ERROR" }
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

# Dubletten entfernen
$feedUrls = $feedUrls | Select-Object -Unique

# 2. Verzeichnis vorbereiten
if (-not $DryRun) {
    if (-not (Test-Path -Path $Output)) {
        New-Item -ItemType Directory -Path $Output | Out-Null
        Write-Log "Verzeichnis erstellt: $Output" -Level "SUCCESS"
    }
    Invoke-CleanupOldParts -Folder $Output
}

# TLS anpassen
if ($PSVersionTable.PSEdition -eq "Desktop") {
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13 }
    catch { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 }
}

$totalDownloaded = 0
$totalSkipped = 0
$totalFailed = 0

# 3. Feeds abarbeiten
foreach ($feedUrl in $feedUrls) {
    if ($global:SharedState.AbortEvent) { break }
    Write-Log "Analysiere Feed: $feedUrl"

    try {
        $feedRequest = Invoke-WebRequest -Uri $feedUrl -UserAgent $global:SharedState.UserAgent -UseBasicParsing -TimeoutSec 30
        [xml]$feed = $feedRequest.Content
    } catch {
        Write-Log "Überspringe Feed wegen Fehler: $_" -Level "ERROR"
        continue
    }

    $items = $feed.SelectNodes("//*[local-name()='item' or local-name()='entry']")
    if (-not $items -or $items.Count -eq 0) { continue }

    if ($Limit -gt 0) { $items = $items | Select-Object -First $Limit }

    # Array für die anstehenden Download-Aufgaben
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
            $filePath = Join-Path -Path $Output -ChildPath $fileName
            $partPath = "$filePath.part"

            if (Test-Path -Path $filePath) {
                Write-Log "Überspringe: $fileName" -Level "INFO" # -ForegroundColor DarkGray
                $totalSkipped++
            } else {
                $tasks += [PSCustomObject]@{ Url = $mediaUrl; Final = $filePath; Part = $partPath; Name = $fileName }
            }
        }
    }

    if ($DryRun) {
        foreach ($t in $tasks) { Write-Log "DRY-RUN: Würde laden: $($t.Name)" -Level "INFO" }
        continue
    }

    if ($tasks.Count -gt 0) {
        Write-Log "Starte Download von $($tasks.Count) Episoden (Workers: $Workers)..."

        # MULTITHREADING-LOGIK: Feature-Detection für PowerShell 7+
        if ($Workers -gt 1 -and $PSVersionTable.PSVersion.Major -ge 7) {
            # Modernes PowerShell Multithreading (Isolierte Runspaces)
            
            # WICHTIGE ÄNDERUNG: Funktionen werden als reiner Text (String) exportiert.
            # So umgehen wir die Sicherheitsbeschränkung, da wir keinen aktiven Code über $using: schleusen.
            $funcRobustStr = ${function:Invoke-RobustDownload}.ToString()
            $funcLogStr = ${function:Write-Log}.ToString()
            $shared = $global:SharedState

            $results = $tasks | ForEach-Object -Parallel {
                # Funktionen im isolierten Thread dynamisch aus dem Text neu kompilieren
                Set-Item -Path "Function:Invoke-RobustDownload" -Value ([scriptblock]::Create($using:funcRobustStr))
                Set-Item -Path "Function:Write-Log" -Value ([scriptblock]::Create($using:funcLogStr))
                
                $task = $_
                $workerId = [System.Threading.Thread]::CurrentThread.ManagedThreadId
                
                # Download-Funktion aufrufen und unseren shared State übergeben
                $success = Invoke-RobustDownload -DownloadUrl $task.Url -FinalPath $task.Final -PartPath $task.Part -MaxRetries $using:Retries -TimeoutSec $using:TimeoutSec -ProgressId $workerId -State $using:shared
                
                if ($success) { Write-Log "✔ Abgeschlossen: $($task.Name)" -Level "SUCCESS" }
                [PSCustomObject]@{ Success = $success }
            } -ThrottleLimit $Workers

            $totalDownloaded += ($results | Where-Object Success -eq $true).Count
            $totalFailed += ($results | Where-Object Success -eq $false).Count
        } 
        else {
            # Fallback für PowerShell 5.1 (Windows Standard, sequenziell)
            if ($Workers -gt 1) { Write-Log "Multithreading erfordert PowerShell 7+. Führe Downloads sequenziell aus." -Level "WARN" }
            
            foreach ($task in $tasks) {
                if ($global:SharedState.AbortEvent) { break }
                $success = Invoke-RobustDownload -DownloadUrl $task.Url -FinalPath $task.Final -PartPath $task.Part -MaxRetries $Retries -TimeoutSec $TimeoutSec -ProgressId 1 -State $global:SharedState
                
                if ($success) { 
                    Write-Log "✔ Abgeschlossen: $($task.Name)" -Level "SUCCESS"
                    $totalDownloaded++ 
                } else { 
                    if (-not $global:SharedState.AbortEvent) { $totalFailed++ }
                }
            }
        }
    }

    if ($M3u -and -not $DryRun -and -not $global:SharedState.AbortEvent) {
        New-M3uPlaylist -Folder $Output -Title "Podcast"
    }
}

if (-not $global:SharedState.AbortEvent) {
    Write-Log "=================================================="
    Write-Log "SYNCHRONISATION ABGESCHLOSSEN"
    Write-Log "✅ Heruntergeladen: $totalDownloaded"
    Write-Log "⏭️ Übersprungen:   $totalSkipped"
    if ($totalFailed -gt 0) { Write-Log "❌ Fehlgeschlagen:  $totalFailed" -Level "WARN" }
    Write-Log "=================================================="
}
