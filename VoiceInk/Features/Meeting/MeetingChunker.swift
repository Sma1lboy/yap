import Foundation

/// One channel of a meeting recording as 16 kHz mono Int16 samples, cut into pieces for transcription while the
/// meeting goes on: once at least `minimumSeconds` are buffered, it cuts at the quietest 100 ms between
/// `minimumSeconds` and `maximumSeconds`, so a piece rarely ends mid-word. Pieces whose loudness stays below
/// `silenceRMS` are dropped instead of transcribed (Whisper invents text for silence).
struct MeetingChunker {
    struct Piece: Equatable {
        /// Seconds from the start of the recording.
        let start: TimeInterval
        let samples: [Int16]
        var end: TimeInterval { start + TimeInterval(samples.count) / MeetingChunker.sampleRate }
    }

    static let sampleRate: Double = 16_000
    static let minimumSeconds: Double = 20
    static let maximumSeconds: Double = 28
    static let windowSeconds: Double = 0.1
    /// About −50 dBFS: room tone and a muted call are below it, speech is well above.
    static let silenceRMS: Double = 100

    private var buffer: [Int16] = []
    /// Samples already handed out or dropped, i.e. where `buffer` starts in the recording.
    private var consumed = 0

    /// Adds samples and returns the pieces that are ready, skipping silent ones.
    mutating func append(_ samples: [Int16]) -> [Piece] {
        buffer.append(contentsOf: samples)
        var pieces: [Piece] = []
        let minimum = Int(Self.minimumSeconds * Self.sampleRate)
        while buffer.count >= Int(Self.maximumSeconds * Self.sampleRate) {
            let cut = Self.quietestCut(in: buffer, from: minimum, to: Int(Self.maximumSeconds * Self.sampleRate))
            if let piece = take(cut) { pieces.append(piece) }
        }
        return pieces
    }

    /// The rest, at the end of the recording (if it isn't silent).
    mutating func flush() -> Piece? {
        take(buffer.count)
    }

    private mutating func take(_ count: Int) -> Piece? {
        guard count > 0 else { return nil }
        let samples = Array(buffer.prefix(count))
        buffer.removeFirst(count)
        let start = TimeInterval(consumed) / Self.sampleRate
        consumed += count
        return Self.rms(samples[...]) < Self.silenceRMS ? nil : Piece(start: start, samples: samples)
    }

    /// Start of the quietest 100 ms window in `lower..<upper`, used as the cut point.
    static func quietestCut(in samples: [Int16], from lower: Int, to upper: Int) -> Int {
        let window = Int(windowSeconds * sampleRate)
        let upper = min(upper, samples.count)
        var best = upper, bestRMS = Double.infinity
        var start = lower
        while start + window <= upper {
            let value = rms(samples[start..<(start + window)])
            if value < bestRMS { (best, bestRMS) = (start, value) }
            start += window
        }
        return best
    }

    static func rms(_ samples: ArraySlice<Int16>) -> Double {
        guard !samples.isEmpty else { return 0 }
        let sum = samples.reduce(0.0) { $0 + Double($1) * Double($1) }
        return (sum / Double(samples.count)).squareRoot()
    }
}

/// A 16 kHz mono Int16 WAV written as samples arrive; the header's sizes are filled in on `close()`.
final class PCM16WAVWriter {
    private let handle: FileHandle
    private(set) var sampleCount = 0

    init(url: URL) throws {
        FileManager.default.createFile(atPath: url.path, contents: Self.header(sampleCount: 0))
        handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
    }

    func append(_ samples: [Int16]) {
        guard !samples.isEmpty else { return }
        samples.withUnsafeBufferPointer { handle.write(Data(buffer: $0)) }
        sampleCount += samples.count
    }

    func close() {
        try? handle.seek(toOffset: 0)
        handle.write(Self.header(sampleCount: sampleCount))
        try? handle.close()
    }

    static func header(sampleCount: Int) -> Data {
        let dataBytes = UInt32(sampleCount * 2)
        var data = Data()
        func put<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        data.append(contentsOf: "RIFF".utf8); put(UInt32(36) + dataBytes); data.append(contentsOf: "WAVE".utf8)
        data.append(contentsOf: "fmt ".utf8); put(UInt32(16)); put(UInt16(1)); put(UInt16(1))
        put(UInt32(16_000)); put(UInt32(32_000)); put(UInt16(2)); put(UInt16(16))
        data.append(contentsOf: "data".utf8); put(dataBytes)
        return data
    }

    /// Writes a finished piece (a chunk for transcription).
    static func write(_ samples: [Int16], to url: URL) throws {
        var data = header(sampleCount: samples.count)
        samples.withUnsafeBufferPointer { data.append(Data(buffer: $0)) }
        try data.write(to: url)
    }

    static func samples(from data: Data) -> [Int16] {
        guard data.count > 44 else { return [] }
        let body = data.dropFirst(44)
        var samples = [Int16](repeating: 0, count: body.count / 2)
        _ = samples.withUnsafeMutableBytes { body.copyBytes(to: $0) }
        return samples
    }
}

#if DEBUG
    extension MeetingChunker {
        static func selfCheck() {
            let rate = Int(sampleRate)
            func tone(_ seconds: Double, amplitude: Int16 = 3_000) -> [Int16] {
                (0..<Int(seconds * sampleRate)).map { $0 % 32 < 16 ? amplitude : -amplitude }
            }
            func silence(_ seconds: Double) -> [Int16] { Array(repeating: 0, count: Int(seconds * sampleRate)) }

            var chunker = MeetingChunker()
            // Speech with a pause at 23–23.5 s: the cut lands in the pause, not at 28 s.
            let speech = tone(23) + silence(0.5) + tone(10)
            let pieces = chunker.append(speech)
            assert(pieces.count == 1 && pieces[0].start == 0)
            assert(abs(pieces[0].end - 23) < 0.2, "cut at the pause, got \(pieces[0].end)")
            let rest = chunker.flush()
            assert(rest != nil && abs(rest!.start - pieces[0].end) < 0.001 && abs(rest!.end - 33.5) < 0.001)

            var quiet = MeetingChunker()
            assert(quiet.append(silence(30)).isEmpty, "silent pieces are dropped")
            // The dropped silence still counts for the timeline: the next piece starts at 20 s, the rest at 40 s.
            let after = quiet.append(tone(29))
            assert(after.count == 1 && after[0].start == 20 && after[0].end == 40)
            assert(quiet.flush()?.start == 40)
            var empty = MeetingChunker()
            assert(empty.flush() == nil)
            assert(quietestCut(in: tone(1) + silence(0.2) + tone(1), from: 0, to: rate * 3) / (rate / 10) == 10)

            let samples: [Int16] = [0, 1, -1, 32_767, -32_768]
            var wav = PCM16WAVWriter.header(sampleCount: samples.count)
            samples.withUnsafeBufferPointer { wav.append(Data(buffer: $0)) }
            assert(wav.count == 44 + 10 && PCM16WAVWriter.samples(from: wav) == samples)
        }
    }
#endif
