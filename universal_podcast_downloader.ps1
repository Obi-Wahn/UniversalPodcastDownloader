# ==============================================================================
# Universal Podcast Downloader
# ==============================================================================

# Konfiguration: URL des RSS-Feeds
$rssUrl = "https://beispiel-url.de/podcast/feed.rss"

# Konfiguration: Zielverzeichnis für den Download
# $HOME stellt die Kompatibilität zwischen Windows (C:\Users\...) und Linux (/home/...) sicher.
$downloadFolder = Join-Path -Path $HOME -ChildPath "Podcasts/MeinLieblingsPodcast"

# HTTP-Header-Anpassung (User-Agent) zur Vermeidung von 403 Forbidden Fehlern durch CDNs
$userAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"

# 1. Überprüfung und Erstellung des Zielverzeichnisses
if (-not (Test-Path -Path $downloadFolder)) {
    New-Item -ItemType Directory -Path $downloadFolder | Out-Null
    Write-Host "Verzeichnis erstellt: $downloadFolder" -ForegroundColor Green
}

Write-Host "Analysiere RSS-Feed: $rssUrl" -ForegroundColor Cyan

# 2. HTTP-Anfrage durchführen und XML-Struktur parsen
try {
    # TLS 1.2 als primäres Sicherheitsprotokoll festlegen
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    
    # Download des Feeds mit spezifischem User-Agent
    $response = Invoke-WebRequest -Uri $rssUrl -UserAgent $userAgent -UseBasicParsing
    
    # Typkonvertierung zu XML
    [xml]$feed = $response.Content
} catch {
    Write-Error "Fehler beim Abruf oder Parsing des RSS-Feeds. Bitte überprüfen Sie die URL."
    Write-Error $_
    exit
}

# Extraktion der Episoden (Standard RSS 2.0 Spezifikation)
$items = $feed.rss.channel.item

if ($null -eq $items) {
    Write-Error "Es konnten keine Episoden extrahiert werden. Mögliche Abweichung der XML-Struktur."
    exit
}

Write-Host "$($items.Count) Episoden im Feed detektiert. Starte Synchronisation..." -ForegroundColor Cyan

# Initialisierung der Variablen für die Fallback-Nummerierung
$totalItems = $items.Count
$currentIndex = 0

# 3. Iteration über alle extrahierten Episoden
foreach ($item in $items) {
    # Explizite Typkonvertierung und Elementauswahl zur Vermeidung von Array-Bildung bei redundanten Tags
    $title = [string]($item.title | Select-Object -First 1)
    
    # Extraktion der Dateianlage (Enclosure)
    $enclosure = $item.enclosure | Select-Object -First 1

    # Validierung, ob ein valider Dateianhang mit URL existiert
    if ($null -ne $enclosure -and $null -ne $enclosure.url) {
        $mp3Url = [string]$enclosure.url

        # Validierung des Dateinamens: Entfernung betriebssystemspezifischer, ungültiger Zeichen
        $invalidChars = [System.IO.Path]::GetInvalidFileNameChars()
        $safeTitle = $title
        foreach ($char in $invalidChars) {
            $safeTitle = $safeTitle.Replace($char, '-')
        }
        
        # Formatierung: Ersetzung von Doppelpunkten und Entfernung von Fragezeichen/Slashes
        $safeTitle = $safeTitle.Replace(':', ' -').Replace('?', '').Replace('/', '-').Trim()

        # Bestimmung der Episodennummer
        $epNum = $null
        
        # Präferenz 1: Extraktion der Episodennummer aus iTunes-spezifischen Tags
        if ($null -ne $item.episode) { $epNum = [string]($item.episode | Select-Object -First 1) }
        elseif ($null -ne $item."itunes:episode") { $epNum = [string]($item."itunes:episode" | Select-Object -First 1) }

        # Präferenz 2 (Fallback): Berechnung der Episodennummer basierend auf der Gesamtanzahl
        if ([string]::IsNullOrWhiteSpace($epNum)) { $epNum = [string]($totalItems - $currentIndex) }

        # Formatierung der Episodennummer auf drei signifikante Stellen (z. B. 001)
        $epInt = $epNum -as [int]
        $epFormatted = if ($null -ne $epInt) { "{0:D3}" -f $epInt } else { $epNum }
        
        # Extraktion der Dateiendung und Bereinigung von URL-Parametern
        $urlWithoutQuery = $mp3Url.Split('?')[0]
        $extension = [System.IO.Path]::GetExtension($urlWithoutQuery)
        
        if ([string]::IsNullOrWhiteSpace($extension)) { $extension = ".mp3" }
        
        # Konstruktion des finalen Dateipfads
        $fileName = "$epFormatted - $safeTitle$extension"
        $filePath = Join-Path -Path $downloadFolder -ChildPath $fileName

        # 4. Inkrementeller Download der Audiodatei
        if (Test-Path -Path $filePath) {
            Write-Host "Überspringe (Datei bereits vorhanden): $fileName" -ForegroundColor DarkGray
        } else {
            Write-Host "Download gestartet: $fileName" -ForegroundColor Yellow
            try {
                Invoke-WebRequest -Uri $mp3Url -OutFile $filePath -UserAgent $userAgent -UseBasicParsing
                Write-Host "Download erfolgreich: $fileName" -ForegroundColor Green
            } catch {
                Write-Error "Fehler beim Download der Datei: $fileName"
                Write-Error $_
            }
        }
    }
    $currentIndex++
}

Write-Host "Synchronisation erfolgreich abgeschlossen." -ForegroundColor Green