// usage: fluidbench <nemotron model dir> <lang e.g. zh-CN|auto> <16k mono wav>... -> JSON lines; same calls as FluidAudioTranscriptionService
import AVFoundation
import FluidAudio
import Foundation

func samples(_ path: String) throws -> [Float] {
    let f = try AVAudioFile(forReading: URL(fileURLWithPath: path), commonFormat: .pcmFormatFloat32, interleaved: false)
    let buf = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(f.length))!
    try f.read(into: buf)
    return Array(UnsafeBufferPointer(start: buf.floatChannelData![0], count: Int(buf.frameLength)))
}

let a = CommandLine.arguments
let t0 = Date()
let manager = StreamingNemotronMultilingualAsrManager()
try await manager.loadModels(from: URL(fileURLWithPath: a[1]))
FileHandle.standardError.write("load \(Date().timeIntervalSince(t0))\n".data(using: .utf8)!)
for p in a[3...] {
    var pcm = try samples(p)
    let t = Date()
    await manager.setLanguage(a[2])
    await manager.reset()
    if pcm.count + 16_000 <= 240_000 { pcm += [Float](repeating: 0, count: 16_000) }
    _ = try await manager.process(samples: pcm)
    let text = try await manager.finish()
    let row: [String: Any] = ["file": p, "text": text, "secs": Date().timeIntervalSince(t)]
    print(String(data: try JSONSerialization.data(withJSONObject: row), encoding: .utf8)!)
}
