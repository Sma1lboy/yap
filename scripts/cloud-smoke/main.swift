// `make cloud-smoke`: regression checks of the Yap Cloud client against a live paygate, run before a release.
// Read-only except limits and config, which are restored before exit. One PASS/FAIL/SKIP line per check.
import Foundation

setvbuf(stdout, nil, _IOLBF, 0)
let env = ProcessInfo.processInfo.environment

guard let token = env["YAP_CLOUD_SMOKE_TOKEN"], !token.isEmpty else {
    print("""
        YAP_CLOUD_SMOKE_TOKEN is not set. Issue one for the smoke account from a Railway-linked paygate checkout
        (prints only the token; creates the account without sign-up credit, so it starts at the $0 these checks need):

          export YAP_CLOUD_SMOKE_TOKEN=$(cd <paygate checkout> && \\
              railway ssh -s paygate -- bun run scripts/issue-token.ts smoke+yap@sma1lboy.me --device-name cloud-smoke)

        Fallback while sign-in codes are still only logged (RESEND_API_KEY unset): POST /v1/auth/start, read
        "code for smoke+yap" from `railway logs -s paygate`, POST /v1/auth/verify, use the returned token.

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

/// Ledger adjustment on the live deployment (paygate's scripts/adjust.ts over `railway ssh`, from a linked checkout).
func adjust(email: String, micros: Int64, note: String, in directory: String) throws {
    let sign = micros < 0 ? "-" : ""
    let amount = sign + String(micros.magnitude / 1_000_000) + "." + String(String(micros.magnitude % 1_000_000 + 1_000_000).dropFirst())
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["railway", "ssh", "-s", "paygate", "--", "bun", "run", "scripts/adjust.ts", email, amount, note]
    process.currentDirectoryURL = URL(fileURLWithPath: directory)
    let output = Pipe()
    process.standardOutput = output
    process.standardError = output
    try process.run()
    process.waitUntilExit()
    let text = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    print("     adjust \(amount) USD: \(text.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\n").last ?? "")")
    if process.terminationStatus != 0 { throw Failed(description: "adjust.ts failed: \(text)") }
}

/// Brings the balance back to exactly 0 with one adjustment of the opposite sign.
func zeroBalance(email: String, in directory: String) throws {
    let semaphore = DispatchSemaphore(value: 0)
    var balance: Int64?
    Task.detached {
        balance = try? await YapCloud.shared.fetchMe().balanceMicros
        semaphore.signal()
    }
    semaphore.wait()
    guard let balance else { throw Failed(description: "couldn't read the balance to zero it") }
    if balance != 0 { try adjust(email: email, micros: -balance, note: "client id-capture check: back to 0", in: directory) }
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
        return "\(me!.email) balance \(YapCloud.formatUSD(micros: me!.balanceMicros)) cap \(me!.monthlyCapMicros.map { YapCloud.formatExactUSD(micros: $0) } ?? "none")"
    }

    await check("models") {
        let catalog = try await cloud.fetchModels()
        let stt = catalog.models.filter(\.isTranscription), chat = catalog.models.filter(\.isChat)
        try expect(!stt.isEmpty && !chat.isEmpty, "transcription \(stt.count) / chat \(chat.count)")
        try expect(stt.allSatisfy { !$0.isChat }, "a model is both transcription and chat")
        return "\(stt.count) transcription, \(chat.count) chat"
    }

    var info: YapCloudInfo?
    await check("info") {
        // Fetched raw so a failing endpoint can't pass on the client's cached copy.
        let (status, data) = try await raw("GET", "/v1/info")
        try expect(status == 200, "HTTP \(status)")
        let live = try JSONDecoder().decode(YapCloudInfo.self, from: data)
        info = live
        await cloud.refreshInfo()
        try expect(cloud.info == live, "YapCloud.info != the live response")
        try expect(live.minTopupMicros > 0 && live.maxTopupMicros >= live.minTopupMicros,
                   "top-up range \(live.minTopupMicros)…\(live.maxTopupMicros)")
        try expect(YapCloud.micros(fromDecimal: live.markup.string).map { $0 >= 0 } == true && cloud.markupPercentText != nil,
                   "markup \(live.markup.string)")
        try expect(live.signupCreditMicros >= 0 && live.maxConcurrentCalls > 0, "credit/concurrency")
        try expect(live.privacyURL != nil && live.termsURL != nil, "legal URLs missing or not https")
        let minDollars = Int(live.minTopupMicros / 1_000_000), maxDollars = Int(live.maxTopupMicros / 1_000_000)
        try expect(cloud.isValidTopUp(minDollars) && cloud.isValidTopUp(maxDollars)
                   && !cloud.isValidTopUp(minDollars - 1) && !cloud.isValidTopUp(maxDollars + 1), "client range check")
        return "\(live.productName): markup \(cloud.markupPercentText!), top-up \(YapCloud.formatPlainUSD(micros: live.minTopupMicros))–"
            + "\(YapCloud.formatPlainUSD(micros: live.maxTopupMicros)), credit \(YapCloud.formatPlainUSD(micros: live.signupCreditMicros)), "
            + "\(live.maxConcurrentCalls) concurrent, support \(live.supportEmail ?? "none"), legal draft \(live.legal.draft)"
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
        try expect(usage.creditMicros + usage.paidMicros == usage.totalMicros,
                   "credit \(usage.creditMicros) + paid \(usage.paidMicros) != total \(usage.totalMicros)")
        if let spent = me?.monthSpentMicros {
            try expect(usage.totalMicros == spent, "usage \(usage.totalMicros) != me.monthSpentMicros \(spent)")
        }
        return "\(usage.totalMicros) micros (credit \(usage.creditMicros) + paid \(usage.paidMicros)) over \(usage.byModel.count) models, matches monthSpent"
    }

    await check("devices") {
        let devices = try await cloud.fetchDevices()
        try expect(devices.filter(\.current).count == 1, "\(devices.filter(\.current).count) current devices")
        // Removing an id that isn't ours / doesn't exist must be a DEVICE_NOT_FOUND no-op, never a sign-out.
        let (status, data) = try await raw("DELETE", "/v1/me/devices/999999999")
        let error = YapCloudError(status: status, body: data, authenticated: true)
        guard case .server(404, "DEVICE_NOT_FOUND", _, _, _) = error else {
            throw Failed(description: "DELETE unknown id → HTTP \(status) \(error)")
        }
        try expect(try await cloud.fetchDevices().count == devices.count, "device list changed")
        return "\(devices.count) device(s), one current; unknown id → 404 DEVICE_NOT_FOUND"
    }

    await check("limits set/clear") {
        guard let original = me else { return "SKIP: /v1/me failed" }
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

    await check("config versions") {
        let versions = try await cloud.fetchConfigVersions()
        guard let newest = versions.first else { return "SKIP: no earlier config versions" }
        let dates = versions.compactMap(\.updatedDate)
        try expect(dates.count == versions.count, "unparseable updatedAt")
        try expect(zip(dates, dates.dropFirst()).allSatisfy { $0 >= $1 }, "not newest first")
        let document = try await cloud.fetchConfig(version: newest.version.string)
        try expect(document.version == newest.version.string, "asked v\(newest.version.string), got v\(document.version)")
        try expect((try? JSONSerialization.jsonObject(with: document.config)) != nil, "config is not JSON")
        return "\(versions.count) earlier versions, newest v\(newest.version.string) fetched (\(document.config.count) bytes)"
    }

    let balance = me?.balanceMicros
    await check("402 chat") {
        guard let balance else { return "SKIP: /v1/me failed" }
        guard balance <= 0 else { return "SKIP: balance > 0 (a real call would be billed)" }
        do {
            _ = try await cloud.chatCompletion(
                model: "deepseek/deepseek-v4.1-flash", messages: [["role": "user", "content": "hi"]], temperature: 0.3,
                timeout: 30)
            throw Failed(description: "chat succeeded at a zero balance")
        } catch YapCloudError.insufficientBalance {
            return "INSUFFICIENT_BALANCE (via YapCloud.chatCompletion)"
        }
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

    await check("401 bad token") {
        var request = URLRequest(url: URL(string: "/v1/me", relativeTo: cloud.baseURL)!)
        request.setValue("Bearer not-a-real-token", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as! HTTPURLResponse).statusCode
        let error = YapCloudError(status: status, body: data, authenticated: true)
        try expect(error.isAuthFailure, "HTTP \(status) → \(error)")
        return "HTTP \(status) → \(error) (signs out)"
    }

    await check("413 payload too large") {
        // Config's cap is 1 MB, the cheapest route to exceed; nothing is written (refused before parsing).
        let (status, data) = try await raw("PUT", "/v1/config", json: ["config": ["pad": String(repeating: "x", count: 1_100_000)]])
        let error = YapCloudError(status: status, body: data, authenticated: true)
        guard case .server(413, "PAYLOAD_TOO_LARGE", _, _, _) = error else { throw Failed(description: "HTTP \(status) \(error)") }
        try expect(YapCloud.transcriptionBodyFits(audioBytes: 30_000_000) && !YapCloud.transcriptionBodyFits(audioBytes: 32_000_000),
                   "client-side 40 MB pre-check")
        return "PAYLOAD_TOO_LARGE; recordings over ~31 MB are refused before upload"
    }

    await check("429 concurrent calls") {
        guard let balance, balance <= 0 else { return "SKIP: needs a zero balance (calls would be billed)" }
        // paygate takes the slot before reading the body, so parallel ~1 MB uploads overlap past the limit
        // (/v1/info maxConcurrentCalls); twice the limit makes an overlap near certain.
        let uploads = 2 * (info?.maxConcurrentCalls ?? 4)
        let body: [String: Any] = [
            "model": "microsoft/mai-transcribe-2",
            "input_audio": ["data": Data(count: 750_000).base64EncodedString(), "format": "wav"],
        ]
        let statuses = await withTaskGroup(of: (Int, Data)?.self) { group in
            for _ in 0..<uploads { group.addTask { try? await raw("POST", "/v1/audio/transcriptions", json: body) } }
            var all: [(Int, Data)] = []
            for await result in group { if let result { all.append(result) } }
            return all
        }
        let errors = statuses.map { YapCloudError(status: $0.0, body: $0.1, authenticated: true) }
        let busy = errors.filter { if case .server(429, "TOO_MANY_CONCURRENT_CALLS", _, _, _) = $0 { return true } else { return false } }
        try expect(errors.allSatisfy { $0 == .insufficientBalance || busy.contains($0) }, "unexpected: \(errors)")
        guard let sample = busy.first else { return "SKIP: uploads didn't overlap enough to hit the limit (\(errors.count)× 402)" }
        try expect(YapCloud.isSafeToRetry(sample), "429 not retried")
        try expect(!(sample.errorDescription ?? "").localizedCaseInsensitiveContains("too many"), "wording")
        return "\(busy.count)/\(errors.count) got TOO_MANY_CONCURRENT_CALLS (retried once by the client), rest 402"
    }

    // Optional, costs ~1 cent of the operator's money: YAP_CLOUD_SMOKE_FUNDED=1 PAYGATE_DIR=<railway-linked paygate>
    // funds the smoke account with $0.01 (scripts/adjust.ts over railway ssh), makes one real transcription and
    // one real chat call through the client, checks the captured generation ids against the ledger, then adjusts
    // the balance back to exactly 0 (the 402 checks above depend on it).
    await check("funded: real calls + ids") {
        guard env["YAP_CLOUD_SMOKE_FUNDED"] == "1" else { return "SKIP: set YAP_CLOUD_SMOKE_FUNDED=1 (and PAYGATE_DIR)" }
        guard let paygateDir = env["PAYGATE_DIR"], !paygateDir.isEmpty else { throw Failed(description: "PAYGATE_DIR not set") }
        guard let email = me?.email, balance == 0 else { throw Failed(description: "needs the smoke account at exactly $0") }
        try adjust(email: email, micros: 10_000, note: "client id-capture check: fund", in: paygateDir)
        var zeroed = false
        defer { if !zeroed { try? zeroBalance(email: email, in: paygateDir) } }

        let stt = YapCloud.GenerationCollector(), chat = YapCloud.GenerationCollector()
        _ = try? await YapCloud.$generationCollector.withValue(stt) {  // silence may transcribe to "" (still billed)
            try await YapCloudProvider().transcribe(
                audioData: silentWAV(), fileName: "smoke.wav", apiKey: token, model: "microsoft/mai-transcribe-2",
                language: nil, customVocabulary: [], timeout: 60)
        }
        _ = try await YapCloud.$generationCollector.withValue(chat) {
            try await cloud.chatCompletion(
                model: "deepseek/deepseek-v4.1-flash", messages: [["role": "user", "content": "Reply with: ok"]],
                temperature: 0, timeout: 30)
        }
        guard let sttID = stt.last, let chatID = chat.last else {
            throw Failed(description: "generation id not captured (transcription \(stt.last ?? "nil"), chat \(chat.last ?? "nil"))")
        }

        // Charges can settle a few seconds after the response (generation lookup when usage.cost is missing).
        var charges: [String: Int64] = [:]
        for _ in 0..<20 where charges.count < 2 {
            charges = try await cloud.fetchCharges(generationIDs: [sttID, chatID]).filter { [sttID, chatID].contains($0.key) }
            if charges.count < 2 { try await Task.sleep(for: .seconds(2)) }
        }
        try expect(charges.count == 2, "charges not found for \([sttID, chatID].filter { charges[$0] == nil })")

        // Each charge must equal ceil(cost × (1 + markup) × 1e6) from the row's own meta.
        let (status, data) = try await raw("GET", "/v1/ledger?limit=20")
        try expect(status == 200, "ledger HTTP \(status)")
        struct Rows: Decodable {
            struct Row: Decodable {
                // Older rows (before the integer ledger) stored cost/markup as JSON numbers.
                struct Meta: Decodable { let generationId: String?; let cost: YapCloudScalar?; let markup: YapCloudScalar? }
                let amountMicros: Int64
                let meta: Meta?
            }
            let entries: [Row]
        }
        let rows = try JSONDecoder().decode(Rows.self, from: data).entries
        for id in [sttID, chatID] {
            guard let row = rows.first(where: { $0.meta?.generationId == id }),
                let cost = row.meta?.cost.flatMap({ Decimal(string: $0.string, locale: Locale(identifier: "en_US_POSIX")) }),
                let markup = row.meta?.markup.flatMap({ Decimal(string: $0.string, locale: Locale(identifier: "en_US_POSIX")) })
            else { throw Failed(description: "no ledger row with cost/markup for \(id)") }
            var exact = cost * (1 + markup) * 1_000_000, rounded = Decimal()
            NSDecimalRound(&rounded, &exact, 0, .up)
            let expected = NSDecimalNumber(decimal: rounded).int64Value
            try expect(-row.amountMicros == expected && charges[id] == expected,
                       "\(id): ledger \(-row.amountMicros), lookup \(String(describing: charges[id])), ceil(cost×(1+markup)) \(expected)")
        }

        try zeroBalance(email: email, in: paygateDir)
        zeroed = true
        let after = try await cloud.fetchMe().balanceMicros
        try expect(after == 0, "balance after restore = \(after)")
        return "transcription \(sttID) = \(charges[sttID]!) micros, chat \(chatID) = \(charges[chatID]!) micros; both match ceil(cost×(1+markup)); balance back to 0"
    }

    print(failures == 0 ? "cloud-smoke: all checks passed" : "cloud-smoke: \(failures) check(s) failed")
    exit(failures == 0 ? 0 : 1)
}
RunLoop.main.run()
