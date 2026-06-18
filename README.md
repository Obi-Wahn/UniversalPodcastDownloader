# **Universal Podcast Downloader**

Dieses Repository enthält zwei native, robuste Skripte (PowerShell und Python) zur automatisierten Synchronisation und Archivierung von Podcast-Episoden aus RSS- oder Atom-Feeds. Das Projekt ist darauf ausgelegt, große Audiodateien zuverlässig herunterzuladen und Dateisystemfehler bei der Benennung proaktiv zu verhindern.

Das Repository bietet für jede Systemumgebung das passende Werkzeug, welches vollständig mit Bordmitteln arbeitet und **keine externen Module oder Abhängigkeiten** (wie pip install) benötigt.

* **PowerShell (universal\_podcast\_downloader.ps1):** Optimiert für Windows-Umgebungen.  
* **Python (universal\_podcast\_downloader.py):** Optimiert für Linux (z. B. Fedora) und macOS.

## **Funktionsumfang beider Versionen**

* **Inkrementelle Synchronisation:** Die Skripte gleichen den Feed mit dem lokalen Zielverzeichnis ab und laden ausschließlich fehlende Episoden herunter.  
* **Ausfallsicherheit & Retry-Logik:** Um Verbindungsabbrüchen oder Server-Timeouts (insbesondere bei großen Sonderfolgen) vorzubeugen, ist ein 60-Sekunden-Timeout integriert. Bei Fehlern greift eine automatische Wiederholungsschleife (bis zu 3 Versuche).  
* **Transaktionssichere Downloads:** Während des Ladevorgangs werden temporäre .part-Dateien genutzt. Dies verhindert, dass unvollständige Downloads bei einem Netzwerkabbruch als fertige MP3-Dateien erkannt werden.  
* **Intelligente Nummerierung:** Die Folgennummer wird bevorzugt aus \<itunes:episode\>-Tags extrahiert. Sollten diese fehlen, nutzen die Skripte das Veröffentlichungsdatum (pubDate bzw. updated) als Sortierkriterium.  
* **Robustes XML-Parsing:** Die Datenextraktion erfolgt über Namespace-unabhängige XPath-Abfragen. Dadurch werden sowohl klassische RSS-Feeds als auch moderne Atom-Feeds fehlerfrei verarbeitet.  
* **Dateisystem-Sicherheit:** Ungültige Sonderzeichen und für Windows reservierte Dateinamen (wie CON, PRN, AUX) werden betriebssystemübergreifend bereinigt. Zudem wird die Länge der Dateinamen auf 150 Zeichen begrenzt, um Limitierungen des Dateisystems (z. B. MAX\_PATH) zu umgehen.

## **Systemvoraussetzungen**

### **Für Windows (PowerShell-Version)**

* Windows Betriebssystem mit Windows PowerShell 5.1 oder neuer (auch kompatibel mit PowerShell Core).  
* Ggf. muss die Ausführung von Skripten auf dem System einmalig gestattet werden:  
  Set-ExecutionPolicy \-Scope CurrentUser \-ExecutionPolicy RemoteSigned

### **Für Linux / macOS (Python-Version)**

* Python 3.x (auf den meisten unixoiden Systemen wie Fedora oder Ubuntu bereits vorinstalliert).  
* Es werden ausschließlich Standardbibliotheken verwendet.

## **Einrichtung und Verwendung**

1. Laden Sie das für Ihr System passende Skript herunter.  
2. Öffnen Sie das Skript in einem Texteditor Ihrer Wahl und passen Sie die Konfiguration im oberen Bereich an:  
   * **Feed-URL:** Fügen Sie die URL des gewünschten Podcast-Feeds ein ($rssUrl bzw. rss\_url).  
   * **Zielverzeichnis:** Geben Sie den absoluten Pfad zu Ihrem lokalen Archiv an ($downloadFolder bzw. download\_folder).  
3. Führen Sie das Skript aus:  
   **Unter Windows (PowerShell):**  
   Rechtsklick auf die Datei \-\> "Mit PowerShell ausführen" oder im Terminal:  
   .\\universal\_podcast\_downloader.ps1

   **Unter Linux / macOS (Python):**  
   Führen Sie das Skript im Terminal aus:  
   python3 universal\_podcast\_downloader.py

## **Lizenz**

Dieses Projekt ist Open Source. Die Modifikation, Nutzung und Weiterverbreitung für private Zwecke ist uneingeschränkt gestattet.
