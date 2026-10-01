import FluidAudio
import Foundation
import os.log

class FluidAudioTranscriptionService: TranscriptionService {
    private var asrManager: AsrManager?
    private var unifiedAsrManager: UnifiedAsrManager?
    private var nemotronAsrManager: StreamingNemotronMultilingualAsrManager?
    private var vadManager: VadManager?
    private var activeVersion: AsrModelVersion?
    private var activeNemotronModelName: String?
    private var cachedModels: AsrModels?
    private var loadingTask: (version: AsrModelVersion, task: Task<AsrModels, Error>)?
    private var managerLoad: (name: String, task: Task<Void, Error>)?
    /// One transcription, preload or release at a time: Nemotron's and Unified's managers keep one decode's state
    /// (language, audio buffer, decoder) on the shared manager, and a release mid-decode would clean them up under
    /// it. Streaming sessions build their own managers and don't take turns.
    private let turns = ModelTurns()
    #if DEBUG
        /// `make lifecycle-check`: whether a batch manager is loaded.
        var hasLoadedManagers: Bool { asrManager != nil || unifiedAsrManager != nil || nemotronAsrManager != nil }
    #endif
    private let audioConverter = AudioConverter()
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "FluidAudioTranscriptionService")

    private func version(for model: any TranscriptionModel) -> AsrModelVersion {
        FluidAudioModelManager.asrVersion(for: model.name)
    }

    static func languageHint(from selectedLanguage: String?, model: any TranscriptionModel) -> Language? {
        guard model.provider == .fluidAudio else {
            return nil
        }
        return FluidAudioModelManager.languageHint(from: selectedLanguage, for: model.name)
    }

    private func cleanupLoadedManagers() async {
        await unifiedAsrManager?.cleanup()
        await nemotronAsrManager?.cleanup()
        await asrManager?.cleanup()

        unifiedAsrManager = nil
        nemotronAsrManager = nil
        asrManager = nil
        vadManager = nil
        activeVersion = nil
        activeNemotronModelName = nil
    }

    private func ensureModelsLoaded(for version: AsrModelVersion) async throws {
        if asrManager != nil, activeVersion == version {
            return
        }

        // Clean up existing manager but preserve cachedModels for reuse
        await cleanupLoadedManagers()

        let models = try await getOrLoadModels(for: version)

        let manager = AsrManager(config: .default)
        try await manager.loadModels(models)
        self.asrManager = manager
        self.activeVersion = version
    }

    private func ensureUnifiedModelsLoaded() async throws {
        if unifiedAsrManager != nil {
            return
        }

        await cleanupLoadedManagers()

        let manager = UnifiedAsrManager(encoderPrecision: FluidAudioModelManager.parakeetUnifiedPrecision)
        try await manager.loadModels(from: FluidAudioModelManager.parakeetUnifiedCacheDirectory())
        self.unifiedAsrManager = manager
    }

    private func ensureNemotronModelsLoaded(named modelName: String) async throws {
        if nemotronAsrManager != nil, activeNemotronModelName == modelName {
            return
        }

        await cleanupLoadedManagers()

        let manager = StreamingNemotronMultilingualAsrManager()
        try await manager.loadModels(from: FluidAudioModelManager.nemotronCacheDirectory(for: modelName))
        self.nemotronAsrManager = manager
        self.activeNemotronModelName = modelName
    }

    // Returns cached models or loads from disk; deduplicates concurrent loads
    func getOrLoadModels(for version: AsrModelVersion) async throws -> AsrModels {
        if let cached = cachedModels, cached.version == version {
            return cached
        }

        // Deduplicate concurrent loads for the same version
        if let (existingVersion, existingTask) = loadingTask, existingVersion == version {
            return try await existingTask.value
        }

        let task = Task {
            let cacheDirectory = AsrModels.defaultCacheDirectory(for: version)
            guard AsrModels.modelsExist(at: cacheDirectory, version: version) else {
                throw AsrModelsError.loadingFailed(
                    "Parakeet model files are incomplete. Download the model from AI Models."
                )
            }
            return try await AsrModels.load(
                from: cacheDirectory,
                configuration: nil,
                version: version,
                encoderPrecision: .int8
            )
        }
        loadingTask = (version, task)

        do {
            let models = try await task.value
            self.cachedModels = models
            // Only clear if we're still the current loading task
            if loadingTask?.version == version {
                self.loadingTask = nil
            }
            return models
        } catch {
            // Only clear if we're still the current loading task
            if loadingTask?.version == version {
                self.loadingTask = nil
            }
            throw error
        }
    }

    /// One manager load at a time per model: the shortcut-press preload and the load after the mode is applied
    /// share it instead of each building a manager. In a turn, so it never replaces managers a transcription uses.
    func loadModel(for model: FluidAudioModel) async throws {
        if let (name, task) = managerLoad {
            if name == model.name { return try await task.value }
            _ = try? await task.value
        }
        let task = Task {
            await self.turns.take()
            defer { self.turns.give() }
            guard !self.turns.isClosed else { throw CancellationError() }
            try await LocalModelActivity.shared.run(.load, stage: .loading, interruptible: false) {
                try await self.loadManagers(for: model)
            }
        }
        managerLoad = (model.name, task)
        defer { if managerLoad?.name == model.name { managerLoad = nil } }
        try await task.value
    }

    private func loadManagers(for model: FluidAudioModel) async throws {
        if FluidAudioModelManager.isNemotronModel(named: model.name) {
            // Realtime Nemotron uses a dedicated streaming manager; batch loads lazily in transcribe().
            return
        }

        if FluidAudioModelManager.isParakeetUnifiedModel(named: model.name) {
            try await ensureUnifiedModelsLoaded()
            return
        }

        try await ensureModelsLoaded(for: version(for: model))
    }

    /// Reported to LocalModelActivity as a decode that stops on a cancel for Nemotron (its chunks run Core ML's async
    /// `prediction(from:)`, which throws when the task is cancelled: a cancel 10 s into a ~39 s decode returned in
    /// 0.02 s in `make lifecycle-check`), and as one that may not for the other FluidAudio models (not run).
    func transcribe(audioURL: URL, model: any TranscriptionModel, context: TranscriptionRequestContext) async throws
        -> String
    {
        // A preload asked first runs first; cancelled while waiting, this leaves the queue without decoding.
        try await turns.takeForTranscription()
        defer { turns.give() }
        guard !turns.isClosed else { throw VoiceInkEngineError.modelLoadFailed }
        return try await LocalModelActivity.shared.run(
            .transcription(LocalModelActivity.requester), stage: .decoding,
            interruptible: FluidAudioModelManager.isNemotronModel(named: model.name)
        ) {
            try await transcribeInTurn(audioURL: audioURL, model: model, context: context)
        }
    }

    private func transcribeInTurn(audioURL: URL, model: any TranscriptionModel, context: TranscriptionRequestContext)
        async throws -> String
    {
        if FluidAudioModelManager.isParakeetUnifiedModel(named: model.name) {
            let wasLoaded = unifiedAsrManager != nil
            try await ensureUnifiedModelsLoaded()
            if !wasLoaded { DictationTimeline.modelDidLoad() }
            guard let unifiedAsrManager else {
                throw ASRError.notInitialized
            }

            let speechAudio = try await preparedSpeechAudio(from: audioURL)
            guard !speechAudio.isEmpty else { return "" }
            let text = try await unifiedAsrManager.transcribe(speechAudio)
            return text
        }

        if FluidAudioModelManager.isNemotronModel(named: model.name) {
            let wasLoaded = nemotronAsrManager != nil && activeNemotronModelName == model.name
            try await ensureNemotronModelsLoaded(named: model.name)
            if !wasLoaded { DictationTimeline.modelDidLoad() }
            guard let nemotronAsrManager else {
                throw ASRError.notInitialized
            }

            let compatibleLanguage = TranscriptionLanguageSupport.validLanguageOrFallback(
                context.language,
                for: model
            )
            let languageHint = FluidAudioModelManager.nemotronLanguageHint(from: compatibleLanguage)
            await nemotronAsrManager.setLanguage(languageHint)
            await nemotronAsrManager.reset()

            var speechAudio = try await preparedSpeechAudio(from: audioURL)
            guard !speechAudio.isEmpty else { return "" }
            let trailingSilenceSamples = 16_000
            let maxSingleChunkSamples = 240_000
            if speechAudio.count + trailingSilenceSamples <= maxSingleChunkSamples {
                speechAudio += [Float](repeating: 0, count: trailingSilenceSamples)
            }
            // Also checked here, before the decode starts (the language and reset above don't check).
            try Task.checkCancellation()
            _ = try await nemotronAsrManager.process(samples: speechAudio)
            let text = try await nemotronAsrManager.finish()
            return text
        }

        let targetVersion = version(for: model)
        let wasLoaded = asrManager != nil && activeVersion == targetVersion
        try await ensureModelsLoaded(for: targetVersion)
        if !wasLoaded { DictationTimeline.modelDidLoad() }

        guard let asrManager = asrManager else {
            throw ASRError.notInitialized
        }

        let languageHint = Self.languageHint(
            from: context.language,
            model: model
        )
        var decoderState = TdtDecoderState.make(decoderLayers: await asrManager.decoderLayerCount)
        let result: ASRResult
        if UserDefaults.standard.bool(forKey: "IsVADEnabled") {
            let speechAudio = try await preparedSpeechAudio(from: audioURL)
            guard !speechAudio.isEmpty else { return "" }
            result = try await asrManager.transcribe(
                speechAudio,
                decoderState: &decoderState,
                language: languageHint
            )
        } else {
            result = try await asrManager.transcribe(
                audioURL,
                decoderState: &decoderState,
                language: languageHint
            )
        }

        return result.text
    }

    private func loadAudioSamples(from audioURL: URL) throws -> [Float] {
        try audioConverter.resampleAudioFile(audioURL)
    }

    private func preparedSpeechAudio(from audioURL: URL) async throws -> [Float] {
        let samples = try loadAudioSamples(from: audioURL)
        return try await preparedSpeechAudio(in: samples)
    }

    func preparedSpeechAudio(in samples: [Float]) async throws -> [Float] {
        guard let segments = try await detectedSpeechAudio(in: samples) else {
            return samples
        }

        var speechAudio = segments.flatMap { $0 }
        guard !speechAudio.isEmpty else { return [] }
        let minimumSamples = ASRConstants.minimumRequiredSamples(forSampleRate: ASRConstants.sampleRate)
        if speechAudio.count < minimumSamples {
            speechAudio += [Float](repeating: 0, count: minimumSamples - speechAudio.count)
        }
        return speechAudio
    }

    // Streaming callers retain each segment's original position for word timestamps.
    func detectedSpeechSegments(in samples: [Float]) async throws -> [VadSegment]? {
        guard UserDefaults.standard.bool(forKey: "IsVADEnabled") else {
            return nil
        }

        do {
            try Task.checkCancellation()
            let manager = try await getOrLoadVadManager()
            let segments = try await manager.segmentSpeech(samples)
            try Task.checkCancellation()
            return segments
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            logger.notice("VAD failed; using full audio: \(error, privacy: .public)")
            return nil
        }
    }

    private func getOrLoadVadManager() async throws -> VadManager {
        if let vadManager { return vadManager }
        let manager = try await VadManager(config: VadConfig(defaultThreshold: 0.7))
        vadManager = manager
        return manager
    }

    // Nil means VAD is disabled or unavailable; callers preserve the original audio.
    private func detectedSpeechAudio(in samples: [Float]) async throws -> [[Float]]? {
        guard UserDefaults.standard.bool(forKey: "IsVADEnabled") else {
            return nil
        }

        do {
            try Task.checkCancellation()
            let manager = try await getOrLoadVadManager()
            let segments = try await manager.segmentSpeechAudio(samples)
            try Task.checkCancellation()
            return segments
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            logger.notice("VAD failed; using full audio: \(error, privacy: .public)")
            return nil
        }
    }

    /// Every loaded manager and the cached Core ML models: the idle release in ModelResidency. After the
    /// transcription or preload in its turn, never under it.
    func releaseAll() async {
        await turns.take()
        defer { turns.give() }
        await LocalModelActivity.shared.run(.release, stage: .unloading, interruptible: false) {
            loadingTask?.task.cancel()
            loadingTask = nil
            await cleanupLoadedManagers()
            cachedModels = nil
        }
    }

    /// Quit: no transcription or preload starts from now on (those still waiting fail without running), then
    /// `releaseAll` once the one in its turn has finished.
    func close() async {
        turns.close()
        await releaseAll()
    }

}
