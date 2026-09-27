import AppKit
import ApplicationServices

/// Where the dictation is going: the frontmost app, its focused window's title, and the text around the cursor in
/// the focused field. The text is nil when the field can't be read (no editable focus, no Accessibility, a secure
/// field); cleanup then falls back to the screen text if the mode allows it.
struct CursorContext: Equatable {
    var appName: String?
    var windowTitle: String?
    var textBeforeCursor: String?
    var textAfterCursor: String?

    var hasText: Bool { !(textBeforeCursor ?? "").isEmpty || !(textAfterCursor ?? "").isEmpty }

    /// The `<CURSOR_CONTEXT>` block for the cleanup prompt; nil when there's nothing to say.
    var promptBlock: String? {
        var lines: [String] = []
        if let appName { lines.append("App: \(appName)") }
        if let windowTitle { lines.append("Window: \(windowTitle)") }
        if hasText {
            lines.append("Text in the field being dictated into; the dictation goes where [CURSOR] is:")
            lines.append((textBeforeCursor ?? "") + "[CURSOR]" + (textAfterCursor ?? ""))
        }
        guard !lines.isEmpty else { return nil }
        return "<CURSOR_CONTEXT>\n" + lines.joined(separator: "\n") + "\n</CURSOR_CONTEXT>"
    }
}

enum CursorContextReader {
    /// About 3,000 characters in all, weighted to what comes before the cursor.
    static let charactersBefore = 2_000
    static let charactersAfter = 1_000

    /// Reads the frontmost app (never Yap itself). Blocking Accessibility calls with a short timeout: call it off
    /// the main thread.
    static func read(app: NSRunningApplication?) -> CursorContext? {
        guard let app, app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return nil }
        let pid = app.processIdentifier
        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElement, AutoLearnLimits.captureAccessibilityTimeoutSeconds)
        var context = CursorContext(appName: app.localizedName, windowTitle: windowTitle(appElement))
        guard AXIsProcessTrusted(), !isSecureFieldFocused(appElement) else { return context }

        let reader = AutoLearnAXTextReader()
        let readings = reader.focusedReadings(processID: pid)
        defer { reader.restoreWebAccessibility(processID: pid, appElement: appElement) }
        guard let reading = readings.first(where: { $0.selection != nil }) ?? readings.first else { return context }
        let (before, after) = excerpt(reading.fieldText, selection: reading.selection)
        context.textBeforeCursor = before
        context.textAfterCursor = after
        return context
    }

    /// Text before and after the cursor (a selection is left out), trimmed to the limits at character boundaries.
    /// Without a known cursor, the end of the field is used.
    static func excerpt(_ text: String, selection: NSRange?) -> (before: String, after: String) {
        let utf16 = text.utf16
        let range = selection ?? NSRange(location: utf16.count, length: 0)
        guard let start = String.Index(utf16.index(utf16.startIndex, offsetBy: min(range.location, utf16.count)), within: text),
            let end = String.Index(
                utf16.index(utf16.startIndex, offsetBy: min(range.location + range.length, utf16.count)), within: text)
        else { return (String(text.suffix(charactersBefore)), "") }
        return (String(text[..<start].suffix(charactersBefore)), String(text[end...].prefix(charactersAfter)))
    }

    private static func windowTitle(_ appElement: AXUIElement) -> String? {
        var window: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &window) == .success,
            let window, CFGetTypeID(window) == AXUIElementGetTypeID()
        else { return nil }
        var title: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window as! AXUIElement, kAXTitleAttribute as CFString, &title) == .success
        else { return nil }
        let trimmed = (title as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    /// Password fields report the secure-text subrole (native and web); their value is never read.
    private static func isSecureFieldFocused(_ appElement: AXUIElement) -> Bool {
        var candidates: [AXUIElement] = []
        var focused: CFTypeRef?
        if AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
            let focused, CFGetTypeID(focused) == AXUIElementGetTypeID()
        {
            candidates.append(focused as! AXUIElement)
        }
        var systemFocused: CFTypeRef?
        if AXUIElementCopyAttributeValue(
            AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute as CFString, &systemFocused) == .success,
            let systemFocused, CFGetTypeID(systemFocused) == AXUIElementGetTypeID()
        {
            candidates.append(systemFocused as! AXUIElement)
        }
        return candidates.contains { element in
            [kAXRoleAttribute, kAXSubroleAttribute].contains { attribute in
                var value: CFTypeRef?
                AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
                return (value as? String) == (kAXSecureTextFieldSubrole as String)
            }
        }
    }
}

#if DEBUG
    extension CursorContextReader {
        static func selfCheck() {
            let (before, after) = excerpt("Hello world", selection: NSRange(location: 5, length: 0))
            assert(before == "Hello" && after == " world")
            let selected = excerpt("abc XYZ def", selection: NSRange(location: 4, length: 3))
            assert(selected == ("abc ", " def"), "a selection is left out")
            assert(excerpt("end", selection: nil) == ("end", ""))
            assert(excerpt("短", selection: NSRange(location: 99, length: 0)) == ("短", ""), "out of range clamps")
            let emoji = excerpt("a😀b", selection: NSRange(location: 2, length: 0))  // inside the surrogate pair
            assert(emoji.before + emoji.after == "ab" || emoji.before + emoji.after == "a😀b")
            let long = String(repeating: "字", count: 5_000)
            let trimmed = excerpt(long, selection: NSRange(location: 2_500, length: 0))
            assert(trimmed.before.count == charactersBefore && trimmed.after.count == charactersAfter)

            let context = CursorContext(
                appName: "Slack", windowTitle: "#general", textBeforeCursor: "Ship it", textAfterCursor: nil)
            assert(context.promptBlock == """
                <CURSOR_CONTEXT>
                App: Slack
                Window: #general
                Text in the field being dictated into; the dictation goes where [CURSOR] is:
                Ship it[CURSOR]
                </CURSOR_CONTEXT>
                """)
            assert(CursorContext(appName: "Mail").promptBlock == "<CURSOR_CONTEXT>\nApp: Mail\n</CURSOR_CONTEXT>")
            assert(CursorContext().promptBlock == nil && !CursorContext(appName: "Mail").hasText)
        }
    }
#endif
