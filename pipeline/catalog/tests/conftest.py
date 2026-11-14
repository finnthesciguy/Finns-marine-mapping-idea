import io
import os
import threading
import zipfile
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

import pytest

FIXTURE = Path(__file__).parent / "fixtures" / "ENCProdCat_trimmed.xml"


@pytest.fixture(scope="session")
def fixture_path() -> str:
    return str(FIXTURE)


@pytest.fixture(scope="session")
def catalog(fixture_path):
    from enc_catalog import parse_catalog

    return parse_catalog(fixture_path)


@pytest.fixture(scope="session")
def selection(catalog):
    from enc_catalog import select_cells

    return select_cells(catalog.cells)


def make_zip(name: str, payload: bytes = b"x" * 5000) -> bytes:
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w", zipfile.ZIP_DEFLATED) as z:
        z.writestr(f"ENC_ROOT/{name}/{name}.000", payload)
    return buf.getvalue()


class FakeServer:
    """Tiny local HTTP server: serves self.files, honours Range and
    If-None-Match, and can be told to fail the next N requests with 503."""

    def __init__(self):
        self.files: dict[str, bytes] = {}
        self.etags: dict[str, str] = {}
        self.log: list[tuple[str, str, str]] = []  # (path, range, status)
        self.fail_next = 0
        self.truncate_next: int | None = None
        srv = self

        class H(BaseHTTPRequestHandler):
            def log_message(self, *a):
                pass

            def do_GET(self):
                rng = self.headers.get("Range", "")
                if srv.fail_next:
                    srv.fail_next -= 1
                    srv.log.append((self.path, rng, "503"))
                    self.send_response(503)
                    self.send_header("Retry-After", "0")
                    self.end_headers()
                    return
                body = srv.files.get(self.path)
                if body is None:
                    srv.log.append((self.path, rng, "404"))
                    self.send_response(404)
                    self.end_headers()
                    return
                etag = srv.etags.get(self.path)
                if etag and self.headers.get("If-None-Match") == etag:
                    srv.log.append((self.path, rng, "304"))
                    self.send_response(304)
                    self.end_headers()
                    return
                status, start = 200, 0
                if rng.startswith("bytes="):
                    start = int(rng[6:].split("-")[0])
                    if start >= len(body):
                        srv.log.append((self.path, rng, "416"))
                        self.send_response(416)
                        self.end_headers()
                        return
                    status = 206
                chunk = body[start:]
                if srv.truncate_next is not None:
                    chunk = chunk[: srv.truncate_next]
                    srv.truncate_next = None
                srv.log.append((self.path, rng, str(status)))
                self.send_response(status)
                if status == 206:
                    self.send_header("Content-Range", f"bytes {start}-{len(body) - 1}/{len(body)}")
                if etag:
                    self.send_header("ETag", etag)
                self.send_header("Content-Length", str(len(chunk)))
                self.end_headers()
                self.wfile.write(chunk)

        self.httpd = ThreadingHTTPServer(("127.0.0.1", 0), H)
        self.url = f"http://127.0.0.1:{self.httpd.server_address[1]}"
        self.thread = threading.Thread(target=self.httpd.serve_forever, daemon=True)
        self.thread.start()

    def close(self):
        self.httpd.shutdown()
        self.httpd.server_close()


@pytest.fixture
def server(monkeypatch):
    # Talk to the local server directly, never through an outbound proxy.
    for k in ("HTTP_PROXY", "http_proxy", "HTTPS_PROXY", "https_proxy", "ALL_PROXY", "all_proxy"):
        monkeypatch.delenv(k, raising=False)
    monkeypatch.setenv("NO_PROXY", "127.0.0.1,localhost")
    s = FakeServer()
    yield s
    s.close()


live = pytest.mark.skipif(os.environ.get("ENC_CATALOG_LIVE") != "1", reason="set ENC_CATALOG_LIVE=1 to hit NOAA")
