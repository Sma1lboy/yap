import SwiftUI

struct ModeSettingsQuickSwitchTip: View {
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: AppTheme.Spacing.x3) {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.x2) {
                Text("Mode shortcuts")
                    .font(AppTheme.font(.body, .semibold))
                    .foregroundColor(AppTheme.Text.primary)
                    .lineLimit(1)

                Text("During recording, press Option + 1-9 to switch modes quickly.")
                    .font(AppTheme.font(.footnote))
                    .foregroundColor(AppTheme.Text.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineLimit(2)
            }

            Spacer(minLength: 8)

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(AppTheme.font(.micro, .semibold))
                    .foregroundColor(AppTheme.Text.secondary)
                    .frame(width: 22, height: 22)
                    .background(AppTheme.Surface.control)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .help("Dismiss")
            .accessibilityLabel("Dismiss shortcut tip")
        }
        .padding(AppTheme.Spacing.x3)
        .background(AppMaterialCardBackground(cornerRadius: AppTheme.Radius.card))
    }
}
