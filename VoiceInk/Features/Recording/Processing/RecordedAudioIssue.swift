import AVFoundation

/// A recording, or its transcript, with nothing worth pasting, caught around the provider call. Cloud APIs
/// answer an empty or very short file with errors like "Invalid audio data provided. Must be at least 300ms of
/// 16kHz audio" (upstream #892), which then showed up as a failed transcription with a useless Retry; and
/// Whisper answers near-silence with a made-up phrase, which then got pasted.
enum RecordedAudioIssue: LocalizedError, Equatable {
    /// No frames, or every sample is exactly 0. A working microphone always has a noise floor, so pure
    /// digital zero means the input delivered nothing (upstream #892, #916, #956).
    case noSound
    /// Shorter than the 0.3 s providers accept.
    case tooShort
    /// The loudest sample never rose above `quietPeakDBFS`: a wrong, distant or muted microphone.
    case tooQuiet
    /// The whole transcript is a phrase Whisper invents on silence (`TranscriptionOutputFilter`). Carries
    /// that text so History can keep it.
    case hallucinated(String)

    static let minimumSeconds = 0.3
    /// Peak below this is the noise floor, not speech; even quiet speech peaks well above it.
    static let quietPeakDBFS: Float = -45

    /// Nil when the file looks transcribable, or can't be read (the provider reports that case itself).
    static func check(_ url: URL) -> RecordedAudioIssue? {
        guard let file = try? AVAudioFile(forReading: url),
            let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 16_384)
        else { return nil }

        var peak: Float = 0
        while (try? file.read(into: buffer)) != nil, buffer.frameLength > 0 {
            guard let channels = buffer.floatChannelData else { return nil }
            for ch in 0..<Int(buffer.format.channelCount) {
                for sample in UnsafeBufferPointer(start: channels[ch], count: Int(buffer.frameLength)) {
                    peak = max(peak, abs(sample))
                }
            }
        }
        return classify(frames: file.length, sampleRate: file.fileFormat.sampleRate, peak: peak)
    }

    /// `peak` is the largest absolute sample, 0...1.
    static func classify(frames: Int64, sampleRate: Double, peak: Float) -> RecordedAudioIssue? {
        if frames == 0 || peak == 0 { return .noSound }
        if Double(frames) / sampleRate < minimumSeconds { return .tooShort }
        if 20 * log10(peak) < quietPeakDBFS { return .tooQuiet }
        return nil
    }

    var errorDescription: String? {
        switch self {
        case .noSound:
            return String(
                localized: "The microphone didn't pick up any sound. Try again, or choose another microphone in Audio Settings.")
        case .tooShort:
            return String(localized: "Recording was too short to transcribe. Try speaking a little longer.")
        case .tooQuiet:
            return String(localized: "Yap barely heard anything. Check that the right microphone is selected in Audio Settings.")
        case .hallucinated:
            return String(localized: "Yap didn't catch anything.")
        }
    }

    /// The notification for this issue. A quiet recording names the input a recording uses (the mode's choice or the
    /// fallback, as `resolveCurrentRecordingDevice` decides), since a wrong one is the usual cause.
    @MainActor
    var notificationTitle: String {
        guard self == .tooQuiet else { return errorDescription ?? "" }
        let manager = AudioDeviceManager.shared
        guard let device = manager.resolveCurrentRecordingDevice().deviceID.flatMap(manager.getDeviceName)
        else { return errorDescription ?? "" }
        return String(
            format: String(localized: "Yap barely heard anything from “%@”. Check your microphone in Audio Settings."), device)
    }

    /// Whether the notification offers Audio Settings: the input, not the words, is the likely problem.
    var offersAudioSettings: Bool { self == .noSound || self == .tooQuiet }

    #if DEBUG
        static func selfCheck() {
            assert(classify(frames: 0, sampleRate: 16000, peak: 0) == .noSound)
            assert(classify(frames: 16000 * 9, sampleRate: 16000, peak: 0) == .noSound)
            assert(classify(frames: 3200, sampleRate: 16000, peak: 0.5) == .tooShort)
            assert(classify(frames: 4800, sampleRate: 16000, peak: 0.5) == nil)
            // -45 dBFS is 0.00562: a noise-floor peak is too quiet, quiet speech at -30 dBFS is not.
            assert(classify(frames: 16000, sampleRate: 16000, peak: 0.001) == .tooQuiet)
            assert(classify(frames: 16000, sampleRate: 16000, peak: 0.0056) == .tooQuiet)
            assert(classify(frames: 16000, sampleRate: 16000, peak: 0.0057) == nil)
            assert(classify(frames: 16000, sampleRate: 16000, peak: 0.03) == nil)
            assert(RecordedAudioIssue.tooQuiet.offersAudioSettings && !RecordedAudioIssue.hallucinated("x").offersAudioSettings)

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
            late[39_000] = 3  // signal only after the first read buffer, and far under -45 dBFS
            assert(check(wav(late)) == .tooQuiet)
            late[39_000] = 8000  // the whole file is read, not just the first buffer
            assert(check(wav(late)) == nil)
            assert(check(wav([Int16](repeating: 40, count: 40_000))) == .tooQuiet)  // -58 dBFS
            assert(check(wav((0..<2000).map { Int16($0 % 7) })) == .tooShort)
        }
    #endif
}
