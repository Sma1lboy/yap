import AVFoundation
import Foundation

enum PCMAudioConverter {
    static func float32Samples(fromPCM16Data data: Data) -> [Float] {
        let sampleCount = data.count / MemoryLayout<Int16>.size
        var samples = [Float](repeating: 0, count: sampleCount)

        data.withUnsafeBytes { rawBuffer in
            let int16Samples = rawBuffer.bindMemory(to: Int16.self)
            for index in 0..<sampleCount {
                samples[index] = max(-1.0, min(Float(Int16(littleEndian: int16Samples[index])) / 32767.0, 1.0))
            }
        }

        return samples
    }

    static func pcmBuffer(fromPCM16Data data: Data) -> AVAudioPCMBuffer? {
        let samples = float32Samples(fromPCM16Data: data)
        guard !samples.isEmpty,
            let format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 16000.0,
                channels: 1,
                interleaved: false
            ),
            let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(samples.count)
            ),
            let channel = buffer.floatChannelData?[0]
        else {
            return nil
        }

        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { pointer in
            guard let baseAddress = pointer.baseAddress else { return }
            channel.update(from: baseAddress, count: samples.count)
        }

        return buffer
    }
}

/// Mixes interleaved Float32 capture buffers to mono and converts them to 16 kHz Int16 for the
/// recording file and the streaming callback. Keeps AVAudioConverter state across buffers so its
/// low-pass filter runs over the whole recording; decimating without one (the old linear
/// interpolation) folded everything above 8 kHz back into the speech band.
final class PCMResampler {
    static let outputFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true)!

    private var converter: AVAudioConverter?
    private var input: AVAudioPCMBuffer?
    private var output: AVAudioPCMBuffer?

    /// Returns 16 kHz mono PCM for these frames; the filter's lookahead arrives in later calls or `flush()`.
    func process(
        _ samples: UnsafePointer<Float32>, frameCount: UInt32, channels: UInt32, sampleRate: Double
    ) -> AVAudioPCMBuffer? {
        guard frameCount > 0, channels > 0,
            let (converter, input, output) = buffers(sampleRate: sampleRate, frameCapacity: frameCount),
            let mono = input.floatChannelData?[0]
        else { return nil }

        let n = Int(channels)
        for i in 0..<Int(frameCount) {
            var sum: Float32 = 0
            for ch in 0..<n { sum += samples[i * n + ch] }
            mono[i] = sum / Float32(n)
        }
        input.frameLength = frameCount

        var fed = false
        return convert(converter, into: output) { status in
            if fed {
                status.pointee = .noDataNow
                return nil
            }
            fed = true
            status.pointee = .haveData
            return input
        }
    }

    /// Drains what the filter still holds at the end of a recording and resets for the next one.
    func flush() -> AVAudioPCMBuffer? {
        guard let converter, let output else { return nil }
        defer { converter.reset() }
        return convert(converter, into: output) { status in
            status.pointee = .endOfStream
            return nil
        }
    }

    func reset() {
        converter?.reset()
    }

    private func convert(
        _ converter: AVAudioConverter, into output: AVAudioPCMBuffer,
        from block: @escaping (UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer?
    ) -> AVAudioPCMBuffer? {
        output.frameLength = 0
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, status in block(status) }
        guard status != .error, error == nil, output.frameLength > 0 else { return nil }
        return output
    }

    private func buffers(sampleRate: Double, frameCapacity: UInt32)
        -> (AVAudioConverter, AVAudioPCMBuffer, AVAudioPCMBuffer)?
    {
        if let converter, let input, let output, converter.inputFormat.sampleRate == sampleRate,
            input.frameCapacity >= frameCapacity
        {
            return (converter, input, output)
        }
        guard
            let inputFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false),
            let converter = AVAudioConverter(from: inputFormat, to: Self.outputFormat),
            let input = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: frameCapacity),
            // Room for this buffer plus whatever the filter held back from earlier ones.
            let output = AVAudioPCMBuffer(
                pcmFormat: Self.outputFormat,
                frameCapacity: UInt32(Double(frameCapacity) * 16000 / sampleRate) * 2 + 1024)
        else { return nil }
        converter.sampleRateConverterQuality = AVAudioQuality.high.rawValue
        self.converter = converter
        self.input = input
        self.output = output
        return (converter, input, output)
    }

    #if DEBUG
        /// 1 kHz passes, 12 kHz (above the 8 kHz Nyquist of 16 kHz) is filtered out instead of aliasing to 4 kHz,
        /// and no frames are lost across buffer boundaries.
        static func selfCheck() {
            func rms(_ hz: Double, rate: Double = 48000) -> (Float, Int) {
                let resampler = PCMResampler()
                var out: [Int16] = []
                let block = 512
                var buf = [Float32](repeating: 0, count: block * 2)  // stereo
                for b in 0..<(Int(rate) / block) {
                    for i in 0..<block {
                        let v = Float32(0.5 * sin(2 * .pi * hz * Double(b * block + i) / rate))
                        buf[2 * i] = v
                        buf[2 * i + 1] = v
                    }
                    if let o = resampler.process(buf, frameCount: UInt32(block), channels: 2, sampleRate: rate) {
                        out += UnsafeBufferPointer(start: o.int16ChannelData![0], count: Int(o.frameLength))
                    }
                }
                if let o = resampler.flush() {
                    out += UnsafeBufferPointer(start: o.int16ChannelData![0], count: Int(o.frameLength))
                }
                let body = out.dropFirst(800).dropLast(800).map { Float($0) / 32768 }
                return ((body.map { $0 * $0 }.reduce(0, +) / Float(body.count)).squareRoot(), out.count)
            }
            let (pass, n) = rms(1000)
            assert(pass > 0.3, "1 kHz should pass at ~0.35 RMS, got \(pass)")
            assert(abs(n - 15872) <= 32, "one second in 512-frame blocks → ~16 kHz frames, got \(n)")
            let (alias, _) = rms(12000)
            assert(alias < 0.005, "12 kHz must not alias into the band, got \(alias)")
            assert(rms(1000, rate: 44100).0 > 0.3)
        }
    #endif
}
