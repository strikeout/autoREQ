import AutoREQCore
import SwiftUI

struct CalibrateView: View {
    @Environment(AppModel.self) private var model
    let session: CalibrationSession

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            stages.padding()
            Divider()
            ScrollView {
                Group {
                    switch session.stage {
                    case .configure: ConfigureStage(session: session)
                    case .levels: LevelsStage(session: session)
                    case .measure: MeasureStage(session: session)
                    case .calculate: CalculateStage(session: session)
                    case .results: ResultsStage(session: session)
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var stages: some View {
        let all: [(CalibrationSession.Stage, String)] = [(.configure, "Configure"), (.levels, "Set levels"), (.measure, "Measure"), (.calculate, "Calculate"), (.results, "Results")]
        return HStack(spacing: 6) {
            ForEach(all, id: \.1) { s, name in
                Text(name)
                    .font(.callout.weight(s == session.stage ? .bold : .regular))
                    .foregroundStyle(s == session.stage ? .yellow : .secondary)
                if s != .results { Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary) }
            }
            Spacer()
            if session.stage != .configure && session.stage != .results {
                Button("Cancel") { session.cancel() }
            }
        }
    }
}

// MARK: - Configure

struct ConfigureStage: View {
    @Environment(AppModel.self) private var model
    @Bindable var session: CalibrationSession
    @State private var confirm = false

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 18) {
            Text("Configure Your Measurement").font(.title2.bold())
            HStack(spacing: 12) {
                modeCard(.quick, "About 5 minutes. Measures at the listening position.")
                modeCard(.complete, "About 20 minutes. Measures several positions around the listening area.")
                if model.state.result != nil {
                    Button { session.stage = .results } label: {
                        VStack(alignment: .leading) { Text("Previous Results").bold(); Text("Open the last result.").font(.caption).foregroundStyle(.secondary) }
                            .padding().frame(maxWidth: .infinity, minHeight: 80, alignment: .topLeading)
                            .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
                    }.buttonStyle(.plain)
                }
            }
            HStack {
                Text("Mic positions")
                Picker("", selection: session.mode == .quick ? $model.state.options.quickPositions : $model.state.options.fullPositions) {
                    ForEach(session.mode == .quick ? [1, 3, 5, 7] : [3, 5, 7, 9], id: \.self) { Text("\($0)").tag($0) }
                }.frame(width: 80)
                Text("5 positions is a good balance for Quick mode.").font(.caption).foregroundStyle(.secondary)
            }

            GroupBox("System") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Start from template")
                        ForEach(SystemTemplate.allCases) { t in Button(t.rawValue) { model.state.speakers = t.speakers } }
                    }
                    ForEach($model.state.speakers) { $sp in
                        HStack {
                            TextField("Name", text: $sp.name).frame(width: 140)
                            Picker("", selection: $sp.role) { ForEach(SpeakerRole.allCases, id: \.self) { Text($0.rawValue).tag($0) } }.frame(width: 120)
                            Picker("Plays", selection: $sp.source) { ForEach(InputSource.allCases) { Text($0.rawValue).tag($0) } }.frame(width: 120)
                            Picker("Output", selection: $sp.outputChannel) {
                                Text("None").tag(Int?.none)
                                ForEach(0..<(model.outputDevice?.outputChannels ?? 2), id: \.self) { c in
                                    Text("Ch \(c + 1)").tag(Int?.some(c))
                                }
                            }.frame(width: 140)
                            if sp.outputChannel == nil { Text("Won't be measured.").font(.caption).foregroundStyle(.orange) }
                            Spacer()
                            Button { model.state.speakers.removeAll { $0.id == sp.id } } label: { Image(systemName: "minus.circle") }.buttonStyle(.plain)
                        }
                    }
                    HStack {
                        Button("Add speaker") { model.state.speakers.append(Speaker(name: "Speaker \(model.state.speakers.count + 1)", role: .fullRange, source: .mono, outputChannel: nil)) }
                        Button("Add subwoofer") { model.state.speakers.append(Speaker(name: "Subwoofer", role: .subwoofer, source: .mono, outputChannel: nil)) }
                        Spacer()
                        Text("\(session.speakers.count) of \(model.state.speakers.count) will be measured.").foregroundStyle(.secondary)
                    }
                    if duplicateOutputs { Text("Each output can be used once.").foregroundStyle(.red) }
                }
                .padding(6)
            }
            Text("Describe each speaker. The app works out the sub and top roles, the crossover and the time alignment.")
                .font(.caption).foregroundStyle(.secondary)

            Button { confirm = true } label: { Label("Start Measurement", systemImage: "play.fill").padding(.horizontal) }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .disabled(session.speakers.isEmpty || duplicateOutputs)
        }
        .sheet(isPresented: $confirm) { ReadyDialog(session: session) }
    }

    private var duplicateOutputs: Bool {
        let chans = model.state.speakers.compactMap(\.outputChannel)
        return Set(chans).count != chans.count
    }

    private func modeCard(_ m: CalibrationSession.Mode, _ text: String) -> some View {
        Button { session.mode = m } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(m.rawValue).bold()
                Text(text).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.leading)
            }
            .padding()
            .frame(maxWidth: .infinity, minHeight: 80, alignment: .topLeading)
            .background(.white.opacity(session.mode == m ? 0.12 : 0.05), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(session.mode == m ? .yellow : .clear))
        }
        .buttonStyle(.plain)
    }
}

struct ReadyDialog: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let session: CalibrationSession
    @State private var showDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Speaker Playback About to Begin").font(.title3.bold())
            Text("Test noise plays through each speaker in turn. Turn your amp or interface down to a safe level first. Put the mic at ear height at the listening position.")
            DisclosureGroup("Devices & Target", isExpanded: $showDetails) {
                VStack(alignment: .leading) {
                    Text("Mic: \(model.micDevice?.name ?? "not set") · ch \(model.state.micChannel + 1)")
                    Text("Output: \(model.outputDevice?.name ?? "not set")")
                    Text("Target curve: \(model.state.target.name)")
                }.font(.callout).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("I'm Ready 🤘") {
                    dismiss()
                    Task { await session.beginLevels() }
                }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 440)
    }
}

// MARK: - Levels

struct LevelsStage: View {
    @Environment(AppModel.self) private var model
    @Bindable var session: CalibrationSession

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Set levels").font(.title2.bold())
            if let floor = session.noiseFloorDB {
                Text(String(format: "Room noise floor: %.0f dBFS", floor)).foregroundStyle(.secondary)
                let sp = session.speakers[safe: session.levelSpeakerIndex]
                Text("Playing: \(sp?.name ?? "–")").font(.headline)
                Text("Raise the interface or amp volume until the meter is green. Keep it out of the red.")
                HStack {
                    MicMeter(peak: model.micPeakDB, rms: model.micRMSDB).frame(width: 320, height: 14)
                    Text(String(format: "%.0f dBFS", model.micRMSDB)).monospacedDigit()
                    Image(systemName: session.levelOK ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(session.levelOK ? .green : .orange)
                }
                HStack {
                    Text("Test signal level")
                    Slider(value: $session.noiseLevelDBFS, in: -40...(-6), step: 1) { _ in session.playLevelSpeaker() }.frame(width: 200)
                    Text("\(Int(session.noiseLevelDBFS)) dBFS").monospacedDigit()
                }
                HStack {
                    Button("Previous speaker") { session.levelSpeakerIndex -= 1; session.playLevelSpeaker() }
                        .disabled(session.levelSpeakerIndex == 0)
                    Button("Next speaker") { session.levelSpeakerIndex += 1; session.playLevelSpeaker() }
                        .disabled(session.levelSpeakerIndex >= session.speakers.count - 1)
                }
                Divider()
                Text("Happy with the levels in the room?").font(.headline)
                HStack {
                    Button("Yes, continue") { session.beginMeasure() }.buttonStyle(.borderedProminent)
                    Button("No, readjust") { session.levelSpeakerIndex = 0; session.playLevelSpeaker() }
                }
            } else {
                ProgressView("Sampling the room noise floor. Keep the room quiet…")
            }
        }
    }
}

// MARK: - Measure

struct MeasureStage: View {
    @Environment(AppModel.self) private var model
    let session: CalibrationSession

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Measure — position \(session.position + 1) of \(session.positions)").font(.title2.bold())
            Text(session.measureMessage).foregroundStyle(.secondary)
            if let live = model.live, session.currentSpeaker != nil {
                ProgressView(value: model.stability) { Text("Confidence").font(.caption) }
                ResponseChart(traces: [Trace(id: "live", color: .yellow, response: live)], smoothing: .oct6, showPhase: false)
                    .frame(height: 300)
            }
            if session.waitingForMove {
                HStack(spacing: 16) {
                    Image(systemName: "infinity").font(.system(size: 40)).foregroundStyle(.yellow)
                    Text("Move the mic about 5–10 cm along a figure-eight around the listening position.")
                }
                Button("Continue") { session.continueAfterMove() }.buttonStyle(.borderedProminent)
            }
        }
    }
}

// MARK: - Calculate

struct CalculateStage: View {
    @Environment(AppModel.self) private var model
    @Bindable var session: CalibrationSession

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Calculating").font(.title2.bold())
            let speakers = session.speakers
            Text("Optimising EQ for \(speakers[safe: session.calcChannel]?.name ?? "channel \(session.calcChannel + 1)") (\(session.calcChannel + 1) of \(speakers.count))")
            if let p = session.calcProgress {
                ProgressView(value: Double(p.generation), total: Double(p.totalGenerations)) {
                    Text("Generation \(p.generation) of \(p.totalGenerations)")
                }
                Text(String(format: "Best individual: %d filters, error %.2f dB RMS", p.filters.count, p.errorDB)).foregroundStyle(.secondary)
            } else {
                ProgressView()
            }
            Button("Skip to results") { session.skipRequested = true }
        }
    }
}

// MARK: - Results

struct ResultsStage: View {
    @Environment(AppModel.self) private var model
    let session: CalibrationSession
    @State private var after = true
    @State private var channel: UUID?
    @State private var confirmApply = false
    @State private var confirmStartOver = false
    @State private var showDetail = false

    var body: some View {
        if let r = model.state.result {
            content(r)
        } else {
            Text("No results yet.").foregroundStyle(.secondary)
        }
    }

    private func content(_ r: CalibrationResult) -> some View {
        let palette = AppModel.palette
        let chosen = r.channels.filter { channel == nil || $0.id == channel }
        let traces: [Trace] = chosen.enumerated().map { n, c in
            let idx = r.channels.firstIndex { $0.id == c.id } ?? n
            return Trace(id: c.correction.speakerName, color: Color(hex: palette[(idx + 1) % palette.count]), response: after ? c.after : c.before)
        } + (channel != nil && after ? chosen.map { c in
            Trace(id: "\(c.correction.speakerName) filters", color: .white.opacity(0.6),
                  response: Response.flat(sampleRate: r.sampleRate).applying(c.correction.eq.map { $0.coefficients(sampleRate: r.sampleRate) }, gainDB: c.target[FrequencyGrid.index(of: 1000)]),
                  dashed: true, lineWidth: 1)
        } : [])
        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Calibration results").font(.title2.bold())
                Spacer()
                Picker("", selection: $after) { Text("Before").tag(false); Text("After").tag(true) }.pickerStyle(.segmented).frame(width: 180)
            }
            HStack {
                chip(nil, "All channels", .white)
                ForEach(Array(r.channels.enumerated()), id: \.1.id) { n, c in
                    chip(c.id, c.correction.speakerName, Color(hex: palette[(n + 1) % palette.count]))
                }
            }
            ResponseChart(traces: traces, target: chosen.first?.target, smoothing: model.state.smoothing, coherenceHide: model.state.coherenceHide.rawValue,
                          showPhase: showDetail, highlight: chosen.count == 1 ? chosen[0].correctedRange : nil)
                .frame(minHeight: showDetail ? 460 : 320)
            diagnostics(chosen)
            DisclosureGroup("More detail", isExpanded: $showDetail) { detail(r, chosen) }
            HStack {
                Button("Apply to loopback") { confirmApply = true }.buttonStyle(.borderedProminent)
                Button("Calculate Again") { session.calculate() }.disabled(session.measurements.isEmpty)
                Button("Export results") { model.exportResults(r) }
                Button("Open results…") { model.openResults() }
                Spacer()
                Button("Start over") { confirmStartOver = true }
            }
        }
        .alert("Apply calibration results?", isPresented: $confirmApply) {
            Button("Apply") { model.applyResult(r) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(r.channels.map { "\($0.correction.speakerName) → Ch \($0.correction.outputChannel + 1)" }.joined(separator: "\n") + "\n\nThis replaces the current correction.")
        }
        .alert("Start over?", isPresented: $confirmStartOver) {
            Button("Start over", role: .destructive) { session.stage = .configure }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func chip(_ id: UUID?, _ name: String, _ color: Color) -> some View {
        Button { channel = id } label: {
            HStack(spacing: 6) { Circle().fill(color).frame(width: 8, height: 8); Text(name) }
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(channel == id ? .white.opacity(0.15) : .white.opacity(0.05), in: Capsule())
        }.buttonStyle(.plain)
    }

    private func diagnostics(_ chans: [ChannelResult]) -> some View {
        let issues = chans.flatMap { c -> [String] in
            var out: [String] = []
            let lo = FrequencyGrid.index(of: c.correctedRange.lowerBound), hi = FrequencyGrid.index(of: min(c.correctedRange.upperBound, 10_000))
            let coh = c.before.coherence[lo...hi].reduce(0, +) / Double(max(hi - lo + 1, 1))
            if coh < 0.6 { out.append("\(c.correction.speakerName): low confidence (\(Int(coh * 100))%). Raise the test level or reduce room noise, then measure again.") }
            if c.errorDB > 3 { out.append(String(format: "%@: %.1f dB RMS from the target after correction. Deep dips are usually cancellations; try another speaker or seat position.", c.correction.speakerName, c.errorDB)) }
            return out
        }
        return GroupBox("Diagnostics") {
            VStack(alignment: .leading, spacing: 4) {
                if issues.isEmpty { Text("No issues flagged — this measurement looks clean.").foregroundStyle(.green) }
                ForEach(issues, id: \.self) { Text("• " + $0) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        }
    }

    private func detail(_ r: CalibrationResult, _ chans: [ChannelResult]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(chans) { c in
                GroupBox(c.correction.speakerName) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(String(format: "Gain %.1f dB · Delay %.2f ms · Polarity %@%@", c.correction.gainDB, c.correction.delayMs,
                                    c.correction.inverted ? "inverted" : "normal",
                                    c.correction.crossover.map { String(format: " · %@ %.0f Hz LR4", $0.highPass ? "High-pass" : "Low-pass", $0.frequency) } ?? ""))
                        ForEach(Array(c.correction.eq.enumerated()), id: \.1.id) { n, b in
                            Text(String(format: "%2d  %@  %7.1f Hz  %+5.1f dB  Q %.2f", n + 1, b.type.rawValue, b.frequency, b.gainDB, b.q))
                                .font(.caption.monospaced())
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            GroupBox("Setup assumptions") {
                VStack(alignment: .leading) { ForEach(r.assumptions, id: \.self) { Text($0).font(.caption) } }
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
