import AppKit
import SwiftUI

@MainActor
final class NotificationManager {
    static let shared = NotificationManager()

    private var notificationWindow: NSPanel?
    private var dismissTimer: Timer?
    private var notificationID: UUID?

    private init() {}

    /// A notification is on screen. Prompts that mustn't replace one (MeetingCallDetector) wait for
    /// `.appNotificationDismissed` instead.
    var isShowingNotification: Bool { notificationWindow != nil }

    func showNotification(
        title: String,
        type: AppNotificationView.NotificationType,
        duration: TimeInterval = 3.0,
        onTap: (() -> Void)? = nil,
        actionButton: (label: String, action: () -> Void)? = nil,
        secondaryButton: (label: String, action: () -> Void)? = nil
    ) {
        dismissTimer?.invalidate()
        dismissTimer = nil
        let notificationID = UUID()
        self.notificationID = notificationID

        if let existingWindow = notificationWindow {
            existingWindow.close()
            notificationWindow = nil
        }

        // Play esc sound for error notifications
        if type == .error {
            SoundManager.shared.playEscSound()
        }
        if type == .error || type == .warning {
            DictationAnnouncer.announce(title)
        }

        let notificationView = AppNotificationView(
            title: title,
            type: type,
            duration: duration,
            onClose: { [weak self] in
                Task { @MainActor in
                    self?.dismissNotification(ifCurrent: notificationID)
                }
            },
            onTap: onTap,
            actionButton: actionButton,
            secondaryButton: secondaryButton
        )
        let hostingController = NSHostingController(rootView: notificationView)
        let size = Self.size(of: hostingController)

        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        panel.contentView = hostingController.view
        panel.isFloatingPanel = true
        panel.level = NSWindow.Level.mainMenu
        panel.backgroundColor = NSColor.clear
        panel.hasShadow = false
        panel.isMovableByWindowBackground = false

        positionWindow(panel)
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil as Any?)

        self.notificationWindow = panel

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.3
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        })

        // Schedule a new timer to dismiss the new notification.
        dismissTimer = Timer.scheduledTimer(
            withTimeInterval: duration,
            repeats: false
        ) { [weak self] _ in
            Task { @MainActor in
                self?.dismissNotification(ifCurrent: notificationID)
            }
        }
    }

    /// The notification's size: as wide as its message on one line, and when that reaches the widest a
    /// notification gets, as tall as the message wrapped at that width (three lines at most), so a long message
    /// (a meeting that couldn't be saved, and why) isn't cut off after one line.
    static func size(of controller: NSHostingController<AppNotificationView>) -> CGSize {
        let oneLine = controller.view.fittingSize
        guard oneLine.width >= AppNotificationView.maxWidth else { return oneLine }
        return controller.sizeThatFits(in: CGSize(width: AppNotificationView.maxWidth, height: .greatestFiniteMagnitude))
    }

    private func positionWindow(_ window: NSWindow) {
        let activeScreen = NSApp.keyWindow?.screen ?? NSScreen.main ?? NSScreen.screens[0]
        let screenRect = activeScreen.visibleFrame
        let notificationRect = window.frame

        // Position notification centered horizontally on screen
        let notificationX = screenRect.midX - (notificationRect.width / 2)

        // Position notification near bottom of screen with appropriate spacing
        let bottomPadding: CGFloat = 24
        let componentHeight: CGFloat = 34
        let notificationSpacing: CGFloat = 16
        let notificationY = screenRect.minY + bottomPadding + componentHeight + notificationSpacing

        window.setFrameOrigin(NSPoint(x: notificationX, y: notificationY))
    }

    func dismissNotification() {
        guard let window = notificationWindow else { return }

        notificationWindow = nil
        notificationID = nil

        dismissTimer?.invalidate()
        dismissTimer = nil

        NSAnimationContext.runAnimationGroup(
            { context in
                context.duration = 0.2
                context.timingFunction = CAMediaTimingFunction(name: .easeIn)
                window.animator().alphaValue = 0
            },
            completionHandler: {
                window.close()
            })
        NotificationCenter.default.post(name: .appNotificationDismissed, object: nil)
    }

    private func dismissNotification(ifCurrent notificationID: UUID) {
        guard self.notificationID == notificationID else { return }
        dismissNotification()
    }
}
