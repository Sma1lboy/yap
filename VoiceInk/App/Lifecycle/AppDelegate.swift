import Cocoa
import os
import SwiftUI
import UniformTypeIdentifiers

class AppDelegate: NSObject, NSApplicationDelegate {
    weak var menuBarManager: MenuBarManager?
    /// Its local models are freed on Quit.
    weak var engine: VoiceInkEngine?
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "AppDelegate")
    /// The Quit that is closing, once applicationShouldTerminate has said `.terminateLater`.
    private var quitting: Task<Void, Never>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        menuBarManager?.applyActivationPolicy()
        YapCloud.shared.scheduleBalanceRefresh()
        DispatchQueue.main.async { MoveToApplicationsPrompt.showIfNeeded() }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if let menuBarManager, !menuBarManager.isMenuBarOnly {
            if WindowManager.shared.currentMainWindow() != nil {
                WindowManager.shared.showMainWindow()
                return false
            }

            WindowManager.shared.prepareForUserRequestedMainWindow()
            NotificationCenter.default.post(name: .showMainWindowRequested, object: nil)
            return false
        }

        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    /// ⌘Q during a meeting would cut it off: ask first. The default button keeps recording, so a stray Return
    /// can't end it either; ending the meeting finishes and saves it before Yap quits. Then, on every Quit, the local
    /// models are freed before AppKit calls exit() (see `closeLocalModels`); a load or decode in flight finishes first.
    /// `terminate:` must come from the run loop (a menu item, a quit Apple event), not from inside a main-queue job such
    /// as a `Task`: AppKit's wait for the reply then can't run the main actor, and Quit never finishes.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let answer = shouldTerminate(
            isRecordingMeeting: MeetingRecorder.isRecordingMeeting,
            confirmEndingMeeting: Self.confirmEndingMeeting,
            endMeeting: { await MeetingRecorder.shared.stop() },
            closeModels: { [weak self] in await self?.engine?.closeLocalModels() },
            reply: { sender.reply(toApplicationShouldTerminate: true) })
        if answer == .terminateLater { (sender as? YapApplication)?.isClosingForQuit = true }
        return answer
    }

    private static func confirmEndingMeeting() -> Bool {
        let alert = NSAlert()
        alert.messageText = String(localized: "A meeting is recording")
        alert.informativeText = String(localized: "Quitting now would cut it off. End the meeting to save its transcript and notes first, or keep recording.")
        alert.addButton(withTitle: String(localized: "Keep Recording"))
        alert.addButton(withTitle: String(localized: "End Meeting and Quit"))
        return alert.runModal() == .alertSecondButtonReturn
    }

    /// The Quit itself, apart from AppKit and the meeting so selfCheck can drive it. Keep Recording cancels before
    /// anything is closed.
    func shouldTerminate(
        isRecordingMeeting: Bool, confirmEndingMeeting: () -> Bool,
        endMeeting: @escaping @MainActor () async -> Void, closeModels: @escaping @MainActor () async -> Void,
        reply: @escaping @MainActor () -> Void
    ) -> NSApplication.TerminateReply {
        if isRecordingMeeting, !confirmEndingMeeting() { return .terminateCancel }
        quitting = Task { @MainActor [logger] in
            if isRecordingMeeting { await endMeeting() }
            logger.notice("quit: closing local models")
            await closeModels()
            logger.notice("quit: local models closed")
            reply()
        }
        return .terminateLater
    }

    // Stash URL when app cold-starts to avoid spawning a new window/tab
    var pendingOpenFileURL: URL?

    func application(_ application: NSApplication, open urls: [URL]) {
        if urls.contains(where: YapCloud.isAccountRefreshURL) {
            showAccountAndRefresh()
            return
        }
        guard let url = urls.first(where: { SupportedMedia.isSupported(url: $0) }) else {
            return
        }

        if let menuBarManager {
            menuBarManager.activateForPresentedWindow()
        } else {
            AppPresentationPolicy.activateForUserFacingWindow()
        }

        if WindowManager.shared.currentMainWindow() == nil {
            // Cold start: do NOT create a window here to avoid extra window/tab.
            // Defer to SwiftUI's main window scene and let ContentView process this later.
            pendingOpenFileURL = url
            WindowManager.shared.prepareForUserRequestedMainWindow()
            NotificationCenter.default.post(name: .showMainWindowRequested, object: nil)
        } else {
            // Running: focus current window and route in-place to Transcribe Audio
            WindowManager.shared.showMainWindow()
            NotificationCenter.default.post(
                name: .navigateToDestination, object: nil, userInfo: ["destination": "Transcribe Audio"])
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .openFileForTranscription, object: nil, userInfo: ["url": url])
            }
        }
    }

    /// `yap://account/refresh` (paygate's checkout success page): bring Yap forward on Account and reload the balance.
    private func showAccountAndRefresh() {
        if let menuBarManager {
            menuBarManager.activateForPresentedWindow()
        } else {
            AppPresentationPolicy.activateForUserFacingWindow()
        }
        // Set before the window exists so a cold start opens straight on Account.
        MainWindowNavigation.shared.navigate(to: .account)
        if WindowManager.shared.currentMainWindow() == nil {
            WindowManager.shared.prepareForUserRequestedMainWindow()
            NotificationCenter.default.post(name: .showMainWindowRequested, object: nil)
        } else {
            WindowManager.shared.showMainWindow()
        }
        Task { @MainActor in await YapCloud.shared.refreshAccount() }
    }
}

/// NSApp (VoiceInkApp.init asks for `YapApplication.shared` before SwiftUI does). A `terminate:` that comes while
/// AppKit waits for a `.terminateLater` reply exits right away without asking the delegate again, so a second ⌘Q or a
/// Quit from the Dock during AppDelegate's closing would cut off the meeting being saved or the model being freed.
/// Those are dropped.
final class YapApplication: NSApplication {
    /// Set when applicationShouldTerminate answers `.terminateLater`; the reply ends the process.
    var isClosingForQuit = false

    override func terminate(_ sender: Any?) {
        if isClosingForQuit { return }
        super.terminate(sender)
    }
}

#if DEBUG
    extension AppDelegate {
        /// Quit's order, with the meeting and the models stood in for: Keep Recording closes nothing and the next Quit
        /// asks again; End Meeting and Quit saves the meeting, then frees the models, then lets AppKit exit.
        @MainActor static func quitSelfCheck() async {
            final class Steps { var names: [String] = [] }
            let steps = Steps()
            let delegate = AppDelegate()
            func quit(confirm: Bool) -> NSApplication.TerminateReply {
                delegate.shouldTerminate(
                    isRecordingMeeting: true, confirmEndingMeeting: { steps.names.append("asked"); return confirm },
                    endMeeting: { await Task.yield(); steps.names.append("meeting saved") },
                    closeModels: { await Task.yield(); steps.names.append("models closed") },
                    reply: { steps.names.append("replied") })
            }
            precondition(quit(confirm: false) == .terminateCancel && steps.names == ["asked"], "\(steps.names)")
            precondition(delegate.quitting == nil)
            precondition(quit(confirm: true) == .terminateLater)
            await delegate.quitting?.value
            precondition(steps.names == ["asked", "asked", "meeting saved", "models closed", "replied"], "\(steps.names)")
        }
    }
#endif
