import Carbon.HIToolbox
import Foundation

/// The shortcuts Yap sets on a fresh install, and the diff needed to get back to them.
/// Per-mode shortcuts and the recorder panel's Esc/Return keys are not touched.
enum DefaultShortcuts {
    /// Every stored global action; a missing entry means "unset" (Cancel Recording unset = double-Esc).
    static let values: [ShortcutAction: Shortcut] = [
        .primaryRecording: .modifierOnly(keyCode: UInt16(kVK_RightOption), modifierFlags: [.option]),
        .meetingRecording: .rightCommandSpace,
    ]

    static let actions: [ShortcutAction] =
        [.primaryRecording, .secondaryRecording] + ShortcutAction.globalUtilityActions + ShortcutAction.recorderPanelStoredActions

    struct Change: Equatable {
        let action: ShortcutAction
        let from: Shortcut?
        let to: Shortcut?
    }

    /// Actions whose current shortcut differs from the default, in display order.
    static func changes(current: (ShortcutAction) -> Shortcut?) -> [Change] {
        var seen = Set<ShortcutAction>()
        return actions.compactMap { action in
            guard seen.insert(action).inserted else { return nil }
            let from = current(action), to = values[action]
            return from == to ? nil : Change(action: action, from: from, to: to)
        }
    }

    /// Clears first, then sets, so a default is never blocked by the shortcut it replaces.
    @MainActor
    static func apply(_ changes: [Change], recordingShortcutManager: RecordingShortcutManager) {
        for change in changes where change.to == nil { ShortcutStore.setShortcut(nil, for: change.action) }
        for change in changes { if let to = change.to { ShortcutStore.setShortcut(to, for: change.action) } }
        if changes.contains(where: { $0.action == .secondaryRecording }) {
            recordingShortcutManager.secondaryRecordingShortcut = .none
        }
        recordingShortcutManager.primaryRecordingShortcut = .custom
        recordingShortcutManager.updateShortcutStatus()
        RecorderPanelShortcutManager.resetEscapeConfirmationHint()
    }

    #if DEBUG
        static func selfCheck() {
            let all = actions.compactMap { values[$0] }
            for (i, a) in all.enumerated() { for b in all[(i + 1)...] { assert(!a.conflicts(with: b)) } }
            assert(changes(current: { values[$0] }).isEmpty)
            let custom = Shortcut.key(keyCode: 6, modifierFlags: [.control])
            let diff = changes(current: { $0 == .primaryRecording ? custom : $0 == .copyLastTranscription ? custom : values[$0] })
            assert(diff.map(\.action) == [.primaryRecording, .copyLastTranscription])
            assert(diff[0].to == values[.primaryRecording] && diff[1].to == nil)
            assert(!actions.contains(where: { if case .mode = $0 { true } else { false } }))
        }
    #endif
}
