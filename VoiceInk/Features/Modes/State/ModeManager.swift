import Foundation
import os

enum ModeRemovalResult {
    case removed
    case blockedDefault
    case notFound
}

class ModeManager: ObservableObject {
    static let shared = ModeManager()
    @Published var configurations: [ModeConfig] = []
    @Published var activeConfiguration: ModeConfig?

    private let triggerLogger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "mode.triggers")

    private let configKey = "modeConfigurationsV2"
    private let activeConfigIdKey = "activeConfigurationId"

    private init() {
        loadConfigurations()

        if let activeConfigIdString = UserDefaults.standard.string(forKey: activeConfigIdKey),
            let activeConfigId = UUID(uuidString: activeConfigIdString)
        {
            activeConfiguration = configurations.first { $0.id == activeConfigId }
        } else {
            activeConfiguration = nil
        }
    }

    private func loadConfigurations() {
        if let data = migratedModeConfigurationData(for: configKey),
            let configs = try? JSONDecoder().decode([ModeConfig].self, from: data)
        {
            configurations = configs
            migrateLoadedModeConfigurationsIfNeeded()
        }
    }

    func saveConfigurations() {
        if let data = try? JSONEncoder().encode(configurations) {
            UserDefaults.standard.set(data, forKey: configKey)
        }
        NotificationCenter.default.post(name: .modeConfigurationsDidChange, object: nil)
    }

    func addConfiguration(_ newConfiguration: ModeConfig) {
        guard !configurations.contains(where: { $0.id == newConfiguration.id }) else {
            return
        }

        let previousEnabledConfigIds = enabledConfigurationIds
        var configuration = newConfiguration
        if configuration.isDefault {
            for index in configurations.indices {
                configurations[index].isDefault = false
            }
            configuration.isEnabled = true
        }

        configurations.append(configuration)
        saveConfigurations()
        postShortcutAvailabilityChangeIfNeeded(previousEnabledConfigIds: previousEnabledConfigIds)
    }

    @discardableResult
    func duplicateConfiguration(with id: UUID) -> ModeConfig? {
        guard let index = configurations.firstIndex(where: { $0.id == id }) else { return nil }

        let source = configurations[index]
        var duplicate = source
        duplicate.id = UUID()
        duplicate.name = nextDuplicateName(for: source.name)
        duplicate.isDefault = false

        // The new mode keeps the settings, but claims no automatic triggers.
        duplicate.appConfigs = nil
        duplicate.urlConfigs = nil
        duplicate.triggerGroups = nil
        duplicate.triggerWords = []

        // Shortcuts are keyed by mode ID, so the duplicate starts without a shortcut.
        let previousEnabledConfigIds = enabledConfigurationIds
        configurations.insert(duplicate, at: index + 1)
        saveConfigurations()
        postShortcutAvailabilityChangeIfNeeded(previousEnabledConfigIds: previousEnabledConfigIds)
        return duplicate
    }

    private func nextDuplicateName(for name: String) -> String {
        let names = Set(configurations.map(\.name))
        var base = name
        if let separator = name.lastIndex(of: " "),
            let suffix = Int(name[name.index(after: separator)...]),
            suffix > 0,
            names.contains(String(name[..<separator]))
        {
            base = String(name[..<separator])
        }

        var number = 1
        while names.contains("\(base) \(number)") {
            number += 1
        }
        return "\(base) \(number)"
    }

    func removeConfiguration(with id: UUID) -> ModeRemovalResult {
        guard let configuration = getConfiguration(with: id) else {
            return .notFound
        }
        guard !configuration.isDefault else {
            return .blockedDefault
        }

        let previousEffectiveConfigurationId = currentEffectiveConfiguration?.id
        let previousEnabledConfigIds = enabledConfigurationIds
        ShortcutStore.removeShortcutStorage(for: .mode(id))
        configurations.removeAll { $0.id == id }
        let selectedConfiguration = repairActiveConfigurationIfNeeded(
            previousEffectiveConfigurationId: previousEffectiveConfigurationId
        )
        saveConfigurations()
        postShortcutAvailabilityChangeIfNeeded(previousEnabledConfigIds: previousEnabledConfigIds)
        notifyActiveConfigurationChange(selectedConfiguration)
        return .removed
    }

    func getConfiguration(with id: UUID) -> ModeConfig? {
        return configurations.first { $0.id == id }
    }

    func updateConfiguration(_ updatedConfiguration: ModeConfig) {
        guard let index = configurations.firstIndex(where: { $0.id == updatedConfiguration.id }) else {
            return
        }

        let previousEnabledConfigIds = enabledConfigurationIds
        var configuration = updatedConfiguration
        if configuration.isDefault {
            for configurationIndex in configurations.indices {
                configurations[configurationIndex].isDefault = false
            }
            configuration.isEnabled = true
        }

        configurations[index] = configuration
        saveConfigurations()
        postShortcutAvailabilityChangeIfNeeded(previousEnabledConfigIds: previousEnabledConfigIds)
    }

    func moveConfigurations(fromOffsets: IndexSet, toOffset: Int) {
        var updatedConfigurations = configurations
        updatedConfigurations.move(fromOffsets: fromOffsets, toOffset: toOffset)
        replaceConfigurations(updatedConfigurations)
    }

    func replaceConfigurations(_ updatedConfigurations: [ModeConfig]) {
        let previousEnabledConfigIds = enabledConfigurationIds
        configurations = updatedConfigurations
        saveConfigurations()
        postShortcutAvailabilityChangeIfNeeded(previousEnabledConfigIds: previousEnabledConfigIds)
    }

    /// Captures rule order as well as disabled rules, which matching deliberately skips.
    func logTriggerRules(diagnosticID: String) {
        triggerLogger.notice(
            "Mode rules id=\(diagnosticID, privacy: .public) count=\(self.configurations.count, privacy: .public) precedence=explicit-mode,website,app,default first-match-wins=true"
        )
        for (index, config) in configurations.enumerated() {
            let apps = config.allAppConfigs.map { $0.bundleIdentifier }.joined(separator: ",")
            let websites = config.allURLConfigs.map { $0.url }.joined(separator: ",")
            triggerLogger.notice(
                "Mode rule id=\(diagnosticID, privacy: .public) order=\(index, privacy: .public) mode=\(config.id.uuidString, privacy: .public) name=\(config.name, privacy: .private) enabled=\(config.isEnabled, privacy: .public) default=\(config.isDefault, privacy: .public) apps=\(apps, privacy: .public) websites=\(websites, privacy: .private)"
            )
        }
    }

    func getConfigurationForURL(_ url: String, diagnosticID: String? = nil) -> ModeConfig? {
        guard let target = Self.target(ofBrowserURL: url) else {
            if let diagnosticID {
                triggerLogger.notice("Website detection id=\(diagnosticID, privacy: .public) result=invalid-or-hostless-url url=\(url, privacy: .private)")
            }
            return nil
        }
        if let diagnosticID {
            let port = target.port.map { String($0) } ?? "unspecified"
            triggerLogger.notice(
                "Website detection id=\(diagnosticID, privacy: .public) host=\(target.host, privacy: .private) port=\(port, privacy: .public) path=\(target.path, privacy: .private) policy=domain-or-subdomain,path-segment-prefix,case-insensitive,explicit-port"
            )
        }

        var checked = 0
        for config in configurations.filter({ $0.isEnabled }) {
            for (index, urlConfig) in config.allURLConfigs.enumerated() {
                let normalizedTrigger = cleanURL(urlConfig.url)
                let reason = Self.triggerMismatchReason(normalizedTrigger, target: target)
                let containsQueryOrFragment = normalizedTrigger.contains("?") || normalizedTrigger.contains("#")
                checked += 1
                if let diagnosticID {
                    triggerLogger.notice(
                        "Website rule id=\(diagnosticID, privacy: .public) mode=\(config.id.uuidString, privacy: .public) rule=\(index, privacy: .public) trigger=\(urlConfig.url, privacy: .private) normalizedTrigger=\(normalizedTrigger, privacy: .private) queryOrFragmentInTrigger=\(containsQueryOrFragment, privacy: .public) result=\(reason ?? "matched", privacy: .public)"
                    )
                }
                if reason == nil {
                    return config
                }
            }
        }
        if let diagnosticID {
            triggerLogger.notice("Website detection id=\(diagnosticID, privacy: .public) result=no-match rulesChecked=\(checked, privacy: .public)")
        }
        return nil
    }

    /// Host, port and path of the active tab. The host is lowercased and loses a
    /// leading "www.". Triggers are stored without a scheme, so a bare host is
    /// parsed as one.
    static func target(ofBrowserURL url: String) -> (host: String, port: Int?, path: String)? {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let absolute = trimmed.contains("://") ? trimmed : "https://" + trimmed
        guard let components = URLComponents(string: absolute),
            let host = components.host,
            !host.isEmpty
        else {
            return nil
        }

        return (normalizedHost(host), components.port, components.path)
    }

    /// A trigger matches the host itself or any subdomain of it. A trigger that
    /// carries a path, such as "icloud.com/mail", also has to match that path
    /// prefix on a segment boundary. Triggers are stored lowercased, so paths
    /// are compared without regard to case.
    static func trigger(_ trigger: String, matches target: (host: String, port: Int?, path: String)) -> Bool {
        triggerMismatchReason(trigger, target: target) == nil
    }

    /// Nil means a match. The same decision supplies diagnostics so reasons cannot drift from matching.
    private static func triggerMismatchReason(_ trigger: String, target: (host: String, port: Int?, path: String)) -> String? {
        let parts = trigger.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        guard let first = parts.first else { return "empty-trigger" }

        let authority = String(first)
        let triggerHost = normalizedHost(authority)
        guard !triggerHost.isEmpty else { return "empty-trigger-host" }
        guard target.host == triggerHost || target.host.hasSuffix("." + triggerHost) else { return "host-mismatch" }

        // A trigger that names a port only matches that port. A trigger whose
        // port is not a number matches nothing rather than every port.
        switch port(ofAuthority: authority) {
        case .absent: break
        case .malformed: return "malformed-trigger-port"
        case .number(let triggerPort): if target.port != triggerPort { return "port-mismatch" }
        }

        guard parts.count > 1 else { return nil }
        // URLComponents reports a decoded path, so decode the trigger as well.
        let rawTriggerPath = String(parts[1])
        let triggerPath = (rawTriggerPath.removingPercentEncoding ?? rawTriggerPath)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .lowercased()
        guard !triggerPath.isEmpty else { return nil }

        let prefix = "/" + triggerPath
        let path = target.path.lowercased()
        return path == prefix || path.hasPrefix(prefix + "/") ? nil : "path-mismatch"
    }

    private enum TriggerPort {
        case absent
        case number(Int)
        case malformed
    }

    /// The port of a stored trigger. An IPv6 literal without a bracketed port
    /// carries colons of its own and counts as portless.
    private static func port(ofAuthority authority: String) -> TriggerPort {
        let suffix: Substring
        if authority.hasPrefix("[") {
            guard let closingBracket = authority.firstIndex(of: "]") else { return .malformed }
            let rest = authority[authority.index(after: closingBracket)...]
            guard rest.hasPrefix(":") else { return rest.isEmpty ? .absent : .malformed }
            suffix = rest.dropFirst()
        } else {
            guard authority.filter({ $0 == ":" }).count == 1,
                let portSeparator = authority.firstIndex(of: ":")
            else {
                return .absent
            }
            suffix = authority[authority.index(after: portSeparator)...]
        }

        guard let value = Int(suffix), (1...65535).contains(value) else { return .malformed }
        return .number(value)
    }

    /// Lowercases a host, drops a leading "www." and drops a port. An IPv6
    /// literal keeps its address: only a single colon is read as a port
    /// separator, and a bracketed literal is unwrapped first.
    private static func normalizedHost(_ host: String) -> String {
        var value = host.lowercased()
        if value.hasPrefix("["), let closingBracket = value.firstIndex(of: "]") {
            value = String(value[value.index(after: value.startIndex)..<closingBracket])
        } else if value.filter({ $0 == ":" }).count == 1, let portSeparator = value.firstIndex(of: ":") {
            value = String(value[..<portSeparator])
        }
        if value.hasPrefix("www.") {
            value = String(value.dropFirst(4))
        }
        return value
    }

    func getConfigurationForApp(_ bundleId: String, diagnosticID: String? = nil) -> ModeConfig? {
        for config in configurations.filter({ $0.isEnabled }) {
            let matched = config.allAppConfigs.contains(where: { $0.bundleIdentifier == bundleId })
            if let diagnosticID {
                triggerLogger.notice(
                    "App rule id=\(diagnosticID, privacy: .public) mode=\(config.id.uuidString, privacy: .public) app=\(bundleId, privacy: .public) result=\(matched ? "matched" : "no-matching-app-trigger", privacy: .public)"
                )
            }
            if matched {
                return config
            }
        }
        return nil
    }

    func getDefaultConfiguration() -> ModeConfig? {
        return configurations.first { $0.isEnabled && $0.isDefault }
    }

    /// The single source of truth for which mode is running, for UI and pipeline alike.
    var currentEffectiveConfiguration: ModeConfig? {
        if let activeConfiguration,
            let latestActive = configurations.first(where: { $0.id == activeConfiguration.id }),
            latestActive.isEnabled
        {
            return latestActive
        }

        return getDefaultConfiguration() ?? enabledConfigurations.first
    }

    func hasDefaultConfiguration() -> Bool {
        return configurations.contains { $0.isDefault }
    }

    func setAsDefault(configId: UUID, skipSave: Bool = false) {
        guard let targetIndex = configurations.firstIndex(where: { $0.id == configId }) else {
            return
        }

        let previousEnabledConfigIds = enabledConfigurationIds

        for index in configurations.indices {
            configurations[index].isDefault = false
        }

        configurations[targetIndex].isDefault = true
        configurations[targetIndex].isEnabled = true

        if !skipSave {
            saveConfigurations()
        }
        postShortcutAvailabilityChangeIfNeeded(previousEnabledConfigIds: previousEnabledConfigIds)
    }

    func enableConfiguration(with id: UUID) {
        if let index = configurations.firstIndex(where: { $0.id == id }) {
            let previousEnabledConfigIds = enabledConfigurationIds
            configurations[index].isEnabled = true
            saveConfigurations()
            postShortcutAvailabilityChangeIfNeeded(previousEnabledConfigIds: previousEnabledConfigIds)
        }
    }

    func disableConfiguration(with id: UUID) {
        guard let index = configurations.firstIndex(where: { $0.id == id }),
            configurations[index].isEnabled,
            !configurations[index].isDefault
        else {
            return
        }

        let previousEffectiveConfigurationId = currentEffectiveConfiguration?.id
        let previousEnabledConfigIds = enabledConfigurationIds
        configurations[index].isEnabled = false
        let selectedConfiguration = repairActiveConfigurationIfNeeded(
            previousEffectiveConfigurationId: previousEffectiveConfigurationId
        )
        saveConfigurations()
        postShortcutAvailabilityChangeIfNeeded(previousEnabledConfigIds: previousEnabledConfigIds)
        notifyActiveConfigurationChange(selectedConfiguration)
    }

    var enabledConfigurations: [ModeConfig] {
        return configurations.filter { $0.isEnabled }
    }

    func resolvedEnabledConfiguration(preferredId: UUID?) -> ModeConfig? {
        if let preferredId,
            let configuration = enabledConfigurations.first(where: { $0.id == preferredId })
        {
            return configuration
        }

        return currentEffectiveConfiguration
    }

    func resolvedEnabledConfigurationId(preferredId: UUID?) -> UUID? {
        resolvedEnabledConfiguration(preferredId: preferredId)?.id
    }

    var hasEnabledConfiguration: Bool {
        configurations.contains(where: \.isEnabled)
    }

    private var enabledConfigurationIds: Set<UUID> {
        Set(enabledConfigurations.map(\.id))
    }

    /// Repairs an invalid active selection using enabled modes only.
    private func repairActiveConfigurationIfNeeded(
        previousEffectiveConfigurationId: UUID?
    ) -> ModeConfig? {
        let enabledConfigIds = enabledConfigurationIds
        let activeConfigurationIsUnavailable =
            activeConfiguration.map { active in
                !enabledConfigIds.contains(active.id)
            } ?? false
        let previousEffectiveConfigurationIsUnavailable =
            previousEffectiveConfigurationId.map { id in
                !enabledConfigIds.contains(id)
            } ?? false

        guard activeConfigurationIsUnavailable || previousEffectiveConfigurationIsUnavailable else {
            return nil
        }

        guard let target = getDefaultConfiguration() ?? enabledConfigurations.first else {
            setActiveConfiguration(nil)
            return nil
        }

        setActiveConfiguration(target)
        return target.id == previousEffectiveConfigurationId ? nil : target
    }

    private func notifyActiveConfigurationChange(_ config: ModeConfig?) {
        guard let config else { return }

        Task { @MainActor in
            NotificationManager.shared.showNotification(
                title: String(
                    format: String(localized: "Active mode switched to %@"),
                    config.name
                ),
                type: .info
            )
        }
    }

    private func postShortcutAvailabilityChangeIfNeeded(previousEnabledConfigIds: Set<UUID>) {
        guard previousEnabledConfigIds != enabledConfigurationIds else {
            return
        }

        NotificationCenter.default.post(name: .modeShortcutAvailabilityDidChange, object: nil)
    }

    func addAppConfig(_ appConfig: AppConfig, to config: ModeConfig) {
        if var updatedConfig = configurations.first(where: { $0.id == config.id }) {
            var configs = updatedConfig.appConfigs ?? []
            configs.append(appConfig)
            updatedConfig.appConfigs = configs
            updateConfiguration(updatedConfig)
        }
    }

    func removeAppConfig(_ appConfig: AppConfig, from config: ModeConfig) {
        if var updatedConfig = configurations.first(where: { $0.id == config.id }) {
            updatedConfig.appConfigs?.removeAll(where: { $0.id == appConfig.id })
            updateConfiguration(updatedConfig)
        }
    }

    func addURLConfig(_ urlConfig: URLConfig, to config: ModeConfig) {
        if var updatedConfig = configurations.first(where: { $0.id == config.id }) {
            var configs = updatedConfig.urlConfigs ?? []
            configs.append(urlConfig)
            updatedConfig.urlConfigs = configs
            updateConfiguration(updatedConfig)
        }
    }

    func removeURLConfig(_ urlConfig: URLConfig, from config: ModeConfig) {
        if var updatedConfig = configurations.first(where: { $0.id == config.id }) {
            updatedConfig.urlConfigs?.removeAll(where: { $0.id == urlConfig.id })
            updateConfiguration(updatedConfig)
        }
    }

    func getConfigurationForTriggerWord(_ text: String) -> (mode: ModeConfig, processedText: String)? {
        guard
            let detection = ModeTriggerWordDetectionService.detect(
                in: text,
                configurations: configurations.filter { $0.isEnabled }
            )
        else { return nil }
        return (detection.mode, detection.processedText)
    }

    func cleanURL(_ url: String) -> String {
        return url.lowercased()
            .replacingOccurrences(of: "https://", with: "")
            .replacingOccurrences(of: "http://", with: "")
            .replacingOccurrences(of: "www.", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func setActiveConfiguration(_ config: ModeConfig?) {
        if let config,
            let latestConfig = configurations.first(where: { $0.id == config.id })
        {
            activeConfiguration = latestConfig
        } else {
            activeConfiguration = config
        }
        UserDefaults.standard.set(config?.id.uuidString, forKey: activeConfigIdKey)
        self.objectWillChange.send()
    }

    func updateCurrentEffectiveConfiguration(_ update: (inout ModeConfig) -> Void) {
        guard var config = currentEffectiveConfiguration else { return }
        update(&config)
        updateConfiguration(config)

        if activeConfiguration?.id == config.id {
            activeConfiguration = config
        }
    }

    var currentActiveConfiguration: ModeConfig? {
        return activeConfiguration
    }

    func getAllAvailableConfigurations() -> [ModeConfig] {
        return configurations
    }

    func isEmojiInUse(_ emoji: String) -> Bool {
        return configurations.contains { $0.icon == .emoji(emoji) }
    }
}
