import Foundation

/// Settings search: each section of SettingsView is shown when the query is a case- and accent-insensitive
/// substring of its title or of one of its row titles, in the app's current language.
/// ponytail: matches whole sections, not single rows; per-row filtering needs each row wrapped in its own check.
enum SettingsGroup: CaseIterable {
    case account, config, shortcuts, voiceEdits, additionalShortcuts, meetings, pasting, interface, general, backup,
        history, agentAccess, help, diagnostics, about

    /// Section title first, then its row titles. Keys are the ones the section's own views use.
    var terms: [String] {
        switch self {
        case .account:
            return [
                String(localized: "Account"), String(localized: "Signed in as"),
                String(localized: "Sync Settings Across Macs"), String(localized: "Sync Now"), String(localized: "Version History…"),
                String(localized: "Manage Yap Cloud…"), String(localized: "Sign Out"),
            ]
        case .config:
            return [
                String(localized: "Config File"), "config.json", String(localized: "Path"),
                String(localized: "Show in Finder"), String(localized: "Reload"),
                String(localized: "Write Current Settings to Config"), String(localized: "Keep Config File in Sync"),
                String(localized: "Import from VoiceInk…"),
            ]
        case .shortcuts:
            return [
                String(localized: "Shortcuts"), String(localized: "Primary Shortcut"),
                String(localized: "Secondary Shortcut"), String(localized: "Add Second Shortcut"),
                String(localized: "Restore Default Shortcuts…"),
            ]
        case .voiceEdits:
            return [
                String(localized: "Voice Edits"), String(localized: "Undo Last Paste"),
                String(localized: "Rewrite Last Dictation"),
            ]
        case .additionalShortcuts:
            return [
                String(localized: "Additional Shortcuts"), String(localized: "Paste Last Transcription (Original)"),
                String(localized: "Paste Last Transcription (Enhanced)"), String(localized: "Copy Last Transcription"),
                String(localized: "Retry Last Transcription"), String(localized: "Open Quick History"), String(localized: "Open Scratchpad"),
                String(localized: "Quick Add to Dictionary"), String(localized: "Cancel Recording"),
            ]
        case .meetings:
            return [
                String(localized: "Meetings"), String(localized: "Record Meeting"),
                String(localized: "Remind Me to Record When a Call Starts"),
                String(localized: "Save Meetings to a Folder Automatically"),
            ]
        case .pasting:
            return [
                String(localized: "Pasting"), String(localized: "Add Space After Paste"),
                String(localized: "Auto Send"), String(localized: "Keep Clipboard Content"),
                String(localized: "Paste Method"),
            ]
        case .interface:
            return [
                String(localized: "Interface"), String(localized: "Appearance"), String(localized: "Language"),
                String(localized: "Recorder Style"), String(localized: "Live Text Display"),
            ]
        case .general:
            return [
                String(localized: "General"), String(localized: "Hide Dock Icon"), String(localized: "Launch at Login"),
            ]
        case .backup:
            return [
                String(localized: "Backup"), String(localized: "Export Settings"), String(localized: "Import Settings"),
            ]
        case .history:
            return [String(localized: "History"), String(localized: "Auto-delete transcripts and audio")]
        case .agentAccess:
            return [
                String(localized: "Agent Access (MCP)"), AgentAccess.enabledTitle(), AgentAccess.dictationsTitle(),
                String(localized: "Connect an Agent"), String(localized: "Helper"), "MCP", "Claude Code", "Codex",
                "Cursor",
            ]
        case .help:
            return [String(localized: "Help"), String(localized: "Explore Key Features")]
        case .diagnostics:
            return [String(localized: "Diagnostics"), String(localized: "Reset Onboarding")]
        case .about:
            return [
                String(localized: "About"), String(localized: "Version"),
                String(localized: "Automatically Check for Updates"), String(localized: "Check for Updates"),
                String(localized: "Report an Issue"),
            ]
        }
    }

    static func matches(_ query: String, terms: [String]) -> Bool {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return q.isEmpty || terms.contains { $0.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
    }

    static func visible(for query: String) -> Set<SettingsGroup> {
        Set(allCases.filter { matches(query, terms: $0.terms) })
    }

    #if DEBUG
        static func selfCheck() {
            assert(visible(for: "").count == allCases.count)
            assert(visible(for: "   ").count == allCases.count)
            assert(matches("PASTE", terms: ["Paste Method"]))
            assert(matches("cafe", terms: ["Café"]))
            assert(!matches("zzz", terms: ["Paste Method"]))
            assert(visible(for: "zzzzqq").isEmpty)
            assert(visible(for: "config.json").contains(.config))
            // The meeting settings are in Meetings, not among the shortcuts.
            assert(visible(for: String(localized: "Remind Me to Record When a Call Starts")) == [.meetings])
            assert(visible(for: String(localized: "Save Meetings to a Folder Automatically")) == [.meetings])
            let meeting = visible(for: String(localized: "Record Meeting"))
            assert(meeting.contains(.meetings) && !meeting.contains(.additionalShortcuts))
            // Agent access is found by its switches and by the clients' names.
            assert(visible(for: AgentAccess.dictationsTitle()) == [.agentAccess])
            assert(visible(for: "claude code") == [.agentAccess] && visible(for: "mcp").contains(.agentAccess))
        }
    #endif
}
