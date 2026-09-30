import AppKit
import SwiftUI

/// Opens the Scratchpad window: floating, remembers its position and size, and stays open when you click elsewhere
/// (unlike Quick History), so you can dictate into it from anywhere.
@MainActor
final class ScratchpadController: NSObject, NSWindowDelegate {
    static let shared = ScratchpadController()

    private final class Panel: NSPanel {
        override var canBecomeKey: Bool { true }
    }

    private var panel: NSPanel?

    func show() {
        if panel == nil { panel = makePanel() }
        NSApp.activate(ignoringOtherApps: true)
        panel?.makeKeyAndOrderFront(nil)
    }

    /// The shortcut: open, or close if it is already the front window.
    func toggle() {
        if let panel, panel.isVisible, panel.isKeyWindow {
            panel.close()
        } else {
            show()
        }
    }

    func windowWillClose(_ notification: Notification) {
        ScratchpadStore.shared.save()
    }

    private func makePanel() -> NSPanel {
        let panel = Panel(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 320),
            styleMask: [.titled, .closable, .resizable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.title = String(localized: "Scratchpad")
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.contentMinSize = NSSize(width: 280, height: 200)
        panel.delegate = self
        panel.contentViewController = NSHostingController(rootView: ScratchpadView(store: .shared))
        if !panel.setFrameUsingName("YapScratchpad") { panel.center() }
        panel.setFrameAutosaveName("YapScratchpad")
        return panel
    }
}
