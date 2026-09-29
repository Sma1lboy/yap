import AVFoundation
import Foundation
import SwiftData

/// A recording the app quit or crashed in the middle of: its WAV is in Recordings/ but no History entry refers to
/// it, because the entry is only created once recording stops. Offered once at the next launch.
enum RecordingRecovery {
    /// Older unreferenced files are ordinary orphans (TranscriptionAutoCleanupService deletes them).
    static let maxAge: TimeInterval = 3 * 24 * 60 * 60
    static var recordingsDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(AppIdentity.supportDirectoryName).appendingPathComponent("Recordings")
    }
    private static let offeredKey = "OfferedRecoveryRecordings"

    /// Whether an unreferenced file in Recordings/ is a recent dictation WAV worth offering, and so must
    /// survive the orphan sweep. Folders (meetings/) never count.
    static func isCandidate(
        name: String, isDirectory: Bool, modified: Date, referenced: Set<String>, now: Date = Date()
    ) -> Bool {
        !isDirectory && name.lowercased().hasSuffix(".wav") && !referenced.contains(name)
            && now.timeIntervalSince(modified) < maxAge
    }

    /// The recorder writes the WAV header when the file closes. A file cut off before that has 0 frames as far as
    /// CoreAudio can tell, so set the RIFF and data sizes from the file's length. No-op on a healthy file.
    static func repairWAVHeader(_ url: URL) {
        guard var bytes = try? Data(contentsOf: url), bytes.count > 44,
            bytes.prefix(4) == Data("RIFF".utf8), bytes[8..<12] == Data("WAVE".utf8)
        else { return }
        func le32(_ at: Int) -> Int {
            (0..<4).reduce(0) { $0 | Int(bytes[at + $1]) << (8 * $1) }
        }
        func setLE32(_ value: Int, at: Int) {
            for i in 0..<4 { bytes[at + i] = UInt8((value >> (8 * i)) & 0xFF) }
        }
        var offset = 12
        while offset + 8 <= bytes.count {
            let id = String(decoding: bytes[offset..<offset + 4], as: UTF8.self)
            let size = le32(offset + 4)
            if id == "data" {
                let actual = (bytes.count - offset - 8) & ~1  // whole 16-bit samples
                guard size != actual else { return }
                setLE32(actual, at: offset + 4)
                setLE32(bytes.count - 8, at: 4)
                try? bytes.write(to: url)
                return
            }
            offset += 8 + size + (size & 1)
        }
    }

    /// Recent files with no History entry that hold audio worth transcribing, newest first.
    static func recoverableFiles(in directory: URL, referenced: Set<String>) -> [URL] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .contentModificationDateKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys)) ?? []
        let dated: [(url: URL, modified: Date)] = urls.compactMap { url in
            let values = try? url.resourceValues(forKeys: Set(keys))
            guard
                isCandidate(
                    name: url.lastPathComponent, isDirectory: values?.isDirectory ?? false,
                    modified: values?.contentModificationDate ?? .distantPast, referenced: referenced)
            else { return nil }
            return (url, values?.contentModificationDate ?? .distantPast)
        }
        return dated.sorted { $0.modified > $1.modified }.map(\.url).filter { url in
            repairWAVHeader(url)
            return (try? AVAudioFile(forReading: url)) != nil && RecordedAudioIssue.check(url) == nil
        }
    }

    /// At launch: offers the newest recoverable recording, once. Older ones stay on disk until they age out.
    // ponytail: one notification per launch; offering several would stack notifications, so add a picker if crashes repeat.
    @MainActor
    static func offerAtLaunch(modelContext: ModelContext, engine: VoiceInkEngine) {
        let referenced = Set(
            ((try? modelContext.fetch(FetchDescriptor<Transcription>())) ?? []).compactMap {
                $0.audioFileURL.flatMap(URL.init(string:))?.lastPathComponent
            })
        let offered = Set(UserDefaults.standard.stringArray(forKey: offeredKey) ?? [])
        let files = recoverableFiles(in: recordingsDirectory, referenced: referenced)
            .filter { !offered.contains($0.lastPathComponent) }
        guard let newest = files.first else { return }
        UserDefaults.standard.set(Array(offered.union(files.map(\.lastPathComponent))), forKey: offeredKey)

        NotificationManager.shared.showNotification(
            title: String(localized: "Yap quit while recording. Transcribe it?"),
            type: .info,
            duration: 30,
            actionButton: (
                String(localized: "Transcribe"),
                { Task { await engine.transcribeRecoveredRecording(newest) } }
            ),
            secondaryButton: (
                String(localized: "Discard"), { try? FileManager.default.removeItem(at: newest) }
            )
        )
    }

    #if DEBUG
        static func selfCheck() {
            let now = Date()
            let fresh = now.addingTimeInterval(-3600)
            func candidate(_ name: String, dir: Bool = false, at: Date, referenced: Set<String> = []) -> Bool {
                isCandidate(name: name, isDirectory: dir, modified: at, referenced: referenced, now: now)
            }
            assert(candidate("a.wav", at: fresh))
            assert(!candidate("a.wav", at: fresh, referenced: ["a.wav"]))  // has a History entry
            assert(!candidate("a.wav", at: now.addingTimeInterval(-maxAge - 1)))  // an ordinary old orphan
            assert(!candidate("meetings", dir: true, at: fresh))
            assert(!candidate("notes.txt", at: fresh))

            // A WAV cut off before its header was finalized (sizes 0) reads as 1 s of audio after the repair.
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).wav")
            defer { try? FileManager.default.removeItem(at: url) }
            var wav = Data("RIFF".utf8) + Data(repeating: 0, count: 4) + Data("WAVEfmt ".utf8)
            wav += Data([16, 0, 0, 0, 1, 0, 1, 0, 0x80, 0x3E, 0, 0, 0, 0x7D, 0, 0, 2, 0, 16, 0])
            wav += Data("data".utf8) + Data(repeating: 0, count: 4)
            wav += Data((0..<16_000).flatMap { i -> [UInt8] in [UInt8(truncatingIfNeeded: i * 37), 0x20] })
            try! wav.write(to: url)
            repairWAVHeader(url)
            assert((try? AVAudioFile(forReading: url).length) == 16_000)
            assert(RecordedAudioIssue.check(url) == nil)
            repairWAVHeader(url)  // healthy file: unchanged
            assert((try? AVAudioFile(forReading: url).length) == 16_000)
        }
    #endif
}
