import Foundation

enum ShortcutAction: Hashable {
    case primaryRecording
    case secondaryRecording
    case pasteLastTranscription
    case pasteLastEnhancement
    /// Copies the last result (enhanced if present) to the clipboard without pasting.
    case copyLastTranscription
    case retryLastTranscription
    case cancelRecorder
    case openQuickHistory
    /// Opens or closes the floating Scratchpad. Unset by default.
    case openScratchpad
    case quickAddToDictionary
    /// Starts a meeting recording (MeetingRecorder); only ✓ in the meeting panel stops it. Default: right ⌘ + Space.
    case meetingRecording
    /// Removes the last paste (LastPasteEditor).
    case undoLastPaste
    /// Press, speak an instruction, press again: the last paste is rewritten in place (LastPasteEditor).
    case rewriteLastPaste
    case mode(UUID)
    case recorderPanelEscape
    case recorderPanelReturn
    case recorderPanelMode(Int)

    var userDefaultsKey: String {
        "Shortcut_\(storageName)"
    }

    var isStored: Bool {
        switch self {
        case .recorderPanelEscape, .recorderPanelReturn, .recorderPanelMode:
            return false
        default:
            return true
        }
    }

    var storageName: String {
        switch self {
        case .primaryRecording:
            return "primaryRecording"
        case .secondaryRecording:
            return "secondaryRecording"
        case .pasteLastTranscription:
            return "pasteLastTranscription"
        case .pasteLastEnhancement:
            return "pasteLastEnhancement"
        case .copyLastTranscription:
            return "copyLastTranscription"
        case .retryLastTranscription:
            return "retryLastTranscription"
        case .cancelRecorder:
            return "cancelRecorder"
        case .openQuickHistory:
            return "openHistoryWindow"
        case .openScratchpad:
            return "openScratchpad"
        case .quickAddToDictionary:
            return "quickAddToDictionary"
        case .meetingRecording:
            return "meetingRecording"
        case .undoLastPaste:
            return "undoLastPaste"
        case .rewriteLastPaste:
            return "rewriteLastPaste"
        case .mode(let id):
            return "mode_\(id.uuidString)"
        case .recorderPanelEscape:
            return "recorderPanelEscape"
        case .recorderPanelReturn:
            return "recorderPanelReturn"
        case .recorderPanelMode(let index):
            return "recorderPanelMode_\(index)"
        }
    }

    var displayName: String {
        switch self {
        case .primaryRecording:
            return String(localized: "Primary Shortcut")
        case .secondaryRecording:
            return String(localized: "Secondary Shortcut")
        case .pasteLastTranscription:
            return String(localized: "Paste Last Transcription")
        case .pasteLastEnhancement:
            return String(localized: "Paste Last Enhanced Transcription")
        case .copyLastTranscription:
            return String(localized: "Copy Last Transcription")
        case .retryLastTranscription:
            return String(localized: "Retry Last Transcription")
        case .cancelRecorder:
            return String(localized: "Cancel Recording")
        case .openQuickHistory:
            return String(localized: "Open Quick History")
        case .openScratchpad:
            return String(localized: "Open Scratchpad")
        case .quickAddToDictionary:
            return String(localized: "Quick Add to Dictionary")
        case .meetingRecording:
            return String(localized: "Record Meeting")
        case .undoLastPaste:
            return String(localized: "Undo Last Paste")
        case .rewriteLastPaste:
            return String(localized: "Rewrite Last Dictation")
        case .mode(let id):
            if let config = ModeManager.shared.getConfiguration(with: id) {
                return String(format: String(localized: "%@ Mode"), config.name)
            }

            if let template = StarterModeCatalog.templates.first(where: { $0.id == id }) {
                return String(format: String(localized: "%@ Mode"), template.name)
            }

            return String(localized: "Mode")
        case .recorderPanelEscape:
            return String(localized: "Recorder Cancel")
        case .recorderPanelReturn:
            return String(localized: "Auto Send")
        case .recorderPanelMode(let index):
            return String(format: String(localized: "Select Mode %@"), Self.displayNumber(forRecorderPanelIndex: index))
        }
    }

    static let globalUtilityActions: [Self] = [
        .pasteLastTranscription,
        .pasteLastEnhancement,
        .copyLastTranscription,
        .retryLastTranscription,
        .openQuickHistory,
        .openScratchpad,
        .quickAddToDictionary,
        .undoLastPaste,
        .rewriteLastPaste,
        .meetingRecording,
    ]

    static let recorderPanelStoredActions: [Self] = [
        .cancelRecorder
    ]

    static let legacyKeyboardShortcutActions: [Self] = [
        .primaryRecording,
        .secondaryRecording,
        .pasteLastTranscription,
        .pasteLastEnhancement,
        .retryLastTranscription,
        .cancelRecorder,
        .openQuickHistory,
        .quickAddToDictionary,
    ]

    private static func displayNumber(forRecorderPanelIndex index: Int) -> String {
        index == 9 ? "10" : "\(index + 1)"
    }
}
