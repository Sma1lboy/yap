import CoreAudio
import SwiftUI

struct OnboardingMicrophoneScreen: View {
    let contentMaxWidth: CGFloat
    let onBack: () -> Void
    let onContinue: () -> Void

    @ObservedObject private var audioDeviceManager = AudioDeviceManager.shared
    @State private var selectedDeviceUID: String?
    @State private var refreshIconRotation = 0.0

    private typealias MicrophoneDevice = (id: AudioDeviceID, uid: String, name: String)

    var body: some View {
        OnboardingStepScreen(
            stage: .microphone,
            contentMaxWidth: contentMaxWidth
        ) {
            microphoneList
        } bottomBar: {
            OnboardingBottomBar(
                leadingTitle: "Back",
                primaryTitle: "Continue",
                isPrimaryEnabled: selectedDevice != nil,
                onLeading: onBack,
                onPrimary: saveSelectionAndContinue,
                isPrimaryDefaultAction: true,
                isLeadingCancelAction: true
            )
        }
        .onAppear {
            refreshMicrophones(selectingIfNeeded: true)
            initializeSelectionIfNeeded()
        }
        .onChange(of: audioDeviceManager.availableDevices.map(\.uid)) { _, _ in
            ensureSelectionIsAvailable()
        }
    }

    private var microphoneList: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.x3) {
            if devices.isEmpty {
                emptyState
            } else {
                listHeader

                ScrollView {
                    LazyVStack(spacing: AppTheme.Spacing.x3) {
                        ForEach(devices, id: \.uid) { device in
                            microphoneRow(for: device)
                        }
                    }
                }
                .frame(maxHeight: 280)
                .scrollIndicators(.automatic)
            }
        }
    }

    private var listHeader: some View {
        HStack {
            Text("Available Microphones")
                .font(AppTheme.font(.body, .semibold))
                .foregroundColor(AppTheme.Text.secondary)

            Spacer()

            refreshButton
        }
        .padding(.horizontal, AppTheme.Spacing.half)
    }

    private func microphoneRow(for device: MicrophoneDevice) -> some View {
        let isSelected = selectedDeviceUID == device.uid

        return Button {
            selectedDeviceUID = device.uid
        } label: {
            HStack(spacing: AppTheme.Spacing.x4) {
                Image(systemName: isSelected ? "checkmark" : "mic")
                    .font(AppTheme.font(.body, .semibold))
                    .foregroundColor(isSelected ? AppTheme.Text.primary : AppTheme.Text.muted)
                    .frame(width: 30, height: 30)
                    .background(
                        RoundedRectangle(cornerRadius: AppTheme.Radius.control, style: .continuous)
                            .fill(isSelected ? AppTheme.Selection.fill : AppTheme.Surface.controlActive)
                    )

                Text(device.name)
                    .font(AppTheme.font(.callout, .semibold))
                    .foregroundColor(AppTheme.Text.primary)
                    .lineLimit(1)

                Spacer(minLength: 12)
            }
            .padding(AppTheme.Spacing.x4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                AppMaterialCardBackground(
                    isSelected: isSelected,
                    cornerRadius: AppTheme.Radius.control
                )
            )
            .contentShape(RoundedRectangle(cornerRadius: AppTheme.Radius.control, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var emptyState: some View {
        VStack(spacing: AppTheme.Spacing.x4) {
            Image(systemName: "mic.slash")
                .font(AppTheme.font(.title, .semibold))
                .foregroundColor(AppTheme.Text.secondary)

            VStack(spacing: AppTheme.Spacing.x1) {
                Text("No microphones found")
                    .font(AppTheme.font(.callout, .semibold))
                    .foregroundColor(AppTheme.Text.primary)

                Text("Connect a microphone or allow microphone access, then refresh.")
                    .font(AppTheme.font(.body))
                    .foregroundColor(AppTheme.Text.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            }

            refreshButton
        }
        .padding(AppTheme.Spacing.x6)
        .frame(maxWidth: .infinity)
        .background(AppMaterialCardBackground(cornerRadius: AppTheme.Radius.control))
    }

    private var refreshButton: some View {
        Button {
            refreshMicrophones(selectingIfNeeded: false)
        } label: {
            Label {
                Text("Refresh")
                    .font(AppTheme.font(.footnote, .semibold))
            } icon: {
                Image(systemName: "arrow.clockwise")
                    .font(AppTheme.font(.footnote, .semibold))
                    .rotationEffect(.degrees(refreshIconRotation))
            }
            .foregroundColor(AppTheme.Text.secondary)
        }
        .buttonStyle(.plain)
        .help("Refresh Microphones")
    }

    private var devices: [MicrophoneDevice] {
        audioDeviceManager.availableDevices
    }

    private var selectedDevice: MicrophoneDevice? {
        guard let selectedDeviceUID else { return nil }
        return devices.first { $0.uid == selectedDeviceUID }
    }

    private func refreshMicrophones(selectingIfNeeded: Bool) {
        withAnimation(.easeInOut(duration: 0.2)) {
            refreshIconRotation += 360
        }

        audioDeviceManager.loadAvailableDevices {
            if selectingIfNeeded {
                initializeSelectionIfNeeded()
            } else {
                ensureSelectionIsAvailable()
            }
        }
    }

    private func initializeSelectionIfNeeded() {
        guard selectedDevice == nil else { return }

        if let savedDeviceID = audioDeviceManager.selectedDeviceID,
            let savedDevice = devices.first(where: { $0.id == savedDeviceID })
        {
            selectedDeviceUID = savedDevice.uid
            return
        }

        if let savedDeviceUID = UserDefaults.standard.selectedAudioDeviceUID,
            let savedDevice = devices.first(where: { $0.uid == savedDeviceUID })
        {
            selectedDeviceUID = savedDevice.uid
            return
        }

        if let defaultDeviceID = audioDeviceManager.getSystemDefaultDevice(),
            let defaultDevice = devices.first(where: { $0.id == defaultDeviceID })
        {
            selectedDeviceUID = defaultDevice.uid
            return
        }

        selectedDeviceUID = devices.first?.uid
    }

    private func ensureSelectionIsAvailable() {
        if selectedDevice == nil {
            selectedDeviceUID = nil
            initializeSelectionIfNeeded()
        }
    }

    private func saveSelectionAndContinue() {
        guard let selectedDevice else { return }
        guard audioDeviceManager.availableDevices.contains(where: { $0.uid == selectedDevice.uid }) else {
            selectedDeviceUID = nil
            refreshMicrophones(selectingIfNeeded: true)
            return
        }

        audioDeviceManager.selectDeviceAndSwitchToCustomMode(id: selectedDevice.id)

        DispatchQueue.main.async {
            onContinue()
        }
    }
}
