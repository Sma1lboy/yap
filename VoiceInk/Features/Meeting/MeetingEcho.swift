import Accelerate
import Foundation

/// Without headphones the other side's voice comes out of the speakers and reaches the microphone, so the same words
/// are transcribed twice: under "Others" and again under "Me". After the last piece is transcribed, the "Me" pieces
/// that are that echo are marked (`MeetingSegment.echo`) and left out of the transcript, and the echoed words are
/// cut out of pieces where the user also spoke (`textWithEcho` keeps the text as transcribed).
///
/// Signal first: the system audio, delayed and quieter, has to explain the microphone. Only when the two channels'
/// loudness moves together for the whole meeting (the speakers reach the microphone at all) is each 20 ms of the
/// microphone compared with the system audio just before it: louder than the echo it predicts means the user
/// spoke. Text second: words are cut from a "Me" piece only where the signal found echo in it and they also appear,
/// in order, in the "Others" pieces at the same time, so quoting the other side with headphones on is kept.
enum MeetingEcho {
    /// 20 ms at 16 kHz.
    static let frameLength = 320
    static let frameSeconds = Double(frameLength) / MeetingChunker.sampleRate
    /// The microphone must be 6 dB above the echo the system audio predicts for a frame to count as the user.
    static let ownSpeechMargin: Float = 4
    /// Delays searched between the system audio and the microphone, in frames: −100…600 ms. The acoustic delay is
    /// up to about 150 ms; the rest is the two capture paths' latencies.
    static let lags = -5...30
    /// The echo can arrive this many frames earlier or later than the best lag (timing jitter, the room's reverb).
    static let spread = -1...4
    /// At the right delay the microphone is the system audio a fixed number of dB quieter, so the level difference
    /// barely varies (its interquartile range; 1–3 dB in the checks). It must be at most this, and at most half of
    /// what it is at a typical delay (12–21 dB), where the two just don't line up.
    static let maximumSpread: Float = 6
    static let maximumSpreadShare: Float = 0.5
    /// And the microphone must hear something (above its own noise) in at least half of the loud system frames.
    static let minimumHeard: Float = 0.5

    // MARK: - Signal

    /// Mean square of each 20 ms frame of a 16 kHz mono PCM16 WAV (samples scaled to ±1), read from byte 44.
    static func energies(of url: URL) -> [Float] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        try? handle.seek(toOffset: 44)
        var result: [Float] = []
        let scale = 1 / Float(32768 * 32768)
        var samples = [Float](repeating: 0, count: frameLength * 500)
        while let data = try? handle.read(upToCount: frameLength * 2 * 500), data.count >= frameLength * 2 {
            let count = data.count / 2 / frameLength * frameLength
            data.withUnsafeBytes { raw in
                vDSP_vflt16(raw.bindMemory(to: Int16.self).baseAddress!, 1, &samples, 1, vDSP_Length(count))
            }
            samples.withUnsafeBufferPointer { buffer in
                for start in stride(from: 0, to: count, by: frameLength) {
                    var meanSquare: Float = 0
                    vDSP_measqv(buffer.baseAddress! + start, 1, &meanSquare, vDSP_Length(frameLength))
                    result.append(meanSquare * scale)
                }
            }
        }
        return result
    }

    /// How the speakers reach the microphone: the delay in frames, the echo's energy relative to the loudest system
    /// frame around that delay (`predictedEcho`), and the microphone's noise floor.
    struct Coupling: Equatable {
        let lag: Int
        let gain: Float
        let floor: Float
    }

    /// The delay at which the microphone follows the system audio most closely: for the loud half of the frames
    /// where the system audio plays, the spread of (microphone − system audio) in dB. With headphones the microphone
    /// is just the room there, whatever the delay, so no delay stands out.
    struct LagSearch: Equatable {
        let lag: Int
        /// Interquartile range of the level difference at `lag`, and its median over all delays, in dB.
        let spread: Float
        let typicalSpread: Float
        /// The share of those frames where the microphone is above its noise floor.
        let heard: Float
    }

    /// Mean square of the microphone's room noise, plus 10 dB: quieter frames are nobody.
    static func noiseFloor(_ mic: [Float]) -> Float {
        max(percentile(mic, 0.1) * 10, 1e-9)
    }

    static func lagSearch(mic: [Float], system: [Float]) -> LagSearch? {
        let count = min(mic.count, system.count)
        let playing = max(percentile(system, 0.1) * 100, 1e-6)
        let loud = percentile(system.prefix(count).filter { $0 >= playing }, 0.5)
        guard loud > 0 else { return nil }
        let floor = noiseFloor(Array(mic.prefix(count)))
        var results: [(lag: Int, spread: Float, heard: Float)] = []
        for lag in lags {
            // The microphone hears the system audio `lag` frames later: mic[t] against system[t - lag].
            var differences: [Float] = []
            var heard = 0
            for t in max(lag, 0)..<min(count, count + lag) where system[t - lag] >= loud {
                differences.append(10 * log10(max(mic[t], 1e-12) / system[t - lag]))
                if mic[t] >= floor { heard += 1 }
            }
            guard differences.count >= 250 else { continue }  // 5 s of the others speaking up
            differences.sort()
            let spread = differences[differences.count * 3 / 4] - differences[differences.count / 4]
            results.append((lag, spread, Float(heard) / Float(differences.count)))
        }
        guard let best = results.min(by: { $0.spread < $1.spread }) else { return nil }
        let typical = results.map(\.spread).sorted()[results.count / 2]
        return LagSearch(lag: best.lag, spread: best.spread, typicalSpread: typical, heard: best.heard)
    }

    /// nil when the microphone doesn't follow the system audio (headphones, or nobody on the other side spoke):
    /// then nothing is echo.
    static func coupling(mic: [Float], system: [Float]) -> Coupling? {
        guard let search = lagSearch(mic: mic, system: system), search.heard >= minimumHeard,
            search.spread <= min(maximumSpread, search.typicalSpread * maximumSpreadShare)
        else { return nil }
        let count = min(mic.count, system.count)
        let floor = noiseFloor(Array(mic.prefix(count)))
        let predicted = predictedEcho(system, count: count, lag: search.lag)
        let loud = percentile(predicted.filter { $0 >= 1e-6 }, 0.5)
        var ratios: [Float] = []
        for t in 0..<count where mic[t] >= floor && predicted[t] >= loud { ratios.append(mic[t] / predicted[t]) }
        guard ratios.count >= 50 else { return nil }  // 1 s
        return Coupling(lag: search.lag, gain: percentile(ratios, 0.5), floor: floor)
    }

    /// For each microphone frame, the loudest system audio frame that could be echoing in it (before the gain).
    static func predictedEcho(_ system: [Float], count: Int, lag: Int) -> [Float] {
        (0..<count).map { t in
            var loudest: Float = 0
            for offset in spread {
                let source = t - lag - offset
                if source >= 0, source < system.count { loudest = max(loudest, system[source]) }
            }
            return loudest
        }
    }

    /// A frame is the user when it's above the noise floor and clearly louder than the echo predicted for it; nil
    /// when it's only noise.
    static func isOwnSpeech(mic: Float, echo: Float, floor: Float) -> Bool? {
        guard mic >= floor else { return nil }
        return mic > ownSpeechMargin * echo
    }

    /// Seconds of the user's own voice and of echo in one stretch of the microphone.
    struct Evidence: Equatable {
        var own: TimeInterval = 0
        var echo: TimeInterval = 0
    }

    static func evidence(
        mic: [Float], predicted: [Float], coupling: Coupling, from start: TimeInterval, to end: TimeInterval
    ) -> Evidence {
        var evidence = Evidence()
        let first = max(0, Int(start / frameSeconds)), last = min(mic.count, predicted.count, Int(end / frameSeconds))
        guard first < last else { return evidence }
        for t in first..<last {
            guard let own = isOwnSpeech(mic: mic[t], echo: coupling.gain * predicted[t], floor: coupling.floor) else { continue }
            if own { evidence.own += frameSeconds } else { evidence.echo += frameSeconds }
        }
        return evidence
    }

    /// The value below which `share` of the values lie (0 for none).
    private static func percentile<C: Collection>(_ values: C, _ share: Double) -> Float where C.Element == Float {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        return sorted[min(sorted.count - 1, Int(Double(sorted.count) * share))]
    }

    // MARK: - Text

    /// Letters and digits only, case- and width-folded (NFKC), each with the character it came from.
    static func normalized(_ text: String) -> [(scalar: Unicode.Scalar, index: String.Index)] {
        var result: [(Unicode.Scalar, String.Index)] = []
        for index in text.indices {
            for scalar in String(text[index]).precomposedStringWithCompatibilityMapping.lowercased().unicodeScalars
            where CharacterSet.alphanumerics.contains(scalar) {
                result.append((scalar, index))
            }
        }
        return result
    }

    /// A Chinese or Japanese character says as much as about two Latin letters.
    static func weight(_ scalar: Unicode.Scalar) -> Int { scalar.value >= 0x2E80 ? 2 : 1 }

    /// A run of text shared with the other side counts from 4 CJK characters or 8 letters or digits.
    static let minimumRunWeight = 8
    /// What's left of a trimmed piece must say at least this much, else the whole piece is echo.
    static let minimumLeftoverWeight = 4

    /// The stretches of `text` that also appear, in the same order, in `others`: runs of the longest common
    /// subsequence of the two normalized texts, as ranges of `text`, with short gaps between them joined.
    static func sharedRuns(_ text: String, others: String) -> (ranges: [Range<String.Index>], weight: Int, total: Int) {
        let me = normalized(text), them = normalized(others)
        let total = me.reduce(0) { $0 + weight($1.scalar) }
        guard !me.isEmpty, !them.isEmpty else { return ([], 0, total) }
        // Longest common subsequence, then walk it back into matched positions of `me` (with their `them` index).
        let width = them.count + 1
        var table = [UInt16](repeating: 0, count: (me.count + 1) * width)
        for i in 1...me.count {
            for j in 1...them.count {
                table[i * width + j] = me[i - 1].scalar == them[j - 1].scalar
                    ? table[(i - 1) * width + j - 1] + 1
                    : max(table[(i - 1) * width + j], table[i * width + j - 1])
            }
        }
        var matched: [(i: Int, j: Int)] = []
        var (i, j) = (me.count, them.count)
        while i > 0, j > 0 {
            if me[i - 1].scalar == them[j - 1].scalar {
                matched.append((i - 1, j - 1))
                i -= 1
                j -= 1
            } else if table[(i - 1) * width + j] >= table[i * width + j - 1] {
                i -= 1
            } else {
                j -= 1
            }
        }
        matched.reverse()

        // Consecutive in both texts: one run. Runs too short to mean anything are dropped.
        var runs: [ClosedRange<Int>] = []
        var start = 0
        for k in matched.indices {
            let last = k == matched.count - 1
                || matched[k + 1].i != matched[k].i + 1 || matched[k + 1].j != matched[k].j + 1
            guard last else { continue }
            let run = matched[start].i...matched[k].i
            if run.reduce(0, { $0 + weight(me[$1].scalar) }) >= minimumRunWeight { runs.append(run) }
            start = k + 1
        }
        // A few unmatched characters between two runs (a misheard word) go with them.
        var joined: [ClosedRange<Int>] = []
        for run in runs {
            if let previous = joined.last,
                (previous.upperBound + 1..<run.lowerBound).reduce(0, { $0 + weight(me[$1].scalar) }) <= minimumLeftoverWeight
            {
                joined[joined.count - 1] = previous.lowerBound...run.upperBound
            } else {
                joined.append(run)
            }
        }
        let shared = joined.reduce(0) { sum, run in sum + run.reduce(0) { $0 + weight(me[$1].scalar) } }
        let ranges = joined.map { me[$0.lowerBound].index..<text.index(after: me[$0.upperBound].index) }
        return (ranges, shared, total)
    }

    /// `text` without the ranges (and the punctuation and spaces right after each), spaces collapsed, no punctuation
    /// or space left at the start, no comma-like mark left at the end.
    static func removing(_ ranges: [Range<String.Index>], from text: String) -> String {
        let separators = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters)
        var result = text
        for range in ranges.reversed() {
            var end = range.upperBound
            while end < result.endIndex, result[end].unicodeScalars.allSatisfy(separators.contains) {
                end = result.index(after: end)
            }
            // A space only where two words would otherwise run together.
            let before = range.lowerBound == result.startIndex ? nil : result[result.index(before: range.lowerBound)]
            let joinsWords = before.map { !$0.unicodeScalars.allSatisfy(separators.contains) } ?? false
            result.replaceSubrange(range.lowerBound..<end, with: joinsWords && end < result.endIndex ? " " : "")
        }
        let collapsed = result.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let start = collapsed.drop { $0.unicodeScalars.allSatisfy(separators.contains) }
        return String(start).trimmingCharacters(in: CharacterSet(charactersIn: ",，、;；:： ").union(.whitespacesAndNewlines))
    }

    // MARK: - Decision

    enum Verdict: Equatable {
        case keep
        /// The whole piece is the other side's voice.
        case echo
        /// The user spoke too; this is what's left once the other side's words are cut out.
        case trim(String)
    }

    /// Less echo than this in a piece: it isn't touched.
    static let minimumEcho: TimeInterval = 0.5
    /// Less of the user's own voice than this: the whole piece is echo, whatever was transcribed.
    static let minimumOwnSpeech: TimeInterval = 0.5
    /// Less than this, and half the text is the other side's too: the whole piece is echo.
    static let littleOwnSpeech: TimeInterval = 3

    static func verdict(text: String, evidence: Evidence, others: String) -> Verdict {
        guard evidence.echo >= minimumEcho else { return .keep }
        if evidence.own < minimumOwnSpeech { return .echo }
        let shared = sharedRuns(text, others: others)
        guard !shared.ranges.isEmpty else { return .keep }
        if evidence.own < littleOwnSpeech, shared.weight * 2 >= shared.total { return .echo }
        let left = removing(shared.ranges, from: text)
        return normalized(left).reduce(0) { $0 + weight($1.scalar) } < minimumLeftoverWeight ? .echo : .trim(left)
    }

    /// Marks and trims the "Me" pieces that are echo, from the meeting's two recorded channels. Pieces that no
    /// "Others" piece overlaps, failed pieces, and every piece when the speakers don't reach the microphone, are
    /// returned as they are. `trace` prints each decision (meeting-echo-check).
    static func removeEcho(from segments: [MeetingSegment], mic: [Float], system: [Float], trace: Bool = false) -> [MeetingSegment] {
        guard let coupling = coupling(mic: mic, system: system) else { return segments }
        let predicted = predictedEcho(system, count: min(mic.count, system.count), lag: coupling.lag)
        let others = segments.filter { $0.speaker == .others }
        return segments.map { segment in
            guard segment.speaker == .me, !segment.isFailed, !segment.isEcho else { return segment }
            let overlapping = others.filter { $0.start < segment.end + 2 && $0.end > segment.start - 2 }
            guard !overlapping.isEmpty else { return segment }
            let evidence = evidence(mic: mic, predicted: predicted, coupling: coupling, from: segment.start, to: segment.end)
            let text = overlapping.filter { !$0.isFailed }.map(\.text).joined(separator: " ")
            var result = segment
            let decision = verdict(text: segment.text, evidence: evidence, others: text)
            if trace {
                print(String(format: "meeting-check: echo me %.0f-%.0fs own %.1fs echo %.1fs -> %@",
                    segment.start, segment.end, evidence.own, evidence.echo, "\(decision)"))
            }
            switch decision {
            case .keep: return segment
            case .echo: result.echo = true
            case .trim(let left):
                result.textWithEcho = segment.text
                result.text = left
            }
            return result
        }
    }

    /// `removeEcho` on a meeting folder's mic.wav and system.wav.
    static func removeEcho(from segments: [MeetingSegment], folder: URL) -> [MeetingSegment] {
        guard segments.contains(where: { $0.speaker == .me }), segments.contains(where: { $0.speaker == .others })
        else { return segments }
        let mic = energies(of: folder.appendingPathComponent("mic.wav"))
        let system = energies(of: folder.appendingPathComponent("system.wav"))
        #if DEBUG
            let trace = CommandLine.arguments.contains("--meeting-files")
            if trace, let search = lagSearch(mic: mic, system: system) {
                print(String(format: "meeting-check: echo coupling %@: lag %d ms, spread %.1f dB (typical %.1f), heard %.0f%%",
                    coupling(mic: mic, system: system) == nil ? "none" : "found", search.lag * 20, search.spread,
                    search.typicalSpread, search.heard * 100))
            }
        #else
            let trace = false
        #endif
        return removeEcho(from: segments, mic: mic, system: system, trace: trace)
    }
}

#if DEBUG
    extension MeetingEcho {
        static func selfCheck() {
            // A frame: at the noise floor it's nobody; the user only 6 dB above the predicted echo.
            assert(isOwnSpeech(mic: 0.9e-6, echo: 0, floor: 1e-6) == nil)
            assert(isOwnSpeech(mic: 1e-3, echo: 0, floor: 1e-6) == true)
            assert(isOwnSpeech(mic: 1e-3, echo: 1e-3 / 4.1, floor: 1e-6) == true)
            assert(isOwnSpeech(mic: 1e-3, echo: 1e-3 / 3.9, floor: 1e-6) == false)
            // The room's noise is the quietest tenth of the microphone; 10 dB above it is the floor.
            assert(abs(noiseFloor([Float](repeating: 1e-6, count: 20) + [Float](repeating: 1e-2, count: 80)) - 1e-5) < 1e-9)

            // Text: case, width and punctuation don't matter; Chinese counts from 4 characters, Latin from 8.
            assert(normalized("Ｋ８s，好！").map { Character($0.scalar) } == ["k", "8", "s", "好"])
            assert(sharedRuns("我们周四发布", others: "他说我们周四发布吧").ranges.count == 1)
            assert(sharedRuns("周四发布", others: "周四发布").weight == 8)
            assert(sharedRuns("周四发", others: "周四发布").ranges.isEmpty)
            assert(sharedRuns("Ship it Friday!", others: "we ship it friday").ranges.count == 1)
            assert(sharedRuns("ship it", others: "ship it").ranges.isEmpty)
            assert(sharedRuns("完全不同的话", others: "Totally different words").ranges.isEmpty)
            // A misheard word between two shared stretches goes with them.
            let joined = sharedRuns("先看一下 CI 然后周四发布", others: "先看一下 CD 然后周四发布")
            assert(joined.ranges.count == 1 && removing(joined.ranges, from: "先看一下 CI 然后周四发布").isEmpty)
            let sentence = "好的，那我们周四发布，我来写文档。"
            assert(removing(sharedRuns(sentence, others: "那我们周四发布").ranges, from: sentence) == "好的，我来写文档。")
            let english = "ok, we ship it on Friday, then I test"
            assert(removing(sharedRuns(english, others: "We ship it on Friday.").ranges, from: english) == "ok, then I test")

            // The decision's boundaries.
            let echoText = "The customer asked for the export in CSV"
            assert(verdict(text: echoText, evidence: .init(own: 0, echo: 0.4), others: echoText) == .keep)
            assert(verdict(text: "我在说别的", evidence: .init(own: 0.4, echo: 5), others: echoText) == .echo)
            assert(verdict(text: echoText, evidence: .init(own: 2.9, echo: 5), others: echoText) == .echo)
            assert(verdict(text: "我在说别的事情", evidence: .init(own: 2.9, echo: 5), others: echoText) == .keep)
            assert(verdict(text: echoText + "，我觉得可以", evidence: .init(own: 8, echo: 5), others: echoText) == .trim("我觉得可以"))
            assert(verdict(text: echoText, evidence: .init(own: 8, echo: 5), others: echoText) == .echo)

            // Signal: a microphone that is the system audio 3 frames later and 15 dB quieter, plus the user alone.
            var system = [Float](repeating: 0, count: 1500), mic = [Float](repeating: 0, count: 1500)
            for t in 0..<1500 where (t / 40) % 3 != 2 { system[t] = 1e-2 * Float(1 + (t * 7919) % 13) }
            for t in 3..<1500 { mic[t] = system[t - 3] * 0.03 }
            for t in 1200..<1300 { system[t] = 0; mic[t] = 5e-3 }
            guard let found = coupling(mic: mic, system: system) else { return assertionFailure("no coupling found") }
            // The prediction takes the loudest frame around the delay, so the gain comes out at or below 0.03.
            assert((2...4).contains(found.lag) && found.gain > 0.005 && found.gain <= 0.03)
            let predicted = predictedEcho(system, count: 1500, lag: found.lag)
            let echoOnly = evidence(mic: mic, predicted: predicted, coupling: found, from: 0, to: 20)
            let alone = evidence(mic: mic, predicted: predicted, coupling: found, from: 24.2, to: 25.8)
            assert(echoOnly.own < 0.2 && echoOnly.echo > 10 && alone.own > 1.4 && alone.echo < 0.1)
            // Headphones: the microphone has only the user, while the others are quiet. No coupling, nothing removed.
            var headphones = [Float](repeating: 0, count: 1500)
            for t in 0..<1500 where (t / 40) % 3 == 2 { headphones[t] = 4e-3 }
            assert(coupling(mic: headphones, system: system) == nil)
            let segments = [
                MeetingSegment(speaker: .me, start: 0, end: 20, text: "we ship it friday"),
                MeetingSegment(speaker: .others, start: 0, end: 20, text: "we ship it friday"),
            ]
            assert(removeEcho(from: segments, mic: headphones, system: system) == segments)
            let removed = removeEcho(from: segments, mic: mic, system: system)
            assert(removed[0].isEcho && removed[1] == segments[1])
            assert(MeetingNotes.transcript(removed) == MeetingNotes.transcript([segments[1]]))

            // segments.json: the echo marks round-trip, and an old file without them reads as not echo.
            var trimmed = MeetingSegment(speaker: .me, start: 1, end: 2, text: "left")
            trimmed.textWithEcho = "echo left"
            let coded = try? JSONDecoder().decode([MeetingSegment].self, from: JSONEncoder().encode([removed[0], trimmed]))
            assert(coded?.map(\.isEcho) == [true, false] && coded?[1].textWithEcho == "echo left")
            let old = #"{"speaker":"me","start":1,"end":2,"text":"hi"}"#
            let decoded = try? JSONDecoder().decode(MeetingSegment.self, from: Data(old.utf8))
            assert(decoded?.isEcho == false && decoded?.textWithEcho == nil)
        }
    }
#endif
