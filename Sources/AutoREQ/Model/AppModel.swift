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
    var live: Response?
    var micPeakDB = -140.0
    var micRMSDB = -140.0
    var status: MeasurementEngine.Status = .idle
    var stability = 0.0
    var noiseChannels: Set<Int> = []
    var autoCapturing = false
    var selectedSnapshotIDs: Set<UUID> = []
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
        do {
            let e = try MeasurementEngine(outputDevice: out.id, inputDevice: mic.id, micChannel: state.micChannel, sampleRate: state.sampleRate, averaging: state.averaging)
            e.clockDriftCorrection = state.clockDrift
            e.onUpdate = { [weak self] u in
                guard let self else { return }
                self.micPeakDB = u.micPeakDB
                self.micRMSDB = u.micRMSDB
                self.status = u.status
                self.stability = u.stability
                if let r = u.response { self.live = self.activeMicCalibration.map(r.removing(mic:)) ?? r }
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
        status = .idle
        live = nil
    }

    /// Restarts the engine after a device or rate change.
    func restartEngine() async {
        let wasRunning = engine != nil
        stopEngine()
        if wasRunning { await startEngine() }
    }

    func setNoise(_ channels: Set<Int>, levelDBFS: Double = -12) {
        noiseChannels = channels
        if channels.isEmpty { autoCapturing = false }
        engine?.setNoise(channels: channels, levelDBFS: levelDBFS)
        if channels.isEmpty { status = .idle }
    }

    func setAveraging(_ a: Averaging) {
        state.averaging = a
        engine?.setAveraging(a)
    }

    func autoCapture(channels: Set<Int>) async {
        guard await startEngine() else { return }
        autoCapturing = true
        setNoise(channels)
    }

    // MARK: Mic calibration

    var allMicCalibrations: [MicCalibration] { MicCalibration.builtIn + state.micCalibrations }

    /// The calibration of the current mic device, if one is chosen.
    var activeMicCalibration: MicCalibration? {
        guard let uid = state.micDeviceUID, let name = state.micCalibrationByDevice[uid] else { return nil }
        return allMicCalibrations.first { $0.name == name }
    }

    func selectMicCalibration(_ name: String?) {
        guard let uid = state.micDeviceUID else { return }
        state.micCalibrationByDevice[uid] = name
    }

    /// Imports REW / miniDSP calibration files and selects the last one for the current mic.
    func importMicCalibration() {
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
            selectMicCalibration(cal.name)
        }
    }

    func removeMicCalibration(_ name: String) {
        state.micCalibrations.removeAll { $0.name == name }
        for (k, v) in state.micCalibrationByDevice where v == name { state.micCalibrationByDevice[k] = nil }
    }

    // MARK: Snapshots

    func takeSnapshot(name: String? = nil, speakerID: UUID? = nil) {
        guard let r = live else { return }
        let n = state.snapshots.count
        state.snapshots.append(Snapshot(name: name ?? "Snapshot \(n + 1)", colorHex: Self.palette[n % Self.palette.count], response: r, speakerID: speakerID))
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
