# **Universal Podcast Downloader (PowerShell & Python)**

Ein Projekt zum automatisierten Herunterladen und Archivieren von Podcasts aus RSS-Feeds. Dieses Repository bietet zwei gleichwertige, native Lösungen ohne externe Abhängigkeiten: Ein PowerShell-Skript (ideal für Windows) und ein Python-Skript (ideal für Linux und macOS).

Beide Skripte analysieren die XML-Struktur des angegebenen Feeds, validieren die Dateinamen, implementieren eine automatische Nummerierung der Episoden zur alphabetischen Sortierung und führen inkrementelle Downloads durch.

## **Funktionsumfang**

* **Native Lösungen:** Nutzen Sie generic\_podcast\_downloader.ps1 unter Windows oder generic\_podcast\_downloader.py unter unixoiden Systemen.  
* **Keine externen Abhängigkeiten:** Die Skripte nutzen ausschließlich integrierte Standardbibliotheken der jeweiligen Sprache.  
* **Inkrementeller Download:** Überprüft das Zielverzeichnis und lädt ausschließlich fehlende Episoden herunter. Dies reduziert die Bandbreiten- und Speichernutzung.  
* **Automatische Nummerierung:** Extrahiert die \<itunes:episode\>-Tags zur Bestimmung der Folgennummer. Sollten diese Tags fehlen, wird die Episodennummer automatisch auf Basis der Gesamtanzahl berechnet.  
* **HTTP-Header-Anpassung:** Verwendet einen Standard-Browser-User-Agent für die HTTP-Anfragen, um etwaige Blockaden (z. B. "403 Forbidden") durch Podcast-Hoster zu vermeiden.  
* **Fehlertoleranz:** Verarbeitet unkonventionelle XML-Strukturen und bereinigt für das Dateisystem ungültige Zeichen automatisch.

## **Voraussetzungen**

### **Für Windows (PowerShell-Version)**

Auf aktuellen Windows-Systemen ist PowerShell bereits vorinstalliert.

*Hinweis:* Sofern die Ausführung von Skripten auf dem System standardmäßig deaktiviert ist, muss die Ausführungsrichtlinie in einer administrativen PowerShell einmalig angepasst werden:

Set-ExecutionPolicy \-Scope CurrentUser \-ExecutionPolicy RemoteSigned

### **Für Linux / macOS (Python-Version)**

Stellen Sie sicher, dass **Python 3** installiert ist. Auf den meisten Linux-Distributionen (z. B. Fedora, Ubuntu) sowie macOS ist dies ab Werk der Fall.

## **Verwendung**

### **Variante A: PowerShell (Windows)**

1. Öffnen Sie generic\_podcast\_downloader.ps1 in einem Texteditor und konfigurieren Sie die URL sowie den Download-Pfad im oberen Bereich:  
   $rssUrl \= "\[https://DEINE-PODCAST-URL.de/feed.rss\](https://DEINE-PODCAST-URL.de/feed.rss)"  
   $downloadFolder \= Join-Path \-Path $HOME \-ChildPath "Podcasts\\MeinLieblingsPodcast"

2. Führen Sie das Skript via Rechtsklick \-\> "Mit PowerShell ausführen" oder im Terminal aus:  
   .\\generic\_podcast\_downloader.ps1

### **Variante B: Python (Linux / macOS)**

1. Öffnen Sie generic\_podcast\_downloader.py in einem Texteditor und konfigurieren Sie die URL sowie den Download-Pfad im oberen Bereich:  
   rss\_url \= "\[https://DEINE-PODCAST-URL.de/feed.rss\](https://DEINE-PODCAST-URL.de/feed.rss)"  
   download\_folder \= Path.home() / "Podcasts" / "MeinLieblingsPodcast"

2. Führen Sie das Skript in Ihrem Terminal aus:  
   python3 generic\_podcast\_downloader.py

## **Lizenz**

Dieses Projekt ist Open Source. Die freie Verwendung, Modifikation und Weiterverbreitung ist gestattet.
