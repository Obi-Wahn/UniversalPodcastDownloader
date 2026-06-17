# **Universal Podcast Downloader (PowerShell)**

Ein plattformübergreifendes PowerShell-Skript zum automatisierten Herunterladen und Archivieren von Podcasts aus RSS-Feeds.

Das Skript analysiert die XML-Struktur des angegebenen Feeds, validiert die Dateinamen, implementiert eine automatische Nummerierung der Episoden zur alphabetischen Sortierung und führt inkrementelle Downloads durch.

## **Funktionsumfang**

* **Plattformkompatibilität:** Unterstützt Windows (Windows PowerShell) und Linux (PowerShell Core / pwsh). Die Verzeichnispfade werden automatisch an das jeweilige Betriebssystem angepasst ($HOME).  
* **Inkrementeller Download:** Überprüft das Zielverzeichnis und lädt ausschließlich fehlende Episoden herunter. Dies reduziert die Bandbreiten- und Speichernutzung.  
* **Automatische Nummerierung:** Extrahiert die \<itunes:episode\>-Tags zur Bestimmung der Folgennummer. Sollten diese Tags fehlen, berechnet das Skript die Episodennummer automatisch auf Basis der Gesamtanzahl der Listeneinträge.  
* **HTTP-Header-Anpassung:** Verwendet einen Standard-Browser-User-Agent für die HTTP-Anfragen, um etwaige Blockaden (z. B. "403 Forbidden") durch Podcast-Hoster oder Content Delivery Networks zu vermeiden.  
* **Fehlertoleranz:** Verarbeitet unkonventionelle XML-Strukturen (z. B. mehrfach vorhandene Titel-Tags) und bereinigt für das Dateisystem ungültige Zeichen automatisch.

## **Voraussetzungen und Installation**

### **Windows**

Auf aktuellen Windows-Systemen ist PowerShell bereits vorinstalliert. Es ist keine zusätzliche Software erforderlich.

*Hinweis:* Sofern die Ausführung von Skripten auf dem System standardmäßig deaktiviert ist, muss die Ausführungsrichtlinie einmalig über eine administrative PowerShell-Sitzung oder für den aktuellen Benutzer angepasst werden:

Set-ExecutionPolicy \-Scope CurrentUser \-ExecutionPolicy RemoteSigned

### **Linux**

Unter Linux wird **PowerShell Core** (pwsh) vorausgesetzt.

Auf Ubuntu- und Debian-basierten Distributionen erfolgt die Installation über den Paketmanager:

sudo apt update  
sudo apt install powershell

*Für weitere Distributionen (z. B. Fedora, Arch Linux) wird auf die [offizielle Microsoft-Dokumentation](https://learn.microsoft.com/de-de/powershell/scripting/install/installing-powershell-on-linux) verwiesen.*

## **Verwendung**

1. Laden Sie die Datei generic\_podcast\_downloader.ps1 herunter.  
2. Öffnen Sie das Skript in einem Texteditor und konfigurieren Sie die Variablen für die Feed-URL und das Download-Verzeichnis im oberen Bereich der Datei:  
   $rssUrl \= "\[https://DEINE-PODCAST-URL.de/feed.rss\](https://DEINE-PODCAST-URL.de/feed.rss)"  
   $downloadFolder \= Join-Path \-Path $HOME \-ChildPath "Podcasts/MeinLieblingsPodcast"

3. Führen Sie das Skript aus:  
   * **Windows:** Rechtsklick auf die .ps1-Datei \-\> "Mit PowerShell ausführen" (oder Aufruf im Terminal via .\\generic\_podcast\_downloader.ps1).  
   * **Linux:** Aufruf im Terminal über den Befehl pwsh generic\_podcast\_downloader.ps1.

## **Lizenz**

Dieses Projekt ist Open Source. Die freie Verwendung, Modifikation und Weiterverbreitung ist gestattet.
