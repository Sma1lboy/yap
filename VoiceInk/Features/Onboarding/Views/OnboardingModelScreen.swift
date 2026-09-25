import SwiftUI

struct OnboardingModelScreen: View {
    let contentMaxWidth: CGFloat
    let localModel: FluidAudioModel?
    let setupKind: OnboardingTranscriptionSetupKind
    let providerOptions: [any CloudProvider]
    @Binding var selectedProviderKey: String
    let isLocalDownloaded: Bool
    let isLocalDownloading: Bool
    let localDownloadStatus: FluidAudioDownloadStatus?
    let isSetupReady: Bool
    @Binding var isShowingSkipWarning: Bool
    let onSelectSetupKind: (OnboardingTranscriptionSetupKind) -> Void
    let onDownload: (FluidAudioModel) -> Void
    let onCancelDownload: (FluidAudioModel) -> Void
    let onVerificationChanged: () -> Void
    let onBack: () -> Void
    let onContinue: () -> Void
    /// Verifies/saves the key (nil = use the stored one) and applies the preset; returns an error to show.
    let onContinueRecommended: (String?) async -> String?
    let onRequestSkip: () -> Void
    let onConfirmSkip: () -> Void

    @State private var recommendedAPIKey = ""
    @State private var recommendedError: String?
    @State private var isApplyingRecommended = false

    private var trimmedRecommendedKey: String {
        recommendedAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isPrimaryEnabled: Bool {
        switch setupKind {
        case .recommended:
            return (isSetupReady || !trimmedRecommendedKey.isEmpty) && !isApplyingRecommended
        case .local:
            return isSetupReady && !isLocalDownloading
        case .cloud:
            return isSetupReady
        }
    }

    private func continueTapped() {
        guard setupKind == .recommended else { return onContinue() }
        let key = trimmedRecommendedKey
        isApplyingRecommended = true
        recommendedError = nil
        Task {
            let error = await onContinueRecommended(key.isEmpty ? nil : key)
            isApplyingRecommended = false
            recommendedError = error
            if error == nil { recommendedAPIKey = "" }
        }
    }

    var body: some View {
        OnboardingStepScreen(
            stage: .model,
            contentMaxWidth: contentMaxWidth
        ) {
            VStack(spacing: 14) {
                OnboardingTranscriptionSetupCard(
                    localModel: localModel,
                    setupKind: setupKind,
                    providerOptions: providerOptions,
                    selectedProviderKey: $selectedProviderKey,
                    isLocalDownloaded: isLocalDownloaded,
                    isLocalDownloading: isLocalDownloading,
                    localDownloadStatus: localDownloadStatus,
                    onSelectSetupKind: onSelectSetupKind,
                    onDownloadLocalModel: onDownload,
                    onCancelLocalModelDownload: onCancelDownload,
                    onVerificationChanged: onVerificationChanged,
                    recommendedAPIKey: $recommendedAPIKey,
                    recommendedError: recommendedError,
                    isApplyingRecommended: isApplyingRecommended
                )
                OnboardingConfigFileHint()
            }
        } bottomBar: {
            OnboardingBottomBar(
                leadingTitle: "Back",
                primaryTitle: "Continue",
                isPrimaryEnabled: isPrimaryEnabled,
                onLeading: onBack,
                onPrimary: continueTapped,
                secondaryTitle: isSetupReady ? nil : "Set It Up Later",
                onSecondary: onRequestSkip
            )
        }
        .alert("Set up transcription later?", isPresented: $isShowingSkipWarning) {
            Button("Go Back", role: .cancel) {}
            Button("Set It Up Later") {
                onConfirmSkip()
            }
        } message: {
            Text("Dictation won't work until you choose a transcription model. The practice steps will be skipped. You can set it up anytime in Settings or in ~/.config/yap/config.json.")
        }
        .onChange(of: recommendedAPIKey) { _, _ in recommendedError = nil }
    }
}
