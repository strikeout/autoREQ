import AutoREQCore
import Charts
import SwiftUI

/// One trace on a response chart.
struct Trace: Identifiable {
    var id: String
    var color: Color
    var response: Response
    var dashed = false
    var lineWidth = 1.5
}

private struct Point: Identifiable {
    let id: Int
    let series: String
    let f: Double
    let v: Double
}

/// Magnitude, coherence and phase charts on a log-frequency axis.
struct ResponseChart: View {
    var traces: [Trace]
    var target: [Double]? = nil
    var smoothing: Smoothing = .oct6
    var coherenceHide = 0.0
    var scale = GraphScale()
    var showPhase = true
    var showCoherence = true
    var highlight: ClosedRange<Double>? = nil
    @State private var hoverF: Double?

    private let step = 2 // Plot every 2nd grid point: 1/24 octave is enough on screen.

    private var xDomain: ClosedRange<Double> {
        scale.kind == .custom ? max(10, scale.fromHz)...min(24_000, max(scale.toHz, scale.fromHz + 10)) : 20...20_000
    }

    private func displayed(_ t: Trace) -> Response {
        var r = smoothing.apply(t.response)
        if scale.kind == .norm24 {
            let lo = FrequencyGrid.index(of: 200), hi = FrequencyGrid.index(of: 2000)
            let m = r.magnitudeDB[lo...hi].reduce(0, +) / Double(hi - lo + 1)
            r.magnitudeDB = r.magnitudeDB.map { $0 - m }
        }
        return r
    }

    /// Splits a trace into segments where the coherence is above the hide level, so hidden parts leave gaps.
    private func points(_ t: Trace, _ r: Response, phase: Bool) -> [Point] {
        var out: [Point] = []
        var seg = 0
        var gap = false
        var lastPhase: Double?
        for i in stride(from: 0, to: FrequencyGrid.count, by: step) {
            let f = FrequencyGrid.frequencies[i]
            guard xDomain.contains(f) else { continue }
            if r.coherence[i] < coherenceHide || (phase && r.coherence[i] < 0.3) { gap = true; continue }
            let v = phase ? r.phaseDeg[i] : r.magnitudeDB[i]
            // Start a new segment at a gap or at a phase wrap, so the chart draws no vertical line.
            if gap || (phase && lastPhase.map { abs($0 - v) > 180 } == true) { seg += 1; gap = false }
            lastPhase = v
            out.append(Point(id: out.count, series: "\(t.id)#\(seg)", f: f, v: v))
        }
        return out
    }

    private var yDomain: ClosedRange<Double>? {
        switch scale.kind {
        case .full: return nil
        case .norm24: return -24...24
        case .custom:
            let all = traces.flatMap { displayed($0).magnitudeDB }
            let mid = all.isEmpty ? 0 : all.sorted()[all.count / 2]
            return (mid - scale.customDB)...(mid + scale.customDB)
        }
    }

    var body: some View {
        let shown = traces.map { ($0, displayed($0)) }
        VStack(spacing: 4) {
            magnitude(shown)
                .frame(minHeight: 220)
            if showCoherence, let first = shown.first {
                coherence(first.1, color: first.0.color).frame(height: 50)
            }
            if showPhase {
                phaseChart(shown).frame(minHeight: 120, maxHeight: 180)
            }
        }
    }

    private func readout(_ shown: [(Trace, Response)]) -> some View {
        Group {
            if let f = hoverF, let (_, r) = shown.first {
                let i = FrequencyGrid.index(of: f)
                Text(String(format: "%.0f Hz   %.1f dB   %.0f°   %.0f%%", FrequencyGrid.frequencies[i], r.magnitudeDB[i], r.phaseDeg[i], r.coherence[i] * 100))
                    .font(.caption.monospacedDigit())
                    .padding(4)
                    .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 4))
            }
        }
    }

    private func magnitude(_ shown: [(Trace, Response)]) -> some View {
        Chart {
            if let h = highlight {
                RectangleMark(xStart: .value("f", h.lowerBound), xEnd: .value("f", h.upperBound))
                    .foregroundStyle(.yellow.opacity(0.08))
            }
            if let target {
                let pts = stride(from: 0, to: FrequencyGrid.count, by: step).filter { xDomain.contains(FrequencyGrid.frequencies[$0]) }
                ForEach(pts, id: \.self) { i in
                    LineMark(x: .value("Hz", FrequencyGrid.frequencies[i]), y: .value("dB", target[i]), series: .value("s", "target"))
                        .foregroundStyle(.yellow.opacity(0.5))
                        .lineStyle(StrokeStyle(lineWidth: 2, dash: [6, 4]))
                }
            }
            ForEach(shown, id: \.0.id) { t, r in
                ForEach(points(t, r, phase: false)) { p in
                    LineMark(x: .value("Hz", p.f), y: .value("dB", p.v), series: .value("s", p.series))
                        .foregroundStyle(t.color)
                        .lineStyle(StrokeStyle(lineWidth: t.lineWidth, dash: t.dashed ? [4, 3] : []))
                }
            }
            if let f = hoverF { RuleMark(x: .value("Hz", f)).foregroundStyle(.white.opacity(0.3)) }
        }
        .chartXScale(domain: xDomain, type: .log)
        .modifier(OptionalYDomain(domain: yDomain))
        .chartXAxis { frequencyAxis }
        .chartYAxisLabel("dB")
        .chartOverlay { proxy in hover(proxy) }
        .overlay(alignment: .topTrailing) { readout(shown) }
    }

    private func coherence(_ r: Response, color: Color) -> some View {
        Chart {
            ForEach(Array(stride(from: 0, to: FrequencyGrid.count, by: step)).filter { xDomain.contains(FrequencyGrid.frequencies[$0]) }, id: \.self) { i in
                AreaMark(x: .value("Hz", FrequencyGrid.frequencies[i]), y: .value("%", r.coherence[i] * 100))
                    .foregroundStyle(LinearGradient(colors: [.red, .yellow, .green], startPoint: .bottom, endPoint: .top).opacity(0.6))
            }
        }
        .chartXScale(domain: xDomain, type: .log)
        .chartYScale(domain: 0...100)
        .chartXAxis(.hidden)
        .chartYAxis { AxisMarks(values: [0, 100]) { _ in AxisValueLabel() } }
        .chartYAxisLabel("Coh %")
    }

    private func phaseChart(_ shown: [(Trace, Response)]) -> some View {
        Chart {
            ForEach(shown, id: \.0.id) { t, r in
                ForEach(points(t, r, phase: true)) { p in
                    LineMark(x: .value("Hz", p.f), y: .value("°", p.v), series: .value("s", p.series))
                        .foregroundStyle(t.color)
                        .lineStyle(StrokeStyle(lineWidth: 1))
                }
            }
            if let f = hoverF { RuleMark(x: .value("Hz", f)).foregroundStyle(.white.opacity(0.3)) }
        }
        .chartXScale(domain: xDomain, type: .log)
        .chartYScale(domain: -180...180)
        .chartYAxis { AxisMarks(values: [-180, -90, 0, 90, 180]) }
        .chartXAxis { frequencyAxis }
        .chartYAxisLabel("Phase °")
        .chartOverlay { proxy in hover(proxy) }
    }

    private var frequencyAxis: some AxisContent {
        AxisMarks(values: [20, 50, 100, 200, 500, 1000, 2000, 5000, 10_000, 20_000]) { v in
            AxisGridLine()
            AxisValueLabel {
                if let d = v.as(Double.self) { Text(d >= 1000 ? "\(Int(d / 1000))k" : "\(Int(d))") }
            }
        }
    }

    private func hover(_ proxy: ChartProxy) -> some View {
        GeometryReader { geo in
            Rectangle().fill(.clear).contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let p):
                        guard let plot = proxy.plotFrame else { return }
                        let x = p.x - geo[plot].origin.x
                        hoverF = proxy.value(atX: x, as: Double.self)
                    case .ended: hoverF = nil
                    }
                }
        }
    }
}

private struct OptionalYDomain: ViewModifier {
    var domain: ClosedRange<Double>?
    func body(content: Content) -> some View {
        if let domain { content.chartYScale(domain: domain) } else { content }
    }
}
