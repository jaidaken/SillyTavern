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
import hashlib  # w3-grp
import http.server
import json
import os
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
        # C-CFG: the author's note lives in the chat's own header. note_depth is the STRING "2" so the
        # gate proves the tolerant number parse; the client must still read a depth of 2.
        "header": {"user_name": "You", "chat_metadata": Handler.chat_metadata()},
        "change_token": Handler.append_token or f"v1.{total}.mock",
        "full_token": Handler.full_token,
        "has_more_before": start > 0,
        "has_more_after": end < total,
        "total_items": total,
        "anchor_index": None if before is None else before,
        "anchor_found": True,
    }


# C-PRE-SAM: the real server runs the preset name through `sanitize-filename` (presets.js:44) and
# 400s when the result is EMPTY, so a name the CLIENT happily accepts can still be rejected, and one
# it accepts can be written under a DIFFERENT name. Modelling it is what lets the gate drive both:
# a mock that only serves the happy shape tests itself. These are sanitize-filename's own regexes.
_ILLEGAL_RE = re.compile(r'[\/\?<>\\:\*\|"]')
_CONTROL_RE = re.compile(r'[\x00-\x1f\x80-\x9f]')
_RESERVED_RE = re.compile(r'^\.+$')
_WINDOWS_RESERVED_RE = re.compile(r'^(con|prn|aux|nul|com[0-9]|lpt[0-9])(\..*)?$', re.I)
_WINDOWS_TRAILING_RE = re.compile(r'[\. ]+$')


def _sanitize_filename(name):
    if not isinstance(name, str):
        return ""
    out = _ILLEGAL_RE.sub("", name)
    out = _CONTROL_RE.sub("", out)
    out = _RESERVED_RE.sub("", out)
    out = _WINDOWS_RESERVED_RE.sub("", out)
    out = _WINDOWS_TRAILING_RE.sub("", out)
    return out.encode("utf-8")[:255].decode("utf-8", "ignore")


# C-PRE-SAM: the sampler presets, as PARALLEL ARRAYS of (name, RAW FILE TEXT) exactly as the real
# server builds them (src/endpoints/settings.js:100-113 pushes the untouched file text after a
# JSON.parse that only validates). They are SIBLINGS of `settings` in the /api/settings/get envelope,
# not keys inside the settings string.
#
# These are user-writable files, so the fixture is deliberately not all well-formed: a fixture that
# only served good presets would test itself, not the parse. In order the entries are: a real shipped
# shape; a rich preset with keys the panel does not model (proves a save keeps them); one carrying the
# dials under the PRESET spelling genamt/max_length; one whose every field is a different wrong shape;
# one whose body is valid JSON but not an object; and one whose NAME is not a string.
def _preset_files():
    return [
        # Deterministic.json's real shape: the five samplers, no genamt, no max_length.
        ("Deterministic", '{"temp":0,"top_p":0,"top_k":1,"min_p":0,"rep_pen":1,"tfs":1,"typical_p":1}'),
        # Extra keys the panel has no control for. A save based on this must not strip them.
        ("Big O", '{"temp":0.87,"top_p":0.99,"top_k":100,"min_p":0.05,"rep_pen":1.05,'
                  '"tfs":0.68,"dry_multiplier":0.8,"add_bos_token":true,"sampler_order":[6,0,1,3,4,2,5]}'),
        # What the classic client writes on its own save (preset-manager.js:739-740). It also carries
        # `preset` (a file naming itself) and the CONNECTION keys a hand-edit could leave in: picking
        # it must not touch the live backend, and saving from it must not carry `preset` through.
        ("Classic Saved", '{"temp":0.66,"top_k":20,"genamt":384,"max_length":32768,'
                          '"preset":"Some Other Name","type":"koboldcpp",'
                          '"server_urls":{"koboldcpp":"http://evil.example:9999"}}'),
        # HOSTILE. temp is a quoted number (a hand-edit: still a number, so it must apply), and every
        # other sampler is a shape that is not a number at all. Each bad field must cost ONLY itself,
        # and this preset must still appear in the list.
        # `preset` is here too, because this is the one a save is based on: a file that names itself
        # must not carry that name through into the saved file.
        ("Hostile Shapes", '{"temp":"0.55","top_p":null,"top_k":{"nested":1},"min_p":true,'
                           '"rep_pen":"warm","genamt":[512],"max_length":"lots",'
                           '"preset":"Some Other Name","tfs":0.42}'),
        # Valid JSON, not an object: it can never apply a sampler, so it is dropped from the list.
        ("Broken", '42'),
        # A name that is not a string. The server would not write this, a hand-edit could.
        (41, '{"temp":0.4}'),
    ]


def _preset_arrays():
    files = _preset_files()
    return {
        "textgenerationwebui_preset_names": [name for name, _ in files],
        "textgenerationwebui_presets": [body for _, body in files],
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
            # C-PRE-SAM: the classic client's own selected-preset key (textgen-settings.js:379). The
            # picker must open on THIS name. Naming a preset does NOT apply it: the live sampler
            # values above are the truth on load, which is why C-CFG-1 still reads temp 0.80.
            "preset": "Big O",
        },
        "power_user": {
            "personas": {"p1.png": "Alice", "p2.png": "Bob", "a b.png": "Spacey"},
            "persona_descriptions": {
                "p1.png": "First persona", "p2.png": "Second persona", "a b.png": "Persona with a space",
            },
            # C-CFG: the real ChatML shape, so the gate reads the templates the client actually ships
            # against. `enabled` is the STRING "true" and `first_output_sequence` is null on purpose:
            # this blob is written by the classic client and by hand, and a hostile field must cost
            # THAT FIELD, never the whole template (the shape that emptied two lists already).
            "instruct": {
                "enabled": "true",
                "name": "ChatML",
                "input_sequence": "<|im_start|>user",
                "output_sequence": "<|im_start|>assistant",
                "system_sequence": "<|im_start|>system",
                "stop_sequence": "<|im_end|>",
                "input_suffix": "<|im_end|>\n",
                "output_suffix": "<|im_end|>\n",
                "system_suffix": "<|im_end|>\n",
                "first_output_sequence": None,
                "story_string_prefix": "<|im_start|>system",
                "story_string_suffix": "<|im_end|>\n",
                "wrap": True,
                "macro": True,
                "names_behavior": "none",
                "system_same_as_user": False,
            },
            "context": {
                "name": "ChatML",
                # w3-wi-engine: carries {{wiBefore}}/{{wiAfter}} like every shipped context preset
                # (default/content/presets/context/ChatML.json); without a slot stock DROPS wi.
                "story_string": "{{#if system}}{{system}}\n{{/if}}{{#if wiBefore}}{{wiBefore}}\n{{/if}}{{#if description}}{{description}}\n{{/if}}{{#if personality}}{{personality}}\n{{/if}}{{#if scenario}}{{scenario}}\n{{/if}}{{#if wiAfter}}{{wiAfter}}\n{{/if}}{{#if persona}}{{persona}}\n{{/if}}{{#if anchorAfter}}{{anchorAfter}}\n{{/if}}{{trim}}",
                "chat_start": "",
                "example_separator": "***",
                "story_string_position": 0,
            },
            # A1: the global main/system prompt. Feeds the story string's {{system}} slot; the client
            # must source it into every generate body (it went out empty before the fix).
            "sysprompt": {"enabled": True, "content": "SYSPROMPT PROBE stay in scene."},
        },
    }


# --- C-PRE-TPL: the instruct/context preset library -------------------------------------------
# These arrive as SIBLINGS of the settings string in the /api/settings/get response, not inside it
# (settings.js:429 `response.send({ settings, ...payload })`), so they are served that way here.
#
# The library is deliberately NOT all well-formed. These files are user-writable, other tools write
# them, and the server validates only that a file is parseable JSON, never its shape: a fixture that
# served only tidy objects would test itself. So the arrays below carry a hostile preset, a
# non-object element, and a nameless one. The bar: a bad FIELD costs that field, a bad PRESET costs
# that preset, and every other preset still lists and still applies.
def _instruct_presets():
    return [
        # The one the settings blob is already on, byte-shaped like the shipped ChatML.json (which
        # carries NO `enabled` key: it is a user toggle, not a template property).
        {
            "name": "ChatML",
            "input_sequence": "<|im_start|>user",
            "output_sequence": "<|im_start|>assistant",
            "system_sequence": "<|im_start|>system",
            "stop_sequence": "<|im_end|>",
            "input_suffix": "<|im_end|>\n",
            "output_suffix": "<|im_end|>\n",
            "system_suffix": "<|im_end|>\n",
            "story_string_prefix": "<|im_start|>system",
            "story_string_suffix": "<|im_end|>\n",
            "wrap": True,
            "macro": True,
            "names_behavior": "none",
            "system_same_as_user": False,
        },
        # A genuinely different shape, so picking it visibly reshapes the prompt rather than
        # re-applying what was already live.
        #
        # SHIPPED-SHAPED ON PURPOSE: it carries all 23 keys of the real Alpaca.json, including the 7
        # this client does not model. Until 2026-07-16 it carried only the 14 modelled ones, and a
        # fixture with no unmodelled fields CANNOT EXPRESS the defect that saving deletes them: every
        # save row passed while a real user's round trip through the panel silently reverted
        # `sequences_as_stop_strings` (true in 37 of the 38 shipped presets) and dropped the alignment
        # message. Values are the real file's, except `activation_regex`, which is "" in all 38.
        {
            "name": "Alpaca",
            "input_sequence": "### Instruction:",
            "output_sequence": "### Response:",
            "system_sequence": "### System:",
            "stop_sequence": "### Instruction:",
            "input_suffix": "",
            "output_suffix": "",
            "system_suffix": "",
            "first_output_sequence": "",
            "last_output_sequence": "",
            "story_string_prefix": "",
            "story_string_suffix": "",
            "wrap": True,
            "macro": True,
            "names_behavior": "none",
            "system_same_as_user": False,
            "activation_regex": "",
            "skip_examples": False,
            "user_alignment_message": "Let's get started. Please respond based on the information and instructions provided above.",
            "last_system_sequence": "",
            "first_input_sequence": "",
            "last_input_sequence": "",
            "sequences_as_stop_strings": True,
        },
        # HOSTILE. Every field here is a shape the struct does not expect, next to two that are
        # perfectly good. The good ones must still apply and this preset must not cost the others.
        {
            "name": "Hostile",
            "input_sequence": "<|hostile_user|>",      # good: must reach the prompt
            "output_sequence": "<|hostile_bot|>",      # good: must reach the prompt
            "output_suffix": None,                     # null where a string belongs -> costs itself
            "system_sequence": ["nope"],               # array where a string belongs -> costs itself
            "stop_sequence": {"deep": "er"},           # object where a string belongs -> costs itself
            "wrap": "yes",                             # unparseable bool string -> keeps its default
            "names_behavior": 42,                      # number where an enum belongs -> keeps default
            "activation_regex": {"unmodelled": True},  # a field this client does not model at all
        },
        # A non-object element. The server JSON.parses each file without validating it, so an array
        # can hold anything at all. It must cost itself and nothing else.
        "this is not a preset object",
        # Nameless: a preset nobody can name is a preset nobody can pick, so it is skipped. It must
        # not take the pickable ones down with it.
        {"input_sequence": "<|orphan|>"},
    ]


def _context_presets():
    return [
        # Carries the migration marker AND both anchors, exactly like every shipped context preset.
        {
            "name": "ChatML",
            # w3-wi-engine: wi slots added, mirroring the real shipped ChatML context preset.
            "story_string": "{{#if system}}{{system}}\n{{/if}}{{#if wiBefore}}{{wiBefore}}\n{{/if}}{{#if description}}{{description}}\n{{/if}}{{#if wiAfter}}{{wiAfter}}\n{{/if}}{{#if anchorBefore}}{{anchorBefore}}\n{{/if}}{{#if anchorAfter}}{{anchorAfter}}\n{{/if}}{{trim}}",
            "chat_start": "",
            "example_separator": "***",
            "story_string_position": 0,
        },
        # THE TRAP, and it is the whole reason this fixture exists. A story string with NO anchors and
        # NO story_string_position: exactly what a hand-written preset, or one from an older tool,
        # looks like. Picking it must run the same one-time anchor migration the classic client runs
        # on a picked preset (power-user.js:2032), or the author's note that worked a moment ago
        # renders NOWHERE and nothing on screen says why.
        {
            "name": "Unmigrated",
            "story_string": "{{#if description}}{{description}}\n{{/if}}{{#if personality}}{{personality}}\n{{/if}}",
            "chat_start": "",
            "example_separator": "---",
        },
    ]


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
            # w3-reason 3d: card tags for the filter-chip gate rows. Rita + every 10th get one.
            "tags": ["harbor"] if i == 41 else (["night"] if i % 10 == 5 else []),
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


# ===== w3-chatmgr (append-only zone): a stateful per-FILE chat store for one fixture character. =====
# The chat-manager rows need what the global _mock_chat_page cannot give: which FILE a read, an
# append, a rename, a delete, a duplicate or a branch actually touched. char07 is otherwise unused
# by the gate; every other avatar keeps the existing handlers, so the zone is isolated by key.
MGR_AVATAR = "char07.png"
MGR_DEFAULT = "Char 07 Vex - 2026-07-14"


def _mgr_msg(name, is_user, mes):
    return {"name": name, "is_user": is_user, "is_system": False,
            "send_date": 1783700000000, "mes": mes, "extra": {}}


def _mgr_fresh_chats():
    return {
        MGR_DEFAULT: [
            _mgr_msg("You", True, "Shall we pick up where we left off?"),
            _mgr_msg("Char 07 Vex", False, "The default thread continues."),
            _mgr_msg("You", True, "Default thread tail marker."),
        ],
        "old adventure": [
            _mgr_msg("You", True, "Tell me about the peppermint dragon."),
            _mgr_msg("Char 07 Vex", False, "The peppermint dragon sleeps in the candy caves."),
        ],
        "keep me": [
            _mgr_msg("You", True, "Sibling canary line one."),
            _mgr_msg("Char 07 Vex", False, "Sibling canary line two."),
        ],
    }


def _mgr_page(stem, req):
    msgs = [dict(m) for m in Handler.mgr_files().get(stem, [])]
    total = len(msgs)
    return {
        "messages": msgs,
        "header": {"user_name": "You", "chat_metadata": {}},
        "change_token": f"mgr-tail-{stem}-{total}",
        "full_token": f"mgr-full-{stem}-{total}",
        "has_more_before": False,
        "has_more_after": False,
        "total_items": total,
        "anchor_index": None if req.get("before_index") is None else req.get("before_index"),
        "anchor_found": True,
    }


def _mgr_search_rows(query):
    fragments = [f for f in str(query or "").lower().split() if f]
    rows = []
    for stem, msgs in Handler.mgr_files().items():
        haystack = (stem + " " + " ".join(str(m.get("mes", "")) for m in msgs)).lower()
        if fragments and not all(f in haystack for f in fragments):
            continue
        last = msgs[-1] if msgs else None
        rows.append({
            "file_name": stem,
            "file_size": f"{sum(len(str(m.get('mes', ''))) for m in msgs)} B",
            "message_count": len(msgs),
            "last_mes": last["send_date"] if last else int(time.time() * 1000),
            "preview_message": last["mes"] if last else "[The chat is empty]",
        })
    return rows


def _mgr_multipart_file(raw, field):
    # The uploaded file part's CONTENT (the fixture jsonl carries only \n, so \r\n-- ends the part).
    m = re.search(r'name="' + re.escape(field) + r'"; filename="[^"]*"\r?\n(?:[^\r\n]*\r?\n)*?\r?\n(.*?)\r?\n--', raw, re.S)
    return m.group(1) if m else None


def _mgr_parse_jsonl(text):
    lines = [ln for ln in str(text).split("\n") if ln.strip()]
    if not lines:
        return None
    try:
        header = json.loads(lines[0])
    except ValueError:
        return None
    if not any(k in header for k in ("user_name", "name", "chat_metadata")):
        return None
    msgs = []
    for ln in lines[1:]:
        try:
            obj = json.loads(ln)
        except ValueError:
            return None
        msgs.append({"name": obj.get("name", ""), "is_user": bool(obj.get("is_user")),
                     "is_system": bool(obj.get("is_system")), "send_date": obj.get("send_date", 0),
                     "mes": obj.get("mes", ""), "extra": obj.get("extra", {})})
    return msgs


def _mgr_export_text(stem):
    header = {"user_name": "You", "character_name": "Char 07 Vex", "create_date": "2026-07-14", "chat_metadata": {}}
    lines = [json.dumps(header)]
    for m in Handler.mgr_files().get(stem, []):
        lines.append(json.dumps(m))
    return "\n".join(lines)
# ===== end w3-chatmgr module zone =====


class Handler(http.server.SimpleHTTPRequestHandler):
    backend = "http://127.0.0.1:8000"
    dev = False
    mock_api = False
    mock_favs = {}
    # ===== w3-chatmgr (append-only): the fixture store, lazy so each gate run starts fresh. =====
    mgr_chats = None
    mgr_exported = None
    mgr_import_count = 0

    @classmethod
    def mgr_files(cls):
        if cls.mgr_chats is None:
            cls.mgr_chats = _mgr_fresh_chats()
        return cls.mgr_chats
    # ===== end w3-chatmgr class zone =====
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
    # Monotonic, because a row cannot key on the VALUE changing: connect is clicked three times and a
    # second connect may carry an identical payload. W6-7 waits on this landing, not on a clock.
    set_connection_count = 0
    last_generate_server = None
    # J1 invariant-2 gate: the prompt of the last generate, so a gate can prove it spans history
    # beyond the display window.
    last_generate_prompt = None
    # C-CFG: the whole generate body, so a gate can prove a panel sampler and the template's stop
    # sequence actually reach the request rather than only localStorage.
    last_generate_body = None
    # Turns the client appended via /api/chats/append; the mock /get echoes them so a reload shows them.
    appended_messages = []
    append_token = None
    # ===== w3-grp: turns appended with a group_id, kept apart from the solo list so the gate can
    # prove a rotation never cross-writes the solo chat. =====
    group_appended = []
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
    # C-PRE-TPL + C-PRE-SAM: the last /api/presets/save body, read back by /dev/state so a row can
    # assert the real POST contract. ONE attribute: both pickers save through the one route and mean
    # the same thing by it.
    preset_save = None
    # C-PRE-TPL: the context library a save grew.
    saved_context_presets = None
    # C-PRE-SAM: the textgen presets a save wrote, which join the next settings/get list.
    saved_presets = {}
    # C-PRE-SAM: fail /api/settings/get on demand. Armed after boot (boot reads the same endpoint),
    # and PERSISTENT: a one-shot failure ends the refetch loop it is meant to detect.
    settings_fail = False
    settings_get_count = 0
    # C-PRE-SAM: seconds /api/presets/save holds before answering, armed via /dev/arm-preset-save-delay.
    preset_save_delay = 0.0
    # C-CHAR: the avatar the last /api/characters/duplicate named, read back by /dev/duplicated.
    duplicated_avatar = None
    # C-CFG: the open chat's metadata, mutated by /api/chats/metadata so a note save round-trips.
    chat_meta = None
    metadata_stale_once = False
    last_metadata_body = None
    # wi-polish: the GROUP chat's header metadata, its own store so a group write can never leak
    # into the solo chat_meta (the dangerous property the gate rows assert).
    group_meta = None
    # w3-wi: mutable mock lorebooks; gate-lore entry "0" = full stock shape + an unknown
    # futureField, which the T0 row deep-diffs after an editor save.
    wi_books = None
    last_wi_edit = None
    wi_get_log = []  # w3-wi-engine
    card_get_count = 0
    last_card_get = None

    @classmethod
    def worldinfo_books(cls):
        if cls.wi_books is None:
            cls.wi_books = {
                "gate-lore": {
                    "name": "Gate Lore",
                    "entries": {
                        "0": {
                            "uid": 0, "key": ["dragon", "wyrm"], "keysecondary": ["red"],
                            "comment": "the dragon", "content": "Dragons breathe fire.",
                            "constant": False, "vectorized": False, "selective": True,
                            "selectiveLogic": 1, "addMemo": True, "order": 90, "position": 4,
                            "disable": False, "ignoreBudget": False, "excludeRecursion": True,
                            "preventRecursion": False, "matchPersonaDescription": False,
                            "matchCharacterDescription": False, "matchCharacterPersonality": False,
                            "matchCharacterDepthPrompt": False, "matchScenario": False,
                            "matchCreatorNotes": False, "delayUntilRecursion": 0,
                            "probability": 75, "useProbability": True, "depth": 6,
                            "outletName": "", "group": "beasts", "groupOverride": False,
                            "groupWeight": 100, "scanDepth": None, "caseSensitive": None,
                            "matchWholeWords": None, "useGroupScoring": None, "automationId": "",
                            "role": 0, "sticky": 2, "cooldown": 0, "delay": 0, "displayIndex": 0,
                            "triggers": [], "futureField": {"nested": [1, 2, 3]},
                        },
                        "3": {
                            "uid": 3, "key": ["castle"], "keysecondary": [], "comment": "",
                            "content": "The castle stands.", "constant": True, "selective": False,
                            "selectiveLogic": 0, "order": 100, "position": 0, "disable": True,
                            "probability": 100, "useProbability": False, "depth": 4,
                        },
                    },
                    "extensions": {"custom": "kept"},
                },
                "beta-lore": {"name": "Beta Lore", "entries": {}},
            }
        return cls.wi_books

    @classmethod
    def chat_metadata(cls):
        if cls.chat_meta is None:
            # A note the client must read back exactly: in_chat at depth 2, every message.
            cls.chat_meta = {
                "integrity": "mock-integrity",
                "note_prompt": "The tide is coming in.",
                "note_interval": 1,
                "note_depth": "2",
                "note_position": 1,
                "note_role": 0,
                "world_info": "gate-lore",  # w3-wi chat-scope book link
            }
        return cls.chat_meta

    @classmethod
    def group_metadata(cls):
        if cls.group_meta is None:
            cls.group_meta = {}
        return cls.group_meta

    @classmethod
    def settings_blob(cls):
        if cls.persona_settings is None:
            cls.persona_settings = _default_settings()
        return cls.persona_settings

    @classmethod
    def context_presets(cls):
        if cls.saved_context_presets is None:
            cls.saved_context_presets = _context_presets()
        return cls.saved_context_presets

    # C-PRE-SAM: a saved preset shows up in the next list, the way the real server's re-read does.
    @classmethod
    def saved_presets_arrays(cls):
        if not cls.saved_presets:
            return {}
        base = _preset_arrays()
        return {
            "textgenerationwebui_preset_names": base["textgenerationwebui_preset_names"] + list(cls.saved_presets.keys()),
            "textgenerationwebui_presets": base["textgenerationwebui_presets"] + list(cls.saved_presets.values()),
        }

    # C-CONN: mutable secrets store so a key write/delete round-trips on the next read.
    secrets = None

    # C-CONN: armed via /dev/arm-keys-exposed to model config allowKeysExposure=true, where
    # secrets.js getMaskedValue returns the RAW key. The client's own re-mask is then the only guard
    # between a live key and the DOM, so the gate has to drive this path to test that guard at all.
    keys_exposed = False

    # ===== w3-grp: groups roster state (append-only zone) =====
    # Mutable so create/edit/delete round-trip on the next /all. Group ids come from a sequence,
    # not the clock: two creates inside one gate run must never collide the way String(Date.now())
    # can. chat_write_count is the T0 sensor: every POST that can write chat-file state bumps it,
    # and the group gate rows assert it holds still across the whole create/edit/delete cycle.
    mock_groups = []
    group_seq = 0
    chat_write_count = 0

    @classmethod
    def grp_t0_state(cls):
        fp = hashlib.sha1(json.dumps(cls.appended_messages, sort_keys=True).encode()).hexdigest()
        return {"chat_writes": cls.chat_write_count, "fingerprint": fp, "groups": len(cls.mock_groups)}

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
            # w3-reason: the newest assistant turn carries thinking, for the reasoning gate rows.
            for m in reversed(cls.reader_msgs):
                if not m["is_user"]:
                    m["extra"] = {"reasoning": "Weigh the tide tables before answering."}
                    break
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
                    "set_connection_count": Handler.set_connection_count,
                    "last_generate_server": Handler.last_generate_server,
                    "last_generate_prompt": Handler.last_generate_prompt,  # J1 invariant-2
                    "last_generate_body": Handler.last_generate_body,  # C-CFG
                    "preset_save": Handler.preset_save,  # C-PRE-TPL
                    "appended": Handler.appended_messages,
                    "append_409_count": Handler.append_409_count,
                    "get_count": Handler.get_count,
                    "get_409_count": Handler.get_409_count,
                    "persona_settings": Handler.persona_settings,  # C-PERS
                    "preset_save": Handler.preset_save,  # C-PRE-SAM
                    "settings_get_count": Handler.settings_get_count,  # C-PRE-SAM
                    "secrets": Handler.secrets,  # C-CONN
                    "duplicated_avatar": Handler.duplicated_avatar,  # C-CHAR
                    "card_edit": Handler.saved_edit,  # C-CARD
                    "avatar_post": Handler.avatar_post,  # C-CARD2
                    "bg_upload": Handler.bg_upload,  # C-CARD2, for C-BG2
                    "full_token": Handler.full_token,
                    "reader_total": len(Handler.reader_current()),
                    "reader_above_probe": Handler.reader_current()[0]["mes"],
                    "group_appended": Handler.group_appended,  # w3-grp
                    "wi_books": Handler.worldinfo_books(),  # w3-wi
                    "wi_get_log": Handler.wi_get_log,  # w3-wi-engine
                    "settings_context": Handler.settings_blob().get("power_user", {}).get("context"),  # w3-wi-engine
                    "last_wi_edit": Handler.last_wi_edit,  # w3-wi
                    "card_get_count": Handler.card_get_count,  # w3-wi
                    "last_card_get": Handler.last_card_get,  # w3-wi
                    "settings_world_info": Handler.settings_blob().get("world_info_settings"),  # w3-wi
                    "chat_meta": Handler.chat_metadata(),  # wi-polish: solo header store
                    "group_meta": Handler.group_metadata(),  # wi-polish: group header store
                })
            # C-CONN: model allowKeysExposure=true, so /api/secrets/read hands back raw keys.
            # w3-wi: drop a card saved by an earlier section, so /api/characters/get serves the
            # stock card (with its embedded character_book) again.
            if self.path.startswith("/dev/wi-reset-card"):
                Handler.saved_card = None
                Handler.hostile_card = False
                return self.mock_json({"ok": True})
            if self.path.startswith("/dev/arm-keys-exposed"):
                Handler.keys_exposed = True
                return self.mock_json({"ok": True, "keys_exposed": True})
            if self.path.startswith("/dev/arm-get-409"):
                Handler.arm_get_409 = True
                return self.mock_json({"armed": True})
            # C-CFG: what the client's last note save actually sent, and a one-shot 409 arm so the
            # gate can drive the stale path a real concurrent writer would cause.
            if self.path.startswith("/dev/note-save"):
                return self.mock_json(Handler.last_metadata_body or {})
            if self.path.startswith("/dev/chat-metadata"):
                return self.mock_json(Handler.chat_metadata())
            # C-PRE-SAM: arm/disarm the settings failure (see the Handler fields).
            if self.path.startswith("/dev/arm-settings-fail"):
                Handler.settings_fail = True
                return self.mock_json({"armed": True})
            if self.path.startswith("/dev/disarm-settings-fail"):
                Handler.settings_fail = False
                return self.mock_json({"armed": False})
            # C-PRE-SAM: hold a save open so a row can watch the in-flight line paint. A mock that
            # always answers within a millisecond makes the pending state unobservable, and a state
            # no row can see is a state nothing proves renders.
            if self.path.startswith("/dev/arm-preset-save-delay"):
                Handler.preset_save_delay = 1.5
                return self.mock_json({"armed": True, "seconds": Handler.preset_save_delay})
            if self.path.startswith("/dev/disarm-preset-save-delay"):
                Handler.preset_save_delay = 0.0
                return self.mock_json({"armed": False})
            # C-CFG: drop the recorded generate so a gate can prove the NEXT body is the one its own
            # send produced. Without this a completion predicate can match a previous send's text and
            # the row reads an artifact it never caused.
            if self.path.startswith("/dev/clear-generate"):
                Handler.last_generate_body = None
                Handler.last_generate_prompt = None
                return self.mock_json({"cleared": True})
            if self.path.startswith("/dev/arm-metadata-409"):
                Handler.metadata_stale_once = True
                return self.mock_json({"armed": True})
            if self.path.startswith("/dev/arm-recent-empty"):
                Handler.recent_empty = True
                return self.mock_json({"armed": True})
            # w3-grp: the T0 snapshot the group rows compare before/after the create/edit/delete cycle.
            if self.path.startswith("/dev/grp-t0"):
                return self.mock_json(Handler.grp_t0_state())
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
            # ===== w3-chatmgr (append-only): the fixture store, server-side truth for the gate rows. =====
            if self.path.startswith("/dev/mgr-state"):
                return self.mock_json({
                    "files": {stem: [m["mes"] for m in msgs] for stem, msgs in Handler.mgr_files().items()},
                    "exported": Handler.mgr_exported,
                })
            # ===== end w3-chatmgr /dev zone =====
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
        # w3-reason: think tags cut MID-TAG across tokens, so the gate proves the client's buffered
        # boundary split in a real browser. "lantern" stays the first BODY token for the SL rows.
        reply = ["<th", "ink>mull the tides", "</th", "ink>", "lantern "] + [f"w{i} " for i in range(22)] + ["FIN"]
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

        # ===== w3-grp: T0 sensor + groups routes (append-only zone) =====
        # The sensor sits BEFORE route matching so even a chat write the mock only generic-acks
        # still counts as an attempted write.
        if any(path.startswith(p) for p in (
                "/api/chats/append", "/api/chats/save", "/api/chats/message/",
                "/api/chats/rename", "/api/chats/delete", "/api/chats/import",
                "/api/chats/group/save", "/api/chats/group/delete", "/api/chats/group/import",
                "/api/chats/backups/restore")):
            Handler.chat_write_count += 1
        if path == "/api/groups/all":
            return self.mock_json(list(Handler.mock_groups))
        if path == "/api/groups/create":
            Handler.group_seq += 1
            gid = str(1790000000000 + Handler.group_seq)
            group = {
                "id": gid,
                "name": req.get("name", "New Group"),
                "members": req.get("members") or [],
                "avatar_url": req.get("avatar_url"),
                "allow_self_responses": bool(req.get("allow_self_responses")),
                "activation_strategy": req.get("activation_strategy", 0),
                "generation_mode": req.get("generation_mode", 0),
                "disabled_members": req.get("disabled_members") or [],
                "fav": req.get("fav"),
                "chat_id": gid,
                "chats": [gid],
                "auto_mode_delay": req.get("auto_mode_delay", 5),
                "generation_mode_join_prefix": "",
                "generation_mode_join_suffix": "",
                "date_last_chat": 0,
            }
            Handler.mock_groups.append(group)
            return self.mock_json(group)
        if path == "/api/groups/edit":
            gid = req.get("id")
            if not gid:
                return self.mock_status(400, {"error": "no id"})
            for i, g in enumerate(Handler.mock_groups):
                if g.get("id") == gid:
                    Handler.mock_groups[i] = req
                    return self.mock_json({"ok": True})
            # The real route writes the file regardless; an unknown id becomes a new entry.
            Handler.mock_groups.append(req)
            return self.mock_json({"ok": True})
        if path == "/api/groups/delete":
            gid = req.get("id")
            if not gid:
                return self.mock_status(400, {"error": "no id"})
            Handler.mock_groups = [g for g in Handler.mock_groups if g.get("id") != gid]
            return self.mock_json({"ok": True})

        if path == "/csrf-token":
            return self.mock_json({"token": "mock-csrf-token"})
        if path == "/api/characters/all":
            return self.mock_json(_mock_characters(Handler.mock_favs))
        if path == "/api/chats/recent":
            return self.mock_json([] if Handler.recent_empty else _mock_recent())
        if path == "/api/settings/get":
            Handler.settings_get_count += 1
            if Handler.settings_fail:
                return self.mock_status(500, {"error": "settings unavailable"})
            # Every preset array rides the ENVELOPE beside `settings`, never inside it
            # (settings.js:428 `response.send({ settings, ...payload })`).
            return self.mock_json({
                "settings": json.dumps(Handler.settings_blob()),
                "instruct": _instruct_presets(),
                "context": Handler.context_presets(),
                **_preset_arrays(),
                **Handler.saved_presets_arrays(),
            })
        # The real save route (src/endpoints/presets.js:44-60), serving both pickers.
        if path == "/api/presets/save":
            if Handler.preset_save_delay:
                time.sleep(Handler.preset_save_delay)
            # Mirrors presets.js:44-60: sanitize FIRST, 400 when the name empties or the preset is
            # missing, and hand back the name actually written.
            name = _sanitize_filename(req.get("name") if isinstance(req, dict) else None)
            preset = req.get("preset") if isinstance(req, dict) else None
            if not preset or not name:
                return self.mock_status(400, {"error": "name and preset are required"})
            Handler.preset_save = req
            # A saved preset joins the library its apiId names, as the server's re-read of that one
            # directory would. Routed, not shared: an instruct save must not enter the textgen list.
            api_id = req.get("apiId")
            if api_id == "context":
                lib = Handler.context_presets()
                saved = dict(preset)
                saved["name"] = name
                Handler.saved_context_presets = [p for p in lib if p.get("name") != name] + [saved]
            elif api_id == "textgenerationwebui":
                Handler.saved_presets[name] = json.dumps(preset)
            return self.mock_json({"name": name})
        # C-CFG: the chat-metadata member of the descriptor-mutation family. The client sends the note
        # fields plus the FULL change token; the server does the read-modify-write and returns the new
        # token. Mirrors the shape the real route must have (reported to the lead), including the 409.
        if path == "/api/chats/metadata":
            Handler.last_metadata_body = req
            if Handler.metadata_stale_once:
                Handler.metadata_stale_once = False
                Handler.bump_full_token()
                return self.mock_status(409, {"error": "stale", "change_token": Handler.full_token})
            # wi-polish: a group_id body writes the GROUP header store, never the solo one
            # (the real route resolves the ref the same way, chats.js resolveUndoRef).
            is_group_write = isinstance(req, dict) and req.get("group_id")
            meta = Handler.group_metadata() if is_group_write else Handler.chat_metadata()
            # world_info joined the allowlist on main (9bc8ee713); mirrored here for the w3-wi row.
            for key in ("note_prompt", "note_interval", "note_depth", "note_position", "note_role", "world_info"):
                if key in req:
                    meta[key] = req[key]
            Handler.bump_full_token()
            return self.mock_json({
                "ok": True,
                "change_token": Handler.full_token,
                "tail_token": Handler.append_token or "v1.mock",
                "total_items": len(Handler.reader_current()) + len(Handler.appended_messages),
            })
        # w3-wi: the five real worldinfo routes (src/endpoints/worldinfo.js), whole-file semantics.
        if path == "/api/worldinfo/list":
            books = Handler.worldinfo_books()
            return self.mock_json([
                {"file_id": fid, "name": b.get("name", fid), "extensions": b.get("extensions", {})}
                for fid, b in sorted(books.items())
            ])
        if path == "/api/worldinfo/get":
            name = req.get("name") if isinstance(req, dict) else None
            Handler.wi_get_log.append(name)  # w3-wi-engine: which books the client fetched
            book = Handler.worldinfo_books().get(name)
            return self.mock_json(book if book is not None else {"entries": {}})
        if path == "/api/worldinfo/edit":
            data = req.get("data") if isinstance(req, dict) else None
            if not isinstance(req, dict) or not req.get("name") or not isinstance(data, dict) or "entries" not in data:
                return self.mock_status(400, {"error": "Is not a valid world info file"})
            Handler.worldinfo_books()[req["name"]] = data
            Handler.last_wi_edit = req
            return self.mock_json({"ok": True})
        if path == "/api/worldinfo/delete":
            name = req.get("name") if isinstance(req, dict) else None
            if name in Handler.worldinfo_books():
                del Handler.worldinfo_books()[name]
                return self.mock_json({})
            return self.mock_status(500, {"error": "no such book"})
        # w3-wi-engine BEGIN: the sixth real route (src/endpoints/worldinfo.js /import): multipart
        # 'avatar' file, name = the sanitized filename stem, body must carry an entries object.
        if path == "/api/worldinfo/import":
            raw = body.decode("utf-8", "replace") if body else ""
            content = _mgr_multipart_file(raw, "avatar")
            fname = _multipart_filename(raw, "avatar") or "imported.json"
            try:
                book = json.loads(content or "")
                if not isinstance(book, dict) or "entries" not in book:
                    raise ValueError("no entries")
            except ValueError:
                return self.mock_status(400, {"error": "Is not a valid world info file"})
            stem = _sanitize_filename(fname)
            if stem.lower().endswith(".json"):
                stem = stem[:-5]
            if not stem:
                return self.mock_status(400, {"error": "World file must have a name"})
            Handler.worldinfo_books()[stem] = book
            return self.mock_json({"name": stem})
        # w3-wi-engine END
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
            Handler.card_get_count += 1  # w3-wi: the deep-fetch completion signal for the gate
            Handler.last_card_get = avatar
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
                    # A1: a per-card system_prompt override. Carries {{original}} so one prompt-body
                    # assertion proves the card wins AND {{original}} expands to the global sysprompt.
                    "system_prompt": "CARD SAYS {{original}} EXTRA",
                    # A1 jailbreak: the card's post-history instruction, injected as a user turn after
                    # the history. {{char}} proves macro resolution in the injected jailbreak.
                    "post_history_instructions": "JB PROBE reply as {{char}}",
                    "creator": "jaidaken",
                    "character_version": "1.2",
                    "alternate_greetings": ["The fog is in.", "Mind the step."],
                    "extensions": {
                        "world": "",
                        "depth_prompt": {"prompt": "keep the lamp burning", "depth": 4, "role": "system"},
                    },
                    # w3-wi: v2-spec embedded book, converted + surfaced read-only by the WI panel.
                    "character_book": {
                        "name": "Keeper's Book",
                        "entries": [
                            {"keys": ["lighthouse"], "secondary_keys": [], "content": "The lamp never dies.",
                             "enabled": True, "insertion_order": 10, "position": "before_char",
                             "extensions": {"probability": 80, "depth": 3}},
                        ],
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
            Handler.set_connection_count += 1
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
        # ===== w3-chatmgr (append-only zone): per-FILE handlers for the fixture character. Placed
        # BEFORE the generic /api/chats/* handlers so char07 traffic is keyed here; every other
        # avatar falls through unchanged. Guards mirror the real routes (chats.js), not happy paths. =====
        if path == "/api/chats/get" and req.get("avatar_url") == MGR_AVATAR:
            return self.mock_json(_mgr_page(str(req.get("file_name") or ""), req))
        if path == "/api/chats/append" and req.get("avatar_url") == MGR_AVATAR:
            stem = str(req.get("file_name") or "")
            msgs = req.get("messages") or []
            Handler.mgr_files().setdefault(stem, []).extend(dict(m) for m in msgs)
            total = len(Handler.mgr_files()[stem])
            return self.mock_json({"ok": True, "appended": len(msgs), "change_token": f"mgr-tail-{stem}-{total}"})
        if path == "/api/chats/search":
            if req.get("avatar_url") == MGR_AVATAR:
                return self.mock_json(_mgr_search_rows(req.get("query")))
            return self.mock_json([])
        if path == "/api/chats/rename" and req.get("avatar_url") == MGR_AVATAR:
            old = str(req.get("original_file") or "").removesuffix(".jsonl")
            new = str(req.get("renamed_file") or "").removesuffix(".jsonl")
            files = Handler.mgr_files()
            if not old or not new or old not in files or new in files:
                return self.mock_status(400, {"error": True})
            files[new] = files.pop(old)
            return self.mock_json({"ok": True, "sanitizedFileName": new})
        if path == "/api/chats/delete" and req.get("avatar_url") == MGR_AVATAR:
            stem = str(req.get("chatfile") or "").removesuffix(".jsonl")
            files = Handler.mgr_files()
            if stem not in files:
                return self.mock_status(400, {"error": True})
            del files[stem]
            return self.mock_json({"ok": True})
        if path == "/api/chats/duplicate" and req.get("avatar_url") == MGR_AVATAR:
            files = Handler.mgr_files()
            src = str(req.get("file_name") or "")
            dst = str(req.get("new_file_name") or "")
            if not src or not dst:
                return self.mock_status(400, {"error": True})
            if src not in files:
                return self.mock_status(404, {"error": "not_found"})
            if dst in files:
                return self.mock_status(409, {"error": "exists"})
            files[dst] = [dict(m) for m in files[src]]
            return self.mock_json({"ok": True})
        if path == "/api/chats/branch" and req.get("avatar_url") == MGR_AVATAR:
            files = Handler.mgr_files()
            src = str(req.get("file_name") or "")
            dst = str(req.get("new_file_name") or "")
            index = req.get("index")
            if not src or not dst or src not in files:
                return self.mock_status(400, {"error": True})
            if dst in files:
                return self.mock_status(409, {"error": "exists"})
            if not isinstance(index, int) or index < 0 or index >= len(files[src]):
                return self.mock_status(400, {"error": "target_not_found"})
            files[dst] = [dict(m) for m in files[src][: index + 1]]
            return self.mock_json({"ok": True, "total_items": len(files[dst])})
        if path == "/api/chats/export" and req.get("avatar_url") == MGR_AVATAR:
            stem = str(req.get("file") or "").removesuffix(".jsonl")
            if stem not in Handler.mgr_files():
                return self.mock_status(404, {"message": "no such chat"})
            Handler.mgr_exported = stem
            return self.mock_json({"message": "ok", "result": _mgr_export_text(stem)})
        if path == "/api/chats/import":
            raw = body.decode("utf-8", "replace") if body else ""
            if _multipart_value(raw, "avatar_url") != MGR_AVATAR:
                return self.mock_status(400, {"error": True})
            content = _mgr_multipart_file(raw, "avatar")
            msgs = _mgr_parse_jsonl(content) if content is not None else None
            if msgs is None:
                return self.mock_json({"error": True})
            Handler.mgr_import_count += 1
            stem = f"Char 07 Vex - imported {Handler.mgr_import_count}"
            Handler.mgr_files()[stem] = msgs
            return self.mock_json({"res": True, "fileNames": [stem + ".jsonl"]})
        # ===== end w3-chatmgr POST zone =====
        if path == "/api/chats/append":
            msgs = req.get("messages") or []
            # ===== w3-grp: group appends (group_id) land in the group list, never the solo one =====
            if req.get("group_id"):
                Handler.group_appended.extend(msgs)
                return self.mock_json({"ok": True, "appended": len(msgs), "change_token": f"g1.{len(Handler.group_appended)}.mock"})
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
            Handler.last_generate_body = json.dumps(req)  # C-CFG
            return self._mock_generate_stream()
        # ===== w3-grp: the group prompt window, same page shape as solo /get, fed from the group
        # appends so member N's prompt can prove it saw member N-1's reply. =====
        if path == "/api/chats/group/get":
            gmsgs = [dict(m) for m in Handler.group_appended]
            return self.mock_json({
                "messages": gmsgs,
                "header": {"user_name": "You", "chat_metadata": Handler.group_metadata()},
                "change_token": f"g1.{len(gmsgs)}.mock",
                "full_token": "gfull.mock",
                "has_more_before": False,
                "has_more_after": False,
                "total_items": len(gmsgs),
                "anchor_index": None,
                "anchor_found": True,
            })
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
        # shutdown() waits UNTIMED for serve_forever to return, so if that thread is gone or wedged
        # the main thread parks in a futex and the process outlives its own SIGTERM: found one 26min
        # old, wchan=futex_do_wait, SigPnd=0, still holding its port and serving a stale dist to
        # every later run. Bound the graceful path, then leave regardless. A test server that will
        # not die is worse than an abrupt one: the OS reclaims the socket either way.
        closing = threading.Thread(target=httpd.shutdown, daemon=True)
        closing.start()
        closing.join(5)
        sys.stderr.flush()
        os._exit(0)

    return 0


if __name__ == "__main__":
    sys.exit(main())
