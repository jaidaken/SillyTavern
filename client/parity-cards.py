#!/usr/bin/env python3
"""Generate battery character cards for the prompt-parity harness (parity-diff.mjs).

Each variant is the stock default_Seraphina.png with its embedded v2 card JSON rewritten to
exercise ONE divergence axis (a macro class, a jailbreak, a depth note, a WI book, ...). Written
as real PNG cards (chara tEXt chunk = base64(JSON), ccv3 dropped so chara is authoritative) under
DISTINCT character names so both frontends load them as separate characters from the same server.

Usage: python3 parity-cards.py --base <default_Seraphina.png> --out-dir <characters/>
"""

import argparse
import base64
import copy
import json
import pathlib
import struct
import sys
import zlib

PNG_SIG = b"\x89PNG\r\n\x1a\n"


def read_chunks(data):
    assert data[:8] == PNG_SIG, "not a PNG"
    chunks, i = [], 8
    while i < len(data):
        (length,) = struct.unpack(">I", data[i:i + 4])
        ctype = data[i + 4:i + 8]
        cdata = data[i + 8:i + 8 + length]
        chunks.append([ctype, cdata])
        i += 8 + length + 4  # skip crc
    return chunks


def write_png(chunks):
    out = bytearray(PNG_SIG)
    for ctype, cdata in chunks:
        out += struct.pack(">I", len(cdata))
        out += ctype
        out += cdata
        out += struct.pack(">I", zlib.crc32(ctype + cdata) & 0xFFFFFFFF)
    return bytes(out)


def text_chunk(keyword, text):
    return [b"tEXt", keyword.encode("latin-1") + b"\x00" + text.encode("latin-1")]


def load_card(base_png):
    chunks = read_chunks(base_png.read_bytes())
    for ctype, cdata in chunks:
        if ctype == b"tEXt":
            kw, _, val = cdata.partition(b"\x00")
            if kw.lower() in (b"chara", b"ccv3"):
                return json.loads(base64.b64decode(val).decode("utf-8"))
    sys.exit("no chara/ccv3 chunk in base card")


def base_image_chunks(base_png):
    # keep every chunk EXCEPT the chara/ccv3 text (we re-add a fresh chara)
    kept = []
    for ctype, cdata in read_chunks(base_png.read_bytes()):
        if ctype == b"tEXt":
            kw = cdata.partition(b"\x00")[0].lower()
            if kw in (b"chara", b"ccv3"):
                continue
        kept.append([ctype, cdata])
    return kept


def make_variant(base_png, card, name, root_patch=None, data_patch=None):
    v = copy.deepcopy(card)
    v["name"] = name
    v.setdefault("data", {})["name"] = name
    # strip the embedded book AND the linked-world name so each variant isolates its axis (Seraphina
    # copies otherwise keep extensions.world="Eldoria" and pull its WI); the baseline keeps both.
    v.pop("character_book", None)
    v["data"].pop("character_book", None)
    ext = v["data"].get("extensions")
    if isinstance(ext, dict):
        ext.pop("world", None)
    for k, val in (root_patch or {}).items():
        v[k] = val
    for k, val in (data_patch or {}).items():
        v["data"][k] = val
    b64 = base64.b64encode(json.dumps(v).encode("utf-8")).decode("latin-1")
    chunks = base_image_chunks(base_png)
    chunks.insert(-1, text_chunk("chara", b64))  # before IEND
    return write_png(chunks)


# --- the battery: one variant per divergence axis --------------------------------------------------
def variants(card):
    macro_desc = (card.get("data", {}).get("description", "") +
                  "\n{{//hidden author note}}\nDice: {{roll:d6}}. Coin: {{random::heads,tails}}. "
                  "Pick: {{pick::red,green,blue}}. You are {{user}} talking to {{char}}.")
    # battery hosted in `description`; source fields sit elsewhere so no macro reads its own host field.
    cardfields_desc = "\n".join([
        "CARDFIELD MACRO BATTERY",
        "prompt=[{{charPrompt}}]",
        "instruction=[{{charInstruction}}]",
        "personality=[{{charPersonality}}]",
        "personalityAlias=[{{personality}}]",
        "persona=[{{persona}}]",
        "mesRaw=[{{mesExamplesRaw}}]",
        "mesFmt=[{{mesExamples}}]",
        "depth=[{{charDepthPrompt}}]",
        "creator=[{{charCreatorNotes}}]",
        "creatorAlias=[{{creatorNotes}}]",
        "first=[{{charFirstMessage}}]",
        "greet0=[{{greeting::0}}]",
        "greet1=[{{greeting::1}}]",
        "greet2=[{{greeting::2}}]",
        "greetOOB=[{{greeting::9}}]",
        "version=[{{charVersion}}]",
        "versionAlias=[{{version}}]",
        "versionUnderscore=[{{char_version}}]",
        "END BATTERY",
    ])
    cardfields_data = {
        "description": cardfields_desc,
        "personality": "a calm and watchful presence",
        "scenario": "desc=[{{charDescription}}] descAlias=[{{description}}]",
        "mes_example": "<START>\nTraveler: Where are we?\nSeraphina: Adrift, but not lost.",
        "first_mes": "Greetings, traveler. I am here.",
        "alternate_greetings": ["An alternate welcome.", "A second alternate."],
        "system_prompt": "CARD MAIN PROMPT override text",
        "post_history_instructions": "CARD POST-HISTORY instruction text",
        "creator_notes": "authored by the parity harness",
        "character_version": "1.4.2",
        "extensions": {"depth_prompt": {"prompt": "(a lamp flickers nearby)", "depth": 2, "role": "system"}},
    }
    return [
        ("ParityMacro", None, {"description": macro_desc}),
        ("ParitySysOverride", None, {"system_prompt": "CARD SYSTEM: {{original}} :END CARD SYSTEM"}),
        ("ParityJailbreak", None, {"post_history_instructions": "Reply as {{char}} only. {{original}}"}),
        ("ParityDepth", None, {"extensions": {"depth_prompt": {"prompt": "(the lamp flickers, {{char}} notices)", "depth": 2, "role": "system"}}}),
        ("ParityGreeting", None, {"first_mes": "Hello {{user}}. {{//greeting note}} I am {{char}}. Persona: {{persona}}."}),
        ("ParityCardFields", None, cardfields_data),
    ]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--base", required=True)
    ap.add_argument("--out-dir", required=True)
    args = ap.parse_args()
    base_png = pathlib.Path(args.base)
    out_dir = pathlib.Path(args.out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    card = load_card(base_png)
    written = []
    for name, root_patch, data_patch in variants(card):
        png = make_variant(base_png, card, name, root_patch, data_patch)
        dst = out_dir / f"{name}.png"
        dst.write_bytes(png)
        written.append(name)
    print(json.dumps({"written": written, "out": str(out_dir)}))


if __name__ == "__main__":
    main()
