import SwiftUI

/// Settings → Config & Sync → Version History…: the synced config's earlier versions, who wrote them, and how
/// each differs from the current one.
struct ConfigVersionHistorySheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var sync = CloudConfigSync.shared

    @State private var versions: [CloudConfigVersionInfo] = []
    @State private var current: YapConfig?
    @State private var currentVersion: String?
    @State private var selection: CloudConfigVersionInfo.ID?
    @State private var selectedConfig: YapConfig?
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var isConfirmingRestore = false
    @State private var isRestoring = false

    /// Every listed version is an earlier one; the current version isn't in the list.
    private var restorableVersion: String? { selection }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Version History")
                .font(.title3.weight(.semibold))
            Text("Every change synced through Yap Cloud is kept as a version.")
                .foregroundColor(AppTheme.Text.secondary)

            if isLoading {
                ProgressView().frame(maxWidth: .infinity, minHeight: 200)
            } else if versions.isEmpty {
                Text("No earlier versions yet.")
                    .foregroundColor(AppTheme.Text.secondary)
                    .frame(maxWidth: .infinity, minHeight: 200)
            } else {
                if let currentVersion {
                    Text(String(format: String(localized: "Current version: %@"), currentVersion))
                        .font(.subheadline)
                        .foregroundColor(AppTheme.Text.secondary)
                }
                List(versions, selection: $selection) { info in
                    row(info)
                }
                .frame(height: 220)
                comparison
            }

            if let errorMessage {
                Text(errorMessage)
                    .foregroundColor(AppTheme.Status.error)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                if isRestoring { ProgressView().controlSize(.small) }
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Restore This Version…") { isConfirmingRestore = true }
                    .disabled(restorableVersion == nil || selectedConfig == nil || isRestoring)
            }
        }
        .padding(24)
        .frame(width: 520)
        .task { await load() }
        .confirmationDialog("Restore this version?", isPresented: $isConfirmingRestore) {
            Button("Restore", role: .destructive) {
                Task { await restore() }
            }
        } message: {
            Text(
                "Settings on all your Macs change to this version. Modes, prompts, dictionary entries and custom models added since then are deleted. The current version stays in the history."
            )
        }
        .onChange(of: selection) { _, version in
            Task { await select(version) }
        }
    }

    private func row(_ info: CloudConfigVersionInfo) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(info.updatedAt?.formatted(date: .abbreviated, time: .shortened) ?? info.version)
                Text(info.deviceName ?? String(localized: "Unknown device"))
                    .font(.caption)
                    .foregroundColor(AppTheme.Text.secondary)
            }
            Spacer()
            Text(verbatim: "v\(info.version)")
                .font(.caption)
                .monospacedDigit()
                .foregroundColor(AppTheme.Text.secondary)
        }
    }

    @ViewBuilder
    private var comparison: some View {
        if let selectedConfig, let current {
            let then = selectedConfig.restoreSummary
            let now = current.restoreSummary
            VStack(alignment: .leading, spacing: 6) {
                Text("Compared with the current version")
                    .font(.subheadline.weight(.medium))
                countRow("Modes", then.modes, now.modes)
                countRow("Prompts", then.prompts, now.prompts)
                countRow("Dictionary entries", then.dictionaryEntries, now.dictionaryEntries)
            }
        } else if selection != nil {
            ProgressView().controlSize(.small)
        } else {
            Text("Select a version to compare it with the current one.")
                .foregroundColor(AppTheme.Text.secondary)
        }
    }

    /// "4 (−1)": the count in the selected version and how that differs from now.
    private func countRow(_ title: LocalizedStringKey, _ then: Int, _ now: Int) -> some View {
        LabeledContent(title) {
            Text(verbatim: then == now ? "\(then)" : "\(then) (\(then > now ? "+" : "−")\(abs(then - now)))")
                .monospacedDigit()
                .foregroundColor(then == now ? AppTheme.Text.secondary : AppTheme.Text.primary)
        }
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            (versions, current, currentVersion) = try await sync.loadHistory()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func restore() async {
        guard let version = restorableVersion else { return }
        isRestoring = true
        defer { isRestoring = false }
        do {
            try await sync.restoreVersion(version)
            dismiss()
        } catch is CloudConfigSync.ConflictError {
            errorMessage = String(localized: "Another Mac changed the settings in the meantime. Look at the history again, then restore.")
            await load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func select(_ version: String?) async {
        selectedConfig = nil
        guard let version else { return }
        do {
            let config = try await sync.config(atVersion: version)
            if selection == version { selectedConfig = config }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
