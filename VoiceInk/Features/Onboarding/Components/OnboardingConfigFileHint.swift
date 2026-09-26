import SwiftUI

/// Points users who prefer a file over the provider cards to `~/.config/yap/config.json`.
struct OnboardingConfigFileHint: View {
    var body: some View {
        HStack(spacing: AppTheme.Spacing.x2) {
            Text("Or configure with ~/.config/yap/config.json")
                .font(AppTheme.font(.caption))
                .foregroundColor(AppTheme.Text.secondary)
            Button("Open Config Folder") {
                YapConfigLoader.shared.openConfigFolder()
            }
            .buttonStyle(.plain)
            .font(AppTheme.font(.caption, .medium))
            .foregroundColor(AppTheme.Accent.text)
        }
    }
}
