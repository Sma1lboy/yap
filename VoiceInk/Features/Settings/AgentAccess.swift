import Foundation

/// Settings › Agent Access (MCP): what yap-mcp, the MCP server inside Yap.app (docs/mcp.md), may read. Compiled
/// into the app and the helper. The helper reads both switches from the app's defaults on every tool call, so a
/// change applies to the agent's next call without restarting it.
enum AgentAccess {
    /// "Let Agents Read Yap's Data": meetings and the dictionary.
    static let enabledKey = "agentAccessEnabled"
    /// "Include Dictation History": dictations as well. They hold passwords, private messages and drafts more often
    /// than meeting notes do, so they need their own yes.
    static let dictationsKey = "agentAccessIncludesDictations"

    enum Level: Equatable {
        case off, meetingsAndDictionary, everything
    }

    /// Both switches start off: a missing value is off, and nothing registers a default for them (the helper
    /// wouldn't see a registered default). `value` reads one key of the app's defaults.
    static func level(_ value: (String) -> Any?) -> Level {
        func isOn(_ key: String) -> Bool { (value(key) as? Bool) == true }
        guard isOn(enabledKey) else { return .off }
        return isOn(dictationsKey) ? .everything : .meetingsAndDictionary
    }

    static let defaultSearchLimit = 20
    static let maxSearchLimit = 50

    /// search_history's limit: 20 when not given, otherwise kept within 1...50.
    static func searchLimit(_ requested: Int?) -> Int {
        min(max(requested ?? defaultSearchLimit, 1), maxSearchLimit)
    }

    /// Where the switches are, in the app's language: "Yap › Settings › Agent Access (MCP)". The helper puts it in
    /// its "turn this on" errors, so the agent can tell the user what they'll see.
    static func settingsPath(bundle: Bundle = .main) -> String {
        ["Yap", String(localized: "Settings", bundle: bundle), String(localized: "Agent Access (MCP)", bundle: bundle)]
            .joined(separator: " › ")
    }

    static func enabledTitle(bundle: Bundle = .main) -> String {
        String(localized: "Let Agents Read Yap's Data", bundle: bundle)
    }

    static func dictationsTitle(bundle: Bundle = .main) -> String {
        String(localized: "Include Dictation History", bundle: bundle)
    }

    #if DEBUG
        static func selfCheck() {
            func level(_ values: [String: Any]) -> Level { Self.level { values[$0] } }
            assert(level([:]) == .off, "off until turned on")
            assert(level([dictationsKey: true]) == .off, "dictations alone open nothing")
            assert(level([enabledKey: true]) == .meetingsAndDictionary)
            assert(level([enabledKey: true, dictationsKey: false]) == .meetingsAndDictionary)
            assert(level([enabledKey: true, dictationsKey: true]) == .everything)
            assert(level([enabledKey: "yes"]) == .off, "only a real true turns it on")
            assert(level([enabledKey: NSNumber(value: true), dictationsKey: NSNumber(value: true)]) == .everything)

            assert(searchLimit(nil) == 20 && searchLimit(7) == 7 && searchLimit(50) == 50)
            assert(searchLimit(500) == 50 && searchLimit(0) == 1 && searchLimit(-3) == 1, "kept within 1...50")
        }
    #endif
}
