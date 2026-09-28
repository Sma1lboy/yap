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

    fileprivate struct Record: @unchecked Sendable {
        let processID: pid_t
        let appElement: AXUIElement
        let target: AXUIElement
        let range: NSRange
        let text: String
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

    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "LastPasteEditor")
    private var record: Record?
    private var captureTask: Task<Void, Never>?

    /// CursorPaster, once ⌘V was posted. The field is read a moment later, when the paste has landed.
    func pasteDidFinish(text: String, processID: pid_t?) {
        record = nil
        captureTask?.cancel()
        guard let processID, !text.isEmpty, AXIsProcessTrusted(),
            processID != ProcessInfo.processInfo.processIdentifier
        else { return }
        captureTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            let captured = await Task.detached { Self.capture(text: text, processID: processID) }.value
            guard !Task.isCancelled else { return }
            record = captured
            if captured == nil { logger.notice("Last paste not located; undo and rewrite won't be offered for it") }
        }
    }

    // MARK: - Undo

    /// Removes the last paste. Shortcut, or a dictation that is only a scratch phrase ("scratch that", 删掉刚才那句).
    func undoLastPaste() async {
        switch await selectLastPaste() {
        case .failure(let failure):
            notify(failure)
        case .success(let record):
            CursorPaster.performDeleteKey()
            self.record = nil
            logger.notice("Last paste removed (\(record.text.count, privacy: .public) characters)")
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

        switch await selectLastPaste() {
        case .failure(let failure):
            notify(failure)
        case .success:
            // Replaces the selection; CursorPaster reports it back here, so it becomes the new last paste.
            _ = await CursorPaster.startPasteAtCursor(rewritten).value
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
        NotificationManager.shared.showNotification(title: failure.message, type: .warning, duration: 5)
    }

    private func selectLastPaste() async -> Result<Record, Failure> {
        guard let record else { return .failure(.nothingPasted) }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == record.processID else {
            return .failure(.focusChanged)
        }
        return await Task.detached { Self.select(record) }.value
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

    nonisolated private static func capture(text: String, processID: pid_t) -> Record? {
        let reader = AutoLearnAXTextReader()
        let appElement = AXUIElementCreateApplication(processID)
        defer { reader.restoreWebAccessibility(processID: processID, appElement: appElement) }
        for reading in reader.focusedReadings(processID: processID) {
            if let range = pastedRange(of: text, selection: reading.selection, in: reading.fieldText) {
                return Record(
                    processID: processID, appElement: reading.appElement, target: reading.targetElement, range: range,
                    text: text)
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
