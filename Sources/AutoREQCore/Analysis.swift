import Accelerate
import Foundation
import Synchronization

/// The averaging modes of the measurement screen.
/// The exponential modes settle in about 1.5 s, 0.5 s and 0.25 s. The FIFO modes average the last N frames.
public enum Averaging: String, Codable, CaseIterable, Sendable, Identifiable {
    case slow = "Slow", fast = "Fast", ultraFast = "Ultra-Fast"
    case fifo4 = "FIFO4", fifo8 = "FIFO8", fifo16 = "FIFO16", fifo32 = "FIFO32"
    public var id: String { rawValue }

    var timeConstant: Double? {
        switch self {
        case .slow: 1.5
        case .fast: 0.5
        case .ultraFast: 0.25
        default: nil
        }
    }

    var fifoLength: Int? {
        switch self {
        case .fifo4: 4
        case .fifo8: 8
        case .fifo16: 16
        case .fifo32: 32
        default: nil
        }
    }
}

/// A dual-channel FFT analyser. It computes the transfer function and the coherence
/// from the reference signal (the noise that the app plays) and the microphone signal.
/// The class is not thread safe. Use it from one queue.
public final class TransferAnalyzer {
    public let fftSize: Int
    public let sampleRate: Double
    public var averaging: Averaging { didSet { if averaging != oldValue { reset() } } }
    /// The time between two `add` calls. The exponential modes use it.
    public var frameInterval: Double = 0.1

    private let window: [Float]
    private let dft: vDSP.DiscreteFourierTransform<Float>
    private let bins: Int
    private var gxx: [Double], gyy: [Double], gxyRe: [Double], gxyIm: [Double]
    private var fifo: [(xx: [Double], yy: [Double], re: [Double], im: [Double])] = []
    private var frames = 0
    private let bands: [ClosedRange<Int>]

    public private(set) var frameCount = 0

    public init(fftSize: Int = 16_384, sampleRate: Double, averaging: Averaging = .slow) {
        self.fftSize = fftSize
        self.sampleRate = sampleRate
        self.averaging = averaging
        window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: fftSize, isHalfWindow: false)
        dft = try! vDSP.DiscreteFourierTransform(count: fftSize, direction: .forward, transformType: .complexComplex, ofType: Float.self)
        bins = fftSize / 2 + 1
        gxx = .init(repeating: 0, count: bins); gyy = gxx; gxyRe = gxx; gxyIm = gxx
        let df = sampleRate / Double(fftSize)
        let half = pow(2, 1 / (2 * FrequencyGrid.pointsPerOctave))
        bands = FrequencyGrid.frequencies.map { f in
            let lo = max(1, Int((f / half / df).rounded(.up)))
            let hi = min(fftSize / 2, Int((f * half / df).rounded(.down)))
            if hi >= lo { return lo...hi }
            let k = min(max(1, Int((f / df).rounded())), fftSize / 2)
            return k...k
        }
    }

    public func reset() {
        for i in 0..<bins { gxx[i] = 0; gyy[i] = 0; gxyRe[i] = 0; gxyIm[i] = 0 }
        fifo.removeAll()
        frameCount = 0
    }

    /// Adds one frame. Both arrays hold `fftSize` time-aligned samples.
    public func add(reference x: [Float], measured y: [Float]) {
        precondition(x.count == fftSize && y.count == fftSize)
        let zeros = [Float](repeating: 0, count: fftSize)
        let fx = dft.transform(real: vDSP.multiply(x, window), imaginary: zeros)
        let fy = dft.transform(real: vDSP.multiply(y, window), imaginary: zeros)
        var xx = [Double](repeating: 0, count: bins), yy = xx, re = xx, im = xx
        for k in 0..<bins {
            let xr = Double(fx.real[k]), xi = Double(fx.imaginary[k])
            let yr = Double(fy.real[k]), yi = Double(fy.imaginary[k])
            xx[k] = xr * xr + xi * xi
            yy[k] = yr * yr + yi * yi
            // conj(X) * Y
            re[k] = xr * yr + xi * yi
            im[k] = xr * yi - xi * yr
        }
        frameCount += 1
        if let n = averaging.fifoLength {
            fifo.append((xx, yy, re, im))
            if fifo.count > n { fifo.removeFirst(fifo.count - n) }
            let m = Double(fifo.count)
            for k in 0..<bins {
                var a = 0.0, b = 0.0, c = 0.0, d = 0.0
                for f in fifo { a += f.xx[k]; b += f.yy[k]; c += f.re[k]; d += f.im[k] }
                gxx[k] = a / m; gyy[k] = b / m; gxyRe[k] = c / m; gxyIm[k] = d / m
            }
        } else {
            let tau = averaging.timeConstant ?? 1.5
            // A short warm-up average stops the first frame from reading as perfectly coherent.
            let alpha = max(1 - exp(-frameInterval / tau), 1 / Double(frameCount))
            for k in 0..<bins {
                gxx[k] += alpha * (xx[k] - gxx[k])
                gyy[k] += alpha * (yy[k] - gyy[k])
                gxyRe[k] += alpha * (re[k] - gxyRe[k])
                gxyIm[k] += alpha * (im[k] - gxyIm[k])
            }
        }
    }

    /// The current averaged response on `FrequencyGrid`.
    public func response(latencySamples: Int) -> Response {
        let n = FrequencyGrid.count
        var mag = [Double](repeating: -120, count: n), ph = mag, coh = mag
        for (i, band) in bands.enumerated() {
            var a = 0.0, b = 0.0, c = 0.0, d = 0.0
            for k in band { a += gxx[k]; b += gyy[k]; c += gxyRe[k]; d += gxyIm[k] }
            let h = Complex(c, d) / Complex(max(a, 1e-30), 0)
            mag[i] = 20 * log10(max(h.magnitude, 1e-9))
            ph[i] = h.phase * 180 / .pi
            // A single frame always gives coherence 1, so report 0 until there are two.
            coh[i] = frameCount < 2 ? 0 : min(1, (c * c + d * d) / max(a * b, 1e-30))
        }
        return Response(magnitudeDB: mag, phaseDeg: ph, coherence: coh, latencySamples: latencySamples, sampleRate: sampleRate)
    }
}

/// Finds the delay between the reference and the measured signal with GCC-PHAT.
public enum DelayFinder {
    /// Returns `lag` so that `measured[n]` matches `reference[n + lag]`.
    /// `reference` must be longer than `measured`. `quality` is the peak height over the mean; above 8 is a reliable peak.
    public static func find(reference r: [Float], measured m: [Float]) -> (lag: Int, quality: Double)? {
        guard r.count > m.count, m.count > 0 else { return nil }
        var p = 1
        while p < r.count + m.count { p <<= 1 }
        guard let fwd = try? vDSP.DiscreteFourierTransform(count: p, direction: .forward, transformType: .complexComplex, ofType: Float.self),
              let inv = try? vDSP.DiscreteFourierTransform(count: p, direction: .inverse, transformType: .complexComplex, ofType: Float.self)
        else { return nil }
        let zeros = [Float](repeating: 0, count: p)
        let fr = fwd.transform(real: r + [Float](repeating: 0, count: p - r.count), imaginary: zeros)
        let fm = fwd.transform(real: m + [Float](repeating: 0, count: p - m.count), imaginary: zeros)
        var gr = [Float](repeating: 0, count: p), gi = gr
        for k in 0..<p {
            // conj(M) * R, then the PHAT weight 1/|.|
            let re = fm.real[k] * fr.real[k] + fm.imaginary[k] * fr.imaginary[k]
            let im = fm.real[k] * fr.imaginary[k] - fm.imaginary[k] * fr.real[k]
            let mag = max((re * re + im * im).squareRoot(), 1e-20)
            gr[k] = re / mag; gi[k] = im / mag
        }
        let c = inv.transform(real: gr, imaginary: gi).real
        let valid = r.count - m.count
        var best = 0, bestV: Float = -.infinity, sum: Float = 0
        for k in 0...valid {
            let v = abs(c[k])
            sum += v
            if v > bestV { bestV = v; best = k }
        }
        let mean = Double(sum) / Double(valid + 1)
        return (best, Double(bestV) / max(mean, 1e-20))
    }
}

/// Pink noise from white noise with the Paul Kellet "refined" filter. It is safe on the render thread.
public struct PinkNoise: Sendable {
    private var b0 = 0.0, b1 = 0.0, b2 = 0.0, b3 = 0.0, b4 = 0.0, b5 = 0.0, b6 = 0.0
    private var seed: UInt64

    public init(seed: UInt64 = 0x9E37_79B9_7F4A_7C15) { self.seed = seed | 1 }

    @inline(__always)
    public mutating func next() -> Float {
        seed ^= seed << 13; seed ^= seed >> 7; seed ^= seed << 17
        let white = Double(seed >> 11) / Double(1 << 53) * 2 - 1
        b0 = 0.99886 * b0 + white * 0.0555179
        b1 = 0.99332 * b1 + white * 0.0750759
        b2 = 0.96900 * b2 + white * 0.1538520
        b3 = 0.86650 * b3 + white * 0.3104856
        b4 = 0.55000 * b4 + white * 0.5329522
        b5 = -0.7616 * b5 - white * 0.0168980
        let pink = b0 + b1 + b2 + b3 + b4 + b5 + b6 + white * 0.5362
        b6 = white * 0.115926
        return Float(pink * 0.11)
    }
}

/// A single-writer, single-reader ring of samples with an absolute sample counter.
/// The render thread writes. Another thread reads a window by its absolute index.
public final class SampleRing: @unchecked Sendable {
    public let capacity: Int
    private let mask: Int
    private let buffer: UnsafeMutablePointer<Float>
    private let written = Atomic<Int>(0)

    public init(capacityPowerOfTwo: Int = 1 << 20) {
        precondition(capacityPowerOfTwo.nonzeroBitCount == 1)
        capacity = capacityPowerOfTwo
        mask = capacity - 1
        buffer = .allocate(capacity: capacity)
        buffer.initialize(repeating: 0, count: capacity)
    }

    deinit { buffer.deallocate() }

    /// The absolute count of samples written so far.
    public var count: Int { written.load(ordering: .acquiring) }

    public func write(_ src: UnsafePointer<Float>, _ n: Int) {
        let c = written.load(ordering: .relaxed)
        for i in 0..<n { buffer[(c + i) & mask] = src[i] }
        written.store(c + n, ordering: .releasing)
    }

    public func write(repeating v: Float, _ n: Int) {
        let c = written.load(ordering: .relaxed)
        for i in 0..<n { buffer[(c + i) & mask] = v }
        written.store(c + n, ordering: .releasing)
    }

    /// Reads `n` samples that start at absolute index `start`.
    /// Returns nil when the window is not written yet or is already overwritten.
    public func read(from start: Int, count n: Int) -> [Float]? {
        let c = count
        guard start >= 0, start + n <= c, start >= c - capacity + 1 else { return nil }
        return (0..<n).map { buffer[(start + $0) & mask] }
    }

    /// Reads one sample on the render thread. The caller checks the range.
    @inline(__always)
    public func sample(at i: Int) -> Float { buffer[i & mask] }
}
