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
            "workers": "--workers", "flat": "--flat", "dry_run": "--dry-run"}
PS_FLAGS = {"url": "-Url", "output": "-Output", "config": "-Config", "retries": "-Retries",
            "workers": "-Workers", "flat": "-Flat", "dry_run": "-DryRun"}


# ------------------------------------------------------------------------------
# Lokaler Feed-Server
# ------------------------------------------------------------------------------
class FeedServer:
    """Liefert pro Pfad eine Folge von Antworten; die letzte wiederholt sich."""

    def __init__(self):
        self.routes = {}
        self.hits = {}
        server = self

        class Handler(BaseHTTPRequestHandler):
            def do_GET(self):
                server.hits.setdefault(self.path, []).append(time.monotonic())
                responses = server.routes.get(self.path)
                if not responses:
                    self.send_response(404)
                    self.send_header("Content-Length", "0")
                    self.end_headers()
                    return
                status, headers, body = responses[min(len(server.hits[self.path]), len(responses)) - 1]
                self.send_response(status)
                for key, value in headers.items():
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

    def add_feed(self, path, title, episodes):
        items = "".join(
            f"<item><title>{ep['title']}</title><guid>{ep['guid']}</guid>"
            f"<enclosure url=\"{self.url(ep['path'])}\" type=\"audio/mpeg\"/></item>"
            for ep in episodes
        )
        rss = f'<?xml version="1.0" encoding="UTF-8"?><rss version="2.0"><channel><title>{title}</title>{items}</channel></rss>'
        self.add(path, rss.encode("utf-8"), content_type="application/rss+xml; charset=utf-8")
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
