# ==============================================================================
# Universal Podcast Downloader (Python Version - Ultimate Edition)
# ==============================================================================

import os
import re
import sys
import shutil
import urllib.request
import xml.etree.ElementTree as ET
from pathlib import Path
from email.utils import parsedate_to_datetime

# Konfiguration: URL des RSS-Feeds (Platzhalter)
rss_url = "https://DEINE-PODCAST-URL.de/feed.rss"

# Konfiguration: Zielverzeichnis (Standard: Unterordner im Benutzerverzeichnis)
download_folder = Path.home() / "Podcasts" / "MeinPodcast"

# HTTP-Header (Tarnung als Browser zur Umgehung von CDN-Blockaden)
headers = {
    'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36'
}

# Windows-spezifische reservierte Namen
RESERVED_NAMES = {
    "CON", "PRN", "AUX", "NUL", "COM1", "COM2", "COM3", "COM4", "COM5", 
    "COM6", "COM7", "COM8", "COM9", "LPT1", "LPT2", "LPT3", "LPT4", 
    "LPT5", "LPT6", "LPT7", "LPT8", "LPT9"
}

# 1. Verzeichnis-Setup
if not download_folder.exists():
    download_folder.mkdir(parents=True, exist_ok=True)
    print(f"\033[92mVerzeichnis erstellt: {download_folder}\033[0m")

print(f"\033[96mAnalysiere Feed: {rss_url}\033[0m")

# 2. HTTP-Anfrage & XML-Parsing
try:
    req = urllib.request.Request(rss_url, headers=headers)
    with urllib.request.urlopen(req, timeout=30) as response:
        xml_data = response.read()
    root = ET.fromstring(xml_data)
except Exception as e:
    print(f"\033[91mFehler: {e}\033[0m")
    sys.exit(1)

# Namespace-unabhängige Suche (RSS <item> oder Atom <entry>)
items = root.findall('.//item') + root.findall('.//{http://www.w3.org/2005/Atom}entry')

if not items:
    print("\033[91mKeine Episoden gefunden.\033[0m")
    sys.exit(1)

print(f"\033[96m{len(items)} Episoden detektiert. Synchronisation startet...\033[0m")

# 3. Episoden verarbeiten
for item in items:
    title_elem = item.find('.//title')
    title = title_elem.text.strip() if title_elem is not None and title_elem.text else "Unbekannte_Episode"
    
    # URL finden (RSS enclosure oder Atom link)
    enclosure = item.find('.//enclosure')
    link = item.find('.//link[@rel="enclosure"]')
    mp3_url = enclosure.get('url') if enclosure is not None else (link.get('href') if link is not None else None)
    
    if mp3_url:
        # Bereinigung
        safe_title = re.sub(r'[<>:"/\\|?*]', '-', title)
        safe_title = safe_title.replace(':', ' -').strip()
        if safe_title.upper() in RESERVED_NAMES: safe_title = f"Episode_{safe_title}"
        if len(safe_title) > 150: safe_title = safe_title[:150].strip()
        
        # Präfix (Episode oder Datum)
        prefix = ""
        ep_node = item.find('.//{http://www.itunes.com/dtds/podcast-1.0.dtd}episode')
        if ep_node is not None and ep_node.text and ep_node.text.strip().isdigit():
            prefix = f"{int(ep_node.text.strip()):03d} - "
        else:
            pub_node = item.find('.//pubDate') or item.find('.//published') or item.find('.//updated')
            if pub_node is not None and pub_node.text:
                try:
                    dt = parsedate_to_datetime(pub_node.text)
                    prefix = f"{dt.strftime('%Y-%m-%d')} - "
                except: pass
        
        # Download
        file_path = download_folder / f"{prefix}{safe_title}.mp3"
        part_path = file_path.with_suffix(".mp3.part")
        
        if file_path.exists():
            print(f"\033[90mÜberspringe: {file_path.name}\033[0m")
        else:
            print(f"\033[93mLade: {file_path.name}\033[0m")
            
            # Retry-Logik für instabile Netzwerkverbindungen
            max_retries = 3
            for attempt in range(max_retries):
                try:
                    req_dl = urllib.request.Request(mp3_url, headers=headers)
                    # Timeout von 60 statt 30 Sekunden für große Specials
                    with urllib.request.urlopen(req_dl, timeout=60) as resp, open(part_path, 'wb') as out:
                        shutil.copyfileobj(resp, out)
                    part_path.rename(file_path)
                    print(f"\033[92mDownload erfolgreich nach Versuch {attempt+1}.\033[0m")
                    break
                except Exception as e:
                    if attempt < max_retries - 1:
                        print(f"\033[93mTimeout bei Versuch {attempt+1}, neuer Versuch...\033[0m")
                    else:
                        if part_path.exists(): part_path.unlink()
                        print(f"\033[91mFehler nach {max_retries} Versuchen: {e}\033[0m")

print("\033[92mSynchronisation abgeschlossen.\033[0m")
