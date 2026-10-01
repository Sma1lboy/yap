import AppKit
import Foundation

/// The Scratchpad's text: one plain-text file in Application Support, never synced. Typing saves after a short
/// pause; appending a dictation, clearing and closing the window save at once.
@MainActor
final class ScratchpadStore: ObservableObject {
    static let shared = ScratchpadStore(fileURL: defaultFileURL)

    @Published var text: String {
        didSet { if text != oldValue { scheduleSave() } }
    }

    private let fileURL: URL
    private var saveTask: Task<Void, Never>?

    init(fileURL: URL) {
        self.fileURL = fileURL
        self.text = Self.read(fileURL)
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.save() } }
    }

    private static var defaultFileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(AppIdentity.supportDirectoryName, isDirectory: true)
            .appendingPathComponent("Scratchpad.txt")
    }

    /// Shown when a dictation found no text field and went to the Scratchpad instead.
    static var noTextFieldMessage: String {
        String(localized: "Copied to clipboard and added to your Scratchpad. No text field was focused, so Yap didn't paste.")
    }

    func append(dictation: String, at date: Date = Date()) {
        text = Self.appending(dictation, to: text, at: date)
        save()
    }

    func clear() {
        text = ""
        save()
    }

    func save() {
        saveTask?.cancel()
        saveTask = nil
        Self.write(text, to: fileURL)
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            self?.save()
        }
    }

    // MARK: - Pure logic

    /// "2026-09-29 17:05" on its own line, then the dictation.
    nonisolated static func entry(_ dictation: String, at date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date) + "\n" + dictation
    }

    /// The dictation after a blank line, ending in a newline so the cursor lands below it. Blank dictations change nothing.
    nonisolated static func appending(
        _ dictation: String, to existing: String, at date: Date, timeZone: TimeZone = .current
    ) -> String {
        let dictation = dictation.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !dictation.isEmpty else { return existing }
        let block = entry(dictation, at: date, timeZone: timeZone) + "\n"
        let head = existing.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
        return head.isEmpty ? block : head + "\n\n" + block
    }

    nonisolated static func read(_ url: URL) -> String {
        (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    nonisolated static func write(_ text: String, to url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }

    #if DEBUG
        static func selfCheck() {
            let utc = TimeZone(identifier: "UTC")!
            let stamped = Date(timeIntervalSince1970: 1_790_000_000)  // 2026-09-21 14:13 UTC
            let stamp = entry("hi", at: stamped, timeZone: utc)
            assert(stamp == "2026-09-21 14:13\nhi", stamp)
            // First entry into an empty pad, then a second one after a blank line; trailing whitespace is absorbed.
            let first = appending("  buy milk \n", to: "", at: stamped, timeZone: utc)
            assert(first == "2026-09-21 14:13\nbuy milk\n")
            let second = appending("call Sara", to: first + "\n\n", at: stamped, timeZone: utc)
            assert(second == first + "\n2026-09-21 14:13\ncall Sara\n", second)
            // Typed text before the first dictation is kept.
            assert(appending("x", to: "my note", at: stamped, timeZone: utc).hasPrefix("my note\n\n2026-09-21 14:13\nx"))
            assert(appending("   \n", to: "keep", at: stamped, timeZone: utc) == "keep", "blank dictation is dropped")
            // Persistence round trip, including Chinese text and an absent file.
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("yap-scratchpad-check-\(UUID().uuidString)/Scratchpad.txt")
            defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            assert(read(url) == "")
            write(second + "换行测试", to: url)
            assert(read(url) == second + "换行测试")
            let store = ScratchpadStore(fileURL: url)
            assert(store.text == second + "换行测试", "a new store starts from the saved file")
            store.append(dictation: "again", at: stamped)
            assert(read(url).hasSuffix("again\n"), "append saves at once")
            store.clear()
            assert(read(url) == "" && store.text == "", "clear saves at once")
        }
    #endif
}
