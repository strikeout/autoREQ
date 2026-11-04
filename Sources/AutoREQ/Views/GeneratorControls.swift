import AutoREQCore
import SwiftUI

/// The signal, the level, the output channel and the presets of the generator.
/// The Measure screen and the Spectrum screen share it.
struct GeneratorControls: View {
    @Environment(AppModel.self) private var model
    @State private var naming = false
    @State private var presetName = ""

    /// The peak-to-RMS ratio of each signal in dB. A file uses a typical value for music.
    private static let crest: [SignalKind: Double] = [.pink: 13, .periodicPink: 14, .white: 5, .sine: 3, .dualSine: 6, .file: 15]

    private func bind<T>(_ path: WritableKeyPath<GeneratorPreset, T>) -> Binding<T> {
        Binding(get: { model.state.generator[keyPath: path] }, set: { model.state.generator[keyPath: path] = $0; model.generatorChanged() })
    }

    var body: some View {
        let g = model.state.generator
        HStack(spacing: 10) {
            Picker("Signal", selection: bind(\.signal.kind)) {
                ForEach(SignalKind.allCases) { Text($0.rawValue).tag($0) }
            }
            .frame(width: 210)
            switch g.signal.kind {
            case .sine:
                frequency(bind(\.signal.frequency))
            case .dualSine:
                frequency(bind(\.signal.frequency))
                frequency(bind(\.signal.frequency2))
            case .file:
                Button("Choose File…") { model.chooseGeneratorFile() }
                Text(g.signal.filePath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "No file")
                    .lineLimit(1).truncationMode(.middle).frame(maxWidth: 160, alignment: .leading).foregroundStyle(.secondary)
            default:
                EmptyView()
            }
            Stepper(value: bind(\.levelDBFS), in: -60...(-3), step: 1) {
                Text("\(Int(g.levelDBFS)) dBFS RMS").monospacedDigit()
            }
            .fixedSize()
            if g.levelDBFS + (Self.crest[g.signal.kind] ?? 0) > 0 {
                Label("Peaks clip", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.caption)
            }
            Picker("Output", selection: bind(\.channel)) {
                Text("All channels").tag(-1)
                ForEach(0..<(model.outputDevice?.outputChannels ?? 2), id: \.self) { Text(channelName($0)).tag($0) }
            }
            .frame(width: 200)
            if model.noiseChannels.isEmpty {
                Button { Task { await model.startGenerator() } } label: { Label("Start", systemImage: "play.fill") }
            } else {
                Button { model.setNoise([]) } label: { Label("Stop", systemImage: "stop.fill") }
            }
            Menu("Presets") {
                ForEach(model.state.generatorPresets) { p in Button(p.name) { model.applyPreset(p) } }
                if !model.state.generatorPresets.isEmpty { Divider() }
                Button("Save Preset…") { presetName = g.signal.label; naming = true }
                if !model.state.generatorPresets.isEmpty {
                    Menu("Delete") {
                        ForEach(model.state.generatorPresets) { p in Button(p.name) { model.state.generatorPresets.removeAll { $0.name == p.name } } }
                    }
                }
            }
            .fixedSize()
        }
        .alert("Save Preset", isPresented: $naming) {
            TextField("Name", text: $presetName)
            Button("Save") { if !presetName.isEmpty { model.savePreset(named: presetName) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("A preset keeps the signal, the level and the output channel.")
        }
    }

    private func frequency(_ value: Binding<Double>) -> some View {
        HStack(spacing: 2) {
            TextField("Hz", value: value, format: .number.precision(.fractionLength(0...1)))
                .frame(width: 70).multilineTextAlignment(.trailing)
            Text("Hz").foregroundStyle(.secondary)
        }
    }

    private func channelName(_ c: Int) -> String {
        let names = model.state.speakers.filter { $0.outputChannel == c }.map(\.name)
        return "Ch \(c + 1)" + (names.isEmpty ? "" : " — " + names.joined(separator: ", "))
    }
}
