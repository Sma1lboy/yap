import CryptoKit
import Darwin
import Foundation

/// History › Save Meetings to Folder…: each selected meeting as History's Export Markdown writes it
/// (`MeetingNotes.markdown`, the same bytes as yap-mcp's get_meeting in the same language and time zone), one file
/// per meeting and content version, in a folder the user picked.
///
/// An archive, not a sync. A file's name holds the meeting's start (in the current time zone), its id and the first
/// 12 hex digits of the SHA-256 of its bytes; nothing from the transcript or the speaker names. The same meeting with
/// the same bytes gets the same name, so saving it again adds nothing; when the bytes change (new speaker names,
/// regenerated notes, another app language or time zone, which change the heading and the date line), the name
/// changes and a new file is added next to the old one.
///
/// Nothing in the folder is replaced or deleted. A name that's taken is compared, never followed: a regular file
/// with the same bytes counts as already there; a file with other bytes (edited by the user), a symbolic link or
/// anything else is left alone and reported. The file is written under a temporary name and then given its name
/// with an exclusive rename (`renameatx_np` with `RENAME_EXCL`, or a hard link where the file system has no such
/// rename), which fails instead of replacing a file created in the meantime. The folder itself is never created.
enum MeetingArchive {
    /// A meeting as it is when the export starts: read on the main actor, written from any thread.
    struct Entry: Sendable {
        let id: UUID
        let timestamp: Date
        let bytes: Data
    }

    enum Conflict: Sendable, Equatable {
        /// A regular file with other content: most likely an earlier copy the user edited.
        case differentContent
        case symbolicLink
        /// A folder or another kind of file.
        case notAFile
    }

    enum Failure: Sendable, Equatable {
        /// The folder was moved or deleted after it was chosen. It isn't created again.
        case folderMissing
        case notPermitted
        /// A file with this name is there, but Yap can't read it to compare it.
        case unreadable
        case other(Int32)
    }

    enum Outcome: Sendable, Equatable {
        case written
        case alreadyThere
        case conflict(Conflict)
        case failed(Failure)
    }

    struct Item: Sendable, Equatable {
        let id: UUID
        let fileName: String
        let outcome: Outcome
    }

    struct Report: Sendable {
        let folder: URL
        let items: [Item]

        func count(_ matches: (Outcome) -> Bool) -> Int { items.filter { matches($0.outcome) }.count }
        var written: Int { count { $0 == .written } }
        var alreadyThere: Int { count { $0 == .alreadyThere } }
        var conflicts: [Item] { items.filter { if case .conflict = $0.outcome { return true } else { return false } } }
        var failures: [Item] { items.filter { if case .failed = $0.outcome { return true } else { return false } } }
    }

    /// The meetings among `selection`, oldest first, with the bytes Export Markdown would write now.
    @MainActor static func entries(for selection: [Transcription]) -> [Entry] {
        selection.filter(\.isMeeting).sorted { $0.timestamp < $1.timestamp }.map {
            Entry(id: $0.id, timestamp: $0.timestamp, bytes: Data(MeetingNotes.markdown(for: $0).utf8))
        }
    }

    /// `2026-09-29 1500 meeting-<id>-<12 hex of SHA-256>.md`. The date is when the meeting started, not the day of
    /// the export, in `timeZone` (the formatter's, so both change together).
    static func fileName(for entry: Entry, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HHmm"
        let digest = SHA256.hash(data: entry.bytes).prefix(6).map { String(format: "%02x", $0) }.joined()
        return "\(formatter.string(from: entry.timestamp)) meeting-\(entry.id.uuidString.lowercased())-\(digest).md"
    }

    /// Writes each entry into `folder`; one result per entry, in order. Nothing is rolled back: what was written
    /// stays when a later file fails.
    static func export(_ entries: [Entry], to folder: URL) -> Report {
        let directory = open(folder.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard directory >= 0 else {
            let reason = failure(errno, folder: true)
            return Report(folder: folder, items: entries.map { Item(id: $0.id, fileName: fileName(for: $0), outcome: .failed(reason)) })
        }
        defer { close(directory) }
        return Report(
            folder: folder,
            items: entries.map { entry in
                let name = fileName(for: entry)
                return Item(id: entry.id, fileName: name, outcome: write(entry.bytes, named: name, in: directory))
            })
    }

    /// Creates `name` in the open folder `directory` with `bytes`, or says why it didn't.
    static func write(_ bytes: Data, named name: String, in directory: Int32) -> Outcome {
        // First what's there: in a folder Yap can't write to, the copies already in it still count as there.
        if let existing = existing(name, in: directory, comparedWith: bytes) { return existing }

        let temporary = ".\(name).\(UUID().uuidString).yap-tmp"
        let file = openat(directory, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o644)
        guard file >= 0 else { return .failed(failure(errno, folder: true)) }
        let wrote = bytes.withUnsafeBytes { buffer -> Bool in
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(file, buffer.baseAddress! + offset, buffer.count - offset)
                if count < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                offset += count
            }
            return fsync(file) == 0
        }
        let writeError = errno
        close(file)
        defer { unlinkat(directory, temporary, 0) }
        guard wrote else { return .failed(failure(writeError, folder: false)) }

        if renameatx_np(directory, temporary, directory, name, UInt32(RENAME_EXCL)) == 0 { return .written }
        var error = errno
        if error == ENOTSUP || error == EINVAL {
            // No exclusive rename on this file system (some network and FAT volumes): a hard link also fails when
            // the name exists. Never a plain rename, which would replace it.
            if linkat(directory, temporary, directory, name, 0) == 0 { return .written }
            error = errno
        }
        if error == EEXIST, let existing = existing(name, in: directory, comparedWith: bytes) {
            return existing  // created by someone else since the first look
        }
        return .failed(failure(error, folder: false))
    }

    /// What's at `name` (never following a link): nil when nothing is.
    private static func existing(_ name: String, in directory: Int32, comparedWith bytes: Data) -> Outcome? {
        var info = stat()
        guard fstatat(directory, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
            return errno == ENOENT ? nil : .failed(failure(errno, folder: false))
        }
        switch info.st_mode & S_IFMT {
        case S_IFREG: break
        case S_IFLNK: return .conflict(.symbolicLink)
        default: return .conflict(.notAFile)
        }
        let file = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard file >= 0 else {
            if errno == ELOOP { return .conflict(.symbolicLink) }
            return .failed(errno == EACCES || errno == EPERM ? .unreadable : failure(errno, folder: false))
        }
        defer { close(file) }
        var content = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = read(file, &buffer, buffer.count)
            if count < 0 {
                if errno == EINTR { continue }
                return .failed(.unreadable)
            }
            if count == 0 { break }
            content.append(buffer, count: count)
            if content.count > bytes.count { return .conflict(.differentContent) }
        }
        return content == bytes ? .alreadyThere : .conflict(.differentContent)
    }

    private static func failure(_ code: Int32, folder: Bool) -> Failure {
        switch code {
        case ENOENT where folder, ENOTDIR where folder: return .folderMissing
        case EACCES, EPERM, EROFS: return .notPermitted
        default: return .other(code)
        }
    }
}

#if DEBUG
    extension MeetingArchive {
        /// Real files in a temporary folder: names, every outcome, a race for one name, a folder that's gone.
        static func selfCheck() {
            let fileManager = FileManager.default
            let root = fileManager.temporaryDirectory.appendingPathComponent("yap-archive-check-\(UUID().uuidString)")
            try! fileManager.createDirectory(at: root, withIntermediateDirectories: false)
            defer { try? fileManager.removeItem(at: root) }

            // Names: the meeting's start, not today; the same day twice is two names; bytes decide the version;
            // nothing of the text is in the name.
            let utc = TimeZone(identifier: "UTC")!
            let morning = Date(timeIntervalSince1970: 1_790_000_000)  // 2026-09-21 14:13 UTC
            let a = Entry(id: UUID(), timestamp: morning, bytes: Data("# Meeting\n\n../../etc: secret\n".utf8))
            let b = Entry(id: UUID(), timestamp: morning.addingTimeInterval(3_600), bytes: a.bytes)
            let nameA = fileName(for: a, timeZone: utc)
            assert(nameA.hasPrefix("2026-09-21 1413 meeting-\(a.id.uuidString.lowercased())-") && nameA.hasSuffix(".md"))
            assert(nameA != fileName(for: b, timeZone: utc), "two meetings on one day")
            assert(nameA == fileName(for: Entry(id: a.id, timestamp: a.timestamp, bytes: a.bytes), timeZone: utc))
            let edited = Entry(id: a.id, timestamp: a.timestamp, bytes: Data("# Meeting\n\nrenamed\n".utf8))
            assert(nameA != fileName(for: edited, timeZone: utc), "new bytes, new version")
            assert(!nameA.contains("/") && !nameA.contains("secret"))
            assert(fileName(for: a, timeZone: TimeZone(identifier: "Asia/Shanghai")!).hasPrefix("2026-09-21 2213 "))

            let directory = open(root.path, O_RDONLY | O_DIRECTORY)
            defer { close(directory) }
            let bytes = Data("hello\n".utf8)
            assert(write(bytes, named: "one.md", in: directory) == .written)
            let path = root.appendingPathComponent("one.md").path
            let inode = (try! fileManager.attributesOfItem(atPath: path))[.systemFileNumber] as! Int
            assert(write(bytes, named: "one.md", in: directory) == .alreadyThere)
            assert((try! fileManager.attributesOfItem(atPath: path))[.systemFileNumber] as! Int == inode, "not rewritten")
            // Edited by the user: kept as it is.
            try! Data("hello, edited\n".utf8).write(to: URL(fileURLWithPath: path))
            assert(write(bytes, named: "one.md", in: directory) == .conflict(.differentContent))
            assert(fileManager.contents(atPath: path) == Data("hello, edited\n".utf8))
            // A link is never followed, even to the same bytes; neither it nor its target changes.
            let target = root.appendingPathComponent("target.txt")
            try! bytes.write(to: target)
            try! fileManager.createSymbolicLink(atPath: root.appendingPathComponent("link.md").path, withDestinationPath: target.path)
            assert(write(Data("other\n".utf8), named: "link.md", in: directory) == .conflict(.symbolicLink))
            assert(write(bytes, named: "link.md", in: directory) == .conflict(.symbolicLink))
            assert(fileManager.contents(atPath: target.path) == bytes)
            try! fileManager.createDirectory(at: root.appendingPathComponent("folder.md"), withIntermediateDirectories: false)
            assert(write(bytes, named: "folder.md", in: directory) == .conflict(.notAFile))
            // A race for one name: one writer creates it, the rest find it; the file is one writer's bytes, whole.
            let candidates = (0..<8).map { Data("writer \($0 % 2)\n".utf8 + Data(repeating: UInt8($0 % 2), count: 200_000)) }
            let outcomes = UnsafeMutableBufferPointer<Outcome>.allocate(capacity: candidates.count)
            defer { outcomes.deallocate() }
            DispatchQueue.concurrentPerform(iterations: candidates.count) { index in
                (outcomes.baseAddress! + index).initialize(to: write(candidates[index], named: "race.md", in: directory))
            }
            let raced = fileManager.contents(atPath: root.appendingPathComponent("race.md").path)
            assert(outcomes.filter { $0 == .written }.count == 1)
            let winner = candidates.firstIndex(of: raced ?? Data())!
            for index in candidates.indices where outcomes[index] != .written {
                assert(outcomes[index] == (candidates[index] == candidates[winner] ? .alreadyThere : .conflict(.differentContent)))
            }
            // Nothing but the files above: no temporary file is left.
            let names = Set(try! fileManager.contentsOfDirectory(atPath: root.path))
            assert(names == ["one.md", "target.txt", "link.md", "folder.md", "race.md"], "\(names)")
            // A folder that's gone isn't made again.
            let gone = root.appendingPathComponent("gone", isDirectory: true)
            let report = export([a, b], to: gone)
            assert(report.failures.count == 2 && report.items.allSatisfy { $0.outcome == .failed(.folderMissing) })
            assert(!fileManager.fileExists(atPath: gone.path))
        }
    }
#endif
