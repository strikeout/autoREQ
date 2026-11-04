import Accelerate
import Foundation

/// The fractional-octave band widths of the RTA.
public enum Banding: Int, Codable, CaseIterable, Sendable, Identifiable {
    case oct1 = 1, oct3 = 3, oct6 = 6, oct12 = 12, oct24 = 24, oct48 = 48
    public var id: Int { rawValue }
    public var label: String { "1/\(rawValue) Oct" }
}

/// A fractional-octave band with its centre and its edges in Hz.
public struct Band: Hashable, Sendable {
    public var centre: Double
    public var lower: Double
    public var upper: Double

    /// The base-ten bands of IEC 61260-1 from 20 Hz to 20 kHz.
    public static func bands(_ b: Banding) -> [Band] {
        let g = pow(10, 0.3), n = Double(b.rawValue)
        var out: [Band] = []
        for x in -500...500 {
            // An odd band count puts a band centre on 1 kHz. An even count puts two centres beside it.
            let e = b.rawValue % 2 == 1 ? Double(x) / n : Double(2 * x + 1) / (2 * n)
            let fm = 1000 * pow(g, e)
            guard fm >= 19.5, fm <= 20_500 else { continue }
            out.append(Band(centre: fm, lower: fm * pow(g, -1 / (2 * n)), upper: fm * pow(g, 1 / (2 * n))))
        }
        return out
    }

    /// The rounded centre for a label, for example "31.5" or "1k".
    public var label: String {
        if centre >= 1000 {
            let k = centre / 1000
            return k >= 10 ? String(format: "%.0fk", k) : String(format: "%.3gk", k)
        }
        return centre >= 100 ? String(format: "%.0f", centre) : String(format: "%.3g", centre)
    }
}

/// A single-channel FFT analyser for the RTA and the spectrograph.
///
/// The levels are RMS levels in dB relative to a digital value of 1.0. A full-scale sine reads -3 dB.
/// The class is not thread safe. Use it from one queue.
public final class SpectrumAnalyzer {
    public let fftSize: Int
    public let sampleRate: Double
    public var averaging: Averaging { didSet { if averaging != oldValue { reset() } } }
    /// The time between two `add` calls. The exponential modes use it.
    public var frameInterval: Double = 0.1
    public private(set) var frameCount = 0

    private let window: [Float]
    private let scale: Double
    private let dft: vDSP.DiscreteFourierTransform<Float>
    private let bins: Int
    /// The mean-square value in each bin of the last frame and of the average.
    private var last: [Double]
    private var average: [Double]
    private var fifo: [[Double]] = []
    private var weights: [Banding: [[(bin: Int, w: Double)]]] = [:]

    public init(fftSize: Int = 16_384, sampleRate: Double, averaging: Averaging = .fast) {
        self.fftSize = fftSize
        self.sampleRate = sampleRate
        self.averaging = averaging
        window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: fftSize, isHalfWindow: false)
        // Parseval: the sum of the one-sided bin powers over N·Σw² is the mean square of the signal.
        scale = 2 / (Double(fftSize) * Double(vDSP.sumOfSquares(window)))
        dft = try! vDSP.DiscreteFourierTransform(count: fftSize, direction: .forward, transformType: .complexComplex, ofType: Float.self)
        bins = fftSize / 2 + 1
        last = .init(repeating: 0, count: bins)
        average = last
    }

    public func reset() {
        for k in 0..<bins { average[k] = 0; last[k] = 0 }
        fifo.removeAll()
        frameCount = 0
    }

    /// Adds one frame of `fftSize` samples.
    public func add(_ x: [Float]) {
        precondition(x.count == fftSize)
        let f = dft.transform(real: vDSP.multiply(x, window), imaginary: [Float](repeating: 0, count: fftSize))
        for k in 0..<bins {
            let re = Double(f.real[k]), im = Double(f.imaginary[k])
            last[k] = (re * re + im * im) * scale
        }
        frameCount += 1
        if let n = averaging.fifoLength {
            fifo.append(last)
            if fifo.count > n { fifo.removeFirst(fifo.count - n) }
            let m = Double(fifo.count)
            for k in 0..<bins { average[k] = fifo.reduce(0) { $0 + $1[k] } / m }
        } else {
            let alpha = max(1 - exp(-frameInterval / (averaging.timeConstant ?? 0.5)), 1 / Double(frameCount))
            for k in 0..<bins { average[k] += alpha * (last[k] - average[k]) }
        }
    }

    /// The band levels in dB. `averaged: false` gives the levels of the last frame only.
    public func levels(_ banding: Banding, averaged: Bool = true) -> [Double] {
        let src = averaged ? average : last
        return bandWeights(banding).map { list in
            10 * log10(max(list.reduce(0) { $0 + src[$1.bin] * $1.w }, 1e-14))
        }
    }

    /// The bins of each band. Each bin counts with the fraction of its width inside the band.
    /// A band narrower than one bin then reads the level density of that bin times the band width.
    private func bandWeights(_ b: Banding) -> [[(bin: Int, w: Double)]] {
        if let w = weights[b] { return w }
        let df = sampleRate / Double(fftSize)
        let w = Band.bands(b).map { band in
            let k0 = max(1, Int((band.lower / df - 0.5).rounded(.down)))
            let k1 = min(bins - 1, Int((band.upper / df + 0.5).rounded(.up)))
            return (k0...max(k0, k1)).compactMap { k -> (bin: Int, w: Double)? in
                let lo = max(band.lower, (Double(k) - 0.5) * df), hi = min(band.upper, (Double(k) + 0.5) * df)
                return hi > lo ? (k, (hi - lo) / df) : nil
            }
        }
        weights[b] = w
        return w
    }
}
