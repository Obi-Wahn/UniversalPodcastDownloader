# ==============================================================================
# Universal Podcast Downloader (Python Version)
# ==============================================================================

import os
import re
import urllib.request
import xml.etree.ElementTree as ET
from pathlib import Path

# Konfiguration: URL des RSS-Feeds
rss_url = "https://beispiel-url.de/podcast/feed.rss"

# Konfiguration: Zielverzeichnis für den Download
# Path.home() ist plattformunabhängig (~ unter Linux, C:\Users\... unter Windows)
download_folder = Path.home() / "Podcasts" / "MeinLieblingsPodcast"

# HTTP-Header-Anpassung zur Vermeidung von 403 Forbidden Fehlern durch CDNs
headers = {
    'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36'
}

# 1. Überprüfung und Erstellung des Zielverzeichnisses
if not download_folder.exists():
    download_folder.mkdir(parents=True, exist_ok=True)
    print(f"\033[92mVerzeichnis erstellt: {download_folder}\033[0m")

print(f"\033[96mAnalysiere RSS-Feed: {rss_url}\033[0m")

# 2. HTTP-Anfrage durchführen und XML-Struktur parsen
try:
    req = urllib.request.Request(rss_url, headers=headers)
    with urllib.request.urlopen(req) as response:
        xml_data = response.read()
    
    # XML-Parsing
    root = ET.fromstring(xml_data)
except Exception as e:
    print(f"\033[91mFehler beim Abruf oder Parsing des RSS-Feeds: {e}\033[0m")
    exit(1)

# Extraktion der Episoden
items = root.findall('./channel/item')

if not items:
    print("\033[91mEs konnten keine Episoden extrahiert werden.\033[0m")
    exit(1)

print(f"\033[96m{len(items)} Episoden im Feed detektiert. Starte Synchronisation...\033[0m")

total_items = len(items)
# Namespace Definition für iTunes-Tags
ns = {'itunes': 'http://www.itunes.com/dtds/podcast-1.0.dtd'}

# 3. Iteration über alle extrahierten Episoden
for index, item in enumerate(items):
    title_elem = item.find('title')
    enclosure_elem = item.find('enclosure')
    
    title = title_elem.text if title_elem is not None else "Unbekannte Episode"
    
    # Validierung der Dateianlage
    if enclosure_elem is not None and enclosure_elem.get('url'):
        mp3_url = enclosure_elem.get('url')
        
        # Validierung des Dateinamens: Bereinigung ungültiger Zeichen
        safe_title = re.sub(r'[<>:"/\\|?*]', '-', title)
        safe_title = safe_title.replace(':', ' -').replace('?', '').replace('/', '-').strip()
        
        # Bestimmung der Episodennummer
        ep_num = None
        itunes_ep = item.find('itunes:episode', ns)
        
        # Präferenz 1: iTunes-Tag
        if itunes_ep is not None and itunes_ep.text:
            ep_num = itunes_ep.text
        # Präferenz 2: Fallback (Berechnung basierend auf Index)
        else:
            ep_num = str(total_items - index)
            
        # Formatierung auf drei Stellen
        try:
            ep_formatted = f"{int(ep_num):03d}"
        except ValueError:
            ep_formatted = ep_num
            
        # Extraktion der Dateiendung ohne URL-Parameter (z.B. ?v=1)
        url_without_query = mp3_url.split('?')[0]
        _, extension = os.path.splitext(url_without_query)
        
        if not extension:
            extension = ".mp3"
            
        # Konstruktion des finalen Dateipfads
        file_name = f"{ep_formatted} - {safe_title}{extension}"
        file_path = download_folder / file_name
        
        # 4. Inkrementeller Download
        if file_path.exists():
            print(f"\033[90mÜberspringe (Datei bereits vorhanden): {file_name}\033[0m")
        else:
            print(f"\033[93mDownload gestartet: {file_name}\033[0m")
            try:
                # Streaming-Download, um den Arbeitsspeicher bei großen Dateien zu schonen
                req_dl = urllib.request.Request(mp3_url, headers=headers)
                with urllib.request.urlopen(req_dl) as response_dl, open(file_path, 'wb') as out_file:
                    out_file.write(response_dl.read())
                print(f"\033[92mDownload erfolgreich: {file_name}\033[0m")
            except Exception as e:
                print(f"\033[91mFehler beim Download von {file_name}: {e}\033[0m")

print("\033[92mSynchronisation erfolgreich abgeschlossen.\033[0m")
