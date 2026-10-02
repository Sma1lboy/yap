import CoreAudio
import SwiftUI

@MainActor
struct AudioSetupView: View {
    @ObservedObject private var audioDeviceManager: AudioDeviceManager
    @ObservedObject private var mediaController = MediaController.shared
    @ObservedObject private var playbackController = PlaybackController.shared
    @State private var microphoneSourceBeforePriorityOrder: MicrophoneSourceSelection = .systemDefault
    @State private var refreshIconRotation = 0.0

    #if DEBUG
        /// make ui-snapshots: a manager on fixture devices instead of this Mac's.
        @MainActor static var snapshotDeviceManager: AudioDeviceManager?
    #endif

    init() {
        #if DEBUG
            _audioDeviceManager = ObservedObject(wrappedValue: Self.snapshotDeviceManager ?? .shared)
        #else
            _audioDeviceManager = ObservedObject(wrappedValue: .shared)
        #endif
    }

    var body: some View {
        Form {
            Section {
                inputSettingsRows
            } header: {
                Text("Audio Input")
            }

            if usesPriorityOrder {
                Section {
                    priorityOrderRows
                } header: {
                    Text("Priority Order")
                }
            }

            Section {
                CustomSoundSettingsView()
            } header: {
                Text("Recording Sounds")
            }

            Section {
                Toggle("Mute Audio While Recording", isOn: $mediaController.isSystemMuteEnabled)

                Toggle("Pause Media While Recording", isOn: $playbackController.isPauseMediaEnabled)

                LabeledContent("Resume Delay") {
                    resumeDelayMenu
                        .disabled(!canEditResumeDelay)
                }
                .foregroundStyle(canEditResumeDelay ? .primary : .secondary)
            } header: {
                Text("Recording Behavior")
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .onAppear {
            if !usesPriorityOrder {
                microphoneSourceBeforePriorityOrder = currentMicrophoneSource
            }
        }
    }

    @ViewBuilder
    private var inputSettingsRows: some View {
        Picker("Microphone Mode", selection: inputRouteSelection) {
            Text("Selected Microphone").tag(InputRoute.singleMicrophone)
            Text("Priority Order").tag(InputRoute.priorityOrder)
        }
        .pickerStyle(.menu)

        if !usesPriorityOrder {
            Picker("Microphone", selection: microphoneSourceSelection) {
                Text(systemDefaultSourceTitle).tag(MicrophoneSourceSelection.systemDefault)

                ForEach(audioDeviceManager.availableDevices, id: \.uid) { device in
                    Text(device.name).tag(MicrophoneSourceSelection.device(device.uid))
                }

                // What the menu shows when no device in it is the user's choice; never offered otherwise.
                if currentMicrophoneSource == .noneAvailable {
                    (hasSavedMicrophone ? Text("Not connected") : Text("None chosen"))
                        .tag(MicrophoneSourceSelection.noneAvailable)
                }
            }
            .pickerStyle(.menu)

            if let status = unavailableMicrophoneStatus {
                Text(status)
                    .font(AppTheme.font(.caption))
                    .foregroundStyle(AppTheme.Text.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }

        Button {
            refreshMicrophones()
        } label: {
            Label {
                Text("Refresh Microphones")
            } icon: {
                Image(yapIcon: "arrow.clockwise")
                    .rotationEffect(.degrees(refreshIconRotation))
            }
        }
        .buttonStyle(.borderless)
        .help("Refresh Microphones")

        Text("If the microphone you chose isn't connected, Yap switches only to another real microphone (built-in, USB, Bluetooth…). Virtual and aggregate inputs are used only when you choose them here.")
            .font(AppTheme.font(.caption))
            .foregroundStyle(AppTheme.Text.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var priorityOrderRows: some View {
        if prioritizedDevicesInDisplayOrder.isEmpty {
            Text("Add microphones in the order Yap should try them.")
                .foregroundStyle(.secondary)
        } else {
            ForEach(prioritizedDevicesInDisplayOrder) { device in
                priorityDeviceRow(for: device)
            }
        }

        if !availableDevicesNotInPriorityOrder.isEmpty {
            ForEach(availableDevicesNotInPriorityOrder, id: \.uid) { device in
                availablePriorityDeviceRow(for: device)
            }
        }
    }

    private var inputRouteSelection: Binding<InputRoute> {
        Binding(
            get: { usesPriorityOrder ? .priorityOrder : .singleMicrophone },
            set: { route in
                switch route {
                case .singleMicrophone:
                    selectSingleMicrophoneMode()
                case .priorityOrder:
                    selectPriorityOrderMode()
                }
            }
        )
    }

    private var microphoneSourceSelection: Binding<MicrophoneSourceSelection> {
        Binding(
            get: { currentMicrophoneSource },
            set: { selection in
                microphoneSourceBeforePriorityOrder = selection
                selectMicrophoneSource(selection)
            }
        )
    }

    private func availablePriorityDeviceRow(for device: (id: AudioDeviceID, uid: String, name: String)) -> some View {
        Button {
            audioDeviceManager.addPrioritizedDevice(uid: device.uid, name: device.name)
        } label: {
            HStack(spacing: AppTheme.Spacing.x2) {
                Label(device.name, yapIcon: "plus.circle")
                    .lineLimit(1)

                Spacer()

                Text("Add")
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func priorityDeviceRow(for prioritizedDevice: PrioritizedDevice) -> some View {
        let device = audioDeviceManager.availableDevices.first { $0.uid == prioritizedDevice.id }
        let isAvailable = device != nil
        let isActive = device.map { audioDeviceManager.getCurrentDevice() == $0.id } ?? false

        return HStack(spacing: AppTheme.Spacing.x2) {
            Text("\(prioritizedDevice.priority + 1)")
                .font(AppTheme.font(.body).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 22, alignment: .leading)

            VStack(alignment: .leading, spacing: AppTheme.Spacing.half) {
                Text(prioritizedDevice.name)
                    .foregroundStyle(isAvailable ? .primary : .secondary)
                    .lineLimit(1)

                if !isAvailable {
                    Text("Unavailable")
                        .font(AppTheme.font(.caption))
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if isActive {
                Label("Active", yapIcon: "checkmark.circle.fill")
                    .font(AppTheme.font(.caption))
                    .foregroundStyle(.secondary)
                    .labelStyle(.titleAndIcon)
            }

            HStack(spacing: AppTheme.Spacing.x1) {
                Button {
                    movePrioritizedDeviceUp(prioritizedDevice)
                } label: {
                    Image(yapIcon: "chevron.up")
                }
                .disabled(prioritizedDevice.id == prioritizedDevicesInDisplayOrder.first?.id)
                .help("Move up")

                Button {
                    movePrioritizedDeviceDown(prioritizedDevice)
                } label: {
                    Image(yapIcon: "chevron.down")
                }
                .disabled(prioritizedDevice.id == prioritizedDevicesInDisplayOrder.last?.id)
                .help("Move down")
                .accessibilityLabel("Move down")

                Button {
                    audioDeviceManager.removePrioritizedDevice(id: prioritizedDevice.id)
                } label: {
                    Image(yapIcon: "minus.circle")
                }
                .help("Remove")
                .accessibilityLabel("Remove")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
        }
    }

    /// The menu shows the user's choice, never a device Yap fell back to on its own (`noneAvailable` then, with what a
    /// recording uses written under it).
    private var currentMicrophoneSource: MicrophoneSourceSelection {
        switch audioDeviceManager.inputMode {
        case .systemDefault:
            return .systemDefault
        case .custom:
            return audioDeviceManager.chosenCustomDeviceUID.map { .device($0) } ?? .noneAvailable
        case .prioritized:
            return microphoneSourceBeforePriorityOrder
        }
    }

    private var hasSavedMicrophone: Bool {
        UserDefaults.standard.selectedAudioDeviceUID != nil
    }

    /// Under the menu when it shows Not connected / None chosen: what a recording uses instead, or why nothing.
    private var unavailableMicrophoneStatus: String? {
        guard currentMicrophoneSource == .noneAvailable else { return nil }
        let resolution = audioDeviceManager.resolveCurrentRecordingDevice()
        if let deviceID = resolution.deviceID,
            let name = audioDeviceManager.availableDevices.first(where: { $0.id == deviceID })?.name
        {
            if hasSavedMicrophone {
                return String(format: String(localized: "Your microphone isn't connected. Recording uses %@ until it's back."), name)
            }
            return String(format: String(localized: "Recording uses %@ until you choose a microphone."), name)
        }
        if resolution.internalMicrophoneBlockedByClosedLid {
            return String(localized: "No usable microphone is available. Open the lid or connect an external microphone.")
        }
        if resolution.onlyUnchosenInputsLeft {
            return String(localized: "No real microphone is connected, and Yap doesn't switch to a virtual or aggregate input on its own. Choose one above to record from it.")
        }
        return String(localized: "No microphone is connected.")
    }

    private func selectMicrophoneSource(_ selection: MicrophoneSourceSelection) {
        switch selection {
        case .systemDefault:
            audioDeviceManager.selectInputMode(.systemDefault)
        case .device(let uid):
            // Gone while the menu was open: nothing else is chosen in its place (the system default could be a
            // virtual input); the menu is refreshed instead.
            guard let device = audioDeviceManager.availableDevices.first(where: { $0.uid == uid }) else {
                audioDeviceManager.loadAvailableDevices()
                return
            }
            audioDeviceManager.selectDeviceAndSwitchToCustomMode(id: device.id)
        case .noneAvailable:
            // Back from Priority Order to a choice that isn't connected: the saved device stays the choice.
            audioDeviceManager.selectInputMode(.custom)
        }
    }

    private func selectSingleMicrophoneMode() {
        selectMicrophoneSource(microphoneSourceBeforePriorityOrder)
    }

    private func selectPriorityOrderMode() {
        if !usesPriorityOrder {
            microphoneSourceBeforePriorityOrder = currentMicrophoneSource
        }
        audioDeviceManager.selectInputMode(.prioritized)
    }

    private var systemDefaultSourceTitle: String {
        guard let name = audioDeviceManager.getSystemDefaultDeviceName() else {
            return String(localized: "System Default")
        }
        return String(format: String(localized: "System Default (%@)"), name)
    }

    private func refreshMicrophones() {
        withAnimation(.easeInOut(duration: 0.35)) {
            refreshIconRotation += 360
        }
        audioDeviceManager.loadAvailableDevices()
    }

    private var usesPriorityOrder: Bool {
        audioDeviceManager.inputMode == .prioritized
    }

    private var prioritizedDevicesInDisplayOrder: [PrioritizedDevice] {
        audioDeviceManager.prioritizedDevices.sorted { $0.priority < $1.priority }
    }

    private var availableDevicesNotInPriorityOrder: [(id: AudioDeviceID, uid: String, name: String)] {
        audioDeviceManager.availableDevices.filter { device in
            !audioDeviceManager.prioritizedDevices.contains { $0.id == device.uid }
        }
    }

    private var resumeDelayMenu: some View {
        Picker("Resume Delay", selection: $mediaController.audioResumptionDelay) {
            Text("0s").tag(0.0)
            Text("1s").tag(1.0)
            Text("2s").tag(2.0)
            Text("3s").tag(3.0)
            Text("4s").tag(4.0)
            Text("5s").tag(5.0)
        }
        .pickerStyle(.menu)
        .labelsHidden()
    }

    private var canEditResumeDelay: Bool {
        mediaController.isSystemMuteEnabled || playbackController.isPauseMediaEnabled
    }

    private func movePrioritizedDeviceUp(_ device: PrioritizedDevice) {
        var devices = prioritizedDevicesInDisplayOrder
        guard let currentIndex = devices.firstIndex(where: { $0.id == device.id }),
            currentIndex > 0
        else { return }

        devices.swapAt(currentIndex, currentIndex - 1)
        updatePriorities(devices)
    }

    private func movePrioritizedDeviceDown(_ device: PrioritizedDevice) {
        var devices = prioritizedDevicesInDisplayOrder
        guard let currentIndex = devices.firstIndex(where: { $0.id == device.id }),
            currentIndex < devices.count - 1
        else { return }

        devices.swapAt(currentIndex, currentIndex + 1)
        updatePriorities(devices)
    }

    private func updatePriorities(_ devices: [PrioritizedDevice]) {
        let updatedDevices = devices.enumerated().map { index, device in
            PrioritizedDevice(id: device.id, name: device.name, priority: index, modelUID: device.modelUID)
        }
        audioDeviceManager.updatePriorities(devices: updatedDevices)
    }
}

private enum MicrophoneSourceSelection: Hashable {
    case systemDefault
    case device(String)
    /// Selected Microphone with the chosen one not connected, or none chosen yet.
    case noneAvailable
}

private enum InputRoute: Hashable {
    case singleMicrophone
    case priorityOrder
}
