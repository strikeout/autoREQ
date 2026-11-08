import Foundation

/// Reads and writes WAV files. The writer makes 32-bit float files that REW can read.
public enum WAVFile {
    /// A WAV file with 32-bit IEEE float samples. The channels must have the same length.
    public static func encode(_ channels: [[Float]], sampleRate: Double) -> Data {
        let frames = channels.first?.count ?? 0
        let dataSize = frames * channels.count * 4
        let rate = Int(sampleRate.rounded())
        var d = Data()
        func u32(_ v: Int) { withUnsafeBytes(of: UInt32(v).littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: Int) { withUnsafeBytes(of: UInt16(v).littleEndian) { d.append(contentsOf: $0) } }
        d.append(contentsOf: Array("RIFF".utf8)); u32(4 + 24 + 12 + 8 + dataSize)
        d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16)
        u16(3); u16(channels.count); u32(rate); u32(rate * channels.count * 4)
        u16(channels.count * 4); u16(32)
        // A non-PCM format needs the fact chunk.
        d.append(contentsOf: Array("fact".utf8)); u32(4); u32(frames)
        d.append(contentsOf: Array("data".utf8)); u32(dataSize)
        d.reserveCapacity(d.count + dataSize)
        for i in 0..<frames {
            for c in channels { withUnsafeBytes(of: c[i].bitPattern.littleEndian) { d.append(contentsOf: $0) } }
        }
        return d
    }

    /// Reads a PCM file with 16, 24 or 32 bits, or a 32-bit float file. It also reads WAVE_FORMAT_EXTENSIBLE.
    /// The function skips unknown chunks. It returns nil for any other file.
    public static func decode(_ data: Data) -> (channels: [[Float]], sampleRate: Double)? {
        let b = [UInt8](data)
        func le(_ o: Int, _ size: Int) -> Int { (0..<size).reduce(0) { $0 | Int(b[o + $1]) << (8 * $1) } }
        guard b.count >= 12, Array(b[0..<4]) == Array("RIFF".utf8), Array(b[8..<12]) == Array("WAVE".utf8) else { return nil }
        var format = 0, channels = 0, rate = 0, bits = 0
        var pos = 12
        while pos + 8 <= b.count {
            let id = String(decoding: b[pos..<pos + 4], as: UTF8.self)
            let size = le(pos + 4, 4)
            let body = pos + 8
            if id == "fmt " {
                guard size >= 16, body + size <= b.count else { return nil }
                format = le(body, 2); channels = le(body + 2, 2); rate = le(body + 4, 4); bits = le(body + 14, 2)
                if format == 0xFFFE {
                    guard size >= 40 else { return nil }
                    format = le(body + 24, 2)
                }
            } else if id == "data" {
                guard channels > 0, rate > 0, [16, 24, 32].contains(bits), format == 1 || (format == 3 && bits == 32) else { return nil }
                let bytes = bits / 8
                let frames = min(size, b.count - body) / (bytes * channels)
                var out = [[Float]](repeating: [Float](repeating: 0, count: frames), count: channels)
                for i in 0..<frames {
                    for c in 0..<channels {
                        let v = le(body + (i * channels + c) * bytes, bytes)
                        let s: Float
                        switch (format, bits) {
                        case (3, _): s = Float(bitPattern: UInt32(v))
                        case (_, 16): s = Float(Int16(truncatingIfNeeded: v)) / 32_768
                        case (_, 24): s = Float(Int32(truncatingIfNeeded: v << 8) >> 8) / 8_388_608
                        default: s = Float(Int32(truncatingIfNeeded: v)) / 2_147_483_648
                        }
                        out[c][i] = s
                    }
                }
                return (out, Double(rate))
            }
            pos = body + size + (size & 1)
        }
        return nil
    }
}
