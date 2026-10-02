#!/usr/bin/env python3
"""Run by scripts/meeting-archive-check.sh (make meeting-archive-check): <app binary> <work folder>.

Two meetings on one day and a dictation go into a History store in the test folder, then the whole History is saved
to folders as History's Save Meetings to Folder… does it, in these cases:

1. Two app processes save into one empty folder at the same moment: each meeting has one file, written by one of
   them and found by the other; every file is byte for byte that meeting's Export Markdown (same language, locale and
   time zone); the dictation has none; names hold the meeting's start and id, nothing of the text.
2. Saving again adds nothing and leaves every file as it was (inode, mtime, bytes).
3. In English instead of Chinese: new bytes, so a new file per meeting next to the old ones.
4. A copy the user edited stays as edited and is reported; a symbolic link in a file's place is reported and neither it
   nor its target changes; a file Yap can't read fails alone while the other meeting is written.
5. Notes regenerated: a new version for that meeting, the old file unchanged.
6. A folder that's gone fails without being created again; a read-only folder fails, except for a copy already in it.
Every export leaves History's entries and the meetings' audio exactly as they were.
"""
import glob, hashlib, json, os, re, shutil, subprocess, sys, time

APP, WORK = sys.argv[1], sys.argv[2]
DATA = os.path.join(WORK, "data")
TZ = "Asia/Shanghai"
LANGS = {"zh": ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"],
         "en": ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]}


def fail(message):
    print("FAIL: " + message)
    sys.exit(1)


def check(condition, message):
    if not condition:
        fail(message)


def launch(lang, *args):
    env = dict(os.environ, TZ=TZ)
    return subprocess.Popen([APP, *LANGS[lang], "--meeting-archive-check", DATA, *args],
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=env)


def finish(process):
    out, err = process.communicate(timeout=120)
    lines = [l[len("archive-check: "):] for l in out.splitlines() if l.startswith("archive-check: ")]
    if process.returncode != 0:
        fail("the app exited with %d\n%s\n%s" % (process.returncode, "\n".join(lines), err[-2000:]))
    return lines


def run(lang, *args):
    return finish(launch(lang, *args))


def export(lang, folder, start=None):
    """One export; returns ({meeting id: (outcome, file name)}, counts line), after checking History didn't change."""
    expected = os.path.join(WORK, "expected-" + lang)
    lines = finish(launch(lang, "export", folder, expected, *([str(start)] if start else [])))
    return parse(lines)


def parse(lines):
    items = {}
    for line in lines:
        m = re.match(r"item (\S+) (\S+) (.+)$", line)
        if m:
            items[m.group(1)] = (m.group(2), m.group(3))
    before = next(l.split()[1] for l in lines if l.startswith("history-before "))
    after = next(l for l in lines if l.startswith("history-after "))
    check(after == "history-after %s changes false" % before, "the export changed History: %s / %s" % (before, after))
    check(next(l for l in lines if l.startswith("selection ")) == "selection 3 meetings 2", "selection: %r" % lines)
    check(set(items) == set(meetings), "one result per meeting, none for the dictation: %r" % items)
    return items, next(l for l in lines if l.startswith("written "))


def md_files(folder):
    return sorted(os.path.basename(p) for p in glob.glob(os.path.join(folder, "*")) + glob.glob(os.path.join(folder, ".*")))


def identity(path):
    s = os.lstat(path)
    return (s.st_ino, s.st_mtime_ns, s.st_size, hashlib.sha256(open(path, "rb").read()).hexdigest() if os.path.isfile(path) and not os.path.islink(path) else None)


def audio_hashes():
    return {p: hashlib.sha256(open(p, "rb").read()).hexdigest() for p in sorted(glob.glob(os.path.join(DATA, "Recordings/**/*.wav"), recursive=True))}


def expected(lang, meeting):
    return open(os.path.join(WORK, "expected-" + lang, meeting + ".md"), "rb").read()


# Seed.
seed = run("zh", "seed")
meetings = [l.split()[1] for l in seed if l.startswith("meeting ")]
dictation = next(l.split()[1] for l in seed if l.startswith("dictation "))
check(len(meetings) == 2, "seed: %r" % seed)
audio = audio_hashes()
check(len(audio) == 2, "seed audio: %r" % audio)
print("seeded: meetings %s, dictation %s, TZ=%s" % (" ".join(meetings), dictation, TZ))

# 1. Two processes, one folder, one moment.
out = os.path.join(WORK, "Archive")
os.mkdir(out)
start = int(time.time()) + 6
a, b = launch("zh", "export", out, os.path.join(WORK, "expected-zh"), str(start)), \
    launch("zh", "export", out, os.path.join(WORK, "expected-zh"), str(start))
(ia, ca), (ib, cb) = parse(finish(a)), parse(finish(b))
for m in meetings:
    outcomes = sorted([ia[m][0], ib[m][0]])
    check(outcomes == ["there", "written"], "race for %s: %r" % (m, outcomes))
    check(ia[m][1] == ib[m][1], "both processes named %s alike" % m)
names = {m: ia[m][1] for m in meetings}
check(md_files(out) == sorted(names.values()), "folder after the race: %r" % md_files(out))
for i, m in enumerate(meetings):
    name = names[m]
    check(re.fullmatch(r"2026-09-30 %s meeting-%s-[0-9a-f]{12}\.md" % (["0905", "1405"][i], m), name), "name: %r" % name)
    data = open(os.path.join(out, name), "rb").read()
    check(data == expected("zh", m), "%s isn't the meeting's Export Markdown" % name)
    check(hashlib.sha256(data).hexdigest()[:12] == name[-15:-3], "%s: the version is the SHA-256 of its bytes" % name)
check(dictation not in " ".join(md_files(out)), "the dictation was exported")
check("../" not in " ".join(names.values()) and "Tingting" not in " ".join(names.values()), "text in a name")
first_text = expected("zh", meetings[0]).decode()
check("# 会议" in first_text and "2026年9月30日" in first_text and "Summary" in first_text,
      "Chinese Markdown with the notes:\n" + first_text)
check(re.search(r"\*\*\[00:21\] .+\*\*: ", first_text), "the failed piece's line is in the file:\n" + first_text)
check("**[00:00] Tingting**" in expected("zh", meetings[1]).decode(), "the second meeting has its speaker names")
print("1. two processes at once: %s / %s; files %s; bytes = Export Markdown (zh-Hans, %s)" % (ca, cb, ", ".join(names.values()), TZ))

# 2. Again: nothing added, nothing touched.
before = {n: identity(os.path.join(out, n)) for n in md_files(out)}
items, counts = export("zh", out)
check(all(items[m] == ("there", names[m]) for m in meetings), "again: %r" % items)
check({n: identity(os.path.join(out, n)) for n in md_files(out)} == before, "saving again touched a file")
print("2. again: %s; inode, mtime and bytes of both files unchanged" % counts)

# 3. Another language, other bytes: a new version next to the old one.
items, counts = export("en", out)
check(all(items[m][0] == "written" and items[m][1] != names[m] for m in meetings), "English: %r" % items)
check(all(open(os.path.join(out, items[m][1]), "rb").read() == expected("en", m) for m in meetings), "English bytes")
check(expected("en", meetings[0]).decode().startswith("# Meeting\n\nSep 30, 2026"), "English Markdown")
check({n: identity(os.path.join(out, n)) for n in before} == before, "the Chinese files changed")
check(len(md_files(out)) == 4, "4 files: %r" % md_files(out))
print("3. English: %s; %d files, the Chinese ones untouched" % (counts, len(md_files(out))))

# 4a. A copy the user edited.
edited = os.path.join(out, names[meetings[1]])
with open(edited, "ab") as f:
    f.write("\n我的批注\n".encode())
kept = identity(edited)
items, counts = export("zh", out)
check(items[meetings[1]][0] == "conflict-differentContent" and items[meetings[0]][0] == "there", "edited: %r" % items)
check(identity(edited) == kept, "the edited copy changed")
print("4a. edited copy: %s; kept as the user left it" % counts)

# 4b. A link where a file would go (to a file with the very same bytes); the other meeting is written.
linked = os.path.join(WORK, "Linked")
os.mkdir(linked)
target = os.path.join(WORK, "target.md")
open(target, "wb").write(expected("zh", meetings[0]))
os.symlink(target, os.path.join(linked, names[meetings[0]]))
target_before = identity(target)
items, counts = export("zh", linked)
check(items[meetings[0]][0] == "conflict-symbolicLink" and items[meetings[1]][0] == "written", "link: %r" % items)
check(os.path.islink(os.path.join(linked, names[meetings[0]])) and identity(target) == target_before, "the link or its target changed")
print("4b. symbolic link: %s; link and target unchanged" % counts)

# 4c. A file Yap can't read fails alone; the other meeting is written.
partial = os.path.join(WORK, "Partial")
os.mkdir(partial)
locked = os.path.join(partial, names[meetings[1]])
open(locked, "wb").write(expected("zh", meetings[1]))
os.chmod(locked, 0)
items, counts = export("zh", partial)
os.chmod(locked, 0o644)
check(items[meetings[1]][0] == "failed-unreadable" and items[meetings[0]][0] == "written", "unreadable: %r" % items)
check(open(locked, "rb").read() == expected("zh", meetings[1]), "the unreadable file changed")
check(open(os.path.join(partial, names[meetings[0]]), "rb").read() == expected("zh", meetings[0]), "partial: the written file")
print("4c. partly failed: %s" % counts)

# 5. Notes regenerated: a new version of that meeting only.
run("zh", "edit")
old = {n: identity(os.path.join(out, n)) for n in md_files(out)}
items, counts = export("zh", out)
check(items[meetings[0]][0] == "written" and items[meetings[0]][1] != names[meetings[0]], "regenerated: %r" % items)
check(items[meetings[1]][0] == "conflict-differentContent", "the edited copy is still reported: %r" % items)
check("CI first, then the API." in open(os.path.join(out, items[meetings[0]][1]), encoding="utf-8").read(), "new notes")
check({n: identity(os.path.join(out, n)) for n in old} == old, "an older version changed")
print("5. regenerated notes: %s; %d files, older versions untouched" % (counts, len(md_files(out))))
print("   the folder now: " + "\n                   ".join(md_files(out)))
print("   %s:\n%s" % (names[meetings[0]], open(os.path.join(out, names[meetings[0]]), encoding="utf-8").read()))

# 6. A folder that's gone; a read-only one that already holds the first meeting's current file.
current = items[meetings[0]][1]
gone = os.path.join(WORK, "Gone")
items, counts = export("zh", gone)
check(all(items[m][0] == "failed-folderMissing" for m in meetings) and not os.path.exists(gone), "gone: %r" % items)
readonly = os.path.join(WORK, "ReadOnly")
os.mkdir(readonly)
open(os.path.join(readonly, current), "wb").write(expected("zh", meetings[0]))
os.chmod(readonly, 0o555)
items, counts = export("zh", readonly)
os.chmod(readonly, 0o755)
check(items[meetings[0]] == ("there", current) and items[meetings[1]][0] == "failed-notPermitted"
      and os.listdir(readonly) == [current], "read-only: %r" % items)
print("6. folder gone: not created again; read-only folder: %s (the copy already there counts)" % counts)

check(audio_hashes() == audio, "the meetings' audio changed")
leftovers = [n for f in [out, linked, partial] for n in md_files(f) if "yap-tmp" in n]
check(not leftovers, "temporary files left: %r" % leftovers)
print("History entries unchanged by every export; audio SHA-256 unchanged; no temporary files left")


# 7. Saving to a folder automatically (Settings › Meetings). Each `auto` launch is a restart: the switch and folder
# are read from this identity's defaults again. In English, so the speaker labels are "Others 1", "Others 2".
def auto(*args, flags=()):
    lines = run("en", "auto", *args, *flags)
    state = next(l for l in lines if l.startswith("auto enabled "))
    last = next(l for l in lines if l.startswith("auto last ")).split(" ", 4)[2:]
    created = [l.split()[1] for l in lines if l.startswith("created ")]
    return lines, state, last, created


def versions(folder, meeting):
    return sorted(n for n in md_files(folder) if meeting in n)


def body(folder, name):
    return open(os.path.join(folder, name), encoding="utf-8").read()


per_meeting = []  # (case, meeting, version files)
A = os.path.join(WORK, "AutoA")
os.mkdir(A)

# 7a. Off by default: a new meeting is saved in History, nothing in any folder.
_, state, last, (m_off,) = auto("create")
check(state.startswith("auto enabled false folder none") and last == ["none"], "default: %s %s" % (state, last))
check(md_files(A) == [], "written while off")
# 7b. Turned on: History's meetings (the two seeded, the one just made) aren't copied.
_, state, last, _ = auto("on", A)
check(state.startswith("auto enabled true folder %s" % A) and md_files(A) == [], "turning on copied History: %r" % md_files(A))
print("7a-b. off by default: nothing written; turning it on with 3 meetings in History: %d files" % len(md_files(A)))

# 7c. A new meeting: one file, its Export Markdown; the same meeting handed on twice more, and again after a restart.
_, state, last, (m1,) = auto("create")
check(last[0] == m1 and last[1] == "written" and versions(A, m1) == [last[2]], "new meeting: %s %r" % (last, md_files(A)))
first = identity(os.path.join(A, last[2]))
_, _, last, _ = auto("resave", m1)
check(last[1] == "there" and versions(A, m1) == [last[2]] and identity(os.path.join(A, last[2])) == first, "duplicate: %s" % last)
_, _, last, _ = auto("resave", m1)
check(last[1] == "there" and len(versions(A, m1)) == 1, "after a restart: %s" % last)
print("7c. new meeting: written; the same save twice in one launch and again after a restart: there, file untouched")

# 7d. Speaker Names: a new version. A Regenerate Notes whose save fails: nothing; one that's saved: a new version.
_, _, last, _ = auto("rename", m1, "me=Jackson")
check(last[1] == "written" and len(versions(A, m1)) == 2 and "Jackson" in body(A, last[2]), "rename: %s" % last)
lines, _, last, _ = auto("notes", m1, "- Notes that never got saved.", flags=("--meeting-fail-save",))
check(last == ["none"] and len(versions(A, m1)) == 2 and "edit-error none" not in lines
      and not any("never got saved" in body(A, n) for n in md_files(A)), "failed notes save: %s %r" % (last, lines))
check(any(l.startswith("notes-now - Ship on Friday") for l in lines), "the old notes weren't put back: %r" % lines)
_, _, last, _ = auto("notes", m1, "- CI first, then the API.")
check(last[1] == "written" and len(versions(A, m1)) == 3 and "CI first, then the API." in body(A, last[2]), "notes: %s" % last)
per_meeting.append(("names, failed notes, notes", m1, versions(A, m1)))
print("7d. rename: a new version; notes whose save failed: nothing written, old notes kept; regenerated notes: a new version")

# 7e. Speakers still pending: saved right away; when they arrive (two people), a new version with them.
_, _, last, (p1,) = auto("create", "pending")
check(last[0] == p1 and last[1] == "written", "pending meeting not saved at once: %s" % last)
pending_file = last[2]
check("Others 1" not in body(A, pending_file), "labels before diarization")
lines, _, last, _ = auto("speakers", p1, "two")
check("speaker-status none" in lines and last[1] == "written" and len(versions(A, p1)) == 2, "speakers: %s %r" % (last, lines))
check("Others 1" in body(A, last[2]) and "Others 2" in body(A, last[2]) and body(A, pending_file).count("Others 1") == 0,
      "the second version has the speakers, the first stays as it was")
per_meeting.append(("pending, then two speakers", p1, versions(A, p1)))
# Diarization failed: only the status changes, the Markdown doesn't: there.
_, _, last, (p2,) = auto("create", "pending")
lines, _, last, _ = auto("speakers", p2, "fail")
check("speaker-status timedOut" in lines and last[1] == "there" and len(versions(A, p2)) == 1, "speakers failed: %s %r" % (last, lines))
per_meeting.append(("pending, then diarization failed", p2, versions(A, p2)))
# The recording folder gone before they arrive: marked as failed, the same Markdown: there.
_, _, last, (p3,) = auto("create", "pending")
lines, _, last, _ = auto("speakers", p3, "gone")
check("speaker-status failed" in lines and last[1] == "there" and len(versions(A, p3)) == 1, "folder gone: %s %r" % (last, lines))
per_meeting.append(("pending, then its recording folder gone", p3, versions(A, p3)))
# The entry deleted while pending (by hand or the retention cleanup): its first file stays; the speakers arriving
# afterwards change nothing and report nothing.
_, _, last, (p4,) = auto("create", "pending")
auto("delete", p4)
lines, _, last, _ = auto("speakers", p4, "two")
check("speaker-status no-entry" in lines and last == ["none"] and len(versions(A, p4)) == 1, "deleted pending: %s %r" % (last, lines))
per_meeting.append(("pending, then deleted", p4, versions(A, p4)))
print("7e. pending speakers: saved at once (1 file); two speakers later: +1 version with Others 1/2; diarization failed or "
      "recording folder gone: status saved, same bytes, there; entry deleted while pending: 1 file, later speakers report nothing")

# 7f. Deleted right after saving, as the retention cleanup does, while the file waits 1 s: the snapshot was taken at
# the save, so the file is still written.
lines, _, last, (c1,) = auto("create-cleanup", flags=("--auto-archive-delay", "1"))
check(("deleted %s" % c1) in lines and last[0] == c1 and last[1] == "written" and len(versions(A, c1)) == 1, "cleanup: %s %r" % (last, lines))
per_meeting.append(("deleted right after saving", c1, versions(A, c1)))
print("7f. entry and audio deleted right after the save, before its file was written: the file is written from the snapshot")

# 7g. A copy the user edited: reported as a conflict and left as it is.
_, _, _, (e1,) = auto("create")
edited = os.path.join(A, versions(A, e1)[0])
with open(edited, "ab") as f:
    f.write(b"\nmy note\n")
kept = identity(edited)
_, _, last, _ = auto("resave", e1)
check(last[1] == "conflict-differentContent" and identity(edited) == kept and len(versions(A, e1)) == 1, "edited: %s" % last)
print("7g. a copy the user edited: %s, kept as it was" % last[1])

# 7h. Turned off while one file is being written (2 s) and another is queued: off returns after the first is
# written; the second never starts. Saved while off: nothing.
before = set(md_files(A))
lines, state, last, (x1, x2) = auto("race-off", flags=("--auto-archive-delay", "2"))
off_at = int(next(l for l in lines if l.startswith("off-at ")).split()[1])
check(state.startswith("auto enabled false") and last == ["none"], "race-off state: %s %s" % (state, last))
check(len(versions(A, x1)) == 1 and versions(A, x2) == [], "race-off files: %r" % (set(md_files(A)) - before))
check(os.stat(os.path.join(A, versions(A, x1)[0])).st_mtime_ns <= off_at, "a file was written after off returned")
_, state, last, (x3,) = auto("create")
check(versions(A, x3) == [] and state.startswith("auto enabled false folder %s" % A), "saved while off: %s" % state)
print("7h. turned off with one file in flight and one queued: the one in flight finished before off returned, the "
      "queued one never started; a meeting saved while off: no file; the folder is kept for next time")

# 7i. The folder changed with one file in flight and one queued: the first lands in the old folder, the queued one
# nowhere, the next meeting in the new folder.
B = os.path.join(WORK, "AutoB")
os.mkdir(B)
auto("on")
before = set(md_files(A))
lines, state, last, (y1, y2, y3) = auto("race-switch", B, flags=("--auto-archive-delay", "2"))
check(state.startswith("auto enabled true folder %s" % B), "switch state: %s" % state)
check(len(versions(A, y1)) == 1 and versions(A, y2) == [] and versions(B, y2) == [] and versions(B, y1) == [], "old destination: %r" % md_files(B))
check(len(versions(B, y3)) == 1 and versions(A, y3) == [] and last[0] == y3 and last[1] == "written", "new folder: %s %r" % (last, md_files(B)))
print("7i. folder changed with one file in flight and one queued: in flight -> old folder, queued -> nowhere, next -> new folder")

# 7j. The folder disappears: failed, not created again; a read-only folder: failed; History keeps the meeting.
shutil.rmtree(B)
_, _, last, (g1,) = auto("create")
check(last[0] == g1 and last[1] == "failed-folderMissing" and not os.path.exists(B), "folder gone: %s" % last)
R = os.path.join(WORK, "AutoReadOnly")
os.mkdir(R)
auto("on", R)
os.chmod(R, 0o555)
_, _, last, (g2,) = auto("create")
os.chmod(R, 0o755)
check(last[1] == "failed-notPermitted" and md_files(R) == [], "read-only: %s" % last)
_, _, last, _ = auto("resave", g2)
# `resave` hands the meeting on twice: the first writes it, the second finds it.
check(last[1] == "there" and len(versions(R, g2)) == 1, "after write access came back, the next save of that meeting: %s" % last)
print("7j. folder gone: failed-folderMissing, not recreated; read-only: failed-notPermitted; History entries kept")

# 7k. Settings leaving this Mac (config.json, Yap Cloud's copy, Export Settings) carry neither the switch nor the
# folder; importing a foreign backup and config (which name both) changes neither, on or off.
settings = os.path.join(WORK, "settings")
os.mkdir(settings)
os.makedirs(os.path.join(WORK, "config", "yap"), exist_ok=True)


def settings_step(step):
    env = dict(os.environ, TZ=TZ, XDG_CONFIG_HOME=os.path.join(WORK, "config"))
    p = subprocess.run([APP, *LANGS["en"], "--meeting-archive-settings-check", settings, step],
                       capture_output=True, text=True, timeout=120, env=env)
    line = next((l for l in p.stdout.splitlines() if l.startswith("settings-check: ")), "")
    check(p.returncode == 0 and " failed " not in line, "settings %s: %d %s %s" % (step, p.returncode, line, p.stderr[-1500:]))
    return line[len("settings-check: "):]


state = settings_step("export")
check(state == "export enabled true folder %s" % R, "settings export state: %s" % state)
for name in ["config.json", "cloud.json", "backup.json"]:
    text = open(os.path.join(settings, name), encoding="utf-8").read()
    check(len(text) > 100 and R not in text and "AutoArchive" not in text and "autoArchive" not in text, "%s carries it" % name)
foreign = "/tmp/someone-elses-folder"
backup = json.load(open(os.path.join(settings, "backup.json")))
backup.setdefault("generalSettings", {}).update({"meetingAutoArchiveEnabled": False, "meetingAutoArchiveFolder": foreign})
backup["meetingAutoArchiveEnabled"], backup["meetingAutoArchiveFolder"] = False, foreign
json.dump(backup, open(os.path.join(settings, "foreign-backup.json"), "w"))
config = json.load(open(os.path.join(settings, "config.json")))
config.setdefault("general", {}).update({"meetingAutoArchiveEnabled": False, "meetingAutoArchiveFolder": foreign})
config["meetingAutoArchiveEnabled"], config["meetingAutoArchiveFolder"] = False, foreign
json.dump(config, open(os.path.join(settings, "foreign-config.json"), "w"))
state = settings_step("import")
check(state == "import enabled true folder %s" % R, "import changed it (on): %s" % state)
auto("off")
for path in ["foreign-backup.json", "foreign-config.json"]:
    data = json.load(open(os.path.join(settings, path)))
    data["meetingAutoArchiveEnabled"] = True
    data.get("generalSettings", data.get("general", {}))["meetingAutoArchiveEnabled"] = True
    json.dump(data, open(os.path.join(settings, path), "w"))
state = settings_step("import")
check(state == "import enabled false folder %s" % R, "import changed it (off): %s" % state)
print("7k. config.json, Yap Cloud's copy and Export Settings: neither the switch nor the folder; importing settings that "
      "name both: on stays on with this Mac's folder, off stays off")

print("7. files per meeting:")
for case, meeting, files in per_meeting:
    print("   %-40s %d  %s" % (case, len(files), ", ".join(files)))
print("meeting-archive-check: OK")
