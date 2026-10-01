#if DEBUG
    import Foundation

    /// `make edit-rate-check`: prints what Auto Learn records for each paste fixture (FinalSnapshotDiffEngine.fixtures)
    /// and runs the correction-rate self-checks, then exits. Nothing is read from any app; the
    /// fixtures are field contents written out in the code.
    enum EditRateCheck {
        static let argument = "--edit-rate-check"

        static func runIfRequested() {
            guard CommandLine.arguments.contains(argument) else { return }
            for fixture in FinalSnapshotDiffEngine.fixtures {
                let outcome = FinalSnapshotDiffEngine.observe(fixture.snapshot)
                var line: [String: Any] = [
                    "fixture": fixture.name,
                    "pasted": fixture.snapshot.originalPastedText,
                    "final": fixture.snapshot.finalFieldText,
                ]
                switch outcome {
                case .observed(let distance):
                    line["observed"] = true
                    line["changed"] = distance > 0
                    line["distance"] = String(format: "%.3f", distance)
                case .unobservable(let reason):
                    line["observed"] = false
                    line["reason"] = reason.rawValue
                }
                line["expected"] = outcome == fixture.expected || {
                    if case .observed(let a) = outcome, case .observed(let b) = fixture.expected { return abs(a - b) < 1e-9 }
                    return false
                }()
                let candidates = FinalSnapshotDiffEngine.revision(from: fixture.snapshot)
                    .map(CorrectionDiffEngine.candidates) ?? []
                line["learningCandidates"] = candidates.map { "\($0.originalText) → \($0.correctedText)" }
                let json = try! JSONSerialization.data(withJSONObject: line, options: [.sortedKeys])
                print("edit-rate-check: \(String(decoding: json, as: UTF8.self))")
            }

            FinalSnapshotDiffEngine.selfCheck()
            print("edit-rate-check: FinalSnapshotDiffEngine.selfCheck ok")
            MainActor.assumeIsolated {
                do { try SessionEditRecorder.selfCheck() } catch { fatalError("SessionEditRecorder: \(error)") }
                print("edit-rate-check: SessionEditRecorder.selfCheck ok")
            }
            fflush(stdout)
            exit(0)
        }
    }
#endif
