import AppIntents
import AppKit
import Foundation

struct ToggleMiniRecorderIntent: AppIntent {
    static var title: LocalizedStringResource = "Toggle Yap Recorder"
    static var description = IntentDescription("Start or stop the Yap recorder for voice transcription.")

    static var openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        NotificationCenter.default.post(name: .toggleRecorderPanel, object: nil)

        let dialog: IntentDialog = "Yap recorder toggled"
        return .result(dialog: dialog)
    }
}

enum IntentError: Error, LocalizedError {
    case appNotAvailable
    case serviceNotAvailable

    var errorDescription: String? {
        switch self {
        case .appNotAvailable:
            return String(localized: "Yap app is not available")
        case .serviceNotAvailable:
            return String(localized: "Yap recording service is not available")
        }
    }
}
