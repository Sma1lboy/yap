import SwiftUI

/// Points users who prefer a file over the provider cards to `~/.config/yap/config.json`.
struct OnboardingConfigFileHint: View {
    var body: some View {
        HStack(spacing: 8) {
            Text("Or configure with ~/.config/yap/config.json")
                .font(.system(size: 11))
                .foregroundColor(AppTheme.Text.secondary)
            Button("Open Config Folder") {
                YapConfigLoader.shared.openConfigFolder()
            }
            .buttonStyle(.plain)
            .font(.system(size: 11, weight: .medium))
            .foregroundColor(AppTheme.Accent.primary)
        }
    }
}
