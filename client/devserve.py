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
import json
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


def _mock_characters(favs):
    chars = []
    for i in range(60):
        name = f"Char {i:02d} {'Vex' if i % 3 else 'Moon'}"
        if i == 41:
            name = "Rita Recent"
        avatar = f"char{i:02d}.png"
        chars.append({
            "name": name,
            "avatar": avatar,
            "description": f"Mock character {i} for the interactions gate.",
            "chat": f"{name} - 2026-07-14",
            "first_mes": f"Greetings from {name}.",
            "fav": favs.get(avatar, i % 7 == 0),
            "date_last_chat": 1783800000000 if i == 41 else 1700000000000 + i * 1000,
            "chat_size": 1024 + i,
            "data_size": 4096 + i,
            "create_date": "2026-07-01",
        })
    return chars


class Handler(http.server.SimpleHTTPRequestHandler):
    backend = "http://127.0.0.1:8000"
    dev = False
    mock_api = False
    mock_favs = {}

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
        # The ziex base_path="/client" means the HTML references /client/* but the
        # dist layout puts files at the root.  Strip the prefix for static serving.
        if self.path.startswith("/client/"):
            self.path = self.path[len("/client"):]
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
                # json.dumps escapes the prefix so `?prefix=a"b` stays valid JSON; completion.zig
                # rejects any payload whose first byte is not `{`. Trailing space joins the tokens.
                payload = json.dumps({"content": f"{prefix}{i} "})
                self.wfile.write(f"data: {payload}\n\n".encode())
                self.wfile.flush()
                time.sleep(delay)
            self.wfile.write(b"data: [DONE]\n\n")
            self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            pass

    def do_HEAD(self):
        if self.is_proxied():
            return self.proxy()
        if self.path.startswith("/client/"):
            self.path = self.path[len("/client"):]
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

        if Handler.mock_api:
            return self.mock(body)

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

    # Canned backend for the interactions gate (verify-interactions.sh): stable data, no real
    # SillyTavern needed. Only ever active with --mock-api, which the gate passes explicitly.
    def mock(self, body):
        try:
            req = json.loads(body) if body else {}
        except ValueError:
            req = {}
        path = urllib.parse.urlparse(self.path).path

        if path == "/csrf-token":
            return self.mock_json({"token": "mock-csrf-token"})
        if path == "/api/characters/all":
            return self.mock_json(_mock_characters(Handler.mock_favs))
        if path == "/api/settings/get":
            settings = {"power_user": {
                "personas": {"p1.png": "Alice", "p2.png": "Bob"},
                "persona_descriptions": {"p1.png": "First persona", "p2.png": "Second persona"},
            }}
            return self.mock_json({"settings": json.dumps(settings)})
        if path == "/api/chats/get":
            name = "Mock"
            for c in _mock_characters(Handler.mock_favs):
                if c["avatar"] == req.get("avatar_url"):
                    name = c["name"]
            return self.mock_json([
                {"user_name": "You", "character_name": name, "chat_metadata": {}},
                {"name": name, "is_user": False, "mes": f"Hello, I am {name}."},
                {"name": "You", "is_user": True, "mes": "Hi there."},
                {"name": name, "is_user": False, "mes": "The newest message lands last."},
            ])
        if path == "/api/characters/edit-attribute":
            if req.get("field") == "fav":
                Handler.mock_favs[req.get("avatar_url")] = bool(req.get("value"))
            return self.mock_json({})
        # Every other API POST (create/rename/settings-save/...) acknowledges without state.
        return self.mock_json({})

    def mock_json(self, payload):
        data = json.dumps(payload).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(data)

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
    parser.add_argument("--mock-api", action="store_true", help="answer /api/* + /csrf-token from canned data instead of the backend (interactions gate)")
    args = parser.parse_args()

    dist = pathlib.Path(args.dist).resolve()
    if not dist.is_dir():
        sys.exit(f"no such dist dir: {dist} (run `zig build export` first)")

    Handler.dist = dist
    Handler.backend = args.backend
    Handler.dev = args.dev
    Handler.mock_api = args.mock_api

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
