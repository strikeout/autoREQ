import Foundation

/// A finding is one diagnostic card. The cards follow the Omnissiah manual.
public struct Finding: Hashable, Sendable, Codable, Identifiable {
    /// The kind of the card. The order of the cases is the display order of cards that have the same severity.
    public enum Kind: String, Codable, CaseIterable, Sendable {
        case weakMeasurement, possibleMeasurementNoise, peakLeftUncorrected, boundaryNull, roomModeNull,
             roomModePeak, bassNull, reflection, modalBoundaryIssue, deepNullLeftAlone, highFrequencyLimit,
             outsideUsableRange
    }

    public enum Severity: Int, Codable, CaseIterable, Sendable, Comparable {
        case info, advisory, warning
        public static func < (l: Severity, r: Severity) -> Bool { l.rawValue < r.rawValue }
    }

    /// The identity stays the same between live updates while the channel, the kind and the frequency stay the same.
    public var id: String { "\(channel)|\(kind.rawValue)|\(frequency.map { String(Int($0.rounded())) } ?? "-")" }
    public var channel: String
    public var frequency: Double?
    public var kind: Kind
    public var severity: Severity
    public var title: String
    public var detail: String
    public var action: String
    /// The estimated distance from the speaker to the wall that causes a boundary null. Other kinds have none.
    public var wallDistanceM: Double?
}

/// Makes the diagnostic cards for one measurement.
///
/// The analysis uses these thresholds.
///
/// - A peak is a local maximum below 300 Hz, 6 dB or more above the median level of two octaves around it.
///   It is a warning at 10 dB or more.
///
/// - A null is a local minimum below 350 Hz, 10 dB or more below the same median. It is a warning at 15 dB or more.
///   A null is clean when the mean coherence within 1/12 octave is 0.7 or more.
///
/// - A clean null between 57 Hz and 350 Hz is a boundary null. The wall distance is the quarter wavelength c / (4 f),
///   rounded to 5 cm, so 57 Hz gives 1.5 m.
///   A clean null below 57 Hz is a room mode null. A null that is not clean is a bass null.
///   The results show a deep null left alone instead of a room mode null or a bass null.
///   This occurs when the EQ boost there is below 3 dB.
///
/// - In the results, a peak that stays more than 3 dB above the target is a peak left uncorrected.
///   It is a warning at 6 dB or more.
///
/// - The SNR at one frequency is 10 · log10(γ² / (1 − γ²)), where γ² is the coherence.
///   A median SNR below 6 dB (γ² 0.8) is a weak measurement. It is a warning below 3 dB (γ² 0.67).
///
/// - A peak with a coherence below 0.6 is possible noise. So is a coherence below 0.5 at 15 % or more of the points above 300 Hz.
///
/// - A modal or boundary issue is a run of 1/6 octave or more below 300 Hz.
///   In the run, the coherence is below 0.6 and the level has no dip of 6 dB.
///
/// - The usable range ends where the 1/6-octave smoothed level falls 15 dB below the 90th percentile of the range.
///   The card shows only when the end is 1/4 octave or more inside the range. Above 2 kHz, the end is a high-frequency limit.
///   All other checks use the usable range only.
///
/// - A reflection is the strongest peak of the energy-time curve 1 ms to 10 ms after the direct sound, above −10 dB.
///   It is a warning above −6 dB. The analysis looks for reflections only when the usable range goes above 1 kHz.
///
/// - A channel gets at most `maxFindings` cards, with the most severe first.
public enum Diagnostics {
    public static let maxFindings = 8

    /// The cards for the live Measure screen: the measurement quality, peaks, nulls and reflections.
    public static func live(_ r: Response, channel: String, range: ClosedRange<Double>) -> [Finding] {
        ranked(analyse(r, channel: channel, range: range, impulse: r.impulse))
    }

    /// The cards for the results page. They tell which peaks the EQ corrected and which nulls it left alone on purpose.
    /// The analysis uses the measurement before the correction, in the corrected range.
    public static func results(_ c: ChannelResult, impulse: ImpulseResponse?) -> [Finding] {
        let sr = c.before.sampleRate
        let eq = c.correction.eq.filter { $0.enabled && $0.type != .allPass }.map { $0.coefficients(sampleRate: sr) }
        func eqGain(_ f: Double) -> Double { eq.reduce(0) { $0 + $1.magnitudeDB(at: f, sampleRate: sr) } }
        var out: [Finding] = []
        for var x in analyse(c.before, channel: c.correction.speakerName, range: c.correctedRange, impulse: impulse ?? c.before.impulse) {
            guard let f = x.frequency else { out.append(x); continue }
            let i = FrequencyGrid.index(of: f)
            // The sub plays below the crossover, so a null of a top there is not important.
            if let xo = c.correction.crossover, xo.highPass, f < xo.frequency, [.boundaryNull, .roomModeNull, .bassNull].contains(x.kind) { continue }
            switch x.kind {
            case .roomModePeak:
                let residual = c.after.magnitudeDB[i] - c.target[i]
                if residual <= 3 {
                    x.severity = .info
                    x.action = eqGain(f) <= -1
                        ? String(format: "The EQ cuts this peak by about %.0f dB. No action is necessary.", -eqGain(f))
                        : "The level is now near the target. No action is necessary."
                } else {
                    x.kind = .peakLeftUncorrected
                    x.severity = residual >= 6 ? .warning : .advisory
                    x.title = "Peak left uncorrected"
                    x.detail = String(format: "The level near %@ stays about %.0f dB above the target.", hz(f), residual)
                    x.action = "Set more filters or a lower confidence, then calibrate again. Bass traps also reduce this peak."
                }
            case .boundaryNull:
                x.action = eqGain(f) < 3
                    ? "Move the speaker closer to the wall or farther away. The calibration does not boost this dip on purpose."
                    : "Move the speaker closer to the wall or farther away. The EQ boost here cannot fill a cancellation."
            case .roomModeNull, .bassNull:
                guard eqGain(f) < 3 else { break }
                let depth = nullDepth(c.before, at: i, range: c.correctedRange)
                x.kind = .deepNullLeftAlone
                x.severity = .info
                x.title = "Deep null left alone"
                x.detail = String(format: "The level drops by about %.0f dB near %@. A boost cannot fill a cancellation, so the calibration does not boost it.", depth, hz(f))
                x.action = "Move the speaker or the listening position to make the dip smaller."
            default: break
            }
            out.append(x)
        }
        return ranked(out)
    }

    // MARK: - Analysis

    static func analyse(_ r: Response, channel: String, range: ClosedRange<Double>, impulse: ImpulseResponse?) -> [Finding] {
        let grid = FrequencyGrid.frequencies
        let idx = grid.indices.filter { range.contains(grid[$0]) }
        guard idx.count > 8 else { return [] }
        var out: [Finding] = []
        func card(_ kind: Finding.Kind, _ f: Double?, _ severity: Finding.Severity, _ title: String, _ detail: String, _ action: String, wall: Double? = nil) {
            out.append(Finding(channel: channel, frequency: f, kind: kind, severity: severity, title: title, detail: detail, action: action, wallDistanceM: wall))
        }

        // Find the ends of the usable range. A high percentile is the reference, so a band-limited speaker gets a correct reference.
        let smooth = Smoothing.oct6.apply(r).magnitudeDB
        let ref = idx.map { smooth[$0] }.sorted()[idx.count * 9 / 10]
        let lowEnd = idx.first { smooth[$0] >= ref - 15 }.map { grid[$0] } ?? range.lowerBound
        let highEnd = idx.last { smooth[$0] >= ref - 15 }.map { grid[$0] } ?? range.upperBound
        let quarter = pow(2, 0.25)
        if lowEnd > range.lowerBound * quarter {
            card(.outsideUsableRange, lowEnd, .info, "Outside the usable range",
                 String(format: "The speaker gives little sound below %@. The level there is more than 15 dB below the main level.", hz(lowEnd)),
                 "Do not boost this region with EQ. The speaker cannot play it at a useful level.")
        }
        if highEnd < range.upperBound / quarter {
            if highEnd >= 2000 {
                card(.highFrequencyLimit, highEnd, .info, "High-frequency limit",
                     String(format: "The response falls fast above %@. The mic or the speaker sets this limit.", hz(highEnd)),
                     "Do not boost above this frequency. A mic calibration file can extend the usable range.")
            } else {
                card(.outsideUsableRange, highEnd, .info, "Outside the usable range",
                     String(format: "The speaker gives little sound above %@. The level there is more than 15 dB below the main level.", hz(highEnd)),
                     "Do not boost this region with EQ. The speaker cannot play it at a useful level.")
            }
        }
        // The other checks use the usable range only.
        let use = idx.filter { grid[$0] >= lowEnd && grid[$0] <= highEnd }
        guard use.count > 8 else { return out }

        // Check the measurement quality.
        let snr = use.map { i -> Double in
            let g = min(max(r.coherence[i], 0.001), 0.9999)
            return 10 * log10(g / (1 - g))
        }.sorted()[use.count / 2]
        let weak = snr < 6
        if weak {
            card(.weakMeasurement, nil, snr < 3 ? .warning : .advisory, "Weak measurement",
                 String(format: "The signal-to-noise ratio is about %.0f dB. A reliable result needs 6 dB or more.", snr),
                 "Increase the test-signal level, or make the room quieter. Then measure again.")
        }
        let high = use.filter { grid[$0] > 300 }
        if !weak && !high.isEmpty && Double(high.filter { r.coherence[$0] < 0.5 }.count) >= 0.15 * Double(high.count) {
            card(.possibleMeasurementNoise, nil, .advisory, "Possible measurement noise",
                 "The coherence is low at many frequencies above 300 Hz. Noise can change the result.",
                 "Make the room quieter, or increase the test-signal level. Then measure again.")
        }

        // Find the peaks and the nulls against the median level of two octaves around each point.
        let low = use.filter { grid[$0] >= 15 && grid[$0] <= 400 }
        let base = low.map { i in low.filter { abs($0 - i) <= 48 }.map { r.magnitudeDB[$0] }.sorted() }.map { $0[$0.count / 2] }
        let span = 4  // The span is 1/12 octave on each side.
        var peaks: [(i: Int, value: Double)] = [], nulls: [(i: Int, value: Double)] = []
        if low.count > 2 * span {
            for n in span..<(low.count - span) {
                let i = low[n], near = low[(n - span)...(n + span)].map { r.magnitudeDB[$0] }
                let d = r.magnitudeDB[i] - base[n]
                if grid[i] <= 300 && d >= 6 && r.magnitudeDB[i] == near.max() { peaks.append((i, d)) }
                if grid[i] <= 350 && d <= -10 && r.magnitudeDB[i] == near.min() { nulls.append((i, -d)) }
            }
        }
        func coherenceNear(_ i: Int) -> Double {
            let k = (max(0, i - span)...min(grid.count - 1, i + span)).map { r.coherence[$0] }
            return k.reduce(0, +) / Double(k.count)
        }
        for p in pick(peaks) {
            let f = grid[p.i]
            if r.coherence[p.i] < 0.6 {
                if !out.contains(where: { $0.kind == .possibleMeasurementNoise }) {
                    card(.possibleMeasurementNoise, f, .advisory, "Possible measurement noise",
                         String(format: "The peak near %@ has low coherence. It can be noise and not a room mode.", hz(f)),
                         "Make the room quieter, or increase the test-signal level. Then measure again.")
                }
                continue
            }
            var detail = String(format: "A room mode raises the level near %@ by about %.0f dB.", hz(f), p.value)
            if let ir = impulse, let t60 = RoomAnalysis.decayT60(ir, frequency: f), t60 >= 0.3 {
                detail += String(format: " The note rings for about %.1f s.", t60)
            }
            card(.roomModePeak, f, p.value >= 10 ? .warning : .advisory, "Room mode peak", detail,
                 "The calibration cuts this peak with EQ. Bass traps also reduce it.")
        }
        for p in pick(nulls) {
            let f = grid[p.i], severity: Finding.Severity = p.value >= 15 ? .warning : .advisory
            if coherenceNear(p.i) < 0.7 {
                card(.bassNull, f, .advisory, "Bass null",
                     String(format: "The level drops by about %.0f dB near %@. The cause is not clear, because the coherence is low here.", p.value, hz(f)),
                     "Measure again at a slightly different mic position. Do not boost this dip with EQ.")
            } else if f >= 57 {
                let d = (343 / (4 * f) / 0.05).rounded() * 0.05
                card(.boundaryNull, f, severity, "Boundary null",
                     String(format: "A wall about %.2f m behind the speaker cancels the sound near %@.", d, hz(f)),
                     "Move the speaker closer to the wall or farther away. EQ cannot fill this dip.", wall: d)
            } else {
                card(.roomModeNull, f, severity, "Room mode null",
                     String(format: "The room cancels the sound near %@ at this mic position. The level drops by about %.0f dB.", hz(f), p.value),
                     "Move the listening position or the speaker. EQ cannot fill this dip.")
            }
        }

        // Find low bass coherence without a dip.
        if !weak {
            var run: [Int] = [], longest: [Int] = []
            for (n, i) in low.enumerated() where grid[i] <= 300 {
                if r.coherence[i] < 0.6 && r.magnitudeDB[i] > base[n] - 6 { run.append(i) } else { run = [] }
                if run.count > longest.count { longest = run }
            }
            if longest.count >= 8 {
                let f = grid[longest[longest.count / 2]]
                card(.modalBoundaryIssue, f, .advisory, "Unstable bass response",
                     String(format: "The coherence is low near %@, but the level does not drop. Room modes or near walls can cause this.", hz(f)),
                     "Move the mic a little and measure again. Average several mic positions.")
            }
        }

        // Find the strongest early reflection.
        if highEnd > 1000, let ir = impulse,
           let x = RoomAnalysis.reflections(ir, windowMs: 10, thresholdDB: -10)
               .filter({ (1...10).contains($0.delayMs) }).max(by: { $0.levelDB < $1.levelDB }) {
            let tau = x.delayMs / 1000
            let notches = (0..<3).map { Double(2 * $0 + 1) / (2 * tau) }
            card(.reflection, notches[0], x.levelDB > -6 ? .warning : .advisory, "Strong early reflection",
                 String(format: "A reflection arrives %.1f ms after the direct sound, only %.0f dB lower. It causes dips near %@, %@ and %@.",
                        x.delayMs, -x.levelDB, hz(notches[0]), hz(notches[1]), hz(notches[2])),
                 "Put absorption at the reflection point, or move the speaker. EQ cannot fix these dips.")
        }
        return out
    }

    /// The three largest extremes, at least 1/6 octave apart.
    static func pick(_ items: [(i: Int, value: Double)]) -> [(i: Int, value: Double)] {
        var kept: [(i: Int, value: Double)] = []
        for x in items.sorted(by: { $0.value > $1.value }) where !kept.contains(where: { abs($0.i - x.i) < 8 }) {
            kept.append(x)
            if kept.count == 3 { break }
        }
        return kept
    }

    /// The depth of the null at grid index `i` below the median level of two octaves around it.
    static func nullDepth(_ r: Response, at i: Int, range: ClosedRange<Double>) -> Double {
        let grid = FrequencyGrid.frequencies
        let near = (max(0, i - 48)...min(grid.count - 1, i + 48)).filter { range.contains(grid[$0]) }.map { r.magnitudeDB[$0] }.sorted()
        return near.isEmpty ? 0 : near[near.count / 2] - r.magnitudeDB[i]
    }

    /// Removes duplicates, sorts by severity and kind, and keeps the first `maxFindings`.
    static func ranked(_ items: [Finding]) -> [Finding] {
        var seen = Set<String>()
        let order = Finding.Kind.allCases
        let unique = items.filter { seen.insert($0.id).inserted }
        let sorted = unique.sorted {
            if $0.severity != $1.severity { return $0.severity > $1.severity }
            let a = order.firstIndex(of: $0.kind)!, b = order.firstIndex(of: $1.kind)!
            if a != b { return a < b }
            return ($0.frequency ?? 0) < ($1.frequency ?? 0)
        }
        return Array(sorted.prefix(maxFindings))
    }

    static func hz(_ f: Double) -> String { f < 1000 ? String(format: "%.0f Hz", f) : String(format: "%.1f kHz", f / 1000) }
}
