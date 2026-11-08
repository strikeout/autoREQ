import Accelerate
import Foundation

/// The signal types of the generator.
public enum SignalKind: String, Codable, CaseIterable, Sendable, Identifiable {
    case pink = "Pink Noise", white = "White Noise", periodicPink = "Periodic Pink Noise"
    case sine = "Sine", dualSine = "Dual Sine", logSweep = "Log Sweep", file = "File"
    public var id: String { rawValue }

    /// A tone has energy at one or two frequencies only. The transfer function needs a broadband signal.
    public var isTonal: Bool { self == .sine || self == .dualSine }
}

/// The settings of one generator signal. The level and the channels are separate.
public struct SignalSettings: Codable, Hashable, Sendable {
    public var kind: SignalKind
    public var frequency: Double
    public var frequency2: Double
    /// The path of the audio file for `.file`.
    public var filePath: String?
    /// The sweep length of `.logSweep` in seconds. It is optional, so older state files still decode.
    public var sweepSeconds: Double?

    public init(kind: SignalKind = .pink, frequency: Double = 1000, frequency2: Double = 60, filePath: String? = nil, sweepSeconds: Double? = nil) {
        self.kind = kind
        self.frequency = frequency
        self.frequency2 = frequency2
        self.filePath = filePath
        self.sweepSeconds = sweepSeconds
    }

    public static let pink = SignalSettings()

    public var label: String {
        switch kind {
        case .sine: String(format: "Sine %.0f Hz", frequency)
        case .dualSine: String(format: "Dual Sine %.0f + %.0f Hz", frequency, frequency2)
        case .logSweep: String(format: "Log Sweep %.0f s", sweepSeconds ?? 2)
        case .file: filePath.map { "File: " + URL(fileURLWithPath: $0).lastPathComponent } ?? "File"
        default: kind.rawValue
        }
    }
}

/// A saved generator setup.
public struct GeneratorPreset: Codable, Hashable, Sendable, Identifiable {
    public var id: String { name }
    public var name: String
    public var signal: SignalSettings
    public var levelDBFS: Double
    /// The zero-based output channel, or -1 for all channels.
    public var channel: Int

    public init(name: String, signal: SignalSettings, levelDBFS: Double, channel: Int) {
        self.name = name
        self.signal = signal
        self.levelDBFS = levelDBFS
        self.channel = channel
    }
}

/// Makes the generator signal at an RMS level of 1.0 (0 dBFS RMS). The caller applies the level.
///
/// `render` allocates nothing, so it is safe on the render thread. Make the generator on another
/// thread, because the periodic noise and the file playback hold a sample table.
public struct SignalGenerator: Sendable {
    public let settings: SignalSettings
    private var pink = PinkNoise()
    private var seed: UInt64 = 0x2545_F491_4F6C_DD1D
    private var phase1 = 0.0, phase2 = 0.0
    private let step1: Double, step2: Double
    private let table: [Float]
    private var index = 0
    /// The position in the last `render` buffer where the table starts again, or nil.
    /// The sweep measurement uses it to find the first sample of each sweep.
    public private(set) var lastWrap: Int?

    /// The Kellet filter output has an RMS of about 0.19. This scale gives an RMS of 1.0.
    static let pinkScale: Float = 5.21

    /// - Parameters:
    ///   - periodLength: The period of `.periodicPink`. Use the frame length of `ImpulseAnalyzer`.
    ///   - fileSamples: The mono samples of `.file` at `sampleRate`. The generator loops them.
    public init(_ settings: SignalSettings, sampleRate: Double, periodLength: Int = 65_536, fileSamples: [Float] = []) {
        self.settings = settings
        step1 = 2 * .pi * settings.frequency / sampleRate
        step2 = 2 * .pi * settings.frequency2 / sampleRate
        switch settings.kind {
        case .periodicPink: table = Self.periodicPink(length: periodLength, sampleRate: sampleRate)
        case .logSweep: table = Self.normalized(Self.sweepTable(seconds: settings.sweepSeconds ?? 2, sampleRate: sampleRate))
        case .file: table = Self.normalized(fileSamples)
        default: table = []
        }
    }

    /// Writes `n` samples to `out`.
    public mutating func render(_ out: UnsafeMutablePointer<Float>, _ n: Int) {
        lastWrap = nil
        switch settings.kind {
        case .pink:
            for i in 0..<n { out[i] = pink.next() * Self.pinkScale }
        case .white:
            // A uniform value in -1…1 has an RMS of 1/√3.
            for i in 0..<n {
                seed ^= seed << 13; seed ^= seed >> 7; seed ^= seed << 17
                out[i] = Float(Double(seed >> 11) / Double(1 << 53) * 2 - 1) * 1.732_050_8
            }
        case .sine:
            for i in 0..<n {
                out[i] = Float(sin(phase1) * 2.0.squareRoot())
                phase1 += step1
                if phase1 > 2 * .pi { phase1 -= 2 * .pi }
            }
        case .dualSine:
            // Two tones at equal level. Each tone has an RMS of 1/√2.
            for i in 0..<n {
                out[i] = Float(sin(phase1) + sin(phase2))
                phase1 += step1; phase2 += step2
                if phase1 > 2 * .pi { phase1 -= 2 * .pi }
                if phase2 > 2 * .pi { phase2 -= 2 * .pi }
            }
        case .periodicPink, .logSweep, .file:
            guard !table.isEmpty else { for i in 0..<n { out[i] = 0 }; return }
            table.withUnsafeBufferPointer { t in
                for i in 0..<n {
                    if index == 0 { lastWrap = i }
                    out[i] = t[index]
                    index += 1
                    if index == t.count { index = 0 }
                }
            }
        }
    }

    /// Pink noise with an exact period of `length` samples.
    ///
    /// Each FFT bin from 20 Hz to 20 kHz gets a magnitude of 1/√f and a random phase.
    /// A frame of exactly one period has no window error.
    public static func periodicPink(length n: Int, sampleRate: Double, seed: UInt64 = 0x5DEE_CE66_D1CE_4E5B) -> [Float] {
        var s = seed | 1
        var re = [Float](repeating: 0, count: n), im = re
        let df = sampleRate / Double(n)
        for k in 1..<(n / 2) {
            let f = Double(k) * df
            guard f >= 20, f <= 20_000 else { continue }
            s ^= s << 13; s ^= s >> 7; s ^= s << 17
            let ph = Double(s >> 11) / Double(1 << 53) * 2 * .pi
            let a = 1 / f.squareRoot()
            re[k] = Float(a * cos(ph)); im[k] = Float(a * sin(ph))
            re[n - k] = re[k]; im[n - k] = -im[k]
        }
        let inv = try! vDSP.DiscreteFourierTransform(count: n, direction: .inverse, transformType: .complexComplex, ofType: Float.self)
        return normalized(inv.transform(real: re, imaginary: im).real)
    }

    /// The silence after each sweep. The impulse response of a sweep measurement has this length.
    public static let sweepTailSeconds = 2.0

    /// One sweep from 20 Hz to 20 kHz with a peak of 1.0, then `sweepTailSeconds` of silence.
    public static func sweepTable(seconds: Double, sampleRate: Double) -> [Float] {
        LogSweep(seconds: seconds, sampleRate: sampleRate).samples + [Float](repeating: 0, count: Int(sweepTailSeconds * sampleRate))
    }

    /// Scales `x` to an RMS of 1.0.
    static func normalized(_ x: [Float]) -> [Float] {
        guard !x.isEmpty else { return x }
        let rms = vDSP.rootMeanSquare(x)
        return rms > 0 ? vDSP.multiply(1 / rms, x) : x
    }
}
