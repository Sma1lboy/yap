import Foundation

/// Yap.app around this helper (it's installed as Yap.app/Contents/Helpers/yap-mcp): its translations and the
/// language the user picked for it, so the Markdown has the same words as History's export.
enum EnclosingApp {
    static let bundle: Bundle? = {
        guard let executable = Bundle.main.executableURL?.resolvingSymlinksInPath() else { return nil }
        let app = executable.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        guard app.pathExtension == "app", let bundle = Bundle(url: app), bundle.bundleIdentifier != nil else { return nil }
        return bundle
    }()

    /// Where the strings come from: Yap.app's, or the helper's own (English) when it runs outside the app.
    static var strings: Bundle { bundle ?? .main }

    /// The helper's own version: MARKETING_VERSION, the same build setting as the app's.
    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
    }

    static var defaultDataDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(AppIdentity.supportDirectoryName, isDirectory: true)
    }

    /// Settings › Language writes `AppleLanguages` into the app's own defaults (AppLanguagePreference). Read them
    /// from there (or the system's when the app follows the system, as the app itself does) and use them in this
    /// process. Call before anything is localized or formatted.
    static func adoptLanguage() {
        guard let identifier = bundle?.bundleIdentifier else { return }
        var preferences: [String: Any] = [:]
        for key in ["AppleLanguages", "AppleLocale"] {
            if let value = CFPreferencesCopyAppValue(key as CFString, identifier as CFString) {
                preferences[key] = value
            }
        }
        UserDefaults.standard.setVolatileDomain(preferences, forName: UserDefaults.argumentDomain)
    }

    /// What Settings › Agent Access (MCP) allows now, read from the app's own defaults on every call (synchronized
    /// first, so a switch flipped in Yap applies to the next call). Off when the helper runs outside Yap.app, where
    /// there are no switches to read.
    static func agentAccess() -> AgentAccess.Level {
        guard let identifier = bundle?.bundleIdentifier else { return .off }
        let domain = identifier as CFString
        CFPreferencesAppSynchronize(domain)
        return AgentAccess.level { CFPreferencesCopyAppValue($0 as CFString, domain) }
    }
}
