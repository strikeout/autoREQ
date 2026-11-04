import AutoREQCore
import Charts
import SwiftUI

/// The RTA and the spectrograph of the mic device inputs.
struct SpectrumView: View {
    @Environment(AppModel.self) private var model

    static let channelColors: [Color] = [.yellow, .cyan, .pink, .green, .purple, .orange, .mint, .indigo]
    static let spans: [(label: String, seconds: Double)] = [("10 s", 10), ("30 s", 30), ("1 min", 60), ("5 min", 300)]

    private func bind<T>(_ path: WritableKeyPath<SpectrumSettings, T>) -> Binding<T> {
        Binding(get: { model.state.spectrum[keyPath: path] }, set: { model.state.spectrum[keyPath: path] = $0; model.spectrumSettingsChanged() })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            GeneratorControls().padding(.horizontal)
            toolbar.padding(.horizontal)
            GroupBox("RTA") { rta.frame(minHeight: 220).padding(6) }.padding(.horizontal)
            GroupBox { spectrograph.frame(minHeight: 200).padding(6) } label: { spectrographHeader }.padding(.horizontal)
        }
        .padding(.vertical)
        .task { await model.startSpectrum() }
        .onDisappear { model.stopSpectrum(); model.setNoise([]) }
    }

    // MARK: - Toolbar

    private var inputCount: Int { min(model.micDevice?.inputChannels ?? 1, MeasurementEngine.maxSpectrumChannels) }

    private var toolbar: some View {
        let s = model.state.spectrum
        return HStack(spacing: 10) {
            Menu("Inputs: " + s.channels.map { "Ch \($0 + 1)" }.joined(separator: ", ")) {
                ForEach(0..<inputCount, id: \.self) { c in
                    Toggle("Ch \(c + 1)" + (c == model.state.micChannel ? " (measurement mic)" : ""), isOn: Binding(
                        get: { s.channels.contains(c) },
                        set: { on in
                            var list = s.channels.filter { $0 != c }
                            if on { list.append(c) }
                            if !list.isEmpty { model.state.spectrum.channels = list.sorted(); model.spectrumSettingsChanged() }
                        }))
                }
            }
            .fixedSize()
            Picker("Bands", selection: bind(\.banding)) { ForEach(Banding.allCases) { Text($0.label).tag($0) } }.frame(width: 160)
            Picker("Average", selection: bind(\.averaging)) { ForEach(Averaging.allCases) { Text($0.rawValue).tag($0) } }.frame(width: 160)
            Toggle("Peak hold", isOn: bind(\.peakHold))
            Button("Reset") { model.resetSpectrum() }
            Spacer()
            MicMeter(peak: model.micPeakDB, rms: model.micRMSDB).frame(width: 80, height: 6)
        }
    }

    // MARK: - RTA

    private struct BandPoint: Identifiable {
        var id: String { "\(series)-\(index)" }
        var series: String
        var index: Int
        var band: Band
        var level: Double
    }

    private var rta: some View {
        let bands = model.spectrumBands, s = model.state.spectrum
        let floor = -120.0
        let bars = s.channels.count == 1 && s.banding.rawValue <= 6
        var points: [BandPoint] = [], peaks: [BandPoint] = []
        for c in s.channels {
            if let lv = model.spectrum[c], lv.count == bands.count {
                points += bands.indices.map { BandPoint(series: "Ch \(c + 1)", index: $0, band: bands[$0], level: max(lv[$0], floor)) }
            }
            if s.peakHold, let pk = model.spectrumPeak[c], pk.count == bands.count {
                peaks += bands.indices.map { BandPoint(series: "Ch \(c + 1) peak", index: $0, band: bands[$0], level: max(pk[$0], floor)) }
            }
        }
        let colors = Dictionary(uniqueKeysWithValues: s.channels.enumerated().flatMap { i, c in
            let col = Self.channelColors[i % Self.channelColors.count]
            return [("Ch \(c + 1)", col), ("Ch \(c + 1) peak", col.opacity(0.6))]
        })
        return Chart {
            ForEach(points) { p in
                if bars {
                    RectangleMark(xStart: .value("Hz", p.band.lower * 1.02), xEnd: .value("Hz", p.band.upper / 1.02),
                                  yStart: .value("dB", floor), yEnd: .value("dB", p.level))
                        .foregroundStyle(colors[p.series] ?? .yellow)
                } else {
                    LineMark(x: .value("Hz", p.band.centre), y: .value("dB", p.level), series: .value("Input", p.series))
                        .foregroundStyle(colors[p.series] ?? .yellow)
                        .interpolationMethod(.stepCenter)
                }
            }
            ForEach(peaks) { p in
                LineMark(x: .value("Hz", p.band.centre), y: .value("dB", p.level), series: .value("Input", p.series))
                    .foregroundStyle(colors[p.series] ?? .white)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .interpolationMethod(.stepCenter)
            }
        }
        .chartXScale(domain: 18...22_000, type: .log)
        .chartYScale(domain: floor...0)
        .chartXAxis {
            // The 20 kHz label does not fit at the right edge of the plot.
            AxisMarks(values: [20, 50, 100, 200, 500, 1000, 2000, 5000, 10_000]) { v in
                AxisGridLine()
                AxisValueLabel { if let d = v.as(Double.self) { Text(d >= 1000 ? "\(Int(d / 1000))k" : "\(Int(d))") } }
            }
        }
        .chartYAxisLabel("dBFS")
        .chartPlotStyle { $0.clipped() }
        .overlay(alignment: .topTrailing) {
            if s.channels.count > 1 {
                HStack(spacing: 10) {
                    ForEach(Array(s.channels.enumerated()), id: \.element) { i, c in
                        Label("Ch \(c + 1)", systemImage: "circle.fill").font(.caption)
                            .foregroundStyle(Self.channelColors[i % Self.channelColors.count])
                    }
                }
                .padding(6)
            }
        }
    }

    // MARK: - Spectrograph

    private var spectrographHeader: some View {
        let s = model.state.spectrum
        return HStack {
            Text("Spectrograph — Ch \((s.channels.first ?? 0) + 1)")
            Spacer()
            Picker("Time", selection: bind(\.spectrogramSeconds)) {
                ForEach(Self.spans, id: \.seconds) { Text($0.label).tag($0.seconds) }
            }
            .pickerStyle(.segmented)
            .frame(width: 240)
            Stepper("Floor \(Int(s.floorDB)) dB", value: bind(\.floorDB), in: -150...(s.ceilingDB - 10), step: 5).fixedSize()
            Stepper("Top \(Int(s.ceilingDB)) dB", value: bind(\.ceilingDB), in: (s.floorDB + 10)...0, step: 5).fixedSize()
        }
        .font(.callout)
    }

    private var spectrograph: some View {
        let s = model.state.spectrum
        let frames = Array(model.spectrogram.suffix(Int(s.spectrogramSeconds * 10)))
        return GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                Rectangle().fill(.black)
                if let img = Spectrograph.image(frames, rows: Int(s.spectrogramSeconds * 10), floor: s.floorDB, ceiling: s.ceilingDB) {
                    Image(decorative: img, scale: 1).resizable().interpolation(.medium)
                }
                ForEach([31.5, 63, 125, 250, 500, 1000, 2000, 4000, 8000, 16_000], id: \.self) { f in
                    let x = Spectrograph.position(of: f) * geo.size.width
                    Rectangle().fill(.white.opacity(0.15)).frame(width: 1, height: geo.size.height).offset(x: x)
                    Text(f >= 1000 ? "\(Int(f / 1000))k" : f == 31.5 ? "31.5" : "\(Int(f))")
                        .font(.caption2).foregroundStyle(.white.opacity(0.7)).offset(x: x + 3, y: 2)
                }
                VStack {
                    Text("now")
                    Spacer()
                    Text("−" + (Self.spans.first { $0.seconds == s.spectrogramSeconds }?.label ?? ""))
                }
                .font(.caption2).foregroundStyle(.white.opacity(0.7))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                .padding(.top, 18).padding(.bottom, 4).padding(.trailing, 4)
            }
        }
    }
}

/// Draws the spectrograph frames as a color map. The newest frame is the top row.
enum Spectrograph {
    private static let bands = AppModel.spectrogramBands

    /// The horizontal position of `f` from 0 to 1. The 1/24-octave bands have equal widths on a log axis.
    static func position(of f: Double) -> Double {
        guard let lo = bands.first?.lower, let hi = bands.last?.upper else { return 0 }
        return log(f / lo) / log(hi / lo)
    }

    static func image(_ frames: [[Float]], rows: Int, floor: Double, ceiling: Double) -> CGImage? {
        let w = bands.count, h = max(rows, 1)
        guard w > 0 else { return nil }
        var px = [UInt32](repeating: 0xFF00_0000, count: w * h)
        let range = Float(ceiling - floor)
        for (age, f) in frames.reversed().enumerated() where age < h && f.count == w {
            for x in 0..<w { px[age * w + x] = color(max(0, min(1, (f[x] - Float(floor)) / range))) }
        }
        return px.withUnsafeMutableBytes { buf in
            CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage()
        }
    }

    /// A dark-to-bright map: black, purple, red, orange, yellow and white.
    private static let stops: [(r: Float, g: Float, b: Float)] = [(0, 0, 0), (0.3, 0.05, 0.45), (0.8, 0.1, 0.3), (1, 0.5, 0), (1, 0.9, 0.1), (1, 1, 1)]

    private static func color(_ v: Float) -> UInt32 {
        let p = v * Float(stops.count - 1), i = min(Int(p), stops.count - 2), t = p - Float(i)
        let a = stops[i], b = stops[i + 1]
        let r = UInt32((a.r + (b.r - a.r) * t) * 255), g = UInt32((a.g + (b.g - a.g) * t) * 255), bl = UInt32((a.b + (b.b - a.b) * t) * 255)
        // RGBA in memory order on a little-endian CPU.
        return 0xFF00_0000 | (bl << 16) | (g << 8) | r
    }
}
