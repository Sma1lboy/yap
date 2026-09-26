import AppKit
import SwiftUI

// MARK: - Native Apple Model Card View
struct NativeAppleModelCardView: View {
    let model: NativeAppleModel

    var body: some View {
        HStack(alignment: .top, spacing: AppTheme.Spacing.x4) {
            // Main Content
            VStack(alignment: .leading, spacing: AppTheme.Spacing.x2) {
                headerSection
                metadataSection
                descriptionSection
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Action Controls
            actionSection
        }
        .padding(AppTheme.Spacing.x4)
        .background(AppMaterialCardBackground())
    }

    private var headerSection: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(model.displayName)
                .font(AppTheme.font(.body, .semibold))
                .foregroundColor(Color(.labelColor))

            Spacer()
        }
    }

    private var metadataSection: some View {
        HStack(spacing: AppTheme.Spacing.x3) {
            // Native Apple
            Label("Native Apple", systemImage: "apple.logo")
                .font(AppTheme.font(.caption))
                .foregroundColor(Color(.secondaryLabelColor))
                .lineLimit(1)

            // Language
            Label(model.language, systemImage: "globe")
                .font(AppTheme.font(.caption))
                .foregroundColor(Color(.secondaryLabelColor))
                .lineLimit(1)

            // On-Device
            Label("On-Device", systemImage: "checkmark.shield")
                .font(AppTheme.font(.caption))
                .foregroundColor(Color(.secondaryLabelColor))
                .lineLimit(1)

            // Requires macOS 26+
            Label("macOS 26+", systemImage: "macbook")
                .font(AppTheme.font(.caption))
                .foregroundColor(Color(.secondaryLabelColor))
                .lineLimit(1)
        }
        .lineLimit(1)
    }

    private var descriptionSection: some View {
        Text(model.description)
            .font(AppTheme.font(.caption))
            .foregroundColor(Color(.secondaryLabelColor))
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, AppTheme.Spacing.x1)
    }

    private var actionSection: some View {
        HStack(spacing: AppTheme.Spacing.x2) {
            modelStatusPill("Built in", systemImage: "checkmark.circle")
        }
    }
}
