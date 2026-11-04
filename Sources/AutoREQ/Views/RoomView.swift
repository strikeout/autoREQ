import AutoREQCore
import Charts
import SwiftUI

/// The impulse response, the energy-time curve, the reflections and the room modes of one measurement.
struct RoomView: View {
    @Environment(AppModel.self) private var model
    @State private var sourceID = "live"
    @State private var span: Span = .ms100
    @State private var result: Result?
    @State private var compareIDs: Set<UUID> = []
    @State private var banding: Banding = .oct1
    @State private var sweepChannel = 0
    @State private var sweepSeconds = 2.0
    @State private var sweepRepeats = 2
    @State private var sweepPeak = -12.0
    @State private var speechDBA = 60.0
    @State private var noiseBands: [Double]?
    @State private var auditory = true
    @State private var sti: STIResult?
    @State private var measuringNoise = false

    private struct STIKey: Hashable {
        var ir: ImpulseResponse?
        var speech: Double
        var noise: [Double]?
        var auditory: Bool
    }

    enum Span: Double, CaseIterable, Identifiable {
        case ms20 = 20, ms50 = 50, ms100 = 100, ms300 = 300, all = 1000
        var id: Double { rawValue }
        var label: String { self == .all ? "All" : "\(Int(rawValue)) ms" }
    }

    struct Result {
        var etc: [Double]
        var reflections: [Reflection]
        var modes: [RoomMode]
        var decays: [BandDecay] = []
        var bandRatios: [RoomAcoustics.EnergyRatios] = []
        var ratios: RoomAcoustics.EnergyRatios?
        /// The energy-time curves of the compared snapshots, in their own time base.
        var overlays: [(name: String, color: Color, ir: ImpulseResponse, etc: [Double])] = []
    }

    private struct Key: Hashable {
        var source: Response?
        var compare: Set<UUID>
        var banding: Banding
    }

    private var snapshot: Snapshot? { model.state.snapshots.first { $0.id.uuidString == sourceID } }

    private var source: Response? {
        if sourceID == "live" { return model.live }
        return snapshot?.response
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Room Analysis").font(.title2.bold())
                Text("Measure with a log sweep below, or take a snapshot on the Measure page. A sweep gives a 2 s impulse response with distortion.")
                    .foregroundStyle(.secondary)
                sweepPanel
                HStack {
                    Picker("Measurement", selection: $sourceID) {
                        Text("Live").tag("live")
                        ForEach(model.state.snapshots) { s in
                            Text(s.response.impulse == nil ? "\(s.name) (no impulse response)" : s.name).tag(s.id.uuidString)
                        }
                    }
                    .frame(maxWidth: 360)
                    Spacer()
                    Picker("Time", selection: $span) {
                        ForEach(Span.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 360)
                }
                HStack {
                    Menu("Compare (\(compareIDs.count))") {
                        ForEach(model.state.snapshots.filter { $0.response.impulse != nil && $0.id.uuidString != sourceID }) { s in
                            Toggle(s.name, isOn: Binding(get: { compareIDs.contains(s.id) }, set: { if $0 { compareIDs.insert(s.id) } else { compareIDs.remove(s.id) } }))
                        }
                    }
                    .fixedSize()
                    .help("Shows the energy-time curves of other snapshots in the same chart.")
                    Spacer()
                    if let s = snapshot, s.response.impulse != nil { Button("Export IR as WAV…") { model.exportImpulse(s) } }
                    Button("Import IR from WAV…") { model.importImpulses() }
                }
                if let r = source {
                    if let ir = r.impulse, let res = result {
                        timeDomain(ir, res)
                    } else if r.impulse == nil {
                        Text("This measurement has no impulse response. The mode list uses the frequency response only, and it has no measured decay.")
                            .foregroundStyle(.orange)
                    }
                    if let res = result {
                        HStack(alignment: .top, spacing: 16) {
                            if r.impulse != nil { reflectionTable(res.reflections) }
                            modeTable(res.modes)
                        }
                        if r.impulse != nil { decayTable(res) }
                        if r.impulse != nil { stiBox }
                    }
                    if let d = snapshot?.distortion, !d.isEmpty { distortionChart(d) }
                } else {
                    Text("Start the noise on the Measure page, or select a snapshot.").foregroundStyle(.secondary)
                }
            }
            .padding(24)
        }
        .task(id: STIKey(ir: source?.impulse, speech: speechDBA, noise: noiseBands, auditory: auditory)) {
            guard let ir = source?.impulse else { sti = nil; return }
            let (s, n, a) = (speechDBA, noiseBands, auditory)
            sti = await Task.detached(priority: .userInitiated) {
                SpeechTransmission.analyze(ir, speechLevelDBA: s, noiseBandLevels: n, auditoryEffects: a)
            }.value
        }
        .task(id: Key(source: source, compare: compareIDs, banding: banding)) {
            guard let r = source else { result = nil; return }
            let others = model.state.snapshots.filter { compareIDs.contains($0.id) }.compactMap { s in s.response.impulse.map { (s.name, s.color, $0) } }
            let b = banding
            result = await Task.detached(priority: .userInitiated) {
                let etc = r.impulse.map(RoomAnalysis.etc) ?? []
                var res = Result(etc: etc, reflections: r.impulse.map { RoomAnalysis.reflections($0, etc: etc) } ?? [],
                                 modes: RoomAnalysis.modes(response: r, impulse: r.impulse))
                if let ir = r.impulse {
                    res.decays = RoomAcoustics.bandDecays(ir, banding: b)
                    res.bandRatios = res.decays.map { RoomAcoustics.energyRatios(ir, band: Band(centre: $0.centre, lower: $0.lower, upper: $0.upper)) }
                    res.ratios = RoomAcoustics.energyRatios(ir)
                }
                res.overlays = others.map { (name: $0.0, color: $0.1, ir: $0.2, etc: RoomAnalysis.etc($0.2)) }
                return res
            }.value
        }
    }

    // MARK: - Time domain

    /// The visible sample range: 2 ms before lag 0 to the end of the span.
    private func window(_ ir: ImpulseResponse) -> Range<Int> {
        let lo = max(0, ir.zeroIndex - Int(0.002 * ir.sampleRate))
        let hi = min(ir.samples.count, ir.zeroIndex + Int(span.rawValue / 1000 * ir.sampleRate))
        return lo..<max(hi, lo + 1)
    }

    /// Reduces `values` to about 1000 points. Each bucket keeps its value with the largest magnitude.
    private func decimate(_ values: [Double], _ range: Range<Int>, _ ir: ImpulseResponse) -> [(t: Double, v: Double)] {
        let step = max(1, range.count / 1000)
        return stride(from: range.lowerBound, to: range.upperBound, by: step).map { i in
            let j = (i..<min(i + step, range.upperBound)).max { abs(values[$0]) < abs(values[$1]) } ?? i
            return (ir.timeMs(j), values[j])
        }
    }

    @ViewBuilder
    private func timeDomain(_ ir: ImpulseResponse, _ res: Result) -> some View {
        let range = window(ir)
        let peak = Double(ir.samples.map(abs).max() ?? 1)
        let irPoints = decimate(ir.samples.map { Double($0) / max(peak, 1e-12) }, range, ir)
        // The ETC is in negative dB, so the largest magnitude is the lowest value. Plot the bucket maximum instead.
        let etcPoints = stride(from: range.lowerBound, to: range.upperBound, by: max(1, range.count / 1000)).map { i in
            (t: ir.timeMs(i), v: max(res.etc[i..<min(i + max(1, range.count / 1000), range.upperBound)].max() ?? -90, -90))
        }
        let xDomain = ir.timeMs(range.lowerBound)...ir.timeMs(range.upperBound - 1)
        GroupBox("Impulse response") {
            Chart(Array(irPoints.enumerated()), id: \.offset) { _, p in
                LineMark(x: .value("ms", p.t), y: .value("Amplitude", p.v)).foregroundStyle(.yellow).lineStyle(StrokeStyle(lineWidth: 1))
            }
            .chartXScale(domain: xDomain)
            .chartYScale(domain: -1...1)
            .chartXAxisLabel("ms")
            .frame(height: 150)
            .padding(6)
        }
        GroupBox("Energy-time curve") {
            Chart {
                ForEach(Array(etcPoints.enumerated()), id: \.offset) { _, p in
                    AreaMark(x: .value("ms", p.t), yStart: .value("dB", -90), yEnd: .value("dB", p.v))
                        .foregroundStyle(.yellow.opacity(0.35))
                    LineMark(x: .value("ms", p.t), y: .value("dB", p.v)).foregroundStyle(.yellow).lineStyle(StrokeStyle(lineWidth: 1))
                }
                ForEach(Array(res.overlays.enumerated()), id: \.offset) { k, o in
                    let pts = overlayPoints(o.ir, o.etc, xDomain)
                    ForEach(Array(pts.enumerated()), id: \.offset) { _, p in
                        LineMark(x: .value("ms", p.t), y: .value("dB", p.v), series: .value("Snapshot", "o\(k)"))
                            .foregroundStyle(o.color).lineStyle(StrokeStyle(lineWidth: 1))
                    }
                }
                ForEach(Array(res.reflections.enumerated()), id: \.element.id) { n, r in
                    if xDomain.contains(ir.timeMs(r.index)) {
                        PointMark(x: .value("ms", ir.timeMs(r.index)), y: .value("dB", r.levelDB))
                            .foregroundStyle(.red)
                            .annotation(position: .top) { Text("\(n + 1)").font(.caption2).foregroundStyle(.red) }
                    }
                }
            }
            .chartXScale(domain: xDomain)
            .chartYScale(domain: -70...5)
            .chartPlotStyle { $0.clipped() }
            .chartXAxisLabel("ms")
            .chartYAxisLabel("dB")
            .frame(height: 200)
            .padding(6)
        }
    }

    /// The bucket maximum of an overlay ETC in the time range of the main chart.
    private func overlayPoints(_ ir: ImpulseResponse, _ etc: [Double], _ domain: ClosedRange<Double>) -> [(t: Double, v: Double)] {
        let lo = max(0, ir.zeroIndex + Int(domain.lowerBound / 1000 * ir.sampleRate))
        let hi = min(etc.count, ir.zeroIndex + Int(domain.upperBound / 1000 * ir.sampleRate))
        guard hi > lo else { return [] }
        let step = max(1, (hi - lo) / 600)
        return stride(from: lo, to: hi, by: step).map { i in (ir.timeMs(i), max(etc[i..<min(i + step, hi)].max() ?? -90, -90)) }
    }

    // MARK: - Sweep, decay and distortion

    private var sweepPanel: some View {
        GroupBox("Measure with a log sweep") {
            HStack(spacing: 12) {
                Picker("Output", selection: $sweepChannel) {
                    ForEach(0..<(model.outputDevice?.outputChannels ?? 2), id: \.self) { c in
                        let names = model.state.speakers.filter { $0.outputChannel == c }.map(\.name)
                        Text("Ch \(c + 1)" + (names.isEmpty ? "" : " — " + names.joined(separator: ", "))).tag(c)
                    }
                }
                .frame(width: 200)
                Picker("Length", selection: $sweepSeconds) { ForEach([1.0, 2, 5, 10], id: \.self) { Text("\(Int($0)) s").tag($0) } }.frame(width: 120)
                Stepper("\(sweepRepeats)×", value: $sweepRepeats, in: 1...8).fixedSize()
                Stepper("Peak \(Int(sweepPeak)) dBFS", value: $sweepPeak, in: -40...(-3), step: 1).fixedSize()
                if let p = model.sweepProgress {
                    ProgressView().controlSize(.small)
                    Text(p).foregroundStyle(.secondary)
                    Button("Stop") { model.setNoise([]) }
                } else {
                    Button { Task { await model.measureSweep(channel: sweepChannel, seconds: sweepSeconds, repeats: sweepRepeats, peakDBFS: sweepPeak) } } label: {
                        Label("Measure", systemImage: "waveform")
                    }
                }
                Spacer()
            }
            .padding(6)
            Text("A sweep is louder than pink noise at the same peak level. Set the amplifier low before you start. Each sweep has 2 s of silence for the decay.")
                .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 6)
        }
    }

    private func decayTable(_ res: Result) -> some View {
        GroupBox {
            Grid(alignment: .trailing, horizontalSpacing: 20, verticalSpacing: 4) {
                GridRow { Text("Band"); Text("EDT"); Text("T20"); Text("T30"); Text("C50"); Text("C80"); Text("D50"); Text("Range") }
                    .font(.caption.bold()).foregroundStyle(.secondary)
                ForEach(Array(res.decays.enumerated()), id: \.offset) { i, d in
                    let e = res.bandRatios.indices.contains(i) ? res.bandRatios[i] : nil
                    GridRow {
                        Text(Band(centre: d.centre, lower: d.lower, upper: d.upper).label + " Hz")
                        Text(seconds(d.edt)); Text(seconds(d.t20)); Text(seconds(d.t30))
                        Text(e.map { String(format: "%+.1f dB", $0.c50DB) } ?? "–")
                        Text(e.map { String(format: "%+.1f dB", $0.c80DB) } ?? "–")
                        Text(e.map { String(format: "%.0f %%", $0.d50Percent) } ?? "–")
                        Text(String(format: "%.0f dB", d.dynamicRangeDB)).foregroundStyle(.secondary)
                    }
                    .monospacedDigit()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
            if let r = res.ratios {
                Text(String(format: "Broadband: C50 %+.1f dB · C80 %+.1f dB · D50 %.0f %% · Ts %.0f ms · D/R %+.1f dB", r.c50DB, r.c80DB, r.d50Percent, r.tsMs, r.drrDB))
                    .monospacedDigit().frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 6)
            }
            Text("EDT, T20 and T30 are decay times to −60 dB. A time shows only when the band has enough range above the noise: 10, 25 and 35 dB. C50 and D50 relate to speech, and C80 relates to music.")
                .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 6)
        } label: {
            HStack {
                Text("Decay and clarity")
                Picker("", selection: $banding) {
                    Text("Octaves").tag(Banding.oct1)
                    Text("1/3 octaves").tag(Banding.oct3)
                }
                .pickerStyle(.segmented).frame(width: 220)
            }
        }
    }

    // MARK: - Speech intelligibility

    private var stiBox: some View {
        GroupBox("Speech intelligibility (STI)") {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 14) {
                    Stepper("Speech level \(Int(speechDBA)) dB(A)", value: $speechDBA, in: 40...100, step: 1).fixedSize()
                    Toggle("Auditory masking and threshold", isOn: $auditory)
                    if let n = noiseBands {
                        Text("Noise: " + zip(SpeechTransmission.bands, n).map { String(format: "%@ %.0f", Band(centre: $0.0, lower: $0.0, upper: $0.0).label, $0.1) }.joined(separator: " · "))
                            .font(.caption).monospacedDigit()
                        Button("Clear Noise") { noiseBands = nil }
                    } else if measuringNoise {
                        ProgressView().controlSize(.small)
                        Text("Reading the room noise for 5 s…").foregroundStyle(.secondary)
                    } else {
                        Button("Measure Background Noise") {
                            measuringNoise = true
                            Task { noiseBands = await model.measureNoiseBands(channel: model.state.micChannel); measuringNoise = false }
                        }
                    }
                    Spacer()
                }
                if let s = sti {
                    HStack(alignment: .top, spacing: 30) {
                        VStack(alignment: .leading) {
                            Text("STI").font(.caption).foregroundStyle(.secondary)
                            Text(String(format: "%.2f", s.sti)).font(.system(size: 34, weight: .semibold, design: .rounded)).monospacedDigit()
                            Text("Class \(s.rating)").foregroundStyle(.secondary)
                        }
                        VStack(alignment: .leading) {
                            Text("STIPA").font(.caption).foregroundStyle(.secondary)
                            Text(String(format: "%.2f", s.stipa)).font(.system(size: 34, weight: .semibold, design: .rounded)).monospacedDigit()
                            Text("Class \(s.stipaRating)").foregroundStyle(.secondary)
                        }
                        Chart {
                            ForEach(Array(zip(s.bands, s.mti).enumerated()), id: \.offset) { _, p in
                                BarMark(x: .value("Band", Band(centre: p.0, lower: p.0, upper: p.0).label), y: .value("MTI", p.1))
                                    .foregroundStyle(.yellow)
                            }
                        }
                        .chartYScale(domain: 0...1)
                        .chartYAxisLabel("Transmission index")
                        .frame(height: 140)
                    }
                    ForEach(s.notes, id: \.self) { Text($0).font(.caption).foregroundStyle(.orange) }
                }
                Text("The app calculates the STI from the impulse response with the indirect method of IEC 60268-16. Without measured noise, the STI shows the room and the speaker only. The values of the masking model come from the published rev-4 model and are not checked against the text of edition 5.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(6)
        }
    }

    private func seconds(_ v: Double?) -> String { v.map { String(format: "%.2f s", $0) } ?? "–" }

    private func distortionChart(_ d: [HarmonicPoint]) -> some View {
        GroupBox("Distortion of the sweep") {
            Chart {
                ForEach(Array(d.enumerated()), id: \.offset) { _, p in
                    if p.thdPercent > 0 {
                        LineMark(x: .value("Hz", p.frequency), y: .value("dB", 20 * log10(p.thdPercent / 100)), series: .value("Curve", "THD"))
                            .foregroundStyle(by: .value("Curve", "THD"))
                    }
                    if p.h2DB > -150 {
                        LineMark(x: .value("Hz", p.frequency), y: .value("dB", p.h2DB), series: .value("Curve", "H2"))
                            .foregroundStyle(by: .value("Curve", "H2"))
                    }
                    if p.h3DB > -150 {
                        LineMark(x: .value("Hz", p.frequency), y: .value("dB", p.h3DB), series: .value("Curve", "H3"))
                            .foregroundStyle(by: .value("Curve", "H3"))
                    }
                }
            }
            .chartForegroundStyleScale(["THD": Color.yellow, "H2": Color.cyan, "H3": Color.pink])
            .chartXScale(domain: 20...20_000, type: .log)
            .chartYScale(domain: -100...0)
            .chartXAxis { ResponseChart.frequencyAxis }
            .chartYAxisLabel("dB re fundamental")
            .chartPlotStyle { $0.clipped() }
            .frame(height: 200)
            .padding(6)
            Text("−40 dB is 1 % distortion. −20 dB is 10 %. Room noise sets a floor, so a low reading can be noise and not the speaker.")
                .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 6)
        }
    }

    private func reflectionTable(_ list: [Reflection]) -> some View {
        GroupBox("Reflections in the first 100 ms") {
            if list.isEmpty {
                Text("No reflection is 10 dB above the noise and above -30 dB.").foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(6)
            } else {
                Grid(alignment: .trailing, horizontalSpacing: 24, verticalSpacing: 4) {
                    GridRow { Text("#"); Text("Delay"); Text("Level"); Text("Extra path") }.font(.caption.bold()).foregroundStyle(.secondary)
                    ForEach(Array(list.enumerated()), id: \.element.id) { n, r in
                        GridRow {
                            Text("\(n + 1)")
                            Text(String(format: "%.2f ms", r.delayMs))
                            Text(String(format: "%.1f dB", r.levelDB))
                            Text(String(format: "%.2f m", r.extraPathM))
                        }
                        .monospacedDigit()
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
                Text("The delay and the level are relative to the direct sound. The extra path is the delay at 343 m/s: a wall at distance d behind the mic adds about 2d.")
                    .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 6)
            }
        }
    }

    private func modeTable(_ modes: [RoomMode]) -> some View {
        GroupBox("Room modes, 15–300 Hz") {
            if modes.isEmpty {
                Text("No peak is 3 dB above the one-octave average.").foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(6)
            } else {
                Grid(alignment: .trailing, horizontalSpacing: 24, verticalSpacing: 4) {
                    GridRow { Text("Frequency"); Text("Level"); Text("Q"); Text("T60 from Q"); Text("T60 measured") }
                        .font(.caption.bold()).foregroundStyle(.secondary)
                    ForEach(modes) { m in
                        GridRow {
                            Text(String(format: "%.1f Hz", m.frequency))
                            Text(String(format: "+%.1f dB", m.levelDB))
                            Text(String(format: "%.1f", m.q))
                            Text(String(format: "%.0f ms", m.t60FromQ * 1000))
                            Text(m.t60Measured.map { String(format: "%.0f ms", $0 * 1000) } ?? "–")
                        }
                        .monospacedDigit()
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
                Text("Level is the height above the one-octave average. T60 from Q is the decay of a resonance with that Q. T60 measured comes from the impulse response in a 1/3-octave band, so a near mode or a short measurement changes it. A long decay (above about 300 ms) shows a mode that EQ can reduce but not remove.")
                    .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 6)
            }
        }
    }
}
