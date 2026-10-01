import Foundation
import os

/// How long local models (Whisper, FluidAudio, transcribe.cpp) stay in memory after the last dictation, and the
/// release itself: on a timer, or on a system memory-pressure warning. Never while a recording, a transcription
/// or the live preview is running. Setting: Models > Advanced > Keep model loaded.
@MainActor
final class ModelResidency {
    static let shared = ModelResidency()

    nonisolated static let keepSecondsKey = "ModelKeepLoadedSeconds"
    nonisolated static let keepAlways = 0
    /// Released as soon as the dictation ends, as before this setting existed; reloading costs ~nothing measured.
    nonisolated static let keepAfterEach = -1
    nonisolated static let defaultKeepSeconds = keepAfterEach
    /// "After each dictation" also frees a model that was preloaded by a shortcut press that never became one.
    nonisolated static let afterEachGraceSeconds: TimeInterval = 30

    /// The one decision, kept pure so selfCheck can pin it down. `idleFor` is the time since the last use.
    nonisolated static func shouldRelease(
        keepSeconds: Int, idleFor: TimeInterval, isBusy: Bool, memoryPressure: Bool
    ) -> Bool {
        if isBusy { return false }
        if memoryPressure { return true }
        if keepSeconds == keepAlways { return false }
        if keepSeconds == keepAfterEach { return idleFor >= afterEachGraceSeconds }
        return idleFor >= TimeInterval(keepSeconds)
    }

    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "ModelResidency")
    private var release: (() async -> Void)?
    private var isRecordingBusy: () -> Bool = { false }
    private var activeUses = 0
    private var lastUse = Date()
    private var pressureWhileBusy = false
    private var timer: Task<Void, Never>?
    private var pressureSource: DispatchSourceMemoryPressure?
    private var settingsObserver: NSObjectProtocol?

    private var keepSeconds: Int {
        UserDefaults.standard.object(forKey: Self.keepSecondsKey) as? Int ?? Self.defaultKeepSeconds
    }
    private var isBusy: Bool { activeUses > 0 || isRecordingBusy() }

    /// The engine hands over what to release and when it is mid-recording or mid-pipeline.
    func configure(isBusy: @escaping () -> Bool, release: @escaping () async -> Void) {
        isRecordingBusy = isBusy
        self.release = release
        guard pressureSource == nil else { return }
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.memoryPressure() }
        }
        source.resume()
        pressureSource = source
        // A shorter setting takes effect without waiting out the old timer.
        settingsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.startTimer() }
        }
    }

    /// A model was just used or is about to be (shortcut pressed, dictation finished): restart the idle clock.
    func touch() {
        lastUse = Date()
        startTimer()
    }

    /// The dictation is over. With "After each dictation" the models go now (the old behaviour); otherwise the
    /// idle clock restarts.
    func sessionEnded() async {
        guard keepSeconds == Self.keepAfterEach, activeUses == 0 else { return touch() }
        timer?.cancel()
        timer = nil
        await release?()
    }

    /// Wraps work that needs a loaded model but isn't the engine's recording state (meeting chunks).
    func withUse<T>(_ body: () async throws -> T) async rethrows -> T {
        activeUses += 1
        defer {
            activeUses -= 1
            touch()
        }
        return try await body()
    }

    private func memoryPressure() {
        logger.notice("memory pressure: releasing local models (busy: \(self.isBusy, privacy: .public))")
        pressureWhileBusy = true
        startTimer()
    }

    private func startTimer() {
        timer?.cancel()
        timer = Task { [weak self] in
            while let self, !Task.isCancelled {
                let keep = self.keepSeconds
                let idle = Date().timeIntervalSince(self.lastUse)
                if Self.shouldRelease(
                    keepSeconds: keep, idleFor: idle, isBusy: self.isBusy, memoryPressure: self.pressureWhileBusy)
                {
                    self.pressureWhileBusy = false
                    self.timer = nil
                    // A use that begins between this check and the free still runs: Whisper's and
                    // FluidAudio's releases wait for their turn (ModelTurns) and the model is loaded again after it;
                    // transcribe.cpp unloads after its last running transcription. Only the cost of a reload is lost.
                    self.logger.notice("releasing local models after \(Int(idle), privacy: .public) s idle")
                    await self.release?()
                    return
                }
                if keep == Self.keepAlways && !self.pressureWhileBusy {
                    self.timer = nil
                    return
                }
                // Busy (or pressure waiting for the end of a dictation): look again soon; idle: sleep the rest.
                let remaining = self.isBusy || self.pressureWhileBusy ? 2 : max(1, Double(keep) - idle)
                try? await Task.sleep(for: .seconds(remaining))
            }
        }
    }

    #if DEBUG
        /// `make lifecycle-check`: the memory-pressure warning the system would send.
        func simulateMemoryPressure() { memoryPressure() }

        static func selfCheck() {
            let keep = 900
            precondition(!shouldRelease(keepSeconds: keep, idleFor: 899, isBusy: false, memoryPressure: false))
            precondition(shouldRelease(keepSeconds: keep, idleFor: 900, isBusy: false, memoryPressure: false))
            // After each dictation: the session end releases directly; the timer only sweeps up a stray preload.
            precondition(!shouldRelease(keepSeconds: keepAfterEach, idleFor: 1, isBusy: false, memoryPressure: false))
            precondition(shouldRelease(keepSeconds: keepAfterEach, idleFor: 31, isBusy: false, memoryPressure: false))
            precondition(!shouldRelease(keepSeconds: keepAfterEach, idleFor: 31, isBusy: true, memoryPressure: false))
            precondition(defaultKeepSeconds == keepAfterEach)
            precondition(!shouldRelease(keepSeconds: keepAlways, idleFor: 86_400, isBusy: false, memoryPressure: false))
            // Memory pressure releases even with "Always", but never mid-recording or mid-transcription.
            precondition(shouldRelease(keepSeconds: keepAlways, idleFor: 0, isBusy: false, memoryPressure: true))
            precondition(!shouldRelease(keepSeconds: keep, idleFor: 10_000, isBusy: true, memoryPressure: false))
            precondition(!shouldRelease(keepSeconds: keep, idleFor: 0, isBusy: true, memoryPressure: true))
        }
    #endif
}
