# ==============================================================================
# Universal Podcast Downloader (Python Version - Refactored & Optimized)
# ==============================================================================

import os
import re
import sys
import shutil
import urllib.request
import xml.etree.ElementTree as ET
from pathlib import Path
from email.utils import parsedate_to_datetime

# Konfiguration: URL des RSS-Feeds
rss_url = "https://beispiel-url.de/podcast/feed.rss"

# Konfiguration: Zielverzeichnis für den Download
# Path.home() ist plattformunabhängig (~ unter Linux, C:\Users\... unter Windows)
download_folder = Path.home() / "Podcasts" / "MeinLieblingsPodcast"

# HTTP-Header-Anpassung zur Vermeidung von 403 Forbidden Fehlern durch CDNs
headers = {
    'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36'
}

# Windows-spezifische reservierte Dateinamen (Dürfen nicht als Dateiname verwendet werden)
RESERVED_NAMES = {
    "CON", "PRN", "AUX", "NUL",
    "COM1", "COM2", "COM3", "COM4", "COM5", "COM6", "COM7", "COM8", "COM9",
    "LPT1", "LPT2", "LPT3", "LPT4", "LPT5", "LPT6", "LPT7", "LPT8", "LPT9"
}

# 1. Überprüfung und Erstellung des Zielverzeichnisses
if not download_folder.exists():
    download_folder.mkdir(parents=True, exist_ok=True)
    print(f"\033[92mVerzeichnis erstellt: {download_folder}\033[0m")

print(f"\033[96mAnalysiere RSS-Feed: {rss_url}\033[0m")

# 2. HTTP-Anfrage durchführen und XML-Struktur parsen
try:
    req = urllib.request.Request(rss_url, headers=headers)
    # Timeout von 30 Sekunden verhindert ein endloses Blockieren des Skripts
    with urllib.request.urlopen(req, timeout=30) as response:
        xml_data = response.read()
    
    # XML-Parsing
    root = ET.fromstring(xml_data)
except Exception as e:
    print(f"\033[91mFehler beim Abruf oder Parsing des RSS-Feeds: {e}\033[0m")
    sys.exit(1) # sys.exit() anstelle des interaktiven exit()

# Extraktion der Episoden (Robustere XPath-Suche, umgeht einfache Namespace-Probleme)
items = root.findall('.//item')

if not items:
    print("\033[91mEs konnten keine Episoden extrahiert werden.\033[0m")
    sys.exit(1)

print(f"\033[96m{len(items)} Episoden im Feed detektiert. Starte Synchronisation...\033[0m")

# Namespace Definition für iTunes-Tags
ns = {'itunes': 'http://www.itunes.com/dtds/podcast-1.0.dtd'}

# 3. Iteration über alle extrahierten Episoden
for item in items:
    title_elem = item.find('title')
    enclosure_elem = item.find('enclosure')
    
    # Robuster Umgang mit leeren Tags wie <title></title>
    title = (
        title_elem.text.strip() 
        if title_elem is not None and title_elem.text 
        else "Unbekannte_Episode"
    )
    
    # Validierung der Dateianlage
    if enclosure_elem is not None and enclosure_elem.get('url'):
        mp3_url = enclosure_elem.get('url')
        
        # Validierung des Dateinamens: Bereinigung ungültiger Zeichen
        safe_title = re.sub(r'[<>:"/\\|?*]', '-', title)
        safe_title = safe_title.replace(':', ' -').replace('?', '').replace('/', '-').strip()
        
        # Prüfung auf reservierte Windows-Dateinamen
        if safe_title.upper() in RESERVED_NAMES:
            safe_title = f"Episode_{safe_title}"
        
        # Bestimmung des Präfix (Episodennummer oder Publikationsdatum)
        prefix = ""
        itunes_ep = item.find('itunes:episode', namespaces=ns)
        
        if itunes_ep is not None and itunes_ep.text and itunes_ep.text.strip().isdigit():
            # Präferenz 1: iTunes-Tag (mit Nullen aufgefüllt auf 3 Stellen)
            prefix = f"{int(itunes_ep.text.strip()):03d} - "
        else:
            # Präferenz 2 (Fallback): Publikationsdatum nutzen (z.B. 2024-08-14 - Titel.mp3)
            # Dies ist stabiler als einfaches Abwärtszählen, falls der Feed abgeschnitten wird.
            pubdate_elem = item.find('pubDate')
            if pubdate_elem is not None and pubdate_elem.text:
                try:
                    dt = parsedate_to_datetime(pubdate_elem.text)
                    prefix = f"{dt.strftime('%Y-%m-%d')} - "
                except Exception:
                    pass # Falls das Datum nicht geparst werden kann, bleibt das Präfix leer
            
        # Extraktion der Dateiendung ohne URL-Parameter (z.B. ?v=1)
        url_without_query = mp3_url.split('?')[0]
        _, extension = os.path.splitext(url_without_query)
        
        if not extension:
            extension = ".mp3"
            
        # Konstruktion der finalen Dateipfade
        file_name = f"{prefix}{safe_title}{extension}"
        file_path = download_folder / file_name
        
        # Temporäre Datei für den Download (.part) um Dateileichen bei Abbrüchen zu verhindern
        part_path = file_path.with_suffix(extension + ".part")
        
        # 4. Inkrementeller Download
        if file_path.exists():
            print(f"\033[90mÜberspringe (Datei bereits vorhanden): {file_name}\033[0m")
        else:
            print(f"\033[93mDownload gestartet: {file_name}\033[0m")
            try:
                # Streaming-Download per shutil verhindert Vollaufen des RAM bei großen Dateien
                req_dl = urllib.request.Request(mp3_url, headers=headers)
                with urllib.request.urlopen(req_dl, timeout=30) as response_dl, open(part_path, 'wb') as out_file:
                    shutil.copyfileobj(response_dl, out_file)
                
                # Nach erfolgreichem Download: .part Endung entfernen
                part_path.rename(file_path)
                print(f"\033[92mDownload erfolgreich: {file_name}\033[0m")
            except Exception as e:
                print(f"\033[91mFehler beim Download von {file_name}: {e}\033[0m")
                # Temporäre Datei bei Fehler aufräumen
                if part_path.exists():
                    part_path.unlink()

print("\033[92mSynchronisation erfolgreich abgeschlossen.\033[0m")
