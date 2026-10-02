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
import glob, hashlib, os, re, subprocess, sys, time

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
print("meeting-archive-check: OK")
