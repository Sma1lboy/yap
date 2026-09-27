import Foundation

/// Yap's own on-disk and keychain namespace, kept separate from upstream VoiceInk so both can be installed side by side.
enum AppIdentity {
    #if DEBUG
        /// `make mock` and `make offline-check` run a copy of the Debug app re-identified as me.sma1lboy.yap.mock,
        /// `make ui-snapshots` one re-identified as me.sma1lboy.yap.snapshots: each has its own defaults domain
        /// (from the bundle id), support directory and keychain service, so the dev app's settings are never touched.
        static let mockIdentifier = "me.sma1lboy.yap.mock"
        static let snapshotsIdentifier = "me.sma1lboy.yap.snapshots"
        static let isMock = Bundle.main.bundleIdentifier == mockIdentifier
        private static let isolatedIdentifier: String? = [mockIdentifier, snapshotsIdentifier]
            .first { $0 == Bundle.main.bundleIdentifier }
        static let supportDirectoryName: String = isolatedIdentifier ?? "me.sma1lboy.yap"
        static let keychainService: String = isolatedIdentifier ?? "me.sma1lboy.yap"
    #else
        static let supportDirectoryName = "me.sma1lboy.yap"
        static let keychainService = "me.sma1lboy.yap"
    #endif
    static let repositoryURL = URL(string: "https://github.com/Sma1lboy/yap")!
    static let issuesURL = URL(string: "https://github.com/Sma1lboy/yap/issues")!
}
