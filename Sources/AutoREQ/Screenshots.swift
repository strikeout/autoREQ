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
        model.live = model.state.snapshots.first?.response
        demoSpectrum(model)
        let shots: [(String, AppSection)] = [("measure", .measure), ("spectrum", .spectrum), ("calibration-results", .calibrate), ("room-analysis", .room),
                                             ("loopback", .loopback), ("target-curve", .target)]
        for (name, section) in shots {
            let root = ContentView(section: section, session: session)
                .environment(model)
                .preferredColorScheme(.dark)
                .tint(.yellow)
            // The room analysis page is long, so its image is taller.
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: section == .room ? 1000 : 860),
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

    /// An RTA and a spectrograph of pink noise through the left speaker. The noise starts after 8 s of room noise.
    static func demoSpectrum(_ model: AppModel) {
        guard let room = model.state.snapshots.first?.response else { return }
        model.state.spectrum.peakHold = true
        var seed: UInt64 = 0xA11CE
        func jitter(_ dB: Double) -> Double {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return (Double(seed >> 11) / Double(1 << 53) * 2 - 1) * dB
        }
        // Pink noise at -20 dBFS RMS gives about -36 dB in each 1/3-octave band.
        func level(_ f: Double, perBand: Double) -> Double { -20 + perBand + room.magnitudeDB[FrequencyGrid.index(of: f)] }
        func floorLevel(_ f: Double, perBand: Double) -> Double { -100 + perBand + 12 * max(0, log2(200 / f)) }
        let bands = model.spectrumBands, perBand3 = 10 * log10(1 / 30.0)
        model.spectrum[0] = bands.map { level($0.centre, perBand: perBand3) + jitter(0.4) }
        model.spectrumPeak[0] = bands.map { level($0.centre, perBand: perBand3) + 1.5 + jitter(0.3) }
        let fine = AppModel.spectrogramBands, perBand24 = 10 * log10(1 / 240.0)
        model.spectrogram = (0..<300).map { t in
            fine.map { b in Float(t < 80 ? floorLevel(b.centre, perBand: perBand24) + jitter(3) : level(b.centre, perBand: perBand24) + jitter(2.5)) }
        }
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
        let leftBands: [EQBand] = [.init(type: .highPass, frequency: 48, q: 0.7), .init(frequency: 68, gainDB: 6, q: 5), .init(frequency: 115, gainDB: -10, q: 6),
                                   .init(frequency: 190, gainDB: 4, q: 3), .init(frequency: 420, gainDB: -3, q: 2), .init(frequency: 2400, gainDB: 2, q: 1.5),
                                   .init(type: .highShelf, frequency: 12_000, gainDB: -3, q: 0.7)]
        var left = room(leftBands, latency: 4800, dips: [115, 420])

        // The impulse response of the left speaker: the direct sound, six early reflections and a diffuse tail.
        var x = [Double](repeating: 0, count: 32_768 + 480)
        x[480] = 1
        for (ms, g) in [(1.9, -0.45), (4.6, 0.32), (7.8, 0.25), (11.5, -0.2), (17.0, 0.14), (23.5, 0.1)] { x[480 + Int(ms * 48)] += g }
        for i in (480 + 1200)..<x.count {
            let t = Double(i - 480) / sr
            x[i] += 0.03 * (random() - 0.5) * exp(-6.91 * t / 0.35)
        }
        for b in leftBands + [EQBand(type: .lowPass, frequency: 18_000, q: 0.7)] {
            var st = BiquadState(b.coefficients(sampleRate: sr))
            x = x.map { st.process($0) }
        }
        left.impulse = ImpulseResponse(samples: x.map { Float($0 + 2e-5 * (random() - 0.5)) }, sampleRate: sr, zeroIndex: 480)
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
