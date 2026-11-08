import Accelerate
import Foundation

/// The smallest power of two that is at least `n` and at least 16. The FFT needs this length.
func nextPowerOfTwo(_ n: Int) -> Int {
    var p = 16
    while p < n { p <<= 1 }
    return p
}

/// The complex FFT of two arrays. The length must be a power of two. Neither direction scales the result.
func dft(_ re: [Double], _ im: [Double], inverse: Bool) -> (re: [Double], im: [Double]) {
    let t = try! vDSP.DiscreteFourierTransform(count: re.count, direction: inverse ? .inverse : .forward,
                                               transformType: .complexComplex, ofType: Double.self)
    let r = t.transform(real: re, imaginary: im)
    return (r.real, r.imaginary)
}

/// The power that a one-sided power spectrum holds around `f`.
/// The function averages the bins from `f / 2^halfBandOct` to `f * 2^halfBandOct`.
/// If the band holds no bin, the function interpolates between the two nearest bins.
func spectrumPower(_ p: [Double], df: Double, at f: Double, halfBandOct: Double) -> Double {
    let last = p.count - 1
    let k0 = Int((f * pow(2, -halfBandOct) / df).rounded(.up))
    let k1 = min(last, Int((f * pow(2, halfBandOct) / df).rounded(.down)))
    if k1 >= k0 && k0 >= 0 {
        var s = 0.0
        for k in k0...k1 { s += p[k] }
        return s / Double(k1 - k0 + 1)
    }
    let pos = min(max(f / df, 0), Double(last))
    let i = min(Int(pos), last - 1)
    let frac = pos - Double(i)
    return p[i] * (1 - frac) + p[i + 1] * frac
}

/// An exponential (Farina) sine sweep. The instantaneous frequency rises from `startHz` to `endHz`.
public struct LogSweep: Sendable {
    public let startHz: Double
    public let endHz: Double
    public let seconds: Double
    public let sampleRate: Double
    /// The sweep with a peak amplitude of 1.0 and a raised-cosine fade at each end.
    public let samples: [Float]

    public init(startHz: Double = 20, endHz: Double = 20_000, seconds: Double, sampleRate: Double, fadeMs: Double = 20) {
        self.startHz = startHz
        self.endHz = endHz
        self.seconds = seconds
        self.sampleRate = sampleRate
        let n = Int((seconds * sampleRate).rounded())
        let fade = max(1, min(n / 2, Int(fadeMs / 1000 * sampleRate)))
        let l = seconds / log(endHz / startHz)
        let k = 2 * Double.pi * startHz * l
        samples = (0..<n).map { i in
            var g = 1.0
            if i < fade { g = 0.5 - 0.5 * cos(Double.pi * Double(i) / Double(fade)) }
            let j = n - 1 - i
            if j < fade { g = min(g, 0.5 - 0.5 * cos(Double.pi * Double(j) / Double(fade))) }
            return Float(g * sin(k * (exp(Double(i) / sampleRate / l) - 1)))
        }
    }

    /// The linear impulse response of a recording.
    ///
    /// The recording must start at the first sweep sample. The caller removes the latency.
    /// It must be as long as the sweep plus the tail that the caller wants to see.
    /// The deconvolution is a regularised division in the frequency domain.
    ///
    /// The pass band has unity gain. A wire has a peak of about 0.8 at 20 Hz to 20 kHz and 48 kHz.
    /// The result has `prerollMs` before lag 0, and `lengthSeconds` after it.
    /// The default length is the tail.
    public func impulse(fromRecorded y: [Float], prerollMs: Double = 10, lengthSeconds: Double? = nil) -> ImpulseResponse {
        let (t, n) = deconvolve(y)
        let pre = Int(prerollMs / 1000 * sampleRate)
        let tail = max(0, y.count - samples.count)
        let len = max(1, min(lengthSeconds.map { Int($0 * sampleRate) } ?? tail, y.count, n - pre))
        let out = (0..<(pre + len)).map { Float(t[(($0 - pre) % n + n) % n]) }
        return ImpulseResponse(samples: out, sampleRate: sampleRate, zeroIndex: pre)
    }

    /// The circular deconvolution of the recording. The array index is the lag, and negative lags wrap to the end.
    /// The harmonic impulse responses sit at the negative lags.
    func deconvolve(_ y: [Float]) -> (t: [Double], n: Int) {
        let n = nextPowerOfTwo(y.count + samples.count)
        func pad(_ a: [Float]) -> [Double] { a.map(Double.init) + [Double](repeating: 0, count: n - a.count) }
        let zeros = [Double](repeating: 0, count: n)
        let x = dft(pad(samples), zeros, inverse: false)
        let r = dft(pad(y), zeros, inverse: false)
        // The regulariser is 20 dB below the mean power of the top octave of the sweep.
        // Where the sweep has less power, the division gives no gain. The noise outside the sweep range stays small.
        let df = sampleRate / Double(n)
        let k1 = min(n / 2, Int(endHz / df))
        let k0 = min(k1, Int(endHz / 2 / df))
        var top = 0.0
        for k in k0...k1 { top += x.re[k] * x.re[k] + x.im[k] * x.im[k] }
        let eps = 0.01 * top / Double(k1 - k0 + 1)
        var re = zeros, im = zeros
        for k in 0..<n {
            let g = 1 / (x.re[k] * x.re[k] + x.im[k] * x.im[k] + eps)
            re[k] = (r.re[k] * x.re[k] + r.im[k] * x.im[k]) * g
            im[k] = (r.im[k] * x.re[k] - r.re[k] * x.im[k]) * g
        }
        let t = dft(re, im, inverse: true).re
        let s = 1 / Double(n)
        return (t.map { $0 * s }, n)
    }

    /// The harmonic distortion against the excitation frequency.
    ///
    /// The k-th harmonic response sits `seconds * ln(k) / ln(endHz / startHz)` before lag 0.
    /// The function cuts a short window out of each response. It reads the spectrum at k times the excitation frequency.
    /// The window is at most 100 ms long, so the resolution at low frequencies is coarse.
    /// The points run from `startHz` to `endHz / 2`.
    /// A harmonic above `endHz` is not in the sweep, and it counts as -200 dB.
    public func distortion(fromRecorded y: [Float], bandsPerOctave: Int = 12) -> [HarmonicPoint] {
        let (t, n) = deconvolve(y)
        let sr = sampleRate
        let rate = log(endHz / startHz)
        func offset(_ k: Int) -> Int { Int((seconds * log(Double(k)) / rate * sr).rounded()) }
        let w = max(256, min(Int(0.1 * sr), Int(0.8 * Double(offset(5) - offset(4)))))
        let pre = w / 8, fadeOut = w / 4
        // Each window starts `pre` samples before its impulse. It fades in over `pre` and out over the last quarter.
        let win = (0..<w).map { i -> Double in
            var g = 1.0
            if i < pre { g = 0.5 - 0.5 * cos(Double.pi * Double(i) / Double(pre)) }
            if i >= w - fadeOut { g = min(g, 0.5 - 0.5 * cos(Double.pi * Double(w - 1 - i) / Double(fadeOut))) }
            return g
        }
        let nfft = nextPowerOfTwo(max(w, Int(sr)))
        let df = sr / Double(nfft)
        let zeros = [Double](repeating: 0, count: nfft)
        let power: [[Double]] = (1...5).map { k in
            var seg = zeros
            for i in 0..<w { seg[i] = t[((i - pre - offset(k)) % n + n) % n] * win[i] }
            let f = dft(seg, zeros, inverse: false)
            return (0...(nfft / 2)).map { f.re[$0] * f.re[$0] + f.im[$0] * f.im[$0] }
        }
        let halfBand = 0.5 / Double(bandsPerOctave)
        var out: [HarmonicPoint] = []
        var j = 0
        while true {
            let f = startHz * pow(2, Double(j) / Double(bandsPerOctave))
            if f > endHz / 2 { break }
            j += 1
            let a1 = max(spectrumPower(power[0], df: df, at: f, halfBandOct: halfBand).squareRoot(), 1e-30)
            var a = [Double](repeating: 0, count: 6)
            for k in 2...5 where Double(k) * f <= endHz {
                a[k] = spectrumPower(power[k - 1], df: df, at: Double(k) * f, halfBandOct: halfBand).squareRoot()
            }
            func db(_ v: Double) -> Double { 20 * log10(max(v / a1, 1e-10)) }
            let sum = (2...5).reduce(0.0) { $0 + a[$1] * a[$1] }
            out.append(HarmonicPoint(frequency: f, h2DB: db(a[2]), h3DB: db(a[3]), thdPercent: 100 * sum.squareRoot() / a1))
        }
        return out
    }
}

/// The distortion at one excitation frequency. The H2 and H3 levels are relative to the fundamental.
public struct HarmonicPoint: Hashable, Sendable, Codable {
    public var frequency: Double
    public var h2DB: Double
    public var h3DB: Double
    /// The THD from the 2nd to the 5th harmonic, in percent of the fundamental.
    public var thdPercent: Double
}

extension Response {
    /// The response of an impulse response, on `FrequencyGrid`. The phase is relative to lag 0.
    ///
    /// A grid point with two or more FFT bins gets the power mean of the bins.
    /// Its phase is the phase of the complex mean. Other points interpolate between the two nearest bins.
    public init(impulse ir: ImpulseResponse, coherence: Double = 1) {
        let sr = ir.sampleRate
        let n = nextPowerOfTwo(max(2 * ir.samples.count, Int(2 * sr)))
        let zeros = [Double](repeating: 0, count: n)
        let x = ir.samples.map(Double.init) + [Double](repeating: 0, count: n - ir.samples.count)
        let f = dft(x, zeros, inverse: false)
        let half = n / 2
        // The factor exp(+j 2 pi k z / n) moves the direct sound from index z to index 0.
        var re = [Double](repeating: 0, count: half + 1), im = re
        for k in 0...half {
            let a = 2 * Double.pi * Double((k * ir.zeroIndex) % n) / Double(n)
            re[k] = f.re[k] * cos(a) - f.im[k] * sin(a)
            im[k] = f.re[k] * sin(a) + f.im[k] * cos(a)
        }
        let df = sr / Double(n)
        let halfBand = 0.5 / FrequencyGrid.pointsPerOctave
        var mag: [Double] = [], phase: [Double] = []
        for g in FrequencyGrid.frequencies {
            let k0 = Int((g * pow(2, -halfBand) / df).rounded(.up))
            let k1 = min(half, Int((g * pow(2, halfBand) / df).rounded(.down)))
            var m: Double, c: Complex
            if k1 > k0 {
                var p = 0.0, sumRe = 0.0, sumIm = 0.0
                for k in k0...k1 {
                    p += re[k] * re[k] + im[k] * im[k]
                    sumRe += re[k]; sumIm += im[k]
                }
                m = (p / Double(k1 - k0 + 1)).squareRoot()
                c = Complex(sumRe, sumIm)
            } else {
                let pos = min(g / df, Double(half))
                let i = min(Int(pos), half - 1)
                let t = pos - Double(i)
                c = Complex(re[i] * (1 - t) + re[i + 1] * t, im[i] * (1 - t) + im[i + 1] * t)
                m = c.magnitude
            }
            mag.append(20 * log10(max(m, 1e-12)))
            phase.append(c.phase * 180 / .pi)
        }
        self.init(magnitudeDB: mag, phaseDeg: phase, coherence: .init(repeating: coherence, count: mag.count), latencySamples: 0, sampleRate: sr)
        impulse = ir
    }
}
