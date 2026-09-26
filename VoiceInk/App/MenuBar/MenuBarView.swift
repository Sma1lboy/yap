import SwiftUI

struct MenuBarView: View {
    @Environment(\.openWindow) private var openWindow
    @EnvironmentObject var engine: VoiceInkEngine
    @EnvironmentObject var recorderUIManager: RecorderUIManager
    @EnvironmentObject var transcriptionModelManager: TranscriptionModelManager
    @EnvironmentObject var whisperModelManager: WhisperModelManager
    @EnvironmentObject var recordingShortcutManager: RecordingShortcutManager
    @EnvironmentObject var menuBarManager: MenuBarManager
    @EnvironmentObject var mainWindowNavigation: MainWindowNavigation
    @EnvironmentObject var updaterViewModel: UpdaterViewModel
    @EnvironmentObject var enhancementService: AIEnhancementService
    @EnvironmentObject var aiService: AIService
    @ObservedObject private var modeManager = ModeManager.shared
    @ObservedObject var audioDeviceManager = AudioDeviceManager.shared
    @ObservedObject private var yapCloud = YapCloud.shared
    @AppStorage(OnboardingSettings.completedV2Key) private var hasCompletedOnboardingV2 = false

    var body: some View {
        VStack {
            if hasCompletedOnboardingV2 {
                completedOnboardingMenu
            } else {
                onboardingMenu
            }
        }
    }

    private var onboardingMenu: some View {
        Group {
            Button("Finish Setting Up Yap…") {
                showMainWindow()
            }

            Divider()

            Button("Quit Yap") {
                NSApplication.shared.terminate(nil)
            }
        }
    }

    private var completedOnboardingMenu: some View {
        Group {
            Button("Open Yap") {
                showMainWindow()
            }

            Button("Start/Stop Dictation") {
                recorderUIManager.handleToggleRecorderPanelNotification()
            }

            Divider()

            if yapCloud.isSignedIn, let balance = yapCloud.balanceMicros {
                if yapCloud.isLowBalance {
                    Button {
                        showMainWindowAndNavigate(to: "Account")
                    } label: {
                        Label(
                            String(format: String(localized: "Low balance (%@) — Add Funds"), YapCloud.formatUSD(micros: balance)),
                            systemImage: "exclamationmark.triangle.fill")
                    }
                } else {
                    Button(String(format: String(localized: "Yap Cloud balance: %@"), YapCloud.formatUSD(micros: balance))) {
                        showMainWindowAndNavigate(to: "Account")
                    }
                }

                Divider()
            }

            Menu {
                ForEach(modeManager.enabledConfigurations) { config in
                    Toggle(
                        config.name,
                        isOn: Binding(
                            get: { modeManager.currentEffectiveConfiguration?.id == config.id },
                            set: { _ in modeManager.setActiveConfiguration(config) }
                        )
                    )
                }

                if modeManager.enabledConfigurations.isEmpty {
                    Text("No modes available")
                        .foregroundColor(.secondary)
                }

                Divider()

                Button("Manage Modes") {
                    showMainWindowAndNavigate(to: "Modes")
                }

                Button("Manage Models") {
                    showMainWindowAndNavigate(to: "AI Models")
                }
            } label: {
                HStack {
                    Image(systemName: "sparkles.square.fill.on.square")
                        .font(AppTheme.font(.caption, .medium))
                    let activeMode = modeManager.currentEffectiveConfiguration
                    Text(String(format: String(localized: "Mode: %@"), activeMode?.name ?? String(localized: "None")))
                    Image(systemName: "chevron.up.chevron.down")
                        .font(AppTheme.font(.micro))
                }
            }

            Menu {
                ForEach(audioDeviceManager.availableDevices, id: \.id) { device in
                    Toggle(
                        device.name,
                        isOn: Binding(
                            get: { audioDeviceManager.getCurrentDevice() == device.id },
                            set: { _ in audioDeviceManager.selectDeviceAndSwitchToCustomMode(id: device.id) }
                        )
                    )
                }

                if audioDeviceManager.availableDevices.isEmpty {
                    Text("No devices available")
                        .foregroundColor(.secondary)
                }
            } label: {
                HStack {
                    Image(systemName: "mic.fill")
                        .font(AppTheme.font(.caption, .medium))
                    Text("Audio Input")
                    Image(systemName: "chevron.up.chevron.down")
                        .font(AppTheme.font(.micro))
                }
            }

            Divider()

            Button("Retry Last Transcription") {
                LastTranscriptionService.retryLastTranscription(
                    from: engine.modelContext,
                    transcriptionModelManager: transcriptionModelManager,
                    serviceRegistry: engine.serviceRegistry,
                    enhancementService: enhancementService
                )
            }

            Button("Copy Last Transcription") {
                LastTranscriptionService.copyLastTranscription(from: engine.modelContext)
            }
            .keyboardShortcut("c", modifiers: [.command, .shift])

            Button("Quick History") {
                menuBarManager.openQuickHistory()
            }
            .keyboardShortcut("h", modifiers: [.command, .shift])

            Button(menuBarManager.isMenuBarOnly ? "Show Dock Icon" : "Hide Dock Icon") {
                let shouldShowMainWindow = menuBarManager.isMenuBarOnly
                menuBarManager.toggleMenuBarOnly()

                if shouldShowMainWindow {
                    showMainWindow()
                }
            }
            .keyboardShortcut("d", modifiers: [.command, .shift])

            Divider()

            Button("Settings…") {
                showMainWindowAndNavigate(to: "Settings")
            }
            .keyboardShortcut(",", modifiers: .command)

            Button("Check for Updates…") {
                updaterViewModel.checkForUpdates()
            }
            .disabled(!updaterViewModel.canCheckForUpdates)

            Button("Quit Yap") {
                NSApplication.shared.terminate(nil)
            }
        }
    }

    private func showMainWindow() {
        let existingWindow = WindowManager.shared.currentMainWindow()
        menuBarManager.activateForPresentedWindow()

        if existingWindow == nil {
            WindowManager.shared.prepareForUserRequestedMainWindow()
            openWindow(id: AppWindowID.main)
        } else {
            openWindow(id: AppWindowID.main)
            WindowManager.shared.showMainWindow()
        }
    }

    private func showMainWindowAndNavigate(to destination: String) {
        mainWindowNavigation.navigate(to: destination)
        showMainWindow()
    }
}
