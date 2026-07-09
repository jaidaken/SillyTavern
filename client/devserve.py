#!/usr/bin/env python3
"""Serve the exported client and reverse-proxy the SillyTavern API to one origin.

Static files come from `dist/`. Anything under `/api/` plus `/csrf-token` is
forwarded to the Express backend, so the browser sees a single origin and no CORS
preflight. Binds loopback only.

Usage: python3 devserve.py [--port 8080] [--dist dist] [--backend http://127.0.0.1:8000]
"""

import argparse
import base64
import http.server
import pathlib
import signal
import socketserver
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request

PROXY_PREFIXES = ("/api/", "/csrf-token")
HOP_BY_HOP = {
    "connection", "keep-alive", "proxy-authenticate", "proxy-authorization",
    "te", "trailers", "transfer-encoding", "upgrade",
}

EXTRA_TYPES = {
    ".wasm": "application/wasm",
    ".mjs": "text/javascript",
    ".js": "text/javascript",
}


class Handler(http.server.SimpleHTTPRequestHandler):
    backend = "http://127.0.0.1:8000"
    dev = False

    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=str(Handler.dist), **kwargs)

    def guess_type(self, path):
        suffix = pathlib.PurePath(path).suffix.lower()
        if suffix in EXTRA_TYPES:
            return EXTRA_TYPES[suffix]
        return super().guess_type(path)

    def is_proxied(self):
        return self.path.startswith(PROXY_PREFIXES)

    def do_GET(self):
        # Test endpoints. Off unless --dev: they must never exist in a served build.
        if self.path.startswith("/dev/"):
            if not Handler.dev:
                self.send_error(404, "not found")
                return
            if self.path.startswith("/dev/stream"):
                return self.dev_stream()
            if self.path.startswith("/dev/hold"):
                return self.dev_hold()
            self.send_error(404, "not found")
            return
        if self.is_proxied():
            return self.proxy()
        return super().do_GET()

    # Headless --dump-dom snapshots at the load event; a slow subresource holds it open.
    def dev_hold(self):
        params = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
        time.sleep(min(float(params.get("ms", ["3000"])[0]) / 1000.0, 30.0))
        pixel = base64.b64decode("R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7")
        self.send_response(200)
        self.send_header("Content-Type", "image/gif")
        self.send_header("Content-Length", str(len(pixel)))
        self.end_headers()
        try:
            self.wfile.write(pixel)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def dev_stream(self):
        query = urllib.parse.urlparse(self.path).query
        params = urllib.parse.parse_qs(query)
        tokens = int(params.get("n", ["200"])[0])
        delay = float(params.get("delay", ["0.002"])[0])
        prefix = params.get("prefix", ["tok"])[0]

        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.end_headers()
        try:
            for i in range(tokens):
                self.wfile.write(f"data: {prefix}{i} \n\n".encode())
                self.wfile.flush()
                time.sleep(delay)
            self.wfile.write(b"data: [DONE]\n\n")
            self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            pass

    def do_HEAD(self):
        if self.is_proxied():
            return self.proxy()
        return super().do_HEAD()

    def do_POST(self):
        return self.proxy()

    def do_PUT(self):
        return self.proxy()

    def do_DELETE(self):
        return self.proxy()

    def proxy(self):
        if not self.is_proxied():
            self.send_error(404, "not proxied")
            return

        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length) if length else None

        target = urllib.parse.urljoin(self.backend, self.path)
        req = urllib.request.Request(target, data=body, method=self.command)
        for key, value in self.headers.items():
            if key.lower() in HOP_BY_HOP or key.lower() == "host":
                continue
            req.add_header(key, value)

        try:
            with urllib.request.urlopen(req) as upstream:
                self.relay(upstream)
        except urllib.error.HTTPError as err:
            self.relay(err)
        except urllib.error.URLError as err:
            self.send_error(502, f"backend unreachable: {err.reason}")

    def relay(self, upstream):
        self.send_response(upstream.status)
        for key, value in upstream.headers.items():
            if key.lower() in HOP_BY_HOP or key.lower() == "content-length":
                continue
            self.send_header(key, value)
        payload = upstream.read()
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(payload)

    def log_message(self, fmt, *args):
        sys.stderr.write(f"{self.command} {self.path}\n")


class Server(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=8080)
    parser.add_argument("--dist", default="dist")
    parser.add_argument("--backend", default="http://127.0.0.1:8000")
    parser.add_argument("--dev", action="store_true", help="expose /dev/stream and /dev/hold test endpoints")
    args = parser.parse_args()

    dist = pathlib.Path(args.dist).resolve()
    if not dist.is_dir():
        sys.exit(f"no such dist dir: {dist} (run `zig build export` first)")

    Handler.dist = dist
    Handler.backend = args.backend
    Handler.dev = args.dev

    # Loopback only. Never 0.0.0.0.
    with Server(("127.0.0.1", args.port), Handler) as httpd:
        stopping = threading.Event()
        # shutdown() blocks until serve_forever() returns, so it cannot run on this thread.
        serving = threading.Thread(target=httpd.serve_forever, daemon=True)

        signal.signal(signal.SIGTERM, lambda *_: stopping.set())
        signal.signal(signal.SIGINT, lambda *_: stopping.set())

        sys.stderr.write(f"serving {dist} on http://127.0.0.1:{args.port} (api -> {args.backend})\n")
        sys.stderr.flush()
        serving.start()
        stopping.wait()
        httpd.shutdown()

    return 0


if __name__ == "__main__":
    sys.exit(main())
