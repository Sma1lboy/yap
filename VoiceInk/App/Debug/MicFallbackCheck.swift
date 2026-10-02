#if DEBUG
    import CoreAudio
    import Foundation
    import IOKit.audio

    /// `scripts/mic-fallback-check.sh`: `--mic-fallback-check matrix|smoke`, then quits.
    /// - `matrix`: each case is a device list (with transport types, a lid, a system default) handed to
    ///   `AudioDeviceManager(fixture:)` with the saved input mode and devices set in UserDefaults first; the app's own
    ///   selection, fallback and recording-change code then runs on it. Prints what was selected, what a recording
    ///   would use, what stays saved, and the request a recording gets when its device goes away.
    /// - `smoke`: this Mac's real input devices, read only: each device's transport and how the selector treats it,
    ///   then what the app would record from with the saved setting and with a saved device that isn't there. The
    ///   system default device isn't changed and nothing is recorded.
    /// Lines start with `mic-check: `.
    @MainActor
    enum MicFallbackCheck {
        static let argument = "--mic-fallback-check"

        typealias Device = AudioDeviceManager.FixtureHardware.Device
        static let builtIn = Device(
            id: 10, uid: "BuiltInMicrophoneDevice", name: "MacBook Pro Microphone", transport: kAudioDeviceTransportTypeBuiltIn,
            dataSource: UInt32(kIOAudioSelectorControlSelectionValueInternalMicrophone))
        static let usb = Device(id: 20, uid: "usb-mic", name: "USB Microphone", transport: kAudioDeviceTransportTypeUSB, modelUID: "M-USB")
        static let virtual = Device(id: 30, uid: "BlackHole2ch_UID", name: "BlackHole 2ch", transport: kAudioDeviceTransportTypeVirtual)
        static let aggregate = Device(id: 40, uid: "yap-tap-aggregate", name: "Yap system audio", transport: kAudioDeviceTransportTypeAggregate)
        static let unknown = Device(id: 50, uid: "mystery", name: "Unknown Input", transport: nil)
        static let airPods = Device(id: 60, uid: "airpods", name: "AirPods", transport: kAudioDeviceTransportTypeBluetooth)

        static func runIfRequested() {
            let arguments = CommandLine.arguments
            guard let index = arguments.firstIndex(of: argument), arguments.indices.contains(index + 1) else { return }
            switch arguments[index + 1] {
            case "matrix": matrix()
            case "smoke": smoke()
            default: print("mic-check: unknown step")
            }
            fflush(stdout)
            exit(0)
        }

        /// Saved preferences, as the app keeps them: mode, the custom device (UID and model UID), the priority list.
        private static func save(mode: AudioInputMode, custom: (uid: String, model: String?)? = nil, prioritized: [String] = []) {
            let defaults = UserDefaults.standard
            defaults.audioInputModeRawValue = mode.rawValue
            defaults.selectedAudioDeviceUID = custom?.uid
            defaults.selectedAudioDeviceModelUID = custom?.model
            defaults.prioritizedDevicesData = try? JSONEncoder().encode(prioritized.enumerated().map {
                PrioritizedDevice(id: $0.element, name: $0.element, priority: $0.offset)
            })
        }

        /// Lets the manager's `DispatchQueue.main.async` work run.
        private static func settle() {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }

        private static func name(_ id: AudioDeviceID?, in manager: AudioDeviceManager) -> String {
            guard let id, id != 0 else { return "none" }
            return manager.availableDevices.first { $0.id == id }?.name ?? "gone(\(id))"
        }

        private static func report(_ label: String, _ manager: AudioDeviceManager) {
            let resolution = manager.resolveCurrentRecordingDevice()
            let saved = UserDefaults.standard.selectedAudioDeviceUID ?? "none"
            let message = resolution.deviceID == nil
                ? " | message " + AudioInputFailurePresentation.noUsableMicrophone(
                    internalMicrophoneBlockedByClosedLid: resolution.internalMicrophoneBlockedByClosedLid,
                    onlyUnchosenInputsLeft: resolution.onlyUnchosenInputsLeft).title
                : ""
            print("mic-check: \(label) selected \(name(manager.selectedDeviceID, in: manager)) | records \(name(resolution.deviceID, in: manager)) | lid-blocked \(resolution.internalMicrophoneBlockedByClosedLid) | unchosen-left \(resolution.onlyUnchosenInputsLeft) | saved \(saved) | prioritized \(manager.prioritizedDevices.map(\.id).joined(separator: ","))\(message)")
        }

        private static func start(_ label: String, _ devices: [Device], default defaultInput: AudioDeviceID? = nil, lid: Bool = false) -> AudioDeviceManager {
            let manager = AudioDeviceManager(fixture: .init(devices: devices, defaultInput: defaultInput, lidClosed: lid))
            settle()
            report(label, manager)
            return manager
        }

        private static func change(_ label: String, _ manager: AudioDeviceManager, _ devices: [Device], lid: Bool = false) {
            manager.fixtureHardwareChanged(.init(devices: devices, defaultInput: manager.fixture?.defaultInput, lidClosed: lid))
            settle()
            report(label, manager)
        }

        /// A recording on `active` when the hardware changes to `devices`: the request the recorder gets.
        private static func loseDuringRecording(_ label: String, _ manager: AudioDeviceManager, active: AudioDeviceID, _ devices: [Device]) {
            manager.recordingDidStart(deviceID: active)
            var request: RecordingDeviceChangeRequest?
            let observer = NotificationCenter.default.addObserver(forName: .recordingDeviceChangeRequired, object: nil, queue: nil) {
                request = $0.object as? RecordingDeviceChangeRequest
            }
            manager.fixtureHardwareChanged(.init(devices: devices, defaultInput: nil, lidClosed: false))
            settle()
            NotificationCenter.default.removeObserver(observer)
            print("mic-check: \(label) request \(request == nil ? "none" : "sent") | switch to \(name(request?.fallbackDeviceID, in: manager)) | unchosen-left \(request?.onlyUnchosenInputsLeft ?? false) | saved \(UserDefaults.standard.selectedAudioDeviceUID ?? "none")")
            manager.recordingDidStop()
        }

        private static func matrix() {
            // The lid is closed (the internal microphone can't be used); a USB microphone and BlackHole are there,
            // BlackHole first in Core Audio's list; the saved custom device isn't plugged in.
            save(mode: .custom, custom: ("missing-mic", nil))
            _ = start("lid-closed-usb-and-virtual", [virtual, builtIn, usb], lid: true)

            // The saved device is gone and only a virtual and an aggregate input are left.
            save(mode: .custom, custom: ("missing-mic", nil))
            _ = start("only-virtual-left", [virtual, aggregate])

            // Yap's own private system-audio aggregate (a meeting's tap) with the lid closed.
            save(mode: .custom, custom: ("missing-mic", nil))
            _ = start("own-aggregate-lid-closed", [aggregate, builtIn], lid: true)

            // The user's own choices of a virtual input: the system default, a custom device, a priority list.
            save(mode: .systemDefault)
            _ = start("system-default-virtual", [builtIn, virtual], default: virtual.id)
            save(mode: .custom, custom: (virtual.uid, nil))
            _ = start("custom-virtual", [builtIn, usb, virtual])
            save(mode: .prioritized, prioritized: ["missing-mic", virtual.uid, builtIn.uid])
            _ = start("prioritized-virtual", [builtIn, virtual])
            save(mode: .prioritized, prioritized: ["missing-mic"])
            _ = start("prioritized-none-left-but-virtual", [virtual, aggregate])
            save(mode: .prioritized, prioritized: ["missing-mic"])
            _ = start("prioritized-falls-back-to-builtin", [virtual, builtIn])

            // Transport the device doesn't report.
            save(mode: .custom, custom: ("missing-mic", nil))
            _ = start("unknown-transport-and-usb", [unknown, usb])
            save(mode: .custom, custom: ("missing-mic", nil))
            _ = start("unknown-transport-only", [unknown])

            // The saved device comes back with another UID but the same model UID: found and saved again.
            save(mode: .custom, custom: ("usb-old-uid", "M-USB"))
            _ = start("uid-reidentified", [builtIn, usb])

            // Unplugged and plugged back: the fallback isn't saved, and the saved device is used again.
            save(mode: .custom, custom: (usb.uid, "M-USB"))
            let manager = start("usb-chosen", [virtual, builtIn, usb])
            change("usb-unplugged", manager, [virtual, builtIn])
            change("usb-unplugged-lid-closed", manager, [virtual, builtIn], lid: true)
            change("usb-back", manager, [virtual, builtIn, usb])

            // During a recording on the USB microphone, it goes away.
            save(mode: .custom, custom: (usb.uid, "M-USB"))
            let recording = start("recording-usb", [usb, airPods, virtual])
            loseDuringRecording("recording-lost-airpods-left", recording, active: usb.id, [virtual, airPods])
            change("recording-usb-back", recording, [usb, virtual])
            loseDuringRecording("recording-lost-only-virtual", recording, active: usb.id, [virtual])
        }

        private static func smoke() {
            let manager = AudioDeviceManager.shared
            settle()
            for device in manager.availableDevices {
                let transport = manager.getUInt32DeviceProperty(deviceID: device.id, selector: kAudioDevicePropertyTransportType)
                print("mic-check: device \(device.id) \(fourCC(transport)) internal-mic \(manager.isInternalMicrophone(device.id)) automatic-fallback \(manager.isAutomaticFallbackInput(device.id)) \(device.name)")
            }
            print("mic-check: system default \(name(manager.getSystemDefaultDevice(), in: manager)) | lid closed \(manager.isClamshellClosed)")
            report("saved-setting", manager)
            print("mic-check: fallback-pick \(name(manager.findBestAvailableDevice(), in: manager))")
        }

        private static func fourCC(_ value: UInt32?) -> String {
            guard let value else { return "none" }
            let bytes = [24, 16, 8, 0].map { UInt8((value >> $0) & 0xff) }
            return String(bytes: bytes, encoding: .ascii).map { "'\($0)'" } ?? "\(value)"
        }
    }
#endif
