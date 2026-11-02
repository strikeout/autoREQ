import Foundation
import Testing
@testable import AutoREQCore

@Test func peakingFilterHasItsGainAtTheCentre() {
    let c = BiquadCoefficients(type: .peaking, frequency: 1000, gainDB: 6, q: 2, sampleRate: 48_000)
    #expect(abs(c.magnitudeDB(at: 1000, sampleRate: 48_000) - 6) < 0.01)
    #expect(abs(c.magnitudeDB(at: 50, sampleRate: 48_000)) < 0.1)
    #expect(abs(20 * log10(c.response(at: 1000, sampleRate: 48_000).magnitude) - 6) < 0.01)
}

@Test func linkwitzRileyIsMinus6AtCrossoverAndSumsFlat() {
    let sr = 48_000.0
    let lp = Crossover(highPass: false, frequency: 80).coefficients(sampleRate: sr)
    let hp = Crossover(highPass: true, frequency: 80).coefficients(sampleRate: sr)
    for f in [20.0, 80, 300] {
        let l = lp.reduce(Complex.one) { $0 * $1.response(at: f, sampleRate: sr) }
        let h = hp.reduce(Complex.one) { $0 * $1.response(at: f, sampleRate: sr) }
        #expect(abs(20 * log10((l + h).magnitude)) < 0.1)
        if f == 80 { #expect(abs(20 * log10(l.magnitude) + 6.02) < 0.1) }
    }
}

@Test func delayFinderFindsAKnownLag() {
    var noise = PinkNoise()
    let ref = (0..<20_000).map { _ in noise.next() }
    let lag = 1234
    let measured = Array(ref[lag..<(lag + 8000)]).map { $0 * 0.3 }
    let r = DelayFinder.find(reference: ref, measured: measured)
    #expect(r?.lag == lag)
    #expect((r?.quality ?? 0) > 8)
}

@Test func analyzerRecoversAPeakingFilter() {
    let sr = 48_000.0
    let n = 16_384
    let band = EQBand(type: .peaking, frequency: 500, gainDB: -8, q: 1.5)
    var state = BiquadState(band.coefficients(sampleRate: sr))
    var noise = PinkNoise()
    let x = (0..<(n * 8)).map { _ in noise.next() }
    let y = x.map { Float(state.process(Double($0))) }
    let a = TransferAnalyzer(fftSize: n, sampleRate: sr, averaging: .fifo8)
    for k in 0..<7 {
        let s = k * n
        a.add(reference: Array(x[s..<(s + n)]), measured: Array(y[s..<(s + n)]))
    }
    let r = a.response(latencySamples: 0)
    let i500 = FrequencyGrid.index(of: 500), i5k = FrequencyGrid.index(of: 5000)
    #expect(abs(r.magnitudeDB[i500] + 8) < 0.5)
    #expect(abs(r.magnitudeDB[i5k]) < 0.5)
    #expect(r.coherence[i500] > 0.9)
}

@Test func targetCurveInterpolatesOnLogFrequency() {
    let t = TargetCurve(name: "t", points: [.init(100, 0), .init(1000, 10)])
    #expect(abs(t.gain(at: 316.2278) - 5) < 0.01)
    #expect(t.gain(at: 20) == 0)
    #expect(t.gain(at: 20_000) == 10)
}

@Test func optimizerFlattensASyntheticRoomMode() {
    let sr = 48_000.0
    // A room with a +10 dB mode at 60 Hz and a 4 dB dip at 200 Hz.
    let room = [EQBand(type: .peaking, frequency: 60, gainDB: 10, q: 5), EQBand(type: .peaking, frequency: 200, gainDB: -4, q: 2)]
    let measured = FrequencyGrid.frequencies.map { f in room.reduce(0) { $0 + $1.coefficients(sampleRate: sr).magnitudeDB(at: f, sampleRate: sr) } }
    let target = [Double](repeating: 0, count: FrequencyGrid.count)
    let coherence = [Double](repeating: 1, count: FrequencyGrid.count)
    var opt = CorrectionOptions()
    opt.filterCount = 6
    let o = EQOptimizer(measured: measured, target: target, coherence: coherence, range: 20...1000, options: opt, sampleRate: sr)
    let r = o.run()
    #expect(r.errorDB < 0.6)
    #expect(r.filters.contains { abs($0.frequency - 60) < 6 && $0.gainDB < -7 })
}

@Test func plannerAlignsALateSubAndBuildsACrossover() {
    let sr = 48_000.0
    var top = Response.flat(sampleRate: sr)
    // A top that rolls off below about 70 Hz.
    let hp = BiquadCoefficients(type: .highPass, frequency: 70, gainDB: 0, q: 0.707, sampleRate: sr)
    top = top.applying([hp])
    top.latencySamples = 1000
    var sub = Response.flat(sampleRate: sr)
    sub.latencySamples = 1100
    let speakers = SystemTemplate.stereoSub.speakers
    let m: [UUID: Response] = [speakers[0].id: top, speakers[1].id: top, speakers[2].id: sub]
    var opt = CorrectionOptions()
    opt.filterCount = 4
    opt.generations = .fastest
    opt.delayEstimation = .crossCorrelation
    let res = CalibrationPlanner(speakers: speakers, measurements: m, target: .absoluteFlat, options: opt).run()
    #expect(res.channels.count == 3)
    let xo = res.channels[0].correction.crossover
    #expect(xo?.highPass == true)
    #expect((60...150).contains(xo?.frequency ?? 0))
    // The sub arrives 100 samples late, so the tops get 100 samples (2.08 ms) of delay.
    let topDelay = res.channels[0].correction.delayMs
    let subDelay = res.channels[2].correction.delayMs
    #expect(abs((topDelay - subDelay) - 100 / sr * 1000) < 0.01)

    // The phase refinement must not leave a cancellation at the crossover.
    opt.delayEstimation = .minimumPhaseError
    let refined = CalibrationPlanner(speakers: speakers, measurements: m, target: .absoluteFlat, options: opt).run()
    let sum = refined.systemAfter!
    let fc = refined.channels[0].correction.crossover!.frequency
    let atXO = sum.magnitudeDB[FrequencyGrid.index(of: fc)]
    let at1k = sum.magnitudeDB[FrequencyGrid.index(of: 1000)]
    #expect(abs(atXO - at1k) < 3, "crossover sum \(atXO) vs 1 kHz \(at1k)")
}

@Test func csvRoundTrips() {
    var r = Response.flat()
    r.magnitudeDB[100] = 3
    r.latencySamples = 77
    let text = ResponseCSV.encode(r, name: "Left", colorHex: "#FFCC00")
    let back = ResponseCSV.decode(text)
    #expect(back?.name == "Left")
    #expect(back?.response.latencySamples == 77)
    #expect(abs((back?.response.magnitudeDB[100] ?? 0) - 3) < 0.01)
}

@Test func micCalibrationParsesAMiniDSPStyleFile() {
    let text = """
    "Sens Factor =-1.378dB, AGain =18dB, SERNO: 7001234"
    * a comment
    10.054\t-1.25
    100.0 0.10
    1000,0.00
    10000\t1.50\t-12.0
    20000 -2.0
    """
    let cal = MicCalibration.parse(text, name: "UMIK-1")
    #expect(cal?.points.count == 5)
    #expect(cal?.sensitivityDB == -1.378)
    #expect(cal?.serial == "7001234")
    #expect(abs((cal?.gain(at: 3162.28) ?? 0) - 0.75) < 0.01)
    #expect(cal?.gain(at: 5) == -1.25)

    var r = Response.flat()
    r = r.removing(mic: cal!)
    #expect(abs(r.magnitudeDB[FrequencyGrid.index(of: 10_000)] + 1.5) < 0.05)
    #expect(MicCalibration.parse(cal!.encode(), name: "x")?.points.count == 5)
}

@Test func builtInMicCurvesAreZeroAt1kHzAndFlatAbove5k() {
    for cal in MicCalibration.builtIn {
        #expect(cal.isTypical)
        #expect(abs(cal.gain(at: 1000)) < 0.01)
        #expect(cal.gain(at: 12_000) == cal.gain(at: 5000))
    }
}
