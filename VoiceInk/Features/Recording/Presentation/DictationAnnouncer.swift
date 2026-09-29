import AppKit

/// Tells VoiceOver what the recorder is doing: the floating panel can't be found by VoiceOver navigation.
/// One polite (low priority) announcement per state change, and none while VoiceOver is off.
@MainActor
enum DictationAnnouncer {
    enum Announcement: Equatable {
        case recording, transcribing, enhancing, pasted

        var text: String {
            switch self {
            case .recording: return String(localized: "Recording")
            case .transcribing: return String(localized: "Transcribing")
            case .enhancing: return String(localized: "Enhancing")
            case .pasted: return String(localized: "Pasted")
            }
        }
    }

    /// What to say when the recorder goes from `previous` to `state`; nil for a repeat or a state with nothing to say.
    nonisolated static func announcement(for state: RecordingState, after previous: RecordingState) -> Announcement? {
        guard state != previous else { return nil }
        switch state {
        case .recording: return .recording
        case .transcribing: return .transcribing
        case .enhancing: return .enhancing
        case .idle, .starting, .busy: return nil
        }
    }

    static func stateChanged(from previous: RecordingState, to state: RecordingState) {
        if let announcement = announcement(for: state, after: previous) { announce(announcement.text) }
    }

    static func pasted() { announce(Announcement.pasted.text) }

    /// Failure titles too (NotificationManager calls this for errors and warnings).
    static func announce(_ text: String) {
        guard NSWorkspace.shared.isVoiceOverEnabled else { return }
        NSAccessibility.post(
            element: NSApp as Any, notification: .announcementRequested,
            userInfo: [
                .announcement: text,
                .priority: NSAccessibilityPriorityLevel.low.rawValue,
            ])
    }

    #if DEBUG
        static func selfCheck() {
            assert(announcement(for: .recording, after: .starting) == .recording)
            assert(announcement(for: .recording, after: .recording) == nil)
            assert(announcement(for: .transcribing, after: .recording) == .transcribing)
            assert(announcement(for: .enhancing, after: .transcribing) == .enhancing)
            assert(announcement(for: .idle, after: .transcribing) == nil)
            assert(announcement(for: .starting, after: .idle) == nil)
            assert(announcement(for: .busy, after: .idle) == nil)
            for a in [Announcement.recording, .transcribing, .enhancing, .pasted] { assert(!a.text.isEmpty) }
        }
    #endif
}
