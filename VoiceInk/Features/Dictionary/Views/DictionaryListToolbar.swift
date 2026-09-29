import SwiftUI

/// Which dictionary entries a list shows, by who added them.
enum DictionarySourceFilter: CaseIterable, Hashable {
    case all, autoAdded, manual

    var title: LocalizedStringKey {
        switch self {
        case .all: "All"
        case .autoAdded: "Auto-added"
        case .manual: "Manually added"
        }
    }

    func includes(isAutoLearned: Bool) -> Bool {
        switch self {
        case .all: true
        case .autoAdded: isAutoLearned
        case .manual: !isAutoLearned
        }
    }
}

/// Filter pills plus Select / Delete for a dictionary list (Vocabulary and Word Replacements share it).
struct DictionaryListToolbar: View {
    @Binding var filter: DictionarySourceFilter
    @Binding var isSelecting: Bool
    let selectedCount: Int
    let visibleCount: Int
    let onSelectAll: () -> Void
    let onDeleteSelected: () -> Void
    @State private var isConfirmingDelete = false

    var body: some View {
        HStack(spacing: AppTheme.Spacing.x2) {
            Picker("Show", selection: $filter) {
                ForEach(DictionarySourceFilter.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()

            Spacer()

            if isSelecting {
                Button("Select All", action: onSelectAll)
                    .disabled(visibleCount == 0 || selectedCount == visibleCount)
                Button(role: .destructive) {
                    isConfirmingDelete = true
                } label: {
                    Text(String(localized: "Delete (\(selectedCount))"))
                }
                .disabled(selectedCount == 0)
                Button("Done") { isSelecting = false }
            } else {
                Button("Select") { isSelecting = true }
                    .disabled(visibleCount == 0)
            }
        }
        .controlSize(.small)
        .confirmationDialog(
            String(localized: "Delete \(selectedCount) entries?"),
            isPresented: $isConfirmingDelete
        ) {
            Button("Delete", role: .destructive, action: onDeleteSelected)
        } message: {
            Text("This can't be undone.")
        }
    }
}

/// Checkbox shown in front of a dictionary entry while selecting.
struct DictionarySelectionMark: View {
    let isSelected: Bool

    var body: some View {
        Image(yapIcon: isSelected ? "checkmark.circle.fill" : "circle")
            .foregroundStyle(isSelected ? AppTheme.Accent.text : AppTheme.Text.muted)
            .accessibilityLabel(isSelected ? Text("Selected") : Text("Not selected"))
    }
}

/// Shown instead of the list when the source filter hides every entry.
struct DictionaryFilterEmptyNote: View {
    let filter: DictionarySourceFilter

    var body: some View {
        Text(filter == .autoAdded
            ? LocalizedStringKey("Nothing added by Auto-Learn yet.")
            : LocalizedStringKey("Nothing added by hand yet."))
            .font(AppTheme.font(.footnote))
            .foregroundStyle(AppTheme.Text.secondary)
            .padding(.vertical, AppTheme.Spacing.x3)
    }
}
