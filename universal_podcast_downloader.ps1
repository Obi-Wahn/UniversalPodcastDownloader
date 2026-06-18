# ==============================================================================
# Universal Podcast Downloader (PowerShell Version - Ultimate Edition)
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

Write-Host "Analysiere Feed: $rssUrl" -ForegroundColor Cyan

# 2. HTTP-Anfrage durchführen und XML-Struktur parsen
try {
    # TLS-Sicherheitsprotokolle anpassen (nur nötig auf älteren Windows PowerShell 5.1 Systemen)
    if ($PSVersionTable.PSEdition -eq "Desktop") {
        # TLS 1.2 und 1.3 (falls vom OS unterstützt) explizit aktivieren
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor 3072
    }
    
    # Timeout von 30 Sekunden verhindert endloses Blockieren (für den Feed-Abruf reicht das)
    $response = Invoke-WebRequest -Uri $rssUrl -UserAgent $userAgent -UseBasicParsing -TimeoutSec 30
    [xml]$feed = $response.Content
} catch {
    # throw statt exit für bessere Fehlerbehandlung, falls das Skript importiert wird
    throw "Fehler beim Abruf oder Parsing des Feeds. Bitte überprüfen Sie die URL. Details: $_"
}

# 3. Extraktion der Episoden (Unterstützt RSS <item> und Atom <entry> per XPath)
$items = $feed.SelectNodes("//*[local-name()='item' or local-name()='entry']")

if (-not $items -or $items.Count -eq 0) {
    throw "Es konnten keine Episoden extrahiert werden. Möglicherweise ist die XML-Struktur ungültig."
}

Write-Host "$($items.Count) Episoden detektiert. Starte Synchronisation..." -ForegroundColor Cyan

# 4. Iteration über alle extrahierten Episoden
foreach ($item in $items) {
    # Robuste Titel-Extraktion (ignoriert Namespaces)
    $titleNode = $item.SelectSingleNode("*[local-name()='title']")
    $title = if ($titleNode -and -not [string]::IsNullOrWhiteSpace($titleNode.InnerText)) { $titleNode.InnerText.Trim() } else { "Unbekannte_Episode" }
    
    # Extraktion der URL (Unterstützt RSS <enclosure> und Atom <link rel="enclosure">)
    $mp3Url = $null
    $enclosure = $item.SelectSingleNode("*[local-name()='enclosure']")
    
    if ($enclosure -and $enclosure.HasAttribute("url")) {
        $mp3Url = $enclosure.GetAttribute("url")
    } else {
        $linkNode = $item.SelectSingleNode("*[local-name()='link' and @rel='enclosure']")
        if ($linkNode -and $linkNode.HasAttribute("href")) {
            $mp3Url = $linkNode.GetAttribute("href")
        }
    }

    # Validierung der Dateianlage
    if (-not [string]::IsNullOrWhiteSpace($mp3Url)) {

        # Kosmetische Bereinigung
        $safeTitle = $title.Replace(':', ' -').Replace('?', '').Replace('/', '-').Trim()
        
        # Windows-System Bereinigung ungültiger Zeichen
        $invalidChars = [System.IO.Path]::GetInvalidFileNameChars()
        foreach ($char in $invalidChars) {
            $safeTitle = $safeTitle.Replace($char, '-')
        }

        # Dateinamen-Längenlimit (Windows MAX_PATH ist oft 260 Zeichen, wir limitieren sicherheitshalber auf 150)
        if ($safeTitle.Length -gt 150) {
            $safeTitle = $safeTitle.Substring(0, 150).Trim()
        }

        # Prüfung auf reservierte Windows-Dateinamen
        if ($reservedNames -contains $safeTitle.ToUpper()) {
            $safeTitle = "Episode_$safeTitle"
        }

        # Bestimmung des Präfix (Episodennummer oder Publikationsdatum)
        $prefix = ""
        
        # Präferenz 1: Episodennummer (Namespace-unabhängig via XPath)
        $epNode = $item.SelectSingleNode("*[local-name()='episode']")
        if ($epNode -and $epNode.InnerText -match "^\d+$") {
            $prefix = "{0:D3} - " -f [int]($epNode.InnerText.Trim())
        } else {
            # Präferenz 2 (Fallback): Publikationsdatum nutzen (Unterstützt RSS pubDate und Atom published/updated)
            $pubDateNode = $item.SelectSingleNode("*[local-name()='pubDate' or local-name()='published' or local-name()='updated']")
            if ($pubDateNode -and -not [string]::IsNullOrWhiteSpace($pubDateNode.InnerText)) {
                try {
                    $dt = [datetime]($pubDateNode.InnerText)
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

        # 5. Inkrementeller Download mit Retry-Logik und 60 Sekunden Timeout
        if (Test-Path -Path $filePath) {
            Write-Host "Überspringe (Datei bereits vorhanden): $fileName" -ForegroundColor DarkGray
        } else {
            $maxRetries = 3
            
            for ($attempt = 1; $attempt -le $maxRetries; $attempt++) {
                Write-Host "Download gestartet ($attempt/$maxRetries): $fileName" -ForegroundColor Yellow
                try {
                    # -OutFile schreibt direkt auf die Festplatte (Streaming), RAM wird nicht überlastet. Timeout auf 60 erhöht.
                    Invoke-WebRequest -Uri $mp3Url -OutFile $partPath -UserAgent $userAgent -UseBasicParsing -TimeoutSec 60
                    
                    # Move-Item statt Rename-Item (robuster bei absoluten Pfaden)
                    Move-Item -Path $partPath -Destination $filePath -Force
                    Write-Host "Download erfolgreich: $fileName" -ForegroundColor Green
                    
                    # Schleife abbrechen, da Download erfolgreich war
                    break 
                } catch {
                    if ($attempt -lt $maxRetries) {
                        Write-Host "Timeout oder Fehler bei Versuch $attempt, probiere es noch einmal..." -ForegroundColor DarkYellow
                    } else {
                        Write-Error "Fehler nach $maxRetries Versuchen beim Download von $fileName"
                        Write-Error $_
                        
                        # Temporäre Datei erst nach dem letzten fehlgeschlagenen Versuch aufräumen
                        if (Test-Path -Path $partPath) {
                            Remove-Item -Path $partPath -Force
                        }
                    }
                }
            }
        }
    }
}

Write-Host "Synchronisation erfolgreich abgeschlossen." -ForegroundColor Green
