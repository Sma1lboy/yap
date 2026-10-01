import SwiftUI

/// Settings › Agent Access (MCP): the switches yap-mcp reads on every call (`AgentAccess`), and how to connect
/// Claude Code, Codex and Cursor to the helper inside this copy of Yap. docs/mcp.md has the details.
struct AgentAccessSettingsSection: View {
    @AppStorage(AgentAccess.enabledKey) private var isEnabled = false
    @AppStorage(AgentAccess.dictationsKey) private var includesDictations = false
    private let helperPath = AgentConnection.helperURL().path

    var body: some View {
        Section {
            Toggle(isOn: $isEnabled) {
                Text(AgentAccess.enabledTitle())
                Text("Claude Code, Cursor, Codex and other agents can read your meetings and dictionary through a helper inside Yap. While this is off, every read gets an error.")
            }

            Toggle(isOn: $includesDictations) {
                Text(AgentAccess.dictationsTitle())
                Text("Dictations often hold passwords, private messages and drafts. While this is off, agents can search meetings only.")
            }
            .disabled(!isEnabled)
        } header: {
            Text("Agent Access (MCP)")
        }

        Section {
            LabeledContent("Helper") {
                HStack(spacing: AppTheme.Spacing.x2) {
                    Text(verbatim: helperPath)
                        .font(AppTheme.font(.footnote).monospaced())
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: helperPath)])
                    }
                }
            }

            connectRow("Claude Code", detail: AgentConnection.claudeCode(helperPath),
                       copy: AgentConnection.claudeCode(helperPath), button: "Copy Command")
            connectRow("Codex", detail: AgentConnection.codex(helperPath),
                       copy: AgentConnection.codex(helperPath), button: "Copy Command")
            connectRow("Cursor", detail: String(localized: "Paste into ~/.cursor/mcp.json"), isCode: false,
                       copy: AgentConnection.cursor(helperPath), button: "Copy JSON")

            VStack(alignment: .leading, spacing: AppTheme.Spacing.x1) {
                Text("Data is read on this Mac only. Yap opens no network port.")
                    .settingsDescription()
                if !isEnabled {
                    Text("Agents can connect now, but they read data only after you turn on the switch above.")
                        .settingsDescription()
                }
            }

            Link("Learn More", destination: AgentConnection.docsURL)
                .appLinkStyle()
        } header: {
            Text("Connect an Agent")
        }
    }

    private func connectRow(
        _ client: String, detail: String, isCode: Bool = true, copy text: String, button: LocalizedStringKey
    ) -> some View {
        LabeledContent {
            CopyTextButton(title: button, text: text)
        } label: {
            Text(verbatim: client)
            Text(verbatim: detail)
                .font(isCode ? AppTheme.font(.footnote).monospaced() : AppTheme.font(.footnote))
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
    }
}

/// A text button that copies `text` and says "Copied" for a moment.
private struct CopyTextButton: View {
    let title: LocalizedStringKey
    let text: String
    @State private var copied = false

    var body: some View {
        Button {
            _ = ClipboardManager.copyToClipboard(text)
            copied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
        } label: {
            Text(copied ? "Copied" : title)
        }
    }
}

/// What the three clients need to start the helper, in the forms docs/mcp.md checked: Claude Code's and Codex's
/// `mcp add` commands and Cursor's `mcp.json`.
enum AgentConnection {
    static let docsURL = URL(string: "https://github.com/Sma1lboy/yap/blob/main/docs/mcp.md")!

    /// The helper inside the running copy of Yap, wherever it is installed.
    static func helperURL(bundle: Bundle = .main) -> URL {
        bundle.bundleURL.appendingPathComponent("Contents/Helpers/yap-mcp")
    }

    static func claudeCode(_ path: String) -> String { "claude mcp add yap -- \(shellQuoted(path))" }

    static func codex(_ path: String) -> String { "codex mcp add yap -- \(shellQuoted(path))" }

    static func cursor(_ path: String) -> String {
        let config = ["mcpServers": ["yap": ["type": "stdio", "command": path]]]
        let data = try? JSONSerialization.data(
            withJSONObject: config, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        return data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }

    /// As is when the shell wouldn't split or expand it, else in single quotes ("VoiceInk Dev.app" has a space).
    static func shellQuoted(_ path: String) -> String {
        let plain = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "/._-+@%,:"))
        guard path.unicodeScalars.contains(where: { !plain.contains($0) }) else { return path }
        return "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    #if DEBUG
        static func selfCheck() {
            let installed = "/Applications/Yap.app/Contents/Helpers/yap-mcp"
            assert(claudeCode(installed) == "claude mcp add yap -- /Applications/Yap.app/Contents/Helpers/yap-mcp")
            assert(codex(installed) == "codex mcp add yap -- /Applications/Yap.app/Contents/Helpers/yap-mcp")
            assert(shellQuoted("/x/VoiceInk Dev.app/y") == "'/x/VoiceInk Dev.app/y'")
            assert(shellQuoted("/x/it's/y") == "'/x/it'\\''s/y'")
            let json = try? JSONSerialization.jsonObject(with: Data(cursor("/x/VoiceInk Dev.app/y").utf8))
            let yap = ((json as? [String: Any])?["mcpServers"] as? [String: Any])?["yap"] as? [String: String]
            assert(yap == ["type": "stdio", "command": "/x/VoiceInk Dev.app/y"], "\(String(describing: json))")
        }
    #endif
}
