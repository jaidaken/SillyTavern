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


MOCK_CHAT_TOTAL = 300


def _mock_chat_page(req):
    """A synthetic paged chat for the reader gate: MOCK_CHAT_TOTAL messages, index-anchored.
    Honors before_index/limit; never 409s (happy-path gate). The client always sends paged."""
    # Synthetic history, then the turns the client appended (the newest), so a reload shows a send.
    extra = Handler.appended_messages
    total = MOCK_CHAT_TOTAL + len(extra)
    try:
        limit = int(req.get("limit") or 100)
    except (TypeError, ValueError):
        limit = 100
    limit = max(1, min(limit, total))
    before = req.get("before_index")
    if isinstance(before, int):
        end = max(0, min(before, total))
        start = max(0, end - limit)
    else:
        end = total
        start = max(0, total - limit)
    messages = []
    for i in range(start, end):
        if i < MOCK_CHAT_TOTAL:
            is_user = (i % 2 == 1)
            messages.append({
                "name": "You" if is_user else "Rita Recent",
                "is_user": is_user,
                "mes": f"History message {i} in the reverse-lazy reader chat.",
            })
        else:
            messages.append(extra[i - MOCK_CHAT_TOTAL])
    return {
        "messages": messages,
        "header": {"user_name": "You", "chat_metadata": {}},
        "change_token": Handler.append_token or f"v1.{total}.mock",
        "has_more_before": start > 0,
        "has_more_after": end < total,
        "total_items": total,
        "anchor_index": None if before is None else before,
        "anchor_found": True,
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


# ---- undo fixture (C4): char00's chat is repurposed as a two-identical-message chat + one older
# backup, so the 60-character count the B2b gate pins stays intact (no extra fixture character). ----
UNDO_AVATAR = "char00.png"
UNDO_TS = "20260714-120000"


def _fresh_undo_chat():
    return [
        {"name": "You", "is_user": True, "mes": "Where does the path lead?"},
        {"name": "Guide", "is_user": False, "mes": "The lantern gutters."},
        {"name": "You", "is_user": True, "mes": "And to the east?"},
        {"name": "Guide", "is_user": False, "mes": "The lantern gutters."},
    ]


def _undo_backup_messages():
    # The older save: message index 1 read differently before an edit; index 3 is its identical twin
    # and must be left untouched by a restore of index 1 (the dangerous-property test).
    m = _fresh_undo_chat()
    m[1] = {"name": "Guide", "is_user": False, "mes": "The lantern flares."}
    return m


def _undo_chat_page():
    msgs = [dict(m) for m in Handler.undo_current()]
    return {
        "messages": msgs,
        "header": {"user_name": "You", "chat_metadata": {}},
        "change_token": f"undo-spine-{Handler.undo_token}",
        "has_more_before": False,
        "has_more_after": False,
        "total_items": len(msgs),
        "anchor_index": None,
        "anchor_found": True,
    }


class Handler(http.server.SimpleHTTPRequestHandler):
    backend = "http://127.0.0.1:8000"
    dev = False
    mock_api = False
    mock_favs = {}
    # Send-loop/connection gate readback: what the client persisted and what its last generate carried.
    recorded_connection = None
    last_generate_server = None
    # J1 invariant-2 gate: the prompt of the last generate, so a gate can prove it spans history
    # beyond the display window.
    last_generate_prompt = None
    # Turns the client appended via /api/chats/append; the mock /get echoes them so a reload shows them.
    appended_messages = []
    append_token = None
    # Counters the 409 gate reads back as observable state (a returned 409, and the resync's refetch).
    append_409_count = 0
    get_count = 0
    # Undo fixture state (C4): the mutable current chat and its optimistic-concurrency token.
    undo_chat = None
    undo_token = "utok-0"

    @classmethod
    def undo_current(cls):
        if cls.undo_chat is None:
            cls.undo_chat = _fresh_undo_chat()
        return cls.undo_chat

    @classmethod
    def bump_undo_token(cls):
        n = int(cls.undo_token.split("-")[1]) + 1
        cls.undo_token = f"utok-{n}"
        return cls.undo_token

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
            if self.path.startswith("/dev/state"):
                return self.mock_json({
                    "recorded_connection": Handler.recorded_connection,
                    "last_generate_server": Handler.last_generate_server,
                    "last_generate_prompt": Handler.last_generate_prompt,  # J1 invariant-2
                    "appended": Handler.appended_messages,
                    "append_409_count": Handler.append_409_count,
                    "get_count": Handler.get_count,
                })
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

    # Canned generate SSE for the send-loop gate (OpenAI-completions shape, ST pipes it back unchanged).
    # 24 tokens at a fixed 60ms interval so stop lands mid-stream; "lantern" is first, "FIN" only on completion.
    def _mock_generate_stream(self):
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.end_headers()
        reply = ["lantern "] + [f"w{i} " for i in range(22)] + ["FIN"]
        try:
            for tok in reply:
                payload = json.dumps({"choices": [{"text": tok}]})
                self.wfile.write(f"data: {payload}\n\n".encode())
                self.wfile.flush()
                time.sleep(0.06)
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
            settings = {
                "main_api": "textgenerationwebui",
                "amount_gen": 64,
                "textgenerationwebui_settings": {
                    "type": "llamacpp",
                    "server_urls": {"llamacpp": "http://127.0.0.1:5001"},
                    "temp": 0.8, "top_p": 0.95, "top_k": 40, "min_p": 0.05, "rep_pen": 1.1,
                },
                "power_user": {
                    "personas": {"p1.png": "Alice", "p2.png": "Bob"},
                    "persona_descriptions": {"p1.png": "First persona", "p2.png": "Second persona"},
                },
            }
            return self.mock_json({"settings": json.dumps(settings)})
        if path == "/api/characters/get":
            return self.mock_json({
                "name": req.get("avatar_url", "char"),
                "personality": "curious and warm",
                "scenario": "a quiet harbor at dusk",
                "mes_example": "<START>\n{{user}}: hello\n{{char}}: well met",
            })
        if path == "/api/backends/text-completions/status":
            return self.mock_json({"result": "mock-model", "data": [{"id": "mock-model"}]})
        if path == "/api/settings/set-connection":
            Handler.recorded_connection = {"api_type": req.get("api_type"), "api_server": req.get("api_server")}
            return self.mock_json({"ok": True, "connection": Handler.recorded_connection})
        if path == "/api/chats/append":
            msgs = req.get("messages") or []
            # Deterministic resync trigger: a message whose text starts with "409:" forces a mismatch.
            if any(str(m.get("mes", "")).startswith("409:") for m in msgs):
                Handler.append_409_count += 1
                return self.mock_status(409, {"error": "version_mismatch", "change_token": Handler.append_token or f"v1.{MOCK_CHAT_TOTAL}.mock"})
            Handler.appended_messages.extend(msgs)
            Handler.append_token = f"v1.{MOCK_CHAT_TOTAL + len(Handler.appended_messages)}.mock"
            return self.mock_json({"ok": True, "appended": len(msgs), "change_token": Handler.append_token})
        if path == "/api/backends/text-completions/generate":
            Handler.last_generate_server = req.get("api_server")
            Handler.last_generate_prompt = req.get("prompt")  # J1 invariant-2
            return self._mock_generate_stream()
        if path == "/api/chats/get":
            # The client always sends paged:true (reader tail window + scroll-up prepend).
            Handler.get_count += 1
            if req.get("avatar_url") == UNDO_AVATAR:
                return self.mock_json(_undo_chat_page())
            return self.mock_json(_mock_chat_page(req))
        if path == "/api/chats/backups/message-versions":
            return self.mock_json(self._undo_versions(req))
        if path == "/api/chats/backups/restore-message":
            return self._undo_restore_message(req)
        if path == "/api/chats/backups/snapshots":
            return self._undo_snapshots(req)
        if path == "/api/chats/backups/restore-deleted":
            return self._undo_restore_deleted(req)
        if path == "/api/characters/edit-attribute":
            if req.get("field") == "fav":
                Handler.mock_favs[req.get("avatar_url")] = bool(req.get("value"))
            return self.mock_json({})
        # Every other API POST (create/rename/settings-save/...) acknowledges without state.
        return self.mock_json({})

    def _undo_versions(self, req):
        idx = req.get("index")
        cur = Handler.undo_current()
        versions = []
        if isinstance(idx, int) and 0 <= idx < len(cur):
            older = _undo_backup_messages()[idx]["mes"]
            # Dedup: only surface a version whose text differs from the message as it stands now.
            if older != cur[idx]["mes"]:
                versions.append({"mes": older, "backup_ts": UNDO_TS, "matched": True})
        return {
            "versions": versions, "depth": 1, "truncated": False,
            "basis": "identity", "attributable": True, "change_token": Handler.undo_token,
        }

    def _undo_restore_message(self, req):
        cur = Handler.undo_current()
        token = req.get("change_token")
        if isinstance(token, str) and token != Handler.undo_token:
            return self.mock_status(409, {"error": "stale", "change_token": Handler.undo_token})
        idx = req.get("index")
        if not (isinstance(idx, int) and 0 <= idx < len(cur)):
            return self.mock_status(400, {"error": "target_not_found"})
        if req.get("backup_ts") != UNDO_TS:
            return self.mock_status(404, {"error": "no_such_backup"})
        # Change ONLY the targeted index; its identical twin at another index must stay put.
        cur[idx]["mes"] = _undo_backup_messages()[idx]["mes"]
        Handler.bump_undo_token()
        return self.mock_json({
            "ok": True, "change_token": Handler.undo_token,
            "restored": {"index": idx, "matched": True, "backup_ts": UNDO_TS},
        })

    def _undo_snapshots(self, req):
        cur = Handler.undo_current()
        if req.get("mode") == "restore":
            token = req.get("change_token")
            if isinstance(token, str) and token != Handler.undo_token:
                return self.mock_status(409, {"error": "stale", "change_token": Handler.undo_token})
            if req.get("backup_ts") != UNDO_TS:
                return self.mock_status(404, {"error": "no_such_backup"})
            Handler.undo_chat = _undo_backup_messages()
            Handler.bump_undo_token()
            return self.mock_json({"ok": True, "restored": len(Handler.undo_chat), "change_token": Handler.undo_token})
        backup = _undo_backup_messages()
        edited = sum(1 for a, b in zip(backup, cur) if a["mes"] != b["mes"])
        snap = {
            "backup_ts": UNDO_TS,
            "message_count": len(backup),
            "last_mes_preview": backup[-1]["mes"] if backup else "",
            "added": max(0, len(cur) - len(backup)),
            "removed": max(0, len(backup) - len(cur)),
            "edited": edited,
            "basis": "identity",
            "too_large": False,
        }
        return self.mock_json({
            "snapshots": [snap], "depth": 1, "truncated": False,
            "basis": "identity", "attributable": True, "change_token": Handler.undo_token,
        })

    def _undo_restore_deleted(self, req):
        token = req.get("change_token")
        if isinstance(token, str) and token != Handler.undo_token:
            return self.mock_status(409, {"error": "stale", "change_token": Handler.undo_token})
        if req.get("backup_ts") != UNDO_TS:
            return self.mock_status(404, {"error": "no_such_backup"})
        # The fixture backup has no messages missing from the current chat, so nothing is restored.
        return self.mock_json({"ok": True, "restored": 0, "change_token": Handler.undo_token})

    def mock_json(self, payload):
        return self.mock_status(200, payload)

    def mock_status(self, status, payload):
        data = json.dumps(payload).encode()
        self.send_response(status)
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
