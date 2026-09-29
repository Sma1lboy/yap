import SwiftUI

/// Settings → Account: sign in to Yap Cloud, and once signed in, who you are and the cross-Mac config sync.
struct AccountSettingsSection: View {
    @ObservedObject private var cloud = YapCloud.shared
    @ObservedObject private var cloudConfigSync = CloudConfigSync.shared
    @AppStorage(CloudConfigSync.enabledKey) private var syncConfigViaCloud = false
    @State private var isShowingVersionHistory = false
    @State private var isConfirmingSignOut = false

    var body: some View {
        Section {
            if cloud.isSignedIn {
                signedIn
            } else {
                Text("Sign in to keep your modes, prompts, dictionary, shortcuts and custom models the same on every Mac. API keys are never uploaded. Yap Cloud models are optional and pay-as-you-go.")
                    .settingsDescription()
                YapCloudSignInForm()
            }
        } header: {
            Text("Account")
        }
    }

    @ViewBuilder
    private var signedIn: some View {
        if let email = cloud.email ?? cloud.me?.email {
            LabeledContent("Signed in as") {
                Text(email).textSelection(.enabled)
            }
        }

        Toggle(isOn: $syncConfigViaCloud) {
            Text("Sync Settings Across Macs")
            Text("Stores your modes, prompts, dictionary, shortcuts and custom models on Yap's server, never your API keys, so every Mac signed in to your account uses the same config.")
        }
        // A stale "Synced at" or conflict banner is misleading (and its buttons no-op) once sync is off.
        if syncConfigViaCloud && cloudConfigSync.isAvailable {
            cloudSyncStatus
            HStack {
                Button("Sync Now") { Task { await cloudConfigSync.sync() } }
                if cloudConfigSync.supportsHistory {
                    Button("Version History…") { isShowingVersionHistory = true }
                        .sheet(isPresented: $isShowingVersionHistory) { ConfigVersionHistorySheet() }
                }
            }
        }

        HStack {
            Button("Manage Yap Cloud…") { MainWindowNavigation.shared.navigate(to: .account) }
            Button("Sign Out") { isConfirmingSignOut = true }
                .confirmationDialog("Sign out of Yap Cloud?", isPresented: $isConfirmingSignOut) {
                    Button("Sign Out", role: .destructive) { cloud.signOutWarningAboutModes() }
                } message: {
                    Text("Modes that use Yap Cloud stop working until you sign in again or switch them to another provider.")
                }
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
            VStack(alignment: .leading, spacing: AppTheme.Spacing.x2) {
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
            VStack(alignment: .leading, spacing: AppTheme.Spacing.x2) {
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

extension YapCloud {
    /// Names of the modes that would fail without a Yap Cloud sign-in (transcription or enhancement goes through it).
    static func modeNamesUsingYapCloud(_ modes: [ModeConfig]) -> [String] {
        modes.filter { mode in
            mode.selectedTranscriptionModelName?.hasPrefix("YapCloud:") == true
                || (mode.isAIEnhancementEnabled && mode.selectedAIProvider == AIProvider.yapCloud.rawValue)
        }.map(\.name)
    }

    /// After signing out or deleting the account: modes that still use Yap Cloud would fail, so name them and offer Modes.
    @MainActor
    static func warnAboutModesUsingYapCloud() {
        let names = modeNamesUsingYapCloud(ModeManager.shared.configurations)
        guard !names.isEmpty else { return }
        NotificationManager.shared.showNotification(
            title: String(
                format: String(localized: "Still using Yap Cloud: %@. Switch them to another provider in Modes."),
                names.joined(separator: ", ")),
            type: .warning,
            duration: 10,
            actionButton: (String(localized: "Manage Modes"), ModeSetupNavigator.openModesSettings)
        )
    }

    @MainActor
    func signOutWarningAboutModes() {
        signOut()
        Self.warnAboutModesUsingYapCloud()
    }

    #if DEBUG
        static func modeNamesSelfCheck() {
            func mode(_ name: String, transcription: String? = nil, enhanced: Bool = false, provider: String? = nil) -> ModeConfig {
                var m = ModeConfig(id: UUID(), name: name, isAIEnhancementEnabled: enhanced, selectedLanguage: "en")
                m.selectedTranscriptionModelName = transcription
                m.selectedAIProvider = provider
                return m
            }
            let modes = [
                mode("Local", transcription: "ggml-base"),
                mode("CloudASR", transcription: "YapCloud:microsoft/mai-transcribe-2"),
                mode("CloudLLM", enhanced: true, provider: AIProvider.yapCloud.rawValue),
                mode("OffLLM", enhanced: false, provider: AIProvider.yapCloud.rawValue),
            ]
            assert(modeNamesUsingYapCloud(modes) == ["CloudASR", "CloudLLM"], "modeNamesUsingYapCloud")
        }
    #endif
}
