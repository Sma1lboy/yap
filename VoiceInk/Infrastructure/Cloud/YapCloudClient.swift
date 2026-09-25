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
    @Published private(set) var me: YapCloudMe?
    @Published private(set) var ledger: [YapCloudLedgerEntry] = []

    private init() {
        #if DEBUG
            YapCloud.selfCheck()
        #endif
        isSignedIn = token != nil
        if let data = defaults.data(forKey: Self.catalogKey) {
            catalog = try? JSONDecoder().decode(YapCloudCatalog.self, from: data)
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
            throw YapCloudError.server(status: 0, code: nil, message: String(localized: "Couldn't save the sign-in token to the keychain."))
        }
        defaults.set(response.user.email, forKey: Self.emailKey)
        isSignedIn = true
        NotificationCenter.default.post(name: .aiProviderKeyChanged, object: nil)
        await refreshAccount()
        await refreshModels()
    }

    @MainActor
    func signOut() async {
        if token != nil {
            do {
                _ = try await send("POST", "/v1/auth/logout")
            } catch {
                logger.error("Logout request failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        clearSession()
    }

    @MainActor
    private func clearSession() {
        keychain.delete(forKey: Self.tokenKey, syncable: false)
        defaults.removeObject(forKey: Self.emailKey)
        isSignedIn = false
        me = nil
        ledger = []
        NotificationCenter.default.post(name: .aiProviderKeyChanged, object: nil)
    }

    // MARK: - Account & wallet

    func fetchMe() async throws -> YapCloudMe {
        try Self.decode(YapCloudMe.self, from: try await send("GET", "/v1/me"))
    }

    func fetchLedger(limit: Int = 20) async throws -> [YapCloudLedgerEntry] {
        try Self.decode(YapCloudLedger.self, from: try await send("GET", "/v1/ledger?limit=\(limit)")).entries
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
        guard token != nil else { return }
        do {
            me = try await fetchMe()
            ledger = try await fetchLedger()
        } catch YapCloudError.notSignedIn {
            clearSession()
        } catch {
            logger.error("Account refresh failed: \(error.localizedDescription, privacy: .public)")
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
        } catch YapCloudError.server(let status, _, _) where status == 404 {
            return nil
        }
    }

    /// Writes `config` (JSON object bytes, no secrets). `ifMatch` is the version you last read; nil = first write.
    /// Returns the new version. A stale version throws `.versionConflict(current:)` with the server's copy.
    func putConfig(_ config: Data, ifMatch version: String?) async throws -> String {
        guard let object = try? JSONSerialization.jsonObject(with: config) else {
            throw YapCloudError.server(status: 0, code: nil, message: "config is not JSON")
        }
        let (data, _) = try await sendWithResponse(
            "PUT", "/v1/config", json: ["config": object], headers: ["If-Match": version.map { "\"\($0)\"" } ?? "*"])
        let body = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let newVersion = body?["version"].map({ "\($0)" }) else {
            throw YapCloudError.server(status: 200, code: nil, message: "Missing version")
        }
        return newVersion
    }

    // MARK: - Funds

    /// Opens Account so the user can add funds; used by the insufficient-balance notification.
    @MainActor
    static func showAddFunds() {
        NSApp.activate(ignoringOtherApps: true)
        NotificationCenter.default.post(
            name: .navigateToDestination, object: nil, userInfo: ["destination": "Account"])
    }

    /// Shows the "add funds" notification when `error` is a Yap Cloud 402. Returns whether it did.
    @MainActor
    @discardableResult
    static func notifyIfInsufficientBalance(_ error: Error) -> Bool {
        guard case YapCloudError.insufficientBalance = error else { return false }
        NotificationManager.shared.showNotification(
            title: YapCloudError.insufficientBalance.errorDescription ?? "",
            type: .error,
            duration: 8,
            onTap: { showAddFunds() },
            actionButton: (label: String(localized: "Add Funds"), action: { showAddFunds() }))
        return true
    }

    /// `$12.35` / `-$0.40`: micros (1 USD = 1e6) rounded half-up to cents, integer math only.
    static func formatUSD(micros: Int64) -> String {
        let cents = (micros.magnitude + 5_000) / 10_000
        let sign = micros < 0 && cents > 0 ? "-" : ""
        return sign + "$" + String(cents / 100) + "." + String(format: "%02d", Int(cents % 100))
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

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard (200..<300).contains(http.statusCode) else {
            throw YapCloudError(status: http.statusCode, body: data, authenticated: authenticated)
        }
        return (data, http)
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
    case invalidAmount
    case versionConflict(current: YapCloudConfigDocument?)
    case server(status: Int, code: String?, message: String)

    /// Maps a non-2xx paygate response (`{"error":{"code","message"}}`).
    init(status: Int, body: Data, authenticated: Bool) {
        let envelope = try? JSONDecoder().decode(Envelope.self, from: body)
        let code = envelope?.error?.code
        switch status {
        case 402:
            self = .insufficientBalance
        case 401 where authenticated:
            self = .notSignedIn
        case 409 where code == "VERSION_CONFLICT":
            self = .versionConflict(current: YapCloudConfigDocument(conflictBody: body))
        default:
            let message = envelope?.error?.message ?? String(data: body, encoding: .utf8) ?? ""
            self = .server(status: status, code: code, message: message.isEmpty ? "HTTP \(status)" : message)
        }
    }

    var errorDescription: String? {
        switch self {
        case .notSignedIn:
            return String(localized: "Not signed in to Yap Cloud. Sign in under Account.")
        case .insufficientBalance:
            return String(localized: "Your Yap Cloud balance has run out. Add funds under Account to keep going.")
        case .invalidAmount:
            return String(
                format: String(localized: "Enter a whole-dollar amount between $%lld and $%lld."),
                Int64(YapCloud.checkoutPresets.min()!), Int64(YapCloud.maximumTopUpUSD))
        case .versionConflict:
            return String(localized: "The cloud config changed on another device.")
        case .server(_, _, let message):
            return message
        }
    }

    private struct Envelope: Decodable {
        struct Body: Decodable {
            let code: String?
            let message: String?
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

    enum CodingKeys: String, CodingKey { case id, email, balanceUsd, balanceMicros }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(YapCloudScalar.self, forKey: .id)
        email = try c.decode(String.self, forKey: .email)
        balanceMicros = try c.decodeMicros(.balanceMicros, fallback: .balanceUsd)
    }
}

struct YapCloudLedgerEntry: Decodable, Identifiable {
    let id: YapCloudScalar
    let kind: String
    let amountMicros: Int64
    let model: String?
    let createdAt: String

    enum CodingKeys: String, CodingKey { case id, kind, amountUsd, amountMicros, model, createdAt }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(YapCloudScalar.self, forKey: .id)
        kind = try c.decode(String.self, forKey: .kind)
        amountMicros = try c.decodeMicros(.amountMicros, fallback: .amountUsd)
        model = try c.decodeIfPresent(String.self, forKey: .model)
        createdAt = try c.decode(String.self, forKey: .createdAt)
    }

    var createdDate: Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: createdAt) ?? ISO8601DateFormatter().date(from: createdAt)
    }
}

private struct YapCloudLedger: Decodable {
    let entries: [YapCloudLedgerEntry]
}

private struct YapCloudCheckout: Decodable {
    let url: String
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
            assert(999_999 < lowBalanceMicros && !(1_000_000 < lowBalanceMicros))

            // Top-up amounts
            assert(isValidTopUp(5) && isValidTopUp(20) && isValidTopUp(500))
            assert(!isValidTopUp(4) && !isValidTopUp(0) && !isValidTopUp(-10) && !isValidTopUp(501))
        }
    }
#endif
