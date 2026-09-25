// Minimal stand-ins for the app types YapCloudClient.swift / YapCloudProvider.swift touch, so `make cloud-smoke`
// can compile the real client files without the app.
import Foundation
import SwiftData

/// In-memory keychain seeded with YAP_CLOUD_SMOKE_TOKEN; nothing touches the real keychain.
final class KeychainService {
    static let shared = KeychainService()
    private var store: [String: String] = [:]
    func getString(forKey key: String, syncable: Bool = true) -> String? { store[key] }
    @discardableResult func save(_ value: String, forKey key: String, syncable: Bool = true) -> Bool {
        store[key] = value
        return true
    }
    @discardableResult func delete(forKey key: String, syncable: Bool = true) -> Bool {
        store[key] = nil
        return true
    }
}

extension Notification.Name {
    static let aiProviderKeyChanged = Notification.Name("aiProviderKeyChanged")
    static let navigateToDestination = Notification.Name("navigateToDestination")
}

enum AppNotificationView { enum NotificationType { case error, warning, info, success } }

@MainActor final class NotificationManager {
    static let shared = NotificationManager()
    private(set) var lastTitle: String?
    private(set) var lastAction: String?
    func showNotification(
        title: String, type: AppNotificationView.NotificationType, duration: TimeInterval = 3,
        onTap: (() -> Void)? = nil, actionButton: (label: String, action: () -> Void)? = nil
    ) {
        lastTitle = title
        lastAction = actionButton?.label
    }
}

enum ModelProvider { case yapCloud }
struct CloudModel {
    let id: UUID
    let name: String
    let displayName: String
    let description: String
    let provider: ModelProvider
    let isMultilingual: Bool
    let supportedLanguages: [String: String]
}
protocol StreamingTranscriptionProvider {}
protocol CloudProvider {}
enum CloudTranscriptionError: Error { case networkError(Error), noTranscriptionReturned }
