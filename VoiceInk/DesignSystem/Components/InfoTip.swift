import SwiftUI

/// A reusable info tip component that displays helpful information in a popover
struct InfoTip: View {
    // Content configuration
    var message: LocalizedStringKey
    var learnMoreLink: URL?

    // Appearance customization
    var iconName: String = "info.circle"
    var iconSize: Image.Scale = .medium
    var iconColor: Color = .primary
    var width: CGFloat = 280

    // State
    @State private var isShowingTip: Bool = false

    var body: some View {
        // A Button (not a tap gesture) so keyboard focus and VoiceOver can open the tip.
        Button {
            isShowingTip.toggle()
        } label: {
            Image(systemName: iconName)
                .imageScale(iconSize)
                .foregroundColor(iconColor)
                .fontWeight(.semibold)
                .padding(5)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("More Info")
        .accessibilityHint(message)
        .popover(isPresented: $isShowingTip) {
            VStack(alignment: .leading, spacing: 0) {
                if learnMoreLink != nil {
                    (Text(message)
                        .foregroundColor(.secondary)
                        + Text(" ")
                        + Text("Learn more")
                        .foregroundColor(AppTheme.Accent.primary))
                        .font(.callout)
                } else {
                    Text(message)
                        .font(.callout)
                        .foregroundColor(.secondary)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(width: width, alignment: .leading)
            .padding(14)
            .onTapGesture {
                if let url = learnMoreLink {
                    NSWorkspace.shared.open(url)
                }
            }
        }
    }
}

// MARK: - Convenience initializers

extension InfoTip {
    /// Creates an InfoTip with just a message
    init(_ message: LocalizedStringKey) {
        self.message = message
        self.learnMoreLink = nil
    }

    /// Creates an InfoTip with a dynamic string message
    init(_ message: String) {
        self.message = LocalizedStringKey(message)
        self.learnMoreLink = nil
    }

    /// Creates an InfoTip with a learn more link
    init(_ message: LocalizedStringKey, learnMoreURL: String) {
        self.message = message
        self.learnMoreLink = URL(string: learnMoreURL)
    }

    /// Creates an InfoTip with a dynamic string message and learn more link
    init(_ message: String, learnMoreURL: String) {
        self.message = LocalizedStringKey(message)
        self.learnMoreLink = URL(string: learnMoreURL)
    }
}
