import AppKit
import SwiftUI

// MARK: - Custom Model Card View
struct CustomModelCardView: View {
    let model: CustomCloudModel
    var deleteAction: () -> Void
    var editAction: (CustomCloudModel) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Main card content
            HStack(alignment: .top, spacing: AppTheme.Spacing.x4) {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.x2) {
                    headerSection
                    metadataSection
                    descriptionSection
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                actionSection
            }
            .padding(AppTheme.Spacing.x4)
        }
        .background(AppMaterialCardBackground())
    }

    private var headerSection: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(model.displayName)
                .font(AppTheme.font(.body, .semibold))
                .foregroundColor(Color(.labelColor))

            // Definitions synced from another Mac arrive without their key (keys never leave a Mac).
            if (APIKeyManager.shared.getCustomModelAPIKey(forModelId: model.id) ?? "").isEmpty {
                Button {
                    editAction(model)
                } label: {
                    Label("API key needed", systemImage: "key")
                        .font(AppTheme.font(.caption, .medium))
                        .foregroundColor(AppTheme.Status.warningStrong)
                }
                .buttonStyle(.plain)
                .help("Add this model's API key on this Mac")
            }

            Spacer()
        }
    }

    private var metadataSection: some View {
        HStack(spacing: AppTheme.Spacing.x3) {
            Label(model.modelName, systemImage: "cube")
                .font(AppTheme.font(.caption))
                .foregroundColor(Color(.secondaryLabelColor))
                .lineLimit(1)

            // Language
            Label(model.language, systemImage: "globe")
                .font(AppTheme.font(.caption))
                .foregroundColor(Color(.secondaryLabelColor))
                .lineLimit(1)

            // OpenAI Compatible
            Label("OpenAI Compatible", systemImage: "checkmark.seal")
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
            modelStatusPill("Configured", systemImage: "checkmark.circle")

            Menu {
                Button {
                    editAction(model)
                } label: {
                    Label("Edit Model", systemImage: "pencil")
                }

                Button(role: .destructive) {
                    deleteAction()
                } label: {
                    Label("Delete Model", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(AppTheme.font(.callout))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .help("More Actions")
            .accessibilityLabel("More Actions")
            .frame(width: 20, height: 20)
        }
    }
}
