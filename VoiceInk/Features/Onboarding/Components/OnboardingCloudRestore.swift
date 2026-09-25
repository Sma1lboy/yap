import SwiftUI

/// First-screen entry for a new Mac: sign in to Yap Cloud and restore the settings synced from another Mac.
struct OnboardingCloudRestoreHint: View {
    let isRestored: Bool
    let onRestore: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            if isRestored {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(AppTheme.Status.positive)
                Text("Settings restored from Yap Cloud")
                    .font(.system(size: 11))
                    .foregroundColor(AppTheme.Text.secondary)
            } else {
                Text("Already have a Yap Cloud account?")
                    .font(.system(size: 11))
                    .foregroundColor(AppTheme.Text.secondary)
                Button("Sign In and Restore Settings", action: onRestore)
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(AppTheme.Accent.primary)
            }
        }
    }
}

/// Sign in → fetch the account's config → show what it contains → Restore applies it and turns sync on.
struct OnboardingCloudRestoreSheet: View {
    /// Called after a successful restore with whether the config covers the setup steps.
    let onRestored: (_ coversSetup: Bool) -> Void

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var cloud = YapCloud.shared

    private enum Phase {
        case signIn
        case loading
        /// Signed in, but no Mac has synced settings to this account yet.
        case empty
        case ready(YapConfig, any CloudConfigDocument)
        case failed(String)
    }

    @State private var phase: Phase = .signIn
    @State private var isRestoring = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Restore Settings from Yap Cloud")
                .font(.title3.weight(.semibold))

            switch phase {
            case .signIn:
                Text("Sign in with the account you use on your other Mac.")
                    .foregroundColor(AppTheme.Text.secondary)
                YapCloudSignInForm()
            case .loading:
                ProgressView()
                    .frame(maxWidth: .infinity)
            case .empty:
                Text("You're signed in. This account hasn't synced settings yet, so there's nothing to restore.")
                    .fixedSize(horizontal: false, vertical: true)
            case .ready(let config, _):
                summary(config.restoreSummary)
            case .failed(let message):
                Text(message)
                    .foregroundColor(AppTheme.Status.error)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                if case .empty = phase {
                    Button("Done") { dismiss() }
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Cancel") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                }
                if case .failed = phase {
                    Button("Retry") { Task { await load() } }
                }
                if case .ready(let config, let document) = phase {
                    Button("Restore") { Task { await restore(config, document) } }
                        .keyboardShortcut(.defaultAction)
                        .disabled(isRestoring)
                }
            }
        }
        .padding(24)
        .frame(width: 440)
        .task(id: cloud.isSignedIn) {
            if cloud.isSignedIn { await load() }
        }
    }

    private func summary(_ summary: YapConfig.RestoreSummary) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("This account has settings synced from another Mac:")
            Form {
                LabeledContent("Modes") { Text(verbatim: "\(summary.modes)") }
                LabeledContent("Prompts") { Text(verbatim: "\(summary.prompts)") }
                LabeledContent("Dictionary entries") { Text(verbatim: "\(summary.dictionaryEntries)") }
                LabeledContent("Shortcuts") { Text(verbatim: "\(summary.shortcuts)") }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .frame(height: 170)
            Text("Restoring applies these settings on this Mac and turns on Sync via Yap Cloud. API keys aren't synced; add them on this Mac if a provider needs one.")
                .font(.system(size: 11))
                .foregroundColor(AppTheme.Text.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func load() async {
        phase = .loading
        do {
            guard let document = try await CloudConfigSync.shared.fetchStored() else {
                phase = .empty
                return
            }
            phase = .ready(try YapConfig.decode(document.config), document)
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    private func restore(_ config: YapConfig, _ document: any CloudConfigDocument) async {
        isRestoring = true
        defer { isRestoring = false }
        do {
            try await CloudConfigSync.shared.restore(document)
            onRestored(config.coversOnboardingSetup)
            dismiss()
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }
}
