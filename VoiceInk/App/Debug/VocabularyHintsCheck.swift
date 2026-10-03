#if DEBUG
    import Foundation
    import ObjectiveC
    import SwiftData

    /// `scripts/vocabulary-hints-check.sh`: `--vocabulary-hints-check`, then quits. Fills an in-memory dictionary, then
    /// sends cloud transcriptions through CloudTranscriptionService (what dictation, file import, History re-transcribe
    /// and meetings call) and opens a Deepgram stream (live dictation), and prints the dictionary terms each request
    /// carried, read off the request itself. Every URLSession configuration gets a URLProtocol that records the request
    /// and answers it, so nothing leaves the Mac; the script also runs the app with IP traffic denied. Provider keys come
    /// from YAP_MOCK_API_KEY_*, Yap Cloud from its snapshot sign-in; the user's dictionary and keys are never read.
    /// For local Whisper it prints the initial prompt WhisperTranscriptionService builds for a request against the same
    /// dictionary (no model is loaded). Also: Yap Cloud's MODEL_NOT_ALLOWED fallback (every request it sends), the
    /// words LLMkit keeps for xAI, ElevenLabs and AssemblyAI's per-word limits, and a stream's next connection after
    /// an add. scripts/vocabulary-hints-check.py holds what each request should carry.
    @MainActor
    enum VocabularyHintsCheck {
        static let argument = "--vocabulary-hints-check"

        /// A fixed clock: the dictionary's dates are all relative to this.
        static let start = Date(timeIntervalSince1970: 1_800_000_000)

        struct Captured {
            let url: URL
            let contentType: String?
            let body: Data
        }

        /// Records each request and answers 200 with the body its client decodes; websockets get a failed handshake.
        /// A Yap Cloud transcription whose model is in `refusedModels` gets paygate's 400 MODEL_NOT_ALLOWED instead.
        final class Recorder: URLProtocol {
            nonisolated(unsafe) static var requests: [Captured] = []
            nonisolated(unsafe) static var refusedModels: Set<String> = []
            static let lock = NSLock()

            override class func canInit(with request: URLRequest) -> Bool { true }
            override class func canInit(with task: URLSessionTask) -> Bool { true }
            override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

            override func startLoading() {
                guard let url = request.url else { return }
                var body = request.httpBody ?? Data()
                if body.isEmpty, let stream = request.httpBodyStream {
                    stream.open()
                    var buffer = [UInt8](repeating: 0, count: 65_536)
                    while stream.hasBytesAvailable {
                        let count = stream.read(&buffer, maxLength: buffer.count)
                        guard count > 0 else { break }
                        body.append(buffer, count: count)
                    }
                    stream.close()
                }
                Self.lock.withLock {
                    Self.requests.append(
                        Captured(url: url, contentType: request.value(forHTTPHeaderField: "Content-Type"), body: body))
                }
                if url.scheme == "wss" {
                    client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
                    return
                }
                let model = (try? JSONSerialization.jsonObject(with: body) as? [String: Any])?["model"] as? String
                if url.host == "cloud.yap.sma1lboy.me", url.path == "/v1/audio/transcriptions", let model,
                    Self.lock.withLock({ Self.refusedModels.contains(model) })
                {
                    let refusal = #"{"error":{"code":"MODEL_NOT_ALLOWED","message":"model \#(model) is not available"}}"#
                    let response = HTTPURLResponse(url: url, statusCode: 400, httpVersion: nil, headerFields: nil)!
                    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                    client?.urlProtocol(self, didLoad: Data(refusal.utf8))
                    client?.urlProtocolDidFinishLoading(self)
                    return
                }
                let answer =
                    url.host == "api.deepgram.com"
                    ? #"{"results":{"channels":[{"alternatives":[{"transcript":"ok"}]}]}}"# : #"{"text":"ok"}"#
                let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: Data(answer.utf8))
                client?.urlProtocolDidFinishLoading(self)
            }

            override func stopLoading() {}

            static func take() -> [Captured] {
                lock.withLock {
                    defer { requests = [] }
                    return requests
                }
            }
        }

        static func runIfRequested() {
            guard CommandLine.arguments.contains(argument) else { return }
            installRecorder()
            YapCloud.isSnapshotMode = true
            YapCloud.shared.applySnapshotState(.funded)

            let audio = FileManager.default.temporaryDirectory.appendingPathComponent(
                "yap-vocabulary-hints-\(UUID().uuidString).wav")
            try! Data("RIFF fixture audio".utf8).write(to: audio)
            defer { try? FileManager.default.removeItem(at: audio) }

            // 1. A hundred older words, then one added last: more than the 100 the capped requests send.
            let container = try! ModelContainer(
                for: VocabularyWord.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
            let context = ModelContext(container)
            for index in 0..<100 {
                context.insert(VocabularyWord(word: String(format: "A%03d", index), dateAdded: start.addingTimeInterval(Double(index))))
            }
            let newest = VocabularyWord(word: "ZNewestName", dateAdded: start.addingTimeInterval(1_000))
            context.insert(newest)
            try! context.save()
            sendAll(name: "over-budget", context: context, audio: audio)
            let whisper = localService(context)
            local(name: "over-budget", service: whisper)

            // 2. The next request after a delete and an add: no cache keeps the old set (the same local service).
            context.delete(newest)
            context.insert(VocabularyWord(word: "YAnother", dateAdded: start.addingTimeInterval(2_000)))
            try! context.save()
            send(name: "after-edit", model: deepgram, context: context, audio: audio)
            local(name: "after-edit", service: whisper)

            // 3. Under the budget: blanks, a case duplicate (the newer spelling), same-date CJK and mixed words.
            let small = ModelContext(
                try! ModelContainer(for: VocabularyWord.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true)))
            for (word, offset) in [
                (" Kubernetes ", 1.0), ("张三丰", 2.0), ("kubernetes", 3.0), ("   ", 4.0), ("useEffect", 5.0), ("React组件", 2.0),
            ] {
                small.insert(VocabularyWord(word: word, dateAdded: start.addingTimeInterval(offset)))
            }
            try! small.save()
            send(name: "under-budget", model: deepgram, context: small, audio: audio)
            stream(name: "under-budget", model: deepgram, provider: deepgramStream(small), language: "en")
            send(name: "under-budget", model: openRouter("openai/gpt-4o-transcribe"), context: small, audio: audio)
            local(name: "under-budget", service: localService(small))

            // Yap Cloud refuses the chosen model (MODEL_NOT_ALLOWED) and the one retry goes to the Recommended model:
            // each request must carry the terms field of the model it names, nothing left over from the other.
            fallback(name: "fallback-from-gpt-4o", model: "openai/gpt-4o-transcribe", refused: ["openai/gpt-4o-transcribe"],
                context: small, audio: audio, language: "zh-Hans")
            fallback(name: "fallback-from-qwen", model: "qwen/qwen3-asr-flash-2026-02-10",
                refused: ["qwen/qwen3-asr-flash-2026-02-10"], context: small, audio: audio)
            fallback(name: "fallback-also-refused", model: "openai/gpt-4o-transcribe",
                refused: ["openai/gpt-4o-transcribe", RecommendedSetup.transcriptionModel], context: small, audio: audio)
            fallback(name: "recommended-refused", model: RecommendedSetup.transcriptionModel,
                refused: [RecommendedSetup.transcriptionModel], context: small, audio: audio)

            // 4. 101 words added at the same moment, inserted in two different orders: the same 100 both times.
            for (name, order) in [("same-date-forward", Array(0..<101)), ("same-date-reverse", Array((0..<101).reversed()))] {
                let sameDate = ModelContext(
                    try! ModelContainer(for: VocabularyWord.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true)))
                for index in order {
                    sameDate.insert(VocabularyWord(word: String(format: "W%03d", index), dateAdded: start))
                }
                try! sameDate.save()
                send(name: name, model: deepgram, context: sameDate, audio: audio)
                local(name: name, service: localService(sameDate))
            }

            // 5. Local Whisper only: the newest words are too long for its prompt budget (900 Latin letters, 120 CJK
            // characters); the older short words that fit still go, whole.
            let oversized = ModelContext(
                try! ModelContainer(for: VocabularyWord.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true)))
            for (word, offset) in [
                ("useEffect", 1.0), ("张三丰", 2.0), (String(repeating: "词", count: 120), 3.0), (String(repeating: "X", count: 900), 4.0),
            ] {
                oversized.insert(VocabularyWord(word: word, dateAdded: start.addingTimeInterval(offset)))
            }
            try! oversized.save()
            local(name: "oversized-newest", service: localService(oversized))

            // 6. What LLMkit sends to providers with their own per-word limits, newest first: a 51-letter word (over
            // 50), a 50-letter one, 7 and 6 words, 21 and 20 letters, then 120 short older words. Each consumer
            // leaves out the words over its limits and fills its count from the older ones; ElevenLabs batch takes
            // them all (the uncut control).
            let limits = ModelContext(
                try! ModelContainer(for: VocabularyWord.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true)))
            for index in 0..<120 {
                limits.insert(VocabularyWord(word: String(format: "S%03d", index), dateAdded: start.addingTimeInterval(Double(index))))
            }
            for (offset, word) in [
                String(repeating: "N", count: 20), String(repeating: "O", count: 21), "alpha beta gamma delta epsilon zeta",
                "one two three four five six seven", String(repeating: "M", count: 50), String(repeating: "L", count: 51),
            ].enumerated() {
                limits.insert(VocabularyWord(word: word, dateAdded: start.addingTimeInterval(1_000 + Double(offset))))
            }
            try! limits.save()
            send(
                name: "provider-limits", model: CloudModel(name: "grok-voice-transcribe-2.0", displayName: "", description: "",
                    provider: .xai, isMultilingual: true, supportedLanguages: [:]),
                context: limits, audio: audio)
            send(name: "provider-limits", model: elevenLabs, context: limits, audio: audio)
            stream(name: "provider-limits", model: elevenLabs,
                provider: ElevenLabsProvider().makeStreamingProvider(modelContext: limits)!, language: nil)
            stream(name: "provider-limits", model: assemblyAI,
                provider: AssemblyAIProvider().makeStreamingProvider(modelContext: limits)!, language: nil)

            // 7. A stream reads the dictionary when it connects: the next connection of the same provider carries a
            // word added after the last one.
            let reconnect = ModelContext(
                try! ModelContainer(for: VocabularyWord.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true)))
            reconnect.insert(VocabularyWord(word: "Kwyntel", dateAdded: start))
            try! reconnect.save()
            let assemblyAIStream = AssemblyAIProvider().makeStreamingProvider(modelContext: reconnect)!
            stream(name: "reconnect-before", model: assemblyAI, provider: assemblyAIStream, language: nil)
            reconnect.insert(VocabularyWord(word: "Zorvex", dateAdded: start.addingTimeInterval(1)))
            try! reconnect.save()
            stream(name: "reconnect-after", model: assemblyAI, provider: assemblyAIStream, language: nil)

            // Asserts: a failure ends the app before the line below.
            DictionaryTerms.selfCheck()
            TranscriptionHints.selfCheck()
            WhisperPrompt.selfCheck()
            print("vocabulary-hints-done: DictionaryTerms TranscriptionHints WhisperPrompt self-checks ok")
            fflush(stdout)
            exit(0)
        }

        static let deepgram = CloudModel(
            name: "nova-3", displayName: "Nova 3", description: "", provider: .deepgram, isMultilingual: true,
            supportedLanguages: [:])
        static let elevenLabs = CloudModel(
            name: "scribe_v2", displayName: "", description: "", provider: .elevenLabs, isMultilingual: true, supportedLanguages: [:])
        static let assemblyAI = CloudModel(
            name: "universal-3-5-pro", displayName: "", description: "", provider: .assemblyAI, isMultilingual: true,
            supportedLanguages: [:])

        static func deepgramStream(_ context: ModelContext) -> any StreamingTranscriptionProvider {
            DeepgramProvider().makeStreamingProvider(modelContext: context)!
        }

        static func openRouter(_ name: String, provider: ModelProvider = .openRouter) -> CloudModel {
            CloudModel(name: name, displayName: name, description: "", provider: provider, isMultilingual: true, supportedLanguages: [:])
        }

        /// Every capped consumer, plus ones that take the whole dictionary or no terms, against one dictionary.
        private static func sendAll(name: String, context: ModelContext, audio: URL) {
            send(name: name, model: deepgram, context: context, audio: audio)
            stream(name: name, model: deepgram, provider: deepgramStream(context), language: nil)
            send(name: name, model: openRouter("microsoft/mai-transcribe-2"), context: context, audio: audio, language: "zh-Hans")
            send(name: name, model: openRouter("openai/gpt-4o-transcribe"), context: context, audio: audio)
            send(name: name, model: openRouter("openai/whisper-large-v3"), context: context, audio: audio)
            send(name: name, model: openRouter("google/gemini-3.5-transcribe"), context: context, audio: audio, language: "en")
            send(name: name, model: openRouter("microsoft/mai-transcribe-2", provider: .yapCloud), context: context, audio: audio)
            send(
                name: name, model: CloudModel(name: "grok-voice-transcribe-2.0", displayName: "", description: "", provider: .xai,
                    isMultilingual: true, supportedLanguages: [:]),
                context: context, audio: audio, language: "en")
            send(
                name: name, model: CloudModel(name: "speechmatics-enhanced", displayName: "", description: "", provider: .speechmatics,
                    isMultilingual: true, supportedLanguages: [:]),
                context: context, audio: audio)
        }

        /// One batch transcription through CloudTranscriptionService; prints the first request it made.
        private static func send(name: String, model: CloudModel, context: ModelContext, audio: URL, language: String? = nil) {
            _ = Recorder.take()
            let outcome = transcribe(model: model, context: context, audio: audio, language: language)
            report(name: name, consumer: "\(model.provider.rawValue)/\(model.name)", outcome: outcome)
        }

        private static func transcribe(model: CloudModel, context: ModelContext, audio: URL, language: String?) -> String {
            let service = CloudTranscriptionService(modelContext: context)
            var done = false
            var outcome = ""
            Task {
                do {
                    outcome = try await service.transcribe(
                        audioURL: audio, model: model, context: TranscriptionRequestContext(language: language, prompt: nil))
                } catch {
                    outcome = "error: \(error.localizedDescription)"
                }
                done = true
            }
            wait { done }
            return outcome
        }

        /// A Yap Cloud transcription of `model` while paygate refuses `refused`; prints every request it made, in order,
        /// with its JSON body (the audio as its format and base64 length).
        private static func fallback(
            name: String, model: String, refused: Set<String>, context: ModelContext, audio: URL, language: String? = nil
        ) {
            _ = Recorder.take()
            Recorder.lock.withLock { Recorder.refusedModels = refused }
            let outcome = transcribe(
                model: openRouter(model, provider: .yapCloud), context: context, audio: audio, language: language)
            Recorder.lock.withLock { Recorder.refusedModels = [] }
            let requests = Recorder.take()
            for (attempt, request) in requests.enumerated() {
                var json = (try? JSONSerialization.jsonObject(with: request.body) as? [String: Any]) ?? [:]
                json["input_audio"] = (json["input_audio"] as? [String: Any]).map {
                    ["format": $0["format"] ?? "", "base64Length": ($0["data"] as? String)?.count ?? 0]
                }
                let line: [String: Any] = [
                    "case": name, "attempt": attempt + 1, "requests": requests.count, "outcome": outcome,
                    "url": "\(request.url.host ?? "")\(request.url.path)", "json": json,
                ]
                let data = try! JSONSerialization.data(withJSONObject: line, options: [.sortedKeys])
                print("vocabulary-hints-fallback: \(String(decoding: data, as: UTF8.self))")
            }
            if requests.isEmpty { print("vocabulary-hints-fallback: {\"case\":\"\(name)\",\"requests\":0}") }
            fflush(stdout)
        }

        /// Local Whisper's service on `context`'s dictionary, as TranscriptionServiceRegistry makes it; no model.
        private static func localService(_ context: ModelContext) -> WhisperTranscriptionService {
            WhisperTranscriptionService(modelsDirectory: FileManager.default.temporaryDirectory, modelContext: context)
        }

        /// The initial prompt a local Whisper request would decode with: the zh base prompt (WhisperPrompt.resolvedPrompt,
        /// as a mode or the default settings resolve it) plus the dictionary, built by WhisperTranscriptionService itself.
        private static func local(name: String, service: WhisperTranscriptionService) {
            let base = WhisperPrompt.resolvedPrompt(for: "zh")
            let prompt = service.initialPrompt(for: TranscriptionRequestContext(language: "zh", prompt: base))
            let line: [String: Any] = ["case": name, "base": base, "prompt": prompt]
            let json = try! JSONSerialization.data(withJSONObject: line, options: [.sortedKeys])
            print("vocabulary-hints-local: \(String(decoding: json, as: UTF8.self))")
            fflush(stdout)
        }

        /// A stream as live dictation opens it; prints the websocket handshake's URL.
        private static func stream(
            name: String, model: CloudModel, provider: any StreamingTranscriptionProvider, language: String?
        ) {
            _ = Recorder.take()
            var done = false
            var outcome = ""
            Task {
                do {
                    try await provider.connect(model: model, language: language)
                    outcome = "connected"
                } catch {
                    outcome = "error: \(error.localizedDescription)"
                }
                // The handshake goes out on its own after connect returns.
                let deadline = Date().addingTimeInterval(5)
                while Recorder.lock.withLock({ Recorder.requests.isEmpty }), Date() < deadline {
                    try? await Task.sleep(for: .milliseconds(10))
                }
                await provider.disconnect()
                done = true
            }
            wait { done }
            report(name: name, consumer: "\(model.provider.rawValue.lowercased())-stream/\(model.name)", outcome: outcome)
        }

        private static func wait(until done: () -> Bool) {
            let deadline = Date().addingTimeInterval(30)
            while !done(), Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
            precondition(done(), "vocabulary-hints-check: a request didn't finish in 30 s")
        }

        private static func report(name: String, consumer: String, outcome: String) {
            let requests = Recorder.take()
            var line: [String: Any] = ["case": name, "consumer": consumer, "outcome": outcome, "requests": requests.count]
            if let request = requests.first {
                let components = URLComponents(url: request.url, resolvingAgainstBaseURL: false)
                line["url"] = "\(request.url.scheme ?? "")://\(request.url.host ?? "")\(request.url.path)"
                var query: [String: [String]] = [:]
                for item in components?.queryItems ?? [] { query[item.name, default: []].append(item.value ?? "") }
                line["query"] = query
                if request.contentType?.hasPrefix("application/json") == true,
                    var json = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any]
                {
                    json["input_audio"] = (json["input_audio"] as? [String: Any]).map { ["format": $0["format"] ?? ""] }
                    line["json"] = json
                } else if request.contentType?.hasPrefix("multipart/form-data") == true {
                    line["form"] = formFields(request.body)
                }
            }
            let json = try! JSONSerialization.data(withJSONObject: line, options: [.sortedKeys])
            print("vocabulary-hints: \(String(decoding: json, as: UTF8.self))")
            fflush(stdout)
        }

        /// The text fields of a multipart body, by name, in order (file parts left out).
        private static func formFields(_ body: Data) -> [String: [String]] {
            var fields: [String: [String]] = [:]
            for part in String(decoding: body, as: UTF8.self).components(separatedBy: "\r\n--") {
                guard let header = part.range(of: "\r\n\r\n"), !part[..<header.lowerBound].contains("filename="),
                    let nameStart = part.range(of: "name=\"")
                else { continue }
                let rest = part[nameStart.upperBound...]
                guard let nameEnd = rest.firstIndex(of: "\"") else { continue }
                var value = String(part[header.upperBound...])
                if value.hasSuffix("\r\n") { value.removeLast(2) }
                fields[String(rest[..<nameEnd]), default: []].append(value)
            }
            return fields
        }

        /// URLSessions made from here on (LLMkit's per-request ones, OpenRouter's, Yap Cloud's) record and answer
        /// through Recorder instead of the network.
        private static func installRecorder() {
            for (original, replacement) in [
                (#selector(getter: URLSessionConfiguration.ephemeral), #selector(URLSessionConfiguration.recordedEphemeral)),
                (#selector(getter: URLSessionConfiguration.default), #selector(URLSessionConfiguration.recordedDefault)),
            ] {
                method_exchangeImplementations(
                    class_getClassMethod(URLSessionConfiguration.self, original)!,
                    class_getClassMethod(URLSessionConfiguration.self, replacement)!)
            }
        }
    }

    extension URLSessionConfiguration {
        /// After installRecorder these run as `.ephemeral` / `.default`, and the calls inside reach the originals.
        @objc fileprivate class func recordedEphemeral() -> URLSessionConfiguration {
            let configuration = recordedEphemeral()
            configuration.protocolClasses = [VocabularyHintsCheck.Recorder.self] + (configuration.protocolClasses ?? [])
            return configuration
        }

        @objc fileprivate class func recordedDefault() -> URLSessionConfiguration {
            let configuration = recordedDefault()
            configuration.protocolClasses = [VocabularyHintsCheck.Recorder.self] + (configuration.protocolClasses ?? [])
            return configuration
        }
    }
#endif
