import FluidAudio
import Foundation
import os

/// One stretch of one remote speaker, in seconds from the start of the recording.
struct SpeakerTurn: Equatable {
    let id: String
    let start: TimeInterval
    let end: TimeInterval
}

/// Names the remote speakers in a meeting: turns from the diarizer in, "Others 1", "Others 2"… on the transcript out.
enum SpeakerLabels {
    /// A speaker with less speech than this is diarizer noise (a cough, a chair), not a person.
    static let minimumSpeech: TimeInterval = 3

    /// Gives each "others" segment the number of the speaker it overlaps most (numbered by first appearance).
    /// Fewer than two real speakers, or fewer than two of them in the segments: returned unchanged, so a
    /// one-on-one call keeps plain "Others".
    static func assign(_ segments: [MeetingSegment], turns: [SpeakerTurn]) -> [MeetingSegment] {
        var speech: [String: TimeInterval] = [:]
        for turn in turns { speech[turn.id, default: 0] += max(0, turn.end - turn.start) }
        let kept = turns.filter { speech[$0.id, default: 0] >= minimumSpeech }.sorted { $0.start < $1.start }
        var number: [String: Int] = [:]
        for turn in kept where number[turn.id] == nil { number[turn.id] = number.count + 1 }
        guard number.count >= 2 else { return segments }

        let labeled = segments.map { segment -> MeetingSegment in
            guard segment.speaker == .others else { return segment }
            var overlap: [Int: TimeInterval] = [:]
            for turn in kept {
                let shared = min(turn.end, segment.end) - max(turn.start, segment.start)
                if shared > 0, let n = number[turn.id] { overlap[n, default: 0] += shared }
            }
            var result = segment
            result.remote = overlap.max { ($0.value, -$0.key) < ($1.value, -$1.key) }?.key
            return result
        }
        return Set(labeled.compactMap(\.remote)).count >= 2 ? labeled : segments
    }
}

/// Offline speaker diarization (FluidAudio, VBx clustering) of a meeting's system audio, once, after it stops.
enum MeetingDiarizer {
    struct Failure: LocalizedError {
        let errorDescription: String?
    }

    /// Below this the clustering has too little to go on.
    static let minimumDuration: TimeInterval = 15
    static func timeout(forDuration seconds: TimeInterval) -> TimeInterval { 60 + seconds / 2 }
    static let downloadTimeout: TimeInterval = 300

    private static let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "MeetingDiarizer")

    /// Models go into `directory` (Yap's own folder, never FluidAudio's default in Application Support); the first
    /// call downloads them and reports 0…1 through `progress`. Throws on failure or timeout.
    static func turns(
        of system: URL, duration: TimeInterval, directory: URL, progress: @escaping @Sendable (Double) -> Void
    ) async throws -> [SpeakerTurn] {
        let manager = OfflineDiarizerManager()
        let models = try await withTimeout(downloadTimeout) {
            try await OfflineDiarizerModels.load(from: directory) { progress($0.fractionCompleted) }
        }
        manager.initialize(models: models)
        let result = try await withTimeout(timeout(forDuration: duration)) { try await manager.process(system) }
        return result.segments.map {
            SpeakerTurn(id: $0.speakerId, start: TimeInterval($0.startTimeSeconds), end: TimeInterval($0.endTimeSeconds))
        }
    }

    /// Core ML work can't be cancelled, so on timeout it is left running and abandoned.
    // ponytail: a stuck diarization keeps its thread until the process exits; fine for a once-per-meeting step.
    private static func withTimeout<T: Sendable>(
        _ seconds: TimeInterval, _ work: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            let done = OSAllocatedUnfairLock(initialState: false)
            @Sendable func finish(_ result: Result<T, Error>) {
                if done.withLock({ let was = $0; $0 = true; return !was }) { continuation.resume(with: result) }
            }
            Task {
                do { finish(.success(try await work())) } catch { finish(.failure(error)) }
            }
            Task {
                try? await Task.sleep(for: .seconds(seconds))
                finish(.failure(Failure(errorDescription: "timed out after \(Int(seconds)) s")))
            }
        }
    }
}

#if DEBUG
    extension SpeakerLabels {
        static func selfCheck() {
            func turn(_ id: String, _ start: TimeInterval, _ end: TimeInterval) -> SpeakerTurn { .init(id: id, start: start, end: end) }
            func segment(_ speaker: MeetingSegment.Speaker, _ start: TimeInterval, _ end: TimeInterval) -> MeetingSegment {
                .init(speaker: speaker, start: start, end: end, text: "x")
            }
            let segments = [segment(.others, 0, 20), segment(.me, 10, 15), segment(.others, 22, 40), segment(.others, 45, 60)]
            // B speaks first, so B is "Others 1"; each segment takes the speaker it overlaps most.
            let turns = [turn("B", 0, 18), turn("A", 19, 21), turn("A", 23, 40), turn("B", 44, 60)]
            let labeled = assign(segments, turns: turns)
            assert(labeled.map(\.remote) == [1, nil, 2, 1])
            assert(labeled[1].speaker == .me && labeled[1].label == MeetingSegment.Speaker.me.label)

            // One real speaker, or a second one below the minimum: plain "Others".
            assert(assign(segments, turns: [turn("A", 0, 60)]) == segments)
            assert(assign(segments, turns: [turn("A", 0, 50), turn("B", 50, 52)]) == segments)
            assert(assign(segments, turns: []) == segments)
            // Two speakers in the audio but only one in the transcribed segments: also unchanged.
            assert(assign([segment(.others, 0, 20)], turns: [turn("A", 0, 20), turn("B", 30, 50)]) == [segment(.others, 0, 20)])
            // A segment no turn overlaps stays plain "Others".
            assert(assign(segments + [segment(.others, 100, 110)], turns: turns).last?.remote == nil)
            // Old segments.json without the field still decodes.
            let old = #"{"speaker":"others","start":1,"end":2,"text":"hi"}"#
            assert((try? JSONDecoder().decode(MeetingSegment.self, from: Data(old.utf8)))?.remote == nil)
        }
    }
#endif
