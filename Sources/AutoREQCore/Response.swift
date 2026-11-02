import Foundation

/// The fixed log-frequency grid that every response uses: 1/48 octave from 10 Hz to 24 kHz.
public enum FrequencyGrid {
    public static let pointsPerOctave = 48.0
    public static let low = 10.0
    public static let high = 24_000.0
    public static let frequencies: [Double] = {
        let n = Int((log2(high / low) * pointsPerOctave).rounded(.down)) + 1
        return (0..<n).map { low * pow(2, Double($0) / pointsPerOctave) }
    }()
    public static var count: Int { frequencies.count }

    /// The grid index nearest to `f`.
    public static func index(of f: Double) -> Int {
        let i = Int((log2(max(f, low) / low) * pointsPerOctave).rounded())
        return min(max(i, 0), count - 1)
    }
}

/// One transfer-function measurement on `FrequencyGrid`.
/// The phase is relative to `latencySamples`: the app removes that delay before it computes the phase.
public struct Response: Codable, Hashable, Sendable {
    public var magnitudeDB: [Double]
    public var phaseDeg: [Double]
    public var coherence: [Double]
    public var latencySamples: Int
    public var sampleRate: Double

    public init(magnitudeDB: [Double], phaseDeg: [Double], coherence: [Double], latencySamples: Int = 0, sampleRate: Double = 48_000) {
        self.magnitudeDB = magnitudeDB
        self.phaseDeg = phaseDeg
        self.coherence = coherence
        self.latencySamples = latencySamples
        self.sampleRate = sampleRate
    }

    public static func flat(sampleRate: Double = 48_000) -> Response {
        let n = FrequencyGrid.count
        return Response(magnitudeDB: .init(repeating: 0, count: n), phaseDeg: .init(repeating: 0, count: n), coherence: .init(repeating: 1, count: n), sampleRate: sampleRate)
    }

    /// The complex value at grid index `i`, with the latency removed.
    public func complex(_ i: Int) -> Complex {
        Complex.polar(pow(10, magnitudeDB[i] / 20), phaseDeg[i] * .pi / 180)
    }

    /// Returns a copy with a display offset: an extra delay, a gain and a polarity flip.
    public func offset(delayMs: Double, gainDB: Double, inverted: Bool) -> Response {
        var r = self
        for (i, f) in FrequencyGrid.frequencies.enumerated() {
            r.magnitudeDB[i] += gainDB
            var p = phaseDeg[i] - 360 * f * delayMs / 1000 + (inverted ? 180 : 0)
            p = wrapDegrees(p)
            r.phaseDeg[i] = p
        }
        return r
    }

    /// Returns a copy that adds the response of `filters` (magnitude and phase).
    public func applying(_ filters: [BiquadCoefficients], gainDB: Double = 0, delaySamples: Double = 0, inverted: Bool = false) -> Response {
        var r = self
        for (i, f) in FrequencyGrid.frequencies.enumerated() {
            var h = complex(i)
            for c in filters { h = h * c.response(at: f, sampleRate: sampleRate) }
            h = h * Complex.polar(pow(10, gainDB / 20) * (inverted ? -1 : 1), -2 * .pi * f * delaySamples / sampleRate)
            r.magnitudeDB[i] = 20 * log10(max(h.magnitude, 1e-12))
            r.phaseDeg[i] = h.phase * 180 / .pi
        }
        return r
    }

    /// Sums responses as complex values. Each input keeps its own latency; the sum is relative to the first latency.
    public static func sum(_ items: [Response]) -> Response? {
        guard let first = items.first else { return nil }
        var out = first
        for i in 0..<FrequencyGrid.count {
            let f = FrequencyGrid.frequencies[i]
            var h = Complex.zero
            var coh = 1.0
            for r in items {
                let extra = Double(r.latencySamples - first.latencySamples)
                h += r.complex(i) * Complex.polar(1, -2 * .pi * f * extra / r.sampleRate)
                coh = min(coh, r.coherence[i])
            }
            out.magnitudeDB[i] = 20 * log10(max(h.magnitude, 1e-12))
            out.phaseDeg[i] = h.phase * 180 / .pi
            out.coherence[i] = coh
        }
        return out
    }

    /// Averages magnitudes on a power basis. It keeps the phase and latency of the first item.
    /// `weights` defaults to equal weights.
    public static func powerAverage(_ items: [Response], weights: [Double]? = nil) -> Response? {
        guard let first = items.first else { return nil }
        let w = weights ?? Array(repeating: 1, count: items.count)
        let total = w.reduce(0, +)
        var out = first
        for i in 0..<FrequencyGrid.count {
            var p = 0.0, c = 0.0
            for (k, r) in items.enumerated() {
                p += w[k] * pow(10, r.magnitudeDB[i] / 10)
                c += w[k] * r.coherence[i]
            }
            out.magnitudeDB[i] = 10 * log10(max(p / total, 1e-24))
            out.coherence[i] = c / total
        }
        return out
    }
}

public func wrapDegrees(_ p: Double) -> Double {
    var x = p.truncatingRemainder(dividingBy: 360)
    if x > 180 { x -= 360 }
    if x < -180 { x += 360 }
    return x
}

/// Display smoothing in fractions of an octave. The values follow the manual.
public enum Smoothing: Int, Codable, CaseIterable, Sendable, Identifiable {
    case none = 0, oct48 = 48, oct24 = 24, oct12 = 12, oct6 = 6, oct3 = 3, oct1 = 1
    public var id: Int { rawValue }
    public var label: String { self == .none ? "None" : "1/\(rawValue) Oct" }

    /// Smooths the magnitude on a power basis and the phase as a complex mean.
    public func apply(_ r: Response) -> Response {
        guard self != .none else { return r }
        let half = Int((FrequencyGrid.pointsPerOctave / Double(rawValue) / 2).rounded())
        guard half > 0 else { return r }
        var out = r
        let n = FrequencyGrid.count
        for i in 0..<n {
            let lo = max(0, i - half), hi = min(n - 1, i + half)
            var p = 0.0, h = Complex.zero, c = 0.0
            for k in lo...hi {
                p += pow(10, r.magnitudeDB[k] / 10)
                h += r.complex(k)
                c += r.coherence[k]
            }
            let m = Double(hi - lo + 1)
            out.magnitudeDB[i] = 10 * log10(max(p / m, 1e-24))
            out.phaseDeg[i] = h.phase * 180 / .pi
            out.coherence[i] = c / m
        }
        return out
    }
}

// MARK: - CSV

public enum ResponseCSV {
    /// Writes a response with a commented header. The header holds the name, colour, sample rate and latency.
    public static func encode(_ r: Response, name: String, colorHex: String) -> String {
        var s = "# name: \(name)\n# color: \(colorHex)\n# sampleRate: \(r.sampleRate)\n# latencySamples: \(r.latencySamples)\n"
        s += "frequency_hz,magnitude_db,phase_deg,coherence\n"
        for (i, f) in FrequencyGrid.frequencies.enumerated() {
            s += String(format: "%.3f,%.3f,%.2f,%.4f\n", f, r.magnitudeDB[i], r.phaseDeg[i], r.coherence[i])
        }
        return s
    }

    /// Reads a CSV that `encode` wrote, or any "frequency, dB[, phase[, coherence]]" CSV.
    /// The function interpolates foreign frequency points onto `FrequencyGrid`.
    public static func decode(_ text: String) -> (response: Response, name: String?, colorHex: String?)? {
        var name: String?, color: String?, rate = 48_000.0, latency = 0
        var pts: [(f: Double, m: Double, p: Double, c: Double)] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#") || line.hasPrefix("*") {
                let kv = line.dropFirst().split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                if kv.count == 2 {
                    switch kv[0] {
                    case "name": name = kv[1]
                    case "color": color = kv[1]
                    case "sampleRate": rate = Double(kv[1]) ?? rate
                    case "latencySamples": latency = Int(kv[1]) ?? 0
                    default: break
                    }
                }
                continue
            }
            let cols = line.split(whereSeparator: { $0 == "," || $0 == "\t" || $0 == ";" || $0 == " " }).compactMap { Double($0) }
            guard cols.count >= 2 else { continue }
            pts.append((cols[0], cols[1], cols.count > 2 ? cols[2] : 0, cols.count > 3 ? cols[3] : 1))
        }
        guard pts.count >= 2 else { return nil }
        pts.sort { $0.f < $1.f }
        var r = Response.flat(sampleRate: rate)
        r.latencySamples = latency
        var j = 0
        for (i, f) in FrequencyGrid.frequencies.enumerated() {
            while j < pts.count - 2 && pts[j + 1].f < f { j += 1 }
            let a = pts[j], b = pts[j + 1]
            let t = min(max((log(f) - log(a.f)) / (log(b.f) - log(a.f)), 0), 1)
            r.magnitudeDB[i] = a.m + (b.m - a.m) * t
            r.phaseDeg[i] = a.p + wrapDegrees(b.p - a.p) * t
            r.coherence[i] = a.c + (b.c - a.c) * t
        }
        return (r, name, color)
    }
}
