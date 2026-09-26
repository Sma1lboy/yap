import Foundation

/// Yap's own on-disk and keychain namespace, kept separate from upstream VoiceInk so both can be installed side by side.
enum AppIdentity {
    #if DEBUG
        /// `make mock` runs a copy of the Debug app re-identified as me.sma1lboy.yap.mock: its own defaults domain,
        /// support directory and keychain service, seeded with fake data (MockEnvironment).
        static let isMock = Bundle.main.bundleIdentifier == "me.sma1lboy.yap.mock"
        static let supportDirectoryName = isMock ? "me.sma1lboy.yap.mock" : "me.sma1lboy.yap"
        static let keychainService = isMock ? "me.sma1lboy.yap.mock" : "me.sma1lboy.yap"
    #else
        static let supportDirectoryName = "me.sma1lboy.yap"
        static let keychainService = "me.sma1lboy.yap"
    #endif
    static let repositoryURL = URL(string: "https://github.com/Sma1lboy/yap")!
    static let issuesURL = URL(string: "https://github.com/Sma1lboy/yap/issues")!
}
