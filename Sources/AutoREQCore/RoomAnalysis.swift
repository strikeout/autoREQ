import Accelerate
import Foundation

/// A measured impulse response. Index `zeroIndex` is the time of the direct sound (lag 0).
public struct ImpulseResponse: Hashable, Sendable {
    public var samples: [Float]
    public var sampleRate: Double
    public var zeroIndex: Int

    public init(samples: [Float], sampleRate: Double, zeroIndex: Int) {
        self.samples = samples
        self.sampleRate = sampleRate
        self.zeroIndex = zeroIndex
    }

    /// The time of sample `i` in milliseconds after lag 0.
    public func timeMs(_ i: Int) -> Double { Double(i - zeroIndex) / sampleRate * 1000 }
}

extension ImpulseResponse: Codable {
    private enum Keys: String, CodingKey { case samples, sampleRate, zeroIndex }

    // The coder keeps the samples as raw Float32 data. JSON numbers make the state file about three times larger.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        let data = try c.decode(Data.self, forKey: .samples)
        samples = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        sampleRate = try c.decode(Double.self, forKey: .sampleRate)
        zeroIndex = try c.decode(Int.self, forKey: .zeroIndex)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(samples.withUnsafeBufferPointer { Data(buffer: $0) }, forKey: .samples)
        try c.encode(sampleRate, forKey: .sampleRate)
        try c.encode(zeroIndex, forKey: .zeroIndex)
    }
}

/// A dual-channel analyser with a long rectangular window. It gives the impulse response.
///
/// The frame is at least 1.2 s long, so the late part of the room decay stays in the frame.
/// A rectangular frame attenuates lag t by (1 - |t| / N). The analyser removes that error.
/// The class is not thread safe. Use it from one queue.
public final class ImpulseAnalyzer {
    public let fftSize: Int
    public let sampleRate: Double
    /// The number of frames in the running average.
    public var maxFrames = 16
    public private(set) var frameCount = 0

    private let fwd: vDSP.DiscreteFourierTransform<Float>
    private let inv: vDSP.DiscreteFourierTransform<Float>
    private var gxx: [Double], gxyRe: [Double], gxyIm: [Double]

    public init(sampleRate: Double) {
        var n = 1 << 14
        while Double(n) < sampleRate * 1.2 { n <<= 1 }
        fftSize = n
        self.sampleRate = sampleRate
        fwd = try! vDSP.DiscreteFourierTransform(count: n, direction: .forward, transformType: .complexComplex, ofType: Float.self)
        inv = try! vDSP.DiscreteFourierTransform(count: n, direction: .inverse, transformType: .complexComplex, ofType: Float.self)
        gxx = .init(repeating: 0, count: n / 2 + 1); gxyRe = gxx; gxyIm = gxx
    }

    public func reset() {
        for k in 0..<gxx.count { gxx[k] = 0; gxyRe[k] = 0; gxyIm[k] = 0 }
        frameCount = 0
    }

    /// Adds one frame. Both arrays hold `fftSize` time-aligned samples.
    public func add(reference x: [Float], measured y: [Float]) {
        precondition(x.count == fftSize && y.count == fftSize)
        let zeros = [Float](repeating: 0, count: fftSize)
        let fx = fwd.transform(real: x, imaginary: zeros)
        let fy = fwd.transform(real: y, imaginary: zeros)
        frameCount += 1
        let alpha = 1 / Double(min(frameCount, maxFrames))
        for k in 0..<gxx.count {
            let xr = Double(fx.real[k]), xi = Double(fx.imaginary[k])
            let yr = Double(fy.real[k]), yi = Double(fy.imaginary[k])
            gxx[k] += alpha * (xr * xr + xi * xi - gxx[k])
            gxyRe[k] += alpha * (xr * yr + xi * yi - gxyRe[k])
            gxyIm[k] += alpha * (xr * yi - xi * yr - gxyIm[k])
        }
    }

    /// The impulse response from `prerollMs` before lag 0 to half the frame length after it.
    public func impulse(prerollMs: Double = 10) -> ImpulseResponse? {
        guard frameCount > 0 else { return nil }
        let n = fftSize, half = n / 2
        let floor = (gxx.max() ?? 0) * 1e-12
        var re = [Float](repeating: 0, count: n), im = re
        for k in 1...half where gxx[k] > floor {
            let h = Complex(gxyRe[k], gxyIm[k]) / Complex(gxx[k], 0)
            re[k] = Float(h.re); im[k] = Float(h.im)
            if k < half { re[n - k] = Float(h.re); im[n - k] = -Float(h.im) }
        }
        let t = inv.transform(real: re, imaginary: im).real
        let pre = Int(prerollMs / 1000 * sampleRate)
        var out = [Float](repeating: 0, count: pre + half)
        for i in 0..<out.count {
            let lag = i - pre
            let w = 1 - Double(abs(lag)) / Double(n)
            out[i] = t[(lag + n) % n] / Float(Double(n) * w)
        }
        return ImpulseResponse(samples: out, sampleRate: sampleRate, zeroIndex: pre)
    }
}

/// One reflection in the energy-time curve.
public struct Reflection: Hashable, Sendable, Identifiable {
    public var id: Int { index }
    public var index: Int
    /// The time after the direct sound.
    public var delayMs: Double
    /// The level relative to the direct sound.
    public var levelDB: Double
    /// The extra path length relative to the direct sound, at 343 m/s.
    public var extraPathM: Double { delayMs / 1000 * 343 }
}

/// One room mode: a narrow peak in the low-frequency response.
public struct RoomMode: Hashable, Sendable, Identifiable {
    public var id: Double { frequency }
    public var frequency: Double
    /// The height of the peak above the one-octave average.
    public var levelDB: Double
    public var q: Double
    /// The decay time that a resonance with this Q has: T60 = 2.2 Q / f.
    public var t60FromQ: Double { 2.2 * q / frequency }
    /// The decay time that the analysis measures in the impulse response, if the response holds enough decay.
    public var t60Measured: Double?
}

/// Time-domain and modal analysis of one measurement.
public enum RoomAnalysis {
    /// The energy-time curve in dB relative to its peak. It is the envelope of the analytic signal.
    public static func etc(_ ir: ImpulseResponse) -> [Double] {
        var n = 1
        while n < ir.samples.count { n <<= 1 }
        guard let fwd = try? vDSP.DiscreteFourierTransform(count: n, direction: .forward, transformType: .complexComplex, ofType: Float.self),
              let inv = try? vDSP.DiscreteFourierTransform(count: n, direction: .inverse, transformType: .complexComplex, ofType: Float.self)
        else { return [] }
        let zeros = [Float](repeating: 0, count: n)
        let f = fwd.transform(real: ir.samples + [Float](repeating: 0, count: n - ir.samples.count), imaginary: zeros)
        var re = f.real, im = f.imaginary
        // The analytic signal has no negative frequencies, and twice the positive ones.
        for k in 1..<(n / 2) { re[k] *= 2; im[k] *= 2 }
        for k in (n / 2 + 1)..<n { re[k] = 0; im[k] = 0 }
        let t = inv.transform(real: re, imaginary: im)
        let env = (0..<ir.samples.count).map { Double(hypot(t.real[$0], t.imaginary[$0])) }
        let peak = max(env.max() ?? 0, 1e-30)
        return env.map { 20 * log10(max($0 / peak, 1e-9)) }
    }

    /// Finds the reflections in the first `windowMs` after the direct sound.
    /// A reflection is a local maximum of the ETC, 10 dB above the noise and above `thresholdDB`.
    public static func reflections(_ ir: ImpulseResponse, etc e: [Double]? = nil, windowMs: Double = 100,
                                   thresholdDB: Double = -30, limit: Int = 15) -> [Reflection] {
        let e = e ?? etc(ir)
        guard let direct = e.indices.max(by: { e[$0] < e[$1] }) else { return [] }
        let sr = ir.sampleRate
        let tail = e.suffix(e.count / 4).sorted()
        let noise = tail.isEmpty ? -120 : tail[tail.count / 2]
        let floor = max(thresholdDB, noise + 10)
        let guardSamples = Int(0.5e-3 * sr)
        let half = max(1, Int(0.25e-3 * sr))
        let end = min(e.count - 1, direct + Int(windowMs / 1000 * sr))
        var found: [Reflection] = []
        var i = direct + guardSamples
        while i <= end {
            let lo = max(0, i - half), hi = min(e.count - 1, i + half)
            if e[i] > floor && e[i] == e[lo...hi].max() {
                found.append(Reflection(index: i, delayMs: Double(i - direct) / sr * 1000, levelDB: e[i]))
                i += half
            }
            i += 1
        }
        return Array(found.sorted { $0.levelDB > $1.levelDB }.prefix(limit)).sorted { $0.delayMs < $1.delayMs }
    }

    /// Finds the room modes between `range.lowerBound` and `range.upperBound`.
    /// The analysis uses the impulse response when it exists, because its spectrum has a finer resolution.
    /// Otherwise it uses the magnitude of `response`.
    public static func modes(response: Response?, impulse: ImpulseResponse?, range: ClosedRange<Double> = 15...300,
                             minLevelDB: Double = 3, limit: Int = 12) -> [RoomMode] {
        var pts: [(f: Double, db: Double)] = []
        if let ir = impulse {
            pts = fineSpectrum(ir, range: range)
        } else if let r = response {
            for (i, f) in FrequencyGrid.frequencies.enumerated() where range.contains(f) && r.coherence[i] > 0.5 {
                pts.append((f, r.magnitudeDB[i]))
            }
        }
        guard pts.count > 8 else { return [] }
        let p = pts.map { pow(10, $0.db / 10) }
        // The baseline is the power average over one octave.
        var lo = 0, hi = 0, sum = 0.0
        var base = [Double](repeating: 0, count: pts.count)
        for i in pts.indices {
            while hi < pts.count && pts[hi].f <= pts[i].f * 1.4142 { sum += p[hi]; hi += 1 }
            while pts[lo].f < pts[i].f / 1.4142 { sum -= p[lo]; lo += 1 }
            base[i] = 10 * log10(max(sum / Double(hi - lo), 1e-30))
        }
        var candidates: [RoomMode] = []
        for i in 1..<(pts.count - 1) {
            let f = pts[i].f, db = pts[i].db
            let level = db - base[i]
            guard level >= minLevelDB else { continue }
            // A peak is the highest point within 1/20 octave on both sides.
            let near = pts.indices.filter { abs(log2(pts[$0].f / f)) <= 0.05 }
            guard near.allSatisfy({ pts[$0].db <= db }) else { continue }
            guard let q = quality(pts, peak: i) else { continue }
            candidates.append(RoomMode(frequency: f, levelDB: level, q: q))
        }
        var modes: [RoomMode] = []
        for c in candidates.sorted(by: { $0.levelDB > $1.levelDB }) where !modes.contains(where: { abs(log2($0.frequency / c.frequency)) < 0.1 }) {
            var m = c
            if let ir = impulse { m.t60Measured = decayT60(ir, frequency: m.frequency) }
            modes.append(m)
            if modes.count == limit { break }
        }
        return modes.sorted { $0.frequency < $1.frequency }
    }

    /// Q from the -3 dB width of the peak. If only one side falls 3 dB, the function doubles that side.
    static func quality(_ pts: [(f: Double, db: Double)], peak i: Int) -> Double? {
        let f0 = pts[i].f, edge = pts[i].db - 3
        func crossing(step: Int) -> Double? {
            var j = i
            while j + step >= 0 && j + step < pts.count {
                let a = pts[j], b = pts[j + step]
                if b.db > pts[i].db { return nil }
                if b.db <= edge { return a.f + (b.f - a.f) * (a.db - edge) / max(a.db - b.db, 1e-9) }
                j += step
            }
            return nil
        }
        let left = crossing(step: -1), right = crossing(step: 1)
        let width: Double
        switch (left, right) {
        case let (l?, r?): width = r - l
        case let (l?, nil): width = 2 * (f0 - l)
        case let (nil, r?): width = 2 * (r - f0)
        default: return nil
        }
        return width > 0 ? f0 / width : nil
    }

    /// The magnitude of the impulse response, zero-padded to a bin spacing below 0.4 Hz.
    static func fineSpectrum(_ ir: ImpulseResponse, range: ClosedRange<Double>) -> [(f: Double, db: Double)] {
        var n = 1
        while Double(n) < ir.sampleRate / 0.4 || n < ir.samples.count { n <<= 1 }
        guard let fwd = try? vDSP.DiscreteFourierTransform(count: n, direction: .forward, transformType: .complexComplex, ofType: Float.self) else { return [] }
        let zeros = [Float](repeating: 0, count: n)
        let s = fwd.transform(real: ir.samples + [Float](repeating: 0, count: n - ir.samples.count), imaginary: zeros)
        let df = ir.sampleRate / Double(n)
        let k0 = max(1, Int(range.lowerBound / df)), k1 = min(n / 2, Int(range.upperBound / df))
        guard k1 > k0 else { return [] }
        return (k0...k1).map { k in
            let m = Double(s.real[k] * s.real[k] + s.imaginary[k] * s.imaginary[k])
            return (Double(k) * df, 10 * log10(max(m, 1e-30)))
        }
    }

    /// The T60 decay time in a 1/3-octave band at `frequency`, from the Schroeder integral.
    /// The filter runs on the reversed response, so its own ringing does not extend the decay.
    /// The fit uses -5 dB to -25 dB (T20), or -5 dB to -15 dB (T10) when the noise is too high.
    public static func decayT60(_ ir: ImpulseResponse, frequency f: Double) -> Double? {
        let sr = ir.sampleRate
        let w0 = 2 * Double.pi * f / sr, alpha = sin(w0) / (2 * 4.32), a0 = 1 + alpha
        let bp = BiquadCoefficients(b0: alpha / a0, b1: 0, b2: -alpha / a0, a1: -2 * cos(w0) / a0, a2: (1 - alpha) / a0)
        var x = ir.samples[ir.zeroIndex...].reversed().map(Double.init)
        for _ in 0..<2 {
            var s = BiquadState(bp)
            x = x.map { s.process($0) }
        }
        x.reverse()
        let e = x.map { $0 * $0 }
        let tail = e.suffix(e.count / 5)
        let noise = tail.reduce(0, +) / Double(max(tail.count, 1))
        var sch = [Double](repeating: 0, count: e.count)
        var acc = 0.0
        for i in stride(from: e.count - 1, through: 0, by: -1) { acc += max(e[i] - noise, 0); sch[i] = acc }
        guard acc > 0 else { return nil }
        let db = sch.map { 10 * log10(max($0 / acc, 1e-30)) }
        let usable = e.count * 4 / 5
        for (top, bottom) in [(-5.0, -25.0), (-5.0, -15.0)] {
            guard let i1 = db.firstIndex(where: { $0 <= top }), let i2 = db.firstIndex(where: { $0 <= bottom }), i2 < usable, i2 > i1 + 4 else { continue }
            // A least-squares line through the decay curve.
            let ts = (i1...i2).map { Double($0) / sr }, ys = Array(db[i1...i2])
            let mt = ts.reduce(0, +) / Double(ts.count), my = ys.reduce(0, +) / Double(ys.count)
            var num = 0.0, den = 0.0
            for k in ts.indices { num += (ts[k] - mt) * (ys[k] - my); den += (ts[k] - mt) * (ts[k] - mt) }
            let slope = num / max(den, 1e-30)
            if slope < 0 { return -60 / slope }
        }
        return nil
    }
}
