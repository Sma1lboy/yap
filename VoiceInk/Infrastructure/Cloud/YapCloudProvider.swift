import CryptoKit
import Foundation
import SwiftData

/// Speech-to-text through Yap Cloud's `/v1/audio/transcriptions` (OpenRouter behind it).
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

    /// paygate forwards OpenRouter's JSON transcription body (`{model, input_audio:{data, format}}`) and rejects
    /// multipart, so LLMkit's clients (multipart; OpenRouter's is pinned to openrouter.ai) can't be reused here.
    func transcribe(
        audioData: Data, fileName: String, apiKey: String, model: String, language: String?,
        customVocabulary: [String], timeout: TimeInterval
    ) async throws -> String {
        defer { YapCloud.shared.scheduleBalanceRefresh() }
        var body: [String: Any] = [
            "model": model,
            "input_audio": ["data": audioData.base64EncodedString(), "format": Self.audioFormat(fileName)],
        ]
        if let language, !language.isEmpty { body["language"] = language }

        var request = URLRequest(url: YapCloud.shared.baseURL.appendingPathComponent("v1/audio/transcriptions"))
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        // Ephemeral session, as for custom endpoints: avoids HTTP/3 uploads that stall behind some VPNs.
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw CloudTranscriptionError.networkError(URLError(.badServerResponse))
        }
        guard (200..<300).contains(http.statusCode) else {
            throw YapCloudError(status: http.statusCode, body: data, authenticated: true)
        }
        guard let text = (try? JSONDecoder().decode(Response.self, from: data))?.text, !text.isEmpty else {
            throw CloudTranscriptionError.noTranscriptionReturned
        }
        return text
    }

    private struct Response: Decodable {
        let text: String?
    }

    static func audioFormat(_ fileName: String) -> String {
        let ext = (fileName as NSString).pathExtension.lowercased()
        return ext.isEmpty ? "wav" : ext
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
