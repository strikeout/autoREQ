import Foundation
import Testing
@testable import AutoREQCore

/// A sine with RMS `rms` at `f` Hz.
private func sine(_ f: Double, rms: Double, seconds: Double, sampleRate: Double = 48_000, phase: Double = 0) -> [Float] {
    let n = Int(seconds * sampleRate)
    return (0..<n).map { Float(rms * 2.0.squareRoot() * sin(2 * .pi * f * Double($0) / sampleRate + phase)) }
}

private func silence(_ seconds: Double, sampleRate: Double = 48_000) -> [Float] {
    [Float](repeating: 0, count: Int(seconds * sampleRate))
}

/// The calibration offset for a sine with RMS 0.1 that represents 94 dB SPL.
private let rms94 = 0.1
private let cal94 = LevelCalibration.offset(measuredRMSDBFS: 20 * log10(rms94))

@Test func analyticWeightingsMatchTheIECTable() {
    let a: [(Double, Double)] = [(31.5, -39.4), (63, -26.2), (125, -16.1), (250, -8.6), (500, -3.2),
                                 (1000, 0), (2000, 1.2), (4000, 1.0), (8000, -1.1), (10000, -2.5)]
    for (f, v) in a { #expect(abs(FrequencyWeighting.analyticDB(.a, at: f) - v) < 0.15, "A at \(f)") }
    let c: [(Double, Double)] = [(31.5, -3.0), (63, -0.8), (1000, 0), (4000, -0.8), (8000, -3.0), (10000, -4.4)]
    for (f, v) in c { #expect(abs(FrequencyWeighting.analyticDB(.c, at: f) - v) < 0.1, "C at \(f)") }
    #expect(FrequencyWeighting.analyticDB(.z, at: 123) == 0)
}

/// IEC 61672-1 Class 1 limits (plus, minus) at the test frequencies.
private let class1: [(f: Double, plus: Double, minus: Double)] = [
    (31.5, 2.0, 2.0), (63, 1.5, 1.5), (125, 1.5, 1.5), (250, 1.4, 1.4), (500, 1.4, 1.4), (1000, 1.1, 1.1),
    (2000, 1.6, 1.6), (4000, 1.6, 1.6), (8000, 2.1, 3.1), (10000, 2.6, 3.6),
]

@Test func digitalFiltersMatchTheAnalyticResponseAt48k() {
    for w in [FrequencyWeighting.a, .c] {
        let sections = w.filters(sampleRate: 48_000)
        for (f, plus, minus) in class1 {
            let digital = sections.reduce(0.0) { $0 + $1.magnitudeDB(at: f, sampleRate: 48_000) }
            let ideal = FrequencyWeighting.analyticDB(w, at: f)
            #expect(digital - ideal < plus && ideal - digital < minus, "\(w) at \(f): digital \(digital), ideal \(ideal)")
            #expect(abs(digital - ideal) < 0.35, "\(w) at \(f): digital \(digital), ideal \(ideal)")
        }
    }
    #expect(FrequencyWeighting.z.filters(sampleRate: 48_000).isEmpty)
}

@Test func digitalFiltersStayInsideClass1AtOtherRates() {
    for fs in [44_100.0, 96_000.0] {
        for w in [FrequencyWeighting.a, .c] {
            let sections = w.filters(sampleRate: fs)
            for (f, plus, minus) in class1 {
                let digital = sections.reduce(0.0) { $0 + $1.magnitudeDB(at: f, sampleRate: fs) }
                let ideal = FrequencyWeighting.analyticDB(w, at: f)
                #expect(digital - ideal < plus && ideal - digital < minus, "\(w) at \(f), \(fs): digital \(digital), ideal \(ideal)")
            }
        }
    }
}

@Test func calibratedToneReadsNinetyFourWithEveryWeighting() {
    let m = SoundLevelMeter(sampleRate: 48_000, calibrationDB: cal94, leqWindows: [(5, .a), (5, .c), (5, .z)])
    m.process(sine(1000, rms: rms94, seconds: 6))
    let l = m.levels()
    for w in [l.a, l.c, l.z] {
        #expect(abs(w.slow - 94) < 0.1)
        #expect(abs(w.fast - 94) < 0.1)
        #expect(abs(w.leq - 94) < 0.1)
    }
    for v in l.leqWindows { #expect(abs((v.value ?? 0) - 94) < 0.1) }
    #expect(abs(l.c.peak1s - (94 + 3.0103)) < 0.1)
    #expect(abs(l.elapsedSeconds - 6) < 1e-9)
}

@Test func fastAndSlowDetectorsDecayAtTheirTimeConstants() {
    let fast = SoundLevelMeter(sampleRate: 48_000, calibrationDB: cal94)
    fast.process(sine(1000, rms: rms94, seconds: 1))
    let before = fast.levels().a.fast
    fast.process(silence(0.2))
    let drop = before - fast.levels().a.fast
    #expect(abs(drop - 34.7 * 0.2) < 0.3)

    let slow = SoundLevelMeter(sampleRate: 48_000, calibrationDB: cal94)
    slow.process(sine(1000, rms: rms94, seconds: 5))
    let sBefore = slow.levels().a.slow
    slow.process(silence(1))
    let sDrop = sBefore - slow.levels().a.slow
    #expect(abs(sDrop - 4.34) < 0.3)
}

@Test func oneSecondBurstInTenSecondsGivesEightyFourLeq() {
    let m = SoundLevelMeter(sampleRate: 48_000, calibrationDB: cal94, leqWindows: [(10, .a)])
    m.process(sine(1000, rms: rms94, seconds: 1))
    m.process(silence(9))
    let l = m.levels()
    #expect(abs(l.a.leq - 84) < 0.1)
    #expect(abs((l.leqWindows[0].value ?? 0) - 84) < 0.1)
}

@Test func shortBurstGivesTheIECToneBurstMaxima() {
    let m = SoundLevelMeter(sampleRate: 48_000, calibrationDB: cal94)
    m.process(sine(1000, rms: rms94, seconds: 0.2))
    m.process(silence(2))
    let l = m.levels()
    #expect(abs(l.a.maxFast - (94 - 0.98)) < 0.3)
    #expect(abs(l.a.maxSlow - (94 - 7.4)) < 0.3)
}

@Test func doseMatchesTheCriteria() {
    var osha = NoiseDose()
    osha.add(levelDBA: 90, seconds: 8 * 3600)
    #expect(abs(osha.oshaPercent - 100) < 0.5)

    var niosh = NoiseDose()
    niosh.add(levelDBA: 85, seconds: 8 * 3600)
    #expect(abs(niosh.nioshPercent - 100) < 0.5)

    var half = NoiseDose()
    half.add(levelDBA: 95, seconds: 4 * 3600)
    #expect(abs(half.oshaPercent - 100) < 0.5)

    var quiet = NoiseDose()
    quiet.add(levelDBA: 79, seconds: 8 * 3600)
    #expect(quiet.oshaPercent == 0)
    #expect(quiet.nioshPercent > 0)

    var p = NoiseDose()
    p.add(levelDBA: 90, seconds: 3600)
    #expect(abs(p.projected8h(elapsedSeconds: 3600).osha - 100) < 0.5)
}

@Test func meterFeedsItsDose() {
    let m = SoundLevelMeter(sampleRate: 16_000, calibrationDB: LevelCalibration.offset(measuredRMSDBFS: 20 * log10(rms94)))
    m.process(sine(1000, rms: rms94, seconds: 4, sampleRate: 16_000))
    // A 94 dBA second is 1/3600 of the NIOSH day.
    #expect(abs(m.levels().nioshDosePercent - 4 / 3600 * 100) < 0.01)
    #expect(m.levels().oshaDosePercent > 0)
}

@Test func peaksFollowTheSignal() {
    let m = SoundLevelMeter(sampleRate: 48_000)
    var x = silence(0.1)
    x[100] = 1
    m.process(x)
    #expect(abs(m.levels().lzPeak) < 1e-6)
    let s = SoundLevelMeter(sampleRate: 48_000)
    s.process(sine(1000, rms: 1 / 2.0.squareRoot(), seconds: 3))
    // The first second holds the filter start-up transient, so the test reads the last second.
    #expect(abs(s.levels().c.peak1s) < 0.1)
    // A full-scale square wave has a peak of 0 dBFS.
    let q = SoundLevelMeter(sampleRate: 48_000)
    q.process((0..<4800).map { ($0 / 240) % 2 == 0 ? 1 : -1 })
    #expect(abs(q.levels().lzPeak) < 1e-6)
}

@Test func resetClearsTheMeter() {
    let m = SoundLevelMeter(sampleRate: 16_000, calibrationDB: 97)
    m.process(sine(1000, rms: 0.1, seconds: 2, sampleRate: 16_000))
    m.reset()
    let l = m.levels()
    #expect(l.elapsedSeconds == 0)
    #expect(l.a.maxFast < -100)
    #expect(l.leqWindows.allSatisfy { $0.value == nil })
}

@Test func logLineHasOneColumnForEachHeaderName() {
    let windows: [(seconds: Double, weighting: FrequencyWeighting)] = [(60, .a), (900, .c)]
    let header = SPLLogFormat.header(channels: ["Left", "Right"], leqWindows: windows)
    let m = SoundLevelMeter(sampleRate: 16_000, calibrationDB: 97, leqWindows: windows)
    m.process(sine(1000, rms: 0.1, seconds: 2, sampleRate: 16_000))
    let l = m.levels()
    let row = SPLLogFormat.row(time: Date(timeIntervalSince1970: 0), levels: [l, l])
    #expect(header.split(separator: ",", omittingEmptySubsequences: false).count
            == row.split(separator: ",", omittingEmptySubsequences: false).count)
    #expect(row.hasPrefix("1970-01-01T00:00:00Z,"))
    #expect(header.contains("Left LAeq60s"))
    #expect(header.contains("Right LCeq900s"))
}
