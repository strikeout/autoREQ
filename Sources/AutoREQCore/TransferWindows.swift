import Accelerate
import Foundation

/// A transfer function with frequency-dependent time windows (FTW).
///
/// A long FFT gives a fine resolution in the bass. A short FFT gives a stable treble, because late
/// reflections fall outside its window. The analyser runs one `TransferAnalyzer` for each window
/// and joins the results on `FrequencyGrid` with a 1/3-octave crossfade.
/// The class is not thread safe. Use it from one queue.
public final class WindowedTransferAnalyzer {
    public struct Part: Sendable {
        public var fftSize: Int
        /// The part covers the frequencies up to this value. The last part goes to the top of the grid.
        public var upperHz: Double
    }

    public let parts: [Part]
    public let sampleRate: Double
    /// The length of the longest window. `add` needs frames of this length.
    public let frameLength: Int
    public var averaging: Averaging { didSet { for a in analyzers { a.averaging = averaging } } }
    private let analyzers: [TransferAnalyzer]
    /// The weight of each part at each grid point. The weights of one grid point add up to 1.
    private let weights: [[Double]]

    /// The windows at 48 kHz. Other rates scale the sizes, so the window times stay the same.
    public static func parts(sampleRate: Double, multiWindow: Bool) -> [Part] {
        func size(_ n48: Int) -> Int {
            var n = 1024
            while Double(n) < Double(n48) * sampleRate / 48_000 * 0.99 { n <<= 1 }
            return n
        }
        guard multiWindow else { return [Part(fftSize: 16_384, upperHz: .infinity)] }
        // About 1.4 s below 160 Hz, 340 ms to 1.25 kHz, 85 ms to 5 kHz and 21 ms above.
        return [Part(fftSize: size(65_536), upperHz: 160), Part(fftSize: size(16_384), upperHz: 1250),
                Part(fftSize: size(4096), upperHz: 5000), Part(fftSize: size(1024), upperHz: .infinity)]
    }

    public init(sampleRate: Double, averaging: Averaging = .slow, multiWindow: Bool = true) {
        parts = Self.parts(sampleRate: sampleRate, multiWindow: multiWindow)
        self.sampleRate = sampleRate
        self.averaging = averaging
        frameLength = parts.map(\.fftSize).max() ?? 16_384
        analyzers = parts.map { TransferAnalyzer(fftSize: $0.fftSize, sampleRate: sampleRate, averaging: averaging) }
        // Each boundary B has a crossfade from B / 2^(1/6) to B · 2^(1/6).
        let fade = pow(2, 1.0 / 6)
        let ps = parts
        weights = FrequencyGrid.frequencies.map { f in
            var w = [Double](repeating: 0, count: ps.count)
            let k = ps.firstIndex { f < $0.upperHz } ?? ps.count - 1
            w[k] = 1
            for b in [k - 1, k] where b >= 0 && b + 1 < ps.count {
                let lo = ps[b].upperHz / fade, hi = ps[b].upperHz * fade
                guard f > lo && f < hi else { continue }
                let t = log2(f / lo) / log2(hi / lo)
                w = [Double](repeating: 0, count: ps.count)
                w[b] = 1 - t; w[b + 1] = t
            }
            return w
        }
    }

    public func reset() { for a in analyzers { a.reset() } }

    /// Adds one tick of data. Both arrays hold `frameLength` time-aligned samples, newest last.
    /// `newSamples` is the number of samples since the last call. A short window adds up to 4 frames
    /// from that new data. Its average then covers the same time as the long windows.
    public func add(reference x: [Float], measured y: [Float], newSamples: Int, interval: Double) {
        precondition(x.count == frameLength && y.count == frameLength)
        for (p, a) in zip(parts, analyzers) {
            let n = p.fftSize, k = max(1, min(4, newSamples / n))
            a.frameInterval = interval / Double(k)
            for j in 0..<k {
                let end = frameLength - (k - 1 - j) * n
                a.add(reference: Array(x[(end - n)..<end]), measured: Array(y[(end - n)..<end]))
            }
        }
    }

    public func response(latencySamples: Int) -> Response {
        let rs = analyzers.map { $0.response(latencySamples: latencySamples) }
        guard rs.count > 1 else { return rs[0] }
        var out = rs[0]
        for i in 0..<FrequencyGrid.count {
            var h = Complex.zero, coh = 0.0
            for (k, r) in rs.enumerated() where weights[i][k] > 0 {
                h += r.complex(i) * Complex(weights[i][k], 0)
                coh += weights[i][k] * r.coherence[i]
            }
            out.magnitudeDB[i] = 20 * log10(max(h.magnitude, 1e-9))
            out.phaseDeg[i] = h.phase * 180 / .pi
            out.coherence[i] = coh
        }
        return out
    }
}

/// Follows a change of the delay from the peak of single-frame impulse responses.
///
/// A new delay must show in two frames in a row. One noisy frame then cannot move the delay.
public struct DelayTracker: Sendable {
    private var candidate: Int?
    private var count = 0

    public init() {}

    /// Returns the shift in samples to add to the measured delay, or nil to keep the delay.
    /// `lag` is the peak position of the newest frame relative to the current delay.
    /// A lag of one sample is jitter around a fraction of a sample, so the tracker keeps the delay.
    public mutating func update(lag: Int?) -> Int? {
        guard let lag, abs(lag) >= 2 else { candidate = nil; count = 0; return nil }
        if let c = candidate, abs(c - lag) <= 1 { count += 1 } else { candidate = lag; count = 1 }
        guard count >= 2 else { return nil }
        candidate = nil
        count = 0
        return lag
    }
}

extension ImpulseAnalyzer {
    /// The peak position of the newest frame alone, in samples relative to lag 0, with GCC-PHAT.
    /// It searches from -10 ms to +`maxLagMs`. It returns nil when the peak is not clear.
    public func latestPeakLag(maxLagMs: Double = 50) -> Int? {
        guard let (re, im) = lastCross else { return nil }
        let n = fftSize
        let t = inverseDFT.transform(real: re, imaginary: im).real
        let pre = Int(0.010 * sampleRate), post = Int(maxLagMs / 1000 * sampleRate)
        var best = 0, bestV: Float = 0, sum: Float = 0
        for lag in -pre...post {
            let v = abs(t[(lag + n) % n])
            sum += v
            if v > bestV { bestV = v; best = lag }
        }
        let mean = sum / Float(pre + post + 1)
        return bestV > 8 * mean ? best : nil
    }
}

extension ImpulseResponse {
    /// The time of the largest peak in milliseconds, with a parabolic fit for a fraction of a sample.
    public var peakTimeMs: Double? {
        guard let i = samples.indices.max(by: { abs(samples[$0]) < abs(samples[$1]) }), i > 0, i + 1 < samples.count else { return nil }
        let a = Double(abs(samples[i - 1])), b = Double(abs(samples[i])), c = Double(abs(samples[i + 1]))
        let d = a - 2 * b + c
        let frac = d == 0 ? 0 : 0.5 * (a - c) / d
        return (Double(i - zeroIndex) + frac) / sampleRate * 1000
    }
}

extension Response {
    /// This response relative to `reference`: the magnitudes subtract, the phases subtract,
    /// and the coherence is the lower of the two.
    /// Each phase is relative to its own latency. The latencies of two engine runs are not comparable.
    /// The result therefore ignores the difference of the latencies and keeps the latency of this response.
    public func dividing(by reference: Response) -> Response {
        var r = self
        r.impulse = nil
        for i in 0..<FrequencyGrid.count {
            r.magnitudeDB[i] = magnitudeDB[i] - reference.magnitudeDB[i]
            r.phaseDeg[i] = wrapDegrees(phaseDeg[i] - reference.phaseDeg[i])
            r.coherence[i] = min(coherence[i], reference.coherence[i])
        }
        return r
    }
}
