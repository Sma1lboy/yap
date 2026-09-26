// usage: tcppbench <model.gguf> <lang|auto> <itn 0|1> <16k mono wav>...  -> JSON lines {file, text, secs}; load time on stderr
import AVFoundation
import Foundation
import TranscribeCpp

func samples(_ path: String) throws -> [Float] {
    let f = try AVAudioFile(forReading: URL(fileURLWithPath: path), commonFormat: .pcmFormatFloat32, interleaved: false)
    precondition(f.processingFormat.sampleRate == 16_000 && f.processingFormat.channelCount == 1)
    let buf = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(f.length))!
    try f.read(into: buf)
    return Array(UnsafeBufferPointer(start: buf.floatChannelData![0], count: Int(buf.frameLength)))
}

let a = CommandLine.arguments
let t0 = Date()
let model = try Model(path: a[1], options: ModelOptions(backend: .auto))
FileHandle.standardError.write("load \(Date().timeIntervalSince(t0)) backend \(model.backend) arch \(model.arch)\n".data(using: .utf8)!)
let opts = RunOptions(timestamps: .none, itn: a[3] == "1" ? .on : .default, language: a[2] == "auto" ? nil : a[2], keepSpecialTags: false)
for p in a[4...] {
    let pcm = try samples(p)
    let t = Date()
    let tr = try model.session().run(pcm, options: opts)
    let row: [String: Any] = ["file": p, "text": tr.text.trimmingCharacters(in: .whitespacesAndNewlines), "secs": Date().timeIntervalSince(t)]
    print(String(data: try JSONSerialization.data(withJSONObject: row), encoding: .utf8)!)
}
