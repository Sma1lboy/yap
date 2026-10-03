import AppKit
import SwiftUI

/// The floating Scratchpad: a plain-text editor with Copy All and Clear. Dictation pastes into it like any text field.
struct ScratchpadView: View {
    @ObservedObject var store: ScratchpadStore
    @State private var confirmingClear = false
    @State private var copied = false

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .topLeading) {
                TextEditor(text: $store.text)
                    .font(AppTheme.font(.body))
                    .foregroundStyle(AppTheme.Text.primary)
                    .scrollContentBackground(.hidden)
                    .padding(AppTheme.Spacing.x3)
                if store.text.isEmpty {
                    Text("Dictate or type here. It stays on this Mac.")
                        .font(AppTheme.font(.body))
                        .foregroundStyle(AppTheme.Text.muted)
                        .padding(.horizontal, AppTheme.Spacing.x3 + AppTheme.Spacing.x1 + AppTheme.Spacing.half)
                        .padding(.vertical, AppTheme.Spacing.x3)
                        .allowsHitTesting(false)
                }
            }

            Divider()
            HStack(spacing: AppTheme.Spacing.x2) {
                AppActionButton("Clear") { confirmingClear = true }
                    .disabled(store.text.isEmpty)
                Spacer()
                AppActionButton(copied ? "Copied" : "Copy All", kind: .primary, minWidth: 72) { copyAll() }
                    .disabled(store.text.isEmpty)
            }
            .padding(AppTheme.Spacing.x3)
        }
        .background(AppTheme.Surface.window)
        .alert("Clear the Scratchpad?", isPresented: $confirmingClear) {
            Button("Clear", role: .destructive) { store.clear() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Everything in it is deleted. This can't be undone.")
        }
    }

    private func copyAll() {
        guard ClipboardManager.copyToClipboard(store.text) else { return }
        copied = true
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            copied = false
        }
    }
}
