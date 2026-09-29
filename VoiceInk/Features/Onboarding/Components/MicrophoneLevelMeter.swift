import AVFoundation
import CoreAudio
import SwiftUI

/// Live input level of one microphone for the onboarding microphone step.
/// Captures with `CoreAudioRecorder` directly: `Recorder.startRecording` pauses media and mutes the system,
/// which a level check must not do. The capture needs an output file; `stop()` deletes it.
final class MicrophoneLevelProbe: ObservableObject, @unchecked Sendable {
    /// True while the current device is being captured; false with no permission or when the device fails to open.
    @Published private(set) var isActive = false

    private let recorder = CoreAudioRecorder()
    private let queue = DispatchQueue(label: "yap.microphone-level-probe")
    private var generation = 0  // main thread only
    private let file = FileManager.default.temporaryDirectory
        .appendingPathComponent("yap-mic-level-\(UUID().uuidString).wav")

    /// 0…1 for the meter; the same -60…0 dB window the recording HUD uses.
    static func normalized(decibels: Float) -> Double {
        let minDb: Float = -60
        return Double(min(max((decibels - minDb) / -minDb, 0), 1))
    }

    var level: Double { Self.normalized(decibels: recorder.averagePower) }

    /// Switches capture to `deviceID`. Does nothing without microphone permission.
    func start(deviceID: AudioDeviceID) {
        generation += 1
        let current = generation
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            isActive = false
            return
        }
        queue.async { [self] in
            recorder.stopRecording()
            var started = false
            do {
                try recorder.startRecording(toOutputFile: file, deviceID: deviceID)
                started = true
            } catch {
                recorder.teardown()
                try? FileManager.default.removeItem(at: file)
            }
            DispatchQueue.main.async { [self] in
                if current == generation { isActive = started }
            }
        }
    }

    /// Stops capture, releases the device and deletes the temporary file.
    func stop() {
        generation += 1
        isActive = false
        queue.async { [self] in
            recorder.teardown()
            try? FileManager.default.removeItem(at: file)
        }
    }

    #if DEBUG
        static func selfCheck() {
            assert(normalized(decibels: -160) == 0)
            assert(normalized(decibels: -60) == 0)
            assert(abs(normalized(decibels: -30) - 0.5) < 1e-6)
            assert(normalized(decibels: 0) == 1)
            assert(normalized(decibels: 6) == 1)
        }
    #endif
}

/// Track and fill for `MicrophoneLevelProbe.level`, redrawn ~20 times a second.
struct MicrophoneLevelBar: View {
    let probe: MicrophoneLevelProbe

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.05)) { _ in
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(AppTheme.Surface.controlActive)
                    Capsule()
                        .fill(AppTheme.Accent.primary)
                        .frame(width: max(proxy.size.height, proxy.size.width * probe.level))
                }
            }
        }
        .frame(width: 96, height: AppTheme.Spacing.x2)
        .accessibilityHidden(true)
    }
}
