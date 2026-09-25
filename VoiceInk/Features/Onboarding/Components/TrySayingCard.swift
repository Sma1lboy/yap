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
        VStack(alignment: .leading, spacing: 6) {
            Text("Try saying")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(AppTheme.Text.muted)
            Text("“um so the standup, 改到 Friday morning, and uh send Chris the onboarding review”")
                .font(.system(size: 13))
                .foregroundStyle(AppTheme.Text.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("Yap pastes")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(AppTheme.Text.muted)
                Text("Standup 改到 Friday morning. Send Chris the onboarding review.")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(AppTheme.Text.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(maxWidth: 520, alignment: .leading)
        .background(AppMaterialCardBackground(cornerRadius: AppTheme.Radius.card))
        .accessibilityElement(children: .combine)
    }
}
