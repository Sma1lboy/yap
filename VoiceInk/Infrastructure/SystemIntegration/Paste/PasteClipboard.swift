import AppKit

/// The pasteboard a paste goes through, and Yap's hold on it from a paste's write until what the user had is put back.
/// The app pastes through `general`; checks give CursorPaster one on a private pasteboard (NSPasteboard(name:)), so
/// nothing they do reaches the clipboard the user copies to.
///
/// A paste owns the pasteboard while its change count is still the one its own write made (and the text and paste
/// session still match). Every write by anyone else, the user copying the same text with the same session data
/// included, bumps the count. Pastes in a row hand the user's original contents on: a paste that starts while the
/// last one still owns the pasteboard keeps that paste's original instead of taking the last dictation for it, and
/// the last one's restore is called off. The original lives only here, in memory, until it is put back, the
/// pasteboard changes hands, or the paste fails; it is never logged or saved.
///
/// The ownership check and the write or ⌘V after it are two steps; another app can write in between, which no check
/// here can rule out (NSPasteboard has no compare-and-swap).
@MainActor
final class PasteClipboard {
    typealias Snapshot = [[(NSPasteboard.PasteboardType, Data)]]

    static let general = PasteClipboard(.general)

    let pasteboard: NSPasteboard
    private var lease: Lease?
    private var restoreTask: Task<Void, Never>?
    private(set) var isClosed = false
    #if DEBUG
        /// Writes clear the pasteboard, leave a half-written item and report failure, as a failed `writeObjects`
        /// would. For the paste-session check only.
        var writeFails = false
    #endif

    init(_ pasteboard: NSPasteboard) {
        self.pasteboard = pasteboard
    }

    /// One paste's write: its text, its paste session (nil when restore is off) and the change count it left.
    struct Claim: Equatable {
        let text: String
        let sessionID: String?
        let changeCount: Int
    }

    private struct Lease {
        let claim: Claim
        /// What the user had before the first of the pastes in a row; nil when restore is off.
        let original: Snapshot?
    }

    /// Puts the text on the pasteboard for ⌘V. `restoreLater`: what the user had is kept, to be put back after the
    /// paste, and the text is marked transient (with a paste session) so clipboard-history apps skip it.
    /// Nil when the write failed; the pasteboard then holds the original again if nobody else wrote to it meanwhile.
    func write(_ text: String, restoreLater: Bool) -> Claim? {
        guard !isClosed else { return nil }
        var original: Snapshot?
        if restoreLater {
            if let lease, let kept = lease.original, owns(lease.claim) {
                original = kept
            } else {
                original = snapshot()
            }
        }
        endLease()

        let sessionID = restoreLater ? UUID().uuidString : nil
        let before = pasteboard.changeCount
        let changeCount: Int?
        #if DEBUG
            changeCount = writeFails ? writeHalfItem() : ClipboardManager.setClipboard(
                text, transient: restoreLater, sessionID: sessionID, on: pasteboard)
        #else
            changeCount = ClipboardManager.setClipboard(text, transient: restoreLater, sessionID: sessionID, on: pasteboard)
        #endif
        guard let changeCount else {
            // Only our clear since `before`: what is there is our half-written item, not someone else's copy.
            if let original, pasteboard.changeCount == before + 1 {
                ClipboardManager.restoreClipboard(Self.items(from: original), on: pasteboard)
            }
            return nil
        }
        let claim = Claim(text: text, sessionID: sessionID, changeCount: changeCount)
        lease = Lease(claim: claim, original: original)
        return claim
    }

    /// Whether the pasteboard still holds exactly what `claim` wrote: nobody has written to it since.
    func owns(_ claim: Claim) -> Bool {
        !isClosed && pasteboard.changeCount == claim.changeCount
            && pasteboard.string(forType: .string) == claim.text
            && pasteboard.string(forType: ClipboardManager.pasteSessionType) == claim.sessionID
    }

    /// ⌘V went out: after `delay`, what the user had goes back, if the paste still owns the pasteboard then. A paste
    /// that starts first takes the original over and calls this restore off.
    func pasteSent(_ claim: Claim, restoreAfter delay: TimeInterval, sleep: @escaping (TimeInterval) async -> Void) {
        guard let lease, lease.claim == claim else { return }
        guard lease.original != nil else { return endLease() }
        restoreTask = Task { @MainActor [weak self] in
            await sleep(delay)
            guard let self, !Task.isCancelled else { return }
            self.restore(claim)
        }
    }

    /// The paste didn't go out (⌘V not sent, or the pasteboard changed first): what is there stays, the original is
    /// let go. A ⌘V that couldn't be sent leaves the text for the user to paste; it isn't swapped back for the original.
    func pasteNotSent(_ claim: Claim) {
        guard lease?.claim == claim else { return }
        endLease()
    }

    /// Puts the original back if `claim` still owns the pasteboard; ends its lease either way.
    @discardableResult
    func restore(_ claim: Claim) -> Bool {
        guard let lease, lease.claim == claim else { return false }
        restoreTask = nil
        self.lease = nil
        guard owns(claim), let original = lease.original else { return false }
        ClipboardManager.restoreClipboard(Self.items(from: original), on: pasteboard)
        return true
    }

    /// Checks: cancels and waits out the pending restore and forgets the original; nothing is written after this.
    /// The caller releases a private pasteboard afterwards.
    func close() async {
        isClosed = true
        let task = restoreTask
        endLease()
        await task?.value
    }

    private func endLease() {
        restoreTask?.cancel()
        restoreTask = nil
        lease = nil
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
        private func writeHalfItem() -> Int? {
            pasteboard.clearContents()
            let item = NSPasteboardItem()
            item.setData(Data([0]), forType: NSPasteboard.PasteboardType("me.sma1lboy.yap.half-written"))
            pasteboard.writeObjects([item])
            return nil
        }

        /// The lease on a private pasteboard: pastes in a row keep the first original, a copy by the user (same text
        /// and session included) ends it, a failed write puts the original back, restore off keeps nothing.
        static func selfCheck() {
            let pasteboard = NSPasteboard(name: NSPasteboard.Name("yap.selfcheck.\(UUID().uuidString)"))
            defer { pasteboard.releaseGlobally() }
            let clipboard = PasteClipboard(pasteboard)
            func put(_ text: String, extra: NSPasteboard.PasteboardType? = nil, session: String? = nil) {
                pasteboard.clearContents()
                let item = NSPasteboardItem()
                item.setString(text, forType: .string)
                if let extra { item.setData(Data([7]), forType: extra) }
                if let session { item.setString(session, forType: ClipboardManager.pasteSessionType) }
                pasteboard.writeObjects([item])
            }
            let extra = NSPasteboard.PasteboardType("com.example.yap-selfcheck")

            put("mine", extra: extra)
            guard let a = clipboard.write("A", restoreLater: true), let b = clipboard.write("B", restoreLater: true)
            else { return assertionFailure("private pasteboard write failed") }
            assert(!clipboard.owns(a) && clipboard.owns(b), "B's write ends A's hold")
            assert(!clipboard.restore(a), "A's restore no longer applies")
            assert(clipboard.restore(b) && pasteboard.string(forType: .string) == "mine", "B restores what was there before A")
            assert(pasteboard.data(forType: extra) == Data([7]), "every type comes back")

            guard let c = clipboard.write("C", restoreLater: true) else { return assertionFailure() }
            put("C", session: c.sessionID)  // the user copies the same text with the same session data
            assert(!clipboard.owns(c) && !clipboard.restore(c), "a new revision isn't Yap's")
            assert(pasteboard.string(forType: .string) == "C")

            put("copied")
            guard let d = clipboard.write("D", restoreLater: true) else { return assertionFailure() }
            clipboard.writeFails = true
            assert(clipboard.write("E", restoreLater: true) == nil)
            clipboard.writeFails = false
            assert(pasteboard.string(forType: .string) == "copied", "a failed write puts the original back")
            assert(!clipboard.owns(d))

            guard let f = clipboard.write("F", restoreLater: false) else { return assertionFailure() }
            assert(clipboard.owns(f) && !clipboard.restore(f), "restore off keeps nothing to put back")
            assert(pasteboard.string(forType: .string) == "F")
        }
    #endif
}
