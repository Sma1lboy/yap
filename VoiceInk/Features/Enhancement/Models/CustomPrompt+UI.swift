import SwiftUI

// MARK: - UI Extensions
extension CustomPrompt {
    func promptIcon(
        isSelected: Bool, onTap: @escaping () -> Void, onEdit: ((CustomPrompt) -> Void)? = nil,
        onDelete: ((CustomPrompt) -> Void)? = nil
    ) -> some View {
        // A Button so the chip is reachable with the keyboard and VoiceOver; double-click still edits.
        Button(action: onTap) {
            HStack(spacing: AppTheme.Spacing.x2) {
                Text(title)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .font(AppTheme.font(.footnote, .medium))
            .foregroundStyle(isSelected ? AppTheme.Text.onAccent : Color.primary)
            .frame(maxWidth: .infinity, minHeight: 30)
            .padding(.horizontal, AppTheme.Spacing.x3)
            .background(
                RoundedRectangle(cornerRadius: AppTheme.Radius.small)
                    .fill(isSelected ? AppTheme.Accent.primary : AppTheme.Surface.control)
            )
            .overlay(
                RoundedRectangle(cornerRadius: AppTheme.Radius.small)
                    .stroke(AppTheme.Border.control, lineWidth: isSelected ? 0 : 0.5)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .simultaneousGesture(
            TapGesture(count: 2).onEnded {
                onEdit?(self)
            }
        )
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityActions {
            if let onEdit {
                Button("Edit") { onEdit(self) }
            }
        }
        .contextMenu {
            if onEdit != nil || onDelete != nil {
                if let onEdit = onEdit {
                    Button {
                        onEdit(self)
                    } label: {
                        Label("Edit", systemImage: "pencil")
                    }
                }

                if let onDelete = onDelete {
                    Button(role: .destructive) {
                        let alert = NSAlert()
                        alert.messageText = String(localized: "Delete Prompt?")
                        alert.informativeText = String(
                            format: String(
                                localized: "Are you sure you want to delete '%@' prompt? This action cannot be undone."),
                            self.title)
                        alert.alertStyle = .warning
                        alert.addButton(withTitle: String(localized: "Delete"))
                        alert.addButton(withTitle: String(localized: "Cancel"))

                        let response = alert.runModal()
                        if response == .alertFirstButtonReturn {
                            onDelete(self)
                        }
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
        }
    }

    static func addNewButton(action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label("Add New", systemImage: "plus.circle.fill")
                .font(AppTheme.font(.footnote, .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, minHeight: 30)
                .padding(.horizontal, AppTheme.Spacing.x3)
                .background(
                    RoundedRectangle(cornerRadius: AppTheme.Radius.small)
                        .fill(AppTheme.Surface.control)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: AppTheme.Radius.small)
                        .stroke(AppTheme.Border.control, lineWidth: 0.5)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
