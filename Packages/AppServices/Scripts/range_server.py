"""Local HTTP server with Range/If-Range support for URLSessionChartTransport integration tests."""
import http.server, socketserver, sys, time, os

DATA = bytes(i % 251 for i in range(1_000_000))
TINY = open(sys.argv[2], "rb").read() if len(sys.argv) > 2 else b""
ETAG = '"v1"'
LASTMOD = "Tue, 28 May 2024 18:20:14 GMT"

class H(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def log_message(self, *a): pass

    def common(self, body_only_head):
        path = self.path.split("?")[0]
        if path == "/missing":
            self.send_response(404); self.send_header("Content-Length", "0"); self.end_headers(); return
        data = TINY if path == "/tiny.mbtiles" else DATA
        if path == "/drop":
            self.send_response(200); self.send_header("Content-Length", str(len(DATA)))
            self.send_header("ETag", ETAG); self.end_headers()
            if not body_only_head:
                self.wfile.write(DATA[:300_000]); self.wfile.flush()
                self.close_connection = True
                self.connection.shutdown(2)
            return
        start = 0
        status = 200
        rng = self.headers.get("Range"); ifr = self.headers.get("If-Range")
        if rng and rng.startswith("bytes=") and (ifr is None or ifr == ETAG or ifr == LASTMOD):
            start = int(rng[6:].split("-")[0])
            if start >= len(data):
                self.send_response(416); self.send_header("Content-Range", f"bytes */{len(data)}")
                self.send_header("Content-Length", "0"); self.end_headers(); return
            status = 206
        body = data[start:]
        self.send_response(status)
        self.send_header("ETag", ETAG); self.send_header("Last-Modified", LASTMOD)
        self.send_header("Accept-Ranges", "bytes"); self.send_header("Content-Length", str(len(body)))
        if status == 206:
            self.send_header("Content-Range", f"bytes {start}-{len(data)-1}/{len(data)}")
        self.end_headers()
        if body_only_head: return
        if path == "/slow":
            for i in range(0, len(body), 10_000):
                try:
                    self.wfile.write(body[i:i+10_000]); self.wfile.flush()
                except Exception:
                    return
                time.sleep(0.05)
        else:
            self.wfile.write(body)

    def do_HEAD(self): self.common(True)
    def do_GET(self): self.common(False)

class S(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    allow_reuse_address = True

S(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
