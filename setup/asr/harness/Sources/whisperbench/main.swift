// usage: whisperbench <ggml model> <silero vad model> <lang|auto> <prompt> <16k mono wav>...
// -> JSON lines {file, text, secs, segments: [[start, end, text]]}; load time on stderr. Runs the app's own LibWhisper.swift (VAD on, like the
// app's default), so windowing, language detection and prompt handling are the shipped code.
import AVFoundation
import Foundation

func samples(_ path: String) throws -> [Float] {
    let f = try AVAudioFile(forReading: URL(fileURLWithPath: path), commonFormat: .pcmFormatFloat32, interleaved: false)
    precondition(f.processingFormat.sampleRate == 16_000 && f.processingFormat.channelCount == 1)
    let buf = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(f.length))!
    try f.read(into: buf)
    return Array(UnsafeBufferPointer(start: buf.floatChannelData![0], count: Int(buf.frameLength)))
}

let a = CommandLine.arguments
// WHISPERBENCH_VAD=0: the app with VAD off (windows tile the whole file, silence kept).
UserDefaults.standard.set(ProcessInfo.processInfo.environment["WHISPERBENCH_VAD"] != "0", forKey: "IsVADEnabled")
VADModelManager.shared.path = a[2]
let t0 = Date()
let context = try await WhisperContext.createContext(path: a[1])
FileHandle.standardError.write("load \(Date().timeIntervalSince(t0))\n".data(using: .utf8)!)
let language = a[3] == "auto" ? nil : a[3]
/// CPU seconds and energy (joules) this process has used so far.
func usage() -> (cpu: Double, joules: Double) {
    var info = rusage_info_v6()
    let status = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(getpid(), RUSAGE_INFO_V6, $0) }
    }
    guard status == 0 else { return (0, 0) }
    var timebase = mach_timebase_info_data_t()
    mach_timebase_info(&timebase)
    let ns = Double(info.ri_user_time + info.ri_system_time) * Double(timebase.numer) / Double(timebase.denom)
    return (ns / 1e9, Double(info.ri_energy_nj) / 1e9)
}

// LIVE=0|1: feed each file in real time (100 ms chunks) as a recording would arrive, with WhisperLivePreview off or
// on, then time the final transcription and report CPU and energy for the whole "recording". Unset: plain decode.
let live = ProcessInfo.processInfo.environment["LIVE"]
for p in a[5...] {
    let pcm = try samples(p)
    var extra: [String: Any] = [:]
    var transcript: WhisperContext.Transcript?
    if let live {
        let before = usage()
        let recordingStart = Date()
        let preview = live == "1"
            ? WhisperLivePreview(
                language: a[3] == "auto" ? nil : a[3],
                interval: .milliseconds(Int(ProcessInfo.processInfo.environment["LIVE_INTERVAL_MS"] ?? "") ?? 1500)
            ) { text in
                if ProcessInfo.processInfo.environment["LIVE_PRINT"] != nil {
                    FileHandle.standardError.write("preview \(String(format: "%.1f", Date().timeIntervalSince(recordingStart))): \(text)\n".data(using: .utf8)!)
                }
            } : nil
        preview?.start(context: context)
        var fed = 0
        while fed < pcm.count {
            let next = min(pcm.count, fed + 1_600)
            preview?.append(samples: Array(pcm[fed..<next]))
            fed = next
            let due = recordingStart.addingTimeInterval(Double(fed) / 16_000)
            if due > Date() { try await Task.sleep(for: .seconds(due.timeIntervalSinceNow)) }
        }
        preview?.stop()
        let t = Date()
        transcript = await context.transcribe(samples: pcm, language: language, prompt: a[4])
        let finalSecs = Date().timeIntervalSince(t)
        let after = usage()
        extra = ["final": finalSecs, "cpu": after.cpu - before.cpu, "joules": after.joules - before.joules,
                 "previews": preview?.stats.decodes ?? 0, "aborted": preview?.stats.aborted ?? 0,
                 "previewSecs": preview?.stats.seconds ?? 0]
    }
    let t = Date()
    if live == nil { transcript = await context.transcribe(samples: pcm, language: language, prompt: a[4]) }
    let text = (transcript?.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    // Timed segments (seconds in the whole file, window offsets added back), as subtitle export sees them.
    let segments = TimedSegments.tidy(transcript?.segments ?? []).map { [$0.start, $0.end, $0.text] as [Any] }
    let row: [String: Any] = ["file": p, "text": text, "secs": (extra["final"] as? Double) ?? Date().timeIntervalSince(t),
                              "segments": segments]
        .merging(extra) { a, _ in a }
    print(String(data: try JSONSerialization.data(withJSONObject: row), encoding: .utf8)!)
}
// ggml's Metal backend can abort in its static destructors at exit; everything is printed by now.
fflush(stdout)
_exit(0)
