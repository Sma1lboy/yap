import AppKit

/// Asks once per location to move Yap into Applications when it was downloaded and is running from somewhere else.
/// A quarantined app outside Applications runs from a read-only AppTranslocation mirror where Sparkle can't install
/// updates, and clearing Downloads later deletes it. Never moves, deletes or restarts anything.
enum MoveToApplicationsPrompt {
    private static let dismissedKey = "moveToApplicationsDismissed"
    private static let translocationMarker = "/AppTranslocation/"

    /// `bundlePath` is `Bundle.main.bundlePath`; `isQuarantined` is whether it carries `com.apple.quarantine`.
    /// A local build (`make local` copies to ~/Downloads) has no quarantine attribute, so it never prompts.
    static func shouldPrompt(bundlePath: String, isQuarantined: Bool, homeDirectory: String) -> Bool {
        if bundlePath.contains(translocationMarker) { return true }
        guard isQuarantined else { return false }
        return !(bundlePath.hasPrefix("/Applications/") || bundlePath.hasPrefix(homeDirectory + "/Applications/"))
    }

    /// The translocation path changes on every launch, so "Not Now" is remembered under one fixed key for all of them.
    static func dismissalKey(bundlePath: String) -> String {
        bundlePath.contains(translocationMarker) ? "AppTranslocation" : bundlePath
    }

    /// Call once at launch. Skipped entirely in DEBUG builds.
    @MainActor
    static func showIfNeeded() {
        #if !DEBUG
            let path = Bundle.main.bundlePath
            let quarantined = getxattr(path, "com.apple.quarantine", nil, 0, 0, 0) >= 0
            guard
                shouldPrompt(
                    bundlePath: path, isQuarantined: quarantined, homeDirectory: NSHomeDirectory())
            else { return }
            let key = dismissalKey(bundlePath: path)
            var dismissed = UserDefaults.standard.stringArray(forKey: dismissedKey) ?? []
            guard !dismissed.contains(key) else { return }

            let alert = NSAlert()
            alert.messageText = String(localized: "Move Yap to Applications")
            alert.informativeText = String(
                localized:
                    "Yap can only update itself from the Applications folder. Drag Yap into it, then open Yap from there."
            )
            alert.addButton(withTitle: String(localized: "Open Applications Folder"))
            alert.addButton(withTitle: String(localized: "Not Now"))
            NSApp.activate(ignoringOtherApps: true)
            if alert.runModal() == .alertFirstButtonReturn {
                NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications", isDirectory: true))
            } else {
                dismissed.append(key)
                UserDefaults.standard.set(dismissed, forKey: dismissedKey)
            }
        #endif
    }

    #if DEBUG
        static func selfCheck() {
            let home = "/Users/jo"
            func prompts(_ path: String, quarantined: Bool) -> Bool {
                shouldPrompt(bundlePath: path, isQuarantined: quarantined, homeDirectory: home)
            }
            assert(!prompts("/Applications/Yap.app", quarantined: true))
            assert(!prompts("/Users/jo/Applications/Yap.app", quarantined: true))
            assert(prompts("/Users/jo/Downloads/Yap.app", quarantined: true))
            assert(!prompts("/Users/jo/Downloads/Yap.app", quarantined: false))
            assert(prompts("/private/var/folders/ab/cd/T/AppTranslocation/1234-ABCD/d/Yap.app", quarantined: true))
            assert(
                !prompts(
                    "/Users/jo/Library/Developer/Xcode/DerivedData/VoiceInk-abc/Build/Products/Release/Yap.app",
                    quarantined: false))

            assert(dismissalKey(bundlePath: "/private/var/folders/x/AppTranslocation/A/d/Yap.app") == "AppTranslocation")
            assert(dismissalKey(bundlePath: "/Users/jo/Downloads/Yap.app") == "/Users/jo/Downloads/Yap.app")
        }
    #endif
}
