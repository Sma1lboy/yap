import SwiftData
import SwiftUI

/// "Try saying" example for someone who has never dictated: the same code-switched sentence as the landing
/// page (site/index.html), and what Yap pastes for it. Callers show it only while no transcription exists.
struct TrySayingCard: View {
    /// Fetches at most one transcription; empty means the user has never dictated.
    static var anyTranscription: FetchDescriptor<Transcription> {
        var descriptor = FetchDescriptor<Transcription>()
        descriptor.fetchLimit = 1
        return descriptor
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.x2) {
            Text("Try saying")
                .font(AppTheme.font(.caption, .semibold))
                .foregroundStyle(AppTheme.Text.muted)
            Text("“um so the standup, 改到 Friday morning, and uh send Chris the onboarding review”")
                .font(AppTheme.font(.body))
                .foregroundStyle(AppTheme.Text.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .firstTextBaseline, spacing: AppTheme.Spacing.x2) {
                Text("Yap pastes")
                    .font(AppTheme.font(.caption, .semibold))
                    .foregroundStyle(AppTheme.Text.muted)
                Text("Standup 改到 Friday morning. Send Chris the onboarding review.")
                    .font(AppTheme.font(.body, .medium))
                    .foregroundStyle(AppTheme.Text.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(AppTheme.Spacing.x4)
        .frame(maxWidth: 520, alignment: .leading)
        .background(AppMaterialCardBackground(cornerRadius: AppTheme.Radius.card))
        .accessibilityElement(children: .combine)
    }
}
