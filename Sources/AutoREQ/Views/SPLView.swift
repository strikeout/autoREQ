import AutoREQCore
import Charts
import SwiftUI

/// The SPL meters, the calibration, the band levels and the log.
struct SPLView: View {
    @Environment(AppModel.self) private var model
    @State private var calibrating: Int?

    private var inputCount: Int { min(model.micDevice?.inputChannels ?? 1, MeasurementEngine.maxSpectrumChannels) }

    var body: some View {
        @Bindable var model = model
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("SPL").font(.title2.bold())
                Text("This is not a certified sound level meter. The levels are correct only after a calibration with an acoustic calibrator.")
                    .foregroundStyle(.secondary)
                calibrationBox
                meterGrid
                bandChart
                logBox
            }
            .padding(24)
        }
        .task { await model.startSPL() }
        .onDisappear { model.stopSPL() }
    }

    // MARK: - Calibration

    private var calibrationBox: some View {
        @Bindable var model = model
        return GroupBox("Channels and calibration") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Calibrator level")
                    Picker("", selection: $model.state.spl.calibratorDB) {
                        Text("94 dB").tag(94.0)
                        Text("114 dB").tag(114.0)
                    }
                    .pickerStyle(.segmented).frame(width: 160)
                    Spacer()
                    Button("Reset Leq, maxima and doses") { model.engine?.resetSoundLevel() }
                }
                ForEach(0..<inputCount, id: \.self) { c in
                    HStack(spacing: 12) {
                        Toggle("Ch \(c + 1)", isOn: Binding(get: { model.state.spl.channels.contains(c) }, set: { on in
                            var list = model.state.spl.channels.filter { $0 != c }
                            if on { list.append(c) }
                            if !list.isEmpty { model.state.spl.channels = list.sorted(); model.splSettingsChanged() }
                        }))
                        .frame(width: 80, alignment: .leading)
                        if let off = model.splCalibration(c) {
                            Text(String(format: "Offset %+.1f dB", off)).monospacedDigit()
                        } else {
                            Text("Not calibrated").foregroundStyle(.orange)
                        }
                        if calibrating == c {
                            ProgressView().controlSize(.small)
                            Text("Reading the calibrator…").foregroundStyle(.secondary)
                        } else {
                            Button("Calibrate") {
                                calibrating = c
                                Task { await model.calibrateSPL(channel: c); calibrating = nil }
                            }
                            .disabled(!model.state.spl.channels.contains(c) || calibrating != nil)
                        }
                        Spacer()
                    }
                }
                Text("Put the calibrator on the mic, turn it on, then click Calibrate. The app reads the tone for 3 s. The calibration does not include the frequency response of the mic.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(6)
        }
    }

    // MARK: - Meters

    private var meterGrid: some View {
        GroupBox {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 12)], spacing: 12) {
                ForEach(model.state.spl.meters) { m in tile(m) }
            }
            .padding(6)
        } label: {
            HStack {
                Text("Meters")
                Spacer()
                Menu("Add Meter") {
                    ForEach(model.state.spl.channels, id: \.self) { c in
                        Menu("Ch \(c + 1)") {
                            ForEach(MeterSpec.Metric.allCases) { metric in
                                Button(metric.rawValue) { model.state.spl.meters.append(MeterSpec(channel: c, metric: metric)) }
                            }
                        }
                    }
                }
                .fixedSize()
            }
        }
    }

    private func tile(_ m: MeterSpec) -> some View {
        let v = model.soundLevels[m.channel].flatMap { m.metric.value($0) }
        let text: String = {
            guard let v, v > -150 else { return "–" }
            return m.metric.isDose ? String(format: "%.1f %%", v) : String(format: "%.1f", v)
        }()
        return VStack(alignment: .leading, spacing: 4) {
            Text(m.metric.rawValue + (model.state.spl.channels.count > 1 ? " · Ch \(m.channel + 1)" : "")).font(.caption).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(text).font(.system(size: 34, weight: .semibold, design: .rounded)).monospacedDigit()
                if !m.metric.isDose { Text("dB").foregroundStyle(.secondary) }
            }
            if model.splCalibration(m.channel) == nil { Text("Not calibrated").font(.caption2).foregroundStyle(.orange) }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
        .contextMenu {
            Button("Remove", role: .destructive) { model.state.spl.meters.removeAll { $0.id == m.id } }
        }
    }

    // MARK: - Bands

    private var bandChart: some View {
        @Bindable var model = model
        let bands = model.spectrumBands
        let c = model.state.spl.channels.first ?? 0
        let off = model.splCalibration(c) ?? 0
        let lv = model.spectrum[c].map { $0.map { $0 + off } } ?? []
        return GroupBox {
            Chart {
                ForEach(Array(zip(bands, lv).enumerated()), id: \.offset) { _, p in
                    RectangleMark(xStart: .value("Hz", p.0.lower * 1.02), xEnd: .value("Hz", p.0.upper / 1.02),
                                  yStart: .value("dB", 0), yEnd: .value("dB", max(p.1, 0)))
                        .foregroundStyle(.yellow)
                }
            }
            .chartXScale(domain: 18...22_000, type: .log)
            .chartYScale(domain: 0...120)
            .chartXAxis {
                AxisMarks(values: [31.5, 63, 125, 250, 500, 1000, 2000, 4000, 8000, 16_000]) { v in
                    AxisGridLine()
                    AxisValueLabel { if let d = v.as(Double.self) { Text(d >= 1000 ? "\(Int(d / 1000))k" : d == 31.5 ? "31.5" : "\(Int(d))") } }
                }
            }
            .chartYAxisLabel("dB SPL (Z)")
            .chartPlotStyle { $0.clipped() }
            .frame(height: 200)
            .padding(6)
        } label: {
            HStack {
                Text("Band levels — Ch \(c + 1)")
                Picker("", selection: Binding(get: { model.state.spl.bandsThird }, set: { model.state.spl.bandsThird = $0; model.splSettingsChanged() })) {
                    Text("Octaves").tag(false)
                    Text("1/3 octaves").tag(true)
                }
                .pickerStyle(.segmented).frame(width: 220)
            }
        }
    }

    // MARK: - Log

    private var logBox: some View {
        GroupBox("Log") {
            HStack {
                if let url = model.splLogURL {
                    Image(systemName: "record.circle").foregroundStyle(.red)
                    Text("Writes to \(url.lastPathComponent) each second.").lineLimit(1)
                    Spacer()
                    Button("Stop Log") { model.stopSPLLog() }
                } else {
                    Text("The log writes one CSV line each second for each channel. It continues when you close the window.")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Start Log…") { model.startSPLLog() }
                }
            }
            .padding(6)
        }
    }
}
