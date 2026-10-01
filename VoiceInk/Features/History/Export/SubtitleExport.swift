import Foundation

/// One timed stretch of a transcript, in seconds from the start of the original audio.
struct TimedSegment: Codable, Equatable {
    var start: Double
    var end: Double
    var text: String
}

extension Transcription {
    var timedSegments: [TimedSegment] { TimedSegments.decode(segmentsJSON) }
}

/// Subtitles and timestamped text from `TimedSegment`s (local Whisper only: cloud providers mostly return
/// no timestamps). Speaker labels aren't part of this.
enum SubtitleFormat: String, CaseIterable, Identifiable {
    case srt, vtt, markdown

    var id: String { rawValue }
    var fileExtension: String { self == .markdown ? "md" : rawValue }

    func render(_ segments: [TimedSegment]) -> String {
        switch self {
        case .srt:
            return segments.enumerated().map { index, s in
                "\(index + 1)\n\(Self.clock(s.start, separator: ","))" + " --> "
                    + "\(Self.clock(s.end, separator: ","))\n\(s.text)\n"
            }.joined(separator: "\n")
        case .vtt:
            let cues = segments.map { s in
                "\(Self.clock(s.start, separator: ".")) --> \(Self.clock(s.end, separator: "."))\n\(s.text)\n"
            }
            return (["WEBVTT\n"] + cues).joined(separator: "\n")
        case .markdown:
            return segments.map { "**[\(Self.shortClock($0.start))]** \($0.text)" }.joined(separator: "\n\n") + "\n"
        }
    }

    /// "01:02:03,450" (SRT) or "01:02:03.450" (VTT).
    static func clock(_ seconds: Double, separator: String) -> String {
        let ms = Int((max(0, seconds) * 1000).rounded())
        return String(format: "%02d:%02d:%02d%@%03d", ms / 3_600_000, ms / 60_000 % 60, ms / 1000 % 60, separator, ms % 1000)
    }

    /// "1:05" or "1:02:03" for Markdown.
    static func shortClock(_ seconds: Double) -> String {
        let s = Int(max(0, seconds))
        return s >= 3600
            ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
            : String(format: "%d:%02d", s / 60, s % 60)
    }
}

enum TimedSegments {
    /// Whisper reports segment times in centiseconds from the start of the slice it decoded. `offsetSamples`
    /// is where that slice (a window, or a single-language piece of one) starts in the whole recording.
    static func fromWhisper(
        t0: Int64, t1: Int64, text: String, offsetSamples: Int, sliceSamples: Int, sampleRate: Int = 16_000
    ) -> TimedSegment {
        let offset = Double(offsetSamples) / Double(sampleRate)
        let sliceEnd = offset + Double(sliceSamples) / Double(sampleRate)
        // Whisper can predict an end a little past the audio it was given; keep it inside the slice.
        let start = min(offset + Double(t0) / 100, sliceEnd)
        let end = min(max(offset + Double(t1) / 100, start), sliceEnd)
        return TimedSegment(start: start, end: end, text: text)
    }

    /// Trims text, drops empty segments and Whisper's "[BLANK_AUDIO]"-style markers, and makes times
    /// monotonic (each segment starts no earlier than the previous one ends) for players that require it.
    static func tidy(_ segments: [TimedSegment], text transform: (String) -> String = { $0 }) -> [TimedSegment] {
        var result: [TimedSegment] = []
        for segment in segments.sorted(by: { $0.start < $1.start }) {
            let text = transform(segment.text).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, !(text.hasPrefix("[") && text.hasSuffix("]")) else { continue }
            let start = max(segment.start, result.last?.end ?? 0)
            result.append(TimedSegment(start: start, end: max(segment.end, start), text: text))
        }
        return result
    }

    /// Whisper stretches a segment over silence when a window holds long pauses (VAD off keeps them), e.g. a
    /// segment "starting" at the window's start while the speech begins 8 s later. `speech` (Silero's ranges,
    /// in samples) pulls each segment's start and end in to the speech it overlaps; a segment overlapping no
    /// speech is left as it is.
    static func snapToSpeech(
        _ segments: [TimedSegment], speech: [Range<Int>], sampleRate: Int = 16_000
    ) -> [TimedSegment] {
        let rate = Double(sampleRate)
        return segments.map { segment in
            let overlapping = speech.filter {
                Double($0.lowerBound) / rate < segment.end && Double($0.upperBound) / rate > segment.start
            }
            guard let first = overlapping.first, let last = overlapping.last else { return segment }
            let start = max(segment.start, Double(first.lowerBound) / rate)
            let end = min(segment.end, Double(last.upperBound) / rate)
            return end > start ? TimedSegment(start: start, end: end, text: segment.text) : segment
        }
    }

    static func encode(_ segments: [TimedSegment]) -> String? {
        guard !segments.isEmpty, let data = try? JSONEncoder().encode(segments) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    static func decode(_ json: String?) -> [TimedSegment] {
        guard let json, let segments = try? JSONDecoder().decode([TimedSegment].self, from: Data(json.utf8)) else {
            return []
        }
        return segments
    }

    #if DEBUG
        static func selfCheck() {
            // Formats.
            let two = [TimedSegment(start: 1.5, end: 3.25, text: "Hello"), TimedSegment(start: 3661, end: 3662.5, text: "你好")]
            assert(SubtitleFormat.srt.render(two) == "1\n00:00:01,500 --> 00:00:03,250\nHello\n\n2\n01:01:01,000 --> 01:01:02,500\n你好\n")
            assert(SubtitleFormat.vtt.render(two).hasPrefix("WEBVTT\n\n00:00:01.500 --> 00:00:03.250\nHello\n"))
            assert(SubtitleFormat.markdown.render(two) == "**[0:01]** Hello\n\n**[1:01:01]** 你好\n")
            assert(tidy([TimedSegment(start: 0, end: 1, text: " [BLANK_AUDIO] "), TimedSegment(start: 1, end: 2, text: " ")]).isEmpty)
            assert(decode(encode(two)) == two && decode(nil).isEmpty && encode([]) == nil)

            // A segment spread over a window's silence is pulled in to its speech; one without speech stays.
            let hz = 16_000
            let spread = [TimedSegment(start: 38.95, end: 62.59, text: "a"), TimedSegment(start: 70, end: 71, text: "b")]
            let snapped = snapToSpeech(spread, speech: [30 * hz..<40 * hz, 47 * hz..<54 * hz, 60 * hz..<61 * hz])
            assert(snapped[0] == TimedSegment(start: 38.95, end: 61, text: "a") && snapped[1] == spread[1])
            assert(snapToSpeech(spread, speech: [47 * hz..<54 * hz])[0] == TimedSegment(start: 47, end: 54, text: "a"))

            // A long file, stitched from windows: times stay monotonic and within 0.5 s of the real audio.
            // A 100 s recording with a 1.2 s utterance starting every 4.3 s; whisper returns each utterance
            // relative to its window (or language piece), a few centiseconds off, as it does in practice.
            let rate = WhisperChunking.sampleRate
            let truth = stride(from: 0.6, to: 98.0, by: 4.3).map { ($0, $0 + 1.2) }
            let speech = truth.map { Int($0.0 * Double(rate))..<Int($0.1 * Double(rate)) }
            let total = 100 * rate
            for keepSilence in [true, false] {
                let windows = WhisperChunking.windows(speech: speech, total: total, keepSilence: keepSilence)
                assert(windows.count >= 4)  // longer than several 28 s windows
                var stitched: [TimedSegment] = []
                for window in windows {
                    // Split a window in two like a mixed-language one, to exercise piece offsets too. The app
                    // cuts language pieces at the quietest moment, so cut in the pause nearest the middle.
                    let middle = window.lowerBound + window.count / 2
                    let pauses = zip(truth, truth.dropFirst()).map { Int(($0.1 + $1.0) / 2 * Double(rate)) }
                    let mid = pauses.filter { window.contains($0) }.min { abs($0 - middle) < abs($1 - middle) }
                        ?? window.upperBound
                    for piece in [window.lowerBound..<mid, mid..<window.upperBound] where !piece.isEmpty {
                        for (index, (start, end)) in truth.enumerated() {
                            let s = Int(start * Double(rate))
                            guard piece.contains(s) else { continue }
                            let jitter = Int64(index % 3) - 1  // −1, 0, +1 cs
                            let t0 = Int64((Double(s - piece.lowerBound) / Double(rate)) * 100) + jitter
                            let t1 = t0 + Int64((end - start) * 100)
                            stitched.append(
                                fromWhisper(
                                    t0: max(0, t0), t1: t1, text: "u\(index)", offsetSamples: piece.lowerBound,
                                    sliceSamples: piece.count))
                        }
                    }
                }
                let tidied = tidy(stitched)
                assert(tidied.count == truth.count)
                assert(zip(tidied, tidied.dropFirst()).allSatisfy { $0.start <= $1.start && $0.end <= $1.start })
                assert(tidied.allSatisfy { $0.start <= $0.end })
                for (segment, expected) in zip(tidied, truth) {
                    assert(abs(segment.start - expected.0) < 0.5 && abs(segment.end - expected.1) < 0.5)
                }
            }
        }
    #endif
}
