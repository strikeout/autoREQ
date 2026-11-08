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
    /// The round in the current area. Each round measures one position for each mic.
    var position = 0
    /// The index of the current area in `plan`.
    var areaIndex = 0
    var currentSpeaker: Speaker?
    var waitingForMove = false
    var measureMessage = ""
    /// One set of speaker measurements for each mic position, with the index of its area.
    var measurements: [(area: Int, set: [UUID: Response])] = []
    private var runTask: Task<Void, Never>?

    // Calculate
    var calcChannel = 0
    var calcProgress: EQOptimizer.Progress?
    var skipRequested = false
    var calcPreview: [Double]?

    init(app: AppModel) { self.app = app }

    var speakers: [Speaker] { app.state.speakers.filter { $0.outputChannel != nil } }
    /// The listening areas of this measurement. Quick mode measures the main area only.
    var plan: [ListeningArea] {
        if mode == .quick {
            var main = app.state.areas[0]
            main.positions = app.state.options.quickPositions
            main.weight = 1
            return [main]
        }
        return app.state.areas
    }
    var area: ListeningArea { plan[min(areaIndex, plan.count - 1)] }
    /// The number of positions in the current area.
    var positions: Int { area.positions }
    /// The number of mics that measure at the same time.
    var micCount: Int { app.engine?.micChannels.count ?? 1 + app.state.extraMicChannels.filter { $0 != app.state.micChannel }.count }
    /// The number of mic moves in the current area. Each round measures one position for each mic.
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
        areaIndex = 0
        measurements = []
        runPosition()
    }

    func continueAfterMove() {
        waitingForMove = false
        position += 1
        if position >= rounds { areaIndex += 1; position = 0 }
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
                // Each mic with a response counts. The main mic can miss a speaker that another mic hears.
                if !app.liveByChannel.isEmpty {
                    for (ch, r) in app.liveByChannel { sets[ch, default: [:]][s.id] = r }
                } else { measureMessage = "\(s.name) gave no usable signal. It will be skipped." }
                app.setNoise([])
                try? await Task.sleep(for: .milliseconds(400))
            }
            currentSpeaker = nil
            let a = areaIndex
            let ordered = sets.keys.sorted().map { sets[$0]! }
            let room = max(0, positions - measurements.filter { $0.area == a }.count)
            var keep = Array(ordered.prefix(room))
            // A kept mic can miss a speaker. Then the speaker takes the measurement of a mic that the area does not need.
            // Without this, the speaker drops out of the result.
            for extra in ordered.dropFirst(room) {
                for i in keep.indices { for (id, r) in extra where keep[i][id] == nil { keep[i][id] = r } }
            }
            for set in keep { measurements.append((a, set)) }
            if position + 1 < rounds {
                waitingForMove = true
                measureMessage = area.size.placement
            } else if areaIndex + 1 < plan.count {
                waitingForMove = true
                measureMessage = "Move the mic to the area \(plan[areaIndex + 1].name), then continue."
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

    /// Averages each speaker over the positions of each area, weights the areas, then runs the planner.
    /// The main area comes first, so its first position gives the phase for the time alignment.
    func calculate() {
        var averaged: [UUID: Response] = [:]
        let areas = plan
        for s in speakers {
            let groups = areas.indices.map { a in (weight: areas[a].weight, positions: measurements.filter { $0.area == a }.compactMap { $0.set[s.id] }) }
                .filter { !$0.positions.isEmpty }
            if let r = ListeningArea.combine(groups) { averaged[s.id] = r }
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
