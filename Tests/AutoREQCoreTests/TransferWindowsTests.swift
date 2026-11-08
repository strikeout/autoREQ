@testable import AutoREQCore
import Foundation
import Testing

private func pink(_ n: Int, seed: UInt64 = 7) -> [Float] {
    var p = PinkNoise(seed: seed)
    return (0..<n).map { _ in p.next() * 5 }
}

/// Runs `analyzer` over `y` against `x` with ticks of 0.1 s at 48 kHz.
private func measure(_ a: WindowedTransferAnalyzer, x: [Float], y: [Float], ticks: Int) -> Response {
    let hop = 4800
    for t in 0..<ticks {
        let end = a.frameLength + t * hop
        a.add(reference: Array(x[(end - a.frameLength)..<end]), measured: Array(y[(end - a.frameLength)..<end]), newSamples: hop, interval: 0.1)
    }
    return a.response(latencySamples: 0)
}

@Test func windowedAnalyzerIsFlatForAWire() {
    let a = WindowedTransferAnalyzer(sampleRate: 48_000, averaging: .fifo8)
    let x = pink(a.frameLength + 10 * 4800)
    let r = measure(a, x: x, y: x, ticks: 10)
    for i in FrequencyGrid.index(of: 20)...FrequencyGrid.index(of: 20_000) {
        #expect(abs(r.magnitudeDB[i]) < 0.01 && abs(r.phaseDeg[i]) < 0.5)
    }
}

@Test func longWindowsResolveANarrowBassResonance() {
    let rate = 48_000.0
    let band = BiquadCoefficients(type: .peaking, frequency: 40, gainDB: 10, q: 8, sampleRate: rate)
    // The error is the largest difference from 30 Hz to 55 Hz. The flanks are steep, so 1 dB is the limit there.
    func error(_ multi: Bool) -> (max: Double, peak: Double) {
        let a = WindowedTransferAnalyzer(sampleRate: rate, averaging: .fifo32, multiWindow: multi)
        let x = pink(a.frameLength + 40 * 4800)
        var s = BiquadState(band)
        let y = x.map { Float(s.process(Double($0))) }
        let r = measure(a, x: x, y: y, ticks: 40)
        let errs = (FrequencyGrid.index(of: 30)...FrequencyGrid.index(of: 55))
            .map { abs(r.magnitudeDB[$0] - band.magnitudeDB(at: FrequencyGrid.frequencies[$0], sampleRate: rate)) }
        let peak = (FrequencyGrid.index(of: 35)...FrequencyGrid.index(of: 45)).map { r.magnitudeDB[$0] }.max()!
        return (errs.max()!, abs(peak - 10))
    }
    let ftw = error(true), single = error(false)
    #expect(ftw.max < 1 && ftw.peak < 1)
    #expect(single.max > 2 && single.peak > 3)
}

@Test func delayTrackerFollowsAOneMillisecondChangeIn2Seconds() {
    let rate = 48_000.0
    let ia = ImpulseAnalyzer(sampleRate: rate)
    let n = ia.fftSize, hop = 24_000
    let x = pink(n + 20 * hop + 1000)
    // The mic hears the noise 100 samples late, then 148 samples late from sample `change` on.
    let change = n + 200 + 2 * hop
    let y: [Float] = x.indices.map { i in
        let d = i < change ? 100 : 148
        return i >= d ? x[i - d] : 0
    }
    var offset = -100, tracker = DelayTracker(), followedAt: Int?
    for t in 0..<12 {
        let end = n + 200 + t * hop
        ia.add(reference: Array(x[(end - n + offset)..<(end + offset)]), measured: Array(y[(end - n)..<end]))
        if let d = tracker.update(lag: ia.latestPeakLag()) { offset -= d; ia.reset() }
        if offset == -148 && followedAt == nil { followedAt = end }
    }
    let at = try! #require(followedAt)
    #expect(Double(at - change) / rate <= 2)
}

@Test func aResponseDividedByItselfIsFlat() {
    var r = Response.flat()
    for i in r.magnitudeDB.indices { r.magnitudeDB[i] = sin(Double(i)) * 6; r.phaseDeg[i] = cos(Double(i)) * 90 }
    let d = r.dividing(by: r)
    #expect(d.magnitudeDB.allSatisfy { abs($0) < 1e-9 } && d.phaseDeg.allSatisfy { abs($0) < 1e-9 })
}

@Test func peakTimeFindsAFractionOfASample() throws {
    var s = [Float](repeating: 0, count: 100)
    s[60] = 1; s[59] = 0.5; s[61] = 0.5
    let ir = ImpulseResponse(samples: s, sampleRate: 48_000, zeroIndex: 10)
    #expect(abs(try #require(ir.peakTimeMs) - 50 / 48.0) < 1e-9)
    s[61] = 0.8
    let shifted = ImpulseResponse(samples: s, sampleRate: 48_000, zeroIndex: 10)
    #expect(try #require(shifted.peakTimeMs) > 50 / 48.0)
}
