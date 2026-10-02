#!/usr/bin/env python3
"""Run by scripts/mic-fallback-check.sh: <matrix output>. Each `mic-check: <case> field value | field value …` line is
compared with what that case should give; prints the whole table (expected → actual) and fails if any differ.

Devices in the cases (MicFallbackCheck.swift): MacBook Pro Microphone (built-in, internal), USB Microphone (USB),
BlackHole 2ch (virtual), Yap system audio (aggregate), Unknown Input (no transport), AirPods (Bluetooth).
"""
import sys

NO_INPUT = "Your microphone isn't connected, and Yap doesn't switch to a virtual or aggregate input you haven't chosen. Choose a microphone in Audio Settings."
EXPECTED = {
    # Not chosen by the user: virtual, aggregate and unknown inputs are never picked; physical ones are.
    "lid-closed-usb-and-virtual": {"selected": "USB Microphone", "records": "USB Microphone", "saved": "missing-mic"},
    "only-virtual-left": {"selected": "none", "records": "none", "unchosen-left": "true", "message": NO_INPUT},
    "own-aggregate-lid-closed": {"selected": "none", "records": "none", "unchosen-left": "true"},
    # Chosen by the user: used even when virtual.
    "system-default-virtual": {"records": "BlackHole 2ch"},
    "custom-virtual": {"selected": "BlackHole 2ch", "records": "BlackHole 2ch", "saved": "BlackHole2ch_UID"},
    "prioritized-virtual": {"selected": "BlackHole 2ch", "records": "BlackHole 2ch"},
    "prioritized-none-left-but-virtual": {"selected": "none", "records": "none", "prioritized": "missing-mic", "unchosen-left": "true"},
    "prioritized-falls-back-to-builtin": {"selected": "MacBook Pro Microphone", "records": "MacBook Pro Microphone", "prioritized": "missing-mic"},
    "unknown-transport-and-usb": {"selected": "USB Microphone", "records": "USB Microphone"},
    "unknown-transport-only": {"selected": "none", "records": "none", "unchosen-left": "true"},
    "uid-reidentified": {"selected": "USB Microphone", "records": "USB Microphone", "saved": "usb-mic"},
    # A fallback is never saved as the user's choice; the chosen device is used again when it's back.
    "usb-chosen": {"selected": "USB Microphone", "records": "USB Microphone", "saved": "usb-mic"},
    "usb-unplugged": {"selected": "MacBook Pro Microphone", "records": "MacBook Pro Microphone", "saved": "usb-mic"},
    "usb-unplugged-lid-closed": {"records": "none", "lid-blocked": "true", "saved": "usb-mic"},
    "usb-back": {"selected": "USB Microphone", "records": "USB Microphone", "saved": "usb-mic"},
    # During a recording.
    "recording-usb": {"records": "USB Microphone"},
    "recording-lost-airpods-left": {"request": "sent", "switch to": "AirPods", "saved": "usb-mic"},
    "recording-usb-back": {"records": "USB Microphone"},
    "recording-lost-only-virtual": {"request": "sent", "switch to": "none", "unchosen-left": "true", "saved": "usb-mic"},
}


def parse(line):
    label, rest = line[len("mic-check: "):].split(" ", 1)
    fields = {}
    for part in rest.split(" | "):
        for key in sorted(["selected", "records", "lid-blocked", "saved", "prioritized", "request", "switch to", "unchosen-left", "message"], key=len, reverse=True):
            if part.startswith(key + " "):
                fields[key] = part[len(key) + 1:]
                break
    return label, fields


rows = dict(parse(l.rstrip("\n")) for l in open(sys.argv[1]) if l.startswith("mic-check: "))
bad = 0
for case, expected in EXPECTED.items():
    actual = rows.get(case)
    if actual is None:
        print("FAIL %-36s missing" % case)
        bad += 1
        continue
    wrong = {k: (v, actual.get(k, "(not printed)")) for k, v in expected.items() if actual.get(k) != v}
    shown = ", ".join("%s %s" % (k, actual[k]) for k in ("selected", "records", "switch to", "unchosen-left", "saved") if k in actual)
    if wrong:
        bad += 1
        print("FAIL %-36s %s" % (case, "; ".join("%s: expected %r, got %r" % (k, e, a) for k, (e, a) in wrong.items())))
    else:
        print("ok   %-36s %s" % (case, shown))
print("matrix: %d of %d cases as expected" % (len(EXPECTED) - bad, len(EXPECTED)))
sys.exit(1 if bad else 0)
