import Foundation

/// Splits long audio into windows whisper can decode in one pass.
///
/// whisper_full on audio longer than its 30 s window seeks by the timestamps it predicts; when a
/// window ends mid-segment the seek skips ahead and whole sentences vanish (upstream #853 blamed VAD,
/// but it happens with VAD off too). Decoding each ≤28 s window separately, cut in the middle of
/// pauses, keeps every sentence inside one window.
enum WhisperChunking {
    static let sampleRate = 16_000
    static let maxWindow = 28 * sampleRate
    static let pad = sampleRate / 5
    /// Silero VAD emits one speech probability per 512 samples.
    static let vadHop = 512

    /// `speech`: sorted VAD speech ranges in samples; `probs`: Silero's per-hop speech probabilities,
    /// used to cut runs of speech longer than a window at their quietest moment. With `keepSilence` the
    /// windows tile the whole recording (VAD off: nothing is dropped); otherwise each window is trimmed
    /// to its speech ± `pad` and windows without speech are dropped.
    static func windows(
        speech: [Range<Int>], probs: [Float] = [], total: Int, maxWindow: Int = maxWindow, pad: Int = pad,
        keepSilence: Bool
    ) -> [Range<Int>] {
        guard total > 0 else { return [] }
        let cuts = zip(speech, speech.dropFirst()).map { ($0.upperBound + $1.lowerBound) / 2 }

        var tiles: [Range<Int>] = []
        var pos = 0
        while pos < total {
            let limit = pos + maxWindow
            if limit >= total {
                tiles.append(pos..<total)
                break
            }
            // No pause within reach (one long run of speech): cut at the quietest moment in the
            // second half of the window, or at the window size when there are no probabilities.
            let cut = cuts.last { $0 > pos && $0 <= limit }
                ?? quietestPoint(probs, in: (pos + maxWindow / 2)..<limit) ?? limit
            tiles.append(pos..<cut)
            pos = cut
        }
        if keepSilence { return tiles }

        return tiles.compactMap { tile in
            let inside = speech.filter { $0.overlaps(tile) }
            guard let first = inside.first, let last = inside.last else { return nil }
            return max(tile.lowerBound, first.lowerBound - pad)..<min(tile.upperBound, last.upperBound + pad)
        }
    }

    /// Sample offset (a hop boundary inside `range`) with the lowest speech probability.
    static func quietestPoint(_ probs: [Float], in range: Range<Int>, hop: Int = vadHop) -> Int? {
        let first = max(0, (range.lowerBound + hop - 1) / hop), end = min(probs.count, range.upperBound / hop)
        guard first < end, let quietest = (first..<end).min(by: { probs[$0] < probs[$1] }) else { return nil }
        return quietest * hop
    }

    /// Joins neighbouring pieces decoded in the same language, so a split only happens where the
    /// language actually changes.
    static func mergeRuns(_ pieces: [(range: Range<Int>, language: String)]) -> [(range: Range<Int>, language: String)] {
        pieces.reduce(into: []) { runs, piece in
            if let last = runs.last, last.language == piece.language, last.range.upperBound == piece.range.lowerBound {
                runs[runs.count - 1].range = last.range.lowerBound..<piece.range.upperBound
            } else {
                runs.append(piece)
            }
        }
    }

    #if DEBUG
        static func selfCheck() {
            let s = 100  // 1 "second" = 100 samples keeps the numbers readable
            func w(_ speech: [Range<Int>], _ total: Int, keep: Bool, probs: [Float] = []) -> [Range<Int>] {
                windows(speech: speech, probs: probs, total: total, maxWindow: 28 * s, pad: s / 5, keepSilence: keep)
            }
            // Short audio: one window; VAD trims leading/trailing silence.
            assert(w([2 * s..<10 * s], 20 * s, keep: true) == [0..<20 * s])
            assert(w([2 * s..<10 * s], 20 * s, keep: false) == [180..<1020])
            // No speech: VAD on decodes nothing, VAD off still decodes everything.
            assert(w([], 20 * s, keep: false) == [])
            assert(w([], 60 * s, keep: true) == [0..<28 * s, 28 * s..<56 * s, 56 * s..<60 * s])
            // 70 s of speech with pauses every 10 s: cuts land in pauses, windows ≤ 28 s, tiles cover all.
            let speech = (0..<7).map { i in (i * 10 * s + 50)..<((i + 1) * 10 * s - 50) }
            let tiles = w(speech, 70 * s, keep: true)
            assert(tiles.first?.lowerBound == 0 && tiles.last?.upperBound == 70 * s)
            assert(zip(tiles, tiles.dropFirst()).allSatisfy { $0.upperBound == $1.lowerBound })
            assert(tiles.allSatisfy { $0.count <= 28 * s })
            assert(tiles.dropLast().allSatisfy { $0.upperBound % (10 * s) == 0 })  // cut mid-pause
            // Every speech sample stays in exactly one VAD-on window.
            let trimmed = w(speech, 70 * s, keep: false)
            for seg in speech {
                assert(seg.allSatisfy { x in trimmed.filter { $0.contains(x) }.count == 1 })
            }
            // One unbroken 70 s run without probabilities: hard cuts, nothing lost.
            assert(w([0..<70 * s], 70 * s, keep: false) == [0..<28 * s, 28 * s..<56 * s, 56 * s..<70 * s])
            // With probabilities (hop 512): the cut moves to the quietest hop in the window's second half.
            var probs = [Float](repeating: 0.9, count: 70 * s / vadHop)
            probs[4] = 0.1  // sample 2048, inside 1400..<2800
            assert(w([0..<70 * s], 70 * s, keep: true, probs: probs).first == 0..<2048)
            assert(quietestPoint(probs, in: 0..<1100) == 0)
            assert(quietestPoint(probs, in: 100..<1100) == 512)  // hop boundaries inside the range only
            assert(quietestPoint(probs, in: 69 * s..<80 * s) == nil)  // past the last probability
            assert(quietestPoint([], in: 0..<1000) == nil)

            let runs = mergeRuns([(0..<10, "en"), (10..<20, "en"), (20..<30, "zh"), (30..<40, "en")])
            assert(runs.map(\.range) == [0..<20, 20..<30, 30..<40] && runs.map(\.language) == ["en", "zh", "en"])
        }
    #endif
}
