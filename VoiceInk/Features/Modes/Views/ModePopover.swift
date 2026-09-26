import SwiftUI

struct ModePopover: View {
    @ObservedObject var modeManager = ModeManager.shared
    let selectedModeId: UUID?
    let onSelect: ((ModeConfig) -> Void)?

    init(selectedModeId: UUID? = nil, onSelect: ((ModeConfig) -> Void)? = nil) {
        self.selectedModeId = selectedModeId
        self.onSelect = onSelect
    }

    private var effectiveSelectedModeId: UUID? {
        modeManager.resolvedEnabledConfigurationId(preferredId: selectedModeId)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.x2) {
            Text("Select Mode")
                .font(.headline)
                .foregroundColor(AppTheme.Text.primary)
                .padding(.horizontal)
                .padding(.top, AppTheme.Spacing.x2)

            Divider()
                .background(AppTheme.Border.subtle)

            ScrollView {
                let enabledConfigs = modeManager.enabledConfigurations
                VStack(alignment: .leading, spacing: AppTheme.Spacing.x1) {
                    if enabledConfigs.isEmpty {
                        VStack(alignment: .center, spacing: AppTheme.Spacing.x2) {
                            Image(systemName: "sparkles")
                                .foregroundColor(AppTheme.Text.secondary)
                                .font(AppTheme.font(.headline))
                            Text("No Modes Available")
                                .foregroundColor(AppTheme.Text.primary)
                                .font(AppTheme.font(.body))
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, AppTheme.Spacing.x4)
                    } else {
                        ForEach(enabledConfigs) { config in
                            ModeRow(
                                config: config,
                                isSelected: effectiveSelectedModeId == config.id,
                                action: {
                                    if let onSelect {
                                        onSelect(config)
                                    } else {
                                        modeManager.setActiveConfiguration(config)
                                    }
                                }
                            )
                        }
                    }
                }
                .padding(.horizontal)
            }
        }
        .frame(width: 180)
        .frame(maxHeight: 340)
        .padding(.vertical, AppTheme.Spacing.x2)
        .background(AppTheme.Surface.window)
        .popoverAppAppearance()
    }
}

struct ModeRow: View {
    let config: ModeConfig
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: AppTheme.Spacing.x2) {
                ModeIconView(
                    icon: config.icon,
                    size: config.icon.kind == .emoji ? 14 : 12,
                    color: AppTheme.Text.primary
                )
                    .frame(width: 16)

                Text(config.name)
                    .foregroundColor(AppTheme.Text.primary)
                    .font(AppTheme.font(.body))
                    .lineLimit(1)

                if isSelected {
                    Spacer()
                    Image(systemName: "checkmark")
                        .foregroundColor(AppTheme.Status.positive)
                        .font(AppTheme.font(.micro))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, AppTheme.Spacing.x1)
            .padding(.horizontal, AppTheme.Spacing.x2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(isSelected ? AppTheme.Selection.fill : Color.clear)
        .cornerRadius(4)
    }
}
