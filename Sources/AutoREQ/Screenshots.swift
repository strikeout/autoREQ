import AppKit
import AutoREQCore
import SwiftUI

/// Renders the main screens with a simulated room and writes PNG files for the README.
/// The mode uses no audio device and never reads or writes the user's state file.
/// Run: `open -W build/AutoREQ.app --args --screenshots "$PWD/docs/screenshots"`
@MainActor
enum Screenshots {
    static func run(directory: String) async -> Int32 {
        let dir = URL(fileURLWithPath: directory, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        ResponseChart.hoverEnabled = false
        let model = AppModel(demo: demoState())
        let session = CalibrationSession(app: model)
        session.stage = .results
        let shots: [(String, AppSection)] = [("measure", .measure), ("calibration-results", .calibrate), ("loopback", .loopback), ("target-curve", .target)]
        for (name, section) in shots {
            let root = ContentView(section: section, session: session)
                .environment(model)
                .preferredColorScheme(.dark)
                .tint(.yellow)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 860),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                  backing: .buffered, defer: false)
            window.title = "AutoREQ"
            window.appearance = NSAppearance(named: .darkAqua)
            window.contentView = NSHostingView(rootView: root)
            // Keep the window away from the mouse pointer, so no hover readout shows.
            window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
            window.orderFrontRegardless()
            // SwiftUI and Swift Charts lay out over several run-loop passes.
            try? await Task.sleep(for: .seconds(2))
            let view = window.contentView?.superview ?? window.contentView!
            guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return 1 }
            view.cacheDisplay(in: view.bounds, to: rep)
            guard let png = rep.representation(using: .png, properties: [:]) else { return 1 }
            do { try png.write(to: dir.appendingPathComponent("\(name).png")) } catch { print("FAIL \(error)"); return 1 }
            print("Wrote \(name).png")
            window.orderOut(nil)
        }
        return 0
    }

    /// A simulated stereo pair and subwoofer in a room with typical modes and a calculated correction.
    static func demoState() -> PersistedState {
        var s = PersistedState()
        let sr = 48_000.0
        let speakers = SystemTemplate.stereoSub.speakers
        s.speakers = speakers
        s.target = .houseFlat
        s.averaging = .fifo16
        s.smoothing = .oct12

        var seed: UInt64 = 0x5EED
        func random() -> Double {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Double(seed >> 11) / Double(1 << 53)
        }
        func room(_ filters: [EQBand], latency: Int, dips: [Double]) -> Response {
            // Small ripple above 300 Hz makes the curve look like a real measurement.
            var bands = filters
            for _ in 0..<18 {
                bands.append(EQBand(type: .peaking, frequency: 300 * pow(2, random() * 5.8), gainDB: (random() - 0.5) * 3, q: 3 + random() * 6))
            }
            var r = Response.flat(sampleRate: sr).applying(bands.map { $0.coefficients(sampleRate: sr) }, gainDB: -18)
            r.latencySamples = latency
            for (i, f) in FrequencyGrid.frequencies.enumerated() {
                var c = 0.98
                for d in dips { c -= 0.5 * exp(-pow(log2(f / d) / 0.12, 2)) }
                if f < 25 { c -= 0.3 * (25 - f) / 15 }
                if f > 15_000 { c -= 0.25 * (f - 15_000) / 9000 }
                c -= 0.03 * random()
                r.coherence[i] = min(max(c, 0.05), 1)
            }
            return r
        }
        let left = room([.init(type: .highPass, frequency: 48, q: 0.7), .init(frequency: 68, gainDB: 6, q: 5), .init(frequency: 115, gainDB: -10, q: 6),
                         .init(frequency: 190, gainDB: 4, q: 3), .init(frequency: 420, gainDB: -3, q: 2), .init(frequency: 2400, gainDB: 2, q: 1.5),
                         .init(type: .highShelf, frequency: 12_000, gainDB: -3, q: 0.7)], latency: 4800, dips: [115, 420])
        let right = room([.init(type: .highPass, frequency: 48, q: 0.7), .init(frequency: 72, gainDB: 5, q: 5), .init(frequency: 130, gainDB: -8, q: 5),
                          .init(frequency: 210, gainDB: 5, q: 3), .init(frequency: 900, gainDB: -2, q: 2),
                          .init(type: .highShelf, frequency: 12_000, gainDB: -2, q: 0.7)], latency: 4806, dips: [130])
        let sub = room([.init(type: .highPass, frequency: 18, q: 0.7), .init(type: .lowPass, frequency: 140, q: 0.7), .init(type: .lowPass, frequency: 140, q: 0.7),
                        .init(frequency: 42, gainDB: 9, q: 4), .init(frequency: 78, gainDB: -7, q: 5)], latency: 4950, dips: [78])
        let measured = [speakers[0].id: left, speakers[1].id: right, speakers[2].id: sub]

        s.snapshots = zip(speakers, [left, right, sub]).enumerated().map { n, pair in
            Snapshot(name: pair.0.name, colorHex: AppModel.palette[n], response: pair.1, speakerID: pair.0.id)
        }
        let result = CalibrationPlanner(speakers: speakers, measurements: measured, target: .houseFlat, options: CorrectionOptions()).run()
        s.result = result
        s.appliedResult = result
        s.loopbackMasterDB = -6
        s.correctionStrength = 0.9
        s.loopbackTrims = ["Subwoofer": 1.5]
        let devices = AudioDevice.all()
        s.loopbackInputUID = devices.first { $0.name.contains("BlackHole") || $0.name.contains("VB-Cable") }?.uid
        return s
    }
}
