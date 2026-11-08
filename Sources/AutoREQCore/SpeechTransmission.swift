import Accelerate
import Foundation

/// The result of a speech intelligibility analysis.
public struct STIResult: Hashable, Sendable, Codable {
    /// The speech transmission index, from 0 to 1.
    public var sti: Double
    /// The STIPA value that the analysis calculates from the same impulse response.
    public var stipa: Double
    /// The qualification band of the STI, for example "A+" or "U".
    public var rating: String
    public var stipaRating: String
    /// The octave band centres in Hz.
    public var bands: [Double]
    /// The modulation transfer index of each octave band.
    public var mti: [Double]
    /// The corrected modulation transfer function: one row for each band, one column for each modulation frequency.
    /// The STI comes from this matrix.
    public var mtf: [[Double]]
    /// The speech-to-noise ratio of each band in dB. The value is nil when the analysis has no noise levels.
    public var snr: [Double]?
    public var notes: [String]
}

/// The speech transmission index (STI) from an impulse response, by the indirect method of IEC 60268-16.
///
/// The model is the revision-4 model of IEC 60268-16:2011 (edition 4). Edition 5 (2020) keeps this model.
/// The tables and the correction formulas come from memory of the standard, not from the published text.
/// Before you use the result for a certificate, check these values against the published text of edition 5.
/// The values are the speech spectrum, the reception threshold, the masking slope, the weights and the rating bands.
///
/// The analysis does these steps for each octave band:
/// 1. A zero-phase band-pass filter isolates the band (see `bandEnergy`).
/// 2. A simplified Lundeby method finds the truncation point and the noise floor (see `decay`).
/// 3. The MTF is the normalised Fourier transform of the squared band response (Schroeder).
/// 4. The speech-to-noise ratio, the auditory masking and the reception threshold reduce the MTF.
///
/// STIPA is usually a direct method. This analysis calculates the STIPA value from the impulse response.
/// This method is "indirect STIPA". It uses the two STIPA modulation frequencies of each band.
public enum SpeechTransmission {
    /// The octave band centres in Hz.
    public static let bands: [Double] = [125, 250, 500, 1000, 2000, 4000, 8000]
    /// The 14 modulation frequencies of the full STI in Hz.
    public static let modulationFrequencies: [Double] = [0.63, 0.8, 1, 1.25, 1.6, 2, 2.5, 3.15, 4, 5, 6.3, 8, 10, 12.5]
    /// The two STIPA modulation frequencies of each band in Hz.
    public static let stipaFrequencies: [[Double]] = [[1.6, 8], [1, 5], [0.63, 3.15], [2, 10], [1.25, 6.25], [0.8, 4], [2.5, 12.5]]
    /// The male weights of the band MTIs.
    public static let alpha: [Double] = [0.085, 0.127, 0.230, 0.233, 0.309, 0.224, 0.173]
    /// The male redundancy weights of two adjacent bands.
    public static let beta: [Double] = [0.085, 0.078, 0.065, 0.011, 0.047, 0.095]
    /// The octave band levels of male speech in dB, relative to the A-weighted speech level.
    /// The A-weighted sum of these levels is 0.05 dB.
    public static let maleSpeechSpectrum: [Double] = [2.9, 2.9, -0.8, -6.8, -12.8, -18.8, -24.8]
    /// The absolute speech reception threshold of each band in dB SPL.
    public static let receptionThreshold: [Double] = [46, 27, 12, 6.5, 7.5, 8, 12]

    /// Calculates the STI and the STIPA value of an impulse response.
    ///
    /// - Parameters:
    ///   - speechLevelDBA: The A-weighted speech level at the listener in dB SPL. The band levels come from the male spectrum.
    ///   - speechBandLevels: The speech levels of the 7 bands in dB SPL. These levels replace `speechLevelDBA`.
    ///   - noiseBandLevels: The background noise levels of the 7 bands in dB SPL. Nil means no noise.
    ///   - auditoryEffects: Set this to false to remove the auditory masking and the reception threshold.
    public static func analyze(_ ir: ImpulseResponse, speechLevelDBA: Double = 60, speechBandLevels: [Double]? = nil,
                               noiseBandLevels: [Double]? = nil, auditoryEffects: Bool = true) -> STIResult {
        let speech = speechBandLevels ?? maleSpeechSpectrum.map { speechLevelDBA + $0 }
        precondition(speech.count == bands.count, "The speech levels must have 7 values.")
        precondition(noiseBandLevels.map { $0.count == bands.count } ?? true, "The noise levels must have 7 values.")
        var notes: [String] = []
        if noiseBandLevels == nil { notes.append("The analysis has no noise levels. The STI shows only the effect of the room.") }
        if ir.sampleRate < 2 * bands[6] * sqrt(2) {
            notes.append("The sample rate is too low for the 8 kHz band. The STI is not valid.")
        }

        let factor = correction(speech: speech, noise: noiseBandLevels, auditoryEffects: auditoryEffects)
        let energy = bandEnergy(ir)
        var mtf: [[Double]] = [], stipaMTF: [[Double]] = []
        for k in bands.indices {
            let d = decay(energy[k], sampleRate: ir.sampleRate)
            if d.rangeDB < 20 {
                notes.append(String(format: "The %@ Hz band has a decay range of %.0f dB. A range of less than 20 dB gives an MTF that is not reliable.",
                                    Band(centre: bands[k], lower: 0, upper: 0).label, d.rangeDB))
            }
            let m = modulation(energy[k], d, sampleRate: ir.sampleRate, frequencies: modulationFrequencies + stipaFrequencies[k])
            mtf.append(m.prefix(modulationFrequencies.count).map { $0 * factor[k] })
            stipaMTF.append(m.suffix(2).map { $0 * factor[k] })
        }
        let full = sti(mtf: mtf)
        let stipa = sti(mtf: stipaMTF).sti
        let snr = noiseBandLevels.map { n in bands.indices.map { speech[$0] - n[$0] } }
        return STIResult(sti: full.sti, stipa: stipa, rating: rating(full.sti), stipaRating: rating(stipa),
                         bands: bands, mti: full.mti, mtf: mtf, snr: snr, notes: notes)
    }

    /// The STI and the band MTIs from an MTF matrix with one row for each band.
    /// A row can have any number of modulation frequencies. The STIPA matrix has two.
    public static func sti(mtf: [[Double]]) -> (sti: Double, mti: [Double]) {
        let mti = mtf.map { row in row.map(transmissionIndex).reduce(0, +) / Double(max(row.count, 1)) }
        var s = 0.0
        for k in mti.indices { s += alpha[k] * mti[k] }
        for k in 0..<(mti.count - 1) { s -= beta[k] * (mti[k] * mti[k + 1]).squareRoot() }
        return (min(max(s, 0), 1), mti)
    }

    /// The transmission index of one modulation transfer value.
    /// The function clips the effective signal-to-noise ratio 10·log10(m / (1 − m)) to ±15 dB. Then TI = (SNR + 15) / 30.
    public static func transmissionIndex(_ m: Double) -> Double {
        guard m > 0 else { return 0 }
        guard m < 1 else { return 1 }
        let snr = min(max(10 * log10(m / (1 - m)), -15), 15)
        return (snr + 15) / 30
    }

    /// The qualification band of IEC 60268-16 Annex F for an STI value.
    public static func rating(_ sti: Double) -> String {
        let limits: [(Double, String)] = [(0.76, "A+"), (0.72, "A"), (0.68, "B"), (0.64, "C"), (0.60, "D"), (0.56, "E"),
                                          (0.52, "F"), (0.48, "G"), (0.44, "H"), (0.40, "I"), (0.36, "J")]
        return limits.first { sti >= $0.0 }?.1 ?? "U"
    }

    /// The auditory masking slope in dB for an octave band level `level` of the next-lower band (revision 4).
    static func maskingSlope(_ level: Double) -> Double {
        switch level {
        case ..<63: return 0.5 * level - 65
        case ..<67: return 1.8 * level - 146.9
        case ..<100: return 0.5 * level - 59.8
        default: return -10
        }
    }

    /// The factor that multiplies the MTF of each band: I_s / (I_s + I_n + I_am + I_rt).
    /// The masking intensity I_am comes from the total intensity (speech and noise) of the next-lower band.
    static func correction(speech: [Double], noise: [Double]?, auditoryEffects: Bool) -> [Double] {
        let s = speech.map { pow(10, $0 / 10) }
        let n = noise?.map { pow(10, $0 / 10) } ?? Array(repeating: 0, count: speech.count)
        return s.indices.map { k in
            var masking = 0.0, threshold = 0.0
            if auditoryEffects {
                threshold = pow(10, receptionThreshold[k] / 10)
                if k > 0 {
                    let lower = s[k - 1] + n[k - 1]
                    masking = lower * pow(10, maskingSlope(10 * log10(lower)) / 10)
                }
            }
            return s[k] / (s[k] + n[k] + masking + threshold)
        }
    }

    /// The squared response of each octave band, from 20 ms before lag 0 to the end of the response.
    ///
    /// The filter is zero phase. Its magnitude is the magnitude of a 6th-order Butterworth band-pass filter
    /// with the band edges at fc / √2 and fc · √2. Zero padding of 100 ms on each side keeps the filter
    /// ringing away from the circular wrap of the FFT.
    static func bandEnergy(_ ir: ImpulseResponse) -> [[Double]] {
        let fs = ir.sampleRate
        let pad = Int(0.1 * fs)
        var n = 1
        while n < ir.samples.count + 2 * pad { n <<= 1 }
        guard let fwd = try? vDSP.DiscreteFourierTransform(count: n, direction: .forward, transformType: .complexComplex, ofType: Float.self),
              let inv = try? vDSP.DiscreteFourierTransform(count: n, direction: .inverse, transformType: .complexComplex, ofType: Float.self)
        else { return bands.map { _ in [] } }
        var x = [Float](repeating: 0, count: n)
        x.replaceSubrange(pad..<(pad + ir.samples.count), with: ir.samples)
        let spectrum = fwd.transform(real: x, imaginary: [Float](repeating: 0, count: n))
        let start = max(0, pad + ir.zeroIndex - Int(0.02 * fs)), end = pad + ir.samples.count
        let width = sqrt(2) - sqrt(0.5), df = fs / Double(n), scale = 1 / Double(n)
        return bands.map { fc in
            var re = spectrum.real, im = spectrum.imaginary
            for j in 0...(n / 2) {
                let f = Double(j) * df
                let g = f > 0 ? Float(1 / (1 + pow((f / fc - fc / f) / width, 6)).squareRoot()) : 0
                re[j] *= g; im[j] *= g
                if j > 0 && j < n / 2 { re[n - j] *= g; im[n - j] *= g }
            }
            let y = inv.transform(real: re, imaginary: im).real
            return (start..<end).map { let v = Double(y[$0]) * scale; return v * v }
        }
    }

    /// The truncation point and the noise floor of one squared band response.
    struct Decay {
        /// The index of the first sample after the truncation point.
        var end: Int
        /// The mean noise energy of one sample.
        var noise: Double
        /// The time constant of the energy decay in seconds, from the regression line. It is nil when the method finds no decay.
        var tau: Double?
        /// The level difference between the highest block and the noise floor in dB.
        var rangeDB: Double
    }

    /// A simplified Lundeby method (Lundeby et al., Acta Acustica 1995) on 20 ms blocks of the squared response.
    ///
    /// The first noise estimate is the mean of the last 10 %. A regression line goes from the highest block
    /// to the first block 10 dB above the noise. The truncation point is where the line meets the noise level.
    /// The new noise estimate starts 10 dB of decay after that point, or at the last 10 % if that part is shorter.
    /// The method repeats these steps up to 5 times.
    static func decay(_ e: [Double], sampleRate fs: Double) -> Decay {
        let n = e.count, block = max(1, Int(0.02 * fs))
        func mean(_ r: Range<Int>) -> Double { r.isEmpty ? 0 : e[r].reduce(0, +) / Double(r.count) }
        func db(_ x: Double) -> Double { 10 * log10(max(x, 1e-300)) }
        let level = (0..<(n / block)).map { db(mean(($0 * block)..<(($0 + 1) * block))) }
        var noise = mean((n - n / 10)..<n)
        guard let peak = level.indices.max(by: { level[$0] < level[$1] }) else {
            return Decay(end: n, noise: noise, tau: nil, rangeDB: 0)
        }
        var result = Decay(end: n, noise: noise, tau: nil, rangeDB: level[peak] - db(noise))
        for _ in 0..<5 {
            let floor = db(noise)
            guard let last = level[peak...].firstIndex(where: { $0 <= floor + 10 }), last - peak >= 2 else { break }
            let ts = (peak...last).map { (Double($0) + 0.5) * Double(block) / fs }, ys = Array(level[peak...last])
            let mt = ts.reduce(0, +) / Double(ts.count), my = ys.reduce(0, +) / Double(ys.count)
            var num = 0.0, den = 0.0
            for i in ts.indices { num += (ts[i] - mt) * (ys[i] - my); den += (ts[i] - mt) * (ts[i] - mt) }
            let slope = num / max(den, 1e-30)
            guard slope < 0 else { break }
            let end = min(n, max((peak + 1) * block, Int((mt + (floor - my) / slope) * fs)))
            let from = min(end + Int(-10 / slope * fs), n - n / 10)
            let previous = result.end
            noise = mean(from..<n)
            result = Decay(end: end, noise: noise, tau: -10 / (slope * log(10)), rangeDB: level[peak] - db(noise))
            if abs(end - previous) < block { break }
        }
        return result
    }

    /// The MTF of one squared band response: |Σ e(t)·exp(−j2πFt)| / Σ e(t).
    /// The sums use the samples before the truncation point minus the noise energy, and an exponential tail after it.
    /// The tail starts at the noise level, because the regression line meets the noise level at that point.
    static func modulation(_ e: [Double], _ d: Decay, sampleRate fs: Double, frequencies: [Double]) -> [Double] {
        let x = e[..<d.end].map { $0 - d.noise }
        let t = vDSP.ramp(withInitialValue: 0.0, increment: 1 / fs, count: x.count)
        let tail = d.tau.map { d.noise * fs * $0 } ?? 0
        let total = vDSP.sum(x) + tail
        guard total > 0 else { return frequencies.map { _ in 0 } }
        let tEnd = Double(d.end) / fs
        return frequencies.map { f in
            let w = 2 * Double.pi * f
            let phase = vDSP.multiply(w, t)
            var sum = Complex(vDSP.dot(x, vForce.cos(phase)), -vDSP.dot(x, vForce.sin(phase)))
            if let tau = d.tau {
                // The integral of tail·exp(−(t − tEnd) / τ)·exp(−jωt) from tEnd to infinity.
                sum += Complex.polar(tail, -w * tEnd) / Complex(1, w * tau)
            }
            return min(sum.magnitude / total, 1)
        }
    }
}
