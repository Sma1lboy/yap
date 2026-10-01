import FluidAudio
import Dispatch
import Foundation
import TranscribeCpp
import os

/// Shared offline runtime for catalog-backed transcribe.cpp model families.
final class OfflineTranscribeCppService: TranscriptionService, @unchecked Sendable {
    private struct LoadedState {
        let modelName: String
        let model: Model
    }

    private struct LoadingState {
        let id: UUID
        let modelName: String
        let task: Task<Model, Error>
    }

    private enum LoadResolution {
        case loaded(Model)
        case loading(LoadingState)
    }

    private static let backendInitializationLock = NSLock()
    private static let modelInitializationLock = NSLock()
    private static var backendsInitialized = false

    private let stateLock = NSLock()
    private var loadedState: LoadedState?
    private var loadingState: LoadingState?
    private var activeTranscriptionCount = 0
    /// An unload asked for while transcriptions ran (idle, memory pressure, model change): done after the last one.
    private var unloadWhenIdle = false
    /// Set by Quit (`close`): no transcription or load starts from then on.
    private var closed = false
    /// `close` waiting for the running transcriptions to end.
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []
    #if DEBUG
        /// `make lifecycle-check`: whether a model is loaded.
        var isModelLoaded: Bool { stateLock.withLock { loadedState != nil } }
    #endif
    private var notificationObservers: [NSObjectProtocol] = []
    private var memoryPressureSource: DispatchSourceMemoryPressure?
    private let audioConverter = AudioConverter()
    private let logger = Logger(
        subsystem: "com.prakashjoshipax.voiceink",
        category: "OfflineTranscribeCppService"
    )

    init() {
        let center = NotificationCenter.default
        notificationObservers.append(
            center.addObserver(forName: .didChangeModel, object: nil, queue: nil) { [weak self] notification in
                guard let modelName = notification.userInfo?["modelName"] as? String else { return }
                self?.unloadModel(unlessSelectedModelIs: modelName)
            }
        )
        notificationObservers.append(
            center.addObserver(forName: .transcribeCppModelDeleted, object: nil, queue: nil) { [weak self] notification in
                guard let modelName = notification.userInfo?["modelName"] as? String else {
                    self?.unloadModel()
                    return
                }
                self?.unloadModel(named: modelName)
            }
        )

        let pressureSource = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical],
            queue: .global(qos: .utility)
        )
        pressureSource.setEventHandler { [weak self] in
            self?.unloadModel()
        }
        pressureSource.resume()
        memoryPressureSource = pressureSource
    }

    deinit {
        memoryPressureSource?.cancel()
        for observer in notificationObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        unloadModel()
    }

    private var backend: Backend {
        #if arch(arm64)
        return .metal
        #else
        return .cpu
        #endif
    }

    func loadModel(for model: TranscribeCppModel) async throws {
        let artifact = try resolveArtifact(for: model)
        _ = try await getOrLoadModel(for: model, artifact: artifact)
    }

    func transcribe(
        audioURL: URL,
        model: any TranscriptionModel,
        context: TranscriptionRequestContext
    ) async throws -> String {
        guard let transcribeCppModel = model as? TranscribeCppModel else {
            throw NSError(
                domain: "OfflineTranscribeCppService",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Unsupported transcription model"]
            )
        }
        let artifact = try resolveArtifact(for: transcribeCppModel)
        let samples = try audioConverter.resampleAudioFile(audioURL)
        let language = selectedLanguage(context.language, for: transcribeCppModel)

        // Counted from before the load: an unload asked for meanwhile waits for this transcription to end.
        try beginRun()
        defer { endRun() }
        let startedAt = ContinuousClock.now
        // The model is only held inside the closure, so this transcription's last reference to it is gone by the
        // time endRun lets Quit go on: Model.deinit frees its Metal buffers before exit().
        let chunkTranscripts = try await LocalModelActivity.shared.run(
            .transcription(LocalModelActivity.requester), stage: .loading, interruptible: false
        ) {
            let model = try await keptModel(for: transcribeCppModel, artifact: artifact)
            LocalModelActivity.current?.stage(.decoding)
            return try await transcribeChunks(samples, language: language, artifact: artifact, on: model)
        }

        logger.notice(
            "\(transcribeCppModel.displayName, privacy: .public) completed in \(startedAt.duration(to: .now).formatted(.units(allowed: [.seconds], width: .narrow)), privacy: .public) for \(samples.count, privacy: .public) samples"
        )
        return joinedText(from: chunkTranscripts)
    }

    /// Every chunk on one model. A cancelled task aborts the native run in flight (Session.run bridges task
    /// cancellation to transcribe.cpp's abort callback, checked between decode steps) and throws CancellationError.
    private func transcribeChunks(
        _ samples: [Float], language: String?, artifact: TranscribeCppModelArtifact, on nativeModel: Model
    ) async throws -> [(text: String, language: String?)] {
        let options = RunOptions(
            timestamps: .none,
            itn: artifact.enablesInverseTextNormalization ? .on : .default,
            language: language,
            keepSpecialTags: false
        )
        let maximumChunkSeconds = effectiveMaximumChunkSeconds(
            configuredMaximum: artifact.maximumChunkSeconds,
            capabilitiesMaximumMilliseconds: nativeModel.capabilities.maxAudioMs
        )
        let chunks = samples.energyAwareChunks(
            maximumCount: maximumChunkSeconds * 16_000,
            boundarySearchCount: artifact.boundarySearchSeconds * 16_000,
            energyWindowCount: artifact.boundaryEnergyWindowSamples
        )

        var chunkTranscripts: [(text: String, language: String?)] = []
        chunkTranscripts.reserveCapacity(chunks.count)
        for chunk in chunks {
            try Task.checkCancellation()
            let session = try nativeModel.session()
            let transcript: Transcript
            do {
                transcript = try await session.run(chunk, options: options)
            } catch where Task.isCancelled {
                throw CancellationError()
            }
            let text = transcript.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                chunkTranscripts.append((text: text, language: transcript.language ?? language))
            }
        }
        return chunkTranscripts
    }

    /// The idle or memory-pressure release: unloads now, or after the last running transcription.
    func cleanup() {
        unloadModel()
    }

    func unloadModel() {
        unloadModel { _ in true }
    }

    /// Quit: no transcription or load starts from now on, and this returns once the running ones have ended (as
    /// Whisper's Quit, it waits for them rather than losing a dictation) and the model is unloaded.
    func close() async {
        stateLock.withLock { closed = true }
        await withCheckedContinuation { (idle: CheckedContinuation<Void, Never>) in
            let now = stateLock.withLock { () -> Bool in
                guard activeTranscriptionCount > 0 else { return true }
                idleWaiters.append(idle)
                return false
            }
            if now { idle.resume() }
        }
        unloadModel()
    }

    private func getOrLoadModel(
        for model: TranscribeCppModel,
        artifact: TranscribeCppModelArtifact
    ) async throws -> Model {
        let resolvedState: LoadResolution = try stateLock.withLock {
            if closed { throw CancellationError() }
            if let loadedState, loadedState.modelName == model.name {
                return .loaded(loadedState.model)
            }
            if let loadingState, loadingState.modelName == model.name {
                return .loading(loadingState)
            }

            loadingState?.task.cancel()
            loadingState = nil
            loadedState = nil

            let loadID = UUID()
            let backend = backend
            let task = Task.detached(priority: .userInitiated) {
                try Task.checkCancellation()
                guard let modelURL = artifact.installedModelFileURL else {
                    throw CocoaError(.fileNoSuchFile)
                }

                try Self.initializeBackendsIfNeeded()
                guard Transcribe.backendAvailable(backend) else {
                    throw TranscribeError.backend("The requested transcribe.cpp backend is unavailable")
                }

                // Serialize non-cancellable native construction to prevent overlapping model loads.
                return try Self.modelInitializationLock.withLock {
                    try Task.checkCancellation()
                    let loadedModel = try Model(
                        path: modelURL.path,
                        options: ModelOptions(backend: backend)
                    )
                    try Task.checkCancellation()
                    return loadedModel
                }
            }
            let state = LoadingState(id: loadID, modelName: model.name, task: task)
            loadingState = state
            return .loading(state)
        }

        if case .loaded(let loadedModel) = resolvedState {
            return loadedModel
        }

        guard case .loading(let loading) = resolvedState else {
            throw CocoaError(.fileReadUnknown)
        }

        let startedAt = ContinuousClock.now
        do {
            let loadedModel = try await loading.task.value
            if let architectureHint = artifact.architectureHint {
                guard loadedModel.arch.localizedCaseInsensitiveContains(architectureHint) else {
                    throw CocoaError(.fileReadCorruptFile)
                }
            }

            let loadIsCurrent = stateLock.withLock {
                if
                    let currentState = loadedState,
                    currentState.modelName == model.name,
                    currentState.model === loadedModel
                {
                    return true
                }
                guard loadingState?.id == loading.id else { return false }
                loadedState = LoadedState(modelName: model.name, model: loadedModel)
                loadingState = nil
                return true
            }
            guard loadIsCurrent else { throw CancellationError() }

            logger.notice(
                "\(model.displayName, privacy: .public) loaded with \(loadedModel.backend, privacy: .public) in \(startedAt.duration(to: .now).formatted(.units(allowed: [.seconds], width: .narrow)), privacy: .public)"
            )
            DictationTimeline.modelDidLoad()
            return loadedModel
        } catch {
            stateLock.withLock {
                if loadingState?.id == loading.id {
                    loadingState = nil
                }
            }
            throw error
        }
    }

    private func unloadModel(named modelName: String) {
        unloadModel { $0 == modelName }
    }

    private func unloadModel(unlessSelectedModelIs modelName: String) {
        unloadModel { $0 != modelName }
    }

    private func unloadModel(where shouldUnload: (String) -> Bool) {
        let didUnload = stateLock.withLock {
            guard let activeModelName = loadedState?.modelName ?? loadingState?.modelName,
                shouldUnload(activeModelName)
            else {
                return false
            }
            guard activeTranscriptionCount == 0 else {
                unloadWhenIdle = true
                return false
            }
            loadingState?.task.cancel()
            loadingState = nil
            loadedState = nil
            return true
        }
        if didUnload {
            logger.notice("transcribe.cpp runtime unloaded")
        }
    }

    /// A transcription starts: counted until `endRun`. After Quit, none does.
    private func beginRun() throws {
        try stateLock.withLock {
            if closed { throw CancellationError() }
            activeTranscriptionCount += 1
        }
    }

    /// The loaded model, loading it if needed; restores it as the loaded one after an unload raced the load.
    private func keptModel(for model: TranscribeCppModel, artifact: TranscribeCppModelArtifact) async throws -> Model {
        let nativeModel = try await getOrLoadModel(for: model, artifact: artifact)
        stateLock.withLock {
            if loadedState == nil {
                loadingState?.task.cancel()
                loadingState = nil
                loadedState = LoadedState(modelName: model.name, model: nativeModel)
            }
        }
        return nativeModel
    }

    /// A transcription ended. The model stays loaded (ModelResidency decides when to release it) unless an unload
    /// was asked for while it ran; `close` goes on once the last one has ended.
    private func endRun() {
        let (didUnload, waiters) = stateLock.withLock { () -> (Bool, [CheckedContinuation<Void, Never>]) in
            activeTranscriptionCount -= 1
            guard activeTranscriptionCount == 0 else { return (false, []) }
            let waiters = idleWaiters
            idleWaiters = []
            guard unloadWhenIdle else { return (false, waiters) }
            unloadWhenIdle = false
            loadingState?.task.cancel()
            loadingState = nil
            loadedState = nil
            return (true, waiters)
        }
        if didUnload {
            logger.notice("transcribe.cpp runtime unloaded after the last transcription")
        }
        waiters.forEach { $0.resume() }
    }

    private func resolveArtifact(for model: TranscribeCppModel) throws -> TranscribeCppModelArtifact {
        guard let artifact = TranscribeCppModelCatalog.artifact(for: model.name) else {
            throw NSError(
                domain: "OfflineTranscribeCppService",
                code: -2,
                userInfo: [NSLocalizedDescriptionKey: "Unsupported transcribe.cpp model"]
            )
        }
        return artifact
    }

    private func selectedLanguage(_ language: String?, for model: TranscribeCppModel) -> String? {
        let compatibleLanguage = TranscriptionLanguageSupport.validLanguageOrFallback(language, for: model)
        guard compatibleLanguage != "auto" else { return nil }
        return compatibleLanguage.split(separator: "-").first.map(String.init)?.lowercased()
    }

    private func effectiveMaximumChunkSeconds(
        configuredMaximum: Int,
        capabilitiesMaximumMilliseconds: Int64
    ) -> Int {
        guard capabilitiesMaximumMilliseconds > 0 else { return configuredMaximum }
        let capabilitiesMaximum = Swift.max(1, Int(capabilitiesMaximumMilliseconds / 1_000))
        return Swift.min(configuredMaximum, capabilitiesMaximum)
    }

    private func joinedText(from chunks: [(text: String, language: String?)]) -> String {
        chunks.enumerated().reduce(into: "") { result, entry in
            let (index, chunk) = entry
            if index > 0, languageUsesSpaces(chunk.language) {
                result.append(" ")
            }
            result.append(chunk.text)
        }
    }

    private func languageUsesSpaces(_ language: String?) -> Bool {
        guard let language else { return true }
        return language != "ja" && language != "yue" && language != "zh"
    }

    private static func initializeBackendsIfNeeded() throws {
        try backendInitializationLock.withLock {
            guard !backendsInitialized else { return }
            try Transcribe.initBackends()
            backendsInitialized = true
        }
    }
}

private extension Array where Element == Float {
    /// Splits long-form audio near low-energy boundaries without overlapping samples.
    func energyAwareChunks(
        maximumCount: Int,
        boundarySearchCount: Int,
        energyWindowCount: Int
    ) -> [[Float]] {
        guard maximumCount > 0, count > maximumCount else { return [self] }

        let safeBoundarySearch = Swift.max(1, Swift.min(boundarySearchCount, maximumCount))
        let safeEnergyWindow = Swift.max(1, energyWindowCount)
        var chunks: [[Float]] = []
        var start = 0

        while start < count {
            let maximumEnd = Swift.min(start + maximumCount, count)
            if maximumEnd == count {
                chunks.append(Array(self[start..<maximumEnd]))
                break
            }

            let searchStart = Swift.max(start, maximumEnd - safeBoundarySearch)
            let splitPoint = quietestWindowStart(
                from: searchStart,
                to: maximumEnd,
                windowCount: safeEnergyWindow
            )
            let safeSplitPoint = Swift.max(start + 1, Swift.min(splitPoint, count))
            chunks.append(Array(self[start..<safeSplitPoint]))
            start = safeSplitPoint
        }

        return chunks
    }

    private func quietestWindowStart(from start: Int, to end: Int, windowCount: Int) -> Int {
        guard end - start > windowCount else { return (start + end) / 2 }

        var quietestStart = start
        var lowestEnergy = Double.infinity
        let finalWindowStart = end - windowCount
        var candidateStarts = [Int](stride(from: start, through: finalWindowStart, by: windowCount))
        if candidateStarts.last != finalWindowStart {
            candidateStarts.append(finalWindowStart)
        }

        for windowStart in candidateStarts {
            var squaredSampleSum = 0.0
            for sample in self[windowStart..<(windowStart + windowCount)] {
                let value = Double(sample)
                squaredSampleSum += value * value
            }
            let meanSquaredEnergy = squaredSampleSum / Double(windowCount)
            if meanSquaredEnergy < lowestEnergy {
                lowestEnergy = meanSquaredEnergy
                quietestStart = windowStart
            }
        }

        return quietestStart
    }
}
