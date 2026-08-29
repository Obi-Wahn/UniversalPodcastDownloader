#!/usr/bin/env python3
# ==============================================================================
# Universal Podcast Downloader (Python Version)
# ==============================================================================
# Ein plattformübergreifendes, robustes Skript zur automatisierten Archivierung
# von Podcasts. Unterstützt RSS/Atom-Feeds, OPML-Import, Multithreading, 
# Resume-Funktionalität bei Verbindungsabbrüchen und M3U-Playlisten.
# ==============================================================================

import os
import re
import sys
import time
import json
import logging
import argparse
import threading
import urllib.request
import urllib.error
from urllib.parse import urlparse
import xml.etree.ElementTree as ET
from pathlib import Path
from email.utils import parsedate_to_datetime
from concurrent.futures import ThreadPoolExecutor, as_completed
from typing import List, Tuple, Optional, Dict, Any

# ==============================================================================
# KONSTANTEN & DEFAULTS
# ==============================================================================
DEFAULT_RSS_URL = "https://beispiel-url.de/podcast/feed.rss"
DEFAULT_DOWNLOAD_FOLDER = str(Path.home() / "Podcasts" / "MeinPodcast")
DEFAULT_LIMIT = 0
DEFAULT_TIMEOUT = 60
DEFAULT_WORKERS = 1

CHUNK_SIZE = 1 << 20  
MAX_FILE_SIZE = 1024 * 1024 * 1024  

RESERVED_NAMES = {
    "CON", "PRN", "AUX", "NUL", "COM1", "COM2", "COM3", "COM4", "COM5", 
    "COM6", "COM7", "COM8", "COM9", "LPT1", "LPT2", "LPT3", "LPT4", 
    "LPT5", "LPT6", "LPT7", "LPT8", "LPT9"
}

ABORT_EVENT = threading.Event()

# ==============================================================================
# KLASSEN & LOGGING
# ==============================================================================
class ColorFormatter(logging.Formatter):
    COLORS = {
        logging.DEBUG: "\033[90m",
        logging.INFO: "\033[36m",
        logging.WARNING: "\033[33m",
        logging.ERROR: "\033[31m",
        logging.CRITICAL: "\033[1m\033[31m",
    }
    RESET = "\033[0m"

    def format(self, record: logging.LogRecord) -> str:
        color = self.COLORS.get(record.levelno, self.RESET)
        record.msg = f"{color}{record.msg}{self.RESET}"
        return super().format(record)

def setup_logging() -> None:
    if os.name == 'nt':
        os.system("") 
    handler = logging.StreamHandler()
    handler.setFormatter(ColorFormatter('%(asctime)s [%(levelname)s] %(message)s', datefmt='%Y-%m-%d %H:%M:%S'))
    logging.basicConfig(level=logging.INFO, handlers=[handler])

class ProgressManager:
    def __init__(self, total_files: int):
        self.lock = threading.Lock()
        self.active: Dict[str, Dict[str, Any]] = {}
        self.completed = 0
        self.total_files = total_files
        self.lines_printed = 0
        self.last_render = 0.0

    def update(self, filename: str, downloaded: int, total: int, speed_bps: float, eta_sec: float):
        with self.lock:
            self.active[filename] = {
                "downloaded": downloaded,
                "total": total,
                "speed": speed_bps,
                "eta": eta_sec
            }
            now = time.time()
            if now - self.last_render > 0.2 or downloaded == total:
                self._render()
                self.last_render = now

    def complete(self, filename: str, success: bool):
        with self.lock:
            self._clear_lines()
            if filename in self.active:
                del self.active[filename]
            self.completed += 1
            if success and not ABORT_EVENT.is_set():
                t = time.strftime('%Y-%m-%d %H:%M:%S')
                sys.stdout.write(f"{t} [\033[32mSUCCESS\033[0m] \033[32m✔ Abgeschlossen: {filename}\033[0m\n")
            self._render()

    def log_error(self, message: str):
        with self.lock:
            self._clear_lines()
            logging.error(message)
            self._render()

    def log_warning(self, message: str):
        with self.lock:
            self._clear_lines()
            logging.warning(message)
            self._render()

    def _clear_lines(self):
        if self.lines_printed > 0:
            sys.stdout.write(f"\033[{self.lines_printed}A")
            for _ in range(self.lines_printed):
                sys.stdout.write("\033[K\n")
            sys.stdout.write(f"\033[{self.lines_printed}A")
            sys.stdout.flush()
            self.lines_printed = 0

    def _render(self):
        if self.lines_printed > 0:
            sys.stdout.write(f"\033[{self.lines_printed}A")

        lines = []
        lines.append(f"\033[1m\033[36mGesamtfortschritt:\033[0m {self.completed} von {self.total_files} Dateien bearbeitet")

        for fname, stats in self.active.items():
            dl = stats["downloaded"]
            tot = stats["total"]
            speed = stats["speed"] / (1024*1024)
            eta = format_eta(stats["eta"])

            short_fname = fname[:30] + "..." if len(fname) > 33 else fname.ljust(33)
            
            if tot > 0:
                pct = (dl / tot) * 100
                lines.append(f"  \033[33m{short_fname}\033[0m | [{pct:6.2f}%] {dl/(1024*1024):5.1f}/{tot/(1024*1024):5.1f} MB | {speed:4.1f} MB/s | ETA: {eta}")
            else:
                lines.append(f"  \033[33m{short_fname}\033[0m | {dl/(1024*1024):5.1f} MB geladen | {speed:4.1f} MB/s")

        for line in lines:
            sys.stdout.write(f"{line}\033[K\n")

        sys.stdout.flush()
        self.lines_printed = len(lines)

# ==============================================================================
# HILFSFUNKTIONEN
# ==============================================================================
def validate_url(url: str) -> bool:
    try:
        result = urlparse(url)
        return all([result.scheme, result.netloc])
    except ValueError:
        return False

def clean_filename(title: str) -> str:
    # Entfernt unsichtbare Steuerzeichen (\x00-\x1f) und illegale Windows-Zeichen
    safe_title = re.sub(r'[\x00-\x1f<>:"/\\|?*]', '-', title)
    # Entfernt trailing spaces und dots (ungültig am Dateiende in Windows)
    safe_title = safe_title[:150].strip(' .')
    
    if safe_title.upper() in RESERVED_NAMES:
        safe_title = f"Episode_{safe_title}"
    return safe_title

def cleanup_old_parts(folder: Path, days_old: int = 7) -> None:
    now = time.time()
    count = 0
    for part_file in folder.glob("*.part"):
        if now - part_file.stat().st_mtime > (days_old * 86400):
            part_file.unlink()
            count += 1
    if count > 0:
        logging.info(f"Bereinigung: {count} veraltete .part-Datei(en) gelöscht.")

def format_eta(seconds: float) -> str:
    if seconds < 0 or seconds == float('inf'):
        return "--:--"
    m, s = divmod(int(seconds), 60)
    h, m = divmod(m, 60)
    if h > 0:
        return f"{h:02d}:{m:02d}:{s:02d}"
    return f"{m:02d}:{s:02d}"

# ==============================================================================
# KERN-LOGIK
# ==============================================================================
def parse_opml(file_path: str) -> List[str]:
    urls = []
    try:
        tree = ET.parse(file_path)
        for outline in tree.findall('.//outline'):
            xml_url = outline.get('xmlUrl')
            if xml_url and validate_url(xml_url):
                urls.append(xml_url)
    except Exception as e:
        logging.error(f"Fehler beim Parsen der OPML-Datei {file_path}: {e}")
    return urls

def parse_feed(url: str, headers: Dict[str, str], timeout: int) -> Tuple[str, List[ET.Element]]:
    if not validate_url(url):
        raise ValueError(f"Ungültige Feed-URL: {url}")
        
    logging.info(f"Analysiere Feed: {url}")
    req = urllib.request.Request(url, headers=headers)
    with urllib.request.urlopen(req, timeout=timeout) as response:
        xml_data = response.read()
    
    root = ET.fromstring(xml_data)
    
    # Extraktion des Channel-Titels (für den Unterordner-Namen)
    channel_title = root.find('./channel/title')
    atom_title = root.find('./{http://www.w3.org/2005/Atom}title')
    
    if channel_title is not None and channel_title.text:
        feed_title = channel_title.text.strip()
    elif atom_title is not None and atom_title.text:
        feed_title = atom_title.text.strip()
    else:
        feed_title = "Unbekannter_Podcast"
    
    items = [elem for elem in root.iter() if elem.tag.endswith('item') or elem.tag.endswith('entry')]
    return feed_title, items

def extract_episode_data(item: ET.Element) -> Tuple[str, Optional[str], str]:
    title = "Unbekannte_Episode"
    mp3_url = None
    prefix = ""

    for child in item:
        tag_name = child.tag.split('}')[-1]
        
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

def download_episode(url: str, final_path: Path, part_path: Path, headers: Dict[str, str], 
                     max_retries: int, timeout_sec: int, pm: ProgressManager) -> bool:
    for attempt in range(1, max_retries + 1):
        if ABORT_EVENT.is_set():
            return False

        try:
            req_headers = headers.copy()
            initial_size = 0
            mode = 'wb'

            if part_path.exists():
                initial_size = part_path.stat().st_size
                req_headers['Range'] = f"bytes={initial_size}-"

            req = urllib.request.Request(url, headers=req_headers)
            with urllib.request.urlopen(req, timeout=timeout_sec) as resp:
                
                if initial_size > 0 and resp.status != 206:
                    initial_size = 0
                    mode = 'wb'
                elif initial_size > 0 and resp.status == 206:
                    mode = 'ab'

                total_size = int(resp.headers.get('Content-Length', 0))
                if total_size > 0:
                    total_size += initial_size
                    
                if total_size > MAX_FILE_SIZE:
                    pm.log_warning(f"Datei überschreitet 1GB-Limit, überspringe: {final_path.name}")
                    return False

                downloaded = initial_size
                start_time = time.time()

                with open(part_path, mode) as out_file:
                    while True:
                        if ABORT_EVENT.is_set():
                            return False

                        chunk = resp.read(CHUNK_SIZE)
                        if not chunk:
                            break
                        
                        out_file.write(chunk)
                        downloaded += len(chunk)
                        
                        # In-Flight Prüfung, falls Content-Length vom Server nicht geliefert wurde
                        if downloaded > MAX_FILE_SIZE:
                            pm.log_warning(f"Datei überschreitet 1GB-Limit während des Downloads, Abbruch: {final_path.name}")
                            return False
                        
                        now = time.time()
                        elapsed = now - start_time
                        speed_bps = (downloaded - initial_size) / elapsed if elapsed > 0 else 0
                        eta = (total_size - downloaded) / speed_bps if speed_bps > 0 and total_size > 0 else 0
                        
                        pm.update(final_path.name, downloaded, total_size, speed_bps, eta)

                if total_size > 0 and downloaded < total_size:
                    raise urllib.error.URLError("Download unvollständig (Verbindung abgerissen)")

                part_path.rename(final_path)
                return True

        except Exception as e:
            if ABORT_EVENT.is_set():
                return False

            if attempt < max_retries:
                # Gedeckelter Backoff (Maximal 60 Sekunden Wartezeit)
                sleep_time = min(2 ** attempt, 60)
                pm.log_warning(f"Fehler bei {final_path.name} (Versuch {attempt}): {e}. Warte {sleep_time}s...")
                
                for _ in range(sleep_time * 10):
                    if ABORT_EVENT.is_set(): return False
                    time.sleep(0.1)
            else:
                pm.log_error(f"Fehlgeschlagen nach {max_retries} Versuchen: {final_path.name}")
                if part_path.exists():
                    part_path.unlink()
    return False

def generate_m3u(folder: Path, feed_title: str) -> None:
    playlist_path = folder / f"{clean_filename(feed_title)}_Playlist.m3u"
    mp3_files = sorted(folder.glob("*.mp3"))
    
    if not mp3_files:
        return

    try:
        with open(playlist_path, 'w', encoding='utf-8') as f:
            f.write("#EXTM3U\n")
            for mp3 in mp3_files:
                f.write(f"{mp3.name}\n")
        logging.info(f"M3U-Playlist generiert: {playlist_path.name}")
    except Exception as e:
        logging.error(f"Konnte M3U nicht erstellen: {e}")

# ==============================================================================
# MAIN (Programm-Einstiegspunkt)
# ==============================================================================
def main() -> None:
    parser = argparse.ArgumentParser(description="Ein robuster Podcast-Downloader für RSS & Atom Feeds.")
    parser.add_argument("-u", "--url", default=None, help="URL des RSS-Feeds")
    parser.add_argument("-c", "--config", type=str, help="Pfad zur config.json")
    parser.add_argument("--opml", type=str, help="Pfad zu einer OPML-Datei mit mehreren Feeds")
    parser.add_argument("-o", "--output", default=DEFAULT_DOWNLOAD_FOLDER, help="Zielverzeichnis")
    parser.add_argument("-l", "--limit", type=int, default=DEFAULT_LIMIT, help="Max. Episoden (0 = alle)")
    parser.add_argument("--retries", type=int, default=3, help="Max. Download-Versuche")
    parser.add_argument("-t", "--timeout", type=int, default=DEFAULT_TIMEOUT, help="Netzwerk-Timeout in Sekunden")
    parser.add_argument("-w", "--workers", type=int, default=DEFAULT_WORKERS, help="Anzahl paralleler Downloads")
    parser.add_argument("--dry-run", action="store_true", help="Simuliert den Vorgang, lädt aber nichts herunter")
    parser.add_argument("--m3u", action="store_true", help="Erzeugt am Ende eine M3U-Playlist")
    
    args = parser.parse_args()
    setup_logging()
    
    # Validierung
    args.workers = max(1, args.workers)

    feed_urls = []
    config_provided = args.config is not None
    config_file = args.config if args.config else "config.json"
    
    if Path(config_file).exists():
        logging.info(f"Lade Konfiguration aus: {config_file}")
        with open(config_file, 'r', encoding='utf-8') as f:
            cfg = json.load(f)
            if "url" in cfg: feed_urls.append(cfg["url"])
            if "urls" in cfg: feed_urls.extend(cfg["urls"])
            if "output" in cfg and args.output == DEFAULT_DOWNLOAD_FOLDER: args.output = cfg["output"]
            
            if "limit" in cfg and args.limit == DEFAULT_LIMIT: args.limit = cfg["limit"]
            if "workers" in cfg and args.workers == DEFAULT_WORKERS: args.workers = max(1, cfg["workers"])
            if "retries" in cfg and args.retries == 3: args.retries = cfg["retries"]
            if "timeout" in cfg and args.timeout == DEFAULT_TIMEOUT: args.timeout = cfg["timeout"]
            if "m3u" in cfg and not args.m3u: args.m3u = cfg["m3u"]
            if "dry_run" in cfg and not args.dry_run: args.dry_run = cfg["dry_run"]
    elif config_provided:
        logging.warning(f"Angegebene Konfigurationsdatei nicht gefunden: {config_file}")
            
    if args.opml:
        feed_urls.extend(parse_opml(args.opml))
        
    if args.url:
        feed_urls.append(args.url)
        
    if not feed_urls:
        feed_urls.append(DEFAULT_RSS_URL)

    # Dubletten entfernen (Reihenfolge beibehalten)
    feed_urls = list(dict.fromkeys(feed_urls))
    
    headers = {
        'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36'
    }

    base_output_folder = Path(args.output)
    
    total_downloaded = 0
    total_skipped = 0
    total_failed = 0

    for feed_url in feed_urls:
        if ABORT_EVENT.is_set(): break
        
        try:
            feed_title, items = parse_feed(feed_url, headers, args.timeout)
        except Exception as e:
            logging.error(f"Überspringe Feed wegen Fehler: {e}")
            continue
            
        if args.limit > 0:
            items = items[:args.limit]
            
        # Generiere dynamischen Unterordner anhand des Podcast-Titels
        safe_feed_title = clean_filename(feed_title)
        feed_output_folder = base_output_folder / safe_feed_title
        
        if not args.dry_run:
            feed_output_folder.mkdir(parents=True, exist_ok=True)
            cleanup_old_parts(feed_output_folder)

        download_tasks = []
        for item in items:
            title, mp3_url, prefix = extract_episode_data(item)
            if not mp3_url:
                continue
                
            safe_title = clean_filename(title)
            ext = Path(urlparse(mp3_url).path).suffix or ".mp3"
            
            # Nutze den modifizierten Unterordner
            file_path = feed_output_folder / f"{prefix}{safe_title}{ext}"
            part_path = file_path.with_suffix(ext + ".part")
            
            if file_path.exists():
                logging.debug(f"Überspringe: {file_path.name}")
                total_skipped += 1
            else:
                download_tasks.append((mp3_url, file_path, part_path))

        if args.dry_run:
            for _, fpath, _ in download_tasks:
                logging.info(f"DRY-RUN: Würde laden: {fpath.name}")
            continue

        if download_tasks:
            logging.info(f"Starte Download von {len(download_tasks)} Episoden (Workers: {args.workers})...")
            
            pm = ProgressManager(len(download_tasks))
            pm._render()
            
            executor = ThreadPoolExecutor(max_workers=args.workers)
            try:
                futures = {
                    executor.submit(
                        download_episode, url, fpath, ppath, headers, args.retries, args.timeout, pm
                    ): fpath.name for url, fpath, ppath in download_tasks
                }

                for future in as_completed(futures):
                    fname = futures[future]
                    try:
                        success = future.result()
                        if success:
                            total_downloaded += 1
                        else:
                            total_failed += 1
                    except Exception as e:
                        if not ABORT_EVENT.is_set():
                            pm.log_error(f"Unerwarteter Fehler bei {fname}: {e}")
                        total_failed += 1
                        success = False
                    finally:
                        pm.complete(fname, success)
            
            except KeyboardInterrupt:
                ABORT_EVENT.set()
                pm.log_warning("Abbruch durch Benutzer. Stoppe Warteschlange und aktive Downloads...")
                executor.shutdown(wait=False, cancel_futures=True)
                sys.exit(0)
            finally:
                if not ABORT_EVENT.is_set():
                    executor.shutdown(wait=True)

        # Generiere die M3U nun PRO FEED direkt im jeweiligen Unterordner
        if args.m3u and not args.dry_run and not ABORT_EVENT.is_set():
            generate_m3u(feed_output_folder, feed_title)

    if not ABORT_EVENT.is_set():
        logging.info("=" * 50)
        logging.info("SYNCHRONISATION ABGESCHLOSSEN")
        logging.info(f"✅ Heruntergeladen: {total_downloaded}")
        logging.info(f"⏭️ Übersprungen:   {total_skipped}")
        if total_failed > 0:
            logging.warning(f"❌ Fehlgeschlagen:  {total_failed}")
        logging.info("=" * 50)

if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        ABORT_EVENT.set()
        print("\n\033[93mAbbruch durch Benutzer.\033[0m")
        sys.exit(0)
