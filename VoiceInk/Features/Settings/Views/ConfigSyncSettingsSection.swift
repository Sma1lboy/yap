import SwiftUI

/// Settings → Config & Sync: config.json (path, status, write-back) and Yap Cloud sync.
struct ConfigSyncSettingsSection: View {
    @ObservedObject private var configLoader = YapConfigLoader.shared
    @ObservedObject private var cloudConfigSync = CloudConfigSync.shared
    @AppStorage(YapConfigLoader.keepInSyncKey) private var keepConfigFileInSync = false
    @AppStorage(CloudConfigSync.enabledKey) private var syncConfigViaCloud = false
    @State private var isShowingVersionHistory = false

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

            Toggle(isOn: $syncConfigViaCloud) {
                Text("Sync via Yap Cloud")
                Text(
                    cloudConfigSync.isAvailable
                        ? String(localized: "Keeps this config the same on every Mac signed in to your account.")
                        : String(localized: "Sign in to Yap Cloud to sync this config between Macs."))
            }
            .disabled(!cloudConfigSync.isAvailable)
            // A stale "Synced at" or conflict banner is misleading (and its buttons no-op) once sync is off.
            if syncConfigViaCloud && cloudConfigSync.isAvailable {
                cloudSyncStatus
                if cloudConfigSync.supportsHistory {
                    Button("Version History…") { isShowingVersionHistory = true }
                        .sheet(isPresented: $isShowingVersionHistory) { ConfigVersionHistorySheet() }
                }
            }
        } header: {
            Text("Config & Sync")
        } footer: {
            Text("Fields set in this file are applied at launch and override the same settings changed in the app.")
        }
    }

    @ViewBuilder
    private var configFileStatus: some View {
        switch configLoader.status {
        case .notFound:
            Text("No config file").settingsDescription()
        case .loaded(let date, let applied, let skipped):
            VStack(alignment: .leading, spacing: 4) {
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

    @ViewBuilder
    private var cloudSyncStatus: some View {
        switch cloudConfigSync.status {
        case .idle:
            EmptyView()
        case .synced(let date):
            Text(String(format: String(localized: "Synced at %@"), date.formatted(date: .abbreviated, time: .shortened)))
                .settingsDescription()
        case .conflict:
            VStack(alignment: .leading, spacing: 6) {
                Text("This Mac and Yap Cloud both changed the config and couldn't be merged automatically.")
                    .foregroundColor(AppTheme.Status.warningStrong)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Use Cloud Version") {
                        Task { await cloudConfigSync.resolveConflict(keepLocal: false) }
                    }
                    Button("Keep This Mac's Settings") {
                        Task { await cloudConfigSync.resolveConflict(keepLocal: true) }
                    }
                }
            }
        case .error(let message):
            VStack(alignment: .leading, spacing: 6) {
                Text(String(format: String(localized: "Cloud sync failed: %@"), message))
                    .foregroundColor(AppTheme.Status.error)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Retry") {
                    Task { await cloudConfigSync.sync() }
                }
            }
        }
    }
}
