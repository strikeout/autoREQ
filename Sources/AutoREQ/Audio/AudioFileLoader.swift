import AVFoundation

/// Reads an audio file as mono samples at the sample rate of the engine.
enum AudioFileLoader {
    /// ponytail: the loader keeps the whole file in memory and stops after 5 minutes (about 58 MB at 48 kHz).
    /// Stream the file from disk if longer files become necessary.
    static let maxSeconds = 300.0

    static func load(_ url: URL, sampleRate: Double) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let inFormat = file.processingFormat
        let frames = AVAudioFrameCount(min(Double(file.length), maxSeconds * inFormat.sampleRate))
        guard let inBuf = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: frames) else { throw err("The file has no audio.") }
        try file.read(into: inBuf, frameCount: frames)
        guard let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false),
              let conv = AVAudioConverter(from: inFormat, to: outFormat)
        else { throw err("The app cannot convert this file.") }
        // The converter mixes all channels to one.
        conv.downmix = true
        let capacity = AVAudioFrameCount(Double(inBuf.frameLength) * sampleRate / inFormat.sampleRate) + 4096
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity) else { throw err("The file is too long.") }
        var done = false
        var error: NSError?
        conv.convert(to: outBuf, error: &error) { _, status in
            if done { status.pointee = .endOfStream; return nil }
            done = true
            status.pointee = .haveData
            return inBuf
        }
        if let error { throw error }
        guard let p = outBuf.floatChannelData?[0], outBuf.frameLength > 0 else { throw err("The file has no audio.") }
        return Array(UnsafeBufferPointer(start: p, count: Int(outBuf.frameLength)))
    }

    private static func err(_ s: String) -> NSError { NSError(domain: "AutoREQ", code: 3, userInfo: [NSLocalizedDescriptionKey: s]) }
}
