import AutoREQCore
import Charts
import SwiftUI

/// The impulse response, the energy-time curve, the reflections and the room modes of one measurement.
struct RoomView: View {
    @Environment(AppModel.self) private var model
    @State private var sourceID = "live"
    @State private var span: Span = .ms100
    @State private var result: Result?

    enum Span: Double, CaseIterable, Identifiable {
        case ms20 = 20, ms50 = 50, ms100 = 100, ms300 = 300, all = 1000
        var id: Double { rawValue }
        var label: String { self == .all ? "All" : "\(Int(rawValue)) ms" }
    }

    struct Result {
        var etc: [Double]
        var reflections: [Reflection]
        var modes: [RoomMode]
    }

    private var source: Response? {
        if sourceID == "live" { return model.live }
        return model.state.snapshots.first { $0.id.uuidString == sourceID }?.response
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Room Analysis").font(.title2.bold())
                Text("Measure a speaker on the Measure page, then take a snapshot. A measurement needs about 5 s of pink noise for a clean impulse response.")
                    .foregroundStyle(.secondary)
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
                    }
                } else {
                    Text("Start the noise on the Measure page, or select a snapshot.").foregroundStyle(.secondary)
                }
            }
            .padding(24)
        }
        .task(id: source) {
            guard let r = source else { result = nil; return }
            result = await Task.detached(priority: .userInitiated) {
                let etc = r.impulse.map(RoomAnalysis.etc) ?? []
                return Result(etc: etc, reflections: r.impulse.map { RoomAnalysis.reflections($0, etc: etc) } ?? [],
                              modes: RoomAnalysis.modes(response: r, impulse: r.impulse))
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
