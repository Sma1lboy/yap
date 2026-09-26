import AVFoundation

/// A recording with nothing to transcribe, caught before it reaches a provider. Cloud APIs answer an
/// empty or very short file with errors like "Invalid audio data provided. Must be at least 300ms of
/// 16kHz audio" (upstream #892), which then showed up as a failed transcription with a useless Retry.
enum RecordedAudioIssue: LocalizedError, Equatable {
    /// No frames, or every sample is exactly 0. A working microphone always has a noise floor, so pure
    /// digital zero means the input delivered nothing (upstream #892, #916, #956).
    case noSound
    /// Shorter than the 0.3 s providers accept.
    case tooShort

    static let minimumSeconds = 0.3

    /// Nil when the file looks transcribable, or can't be read (the provider reports that case itself).
    static func check(_ url: URL) -> RecordedAudioIssue? {
        guard let file = try? AVAudioFile(forReading: url),
            let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 16_384)
        else { return nil }

        var hasSignal = false
        // Real speech has a non-zero sample in the first buffer, so this reads one buffer in practice.
        while !hasSignal, (try? file.read(into: buffer)) != nil, buffer.frameLength > 0 {
            guard let channels = buffer.floatChannelData else { return nil }
            for ch in 0..<Int(buffer.format.channelCount) {
                if UnsafeBufferPointer(start: channels[ch], count: Int(buffer.frameLength)).contains(where: { $0 != 0 }) {
                    hasSignal = true
                }
            }
        }
        return classify(frames: file.length, sampleRate: file.fileFormat.sampleRate, hasSignal: hasSignal)
    }

    static func classify(frames: Int64, sampleRate: Double, hasSignal: Bool) -> RecordedAudioIssue? {
        if frames == 0 || !hasSignal { return .noSound }
        if Double(frames) / sampleRate < minimumSeconds { return .tooShort }
        return nil
    }

    var errorDescription: String? {
        switch self {
        case .noSound:
            return String(
                localized: "The microphone didn't pick up any sound. Try again, or choose another microphone in Audio Settings.")
        case .tooShort:
            return String(localized: "Recording was too short to transcribe. Try speaking a little longer.")
        }
    }

    #if DEBUG
        static func selfCheck() {
            assert(classify(frames: 0, sampleRate: 16000, hasSignal: false) == .noSound)
            assert(classify(frames: 16000 * 9, sampleRate: 16000, hasSignal: false) == .noSound)
            assert(classify(frames: 3200, sampleRate: 16000, hasSignal: true) == .tooShort)
            assert(classify(frames: 4800, sampleRate: 16000, hasSignal: true) == nil)

            let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }
            func wav(_ samples: [Int16]) -> URL {
                let url = dir.appendingPathComponent("\(UUID().uuidString).wav")
                let format = AVAudioFormat(
                    commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true)!
                let file = try! AVAudioFile(
                    forWriting: url, settings: format.settings, commonFormat: .pcmFormatInt16, interleaved: true)
                if !samples.isEmpty {
                    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
                    buffer.frameLength = buffer.frameCapacity
                    samples.withUnsafeBufferPointer { buffer.int16ChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
                    try! file.write(from: buffer)
                }
                return url
            }
            assert(check(wav([])) == .noSound)
            assert(check(wav([Int16](repeating: 0, count: 40_000))) == .noSound)
            var late = [Int16](repeating: 0, count: 40_000)
            late[39_000] = 3  // signal only after the first read buffer
            assert(check(wav(late)) == nil)
            assert(check(wav((0..<2000).map { Int16($0 % 7) })) == .tooShort)
        }
    #endif
}
