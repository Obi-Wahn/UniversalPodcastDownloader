# **Universal Podcast Downloader**

Dieses Repository enthält zwei native, robuste Kommandozeilen-Werkzeuge (PowerShell und Python) zur automatisierten Synchronisation und Archivierung von Podcast-Episoden aus RSS- oder Atom-Feeds.

Das Projekt ist darauf ausgelegt, große Audiodateien zuverlässig herunterzuladen, Netzwerkabbrüche abzufangen und Dateisystemfehler bei der Benennung proaktiv zu verhindern. Beide Skripte arbeiten vollständig mit Bordmitteln und benötigen **keine externen Module oder Abhängigkeiten**.

* **PowerShell (universal\_podcast\_downloader.ps1):** Optimiert für Windows-Umgebungen (nutzt tiefgreifende .NET-Klassen für optimiertes Streaming).  
* **Python (universal\_podcast\_downloader.py):** Optimiert für Linux (z. B. Fedora) und macOS.

## **Kernfunktionen**

* **Echtes Download-Resume:** Bricht die Netzwerkverbindung ab, fangen die Skripte dank Range-Headern nicht von vorne an, sondern setzen den Download bytegenau an der Abbruchstelle fort.  
* **Speicherschonendes Chunking:** Dateien werden in 1-MB-Blöcken verarbeitet. Der Arbeitsspeicher (RAM) läuft auch bei riesigen Sonderfolgen nicht über.  
* **Fortschrittsanzeige & Logging:** Live-Fortschrittsbalken im Terminal sowie strukturierte Status- und Fehlermeldungen mit Zeitstempel.  
* **Retry-Logik mit Exponentiellem Backoff:** Bei Timeouts probieren die Skripte es automatisch erneut und verdoppeln dabei schonend die Wartezeit (2s, 4s, 8s...).  
* **Dynamische Meta-Auswertung:** Intelligentes Auslesen von \<itunes:episode\> für die Nummerierung oder Fallback auf das Veröffentlichungsdatum. Die Dateiendung (.mp3, .m4a, etc.) wird dynamisch aus der URL abgeleitet.  
* **Absolute Dateisystem-Sicherheit:** Bereinigung von Sonderzeichen, Begrenzung auf 150 Zeichen (Schutz vor MAX\_PATH-Fehlern) und Abfangen von reservierten Windows-Systemnamen (wie CON oder PRN).

## **Konfiguration**

Sie können die Standardwerte (Default-Werte) für Ihre Lieblings-Podcasts direkt im oberen Bereich der Skripte (BENUTZER-EINSTELLUNGEN) anpassen. Wenn Sie die Skripte dann ohne weitere Parameter starten, werden diese Standardwerte verwendet.

Alternativ lassen sich die Skripte für maximale Flexibilität über **Kommandozeilenparameter (CLI)** steuern.

## **🐍 Nutzung der Python-Variante (Linux / macOS)**

**Voraussetzung:** Python 3.x (Standard auf den meisten unixoiden Systemen).

### **CLI-Parameter (Python)**

| Parameter | Kurz | Beschreibung | Standardwert (Default) |
| :---- | :---- | :---- | :---- |
| \--url | \-u | Die URL des RSS/Atom-Feeds. | *siehe Skript-Header* |
| \--output | \-o | Absoluter Pfad zum Zielverzeichnis. | \~/Podcasts/MeinPodcast |
| \--limit | \-l | Lädt nur die neuesten N Episoden (0 \= alle). | 0 |
| \--retries |  | Maximale Anzahl der Fehler-Wiederholungen. | 3 |
| \--help | \-h | Zeigt die integrierte Hilfeseite an. | \- |

**Beispiele:**

\# Standard-Download mit den Werten aus dem Skript-Header  
python3 universal\_podcast\_downloader.py

\# Nur die neuesten 5 Folgen eines spezifischen Feeds laden  
python3 universal\_podcast\_downloader.py \-u "\[https://beispiel.de/feed.rss\](https://beispiel.de/feed.rss)" \-l 5

\# Download in ein anderes Verzeichnis mit 5 Wiederholungsversuchen  
python3 universal\_podcast\_downloader.py \-o "/home/nutzer/Archiv" \--retries 5

## **🪟 Nutzung der PowerShell-Variante (Windows)**

**Voraussetzung:** Windows PowerShell 5.1 oder neuer (auch PowerShell Core 7+ kompatibel).

*Hinweis: Möglicherweise müssen Sie die Skriptausführung einmalig erlauben (Set-ExecutionPolicy \-Scope CurrentUser \-ExecutionPolicy RemoteSigned).*

### **CLI-Parameter (PowerShell)**

| Parameter | Beschreibung | Standardwert (Default) |
| :---- | :---- | :---- |
| \-Url | Die URL des RSS/Atom-Feeds. | *siehe Skript-Header* |
| \-Output | Absoluter Pfad zum Zielverzeichnis. | $HOME\\Podcasts\\MeinPodcast |
| \-Limit | Lädt nur die neuesten N Episoden (0 \= alle). | 0 |
| \-Retries | Maximale Anzahl der Fehler-Wiederholungen. | 3 |

**Beispiele:**

\# Standard-Download per Konsole  
.\\universal\_podcast\_downloader.ps1

\# Spezifischen Podcast in ein neues Laufwerk laden  
.\\universal\_podcast\_downloader.ps1 \-Url "\[https://beispiel.de/feed.rss\](https://beispiel.de/feed.rss)" \-Output "D:\\Podcast-Archiv"

\# Nur die neueste Folge abrufen (Limit 1\)  
.\\universal\_podcast\_downloader.ps1 \-Limit 1

## **Lizenz und Datenschutz**

Dieses Projekt ist Open Source. Die Modifikation, Nutzung und Weiterverbreitung für private Zwecke ist uneingeschränkt gestattet. Die Skripte arbeiten datenschutzfreundlich, enthalten keinerlei Telemetrie und übermitteln nur einen generischen Browser-User-Agent, um grundlegende CDN-Blockaden zu umgehen.
