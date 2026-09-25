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
    let onRequestSkip: () -> Void
    let onConfirmSkip: () -> Void

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
                    onVerificationChanged: onVerificationChanged
                )
                OnboardingConfigFileHint()
            }
        } bottomBar: {
            OnboardingBottomBar(
                leadingTitle: "Back",
                primaryTitle: "Continue",
                isPrimaryEnabled: isSetupReady && !(setupKind == .local && isLocalDownloading),
                onLeading: onBack,
                onPrimary: onContinue,
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
    }
}
