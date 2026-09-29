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

        var didPostPasteCommand: Bool {
            self == .commandPosted
        }
    }

    struct PasteOutcome {
        let result: PasteResult
        let autoLearnGeneration: UInt64?
    }

    private static let prePasteDelay: TimeInterval = 0.10
    private static let pasteShortcutEventDelay: TimeInterval = 0.01
    private static let minimumClipboardRestoreDelay: TimeInterval = 0.25

    /// Remote-desktop and VM windows copy the local clipboard to the other machine asynchronously.
    /// With the usual 0.1 s / 0.25 s timing the remote side pastes before it has the new text, or the
    /// restore lands first, so it pastes the previous dictation (upstream #928, Screen Sharing; the
    /// reporter's working setting was a 5 s restore delay).
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
    ]

    static func pasteTiming(frontmostBundleID: String?) -> (prePaste: TimeInterval, minimumRestore: TimeInterval) {
        guard let frontmostBundleID, clipboardSyncingApps.contains(frontmostBundleID) else {
            return (prePasteDelay, minimumClipboardRestoreDelay)
        }
        return (0.5, 5)
    }

    static func pasteAtCursor(_ text: String) {
        Task {
            let pasteTask = await MainActor.run {
                startPasteAtCursor(text)
            }
            _ = await pasteTask.value
        }
    }

    @MainActor
    @discardableResult
    static func startPasteAtCursor(_ text: String) -> Task<PasteOutcome, Never> {
        Task { @MainActor in
            await performPasteSession(text)
        }
    }

    @MainActor
    private static func performPasteSession(_ text: String) async -> PasteOutcome {
        let pasteboard = NSPasteboard.general

        // Both paste methods send keystrokes, which macOS drops without Accessibility.
        // Leave the text on the clipboard (no restore) so nothing is lost.
        guard AXIsProcessTrusted() else {
            logger.error("Accessibility permission missing; leaving text on the clipboard")
            _ = ClipboardManager.setClipboard(text, transient: false, sessionID: nil)
            NotificationManager.shared.showNotification(
                title: String(localized: "Copied to clipboard. Allow Accessibility so Yap can paste automatically."),
                type: .warning,
                duration: 8,
                actionButton: (String(localized: "Open Settings"), PrivacySettingsPane.accessibility.open)
            )
            return PasteOutcome(result: .commandNotPosted, autoLearnGeneration: nil)
        }

        // Nothing editable focused (desktop, Finder): ⌘V would go nowhere and the restore would then
        // take the text back off the clipboard. Keep it there and say so.
        if !focusedElementCanTakeText() {
            logger.notice("No editable element focused; leaving text on the clipboard")
            _ = ClipboardManager.setClipboard(text, transient: false, sessionID: nil)
            NotificationManager.shared.showNotification(
                title: String(localized: "Copied to clipboard. No text field was focused, so Yap didn't paste. It's also in History."),
                type: .warning,
                duration: 6
            )
            return PasteOutcome(result: .commandNotPosted, autoLearnGeneration: nil)
        }

        let timing = pasteTiming(frontmostBundleID: NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
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
            return PasteOutcome(result: .commandNotPosted, autoLearnGeneration: nil)
        }

        await wait(timing.prePaste)

        let pasteResult: PasteResult
        let autoLearnGeneration: UInt64?
        let targetProcessID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        if AutoLearnSettings.isEnabled {
            pasteResult = await postPasteCommand()
            autoLearnGeneration = await AutoLearnService.shared.pasteDidFinish(
                text: text,
                processID: targetProcessID,
                commandPosted: pasteResult.didPostPasteCommand
            )
        } else {
            pasteResult = await postPasteCommand()
            autoLearnGeneration = nil
        }
        if pasteResult.didPostPasteCommand {
            LastPasteEditor.shared.pasteDidFinish(text: text, processID: targetProcessID)
        }
        // A paste that never reached the app must not take the text back off the clipboard.
        if shouldRestoreClipboard && pasteResult.didPostPasteCommand {
            scheduleClipboardRestore(
                savedContents,
                expectedText: text,
                sessionID: sessionID,
                minimumDelay: timing.minimumRestore,
                on: pasteboard
            )
        }

        return PasteOutcome(result: pasteResult, autoLearnGeneration: autoLearnGeneration)
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
    private static func postPasteCommand() async -> PasteResult {
        if PasteMethod.current() == .appleScript {
            return pasteUsingAppleScript() ? .commandPosted : .commandNotPosted
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
    private static func pasteFromClipboard() async -> PasteResult {
        guard AXIsProcessTrusted() else {
            logger.error("Accessibility permission is required to paste with simulated key events")
            return .commandNotPosted
        }

        let source = CGEventSource(stateID: .privateState)

        guard let cmdDown = CGEvent(keyboardEventSource: source, virtualKey: 0x37, keyDown: true),
            let vDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true),
            let vUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false),
            let cmdUp = CGEvent(keyboardEventSource: source, virtualKey: 0x37, keyDown: false)
        else {
            logger.error("Failed to create Cmd+V keyboard events")
            return .commandNotPosted
        }

        cmdDown.flags = .maskCommand
        vDown.flags = .maskCommand
        vUp.flags = .maskCommand

        cmdDown.post(tap: .cghidEventTap)
        await wait(pasteShortcutEventDelay)
        vDown.post(tap: .cghidEventTap)
        await wait(pasteShortcutEventDelay)
        vUp.post(tap: .cghidEventTap)
        await wait(pasteShortcutEventDelay)
        cmdUp.post(tap: .cghidEventTap)

        return .commandPosted
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
