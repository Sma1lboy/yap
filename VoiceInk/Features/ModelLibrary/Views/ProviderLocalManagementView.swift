import AppKit
import SwiftUI

struct LocalEnhancementServiceManagementView: View {
    @EnvironmentObject private var aiService: AIService

    @State private var isOllamaExpanded = false
    @State private var isLocalCLIExpanded = false
    @State private var ollamaBaseURL = UserDefaults.standard.string(forKey: "ollamaBaseURL") ?? "http://localhost:11434"
    @State private var selectedOllamaModel = UserDefaults.standard.string(forKey: "ollamaSelectedModel") ?? "mistral"
    @State private var ollamaUserRefreshError: String?
    @State private var localCLICommandTemplate = ""
    @State private var localCLITimeoutSeconds = LocalCLIService.defaultTimeoutSeconds
    @State private var isSyncingLocalCLIState = false

    private var isLocalCLIConfigured: Bool {
        !localCLICommandTemplate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.x3) {
            ProviderSectionHeader(
                title: "Local Enhancement Services",
                subtitle: "Connect Ollama or configure a CLI command for local enhancement."
            )
            .padding(.top, AppTheme.Spacing.x2)

            VStack(spacing: 0) {
                LocalProviderDisclosureRow(
                    title: Text(verbatim: "Ollama"),
                    subtitle: ollamaModelNames.isEmpty ? Text("Local server") : Text(localModelCountLabel),
                    systemImage: "server.rack",
                    statusTitle: ollamaStatusTitle,
                    isExpanded: $isOllamaExpanded
                ) {
                    ollamaConfiguration
                }

                Divider()
                    .padding(.leading, 58)  // design-exempt: layout offset, not spacing

                LocalProviderDisclosureRow(
                    title: Text("CLI Provider"),
                    subtitle: Text("Claude, Codex, scripts, or any command"),
                    systemImage: "terminal",
                    statusTitle: isLocalCLIConfigured ? Text("Configured") : Text("Not configured"),
                    isExpanded: $isLocalCLIExpanded
                ) {
                    localCLIConfiguration
                }
            }
            .background(AppMaterialCardBackground(cornerRadius: AppTheme.Radius.control))
        }
        .onAppear {
            selectedOllamaModel = aiService.selectedModel(for: .ollama)
            syncLocalCLIStateFromService()
        }
    }

    private var ollamaModelNames: [String] {
        aiService.availableModels(for: .ollama)
    }

    private var localModelCountLabel: String {
        let count = ollamaModelNames.count
        return String(localized: "\(count) models")
    }

    private var ollamaStatusTitle: Text {
        if aiService.isOllamaRefreshing {
            return Text("Checking")
        }

        if !aiService.connectedProviders.contains(.ollama) {
            return Text("Disconnected")
        }

        return ollamaModelNames.isEmpty ? Text("No models") : Text(localModelCountLabel)
    }

    private var ollamaActionTitle: LocalizedStringKey {
        aiService.connectedProviders.contains(.ollama) ? "Refresh" : "Connect"
    }

    private var ollamaConfiguration: some View {
        LocalProviderExpandedContent {
            LocalProviderFormRow(title: "Server") {
                HStack(spacing: AppTheme.Spacing.x2) {
                    TextField("", text: $ollamaBaseURL, prompt: Text(verbatim: "http://localhost:11434"))
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 320)
                        .disabled(aiService.isOllamaRefreshing)
                        .onChange(of: ollamaBaseURL) { _, _ in
                            ollamaUserRefreshError = nil
                        }

                    Button {
                        ollamaUserRefreshError = nil
                        aiService.updateOllamaBaseURL(ollamaBaseURL)
                        checkOllamaConnectionFromUserAction()
                    } label: {
                        if aiService.isOllamaRefreshing {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Text(ollamaActionTitle)
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(aiService.isOllamaRefreshing)
                }
            }

            if let ollamaUserRefreshError {
                Text(ollamaUserRefreshError)
                    .font(.caption)
                    .foregroundStyle(AppTheme.Status.error)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, LocalProviderMetrics.labelWidth + 12)
            }

            if !ollamaModelNames.isEmpty {
                Divider()
                    .padding(.leading, LocalProviderMetrics.labelWidth + 12)

                LocalProviderFormRow(title: "Model") {
                    Picker("Model", selection: $selectedOllamaModel) {
                        ForEach(ollamaModelNames, id: \.self) { model in
                            Text(model).tag(model)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .frame(maxWidth: 320, alignment: .leading)
                    .onChange(of: selectedOllamaModel) { _, newValue in
                        aiService.updateSelectedOllamaModel(newValue)
                        aiService.selectModel(newValue, for: .ollama)
                    }
                }
            }
        }
    }

    private var localCLIConfiguration: some View {
        LocalProviderExpandedContent {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.x2) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Command")
                        .font(AppTheme.font(.footnote, .medium))
                        .foregroundStyle(.secondary)

                    Spacer()

                    Menu {
                        ForEach(LocalCLITemplate.allCases) { template in
                            Button(template.displayName) {
                                aiService.loadLocalCLITemplate(template)
                                syncLocalCLIStateFromService()
                            }
                        }
                    } label: {
                        Label("Template", systemImage: "doc.on.doc")
                            .font(AppTheme.font(.footnote, .medium))
                    }
                    .menuStyle(.button)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                TextEditor(text: $localCLICommandTemplate)
                    .font(AppTheme.font(.footnote, .regular, design: .monospaced))
                    .frame(minHeight: 88)
                    .scrollContentBackground(.hidden)
                    .padding(AppTheme.Spacing.x2)
                    .background(Color(NSColor.textBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.small))
                    .overlay(
                        RoundedRectangle(cornerRadius: AppTheme.Radius.small)
                            .stroke(AppTheme.Border.control.opacity(0.4), lineWidth: 1)
                    )
                    .onChange(of: localCLICommandTemplate) { _, newValue in
                        guard !isSyncingLocalCLIState else { return }
                        aiService.updateLocalCLICommandTemplate(newValue)
                    }
            }

            Divider()
                .padding(.leading, LocalProviderMetrics.labelWidth + 12)

            LocalProviderFormRow(title: "Timeout") {
                Picker("Timeout", selection: $localCLITimeoutSeconds) {
                    Text("15s").tag(15.0)
                    Text("30s").tag(30.0)
                    Text("45s").tag(45.0)
                    Text("60s").tag(60.0)
                    Text("90s").tag(90.0)
                    Text("120s").tag(120.0)
                    Text("180s").tag(180.0)
                    Text("300s").tag(300.0)
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(width: 110, alignment: .leading)
                .onChange(of: localCLITimeoutSeconds) { _, newValue in
                    aiService.updateLocalCLITimeoutSeconds(newValue)
                }
            }

            Text("Variables: YAP_SYSTEM_PROMPT, YAP_USER_PROMPT, YAP_FULL_PROMPT")
                .font(AppTheme.font(.caption, .regular, design: .monospaced))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, AppTheme.Spacing.half)
        }
    }

    private func checkOllamaConnectionFromUserAction() {
        Task { @MainActor in
            let result = await aiService.refreshOllamaAvailability()
            let models = result.models.map(\.name)

            ollamaUserRefreshError = result.errorMessage

            if !models.contains(selectedOllamaModel), let firstModel = models.first {
                selectedOllamaModel = firstModel
                aiService.selectModel(firstModel, for: .ollama)
            }
        }
    }

    private func syncLocalCLIStateFromService() {
        isSyncingLocalCLIState = true
        localCLICommandTemplate = aiService.localCLICommandTemplate
        localCLITimeoutSeconds = aiService.localCLITimeoutSeconds
        DispatchQueue.main.async {
            isSyncingLocalCLIState = false
        }
    }
}

private enum LocalProviderMetrics {
    static let labelWidth: CGFloat = 72
}

private struct LocalProviderDisclosureRow<Content: View>: View {
    let title: Text
    let subtitle: Text
    let systemImage: String
    let statusTitle: Text
    @Binding var isExpanded: Bool
    let content: () -> Content

    init(
        title: Text,
        subtitle: Text,
        systemImage: String,
        statusTitle: Text,
        isExpanded: Binding<Bool>,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.statusTitle = statusTitle
        self._isExpanded = isExpanded
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.smooth(duration: 0.18)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: AppTheme.Spacing.x3) {
                    Image(systemName: systemImage)
                        .font(AppTheme.font(.callout, .medium))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.secondary)
                        .frame(width: 30, height: 30)
                        .background(
                            RoundedRectangle(cornerRadius: AppTheme.Radius.small)
                                .fill(AppTheme.Surface.control)
                                .overlay(
                                    RoundedRectangle(cornerRadius: AppTheme.Radius.small)
                                        .stroke(AppTheme.Border.control.opacity(0.3), lineWidth: 1)
                                )
                        )

                    VStack(alignment: .leading, spacing: AppTheme.Spacing.half) {
                        title
                            .font(AppTheme.font(.body, .semibold))
                            .foregroundStyle(.primary)

                        subtitle
                            .font(AppTheme.font(.caption))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 12)

                    statusTitle
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    Image(systemName: "chevron.right")
                        .font(AppTheme.font(.caption, .semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .contentShape(Rectangle())
                .padding(.horizontal, AppTheme.Spacing.x4)
                .padding(.vertical, AppTheme.Spacing.x3)
            }
            .buttonStyle(.plain)

            if isExpanded {
                Divider()
                    .padding(.leading, 58)  // design-exempt: layout offset, not spacing

                content()
                    .padding(.horizontal, AppTheme.Spacing.x4)
                    .padding(.top, AppTheme.Spacing.x3)
                    .padding(.bottom, AppTheme.Spacing.x4)
                    .transition(.opacity)
            }
        }
    }
}

private struct LocalProviderExpandedContent<Content: View>: View {
    let content: () -> Content

    init(@ViewBuilder content: @escaping () -> Content) {
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.x3) {
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct LocalProviderFormRow<Content: View>: View {
    let title: LocalizedStringKey
    let content: () -> Content

    init(title: LocalizedStringKey, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.content = content
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: AppTheme.Spacing.x3) {
            Text(title)
                .font(AppTheme.font(.footnote, .medium))
                .foregroundStyle(.secondary)
                .frame(width: LocalProviderMetrics.labelWidth, alignment: .leading)

            content()

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
