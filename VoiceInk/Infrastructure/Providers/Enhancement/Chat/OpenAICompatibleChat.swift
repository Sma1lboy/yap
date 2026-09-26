import Foundation
import LLMkit

/// Chat completions for OpenAI-compatible endpoints (Groq, Cerebras, OpenAI, Mistral, custom servers).
///
/// Replaces LLMkit's OpenAILLMClient for enhancement because that client (upstream's package, which we
/// don't change) always sends `temperature` and decodes only the message text:
/// - no output cap is requested, so the server default wins (Groq: 2048 tokens, about 8,000 characters
///   of cleaned text) and the reply is cut mid-sentence (upstream #973);
/// - `finish_reason` is thrown away, so that cut text was pasted as if complete;
/// - models that only accept the default temperature (gpt-5.x, Azure deployments) reject every request
///   with HTTP 400 even though the connection test passes (upstream #927).
enum OpenAICompatibleChat {
    /// Large enough for any dictation; a server that rejects it gets a retry without it.
    static let maxCompletionTokens = 16_384

    /// Parameters we send by choice rather than necessity. A 4xx that names one of them is answered by
    /// one retry without it, so each server ends up with the most we can send.
    static let optionalParameters = ["temperature", "max_completion_tokens"]

    static func complete(
        baseURL: URL,
        apiKey: String,
        model: String,
        messages: [ChatMessage],
        systemPrompt: String?,
        reasoningEffort: String? = nil,
        extraBody: [String: Any]? = nil,
        timeout: TimeInterval
    ) async throws -> String {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LLMKitError.missingAPIKey
        }
        var allMessages = messages
        if let systemPrompt, !systemPrompt.isEmpty {
            allMessages.insert(.system(systemPrompt), at: 0)
        }
        var body: [String: Any] = [
            "model": model,
            "messages": allMessages.map { ["role": $0.role, "content": $0.content] },
            "temperature": 0.3,
            "max_completion_tokens": maxCompletionTokens,
            "stream": false,
        ]
        if let reasoningEffort {
            body["reasoning_effort"] = reasoningEffort
        }
        extraBody?.forEach { body[$0.key] = $0.value }

        var dropped: Set<String> = []
        while true {
            let (status, data) = try await send(body, to: baseURL, apiKey: apiKey, timeout: timeout)
            let message = String(data: data, encoding: .utf8) ?? ""
            if (400..<500).contains(status),
                let parameter = rejectedParameter(in: message, sent: body.keys, alreadyDropped: dropped)
            {
                body.removeValue(forKey: parameter)
                dropped.insert(parameter)
                continue
            }
            guard (200..<300).contains(status) else {
                throw LLMKitError.httpError(statusCode: status, message: message)
            }
            let reply = try parse(data)
            guard !OpenRouterRequestPolicy.outputWasTruncated(finishReason: reply.finishReason) else {
                throw EnhancementError.outputTruncated
            }
            return reply.text
        }
    }

    /// The optional parameter a 4xx body complains about, if any and not already dropped.
    static func rejectedParameter(
        in message: String, sent: Dictionary<String, Any>.Keys, alreadyDropped: Set<String>
    ) -> String? {
        optionalParameters.first { sent.contains($0) && !alreadyDropped.contains($0) && message.contains($0) }
    }

    static func parse(_ data: Data) throws -> (text: String, finishReason: String?) {
        struct Response: Decodable {
            struct Choice: Decodable {
                struct Message: Decodable { let content: String? }
                let message: Message
                let finish_reason: String?
            }
            let choices: [Choice]
        }
        do {
            let choice = try JSONDecoder().decode(Response.self, from: data).choices.first
            return (choice?.message.content ?? "", choice?.finish_reason)
        } catch {
            throw LLMKitError.decodingError(error.localizedDescription)
        }
    }

    /// Retries network failures and 429/5xx twice (1 s, 2 s), like LLMkit's client did.
    private static func send(
        _ body: [String: Any], to url: URL, apiKey: String, timeout: TimeInterval
    ) async throws -> (Int, Data) {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        guard let httpBody = try? JSONSerialization.data(withJSONObject: body) else {
            throw LLMKitError.encodingError
        }
        request.httpBody = httpBody

        var attempt = 0
        while true {
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                if [429, 500, 502, 503, 504].contains(status), attempt < 2 {
                    attempt += 1
                    try await Task.sleep(nanoseconds: UInt64(attempt) * 1_000_000_000)
                    continue
                }
                return (status, data)
            } catch let error as URLError where error.code == .timedOut {
                throw LLMKitError.timeout
            } catch let error as URLError where attempt < 2 && error.code != .cancelled {
                attempt += 1
                try await Task.sleep(nanoseconds: UInt64(attempt) * 1_000_000_000)
            } catch let error as URLError {
                throw LLMKitError.networkError(error.localizedDescription)
            }
        }
    }

    #if DEBUG
        static func selfCheck() {
            let sent: [String: Any] = ["model": "m", "temperature": 0.3, "max_completion_tokens": 1]
            let azure = #"{"error":{"message":"Unsupported value: 'temperature' does not support 0.3 with this model.","param":"temperature"}}"#
            assert(rejectedParameter(in: azure, sent: sent.keys, alreadyDropped: []) == "temperature")
            assert(rejectedParameter(in: azure, sent: sent.keys, alreadyDropped: ["temperature"]) == nil)
            let mistral = #"{"detail":[{"type":"extra_forbidden","loc":["body","max_completion_tokens"]}]}"#
            assert(rejectedParameter(in: mistral, sent: sent.keys, alreadyDropped: []) == "max_completion_tokens")
            assert(rejectedParameter(in: #"{"error":"invalid api key"}"#, sent: sent.keys, alreadyDropped: []) == nil)

            let cut = #"{"choices":[{"message":{"content":"Point number 67"},"finish_reason":"length"}]}"#
            assert((try? parse(Data(cut.utf8)))?.finishReason == "length")
            let ok = #"{"choices":[{"message":{"content":"done"},"finish_reason":"stop"}]}"#
            assert((try? parse(Data(ok.utf8)))?.text == "done")
            assert(OpenRouterRequestPolicy.outputWasTruncated(finishReason: "length"))
        }
    #endif
}
