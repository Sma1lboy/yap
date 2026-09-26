import SwiftUI

struct CompactHeroSection: View {
    let icon: String
    let title: LocalizedStringKey
    let description: LocalizedStringKey
    var maxDescriptionWidth: CGFloat? = nil

    var body: some View {
        VStack(spacing: AppTheme.Spacing.x4) {
            Image(systemName: icon)
                .font(AppTheme.font(.display))
                .foregroundStyle(AppTheme.Status.infoStrong)
                .symbolRenderingMode(.hierarchical)

            VStack(spacing: AppTheme.Spacing.x2) {
                Text(title)
                    .font(AppTheme.font(.title, .semibold))
                Text(description)
                    .font(AppTheme.font(.callout))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: maxDescriptionWidth)
            }
        }
        .padding(.vertical, AppTheme.Spacing.x5)
        .frame(maxWidth: .infinity)
    }
}
