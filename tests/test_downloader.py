"""
Gemeinsame End-to-End-Tests für beide Implementierungen des Downloaders.

Jeder Test läuft gegen alle verfügbaren Implementierungen:
  - python      universal_podcast_downloader.py
  - pwsh        universal_podcast_downloader.ps1 unter PowerShell 7+
  - powershell  universal_podcast_downloader.ps1 unter Windows PowerShell 5.1 (nur Windows)

Nicht installierte Shells werden übersprungen, außer sie stehen in der
Umgebungsvariable REQUIRE_IMPLS (z.B. "python,pwsh,powershell" in der CI) -
dann schlägt der Test fehl, statt still übersprungen zu werden.

Die Feeds und Audiodateien liefert ein lokaler HTTP-Server, es wird nichts
aus dem Internet geladen.
"""
import json
import os
import re
import shutil
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parent.parent
PY_SCRIPT = REPO / "universal_podcast_downloader.py"
PS_SCRIPT = REPO / "universal_podcast_downloader.ps1"

IMPLS = ["python", "pwsh", "powershell"]
REQUIRED = {i.strip() for i in os.environ.get("REQUIRE_IMPLS", "").split(",") if i.strip()}

AUDIO = b"ID3" + bytes(4096)

PY_FLAGS = {"url": "--url", "output": "--output", "config": "--config", "retries": "--retries",
            "workers": "--workers", "flat": "--flat", "dry_run": "--dry-run", "m3u": "--m3u"}
PS_FLAGS = {"url": "-Url", "output": "-Output", "config": "-Config", "retries": "-Retries",
            "workers": "-Workers", "flat": "-Flat", "dry_run": "-DryRun", "m3u": "-M3u"}


# ------------------------------------------------------------------------------
# Lokaler Feed-Server
# ------------------------------------------------------------------------------
def ranged(data):
    """Antwortet wie ein Server mit Range-Unterstützung: 206 ab der gewünschten Stelle, 416 dahinter."""
    def respond(handler):
        match = re.match(r"bytes=(\d+)-", handler.headers.get("Range") or "")
        start = int(match[1]) if match else 0
        if match and start >= len(data):
            handler.send_response(416)
            handler.send_header("Content-Range", f"bytes */{len(data)}")
            handler.send_header("Content-Length", "0")
            handler.end_headers()
            return
        body = data[start:]
        handler.send_response(206 if match else 200)
        if match:
            handler.send_header("Content-Range", f"bytes {start}-{len(data) - 1}/{len(data)}")
        handler.send_header("Content-Type", "audio/mpeg")
        handler.send_header("Content-Length", str(len(body)))
        handler.end_headers()
        handler.wfile.write(body)
    return respond


def truncated(data, cut):
    """Kündigt die volle Länge an, bricht aber nach `cut` Bytes ab (wie ein Verbindungsabbruch)."""
    def respond(handler):
        handler.send_response(200)
        handler.send_header("Content-Type", "audio/mpeg")
        handler.send_header("Content-Length", str(len(data)))
        handler.end_headers()
        handler.wfile.write(data[:cut])
    return respond


class FeedServer:
    """Liefert pro Pfad eine Folge von Antworten; die letzte wiederholt sich.

    Eine Antwort ist entweder (Status, Header, Body) oder eine Funktion, die den Request selbst beantwortet.
    """

    def __init__(self):
        self.routes = {}
        self.hits = {}
        self.request_headers = {}
        server = self

        class Handler(BaseHTTPRequestHandler):
            def do_GET(self):
                server.hits.setdefault(self.path, []).append(time.monotonic())
                server.request_headers.setdefault(self.path, []).append(dict(self.headers))
                responses = server.routes.get(self.path)
                if not responses:
                    self.send_response(404)
                    self.send_header("Content-Length", "0")
                    self.end_headers()
                    return
                response = responses[min(len(server.hits[self.path]), len(responses)) - 1]
                if callable(response):
                    response(self)
                    return
                status, headers, body = response
                self.send_response(status)
                for key, value in headers.items():
                    if value is not None:
                        self.send_header(key, value)
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def log_message(self, *args):
                pass

        self.httpd = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        threading.Thread(target=self.httpd.serve_forever, daemon=True).start()

    def url(self, path):
        return f"http://127.0.0.1:{self.httpd.server_address[1]}{path}"

    def add(self, path, body, content_type="audio/mpeg", status=200, headers=None):
        self.routes[path] = [(status, {"Content-Type": content_type, **(headers or {})}, body)]

    def add_sequence(self, path, responses):
        self.routes[path] = responses

    def add_feed(self, path, title, episodes, content_type="application/rss+xml; charset=utf-8"):
        items = "".join(
            f"<item><title>{ep['title']}</title><guid>{ep['guid']}</guid>{ep.get('extra', '')}"
            f"<enclosure url=\"{self.url(ep['path'])}\" type=\"{ep.get('type', 'audio/mpeg')}\"/></item>"
            for ep in episodes
        )
        rss = f'<?xml version="1.0" encoding="UTF-8"?><rss version="2.0"><channel><title>{title}</title>{items}</channel></rss>'
        self.add(path, rss.encode("utf-8"), content_type=content_type)
        return self.url(path)


@pytest.fixture
def server():
    srv = FeedServer()
    yield srv
    srv.httpd.shutdown()


@pytest.fixture
def script_dir(tmp_path):
    """Kopie beider Skripte in einem eigenen Ordner (Skriptordner-Logik testbar, Repo bleibt sauber)."""
    target = tmp_path / "skriptordner"
    target.mkdir()
    shutil.copy(PY_SCRIPT, target)
    shutil.copy(PS_SCRIPT, target)
    return target


@pytest.fixture(params=IMPLS)
def impl(request):
    name = request.param
    if name == "python":
        available = True
    elif name == "powershell":
        # Windows PowerShell 5.1 gibt es nur unter Windows
        available = sys.platform == "win32" and shutil.which("powershell") is not None
    else:
        available = shutil.which(name) is not None
    if not available:
        if name in REQUIRED:
            pytest.fail(f"Implementierung '{name}' ist laut REQUIRE_IMPLS Pflicht, aber nicht installiert")
        pytest.skip(f"'{name}' ist nicht installiert")
    return name


def run(impl, script_dir, cwd, env=None, **opts):
    """Startet eine Implementierung und liefert (Exit-Code, kombinierte Ausgabe)."""
    if impl == "python":
        cmd = [sys.executable, str(script_dir / PY_SCRIPT.name)]
        flags = PY_FLAGS
    else:
        cmd = [shutil.which(impl), "-NoLogo", "-NoProfile", "-NonInteractive",
               "-ExecutionPolicy", "Bypass", "-File", str(script_dir / PS_SCRIPT.name)]
        flags = PS_FLAGS
    for key, value in opts.items():
        if value is True:
            cmd.append(flags[key])
        else:
            cmd += [flags[key], str(value)]

    full_env = {**os.environ, "NO_PROXY": "127.0.0.1,localhost", "no_proxy": "127.0.0.1,localhost", **(env or {})}
    proc = subprocess.run(cmd, cwd=cwd, env=full_env, capture_output=True, timeout=180)
    output = (proc.stdout + proc.stderr).decode("utf-8", errors="replace")
    return proc.returncode, output


def audio_files(folder):
    return sorted(p.name for p in Path(folder).rglob("*.mp3"))


# ------------------------------------------------------------------------------
# Tests
# ------------------------------------------------------------------------------
def test_download_creates_feed_folder_and_manifest(impl, server, script_dir, tmp_path):
    server.add("/ep1.mp3", AUDIO)
    feed = server.add_feed("/feed.xml", "Testcast", [{"title": "Folge 1", "guid": "g-1", "path": "/ep1.mp3"}])
    out = tmp_path / "out"

    code, output = run(impl, script_dir, tmp_path, url=feed, output=out, retries=1)

    assert code == 0, output
    episode = out / "Testcast" / "Folge 1.mp3"
    assert episode.read_bytes() == AUDIO
    manifest = json.loads((out / "Testcast" / ".downloaded.json").read_text(encoding="utf-8-sig"))
    assert manifest == {"g-1": "Folge 1.mp3"}


def test_flat_puts_episodes_directly_into_output(impl, server, script_dir, tmp_path):
    server.add("/ep1.mp3", AUDIO)
    feed = server.add_feed("/feed.xml", "Testcast", [{"title": "Folge 1", "guid": "g-1", "path": "/ep1.mp3"}])
    out = tmp_path / "out"

    code, output = run(impl, script_dir, tmp_path, url=feed, output=out, retries=1, flat=True)

    assert code == 0, output
    assert (out / "Folge 1.mp3").exists()
    assert not (out / "Testcast").exists()


def test_multiple_workers_download_everything(impl, server, script_dir, tmp_path):
    episodes = []
    for i in range(1, 4):
        server.add(f"/ep{i}.mp3", AUDIO)
        episodes.append({"title": f"Folge {i}", "guid": f"g-{i}", "path": f"/ep{i}.mp3"})
    feed = server.add_feed("/feed.xml", "Testcast", episodes)
    out = tmp_path / "out"

    code, output = run(impl, script_dir, tmp_path, url=feed, output=out, retries=1, workers=3)

    assert code == 0, output
    assert audio_files(out) == ["Folge 1.mp3", "Folge 2.mp3", "Folge 3.mp3"]
    manifest = json.loads((out / "Testcast" / ".downloaded.json").read_text(encoding="utf-8-sig"))
    assert set(manifest) == {"g-1", "g-2", "g-3"}


def test_guid_dedup_skips_episode_with_changed_title(impl, server, script_dir, tmp_path):
    server.add("/ep1.mp3", AUDIO)
    out = tmp_path / "out"
    feed = server.add_feed("/feed.xml", "Testcast", [{"title": "Folge 1", "guid": "g-1", "path": "/ep1.mp3"}])
    assert run(impl, script_dir, tmp_path, url=feed, output=out, retries=1)[0] == 0

    feed = server.add_feed("/feed.xml", "Testcast", [{"title": "Folge 1 (umbenannt)", "guid": "g-1", "path": "/ep1.mp3"}])
    code, output = run(impl, script_dir, tmp_path, url=feed, output=out, retries=1)

    assert code == 0, output
    assert audio_files(out) == ["Folge 1.mp3"]


def test_error_page_instead_of_audio_is_rejected(impl, server, script_dir, tmp_path):
    server.add("/tot.mp3", b"<html>404</html>", content_type="text/html")
    feed = server.add_feed("/feed.xml", "Testcast", [{"title": "Tot", "guid": "g-x", "path": "/tot.mp3"}])
    out = tmp_path / "out"

    code, output = run(impl, script_dir, tmp_path, url=feed, output=out, retries=1)

    assert code == 1, output
    assert audio_files(out) == []


def test_unreachable_feed_sets_exit_code(impl, server, script_dir, tmp_path):
    code, output = run(impl, script_dir, tmp_path, url=server.url("/gibt-es-nicht.xml"), output=tmp_path / "out", retries=1)

    assert code == 1, output
    assert "Feeds mit Fehler: 1" in output


def test_stale_own_part_file_is_restarted_but_foreign_files_are_kept(impl, server, script_dir, tmp_path):
    server.add("/ep1.mp3", AUDIO)
    feed = server.add_feed("/feed.xml", "Testcast", [{"title": "Folge 1", "guid": "g-1", "path": "/ep1.mp3"}])
    folder = tmp_path / "out" / "Testcast"
    (folder / "Unterordner").mkdir(parents=True)
    eight_days_ago = time.time() - 8 * 86400
    own_part = folder / "Folge 1.mp3.part"
    foreign = [folder / "browser-download.zip.part", folder / "Unterordner" / "fremd.mp3.part"]
    for part in [own_part, *foreign]:
        part.write_bytes(b"alt")
        os.utime(part, (eight_days_ago, eight_days_ago))

    code, output = run(impl, script_dir, tmp_path, url=feed, output=tmp_path / "out", retries=1)

    assert code == 0, output
    assert (folder / "Folge 1.mp3").read_bytes() == AUDIO
    # Kein "Range"-Header: die veraltete eigene .part-Datei wurde gelöscht statt fortgesetzt
    assert "Range" not in server.request_headers["/ep1.mp3"][0]
    for part in foreign:
        assert part.exists(), f"fremde Datei gelöscht: {part.name}"


def test_deleted_episode_is_downloaded_again(impl, server, script_dir, tmp_path):
    server.add("/ep1.mp3", AUDIO)
    feed = server.add_feed("/feed.xml", "Testcast", [{"title": "Folge 1", "guid": "g-1", "path": "/ep1.mp3"}])
    out = tmp_path / "out"
    assert run(impl, script_dir, tmp_path, url=feed, output=out, retries=1)[0] == 0
    episode = out / "Testcast" / "Folge 1.mp3"
    episode.unlink()

    code, output = run(impl, script_dir, tmp_path, url=feed, output=out, retries=1)

    assert code == 0, output
    assert episode.read_bytes() == AUDIO


def test_same_title_gets_unique_name_and_stays_stable(impl, server, script_dir, tmp_path):
    server.add("/a.mp3", b"ID3-A" + bytes(100))
    server.add("/b.mp3", b"ID3-B" + bytes(100))
    server.add("/c.mp3", b"ID3-C" + bytes(100))
    feed = server.add_feed("/feed.xml", "Testcast", [
        {"title": "Bonus", "guid": "g-a", "path": "/a.mp3"},
        {"title": "Bonus", "guid": "g-b", "path": "/b.mp3"},
        {"title": "Bonus", "guid": "g-a", "path": "/a.mp3"},  # doppelter Feed-Eintrag
        {"title": "...", "guid": "g-c", "path": "/c.mp3"},     # Titel ergibt keinen gültigen Namen
    ])
    out = tmp_path / "out"
    folder = out / "Testcast"

    code, output = run(impl, script_dir, tmp_path, url=feed, output=out, retries=1)

    assert code == 0, output
    assert audio_files(out) == ["Bonus (2).mp3", "Bonus.mp3", "Unbenannt.mp3"]
    assert (folder / "Bonus.mp3").read_bytes().startswith(b"ID3-A")
    assert (folder / "Bonus (2).mp3").read_bytes().startswith(b"ID3-B")

    # Zweiter Lauf: nichts Neues, Zuordnung bleibt stabil
    code, output = run(impl, script_dir, tmp_path, url=feed, output=out, retries=1)
    assert code == 0, output
    assert audio_files(out) == ["Bonus (2).mp3", "Bonus.mp3", "Unbenannt.mp3"]


def test_extension_from_feed_type_and_m3u_lists_all_media(impl, server, script_dir, tmp_path):
    server.add("/download?id=1", AUDIO, content_type="audio/mp4")  # URL ohne Dateiendung
    server.add("/ep2.mp3", AUDIO)
    feed = server.add_feed("/feed.xml", "Testcast", [
        {"title": "Folge 1", "guid": "g-1", "path": "/download?id=1", "type": "audio/x-m4a"},
        {"title": "Folge 2", "guid": "g-2", "path": "/ep2.mp3"},
    ])
    out = tmp_path / "out"

    code, output = run(impl, script_dir, tmp_path, url=feed, output=out, retries=1, m3u=True)

    assert code == 0, output
    folder = out / "Testcast"
    assert (folder / "Folge 1.m4a").exists()
    playlist = (folder / "Testcast_Playlist.m3u").read_text(encoding="utf-8-sig").splitlines()
    assert "Folge 1.m4a" in playlist and "Folge 2.mp3" in playlist


def test_title_with_brackets_is_recognized_on_rerun(impl, server, script_dir, tmp_path):
    """PowerShell deutet [ ] bei -Path als Platzhalter - die Folge wurde nie als vorhanden erkannt."""
    server.add("/ep1.mp3", AUDIO)
    feed = server.add_feed("/feed.xml", "Testcast [Archiv]", [{"title": "Bonus [Teil 1]", "guid": "g-1", "path": "/ep1.mp3"}])
    out = tmp_path / "out"
    assert run(impl, script_dir, tmp_path, url=feed, output=out, retries=1)[0] == 0
    assert (out / "Testcast [Archiv]" / "Bonus [Teil 1].mp3").exists()

    code, output = run(impl, script_dir, tmp_path, url=feed, output=out, retries=1)

    assert code == 0, output
    assert len(server.hits["/ep1.mp3"]) == 1, "Folge wurde erneut heruntergeladen"


@pytest.mark.parametrize("feed_content_type", ["application/octet-stream", None], ids=["octet-stream", "ohne-header"])
def test_feed_with_unusual_content_type_is_read(impl, feed_content_type, server, script_dir, tmp_path):
    """Falsch konfigurierte Server liefern Feeds als Binärdaten oder ganz ohne Content-Type aus."""
    server.add("/ep1.mp3", AUDIO)
    feed = server.add_feed("/feed.xml", "Testcast", [{"title": "Folge 1", "guid": "g-1", "path": "/ep1.mp3"}],
                           content_type=feed_content_type)
    out = tmp_path / "out"

    code, output = run(impl, script_dir, tmp_path, url=feed, output=out, retries=1)

    assert code == 0, output
    assert (out / "Testcast" / "Folge 1.mp3").exists()


def test_interrupted_download_is_resumed_on_next_run(impl, server, script_dir, tmp_path):
    data = bytes(range(256)) * 64
    server.add_sequence("/ep1.mp3", [truncated(data, 5000), ranged(data)])
    feed = server.add_feed("/feed.xml", "Testcast", [{"title": "Folge 1", "guid": "g-1", "path": "/ep1.mp3"}])
    out = tmp_path / "out"
    part = out / "Testcast" / "Folge 1.mp3.part"

    # 1. Lauf: Verbindung bricht ab -> Fehlschlag, aber die .part-Datei bleibt erhalten
    code, output = run(impl, script_dir, tmp_path, url=feed, output=out, retries=1)
    assert code == 1, output
    assert part.exists(), "Fortschritt verworfen"
    kept = part.stat().st_size
    assert 0 < kept <= 5000

    # 2. Lauf: setzt an genau dieser Stelle fort
    code, output = run(impl, script_dir, tmp_path, url=feed, output=out, retries=1)
    assert code == 0, output
    assert server.request_headers["/ep1.mp3"][-1].get("Range") == f"bytes={kept}-"
    assert (out / "Testcast" / "Folge 1.mp3").read_bytes() == data


def test_part_file_rejected_by_server_is_discarded(impl, server, script_dir, tmp_path):
    """416: Die .part-Datei passt nicht mehr zur Datei auf dem Server -> neu beginnen statt ewig scheitern."""
    server.add_sequence("/ep1.mp3", [ranged(AUDIO)])
    feed = server.add_feed("/feed.xml", "Testcast", [{"title": "Folge 1", "guid": "g-1", "path": "/ep1.mp3"}])
    folder = tmp_path / "out" / "Testcast"
    folder.mkdir(parents=True)
    (folder / "Folge 1.mp3.part").write_bytes(b"x" * (len(AUDIO) + 100))

    code, output = run(impl, script_dir, tmp_path, url=feed, output=tmp_path / "out", retries=2)

    assert code == 0, output
    assert (folder / "Folge 1.mp3").read_bytes() == AUDIO


def test_date_prefix_is_identical_in_both_implementations(impl, server, script_dir, tmp_path):
    """Folgen ohne Episodennummer: Datum so, wie es im Feed steht, unabhängig von der lokalen Zeitzone."""
    episodes = [
        # 23:30 in New York ist in Berlin schon der nächste Tag
        {"title": "Folge A", "guid": "g-a", "path": "/a.mp3", "extra": "<pubDate>Tue, 01 Sep 2026 23:30:00 -0500</pubDate>"},
        # falscher Wochentag (der 01.09.2026 ist ein Dienstag) - kommt in echten Feeds vor
        {"title": "Folge B", "guid": "g-b", "path": "/b.mp3", "extra": "<pubDate>Mon, 01 Sep 2026 10:00:00 GMT</pubDate>"},
        # ISO 8601, wie in Atom-Feeds üblich
        {"title": "Folge C", "guid": "g-c", "path": "/c.mp3", "extra": "<pubDate>2026-09-03T23:30:00-05:00</pubDate>"},
    ]
    for ep in episodes:
        server.add(ep["path"], AUDIO)
    feed = server.add_feed("/feed.xml", "Testcast", episodes)
    out = tmp_path / "out"

    code, output = run(impl, script_dir, tmp_path, env={"TZ": "Europe/Berlin"}, url=feed, output=out, retries=1)

    assert code == 0, output
    assert audio_files(out) == ["2026-09-01 - Folge A.mp3", "2026-09-01 - Folge B.mp3", "2026-09-03 - Folge C.mp3"]


def test_retry_after_header_is_respected(impl, server, script_dir, tmp_path):
    # Standard-Backoff nach Versuch 1 wären 2s - der Server verlangt 4s
    server.add_sequence("/ep1.mp3", [
        (429, {"Retry-After": "4"}, b""),
        (200, {"Content-Type": "audio/mpeg"}, AUDIO),
    ])
    feed = server.add_feed("/feed.xml", "Testcast", [{"title": "Folge 1", "guid": "g-1", "path": "/ep1.mp3"}])
    out = tmp_path / "out"

    code, output = run(impl, script_dir, tmp_path, url=feed, output=out, retries=2)

    assert code == 0, output
    first, second = server.hits["/ep1.mp3"][:2]
    assert second - first >= 3.5, f"nur {second - first:.1f}s gewartet\n{output}"


def test_default_output_is_podcasts_folder_next_to_script(impl, server, script_dir, tmp_path):
    server.add("/ep1.mp3", AUDIO)
    feed = server.add_feed("/feed.xml", "Testcast", [{"title": "Folge 1", "guid": "g-1", "path": "/ep1.mp3"}])
    elsewhere = tmp_path / "anderswo"
    elsewhere.mkdir()

    code, output = run(impl, script_dir, elsewhere, url=feed, retries=1)

    assert code == 0, output
    assert (script_dir / "Podcasts" / "Testcast" / "Folge 1.mp3").exists()
    assert not any(elsewhere.iterdir())


def test_config_next_to_script_is_found_from_other_working_directory(impl, server, script_dir, tmp_path):
    """Aufgabenplanung/Cron starten oft in einem anderen Arbeitsverzeichnis (z.B. C:\\Windows\\System32)."""
    server.add("/ep1.mp3", AUDIO)
    feed = server.add_feed("/feed.xml", "Testcast", [{"title": "Folge 1", "guid": "g-1", "path": "/ep1.mp3"}])
    # Relativer Pfad: muss relativ zum Ordner der config.json aufgelöst werden
    (script_dir / "config.json").write_text(json.dumps({"url": feed, "output": "Archiv", "retries": 1}), encoding="utf-8")
    elsewhere = tmp_path / "anderswo"
    elsewhere.mkdir()

    code, output = run(impl, script_dir, elsewhere)

    assert code == 0, output
    assert (script_dir / "Archiv" / "Testcast" / "Folge 1.mp3").exists()
    assert not any(elsewhere.iterdir())


def test_config_with_umlaut_output_path(impl, server, script_dir, tmp_path):
    """Nachgestellter Nutzerfall; UTF-8 ohne BOM ist in Windows PowerShell 5.1 der kritische Fall."""
    server.add("/ep1.mp3", AUDIO)
    feed = server.add_feed("/feed.xml", "Der Bobcast", [{"title": "Folge 1", "guid": "g-1", "path": "/ep1.mp3"}])
    target = tmp_path / "Haschimitenfürst – Der Bobcast"
    config = {"urls": [feed], "output": str(target), "flat": True, "retries": 1}
    (script_dir / "config.json").write_text(json.dumps(config, ensure_ascii=False), encoding="utf-8")

    code, output = run(impl, script_dir, script_dir)

    assert code == 0, output
    assert (target / "Folge 1.mp3").exists()


def test_config_with_bom_is_accepted(impl, server, script_dir, tmp_path):
    server.add("/ep1.mp3", AUDIO)
    feed = server.add_feed("/feed.xml", "Testcast", [{"title": "Folge 1", "guid": "g-1", "path": "/ep1.mp3"}])
    out = tmp_path / "out"
    (script_dir / "config.json").write_text(json.dumps({"url": feed, "output": str(out), "retries": 1}), encoding="utf-8-sig")

    code, output = run(impl, script_dir, script_dir)

    assert code == 0, output
    assert (out / "Testcast" / "Folge 1.mp3").exists()


def test_broken_config_fails_with_clear_message(impl, script_dir):
    (script_dir / "config.json").write_text('{ "url": "http://127.0.0.1:1/feed.xml", kaputt ]', encoding="utf-8")

    code, output = run(impl, script_dir, script_dir)

    assert code == 1, output
    assert "Fehler beim Lesen" in output
    assert "Traceback" not in output


def test_python_survives_non_utf8_console(server, script_dir, tmp_path):
    """Windows mit umgeleiteter Ausgabe (> log.txt, Aufgabenplanung) nutzt cp1252 für stdout."""
    server.add("/ep1.mp3", AUDIO)
    feed = server.add_feed("/feed.xml", "Testcast", [{"title": "Folge 1", "guid": "g-1", "path": "/ep1.mp3"}])
    out = tmp_path / "out"

    code, output = run("python", script_dir, tmp_path, env={"PYTHONIOENCODING": "cp1252"},
                       url=feed, output=out, retries=1)

    assert code == 0, output
    assert "Traceback" not in output


def test_ps1_is_saved_as_utf8_with_bom():
    """Ohne BOM liest Windows PowerShell 5.1 die Datei als ANSI: aus '✔' wird 'âœ”', und das
    '”' beendet Strings vorzeitig - die Download-Schleife wird dann stillschweigend zu Text."""
    assert PS_SCRIPT.read_bytes().startswith(b"\xef\xbb\xbf"), \
        "universal_podcast_downloader.ps1 muss als 'UTF-8 mit BOM' gespeichert sein"
