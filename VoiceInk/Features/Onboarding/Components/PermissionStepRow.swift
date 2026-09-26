import SwiftUI

struct PermissionStepRow: View {
    let stepNumber: Int
    let descriptor: OnboardingPermissionDescriptor
    let status: OnboardingPermissionStatus
    let isActive: Bool
    let isLocked: Bool
    let showsRestartHint: Bool
    let actionTitle: String
    let onSelect: () -> Void
    let onAction: () -> Void
    let onQuit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.x3) {
            HStack(alignment: .center, spacing: AppTheme.Spacing.x4) {
                stepNumberView

                VStack(alignment: .leading, spacing: AppTheme.Spacing.x1) {
                    Text(LocalizedStringKey(descriptor.title))
                        .font(AppTheme.font(.callout, .semibold))
                        .foregroundColor(AppTheme.Text.primary)

                    Text(LocalizedStringKey(descriptor.subtitle))
                        .font(AppTheme.font(.footnote))
                        .foregroundColor(AppTheme.Text.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 10)

                if status.isGranted || isLocked {
                    statusBadge
                } else {
                    actionButton
                }
            }

            if isActive && !isLocked && showsRestartHint {
                restartHint
                    .padding(.leading, AppTheme.Spacing.x12)
            }
        }
        .padding(AppTheme.Spacing.x4)
        .background(
            AppMaterialCardBackground(
                isSelected: isActive && !isLocked,
                cornerRadius: AppTheme.Radius.control
            )
        )
        .opacity(isLocked ? 0.55 : 1)
        .contentShape(RoundedRectangle(cornerRadius: AppTheme.Radius.control, style: .continuous))
        .onTapGesture {
            guard !isLocked else { return }
            onSelect()
        }
    }

    private var stepNumberView: some View {
        ZStack {
            RoundedRectangle(cornerRadius: AppTheme.Radius.control, style: .continuous)
                .fill(status.isGranted ? AppTheme.Selection.fill : AppTheme.Surface.controlActive)

            if status.isGranted {
                Image(systemName: "checkmark")
                    .font(AppTheme.font(.footnote, .semibold))
                    .foregroundColor(AppTheme.Text.primary)
            } else {
                Text("\(stepNumber)")
                    .font(AppTheme.font(.footnote, .semibold))
                    .foregroundColor(isActive && !isLocked ? AppTheme.Text.primary : AppTheme.Text.muted)
            }
        }
        .frame(width: 30, height: 30)
    }

    private var actionButton: some View {
        Button(action: onAction) {
            Text(LocalizedStringKey(actionTitle))
                .font(AppTheme.font(.footnote, .semibold))
                .foregroundColor(AppTheme.Action.primaryForeground)
                .frame(minWidth: 94)
                .padding(.horizontal, AppTheme.Spacing.x3)
                .padding(.vertical, AppTheme.Spacing.x2)
                .background(
                    RoundedRectangle(cornerRadius: AppTheme.Radius.control, style: .continuous)
                        .fill(AppTheme.Action.primaryFill)
                )
        }
        .buttonStyle(.plain)
    }

    private var statusBadge: some View {
        Text(isLocked ? LocalizedStringKey("Locked") : LocalizedStringKey(status.label))
            .font(AppTheme.font(.footnote, .semibold))
            .foregroundColor(isLocked ? AppTheme.Text.muted : statusTone)
            .padding(.horizontal, AppTheme.Spacing.x3)
            .padding(.vertical, AppTheme.Spacing.x2)
            .background(isLocked ? AppTheme.Surface.subtle : statusTone.opacity(0.12))
            .clipShape(Capsule())
    }

    private var statusTone: Color {
        switch status {
        case .denied, .restricted:
            return AppTheme.Status.error
        default:
            return AppTheme.Text.secondary
        }
    }

    private var restartHint: some View {
        HStack(spacing: AppTheme.Spacing.x2) {
            Text("Restart Yap after enabling Screen Recording.")
                .font(AppTheme.font(.footnote))
                .foregroundColor(AppTheme.Text.muted)
                .fixedSize(horizontal: false, vertical: true)

            Button("Quit") {
                onQuit()
            }
            .font(AppTheme.font(.footnote, .semibold))
            .buttonStyle(.plain)
            .foregroundColor(AppTheme.Action.secondaryForeground)
        }
    }
}
