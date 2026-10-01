#!/usr/bin/env python3
"""scripts/lifecycle-check.sh's verdict on one suite's `lifecycle:` lines (LifecycleCheck.swift).

usage: lifecycle-check.py <suite> <output file> <exit status> [crash report]
"""
import json
import statistics
import sys

suite, path, status, crash = sys.argv[1], sys.argv[2], sys.argv[3], (sys.argv[4] if len(sys.argv) > 4 else "")
lines = [json.loads(l[len("isolation: "):]) for l in open(path) if l.startswith("isolation: ")]
results = [l for l in lines if "phase" in l]
failures = []


def check(cond, message):
    if not cond:
        failures.append(message)


def by(phase, request=None):
    return [r for r in results if r["phase"] == phase and (request is None or r["request"] == request)]


def same(r, base, keys=("text", "segments")):
    return bool(r.get("ok")) and all(r.get(k) == base.get(k) for k in keys)


def baseline(request):
    runs = by("baseline", request)
    check(len(runs) == 2 and all(r.get("ok") for r in runs), f"{request} failed alone: {[r.get('error') for r in runs]}")
    check(len(runs) == 2 and same(runs[1], runs[0]), f"{request} differs between two runs alone")
    return runs[0] if runs else {}


def show(r):
    keep = ["ok", "cancelled", "error", "seconds", "status", "loadedAfter", "loadedRightAfter", "loadedLater",
            "failedPieces", "previews", "session", "afterCancel", "newEntries", "releaseSeconds", "offset",
            "stageAtCancel", "interruptibleAtCancel", "markedCancelled", "fraction", "probsEqual", "segmentsEqual",
            "probs", "segmentCount", "waitSeen", "waitTitle", "waitStage", "works", "waits"]
    return {k: (round(v, 2) if isinstance(v, float) else v) for k, v in r.items() if k in keep}


check(status == "0", f"exit status {status}")
check(not crash, f"crash report {crash}")
check(suite not in ("whisper", "residency") or any(l.get("event") == "done" for l in lines), "the check didn't finish")
for r in results:
    print(f"  {r['phase']:22} {r['request']:9} {show(r)}")

if suite == "whisper":
    a, big = baseline("A"), baseline("long")
    long_seconds = statistics.median(r["seconds"] for r in by("baseline", "long"))
    # How long a cancel may take to stop: speech detection checks between pieces of about a second of audio, a decode
    # before each graph computation and window. Up to M4.3 a cancel during speech detection waited for it to finish:
    # 82-86 s for the 65 s file in one slowed-down run.
    STOP = 2.0
    for r in by("cancel-queued", "A"):
        check(r.get("afterCancel", 1e9) <= STOP, f"queued request took {r.get('afterCancel')} s to leave the queue")
    for r, first in zip(by("cancel-queued", "A"), by("cancel-queued", "long")):
        check(r.get("cancelled") is True, f"queued request round {r.get('round')} wasn't cancelled: {show(r)}")
        check(r.get("end", 1e18) < first.get("end", 0), "the queued request only ended after the one ahead of it")
        check(same(first, big), f"the long request beside a cancelled one differs (round {first.get('round')})")
    for r in (by("cancel-queued-after", "A") + by("cancel-decoding-after", "A") + by("cancel-loading-after", "A")
              + by("cancel-speech-after", "A")):
        check(same(r, a), f"{r['phase']}: A differs from alone: {r.get('text')!r} {r.get('error')}")
    for r in by("cancel-decoding", "long"):
        # A cancel that came after the decode had already finished leaves a normal result.
        check(r.get("cancelled") is True or same(r, big), f"decoding request neither cancelled nor as alone: {show(r)}")
        check(r.get("cancelled") is not True or r.get("afterCancel", 1e9) <= STOP,
              f"cancelled {r.get('offset')} s in, it took {r.get('afterCancel', 0):.2f} s to stop (limit {STOP} s)")
        check(r.get("loadedAfter") is True, "the model was released by a cancel")
    for r in by("vad-parity"):
        check(r.get("ok") is True, f"speech detection in pieces differs from one call on {r['request']}: {show(r)}")
    check(len(by("vad-parity")) >= 5, f"speech detection compared on {len(by('vad-parity'))} clips, expected 5 or more")
    for phase in ("cancel-speech", "cancel-longer-decoding"):
        runs = by(phase, "longer")
        check(len(runs) >= 2, f"{phase}: {len(runs)} runs (no longer clip?)")
        for r in runs:
            want = "speechDetection" if phase == "cancel-speech" else "decoding"
            check(r.get("reachedStage") is True and r.get("stageAtCancel") == want,
                  f"{phase}: the cancel didn't come during {want}: {show(r)}")
            check(r.get("cancelled") is True, f"{phase}: not cancelled: {show(r)}")
            check(r.get("afterCancel", 1e9) <= STOP,
                  f"{phase}: took {r.get('afterCancel', 0):.2f} s to stop (limit {STOP} s): {show(r)}")
            check(r.get("loadedAfter") is True, f"{phase}: the model was released by a cancel")
    speech = [r["seconds"] for r in by("speech-baseline", "longer")]
    for r in by("wait-visible", "dictation"):
        check(r.get("waitSeen") is True, f"a dictation queued behind speech detection showed no wait: {show(r)}")
        check(r.get("ok") is True and r.get("text") == (by("dictation-baseline", "dictation") or [{}])[0].get("text"),
              f"the queued dictation after the cancel: {show(r)}")
    for r in by("activity-idle"):
        check(r.get("ok") is True, f"work or waits still reported after the suite: {show(r)}")
    # The same request at the end as at the start: a Mac that slowed down meanwhile makes every time above
    # meaningless, so the run fails as an environment problem instead of passing.
    end = by("baseline-end", "long")
    check(bool(end) and same(end[0], big), "the long clip alone at the end differs from the start")
    if end:
        check(end[0]["seconds"] <= 3 * long_seconds + 1,
              f"ENVIRONMENT: the long clip took {end[0]['seconds']:.2f} s at the end, {long_seconds:.2f} s at the start"
              " (the Mac slowed down during the run; cause not established here)")
    if speech:
        print(f"  speech detection alone over the longer clip: {', '.join(f'{s:.2f}' for s in speech)} s")
    first_preview = next((i for i, l in enumerate(lines) if l.get("phase") == "preview"), len(lines))
    loads = [l for l in lines[:first_preview] if l.get("event") == "load"]
    check(len(loads) == 1, f"{len(loads)} loads; expected only the one after the release before cancel-loading")
    for r in by("cancel-loading", "A"):
        check(r.get("cancelled") is True and r.get("loadedAfter") is True, f"cancel during a load: {show(r)}")
    base_dictation = by("dictation-baseline", "dictation")
    for r in by("dictation-cancel", "dictation"):
        check(r.get("status") == "canceled", f"cancelled dictation saved as {r.get('status')}")
    for r in by("dictation-after", "dictation"):
        check(r.get("status") == "completed" and base_dictation and r.get("text") == base_dictation[0].get("text"),
              f"dictation after the cancel: {show(r)}")
    for r in by("import-cancel", "import"):
        check(r.get("status") == "pending" and r.get("newEntries") == 0, f"cancelled import: {show(r)}")
    for r in by("import-after", "import"):
        check(r.get("ok") is True and r.get("newEntries") == 1, f"import after the cancel: {show(r)}")
    for r in by("preview", "long") + by("preview-switch", "long"):
        check(same(r, big, ("text",)), f"{r['phase']}: the final text differs from the file alone: {show(r)}")
        check(r.get("previews", 0) > 0, f"{r['phase']}: no preview text came out")
    for r in by("preview-switch", "long"):
        check(r.get("switchOK") is True, "the other model's request during the preview failed")
    print(f"  long alone {long_seconds:.2f} s")

elif suite == "residency":
    for r in by("residency"):
        keep, name = r["keep"], r["request"]
        if name == "cancelled":
            check(r.get("cancelled") is True, f"keep {keep}: the request wasn't cancelled")
        else:
            check(r.get("ok") is True, f"keep {keep} {name}: {show(r)}")
        if name == "preview":
            check(r.get("session") == "WhisperPreviewSession", f"preview ran as {r.get('session')}")
        check(name == "cancelled" or r.get("loadedRightAfter") is True, f"keep {keep} {name}: not loaded right after")
        want_later = keep == 0
        check(r.get("loadedLater") is want_later,
              f"keep {keep} {name}: loaded {r.get('loadedLater')} {r.get('laterSeconds')} s later, expected {want_later}")
    for r in by("pressure", "meeting"):
        check(r.get("failedPieces") == 0, f"memory pressure during a meeting: {r.get('failedPieces')} failed pieces")
        check(r.get("releasedAfterMeeting") is True, "memory pressure: the model wasn't released after the meeting")
    for r in by("pressure-after", "A"):
        check(r.get("ok") is True, f"after the pressure release: {show(r)}")

else:  # tcpp, fluid: the backend suite
    a, b = baseline("A"), baseline("B")
    check(a.get("text") != b.get("text"), "A and B came out the same alone")
    for r in by("same"):
        base = a if r["request"] == "A" else b
        check(same(r, base, ("text",)), f"same round {r.get('round')} {r['request']}: {r.get('text')!r} {r.get('error')}")
    print(f"  together: {sum(same(r, a if r['request'] == 'A' else b, ('text',)) for r in by('same'))}/{len(by('same'))} as alone")
    for r in by("release-during", "long"):
        check(r.get("ok") is True, f"a release during the decode broke it: {show(r)}")
        check(r.get("loadedAfterRelease") is False, "the release left the model loaded")
        if suite == "fluid":
            check(r.get("releasedAfterDecode") is True, "FluidAudio's release didn't wait for the decode")
    for r in by("release-after", "A") + by("cancel-after", "A"):
        check(same(r, a, ("text",)), f"{r['phase']}: {show(r)}")
    for r in by("kept", "A"):
        check(r.get("ok") is True, "the model wasn't kept between requests")
    for r in by("cancel-queued", "A"):
        if suite == "fluid":
            check(r.get("cancelled") is True, f"queued request wasn't cancelled: {show(r)}")
        else:
            # transcribe.cpp has no queue: its native runs take turns per chunk, so A runs between the long file's
            # chunks and is usually done before the cancel.
            check(r.get("cancelled") is True or same(r, a, ("text",)), f"request beside the long one: {show(r)}")
    for r in by("cancel-queued", "long"):
        check(r.get("ok") is True, f"the long request beside a cancelled one failed: {show(r)}")
    for r in by("cancel-decoding", "long"):
        check(r.get("cancelled") is True, f"decoding request wasn't cancelled: {show(r)}")
        if suite == "fluid":
            # Nemotron's decode doesn't stop on a cancel: the wait is shown as a step that can't be stopped, and the
            # request still ends cancelled. How long it took is reported only.
            check(r.get("interruptibleAtCancel") is False and r.get("markedCancelled") is True,
                  f"FluidAudio's decode not shown as cancelled and unstoppable: {show(r)}")
            print(f"  cancel during the Nemotron decode took {r.get('afterCancel', 0):.2f} s (it can't be stopped)")
        else:
            check(r.get("afterCancel", 1e9) <= 2.0, f"transcribe.cpp took {r.get('afterCancel', 0):.2f} s to stop")
    events = [l.get("event") for l in lines if "event" in l]
    check("terminate" in events and "will terminate" in events, "no Quit through NSApplication")
    quit_at = next((l["t"] for l in lines if l.get("event") == "terminate"), None)
    will = next((l for l in lines if l.get("event") == "will terminate"), {})
    check(will.get("loaded") is False, "model still loaded at willTerminate")
    in_flight = by("quit-in-flight", "long")
    check(bool(in_flight) and in_flight[0]["t"] <= will.get("t", 0), "Quit didn't wait for the transcription in flight")
    waits = [l for l in lines if l.get("event") == "quit-wait" and l["t"] <= will.get("t", 0)]
    if quit_at and will:
        took = will["t"] - quit_at
        print(f"  Quit took {took:.2f} s")
        if took > 1.5:
            # The main actor kept running (these come from it every half second) and the panel said what Quit waits for.
            check(len(waits) >= int(took / 0.5) - 2, f"{len(waits)} wait reports in {took:.1f} s: the main actor stalled")
            check(any(w.get("panel") and w.get("title") for w in waits), "the Quit panel never showed what it waits for")
        for title, stage in sorted({(w.get("title"), w.get("stage")) for w in waits if w.get("panel")}):
            print(f"  Quit panel: {title} / {stage}")

if failures:
    print(f"{suite}: FAIL")
    for f in failures:
        print("  " + f)
    sys.exit(1)
print(f"{suite}: OK")
