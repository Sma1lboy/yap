import SwiftUI

struct OnboardingContextAwarenessScreen: View {
    let contentMaxWidth: CGFloat
    let onBack: () -> Void
    let onContinue: () -> Void

    var body: some View {
        OnboardingStepScreen(
            systemImage: "sparkles.square.fill.on.square",
            title: "Yap is Context-Aware",
            subtitle: "Yap automatically understands what you are working with and selects your preferred setup.",
            contentMaxWidth: max(contentMaxWidth, 680),
            showsHeader: false,
            contentYOffset: 0
        ) {
            OnboardingContextAwarenessContent()
        } bottomBar: {
            OnboardingBottomBar(
                leadingTitle: "Back",
                primaryTitle: "Continue",
                isPrimaryEnabled: true,
                onLeading: onBack,
                onPrimary: onContinue,
                isPrimaryDefaultAction: true,
                isLeadingCancelAction: true
            )
        }
    }
}

private struct OnboardingContextAwarenessContent: View {
    var body: some View {
        ZStack {
            VStack(spacing: AppTheme.Spacing.x5) {
                Image(systemName: "sparkles.square.fill.on.square")
                    .font(AppTheme.font(.title, .semibold))
                    .foregroundColor(AppTheme.Text.primary)
                    .frame(width: 56, height: 56)
                    .background(
                        RoundedRectangle(cornerRadius: AppTheme.Radius.panel, style: .continuous)
                            .fill(AppTheme.Surface.controlActive)
                    )

                VStack(spacing: AppTheme.Spacing.x3) {
                    Text("Yap is context-aware.")
                        .font(AppTheme.font(.display, .semibold))
                        .foregroundColor(AppTheme.Text.primary)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)

                    Text(
                        "Yap automatically understands what you are working with and selects your preferred setup. You can always configure this by editing or creating new modes."
                    )
                    .font(AppTheme.font(.headline))
                    .foregroundColor(AppTheme.Text.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 620)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.top, 52)  // design-exempt: layout offset, not spacing

            ContextAwarenessCenterSlot()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                .offset(y: 50)

            optionSwitchingText
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                .offset(y: 226)
        }
        .padding(.horizontal, AppTheme.Spacing.x8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var optionSwitchingText: some View {
        Text("Note: Press Option 1-9 during recording to switch modes manually.")
            .font(AppTheme.font(.body, .medium))
            .foregroundColor(AppTheme.Text.secondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct ContextAwarenessCenterSlot: View {
    var body: some View {
        ContextAwarenessModeVisual()
            .frame(maxWidth: 560)
            .frame(height: 250)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(
                "Yap modes include Dictation, Enhance, Email, Assistant, Rewrite, Ask, Summarize, and Translate.")
    }
}

private struct ContextAwarenessModeVisual: View {
    private let modes: [ContextAwarenessModePill.Model] = [
        ContextAwarenessModePill.Model(systemImage: "mic.fill", title: "Dictation", angle: -90),
        ContextAwarenessModePill.Model(systemImage: "sparkles", title: "Enhance", angle: -45),
        ContextAwarenessModePill.Model(systemImage: "envelope.fill", title: "Email", angle: 0),
        ContextAwarenessModePill.Model(systemImage: "bubble.left.and.bubble.right.fill", title: "Ask", angle: 45),
        ContextAwarenessModePill.Model(systemImage: "globe", title: "Translate", angle: 90),
        ContextAwarenessModePill.Model(systemImage: "text.alignleft", title: "Summarize", angle: 135),
        ContextAwarenessModePill.Model(systemImage: "quote.bubble.fill", title: "Rewrite", angle: 180),
        ContextAwarenessModePill.Model(systemImage: "wand.and.stars", title: "Assistant", angle: -135),
    ]

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                ForEach(modes) { mode in
                    ContextAwarenessModePill(model: mode)
                        .position(position(for: mode, in: proxy.size))
                }

                ContextAwarenessModeHub()
                    .position(x: proxy.size.width * 0.5, y: proxy.size.height * 0.5)
            }
        }
    }

    private func position(for mode: ContextAwarenessModePill.Model, in size: CGSize) -> CGPoint {
        let radians = mode.angle * .pi / 180
        let xRadius = min(size.width * 0.34, 190)
        let yRadius = min(size.height * 0.40, 102)

        return CGPoint(
            x: size.width * 0.5 + CGFloat(cos(radians)) * xRadius,
            y: size.height * 0.5 + CGFloat(sin(radians)) * yRadius
        )
    }
}

private struct ContextAwarenessModePill: View {
    struct Model: Identifiable {
        let systemImage: String
        let title: String
        let angle: Double

        var id: String { title }
    }

    let model: Model

    var body: some View {
        HStack(spacing: AppTheme.Spacing.x2) {
            Image(systemName: model.systemImage)
                .font(AppTheme.font(.body, .semibold))
                .foregroundColor(AppTheme.Text.secondary)

            Text(LocalizedStringKey(model.title))
                .font(AppTheme.font(.body, .semibold))
                .foregroundColor(AppTheme.Text.primary)
                .lineLimit(1)
        }
        .padding(.horizontal, AppTheme.Spacing.x4)
        .frame(height: 42)
        .background(
            Capsule()
                .fill(AppTheme.Surface.control.opacity(0.84))
        )
        .overlay(
            Capsule()
                .stroke(AppTheme.Border.subtle, lineWidth: 1)
        )
    }
}

private struct ContextAwarenessModeHub: View {
    var body: some View {
        HStack(spacing: AppTheme.Spacing.x2) {
            Image(systemName: "sparkles.square.fill.on.square")
                .font(AppTheme.font(.callout, .semibold))
                .foregroundColor(AppTheme.Text.secondary)
                .frame(width: 18)

            Text("Yap Modes")
                .font(AppTheme.font(.callout, .semibold))
                .foregroundColor(AppTheme.Text.primary)
                .lineLimit(1)
        }
        .padding(.horizontal, AppTheme.Spacing.x5)
        .frame(height: 46)
        .background(
            Capsule()
                .fill(AppTheme.Surface.control.opacity(0.92))
        )
        .overlay(
            Capsule()
                .stroke(AppTheme.Border.card, lineWidth: 1)
        )
    }
}
