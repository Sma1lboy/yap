// `make cloud-latency`: how long a Yap Cloud dictation takes, measured with the real client code against the live
// deployment, and how much of it is paygate's hop. Needs PAYGATE_DIR (a Railway-linked paygate checkout). It never
// touches the shared smoke account: it creates its own throwaway account with scripts/issue-token.ts
// (latency+<timestamp>@…, no sign-up credit), funds it $0.05 with scripts/adjust.ts, and at the end waits for late
// charges, adjusts it back to exactly $0 and deletes the account (DELETE /v1/me).
// With OPENROUTER_API_KEY (env or ~/.env) the same requests also go straight to OpenRouter for an A/B.
import Foundation

setvbuf(stdout, nil, _IOLBF, 0)
let env = ProcessInfo.processInfo.environment
let runs = Int(env["CLOUD_LATENCY_RUNS"] ?? "") ?? 5
let label = env["CLOUD_LATENCY_LABEL"] ?? "run"
let transcriptionModel = "microsoft/mai-transcribe-2"  // RecommendedSetup.transcriptionModel
let enhancementModel = "deepseek/deepseek-v4.1-flash"  // RecommendedSetup.enhancementModel
let accountEmail = "latency+\(Int(Date().timeIntervalSince1970))@sma1lboy.me"

guard let paygateDir = env["PAYGATE_DIR"], !paygateDir.isEmpty else {
    print("Set PAYGATE_DIR to a Railway-linked paygate checkout (funding and the one-time token need railway ssh).")
    exit(2)
}
guard let token = issueToken(email: accountEmail, in: paygateDir, deviceName: "cloud-latency") else {
    print("issue-token.ts failed in \(paygateDir)")
    exit(2)
}
KeychainService.shared.save(token, forKey: "yapCloudToken", syncable: false)
let openRouterKey = env["OPENROUTER_API_KEY"].flatMap { $0.isEmpty ? nil : $0 }
    ?? (try? String(contentsOfFile: NSHomeDirectory() + "/.env", encoding: .utf8))?
        .split(separator: "\n").first { $0.hasPrefix("OPENROUTER_API_KEY=") }
        .map { String($0.dropFirst("OPENROUTER_API_KEY=".count)).trimmingCharacters(in: CharacterSet(charactersIn: "\"' ")) }

// MARK: - Clips and prompt

/// Code-switched dictation read by macOS `say` (Chinese voice), as 16 kHz mono 16-bit WAV like Yap records.
func clip(_ text: String, name: String) throws -> Data {
    let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("yap-latency-\(name).wav")
    let say = Process()
    say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
    say.arguments = ["-v", "Tingting", "--data-format=LEI16@16000", "-o", url.path, text]
    try say.run()
    say.waitUntilExit()
    return try Data(contentsOf: url)
}
let sentences = [
    "好的没问题",
    "帮我回一下Kevin，就说PR我看过了，整体LGTM，但是那个useEffect里面的dependency array漏了一个userID，改完就可以merge。",
    "那个我今天想把那个deployed的pipeline改一下，就是现在CI太慢了，然后build cache好像没生效，我怀疑是Docker Layer的顺序有问题。",
    "我们明天的会要讨论三件事，第一是Q四的roadmap，第二是那个onboarding flow要不要重做，第三就是hiring，我们还缺一个senior front end。",
    "这个feature的acceptance criteria大概是这样，用户可以上传PDF，然后系统自动extract表格，再然后导出成CSV，还有就是要支持batch，一次最多五十个文件。",
    "你本地跑的话先clone下来，然后bun install，然后要把那个env文件从example复制一份，填上OpenAI的key，最后bun dev就行了，端口是三千。",
    "嗯先说一下那个API的事，就是rate limit我已经调到每分钟两百了，应该够用。然后另外一个事，下周三我请假，有事Slack找我就行，那个on-call我跟David换了。",
]
let clips: [(name: String, audio: Data)] = try [
    ("short", clip(sentences[0] + "，" + "我马上看一下", name: "short")),
    ("medium", clip(sentences[1], name: "medium")),
    ("long", clip(sentences[1...3].joined(), name: "long")),
]
let prompt = (try? String(contentsOfFile: "VoiceInk/Resources/RecommendedPrompt.md", encoding: .utf8)) ?? ""

// MARK: - Measurement

func ms(_ start: Date) -> Double { Date().timeIntervalSince(start) * 1000 }

/// One POST straight to OpenRouter, on a fresh ephemeral session like the client's (so only paygate's hop differs).
func direct(_ path: String, body: [String: Any]) async throws -> Data {
    var request = URLRequest(url: URL(string: "https://openrouter.ai/api/v1" + path)!, timeoutInterval: 120)
    request.httpMethod = "POST"
    request.setValue("Bearer \(openRouterKey!)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONSerialization.data(withJSONObject: body)
    let session = URLSession(configuration: .ephemeral)
    defer { session.finishTasksAndInvalidate() }
    let (data, response) = try await session.data(for: request)
    guard (response as? HTTPURLResponse)?.statusCode == 200 else {
        throw Failed(description: "direct \(path) HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0): \(String(data: data, encoding: .utf8) ?? "")")
    }
    return data
}

func percentile(_ values: [Double], _ p: Double) -> Double {
    let sorted = values.sorted()
    guard !sorted.isEmpty else { return .nan }
    return sorted[min(sorted.count - 1, Int((Double(sorted.count - 1) * p).rounded()))]
}
func cell(_ values: [Double], failed: Int = 0) -> String {
    let times = values.isEmpty ? "—" : String(format: "%.0f / %.0f", percentile(values, 0.5), percentile(values, 0.95))
    return failed == 0 ? times : times + " (\(failed) failed)"
}

/// Times one call; a failure is counted (and printed) instead of ending the run.
func timed<T>(_ label: String, _ times: inout [Double], _ failures: inout Int, _ body: () async throws -> T) async -> T? {
    let t = Date()
    do {
        let value = try await body()
        times.append(ms(t))
        return value
    } catch {
        failures += 1
        print("     \(label) failed after \(Int(ms(t))) ms: \(error)")
        return nil
    }
}

Task { @MainActor in
    let cloud = YapCloud.shared
    var exitCode: Int32 = 0
    do {
        print("account: \(accountEmail)")
        guard try await cloud.fetchMe().balanceMicros == 0 else { throw Failed(description: "new account must start at $0") }
        try adjust(email: accountEmail, micros: 50_000, note: "cloud-latency: fund", in: paygateDir)

        print("# \(label): \(runs) runs per clip, p50 / p95 in ms\n")
        print("| clip | audio | STT via Yap Cloud | STT direct | enhance via Yap Cloud | enhance direct | STT+enhance via Yap Cloud |")
        print("|---|---|---|---|---|---|---|")
        for (name, audio) in clips {
            var sttCloud: [Double] = [], sttDirect: [Double] = [], chatCloud: [Double] = [], chatDirect: [Double] = [], total: [Double] = []
            var sttCloudFailed = 0, sttDirectFailed = 0, chatCloudFailed = 0, chatDirectFailed = 0, totalFailed = 0
            for _ in 0..<runs {
                // As in the app: recording starts (prewarm), the user speaks for the clip's length, then the upload.
                cloud.prewarm()
                try await Task.sleep(for: .seconds(YapCloud.wavDuration(audio) ?? 0))
                let text = await timed("\(name) STT via Yap Cloud", &sttCloud, &sttCloudFailed) {
                    try await YapCloudProvider().transcribe(
                        audioData: audio, fileName: "\(name).wav", apiKey: token, model: transcriptionModel, language: nil,
                        customVocabulary: [], timeout: 120)
                } ?? sentences[1]
                let messages = [["role": "system", "content": prompt], ["role": "user", "content": "\n<TRANSCRIPT>\n\(text)\n</TRANSCRIPT>"]]
                let ids = YapCloud.GenerationCollector()
                let enhanced = await timed("\(name) enhance via Yap Cloud", &chatCloud, &chatCloudFailed) {
                    try await YapCloud.$generationCollector.withValue(ids) {
                        try await cloud.chatCompletion(model: enhancementModel, messages: messages, temperature: 0.3, timeout: 30)
                    }
                }
                // The per-dictation cost in History needs the generation id and the text from every call.
                if let enhanced, enhanced.isEmpty || ids.last == nil {
                    throw Failed(description: "\(name): enhancement returned \(enhanced.count) chars, id \(ids.last ?? "none")")
                }
                if enhanced != nil, sttCloud.count > total.count { total.append(sttCloud.last! + chatCloud.last!) } else { totalFailed += 1 }
                if openRouterKey != nil {
                    _ = await timed("\(name) STT direct", &sttDirect, &sttDirectFailed) {
                        try await direct("/audio/transcriptions", body: [
                            "model": transcriptionModel, "input_audio": ["data": audio.base64EncodedString(), "format": "wav"],
                        ])
                    }
                    _ = await timed("\(name) enhance direct", &chatDirect, &chatDirectFailed) {
                        // The same body the client sends (paygate only adds usage accounting).
                        var body = YapCloud.chatBody(model: enhancementModel, messages: messages, temperature: 0.3, reasoningOff: true)
                        body["usage"] = ["include": true]
                        return try await direct("/chat/completions", body: body)
                    }
                }
            }
            let seconds = YapCloud.wavDuration(audio).map { String(format: "%.1f s, %.0f KB", $0, Double(audio.count) / 1024) } ?? "?"
            print("| \(name) | \(seconds) | \(cell(sttCloud, failed: sttCloudFailed)) | \(cell(sttDirect, failed: sttDirectFailed)) | "
                + "\(cell(chatCloud, failed: chatCloudFailed)) | \(cell(chatDirect, failed: chatDirectFailed)) | \(cell(total, failed: totalFailed)) |")
        }

        // Connection setup: a fresh connection per request (what an ephemeral session per call costs) vs one reused.
        func healthz(_ session: URLSession) async -> Double {
            var request = URLRequest(url: URL(string: "/healthz", relativeTo: cloud.baseURL)!)
            request.httpMethod = "HEAD"
            let t = Date()
            _ = try? await session.data(for: request)
            return ms(t)
        }
        var fresh: [Double] = [], reused: [Double] = []
        let shared = URLSession(configuration: .ephemeral)
        _ = await healthz(shared)
        for _ in 0..<runs {
            let session = URLSession(configuration: .ephemeral)
            fresh.append(await healthz(session))
            session.finishTasksAndInvalidate()
            reused.append(await healthz(shared))
        }
        print("\n| HEAD /healthz | new connection | reused connection |\n|---|---|---|\n| p50 / p95 ms | \(cell(fresh)) | \(cell(reused)) |")

    } catch {
        print("FAIL", error)
        exitCode = 1
    }
    // Always leave the account at exactly $0. A call the client gave up on is still billed when OpenRouter finishes
    // it (paygate has no abort signal), so first wait for the balance to stop moving: 3 equal reads 5 s apart.
    do {
        var stable = 0, last: Int64?
        for _ in 0..<24 where stable < 3 {
            let now = try await cloud.fetchMe().balanceMicros
            stable = now == last ? stable + 1 : 1
            last = now
            try await Task.sleep(for: .seconds(5))
        }
        try zeroBalance(email: accountEmail, in: paygateDir)
        let after = try await cloud.fetchMe().balanceMicros
        print("\nbalance after: \(after) micros")
        if after != 0 { exitCode = 1 }
    } catch {
        print("FAIL restoring the balance:", error)
        exitCode = 1
    }
    // The throwaway account goes away (every token revoked); its zeroed ledger stays on paygate's books.
    do {
        try await cloud.deleteAccount(confirmEmail: accountEmail)
        print("deleted account \(accountEmail)")
    } catch {
        print("FAIL deleting \(accountEmail):", error)
        exitCode = 1
    }
    exit(exitCode)
}
RunLoop.main.run()
