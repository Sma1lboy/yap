import CryptoKit
import Foundation
import LLMkit
import SwiftData

/// Shared persistence for OpenRouter's separate text and speech-to-text catalogs.
final class OpenRouterCatalogStore: @unchecked Sendable {
    enum Kind: String {
        case enhancement = "openRouterModelCatalog"
        case transcription = "openRouterTranscriptionModelCatalog"
    }

    static let shared = OpenRouterCatalogStore()

    private let lock = NSLock()
    private let defaults = UserDefaults.standard
    private var catalogs: [Kind: [OpenRouterModel]] = [:]

    private init() {
        for kind in [Kind.enhancement, .transcription] {
            guard let data = defaults.data(forKey: kind.rawValue),
                let models = try? JSONDecoder().decode([OpenRouterModel].self, from: data)
            else { continue }
            catalogs[kind] = models
        }
    }

    func models(for kind: Kind) -> [OpenRouterModel]? {
        lock.lock()
        defer { lock.unlock() }
        return catalogs[kind]
    }

    func save(_ models: [OpenRouterModel], for kind: Kind) throws {
        let data = try JSONEncoder().encode(models)
        defaults.set(data, forKey: kind.rawValue)
        lock.lock()
        catalogs[kind] = models
        lock.unlock()
    }

    var legacyEnhancementModelIDs: [String] {
        defaults.array(forKey: "openRouterModels") as? [String] ?? []
    }

    func saveLegacyEnhancementModelIDs(_ ids: [String]) {
        defaults.set(ids, forKey: "openRouterModels")
    }
}

enum OpenRouterTranscriptionCatalog {
    static var models: [OpenRouterModel] {
        OpenRouterCatalogStore.shared.models(for: .transcription) ?? []
    }

    @MainActor
    static func refresh() async throws {
        let catalog = try await OpenRouterClient.fetchTranscriptionModelCatalog()
        guard !catalog.isEmpty else { throw LLMKitError.noResultReturned }
        try OpenRouterCatalogStore.shared.save(catalog, for: .transcription)
    }
}

struct OpenRouterProvider: CloudProvider {
    let modelProvider: ModelProvider = .openRouter
    let providerKey = "OpenRouter"
    let languageCodes: [String]? = ["auto"]
    let includesAutoDetect = true

    var models: [CloudModel] {
        OpenRouterTranscriptionCatalog.models.map { model in
            CloudModel(
                id: Self.stableID(for: model.id),
                name: model.id,
                displayName: model.name ?? model.id,
                description: String(localized: "OpenRouter speech-to-text model"),
                provider: .openRouter,
                isMultilingual: true,
                supportedLanguages: ["auto": String(localized: "Auto-detect")]
            )
        }
    }

    func transcribe(
        audioData: Data, fileName: String, apiKey: String, model: String, language: String?,
        customVocabulary: [String], timeout: TimeInterval
    ) async throws -> String {
        var hints: [String: Any] = [:]
        TranscriptionHints.apply(to: &hints, model: model, language: language, vocabulary: customVocabulary)
        guard !hints.isEmpty else {
            return try await OpenRouterTranscriptionClient.transcribe(
                audioData: audioData, fileName: fileName, apiKey: apiKey, model: model, timeout: timeout)
        }
        // LLMkit's client is multipart with only file + model; language and provider.options need the JSON body.
        var body = hints
        body["model"] = model
        body["input_audio"] = ["data": audioData.base64EncodedString(), "format": YapCloudProvider.audioFormat(fileName)]
        return try await Self.transcribeJSON(body: body, apiKey: apiKey, timeout: timeout)
    }

    /// POST JSON to OpenRouter's STT endpoint with LLMkit's behaviour: 2 retries (1 s, 2 s) on network errors and
    /// 429/5xx, failures as `LLMKitError` so CloudTranscriptionService maps them the same way.
    private static func transcribeJSON(body: [String: Any], apiKey: String, timeout: TimeInterval) async throws -> String {
        guard !apiKey.isEmpty else { throw LLMKitError.missingAPIKey }
        var request = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/audio/transcriptions")!, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        var lastError: Error = LLMKitError.networkError("Request failed")
        for attempt in 0...2 {
            if attempt > 0 { try await Task.sleep(for: .seconds(attempt)) }
            // Ephemeral per request, like LLMkit: a shared session learns Alt-Svc and moves uploads to HTTP/3.
            let session = URLSession(configuration: .ephemeral)
            defer { session.finishTasksAndInvalidate() }
            let data: Data, response: URLResponse
            do {
                (data, response) = try await session.data(for: request)
            } catch let error as URLError where error.code == .timedOut {
                throw LLMKitError.timeout
            } catch {
                lastError = LLMKitError.networkError(error.localizedDescription)
                continue
            }
            guard let http = response as? HTTPURLResponse else { throw LLMKitError.networkError("No HTTP response received.") }
            guard (200..<300).contains(http.statusCode) else {
                lastError = LLMKitError.httpError(
                    statusCode: http.statusCode, message: String(data: data, encoding: .utf8) ?? "No error details")
                if http.statusCode == 429 || http.statusCode >= 500 { continue }
                throw lastError
            }
            struct Response: Decodable { let text: String? }
            guard let text = (try? JSONDecoder().decode(Response.self, from: data))?.text, !text.isEmpty else {
                throw LLMKitError.noResultReturned
            }
            return text
        }
        throw lastError
    }

    func makeStreamingProvider(modelContext: ModelContext) -> (any StreamingTranscriptionProvider)? { nil }

    func verifyAPIKey(_ key: String) async -> (isValid: Bool, errorMessage: String?) {
        await OpenRouterClient.verifyAPIKey(key)
    }

    static func stableID(for slug: String) -> UUID {
        let digest = Array(SHA256.hash(data: Data("OpenRouter:\(slug)".utf8)))
        return UUID(uuid: (
            digest[0], digest[1], digest[2], digest[3],
            digest[4], digest[5], digest[6], digest[7],
            digest[8], digest[9], digest[10], digest[11],
            digest[12], digest[13], digest[14], digest[15]
        ))
    }
}
