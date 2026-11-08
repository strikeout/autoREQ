import Foundation
import Testing
@testable import AutoREQCore

/// The analytic MTF of an exponential energy decay with the decay time `t60`.
private func analyticMTF(t60: Double) -> [[Double]] {
    SpeechTransmission.bands.map { _ in
        SpeechTransmission.modulationFrequencies.map { 1 / (1 + pow(2 * .pi * $0 * t60 / 13.8, 2)).squareRoot() }
    }
}

/// A synthetic room response: one tone at each band centre with an exponential envelope.
/// The squared response of each band decays as exp(−13.8 t / T).
/// Random noise is not a good test signal here. A short decay in the 125 Hz band has few degrees of freedom.
/// The MTF of that band then has a random error larger than 0.02.
private func decayIR(t60: Double, sampleRate fs: Double, noise: Float = 0) -> ImpulseResponse {
    var seed: UInt64 = 1
    func uniform() -> Float {
        seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Float(seed >> 40) / Float(1 << 24) * 2 - 1
    }
    let count = Int(max(1.5 * t60, 1) * fs)
    let samples = (0..<count).map { i -> Float in
        let t = Double(i) / fs
        let tones = SpeechTransmission.bands.reduce(0.0) { $0 + cos(2 * .pi * $1 * t) }
        return Float(exp(-6.9 * t / t60) * tones) + noise * 1.732 * uniform()
    }
    return ImpulseResponse(samples: samples, sampleRate: fs, zeroIndex: 0)
}

private func idealImpulse() -> ImpulseResponse {
    var s = [Float](repeating: 0, count: 24_000)
    s[480] = 1
    return ImpulseResponse(samples: s, sampleRate: 48_000, zeroIndex: 480)
}

private let speech60 = SpeechTransmission.maleSpeechSpectrum.map { 60 + $0 }

@Test(arguments: [0.5, 1.0, 2.0])
func exponentialDecayGivesTheAnalyticMTF(t60: Double) {
    let r = SpeechTransmission.analyze(decayIR(t60: t60, sampleRate: 32_000), auditoryEffects: false)
    let expected = analyticMTF(t60: t60)
    for k in expected.indices {
        for f in expected[k].indices {
            #expect(abs(r.mtf[k][f] - expected[k][f]) < 0.02, "band \(k), frequency \(f): \(r.mtf[k][f]) / \(expected[k][f])")
        }
    }
    #expect(abs(r.sti - SpeechTransmission.sti(mtf: expected).sti) < 0.02)
}

@Test func noisyDecayGivesTheAnalyticMTF() {
    // In the 8 kHz band, the noise floor is 25 dB below the start of the decay. The other bands have less noise.
    // Without the truncation, the MTF of the 8 kHz band is 0.06 too low.
    let r = SpeechTransmission.analyze(decayIR(t60: 1, sampleRate: 32_000, noise: 0.067), auditoryEffects: false)
    let expected = analyticMTF(t60: 1)
    for k in expected.indices {
        for f in expected[k].indices {
            #expect(abs(r.mtf[k][f] - expected[k][f]) < 0.03, "band \(k), frequency \(f): \(r.mtf[k][f]) / \(expected[k][f])")
        }
    }
    #expect(abs(r.sti - SpeechTransmission.sti(mtf: expected).sti) < 0.02)
}

@Test func idealImpulseGivesAnSTIOfOne() {
    let r = SpeechTransmission.analyze(idealImpulse(), auditoryEffects: false)
    #expect(abs(r.sti - 1) <= 0.005)
    #expect(abs(r.stipa - 1) <= 0.005)
    #expect(r.rating == "A+")
    #expect(r.snr == nil)
}

@Test func zeroSignalToNoiseRatioGivesHalfTheTransmission() {
    let r = SpeechTransmission.analyze(idealImpulse(), noiseBandLevels: speech60, auditoryEffects: false)
    let a = SpeechTransmission.alpha.reduce(0, +), b = SpeechTransmission.beta.reduce(0, +)
    #expect(abs(r.sti - 0.5 * (a - b)) < 0.01)
    #expect(abs(r.stipa - 0.5 * (a - b)) < 0.01)
    #expect(r.snr == Array(repeating: 0, count: 7))
}

@Test(arguments: [15.0, 20.0, 30.0])
func highSignalToNoiseRatioGivesAnSTIOfOne(snr: Double) {
    let r = SpeechTransmission.analyze(idealImpulse(), noiseBandLevels: speech60.map { $0 - snr }, auditoryEffects: false)
    #expect(r.sti > 0.99)
}

@Test(arguments: [-15.0, -20.0])
func lowSignalToNoiseRatioGivesAnSTIOfZero(snr: Double) {
    let r = SpeechTransmission.analyze(idealImpulse(), noiseBandLevels: speech60.map { $0 - snr }, auditoryEffects: false)
    #expect(r.sti < 0.005)
    #expect(r.rating == "U")
}

@Test func auditoryEffectsLowerTheSTIOfAQuietTalker() {
    let loud = SpeechTransmission.analyze(idealImpulse(), speechLevelDBA: 70)
    let quiet = SpeechTransmission.analyze(idealImpulse(), speechLevelDBA: 40)
    // A perfect channel keeps an STI of 1 at a normal speech level. The masking is more than 15 dB down.
    #expect(loud.sti > 0.99)
    // At 40 dB(A), the 125 Hz and 250 Hz speech levels are near the reception threshold.
    #expect(quiet.sti < loud.sti - 0.05)
}

@Test func stiOfAConstantMTF() {
    let one = SpeechTransmission.bands.map { _ in [Double](repeating: 1, count: 14) }
    #expect(SpeechTransmission.sti(mtf: one).sti == 1)
    let half = SpeechTransmission.bands.map { _ in [Double](repeating: 0.5, count: 14) }
    #expect(abs(SpeechTransmission.sti(mtf: half).sti - 0.5) < 1e-9)
    #expect(SpeechTransmission.sti(mtf: half).mti.allSatisfy { abs($0 - 0.5) < 1e-9 })
}

@Test func maskingSlopeIsContinuous() {
    for l in [63.0, 67.0] {
        #expect(abs(SpeechTransmission.maskingSlope(l - 1e-9) - SpeechTransmission.maskingSlope(l)) < 1e-6)
    }
    #expect(abs(SpeechTransmission.maskingSlope(100 - 1e-9) - SpeechTransmission.maskingSlope(100)) < 0.25)
}

@Test func ratingThresholds() {
    let cases: [(Double, String)] = [
        (1, "A+"), (0.76, "A+"), (0.7599, "A"), (0.72, "A"), (0.7199, "B"), (0.68, "B"), (0.64, "C"), (0.60, "D"),
        (0.56, "E"), (0.52, "F"), (0.48, "G"), (0.44, "H"), (0.40, "I"), (0.36, "J"), (0.3599, "U"), (0, "U"),
    ]
    for (sti, expected) in cases { #expect(SpeechTransmission.rating(sti) == expected, "\(sti)") }
}
