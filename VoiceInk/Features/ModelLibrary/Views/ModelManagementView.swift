import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum ModelFilter: String, CaseIterable, Identifiable {
    case local = "Local"
    case cloud = "Cloud"
    case custom = "Custom"

    var id: String { self.rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .local:
            return "Local"
        case .cloud:
            return "Cloud"
        case .custom:
            return "Custom"
        }
    }
}

struct ModelManagementView: View {
    @EnvironmentObject private var aiService: AIService
    @EnvironmentObject private var whisperModelManager: WhisperModelManager
    @EnvironmentObject private var transcriptionModelManager: TranscriptionModelManager
    @StateObject private var customModelManager = CustomCloudModelManager.shared
    @StateObject private var customAIProviderManager = CustomAIProviderManager.shared
    @ObservedObject private var warmupCoordinator = WhisperModelWarmupCoordinator.shared
    private let voiceInkRefineService = VoiceInkRefineService.shared

    @State private var selectedFilter: ModelFilter = .local
    @State private var activePanel: ModelManagementPanel?

    @State private var isShowingDeleteAlert = false
    @State private var alertTitle = ""
    @State private var alertMessage = ""
    @State private var deleteActionClosure: () -> Void = {}

    private enum ModelManagementPanel {
        case settings
        case cloudProvider(ProviderDescriptor)
        case customTranscriptionModel(CustomCloudModel?)
        case customEnhancementModel(CustomAIProviderConfig?)
    }

    private var isSettingsPanelOpen: Bool {
        if case .settings? = activePanel { return true }
        return false
    }

    private var isPanelOpen: Bool {
        activePanel != nil
    }

    private var selectedCloudProviderID: String? {
        if case .cloudProvider(let descriptor)? = activePanel {
            return descriptor.id
        }
        return nil
    }

    private func closePanel() {
        activePanel = nil
    }

    private func toggleSettingsPanel() {
        activePanel = isSettingsPanelOpen ? nil : .settings
    }

    private func openCloudProviderPanel(_ descriptor: ProviderDescriptor) {
        activePanel = .cloudProvider(descriptor)
    }

    private func openCustomTranscriptionModelPanel(_ model: CustomCloudModel? = nil) {
        activePanel = .customTranscriptionModel(model)
    }

    private func openCustomEnhancementModelPanel(_ provider: CustomAIProviderConfig? = nil) {
        activePanel = .customEnhancementModel(provider)
    }

    var body: some View {
        VStack(spacing: 0) {
            #if DEBUG
                // make ui-snapshots: open a tab or panel before the frame is captured.
                Color.clear.frame(height: 0).onAppear(perform: applySnapshotOverrides)
            #endif
            headerSection

            ScrollView {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.x5) {
                    if SystemArchitecture.isIntelMac {
                        intelMacWarningBanner
                    }

                    availableModelsSection
                }
                .padding(.horizontal, AppTheme.Spacing.x6)
                .padding(.top, AppTheme.Spacing.x5)
                .padding(.bottom, AppTheme.Spacing.x8)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 600, minHeight: 500)
        .sidePanel(
            isPresented: .init(
                get: { isPanelOpen },
                set: { if !$0 { closePanel() } }
            )
        ) {
            modelPanelContent
        }
        .alert(isPresented: $isShowingDeleteAlert) {
            Alert(
                title: Text(alertTitle),
                message: Text(alertMessage),
                primaryButton: .destructive(Text("Delete"), action: deleteActionClosure),
                secondaryButton: .cancel()
            )
        }
    }

    private var headerSection: some View {
        AppScreenHeader(title: "Model Catalog") {
            settingsButton
        }
    }

    @ViewBuilder
    private var modelPanelContent: some View {
        switch activePanel {
        case .settings:
            settingsPanelContent
        case .cloudProvider(let descriptor):
            ProviderDetailPanel(descriptor: descriptor, onClose: closePanel)
                .environmentObject(aiService)
                .environmentObject(transcriptionModelManager)
                .id(descriptor.id)
        case .customTranscriptionModel(let model):
            CustomTranscriptionModelEditorPanel(
                editingModel: model,
                customModelManager: customModelManager,
                onClose: closePanel,
                onSave: {
                    transcriptionModelManager.refreshAllAvailableModels()
                    closePanel()
                }
            )
        case .customEnhancementModel(let provider):
            CustomEnhancementModelEditorPanel(
                editingProvider: provider,
                manager: customAIProviderManager,
                onClose: closePanel,
                onSave: closePanel
            )
        case nil:
            EmptyView()
        }
    }

    private var settingsPanelContent: some View {
        VStack(spacing: 0) {
            AppPanelHeader(title: "Model Settings", onClose: closePanel)

            ModelSettingsPanel()
        }
    }

    private var availableModelsSection: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.x4) {
            modelFilterPicker

            switch selectedFilter {
            case .local:
                localModelsSection
            case .cloud:
                CloudProviderManagementView(
                    selectedProviderID: selectedCloudProviderID,
                    onSelectProvider: openCloudProviderPanel
                )
                .environmentObject(aiService)
                .environmentObject(transcriptionModelManager)
            case .custom:
                CustomProviderManagementView(
                    customModelManager: customModelManager,
                    customAIProviderManager: customAIProviderManager,
                    onAddTranscriptionModel: {
                        openCustomTranscriptionModelPanel()
                    },
                    onEditTranscriptionModel: { model in
                        openCustomTranscriptionModelPanel(model)
                    },
                    onDeleteTranscriptionModel: { model in
                        confirmDeleteCustomModel(model)
                    },
                    onAddEnhancementModel: {
                        openCustomEnhancementModelPanel()
                    },
                    onEditEnhancementModel: { provider in
                        openCustomEnhancementModelPanel(provider)
                    },
                    onDeleteEnhancementModel: { provider in
                        confirmDeleteCustomEnhancementModel(provider)
                    }
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var modelFilterPicker: some View {
        HStack(spacing: AppTheme.Spacing.x3) {
            ForEach(ModelFilter.allCases, id: \.self) { filter in
                Button(action: {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                        selectedFilter = filter
                    }
                    activePanel = nil
                }) {
                    Text(filter.title)
                        .font(AppTheme.font(.callout, selectedFilter == filter ? .semibold : .medium))
                        .foregroundColor(selectedFilter == filter ? .primary : .primary.opacity(0.7))
                        .padding(.horizontal, AppTheme.Spacing.x4)
                        .padding(.vertical, AppTheme.Spacing.x2)
                        .background(
                            AppMaterialCardBackground(isSelected: selectedFilter == filter, cornerRadius: AppTheme.Radius.pill)
                        )
                }
                .buttonStyle(PlainButtonStyle())
            }
        }
        .padding(.bottom, AppTheme.Spacing.x2)
    }

    private var settingsButton: some View {
        AppIconButton(
            systemName: "gearshape.fill",
            help: "Model Settings"
        ) {
            toggleSettingsPanel()
        }
    }

    private var localModelsSection: some View {
        VStack(spacing: AppTheme.Spacing.x3) {
            VoiceInkRefineModelCardView(
                service: voiceInkRefineService,
                deleteAction: deleteVoiceInkRefineModel
            )

            ForEach(appleSpeechModels, id: \.id) { model in
                localModelCard(model)
            }

            ForEach(downloadableLocalModels, id: \.id) { model in
                localModelCard(model)
            }

            importLocalModelButton

            LocalEnhancementServiceManagementView()
                .environmentObject(aiService)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func localModelCard(_ model: any TranscriptionModel) -> some View {
        let isWarming =
            (model as? WhisperModel).map { whisperModel in
                warmupCoordinator.isWarming(modelNamed: whisperModel.name)
            } ?? false

        return ModelCardView(
            model: model,
            isDownloaded: whisperModelManager.availableModels.contains { $0.name == model.name },
            downloadProgress: whisperModelManager.downloadProgress,
            modelURL: whisperModelManager.availableModels.first { $0.name == model.name }?.url,
            isWarming: isWarming,
            deleteAction: {
                deleteLocalModel(model)
            },
            downloadAction: {
                if let whisperModel = model as? WhisperModel {
                    whisperModelManager.startDownload(whisperModel)
                }
            },
            cancelDownloadAction: {
                if let whisperModel = model as? WhisperModel {
                    whisperModelManager.cancelDownload(whisperModel)
                }
            }
        )
    }

    private var importLocalModelButton: some View {
        HStack(spacing: AppTheme.Spacing.x2) {
            Button(action: { presentImportPanel() }) {
                HStack(spacing: AppTheme.Spacing.x2) {
                    Image(systemName: "square.and.arrow.down")
                    Text("Import Local Model…")
                        .font(AppTheme.font(.footnote, .semibold))
                }
                .frame(maxWidth: .infinity)
                .padding(AppTheme.Spacing.x4)
                .background(AppMaterialCardBackground(cornerRadius: AppTheme.Radius.control))
            }
            .buttonStyle(.plain)

            InfoTip(
                "Add a custom fine-tuned whisper model to use with Yap. Select the downloaded .bin file."
            )
        }
    }

    private var intelMacWarningBanner: some View {
        HStack(spacing: AppTheme.Spacing.x3) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(AppTheme.font(.callout, .semibold))
                .foregroundColor(AppTheme.Status.warningStrong)

            Text("Local models don't work reliably on Intel Macs")
                .font(AppTheme.font(.body, .medium))
                .foregroundColor(.primary.opacity(0.85))

            Spacer()

            Button(action: {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    selectedFilter = .cloud
                }
            }) {
                HStack(spacing: AppTheme.Spacing.x1) {
                    Text("Use Cloud")
                        .font(AppTheme.font(.footnote, .semibold))
                    Image(systemName: "arrow.right")
                        .font(AppTheme.font(.micro, .semibold))
                }
                .foregroundColor(AppTheme.Status.warningStrong)
                .padding(.horizontal, AppTheme.Spacing.x3)
                .padding(.vertical, AppTheme.Spacing.x2)
                .background(AppTheme.Status.warningStrong.opacity(0.12))
                .cornerRadius(AppTheme.Radius.small)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, AppTheme.Spacing.x4)
        .padding(.vertical, AppTheme.Spacing.x3)
        .background(AppTheme.Status.warningStrong.opacity(0.08))
        .cornerRadius(AppTheme.Radius.control)
    }

    private var localModels: [any TranscriptionModel] {
        transcriptionModelManager.allAvailableModels.filter {
            ($0.provider == .whisper || $0.provider == .nativeApple || $0.provider == .fluidAudio
                || $0.provider == .transcribeCpp)
                && transcriptionModelManager.isAvailableOnCurrentOS($0)
        }
    }

    private var appleSpeechModels: [any TranscriptionModel] {
        localModels.filter { $0.provider == .nativeApple }
    }

    private var downloadableLocalModels: [any TranscriptionModel] {
        localModels.filter { $0.provider != .nativeApple }
    }

    private func deleteLocalModel(_ model: any TranscriptionModel) {
        guard let downloadedModel = whisperModelManager.availableModels.first(where: { $0.name == model.name }) else {
            return
        }

        Task {
            await whisperModelManager.deleteModel(downloadedModel)
        }
    }

    private func confirmDeleteCustomModel(_ model: CustomCloudModel) {
        alertTitle = String(localized: "Delete Custom Model")
        alertMessage = String(
            format: String(localized: "Are you sure you want to delete the custom model '%@'?"),
            model.displayName
        )
        deleteActionClosure = {
            customModelManager.removeCustomModel(withId: model.id)
            transcriptionModelManager.refreshAllAvailableModels()
        }
        isShowingDeleteAlert = true
    }

    private func deleteVoiceInkRefineModel() {
        Task {
            await voiceInkRefineService.deleteModel()
        }
    }

    private func confirmDeleteCustomEnhancementModel(_ provider: CustomAIProviderConfig) {
        alertTitle = String(localized: "Delete Custom Enhancement Model")
        alertMessage = String(
            format: String(localized: "Are you sure you want to delete the custom enhancement model '%@'?"),
            provider.name
        )
        deleteActionClosure = {
            customAIProviderManager.deleteProvider(provider)
        }
        isShowingDeleteAlert = true
    }

    private func presentImportPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.init(filenameExtension: "bin")!]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.resolvesAliases = true
        panel.title = String(localized: "Select a Whisper ggml .bin model")
        if panel.runModal() == .OK, let url = panel.url {
            Task { @MainActor in
                await whisperModelManager.importWhisperModel(from: url)
            }
        }
    }
}

#if DEBUG
    extension ModelManagementView {
        enum SnapshotPanel { case customProviderEditor }
        @MainActor static var snapshotFilter: ModelFilter?
        @MainActor static var snapshotPanel: SnapshotPanel?

        private func applySnapshotOverrides() {
            if let filter = Self.snapshotFilter { selectedFilter = filter }
            if Self.snapshotPanel == .customProviderEditor {
                openCustomEnhancementModelPanel(customAIProviderManager.providers.first)
            }
        }
    }
#endif
