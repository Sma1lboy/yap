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
            Image(yapIcon: "lock.shield")
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

struct TrustBody: View {
    @Query(TrySayingCard.anyTranscription) private var existingTranscriptions: [Transcription]

    /// Only for someone who hasn't dictated yet (e.g. after "Set It Up Later"). The card takes the decorative
    /// map's place: squeezed smaller, the map draws past its frame into the headline and text.
    private var showsTrySaying: Bool { existingTranscriptions.isEmpty }
    @State private var showsPrivacyDetails = false

    static func meetingLine(shortcut: Shortcut?) -> String {
        if let shortcut {
            return String(localized: "Yap can also record meetings: press \(shortcut.displayString) to start, then click ✓ in its panel to stop.")
        }
        return String(localized: "Yap can also record meetings. Set a shortcut for it in Settings.")
    }

    #if DEBUG
        static func selfCheck() {
            // Points to the Settings page by the name the sidebar shows, in whatever language the app runs in.
            assert(meetingLine(shortcut: nil).contains(String(localized: "Settings")))
            assert(meetingLine(shortcut: .rightCommandSpace).contains(Shortcut.rightCommandSpace.displayString))
        }
    #endif

    var body: some View {
        VStack(spacing: 0) {
            if !showsTrySaying {
                TrustMapView()
                    .frame(height: 230)
                    .padding(.bottom, AppTheme.Spacing.x6)
            }

            VStack(spacing: AppTheme.Spacing.x3) {
                Text("Yap saves history on this Mac. Cloud processing sends audio or text to your chosen services.", tableName: "PrivacyCopy")
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
                        Image(yapIcon: "chevron.down")
                            .rotationEffect(.degrees(showsPrivacyDetails ? 180 : 0))
                    }
                    .font(AppTheme.font(.footnote, .medium))
                    .foregroundColor(AppTheme.Text.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityValue(showsPrivacyDetails ? Text("Expanded") : Text("Collapsed"))

                if showsPrivacyDetails {
                    VStack(alignment: .leading, spacing: AppTheme.Spacing.x3) {
                        Text("Local models process audio or text on this Mac. Choose local transcription and local enhancement for on-device processing.", tableName: "PrivacyCopy")
                        Text("With your own API key, cloud models receive the audio, text and enabled context needed for the request.", tableName: "PrivacyCopy")
                        Text("Yap Cloud sends requests through Yap's server to model providers and records the model and cost for billing.", tableName: "PrivacyCopy")
                        Text("Optional cloud sync stores modes, prompts, dictionary, shortcuts and custom models on Yap's server, without your API keys.", tableName: "PrivacyCopy")
                        Text("If you enable Agent Access (MCP), connected agents can read allowed history and dictionary data. Their own privacy policies apply.", tableName: "PrivacyCopy")
                    }
                        .font(AppTheme.font(.body))
                        .foregroundColor(AppTheme.Text.secondary)
                        .multilineTextAlignment(.leading)
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

                Text(Self.meetingLine(shortcut: ShortcutStore.shortcut(for: .meetingRecording)))
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
            Image(yapIcon: systemImage)
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
            Image(yapIcon: "shield.fill")
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
                    Image(yapIcon: "shield")
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
