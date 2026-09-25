import AppKit
import SwiftUI

struct OnboardingTranscriptionSetupCard: View {
    let localModel: FluidAudioModel?
    let setupKind: OnboardingTranscriptionSetupKind
    let providerOptions: [any CloudProvider]
    @Binding var selectedProviderKey: String
    let isLocalDownloaded: Bool
    let isLocalDownloading: Bool
    let localDownloadStatus: FluidAudioDownloadStatus?
    let localDownloadError: String?
    let onSelectSetupKind: (OnboardingTranscriptionSetupKind) -> Void
    let onDownloadLocalModel: (FluidAudioModel) -> Void
    let onCancelLocalModelDownload: (FluidAudioModel) -> Void
    let onVerificationChanged: () -> Void
    /// Recommended setup: key draft, the last error, and whether Continue is verifying/applying.
    @Binding var recommendedAPIKey: String
    let recommendedError: String?
    let isApplyingRecommended: Bool

    @EnvironmentObject private var transcriptionModelManager: TranscriptionModelManager
    @ObservedObject private var yapCloud = YapCloud.shared
    @State private var apiKey = ""
    @State private var isVerifying = false
    @State private var verificationMessage: String?
    @State private var verificationDetailMessage: String?
    @State private var verificationSucceeded = false
    @State private var isSwitchingProvider = false
    @State private var isLoadingOpenRouterModels = false

    private var selectedProvider: (any CloudProvider)? {
        providerOptions.first {
            $0.providerKey.caseInsensitiveCompare(selectedProviderKey) == .orderedSame
        } ?? providerOptions.first
    }

    private var trimmedAPIKey: String {
        apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isSelectedProviderConnected: Bool {
        guard let selectedProvider else { return false }
        return APIKeyManager.shared.hasAPIKey(forProvider: selectedProvider.providerKey)
    }

    private var canVerify: Bool {
        !trimmedAPIKey.isEmpty && !isVerifying
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            setupSwitcher

            switch setupKind {
            case .recommended:
                recommendedSetup
            case .yapCloud:
                yapCloudSetup
            case .local:
                localSetup
            case .cloud:
                cloudSetup
            }
        }
        .onAppear {
            if selectedProviderKey.isEmpty, let selectedProvider {
                selectedProviderKey = selectedProvider.providerKey
            }
            refreshVerificationState()
        }
        .onReceive(NotificationCenter.default.publisher(for: .aiProviderKeyChanged)) { _ in
            refreshVerificationState()
        }
        .onChange(of: selectedProviderKey) { _, _ in
            handleProviderChange()
        }
        .onChange(of: apiKey) { _, _ in
            guard !apiKey.isEmpty else { return }
            verificationSucceeded = false
            verificationMessage = nil
            verificationDetailMessage = nil
        }
        .task(id: "\(setupKind.rawValue):\(selectedProviderKey)") {
            await loadOpenRouterModelsIfNeeded()
        }
    }

    private var setupSwitcher: some View {
        HStack(spacing: 8) {
            setupChoice(.recommended, systemImage: "sparkles")
            setupChoice(.yapCloud, systemImage: "creditcard")
            setupChoice(.cloud, systemImage: "cloud.fill")
            setupChoice(.local, systemImage: "macbook")
        }
        .padding(4)
        .background(AppMaterialCardBackground(cornerRadius: 12))
    }

    private func setupChoice(_ kind: OnboardingTranscriptionSetupKind, systemImage: String) -> some View {
        let isSelected = setupKind == kind

        return Button {
            onSelectSetupKind(kind)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.system(size: 12, weight: .semibold))

                Text(kind.title)
                    .font(.system(size: 12, weight: .semibold))
            }
            .foregroundColor(isSelected ? AppTheme.Text.primary : AppTheme.Text.secondary)
            .frame(maxWidth: .infinity)
            .frame(height: 36)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(isSelected ? AppTheme.Surface.controlActive : AppTheme.Surface.clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var hasStoredOpenRouterKey: Bool {
        APIKeyManager.shared.hasAPIKey(forProvider: AIProvider.openRouter.rawValue)
    }

    private var recommendedSetup: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("OpenRouter · MAI-Transcribe-2 → DeepSeek V4.1 Flash · Chinese–English enhancement · about $0.13 per hour of speech")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(AppTheme.Text.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if hasStoredOpenRouterKey && recommendedAPIKey.isEmpty && recommendedError == nil {
                HStack(alignment: .center, spacing: 9) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(AppTheme.Status.positive)
                    Text("OpenRouter key found. Continue to use it.")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(AppTheme.Text.primary)
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .center) {
                        Text(String(format: String(localized: "%@ API Key"), AIProvider.openRouter.rawValue))
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(AppTheme.Text.primary)
                        Spacer()
                        Button {
                            NSWorkspace.shared.open(RecommendedSetup.apiKeyURL)
                        } label: {
                            HStack(spacing: 4) {
                                Text("Get API key")
                                Image(systemName: "arrow.up.right")
                                    .font(.system(size: 9, weight: .semibold))
                            }
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(AppTheme.Text.secondary)
                        }
                        .buttonStyle(.plain)
                    }

                    keyField(
                        String(format: String(localized: "Paste %@ API key"), AIProvider.openRouter.rawValue),
                        text: $recommendedAPIKey
                    )
                    .disabled(isApplyingRecommended)
                }

                recommendedStatusLine
            }
        }
        .padding(16)
        .background(AppMaterialCardBackground(cornerRadius: 12))
    }

    private var yapCloudSetup: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Use Yap Cloud (pay as you go)")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(AppTheme.Text.primary)
                Text("Same models as Recommended, no API key: sign in with your email and top up a balance. Each dictation is charged at cost plus a small markup.")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(AppTheme.Text.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if yapCloud.isSignedIn {
                HStack(alignment: .center, spacing: 9) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(AppTheme.Status.positive)
                    Text(yapCloudSignedInLine)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(AppTheme.Text.primary)
                }
                if let balance = yapCloud.balanceMicros, balance <= 0 {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Add funds to start dictating. Your balance updates when you come back to Yap.")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(AppTheme.Status.warningStrong)
                            .fixedSize(horizontal: false, vertical: true)
                        YapCloudQuickTopUp()
                    }
                }
                if YapCloudProvider().models.isEmpty {
                    HStack(spacing: 8) {
                        Text("Yap Cloud has no transcription models available right now.")
                        Button("Retry") { Task { await yapCloud.refreshModels() } }
                    }
                    .font(.system(size: 12))
                    .foregroundColor(AppTheme.Text.secondary)
                }
            } else {
                YapCloudSignInForm()
            }

            if let recommendedError {
                Text(recommendedError)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(AppTheme.Status.error)
            }
        }
        .padding(16)
        .background(AppMaterialCardBackground(cornerRadius: 12))
        .task(id: yapCloud.isSignedIn) {
            await yapCloud.refreshModels()
            await yapCloud.refreshAccount()
        }
        .onChange(of: yapCloud.balanceMicros) { _, _ in onVerificationChanged() }
    }

    /// "Signed in as a@b.c · Balance $4.20"; no email/balance yet → just the part that is known.
    private var yapCloudSignedInLine: String {
        let email = yapCloud.me?.email ?? yapCloud.email
        let who = email.map { String(format: String(localized: "Signed in as %@"), $0) }
            ?? String(localized: "Signed in to Yap Cloud")
        guard let balance = yapCloud.balanceMicros else { return who }
        return who + " · " + String(format: String(localized: "Balance %@"), YapCloud.formatUSD(micros: balance))
    }

    @ViewBuilder
    private var recommendedStatusLine: some View {
        if isApplyingRecommended {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Checking the key and applying the setup…")
            }
            .font(.system(size: 12))
            .foregroundColor(AppTheme.Text.secondary)
        } else if let recommendedError {
            HStack(alignment: .top, spacing: 7) {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.top, 1)
                Text(recommendedError)
                    .font(.system(size: 12, weight: .medium))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundColor(AppTheme.Status.error)
        } else {
            Text("Continue checks the key, then sets up transcription and enhancement with it.")
                .font(.system(size: 12))
                .foregroundColor(AppTheme.Text.secondary)
        }
    }

    private func keyField(_ placeholder: String, text: Binding<String>) -> some View {
        SecureField(placeholder, text: text)
            .textFieldStyle(.plain)
            .font(.system(size: 13))
            .padding(.horizontal, 12)
            .frame(height: 38)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(AppTheme.Surface.control)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(AppTheme.Border.control.opacity(0.45), lineWidth: 1)
            )
    }

    @ViewBuilder
    private var localSetup: some View {
        if let localModel {
            TranscriptionModelDownloadCard(
                model: localModel,
                isDownloaded: isLocalDownloaded,
                isDownloading: isLocalDownloading,
                status: localDownloadStatus,
                errorMessage: localDownloadError,
                onDownload: {
                    onDownloadLocalModel(localModel)
                },
                onCancel: {
                    onCancelLocalModelDownload(localModel)
                }
            )
        } else {
            missingModelPanel
        }
    }

    private var missingModelPanel: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(AppTheme.Status.error)

            Text("Parakeet V3 is not available.")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(AppTheme.Text.secondary)

            Spacer(minLength: 0)
        }
        .padding(16)
        .background(AppMaterialCardBackground(cornerRadius: 12))
    }

    private var cloudSetup: some View {
        VStack(alignment: .leading, spacing: 14) {
            providerSummary

            if isSelectedProviderConnected {
                verifiedProviderSummary
                if selectedProvider?.modelProvider == .openRouter,
                    selectedProvider?.models.isEmpty == true
                {
                    HStack(spacing: 8) {
                        if isLoadingOpenRouterModels {
                            ProgressView()
                                .controlSize(.small)
                            Text("Refreshing")
                        } else {
                            Text("No models loaded.")
                            Button("Refresh") {
                                Task { await loadOpenRouterModelsIfNeeded() }
                            }
                            .buttonStyle(.link)
                        }
                    }
                    .font(.system(size: 12))
                    .foregroundColor(AppTheme.Text.secondary)
                }
            } else {
                apiKeyField
                verificationFooter
            }
        }
        .padding(16)
        .background(AppMaterialCardBackground(cornerRadius: 12))
    }

    private var providerSummary: some View {
        HStack(alignment: .center, spacing: 10) {
            if let selectedProvider {
                ProviderBrandIcon(
                    descriptor: descriptor(for: selectedProvider),
                    fallbackSystemImage: "captions.bubble.fill",
                    isSelected: true,
                    size: 28,
                    iconSize: 15
                )

                VStack(alignment: .leading, spacing: 2) {
                    Text(selectedProvider.providerKey)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(AppTheme.Text.primary)
                }
            }

            Spacer(minLength: 0)

            if providerOptions.count > 1 {
                Button {
                    isSwitchingProvider.toggle()
                } label: {
                    HStack(spacing: 6) {
                        Text("Switch provider")
                        Image(systemName: isSwitchingProvider ? "chevron.up" : "chevron.down")
                            .font(.system(size: 9, weight: .bold))
                    }
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(AppTheme.Text.secondary)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 7)
                    .background(Capsule().fill(AppTheme.Surface.controlActive))
                }
                .buttonStyle(.plain)
                .popover(isPresented: $isSwitchingProvider, arrowEdge: .bottom) {
                    TranscriptionProviderSelectionCard(
                        providerOptions: providerOptions,
                        selectedProviderKey: $selectedProviderKey
                    )
                    .frame(width: 430)
                    .padding(10)
                }
            }
        }
    }

    private var apiKeyField: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center) {
                Text(apiKeyLabel)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(AppTheme.Text.primary)

                Spacer()

                if let apiKeyURL {
                    Button {
                        NSWorkspace.shared.open(apiKeyURL)
                    } label: {
                        HStack(spacing: 4) {
                            Text("Get API key")
                            Image(systemName: "arrow.up.right")
                                .font(.system(size: 9, weight: .semibold))
                        }
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(AppTheme.Text.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }

            keyField(apiKeyPlaceholder, text: $apiKey)
        }
    }

    private var verificationFooter: some View {
        HStack(alignment: .center, spacing: 12) {
            statusLine

            Spacer(minLength: 12)

            Button(action: verifyAPIKey) {
                HStack(spacing: 6) {
                    if isVerifying {
                        ProgressView()
                            .controlSize(.small)
                    }

                    Text(isVerifying ? LocalizedStringKey("Testing...") : LocalizedStringKey("Test connection"))
                }
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(canVerify ? AppTheme.Action.primaryForeground : AppTheme.Action.disabledForeground)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(
                    Capsule()
                        .fill(canVerify ? AppTheme.Action.primaryFill : AppTheme.Action.disabledFill)
                )
            }
            .buttonStyle(.plain)
            .disabled(!canVerify)
        }
        .padding(.top, 2)
    }

    private var verifiedProviderSummary: some View {
        HStack(alignment: .center, spacing: 9) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(AppTheme.Status.positive)

            Text("Connection verified.")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(AppTheme.Text.primary)

            Spacer(minLength: 0)
        }
        .padding(.top, 2)
    }

    @ViewBuilder
    private var statusLine: some View {
        if let verificationMessage {
            HStack(alignment: .top, spacing: 7) {
                Image(systemName: verificationSucceeded ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(verificationSucceeded ? AppTheme.Status.positive : AppTheme.Status.error)
                    .padding(.top, 1)

                VStack(alignment: .leading, spacing: 3) {
                    Text(verificationMessage)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(verificationSucceeded ? AppTheme.Text.secondary : AppTheme.Status.error)
                        .fixedSize(horizontal: false, vertical: true)

                    if let verificationDetailMessage, !verificationSucceeded {
                        Text(verificationDetailMessage)
                            .font(.system(size: 11))
                            .foregroundColor(AppTheme.Status.error.opacity(0.82))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        } else {
            Text("Test the connection to continue.")
                .font(.system(size: 12))
                .foregroundColor(AppTheme.Text.secondary)
        }
    }

    private var apiKeyLabel: String {
        guard let selectedProvider else { return String(localized: "API Key") }
        return String(format: String(localized: "%@ API Key"), selectedProvider.providerKey)
    }

    private var apiKeyPlaceholder: String {
        guard let selectedProvider else { return String(localized: "Paste API key") }
        return String(format: String(localized: "Paste %@ API key"), selectedProvider.providerKey)
    }

    private var apiKeyURL: URL? {
        guard let selectedProvider else { return nil }
        return descriptor(for: selectedProvider).apiConsoleURL
    }

    private func refreshVerificationState() {
        verificationSucceeded = isSelectedProviderConnected
        verificationMessage =
            verificationSucceeded
            ? selectedProvider.map {
                String(format: String(localized: "%@ connection verified."), $0.providerKey)
            }
            : nil
        verificationDetailMessage = nil

        if verificationSucceeded {
            apiKey = ""
        }
    }

    private func handleProviderChange() {
        apiKey = ""
        isVerifying = false
        isSwitchingProvider = false
        refreshVerificationState()
        onVerificationChanged()
    }

    private func verifyAPIKey() {
        let key = trimmedAPIKey
        guard let selectedProvider, !key.isEmpty else { return }

        isVerifying = true
        verificationMessage = nil
        verificationDetailMessage = nil
        verificationSucceeded = false
        let providerKey = selectedProvider.providerKey

        Task {
            let result = await selectedProvider.verifyAPIKey(key)

            await MainActor.run {
                isVerifying = false

                guard self.selectedProvider?.providerKey == providerKey else {
                    refreshVerificationState()
                    onVerificationChanged()
                    return
                }

                verificationSucceeded = result.isValid

                if result.isValid {
                    guard APIKeyManager.shared.saveAPIKey(key, forProvider: providerKey) else {
                        verificationSucceeded = false
                        verificationMessage = String(
                            localized: "The key worked, but Yap could not save it securely.")
                        verificationDetailMessage = nil
                        onVerificationChanged()
                        return
                    }

                    transcriptionModelManager.refreshAllAvailableModels()
                    apiKey = ""
                    verificationMessage = String(format: String(localized: "%@ connection verified."), providerKey)
                    verificationDetailMessage = nil
                    NotificationCenter.default.post(name: .aiProviderKeyChanged, object: nil)
                    Task { await loadOpenRouterModelsIfNeeded() }
                } else {
                    verificationMessage = String(
                        localized: "Could not verify this API key. Check the key and your internet connection, then try again.")
                    verificationDetailMessage = result.errorMessage
                }

                onVerificationChanged()
            }
        }
    }

    private func loadOpenRouterModelsIfNeeded() async {
        guard setupKind == .cloud,
            selectedProvider?.modelProvider == .openRouter,
            selectedProvider?.models.isEmpty == true,
            isSelectedProviderConnected,
            !isLoadingOpenRouterModels
        else { return }

        isLoadingOpenRouterModels = true
        await transcriptionModelManager.refreshOpenRouterCatalog()
        isLoadingOpenRouterModels = false
        onVerificationChanged()
    }

    private func descriptor(for provider: any CloudProvider) -> ProviderDescriptor {
        ProviderDescriptor(
            displayName: provider.providerKey,
            providerKey: provider.providerKey,
            aiProvider: nil,
            cloudProvider: provider
        )
    }
}

private struct TranscriptionProviderSelectionCard: View {
    let providerOptions: [any CloudProvider]
    @Binding var selectedProviderKey: String

    var body: some View {
        LazyVGrid(
            columns: [
                GridItem(.flexible(), spacing: 8),
                GridItem(.flexible(), spacing: 8),
            ],
            alignment: .leading,
            spacing: 8
        ) {
            ForEach(providerOptions.map { $0.providerKey }, id: \.self) { providerKey in
                if let provider = providerOptions.first(where: {
                    $0.providerKey.caseInsensitiveCompare(providerKey) == .orderedSame
                }) {
                    TranscriptionProviderChoiceButton(
                        provider: provider,
                        isSelected: selectedProviderKey.caseInsensitiveCompare(provider.providerKey) == .orderedSame,
                        action: {
                            selectedProviderKey = provider.providerKey
                        }
                    )
                }
            }
        }
        .padding(16)
        .background(ProviderSurface(cornerRadius: 12))
    }
}

private struct TranscriptionProviderChoiceButton: View {
    let provider: any CloudProvider
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                ProviderBrandIcon(
                    descriptor: descriptor,
                    fallbackSystemImage: "captions.bubble.fill",
                    isSelected: isSelected,
                    size: 28,
                    iconSize: 15
                )

                VStack(alignment: .leading, spacing: 4) {
                    Text(provider.providerKey)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(AppTheme.Text.primary)
                        .lineLimit(1)

                }

                Spacer(minLength: 0)

                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(AppTheme.Text.secondary)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 54)
            .background(ProviderSurface(isActive: isSelected, cornerRadius: 10))
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(provider.providerKey)
    }

    private var descriptor: ProviderDescriptor {
        ProviderDescriptor(
            displayName: provider.providerKey,
            providerKey: provider.providerKey,
            aiProvider: nil,
            cloudProvider: provider
        )
    }
}


#if DEBUG
    private struct OnboardingTranscriptionSetupCardPreview: View {
        let setupKind: OnboardingTranscriptionSetupKind
        @State private var providerKey = "AssemblyAI"
        @State private var recommendedKey = ""

        var body: some View {
            OnboardingTranscriptionSetupCard(
                localModel: nil, setupKind: setupKind, providerOptions: CloudProviderRegistry.allProviders,
                selectedProviderKey: $providerKey, isLocalDownloaded: false, isLocalDownloading: false,
                localDownloadStatus: nil, localDownloadError: nil, onSelectSetupKind: { _ in }, onDownloadLocalModel: { _ in },
                onCancelLocalModelDownload: { _ in }, onVerificationChanged: {},
                recommendedAPIKey: $recommendedKey, recommendedError: nil, isApplyingRecommended: false
            )
            .environmentObject(
                TranscriptionModelManager(
                    whisperModelManager: WhisperModelManager(modelsDirectory: FileManager.default.temporaryDirectory),
                    fluidAudioModelManager: FluidAudioModelManager()))
            .frame(width: 560)
            .padding()
        }
    }

    #Preview("Recommended") {
        OnboardingTranscriptionSetupCardPreview(setupKind: .recommended)
    }

    #Preview("Custom cloud") {
        OnboardingTranscriptionSetupCardPreview(setupKind: .cloud)
    }
#endif
