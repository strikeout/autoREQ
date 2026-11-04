import Accelerate
@testable import AutoREQCore
import Foundation
import Testing

private func render(_ s: SignalSettings, count n: Int, rate: Double = 48_000, period: Int = 65_536) -> [Float] {
    var g = SignalGenerator(s, sampleRate: rate, periodLength: period)
    var out = [Float](repeating: 0, count: n)
    out.withUnsafeMutableBufferPointer { g.render($0.baseAddress!, n) }
    return out
}

private func db(_ x: Float) -> Double { 20 * log10(Double(x)) }

@Test func eachSignalHasAnRMSOfOne() {
    for kind in SignalKind.allCases where kind != .file {
        let x = render(SignalSettings(kind: kind, frequency: 1000, frequency2: 60), count: 1 << 19)
        #expect(abs(db(vDSP.rootMeanSquare(x))) < 0.3, "\(kind.rawValue)")
    }
}

@Test func periodicPinkRepeatsExactly() {
    let x = render(SignalSettings(kind: .periodicPink), count: 3 * 65_536)
    for i in stride(from: 0, to: 65_536, by: 997) { #expect(x[i] == x[i + 65_536]) }
}

@Test func filePlaybackLoopsTheFile() {
    var g = SignalGenerator(SignalSettings(kind: .file), sampleRate: 48_000, fileSamples: [1, -1, 1, -1, 2])
    var out = [Float](repeating: 0, count: 10)
    out.withUnsafeMutableBufferPointer { g.render($0.baseAddress!, 10) }
    #expect(out[0] == out[5] && out[4] == out[9] && out[4] > out[0])
}

@Test func bandsFollowIEC61260() {
    let third = Band.bands(.oct3)
    #expect(third.count == 31)
    #expect(third.contains { abs($0.centre - 1000) < 1e-9 })
    #expect(third.map(\.label).prefix(3) == ["20", "25", "31.6"] || third.map(\.label).prefix(3) == ["20", "25.1", "31.6"])
    let oct = Band.bands(.oct1)
    #expect(oct.count == 10)
    #expect(abs(oct[0].upper - oct[1].lower) < 1e-9)
}

@Test func aSineReadsItsLevelInItsBand() {
    let rate = 48_000.0, n = 16_384
    let x = render(SignalSettings(kind: .sine, frequency: 1000), count: n).map { $0 * 0.1 } // -20 dB RMS
    let a = SpectrumAnalyzer(fftSize: n, sampleRate: rate)
    a.add(x)
    let bands = Band.bands(.oct3), levels = a.levels(.oct3)
    let i = bands.firstIndex { abs($0.centre - 1000) < 1 }!
    #expect(abs(levels[i] + 20) < 0.2)
    #expect(levels[i - 2] < -60 && levels[i + 2] < -60)
}

@Test func periodicPinkIsFlatInThirdOctaves() {
    let rate = 48_000.0, n = 16_384
    let x = render(SignalSettings(kind: .periodicPink), count: 65_536 + n)
    // 16 frames with a hop of n/4 cover one period. Their average removes most of the frame-to-frame scatter.
    let a = SpectrumAnalyzer(fftSize: n, sampleRate: rate, averaging: .fifo16)
    for f in 0..<16 { a.add(Array(x[(f * 4096)..<(f * 4096 + n)])) }
    let bands = Band.bands(.oct3), levels = a.levels(.oct3)
    let used = bands.indices.filter { bands[$0].centre >= 50 && bands[$0].centre <= 16_000 }
    let mean = used.map { levels[$0] }.reduce(0, +) / Double(used.count)
    for i in used { #expect(abs(levels[i] - mean) < 0.5, "\(bands[i].label) Hz") }
}

@Test func periodicNoiseGivesAnExactImpulseResponseAfterOneFrame() throws {
    let rate = 48_000.0
    let ia = ImpulseAnalyzer(sampleRate: rate)
    ia.periodic = true
    let n = ia.fftSize
    let x = render(SignalSettings(kind: .periodicPink), count: 2 * n, period: n)
    // The room: the direct sound after 48 samples and a reflection at -6 dB 10 ms later.
    var y = [Float](repeating: 0, count: 2 * n)
    for i in 528..<(2 * n) { y[i] = x[i - 48] + 0.5 * x[i - 528] }
    ia.add(reference: Array(x[n..<(2 * n)]), measured: Array(y[n..<(2 * n)]))
    let ir = try #require(ia.impulse())
    // The noise has energy from 20 Hz to 20 kHz only. A band-limited impulse has a peak of 2·(bins in the band)/N.
    let df = rate / Double(n)
    let inBand = Double((1..<(n / 2)).filter { Double($0) * df >= 20 && Double($0) * df <= 20_000 }.count)
    let peak = Float(2 * inBand / Double(n))
    #expect(abs(ir.samples[ir.zeroIndex + 48] / peak - 1) < 0.001)
    #expect(abs(ir.samples[ir.zeroIndex + 528] / peak - 0.5) < 0.001)
}
