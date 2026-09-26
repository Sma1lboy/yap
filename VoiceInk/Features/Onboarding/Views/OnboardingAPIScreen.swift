import SwiftUI

struct OnboardingAPIScreen: View {
    @ObservedObject var aiService: AIService

    let contentMaxWidth: CGFloat
    let providerOptions: [AIProvider]
    @Binding var selectedProvider: AIProvider
    let isSelectedProviderVerified: Bool
    let canContinue: Bool
    @Binding var isShowingSkipWarning: Bool
    let onVerificationChanged: () -> Void
    let onBack: () -> Void
    let onContinue: () -> Void
    let onRequestSkip: () -> Void
    let onConfirmSkip: () -> Void

    var body: some View {
        OnboardingStepScreen(
            stage: .api,
            contentMaxWidth: contentMaxWidth
        ) {
            VStack(spacing: AppTheme.Spacing.x4) {
                AIProviderVerificationCard(
                    aiService: aiService,
                    providerOptions: providerOptions,
                    selectedProvider: $selectedProvider,
                    onVerificationChanged: onVerificationChanged
                )
                OnboardingConfigFileHint()
            }
        } bottomBar: {
            OnboardingBottomBar(
                leadingTitle: "Back",
                primaryTitle: "Continue",
                isPrimaryEnabled: canContinue && isSelectedProviderVerified,
                onLeading: onBack,
                onPrimary: onContinue,
                secondaryTitle: isSelectedProviderVerified ? nil : "Set It Up Later",
                onSecondary: onRequestSkip
            )
        }
        .alert("Set up AI enhancement later?", isPresented: $isShowingSkipWarning) {
            Button("Go Back", role: .cancel) {}
            Button("Set It Up Later") {
                onConfirmSkip()
            }
        } message: {
            Text("Enhancement modes and AI actions will stay off until you add a key. You can set this up anytime from Settings.")
        }
    }
}
