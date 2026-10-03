import AppKit
import Carbon
import Foundation
import os

class CursorPaster {
    private static let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "CursorPaster")

    enum PasteResult: Equatable {
        case commandPosted
        /// The key events / AppleScript couldn't be sent: the text stays on the clipboard for the user to paste (in the
        /// Scratchpad instead if the clipboard no longer holds it). Also a clipboard write that failed: the text goes
        /// to the Scratchpad and the clipboard is put back.
        case commandNotPosted
        /// When ⌘V was due the clipboard no longer held this paste's text (the user copied something, or another
        /// paste replaced it): no key was sent, the clipboard is left as it is, and the text goes to the Scratchpad.
        case clipboardChanged
        /// No Accessibility permission: the text stays on the clipboard for the user to paste.
        case leftOnClipboard
        /// No editable element focused: the text goes to the Scratchpad, and stays on the clipboard if it could be put
        /// there.
        case sentToScratchpad
        /// When ⌘V was due a different app or field was in front than the paste was for (or the app it was for wasn't
        /// in front when it started, quit, or there was none): no key was sent, and the text goes to the Scratchpad.
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
        let request: Request
        let target: Target
    }

    /// One paste, Undo, or key the user asked for, numbered when they asked (`newRequest`), before any wait. A paste or
    /// key whose request is no longer the latest isn't sent.
    struct Request: Equatable {
        fileprivate let number: UInt64
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

    /// What a notification tells the user when a paste, Finish and Send's key or Undo's Delete didn't go out.
    enum Notice: Equatable {
        /// No ⌘V was sent. `text`: where the text is now, as checked after the refusal (not assumed from the reason).
        case notPasted(Reason, text: Destination)
        /// The paste went out; Finish and Send's key didn't (`targetChanged`, `superseded` or `notSent`).
        case sendSkipped(KeyResult)
        /// Undo's Delete didn't go out (`targetChanged` or `notSent`): nothing was removed.
        case deleteSkipped(KeyResult)

        enum Reason: Equatable {
            case accessibilityMissing, noTextField, targetChanged, targetQuit, noTarget, clipboardChanged, superseded
            case clipboardWriteFailed, pasteKeysFailed
        }

        enum Destination: Equatable {
            case clipboard, scratchpad, clipboardAndScratchpad
        }
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
        /// Finish and Send is about to send its key after the paste with this Auto Learn generation. Auto Learn stops
        /// watching the paste (`autoSent`) whether or not the key then passes its last check.
        var autoSendWillPost: @MainActor (UInt64) async -> Void
        /// After ⌘V went out; returns the Auto Learn generation.
        var pasteSent: @MainActor (SentPaste) async -> UInt64?
        var toScratchpad: @MainActor (String) -> Void
        var notify: @MainActor (Notice) -> Void
        /// Asks the app with this process ID, once, to come to the front (History's Paste Again, Quick History).
        var activate: @MainActor (pid_t) -> Void
        /// Whether the app with this process ID is still running.
        var isRunning: (pid_t) -> Bool
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

    /// A new request (a paste, Undo), numbered now: every paste or key of an earlier request still waiting is no longer
    /// sent.
    @MainActor
    static func newRequest() -> Request {
        latestRequest &+= 1
        return Request(number: latestRequest)
    }

    /// No paste, Undo or rewrite has started since `request` was taken (Rewrite asks before and after its AI wait).
    @MainActor
    static func isLatest(_ request: Request) -> Bool {
        request == latest
    }

    /// History's Paste Again, Quick History and Paste Last: the paste is for `target`, the app the caller recorded.
    /// The request is taken now, before any wait, so a paste or Undo started meanwhile supersedes this one.
    /// `activate`: unless the app is in front already, it's asked once to come to the front. After `hold` (Paste
    /// Last: its shortcut's keys coming up) the paste waits until the app is in front, checking every 20 ms for at
    /// most `activationTimeout`, then goes on as any paste does, which refuses it if the app still isn't in front.
    /// An app that quit is refused at once. No target (nothing recorded): the text goes to the Scratchpad, the
    /// clipboard isn't touched and nothing is pasted into whatever is in front.
    @MainActor
    @discardableResult
    static func paste(
        _ text: String, into target: pid_t?, activate: Bool, hold: TimeInterval = 0
    ) -> Task<PasteOutcome, Never> {
        let outlets = Self.outlets
        let request = newRequest()
        guard let target else {
            logger.notice("No app to paste into; text sent to the Scratchpad")
            outlets.toScratchpad(text)
            outlets.notify(.notPasted(.noTarget, text: .scratchpad))
            return Task { PasteOutcome(result: .targetChanged, autoLearnGeneration: nil) }
        }
        if activate, outlets.frontmostApp().processID != target { outlets.activate(target) }
        return Task { @MainActor in
            if hold > 0 { await outlets.sleep(hold) }
            let deadline = outlets.now() + activationTimeout
            while outlets.frontmostApp().processID != target, request == latest, !Task.isCancelled,
                outlets.isRunning(target), outlets.now() < deadline
            {
                await outlets.sleep(activationPoll)
            }
            if request != latest || Task.isCancelled {
                logger.notice("A newer request started while the app came to the front; text sent to the Scratchpad")
                outlets.toScratchpad(text)
                if request != latest { outlets.notify(.notPasted(.superseded, text: .scratchpad)) }
                return PasteOutcome(result: .superseded, autoLearnGeneration: nil)
            }
            guard outlets.isRunning(target) else {
                logger.notice("The app the paste was for quit; text sent to the Scratchpad")
                outlets.toScratchpad(text)
                outlets.notify(.notPasted(.targetQuit, text: .scratchpad))
                return PasteOutcome(result: .targetChanged, autoLearnGeneration: nil)
            }
            switch preparePaste(text, lead: .other, dictationID: nil, target: target, field: nil, request: request, outlets: outlets) {
            case .finished(let outcome): return outcome
            case .ready(let paste): return await post(paste, outlets: outlets)
            }
        }
    }

    /// How long History's and Quick History's pastes wait for the app they activated to come to the front, and how
    /// often they look. Not measured against real apps: a margin over the 0.12 / 0.15 s they used to wait blindly.
    private static let activationTimeout: TimeInterval = 1.0
    private static let activationPoll: TimeInterval = 0.02

    /// The checks, the clipboard and the selection read start now, in the caller's turn on the main thread; the wait
    /// and ⌘V follow in the returned task. The wait counts from the clipboard write, so main-thread work queued ahead of
    /// that task (the recorder closing, the session cleanup) runs inside the wait instead of before it. `dictationID`:
    /// the dictation being pasted, whose SessionMetric gets what Auto Learn sees become of it. `target`: the process the
    /// caller chose, and with `.element` focus the field the paste is for (Undo and Rewrite Last Paste: the field
    /// LastPasteEditor just selected in); nil takes the app in front now, Yap itself included. Without a known field the
    /// app's focused element is read during the wait and the paste is checked against that. `request`: one the caller
    /// took earlier (Undo and Rewrite, before they selected the text); nil takes a new one. A request that is no longer
    /// the latest when the paste starts is refused before the clipboard is touched. A newer paste, or Undo, supersedes
    /// this one: its ⌘V and its Finish and Send key are not sent after that.
    @MainActor
    @discardableResult
    static func startPasteAtCursor(
        _ text: String, lead: Lead = .other, dictationID: UUID? = nil, target: Target? = nil, request: Request? = nil
    ) -> Task<PasteOutcome, Never> {
        let outlets = Self.outlets
        let request = request ?? newRequest()
        var field: AXUIElement?
        if case .element(let element) = target?.focus { field = element }
        switch preparePaste(
            text, lead: lead, dictationID: dictationID, target: target?.processID, field: field, request: request,
            outlets: outlets)
        {
        case .finished(let outcome):
            return Task { outcome }
        case .ready(let paste):
            return Task { @MainActor in await post(paste, outlets: outlets) }
        }
    }

    /// Finish and Send: `key` after the paste in `outcome`, 150 ms after its ⌘V, if that paste is still the latest
    /// request and its app and field are still in front. The paste went out either way; this is only the key. The
    /// focus is read again after every wait, Auto Learn's included, and nothing is awaited from the last checks to the
    /// key. Auto Learn stops watching the paste (`autoSent`) once the key is about to go, before those last checks: a
    /// key refused there leaves the paste unwatched. A key not sent is said in a notification (not when cancelled).
    @MainActor
    static func submit(_ key: FinishAndSendKey, after outcome: PasteOutcome) async -> KeyResult {
        let outlets = Self.outlets
        guard key.isEnabled, let sent = outcome.sent else { return .notSent }
        await outlets.sleep(submitDelay)
        func refusal() async -> KeyResult? {
            let focusMoved = await focusMoved(from: sent.target, outlets: outlets)
            guard sent.request == latest, !Task.isCancelled else {
                logger.notice("Finish and Send skipped: a newer request started after the paste")
                return .superseded
            }
            guard outlets.canPostKeys() else { return .notSent }
            guard outlets.frontmostApp().processID == sent.target.processID, !focusMoved else {
                logger.notice("Finish and Send skipped: another app or field is in front than the paste went to")
                return .targetChanged
            }
            return nil
        }
        var result = await refusal()
        if result == nil {
            if let generation = outcome.autoLearnGeneration { await outlets.autoSendWillPost(generation) }
            result = await refusal()
        }
        let sentKey = result ?? (outlets.postSubmitKey(key) ? .sent : .notSent)
        if sentKey != .sent, sent.request != latest || !Task.isCancelled { outlets.notify(.sendSkipped(sentKey)) }
        return sentKey
    }

    /// Finish and Send after a custom command: the command delivered the text itself, so there is no paste to check
    /// the app and field against. `key` goes 150 ms after the command finished, if Accessibility allows it.
    @MainActor
    static func submitAfterCommand(_ key: FinishAndSendKey) async -> KeyResult {
        let outlets = Self.outlets
        guard key.isEnabled else { return .notSent }
        await outlets.sleep(submitDelay)
        guard !Task.isCancelled, outlets.canPostKeys() else { return .notSent }
        return outlets.postSubmitKey(key) ? .sent : .notSent
    }

    /// Undo Last Paste: deletes the selection LastPasteEditor just set in `field` of `processID` (it checked that field
    /// and its text through Accessibility a moment before). `request`: taken when the Undo started, so a paste or key
    /// still waiting from before isn't sent. The app's focus is read again; then, with nothing awaited up to the key,
    /// the request must still be the latest, Accessibility allowed, the app in front and its focus still on that field
    /// (or an element inside it or around it; unreadable: the app is all there is). Not sent because the app or field
    /// changed or the key couldn't be sent: a notification says nothing was removed. Superseded: the newer request
    /// reports for itself.
    @MainActor
    static func deleteSelection(in processID: pid_t, field: AXUIElement, request: Request) async -> KeyResult {
        let outlets = Self.outlets
        let focusMoved = await focusMoved(from: Target(processID: processID, focus: .element(field)), outlets: outlets)
        let result: KeyResult
        if request != latest || Task.isCancelled {
            result = .superseded
        } else if !outlets.canPostKeys() {
            result = .notSent
        } else if outlets.frontmostApp().processID != processID || focusMoved {
            result = .targetChanged
        } else {
            result = outlets.postDeleteKey() ? .sent : .notSent
        }
        if result == .targetChanged || result == .notSent { outlets.notify(.deleteSkipped(result)) }
        return result
    }

    private static let submitDelay: TimeInterval = 0.15

    /// Bumped by every paste and Undo when it starts (`newRequest`); a paste or key whose request is no longer the
    /// latest isn't sent. Never bumped by a restore.
    @MainActor private static var latestRequest: UInt64 = 0
    @MainActor private static var latest: Request { Request(number: latestRequest) }

    private enum Preparation {
        case finished(PasteOutcome)
        case ready(PreparedPaste)
    }

    private struct PreparedPaste {
        let request: Request
        let text: String
        let lead: Lead
        let dictationID: UUID?
        let prePasteDelay: TimeInterval
        let restoreDelay: TimeInterval
        let clipboardSetAt: TimeInterval
        /// The caller's target, or else the app in front when the paste started (nil only when there was none).
        let targetProcessID: pid_t?
        /// The target's focused element, then the text the paste is about to replace (what Undo Last Paste restores),
        /// read in that order while the wait runs: the selection read can switch a web view's accessibility on. A field
        /// the caller knows (Undo, Rewrite) is taken as it is, not read. Nil for Yap's own windows, which aren't read
        /// through Accessibility: only the process is checked there.
        let read: Task<(focus: Focus, replaced: String), Never>?
        let claim: PasteClipboard.Claim
    }

    @MainActor
    private static func preparePaste(
        _ text: String, lead: Lead, dictationID: UUID?, target: pid_t?, field: AXUIElement?, request: Request,
        outlets: Outlets
    ) -> Preparation {
        let clipboard = outlets.clipboard

        // A request taken before a wait (Undo's and Rewrite's, while they selected the text) that a newer paste or
        // Undo replaced since, or whose caller was cancelled: refused before anything is written, so the newer paste's
        // clipboard, its restore and the user's copy stay as they are.
        if request != latest || Task.isCancelled {
            logger.notice("A newer request started before this paste began; clipboard untouched, text sent to the Scratchpad")
            outlets.toScratchpad(text)
            // Cancelled with nothing newer: no notification, as after the wait.
            if request != latest { outlets.notify(.notPasted(.superseded, text: .scratchpad)) }
            return .finished(PasteOutcome(result: .superseded, autoLearnGeneration: nil))
        }

        // Leave the text on the clipboard (no restore) so nothing is lost.
        guard outlets.canPostKeys() else {
            logger.error("Accessibility permission missing; leaving text on the clipboard")
            return .finished(
                keepUnpasted(text, .accessibilityMissing, result: .leftOnClipboard, alsoScratchpad: false, outlets: outlets))
        }

        let frontmost = outlets.frontmostApp()
        // The caller activated (or recorded) an app and another one is in front: the paste was meant for that app,
        // not this one. The clipboard isn't touched.
        if let target, frontmost.processID != target {
            logger.notice("The app the paste was for isn't in front; nothing sent, text sent to the Scratchpad")
            outlets.toScratchpad(text)
            outlets.notify(.notPasted(.targetChanged, text: .scratchpad))
            return .finished(PasteOutcome(result: .targetChanged, autoLearnGeneration: nil))
        }

        // Nothing editable focused (desktop, Finder): ⌘V would go nowhere and the restore would then
        // take the text back off the clipboard. Keep it there and say so.
        guard outlets.focusCanTakeText() else {
            logger.notice("No editable element focused; leaving text on the clipboard and in the Scratchpad")
            return .finished(
                keepUnpasted(text, .noTextField, result: .sentToScratchpad, alsoScratchpad: true, outlets: outlets))
        }

        let timing = pasteTiming(frontmostBundleID: frontmost.bundleID, lead: lead)
        let restore = outlets.restoreSettings()
        guard let claim = clipboard.write(text, restoreLater: restore.enabled) else {
            // Not on the clipboard and not pasted: the Scratchpad keeps it.
            logger.error("Failed to prepare clipboard for paste; text sent to the Scratchpad")
            outlets.toScratchpad(text)
            outlets.notify(.notPasted(.clipboardWriteFailed, text: .scratchpad))
            return .finished(PasteOutcome(result: .commandNotPosted, autoLearnGeneration: nil))
        }

        // The target is fixed now, Yap's own window included (History's search field, the Scratchpad): the app in front
        // after the wait is never taken instead.
        let targetProcessID = frontmost.processID
        return .ready(
            PreparedPaste(
                request: request, text: text, lead: lead, dictationID: dictationID, prePasteDelay: timing.prePaste,
                restoreDelay: max(restore.delay, timing.minimumRestore), clipboardSetAt: outlets.now(),
                targetProcessID: targetProcessID,
                read: targetProcessID.flatMap {
                    $0 == ownProcessID ? nil : read(in: $0, field: field, outlets: outlets)
                },
                claim: claim))
    }

    /// No paste at all (no Accessibility, no text field): the text is left on the clipboard (not
    /// restored), and put in the Scratchpad too when `alsoScratchpad` or when the clipboard write failed. The
    /// notification says where it is. `result` when it was copied; a failed copy is `commandNotPosted` unless the
    /// Scratchpad was meant to get it anyway.
    @MainActor
    private static func keepUnpasted(
        _ text: String, _ reason: Notice.Reason, result: PasteResult, alsoScratchpad: Bool, outlets: Outlets
    ) -> PasteOutcome {
        let copied = outlets.clipboard.write(text, restoreLater: false) != nil
        if alsoScratchpad || !copied { outlets.toScratchpad(text) }
        let destination: Notice.Destination = !copied ? .scratchpad : alsoScratchpad ? .clipboardAndScratchpad : .clipboard
        outlets.notify(.notPasted(reason, text: destination))
        return PasteOutcome(result: copied || alsoScratchpad ? result : .commandNotPosted, autoLearnGeneration: nil)
    }

    private static let ownProcessID = ProcessInfo.processInfo.processIdentifier

    @MainActor
    private static func read(
        in processID: pid_t, field: AXUIElement?, outlets: Outlets
    ) -> Task<(focus: Focus, replaced: String), Never> {
        let selectedText = outlets.selectedText
        return Task { @MainActor in
            let focus = if let field { Focus.element(field) } else { await outlets.focusedElement(processID) }
            guard let selectedText else { return (focus, "") }
            return (focus, await Task.detached { selectedText(processID) }.value)
        }
    }

    @MainActor
    private static func post(_ paste: PreparedPaste, outlets: Outlets) async -> PasteOutcome {
        await waitBeforePaste(paste, outlets: outlets)
        let start: (focus: Focus, replaced: String) = await paste.read?.value ?? (.unreadable, "")
        let target = Target(processID: paste.targetProcessID, focus: start.focus)
        let focusMoved = await self.focusMoved(from: target, outlets: outlets)

        // Nothing awaited from here to ⌘V, so what is checked is what holds when the key goes out (to the OS).
        if paste.request != latest || Task.isCancelled {
            logger.notice("A newer request started before ⌘V; nothing sent, text sent to the Scratchpad")
            // Cancelled with nothing newer (the app shutting down): no notification.
            return refuse(paste, .superseded, notice: paste.request != latest ? .superseded : nil, outlets: outlets)
        }
        // Permission gone: the text stays on the clipboard for the user to paste, if it is still there. The user's
        // copy (or another paste's text) is left alone and this text goes to the Scratchpad instead.
        guard outlets.canPostKeys() else {
            logger.error("Accessibility permission went away before ⌘V; nothing sent")
            let owned = outlets.clipboard.owns(paste.claim)
            outlets.clipboard.pasteNotSent(paste.claim)
            if !owned { outlets.toScratchpad(paste.text) }
            outlets.notify(.notPasted(.accessibilityMissing, text: owned ? .clipboard : .scratchpad))
            return PasteOutcome(result: owned ? .leftOnClipboard : .clipboardChanged, autoLearnGeneration: nil)
        }
        // Same app and element, but the focus no longer takes text (a field disabled, the focus on a list): the same
        // check as when the paste started.
        if outlets.frontmostApp().processID != target.processID || focusMoved || !outlets.focusCanTakeText() {
            logger.notice("Another app or field is in front than the paste was for; nothing sent, text sent to the Scratchpad")
            return refuse(paste, .targetChanged, notice: .targetChanged, outlets: outlets)
        }
        // ⌘V pastes whatever the clipboard holds now. If that isn't this paste's write any more, it would paste the
        // user's new copy or another paste's text, so no key goes out and the clipboard is left alone.
        guard outlets.clipboard.owns(paste.claim) else {
            logger.notice("The clipboard changed before ⌘V; nothing sent, text sent to the Scratchpad")
            outlets.clipboard.pasteNotSent(paste.claim)
            outlets.toScratchpad(paste.text)
            outlets.notify(.notPasted(.clipboardChanged, text: .scratchpad))
            return PasteOutcome(result: .clipboardChanged, autoLearnGeneration: nil)
        }
        let posted = await outlets.postPasteKeys()
        guard posted.result.didPostPasteCommand else {
            // A paste that never reached the app must not take the text back off the clipboard; if it's no longer
            // there, the Scratchpad gets it.
            let owned = outlets.clipboard.owns(paste.claim)
            outlets.clipboard.pasteNotSent(paste.claim)
            if !owned { outlets.toScratchpad(paste.text) }
            outlets.notify(.notPasted(.pasteKeysFailed, text: owned ? .clipboard : .scratchpad))
            return PasteOutcome(result: posted.result, autoLearnGeneration: nil)
        }
        let autoLearnGeneration = await outlets.pasteSent(
            SentPaste(text: paste.text, processID: target.processID, dictationID: paste.dictationID, replaced: start.replaced))
        outlets.clipboard.pasteSent(paste.claim, restoreAfter: paste.restoreDelay, sleep: outlets.sleep)
        return PasteOutcome(
            result: .commandPosted, autoLearnGeneration: autoLearnGeneration, commandTime: posted.commandTime,
            sent: SentRequest(request: paste.request, target: target))
    }

    /// No ⌘V: what the user had goes back on the clipboard if this paste still holds it (a newer paste's write or
    /// the user's copy stays), and the text goes to the Scratchpad. With restore off there is nothing to put back, so
    /// the text is on the clipboard too; the notification says which.
    @MainActor
    private static func refuse(
        _ paste: PreparedPaste, _ result: PasteResult, notice reason: Notice.Reason?, outlets: Outlets
    ) -> PasteOutcome {
        if outlets.clipboard.owns(paste.claim) {
            outlets.clipboard.restore(paste.claim)
        } else {
            outlets.clipboard.pasteNotSent(paste.claim)
        }
        outlets.toScratchpad(paste.text)
        if let reason {
            let stillCopied = outlets.clipboard.owns(paste.claim)
            outlets.notify(.notPasted(reason, text: stillCopied ? .clipboardAndScratchpad : .scratchpad))
        }
        return PasteOutcome(result: result, autoLearnGeneration: nil)
    }

    /// Whether the target app's focus is known to have moved since `target` was taken: to another element that
    /// neither contains nor is contained by the first (a web view moving focus inside one field does that), or to
    /// nothing. An unreadable focus, then or now, is not a known move: the process check is all there is.
    @MainActor
    private static func focusMoved(from target: Target, outlets: Outlets) async -> Bool {
        guard let processID = target.processID, case .element(let before) = target.focus else { return false }
        let now = await outlets.focusedElement(processID)
        switch now {
        case .unreadable: return false
        case .none: return true
        case .element(let element):
            if CFEqual(element, before) { return false }
            let related = await outlets.encloses(target.focus, now)
            return !related
        }
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
        // A notification offers the Scratchpad only when the text is there, and Settings when the permission is the cause.
        assert(Notice.notPasted(.accessibilityMissing, text: .clipboard).actions == [.openAccessibilitySettings])
        assert(Notice.notPasted(.accessibilityMissing, text: .scratchpad).actions == [.openAccessibilitySettings, .openScratchpad])
        assert(Notice.notPasted(.pasteKeysFailed, text: .clipboard).actions.isEmpty, "the text is on the clipboard only")
        assert(Notice.notPasted(.targetChanged, text: .clipboardAndScratchpad).actions == [.openScratchpad])
        assert(Notice.sendSkipped(.targetChanged).actions.isEmpty && Notice.deleteSkipped(.notSent).actions.isEmpty)
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
    /// The whole parent walk, both ways; past it the two elements count as unrelated (the paste is refused).
    private static let parentWalkBudget: TimeInterval = 0.3

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

    /// Whether `a` is a parent (or further up) of `b`, or `b` of `a`. False when that couldn't be found out within
    /// `parentWalkBudget`: the elements are known to differ, and nothing showed they are one field.
    nonisolated fileprivate static func encloses(_ a: Focus, _ b: Focus) -> Bool {
        guard case .element(let a) = a, case .element(let b) = b else { return false }
        let deadline = ProcessInfo.processInfo.systemUptime + parentWalkBudget
        func isAncestor(_ ancestor: AXUIElement, of element: AXUIElement) -> Bool {
            var current = element
            for _ in 0..<maximumParentWalk {
                let left = deadline - ProcessInfo.processInfo.systemUptime
                guard left > 0 else { return false }
                AXUIElementSetMessagingTimeout(current, Float(min(left, TimeInterval(focusReadTimeout))))
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

extension CursorPaster.Notice {
    enum Action: Equatable {
        case openScratchpad, openAccessibilitySettings
    }

    /// Where the text is, then why it wasn't pasted; or which key didn't go out after a paste that did.
    var message: String {
        switch self {
        case .notPasted(let reason, let destination):
            return String(localized: "\(destination.sentence) \(reason.sentence)")
        case .sendSkipped(.targetChanged):
            return String(localized: "Yap sent the paste shortcut (⌘V) but not the send key: another app or field was in front.")
        case .sendSkipped(.superseded):
            return String(localized: "Yap sent the paste shortcut (⌘V) but not the send key: a newer paste or Undo started first.")
        case .sendSkipped:
            return String(localized: "Yap sent the paste shortcut (⌘V) but couldn't press the send key.")
        case .deleteSkipped(.notSent):
            return String(localized: "Yap couldn't remove your last dictation: the Delete key couldn't be sent.")
        case .deleteSkipped:
            return String(localized: "Yap didn't remove your last dictation: its field isn't focused anymore.")
        }
    }

    /// The notification's buttons, first one primary: what fixes the cause, then where the text is.
    var actions: [Action] {
        guard case .notPasted(let reason, let destination) = self else { return [] }
        return (reason == .accessibilityMissing ? [.openAccessibilitySettings] : [])
            + (destination == .clipboard ? [] : [.openScratchpad])
    }
}

extension CursorPaster.Notice.Destination {
    fileprivate var sentence: String {
        switch self {
        case .clipboard: return String(localized: "Copied to clipboard.")
        case .scratchpad: return String(localized: "Added to your Scratchpad.")
        case .clipboardAndScratchpad: return String(localized: "Copied to clipboard and added to your Scratchpad.")
        }
    }
}

extension CursorPaster.Notice.Reason {
    fileprivate var sentence: String {
        switch self {
        case .accessibilityMissing: return String(localized: "Allow Accessibility so Yap can paste automatically.")
        case .noTextField: return String(localized: "No text field was focused, so Yap didn't paste.")
        case .targetChanged:
            return String(localized: "Another app or field was in front when Yap was about to paste, so it didn't.")
        case .targetQuit: return String(localized: "The app Yap was going to paste into quit.")
        case .noTarget: return String(localized: "Yap couldn't tell which app to paste into, so it didn't.")
        case .clipboardChanged:
            return String(localized: "The clipboard changed just before Yap pasted, so it didn't paste and left the clipboard as it was.")
        case .superseded: return String(localized: "A newer paste or Undo started before this one was pasted.")
        case .clipboardWriteFailed: return String(localized: "Yap couldn't put the text on the clipboard, so it didn't paste.")
        case .pasteKeysFailed: return String(localized: "Yap couldn't send the paste shortcut (⌘V).")
        }
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
            // First, with nothing awaited since ⌘V: an Undo or Rewrite pressed while Auto Learn is told must not act on
            // the paste before this one.
            LastPasteEditor.shared.pasteDidFinish(text: paste.text, processID: paste.processID, replacing: paste.replaced)
            return AutoLearnSettings.isEnabled
                ? await AutoLearnService.shared.pasteDidFinish(
                    text: paste.text, processID: paste.processID, commandPosted: true, dictationID: paste.dictationID)
                : nil
        },
        toScratchpad: { ScratchpadStore.shared.append(dictation: $0) },
        notify: { notice in
            let buttons = notice.actions.map { action -> (label: String, action: () -> Void) in
                switch action {
                case .openScratchpad: return (String(localized: "Open Scratchpad"), { ScratchpadController.shared.show() })
                case .openAccessibilitySettings: return (String(localized: "Open Settings"), PrivacySettingsPane.accessibility.open)
                }
            }
            NotificationManager.shared.showNotification(
                title: notice.message,
                type: .warning,
                duration: notice.actions.first == .openAccessibilitySettings ? 8 : 6,
                actionButton: buttons.first,
                secondaryButton: buttons.dropFirst().first)
        },
        // ignoringOtherApps has no effect since macOS 14 (what History and Quick History passed before): a plain request.
        activate: { NSRunningApplication(processIdentifier: $0)?.activate() },
        isRunning: { NSRunningApplication(processIdentifier: $0).map { !$0.isTerminated } ?? false },
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
        /// Delete report they couldn't be). Nothing goes to Auto Learn, Last Paste, the Scratchpad or a notification, and
        /// no app is activated (none counts as running, so a paste into a chosen app is refused at once).
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
                // Nothing is activated; no process is looked up.
                activate: { _ in },
                isRunning: { _ in false },
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
