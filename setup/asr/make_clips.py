#!/usr/bin/env python3
"""Synthesizes setup/asr/clips/<id>.m4a from cases.json with macOS `say` (two voices, fast rate), like the
original cloud bench. The clips are committed, so benches compare on identical audio; rerun only to change cases."""
import json, os, subprocess, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
RATE = "230"  # words per minute; faster than the default, as people dictate

cases = json.load(open(os.path.join(HERE, "cases.json")))
os.makedirs(os.path.join(HERE, "clips"), exist_ok=True)
for case in cases:
    with tempfile.TemporaryDirectory() as tmp:
        aiff = os.path.join(tmp, "x.aiff")
        subprocess.run(["say", "-v", case["voice"], "-r", RATE, "-o", aiff, case["text"]], check=True)
        out = os.path.join(HERE, "clips", case["id"] + ".m4a")
        subprocess.run(["afconvert", "-f", "m4af", "-d", "aac", "-b", "48000", "-c", "1", aiff, out], check=True)
    print(case["id"], out)
