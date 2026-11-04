import Accelerate
import AppKit
import AutoREQCore
import AVFoundation
import Foundation
import Observation
import SwiftUI

/// A stored measurement. The offsets change only the display, never the data.
struct Snapshot: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var colorHex: String
    var response: Response
    var visible = true
    var speakerID: UUID?
    var offsetDelayMs = 0.0
    var offsetGainDB = 0.0
    var inverted = false
    /// The harmonic distortion of a sweep measurement. Other snapshots have none.
    var distortion: [HarmonicPoint]?

    var displayed: Response { response.offset(delayMs: offsetDelayMs, gainDB: offsetGainDB, inverted: inverted) }
    var color: Color { Color(hex: colorHex) }
}

enum CoherenceHide: Double, Codable, CaseIterable, Identifiable {
    case low = 0, medium = 0.5, high = 0.7, veryHigh = 0.9
    var id: Double { rawValue }
    var label: String { ["Low (show all)", "Medium", "High", "Very High"][CoherenceHide.allCases.firstIndex(of: self)!] }
}

struct GraphScale: Codable, Hashable {
    enum Kind: String, Codable, CaseIterable, Identifiable { case full = "Full Scale", norm24 = "±24dB Norm", custom = "Custom…"; var id: String { rawValue } }
    var kind: Kind = .full
    var customDB = 30.0
    var fromHz = 20.0
    var toHz = 20_000.0
}

/// The settings of the Spectrum screen.
struct SpectrumSettings: Codable, Hashable {
    /// The zero-based input channels of the mic device.
    var channels: [Int] = [0]
    var banding: Banding = .oct3
    var averaging: Averaging = .fast
    var peakHold = false
    var spectrogramSeconds = 30.0
    var floorDB = -100.0
    var ceilingDB = -20.0
}

/// The settings of the SPL screen.
struct SPLSettings: Codable, Hashable {
    /// The zero-based input channels of the mic device that have a meter.
    var channels: [Int] = [0]
    /// The dB SPL offset of each channel, keyed `uid#channel`. Missing means not calibrated.
    var calibrations: [String: Double] = [:]
    var meters: [MeterSpec] = MeterSpec.defaults
    var calibratorDB = 94.0
    var bandsThird = false
}

/// One tile of the SPL meter grid.
struct MeterSpec: Codable, Hashable, Identifiable {
    enum Metric: String, Codable, CaseIterable, Identifiable {
        case laf = "LAF", las = "LAS", lai = "LAI", lcf = "LCF", lcs = "LCS", lzf = "LZF", lzs = "LZS"
        case laeq = "LAeq", lceq = "LCeq", lzeq = "LZeq", lafmax = "LAFmax", lasmax = "LASmax"
        case lcpeak = "LCpeak", lzpeak = "LZpeak", laeq1 = "LAeq 1 min", laeq10 = "LAeq 10 min", laeq15 = "LAeq 15 min"
        case osha = "OSHA dose", niosh = "NIOSH dose", osha8 = "OSHA 8 h projected", niosh8 = "NIOSH 8 h projected"
        var id: String { rawValue }
        var isDose: Bool { [.osha, .niosh, .osha8, .niosh8].contains(self) }

        func value(_ l: SoundLevels) -> Double? {
            switch self {
            case .laf: l.a.fast
            case .las: l.a.slow
            case .lai: l.a.impulse
            case .lcf: l.c.fast
            case .lcs: l.c.slow
            case .lzf: l.z.fast
            case .lzs: l.z.slow
            case .laeq: l.a.leq
            case .lceq: l.c.leq
            case .lzeq: l.z.leq
            case .lafmax: l.a.maxFast
            case .lasmax: l.a.maxSlow
            case .lcpeak: l.lcPeak
            case .lzpeak: l.lzPeak
            case .laeq1: l.leqWindows.first { $0.seconds == 60 }?.value
            case .laeq10: l.leqWindows.first { $0.seconds == 600 }?.value
            case .laeq15: l.leqWindows.first { $0.seconds == 900 }?.value
            case .osha: l.oshaDosePercent
            case .niosh: l.nioshDosePercent
            case .osha8: l.oshaProjected8hPercent
            case .niosh8: l.nioshProjected8hPercent
            }
        }
    }
    var id = UUID()
    var channel = 0
    var metric: Metric

    static let defaults: [MeterSpec] = [.laf, .las, .laeq, .lcpeak, .laeq1, .laeq15, .osha, .niosh].map { MeterSpec(metric: $0) }
}

/// The settings of the capture timer on the Measure screen.
struct CaptureTimer: Codable, Hashable {
    var intervalSeconds = 10.0
    var count = 6
    /// Adds one snapshot with the power average of all captures.
    var average = true
    /// Keeps each capture as a snapshot. Without it, only the average stays.
    var keepEach = false
}

/// Everything the app saves between launches.
struct PersistedState: Codable {
    var micDeviceUID: String?
    var micChannel = 0
    var outputDeviceUID: String?
    var loopbackInputUID: String?
    var sampleRate = 48_000.0
    var averaging: Averaging = .slow
    var smoothing: Smoothing = .oct6
    var coherenceHide: CoherenceHide = .low
    var graphScale = GraphScale()
    var clockDrift = false
    var snapshots: [Snapshot] = []
    var speakers: [Speaker] = SystemTemplate.stereoSub.speakers
    var options = CorrectionOptions()
    var target: TargetCurve = .houseFlat
    var result: CalibrationResult?
    var appliedResult: CalibrationResult?
    var loopbackBypass = false
    // The loopback volume fields are optional so that a state file from an older version still decodes.
    var loopbackMasterDBStored: Double?
    var loopbackTrimsStored: [String: Double]?
    var correctionStrengthStored: Double?
    var micCalibrationsStored: [MicCalibration]?
    var micCalibrationByDeviceStored: [String: String]?
    var generatorStored: GeneratorPreset?
    var generatorPresetsStored: [GeneratorPreset]?
    var spectrumStored: SpectrumSettings?
    var extraMicChannelsStored: [Int]?
    var multiWindowStored: Bool?
    var referenceSnapshotIDStored: UUID?
    var liveDelayMsStored: Double?
    var timerStored: CaptureTimer?
    var splStored: SPLSettings?
    var areasStored: [ListeningArea]?
    /// The last custom target curve, so a preset choice does not lose the custom points.
    var customTarget: TargetCurve?
    /// The I/O buffer size in frames. Nil keeps the size of the device.
    var bufferFrames: Int?
    /// The space plan of the Complete Measurement mode. The first area is the main area.
    var areas: [ListeningArea] {
        get { areasStored ?? [ListeningArea(name: "Main", size: .singleSeat)] }
        set { areasStored = newValue }
    }
    var spl: SPLSettings { get { splStored ?? SPLSettings() } set { splStored = newValue } }

    /// More mic channels of the mic device. Each one measures at the same time as the main mic.
    var extraMicChannels: [Int] { get { extraMicChannelsStored ?? [] } set { extraMicChannelsStored = newValue } }
    /// Frequency-dependent windows for the transfer function (FTW).
    var multiWindow: Bool { get { multiWindowStored ?? true } set { multiWindowStored = newValue } }
    /// The plot time reference of the live traces in ms. It changes only the displayed phase.
    var liveDelayMs: Double { get { liveDelayMsStored ?? 0 } set { liveDelayMsStored = newValue } }
    var timer: CaptureTimer { get { timerStored ?? CaptureTimer() } set { timerStored = newValue } }

    /// The generator setup of the Measure and Spectrum screens. The guided calibration always uses pink noise.
    var generator: GeneratorPreset {
        get { generatorStored ?? GeneratorPreset(name: "Current", signal: .pink, levelDBFS: -20, channel: 0) }
        set { generatorStored = newValue }
    }
    var generatorPresets: [GeneratorPreset] { get { generatorPresetsStored ?? [] } set { generatorPresetsStored = newValue } }
    var spectrum: SpectrumSettings { get { spectrumStored ?? SpectrumSettings() } set { spectrumStored = newValue } }

    /// Calibration files that the user imported.
    var micCalibrations: [MicCalibration] { get { micCalibrationsStored ?? [] } set { micCalibrationsStored = newValue } }
    /// The chosen calibration name for each mic device UID.
    var micCalibrationByDevice: [String: String] { get { micCalibrationByDeviceStored ?? [:] } set { micCalibrationByDeviceStored = newValue } }

    /// The master volume after the correction, in dB.
    var loopbackMasterDB: Double { get { loopbackMasterDBStored ?? 0 } set { loopbackMasterDBStored = newValue } }
    /// A trim in dB per speaker name, on top of the calibrated gain.
    var loopbackTrims: [String: Double] { get { loopbackTrimsStored ?? [:] } set { loopbackTrimsStored = newValue } }
    /// 0…1. It scales the gain of every EQ band.
    var correctionStrength: Double { get { correctionStrengthStored ?? 1 } set { correctionStrengthStored = newValue } }
}

@Observable @MainActor
final class AppModel {
    var state = PersistedState() { didSet { scheduleSave() } }
    var devices: [AudioDevice] = []

    // Measurement
    private(set) var engine: MeasurementEngine?
    var engineError: String?
    /// The live response of the main mic.
    var live: Response?
    /// The live response of each mic channel, with its mic calibration removed.
    var liveByChannel: [Int: Response] = [:]
    /// The progress text of a sweep measurement. Nil when no sweep measurement runs.
    var sweepProgress: String?
    /// The progress of the capture timer, for example (2, 6). Nil when the timer does not run.
    var timerProgress: (done: Int, total: Int)?
    private var timerTask: Task<Void, Never>?
    var micPeakDB = -140.0
    var micRMSDB = -140.0
    var status: MeasurementEngine.Status = .idle
    var stability = 0.0
    var noiseChannels: Set<Int> = []
    var autoCapturing = false
    var selectedSnapshotIDs: Set<UUID> = []
    /// The signal that plays now on the Measure or Spectrum screen.
    var playingSignal: SignalSettings?

    // Spectrum
    /// The averaged band levels of each input channel, with the mic calibration removed.
    var spectrum: [Int: [Double]] = [:]
    var spectrumPeak: [Int: [Double]] = [:]
    /// The 1/24-octave frames of the spectrograph, oldest first. The engine adds 10 frames each second.
    var spectrogram: [[Float]] = []
    static let spectrogramMaxFrames = 3000
    private var spectrumRunning = false
    /// The band width that the engine uses now. The Spectrum and SPL screens set it.
    private var engineBanding = Banding.oct3

    // SPL
    var soundLevels: [Int: SoundLevels] = [:]
    var splRunning = false
    /// The file of the running SPL log, or nil.
    var splLogURL: URL?
    private var splLog: FileHandle?
    private var splLogTask: Task<Void, Never>?
    private var splActivity: NSObjectProtocol?
    private var loadedFile: (path: String, rate: Double, samples: [Float])?
    var micPermission = AVCaptureDevice.authorizationStatus(for: .audio)

    // Loopback
    private(set) var loopback: LoopbackEngine?
    var loopbackError: String?

    private var saveTask: Task<Void, Never>?

    static let palette = ["#FFC400", "#4FC3F7", "#EF5350", "#66BB6A", "#AB47BC", "#FF7043", "#26C6DA", "#D4E157"]

    /// False for the demo model of the screenshot mode, so that it never writes the user's state file.
    private let persists: Bool

    init() {
        persists = true
        if let data = try? Data(contentsOf: Self.stateURL), let s = try? JSONDecoder().decode(PersistedState.self, from: data) {
            state = s
        }
        refreshDevices()
    }

    /// Makes a model that shows `demo` and saves nothing.
    init(demo: PersistedState) {
        persists = false
        state = demo
        devices = AudioDevice.all()
    }

    nonisolated static var stateURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("AutoREQ", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("state.json")
    }

    private func scheduleSave() {
        guard persists else { return }
        saveTask?.cancel()
        let s = state
        saveTask = Task.detached(priority: .utility) {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled, let data = try? JSONEncoder().encode(s) else { return }
            try? data.write(to: AppModel.stateURL, options: .atomic)
        }
    }

    // MARK: Devices

    func refreshDevices() {
        devices = AudioDevice.all()
        if device(uid: state.micDeviceUID, input: true) == nil, let id = AudioDevice.defaultDevice(input: true) {
            state.micDeviceUID = devices.first { $0.id == id }?.uid
        }
        if device(uid: state.outputDeviceUID, input: false) == nil, let id = AudioDevice.defaultDevice(input: false) {
            state.outputDeviceUID = devices.first { $0.id == id }?.uid
        }
    }

    func device(uid: String?, input: Bool) -> AudioDevice? {
        devices.first { $0.uid == uid && (input ? $0.inputChannels > 0 : $0.outputChannels > 0) }
    }

    var micDevice: AudioDevice? { device(uid: state.micDeviceUID, input: true) }
    var outputDevice: AudioDevice? { device(uid: state.outputDeviceUID, input: false) }
    var loopbackInput: AudioDevice? { device(uid: state.loopbackInputUID, input: true) }

    // MARK: Measurement engine

    func requestMic() async -> Bool {
        if micPermission == .notDetermined {
            _ = await AVCaptureDevice.requestAccess(for: .audio)
            micPermission = AVCaptureDevice.authorizationStatus(for: .audio)
        }
        return micPermission == .authorized
    }

    /// Starts both measurement engines if they do not run. They keep running so arrival times stay comparable.
    @discardableResult
    func startEngine() async -> Bool {
        if engine != nil { return true }
        guard await requestMic() else { engineError = "Microphone access is off. Turn it on in System Settings → Privacy & Security → Microphone."; return false }
        guard let mic = micDevice, let out = outputDevice else { engineError = "Choose a measurement mic and a speaker output in Settings → Audio."; return false }
        if let b = state.bufferFrames {
            AudioDevice.setBufferSize(b, for: out.id)
            AudioDevice.setBufferSize(b, for: mic.id)
        }
        do {
            let e = try MeasurementEngine(outputDevice: out.id, inputDevice: mic.id, micChannels: [state.micChannel] + state.extraMicChannels,
                                          sampleRate: state.sampleRate, averaging: state.averaging, multiWindow: state.multiWindow)
            e.clockDriftCorrection = state.clockDrift
            e.onUpdate = { [weak self] u in
                guard let self else { return }
                self.micPeakDB = u.micPeakDB
                self.micRMSDB = u.micRMSDB
                self.status = u.status
                self.stability = u.stability
                if !u.responses.isEmpty {
                    self.liveByChannel = u.responses.reduce(into: [:]) { out, kv in
                        out[kv.key] = self.micCalibration(for: kv.key).map(kv.value.removing(mic:)) ?? kv.value
                    }
                    self.live = self.liveByChannel[self.state.micChannel]
                }
                if self.spectrumRunning { self.receiveSpectrum(u) }
                if self.splRunning || self.splLog != nil { self.soundLevels = u.soundLevels }
                if self.autoCapturing && u.stability >= 1 {
                    self.autoCapturing = false
                    self.takeSnapshot()
                    self.setNoise([])
                }
            }
            engine = e
            engineError = nil
            return true
        } catch {
            engineError = "The audio engine did not start: \(error.localizedDescription)"
            return false
        }
    }

    func stopEngine() {
        engine?.shutdown()
        engine = nil
        noiseChannels = []
        playingSignal = nil
        spectrumRunning = false
        splRunning = false
        stopSPLLog()
        liveByChannel = [:]
        stopTimer()
        status = .idle
        live = nil
    }

    /// Restarts the engine after a device or rate change.
    func restartEngine() async {
        let wasRunning = engine != nil
        stopEngine()
        if wasRunning { await startEngine() }
    }

    /// Plays pink noise for the guided calibration, or stops the generator with an empty set.
    func setNoise(_ channels: Set<Int>, levelDBFS: Double = -20) {
        noiseChannels = channels
        playingSignal = channels.isEmpty ? nil : .pink
        if channels.isEmpty { autoCapturing = false; stopTimer() }
        engine?.setNoise(channels: channels, levelDBFS: levelDBFS)
        if channels.isEmpty { status = .idle }
    }

    /// The output channels of the generator setup.
    var generatorChannels: Set<Int> {
        let n = engine?.outputChannelCount ?? outputDevice?.outputChannels ?? 2
        let c = state.generator.channel
        return c < 0 ? Set(0..<n) : [min(c, n - 1)]
    }

    /// Plays the generator setup of `state.generator`.
    func startGenerator() async {
        guard await startEngine(), let e = engine else { return }
        let g = state.generator
        var samples: [Float] = []
        if g.signal.kind == .file {
            guard let path = g.signal.filePath else { engineError = "Choose an audio file for the generator."; return }
            if let f = loadedFile, f.path == path, f.rate == e.sampleRate {
                samples = f.samples
            } else {
                do {
                    samples = try await Task.detached { try AudioFileLoader.load(URL(fileURLWithPath: path), sampleRate: e.sampleRate) }.value
                    loadedFile = (path, e.sampleRate, samples)
                } catch {
                    engineError = "The app cannot read \(URL(fileURLWithPath: path).lastPathComponent): \(error.localizedDescription)"
                    return
                }
            }
        }
        let chans = generatorChannels
        noiseChannels = chans
        playingSignal = g.signal
        // A tone gives no transfer function, so the last one must not stay on the screen.
        if g.signal.kind.isTonal { live = nil }
        e.setOutput(channels: chans, signal: g.signal, levelDBFS: g.levelDBFS, fileSamples: samples)
    }

    /// Applies a changed generator setup while the generator plays. A level change does not restart the analysis.
    func generatorChanged() {
        guard !noiseChannels.isEmpty, let e = engine else { return }
        if playingSignal == state.generator.signal && noiseChannels == generatorChannels {
            e.setLevel(state.generator.levelDBFS)
        } else {
            Task { await startGenerator() }
        }
    }

    func savePreset(named name: String) {
        var p = state.generator
        p.name = name
        state.generatorPresets.removeAll { $0.name == name }
        state.generatorPresets.append(p)
    }

    func applyPreset(_ p: GeneratorPreset) {
        state.generator = p
        generatorChanged()
    }

    func chooseGeneratorFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        panel.message = "Choose a WAV, AIFF or other audio file. The app plays it as the measurement signal."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        state.generator.signal.kind = .file
        state.generator.signal.filePath = url.path
        generatorChanged()
    }

    // MARK: Latency drift check

    /// The result text of the last latency drift check.
    var latencyReport: String?
    var latencyCheckRunning = false

    /// Measures the latency `runs` times with pink noise on `channel`.
    /// With `reopen`, the engine opens the audio streams again before each run.
    /// The check writes a CSV file to the diagnostics folder of the app.
    func latencyDriftCheck(runs: Int, reopen: Bool, channel: Int) async {
        latencyCheckRunning = true
        defer { latencyCheckRunning = false }
        var values: [Double] = []
        for k in 1...runs {
            if reopen { stopEngine() }
            guard await startEngine() else { return }
            latencyReport = "Run \(k) of \(runs)…"
            live = nil
            setNoise([channel], levelDBFS: -24)
            let start = Date()
            while Date().timeIntervalSince(start) < 8 && (live == nil || status != .measuring) { try? await Task.sleep(for: .milliseconds(100)) }
            if let r = live { values.append(Double(r.latencySamples) / r.sampleRate * 1000) }
            setNoise([])
            try? await Task.sleep(for: .milliseconds(300))
        }
        guard let lo = values.min(), let hi = values.max() else { latencyReport = "No run found the delay. Check the levels and the routing."; return }
        let dir = AppModel.stateURL.deletingLastPathComponent().appendingPathComponent("diagnostics", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let url = dir.appendingPathComponent("latency-\(f.string(from: Date())).csv")
        let csv = "run,latency_ms\n" + values.enumerated().map { String(format: "%d,%.4f", $0.offset + 1, $0.element) }.joined(separator: "\n") + "\n"
        try? csv.write(to: url, atomically: true, encoding: .utf8)
        latencyReport = String(format: "%d of %d runs: latency %.3f–%.3f ms, spread %.3f ms. The CSV file is %@.", values.count, runs, lo, hi, hi - lo, url.lastPathComponent)
            + (hi - lo > 0.1 ? " The latency changes between runs. Use one interface for the mic and the speakers, or turn on Track Delay." : "")
    }

    // MARK: Remote access

    /// The web viewer and JSON API server. It is nil while it is off.
    private(set) var remote: RemoteServer?
    var remoteError: String?

    /// Starts the server on 127.0.0.1, or on all interfaces with `lan`. The token stays the same until the app quits.
    func startRemote(lan: Bool) {
        let r = remote ?? RemoteServer(model: self)
        r.onFailure = { [weak self] msg in self?.remoteError = msg; self?.remote = nil }
        do {
            try r.start(lan: lan)
            remote = r
            remoteError = nil
            RemoteAPI.splProvider = { m in
                guard m.splRunning || !m.soundLevels.isEmpty else { return ["available": false] }
                let multi = m.state.spl.channels.count > 1
                let meters: [[String: Any]] = m.state.spl.meters.map { spec in
                    let v = m.soundLevels[spec.channel].flatMap { spec.metric.value($0) }
                    return ["label": spec.metric.rawValue + (multi ? " · Ch \(spec.channel + 1)" : ""), "value": v.map { $0 as Any } ?? NSNull()]
                }
                return ["available": true, "meters": meters]
            }
        } catch {
            remoteError = "The server did not start: \(error.localizedDescription)"
        }
    }

    func stopRemote() {
        remote?.stop()
        remote = nil
    }

    // MARK: Background noise for STI

    /// Reads the octave-band noise levels from 125 Hz to 8 kHz on `channel` for 5 s, in dB SPL.
    /// The generator must be off, and the channel needs an SPL calibration.
    func measureNoiseBands(channel: Int) async -> [Double]? {
        guard let off = splCalibration(channel) else { engineError = "Calibrate Ch \(channel + 1) on the SPL screen first."; return nil }
        guard await startEngine(), let e = engine else { return nil }
        setNoise([])
        spectrum = [:]
        engineBanding = .oct1
        spectrumRunning = true
        e.setSpectrum(channels: [channel], banding: .oct1, averaging: .slow)
        try? await Task.sleep(for: .seconds(5))
        let bands = Band.bands(.oct1), levels = spectrum[channel]
        spectrumRunning = false
        e.setSpectrum(channels: [], banding: .oct1, averaging: .slow)
        guard let levels, levels.count == bands.count else { return nil }
        return SpeechTransmission.bands.map { f in
            let i = bands.indices.min { abs(log2(bands[$0].centre / f)) < abs(log2(bands[$1].centre / f)) }!
            return levels[i] + off
        }
    }

    // MARK: SPL

    private func splKey(_ channel: Int) -> String { "\(state.micDeviceUID ?? "")#\(channel)" }

    /// The dB SPL offset of `channel`, or nil if the channel has no calibration.
    func splCalibration(_ channel: Int) -> Double? { state.spl.calibrations[splKey(channel)] }

    /// Starts the meters and the band levels of the SPL screen.
    func startSPL() async {
        guard persists, await startEngine() else { return }
        splRunning = true
        splSettingsChanged()
    }

    func stopSPL() {
        guard splRunning else { return }
        splRunning = false
        if splLog == nil { engine?.setSoundLevel(calibrations: [:]) }
        spectrumRunning = false
        engine?.setSpectrum(channels: [], banding: engineBanding, averaging: .slow)
    }

    /// Sends the SPL channels, their calibrations and the band width to the engine.
    func splSettingsChanged() {
        guard splRunning || splLog != nil else { return }
        let s = state.spl
        engine?.setSoundLevel(calibrations: Dictionary(uniqueKeysWithValues: s.channels.map { ($0, splCalibration($0) ?? 0) }))
        spectrum = [:]
        spectrumPeak = [:]
        spectrumRunning = true
        engineBanding = s.bandsThird ? .oct3 : .oct1
        engine?.setSpectrum(channels: s.channels, banding: engineBanding, averaging: .slow)
    }

    /// Reads the calibrator tone on `channel` for 3 s and stores the offset to the calibrator level.
    func calibrateSPL(channel: Int) async {
        guard let e = engine else { return }
        try? await Task.sleep(for: .seconds(3))
        guard let rms = e.rmsDBFS(channel: channel, seconds: 3), rms > -90 else {
            engineError = "The app hears no calibrator tone on Ch \(channel + 1)."
            return
        }
        state.spl.calibrations[splKey(channel)] = LevelCalibration.offset(measuredRMSDBFS: rms, referenceDBSPL: state.spl.calibratorDB)
        splSettingsChanged()
        engine?.resetSoundLevel()
    }

    /// Writes one CSV line each second to a file that the user selects. The log continues when the
    /// window closes, and macOS does not put the app to sleep while it runs.
    func startSPLLog() {
        let panel = NSSavePanel()
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        panel.nameFieldStringValue = "AutoREQ SPL \(f.string(from: Date())).csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let chans = state.spl.channels
        let header = SPLLogFormat.header(channels: chans.map { "Ch\($0 + 1)" }, leqWindows: [(60, .a), (600, .a), (900, .a)])
        guard FileManager.default.createFile(atPath: url.path, contents: Data((header + "\n").utf8)), let h = try? FileHandle(forWritingTo: url) else {
            engineError = "The app cannot write \(url.lastPathComponent)."
            return
        }
        h.seekToEndOfFile()
        splLog = h
        splLogURL = url
        splActivity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled], reason: "SPL log")
        splLogTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                let rows = chans.compactMap { soundLevels[$0] }
                guard rows.count == chans.count else { continue }
                splLog?.write(Data((SPLLogFormat.row(time: Date(), levels: rows) + "\n").utf8))
            }
        }
    }

    func stopSPLLog() {
        splLogTask?.cancel()
        splLogTask = nil
        try? splLog?.close()
        splLog = nil
        splLogURL = nil
        if let a = splActivity { ProcessInfo.processInfo.endActivity(a) }
        splActivity = nil
    }

    // MARK: Spectrum

    var spectrumBands: [Band] { Band.bands(engineBanding) }
    nonisolated static let spectrogramBands = Band.bands(.oct24)

    func startSpectrum() async {
        // The demo model of the screenshot mode shows its own data and uses no audio device.
        guard persists, await startEngine() else { return }
        spectrumRunning = true
        spectrumSettingsChanged()
    }

    func stopSpectrum() {
        spectrumRunning = false
        engine?.setSpectrum(channels: [], banding: state.spectrum.banding, averaging: state.spectrum.averaging)
    }

    /// Sends the spectrum settings to the engine and clears the peak hold.
    func spectrumSettingsChanged() {
        spectrum = [:]
        spectrumPeak = [:]
        guard spectrumRunning else { return }
        let s = state.spectrum
        engineBanding = s.banding
        engine?.setSpectrum(channels: s.channels, banding: s.banding, averaging: s.averaging)
    }

    func resetSpectrum() {
        spectrumPeak = [:]
        engine?.resetSpectrum()
    }

    private func receiveSpectrum(_ u: MeasurementEngine.Update) {
        let bands = spectrumBands
        let cal = activeMicCalibration
        for (c, raw) in u.spectrum where raw.count == bands.count {
            let levels = c == state.micChannel && cal != nil ? zip(raw, bands).map { $0 - cal!.gain(at: $1.centre) } : raw
            spectrum[c] = levels
            if state.spectrum.peakHold { spectrumPeak[c] = spectrumPeak[c].map { zip($0, levels).map(max) } ?? levels }
        }
        if var f = u.spectrogramFrame, f.count == Self.spectrogramBands.count {
            if state.spectrum.channels.first == state.micChannel, let cal {
                for i in f.indices { f[i] -= Float(cal.gain(at: Self.spectrogramBands[i].centre)) }
            }
            spectrogram.append(f)
            if spectrogram.count > Self.spectrogramMaxFrames { spectrogram.removeFirst(spectrogram.count - Self.spectrogramMaxFrames) }
        }
    }

    func setAveraging(_ a: Averaging) {
        state.averaging = a
        engine?.setAveraging(a)
    }

    func autoCapture() async {
        guard await startEngine() else { return }
        autoCapturing = true
        await startGenerator()
    }

    // MARK: Mic calibration

    var allMicCalibrations: [MicCalibration] { MicCalibration.builtIn + state.micCalibrations }

    /// The calibration of the main mic, if the user selected one.
    var activeMicCalibration: MicCalibration? { micCalibration(for: state.micChannel) }

    /// The key of a mic channel in `micCalibrationByDevice`. The main mic uses the device UID alone,
    /// so a state file from an older version keeps its calibration.
    private func calibrationKey(_ channel: Int) -> String? {
        guard let uid = state.micDeviceUID else { return nil }
        return channel == state.micChannel ? uid : "\(uid)#\(channel)"
    }

    /// The calibration of the mic on `channel`, if the user selected one.
    func micCalibration(for channel: Int) -> MicCalibration? {
        guard let key = calibrationKey(channel), let name = state.micCalibrationByDevice[key] else { return nil }
        return allMicCalibrations.first { $0.name == name }
    }

    func selectMicCalibration(_ name: String?, channel: Int? = nil) {
        guard let key = calibrationKey(channel ?? state.micChannel) else { return }
        state.micCalibrationByDevice[key] = name
    }

    /// Imports REW / miniDSP calibration files and selects the last one for the current mic.
    func importMicCalibration(channel: Int? = nil) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.message = "Choose a mic calibration file, for example the file from miniDSP for your mic's serial number."
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            let name = url.deletingPathExtension().lastPathComponent
            guard let text = (try? String(contentsOf: url, encoding: .utf8)) ?? (try? String(contentsOf: url, encoding: .isoLatin1)),
                  let cal = MicCalibration.parse(text, name: name)
            else { engineError = "\(url.lastPathComponent) is not a calibration file this app can read."; continue }
            state.micCalibrations.removeAll { $0.name == cal.name }
            state.micCalibrations.append(cal)
            selectMicCalibration(cal.name, channel: channel)
        }
    }

    func removeMicCalibration(_ name: String) {
        state.micCalibrations.removeAll { $0.name == name }
        for (k, v) in state.micCalibrationByDevice where v == name { state.micCalibrationByDevice[k] = nil }
    }

    // MARK: Snapshots

    /// Keeps the live response of each mic as a snapshot. The snapshot gets the live plot time reference as its delay offset.
    /// Returns the new snapshots.
    @discardableResult
    func takeSnapshot(name: String? = nil, speakerID: UUID? = nil) -> [Snapshot] {
        let chans = [state.micChannel] + state.extraMicChannels.filter { liveByChannel[$0] != nil }
        let base = name ?? "Snapshot \(state.snapshots.count + 1)"
        var added: [Snapshot] = []
        for c in chans {
            guard let r = liveByChannel[c] ?? (c == state.micChannel ? live : nil) else { continue }
            let n = state.snapshots.count
            var s = Snapshot(name: chans.count > 1 ? "\(base) · Ch \(c + 1)" : base, colorHex: Self.palette[n % Self.palette.count], response: r, speakerID: speakerID)
            s.offsetDelayMs = state.liveDelayMs
            state.snapshots.append(s)
            added.append(s)
        }
        return added
    }

    /// The property returns the reference snapshot. The Measure screen shows every other trace relative to it.
    var referenceSnapshot: Snapshot? {
        guard let id = state.referenceSnapshotIDStored else { return nil }
        return state.snapshots.first { $0.id == id }
    }

    // MARK: Sweep measurement

    /// Plays `repeats` log sweeps on `channel` and keeps one snapshot for each mic.
    /// The snapshot holds the impulse response, the transfer function and the distortion.
    func measureSweep(channel: Int, seconds: Double, repeats: Int, peakDBFS: Double) async {
        guard await startEngine(), let e = engine else { return }
        let rate = e.sampleRate
        let table = SignalGenerator.sweepTable(seconds: seconds, sampleRate: rate)
        let period = table.count
        // The generator scales the table to an RMS of 1.0. This level gives the sweep the requested peak.
        let rms = Double(vDSP.rootMeanSquare(table))
        let level = peakDBFS + 20 * log10(rms)
        let oldStart = e.periodStart
        let signal = SignalSettings(kind: .logSweep, sweepSeconds: seconds)
        noiseChannels = [channel]
        playingSignal = signal
        sweepProgress = "Waiting for the sweep…"
        e.setOutput(channels: [channel], signal: signal, levelDBFS: level)
        defer { sweepProgress = nil }

        // The first sweep starts when the table starts. Earlier periods hold the old signal.
        var firstStart: Int?
        var sums: [Int: [Float]] = [:], offsets: [Int: Int] = [:]
        var used: Set<Int> = []
        let deadline = Date().addingTimeInterval(Double(period) / rate * Double(repeats + 3) + 5)
        while used.count < repeats && Date() < deadline && !noiseChannels.isEmpty {
            try? await Task.sleep(for: .milliseconds(200))
            if firstStart == nil, e.periodStart != oldStart, e.periodStart >= 0 { firstStart = e.periodStart }
            guard let first = firstStart, let p = e.lastPeriod(length: period), p.start >= first, !used.contains(p.start) else { continue }
            used.insert(p.start)
            for (c, y) in p.data {
                sums[c] = sums[c].map { vDSP.add($0, y) } ?? y
                offsets[c] = p.offsets[c]
            }
            sweepProgress = "Sweep \(used.count) of \(repeats)"
        }
        setNoise([])
        guard used.count == repeats else {
            engineError = used.isEmpty ? "The sweep gave no signal at the mic. Check the levels and the routing." : "The sweep measurement stopped early."
            return
        }
        sweepProgress = "Calculating…"
        // Divide by the sweep peak as well, so the levels are relative to the played sweep.
        let n = Float(repeats) * Float(pow(10, peakDBFS / 20))
        let results = await Task.detached(priority: .userInitiated) { () -> [(Int, Response, [HarmonicPoint])] in
            let sweep = LogSweep(seconds: seconds, sampleRate: rate)
            return sums.keys.sorted().map { c in
                let y = vDSP.divide(sums[c]!, n)
                let ir = sweep.impulse(fromRecorded: y)
                var r = Response(impulse: ir)
                r.latencySamples = -(offsets[c] ?? 0)
                return (c, r, sweep.distortion(fromRecorded: y))
            }
        }.value
        for (c, r, d) in results {
            let calibrated = micCalibration(for: c).map(r.removing(mic:)) ?? r
            let k = state.snapshots.count
            var s = Snapshot(name: "Sweep Ch \(channel + 1)" + (results.count > 1 ? " · Mic \(c + 1)" : ""), colorHex: Self.palette[k % Self.palette.count], response: calibrated)
            s.distortion = d
            state.snapshots.append(s)
        }
    }

    /// Writes the impulse response of `s` as a 32-bit float WAV file.
    func exportImpulse(_ s: Snapshot) {
        guard let ir = s.response.impulse else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(s.name) IR.wav"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? WAVFile.encode([ir.samples], sampleRate: ir.sampleRate).write(to: url)
    }

    /// Reads impulse responses from WAV files, one snapshot for each file. The largest peak becomes lag 0.
    func importImpulses() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.wav]
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            guard let data = try? Data(contentsOf: url), let wav = WAVFile.decode(data), let x = wav.channels.first, !x.isEmpty else {
                engineError = "\(url.lastPathComponent) is not a WAV file this app can read."
                continue
            }
            let peak = x.indices.max { abs(x[$0]) < abs(x[$1]) } ?? 0
            let k = state.snapshots.count
            let ir = ImpulseResponse(samples: x, sampleRate: wav.sampleRate, zeroIndex: peak)
            state.snapshots.append(Snapshot(name: url.deletingPathExtension().lastPathComponent, colorHex: Self.palette[k % Self.palette.count], response: Response(impulse: ir)))
        }
    }

    // MARK: Capture timer

    /// Takes a snapshot at the interval of `state.timer`. The generator must play.
    func startTimer() {
        stopTimer()
        let t = state.timer
        timerProgress = (0, t.count)
        timerTask = Task {
            var captured: [Snapshot] = []
            for k in 1...max(1, t.count) {
                try? await Task.sleep(for: .seconds(t.intervalSeconds))
                guard !Task.isCancelled, live != nil, !noiseChannels.isEmpty else { break }
                captured += takeSnapshot(name: "Timer \(k)/\(t.count)")
                timerProgress = (k, t.count)
            }
            if t.average, captured.count > 1 {
                // One average for each mic channel. The names end in "· Ch n" when there are several mics.
                let groups = Dictionary(grouping: captured) { $0.name.components(separatedBy: " · ").dropFirst().first ?? "" }
                for (ch, items) in groups.sorted(by: { $0.key < $1.key }) {
                    guard let avg = Response.powerAverage(items.map(\.response)) else { continue }
                    let n = state.snapshots.count
                    var s = Snapshot(name: "Timer average" + (ch.isEmpty ? "" : " · \(ch)"), colorHex: Self.palette[n % Self.palette.count], response: avg)
                    s.offsetDelayMs = items[0].offsetDelayMs
                    state.snapshots.append(s)
                }
            }
            if !t.keepEach && t.average && captured.count > 1 {
                let ids = Set(captured.map(\.id))
                state.snapshots.removeAll { ids.contains($0.id) }
            }
            timerProgress = nil
        }
    }

    func stopTimer() {
        timerTask?.cancel()
        timerTask = nil
        timerProgress = nil
    }

    func combineSelected() {
        let items = state.snapshots.filter { selectedSnapshotIDs.contains($0.id) }
        guard items.count >= 2, let sum = Response.sum(items.map(\.displayed)) else { return }
        let n = state.snapshots.count
        state.snapshots.append(Snapshot(name: items.map(\.name).joined(separator: " + "), colorHex: Self.palette[n % Self.palette.count], response: sum))
    }

    func exportSnapshots(_ items: [Snapshot]) {
        if items.count == 1, let s = items.first {
            let panel = NSSavePanel()
            panel.nameFieldStringValue = "\(s.name).csv"
            guard panel.runModal() == .OK, let url = panel.url else { return }
            try? ResponseCSV.encode(s.displayed, name: s.name, colorHex: s.colorHex).write(to: url, atomically: true, encoding: .utf8)
        } else {
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.prompt = "Export Here"
            guard panel.runModal() == .OK, let dir = panel.url else { return }
            for s in items {
                try? ResponseCSV.encode(s.displayed, name: s.name, colorHex: s.colorHex).write(to: dir.appendingPathComponent("\(s.name).csv"), atomically: true, encoding: .utf8)
            }
        }
    }

    func importSnapshots() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.commaSeparatedText, .plainText]
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            guard let text = try? String(contentsOf: url, encoding: .utf8), let d = ResponseCSV.decode(text) else { continue }
            let n = state.snapshots.count
            state.snapshots.append(Snapshot(name: d.name ?? url.deletingPathExtension().lastPathComponent, colorHex: d.colorHex ?? Self.palette[n % Self.palette.count], response: d.response))
        }
    }

    // MARK: Loopback

    var correctionStatus: (label: String, color: Color) {
        if state.appliedResult == nil { return ("No correction applied", .gray) }
        if state.loopbackBypass { return ("Correction bypassed", .orange) }
        return loopback == nil ? ("Correction ready — loopback stopped", .gray) : ("Room correction active", .green)
    }

    func startLoopback() {
        stopLoopback()
        guard let inDev = loopbackInput, let outDev = outputDevice else {
            loopbackError = "Choose a loopback input (for example BlackHole 2ch) and a speaker output in Settings → Audio."
            return
        }
        guard inDev.id != outDev.id else { loopbackError = "The loopback input and the speaker output must be different devices."; return }
        do {
            let l = try LoopbackEngine(inputDevice: inDev.id, outputDevice: outDev.id, sampleRate: state.sampleRate)
            l.apply(loopbackCorrections, bypass: state.loopbackBypass)
            l.setMasterVolume(dB: state.loopbackMasterDB)
            loopback = l
            loopbackError = nil
        } catch {
            loopbackError = "Loopback did not start: \(error.localizedDescription)"
        }
    }

    func stopLoopback() {
        loopback?.stop()
        loopback = nil
    }

    func setBypass(_ b: Bool) {
        state.loopbackBypass = b
        reapplyLoopback()
    }

    func applyResult(_ r: CalibrationResult?) {
        state.appliedResult = r
        reapplyLoopback()
    }

    /// The applied correction with the user's trims and strength, or a stereo pass-through if there is none.
    var loopbackCorrections: [ChannelCorrection] {
        var cs = state.appliedResult?.corrections
            ?? SystemTemplate.stereo.speakers.map { ChannelCorrection(speaker: $0, outputChannel: $0.outputChannel!) }
        let strength = state.correctionStrength
        for i in cs.indices {
            cs[i].gainDB += state.loopbackTrims[cs[i].speakerName] ?? 0
            for k in cs[i].eq.indices where [.peaking, .lowShelf, .highShelf].contains(cs[i].eq[k].type) {
                cs[i].eq[k].gainDB *= strength
            }
        }
        return cs
    }

    /// Rebuilds the loopback filters. Call it after a trim or strength change, not on every slider step:
    /// a rebuild resets the filter state.
    func reapplyLoopback() {
        loopback?.apply(loopbackCorrections, bypass: state.loopbackBypass)
    }

    func setMasterVolume(_ dB: Double) {
        state.loopbackMasterDB = dB
        loopback?.setMasterVolume(dB: dB)
    }

    // MARK: Files

    func exportResults(_ r: CalibrationResult) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Export Here"
        guard panel.runModal() == .OK, let dir = panel.url else { return }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? enc.encode(r).write(to: dir.appendingPathComponent("AutoREQ results.autoreq.json"))
        for c in r.channels {
            try? REWExport.filterSettings(c.correction, date: r.date).write(to: dir.appendingPathComponent("\(c.correction.speakerName) REW filters.txt"), atomically: true, encoding: .utf8)
            try? ResponseCSV.encode(c.after, name: "\(c.correction.speakerName) corrected", colorHex: "#FFC400").write(to: dir.appendingPathComponent("\(c.correction.speakerName) corrected.csv"), atomically: true, encoding: .utf8)
        }
    }

    func openResults() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url, let data = try? Data(contentsOf: url),
              let r = try? JSONDecoder().decode(CalibrationResult.self, from: data) else { return }
        state.result = r
    }

    func backup() {
        let panel = NSSavePanel()
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        panel.nameFieldStringValue = "autoreq-backup_\(f.string(from: Date())).json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        var s = state
        s.snapshots = []
        try? JSONEncoder().encode(s).write(to: url)
    }

    func restore() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url, let data = try? Data(contentsOf: url),
              var s = try? JSONDecoder().decode(PersistedState.self, from: data) else { return }
        s.snapshots = state.snapshots
        state = s
        applyResult(s.appliedResult)
    }

    func factoryReset() {
        stopEngine()
        stopLoopback()
        state = PersistedState()
        refreshDevices()
    }
}

extension Color {
    init(hex: String) {
        let h = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        let v = UInt32(h, radix: 16) ?? 0xFFC400
        self.init(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }
}
