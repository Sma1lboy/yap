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

    func loadModel(_ model: WhisperModelFile) async throws {
        guard whisperContext == nil else { return }

        isModelLoading = true
        defer { isModelLoading = false }

        do {
            whisperContext = try await WhisperContext.createContext(path: model.url.path)

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

            if shouldWarmup(model) {
                WhisperModelWarmupCoordinator.shared.scheduleWarmup(for: model, whisperModelManager: self)
            }
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

    private func shouldWarmup(_ model: WhisperModel) -> Bool {
        !model.name.contains("q5") && !model.name.contains("q8")
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

    func unloadModel() {
        Task {
            await whisperContext?.releaseResources()
            whisperContext = nil
            isModelLoaded = false
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
        await whisperContext?.releaseResources()
        whisperContext = nil
        isModelLoaded = false
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
