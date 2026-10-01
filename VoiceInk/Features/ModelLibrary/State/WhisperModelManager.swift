import Atomics
import Foundation
import SwiftUI
import Zip
import os

// MARK: - WhisperModelFile

struct WhisperModelFile: Identifiable {
    let id = UUID()
    let name: String
    let url: URL
    var coreMLEncoderURL: URL?  // Path to the unzipped .mlmodelc directory
    var isCoreMLDownloaded: Bool { coreMLEncoderURL != nil }

    var downloadURL: String {
        "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/\(filename)"
    }

    var filename: String {
        "\(name).bin"
    }

    // Core ML related properties
    var coreMLZipDownloadURL: String? {
        // Only non-quantized models have Core ML versions
        guard !name.contains("q5") && !name.contains("q8") else { return nil }
        return "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/\(name)-encoder.mlmodelc.zip"
    }

    var coreMLEncoderDirectoryName: String? {
        guard coreMLZipDownloadURL != nil else { return nil }
        return "\(name)-encoder.mlmodelc"
    }
}

// MARK: - WhisperModelManager

@MainActor
class WhisperModelManager: ObservableObject {
    @Published var availableModels: [WhisperModelFile] = []
    @Published var downloadProgress: [String: Double] = [:]
    /// Why the last download of a model failed, by model name; cleared when a new download starts.
    @Published var downloadErrors: [String: String] = [:]
    /// Bytes and transfer rate by progress key (`<name>_main`, `<name>_coreml`), for "120 MB of 547 MB · 1 min left".
    @Published var downloadDetails: [String: ModelFileDownloader.Progress] = [:]
    @Published var whisperContext: WhisperContext?
    @Published var isModelLoaded = false
    @Published var loadedWhisperModel: WhisperModelFile?
    @Published var isModelLoading = false
    private var activeDownloadTasks: [String: Task<Void, Never>] = [:]
    private var loadTask: Task<Void, Error>?
    /// How a load turns a model file into a context; selfCheck replaces it to count loads without a model.
    var makeContext: (WhisperModelFile) async throws -> WhisperContext = {
        try await WhisperContext.createContext(path: $0.url.path)
    }

    let modelsDirectory: URL
    let whisperPrompt = WhisperPrompt()

    /// Called when a model is deleted, passing the model name.
    /// TranscriptionModelManager listens to clear currentTranscriptionModel if needed.
    var onModelDeleted: ((String) -> Void)?

    /// Called after a new model is added (downloaded or imported) so
    /// TranscriptionModelManager can rebuild allAvailableModels.
    var onModelsChanged: (() -> Void)?

    let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "WhisperModelManager")

    init(modelsDirectory: URL) {
        self.modelsDirectory = modelsDirectory
    }

    // MARK: - Model Directory Management

    func createModelsDirectoryIfNeeded() {
        do {
            try FileManager.default.createDirectory(
                at: modelsDirectory, withIntermediateDirectories: true, attributes: nil)
        } catch {
            logError("Error creating models directory", error)
        }
    }

    func loadAvailableModels() {
        ModelFileDownloader.removeStalePartials(in: modelsDirectory)
        do {
            let fileURLs = try FileManager.default.contentsOfDirectory(
                at: modelsDirectory, includingPropertiesForKeys: nil)
            availableModels = fileURLs.compactMap { url in
                guard url.pathExtension == "bin" else { return nil }
                return WhisperModelFile(name: url.deletingPathExtension().lastPathComponent, url: url)
            }
        } catch {
            logError("Error loading available models", error)
        }
    }

    // MARK: - Model Loading

    /// One load at a time: the shortcut-press preload, the load after the mode is applied and a transcription
    /// (`context(forModelNamed:)`) share it.
    func loadModel(_ model: WhisperModelFile) async throws {
        if let loadTask { return try await loadTask.value }
        guard whisperContext == nil else { return }

        // Cleared by the load itself, so whoever waits on it sees it gone as soon as it finishes.
        let task = Task {
            defer { self.loadTask = nil }
            try await self.createContext(for: model)
        }
        loadTask = task
        try await task.value
    }

    func finishPendingLoad() async {
        try? await loadTask?.value
    }

    /// The shared context holding the model named `name`, for a transcription. A load already running (the
    /// shortcut-press preload) is waited for instead of started again, and a different loaded model is released
    /// before this one loads, so a dictation never holds two copies. `waited` is true when the transcription had to
    /// wait for a load.
    func context(forModelNamed name: String) async throws -> (context: WhisperContext, waited: Bool) {
        var waited = false
        while true {
            if let loadTask {
                waited = true
                _ = try? await loadTask.value
            } else if let whisperContext, isModelLoaded, loadedWhisperModel?.name == name {
                return (whisperContext, waited)
            } else {
                guard let model = availableModels.first(where: { $0.name == name }),
                    FileManager.default.fileExists(atPath: model.url.path)
                else {
                    logger.error("❌ Model file not found for: \(name, privacy: .public)")
                    throw VoiceInkEngineError.modelLoadFailed
                }
                waited = true
                if whisperContext != nil { await cleanupResources() }
                try await loadModel(model)
            }
        }
    }

    private func createContext(for model: WhisperModelFile) async throws {
        isModelLoading = true
        defer { isModelLoading = false }

        do {
            whisperContext = try await makeContext(model)

            let currentPrompt =
                UserDefaults.standard.string(forKey: "TranscriptionPrompt") ?? whisperPrompt.transcriptionPrompt
            await whisperContext?.setPrompt(currentPrompt)

            isModelLoaded = true
            loadedWhisperModel = model
        } catch {
            throw VoiceInkEngineError.modelLoadFailed
        }
    }

    // MARK: - Model Download & Management

    /// Downloads `url` to `destination` through ModelFileDownloader (size and sha256 checked, `.part` until
    /// verified, disk space checked first). A dropped connection or a cancel keeps URLSession's resume data in
    /// `<destination>.resume`, so the next attempt continues where this one stopped; if the server refuses that
    /// resume (an expired CDN link), the download starts over once.
    private func downloadFile(from url: URL, to destination: URL, progressKey: String) async throws {
        let resumeURL = ModelFileDownloader.resumeDataURL(for: destination)
        let expected = await ModelFileDownloader.fetchExpected(for: url)
        let onProgress: @Sendable (ModelFileDownloader.Progress) -> Void = { [weak self] progress in
            DispatchQueue.main.async {
                guard let self, self.downloadProgress[progressKey] != nil else { return }
                self.downloadProgress[progressKey] = progress.fraction
                self.downloadDetails[progressKey] = progress
            }
        }
        var resumeData = try? Data(contentsOf: resumeURL)
        while true {
            do {
                try await ModelFileDownloader.download(
                    url, to: destination, expected: expected, resumeData: resumeData, onProgress: onProgress)
                try? FileManager.default.removeItem(at: resumeURL)
                return
            } catch let interrupted as ModelFileDownloader.Interrupted {
                if let data = interrupted.resumeData {
                    try? data.write(to: resumeURL, options: .atomic)
                }
                throw interrupted.underlying is CancellationError ? CancellationError() : interrupted
            } catch ModelFileDownloader.Failure.badResponse(let status) where resumeData != nil {
                logger.notice("Resume refused (HTTP \(status, privacy: .public)); starting \(url.lastPathComponent, privacy: .public) over")
                try? FileManager.default.removeItem(at: resumeURL)
                resumeData = nil
            } catch {
                try? FileManager.default.removeItem(at: resumeURL)
                throw error
            }
        }
    }

    func downloadModel(_ model: WhisperModel) async {
        guard let url = URL(string: model.downloadURL) else { return }
        await performModelDownload(model, url)
    }

    func startDownload(_ model: WhisperModel) {
        guard activeDownloadTasks[model.name] == nil else { return }
        downloadProgress[model.name + "_main"] = 0
        downloadErrors[model.name] = nil
        activeDownloadTasks[model.name] = Task { [weak self] in
            guard let self else { return }
            await self.downloadModel(model)
            self.activeDownloadTasks[model.name] = nil
        }
    }

    func cancelDownload(_ model: WhisperModel) {
        activeDownloadTasks[model.name]?.cancel()
    }

    private func performModelDownload(_ model: WhisperModel, _ url: URL) async {
        var committedMainModel: WhisperModelFile?

        do {
            var whisperModel = try await downloadMainModel(model, from: url)
            committedMainModel = whisperModel
            try Task.checkCancellation()

            if let coreMLZipURL = whisperModel.coreMLZipDownloadURL,
                let coreMLURL = URL(string: coreMLZipURL)
            {
                whisperModel = try await downloadAndSetupCoreMLModel(for: whisperModel, from: coreMLURL)
            }

            try Task.checkCancellation()
            availableModels.append(whisperModel)
            self.downloadProgress.removeValue(forKey: model.name + "_main")
            self.downloadDetails.removeValue(forKey: model.name + "_main")

            onModelsChanged?()

            WhisperModelWarmupCoordinator.shared.scheduleWarmup(for: model, whisperModelManager: self)
        } catch is CancellationError {
            removePartialDownload(for: model, preserveMainModel: committedMainModel != nil)
            if let committedMainModel,
                !availableModels.contains(where: { $0.name == committedMainModel.name })
            {
                availableModels.append(committedMainModel)
                onModelsChanged?()
            }
            handleModelDownloadError(model, CancellationError())
        } catch {
            handleModelDownloadError(model, error)
        }
    }

    private func removePartialDownload(for model: WhisperModel, preserveMainModel: Bool) {
        if !preserveMainModel {
            try? FileManager.default.removeItem(at: modelsDirectory.appendingPathComponent(model.filename))
        }
        try? FileManager.default.removeItem(
            at: modelsDirectory.appendingPathComponent("\(model.name)-encoder.mlmodelc.zip")
        )
        try? FileManager.default.removeItem(
            at: modelsDirectory.appendingPathComponent("\(model.name)-encoder.mlmodelc")
        )
    }

    private func downloadMainModel(_ model: WhisperModel, from url: URL) async throws -> WhisperModelFile {
        let destinationURL = modelsDirectory.appendingPathComponent(model.filename)
        try await downloadFile(from: url, to: destinationURL, progressKey: model.name + "_main")
        try Task.checkCancellation()
        return WhisperModelFile(name: model.name, url: destinationURL)
    }

    private func downloadAndSetupCoreMLModel(for model: WhisperModelFile, from url: URL) async throws
        -> WhisperModelFile
    {
        let progressKeyCoreML = model.name + "_coreml"
        let coreMLZipPath = modelsDirectory.appendingPathComponent("\(model.name)-encoder.mlmodelc.zip")
        downloadProgress[progressKeyCoreML] = 0
        try await downloadFile(from: url, to: coreMLZipPath, progressKey: progressKeyCoreML)
        try Task.checkCancellation()

        return try await unzipAndSetupCoreMLModel(for: model, zipPath: coreMLZipPath, progressKey: progressKeyCoreML)
    }

    private func unzipAndSetupCoreMLModel(for model: WhisperModelFile, zipPath: URL, progressKey: String) async throws
        -> WhisperModelFile
    {
        let coreMLDestination = modelsDirectory.appendingPathComponent("\(model.name)-encoder.mlmodelc")

        try? FileManager.default.removeItem(at: coreMLDestination)
        try Task.checkCancellation()
        try await unzipCoreMLFile(zipPath, to: modelsDirectory)
        try Task.checkCancellation()
        return try verifyAndCleanupCoreMLFiles(model, coreMLDestination, zipPath, progressKey)
    }

    private func unzipCoreMLFile(_ zipPath: URL, to destination: URL) async throws {
        let finished = ManagedAtomic(false)

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            func finishOnce(_ result: Result<Void, Error>) {
                if finished.exchange(true, ordering: .acquiring) == false {
                    continuation.resume(with: result)
                }
            }

            do {
                try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
                try Zip.unzipFile(zipPath, destination: destination, overwrite: true, password: nil)
                finishOnce(.success(()))
            } catch {
                finishOnce(.failure(error))
            }
        }
    }

    private func verifyAndCleanupCoreMLFiles(
        _ model: WhisperModelFile, _ destination: URL, _ zipPath: URL, _ progressKey: String
    ) throws -> WhisperModelFile {
        var model = model

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: destination.path, isDirectory: &isDirectory), isDirectory.boolValue
        else {
            try? FileManager.default.removeItem(at: zipPath)
            throw VoiceInkEngineError.unzipFailed
        }

        try? FileManager.default.removeItem(at: zipPath)
        model.coreMLEncoderURL = destination
        self.downloadProgress.removeValue(forKey: progressKey)

        return model
    }

    private func handleModelDownloadError(_ model: WhisperModel, _ error: Error) {
        if !(error is CancellationError) { downloadErrors[model.name] = error.localizedDescription }
        self.downloadProgress.removeValue(forKey: model.name + "_main")
        self.downloadProgress.removeValue(forKey: model.name + "_coreml")
        self.downloadDetails.removeValue(forKey: model.name + "_main")
        self.downloadDetails.removeValue(forKey: model.name + "_coreml")
    }

    func deleteModel(_ model: WhisperModelFile) async {
        do {
            try FileManager.default.removeItem(at: model.url)

            if let coreMLURL = model.coreMLEncoderURL {
                try? FileManager.default.removeItem(at: coreMLURL)
            } else {
                let coreMLDir = modelsDirectory.appendingPathComponent("\(model.name)-encoder.mlmodelc")
                if FileManager.default.fileExists(atPath: coreMLDir.path) {
                    try? FileManager.default.removeItem(at: coreMLDir)
                }
            }

            availableModels.removeAll { $0.id == model.id }

            // Notify TranscriptionModelManager to clear currentTranscriptionModel if it matches
            onModelDeleted?(model.name)
        } catch {
            logError("Error deleting model: \(model.name)", error)
        }
    }

    func clearDownloadedModels() async {
        for model in availableModels {
            do {
                try FileManager.default.removeItem(at: model.url)
            } catch {
                logError("Error deleting model during cleanup", error)
            }
        }
        availableModels.removeAll()
    }

    // MARK: - Resource Management

    /// Releases the WhisperContext and resets model-loaded state.
    /// Does NOT call serviceRegistry.cleanup() — that is VoiceInkEngine's responsibility.
    func cleanupResources() async {
        logger.notice("WhisperModelManager.cleanupResources: releasing whisper context")
        await finishPendingLoad()
        // Cleared before the release finishes: a preload that starts meanwhile then loads a fresh copy instead of
        // finding this one, skipping, and leaving the dictation to load it again after the stop.
        let releasing = whisperContext
        whisperContext = nil
        isModelLoaded = false
        await releasing?.releaseResources()
        logger.notice("WhisperModelManager.cleanupResources: completed")
    }

    // MARK: - Import Local Model

    func importWhisperModel(from sourceURL: URL) async {
        guard sourceURL.pathExtension.lowercased() == "bin" else { return }

        let baseName = sourceURL.deletingPathExtension().lastPathComponent
        let destinationURL = modelsDirectory.appendingPathComponent("\(baseName).bin")

        if FileManager.default.fileExists(atPath: destinationURL.path) {
            NotificationManager.shared.showNotification(
                title: String(format: String(localized: "A model named %@.bin already exists"), baseName),
                type: .warning,
                duration: 4.0
            )
            return
        }

        do {
            try FileManager.default.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: sourceURL, to: destinationURL)

            let newWhisperModel = WhisperModelFile(name: baseName, url: destinationURL)
            availableModels.append(newWhisperModel)

            onModelsChanged?()

            NotificationManager.shared.showNotification(
                title: String(format: String(localized: "Imported %@"), destinationURL.lastPathComponent),
                type: .success,
                duration: 3.0
            )
        } catch {
            logError("Failed to import local model", error)
            NotificationManager.shared.showNotification(
                title: String(format: String(localized: "Failed to import model: %@"), error.localizedDescription),
                type: .error,
                duration: 5.0
            )
        }
    }

    // MARK: - Helpers

    private func logError(_ message: String, _ error: Error) {
        logger.error("❌ \(message, privacy: .public): \(error, privacy: .public)")
    }
}

// MARK: - WhisperModelProvider

extension WhisperModelManager: WhisperModelProvider {}

#if DEBUG
    extension WhisperModelManager {
        /// Loads are counted with placeholder contexts (no model file is read): a dictation stopped while the press's
        /// preload is still loading waits for it, a press during a release still preloads, and a dictation needing a
        /// different model releases the loaded one first.
        static func selfCheck() async {
            final class Loads { var names: [String] = [] }
            let loads = Loads()
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("yap-model-load-\(UUID())")
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let files = ["a", "b"].map { WhisperModelFile(name: $0, url: directory.appendingPathComponent("\($0).bin")) }
            for file in files { FileManager.default.createFile(atPath: file.url.path, contents: Data()) }

            let manager = WhisperModelManager(modelsDirectory: directory)
            manager.availableModels = files
            manager.makeContext = { file in
                loads.names.append(file.name)
                try await Task.sleep(for: .milliseconds(30))
                return WhisperContext.placeholder()
            }
            func ready(_ name: String) async -> (context: WhisperContext, waited: Bool)? {
                try? await manager.context(forModelNamed: name)
            }

            // Stopped while the press's preload is loading: that load is waited for, not repeated.
            let preload = Task { try? await manager.loadModel(files[0]) }
            await Task.yield()
            let stopped = await ready("a")
            await preload.value
            precondition(loads.names == ["a"] && stopped?.waited == true, "one load, waited for: \(loads.names)")
            precondition(stopped?.context === manager.whisperContext)
            let again = await ready("a")
            precondition(again?.waited == false && loads.names == ["a"], "loaded: used as is")

            // The next press comes while the last dictation's release is still running: it loads a fresh copy.
            let release = Task { await manager.cleanupResources() }
            let nextPress = Task { try? await manager.loadModel(files[0]) }
            await release.value
            await nextPress.value
            precondition(manager.whisperContext != nil && loads.names == ["a", "a"], "preloaded: \(loads.names)")
            let afterPress = await ready("a")
            precondition(afterPress?.waited == false && loads.names == ["a", "a"])

            // The mode wants another model: the loaded one goes first, so there is only ever one.
            let other = await ready("b")
            precondition(other?.waited == true && loads.names == ["a", "a", "b"])
            precondition(manager.loadedWhisperModel?.name == "b" && other?.context === manager.whisperContext)
            let missing = await ready("missing")
            precondition(missing == nil && loads.names == ["a", "a", "b"])
            await manager.cleanupResources()
        }
    }
#endif

// MARK: - Download Progress View

struct DownloadProgressView: View {
    let modelName: String
    let downloadProgress: [String: Double]
    var downloadDetails: [String: ModelFileDownloader.Progress] = [:]
    var isOptimizing = false

    @Environment(\.colorScheme) private var colorScheme

    private var mainProgress: Double {
        downloadProgress[modelName + "_main"] ?? 0
    }

    private var coreMLProgress: Double {
        supportsCoreML ? (downloadProgress[modelName + "_coreml"] ?? 0) : 0
    }

    private var supportsCoreML: Bool {
        !modelName.contains("q5") && !modelName.contains("q8")
    }

    private var totalProgress: Double {
        if isOptimizing {
            return 1
        }

        return supportsCoreML ? (mainProgress * 0.5) + (coreMLProgress * 0.5) : mainProgress
    }

    private var downloadPhase: String {
        if isOptimizing {
            return String(localized: "Optimizing model for your device")
        }

        if supportsCoreML && downloadProgress[modelName + "_coreml"] != nil {
            return String(format: String(localized: "Downloading Core ML Model for %@"), modelName)
        }
        return String(format: String(localized: "Downloading %@ Model"), modelName)
    }

    /// The transfer running now: Core ML once it has started, else the main model.
    private var activeDetail: ModelFileDownloader.Progress? {
        downloadDetails[modelName + "_coreml"] ?? downloadDetails[modelName + "_main"]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.x2) {
            HStack {
                Text(downloadPhase)
                    .lineLimit(1)

                if !isOptimizing, let summary = activeDetail?.summary {
                    Text(summary)
                        .lineLimit(1)
                }

                Spacer()

                Text(totalProgress, format: .percent.precision(.fractionLength(0)))
                    .fontDesign(.monospaced)
            }
            .font(AppTheme.font(.footnote, .medium))
            .foregroundColor(Color(.secondaryLabelColor))

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: AppTheme.Radius.small)
                        .fill(AppTheme.Border.control.opacity(0.3))
                        .frame(height: 6)

                    RoundedRectangle(cornerRadius: AppTheme.Radius.small)
                        .fill(AppTheme.Accent.primary)
                        .frame(width: max(0, min(geometry.size.width * totalProgress, geometry.size.width)), height: 6)
                }
            }
            .frame(height: 6)
        }
        .padding(.vertical, AppTheme.Spacing.x1)
    }
}
