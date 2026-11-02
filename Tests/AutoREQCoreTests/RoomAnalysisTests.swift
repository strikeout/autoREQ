import Foundation
import Testing
@testable import AutoREQCore

@Test func impulseAnalyzerFindsADirectSoundAndOneReflection() {
    let sr = 48_000.0
    let a = ImpulseAnalyzer(sampleRate: sr)
    let n = a.fftSize
    var noise = PinkNoise()
    let x = (0..<(n * 9)).map { _ in noise.next() }
    // The reflection arrives 10 ms after the direct sound, 6 dB lower.
    let d = 480
    let y = x.indices.map { x[$0] + ($0 >= d ? 0.5 * x[$0 - d] : 0) }
    for k in 1..<9 { a.add(reference: Array(x[(k * n)..<((k + 1) * n)]), measured: Array(y[(k * n)..<((k + 1) * n)])) }
    let ir = a.impulse()!
    #expect(abs(ir.samples[ir.zeroIndex] - 1) < 0.05)
    #expect(abs(ir.samples[ir.zeroIndex + d] - 0.5) < 0.05)
    let r = RoomAnalysis.reflections(ir)
    let main = r.max { $0.levelDB < $1.levelDB }
    #expect(main.map { abs($0.delayMs - 10) < 0.05 } == true)
    #expect(main.map { abs($0.levelDB + 6) < 1 } == true)
    #expect(main.map { abs($0.extraPathM - 3.43) < 0.02 } == true)
}

@Test func roomModeHasTheQAndDecayOfASyntheticResonance() {
    let sr = 48_000.0
    let f0 = 50.0, t60 = 0.4
    let tau = t60 / log(1000)
    let amp = 20 / (tau * sr)
    var s = [Float](repeating: 0, count: 32_768 + 480)
    let z = 480
    s[z] = 1
    for i in 0..<(s.count - z) {
        let t = Double(i) / sr
        s[z + i] += Float(amp * exp(-t / tau) * cos(2 * .pi * f0 * t))
    }
    let ir = ImpulseResponse(samples: s, sampleRate: sr, zeroIndex: z)
    let modes = RoomAnalysis.modes(response: nil, impulse: ir)
    let m = modes.max { $0.levelDB < $1.levelDB }
    #expect(m.map { abs($0.frequency - f0) < 0.5 } == true)
    // A resonance with time constant tau has Q = pi f0 tau.
    let q = Double.pi * f0 * tau
    #expect(m.map { abs($0.q - q) / q < 0.2 } == true)
    #expect(m.map { abs($0.t60FromQ - t60) / t60 < 0.2 } == true)
    #expect(m?.t60Measured.map { abs($0 - t60) / t60 < 0.2 } == true)
}

@Test func impulseResponseSurvivesACodableRoundTrip() throws {
    var r = Response.flat()
    r.impulse = ImpulseResponse(samples: [0, 1, -0.5, 0.25], sampleRate: 48_000, zeroIndex: 1)
    let back = try JSONDecoder().decode(Response.self, from: JSONEncoder().encode(r))
    #expect(back.impulse == r.impulse)
    // A state file from v1.0 has no impulse key.
    let old = try JSONDecoder().decode(Response.self, from: JSONEncoder().encode(Response.flat()))
    #expect(old.impulse == nil)
}
