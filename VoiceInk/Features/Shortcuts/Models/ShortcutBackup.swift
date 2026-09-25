import Foundation

struct LegacyKeyboardShortcut: Codable {
    let carbonKeyCode: Int
    let carbonModifiers: Int
}

/// A shortcut in backups and config.json: the raw fields, plus a readable `"shortcut": "cmd+shift+space"` when
/// one exists. Reading prefers the raw fields, then the legacy format, then the readable string alone.
struct ShortcutBackup: Codable, Equatable {
    let shortcut: Shortcut

    private enum ReadableKey: String, CodingKey {
        case shortcut
    }

    init(_ shortcut: Shortcut) {
        self.shortcut = shortcut
    }

    init(from decoder: Decoder) throws {
        if let shortcut = try? Shortcut(from: decoder) {
            self.shortcut = shortcut
            return
        }

        if let legacyShortcut = try? LegacyKeyboardShortcut(from: decoder) {
            self.shortcut = Shortcut.fromLegacyShortcut(legacyShortcut)
            return
        }

        let container = try decoder.container(keyedBy: ReadableKey.self)
        let string = try container.decode(String.self, forKey: .shortcut)
        guard let shortcut = Shortcut(configString: string) else {
            throw DecodingError.dataCorruptedError(
                forKey: .shortcut, in: container, debugDescription: "Unknown shortcut \"\(string)\"")
        }
        self.shortcut = shortcut
    }

    func encode(to encoder: Encoder) throws {
        try shortcut.encode(to: encoder)
        var container = encoder.container(keyedBy: ReadableKey.self)
        try container.encodeIfPresent(shortcut.configString, forKey: .shortcut)
    }
}
