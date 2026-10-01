import Foundation

extension Notification.Name {
    static let AppSettingsDidChange = Notification.Name("appSettingsDidChange")
    static let languageDidChange = Notification.Name("languageDidChange")
    static let promptDidChange = Notification.Name("promptDidChange")
    static let toggleRecorderPanel = Notification.Name("toggleRecorderPanel")
    static let dismissRecorderPanel = Notification.Name("dismissRecorderPanel")
    static let didChangeModel = Notification.Name("didChangeModel")
    static let transcribeCppModelDeleted = Notification.Name("transcribeCppModelDeleted")
    static let aiProviderKeyChanged = Notification.Name("aiProviderKeyChanged")
    static let navigateToDestination = Notification.Name("navigateToDestination")
    static let showMainWindowRequested = Notification.Name("showMainWindowRequested")
    static let modeConfigurationApplied = Notification.Name("modeConfigurationApplied")
    static let modeConfigurationsDidChange = Notification.Name("ModeConfigurationsDidChange")
    static let modeShortcutAvailabilityDidChange = Notification.Name("modeShortcutAvailabilityDidChange")
    static let transcriptionCreated = Notification.Name("transcriptionCreated")
    static let transcriptionCompleted = Notification.Name("transcriptionCompleted")
    static let transcriptionDeleted = Notification.Name("transcriptionDeleted")
    static let sessionMetricsDidChange = Notification.Name("sessionMetricsDidChange")
    /// Auto Learn's outcome was saved on an already saved SessionMetric (up to 60 s after the paste). Home's week
    /// panel reloads; Insights doesn't use it.
    static let sessionEditOutcomeDidChange = Notification.Name("sessionEditOutcomeDidChange")
    static let wordReplacementsDidChange = Notification.Name("wordReplacementsDidChange")
    static let autoLearnQueueDidChange = Notification.Name("autoLearnQueueDidChange")
    static let autoLearnReviewProposalsDidChange = Notification.Name("autoLearnReviewProposalsDidChange")
    static let autoLearnRecentlyLearnedDidChange = Notification.Name("autoLearnRecentlyLearnedDidChange")
    static let openFileForTranscription = Notification.Name("openFileForTranscription")
    static let recordingDeviceChangeRequired = Notification.Name("recordingDeviceChangeRequired")
    /// NotificationManager's notification went away (timed out or closed), not replaced by another.
    static let appNotificationDismissed = Notification.Name("appNotificationDismissed")
}
