import AppKit
import Combine
import CoreAudio
import os

/// An app whose use of the microphone suggests a call. Recognized by bundle ID, of the process itself or of the app
/// responsible for it (Chrome's helpers, Safari's shared WebKit GPU process). A browser only tells us that it's
/// using the microphone, not that it's in a meeting, so its prompt says just that.
struct MeetingCallApp: Hashable {
    let id: String
    let name: String
    let isBrowser: Bool

    /// Every recognized app. Add a row to support another one; bundle IDs are matched whole, case-insensitively.
    static var table: [(bundleIDs: [String], app: MeetingCallApp)] {
        func meeting(_ name: String, _ ids: String...) -> ([String], MeetingCallApp) {
            (ids, MeetingCallApp(id: ids[0], name: name, isBrowser: false))
        }
        func browser(_ name: String, _ ids: String...) -> ([String], MeetingCallApp) {
            (ids, MeetingCallApp(id: ids[0], name: name, isBrowser: true))
        }
        return [
            meeting("Zoom", "us.zoom.xos"),
            meeting("Microsoft Teams", "com.microsoft.teams2", "com.microsoft.teams"),
            meeting("Webex", "Cisco-Systems.Spark", "com.webex.meetingmanager"),
            meeting("Slack", "com.tinyspeck.slackmacgap"),
            meeting("Discord", "com.hnc.Discord"),
            // A FaceTime call's audio runs in the avconferenced daemon; the FaceTime app itself doesn't open the mic.
            meeting("FaceTime", "com.apple.FaceTime", "com.apple.avconferenced"),
            meeting("Skype", "com.skype.skype"),
            meeting(String(localized: "Feishu"), "com.bytedance.macos.feishu"),
            meeting("Lark", "com.larksuite.larkApp", "com.electron.lark"),
            meeting(String(localized: "Tencent Meeting"), "com.tencent.meeting"),
            meeting("VooV Meeting", "com.tencent.tencentmeeting"),
            meeting(String(localized: "DingTalk"), "com.alibaba.DingTalkMac"),
            browser("Google Chrome", "com.google.Chrome"),
            browser("Safari", "com.apple.Safari"),
            browser("Arc", "company.thebrowser.Browser"),
            browser("Microsoft Edge", "com.microsoft.edgemac"),
            browser("Firefox", "org.mozilla.firefox"),
            browser("Brave", "com.brave.Browser"),
        ]
    }

    static func recognize(_ process: MicrophoneProcess) -> MeetingCallApp? {
        let table = table
        for bundleID in [process.responsibleBundleID, process.bundleID].compactMap({ $0?.lowercased() }) {
            if let row = table.first(where: { $0.bundleIDs.contains { $0.lowercased() == bundleID } }) { return row.app }
        }
        return nil
    }

    /// "Zoom is on a call. Record this meeting?"; a browser is only said to use the microphone.
    var askMessage: String {
        String(
            format: isBrowser
                ? String(localized: "%@ is using the microphone. Record this meeting?")
                : String(localized: "%@ is on a call. Record this meeting?"),
            name)
    }

    static var endMessage: String {
        String(localized: "The call seems to have ended. Click ✓ to end the meeting and save it.")
    }
}

/// A process that Core Audio says is running audio input.
struct MicrophoneProcess: Equatable {
    let pid: pid_t
    let bundleID: String?
    /// The app macOS holds responsible for the process (Chrome for its helper); the process itself when it has none.
    let responsiblePID: pid_t
    let responsibleBundleID: String?
}

/// When to offer recording a call and when to say it seems to have ended, from snapshots of which processes use the
/// microphone. Pure: `update` is given the time, so the self-check plays whole calls in a few lines.
/// - Ask once per call, after its app has held the microphone for `startDelay`, and only when Yap isn't recording or
///   finishing a meeting, isn't showing the consent note, isn't dictating and has no notification on screen (then the
///   prompt waits; it isn't dropped). A call is over, and the next one is asked about again, once its app has left
///   the microphone for `endDelay`; a shorter gap (a device switch) is the same call.
/// - During a recording, the call apps on the microphone when it started (the one that was asked about included) or
///   later are watched; when all of them have left the microphone for `endDelay`, say so once. Nothing is stopped:
///   only ✓ ends a meeting.
struct MeetingCallPolicy {
    static let startDelay: TimeInterval = 5
    static let endDelay: TimeInterval = 10

    struct YapState {
        var meeting: MeetingRecorder.Phase = .idle
        var isDictating = false
        var isShowingNotification = false
    }

    enum Action: Equatable {
        case none
        case askToRecord(MeetingCallApp)
        case remindToEnd(MeetingCallApp)
    }

    private struct Call {
        let app: MeetingCallApp
        var onSince: Date?
        var offSince: Date?
        var asked = false
    }

    let ownPID: pid_t
    private var calls: [String: Call] = [:]
    private var watched: Set<String> = []
    private var remindedEnd = false
    private var wasRecording = false

    init(ownPID: pid_t) { self.ownPID = ownPID }

    /// The call apps among `processes`, without Yap itself.
    func callApps(_ processes: [MicrophoneProcess]) -> [MeetingCallApp] {
        var apps: [MeetingCallApp] = []
        for process in processes where process.pid != ownPID && process.responsiblePID != ownPID {
            if let app = MeetingCallApp.recognize(process), !apps.contains(app) { apps.append(app) }
        }
        return apps
    }

    mutating func update(_ processes: [MicrophoneProcess], yap: YapState, now: Date) -> Action {
        let active = callApps(processes)
        let activeIDs = Set(active.map(\.id))
        for app in active {
            var call = calls[app.id] ?? Call(app: app)
            if call.onSince == nil { call.onSince = now }
            call.offSince = nil
            calls[app.id] = call
        }
        for (id, var call) in calls where !activeIDs.contains(id) {
            let offSince = call.offSince ?? now
            call.offSince = offSince
            call.onSince = nil
            calls[id] = now.timeIntervalSince(offSince) >= Self.endDelay && !watched.contains(id) ? nil : call
        }

        let recording = yap.meeting.isRecording
        if recording {
            if !wasRecording {
                watched = Set(calls.filter { $0.value.onSince != nil || $0.value.asked }.keys)
                remindedEnd = false
            }
            for id in activeIDs {
                watched.insert(id)
                calls[id]?.asked = true
            }
        } else if wasRecording {
            watched = []
            remindedEnd = false
        }
        wasRecording = recording
        let canShow = !yap.isDictating && !yap.isShowingNotification

        if recording {
            let watchedCalls = watched.compactMap { calls[$0] }
            if watchedCalls.contains(where: { $0.onSince != nil }) {
                remindedEnd = false
                return .none
            }
            guard !remindedEnd, canShow,
                let last = watchedCalls.max(by: { ($0.offSince ?? .distantPast) < ($1.offSince ?? .distantPast) }),
                let offSince = last.offSince, now.timeIntervalSince(offSince) >= Self.endDelay
            else { return .none }
            remindedEnd = true
            return .remindToEnd(last.app)
        }

        switch yap.meeting {
        case .idle, .done: break
        case .consent, .recording, .finishing: return .none
        }
        guard canShow else { return .none }
        let due = calls.values
            .filter { call in !call.asked && call.onSince.map { now.timeIntervalSince($0) >= Self.startDelay } == true }
            .sorted { a, b in
                (a.app.isBrowser ? 1 : 0, a.onSince ?? now) < (b.app.isBrowser ? 1 : 0, b.onSince ?? now)
            }
        guard let pick = due.first else { return .none }
        // Every app on the microphone now is part of this call: one prompt, not one per app.
        for id in activeIDs { calls[id]?.asked = true }
        return .askToRecord(pick.app)
    }

    /// When `update` should run again though nothing changed: a call's `startDelay` or `endDelay` running out. Nil
    /// when only an event can change the answer (a deferred prompt waits for the dictation or notification to end).
    func nextCheck(after now: Date) -> Date? {
        calls.values.compactMap { call -> Date? in
            if let on = call.onSince { return call.asked ? nil : on.addingTimeInterval(Self.startDelay) }
            return call.offSince?.addingTimeInterval(Self.endDelay)
        }
        .filter { $0 > now }
        .min()
    }
}

/// Watches which processes use the microphone (Core Audio's process objects, macOS 14.2+) and runs
/// MeetingCallPolicy on every change: one listener on the process list and one on each process's "running input".
/// No polling; a one-shot timer runs only until the next `startDelay` / `endDelay` is due. After sleep the listeners
/// are set up again. With the setting off, no audio listener or observer is registered (only the one that notices
/// the setting turning on).
@MainActor
final class MeetingCallDetector {
    static let shared = MeetingCallDetector()
    static let enabledKey = "meetingCallDetection"

    /// Unset: on for anyone who has recorded a meeting (accepted the consent note), off for dictation-only users.
    static func isEnabled(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: enabledKey) as? Bool ?? defaults.bool(forKey: MeetingRecorder.consentShownKey)
    }

    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "MeetingCallDetector")
    private weak var engine: VoiceInkEngine?
    private var policy = MeetingCallPolicy(ownPID: getpid())
    private var processes: [AudioObjectID: MicrophoneProcess] = [:]
    private var inputListeners: [AudioObjectID: AudioObjectPropertyListenerBlock] = [:]
    private var listListener: AudioObjectPropertyListenerBlock?
    private var observers: [NSObjectProtocol] = []
    private var subscriptions: Set<AnyCancellable> = []
    private var checkTimer: Timer?
    private var settingObserver: NSObjectProtocol?

    func configure(engine: VoiceInkEngine) {
        self.engine = engine
        settingObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.applySetting() }
        }
        applySetting()
    }

    private var isRunning: Bool { listListener != nil }

    private func applySetting() {
        let enabled = Self.isEnabled()
        if enabled, !isRunning {
            start()
        } else if !enabled, isRunning {
            stop()
        }
    }

    private func start() {
        logger.notice("Call detection on")
        policy = MeetingCallPolicy(ownPID: getpid())
        addAudioListeners()
        observers = [
            NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.isRunning else { return }
                    self.removeAudioListeners()
                    self.addAudioListeners()
                }
            },
            NotificationCenter.default.addObserver(forName: .appNotificationDismissed, object: nil, queue: .main) {
                [weak self] _ in
                MainActor.assumeIsolated { self?.evaluate() }
            },
        ]
        // @Published sends before the property changes; evaluate once it has, on the next turn of the main queue.
        engine?.$recordingState.removeDuplicates().receive(on: DispatchQueue.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.evaluate() } }
            .store(in: &subscriptions)
        MeetingRecorder.shared.$phase.receive(on: DispatchQueue.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.evaluate() } }
            .store(in: &subscriptions)
    }

    private func stop() {
        logger.notice("Call detection off")
        removeAudioListeners()
        for observer in observers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            NotificationCenter.default.removeObserver(observer)
        }
        observers = []
        subscriptions = []
        checkTimer?.invalidate()
        checkTimer = nil
    }

    // MARK: - Core Audio

    private func addAudioListeners() {
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated { self?.syncProcesses() }
        }
        var address = AudioProcessList.address(kAudioHardwarePropertyProcessObjectList)
        let status = AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, listener)
        if status != noErr { logger.error("Listening to the audio process list failed: \(status, privacy: .public)") }
        listListener = listener
        syncProcesses()
    }

    private func removeAudioListeners() {
        if let listListener {
            var address = AudioProcessList.address(kAudioHardwarePropertyProcessObjectList)
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, listListener)
        }
        listListener = nil
        for (object, listener) in inputListeners {
            var address = AudioProcessList.address(kAudioProcessPropertyIsRunningInput)
            AudioObjectRemovePropertyListenerBlock(object, &address, .main, listener)
        }
        inputListeners = [:]
        processes = [:]
    }

    /// Follows the process list: a listener on each new process's input, none left on processes that are gone.
    private func syncProcesses() {
        let objects = Set(AudioProcessList.objects())
        for (object, listener) in inputListeners where !objects.contains(object) {
            var address = AudioProcessList.address(kAudioProcessPropertyIsRunningInput)
            AudioObjectRemovePropertyListenerBlock(object, &address, .main, listener)
            inputListeners[object] = nil
            processes[object] = nil
        }
        for object in objects where inputListeners[object] == nil {
            guard let process = AudioProcessList.process(object) else { continue }
            let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                MainActor.assumeIsolated { self?.evaluate() }
            }
            var address = AudioProcessList.address(kAudioProcessPropertyIsRunningInput)
            guard AudioObjectAddPropertyListenerBlock(object, &address, .main, listener) == noErr else { continue }
            inputListeners[object] = listener
            processes[object] = process
        }
        evaluate()
    }

    private func evaluate() {
        guard isRunning else { return }
        let now = Date()
        let usingMicrophone = processes.filter { AudioProcessList.isRunningInput($0.key) }.map(\.value)
        let yap = MeetingCallPolicy.YapState(
            meeting: MeetingRecorder.shared.phase,
            isDictating: (engine?.recordingState ?? .idle) != .idle,
            isShowingNotification: NotificationManager.shared.isShowingNotification)
        switch policy.update(usingMicrophone, yap: yap, now: now) {
        case .none:
            break
        case .askToRecord(let app):
            logger.notice("\(app.id, privacy: .public) is using the microphone; asking to record")
            NotificationManager.shared.showNotification(
                title: app.askMessage, type: .info, duration: 15,
                actionButton: (String(localized: "Record Meeting"), { MeetingRecorder.shared.toggle() }))
        case .remindToEnd(let app):
            logger.notice("\(app.id, privacy: .public) left the microphone during a meeting recording")
            NotificationManager.shared.showNotification(
                title: MeetingCallApp.endMessage, type: .info, duration: 15,
                actionButton: (String(localized: "Show Meeting Panel"), { MeetingPanelController.shared.show() }))
        }
        checkTimer?.invalidate()
        checkTimer = policy.nextCheck(after: now).map { due in
            Timer.scheduledTimer(withTimeInterval: due.timeIntervalSince(now) + 0.05, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.evaluate() }
            }
        }
    }
}

/// Reading Core Audio's process objects.
enum AudioProcessList {
    static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }

    static func objects() -> [AudioObjectID] {
        var address = address(kAudioHardwarePropertyProcessObjectList)
        let system = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &objects) == noErr else { return [] }
        return Array(objects.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
    }

    static func isRunningInput(_ object: AudioObjectID) -> Bool {
        var address = address(kAudioProcessPropertyIsRunningInput)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr && value != 0
    }

    static func process(_ object: AudioObjectID) -> MicrophoneProcess? {
        var address = address(kAudioProcessPropertyPID)
        var pid: pid_t = -1
        var size = UInt32(MemoryLayout<pid_t>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &pid) == noErr, pid > 0 else { return nil }
        address = Self.address(kAudioProcessPropertyBundleID)
        var bundleID: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let bundle = AudioObjectGetPropertyData(object, &address, 0, nil, &size, &bundleID) == noErr
            ? bundleID?.takeRetainedValue() as String? : nil
        let responsible = responsiblePID(pid)
        return MicrophoneProcess(
            pid: pid, bundleID: bundle?.isEmpty == false ? bundle : nil, responsiblePID: responsible,
            responsibleBundleID: NSRunningApplication(processIdentifier: responsible)?.bundleIdentifier)
    }

    /// macOS's "responsible process": the app a helper or XPC service works for (Chrome for its helpers, Safari for
    /// WebKit's GPU process). A libsystem function without a public header, looked up at run time; without it a
    /// process counts as its own.
    private static let responsibleFunction: (@convention(c) (pid_t) -> pid_t)? = {
        guard let symbol = dlsym(dlopen(nil, RTLD_NOW), "responsibility_get_pid_responsible_for_pid") else { return nil }
        return unsafeBitCast(symbol, to: (@convention(c) (pid_t) -> pid_t).self)
    }()

    static func responsiblePID(_ pid: pid_t) -> pid_t {
        guard let responsible = responsibleFunction?(pid), responsible > 0 else { return pid }
        return responsible
    }
}

#if DEBUG
    extension MeetingCallPolicy {
        static func selfCheck() {
            let own: pid_t = 900
            func process(_ pid: pid_t, _ bundleID: String?, responsible: (pid_t, String?)? = nil) -> MicrophoneProcess {
                MicrophoneProcess(
                    pid: pid, bundleID: bundleID, responsiblePID: responsible?.0 ?? pid,
                    responsibleBundleID: responsible == nil ? bundleID : responsible?.1)
            }
            let zoom = process(10, "us.zoom.xos")
            let chromeHelper = process(21, "com.google.Chrome.helper", responsible: (20, "com.google.Chrome"))
            let safariGPU = process(31, "com.apple.WebKit.GPU", responsible: (30, "com.apple.Safari"))
            let otherWebKit = process(41, "com.apple.WebKit.GPU", responsible: (40, "com.example.widgets"))
            let arcHelper = process(51, "company.thebrowser.browser.helper", responsible: (50, "company.thebrowser.Browser"))
            let yapSelf = process(own, "me.sma1lboy.yap")
            let facetime = process(60, "com.apple.avconferenced")
            let unknown = process(70, "com.example.recorder")
            let t0 = Date(timeIntervalSince1970: 1_000_000)
            func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }
            let idle = YapState()
            let recording = YapState(meeting: .recording(started: t0))

            // Recognition: by the responsible app, whole bundle IDs, any case; Yap and unknown apps never.
            var policy = MeetingCallPolicy(ownPID: own)
            assert(policy.callApps([chromeHelper]).map(\.name) == ["Google Chrome"])
            assert(policy.callApps([safariGPU]).map(\.name) == ["Safari"], "WebKit's GPU process is Safari only for Safari")
            assert(policy.callApps([otherWebKit, unknown]).isEmpty)
            assert(policy.callApps([arcHelper]).map(\.name) == ["Arc"])
            assert(policy.callApps([facetime]).map(\.name) == ["FaceTime"])
            assert(policy.callApps([yapSelf, process(901, "me.sma1lboy.yap.helper", responsible: (own, "me.sma1lboy.yap"))]).isEmpty)
            assert(policy.callApps([process(80, "us.zoom.xos.helper")]).isEmpty, "a bundle ID matches whole, not by prefix")
            assert(policy.callApps([process(81, "com.microsoft.teams2"), process(82, "com.microsoft.teams")]).count == 1)

            // Browser naming: the prompt names the browser and doesn't claim a call.
            let chrome = MeetingCallApp.recognize(chromeHelper)!
            let zoomApp = MeetingCallApp.recognize(zoom)!
            assert(chrome.isBrowser && !zoomApp.isBrowser)
            assert(chrome.askMessage == String(format: String(localized: "%@ is using the microphone. Record this meeting?"), "Google Chrome"))
            assert(zoomApp.askMessage == String(format: String(localized: "%@ is on a call. Record this meeting?"), "Zoom"))

            // 5 s debounce, then once per call.
            assert(policy.update([zoom], yap: idle, now: at(0)) == .none)
            assert(policy.nextCheck(after: at(0)) == at(5))
            assert(policy.update([zoom], yap: idle, now: at(4.9)) == .none)
            assert(policy.update([zoom], yap: idle, now: at(5)) == .askToRecord(zoomApp))
            assert(policy.update([zoom], yap: idle, now: at(60)) == .none, "asked once per call")
            // A short gap (a device switch) is the same call; 10 s off ends it, and the next call is asked about.
            assert(policy.update([], yap: idle, now: at(61)) == .none)
            assert(policy.update([zoom], yap: idle, now: at(65)) == .none)
            assert(policy.update([zoom], yap: idle, now: at(75)) == .none)
            assert(policy.update([], yap: idle, now: at(80)) == .none)
            assert(policy.nextCheck(after: at(80)) == at(90))
            assert(policy.update([], yap: idle, now: at(90)) == .none)
            assert(policy.update([zoom], yap: idle, now: at(100)) == .none)
            assert(policy.update([zoom], yap: idle, now: at(105)) == .askToRecord(zoomApp))

            // Under 5 s on the microphone isn't a call.
            policy = MeetingCallPolicy(ownPID: own)
            assert(policy.update([zoom], yap: idle, now: at(0)) == .none)
            assert(policy.update([], yap: idle, now: at(3)) == .none)
            assert(policy.update([zoom], yap: idle, now: at(4)) == .none)
            assert(policy.update([zoom], yap: idle, now: at(8)) == .none, "on again at 4 s: 5 s from there")
            assert(policy.update([zoom], yap: idle, now: at(9)) == .askToRecord(zoomApp))

            // Not while recording (nor afterwards for the same call), in the consent note, finishing, or dictating.
            policy = MeetingCallPolicy(ownPID: own)
            assert(policy.update([zoom], yap: recording, now: at(0)) == .none)
            assert(policy.update([zoom], yap: recording, now: at(30)) == .none)
            assert(policy.update([zoom], yap: idle, now: at(40)) == .none, "this call was recorded already")
            for phase in [MeetingRecorder.Phase.consent, .finishing("x")] {
                policy = MeetingCallPolicy(ownPID: own)
                assert(policy.update([zoom], yap: YapState(meeting: phase), now: at(0)) == .none)
                assert(policy.update([zoom], yap: YapState(meeting: phase), now: at(10)) == .none)
            }
            policy = MeetingCallPolicy(ownPID: own)
            assert(policy.update([zoom], yap: YapState(isDictating: true), now: at(0)) == .none)
            assert(policy.update([zoom], yap: YapState(isDictating: true), now: at(10)) == .none, "not while dictating")
            assert(policy.update([zoom], yap: idle, now: at(12)) == .askToRecord(zoomApp), "after the dictation")

            // A notification on screen (an error, a recovery) defers the prompt; it isn't dropped.
            policy = MeetingCallPolicy(ownPID: own)
            assert(policy.update([zoom], yap: idle, now: at(0)) == .none)
            assert(policy.update([zoom], yap: YapState(isShowingNotification: true), now: at(6)) == .none)
            assert(policy.nextCheck(after: at(6)) == nil, "waits for the notification to go away")
            assert(policy.update([zoom], yap: idle, now: at(9)) == .askToRecord(zoomApp))

            // Yap's own microphone and unknown apps never prompt.
            policy = MeetingCallPolicy(ownPID: own)
            assert(policy.update([yapSelf, unknown, otherWebKit], yap: idle, now: at(0)) == .none)
            assert(policy.update([yapSelf, unknown, otherWebKit], yap: idle, now: at(60)) == .none)
            assert(policy.nextCheck(after: at(60)) == nil)

            // Two apps on one call: one prompt, the meeting app named before the browser.
            policy = MeetingCallPolicy(ownPID: own)
            assert(policy.update([chromeHelper], yap: idle, now: at(0)) == .none)
            assert(policy.update([chromeHelper, zoom], yap: idle, now: at(1)) == .none)
            assert(policy.update([chromeHelper, zoom], yap: idle, now: at(6)) == .askToRecord(zoomApp))
            assert(policy.update([chromeHelper, zoom], yap: idle, now: at(20)) == .none)
            policy = MeetingCallPolicy(ownPID: own)
            assert(policy.update([chromeHelper], yap: idle, now: at(0)) == .none)
            assert(policy.update([chromeHelper], yap: idle, now: at(5)) == .askToRecord(chrome))

            // End: the app asked about (or on the microphone when recording started) is off it for 10 s; said once.
            policy = MeetingCallPolicy(ownPID: own)
            assert(policy.update([zoom], yap: idle, now: at(0)) == .none)
            assert(policy.update([zoom], yap: idle, now: at(5)) == .askToRecord(zoomApp))
            assert(policy.update([zoom], yap: recording, now: at(8)) == .none)
            assert(policy.update([], yap: recording, now: at(100)) == .none)
            assert(policy.nextCheck(after: at(100)) == at(110))
            assert(policy.update([], yap: recording, now: at(109.9)) == .none, "10 s debounce")
            assert(policy.update([], yap: recording, now: at(110)) == .remindToEnd(zoomApp))
            assert(policy.update([], yap: recording, now: at(200)) == .none, "once")
            // Back on the call and off again: a new end.
            assert(policy.update([zoom], yap: recording, now: at(210)) == .none)
            assert(policy.update([], yap: recording, now: at(220)) == .none)
            assert(policy.update([], yap: recording, now: at(230)) == .remindToEnd(zoomApp))
            // A short gap isn't an end.
            policy = MeetingCallPolicy(ownPID: own)
            assert(policy.update([zoom], yap: recording, now: at(0)) == .none)
            assert(policy.update([], yap: recording, now: at(10)) == .none)
            assert(policy.update([zoom], yap: recording, now: at(15)) == .none)
            assert(policy.update([zoom], yap: recording, now: at(30)) == .none)
            // An app that joins after the recording started counts too; every watched app must be off.
            policy = MeetingCallPolicy(ownPID: own)
            assert(policy.update([], yap: recording, now: at(0)) == .none)
            assert(policy.update([chromeHelper], yap: recording, now: at(10)) == .none)
            assert(policy.update([chromeHelper, zoom], yap: recording, now: at(20)) == .none)
            assert(policy.update([chromeHelper], yap: recording, now: at(30)) == .none)
            assert(policy.update([chromeHelper], yap: recording, now: at(45)) == .none, "Chrome is still on the call")
            assert(policy.update([], yap: recording, now: at(50)) == .none)
            assert(policy.update([], yap: recording, now: at(60)) == .remindToEnd(chrome))
            // Deferred while dictating; nothing without a call app; the meeting's end drops it.
            policy = MeetingCallPolicy(ownPID: own)
            assert(policy.update([zoom], yap: recording, now: at(0)) == .none)
            assert(policy.update([], yap: recording, now: at(10)) == .none)
            assert(policy.update([], yap: YapState(meeting: .recording(started: t0), isDictating: true), now: at(25)) == .none)
            assert(policy.update([], yap: recording, now: at(26)) == .remindToEnd(zoomApp))
            policy = MeetingCallPolicy(ownPID: own)
            assert(policy.update([unknown, yapSelf], yap: recording, now: at(0)) == .none)
            assert(policy.update([], yap: recording, now: at(60)) == .none, "nothing to watch")
            policy = MeetingCallPolicy(ownPID: own)
            assert(policy.update([zoom], yap: recording, now: at(0)) == .none)
            assert(policy.update([zoom], yap: YapState(meeting: .finishing("x")), now: at(10)) == .none)
            assert(policy.update([], yap: idle, now: at(20)) == .none)
            assert(policy.update([], yap: idle, now: at(40)) == .none, "no end reminder once the meeting is over")
        }
    }
#endif
