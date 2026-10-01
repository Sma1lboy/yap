import Foundation

/// Work on a local model, one at a time in the order it asked: each transcription and each release (idle, memory
/// pressure, Quit), and for Whisper the switch to another model. A release or another model's load then waits for
/// the transcription in its turn instead of freeing what it uses, and transcriptions that keep their state on one
/// shared object (a WhisperContext, FluidAudio's Nemotron and Unified managers) don't mix. Lock-based, so taking a
/// free turn doesn't wait for any actor. Used by WhisperModelManager and FluidAudioTranscriptionService.
final class ModelTurns: @unchecked Sendable {
    private let lock = NSLock()
    private var busy = false
    private var waiting: [(id: UInt64, turn: CheckedContinuation<Void, Error>)] = []
    private var lastID: UInt64 = 0
    private var closed = false

    /// Set by Quit: every turn from then on fails without touching a model.
    var isClosed: Bool { lock.withLock { closed } }
    func close() { lock.withLock { closed = true } }

    /// A release's turn: waits however long it takes, cancelled or not.
    func take() async {
        try? await take(cancellable: false)
    }

    /// A transcription's turn. Cancelled while it waits, it leaves the queue and throws CancellationError: it
    /// never holds the turn, and the ones behind it move up.
    func take(cancellable: Bool) async throws {
        let id = lock.withLock { () -> UInt64 in
            lastID &+= 1
            return lastID
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (turn: CheckedContinuation<Void, Error>) in
                let outcome = lock.withLock { () -> Bool? in
                    // Checked under the lock the handler takes too, so a cancel can't fall between the two.
                    if cancellable && Task.isCancelled { return nil }
                    guard busy else {
                        busy = true
                        return true
                    }
                    waiting.append((id, turn))
                    return false
                }
                switch outcome {
                case nil: turn.resume(throwing: CancellationError())
                case true?: turn.resume()
                case false?: break
                }
            }
        } onCancel: {
            guard cancellable else { return }
            let left = lock.withLock { () -> CheckedContinuation<Void, Error>? in
                guard let index = waiting.firstIndex(where: { $0.id == id }) else { return nil }
                return waiting.remove(at: index).turn
            }
            left?.resume(throwing: CancellationError())
        }
    }

    func give() {
        let next = lock.withLock { () -> CheckedContinuation<Void, Error>? in
            guard !waiting.isEmpty else {
                busy = false
                return nil
            }
            return waiting.removeFirst().turn
        }
        next?.resume()
    }
}
