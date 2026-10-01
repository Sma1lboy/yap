import Foundation

/// whisper.cpp's `whisper_vad_segments_from_probs` (src/whisper.cpp, whisper.cpp d09f61a7), line for line, in
/// centiseconds. whisper.cpp only takes the probabilities it computed in its last `whisper_vad_detect_speech*` call,
/// and WhisperContext computes them a piece at a time so a cancel can stop it in between; this turns the joined
/// probabilities into the same segments. `make lifecycle-check` compares both, segment for segment, on real audio.
enum WhisperSpeechSegments {
    struct Params {
        var threshold: Float
        var minSpeechDurationMs: Int
        var minSilenceDurationMs: Int
        var maxSpeechDurationS: Float
        var speechPadMs: Int
    }

    static func segments(probs: [Float], window: Int, params: Params) -> [(start: Int64, end: Int64)] {
        let sampleRate = 16_000
        let minSilenceSamples = sampleRate * params.minSilenceDurationMs / 1000
        let audioLengthSamples = probs.count * window
        let minSpeechSamples = sampleRate * params.minSpeechDurationMs / 1000
        let speechPadSamples = sampleRate * params.speechPadMs / 1000
        let maxSpeechSamples: Int
        if params.maxSpeechDurationS > 100_000 {
            maxSpeechSamples = Int(Int32.max) / 2
        } else {
            let temp = Int64(sampleRate) * Int64(params.maxSpeechDurationS) - Int64(window) - 2 * Int64(speechPadSamples)
            maxSpeechSamples = temp > Int64(Int32.max) || temp < 0 ? Int(Int32.max) / 2 : Int(temp)
        }
        let minSilenceSamplesAtMaxSpeech = sampleRate * 98 / 1000
        let negThreshold = max(params.threshold - 0.15, 0.01)

        var speeches: [(start: Int, end: Int)] = []
        var isSpeechSegment = false
        var tempEnd = 0
        var prevEnd = 0
        var nextStart = 0
        var currSpeechStart = 0
        var hasCurrSpeech = false

        for (i, currProb) in probs.enumerated() {
            let currSample = window * i
            if currProb >= params.threshold && tempEnd != 0 {
                tempEnd = 0
                if nextStart < prevEnd { nextStart = currSample }
            }
            if currProb >= params.threshold && !isSpeechSegment {
                isSpeechSegment = true
                currSpeechStart = currSample
                hasCurrSpeech = true
                continue
            }
            if isSpeechSegment && (currSample - currSpeechStart) > maxSpeechSamples {
                if prevEnd != 0 {
                    speeches.append((currSpeechStart, prevEnd))
                    hasCurrSpeech = true
                    if nextStart < prevEnd {
                        isSpeechSegment = false
                        hasCurrSpeech = false
                    } else {
                        currSpeechStart = nextStart
                    }
                    prevEnd = 0
                    nextStart = 0
                    tempEnd = 0
                } else {
                    speeches.append((currSpeechStart, currSample))
                    prevEnd = 0
                    nextStart = 0
                    tempEnd = 0
                    isSpeechSegment = false
                    hasCurrSpeech = false
                    continue
                }
            }
            if currProb < negThreshold && isSpeechSegment {
                if tempEnd == 0 { tempEnd = currSample }
                if (currSample - tempEnd) > minSilenceSamplesAtMaxSpeech { prevEnd = tempEnd }
                if (currSample - tempEnd) < minSilenceSamples { continue }
                if (tempEnd - currSpeechStart) > minSpeechSamples { speeches.append((currSpeechStart, tempEnd)) }
                prevEnd = 0
                nextStart = 0
                tempEnd = 0
                isSpeechSegment = false
                hasCurrSpeech = false
                continue
            }
        }
        if hasCurrSpeech && (audioLengthSamples - currSpeechStart) > minSpeechSamples {
            speeches.append((currSpeechStart, audioLengthSamples))
        }

        // Merge segments less than 200 ms apart.
        var i = 0
        while i < speeches.count - 1 {
            if speeches[i + 1].start - speeches[i].end < sampleRate * 200 / 1000 {
                speeches[i].end = speeches[i + 1].end
                speeches.remove(at: i + 1)
            } else {
                i += 1
            }
        }
        speeches.removeAll { $0.end - $0.start < minSpeechSamples }

        for i in speeches.indices {
            if i == 0 {
                speeches[i].start = speeches[i].start > speechPadSamples ? speeches[i].start - speechPadSamples : 0
            }
            if i < speeches.count - 1 {
                let silence = speeches[i + 1].start - speeches[i].end
                if silence < 2 * speechPadSamples {
                    speeches[i].end += silence / 2
                    speeches[i + 1].start = speeches[i + 1].start > silence / 2 ? speeches[i + 1].start - silence / 2 : 0
                } else {
                    speeches[i].end = min(speeches[i].end + speechPadSamples, audioLengthSamples)
                    speeches[i + 1].start =
                        speeches[i + 1].start > speechPadSamples ? speeches[i + 1].start - speechPadSamples : 0
                }
            } else {
                speeches[i].end = min(speeches[i].end + speechPadSamples, audioLengthSamples)
            }
        }
        return speeches.map { (centiseconds($0.start), centiseconds($0.end)) }
    }

    /// whisper.cpp's `samples_to_cs`.
    private static func centiseconds(_ samples: Int) -> Int64 {
        Int64((Double(samples) / 16_000) * 100 + 0.5)
    }
}
