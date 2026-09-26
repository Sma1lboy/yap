import SwiftData
import AppKit
import SwiftUI

struct OnboardingTrustScreen: View {
    let contentMaxWidth: CGFloat
    let onBack: () -> Void
    let onContinue: () -> Void

    var body: some View {
        OnboardingStepScreen(
            systemImage: "lock.shield",
            title: "Privacy Starts Here",
            subtitle: "Review how Yap handles your data before you start.",
            contentMaxWidth: max(contentMaxWidth, 720),
            showsHeader: false,
            contentYOffset: 0
        ) {
            OnboardingTrustContent()
        } bottomBar: {
            OnboardingBottomBar(
                leadingTitle: "Back",
                primaryTitle: "Start Using Yap",
                isPrimaryEnabled: true,
                onLeading: onBack,
                onPrimary: onContinue,
                isPrimaryDefaultAction: true,
                isLeadingCancelAction: true
            )
        }
    }
}

private struct OnboardingTrustContent: View {
    var body: some View {
        // Stacked, not overlaid: at the 750pt minimum height the centered body used to run into the header.
        // Scrolls when the window is short; the bottom padding clears the overlaid Back / Start bar.
        ScrollView {
            VStack(spacing: AppTheme.Spacing.x8) {
                TrustHeader()
                TrustBody()
            }
            .padding(.top, AppTheme.Spacing.x12)
            .padding(.bottom, 100)  // design-exempt: layout offset, not spacing
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.automatic)
        .padding(.horizontal, AppTheme.Spacing.x8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct TrustHeader: View {
    var body: some View {
        VStack(spacing: AppTheme.Spacing.x4) {
            Image(systemName: "lock.shield")
                .font(AppTheme.font(.title, .semibold))
                .foregroundColor(AppTheme.Text.primary)
                .frame(width: 56, height: 56)
                .background(
                    RoundedRectangle(cornerRadius: AppTheme.Radius.panel, style: .continuous)
                        .fill(AppTheme.Surface.controlActive)
                )

            Text("You choose where your voice goes")
                .font(AppTheme.font(.display, .semibold))
                .foregroundColor(AppTheme.Text.primary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct TrustBody: View {
    @Query(TrySayingCard.anyTranscription) private var existingTranscriptions: [Transcription]

    /// Only for someone who hasn't dictated yet (e.g. after "Set It Up Later"). The card takes the decorative
    /// map's place: squeezed smaller, the map draws past its frame into the headline and text.
    private var showsTrySaying: Bool { existingTranscriptions.isEmpty }
    @State private var showsPrivacyDetails = false

    var body: some View {
        VStack(spacing: 0) {
            if !showsTrySaying {
                TrustMapView()
                    .frame(height: 230)
                    .padding(.bottom, AppTheme.Spacing.x6)
            }

            VStack(spacing: AppTheme.Spacing.x3) {
                Text("Yap collects no usage data. Transcripts are stored only on this Mac.")
                    .font(AppTheme.font(.title3, .semibold))
                    .foregroundColor(AppTheme.Text.primary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 610)

                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { showsPrivacyDetails.toggle() }
                } label: {
                    HStack(spacing: AppTheme.Spacing.x1) {
                        Text("Privacy details")
                        Image(systemName: "chevron.down")
                            .rotationEffect(.degrees(showsPrivacyDetails ? 180 : 0))
                    }
                    .font(AppTheme.font(.footnote, .medium))
                    .foregroundColor(AppTheme.Text.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityValue(showsPrivacyDetails ? Text("Expanded") : Text("Collapsed"))

                if showsPrivacyDetails {
                    Text("Local models keep everything on this Mac. With your own API key, audio and text go only to the provider you choose. With Yap Cloud, they pass through Yap's server on the way to the model provider; the server records the model and cost for billing. If you turn on Sync via Yap Cloud, your modes, prompts, dictionary, shortcuts and custom models are stored there too, never your API keys.")
                        .font(AppTheme.font(.body))
                        .foregroundColor(AppTheme.Text.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 610)
                        .transition(.opacity)
                }

                Text("Yap picks a mode for the app you're in. Press Option 1-9 while recording to switch, and edit modes anytime.")
                    .font(AppTheme.font(.body))
                    .foregroundColor(AppTheme.Text.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 610)

                Text("Yap is also open source, so you can inspect every single line of code.")
                    .font(AppTheme.font(.body))
                    .foregroundColor(AppTheme.Text.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 610)
            }

            if showsTrySaying {
                TrySayingCard()
                    .padding(.top, AppTheme.Spacing.x5)
            }
        }
    }
}

private struct TrustMapView: View {
    var body: some View {
        ZStack {
            TrustConnectorLines()
                .stroke(
                    AppTheme.Border.control.opacity(0.58),
                    style: StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round)
                )
                .frame(width: 500, height: 210)
                .offset(y: 22)

            TrustPill(
                systemImage: "internaldrive.fill",
                title: "Local Storage"
            )
            .offset(y: -94)

            TrustPill(
                systemImage: "chevron.left.forwardslash.chevron.right",
                title: "Open Source"
            )
            .offset(x: -172, y: -12)

            TrustPill(
                systemImage: "slider.horizontal.3",
                title: "You Control It"
            )
            .offset(x: 172, y: -12)

            TrustShield()
                .offset(y: 76)
        }
    }
}

private struct TrustConnectorLines: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let centerX = rect.midX
        let topY = rect.minY + 18
        let branchY = rect.minY + 110
        let shieldY = rect.maxY - 34
        let leftX = rect.minX + 78
        let rightX = rect.maxX - 78

        path.move(to: CGPoint(x: centerX, y: topY))
        path.addLine(to: CGPoint(x: centerX, y: shieldY))

        path.move(to: CGPoint(x: leftX, y: branchY))
        path.addLine(to: CGPoint(x: leftX, y: shieldY - 5))
        path.addLine(to: CGPoint(x: centerX - 52, y: shieldY - 5))

        path.move(to: CGPoint(x: rightX, y: branchY))
        path.addLine(to: CGPoint(x: rightX, y: shieldY - 5))
        path.addLine(to: CGPoint(x: centerX + 52, y: shieldY - 5))

        return path
    }
}

private struct TrustPill: View {
    let systemImage: String
    let title: String

    var body: some View {
        HStack(spacing: AppTheme.Spacing.x2) {
            Image(systemName: systemImage)
                .font(AppTheme.font(.body, .semibold))
                .foregroundColor(AppTheme.Text.secondary)

            Text(LocalizedStringKey(title))
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

private struct TrustShield: View {
    var body: some View {
        ZStack {
            Image(systemName: "shield.fill")
                .font(AppTheme.font(.display, .regular))
                .foregroundStyle(
                    LinearGradient(
                        colors: [
                            AppTheme.Surface.control,
                            AppTheme.Surface.controlActive,
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .overlay(
                    Image(systemName: "shield")
                        .font(AppTheme.font(.display, .regular))
                        .foregroundColor(AppTheme.Border.control)
                )

            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: 52, height: 52)
        }
    }
}
