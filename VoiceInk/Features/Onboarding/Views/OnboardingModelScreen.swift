import SwiftUI

struct OnboardingModelScreen: View {
    let contentMaxWidth: CGFloat
    let providerOptions: [any CloudProvider]
    @Binding var selectedProviderKey: String
    let isSetupReady: Bool
    @Binding var isShowingSkipWarning: Bool
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
                    providerOptions: providerOptions,
                    selectedProviderKey: $selectedProviderKey,
                    onVerificationChanged: onVerificationChanged
                )
                OnboardingConfigFileHint()
            }
        } bottomBar: {
            OnboardingBottomBar(
                leadingTitle: "Back",
                primaryTitle: "Continue",
                isPrimaryEnabled: isSetupReady,
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
