import AppKit
import SwiftUI

/// A transparent strip that moves the window, for the top edge of a page now that there is no title bar.
/// Double-click does what the system does for a title bar (System Settings > Desktop & Dock: zoom, minimize, or
/// nothing).
struct WindowDragStrip: View {
    var body: some View {
        Color.clear
            .contentShape(Rectangle())
            .gesture(WindowDragGesture())
            .simultaneousGesture(TapGesture(count: 2).onEnded(Self.titleBarDoubleClick))
            .accessibilityHidden(true)
    }

    private static func titleBarDoubleClick() {
        guard let window = NSApp.keyWindow else { return }
        switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") {
        case "Minimize": window.miniaturize(nil)
        case "None": break
        default: window.zoom(nil)
        }
    }
}

extension View {
    /// Lets the top `height` points of this view drag the window, above whatever the view draws there.
    func windowDragArea(height: CGFloat) -> some View {
        overlay(alignment: .top) {
            WindowDragStrip().frame(height: height)
        }
    }
}
