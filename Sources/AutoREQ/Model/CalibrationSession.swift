import AutoREQCore
import Foundation
import Observation

/// The guided room correction: Configure → Set levels → Measure → Calculate → Results.
@Observable @MainActor
final class CalibrationSession {
    enum Stage: Equatable { case configure, levels, measure, calculate, results }
    enum Mode: String, CaseIterable, Identifiable { case quick = "Quick Measurement", complete = "Complete Measurement"; var id: String { rawValue } }

    let app: AppModel
    var stage: Stage = .configure
    var mode: Mode = .quick
    var alignOnly = false

    // Levels
    var noiseFloorDB: Double?
    var levelSpeakerIndex = 0
    /// The RMS level of the pink noise. Its peaks are about 13 dB higher.
    var noiseLevelDBFS = -20.0

    // Measure
    var position = 0
    var currentSpeaker: Speaker?
    var waitingForMove = false
    var measureMessage = ""
    var measurements: [[UUID: Response]] = []
    private var runTask: Task<Void, Never>?

    // Calculate
    var calcChannel = 0
    var calcProgress: EQOptimizer.Progress?
    var skipRequested = false
    var calcPreview: [Double]?

    init(app: AppModel) { self.app = app }

    var speakers: [Speaker] { app.state.speakers.filter { $0.outputChannel != nil } }
    var positions: Int { mode == .quick ? app.state.options.quickPositions : app.state.options.fullPositions }
    /// The number of mics that measure at the same time.
    var micCount: Int { 1 + app.state.extraMicChannels.filter { $0 != app.state.micChannel }.count }
    /// The number of mic moves. Each round measures one position for each mic.
    var rounds: Int { max(1, Int((Double(positions) / Double(micCount)).rounded(.up))) }

    // MARK: Levels

    func beginLevels() async {
        guard await app.startEngine() else { return }
        stage = .levels
        app.setNoise([])
        noiseFloorDB = nil
        levelSpeakerIndex = 0
        // Sample the room noise floor for two seconds.
        var samples: [Double] = []
        for _ in 0..<20 {
            try? await Task.sleep(for: .milliseconds(100))
            samples.append(app.micRMSDB)
        }
        noiseFloorDB = samples.sorted()[samples.count / 2]
        playLevelSpeaker()
    }

    func playLevelSpeaker() {
        guard speakers.indices.contains(levelSpeakerIndex), let ch = speakers[levelSpeakerIndex].outputChannel else { return }
        app.setNoise([ch], levelDBFS: noiseLevelDBFS)
    }

    /// Green when the noise sits well above the floor and does not clip.
    var levelOK: Bool {
        guard let floor = noiseFloorDB else { return false }
        return app.micRMSDB > floor + 15 && app.micPeakDB < -3
    }

    // MARK: Measure

    func beginMeasure() {
        app.setNoise([])
        stage = .measure
        position = 0
        measurements = []
        runPosition()
    }

    func continueAfterMove() {
        waitingForMove = false
        position += 1
        runPosition()
    }

    private func runPosition() {
        runTask = Task {
            // One set of measurements for each mic channel.
            var sets: [Int: [UUID: Response]] = [:]
            app.setAveraging(.fifo16)
            for s in speakers {
                guard let ch = s.outputChannel else { continue }
                currentSpeaker = s
                measureMessage = "Measuring \(s.name)…"
                app.engine?.resetAverages()
                app.setNoise([ch], levelDBFS: noiseLevelDBFS)
                let start = Date()
                try? await Task.sleep(for: .seconds(1.5))
                while !Task.isCancelled {
                    let t = Date().timeIntervalSince(start)
                    if (app.stability >= 1 && t > 3) || t > 12 { break }
                    try? await Task.sleep(for: .milliseconds(100))
                }
                if Task.isCancelled { return }
                if app.live != nil, app.status == .measuring {
                    for (ch, r) in app.liveByChannel { sets[ch, default: [:]][s.id] = r }
                } else { measureMessage = "\(s.name) gave no usable signal. It will be skipped." }
                app.setNoise([])
                try? await Task.sleep(for: .milliseconds(400))
            }
            currentSpeaker = nil
            for ch in sets.keys.sorted() where measurements.count < positions { measurements.append(sets[ch]!) }
            if position + 1 < rounds {
                waitingForMove = true
                measureMessage = "Move the mic 5–10 cm, then continue."
            } else {
                measureMessage = "Measurements done."
                calculate()
            }
        }
    }

    func cancel() {
        runTask?.cancel()
        runTask = nil
        app.setNoise([])
        stage = .configure
    }

    // MARK: Calculate

    /// Averages each speaker over all positions, then runs the planner.
    func calculate() {
        var averaged: [UUID: Response] = [:]
        for s in speakers {
            let rs = measurements.compactMap { $0[s.id] }
            if let a = Response.powerAverage(rs) { averaged[s.id] = a }
        }
        calculate(with: averaged)
    }

    /// Calculates from given measurements, for example from snapshots on the measurement page.
    func calculate(with averaged: [UUID: Response]) {
        stage = .calculate
        skipRequested = false
        calcProgress = nil
        var opts = app.state.options
        if alignOnly { opts.filterCount = 0 }
        let planner = CalibrationPlanner(speakers: app.state.speakers, measurements: averaged, target: app.state.target, options: opts)
        runTask = Task {
            let result = await Task.detached(priority: .userInitiated) { [weak self] in
                planner.run { channel, p in
                    let skip = MainActor.assumeIsolatedSync { self?.skipRequested ?? true }
                    Task { @MainActor in self?.calcChannel = channel; self?.calcProgress = p }
                    return !skip
                }
            }.value
            app.state.result = result
            stage = .results
        }
    }
}

extension MainActor {
    /// Reads a main-actor value from a background thread. It blocks only for the read.
    static func assumeIsolatedSync<T: Sendable>(_ body: @MainActor () -> T) -> T {
        if Thread.isMainThread { return MainActor.assumeIsolated(body) }
        return DispatchQueue.main.sync { MainActor.assumeIsolated(body) }
    }
}
