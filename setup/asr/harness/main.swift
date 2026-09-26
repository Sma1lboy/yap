// Runs the app's own LibWhisper.swift on one file. Built by setup/asr/bench.py.
// usage: asr-harness <model.bin> <silero.bin> <16 kHz mono wav> [vad=on|off] [language=auto] [prompt=...]
// prints one JSON line: {"text": ..., "seconds": ...}
import AVFoundation
import Foundation

let args = CommandLine.arguments
var options: [String: String] = [:]
for arg in args.dropFirst(4) {
    let parts = arg.split(separator: "=", maxSplits: 1).map(String.init)
    if parts.count == 2 { options[parts[0]] = parts[1] }
}
UserDefaults.standard.set(options["vad", default: "on"] == "on", forKey: "IsVADEnabled")
VADModelManager.shared.path = args[2]

let file = try AVAudioFile(forReading: URL(fileURLWithPath: args[3]))
precondition(file.processingFormat.sampleRate == 16000 && file.processingFormat.channelCount == 1, "want 16 kHz mono")
let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
try file.read(into: buffer)
let samples = Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))

let done = DispatchSemaphore(value: 0)
Task {
    let context = try await WhisperContext.createContext(path: args[1])
    let language = options["language", default: "auto"]
    await context.setLanguage(language == "auto" ? nil : language)
    await context.setPrompt(options["prompt"])
    let start = Date()
    _ = await context.fullTranscribe(samples: samples)
    let text = await context.getTranscription()
    let json = try JSONSerialization.data(withJSONObject: ["text": text, "seconds": Date().timeIntervalSince(start)])
    print(String(decoding: json, as: UTF8.self))
    done.signal()
}
done.wait()
// ggml's Metal backend can abort in its static destructors at exit; the result is already printed.
fflush(stdout)
_exit(0)
