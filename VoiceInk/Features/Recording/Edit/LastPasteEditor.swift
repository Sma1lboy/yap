import AppKit
import ApplicationServices
import os

/// The last text Yap pasted and where it landed, so it can be undone or rewritten by voice in place.
/// Recorded after every paste (Accessibility only, whether or not Auto Learn is on). Before changing anything it
/// checks that the same field is still focused and still holds exactly that text at that spot, then selects it
/// through Accessibility and checks the selection; if any of that fails it leaves the text alone and says why.
@MainActor
final class LastPasteEditor {
    static let shared = LastPasteEditor()

    struct Record: @unchecked Sendable {
        let processID: pid_t
        let appElement: AXUIElement
        let target: AXUIElement
        let range: NSRange
        let text: String
        /// What the paste replaced (the selection at paste time). Empty when it only inserted.
        let replaced: String
    }

    enum Failure: Error, Equatable {
        case nothingPasted, focusChanged, edited, cannotSelect, aiNotConfigured, rewriteFailed(String)

        var message: String {
            switch self {
            case .nothingPasted:
                return String(localized: "No recent dictation Yap can find to change.")
            case .focusChanged:
                return String(localized: "The field with your last dictation isn't focused anymore.")
            case .edited:
                return String(localized: "Your last dictation was edited since, so Yap left it alone.")
            case .cannotSelect:
                return String(localized: "This app doesn't let Yap select your last dictation.")
            case .aiNotConfigured:
                return String(localized: "To rewrite by voice, turn on AI enhancement with a provider in this mode.")
            case .rewriteFailed(let description):
                return EnhancementFailureFormatter.message(description: description)
            }
        }
    }

    /// What Undo and Rewrite touch outside their own logic: checking and selecting the last paste through
    /// Accessibility, and telling the user why it can't be changed. `live` is the app's; PasteSessionCheck installs its
    /// own (`check`), with no Accessibility call and no notification.
    struct Outlets {
        /// The app in front is still the last paste's, its field is focused and holds the text at that spot, and the
        /// text is now selected there.
        var select: @MainActor (Record) async -> Result<Record, Failure>
        var notify: @MainActor (Failure) -> Void
    }

    /// What Undo or the paste after a rewrite did, for the log and the checks.
    enum Edit: Equatable {
        case refused(Failure)
        case deleted(CursorPaster.KeyResult)
        case pasted(CursorPaster.PasteResult)
    }

    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "LastPasteEditor")
    private let outlets: Outlets
    private var record: Record?
    private var captureTask: Task<Void, Never>?

    private init(outlets: Outlets = .live, record: Record? = nil) {
        self.outlets = outlets
        self.record = record
    }

    #if DEBUG
        /// PasteSessionCheck: an editor of its own whose last paste is `record`, with `outlets` (never `.shared`).
        static func check(_ outlets: Outlets, record: Record) -> LastPasteEditor {
            LastPasteEditor(outlets: outlets, record: record)
        }
    #endif

    /// CursorPaster, once ⌘V was posted. The field is read a moment later, when the paste has landed.
    func pasteDidFinish(text: String, processID: pid_t?, replacing replaced: String = "") {
        record = nil
        captureTask?.cancel()
        guard let processID, !text.isEmpty, AXIsProcessTrusted(),
            processID != ProcessInfo.processInfo.processIdentifier
        else { return }
        captureTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            let captured = await Task.detached { Self.capture(text: text, processID: processID, replaced: replaced) }.value
            guard !Task.isCancelled else { return }
            record = captured
            if captured == nil { logger.notice("Last paste not located; undo and rewrite won't be offered for it") }
        }
    }

    // MARK: - Undo

    /// Takes the last paste back: puts the text it replaced there again, or just deletes it when it replaced nothing.
    /// Shortcut, or a dictation that is only a scratch phrase ("scratch that", 删掉刚才那句). Its request is taken
    /// first, so a paste or Finish and Send key still waiting isn't sent after this, and an earlier Undo whose Delete
    /// or paste comes late doesn't go out as well. Both go to the field the last paste was selected in, and nowhere
    /// else. CursorPaster says so when they don't go out.
    @discardableResult
    func undoLastPaste() async -> Edit {
        let request = CursorPaster.newRequest()
        switch await selectLastPaste() {
        case .failure(let failure):
            notify(failure)
            return .refused(failure)
        case .success(let record):
            if record.replaced.isEmpty {
                let deleted = await CursorPaster.deleteSelection(in: record.processID, field: record.target, request: request)
                guard deleted == .sent else {
                    logger.notice("Undo didn't delete the last paste: \(String(describing: deleted), privacy: .public)")
                    return .deleted(deleted)
                }
                self.record = nil
                logger.notice("Last paste removed (\(record.text.count, privacy: .public) characters)")
                return .deleted(deleted)
            } else {
                // Becomes the new last paste, so undoing again brings the rewrite back.
                let result = await CursorPaster.startPasteAtCursor(
                    record.replaced, target: record.pasteTarget, request: request
                ).value.result
                logger.notice("Undo pasting the text the last paste replaced (\(record.replaced.count, privacy: .public) characters): \(String(describing: result), privacy: .public)")
                return .pasted(result)
            }
        }
    }

    // MARK: - Rewrite

    /// Before recording the instruction: the last paste must still be there, and it's selected so the rewrite
    /// replaces it. False (after telling the user why) when it can't be edited.
    func prepareRewrite() async -> Bool {
        if case .failure(let failure) = await selectLastPaste() {
            notify(failure)
            return false
        }
        return true
    }

    /// The spoken instruction arrived: rewrite the last paste with the mode's AI provider and paste the result
    /// over it. The paste is checked again first, since the user may have edited it meanwhile.
    func rewriteLastPaste(instruction: String, enhancementService: AIEnhancementService?, aiService: AIService?) async {
        let instruction = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !instruction.isEmpty, let record else { return notify(.nothingPasted) }
        guard let enhancementService, let aiService else { return notify(.aiNotConfigured) }
        let base = ModeRuntimeResolver.currentEnhancementConfiguration(
            enhancementService: enhancementService, aiService: aiService)
        let prompt = CustomPrompt(title: "Rewrite Last Dictation", promptText: Self.rewritePrompt, useSystemInstructions: false)
        // Checked with the rewrite prompt in place: the mode's own prompt selection doesn't matter here.
        guard base.provider != nil, base.provider != .voiceInkRefine,
            enhancementService.isConfigured(for: base.replacingPrompt(prompt))
        else { return notify(.aiNotConfigured) }

        let rewritten: String
        do {
            let result = try await enhancementService.enhance(
                Self.rewriteInput(text: record.text, instruction: instruction), configuration: base.replacingPrompt(prompt))
            rewritten = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return notify(.rewriteFailed(EnhancementFailureFormatter.description(for: error)))
        }
        guard !rewritten.isEmpty else { return notify(.rewriteFailed(String(localized: "The AI returned no text."))) }
        await pasteRewrite(rewritten)
    }

    /// The rewrite came back: select the last paste again and paste `rewritten` over it, into that field only. The
    /// request is taken before the selection, as Undo's is, so a dictation that starts meanwhile goes out instead.
    @discardableResult
    func pasteRewrite(_ rewritten: String) async -> Edit {
        let request: CursorPaster.Request? = nil
        switch await selectLastPaste() {
        case .failure(let failure):
            notify(failure)
            return .refused(failure)
        case .success(let record):
            // Replaces the selection; CursorPaster reports it back here, so it becomes the new last paste.
            return .pasted(
                await CursorPaster.startPasteAtCursor(rewritten, target: record.pasteTarget, request: request).value.result)
        }
    }

    static let rewritePrompt = """
        The input holds TEXT the user dictated a moment ago and an INSTRUCTION they just spoke about how to change it. \
        Apply the instruction to TEXT and output only the changed text: no explanation, quotes or tags. Keep \
        everything the instruction doesn't ask to change, and keep the language(s) of TEXT unless the instruction \
        asks for another one. English terms inside Chinese stay in English.
        """

    static func rewriteInput(text: String, instruction: String) -> String {
        "<TEXT>\n\(text)\n</TEXT>\n<INSTRUCTION>\n\(instruction)\n</INSTRUCTION>"
    }

    // MARK: - Scratch phrases

    /// Whole dictations that mean "take back the last one" instead of text to paste.
    static let scratchPhrases: Set<String> = [
        "删掉刚才那句", "删掉刚才那段", "删除刚才那句", "删除刚才那段", "撤销刚才那句", "撤销上次粘贴",
        "scratchthat", "deletethat", "undothat",
    ]

    static func isScratchPhrase(_ text: String) -> Bool {
        let normalized = text.lowercased().unicodeScalars
            .filter { !CharacterSet.punctuationCharacters.union(.symbols).union(.whitespacesAndNewlines).contains($0) }
        return scratchPhrases.contains(String(String.UnicodeScalarView(normalized)))
    }

    // MARK: - Accessibility

    private func notify(_ failure: Failure) {
        logger.notice("Last paste edit refused: \(String(describing: failure), privacy: .public)")
        outlets.notify(failure)
    }

    private func selectLastPaste() async -> Result<Record, Failure> {
        guard let record else { return .failure(.nothingPasted) }
        return await outlets.select(record)
    }

    nonisolated private static func select(_ record: Record) -> Result<Record, Failure> {
        let reader = AutoLearnAXTextReader()
        defer { reader.restoreWebAccessibility(processID: record.processID, appElement: record.appElement) }
        let readings = reader.focusedReadings(processID: record.processID)
        guard readings.contains(where: { CFEqual($0.targetElement, record.target) }) else { return .failure(.focusChanged) }
        guard let field = reader.textValue(from: record.target)?.text as NSString?,
            NSMaxRange(record.range) <= field.length, field.substring(with: record.range) == record.text
        else { return .failure(.edited) }

        var cfRange = CFRange(location: record.range.location, length: record.range.length)
        guard let value = AXValueCreate(.cfRange, &cfRange),
            AXUIElementSetAttributeValue(record.target, kAXSelectedTextRangeAttribute as CFString, value) == .success
        else { return .failure(.cannotSelect) }
        var selected: CFTypeRef?
        var selectedRange = CFRange()
        guard AXUIElementCopyAttributeValue(record.target, kAXSelectedTextRangeAttribute as CFString, &selected) == .success,
            let selected, CFGetTypeID(selected) == AXValueGetTypeID(),
            AXValueGetValue(selected as! AXValue, .cfRange, &selectedRange),
            selectedRange.location == cfRange.location, selectedRange.length == cfRange.length
        else { return .failure(.cannotSelect) }
        return .success(record)
    }

    /// The selected text in the focused field of `processID`, read just before a paste replaces it. Only the selection
    /// is read: ⌘V waits for this.
    nonisolated static func selectedText(processID: pid_t) -> String {
        let reader = AutoLearnAXTextReader()
        defer { reader.restoreWebAccessibility(processID: processID, appElement: AXUIElementCreateApplication(processID)) }
        return reader.focusedSelection(processID: processID)
    }

    nonisolated private static func capture(text: String, processID: pid_t, replaced: String) -> Record? {
        let reader = AutoLearnAXTextReader()
        let appElement = AXUIElementCreateApplication(processID)
        defer { reader.restoreWebAccessibility(processID: processID, appElement: appElement) }
        for reading in reader.focusedReadings(processID: processID) {
            if let range = pastedRange(of: text, selection: reading.selection, in: reading.fieldText) {
                return Record(
                    processID: processID, appElement: reading.appElement, target: reading.targetElement, range: range,
                    text: text, replaced: replaced)
            }
        }
        return nil
    }

    /// Where `pasted` sits in `field` right after the paste: just before the cursor, or else its only occurrence.
    nonisolated static func pastedRange(of pasted: String, selection: NSRange?, in field: String) -> NSRange? {
        let field = field as NSString
        let length = (pasted as NSString).length
        guard length > 0 else { return nil }
        if let selection, selection.length == 0, selection.location >= length, selection.location <= field.length {
            let range = NSRange(location: selection.location - length, length: length)
            if field.substring(with: range) == pasted { return range }
        }
        let first = field.range(of: pasted, options: .literal)
        guard first.location != NSNotFound else { return nil }
        let rest = NSRange(location: first.location + 1, length: field.length - first.location - 1)
        return field.range(of: pasted, options: .literal, range: rest).location == NSNotFound ? first : nil
    }
}

extension LastPasteEditor.Record {
    /// The app and the field the last paste was selected in: a paste over it goes there or nowhere.
    var pasteTarget: CursorPaster.Target { CursorPaster.Target(processID: processID, focus: .element(target)) }
}

extension LastPasteEditor.Outlets {
    @MainActor static let live = LastPasteEditor.Outlets(
        select: { record in
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == record.processID else {
                return .failure(.focusChanged)
            }
            return await Task.detached { LastPasteEditor.select(record) }.value
        },
        notify: { NotificationManager.shared.showNotification(title: $0.message, type: .warning, duration: 5) })
}

#if DEBUG
    extension LastPasteEditor {
        static func selfCheck() {
            let field = "Hi team, 今天发版。 See you"
            let pasted = "今天发版。"
            let end = (("Hi team, " + pasted) as NSString).length
            let range = pastedRange(of: pasted, selection: NSRange(location: end, length: 0), in: field)
            assert(range == NSRange(location: 9, length: (pasted as NSString).length))
            assert(pastedRange(of: pasted, selection: nil, in: field) == range, "only occurrence")
            assert(pastedRange(of: "ok", selection: nil, in: "ok and ok") == nil, "ambiguous without the cursor")
            assert(pastedRange(of: "ok", selection: NSRange(location: 9, length: 0), in: "ok and ok")
                == NSRange(location: 7, length: 2))
            assert(pastedRange(of: "gone", selection: nil, in: "nothing") == nil && pastedRange(of: "", selection: nil, in: "x") == nil)

            assert(isScratchPhrase("Scratch that.") && isScratchPhrase("删掉刚才那句。") && isScratchPhrase(" delete that! "))
            assert(!isScratchPhrase("scratch that part about Friday") && !isScratchPhrase("删掉刚才那句里的错字"))
            assert(rewriteInput(text: "a", instruction: "b") == "<TEXT>\na\n</TEXT>\n<INSTRUCTION>\nb\n</INSTRUCTION>")
        }
    }
#endif
