import Foundation

/// The decay times of one frequency band. The times are in seconds.
/// A time is nil when the dynamic range is too small for it.
public struct BandDecay: Hashable, Sendable, Codable {
    public var centre: Double
    public var lower: Double
    public var upper: Double
    /// The early decay time from the fit between 0 dB and -10 dB. It needs 20 dB of dynamic range.
    public var edt: Double?
    /// The decay time from the fit between -5 dB and -25 dB. It needs 35 dB of dynamic range, so the fit ends 10 dB above the noise.
    public var t20: Double?
    /// The decay time from the fit between -5 dB and -35 dB. It needs 45 dB of dynamic range, so the fit ends 10 dB above the noise.
    public var t30: Double?
    /// The noise power per sample in dB, relative to a digital value of 1.0.
    public var noiseFloorDB: Double
    /// The level at the start of the decay minus the noise floor.
    public var dynamicRangeDB: Double
}

/// Decay times and energy ratios from an impulse response.
public enum RoomAcoustics {
    public struct EnergyRatios: Hashable, Sendable, Codable {
        public var c50DB: Double
        public var c80DB: Double
        public var d50Percent: Double
        public var tsMs: Double
        public var drrDB: Double
    }

    /// The decay times in the bands of `banding` with a centre inside `range`.
    ///
    /// Each band uses a zero-phase band-pass filter, so the filter does not add delay.
    /// The decay starts 1/(2 x lower edge) before `zeroIndex`, so the filter keeps the energy of the direct sound.
    /// The function finds the end of the decay with the Lundeby method.
    /// It subtracts the noise power from the energy, and adds the Lundeby tail term to the Schroeder integral.
    public static func bandDecays(_ ir: ImpulseResponse, banding: Banding, range: ClosedRange<Double> = 63...8000) -> [BandDecay] {
        let bands = Band.bands(banding).filter { range.contains($0.centre) }
        guard !bands.isEmpty, ir.samples.count > 64 else { return [] }
        let filter = BandFilter(ir.samples)
        let sr = ir.sampleRate
        return bands.map { band in
            let x = filter.apply(band, sampleRate: sr)
            let start = max(0, ir.zeroIndex - Int(sr / (2 * band.lower)))
            let e = x[start...].map { $0 * $0 }
            var d = BandDecay(centre: band.centre, lower: band.lower, upper: band.upper, edt: nil, t20: nil, t30: nil,
                              noiseFloorDB: 10 * log10(max(mean(e, e.count - e.count / 10, e.count), 1e-30)), dynamicRangeDB: 0)
            guard let fit = lundeby(e, sampleRate: sr) else { return d }
            d.noiseFloorDB = 10 * log10(max(fit.noise, 1e-30))
            d.dynamicRangeDB = max(0, fit.interceptDB - d.noiseFloorDB)
            // The Schroeder integral of the signal energy. The tail term stands for the energy after the truncation point.
            let tc = fit.truncation
            var acc = fit.noise / (1 - pow(10, fit.slope / 10))
            var curve = [Double](repeating: 0, count: tc + 1)
            for i in stride(from: tc, through: 0, by: -1) {
                acc += e[i] - fit.noise
                curve[i] = acc
            }
            let top = max(curve[0], 1e-30)
            let db = curve.map { 10 * log10(max($0 / top, 1e-30)) }
            func decayTime(from hi: Double, to lo: Double, minRange: Double) -> Double? {
                guard d.dynamicRangeDB >= minRange,
                      let i0 = db.firstIndex(where: { $0 <= hi }), let i1 = db.firstIndex(where: { $0 <= lo }), i1 - i0 >= 3,
                      let line = regression(i0...i1, db), line.slope < 0 else { return nil }
                return -60 / (line.slope * sr)
            }
            d.edt = decayTime(from: 0, to: -10, minRange: 20)
            d.t20 = decayTime(from: -5, to: -25, minRange: 35)
            d.t30 = decayTime(from: -5, to: -35, minRange: 45)
            return d
        }
    }

    /// The energy ratios of an impulse response, in the whole range or in one band.
    ///
    /// The time zero is the sample with the largest magnitude within 2.5 ms of `zeroIndex`.
    /// The energy starts 1 ms before that sample, so the onset of the direct sound stays inside.
    /// The energy ends at the last 10 ms block that is more than 3 dB above the noise floor.
    /// The noise floor is the mean power of the last 10 % of the response. The function subtracts it from each sample.
    /// The direct sound for the DRR is the window of 2.5 ms before and after the peak.
    public static func energyRatios(_ ir: ImpulseResponse, band: Band? = nil) -> EnergyRatios {
        let sr = ir.sampleRate
        let x = band.map { BandFilter(ir.samples).apply($0, sampleRate: sr) } ?? ir.samples.map(Double.init)
        let n = x.count
        let near = Int(2.5e-3 * sr)
        let lo = max(0, ir.zeroIndex - near), hi = min(n - 1, ir.zeroIndex + near)
        var t0 = min(max(ir.zeroIndex, 0), max(n - 1, 0))
        if lo <= hi { t0 = (lo...hi).max { abs(x[$0]) < abs(x[$1]) } ?? t0 }
        let start = max(0, t0 - Int(1e-3 * sr))
        let e = x[start...].map { $0 * $0 }
        let noise = mean(e, e.count - e.count / 10, e.count)
        // Scan the 10 ms blocks from the end. The first block above the noise ends the energy.
        let block = max(1, Int(0.01 * sr))
        var end = e.count
        var b = (e.count - 1) / block
        while b >= 0, mean(e, b * block, min(e.count, (b + 1) * block)) <= 2 * noise + 1e-30 { b -= 1 }
        end = b < 0 ? 0 : min(e.count, (b + 1) * block)
        let at = t0 - start
        func energy(_ a: Int, _ z: Int) -> Double {
            let a = max(0, min(a, end)), z = max(a, min(z, end))
            return (a..<z).reduce(0.0) { $0 + e[$1] - noise }
        }
        func ratioDB(_ ms: Double) -> Double {
            let cut = at + Int((ms / 1000 * sr).rounded())
            return 10 * log10(max(energy(0, cut), 1e-30) / max(energy(cut, end), 1e-30))
        }
        let total = max(energy(0, end), 1e-30)
        let cut50 = at + Int((0.05 * sr).rounded())
        var moment = 0.0
        for i in 0..<end { moment += Double(i - at) / sr * (e[i] - noise) }
        let direct = energy(at - near, at + near + 1)
        return EnergyRatios(c50DB: ratioDB(50), c80DB: ratioDB(80), d50Percent: 100 * energy(0, cut50) / total,
                            tsMs: moment / total * 1000,
                            drrDB: 10 * log10(max(direct, 1e-30) / max(total - direct, 1e-30)))
    }

    // MARK: - Internals

    struct LundebyFit {
        /// The end of the decay as a sample index.
        var truncation: Int
        /// The noise power per sample.
        var noise: Double
        /// The slope of the decay in dB per sample.
        var slope: Double
        /// The level of the regression line at sample 0, in dB.
        var interceptDB: Double
    }

    /// The Lundeby method of ISO 3382-1 for the end of a decay. `e` is the squared impulse response.
    ///
    /// The method smooths the energy in blocks of 10 ms. It fits a line from the start to 10 dB above the noise.
    /// The point where the line meets the noise is the end of the decay.
    ///
    /// The method then takes the noise from the part after that point.
    /// It fits again with a block length that gives four blocks for each 10 dB of decay.
    /// It repeats this up to five times.
    /// The function returns nil when the energy has no falling slope.
    static func lundeby(_ e: [Double], sampleRate sr: Double) -> LundebyFit? {
        let n = e.count
        guard n >= Int(0.2 * sr) else { return nil }
        var cum = [Double](repeating: 0, count: n + 1)
        for i in 0..<n { cum[i + 1] = cum[i] + e[i] }
        func avg(_ a: Int, _ z: Int) -> Double { (cum[z] - cum[a]) / Double(z - a) }
        func db(_ v: Double) -> Double { 10 * log10(max(v, 1e-30)) }
        // The line fit over the blocks from the start up to the first block within 10 dB of the noise.
        func fit(_ len: Int, _ noiseDB: Double) -> (slope: Double, intercept: Double)? {
            let levels = (0..<(n / len)).map { db(avg($0 * len, ($0 + 1) * len)) }
            let j = levels.firstIndex { $0 < noiseDB + 10 } ?? levels.count
            guard j >= 2 else { return nil }
            let line = regression(0..<j, levels)
            guard let l = line, l.slope < 0 else { return nil }
            // The regression ran over block numbers. The block centres are (k + 0.5) * len samples.
            return (l.slope / Double(len), l.intercept - l.slope * 0.5)
        }
        var len = Int(0.01 * sr)
        var noise = avg(n - n / 10, n)
        guard let first = fit(len, db(noise)) else { return nil }
        var m = first.slope, c = first.intercept
        var tc = (db(noise) - c) / m
        for _ in 0..<5 {
            len = max(Int(0.005 * sr), Int(-10 / m / 4))
            let from = Int(max(tc + 7 / -m, 0))
            noise = avg(from < n - n / 20 ? from : n - n / 10, n)
            guard let f = fit(len, db(noise)) else { break }
            m = f.slope; c = f.intercept
            let next = (db(noise) - c) / m
            let done = abs(next - tc) < Double(len)
            tc = next
            if done { break }
        }
        guard tc.isFinite else { return nil }
        return LundebyFit(truncation: min(max(Int(tc), 1), n - 1), noise: noise, slope: m, interceptDB: c)
    }

    static func mean(_ a: [Double], _ from: Int, _ to: Int) -> Double {
        guard to > from else { return 0 }
        return a[from..<to].reduce(0, +) / Double(to - from)
    }

    /// The least-squares line y = intercept + slope * x over `y[range]`, where x is the index.
    static func regression(_ range: Range<Int>, _ y: [Double]) -> (slope: Double, intercept: Double)? {
        let n = Double(range.count)
        guard n >= 2 else { return nil }
        var sx = 0.0, sy = 0.0, sxx = 0.0, sxy = 0.0
        for i in range {
            let x = Double(i)
            sx += x; sy += y[i]; sxx += x * x; sxy += x * y[i]
        }
        let d = n * sxx - sx * sx
        guard d != 0 else { return nil }
        let slope = (n * sxy - sx * sy) / d
        return (slope, (sy - slope * sx) / n)
    }

    static func regression(_ range: ClosedRange<Int>, _ y: [Double]) -> (slope: Double, intercept: Double)? {
        regression(range.lowerBound..<(range.upperBound + 1), y)
    }

    /// A zero-phase band-pass filter in the frequency domain. The initializer computes the spectrum of the response once.
    ///
    /// The gain is 1 / sqrt(1 + u^8) with u = (f / fc - fc / f) / ((upper - lower) / fc).
    /// The gain is 0.707 at both band edges, and it falls by 24 dB per octave outside.
    struct BandFilter {
        let count: Int
        let n: Int
        let re: [Double]
        let im: [Double]

        init(_ samples: [Float]) {
            count = samples.count
            n = nextPowerOfTwo(2 * samples.count)
            let x = samples.map(Double.init) + [Double](repeating: 0, count: n - samples.count)
            (re, im) = dft(x, [Double](repeating: 0, count: n), inverse: false)
        }

        func apply(_ band: Band, sampleRate sr: Double) -> [Double] {
            let fc = (band.lower * band.upper).squareRoot()
            let width = (band.upper - band.lower) / fc
            var r = re, i = im
            for k in 0...(n / 2) {
                var g = 0.0
                if k > 0 {
                    let f = Double(k) * sr / Double(n)
                    let u = (f / fc - fc / f) / width
                    let u2 = u * u
                    g = 1 / (1 + u2 * u2 * u2 * u2).squareRoot()
                }
                r[k] *= g; i[k] *= g
                if k > 0 && k < n / 2 { r[n - k] *= g; i[n - k] *= g }
            }
            let t = dft(r, i, inverse: true).re
            return t[0..<count].map { $0 / Double(n) }
        }
    }
}
