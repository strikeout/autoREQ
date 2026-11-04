import AutoREQCore
import Charts
import SwiftUI

/// The target curve: a gallery of the presets, a large chart and the editor of the custom curve.
struct TargetCurveView: View {
    @Environment(AppModel.self) private var model
    @State private var showPresets = false
    @State private var showRoom = true
    @State private var dragID: UUID?
    /// True after the first event of a drag. The view selects the point to move at that event only.
    @State private var dragStarted = false

    private static let notes: [String: String] = [
        "House Flat": "A gentle bass lift that becomes flat at 1 kHz. This is the recommended curve.",
        "Absolute Flat": "No lift and no tilt. Use it for a reference check.",
        "N Curve": "A warm sound with more bass and a softer treble.",
        "H Curve": "A punchy sound with a forward upper midrange.",
        "D Curve": "A smooth top end with a gentle treble roll-off.",
        "Custom": "Make your own curve from points.",
    ]

    /// The regions of the chart background. The labels help a user who does not read frequencies.
    private static let regions: [(name: String, range: ClosedRange<Double>)] = [("Bass", 20...250), ("Midrange", 250...4000), ("Treble", 4000...20_000)]

    private var target: TargetCurve { model.state.target }
    private var isCustom: Bool { target.name == "Custom" }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Target Curve").font(.title2.bold())
                Text("The target is a shape only, not a loudness. The correction moves each speaker toward this shape.")
                    .foregroundStyle(.secondary)
                gallery
                chartBox
                if isCustom { editor }
            }
            .padding(24)
        }
    }

    // MARK: - Gallery

    private var gallery: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
            ForEach(TargetCurve.presets + [isCustom ? target : TargetCurve.custom]) { t in
                let selected = t.name == target.name
                Button {
                    // Keep the custom points before a preset replaces them.
                    if isCustom { model.state.customTarget = target }
                    if t.name == "Custom" && !isCustom { model.state.target = model.state.customTarget ?? .custom } else if !selected { model.state.target = t }
                } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        Sparkline(curve: t, color: selected ? .yellow : .secondary).frame(height: 44)
                        HStack(spacing: 4) {
                            Text(t.name).bold()
                            if t == .houseFlat { Image(systemName: "star.fill").font(.caption).foregroundStyle(.yellow) }
                        }
                        Text(Self.notes[t.name] ?? "").font(.caption).foregroundStyle(.secondary)
                            .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, minHeight: 130, alignment: .topLeading)
                    .background(.white.opacity(selected ? 0.09 : 0.04), in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(selected ? Color.yellow : .white.opacity(0.08), lineWidth: selected ? 2 : 1))
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Chart

    private struct CurvePoint: Identifiable {
        var id: String { "\(series)-\(frequency)" }
        var series: String
        var frequency: Double
        var gain: Double
    }

    private static let frequencies: [Double] = (0...240).map { 20 * pow(1000, Double($0) / 240) }

    /// The measured system response before the correction, 1/3-octave smoothed, with 0 dB at 1 kHz.
    private var room: [CurvePoint] {
        guard showRoom, let r = model.state.result?.systemBefore else { return [] }
        let s = Smoothing.oct3.apply(r)
        let ref = s.magnitudeDB[FrequencyGrid.index(of: 1000)]
        return Self.frequencies.map { CurvePoint(series: "Room", frequency: $0, gain: s.magnitudeDB[FrequencyGrid.index(of: $0)] - ref) }
    }

    private var chartBox: some View {
        let curve = Self.frequencies.map { CurvePoint(series: "Target", frequency: $0, gain: target.gain(at: $0)) }
        let others = showPresets ? TargetCurve.presets.filter { $0.name != target.name }.flatMap { p in
            Self.frequencies.map { CurvePoint(series: p.name, frequency: $0, gain: p.gain(at: $0)) }
        } : []
        let roomPoints = room
        return GroupBox {
            Chart {
                ForEach(Self.regions, id: \.name) { r in
                    RectangleMark(xStart: .value("Hz", r.range.lowerBound), xEnd: .value("Hz", r.range.upperBound), yStart: .value("dB", -12), yEnd: .value("dB", 12))
                        .foregroundStyle(.white.opacity(r.name == "Midrange" ? 0.025 : 0.0))
                        .annotation(position: .overlay, alignment: .top) {
                            Text(r.name).font(.caption2).foregroundStyle(.secondary).padding(.top, 4)
                        }
                }
                RuleMark(y: .value("dB", 0)).foregroundStyle(.white.opacity(0.35)).lineStyle(StrokeStyle(lineWidth: 1))
                ForEach(roomPoints) { p in
                    LineMark(x: .value("Hz", p.frequency), y: .value("dB", max(min(p.gain, 12), -12)), series: .value("Curve", "Room"))
                        .foregroundStyle(.cyan.opacity(0.6)).lineStyle(StrokeStyle(lineWidth: 1.2))
                }
                ForEach(others) { p in
                    LineMark(x: .value("Hz", p.frequency), y: .value("dB", p.gain), series: .value("Curve", p.series))
                        .foregroundStyle(.white.opacity(0.3)).lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                }
                ForEach(curve) { p in
                    AreaMark(x: .value("Hz", p.frequency), yStart: .value("dB", 0), yEnd: .value("dB", p.gain))
                        .foregroundStyle(LinearGradient(colors: [.yellow.opacity(0.35), .yellow.opacity(0.05)], startPoint: .top, endPoint: .bottom))
                    LineMark(x: .value("Hz", p.frequency), y: .value("dB", p.gain), series: .value("Curve", "Target"))
                        .foregroundStyle(.yellow).lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round))
                }
                ForEach(target.points) { p in
                    // A label at an end of the axis aligns inward, so the plot edge does not cut it.
                    let edge: HorizontalAlignment = p.frequency <= 25 ? .leading : p.frequency >= 16_000 ? .trailing : .center
                    PointMark(x: .value("Hz", p.frequency), y: .value("dB", p.gainDB))
                        .symbolSize(isCustom ? 90 : 40)
                        .foregroundStyle(p.id == dragID ? .yellow : .white)
                        .annotation(position: p.gainDB >= 0 ? .top : .bottom, alignment: Alignment(horizontal: edge, vertical: .center), spacing: 6) {
                            Text("\(Self.hz(p.frequency)) \(String(format: "%+.1f", p.gainDB))")
                                .font(.caption2.monospacedDigit()).foregroundStyle(.white.opacity(0.8))
                                .offset(x: edge == .leading ? 8 : edge == .trailing ? -8 : 0)
                        }
                }
            }
            .chartXScale(domain: 20...20_000, type: .log)
            .chartYScale(domain: -12...12)
            .chartXAxis { ResponseChart.frequencyAxis }
            .chartYAxis { AxisMarks(values: [-12, -6, 0, 6, 12]) { v in AxisGridLine(); AxisValueLabel { if let d = v.as(Double.self) { Text("\(Int(d)) dB") } } } }
            .chartPlotStyle { $0.clipped() }
            .chartOverlay { proxy in dragLayer(proxy) }
            .frame(height: 320)
            .padding(6)
        } label: {
            HStack(spacing: 16) {
                Text(target.name).bold()
                Spacer()
                Toggle("Measured room", isOn: $showRoom).disabled(model.state.result?.systemBefore == nil)
                    .help("Shows the system response before the correction, from the last calibration, with 0 dB at 1 kHz.")
                Toggle("Other presets", isOn: $showPresets)
            }
            .font(.callout)
        }
    }

    /// Lets the user drag the points of the custom curve. The nearest point within 30 pt moves.
    private func dragLayer(_ proxy: ChartProxy) -> some View {
        GeometryReader { geo in
            Rectangle().fill(.clear).contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        guard let frame = proxy.plotFrame else { return }
                        let origin = geo[frame].origin
                        let loc = CGPoint(x: v.location.x - origin.x, y: v.location.y - origin.y)
                        if !dragStarted {
                            dragStarted = true
                            dragID = target.points.min { distance($0, loc, proxy) < distance($1, loc, proxy) }
                                .flatMap { distance($0, loc, proxy) < 30 ? $0.id : nil }
                        }
                        guard let id = dragID, let i = model.state.target.points.firstIndex(where: { $0.id == id }),
                              let f: Double = proxy.value(atX: loc.x), let g: Double = proxy.value(atY: loc.y) else { return }
                        model.state.target.points[i].frequency = Self.round3(min(max(f, 20), 20_000))
                        model.state.target.points[i].gainDB = (min(max(g, -12), 12) * 2).rounded() / 2
                        model.state.customTarget = model.state.target
                    }
                    .onEnded { _ in dragID = nil; dragStarted = false }, including: isCustom ? .all : .none)
        }
    }

    private func distance(_ p: TargetCurve.Point, _ loc: CGPoint, _ proxy: ChartProxy) -> CGFloat {
        guard let x = proxy.position(forX: p.frequency), let y = proxy.position(forY: p.gainDB) else { return .infinity }
        return hypot(x - loc.x, y - loc.y)
    }

    // MARK: - Editor

    private var editor: some View {
        @Bindable var model = model
        return GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                    GridRow { Text("Frequency"); Text("Gain"); Text("") }.font(.caption.bold()).foregroundStyle(.secondary)
                    ForEach(target.points.sorted { $0.frequency < $1.frequency }) { p in
                        if let i = model.state.target.points.firstIndex(where: { $0.id == p.id }) {
                            GridRow {
                                HStack(spacing: 4) {
                                    TextField("Hz", value: Binding(get: { model.state.target.points[i].frequency },
                                                                   set: { model.state.target.points[i].frequency = min(max($0, TargetCurve.frequencyRange.lowerBound), TargetCurve.frequencyRange.upperBound) }),
                                              format: .number.precision(.significantDigits(1...4)))
                                        .frame(width: 80).multilineTextAlignment(.trailing)
                                    Text("Hz").foregroundStyle(.secondary)
                                }
                                HStack {
                                    Slider(value: $model.state.target.points[i].gainDB, in: TargetCurve.gainRange, step: 0.5).frame(width: 220)
                                    Text(String(format: "%+.1f dB", p.gainDB)).monospacedDigit().frame(width: 64, alignment: .trailing)
                                }
                                Button { model.state.target.points.removeAll { $0.id == p.id } } label: { Image(systemName: "minus.circle") }
                                    .buttonStyle(.plain).disabled(target.points.count <= 2)
                            }
                        }
                    }
                }
                HStack {
                    Button("Add Point") { model.state.target.points.append(.init(1000, 0)) }
                    Menu("Start from") {
                        ForEach(TargetCurve.presets) { p in
                            Button(p.name) { model.state.target = TargetCurve(name: "Custom", points: p.points.map { .init($0.frequency, $0.gainDB) }) }
                        }
                    }
                    .fixedSize()
                    Spacer()
                    Text("Drag a point in the chart, or type a value.").font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(6)
        } label: { Text("Custom points") }
        .onChange(of: model.state.target) { if isCustom { model.state.customTarget = model.state.target } }
    }

    // MARK: - Format

    static func hz(_ f: Double) -> String { f >= 1000 ? String(format: f >= 10_000 ? "%.0fk" : "%.3gk", f / 1000) : String(format: "%.0f", f) }

    /// Rounds to 3 significant digits, so a dragged point shows 125 Hz and not 124.37 Hz.
    static func round3(_ f: Double) -> Double {
        let e = pow(10, floor(log10(f)) - 2)
        return (f / e).rounded() * e
    }
}

/// A small preview of a target curve from 20 Hz to 20 kHz, with the 0 dB line.
struct Sparkline: View {
    let curve: TargetCurve
    let color: Color

    var body: some View {
        Canvas { ctx, size in
            let y = { (g: Double) in size.height / 2 - CGFloat(g / 8) * size.height / 2 }
            var zero = Path()
            zero.move(to: CGPoint(x: 0, y: y(0)))
            zero.addLine(to: CGPoint(x: size.width, y: y(0)))
            ctx.stroke(zero, with: .color(.white.opacity(0.15)), lineWidth: 1)
            var p = Path()
            for k in 0...60 {
                let f = 20 * pow(1000, Double(k) / 60)
                let pt = CGPoint(x: size.width * CGFloat(k) / 60, y: y(max(min(curve.gain(at: f), 8), -8)))
                if k == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
            }
            ctx.stroke(p, with: .color(color), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
        }
    }
}
