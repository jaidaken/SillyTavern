#!/usr/bin/env python3
"""Seed a scratch ST data dir for the prompt-parity harness (parity-diff.mjs).

Run AFTER the ST server has booted once on --data (so default-user/ exists with the
seeded default settings + preset library). This overlays a CONTROLLED, deterministic
configuration that BOTH frontends read from the one server:

  - connection: main_api=textgenerationwebui, type=ooba, server_urls.ooba=<fake backend>
    (so both frontends go "connected" against parity-fake-backend.py and will send)
  - templates: power_user.instruct + power_user.context set explicitly to the ChatML
    shipped presets, so both builders use byte-identical wrap sequences + story string
  - persona: a fixed username, empty persona_description (no persona slot in the baseline)
  - sysprompt: kept enabled with a macro-free content, so the {{system}} slot is exercised
    with a known string (A1 parity) without dragging in card-override / {{original}}

  - card: copies default/content/default_Seraphina.png into default-user/characters/ (a
    stock v2 card, no system_prompt override -> effectiveSystem == global on both sides)

Everything here is shared by both frontends because they both hit the same /api/settings/get
and /api/characters/get on the same server. The point is one fixture, two prompt builders.

Usage: python3 parity-seed.py --data <dataRoot> --repo <repoRoot> --fake-url http://127.0.0.1:8125
"""

import argparse
import json
import pathlib
import sys


def load_preset(repo, kind, name):
    p = pathlib.Path(repo) / "default" / "content" / "presets" / kind / f"{name}.json"
    return json.loads(p.read_text())


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--data", required=True, help="dataRoot (contains default-user/)")
    ap.add_argument("--repo", required=True, help="ST repo root (for presets + seed card)")
    ap.add_argument("--fake-url", default="http://127.0.0.1:8125")
    ap.add_argument("--username", default="Tester")
    args = ap.parse_args()

    user = pathlib.Path(args.data) / "default-user"
    settings_path = user / "settings.json"
    if not settings_path.exists():
        sys.exit(f"no settings.json at {settings_path} - boot the server on --data first")

    s = json.loads(settings_path.read_text())
    pu = s.setdefault("power_user", {})

    # skip the first-run welcome dialog; auto-connect to the configured server on load so the
    # drive never has to click Connect (both frontends read auto_connect from the same settings).
    s["firstRun"] = False
    pu["auto_connect"] = True

    # --- connection: textgen (ooba/generic) pointed at the fake backend ---
    s["main_api"] = "textgenerationwebui"
    tgw = s.setdefault("textgenerationwebui_settings", {})
    tgw["type"] = "ooba"
    tgw.setdefault("server_urls", {})["ooba"] = args.fake_url

    # --- templates: force ChatML instruct + context on both builders ---
    instruct = load_preset(args.repo, "instruct", "ChatML")
    context = load_preset(args.repo, "context", "ChatML")
    instruct["enabled"] = True
    pu["instruct"] = instruct
    pu["context"] = context

    # persona named <username> so {{user}} resolves the same on both: the new client reads the name
    # from personas[user_avatar], not username. Empty description -> no persona story slot (baseline).
    avatar = "parity-user.png"
    s["username"] = args.username
    s["user_avatar"] = avatar
    pu["personas"] = {avatar: args.username}
    pu["persona_descriptions"] = {avatar: {"description": "", "position": 0, "depth": 4, "role": 0, "lorebook": ""}}
    pu["persona_description"] = ""
    pu["persona_description_position"] = 0
    # the avatar file must EXIST or the old frontend rejects the persona and name1 falls back to
    # "[Unnamed Persona]"; copy the shipped default under our avatar name.
    av_dir = user / "User Avatars"
    if av_dir.is_dir():
        default_av = av_dir / "user-default.png"
        target_av = av_dir / avatar
        if default_av.exists() and not target_av.exists():
            target_av.write_bytes(default_av.read_bytes())

    # --- sysprompt: enabled, macro-free, known content (exercises {{system}} parity) ---
    pu["sysprompt"] = {
        "enabled": True,
        "name": "Parity",
        "content": "You are participating in a fictional roleplay. Stay in character.",
    }
    pu["prefer_character_prompt"] = True
    pu["prefer_character_jailbreak"] = True

    settings_path.write_text(json.dumps(s, indent=4))

    # --- card: the stock default_Seraphina.png from default content (no v2 override). Never copy a
    # second file: two same-name cards split the listing + chat state. Variants get DISTINCT names.
    chars = user / "characters"
    card = chars / "default_Seraphina.png"
    if not card.exists():
        sys.exit(f"stock Seraphina missing at {card} - did default content seed? boot the server on --data first")

    print(json.dumps({
        "settings": str(settings_path),
        "card": str(card),
        "main_api": s["main_api"],
        "fake_url": tgw["server_urls"]["ooba"],
        "instruct": instruct.get("name"),
        "context": context.get("name"),
    }, indent=2))


if __name__ == "__main__":
    main()
