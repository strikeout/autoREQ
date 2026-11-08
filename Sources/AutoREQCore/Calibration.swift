import Foundation

public enum SpeakerRole: String, Codable, CaseIterable, Sendable {
    case fullRange = "Speaker", subwoofer = "Subwoofer"
}

/// The loopback input that feeds a speaker.
public enum InputSource: String, Codable, CaseIterable, Sendable, Identifiable {
    case left = "Left", right = "Right", mono = "L+R"
    public var id: String { rawValue }
}

/// One speaker of the system. `outputChannel` is a zero-based channel of the output device; nil means "Won't be measured".
public struct Speaker: Codable, Hashable, Sendable, Identifiable {
    public var id = UUID()
    public var name: String
    public var role: SpeakerRole
    public var source: InputSource
    public var outputChannel: Int?

    public init(name: String, role: SpeakerRole, source: InputSource, outputChannel: Int?) {
        self.name = name; self.role = role; self.source = source; self.outputChannel = outputChannel
    }
}

public enum SystemTemplate: String, CaseIterable, Sendable, Identifiable {
    case stereo = "Left + Right"
    case stereoSub = "Left + Right + Subwoofer"
    case mono = "Mono Speaker"
    public var id: String { rawValue }

    public var speakers: [Speaker] {
        switch self {
        case .stereo: [Speaker(name: "Left", role: .fullRange, source: .left, outputChannel: 0),
                       Speaker(name: "Right", role: .fullRange, source: .right, outputChannel: 1)]
        case .stereoSub: [Speaker(name: "Left", role: .fullRange, source: .left, outputChannel: 0),
                          Speaker(name: "Right", role: .fullRange, source: .right, outputChannel: 1),
                          Speaker(name: "Subwoofer", role: .subwoofer, source: .mono, outputChannel: 2)]
        case .mono: [Speaker(name: "Speaker", role: .fullRange, source: .mono, outputChannel: 0)]
        }
    }
}

/// A 4th-order Linkwitz-Riley crossover filter: two cascaded 2nd-order Butterworth sections.
public struct Crossover: Codable, Hashable, Sendable {
    public var highPass: Bool
    public var frequency: Double
    public init(highPass: Bool, frequency: Double) { self.highPass = highPass; self.frequency = frequency }

    public func coefficients(sampleRate: Double) -> [BiquadCoefficients] {
        let c = BiquadCoefficients(type: highPass ? .highPass : .lowPass, frequency: frequency, gainDB: 0, q: 0.5.squareRoot(), sampleRate: sampleRate)
        return [c, c]
    }
}

/// The full processing for one output channel. The loopback engine runs it.
public struct ChannelCorrection: Codable, Hashable, Sendable, Identifiable {
    public var id = UUID()
    public var speakerName: String
    public var role: SpeakerRole
    public var source: InputSource
    public var outputChannel: Int
    public var gainDB: Double = 0
    public var delayMs: Double = 0
    public var inverted = false
    public var crossover: Crossover?
    public var eq: [EQBand] = []

    public init(speaker: Speaker, outputChannel: Int) {
        speakerName = speaker.name; role = speaker.role; source = speaker.source; self.outputChannel = outputChannel
    }

    /// The crossover filters, then the enabled EQ bands.
    public func filters(sampleRate: Double) -> [BiquadCoefficients] {
        (crossover?.coefficients(sampleRate: sampleRate) ?? []) + eq.filter(\.enabled).map { $0.coefficients(sampleRate: sampleRate) }
    }
}

public struct ChannelResult: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID { correction.id }
    public var correction: ChannelCorrection
    public var before: Response
    public var after: Response
    /// The target in dB with this channel's level offset, on `FrequencyGrid`.
    public var target: [Double]
    public var correctedRange: ClosedRange<Double>
    public var errorDB: Double
}

public struct CalibrationResult: Codable, Hashable, Sendable {
    public var date = Date()
    public var targetCurve: TargetCurve
    public var options: CorrectionOptions
    public var channels: [ChannelResult]
    public var systemBefore: Response?
    public var systemAfter: Response?
    /// Plain-language setup assumptions: roles, crossover, ranges, alignment.
    public var assumptions: [String]
    public var sampleRate: Double

    public var corrections: [ChannelCorrection] { channels.map(\.correction) }
}

/// Turns per-speaker measurements into a full correction: crossover, level, delay, polarity and EQ.
public struct CalibrationPlanner {
    public var speakers: [Speaker]
    /// The measurement of each speaker, keyed by speaker id. Each must carry its latency.
    public var measurements: [UUID: Response]
    public var target: TargetCurve
    public var options: CorrectionOptions

    public init(speakers: [Speaker], measurements: [UUID: Response], target: TargetCurve, options: CorrectionOptions) {
        self.speakers = speakers; self.measurements = measurements; self.target = target; self.options = options
    }

    /// The frequency below the passband where the response falls `dropDB` under the 200 Hz–2 kHz median.
    static func lowCorner(_ r: Response, dropDB: Double) -> Double {
        let f = FrequencyGrid.frequencies
        let pass = f.indices.filter { f[$0] >= 200 && f[$0] <= 2000 }.map { r.magnitudeDB[$0] }.sorted()
        guard !pass.isEmpty else { return 20 }
        let ref = pass[pass.count / 2]
        var i = FrequencyGrid.index(of: 200)
        while i > 0 && r.magnitudeDB[i] > ref - dropDB { i -= 1 }
        return f[i]
    }

    /// Runs the full calculation. `progress` gets the channel index and the optimiser progress; return false to stop early.
    public func run(progress: (Int, EQOptimizer.Progress) -> Bool = { _, _ in true }) -> CalibrationResult {
        let used = speakers.filter { $0.outputChannel != nil && measurements[$0.id] != nil }
        let sr = used.first.flatMap { measurements[$0.id]?.sampleRate } ?? 48_000
        let tops = used.filter { $0.role == .fullRange }
        let subs = used.filter { $0.role == .subwoofer }
        let grid = FrequencyGrid.frequencies
        let targetGrid = target.gridValues
        var notes: [String] = []
        notes.append("Roles: " + used.map { "\($0.name) = \($0.role == .subwoofer ? "sub" : "top")" }.joined(separator: ", ") + ".")

        // Crossover from the low corner of the tops.
        var fc: Double?
        if !tops.isEmpty && !subs.isEmpty {
            let corners = tops.compactMap { measurements[$0.id] }.map { Self.lowCorner($0, dropDB: 6) }
            let mean = corners.reduce(0, +) / Double(corners.count)
            fc = min(max((mean * 1.4).rounded(), 60), 150)
            notes.append(String(format: "Crossover: %.0f Hz, Linkwitz-Riley 24 dB/oct (tops -6 dB at %.0f Hz).", fc!, mean))
        }

        // Per-channel pre-EQ response, range and level.
        struct Work { var speaker: Speaker; var corr: ChannelCorrection; var raw: Response; var pre: Response; var range: ClosedRange<Double>; var level: Double }
        var work: [Work] = []
        for s in used {
            guard let raw = measurements[s.id], let ch = s.outputChannel else { continue }
            var corr = ChannelCorrection(speaker: s, outputChannel: ch)
            if let fc { corr.crossover = Crossover(highPass: s.role == .fullRange, frequency: fc) }
            let pre = raw.applying(corr.crossover?.coefficients(sampleRate: sr) ?? [])
            var range: ClosedRange<Double>
            if s.role == .subwoofer {
                range = max(20, Self.lowCorner(raw, dropDB: 12))...min(250, (fc ?? 120) * 1.5)
            } else if let fc {
                range = (fc * 0.7)...20_000
            } else {
                range = max(20, Self.lowCorner(raw, dropDB: 10))...20_000
            }
            if range.lowerBound >= range.upperBound { range = 20...20_000 }
            let core = s.role == .subwoofer ? range : max(range.lowerBound, 200)...min(range.upperBound, 2000)
            let idx = grid.indices.filter { core.contains(grid[$0]) }
            let level: Double
            if options.gainEstimation == .matchedAmplitude {
                let p = idx.map { pow(10, (pre.magnitudeDB[$0] - targetGrid[$0]) / 10) }.reduce(0, +) / Double(max(idx.count, 1))
                level = 10 * log10(max(p, 1e-24))
            } else {
                level = idx.map { pre.magnitudeDB[$0] - targetGrid[$0] }.reduce(0, +) / Double(max(idx.count, 1))
            }
            notes.append(String(format: "%@: measured and corrected %.0f Hz – %.0f Hz.", s.name, range.lowerBound, range.upperBound))
            work.append(Work(speaker: s, corr: corr, raw: raw, pre: pre, range: range, level: level))
        }

        // EQ, one channel at a time.
        var errors: [Double] = []
        for (n, w) in work.enumerated() {
            let t = targetGrid.map { $0 + w.level }
            let opt = EQOptimizer(measured: w.pre.magnitudeDB, target: t, coherence: w.pre.coherence, range: w.range, options: options, sampleRate: sr)
            let r = opt.run { progress(n, $0) }
            work[n].corr.eq = r.filters
            errors.append(r.errorDB)
            if options.gainEstimation == .minimumSummedError {
                let post = w.pre.applying(r.filters.map { $0.coefficients(sampleRate: sr) })
                let idx = grid.indices.filter { w.range.contains(grid[$0]) }
                work[n].level = idx.map { post.magnitudeDB[$0] - targetGrid[$0] }.reduce(0, +) / Double(max(idx.count, 1))
            }
        }

        // Level: match every channel to the quietest one, so the gains only cut.
        let ref = work.map(\.level).min() ?? 0
        for i in work.indices { work[i].corr.gainDB = ref - work[i].level }
        notes.append("Level: \(options.gainEstimation.rawValue).")

        // Time alignment from the measured arrival times.
        let arrival = Dictionary(uniqueKeysWithValues: work.map { ($0.speaker.id, Double($0.raw.latencySamples)) })
        var delay = [UUID: Double]()
        switch options.timeAlign {
        case .allSpeakers:
            let latest = arrival.values.max() ?? 0
            for w in work { delay[w.speaker.id] = latest - arrival[w.speaker.id]! }
        case .subwooferOnly:
            for w in work { delay[w.speaker.id] = 0 }
            let topArrival = tops.compactMap { arrival[$0.id] }
            if !topArrival.isEmpty {
                let meanTop = topArrival.reduce(0, +) / Double(topArrival.count)
                for s in subs {
                    let rel = meanTop - arrival[s.id]!
                    if rel >= 0 { delay[s.id] = rel } else { for t in tops { delay[t.id] = max(delay[t.id] ?? 0, -rel) } }
                }
            }
        }

        // Fine alignment of each sub against the tops at the crossover.
        func fineAlign(_ fc: Double) {
            let band = grid.indices.filter { grid[$0] >= fc / 2 && grid[$0] <= fc * 2 }
            func complexAt(_ w: Work, _ i: Int, extraDelay: Double, inverted: Bool) -> Complex {
                var h = w.pre.complex(i)
                for c in w.corr.eq.map({ $0.coefficients(sampleRate: sr) }) { h = h * c.response(at: grid[i], sampleRate: sr) }
                let total = Double(w.raw.latencySamples) + (delay[w.speaker.id] ?? 0) + extraDelay
                return h * Complex.polar(pow(10, w.corr.gainDB / 20) * (inverted ? -1 : 1), -2 * .pi * grid[i] * total / sr)
            }
            let topWork = work.filter { $0.speaker.role == .fullRange }
            for (k, w) in work.enumerated() where w.speaker.role == .subwoofer {
                var bestCost = Double.infinity, bestShift = 0.0, bestInv = false
                let maxShift = 0.004 * sr
                for inv in [false, true] {
                    var shift = -maxShift
                    while shift <= maxShift {
                        var cost = 0.0
                        for i in band {
                            let s = complexAt(w, i, extraDelay: shift, inverted: inv)
                            for t in topWork {
                                let h = complexAt(t, i, extraDelay: 0, inverted: false)
                                // Weighted phase error: 1 - cos(phase difference), weighted by the smaller magnitude.
                                let d = s.phase - h.phase
                                cost += min(s.magnitude, h.magnitude) * (1 - cos(d))
                            }
                        }
                        if cost < bestCost { bestCost = cost; bestShift = shift; bestInv = inv }
                        shift += 0.00005 * sr
                    }
                }
                delay[w.speaker.id, default: 0] += bestShift
                work[k].corr.inverted = bestInv
            }
        }
        if let fc, options.delayEstimation == .minimumPhaseError {
            fineAlign(fc)
            notes.append("Time alignment: \(options.timeAlign.rawValue), refined by minimum phase error at the crossover.")
        } else {
            notes.append("Time alignment: \(options.timeAlign.rawValue), from the cross-correlation peak.")
        }

        // Phase correction: all-pass filters on the side whose phase leads, then a new fine alignment.
        if let fc, options.phaseCorrection, !subs.isEmpty, !tops.isEmpty {
            func corrected(_ w: Work) -> Response {
                w.pre.applying(w.corr.eq.map { $0.coefficients(sampleRate: sr) }, gainDB: w.corr.gainDB, delaySamples: delay[w.speaker.id] ?? 0, inverted: w.corr.inverted)
            }
            let ap = PhaseAligner.align(subwoofers: work.filter { $0.speaker.role == .subwoofer }.map(corrected),
                                        tops: work.filter { $0.speaker.role == .fullRange }.map(corrected), band: (fc / 2)...(fc * 2))
            if !ap.filters.isEmpty {
                for i in work.indices where (work[i].speaker.role == .subwoofer) == ap.onSubwoofers { work[i].corr.eq += ap.filters }
                if options.delayEstimation == .minimumPhaseError { fineAlign(fc) }
                notes.append(String(format: "Phase correction: %d all-pass filters on the %@. The phase error at the crossover fell from %.2f to %.2f.",
                                    ap.filters.count, ap.onSubwoofers ? "subwoofers" : "tops", ap.before, ap.after))
            } else {
                notes.append("Phase correction: the phase at the crossover is already aligned. The app added no all-pass filters.")
            }
        }
        // No negative delays: move every channel up by the same amount.
        let minDelay = delay.values.min() ?? 0
        if minDelay < 0 { for key in delay.keys { delay[key]! -= minDelay } }
        for i in work.indices { work[i].corr.delayMs = (delay[work[i].speaker.id] ?? 0) / sr * 1000 }

        // Headroom: the loopback path is digital, so remove net boost to stop clipping.
        var peak = -Double.infinity
        for w in work {
            let filters = w.corr.filters(sampleRate: sr)
            for f in grid where w.range.contains(f) || w.corr.crossover != nil {
                var g = w.corr.gainDB
                for c in filters { g += c.magnitudeDB(at: f, sampleRate: sr) }
                peak = max(peak, g)
            }
        }
        if peak > 0 {
            for i in work.indices { work[i].corr.gainDB -= peak }
            notes.append(String(format: "Headroom: all channels lowered by %.1f dB so that EQ boosts cannot clip.", peak))
        }

        let channels = work.enumerated().map { n, w -> ChannelResult in
            let eqFilters = w.corr.eq.map { $0.coefficients(sampleRate: sr) }
            let after = w.pre.applying(eqFilters, gainDB: w.corr.gainDB, delaySamples: w.corr.delayMs * sr / 1000, inverted: w.corr.inverted)
            return ChannelResult(correction: w.corr, before: w.raw, after: after, target: targetGrid.map { $0 + ref + (peak > 0 ? -peak : 0) }, correctedRange: w.range, errorDB: errors[n])
        }
        return CalibrationResult(targetCurve: target, options: options, channels: channels,
                                 systemBefore: Response.sum(channels.map(\.before)), systemAfter: Response.sum(channels.map(\.after)),
                                 assumptions: notes, sampleRate: sr)
    }
}

// MARK: - Export

public enum REWExport {
    /// One REW "Filter Settings" file for one channel. Import it in REW with Filter Tasks → Import.
    public static func filterSettings(_ c: ChannelCorrection, date: Date = Date()) -> String {
        var s = "Filter Settings file\n\nRoom EQ V5.31\nDated: \(date.formatted(date: .abbreviated, time: .shortened))\n\nNotes:AutoREQ \(c.speakerName)\n\nEqualiser: Generic\nAverage 1\n"
        let bands = c.eq
        for k in 0..<max(bands.count, 1) {
            guard k < bands.count else { s += "Filter  1: OFF None\n"; break }
            let b = bands[k]
            s += String(format: "Filter %2d: %@  %@ Fc %7.1f Hz  Gain %5.1f dB  Q %6.3f\n", k + 1, b.enabled ? "ON " : "OFF", b.type.rewCode.padding(toLength: 8, withPad: " ", startingAt: 0), b.frequency, b.gainDB, b.q)
        }
        return s
    }
}
