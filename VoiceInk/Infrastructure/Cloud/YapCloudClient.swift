import AppKit
import Foundation
import os

/// Yap Cloud: the paygate server (contract: paygate `docs/api.md`) — email-code sign-in, a prepaid wallet,
/// OpenAI-compatible proxies for chat and transcription, and config sync.
///
/// The token is per device, so it lives in the keychain with `syncable: false`. Other code reads it through
/// `YapCloud.shared.token` (any thread); `APIKeyManager` hands it out as the "Yap Cloud" provider key.
final class YapCloud: ObservableObject {
    static let shared = YapCloud()

    static let providerName = "Yap Cloud"
    static let baseURLDefaultsKey = "yapCloudBaseURL"
    static let defaultBaseURL = "https://paygate-production-2502.up.railway.app"
    static let checkoutPresets = [5, 10, 20]
    static let maximumTopUpUSD = 500
    /// Below this ($1), Home and the menu bar show a prominent "add funds" entry.
    static let lowBalanceMicros: Int64 = 1_000_000

    private static let tokenKey = "yapCloudToken"
    private static let emailKey = "yapCloudEmail"
    private static let catalogKey = "yapCloudModelCatalog"

    private let keychain = KeychainService.shared
    private let defaults = UserDefaults.standard
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "YapCloud")
    private let catalogLock = NSLock()
    private var catalog: YapCloudCatalog?
    private var balanceRefresh: Task<Void, Never>?

    @Published private(set) var isSignedIn = false
    @Published private(set) var me: YapCloudMe? {
        didSet { balanceUpdatedAt = me == nil ? nil : Date() }
    }
    @Published private(set) var balanceUpdatedAt: Date?
    @Published private(set) var ledger: [YapCloudLedgerEntry] = []
    /// False until a ledger fetch succeeds, so a failed load is never shown as "no activity".
    @Published private(set) var isLedgerLoaded = false
    @Published private(set) var isRefreshingAccount = false
    /// Why the last Account refresh failed; nil after a successful one.
    @Published private(set) var accountRefreshError: String?
    /// This month's spend from `/v1/usage`; nil until loaded.
    @Published private(set) var monthlySpend: YapCloudMonthlySpend?
    /// Set when Checkout opens; cleared once the balance goes up (or the user stops waiting).
    @Published private(set) var pendingTopUp: PendingTopUp?
    /// The last paygate request failed to connect (or got 502/503/504). Account shows a banner; cleared by the next
    /// successful request, and /healthz is polled every 15 s while it's set.
    @Published private(set) var isUnreachable = false
    private var healthPoll: Task<Void, Never>?
    /// Signed-in devices for Account; nil until loaded or while paygate doesn't have the endpoint (404).
    @Published private(set) var devices: [YapCloudDevice]?
    /// Why the device list failed to load (not set for the 404 of an undeployed endpoint).
    @Published private(set) var devicesError: String?

    struct PendingTopUp: Equatable {
        let balanceBeforeMicros: Int64
        let startedAt: Date
    }

    private init() {
        #if DEBUG
            YapCloud.selfCheck()
        #endif
        isSignedIn = token != nil
        if let data = defaults.data(forKey: Self.catalogKey) {
            catalog = try? JSONDecoder().decode(YapCloudCatalog.self, from: data)
        }
        // Paying happens in the browser; coming back to Yap is when the new balance should show
        // (Account, the Home card and the menu bar all read `me`).
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.refreshAfterReturning() }
        }
    }

    // MARK: - Shared state other features read

    /// Server root. DEBUG builds honor `defaults write <bundle id> yapCloudBaseURL http://localhost:8787`.
    var baseURL: URL {
        #if DEBUG
            if let raw = defaults.string(forKey: Self.baseURLDefaultsKey)?.trimmingCharacters(in: .whitespaces),
                let url = URL(string: raw), !raw.isEmpty
            {
                return url
            }
        #endif
        return URL(string: Self.defaultBaseURL)!
    }

    /// Bearer token of the signed-in device, or nil when signed out.
    var token: String? {
        guard let value = keychain.getString(forKey: Self.tokenKey, syncable: false), !value.isEmpty else { return nil }
        return value
    }

    /// Email of the signed-in account; kept so Account can show it before `/v1/me` answers.
    var email: String? { defaults.string(forKey: Self.emailKey) }

    /// Last `/v1/models` answer (persisted, so transcription models exist at launch before any fetch).
    var models: [YapCloudModel] {
        catalogLock.withLock { catalog?.models ?? [] }
    }

    var transcriptionModels: [YapCloudModel] { models.filter(\.isTranscription) }
    var chatModels: [YapCloudModel] { models.filter(\.isChat) }

    // MARK: - Auth

    func startSignIn(email: String) async throws {
        _ = try await send("POST", "/v1/auth/start", json: ["email": email], authenticated: false)
    }

    @MainActor
    func verify(email: String, code: String) async throws {
        let data = try await send(
            "POST", "/v1/auth/verify",
            json: ["email": email, "code": code, "deviceName": Host.current().localizedName ?? "Mac"],
            authenticated: false)
        let response = try Self.decode(YapCloudVerifyResponse.self, from: data)
        guard keychain.save(response.token, forKey: Self.tokenKey, syncable: false) else {
            throw YapCloudError.keychainUnavailable
        }
        defaults.set(response.user.email, forKey: Self.emailKey)
        isSignedIn = true
        NotificationCenter.default.post(name: .aiProviderKeyChanged, object: nil)
        await refreshAccount()
        announceSignupCreditIfNew(userID: response.user.id.string)
        await refreshModels()
    }

    /// New accounts get a `credit` ledger row (the sign-up bonus). Right after the first sign-in, say so once.
    @MainActor
    private func announceSignupCreditIfNew(userID: String) {
        let key = "yapCloudSignupCreditShown." + userID
        guard !defaults.bool(forKey: key), (balanceMicros ?? 0) > 0,
            let credit = Self.signupCreditMicros(in: ledger, now: Date())
        else { return }
        defaults.set(true, forKey: key)
        Self.showCredited(
            String(format: String(localized: "Added %@ of trial credit to your Yap Cloud balance."), Self.formatUSD(micros: credit)))
    }

    /// The sign-up bonus if it was granted within the last hour (a brand-new account, not a later sign-in).
    static func signupCreditMicros(in ledger: [YapCloudLedgerEntry], now: Date) -> Int64? {
        ledger.first { entry in
            entry.kind == "credit" && entry.amountMicros > 0
                && entry.createdDate.map { now.timeIntervalSince($0) < 3600 } == true
        }?.amountMicros
    }

    @MainActor
    static func showCredited(_ title: String) {
        NotificationManager.shared.showNotification(title: title, type: .success, duration: 5)
    }

    /// Signs out locally right away; revoking the token server-side is best effort, so being offline
    /// never leaves the user waiting on the 20s request timeout.
    @MainActor
    func signOut() {
        guard let token else {
            clearSession()
            return
        }
        clearSession()
        Task {
            do {
                _ = try await sendWithResponse(
                    "POST", "/v1/auth/logout", headers: ["Authorization": "Bearer \(token)"], authenticated: false)
            } catch {
                logger.error("Logout request failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    @MainActor
    private func clearSession() {
        keychain.delete(forKey: Self.tokenKey, syncable: false)
        defaults.removeObject(forKey: Self.emailKey)
        isSignedIn = false
        me = nil
        ledger = []
        isLedgerLoaded = false
        accountRefreshError = nil
        monthlySpend = nil
        devices = nil
        devicesError = nil
        NotificationCenter.default.post(name: .aiProviderKeyChanged, object: nil)
    }

    // MARK: - Account & wallet

    func fetchMe() async throws -> YapCloudMe {
        try Self.decode(YapCloudMe.self, from: try await send("GET", "/v1/me"))
    }

    func fetchLedger(limit: Int = 20) async throws -> [YapCloudLedgerEntry] {
        try Self.decode(YapCloudLedger.self, from: try await send("GET", "/v1/ledger?limit=\(limit)")).entries
    }

    /// `PUT /v1/me/limits`; nil removes the cap. Refreshes `me` so Account shows the new cap.
    @MainActor
    func setMonthlyCap(micros: Int64?) async throws {
        _ = try await send("PUT", "/v1/me/limits", json: Self.limitsBody(capMicros: micros))
        me = try await fetchMe()
    }

    static func limitsBody(capMicros: Int64?) -> [String: Any] {
        ["monthlyCapMicros": capMicros.map { NSNumber(value: $0) } ?? NSNull()]
    }

    /// Cap presets in whole dollars. A custom cap is any decimal dollar amount from $0 (blocks all calls) to
    /// $10 000, parsed exactly into micros.
    static let monthlyCapPresets = [5, 10, 20]
    static let maximumMonthlyCapMicros: Int64 = 10_000_000_000
    static func monthlyCapMicros(fromDollars text: String) -> Int64? {
        let trimmed = text.trimmingCharacters(in: CharacterSet(charactersIn: "$ ").union(.whitespaces))
        guard !trimmed.isEmpty, let micros = micros(fromDecimal: trimmed),
            (0...maximumMonthlyCapMicros).contains(micros)
        else { return nil }
        return micros
    }

    /// This month's usage spend, per model. No `since`: paygate's default window is the current UTC month, the
    /// same one `monthSpentMicros` and the monthly cap use, so the card and "used of cap" always agree.
    func fetchUsage() async throws -> YapCloudMonthlySpend {
        try Self.decode(YapCloudMonthlySpend.self, from: try await send("GET", "/v1/usage"))
    }

    /// Returns the Stripe Checkout URL for a top-up of `amountUSD` dollars.
    func checkoutURL(amountUSD: Int) async throws -> URL {
        guard Self.isValidTopUp(amountUSD) else { throw YapCloudError.invalidAmount }
        let data = try await send("POST", "/v1/wallet/checkout", json: ["amountUsd": amountUSD])
        guard let url = URL(string: try Self.decode(YapCloudCheckout.self, from: data).url) else {
            throw YapCloudError.server(status: 200, code: nil, message: "Invalid checkout URL")
        }
        return url
    }

    var balanceMicros: Int64? { me?.balanceMicros }
    var isLowBalance: Bool { balanceMicros.map { $0 < Self.lowBalanceMicros } ?? false }

    /// Refetches `/v1/me` once, a moment after a billed call finishes (a dictation's transcription and cleanup
    /// collapse into one fetch). Also called at launch. The billed request itself stays untouched.
    func scheduleBalanceRefresh() {
        Task { @MainActor in
            guard isSignedIn else { return }
            balanceRefresh?.cancel()
            balanceRefresh = Task { @MainActor in
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                do {
                    me = try await fetchMe()
                } catch YapCloudError.notSignedIn {
                    clearSession()
                } catch {
                    logger.error("Balance refresh failed: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }

    /// Reloads balance and the last 20 ledger rows for the Account page. Signs out on a revoked token.
    @MainActor
    func refreshAccount() async {
        guard token != nil, !isRefreshingAccount else { return }
        isRefreshingAccount = true
        defer { isRefreshingAccount = false }
        do {
            me = try await fetchMe()
            settlePendingTopUp()
            ledger = try await fetchLedger()
            isLedgerLoaded = true
            monthlySpend = try await fetchUsage()
            accountRefreshError = nil
        } catch YapCloudError.notSignedIn {
            clearSession()
        } catch YapCloudError.unreachable {
            // The Account banner says it; no second, duplicate error line.
            accountRefreshError = nil
        } catch {
            logger.error("Account refresh failed: \(error.localizedDescription, privacy: .public)")
            accountRefreshError = error.localizedDescription
        }
    }

    // MARK: - Models

    func fetchModels() async throws -> YapCloudCatalog {
        try Self.decode(YapCloudCatalog.self, from: try await send("GET", "/v1/models", authenticated: false))
    }

    /// Fetches `/v1/models`, persists it and tells model pickers to reload. Keeps the old catalog on failure.
    @MainActor
    func refreshModels() async {
        do {
            let fresh = try await fetchModels()
            catalogLock.withLock { catalog = fresh }
            defaults.set(try JSONEncoder().encode(fresh), forKey: Self.catalogKey)
            objectWillChange.send()
            NotificationCenter.default.post(name: .aiProviderKeyChanged, object: nil)
        } catch {
            logger.error("Model catalog refresh failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Config sync

    /// Current synced config, or nil when none was ever written (404).
    func fetchConfig() async throws -> YapCloudConfigDocument? {
        do {
            let (data, response) = try await sendWithResponse("GET", "/v1/config")
            return YapCloudConfigDocument(body: data, etag: response.value(forHTTPHeaderField: "ETag"))
        } catch YapCloudError.server(let status, _, _, _, _) where status == 404 {
            return nil
        }
    }

    /// Writes `config` (JSON object bytes, no secrets). `ifMatch` is the version you last read; nil = first write,
    /// sent as `If-None-Match: *` so an existing doc answers 409 VERSION_CONFLICT instead of being overwritten.
    /// Returns the new version. A stale version throws `.versionConflict(current:)` with the server's copy.
    func putConfig(_ config: Data, ifMatch version: String?) async throws -> String {
        guard let object = try? JSONSerialization.jsonObject(with: config) else {
            throw YapCloudError.server(status: 0, code: nil, message: "config is not JSON")
        }
        let (data, _) = try await sendWithResponse(
            "PUT", "/v1/config", json: ["config": object], headers: version.map { ["If-Match": "\"\($0)\""] } ?? ["If-None-Match": "*"])
        let body = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let newVersion = body?["version"].map({ "\($0)" }) else {
            throw YapCloudError.server(status: 200, code: nil, message: "Missing version")
        }
        return newVersion
    }

    /// Versions replaced by earlier PUTs (not the current one), newest first, at most 20.
    func fetchConfigVersions() async throws -> [YapCloudConfigVersion] {
        try Self.decode([YapCloudConfigVersion].self, from: try await send("GET", "/v1/config/versions"))
    }

    /// One earlier version's config. The current version, or one pruned from history, is 404 VERSION_NOT_FOUND.
    func fetchConfig(version: String) async throws -> YapCloudConfigDocument {
        let path = "/v1/config/versions/" + (version.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? version)
        guard let document = YapCloudConfigDocument(body: try await send("GET", path), etag: nil) else {
            throw YapCloudError.server(status: 200, code: nil, message: "Malformed config version")
        }
        return document
    }

    // MARK: - Funds

    /// Opens Account so the user can add funds; used by the insufficient-balance notification.
    @MainActor
    static func showAddFunds() {
        NSApp.activate(ignoringOtherApps: true)
        NotificationCenter.default.post(
            name: .navigateToDestination, object: nil, userInfo: ["destination": "Account"])
    }

    // MARK: - Billed proxy calls

    /// POSTs a JSON body to a billed proxy route (`/v1/chat/completions`, `/v1/audio/transcriptions`).
    /// Retries once after 0.5 s, only when the first attempt provably wasn't billed (see `isSafeToRetry`).
    /// Final network failures become `.unreachable`, so no outer retry loop re-sends a billed request.
    func proxy(_ path: String, body: [String: Any], timeout: TimeInterval) async throws -> Data {
        defer { scheduleBalanceRefresh() }
        let payload = try JSONSerialization.data(withJSONObject: body)
        do {
            let data = try await Self.retryingOnce { try await self.proxyOnce(path, payload: payload, timeout: timeout) }
            noteReachability(nil)
            return data
        } catch {
            let classified = Self.classify(error)
            noteReachability(classified)
            throw classified
        }
    }

    private func proxyOnce(_ path: String, payload: Data, timeout: TimeInterval) async throws -> Data {
        guard let token else { throw YapCloudError.notSignedIn }
        var request = URLRequest(url: URL(string: path, relativeTo: baseURL)!, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = payload
        // Ephemeral session: avoids HTTP/3 uploads that stall behind some VPNs (same as custom endpoints).
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard (200..<300).contains(http.statusCode) else {
            throw YapCloudError(status: http.statusCode, body: data, authenticated: true)
        }
        return data
    }

    /// Safe = paygate cannot have forwarded (so billed) the request. paygate bills any call OpenRouter answered,
    /// even after the client gave up (no abort signal in src/proxy.ts), so timeouts and dropped connections are
    /// not retried. It never bills 502 UPSTREAM_UNAVAILABLE (OpenRouter unreachable) or passed-through 5xx.
    static func isSafeToRetry(_ error: Error) -> Bool {
        if let error = error as? URLError {
            return [.cannotFindHost, .cannotConnectToHost, .dnsLookupFailed, .notConnectedToInternet].contains(error.code)
        }
        if case YapCloudError.server(let status, _, _, _, _) = error { return [502, 503, 504].contains(status) }
        return false
    }

    static func retryingOnce<T>(
        delay: Duration = .milliseconds(500), _ operation: () async throws -> T
    ) async throws -> T {
        do {
            return try await operation()
        } catch where isSafeToRetry(error) {
            try await Task.sleep(for: delay)
            return try await operation()
        }
    }

    /// Enhancement requests through Yap Cloud: model latency plus paygate's hop, independent of the user's
    /// per-provider enhancement timeout (7 s default), which a cold route can exceed.
    static let enhancementTimeout: TimeInterval = 30

    /// Transcription time grows with the recording: 10 s + 1.5 × its length, at most 120 s.
    static func transcriptionTimeout(audioSeconds: Double) -> TimeInterval {
        min(120, 10 + 1.5 * max(0, audioSeconds))
    }

    /// Length of a WAV from its chunks (`fmt ` byte rate, `data` size); nil if not a WAV. Chunks are walked rather
    /// than read at fixed offsets because macOS writers put a FLLR/JUNK chunk before `fmt `.
    static func wavDuration(_ data: Data) -> Double? {
        let bytes = [UInt8](data.prefix(8192))
        guard bytes.count >= 12, bytes[0..<4].elementsEqual("RIFF".utf8), bytes[8..<12].elementsEqual("WAVE".utf8)
        else { return nil }
        func u32(_ i: Int) -> Int { Int(bytes[i]) | Int(bytes[i + 1]) << 8 | Int(bytes[i + 2]) << 16 | Int(bytes[i + 3]) << 24 }
        var byteRate = 0
        var offset = 12
        while offset + 8 <= bytes.count {
            let id = bytes[offset..<offset + 4], size = u32(offset + 4)
            if id.elementsEqual("fmt ".utf8), offset + 20 <= bytes.count {
                byteRate = u32(offset + 16)
            } else if id.elementsEqual("data".utf8) {
                guard byteRate > 0 else { return nil }
                // Some writers leave the size at 0 / max while streaming; fall back to the file length.
                let payload = size > 0 && offset + 8 + size <= data.count ? size : data.count - offset - 8
                return Double(payload) / Double(byteRate)
            }
            offset += 8 + size + (size & 1)
        }
        return nil
    }

    /// Non-streaming chat completion through paygate; returns the first choice's text.
    func chatCompletion(model: String, messages: [[String: String]], temperature: Double, timeout: TimeInterval)
        async throws -> String
    {
        let data = try await proxy(
            "/v1/chat/completions",
            body: ["model": model, "messages": messages, "temperature": temperature, "stream": false],
            timeout: timeout)
        struct Response: Decodable {
            struct Choice: Decodable {
                struct Message: Decodable { let content: String? }
                let message: Message
            }
            let choices: [Choice]
        }
        guard let text = (try? JSONDecoder().decode(Response.self, from: data))?.choices.first?.message.content else {
            throw YapCloudError.server(status: 200, code: nil, message: "Unexpected chat response")
        }
        return text
    }

    // MARK: - Devices

    func fetchDevices() async throws -> [YapCloudDevice] {
        try YapCloudDevice.decodeList(try await send("GET", "/v1/me/devices"))
    }

    /// Loads the device list for Account. A 404 (endpoint not deployed yet) leaves `devices` nil, hiding the section.
    @MainActor
    func refreshDevices() async {
        guard token != nil else { return }
        do {
            devices = try await fetchDevices()
            devicesError = nil
        } catch YapCloudError.notSignedIn {
            clearSession()
        } catch YapCloudError.server(let status, _, _, _, _) where status == 404 {
            devices = nil
        } catch {
            logger.error("Device list failed: \(error.localizedDescription, privacy: .public)")
            devicesError = error.localizedDescription
        }
    }

    /// Revokes another device's token (`DELETE /v1/me/devices/{id}`), then reloads the list.
    @MainActor
    func removeDevice(_ device: YapCloudDevice) async throws {
        let id = device.id.string.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(["/"])) ?? ""
        do {
            _ = try await send("DELETE", "/v1/me/devices/\(id)")
        } catch YapCloudError.server(_, let code, _, _, _) where code == "DEVICE_NOT_FOUND" {
            // Already signed out elsewhere; the reload below drops it from the list.
        }
        devices = try await fetchDevices()
    }

    static func parseDate(_ string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: string) ?? ISO8601DateFormatter().date(from: string)
    }

    // MARK: - Top-up flow

    /// Opens Stripe Checkout in the browser and starts waiting for the balance to go up.
    @MainActor
    func openCheckout(amountUSD: Int) async throws {
        let url = try await checkoutURL(amountUSD: amountUSD)
        // The balance to compare against once the payment lands.
        if let fresh = try? await fetchMe() { me = fresh }
        pendingTopUp = PendingTopUp(balanceBeforeMicros: balanceMicros ?? 0, startedAt: Date())
        NSWorkspace.shared.open(url)
    }

    @MainActor
    func stopWaitingForTopUp() { pendingTopUp = nil }

    /// Coming back from the browser: refresh, and while a payment is pending re-check a couple of times,
    /// since Stripe's webhook can land a few seconds after the success page.
    @MainActor
    func refreshAfterReturning() async {
        await refreshAccount()
        for delay in [3, 8] where pendingTopUp != nil {
            try? await Task.sleep(for: .seconds(delay))
            await refreshAccount()
        }
    }

    /// After a /v1/me fetch: a higher balance while waiting means the top-up arrived; say so once.
    @MainActor
    private func settlePendingTopUp() {
        guard let pending = pendingTopUp else { return }
        if Date().timeIntervalSince(pending.startedAt) > 2 * 3600 {
            pendingTopUp = nil
            return
        }
        guard let balance = balanceMicros,
            let credited = Self.creditedMicros(before: pending.balanceBeforeMicros, after: balance)
        else { return }
        pendingTopUp = nil
        Self.showCredited(
            String(format: String(localized: "Added %@ to your Yap Cloud balance."), Self.formatUSD(micros: credited)))
    }

    static func creditedMicros(before: Int64, after: Int64) -> Int64? {
        after > before ? after - before : nil
    }

    /// "~$0.0012 / call" from this month's usage, or nil (not loaded, or fewer than 3 calls).
    func averageCallLabel(model: String) -> String? {
        monthlySpend?.averageCallMicros(model: model).map {
            String(format: String(localized: "%@ / call"), Self.formatAverage(micros: $0))
        }
    }

    /// An average: "~$0.0012", or "<$0.0001" (no "~" on a bound).
    static func formatAverage(micros: Int64) -> String {
        let amount = formatLedgerAmount(micros: micros, kind: "usage")
        return amount.hasPrefix("<") ? amount : "~" + amount
    }

    /// `yap://account/refresh` (also `yap://account`), the link paygate's checkout success page returns to.
    /// Dev builds register `yap-dev://` instead (YAP_URL_SCHEME) so they don't take links from the release app.
    static func isAccountRefreshURL(_ url: URL) -> Bool {
        guard ["yap", "yap-dev"].contains(url.scheme?.lowercased() ?? ""), url.host?.lowercased() == "account"
        else { return false }
        return ["", "/", "/refresh"].contains(url.path.lowercased())
    }

    /// Shows the account notification when `error` is a Yap Cloud 402 (Add Funds) or 401 (sign in again).
    /// Returns whether it did, so callers can skip their generic failure message.
    @MainActor
    @discardableResult
    static func notifyIfAccountProblem(_ error: Error) -> Bool {
        switch error {
        case YapCloudError.insufficientBalance:
            NotificationManager.shared.showNotification(
                title: YapCloudError.insufficientBalance.errorDescription ?? "",
                type: .error,
                duration: 8,
                onTap: { showAddFunds() },
                actionButton: (label: String(localized: "Add Funds"), action: { showAddFunds() }))
        case YapCloudError.monthlyCapReached:
            NotificationManager.shared.showNotification(
                title: YapCloudError.monthlyCapReached.errorDescription ?? "",
                type: .error,
                duration: 8,
                onTap: { showAddFunds() },
                actionButton: (label: String(localized: "Adjust Cap"), action: { showAddFunds() }))
        case YapCloudError.unreachable:
            NotificationManager.shared.showNotification(
                title: YapCloudError.unreachable.errorDescription ?? "", type: .error, duration: 5)
        case YapCloudError.notSignedIn:
            // The token was rejected (revoked or expired); drop it so Account shows the sign-in form.
            shared.clearSession()
            NotificationManager.shared.showNotification(
                title: YapCloudError.notSignedIn.errorDescription ?? "",
                type: .error,
                duration: 8,
                onTap: { showAddFunds() },
                actionButton: (label: String(localized: "Open Account"), action: { showAddFunds() }))
        default:
            return false
        }
        return true
    }

    /// `$12.35` / `-$0.0012`: micros (1 USD = 1e6) rounded half-up to `decimals` places (0...6), integer math only.
    static func formatUSD(micros: Int64, decimals: Int = 2) -> String {
        var step: UInt64 = 1
        for _ in 0..<(6 - decimals) { step *= 10 }
        let units = (micros.magnitude + step / 2) / step
        let scale = 1_000_000 / step
        let sign = micros < 0 && units > 0 ? "-" : ""
        let fraction = decimals == 0 ? "" : "." + String(String(units % scale + scale).dropFirst())
        return sign + "$" + String(units / scale) + fraction
    }

    /// A user-set amount (the cap) shown without losing precision: 2 decimals, more only when needed (`$0.0001`).
    static func formatExactUSD(micros: Int64) -> String {
        var decimals = 2
        var divisor: Int64 = 10_000
        while decimals < 6, micros % divisor != 0 {
            decimals += 1
            divisor /= 10
        }
        return formatUSD(micros: micros, decimals: decimals)
    }

    /// Ledger amounts: usage rows are usually under a cent, so they get 4 decimals (below $0.0001: "-<$0.0001",
    /// keeping the sign so a charge never reads as a credit);
    /// top-ups and adjustments get 2.
    static func formatLedgerAmount(micros: Int64, kind: String) -> String {
        guard kind == "usage" else { return formatUSD(micros: micros) }
        if micros != 0 && micros.magnitude < 100 { return (micros < 0 ? "-" : "") + "<$0.0001" }
        return formatUSD(micros: micros, decimals: 4)
    }

    /// Exact decimal string ("12.50", "-0.0021", legacy number text) → micros, rounded to the nearest micro.
    static func micros(fromDecimal string: String) -> Int64? {
        guard var value = Decimal(string: string, locale: Locale(identifier: "en_US_POSIX")) else { return nil }
        value *= 1_000_000
        var rounded = Decimal()
        NSDecimalRound(&rounded, &value, 0, .plain)
        return NSDecimalNumber(decimal: rounded).int64Value
    }

    static func isValidTopUp(_ amountUSD: Int) -> Bool {
        (checkoutPresets.min()!...maximumTopUpUSD).contains(amountUSD)
    }

    // MARK: - HTTP

    private func send(
        _ method: String, _ path: String, json: [String: Any]? = nil, authenticated: Bool = true
    ) async throws -> Data {
        try await sendWithResponse(method, path, json: json, authenticated: authenticated).0
    }

    private func sendWithResponse(
        _ method: String, _ path: String, json: [String: Any]? = nil, headers: [String: String] = [:],
        authenticated: Bool = true
    ) async throws -> (Data, HTTPURLResponse) {
        guard let url = URL(string: path, relativeTo: baseURL) else { throw URLError(.badURL) }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.httpMethod = method
        if authenticated {
            guard let token else { throw YapCloudError.notSignedIn }
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let json {
            request.httpBody = try JSONSerialization.data(withJSONObject: json)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            guard (200..<300).contains(http.statusCode) else {
                throw YapCloudError(status: http.statusCode, body: data, authenticated: authenticated)
            }
            noteReachability(nil)
            return (data, http)
        } catch {
            let classified = Self.classify(error)
            noteReachability(classified)
            throw classified
        }
    }

    /// Network failures and 502/503/504 all mean "Yap Cloud can't be reached right now" to the user.
    static func classify(_ error: Error) -> Error {
        if error is URLError { return YapCloudError.unreachable }
        if case YapCloudError.server(let status, _, _, _, _) = error, [502, 503, 504].contains(status) {
            return YapCloudError.unreachable
        }
        return error
    }

    /// Any answer from paygate clears the unreachable state; `.unreachable` sets it and starts polling /healthz.
    private func noteReachability(_ error: Error?) {
        let unreachable = (error as? YapCloudError) == .unreachable
        Task { @MainActor in
            guard unreachable != isUnreachable else { return }
            isUnreachable = unreachable
            healthPoll?.cancel()
            guard unreachable else { return }
            healthPoll = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(15))
                    guard let self, !Task.isCancelled else { return }
                    if await self.isHealthy() {
                        if self.isSignedIn { await self.refreshAccount() } else { self.isUnreachable = false }
                        return
                    }
                }
            }
        }
    }

    /// `GET /healthz` (unauthenticated, `{ok: true}`).
    func isHealthy() async -> Bool {
        var request = URLRequest(url: URL(string: "/healthz", relativeTo: baseURL)!, timeoutInterval: 10)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        guard let (_, response) = try? await URLSession.shared.data(for: request) else { return false }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }

    private static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw YapCloudError.server(status: 200, code: nil, message: "Unexpected response: \(error.localizedDescription)")
        }
    }
}

// MARK: - Errors

enum YapCloudError: LocalizedError, Equatable {
    case notSignedIn
    case insufficientBalance
    /// 402 MONTHLY_CAP_REACHED: the user's own monthly spending cap, not an empty balance.
    case monthlyCapReached
    /// paygate (or its upstream) can't be reached: network failure, timeout, or 502/503/504.
    case unreachable
    case invalidAmount
    case keychainUnavailable
    case versionConflict(current: YapCloudConfigDocument?)
    /// `message` is paygate's English text, kept for logs; users see a description mapped from `code`.
    /// `retryAfterSeconds` comes with RATE_LIMITED, `attemptsRemaining` with INVALID_CODE.
    case server(
        status: Int, code: String?, message: String, retryAfterSeconds: Int? = nil, attemptsRemaining: Int? = nil)

    /// Maps a non-2xx paygate response (`{"error":{"code","message"}}`).
    init(status: Int, body: Data, authenticated: Bool) {
        let envelope = try? JSONDecoder().decode(Envelope.self, from: body)
        let code = envelope?.error?.code
        switch status {
        case 402 where code == "MONTHLY_CAP_REACHED":
            self = .monthlyCapReached
        case 402:
            self = .insufficientBalance
        case 401 where authenticated:
            self = .notSignedIn
        case 409 where code == "VERSION_CONFLICT":
            self = .versionConflict(current: YapCloudConfigDocument(conflictBody: body))
        default:
            let message = envelope?.error?.message ?? String(data: body, encoding: .utf8) ?? ""
            self = .server(
                status: status, code: code, message: message.isEmpty ? "HTTP \(status)" : message,
                retryAfterSeconds: envelope?.error?.retryAfterSeconds,
                attemptsRemaining: envelope?.error?.attemptsRemaining)
        }
    }

    var errorDescription: String? {
        switch self {
        case .notSignedIn:
            return String(localized: "Not signed in to Yap Cloud. Sign in under Account.")
        case .insufficientBalance:
            return String(localized: "Your Yap Cloud balance has run out. Add funds under Account to keep going.")
        case .monthlyCapReached:
            return String(localized: "You've reached your monthly Yap Cloud spending cap. Raise it under Account to keep going.")
        case .unreachable:
            // One sentence for "can't reach it" and "server-side failure"; the per-code fallback adds "(CODE)".
            return String(localized: "Yap Cloud is temporarily unavailable. Try again shortly.")
        case .invalidAmount:
            return String(
                format: String(localized: "Enter a whole-dollar amount between $%lld and $%lld."),
                Int64(YapCloud.checkoutPresets.min()!), Int64(YapCloud.maximumTopUpUSD))
        case .keychainUnavailable:
            return String(localized: "Couldn't save the sign-in token to the keychain.")
        case .versionConflict:
            return String(localized: "The cloud config changed on another device.")
        case .server(_, let code, _, let retryAfterSeconds, let attemptsRemaining):
            return Self.description(
                forCode: code, retryAfterSeconds: retryAfterSeconds, attemptsRemaining: attemptsRemaining)
        }
    }

    /// Codes from paygate docs/api.md and its fail() calls. Unknown codes and non-paygate failures
    /// (no code) read as a temporary outage; the raw HTTP status is never shown.
    private static func description(forCode code: String?, retryAfterSeconds: Int?, attemptsRemaining: Int?) -> String {
        switch code {
        case "INVALID_CODE":
            if let attemptsRemaining {
                return String(
                    format: String(localized: "That code isn't right. Attempts left: %lld."), Int64(attemptsRemaining))
            }
            return String(localized: "That code isn't right. Check the email and try again.")
        case "CODE_EXPIRED":
            return String(localized: "That code has expired. Send a new code.")
        case "CODE_NOT_FOUND":
            return String(localized: "There's no active code for this email. Send a new code.")
        case "TOO_MANY_ATTEMPTS":
            return String(localized: "Too many wrong tries for this code. Send a new code.")
        case "EMAIL_SEND_FAILED":
            return String(localized: "Couldn't send the email. Try again in a moment.")
        case "INVALID_EMAIL":
            return String(localized: "Enter a valid email address.")
        case "RATE_LIMITED":
            if let retryAfterSeconds, retryAfterSeconds > 0 {
                let minutes = Int64((retryAfterSeconds + 59) / 60)
                return String(
                    format: String(localized: "Too many requests. Try again in %lld min."), minutes)
            }
            return String(localized: "Too many requests. Wait a moment and try again.")
        case "UPSTREAM_UNAVAILABLE":
            return String(localized: "The AI service is unreachable right now. Nothing was charged. Try again shortly.")
        case "STRIPE_ERROR":
            return String(localized: "Payment service is unavailable right now. Try again shortly.")
        case "INVALID_AMOUNT":
            return YapCloudError.invalidAmount.errorDescription ?? ""
        case "MODEL_NOT_ALLOWED":
            return String(localized: "This model isn't available on Yap Cloud. Choose another model.")
        case "STRIPE_NOT_CONFIGURED":
            return String(localized: "Adding funds isn't available yet.")
        case "CONFIG_TOO_LARGE":
            return String(localized: "The config is too large to sync (limit 256 KB).")
        case let code?:
            return String(format: String(localized: "Yap Cloud is temporarily unavailable. Try again shortly. (%@)"), code)
        case nil:
            return String(localized: "Yap Cloud is temporarily unavailable. Try again shortly.")
        }
    }

    private struct Envelope: Decodable {
        struct Body: Decodable {
            let code: String?
            let message: String?
            let retryAfterSeconds: Int?
            let attemptsRemaining: Int?
        }
        let error: Body?
    }
}

// MARK: - Payloads

/// Number, or string holding one (Postgres numerics arrive as strings). Also carries ids of either type.
struct YapCloudScalar: Codable, Hashable {
    let string: String
    var double: Double { Double(string) ?? 0 }

    init(_ string: String) { self.string = string }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(String.self) {
            string = value
        } else if let value = try? container.decode(Int.self) {
            string = String(value)
        } else {
            string = String(try container.decode(Double.self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(string)
    }
}

struct YapCloudUser: Decodable {
    let id: YapCloudScalar
    let email: String
}

private struct YapCloudVerifyResponse: Decodable {
    let token: String
    let user: YapCloudUser
}

extension KeyedDecodingContainer {
    /// Money as integer micros: `<name>Micros` when present, else the `<name>Usd` decimal string (or the legacy
    /// JSON number, read as its text) parsed with Decimal. Never passes through Double arithmetic.
    func decodeMicros(_ microsKey: Key, fallback usdKey: Key) throws -> Int64 {
        if let micros = try decodeIfPresent(Int64.self, forKey: microsKey) { return micros }
        let text = try decode(YapCloudScalar.self, forKey: usdKey).string
        guard let micros = YapCloud.micros(fromDecimal: text) else {
            throw DecodingError.dataCorruptedError(forKey: usdKey, in: self, debugDescription: "Not a decimal: \(text)")
        }
        return micros
    }
}

struct YapCloudMe: Decodable {
    let id: YapCloudScalar
    let email: String
    let balanceMicros: Int64
    /// False until paygate ships spending caps (`monthlyCapMicros` absent from /v1/me); Account hides the cap UI.
    let supportsMonthlyCap: Bool
    /// nil = no cap.
    let monthlyCapMicros: Int64?
    /// This month's spend as the server counts it for the cap.
    let monthSpentMicros: Int64?

    enum CodingKeys: String, CodingKey {
        case id, email, balanceUsd, balanceMicros, monthlyCapMicros, monthSpentMicros
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(YapCloudScalar.self, forKey: .id)
        email = try c.decode(String.self, forKey: .email)
        balanceMicros = try c.decodeMicros(.balanceMicros, fallback: .balanceUsd)
        supportsMonthlyCap = c.contains(.monthlyCapMicros)
        monthlyCapMicros = try c.decodeIfPresent(Int64.self, forKey: .monthlyCapMicros)
        monthSpentMicros = try c.decodeIfPresent(Int64.self, forKey: .monthSpentMicros)
    }

    /// Known to be at or over the cap, so a billed call would get 402 MONTHLY_CAP_REACHED.
    var isAtMonthlyCap: Bool {
        guard let cap = monthlyCapMicros, let spent = monthSpentMicros else { return false }
        return spent >= cap
    }
}

struct YapCloudLedgerEntry: Decodable, Identifiable {
    let id: YapCloudScalar
    let kind: String
    let amountMicros: Int64
    let model: String?
    let createdAt: String
    /// Stripe receipt for topup rows, once paygate sends it.
    let receiptURL: URL?

    enum CodingKeys: String, CodingKey { case id, kind, amountUsd, amountMicros, model, createdAt, receiptUrl }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(YapCloudScalar.self, forKey: .id)
        kind = try c.decode(String.self, forKey: .kind)
        amountMicros = try c.decodeMicros(.amountMicros, fallback: .amountUsd)
        model = try c.decodeIfPresent(String.self, forKey: .model)
        createdAt = try c.decode(String.self, forKey: .createdAt)
        receiptURL = try c.decodeIfPresent(String.self, forKey: .receiptUrl)
            .flatMap(URL.init(string:)).flatMap { $0.scheme == "https" ? $0 : nil }
    }

    var createdDate: Date? { YapCloud.parseDate(createdAt) }
}

/// One signed-in device (one token) from `GET /v1/me/devices`.
/// `GET /v1/config/versions` entry.
struct YapCloudConfigVersion: Decodable, Equatable {
    let version: YapCloudScalar
    let updatedAt: String?
    /// Nil once the device that wrote it has signed out.
    let deviceName: String?
    let bytes: Int?

    var updatedDate: Date? { updatedAt.flatMap(YapCloud.parseDate) }
}

struct YapCloudDevice: Decodable, Identifiable, Equatable {
    let id: YapCloudScalar
    let deviceName: String?
    let createdAt: String
    let lastUsedAt: String?
    /// The device making this request, i.e. this Mac.
    let current: Bool

    var lastUsedDate: Date? { lastUsedAt.flatMap(YapCloud.parseDate) ?? YapCloud.parseDate(createdAt) }

    /// Accepts a bare array or `{devices: [...]}`.
    static func decodeList(_ data: Data) throws -> [YapCloudDevice] {
        struct Wrapped: Decodable { let devices: [YapCloudDevice] }
        if let list = try? JSONDecoder().decode([YapCloudDevice].self, from: data) { return list }
        return try JSONDecoder().decode(Wrapped.self, from: data).devices
    }
}

private struct YapCloudLedger: Decodable {
    let entries: [YapCloudLedgerEntry]
}

private struct YapCloudCheckout: Decodable {
    let url: String
}

/// `GET /v1/usage`: spend (positive micros) since a date, total plus per-model, sorted by spend.
struct YapCloudMonthlySpend: Decodable, Equatable {
    struct ModelSpend: Decodable, Equatable {
        /// nil for charges the server recorded without a model.
        let model: String?
        let micros: Int64
        let calls: Int

        enum CodingKeys: String, CodingKey { case model, micros, usd, calls }

        init(model: String?, micros: Int64, calls: Int) {
            self.model = model
            self.micros = micros
            self.calls = calls
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            model = try c.decodeIfPresent(String.self, forKey: .model)
            micros = try c.decodeMicros(.micros, fallback: .usd)
            calls = try c.decodeIfPresent(Int.self, forKey: .calls) ?? 0
        }
    }

    let totalMicros: Int64
    let byModel: [ModelSpend]
    /// Start of the window (paygate default: 1st of the current UTC month).
    let since: Date?
    /// Part of the spend covered by sign-up credit / by paid balance (`total = credit + paid`); nil on older servers.
    let creditMicros: Int64?
    let paidMicros: Int64?

    var topModels: [ModelSpend] { Array(byModel.prefix(5)) }

    /// This user's average cost per call for `model` this month, from their own usage; nil under 3 calls.
    func averageCallMicros(model: String) -> Int64? {
        byModel.first { $0.model == model }.flatMap { YapCloudMonthlySpend.averageMicros($0.micros, calls: $0.calls) }
    }

    struct Runway: Equatable {
        let monthlyMicros: Int64
        /// Whole days the balance lasts at this month's daily average.
        let days: Int64
    }

    /// Balance ÷ this month's daily average spend. nil with under 3 days of the month elapsed, no spend, no balance,
    /// or a daily average below one micro. Integer micros throughout.
    static func runway(balanceMicros: Int64, spentMicros: Int64, elapsedSeconds: Int64) -> Runway? {
        guard elapsedSeconds >= 3 * 86_400, spentMicros > 0, balanceMicros > 0 else { return nil }
        let dailyMicros = spentMicros * 86_400 / elapsedSeconds
        guard dailyMicros > 0 else { return nil }
        return Runway(monthlyMicros: dailyMicros * 30, days: balanceMicros / dailyMicros)
    }

    /// Rounded half-up integer mean; provider price units differ, so a real per-call average is what's shown.
    static func averageMicros(_ micros: Int64, calls: Int) -> Int64? {
        guard calls >= 3 else { return nil }
        let n = Int64(calls)
        return (micros + n / 2) / n
    }

    enum CodingKeys: String, CodingKey {
        case totalMicros, totalUsd, byModel, since, creditMicros, creditUsd, paidMicros, paidUsd
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        totalMicros = try c.decodeMicros(.totalMicros, fallback: .totalUsd)
        byModel = try c.decode([ModelSpend].self, forKey: .byModel)
        since = try c.decodeIfPresent(String.self, forKey: .since).flatMap(YapCloud.parseDate)
        creditMicros = c.contains(.creditMicros) || c.contains(.creditUsd)
            ? try c.decodeMicros(.creditMicros, fallback: .creditUsd) : nil
        paidMicros = c.contains(.paidMicros) || c.contains(.paidUsd)
            ? try c.decodeMicros(.paidMicros, fallback: .paidUsd) : nil
    }
}

struct YapCloudCatalog: Codable {
    let models: [YapCloudModel]
}

struct YapCloudModel: Codable, Hashable {
    struct Architecture: Codable, Hashable {
        let inputModalities: [String]?
        let outputModalities: [String]?

        enum CodingKeys: String, CodingKey {
            case inputModalities = "input_modalities"
            case outputModalities = "output_modalities"
        }
    }

    let id: String
    let name: String?
    let architecture: Architecture?
    /// USD per token (`prompt`, `completion`), per audio unit (`audio`), per call (`request`), already marked up.
    let pricing: [String: YapCloudScalar]?

    var displayName: String { name ?? id }
    var isTranscription: Bool { architecture?.outputModalities?.contains("transcription") == true }
    /// Models without architecture predate the contract's split; treat them as chat models.
    var isChat: Bool { architecture?.outputModalities.map { $0.contains("text") } ?? true }
    func price(_ key: String) -> Double? { pricing?[key]?.double }
}

struct YapCloudConfigDocument: Equatable {
    let version: String
    /// The opaque config object, as JSON bytes.
    let config: Data

    /// `GET /v1/config` body plus its `ETag: "<version>"`.
    init?(body: Data, etag: String?) {
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return nil }
        self.init(object: object, etag: etag)
    }

    /// 409 bodies carry the current document either at the top level or under `current`.
    init?(conflictBody: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: conflictBody) as? [String: Any] else { return nil }
        self.init(object: (object["current"] as? [String: Any]) ?? object, etag: nil)
    }

    private init?(object: [String: Any], etag: String?) {
        let version = etag.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "W/\"")) }
            ?? object["version"].map { "\($0)" }
        guard let version, let config = object["config"],
            let data = try? JSONSerialization.data(withJSONObject: config, options: [.sortedKeys])
        else { return nil }
        self.version = version
        self.config = data
    }
}

// MARK: - Self-check

#if DEBUG
    extension YapCloud {
        static func selfCheck() {
            func json(_ string: String) -> Data { Data(string.utf8) }

            // Error mapping
            assert(YapCloudError(status: 402, body: json(#"{"error":{"code":"INSUFFICIENT_BALANCE","message":"x"}}"#), authenticated: true) == .insufficientBalance)
            assert(YapCloudError(status: 402, body: Data(), authenticated: true) == .insufficientBalance)
            assert(YapCloudError(status: 401, body: Data(), authenticated: true) == .notSignedIn)
            assert(
                YapCloudError(status: 401, body: json(#"{"error":{"code":"INVALID_CODE","message":"Wrong code"}}"#), authenticated: false)
                    == .server(status: 401, code: "INVALID_CODE", message: "Wrong code"))
            assert(YapCloudError(status: 500, body: Data(), authenticated: true) == .server(status: 500, code: nil, message: "HTTP 500"))
            assert(YapCloudError(status: 500, body: Data(), authenticated: true).errorDescription?.contains("500") == false)
            assert(YapCloudError.server(status: 503, code: "SOMETHING_NEW", message: "x").errorDescription?
                .contains("SOMETHING_NEW") == true)
            assert(YapCloudError.server(status: 429, code: "RATE_LIMITED", message: "x").errorDescription?
                .contains("RATE_LIMITED") == false)
            assert(
                YapCloudError(
                    status: 429, body: Data(#"{"error":{"code":"RATE_LIMITED","message":"m","retryAfterSeconds":61}}"#.utf8),
                    authenticated: false)
                    == .server(status: 429, code: "RATE_LIMITED", message: "m", retryAfterSeconds: 61))
            let conflict = YapCloudError(
                status: 409, body: json(#"{"error":{"code":"VERSION_CONFLICT"},"current":{"version":7,"config":{"a":1}}}"#),
                authenticated: true)
            assert(conflict == .versionConflict(current: YapCloudConfigDocument(body: json(#"{"version":"7","config":{"a":1}}"#), etag: nil)))

            // Decoding: numbers as numbers or strings
            func me(_ body: String) -> Int64? { try? JSONDecoder().decode(YapCloudMe.self, from: json(body)).balanceMicros }
            assert(me(#"{"id":3,"email":"a@b.c","balanceUsd":"12.50"}"#) == 12_500_000)
            assert(me(#"{"id":"u","email":"a@b.c","balanceUsd":"12.50","balanceMicros":12500001}"#) == 12_500_001)
            assert(me(#"{"id":"u","email":"a@b.c","balanceUsd":0}"#) == 0)
            assert(me(#"{"id":"u","email":"a@b.c","balanceUsd":9.9979}"#) == 9_997_900)
            assert(me(#"{"id":"u","email":"a@b.c","balanceUsd":"-0.0000210000"}"#) == -21)
            assert(me(#"{"id":"u","email":"a@b.c","balanceUsd":"abc"}"#) == nil)
            assert(micros(fromDecimal: "0.0000005") == 1 && micros(fromDecimal: "1.1e-07") == 0)
            let ledger = try! JSONDecoder().decode(
                YapCloudLedger.self,
                from: json(#"{"entries":[{"id":"u1","kind":"usage","amountUsd":-0.0021,"model":"m","createdAt":"2026-09-25T10:00:00.123Z","meta":{}}]}"#))
            assert(ledger.entries[0].amountMicros == -2_100 && ledger.entries[0].createdDate != nil)
            let catalog = try! JSONDecoder().decode(
                YapCloudCatalog.self,
                from: json(#"""
                    {"markup":0.1,"models":[
                     {"id":"microsoft/mai-transcribe-2","name":"MAI","architecture":{"input_modalities":["audio"],"output_modalities":["transcription"]},"pricing":{"prompt":"0","completion":"0","audio":"0.0000275"}},
                     {"id":"deepseek/deepseek-v4.1-flash","architecture":{"input_modalities":["text"],"output_modalities":["text"]},"pricing":{"prompt":0.00000011,"completion":"0.00000044"}},
                     {"id":"legacy","pricing":{"prompt":"1"}}]}
                    """#))
            assert(catalog.models.map(\.isTranscription) == [true, false, false])
            assert(catalog.models.map(\.isChat) == [false, true, true])
            assert(catalog.models[0].price("audio") == 0.0000275 && catalog.models[1].price("prompt") == 0.00000011)
            assert(catalog.models[1].displayName == "deepseek/deepseek-v4.1-flash" && catalog.models[2].price("audio") == nil)

            // Config document
            let doc = YapCloudConfigDocument(body: json(#"{"version":2,"updatedAt":"x","config":{"b":1,"a":2}}"#), etag: #""5""#)
            assert(doc?.version == "5" && doc?.config == json(#"{"a":2,"b":1}"#))
            assert(YapCloudConfigDocument(body: json(#"{"version":2}"#), etag: nil) == nil)

            // Money formatting (integer micros → cents, half-up)
            assert(formatUSD(micros: 12_345_678) == "$12.35" && formatUSD(micros: 0) == "$0.00")
            assert(formatUSD(micros: -400_000) == "-$0.40" && formatUSD(micros: -2_100) == "$0.00")
            assert(formatUSD(micros: 999_999) == "$1.00" && formatUSD(micros: 5_000_000_000) == "$5000.00")
            assert(formatUSD(micros: -1_200, decimals: 4) == "-$0.0012" && formatUSD(micros: 12_345_678, decimals: 4) == "$12.3457")
            assert(formatUSD(micros: 7, decimals: 6) == "$0.000007" && formatUSD(micros: 2_500_000, decimals: 0) == "$3")
            assert(formatLedgerAmount(micros: -92, kind: "usage") == "-<$0.0001")
            assert(formatLedgerAmount(micros: -150, kind: "usage") == "-$0.0002")
            assert(formatLedgerAmount(micros: 0, kind: "usage") == "$0.0000")
            assert(formatLedgerAmount(micros: -999_904, kind: "adjust") == "-$1.00")
            assert(formatLedgerAmount(micros: 10_000_000, kind: "topup") == "$10.00")
            assert(999_999 < lowBalanceMicros && !(1_000_000 < lowBalanceMicros))

            // Runway: balance ÷ daily average; hidden early in the month or without spend
            let day: Int64 = 86_400
            assert(YapCloudMonthlySpend.runway(balanceMicros: 10_000_000, spentMicros: 3_000_000, elapsedSeconds: 3 * day)
                == .init(monthlyMicros: 30_000_000, days: 10))
            assert(YapCloudMonthlySpend.runway(balanceMicros: 10_000_000, spentMicros: 3_000_000, elapsedSeconds: 3 * day - 1) == nil)
            assert(YapCloudMonthlySpend.runway(balanceMicros: 0, spentMicros: 3_000_000, elapsedSeconds: 10 * day) == nil)
            assert(YapCloudMonthlySpend.runway(balanceMicros: 5, spentMicros: 0, elapsedSeconds: 10 * day) == nil)
            assert(YapCloudMonthlySpend.runway(balanceMicros: 5, spentMicros: 2, elapsedSeconds: 10 * day) == nil)
            assert(YapCloudMonthlySpend.runway(balanceMicros: 999_999, spentMicros: 10_000_000, elapsedSeconds: 10 * day)?.days == 0)

            // Average per call
            assert(YapCloudMonthlySpend.averageMicros(184, calls: 2) == nil)
            assert(YapCloudMonthlySpend.averageMicros(184, calls: 3) == 61 && YapCloudMonthlySpend.averageMicros(185, calls: 2) == nil)
            assert(YapCloudMonthlySpend.averageMicros(9, calls: 4) == 2 && YapCloudMonthlySpend.averageMicros(10, calls: 4) == 3)
            assert(formatAverage(micros: 1_200) == "~$0.0012" && formatAverage(micros: 2) == "<$0.0001")

            // /v1/usage
            let usage = try! JSONDecoder().decode(
                YapCloudMonthlySpend.self,
                from: json(#"""
                    {"since":"2026-09-01T00:00:00.000Z","until":"x","totalMicros":193,"totalUsd":"0.000193","byModel":[
                     {"model":"a","micros":100,"usd":"0.000100","calls":2},{"model":null,"micros":50,"usd":"0.000050","calls":1},
                     {"model":"c","micros":20,"calls":1},{"model":"d","micros":10,"calls":1},{"model":"e","micros":8,"calls":1},
                     {"model":"f","usd":"0.000005","calls":1}]}
                    """#))
            assert(usage.since == parseDate("2026-09-01T00:00:00.000Z") && usage.creditMicros == nil)
            let split = try! JSONDecoder().decode(
                YapCloudMonthlySpend.self,
                from: json(#"{"totalMicros":300,"creditMicros":200,"creditUsd":"0.000200","paidUsd":"0.000100","byModel":[]}"#))
            assert(split.creditMicros == 200 && split.paidMicros == 100)
            let receipts = try! JSONDecoder().decode(
                YapCloudLedger.self,
                from: json(#"""
                    {"entries":[
                     {"id":"2","kind":"topup","amountMicros":5000000,"createdAt":"2026-09-25T10:00:00Z","receiptUrl":"https://pay.stripe.com/receipts/x"},
                     {"id":"1","kind":"topup","amountMicros":5000000,"createdAt":"2026-09-25T10:00:00Z","receiptUrl":"javascript:alert(1)"}]}
                    """#)).entries
            assert(receipts[0].receiptURL?.host == "pay.stripe.com" && receipts[1].receiptURL == nil)
            assert(usage.totalMicros == 193 && usage.byModel.count == 6 && usage.topModels.count == 5)
            assert(usage.byModel[0] == .init(model: "a", micros: 100, calls: 2) && usage.byModel[1].model == nil)
            assert(usage.byModel[5].micros == 5)
            assert(try! JSONDecoder().decode(YapCloudMonthlySpend.self, from: json(#"{"totalMicros":0,"byModel":[]}"#)).topModels.isEmpty)

            // Monthly cap (fake /v1/me and 402 bodies until paygate ships it)
            let noCapField = try! JSONDecoder().decode(YapCloudMe.self, from: json(#"{"id":"u","email":"a@b.c","balanceMicros":5}"#))
            assert(!noCapField.supportsMonthlyCap && noCapField.monthlyCapMicros == nil && !noCapField.isAtMonthlyCap)
            let uncapped = try! JSONDecoder().decode(
                YapCloudMe.self, from: json(#"{"id":"u","email":"a@b.c","balanceMicros":5,"monthlyCapMicros":null,"monthSpentMicros":900}"#))
            assert(uncapped.supportsMonthlyCap && uncapped.monthlyCapMicros == nil && !uncapped.isAtMonthlyCap)
            let capped = try! JSONDecoder().decode(
                YapCloudMe.self,
                from: json(#"{"id":"u","email":"a@b.c","balanceMicros":5,"monthlyCapMicros":5000000,"monthSpentMicros":5000000}"#))
            assert(capped.monthlyCapMicros == 5_000_000 && capped.isAtMonthlyCap)
            assert(
                YapCloudError(status: 402, body: json(#"{"error":{"code":"MONTHLY_CAP_REACHED","message":"x"}}"#), authenticated: true)
                    == .monthlyCapReached)
            assert(String(data: try! JSONSerialization.data(withJSONObject: limitsBody(capMicros: nil)), encoding: .utf8) == #"{"monthlyCapMicros":null}"#)
            assert(String(data: try! JSONSerialization.data(withJSONObject: limitsBody(capMicros: 20_000_000)), encoding: .utf8) == #"{"monthlyCapMicros":20000000}"#)
            assert(monthlyCapMicros(fromDollars: "$0.0001") == 100 && monthlyCapMicros(fromDollars: "0") == 0)
            assert(monthlyCapMicros(fromDollars: "50") == 50_000_000 && monthlyCapMicros(fromDollars: "10000") == 10_000_000_000)
            assert(monthlyCapMicros(fromDollars: "10000.01") == nil && monthlyCapMicros(fromDollars: "-1") == nil)
            assert(monthlyCapMicros(fromDollars: "") == nil && monthlyCapMicros(fromDollars: "abc") == nil)
            assert(formatExactUSD(micros: 100) == "$0.0001" && formatExactUSD(micros: 5_000_000) == "$5.00")
            assert(formatExactUSD(micros: 1_234_567) == "$1.234567" && formatExactUSD(micros: 0) == "$0.00")

            // Top-up arrival
            assert(creditedMicros(before: 5, after: 10_000_005) == 10_000_000)
            assert(creditedMicros(before: 5, after: 5) == nil && creditedMicros(before: 5, after: 3) == nil)
            assert(creditedMicros(before: -200, after: 4_999_800) == 5_000_000)

            // Devices (fake /v1/me/devices until paygate ships it)
            let devicesJSON = #"""
                [{"id":"d1","deviceName":"Jackson's MacBook Pro","createdAt":"2026-09-01T10:00:00.000Z","lastUsedAt":"2026-09-25T09:00:00Z","current":true},
                 {"id":7,"deviceName":null,"createdAt":"2026-08-01T10:00:00Z","lastUsedAt":null,"current":false}]
                """#
            let devices = try! YapCloudDevice.decodeList(json(devicesJSON))
            assert(devices.count == 2 && devices[0].current && !devices[1].current)
            assert(devices[1].id.string == "7" && devices[1].deviceName == nil)
            assert(devices[0].lastUsedDate == parseDate("2026-09-25T09:00:00Z"))
            assert(devices[1].lastUsedDate == parseDate("2026-08-01T10:00:00Z"))
            assert(try! YapCloudDevice.decodeList(json(#"{"devices":\#(devicesJSON)}"#)) == devices)

            // Sign-up credit: a recent positive credit row only
            let credits = try! JSONDecoder().decode(
                YapCloudLedger.self,
                from: json(#"""
                    {"entries":[
                     {"id":"3","kind":"usage","amountMicros":-92,"createdAt":"2026-09-25T10:30:00Z"},
                     {"id":"1","kind":"credit","amountMicros":1000000,"createdAt":"2026-09-25T10:00:00Z"}]}
                    """#)).entries
            let t0 = parseDate("2026-09-25T10:00:00Z")!
            assert(signupCreditMicros(in: credits, now: t0.addingTimeInterval(600)) == 1_000_000)
            assert(signupCreditMicros(in: credits, now: t0.addingTimeInterval(7200)) == nil)
            assert(signupCreditMicros(in: Array(credits.prefix(1)), now: t0) == nil)

            // yap:// links
            assert(isAccountRefreshURL(URL(string: "yap://account/refresh")!) && isAccountRefreshURL(URL(string: "YAP://Account")!))
            assert(isAccountRefreshURL(URL(string: "yap://account/refresh?session=cs_1")!))
            assert(!isAccountRefreshURL(URL(string: "yap://account/delete")!) && !isAccountRefreshURL(URL(string: "yap://settings")!))
            assert(!isAccountRefreshURL(URL(string: "https://account/refresh")!))
            assert(isAccountRefreshURL(URL(string: "yap-dev://account/refresh")!) && !isAccountRefreshURL(URL(string: "yapx://account")!))

            // Timeouts
            assert(transcriptionTimeout(audioSeconds: 0) == 10 && transcriptionTimeout(audioSeconds: 20) == 40)
            assert(transcriptionTimeout(audioSeconds: 600) == 120)
            var wav = Data("RIFF".utf8) + Data(repeating: 0, count: 4) + Data("WAVEfmt ".utf8)
            wav += Data([16, 0, 0, 0, 1, 0, 1, 0, 0x80, 0x3E, 0, 0, 0, 0x7D, 0, 0, 2, 0, 16, 0])  // 16 kHz mono s16: 32000 B/s
            wav += Data("data".utf8) + Data([0x00, 0xFA, 0, 0]) + Data(count: 64_000)  // 64000 bytes = 2 s
            assert(wavDuration(wav) == 2 && wavDuration(Data("not a wav".utf8)) == nil)
            var padded = Data("RIFF".utf8) + Data(repeating: 0, count: 4) + Data("WAVE".utf8)
            padded += Data("FLLR".utf8) + Data([4, 0, 0, 0]) + Data(count: 4)  // filler chunk before fmt
            padded += Data("fmt ".utf8) + Data([16, 0, 0, 0, 1, 0, 1, 0, 0x80, 0x3E, 0, 0, 0, 0x7D, 0, 0, 2, 0, 16, 0])
            padded += Data("data".utf8) + Data([0x00, 0x7D, 0, 0]) + Data(count: 32_000)
            assert(wavDuration(padded) == 1)

            // Unreachable classification
            assert(classify(URLError(.timedOut)) as? YapCloudError == .unreachable)
            assert(classify(YapCloudError.server(status: 503, code: nil, message: "")) as? YapCloudError == .unreachable)
            assert(classify(YapCloudError.insufficientBalance) as? YapCloudError == .insufficientBalance)
            assert(classify(YapCloudError.server(status: 500, code: nil, message: "")) as? YapCloudError != .unreachable)

            // Proxy retry policy: only provably-unbilled failures, once
            assert(isSafeToRetry(URLError(.cannotConnectToHost)) && isSafeToRetry(URLError(.notConnectedToInternet)))
            assert(!isSafeToRetry(URLError(.timedOut)) && !isSafeToRetry(URLError(.networkConnectionLost)))
            assert(isSafeToRetry(YapCloudError.server(status: 502, code: "UPSTREAM_UNAVAILABLE", message: "")))
            assert(!isSafeToRetry(YapCloudError.insufficientBalance) && !isSafeToRetry(YapCloudError.notSignedIn))
            assert(!isSafeToRetry(YapCloudError.server(status: 400, code: "MODEL_NOT_ALLOWED", message: "")))

            // Top-up amounts
            assert(isValidTopUp(5) && isValidTopUp(20) && isValidTopUp(500))
            assert(!isValidTopUp(4) && !isValidTopUp(0) && !isValidTopUp(-10) && !isValidTopUp(501))
        }
    }
#endif
