import SwiftUI

/// Searchable list of model ids; picking one calls `onSelect`.
struct YapCloudModelBrowser: View {
    let title: LocalizedStringKey
    /// `id` is what `onSelect` receives; `detail` (the model slug) is shown under the name.
    let models: [(id: String, name: String, detail: String)]
    let selectedID: String?
    let onSelect: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var filtered: [(id: String, name: String, detail: String)] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return models }
        return models.filter { $0.detail.localizedCaseInsensitiveContains(q) || $0.name.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.x3) {
            HStack {
                Text(title).font(AppTheme.font(.body, .semibold))
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            TextField("Search models", text: $query)
                .textFieldStyle(.roundedBorder)
            List(filtered, id: \.id) { model in
                Button {
                    onSelect(model.id)
                    dismiss()
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: AppTheme.Spacing.half) {
                            Text(model.name)
                            if model.name != model.detail {
                                Text(model.detail).font(AppTheme.font(.caption)).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        if let average = YapCloud.shared.averageCallLabel(model: model.detail) {
                            Text(average).font(AppTheme.font(.caption)).monospacedDigit().foregroundStyle(.secondary)
                        }
                        if model.id == selectedID {
                            Image(systemName: "checkmark").accessibilityHidden(true)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(model.id == selectedID ? .isSelected : [])
            }
            .listStyle(.inset)
        }
        .padding(AppTheme.Spacing.x4)
        .frame(width: 420, height: 460)
    }
}

/// Enhancement model choice for Yap Cloud: recommended models in the picker, the rest via "All Models…".
struct YapCloudEnhancementModelPicker: View {
    let models: [String]
    @Binding var selection: String
    @State private var isBrowsing = false

    private var recommended: [String] {
        let available = YapCloudPicks.enhancement.filter(models.contains)
        return available.contains(selection) || selection.isEmpty ? available : available + [selection]
    }

    var body: some View {
        LabeledContent("AI Model") {
            HStack(spacing: AppTheme.Spacing.x2) {
                Picker("", selection: $selection) {
                    ForEach(recommended, id: \.self) { id in
                        Text(YapCloud.shared.averageCallLabel(model: id).map { "\(id)  \($0)" } ?? id).tag(id)
                    }
                }
                .labelsHidden()
                Button("All Models…") { isBrowsing = true }
            }
        }
        .sheet(isPresented: $isBrowsing) {
            YapCloudModelBrowser(
                title: "All Yap Cloud Models",
                models: models.map { id in (id, YapCloud.shared.models.first { $0.id == id }?.displayName ?? id, id) },
                selectedID: selection,
                onSelect: { selection = $0 })
        }
    }
}
