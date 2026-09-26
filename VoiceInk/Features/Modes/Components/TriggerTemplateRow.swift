import SwiftUI

struct TriggerTemplateRow: View {
    let template: TriggerTemplate
    let group: ModeTriggerGroup
    let isAdded: Bool
    let isLoadingApps: Bool
    let onToggle: (ModeTriggerGroup) -> Void

    private var isDisabled: Bool {
        isLoadingApps || (!isAdded && group.isEmpty)
    }

    private var cardBackground: Color {
        isAdded ? Color(nsColor: .unemphasizedSelectedContentBackgroundColor) : Color.clear
    }

    private var cardBorder: Color {
        isAdded ? Color(nsColor: .separatorColor) : AppTheme.Border.control
    }

    var body: some View {
        Button {
            guard !isDisabled else { return }
            onToggle(group)
        } label: {
            HStack(spacing: AppTheme.Spacing.x3) {
                TriggerSymbol(systemName: template.systemImage)

                Text(template.name)
                    .font(AppTheme.font(.body, .semibold))
                    .foregroundColor(.primary)
                    .lineLimit(1)

                Spacer()

                if !group.isEmpty {
                    TriggerGroupPreviewStack(appConfigs: group.appConfigs, urlConfigs: group.urlConfigs, tileSize: 24)
                        .padding(.trailing, AppTheme.Spacing.x1)
                }

                if isAdded {
                    Image(systemName: "checkmark.circle.fill")
                        .font(AppTheme.font(.headline, .medium))
                        .foregroundStyle(AppTheme.Accent.text)
                        .frame(width: 22, height: 22)
                } else if !isDisabled {
                    Image(systemName: "plus.circle.fill")
                        .font(AppTheme.font(.callout, .medium))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 22)
                }
            }
            .padding(.horizontal, AppTheme.Spacing.x2)
            .padding(.vertical, AppTheme.Spacing.x2)
            .contentShape(Rectangle())
            .background {
                RoundedRectangle(cornerRadius: AppTheme.Radius.control, style: .continuous)
                    .fill(cardBackground)
            }
            .overlay {
                RoundedRectangle(cornerRadius: AppTheme.Radius.control, style: .continuous)
                    .strokeBorder(cardBorder, lineWidth: 0.5)
            }
        }
        .buttonStyle(.plain)
        .help(isAdded ? String(localized: "Remove \(template.name) triggers") : group.summaryText)
    }
}

struct TriggerSymbol: View {
    let systemName: String

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: AppTheme.Radius.small)
                .fill(AppTheme.Surface.control)
                .frame(width: 28, height: 28)

            Image(systemName: systemName)
                .font(AppTheme.font(.body, .medium))
                .foregroundStyle(.primary)
        }
    }
}
