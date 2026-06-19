#Requires -Version 5.1
<#
.SYNOPSIS
    Universal Podcast Downloader (PowerShell Version)
.DESCRIPTION
    Ein robuster Podcast-Downloader für RSS & Atom Feeds mit Resume-Funktion,
    Fortschrittsanzeige und Fehler-Toleranz. Ohne externe Abhängigkeiten.
#>

# ==============================================================================
# BENUTZER-EINSTELLUNGEN / CLI-PARAMETER
# ==============================================================================
param (
    # Tragen Sie hier die URL des gewünschten RSS-Feeds ein:
    [string]$Url = "https://beispiel-url.de/podcast/feed.rss",

    # Tragen Sie hier den Standard-Speicherort für die MP3-Dateien ein ($HOME ist Ihr Benutzerverzeichnis):
    [string]$Output = (Join-Path -Path $HOME -ChildPath "Podcasts\MeinPodcast"),

    # Maximale Anzahl der neuesten Episoden (0 = alle laden):
    [int]$Limit = 0,

    # Maximale Anzahl der Download-Versuche bei Netzwerkfehlern:
    [int]$Retries = 3,

    # Timeout für Netzwerkverbindungen in Sekunden:
    [int]$TimeoutSec = 60,

    # Simuliert den Vorgang, ohne Dateien tatsächlich herunterzuladen:
    [switch]$DryRun
)

# Generischer User-Agent gegen CDN-Blockaden und für Datenschutz
$UserAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"

# Reservierte Windows-Namen auf Skript-Ebene abfangen (verhindert Beeinflussung anderer Skripte)
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

function Invoke-RobustDownload {
    param(
        [string]$DownloadUrl,
        [string]$FinalPath,
        [string]$PartPath,
        [int]$MaxRetries,
        [int]$TimeoutSec
    )

    for ($attempt = 1; $attempt -le $MaxRetries; $attempt++) {
        $progressStarted = $false
        try {
            # Direkter Zugriff auf .NET HttpWebRequest für Chunking und Range-Headers
            $request = [System.Net.HttpWebRequest][System.Net.WebRequest]::Create($DownloadUrl)
            $request.UserAgent = $UserAgent
            $request.Timeout = $TimeoutSec * 1000 # Umrechnung in Millisekunden

            $initialSize = 0
            $appendMode = $false

            # Resume-Logik prüfen
            if (Test-Path -Path $PartPath) {
                $initialSize = (Get-Item -Path $PartPath).Length
                if ($initialSize -gt 0) {
                    $request.AddRange($initialSize)
                    $appendMode = $true
                }
            }

            $response = $request.GetResponse()
            
            # ContentLength-Bug Fix: -1 abfangen
            $totalSize = if ($response.ContentLength -ge 0) { $response.ContentLength + $initialSize } else { 0 }
            
            # Prüfen, ob der Server Resume (206 Partial Content) unterstützt
            $isPartial = ($response.StatusCode -eq [System.Net.HttpStatusCode]::PartialContent)
            
            if ($initialSize -gt 0 -and -not $isPartial) {
                Write-Log "Server unterstützt kein Resume. Starte Download neu." -Level "INFO"
                $initialSize = 0
                $appendMode = $false
            } elseif ($initialSize -gt 0 -and $isPartial) {
                $mb = [math]::Round($initialSize / 1MB, 1)
                Write-Log "Setze abgebrochenen Download fort (ab $mb MB)." -Level "INFO"
            }

            # FileStream vorbereiten
            $fileMode = if ($appendMode -and $isPartial) { [System.IO.FileMode]::Append } else { [System.IO.FileMode]::Create }
            $fileStream = New-Object System.IO.FileStream($PartPath, $fileMode, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
            $responseStream = $response.GetResponseStream()

            $buffer = New-Object byte[] (1024 * 1024) # 1 MB Puffer
            $downloaded = $initialSize
            $progressStarted = $true

            try {
                while (($read = $responseStream.Read($buffer, 0, $buffer.Length)) -gt 0) {
                    $fileStream.Write($buffer, 0, $read)
                    $downloaded += $read

                    # PowerShell Fortschrittsbalken (inklusive Handhabung unbekannter Größen)
                    if ($totalSize -gt 0) {
                        $pct = ($downloaded / $totalSize) * 100
                        $statusText = "{0:N1} MB / {1:N1} MB" -f ($downloaded / 1MB), ($totalSize / 1MB)
                        Write-Progress -Activity "Lade herunter: $(Split-Path $FinalPath -Leaf)" -Status $statusText -PercentComplete $pct
                    } else {
                        $statusText = "{0:N1} MB geladen (Gesamtgröße unbekannt)" -f ($downloaded / 1MB)
                        Write-Progress -Activity "Lade herunter: $(Split-Path $FinalPath -Leaf)" -Status $statusText
                    }
                }
            } finally {
                if ($fileStream) { $fileStream.Close() }
                if ($responseStream) { $responseStream.Close() }
                if ($response) { $response.Close() }
                if ($progressStarted) { Write-Progress -Activity "Lade herunter: $(Split-Path $FinalPath -Leaf)" -Completed }
            }

            # Größenprüfung am Ende (nur wenn Gesamtgröße vom Server mitgeteilt wurde)
            if ($totalSize -gt 0 -and $downloaded -lt $totalSize) {
                throw "Download unvollständig (Verbindung abgerissen)."
            }

            Move-Item -Path $PartPath -Destination $FinalPath -Force
            Write-Log "Download erfolgreich abgeschlossen." -Level "SUCCESS"
            return # Erfolg! Schleife verlassen.

        } catch {
            if ($progressStarted) { Write-Progress -Activity "Lade herunter: $(Split-Path $FinalPath -Leaf)" -Completed }
            $errMsg = $_.Exception.Message
            
            if ($attempt -lt $MaxRetries) {
                $sleepTime = [math]::Pow(2, $attempt) # Exponentielles Backoff: 2, 4, 8...
                Write-Log "Fehler bei Versuch $attempt/$MaxRetries: $errMsg. Warte ${sleepTime}s..." -Level "WARN"
                Start-Sleep -Seconds $sleepTime
            } else {
                Write-Log "Endgültig fehlgeschlagen nach $MaxRetries Versuchen: $errMsg" -Level "ERROR"
            }
        }
    }
}

# ------------------------------------------------------------------------------
# HAUPTSKRIPT (MAIN)
# ------------------------------------------------------------------------------

# 1. Zielverzeichnis sichern
if (-not $DryRun -and -not (Test-Path -Path $Output)) {
    New-Item -ItemType Directory -Path $Output | Out-Null
    Write-Log "Verzeichnis erstellt: $Output" -Level "SUCCESS"
}

Write-Log "Analysiere Feed: $Url"

# TLS anpassen für ältere PowerShell-Versionen (Vermeidung magischer Nummern)
if ($PSVersionTable.PSEdition -eq "Desktop") {
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13
    } catch {
        # Fallback, falls .NET-Version kein Tls13 Enum kennt
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    }
}

try {
    $feedRequest = Invoke-WebRequest -Uri $Url -UserAgent $UserAgent -UseBasicParsing -TimeoutSec 30
    [xml]$feed = $feedRequest.Content
} catch {
    Write-Log "Fehler beim Abruf oder Parsing des Feeds. Details: $_" -Level "ERROR"
    exit 1
}

# 2. Episoden namespace-unabhängig auslesen (RSS + Atom)
$items = $feed.SelectNodes("//*[local-name()='item' or local-name()='entry']")

if (-not $items -or $items.Count -eq 0) {
    Write-Log "Keine Episoden im XML gefunden." -Level "ERROR"
    exit 1
}

# Limit anwenden
if ($Limit -gt 0) {
    $items = $items | Select-Object -First $Limit
    Write-Log "Limit aktiv: Verarbeite nur die neuesten $Limit Episoden."
} else {
    Write-Log "$($items.Count) Episoden detektiert."
}

# 3. Schleife durch Episoden
foreach ($item in $items) {
    $titleNode = $item.SelectSingleNode("*[local-name()='title']")
    $title = if ($titleNode) { $titleNode.InnerText.Trim() } else { "Unbekannte_Episode" }
    
    $mediaUrl = $null
    $enclosure = $item.SelectSingleNode("*[local-name()='enclosure']")
    if ($enclosure -and $enclosure.HasAttribute("url")) {
        $mediaUrl = $enclosure.GetAttribute("url")
    } else {
        $linkNode = $item.SelectSingleNode("*[local-name()='link' and @rel='enclosure']")
        if ($linkNode -and $linkNode.HasAttribute("href")) { $mediaUrl = $linkNode.GetAttribute("href") }
    }

    if (-not [string]::IsNullOrWhiteSpace($mediaUrl)) {
        
        $safeTitle = Get-SafeFileName -Title $title
        
        # Präfix ermitteln (Nummer oder Datum)
        $prefix = ""
        $epNode = $item.SelectSingleNode("*[local-name()='episode']")
        if ($epNode -and $epNode.InnerText -match "^\d+$") {
            $prefix = "{0:D3} - " -f [int]($epNode.InnerText.Trim())
        } else {
            $pubDateNode = $item.SelectSingleNode("*[local-name()='pubDate' or local-name()='published' or local-name()='updated']")
            if ($pubDateNode) { 
                try { 
                    $prefix = ([datetime]$pubDateNode.InnerText).ToString("yyyy-MM-dd") + " - " 
                } catch {
                    Write-Log "Datumsformat unbekannt für '$title'" -Level "WARN"
                } 
            }
        }
        
        # Dynamische Dateiendung
        $urlWithoutQuery = $mediaUrl.Split('?')[0]
        $extension = [System.IO.Path]::GetExtension($urlWithoutQuery)
        if ([string]::IsNullOrWhiteSpace($extension)) { $extension = ".mp3" }

        $fileName = "$prefix$safeTitle$extension"
        $filePath = Join-Path -Path $Output -ChildPath $fileName
        $partPath = "$filePath.part"

        if (Test-Path -Path $filePath) {
            Write-Log "Überspringe (bereits vorhanden): $fileName"
        } else {
            if ($DryRun) {
                Write-Log "DRY-RUN: Würde Datei herunterladen: $fileName" -Level "INFO"
            } else {
                Write-Log "Starte Download: $fileName"
                Invoke-RobustDownload -DownloadUrl $mediaUrl -FinalPath $filePath -PartPath $partPath -MaxRetries $Retries -TimeoutSec $TimeoutSec
            }
        }
    }
}

Write-Log "Synchronisation erfolgreich abgeschlossen." -Level "SUCCESS"
