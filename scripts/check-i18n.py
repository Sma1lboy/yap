#!/usr/bin/env python3
"""Every key in the .xcstrings catalogs has a translation in every app language (en is the source text)."""
import json, sys
from pathlib import Path

LANGS = ["de", "fr", "zh-Hans", "zh-Hant"]
bad = 0
for f in sorted(Path("VoiceInk").glob("*.xcstrings")):
    for key, entry in json.load(open(f))["strings"].items():
        if entry.get("shouldTranslate") is False:
            continue
        missing = [l for l in LANGS if l not in entry.get("localizations", {})]
        if missing:
            bad += 1
            print(f"{f}: {key!r} lacks {', '.join(missing)}")
print(f"check-i18n: {bad} problem(s)")
sys.exit(1 if bad else 0)
