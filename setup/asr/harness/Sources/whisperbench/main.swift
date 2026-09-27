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
await context.setLanguage(a[3] == "auto" ? nil : a[3])
await context.setPrompt(a[4])
for p in a[5...] {
    let pcm = try samples(p)
    let t = Date()
    _ = await context.fullTranscribe(samples: pcm)
    let text = await context.getTranscription().trimmingCharacters(in: .whitespacesAndNewlines)
    // Timed segments (seconds in the whole file, window offsets added back), as subtitle export sees them.
    let segments = TimedSegments.tidy(await context.getSegments()).map { [$0.start, $0.end, $0.text] as [Any] }
    let row: [String: Any] = ["file": p, "text": text, "secs": Date().timeIntervalSince(t), "segments": segments]
    print(String(data: try JSONSerialization.data(withJSONObject: row), encoding: .utf8)!)
}
// ggml's Metal backend can abort in its static destructors at exit; everything is printed by now.
fflush(stdout)
_exit(0)
