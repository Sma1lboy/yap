import Foundation

/// Text in the recorder while a local Whisper recording is still running. Whisper has no streaming mode, so this
/// re-decodes the recent audio every `interval` with a quick, abortable decode and shows the result. The final
/// transcript still comes from the whole recording (windows, language detection, VAD) once the key is released.
/// The preview is display only.
///
/// Audio since the last commit point is decoded as one piece. Once that piece passes `commitSeconds`, its text is
/// kept and a new piece starts, so every decode stays inside one 30 s Whisper window. The language detected by the
/// first preview is reused for later ones (detection would cost another encoder pass each time).
final class WhisperLivePreview: @unchecked Sendable {
    static let sampleRate = 16_000

    private var context: WhisperContext?
    private let interval: Duration
    private let minNewAudio: Int
    private let commitSamples: Int
    private let onText: @Sendable (String) -> Void
    private let lock = NSLock()
    private var samples: [Float] = []
    private var language: String?
    private var loop: Task<Void, Never>?
    /// Measurements for setup/asr (and logs): decodes run, aborted, seconds spent decoding.
    private(set) var stats = (decodes: 0, aborted: 0, seconds: 0.0)

    /// Audio can be appended right away; decoding starts with `start(context:)` once the model is loaded.
    init(
        language: String?, interval: Duration = .milliseconds(1500),
        minNewAudioSeconds: Double = 1, commitSeconds: Double = 20, onText: @escaping @Sendable (String) -> Void
    ) {
        self.language = language
        self.interval = interval
        self.minNewAudio = Int(minNewAudioSeconds * Double(Self.sampleRate))
        self.commitSamples = Int(commitSeconds * Double(Self.sampleRate))
        self.onText = onText
    }

    /// 16 kHz mono Int16 little-endian PCM, as the recorder's chunk callback delivers it.
    func append(pcm16 data: Data) {
        let floats = data.withUnsafeBytes { raw in
            raw.bindMemory(to: Int16.self).map { Float(Int16(littleEndian: $0)) / 32768 }
        }
        lock.withLock { samples.append(contentsOf: floats) }
    }

    func append(samples floats: [Float]) {
        lock.withLock { samples.append(contentsOf: floats) }
    }

    func start(context: WhisperContext) {
        lock.withLock { self.context = context }
        let slot = context.preview
        slot.open()
        // Detached: each preview decode blocks its thread for a few hundred milliseconds.
        loop = Task.detached(priority: .utility) { [weak self] in
            var committed = ""
            var pieceStart = 0
            var decodedUpTo = 0
            while !Task.isCancelled {
                guard let self else { return }
                try? await Task.sleep(for: self.interval)
                let total = self.lock.withLock { self.samples.count }
                guard total - decodedUpTo >= self.minNewAudio, !Task.isCancelled else { continue }
                // The first decode also detects the language for the rest; wait for enough audio to tell.
                if self.lock.withLock({ self.language == nil }), total - pieceStart < Self.sampleRate * 3 { continue }
                let piece = self.lock.withLock { Array(self.samples[pieceStart..<total]) }
                let language = self.lock.withLock { self.language }

                let started = Date()
                let result = slot.transcribe(piece, language: language)
                self.lock.withLock {
                    self.stats.seconds += Date().timeIntervalSince(started)
                    if result == nil { self.stats.aborted += 1 } else { self.stats.decodes += 1 }
                }
                guard let result, !Task.isCancelled else { continue }
                decodedUpTo = total
                self.lock.withLock { if self.language == nil { self.language = result.language } }
                self.onText(WhisperLivePreview.join(committed, result.text))
                if piece.count >= self.commitSamples {
                    committed = WhisperLivePreview.join(committed, result.text)
                    pieceStart = total
                }
            }
        }
    }

    /// Stops the loop and aborts a decode in flight, so the final transcription starts right away.
    func stop() {
        loop?.cancel()
        loop = nil
        guard let context = lock.withLock({ context }) else { return }
        context.preview.close()
        Task.detached(priority: .utility) { context.preview.releaseState() }
    }

    static func join(_ committed: String, _ current: String) -> String {
        guard !committed.isEmpty else { return current }
        guard !current.isEmpty else { return committed }
        let needsSpace = committed.last.map { $0.isASCII && $0.isLetter } == true
            && current.first.map { $0.isASCII && $0.isLetter } == true
        return committed + (needsSpace ? " " : "") + current
    }

    #if DEBUG
        static func selfCheck() {
            assert(join("", "你好") == "你好")
            assert(join("你好，", "世界") == "你好，世界")
            assert(join("hello", "world") == "hello world")
            assert(join("用 React", "写组件") == "用 React写组件")
            assert(join("第一段", "") == "第一段")
        }
    #endif
}
