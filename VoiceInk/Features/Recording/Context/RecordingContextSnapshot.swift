import AppKit
import Foundation

struct RecordingContextSnapshot {
    var capturedAt = Date()
    var selectedText: String?
    var clipboardText: String?
    var screenText: String?
    var cursorContext: CursorContext?
    var appName: String?
    var appBundleID: String?
}

extension Transcription {
    func setSourceApp(from snapshot: RecordingContextSnapshot?) {
        sourceAppName = snapshot?.appName
        sourceAppBundleID = snapshot?.appBundleID
    }
}

@MainActor
final class RecordingContextSnapshotStore {
    private(set) var snapshot = RecordingContextSnapshot()

    func updateSelectedText(_ text: String?) {
        snapshot.selectedText = Self.normalized(text)
    }

    func updateClipboardText(_ text: String?) {
        snapshot.clipboardText = Self.normalized(text)
    }

    func updateScreenText(_ text: String?) {
        snapshot.screenText = Self.normalized(text)
    }

    func updateFrontmostApp(_ app: NSRunningApplication?) {
        snapshot.appName = app?.localizedName
        snapshot.appBundleID = app?.bundleIdentifier
    }

    func updateCursorContext(_ context: CursorContext?) {
        snapshot.cursorContext = context
    }

    private static func normalized(_ text: String?) -> String? {
        guard let text else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

@MainActor
enum RecordingContextCaptureService {
    static func startCapture(into store: RecordingContextSnapshotStore) -> [Task<Void, Never>] {
        store.updateFrontmostApp(NSWorkspace.shared.frontmostApplication)
        return [
            Task { @MainActor in
                store.updateClipboardText(NSPasteboard.general.string(forType: .string))
            },
            Task { @MainActor in
                guard !Task.isCancelled else { return }
                let selectedText = await SelectedTextService.fetchSelectedText()
                guard !Task.isCancelled else { return }
                store.updateSelectedText(selectedText)
            },
            Task { @MainActor in
                // Read when recording starts, before anything is pasted; the mode decides later whether it's used.
                let app = NSWorkspace.shared.frontmostApplication
                let context = await Task.detached { CursorContextReader.read(app: app) }.value
                guard !Task.isCancelled else { return }
                store.updateCursorContext(context)
            },
            Task { @MainActor in
                guard CGPreflightScreenCaptureAccess(), !Task.isCancelled else { return }
                let screenCaptureService = ScreenCaptureService()
                let screenText = await screenCaptureService.captureAndExtractText()
                guard !Task.isCancelled else { return }
                store.updateScreenText(screenText)
            },
        ]
    }
}

#if DEBUG
    extension RecordingContextSnapshot {
        static func selfCheck() {
            var snapshot = RecordingContextSnapshot()
            snapshot.appName = "Notes"
            snapshot.appBundleID = "com.apple.Notes"
            let saved = Transcription(text: "hi", duration: 1)
            saved.setSourceApp(from: snapshot)
            assert(saved.sourceAppName == "Notes" && saved.sourceAppBundleID == "com.apple.Notes")

            let unknown = Transcription(text: "hi", duration: 1)
            unknown.setSourceApp(from: nil)
            assert(unknown.sourceAppName == nil && unknown.sourceAppBundleID == nil)
        }
    }
#endif
