import AppKit
import Carbon.HIToolbox

/// The readable form config.json accepts next to the raw fields: `"cmd+shift+space"`, `"ctrl+f5"`,
/// `"right-option"` (that modifier key alone), `"fn"`. Keys are named by their US-layout position, like the raw
/// key codes. Mouse buttons and keys without a name here have no readable form; the raw fields still cover them.
extension Shortcut {
    private static let modifierNames: [(name: String, flag: NSEvent.ModifierFlags)] = [
        ("cmd", .command), ("shift", .shift), ("opt", .option), ("ctrl", .control), ("fn", .function),
    ]
    private static let modifierAliases: [String: String] = [
        "command": "cmd", "option": "opt", "alt": "opt", "control": "ctrl", "function": "fn",
    ]
    /// Modifier keys pressed alone, by side.
    private static let modifierKeys: [String: (keyCode: Int, flag: NSEvent.ModifierFlags)] = [
        "left-cmd": (kVK_Command, .command), "right-cmd": (kVK_RightCommand, .command),
        "left-shift": (kVK_Shift, .shift), "right-shift": (kVK_RightShift, .shift),
        "left-opt": (kVK_Option, .option), "right-opt": (kVK_RightOption, .option),
        "left-ctrl": (kVK_Control, .control), "right-ctrl": (kVK_RightControl, .control),
        "fn": (kVK_Function, .function),
    ]
    private static let keyNames: [String: Int] = {
        var names: [String: Int] = [
            "a": kVK_ANSI_A, "b": kVK_ANSI_B, "c": kVK_ANSI_C, "d": kVK_ANSI_D, "e": kVK_ANSI_E, "f": kVK_ANSI_F,
            "g": kVK_ANSI_G, "h": kVK_ANSI_H, "i": kVK_ANSI_I, "j": kVK_ANSI_J, "k": kVK_ANSI_K, "l": kVK_ANSI_L,
            "m": kVK_ANSI_M, "n": kVK_ANSI_N, "o": kVK_ANSI_O, "p": kVK_ANSI_P, "q": kVK_ANSI_Q, "r": kVK_ANSI_R,
            "s": kVK_ANSI_S, "t": kVK_ANSI_T, "u": kVK_ANSI_U, "v": kVK_ANSI_V, "w": kVK_ANSI_W, "x": kVK_ANSI_X,
            "y": kVK_ANSI_Y, "z": kVK_ANSI_Z,
            "0": kVK_ANSI_0, "1": kVK_ANSI_1, "2": kVK_ANSI_2, "3": kVK_ANSI_3, "4": kVK_ANSI_4,
            "5": kVK_ANSI_5, "6": kVK_ANSI_6, "7": kVK_ANSI_7, "8": kVK_ANSI_8, "9": kVK_ANSI_9,
            "-": kVK_ANSI_Minus, "=": kVK_ANSI_Equal, "[": kVK_ANSI_LeftBracket, "]": kVK_ANSI_RightBracket,
            ";": kVK_ANSI_Semicolon, "'": kVK_ANSI_Quote, ",": kVK_ANSI_Comma, ".": kVK_ANSI_Period,
            "/": kVK_ANSI_Slash, "\\": kVK_ANSI_Backslash, "`": kVK_ANSI_Grave,
            "space": kVK_Space, "return": kVK_Return, "tab": kVK_Tab, "escape": kVK_Escape, "delete": kVK_Delete,
            "forwarddelete": kVK_ForwardDelete, "left": kVK_LeftArrow, "right": kVK_RightArrow,
            "up": kVK_UpArrow, "down": kVK_DownArrow, "home": kVK_Home, "end": kVK_End,
            "pageup": kVK_PageUp, "pagedown": kVK_PageDown,
        ]
        let functionKeys = [
            kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
            kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20,
        ]
        for (index, code) in functionKeys.enumerated() { names["f\(index + 1)"] = code }
        return names
    }()
    private static let keyAliases: [String: String] = ["enter": "return", "esc": "escape", "backspace": "delete"]

    /// Nil when this shortcut has no readable form, or the form wouldn't read back as exactly this shortcut.
    var configString: String? {
        let flags = modifierFlags
        let modifiers = Self.modifierNames.filter { flags.contains($0.flag) }.map(\.name)
        let string: String?
        switch kind {
        case .key:
            string = Self.keyNames.first { $0.value == Int(keyCode) }
                .map { (modifiers + [$0.key]).joined(separator: "+") }
        case .modifierOnly:
            if let side = Self.modifierKeys.first(where: { $0.value.keyCode == Int(keyCode) }) {
                string = side.key
            } else {
                string = modifiers.isEmpty ? nil : modifiers.joined(separator: "+")
            }
        case .mouseButton:
            string = nil
        }
        return string.flatMap { Self(configString: $0) == self ? $0 : nil }
    }

    /// Parses the readable form, case-insensitively. All-modifier strings mean those modifiers held alone.
    init?(configString: String) {
        let tokens = configString.lowercased().replacingOccurrences(of: " ", with: "")
            .split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        guard !tokens.contains(where: \.isEmpty) else { return nil }
        if tokens.count == 1 {
            // "right-option" → "right-opt"
            let parts = tokens[0].split(separator: "-", maxSplits: 1).map(String.init)
            let name =
                parts.count == 2 && (parts[0] == "left" || parts[0] == "right")
                ? parts[0] + "-" + (Self.modifierAliases[parts[1]] ?? parts[1]) : tokens[0]
            if let side = Self.modifierKeys[name] {
                self = .modifierOnly(keyCode: UInt16(side.keyCode), modifierFlags: side.flag)
                return
            }
        }
        var flags: NSEvent.ModifierFlags = []
        var key: Int?
        for token in tokens {
            let modifier = Self.modifierAliases[token] ?? token
            if let flag = Self.modifierNames.first(where: { $0.name == modifier })?.flag {
                flags.insert(flag)
            } else if key == nil, let code = Self.keyNames[Self.keyAliases[token] ?? token] {
                key = code
            } else {
                return nil
            }
        }
        if let key {
            self = .key(keyCode: UInt16(key), modifierFlags: flags)
        } else if !flags.isEmpty {
            self = .modifierOnly(keyCode: nil, modifierFlags: flags)
        } else {
            return nil
        }
    }
}

#if DEBUG
    extension Shortcut {
        static func configStringSelfCheck() {
            let cases: [(String, Shortcut)] = [
                ("cmd+shift+space", .key(keyCode: UInt16(kVK_Space), modifierFlags: [.command, .shift])),
                ("opt+space", .key(keyCode: UInt16(kVK_Space), modifierFlags: [.option])),
                ("cmd+opt+ctrl+k", .key(keyCode: UInt16(kVK_ANSI_K), modifierFlags: [.command, .option, .control])),
                ("ctrl+f5", .key(keyCode: UInt16(kVK_F5), modifierFlags: [.control])),
                ("f13", .key(keyCode: UInt16(kVK_F13), modifierFlags: [])),
                ("cmd+/", .key(keyCode: UInt16(kVK_ANSI_Slash), modifierFlags: [.command])),
                ("escape", .key(keyCode: UInt16(kVK_Escape), modifierFlags: [])),
                ("right-opt", .modifierOnly(keyCode: UInt16(kVK_RightOption), modifierFlags: [.option])),
                ("right-cmd", .rightCommand),
                ("fn", .modifierOnly(keyCode: UInt16(kVK_Function), modifierFlags: [.function])),
                ("cmd+shift", .modifierOnly(keyCode: nil, modifierFlags: [.command, .shift])),
            ]
            for (string, shortcut) in cases {
                assert(shortcut.configString == string, "\(string) formats as \(shortcut.configString ?? "nil")")
                assert(Shortcut(configString: string) == shortcut, "\(string) parses")
            }
            // Aliases and case.
            assert(Shortcut(configString: "Command+Shift+Space") == cases[0].1)
            assert(Shortcut(configString: "right-option") == cases[7].1)
            assert(Shortcut(configString: "ctrl+esc") == .key(keyCode: UInt16(kVK_Escape), modifierFlags: [.control]))
            // fn on an F key is dropped by normalization, so it reads back as the plain F key.
            assert(Shortcut(configString: "fn+f5") == .key(keyCode: UInt16(kVK_F5), modifierFlags: []))
            // Not expressible: raw fields only.
            assert(Shortcut.mouseButton(buttonNumber: 3).configString == nil)
            assert(Shortcut.key(keyCode: UInt16(kVK_ANSI_KeypadEnter), modifierFlags: []).configString == nil)
            for bad in ["", "cmd+", "cmd+a+b", "hyper+a", "a+b"] { assert(Shortcut(configString: bad) == nil, bad) }

            // In config JSON: raw fields win, the string alone works, both are written.
            let decoder = JSONDecoder()
            let rawAndString = #"{"kind":"key","keyCode":0,"modifierFlagsRawValue":1048576,"shortcut":"cmd+b"}"#
            assert((try? decoder.decode(ShortcutBackup.self, from: Data(rawAndString.utf8)))?.shortcut.keyCode == 0)
            let stringOnly = try? decoder.decode(
                ShortcutBackup.self, from: Data(#"{"shortcut":"cmd+shift+space"}"#.utf8))
            assert(stringOnly?.shortcut == cases[0].1)
            let written = (try? JSONEncoder().encode(ShortcutBackup(cases[0].1)))
                .flatMap { String(data: $0, encoding: .utf8) }
            assert(written?.contains(#""shortcut":"cmd+shift+space""#) == true && written?.contains("keyCode") == true)
            let mouse = (try? JSONEncoder().encode(ShortcutBackup(.mouseButton(buttonNumber: 3))))
                .flatMap { String(data: $0, encoding: .utf8) }
            assert(mouse?.contains("\"shortcut\"") == false)
        }
    }
#endif
