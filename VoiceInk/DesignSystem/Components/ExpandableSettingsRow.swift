import SwiftUI

struct ExpandableSettingsRow<Content: View>: View {
    @Binding private var isExpanded: Bool

    private let isEnabled: Binding<Bool>?
    private let label: LocalizedStringKey
    private let infoMessage: LocalizedStringKey?
    private let infoURL: String?
    private let expandedContentTransition: AnyTransition
    private let content: () -> Content

    @State private var isHandlingToggleChange = false

    init(
        isExpanded: Binding<Bool>,
        isEnabled: Binding<Bool>,
        label: LocalizedStringKey,
        infoMessage: LocalizedStringKey? = nil,
        infoURL: String? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) {
        _isExpanded = isExpanded
        self.isEnabled = isEnabled
        self.label = label
        self.infoMessage = infoMessage
        self.infoURL = infoURL
        self.expandedContentTransition = .opacity.combined(with: .move(edge: .top))
        self.content = content
    }

    init(
        title: LocalizedStringKey,
        isExpanded: Binding<Bool>,
        @ViewBuilder content: @escaping () -> Content
    ) {
        _isExpanded = isExpanded
        self.isEnabled = nil
        self.label = title
        self.infoMessage = nil
        self.infoURL = nil
        self.expandedContentTransition = .opacity
        self.content = content
    }

    private var rowIsEnabled: Bool {
        isEnabled?.wrappedValue ?? true
    }

    private func toggleExpanded() {
        guard !isHandlingToggleChange, rowIsEnabled else { return }
        withAnimation(.easeInOut(duration: 0.2)) {
            isExpanded.toggle()
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                if let isEnabled = isEnabled {
                    Toggle(isOn: isEnabled) {
                        labelView
                    }
                } else {
                    labelView
                }

                Spacer()

                // A Button so the options are reachable with the keyboard and VoiceOver; clicking the row works too.
                Button(action: toggleExpanded) {
                    Image(systemName: "chevron.right")
                        .font(AppTheme.font(.footnote, .semibold))
                        .foregroundColor(.secondary)
                        .rotationEffect(.degrees(rowIsEnabled && isExpanded ? 90 : 0))
                        .opacity(rowIsEnabled ? 1 : 0.4)
                }
                .buttonStyle(.plain)
                .disabled(!rowIsEnabled)
                .accessibilityLabel(isExpanded ? LocalizedStringKey("Hide Options") : "Show Options")
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: toggleExpanded)

            if rowIsEnabled && isExpanded {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.x2) {
                    content()
                }
                .padding(.top, AppTheme.Spacing.x3)
                .padding(.leading, AppTheme.Spacing.x1)
                .transition(expandedContentTransition)
            }
        }
        .onChange(of: rowIsEnabled) { _, newValue in
            guard isEnabled != nil else { return }
            isHandlingToggleChange = true
            if newValue {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isExpanded = true
                }
            } else {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isExpanded = false
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                isHandlingToggleChange = false
            }
        }
    }

    private var labelView: some View {
        HStack(spacing: AppTheme.Spacing.x1) {
            Text(label)
            if let infoMessage = infoMessage {
                if let infoURL = infoURL {
                    InfoTip(infoMessage, learnMoreURL: infoURL)
                } else {
                    InfoTip(infoMessage)
                }
            }
        }
    }
}
