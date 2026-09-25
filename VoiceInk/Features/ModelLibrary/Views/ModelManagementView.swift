import AppKit
import SwiftUI

enum ModelFilter: String, CaseIterable, Identifiable {
    case cloud = "Cloud"
    case custom = "Custom"

    var id: String { self.rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .cloud:
            return "Cloud"
        case .custom:
            return "Custom"
        }
    }
}

struct ModelManagementView: View {
    @EnvironmentObject private var aiService: AIService
    @EnvironmentObject private var transcriptionModelManager: TranscriptionModelManager
    @StateObject private var customModelManager = CustomCloudModelManager.shared
    @StateObject private var customAIProviderManager = CustomAIProviderManager.shared

    @State private var selectedFilter: ModelFilter = .cloud
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
            headerSection

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    availableModelsSection
                }
                .padding(.horizontal, 24)
                .padding(.top, 18)
                .padding(.bottom, 28)
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
        VStack(alignment: .leading, spacing: 16) {
            modelFilterPicker

            switch selectedFilter {
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
        HStack(spacing: 12) {
            ForEach(ModelFilter.allCases, id: \.self) { filter in
                Button(action: {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                        selectedFilter = filter
                    }
                    activePanel = nil
                }) {
                    Text(filter.title)
                        .font(.system(size: 14, weight: selectedFilter == filter ? .semibold : .medium))
                        .foregroundColor(selectedFilter == filter ? .primary : .primary.opacity(0.7))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(
                            AppMaterialCardBackground(isSelected: selectedFilter == filter, cornerRadius: 22)
                        )
                }
                .buttonStyle(PlainButtonStyle())
            }
        }
        .padding(.bottom, 8)
    }

    private var settingsButton: some View {
        AppIconButton(
            systemName: "gearshape.fill",
            help: "Model Settings"
        ) {
            toggleSettingsPanel()
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
}
