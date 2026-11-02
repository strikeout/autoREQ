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
                }
                Section("Speaker Output") {
                    Picker("Device", selection: $model.state.outputDeviceUID) {
                        ForEach(model.devices.filter { $0.outputChannels > 0 }) { Text("\($0.name) (\($0.outputChannels) ch)").tag(String?.some($0.uid)) }
                    }
                }
                Section("Audio Engine") {
                    Picker("Sample Rate", selection: $model.state.sampleRate) {
                        ForEach([44_100.0, 48_000, 88_200, 96_000, 176_400, 192_000], id: \.self) { Text("\(String(format: "%g", $0 / 1000)) kHz").tag($0) }
                    }
                    Text("AutoREQ sets the mic and the output device to this rate.").font(.caption).foregroundStyle(.secondary)
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
                Picker("Full Positions", selection: $model.state.options.fullPositions) { ForEach([3, 5, 7, 9], id: \.self) { Text("\($0)").tag($0) } }
            }
            Section("Alignment") {
                Picker("Gain Estimation", selection: $model.state.options.gainEstimation) { ForEach(CorrectionOptions.GainEstimation.allCases) { Text($0.rawValue).tag($0) } }
                Picker("Delay Estimation", selection: $model.state.options.delayEstimation) { ForEach(CorrectionOptions.DelayEstimation.allCases) { Text($0.rawValue).tag($0) } }
                Picker("Time-Align", selection: $model.state.options.timeAlign) { ForEach(CorrectionOptions.TimeAlign.allCases) { Text($0.rawValue).tag($0) } }
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
