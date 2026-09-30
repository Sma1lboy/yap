#if DEBUG
    import AppKit

    /// `make meeting-call-check`: launched with `--meeting-call-check`, the app runs the call detector's self-check,
    /// prints every process that Core Audio says is using the microphone right now with what the detector makes of
    /// it (a call app, a browser, Yap itself, or nothing), and quits before touching any settings or data. A manual
    /// check: start a call in Zoom, FaceTime or a browser and run it (docs/meeting-recording.md).
    @MainActor
    enum MeetingCallCheck {
        static let argument = "--meeting-call-check"

        static func runIfRequested() {
            guard CommandLine.arguments.contains(argument) else { return }
            MeetingCallPolicy.selfCheck()
            print("meeting-call-check: self-check ok")
            let policy = MeetingCallPolicy(ownPID: getpid())
            let objects = AudioProcessList.objects()
            let using = objects.filter(AudioProcessList.isRunningInput).compactMap(AudioProcessList.process)
            print("meeting-call-check: \(objects.count) audio processes, \(using.count) using the microphone")
            for process in using {
                let result: String
                if process.pid == getpid() || process.responsiblePID == getpid() {
                    result = "Yap itself, ignored"
                } else if let app = policy.callApps([process]).first {
                    result = "\(app.isBrowser ? "browser" : "call app") \(app.name): \"\(app.askMessage)\""
                } else {
                    result = "not a call app"
                }
                let responsible = process.responsiblePID == process.pid
                    ? "" : " (for pid \(process.responsiblePID) \(process.responsibleBundleID ?? "?"))"
                print("meeting-call-check: pid \(process.pid) \(process.bundleID ?? "?")\(responsible) → \(result)")
            }
            print("meeting-call-check: detection is \(MeetingCallDetector.isEnabled() ? "on" : "off") in this app's settings")
            fflush(stdout)
            exit(0)
        }
    }
#endif
