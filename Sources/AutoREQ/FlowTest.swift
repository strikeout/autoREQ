import AppKit
import AutoREQCore
import AVFoundation
import SwiftUI

/// Drives the screens of the app through their user flows on a loop-through device, for example VB-Cable.
///
/// The test uses a model that saves nothing, so it never changes the state file of the user.
/// It draws each screen in a hidden window during the flow. A crash in a view then stops the test.
/// Run: `open -W --stdout out.txt build/AutoREQ.app --args --flowtest "VB-Cable"`
@MainActor
enum FlowTest {
    static func run(deviceName: String) async -> Int32 {
        func say(_ s: String) { print(s); fflush(stdout) }
        var failures: [String] = []
        func check(_ ok: Bool, _ what: String) {
            say((ok ? "ok    " : "FAIL  ") + what)
            if !ok { failures.append(what) }
        }

        _ = await AVCaptureDevice.requestAccess(for: .audio)
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else { say("FAIL microphone access denied"); return 1 }
        guard let dev = AudioDevice.all().first(where: { $0.name == deviceName && $0.inputChannels > 0 && $0.outputChannels > 0 }) else {
            say("FAIL no loop-through device named \(deviceName)"); return 1
        }
        var s = PersistedState()
        s.micDeviceUID = dev.uid
        s.outputDeviceUID = dev.uid
        s.micChannel = 0
        s.extraMicChannels = dev.inputChannels > 1 ? [1] : []
        s.sampleRate = AudioDevice.sampleRate(of: dev.id) ?? 48_000
        s.speakers = SystemTemplate.stereo.speakers
        s.generator = GeneratorPreset(name: "Current", signal: .pink, levelDBFS: -20, channel: -1)
        s.clockDrift = true
        let model = AppModel(test: s)
        let session = CalibrationSession(app: model)
        let mics = dev.inputChannels > 1 ? 2 : 1

        // The window draws the current screen at each pump step. A crash in a view body stops the test there.
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 900), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        window.orderFrontRegardless()
        func show(_ section: AppSection) {
            window.contentView = NSHostingView(rootView: ContentView(section: section, session: session).environment(model).preferredColorScheme(.dark))
            say("--- \(section.rawValue)")
        }
        func pump(_ seconds: Double) async {
            let end = Date().addingTimeInterval(seconds)
            while Date() < end {
                if let v = window.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) { v.cacheDisplay(in: v.bounds, to: rep) }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        func until(_ seconds: Double, _ done: () -> Bool) async {
            let end = Date().addingTimeInterval(seconds)
            while Date() < end && !done() { await pump(0.2) }
        }

        // MARK: Measure: live traces, snapshots, Find, reference, timer
        show(.measure)
        await pump(0.5)
        check(await model.startGenerator(), "Measure: the generator starts")
        await until(8) { model.liveByChannel.count == mics && model.status == .measuring }
        await pump(2)
        check(model.live != nil, "Measure: the main mic has a live response")
        check(model.liveByChannel.count == mics, "Measure: each of the \(mics) mics has a live response")
        let snaps = model.takeSnapshot()
        check(snaps.count == mics, "Measure: Take Snapshot keeps one snapshot for each mic")
        if let t = model.live?.impulse?.peakTimeMs { model.state.liveDelayMs = -t }
        check(abs(model.state.liveDelayMs) < 0.05, "Measure: Find gives a phase delay near 0 ms on a loop")
        model.state.referenceSnapshotIDStored = snaps.first?.id
        await pump(1)
        model.state.referenceSnapshotIDStored = nil
        model.state.timer = CaptureTimer(intervalSeconds: 2, count: 2, average: true, keepEach: false)
        var before = model.state.snapshots.count
        model.startTimer()
        await until(8) { model.timerProgress == nil }
        let averages = model.state.snapshots.filter { $0.name.hasPrefix("Timer average") }.count
        check(averages == mics && model.state.snapshots.count == before + mics, "Measure: the timer adds one average for each mic and removes the captures")
        before = model.state.snapshots.count
        model.startTimer()
        await pump(2.6)
        model.stopTimer()
        await pump(0.5)
        check(model.state.snapshots.count == before + mics && model.state.snapshots.filter { $0.name.hasPrefix("Timer average") }.count == averages,
              "Measure: Stop Timer keeps the capture and adds no average")
        model.setNoise([])

        // MARK: Spectrum: RTA, sine level, band change, spectrograph
        show(.spectrum)
        await pump(1)
        model.state.generator.signal = SignalSettings(kind: .sine, frequency: 1000)
        model.state.generator.channel = 0
        check(await model.startGenerator(), "Spectrum: the sine starts")
        await pump(3)
        let bands = model.spectrumBands
        let k = bands.firstIndex { abs($0.centre - 1000) < 1 }
        let level = k.flatMap { model.spectrum[0]?[$0] } ?? -200
        check(abs(level + 20) < 1, String(format: "Spectrum: a -20 dBFS sine reads %.1f dB in the 1 kHz band", level))
        model.state.spectrum.banding = .oct24
        model.spectrumSettingsChanged()
        await pump(1.5)
        check(model.spectrogram.count > 10, "Spectrum: the spectrograph has frames")
        model.state.spectrum.banding = .oct3
        model.setNoise([])

        // MARK: Room Analysis: live analysis, then a sweep snapshot in the same view
        show(.room)
        model.state.generator = GeneratorPreset(name: "Current", signal: .pink, levelDBFS: -20, channel: 0)
        _ = await model.startGenerator()
        await pump(4)
        let count = model.state.snapshots.count
        await model.measureSweep(channel: 0, seconds: 1, repeats: 1, peakDBFS: -12)
        let sweep = model.state.snapshots.dropFirst(count).first { $0.name.hasPrefix("Sweep") }
        check(sweep?.response.impulse != nil, "Room Analysis: the sweep keeps a snapshot with an impulse response")
        check(!(sweep?.distortion ?? []).isEmpty, "Room Analysis: the sweep snapshot has the distortion")
        _ = await model.startGenerator()
        await pump(2)
        // The live result is on the screen. The switch to the longer sweep impulse response crashed in v1.8.2.
        if let id = sweep?.id.uuidString { model.roomSourceID = id }
        await pump(4)
        model.roomSourceID = "live"
        await pump(2)
        check(true, "Room Analysis: the screen survives the switch from live to the sweep and back")
        model.setNoise([])

        // MARK: SPL: calibration, meters, log on and off the screen
        show(.spl)
        await pump(1)
        model.state.generator = GeneratorPreset(name: "Current", signal: SignalSettings(kind: .sine, frequency: 1000), levelDBFS: -20, channel: 0)
        _ = await model.startGenerator()
        await pump(1.5)
        model.state.spl.calibratorDB = 94
        await model.calibrateSPL(channel: 0)
        let offset = model.splCalibration(0) ?? 0
        check(abs(offset - 114) < 0.3, String(format: "SPL: the calibration offset is %.2f dB (114 expected)", offset))
        await pump(2.5)
        let leq = model.soundLevels[0]?.a.leq1s ?? 0
        check(abs(leq - 94) < 0.3, String(format: "SPL: the calibrated tone reads %.2f dB(A)", leq))
        let log = FileManager.default.temporaryDirectory.appendingPathComponent("autoreq-flowtest-spl.csv")
        model.startSPLLog(to: log)
        await pump(2.4)
        show(.measure)
        await pump(2.4)
        model.stopSPLLog()
        let rows = ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").count - 1
        check(rows >= 4, "SPL: the log writes each second, also after the SPL screen closes (\(rows) rows)")
        try? FileManager.default.removeItem(at: log)
        model.setNoise([])

        // MARK: Calibrate: the guided Quick Measurement from the levels to the results
        show(.calibrate)
        model.state.options.quickPositions = 1
        model.state.options.generations = .fastest
        model.state.options.phaseCorrection = true
        session.mode = .quick
        await session.beginLevels()
        await pump(1.5)
        session.beginMeasure()
        await until(90) { session.stage == .results }
        check(session.stage == .results, "Calibrate: the guided calibration reaches the results")
        check(model.state.result?.channels.count == 2, "Calibrate: the result has both speakers (\(model.state.result?.channels.map(\.correction.speakerName) ?? []))")
        await pump(1)

        // MARK: Target Curve: each preset, the custom curve and the measured room
        show(.target)
        for t in TargetCurve.presets + [TargetCurve.custom] {
            model.state.target = t
            await pump(0.4)
        }
        check(true, "Target Curve: each preset and the custom curve draw")

        // MARK: Settings: latency drift check, both modes
        show(.settings)
        await model.latencyDriftCheck(runs: 3, reopen: false, channel: 0)
        check(model.latencyReport?.hasPrefix("3 of 3") == true, "Settings: the latency drift check finds the delay in 3 runs")
        await model.latencyDriftCheck(runs: 2, reopen: true, channel: 0)
        check(model.latencyReport?.hasPrefix("2 of 2") == true, "Settings: the latency drift check works with re-opened streams")

        // MARK: Remote: the API, a bad query value, the generator and a restart
        model.state.generator = GeneratorPreset(name: "Current", signal: .pink, levelDBFS: -20, channel: 0)
        _ = await model.startGenerator()
        await pump(3)
        model.startRemote(lan: false, port: 0)
        await pump(0.6)
        func request(_ path: String, post: Bool = false) async -> Int {
            guard let r = model.remote, let url = URL(string: "http://127.0.0.1:\(r.port)\(path)\(path.contains("?") ? "&" : "?")token=\(r.token)") else { return -1 }
            var req = URLRequest(url: url)
            req.httpMethod = post ? "POST" : "GET"
            guard let (_, resp) = try? await URLSession.shared.data(for: req) else { return -1 }
            return (resp as? HTTPURLResponse)?.statusCode ?? -1
        }
        for path in ["/api/status", "/api/response", "/api/impulse?ms=nan", "/api/spectrum", "/api/spl", "/"] {
            let code = await request(path)
            check(code == 200, "Remote: GET \(path) answers \(code)")
        }
        let started = await request("/api/generator/start", post: true), stopped = await request("/api/generator/stop", post: true)
        check(started == 200 && stopped == 200 && model.noiseChannels.isEmpty, "Remote: the API starts and stops the generator")
        model.startRemote(lan: false)
        await pump(1)
        let again = await request("/api/status")
        check(again == 200, "Remote: the server answers after a restart on the same port")
        model.stopRemote()

        say("--- Loopback: skipped, because it needs a second device for the output")
        model.stopEngine()
        window.orderOut(nil)
        say(failures.isEmpty ? "PASS" : "FAIL \(failures.count) of the checks")
        return failures.isEmpty ? 0 : 1
    }
}
