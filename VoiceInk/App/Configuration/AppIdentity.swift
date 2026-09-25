import Foundation

/// Yap's own on-disk and keychain namespace, kept separate from upstream VoiceInk so both can be installed side by side.
enum AppIdentity {
    static let supportDirectoryName = "me.sma1lboy.yap"
    static let keychainService = "me.sma1lboy.yap"
    static let repositoryURL = URL(string: "https://github.com/Sma1lboy/yap")!
    static let issuesURL = URL(string: "https://github.com/Sma1lboy/yap/issues")!
}
