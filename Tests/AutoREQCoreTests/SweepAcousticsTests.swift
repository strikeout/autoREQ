import Foundation
import Testing
@testable import AutoREQCore

/// A deterministic Gaussian noise source for the synthetic decay tests.
private struct Noise {
    var state: UInt64
    mutating func uniform() -> Double {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return (Double(state >> 11) + 0.5) / Double(1 << 53)
    }
    mutating func gauss() -> Double { (-2 * log(uniform())).squareRoot() * cos(2 * .pi * uniform()) }
}

private let sr = 48_000.0

@Test func sweepWireGivesOnePeakAndNoDistortion() {
    let sweep = LogSweep(seconds: 1.5, sampleRate: sr)
    let y = sweep.samples + [Float](repeating: 0, count: Int(0.5 * sr))
    let ir = sweep.impulse(fromRecorded: y)
    let peak = ir.samples.indices.max { abs(ir.samples[$0]) < abs(ir.samples[$1]) }!
    #expect(abs(peak - ir.zeroIndex) <= 4)
    #expect(abs(ir.samples[peak]) > 0.8 && abs(ir.samples[peak]) < 1.05)
    #expect(ir.samples.count == ir.zeroIndex + Int(0.5 * sr))
    let thd = sweep.distortion(fromRecorded: y)
    #expect(abs(thd.first!.frequency - 20) < 1e-9)
    #expect(thd.last!.frequency <= 10_000)
    let worst = thd.map(\.thdPercent).max()!
    #expect(worst < 0.003, "worst THD \(worst) %")
}

@Test func sweepShowsAReflection() {
    let sweep = LogSweep(seconds: 1.5, sampleRate: sr)
    var y = sweep.samples + [Float](repeating: 0, count: Int(0.5 * sr))
    for i in 0..<sweep.samples.count { y[i + 480] += 0.5 * sweep.samples[i] }
    let ir = sweep.impulse(fromRecorded: y)
    let direct = ir.samples[ir.zeroIndex]
    #expect(abs(ir.timeMs(ir.zeroIndex + 480) - 10) < 1e-9)
    #expect(abs(ir.samples[ir.zeroIndex + 480] / direct - 0.5) < 0.005)
}

@Test func sweepThirdHarmonicOfACubicNonlinearity() {
    let sweep = LogSweep(seconds: 1.5, sampleRate: sr)
    let a: Float = 0.1
    let y = sweep.samples.map { $0 + a * $0 * $0 * $0 } + [Float](repeating: 0, count: Int(0.5 * sr))
    // The fundamental has the amplitude 1 + 3a/4 and the third harmonic has a/4.
    let expected = 20 * log10(Double(a) / 4 / (1 + 3 * Double(a) / 4))
    let points = sweep.distortion(fromRecorded: y).filter { $0.frequency > 200 && $0.frequency < 3000 }
    #expect(points.count > 30)
    for p in points {
        #expect(abs(p.h3DB - expected) < 1, "H3 \(p.h3DB) dB at \(p.frequency) Hz, expected \(expected) dB")
        #expect(p.h2DB < -60)
    }
}

@Test func decayTimesOfAnExponentialDecay() {
    var noise = Noise(state: 12345)
    let t60 = 1.2
    let n = Int(2.4 * sr)
    let pre = 480
    var x = [Float](repeating: 0, count: pre + n)
    for i in 0..<n {
        let t = Double(i) / sr
        x[pre + i] = Float(noise.gauss() * exp(-6.91 * t / t60) + noise.gauss() * 1e-3)
    }
    let decays = RoomAcoustics.bandDecays(ImpulseResponse(samples: x, sampleRate: sr, zeroIndex: pre), banding: .oct1)
        .filter { $0.centre > 120 && $0.centre < 4100 }
    #expect(decays.count == 6)
    for d in decays {
        #expect(d.dynamicRangeDB > 45, "range \(d.dynamicRangeDB) dB at \(d.centre) Hz")
        #expect(abs((d.t20 ?? 0) - t60) < 0.05 * t60, "T20 \(d.t20 ?? 0) s at \(d.centre) Hz")
        #expect(abs((d.t30 ?? 0) - t60) < 0.05 * t60, "T30 \(d.t30 ?? 0) s at \(d.centre) Hz")
    }
}

@Test func decayTimesAreNilWithoutDynamicRange() {
    var noise = Noise(state: 99)
    // A decay of 20 dB above the noise gives an EDT but no T20 and no T30.
    var x = [Float](repeating: 0, count: Int(2 * sr))
    for i in x.indices { x[i] = Float(noise.gauss() * (exp(-6.91 * Double(i) / sr / 0.5) + 0.1)) }
    let d = RoomAcoustics.bandDecays(ImpulseResponse(samples: x, sampleRate: sr, zeroIndex: 0), banding: .oct1, range: 900...1100)
    #expect(d.count == 1)
    #expect(d[0].t30 == nil)
}

private func splitResponse() -> ImpulseResponse {
    let pre = 100
    var x = [Float](repeating: 0, count: pre + Int(0.4 * sr))
    x[pre] = 1
    // The tail runs from 50 ms to 300 ms with a flat energy of 1 in total.
    let from = pre + Int(0.05 * sr), to = pre + Int(0.3 * sr)
    for i in from..<to { x[i] = Float(1 / Double(to - from).squareRoot()) }
    return ImpulseResponse(samples: x, sampleRate: sr, zeroIndex: pre)
}

@Test func energyRatiosOfAKnownSplit() {
    let r = RoomAcoustics.energyRatios(splitResponse())
    #expect(abs(r.c50DB) < 0.2)
    #expect(abs(r.d50Percent - 50) < 1)
    // The tail has 12000 samples. The 30 ms from 50 ms to 80 ms hold 1440 of them.
    let early = 1 + 1440.0 / 12_000
    #expect(abs(r.c80DB - 10 * log10(early / (2 - early))) < 0.2)
    // The mean time of the tail is 175 ms. The direct sound is at 0. Half of the energy is in each.
    #expect(abs(r.tsMs - 87.5) < 1)
    #expect(abs(r.drrDB) < 0.2)
}

@Test func energyRatiosIgnoreTheNoiseTail() {
    var noise = Noise(state: 7)
    var ir = splitResponse()
    for i in ir.samples.indices { ir.samples[i] += Float(noise.gauss() * 1e-3) }
    let r = RoomAcoustics.energyRatios(ir)
    #expect(abs(r.c50DB) < 0.3)
    #expect(abs(r.d50Percent - 50) < 1.5)
}

@Test func wavRoundTripKeepsFloatSamples() throws {
    let left: [Float] = (0..<1000).map { sin(Float($0) * 0.1) }
    let right: [Float] = (0..<1000).map { Float($0) / 1000 - 0.5 }
    let data = WAVFile.encode([left, right], sampleRate: 44_100)
    let wav = try #require(WAVFile.decode(data))
    #expect(wav.sampleRate == 44_100)
    #expect(wav.channels == [left, right])
}

@Test func wavDecodesSixteenBitPCMAndSkipsUnknownChunks() throws {
    var d = Data()
    func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
    func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
    d.append(contentsOf: Array("RIFF".utf8)); u32(0)
    d.append(contentsOf: Array("WAVE".utf8))
    d.append(contentsOf: Array("LIST".utf8)); u32(3); d.append(contentsOf: [1, 2, 3, 0])
    d.append(contentsOf: Array("fmt ".utf8)); u32(16)
    u16(1); u16(1); u32(8000); u32(16_000); u16(2); u16(16)
    d.append(contentsOf: Array("data".utf8)); u32(6)
    for v: Int16 in [0, 16_384, -32_768] { u16(UInt16(bitPattern: v)) }
    let wav = try #require(WAVFile.decode(d))
    #expect(wav.sampleRate == 8000)
    #expect(wav.channels == [[0, 0.5, -1]])
    #expect(WAVFile.decode(Data([1, 2, 3])) == nil)
}

@Test func responseOfADelayedImpulseIsFlat() {
    var x = [Float](repeating: 0, count: 4800)
    x[480] = 1
    let r = Response(impulse: ImpulseResponse(samples: x, sampleRate: sr, zeroIndex: 480))
    #expect(r.magnitudeDB.count == FrequencyGrid.count)
    #expect(r.impulse != nil)
    for (i, f) in FrequencyGrid.frequencies.enumerated() where f >= 20 && f <= 20_000 {
        #expect(abs(r.magnitudeDB[i]) < 0.1, "magnitude \(r.magnitudeDB[i]) dB at \(f) Hz")
        #expect(abs(r.phaseDeg[i]) < 1, "phase \(r.phaseDeg[i]) deg at \(f) Hz")
    }
}
