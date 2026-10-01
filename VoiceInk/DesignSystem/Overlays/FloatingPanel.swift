import AppKit
import SwiftUI

extension NSPanel {
    /// A floating window that never takes focus (the meeting panel, the Quit wait): borderless, on every Space,
    /// sized by its SwiftUI content.
    static func floating(width: CGFloat, height: CGFloat, content: some View) -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.nonactivatingPanel, .fullSizeContentView, .borderless], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.becomesKeyOnlyIfNeeded = true
        let host = NSHostingView(rootView: content)
        host.sizingOptions = [.preferredContentSize]
        panel.contentView = host
        return panel
    }

    /// The top-right corner of the screen with the pointer.
    func moveToTopRightOfPointerScreen() {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main else { return }
        let frame = screen.visibleFrame
        setFrameTopLeftPoint(NSPoint(x: frame.maxX - self.frame.width - 16, y: frame.maxY - 16))
    }
}
