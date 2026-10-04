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
    [string]$Output = "",   # Standard: "Podcasts" im Skriptordner (wird unten gesetzt)
    [int]$Limit = 0,
    [int]$Retries = 3,
    [int]$TimeoutSec = 60,
    [int]$Workers = 1,
    [switch]$DryRun,
    [switch]$M3u,
    [switch]$Flat
)

# Punkt 10: Ungültige Workers-Werte abfangen
if ($Workers -lt 1) { $Workers = 1 }

$global:SharedState = [hashtable]::Synchronized(@{
    ChunkSize = 1MB
    MaxFileSize = 1GB
    UserAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"
})

# Strg+C: PowerShell stoppt das Skript selbst und führt dabei die finally-Blöcke aus
# (Streams werden geschlossen, .part-Dateien bleiben für das Resume erhalten).
# Ein eigener [Console]::CancelKeyPress-Handler ist hier ungeeignet: Er läuft auf einem
# Thread ohne Runspace und bringt PowerShell zum Absturz.

$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
# Standard-Zielordner erst hier setzen, damit er auf demselben $scriptDir basiert wie die Config-Suche
if (-not $PSBoundParameters.ContainsKey('Output')) { $Output = Join-Path -Path $scriptDir -ChildPath "Podcasts" }

$script:ReservedNames = @("CON", "PRN", "AUX", "NUL", "COM1", "COM2", "COM3", "COM4", "COM5", "COM6", "COM7", "COM8", "COM9", "LPT1", "LPT2", "LPT3", "LPT4", "LPT5", "LPT6", "LPT7", "LPT8", "LPT9")

# Dateiendung aus dem "type"-Attribut des Feeds, falls die URL keine bekannte Endung hat
$script:MediaTypes = @{
    "audio/mpeg" = ".mp3"; "audio/mp3" = ".mp3"; "audio/x-mpeg" = ".mp3"
    "audio/mp4" = ".m4a"; "audio/x-m4a" = ".m4a"; "audio/m4a" = ".m4a"
    "audio/aac" = ".aac"; "audio/x-aac" = ".aac"; "audio/ogg" = ".ogg"; "audio/opus" = ".opus"
    "audio/flac" = ".flac"; "audio/x-flac" = ".flac"; "audio/wav" = ".wav"; "audio/x-wav" = ".wav"
    "video/mp4" = ".mp4"; "video/x-m4v" = ".m4v"
}
$script:MediaExtensions = @($script:MediaTypes.Values) + @(".m4b", ".oga") | Select-Object -Unique

# Eigene .part-Dateien, die älter sind, werden nicht fortgesetzt, sondern neu begonnen
$script:PartMaxAgeDays = 7

# Hinweis: Dateipfade immer mit -LiteralPath ansprechen. Mit -Path deutet PowerShell
# eckige Klammern als Platzhalter, und "Bonus [Teil 1].mp3" würde nie gefunden.

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
    # Ein Titel nur aus Punkten/Leerzeichen bekäme sonst einen leeren Namen
    if ([string]::IsNullOrWhiteSpace($safeTitle)) { $safeTitle = "Unbenannt" }
    if ($script:ReservedNames -contains $safeTitle.ToUpper()) { $safeTitle = "Episode_$safeTitle" }
    return $safeTitle
}

$script:MonthNumbers = @{ jan = 1; feb = 2; mar = 3; apr = 4; may = 5; jun = 6; jul = 7; aug = 8; sep = 9; oct = 10; nov = 11; dec = 12 }

function Get-DatePrefix {
    # Datum für den Dateinamen so, wie es im Feed steht (ohne Zeitzonen-Umrechnung).
    # Bewusst per Muster statt per [datetime]: So bilden Python und PowerShell für dieselbe
    # Folge denselben Namen - für RFC 822 ("Tue, 01 Sep 2026 ...") und ISO 8601 ("2026-09-01T...").
    param([string]$Text)
    $Text = "$Text".Trim()
    if ($Text -match '^(\d{4})-(\d{2})-(\d{2})') {
        $year = [int]$Matches[1]; $month = [int]$Matches[2]; $day = [int]$Matches[3]
    } elseif ($Text -match '(\d{1,2})\s+([A-Za-z]{3})\s+(\d{4})') {
        $year = [int]$Matches[3]; $month = [int]$script:MonthNumbers[$Matches[2]]; $day = [int]$Matches[1]
    } else {
        return ""
    }
    try { return [datetime]::new($year, $month, $day).ToString("yyyy-MM-dd", [System.Globalization.CultureInfo]::InvariantCulture) + " - " }
    catch { return "" }
}

function Get-MediaExtension {
    # Dateiendung aus der URL, sonst aus dem "type"-Attribut des Feeds, sonst .mp3
    param([string]$Url, [string]$MediaType)
    $suffix = ""
    try { $suffix = [System.IO.Path]::GetExtension(([System.Uri]$Url).AbsolutePath) } catch {}
    if ($script:MediaExtensions -contains $suffix.ToLower()) { return $suffix }
    $fromType = $script:MediaTypes[($MediaType -split ';')[0].Trim().ToLower()]
    if ($fromType) { return $fromType }
    # Unbekannte, aber plausible Endung beibehalten (z.B. .wma); Unsinn wie ".mp3:x" verwerfen
    if ($suffix -match '^\.[A-Za-z0-9]{1,5}$') { return $suffix }
    return ".mp3"
}

function Get-UniqueFileName {
    # Liefert einen Dateinamen, der keiner anderen Folge gehört, und reserviert ihn für $Key.
    # $Claimed bildet Dateinamen auf den Dedup-Schlüssel ihrer Folge ab; PowerShell-Hashtables
    # ignorieren Groß-/Kleinschreibung, genau wie Windows bei Dateinamen.
    param([string]$Base, [string]$Extension, [string]$Key, [hashtable]$Claimed)
    $name = "$Base$Extension"
    $n = 2
    while ($Claimed.ContainsKey($name) -and $Claimed[$name] -ne $Key) {
        $name = "$Base ($n)$Extension"
        $n++
    }
    $Claimed[$name] = $Key
    return $name
}

function Get-DownloadManifest {
    # GUID-Manifest eines Feed-Ordners laden: merkt sich bereits geladene Episoden,
    # damit ein geänderter Titel keinen erneuten Download derselben Episode auslöst.
    param([string]$Folder)
    $manifestPath = Join-Path -Path $Folder -ChildPath ".downloaded.json"
    if (-not (Test-Path -LiteralPath $manifestPath)) { return @{} }
    try {
        $raw = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $manifest = @{}
        # Beschädigte/von Hand editierte Manifeste: nur gültige Einträge (Schlüssel -> Dateiname) übernehmen
        if ($raw -is [System.Management.Automation.PSCustomObject]) {
            foreach ($prop in $raw.PSObject.Properties) {
                if ($prop.Value -is [string] -and $prop.Value) { $manifest[$prop.Name] = $prop.Value }
            }
        }
        return $manifest
    } catch { return @{} }
}

function Save-DownloadManifest {
    param([string]$Folder, [hashtable]$Manifest)
    $manifestPath = Join-Path -Path $Folder -ChildPath ".downloaded.json"
    try {
        $Manifest | ConvertTo-Json | Out-File -LiteralPath $manifestPath -Encoding UTF8
    } catch {
        Write-Log "Konnte Manifest nicht speichern: $_" -Level "ERROR"
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
        $progressStarted = $false

        try {
            $request = [System.Net.HttpWebRequest][System.Net.WebRequest]::Create($DownloadUrl)
            $request.UserAgent = $State.UserAgent
            $request.Timeout = $TimeoutSec * 1000

            $initialSize = 0
            $appendMode = $false

            if (Test-Path -LiteralPath $PartPath) {
                $initialSize = (Get-Item -LiteralPath $PartPath).Length
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
                if (Test-Path -LiteralPath $PartPath) { Remove-Item -LiteralPath $PartPath -Force }
                return $false
            }

            if ($totalSize -gt 0 -and $downloaded -lt $totalSize) {
                throw "Download unvollständig (Verbindung abgerissen)."
            }

            Move-Item -LiteralPath $PartPath -Destination $FinalPath -Force
            return $true

        } catch {
            if ($progressStarted) { Write-Progress -Id $ProgressId -Activity "Lade: $(Split-Path $FinalPath -Leaf)" -Completed }

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
                # 416: Die .part-Datei passt nicht mehr zur Datei auf dem Server (bereits vollständig
                # oder serverseitig geändert) -> verwerfen, der nächste Versuch beginnt neu
                if ([int]$webResponse.StatusCode -eq 416 -and (Test-Path -LiteralPath $PartPath)) {
                    Remove-Item -LiteralPath $PartPath -Force
                }
                $webResponse.Close()
            }

            if ($attempt -lt $MaxRetries) {
                # Server-seitige Wartezeit (Retry-After) hat Vorrang vor dem gedeckelten Backoff (max 60s)
                $sleepTime = if ($null -ne $retryAfter) { [math]::Min($retryAfter, 300) } else { [math]::Min([math]::Pow(2, $attempt), 60) }
                Write-Log "Fehler bei Versuch $attempt/${MaxRetries}: $errMsg. Warte ${sleepTime}s..." -Level "WARN"
                Start-Sleep -Milliseconds ([int]($sleepTime * 1000))
            } else {
                # .part-Datei behalten: Der nächste Lauf setzt den Download dort fort
                # (eigene .part-Dateien älter als 7 Tage werden dort neu begonnen)
                Write-Log "Fehlgeschlagen nach $MaxRetries Versuchen: $(Split-Path $FinalPath -Leaf)" -Level "ERROR"
            }
        }
    }
    return $false
}

function New-M3uPlaylist {
    param([string]$Folder, [string]$Title)
    $mediaFiles = @(Get-ChildItem -LiteralPath $Folder -File | Where-Object { $script:MediaExtensions -contains $_.Extension.ToLower() } | Sort-Object Name)
    if ($mediaFiles.Count -eq 0) { return }

    try {
        $playlistPath = Join-Path -Path $Folder -ChildPath "$Title`_Playlist.m3u"
        $content = @("#EXTM3U") + @($mediaFiles.Name)
        $content | Out-File -LiteralPath $playlistPath -Encoding UTF8
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
    if (Test-Path -LiteralPath $Config) {
        $configToLoad = $Config
    } else {
        Write-Log "Angegebene Konfigurationsdatei '$Config' nicht gefunden! Verwende Standardwerte." -Level "WARN"
    }
} else {
    # Automatische Erkennung: zuerst im aktuellen Verzeichnis, dann im Skriptordner
    # (z.B. Aufgabenplanung, die standardmäßig in C:\Windows\System32 startet)
    foreach ($candidate in @((Join-Path -Path (Get-Location).Path -ChildPath "config.json"), (Join-Path -Path $scriptDir -ChildPath "config.json"))) {
        if (Test-Path -LiteralPath $candidate) { $configToLoad = $candidate; break }
    }
}

if (-not [string]::IsNullOrWhiteSpace($configToLoad)) {
    Write-Log "Lade Konfiguration aus: $configToLoad" -Level "INFO"
    try {
        # -Encoding UTF8: Windows PowerShell 5.1 liest sonst als ANSI (Umlaute in Pfaden!)
        $cfg = Get-Content -LiteralPath $configToLoad -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($cfg.url) { $feedUrls += $cfg.url }
        if ($cfg.urls) { $feedUrls += $cfg.urls }
        if ($cfg.output -and -not $PSBoundParameters.ContainsKey('Output')) {
            # Relative Pfade beziehen sich auf den Ordner der config.json, nicht auf das Arbeitsverzeichnis
            $configDir = Split-Path -Parent (Resolve-Path -LiteralPath $configToLoad).Path
            $Output = if ([System.IO.Path]::IsPathRooted($cfg.output)) { $cfg.output } else { [System.IO.Path]::GetFullPath((Join-Path -Path $configDir -ChildPath $cfg.output)) }
        }

        if ($null -ne $cfg.limit -and $Limit -eq 0) { $Limit = [int]$cfg.limit }
        if ($null -ne $cfg.workers -and $Workers -eq 1) { $Workers = [int]$cfg.workers }
        if ($null -ne $cfg.retries -and $Retries -eq 3) { $Retries = [int]$cfg.retries }
        if ($null -ne $cfg.timeout -and $TimeoutSec -eq 60) { $TimeoutSec = [int]$cfg.timeout }
        if ($null -ne $cfg.m3u -and -not $M3u) { $M3u = [bool]$cfg.m3u }
        if ($null -ne $cfg.dry_run -and -not $DryRun) { $DryRun = [bool]$cfg.dry_run }
        if ($null -ne $cfg.flat -and -not $Flat) { $Flat = [bool]$cfg.flat }

        if ($Workers -lt 1) { $Workers = 1 }
    } catch {
        # Mit einer kaputten Config weiterzumachen ist sinnlos (Platzhalter-URL, falscher Zielordner)
        Write-Log "Fehler beim Lesen der ${configToLoad}: $_" -Level "ERROR"
        exit 1
    }
}

if (-not [string]::IsNullOrWhiteSpace($Opml) -and (Test-Path -LiteralPath $Opml)) {
    try {
        [xml]$opmlXml = Get-Content -LiteralPath $Opml -Raw -Encoding UTF8
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

if (-not $DryRun -and -not (Test-Path -LiteralPath $Output)) {
    [System.IO.Directory]::CreateDirectory($Output) | Out-Null
    Write-Log "Basis-Verzeichnis erstellt: $Output" -Level "SUCCESS"
}

if ($PSVersionTable.PSEdition -eq "Desktop") {
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13 }
    catch { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 }
}

$totalDownloaded = 0
$totalSkipped = 0
$totalFailed = 0
$failedFeeds = 0

foreach ($feedUrl in $feedUrls) {
    Write-Log "Analysiere Feed: $feedUrl"

    try {
        # Punkt 3: TimeoutSec wird nun korrekt durchgereicht
        $feedRequest = Invoke-WebRequest -Uri $feedUrl -UserAgent $global:SharedState.UserAgent -UseBasicParsing -TimeoutSec $TimeoutSec
        # XML direkt aus den Bytes lesen: .Content liefert bei falschem oder fehlendem Content-Type
        # (z.B. application/octet-stream) Bytes statt Text, und die Kodierung kommt so aus dem Feed
        # selbst statt aus dem HTTP-Header (sonst kaputte Umlaute unter Windows PowerShell 5.1)
        $feedRequest.RawContentStream.Position = 0
        $feed = New-Object System.Xml.XmlDocument
        $feed.Load($feedRequest.RawContentStream)
    } catch {
        Write-Log "Überspringe Feed wegen Fehler: $_" -Level "ERROR"
        $failedFeeds++
        continue
    }

    # Punkt 1 & 2: Feed-Titel parsen und Unterordner generieren
    $channelTitleNode = $feed.SelectSingleNode("//*[local-name()='channel']/*[local-name()='title'] | //*[local-name()='feed']/*[local-name()='title']")
    $feedTitle = if ($channelTitleNode -and -not [string]::IsNullOrWhiteSpace($channelTitleNode.InnerText)) {
        Get-SafeFileName -Title $channelTitleNode.InnerText
    } else {
        "Unbekannter_Podcast"
    }

    # -Flat: Episoden landen ohne Unterordner direkt im Zielverzeichnis
    $feedOutputFolder = if ($Flat) { $Output } else { Join-Path -Path $Output -ChildPath $feedTitle }

    if (-not $DryRun) {
        [System.IO.Directory]::CreateDirectory($feedOutputFolder) | Out-Null
    }

    # GUID-Manifest laden: erkennt bereits geladene Episoden auch dann wieder,
    # wenn sich der Titel (und damit der Dateiname) im Feed geändert hat.
    $manifest = Get-DownloadManifest -Folder $feedOutputFolder
    $manifestChanged = $false
    $claimed = @{}
    foreach ($entry in $manifest.GetEnumerator()) { $claimed[[string]$entry.Value] = $entry.Key }
    $seenKeys = @{}
    $staleParts = 0

    $items = $feed.SelectNodes("//*[local-name()='item' or local-name()='entry']")
    if (-not $items -or $items.Count -eq 0) { continue }

    if ($Limit -gt 0) { $items = $items | Select-Object -First $Limit }

    $tasks = @()

    foreach ($item in $items) {
        $titleNode = $item.SelectSingleNode("*[local-name()='title']")
        $title = if ($titleNode) { $titleNode.InnerText.Trim() } else { "Unbekannte_Episode" }

        $mediaUrl = $null
        $mediaType = ""
        $enclosure = $item.SelectSingleNode("*[local-name()='enclosure']")
        if ($enclosure -and $enclosure.HasAttribute("url")) {
            $mediaUrl = $enclosure.GetAttribute("url")
            $mediaType = $enclosure.GetAttribute("type")
        } else {
            $linkNode = $item.SelectSingleNode("*[local-name()='link' and @rel='enclosure']")
            if ($linkNode -and $linkNode.HasAttribute("href")) {
                $mediaUrl = $linkNode.GetAttribute("href")
                $mediaType = $linkNode.GetAttribute("type")
            }
        }
        if ([string]::IsNullOrWhiteSpace($mediaUrl)) { continue }

        $guidNode = $item.SelectSingleNode("*[local-name()='guid' or local-name()='id']")
        $guid = if ($guidNode -and -not [string]::IsNullOrWhiteSpace($guidNode.InnerText)) { $guidNode.InnerText.Trim() } else { $null }
        $dedupKey = if ($guid) { $guid } else { $mediaUrl }
        if ($seenKeys.ContainsKey($dedupKey)) { continue }   # Dieselbe Folge steht doppelt im Feed
        $seenKeys[$dedupKey] = $true

        # Bereits geladen (ggf. unter altem Namen, falls sich der Titel geändert hat)?
        # Fehlt die Datei, wurde sie gelöscht -> erneut herunterladen.
        $recorded = $manifest[$dedupKey]
        if ($recorded -and (Test-Path -LiteralPath (Join-Path -Path $feedOutputFolder -ChildPath $recorded))) {
            Write-Log "Überspringe: $recorded" -Level "INFO"
            $totalSkipped++
            continue
        }

        # Präfix wie in der Python-Variante: letzte gültige Episodennummer, sonst erstes lesbares Datum
        $prefix = ""
        $episodeNumbers = @($item.SelectNodes("*[local-name()='episode']") | ForEach-Object { $_.InnerText.Trim() } | Where-Object { $_ -match '^\d+$' })
        if ($episodeNumbers.Count -gt 0) { $prefix = "{0:D3} - " -f [int]$episodeNumbers[-1] }
        else {
            foreach ($dateNode in $item.SelectNodes("*[local-name()='pubDate' or local-name()='published' or local-name()='updated']")) {
                $prefix = Get-DatePrefix -Text $dateNode.InnerText
                if ($prefix) { break }
            }
        }

        # Eindeutiger Name: gleicher Titel bei verschiedenen Folgen bekommt " (2)" usw.
        $extension = Get-MediaExtension -Url $mediaUrl -MediaType $mediaType
        $fileName = Get-UniqueFileName -Base "$prefix$(Get-SafeFileName -Title $title)" -Extension $extension -Key $dedupKey -Claimed $claimed
        $filePath = Join-Path -Path $feedOutputFolder -ChildPath $fileName
        $partPath = "$filePath.part"

        # Altbestand ohne Manifest-Eintrag: vorhandene Datei übernehmen statt neu zu laden
        if (Test-Path -LiteralPath $filePath) {
            Write-Log "Überspringe: $fileName" -Level "INFO"
            $totalSkipped++
            $manifest[$dedupKey] = $fileName
            $manifestChanged = $true
            continue
        }

        # Nur eigene .part-Dateien anfassen: zu alte werden neu begonnen statt fortgesetzt
        if (-not $DryRun -and (Test-Path -LiteralPath $partPath) -and
            (Get-Item -LiteralPath $partPath).LastWriteTime -lt (Get-Date).AddDays(-$script:PartMaxAgeDays)) {
            Remove-Item -LiteralPath $partPath -Force
            $staleParts++
        }

        $tasks += [PSCustomObject]@{ Url = $mediaUrl; Final = $filePath; Part = $partPath; Name = $fileName; DedupKey = $dedupKey }
    }

    if ($staleParts -gt 0) { Write-Log "Bereinigung: $staleParts veraltete .part-Datei(en) gelöscht." -Level "INFO" }
    if ($manifestChanged -and -not $DryRun) { Save-DownloadManifest -Folder $feedOutputFolder -Manifest $manifest }

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
                $success = Invoke-RobustDownload -DownloadUrl $task.Url -FinalPath $task.Final -PartPath $task.Part -MaxRetries $Retries -TimeoutSec $TimeoutSec -ProgressId 1 -State $global:SharedState

                if ($success) {
                    Write-Log "✔ Abgeschlossen: $($task.Name)" -Level "SUCCESS"
                    $totalDownloaded++
                    $manifest[$task.DedupKey] = $task.Name
                    Save-DownloadManifest -Folder $feedOutputFolder -Manifest $manifest
                } else {
                    $totalFailed++
                }
            }
        }
    }

    if ($M3u -and -not $DryRun) {
        # Playlist wird nun pro Feed-Ordner und mit passendem Titel erstellt
        New-M3uPlaylist -Folder $feedOutputFolder -Title $feedTitle
    }
}

Write-Log "=================================================="
Write-Log "SYNCHRONISATION ABGESCHLOSSEN"
Write-Log "✅ Heruntergeladen: $totalDownloaded"
Write-Log "⏭️ Übersprungen:   $totalSkipped"
if ($totalFailed -gt 0) { Write-Log "❌ Fehlgeschlagen:  $totalFailed" -Level "WARN" }
if ($failedFeeds -gt 0) { Write-Log "❌ Feeds mit Fehler: $failedFeeds" -Level "WARN" }
Write-Log "=================================================="
if ($totalFailed -gt 0 -or $failedFeeds -gt 0) { exit 1 }
