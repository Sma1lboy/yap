#if DEBUG
    import AppKit
    import SwiftData
    import SwiftUI

    /// `make ui-snapshots`: renders key screens to PNGs with fake data and exits, without showing a window,
    /// taking focus or touching the network. Views are hosted in a never-ordered-in offscreen window and drawn
    /// with `cacheDisplay`, because `ImageRenderer` can't draw AppKit-backed controls (Form rows, toggles,
    /// pickers, text fields).
    @MainActor
    enum UISnapshots {
        static let argument = "--render-snapshots"
        static let outputDirectory = URL(fileURLWithPath: "/tmp/yap-ui/snapshots", isDirectory: true)
        /// The main window's minimum size.
        static let size = CGSize(width: AppWindowLayout.minimumWidth, height: AppWindowLayout.minimumHeight)

        /// Call first thing at launch; returns only when the argument isn't present.
        static func runIfRequested() {
            guard CommandLine.arguments.contains(argument) else { return }
            NSApplication.shared.setActivationPolicy(.prohibited)
            YapCloud.isSnapshotMode = true
            try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

            let container = try! ModelContainer(
                for: Transcription.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
            let modelManager = TranscriptionModelManager(
                whisperModelManager: WhisperModelManager(modelsDirectory: FileManager.default.temporaryDirectory),
                fluidAudioModelManager: FluidAudioModelManager())
            CloudConfigSync.shared.store = SnapshotConfigStore()

            var written: [String] = []
            for state in YapCloud.SnapshotState.allCases {
                YapCloud.shared.applySnapshotState(state)
                written += render("account-\(state.rawValue)") {
                    AccountView().environmentObject(modelManager)
                }
            }

            YapCloud.shared.applySnapshotState(.funded)
            written += render("config-sync") {
                Form { ConfigSyncSettingsSection() }
                    .formStyle(.grouped)
                    .scrollContentBackground(.hidden)
            }
            written += render("onboarding-final") {
                OnboardingTrustScreen(contentMaxWidth: 700, onBack: {}, onContinue: {})
                    .modelContainer(container)
            }
            let practiced = try! ModelContainer(
                for: Transcription.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
            practiced.mainContext.insert(Transcription(text: "Standup moved to Friday.", duration: 3))
            written += render("onboarding-final-after-practice") {
                OnboardingTrustScreen(contentMaxWidth: 700, onBack: {}, onContinue: {})
                    .modelContainer(practiced)
            }
            written += render("home-empty") {
                HistoryView { EmptyView() }
                    .modelContainer(container)
            }
            if let notes = ReleaseNotes.current {
                written += render("whats-new", size: CGSize(width: 560, height: 620)) {
                    ReleaseNotesSheet(notes: notes)
                }
            }

            print("Wrote \(written.count) snapshots to \(outputDirectory.path)")
            exit(0)
        }

        private static func render<V: View>(
            _ name: String, size: CGSize = size, @ViewBuilder _ content: () -> V
        ) -> [String] {
            [NSAppearance.Name.aqua, .darkAqua].map { appearanceName in
                let isDark = appearanceName == .darkAqua
                let host = NSHostingView(
                    rootView: content()
                        .environment(\.colorScheme, isDark ? .dark : .light)
                        .frame(width: size.width, height: size.height)
                        .background(Color(nsColor: .windowBackgroundColor)))
                host.frame = CGRect(origin: .zero, size: size)
                let window = NSWindow(
                    contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                window.appearance = NSAppearance(named: appearanceName)
                window.contentView = host
                host.layoutSubtreeIfNeeded()
                // Forms and lists fill their rows on the next run-loop turns.
                RunLoop.main.run(until: Date().addingTimeInterval(0.5))
                host.layoutSubtreeIfNeeded()

                let url = outputDirectory.appendingPathComponent("\(name)-\(isDark ? "dark" : "light").png")
                if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                    host.cacheDisplay(in: host.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: url)
                }
                window.contentView = nil
                return url.path
            }
        }
    }

    /// A signed-in, in-memory store so Config & Sync renders its enabled state.
    private final class SnapshotConfigStore: ConfigCloudStore {
        struct Document: CloudConfigDocument {
            let version: String
            let config: Data
        }

        var isSignedIn: Bool { true }
        func fetchConfig() async throws -> Document? { nil }
        func putConfig(_ data: Data, ifMatch: String?) async throws -> String { "1" }
    }
#endif
