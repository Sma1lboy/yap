import SwiftUI

struct DictionaryPill<Label: View>: View {
    private let label: Label
    private let onRemove: (() -> Void)?
    private let removeHelp: LocalizedStringKey
    private let removeAccessibilityLabel: LocalizedStringKey?

    init(
        onRemove: (() -> Void)?,
        removeHelp: LocalizedStringKey,
        removeAccessibilityLabel: LocalizedStringKey? = nil,
        @ViewBuilder label: () -> Label
    ) {
        self.label = label()
        self.onRemove = onRemove
        self.removeHelp = removeHelp
        self.removeAccessibilityLabel = removeAccessibilityLabel
    }

    var body: some View {
        HStack(spacing: AppTheme.Spacing.x2) {
            label
                .font(AppTheme.font(.body))

            removeButton
        }
        .padding(.horizontal, AppTheme.Spacing.x2)
        .padding(.vertical, AppTheme.Spacing.x2)
        .background {
            RoundedRectangle(cornerRadius: AppTheme.Radius.small)
                .fill(AppTheme.Surface.window.opacity(0.4))
        }
        .overlay {
            RoundedRectangle(cornerRadius: AppTheme.Radius.small)
                .stroke(AppTheme.Border.subtle, lineWidth: 1)
        }
        .shadow(color: Color.black.opacity(0.05), radius: 2, y: 1)
    }

    @ViewBuilder
    private var removeButton: some View {
        if let onRemove {
            let button = Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(AppTheme.Text.primary)
            }
            .buttonStyle(.borderless)
            .help(removeHelp)

            if let removeAccessibilityLabel {
                button.accessibilityLabel(removeAccessibilityLabel)
            } else {
                button
            }
        }
    }
}
