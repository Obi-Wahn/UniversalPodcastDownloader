# **Universal Podcast Downloader**

Ein Repository zur automatisierten Synchronisation von Podcast-Episoden aus RSS- oder Atom-Feeds. Das Projekt bietet zwei native Lösungen, die jeweils die spezifischen Stärken des Betriebssystems nutzen:

1. **PowerShell-Skript (generic\_podcast\_downloader.ps1):** Optimiert für Windows-Umgebungen.  
2. **Python-Skript (generic\_podcast\_downloader.py):** Optimiert für Linux (z. B. Fedora) und macOS.

Beide Skripte sind hochgradig robust, nutzen keine externen Abhängigkeiten und folgen aktuellen Best-Practices für inkrementelle Downloads.

## **Funktionsumfang**

* **Plattform-Native Lösungen:** Wählen Sie das Skript, das optimal zu Ihrem Betriebssystem passt.  
* **Inkrementelle Synchronisation:** Existierende Dateien werden erkannt und übersprungen.  
* **Sichere Dateinamen:** Automatische Bereinigung ungültiger Zeichen und Schutz vor Windows-reservierten Dateinamen (CON, NUL, etc.).  
* **Intelligente Nummerierung:** Extrahiert Folgennummern aus \<itunes:episode\>-Tags. Fehlen diese, dient das Veröffentlichungsdatum (pubDate) als Fallback für die Sortierung.  
* **Robustes Parsing:** XPath-basiertes Auslesen der XML-Struktur unterstützt sowohl RSS als auch Atom-Feeds und ignoriert Namespace-Probleme.  
* **Streaming-Download:** Beide Skripte laden Dateien direkt auf die Festplatte (statt in den RAM) und nutzen .part-Dateien zur Vermeidung von korrupten Downloads bei Verbindungsabbrüchen.

## **Voraussetzungen**

### **PowerShell (Windows)**

* Standardmäßig auf Windows vorinstalliert.  
* Sofern die Ausführung von Skripten blockiert ist, einmalig in der PowerShell ausführen:  
  Set-ExecutionPolicy \-Scope CurrentUser \-ExecutionPolicy RemoteSigned

### **Python (Linux / macOS)**

* Python 3 ist auf den meisten Distributionen (wie Fedora) vorinstalliert.  
* Es sind keine pip-Installationen erforderlich; das Skript nutzt ausschließlich die Standardbibliothek.

## **Verwendung**

### **Konfiguration**

Öffnen Sie das gewünschte Skript (.ps1 oder .py) in einem Editor und passen Sie die Variablen am Anfang der Datei an:

* $rssUrl / rss\_url: Die URL Ihres Podcast-Feeds.  
* $downloadFolder / download\_folder: Ihr lokaler Zielpfad.

### **Ausführung**

**Unter Windows (PowerShell):**

.\\generic\_podcast\_downloader.ps1

**Unter Linux / macOS (Python):**

python3 generic\_podcast\_downloader.py

## **Lizenz**

Dieses Projekt ist Open Source. Die freie Verwendung, Modifikation und Weiterverbreitung ist gestattet.
