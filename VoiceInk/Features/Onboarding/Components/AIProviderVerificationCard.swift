import AppKit
import SwiftUI

struct AIProviderVerificationCard: View {
    @ObservedObject var aiService: AIService

    let providerOptions: [AIProvider]
    @Binding var selectedProvider: AIProvider
    let onVerificationChanged: () -> Void

    @State private var apiKey = ""
    @State private var isVerifying = false
    @State private var verificationMessage: String?
    @State private var verificationDetailMessage: String?
    @State private var verificationSucceeded = false
    @State private var isSwitchingProvider = false

    private var trimmedAPIKey: String {
        apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isSelectedProviderConnected: Bool {
        APIKeyManager.shared.hasAPIKey(forProvider: selectedProvider.rawValue)
    }

    private var shouldShowAPIKeyEntry: Bool {
        !isSelectedProviderConnected
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.x4) {
            providerSummary

            if shouldShowAPIKeyEntry {
                apiKeyField
                verificationFooter
            } else {
                verifiedProviderSummary
            }
        }
        .padding(AppTheme.Spacing.x4)
        .background(AppMaterialCardBackground(cornerRadius: AppTheme.Radius.control))
        .onAppear { refreshVerificationState() }
        .onReceive(NotificationCenter.default.publisher(for: .aiProviderKeyChanged)) { _ in
            refreshVerificationState()
        }
        .onChange(of: selectedProvider) { _, _ in
            handleProviderChange()
        }
        .onChange(of: apiKey) { _, _ in
            guard !apiKey.isEmpty else { return }
            verificationSucceeded = false
            verificationMessage = nil
            verificationDetailMessage = nil
        }
    }

    private var providerSummary: some View {
        HStack(alignment: .center, spacing: AppTheme.Spacing.x3) {
            ProviderBrandIcon(
                descriptor: providerDescriptor(for: selectedProvider),
                fallbackSystemImage: "sparkles",
                isSelected: true,
                size: 28,
                iconSize: 15
            )

            VStack(alignment: .leading, spacing: AppTheme.Spacing.half) {
                Text(selectedProvider.displayName)
                    .font(AppTheme.font(.body, .semibold))
                    .foregroundColor(AppTheme.Text.primary)
            }

            Spacer(minLength: 0)

            if providerOptions.count > 1 {
                Button {
                    isSwitchingProvider.toggle()
                } label: {
                    HStack(spacing: AppTheme.Spacing.x2) {
                        Text("Switch AI provider")
                        Image(systemName: isSwitchingProvider ? "chevron.up" : "chevron.down")
                            .font(AppTheme.font(.micro, .semibold))
                    }
                    .font(AppTheme.font(.caption, .semibold))
                    .foregroundColor(AppTheme.Text.secondary)
                    .padding(.horizontal, AppTheme.Spacing.x3)
                    .padding(.vertical, AppTheme.Spacing.x2)
                    .background(Capsule().fill(AppTheme.Surface.controlActive))
                }
                .buttonStyle(.plain)
                .popover(isPresented: $isSwitchingProvider, arrowEdge: .bottom) {
                    AIProviderSelectionCard(
                        providerOptions: providerOptions,
                        selectedProvider: $selectedProvider
                    )
                    .frame(width: 430)
                    .padding(AppTheme.Spacing.x3)
                }
            }
        }
    }

    private var apiKeyField: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.x2) {
            HStack(alignment: .center) {
                Text(String(format: String(localized: "%@ API Key"), selectedProvider.displayName))
                    .font(AppTheme.font(.footnote, .semibold))
                    .foregroundColor(AppTheme.Text.primary)

                Spacer()

                if let apiKeyURL {
                    Button {
                        NSWorkspace.shared.open(apiKeyURL)
                    } label: {
                        HStack(spacing: AppTheme.Spacing.x1) {
                            Text("Get API key")
                            Image(systemName: "arrow.up.right")
                                .font(AppTheme.font(.micro, .semibold))
                        }
                        .font(AppTheme.font(.caption, .semibold))
                        .foregroundColor(AppTheme.Text.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }

            SecureField(apiKeyPlaceholder, text: $apiKey)
                .textFieldStyle(.plain)
                .font(AppTheme.font(.body))
                .padding(.horizontal, AppTheme.Spacing.x3)
                .frame(height: 38)
                .background(
                    RoundedRectangle(cornerRadius: AppTheme.Radius.control, style: .continuous)
                        .fill(AppTheme.Surface.control)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: AppTheme.Radius.control, style: .continuous)
                        .stroke(AppTheme.Border.control.opacity(0.45), lineWidth: 1)
                )
        }
    }

    private var verificationFooter: some View {
        HStack(alignment: .center, spacing: AppTheme.Spacing.x3) {
            statusLine

            Spacer(minLength: 12)

            Button(action: verifyAPIKey) {
                HStack(spacing: AppTheme.Spacing.x2) {
                    if isVerifying {
                        ProgressView()
                            .controlSize(.small)
                    }

                    Text(isVerifying ? LocalizedStringKey("Testing...") : LocalizedStringKey("Test connection"))
                }
                .font(AppTheme.font(.footnote, .semibold))
                .foregroundColor(canVerify ? AppTheme.Action.primaryForeground : AppTheme.Action.disabledForeground)
                .padding(.horizontal, AppTheme.Spacing.x4)
                .padding(.vertical, AppTheme.Spacing.x2)
                .background(
                    Capsule()
                        .fill(canVerify ? AppTheme.Action.primaryFill : AppTheme.Action.disabledFill)
                )
            }
            .buttonStyle(.plain)
            .disabled(!canVerify)
        }
        .padding(.top, AppTheme.Spacing.half)
    }

    private var verifiedProviderSummary: some View {
        HStack(alignment: .center, spacing: AppTheme.Spacing.x3) {
            HStack(spacing: AppTheme.Spacing.x2) {
                Image(systemName: "checkmark.circle.fill")
                    .font(AppTheme.font(.callout, .semibold))
                    .foregroundColor(AppTheme.Status.positive)

                VStack(alignment: .leading, spacing: AppTheme.Spacing.half) {
                    Text("Connection verified.")
                        .font(AppTheme.font(.footnote, .semibold))
                        .foregroundColor(AppTheme.Text.primary)
                }
            }

            Spacer(minLength: 12)
        }
        .padding(.top, AppTheme.Spacing.half)
    }

    @ViewBuilder
    private var statusLine: some View {
        if let verificationMessage {
            HStack(alignment: .top, spacing: AppTheme.Spacing.x2) {
                Image(systemName: verificationSucceeded ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .font(AppTheme.font(.footnote, .semibold))
                    .foregroundColor(verificationSucceeded ? AppTheme.Status.positive : AppTheme.Status.error)
                    .padding(.top, AppTheme.Spacing.half)

                VStack(alignment: .leading, spacing: AppTheme.Spacing.x1) {
                    Text(verificationMessage)
                        .font(AppTheme.font(.footnote, .medium))
                        .foregroundColor(verificationSucceeded ? AppTheme.Text.secondary : AppTheme.Status.error)
                        .fixedSize(horizontal: false, vertical: true)

                    if let verificationDetailMessage, !verificationSucceeded {
                        Text(verificationDetailMessage)
                            .font(AppTheme.font(.caption))
                            .foregroundColor(AppTheme.Status.error.opacity(0.82))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        } else {
            Text("Test the connection to continue.")
                .font(AppTheme.font(.footnote))
                .foregroundColor(AppTheme.Text.secondary)
        }
    }

    private var canVerify: Bool {
        !trimmedAPIKey.isEmpty && !isVerifying
    }

    private var apiKeyPlaceholder: String {
        String(format: String(localized: "Paste %@ API key"), selectedProvider.rawValue)
    }

    private var apiKeyURL: URL? {
        selectedProvider.apiKeyURL
    }

    private func refreshVerificationState() {
        verificationSucceeded = isSelectedProviderConnected
        verificationMessage =
            verificationSucceeded
            ? String(format: String(localized: "%@ connection verified."), selectedProvider.rawValue)
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
        guard !key.isEmpty else { return }

        isVerifying = true
        verificationMessage = nil
        verificationDetailMessage = nil
        verificationSucceeded = false

        Task {
            let provider = selectedProvider
            let modelName = provider.defaultModel
            let result = await aiService.verifyAPIKey(key, for: provider, model: modelName)

            await MainActor.run {
                isVerifying = false

                guard selectedProvider == provider else {
                    refreshVerificationState()
                    onVerificationChanged()
                    return
                }

                verificationSucceeded = result.isValid

                if result.isValid {
                    guard APIKeyManager.shared.saveAPIKey(key, forProvider: provider.rawValue) else {
                        verificationSucceeded = false
                        verificationMessage = String(
                            localized: "The key worked, but Yap could not save it securely.")
                        verificationDetailMessage = nil
                        onVerificationChanged()
                        return
                    }

                    aiService.selectedProvider = provider
                    aiService.selectModel(modelName, for: provider)
                    aiService.apiKey = key
                    aiService.isAPIKeyValid = true
                    apiKey = ""
                    verificationMessage = String(
                        format: String(localized: "%@ connection verified."), provider.rawValue)
                    verificationDetailMessage = nil
                    NotificationCenter.default.post(name: .aiProviderKeyChanged, object: nil)
                } else {
                    verificationMessage = String(
                        localized: "Could not verify this API key. Check the key and your internet connection, then try again.")
                    verificationDetailMessage = result.errorMessage
                }

                onVerificationChanged()
            }
        }
    }
}

private struct AIProviderSelectionCard: View {
    let providerOptions: [AIProvider]
    @Binding var selectedProvider: AIProvider

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.x2) {
            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: AppTheme.Spacing.x2),
                    GridItem(.flexible(), spacing: AppTheme.Spacing.x2),
                ],
                alignment: .leading,
                spacing: AppTheme.Spacing.x2
            ) {
                ForEach(providerOptions, id: \.self) { provider in
                    ProviderChoiceButton(
                        provider: provider,
                        isSelected: selectedProvider == provider,
                        action: {
                            selectedProvider = provider
                        }
                    )
                }
            }
        }
        .padding(AppTheme.Spacing.x4)
        .background(ProviderSurface(cornerRadius: AppTheme.Radius.card))
    }
}

private struct ProviderChoiceButton: View {
    let provider: AIProvider
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: AppTheme.Spacing.x2) {
                ProviderBrandIcon(
                    descriptor: providerDescriptor(for: provider),
                    fallbackSystemImage: "sparkles",
                    isSelected: isSelected,
                    size: 28,
                    iconSize: 15
                )

                VStack(alignment: .leading, spacing: AppTheme.Spacing.x1) {
                    Text(provider.displayName)
                        .font(AppTheme.font(.footnote, .semibold))
                        .foregroundColor(AppTheme.Text.primary)
                        .lineLimit(1)

                }

                Spacer(minLength: 0)

                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(AppTheme.font(.body, .semibold))
                        .foregroundColor(AppTheme.Text.secondary)
                }
            }
            .padding(.horizontal, AppTheme.Spacing.x3)
            .frame(height: 54)
            .background(ProviderSurface(isActive: isSelected, cornerRadius: AppTheme.Radius.control))
            .contentShape(RoundedRectangle(cornerRadius: AppTheme.Radius.control, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(provider.rawValue)
    }

}


fileprivate func providerDescriptor(for provider: AIProvider) -> ProviderDescriptor {
    ProviderDescriptor(
        displayName: provider.rawValue,
        providerKey: provider.rawValue,
        aiProvider: provider,
        cloudProvider: nil
    )
}

fileprivate extension AIProvider {
    var apiKeyURL: URL? {
        switch self {
        case .groq:
            return URL(string: "https://console.groq.com/keys")
        case .openAI:
            return URL(string: "https://platform.openai.com/api-keys")
        case .gemini:
            return URL(string: "https://aistudio.google.com/app/apikey")
        case .anthropic:
            return URL(string: "https://console.anthropic.com/settings/keys")
        case .mistral:
            return URL(string: "https://console.mistral.ai/api-keys/")
        case .openRouter:
            return URL(string: "https://openrouter.ai/keys")
        case .cerebras:
            return URL(string: "https://cloud.cerebras.ai/platform")
        default:
            return nil
        }
    }
}
