import Foundation

/// Schema v1 of `~/.config/yap/config.json`. Every field is optional; empty strings count as unset.
struct YapConfig: Codable, Equatable {
    struct Transcription: Codable, Equatable {
        var provider: String?
        var model: String?
    }

    struct Enhancement: Codable, Equatable {
        var enabled: Bool?
        var provider: String?
        var model: String?
        /// A file path (relative to the config dir, absolute, or `~/...`) or inline prompt text.
        var prompt: String?
    }

    struct DefaultMode: Codable, Equatable {
        var screenContext: Bool?
        var clipboardContext: Bool?
        var selectedTextContext: Bool?
    }

    var keys: [String: String]?
    var transcription: Transcription?
    var enhancement: Enhancement?
    var defaultMode: DefaultMode?

    static let promptID = UUID(uuidString: "A1B2C3D4-0000-4000-8000-00000000C0DE")!

    static let template = """
        {
          "keys": { "openrouter": "" },
          "transcription": { "provider": "", "model": "" },
          "enhancement": { "provider": "", "model": "", "prompt": "" },
          "defaultMode": {}
        }

        """

    // MARK: - Locations

    static func configDirectory(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let xdg = environment["XDG_CONFIG_HOME"]?.nonEmpty {
            return URL(fileURLWithPath: (xdg as NSString).expandingTildeInPath).appendingPathComponent("yap")
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/yap")
    }

    // MARK: - Parsing

    /// Decodes and drops empty strings/sections so callers only see fields that were actually set.
    static func decode(_ data: Data) throws -> YapConfig {
        var config = try JSONDecoder().decode(YapConfig.self, from: data)
        config.keys = config.keys?.filter { $0.value.nonEmpty != nil }
        if config.keys?.isEmpty == true { config.keys = nil }
        if var transcription = config.transcription {
            transcription.provider = transcription.provider?.nonEmpty
            transcription.model = transcription.model?.nonEmpty
            config.transcription = transcription == Transcription() ? nil : transcription
        }
        if var enhancement = config.enhancement {
            enhancement.provider = enhancement.provider?.nonEmpty
            enhancement.model = enhancement.model?.nonEmpty
            enhancement.prompt = enhancement.prompt?.nonEmpty
            config.enhancement = enhancement == Enhancement() ? nil : enhancement
        }
        if config.defaultMode == DefaultMode() { config.defaultMode = nil }
        return config
    }

    /// Human-readable decoding error that names the JSON path, e.g. `enhancement.enabled: Expected Bool`.
    static func describe(_ error: Error) -> String {
        func path(_ codingPath: [CodingKey]) -> String {
            let joined = codingPath.map { $0.intValue.map { "[\($0)]" } ?? $0.stringValue }.joined(separator: ".")
            return joined.isEmpty ? "(root)" : joined
        }
        switch error as? DecodingError {
        case .typeMismatch(_, let context), .valueNotFound(_, let context), .dataCorrupted(let context):
            let underlying = (context.underlyingError as NSError?)?.userInfo[NSDebugDescriptionErrorKey] as? String
            return "\(path(context.codingPath)): \(underlying ?? context.debugDescription)"
        case .keyNotFound(let key, let context):
            return "\(path(context.codingPath + [key])): missing key"
        default:
            return error.localizedDescription
        }
    }

    /// Parses `KEY=VALUE` lines (optional `export `, `#` comments, surrounding quotes stripped).
    static func parseDotEnv(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        for rawLine in text.split(whereSeparator: \.isNewline) {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("export ") { line = String(line.dropFirst(7)) }
            guard !line.hasPrefix("#"), let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, let first = value.first, first == value.last, first == "\"" || first == "'" {
                value = String(value.dropFirst().dropLast())
            }
            if !key.isEmpty { result[key] = value }
        }
        return result
    }

    /// Resolves a key value: `env:NAME` reads the environment, then `~/.env`; anything else is literal.
    /// Returns nil for empty or unresolved values.
    static func resolveSecret(_ value: String, environment: [String: String], dotEnv: () -> String?) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("env:") else { return trimmed.nonEmpty }
        let name = String(trimmed.dropFirst(4)).trimmingCharacters(in: .whitespaces)
        if let fromEnv = environment[name]?.nonEmpty { return fromEnv }
        return dotEnv().flatMap { parseDotEnv($0)[name]?.nonEmpty }
    }

    /// Reads the prompt from a file when `value` names an existing file, otherwise returns it as inline text.
    static func resolvePrompt(_ value: String, configDirectory: URL, readFile: (URL) -> String?) -> String? {
        guard let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty else { return nil }
        let expanded = (trimmed as NSString).expandingTildeInPath
        let url =
            expanded.hasPrefix("/")
            ? URL(fileURLWithPath: expanded) : configDirectory.appendingPathComponent(trimmed)
        if !trimmed.contains("\n"), let text = readFile(url) { return text }
        return trimmed
    }
}

extension String {
    fileprivate var nonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

#if DEBUG
    extension YapConfig {
        static func selfCheck() {
            let env = parseDotEnv("# c\nexport A=\"x y\"\nB='z'\nC=plain=eq\n\nD=")
            assert(env == ["A": "x y", "B": "z", "C": "plain=eq", "D": ""])
            assert(resolveSecret("env:A", environment: ["A": "fromEnv"], dotEnv: { "A=fromFile" }) == "fromEnv")
            assert(resolveSecret("env:A", environment: [:], dotEnv: { "A=fromFile" }) == "fromFile")
            assert(resolveSecret("env:A", environment: [:], dotEnv: { nil }) == nil)
            assert(resolveSecret("  ", environment: [:], dotEnv: { nil }) == nil)
            assert(resolveSecret("sk-or-1", environment: [:], dotEnv: { nil }) == "sk-or-1")
            let dir = URL(fileURLWithPath: "/cfg")
            let files = ["/cfg/prompt.md": "FILE", "/abs/p.md": "ABS"]
            let read: (URL) -> String? = { files[$0.path] }
            assert(resolvePrompt("prompt.md", configDirectory: dir, readFile: read) == "FILE")
            assert(resolvePrompt("/abs/p.md", configDirectory: dir, readFile: read) == "ABS")
            assert(resolvePrompt("Fix grammar.", configDirectory: dir, readFile: read) == "Fix grammar.")
            assert(resolvePrompt("", configDirectory: dir, readFile: read) == nil)
            assert((try? decode(Data(template.utf8))) == YapConfig())
            let partial = try? decode(Data(#"{"transcription":{"provider":"openrouter","model":" "}}"#.utf8))
            assert(partial?.transcription == Transcription(provider: "openrouter", model: nil))
            do {
                _ = try decode(Data(#"{"enhancement":{"enabled":"yes"}}"#.utf8))
                assertionFailure("expected decoding error")
            } catch {
                assert(describe(error).hasPrefix("enhancement.enabled:"))
            }
        }
    }
#endif
