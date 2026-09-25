// `make cloud-smoke`: regression checks of the Yap Cloud client against a live paygate, run before a release.
// Read-only except limits and config, which are restored before exit. One PASS/FAIL/SKIP line per check.
import Foundation

setvbuf(stdout, nil, _IOLBF, 0)
let env = ProcessInfo.processInfo.environment

guard let token = env["YAP_CLOUD_SMOKE_TOKEN"], !token.isEmpty else {
    print("""
        YAP_CLOUD_SMOKE_TOKEN is not set. Get a token for the smoke account (smoke+yap@sma1lboy.me):

          BASE=https://paygate-production-2502.up.railway.app
          curl -s -X POST $BASE/v1/auth/start -H 'Content-Type: application/json' -d '{"email":"smoke+yap@sma1lboy.me"}'
          # the 6-digit code is in paygate's server log (no email is sent while RESEND_API_KEY is unset):
          (cd <paygate checkout> && railway logs -s paygate | grep 'code for smoke+yap')
          curl -s -X POST $BASE/v1/auth/verify -H 'Content-Type: application/json' \\
               -d '{"email":"smoke+yap@sma1lboy.me","code":"<code>","deviceName":"cloud-smoke"}'
          export YAP_CLOUD_SMOKE_TOKEN=<token from the response>

        Optional: YAP_CLOUD_SMOKE_URL=http://localhost:8787 to point at another paygate.
        """)
    exit(2)
}
if let url = env["YAP_CLOUD_SMOKE_URL"], !url.isEmpty {
    UserDefaults.standard.set(url, forKey: YapCloud.baseURLDefaultsKey)
}
KeychainService.shared.save(token, forKey: "yapCloudToken", syncable: false)

var failures = 0
func report(_ status: String, _ name: String, _ detail: String) {
    print("\(status.padding(toLength: 4, withPad: " ", startingAt: 0)) \(name.padding(toLength: 26, withPad: " ", startingAt: 0)) \(detail)")
    if status == "FAIL" { failures += 1 }
}
func check(_ name: String, _ body: () async throws -> String) async {
    do {
        let detail = try await body()
        report(detail.hasPrefix("SKIP:") ? "SKIP" : "PASS", name, detail.replacingOccurrences(of: "SKIP: ", with: ""))
    } catch {
        report("FAIL", name, "\(error)")
    }
}
struct Failed: Error, CustomStringConvertible { let description: String }
func expect(_ condition: Bool, _ message: @autoclosure () -> String) throws {
    if !condition { throw Failed(description: message()) }
}

/// Raw authenticated request for endpoints the app client doesn't wrap (ledger paging, chat proxy).
func raw(_ method: String, _ path: String, json: [String: Any]? = nil) async throws -> (Int, Data) {
    var request = URLRequest(url: URL(string: path, relativeTo: YapCloud.shared.baseURL)!, timeoutInterval: 30)
    request.httpMethod = method
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    if let json {
        request.httpBody = try JSONSerialization.data(withJSONObject: json)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    }
    let (data, response) = try await URLSession.shared.data(for: request)
    return ((response as! HTTPURLResponse).statusCode, data)
}

/// One second of 16 kHz mono silence as WAV, for the transcription 402 check.
func silentWAV() -> Data {
    let samples = 16_000, bytes = samples * 2
    var d = Data()
    func u32(_ v: Int) { withUnsafeBytes(of: UInt32(v).littleEndian) { d.append(contentsOf: $0) } }
    func u16(_ v: Int) { withUnsafeBytes(of: UInt16(v).littleEndian) { d.append(contentsOf: $0) } }
    d.append(contentsOf: Array("RIFF".utf8)); u32(36 + bytes); d.append(contentsOf: Array("WAVEfmt ".utf8))
    u32(16); u16(1); u16(1); u32(16_000); u32(32_000); u16(2); u16(16)
    d.append(contentsOf: Array("data".utf8)); u32(bytes); d.append(Data(count: bytes))
    return d
}

Task { @MainActor in
    let cloud = YapCloud.shared  // DEBUG build: init runs the client's selfCheck (asserts abort on failure)
    report("PASS", "client selfCheck", "decoding, error mapping, money formatting")
    print("     server                     \(cloud.baseURL.absoluteString)")

    var me: YapCloudMe?
    await check("me") {
        me = try await cloud.fetchMe()
        return "\(me!.email) balance \(YapCloud.formatUSD(micros: me!.balanceMicros)) cap field \(me!.supportsMonthlyCap)"
    }

    await check("models") {
        let catalog = try await cloud.fetchModels()
        let stt = catalog.models.filter(\.isTranscription), chat = catalog.models.filter(\.isChat)
        try expect(!stt.isEmpty && !chat.isEmpty, "transcription \(stt.count) / chat \(chat.count)")
        try expect(stt.allSatisfy { !$0.isChat }, "a model is both transcription and chat")
        return "\(stt.count) transcription, \(chat.count) chat"
    }

    await check("ledger paging") {
        struct Page: Decodable {
            let entries: [YapCloudLedgerEntry]
            let nextBefore: YapCloudScalar?
        }
        let (s1, d1) = try await raw("GET", "/v1/ledger?limit=2")
        try expect(s1 == 200, "HTTP \(s1)")
        let first = try JSONDecoder().decode(Page.self, from: d1)
        guard let cursor = first.nextBefore else { return "SKIP: fewer than 3 ledger rows" }
        let (s2, d2) = try await raw("GET", "/v1/ledger?limit=2&before=\(cursor.string)")
        try expect(s2 == 200, "HTTP \(s2)")
        let second = try JSONDecoder().decode(Page.self, from: d2)
        let ids = (first.entries + second.entries).compactMap { Int64($0.id.string) }
        try expect(ids.count == first.entries.count + second.entries.count, "non-numeric ids")
        try expect(zip(ids, ids.dropFirst()).allSatisfy { $0 > $1 }, "ids not strictly descending across pages: \(ids)")
        return "page 1 \(first.entries.count) rows, page 2 \(second.entries.count) rows, ids \(ids)"
    }

    await check("usage") {
        let usage = try await cloud.fetchUsage()
        try expect(usage.totalMicros == usage.byModel.reduce(0) { $0 + $1.micros }, "total != sum(byModel)")
        if let spent = me?.monthSpentMicros {
            try expect(usage.totalMicros == spent, "usage \(usage.totalMicros) != me.monthSpentMicros \(spent)")
        }
        return "\(usage.totalMicros) micros over \(usage.byModel.count) models, matches monthSpent"
    }

    await check("devices") {
        let devices = try await cloud.fetchDevices()
        try expect(devices.filter(\.current).count == 1, "\(devices.filter(\.current).count) current devices")
        return "\(devices.count) device(s), one current"
    }

    await check("limits set/clear") {
        guard let original = me else { return "SKIP: /v1/me failed" }
        guard original.supportsMonthlyCap else { return "SKIP: server has no monthly cap" }
        do {
            try await cloud.setMonthlyCap(micros: 100)
            try expect(cloud.me?.monthlyCapMicros == 100, "cap after set = \(String(describing: cloud.me?.monthlyCapMicros))")
        } catch {
            try? await cloud.setMonthlyCap(micros: original.monthlyCapMicros)
            throw error
        }
        try await cloud.setMonthlyCap(micros: original.monthlyCapMicros)
        let restored = try await cloud.fetchMe().monthlyCapMicros
        try expect(restored == original.monthlyCapMicros, "cap not restored: \(String(describing: restored))")
        return "set 100 micros, restored to \(original.monthlyCapMicros.map(String.init) ?? "null")"
    }

    await check("config fetch/put/409") {
        guard let doc = try await cloud.fetchConfig() else { return "SKIP: no config doc (won't create one)" }
        // Same content back: the version moves, the config doesn't.
        let next = try await cloud.putConfig(doc.config, ifMatch: doc.version)
        let again = try await cloud.fetchConfig()
        try expect(again?.version == next && again?.config == doc.config, "refetch mismatch")
        do {
            _ = try await cloud.putConfig(doc.config, ifMatch: doc.version)
            throw Failed(description: "stale If-Match accepted")
        } catch YapCloudError.versionConflict(let current) {
            try expect(current?.version == next, "409 current version \(String(describing: current?.version))")
        }
        do {
            _ = try await cloud.putConfig(doc.config, ifMatch: nil)
            throw Failed(description: "If-None-Match: * accepted over an existing doc")
        } catch YapCloudError.versionConflict {}
        return "v\(doc.version) → v\(next) (same content), stale and create-only both 409"
    }

    let balance = me?.balanceMicros
    await check("402 chat") {
        guard let balance else { return "SKIP: /v1/me failed" }
        guard balance <= 0 else { return "SKIP: balance > 0 (a real call would be billed)" }
        let (status, data) = try await raw(
            "POST", "/v1/chat/completions",
            json: ["model": "deepseek/deepseek-v4.1-flash", "messages": [["role": "user", "content": "hi"]], "stream": false])
        let error = YapCloudError(status: status, body: data, authenticated: true)
        try expect(error == .insufficientBalance, "HTTP \(status) → \(error)")
        return "INSUFFICIENT_BALANCE"
    }
    await check("402 transcription") {
        guard let balance else { return "SKIP: /v1/me failed" }
        guard balance <= 0 else { return "SKIP: balance > 0 (a real call would be billed)" }
        do {
            _ = try await YapCloudProvider().transcribe(
                audioData: silentWAV(), fileName: "smoke.wav", apiKey: token, model: "microsoft/mai-transcribe-2",
                language: nil, customVocabulary: [], timeout: 60)
            throw Failed(description: "transcription succeeded at a zero balance")
        } catch YapCloudError.insufficientBalance {
            try expect(YapCloud.notifyIfAccountProblem(YapCloudError.insufficientBalance), "no Add Funds notification")
            return "INSUFFICIENT_BALANCE, Add Funds notification"
        }
    }

    print(failures == 0 ? "cloud-smoke: all checks passed" : "cloud-smoke: \(failures) check(s) failed")
    exit(failures == 0 ? 0 : 1)
}
RunLoop.main.run()
