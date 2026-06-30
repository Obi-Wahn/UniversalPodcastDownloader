# **Universal Podcast Downloader**

Dieses Repository enthält zwei native, hochrobuste Kommandozeilen-Werkzeuge (PowerShell und Python) zur automatisierten Synchronisation und Archivierung von Podcast-Episoden aus RSS- oder Atom-Feeds.

Das Projekt ist darauf ausgelegt, große Audiodateien zuverlässig herunterzuladen, Netzwerkabbrüche abzufangen und Dateisystemfehler bei der Benennung proaktiv zu verhindern. Beide Skripte arbeiten vollständig mit den jeweiligen Bordmitteln des Betriebssystems und benötigen **keine externen Module oder Abhängigkeiten**.

* **PowerShell (universal\_podcast\_downloader.ps1):** Optimiert für Windows-Umgebungen. Nutzt native .NET-Klassen für optimiertes Streaming und unterstützt Multithreading ab PowerShell 7\.  
* **Python (universal\_podcast\_downloader.py):** Optimiert für Linux und macOS. Vollständig typisiert und auf maximale Performance durch asynchrone Aufgabenverteilung ausgelegt.

## **Kernfunktionen**

* **Parallele Downloads (Multithreading):** Steigern Sie die Download-Geschwindigkeit massiv, indem Sie mehrere Episoden gleichzeitig herunterladen.  
* **OPML-Import & JSON-Konfiguration:** Übernehmen Sie Ihre Podcasts aus Apple Podcasts, AntennaPod o.ä. mittels OPML-Datei, oder verwalten Sie Ihre Abonnements zentral über eine config.json.  
* **Echtes Download-Resume:** Bricht die Netzwerkverbindung ab, fangen die Skripte dank Range-Headern nicht von vorne an, sondern setzen den Download bytegenau an der Abbruchstelle fort.  
* **Graceful Shutdown:** Wird das Skript durch den Nutzer abgebrochen (Strg+C), werden aktive Netzwerkverbindungen sauber geschlossen und temporäre Dateien für den späteren Resume-Vorgang gesichert.  
* **Speicherschonendes Chunking:** Dateien werden in 1-MB-Blöcken verarbeitet. Der Arbeitsspeicher (RAM) wird selbst bei riesigen Dateien nicht überlastet. Integrierter Schutz vor Dateien \> 1 GB.  
* **Fortschrittsanzeige & Logging:** Live-Fortschrittsbalken im Terminal (inklusive Downloadgeschwindigkeit in MB/s und ETA-Berechnung) sowie strukturierte Status- und Fehlermeldungen mit Zeitstempel.  
* **Retry-Logik mit Exponentiellem Backoff:** Bei Timeouts probieren die Skripte es automatisch erneut und verdoppeln dabei schonend die Wartezeit (2s, 4s, 8s...).  
* **Absolute Dateisystem-Sicherheit:** Bereinigung von Sonderzeichen, Begrenzung auf 150 Zeichen (Schutz vor MAX\_PATH-Fehlern) und Abfangen von reservierten Windows-Systemnamen (wie CON oder PRN).  
* **M3U-Playlisten:** Erzeugen Sie nach dem Download automatisch eine .m3u-Playlist für Ihren lokalen Mediaplayer.  
* **Dry-Run Modus:** Testen Sie das Parsing und die Namensgenerierung des Feeds risikolos, ohne Daten herunterzuladen.

## **Konfigurationsmöglichkeiten**

Sie können das Zielverzeichnis und die Feed-URLs auf drei Arten definieren:

1. **Automatisch (config.json):** Eine einfache JSON-Datei ({"url": "...", "output": "..."}). *Tipp:* Liegt eine Datei namens config.json im exakt selben Ordner wie das Skript, wird sie beim Start **vollautomatisch erkannt** und geladen. Es sind keine weiteren Befehlszeilenparameter nötig ("Convention over Configuration").  
2. **Kommandozeile (CLI):** Übergabe spezifischer Parameter beim Aufruf (siehe Tabellen unten). Überschreibt bei Bedarf die automatische Konfiguration.  
3. **OPML-Datei:** Eine von Podcatchern exportierte XML-Datei, aus der das Skript alle Feed-URLs extrahiert und nacheinander abarbeitet.

## **🐍 Nutzung der Python-Variante (Linux / macOS)**

**Voraussetzung:** Python 3.2 oder neuer (Standard auf den meisten unixoiden Systemen).

### **CLI-Parameter (Python)**

| Parameter | Kurz | Beschreibung | Standardwert |
| :---- | :---- | :---- | :---- |
| \--url | \-u | Die URL des RSS/Atom-Feeds. | *Beispiel-URL* |
| \--config | \-c | Pfad zu einer abweichenden config.json. | *Auto-Erkennung* |
| \--opml |  | Pfad zu einer OPML-Datei (für Massen-Downloads). | \- |
| \--output | \-o | Absoluter Pfad zum Zielverzeichnis. | \~/Podcasts/MeinPodcast |
| \--limit | \-l | Lädt nur die neuesten N Episoden (0 \= alle). | 0 |
| \--retries |  | Maximale Anzahl der Fehler-Wiederholungen. | 3 |
| \--timeout | \-t | Netzwerk-Timeout in Sekunden. | 60 |
| \--workers | \-w | Anzahl der parallelen Download-Threads. | 1 |
| \--m3u |  | Erzeugt nach dem Download eine M3U-Playlist. | False |
| \--dry-run |  | Simuliert den Vorgang, ohne herunterzuladen. | False |
| \--help | \-h | Zeigt die integrierte Hilfeseite an. | \- |

**Beispiele:**

\# Nutzt automatisch eine vorhandene config.json im selben Ordner  
python3 universal\_podcast\_downloader.py

\# Gesamtes Archiv aus einer OPML-Datei laden, 5 Downloads parallel  
python3 universal\_podcast\_downloader.py \--opml "abos.opml" \-w 5

\# Nur die neuesten 3 Folgen laden und M3U-Playlist erstellen  
python3 universal\_podcast\_downloader.py \-u "\[https://beispiel.de/feed.rss\](https://beispiel.de/feed.rss)" \-l 3 \--m3u

\# Risikofreier Trockenlauf zur Ansicht der Namensgenerierung  
python3 universal\_podcast\_downloader.py \--dry-run

## **🪟 Nutzung der PowerShell-Variante (Windows)**

**Voraussetzung:** Windows PowerShell 5.1 oder neuer. Multithreading (-Workers) erfordert **PowerShell 7+**. *Hinweis: Möglicherweise müssen Sie die Skriptausführung einmalig erlauben (Set-ExecutionPolicy \-Scope CurrentUser \-ExecutionPolicy RemoteSigned).*

### **CLI-Parameter (PowerShell)**

| Parameter | Beschreibung | Standardwert (Default) |
| :---- | :---- | :---- |
| \-Url | Die URL des RSS/Atom-Feeds. | *Beispiel-URL* |
| \-Config | Pfad zu einer abweichenden config.json. | *Auto-Erkennung* |
| \-Opml | Pfad zu einer OPML-Datei (für Massen-Downloads). | \- |
| \-Output | Absoluter Pfad zum Zielverzeichnis. | $HOME\\Podcasts\\MeinPodcast |
| \-Limit | Lädt nur die neuesten N Episoden (0 \= alle). | 0 |
| \-Retries | Maximale Anzahl der Fehler-Wiederholungen. | 3 |
| \-TimeoutSec | Netzwerk-Timeout in Sekunden. | 60 |
| \-Workers | Anzahl der parallelen Download-Threads (nur PS 7+). | 1 |
| \-M3u | Erzeugt nach dem Download eine M3U-Playlist. | $false |
| \-DryRun | Simuliert den Vorgang, ohne herunterzuladen. | $false |

**Beispiele:**

\# Nutzt automatisch eine vorhandene config.json im selben Ordner  
.\\universal\_podcast\_downloader.ps1

\# Standard-Download mit 3 parallelen Threads (PS 7+)  
.\\universal\_podcast\_downloader.ps1 \-Workers 3

\# Spezifischen Podcast in ein neues Laufwerk laden und Playlist generieren  
.\\universal\_podcast\_downloader.ps1 \-Url "\[https://beispiel.de/feed.rss\](https://beispiel.de/feed.rss)" \-Output "D:\\Podcast-Archiv" \-M3u

\# Konfiguration über eine abweichende JSON-Datei steuern  
.\\universal\_podcast\_downloader.ps1 \-Config "C:\\pfad\\zu\\meinen\_podcasts.json"

## **Entstehung, Lizenz und Datenschutz**

Dieses Projekt ist Open Source und steht unter der [MIT-Lizenz](https://opensource.org/license/mit). Die Skripte arbeiten streng datenschutzfreundlich: Sie enthalten keinerlei Telemetrie und übermitteln lediglich einen generischen Browser-User-Agent, um 403-Blockaden durch Content Delivery Networks (CDNs) zu umgehen.

**Hinweis zur Entstehung:** Die Skripte und die dazugehörige Dokumentation in diesem Projekt wurden mithilfe von Künstlicher Intelligenz (KI) konzipiert, entwickelt und optimiert.
