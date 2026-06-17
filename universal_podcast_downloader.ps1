# ==============================================================================
# Universal Podcast Downloader (PowerShell Version - Refactored & Optimized)
# ==============================================================================

# Konfiguration: URL des RSS-Feeds
$rssUrl = "https://beispiel-url.de/podcast/feed.rss"

# Konfiguration: Zielverzeichnis für den Download
# $HOME stellt die Kompatibilität zwischen Windows (C:\Users\...) und Linux (/home/...) sicher.
$downloadFolder = Join-Path -Path $HOME -ChildPath "Podcasts/MeinLieblingsPodcast"

# HTTP-Header-Anpassung zur Vermeidung von 403 Forbidden Fehlern durch CDNs
$userAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"

# Windows-spezifische reservierte Dateinamen
$reservedNames = @(
    "CON", "PRN", "AUX", "NUL",
    "COM1", "COM2", "COM3", "COM4", "COM5", "COM6", "COM7", "COM8", "COM9",
    "LPT1", "LPT2", "LPT3", "LPT4", "LPT5", "LPT6", "LPT7", "LPT8", "LPT9"
)

# 1. Überprüfung und Erstellung des Zielverzeichnisses
if (-not (Test-Path -Path $downloadFolder)) {
    New-Item -ItemType Directory -Path $downloadFolder | Out-Null
    Write-Host "Verzeichnis erstellt: $downloadFolder" -ForegroundColor Green
}

Write-Host "Analysiere RSS-Feed: $rssUrl" -ForegroundColor Cyan

# 2. HTTP-Anfrage durchführen und XML-Struktur parsen
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    # Timeout von 30 Sekunden verhindert endloses Blockieren
    $response = Invoke-WebRequest -Uri $rssUrl -UserAgent $userAgent -UseBasicParsing -TimeoutSec 30
    [xml]$feed = $response.Content
} catch {
    Write-Error "Fehler beim Abruf oder Parsing des RSS-Feeds. Bitte überprüfen Sie die URL."
    Write-Error $_
    exit 1
}

# Extraktion der Episoden
$items = $feed.rss.channel.item

if ($null -eq $items) {
    Write-Error "Es konnten keine Episoden extrahiert werden."
    exit 1
}

Write-Host "$($items.Count) Episoden im Feed detektiert. Starte Synchronisation..." -ForegroundColor Cyan

# 3. Iteration über alle extrahierten Episoden
foreach ($item in $items) {
    # Robuster Umgang mit leeren Tags
    $titleRaw = $item.title | Select-Object -First 1
    $title = if (-not [string]::IsNullOrWhiteSpace($titleRaw)) { [string]$titleRaw.Trim() } else { "Unbekannte_Episode" }
    
    $enclosure = $item.enclosure | Select-Object -First 1

    # Validierung der Dateianlage
    if ($null -ne $enclosure -and $null -ne $enclosure.url) {
        $mp3Url = [string]$enclosure.url

        # Validierung des Dateinamens: Bereinigung ungültiger Zeichen
        $invalidChars = [System.IO.Path]::GetInvalidFileNameChars()
        $safeTitle = $title
        foreach ($char in $invalidChars) {
            $safeTitle = $safeTitle.Replace($char, '-')
        }
        $safeTitle = $safeTitle.Replace(':', ' -').Replace('?', '').Replace('/', '-').Trim()

        # Prüfung auf reservierte Windows-Dateinamen
        if ($reservedNames -contains $safeTitle.ToUpper()) {
            $safeTitle = "Episode_$safeTitle"
        }

        # Bestimmung des Präfix (Episodennummer oder Publikationsdatum)
        $prefix = ""
        $epNum = $null
        
        # Präferenz 1: iTunes-Tag
        if ($null -ne $item.episode) { $epNum = [string]($item.episode | Select-Object -First 1) }
        elseif ($null -ne $item."itunes:episode") { $epNum = [string]($item."itunes:episode" | Select-Object -First 1) }

        if (-not [string]::IsNullOrWhiteSpace($epNum) -and $epNum -match "^\d+$") {
            $prefix = "{0:D3} - " -f [int]$epNum
        } else {
            # Präferenz 2 (Fallback): Publikationsdatum nutzen
            $pubDateRaw = $item.pubDate | Select-Object -First 1
            if (-not [string]::IsNullOrWhiteSpace($pubDateRaw)) {
                try {
                    $dt = [datetime]$pubDateRaw
                    $prefix = $dt.ToString("yyyy-MM-dd") + " - "
                } catch {
                    # Ignorieren, falls das Datum nicht geparst werden kann
                }
            }
        }
        
        # Extraktion der Dateiendung ohne URL-Parameter (z. B. ?v=1)
        $urlWithoutQuery = $mp3Url.Split('?')[0]
        $extension = [System.IO.Path]::GetExtension($urlWithoutQuery)
        
        if ([string]::IsNullOrWhiteSpace($extension)) { $extension = ".mp3" }
        
        # Konstruktion der finalen Dateipfade
        $fileName = "$prefix$safeTitle$extension"
        $filePath = Join-Path -Path $downloadFolder -ChildPath $fileName
        
        # Temporäre Datei für den Download (.part)
        $partPath = $filePath + ".part"

        # 4. Inkrementeller Download
        if (Test-Path -Path $filePath) {
            Write-Host "Überspringe (Datei bereits vorhanden): $fileName" -ForegroundColor DarkGray
        } else {
            Write-Host "Download gestartet: $fileName" -ForegroundColor Yellow
            try {
                # -OutFile schreibt direkt auf die Festplatte (Streaming), RAM wird nicht überlastet
                Invoke-WebRequest -Uri $mp3Url -OutFile $partPath -UserAgent $userAgent -UseBasicParsing -TimeoutSec 30
                
                # Nach erfolgreichem Download: Umbenennen zur finalen Datei
                Rename-Item -Path $partPath -NewName $fileName -Force
                Write-Host "Download erfolgreich: $fileName" -ForegroundColor Green
            } catch {
                Write-Error "Fehler beim Download von $fileName"
                Write-Error $_
                
                # Temporäre Datei bei Fehler aufräumen
                if (Test-Path -Path $partPath) {
                    Remove-Item -Path $partPath -Force
                }
            }
        }
    }
}

Write-Host "Synchronisation erfolgreich abgeschlossen." -ForegroundColor Green
