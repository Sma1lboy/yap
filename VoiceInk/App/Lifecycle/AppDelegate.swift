import Cocoa
import SwiftUI
import UniformTypeIdentifiers

class AppDelegate: NSObject, NSApplicationDelegate {
    weak var menuBarManager: MenuBarManager?

    func applicationDidFinishLaunching(_ notification: Notification) {
        menuBarManager?.applyActivationPolicy()
        YapCloud.shared.scheduleBalanceRefresh()
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
