import AppKit
import Carbon
import Foundation
import os

class CursorPaster {
    private static let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "CursorPaster")

    enum PasteResult: Equatable {
        case commandPosted
        /// The key events / AppleScript couldn't be sent: the text stays on the clipboard for the user to paste.
        /// Also a clipboard write that failed: the text goes to the Scratchpad and the clipboard is put back.
        case commandNotPosted
        /// When ⌘V was due the clipboard no longer held this paste's text (the user copied something, or another
        /// paste replaced it): no key was sent, the clipboard is left as it is, and the text goes to the Scratchpad.
        case clipboardChanged
        /// No Accessibility permission: the text stays on the clipboard for the user to paste.
        case leftOnClipboard
        /// No editable element focused: the text stays on the clipboard and goes to the Scratchpad.
        case sentToScratchpad
        /// When ⌘V was due a different app or field was in front than the paste was for (or the app it was for wasn't
        /// in front when it started): no key was sent, and the text goes to the Scratchpad.
        case targetChanged
        /// A newer paste (or Undo) started, or the paste was cancelled, before ⌘V: no key was sent, the text goes to
        /// the Scratchpad.
        case superseded

        var didPostPasteCommand: Bool {
            self == .commandPosted
        }
    }

    struct PasteOutcome {
        let result: PasteResult
        let autoLearnGeneration: UInt64?
        /// System uptime when ⌘V went out: the V key-down, or when the AppleScript paste returned.
        var commandTime: TimeInterval?
        /// Set when ⌘V went out: the request and target a key sent after it (Finish and Send) is checked against.
        var sent: SentRequest?
    }

    /// A paste whose ⌘V went out: which request it was and where it went.
    struct SentRequest {
        let request: UInt64
        let target: Target
    }

    /// Where a paste or key is meant to go: the app in front and its focused element when the request took it.
    struct Target: @unchecked Sendable {
        let processID: pid_t?
        let focus: Focus
    }

    /// The target app's focused element as Accessibility reports it (kAXFocusedUIElementAttribute of the app).
    enum Focus: @unchecked Sendable {
        /// Compared with CFEqual, which is Accessibility's own identity: the same element of the same process.
        case element(AXUIElement)
        /// The app answered that nothing in it has focus.
        case none
        /// The query failed (unsupported, timed out, no app): this says nothing about the field.
        case unreadable
    }

    /// A key sent on its own (Finish and Send's Enter, Undo's Delete).
    enum KeyResult: Equatable {
        case sent
        /// The key events couldn't be made, or Accessibility isn't allowed.
        case notSent
        /// A different app or field is in front than the key was for.
        case targetChanged
        /// A newer paste or Undo started after the one this key belongs to.
        case superseded
    }

    /// A paste that went out, for Auto Learn and Undo/Rewrite Last Paste.
    struct SentPaste {
        let text: String
        let processID: pid_t?
        let dictationID: UUID?
        /// The selection the paste replaced.
        let replaced: String
    }

    enum Notice {
        case accessibilityMissing, noTextField, targetChanged
    }

    /// Everything a paste touches outside its own logic: the pasteboard, the app in front and its focused field, the
    /// keyboard, the clock, Auto Learn and Last Paste, the Scratchpad and notifications. `live` is the app's; checks
    /// install their own, on a private pasteboard with no key sent (`check`, PasteSessionCheck).
    struct Outlets {
        var clipboard: PasteClipboard
        /// Accessibility trust: both paste methods send keystrokes, which macOS drops without it.
        var canPostKeys: () -> Bool
        var focusCanTakeText: () -> Bool
        var frontmostApp: () -> (bundleID: String?, processID: pid_t?)
        /// The focused element of the app with this process ID, read off the main thread.
        var focusedElement: @MainActor (pid_t) async -> Focus
        /// Whether one of two elements contains the other (Accessibility parents), read off the main thread.
        var encloses: @MainActor (Focus, Focus) async -> Bool
        /// The focused field's selection in that app, which the paste replaces; nil: not read.
        var selectedText: (@Sendable (pid_t) -> String)?
        /// Shift, Control, Option or Fn held (still down from the shortcut).
        var modifiersHeld: () -> Bool
        /// Sends ⌘V; the time is when V went down.
        var postPasteKeys: @MainActor () async -> (result: PasteResult, commandTime: TimeInterval?)
        /// Sends Finish and Send's key; false when the events couldn't be made.
        var postSubmitKey: @MainActor (FinishAndSendKey) -> Bool
        /// Sends Delete; false when the events couldn't be made.
        var postDeleteKey: @MainActor () -> Bool
        /// Finish and Send is about to send its key after the paste with this Auto Learn generation.
        var autoSendWillPost: @MainActor (UInt64) async -> Void
        /// After ⌘V went out; returns the Auto Learn generation.
        var pasteSent: @MainActor (SentPaste) async -> UInt64?
        var toScratchpad: @MainActor (String) -> Void
        var notify: @MainActor (Notice) -> Void
        var restoreSettings: () -> (enabled: Bool, delay: TimeInterval)
        var now: () -> TimeInterval
        var sleep: (TimeInterval) async -> Void
    }

    @MainActor static var outlets = Outlets.live

    /// What happened just before the paste, which decides how long ⌘V waits after the clipboard is set.
    enum Lead {
        /// The dictation was stopped with its keyboard shortcut. Yap's recorder never had keyboard focus (it is a
        /// non-activating panel nobody clicked), so the app in front already has the focus ⌘V goes to.
        case shortcut
        /// A click in Yap's recorder or menu bar, a paste from History, or a selection Yap just set through
        /// Accessibility (Undo and Rewrite Last Paste): focus or selection may still be moving.
        case other
    }

    /// The clipboard is written and read back before the wait (ClipboardManager.setClipboard), so a local app reading
    /// it on ⌘V gets the new text without any wait; upstream VoiceInk pasted with none before May 2026 (caca8c4d^).
    /// What a wait still covers: focus coming back from Yap's own windows, and selection changes made through
    /// Accessibility, which web views apply asynchronously. After a shortcut stop neither happened; the 20 ms is
    /// margin, not measured.
    private static let prePasteDelay: TimeInterval = 0.10
    private static let shortcutPrePasteDelay: TimeInterval = 0.02
    private static let pasteShortcutEventDelay: TimeInterval = 0.01
    private static let minimumClipboardRestoreDelay: TimeInterval = 0.25

    /// Remote-desktop and VM windows copy the local clipboard to the other machine asynchronously.
    /// With the usual 0.1 s / 0.25 s timing the remote side pastes before it has the new text, or the
    /// restore lands first, so it pastes the previous dictation (upstream #928, Screen Sharing; the
    /// reporter's working setting was a 5 s restore delay). XQuartz copies the pasteboard to X11's
    /// clipboard the same way (its pbproxy), so X11 apps get the same timing.
    // ponytail: fixed bundle-ID list; add apps here as reports come in.
    private static let clipboardSyncingApps: Set<String> = [
        "com.apple.ScreenSharing",
        "com.microsoft.rdc.macos",  // Windows App / Microsoft Remote Desktop
        "com.parallels.desktop.console",
        "com.vmware.fusion",
        "com.utmapp.UTM",
        "com.teamviewer.TeamViewer",
        "com.philandro.anydesk",
        "com.p5sys.jump.mac.viewer",
        "com.citrix.receiver.icaviewer.mac",
        "com.realvnc.vncviewer",
        "org.xquartz.X11",
        "org.macosforge.xquartz.X11",
    ]

    static func pasteTiming(frontmostBundleID: String?, lead: Lead) -> (prePaste: TimeInterval, minimumRestore: TimeInterval) {
        if let frontmostBundleID, clipboardSyncingApps.contains(frontmostBundleID) {
            return (0.5, 5)
        }
        return (lead == .shortcut ? shortcutPrePasteDelay : prePasteDelay, minimumClipboardRestoreDelay)
    }

    /// `target`: the process the caller already chose (an app it activated, the one a record names); nil: the app in
    /// front when the paste starts.
    static func pasteAtCursor(_ text: String, target: pid_t? = nil) {
        Task {
            let pasteTask = await MainActor.run {
                startPasteAtCursor(text, target: target)
            }
            _ = await pasteTask.value
        }
    }

    /// The checks, the clipboard and the selection read start now, in the caller's turn on the main thread; the wait
    /// and ⌘V follow in the returned task. The wait counts from the clipboard write, so main-thread work queued ahead of
    /// that task (the recorder closing, the session cleanup) runs inside the wait instead of before it. `dictationID`:
    /// the dictation being pasted, whose SessionMetric gets what Auto Learn sees become of it.
    @MainActor
    @discardableResult
    static func startPasteAtCursor(
        _ text: String, lead: Lead = .other, dictationID: UUID? = nil, target: pid_t? = nil
    ) -> Task<PasteOutcome, Never> {
        let outlets = Self.outlets
        switch preparePaste(text, lead: lead, dictationID: dictationID, outlets: outlets) {
        case .finished(let outcome):
            return Task { outcome }
        case .ready(let paste):
            return Task { @MainActor in await post(paste, outlets: outlets) }
        }
    }

    /// Finish and Send: `key` after the paste in `outcome`, 150 ms after its ⌘V.
    @MainActor
    static func submit(_ key: FinishAndSendKey, after outcome: PasteOutcome) async -> KeyResult {
        let outlets = Self.outlets
        guard key.isEnabled, outcome.sent != nil else { return .notSent }
        await outlets.sleep(submitDelay)
        if let generation = outcome.autoLearnGeneration { await outlets.autoSendWillPost(generation) }
        guard outlets.canPostKeys() else { return .notSent }
        return outlets.postSubmitKey(key) ? .sent : .notSent
    }

    /// Undo Last Paste: deletes the selection it just set in `processID`'s focused field.
    @MainActor
    static func deleteSelection(in processID: pid_t) -> KeyResult {
        let outlets = Self.outlets
        guard outlets.canPostKeys() else { return .notSent }
        return outlets.postDeleteKey() ? .sent : .notSent
    }

    private static let submitDelay: TimeInterval = 0.15

    private enum Preparation {
        case finished(PasteOutcome)
        case ready(PreparedPaste)
    }

    private struct PreparedPaste {
        let text: String
        let lead: Lead
        let dictationID: UUID?
        let prePasteDelay: TimeInterval
        let restoreDelay: TimeInterval
        let clipboardSetAt: TimeInterval
        let targetProcessID: pid_t?
        /// The text the paste is about to replace, what Undo Last Paste restores; read while the wait runs.
        let replaced: Task<String, Never>?
        let claim: PasteClipboard.Claim
    }

    @MainActor
    private static func preparePaste(_ text: String, lead: Lead, dictationID: UUID?, outlets: Outlets) -> Preparation {
        let clipboard = outlets.clipboard

        // Leave the text on the clipboard (no restore) so nothing is lost.
        guard outlets.canPostKeys() else {
            logger.error("Accessibility permission missing; leaving text on the clipboard")
            _ = clipboard.write(text, restoreLater: false)
            outlets.notify(.accessibilityMissing)
            return .finished(PasteOutcome(result: .leftOnClipboard, autoLearnGeneration: nil))
        }

        // Nothing editable focused (desktop, Finder): ⌘V would go nowhere and the restore would then
        // take the text back off the clipboard. Keep it there and say so.
        guard outlets.focusCanTakeText() else {
            logger.notice("No editable element focused; leaving text on the clipboard and in the Scratchpad")
            _ = clipboard.write(text, restoreLater: false)
            outlets.toScratchpad(text)
            outlets.notify(.noTextField)
            return .finished(PasteOutcome(result: .sentToScratchpad, autoLearnGeneration: nil))
        }

        let frontmost = outlets.frontmostApp()
        let timing = pasteTiming(frontmostBundleID: frontmost.bundleID, lead: lead)
        let restore = outlets.restoreSettings()
        guard let claim = clipboard.write(text, restoreLater: restore.enabled) else {
            // Not on the clipboard and not pasted: the Scratchpad keeps it.
            logger.error("Failed to prepare clipboard for paste; text sent to the Scratchpad")
            outlets.toScratchpad(text)
            return .finished(PasteOutcome(result: .commandNotPosted, autoLearnGeneration: nil))
        }

        let targetProcessID = frontmost.processID
        let replaced = outlets.selectedText.map { read in
            Task.detached { targetProcessID.map(read) ?? "" }
        }
        return .ready(
            PreparedPaste(
                text: text, lead: lead, dictationID: dictationID, prePasteDelay: timing.prePaste,
                restoreDelay: max(restore.delay, timing.minimumRestore), clipboardSetAt: outlets.now(),
                targetProcessID: targetProcessID, replaced: replaced, claim: claim))
    }

    @MainActor
    private static func post(_ paste: PreparedPaste, outlets: Outlets) async -> PasteOutcome {
        await waitBeforePaste(paste, outlets: outlets)
        let replaced = await paste.replaced?.value ?? ""

        // ⌘V pastes whatever the clipboard holds now. If that isn't this paste's write any more, it would paste the
        // user's new copy or another paste's text, so no key goes out and the clipboard is left alone.
        guard outlets.clipboard.owns(paste.claim) else {
            logger.notice("The clipboard changed before ⌘V; nothing sent, text sent to the Scratchpad")
            outlets.clipboard.pasteNotSent(paste.claim)
            outlets.toScratchpad(paste.text)
            return PasteOutcome(result: .clipboardChanged, autoLearnGeneration: nil)
        }
        let posted = await outlets.postPasteKeys()
        guard posted.result.didPostPasteCommand else {
            // A paste that never reached the app must not take the text back off the clipboard.
            outlets.clipboard.pasteNotSent(paste.claim)
            return PasteOutcome(result: posted.result, autoLearnGeneration: nil)
        }
        let autoLearnGeneration = await outlets.pasteSent(
            SentPaste(text: paste.text, processID: paste.targetProcessID, dictationID: paste.dictationID, replaced: replaced))
        outlets.clipboard.pasteSent(paste.claim, restoreAfter: paste.restoreDelay, sleep: outlets.sleep)
        return PasteOutcome(
            result: .commandPosted, autoLearnGeneration: autoLearnGeneration, commandTime: posted.commandTime,
            sent: SentRequest(request: 0, target: Target(processID: paste.targetProcessID, focus: .unreadable)))
    }

    /// The pre-paste wait, counted from the clipboard write. After a shortcut stop the user may still be holding the
    /// shortcut's modifiers (toggle mode stops on a press), which would turn ⌘V into ⌥⌘V or ⇧⌘V; ⌘V waits for them to
    /// come up, until 0.1 s after the clipboard write at most, the wait it used to have.
    private static func waitBeforePaste(_ paste: PreparedPaste, outlets: Outlets) async {
        func elapsed() -> TimeInterval { outlets.now() - paste.clipboardSetAt }
        let first = paste.prePasteDelay - elapsed()
        if first > 0 { await outlets.sleep(first) }
        guard paste.lead == .shortcut else { return }
        while elapsed() < prePasteDelay, outlets.modifiersHeld() {
            await outlets.sleep(pasteShortcutEventDelay)
        }
    }

    /// Roles that are never a text target. Anything else (including an unreadable element) counts as text.
    private static let nonTextRoles: Set<String> = [
        "AXApplication", "AXWindow", "AXButton", "AXImage", "AXList", "AXOutline", "AXTable", "AXGroup",
    ]

    /// `focusRole` is nil when the system-wide focused element is missing; `readFailed` means the
    /// Accessibility query itself errored (the app doesn't expose it), which says nothing about the field.
    static func canTakeText(focusRole: String?, focusMissing: Bool, readFailed: Bool) -> Bool {
        if readFailed { return true }
        if focusMissing { return false }
        guard let focusRole else { return true }
        return !nonTextRoles.contains(focusRole)
    }

    fileprivate static func focusedElementCanTakeText() -> Bool {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.3)
        var focused: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused)
        guard status == .success, let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else {
            return canTakeText(focusRole: nil, focusMissing: status == .noValue, readFailed: status != .noValue)
        }
        var role: CFTypeRef?
        AXUIElementCopyAttributeValue(focused as! AXUIElement, kAXRoleAttribute as CFString, &role)
        return canTakeText(focusRole: role as? String, focusMissing: false, readFailed: false)
    }

    #if DEBUG
    static func selfCheck() {
        assert(canTakeText(focusRole: "AXTextField", focusMissing: false, readFailed: false))
        assert(canTakeText(focusRole: "AXTextArea", focusMissing: false, readFailed: false))
        assert(canTakeText(focusRole: "AXWebArea", focusMissing: false, readFailed: false), "unsure keeps pasting")
        assert(canTakeText(focusRole: nil, focusMissing: false, readFailed: false))
        assert(!canTakeText(focusRole: nil, focusMissing: true, readFailed: false), "no focused element")
        assert(!canTakeText(focusRole: "AXList", focusMissing: false, readFailed: false), "Finder list")
        assert(canTakeText(focusRole: nil, focusMissing: false, readFailed: true), "AX unreadable keeps pasting")
        // Clipboard-syncing apps keep their long wait whatever came before; a shortcut stop waits less than a click.
        for lead in [Lead.shortcut, .other] {
            assert(pasteTiming(frontmostBundleID: "com.apple.ScreenSharing", lead: lead) == (0.5, 5))
            assert(pasteTiming(frontmostBundleID: "org.xquartz.X11", lead: lead) == (0.5, 5))
        }
        let local = "com.apple.TextEdit"
        assert(pasteTiming(frontmostBundleID: local, lead: .shortcut).prePaste < pasteTiming(frontmostBundleID: local, lead: .other).prePaste)
        assert(pasteTiming(frontmostBundleID: local, lead: .other).prePaste == prePasteDelay, "clicks keep the old wait")
    }
    #endif

    @MainActor
    fileprivate static func postPasteCommand() async -> (result: PasteResult, commandTime: TimeInterval?) {
        if PasteMethod.current() == .appleScript {
            let posted = pasteUsingAppleScript()
            return posted ? (.commandPosted, ProcessInfo.processInfo.systemUptime) : (.commandNotPosted, nil)
        } else {
            return await pasteFromClipboard()
        }
    }

    // MARK: - AppleScript paste

    // "X – QWERTY ⌘" layouts remap to QWERTY when Command is held, so keystroke "v" resolves
    // the wrong key code. key code 9 (physical V) bypasses layout translation for those layouts.
    private static func makeScript(_ source: String) -> NSAppleScript? {
        let script = NSAppleScript(source: source)
        var error: NSDictionary?
        script?.compileAndReturnError(&error)
        return script
    }

    private static let pasteScriptKeystroke = makeScript(
        "tell application \"System Events\" to keystroke \"v\" using command down")
    private static let pasteScriptKeyCode = makeScript(
        "tell application \"System Events\" to key code 9 using command down")

    @MainActor
    private static var layoutSwitchesToQWERTYOnCommand: Bool {
        let source = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        guard let nameRef = TISGetInputSourceProperty(source, kTISPropertyLocalizedName) else { return false }
        return (Unmanaged<CFString>.fromOpaque(nameRef).takeUnretainedValue() as String).hasSuffix("⌘")
    }

    @MainActor
    private static func pasteUsingAppleScript() -> Bool {
        guard let script = layoutSwitchesToQWERTYOnCommand ? pasteScriptKeyCode : pasteScriptKeystroke else {
            logger.error("AppleScript paste script is unavailable")
            return false
        }

        var error: NSDictionary?
        script.executeAndReturnError(&error)
        if let error {
            logger.error("AppleScript paste failed: \(String(describing: error), privacy: .public)")
        }
        return error == nil
    }

    // MARK: - CGEvent paste

    // Posts Cmd+V via CGEvent without modifying the active input source.
    @MainActor
    private static func pasteFromClipboard() async -> (result: PasteResult, commandTime: TimeInterval?) {
        guard AXIsProcessTrusted() else {
            logger.error("Accessibility permission is required to paste with simulated key events")
            return (.commandNotPosted, nil)
        }

        let source = CGEventSource(stateID: .privateState)

        guard let cmdDown = CGEvent(keyboardEventSource: source, virtualKey: 0x37, keyDown: true),
            let vDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true),
            let vUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false),
            let cmdUp = CGEvent(keyboardEventSource: source, virtualKey: 0x37, keyDown: false)
        else {
            logger.error("Failed to create Cmd+V keyboard events")
            return (.commandNotPosted, nil)
        }

        cmdDown.flags = .maskCommand
        vDown.flags = .maskCommand
        vUp.flags = .maskCommand

        cmdDown.post(tap: .cghidEventTap)
        await wait(pasteShortcutEventDelay)
        let commandTime = ProcessInfo.processInfo.systemUptime
        vDown.post(tap: .cghidEventTap)
        await wait(pasteShortcutEventDelay)
        vUp.post(tap: .cghidEventTap)
        await wait(pasteShortcutEventDelay)
        cmdUp.post(tap: .cghidEventTap)

        return (.commandPosted, commandTime)
    }

    private static func wait(_ seconds: TimeInterval) async {
        guard seconds > 0 else { return }
        let nanoseconds = UInt64(seconds * 1_000_000_000)
        try? await Task.sleep(nanoseconds: nanoseconds)
    }

    // MARK: - Send Key

    /// Delete, for Undo Last Paste after it selected the last paste. Only through `outlets.postDeleteKey`.
    @MainActor
    fileprivate static func postDeleteKey() -> Bool {
        let source = CGEventSource(stateID: .privateState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0x33, keyDown: true),
            let up = CGEvent(keyboardEventSource: source, virtualKey: 0x33, keyDown: false)
        else { return false }
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }

    /// Finish and Send's key. Only through `outlets.postSubmitKey`.
    @MainActor
    fileprivate static func postSubmitKey(_ key: FinishAndSendKey) -> Bool {
        let source = CGEventSource(stateID: .privateState)
        guard key.isEnabled,
            let enterDown = CGEvent(keyboardEventSource: source, virtualKey: 0x24, keyDown: true),
            let enterUp = CGEvent(keyboardEventSource: source, virtualKey: 0x24, keyDown: false)
        else { return false }

        switch key {
        case .none: return false
        case .enter: break
        case .shiftEnter:
            enterDown.flags = .maskShift
            enterUp.flags = .maskShift
        case .commandEnter:
            enterDown.flags = .maskCommand
            enterUp.flags = .maskCommand
        }

        enterDown.post(tap: .cghidEventTap)
        enterUp.post(tap: .cghidEventTap)
        return true
    }

    // MARK: - Target

    private static let focusReadTimeout: Float = 0.25
    /// Accessibility trees in web views run deep; past this many parents an element counts as unrelated.
    private static let maximumParentWalk = 64

    /// The app's own focused element (not the system-wide one, which Yap's recorder panel can hold).
    nonisolated fileprivate static func readFocus(processID: pid_t) -> Focus {
        let app = AXUIElementCreateApplication(processID)
        AXUIElementSetMessagingTimeout(app, focusReadTimeout)
        var focused: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focused)
        if status == .success, let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() {
            return .element(focused as! AXUIElement)
        }
        return status == .noValue ? .none : .unreadable
    }

    /// Whether `a` is a parent (or further up) of `b`, or `b` of `a`.
    nonisolated fileprivate static func encloses(_ a: Focus, _ b: Focus) -> Bool {
        guard case .element(let a) = a, case .element(let b) = b else { return false }
        func isAncestor(_ ancestor: AXUIElement, of element: AXUIElement) -> Bool {
            var current = element
            for _ in 0..<maximumParentWalk {
                AXUIElementSetMessagingTimeout(current, focusReadTimeout)
                var parent: CFTypeRef?
                guard AXUIElementCopyAttributeValue(current, kAXParentAttribute as CFString, &parent) == .success,
                    let parent, CFGetTypeID(parent) == AXUIElementGetTypeID()
                else { return false }
                current = parent as! AXUIElement
                if CFEqual(current, ancestor) { return true }
            }
            return false
        }
        return isAncestor(a, of: b) || isAncestor(b, of: a)
    }
}

extension CursorPaster.Outlets {
    @MainActor static let live = CursorPaster.Outlets(
        clipboard: .general,
        canPostKeys: { AXIsProcessTrusted() },
        focusCanTakeText: { CursorPaster.focusedElementCanTakeText() },
        frontmostApp: {
            let app = NSWorkspace.shared.frontmostApplication
            return (app?.bundleIdentifier, app?.processIdentifier)
        },
        focusedElement: { processID in await Task.detached { CursorPaster.readFocus(processID: processID) }.value },
        encloses: { a, b in await Task.detached { CursorPaster.encloses(a, b) }.value },
        selectedText: { LastPasteEditor.selectedText(processID: $0) },
        modifiersHeld: { !NSEvent.modifierFlags.intersection([.shift, .control, .option, .function]).isEmpty },
        postPasteKeys: { await CursorPaster.postPasteCommand() },
        postSubmitKey: { CursorPaster.postSubmitKey($0) },
        postDeleteKey: { CursorPaster.postDeleteKey() },
        autoSendWillPost: { await AutoLearnService.shared.cancelForAutoSend(generation: $0) },
        pasteSent: { paste in
            let generation =
                AutoLearnSettings.isEnabled
                ? await AutoLearnService.shared.pasteDidFinish(
                    text: paste.text, processID: paste.processID, commandPosted: true, dictationID: paste.dictationID)
                : nil
            LastPasteEditor.shared.pasteDidFinish(text: paste.text, processID: paste.processID, replacing: paste.replaced)
            return generation
        },
        toScratchpad: { ScratchpadStore.shared.append(dictation: $0) },
        notify: { notice in
            switch notice {
            case .accessibilityMissing:
                NotificationManager.shared.showNotification(
                    title: String(localized: "Copied to clipboard. Allow Accessibility so Yap can paste automatically."),
                    type: .warning,
                    duration: 8,
                    actionButton: (String(localized: "Open Settings"), PrivacySettingsPane.accessibility.open)
                )
            case .noTextField:
                NotificationManager.shared.showNotification(
                    title: ScratchpadStore.noTextFieldMessage,
                    type: .warning,
                    duration: 6,
                    actionButton: (String(localized: "Open Scratchpad"), { ScratchpadController.shared.show() })
                )
            case .targetChanged:
                NotificationManager.shared.showNotification(
                    title: String(localized: "Added to your Scratchpad. Another app or field was in front when Yap was about to paste, so it didn't."),
                    type: .warning,
                    duration: 6,
                    actionButton: (String(localized: "Open Scratchpad"), { ScratchpadController.shared.show() })
                )
            }
        },
        restoreSettings: CursorPaster.Outlets.savedRestoreSettings,
        now: { ProcessInfo.processInfo.systemUptime },
        sleep: { seconds in
            guard seconds > 0 else { return }
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        }
    )

    /// Settings › Clipboard: whether to put back what was on the clipboard, and after how long at least.
    static func savedRestoreSettings() -> (enabled: Bool, delay: TimeInterval) {
        (UserDefaults.standard.bool(forKey: "restoreClipboardAfterPaste"),
         UserDefaults.standard.double(forKey: "clipboardRestoreDelay"))
    }

    #if DEBUG
        /// The checks that dictate files (offline, latency, isolation, lifecycle, quit, residency, first run): a
        /// private pasteboard, an editable field always focused, no app in front (the usual timing), nothing read
        /// through Accessibility and no key sent. ⌘V takes as long as the real key events (three 10 ms waits) and
        /// reports `result()`; `commandSent` gets the time V would have gone down. No other key is sent (Enter and
        /// Delete report they couldn't be). Nothing goes to Auto Learn, Last Paste, the Scratchpad or a notification.
        /// Restore follows the mock identity's settings, on the private board. Every outlet is set here, none taken
        /// from `live`, so a new outlet doesn't compile until the checks have their own.
        @MainActor
        static func check(
            _ clipboard: PasteClipboard,
            result: @escaping @MainActor () -> CursorPaster.PasteResult = { .commandPosted },
            commandSent: @escaping @MainActor (TimeInterval) -> Void = { _ in }
        ) -> Self {
            let sleep: (TimeInterval) async -> Void = { seconds in
                guard seconds > 0 else { return }
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            }
            return CursorPaster.Outlets(
                clipboard: clipboard,
                canPostKeys: { true },
                focusCanTakeText: { true },
                frontmostApp: { (nil, nil) },
                focusedElement: { _ in .unreadable },
                encloses: { _, _ in false },
                selectedText: nil,
                modifiersHeld: { false },
                postPasteKeys: {
                    let result = result()
                    guard result == .commandPosted else { return (result, nil) }
                    await sleep(0.01)
                    let commandTime = ProcessInfo.processInfo.systemUptime
                    commandSent(commandTime)
                    await sleep(0.01)
                    await sleep(0.01)
                    return (.commandPosted, commandTime)
                },
                postSubmitKey: { _ in false },
                postDeleteKey: { false },
                autoSendWillPost: { _ in },
                pasteSent: { _ in nil },
                toScratchpad: { _ in },
                notify: { _ in },
                restoreSettings: savedRestoreSettings,
                now: { ProcessInfo.processInfo.systemUptime },
                sleep: sleep)
        }

        /// Installs `check` outlets on a new private pasteboard for a dictation check; call the returned closure when
        /// the check is done: it cancels and waits out the pending restores, then releases the pasteboard.
        @MainActor
        static func installCheck(
            result: @escaping @MainActor () -> CursorPaster.PasteResult = { .commandPosted },
            commandSent: @escaping @MainActor (TimeInterval) -> Void = { _ in }
        ) -> @MainActor () async -> Void {
            let clipboard = PasteClipboard(NSPasteboard(name: NSPasteboard.Name("me.sma1lboy.yap.check.\(UUID().uuidString)")))
            CursorPaster.outlets = check(clipboard, result: result, commandSent: commandSent)
            return {
                await clipboard.close()
                clipboard.pasteboard.releaseGlobally()
            }
        }
    #endif
}
