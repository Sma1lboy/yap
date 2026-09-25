import CryptoKit
import Foundation
import LLMkit
import SwiftData

/// Speech-to-text through Yap Cloud's OpenAI-compatible `/v1/audio/transcriptions` (OpenRouter behind it).
struct YapCloudProvider: CloudProvider {
    let modelProvider: ModelProvider = .yapCloud
    let providerKey = YapCloud.providerName
    let languageCodes: [String]? = ["auto"]
    let includesAutoDetect = true

    var models: [CloudModel] {
        YapCloud.shared.transcriptionModels.map { model in
            CloudModel(
                id: Self.stableID(for: model.id),
                name: model.id,
                displayName: model.displayName,
                description: String(localized: "Yap Cloud speech-to-text model, billed to your balance"),
                provider: .yapCloud,
                isMultilingual: true,
                supportedLanguages: ["auto": String(localized: "Auto-detect")]
            )
        }
    }

    func transcribe(
        audioData: Data, fileName: String, apiKey: String, model: String, language: String?,
        customVocabulary: [String], timeout: TimeInterval
    ) async throws -> String {
        do {
            return try await OpenAITranscriptionClient.transcribe(
                baseURL: YapCloud.shared.baseURL,
                audioData: audioData,
                fileName: fileName,
                apiKey: apiKey,
                model: model,
                timeout: timeout
            )
        } catch LLMKitError.httpError(let statusCode, let message) where statusCode == 401 || statusCode == 402 {
            throw YapCloudError(status: statusCode, body: Data(message.utf8), authenticated: true)
        }
    }

    func makeStreamingProvider(modelContext: ModelContext) -> (any StreamingTranscriptionProvider)? { nil }

    func verifyAPIKey(_ key: String) async -> (isValid: Bool, errorMessage: String?) {
        (!key.isEmpty, nil)
    }

    static func stableID(for slug: String) -> UUID {
        let digest = Array(SHA256.hash(data: Data("YapCloud:\(slug)".utf8)))
        return UUID(uuid: (
            digest[0], digest[1], digest[2], digest[3],
            digest[4], digest[5], digest[6], digest[7],
            digest[8], digest[9], digest[10], digest[11],
            digest[12], digest[13], digest[14], digest[15]
        ))
    }
}
