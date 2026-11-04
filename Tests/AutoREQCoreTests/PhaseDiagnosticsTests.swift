import Foundation
import Testing
@testable import AutoREQCore

private let sr = 48_000.0

private func lr4(_ highPass: Bool) -> [BiquadCoefficients] {
    Crossover(highPass: highPass, frequency: 80).coefficients(sampleRate: sr)
}

/// A flat response with `filters` added.
private func shaped(_ filters: [BiquadCoefficients], coherence: Double = 1) -> Response {
    var r = Response.flat(sampleRate: sr).applying(filters)
    r.coherence = r.coherence.map { _ in coherence }
    return r
}

private func sumDB(_ a: Response, _ b: Response, at f: Double) -> Double {
    let i = FrequencyGrid.index(of: f)
    return 20 * log10((a.complex(i) + b.complex(i)).magnitude)
}

@Test func allPassFiltersRemoveAPhaseRotationThatADelayCannotFix() {
    let rotation = BiquadCoefficients(type: .allPass, frequency: 60, gainDB: 0, q: 0.7, sampleRate: sr)
    let sub = shaped(lr4(false) + [rotation])
    let top = shaped(lr4(true))
    let band = 40.0...160.0
    // An all-pass filter adds lag only, so the filters go on the top, which leads.
    let r = PhaseAligner.allPassFilters(for: [top], against: [sub], band: band)
    #expect(!r.filters.isEmpty)
    #expect(r.filters.allSatisfy { $0.type == .allPass && $0.gainDB == 0 })
    #expect(r.after <= r.before * 0.5, "before \(r.before), after \(r.after)")
    #expect(abs(PhaseAligner.cost([top], against: [sub], band: band, filters: r.filters) - r.after) < 1e-9)
    let fixed = top.applying(r.filters.map { $0.coefficients(sampleRate: sr) })
    let before = sumDB(sub, top, at: 80), after = sumDB(sub, fixed, at: 80)
    #expect(after > before + 3, "sum at 80 Hz: before \(before) dB, after \(after) dB")
    #expect(abs(after) < 1, "sum at 80 Hz: \(after) dB")

    // `align` finds a side by itself and gets the same improvement.
    let a = PhaseAligner.align(subwoofers: [sub], tops: [top], band: band)
    #expect(!a.filters.isEmpty && a.after <= a.before * 0.5)
}

@Test func allPassFiltersAreEmptyWhenTheChannelsAreAligned() {
    let r = PhaseAligner.allPassFilters(for: [shaped(lr4(true))], against: [shaped(lr4(false))], band: 40...160)
    #expect(r.filters.isEmpty)
    #expect(r.before < 1e-6)
}

@Test func diagnosticsFindABoundaryNull() {
    let null = BiquadCoefficients(type: .peaking, frequency: 100, gainDB: -18, q: 3, sampleRate: sr)
    let f = Diagnostics.live(shaped([null]), channel: "Left", range: 20...20_000)
    let card = f.first { $0.kind == .boundaryNull }
    #expect(card != nil, "\(f.map(\.kind))")
    #expect(abs((card?.wallDistanceM ?? 0) - 0.85) < 0.001)
    #expect(card?.detail.contains("0.85 m") == true)
}

@Test func diagnosticsFindAWeakMeasurement() {
    let f = Diagnostics.live(shaped([], coherence: 0.5), channel: "Left", range: 20...20_000)
    #expect(f.first?.kind == .weakMeasurement)
    #expect(f.first?.severity == .warning)
}

@Test func diagnosticsFindARoomModePeak() {
    let peak = BiquadCoefficients(type: .peaking, frequency: 45, gainDB: 8, q: 5, sampleRate: sr)
    let f = Diagnostics.live(shaped([peak]), channel: "Sub", range: 20...200)
    let card = f.first { $0.kind == .roomModePeak }
    #expect(card != nil, "\(f.map(\.kind))")
    #expect(abs(log2((card?.frequency ?? 0) / 45)) < 0.05)
}

@Test func diagnosticsUseTheUsableRangeOfASub() {
    // A sub gives noise above its pass band. That noise must not make the measurement weak.
    var sub = shaped(lr4(false) + lr4(false))
    for i in sub.coherence.indices where sub.magnitudeDB[i] < -30 { sub.coherence[i] = 0.05 }
    let f = Diagnostics.live(sub, channel: "Sub", range: 20...20_000)
    #expect(!f.contains { $0.kind == .weakMeasurement }, "\(f.map(\.kind))")
    #expect(f.contains { $0.kind == .outsideUsableRange })
}

@Test func diagnosticsGiveNoWarningsForAFlatResponse() {
    let f = Diagnostics.live(.flat(sampleRate: sr), channel: "Left", range: 20...20_000)
    #expect(f.isEmpty, "\(f.map(\.title))")
}

@Test func diagnosticsResultsTellThatTheEQCutAPeak() {
    let peak = BiquadCoefficients(type: .peaking, frequency: 45, gainDB: 8, q: 5, sampleRate: sr)
    let cut = EQBand(type: .peaking, frequency: 45, gainDB: -8, q: 5)
    var corr = ChannelCorrection(speaker: Speaker(name: "Sub", role: .subwoofer, source: .mono, outputChannel: 0), outputChannel: 0)
    corr.eq = [cut]
    let before = shaped([peak])
    let after = before.applying([cut.coefficients(sampleRate: sr)])
    let c = ChannelResult(correction: corr, before: before, after: after, target: .init(repeating: 0, count: FrequencyGrid.count),
                          correctedRange: 20...200, errorDB: 0)
    let card = Diagnostics.results(c, impulse: nil).first { $0.kind == .roomModePeak }
    #expect(card?.severity == .info)
    #expect(card?.action.contains("cuts this peak") == true)
}

@Test func listeningAreasShareTheAreaWeightAmongThePositions() {
    let main = Array(repeating: Response.flat(sampleRate: sr), count: 3)
    let quiet = Array(repeating: Response.flat(sampleRate: sr).offset(delayMs: 0, gainDB: -6, inverted: false), count: 9)
    let r = ListeningArea.combine([(weight: 1, positions: main), (weight: 1, positions: quiet)])
    let expected = 10 * log10((1 + pow(10, -0.6)) / 2)
    #expect(abs((r?.magnitudeDB[200] ?? 0) - expected) < 0.01, "\(r?.magnitudeDB[200] ?? 0) vs \(expected)")
    #expect(ListeningArea(name: "Main", size: .venue).positions == 9)
}

@Test func plannerPhaseCorrectionFixesARotatedSub() {
    let sr = 48_000.0
    var top = Response.flat(sampleRate: sr).applying([BiquadCoefficients(type: .highPass, frequency: 70, gainDB: 0, q: 0.707, sampleRate: sr)])
    top.latencySamples = 1000
    // The sub has an extra phase rotation that no delay can remove.
    var sub = Response.flat(sampleRate: sr).applying([BiquadCoefficients(type: .allPass, frequency: 60, gainDB: 0, q: 0.7, sampleRate: sr)])
    sub.latencySamples = 1000
    let speakers = SystemTemplate.stereoSub.speakers
    let m: [UUID: Response] = [speakers[0].id: top, speakers[1].id: top, speakers[2].id: sub]
    var opt = CorrectionOptions()
    opt.filterCount = 0
    opt.generations = .fastest
    func dip(_ on: Bool) -> Double {
        opt.phaseCorrection = on
        let r = CalibrationPlanner(speakers: speakers, measurements: m, target: .absoluteFlat, options: opt).run()
        // The loss of the complex sum against the magnitude sum at the crossover.
        let i = FrequencyGrid.index(of: r.channels[0].correction.crossover!.frequency)
        let magSum = r.channels.map { pow(10, $0.after.magnitudeDB[i] / 20) }.reduce(0, +)
        return 20 * log10(magSum) - r.systemAfter!.magnitudeDB[i]
    }
    let without = dip(false), with = dip(true)
    #expect(with <= without + 0.1, "with \(with) dB, without \(without) dB")
    #expect(with < 1)
}
