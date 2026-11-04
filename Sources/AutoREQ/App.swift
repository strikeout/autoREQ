import AppKit
import AutoREQCore
import SwiftUI

@main
struct AutoREQApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @State private var model = AppModel()

    var body: some Scene {
        Window("AutoREQ", id: "main") {
            ContentView()
                .environment(model)
                .frame(minWidth: 900, minHeight: 640)
                .preferredColorScheme(.dark)
                .tint(.yellow)
        }
        .windowResizability(.contentMinSize)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // An unbundled `swift run` binary starts as a background process. This makes the window come forward.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--screenshots"), i + 1 < args.count {
            Task { @MainActor in exit(await Screenshots.run(directory: args[i + 1])) }
        }
        if let i = args.firstIndex(of: "--flowtest"), i + 1 < args.count {
            Task { @MainActor in exit(await FlowTest.run(deviceName: args[i + 1])) }
        }
        if let i = args.firstIndex(of: "--selftest"), i + 1 < args.count {
            Task { @MainActor in exit(await SelfTest.run(deviceName: args[i + 1])) }
        }
    }

    // Closing the window keeps the app (and the loopback correction) running, as in the original.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

enum AppSection: String, CaseIterable, Identifiable {
    case home = "Home", measure = "Measure", spectrum = "Spectrum", spl = "SPL", calibrate = "Calibrate", room = "Room Analysis", loopback = "Loopback", target = "Target Curve", settings = "Settings"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .home: "house"
        case .measure: "waveform.path.ecg"
        case .spectrum: "chart.bar.xaxis"
        case .spl: "gauge.with.dots.needle.67percent"
        case .calibrate: "wand.and.stars"
        case .room: "waveform.badge.magnifyingglass"
        case .loopback: "arrow.triangle.2.circlepath"
        case .target: "point.topleft.down.to.point.bottomright.curvepath"
        case .settings: "gearshape"
        }
    }
}

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @State private var section: AppSection?
    @State private var session: CalibrationSession?

    init(section: AppSection = .home, session: CalibrationSession? = nil) {
        _section = State(initialValue: section)
        _session = State(initialValue: session)
    }

    var body: some View {
        NavigationSplitView {
            List(AppSection.allCases, selection: $section) { s in
                Label(s.rawValue, systemImage: s.icon).tag(s)
            }
            .navigationSplitViewColumnWidth(190)
            .safeAreaInset(edge: .bottom) {
                let st = model.correctionStatus
                HStack {
                    Circle().fill(st.color).frame(width: 8, height: 8)
                    Text(st.label).font(.caption).foregroundStyle(.secondary)
                }
                .padding(10)
            }
        } detail: {
            Group {
                switch section ?? .home {
                case .home: HomeView(section: $section)
                case .measure: if let session { MeasureView(section: $section, session: session) }
                case .calibrate: if let session { CalibrateView(session: session) }
                case .spectrum: SpectrumView()
                case .spl: SPLView()
                case .room: RoomView()
                case .loopback: LoopbackView()
                case .target: TargetCurveView()
                case .settings: SettingsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .task { if session == nil { session = CalibrationSession(app: model) } }
        .overlay(alignment: .bottom) {
            if let e = model.engineError ?? model.loopbackError {
                HStack {
                    Image(systemName: "xmark.octagon.fill")
                    Text(e).lineLimit(3)
                    Spacer()
                    Button { model.engineError = nil; model.loopbackError = nil } label: { Image(systemName: "xmark.circle") }.buttonStyle(.plain)
                }
                .padding(12)
                .background(.red.opacity(0.85), in: RoundedRectangle(cornerRadius: 8))
                .padding()
            }
        }
    }
}

struct HomeView: View {
    @Environment(AppModel.self) private var model
    @Binding var section: AppSection?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("AutoREQ").font(.largeTitle.bold())
                Text("Measure your room, calculate a correction, and run it on any speakers through a loopback device.")
                    .foregroundStyle(.secondary)
                HStack(spacing: 16) {
                    card("Calibrate", "wand.and.stars", "Guided room correction: levels, measurements, EQ and time alignment.") { section = .calibrate }
                    card("Measure", "waveform.path.ecg", "Real-time transfer function with pink noise, coherence and snapshots.") { section = .measure }
                    card("Loopback", "arrow.triangle.2.circlepath", "Run the correction live on system audio.") { section = .loopback }
                }
                GroupBox("Room Correction") {
                    let st = model.correctionStatus
                    HStack {
                        Circle().fill(st.color).frame(width: 10, height: 10)
                        Text(st.label)
                        Spacer()
                        if let r = model.state.appliedResult {
                            Text("\(r.channels.count) channels · \(r.targetCurve.name) · \(r.date.formatted(date: .abbreviated, time: .shortened))").foregroundStyle(.secondary)
                        }
                    }.padding(6)
                }
                GroupBox("Devices") {
                    VStack(alignment: .leading, spacing: 6) {
                        row("Measurement mic", model.micDevice.map { "\($0.name) · ch \(model.state.micChannel + 1)" })
                        row("Speaker output", model.outputDevice.map { "\($0.name) · \($0.outputChannels) ch" })
                        row("Loopback input", model.loopbackInput?.name)
                    }.padding(6)
                }
            }
            .padding(24)
        }
    }

    private func row(_ k: String, _ v: String?) -> some View {
        HStack { Text(k).foregroundStyle(.secondary); Spacer(); Text(v ?? "Not set").foregroundStyle(v == nil ? .orange : .primary) }
    }

    private func card(_ title: String, _ icon: String, _ text: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: icon).font(.title).foregroundStyle(.yellow)
                Text(title).font(.title3.bold())
                Text(text).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 140, alignment: .topLeading)
            .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }
}
