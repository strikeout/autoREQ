import Foundation

// This file holds a sound level meter. It is NOT a certified sound level meter. It has no
// type approval and no traceable calibration. Use it for orientation and logging, not for
// legal or occupational compliance decisions.

/// A frequency weighting of IEC 61672-1. Z means no weighting.
public enum FrequencyWeighting: String, Codable, CaseIterable, Sendable, Identifiable {
    case a = "A", c = "C", z = "Z"

    public var id: String { rawValue }

    /// The analog pole frequencies in Hz. A and C share them.
    private static let f1 = 20.6, f2 = 107.7, f3 = 737.9, f4 = 12194.0

    /// The closed-form IEC 61672-1 magnitude in dB at `f` Hz. The result is 0 dB at 1 kHz.
    public static func analyticDB(_ w: FrequencyWeighting, at f: Double) -> Double {
        func raw(_ f: Double) -> Double {
            let s = f * f
            switch w {
            case .z: return 1
            case .c: return f4 * f4 * s / ((s + f1 * f1) * (s + f4 * f4))
            case .a:
                return f4 * f4 * s * s
                    / ((s + f1 * f1) * ((s + f2 * f2) * (s + f3 * f3)).squareRoot() * (s + f4 * f4))
            }
        }
        return 20 * log10(max(raw(f), 1e-30) / raw(1000))
    }

    /// The biquad sections of a digital filter for this weighting. The gain is 0 dB at 1 kHz.
    ///
    /// Each section is a bilinear transform of an analog section. The transform prewarps
    /// each section to its own pole frequency. The 12194 Hz section is the exception.
    /// The transform prewarps this section to 10 kHz, so the error at 10 kHz is zero.
    ///
    /// At 48 kHz and at 96 kHz the response stays inside the IEC 61672-1 Class 1 limits up to 10 kHz.
    /// At 44.1 kHz the error at 10 kHz is a little larger. The response still stays inside the limits.
    /// Above 10 kHz the digital response falls faster than the analog one at low sample rates.
    public func filters(sampleRate fs: Double) -> [BiquadCoefficients] {
        var sections: [BiquadCoefficients]
        switch self {
        case .z: return []
        case .c:
            sections = [Self.section(zeros: true, Self.f1, Self.f1, match: Self.f1, fs),
                        Self.section(zeros: false, Self.f4, Self.f4, match: Self.highMatch, fs)]
        case .a:
            sections = [Self.section(zeros: true, Self.f1, Self.f1, match: Self.f1, fs),
                        Self.section(zeros: true, Self.f2, Self.f3, match: Self.f2, fs),
                        Self.section(zeros: false, Self.f4, Self.f4, match: Self.highMatch, fs)]
        }
        let gainDB = sections.reduce(0.0) { $0 + $1.magnitudeDB(at: 1000, sampleRate: fs) }
        let g = pow(10, -gainDB / 20)
        sections[0].b0 *= g; sections[0].b1 *= g; sections[0].b2 *= g
        return sections
    }

    private static let highMatch = 10000.0

    /// One analog section, `s^2 / ((s + a)(s + b))` or `1 / ((s + a)(s + b))`, as a biquad.
    /// The frequencies `a`, `b` and `match` are in Hz.
    private static func section(zeros: Bool, _ a: Double, _ b: Double, match: Double, _ fs: Double) -> BiquadCoefficients {
        let wa = 2 * Double.pi * a, wb = 2 * Double.pi * b
        let fm = min(match, 0.45 * fs)
        let k = 2 * Double.pi * fm / tan(Double.pi * fm / fs)
        let a0 = k * k + (wa + wb) * k + wa * wb
        let a1 = -2 * k * k + 2 * wa * wb
        let a2 = k * k - (wa + wb) * k + wa * wb
        let n = zeros ? k * k : 1
        let m = zeros ? -2 * k * k : 2
        return BiquadCoefficients(b0: n / a0, b1: m / a0, b2: n / a0, a1: a1 / a0, a2: a2 / a0)
    }
}

/// This type names a time weighting. F and S are exponential averages of the squared signal.
/// I uses a 35 ms rise and a 1.5 s decay. This is a simple two-constant detector.
/// It has no peak hold, so it is not exact to IEC 60651.
public enum TimeWeighting: String, Codable, CaseIterable, Sendable {
    case fast = "F", slow = "S", impulse = "I"
}

/// The levels of one frequency weighting. All levels are in dB SPL.
public struct WeightedLevels: Hashable, Sendable, Codable {
    public var fast = 0.0, slow = 0.0, impulse = 0.0
    /// The maximum of `fast` and `slow` since the reset.
    public var maxFast = 0.0, maxSlow = 0.0
    /// The equivalent continuous level since the reset.
    public var leq = 0.0
    /// The equivalent continuous level of the last completed second.
    public var leq1s = 0.0
    /// The highest absolute sample value since the reset.
    public var peak = 0.0
    /// The highest absolute sample value in the last completed second.
    public var peak1s = 0.0
}

/// This type describes one rolling Leq window. `value` is nil until the first second completes. Before the window
/// is full, the value covers the seconds that exist.
public struct LeqWindow: Hashable, Sendable, Codable {
    public var seconds: Double
    public var weighting: FrequencyWeighting
    public var value: Double?
    public init(seconds: Double, weighting: FrequencyWeighting, value: Double? = nil) {
        self.seconds = seconds; self.weighting = weighting; self.value = value
    }
}

/// A snapshot of all meter values. Levels are in dB SPL. A silent level reads -200 dB plus the calibration.
public struct SoundLevels: Hashable, Sendable, Codable {
    public var a = WeightedLevels()
    public var c = WeightedLevels()
    public var z = WeightedLevels()
    public var leqWindows: [LeqWindow] = []
    public var oshaDosePercent = 0.0
    public var nioshDosePercent = 0.0
    /// The dose that the exposure so far predicts for 8 hours at the same average.
    public var oshaProjected8hPercent = 0.0
    public var nioshProjected8hPercent = 0.0
    public var elapsedSeconds = 0.0

    public var lcPeak: Double { c.peak }
    public var lzPeak: Double { z.peak }
    public init() {}
}

/// The OSHA and NIOSH noise dose accumulators.
///
/// OSHA: criterion 90 dBA, exchange rate 5 dB, threshold 80 dBA, slow response.
/// NIOSH: criterion 85 dBA, exchange rate 3 dB, no threshold. Both use an 8 hour day.
/// The allowed time at level L is 8 h / 2^((L - criterion) / exchange rate).
public struct NoiseDose: Sendable, Hashable, Codable {
    private var oshaFraction = 0.0
    private var nioshFraction = 0.0
    public init() {}

    public var oshaPercent: Double { oshaFraction * 100 }
    public var nioshPercent: Double { nioshFraction * 100 }

    /// Adds `seconds` of exposure at `levelDBA`. The NIOSH dose uses `nioshLevelDBA` when the caller gives one.
    public mutating func add(levelDBA: Double, nioshLevelDBA: Double? = nil, seconds: Double) {
        if levelDBA >= 80 {
            oshaFraction += seconds / (28_800 / pow(2, (levelDBA - 90) / 5))
        }
        let n = nioshLevelDBA ?? levelDBA
        nioshFraction += seconds / (28_800 / pow(2, (n - 85) / 3))
    }

    /// The dose in percent if the average so far continued for 8 hours.
    public func projected8h(elapsedSeconds: Double) -> (osha: Double, niosh: Double) {
        guard elapsedSeconds > 0 else { return (0, 0) }
        let f = 28_800 / elapsedSeconds
        return (oshaPercent * f, nioshPercent * f)
    }
}

public enum LevelCalibration {
    /// The offset in dB so that dB SPL = dBFS RMS + offset. `measuredRMSDBFS` is the RMS
    /// level of the calibrator tone. `referenceDBSPL` is the level of the calibrator, 94 or 114 dB.
    public static func offset(measuredRMSDBFS: Double, referenceDBSPL: Double = 94) -> Double {
        referenceDBSPL - measuredRMSDBFS
    }
}

/// A streaming sound level meter for one channel. It is not a certified sound level meter.
/// It is not thread-safe. Use it from one queue.
///
/// Feed it with `process`. Call `levels()` at any rate. The Leq windows and the dose
/// update once for each second of audio. The OSHA dose takes LAS at the end of each second.
/// The NIOSH dose takes the LAeq of each second.
public final class SoundLevelMeter {
    public let sampleRate: Double
    public var calibrationDB: Double
    private let windows: [(seconds: Double, weighting: FrequencyWeighting)]

    private struct Band {
        var filter: [BiquadState]
        var yF = 0.0, yS = 0.0, yI = 0.0
        var maxF = 0.0, maxS = 0.0
        var totalSq = 0.0, binSq = 0.0
        var peak = 0.0, binPeak = 0.0
        var leq1s = 0.0, peak1s = 0.0
        var bins: [Double]
        var closed = 0

        init(_ w: FrequencyWeighting, fs: Double, cap: Int) {
            filter = w.filters(sampleRate: fs).map { BiquadState($0) }
            bins = [Double](repeating: 0, count: cap)
        }
    }

    private var bands: [Band] = []
    private let aF, aS, aIUp, aIDown: Double
    private let binLength: Int
    private var binCount = 0
    private var totalCount = 0
    private var dose = NoiseDose()
    private var windowValues: [Double?]

    public init(sampleRate: Double, calibrationDB: Double = 0,
                leqWindows: [(seconds: Double, weighting: FrequencyWeighting)] = [(60, .a), (600, .a), (900, .a)]) {
        self.sampleRate = sampleRate
        self.calibrationDB = calibrationDB
        self.windows = leqWindows
        func coefficient(_ tau: Double) -> Double { 1 - exp(-1 / (sampleRate * tau)) }
        aF = coefficient(0.125); aS = coefficient(1)
        aIUp = coefficient(0.035); aIDown = coefficient(1.5)
        binLength = max(1, Int(sampleRate.rounded()))
        windowValues = [Double?](repeating: nil, count: leqWindows.count)
        makeBands()
    }

    private func makeBands() {
        bands = FrequencyWeighting.allCases.map { w in
            let cap = windows.filter { $0.weighting == w }.map { max(1, Int($0.seconds.rounded())) }.max() ?? 1
            return Band(w, fs: sampleRate, cap: cap)
        }
    }

    /// Clears all filters, detectors, maxima, windows and the dose. The calibration stays.
    public func reset() {
        makeBands()
        binCount = 0; totalCount = 0
        dose = NoiseDose()
        windowValues = [Double?](repeating: nil, count: windows.count)
    }

    public func process(_ x: [Float]) {
        x.withUnsafeBufferPointer { process($0) }
    }

    public func process(_ x: UnsafeBufferPointer<Float>) {
        // The local copy avoids an exclusivity check on every sample.
        var b = bands
        bands = []
        for sample in x {
            let v = Double(sample)
            for i in 0..<3 {
                var y = v
                for j in b[i].filter.indices { y = b[i].filter[j].process(y) }
                let p = y * y
                b[i].totalSq += p
                b[i].binSq += p
                b[i].yF += aF * (p - b[i].yF)
                b[i].yS += aS * (p - b[i].yS)
                b[i].yI += (p > b[i].yI ? aIUp : aIDown) * (p - b[i].yI)
                b[i].maxF = max(b[i].maxF, b[i].yF)
                b[i].maxS = max(b[i].maxS, b[i].yS)
                let m = abs(y)
                b[i].peak = max(b[i].peak, m)
                b[i].binPeak = max(b[i].binPeak, m)
            }
            totalCount += 1
            binCount += 1
            if binCount == binLength { closeBin(&b) }
        }
        bands = b
    }

    private func db(_ meanSquare: Double) -> Double { 10 * log10(max(meanSquare, 1e-20)) + calibrationDB }
    private func peakDB(_ peak: Double) -> Double { 20 * log10(max(peak, 1e-10)) + calibrationDB }

    private func closeBin(_ b: inout [Band]) {
        for i in 0..<3 {
            let ms = b[i].binSq / Double(binLength)
            b[i].leq1s = ms
            b[i].peak1s = b[i].binPeak
            b[i].bins[b[i].closed % b[i].bins.count] = ms
            b[i].closed += 1
            b[i].binSq = 0; b[i].binPeak = 0
        }
        binCount = 0
        // Band 0 is A.
        dose.add(levelDBA: db(b[0].yS), nioshLevelDBA: db(b[0].leq1s), seconds: 1)
        for (k, w) in windows.enumerated() {
            let band = b[FrequencyWeighting.allCases.firstIndex(of: w.weighting)!]
            let n = min(max(1, Int(w.seconds.rounded())), band.closed)
            var sum = 0.0
            for j in 0..<n { sum += band.bins[(band.closed - 1 - j) % band.bins.count] }
            windowValues[k] = db(sum / Double(n))
        }
    }

    public func levels() -> SoundLevels {
        func weighted(_ b: Band) -> WeightedLevels {
            var w = WeightedLevels()
            w.fast = db(b.yF); w.slow = db(b.yS); w.impulse = db(b.yI)
            w.maxFast = db(b.maxF); w.maxSlow = db(b.maxS)
            w.leq = db(totalCount > 0 ? b.totalSq / Double(totalCount) : 0)
            w.leq1s = db(b.leq1s)
            w.peak = peakDB(b.peak); w.peak1s = peakDB(b.peak1s)
            return w
        }
        var s = SoundLevels()
        s.a = weighted(bands[0]); s.c = weighted(bands[1]); s.z = weighted(bands[2])
        s.leqWindows = windows.enumerated().map {
            LeqWindow(seconds: $0.element.seconds, weighting: $0.element.weighting, value: windowValues[$0.offset])
        }
        let p = dose.projected8h(elapsedSeconds: Double(bands[0].closed))
        s.oshaDosePercent = dose.oshaPercent; s.nioshDosePercent = dose.nioshPercent
        s.oshaProjected8hPercent = p.osha; s.nioshProjected8hPercent = p.niosh
        s.elapsedSeconds = Double(totalCount) / sampleRate
        return s
    }
}

/// A CSV log format with one line for each second.
public enum SPLLogFormat {
    /// This function writes the header line. Each channel gets the same columns, the Leq windows and the two doses.
    public static func header(channels: [String], leqWindows: [(seconds: Double, weighting: FrequencyWeighting)]) -> String {
        var cols = ["time"]
        for ch in channels {
            let name = ch.replacingOccurrences(of: ",", with: " ")
            var names = ["LAeq1s", "LAF", "LAS", "LCF", "LCpeak", "LZpeak"]
            names += leqWindows.map { "L\($0.weighting.rawValue)eq\(Int($0.seconds.rounded()))s" }
            names += ["OSHA%", "NIOSH%"]
            cols += names.map { "\(name) \($0)" }
        }
        return cols.joined(separator: ",")
    }

    /// This function writes one data line. `levels` holds one snapshot for each channel. The peaks are the peaks of the last second.
    public static func row(time: Date, levels: [SoundLevels]) -> String {
        func f(_ v: Double?) -> String { v.map { String(format: "%.1f", $0) } ?? "" }
        var cols = [ISO8601DateFormatter().string(from: time)]
        for l in levels {
            cols += [f(l.a.leq1s), f(l.a.fast), f(l.a.slow), f(l.c.fast), f(l.c.peak1s), f(l.z.peak1s)]
            cols += l.leqWindows.map { f($0.value) }
            cols += [f(l.oshaDosePercent), f(l.nioshDosePercent)]
        }
        return cols.joined(separator: ",")
    }
}
