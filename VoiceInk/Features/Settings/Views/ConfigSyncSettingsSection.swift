import SwiftUI

/// Settings → Config File: config.json (path, status, write-back) and the VoiceInk import.
struct ConfigSyncSettingsSection: View {
    @ObservedObject private var configLoader = YapConfigLoader.shared
    @AppStorage(YapConfigLoader.keepInSyncKey) private var keepConfigFileInSync = false
    @State private var voiceInkImport: YapConfig?
    @State private var voiceInkImportResult: String?
    private let hasVoiceInk = VoiceInkImport.installedDefaults() != nil

    var body: some View {
        Section {
            LabeledContent("Path") {
                Text(configLoader.fileURL.path)
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            configFileStatus

            if configLoader.fileIsNewerVersion {
                Text("This file comes from a newer version of Yap. Fields it doesn't recognize were ignored.")
                    .foregroundColor(AppTheme.Status.warningStrong)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button("Open") {
                    configLoader.openConfigFile()
                }
                Button("Show in Finder") {
                    configLoader.revealConfigFile()
                }
                Button("Reload") {
                    Task { await configLoader.reload() }
                }
            }

            Button("Write Current Settings to Config") {
                Task { await configLoader.writeCurrentSettings() }
            }
            if let error = configLoader.writeError {
                Text(String(format: String(localized: "Could not write config file: %@"), error))
                    .foregroundColor(AppTheme.Status.error)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let date = configLoader.lastWritten {
                Text(
                    String(
                        format: String(localized: "Written at %@"), date.formatted(date: .abbreviated, time: .shortened))
                )
                .settingsDescription()
            }

            Toggle(isOn: $keepConfigFileInSync) {
                Text("Keep Config File in Sync")
                Text("Writes settings changes back to the file. The previous file is kept as config.json.bak.")
            }

            voiceInkImportRow
        } header: {
            Text("Config File")
        } footer: {
            Text("Fields set in this file are applied at launch and override the same settings changed in the app.")
        }
    }

    /// Manual only: reads VoiceInk's settings, shows what they contain, imports after confirmation.
    @ViewBuilder
    private var voiceInkImportRow: some View {
        LabeledContent {
            Button("Import from VoiceInk…") {
                Task {
                    let dictionary = VoiceInkImport.readDictionary()
                    guard let defaults = VoiceInkImport.installedDefaults() else { return }
                    voiceInkImport = VoiceInkImport.config(from: defaults, dictionary: dictionary)
                }
            }
            .disabled(!hasVoiceInk)
        } label: {
            Text("VoiceInk")
            Text(
                hasVoiceInk
                    ? String(localized: "Bring over modes, prompts, dictionary, shortcuts, general settings and custom models. API keys and license aren't copied.")
                    : String(localized: "No VoiceInk settings found on this Mac."))
        }
        .confirmationDialog(
            "Import from VoiceInk?",
            isPresented: Binding(get: { voiceInkImport != nil }, set: { if !$0 { voiceInkImport = nil } })
        ) {
            if let config = voiceInkImport, config.hasSections {
                Button("Import") {
                    Task {
                        let result = await YapConfigLoader.shared.importSections(config)
                        voiceInkImportResult = result.skipped.isEmpty
                            ? String(format: String(localized: "Imported from VoiceInk: %@"), result.applied.joined(separator: ", "))
                            : String(format: String(localized: "Imported from VoiceInk: %@. Skipped: %@"),
                                     result.applied.joined(separator: ", "), result.skipped.joined(separator: ", "))
                    }
                }
            }
        } message: {
            if let summary = voiceInkImport.map(\.restoreSummary), voiceInkImport?.hasSections == true {
                Text(
                    String(
                        format: String(localized: "%lld modes, %lld prompts, %lld dictionary entries, %lld shortcuts and %lld custom models or providers (without their API keys). Entries with the same id replace Yap's; the rest of Yap's stay."),
                        summary.modes, summary.prompts, summary.dictionaryEntries, summary.shortcuts,
                        summary.customDefinitions))
            } else {
                Text("VoiceInk has no settings to import.")
            }
        }
        if let voiceInkImportResult {
            Text(voiceInkImportResult).settingsDescription()
        }
    }

    @ViewBuilder
    private var configFileStatus: some View {
        switch configLoader.status {
        case .notFound:
            Text("No config file").settingsDescription()
        case .loaded(let date, let applied, let skipped):
            VStack(alignment: .leading, spacing: AppTheme.Spacing.x1) {
                Text(
                    String(
                        format: String(localized: "Loaded at %@"),
                        date.formatted(date: .abbreviated, time: .shortened)
                    )
                )
                Text(
                    applied.isEmpty
                        ? String(localized: "No fields applied")
                        : String(format: String(localized: "Applied: %@"), applied.joined(separator: ", "))
                )
                .settingsDescription()
                if !skipped.isEmpty {
                    Text(String(format: String(localized: "Skipped: %@"), skipped.joined(separator: ", ")))
                        .settingsDescription()
                }
            }
        case .error(let message):
            Text(String(format: String(localized: "Could not read config file: %@"), message))
                .foregroundColor(AppTheme.Status.error)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
