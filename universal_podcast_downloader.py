#!/usr/bin/env python3
# ==============================================================================
# Universal Podcast Downloader (Python Version)
# ==============================================================================

import re
import sys
import time
import logging
import argparse
import urllib.request
import urllib.error
from urllib.parse import urlparse
import xml.etree.ElementTree as ET
from pathlib import Path
from email.utils import parsedate_to_datetime

# ==============================================================================
# BENUTZER-EINSTELLUNGEN (Hier anpassen)
# ==============================================================================
# Tragen Sie hier die URL des gewünschten RSS-Feeds ein:
DEFAULT_RSS_URL = "https://beispiel-url.de/podcast/feed.rss"

# Tragen Sie hier den Standard-Speicherort für die MP3-Dateien ein.
# Path.home() verweist automatisch auf Ihr Benutzerverzeichnis (z.B. /home/nutzer/ oder C:\Users\Nutzer\).
DEFAULT_DOWNLOAD_FOLDER = str(Path.home() / "Podcasts" / "MeinPodcast")

# Maximale Anzahl der neuesten Episoden, die geladen werden sollen (0 = alle laden):
DEFAULT_LIMIT = 0
# ==============================================================================

# Windows-spezifische reservierte Namen (Sicherheitsmaßnahme für plattformübergreifende Nutzung)
RESERVED_NAMES = {
    "CON", "PRN", "AUX", "NUL", "COM1", "COM2", "COM3", "COM4", "COM5", 
    "COM6", "COM7", "COM8", "COM9", "LPT1", "LPT2", "LPT3", "LPT4", 
    "LPT5", "LPT6", "LPT7", "LPT8", "LPT9"
}

def setup_logging():
    """Richtet das Logging-Modul für konsistente Ausgaben ein."""
    logging.basicConfig(
        level=logging.INFO,
        format='%(asctime)s [%(levelname)s] %(message)s',
        datefmt='%Y-%m-%d %H:%M:%S'
    )

def clean_filename(title):
    """Bereinigt den Episodentitel für das Dateisystem."""
    # Ungültige Zeichen entfernen
    safe_title = re.sub(r'[<>:"/\\|?*]', '-', title)
    # Längenlimitierung (MAX_PATH Vorbeugung)
    safe_title = safe_title[:150].strip()
    # Reservierte Namen abfangen
    if safe_title.upper() in RESERVED_NAMES:
        safe_title = f"Episode_{safe_title}"
    return safe_title

def parse_feed(url, headers):
    """Lädt und parst den RSS/Atom-Feed namespace-unabhängig."""
    logging.info(f"Analysiere Feed: {url}")
    try:
        req = urllib.request.Request(url, headers=headers)
        with urllib.request.urlopen(req, timeout=30) as response:
            xml_data = response.read()
        root = ET.fromstring(xml_data)
        
        # Namespace-agnostische Suche für <item> (RSS) und <entry> (Atom)
        items = []
        for elem in root.iter():
            if elem.tag.endswith('item') or elem.tag.endswith('entry'):
                items.append(elem)
        return items
    except Exception as e:
        logging.error(f"Fehler beim Abruf oder Parsing des Feeds: {e}")
        sys.exit(1)

def extract_episode_data(item):
    """Extrahiert Titel, URL und Präfix (Nummer/Datum) aus einem XML-Element."""
    title = "Unbekannte_Episode"
    mp3_url = None
    prefix = ""

    for child in item:
        tag_name = child.tag.split('}')[-1]  # Namespace abschneiden
        
        if tag_name == 'title' and child.text:
            title = child.text.strip()
            
        elif tag_name == 'enclosure' and child.get('url'):
            mp3_url = child.get('url')
            
        elif tag_name == 'link' and child.get('rel') == 'enclosure' and child.get('href'):
            mp3_url = child.get('href')
            
        elif tag_name == 'episode' and child.text and child.text.strip().isdigit():
            prefix = f"{int(child.text.strip()):03d} - "
            
        elif tag_name in ('pubDate', 'published', 'updated') and not prefix:
            try:
                dt = parsedate_to_datetime(child.text)
                prefix = f"{dt.strftime('%Y-%m-%d')} - "
            except (ValueError, TypeError):
                pass
                
    return title, mp3_url, prefix

def download_episode(url, final_path, part_path, headers, max_retries):
    """Lädt die Datei herunter, mit Resume-Funktion und Fortschrittsbalken."""
    for attempt in range(1, max_retries + 1):
        try:
            req_headers = headers.copy()
            initial_size = 0
            mode = 'wb'

            # Resume-Logik: Falls eine .part Datei existiert, prüfen wir die Größe
            if part_path.exists():
                initial_size = part_path.stat().st_size
                req_headers['Range'] = f"bytes={initial_size}-"

            req = urllib.request.Request(url, headers=req_headers)
            with urllib.request.urlopen(req, timeout=60) as resp:
                
                # Wenn der Server den Range-Header ignoriert (Status 200 statt 206), von vorne beginnen
                if initial_size > 0 and resp.status != 206:
                    logging.info("Server unterstützt kein Resume. Starte Download neu.")
                    initial_size = 0
                    mode = 'wb'
                elif initial_size > 0 and resp.status == 206:
                    logging.info(f"Setze abgebrochenen Download fort (ab {initial_size / (1024*1024):.1f} MB).")
                    mode = 'ab'

                total_size = int(resp.headers.get('Content-Length', 0)) + initial_size
                downloaded = initial_size

                with open(part_path, mode) as out_file:
                    while True:
                        # 1 MB Chunks, um RAM zu schonen und Netzwerk-Timeouts vorzubeugen
                        chunk = resp.read(1024 * 1024)
                        if not chunk:
                            break
                        out_file.write(chunk)
                        downloaded += len(chunk)
                        
                        # Fortschrittsbalken zeichnen
                        if total_size > 0:
                            pct = (downloaded / total_size) * 100
                            sys.stdout.write(f"\r    Fortschritt: [{pct:6.2f}%] {downloaded / (1024*1024):.1f} MB / {total_size / (1024*1024):.1f} MB")
                            sys.stdout.flush()

                sys.stdout.write("\n")  # Zeilenumbruch nach Fortschrittsbalken
                
                # Größenprüfung
                if total_size > 0 and downloaded < total_size:
                    raise urllib.error.URLError("Download unvollständig (Verbindung abgerissen)")

                part_path.rename(final_path)
                logging.info(f"Download erfolgreich abgeschlossen.")
                return  # Erfolgreich -> Funktion verlassen

        except Exception as e:
            sys.stdout.write("\n")
            if attempt < max_retries:
                sleep_time = 2 ** attempt  # Exponentielles Backoff: 2, 4, 8 Sekunden...
                logging.warning(f"Fehler bei Versuch {attempt}/{max_retries}: {e}. Warte {sleep_time}s...")
                time.sleep(sleep_time)
            else:
                logging.error(f"Endgültig fehlgeschlagen nach {max_retries} Versuchen: {e}")
                # part_path wird absichtlich nicht gelöscht, um Resume bei einem späteren Start zu ermöglichen

def main():
    # CLI Argument-Parsing einrichten
    parser = argparse.ArgumentParser(description="Ein robuster Podcast-Downloader für RSS & Atom Feeds.")
    parser.add_argument("-u", "--url", default=DEFAULT_RSS_URL, help="URL des RSS-Feeds")
    parser.add_argument("-o", "--output", default=DEFAULT_DOWNLOAD_FOLDER, help="Zielverzeichnis")
    parser.add_argument("-l", "--limit", type=int, default=DEFAULT_LIMIT, help="Nur die neuesten N Episoden laden (0 = alle)")
    parser.add_argument("--retries", type=int, default=3, help="Maximale Anzahl der Download-Versuche")
    
    args = parser.parse_args()
    
    setup_logging()
    
    # Generischer, weit verbreiteter User-Agent schützt vor Tracking durch Exotik, 
    # überwindet aber gleichzeitig CDN-Blockaden.
    headers = {
        'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36'
    }

    download_folder = Path(args.output)
    if not download_folder.exists():
        download_folder.mkdir(parents=True, exist_ok=True)
        logging.info(f"Verzeichnis erstellt: {download_folder}")

    # Feed verarbeiten
    items = parse_feed(args.url, headers)
    
    if args.limit > 0:
        items = items[:args.limit]
        logging.info(f"Limit aktiv: Verarbeite nur die neuesten {args.limit} Episoden.")
    else:
        logging.info(f"{len(items)} Episoden im Feed gefunden.")

    # Episoden herunterladen
    for item in items:
        title, mp3_url, prefix = extract_episode_data(item)
        
        if not mp3_url:
            continue
            
        safe_title = clean_filename(title)
        
        # Dateiendung dynamisch aus URL ermitteln (fängt auch .m4a, .ogg ab)
        url_path = urlparse(mp3_url).path
        ext = Path(url_path).suffix or ".mp3"
        
        file_path = download_folder / f"{prefix}{safe_title}{ext}"
        part_path = file_path.with_suffix(ext + ".part")
        
        if file_path.exists():
            logging.info(f"Überspringe (bereits vorhanden): {file_path.name}")
        else:
            logging.info(f"Starte Download: {file_path.name}")
            download_episode(mp3_url, file_path, part_path, headers, args.retries)

    logging.info("Synchronisation erfolgreich abgeschlossen.")

if __name__ == "__main__":
    # Verhindert, dass das Skript sofort schließt, falls Fehler bei der initialen Ausführung auftreten
    try:
        main()
    except KeyboardInterrupt:
        print("\nAbbruch durch Benutzer.")
        sys.exit(0)
