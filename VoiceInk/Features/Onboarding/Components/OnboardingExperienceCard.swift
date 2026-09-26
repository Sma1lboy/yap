import SwiftUI

struct OnboardingExperienceCard: View {
    let step: OnboardingExperienceStep
    let shortcutAction: ShortcutAction
    let hasShortcut: Bool
    @Binding var text: String
    let onShortcutChanged: () -> Void

    @State private var isFieldFocused = false
    private let editorTextInset = EdgeInsets(top: 1, leading: 1, bottom: 1, trailing: 1)
    private let panelHeight: CGFloat = 184

    var body: some View {
        VStack(spacing: AppTheme.Spacing.x6) {
            if step.layout == .respond {
                respondStage
            } else {
                transformStage
            }

            OnboardingExperienceInstruction(
                step: step,
                shortcutAction: shortcutAction,
                hasShortcut: hasShortcut,
                onShortcutChanged: onShortcutChanged
            )
        }
        .frame(maxWidth: .infinity)
        .onAppear {
            focusFieldIfReady()
        }
        .onChange(of: hasShortcut) { _, _ in
            focusFieldIfReady()
        }
    }

    private var transformStage: some View {
        HStack(alignment: .center, spacing: 0) {
            sayPanel
            transformArrow
            notesPreviewPanel
        }
    }

    private var sayPanel: some View {
        panelShell(kicker: step.sampleLabel) {
            Text(LocalizedStringKey(step.sampleText))
                .font(AppTheme.font(.headline, .medium))
                .foregroundColor(AppTheme.Text.primary)
                .lineSpacing(5)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var notesPreviewPanel: some View {
        VStack(spacing: 0) {
            notesToolbar

            Divider()
                .opacity(0.5)

            notesTextArea
        }
        .frame(maxWidth: .infinity)
        .frame(height: panelHeight)
        .background(AppTheme.Surface.window.opacity(0.86))
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.panel, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.Radius.panel, style: .continuous)
                .stroke(fieldBorderColor, lineWidth: 1)
        )
        .opacity(hasShortcut ? 1 : 0.5)
        .animation(.easeInOut(duration: 0.18), value: hasShortcut)
    }

    private var notesToolbar: some View {
        HStack(spacing: AppTheme.Spacing.x2) {
            trafficLights

            Image(systemName: "note.text")
                .font(AppTheme.font(.footnote, .semibold))
                .foregroundColor(AppTheme.Text.secondary)

            Text("Notes")
                .font(AppTheme.font(.footnote, .semibold))
                .foregroundColor(AppTheme.Text.primary)

            Spacer(minLength: 0)

            Image(systemName: "square.and.pencil")
                .font(AppTheme.font(.footnote, .semibold))
                .foregroundColor(AppTheme.Text.muted)
        }
        .padding(.horizontal, AppTheme.Spacing.x3)
        .frame(height: 32)
        .background(AppTheme.Surface.control.opacity(0.48))
    }

    private var trafficLights: some View {
        HStack(spacing: AppTheme.Spacing.x1) {
            Circle()
                .fill(AppTheme.Status.error.opacity(0.78))
            Circle()
                .fill(AppTheme.Status.warningStrong.opacity(0.78))
            Circle()
                .fill(AppTheme.Status.positive.opacity(0.78))
        }
        .frame(width: 42, height: 10)
    }

    private var notesTextArea: some View {
        ZStack(alignment: .topLeading) {
            if text.isEmpty {
                Text(LocalizedStringKey(step.fieldPlaceholder))
                    .font(AppTheme.font(.body))
                    .foregroundColor(AppTheme.Text.muted)
                    .padding(editorTextInset)
                    .allowsHitTesting(false)
            }

            editor
        }
        .padding(.horizontal, AppTheme.Spacing.x3)
        .padding(.vertical, AppTheme.Spacing.x3)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var transformArrow: some View {
        Image(systemName: "arrow.right")
            .font(AppTheme.font(.headline, .semibold))
            .foregroundColor(AppTheme.Text.muted)
            .frame(width: 46)
    }

    private var respondStage: some View {
        panelShell(kicker: step.sampleLabel, height: 150) {
            Text(LocalizedStringKey(step.sampleText))
                .font(AppTheme.font(.title, .medium))
                .foregroundColor(AppTheme.Text.primary)
                .lineSpacing(5)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: 460)
    }

    private func panelShell<Content: View>(
        kicker: String,
        height: CGFloat? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.x3) {
            Text(LocalizedStringKey(kicker))
                .font(AppTheme.font(.caption, .semibold))
                .textCase(.uppercase)
                .tracking(1.0)
                .foregroundColor(AppTheme.Text.muted)

            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(AppTheme.Spacing.x4)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .frame(height: height ?? panelHeight)
        .background(AppTheme.Surface.control.opacity(0.45))
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.panel, style: .continuous))
    }

    @ViewBuilder
    private var editor: some View {
        OnboardingLockedTextEditor(
            text: $text,
            isEnabled: hasShortcut,
            isFocused: $isFieldFocused
        )
        .padding(editorTextInset)
    }

    private func focusFieldIfReady() {
        guard hasShortcut else {
            isFieldFocused = false
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            isFieldFocused = true
        }
    }

    private var fieldBorderColor: Color {
        isFieldFocused ? AppTheme.Accent.border : AppTheme.Border.subtle
    }
}

private struct OnboardingExperienceInstruction: View {
    let step: OnboardingExperienceStep
    let shortcutAction: ShortcutAction
    let hasShortcut: Bool
    let onShortcutChanged: () -> Void

    var body: some View {
        line
            .frame(maxWidth: .infinity)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var line: some View {
        VStack(alignment: .center, spacing: AppTheme.Spacing.x3) {
            instructionText(hasShortcut ? step.configuredInstruction : "Choose a shortcut to get started.")
            shortcutControl
        }
    }

    private var shortcutControl: some View {
        OnboardingShortcutSetupView(
            action: shortcutAction,
            onShortcutChanged: onShortcutChanged
        )
    }

    private func instructionText(_ value: String) -> some View {
        Text(LocalizedStringKey(value))
            .font(AppTheme.font(.headline, .medium))
            .foregroundColor(AppTheme.Text.primary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
