import AutoREQCore
import SwiftUI

struct MeasureView: View {
    @Environment(AppModel.self) private var model
    @Binding var section: AppSection?
    let session: CalibrationSession
    @State private var showSettings = false
    @State private var editing: Snapshot?

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 10) {
            GeneratorControls().padding(.horizontal)
            toolbar
            ResponseChart(traces: traces, smoothing: model.state.smoothing, coherenceHide: model.state.coherenceHide.rawValue, scale: model.state.graphScale)
                .padding(.horizontal)
            snapshotList
        }
        .padding(.vertical)
        .sheet(item: $editing) { s in SnapshotEditor(snapshot: s) }
        .onDisappear { model.setNoise([]) }
    }

    private var traces: [Trace] {
        var t: [Trace] = []
        if let live = model.live, model.engine != nil { t.append(Trace(id: "Realtime", color: .white, response: live, lineWidth: 2)) }
        for s in model.state.snapshots where s.visible {
            t.append(Trace(id: s.id.uuidString, color: s.color, response: s.displayed, lineWidth: model.selectedSnapshotIDs.contains(s.id) ? 2.5 : 1.5))
        }
        return t
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Button { Task { await model.autoCapture() } } label: { Label("Auto Capture", systemImage: "wand.and.rays") }
                .disabled(model.autoCapturing || model.state.generator.signal.kind.isTonal)
            Button { model.takeSnapshot() } label: { Label("Take Snapshot", systemImage: "camera") }
                .disabled(model.live == nil || model.noiseChannels.isEmpty)
            Spacer()
            statusPill
            Button { showSettings.toggle() } label: { Image(systemName: "gearshape") }
                .popover(isPresented: $showSettings) { MeasurementSettings().padding().frame(width: 320) }
        }
        .padding(.horizontal)
    }

    private var statusPill: some View {
        let (text, color): (String, Color) = {
            if model.autoCapturing { return ("Waiting for a stable measurement \(Int(model.stability * 100))%", .yellow) }
            if model.engine == nil { return ("Engine off", .gray) }
            switch model.status {
            case .measuring: return ("OK — Measuring — playing \(model.playingSignal?.label ?? "noise")", .green)
            case .tone: return (model.status.label, .orange)
            case .noDelay: return (model.status.label, .red)
            default: return (model.status.label, .gray)
            }
        }()
        return HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(text).font(.caption)
            MicMeter(peak: model.micPeakDB, rms: model.micRMSDB).frame(width: 80, height: 6)
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(.white.opacity(0.06), in: Capsule())
    }

    private var snapshotList: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Snapshots").font(.headline)
                Spacer()
                let sel = model.state.snapshots.filter { model.selectedSnapshotIDs.contains($0.id) }
                Button("Combine") { model.combineSelected() }.disabled(sel.count < 2)
                Menu("Create Calibration") {
                    Button("Full correction") { createCalibration(alignOnly: false) }
                    Button("Align only") { createCalibration(alignOnly: true) }
                }
                .fixedSize()
                .disabled(sel.allSatisfy { $0.speakerID == nil })
                Button("Export CSV") { model.exportSnapshots(sel) }.disabled(sel.isEmpty)
                Button("Export All") { model.exportSnapshots(model.state.snapshots) }.disabled(model.state.snapshots.isEmpty)
                Button("Load") { model.importSnapshots() }
            }
            List {
                ForEach(model.state.snapshots) { s in
                    SnapshotRow(snapshot: s, selected: model.selectedSnapshotIDs.contains(s.id), onEdit: { editing = s })
                }
            }
            .frame(minHeight: 120)
        }
        .padding(.horizontal)
    }

    /// Builds a calibration from the selected snapshots. Each selected snapshot needs a speaker.
    private func createCalibration(alignOnly: Bool) {
        let sel = model.state.snapshots.filter { model.selectedSnapshotIDs.contains($0.id) }
        var byID: [UUID: [Response]] = [:]
        for s in sel { if let id = s.speakerID { byID[id, default: []].append(s.displayed) } }
        let averaged = byID.compactMapValues { Response.powerAverage($0) }
        session.alignOnly = alignOnly
        session.calculate(with: averaged)
        section = .calibrate
    }
}

struct SnapshotRow: View {
    @Environment(AppModel.self) private var model
    let snapshot: Snapshot
    let selected: Bool
    let onEdit: () -> Void

    private var index: Int? { model.state.snapshots.firstIndex { $0.id == snapshot.id } }

    var body: some View {
        HStack(spacing: 10) {
            Button { if let i = index { model.state.snapshots[i].visible.toggle() } } label: {
                Circle().fill(snapshot.visible ? snapshot.color : .clear).overlay(Circle().stroke(snapshot.color)).frame(width: 12, height: 12)
            }.buttonStyle(.plain)
            Text(snapshot.name).fontWeight(selected ? .bold : .regular)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture {
                    if selected { model.selectedSnapshotIDs.remove(snapshot.id) } else { model.selectedSnapshotIDs.insert(snapshot.id) }
                }
            if selected, let i = index { offsets(i) }
            Picker("", selection: Binding(get: { snapshot.speakerID }, set: { v in if let i = index { model.state.snapshots[i].speakerID = v } })) {
                Text("No speaker").tag(UUID?.none)
                ForEach(model.state.speakers) { sp in Text(sp.name).tag(UUID?.some(sp.id)) }
            }.frame(width: 130)
            Button("Edit", action: onEdit)
            Button { model.state.snapshots.removeAll { $0.id == snapshot.id }; model.selectedSnapshotIDs.remove(snapshot.id) } label: {
                Image(systemName: "xmark").foregroundStyle(.red)
            }.buttonStyle(.plain)
        }
    }

    /// Display-only offsets. Hold Shift for a fine step.
    private func offsets(_ i: Int) -> some View {
        HStack(spacing: 4) {
            stepper("Delay", value: model.state.snapshots[i].offsetDelayMs, unit: "ms") { model.state.snapshots[i].offsetDelayMs += $0 }
            Button("↩") { model.state.snapshots[i].offsetDelayMs = 0 }.buttonStyle(.borderless)
            stepper("Gain", value: model.state.snapshots[i].offsetGainDB, unit: "dB") { model.state.snapshots[i].offsetGainDB += $0 }
            Button("↩") { model.state.snapshots[i].offsetGainDB = 0 }.buttonStyle(.borderless)
            Button { model.state.snapshots[i].inverted.toggle() } label: { Image(systemName: "plusminus") }
                .foregroundStyle(model.state.snapshots[i].inverted ? .orange : .primary)
        }
        .font(.caption)
    }

    private func stepper(_ label: String, value: Double, unit: String, change: @escaping (Double) -> Void) -> some View {
        HStack(spacing: 2) {
            Text(label).foregroundStyle(.secondary)
            Button("−") { change(-step) }.buttonStyle(.borderless)
            Text(String(format: "%.2f %@", value, unit)).monospacedDigit().frame(width: 62)
            Button("+") { change(step) }.buttonStyle(.borderless)
        }
    }

    private var step: Double { NSEvent.modifierFlags.contains(.shift) ? 0.5 * 0.025 : 0.5 }
}

struct SnapshotEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State var snapshot: Snapshot

    var body: some View {
        Form {
            Text("Edit Snapshot Details").font(.headline)
            TextField("Name", text: $snapshot.name)
            ColorPicker("Colour", selection: Binding(get: { snapshot.color }, set: { snapshot.colorHex = $0.hex }))
            Picker("Speaker", selection: $snapshot.speakerID) {
                Text("None").tag(UUID?.none)
                ForEach(model.state.speakers) { sp in Text(sp.name).tag(UUID?.some(sp.id)) }
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Update") {
                    if let i = model.state.snapshots.firstIndex(where: { $0.id == snapshot.id }) { model.state.snapshots[i] = snapshot }
                    dismiss()
                }.keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(width: 360)
    }
}

struct MeasurementSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Picker("Averaging", selection: Binding(get: { model.state.averaging }, set: { model.setAveraging($0) })) {
                ForEach(Averaging.allCases) { Text($0.rawValue).tag($0) }
            }
            .disabled(!model.noiseChannels.isEmpty)
            Picker("Smoothing", selection: $model.state.smoothing) {
                ForEach(Smoothing.allCases) { Text($0.label).tag($0) }
            }
            Picker("Coherence (hide below)", selection: $model.state.coherenceHide) {
                ForEach(CoherenceHide.allCases) { Text($0.label).tag($0) }
            }
            Picker("Graph Scale", selection: $model.state.graphScale.kind) {
                ForEach(GraphScale.Kind.allCases) { Text($0.rawValue).tag($0) }
            }
            if model.state.graphScale.kind == .custom {
                Stepper("± \(Int(model.state.graphScale.customDB)) dB", value: $model.state.graphScale.customDB, in: 1...60)
                TextField("From Hz", value: $model.state.graphScale.fromHz, format: .number)
                TextField("To Hz", value: $model.state.graphScale.toHz, format: .number)
            }
            Toggle("Clock Drift Correction", isOn: Binding(get: { model.state.clockDrift }, set: { model.state.clockDrift = $0; model.engine?.clockDriftCorrection = $0 }))
            Text("Turn this on only when the mic and the speakers use different interfaces.").font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct MicMeter: View {
    var peak: Double
    var rms: Double

    var body: some View {
        GeometryReader { g in
            let w = g.size.width
            let x = { (db: Double) in CGFloat(min(max((db + 80) / 80, 0), 1)) * w }
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.1))
                Capsule().fill(peak > -3 ? .red : .green).frame(width: x(rms))
                Rectangle().fill(.white).frame(width: 2).offset(x: x(peak) - 1)
            }
        }
    }
}

extension Color {
    var hex: String {
        let c = NSColor(self).usingColorSpace(.sRGB) ?? .yellow
        return String(format: "#%02X%02X%02X", Int(c.redComponent * 255), Int(c.greenComponent * 255), Int(c.blueComponent * 255))
    }
}
