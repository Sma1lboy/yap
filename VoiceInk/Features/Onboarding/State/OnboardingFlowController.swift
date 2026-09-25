import Carbon
import SwiftUI

@MainActor
final class OnboardingFlowController {
    private unowned let coordinator: OnboardingCoordinator

    init(coordinator: OnboardingCoordinator) {
        self.coordinator = coordinator
    }

    func goToPermissionsStep() {
        coordinator.storedStage = OnboardingStage.permissions.rawValue
    }

    func goToMicrophoneStep() {
        guard coordinator.requiredPermissionsGranted else { return }
        coordinator.storedStage = OnboardingStage.microphone.rawValue
    }

    func goToModelStep() {
        guard coordinator.requiredPermissionsGranted,
            coordinator.hasSelectedOnboardingMicrophone
        else { return }
        if coordinator.restoredFromCloud {
            continueAfterRestore()
        } else {
            coordinator.storedStage = OnboardingStage.model.rawValue
        }
    }

    /// The first screen's "Sign in and restore settings" finished. When the config covers provider and modes,
    /// the model and practice steps are skipped; the AI key step stays only for a provider missing its key.
    func didRestoreFromCloud(_ config: YapConfig) {
        coordinator.restoreProviderNames = config.providerNames
        coordinator.restoredFromCloud = config.coversOnboardingSetup
    }

    /// Past the permission steps after a restore: the AI key step with the config's provider preselected while a
    /// key is missing (and wasn't explicitly skipped), else the last step.
    private func continueAfterRestore() {
        if !coordinator.hasSkippedAPISetup, let provider = coordinator.restoreProviderMissingKey {
            coordinator.storedOnboardingAIProvider = provider.rawValue
            refreshAPIVerification()
            coordinator.storedStage = OnboardingStage.api.rawValue
        } else {
            coordinator.storedStage = OnboardingStage.trust.rawValue
        }
    }

    func goToAPIStep(
        isTranscriptionSetupReady: Bool,
        aiService: AIService
    ) {
        guard coordinator.requiredPermissionsGranted,
            coordinator.hasSelectedOnboardingMicrophone,
            isTranscriptionSetupReady
        else { return }
        coordinator.hasSkippedTranscriptionSetup = false
        coordinator.usedRecommendedSetup = false
        ensureDefaultOnboardingProvider()
        selectOnboardingProvider(coordinator.selectedOnboardingProvider, aiService: aiService)
        coordinator.storedStage = OnboardingStage.api.rawValue
    }

    /// Verifies and saves `newKey` (nil reuses the stored OpenRouter key), applies the recommended preset and
    /// goes straight to the practice steps: the same key covers cleanup, so the AI key step is skipped.
    /// Returns an error message to show, or nil on success.
    func applyRecommendedSetup(newKey: String?, enhancementService: AIEnhancementService) async -> String? {
        guard coordinator.requiredPermissionsGranted, coordinator.hasSelectedOnboardingMicrophone else { return nil }
        let providerKey = AIProvider.openRouter.rawValue
        if let newKey {
            let result = await OpenRouterProvider().verifyAPIKey(newKey)
            guard result.isValid else {
                return result.errorMessage
                    ?? String(localized: "Could not verify this API key. Check the key and your internet connection, then try again.")
            }
            guard APIKeyManager.shared.saveAPIKey(newKey, forProvider: providerKey) else {
                return String(localized: "The key worked, but Yap could not save it securely.")
            }
        }
        guard let key = APIKeyManager.shared.getAPIKey(forProvider: providerKey) else {
            return String(localized: "Paste your OpenRouter API key to continue.")
        }

        await finishPreset(
            .recommended(openRouterKey: key), kind: .recommended, providerKey: providerKey,
            enhancementService: enhancementService)
        return nil
    }

    /// "Use Yap Cloud": same models and prompt as Recommended, billed to the signed-in Yap Cloud account.
    func applyYapCloudSetup(enhancementService: AIEnhancementService) async -> String? {
        guard coordinator.requiredPermissionsGranted, coordinator.hasSelectedOnboardingMicrophone else { return nil }
        guard YapCloud.shared.token != nil else {
            return String(localized: "Sign in to Yap Cloud to continue.")
        }
        guard let model = coordinator.selectedOnboardingTranscriptionModel else {
            return String(localized: "Yap Cloud has no transcription models available right now.")
        }
        await finishPreset(
            .yapCloud(transcriptionModel: model.name), kind: .yapCloud, providerKey: YapCloud.providerName,
            enhancementService: enhancementService)
        return nil
    }

    /// Applies a one-account preset and skips the AI key step, since the same account covers cleanup.
    private func finishPreset(
        _ config: YapConfig, kind: OnboardingTranscriptionSetupKind, providerKey: String,
        enhancementService: AIEnhancementService
    ) async {
        await YapConfigLoader.shared.apply(config: config, source: .recommended, patchModes: false)
        NotificationCenter.default.post(name: .aiProviderKeyChanged, object: nil)

        coordinator.storedTranscriptionSetupKind = kind.rawValue
        coordinator.usedRecommendedSetup = true
        coordinator.hasSkippedTranscriptionSetup = false
        coordinator.hasSkippedAPISetup = false
        coordinator.storedOnboardingTranscriptionProvider = providerKey
        coordinator.storedOnboardingAIProvider = providerKey
        refreshTranscriptionSetupVerification()
        refreshAPIVerification()
        goToExperienceStep(
            isTranscriptionSetupReady: coordinator.isTranscriptionSetupReady(isTranscriptionModelDownloaded: false),
            enhancementService: enhancementService
        )
    }

    /// The step before the practice steps: the AI key step, or the model step when the preset covered it.
    private var stageBeforeExperience: OnboardingStage {
        coordinator.usedRecommendedSetup ? .model : .api
    }

    func goBackToModelStep() {
        guard coordinator.requiredPermissionsGranted else {
            goToPermissionsStep()
            return
        }

        if coordinator.restoredFromCloud {
            coordinator.storedStage = OnboardingStage.microphone.rawValue
            return
        }

        coordinator.storedStage = OnboardingStage.model.rawValue
    }

    func goToExperienceStep(
        isTranscriptionSetupReady: Bool,
        enhancementService: AIEnhancementService
    ) {
        guard coordinator.isReadyForExperience(isTranscriptionSetupReady: isTranscriptionSetupReady) else { return }
        // After a restore the AI key step leads to the next missing key or the last step, not the practice steps.
        if coordinator.restoredFromCloud {
            continueAfterRestore()
            return
        }
        coordinator.storedStage = OnboardingStage.experience.rawValue
        moveToExperienceStep(0, enhancementService: enhancementService)
    }

    func goToContextAwarenessStep(isTranscriptionSetupReady: Bool) {
        guard coordinator.isReadyForExperience(isTranscriptionSetupReady: isTranscriptionSetupReady),
            coordinator.shouldShowContextAwarenessAfterCurrentExperience
        else {
            return
        }

        activateCleanTranscriptionMode()
        coordinator.storedStage = OnboardingStage.contextAwareness.rawValue
    }

    func goToTrustStep(isTranscriptionSetupReady: Bool) {
        guard coordinator.isReadyForExperience(isTranscriptionSetupReady: isTranscriptionSetupReady) else { return }
        coordinator.storedStage = OnboardingStage.trust.rawValue
    }

    func requestSkipTranscriptionSetup() {
        coordinator.isShowingSkipTranscriptionSetupWarning = true
    }

    /// Experience steps need working dictation, so skipping transcription jumps straight to the trust step.
    func skipTranscriptionSetupAndContinue() {
        guard coordinator.requiredPermissionsGranted,
            coordinator.hasSelectedOnboardingMicrophone
        else { return }
        coordinator.hasSkippedTranscriptionSetup = true
        coordinator.usedRecommendedSetup = false
        coordinator.storedStage = OnboardingStage.trust.rawValue
    }

    func requestSkipAPISetup() {
        coordinator.isShowingSkipAPISetupWarning = true
    }

    func skipAPISetupAndContinue(
        isTranscriptionSetupReady: Bool,
        enhancementService: AIEnhancementService
    ) {
        coordinator.hasSkippedAPISetup = true
        coordinator.isSelectedAPIProviderVerified = false
        goToExperienceStep(
            isTranscriptionSetupReady: isTranscriptionSetupReady,
            enhancementService: enhancementService
        )
    }

    func goToExperiencePracticePhase() {
        withAnimation(.easeInOut(duration: 0.28)) {
            coordinator.isExperienceInIntroPhase = false
        }
    }

    func goToExperienceIntroPhase() {
        guard !coordinator.shouldSkipCurrentExperienceIntro else { return }

        withAnimation(.easeInOut(duration: 0.28)) {
            coordinator.isExperienceInIntroPhase = true
        }
    }

    func goBackFromExperiencePractice(enhancementService: AIEnhancementService) {
        if coordinator.shouldSkipCurrentExperienceIntro {
            goToPreviousExperienceStep(enhancementService: enhancementService)
        } else {
            goToExperienceIntroPhase()
        }
    }

    func goToPreviousExperienceStep(enhancementService: AIEnhancementService) {
        if coordinator.shouldShowContextAwarenessBeforeCurrentExperience {
            coordinator.experienceStepIndex = coordinator.normalizedExperienceStepIndex - 1
            activateCleanTranscriptionMode()
            coordinator.storedStage = OnboardingStage.contextAwareness.rawValue
            return
        }

        if coordinator.normalizedExperienceStepIndex > 0 {
            moveToExperienceStep(
                coordinator.normalizedExperienceStepIndex - 1,
                enhancementService: enhancementService
            )
        } else {
            coordinator.storedStage = stageBeforeExperience.rawValue
        }
    }

    func goToPreviousContextAwarenessStep(enhancementService: AIEnhancementService) {
        coordinator.storedStage = OnboardingStage.experience.rawValue
        coordinator.isExperienceInIntroPhase = false
        installCurrentExperienceMode(enhancementService: enhancementService)
        activateExperienceModeForDemo()
        refreshExperienceModeState(enhancementService: enhancementService)
    }

    func continueFromContextAwarenessStep(enhancementService: AIEnhancementService) {
        let nextIndex = coordinator.normalizedExperienceStepIndex + 1
        guard coordinator.activeExperienceSteps.indices.contains(nextIndex) else {
            coordinator.storedStage = OnboardingStage.trust.rawValue
            return
        }

        coordinator.storedStage = OnboardingStage.experience.rawValue
        moveToExperienceStep(nextIndex, enhancementService: enhancementService)
    }

    func goToPreviousTrustStep(
        isTranscriptionSetupReady: Bool,
        enhancementService: AIEnhancementService
    ) {
        if coordinator.hasSkippedTranscriptionSetup {
            coordinator.hasSkippedTranscriptionSetup = false
            coordinator.storedStage = OnboardingStage.model.rawValue
            return
        }

        if coordinator.restoredFromCloud {
            coordinator.storedStage = OnboardingStage.microphone.rawValue
            return
        }

        guard coordinator.isReadyForExperience(isTranscriptionSetupReady: isTranscriptionSetupReady) else {
            coordinator.storedStage = stageBeforeExperience.rawValue
            return
        }

        let previousIndex = max(coordinator.activeExperienceSteps.count - 1, 0)
        coordinator.experienceStepIndex = previousIndex
        coordinator.isExperienceInIntroPhase = false

        // Mirrors the forward path back through Context Awareness.
        if coordinator.activeExperienceSteps.last?.showsContextAwarenessAfterCompletion == true {
            activateCleanTranscriptionMode()
            coordinator.storedStage = OnboardingStage.contextAwareness.rawValue
            return
        }

        coordinator.storedStage = OnboardingStage.experience.rawValue
        installExperienceMode(at: previousIndex, enhancementService: enhancementService)
        activateExperienceModeForDemo()
        refreshExperienceModeState(enhancementService: enhancementService)
    }

    func advanceExperienceStep(
        isTranscriptionSetupReady: Bool,
        enhancementService: AIEnhancementService
    ) {
        guard coordinator.isCurrentExperienceReady(isTranscriptionSetupReady: isTranscriptionSetupReady) else {
            return
        }

        continueAfterCurrentExperienceStep(
            isTranscriptionSetupReady: isTranscriptionSetupReady,
            enhancementService: enhancementService
        )
    }

    func skipCurrentExperienceStep(
        isTranscriptionSetupReady: Bool,
        enhancementService: AIEnhancementService
    ) {
        guard coordinator.isReadyForExperience(isTranscriptionSetupReady: isTranscriptionSetupReady) else {
            return
        }

        continueAfterCurrentExperienceStep(
            isTranscriptionSetupReady: isTranscriptionSetupReady,
            enhancementService: enhancementService
        )
    }

    private func continueAfterCurrentExperienceStep(
        isTranscriptionSetupReady: Bool,
        enhancementService: AIEnhancementService
    ) {
        if coordinator.shouldShowContextAwarenessAfterCurrentExperience {
            goToContextAwarenessStep(isTranscriptionSetupReady: isTranscriptionSetupReady)
        } else if coordinator.isLastExperienceStep {
            goToTrustStep(isTranscriptionSetupReady: isTranscriptionSetupReady)
        } else {
            moveToExperienceStep(
                coordinator.normalizedExperienceStepIndex + 1,
                enhancementService: enhancementService
            )
        }
    }

    func reconcileStage(
        isTranscriptionSetupReady: Bool,
        enhancementService: AIEnhancementService
    ) {
        if coordinator.stage == .microphone && !coordinator.requiredPermissionsGranted {
            goToPermissionsStep()
        }

        if coordinator.stage == .model
            && (!coordinator.requiredPermissionsGranted || !coordinator.hasSelectedOnboardingMicrophone)
        {
            goToFirstIncompleteSetupStep(isTranscriptionSetupReady: isTranscriptionSetupReady)
        }

        // After a restore the key step is only for a missing key; the onboarding transcription setup doesn't apply.
        let leaveAPIStep =
            coordinator.restoredFromCloud
            ? coordinator.restoreProviderMissingKey == nil
            : !isTranscriptionSetupReady || coordinator.usedRecommendedSetup
        if coordinator.stage == .api
            && (!coordinator.requiredPermissionsGranted || !coordinator.hasSelectedOnboardingMicrophone || leaveAPIStep)
        {
            goToFirstIncompleteSetupStep(isTranscriptionSetupReady: isTranscriptionSetupReady)
        }

        if (coordinator.stage == .experience || coordinator.stage == .contextAwareness || coordinator.stage == .trust)
            && !coordinator.isReadyForExperience(isTranscriptionSetupReady: isTranscriptionSetupReady)
        {
            goToFirstIncompleteSetupStep(isTranscriptionSetupReady: isTranscriptionSetupReady)
        }

        // Skipped transcription means no working dictation, so the API and practice steps are not reachable.
        // After a restore the model and practice steps aren't either (the key step is handled above).
        let practiceStages: [OnboardingStage] = [.experience, .contextAwareness]
        if (coordinator.hasSkippedTranscriptionSetup && (practiceStages + [.api]).contains(coordinator.stage))
            || (coordinator.restoredFromCloud && (practiceStages + [.model]).contains(coordinator.stage))
        {
            goToFirstIncompleteSetupStep(isTranscriptionSetupReady: isTranscriptionSetupReady)
        }

        if coordinator.stage == .experience
            && coordinator.isReadyForExperience(isTranscriptionSetupReady: isTranscriptionSetupReady)
            && !coordinator.isExperienceModeInstalled
        {
            installCurrentExperienceMode(enhancementService: enhancementService)
        }

        if coordinator.stage == .contextAwareness
            && coordinator.isReadyForExperience(isTranscriptionSetupReady: isTranscriptionSetupReady)
        {
            activateCleanTranscriptionMode()
        }
    }

    func goToFirstIncompleteSetupStep(isTranscriptionSetupReady: Bool) {
        if !coordinator.requiredPermissionsGranted {
            coordinator.storedStage = OnboardingStage.permissions.rawValue
        } else if !coordinator.hasSelectedOnboardingMicrophone {
            coordinator.storedStage = OnboardingStage.microphone.rawValue
        } else if coordinator.restoredFromCloud {
            continueAfterRestore()
        } else if coordinator.hasSkippedTranscriptionSetup {
            coordinator.storedStage = OnboardingStage.trust.rawValue
        } else if !isTranscriptionSetupReady {
            coordinator.storedStage = OnboardingStage.model.rawValue
        } else {
            coordinator.storedStage = stageBeforeExperience.rawValue
        }
    }

    func downloadTranscriptionModel(
        _ model: FluidAudioModel,
        modelManager: FluidAudioModelManager
    ) {
        guard coordinator.requiredPermissionsGranted,
            coordinator.hasSelectedOnboardingMicrophone,
            !modelManager.isFluidAudioModelDownloaded(model),
            !modelManager.isFluidAudioModelDownloading(model)
        else {
            return
        }

        modelManager.startDownload(model)
    }

    func moveToExperienceStep(
        _ index: Int,
        enhancementService: AIEnhancementService
    ) {
        guard coordinator.activeExperienceSteps.indices.contains(index) else {
            return
        }

        coordinator.experienceStepIndex = index
        coordinator.isExperienceInIntroPhase = shouldStartExperienceInIntroPhase(
            for: coordinator.activeExperienceSteps[index]
        )
        resetExperienceText(at: index)
        installExperienceMode(at: index, enhancementService: enhancementService)
        activateExperienceModeForDemo()
        clearExperienceShortcutForIntroIfNeeded()
        refreshExperienceModeState(enhancementService: enhancementService)
    }

    func completeOnboarding(
        isTranscriptionSetupReady: Bool,
        onComplete: () -> Void
    ) {
        let isFinalStage = coordinator.stage == .trust

        guard
            isFinalStage || coordinator.isCurrentExperienceReady(isTranscriptionSetupReady: isTranscriptionSetupReady)
        else {
            return
        }

        let preset = coordinator.usedRecommendedSetup ? chosenPreset() : nil
        let restored = coordinator.restoredFromCloud
        OnboardingStorageKeys.onboardingKeys.forEach {
            coordinator.defaults.removeObject(forKey: $0)
        }
        installFallbackSetupIfNeeded()
        // A restored default mode stays the default; the Clean starter mode may exist but isn't forced.
        if !restored { activateCleanTranscriptionMode() }
        reapplyConfigFile(preset: preset)
        onComplete()
    }

    /// "Set It Up Later" skips the practice steps, which are what install the starter modes and record the
    /// shortcut. Without this the hotkey does nothing; with it, recording starts and the preflight / model
    /// checks tell the user which provider or model to set up.
    private func installFallbackSetupIfNeeded() {
        if ModeManager.shared.configurations.isEmpty {
            StarterModeFactory.install(
                kinds: [.clean],
                provider: coordinator.selectedOnboardingProvider,
                modelName: nil
            )
        }

        if ShortcutStore.rawShortcut(for: .primaryRecording) == nil,
            !ShortcutStore.isShortcutCleared(for: .primaryRecording)
        {
            ShortcutStore.setShortcut(
                .modifierOnly(keyCode: UInt16(kVK_RightOption), modifierFlags: [.option]),
                for: .primaryRecording
            )
        }
    }

    /// Onboarding rewrites the starter modes, so the recommended preset (if chosen) and then config.json are
    /// applied again on top of them; config.json goes last so its fields win.
    private func reapplyConfigFile(preset: YapConfig?) {
        Task { @MainActor in
            if let preset {
                await YapConfigLoader.shared.apply(config: preset, source: .recommended, patchModes: true)
            }
            await YapConfigLoader.shared.reload()
        }
    }

    private func chosenPreset() -> YapConfig? {
        if coordinator.transcriptionSetupKind == .yapCloud {
            return coordinator.selectedOnboardingTranscriptionModel.map { .yapCloud(transcriptionModel: $0.name) }
        }
        return APIKeyManager.shared.getAPIKey(forProvider: AIProvider.openRouter.rawValue)
            .map { .recommended(openRouterKey: $0) }
    }

    func refreshAPIVerification() {
        coordinator.isSelectedAPIProviderVerified = APIKeyManager.shared.hasAPIKey(
            forProvider: coordinator.selectedOnboardingProvider.rawValue
        )

        if coordinator.isSelectedAPIProviderVerified {
            coordinator.hasSkippedAPISetup = false
        }
    }

    func refreshTranscriptionSetupVerification() {
        ensureDefaultOnboardingTranscriptionProvider()

        guard let provider = coordinator.selectedOnboardingTranscriptionProvider else {
            coordinator.isSelectedTranscriptionProviderVerified = false
            return
        }

        coordinator.isSelectedTranscriptionProviderVerified = APIKeyManager.shared.hasAPIKey(
            forProvider: provider.providerKey
        )
    }

    func selectOnboardingTranscriptionSetup(_ kind: OnboardingTranscriptionSetupKind) {
        coordinator.storedTranscriptionSetupKind = kind.rawValue
        if kind != .recommended { coordinator.usedRecommendedSetup = false }
        ensureDefaultOnboardingTranscriptionProvider()
        refreshTranscriptionSetupVerification()
    }

    func ensureDefaultOnboardingTranscriptionProvider() {
        let options = coordinator.onboardingTranscriptionProviderOptions
        if options.contains(where: {
            $0.providerKey.caseInsensitiveCompare(coordinator.storedOnboardingTranscriptionProvider) == .orderedSame
        }) {
            return
        }

        let defaultProvider = coordinator.recommendedOnboardingTranscriptionProvider ?? options.first
        coordinator.storedOnboardingTranscriptionProvider = defaultProvider?.providerKey ?? ""
    }

    func selectOnboardingTranscriptionProvider(_ providerKey: String) {
        guard
            coordinator.onboardingTranscriptionProviderOptions.contains(where: {
                $0.providerKey.caseInsensitiveCompare(providerKey) == .orderedSame
            })
        else { return }

        coordinator.storedOnboardingTranscriptionProvider = providerKey
        refreshTranscriptionSetupVerification()
    }

    func ensureDefaultOnboardingProvider() {
        if let storedProvider = AIProvider(rawValue: coordinator.storedOnboardingAIProvider),
            coordinator.onboardingProviderOptions.contains(storedProvider)
        {
            return
        }

        let defaultProvider: AIProvider =
            coordinator.onboardingProviderOptions.contains(.groq)
            ? .groq
            : coordinator.onboardingProviderOptions.first ?? .groq
        coordinator.storedOnboardingAIProvider = defaultProvider.rawValue
    }

    func selectOnboardingProvider(_ provider: AIProvider, aiService: AIService) {
        guard coordinator.onboardingProviderOptions.contains(provider) else { return }

        coordinator.storedOnboardingAIProvider = provider.rawValue

        if APIKeyManager.shared.hasAPIKey(forProvider: provider.rawValue) {
            aiService.selectedProvider = provider
            aiService.selectModel(provider.defaultModel, for: provider)
        }

        refreshAPIVerification()
    }

    func installExperienceMode(
        at index: Int,
        enhancementService: AIEnhancementService
    ) {
        guard coordinator.activeExperienceSteps.indices.contains(index) else {
            return
        }

        var seenKinds = Set<StarterModeKind>()
        let installedKinds = coordinator.activeExperienceSteps
            .prefix(index + 1)
            .map(\.starterModeKind)
            .filter { seenKinds.insert($0).inserted }

        let installedSteps = Array(coordinator.activeExperienceSteps.prefix(index + 1))

        let seedResult = StarterModePromptSeeder.ensurePrompts(
            for: installedKinds,
            in: enhancementService.customPrompts
        )
        if seedResult.didChange {
            enhancementService.customPrompts = seedResult.prompts
        }

        StarterModeFactory.install(
            kinds: installedKinds,
            provider: coordinator.selectedOnboardingProvider,
            modelName: coordinator.usedRecommendedSetup
                ? RecommendedSetup.enhancementModel : coordinator.selectedOnboardingProvider.defaultModel,
            transcriptionModelName: coordinator.selectedOnboardingTranscriptionModelName
                ?? StarterModeFactory.defaultTranscriptionModelName,
            isRealtimeTranscriptionEnabled: coordinator.selectedOnboardingTranscriptionUsesRealtime,
            selectedLanguage: coordinator.selectedOnboardingTranscriptionLanguage
        )

        removeModeShortcutStorageForPrimaryRecordingSteps(installedSteps)
        applyDefaultMode(for: coordinator.activeExperienceSteps[index])
    }

    func installCurrentExperienceMode(enhancementService: AIEnhancementService) {
        guard coordinator.stage == .experience else { return }
        installExperienceMode(
            at: coordinator.normalizedExperienceStepIndex,
            enhancementService: enhancementService
        )
        refreshExperienceModeState(enhancementService: enhancementService)
    }

    func refreshExperienceModeState(enhancementService: AIEnhancementService) {
        let hasRequiredPrompts = StarterModePromptSeeder.hasPrompts(
            for: [coordinator.experienceModeTemplate.kind],
            in: enhancementService.customPrompts
        )

        coordinator.isExperienceModeInstalled =
            StarterModeFactory.isInstalled(kind: coordinator.experienceModeTemplate.kind) && hasRequiredPrompts
        coordinator.hasExperienceModeShortcut = ShortcutStore.shortcut(for: coordinator.experienceShortcutAction) != nil
    }

    func clearExperienceShortcutForIntroIfNeeded() {
        guard coordinator.stage == .experience,
            coordinator.isExperienceInIntroPhase,
            coordinator.experienceStep.shouldClearShortcutOnIntro,
            !coordinator.clearedExperienceShortcutActions.contains(coordinator.experienceShortcutAction)
        else {
            return
        }

        var clearedActions = coordinator.clearedExperienceShortcutActions
        clearedActions.insert(coordinator.experienceShortcutAction)
        coordinator.clearedExperienceShortcutActions = clearedActions
        ShortcutStore.setShortcut(nil, for: coordinator.experienceShortcutAction)
    }

    func activateExperienceModeForDemo() {
        guard coordinator.stage == .experience,
            let config = ModeManager.shared.getConfiguration(with: coordinator.experienceModeTemplate.id)
        else {
            return
        }

        applyDefaultMode(for: coordinator.experienceStep)
        ModeManager.shared.setActiveConfiguration(config)
    }

    func activateCleanTranscriptionMode() {
        guard let cleanTemplate = StarterModeCatalog.templates.first(where: { $0.kind == .clean }),
            let cleanConfig = ModeManager.shared.getConfiguration(with: cleanTemplate.id)
        else {
            return
        }

        ModeManager.shared.setAsDefault(configId: cleanConfig.id)
        ModeManager.shared.setActiveConfiguration(cleanConfig)
    }

    private func applyDefaultMode(for step: OnboardingExperienceStep) {
        setDefaultStarterMode(step.defaultModeKind)
    }

    private func setDefaultStarterMode(_ kind: StarterModeKind) {
        guard let template = StarterModeCatalog.templates.first(where: { $0.kind == kind }),
            ModeManager.shared.getConfiguration(with: template.id) != nil,
            ModeManager.shared.getDefaultConfiguration()?.id != template.id
        else {
            return
        }

        ModeManager.shared.setAsDefault(configId: template.id)
    }

    private func shouldStartExperienceInIntroPhase(for step: OnboardingExperienceStep) -> Bool {
        !step.shouldSkipShortcutIntro(
            hasConfiguredShortcut: ShortcutStore.shortcut(for: shortcutAction(for: step)) != nil
        )
    }

    private func removeModeShortcutStorageForPrimaryRecordingSteps(_ steps: [OnboardingExperienceStep]) {
        var removedTemplateIds = Set<UUID>()

        for step in steps where step.usesPrimaryRecordingShortcut {
            let template = modeTemplate(for: step)
            guard removedTemplateIds.insert(template.id).inserted else {
                continue
            }

            let action = ShortcutAction.mode(template.id)
            if ShortcutStore.rawShortcut(for: action) != nil || ShortcutStore.isShortcutCleared(for: action) {
                ShortcutStore.removeShortcutStorage(for: action)
            }
        }
    }

    private func shortcutAction(for step: OnboardingExperienceStep) -> ShortcutAction {
        step.shortcutAction(modeTemplate: modeTemplate(for: step))
    }

    private func modeTemplate(for step: OnboardingExperienceStep) -> StarterModeTemplate {
        StarterModeCatalog.templates.first { $0.kind == step.starterModeKind } ?? StarterModeCatalog.templates[0]
    }

    func resetExperienceText(at index: Int) {
        guard coordinator.activeExperienceSteps.indices.contains(index) else {
            return
        }

        let step = coordinator.activeExperienceSteps[index]
        var updatedText = coordinator.experienceTextByKind
        updatedText[step.kind] = step.initialFieldText
        coordinator.experienceTextByKind = updatedText
    }
}
