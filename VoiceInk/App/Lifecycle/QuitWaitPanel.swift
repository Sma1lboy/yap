import AppKit
import SwiftUI
import os

/// While Quit waits for the local models (`VoiceInkEngine.closeLocalModels`: a decode, load, warm-up or release in
/// flight finishes before the models are freed), a small floating window says what it waits for and how long that
/// step has taken. Non-activating, so it never takes focus; shown only when the wait passes half a second, and closed
/// once, right before Yap replies to the Quit.
@MainActor
final class QuitWaitPanel {
    private var panel: NSPanel?
    private var showTask: Task<Void, Never>?

    func showAfterDelay() {
        showTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard let self, !Task.isCancelled else { return }
            Logger(subsystem: "com.prakashjoshipax.voiceink", category: "AppDelegate").notice("quit: wait panel shown")
            let panel = NSPanel.floating(width: 340, height: 100, content: QuitWaitView(activity: .shared))
            self.panel = panel
            panel.moveToTopRightOfPointerScreen()
            panel.orderFrontRegardless()
        }
    }

    func close() {
        showTask?.cancel()
        showTask = nil
        panel?.orderOut(nil)
        panel = nil
    }
}

struct QuitWaitView: View {
    @ObservedObject var activity: LocalModelActivity
    @State private var now = Date()

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.x2) {
            HStack(spacing: AppTheme.Spacing.x2) {
                ProgressView().controlSize(.small)
                Text("Quitting Yap").font(AppTheme.font(.callout, .semibold))
            }
            if let work = activity.works.first {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.half) {
                    Text(work.waitTitle).font(AppTheme.font(.body))
                    Text(work.stageLine(now: now))
                        .font(AppTheme.font(.footnote))
                        .monospacedDigit()
                        .foregroundStyle(AppTheme.Text.secondary)
                    if let note = work.stopNote {
                        Text(note)
                            .font(AppTheme.font(.footnote))
                            .foregroundStyle(AppTheme.Text.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Text("Yap quits as soon as this is done.")
                    .font(AppTheme.font(.footnote))
                    .foregroundStyle(AppTheme.Text.secondary)
            } else {
                Text("Freeing the local models")
                    .font(AppTheme.font(.footnote))
                    .foregroundStyle(AppTheme.Text.secondary)
            }
        }
        .padding(AppTheme.Spacing.x4)
        .frame(width: 340, alignment: .leading)
        .background(AppMaterialCardBackground(cornerRadius: AppTheme.Radius.card))
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { now = $0 }
    }
}
