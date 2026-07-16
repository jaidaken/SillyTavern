#!/usr/bin/env python3
"""Serve the exported client and reverse-proxy the SillyTavern API to one origin.

Static files come from `dist/`. Anything under `/api/` plus `/csrf-token` is
forwarded to the Express backend, so the browser sees a single origin and no CORS
preflight. Binds loopback only.

Usage: python3 devserve.py [--port 8080] [--dist dist] [--backend http://127.0.0.1:8000]
"""

import argparse
import base64
import datetime
import http.server
import json
import pathlib
import re
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
    # The mutable base file, then the turns the client appended (the newest), so a reload shows a send
    # and a message mutation (edit/delete/move by absolute index) shows through.
    all_msgs = Handler.reader_current() + Handler.appended_messages
    total = len(all_msgs)
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
    messages = [dict(m) for m in all_msgs[start:end]]
    return {
        "messages": messages,
        "header": {"user_name": "You", "chat_metadata": {}},
        "change_token": Handler.append_token or f"v1.{total}.mock",
        "full_token": Handler.full_token,
        "has_more_before": start > 0,
        "has_more_after": end < total,
        "total_items": total,
        "anchor_index": None if before is None else before,
        "anchor_found": True,
    }


# C-PERS: the persona settings blob is mutable so a persist (settings/save) round-trips on the next
# get. "a b.png" carries a space so the gate proves the persona avatar-URL encode fix.
def _default_settings():
    return {
        "main_api": "textgenerationwebui",
        "amount_gen": 64,
        "textgenerationwebui_settings": {
            "type": "llamacpp",
            "server_urls": {"llamacpp": "http://127.0.0.1:5001"},
            "temp": 0.8, "top_p": 0.95, "top_k": 40, "min_p": 0.05, "rep_pen": 1.1,
        },
        "power_user": {
            "personas": {"p1.png": "Alice", "p2.png": "Bob", "a b.png": "Spacey"},
            "persona_descriptions": {
                "p1.png": "First persona", "p2.png": "Second persona", "a b.png": "Persona with a space",
            },
        },
    }


# --- C-CONN: secrets store for the connection panel's API-key field ---------------------------
# DUMMY values only, never a real key. Mirrors src/endpoints/secrets.js: the store is a map of
# secret key -> entry list, one entry active at a time. tabby is seeded so the gate can prove the
# "key already set" path without writing first; llamacpp starts bare to prove "no key set".
MOCK_SECRET_VALUE = "dummy-tabby-key-for-the-gate-0001"


def _mask_secret(value):
    """The masking secrets.js getMaskedValue applies when allowKeysExposure is off."""
    if len(value) <= 10:
        return "*" * 10
    return "*" * 7 + value[-3:]


def _default_secrets():
    return {
        "api_key_tabby": [
            {"id": "sec-tabby-1", "value": MOCK_SECRET_VALUE, "label": "seeded", "active": True},
        ],
    }


def _mock_characters(favs):
    chars = []
    for i in range(60):
        name = f"Char {i:02d} {'Vex' if i % 3 else 'Moon'}"
        if i == 41:
            name = "Rita Recent"
        avatar = f"char{i:02d}.png"
        if i == 12:
            # C-CHAR: an avatar filename is a character's name + .png, so a space is ordinary. This
            # row proves the list percent-encodes the thumbnail src instead of pasting it in raw.
            avatar = "Char 12 Spaced.png"
        entry = {
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
        }
        if i == 30:
            # A card from another tool: the server passes card JSON through UNCOERCED
            # (characters.js:426-430), and serving only well-formed cards hid a bug where ONE of
            # these emptied the whole list. The other 59 pin that it costs only its own fields.
            entry["create_date"] = 1700000000000
            entry["description"] = None
            entry["chat"] = 42
        chars.append(entry)
    return chars


# ---- C-CARD2 hostile card: the deep /characters/get body for a card another tool wrote. -------------
# Every field here is a shape the server hands over untouched, straight from the PNG's own JSON
# (characters.js:426-430). `avatar` and `json_data` stay well-formed because the SERVER sets those.
# The value of a plain multipart text field, for asserting what an upload actually carried.
def _multipart_value(raw, field):
    m = re.search(r'name="' + re.escape(field) + r'"\r?\n\r?\n(.*?)\r?\n--', raw, re.S)
    return m.group(1) if m else None


# The uploaded file's name, which is what the server names a background after (sanitize of
# request.file.originalname, backgrounds.js:144). Empty unless the part is BOTH the right field
# and an actual file, which is the multer contract the real handler 400s on.
def _multipart_filename(raw, field):
    m = re.search(r'name="' + re.escape(field) + r'"; filename="([^"]*)"', raw)
    return m.group(1) if m and m.group(1) else None


def _hostile_card(avatar):
    return {
        "name": None,
        "description": 42,
        "personality": ["a", "b"],
        "scenario": {"x": 1},
        "first_mes": True,
        "mes_example": None,
        "tags": "solo, mystery",
        "chat": 1700000000000,
        "create_date": 1700000000000,
        "fav": "true",
        "talkativeness": "0.9",
        "json_data": json.dumps({"name": avatar, "data": {"character_book": {"entries": []}}}),
        "data": {
            "creator_notes": None,
            "system_prompt": 7,
            "creator": "someone",
            "character_version": 1.2,
            "alternate_greetings": ["real one", 99, None],
            "extensions": {
                "world": None,
                "depth_prompt": {"prompt": None, "depth": "3", "role": 5},
            },
        },
    }


# ---- C-HOME recent-chats fixture: ChatInfo[] as /api/chats/recent returns. Character chats carry an
# avatar; the group chat carries `group` and no avatar, so the client filters it out of the v1 list. ----
def _mock_recent():
    # last_mes is typed {number|string} (src/endpoints/chats.js:369,380) and ALL THREE shapes below
    # are real, so the fixture serves all three: an ISO string (:403 send_date, every modern chat),
    # SillyTavern's own humanized format (src/util.js:538, carried by legacy chat files' send_date),
    # and a bare NUMBER (:450, the empty-chat path). Serving only ISO hid two live client bugs.
    def iso(ago_ms):
        dt = datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(milliseconds=ago_ms)
        return dt.strftime("%Y-%m-%dT%H:%M:%S.") + f"{dt.microsecond // 1000:03d}Z"

    def humanized(ago_ms):
        # util.js humanizedDateTime writes the WRITER's local clock with no zone; the fixture uses UTC
        # so the gate's expectation matches the client, which reads a zone-less stamp as UTC.
        dt = datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(milliseconds=ago_ms)
        return (f"{dt.year:04d}-{dt.month:02d}-{dt.day:02d}@{dt.hour:02d}h{dt.minute:02d}m"
                f"{dt.second:02d}s{dt.microsecond // 1000:03d}ms")

    def epoch_ms(ago_ms):
        return int(time.time() * 1000) - ago_ms

    return [
        {"file_name": "Rita Recent - 2026-07-14.jsonl", "avatar": "char41.png",
         "mes": "The harbor lights are on again tonight.", "last_mes": iso(5 * 60 * 1000),
         "file_size": "4 kB", "chat_items": 12},
        # Legacy chat file: send_date is util.js's humanized format, not ISO.
        {"file_name": "Char 05 Vex - 2026-07-13.jsonl", "avatar": "char05.png",
         "mes": "Let us take the eastern road while the tide is low.", "last_mes": humanized(3 * 60 * 60 * 1000),
         "file_size": "2 kB", "chat_items": 6},
        # The empty-chat path (chats.js:450): last_mes is a NUMBER and the preview is the placeholder.
        # Typed as a string on the client, this row alone failed the whole array parse.
        {"file_name": "Char 06 Vex - 2026-07-10.jsonl", "avatar": "char06.png",
         "mes": "[The chat is empty]", "last_mes": epoch_ms(4 * 24 * 60 * 60 * 1000),
         "file_size": "0 kB", "chat_items": 0},
        {"file_name": "Party - 2026-07-09.jsonl", "group": "grp1",
         "mes": "We should make camp here before nightfall.", "last_mes": iso(6 * 24 * 60 * 60 * 1000),
         "file_size": "3 kB", "chat_items": 8},
    ]


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
        "full_token": f"undo-full-{Handler.undo_token}",
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
    # C-BG: the gallery /api/backgrounds/all serves. Mutable, so a delete or rename shows on the next
    # load; "a b.jpg" carries the space that proves the url encode, "loop.webp" is the animated one.
    mock_backgrounds = ["dusk harbor.jpg", "a b.jpg", "loop.webp", "study.png",
                        # C-BG2: see mock_bg_odd. "slow delete.png" is the second-mutation row's file.
                        "odd str.jpg", "odd null.jpg", "slow delete.png"]

    # C-BG2: isAnimated reaches the wire in any json shape the on-disk index holds, because the server
    # JSON.parses it unvalidated and defends only the ABSENT case (image-metadata.js:218,
    # backgrounds.js:30). Typed `bool`, ONE of these emptied the whole gallery.
    mock_bg_odd = {"odd str.jpg": "true", "odd null.jpg": None}

    # C-BG2: the delete that stays in flight long enough for a second mutation to land during it. The
    # dialog blocks only while it is up; the request outlives it, and that window is where a second
    # click used to be dropped in silence.
    mock_bg_slow_delete = "slow delete.png"

    @staticmethod
    def mock_bg_entry(f):
        if f in Handler.mock_bg_odd:
            return {"filename": f, "isAnimated": Handler.mock_bg_odd[f]}
        return {"filename": f, "isAnimated": f.endswith(".webp")}
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
    # C-CARD: the last /characters/edit body, and the card /characters/get serves once one is saved.
    saved_edit = None
    saved_card = None
    # C-CARD2: armed via /dev/arm-hostile-card, so /characters/get serves a card another tool wrote.
    hostile_card = False
    # C-CARD2: what the last /characters/edit-avatar multipart body actually carried.
    avatar_post = None
    # C-CARD2, for C-BG2: the same, for the last /backgrounds/upload body.
    bg_upload = None
    get_count = 0
    # History-prefetch 409: armed once via /dev/arm-get-409, fires on the next prepend GET only, so the
    # scroll-preservation gate can drive the real resync path the mock append 409 cannot reach.
    arm_get_409 = False
    get_409_count = 0
    # C-HOME: armed via /dev/arm-recent-empty so the home landing's empty state can be driven.
    recent_empty = False
    # Undo fixture state (C4): the mutable current chat and its optimistic-concurrency token.
    undo_chat = None
    undo_token = "utok-0"
    # C-PERS: mutable settings blob so a persona persist (settings/save) shows on the next get.
    persona_settings = None
    # C-CHAR: the avatar the last /api/characters/duplicate named, read back by /dev/duplicated.
    duplicated_avatar = None

    @classmethod
    def settings_blob(cls):
        if cls.persona_settings is None:
            cls.persona_settings = _default_settings()
        return cls.persona_settings

    # C-CONN: mutable secrets store so a key write/delete round-trips on the next read.
    secrets = None

    # C-CONN: armed via /dev/arm-keys-exposed to model config allowKeysExposure=true, where
    # secrets.js getMaskedValue returns the RAW key. The client's own re-mask is then the only guard
    # between a live key and the DOM, so the gate has to drive this path to test that guard at all.
    keys_exposed = False

    @classmethod
    def secrets_store(cls):
        if cls.secrets is None:
            cls.secrets = _default_secrets()
        return cls.secrets

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

    # Reader-chat mutation state (T0): a concrete mutable 300-message file so edit/delete/move by
    # ABSOLUTE index prove the client never corrupts above-window history. full_token = whole-file version.
    reader_msgs = None
    full_token = "full-v0"
    full_ver = 0

    @classmethod
    def reader_current(cls):
        if cls.reader_msgs is None:
            cls.reader_msgs = []
            for i in range(MOCK_CHAT_TOTAL):
                is_user = (i % 2 == 1)
                cls.reader_msgs.append({
                    "name": "You" if is_user else "Rita Recent",
                    "is_user": is_user,
                    "is_system": False,
                    "mes": f"History message {i} in the reverse-lazy reader chat.",
                })
        return cls.reader_msgs

    @classmethod
    def bump_full_token(cls):
        cls.full_ver += 1
        cls.full_token = f"full-v{cls.full_ver}"
        cls.append_token = f"v1.{len(cls.reader_current()) + len(cls.appended_messages)}.mut{cls.full_ver}"
        return cls.full_token

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
            # C-CONN: seed the configured textgen type so the gate can tell a reflected mined type
            # from the client's own default (the fixture blob's type IS the default).
            if self.path.startswith("/dev/conn-type"):
                params = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
                api_type = params.get("t", ["llamacpp"])[0]
                textgen = Handler.settings_blob().setdefault("textgenerationwebui_settings", {})
                textgen["type"] = api_type
                textgen.setdefault("server_urls", {})[api_type] = f"http://127.0.0.1:5001/{api_type}"
                return self.mock_json({"ok": True, "type": api_type})
            if self.path.startswith("/dev/state"):
                return self.mock_json({
                    "recorded_connection": Handler.recorded_connection,
                    "last_generate_server": Handler.last_generate_server,
                    "last_generate_prompt": Handler.last_generate_prompt,  # J1 invariant-2
                    "appended": Handler.appended_messages,
                    "append_409_count": Handler.append_409_count,
                    "get_count": Handler.get_count,
                    "get_409_count": Handler.get_409_count,
                    "persona_settings": Handler.persona_settings,  # C-PERS
                    "secrets": Handler.secrets,  # C-CONN
                    "duplicated_avatar": Handler.duplicated_avatar,  # C-CHAR
                    "card_edit": Handler.saved_edit,  # C-CARD
                    "avatar_post": Handler.avatar_post,  # C-CARD2
                    "bg_upload": Handler.bg_upload,  # C-CARD2, for C-BG2
                    "full_token": Handler.full_token,
                    "reader_total": len(Handler.reader_current()),
                    "reader_above_probe": Handler.reader_current()[0]["mes"],
                })
            # C-CONN: model allowKeysExposure=true, so /api/secrets/read hands back raw keys.
            if self.path.startswith("/dev/arm-keys-exposed"):
                Handler.keys_exposed = True
                return self.mock_json({"ok": True, "keys_exposed": True})
            if self.path.startswith("/dev/arm-get-409"):
                Handler.arm_get_409 = True
                return self.mock_json({"armed": True})
            if self.path.startswith("/dev/arm-recent-empty"):
                Handler.recent_empty = True
                return self.mock_json({"armed": True})
            # C-CARD2: serve a card written by another tool from /characters/get. A fixture that only
            # ever serves the shape we expect tests our own reading of the server, not the server.
            if self.path.startswith("/dev/arm-hostile-card"):
                Handler.hostile_card = True
                Handler.saved_card = None
                return self.mock_json({"armed": True})
            if self.path.startswith("/dev/reader-at"):
                params = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
                i = int(params.get("i", ["-1"])[0])
                reader = Handler.reader_current()
                return self.mock_json({"mes": reader[i]["mes"] if 0 <= i < len(reader) else None, "total": len(reader)})
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
        if path == "/api/chats/recent":
            return self.mock_json([] if Handler.recent_empty else _mock_recent())
        if path == "/api/settings/get":
            return self.mock_json({"settings": json.dumps(Handler.settings_blob())})
        if path == "/api/settings/save":
            # C-PERS: merge the posted settings so a persona persist round-trips on the next get.
            if isinstance(req, dict):
                Handler.settings_blob().update(req)
            return self.mock_json({})
        if path == "/api/avatars/upload":
            # C-PERS: the multipart body is not parsed here; ack with a stored filename.
            return self.mock_json({"path": "persona-uploaded.png"})
        if path == "/api/avatars/delete":
            # C-PERS: ack the avatar delete; the client then removes the settings entry.
            return self.mock_json({"result": "ok"})
        # C-CHAR: duplicate is the one row action with no native dialog in front of it, so it is the
        # one the gate can drive end to end. The client refetches /all on success.
        if path == "/api/characters/duplicate":
            Handler.duplicated_avatar = req.get("avatar_url")
            return self.mock_json({"path": "duplicated.png"})
        # C-CARD2, for C-BG2: same global multer, so the same field-name contract. The real handler
        # 400s on !request.file, names the file from request.file.originalname and answers with the
        # sanitized name as PLAIN TEXT, not JSON (backgrounds.js:141-155). Only the server knows the
        # final name, which is why the panel re-fetches /all rather than trusting what it sent.
        if path == "/api/backgrounds/upload":
            raw = body.decode("utf-8", "replace") if body else ""
            name = _multipart_filename(raw, "avatar")
            Handler.bg_upload = {"field_avatar": 'name="avatar"' in raw, "filename": name, "bytes": len(raw)}
            if not name:
                return self.mock_status(400, "Error: no file uploaded")
            if name not in Handler.mock_backgrounds:
                Handler.mock_backgrounds.append(name)
            return self.mock_text(200, name)
        if path == "/api/characters/edit-avatar":
            # multer is mounted globally as .single('avatar') and the handler 400s on !request.file
            # (characters.js:1234), so the FIELD NAME is the contract and this mock holds it: a body
            # naming the file anything else gets the same 400 the real server would send.
            raw = body.decode("utf-8", "replace") if body else ""
            Handler.avatar_post = {
                "field_avatar": 'name="avatar"' in raw,
                "avatar_url": _multipart_value(raw, "avatar_url"),
                "bytes": len(raw),
            }
            if not Handler.avatar_post["field_avatar"]:
                return self.mock_status(400, "Error: no file uploaded")
            return self.mock_json({"ok": True})
        if path == "/api/characters/get":
            # C-CARD: the three original keys are what char_api's DeepCard reads for the prompt and
            # must keep their values; everything below is the rest of the deep card the editor loads,
            # shaped as processCharacter returns it (top-level v1 mirror + data.* + json_data).
            avatar = req.get("avatar_url", "char")
            if Handler.hostile_card:
                return self.mock_json(_hostile_card(avatar))
            if Handler.saved_card is not None:
                return self.mock_json(Handler.saved_card)
            return self.mock_json({
                "name": avatar,
                "personality": "curious and warm",
                "scenario": "a quiet harbor at dusk",
                "mes_example": "<START>\n{{user}}: hello\n{{char}}: well met",
                "description": "a lighthouse keeper who reads the weather",
                "first_mes": "The lamp is lit. You are late.",
                "fav": True,
                "talkativeness": 0.7,
                "tags": ["keeper", "coastal"],
                "chat": f"{avatar} - 2026-01-01",
                "create_date": "2026-01-01T00:00:00.000Z",
                "json_data": json.dumps({"name": avatar, "data": {"character_book": {"entries": []}}}),
                "data": {
                    "creator_notes": "for the harbour arc",
                    "system_prompt": "",
                    "post_history_instructions": "",
                    "creator": "jaidaken",
                    "character_version": "1.2",
                    "alternate_greetings": ["The fog is in.", "Mind the step."],
                    "extensions": {
                        "world": "",
                        "depth_prompt": {"prompt": "keep the lamp burning", "depth": 4, "role": "system"},
                    },
                },
            })
        if path == "/api/characters/edit":
            # C-CARD: store the posted body and serve it back from /get, so the gate proves a real
            # round-trip (edit -> save -> reload shows the saved text) rather than a local echo.
            Handler.saved_edit = req
            saved = dict(Handler.saved_card or {})
            saved.update({
                "name": req.get("ch_name", ""),
                "description": req.get("description", ""),
                "personality": req.get("personality", ""),
                "scenario": req.get("scenario", ""),
                "first_mes": req.get("first_mes", ""),
                "mes_example": req.get("mes_example", ""),
                "fav": req.get("fav") == "true",
                "talkativeness": req.get("talkativeness", 0.5),
                "tags": [t.strip() for t in str(req.get("tags", "")).split(",") if t.strip()],
                "chat": req.get("chat", ""),
                "create_date": req.get("create_date", ""),
                "json_data": req.get("json_data", ""),
                "data": {
                    "creator_notes": req.get("creator_notes", ""),
                    "system_prompt": req.get("system_prompt", ""),
                    "post_history_instructions": req.get("post_history_instructions", ""),
                    "creator": req.get("creator", ""),
                    "character_version": req.get("character_version", ""),
                    "alternate_greetings": req.get("alternate_greetings", []),
                    "extensions": {
                        "world": req.get("world", ""),
                        "depth_prompt": {
                            "prompt": req.get("depth_prompt_prompt", ""),
                            "depth": req.get("depth_prompt_depth", 4),
                            "role": req.get("depth_prompt_role", "system"),
                        },
                    },
                },
            })
            Handler.saved_card = saved
            return self.mock_json({"ok": True})
        if path == "/api/backends/text-completions/status":
            return self.mock_json({"result": "mock-model", "data": [{"id": "mock-model"}]})
        if path == "/api/settings/set-connection":
            Handler.recorded_connection = {"api_type": req.get("api_type"), "api_server": req.get("api_server")}
            return self.mock_json({"ok": True, "connection": Handler.recorded_connection})
        # --- C-CONN: secrets routes, contract-faithful to src/endpoints/secrets.js ---
        if path == "/api/secrets/read":
            # allowKeysExposure=true skips the server-side mask entirely (secrets.js getMaskedValue).
            expose = Handler.keys_exposed
            return self.mock_json({
                key: [
                    {
                        "id": e["id"],
                        "value": e["value"] if expose else _mask_secret(e["value"]),
                        "label": e["label"],
                        "active": e["active"],
                    }
                    for e in entries
                ]
                for key, entries in Handler.secrets_store().items()
            })
        if path == "/api/secrets/write":
            key, value = req.get("key"), req.get("value")
            if not key or not isinstance(value, str):
                return self.mock_status(400, {"error": "Invalid key or value"})
            entries = Handler.secrets_store().setdefault(key, [])
            for entry in entries:
                entry["active"] = False
            new_id = f"sec-{key}-{len(entries) + 1}"
            entries.append({"id": new_id, "value": value, "label": req.get("label") or "Unlabeled", "active": True})
            return self.mock_json({"id": new_id})
        if path == "/api/secrets/delete":
            key, secret_id = req.get("key"), req.get("id")
            if not key:
                return self.mock_status(400, {"error": "Key and ID are required"})
            entries = Handler.secrets_store().get(key) or []
            for i, entry in enumerate(entries):
                hit = (entry["id"] == secret_id) if secret_id else entry["active"]
                if hit:
                    entries.pop(i)
                    break
            if entries and not any(e["active"] for e in entries):
                entries[0]["active"] = True
            if not entries:
                Handler.secrets_store().pop(key, None)
            # The real route answers 204, so it carries no body.
            self.send_response(204)
            self.end_headers()
            return
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
            # Fire an armed history-prefetch 409 on a prepend GET only (before_index set); the resync's
            # own tail reload carries no before_index, so it refetches cleanly after the stale page.
            if Handler.arm_get_409 and isinstance(req.get("before_index"), int):
                Handler.arm_get_409 = False
                Handler.get_409_count += 1
                return self.mock_status(409, {"error": "stale", "change_token": Handler.append_token or f"v1.{MOCK_CHAT_TOTAL}.mock"})
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
        if path.startswith("/api/chats/message/"):
            return self._mock_message_mutation(path.rsplit("/", 1)[-1], req)
        # ===== C-BG: backgrounds (append-only zone) =====
        # Stateful, so a delete/rename shows on the next /all and the gate's server-authoritative
        # rows are non-vacuous. The real delete/rename answer the text "ok"; the client reads only
        # the status, so a json body stands in for it here.
        if path == "/api/backgrounds/all":
            return self.mock_json({
                "images": [Handler.mock_bg_entry(f) for f in Handler.mock_backgrounds],
                "config": {"width": 160, "height": 90},
            })
        if path == "/api/backgrounds/delete":
            name = req.get("bg")
            if name not in Handler.mock_backgrounds:
                return self.mock_status(400, {"error": "not found"})
            # C-BG2: hold this one open so a second mutation lands while it is still on the wire.
            if name == Handler.mock_bg_slow_delete:
                time.sleep(1.5)
            Handler.mock_backgrounds.remove(name)
            return self.mock_json({"ok": True})
        if path == "/api/backgrounds/rename":
            old, new = req.get("old_bg"), req.get("new_bg")
            if old not in Handler.mock_backgrounds:
                return self.mock_status(400, {"error": "not found"})
            if new in Handler.mock_backgrounds:
                return self.mock_status(400, {"error": "exists"})
            Handler.mock_backgrounds[Handler.mock_backgrounds.index(old)] = new
            return self.mock_json({"ok": True})
        # Every other API POST (create/rename/settings-save/...) acknowledges without state.
        return self.mock_json({})

    def _mock_message_mutation(self, op, req):
        """Message mutation on the reader file by ABSOLUTE index. Presenting anything but the whole-file
        token 409s (proves the client sends full_token, not the tail token). Applying at the absolute
        index and re-serving proves the client targets the right message, never one above the window."""
        reader = Handler.reader_current()
        token = req.get("change_token")
        if not isinstance(token, str) or token != Handler.full_token:
            return self.mock_status(409, {"error": "version_mismatch", "change_token": Handler.full_token})
        idx = req.get("index")
        if not (isinstance(idx, int) and 0 <= idx < len(reader)):
            return self.mock_status(400, {"error": "target_not_found"})
        if op == "edit":
            reader[idx]["mes"] = req.get("mes", reader[idx]["mes"])
        elif op == "delete":
            reader.pop(idx)
        elif op == "hide":
            reader[idx]["is_system"] = not reader[idx].get("is_system", False)
        elif op == "move":
            j = idx - 1 if req.get("direction") == "up" else idx + 1
            if 0 <= j < len(reader):
                reader[idx], reader[j] = reader[j], reader[idx]
        else:
            return self.mock_status(404, {"error": "unknown_op"})
        Handler.bump_full_token()
        return self.mock_json({
            "ok": True,
            "change_token": Handler.full_token,
            "tail_token": Handler.append_token,
            "affected_cf_id": f"cf-{idx}",
            "index": idx,
            "total_items": len(reader) + len(Handler.appended_messages),
        })

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

    # C-CARD2: /api/backgrounds/upload answers `response.send(filename)`, a bare string, so a mock
    # that wrapped it in JSON would be testing a contract the server does not have.
    def mock_text(self, status, text):
        data = text.encode()
        self.send_response(status)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(data)

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
        # Wait in SLICES, never bare: a signal's Python callback runs on the main thread's eval loop,
        # and an untimed wait parks that thread in a futex where it never gets there (SIGTERM ignored
        # forever -> `timeout` blocks on it -> the orphan holds its port serving a STALE dist).
        while not stopping.wait(0.25):
            pass
        httpd.shutdown()

    return 0


if __name__ == "__main__":
    sys.exit(main())
