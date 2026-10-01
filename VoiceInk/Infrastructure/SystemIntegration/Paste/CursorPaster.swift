import AppKit
import Carbon
import Foundation
import os

class CursorPaster {
    private typealias ClipboardItemSnapshot = [(NSPasteboard.PasteboardType, Data)]
    private typealias ClipboardSnapshot = [ClipboardItemSnapshot]
    private static let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "CursorPaster")

    enum PasteResult: Equatable {
        case commandPosted
        case commandNotPosted
        /// No Accessibility permission: the text stays on the clipboard for the user to paste.
        case leftOnClipboard
        /// No editable element focused: the text stays on the clipboard and goes to the Scratchpad.
        case sentToScratchpad

        var didPostPasteCommand: Bool {
            self == .commandPosted
        }
    }

    struct PasteOutcome {
        let result: PasteResult
        let autoLearnGeneration: UInt64?
        /// System uptime when ⌘V went out: the V key-down, or when the AppleScript paste returned.
        var commandTime: TimeInterval?
    }

    #if DEBUG
        /// `make dictation-latency`: the clipboard and every wait up to ⌘V run as usual, but the frontmost app isn't
        /// asked about its focused field or selection, no key event is posted and nothing goes to Auto Learn or Last
        /// Paste, so nothing is read from or typed into whatever app is in front. Uses the normal timing even when a
        /// remote-desktop app is frontmost. `dryRunResult` is what the paste reports (a failed paste for its check).
        static var dryRun = false
        static var dryRunResult = PasteResult.commandPosted
        /// When the last dry-run ⌘V would have gone out, so the check can tell what happened after it.
        static var lastDryRunCommandTime: TimeInterval?
    #else
        static let dryRun = false
    #endif

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

    static func pasteAtCursor(_ text: String) {
        Task {
            let pasteTask = await MainActor.run {
                startPasteAtCursor(text)
            }
            _ = await pasteTask.value
        }
    }

    /// The checks, the clipboard and the selection read start now, in the caller's turn on the main thread; the wait
    /// and ⌘V follow in the returned task. The wait counts from the clipboard write, so main-thread work queued ahead of
    /// that task (the recorder closing, the session cleanup) runs inside the wait instead of before it.
    @MainActor
    @discardableResult
    static func startPasteAtCursor(_ text: String, lead: Lead = .other) -> Task<PasteOutcome, Never> {
        switch preparePaste(text, lead: lead) {
        case .finished(let outcome):
            return Task { outcome }
        case .ready(let paste):
            return Task { @MainActor in await post(paste) }
        }
    }

    private enum Preparation {
        case finished(PasteOutcome)
        case ready(PreparedPaste)
    }

    private struct PreparedPaste {
        let text: String
        let lead: Lead
        let timing: (prePaste: TimeInterval, minimumRestore: TimeInterval)
        let clipboardSetAt: TimeInterval
        let targetProcessID: pid_t?
        /// The text the paste is about to replace, what Undo Last Paste restores; read while the wait runs.
        let replaced: Task<String, Never>?
        let restore: (savedContents: ClipboardSnapshot, sessionID: String)?
    }

    @MainActor
    private static func preparePaste(_ text: String, lead: Lead) -> Preparation {
        let pasteboard = NSPasteboard.general

        // Both paste methods send keystrokes, which macOS drops without Accessibility.
        // Leave the text on the clipboard (no restore) so nothing is lost.
        guard dryRun || AXIsProcessTrusted() else {
            logger.error("Accessibility permission missing; leaving text on the clipboard")
            _ = ClipboardManager.setClipboard(text, transient: false, sessionID: nil)
            NotificationManager.shared.showNotification(
                title: String(localized: "Copied to clipboard. Allow Accessibility so Yap can paste automatically."),
                type: .warning,
                duration: 8,
                actionButton: (String(localized: "Open Settings"), PrivacySettingsPane.accessibility.open)
            )
            return .finished(PasteOutcome(result: .leftOnClipboard, autoLearnGeneration: nil))
        }

        // Nothing editable focused (desktop, Finder): ⌘V would go nowhere and the restore would then
        // take the text back off the clipboard. Keep it there and say so.
        if !dryRun && !focusedElementCanTakeText() {
            logger.notice("No editable element focused; leaving text on the clipboard and in the Scratchpad")
            _ = ClipboardManager.setClipboard(text, transient: false, sessionID: nil)
            ScratchpadStore.shared.append(dictation: text)
            NotificationManager.shared.showNotification(
                title: ScratchpadStore.noTextFieldMessage,
                type: .warning,
                duration: 6,
                actionButton: (String(localized: "Open Scratchpad"), { ScratchpadController.shared.show() })
            )
            return .finished(PasteOutcome(result: .sentToScratchpad, autoLearnGeneration: nil))
        }

        let timing = pasteTiming(
            frontmostBundleID: dryRun ? nil : NSWorkspace.shared.frontmostApplication?.bundleIdentifier, lead: lead)
        let shouldRestoreClipboard = UserDefaults.standard.bool(forKey: "restoreClipboardAfterPaste")
        let savedContents = shouldRestoreClipboard ? snapshotClipboard(from: pasteboard) : []
        let sessionID = UUID().uuidString

        guard
            ClipboardManager.setClipboard(
                text,
                transient: shouldRestoreClipboard,
                sessionID: shouldRestoreClipboard ? sessionID : nil
            )
        else {
            logger.error("Failed to prepare clipboard for paste")
            return .finished(PasteOutcome(result: .commandNotPosted, autoLearnGeneration: nil))
        }

        let targetProcessID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        return .ready(
            PreparedPaste(
                text: text, lead: lead, timing: timing, clipboardSetAt: ProcessInfo.processInfo.systemUptime,
                targetProcessID: targetProcessID,
                replaced: dryRun
                    ? nil : Task.detached { targetProcessID.map { LastPasteEditor.selectedText(processID: $0) } ?? "" },
                restore: shouldRestoreClipboard ? (savedContents, sessionID) : nil))
    }

    @MainActor
    private static func post(_ paste: PreparedPaste) async -> PasteOutcome {
        await waitBeforePaste(paste)
        if dryRun {
            #if DEBUG
                guard dryRunResult == .commandPosted else {
                    return PasteOutcome(result: dryRunResult, autoLearnGeneration: nil)
                }
            #endif
            return PasteOutcome(result: .commandPosted, autoLearnGeneration: nil, commandTime: await simulatePasteKeys())
        }
        let replaced = await paste.replaced?.value ?? ""

        let posted: (result: PasteResult, commandTime: TimeInterval?)
        let autoLearnGeneration: UInt64?
        if AutoLearnSettings.isEnabled {
            posted = await postPasteCommand()
            autoLearnGeneration = await AutoLearnService.shared.pasteDidFinish(
                text: paste.text,
                processID: paste.targetProcessID,
                commandPosted: posted.result.didPostPasteCommand
            )
        } else {
            posted = await postPasteCommand()
            autoLearnGeneration = nil
        }
        let pasteResult = posted.result
        if pasteResult.didPostPasteCommand {
            LastPasteEditor.shared.pasteDidFinish(text: paste.text, processID: paste.targetProcessID, replacing: replaced)
        }
        // A paste that never reached the app must not take the text back off the clipboard.
        if let restore = paste.restore, pasteResult.didPostPasteCommand {
            scheduleClipboardRestore(
                restore.savedContents,
                expectedText: paste.text,
                sessionID: restore.sessionID,
                minimumDelay: paste.timing.minimumRestore,
                on: NSPasteboard.general
            )
        }

        return PasteOutcome(result: pasteResult, autoLearnGeneration: autoLearnGeneration, commandTime: posted.commandTime)
    }

    /// The pre-paste wait, counted from the clipboard write. After a shortcut stop the user may still be holding the
    /// shortcut's modifiers (toggle mode stops on a press), which would turn ⌘V into ⌥⌘V or ⇧⌘V; ⌘V waits for them to
    /// come up, until 0.1 s after the clipboard write at most, the wait it used to have.
    private static func waitBeforePaste(_ paste: PreparedPaste) async {
        func elapsed() -> TimeInterval { ProcessInfo.processInfo.systemUptime - paste.clipboardSetAt }
        await wait(paste.timing.prePaste - elapsed())
        guard paste.lead == .shortcut else { return }
        let held: NSEvent.ModifierFlags = [.shift, .control, .option, .function]
        while elapsed() < prePasteDelay, !NSEvent.modifierFlags.intersection(held).isEmpty {
            await wait(pasteShortcutEventDelay)
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

    private static func focusedElementCanTakeText() -> Bool {
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

    private static func snapshotClipboard(from pasteboard: NSPasteboard) -> ClipboardSnapshot {
        (pasteboard.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in
                if let data = item.data(forType: type) {
                    return (type, data)
                }
                return nil
            }
        }
    }

    @MainActor
    private static func postPasteCommand() async -> (result: PasteResult, commandTime: TimeInterval?) {
        if PasteMethod.current() == .appleScript {
            let posted = pasteUsingAppleScript()
            return posted ? (.commandPosted, ProcessInfo.processInfo.systemUptime) : (.commandNotPosted, nil)
        } else {
            return await pasteFromClipboard()
        }
    }

    private static func scheduleClipboardRestore(
        _ savedContents: ClipboardSnapshot,
        expectedText: String,
        sessionID: String,
        minimumDelay: TimeInterval,
        on pasteboard: NSPasteboard
    ) {
        let delay = max(UserDefaults.standard.double(forKey: "clipboardRestoreDelay"), minimumDelay)

        Task { @MainActor in
            await wait(delay)
            guard pasteboardStillOwnedByPasteSession(pasteboard, expectedText: expectedText, sessionID: sessionID)
            else {
                return
            }
            ClipboardManager.restoreClipboard(pasteboardItems(from: savedContents), on: pasteboard)
        }
    }

    private static func pasteboardStillOwnedByPasteSession(
        _ pasteboard: NSPasteboard,
        expectedText: String,
        sessionID: String
    ) -> Bool {
        pasteboard.string(forType: .string) == expectedText
            && pasteboard.string(forType: ClipboardManager.pasteSessionType) == sessionID
    }

    private static func pasteboardItems(from snapshot: ClipboardSnapshot) -> [NSPasteboardItem] {
        snapshot.map { itemSnapshot in
            let item = NSPasteboardItem()
            for (type, data) in itemSnapshot {
                item.setData(data, forType: type)
            }
            return item
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

    /// dryRun: the waits of pasteFromClipboard without its events; returns when V would have gone down.
    private static func simulatePasteKeys() async -> TimeInterval {
        await wait(pasteShortcutEventDelay)
        let commandTime = ProcessInfo.processInfo.systemUptime
        #if DEBUG
            lastDryRunCommandTime = commandTime
        #endif
        await wait(pasteShortcutEventDelay)
        await wait(pasteShortcutEventDelay)
        return commandTime
    }

    private static func wait(_ seconds: TimeInterval) async {
        guard seconds > 0 else { return }
        let nanoseconds = UInt64(seconds * 1_000_000_000)
        try? await Task.sleep(nanoseconds: nanoseconds)
    }

    // MARK: - Send Key

    /// Deletes the current selection (LastPasteEditor's undo, after it selected the last paste).
    static func performDeleteKey() {
        guard AXIsProcessTrusted() else { return }
        let source = CGEventSource(stateID: .privateState)
        CGEvent(keyboardEventSource: source, virtualKey: 0x33, keyDown: true)?.post(tap: .cghidEventTap)
        CGEvent(keyboardEventSource: source, virtualKey: 0x33, keyDown: false)?.post(tap: .cghidEventTap)
    }

    static func performSendKey(_ key: FinishAndSendKey) {
        guard key.isEnabled else { return }
        guard AXIsProcessTrusted() else { return }

        let source = CGEventSource(stateID: .privateState)
        let enterDown = CGEvent(keyboardEventSource: source, virtualKey: 0x24, keyDown: true)
        let enterUp = CGEvent(keyboardEventSource: source, virtualKey: 0x24, keyDown: false)

        switch key {
        case .none: return
        case .enter: break
        case .shiftEnter:
            enterDown?.flags = .maskShift
            enterUp?.flags = .maskShift
        case .commandEnter:
            enterDown?.flags = .maskCommand
            enterUp?.flags = .maskCommand
        }

        enterDown?.post(tap: .cghidEventTap)
        enterUp?.post(tap: .cghidEventTap)
    }
}
