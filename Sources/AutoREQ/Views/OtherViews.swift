import AutoREQCore
import Charts
import SwiftUI

struct LoopbackView: View {
    @Environment(AppModel.self) private var model
    @State private var confirmReset = false

    var body: some View {
        @Bindable var model = model
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Loopback").font(.title2.bold())
                Text("Set your Mac's sound output to the loopback device (for example BlackHole 2ch). AutoREQ captures that audio, applies the correction, and plays it on the speaker output. The app must stay open; closing the window keeps it running.")
                    .foregroundStyle(.secondary)
                GroupBox {
                    VStack(alignment: .leading, spacing: 10) {
                        Picker("Loopback input", selection: $model.state.loopbackInputUID) {
                            Text("-- Disable Loopback --").tag(String?.none)
                            ForEach(model.devices.filter { $0.inputChannels > 0 }) { Text($0.name).tag(String?.some($0.uid)) }
                        }
                        Picker("Speaker output", selection: $model.state.outputDeviceUID) {
                            ForEach(model.devices.filter { $0.outputChannels > 0 }) { Text("\($0.name) (\($0.outputChannels) ch)").tag(String?.some($0.uid)) }
                        }
                        HStack {
                            if model.loopback == nil {
                                Button { model.startLoopback() } label: { Label("Start", systemImage: "play.fill") }.buttonStyle(.borderedProminent)
                            } else {
                                Button { model.stopLoopback() } label: { Label("Stop", systemImage: "stop.fill") }
                            }
                            let st = model.correctionStatus
                            Circle().fill(st.color).frame(width: 10, height: 10)
                            Text(st.label)
                            Spacer()
                            Button(model.state.loopbackBypass ? "Enable" : "Bypass") { model.setBypass(!model.state.loopbackBypass) }
                                .disabled(model.state.appliedResult == nil)
                            Button("Reset Correction") { confirmReset = true }.disabled(model.state.appliedResult == nil)
                        }
                        Text("Bypass is level matched: it keeps the crossover and the channel gains, and removes EQ, delay and polarity.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(6)
                }
                LoopbackVolume()
                if let r = model.state.appliedResult {
                    GroupBox("Active correction") {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(r.corrections) { c in
                                Text(String(format: "%@ → Ch %d · %@ · %d EQ bands · %.1f dB · %.2f ms%@", c.speakerName, c.outputChannel + 1, c.source.rawValue,
                                            c.eq.filter(\.enabled).count, c.gainDB, c.delayMs, c.inverted ? " · inverted" : ""))
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(4)
                    }
                } else {
                    Text("No correction applied. Loopback passes stereo straight through to channels 1 and 2.").foregroundStyle(.secondary)
                }
            }
            .padding(24)
        }
        .onAppear { model.refreshDevices() }
        .alert("Reset the loopback correction?", isPresented: $confirmReset) {
            Button("Reset", role: .destructive) { model.applyResult(nil) }
            Button("Cancel", role: .cancel) {}
        }
    }
}

struct TargetCurveView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 14) {
            Text("Target Curve").font(.title2.bold())
            Text("The target is a shape only, not a loudness.").foregroundStyle(.secondary)
            Picker("Preset", selection: Binding(get: { model.state.target.name }, set: { name in
                if let p = TargetCurve.presets.first(where: { $0.name == name }) { model.state.target = p }
                else { var c = model.state.target; c.name = "Custom"; model.state.target = c }
            })) {
                ForEach(TargetCurve.presets) { Text($0.name + ($0 == .houseFlat ? " ★" : "")).tag($0.name) }
                Text("Custom").tag("Custom")
            }
            .frame(width: 320)
            Chart {
                ForEach(Array(stride(from: 0, to: FrequencyGrid.count, by: 4)).filter { (20...20_000).contains(FrequencyGrid.frequencies[$0]) }, id: \.self) { i in
                    LineMark(x: .value("Hz", FrequencyGrid.frequencies[i]), y: .value("dB", model.state.target.gain(at: FrequencyGrid.frequencies[i])))
                        .foregroundStyle(.yellow)
                }
                ForEach(model.state.target.points) { p in
                    PointMark(x: .value("Hz", p.frequency), y: .value("dB", p.gainDB)).foregroundStyle(.white)
                }
            }
            .chartXScale(domain: 20...20_000, type: .log)
            .chartYScale(domain: -12...12)
            .chartXAxis { ResponseChart.frequencyAxis }
            .frame(height: 240)
            if model.state.target.name == "Custom" {
                VStack(alignment: .leading) {
                    ForEach($model.state.target.points) { $p in
                        HStack {
                            TextField("Hz", value: $p.frequency, format: .number).frame(width: 90)
                            Text("Hz")
                            Stepper(String(format: "%+.1f dB", p.gainDB), value: $p.gainDB, in: TargetCurve.gainRange, step: 0.5)
                            Button { model.state.target.points.removeAll { $0.id == p.id } } label: { Image(systemName: "xmark") }
                                .disabled(model.state.target.points.count <= 2)
                        }
                    }
                    Button("+ Add point") { model.state.target.points.append(.init(1000, 0)) }
                }
            }
            Spacer()
        }
        .padding(24)
    }
}

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var confirmReset = false
    @State private var testing = false
    @State private var driftRuns = 5
    @State private var driftReopen = false

    var body: some View {
        @Bindable var model = model
        TabView {
            Form {
                Section("Measurement Mic") {
                    Picker("Device", selection: $model.state.micDeviceUID) {
                        ForEach(model.devices.filter { $0.inputChannels > 0 }) { Text($0.name).tag(String?.some($0.uid)) }
                    }
                    Picker("Channel", selection: $model.state.micChannel) {
                        ForEach(0..<(model.micDevice?.inputChannels ?? 1), id: \.self) { Text("Ch \($0 + 1)").tag($0) }
                    }
                    HStack { Text("Mic Level"); MicMeter(peak: model.micPeakDB, rms: model.micRMSDB).frame(height: 8) }
                    MicCalibrationRow()
                }
                Section("Extra Mics") {
                    let n = min(model.micDevice?.inputChannels ?? 1, MeasurementEngine.maxSpectrumChannels)
                    ForEach(0..<n, id: \.self) { c in
                        if c != model.state.micChannel {
                            Toggle("Ch \(c + 1)", isOn: Binding(get: { model.state.extraMicChannels.contains(c) }, set: { on in
                                model.state.extraMicChannels = (model.state.extraMicChannels.filter { $0 != c } + (on ? [c] : [])).sorted()
                                Task { await model.restartEngine() }
                            }))
                            if model.state.extraMicChannels.contains(c) { MicCalibrationRow(channel: c).padding(.leading, 20) }
                        }
                    }
                    Text("Each extra mic measures at the same time as the main mic. In the guided calibration, each mic counts as one position.")
                        .font(.caption).foregroundStyle(.secondary)
                    if model.micDevice?.isAggregate == true {
                        Text("This is an aggregate device. Its devices can have separate clocks. Turn on drift correction in Audio MIDI Setup, or use one interface for all mics.")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }
                Section("Speaker Output") {
                    Picker("Device", selection: $model.state.outputDeviceUID) {
                        ForEach(model.devices.filter { $0.outputChannels > 0 }) { Text("\($0.name) (\($0.outputChannels) ch)").tag(String?.some($0.uid)) }
                    }
                    HStack {
                        Text("Test Speakers")
                            .padding(.horizontal, 12).padding(.vertical, 4)
                            .background(testing ? Color.yellow.opacity(0.4) : Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
                            .onLongPressGesture(minimumDuration: 0.01, pressing: { down in
                                testing = down
                                if down {
                                    Task { if await model.startEngine() { model.setNoise(Set(0..<(model.engine?.outputChannelCount ?? 2)), levelDBFS: -30) } }
                                } else { model.setNoise([]) }
                            }, perform: {})
                        Text("Hold to play pink noise at −30 dBFS on all channels.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section("Audio Engine") {
                    Picker("Sample Rate", selection: $model.state.sampleRate) {
                        ForEach([44_100.0, 48_000, 88_200, 96_000, 176_400, 192_000], id: \.self) { Text("\(String(format: "%g", $0 / 1000)) kHz").tag($0) }
                    }
                    Text("AutoREQ sets the mic and the output device to this rate.").font(.caption).foregroundStyle(.secondary)
                    Picker("Buffer Size", selection: $model.state.bufferFrames) {
                        Text("Auto").tag(Int?.none)
                        ForEach([64, 128, 256, 512, 1024, 2048], id: \.self) { Text("\($0) samples").tag(Int?.some($0)) }
                    }
                    Text("A larger buffer stops clicks on a slow Mac. Auto keeps the size of the device.").font(.caption).foregroundStyle(.secondary)
                }
                Section("Diagnostics") {
                    HStack {
                        Picker("Latency Drift Check", selection: $driftRuns) { ForEach([3, 5, 10, 20], id: \.self) { Text("\($0) runs").tag($0) } }.frame(width: 260)
                        Picker("", selection: $driftReopen) { Text("Baseline").tag(false); Text("Re-open streams").tag(true) }.frame(width: 160)
                        Button("Run") { Task { await model.latencyDriftCheck(runs: driftRuns, reopen: driftReopen, channel: 0) } }
                            .disabled(model.latencyCheckRunning || !model.noiseChannels.isEmpty)
                    }
                    if let r = model.latencyReport { Text(r).font(.caption) }
                    Text("Stop the measurement first. The check plays pink noise on Ch 1 and measures the latency in each run. Baseline keeps the streams open.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("System Audio (loopback)") {
                    Picker("Loopback Input", selection: $model.state.loopbackInputUID) {
                        Text("-- Disable Loopback --").tag(String?.none)
                        ForEach(model.devices.filter { $0.inputChannels > 0 }) { Text($0.name).tag(String?.some($0.uid)) }
                    }
                }
                HStack {
                    Button("Refresh devices") { model.refreshDevices() }
                    Button("Restart audio engine") { Task { await model.restartEngine() } }
                }
            }
            .formStyle(.grouped)
            .tabItem { Text("Audio") }

            CalibrationSettings()
                .tabItem { Text("Calibration") }

            Form {
                Section("Backup") {
                    Text("A backup holds the settings, the speaker layout, the target curve and the calibration results. It does not hold snapshots.")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button("Back up…") { model.backup() }
                        Button("Restore…") { model.restore() }
                    }
                }
                Section("Reset") {
                    Button("Reset to factory defaults…", role: .destructive) { confirmReset = true }
                }
            }
            .formStyle(.grouped)
            .tabItem { Text("Backup") }
        }
        .padding()
        .onChange(of: model.state.micDeviceUID) { Task { await model.restartEngine() } }
        .onChange(of: model.state.micChannel) { Task { await model.restartEngine() } }
        .onChange(of: model.state.outputDeviceUID) { Task { await model.restartEngine() } }
        .onChange(of: model.state.sampleRate) { Task { await model.restartEngine() } }
        .onChange(of: model.state.bufferFrames) { Task { await model.restartEngine() } }
        .alert("Reset to factory defaults?", isPresented: $confirmReset) {
            Button("Reset", role: .destructive) { model.factoryReset() }
            Button("Cancel", role: .cancel) {}
        } message: { Text("This clears audio choices, calibration results and snapshots.") }
    }
}

struct CalibrationSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            if let r = model.state.appliedResult {
                Section("Applied Correction") {
                    Text("\(r.channels.count) channels · \(r.targetCurve.name) · \(r.date.formatted(date: .abbreviated, time: .shortened))")
                }
            }
            Section("Measurement") {
                Picker("Quick Positions", selection: $model.state.options.quickPositions) { ForEach([1, 3, 5, 7], id: \.self) { Text("\($0)").tag($0) } }
                Picker("Full Positions (main area)", selection: $model.state.areas[0].positions) { ForEach([3, 5, 7, 9], id: \.self) { Text("\($0)").tag($0) } }
            }
            Section("Alignment") {
                Picker("Gain Estimation", selection: $model.state.options.gainEstimation) { ForEach(CorrectionOptions.GainEstimation.allCases) { Text($0.rawValue).tag($0) } }
                Picker("Delay Estimation", selection: $model.state.options.delayEstimation) { ForEach(CorrectionOptions.DelayEstimation.allCases) { Text($0.rawValue).tag($0) } }
                Picker("Time-Align", selection: $model.state.options.timeAlign) { ForEach(CorrectionOptions.TimeAlign.allCases) { Text($0.rawValue).tag($0) } }
                Picker("Phase Correction", selection: $model.state.options.phaseCorrection) { Text("Off").tag(false); Text("On").tag(true) }
                Text("Phase Correction adds all-pass filters, so the subs and the tops stay in phase across the crossover. The calculation takes longer.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Room Correction") {
                Picker("Max Generations", selection: $model.state.options.generations) { ForEach(CorrectionOptions.Generations.allCases) { Text($0.label).tag($0) } }
                Picker("Fitness Threshold", selection: $model.state.options.threshold) { ForEach(CorrectionOptions.Threshold.allCases) { Text($0.label).tag($0) } }
                Picker("Confidence Weighting", selection: $model.state.options.confidence) { ForEach(CorrectionOptions.Confidence.allCases) { Text($0.label).tag($0) } }
                Stepper("Correction Filters: \(model.state.options.filterCount)", value: $model.state.options.filterCount, in: 1...48)
                Stepper(String(format: "Max boost per filter: %.0f dB", model.state.options.maxBoostDB), value: $model.state.options.maxBoostDB, in: 0...18)
                Picker("Boost Trust", selection: $model.state.options.boostTrust) { ForEach(CorrectionOptions.BoostTrust.allCases) { Text($0.label).tag($0) } }
                Picker("Cut Trust", selection: $model.state.options.cutTrust) { ForEach(CorrectionOptions.CutTrust.allCases) { Text($0.label).tag($0) } }
                Picker("Boost Restraint", selection: $model.state.options.boostRestraint) { ForEach(CorrectionOptions.BoostRestraint.allCases) { Text($0.label).tag($0) } }
                Text("If the result sounds over-processed, set Boost Restraint to Strong or Boost Trust to Off, then Calculate Again.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Display") {
                Picker("Smoothing", selection: $model.state.smoothing) { ForEach(Smoothing.allCases) { Text($0.label).tag($0) } }
                Picker("Coherence", selection: $model.state.coherenceHide) { ForEach(CoherenceHide.allCases) { Text($0.label).tag($0) } }
            }
        }
        .formStyle(.grouped)
    }
}

/// Master volume, correction strength and a trim per speaker for the loopback output.
struct LoopbackVolume: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        GroupBox("Volume") {
            VStack(alignment: .leading, spacing: 10) {
                row("Master", value: Binding(get: { model.state.loopbackMasterDB }, set: { model.setMasterVolume($0) }),
                    range: -60...12, step: 0.5, text: String(format: "%+.1f dB", model.state.loopbackMasterDB),
                    reset: { model.setMasterVolume(0) }, commit: {})
                row("Correction strength", value: $model.state.correctionStrength, range: 0...1, step: 0.05,
                    text: "\(Int((model.state.correctionStrength * 100).rounded())) %",
                    reset: { model.state.correctionStrength = 1; model.reapplyLoopback() }, commit: { model.reapplyLoopback() })
                Divider()
                ForEach(model.loopbackCorrections.map(\.speakerName), id: \.self) { name in
                    let trim = Binding(get: { model.state.loopbackTrims[name] ?? 0 }, set: { model.state.loopbackTrims[name] = $0 })
                    row("\(name) trim", value: trim, range: -12...12, step: 0.5, text: String(format: "%+.1f dB", trim.wrappedValue),
                        reset: { model.state.loopbackTrims[name] = nil; model.reapplyLoopback() }, commit: { model.reapplyLoopback() })
                }
                Text("Strength scales every EQ band: 0 % keeps only the crossover, level and delay. Trims and master add to the calibrated gain. A boost above 0 dB can clip.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(6)
        }
    }

    /// One slider row. `commit` runs when the drag ends, because a filter rebuild resets the filter state.
    private func row(_ label: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double, text: String,
                     reset: @escaping () -> Void, commit: @escaping () -> Void) -> some View {
        HStack {
            Text(label).frame(width: 150, alignment: .leading)
            let rounded = Binding(get: { value.wrappedValue }, set: { value.wrappedValue = ($0 / step).rounded() * step })
            Slider(value: rounded, in: range) { editing in if !editing { commit() } }
            Text(text).monospacedDigit().frame(width: 70, alignment: .trailing)
            Button("↩", action: reset).buttonStyle(.borderless)
        }
    }
}

/// Chooses the calibration of the current mic, and imports calibration files.
struct MicCalibrationRow: View {
    @Environment(AppModel.self) private var model
    /// The row sets the calibration of this mic channel. Nil selects the main mic.
    var channel: Int?

    var body: some View {
        let active = model.micCalibration(for: channel ?? model.state.micChannel)
        VStack(alignment: .leading, spacing: 6) {
            Picker("Calibration", selection: Binding(get: { active?.name }, set: { model.selectMicCalibration($0, channel: channel) })) {
                Text("None").tag(String?.none)
                let typical = model.allMicCalibrations.filter(\.isTypical)
                let files = model.allMicCalibrations.filter { !$0.isTypical }
                if !files.isEmpty {
                    Section("Imported files") { ForEach(files) { Text($0.name).tag(String?.some($0.name)) } }
                }
                if !typical.isEmpty {
                    Section("Typical curves") { ForEach(typical) { Text($0.name).tag(String?.some($0.name)) } }
                }
            }
            .disabled(model.state.micDeviceUID == nil)
            HStack {
                Button("Import calibration file…") { model.importMicCalibration(channel: channel) }
                if let a = active, !a.isTypical {
                    Button("Remove", role: .destructive) { model.removeMicCalibration(a.name) }
                }
            }
            if model.micDevice?.name.localizedCaseInsensitiveContains("iPhone") == true {
                Text("iPhone mic over Continuity: choose Mic Mode → Standard in the menu bar while AutoREQ measures. Voice Isolation removes steady noise, so it ruins a pink-noise measurement. Apple does not say if Standard turns off all processing, so check a reading against a known mic if you can.")
                    .font(.caption).foregroundStyle(.orange)
            }
            if let a = active {
                let range = a.frequencyRange.map { String(format: "%.0f Hz – %.0f Hz", $0.lowerBound, $0.upperBound) } ?? ""
                Text([range, "\(a.points.count) points", a.serial.map { "serial \($0)" }, a.sensitivityDB.map { String(format: "sens %.2f dB", $0) }]
                    .compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary)
                if a.isTypical {
                    Text("A typical curve is an average of the model, not your unit. Units can differ by several dB above 10 kHz. Use the file for your serial number if the maker gives one. Source: \(a.source)")
                        .font(.caption).foregroundStyle(.orange)
                }
            } else {
                Text("The calibration applies to new measurements from this mic. Snapshots that you took before keep their data.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
