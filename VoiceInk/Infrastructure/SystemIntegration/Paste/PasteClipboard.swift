import AppKit

/// The pasteboard a paste goes through, and the restore of what the user had there. The app pastes through `general`;
/// checks give CursorPaster one on a private pasteboard (NSPasteboard(name:)), so nothing they do reaches the
/// clipboard the user copies to.
@MainActor
final class PasteClipboard {
    typealias Snapshot = [[(NSPasteboard.PasteboardType, Data)]]

    static let general = PasteClipboard(.general)

    let pasteboard: NSPasteboard
    private var restoreTasks: [UUID: Task<Void, Never>] = [:]
    private(set) var isClosed = false
    #if DEBUG
        /// The next writes clear the pasteboard, leave a half-written item and report failure, as a failed
        /// `writeObjects` would. For the paste-session check only.
        var writeFails = false
    #endif

    init(_ pasteboard: NSPasteboard) {
        self.pasteboard = pasteboard
    }

    /// One paste's text on the pasteboard.
    struct Claim: Equatable {
        let text: String
        let sessionID: String?
        fileprivate let id = UUID()
    }

    private var originals: [UUID: Snapshot] = [:]

    /// Puts the text on the pasteboard for ⌘V. `restoreLater`: what is there now is kept, to be put back after the
    /// paste, and the text is marked transient so clipboard-history apps skip it. Nil when the write failed.
    func write(_ text: String, restoreLater: Bool) -> Claim? {
        guard !isClosed else { return nil }
        let original = restoreLater ? snapshot() : nil
        let claim = Claim(text: text, sessionID: restoreLater ? UUID().uuidString : nil)
        #if DEBUG
            if writeFails {
                writeHalfItem()
                return nil
            }
        #endif
        guard ClipboardManager.setClipboard(text, transient: restoreLater, sessionID: claim.sessionID, on: pasteboard)
        else { return nil }
        if let original { originals[claim.id] = original }
        return claim
    }

    /// Whether the pasteboard still holds what `claim` wrote.
    func owns(_ claim: Claim) -> Bool {
        !isClosed && pasteboard.string(forType: .string) == claim.text
            && pasteboard.string(forType: ClipboardManager.pasteSessionType) == claim.sessionID
    }

    /// ⌘V went out: after `delay`, what the user had goes back, unless the pasteboard changed since.
    func pasteSent(_ claim: Claim, restoreAfter delay: TimeInterval, sleep: @escaping (TimeInterval) async -> Void) {
        guard let original = originals.removeValue(forKey: claim.id) else { return }
        let key = UUID()
        restoreTasks[key] = Task { @MainActor [weak self] in
            await sleep(delay)
            guard let self, !Task.isCancelled else { return }
            self.restoreTasks[key] = nil
            guard self.owns(claim) else { return }
            ClipboardManager.restoreClipboard(Self.items(from: original), on: self.pasteboard)
        }
    }

    /// The paste didn't go out: its text stays on the pasteboard for the user to paste.
    func pasteNotSent(_ claim: Claim) {
        originals[claim.id] = nil
    }

    /// Checks: cancels and waits out every pending restore, then forgets what was kept; nothing is written after this.
    /// The caller releases a private pasteboard afterwards.
    func close() async {
        isClosed = true
        let tasks = restoreTasks.values
        restoreTasks.removeAll()
        originals.removeAll()
        for task in tasks {
            task.cancel()
            await task.value
        }
    }

    private func snapshot() -> Snapshot {
        (pasteboard.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        }
    }

    private static func items(from snapshot: Snapshot) -> [NSPasteboardItem] {
        snapshot.map { pairs in
            let item = NSPasteboardItem()
            for (type, data) in pairs { item.setData(data, forType: type) }
            return item
        }
    }

    #if DEBUG
        private func writeHalfItem() {
            pasteboard.clearContents()
            let item = NSPasteboardItem()
            item.setData(Data([0]), forType: NSPasteboard.PasteboardType("me.sma1lboy.yap.half-written"))
            pasteboard.writeObjects([item])
        }
    #endif
}
