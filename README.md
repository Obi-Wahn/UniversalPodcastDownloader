# **Universal Podcast Downloader**

Dieses Repository enthält zwei native, hochrobuste Kommandozeilen-Werkzeuge (PowerShell und Python) zur automatisierten Synchronisation und Archivierung von Podcast-Episoden aus RSS- oder Atom-Feeds.  
Das Projekt ist darauf ausgelegt, große Audiodateien zuverlässig herunterzuladen, Netzwerkabbrüche abzufangen und Dateisystemfehler bei der Benennung proaktiv zu verhindern. Beide Skripte arbeiten vollständig mit den jeweiligen Bordmitteln des Betriebssystems und benötigen **keine externen Module oder Abhängigkeiten**.

* **PowerShell (universal\_podcast\_downloader.ps1):** Optimiert für Windows-Umgebungen. Nutzt native .NET-Klassen für optimiertes Streaming und unterstützt Multithreading ab PowerShell 7\.  
* **Python (universal\_podcast\_downloader.py):** Optimiert für Linux und macOS. Vollständig typisiert und auf maximale Performance durch parallele Downloads (Multithreading) ausgelegt.

## **Kernfunktionen**

* **Automatische Ordnerstruktur:** Die Skripte parsen den Titel des Podcasts direkt aus dem Feed und erstellen für jedes Abonnement automatisch einen eigenen, aufgeräumten Unterordner im Zielverzeichnis.  
* **GUID-basiertes Dedup-Manifest:** Pro Feed-Unterordner wird eine `.downloaded.json` gepflegt, die Episoden anhand ihrer Feed-GUID (RSS `<guid>` / Atom `<id>`) als bereits geladen markiert. Ändert sich später nur der Episodentitel, wird sie dank Manifest trotzdem korrekt übersprungen statt erneut heruntergeladen.  
* **Content-Type-Prüfung:** Antwortet ein Server statt der erwarteten Audiodatei mit einer HTML-/JSON-/XML-Fehlerseite (z. B. bei einem toten Link), wird der Download sofort abgebrochen, statt die Fehlerseite als Episode zu speichern.  
* **Respektiert `Retry-After` bei Rate-Limits:** Antwortet ein Server mit HTTP 429, warten die Skripte die vom Server über den `Retry-After`-Header vorgegebene Zeit (Sekunden oder HTTP-Datum, gedeckelt auf 5 Minuten), statt blind den Standard-Backoff zu nutzen.  
* **Parallele Downloads (Multithreading):** Steigern Sie die Download-Geschwindigkeit massiv, indem Sie mehrere Episoden gleichzeitig herunterladen.  
* **OPML-Import & JSON-Konfiguration (Auto-Detect):** Übernehmen Sie Ihre Podcasts aus Apple Podcasts, AntennaPod o.ä. mittels OPML-Datei, oder verwalten Sie Ihre Abonnements zentral über eine config.json. Liegt die Datei im Skript-Verzeichnis, wird sie vollautomatisch erkannt.  
* **Echtes Download-Resume:** Bricht die Netzwerkverbindung ab, fangen die Skripte dank Range-Headern nicht von vorne an, sondern setzen den Download bytegenau an der Abbruchstelle fort.  
* **Speicherschonendes Chunking & "In-Flight" Limit-Schutz:** Dateien werden in 1-MB-Blöcken verarbeitet. Der Arbeitsspeicher (RAM) wird selbst bei riesigen Dateien nicht überlastet. Ein integrierter Schutz bricht Downloads über 1 GB ab – selbst dann, wenn der Host-Server vorab keine Dateigröße übermittelt hat.  
* **Retry-Logik mit gedeckeltem Backoff:** Bei Timeouts probieren die Skripte es automatisch erneut und verdoppeln dabei schonend die Wartezeit (2s, 4s, 8s...). Um Deadlocks zu vermeiden, ist die Wartezeit bei einem sicheren Maximum von 60 Sekunden gedeckelt.  
* **Absolute Dateisystem-Sicherheit:** Bereinigung von Sonderzeichen und unsichtbaren Steuerzeichen, Entfernung von Leerzeichen am Dateiende, Begrenzung auf 150 Zeichen (Schutz vor MAX\_PATH-Fehlern) und Abfangen von reservierten Windows-Systemnamen (wie CON oder PRN).  
* **Graceful Shutdown:** Wird das Skript durch den Nutzer abgebrochen (Strg+C), werden aktive Netzwerkverbindungen sauber geschlossen und temporäre Dateien für den späteren Resume-Vorgang gesichert.  
* **Fortschrittsanzeige & Logging:** Live-Fortschrittsbalken im Terminal (inklusive Downloadgeschwindigkeit in MB/s und ETA-Berechnung) sowie strukturierte Status- und Fehlermeldungen mit Zeitstempel.  
* **M3U-Playlisten:** Erzeugen Sie nach dem Download automatisch eine sauber benannte .m3u-Playlist (z.B. PodcastTitel\_Playlist.m3u) direkt im Unterordner des jeweiligen Feeds.  
* **Dry-Run Modus:** Testen Sie das Parsing und die Namensgenerierung des Feeds risikolos, ohne Daten herunterzuladen.  
* **Aussagekräftiger Exit-Code:** Für den unbeaufsichtigten Betrieb (Cron, Task Scheduler) beenden sich beide Skripte mit Exit-Code `1`, sobald mindestens eine Episode endgültig fehlgeschlagen ist – so lassen sich Fehler automatisiert erkennen.

## **Konfigurationsmöglichkeiten**

Sie können das Zielverzeichnis und die Feed-URLs auf drei Arten definieren:

> 1. **Kommandozeile (CLI):** Übergabe der Parameter beim Aufruf (siehe Tabellen unten). Manuell übergebene CLI-Werte haben dabei immer Vorrang. Ist in der `config.json` ein `output`-Pfad angegeben, wird dieser verwendet; ist weder `-o`/`-Output` noch `output` in der Config gesetzt, legen die Skripte automatisch einen Ordner `Podcasts` direkt im Skriptordner an.  
> 2. **config.json:** Eine JSON-Datei, die *alle* verfügbaren Parameter (Limit, Workers, Retries etc.) zentral abbilden kann. Fehlt eine manuell angegebene Config-Datei, warnt das Skript nun zuverlässig. Eine datenschutzfreundliche config.example.json liegt dem Projekt bei.  
> 3. **OPML-Datei:** Eine von Podcatchern exportierte XML-Datei, aus der das Skript alle Feed-URLs extrahiert und nacheinander abarbeitet.

## **🐍 Nutzung der Python-Variante (Linux / macOS)**

**Voraussetzung:** Python 3.6 oder neuer (Standard auf den meisten unixoiden Systemen).

### **CLI-Parameter (Python)**

| Parameter | Kurz | Beschreibung | Standardwert |
| :---- | :---- | :---- | :---- |
| \--url | \-u | Die URL des RSS/Atom-Feeds. | *Beispiel-URL* |
| \--config | \-c | Pfad zu einer config.json. | \- |
| \--opml |  | Pfad zu einer OPML-Datei (für Massen-Downloads). | \- |
| \--output | \-o | Absoluter Pfad zum Basis-Zielverzeichnis. | ./Podcasts (im Skriptordner) |
| \--limit | \-l | Lädt nur die neuesten N Episoden (0 \= alle). | 0 |
| \--retries |  | Maximale Anzahl der Fehler-Wiederholungen. | 3 |
| \--timeout | \-t | Netzwerk-Timeout in Sekunden. | 60 |
| \--workers | \-w | Anzahl der parallelen Download-Threads. | 1 |
| \--m3u |  | Erzeugt nach dem Download eine M3U-Playlist. | False |
| \--dry-run |  | Simuliert den Vorgang, ohne herunterzuladen. | False |
| \--help | \-h | Zeigt die integrierte Hilfeseite an. | \- |

**Beispiele:**

Bash  
\# Gesamtes Archiv aus einer OPML-Datei laden, 5 Downloads parallel  
python3 universal\_podcast\_downloader.py \--opml "abos.opml" \-w 5

\# Nur die neuesten 3 Folgen laden und M3U-Playlist erstellen  
python3 universal\_podcast\_downloader.py \-u "https://beispiel.de/feed.rss" \-l 3 \--m3u

\# Risikofreier Trockenlauf zur Ansicht der Namensgenerierung  
python3 universal\_podcast\_downloader.py \--dry-run

## **🪟 Nutzung der PowerShell-Variante (Windows)**

**Voraussetzung:** Windows PowerShell 5.1 oder neuer. Multithreading (-Workers) erfordert **PowerShell 7+**.  
*Hinweis: Möglicherweise müssen Sie die Skriptausführung einmalig erlauben (Set-ExecutionPolicy \-Scope CurrentUser \-ExecutionPolicy RemoteSigned).*

### **CLI-Parameter (PowerShell)**

| Parameter | Beschreibung | Standardwert (Default) |
| :---- | :---- | :---- |
| \-Url | Die URL des RSS/Atom-Feeds. | *Beispiel-URL* |
| \-Config | Pfad zu einer config.json. | \- |
| \-Opml | Pfad zu einer OPML-Datei (für Massen-Downloads). | \- |
| \-Output | Absoluter Pfad zum Basis-Zielverzeichnis. | .\\Podcasts (im Skriptordner) |
| \-Limit | Lädt nur die neuesten N Episoden (0 \= alle). | 0 |
| \-Retries | Maximale Anzahl der Fehler-Wiederholungen. | 3 |
| \-TimeoutSec | Netzwerk-Timeout in Sekunden. | 60 |
| \-Workers | Anzahl der parallelen Download-Threads (nur PS 7+). | 1 |
| \-M3u | Erzeugt nach dem Download eine M3U-Playlist. | $false |
| \-DryRun | Simuliert den Vorgang, ohne herunterzuladen. | $false |

**Beispiele:**

PowerShell  
\# Standard-Download mit 3 parallelen Threads (PS 7+)  
.\\universal\_podcast\_downloader.ps1 \-Workers 3

\# Spezifischen Podcast in ein neues Laufwerk laden und Playlist generieren  
.\\universal\_podcast\_downloader.ps1 \-Url "https://beispiel.de/feed.rss" \-Output "D:\\Podcast-Archiv" \-M3u

\# Konfiguration über eine JSON-Datei steuern  
.\\universal\_podcast\_downloader.ps1 \-Config "C:\\pfad\\zu\\meinen\_podcasts.json"

## **Lizenz und Datenschutz**

Dieses Projekt ist Open Source und steht unter der MIT-Lizenz. Die Modifikation, Nutzung und Weiterverbreitung ist uneingeschränkt gestattet. Die Skripte arbeiten streng datenschutzfreundlich: Sie enthalten keinerlei Telemetrie und übermitteln lediglich einen generischen Browser-User-Agent, um 403-Blockaden durch Content Delivery Networks (CDNs) zu umgehen.
