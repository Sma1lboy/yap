import Foundation

/// Decides whether a cancel press discards the recording now or first asks for a second press.
enum CancelConfirmation {
    /// Recordings at least this long ask before being discarded.
    static let longRecordingSeconds: TimeInterval = 15
    /// The second press must land within this many seconds of the first.
    static let confirmWindow: TimeInterval = 3

    enum Decision: Equatable { case discard, askAgain }

    static func isLong(isRecording: Bool, elapsed: TimeInterval) -> Bool {
        isRecording && elapsed >= longRecordingSeconds
    }

    static func decide(isRecording: Bool, elapsed: TimeInterval, sinceFirstPress: TimeInterval?) -> Decision {
        if let s = sinceFirstPress, s <= confirmWindow { return .discard }
        return isLong(isRecording: isRecording, elapsed: elapsed) ? .askAgain : .discard
    }

    #if DEBUG
        static func selfCheck() {
            assert(decide(isRecording: true, elapsed: 5, sinceFirstPress: nil) == .discard)
            assert(decide(isRecording: true, elapsed: 15, sinceFirstPress: nil) == .askAgain)
            assert(decide(isRecording: true, elapsed: 120, sinceFirstPress: 2) == .discard)
            assert(decide(isRecording: true, elapsed: 120, sinceFirstPress: 4) == .askAgain)
            assert(decide(isRecording: false, elapsed: 120, sinceFirstPress: nil) == .discard)
        }
    #endif
}
